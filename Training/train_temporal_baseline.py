#!/usr/bin/env python3
"""Train a deterministic, research-only multi-task temporal pose baseline.

This script consumes only `assemble_temporal_dataset.py` output. It never trains
from the held-out test split, never promotes its own artifact, and reports the
strong release metrics without pretending that offline prediction establishes
end-to-end repeatability or Core ML parity.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path

import numpy as np

from consent_auth import (
    ConsentAuthorizationError,
    load_verified_consent_ledger_records,
    load_verified_consent_registry,
    require_consent_registry_secret,
)
from coach_auth import parse_iso8601
from task_coordinator_auth import (
    TaskCoordinatorAuthorizationError,
    load_verified_task_coordinator_registry,
    require_task_coordinator_registry_secret,
)
from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import (
    CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING,
    validate_record_provenance,
)


PHASES = (
    "startingStance", "ballToss", "loading", "trophyPosition", "legDrive",
    "racketDrop", "upwardAcceleration", "contactPosition", "pronation", "followThrough",
)
TECHNIQUES = (
    "tossPlacement", "loadingSequence", "trophyAlignment",
    "legDriveTiming", "contactReach", "landingBalance",
)
APP_PRIORITY_TECHNIQUES = (
    "tossPlacement", "loadingSequence", "trophyAlignment",
    "legDriveTiming", "contactReach", "landingBalance",
)
JOINTS = (
    "nose", "neck", "root", "leftShoulder", "rightShoulder", "leftElbow", "rightElbow",
    "leftWrist", "rightWrist", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle",
)
RESAMPLED_STEPS = 24
L2 = 8.0


def load_dataset(path: Path) -> dict:
    try:
        dataset = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"dataset is unreadable JSON: {error}") from error
    if dataset.get("schemaVersion") != 3 or dataset.get("trainingEligible") is not True:
        raise ValueError("input is not an eligible temporal dataset artifact")
    if dataset.get("modelReleaseEligible") is not False:
        raise ValueError("input dataset has an invalid model-release claim")
    if dataset.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise ValueError("input dataset is not bound to the current coach rubric")
    if any(record.get("rubric") != CURRENT_RUBRIC_BINDING for record in dataset.get("records") or []):
        raise ValueError("one or more records are not bound to the current coach rubric")
    if dataset.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise ValueError("input dataset is not bound to the frozen capture plan")
    capture_errors = [
        error
        for record in dataset.get("records") or []
        for error in validate_record_provenance(record)
    ]
    if capture_errors:
        raise ValueError("one or more records have invalid capture-plan provenance: " + capture_errors[0])
    digest = hashlib.sha256(
        json.dumps(dataset.get("records") or [], sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    if dataset.get("datasetDigest") != digest:
        raise ValueError("temporal dataset digest does not match its records")
    return dataset


def validate_player_isolation(records: list[dict]) -> list[str]:
    errors: list[str] = []
    player_splits: dict[str, set[str]] = defaultdict(set)
    analysis_ids: set[str] = set()
    video_hashes: set[str] = set()
    for record in records:
        analysis_id = record.get("analysisID")
        if not analysis_id or analysis_id in analysis_ids:
            errors.append("analysis IDs must be present and unique")
        analysis_ids.add(analysis_id)
        video_hash = record.get("sourceVideoSHA256")
        if not video_hash or video_hash in video_hashes:
            errors.append("source video fingerprints must be present and unique")
        video_hashes.add(video_hash)
        player_splits[record.get("participantPseudonym")].add(record.get("split"))
    leaking = sorted(player for player, splits in player_splits.items() if len(splits) > 1)
    if leaking:
        errors.append(f"players cross data splits: {', '.join(leaking)}")
    for split in ("train", "validation", "test"):
        if not any(record.get("split") == split for record in records):
            errors.append(f"{split} split is empty")
    return errors


def verify_temporal_dataset_consent(
    records: list[dict],
    consent_records: dict[str, dict],
) -> tuple[list[dict], list[str]]:
    current_evidence: list[dict] = []
    errors: list[str] = []
    for record in records:
        analysis_id = record.get("analysisID")
        provenance = record.get("consentProvenance")
        if not isinstance(provenance, dict) or not provenance.get("consentRecordID"):
            errors.append(f"analysis {analysis_id}: assembled consent provenance is missing")
            continue
        consent = consent_records.get(provenance["consentRecordID"])
        if consent is None:
            errors.append(f"analysis {analysis_id}: consent record is absent from the fresh signed ledger")
            continue
        receipt = consent["receipt"]
        if not consent["active"]:
            errors.append(f"analysis {analysis_id}: consent was revoked after dataset assembly")
            continue
        if receipt.get("participantPseudonym") != record.get("participantPseudonym"):
            errors.append(f"analysis {analysis_id}: current consent participant does not match")
            continue
        video_hash = record.get("sourceVideoSHA256")
        if video_hash not in (receipt.get("coveredVideoSHA256") or []):
            errors.append(f"analysis {analysis_id}: current consent does not cover the source video")
            continue
        current_evidence.append({
            "analysisID": analysis_id,
            "consentRecordID": provenance["consentRecordID"],
            "consentReceiptID": receipt["consentReceiptID"],
            "authorityID": receipt["authorityID"],
            "receiptSHA256": consent["receiptSHA256"],
            "decisionAt": receipt["occurredAt"],
            "sourceVideoSHA256": video_hash,
        })
    return current_evidence, errors


def verify_temporal_task_coordinators(
    records: list[dict],
    registry: dict[str, dict],
) -> tuple[list[dict], list[str]]:
    current_evidence: list[dict] = []
    errors: list[str] = []
    for record in records:
        analysis_id = record.get("analysisID")
        provenance = record.get("portableTaskProvenance")
        if not isinstance(provenance, dict):
            errors.append(f"analysis {analysis_id}: portable-task provenance is missing")
            continue
        if provenance.get("status") == "LOCAL SAME-DEVICE LABELING — no portable task":
            current_evidence.append({"analysisID": analysis_id, "status": "LOCAL SAME-DEVICE LABELING"})
            continue
        if not str(provenance.get("status", "")).startswith("AUTHORIZED"):
            errors.append(f"analysis {analysis_id}: portable task coordinator was not authorized at assembly")
            continue
        coordinator_id = provenance.get("coordinatorPseudonym")
        entry = registry.get(coordinator_id)
        if entry is None:
            errors.append(f"analysis {analysis_id}: task coordinator is no longer active")
            continue
        if provenance.get("signerKeyID") != entry.get("signerKeyID"):
            errors.append(f"analysis {analysis_id}: current coordinator key differs from the assembled task")
            continue
        try:
            task_created = parse_iso8601(provenance.get("taskCreatedAt"))
            authorized_from = parse_iso8601(entry.get("authorizedFrom"))
            expires_at = parse_iso8601(entry.get("expiresAt"))
        except (TypeError, ValueError):
            errors.append(f"analysis {analysis_id}: task coordinator authorization timestamps are invalid")
            continue
        if not authorized_from <= task_created < expires_at:
            errors.append(f"analysis {analysis_id}: task falls outside the current coordinator authorization window")
            continue
        current_evidence.append({
            "analysisID": analysis_id,
            "taskID": provenance.get("taskID"),
            "taskSHA256": provenance.get("taskSHA256"),
            "coordinatorID": coordinator_id,
            "signerKeyID": entry.get("signerKeyID"),
            "taskCreatedAt": provenance.get("taskCreatedAt"),
        })
    return current_evidence, errors


def record_vector(record: dict, steps: int = RESAMPLED_STEPS) -> np.ndarray:
    sequence = record["featureEvidence"]["sequence"]
    frames = sequence["frames"]
    timestamps = np.asarray([frame["timestamp"] for frame in frames], dtype=np.float64)
    if len(frames) < 2 or not np.all(np.diff(timestamps) >= 0) or timestamps[-1] <= timestamps[0]:
        raise ValueError(f"analysis {record.get('analysisID')}: feature timestamps are invalid")
    frame_matrix = []
    for frame in frames:
        by_joint = {item["joint"]: item for item in frame["joints"]}
        if set(by_joint) != set(JOINTS):
            raise ValueError(f"analysis {record.get('analysisID')}: joint contract is incomplete")
        values = [float(frame["bodyConfidence"])]
        for joint in JOINTS:
            item = by_joint[joint]
            values.extend([
                float(item["x"]), float(item["y"]), float(item["confidence"]),
                1.0 if item["isPresent"] else 0.0,
            ])
        frame_matrix.append(values)
    matrix = np.asarray(frame_matrix, dtype=np.float64)
    targets = np.linspace(timestamps[0], timestamps[-1], steps)
    resampled = np.column_stack([
        np.interp(targets, timestamps, matrix[:, column])
        for column in range(matrix.shape[1])
    ])
    duration = float(sequence["duration"])
    context = np.asarray([
        min(duration, 45.0) / 45.0,
        1.0 if record["cameraAngle"] == "side" else 0.0,
        1.0 if record["cameraAngle"] == "rear" else 0.0,
    ])
    return np.concatenate([context, resampled.reshape(-1)])


def label_arrays(records: list[dict]) -> dict[str, np.ndarray]:
    count = len(records)
    usability = np.zeros((count, 1))
    phase_visibility = np.zeros((count, len(PHASES)))
    boundaries = np.zeros((count, len(PHASES) * 2))
    boundary_mask = np.zeros_like(boundaries)
    technique_visibility = np.zeros((count, len(TECHNIQUES)))
    ratings = np.zeros((count, len(TECHNIQUES)))
    rating_mask = np.zeros_like(ratings)
    priority = np.full(count, -1, dtype=np.int64)
    for row, record in enumerate(records):
        labels = record["labels"]
        usability[row, 0] = 1.0 if labels["isVideoUsable"] else 0.0
        duration = float(record["featureEvidence"]["sequence"]["duration"])
        for item in labels.get("phaseBoundaries") or []:
            if item.get("phase") not in PHASES:
                continue
            index = PHASES.index(item["phase"])
            if item.get("isVisible"):
                phase_visibility[row, index] = 1
                boundaries[row, index * 2] = float(item["startTime"]) / duration
                boundaries[row, index * 2 + 1] = float(item["endTime"]) / duration
                boundary_mask[row, index * 2:index * 2 + 2] = 1
        for item in labels.get("techniqueRatings") or []:
            if item.get("label") not in TECHNIQUES:
                continue
            index = TECHNIQUES.index(item["label"])
            if item.get("isVisible") and item.get("rating") is not None:
                technique_visibility[row, index] = 1
                ratings[row, index] = (float(item["rating"]) - 1) / 4
                rating_mask[row, index] = 1
        if labels.get("topPriority") in TECHNIQUES:
            priority[row] = TECHNIQUES.index(labels["topPriority"])
    return {
        "usability": usability,
        "phaseVisibility": phase_visibility,
        "boundaries": boundaries,
        "boundaryMask": boundary_mask,
        "techniqueVisibility": technique_visibility,
        "ratings": ratings,
        "ratingMask": rating_mask,
        "priority": priority,
    }


def standardize(train_x: np.ndarray, other: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    mean = train_x.mean(axis=0)
    scale = train_x.std(axis=0)
    scale[scale < 1e-6] = 1.0
    return (train_x - mean) / scale, (other - mean) / scale, mean, scale


def fit_ridge(x: np.ndarray, y: np.ndarray, l2: float = L2) -> tuple[np.ndarray, np.ndarray]:
    if not len(x):
        raise ValueError("cannot fit a model head without training examples")
    y = np.atleast_2d(y) if y.ndim == 1 else y
    if y.shape[0] != x.shape[0]:
        y = y.T
    intercept = y.mean(axis=0)
    centered = y - intercept
    dual = np.linalg.solve(x @ x.T + l2 * np.eye(len(x)), centered)
    return x.T @ dual, intercept


def fit_masked_heads(x: np.ndarray, y: np.ndarray, mask: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    weights = np.zeros((x.shape[1], y.shape[1]))
    intercepts = np.zeros(y.shape[1])
    for column in range(y.shape[1]):
        selected = mask[:, column] > 0
        if not np.any(selected):
            continue
        weight, intercept = fit_ridge(x[selected], y[selected, column:column + 1])
        weights[:, column] = weight[:, 0]
        intercepts[column] = intercept[0]
    return weights, intercepts


def train(records: list[dict]) -> dict:
    errors = validate_player_isolation(records)
    if errors:
        raise ValueError("; ".join(errors))
    by_split = {split: [record for record in records if record["split"] == split] for split in ("train", "validation", "test")}
    train_x_raw = np.stack([record_vector(record) for record in by_split["train"]])
    all_x_raw = np.stack([record_vector(record) for record in records])
    train_x, all_x, mean, scale = standardize(train_x_raw, all_x_raw)
    labels = label_arrays(records)
    train_indices = np.asarray([index for index, record in enumerate(records) if record["split"] == "train"])

    heads = {}
    for name in ("usability", "phaseVisibility", "techniqueVisibility"):
        heads[name] = fit_ridge(train_x, labels[name][train_indices])
    heads["boundaries"] = fit_masked_heads(train_x, labels["boundaries"][train_indices], labels["boundaryMask"][train_indices])
    heads["ratings"] = fit_masked_heads(train_x, labels["ratings"][train_indices], labels["ratingMask"][train_indices])
    priority_rows = labels["priority"][train_indices] >= 0
    priority_targets = np.eye(len(TECHNIQUES))[labels["priority"][train_indices][priority_rows]]
    heads["priority"] = fit_ridge(train_x[priority_rows], priority_targets)

    return {
        "records": records,
        "x": all_x,
        "labels": labels,
        "heads": heads,
        "mean": mean,
        "scale": scale,
        "splitCounts": {split: len(items) for split, items in by_split.items()},
    }


def predict(trained: dict) -> dict[str, np.ndarray]:
    x = trained["x"]
    output = {}
    for name, (weights, intercept) in trained["heads"].items():
        output[name] = x @ weights + intercept
    output["usability"] = np.clip(output["usability"], 0, 1)
    output["phaseVisibility"] = np.clip(output["phaseVisibility"], 0, 1)
    output["techniqueVisibility"] = np.clip(output["techniqueVisibility"], 0, 1)
    output["boundaries"] = np.clip(output["boundaries"], 0, 1)
    output["ratings"] = np.clip(output["ratings"], 0, 1)
    return output


def _binary_metrics(truth: np.ndarray, prediction: np.ndarray) -> dict[str, float]:
    truth = truth.astype(bool)
    prediction = prediction.astype(bool)
    tp = int(np.sum(truth & prediction))
    fp = int(np.sum(~truth & prediction))
    fn = int(np.sum(truth & ~prediction))
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"precision": precision, "recall": recall, "f1": f1}


def app_priority_predictions(
    priority_scores: np.ndarray,
    technique_visibility: np.ndarray,
) -> np.ndarray:
    """Mirror the native report's visible, actually-supported priority selection."""
    if priority_scores.shape != technique_visibility.shape:
        raise ValueError("priority and technique-visibility outputs must have the same shape")
    if priority_scores.ndim != 2 or priority_scores.shape[1] != len(TECHNIQUES):
        raise ValueError("priority outputs do not match the six-technique contract")
    supported = np.asarray([technique in APP_PRIORITY_TECHNIQUES for technique in TECHNIQUES])
    eligible = (technique_visibility >= 0.5) & supported[None, :]
    selected = np.full(priority_scores.shape[0], -1, dtype=np.int64)
    for row in range(priority_scores.shape[0]):
        indices = np.flatnonzero(eligible[row])
        if len(indices):
            selected[row] = int(indices[np.argmax(priority_scores[row, indices])])
    return selected


