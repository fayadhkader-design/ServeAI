#!/usr/bin/env python3
"""Build provenance-bound crop derivatives for pose-calibration checks."""

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


def build_derivative_plan(
    device_manifest: dict,
    clip_directory: Path,
    crop: dict[str, int],
) -> list[dict]:
    if device_manifest.get("purpose") != "local-calibration-device-input":
        raise ValueError("manifest is not a local calibration device-input package")
    if device_manifest.get("trainingEligible") is not False:
        raise ValueError("calibration derivatives must not be created from a training-eligible package")

    plans = []
    for clip in device_manifest.get("clips") or []:
        source = clip_directory / clip["filename"]
        if not source.is_file() or sha256(source) != clip["clipSHA256"]:
            raise ValueError(f"{clip['clipID']}: selected clip fingerprint does not match")
        metadata = clip["videoMetadata"]
        if (
            crop["x"] < 0
            or crop["y"] < 0
            or crop["width"] <= 0
            or crop["height"] <= 0
            or crop["x"] + crop["width"] > metadata["width"]
            or crop["y"] + crop["height"] > metadata["height"]
        ):
            raise ValueError(f"{clip['clipID']}: crop leaves the source frame")
        if any(value % 2 for value in crop.values()):
            raise ValueError("H.264 calibration crop coordinates and dimensions must be even")
        plans.append({
            "clipID": clip["clipID"],
            "source": source,
            "sourceSHA256": clip["clipSHA256"],
            "sourceMetadata": metadata,
            "crop": dict(crop),
            "humanReview": clip["humanReview"],
        })
    if not plans:
        raise ValueError("manifest does not contain calibration clips")
    return plans


def materialize(plan: dict, output: Path) -> dict:
    crop = plan["crop"]
    target_width = plan["sourceMetadata"]["width"]
    target_height = plan["sourceMetadata"]["height"]
    video_filter = (
        f"crop={crop['width']}:{crop['height']}:{crop['x']}:{crop['y']},"
        f"scale={target_width}:{target_height}:flags=lanczos,setsar=1,"
        "format=yuv420p,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709"
    )
    subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", str(plan["source"]),
            "-map", "0:v:0", "-map", "0:a:0?",
            "-vf", video_filter,
            "-c:v", "libx264", "-preset", "slow", "-crf", "15",
            "-profile:v", "high", "-level:v", "4.1",
            "-pix_fmt", "yuv420p",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
            "-c:a", "aac", "-b:a", "192k",
            "-movflags", "+faststart", "-avoid_negative_ts", "make_zero",
            "-y", str(output),
        ],
        check=True,
    )
    observed = probe(output)
    stream = observed["streams"][0]
    expected_duration = float(plan["sourceMetadata"]["duration"])
    observed_duration = float(observed["format"]["duration"])
    if abs(observed_duration - expected_duration) > 0.15:
        raise ValueError(f"{plan['clipID']}: derivative duration differs from selected clip")
    if stream["width"] != target_width or stream["height"] != target_height:
        raise ValueError(f"{plan['clipID']}: derivative output dimensions are unexpected")
    return {
        "derivativeID": f"{plan['clipID']}-pose-crop",
        "filename": output.name,
        "sha256": sha256(output),
        "parentSelectedClip": {
            "clipID": plan["clipID"],
            "filename": plan["source"].name,
            "sha256": plan["sourceSHA256"],
        },
        "transform": {
            "type": "fixed-center-crop-and-upscale",
            "crop": plan["crop"],
            "output": {"width": target_width, "height": target_height},
            "scaleFactor": round(target_width / plan["crop"]["width"], 6),
        },
        "videoMetadata": {
            "duration": observed_duration,
            "width": stream["width"],
            "height": stream["height"],
            "averageFrameRate": stream["avg_frame_rate"],
        },
        "humanReview": {
            "oneServeStillVisible": True,
            "fullBodyBallRacketAndLandingStillVisible": True,
            "phaseAnchors": plan["humanReview"]["phaseAnchors"],
        },
        "intendedUse": "pose-quality calibration only",
        "poseEvidenceStatus": "pending-physical-iPhone-check",
        "trainingEligible": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("device_manifest", type=Path)
    parser.add_argument("--clip-directory", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--crop-x", type=int, default=216)
    parser.add_argument("--crop-y", type=int, default=320)
    parser.add_argument("--crop-width", type=int, default=648)
    parser.add_argument("--crop-height", type=int, default=1152)
    args = parser.parse_args()

    device_manifest = json.loads(args.device_manifest.read_text())
    crop = {
        "x": args.crop_x,
        "y": args.crop_y,
        "width": args.crop_width,
        "height": args.crop_height,
    }
    plans = build_derivative_plan(device_manifest, args.clip_directory, crop)
    args.output_directory.mkdir(parents=True, exist_ok=True)
    derivatives = []
    for plan in plans:
        output = args.output_directory / f"{plan['clipID']}-pose-crop.mp4"
        derivatives.append(materialize(plan, output))
        print(f"materialized {plan['clipID']} pose crop -> {output}")

    package = {
        "schemaVersion": 1,
        "purpose": "local-calibration-pose-crop-derivatives",
        "participantPseudonym": device_manifest["participantPseudonym"],
        "parentDeviceInputManifestSHA256": sha256(args.device_manifest),
        "derivatives": derivatives,
        "trainingEligible": False,
        "limitations": [
            "Crop derivatives are not original camera evidence.",
            "Upscaling does not create new visual detail.",
            "Passing a simulator check is not physical-device release evidence.",
        ],
    }
    package_path = args.output_directory / "pose_crop_manifest.json"
    package_path.write_text(json.dumps(package, indent=2) + "\n")
    print(f"wrote pose-crop manifest: {package_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
