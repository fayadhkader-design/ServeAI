import base64
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from prepare_coach_dataset import TECHNIQUES, compare, stable_split, validate
from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import SLOTS_BY_ID, assignment_for_slot


def package(*, coach="coach-a", participant="player-a", priority="legDriveTiming"):
    joints = [
        "nose", "neck", "root", "leftShoulder", "rightShoulder", "leftElbow", "rightElbow",
        "leftWrist", "rightWrist", "leftHip", "rightHip", "leftKnee", "rightKnee", "leftAnkle", "rightAnkle",
    ]
    return {
        "schemaVersion": 8,
        "rubric": dict(CURRENT_RUBRIC_BINDING),
        "annotationID": f"annotation-{coach}",
        "analysisID": "analysis-1",
        "participantPseudonym": participant,
        "annotatorPseudonym": coach,
        "cameraAngle": "side",
        "skillLevel": "intermediate",
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
        "modelFeatureEvidence": {
            "sequence": {
                "schemaVersion": 2,
                "duration": 3.0,
                "cameraAngle": "side",
                "frames": [
                    {
                        "timestamp": index * 0.1,
                        "bodyConfidence": 0.9,
                        "joints": [
                            {"joint": joint, "x": 0.01, "y": 0.02, "confidence": 0.9, "isPresent": True}
                            for joint in joints
                        ],
                    }
                    for index in range(30)
                ],
            },
            "provenance": {
                "schemaVersion": 1,
                "encoderIdentifier": "serveai.pose-sequence",
                "encoderVersion": "2.0.0",
                "poseDetectorIdentifier": "AppleVision.VNDetectHumanBodyPoseRequest",
                "poseDetectorVersion": "revision-1",
                "videoSHA256": "a" * 64,
                "generatedAt": "2026-07-26T12:00:00Z",
                "requestedSamplesPerSecond": 15,
                "smoothingWindow": 5,
                "sampledFrameCount": 30,
                "detectedFrameCount": 30,
            },
        },
        "isVideoUsable": True,
        "phaseBoundaries": [
            {"phase": phase, "startTime": index * 0.1, "endTime": (index + 1) * 0.1, "isVisible": True}
            for index, phase in enumerate((
                "startingStance", "ballToss", "loading", "trophyPosition", "legDrive",
                "racketDrop", "upwardAcceleration", "contactPosition", "pronation", "followThrough",
            ))
        ],
        "techniqueRatings": [
            {"label": label, "rating": 4, "isVisible": True, "note": None}
            for label in sorted(TECHNIQUES)
        ],
        "topPriority": priority,
        "consent": {
            "consentVersion": "2026-07",
            "allowsResearchAndModelTraining": True,
            "recordedAt": "2026-07-26T12:00:00Z",
            "consentRecordID": "76f75711-1126-4e9d-bac6-09333d55ee38",
            "decisionHistory": [{
                "id": "a492debc-f607-4d38-b5a4-c6f26189c50e",
                "kind": "granted",
                "occurredAt": "2026-07-26T12:00:00Z",
                "consentVersion": "2026-07",
            }],
        },
    }


