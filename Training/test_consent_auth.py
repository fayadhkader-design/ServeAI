import json
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from consent_auth import (
    ConsentAuthorizationError,
    create_consent_ledger_snapshot,
    load_verified_consent_ledger_records,
    load_verified_consent_records,
    load_verified_consent_registry,
    require_separate_signing_domains,
    sign_consent_receipt,
    sign_consent_ledger_snapshot,
    sign_consent_registry_payload,
    validate_consent_receipt,
    verify_consent_ledger_snapshot,
    verify_annotation_consent,
)
from test_training_pipeline import package


def receipt(*, decision="granted", receipt_id="receipt-1", supersedes=None, video_hash="a" * 64):
    return {
        "schemaVersion": 1,
        "consentReceiptID": receipt_id,
        "consentRecordID": "76f75711-1126-4e9d-bac6-09333d55ee38",
        "participantPseudonym": "player-a",
        "authorityID": "privacy-admin",
        "decision": decision,
        "occurredAt": "2026-07-26T12:00:00Z" if decision == "granted" else "2026-07-27T12:00:00Z",
        "supersedesReceiptID": supersedes,
        "consentVersion": "2026-07",
        "notice": {
            "identifier": "serveai.research-consent",
            "version": "2026-07",
            "documentSHA256": "b" * 64,
        },
        "affirmativeActionSHA256": "c" * 64,
        "ageAssurance": "adultConfirmed",
        "purposes": ["serveModelTraining", "serveModelEvaluation"],
        "dataCategories": ["serveVideo", "bodyPoseFeatures", "coachAnnotations"],
        "coveredVideoSHA256": [video_hash],
        "validUntil": "2099-01-01T00:00:00Z",
        "retentionUntil": "2099-01-01T00:00:00Z",
        "withdrawalMechanism": "study@example.invalid",
    }


class ConsentAuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="serveai-consent-test-")
        self.directory = Path(self.temp.name)
        self.private_key = self.directory / "authority-private.pem"
        self.public_key = self.directory / "authority-public.pem"
        subprocess.run(
            [
                "openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                "ec_paramgen_curve:P-256", "-out", str(self.private_key),
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(self.private_key), "-pubout", "-out", str(self.public_key)],
            check=True,
            capture_output=True,
        )
        self.secret = b"unit-test-consent-secret-that-is-long-enough"
        unsigned = {
            "schemaVersion": 1,
            "registryID": "consent-registry",
            "issuedAt": "2026-07-26T10:00:00Z",
            "authorities": [{
                "authorityID": "privacy-admin",
                "status": "active",
                "organization": "Test data controller",
                "role": "Privacy administrator",
                "expiresAt": "2099-01-01T00:00:00Z",
                "publicKeyPEM": self.public_key.read_text(),
            }],
        }
        self.registry_path = self.directory / "registry.json"
        self.registry_path.write_text(json.dumps(sign_consent_registry_payload(unsigned, self.secret)))
        self.registry = load_verified_consent_registry(
            self.registry_path,
            self.secret,
            now=datetime(2026, 7, 26, tzinfo=timezone.utc),
        )

    def tearDown(self):
        self.temp.cleanup()

    def write_and_sign(self, value, name):
        path = self.directory / name
        path.write_text(json.dumps(value, indent=2))
        sign_consent_receipt(path, "privacy-admin", self.private_key)
        return path

    def write_ledger(self, paths, *, issued_at=None, name="ledger.json"):
        path = self.directory / name
        path.write_text(json.dumps(create_consent_ledger_snapshot(
            paths,
            "privacy-admin",
            snapshot_id=f"snapshot-{name}",
            issued_at=issued_at,
        ), indent=2))
        sign_consent_ledger_snapshot(path, "privacy-admin", self.private_key)
        return path

    def test_signed_video_bound_grant_authorizes_matching_annotation(self):
        path = self.write_and_sign(receipt(), "grant.json")
        records = load_verified_consent_records(
            [path], self.registry, now=datetime(2026, 7, 26, 18, tzinfo=timezone.utc)
        )

        evidence, errors = verify_annotation_consent(package(), records)

        self.assertEqual(errors, [])
        self.assertEqual(evidence["consentReceiptID"], "receipt-1")
        self.assertEqual(evidence["sourceVideoSHA256"], "a" * 64)

    def test_fresh_signed_ledger_loads_complete_receipt_set(self):
        grant = self.write_and_sign(receipt(), "grant.json")
        ledger = self.write_ledger(
            [grant], issued_at=datetime(2026, 7, 26, 17, tzinfo=timezone.utc)
        )

        records, evidence = load_verified_consent_ledger_records(
            [grant], ledger, self.registry, now=datetime(2026, 7, 26, 18, tzinfo=timezone.utc)
        )

        self.assertIn("76f75711-1126-4e9d-bac6-09333d55ee38", records)
        self.assertEqual(evidence["receiptCount"], 1)

    def test_signed_ledger_detects_an_omitted_revocation(self):
        grant = self.write_and_sign(receipt(), "grant.json")
        revocation = self.write_and_sign(
            receipt(decision="revoked", receipt_id="receipt-2", supersedes="receipt-1"),
            "revocation.json",
        )
        ledger = self.write_ledger(
            [grant, revocation], issued_at=datetime(2026, 7, 28, 17, tzinfo=timezone.utc)
        )

        with self.assertRaisesRegex(ConsentAuthorizationError, "omitted, added, or modified"):
            verify_consent_ledger_snapshot(
                ledger,
                [grant],
                self.registry,
                now=datetime(2026, 7, 28, 18, tzinfo=timezone.utc),
            )

    def test_stale_consent_ledger_is_rejected_before_training(self):
        grant = self.write_and_sign(receipt(), "grant.json")
        ledger = self.write_ledger(
            [grant], issued_at=datetime(2026, 7, 24, 12, tzinfo=timezone.utc)
        )

        with self.assertRaisesRegex(ConsentAuthorizationError, "snapshot is stale"):
            verify_consent_ledger_snapshot(
                ledger,
                [grant],
                self.registry,
                now=datetime(2026, 7, 26, 18, tzinfo=timezone.utc),
            )

    def test_receipt_tampering_is_rejected(self):
        path = self.write_and_sign(receipt(), "grant.json")
        tampered = json.loads(path.read_text())
        tampered["coveredVideoSHA256"] = ["d" * 64]
        path.write_text(json.dumps(tampered))

        with self.assertRaisesRegex(ConsentAuthorizationError, "content hash"):
            load_verified_consent_records([path], self.registry)

    def test_later_signed_revocation_disables_record(self):
        grant = self.write_and_sign(receipt(), "grant.json")
        revocation = self.write_and_sign(
            receipt(decision="revoked", receipt_id="receipt-2", supersedes="receipt-1"),
            "revocation.json",
        )
        records = load_verified_consent_records(
            [grant, revocation], self.registry, now=datetime(2026, 7, 28, tzinfo=timezone.utc)
        )

        evidence, errors = verify_annotation_consent(package(), records)

        self.assertIsNone(evidence)
        self.assertTrue(any("revoked" in error for error in errors))

    def test_grant_cannot_authorize_a_different_video(self):
        path = self.write_and_sign(receipt(video_hash="d" * 64), "grant.json")
        records = load_verified_consent_records([path], self.registry)

        evidence, errors = verify_annotation_consent(package(), records)

        self.assertIsNone(evidence)
        self.assertTrue(any("source-video" in error for error in errors))

    def test_broken_decision_chain_is_rejected(self):
        grant = self.write_and_sign(receipt(), "grant.json")
        revocation = self.write_and_sign(
            receipt(decision="revoked", receipt_id="receipt-2", supersedes="wrong-receipt"),
            "revocation.json",
        )

        with self.assertRaisesRegex(ConsentAuthorizationError, "broken or forked"):
            load_verified_consent_records(
                [grant, revocation], self.registry, now=datetime(2026, 7, 28, tzinfo=timezone.utc)
            )

    def test_minor_or_incomplete_scope_is_rejected(self):
        candidate = receipt()
        candidate["ageAssurance"] = "guardianClaimed"
        candidate["purposes"] = ["serveModelEvaluation"]
        candidate["dataCategories"] = ["bodyPoseFeatures", "coachAnnotations"]

        errors = validate_consent_receipt(
            candidate, now=datetime(2026, 7, 26, tzinfo=timezone.utc)
        )

        self.assertTrue(any("adults only" in error for error in errors))
        self.assertTrue(any("both model training and evaluation" in error for error in errors))
        self.assertTrue(any("video, pose features" in error for error in errors))

    def test_expired_consent_and_retention_are_rejected(self):
        candidate = receipt()
        candidate["validUntil"] = "2027-01-01T00:00:00Z"
        candidate["retentionUntil"] = "2027-01-01T00:00:00Z"

        errors = validate_consent_receipt(
            candidate, now=datetime(2028, 1, 1, tzinfo=timezone.utc)
        )

        self.assertTrue(any("consent validity period has expired" in error for error in errors))
        self.assertTrue(any("data retention period has expired" in error for error in errors))

    def test_future_dated_consent_is_rejected(self):
        errors = validate_consent_receipt(
            receipt(), now=datetime(2026, 7, 25, tzinfo=timezone.utc)
        )

        self.assertTrue(any("in the future" in error for error in errors))

    def test_coach_and_consent_authority_cannot_share_a_signing_key(self):
        coach_registry = {"coach-a": {"publicKeyPEM": self.public_key.read_text()}}

        with self.assertRaisesRegex(ConsentAuthorizationError, "must not share"):
            require_separate_signing_domains(coach_registry, self.registry)


if __name__ == "__main__":
    unittest.main()
