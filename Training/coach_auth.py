#!/usr/bin/env python3
"""Cryptographic coach authorization for ServeAI ground-truth artifacts.

The registry is authorized with an admin HMAC whose secret stays outside the
repository. Individual annotations and adjudications are signed with each
coach's EC private key; only public keys are stored in the registry.
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
from datetime import datetime, timezone
from pathlib import Path


REGISTRY_SCHEMA = 1
SIGNATURE_SCHEMA = 1
REGISTRY_SECRET_ENV = "SERVEAI_COACH_REGISTRY_SECRET"


class CoachAuthorizationError(ValueError):
    pass


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def registry_payload(registry: dict) -> dict:
    return {
        "schemaVersion": registry.get("schemaVersion"),
        "registryID": registry.get("registryID"),
        "issuedAt": registry.get("issuedAt"),
        "coaches": registry.get("coaches"),
    }


def require_registry_secret(environment: dict[str, str] | None = None) -> bytes:
    value = (environment or os.environ).get(REGISTRY_SECRET_ENV, "")
    if len(value) < 32:
        raise CoachAuthorizationError(
            f"{REGISTRY_SECRET_ENV} must contain at least 32 characters and must not be committed"
        )
    return value.encode("utf-8")


def sign_registry_payload(unsigned: dict, secret: bytes) -> dict:
    payload = registry_payload(unsigned)
    if payload["schemaVersion"] != REGISTRY_SCHEMA:
        raise CoachAuthorizationError(f"registry schema must be {REGISTRY_SCHEMA}")
    signature = hmac.new(secret, canonical_json(payload), hashlib.sha256).hexdigest()
    return {**payload, "signatureAlgorithm": "HMAC-SHA256", "signature": signature}


def load_verified_registry(path: Path, secret: bytes, now: datetime | None = None) -> dict[str, dict]:
    try:
        registry = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise CoachAuthorizationError(f"coach registry is unreadable: {error}") from error
    if registry.get("schemaVersion") != REGISTRY_SCHEMA:
        raise CoachAuthorizationError(f"coach registry schema must be {REGISTRY_SCHEMA}")
    if registry.get("signatureAlgorithm") != "HMAC-SHA256":
        raise CoachAuthorizationError("coach registry signature algorithm is unsupported")
    expected = hmac.new(secret, canonical_json(registry_payload(registry)), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, str(registry.get("signature", ""))):
        raise CoachAuthorizationError("coach registry signature is invalid")

    current = now or datetime.now(timezone.utc)
    active: dict[str, dict] = {}
    seen: set[str] = set()
    seen_public_keys: set[str] = set()
    if not str(registry.get("registryID", "")).strip() or not registry.get("issuedAt"):
        raise CoachAuthorizationError("coach registry ID and issue timestamp are required")
    for entry in registry.get("coaches") or []:
        coach_id = str(entry.get("coachID", "")).strip()
        if not coach_id or coach_id in seen:
            raise CoachAuthorizationError("coach registry contains a missing or duplicate coach ID")
        seen.add(coach_id)
        if entry.get("status") != "active":
            continue
        try:
            expires_at = parse_iso8601(entry.get("expiresAt"))
        except (TypeError, ValueError) as error:
            raise CoachAuthorizationError(f"coach {coach_id} has an invalid expiry") from error
        if expires_at <= current:
            continue
        if not str(entry.get("qualification", "")).strip():
            raise CoachAuthorizationError(f"coach {coach_id} has no verified qualification")
        public_key = str(entry.get("publicKeyPEM", ""))
        if "BEGIN PUBLIC KEY" not in public_key:
            raise CoachAuthorizationError(f"coach {coach_id} has no valid public key")
        key_fingerprint = hashlib.sha256(public_key.encode("utf-8")).hexdigest()
        if key_fingerprint in seen_public_keys:
            raise CoachAuthorizationError("two active coaches cannot share one public key")
        seen_public_keys.add(key_fingerprint)
        key_check = subprocess.run(
            ["openssl", "pkey", "-pubin", "-text", "-noout"],
            input=public_key.encode("utf-8"),
            check=False,
            capture_output=True,
        )
        key_detail = key_check.stdout.decode("utf-8", errors="replace")
        if key_check.returncode != 0 or not ("prime256v1" in key_detail or "P-256" in key_detail):
            raise CoachAuthorizationError(f"coach {coach_id} public key is not EC P-256")
        active[coach_id] = entry
    return active


def signature_path_for(artifact_path: Path) -> Path:
    return artifact_path.with_suffix(".signature.json")


def artifact_id(artifact: dict) -> object:
    return artifact.get("annotationID") or artifact.get("adjudicationID") or artifact.get("groundTruthID")


def sign_artifact(
    artifact_path: Path,
    coach_id: str,
    private_key_path: Path,
    output_path: Path | None = None,
) -> Path:
    data = artifact_path.read_bytes()
    command = [
        "openssl", "dgst", "-sha256", "-sign", str(private_key_path), str(artifact_path)
    ]
    result = subprocess.run(command, check=False, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise CoachAuthorizationError(f"OpenSSL could not sign the artifact: {detail}")
    try:
        artifact = json.loads(data)
    except json.JSONDecodeError as error:
        raise CoachAuthorizationError(f"artifact is not valid JSON: {error}") from error
    sidecar = {
        "schemaVersion": SIGNATURE_SCHEMA,
        "coachID": coach_id,
        "artifactID": artifact_id(artifact),
        "contentSHA256": hashlib.sha256(data).hexdigest(),
        "signatureAlgorithm": "ECDSA-P256-SHA256",
        "signatureBase64": base64.b64encode(result.stdout).decode("ascii"),
    }
    destination = output_path or signature_path_for(artifact_path)
    destination.write_text(json.dumps(sidecar, indent=2, sort_keys=True) + "\n")
    return destination


def verify_artifact_signature(
    artifact_path: Path,
    coach_id: str,
    registry: dict[str, dict],
    sidecar_path: Path | None = None,
) -> None:
    entry = registry.get(coach_id)
    if entry is None:
        raise CoachAuthorizationError(f"coach {coach_id} is not active in the signed registry")
    path = sidecar_path or signature_path_for(artifact_path)
    try:
        sidecar = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise CoachAuthorizationError(f"signature sidecar is unreadable: {error}") from error
    if sidecar.get("schemaVersion") != SIGNATURE_SCHEMA:
        raise CoachAuthorizationError(f"signature schema must be {SIGNATURE_SCHEMA}")
    if sidecar.get("coachID") != coach_id:
        raise CoachAuthorizationError("signature coach does not match the artifact coach")
    if sidecar.get("signatureAlgorithm") != "ECDSA-P256-SHA256":
        raise CoachAuthorizationError("artifact signature algorithm is unsupported")

    data = artifact_path.read_bytes()
    try:
        artifact = json.loads(data)
    except json.JSONDecodeError as error:
        raise CoachAuthorizationError("signed artifact is no longer valid JSON") from error
    signed_artifact_id = artifact_id(artifact)
    if not signed_artifact_id or sidecar.get("artifactID") != signed_artifact_id:
        raise CoachAuthorizationError("signature artifact ID does not match the signed JSON")
    if not hmac.compare_digest(hashlib.sha256(data).hexdigest(), str(sidecar.get("contentSHA256", ""))):
        raise CoachAuthorizationError("artifact content hash does not match its signature sidecar")
    try:
        signature = base64.b64decode(sidecar["signatureBase64"], validate=True)
    except (KeyError, ValueError, binascii.Error) as error:
        raise CoachAuthorizationError("artifact signature is not valid base64") from error

    with tempfile.TemporaryDirectory(prefix="serveai-coach-auth-") as temp:
        temp_path = Path(temp)
        key_path = temp_path / "coach-public.pem"
        signature_path = temp_path / "artifact.sig"
        key_path.write_text(entry["publicKeyPEM"])
        signature_path.write_bytes(signature)
        result = subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-verify", str(key_path),
                "-signature", str(signature_path), str(artifact_path),
            ],
            check=False,
            capture_output=True,
        )
    if result.returncode != 0:
        raise CoachAuthorizationError("artifact signature is invalid")


def parse_iso8601(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timestamp must include a timezone")
    return parsed
