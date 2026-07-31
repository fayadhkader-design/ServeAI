#!/usr/bin/env python3
"""Prepare a license-audited Open Images tennis racket/ball subset.

Open Images licenses its annotations under CC BY 4.0, while each underlying
image retains its own license. This tool deliberately fails closed: a box is
eligible only when the corresponding image metadata exists and names a
Creative Commons Attribution license. Every retained image receives an
attribution record and every downloaded byte receives a SHA-256 digest.

The output is detector-training evidence, not serve-technique ground truth.
It contains object boxes only and cannot validate racket-drop, contact, or
pronation coaching claims.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import subprocess
import urllib.parse
import urllib.request
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
from typing import IO, Iterable, Iterator


CLASS_LABELS = {
    "/m/05ctyq": "tennis_ball",
    "/m/0h8my_4": "tennis_racket",
}

SPLIT_SOURCES = {
    "train": {
        "boxes": "https://storage.googleapis.com/openimages/v6/oidv6-train-annotations-bbox.csv",
        "metadata": "https://storage.googleapis.com/openimages/2018_04/train/train-images-boxable-with-rotation.csv",
    },
    "validation": {
        "boxes": "https://storage.googleapis.com/openimages/v5/validation-annotations-bbox.csv",
        "metadata": "https://storage.googleapis.com/openimages/2018_04/validation/validation-images-with-rotation.csv",
    },
    "test": {
        "boxes": "https://storage.googleapis.com/openimages/v5/test-annotations-bbox.csv",
        "metadata": "https://storage.googleapis.com/openimages/2018_04/test/test-images-with-rotation.csv",
    },
}

ALLOWED_LICENSE_PREFIXES = (
    "https://creativecommons.org/licenses/by/",
    "http://creativecommons.org/licenses/by/",
)


def allowed_image_license(value: str) -> bool:
    normalized = value.strip().lower()
    return any(normalized.startswith(prefix) for prefix in ALLOWED_LICENSE_PREFIXES)


def finite_unit(value: str) -> float:
    parsed = float(value)
    if not 0 <= parsed <= 1:
        raise ValueError(f"normalized coordinate outside [0, 1]: {parsed}")
    return parsed


def collect_boxes(rows: Iterable[dict[str, str]]) -> dict[str, list[dict]]:
    by_image: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        label = CLASS_LABELS.get(row.get("LabelName", ""))
        if not label:
            continue
        xmin = finite_unit(row["XMin"])
        xmax = finite_unit(row["XMax"])
        ymin = finite_unit(row["YMin"])
        ymax = finite_unit(row["YMax"])
        if xmax <= xmin or ymax <= ymin:
            continue
        by_image[row["ImageID"]].append({
            "label": label,
            "xmin": xmin,
            "xmax": xmax,
            "ymin": ymin,
            "ymax": ymax,
            "isOccluded": row.get("IsOccluded") == "1",
            "isTruncated": row.get("IsTruncated") == "1",
            "isGroupOf": row.get("IsGroupOf") == "1",
            "isDepiction": row.get("IsDepiction") == "1",
        })
    return dict(by_image)


def collect_licensed_metadata(
    rows: Iterable[dict[str, str]],
    wanted_ids: set[str],
) -> tuple[dict[str, dict], dict[str, int]]:
    accepted: dict[str, dict] = {}
    rejected = Counter()
    for row in rows:
        image_id = row.get("ImageID", "")
        if image_id not in wanted_ids:
            continue
        license_url = row.get("License", "")
        if not allowed_image_license(license_url):
            rejected["licenseNotExplicitlyAllowed"] += 1
            continue
        source_urls = list(dict.fromkeys(filter(None, (
            row.get("Thumbnail300KURL"),
            row.get("OriginalURL"),
        ))))
        if not source_urls:
            rejected["missingDownloadURL"] += 1
            continue
        accepted[image_id] = {
            "imageID": image_id,
            "license": license_url,
            "author": row.get("Author", ""),
            "authorProfileURL": row.get("AuthorProfileURL", ""),
            "title": row.get("Title", ""),
            "originalURL": row.get("OriginalURL", ""),
            "originalLandingURL": row.get("OriginalLandingURL", ""),
            "downloadURLs": source_urls,
            "rotationDegreesCounterclockwise": rotation_value(row.get("Rotation", "")),
        }
    rejected["missingMetadata"] += len(wanted_ids - set(accepted)) - sum(rejected.values())
    return accepted, dict(rejected)


def rotation_value(value: str) -> int | None:
    stripped = value.strip().lower()
    if not stripped or stripped == "nan":
        return None
    parsed = int(float(stripped))
    if parsed not in (0, 90, 180, 270):
        raise ValueError(f"unsupported image rotation: {parsed}")
    return parsed


@contextmanager
def text_source(source: str) -> Iterator[IO[str]]:
    parsed = urllib.parse.urlparse(source)
    if parsed.scheme in ("http", "https"):
        response = urllib.request.urlopen(source, timeout=120)
        wrapper = __import__("io").TextIOWrapper(response, encoding="utf-8", newline="")
        try:
            yield wrapper
        finally:
            wrapper.close()
    else:
        with Path(source).open(newline="", encoding="utf-8") as handle:
            yield handle


def download_file(url: str, destination: Path) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "ServeAI dataset audit"})
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=120) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
            digest.update(chunk)
    return digest.hexdigest()


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def extension_for(url: str) -> str:
    suffix = Path(urllib.parse.urlparse(url).path).suffix.lower()
    return suffix if suffix in {".jpg", ".jpeg", ".png", ".webp"} else ".jpg"


def image_dimensions(path: Path) -> tuple[int, int]:
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    values = {}
    for line in result.stdout.splitlines():
        if ":" not in line:
            continue
        key, value = (part.strip() for part in line.split(":", 1))
        if key in {"pixelWidth", "pixelHeight"}:
            values[key] = int(value)
    if values.get("pixelWidth", 0) <= 0 or values.get("pixelHeight", 0) <= 0:
        raise ValueError(f"could not read image dimensions: {path.name}")
    return values["pixelWidth"], values["pixelHeight"]


def create_ml_annotations(records: list[dict]) -> list[dict]:
    annotations = []
    for record in records:
        width = record.get("pixelWidth")
        height = record.get("pixelHeight")
        local_image = record.get("localImage")
        if not width or not height or not local_image:
            continue
        annotations.append({
            "image": Path(local_image).name,
            "annotations": [
                {
                    "label": box["label"],
                    "coordinates": {
                        "x": (box["xmin"] + box["xmax"]) / 2 * width,
                        "y": (box["ymin"] + box["ymax"]) / 2 * height,
                        "width": (box["xmax"] - box["xmin"]) * width,
                        "height": (box["ymax"] - box["ymin"]) * height,
                    },
                }
                for box in record["boxes"]
            ],
        })
    return annotations


def download_record(
    *,
    image_id: str,
    split: str,
    image_boxes: list[dict],
    attribution: dict,
    image_directory: Path,
) -> tuple[dict | None, dict | None]:
    record = {
        "imageID": image_id,
        "split": split,
        "boxes": image_boxes,
        "attribution": attribution,
    }
    mirror_url = f"https://open-images-dataset.s3.amazonaws.com/{split}/{image_id}.jpg"
    last_error = None
    for source_url in [mirror_url, *attribution["downloadURLs"]]:
        filename = image_id + extension_for(source_url)
        destination = image_directory / filename
        try:
            if destination.exists():
                width, height = image_dimensions(destination)
                digest = file_sha256(destination)
            else:
                digest = download_file(source_url, destination)
                width, height = image_dimensions(destination)
            record["localImage"] = str(Path("images") / filename)
            record["sha256"] = digest
            record["selectedDownloadURL"] = source_url
            record["pixelWidth"] = width
            record["pixelHeight"] = height
            return record, None
        except Exception as error:  # network/source failures stay explicit
            destination.unlink(missing_ok=True)
            last_error = error
    return None, {
        "imageID": image_id,
        "errorType": type(last_error).__name__,
    }


def prepare(
    *,
    split: str,
    boxes_source: str,
    metadata_source: str,
    output: Path,
    download: bool,
    max_images: int | None,
    workers: int = 12,
) -> dict:
    with text_source(boxes_source) as handle:
        boxes = collect_boxes(csv.DictReader(handle))
    with text_source(metadata_source) as handle:
        metadata, rejected = collect_licensed_metadata(csv.DictReader(handle), set(boxes))

    selected_ids = sorted(metadata)
    if max_images is not None:
        selected_ids = selected_ids[:max_images]

    output.mkdir(parents=True, exist_ok=True)
    image_directory = output / "images"
    if download:
        image_directory.mkdir(exist_ok=True)

    records = []
    download_failures = []
    label_counts = Counter()
    pending = []
    for image_id in selected_ids:
        attribution = metadata[image_id]
        image_boxes = boxes[image_id]
        record = {
            "imageID": image_id,
            "split": split,
            "boxes": image_boxes,
            "attribution": attribution,
        }
        if download:
            pending.append((image_id, image_boxes, attribution))
        else:
            records.append(record)

    if download:
        if workers <= 0:
            raise ValueError("workers must be positive")
        with ThreadPoolExecutor(max_workers=workers) as executor:
            results = executor.map(
                lambda values: download_record(
                    image_id=values[0],
                    split=split,
                    image_boxes=values[1],
                    attribution=values[2],
                    image_directory=image_directory,
                ),
                pending,
            )
            for record, failure in results:
                if record:
                    records.append(record)
                if failure:
                    download_failures.append(failure)
    records.sort(key=lambda item: item["imageID"])
    for record in records:
        label_counts.update(item["label"] for item in record["boxes"])

    annotations_path = output / "annotations.jsonl"
    with annotations_path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, sort_keys=True, ensure_ascii=False) + "\n")

    create_ml = create_ml_annotations(records)
    if create_ml:
        (output / "createml-annotations.json").write_text(
            json.dumps(create_ml, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

    summary = {
        "schemaVersion": 1,
        "datasetIdentifier": "serveai.open-images-racket-ball",
        "split": split,
        "purpose": "Object-perception research; not serve-technique or coaching ground truth.",
        "annotationLicense": "CC-BY-4.0",
        "sourceURLs": {"boxes": boxes_source, "metadata": metadata_source},
        "requestedClassLabels": CLASS_LABELS,
        "candidateImageCount": len(boxes),
        "licensedImageCount": len(metadata),
        "writtenImageCount": len(records),
        "createMLAnnotationCount": len(create_ml),
        "boxCountByLabel": dict(sorted(label_counts.items())),
        "rejectedImageCounts": rejected,
        "downloadFailures": download_failures,
        "releaseInterpretation": {
            "canTrainObjectDetectorWithAttribution": True,
            "canEstablishServeTechniqueAccuracy": False,
            "canEstablishRacketDropOrPronationAccuracy": False,
        },
    }
    (output / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--split", choices=sorted(SPLIT_SOURCES), default="validation")
    parser.add_argument("--boxes-source")
    parser.add_argument("--metadata-source")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--download", action="store_true")
    parser.add_argument("--max-images", type=int)
    parser.add_argument("--workers", type=int, default=12)
    args = parser.parse_args()
    sources = SPLIT_SOURCES[args.split]
    summary = prepare(
        split=args.split,
        boxes_source=args.boxes_source or sources["boxes"],
        metadata_source=args.metadata_source or sources["metadata"],
        output=args.output,
        download=args.download,
        max_images=args.max_images,
        workers=args.workers,
    )
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
