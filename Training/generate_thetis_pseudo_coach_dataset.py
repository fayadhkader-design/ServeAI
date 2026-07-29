#!/usr/bin/env python3
"""Build a player-isolated THETIS weak-supervision dataset.

The inputs are Apple Vision poses extracted from the research-only THETIS RGB
serve clips. Labels are deterministic, observable-only 2D proxies. They are not
coach ground truth and cannot establish production coaching accuracy.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

from generate_pseudo_coach_dataset import (
    JOINTS,
    PHASES,
    TECHNIQUES,
    SourceFrame,
    _resample_feature_frames,
    build_labels,
    canonical_json,
    overhead_score,
    sha256_bytes,
)


ROOT = Path(__file__).resolve().parent
DEFAULT_POSES = (
    ROOT / "artifacts/thetis_flat_service_poses.jsonl",
    ROOT / "artifacts/thetis_kick_service_poses.jsonl",
    ROOT / "artifacts/thetis_slice_service_poses.jsonl",
)
DEFAULT_MANIFEST = ROOT / "artifacts/thetis_source_manifest.json"
DEFAULT_SOURCES = ROOT / "biomechanics_sources.json"
DEFAULT_OUTPUT = ROOT / "artifacts/thetis_pseudo_coach_dataset.json"
DATASET_IDENTIFIER = "serveai.thetis-pseudo-coach-temporal"
TEACHER_IDENTIFIER = "serveai.biomechanics-pseudo-labeler"
TEACHER_VERSION = "0.2.0-research-thetis"


def load_jsonl(paths: tuple[Path, ...]) -> tuple[list[dict], list[dict]]:
    source_records: list[dict] = []
    for path in paths:
        with path.open() as handle:
            source_records.extend(json.loads(line) for line in handle if line.strip())
    if len(source_records) != 495:
        raise ValueError(f"expected 495 extracted pose sequences, found {len(source_records)}")
    unique: list[dict] = []
    duplicates: list[dict] = []
    seen: dict[str, str] = {}
    for item in sorted(source_records, key=lambda value: value["sourceFilename"]):
        digest = item["sourceVideoSHA256"]
        if digest in seen:
            duplicates.append({
                "sourceFilename": item["sourceFilename"],
                "reason": f"exact duplicate of {seen[digest]} (same SHA-256)",
            })
        else:
            seen[digest] = item["sourceFilename"]
            unique.append(item)
    return unique, duplicates


def source_frames(record: dict) -> list[SourceFrame]:
    result = []
    for index, frame in enumerate(record["frames"]):
        joints = {
            item["joint"]: (
                float(item["x"]),
                float(item["y"]),
                float(item["confidence"]),
                bool(item["isPresent"]),
            )
            for item in frame["joints"]
        }
        if set(joints) != set(JOINTS):
            raise ValueError(f"{record['sourceFilename']} does not satisfy the joint contract")
        result.append(SourceFrame(
            source_number=index,
            raw_root_x=float(frame["rawRootX"]),
            raw_root_y=float(frame["rawRootY"]),
            raw_scale=float(frame["rawScale"]),
            body_confidence=float(frame["bodyConfidence"]),
            joints=joints,
        ))
    if len(result) < 24:
        raise ValueError(f"{record['sourceFilename']} has fewer than 24 detected pose frames")
    return result


def choose_events(frames: list[SourceFrame]) -> tuple[int, int, int, int, str, float]:
    candidates: dict[str, list[tuple[float, int]]] = {"left": [], "right": []}
    for index, frame in enumerate(frames):
        scored = overhead_score(frame)
        if scored is not None:
            score, side = scored
            candidates[side].append((score, index))

    peaks = {
        side: max(values, default=None)
        for side, values in candidates.items()
    }
    if peaks["left"] is not None and peaks["right"] is not None:
        left_score, left_index = peaks["left"]
        right_score, right_index = peaks["right"]
        if abs(left_index - right_index) >= 2:
            if left_index < right_index:
                trophy, contact, tossing_side, trophy_score = left_index, right_index, "left", left_score
            else:
                trophy, contact, tossing_side, trophy_score = right_index, left_index, "right", right_score
        else:
            contact_score, contact, hitting_side = max(
                (left_score, left_index, "left"),
                (right_score, right_index, "right"),
            )
            tossing_side = "right" if hitting_side == "left" else "left"
            trophy = max(1, contact - 4)
            trophy_score = contact_score
    else:
        available = [
            (value[0], value[1], side)
            for side, value in peaks.items() if value is not None
        ]
        if not available:
            raise ValueError("no overhead-arm event was observed")
        contact_score, contact, hitting_side = max(available)
        tossing_side = "right" if hitting_side == "left" else "left"
        trophy = max(1, contact - 4)
        trophy_score = contact_score

    if contact <= trophy:
        contact = min(len(frames) - 2, trophy + 3)
    event_span = max(6, contact - trophy)
    start = max(0, trophy - max(7, event_span))
    end = min(len(frames) - 1, contact + max(7, event_span))
    while end - start + 1 < 18 and (start > 0 or end < len(frames) - 1):
        start = max(0, start - 1)
        end = min(len(frames) - 1, end + 1)
    if end - start + 1 < 18:
        raise ValueError("serve event window is too short")
    return start, end, trophy, contact, tossing_side, trophy_score


def split_for(participant: str) -> str:
    number = int(participant.rsplit("p", 1)[1])
    if number <= 36:
        return "train"
    if number <= 44:
        return "validation"
    return "test"


def build_dataset(pose_paths: tuple[Path, ...], manifest_path: Path, sources_path: Path) -> dict:
    extracted, rejected = load_jsonl(pose_paths)
    manifest = json.loads(manifest_path.read_text())
    if manifest.get("complete") is not True or manifest.get("downloadedClipCount") != 495:
        raise ValueError("THETIS source manifest is incomplete")
    if manifest.get("productionUseAllowed") is not False:
        raise ValueError("THETIS source terms were not fail-closed")
    manifest_files = {item["derivedSHA256"]: item for item in manifest["files"]}
    sources = json.loads(sources_path.read_text())

    records = []
    for item in sorted(extracted, key=lambda value: value["sourceFilename"]):
        try:
            frames = source_frames(item)
            start, end, trophy, contact, tossing_side, trophy_score = choose_events(frames)
            timestamps = [float(frame["timestamp"]) for frame in item["frames"]]
            effective_fps = (len(timestamps) - 1) / (timestamps[-1] - timestamps[0])
            labels, events = build_labels(
                frames, start, end, trophy, tossing_side, source_fps=effective_fps
            )
            feature_frames = _resample_feature_frames(
                frames, start, end, source_fps=effective_fps
            )
            duration = (end - start) / effective_fps
            source_manifest_entry = manifest_files.get(item["sourceVideoSHA256"])
            if source_manifest_entry is None:
                raise ValueError("derived video fingerprint is absent from the source manifest")
            participant = item["participantPseudonym"]
            player_number = int(participant.rsplit("p", 1)[1])
            source_range = {
                "startSample": start,
                "endSample": end,
                "sampleCount": end - start + 1,
                "trophyProxySample": trophy,
                "contactProxySample": contact,
            }
            evidence_digest = sha256_bytes(canonical_json({
                "sourceVideoSHA256": item["sourceVideoSHA256"],
                "sourceRange": source_range,
                "frames": feature_frames,
            }))
            records.append({
                "analysisID": f"thetis-{Path(item['sourceFilename']).stem}",
                "participantPseudonym": participant,
                "split": split_for(participant),
                "cameraAngle": "front",
                "cohorts": {
                    "cameraAngle": "front-unsupported",
                    "skillLevel": "beginner" if player_number <= 31 else "expert",
                    "dominantHand": "unknown",
                    "lighting": "indoor-variable",
                    "resolution": "480p",
                    "frameRate": "17-30fps",
                    "serveType": item["serveType"],
                },
                "sourceVideoSHA256": item["sourceVideoSHA256"],
                "sourceFrameEvidenceSHA256": evidence_digest,
                "featureEvidence": {
                    "sequence": {
                        "schemaVersion": 2,
                        "duration": duration,
                        "cameraAngle": "front",
                        "frames": feature_frames,
                    },
                    "provenance": {
                        "schemaVersion": 1,
                        "encoderIdentifier": "serveai.pose-sequence",
                        "encoderVersion": "2.0.0",
                        "poseDetectorIdentifier": "apple-vision-human-body-pose",
                        "poseDetectorVersion": "VNDetectHumanBodyPoseRequest-runtime-2026-07",
                        "sourceDatasetID": "thetis-three-dimensional-tennis-shots",
                        "sourceRepositoryCommit": manifest["repositoryCommit"],
                        "sourceVideoSHA256": item["sourceVideoSHA256"],
                        "sourceFrameRange": source_range,
                        "requestedSamplesPerSecond": effective_fps,
                        "smoothingWindow": 1,
                        "sampledFrameCount": item["sampledFrameCount"],
                        "detectedFrameCount": len(item["frames"]),
                    },
                },
                "labels": labels,
                "pseudoLabelProvenance": {
                    "teacherIdentifier": TEACHER_IDENTIFIER,
                    "teacherVersion": TEACHER_VERSION,
                    "coachVerified": False,
                    "pseudoLabeled": True,
                    "sourceManifestSHA256": sha256_bytes(manifest_path.read_bytes()),
                    "biomechanicsManifestSHA256": sha256_bytes(sources_path.read_bytes()),
                    "sourceIDs": [source["id"] for source in sources["sources"]],
                    "events": events | {
                        "selectedContactProxySample": contact,
                        "sourceServeClass": item["serveType"],
                    },
                    "trophyAnchorScore": round(trophy_score, 6),
                },
            })
        except (KeyError, TypeError, ValueError) as error:
            rejected.append({"sourceFilename": item.get("sourceFilename"), "reason": str(error)})

    players_by_split = {
        split: sorted({record["participantPseudonym"] for record in records if record["split"] == split})
        for split in ("train", "validation", "test")
    }
    dataset = {
        "schemaVersion": 1,
        "datasetIdentifier": DATASET_IDENTIFIER,
        "datasetVersion": "0.2.0-research",
        "teacherIdentifier": TEACHER_IDENTIFIER,
        "teacherVersion": TEACHER_VERSION,
        "sourceDataset": {
            "id": "thetis-three-dimensional-tennis-shots",
            "repository": manifest["repository"],
            "repositoryCommit": manifest["repositoryCommit"],
            "paper": manifest["paper"],
            "sourceTerms": manifest["sourceTerms"],
            "productionUseAllowed": False,
            "sourceManifestSHA256": sha256_bytes(manifest_path.read_bytes()),
        },
        "segmentation": {
            "sourceClipCount": len(extracted) + len(rejected),
            "completeClipCount": len(records),
            "rejectedClipCount": len(rejected),
            "rejections": rejected,
            "policy": "per-clip opposite-arm overhead maxima with an 18-sample minimum event window",
        },
        "splitPolicy": "fixed player-isolated split: p1-p36 train, p37-p44 validation, p45-p55 test",
        "splitCounts": {
            split: sum(record["split"] == split for record in records)
            for split in ("train", "validation", "test")
        },
        "playerCounts": {split: len(players) for split, players in players_by_split.items()},
        "playersBySplit": players_by_split,
        "phaseVisibilityCounts": {
            phase: sum(
                next(value for value in record["labels"]["phaseBoundaries"] if value["phase"] == phase)["isVisible"]
                for record in records
            )
            for phase in PHASES
        },
        "techniqueRatingCounts": {
            technique: sum(
                next(value for value in record["labels"]["techniqueRatings"] if value["label"] == technique)["isVisible"]
                for record in records
            )
            for technique in TECHNIQUES
        },
        "groundTruthEligible": False,
        "modelReleaseEligible": False,
        "limitations": manifest["captureLimitations"] + [
            "Labels are deterministic 2D biomechanical proxies, not independent coach judgments.",
            "Player-held-out results measure pseudo-teacher agreement, not coaching accuracy.",
            "Racket drop, pronation, toss consistency, and trophy-alignment quality remain unavailable.",
        ],
        "records": records,
    }
    dataset["datasetDigest"] = hashlib.sha256(canonical_json(records)).hexdigest()
    return dataset


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--poses", nargs=3, type=Path, default=DEFAULT_POSES)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--sources", type=Path, default=DEFAULT_SOURCES)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    try:
        dataset = build_dataset(tuple(args.poses), args.manifest, args.sources)
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"THETIS pseudo-label generation stopped: {error}")
        return 1
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(dataset, indent=2, allow_nan=False) + "\n")
    print(
        f"wrote {len(dataset['records'])} player-isolated research clips to {args.output}; "
        f"players={dataset['playerCounts']}; releaseEligible=false"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
