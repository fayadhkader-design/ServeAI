import base64
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import build_repeatability_report as repeatability
from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING, SLOTS_BY_ID
from evaluate_release_candidate import canonical_digest
from sign_validated_model_release import sha256_artifact


class SignedRepeatabilityReportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="serveai-repeatability-")
        self.root = Path(self.temporary.name)
        self.private_key = self.root / "private.pem"
        self.public_der = self.root / "public.der"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(self.private_key)],
            check=True, capture_output=True,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(self.private_key), "-pubout", "-outform", "DER", "-out", str(self.public_der)],
            check=True, capture_output=True,
        )
        self.public_x963 = self.public_der.read_bytes()[-65:]
        self.signer_key_id = hashlib.sha256(self.public_x963).hexdigest()
        self.registry = {
            "coordinator-a": {
                "coordinatorID": "coordinator-a",
                "organization": "ServeAI test study",
                "role": "Collection coordinator",
                "authorizedFrom": "2026-07-26T00:00:00Z",
                "expiresAt": "2099-01-01T00:00:00Z",
                "signerKeyID": self.signer_key_id,
                "publicKeyX963": base64.b64encode(self.public_x963).decode(),
            },
        }
        self.compiled_model = self.root / "Validated.mlmodelc"
        self.compiled_model.mkdir()
        (self.compiled_model / "model.bin").write_bytes(b"compiled release candidate")
        self.model_hash = sha256_artifact(self.compiled_model)
        self.identity = {
            "modelIdentifier": "serveai.release-candidate",
            "modelVersion": "1.0.0-test",
        }
        self.video_hash = "a" * 64
        self.app_build = "com.serveai.app/1.0(42)"
        slot = SLOTS_BY_ID["slot-241"]
        records = [{
            "analysisID": "held-out-analysis",
            "participantPseudonym": slot["participantPseudonym"],
            "split": slot["split"],
            "sourceVideoSHA256": self.video_hash,
            "cameraAngle": slot["cameraAngle"],
            "skillLevel": slot["skillLevel"],
            "rubric": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanProvenance": {
                "status": "PINNED — signed task matches frozen capture plan",
                "plan": dict(CURRENT_CAPTURE_PLAN_BINDING),
                "slotID": slot["slotID"],
                "participantPseudonym": slot["participantPseudonym"],
                "split": slot["split"],
            },
        }]
        self.test_record = records[0]
        digest = canonical_digest(records)
        self.dataset = self.root / "dataset.json"
        self.dataset.write_text(json.dumps({
            "schemaVersion": 3,
            "trainingEligible": True,
            "datasetDigest": digest,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "records": records,
        }))
        self.model = self.root / "model.json"
        self.model.write_text(json.dumps({
            "schemaVersion": 1,
            **self.identity,
            "trainingDatasetDigest": digest,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
        }))
        self.first_task = self.write_task("task-first", "run-first", 81, "first.json")
        self.repeated_task = self.write_task("task-repeated", "run-repeated", 84, "repeated.json")
        self.manifest = self.root / "pairs.json"
        self.write_manifest()

    def tearDown(self):
        self.temporary.cleanup()

    def signed_task(self, task_id, analysis_id, score, *, source="coreML"):
        payload = {
            "schemaVersion": 1,
            "taskID": task_id,
            "analysisID": analysis_id,
            "createdAt": "2026-07-26T12:00:00Z",
            "coordinatorPseudonym": "coordinator-a",
            "sourceVideoFilename": "serve.mov",
            "sourceVideoSHA256": self.video_hash,
            "analysis": {
                "id": analysis_id,
                "createdAt": "2026-07-26T12:00:00Z",
                "overallScore": score,
                "skillLevel": self.test_record["skillLevel"],
                "cameraAngle": self.test_record["cameraAngle"],
                "source": source,
                "modelFeatureEvidence": {"provenance": {"videoSHA256": self.video_hash}},
                "modelTrace": {
                    **self.identity,
                    "modelArtifactSHA256": self.model_hash,
                    "validatedReleaseVerified": source == "coreML",
                    "appBuildIdentifier": self.app_build,
                },
            },
        }
        content = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        content_path = self.root / f"{task_id}.payload"
        signature_path = self.root / f"{task_id}.sig"
        content_path.write_bytes(content)
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(self.private_key), "-out", str(signature_path), str(content_path)],
            check=True, capture_output=True,
        )
        return {
            "schemaVersion": 1,
            "payload": payload,
            "signature": {
                "algorithm": "ECDSA-P256-SHA256",
                "signerKeyID": self.signer_key_id,
                "publicKeyX963": base64.b64encode(self.public_x963).decode(),
                "signedContentSHA256": hashlib.sha256(content).hexdigest(),
                "signatureDER": base64.b64encode(signature_path.read_bytes()).decode(),
            },
        }

    def write_task(self, task_id, analysis_id, score, filename):
        path = self.root / filename
        path.write_text(json.dumps(self.signed_task(task_id, analysis_id, score)))
        return path

    def write_manifest(self, *, repeated="repeated.json"):
        self.manifest.write_text(json.dumps({
            "schemaVersion": 1,
            "appBuildIdentifier": self.app_build,
            "pairs": [{
                "analysisID": "held-out-analysis",
                "firstTask": "first.json",
                "repeatedTask": repeated,
            }],
        }))

    def build(self):
        return repeatability.build_report(
            compiled_model_path=self.compiled_model,
            research_model_path=self.model,
            dataset_path=self.dataset,
            pair_manifest_path=self.manifest,
            registry=self.registry,
        )

    def test_two_authorized_signed_runs_build_exact_video_report(self):
        report = self.build()

        self.assertEqual(report["modelSHA256"], self.model_hash)
        self.assertEqual(report["protocol"], repeatability.PROTOCOL)
        self.assertEqual(report["pairs"][0]["firstScore"], 81)
        self.assertEqual(report["pairs"][0]["repeatedScore"], 84)
        self.assertEqual(report["pairs"][0]["sourceVideoSHA256"], self.video_hash)

    def test_score_tampering_is_rejected_by_signature(self):
        task = json.loads(self.first_task.read_text())
        task["payload"]["analysis"]["overallScore"] = 1
        self.first_task.write_text(json.dumps(task))

        with self.assertRaisesRegex(ValueError, "signature|signed-content"):
            self.build()

    def test_wrong_model_artifact_trace_is_rejected(self):
        wrong = self.signed_task("task-wrong-model", "run-wrong-model", 84)
        wrong["payload"]["analysis"]["modelTrace"]["modelArtifactSHA256"] = "f" * 64
        # Re-sign the semantically wrong payload so this reaches the model-binding gate.
        content = json.dumps(wrong["payload"], sort_keys=True, separators=(",", ":")).encode()
        payload_path = self.root / "wrong.payload"
        signature_path = self.root / "wrong.sig"
        payload_path.write_bytes(content)
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(self.private_key), "-out", str(signature_path), str(payload_path)],
            check=True, capture_output=True,
        )
        wrong["signature"]["signedContentSHA256"] = hashlib.sha256(content).hexdigest()
        wrong["signature"]["signatureDER"] = base64.b64encode(signature_path.read_bytes()).decode()
        (self.root / "wrong.json").write_text(json.dumps(wrong))
        self.write_manifest(repeated="wrong.json")

        with self.assertRaisesRegex(repeatability.RepeatabilityEvidenceError, "model/app trace"):
            self.build()

    def test_same_native_analysis_cannot_count_as_two_runs(self):
        duplicate = self.write_task("task-duplicate", "run-first", 82, "duplicate.json")
        self.assertTrue(duplicate.exists())
        self.write_manifest(repeated="duplicate.json")

        with self.assertRaisesRegex(repeatability.RepeatabilityEvidenceError, "analysis runs"):
            self.build()

    def test_explicit_evaluation_candidate_source_is_accepted(self):
        self.first_task.write_text(json.dumps(self.signed_task(
            "task-first", "run-first", 81, source="evaluationCoreML",
        )))
        self.repeated_task.write_text(json.dumps(self.signed_task(
            "task-repeated", "run-repeated", 84, source="evaluationCoreML",
        )))

        report = self.build()

        self.assertEqual(report["pairs"][0]["firstScore"], 81)


if __name__ == "__main__":
    unittest.main()
