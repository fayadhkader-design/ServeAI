#!/usr/bin/env python3
"""Download only explicitly approved files and verify immutable checksums."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent
MANIFEST = ROOT / "datasets.json"
ALLOWED = {"training-with-attribution", "research-and-training-with-attribution"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".partial")
    request = Request(url, headers={"User-Agent": "ServeAI-dataset-verifier/1.0"})
    with urlopen(request, timeout=60) as response, temporary.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            output.write(chunk)
    temporary.replace(destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--download", action="store_true", help="Fetch missing approved files")
    args = parser.parse_args()

    manifest = json.loads(MANIFEST.read_text())
    failures: list[str] = []
    for dataset in manifest["datasets"]:
        files = dataset.get("files", [])
        if files and dataset["allowedUse"] not in ALLOWED:
            failures.append(f"{dataset['id']}: blocked dataset unexpectedly contains files")
            continue
        for item in files:
            path = ROOT / item["path"]
            if not path.exists() and args.download:
                print(f"downloading {dataset['id']}: {path.name}")
                download(item["url"], path)
            if not path.exists():
                failures.append(f"{dataset['id']}: missing {path}")
                continue
            actual = sha256(path)
            if actual != item["sha256"]:
                failures.append(f"{dataset['id']}: checksum mismatch for {path.name}")
            else:
                print(f"verified {dataset['id']}: {path.name}")

    if failures:
        print("\nFAILED")
        print("\n".join(f"- {failure}" for failure in failures))
        return 1
    print("\nAll approved dataset files passed provenance checks.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
