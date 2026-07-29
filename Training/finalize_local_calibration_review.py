#!/usr/bin/env python3
"""Validate and normalize a human-reviewed local calibration submission."""

from __future__ import annotations

import argparse
import copy
import json
from datetime import datetime
from pathlib import Path

from coach_rubric import CURRENT_BINDING, TECHNIQUES


PHASES = (
    "startingStance", "ballToss", "loading", "trophyPosition", "legDrive",
    "racketDrop", "upwardAcceleration", "contactPosition", "pronation", "followThrough",
)
HANDS = {"right", "left"}
SKILLS = {"beginner", "intermediate", "advanced", "competitive"}


def validate_and_normalize(review: dict, manifest: dict) -> dict:
    errors: list[str] = []
    if review.get("schemaVersion") != 1 or review.get("purpose") != "human-reviewed-local-calibration":
        errors.append("review identity is invalid")
    if review.get("participantPseudonym") != manifest.get("participantPseudonym"):
        errors.append("participant does not match the calibration manifest")
    if review.get("dominantHand") not in HANDS:
        errors.append("dominant hand is missing or invalid")
    if review.get("skillLevel") not in SKILLS:
        errors.append("skill level is missing or invalid")
    if review.get("cameraAngle") != manifest.get("cameraAngle"):
        errors.append("camera angle does not match the calibration manifest")
    try:
        datetime.fromisoformat(str(review.get("createdAt")).replace("Z", "+00:00"))
    except ValueError:
        errors.append("review timestamp is invalid")

    manifest_sources = {item["filename"]: item for item in manifest.get("sources") or []}
    reviewed_sources = review.get("sources")
    if not isinstance(reviewed_sources, list):
        reviewed_sources = []
        errors.append("reviewed sources are missing")
    if {item.get("filename") for item in reviewed_sources if isinstance(item, dict)} != set(manifest_sources):
        errors.append("reviewed source set does not match the manifest")

    normalized = copy.deepcopy(review)
    for source in normalized.get("sources") or []:
        filename = source.get("filename")
        expected = manifest_sources.get(filename)
        if expected is None:
            continue
        prefix = f"{filename}: "
        if source.get("sourceVideoSHA256") != expected.get("sha256"):
            errors.append(prefix + "source fingerprint does not match")
        candidates = {item["id"]: item for item in expected.get("candidates") or []}
        selected = candidates.get(source.get("selectedCandidateID"))
        if selected is None:
            errors.append(prefix + "selected serve window is invalid")
        anchors = source.get("phaseAnchors")
        if not isinstance(anchors, dict) or set(anchors) != set(PHASES):
            errors.append(prefix + "all ten phase anchors are required")
        else:
            times = [anchors[phase] for phase in PHASES]
            if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in times):
                errors.append(prefix + "phase anchors must be numeric")
            elif times != sorted(times):
                errors.append(prefix + "phase anchors must be chronological")
            elif selected and (times[0] < selected["startTime"] or times[-1] > selected["endTime"]):
                errors.append(prefix + "phase anchors fall outside the selected serve")
        ratings = source.get("techniqueRatings")
        if not isinstance(ratings, dict) or set(ratings) != TECHNIQUES:
            errors.append(prefix + "all six rubric techniques are required")
            continue
        visible_ratings: dict[str, int] = {}
        for label, item in ratings.items():
            if not isinstance(item, dict) or not isinstance(item.get("isVisible"), bool):
                errors.append(prefix + f"{label} visibility is invalid")
                continue
            rating = item.get("rating")
            if isinstance(rating, str) and rating.isdigit():
                rating = int(rating)
                item["rating"] = rating
            if item["isVisible"]:
                if isinstance(rating, bool) or not isinstance(rating, int) or not 1 <= rating <= 5:
                    errors.append(prefix + f"{label} needs a visible 1–5 rating")
                else:
                    visible_ratings[label] = rating
            elif rating not in (None, ""):
                errors.append(prefix + f"{label} is hidden but contains a rating")
            else:
                item["rating"] = None
        priority = source.get("topPriority")
        if priority not in visible_ratings:
            errors.append(prefix + "priority must be a visible rated technique")
        elif visible_ratings[priority] != min(visible_ratings.values()):
            errors.append(prefix + "priority must be one of the lowest-rated visible techniques")
        if source.get("reviewed") is not True:
            errors.append(prefix + "review confirmation is missing")

    if errors:
        raise ValueError("\n".join(errors))
    normalized["rubric"] = dict(CURRENT_BINDING)
    normalized["validation"] = {
        "status": "VALIDATED LOCAL CALIBRATION — not release ground truth",
        "trainingEligible": False,
        "blockingRequirements": [
            "signed training consent",
            "original-video-bound iPhone pose evidence",
            "independent release validation",
        ],
    }
    return normalized


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("review", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    review = json.loads(args.review.read_text())
    manifest = json.loads(args.manifest.read_text())
    normalized = validate_and_normalize(review, manifest)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(normalized, indent=2) + "\n")
    print(f"validated calibration review: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
