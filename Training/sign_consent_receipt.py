#!/usr/bin/env python3
"""Sign an immutable participant-consent grant or revocation receipt."""

from __future__ import annotations

import argparse
from pathlib import Path

from consent_auth import sign_consent_receipt


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--authority-id", required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = sign_consent_receipt(args.receipt, args.authority_id, args.private_key, args.output)
    print(f"wrote consent signature sidecar to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