def evaluate(trained: dict, split: str, cohort: tuple[str, str] | None = None) -> dict:
    predictions = predict(trained)
    labels = trained["labels"]
    indices = np.asarray([
        index for index, record in enumerate(trained["records"])
        if record["split"] == split
        and (cohort is None or record.get("cohorts", {}).get(cohort[0]) == cohort[1])
    ])
    quality = _binary_metrics(labels["usability"][indices] >= 0.5, predictions["usability"][indices] >= 0.5)
    visibility = _binary_metrics(labels["phaseVisibility"][indices] >= 0.5, predictions["phaseVisibility"][indices] >= 0.5)
    boundary_mask = labels["boundaryMask"][indices] > 0
    durations = np.asarray([
        trained["records"][index]["featureEvidence"]["sequence"]["duration"] for index in indices
    ])[:, None]
    boundary_errors = np.abs(predictions["boundaries"][indices] - labels["boundaries"][indices]) * durations
    rating_mask = labels["ratingMask"][indices] > 0
    rating_errors = np.abs(predictions["ratings"][indices] - labels["ratings"][indices]) * 4
    priority_rows = labels["priority"][indices] >= 0
    priority_prediction = app_priority_predictions(
        predictions["priority"][indices],
        predictions["techniqueVisibility"][indices],
    )
    return {
        "clipCount": int(len(indices)),
        "playerCount": len({trained["records"][index]["participantPseudonym"] for index in indices}),
        "qualityPrecision": quality["precision"],
        "qualityRecall": quality["recall"],
        "qualityF1": quality["f1"],
        "phaseVisibilityPrecision": visibility["precision"],
        "phaseVisibilityRecall": visibility["recall"],
        "phaseVisibilityF1": visibility["f1"],
        "boundaryMeanAbsoluteErrorSeconds": float(boundary_errors[boundary_mask].mean()) if np.any(boundary_mask) else None,
        "techniqueRatingMeanAbsoluteError": float(rating_errors[rating_mask].mean()) if np.any(rating_mask) else None,
        "priorityAgreement": float(np.mean(priority_prediction[priority_rows] == labels["priority"][indices][priority_rows])) if np.any(priority_rows) else 0.0,
        "priorityContract": "native visible supported-technique argmax; unsupported or invisible priorities count as disagreement",
        "repeatabilityWithinFivePoints": None,
    }


