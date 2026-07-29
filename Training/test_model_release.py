import argparse
import base64
import json
import pathlib
import subprocess
import tempfile
import unittest

import sign_validated_model_release as release
from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING


class ValidatedModelReleaseSignerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.model = self.root / "Synthetic.mlmodelc"
        self.model.write_bytes(b"synthetic compiled Core ML model")
        self.key = self.root / "release-key.pem"
        subprocess.run(
            ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(self.key)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.evaluation = self.root / "SyntheticEvaluation.json"
        self.rights = self.root / "SyntheticRights.json"
        self.output = self.root / "ServeAIValidatedModelRelease.json"
        self.write_documents()

    def tearDown(self):
        self.temporary.cleanup()

    def write_documents(self, *, priority=0.90, commercial_grant=True):
        identity = {
            "modelIdentifier": "serveai.synthetic-validation-test",
            "modelVersion": "1.0.0-test",
        }
        evaluation = {
            "schemaVersion": 4,
            **identity,
            "modelSHA256": release.sha256_artifact(self.model),
            "rubric": dict(CURRENT_RUBRIC_BINDING),
            "capturePlan": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "releaseEligible": True,
            "passesProductionAccuracyGates": True,
            "commercialUseCleared": True,
            "coachGroundTruthVerified": True,
            "independentAdjudicationPolicyVerified": True,
            "coreMLParityPassed": True,
            "conversionParityMaximumAbsoluteError": 0.00001,
            "conversionParitySampleCount": 60,
            "design": {
                "heldOutClipCount": 60,
                "uniquePlayerCount": 10,
                "usesPlayerHeldOutSplit": True,
                "allClipsHaveTrainingConsent": True,
                "provenanceVerified": True,
                "auditedSubgroupDimensions": sorted(release.REQUIRED_SUBGROUPS),
                "failedMaterialSubgroups": [],
                "evaluatedCameraAngles": sorted(release.REQUIRED_CAMERA_ANGLES),
                "evaluatedSkillGroups": sorted(release.REQUIRED_SKILL_GROUPS),
                "repeatabilityPairCount": 30,
                "repeatabilityPlayerCount": 10,
                "repeatabilityUsesExactSameVideo": True,
            },
            "metrics": {
                "qualityPrecision": 0.95,
                "qualityRecall": 0.95,
                "boundaryMeanAbsoluteErrorSeconds": 0.08,
                "phaseVisibilityF1": 0.90,
                "techniqueRatingMeanAbsoluteError": 0.40,
                "priorityAgreement": priority,
                "repeatabilityWithinFivePoints": 0.95,
            },
        }
        rights = {
            "schemaVersion": 1,
            **identity,
            "commercialUseCleared": True,
            "trainingSources": [
                {
                    "sourceIdentifier": "consented-first-party-test-data",
                    "licenseIdentifier": "ServeAI-training-consent-v1",
                    "evidenceSHA256": "a" * 64,
                    "permitsCommercialModelTraining": commercial_grant,
                }
            ],
        }
        self.evaluation.write_text(json.dumps(evaluation, sort_keys=True))
        self.rights.write_text(json.dumps(rights, sort_keys=True))

    def args(self):
        return argparse.Namespace(
            model=self.model,
            evaluation=self.evaluation,
            rights_evidence=self.rights,
            private_key=self.key,
            issued_at="2026-07-26T12:00:00Z",
            output=self.output,
        )

    def test_passing_evidence_creates_verifiable_p256_envelope(self):
        envelope, key_id = release.create_release(self.args())
        payload = base64.b64decode(envelope["payloadBase64"])
        signature = base64.b64decode(envelope["signature"]["derBase64"])
        payload_file = self.root / "payload.json"
        signature_file = self.root / "signature.der"
        public_key = self.root / "public-key.pem"
        payload_file.write_bytes(payload)
        signature_file.write_bytes(signature)
        subprocess.run(
            ["openssl", "ec", "-in", str(self.key), "-pubout", "-out", str(public_key)],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        verification = subprocess.run(
            [
                "openssl", "dgst", "-sha256", "-verify", str(public_key),
                "-signature", str(signature_file), str(payload_file),
            ],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.assertEqual(verification.returncode, 0, verification.stderr.decode())
        self.assertEqual(envelope["signature"]["keyID"], key_id)
        self.assertEqual(len(key_id), 64)

    def test_signer_refuses_technique_or_priority_gate_failure(self):
        self.write_documents(priority=0.74)
        with self.assertRaisesRegex(release.ReleaseGateError, "priorityAgreement"):
            release.create_release(self.args())

    def test_signer_refuses_missing_commercial_training_grant(self):
        self.write_documents(commercial_grant=False)
        with self.assertRaisesRegex(release.ReleaseGateError, "permitsCommercialModelTraining"):
            release.create_release(self.args())

    def test_signer_refuses_model_tampering_after_evaluation(self):
        self.model.write_bytes(b"tampered after evaluation")
        with self.assertRaisesRegex(release.ReleaseGateError, "evaluation.modelSHA256"):
            release.create_release(self.args())

    def test_signer_refuses_capture_plan_substitution(self):
        evaluation = json.loads(self.evaluation.read_text())
        evaluation["capturePlan"]["version"] = "1.0.1"
        self.evaluation.write_text(json.dumps(evaluation, sort_keys=True))

        with self.assertRaisesRegex(release.ReleaseGateError, "capturePlan"):
            release.create_release(self.args())

    def test_current_thetis_pseudo_model_cannot_be_promoted(self):
        repository = pathlib.Path(__file__).resolve().parent
        args = self.args()
        args.evaluation = repository / "artifacts" / "thetis_pseudo_coach_evaluation.json"
        with self.assertRaises(release.ReleaseGateError):
            release.create_release(args)

    def test_compiled_model_directory_hash_matches_native_contract(self):
        directory = self.root / "Directory.mlmodelc"
        (directory / "sub").mkdir(parents=True)
        (directory / "a.bin").write_bytes(b"alpha")
        (directory / "sub" / "b.bin").write_bytes(b"beta")
        self.assertEqual(
            release.sha256_artifact(directory),
            "d785f6953ed84c82b2cccb5c079398afaddbabdd54888d837f2946836d99c2d2",
        )


if __name__ == "__main__":
    unittest.main()
