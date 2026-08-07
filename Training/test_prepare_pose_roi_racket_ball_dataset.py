import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import prepare_pose_roi_racket_ball_dataset as roi


class PoseROIRacketBallDatasetTests(unittest.TestCase):
    def test_pose_roi_is_square_bounded_and_shifted_upward(self):
        crop = roi.roi_from_pose({"rawRootX": .6, "rawRootY": .5, "rawScale": .1}, 1000, 2000)
        self.assertEqual(crop["width"], crop["height"])
        self.assertGreaterEqual(crop["x"], 0)
        self.assertGreaterEqual(crop["y"], 0)
        self.assertLessEqual(crop["x"] + crop["width"], 1000)
        self.assertLessEqual(crop["y"] + crop["height"], 2000)
        self.assertLess(crop["y"] + crop["height"] / 2, 1000)

    def test_point_transform_converts_full_frame_to_crop_coordinates(self):
        crop = {"x": 250, "y": 500, "width": 500, "height": 500}
        transformed = roi.transform_point({"status": "visible", "x": .5, "y": .375}, crop, 1000, 2000)
        self.assertAlmostEqual(transformed["x"], .5)
        self.assertAlmostEqual(transformed["y"], .5)
        self.assertTrue(roi.point_inside(transformed))

    def test_ball_target_is_a_context_region_not_a_tiny_silhouette(self):
        box = roi.ball_center_region_box({"ballCenter": {"status": "visible", "x": .5, "y": .5}}, 832, 832)
        self.assertGreaterEqual((box["xmax"] - box["xmin"]) * 832, 40)
        self.assertAlmostEqual((box["xmin"] + box["xmax"]) / 2, .5)

    def test_pose_lookup_requires_image_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "poses.jsonl"
            path.write_text(json.dumps({"frames": [{"rawRootX": .5, "rawRootY": .5, "rawScale": .1}]}) + "\n")
            with self.assertRaisesRegex(roi.ROIError, "imageFilename"):
                roi.pose_lookup(path)

    def test_split_uses_pose_median_only_when_direct_pose_is_missing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            (source / "images").mkdir(parents=True)
            for name in ("one.jpg", "two.jpg"):
                (source / "images" / name).write_bytes(name.encode())
            points = {
                "handleButt": {"status": "visible", "x": .5, "y": .5},
                "racketThroat": {"status": "visible", "x": .5, "y": .45},
                "hoopTop": {"status": "visible", "x": .5, "y": .35},
                "hoopLeft": {"status": "visible", "x": .48, "y": .38},
                "hoopRight": {"status": "visible", "x": .52, "y": .38},
                "ballCenter": {"status": "visible", "x": .55, "y": .33},
            }
            records = [{"sampleID": name[:-4], "localImage": f"images/{name}", "pixelWidth": 1000, "pixelHeight": 2000, "frameSHA256": name, "points": points} for name in ("one.jpg", "two.jpg")]
            (source / "keypoints.jsonl").write_text("".join(json.dumps(item) + "\n" for item in records))
            poses = root / "poses.jsonl"
            poses.write_text(json.dumps({"frames": [{"imageFilename": "one.jpg", "rawRootX": .5, "rawRootY": .5, "rawScale": .1}]}) + "\n")

            def fake_crop(_source, destination, _crop, _size):
                destination.write_bytes(b"crop")

            with mock.patch.object(roi, "extract_crop", side_effect=fake_crop):
                result = roi.materialize_split(source, poses, root / "output", 832)
            self.assertEqual(result["directPoseFrameCount"], 1)
            self.assertEqual(result["fallbackMedianFrameCount"], 1)
            self.assertEqual(result["visibleKeypointCoverage"], 1)


if __name__ == "__main__":
    unittest.main()
