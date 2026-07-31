import hashlib
import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent


class ObjectPerceptionBaselineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = json.loads((ROOT / "OBJECT_PERCEPTION_BASELINE.json").read_text())

    def test_candidate_stays_fail_closed_for_release(self):
        release = self.report["releaseInterpretation"]
        self.assertFalse(release["passesTargetDomainReleaseGate"])
        self.assertFalse(release["bundledInRelease"])
        self.assertFalse(release["canEstablishRacketHeadLowPoint"])
        self.assertFalse(release["canEstablishBallImpact"])
        self.assertFalse(release["canEstablishPronation"])

    def test_reported_metrics_do_not_satisfy_target_gate(self):
        gate = self.report["targetDomainReleaseGate"]
        results = self.report["results"]
        self.assertLess(results["tennisRacket"]["precision"], gate["minimumRacketPrecision"])
        self.assertLess(results["tennisRacket"]["recall"], gate["minimumRacketRecall"])
        self.assertLess(results["tennisBall"]["precision"], gate["minimumBallPrecisionDuringTossThroughContact"])
        self.assertLess(results["tennisBall"]["recall"], gate["minimumBallRecallDuringTossThroughContact"])

    def test_local_candidate_hash_matches_when_downloaded(self):
        model = ROOT / "data/YOLOv3Int8LUT.mlmodel"
        if not model.exists():
            self.skipTest("local research candidate is not downloaded")
        digest = hashlib.sha256(model.read_bytes()).hexdigest()
        self.assertEqual(digest, self.report["candidateModel"]["sha256"])

    def test_transfer_learning_experiment_cannot_replace_baseline(self):
        experiment = self.report["transferLearningExperiment"]
        baseline = self.report["results"]
        fixed = experiment["fixedProtocolResults"]
        self.assertFalse(experiment["releaseEligible"])
        self.assertFalse(experiment["bundledInRelease"])
        self.assertLess(
            fixed["tennisRacket"]["precision"],
            baseline["tennisRacket"]["precision"],
        )
        self.assertLess(
            fixed["tennisBall"]["recall"],
            baseline["tennisBall"]["recall"],
        )


if __name__ == "__main__":
    unittest.main()
