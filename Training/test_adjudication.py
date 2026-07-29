import unittest

from adjudicate_coach_labels import compile_ground_truth, validate_resolution
from prepare_coach_dataset import PHASES
from test_training_pipeline import package
from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING


TECHNIQUES = (
    "tossPlacement", "loadingSequence", "trophyAlignment",
    "legDriveTiming", "contactReach", "landingBalance",
)


def resolution(*, adjudicator="coach-c"):
    return {
        "schemaVersion": 3,
        "rubric": dict(CURRENT_RUBRIC_BINDING),
        "adjudicationID": "adjudication-1",
        "analysisID": "analysis-1",
        "sourceAnnotationIDs": ["annotation-coach-a", "annotation-coach-b"],
        "adjudicatorPseudonym": adjudicator,
        "createdAt": "2026-07-26T18:00:00Z",
        "collectionMetadata": {
            "dominantHand": "right",
            "environment": "outdoor",
            "lighting": "evenDaylight",
            "sourceDeviceCategory": "iPhone",
            "sourceDeviceModel": "iPhone 15 Pro",
            "subjectContrast": "typical",
            "recordingIssueTags": [],
            "videoWidth": 1920,
            "videoHeight": 1080,
            "nominalFrameRate": 60,
        },
        "isVideoUsable": True,
        "unusableReason": None,
        "phaseBoundaries": [
            {"phase": phase, "startTime": index * 0.1, "endTime": (index + 1) * 0.1, "isVisible": True}
            for index, phase in enumerate(PHASES)
        ],
        "techniqueRatings": [
            {"label": label, "rating": 4, "isVisible": True, "note": None}
            for label in TECHNIQUES
        ],
        "topPriority": "contactReach",
        "decisionNotes": "The adjudicator reviewed both labels against the video and selected each boundary explicitly.",
    }


class AdjudicationTests(unittest.TestCase):
    def setUp(self):
        self.annotations = [package(coach="coach-a"), package(coach="coach-b", priority="contactReach")]
        self.registry = {coach: {} for coach in ("coach-a", "coach-b", "coach-c")}

    def test_complete_independent_resolution_compiles_release_eligible_ground_truth(self):
        candidate = resolution()

        self.assertEqual(validate_resolution(candidate, self.annotations, self.registry), [])
        ground_truth = compile_ground_truth(candidate, self.annotations)
        self.assertTrue(ground_truth["groundTruthEligible"])
        self.assertFalse(ground_truth["modelReleaseEligible"])
        self.assertEqual(ground_truth["topPriority"], "contactReach")
        self.assertEqual(ground_truth["adjudicatorPseudonym"], "coach-c")
        self.assertEqual(ground_truth["cohorts"]["frameRate"], "60fps")
        self.assertEqual(ground_truth["rubric"], CURRENT_RUBRIC_BINDING)

    def test_tampered_rubric_is_rejected(self):
        candidate = resolution()
        candidate["rubric"]["version"] = "1.0.1"

        errors = validate_resolution(candidate, self.annotations, self.registry)

        self.assertTrue(any("rubric" in error for error in errors))

    def test_priority_must_be_lowest_visible_rating(self):
        candidate = resolution()
        candidate["techniqueRatings"][0]["rating"] = 2
        candidate["topPriority"] = "contactReach"

        errors = validate_resolution(candidate, self.annotations, self.registry)

        self.assertTrue(any("lowest visible" in error for error in errors))

    def test_source_coach_cannot_adjudicate_their_own_labels(self):
        errors = validate_resolution(resolution(adjudicator="coach-a"), self.annotations, self.registry)

        self.assertTrue(any("independent" in error for error in errors))

    def test_incomplete_resolution_is_rejected_instead_of_averaged(self):
        candidate = resolution()
        candidate["phaseBoundaries"] = candidate["phaseBoundaries"][:-1]
        candidate["techniqueRatings"] = []
        candidate["topPriority"] = None

        errors = validate_resolution(candidate, self.annotations, self.registry)

        self.assertTrue(any("ten serve phases" in error for error in errors))
        self.assertTrue(any("six technique" in error for error in errors))
        self.assertTrue(any("top priority" in error for error in errors))

    def test_duplicate_source_and_non_numeric_timing_are_rejected(self):
        candidate = resolution()
        candidate["sourceAnnotationIDs"] = ["annotation-coach-a", "annotation-coach-a"]
        candidate["phaseBoundaries"][2]["startTime"] = "invalid"

        errors = validate_resolution(candidate, self.annotations, self.registry)

        self.assertTrue(any("exactly once" in error for error in errors))
        self.assertTrue(any("timing must be numeric" in error for error in errors))

    def test_missing_collection_metadata_is_rejected(self):
        candidate = resolution()
        candidate.pop("collectionMetadata")

        errors = validate_resolution(candidate, self.annotations, self.registry)

        self.assertTrue(any("cohort metadata" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