def attach_signed_labeling_task(candidate, slot_id="slot-001", source="vision"):
    slot = SLOTS_BY_ID[slot_id]
    candidate["participantPseudonym"] = slot["participantPseudonym"]
    candidate["cameraAngle"] = slot["cameraAngle"]
    candidate["skillLevel"] = slot["skillLevel"]
    candidate["modelFeatureEvidence"]["sequence"]["cameraAngle"] = slot["cameraAngle"]
    candidate["collectionMetadata"].update({
        "dominantHand": slot["dominantHand"],
        "environment": slot["environment"],
        "lighting": slot["lighting"],
        "sourceDeviceCategory": slot["sourceDeviceCategory"],
        "sourceDeviceModel": slot["sourceDeviceModel"],
        "subjectContrast": slot["subjectContrast"],
        "recordingIssueTags": list(slot["recordingIssueTags"]),
        "videoWidth": 3840 if slot["resolution"] == "4k" else 1920 if slot["resolution"] == "1080p" else 1280,
        "videoHeight": 2160 if slot["resolution"] == "4k" else 1080 if slot["resolution"] == "1080p" else 720,
        "nominalFrameRate": int(slot["frameRate"].removesuffix("fps")),
    })
    candidate["modelReport"] = {
        "source": source,
        "overallScore": 0 if source == "researchCapture" else 78,
        "phaseScores": [],
        "confidence": {
            "level": "high",
            "visibilityScore": 0.9,
            "poseDetectionQuality": 0.9,
            "cameraSuitability": 0.9,
            "usableFrameCount": 30,
            "missingAreas": [],
        },
    }
    analysis = {
        "id": candidate["analysisID"],
        "createdAt": "2026-07-26T12:00:00Z",
        "overallScore": candidate["modelReport"]["overallScore"],
        "skillLevel": candidate["skillLevel"],
        "cameraAngle": candidate["cameraAngle"],
        "source": candidate["modelReport"]["source"],
        "phaseScores": candidate["modelReport"]["phaseScores"],
        "technicalMetrics": [],
        "insights": [],
        "drills": [],
        "limitations": [],
        "confidence": candidate["modelReport"]["confidence"],
        "videoMetadata": {
            "duration": 3,
            "width": candidate["collectionMetadata"]["videoWidth"],
            "height": candidate["collectionMetadata"]["videoHeight"],
            "nominalFrameRate": candidate["collectionMetadata"]["nominalFrameRate"],
            "usableFrames": 30,
            "sampledFrames": 30,
        },
        "modelFeatureEvidence": candidate["modelFeatureEvidence"],
    }
    payload = {
        "schemaVersion": 2,
        "taskID": "5fc148d3-7406-426a-bf7a-02f3e27d4073",
        "analysisID": candidate["analysisID"],
        "createdAt": "2026-07-26T12:00:00Z",
        "coordinatorPseudonym": "coordinator-a",
        "sourceVideoFilename": "serve.mov",
        "sourceVideoSHA256": candidate["modelFeatureEvidence"]["provenance"]["videoSHA256"],
        "capturePlanAssignment": assignment_for_slot(slot_id),
        "analysis": analysis,
    }
    content = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    with tempfile.TemporaryDirectory(prefix="serveai-task-test-") as temp:
        directory = Path(temp)
        private_key = directory / "private.pem"
        public_der = directory / "public.der"
        content_path = directory / "payload.json"
        signature_path = directory / "payload.sig"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(private_key)],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(private_key), "-pubout", "-outform", "DER", "-out", str(public_der)],
            check=True,
            capture_output=True,
        )
        content_path.write_bytes(content)
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(private_key), "-out", str(signature_path), str(content_path)],
            check=True,
            capture_output=True,
        )
        public_bytes = public_der.read_bytes()[-65:]
        signature_bytes = signature_path.read_bytes()
    candidate["labelingTask"] = {
        "schemaVersion": 1,
        "payload": payload,
        "signature": {
            "algorithm": "ECDSA-P256-SHA256",
            "signerKeyID": hashlib.sha256(public_bytes).hexdigest(),
            "publicKeyX963": base64.b64encode(public_bytes).decode(),
            "signedContentSHA256": hashlib.sha256(content).hexdigest(),
            "signatureDER": base64.b64encode(signature_bytes).decode(),
        },
    }
    return candidate


