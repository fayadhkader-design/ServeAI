import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent
ARTIFACTS = ROOT / "artifacts"
WORKSPACE = ROOT.parent


class THETISResearchPipelineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manifest = json.loads((ARTIFACTS / "thetis_source_manifest.json").read_text())
        cls.dataset = json.loads((ARTIFACTS / "thetis_pseudo_coach_dataset.json").read_text())
        cls.evaluation = json.loads((ARTIFACTS / "thetis_pseudo_coach_evaluation.json").read_text())
        cls.parity = json.loads((ARTIFACTS / "thetis_coreml_parity.json").read_text())

    def test_source_manifest_is_complete_and_research_only(self):
        self.assertTrue(self.manifest["complete"])
        self.assertEqual(self.manifest["downloadedClipCount"], 495)
        self.assertFalse(self.manifest["productionUseAllowed"])
        self.assertEqual(len(self.manifest["repositoryCommit"]), 40)

    def test_dataset_is_player_isolated_and_large_enough_for_research(self):
        records = self.dataset["records"]
        self.assertEqual(len(records), 455)
        self.assertEqual(self.dataset["splitCounts"], {"train": 295, "validation": 67, "test": 93})
        self.assertEqual(self.dataset["playerCounts"], {"train": 36, "validation": 8, "test": 11})
        player_splits = {}
        for record in records:
            player_splits.setdefault(record["participantPseudonym"], set()).add(record["split"])
        self.assertEqual(len(player_splits), 55)
        self.assertTrue(all(len(splits) == 1 for splits in player_splits.values()))
        self.assertEqual(len({record["sourceVideoSHA256"] for record in records}), len(records))

    def test_unobservable_labels_remain_unavailable(self):
        self.assertEqual(self.dataset["phaseVisibilityCounts"]["racketDrop"], 0)
        self.assertEqual(self.dataset["phaseVisibilityCounts"]["pronation"], 0)
        self.assertEqual(self.dataset["techniqueRatingCounts"]["tossConsistency"], 0)
        self.assertEqual(self.dataset["techniqueRatingCounts"]["trophyAlignment"], 0)
        self.assertFalse(self.dataset["groundTruthEligible"])
        self.assertFalse(self.dataset["modelReleaseEligible"])

    def test_rejections_include_duplicate_and_unobservable_events(self):
        rejections = self.dataset["segmentation"]["rejections"]
        self.assertEqual(len(rejections), 40)
        self.assertEqual(sum("exact duplicate" in item["reason"] for item in rejections), 1)
        self.assertEqual(sum("no overhead-arm event" in item["reason"] for item in rejections), 39)

    def test_evaluation_preserves_failed_release_gates(self):
        test = self.evaluation["testPseudoTeacherAgreement"]
        self.assertEqual(test["clipCount"], 93)
        self.assertEqual(test["playerCount"], 11)
        self.assertLessEqual(test["boundaryMeanAbsoluteErrorSeconds"], 0.12)
        self.assertGreater(test["techniqueRatingMeanAbsoluteError"], 0.60)
        self.assertLess(test["priorityAgreement"], 0.75)
        self.assertFalse(self.evaluation["coachingAccuracyMeasured"])
        self.assertFalse(self.evaluation["releaseEligible"])

    def test_coreml_parity_passes_without_promoting_model(self):
        self.assertTrue(self.parity["passes"])
        self.assertLessEqual(self.parity["maximumAbsoluteError"], self.parity["tolerance"])
        self.assertFalse(self.parity["releaseEligible"])
        model_path = WORKSPACE / "ServeAI/Resources/Models/ServeAITennisPseudoCoach.mlmodel"
        self.assertTrue(model_path.exists())
        self.assertGreater(model_path.stat().st_size, 100_000)

    def test_review_contains_all_records_and_accessible_controls(self):
        report = (WORKSPACE / "outputs/serveai-multiplayer-model-audit.html").read_text()
        self.assertIn("Unique serves", report)
        self.assertIn("<strong>455</strong>", report)
        self.assertIn('aria-label="Search clips"', report)
        self.assertIn('aria-label="Close review"', report)
        self.assertIn("Experimental only.", report)


if __name__ == "__main__":
    unittest.main()
