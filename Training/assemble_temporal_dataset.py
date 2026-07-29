#!/usr/bin/env python3
"""Assemble signed annotations and pose evidence into temporal training records.

The CLI is deliberately fail closed: the full collection audit must pass, every
source annotation signature is reverified, every disagreement must have signed
third-coach ground truth, and pose features must remain bound to the source
video fingerprint recorded in the prepared index.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from itertools import combinations
from pathlib import Path

from audit_collection import audit_collection
from coach_auth import (
    CoachAuthorizationError,
    load_verified_registry,
    require_registry_secret,
    verify_artifact_signature,
)
from consent_auth import (
    ConsentAuthorizationError,
    load_verified_consent_ledger_records,
    load_verified_consent_registry,
    require_separate_signing_domains,
    require_consent_registry_secret,
    verify_annotation_consent,
)
from prepare_coach_dataset import (
    compare,
    feature_evidence_digest,
    labeling_task_digest,
    validate as validate_annotation,
)
from task_coordinator_auth import (
    TaskCoordinatorAuthorizationError,
    authorize_labeling_task,
    load_verified_task_coordinator_registry,
    require_task_coordinator_registry_secret,
)
from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING, validate_rubric_binding
from capture_plan import (
    CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING,
    validate_annotation_assignment,
)


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{path} is unreadable JSON: {error}") from error


def canonical_digest(value: object) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def _labels(source: dict) -> dict:
    return {
        "isVideoUsable": source["isVideoUsable"],
        "unusableReason": source.get("unusableReason"),
        "phaseBoundaries": source.get("phaseBoundaries") or [],
        "techniqueRatings": source.get("techniqueRatings") or [],
        "topPriority": source.get("topPriority"),
    }


def assemble_records(
    indices: list[dict],
    ground_truth_records: list[dict],
    *,
    registry: dict[str, dict] | None = None,
    ground_truth_paths: dict[str, Path] | None = None,
    consent_records: dict[str, dict] | None = None,
    task_coordinator_registry: dict[str, dict] | None = None,
) -> tuple[list[dict], list[str]]:
    ground_truth = {
        item.get("analysisID"): item
        for item in ground_truth_records
        if item.get("analysisID")
    }
    records: list[dict] = []
    errors: list[str] = []
    seen: set[str] = set()

    for index in indices:
        for review in index.get("reviews") or []:
            analysis_id = review.get("analysisID")
            if not analysis_id or analysis_id in seen:
                errors.append(f"analysis ID is missing or duplicated: {analysis_id!r}")
                continue
            seen.add(analysis_id)
            annotation_paths = [Path(path) for path in review.get("annotationFiles") or []]
            if len(annotation_paths) < 2:
                errors.append(f"analysis {analysis_id}: two source annotation files are required")
                continue

            annotations: list[dict] = []
            for path in annotation_paths:
                try:
                    annotation = load_json(path)
                except ValueError as error:
                    errors.append(str(error))
                    continue
                validation = validate_annotation(
                    annotation,
                    path,
                    set(registry) if registry is not None else None,
                    task_coordinator_registry,
                )
                if validation:
                    errors.extend(validation)
                    continue
                if registry is not None:
                    try:
                        verify_artifact_signature(path, annotation["annotatorPseudonym"], registry)
                    except CoachAuthorizationError as error:
                        errors.append(f"{path.name}: {error}")
                        continue
                annotations.append(annotation)
            if len(annotations) != len(annotation_paths):
                continue

            verified_consent: list[dict] = []
            if consent_records is None:
                errors.append(f"analysis {analysis_id}: independently verified consent records are required")
                continue
            for annotation in annotations:
                evidence, consent_errors = verify_annotation_consent(annotation, consent_records)
                errors.extend(f"analysis {analysis_id}: {error}" for error in consent_errors)
                if evidence is not None:
                    verified_consent.append(evidence)
            if len(verified_consent) != len(annotations):
                continue
            consent_evidence_digests = {
                canonical_digest(item) for item in verified_consent
            }
            if len(consent_evidence_digests) != 1:
                errors.append(f"analysis {analysis_id}: signed consent evidence conflicts across source annotations")
                continue
            consent_evidence = verified_consent[0]
            if consent_evidence != review.get("consentVerification"):
                errors.append(f"analysis {analysis_id}: signed consent evidence does not match the prepared index")
                continue

            annotation_ids = {item["annotationID"] for item in annotations}
            coach_ids = {item["annotatorPseudonym"] for item in annotations}
            if len(coach_ids) < 2:
                errors.append(f"analysis {analysis_id}: two distinct source coaches are required")
                continue
            if any(item["analysisID"] != analysis_id for item in annotations):
                errors.append(f"analysis {analysis_id}: source annotation analysis IDs do not match")
                continue
            if any(item["participantPseudonym"] != review.get("participantPseudonym") for item in annotations):
                errors.append(f"analysis {analysis_id}: source participant identity does not match the index")
                continue
            actual_disagreement = any(
                compare(first, second)["requiresAdjudication"]
                for first, second in combinations(annotations, 2)
                if first["annotatorPseudonym"] != second["annotatorPseudonym"]
            )
            evidence_digests = {feature_evidence_digest(item["modelFeatureEvidence"]) for item in annotations}
            if len(evidence_digests) != 1:
                errors.append(f"analysis {analysis_id}: source annotations contain different pose evidence")
                continue
            evidence_digest = next(iter(evidence_digests))
            if evidence_digest != review.get("featureEvidenceDigest"):
                errors.append(f"analysis {analysis_id}: pose evidence digest does not match the prepared index")
                continue
            evidence = annotations[0]["modelFeatureEvidence"]
            video_digest = evidence["provenance"]["videoSHA256"]
            if video_digest != review.get("sourceVideoSHA256"):
                errors.append(f"analysis {analysis_id}: source video fingerprint does not match the prepared index")
                continue

            tasks = [item.get("labelingTask") for item in annotations]
            task = None
            if any(task is not None for task in tasks):
                if any(task is None for task in tasks):
                    errors.append(f"analysis {analysis_id}: portable task provenance is missing from a source annotation")
                    continue
                task_digests = {labeling_task_digest(task) for task in tasks}
                if len(task_digests) != 1:
                    errors.append(f"analysis {analysis_id}: source annotations contain different portable tasks")
                    continue
                if task_coordinator_registry is None:
                    errors.append(f"analysis {analysis_id}: an authorized task coordinator registry is required")
                    continue
                task = tasks[0]
                try:
                    authorization = authorize_labeling_task(task, task_coordinator_registry)
                except TaskCoordinatorAuthorizationError as error:
                    errors.append(f"analysis {analysis_id}: {error}")
                    continue
                task_provenance = {
                    "status": "AUTHORIZED — ECDSA signature and coordinator registry key verified",
                    "taskSHA256": next(iter(task_digests)),
                    "taskID": task["payload"]["taskID"],
                    "taskCreatedAt": task["payload"]["createdAt"],
                    "coordinatorPseudonym": task["payload"]["coordinatorPseudonym"],
                    "signerKeyID": task["signature"]["signerKeyID"],
                    "authorization": authorization,
                }
            else:
                task_provenance = {"status": "LOCAL SAME-DEVICE LABELING — no portable task"}
            if task_provenance != review.get("labelingTaskVerification"):
                errors.append(
                    f"analysis {analysis_id}: portable task authorization does not match the prepared index"
                )
                continue
            if task is not None and task.get("payload", {}).get("schemaVersion") == 2:
                capture_slot, capture_errors = validate_annotation_assignment(annotations[0])
                if capture_errors or capture_slot is None:
                    errors.extend(f"analysis {analysis_id}: {error}" for error in capture_errors)
                    continue
                capture_plan_provenance = {
                    "status": "PINNED — signed task matches frozen capture plan",
                    "plan": CURRENT_CAPTURE_PLAN_BINDING,
                    "slotID": capture_slot["slotID"],
                    "participantPseudonym": capture_slot["participantPseudonym"],
                    "split": capture_slot["split"],
                }
            else:
                capture_plan_provenance = {
                    "status": "UNBOUND — legacy or local annotation; not release-evaluation eligible"
                }
            if review.get("capturePlanVerification") is not None and (
                capture_plan_provenance != review.get("capturePlanVerification")
            ):
                errors.append(
                    f"analysis {analysis_id}: capture-plan proof does not match the prepared index"
                )
                continue

            adjudicated = ground_truth.get(analysis_id)
            if review.get("requiresAdjudication") or actual_disagreement:
                if adjudicated is None:
                    errors.append(f"analysis {analysis_id}: unresolved coach disagreement")
                    continue
                if adjudicated.get("groundTruthEligible") is not True:
                    errors.append(f"analysis {analysis_id}: adjudication is not ground-truth eligible")
                    continue
                rubric_errors = validate_rubric_binding(adjudicated.get("rubric"))
                if rubric_errors:
                    errors.extend(f"analysis {analysis_id}: adjudication {error}" for error in rubric_errors)
                    continue
                if set(adjudicated.get("sourceAnnotationIDs") or []) != annotation_ids:
                    errors.append(f"analysis {analysis_id}: adjudication source annotation IDs do not match")
                    continue
                if adjudicated.get("featureEvidenceDigest") != evidence_digest or adjudicated.get("sourceVideoSHA256") != video_digest:
                    errors.append(f"analysis {analysis_id}: adjudication is not bound to the same video and pose evidence")
                    continue
                if registry is not None:
                    path = (ground_truth_paths or {}).get(analysis_id)
                    if path is None:
                        errors.append(f"analysis {analysis_id}: signed ground-truth file path is missing")
                        continue
                    try:
                        verify_artifact_signature(path, adjudicated["adjudicatorPseudonym"], registry)
                    except (CoachAuthorizationError, KeyError) as error:
                        errors.append(f"{path.name}: {error}")
                        continue
                label_source = adjudicated
                ground_truth_provenance = {
                    "kind": "signedThirdCoachAdjudication",
                    "groundTruthID": adjudicated.get("groundTruthID"),
                    "adjudicatorPseudonym": adjudicated.get("adjudicatorPseudonym"),
                }
            else:
                label_source = annotations[0]
                ground_truth_provenance = {"kind": "exactDoubleCoachAgreement"}

            records.append({
                "analysisID": analysis_id,
                "participantPseudonym": review["participantPseudonym"],
                "split": review["split"],
                "cameraAngle": review["cameraAngle"],
                "skillLevel": review["skillLevel"],
                "cohorts": (adjudicated or review)["cohorts"],
                "featureEvidenceDigest": evidence_digest,
                "sourceVideoSHA256": video_digest,
                "featureEvidence": evidence,
                "rubric": CURRENT_RUBRIC_BINDING,
                "consentProvenance": consent_evidence,
                "portableTaskProvenance": task_provenance,
                "capturePlanProvenance": capture_plan_provenance,
                "labels": _labels(label_source),
                "labelProvenance": {
                    **ground_truth_provenance,
                    "sourceAnnotationIDs": sorted(annotation_ids),
                    "sourceCoachIDs": sorted(coach_ids),
                    "consentRecordID": consent_evidence["consentRecordID"],
                    "consentReceiptID": consent_evidence["consentReceiptID"],
                },
            })
    return records, errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("indices", nargs="+", type=Path, help="Prepared coach dataset indices")
    parser.add_argument("--ground-truth", nargs="*", type=Path, default=[])
    parser.add_argument("--coach-registry", type=Path, required=True)
    parser.add_argument("--task-coordinator-registry", type=Path, required=True)
    parser.add_argument("--consent-registry", type=Path, required=True)
    parser.add_argument("--consent-ledger", type=Path, required=True)
    parser.add_argument(
        "--consent-receipts",
        nargs="+",
        type=Path,
        required=True,
        help="Signed grant/revocation receipt files or directories",
    )
    parser.add_argument("--output", type=Path, default=Path("Training/artifacts/temporal_dataset.json"))
    args = parser.parse_args()

    try:
        registry = load_verified_registry(args.coach_registry, require_registry_secret())
        task_coordinator_registry = load_verified_task_coordinator_registry(
            args.task_coordinator_registry,
            require_task_coordinator_registry_secret(),
        )
        consent_registry = load_verified_consent_registry(
            args.consent_registry,
            require_consent_registry_secret(),
        )
        require_separate_signing_domains(registry, consent_registry)
        receipt_paths: list[Path] = []
        for item in args.consent_receipts:
            candidates = sorted(item.glob("*.json")) if item.is_dir() else [item]
            receipt_paths.extend(
                path for path in candidates
                if not path.name.endswith(".consent-signature.json")
                and not path.name.endswith(".consent-ledger-signature.json")
                and path.resolve() != args.consent_ledger.resolve()
            )
        consent_records, consent_ledger_evidence = load_verified_consent_ledger_records(
            receipt_paths, args.consent_ledger, consent_registry
        )
        indices = [load_json(path) for path in args.indices]
        ground_truth_records = [load_json(path) for path in args.ground_truth]
    except (
        CoachAuthorizationError,
        ConsentAuthorizationError,
        TaskCoordinatorAuthorizationError,
        ValueError,
    ) as error:
        print(f"Temporal dataset assembly stopped: {error}")
        return 2

    audit = audit_collection(indices, ground_truth_records)
    if not audit["collectionReady"]:
        print("Temporal dataset assembly stopped: the collection readiness gate has not passed.")
        print(json.dumps(audit["deficits"], indent=2))
        return 1

    ground_truth_paths = {
        item["analysisID"]: path
        for path, item in zip(args.ground_truth, ground_truth_records, strict=True)
        if item.get("analysisID")
    }
    records, errors = assemble_records(
        indices,
        ground_truth_records,
        registry=registry,
        ground_truth_paths=ground_truth_paths,
        consent_records=consent_records,
        task_coordinator_registry=task_coordinator_registry,
    )
    if errors or len(records) != audit["analysisCount"]:
        print("Temporal dataset assembly stopped; no partial training dataset was written.")
        print("\n".join(f"- {error}" for error in errors))
        return 1


    payload = {
        "schemaVersion": 3,
        "featureContract": "ServeModelFeatureSequence schema 2",
        "labelContract": "ServeAI single-serve observational rubric v1.0.0; explicit coach ground truth; no automatic averaging",
        "rubricContract": CURRENT_RUBRIC_BINDING,
        "capturePlanContract": CURRENT_CAPTURE_PLAN_BINDING,
        "consentContract": "Independently signed, video-bound consent receipt schema 1",
        "consentLedgerVerification": consent_ledger_evidence,
        "taskCoordinatorRegistryVerification": {
            "registryID": load_json(args.task_coordinator_registry).get("registryID"),
            "registrySHA256": hashlib.sha256(args.task_coordinator_registry.read_bytes()).hexdigest(),
        },
        "analysisCount": len(records),
        "participantCount": audit["participantCount"],
        "splitCounts": audit["splitCounts"],
        "collectionAuditDigest": canonical_digest(audit),
        "trainingEligible": True,
        "modelReleaseEligible": False,
        "records": records,
    }
    payload["datasetDigest"] = canonical_digest(payload["records"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(records)} signed temporal records to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