class TrainingPipelineTests(unittest.TestCase):
    def test_split_is_stable_for_every_clip_from_player(self):
        self.assertEqual(stable_split("player-17"), stable_split("player-17"))
        self.assertIn(stable_split("player-17"), {"train", "validation", "test"})

    def test_valid_complete_package_passes(self):
        self.assertEqual(validate(package(), __import__("pathlib").Path("sample.json")), [])

    def test_research_capture_is_accepted_only_as_signed_unusable_failure_sample(self):
        candidate = package()
        candidate["isVideoUsable"] = False
        candidate["unusableReason"] = "Recording failed the ServeAI input-quality gate"
        candidate["phaseBoundaries"] = []
        candidate["techniqueRatings"] = []
        candidate["topPriority"] = None
        attach_signed_labeling_task(candidate, slot_id="slot-001", source="researchCapture")

        self.assertEqual(validate(candidate, Path("research.json")), [])

    def test_research_capture_cannot_be_promoted_to_coaching_ground_truth(self):
        candidate = package()
        attach_signed_labeling_task(candidate, slot_id="slot-001", source="researchCapture")

        messages = validate(candidate, Path("research.json"))

        self.assertTrue(any("must remain labeled unusable" in message for message in messages))
        self.assertTrue(any("cannot provide technique" in message for message in messages))

    def test_missing_or_tampered_rubric_is_rejected(self):
        candidate = package()
        candidate["rubric"]["sha256"] = "0" * 64

        messages = validate(candidate, __import__("pathlib").Path("sample.json"))

        self.assertTrue(any("rubric" in message for message in messages))

    def test_priority_must_be_lowest_visible_rating(self):
        candidate = package(priority="contactReach")
        next(
            item for item in candidate["techniqueRatings"] if item["label"] == "tossPlacement"
        )["rating"] = 2

        messages = validate(candidate, __import__("pathlib").Path("sample.json"))

        self.assertTrue(any("lowest visible" in message for message in messages))

    def test_missing_consent_and_participant_are_rejected(self):
        candidate = package(participant=None)
        candidate["consent"]["allowsResearchAndModelTraining"] = False
        messages = validate(candidate, __import__("pathlib").Path("sample.json"))
        self.assertTrue(any("consent" in message for message in messages))
        self.assertTrue(any("participant" in message for message in messages))

    def test_coach_priority_disagreement_requires_adjudication(self):
        result = compare(package(coach="coach-a"), package(coach="coach-b", priority="contactReach"))
        self.assertFalse(result["topPriorityAgreement"])
        self.assertTrue(result["requiresAdjudication"])

    def test_technique_rating_disagreement_requires_adjudication(self):
        first = package(coach="coach-a")
        second = package(coach="coach-b")
        second["techniqueRatings"][0]["rating"] = 2

        result = compare(first, second)

        self.assertFalse(result["techniqueRatingsAgreement"])
        self.assertTrue(result["requiresAdjudication"])

    def test_any_timing_disagreement_requires_explicit_adjudication(self):
        first = package(coach="coach-a")
        second = package(coach="coach-b")
        second["phaseBoundaries"][0]["startTime"] += 0.001

        result = compare(first, second)

        self.assertTrue(result["requiresAdjudication"])

    def test_revoked_consent_is_rejected_even_with_prior_grant(self):
        candidate = package()
        candidate["consent"]["allowsResearchAndModelTraining"] = False
        candidate["consent"]["revokedAt"] = "2026-07-27T12:00:00Z"
        candidate["consent"]["decisionHistory"].append({
            "id": "b492debc-f607-4d38-b5a4-c6f26189c50e",
            "kind": "revoked",
            "occurredAt": "2026-07-27T12:00:00Z",
            "consentVersion": "2026-07",
        })

        messages = validate(candidate, __import__("pathlib").Path("sample.json"))

        self.assertTrue(any("revoked" in message for message in messages))

    def test_malformed_timing_and_ratings_are_rejected_without_crashing(self):
        candidate = package()
        candidate["phaseBoundaries"][0]["startTime"] = "not-a-number"
        candidate["techniqueRatings"][0]["rating"] = 9

        messages = validate(candidate, __import__("pathlib").Path("sample.json"))

        self.assertTrue(any("timing must be numeric" in message for message in messages))
        self.assertTrue(any("1–5 rating" in message for message in messages))

    def test_missing_or_tampered_model_features_are_rejected(self):
        candidate = package()
        candidate["modelFeatureEvidence"]["sequence"]["frames"][0]["joints"].pop()
        candidate["modelFeatureEvidence"]["provenance"]["videoSHA256"] = "not-a-hash"

        messages = validate(candidate, __import__("pathlib").Path("sample.json"))

        self.assertTrue(any("every body joint" in message for message in messages))
        self.assertTrue(any("SHA-256" in message for message in messages))

    def test_signed_cross_device_labeling_task_is_verified(self):
        candidate = attach_signed_labeling_task(package())

        self.assertEqual(validate(candidate, __import__("pathlib").Path("sample.json")), [])

    def test_tampered_cross_device_labeling_task_is_rejected(self):
        candidate = attach_signed_labeling_task(package())
        candidate["labelingTask"]["payload"]["coordinatorPseudonym"] = "tampered-coordinator"

        messages = validate(candidate, __import__("pathlib").Path("sample.json"))

        self.assertTrue(any("signed-content" in message or "signature" in message for message in messages))


if __name__ == "__main__":
    unittest.main()
