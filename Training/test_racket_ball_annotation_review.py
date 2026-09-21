import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import build_racket_ball_annotation_review as review


class RacketBallAnnotationReviewTests(unittest.TestCase):
    def fixture(self):
        return {
            "participantPseudonym": "participant-test-001",
            "cameraAngle": "rear",
            "dominantHand": "right",
            "skillLevel": "intermediate",
            "sources": [{
                "filename": "serve.mov",
                "sourceVideoSHA256": "digest",
                "phaseAnchors": {
                    "racketDrop": 3.0,
                    "upwardAcceleration": 3.2,
                    "contactPosition": 3.4,
                    "pronation": 3.6,
                },
            }],
        }

    def contact_fixture(self):
        return {
            "schemaVersion": 1,
            "purpose": review.CONTACT_INTAKE_PURPOSE,
            "participantPseudonym": "participant-test-002",
            "cameraAngle": "side",
            "dominantHand": "left",
            "skillLevel": "intermediate",
            "participantConsentReference": "consent-test-002",
            "mediaRightsBasis": "self-recorded",
            "mediaRightsReference": "rights-test-002",
            "sources": [{
                "filename": "serve.mov",
                "sourceVideoSHA256": hashlib.sha256(b"video").hexdigest(),
                "contactSeconds": 3.0,
            }],
        }

    def test_contact_intake_samples_window_without_claiming_phase_truth(self):
        fixture = self.contact_fixture()
        review.validate_contact_intake(fixture)
        samples = review.planned_samples(fixture)
        self.assertEqual(len(samples), 15)
        self.assertEqual({item["phaseHint"] for item in samples}, {"contactWindow"})
        self.assertEqual(samples[0]["timestampSeconds"], 2.58)
        self.assertEqual(samples[-1]["timestampSeconds"], 3.42)

    def test_contact_intake_rejects_missing_rights_and_path_traversal(self):
        fixture = self.contact_fixture()
        del fixture["mediaRightsReference"]
        with self.assertRaisesRegex(review.BuildError, "mediaRightsReference"):
            review.validate_contact_intake(fixture)
        fixture = self.contact_fixture()
        fixture["sources"][0]["filename"] = "../private.mov"
        with self.assertRaisesRegex(review.BuildError, "plain filename"):
            review.validate_contact_intake(fixture)

    def test_contact_intake_checks_video_bounds_and_writes_isolated_review(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            output = directory / "output"
            (directory / "serve.mov").write_bytes(b"video")
            fixture = self.contact_fixture()
            fixture["sources"][0]["sourceVideoSHA256"] = fixture["sources"][0]["sourceVideoSHA256"].upper()

            def fake_extract(_video, _timestamp, path):
                path.write_bytes(f"frame-{path.name}".encode())

            with mock.patch.object(review.shutil, "which", return_value="ffmpeg"), mock.patch.object(
                review, "video_duration", return_value=4.0
            ), mock.patch.object(review, "extract_frame", side_effect=fake_extract):
                manifest = review.materialize(fixture, directory, output)
                self.assertEqual(manifest["sourceMode"], "contact-window-intake")
                self.assertEqual(len(manifest["samples"]), 15)
                self.assertEqual(len(manifest["reviewID"]), 64)
                with self.assertRaisesRegex(review.BuildError, "refusing to overwrite"):
                    review.materialize(fixture, directory, output)
            with mock.patch.object(review.shutil, "which", return_value="ffmpeg"), mock.patch.object(
                review, "video_duration", return_value=3.2
            ):
                with self.assertRaisesRegex(review.BuildError, "too close to the end"):
                    review.materialize(fixture, directory, directory / "new-output")

    def test_plans_fifteen_critical_frames_per_source(self):
        samples = review.planned_samples(self.fixture())
        self.assertEqual(len(samples), 15)
        self.assertEqual(samples[0]["phaseHint"], "racketDrop")
        self.assertAlmostEqual(samples[0]["timestampSeconds"], 2.88)
        self.assertAlmostEqual(samples[-1]["timestampSeconds"], 3.72)

    def test_missing_required_phase_fails_closed(self):
        fixture = self.fixture()
        del fixture["sources"][0]["phaseAnchors"]["pronation"]
        with self.assertRaisesRegex(review.BuildError, "missing pronation"):
            review.planned_samples(fixture)

    def test_source_verification_rejects_hash_mismatch(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "serve.mov").write_bytes(b"video")
            with self.assertRaisesRegex(review.BuildError, "hash mismatch"):
                review.verify_sources(self.fixture(), directory)

    def test_manifest_binds_every_extracted_frame(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            output = directory / "output"
            (directory / "serve.mov").write_bytes(b"video")
            fixture = self.fixture()
            fixture["sources"][0]["sourceVideoSHA256"] = hashlib.sha256(b"video").hexdigest()

            def fake_extract(_video, _timestamp, path):
                path.write_bytes(f"frame-{path.name}".encode())

            with mock.patch.object(review.shutil, "which", return_value="ffmpeg"), mock.patch.object(
                review, "extract_frame", side_effect=fake_extract
            ):
                manifest = review.materialize(fixture, directory, output)

            self.assertFalse(manifest["releaseEligible"])
            self.assertEqual(len(manifest["samples"]), 15)
            self.assertTrue(all(len(item["frameSHA256"]) == 64 for item in manifest["samples"]))
            page = review.build_html(manifest)
            self.assertIn("normalized-top-left-origin", page)
            self.assertIn("Bottom of the grip", page)
            self.assertIn("where the handle splits into the V", page)
            self.assertIn("as it appears on your screen", page)
            self.assertIn("Can't see this point", page)


if __name__ == "__main__":
    unittest.main()
