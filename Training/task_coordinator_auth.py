#!/usr/bin/env python3
"""Authorization for native ServeAI portable labeling-task signers.

The task's embedded ECDSA signature proves content integrity. This module adds
independent administrative authorization: a signed registry binds a
coordinator pseudonym to the exact CryptoKit P-256 public key and validity
window used to create portable tasks.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import subprocess
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path

from coach_auth import canonical_json, parse_iso8601


TASK_COORDINATOR_REGISTRY_SCHEMA = 1
TASK_COORDINATOR_REGISTRY_SECRET_ENV = "SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET"


class TaskCoordinatorAuthorizationError(ValueError):
    pass


def registry_payload(registry: dict) -> dict:
    return {
        "schemaVersion": registry.get("schemaVersion"),
        "registryID": registry.get("registryID"),
        "issuedAt": registry.get("issuedAt"),
        "coordinators": registry.get("coordinators"),
    }


def require_task_coordinator_registry_secret(environment: dict[str, str] | None = None) -> bytes:
    value = (environment or os.environ).get(TASK_COORDINATOR_REGISTRY_SECRET_ENV, "")
    if len(value) < 32:
        raise TaskCoordinatorAuthorizationError(
            f"{TASK_COORDINATOR_REGISTRY_SECRET_ENV} must contain at least 32 characters and must not be committed"
        )
    return value.encode("utf-8")


def sign_task_coordinator_registry_payload(unsigned: dict, secret: bytes) -> dict:
    payload = registry_payload(unsigned)
    if payload["schemaVersion"] != TASK_COORDINATOR_REGISTRY_SCHEMA:
        raise TaskCoordinatorAuthorizationError(
            f"task coordinator registry schema must be {TASK_COORDINATOR_REGISTRY_SCHEMA}"
        )
    signature = hmac.new(secret, canonical_json(payload), hashlib.sha256).hexdigest()
    return {**payload, "signatureAlgorithm": "HMAC-SHA256", "signature": signature}


def decode_x963(value: object) -> bytes:
    try:
        public_bytes = base64.b64decode(str(value or ""), validate=True)
    except (ValueError, binascii.Error) as error:
        raise TaskCoordinatorAuthorizationError("task coordinator public key is not valid base64") from error
    if len(public_bytes) != 65 or public_bytes[:1] != b"\x04":
        raise TaskCoordinatorAuthorizationError("task coordinator public key is not an uncompressed P-256 point")
    return public_bytes


def p256_x963_to_spki(public_bytes: bytes) -> bytes:
    # RFC 5480 SubjectPublicKeyInfo: id-ecPublicKey + prime256v1 + SEC1 point.
    prefix = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200")
    return prefix + public_bytes


def is_valid_p256_x963(public_bytes: bytes) -> bool:
    with tempfile.TemporaryDirectory(prefix="serveai-task-key-") as temp:
        key_path = Path(temp) / "public.der"
        key_path.write_bytes(p256_x963_to_spki(public_bytes))
        check = subprocess.run(
            ["openssl", "pkey", "-pubin", "-inform", "DER", "-in", str(key_path), "-text", "-noout"],
            check=False,
            capture_output=True,
        )
    detail = check.stdout.decode("utf-8", errors="replace")
    return check.returncode == 0 and ("prime256v1" in detail or "P-256" in detail)


def load_verified_task_coordinator_registry(
    path: Path,
    secret: bytes,
    now: datetime | None = None,
) -> dict[str, dict]:
    try:
        registry = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise TaskCoordinatorAuthorizationError(f"task coordinator registry is unreadable: {error}") from error
    if registry.get("schemaVersion") != TASK_COORDINATOR_REGISTRY_SCHEMA:
        raise TaskCoordinatorAuthorizationError(
            f"task coordinator registry schema must be {TASK_COORDINATOR_REGISTRY_SCHEMA}"
        )
    if registry.get("signatureAlgorithm") != "HMAC-SHA256":
        raise TaskCoordinatorAuthorizationError("task coordinator registry signature algorithm is unsupported")
    expected = hmac.new(secret, canonical_json(registry_payload(registry)), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, str(registry.get("signature", ""))):
        raise TaskCoordinatorAuthorizationError("task coordinator registry signature is invalid")
    if not str(registry.get("registryID", "")).strip() or not registry.get("issuedAt"):
        raise TaskCoordinatorAuthorizationError("task coordinator registry ID and issue timestamp are required")

    current = now or datetime.now(timezone.utc)
    try:
        issued_at = parse_iso8601(registry["issuedAt"])
    except (TypeError, ValueError) as error:
        raise TaskCoordinatorAuthorizationError("task coordinator registry issue timestamp is invalid") from error
    if issued_at > current + timedelta(minutes=5):
        raise TaskCoordinatorAuthorizationError("task coordinator registry issue timestamp is in the future")

    active: dict[str, dict] = {}
    seen_ids: set[str] = set()
    seen_keys: set[str] = set()
    for entry in registry.get("coordinators") or []:
        coordinator_id = str(entry.get("coordinatorID", "")).strip()
        if not coordinator_id or coordinator_id in seen_ids:
            raise TaskCoordinatorAuthorizationError(
                "task coordinator registry contains a missing or duplicate coordinator ID"
            )
        seen_ids.add(coordinator_id)
        if entry.get("status") != "active":
            continue
        if not str(entry.get("organization", "")).strip() or not str(entry.get("role", "")).strip():
            raise TaskCoordinatorAuthorizationError(
                f"task coordinator {coordinator_id} lacks organization or role"
            )
        try:
            authorized_from = parse_iso8601(entry.get("authorizedFrom"))
            expires_at = parse_iso8601(entry.get("expiresAt"))
        except (TypeError, ValueError) as error:
            raise TaskCoordinatorAuthorizationError(
                f"task coordinator {coordinator_id} has an invalid authorization window"
            ) from error
        if expires_at <= authorized_from:
            raise TaskCoordinatorAuthorizationError(
                f"task coordinator {coordinator_id} has an empty authorization window"
            )
        if expires_at <= current:
            continue
        public_bytes = decode_x963(entry.get("publicKeyX963"))
        if not is_valid_p256_x963(public_bytes):
            raise TaskCoordinatorAuthorizationError(
                f"task coordinator {coordinator_id} public key is not EC P-256"
            )
        key_id = hashlib.sha256(public_bytes).hexdigest()
        if entry.get("signerKeyID") != key_id:
            raise TaskCoordinatorAuthorizationError(
                f"task coordinator {coordinator_id} signer key fingerprint is invalid"
            )
        if key_id in seen_keys:
            raise TaskCoordinatorAuthorizationError(
                "two active task coordinators cannot share one signing key"
            )
        seen_keys.add(key_id)
        active[coordinator_id] = entry
    return active


def verify_p256_x963_signature(public_bytes: bytes, signature_bytes: bytes, content: bytes) -> bool:
    if len(public_bytes) != 65 or public_bytes[:1] != b"\x04":
        return False
    with tempfile.TemporaryDirectory(prefix="serveai-task-verify-") as temp:
        directory = Path(temp)
        key_der = directory / "task-public.der"
        key_pem = directory / "task-public.pem"
        signature_path = directory / "task.sig"
        content_path = directory / "payload.json"
        key_der.write_bytes(p256_x963_to_spki(public_bytes))
        signature_path.write_bytes(signature_bytes)
        content_path.write_bytes(content)
        convert = subprocess.run(
            ["openssl", "pkey", "-pubin", "-inform", "DER", "-in", str(key_der), "-out", str(key_pem)],
            check=False,
            capture_output=True,
        )
        if convert.returncode != 0:
            return False
        verified = subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-verify", str(key_pem),
                "-signature", str(signature_path), str(content_path),
            ],
            check=False,
            capture_output=True,
        )
        return verified.returncode == 0


def verify_native_task_signature(task: dict) -> dict:
    if task.get("schemaVersion") != 1:
        raise TaskCoordinatorAuthorizationError("labeling task schema must be 1")
    payload = task.get("payload")
    signature = task.get("signature")
    if not isinstance(payload, dict) or payload.get("schemaVersion") not in {1, 2}:
        raise TaskCoordinatorAuthorizationError("labeling task payload schema must be 1 or 2")
    if not isinstance(signature, dict):
        raise TaskCoordinatorAuthorizationError("labeling task signature is missing")
    if signature.get("algorithm") != "ECDSA-P256-SHA256":
        raise TaskCoordinatorAuthorizationError("labeling task signature algorithm is unsupported")
    content = canonical_json(payload)
    if signature.get("signedContentSHA256") != hashlib.sha256(content).hexdigest():
        raise TaskCoordinatorAuthorizationError("labeling task signed-content digest is invalid")
    public_bytes = decode_x963(signature.get("publicKeyX963"))
    if signature.get("signerKeyID") != hashlib.sha256(public_bytes).hexdigest():
        raise TaskCoordinatorAuthorizationError("labeling task signer key fingerprint is invalid")
    try:
        signature_bytes = base64.b64decode(str(signature.get("signatureDER") or ""), validate=True)
    except (ValueError, binascii.Error) as error:
        raise TaskCoordinatorAuthorizationError("labeling task signature is not valid base64") from error
    if not verify_p256_x963_signature(public_bytes, signature_bytes, content):
        raise TaskCoordinatorAuthorizationError("labeling task signature is invalid or the task was changed")
    return {
        "coordinatorID": payload.get("coordinatorPseudonym"),
        "taskID": payload.get("taskID"),
        "createdAt": payload.get("createdAt"),
        "signerKeyID": signature.get("signerKeyID"),
        "publicKeyX963": signature.get("publicKeyX963"),
    }


def authorize_labeling_task(task: dict, registry: dict[str, dict]) -> dict:
    payload = task.get("payload") or {}
    signature = task.get("signature") or {}
    coordinator_id = str(payload.get("coordinatorPseudonym") or "")
    entry = registry.get(coordinator_id)
    if entry is None:
        raise TaskCoordinatorAuthorizationError(
            f"task coordinator {coordinator_id or '<missing>'} is not active in the signed registry"
        )
    if signature.get("signerKeyID") != entry.get("signerKeyID"):
        raise TaskCoordinatorAuthorizationError("labeling task signer key is not authorized for its coordinator")
    if signature.get("publicKeyX963") != entry.get("publicKeyX963"):
        raise TaskCoordinatorAuthorizationError("labeling task public key differs from the authorized coordinator key")
    try:
        created_at = parse_iso8601(payload.get("createdAt"))
        authorized_from = parse_iso8601(entry.get("authorizedFrom"))
        expires_at = parse_iso8601(entry.get("expiresAt"))
    except (TypeError, ValueError) as error:
        raise TaskCoordinatorAuthorizationError("labeling task authorization timestamps are invalid") from error
    if not authorized_from <= created_at < expires_at:
        raise TaskCoordinatorAuthorizationError("labeling task was signed outside the coordinator authorization window")
    return {
        "status": "AUTHORIZED — signed coordinator registry key matched",
        "coordinatorID": coordinator_id,
        "organization": entry["organization"],
        "role": entry["role"],
        "signerKeyID": entry["signerKeyID"],
        "authorizedFrom": entry["authorizedFrom"],
        "expiresAt": entry["expiresAt"],
    }
