import tempfile
import unittest
from pathlib import Path

from build_pose_calibration_derivatives import build_derivative_plan, sha256


class PoseCalibrationDerivativeTests(unittest.TestCase):
    def manifest(self, clip: Path) -> dict:
        return {
            "purpose": "local-calibration-device-input",
            "participantPseudonym": "participant-local-001",
            "trainingEligible": False,
            "clips": [{
                "clipID": "serve-A",
                "filename": clip.name,
                "clipSHA256": sha256(clip),
                "videoMetadata": {"width": 1080, "height": 1920, "duration": 4.0},
                "humanReview": {"phaseAnchors": {"contactPosition": 2.6}},
            }],
        }

    def test_plan_binds_crop_to_verified_selected_clip(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            clip = directory / "serve-A.mp4"
            clip.write_bytes(b"selected-serve")
            crop = {"x": 216, "y": 320, "width": 648, "height": 1152}

            plan = build_derivative_plan(self.manifest(clip), directory, crop)[0]

            self.assertEqual(plan["sourceSHA256"], sha256(clip))
            self.assertEqual(plan["crop"], crop)

    def test_plan_rejects_crop_outside_source_frame(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            clip = directory / "serve-A.mp4"
            clip.write_bytes(b"selected-serve")
            crop = {"x": 500, "y": 320, "width": 648, "height": 1152}

            with self.assertRaisesRegex(ValueError, "crop leaves"):
                build_derivative_plan(self.manifest(clip), directory, crop)

    def test_plan_rejects_odd_h264_crop_values(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            clip = directory / "serve-A.mp4"
            clip.write_bytes(b"selected-serve")
            crop = {"x": 215, "y": 320, "width": 648, "height": 1152}

            with self.assertRaisesRegex(ValueError, "must be even"):
                build_derivative_plan(self.manifest(clip), directory, crop)


if __name__ == "__main__":
    unittest.main()
