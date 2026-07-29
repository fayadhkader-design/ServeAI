#!/usr/bin/env python3
"""Audit whether a consented, coach-reviewed collection is ready for model work.

This is a collection gate, not a model-accuracy gate. Passing means the dataset
is large and varied enough to start temporal-model training and a held-out
evaluation. It never marks a model as release eligible.
"""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING, SLOTS_BY_ID


MINIMUM_ANALYSES = 300
MINIMUM_PARTICIPANTS = 40
MINIMUM_SPLITS = {"train": 180, "validation": 45, "test": 60}
MINIMUM_TEST_PARTICIPANTS = 10

OVERALL_COHORT_MINIMUMS = {
    "cameraAngle": {"side": 60, "rear": 60},
    "skillLevel": {"beginner": 30, "intermediate": 30, "advanced": 30, "competitive": 30},
    "dominantHand": {"right": 150, "left": 30},
    "environment": {"outdoor": 45, "indoor": 45},
    "lighting": {"evenDaylight": 30, "harshSun": 15, "indoorBright": 15, "lowLight": 15},
    "subjectContrast": {"high": 15, "typical": 90, "low": 30},
    "resolution": {"720p": 30, "1080p": 60, "4k": 15},
    "frameRate": {"30fps": 60, "60fps": 60, "120fps": 15},
}

TEST_COHORT_MINIMUMS = {
    "cameraAngle": {"side": 10, "rear": 10},
    "skillLevel": {"beginner": 5, "intermediate": 5, "advanced": 5, "competitive": 5},
    "dominantHand": {"right": 20, "left": 5},
    "environment": {"outdoor": 5, "indoor": 5},
    "lighting": {"evenDaylight": 3, "harshSun": 3, "indoorBright": 3, "lowLight": 3},
    "subjectContrast": {"high": 3, "typical": 10, "low": 3},
    "resolution": {"720p": 3, "1080p": 3, "4k": 3},
    "frameRate": {"30fps": 3, "60fps": 3, "120fps": 3},
}

RECORDING_ISSUE_MINIMUMS = {
    "poorFraming": 10,
    "occlusion": 10,
    "lowLight": 10,
    "multiplePeople": 10,
    "motionBlur": 10,
}
MINIMUM_NEGATIVE_EXAMPLES = 45
MINIMUM_IPHONE_MODELS = 4


def _deficit(deficits: list[dict], gate: str, observed: int, required: int) -> None:
    if observed < required:
        deficits.append({"gate": gate, "observed": observed, "required": required})


def _cohort_counts(records: list[dict]) -> dict[str, Counter]:
    counts: dict[str, Counter] = defaultdict(Counter)
    for record in records:
        for name, value in record["cohorts"].items():
            counts[name][value] += 1
    return counts


