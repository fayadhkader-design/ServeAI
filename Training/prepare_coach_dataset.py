#!/usr/bin/env python3
"""Validate consented ServeAI exports and create a player-isolated review index.

This script never averages two coaches into artificial ground truth. It reports
disagreement and leaves adjudication explicit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from collections import defaultdict
from itertools import combinations
from pathlib import Path

from coach_auth import (
    CoachAuthorizationError,
    load_verified_registry,
    parse_iso8601,
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
from task_coordinator_auth import (
    TaskCoordinatorAuthorizationError,
    authorize_labeling_task,
    load_verified_task_coordinator_registry,
    require_task_coordinator_registry_secret,
    verify_native_task_signature,
)
from coach_rubric import (
    CURRENT_BINDING as CURRENT_RUBRIC_BINDING,
    TECHNIQUES,
    validate_priority,
    validate_rubric_binding,
)
from capture_plan import (
    CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING,
    validate_annotation_assignment,
    validate_task_assignment,
)


CURRENT_SCHEMA = 8
CURRENT_CONSENT = "2026-07"
PHASES = (
    "startingStance", "ballToss", "loading", "trophyPosition", "legDrive",
    "racketDrop", "upwardAcceleration", "contactPosition", "pronation", "followThrough",
)
CAMERA_ANGLES = {"side", "rear"}
SKILL_LEVELS = {"beginner", "intermediate", "advanced", "competitive"}
DOMINANT_HANDS = {"right", "left"}
ENVIRONMENTS = {"outdoor", "indoor"}
LIGHTING_CONDITIONS = {"evenDaylight", "harshSun", "indoorBright", "lowLight"}
DEVICE_CATEGORIES = {"iPhone", "otherPhone", "dedicatedCamera"}
SUBJECT_CONTRASTS = {"high", "typical", "low"}
RECORDING_ISSUES = {"poorFraming", "occlusion", "lowLight", "multiplePeople", "motionBlur"}
BODY_JOINTS = {
    "nose", "neck", "root",
    "leftShoulder", "rightShoulder", "leftElbow", "rightElbow", "leftWrist", "rightWrist",
    "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle",
}


def is_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def validate_collection_metadata(metadata: object) -> list[str]:
    if not isinstance(metadata, dict):
        return ["collection cohort metadata is missing"]
    errors: list[str] = []
    if metadata.get("dominantHand") not in DOMINANT_HANDS:
        errors.append("dominant-hand cohort is missing or invalid")
    if metadata.get("environment") not in ENVIRONMENTS:
        errors.append("court-environment cohort is missing or invalid")
    if metadata.get("lighting") not in LIGHTING_CONDITIONS:
        errors.append("lighting cohort is missing or invalid")
    if metadata.get("sourceDeviceCategory") not in DEVICE_CATEGORIES:
        errors.append("source-device category is missing or invalid")
    if not str(metadata.get("sourceDeviceModel") or "").strip():
        errors.append("source-device model or study code is missing")
    if metadata.get("subjectContrast") not in SUBJECT_CONTRASTS:
        errors.append("subject-contrast cohort is missing or invalid")
    issues = metadata.get("recordingIssueTags")
    if not isinstance(issues, list) or len(issues) != len(set(issues)) or not set(issues).issubset(RECORDING_ISSUES):
        errors.append("recording-issue tags are invalid or duplicated")
    if not isinstance(metadata.get("videoWidth"), int) or metadata.get("videoWidth", 0) <= 0:
        errors.append("video width is missing or invalid")
    if not isinstance(metadata.get("videoHeight"), int) or metadata.get("videoHeight", 0) <= 0:
        errors.append("video height is missing or invalid")
    if not is_number(metadata.get("nominalFrameRate")) or metadata.get("nominalFrameRate", 0) <= 0:
        errors.append("nominal frame rate is missing or invalid")
    return errors


def resolution_cohort(metadata: dict) -> str:
    short_edge = min(metadata["videoWidth"], metadata["videoHeight"])
    if short_edge >= 1800:
        return "4k"
    if short_edge >= 1000:
        return "1080p"
    if short_edge >= 700:
        return "720p"
    return "sub-720p"


def frame_rate_cohort(metadata: dict) -> str:
    rate = metadata["nominalFrameRate"]
    if rate >= 90:
        return "120fps"
    if rate >= 45:
        return "60fps"
    return "30fps"


def feature_evidence_digest(evidence: dict) -> str:
    canonical = json.dumps(evidence, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def labeling_task_digest(task: dict) -> str:
    return hashlib.sha256(canonical_json(task)).hexdigest()


def validate_labeling_task(
    task: object,
    package: dict,
    verified_task_coordinators: dict[str, dict] | None = None,
) -> list[str]:
    """Verify optional native cross-device task binding and its ECDSA signature."""
    if task is None:
        return []
    if not isinstance(task, dict):
        return ["labeling task is invalid"]
    errors: list[str] = []
    payload = task.get("payload")
    signature = task.get("signature")
    if task.get("schemaVersion") != 1 or not isinstance(payload, dict) or payload.get("schemaVersion") not in {1, 2}:
        return ["labeling task envelope must be schema 1 and payload schema must be 1 or 2"]
    if not isinstance(signature, dict):
        return ["labeling task signature is missing"]

    analysis = payload.get("analysis")
    if not isinstance(analysis, dict):
        return ["labeling task analysis snapshot is missing"]
    if payload.get("analysisID") != package.get("analysisID") or analysis.get("id") != package.get("analysisID"):
        errors.append("labeling task analysis identity conflicts with the annotation")
    if analysis.get("cameraAngle") != package.get("cameraAngle") or analysis.get("skillLevel") != package.get("skillLevel"):
        errors.append("labeling task camera angle or skill level conflicts with the annotation")
    if analysis.get("source") == "simulated":
        errors.append("simulated analyses cannot be labeling tasks")
    if analysis.get("source") == "researchCapture":
        assigned_slot, _ = validate_task_assignment(payload)
        if not assigned_slot or not assigned_slot.get("recordingIssueTags"):
            errors.append("research-only captures must be assigned to an intentional failure slot")
        if (
            analysis.get("overallScore") != 0
            or analysis.get("phaseScores")
            or analysis.get("technicalMetrics")
            or analysis.get("insights")
            or analysis.get("drills")
        ):
            errors.append("research-only captures cannot contain coaching outputs")
    if analysis.get("modelFeatureEvidence") != package.get("modelFeatureEvidence"):
        errors.append("labeling task pose evidence conflicts with the annotation")
    evidence = analysis.get("modelFeatureEvidence") or {}
    evidence_hash = (evidence.get("provenance") or {}).get("videoSHA256")
    if payload.get("sourceVideoSHA256") != evidence_hash:
        errors.append("labeling task source-video fingerprint conflicts with pose evidence")
    if not str(payload.get("sourceVideoFilename") or "").strip():
        errors.append("labeling task source-video filename is missing")
    if len(str(payload.get("coordinatorPseudonym") or "").strip()) < 3:
        errors.append("labeling task coordinator pseudonym is invalid")
    if not payload.get("taskID"):
        errors.append("labeling task ID is missing")
    try:
        parse_iso8601(payload.get("createdAt"))
    except (TypeError, ValueError):
        errors.append("labeling task creation timestamp is invalid")

    expected_report = {
        "source": analysis.get("source"),
        "overallScore": analysis.get("overallScore"),
        "phaseScores": analysis.get("phaseScores"),
        "confidence": analysis.get("confidence"),
    }
    if package.get("modelReport") != expected_report:
        errors.append("labeling task report snapshot conflicts with the annotation")
    if payload.get("schemaVersion") == 2:
        _, assignment_errors = validate_annotation_assignment(package)
        errors.extend(assignment_errors)

    try:
        verify_native_task_signature(task)
    except TaskCoordinatorAuthorizationError as error:
        errors.append(str(error))
    if not errors and verified_task_coordinators is not None:
        try:
            authorize_labeling_task(task, verified_task_coordinators)
        except TaskCoordinatorAuthorizationError as error:
            errors.append(str(error))
    return errors


def validate_feature_evidence(evidence: object, camera_angle: object) -> list[str]:
    if not isinstance(evidence, dict):
        return ["model feature evidence is missing"]
    errors: list[str] = []
    sequence = evidence.get("sequence")
    provenance = evidence.get("provenance")
    if not isinstance(sequence, dict):
        return ["model feature sequence is missing"]
    if not isinstance(provenance, dict):
        return ["model feature provenance is missing"]

    if sequence.get("schemaVersion") != 2:
        errors.append("model feature sequence schema must be 2")
    duration = sequence.get("duration")
    if not is_number(duration) or not math.isfinite(duration) or not 2 <= duration <= 45:
        errors.append("model feature duration is invalid")
    if sequence.get("cameraAngle") != camera_angle:
        errors.append("model feature camera angle does not match the annotation")
    frames = sequence.get("frames")
    if not isinstance(frames, list) or len(frames) < 18:
        errors.append("model feature sequence needs at least 18 frames")
        frames = []

    previous_time = -math.inf
    valid_times: list[float] = []
    for index, frame in enumerate(frames):
        if not isinstance(frame, dict):
            errors.append(f"model frame {index} is invalid")
            continue
        timestamp = frame.get("timestamp")
        if not is_number(timestamp) or not math.isfinite(timestamp) or timestamp < previous_time:
            errors.append(f"model frame {index} timestamp is invalid or out of order")
        else:
            previous_time = timestamp
            valid_times.append(timestamp)
        body_confidence = frame.get("bodyConfidence")
        if not is_number(body_confidence) or not math.isfinite(body_confidence) or not 0 <= body_confidence <= 1:
            errors.append(f"model frame {index} body confidence is invalid")
        joints = frame.get("joints")
        if not isinstance(joints, list):
            errors.append(f"model frame {index} joints are missing")
            continue
        names = [item.get("joint") for item in joints if isinstance(item, dict)]
        if len(joints) != len(BODY_JOINTS) or len(names) != len(set(names)) or set(names) != BODY_JOINTS:
            errors.append(f"model frame {index} must contain every body joint exactly once")
            continue
        for item in joints:
            name = item.get("joint", "unknown")
            values = (item.get("x"), item.get("y"), item.get("confidence"))
            if any(not is_number(value) or not math.isfinite(value) for value in values):
                errors.append(f"model frame {index} joint {name} has non-finite features")
                continue
            x, y, confidence = values
            if abs(x) > 10 or abs(y) > 10 or not 0 <= confidence <= 1:
                errors.append(f"model frame {index} joint {name} is outside feature bounds")
            if not isinstance(item.get("isPresent"), bool):
                errors.append(f"model frame {index} joint {name} presence flag is invalid")
            elif item["isPresent"] is False and (x != 0 or y != 0 or confidence != 0):
                errors.append(f"model frame {index} absent joint {name} contains fabricated features")
    if valid_times and (valid_times[0] < 0 or (is_number(duration) and valid_times[-1] > duration + 0.1) or valid_times[-1] <= valid_times[0]):
        errors.append("model feature timestamps do not span a valid portion of the video")

    if provenance.get("schemaVersion") != 1:
        errors.append("model feature provenance schema must be 1")
    if provenance.get("encoderIdentifier") != "serveai.pose-sequence" or provenance.get("encoderVersion") != "2.0.0":
        errors.append("model feature encoder identifier or version is unsupported")
    if not str(provenance.get("poseDetectorIdentifier") or "").strip() or not str(provenance.get("poseDetectorVersion") or "").strip():
        errors.append("pose detector provenance is missing")
    digest = provenance.get("videoSHA256")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        errors.append("source video SHA-256 is missing or invalid")
    if not provenance.get("generatedAt"):
        errors.append("model feature generation timestamp is missing")
    else:
        try:
            parse_iso8601(provenance["generatedAt"])
        except (TypeError, ValueError):
            errors.append("model feature generation timestamp is invalid")
    sample_rate = provenance.get("requestedSamplesPerSecond")
    smoothing = provenance.get("smoothingWindow")
    sampled = provenance.get("sampledFrameCount")
    detected = provenance.get("detectedFrameCount")
    if not is_number(sample_rate) or sample_rate <= 0:
        errors.append("requested model sampling rate is invalid")
    if not isinstance(smoothing, int) or isinstance(smoothing, bool) or smoothing <= 0:
        errors.append("model smoothing window is invalid")
    if not isinstance(sampled, int) or isinstance(sampled, bool) or sampled < len(frames):
        errors.append("sampled model frame count is invalid")
    if not isinstance(detected, int) or isinstance(detected, bool) or detected != len(frames):
        errors.append("detected model frame count does not match the feature sequence")
    return errors


def stable_split(participant: str) -> str:
    bucket = int(hashlib.sha256(participant.encode()).hexdigest()[:8], 16) % 100
    if bucket < 70:
        return "train"
    if bucket < 85:
        return "validation"
    return "test"


def phase_map(package: dict) -> dict[str, dict]:
    return {
        item["phase"]: item
        for item in package.get("phaseBoundaries", [])
        if isinstance(item, dict) and item.get("phase")
    }


def validate(
    package: dict,
    path: Path,
    verified_coaches: set[str] | None = None,
    verified_task_coordinators: dict[str, dict] | None = None,
) -> list[str]:
    errors: list[str] = []
    if package.get("schemaVersion") != CURRENT_SCHEMA:
        errors.append(f"schema must be {CURRENT_SCHEMA}")
    errors.extend(validate_rubric_binding(package.get("rubric")))
    consent = package.get("consent", {})
    if not isinstance(consent, dict):
        consent = {}
    if consent.get("consentVersion") != CURRENT_CONSENT:
        errors.append("consent version is not current")
    if consent.get("allowsResearchAndModelTraining") is not True or not consent.get("recordedAt"):
        errors.append("explicit recorded training consent is missing")
    elif consent.get("recordedAt"):
        try:
            parse_iso8601(consent["recordedAt"])
        except (TypeError, ValueError):
            errors.append("consent grant timestamp is invalid")
    if consent.get("revokedAt"):
        errors.append("training consent has been revoked")
        try:
            parse_iso8601(consent["revokedAt"])
        except (TypeError, ValueError):
            errors.append("consent revocation timestamp is invalid")
    if not consent.get("consentRecordID"):
        errors.append("consent record ID is missing")
    decisions = consent.get("decisionHistory") or []
    if not isinstance(decisions, list) or not decisions or not isinstance(decisions[-1], dict) or decisions[-1].get("kind") != "granted":
        errors.append("consent audit history does not end in an active grant")
    if not package.get("participantPseudonym"):
        errors.append("participant pseudonym is missing")
    if not package.get("annotatorPseudonym"):
        errors.append("annotator pseudonym is missing")
    elif verified_coaches is not None and package.get("annotatorPseudonym") not in verified_coaches:
        errors.append("annotator is not active in the signed coach registry")
    if not package.get("analysisID"):
        errors.append("analysis ID is missing")
    if not package.get("annotationID"):
        errors.append("annotation ID is missing")
    if package.get("cameraAngle") not in CAMERA_ANGLES:
        errors.append("camera angle is invalid")
    if package.get("skillLevel") not in SKILL_LEVELS:
        errors.append("skill level is invalid")
    errors.extend(validate_collection_metadata(package.get("collectionMetadata")))
    errors.extend(validate_feature_evidence(package.get("modelFeatureEvidence"), package.get("cameraAngle")))
    errors.extend(validate_labeling_task(
        package.get("labelingTask"), package, verified_task_coordinators
    ))
    if not isinstance(package.get("isVideoUsable"), bool):
        errors.append("video usability decision must be true or false")
    model_report = package.get("modelReport") or {}
    if model_report.get("source") == "researchCapture":
        if package.get("labelingTask") is None:
            errors.append("research-only captures require a signed capture-plan labeling task")
        if package.get("isVideoUsable") is not False:
            errors.append("research-only captures must remain labeled unusable")
        if package.get("phaseBoundaries") or package.get("techniqueRatings") or package.get("topPriority"):
            errors.append("research-only captures cannot provide technique, timing, or coaching-priority labels")
    if package.get("isVideoUsable") is True:
        phases = phase_map(package)
        if len(package.get("phaseBoundaries") or []) != len(PHASES) or set(phases) != set(PHASES):
            errors.append("all ten phase decisions are required")
        for phase, item in phases.items():
            if item.get("isVisible") and (item.get("startTime") is None or item.get("endTime") is None):
                errors.append(f"visible phase {phase} has incomplete timing")
            if item.get("startTime") is not None and item.get("endTime") is not None:
                if not is_number(item["startTime"]) or not is_number(item["endTime"]):
                    errors.append(f"phase {phase} timing must be numeric")
                elif item["endTime"] < item["startTime"]:
                    errors.append(f"phase {phase} ends before it starts")
            if not item.get("isVisible") and (item.get("startTime") is not None or item.get("endTime") is not None):
                errors.append(f"invisible phase {phase} contains fabricated timing")
        techniques = package.get("techniqueRatings") or []
        technique_map = {
            item.get("label"): item for item in techniques if isinstance(item, dict) and item.get("label")
        }
        if len(techniques) != len(TECHNIQUES) or set(technique_map) != TECHNIQUES:
            errors.append("all six technique decisions are required")
        for label, item in technique_map.items():
            rating = item.get("rating")
            if item.get("isVisible") and (not isinstance(rating, int) or isinstance(rating, bool) or not 1 <= rating <= 5):
                errors.append(f"visible technique {label} needs a 1–5 rating")
            if not item.get("isVisible") and rating is not None:
                errors.append(f"invisible technique {label} contains a fabricated rating")
        if package.get("topPriority") not in TECHNIQUES:
            errors.append("top coaching priority is missing or invalid")
        else:
            errors.extend(validate_priority(techniques, package.get("topPriority")))
    elif package.get("isVideoUsable") is False and not package.get("unusableReason"):
        errors.append("unusable clip has no reason")
    return [f"{path.name}: {error}" for error in errors]


def compare(first: dict, second: dict) -> dict:
    first_phases = phase_map(first)
    second_phases = phase_map(second)
    timing_errors: list[float] = []
    visibility_agreements = 0
    for phase in PHASES:
        a, b = first_phases.get(phase), second_phases.get(phase)
        if not a or not b:
            continue
        if a.get("isVisible") == b.get("isVisible"):
            visibility_agreements += 1
        if a.get("isVisible") and b.get("isVisible"):
            timing_errors.extend([
                abs(a["startTime"] - b["startTime"]),
                abs(a["endTime"] - b["endTime"]),
            ])
    first_techniques = {
        item.get("label"): (item.get("isVisible"), item.get("rating"))
        for item in first.get("techniqueRatings") or [] if isinstance(item, dict)
    }
    second_techniques = {
        item.get("label"): (item.get("isVisible"), item.get("rating"))
        for item in second.get("techniqueRatings") or [] if isinstance(item, dict)
    }
    technique_agreement = first_techniques == second_techniques
    usability_agreement = first.get("isVideoUsable") == second.get("isVideoUsable")
    return {
        "coachIDs": sorted([first["annotatorPseudonym"], second["annotatorPseudonym"]]),
        "visibilityAgreement": visibility_agreements / len(PHASES),
        "boundaryMeanAbsoluteDifference": sum(timing_errors) / len(timing_errors) if timing_errors else None,
        "topPriorityAgreement": first.get("topPriority") == second.get("topPriority"),
        "requiresAdjudication": (
            first.get("topPriority") != second.get("topPriority")
            or visibility_agreements != len(PHASES)
            or any(error > 1e-9 for error in timing_errors)
            or first.get("collectionMetadata") != second.get("collectionMetadata")
            or not technique_agreement
            or not usability_agreement
        ),
        "collectionMetadataAgreement": first.get("collectionMetadata") == second.get("collectionMetadata"),
        "techniqueRatingsAgreement": technique_agreement,
        "videoUsabilityAgreement": usability_agreement,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("inputs", nargs="+", type=Path, help="Annotation JSON files or directories")
    parser.add_argument("--output", type=Path, default=Path("Training/artifacts/coach_dataset_index.json"))
    parser.add_argument("--allow-single-label", action="store_true")
    parser.add_argument("--coach-registry", type=Path, help="Admin-signed coach public-key registry")
    parser.add_argument(
        "--task-coordinator-registry",
        type=Path,
        help="Admin-signed registry for native portable-task signer keys",
    )
    parser.add_argument("--consent-registry", type=Path, help="Admin-signed consent-authority public-key registry")
    parser.add_argument("--consent-ledger", type=Path, help="Fresh signed complete receipt-ledger snapshot")
    parser.add_argument(
        "--consent-receipts",
        nargs="+",
        type=Path,
        help="Signed consent receipt JSON files or directories containing immutable grant/revocation receipts",
    )
    parser.add_argument(
        "--allow-unverified-coaches",
        action="store_true",
        help="Research-only escape hatch; output remains ineligible for model release",
    )
    parser.add_argument(
        "--allow-unverified-consent",
        action="store_true",
        help="Research-only escape hatch; coach-side consent claims are not independent authorization",
    )
    parser.add_argument(
        "--allow-unverified-task-coordinators",
        action="store_true",
        help="Research-only escape hatch; portable task signer identity is not independently authorized",
    )
    args = parser.parse_args()

    registry: dict[str, dict] | None = None
    if args.allow_unverified_coaches:
        print("WARNING: coach signatures are not being verified; output is research-only")
    else:
        if args.coach_registry is None:
            print("Dataset preparation stopped; --coach-registry is required unless --allow-unverified-coaches is set.")
            return 1
        try:
            registry = load_verified_registry(args.coach_registry, require_registry_secret())
        except CoachAuthorizationError as error:
            print(f"Dataset preparation stopped; {error}")
            return 1

    task_coordinator_registry: dict[str, dict] | None = None
    if args.allow_unverified_task_coordinators:
        print("WARNING: portable task coordinators are not registry-verified; portable-task output is research-only")
    else:
        if args.task_coordinator_registry is None:
            print(
                "Dataset preparation stopped; --task-coordinator-registry is required unless "
                "--allow-unverified-task-coordinators is set."
            )
            return 1
        try:
            task_coordinator_registry = load_verified_task_coordinator_registry(
                args.task_coordinator_registry,
                require_task_coordinator_registry_secret(),
            )
        except TaskCoordinatorAuthorizationError as error:
            print(f"Dataset preparation stopped; {error}")
            return 1

    consent_records: dict[str, dict] | None = None
    if args.allow_unverified_consent:
        print("WARNING: independent consent receipts are not being verified; output is research-only")
    else:
        if args.consent_registry is None or args.consent_ledger is None or not args.consent_receipts:
            print(
                "Dataset preparation stopped; --consent-registry, --consent-ledger, and --consent-receipts are required "
                "unless --allow-unverified-consent is set."
            )
            return 1
        receipt_paths: list[Path] = []
        for item in args.consent_receipts:
            candidates = sorted(item.glob("*.json")) if item.is_dir() else [item]
            receipt_paths.extend(
                path for path in candidates
                if not path.name.endswith(".consent-signature.json")
                and not path.name.endswith(".consent-ledger-signature.json")
                and path.resolve() != args.consent_ledger.resolve()
            )
        try:
            consent_registry = load_verified_consent_registry(
                args.consent_registry,
                require_consent_registry_secret(),
            )
            if registry is not None:
                require_separate_signing_domains(registry, consent_registry)
            consent_records, consent_ledger_evidence = load_verified_consent_ledger_records(
                receipt_paths, args.consent_ledger, consent_registry
            )
        except ConsentAuthorizationError as error:
            print(f"Dataset preparation stopped; {error}")
            return 1

    paths: list[Path] = []
    for item in args.inputs:
        candidates = sorted(item.glob("*.json")) if item.is_dir() else [item]
        paths.extend(path for path in candidates if not path.name.endswith(".signature.json"))
    packages: list[dict] = []
    failures: list[str] = []
    for path in paths:
        try:
            package = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            failures.append(f"{path.name}: unreadable JSON ({error})")
            continue
        errors = validate(
            package,
            path,
            set(registry) if registry is not None else None,
            task_coordinator_registry,
        )
        if not errors and registry is not None:
            try:
                verify_artifact_signature(path, package["annotatorPseudonym"], registry)
            except CoachAuthorizationError as error:
                errors.append(f"{path.name}: {error}")
        consent_evidence = None
        if not errors and consent_records is not None:
            consent_evidence, consent_errors = verify_annotation_consent(package, consent_records)
            errors.extend(f"{path.name}: {error}" for error in consent_errors)
        if errors:
            failures.extend(errors)
        else:
            package["_sourceFile"] = str(path)
            package["_consentEvidence"] = consent_evidence or {"status": "UNVERIFIED — research only"}
            packages.append(package)

    by_analysis: dict[str, list[dict]] = defaultdict(list)
    for package in packages:
        by_analysis[package["analysisID"]].append(package)

    reviews = []
    for analysis_id, annotations in sorted(by_analysis.items()):
        coaches = {item["annotatorPseudonym"] for item in annotations}
        if len(coaches) < 2 and not args.allow_single_label:
            failures.append(f"analysis {analysis_id}: needs labels from two distinct coaches")
            continue
        pairwise = [compare(a, b) for a, b in combinations(annotations, 2) if a["annotatorPseudonym"] != b["annotatorPseudonym"]]
        participant = annotations[0]["participantPseudonym"]
        if any(item["participantPseudonym"] != participant for item in annotations):
            failures.append(f"analysis {analysis_id}: participant IDs conflict")
            continue
        if len({item["cameraAngle"] for item in annotations}) != 1:
            failures.append(f"analysis {analysis_id}: camera angles conflict")
            continue
        if len({item["skillLevel"] for item in annotations}) != 1:
            failures.append(f"analysis {analysis_id}: skill levels conflict")
            continue
        feature_digests = {feature_evidence_digest(item["modelFeatureEvidence"]) for item in annotations}
        if len(feature_digests) != 1:
            failures.append(f"analysis {analysis_id}: signed model feature evidence conflicts")
            continue
        labeling_tasks = [item.get("labelingTask") for item in annotations]
        if any(task is not None for task in labeling_tasks):
            if any(task is None for task in labeling_tasks):
                failures.append(f"analysis {analysis_id}: signed labeling-task provenance is missing from one or more labels")
                continue
            task_digests = {labeling_task_digest(task) for task in labeling_tasks}
            if len(task_digests) != 1:
                failures.append(f"analysis {analysis_id}: signed labeling tasks conflict")
                continue
            task = labeling_tasks[0]
            if task_coordinator_registry is not None:
                authorization = authorize_labeling_task(task, task_coordinator_registry)
                task_status = "AUTHORIZED — ECDSA signature and coordinator registry key verified"
            else:
                authorization = {"status": "UNVERIFIED COORDINATOR — research only"}
                task_status = "ECDSA signature verified; coordinator identity unverified"
            labeling_task_evidence = {
                "status": task_status,
                "taskSHA256": next(iter(task_digests)),
                "taskID": task["payload"]["taskID"],
                "taskCreatedAt": task["payload"]["createdAt"],
                "coordinatorPseudonym": task["payload"]["coordinatorPseudonym"],
                "signerKeyID": task["signature"]["signerKeyID"],
                "authorization": authorization,
            }
            if task["payload"].get("schemaVersion") == 2:
                slot, assignment_errors = validate_annotation_assignment(annotations[0])
                if assignment_errors or slot is None:
                    failures.extend(f"analysis {analysis_id}: {error}" for error in assignment_errors)
                    continue
                capture_plan_evidence = {
                    "status": "PINNED — signed task matches frozen capture plan",
                    "plan": CURRENT_CAPTURE_PLAN_BINDING,
                    "slotID": slot["slotID"],
                    "participantPseudonym": slot["participantPseudonym"],
                    "split": slot["split"],
                }
            else:
                capture_plan_evidence = {"status": "LEGACY TASK — no signed capture-plan assignment"}
        else:
            labeling_task_evidence = {"status": "LOCAL SAME-DEVICE LABELING — no portable task"}
            capture_plan_evidence = {"status": "LOCAL LABEL — no signed capture-plan assignment"}
        consent_evidence = {json.dumps(item["_consentEvidence"], sort_keys=True) for item in annotations}
        if len(consent_evidence) != 1:
            failures.append(f"analysis {analysis_id}: independently verified consent evidence conflicts")
            continue
        reviews.append({
            "analysisID": analysis_id,
            "participantPseudonym": participant,
            "split": capture_plan_evidence.get("split") or stable_split(participant),
            "cameraAngle": annotations[0]["cameraAngle"],
            "skillLevel": annotations[0]["skillLevel"],
            "collectionMetadata": annotations[0]["collectionMetadata"],
            "featureEvidenceDigest": next(iter(feature_digests)),
            "sourceVideoSHA256": annotations[0]["modelFeatureEvidence"]["provenance"]["videoSHA256"],
            "labelingTaskVerification": labeling_task_evidence,
            "capturePlanVerification": capture_plan_evidence,
            "consentVerification": annotations[0]["_consentEvidence"],
            "cohorts": {
                "cameraAngle": annotations[0]["cameraAngle"],
                "skillLevel": annotations[0]["skillLevel"],
                "dominantHand": annotations[0]["collectionMetadata"]["dominantHand"],
                "environment": annotations[0]["collectionMetadata"]["environment"],
                "lighting": annotations[0]["collectionMetadata"]["lighting"],
                "sourceDeviceCategory": annotations[0]["collectionMetadata"]["sourceDeviceCategory"],
                "sourceDeviceModel": annotations[0]["collectionMetadata"]["sourceDeviceModel"],
                "subjectContrast": annotations[0]["collectionMetadata"]["subjectContrast"],
                "resolution": resolution_cohort(annotations[0]["collectionMetadata"]),
                "frameRate": frame_rate_cohort(annotations[0]["collectionMetadata"]),
            },
            "annotationFiles": [item["_sourceFile"] for item in annotations],
            "pairwiseAgreement": pairwise,
            "requiresAdjudication": any(item["requiresAdjudication"] for item in pairwise),
        })

    if failures:
        print("Dataset preparation stopped; no partial index was written.")
        print("\n".join(f"- {failure}" for failure in failures))
        return 1

    split_counts = {name: sum(item["split"] == name for item in reviews) for name in ("train", "validation", "test")}
    portable_reviews = [
        item for item in reviews
        if item["labelingTaskVerification"]["status"] != "LOCAL SAME-DEVICE LABELING — no portable task"
    ]
    portable_task_authorization_complete = (
        not portable_reviews
        or all(
            item["labelingTaskVerification"]["status"].startswith("AUTHORIZED")
            for item in portable_reviews
        )
    )
    output = {
        "schemaVersion": 1,
        "rubricContract": CURRENT_RUBRIC_BINDING,
        "capturePlanContract": CURRENT_CAPTURE_PLAN_BINDING,
        "splitPolicy": "SHA-256 participant pseudonym: 70/15/15; every clip from one player stays together",
        "groundTruthPolicy": "Coach disagreements require explicit adjudication and are never averaged automatically",
        "coachVerification": "ECDSA-P256 signatures checked against an admin-authorized coach registry" if registry is not None else "UNVERIFIED — research only",
        "consentVerification": (
            "ECDSA-P256 consent receipts checked against a separately authorized consent registry"
            if consent_records is not None else "UNVERIFIED — research only"
        ),
        "consentLedgerVerification": (
            consent_ledger_evidence if consent_records is not None else {"status": "UNVERIFIED — research only"}
        ),
        "portableTaskCoordinatorVerification": (
            "HMAC-authorized registry matched each embedded task signer key"
            if task_coordinator_registry is not None
            else "UNVERIFIED — research only"
        ),
        "groundTruthEligible": (
            registry is not None
            and consent_records is not None
            and portable_task_authorization_complete
            and not args.allow_single_label
            and bool(reviews)
            and not any(item["requiresAdjudication"] for item in reviews)
        ),
        "modelReleaseEligible": False,
        "analysisCount": len(reviews),
        "participantCount": len({item["participantPseudonym"] for item in reviews}),
        "splitCounts": split_counts,
        "reviews": reviews,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print(f"wrote {args.output} with {len(reviews)} double-labeled analyses")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
