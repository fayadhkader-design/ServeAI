#!/usr/bin/env python3
"""Create source-bound single-serve clips from a validated local review."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_clip_plan(review: dict, manifest: dict, raw_directory: Path) -> list[dict]:
    validation = review.get("validation") or {}
    if validation.get("status") != "VALIDATED LOCAL CALIBRATION — not release ground truth":
        raise ValueError("review is not a validated local calibration")
    manifest_sources = {item["filename"]: item for item in manifest.get("sources") or []}
    plans: list[dict] = []
    for reviewed in review.get("sources") or []:
        source = manifest_sources.get(reviewed.get("filename"))
        if source is None or reviewed.get("sourceVideoSHA256") != source.get("sha256"):
            raise ValueError("review source does not match the calibration manifest")
        candidate = next(
            (item for item in source.get("candidates") or [] if item["id"] == reviewed.get("selectedCandidateID")),
            None,
        )
        if candidate is None:
            raise ValueError(f"{source['filename']}: selected candidate is missing")
        original = raw_directory / source["filename"]
        if not original.is_file() or sha256(original) != source["sha256"]:
            raise ValueError(f"{source['filename']}: original fingerprint does not match")
        start = float(candidate["startTime"])
        end = float(candidate["endTime"])
        anchors = {
            phase: round(float(timestamp) - start, 6)
            for phase, timestamp in reviewed["phaseAnchors"].items()
        }
        if min(anchors.values()) < 0 or max(anchors.values()) > end - start:
            raise ValueError(f"{source['filename']}: rebased phase anchors leave the selected clip")
        plans.append({
            "clipID": candidate["id"],
            "participantPseudonym": review["participantPseudonym"],
            "original": original,
            "originalFilename": source["filename"],
            "originalSHA256": source["sha256"],
            "selection": {
                "startTime": start,
                "endTime": end,
                "duration": end - start,
            },
            "rebasedPhaseAnchors": anchors,
            "techniqueRatings": reviewed["techniqueRatings"],
            "topPriority": reviewed["topPriority"],
            "reviewerNotes": reviewed.get("notes") or "",
        })
    if len(plans) != len(manifest_sources):
        raise ValueError("validated review does not select exactly one serve per source")
    return plans


def probe(path: Path) -> dict:
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_entries", "stream=width,height,avg_frame_rate:format=duration",
            "-of", "json", str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def materialize(plan: dict, output: Path) -> dict:
    duration = plan["selection"]["duration"]
    subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-ss", f"{plan['selection']['startTime']:.6f}",
            "-i", str(plan["original"]),
            "-t", f"{duration:.6f}",
            "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "libx264", "-preset", "slow", "-crf", "15",
            "-pix_fmt", "yuv420p",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart", "-avoid_negative_ts", "make_zero",
            "-y", str(output),
        ],
        check=True,
    )
    metadata = probe(output)
    observed_duration = float(metadata["format"]["duration"])
    if abs(observed_duration - duration) > 0.15:
        raise ValueError(f"{plan['clipID']}: materialized duration differs from its selection")
    stream = metadata["streams"][0]
    return {
        "clipID": plan["clipID"],
        "participantPseudonym": plan["participantPseudonym"],
        "filename": output.name,
        "clipSHA256": sha256(output),
        "parentSource": {
            "filename": plan["originalFilename"],
            "sha256": plan["originalSHA256"],
            "selection": plan["selection"],
        },
        "videoMetadata": {
            "duration": observed_duration,
            "width": stream["width"],
            "height": stream["height"],
            "averageFrameRate": stream["avg_frame_rate"],
        },
        "humanReview": {
            "oneServeConfirmed": True,
            "phaseAnchors": plan["rebasedPhaseAnchors"],
            "techniqueRatings": plan["techniqueRatings"],
            "topPriority": plan["topPriority"],
            "notes": plan["reviewerNotes"],
        },
        "poseEvidenceStatus": "pending-iPhone-extraction",
        "trainingEligible": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("review", type=Path)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--raw-directory", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    args = parser.parse_args()
    review = json.loads(args.review.read_text())
    manifest = json.loads(args.manifest.read_text())
    plans = build_clip_plan(review, manifest, args.raw_directory)
    args.output_directory.mkdir(parents=True, exist_ok=True)
    records = []
    for plan in plans:
        output = args.output_directory / f"{plan['clipID']}.mp4"
        records.append(materialize(plan, output))
        print(f"materialized {plan['clipID']} -> {output}")
    package = {
        "schemaVersion": 1,
        "purpose": "local-calibration-device-input",
        "participantPseudonym": review["participantPseudonym"],
        "rubric": review["rubric"],
        "reviewCreatedAt": review["createdAt"],
        "clips": records,
        "trainingEligible": False,
        "blockingRequirements": [
            "signed training consent",
            "clip-bound iPhone pose evidence",
            "independent release validation",
        ],
    }
    package_path = args.output_directory / "device_input_manifest.json"
    package_path.write_text(json.dumps(package, indent=2) + "\n")
    print(f"wrote device-input manifest: {package_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
