#!/usr/bin/env python3
"""Build repeatability evidence from two signed native analyses per held-out clip.

The resulting report is accepted by ``evaluate_release_candidate.py``. Every
score is read from a coordinator-authorized, tamper-evident native task; the
task itself binds the app build, validated model artifact, and source video.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import (
    CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING,
    validate_record_provenance,
)
from evaluate_release_candidate import canonical_digest
from sign_validated_model_release import read_json, sha256_artifact
from task_coordinator_auth import (
    TASK_COORDINATOR_REGISTRY_SECRET_ENV,
    TaskCoordinatorAuthorizationError,
    authorize_labeling_task,
    load_verified_task_coordinator_registry,
    require_task_coordinator_registry_secret,
    verify_native_task_signature,
)


PROTOCOL = "same compiled model, app build, settings, and exact source video analyzed twice"


class RepeatabilityEvidenceError(ValueError):
    pass


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resolve_path(manifest_path: Path, value: object, field: str) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise RepeatabilityEvidenceError(f"{field} is required")
    path = Path(value)
    return path if path.is_absolute() else manifest_path.parent / path


def validate_dataset(dataset: dict[str, Any], model: dict[str, Any]) -> dict[str, dict[str, Any]]:
    if dataset.get("schemaVersion") != 3 or dataset.get("trainingEligible") is not True:
        raise RepeatabilityEvidenceError("dataset is not an eligible assembled temporal artifact")
    if dataset.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise RepeatabilityEvidenceError("dataset is not bound to the current coach rubric")
    if model.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise RepeatabilityEvidenceError("model is not bound to the current coach rubric")
    if dataset.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise RepeatabilityEvidenceError("dataset is not bound to the frozen capture plan")
    if model.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise RepeatabilityEvidenceError("model is not bound to the frozen capture plan")
    records = dataset.get("records")
    if not isinstance(records, list) or not records:
        raise RepeatabilityEvidenceError("dataset records are missing")
    digest = canonical_digest(records)
    if dataset.get("datasetDigest") != digest or model.get("trainingDatasetDigest") != digest:
        raise RepeatabilityEvidenceError("dataset is not the exact artifact used to train the model")
    result: dict[str, dict[str, Any]] = {}
    for record in records:
        if record.get("rubric") != CURRENT_RUBRIC_BINDING:
            raise RepeatabilityEvidenceError("one or more records are not bound to the current coach rubric")
        capture_errors = validate_record_provenance(record)
        if capture_errors:
            raise RepeatabilityEvidenceError(
                "one or more records have invalid capture-plan provenance: " + capture_errors[0]
            )
        analysis_id = record.get("analysisID")
        if record.get("split") != "test":
            continue
        if not isinstance(analysis_id, str) or not analysis_id or analysis_id in result:
            raise RepeatabilityEvidenceError("held-out analysis IDs must be present and unique")
        result[analysis_id] = record
    if not result:
        raise RepeatabilityEvidenceError("held-out test split is empty")
    return result


def validate_task(
    task: dict[str, Any],
    *,
    registry: dict[str, dict],
    model_identifier: str,
    model_version: str,
    model_hash: str,
    app_build_identifier: str,
    record: dict[str, Any],
) -> dict[str, Any]:
    verify_native_task_signature(task)
    authorization = authorize_labeling_task(task, registry)
    payload = task.get("payload") or {}
    analysis = payload.get("analysis") or {}
    evidence = analysis.get("modelFeatureEvidence") or {}
    provenance = evidence.get("provenance") or {}
    trace = analysis.get("modelTrace") or {}

    source = analysis.get("source")
    if source not in {"coreML", "experimentalCoreML", "evaluationCoreML"}:
        raise RepeatabilityEvidenceError(
            "repeatability tasks must come from an exact experimental candidate or validated Core ML mode"
        )
    expected_release_verification = source == "coreML"
    expected_trace = (
        model_identifier,
        model_version,
        model_hash,
        expected_release_verification,
        app_build_identifier,
    )
    actual_trace = (
        trace.get("modelIdentifier"),
        trace.get("modelVersion"),
        trace.get("modelArtifactSHA256"),
        trace.get("validatedReleaseVerified"),
        trace.get("appBuildIdentifier"),
    )
    if actual_trace != expected_trace:
        raise RepeatabilityEvidenceError("signed task model/app trace does not match the release candidate")

    video_hash = record.get("sourceVideoSHA256")
    if (
        payload.get("sourceVideoSHA256") != video_hash
        or provenance.get("videoSHA256") != video_hash
    ):
        raise RepeatabilityEvidenceError("signed task is not bound to the held-out source video")
    if (
        analysis.get("cameraAngle") != record.get("cameraAngle")
        or analysis.get("skillLevel") != record.get("skillLevel")
    ):
        raise RepeatabilityEvidenceError("signed task capture settings differ from the held-out record")
    score = analysis.get("overallScore")
    if isinstance(score, bool) or not isinstance(score, int) or not 0 <= score <= 100:
        raise RepeatabilityEvidenceError("signed task score must be an integer from 0 to 100")
    if payload.get("analysisID") != analysis.get("id"):
        raise RepeatabilityEvidenceError("signed task analysis identity is inconsistent")
    return {
        "taskID": payload.get("taskID"),
        "analysisID": payload.get("analysisID"),
        "score": score,
        "coordinatorID": authorization["coordinatorID"],
        "signerKeyID": authorization["signerKeyID"],
    }


def build_report(
    *,
    compiled_model_path: Path,
    research_model_path: Path,
    dataset_path: Path,
    pair_manifest_path: Path,
    registry: dict[str, dict],
    registry_path: Path | None = None,
) -> dict[str, Any]:
    model = read_json(research_model_path)
    dataset = read_json(dataset_path)
    manifest = read_json(pair_manifest_path)
    if manifest.get("schemaVersion") != 1:
        raise RepeatabilityEvidenceError("repeatability pair manifest schema must be 1")
    identity = (model.get("modelIdentifier"), model.get("modelVersion"))
    if not all(isinstance(value, str) and value.strip() for value in identity):
        raise RepeatabilityEvidenceError("research model identity is missing")
    model_hash = sha256_artifact(compiled_model_path)
    app_build = manifest.get("appBuildIdentifier")
    if not isinstance(app_build, str) or not app_build.strip():
        raise RepeatabilityEvidenceError("appBuildIdentifier is required")
    test_records = validate_dataset(dataset, model)
    candidates = manifest.get("pairs")
    if not isinstance(candidates, list) or not candidates:
        raise RepeatabilityEvidenceError("repeatability pair manifest contains no pairs")

    pairs: list[dict[str, Any]] = []
    seen_dataset_ids: set[str] = set()
    seen_task_ids: set[str] = set()
    seen_run_ids: set[str] = set()
    for candidate in candidates:
        dataset_analysis_id = candidate.get("analysisID")
        record = test_records.get(dataset_analysis_id)
        if record is None or dataset_analysis_id in seen_dataset_ids:
            raise RepeatabilityEvidenceError("each pair must uniquely reference a held-out analysis")
        first_path = resolve_path(pair_manifest_path, candidate.get("firstTask"), "firstTask")
        repeated_path = resolve_path(pair_manifest_path, candidate.get("repeatedTask"), "repeatedTask")
        first_task = read_json(first_path)
        repeated_task = read_json(repeated_path)
        first = validate_task(
            first_task, registry=registry, model_identifier=identity[0], model_version=identity[1],
            model_hash=model_hash, app_build_identifier=app_build, record=record,
        )
        repeated = validate_task(
            repeated_task, registry=registry, model_identifier=identity[0], model_version=identity[1],
            model_hash=model_hash, app_build_identifier=app_build, record=record,
        )
        task_ids = {first["taskID"], repeated["taskID"]}
        run_ids = {first["analysisID"], repeated["analysisID"]}
        if None in task_ids or len(task_ids) != 2 or task_ids & seen_task_ids:
            raise RepeatabilityEvidenceError("repeatability task IDs must be present and globally unique")
        if None in run_ids or len(run_ids) != 2 or run_ids & seen_run_ids:
            raise RepeatabilityEvidenceError("repeatability analysis runs must be distinct and globally unique")
        seen_dataset_ids.add(dataset_analysis_id)
        seen_task_ids.update(task_ids)
        seen_run_ids.update(run_ids)
        pairs.append({
            "analysisID": dataset_analysis_id,
            "participantPseudonym": record.get("participantPseudonym"),
            "sourceVideoSHA256": record.get("sourceVideoSHA256"),
            "cameraAngle": record.get("cameraAngle"),
            "skillLevel": record.get("skillLevel"),
            "firstScore": first["score"],
            "repeatedScore": repeated["score"],
            "firstAnalysisID": first["analysisID"],
            "repeatedAnalysisID": repeated["analysisID"],
            "firstTaskID": first["taskID"],
            "repeatedTaskID": repeated["taskID"],
            "firstTaskSHA256": sha256_file(first_path),
            "repeatedTaskSHA256": sha256_file(repeated_path),
        })

    return {
        "schemaVersion": 1,
        "modelIdentifier": identity[0],
        "modelVersion": identity[1],
        "modelSHA256": model_hash,
        "rubricContract": CURRENT_RUBRIC_BINDING,
        "capturePlanContract": CURRENT_CAPTURE_PLAN_BINDING,
        "appBuildIdentifier": app_build,
        "protocol": PROTOCOL,
        "pairs": pairs,
        "evidenceDigests": {
            "researchModelSHA256": sha256_file(research_model_path),
            "datasetSHA256": sha256_file(dataset_path),
            "pairManifestSHA256": sha256_file(pair_manifest_path),
            **({"taskCoordinatorRegistrySHA256": sha256_file(registry_path)} if registry_path else {}),
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiled-model", type=Path, required=True)
    parser.add_argument("--research-model", type=Path, required=True)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--pair-manifest", type=Path, required=True)
    parser.add_argument("--task-coordinator-registry", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        secret = require_task_coordinator_registry_secret()
        registry = load_verified_task_coordinator_registry(args.task_coordinator_registry, secret)
        report = build_report(
            compiled_model_path=args.compiled_model,
            research_model_path=args.research_model,
            dataset_path=args.dataset,
            pair_manifest_path=args.pair_manifest,
            registry=registry,
            registry_path=args.task_coordinator_registry,
        )
    except (
        RepeatabilityEvidenceError,
        TaskCoordinatorAuthorizationError,
        OSError,
        json.JSONDecodeError,
        ValueError,
    ) as error:
        print(f"Repeatability report stopped; no report was written: {error}")
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(report['pairs'])} signed repeatability pairs to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
