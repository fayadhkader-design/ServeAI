import json
import tempfile
import unittest
from pathlib import Path

from generate_pseudo_coach_dataset import (
    DEFAULT_ANNOTATIONS,
    DEFAULT_SOURCES,
    PHASES,
    TECHNIQUES,
    build_dataset,
)
from train_pseudo_coach_baseline import fit_candidate, load_pseudo_dataset
from train_temporal_baseline import evaluate


class PseudoCoachPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dataset = build_dataset(DEFAULT_ANNOTATIONS, DEFAULT_SOURCES)

    def test_every_detected_complete_clip_is_labeled_with_explicit_limitations(self):
        records = self.dataset["records"]

        self.assertEqual(len(records), 31)
        self.assertEqual(self.dataset["segmentation"]["detectedOverheadAnchorCount"], 33)
        self.assertFalse(self.dataset["groundTruthEligible"])
        self.assertFalse(self.dataset["modelReleaseEligible"])
        for record in records:
            phases = {item["phase"]: item for item in record["labels"]["phaseBoundaries"]}
            techniques = {item["label"]: item for item in record["labels"]["techniqueRatings"]}
            self.assertEqual(set(phases), set(PHASES))
            self.assertEqual(set(techniques), set(TECHNIQUES))
            self.assertFalse(phases["racketDrop"]["isVisible"])
            self.assertFalse(phases["pronation"]["isVisible"])
            self.assertIsNone(phases["racketDrop"]["startTime"])
            self.assertFalse(techniques["tossPlacement"]["isVisible"])
            self.assertFalse(techniques["trophyAlignment"]["isVisible"])
            self.assertIsNone(techniques["trophyAlignment"]["rating"])
            self.assertFalse(record["pseudoLabelProvenance"]["coachVerified"])

    def test_contact_proxy_follows_trophy_proxy(self):
        for record in self.dataset["records"]:
            events = record["pseudoLabelProvenance"]["events"]
            self.assertGreaterEqual(
                events["overheadContactProxyFrame"],
                events["overheadTrophyProxyFrame"],
            )
            self.assertIn("not verified ball-racket impact", events["observableWarning"])

    def test_dataset_generation_is_deterministic(self):
        repeated = build_dataset(DEFAULT_ANNOTATIONS, DEFAULT_SOURCES)

        self.assertEqual(repeated["datasetDigest"], self.dataset["datasetDigest"])
        self.assertEqual(repeated["records"], self.dataset["records"])

    def test_loader_rejects_false_release_claim(self):
        candidate = json.loads(json.dumps(self.dataset))
        candidate["modelReleaseEligible"] = True
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "dataset.json"
            path.write_text(json.dumps(candidate))

            with self.assertRaisesRegex(ValueError, "eligibility"):
                load_pseudo_dataset(path)

    def test_research_model_trains_but_evaluation_remains_same_athlete(self):
        trained = fit_candidate(self.dataset["records"], l2=1.0)
        test = evaluate(trained, "test")

        self.assertEqual(test["clipCount"], 6)
        self.assertEqual(test["playerCount"], 1)
        self.assertIsNotNone(test["techniqueRatingMeanAbsoluteError"])


if __name__ == "__main__":
    unittest.main()
