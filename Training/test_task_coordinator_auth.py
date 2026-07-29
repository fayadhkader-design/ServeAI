import json
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from task_coordinator_auth import (
    TaskCoordinatorAuthorizationError,
    authorize_labeling_task,
    load_verified_task_coordinator_registry,
    sign_task_coordinator_registry_payload,
)
from test_training_pipeline import attach_signed_labeling_task, package


class TaskCoordinatorAuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="serveai-task-coordinator-")
        self.directory = Path(self.temp.name)
        self.secret = b"task-coordinator-admin-secret-long-enough"
        self.task = attach_signed_labeling_task(package())["labelingTask"]

    def tearDown(self):
        self.temp.cleanup()

    def registry(self, *, coordinator_id="coordinator-a", expires_at="2099-01-01T00:00:00Z"):
        signature = self.task["signature"]
        unsigned = {
            "schemaVersion": 1,
            "registryID": "task-coordinator-registry",
            "issuedAt": "2026-07-26T12:00:00Z",
            "coordinators": [{
                "coordinatorID": coordinator_id,
                "status": "active",
                "organization": "Test study",
                "role": "Collection coordinator",
                "authorizedFrom": "2026-07-26T00:00:00Z",
                "expiresAt": expires_at,
                "signerKeyID": signature["signerKeyID"],
                "publicKeyX963": signature["publicKeyX963"],
            }],
        }
        path = self.directory / f"registry-{coordinator_id}.json"
        path.write_text(json.dumps(sign_task_coordinator_registry_payload(unsigned, self.secret)))
        return path

    def load(self, path):
        return load_verified_task_coordinator_registry(
            path,
            self.secret,
            now=datetime(2026, 7, 27, tzinfo=timezone.utc),
        )

    def test_authorized_native_task_key_is_accepted(self):
        evidence = authorize_labeling_task(self.task, self.load(self.registry()))

        self.assertEqual(evidence["coordinatorID"], "coordinator-a")
        self.assertEqual(evidence["signerKeyID"], self.task["signature"]["signerKeyID"])

    def test_unknown_coordinator_is_rejected(self):
        with self.assertRaisesRegex(TaskCoordinatorAuthorizationError, "not active"):
            authorize_labeling_task(self.task, self.load(self.registry(coordinator_id="coordinator-b")))

    def test_expired_coordinator_is_not_active(self):
        registry = self.load(self.registry(expires_at="2026-07-26T12:30:00Z"))

        self.assertNotIn("coordinator-a", registry)
        with self.assertRaisesRegex(TaskCoordinatorAuthorizationError, "not active"):
            authorize_labeling_task(self.task, registry)

    def test_substituted_device_key_is_rejected(self):
        other_task = attach_signed_labeling_task(package())["labelingTask"]
        registry = self.load(self.registry())

        with self.assertRaisesRegex(TaskCoordinatorAuthorizationError, "signer key"):
            authorize_labeling_task(other_task, registry)

    def test_registry_tampering_is_rejected(self):
        path = self.registry()
        registry = json.loads(path.read_text())
        registry["coordinators"][0]["organization"] = "Attacker"
        path.write_text(json.dumps(registry))

        with self.assertRaisesRegex(TaskCoordinatorAuthorizationError, "signature is invalid"):
            self.load(path)


if __name__ == "__main__":
    unittest.main()

