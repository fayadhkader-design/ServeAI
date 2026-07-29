#!/usr/bin/env python3
"""Build the native release-evaluation document from frozen evidence.

This stage computes release fields; it does not accept caller-supplied pass
booleans. Structurally incomplete evidence is rejected without output. Complete
evidence that misses a metric produces a fail-closed report the signer refuses.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Any

from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import (
    CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING,
    validate_record_provenance,
)
from sign_validated_model_release import (
    REQUIRED_CAMERA_ANGLES,
    REQUIRED_SKILL_GROUPS,
    REQUIRED_SUBGROUPS,
    ReleaseGateError,
    read_json,
    rights_failures,
    sha256_artifact,
)


PRIORITY_CONTRACT = (
    "native visible supported-technique argmax; unsupported or invisible priorities count as disagreement"
)
SUBGROUP_NAME_MAP = {
    "cameraAngle": "cameraAngle",
    "skillLevel": "skillGroup",
    "dominantHand": "handedness",
    "lighting": "lighting",
    "resolution": "resolution",
    "frameRate": "frameRate",
}
MINIMUMS = {
    "qualityPrecision": 0.90,
    "qualityRecall": 0.90,
    "phaseVisibilityF1": 0.85,
    "priorityAgreement": 0.75,
    "repeatabilityWithinFivePoints": 0.90,
}
MAXIMUMS = {
    "boundaryMeanAbsoluteErrorSeconds": 0.12,
    "techniqueRatingMeanAbsoluteError": 0.60,
}


class EvaluationEvidenceError(ValueError):
    pass


def canonical_digest(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(document: dict[str, Any], path: str) -> Any:
    value: Any = document
    for component in path.split("."):
        if not isinstance(value, dict) or component not in value:
            raise EvaluationEvidenceError(f"missing required field: {path}")
        value = value[component]
    return value


def finite(document: dict[str, Any], path: str) -> float:
    value = require(document, path)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise EvaluationEvidenceError(f"field must be a finite number: {path}")
    return float(value)


def validate_identity(identity: tuple[str, str], document: dict[str, Any], name: str) -> None:
    if (document.get("modelIdentifier"), document.get("modelVersion")) != identity:
        raise EvaluationEvidenceError(f"{name} model identity does not match")


def validate_dataset(dataset: dict[str, Any], expected_digest: str) -> dict[str, Any]:
    if dataset.get("schemaVersion") != 3 or dataset.get("trainingEligible") is not True:
        raise EvaluationEvidenceError("dataset is not an eligible assembled temporal artifact")
    if dataset.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise EvaluationEvidenceError("dataset is not bound to the current coach rubric")
    if dataset.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise EvaluationEvidenceError("dataset is not bound to the frozen capture plan")
    if dataset.get("modelReleaseEligible") is not False:
        raise EvaluationEvidenceError("dataset contains an invalid model-release claim")
    records = dataset.get("records")
    if not isinstance(records, list) or not records:
        raise EvaluationEvidenceError("dataset records are missing")
    digest = canonical_digest(records)
    if dataset.get("datasetDigest") != digest or digest != expected_digest:
        raise EvaluationEvidenceError("dataset digest does not match the trained model")

    analysis_ids: set[str] = set()
    video_hashes: set[str] = set()
    player_splits: dict[str, set[str]] = {}
    observed_splits: set[str] = set()
    for record in records:
        if record.get("rubric") != CURRENT_RUBRIC_BINDING:
            raise EvaluationEvidenceError("one or more records are not bound to the current coach rubric")
        capture_errors = validate_record_provenance(record)
        if capture_errors:
            raise EvaluationEvidenceError(
                "one or more records have invalid capture-plan provenance: " + capture_errors[0]
            )
        analysis_id = record.get("analysisID")
        video_hash = record.get("sourceVideoSHA256")
        participant = record.get("participantPseudonym")
        split = record.get("split")
        if not analysis_id or analysis_id in analysis_ids:
            raise EvaluationEvidenceError("dataset analysis IDs must be present and unique")
        if (
            not isinstance(video_hash, str)
            or len(video_hash) != 64
            or any(character not in "0123456789abcdef" for character in video_hash)
            or video_hash in video_hashes
        ):
            raise EvaluationEvidenceError("dataset video hashes must be valid and unique")
        if not participant or split not in {"train", "validation", "test"}:
            raise EvaluationEvidenceError("dataset participant/split provenance is incomplete")
        analysis_ids.add(analysis_id)
        video_hashes.add(video_hash)
        observed_splits.add(split)
        player_splits.setdefault(participant, set()).add(split)
    if any(len(splits) != 1 for splits in player_splits.values()):
        raise EvaluationEvidenceError("dataset contains player leakage across splits")
    if observed_splits != {"train", "validation", "test"}:
        raise EvaluationEvidenceError("dataset must contain nonempty train, validation, and test splits")

    test_records = [record for record in records if record.get("split") == "test"]
    if not test_records:
        raise EvaluationEvidenceError("held-out test split is empty")
    coach_ground_truth = True
    adjudication_policy = True
    consent_complete = True
    provenance_complete = True
    for record in test_records:
        label = record.get("labelProvenance") or {}
        source_coaches = label.get("sourceCoachIDs") or []
        kind = label.get("kind")
        coach_ground_truth &= len(source_coaches) == 2 and len(set(source_coaches)) == 2
        if kind == "signedThirdCoachAdjudication":
            adjudicator = label.get("adjudicatorPseudonym")
            adjudication_policy &= bool(adjudicator) and adjudicator not in source_coaches
        elif kind != "exactDoubleCoachAgreement":
            adjudication_policy = False
        consent = record.get("consentProvenance") or {}
        consent_complete &= bool(consent.get("consentRecordID") and consent.get("consentReceiptID"))
        portable = record.get("portableTaskProvenance") or {}
        portable_status = str(portable.get("status", ""))
        provenance_complete &= (
            bool(record.get("featureEvidenceDigest"))
            and portable_status.startswith(("AUTHORIZED", "LOCAL SAME-DEVICE LABELING"))
        )
    return {
        "records": records,
        "testRecords": test_records,
        "coachGroundTruthVerified": coach_ground_truth,
        "independentAdjudicationPolicyVerified": adjudication_policy,
        "allClipsHaveTrainingConsent": consent_complete,
        "provenanceVerified": provenance_complete,
    }


def validate_offline_evaluation(
    offline: dict[str, Any],
    identity: tuple[str, str],
    dataset_digest: str,
    test_records: list[dict[str, Any]],
) -> tuple[dict[str, float], list[str], list[str]]:
    if offline.get("schemaVersion") != 1:
        raise EvaluationEvidenceError("offline evaluation schema is unsupported")
    if offline.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise EvaluationEvidenceError("offline evaluation is not bound to the current coach rubric")
    if offline.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise EvaluationEvidenceError("offline evaluation is not bound to the frozen capture plan")
    validate_identity(identity, offline, "offline evaluation")
    if offline.get("trainingDatasetDigest") != dataset_digest:
        raise EvaluationEvidenceError("offline evaluation is not bound to the assembled dataset")
    test = require(offline, "test")
    if test.get("priorityContract") != PRIORITY_CONTRACT:
        raise EvaluationEvidenceError("offline priority metric does not match the native app contract")
    test_players = {record["participantPseudonym"] for record in test_records}
    if test.get("clipCount") != len(test_records) or test.get("playerCount") != len(test_players):
        raise EvaluationEvidenceError("offline test counts do not match the frozen dataset")
    metrics = {
        "qualityPrecision": finite(test, "qualityPrecision"),
        "qualityRecall": finite(test, "qualityRecall"),
        "boundaryMeanAbsoluteErrorSeconds": finite(test, "boundaryMeanAbsoluteErrorSeconds"),
        "phaseVisibilityF1": finite(test, "phaseVisibilityF1"),
        "techniqueRatingMeanAbsoluteError": finite(test, "techniqueRatingMeanAbsoluteError"),
        "priorityAgreement": finite(test, "priorityAgreement"),
    }
    subgroup_reports = require(offline, "subgroups")
    audited: list[str] = []
    computed_failures: list[str] = []
    for source_name, release_name in SUBGROUP_NAME_MAP.items():
        report = subgroup_reports.get(source_name)
        expected_values: dict[str, list[dict[str, Any]]] = {}
        for record in test_records:
            cohort_value = (record.get("cohorts") or {}).get(source_name)
            if not isinstance(cohort_value, str) or not cohort_value:
                raise EvaluationEvidenceError(f"dataset lacks {source_name} cohort provenance")
            expected_values.setdefault(cohort_value, []).append(record)
        if not isinstance(report, dict) or set(report) != set(expected_values) or len(report) < 2:
            raise EvaluationEvidenceError(f"offline {source_name} subgroup coverage does not match the dataset")
        audited.append(release_name)
        for cohort_value, cohort_records in expected_values.items():
            cohort = report.get(cohort_value)
            if not isinstance(cohort, dict):
                raise EvaluationEvidenceError(f"offline subgroup {source_name}={cohort_value} is malformed")
            expected_players = {record["participantPseudonym"] for record in cohort_records}
            if cohort.get("clipCount") != len(cohort_records) or cohort.get("playerCount") != len(expected_players):
                raise EvaluationEvidenceError(
                    f"offline subgroup {source_name}={cohort_value} counts do not match the dataset"
                )
            if cohort.get("priorityContract") != PRIORITY_CONTRACT:
                raise EvaluationEvidenceError(
                    f"offline subgroup {source_name}={cohort_value} priority contract is invalid"
                )
            cohort_metrics = {
                "qualityPrecision": finite(cohort, "qualityPrecision"),
                "qualityRecall": finite(cohort, "qualityRecall"),
                "boundaryMeanAbsoluteErrorSeconds": finite(cohort, "boundaryMeanAbsoluteErrorSeconds"),
                "phaseVisibilityF1": finite(cohort, "phaseVisibilityF1"),
                "techniqueRatingMeanAbsoluteError": finite(cohort, "techniqueRatingMeanAbsoluteError"),
                "priorityAgreement": finite(cohort, "priorityAgreement"),
            }
            material = len(cohort_records) >= 5 and len(expected_players) >= 3
            passes = (
                material
                and all(cohort_metrics[name] >= threshold for name, threshold in MINIMUMS.items() if name in cohort_metrics)
                and all(cohort_metrics[name] <= threshold for name, threshold in MAXIMUMS.items())
            )
            if not passes:
                computed_failures.append(f"{source_name}={cohort_value}")
    declared_failures = offline.get("failedMaterialSubgroups")
    if not isinstance(declared_failures, list) or any(not isinstance(item, str) for item in declared_failures):
        raise EvaluationEvidenceError("offline failed-material-subgroup declaration is malformed")
    failed_subgroups = sorted(set(declared_failures) | set(computed_failures))
    return metrics, audited, failed_subgroups


def validate_repeatability(
    report: dict[str, Any],
    identity: tuple[str, str],
    model_hash: str,
    test_records: list[dict[str, Any]],
) -> dict[str, Any]:
    if report.get("schemaVersion") != 1:
        raise EvaluationEvidenceError("repeatability report schema is unsupported")
    if report.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise EvaluationEvidenceError("repeatability report is not bound to the current coach rubric")
    if report.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise EvaluationEvidenceError("repeatability report is not bound to the frozen capture plan")
    validate_identity(identity, report, "repeatability report")
    if report.get("modelSHA256") != model_hash or not report.get("appBuildIdentifier"):
        raise EvaluationEvidenceError("repeatability report is not bound to the model and app build")
    if report.get("protocol") != "same compiled model, app build, settings, and exact source video analyzed twice":
        raise EvaluationEvidenceError("repeatability protocol is not the required exact-video protocol")
    by_analysis = {record["analysisID"]: record for record in test_records}
    pairs = report.get("pairs")
    if not isinstance(pairs, list) or not pairs:
        raise EvaluationEvidenceError("repeatability pairs are missing")
    seen: set[str] = set()
    within_five = 0
    players: set[str] = set()
    exact_source_binding = True
    for pair in pairs:
        analysis_id = pair.get("analysisID")
        record = by_analysis.get(analysis_id)
        if record is None or analysis_id in seen:
            raise EvaluationEvidenceError("repeatability pairs must uniquely reference held-out analyses")
        first, second = pair.get("firstScore"), pair.get("repeatedScore")
        if (
            not isinstance(first, int) or isinstance(first, bool) or not 0 <= first <= 100
            or not isinstance(second, int) or isinstance(second, bool) or not 0 <= second <= 100
        ):
            raise EvaluationEvidenceError("repeatability scores must be integer values from 0 to 100")
        exact_source_binding &= (
            pair.get("sourceVideoSHA256") == record.get("sourceVideoSHA256")
            and pair.get("participantPseudonym") == record.get("participantPseudonym")
            and pair.get("cameraAngle") == record.get("cameraAngle")
            and pair.get("skillLevel") == record.get("skillLevel")
        )
        seen.add(analysis_id)
        players.add(record["participantPseudonym"])
        within_five += abs(first - second) <= 5
    return {
        "pairCount": len(pairs),
        "playerCount": len(players),
        "usesExactSameVideo": exact_source_binding,
        "withinFivePoints": within_five / len(pairs),
    }


def validate_parity(
    report: dict[str, Any], identity: tuple[str, str], model_hash: str
) -> dict[str, Any]:
    if report.get("schemaVersion") != 2:
        raise EvaluationEvidenceError("Core ML parity report schema is unsupported")
    if report.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise EvaluationEvidenceError("Core ML parity report is not bound to the current coach rubric")
    if report.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise EvaluationEvidenceError("Core ML parity report is not bound to the frozen capture plan")
    validate_identity(identity, report, "Core ML parity report")
    if report.get("compiledModelSHA256") != model_hash:
        raise EvaluationEvidenceError("Core ML parity report does not match the compiled model")
    maximum_error = finite(report, "maximumAbsoluteError")
    sample_count = int(finite(report, "sampleCount"))
    return {
        "maximumError": maximum_error,
        "sampleCount": sample_count,
        "passes": report.get("passes") is True and maximum_error <= 0.0001 and sample_count >= 60,
    }


def build_evaluation(
    *,
    compiled_model_path: Path,
    research_model_path: Path,
    dataset_path: Path,
    offline_evaluation_path: Path,
    repeatability_path: Path | None,
    parity_path: Path,
    rights_path: Path,
    repeatability_document: dict[str, Any] | None = None,
) -> dict[str, Any]:
    model_hash = sha256_artifact(compiled_model_path)
    research_model = read_json(research_model_path)
    if research_model.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise EvaluationEvidenceError("research model is not bound to the current coach rubric")
    if research_model.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise EvaluationEvidenceError("research model is not bound to the frozen capture plan")
    identity = (research_model.get("modelIdentifier"), research_model.get("modelVersion"))
    if not all(identity):
        raise EvaluationEvidenceError("research model identity is missing")
    dataset_digest = research_model.get("trainingDatasetDigest")
    if not isinstance(dataset_digest, str) or len(dataset_digest) != 64:
        raise EvaluationEvidenceError("research model training dataset digest is missing")

    dataset = read_json(dataset_path)
    dataset_evidence = validate_dataset(dataset, dataset_digest)
    offline = read_json(offline_evaluation_path)
    offline_metrics, audited, failed_subgroups = validate_offline_evaluation(
        offline, identity, dataset_digest, dataset_evidence["testRecords"]
    )
    if (repeatability_path is None) == (repeatability_document is None):
        raise EvaluationEvidenceError(
            "provide exactly one repeatability report path or verified repeatability document"
        )
    raw_repeatability = (
        repeatability_document
        if repeatability_document is not None
        else read_json(repeatability_path)
    )
    repeatability = validate_repeatability(
        raw_repeatability, identity, model_hash, dataset_evidence["testRecords"]
    )
    parity = validate_parity(read_json(parity_path), identity, model_hash)
    rights = read_json(rights_path)
    validate_identity(identity, rights, "rights evidence")
    rights_ok = not rights_failures(rights)

    metrics = {**offline_metrics, "repeatabilityWithinFivePoints": repeatability["withinFivePoints"]}
    test_records = dataset_evidence["testRecords"]
    test_players = {record["participantPseudonym"] for record in test_records}
    camera_angles = sorted({record.get("cameraAngle") for record in test_records if record.get("cameraAngle")})
    skill_groups = sorted({record.get("skillLevel") for record in test_records if record.get("skillLevel")})
    design = {
        "heldOutClipCount": len(test_records),
        "uniquePlayerCount": len(test_players),
        "usesPlayerHeldOutSplit": True,
        "allClipsHaveTrainingConsent": dataset_evidence["allClipsHaveTrainingConsent"],
        "provenanceVerified": dataset_evidence["provenanceVerified"],
        "auditedSubgroupDimensions": sorted(audited),
        "failedMaterialSubgroups": failed_subgroups,
        "evaluatedCameraAngles": camera_angles,
        "evaluatedSkillGroups": skill_groups,
        "repeatabilityPairCount": repeatability["pairCount"],
        "repeatabilityPlayerCount": repeatability["playerCount"],
        "repeatabilityUsesExactSameVideo": repeatability["usesExactSameVideo"],
    }

    failures: list[str] = []
    if design["heldOutClipCount"] < 60: failures.append("held-out clip count")
    if design["uniquePlayerCount"] < 10: failures.append("held-out player count")
    if not dataset_evidence["coachGroundTruthVerified"]: failures.append("coach ground truth")
    if not dataset_evidence["independentAdjudicationPolicyVerified"]: failures.append("independent adjudication")
    if not design["allClipsHaveTrainingConsent"]: failures.append("training consent")
    if not design["provenanceVerified"]: failures.append("provenance")
    if not REQUIRED_SUBGROUPS.issubset(set(audited)): failures.append("subgroup coverage")
    if failed_subgroups: failures.append("subgroup performance")
    if not REQUIRED_CAMERA_ANGLES.issubset(set(camera_angles)): failures.append("camera-angle coverage")
    if not REQUIRED_SKILL_GROUPS.issubset(set(skill_groups)): failures.append("skill-group coverage")
    if repeatability["pairCount"] < 30: failures.append("repeatability pair count")
    if repeatability["playerCount"] < 10: failures.append("repeatability player count")
    if not repeatability["usesExactSameVideo"]: failures.append("repeatability source binding")
    for metric, minimum in MINIMUMS.items():
        if metrics[metric] < minimum: failures.append(metric)
    for metric, maximum in MAXIMUMS.items():
        if metrics[metric] > maximum: failures.append(metric)
    if not parity["passes"]: failures.append("Core ML parity")
    if not rights_ok: failures.append("commercial-use rights")

    metric_failures = [failure for failure in failures if failure != "commercial-use rights"]
    release_eligible = not failures
    return {
        "schemaVersion": 4,
        "modelIdentifier": identity[0],
        "modelVersion": identity[1],
        "modelSHA256": model_hash,
        "rubric": CURRENT_RUBRIC_BINDING,
        "capturePlan": CURRENT_CAPTURE_PLAN_BINDING,
        "releaseEligible": release_eligible,
        "passesProductionAccuracyGates": not metric_failures,
        "commercialUseCleared": rights_ok,
        "coachGroundTruthVerified": dataset_evidence["coachGroundTruthVerified"],
        "independentAdjudicationPolicyVerified": dataset_evidence["independentAdjudicationPolicyVerified"],
        "coreMLParityPassed": parity["passes"],
        "conversionParityMaximumAbsoluteError": parity["maximumError"],
        "conversionParitySampleCount": parity["sampleCount"],
        "design": design,
        "metrics": metrics,
        "failedCriteria": failures,
        "evidenceDigests": {
            "researchModelSHA256": sha256_file(research_model_path),
            "datasetSHA256": sha256_file(dataset_path),
            "offlineEvaluationSHA256": sha256_file(offline_evaluation_path),
            "repeatabilityReportSHA256": (
                canonical_digest(raw_repeatability)
                if repeatability_document is not None
                else sha256_file(repeatability_path)
            ),
            "coreMLParityReportSHA256": sha256_file(parity_path),
            "rightsEvidenceSHA256": sha256_file(rights_path),
        },
        "evidenceGeneration": {
            "schemaVersion": 1,
            "tool": "evaluate_release_candidate.py",
            "repeatabilitySource": (
                "verified signed native task pairs"
                if repeatability_document is not None
                else "frozen repeatability report"
            ),
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiled-model", type=Path, required=True)
    parser.add_argument("--research-model", type=Path, required=True)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--offline-evaluation", type=Path, required=True)
    parser.add_argument("--repeatability", type=Path, required=True)
    parser.add_argument("--coreml-parity", type=Path, required=True)
    parser.add_argument("--rights-evidence", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        evaluation = build_evaluation(
            compiled_model_path=args.compiled_model,
            research_model_path=args.research_model,
            dataset_path=args.dataset,
            offline_evaluation_path=args.offline_evaluation,
            repeatability_path=args.repeatability,
            parity_path=args.coreml_parity,
            rights_path=args.rights_evidence,
        )
    except (EvaluationEvidenceError, ReleaseGateError, OSError, json.JSONDecodeError) as error:
        print(f"Release evaluation stopped; no report was written: {error}")
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evaluation, indent=2, sort_keys=True, allow_nan=False) + "\n")
    print(f"wrote release evaluation to {args.output}; eligible={evaluation['releaseEligible']}")
    return 0 if evaluation["releaseEligible"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
