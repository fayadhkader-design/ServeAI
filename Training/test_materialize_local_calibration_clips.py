import tempfile
import unittest
from pathlib import Path

from materialize_local_calibration_clips import build_clip_plan, sha256


class MaterializeLocalCalibrationClipsTests(unittest.TestCase):
    def test_plan_rebases_phase_anchors_and_keeps_parent_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            raw = Path(temporary)
            original = raw / "serve.MOV"
            original.write_bytes(b"source")
            digest = sha256(original)
            phases = (
                "startingStance", "ballToss", "loading", "trophyPosition", "legDrive",
                "racketDrop", "upwardAcceleration", "contactPosition", "pronation", "followThrough",
            )
            review = {
                "participantPseudonym": "participant-local-001",
                "validation": {"status": "VALIDATED LOCAL CALIBRATION — not release ground truth"},
                "sources": [{
                    "filename": "serve.MOV",
                    "sourceVideoSHA256": digest,
                    "selectedCandidateID": "serve-A",
                    "phaseAnchors": {phase: 1.2 + index * 0.2 for index, phase in enumerate(phases)},
                    "techniqueRatings": {},
                    "topPriority": "tossPlacement",
                }],
            }
            manifest = {
                "sources": [{
                    "filename": "serve.MOV",
                    "sha256": digest,
                    "candidates": [{"id": "serve-A", "startTime": 1.0, "endTime": 4.0}],
                }],
            }

            plan = build_clip_plan(review, manifest, raw)[0]

            self.assertEqual(plan["originalSHA256"], digest)
            self.assertAlmostEqual(plan["rebasedPhaseAnchors"]["startingStance"], 0.2)
            self.assertAlmostEqual(plan["rebasedPhaseAnchors"]["followThrough"], 2.0)


if __name__ == "__main__":
    unittest.main()
