#!/usr/bin/env python3
"""Fetch only the THETIS RGB serve subset and transcode it for Apple Vision.

THETIS is described by its authors as freely available for research purposes.
The downloaded material is therefore isolated as research-only and must not be
treated as commercial training data or as participant-consented ServeAI data.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import subprocess
import tempfile
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DEFAULT_OUTPUT = ROOT / "data/raw/thetis_serves"
DEFAULT_MANIFEST = ROOT / "artifacts/thetis_source_manifest.json"
REPOSITORY = "THETIS-dataset/dataset"
ACTIONS = ("flat_service", "kick_service", "slice_service")
EXPECTED_CLIP_COUNT = 495
USER_AGENT = "ServeAI-research-dataset-fetcher/1.0"


def request_json(url: str) -> object:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def checkpoint(path: Path, commit: str, entries: list[dict], complete: bool) -> None:
    payload = {
        "schemaVersion": 1,
        "datasetIdentifier": "thetis-three-dimensional-tennis-shots",
        "repository": f"https://github.com/{REPOSITORY}",
        "repositoryCommit": commit,
        "paper": "https://openaccess.thecvf.com/content_cvpr_workshops_2013/W08/html/Gourgari_THETIS_Three_Dimensional_2013_CVPR_paper.html",
        "sourceTerms": "Freely available for research purposes; no commercial-use grant is stated.",
        "productionUseAllowed": False,
        "participantCount": 55,
        "beginnerParticipants": 31,
        "expertParticipants": 24,
        "cameraView": "frontal Kinect RGB; outside ServeAI's supported side/rear capture views",
        "captureLimitations": [
            "Staged indoor actions without a tennis ball.",
            "Front-facing Kinect view does not match ServeAI's side/rear iPhone protocol.",
            "Dataset terms support research use only and do not clear a commercial app model.",
            "No independent ServeAI coach phase or technique labels are provided.",
        ],
        "serveClasses": list(ACTIONS),
        "expectedClipCount": EXPECTED_CLIP_COUNT,
        "downloadedClipCount": len(entries),
        "complete": complete,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "files": sorted(entries, key=lambda item: item["derivedPath"]),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def download_and_transcode(item: dict, output_root: Path, commit: str) -> dict:
    action = item["action"]
    source_name = item["name"]
    derived_name = f"{Path(source_name).stem}.mp4"
    destination = output_root / action / derived_name
    destination.parent.mkdir(parents=True, exist_ok=True)
    source_url = (
        f"https://raw.githubusercontent.com/{REPOSITORY}/{commit}/"
        f"VIDEO_RGB/{action}/{source_name}"
    )

    with tempfile.TemporaryDirectory(prefix="serveai-thetis-") as temporary:
        temporary_root = Path(temporary)
        source_path = temporary_root / source_name
        digest = hashlib.sha256()
        request = urllib.request.Request(source_url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(request, timeout=120) as response, source_path.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                digest.update(chunk)
                output.write(chunk)
        if source_path.stat().st_size != item["size"]:
            raise ValueError(f"downloaded size mismatch for {source_name}")

        temporary_mp4 = temporary_root / derived_name
        subprocess.run(
            [
                "ffmpeg", "-y", "-loglevel", "error", "-i", str(source_path),
                "-map", "0:v:0", "-an", "-c:v", "libx264", "-preset", "veryfast",
                "-crf", "24", "-pix_fmt", "yuv420p", "-movflags", "+faststart",
                str(temporary_mp4),
            ],
            check=True,
        )
        os.replace(temporary_mp4, destination)

    pieces = Path(source_name).stem.split("_")
    return {
        "participantPseudonym": f"thetis-{pieces[0]}",
        "skillGroup": "beginner" if int(pieces[0][1:]) <= 31 else "expert",
        "serveClass": action,
        "repetition": pieces[-1],
        "sourceFilename": source_name,
        "sourceURL": source_url,
        "sourceBytes": item["size"],
        "sourceSHA256": digest.hexdigest(),
        "derivedPath": str(destination.relative_to(ROOT.parent)),
        "derivedBytes": destination.stat().st_size,
        "derivedSHA256": sha256_file(destination),
        "transformation": "FFmpeg H.264 CRF 24 transcode for AVFoundation compatibility; no temporal edits",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--workers", type=int, default=6)
    args = parser.parse_args()
    if args.workers < 1 or args.workers > 12:
        raise SystemExit("--workers must be between 1 and 12")

    repository = request_json(f"https://api.github.com/repos/{REPOSITORY}/commits/main")
    commit = repository["sha"]
    source_items = []
    for action in ACTIONS:
        listing = request_json(
            f"https://api.github.com/repos/{REPOSITORY}/contents/VIDEO_RGB/{action}?ref={commit}"
        )
        source_items.extend(
            {"action": action, "name": item["name"], "size": item["size"]}
            for item in listing if item.get("type") == "file" and item["name"].endswith(".avi")
        )
    if len(source_items) != EXPECTED_CLIP_COUNT:
        raise SystemExit(f"expected {EXPECTED_CLIP_COUNT} source clips, found {len(source_items)}")

    previous: dict[str, dict] = {}
    if args.manifest.exists():
        prior_payload = json.loads(args.manifest.read_text())
        if prior_payload.get("repositoryCommit") == commit:
            previous = {item["sourceFilename"]: item for item in prior_payload.get("files", [])}

    entries: list[dict] = []
    pending: list[dict] = []
    for item in source_items:
        prior = previous.get(item["name"])
        if prior:
            destination = ROOT.parent / prior["derivedPath"]
            if destination.exists() and sha256_file(destination) == prior.get("derivedSHA256"):
                entries.append(prior)
                continue
        pending.append(item)

    checkpoint(args.manifest, commit, entries, complete=False)
    completed = len(entries)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(download_and_transcode, item, args.output, commit): item
            for item in pending
        }
        for future in concurrent.futures.as_completed(futures):
            item = futures[future]
            try:
                entries.append(future.result())
            except Exception as error:
                checkpoint(args.manifest, commit, entries, complete=False)
                raise RuntimeError(f"failed {item['action']}/{item['name']}: {error}") from error
            completed += 1
            if completed % 20 == 0 or completed == EXPECTED_CLIP_COUNT:
                checkpoint(args.manifest, commit, entries, complete=False)
                print(f"prepared {completed}/{EXPECTED_CLIP_COUNT} THETIS serve clips", flush=True)

    checkpoint(args.manifest, commit, entries, complete=True)
    print(f"wrote complete research-only source manifest to {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
