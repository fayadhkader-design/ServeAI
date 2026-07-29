#!/usr/bin/env python3
"""Distill the transparent pseudo-coach rules into a research-only model.

The reported metrics are teacher-agreement metrics on time blocks from the same
athlete. They do not measure tennis-coaching accuracy or new-player
generalization, and the resulting artifact is never release eligible.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from train_temporal_baseline import (
    JOINTS,
    PHASES,
    RESAMPLED_STEPS,
    TECHNIQUES,
    evaluate,
    fit_ridge,
    label_arrays,
    record_vector,
    serialize_head,
    standardize,
)


ROOT = Path(__file__).resolve().parent
DEFAULT_DATASET = ROOT / "artifacts/pseudo_coach_dataset.json"
DEFAULT_MODEL = ROOT / "artifacts/pseudo_coach_model.json"
DEFAULT_EVALUATION = ROOT / "artifacts/pseudo_coach_evaluation.json"
L2_GRID = (0.1, 1.0, 8.0, 32.0, 128.0)


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def load_pseudo_dataset(path: Path) -> dict:
    payload = json.loads(path.read_text())
    if payload.get("schemaVersion") != 1 or payload.get("datasetIdentifier") != "serveai.pseudo-coach-temporal":
        raise ValueError("input is not a ServeAI pseudo-coach dataset")
    if payload.get("groundTruthEligible") is not False or payload.get("modelReleaseEligible") is not False:
        raise ValueError("pseudo dataset contains an invalid eligibility claim")
    records = payload.get("records") or []
    if not records or any(record.get("pseudoLabelProvenance", {}).get("coachVerified") is not False for record in records):
        raise ValueError("every pseudo record must explicitly state coachVerified=false")
    digest = hashlib.sha256(canonical_json(records)).hexdigest()
    if payload.get("datasetDigest") != digest:
        raise ValueError("pseudo dataset digest does not match its records")
    split_counts = {split: sum(record.get("split") == split for record in records) for split in ("train", "validation", "test")}
    if any(count == 0 for count in split_counts.values()):
        raise ValueError("pseudo dataset must contain train, validation, and test time blocks")
    participants = {record.get("participantPseudonym") for record in records}
    if len(participants) != 1:
        raise ValueError("this research protocol expects the documented single-athlete source")
    return payload


def fit_masked_heads(
    x: np.ndarray,
    y: np.ndarray,
    mask: np.ndarray,
    l2: float,
) -> tuple[np.ndarray, np.ndarray]:
    weights = np.zeros((x.shape[1], y.shape[1]))
    intercepts = np.zeros(y.shape[1])
    for column in range(y.shape[1]):
        selected = mask[:, column] > 0
        if not np.any(selected):
            continue
        weight, intercept = fit_ridge(x[selected], y[selected, column:column + 1], l2=l2)
        weights[:, column] = weight[:, 0]
        intercepts[column] = intercept[0]
    return weights, intercepts


def fit_candidate(records: list[dict], l2: float) -> dict:
    train_records = [record for record in records if record["split"] == "train"]
    train_x_raw = np.stack([record_vector(record) for record in train_records])
    all_x_raw = np.stack([record_vector(record) for record in records])
    train_x, all_x, mean, scale = standardize(train_x_raw, all_x_raw)
    labels = label_arrays(records)
    train_indices = np.asarray([index for index, record in enumerate(records) if record["split"] == "train"])

    heads = {}
    for name in ("usability", "phaseVisibility", "techniqueVisibility"):
        heads[name] = fit_ridge(train_x, labels[name][train_indices], l2=l2)
    heads["boundaries"] = fit_masked_heads(
        train_x,
        labels["boundaries"][train_indices],
        labels["boundaryMask"][train_indices],
        l2,
    )
    heads["ratings"] = fit_masked_heads(
        train_x,
        labels["ratings"][train_indices],
        labels["ratingMask"][train_indices],
        l2,
    )
    priority_rows = labels["priority"][train_indices] >= 0
    if not np.any(priority_rows):
        raise ValueError("training block has no pseudo priority labels")
    priority_targets = np.eye(len(TECHNIQUES))[labels["priority"][train_indices][priority_rows]]
    heads["priority"] = fit_ridge(train_x[priority_rows], priority_targets, l2=l2)
    return {
        "records": records,
        "x": all_x,
        "labels": labels,
        "heads": heads,
        "mean": mean,
        "scale": scale,
        "splitCounts": {split: sum(record["split"] == split for record in records) for split in ("train", "validation", "test")},
    }


def selection_loss(metrics: dict) -> float:
    boundary = metrics["boundaryMeanAbsoluteErrorSeconds"]
    rating = metrics["techniqueRatingMeanAbsoluteError"]
    if boundary is None or rating is None:
        return float("inf")
    return boundary + rating * 0.25 + (1.0 - metrics["priorityAgreement"]) * 0.50


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", nargs="?", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--model-output", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--evaluation-output", type=Path, default=DEFAULT_EVALUATION)
    args = parser.parse_args()
    try:
        dataset = load_pseudo_dataset(args.dataset)
        records = dataset["records"]
        candidates = []
        for l2 in L2_GRID:
            trained = fit_candidate(records, l2)
            validation = evaluate(trained, "validation")
            candidates.append((selection_loss(validation), l2, trained, validation))
        _, selected_l2, trained, validation = min(candidates, key=lambda item: (item[0], item[1]))
        test = evaluate(trained, "test")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError, np.linalg.LinAlgError) as error:
        print(f"Pseudo-coach training stopped: {error}")
        return 1

    model = {
        "schemaVersion": 1,
        "modelIdentifier": "serveai.temporal-pose-pseudo-coach",
        "modelVersion": "0.1.0-research",
        "featureSchemaVersion": 2,
        "resampledSteps": RESAMPLED_STEPS,
        "jointOrder": JOINTS,
        "phaseOrder": PHASES,
        "techniqueOrder": TECHNIQUES,
        "normalizationMean": trained["mean"].tolist(),
        "normalizationScale": trained["scale"].tolist(),
        "heads": {name: serialize_head(head) for name, head in trained["heads"].items()},
        "selectedL2": selected_l2,
        "trainingDatasetDigest": dataset["datasetDigest"],
        "teacherIdentifier": dataset["teacherIdentifier"],
        "teacherVersion": dataset["teacherVersion"],
        "coachVerified": False,
        "newPlayerGeneralizationEvaluated": False,
        "releaseEligible": False,
    }
    evaluation = {
        "schemaVersion": 1,
        "modelIdentifier": model["modelIdentifier"],
        "modelVersion": model["modelVersion"],
        "selectedL2": selected_l2,
        "hyperparameterSelection": [
            {
                "l2": l2,
                "validationSelectionLoss": loss,
                "validation": metrics,
            }
            for loss, l2, _, metrics in candidates
        ],
        "splitPolicy": dataset["splitPolicy"],
        "splitCounts": trained["splitCounts"],
        "validationTeacherAgreement": validation,
        "testTeacherAgreement": test,
        "coachingAccuracyMeasured": False,
        "newPlayerGeneralizationEvaluated": False,
        "passesProductionAccuracyGates": False,
        "releaseEligible": False,
        "releaseReason": (
            "The test block measures agreement with deterministic pseudo-label rules on the same athlete. "
            "It contains no independent coach labels and cannot establish coaching accuracy."
        ),
    }
    args.model_output.parent.mkdir(parents=True, exist_ok=True)
    args.evaluation_output.parent.mkdir(parents=True, exist_ok=True)
    args.model_output.write_text(json.dumps(model, indent=2, allow_nan=False) + "\n")
    args.evaluation_output.write_text(json.dumps(evaluation, indent=2, allow_nan=False) + "\n")
    print(f"wrote pseudo-coach research model to {args.model_output}")
    print(f"wrote same-athlete teacher-agreement evaluation to {args.evaluation_output}")
    print("releaseEligible=false; coachingAccuracyMeasured=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
