import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from coach_auth import (
    CoachAuthorizationError,
    load_verified_registry,
    sign_artifact,
    sign_registry_payload,
    verify_artifact_signature,
)
from consent_auth import (
    create_consent_ledger_snapshot,
    sign_consent_ledger_snapshot,
    sign_consent_receipt,
    sign_consent_registry_payload,
)
from test_adjudication import resolution
from test_consent_auth import receipt
from test_training_pipeline import package
from task_coordinator_auth import sign_task_coordinator_registry_payload


class CoachAuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="serveai-auth-test-")
        self.directory = Path(self.temp.name)
        self.private_key = self.directory / "coach-private.pem"
        self.public_key = self.directory / "coach-public.pem"
        self.generate_keypair(self.private_key, self.public_key)
        self.secret = b"unit-test-admin-secret-that-is-long-enough"

    def generate_keypair(self, private_key, public_key):
        subprocess.run(
            [
                "openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                "ec_paramgen_curve:P-256", "-out", str(private_key),
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)],
            check=True,
            capture_output=True,
        )

    def tearDown(self):
        self.temp.cleanup()

    def registry(self, *, expires_at="2099-01-01T00:00:00Z"):
        unsigned = {
            "schemaVersion": 1,
            "registryID": "test-registry",
            "issuedAt": "2026-07-26T18:00:00Z",
            "coaches": [{
                "coachID": "coach-a",
                "status": "active",
                "qualification": "Test coach",
                "expiresAt": expires_at,
                "publicKeyPEM": self.public_key.read_text(),
            }],
        }
        path = self.directory / "registry.json"
        path.write_text(json.dumps(sign_registry_payload(unsigned, self.secret)))
        return path

    def test_signed_artifact_verifies_against_authorized_public_key(self):
        registry = load_verified_registry(self.registry(), self.secret)
        artifact = self.directory / "annotation.json"
        artifact.write_text(json.dumps({"annotationID": "annotation-a", "value": 7}))
        sign_artifact(artifact, "coach-a", self.private_key)

        verify_artifact_signature(artifact, "coach-a", registry)

    def test_artifact_tampering_is_rejected(self):
        registry = load_verified_registry(self.registry(), self.secret)
        artifact = self.directory / "annotation.json"
        artifact.write_text(json.dumps({"annotationID": "annotation-a", "value": 7}))
        sign_artifact(artifact, "coach-a", self.private_key)
        artifact.write_text(json.dumps({"annotationID": "annotation-a", "value": 8}))

        with self.assertRaisesRegex(CoachAuthorizationError, "content hash"):
            verify_artifact_signature(artifact, "coach-a", registry)

    def test_compiled_ground_truth_can_be_signed_by_its_adjudicator(self):
        registry = load_verified_registry(self.registry(), self.secret)
        artifact = self.directory / "ground-truth.json"
        artifact.write_text(json.dumps({"groundTruthID": "ground-truth-a", "value": 7}))
        sign_artifact(artifact, "coach-a", self.private_key)

        verify_artifact_signature(artifact, "coach-a", registry)

    def test_registry_tampering_is_rejected(self):
        path = self.registry()
        registry = json.loads(path.read_text())
        registry["coaches"][0]["coachID"] = "attacker"
        path.write_text(json.dumps(registry))

        with self.assertRaisesRegex(CoachAuthorizationError, "registry signature"):
            load_verified_registry(path, self.secret)

    def test_expired_coach_is_not_authorized(self):
        registry = load_verified_registry(
            self.registry(expires_at="2025-01-01T00:00:00Z"),
            self.secret,
            now=datetime(2026, 1, 1, tzinfo=timezone.utc),
        )

        self.assertNotIn("coach-a", registry)

    def test_dataset_preparation_accepts_two_distinct_signed_coaches(self):
        second_private = self.directory / "coach-b-private.pem"
        second_public = self.directory / "coach-b-public.pem"
        self.generate_keypair(second_private, second_public)
        unsigned = {
            "schemaVersion": 1,
            "registryID": "integration-registry",
            "issuedAt": "2026-07-26T18:00:00Z",
            "coaches": [
                {
                    "coachID": "coach-a",
                    "status": "active",
                    "qualification": "Verified coach A",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "publicKeyPEM": self.public_key.read_text(),
                },
                {
                    "coachID": "coach-b",
                    "status": "active",
                    "qualification": "Verified coach B",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "publicKeyPEM": second_public.read_text(),
                },
            ],
        }
        registry_path = self.directory / "registry.json"
        registry_path.write_text(json.dumps(sign_registry_payload(unsigned, self.secret)))
        annotations = self.directory / "annotations"
        annotations.mkdir()
        first = annotations / "first.json"
        second = annotations / "second.json"
        first.write_text(json.dumps(package(coach="coach-a"), indent=2))
        second.write_text(json.dumps(package(coach="coach-b"), indent=2))
        sign_artifact(first, "coach-a", self.private_key)
        sign_artifact(second, "coach-b", second_private)
        consent_private = self.directory / "consent-private.pem"
        consent_public = self.directory / "consent-public.pem"
        self.generate_keypair(consent_private, consent_public)
        unsigned_consent_registry = {
            "schemaVersion": 1,
            "registryID": "integration-consent-registry",
            "issuedAt": "2026-07-26T18:00:00Z",
            "authorities": [{
                "authorityID": "privacy-admin",
                "status": "active",
                "organization": "Test data controller",
                "role": "Privacy administrator",
                "expiresAt": "2099-01-01T00:00:00Z",
                "publicKeyPEM": consent_public.read_text(),
            }],
        }
        consent_registry_path = self.directory / "consent-registry.json"
        consent_registry_path.write_text(json.dumps(
            sign_consent_registry_payload(unsigned_consent_registry, self.secret)
        ))
        task_coordinator_registry_path = self.directory / "task-coordinator-registry.json"
        task_coordinator_registry_path.write_text(json.dumps(
            sign_task_coordinator_registry_payload({
                "schemaVersion": 1,
                "registryID": "integration-task-coordinator-registry",
                "issuedAt": "2026-07-26T18:00:00Z",
                "coordinators": [],
            }, self.secret)
        ))
        consent_directory = self.directory / "consent"
        consent_directory.mkdir()
        consent_path = consent_directory / "grant.json"
        consent_path.write_text(json.dumps(receipt(), indent=2))
        sign_consent_receipt(consent_path, "privacy-admin", consent_private)
        consent_ledger_path = self.directory / "consent-ledger.json"
        consent_ledger_path.write_text(json.dumps(create_consent_ledger_snapshot(
            [consent_path], "privacy-admin", snapshot_id="integration-ledger"
        ), indent=2))
        sign_consent_ledger_snapshot(consent_ledger_path, "privacy-admin", consent_private)
        output = self.directory / "index.json"
        environment = os.environ.copy()
        environment["SERVEAI_COACH_REGISTRY_SECRET"] = self.secret.decode("utf-8")
        environment["SERVEAI_CONSENT_REGISTRY_SECRET"] = self.secret.decode("utf-8")
        environment["SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET"] = self.secret.decode("utf-8")
        result = subprocess.run(
            [
                "python3", str(Path(__file__).parent / "prepare_coach_dataset.py"),
                str(annotations), "--coach-registry", str(registry_path),
                "--task-coordinator-registry", str(task_coordinator_registry_path),
                "--consent-registry", str(consent_registry_path),
                "--consent-ledger", str(consent_ledger_path),
                "--consent-receipts", str(consent_directory),
                "--output", str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        index = json.loads(output.read_text())
        self.assertTrue(index["groundTruthEligible"])
        self.assertFalse(index["modelReleaseEligible"])
        self.assertEqual(index["analysisCount"], 1)

    def test_explicit_third_coach_adjudication_compiles_end_to_end(self):
        credentials = {"coach-a": (self.private_key, self.public_key)}
        for coach_id in ("coach-b", "coach-c"):
            private_key = self.directory / f"{coach_id}-private.pem"
            public_key = self.directory / f"{coach_id}-public.pem"
            self.generate_keypair(private_key, public_key)
            credentials[coach_id] = (private_key, public_key)
        unsigned = {
            "schemaVersion": 1,
            "registryID": "adjudication-registry",
            "issuedAt": "2026-07-26T18:00:00Z",
            "coaches": [
                {
                    "coachID": coach_id,
                    "status": "active",
                    "qualification": f"Verified {coach_id}",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "publicKeyPEM": keys[1].read_text(),
                }
                for coach_id, keys in credentials.items()
            ],
        }
        registry_path = self.directory / "adjudication-registry.json"
        registry_path.write_text(json.dumps(sign_registry_payload(unsigned, self.secret)))
        first = self.directory / "first.json"
        second = self.directory / "second.json"
        decision = self.directory / "adjudication.json"
        first.write_text(json.dumps(package(coach="coach-a"), indent=2))
        second.write_text(json.dumps(package(coach="coach-b", priority="contactReach"), indent=2))
        decision.write_text(json.dumps(resolution(), indent=2))
        sign_artifact(first, "coach-a", credentials["coach-a"][0])
        sign_artifact(second, "coach-b", credentials["coach-b"][0])
        sign_artifact(decision, "coach-c", credentials["coach-c"][0])
        output = self.directory / "ground-truth.json"
        environment = os.environ.copy()
        environment["SERVEAI_COACH_REGISTRY_SECRET"] = self.secret.decode("utf-8")
        result = subprocess.run(
            [
                "python3", str(Path(__file__).parent / "adjudicate_coach_labels.py"),
                str(first), str(second), "--resolution", str(decision),
                "--coach-registry", str(registry_path), "--output", str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        ground_truth = json.loads(output.read_text())
        self.assertTrue(ground_truth["groundTruthEligible"])
        self.assertFalse(ground_truth["modelReleaseEligible"])
        self.assertEqual(ground_truth["adjudicatorPseudonym"], "coach-c")


if __name__ == "__main__":
    unittest.main()