def audit_collection(indices: list[dict], ground_truth_records: list[dict] | None = None) -> dict:
    ground_truth = {
        item.get("analysisID"): item
        for item in (ground_truth_records or [])
        if item.get("analysisID")
    }
    deficits: list[dict] = []
    records: list[dict] = []
    seen_analyses: set[str] = set()
    unresolved: list[str] = []
    unverified_index_count = 0
    unverified_consent_index_count = 0
    unverified_task_coordinator_index_count = 0
    unverified_capture_plan_count = 0
    source_video_analyses: dict[str, list[str]] = defaultdict(list)
    capture_slot_analyses: dict[str, list[str]] = defaultdict(list)

    for index in indices:
        if not str(index.get("coachVerification", "")).startswith("ECDSA-P256"):
            unverified_index_count += 1
        if not str(index.get("consentVerification", "")).startswith("ECDSA-P256"):
            unverified_consent_index_count += 1
        if not str(index.get("portableTaskCoordinatorVerification", "")).startswith("HMAC-authorized"):
            unverified_task_coordinator_index_count += 1
        ledger = index.get("consentLedgerVerification")
        if (
            not isinstance(ledger, dict)
            or not ledger.get("consentLedgerSnapshotID")
            or not ledger.get("authorityID")
            or not ledger.get("issuedAt")
            or not re.fullmatch(r"[0-9a-f]{64}", str(ledger.get("ledgerSHA256", "")))
        ):
            unverified_consent_index_count += 1
        for review in index.get("reviews") or []:
            analysis_id = review.get("analysisID")
            if not analysis_id or analysis_id in seen_analyses:
                deficits.append({
                    "gate": "unique analysis IDs",
                    "observed": analysis_id or "missing",
                    "required": "one non-empty unique ID per serve",
                })
                continue
            seen_analyses.add(analysis_id)
            adjudicated = ground_truth.get(analysis_id)
            if review.get("requiresAdjudication") and not adjudicated:
                unresolved.append(analysis_id)
            if adjudicated and adjudicated.get("groundTruthEligible") is not True:
                deficits.append({
                    "gate": f"eligible adjudication for {analysis_id}",
                    "observed": False,
                    "required": True,
                })
            source = adjudicated or review
            capture_plan = review.get("capturePlanVerification") or {}
            capture_slot = capture_plan.get("slotID")
            if (
                not str(capture_plan.get("status", "")).startswith("PINNED")
                or capture_plan.get("plan") != CURRENT_CAPTURE_PLAN_BINDING
                or not capture_slot
                or capture_slot not in SLOTS_BY_ID
                or not capture_plan.get("participantPseudonym")
                or capture_plan.get("participantPseudonym") != review.get("participantPseudonym")
                or capture_plan.get("split") != review.get("split")
                or SLOTS_BY_ID.get(capture_slot, {}).get("participantPseudonym") != review.get("participantPseudonym")
                or SLOTS_BY_ID.get(capture_slot, {}).get("split") != review.get("split")
            ):
                unverified_capture_plan_count += 1
            elif capture_slot:
                capture_slot_analyses[capture_slot].append(analysis_id)
            feature_digest = review.get("featureEvidenceDigest")
            video_digest = review.get("sourceVideoSHA256")
            consent = review.get("consentVerification")
            if (
                not isinstance(consent, dict)
                or not consent.get("consentRecordID")
                or not consent.get("consentReceiptID")
                or not consent.get("authorityID")
                or not re.fullmatch(r"[0-9a-f]{64}", str(consent.get("receiptSHA256", "")))
                or consent.get("sourceVideoSHA256") != video_digest
            ):
                deficits.append({
                    "gate": f"independently verified consent evidence for {analysis_id}",
                    "observed": False,
                    "required": True,
                })
            if not isinstance(feature_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", feature_digest):
                deficits.append({
                    "gate": f"valid pose evidence digest for {analysis_id}",
                    "observed": False,
                    "required": True,
                })
            if not isinstance(video_digest, str) or not re.fullmatch(r"[0-9a-f]{64}", video_digest):
                deficits.append({
                    "gate": f"valid source video fingerprint for {analysis_id}",
                    "observed": False,
                    "required": True,
                })
            else:
                source_video_analyses[video_digest].append(analysis_id)
            if adjudicated and (
                adjudicated.get("featureEvidenceDigest") != feature_digest
                or adjudicated.get("sourceVideoSHA256") != video_digest
            ):
                deficits.append({
                    "gate": f"adjudication evidence binding for {analysis_id}",
                    "observed": False,
                    "required": True,
                })
            cohorts = source.get("cohorts")
            metadata = source.get("collectionMetadata")
            if not isinstance(cohorts, dict) or not isinstance(metadata, dict):
                deficits.append({
                    "gate": f"complete cohort metadata for {analysis_id}",
                    "observed": False,
                    "required": True,
                })
                continue
            records.append({
                "analysisID": analysis_id,
                "participantPseudonym": review.get("participantPseudonym"),
                "split": review.get("split"),
                "cohorts": cohorts,
                "collectionMetadata": metadata,
            })

    _deficit(deficits, "verified signed coach indices", 0 if unverified_index_count else 1, 1)
    _deficit(deficits, "verified signed consent indices", 0 if unverified_consent_index_count else 1, 1)
    _deficit(
        deficits,
        "verified portable-task coordinator indices",
        0 if unverified_task_coordinator_index_count else 1,
        1,
    )
    _deficit(
        deficits,
        "signed capture-plan assignments",
        0 if unverified_capture_plan_count else 1,
        1,
    )
    _deficit(deficits, "resolved coach disagreements", 0 if unresolved else 1, 1)
    _deficit(deficits, "total analyses", len(records), MINIMUM_ANALYSES)

    participants = {item["participantPseudonym"] for item in records if item["participantPseudonym"]}
    _deficit(deficits, "total participants", len(participants), MINIMUM_PARTICIPANTS)

    split_counts = Counter(item["split"] for item in records)
    for split, minimum in MINIMUM_SPLITS.items():
        _deficit(deficits, f"{split} analyses", split_counts[split], minimum)

    participant_splits: dict[str, set[str]] = defaultdict(set)
    for item in records:
        participant_splits[item["participantPseudonym"]].add(item["split"])
    leaking_players = sorted(player for player, splits in participant_splits.items() if len(splits) > 1)
    _deficit(deficits, "player-isolated splits", 0 if leaking_players else 1, 1)
    duplicated_videos = {
        digest: analyses
        for digest, analyses in source_video_analyses.items()
        if len(analyses) > 1
    }
    _deficit(deficits, "unique source videos", 0 if duplicated_videos else 1, 1)
    duplicated_capture_slots = {
        slot: analyses for slot, analyses in capture_slot_analyses.items() if len(analyses) > 1
    }
    _deficit(deficits, "unique capture-plan slots", 0 if duplicated_capture_slots else 1, 1)

    test_records = [item for item in records if item["split"] == "test"]
    test_participants = {item["participantPseudonym"] for item in test_records if item["participantPseudonym"]}
    _deficit(deficits, "held-out test participants", len(test_participants), MINIMUM_TEST_PARTICIPANTS)

    overall_counts = _cohort_counts(records)
    test_counts = _cohort_counts(test_records)
    for cohort, required_values in OVERALL_COHORT_MINIMUMS.items():
        for value, minimum in required_values.items():
            _deficit(deficits, f"overall {cohort}={value}", overall_counts[cohort][value], minimum)
    for cohort, required_values in TEST_COHORT_MINIMUMS.items():
        for value, minimum in required_values.items():
            _deficit(deficits, f"test {cohort}={value}", test_counts[cohort][value], minimum)

    issue_counts = Counter()
    negative_count = 0
    iphone_models: set[str] = set()
    for item in records:
        metadata = item["collectionMetadata"]
        issues = metadata.get("recordingIssueTags") or []
        issue_counts.update(issues)
        if issues:
            negative_count += 1
        if metadata.get("sourceDeviceCategory") == "iPhone" and metadata.get("sourceDeviceModel"):
            iphone_models.add(metadata["sourceDeviceModel"])
    for issue, minimum in RECORDING_ISSUE_MINIMUMS.items():
        _deficit(deficits, f"recording issue={issue}", issue_counts[issue], minimum)
    _deficit(deficits, "negative/failure examples", negative_count, MINIMUM_NEGATIVE_EXAMPLES)
    _deficit(deficits, "distinct iPhone models", len(iphone_models), MINIMUM_IPHONE_MODELS)

    return {
        "schemaVersion": 1,
        "collectionReady": not deficits,
        "readyForTrainingAndHeldOutEvaluation": not deficits,
        "modelReleaseEligible": False,
        "modelReleaseReason": "Collection coverage alone cannot establish model accuracy; the held-out evaluator must pass separately.",
        "analysisCount": len(records),
        "participantCount": len(participants),
        "splitCounts": dict(sorted(split_counts.items())),
        "testParticipantCount": len(test_participants),
        "unresolvedAnalysisIDs": unresolved,
        "playerLeakage": leaking_players,
        "duplicateSourceVideos": duplicated_videos,
        "duplicateCaptureSlots": duplicated_capture_slots,
        "cohortCounts": {name: dict(sorted(values.items())) for name, values in sorted(overall_counts.items())},
        "testCohortCounts": {name: dict(sorted(values.items())) for name, values in sorted(test_counts.items())},
        "recordingIssueCounts": dict(sorted(issue_counts.items())),
        "distinctIPhoneModels": sorted(iphone_models),
        "deficits": deficits,
    }


def _load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{path} is unreadable JSON: {error}") from error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("indices", nargs="+", type=Path, help="Prepared coach dataset index JSON files")
    parser.add_argument(
        "--ground-truth",
        nargs="*",
        type=Path,
        default=[],
        help="Ground-truth JSON files compiled from signed third-coach adjudications",
    )
    parser.add_argument("--output", type=Path, default=Path("Training/artifacts/collection_audit.json"))
    args = parser.parse_args()

    try:
        report = audit_collection(
            [_load_json(path) for path in args.indices],
            [_load_json(path) for path in args.ground_truth],
        )
    except ValueError as error:
        print(f"Collection audit stopped: {error}")
        return 2

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    if report["collectionReady"]:
        print(f"collection gate passed; report written to {args.output}")
        return 0
    print(f"collection gate failed with {len(report['deficits'])} deficit(s); report written to {args.output}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
