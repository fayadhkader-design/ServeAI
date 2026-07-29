#!/usr/bin/env python3
"""Verify a native task and extract its signer as an unsigned registry entry."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from coach_auth import parse_iso8601
from task_coordinator_auth import TaskCoordinatorAuthorizationError, verify_native_task_signature


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("task", type=Path, help="Signed coach-task JSON exported by ServeAI")
    parser.add_argument("--organization", required=True)
    parser.add_argument("--role", default="Dataset collection coordinator")
    parser.add_argument("--expires-at", required=True, help="ISO-8601 authorization expiry")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        task = json.loads(args.task.read_text())
        signer = verify_native_task_signature(task)
        created_at = parse_iso8601(signer["createdAt"])
        expires_at = parse_iso8601(args.expires_at)
        if expires_at <= created_at:
            raise TaskCoordinatorAuthorizationError("coordinator expiry must be after the task creation time")
        if not str(args.organization).strip() or not str(args.role).strip():
            raise TaskCoordinatorAuthorizationError("organization and role are required")
    except (OSError, json.JSONDecodeError, TypeError, ValueError, TaskCoordinatorAuthorizationError) as error:
        print(f"Could not extract task coordinator entry: {error}")
        return 1
    entry = {
        "coordinatorID": signer["coordinatorID"],
        "status": "active",
        "organization": args.organization.strip(),
        "role": args.role.strip(),
        "authorizedFrom": signer["createdAt"],
        "expiresAt": args.expires_at,
        "signerKeyID": signer["signerKeyID"],
        "publicKeyX963": signer["publicKeyX963"],
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(entry, indent=2, sort_keys=True) + "\n")
    print(f"wrote verified unsigned coordinator entry to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

