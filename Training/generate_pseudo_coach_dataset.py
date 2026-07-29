#!/usr/bin/env python3
"""Build transparent research-only serve labels from licensed 2D poses.

This is weak supervision, not a substitute for a tennis coach. The labeler uses
only measurements available from COCO body joints and deliberately marks
    racket drop, pronation, and toss placement unavailable. Its output cannot be
fed into the signed coach-ground-truth pipeline or satisfy release gates.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from dataclasses import dataclass
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parent
DEFAULT_ANNOTATIONS = ROOT / "data/raw/tennis_player_actions/annotations/serve.json"
DEFAULT_SOURCES = ROOT / "biomechanics_sources.json"
DEFAULT_OUTPUT = ROOT / "artifacts/pseudo_coach_dataset.json"
TEACHER_IDENTIFIER = "serveai.biomechanics-pseudo-labeler"
TEACHER_VERSION = "0.1.0-research"
SOURCE_DATASET_ID = "tennis-player-actions-v1"
SOURCE_FPS = 30.0
RESAMPLED_STEPS = 24
MIN_ANCHOR_SEPARATION = 8

PHASES = (
    "startingStance", "ballToss", "loading", "trophyPosition", "legDrive",
    "racketDrop", "upwardAcceleration", "contactPosition", "pronation", "followThrough",
)
TECHNIQUES = (
    "tossPlacement", "loadingSequence", "trophyAlignment",
    "legDriveTiming", "contactReach", "landingBalance",
)
JOINTS = (
    "nose", "neck", "root", "leftShoulder", "rightShoulder", "leftElbow", "rightElbow",
    "leftWrist", "rightWrist", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle",
)
COCO_NAMES = {
    "nose": "nose",
    "neck": "neck",
    "leftShoulder": "left_shoulder",
    "rightShoulder": "right_shoulder",
    "leftElbow": "left_elbow",
    "rightElbow": "right_elbow",
    "leftWrist": "left_wrist",
    "rightWrist": "right_wrist",
    "leftHip": "left_hip",
    "rightHip": "right_hip",
    "leftKnee": "left_knee",
    "rightKnee": "right_knee",
    "leftAnkle": "left_ankle",
    "rightAnkle": "right_ankle",
}


@dataclass(frozen=True)
class SourceFrame:
    source_number: int
    raw_root_x: float
    raw_root_y: float
    raw_scale: float
    body_confidence: float
    joints: dict[str, tuple[float, float, float, bool]]


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _finite_point(points: np.ndarray, visibility: np.ndarray, index: int) -> np.ndarray | None:
    if visibility[index] <= 0 or not np.all(np.isfinite(points[index])):
        return None
    return points[index]


def load_source_frames(path: Path) -> tuple[list[SourceFrame], str]:
    payload = json.loads(path.read_text())
    names = payload["categories"][0]["keypoints"]
    indices = {name: index for index, name in enumerate(names)}
    images = {item["id"]: item for item in payload["images"]}
    annotations = sorted(
        payload["annotations"],
        key=lambda item: images[item["image_id"]]["file_name"],
    )
    frames: list[SourceFrame] = []
    for annotation in annotations:
        image = images[annotation["image_id"]]
        source_number = int(Path(image["file_name"]).stem.split("_")[-1])
        encoded = np.asarray(annotation["keypoints"], dtype=np.float64).reshape(-1, 3)
        visibility = encoded[:, 2]
        points = encoded[:, :2] / np.asarray([image["width"], image["height"]])
        points[:, 1] = 1.0 - points[:, 1]

        hips = [
            _finite_point(points, visibility, indices[name])
            for name in ("left_hip", "right_hip")
        ]
        hips = [point for point in hips if point is not None]
        visible_points = points[visibility > 0]
        if not hips or not len(visible_points):
            raise ValueError(f"source frame {source_number} lacks a usable body center")
        root = np.mean(hips, axis=0)
        scale_candidates = []
        for name in ("nose", "neck", "left_ankle", "right_ankle"):
            point = _finite_point(points, visibility, indices[name])
            if point is not None:
                scale_candidates.append(float(np.linalg.norm(point - root)))
        if not scale_candidates:
            scale_candidates = [float(np.linalg.norm(point - root)) for point in visible_points]
        scale = max(max(scale_candidates), 0.10)

        joints: dict[str, tuple[float, float, float, bool]] = {}
        for body_name in JOINTS:
            if body_name == "root":
                hip_confidences = [visibility[indices[name]] / 2 for name in ("left_hip", "right_hip") if visibility[indices[name]] > 0]
                confidence = float(np.mean(hip_confidences)) if hip_confidences else 0.0
                joints[body_name] = (0.0, 0.0, confidence, bool(hip_confidences))
                continue
            source_name = COCO_NAMES[body_name]
            source_index = indices[source_name]
            point = _finite_point(points, visibility, source_index)
            if point is None:
                joints[body_name] = (0.0, 0.0, 0.0, False)
            else:
                normalized = (point - root) / scale
                joints[body_name] = (
                    float(normalized[0]),
                    float(normalized[1]),
                    float(min(1.0, visibility[source_index] / 2)),
                    True,
                )
        body_confidence = float(np.mean([item[2] for item in joints.values() if item[3]]))
        frames.append(SourceFrame(
            source_number=source_number,
            raw_root_x=float(root[0]),
            raw_root_y=float(root[1]),
            raw_scale=scale,
            body_confidence=body_confidence,
            joints=joints,
        ))
    if len(frames) < 40:
        raise ValueError("source annotation sequence is too short for temporal pseudo-labeling")
    if [frame.source_number for frame in frames] != sorted(frame.source_number for frame in frames):
        raise ValueError("source frame numbers are not ordered")
    return frames, sha256_bytes(path.read_bytes())


def _joint(frame: SourceFrame, name: str) -> np.ndarray | None:
    x, y, confidence, present = frame.joints[name]
    if not present or confidence < 0.25:
        return None
    return np.asarray([x, y], dtype=np.float64)


def _angle(first: np.ndarray, vertex: np.ndarray, second: np.ndarray) -> float | None:
    a = first - vertex
    b = second - vertex
    denominator = float(np.linalg.norm(a) * np.linalg.norm(b))
    if denominator <= 1e-9:
        return None
    cosine = float(np.clip(np.dot(a, b) / denominator, -1.0, 1.0))
    return math.degrees(math.acos(cosine))


def elbow_angle(frame: SourceFrame, side: str) -> float | None:
    shoulder = _joint(frame, f"{side}Shoulder")
    elbow = _joint(frame, f"{side}Elbow")
    wrist = _joint(frame, f"{side}Wrist")
    if shoulder is None or elbow is None or wrist is None:
        return None
    return _angle(shoulder, elbow, wrist)


def knee_angle(frame: SourceFrame, side: str) -> float | None:
    hip = _joint(frame, f"{side}Hip")
    knee = _joint(frame, f"{side}Knee")
    ankle = _joint(frame, f"{side}Ankle")
    if hip is None or knee is None or ankle is None:
        return None
    return _angle(hip, knee, ankle)


def shoulder_tilt(frame: SourceFrame) -> float | None:
    left = _joint(frame, "leftShoulder")
    right = _joint(frame, "rightShoulder")
    if left is None or right is None:
        return None
    delta = right - left
    angle = abs(math.degrees(math.atan2(float(delta[1]), float(delta[0]))))
    return min(angle, 180.0 - angle)


def overhead_score(frame: SourceFrame) -> tuple[float, str] | None:
    candidates: list[tuple[float, float, float, str]] = []
    for side in ("left", "right"):
        wrist = _joint(frame, f"{side}Wrist")
        angle = elbow_angle(frame, side)
        if wrist is not None and angle is not None:
            candidates.append((float(wrist[1]), angle, frame.joints[f"{side}Wrist"][2], side))
    if not candidates:
        return None
    candidates.sort(reverse=True)
    high, extension, confidence, side = candidates[0]
    low = min(item[0] for item in candidates)
    score = high + 0.45 * (high - low) + 0.0025 * extension + 0.08 * confidence
    if high < 0.45 or extension < 115:
        return None
    return score, side


def detect_overhead_anchors(frames: list[SourceFrame]) -> list[tuple[int, str, float]]:
    scored = [overhead_score(frame) for frame in frames]
    candidates: list[tuple[int, str, float]] = []
    for index in range(2, len(frames) - 2):
        if scored[index] is None:
            continue
        score, side = scored[index]
        neighborhood = [item[0] for item in scored[index - 2:index + 3] if item is not None]
        if neighborhood and score >= max(neighborhood):
            candidates.append((index, side, score))
    selected: list[tuple[int, str, float]] = []
    for candidate in sorted(candidates, key=lambda item: item[2], reverse=True):
        if all(abs(candidate[0] - item[0]) >= MIN_ANCHOR_SEPARATION for item in selected):
            selected.append(candidate)
    return sorted(selected)


def segment_complete_serves(
    frames: list[SourceFrame],
    anchors: list[tuple[int, str, float]],
) -> list[tuple[int, int, int, str, float]]:
    segments: list[tuple[int, int, int, str, float]] = []
    for previous, current, following in zip(anchors, anchors[1:], anchors[2:]):
        anchor, side, score = current
        start = (previous[0] + anchor) // 2 + 1
        end = (anchor + following[0]) // 2
        if start < anchor < end and end - start + 1 >= 6:
            segments.append((start, end, anchor, side, score))
    if len(segments) < 12:
        raise ValueError("too few complete overhead-event cycles were detected")
    return segments


def _best_loading_index(frames: list[SourceFrame], start: int, anchor: int) -> int:
    best_index = max(start, anchor - 3)
    best_angle = math.inf
    for index in range(start, anchor + 1):
        angles = [value for side in ("left", "right") if (value := knee_angle(frames[index], side)) is not None]
        if angles and min(angles) < best_angle:
            best_angle = min(angles)
            best_index = index
    return best_index


def _contact_proxy_index(
    frames: list[SourceFrame],
    trophy_anchor: int,
    end: int,
    hitting_side: str,
) -> int:
    best_index = trophy_anchor
    best_score = -math.inf
    tossing_side = "right" if hitting_side == "left" else "left"
    for index in range(trophy_anchor, end + 1):
        hitting_wrist = _joint(frames[index], f"{hitting_side}Wrist")
        tossing_wrist = _joint(frames[index], f"{tossing_side}Wrist")
        extension = elbow_angle(frames[index], hitting_side)
        if hitting_wrist is None or extension is None:
            continue
        asymmetry = float(hitting_wrist[1] - tossing_wrist[1]) if tossing_wrist is not None else 0.0
        score = float(hitting_wrist[1]) + 0.45 * asymmetry + 0.003 * extension
        if score > best_score:
            best_score = score
            best_index = index
    return best_index


def _rating(value: float) -> int:
    return int(max(1, min(5, 1 + round(4 * max(0.0, min(1.0, value))))))


def build_labels(
    frames: list[SourceFrame],
    start: int,
    end: int,
    anchor: int,
    tossing_side: str,
    source_fps: float = SOURCE_FPS,
) -> tuple[dict, dict]:
    hitting_side = "right" if tossing_side == "left" else "left"
    trophy = anchor
    contact = _contact_proxy_index(frames, trophy, end, hitting_side)
    loading = _best_loading_index(frames, start, trophy)
    duration = (end - start) / source_fps

    def seconds(index: int) -> float:
        return round((max(start, min(end, index)) - start) / source_fps, 6)

    pre_span = max(3, trophy - start)
    stance_end = start + max(1, int(pre_span * 0.18))
    toss_end = start + max(2, int(pre_span * 0.45))
    loading_start = min(toss_end, loading)
    contact_end = min(end, contact + 1)
    follow_start = min(end, contact_end + 1)

    phase_ranges: dict[str, tuple[int, int] | None] = {
        "startingStance": (start, stance_end),
        "ballToss": (stance_end, toss_end),
        "loading": (loading_start, max(loading_start, loading)),
        "trophyPosition": (max(start, trophy - 1), min(contact, trophy + 1)),
        "legDrive": (loading, contact),
        "racketDrop": None,
        "upwardAcceleration": (trophy, contact),
        "contactPosition": (contact, contact_end),
        "pronation": None,
        "followThrough": (follow_start, end),
    }
    phase_notes = {
        "racketDrop": "Unavailable: COCO body joints do not locate the racket head.",
        "pronation": "Unavailable: 2D body joints cannot resolve forearm rotation.",
        "contactPosition": "Low-confidence post-trophy hitting-arm extension proxy; true ball-racket impact is not observed.",
    }
    phase_boundaries = []
    for phase in PHASES:
        interval = phase_ranges[phase]
        phase_boundaries.append({
            "phase": phase,
            "startTime": seconds(interval[0]) if interval is not None else None,
            "endTime": seconds(interval[1]) if interval is not None else None,
            "isVisible": interval is not None,
            "note": phase_notes.get(phase, "Rule-derived 2D event interval; not coach verified."),
        })

    median_scale = float(np.median([frame.raw_scale for frame in frames[start:end + 1]]))
    rise = (frames[contact].raw_root_y - frames[loading].raw_root_y) / max(median_scale, 1e-6)
    loading_lead = contact - loading
    loading_score = 0.15 + min(0.55, max(0.0, rise) * 3.0) + min(0.30, loading_lead / max(pre_span, 1) * 0.45)

    velocity_candidates = []
    for index in range(max(loading + 1, start + 1), contact + 1):
        velocity = (frames[index].raw_root_y - frames[index - 1].raw_root_y) / max(median_scale, 1e-6)
        velocity_candidates.append((velocity, index))
    peak_velocity, peak_velocity_index = max(velocity_candidates, default=(0.0, loading))
    timing_score = (
        min(0.55, max(0.0, rise) * 3.0)
        + min(0.30, max(0.0, peak_velocity) * 8.0)
        + (0.15 if loading <= peak_velocity_index <= contact else 0.0)
    )

    trophy_elbow = elbow_angle(frames[trophy], hitting_side)
    trophy_tilt = shoulder_tilt(frames[trophy])

    contact_elbow = elbow_angle(frames[contact], hitting_side)
    contact_score = 0.0 if contact_elbow is None else max(0.0, min(1.0, (contact_elbow - 105.0) / 55.0))

    landing_frame = frames[end]
    left_ankle = _joint(landing_frame, "leftAnkle")
    right_ankle = _joint(landing_frame, "rightAnkle")
    landing_visible = left_ankle is not None and right_ankle is not None
    if landing_visible:
        lower, upper = sorted((float(left_ankle[0]), float(right_ankle[0])))
        width = max(upper - lower, 0.05)
        if lower <= 0 <= upper:
            landing_score = 1.0
        else:
            distance = min(abs(lower), abs(upper)) / width
            landing_score = max(0.0, 1.0 - distance)
    else:
        landing_score = 0.0

    technique_values = {
        "tossPlacement": None,
        "loadingSequence": _rating(loading_score),
        "trophyAlignment": None,
        "legDriveTiming": _rating(timing_score),
        "contactReach": _rating(contact_score),
        "landingBalance": _rating(landing_score) if landing_visible else None,
    }
    technique_notes = {
        "tossPlacement": "Unavailable because this 2D pose dataset does not track the ball.",
        "loadingSequence": f"Pseudo-rating from knee-flexion timing and {rise:.2f} body-scale center rise.",
        "trophyAlignment": (
            f"Unavailable as a quality rating: the observed 2D elbow angle is {trophy_elbow:.1f}° and shoulder-line tilt is {trophy_tilt:.1f}°, but the elevated uncalibrated view cannot map these to published 3D ranges."
            if trophy_elbow is not None and trophy_tilt is not None
            else "Unavailable: required trophy joints or calibrated 3D geometry are missing."
        ),
        "legDriveTiming": f"Pseudo-rating from load-to-overhead timing and peak 2D center velocity {peak_velocity:.3f} body units/frame.",
        "contactReach": f"Pseudo-rating from {contact_elbow:.1f}° hitting-elbow extension at the contact proxy." if contact_elbow is not None else "Hitting shoulder, elbow, or wrist was unavailable.",
        "landingBalance": "Pseudo-rating from body center relative to the visible ankle base at the segment end." if landing_visible else "Both ankles were not visible at the segment end.",
    }
    technique_ratings = [{
        "label": label,
        "rating": technique_values[label],
        "isVisible": technique_values[label] is not None,
        "note": technique_notes[label],
    } for label in TECHNIQUES]
    visible_ratings = [(label, value) for label, value in technique_values.items() if value is not None]
    top_priority = min(visible_ratings, key=lambda item: (item[1], TECHNIQUES.index(item[0])))[0]

    required_visible = [
        frame.joints[name][3]
        for frame in frames[start:end + 1]
        for name in ("leftShoulder", "rightShoulder", "leftHip", "rightHip", "leftKnee", "rightKnee")
    ]
    usable_fraction = sum(required_visible) / max(len(required_visible), 1)
    labels = {
        "isVideoUsable": usable_fraction >= 0.70,
        "unusableReason": None if usable_fraction >= 0.70 else "Fewer than 70% of core 2D joints were visible.",
        "phaseBoundaries": phase_boundaries,
        "techniqueRatings": technique_ratings,
        "topPriority": top_priority,
    }
    trophy_observation = overhead_score(frames[trophy])
    events = {
        "loadingFrame": frames[loading].source_number,
        "overheadTrophyProxyFrame": frames[trophy].source_number,
        "overheadContactProxyFrame": frames[contact].source_number,
        "tossingSideProxy": tossing_side,
        "hittingSideProxy": hitting_side,
        "trophyProxyScore": round(trophy_observation[0], 6) if trophy_observation is not None else 0.0,
        "observableWarning": "The contact proxy is the post-trophy hitting-wrist/extension maximum, not verified ball-racket impact.",
    }
    return labels, events


def _resample_feature_frames(
    frames: list[SourceFrame],
    start: int,
    end: int,
    source_fps: float = SOURCE_FPS,
) -> list[dict]:
    source_positions = np.arange(start, end + 1, dtype=np.float64)
    targets = np.linspace(start, end, RESAMPLED_STEPS)
    result = []
    for step, target in enumerate(targets):
        joints = []
        for name in JOINTS:
            values = np.asarray([frame.joints[name][:3] for frame in frames[start:end + 1]], dtype=np.float64)
            present = np.asarray([frame.joints[name][3] for frame in frames[start:end + 1]], dtype=np.float64)
            confidence = float(np.interp(target, source_positions, values[:, 2]))
            is_present = bool(np.interp(target, source_positions, present) >= 0.5 and confidence >= 0.25)
            joints.append({
                "joint": name,
                "x": float(np.interp(target, source_positions, values[:, 0])) if is_present else 0.0,
                "y": float(np.interp(target, source_positions, values[:, 1])) if is_present else 0.0,
                "confidence": confidence if is_present else 0.0,
                "isPresent": is_present,
            })
        body_confidence = float(np.interp(
            target,
            source_positions,
            [frame.body_confidence for frame in frames[start:end + 1]],
        ))
        duration = (end - start) / source_fps
        result.append({
            "timestamp": round(duration * step / (RESAMPLED_STEPS - 1), 6),
            "bodyConfidence": max(0.0, min(1.0, body_confidence)),
            "joints": joints,
        })
    return result


def build_dataset(annotation_path: Path, sources_path: Path) -> dict:
    frames, annotation_sha256 = load_source_frames(annotation_path)
    anchors = detect_overhead_anchors(frames)
    segments = segment_complete_serves(frames, anchors)
    sources = json.loads(sources_path.read_text())
    if sources.get("teacherIdentifier") != TEACHER_IDENTIFIER or sources.get("teacherVersion") != TEACHER_VERSION:
        raise ValueError("biomechanics source manifest does not match this teacher version")

    records = []
    train_end = max(1, int(len(segments) * 0.65))
    validation_end = max(train_end + 1, int(len(segments) * 0.82))
    for clip_index, (start, end, anchor, side, anchor_score) in enumerate(segments):
        split = "train" if clip_index < train_end else ("validation" if clip_index < validation_end else "test")
        duration = (end - start) / SOURCE_FPS
        labels, events = build_labels(frames, start, end, anchor, side)
        feature_frames = _resample_feature_frames(frames, start, end)
        source_range = {
            "startFrame": frames[start].source_number,
            "endFrame": frames[end].source_number,
            "frameCount": end - start + 1,
        }
        evidence_digest = sha256_bytes(canonical_json({
            "annotationSHA256": annotation_sha256,
            "sourceRange": source_range,
            "frames": feature_frames,
        }))
        records.append({
            "analysisID": f"pseudo-{clip_index + 1:03d}",
            "participantPseudonym": "public-dataset-athlete-1",
            "split": split,
            "cameraAngle": "rear",
            "cohorts": {
                "cameraAngle": "rear",
                "skillLevel": "unknown",
                "dominantHand": "unknown",
                "lighting": "outdoor-variable",
                "resolution": "720p",
                "frameRate": "30fps",
            },
            "sourceFrameEvidenceSHA256": evidence_digest,
            "featureEvidence": {
                "sequence": {
                    "schemaVersion": 2,
                    "duration": duration,
                    "cameraAngle": "rear",
                    "frames": feature_frames,
                },
                "provenance": {
                    "schemaVersion": 1,
                    "encoderIdentifier": "serveai.pose-sequence",
                    "encoderVersion": "2.0.0",
                    "poseDetectorIdentifier": "published-coco-keypoints",
                    "poseDetectorVersion": "wang-et-al-2024-v1",
                    "sourceDatasetID": SOURCE_DATASET_ID,
                    "sourceAnnotationSHA256": annotation_sha256,
                    "sourceFrameRange": source_range,
                    "requestedSamplesPerSecond": SOURCE_FPS,
                    "smoothingWindow": 1,
                    "sampledFrameCount": end - start + 1,
                    "detectedFrameCount": RESAMPLED_STEPS,
                },
            },
            "labels": labels,
            "pseudoLabelProvenance": {
                "teacherIdentifier": TEACHER_IDENTIFIER,
                "teacherVersion": TEACHER_VERSION,
                "coachVerified": False,
                "pseudoLabeled": True,
                "sourceManifestSHA256": sha256_bytes(sources_path.read_bytes()),
                "sourceIDs": [item["id"] for item in sources["sources"]],
                "events": events,
                "trophyAnchorScore": round(anchor_score, 6),
            },
        })

    visibility_counts = {
        phase: sum(
            next(item for item in record["labels"]["phaseBoundaries"] if item["phase"] == phase)["isVisible"]
            for record in records
        )
        for phase in PHASES
    }
    rating_counts = {
        technique: sum(
            next(item for item in record["labels"]["techniqueRatings"] if item["label"] == technique)["isVisible"]
            for record in records
        )
        for technique in TECHNIQUES
    }
    dataset = {
        "schemaVersion": 1,
        "datasetIdentifier": "serveai.pseudo-coach-temporal",
        "datasetVersion": "0.1.0-research",
        "teacherIdentifier": TEACHER_IDENTIFIER,
        "teacherVersion": TEACHER_VERSION,
        "sourceDataset": {
            "id": SOURCE_DATASET_ID,
            "doi": "10.17632/nv3rpsxhhk.1",
            "license": "CC BY 4.0",
            "annotationSHA256": annotation_sha256,
            "sourceFrameCount": len(frames),
        },
        "segmentation": {
            "detectedOverheadAnchorCount": len(anchors),
            "completeClipCount": len(records),
            "policy": "midpoints between consecutive overhead-arm maxima; first and last edge cycles omitted",
        },
        "splitPolicy": "contiguous same-athlete time blocks; no player-held-out generalization claim",
        "splitCounts": {split: sum(record["split"] == split for record in records) for split in ("train", "validation", "test")},
        "phaseVisibilityCounts": visibility_counts,
        "techniqueRatingCounts": rating_counts,
        "groundTruthEligible": False,
        "modelReleaseEligible": False,
        "limitations": [
            "All source serves are from one recorded athlete.",
            "Labels are deterministic 2D biomechanical proxies, not independent coach judgments.",
            "The source frame corpus does not provide original clip boundaries, camera calibration, ball contact, or racket tracking.",
            "Validation and test blocks contain the same athlete and therefore cannot measure new-player generalization.",
            "Racket drop, pronation, toss consistency, and trophy-alignment quality are intentionally unavailable.",
        ],
        "records": records,
    }
    dataset["datasetDigest"] = sha256_bytes(canonical_json(records))
    return dataset


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--annotations", type=Path, default=DEFAULT_ANNOTATIONS)
    parser.add_argument("--sources", type=Path, default=DEFAULT_SOURCES)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    try:
        dataset = build_dataset(args.annotations, args.sources)
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"Pseudo-label generation stopped: {error}")
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dataset, indent=2, allow_nan=False) + "\n")
    print(
        f"wrote {len(dataset['records'])} research-only pseudo-labeled clips to {args.output}; "
        "coachVerified=false, modelReleaseEligible=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
