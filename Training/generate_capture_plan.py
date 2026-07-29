#!/usr/bin/env python3
"""Generate a deterministic, participant-isolated ServeAI capture plan.

The plan contains study pseudonyms and collection targets only. It intentionally
contains no names, contact details, or recruitment records.
"""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


PARTICIPANTS = 60
CLIPS_PER_PARTICIPANT = 5
SKILLS = ("beginner", "intermediate", "advanced", "competitive")
LIGHTING = ("evenDaylight", "harshSun", "indoorBright", "lowLight")
CONTRAST = ("typical", "high", "typical", "low")
RESOLUTION = ("1080p", "720p", "1080p", "4k")
FRAME_RATE = ("60fps", "30fps", "60fps", "120fps")
IPHONE_STUDY_CODES = ("iPhone-current-A", "iPhone-current-B", "iPhone-older-A", "iPhone-pro-A")
ISSUES = ("poorFraming", "occlusion", "lowLight", "multiplePeople", "motionBlur")


def participant_split(number: int) -> str:
    if number <= 36:
        return "train"
    if number <= 48:
        return "validation"
    return "test"


def build_plan() -> dict:
    slots: list[dict] = []
    global_clip = 0
    for participant_number in range(1, PARTICIPANTS + 1):
        participant = f"participant-{participant_number:03d}"
        split = participant_split(participant_number)
        skill = SKILLS[(participant_number - 1) % len(SKILLS)]
        hand = "left" if participant_number % 5 == 0 else "right"
        for serve_number in range(1, CLIPS_PER_PARTICIPANT + 1):
            global_clip += 1
            rotation = global_clip - 1
            issue_tags = [ISSUES[rotation % len(ISSUES)]] if global_clip <= 50 else []
            slots.append(
                {
                    "slotID": f"slot-{global_clip:03d}",
                    "participantPseudonym": participant,
                    "split": split,
                    "serveNumber": serve_number,
                    "cameraAngle": "side" if (participant_number + serve_number) % 2 == 0 else "rear",
                    "skillLevel": skill,
                    "dominantHand": hand,
                    "environment": "indoor" if rotation % 3 == 0 else "outdoor",
                    "lighting": LIGHTING[rotation % len(LIGHTING)],
                    "subjectContrast": CONTRAST[rotation % len(CONTRAST)],
                    "resolution": RESOLUTION[rotation % len(RESOLUTION)],
                    "frameRate": FRAME_RATE[rotation % len(FRAME_RATE)],
                    "sourceDeviceCategory": "iPhone",
                    "sourceDeviceModel": IPHONE_STUDY_CODES[rotation % len(IPHONE_STUDY_CODES)],
                    "recordingIssueTags": issue_tags,
                    "requiredIndependentCoachLabels": 2,
                    "requiresThirdCoachIfDisputed": True,
                }
            )

    coverage_requirements = [
        {"dimension": "Participant isolation", "target": "36 train / 12 validation / 12 test participants", "reason": "Prevents the same player's mechanics leaking across splits."},
        {"dimension": "Supported views", "target": "150 side / 150 rear clips", "reason": "Matches the two camera views supported by the app."},
        {"dimension": "Skill", "target": "75 clips per skill level", "reason": "Tests advice across beginner through competitive mechanics."},
        {"dimension": "Handedness", "target": "≥ 60 left-handed clips", "reason": "Exceeds the 30-clip overall and 5-clip held-out audit floors."},
        {"dimension": "Lighting", "target": "Every lighting cohort in every split", "reason": "Exposes pose and visibility failures that averages can hide."},
        {"dimension": "Capture format", "target": "720p / 1080p / 4K and 30 / 60 / 120 FPS", "reason": "Covers supported device capture variation."},
        {"dimension": "iPhone hardware", "target": "≥ 4 study-coded models", "reason": "Meets the collection audit without storing personal device identifiers."},
        {"dimension": "Failure examples", "target": "50 clips; ≥ 10 for each issue tag", "reason": "Trains and evaluates the fail-closed usable-video gate."},
        {"dimension": "Labeling", "target": "2 blind coaches + third-coach adjudication", "reason": "Creates defensible technique and priority ground truth."},
    ]
    counts = {
        "split": Counter(slot["split"] for slot in slots),
        "cameraAngle": Counter(slot["cameraAngle"] for slot in slots),
        "skillLevel": Counter(slot["skillLevel"] for slot in slots),
        "dominantHand": Counter(slot["dominantHand"] for slot in slots),
        "lighting": Counter(slot["lighting"] for slot in slots),
        "frameRate": Counter(slot["frameRate"] for slot in slots),
        "recordingIssue": Counter(tag for slot in slots for tag in slot["recordingIssueTags"]),
    }
    return {
        "schemaVersion": 1,
        "planID": "serveai-target-domain-pilot-v1",
        "purpose": "Collect consented, real-ball iPhone side/rear serves for coach-ground-truth training and held-out evaluation.",
        "containsPersonalData": False,
        "summary": {
            "targetClips": len(slots),
            "minimumParticipants": PARTICIPANTS,
            "trainClips": 180,
            "validationClips": 60,
            "heldOutClips": 60,
        },
        "protocol": {
            "consentVersion": "2026-07",
            "participantSplitPolicy": "A participant pseudonym belongs to exactly one fixed split.",
            "capture": "One complete real-ball serve; stationary iPhone; full body and racket visible; side or rear view; 10–15 feet away; normal speed; 60 FPS when available.",
            "labeling": "Two qualified coaches label independently; a third qualified coach signs explicit adjudication for every disagreement.",
            "testSetLock": "Test videos and labels remain inaccessible to tuning until model and thresholds are frozen.",
        },
        "coverageRequirements": coverage_requirements,
        "plannedCounts": {name: dict(sorted(values.items())) for name, values in counts.items()},
        "slots": slots,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "artifacts" / "target_capture_plan.json")
    arguments = parser.parse_args()
    plan = build_plan()
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    arguments.output.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
    print(f"wrote {plan['summary']['targetClips']} capture slots to {arguments.output}")


if __name__ == "__main__":
    main()
