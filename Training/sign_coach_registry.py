#!/usr/bin/env python3
"""Authorize a coach public-key registry using an out-of-repo admin secret."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from coach_auth import require_registry_secret, sign_registry_payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path, help="Unsigned coach registry JSON")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    registry = json.loads(args.input.read_text())
    signed = sign_registry_payload(registry, require_registry_secret())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(signed, indent=2, sort_keys=True) + "\n")
    print(f"wrote signed coach registry to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
