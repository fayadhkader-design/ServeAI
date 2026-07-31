#!/usr/bin/env python3
"""Audit pose-evidence stability without treating weak data as coaching truth.

The THETIS clips are frontal, staged, ball-free, and research-only. This tool
therefore measures only whether conservative 2D evidence can be extracted and
whether known single-frame/arm-switch failure modes occur. It never evaluates
technique accuracy or produces training labels.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parent
DEFAULT_INPUTS = (
    ROOT / "artifacts/thetis_flat_service_poses.jsonl",
    ROOT / "artifacts/thetis_kick_service_poses.jsonl",
    ROOT / "artifacts/thetis_slice_service_poses.jsonl",
)
DEFAULT_MANIFEST = ROOT / "artifacts/thetis_source_manifest.json"


def percentile(values: list[float], probability: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    position = max(0.0, min(1.0, probability)) * (len(ordered) - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def point(frame: dict, name: str) -> dict | None:
    for item in frame.get("joints", []):
        if item.get("joint") == name and item.get("isPresent", True):
            return item
    return None


def distance(first: dict, second: dict) -> float:
    return math.hypot(second["x"] - first["x"], second["y"] - first["y"])


def joint_angle(first: dict, vertex: dict, second: dict) -> float | None:
    first_vector = (first["x"] - vertex["x"], first["y"] - vertex["y"])
    second_vector = (second["x"] - vertex["x"], second["y"] - vertex["y"])
    magnitude = math.hypot(*first_vector) * math.hypot(*second_vector)
    if magnitude <= 1e-12:
        return None
    cosine = max(-1.0, min(1.0, (
        first_vector[0] * second_vector[0]
        + first_vector[1] * second_vector[1]
    ) / magnitude))
    return math.degrees(math.acos(cosine))


def torso_scale(frame: dict) -> float | None:
    neck, root = point(frame, "neck"), point(frame, "root")
    if neck and root:
        scale = distance(neck, root)
        return scale if scale > 0.04 else None
    return None


def knee_sample(frame: dict, side: str) -> tuple[float, float] | None:
    hip = point(frame, f"{side}Hip")
    knee = point(frame, f"{side}Knee")
    ankle = point(frame, f"{side}Ankle")
    if not (hip and knee and ankle):
        return None
    confidence = min(hip["confidence"], knee["confidence"], ankle["confidence"])
    if confidence < 0.35:
        return None
    angle = joint_angle(hip, knee, ankle)
    return (angle, confidence) if angle is not None else None


def clearer_knee_sample(frame: dict) -> tuple[float, float] | None:
    samples = [sample for side in ("left", "right") if (sample := knee_sample(frame, side))]
    return max(samples, key=lambda sample: sample[1], default=None)


def shoulder_direction(frame: dict) -> float | None:
    left, right = point(frame, "leftShoulder"), point(frame, "rightShoulder")
    if not (left and right) or min(left["confidence"], right["confidence"]) < 0.35:
        return None
    if distance(left, right) < 0.035:
        return None
    return math.degrees(math.atan2(right["y"] - left["y"], right["x"] - left["x"]))


def normalized_arm_heights(frames: list[dict], side: str) -> list[tuple[float, float]]:
    samples: list[tuple[float, float]] = []
    for frame in frames:
        shoulder = point(frame, f"{side}Shoulder")
        wrist = point(frame, f"{side}Wrist")
        scale = torso_scale(frame)
        if not (shoulder and wrist and scale):
            continue
        confidence = min(shoulder["confidence"], wrist["confidence"])
        if confidence < 0.35:
            continue
        samples.append(((wrist["y"] - shoulder["y"]) / scale, confidence))
    return samples


def hitting_arm(frames: list[dict]) -> str | None:
    candidates = frames[len(frames) // 2:]
    scores: dict[str, float] = {}
    for side in ("left", "right"):
        samples = normalized_arm_heights(candidates, side)
        if len(samples) < 2:
            continue
        half = max(1, len(samples) // 2)
        low = percentile([value for value, _ in samples[:half]], 0.20)
        peak = percentile([value for value, _ in samples[-half:]], 0.80)
        if low is None or peak is None:
            continue
        upward_range = max(0.0, peak - low)
        coverage = len(samples) / max(1, len(candidates))
        confidence = sum(value for _, value in samples) / len(samples)
        scores[side] = (
            min(1.5, upward_range) / 1.5 * 0.75
            + coverage * 0.10
            + confidence * 0.15
        )
    return max(scores, key=scores.get) if scores else None


def confidence_arm_switches(frames: list[dict]) -> int:
    selected: list[str] = []
    for frame in frames:
        candidates = []
        for side in ("left", "right"):
            wrist = point(frame, f"{side}Wrist")
            if wrist and wrist["confidence"] >= 0.25:
                candidates.append((wrist["confidence"], side))
        if candidates:
            selected.append(max(candidates)[1])
    return sum(first != second for first, second in zip(selected, selected[1:]))


def record_observations(record: dict) -> dict[str, bool | int]:
    frames = record.get("frames", [])
    knee_angles = [
        sample[0] for frame in frames
        if (sample := clearer_knee_sample(frame)) is not None
    ]
    plausible_knees = [angle for angle in knee_angles if 65 <= angle <= 175]
    directions = [
        direction for frame in frames
        if (direction := shoulder_direction(frame)) is not None
    ]
    arm = hitting_arm(frames)
    toss_side = "right" if arm == "left" else "left" if arm == "right" else None
    toss_samples = normalized_arm_heights(frames[:max(1, len(frames) // 2)], toss_side) if toss_side else []
    return {
        "rejectedExtremeKneeFrame": bool(knee_angles and min(knee_angles) < 65),
        "robustKneeEvidence": len(plausible_knees) >= 3 and percentile(plausible_knees, 0.20) is not None,
        "rawShoulderDirectionOver90": any(abs(value) > 90 for value in directions),
        "stableAcuteShoulderEvidence": len(directions) >= 3,
        "consistentHittingArm": arm is not None,
        "normalizedTossArmEvidence": len(toss_samples) >= 3,
        "wristConfidenceArmSwitches": confidence_arm_switches(frames),
    }


def participant_group(record: dict) -> str:
    participant = record.get("participantPseudonym", "")
    try:
        number = int(participant.rsplit("p", 1)[1])
    except (IndexError, ValueError):
        return "unknown"
    return "beginner" if number <= 31 else "expert"


def summarize(observations: list[dict]) -> dict:
    count = len(observations)
    boolean_fields = [
        "rejectedExtremeKneeFrame",
        "robustKneeEvidence",
        "rawShoulderDirectionOver90",
        "stableAcuteShoulderEvidence",
        "consistentHittingArm",
        "normalizedTossArmEvidence",
    ]
    result = {"sequenceCount": count}
    for field in boolean_fields:
        matched = sum(bool(item[field]) for item in observations)
        result[field] = {
            "count": matched,
            "rate": round(matched / count, 4) if count else 0,
        }
    switched = sum(item["wristConfidenceArmSwitches"] > 0 for item in observations)
    result["sequencesWithConfidenceBasedArmSwitches"] = {
        "count": switched,
        "rate": round(switched / count, 4) if count else 0,
    }
    result["totalConfidenceBasedArmSwitches"] = sum(
        int(item["wristConfidenceArmSwitches"]) for item in observations
    )
    return result


def audit_records(records: Iterable[dict], manifest_digest: str = "test") -> dict:
    grouped: dict[str, list[dict]] = defaultdict(list)
    overall = []
    for record in records:
        observations = record_observations(record)
        overall.append(observations)
        grouped[participant_group(record)].append(observations)
    return {
        "schemaVersion": 1,
        "auditIdentifier": "serveai.pose-evidence-stability",
        "sourceManifestSHA256": manifest_digest,
        "purpose": "Research-only coverage and failure-mode audit; not technique accuracy or coach ground truth.",
        "overall": summarize(overall),
        "participantGroups": {
            name: summarize(items) for name, items in sorted(grouped.items())
        },
        "releaseInterpretation": {
            "canCalibrateVisibilityAndRobustness": True,
            "canEstablishTechniqueAccuracy": False,
            "canTrainCommercialReleaseModel": False,
            "reasons": [
                "Frontal Kinect view is outside ServeAI's supported side/rear protocol.",
                "Clips are staged without a tennis ball.",
                "No independent ServeAI coach labels are provided.",
                "Source terms do not state a commercial-use grant.",
            ],
        },
    }


def load_records(paths: tuple[Path, ...]) -> list[dict]:
    records = []
    for path in paths:
        with path.open() as handle:
            records.extend(json.loads(line) for line in handle if line.strip())
    return records


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inputs", nargs="+", type=Path, default=list(DEFAULT_INPUTS))
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text())
    if manifest.get("productionUseAllowed") is not False:
        raise ValueError("source manifest must remain fail-closed for production use")
    records = load_records(tuple(args.inputs))
    if len(records) != manifest.get("downloadedClipCount"):
        raise ValueError("pose sequence count does not match the source manifest")
    digest = hashlib.sha256(args.manifest.read_bytes()).hexdigest()
    report = audit_records(records, digest)
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(encoded)
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
