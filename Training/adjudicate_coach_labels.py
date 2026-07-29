#!/usr/bin/env python3
"""Compile two signed coach labels plus one signed adjudication into ground truth.

No timing, rating, or priority is averaged. Every final value must be selected
explicitly by a third authorized adjudicator and signed with that person's key.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from coach_auth import (
    CoachAuthorizationError,
    load_verified_registry,
    parse_iso8601,
    require_registry_secret,
    verify_artifact_signature,
)
from prepare_coach_dataset import (
    PHASES,
    frame_rate_cohort,
    feature_evidence_digest,
    is_number,
    resolution_cohort,
    validate as validate_annotation,
    validate_collection_metadata,
)
from coach_rubric import (
    CURRENT_BINDING as CURRENT_RUBRIC_BINDING,
    TECHNIQUES,
    validate_priority,
    validate_rubric_binding,
)


ADJUDICATION_SCHEMA = 3
GROUND_TRUTH_SCHEMA = 4


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"{path.name} is unreadable JSON: {error}") from error


def validate_resolution(resolution: dict, annotations: list[dict], registry: dict[str, dict]) -> list[str]:
    errors: list[str] = []
    if resolution.get("schemaVersion") != ADJUDICATION_SCHEMA:
        errors.append(f"adjudication schema must be {ADJUDICATION_SCHEMA}")
    errors.extend(validate_rubric_binding(resolution.get("rubric")))
    for annotation in annotations:
        errors.extend(f"source annotation {error}" for error in validate_rubric_binding(annotation.get("rubric")))
    if not resolution.get("adjudicationID"):
        errors.append("adjudication ID is missing")
    analysis_ids = {item.get("analysisID") for item in annotations}
    if len(analysis_ids) != 1 or resolution.get("analysisID") not in analysis_ids:
        errors.append("adjudication analysis ID does not match every source label")
    source_ids = {item.get("annotationID") for item in annotations}
    named_source_ids = resolution.get("sourceAnnotationIDs") or []
    if len(named_source_ids) != len(source_ids) or set(named_source_ids) != source_ids:
        errors.append("adjudication must name every source annotation ID exactly once")
    source_coaches = {item.get("annotatorPseudonym") for item in annotations}
    adjudicator = resolution.get("adjudicatorPseudonym")
    if adjudicator not in registry:
        errors.append("adjudicator is not active in the signed coach registry")
    if adjudicator in source_coaches:
        errors.append("adjudicator must be independent from both source coaches")
    if not str(resolution.get("decisionNotes", "")).strip():
        errors.append("adjudication decision notes are required")
    if not resolution.get("createdAt"):
        errors.append("adjudication timestamp is missing")
    else:
        try:
            parse_iso8601(resolution["createdAt"])
        except (TypeError, ValueError):
            errors.append("adjudication timestamp is invalid")

    metadata_errors = validate_collection_metadata(resolution.get("collectionMetadata"))
    errors.extend(f"adjudicated {error}" for error in metadata_errors)

    is_usable = resolution.get("isVideoUsable") is True
    boundaries = resolution.get("phaseBoundaries") or []
    phase_names = [item.get("phase") for item in boundaries]
    if is_usable:
        if len(boundaries) != len(PHASES) or set(phase_names) != set(PHASES):
            errors.append("adjudication must decide all ten serve phases")
        ordered_visible: list[tuple[float, float, str]] = []
        for item in boundaries:
            phase = item.get("phase", "unknown")
            if item.get("isVisible"):
                start, end = item.get("startTime"), item.get("endTime")
                if start is None or end is None:
                    errors.append(f"visible adjudicated phase {phase} has incomplete timing")
                elif not is_number(start) or not is_number(end):
                    errors.append(f"adjudicated phase {phase} timing must be numeric")
                elif end < start:
                    errors.append(f"adjudicated phase {phase} ends before it starts")
                else:
                    ordered_visible.append((start, end, phase))
            elif item.get("startTime") is not None or item.get("endTime") is not None:
                errors.append(f"invisible adjudicated phase {phase} contains fabricated timing")
        order = {phase: index for index, phase in enumerate(PHASES)}
        ordered_visible.sort(key=lambda item: order.get(item[2], len(order)))
        for previous, current in zip(ordered_visible, ordered_visible[1:]):
            if current[0] < previous[0] or current[1] < previous[1]:
                errors.append("adjudicated phase boundaries are not chronological")
                break
        techniques = resolution.get("techniqueRatings") or []
        technique_names = [item.get("label") for item in techniques]
        if len(techniques) != len(TECHNIQUES) or set(technique_names) != TECHNIQUES:
            errors.append("adjudication must decide all six technique labels")
        for item in techniques:
            rating = item.get("rating")
            if item.get("isVisible") and (not isinstance(rating, int) or isinstance(rating, bool) or not 1 <= rating <= 5):
                errors.append(f"visible technique {item.get('label')} needs a 1–5 rating")
            if not item.get("isVisible") and rating is not None:
                errors.append(f"invisible technique {item.get('label')} contains a fabricated rating")
        if resolution.get("topPriority") not in TECHNIQUES:
            errors.append("adjudication must select one valid top priority")
        else:
            errors.extend(f"adjudicated {error}" for error in validate_priority(techniques, resolution.get("topPriority")))
    elif not str(resolution.get("unusableReason", "")).strip():
        errors.append("unusable adjudication requires a reason")
    return errors


def compile_ground_truth(resolution: dict, annotations: list[dict]) -> dict:
    first = annotations[0]
    metadata = resolution["collectionMetadata"]
    return {
        "schemaVersion": GROUND_TRUTH_SCHEMA,
        "rubric": CURRENT_RUBRIC_BINDING,
        "groundTruthID": resolution["adjudicationID"],
        "analysisID": resolution["analysisID"],
        "participantPseudonym": first["participantPseudonym"],
        "cameraAngle": first["cameraAngle"],
        "skillLevel": first["skillLevel"],
        "featureEvidenceDigest": feature_evidence_digest(first["modelFeatureEvidence"]),
        "sourceVideoSHA256": first["modelFeatureEvidence"]["provenance"]["videoSHA256"],
        "collectionMetadata": metadata,
        "cohorts": {
            "cameraAngle": first["cameraAngle"],
            "skillLevel": first["skillLevel"],
            "dominantHand": metadata["dominantHand"],
            "environment": metadata["environment"],
            "lighting": metadata["lighting"],
            "sourceDeviceCategory": metadata["sourceDeviceCategory"],
            "sourceDeviceModel": metadata["sourceDeviceModel"],
            "subjectContrast": metadata["subjectContrast"],
            "resolution": resolution_cohort(metadata),
            "frameRate": frame_rate_cohort(metadata),
        },
        "sourceAnnotationIDs": resolution["sourceAnnotationIDs"],
        "sourceCoachIDs": sorted(item["annotatorPseudonym"] for item in annotations),
        "adjudicatorPseudonym": resolution["adjudicatorPseudonym"],
        "adjudicatedAt": resolution["createdAt"],
        "isVideoUsable": resolution["isVideoUsable"],
        "unusableReason": resolution.get("unusableReason"),
        "phaseBoundaries": resolution.get("phaseBoundaries", []),
        "techniqueRatings": resolution.get("techniqueRatings", []),
        "topPriority": resolution.get("topPriority"),
        "decisionNotes": resolution["decisionNotes"],
        "consentEvidence": [
            {
                "annotationID": item["annotationID"],
                "consentRecordID": item["consent"]["consentRecordID"],
                "latestDecisionID": item["consent"]["decisionHistory"][-1]["id"],
            }
            for item in annotations
        ],
        "groundTruthEligible": True,
        "modelReleaseEligible": False,
        "groundTruthPolicy": "Every disagreement was explicitly resolved by an independent signed adjudicator; no values were averaged.",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("annotations", nargs="+", type=Path)
    parser.add_argument("--resolution", type=Path, required=True)
    parser.add_argument("--coach-registry", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    try:
        registry = load_verified_registry(args.coach_registry, require_registry_secret())
        annotations = [load_json(path) for path in args.annotations]
        if len({item.get("annotatorPseudonym") for item in annotations}) < 2:
            raise ValueError("two distinct source coaches are required")
        if len({item.get("analysisID") for item in annotations}) != 1:
            raise ValueError("source annotations do not describe the same analysis")
        if len({item.get("participantPseudonym") for item in annotations}) != 1:
            raise ValueError("source annotations disagree on participant identity")
        if len({item.get("cameraAngle") for item in annotations}) != 1:
            raise ValueError("source annotations disagree on camera angle")
        if len({item.get("skillLevel") for item in annotations}) != 1:
            raise ValueError("source annotations disagree on skill level")
        failures: list[str] = []
        for path, annotation in zip(args.annotations, annotations, strict=True):
            failures.extend(validate_annotation(annotation, path, set(registry)))
            if not failures:
                verify_artifact_signature(path, annotation["annotatorPseudonym"], registry)
        resolution = load_json(args.resolution)
        failures.extend(validate_resolution(resolution, annotations, registry))
        if not failures:
            verify_artifact_signature(args.resolution, resolution["adjudicatorPseudonym"], registry)
        if failures:
            raise ValueError("\n".join(f"- {item}" for item in failures))
    except (CoachAuthorizationError, KeyError, ValueError) as error:
        print("Adjudication stopped; no ground-truth file was written.")
        print(error)
        return 1

    ground_truth = compile_ground_truth(resolution, annotations)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(ground_truth, indent=2, sort_keys=True) + "\n")
    print(f"wrote signed, explicitly adjudicated ground truth to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
