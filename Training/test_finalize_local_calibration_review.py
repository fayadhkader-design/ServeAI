import copy
import unittest

from finalize_local_calibration_review import validate_and_normalize


class FinalizeLocalCalibrationReviewTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {
            "participantPseudonym": "participant-local-001",
            "cameraAngle": "rear",
            "sources": [{
                "filename": "serve.MOV",
                "sha256": "a" * 64,
                "candidates": [{"id": "serve-A", "startTime": 1.0, "endTime": 4.0}],
            }],
        }
        phases = (
            "startingStance", "ballToss", "loading", "trophyPosition", "legDrive",
            "racketDrop", "upwardAcceleration", "contactPosition", "pronation", "followThrough",
        )
        techniques = (
            "tossPlacement", "loadingSequence", "trophyAlignment",
            "legDriveTiming", "contactReach", "landingBalance",
        )
        self.review = {
            "schemaVersion": 1,
            "purpose": "human-reviewed-local-calibration",
            "createdAt": "2026-07-27T18:28:27Z",
            "participantPseudonym": "participant-local-001",
            "dominantHand": "right",
            "skillLevel": "intermediate",
            "cameraAngle": "rear",
            "sources": [{
                "filename": "serve.MOV",
                "sourceVideoSHA256": "a" * 64,
                "selectedCandidateID": "serve-A",
                "phaseAnchors": {phase: 1.1 + index * 0.2 for index, phase in enumerate(phases)},
                "techniqueRatings": {
                    label: {"isVisible": True, "rating": "3" if index else "2"}
                    for index, label in enumerate(techniques)
                },
                "topPriority": "tossPlacement",
                "reviewed": True,
            }],
        }

    def test_numeric_strings_are_normalized_and_review_stays_blocked(self):
        normalized = validate_and_normalize(self.review, self.manifest)

        self.assertEqual(
            normalized["sources"][0]["techniqueRatings"]["tossPlacement"]["rating"],
            2,
        )
        self.assertFalse(normalized["validation"]["trainingEligible"])
        self.assertIn("rubric", normalized)

    def test_priority_must_be_lowest_visible_rating(self):
        review = copy.deepcopy(self.review)
        review["sources"][0]["topPriority"] = "loadingSequence"

        with self.assertRaisesRegex(ValueError, "lowest-rated"):
            validate_and_normalize(review, self.manifest)


if __name__ == "__main__":
    unittest.main()
