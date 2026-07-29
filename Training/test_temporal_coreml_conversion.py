import json
import os
import tempfile
import unittest
from pathlib import Path

import numpy as np

from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING
import convert_temporal_model_to_coreml as conversion
import evaluate_release_candidate as release_evaluation
from sign_validated_model_release import sha256_artifact
from test_temporal_baseline import record
from train_temporal_baseline import JOINTS, PHASES, RESAMPLED_STEPS, TECHNIQUES


class ExpectedPredictor:
    def __init__(self, model):
        self.model = model

    def predict(self, inputs):
        return conversion.expected_outputs(self.model, np.asarray(inputs["features"], dtype=np.float64))


class TemporalCoreMLConversionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="serveai-coreml-test-")
        self.root = Path(self.temporary.name)
        self.records = [
            record(analysis="train-0", video_hash=f"{9001:064x}", slot_id="slot-001"),
            record(analysis="validation-0", video_hash=f"{9002:064x}", slot_id="slot-181"),
        ]
        for player in range(12):
            for serve in range(5):
                index = player * 5 + serve
                self.records.append(record(
                    analysis=f"test-{index}",
                    video_hash=f"{index + 1:064x}",
                    slot_id=f"slot-{241 + index:03d}",
                ))
        digest = conversion.canonical_records_digest(self.records)
        self.dataset = {
            "schemaVersion": 3,
            "trainingEligible": True,
            "modelReleaseEligible": False,
            "datasetDigest": digest,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "records": self.records,
        }
        for item in self.records:
            item["rubric"] = dict(CURRENT_RUBRIC_BINDING)
        digest = conversion.canonical_records_digest(self.records)
        self.dataset["datasetDigest"] = digest
        heads = {}
        for head, size in conversion.OUTPUT_DIMENSIONS.items():
            weights = np.zeros((conversion.INPUT_DIMENSION, size), dtype=np.float64)
            for output_index in range(size):
                weights[output_index, output_index] = 0.01 * (output_index + 1)
            heads[head] = {
                "weights": weights.tolist(),
                "intercept": np.linspace(0.01, 0.01 * size, size).tolist(),
            }
        self.model = {
            "schemaVersion": 1,
            "modelIdentifier": "serveai.synthetic-coach-temporal",
            "modelVersion": "1.0.0-test",
            "featureSchemaVersion": 2,
            "resampledSteps": RESAMPLED_STEPS,
            "jointOrder": list(JOINTS),
            "phaseOrder": list(PHASES),
            "techniqueOrder": list(TECHNIQUES),
            "normalizationMean": [0.0] * conversion.INPUT_DIMENSION,
            "normalizationScale": [1.0] * conversion.INPUT_DIMENSION,
            "heads": heads,
            "trainingDatasetDigest": digest,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "releaseEligible": False,
        }
        self.model_path = self.root / "model.json"
        self.dataset_path = self.root / "dataset.json"
        self.model_path.write_text(json.dumps(self.model))
        self.dataset_path.write_text(json.dumps(self.dataset))

    def tearDown(self):
        self.temporary.cleanup()

    def test_validates_exact_native_input_and_output_contract(self):
        records = conversion.validate_inputs(self.model, self.dataset)

        self.assertEqual(len(records), 62)
        self.assertEqual(conversion.OUTPUT_DIMENSIONS["priority"], 6)

    def test_dataset_substitution_is_rejected(self):
        self.dataset["records"][0]["participantPseudonym"] = "substituted-player"
        self.dataset["datasetDigest"] = conversion.canonical_records_digest(self.dataset["records"])

        with self.assertRaisesRegex(conversion.TemporalCoreMLConversionError, "same frozen records"):
            conversion.validate_inputs(self.model, self.dataset)

    def test_wrong_priority_head_shape_is_rejected(self):
        self.model["heads"]["priority"]["intercept"].pop()

        with self.assertRaisesRegex(conversion.TemporalCoreMLConversionError, "shape"):
            conversion.validate_inputs(self.model, self.dataset)

    def test_parity_report_covers_every_held_out_clip_and_binds_compiled_hash(self):
        records = conversion.validate_inputs(self.model, self.dataset)
        compiled = self.root / "Synthetic.mlmodelc"
        compiled.mkdir()
        (compiled / "model.bin").write_bytes(b"compiled candidate")

        report = conversion.build_parity_report(
            ExpectedPredictor(self.model), self.model, records, compiled
        )

        self.assertTrue(report["passes"])
        self.assertEqual(report["schemaVersion"], 2)
        self.assertEqual(report["sampleCount"], 60)
        self.assertEqual(report["compiledModelSHA256"], sha256_artifact(compiled))
        self.assertEqual(report["rubricContract"], CURRENT_RUBRIC_BINDING)
        self.assertEqual(report["capturePlanContract"], CURRENT_CAPTURE_PLAN_BINDING)
        self.assertLessEqual(report["maximumAbsoluteError"], conversion.PARITY_TOLERANCE)
        validated = release_evaluation.validate_parity(
            report,
            (self.model["modelIdentifier"], self.model["modelVersion"]),
            sha256_artifact(compiled),
        )
        self.assertTrue(validated["passes"])

    def test_parity_report_fails_closed_below_sixty_samples(self):
        records = conversion.validate_inputs(self.model, self.dataset)
        compiled = self.root / "Synthetic.mlmodelc"
        compiled.mkdir()
        (compiled / "model.bin").write_bytes(b"compiled candidate")
        fewer = [item for item in records if item["split"] != "test"] + [
            item for item in records if item["split"] == "test"
        ][:59]

        report = conversion.build_parity_report(
            ExpectedPredictor(self.model), self.model, fewer, compiled
        )

        self.assertFalse(report["passes"])
        self.assertEqual(report["sampleCount"], 59)

    def test_tampered_rubric_is_rejected_before_conversion(self):
        self.model["rubricContract"]["sha256"] = "0" * 64

        with self.assertRaisesRegex(conversion.TemporalCoreMLConversionError, "coach rubric"):
            conversion.validate_inputs(self.model, self.dataset)

    @unittest.skipUnless(
        os.environ.get("SERVEAI_RUN_COREML_INTEGRATION") == "1",
        "set SERVEAI_RUN_COREML_INTEGRATION=1 under the pinned Python 3.12 runtime",
    )
    def test_apple_compiler_and_compiled_runtime_match_frozen_model(self):
        compiled = self.root / "SyntheticValidated.mlmodelc"

        report = conversion.convert_and_evaluate(
            model_path=self.model_path,
            dataset_path=self.dataset_path,
            compiled_output=compiled,
        )

        self.assertTrue(compiled.is_dir())
        self.assertTrue(report["passes"])
        self.assertEqual(report["compiledModelSHA256"], sha256_artifact(compiled))
        self.assertLessEqual(report["maximumAbsoluteError"], conversion.PARITY_TOLERANCE)


if __name__ == "__main__":
    unittest.main()
