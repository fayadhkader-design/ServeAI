#!/usr/bin/env python3
"""Sign an annotation, adjudication, or compiled ground truth with a coach EC key."""

from __future__ import annotations

import argparse
from pathlib import Path

from coach_auth import sign_artifact


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--coach-id", required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = sign_artifact(args.artifact, args.coach_id, args.private_key, args.output)
    print(f"wrote signature sidecar to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
