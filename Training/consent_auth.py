#!/usr/bin/env python3
"""Independent consent authorization for ServeAI model-development records.

Coach annotations may reference consent, but they are not consent authority.
This module verifies immutable consent receipts signed by a separately
authorized study/privacy administrator and binds each grant to a participant,
the disclosed purposes, data categories, and exact source-video fingerprints.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import subprocess
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from coach_auth import canonical_json, parse_iso8601


CONSENT_REGISTRY_SCHEMA = 1
CONSENT_RECEIPT_SCHEMA = 1
CONSENT_SIGNATURE_SCHEMA = 1
CONSENT_LEDGER_SCHEMA = 1
CONSENT_LEDGER_SIGNATURE_SCHEMA = 1
MAX_CONSENT_LEDGER_AGE = timedelta(hours=24)
CONSENT_REGISTRY_SECRET_ENV = "SERVEAI_CONSENT_REGISTRY_SECRET"
CURRENT_CONSENT_VERSION = "2026-07"
REQUIRED_PURPOSES = {"serveModelTraining", "serveModelEvaluation"}
REQUIRED_DATA_CATEGORIES = {"serveVideo", "bodyPoseFeatures", "coachAnnotations"}
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")


class ConsentAuthorizationError(ValueError):
    pass


def require_separate_signing_domains(
    coach_registry: dict[str, dict],
    consent_registry: dict[str, dict],
) -> None:
    coach_fingerprints = {
        hashlib.sha256(str(entry.get("publicKeyPEM", "")).encode("utf-8")).hexdigest()
        for entry in coach_registry.values()
    }
    consent_fingerprints = {
        hashlib.sha256(str(entry.get("publicKeyPEM", "")).encode("utf-8")).hexdigest()
        for entry in consent_registry.values()
    }
    if coach_fingerprints & consent_fingerprints:
        raise ConsentAuthorizationError(
            "coach and consent-authority registries must not share signing keys"
        )


def _registry_payload(registry: dict) -> dict:
    return {
        "schemaVersion": registry.get("schemaVersion"),
        "registryID": registry.get("registryID"),
        "issuedAt": registry.get("issuedAt"),
        "authorities": registry.get("authorities"),
    }


def require_consent_registry_secret(environment: dict[str, str] | None = None) -> bytes:
    value = (environment or os.environ).get(CONSENT_REGISTRY_SECRET_ENV, "")
    if len(value) < 32:
        raise ConsentAuthorizationError(
            f"{CONSENT_REGISTRY_SECRET_ENV} must contain at least 32 characters and must not be committed"
        )
    return value.encode("utf-8")


def sign_consent_registry_payload(unsigned: dict, secret: bytes) -> dict:
    payload = _registry_payload(unsigned)
    if payload["schemaVersion"] != CONSENT_REGISTRY_SCHEMA:
        raise ConsentAuthorizationError(f"consent registry schema must be {CONSENT_REGISTRY_SCHEMA}")
    signature = hmac.new(secret, canonical_json(payload), hashlib.sha256).hexdigest()
    return {**payload, "signatureAlgorithm": "HMAC-SHA256", "signature": signature}


def load_verified_consent_registry(
    path: Path,
    secret: bytes,
    now: datetime | None = None,
) -> dict[str, dict]:
    try:
        registry = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ConsentAuthorizationError(f"consent registry is unreadable: {error}") from error
    if registry.get("schemaVersion") != CONSENT_REGISTRY_SCHEMA:
        raise ConsentAuthorizationError(f"consent registry schema must be {CONSENT_REGISTRY_SCHEMA}")
    if registry.get("signatureAlgorithm") != "HMAC-SHA256":
        raise ConsentAuthorizationError("consent registry signature algorithm is unsupported")
    expected = hmac.new(secret, canonical_json(_registry_payload(registry)), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, str(registry.get("signature", ""))):
        raise ConsentAuthorizationError("consent registry signature is invalid")
    if not str(registry.get("registryID", "")).strip() or not registry.get("issuedAt"):
        raise ConsentAuthorizationError("consent registry ID and issue timestamp are required")
    try:
        parse_iso8601(registry["issuedAt"])
    except (TypeError, ValueError) as error:
        raise ConsentAuthorizationError("consent registry issue timestamp is invalid") from error

    current = now or datetime.now(timezone.utc)
    active: dict[str, dict] = {}
    seen_ids: set[str] = set()
    seen_keys: set[str] = set()
    for entry in registry.get("authorities") or []:
        authority_id = str(entry.get("authorityID", "")).strip()
        if not authority_id or authority_id in seen_ids:
            raise ConsentAuthorizationError("consent registry contains a missing or duplicate authority ID")
        seen_ids.add(authority_id)
        if entry.get("status") != "active":
            continue
        if not str(entry.get("organization", "")).strip() or not str(entry.get("role", "")).strip():
            raise ConsentAuthorizationError(f"consent authority {authority_id} lacks organization or role")
        try:
            expires_at = parse_iso8601(entry.get("expiresAt"))
        except (TypeError, ValueError) as error:
            raise ConsentAuthorizationError(f"consent authority {authority_id} has an invalid expiry") from error
        if expires_at <= current:
            continue
        public_key = str(entry.get("publicKeyPEM", ""))
        if "BEGIN PUBLIC KEY" not in public_key:
            raise ConsentAuthorizationError(f"consent authority {authority_id} has no valid public key")
        fingerprint = hashlib.sha256(public_key.encode("utf-8")).hexdigest()
        if fingerprint in seen_keys:
            raise ConsentAuthorizationError("two active consent authorities cannot share one public key")
        seen_keys.add(fingerprint)
        check = subprocess.run(
            ["openssl", "pkey", "-pubin", "-text", "-noout"],
            input=public_key.encode("utf-8"),
            check=False,
            capture_output=True,
        )
        detail = check.stdout.decode("utf-8", errors="replace")
        if check.returncode != 0 or not ("prime256v1" in detail or "P-256" in detail):
            raise ConsentAuthorizationError(f"consent authority {authority_id} public key is not EC P-256")
        active[authority_id] = entry
    return active


def consent_signature_path_for(receipt_path: Path) -> Path:
    return receipt_path.with_suffix(".consent-signature.json")


def consent_ledger_signature_path_for(ledger_path: Path) -> Path:
    return ledger_path.with_suffix(".consent-ledger-signature.json")


def sign_consent_receipt(
    receipt_path: Path,
    authority_id: str,
    private_key_path: Path,
    output_path: Path | None = None,
) -> Path:
    data = receipt_path.read_bytes()
    try:
        receipt = json.loads(data)
    except json.JSONDecodeError as error:
        raise ConsentAuthorizationError(f"consent receipt is not valid JSON: {error}") from error
    receipt_id = receipt.get("consentReceiptID")
    if not receipt_id:
        raise ConsentAuthorizationError("consent receipt ID is missing")
    if receipt.get("authorityID") != authority_id:
        raise ConsentAuthorizationError("signing authority does not match consent receipt authority")
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(private_key_path), str(receipt_path)],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ConsentAuthorizationError(f"OpenSSL could not sign the consent receipt: {detail}")
    sidecar = {
        "schemaVersion": CONSENT_SIGNATURE_SCHEMA,
        "authorityID": authority_id,
        "consentReceiptID": receipt_id,
        "contentSHA256": hashlib.sha256(data).hexdigest(),
        "signatureAlgorithm": "ECDSA-P256-SHA256",
        "signatureBase64": base64.b64encode(result.stdout).decode("ascii"),
    }
    destination = output_path or consent_signature_path_for(receipt_path)
    destination.write_text(json.dumps(sidecar, indent=2, sort_keys=True) + "\n")
    return destination


def verify_consent_receipt_signature(
    receipt_path: Path,
    authority_id: str,
    registry: dict[str, dict],
    sidecar_path: Path | None = None,
) -> None:
    entry = registry.get(authority_id)
    if entry is None:
        raise ConsentAuthorizationError(f"consent authority {authority_id} is not active in the signed registry")
    path = sidecar_path or consent_signature_path_for(receipt_path)
    try:
        sidecar = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ConsentAuthorizationError(f"consent signature sidecar is unreadable: {error}") from error
    if sidecar.get("schemaVersion") != CONSENT_SIGNATURE_SCHEMA:
        raise ConsentAuthorizationError(f"consent signature schema must be {CONSENT_SIGNATURE_SCHEMA}")
    if sidecar.get("authorityID") != authority_id:
        raise ConsentAuthorizationError("consent signature authority does not match the receipt")
    if sidecar.get("signatureAlgorithm") != "ECDSA-P256-SHA256":
        raise ConsentAuthorizationError("consent signature algorithm is unsupported")
    data = receipt_path.read_bytes()
    try:
        receipt = json.loads(data)
    except json.JSONDecodeError as error:
        raise ConsentAuthorizationError("signed consent receipt is no longer valid JSON") from error
    if not receipt.get("consentReceiptID") or sidecar.get("consentReceiptID") != receipt.get("consentReceiptID"):
        raise ConsentAuthorizationError("consent signature receipt ID does not match the signed JSON")
    digest = hashlib.sha256(data).hexdigest()
    if not hmac.compare_digest(digest, str(sidecar.get("contentSHA256", ""))):
        raise ConsentAuthorizationError("consent receipt content hash does not match its signature sidecar")
    try:
        signature = base64.b64decode(sidecar["signatureBase64"], validate=True)
    except (KeyError, ValueError, binascii.Error) as error:
        raise ConsentAuthorizationError("consent receipt signature is not valid base64") from error
    with tempfile.TemporaryDirectory(prefix="serveai-consent-auth-") as temporary:
        directory = Path(temporary)
        key_path = directory / "authority-public.pem"
        signature_path = directory / "receipt.sig"
        key_path.write_text(entry["publicKeyPEM"])
        signature_path.write_bytes(signature)
        result = subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-verify", str(key_path),
                "-signature", str(signature_path), str(receipt_path),
            ],
            check=False,
            capture_output=True,
        )
    if result.returncode != 0:
        raise ConsentAuthorizationError("consent receipt signature is invalid")


def create_consent_ledger_snapshot(
    receipt_paths: list[Path],
    authority_id: str,
    *,
    snapshot_id: str,
    issued_at: datetime | None = None,
) -> dict:
    entries: list[dict] = []
    seen: set[str] = set()
    for path in receipt_paths:
        try:
            receipt = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ConsentAuthorizationError(f"{path.name}: unreadable consent receipt ({error})") from error
        receipt_id = str(receipt.get("consentReceiptID", "")).strip()
        record_id = str(receipt.get("consentRecordID", "")).strip()
        if not receipt_id or not record_id:
            raise ConsentAuthorizationError(f"{path.name}: consent receipt or record ID is missing")
        if receipt_id in seen:
            raise ConsentAuthorizationError("consent ledger cannot contain duplicate receipt IDs")
        seen.add(receipt_id)
        entries.append({
            "consentReceiptID": receipt_id,
            "consentRecordID": record_id,
            "receiptSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    if not entries:
        raise ConsentAuthorizationError("consent ledger must contain at least one receipt")
    timestamp = issued_at or datetime.now(timezone.utc)
    return {
        "schemaVersion": CONSENT_LEDGER_SCHEMA,
        "consentLedgerSnapshotID": snapshot_id,
        "authorityID": authority_id,
        "issuedAt": timestamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
        "receiptCount": len(entries),
        "receiptEntries": sorted(entries, key=lambda item: item["consentReceiptID"]),
    }


def sign_consent_ledger_snapshot(
    ledger_path: Path,
    authority_id: str,
    private_key_path: Path,
    output_path: Path | None = None,
) -> Path:
    data = ledger_path.read_bytes()
    try:
        ledger = json.loads(data)
    except json.JSONDecodeError as error:
        raise ConsentAuthorizationError(f"consent ledger is not valid JSON: {error}") from error
    snapshot_id = ledger.get("consentLedgerSnapshotID")
    if not snapshot_id:
        raise ConsentAuthorizationError("consent ledger snapshot ID is missing")
    if ledger.get("authorityID") != authority_id:
        raise ConsentAuthorizationError("signing authority does not match consent ledger authority")
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", str(private_key_path), str(ledger_path)],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ConsentAuthorizationError(f"OpenSSL could not sign the consent ledger: {detail}")
    sidecar = {
        "schemaVersion": CONSENT_LEDGER_SIGNATURE_SCHEMA,
        "authorityID": authority_id,
        "consentLedgerSnapshotID": snapshot_id,
        "contentSHA256": hashlib.sha256(data).hexdigest(),
        "signatureAlgorithm": "ECDSA-P256-SHA256",
        "signatureBase64": base64.b64encode(result.stdout).decode("ascii"),
    }
    destination = output_path or consent_ledger_signature_path_for(ledger_path)
    destination.write_text(json.dumps(sidecar, indent=2, sort_keys=True) + "\n")
    return destination


def verify_consent_ledger_snapshot(
    ledger_path: Path,
    receipt_paths: list[Path],
    registry: dict[str, dict],
    *,
    now: datetime | None = None,
    maximum_age: timedelta = MAX_CONSENT_LEDGER_AGE,
    sidecar_path: Path | None = None,
) -> dict:
    try:
        ledger = json.loads(ledger_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ConsentAuthorizationError(f"consent ledger is unreadable: {error}") from error
    if ledger.get("schemaVersion") != CONSENT_LEDGER_SCHEMA:
        raise ConsentAuthorizationError(f"consent ledger schema must be {CONSENT_LEDGER_SCHEMA}")
    snapshot_id = str(ledger.get("consentLedgerSnapshotID", "")).strip()
    authority_id = str(ledger.get("authorityID", "")).strip()
    if not snapshot_id or authority_id not in registry:
        raise ConsentAuthorizationError("consent ledger snapshot ID or active authority is missing")
    try:
        issued_at = parse_iso8601(ledger.get("issuedAt"))
    except (TypeError, ValueError) as error:
        raise ConsentAuthorizationError("consent ledger issue timestamp is invalid") from error
    current = now or datetime.now(timezone.utc)
    if issued_at > current:
        raise ConsentAuthorizationError("consent ledger issue timestamp is in the future")
    if current - issued_at > maximum_age:
        raise ConsentAuthorizationError("consent ledger snapshot is stale; issue a fresh snapshot")

    entries = ledger.get("receiptEntries")
    if not isinstance(entries, list) or not entries or ledger.get("receiptCount") != len(entries):
        raise ConsentAuthorizationError("consent ledger receipt count or entries are invalid")
    actual_entries: list[dict] = []
    seen: set[str] = set()
    for path in receipt_paths:
        try:
            receipt = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ConsentAuthorizationError(f"{path.name}: unreadable consent receipt ({error})") from error
        receipt_id = str(receipt.get("consentReceiptID", "")).strip()
        if not receipt_id or receipt_id in seen:
            raise ConsentAuthorizationError("receipt set contains a missing or duplicate receipt ID")
        seen.add(receipt_id)
        actual_entries.append({
            "consentReceiptID": receipt_id,
            "consentRecordID": receipt.get("consentRecordID"),
            "receiptSHA256": hashlib.sha256(path.read_bytes()).hexdigest(),
        })
    expected = sorted(entries, key=lambda item: str(item.get("consentReceiptID", "")))
    actual = sorted(actual_entries, key=lambda item: item["consentReceiptID"])
    if expected != actual:
        raise ConsentAuthorizationError(
            "consent receipt set does not exactly match the signed ledger; a receipt may be omitted, added, or modified"
        )

    signature_path = sidecar_path or consent_ledger_signature_path_for(ledger_path)
    try:
        sidecar = json.loads(signature_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ConsentAuthorizationError(f"consent ledger signature sidecar is unreadable: {error}") from error
    if sidecar.get("schemaVersion") != CONSENT_LEDGER_SIGNATURE_SCHEMA:
        raise ConsentAuthorizationError(
            f"consent ledger signature schema must be {CONSENT_LEDGER_SIGNATURE_SCHEMA}"
        )
    if sidecar.get("authorityID") != authority_id or sidecar.get("consentLedgerSnapshotID") != snapshot_id:
        raise ConsentAuthorizationError("consent ledger signature identity does not match the ledger")
    if sidecar.get("signatureAlgorithm") != "ECDSA-P256-SHA256":
        raise ConsentAuthorizationError("consent ledger signature algorithm is unsupported")
    data = ledger_path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if not hmac.compare_digest(digest, str(sidecar.get("contentSHA256", ""))):
        raise ConsentAuthorizationError("consent ledger content hash does not match its signature sidecar")
    try:
        signature = base64.b64decode(sidecar["signatureBase64"], validate=True)
    except (KeyError, ValueError, binascii.Error) as error:
        raise ConsentAuthorizationError("consent ledger signature is not valid base64") from error
    with tempfile.TemporaryDirectory(prefix="serveai-consent-ledger-") as temporary:
        directory = Path(temporary)
        key_path = directory / "authority-public.pem"
        signature_file = directory / "ledger.sig"
        key_path.write_text(registry[authority_id]["publicKeyPEM"])
        signature_file.write_bytes(signature)
        result = subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-verify", str(key_path),
                "-signature", str(signature_file), str(ledger_path),
            ],
            check=False,
            capture_output=True,
        )
    if result.returncode != 0:
        raise ConsentAuthorizationError("consent ledger signature is invalid")
    return {
        "consentLedgerSnapshotID": snapshot_id,
        "authorityID": authority_id,
        "issuedAt": ledger["issuedAt"],
        "receiptCount": len(entries),
        "ledgerSHA256": digest,
    }


def load_verified_consent_ledger_records(
    receipt_paths: list[Path],
    ledger_path: Path,
    registry: dict[str, dict],
    *,
    now: datetime | None = None,
) -> tuple[dict[str, dict], dict]:
    ledger_evidence = verify_consent_ledger_snapshot(
        ledger_path, receipt_paths, registry, now=now
    )
    records = load_verified_consent_records(receipt_paths, registry, now=now)
    return records, ledger_evidence


def validate_consent_receipt(receipt: dict, now: datetime | None = None) -> list[str]:
    errors: list[str] = []
    if receipt.get("schemaVersion") != CONSENT_RECEIPT_SCHEMA:
        errors.append(f"consent receipt schema must be {CONSENT_RECEIPT_SCHEMA}")
    for field in ("consentReceiptID", "consentRecordID", "participantPseudonym", "authorityID"):
        if not str(receipt.get(field, "")).strip():
            errors.append(f"{field} is missing")
    if receipt.get("decision") not in {"granted", "revoked"}:
        errors.append("consent decision must be granted or revoked")
    try:
        occurred_at = parse_iso8601(receipt.get("occurredAt"))
    except (TypeError, ValueError):
        occurred_at = None
        errors.append("consent decision timestamp is invalid")
    current = now or datetime.now(timezone.utc)
    if occurred_at is not None and occurred_at > current:
        errors.append("consent decision timestamp is in the future")
    if receipt.get("consentVersion") != CURRENT_CONSENT_VERSION:
        errors.append("consent version is not current")
    notice = receipt.get("notice")
    if not isinstance(notice, dict):
        errors.append("versioned consent notice evidence is missing")
    else:
        if not str(notice.get("identifier", "")).strip() or notice.get("version") != CURRENT_CONSENT_VERSION:
            errors.append("consent notice identifier or version is invalid")
        if not SHA256_PATTERN.fullmatch(str(notice.get("documentSHA256", ""))):
            errors.append("consent notice document SHA-256 is invalid")
    if not SHA256_PATTERN.fullmatch(str(receipt.get("affirmativeActionSHA256", ""))):
        errors.append("affirmative consent evidence SHA-256 is invalid")
    if receipt.get("ageAssurance") != "adultConfirmed":
        errors.append("MVP model collection accepts adults only; age assurance is not adultConfirmed")
    purposes = receipt.get("purposes")
    if not isinstance(purposes, list) or len(purposes) != len(set(purposes)) or not REQUIRED_PURPOSES.issubset(purposes):
        errors.append("consent purposes do not authorize both model training and evaluation")
    categories = receipt.get("dataCategories")
    if not isinstance(categories, list) or len(categories) != len(set(categories)) or not REQUIRED_DATA_CATEGORIES.issubset(categories):
        errors.append("consent data categories do not cover video, pose features, and coach labels")
    hashes = receipt.get("coveredVideoSHA256")
    if not isinstance(hashes, list) or not hashes or len(hashes) != len(set(hashes)):
        errors.append("covered source-video fingerprints are missing or duplicated")
    elif any(not SHA256_PATTERN.fullmatch(str(value)) for value in hashes):
        errors.append("covered source-video fingerprint is invalid")
    if not str(receipt.get("withdrawalMechanism", "")).strip():
        errors.append("withdrawal mechanism is missing")
    for field, label in (("validUntil", "consent validity"), ("retentionUntil", "data retention")):
        try:
            value = parse_iso8601(receipt.get(field))
            if value <= current:
                errors.append(f"{label} period has expired")
            if occurred_at is not None and value <= occurred_at:
                errors.append(f"{label} end must follow the consent decision")
        except (TypeError, ValueError):
            errors.append(f"{label} timestamp is invalid")
    return errors


def load_verified_consent_records(
    receipt_paths: list[Path],
    registry: dict[str, dict],
    now: datetime | None = None,
) -> dict[str, dict]:
    grouped: dict[str, list[tuple[dict, Path, str]]] = defaultdict(list)
    seen_receipts: set[str] = set()
    failures: list[str] = []
    for path in receipt_paths:
        try:
            receipt = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            failures.append(f"{path.name}: unreadable consent receipt ({error})")
            continue
        errors = validate_consent_receipt(receipt, now=now)
        if receipt.get("authorityID") not in registry:
            errors.append("consent authority is not active in the signed registry")
        if not errors:
            try:
                verify_consent_receipt_signature(path, receipt["authorityID"], registry)
            except ConsentAuthorizationError as error:
                errors.append(str(error))
        receipt_id = receipt.get("consentReceiptID")
        if receipt_id in seen_receipts:
            errors.append("consent receipt ID is duplicated")
        if errors:
            failures.extend(f"{path.name}: {error}" for error in errors)
            continue
        seen_receipts.add(receipt_id)
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        grouped[receipt["consentRecordID"]].append((receipt, path, digest))
    if failures:
        raise ConsentAuthorizationError("; ".join(failures))

    verified: dict[str, dict] = {}
    for record_id, events in grouped.items():
        events.sort(key=lambda item: parse_iso8601(item[0]["occurredAt"]))
        participants = {item[0]["participantPseudonym"] for item in events}
        if len(participants) != 1:
            raise ConsentAuthorizationError(f"consent record {record_id} changes participant identity")
        previous_id = None
        for index, (receipt, _, _) in enumerate(events):
            if index == 0 and receipt.get("decision") != "granted":
                raise ConsentAuthorizationError(f"consent record {record_id} begins with a revocation")
            if receipt.get("supersedesReceiptID") != previous_id:
                raise ConsentAuthorizationError(f"consent record {record_id} has a broken or forked decision chain")
            previous_id = receipt["consentReceiptID"]
        receipt, path, digest = events[-1]
        verified[record_id] = {
            "receipt": receipt,
            "receiptPath": str(path),
            "receiptSHA256": digest,
            "active": receipt["decision"] == "granted",
            "decisionCount": len(events),
        }
    return verified


def verify_annotation_consent(package: dict, records: dict[str, dict]) -> tuple[dict | None, list[str]]:
    embedded = package.get("consent") or {}
    record_id = embedded.get("consentRecordID")
    verified = records.get(record_id)
    if verified is None:
        return None, ["no independently signed consent receipt matches the annotation consent record"]
    receipt = verified["receipt"]
    errors: list[str] = []
    if not verified["active"]:
        errors.append("independently signed consent has been revoked")
    if receipt.get("participantPseudonym") != package.get("participantPseudonym"):
        errors.append("signed consent participant does not match the annotation")
    if receipt.get("consentVersion") != embedded.get("consentVersion"):
        errors.append("signed consent version does not match the annotation")
    video_hash = ((package.get("modelFeatureEvidence") or {}).get("provenance") or {}).get("videoSHA256")
    if video_hash not in (receipt.get("coveredVideoSHA256") or []):
        errors.append("signed consent does not cover this source-video fingerprint")
    if errors:
        return None, errors
    evidence = {
        "consentRecordID": record_id,
        "consentReceiptID": receipt["consentReceiptID"],
        "authorityID": receipt["authorityID"],
        "decisionAt": receipt["occurredAt"],
        "consentVersion": receipt["consentVersion"],
        "noticeDocumentSHA256": receipt["notice"]["documentSHA256"],
        "receiptSHA256": verified["receiptSHA256"],
        "sourceVideoSHA256": video_hash,
    }
    return evidence, []
