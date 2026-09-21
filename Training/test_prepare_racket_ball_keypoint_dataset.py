import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import prepare_racket_ball_keypoint_dataset as dataset


class RacketBallKeypointDatasetTests(unittest.TestCase):
    def fixture(self, root: Path, source_names=("a.mov", "b.mov"), contact_intake=False):
        review = root / "review"
        (review / "frames").mkdir(parents=True)
        frames, samples = [], []
        for source_index, source in enumerate(source_names, 1):
            frame_path = review / "frames" / f"source-{source_index}.jpg"
            frame_path.write_bytes(f"image-{source_index}".encode())
            digest = hashlib.sha256(frame_path.read_bytes()).hexdigest()
            sample_id = f"source-{source_index}-contactPosition-1"
            samples.append({"id": sample_id, "sourceFilename": source, "sourceVideoSHA256": f"video-{source_index}", "frameSHA256": digest, "timestampSeconds": 1.0, "phaseHint": "contactPosition", "framePath": f"frames/{frame_path.name}"})
            frames.append({
                "sampleID": sample_id, "sourceFilename": source, "sourceVideoSHA256": f"video-{source_index}",
                "frameSHA256": digest, "timestampSeconds": 1.0, "phaseHint": "contactPosition", "reviewed": True,
                "points": {
                    "handleButt": {"status": "visible", "x": .5, "y": .6},
                    "racketThroat": {"status": "visible", "x": .5, "y": .5},
                    "hoopTop": {"status": "visible", "x": .5, "y": .3},
                    "hoopLeft": {"status": "visible", "x": .6, "y": .4},
                    "hoopRight": {"status": "visible", "x": .4, "y": .4},
                    "ballCenter": {"status": "visible", "x": .7, "y": .2},
                },
            })
        manifest = {"samples": samples}
        if contact_intake:
            manifest.update({
                "sourceMode": "contact-window-intake", "reviewID": "review-test-001",
                "participantPseudonym": "participant-test", "cameraAngle": "side",
                "dominantHand": "right", "skillLevel": "intermediate",
                "participantConsentReference": "consent-test-001", "mediaRightsBasis": "self-recorded",
                "mediaRightsReference": "rights-test-001",
            })
        (review / "manifest.json").write_text(json.dumps(manifest))
        labels = root / "labels.json"
        payload = {"schemaVersion": 1, "purpose": "human-reviewed-racket-ball-keypoint-pilot", "releaseEligible": False, "participantPseudonym": "participant-test", "cameraAngle": "side" if contact_intake else "rear", "frames": frames}
        if contact_intake:
            payload.update({key: manifest[key] for key in (
                "sourceMode", "reviewID", "dominantHand", "skillLevel",
                "participantConsentReference", "mediaRightsBasis", "mediaRightsReference"
            )})
        labels.write_text(json.dumps(payload))
        return labels, review

    def test_materializes_recording_separated_pilot_and_audits_swaps(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            labels, review = self.fixture(root)
            with mock.patch.object(dataset, "image_dimensions", return_value=(1000, 2000)):
                result = dataset.materialize(labels, review, root / "output")
            self.assertFalse(result["releaseEligible"])
            self.assertEqual(result["frameCounts"], {"adaptation": 1, "evaluation": 1})
            self.assertEqual(len(result["semanticCorrections"]), 2)
            keypoints = json.loads((root / "output/evaluation/keypoints.jsonl").read_text())
            self.assertLess(keypoints["points"]["hoopLeft"]["x"], keypoints["points"]["hoopRight"]["x"])
            annotations = json.loads((root / "output/evaluation/createml-annotations.json").read_text())
            self.assertEqual({item["label"] for item in annotations[0]["annotations"]}, {"tennis_ball", "tennis_racket"})

    def test_rejects_coordinate_outside_unit_interval(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            labels, review = self.fixture(root)
            payload = json.loads(labels.read_text())
            payload["frames"][0]["points"]["ballCenter"]["x"] = 1.1
            labels.write_text(json.dumps(payload))
            with self.assertRaisesRegex(dataset.PreparationError, "outside"):
                dataset.load_and_validate(labels, review)

    def test_rejects_frame_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            labels, review = self.fixture(root)
            (review / "frames/source-1.jpg").write_bytes(b"modified")
            with self.assertRaisesRegex(dataset.PreparationError, "frame bytes"):
                dataset.load_and_validate(labels, review)

    def test_not_visible_point_cannot_carry_coordinates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            labels, review = self.fixture(root)
            payload = json.loads(labels.read_text())
            payload["frames"][0]["points"]["ballCenter"] = {"status": "notVisible", "x": .5, "y": None}
            labels.write_text(json.dumps(payload))
            with self.assertRaisesRegex(dataset.PreparationError, "must not carry"):
                dataset.load_and_validate(labels, review)

    def test_one_clip_intake_stays_unassigned_and_non_release(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            labels, review = self.fixture(root, source_names=("one.mov",), contact_intake=True)
            with mock.patch.object(dataset, "image_dimensions", return_value=(1000, 2000)):
                result = dataset.materialize(labels, review, root / "output")
            self.assertEqual(result["frameCounts"], {"unassigned": 1})
            self.assertEqual(result["sourceSplit"], {"one.mov": "unassigned"})
            self.assertEqual(result["sourceMode"], "contact-window-intake")
            self.assertFalse(result["releaseEligible"])
            self.assertTrue((root / "output/unassigned/keypoints.jsonl").is_file())
            self.assertFalse((root / "output/adaptation").exists())
            self.assertIn("side camera", result["limitations"][0])

    def test_contact_intake_rejects_wrong_review_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            labels, review = self.fixture(root, source_names=("one.mov",), contact_intake=True)
            payload = json.loads(labels.read_text())
            payload["reviewID"] = "another-review"
            labels.write_text(json.dumps(payload))
            with self.assertRaisesRegex(dataset.PreparationError, "review ID"):
                dataset.load_and_validate(labels, review)

    def test_contact_intake_rejects_mismatched_rights_and_camera(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            labels, review = self.fixture(root, source_names=("one.mov",), contact_intake=True)
            payload = json.loads(labels.read_text())
            payload["mediaRightsReference"] = "different"
            labels.write_text(json.dumps(payload))
            with self.assertRaisesRegex(dataset.PreparationError, "mediaRightsReference"):
                dataset.load_and_validate(labels, review)
            payload["mediaRightsReference"] = "rights-test-001"
            payload["cameraAngle"] = "rear"
            labels.write_text(json.dumps(payload))
            with self.assertRaisesRegex(dataset.PreparationError, "cameraAngle"):
                dataset.load_and_validate(labels, review)


if __name__ == "__main__":
    unittest.main()
