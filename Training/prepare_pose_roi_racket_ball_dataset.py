#!/usr/bin/env python3
"""Build square, pose-centered crops for the target-domain object pilot.

Crop coordinates come only from Apple Vision body pose. Racket and ball labels
are transformed after the crop is frozen and are used solely as ground truth.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import statistics
import subprocess
from pathlib import Path

from prepare_racket_ball_keypoint_dataset import ALL_KEYS, createml_record, racket_box


class ROIError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_jsonl(path: Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def pose_lookup(path: Path) -> tuple[dict[str, dict], dict]:
    records = load_jsonl(path)
    if len(records) != 1:
        raise ROIError(f"{path} must contain exactly one image-group record")
    frames = records[0].get("frames") or []
    direct: dict[str, dict] = {}
    for frame in frames:
        filename = frame.get("imageFilename")
        if not filename:
            raise ROIError("pose evidence is missing imageFilename; rebuild the extractor")
        if filename in direct:
            raise ROIError(f"duplicate pose image filename: {filename}")
        direct[filename] = frame
    if not direct:
        raise ROIError("pose evidence contains no detected frames")
    fallback = {
        key: statistics.median(float(frame[key]) for frame in direct.values())
        for key in ("rawRootX", "rawRootY", "rawScale")
    }
    return direct, fallback


def roi_from_pose(pose: dict, width: int, height: int) -> dict[str, int]:
    root_x = float(pose["rawRootX"])
    root_y_top = 1.0 - float(pose["rawRootY"])
    scale = float(pose["rawScale"])
    if not all(math.isfinite(value) for value in (root_x, root_y_top, scale)):
        raise ROIError("pose ROI inputs must be finite")
    side = round(min(width * 0.60, max(width * 0.40, scale * width * 5.0)))
    side = min(side, width, height)
    center_x = root_x * width
    center_y = root_y_top * height - side * 0.35
    x = round(center_x - side / 2)
    y = round(center_y - side / 2)
    x = min(max(0, x), width - side)
    y = min(max(0, y), height - side)
    return {"x": x, "y": y, "width": side, "height": side}


def transform_point(point: dict, roi: dict, width: int, height: int) -> dict:
    if point["status"] != "visible":
        return {"status": "notVisible"}
    pixel_x, pixel_y = point["x"] * width, point["y"] * height
    return {
        "status": "visible",
        "x": (pixel_x - roi["x"]) / roi["width"],
        "y": (pixel_y - roi["y"]) / roi["height"],
    }


def point_inside(point: dict) -> bool:
    return point["status"] != "visible" or (0 <= point["x"] <= 1 and 0 <= point["y"] <= 1)


def ball_center_region_box(points: dict, width: int, height: int) -> dict | None:
    """Return a learnable context region centered on the human-labeled ball.

    A 6–10 px physical ball becomes too small for ObjectPrint's detector grid.
    The target is therefore explicitly a ball-center region, not a claim about
    the ball's exact silhouette. Downstream evaluation must use center distance.
    """
    ball = points["ballCenter"]
    if ball["status"] != "visible":
        return None
    diameter = min(64.0, max(40.0, width * 0.055))
    half_x, half_y = diameter / (2 * width), diameter / (2 * height)
    return {
        "label": "tennis_ball",
        "xmin": max(0.0, ball["x"] - half_x), "xmax": min(1.0, ball["x"] + half_x),
        "ymin": max(0.0, ball["y"] - half_y), "ymax": min(1.0, ball["y"] + half_y),
        "derivation": "human ball center plus 40–64 px context region for small-object learning",
    }


def extract_crop(source: Path, destination: Path, roi: dict, output_size: int) -> None:
    subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(source),
            "-vf", f"crop={roi['width']}:{roi['height']}:{roi['x']}:{roi['y']},scale={output_size}:{output_size}:flags=lanczos",
            "-frames:v", "1", "-q:v", "2", str(destination),
        ],
        check=True,
    )


def materialize_split(
    source_directory: Path,
    pose_path: Path,
    output_directory: Path,
    output_size: int,
) -> dict:
    direct, fallback = pose_lookup(pose_path)
    source_records = load_jsonl(source_directory / "keypoints.jsonl")
    output_directory.mkdir(parents=True)
    (output_directory / "images").mkdir()
    keypoint_records: list[dict] = []
    detector_records: list[dict] = []
    createml_records: list[dict] = []
    roi_records: list[dict] = []
    visible_count = 0
    covered_count = 0
    fallback_count = 0

    for source_record in source_records:
        image_name = Path(source_record["localImage"]).name
        pose = direct.get(image_name)
        pose_source = "direct"
        if pose is None:
            pose, pose_source = fallback, "split-median-fallback"
            fallback_count += 1
        source_image = source_directory / source_record["localImage"]
        width, height = int(source_record["pixelWidth"]), int(source_record["pixelHeight"])
        roi = roi_from_pose(pose, width, height)
        transformed = {
            key: transform_point(source_record["points"][key], roi, width, height)
            for key in ALL_KEYS
        }
        outside = [key for key, point in transformed.items() if not point_inside(point)]
        if outside:
            raise ROIError(f"{source_record['sampleID']} pose ROI excludes visible labels: {', '.join(outside)}")
        visible_count += sum(point["status"] == "visible" for point in transformed.values())
        covered_count += sum(point_inside(point) and point["status"] == "visible" for point in transformed.values())
        destination = output_directory / "images" / image_name
        extract_crop(source_image, destination, roi, output_size)
        boxes = [box for box in (
            racket_box(transformed), ball_center_region_box(transformed, output_size, output_size)
        ) if box is not None]
        keypoint_records.append({
            **{key: value for key, value in source_record.items() if key not in {"points", "localImage", "pixelWidth", "pixelHeight", "framePath"}},
            "points": transformed,
            "localImage": f"images/{image_name}",
            "pixelWidth": output_size,
            "pixelHeight": output_size,
            "parentFrameSHA256": source_record["frameSHA256"],
            "roi": roi,
            "roiPoseSource": pose_source,
        })
        detector_records.append({
            "imageID": source_record["sampleID"], "localImage": f"images/{image_name}",
            "boxes": [{key: value for key, value in box.items() if key != "derivation"} for box in boxes],
        })
        createml_records.append(createml_record(image_name, boxes, output_size, output_size))
        roi_records.append({
            "sampleID": source_record["sampleID"], "imageFilename": image_name,
            "parentFrameSHA256": source_record["frameSHA256"], "crop": roi,
            "poseSource": pose_source, "cropSHA256": sha256_file(destination),
        })

    (output_directory / "keypoints.jsonl").write_text("".join(json.dumps(item, sort_keys=True) + "\n" for item in keypoint_records))
    (output_directory / "annotations.jsonl").write_text("".join(json.dumps(item, sort_keys=True) + "\n" for item in detector_records))
    (output_directory / "createml-annotations.json").write_text(json.dumps(createml_records, indent=2, sort_keys=True) + "\n")
    (output_directory / "roi-evidence.jsonl").write_text("".join(json.dumps(item, sort_keys=True) + "\n" for item in roi_records))
    return {
        "frameCount": len(source_records),
        "directPoseFrameCount": len(source_records) - fallback_count,
        "fallbackMedianFrameCount": fallback_count,
        "visibleKeypointCount": visible_count,
        "coveredVisibleKeypointCount": covered_count,
        "visibleKeypointCoverage": covered_count / max(visible_count, 1),
    }


def materialize(source: Path, adaptation_poses: Path, evaluation_poses: Path, output: Path, output_size: int = 832) -> dict:
    if output_size < 416:
        raise ROIError("output size must be at least 416 pixels")
    if output.exists() and any(output.iterdir()):
        raise ROIError(f"refusing to overwrite non-empty output: {output}")
    source_manifest = source / "manifest.json"
    if not source_manifest.is_file():
        raise ROIError("source target-domain manifest is missing")
    source_metadata = json.loads(source_manifest.read_text())
    if source_metadata.get("releaseEligible") is not False:
        raise ROIError("source pilot must remain releaseEligible false")
    output.mkdir(parents=True, exist_ok=True)
    splits = {
        "adaptation": materialize_split(source / "adaptation", adaptation_poses, output / "adaptation", output_size),
        "evaluation": materialize_split(source / "evaluation", evaluation_poses, output / "evaluation", output_size),
    }
    result = {
        "schemaVersion": 1,
        "purpose": "pose-centered high-resolution racket/ball object pilot",
        "parentManifestSHA256": sha256_file(source_manifest),
        "outputSize": output_size,
        "roiContract": {
            "coordinateSystem": "Vision root uses bottom-left normalized coordinates; output uses top-left pixels",
            "sidePixels": "clamp(5 * rawScale * sourceWidth, 0.40 * sourceWidth, 0.60 * sourceWidth)",
            "centerX": "rawRootX * sourceWidth",
            "centerY": "(1 - rawRootY) * sourceHeight - 0.35 * sidePixels",
            "missingPoseFallback": "median rawRootX/rawRootY/rawScale from detected frames in the same recording",
            "ballTarget": "40–64 px context region centered on the human label; exact silhouette is not inferred",
        },
        "splits": splits,
        "releaseEligible": False,
        "limitations": [
            "This pilot still contains one participant and one rear-view setup.",
            "Median pose fallback is recording-local and requires separate new-player validation.",
            "Cropping increases object pixels but does not recover detail absent from the source frame.",
            "Racket/ball localization does not by itself measure three-dimensional forearm pronation.",
        ],
    }
    (output / "manifest.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--adaptation-poses", type=Path, required=True)
    parser.add_argument("--evaluation-poses", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--output-size", type=int, default=832)
    args = parser.parse_args()
    try:
        result = materialize(args.source.resolve(), args.adaptation_poses.resolve(), args.evaluation_poses.resolve(), args.output.resolve(), args.output_size)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError, ROIError) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
