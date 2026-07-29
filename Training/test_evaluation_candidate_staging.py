import json
import tempfile
import unittest
from pathlib import Path

from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING
from convert_temporal_model_to_coreml import HEAD_ORDER
from sign_validated_model_release import sha256_artifact
from stage_evaluation_candidate import EvaluationCandidateStagingError, stage_candidate
from unstage_evaluation_candidate import EvaluationCandidateUnstagingError, unstage_candidate


WORKSPACE = Path(__file__).resolve().parents[1]


class EvaluationCandidateStagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="serveai-stage-test-")
        self.root = Path(self.temporary.name)
        self.compiled = self.root / "Candidate.mlmodelc"
        self.compiled.mkdir()
        (self.compiled / "model.bin").write_bytes(b"exact compiled candidate")
        self.model = {
            "schemaVersion": 1,
            "releaseEligible": False,
            "modelIdentifier": "serveai.coach-temporal",
            "modelVersion": "1.0.0-rc1",
            "featureSchemaVersion": 2,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "heads": {name: {} for name in HEAD_ORDER},
        }
        self.parity = {
            "schemaVersion": 2,
            "modelIdentifier": self.model["modelIdentifier"],
            "modelVersion": self.model["modelVersion"],
            "compiledModelSHA256": sha256_artifact(self.compiled),
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "sampleCount": 60,
            "maximumAbsoluteError": 0.00001,
            "maximumAbsoluteErrorByOutput": {name: 0.00001 for name in HEAD_ORDER},
            "tolerance": 0.0001,
            "passes": True,
            "releaseEligible": False,
        }
        self.model_path = self.root / "model.json"
        self.parity_path = self.root / "parity.json"
        self.output = self.root / "EvaluationCandidate"
        self._write_inputs()

    def tearDown(self):
        self.temporary.cleanup()

    def _write_inputs(self):
        self.model_path.write_text(json.dumps(self.model))
        self.parity_path.write_text(json.dumps(self.parity))

    def test_stages_hash_bound_debug_candidate_without_release_claim(self):
        manifest = stage_candidate(
            compiled_model_path=self.compiled,
            research_model_path=self.model_path,
            parity_path=self.parity_path,
            output_directory=self.output,
        )

        self.assertEqual(manifest["purpose"], "release-evaluation-only")
        self.assertNotIn("releaseEligible", manifest)
        self.assertEqual(manifest["model"]["sha256"], sha256_artifact(self.compiled))
        self.assertTrue((self.output / "ServeAIEvaluationCandidateModel.mlmodelc").is_dir())
        self.assertTrue((self.output / "ServeAIEvaluationCandidateParity.json").is_file())
        self.assertTrue((self.output / "ServeAIEvaluationCandidate.json").is_file())

    def test_rejects_parity_for_different_compiled_model(self):
        self.parity["compiledModelSHA256"] = "f" * 64
        self._write_inputs()

        with self.assertRaisesRegex(EvaluationCandidateStagingError, "exact compiled candidate"):
            stage_candidate(
                compiled_model_path=self.compiled,
                research_model_path=self.model_path,
                parity_path=self.parity_path,
                output_directory=self.output,
            )
        self.assertFalse(self.output.exists())

    def test_rejects_candidate_bound_to_a_different_rubric(self):
        self.parity["rubricContract"]["version"] = "1.0.1"
        self._write_inputs()

        with self.assertRaisesRegex(EvaluationCandidateStagingError, "exact compiled candidate"):
            stage_candidate(
                compiled_model_path=self.compiled,
                research_model_path=self.model_path,
                parity_path=self.parity_path,
                output_directory=self.output,
            )

    def test_refuses_to_overwrite_existing_candidate(self):
        self.output.mkdir()

        with self.assertRaisesRegex(EvaluationCandidateStagingError, "refusing to overwrite"):
            stage_candidate(
                compiled_model_path=self.compiled,
                research_model_path=self.model_path,
                parity_path=self.parity_path,
                output_directory=self.output,
            )

    def test_unstage_removes_only_recognized_candidate_directory(self):
        stage_candidate(
            compiled_model_path=self.compiled,
            research_model_path=self.model_path,
            parity_path=self.parity_path,
            output_directory=self.output,
        )

        unstage_candidate(self.output)

        self.assertFalse(self.output.exists())

    def test_unstage_refuses_directory_with_unknown_content(self):
        stage_candidate(
            compiled_model_path=self.compiled,
            research_model_path=self.model_path,
            parity_path=self.parity_path,
            output_directory=self.output,
        )
        (self.output / "keep-me.txt").write_text("user data")

        with self.assertRaisesRegex(EvaluationCandidateUnstagingError, "unrecognized"):
            unstage_candidate(self.output)
        self.assertTrue(self.output.exists())

    def test_release_target_excludes_and_guards_unvalidated_models(self):
        project = (WORKSPACE / "ServeAI.xcodeproj/project.pbxproj").read_text()

        self.assertIn('"ServeAIEvaluationCandidate*",', project)
        self.assertIn("ServeAITennisPseudoCoach.mlmodel,", project)
        self.assertIn("Reject unvalidated model artifacts in Release", project)
        self.assertIn("/ServeAIEvaluationCandidate*", project)
        self.assertIn("/ServeAITennisPseudoCoach*", project)


if __name__ == "__main__":
    unittest.main()
