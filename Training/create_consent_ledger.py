#!/usr/bin/env python3
"""Create and sign a fresh complete consent-receipt ledger snapshot."""

from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path

from consent_auth import create_consent_ledger_snapshot, sign_consent_ledger_snapshot


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("receipts", nargs="+", type=Path, help="Receipt JSON files or directories")
    parser.add_argument("--authority-id", required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--snapshot-id", default=None)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    paths: list[Path] = []
    for item in args.receipts:
        candidates = sorted(item.glob("*.json")) if item.is_dir() else [item]
        paths.extend(
            path for path in candidates
            if not path.name.endswith(".consent-signature.json")
            and not path.name.endswith(".consent-ledger-signature.json")
            and path.resolve() != args.output.resolve()
        )
    snapshot = create_consent_ledger_snapshot(
        paths,
        args.authority_id,
        snapshot_id=args.snapshot_id or str(uuid.uuid4()),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(snapshot, indent=2, sort_keys=True) + "\n")
    signature = sign_consent_ledger_snapshot(
        args.output, args.authority_id, args.private_key
    )
    print(f"wrote signed consent ledger to {args.output}")
    print(f"wrote consent ledger signature to {signature}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
