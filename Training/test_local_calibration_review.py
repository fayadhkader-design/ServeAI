import copy
import json
import tempfile
import unittest
from pathlib import Path

from build_local_calibration_review import build_html


class LocalCalibrationReviewTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            "schemaVersion": 1,
            "purpose": "local-calibration-only",
            "participantPseudonym": "participant-local-001",
            "consentStatus": "pending-signed-training-consent",
            "sources": [{
                "filename": "owner-serve.MOV",
                "sha256": "a" * 64,
                "duration": 6.0,
                "width": 1920,
                "height": 1080,
                "nominalFrameRate": 60.0,
                "workingDerivative": "owner-serve.mp4",
                "qualityAssessment": {
                    "strengths": ["full body visible"],
                    "limitations": ["contains two serves"],
                },
                "candidates": [{
                    "id": "owner-serve-A",
                    "label": "First serve",
                    "startTime": 1.0,
                    "endTime": 4.0,
                    "contactEstimate": 2.8,
                }],
            }],
        }

    def test_review_is_source_bound_and_cannot_claim_consent(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "review.html"
            markup = build_html(copy.deepcopy(self.manifest), output)

        self.assertIn("a" * 64, markup)
        self.assertIn("Local calibration only", markup)
        self.assertIn("pending-signed-training-consent", markup)
        self.assertIn("pending-iPhone-extraction", markup)
        self.assertIn("Download reviewed JSON", markup)
        self.assertIn("loadingSequence", markup)
        self.assertIn("landingBalance", markup)
        self.assertNotIn("followThroughBalance", markup)

    def test_embedded_seed_retains_one_participant_and_one_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "review.html"
            markup = build_html(copy.deepcopy(self.manifest), output)
        seed = markup.split('<script id="seed" type="application/json">', 1)[1].split("</script>", 1)[0]
        payload = json.loads(seed)

        self.assertEqual(payload["manifest"]["participantPseudonym"], "participant-local-001")
        self.assertEqual(len(payload["manifest"]["sources"]), 1)
        self.assertEqual(payload["manifest"]["sources"][0]["sha256"], "a" * 64)


if __name__ == "__main__":
    unittest.main()
