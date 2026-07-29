#!/usr/bin/env python3
"""Train a player-isolated research model on THETIS pseudo-coach labels."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np

from train_pseudo_coach_baseline import L2_GRID, fit_candidate, selection_loss
from train_temporal_baseline import (
    JOINTS,
    PHASES,
    RESAMPLED_STEPS,
    TECHNIQUES,
    evaluate,
    serialize_head,
    validate_player_isolation,
)


ROOT = Path(__file__).resolve().parent
DEFAULT_DATASET = ROOT / "artifacts/thetis_pseudo_coach_dataset.json"
DEFAULT_MODEL = ROOT / "artifacts/thetis_pseudo_coach_model.json"
DEFAULT_EVALUATION = ROOT / "artifacts/thetis_pseudo_coach_evaluation.json"


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def load_dataset(path: Path) -> dict:
    payload = json.loads(path.read_text())
    if payload.get("schemaVersion") != 1 or payload.get("datasetIdentifier") != "serveai.thetis-pseudo-coach-temporal":
        raise ValueError("input is not the THETIS pseudo-coach dataset")
    if payload.get("groundTruthEligible") is not False or payload.get("modelReleaseEligible") is not False:
        raise ValueError("research dataset contains an invalid eligibility claim")
    if payload.get("sourceDataset", {}).get("productionUseAllowed") is not False:
        raise ValueError("source license restrictions were not preserved")
    records = payload.get("records") or []
    digest = hashlib.sha256(canonical_json(records)).hexdigest()
    if digest != payload.get("datasetDigest"):
        raise ValueError("dataset digest does not match its records")
    if len(records) < 300:
        raise ValueError("fewer than 300 usable research clips remain")
    if len({record["participantPseudonym"] for record in records}) < 40:
        raise ValueError("fewer than 40 players remain")
    isolation_errors = validate_player_isolation(records)
    if isolation_errors:
        raise ValueError("; ".join(isolation_errors))
    if any(record.get("pseudoLabelProvenance", {}).get("coachVerified") is not False for record in records):
        raise ValueError("every record must explicitly state coachVerified=false")
    return payload


def metric_failures(metrics: dict) -> list[str]:
    checks = (
        (metrics["clipCount"] >= 60, "held-out clip count"),
        (metrics["playerCount"] >= 10, "held-out player count"),
        (metrics["qualityPrecision"] >= 0.90, "recording-quality precision"),
        (metrics["qualityRecall"] >= 0.90, "recording-quality recall"),
        (
            metrics["boundaryMeanAbsoluteErrorSeconds"] is not None
            and metrics["boundaryMeanAbsoluteErrorSeconds"] <= 0.12,
            "phase-boundary timing",
        ),
        (metrics["phaseVisibilityF1"] >= 0.85, "phase visibility"),
        (
            metrics["techniqueRatingMeanAbsoluteError"] is not None
            and metrics["techniqueRatingMeanAbsoluteError"] <= 0.60,
            "technique rating agreement",
        ),
        (metrics["priorityAgreement"] >= 0.75, "priority agreement"),
    )
    return [label for passed, label in checks if not passed]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset", nargs="?", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--model-output", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--evaluation-output", type=Path, default=DEFAULT_EVALUATION)
    args = parser.parse_args()
    try:
        dataset = load_dataset(args.dataset)
        records = dataset["records"]
        candidates = []
        for l2 in L2_GRID:
            trained = fit_candidate(records, l2)
            validation = evaluate(trained, "validation")
            candidates.append((selection_loss(validation), l2, trained, validation))
        _, selected_l2, trained, validation = min(candidates, key=lambda item: (item[0], item[1]))
        test = evaluate(trained, "test")
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError, np.linalg.LinAlgError) as error:
        print(f"THETIS research training stopped: {error}")
        return 1

    pseudo_metric_failures = metric_failures(test)
    model = {
        "schemaVersion": 1,
        "modelIdentifier": "serveai.thetis-pseudo-coach",
        "modelVersion": "0.2.0-research",
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
        "sourceRepositoryCommit": dataset["sourceDataset"]["repositoryCommit"],
        "teacherIdentifier": dataset["teacherIdentifier"],
        "teacherVersion": dataset["teacherVersion"],
        "coachVerified": False,
        "playerHeldOutPseudoTeacherEvaluation": True,
        "sideRearViewEvaluation": False,
        "commercialUseCleared": False,
        "releaseEligible": False,
    }
    evaluation = {
        "schemaVersion": 1,
        "modelIdentifier": model["modelIdentifier"],
        "modelVersion": model["modelVersion"],
        "selectedL2": selected_l2,
        "hyperparameterSelection": [
            {"l2": l2, "validationSelectionLoss": loss, "validation": metrics}
            for loss, l2, _, metrics in candidates
        ],
        "splitPolicy": dataset["splitPolicy"],
        "splitCounts": trained["splitCounts"],
        "playerCounts": dataset["playerCounts"],
        "validationPseudoTeacherAgreement": validation,
        "testPseudoTeacherAgreement": test,
        "pseudoTeacherMetricFailures": pseudo_metric_failures,
        "passesPseudoTeacherMetricSubset": not pseudo_metric_failures,
        "coachingAccuracyMeasured": False,
        "newPlayerPseudoTeacherAgreementEvaluated": True,
        "sideRearViewEvaluation": False,
        "commercialUseCleared": False,
        "passesProductionAccuracyGates": False,
        "releaseEligible": False,
        "releaseReason": (
            "Player-held-out results measure agreement with deterministic pseudo-label rules on frontal, "
            "staged, no-ball research footage. No independent coach ground truth, supported side/rear view "
            "evaluation, app repeatability study, or commercial training grant is present."
        ),
    }
    args.model_output.parent.mkdir(parents=True, exist_ok=True)
    args.evaluation_output.parent.mkdir(parents=True, exist_ok=True)
    args.model_output.write_text(json.dumps(model, indent=2, allow_nan=False) + "\n")
    args.evaluation_output.write_text(json.dumps(evaluation, indent=2, allow_nan=False) + "\n")
    print(f"wrote player-isolated research model to {args.model_output}")
    print(f"wrote pseudo-teacher evaluation to {args.evaluation_output}")
    print(f"test={test}; releaseEligible=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
