#!/usr/bin/env python3
"""Validate a local keypoint export and materialize an auditable pilot dataset.

The source export is never modified. Screen-left/screen-right hoop points are
canonicalized only when their x ordering proves that the two semantic names
were reversed, and every such correction is recorded in the output manifest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
from collections import Counter
from pathlib import Path


RACKET_KEYS = ("handleButt", "racketThroat", "hoopTop", "hoopLeft", "hoopRight")
ALL_KEYS = (*RACKET_KEYS, "ballCenter")
ALLOWED_STATUSES = {"visible", "notVisible"}


class PreparationError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def image_dimensions(path: Path) -> tuple[int, int]:
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    values: dict[str, int] = {}
    for line in result.stdout.splitlines():
        if ":" not in line:
            continue
        key, value = (part.strip() for part in line.split(":", 1))
        if key in {"pixelWidth", "pixelHeight"}:
            values[key] = int(value)
    width, height = values.get("pixelWidth", 0), values.get("pixelHeight", 0)
    if width <= 0 or height <= 0:
        raise PreparationError(f"could not read image dimensions: {path}")
    return width, height


def finite_unit(value: object, context: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise PreparationError(f"{context} must be a number")
    parsed = float(value)
    if not math.isfinite(parsed) or not 0 <= parsed <= 1:
        raise PreparationError(f"{context} is outside [0, 1]")
    return parsed


def validate_point(point: object, context: str) -> dict:
    if not isinstance(point, dict):
        raise PreparationError(f"{context} must be an object")
    status = point.get("status")
    if status not in ALLOWED_STATUSES:
        raise PreparationError(f"{context} has unsupported status {status!r}")
    if status == "visible":
        return {
            "status": status,
            "x": finite_unit(point.get("x"), f"{context}.x"),
            "y": finite_unit(point.get("y"), f"{context}.y"),
        }
    if point.get("x") is not None or point.get("y") is not None:
        raise PreparationError(f"{context} must not carry coordinates when not visible")
    return {"status": status}


def load_and_validate(labels_path: Path, review_directory: Path) -> tuple[dict, list[dict], list[dict]]:
    labels = json.loads(labels_path.read_text())
    manifest = json.loads((review_directory / "manifest.json").read_text())
    if labels.get("schemaVersion") != 1:
        raise PreparationError("only racket/ball keypoint schema version 1 is supported")
    if labels.get("purpose") != "human-reviewed-racket-ball-keypoint-pilot":
        raise PreparationError("unexpected label-export purpose")
    if labels.get("releaseEligible") is not False:
        raise PreparationError("pilot labels must remain releaseEligible false")
    frames = labels.get("frames")
    if not isinstance(frames, list) or not frames:
        raise PreparationError("export contains no frames")
    expected = {sample["id"]: sample for sample in manifest.get("samples", [])}
    if len(expected) != len(frames):
        raise PreparationError("export and review manifest frame counts differ")

    seen_ids: set[str] = set()
    seen_hashes: set[str] = set()
    corrections: list[dict] = []
    canonical: list[dict] = []
    for raw in frames:
        sample_id = raw.get("sampleID")
        if sample_id in seen_ids:
            raise PreparationError(f"duplicate sample ID: {sample_id}")
        seen_ids.add(sample_id)
        source = expected.get(sample_id)
        if source is None:
            raise PreparationError(f"unknown sample ID: {sample_id}")
        if raw.get("reviewed") is not True:
            raise PreparationError(f"{sample_id} is not reviewed")
        for field in ("sourceFilename", "sourceVideoSHA256", "frameSHA256", "phaseHint", "timestampSeconds"):
            if raw.get(field) != source.get(field):
                raise PreparationError(f"{sample_id} does not match manifest field {field}")
        frame_path = review_directory / source["framePath"]
        if not frame_path.is_file() or sha256_file(frame_path) != raw["frameSHA256"]:
            raise PreparationError(f"{sample_id} frame bytes do not match the signed digest")
        if raw["frameSHA256"] in seen_hashes:
            raise PreparationError(f"duplicate frame bytes: {sample_id}")
        seen_hashes.add(raw["frameSHA256"])
        points = raw.get("points")
        if not isinstance(points, dict) or set(points) != set(ALL_KEYS):
            raise PreparationError(f"{sample_id} must contain exactly the six keypoints")
        normalized = {key: validate_point(points[key], f"{sample_id}.{key}") for key in ALL_KEYS}
        left, right = normalized["hoopLeft"], normalized["hoopRight"]
        if left["status"] == right["status"] == "visible" and left["x"] >= right["x"]:
            if left["x"] == right["x"]:
                raise PreparationError(f"{sample_id} hoop left/right points collapse to one x-coordinate")
            normalized["hoopLeft"], normalized["hoopRight"] = right, left
            corrections.append({
                "sampleID": sample_id,
                "type": "swap-screen-left-right",
                "reason": "hoopLeft.x was greater than hoopRight.x",
            })
        canonical.append({
            "sampleID": sample_id,
            "sourceFilename": raw["sourceFilename"],
            "sourceVideoSHA256": raw["sourceVideoSHA256"],
            "frameSHA256": raw["frameSHA256"],
            "timestampSeconds": raw["timestampSeconds"],
            "phaseHint": raw["phaseHint"],
            "points": normalized,
            "framePath": source["framePath"],
        })
    if seen_ids != set(expected):
        raise PreparationError("export is missing one or more expected sample IDs")
    return labels, canonical, corrections


def racket_box(points: dict) -> dict | None:
    visible = [points[key] for key in RACKET_KEYS if points[key]["status"] == "visible"]
    if len(visible) < 3 or points["handleButt"]["status"] != "visible":
        return None
    xs, ys = [point["x"] for point in visible], [point["y"] for point in visible]
    width, height = max(xs) - min(xs), max(ys) - min(ys)
    pad_x, pad_y = max(0.004, width * 0.20), max(0.004, height * 0.20)
    return {
        "label": "tennis_racket",
        "xmin": max(0.0, min(xs) - pad_x), "xmax": min(1.0, max(xs) + pad_x),
        "ymin": max(0.0, min(ys) - pad_y), "ymax": min(1.0, max(ys) + pad_y),
        "derivation": "visible racket keypoint extrema plus 20% padding",
    }


def ball_box(points: dict, width: int, height: int) -> dict | None:
    ball = points["ballCenter"]
    if ball["status"] != "visible":
        return None
    handle, top = points["handleButt"], points["hoopTop"]
    if handle["status"] == top["status"] == "visible":
        racket_pixels = math.hypot((top["x"] - handle["x"]) * width, (top["y"] - handle["y"]) * height)
        diameter_pixels = min(30.0, max(6.0, racket_pixels * 0.10))
    else:
        diameter_pixels = 8.0
    half_x, half_y = diameter_pixels / (2 * width), diameter_pixels / (2 * height)
    return {
        "label": "tennis_ball",
        "xmin": max(0.0, ball["x"] - half_x), "xmax": min(1.0, ball["x"] + half_x),
        "ymin": max(0.0, ball["y"] - half_y), "ymax": min(1.0, ball["y"] + half_y),
        "derivation": "human ball center plus diameter estimated as 10% of visible racket length",
    }


def createml_record(image_name: str, boxes: list[dict], width: int, height: int) -> dict:
    return {"image": image_name, "annotations": [{
        "label": box["label"],
        "coordinates": {
            "x": (box["xmin"] + box["xmax"]) / 2 * width,
            "y": (box["ymin"] + box["ymax"]) / 2 * height,
            "width": (box["xmax"] - box["xmin"]) * width,
            "height": (box["ymax"] - box["ymin"]) * height,
        },
    } for box in boxes]}


def materialize(labels_path: Path, review_directory: Path, output: Path) -> dict:
    if output.exists() and any(output.iterdir()):
        raise PreparationError(f"refusing to overwrite non-empty output: {output}")
    labels, frames, corrections = load_and_validate(labels_path, review_directory)
    output.mkdir(parents=True, exist_ok=True)
    source_names = sorted({frame["sourceFilename"] for frame in frames})
    if len(source_names) < 2:
        raise PreparationError("pilot needs two separately recorded source clips")
    split_for_source = {source_names[0]: "adaptation", source_names[1]: "evaluation"}
    counts = Counter()
    visibility = Counter()

    for split in ("adaptation", "evaluation"):
        split_dir = output / split
        (split_dir / "images").mkdir(parents=True)
        keypoint_records, detector_records, createml_records = [], [], []
        for frame in frames:
            if split_for_source[frame["sourceFilename"]] != split:
                continue
            source_image = review_directory / frame["framePath"]
            image_name = f"{frame['sampleID']}.jpg"
            target_image = split_dir / "images" / image_name
            shutil.copy2(source_image, target_image)
            width, height = image_dimensions(target_image)
            boxes = [box for box in (racket_box(frame["points"]), ball_box(frame["points"], width, height)) if box is not None]
            keypoint_records.append({**frame, "localImage": f"images/{image_name}", "pixelWidth": width, "pixelHeight": height})
            detector_records.append({
                "imageID": frame["sampleID"], "localImage": f"images/{image_name}",
                "boxes": [{key: value for key, value in box.items() if key != "derivation"} for box in boxes],
            })
            createml_records.append(createml_record(image_name, boxes, width, height))
            counts[split] += 1
            for key, point in frame["points"].items():
                visibility[f"{key}:{point['status']}"] += 1
        (split_dir / "keypoints.jsonl").write_text("".join(json.dumps(item, sort_keys=True) + "\n" for item in keypoint_records))
        (split_dir / "annotations.jsonl").write_text("".join(json.dumps(item, sort_keys=True) + "\n" for item in detector_records))
        (split_dir / "createml-annotations.json").write_text(json.dumps(createml_records, indent=2, sort_keys=True) + "\n")

    result = {
        "schemaVersion": 1,
        "purpose": "one-participant target-domain racket/ball pilot",
        "createdFromSHA256": sha256_file(labels_path),
        "sourceReviewManifestSHA256": sha256_file(review_directory / "manifest.json"),
        "participantPseudonym": labels.get("participantPseudonym"), "cameraAngle": labels.get("cameraAngle"),
        "sourceSplit": split_for_source, "frameCounts": dict(counts),
        "visibilityCounts": dict(sorted(visibility.items())), "semanticCorrections": corrections,
        "detectorBoxDerivations": {
            "tennis_racket": "bounds of visible human keypoints with padding",
            "tennis_ball": "human center with estimated diameter; center-distance evaluation is authoritative",
        },
        "releaseEligible": False,
        "limitations": [
            "Only one participant and one rear camera setup are represented.",
            "Adjacent video frames are correlated and are not independent examples.",
            "The adaptation/evaluation split separates recordings, not participants.",
            "Ball box diameter is estimated because only the center was labeled.",
            "These labels can audit object localization but cannot establish forearm pronation accuracy.",
        ],
    }
    (output / "manifest.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("labels", type=Path)
    parser.add_argument("--review-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        result = materialize(args.labels.resolve(), args.review_directory.resolve(), args.output.resolve())
    except (OSError, ValueError, json.JSONDecodeError, subprocess.SubprocessError, PreparationError) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