def serialize_head(head: tuple[np.ndarray, np.ndarray]) -> dict:
    weights, intercept = head
    return {"weights": weights.tolist(), "intercept": intercept.tolist()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--consent-registry", type=Path, required=True)
    parser.add_argument("--task-coordinator-registry", type=Path, required=True)
    parser.add_argument("--consent-ledger", type=Path, required=True)
    parser.add_argument(
        "--consent-receipts",
        nargs="+",
        type=Path,
        required=True,
        help="Authoritative complete signed consent receipt set",
    )
    parser.add_argument("--model-output", type=Path, default=Path("Training/artifacts/temporal_baseline.json"))
    parser.add_argument("--evaluation-output", type=Path, default=Path("Training/artifacts/temporal_baseline_evaluation.json"))
    args = parser.parse_args()
    try:
        dataset = load_dataset(args.dataset)
        records = dataset.get("records") or []
        task_coordinator_registry = load_verified_task_coordinator_registry(
            args.task_coordinator_registry,
            require_task_coordinator_registry_secret(),
        )
        current_task_evidence, task_errors = verify_temporal_task_coordinators(
            records, task_coordinator_registry
        )
        if task_errors:
            raise ValueError("; ".join(task_errors))
        consent_registry = load_verified_consent_registry(
            args.consent_registry,
            require_consent_registry_secret(),
        )
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
        current_consent_evidence, consent_errors = verify_temporal_dataset_consent(
            records, consent_records
        )
        if consent_errors:
            raise ValueError("; ".join(consent_errors))
        trained = train(records)
        validation = evaluate(trained, "validation")
        test = evaluate(trained, "test")
    except (
        ConsentAuthorizationError,
        TaskCoordinatorAuthorizationError,
        KeyError,
        ValueError,
        np.linalg.LinAlgError,
    ) as error:
        print(f"Temporal baseline training stopped: {error}")
        return 1

    criteria = {
        "minimumHeldOutClipCount": 60,
        "minimumHeldOutPlayerCount": 10,
        "minimumQualityPrecision": 0.90,
        "minimumQualityRecall": 0.90,
        "maximumBoundaryMeanAbsoluteErrorSeconds": 0.12,
        "minimumPhaseVisibilityF1": 0.85,
        "maximumTechniqueRatingMeanAbsoluteError": 0.60,
        "minimumPriorityAgreement": 0.75,
        "minimumRepeatabilityWithinFivePoints": 0.90,
    }
    required_subgroup_dimensions = (
        "cameraAngle", "skillLevel", "dominantHand", "lighting", "resolution", "frameRate",
    )
    subgroup_reports: dict[str, dict[str, dict]] = {}
    failed_material_subgroups: list[str] = []
    for dimension in required_subgroup_dimensions:
        values = sorted({
            record.get("cohorts", {}).get(dimension)
            for record in records if record["split"] == "test" and record.get("cohorts", {}).get(dimension)
        })
        subgroup_reports[dimension] = {}
        for value in values:
            metrics = evaluate(trained, "test", (dimension, value))
            subgroup_reports[dimension][value] = metrics
            if metrics["clipCount"] < 5 or metrics["playerCount"] < 3:
                failed_material_subgroups.append(f"{dimension}={value}")
                continue
            subgroup_passes = (
                metrics["qualityPrecision"] >= criteria["minimumQualityPrecision"]
                and metrics["qualityRecall"] >= criteria["minimumQualityRecall"]
                and metrics["boundaryMeanAbsoluteErrorSeconds"] is not None
                and metrics["boundaryMeanAbsoluteErrorSeconds"] <= criteria["maximumBoundaryMeanAbsoluteErrorSeconds"]
                and metrics["phaseVisibilityF1"] >= criteria["minimumPhaseVisibilityF1"]
                and metrics["techniqueRatingMeanAbsoluteError"] is not None
                and metrics["techniqueRatingMeanAbsoluteError"] <= criteria["maximumTechniqueRatingMeanAbsoluteError"]
                and metrics["priorityAgreement"] >= criteria["minimumPriorityAgreement"]
            )
            if not subgroup_passes:
                failed_material_subgroups.append(f"{dimension}={value}")
    missing_subgroup_dimensions = [
        dimension for dimension in required_subgroup_dimensions
        if len(subgroup_reports[dimension]) < 2
    ]

    offline_comparisons = (
        (test["clipCount"] >= criteria["minimumHeldOutClipCount"], "held-out clip count"),
        (test["playerCount"] >= criteria["minimumHeldOutPlayerCount"], "held-out player count"),
        (test["qualityPrecision"] >= criteria["minimumQualityPrecision"], "recording-quality precision"),
        (test["qualityRecall"] >= criteria["minimumQualityRecall"], "recording-quality recall"),
        (test["boundaryMeanAbsoluteErrorSeconds"] is not None and test["boundaryMeanAbsoluteErrorSeconds"] <= criteria["maximumBoundaryMeanAbsoluteErrorSeconds"], "phase-boundary timing"),
        (test["phaseVisibilityF1"] >= criteria["minimumPhaseVisibilityF1"], "phase visibility"),
        (test["techniqueRatingMeanAbsoluteError"] is not None and test["techniqueRatingMeanAbsoluteError"] <= criteria["maximumTechniqueRatingMeanAbsoluteError"], "technique rating agreement"),
        (test["priorityAgreement"] >= criteria["minimumPriorityAgreement"], "coach priority agreement"),
        (not missing_subgroup_dimensions, "subgroup coverage"),
        (not failed_material_subgroups, "subgroup performance"),
    )
    offline_failed = [label for passed, label in offline_comparisons if not passed]
    failed = offline_failed + [
        "end-to-end repeatability not evaluated",
        "Core ML parity not yet evaluated",
    ]

    model = {
        "schemaVersion": 1,
        "modelIdentifier": "serveai.temporal-pose-baseline",
        "modelVersion": "0.1.0-research",
        "featureSchemaVersion": 2,
        "resampledSteps": RESAMPLED_STEPS,
        "jointOrder": JOINTS,
        "phaseOrder": PHASES,
        "techniqueOrder": TECHNIQUES,
        "normalizationMean": trained["mean"].tolist(),
        "normalizationScale": trained["scale"].tolist(),
        "heads": {name: serialize_head(head) for name, head in trained["heads"].items()},
        "trainingDatasetDigest": dataset.get("datasetDigest"),
        "rubricContract": CURRENT_RUBRIC_BINDING,
        "capturePlanContract": CURRENT_CAPTURE_PLAN_BINDING,
        "trainingTimeConsentLedger": consent_ledger_evidence,
        "trainingTimeConsentEvidenceDigest": hashlib.sha256(
            json.dumps(current_consent_evidence, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
        "trainingTimeTaskCoordinatorRegistry": {
            "registryID": json.loads(args.task_coordinator_registry.read_text()).get("registryID"),
            "registrySHA256": hashlib.sha256(args.task_coordinator_registry.read_bytes()).hexdigest(),
        },
        "trainingTimeTaskCoordinatorEvidenceDigest": hashlib.sha256(
            json.dumps(current_task_evidence, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest(),
        "releaseEligible": False,
    }
    evaluation = {
        "schemaVersion": 1,
        "modelIdentifier": model["modelIdentifier"],
        "modelVersion": model["modelVersion"],
        "trainingDatasetDigest": dataset.get("datasetDigest"),
        "rubricContract": CURRENT_RUBRIC_BINDING,
        "capturePlanContract": CURRENT_CAPTURE_PLAN_BINDING,
        "splitPolicy": "player-isolated splits supplied by the signed temporal dataset",
        "splitCounts": trained["splitCounts"],
        "trainingTimeConsentLedger": consent_ledger_evidence,
        "trainingTimeTaskCoordinatorRegistry": model["trainingTimeTaskCoordinatorRegistry"],
        "validation": validation,
        "test": test,
        "subgroups": subgroup_reports,
        "missingSubgroupDimensions": missing_subgroup_dimensions,
        "failedMaterialSubgroups": failed_material_subgroups,
        "acceptanceCriteria": criteria,
        "failedCriteria": failed,
        "passesOfflineMetricSubset": not offline_failed,
        "releaseEligible": False,
        "releaseReason": "Offline training cannot establish app-level repeatability, subgroup safety, or Core ML parity.",
    }
    args.model_output.parent.mkdir(parents=True, exist_ok=True)
    args.evaluation_output.parent.mkdir(parents=True, exist_ok=True)
    args.model_output.write_text(json.dumps(model, indent=2) + "\n")
    args.evaluation_output.write_text(json.dumps(evaluation, indent=2, allow_nan=False) + "\n")
    print(f"wrote research-only temporal baseline to {args.model_output}")
    print(f"wrote player-held-out evaluation to {args.evaluation_output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
