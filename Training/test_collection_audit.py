import unittest

from audit_collection import audit_collection
from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING


SKILLS = ("beginner", "intermediate", "advanced", "competitive")
LIGHTING = ("evenDaylight", "harshSun", "indoorBright", "lowLight")
CONTRAST = ("typical", "low", "high")
RESOLUTIONS = ("720p", "1080p", "4k")
FRAME_RATES = ("30fps", "60fps", "120fps")
ISSUES = ("poorFraming", "occlusion", "lowLight", "multiplePeople", "motionBlur")
MODELS = ("iPhone 12", "iPhone 13", "iPhone 14", "iPhone 15 Pro")


def balanced_index():
    reviews = []
    participant_number = 0
    analysis_number = 0
    for split, participants in (("train", 36), ("validation", 12), ("test", 12)):
        for _ in range(participants):
            participant = f"participant-{participant_number + 1:03d}"
            participant_number += 1
            for _ in range(5):
                index = analysis_number
                analysis_number += 1
                resolution = RESOLUTIONS[index % len(RESOLUTIONS)]
                frame_rate = FRAME_RATES[index % len(FRAME_RATES)]
                dimensions = {"720p": (1280, 720), "1080p": (1920, 1080), "4k": (3840, 2160)}[resolution]
                issue_tags = [ISSUES[index % len(ISSUES)]] if index % 4 == 0 else []
                cohorts = {
                    "cameraAngle": "side" if index % 2 == 0 else "rear",
                    "skillLevel": SKILLS[index % len(SKILLS)],
                    "dominantHand": "left" if index % 5 == 0 else "right",
                    "environment": "outdoor" if index % 2 == 0 else "indoor",
                    "lighting": LIGHTING[index % len(LIGHTING)],
                    "sourceDeviceCategory": "iPhone",
                    "sourceDeviceModel": MODELS[index % len(MODELS)],
                    "subjectContrast": CONTRAST[index % len(CONTRAST)],
                    "resolution": resolution,
                    "frameRate": frame_rate,
                }
                reviews.append({
                    "analysisID": f"analysis-{index:04d}",
                    "participantPseudonym": participant,
                    "split": split,
                    "capturePlanVerification": {
                        "status": "PINNED — signed task matches frozen capture plan",
                        "plan": dict(CURRENT_CAPTURE_PLAN_BINDING),
                        "slotID": f"slot-{index + 1:03d}",
                        "participantPseudonym": participant,
                        "split": split,
                    },
                    "cohorts": cohorts,
                    "collectionMetadata": {
                        "sourceDeviceCategory": "iPhone",
                        "sourceDeviceModel": cohorts["sourceDeviceModel"],
                        "recordingIssueTags": issue_tags,
                        "videoWidth": dimensions[0],
                        "videoHeight": dimensions[1],
                        "nominalFrameRate": {"30fps": 30, "60fps": 60, "120fps": 120}[frame_rate],
                    },
                    "featureEvidenceDigest": f"{index + 10_000:064x}",
                    "sourceVideoSHA256": f"{index + 20_000:064x}",
                    "consentVerification": {
                        "consentRecordID": f"consent-{index:04d}",
                        "consentReceiptID": f"receipt-{index:04d}",
                        "authorityID": "privacy-admin",
                        "receiptSHA256": f"{index + 30_000:064x}",
                        "sourceVideoSHA256": f"{index + 20_000:064x}",
                    },
                    "requiresAdjudication": False,
                })
    return {
        "coachVerification": "ECDSA-P256 signatures checked against an admin-authorized coach registry",
        "consentVerification": "ECDSA-P256 consent receipts checked against a separately authorized consent registry",
        "portableTaskCoordinatorVerification": "HMAC-authorized registry matched each embedded task signer key",
        "consentLedgerVerification": {
            "consentLedgerSnapshotID": "snapshot-1",
            "authorityID": "privacy-admin",
            "issuedAt": "2026-07-26T12:00:00Z",
            "receiptCount": len(reviews),
            "ledgerSHA256": "f" * 64,
        },
        "reviews": reviews,
    }


class CollectionAuditTests(unittest.TestCase):
    def test_balanced_300_clip_collection_passes_collection_gate_only(self):
        report = audit_collection([balanced_index()])

        self.assertTrue(report["collectionReady"])
        self.assertFalse(report["modelReleaseEligible"])
        self.assertEqual(report["analysisCount"], 300)
        self.assertEqual(report["testParticipantCount"], 12)

    def test_missing_left_handed_examples_fails(self):
        candidate = balanced_index()
        for review in candidate["reviews"]:
            review["cohorts"]["dominantHand"] = "right"

        report = audit_collection([candidate])

        self.assertFalse(report["collectionReady"])
        self.assertTrue(any(item["gate"] == "overall dominantHand=left" for item in report["deficits"]))

    def test_player_leakage_fails_even_when_counts_pass(self):
        candidate = balanced_index()
        candidate["reviews"][-1]["participantPseudonym"] = candidate["reviews"][0]["participantPseudonym"]

        report = audit_collection([candidate])

        self.assertFalse(report["collectionReady"])
        self.assertTrue(report["playerLeakage"])

    def test_unresolved_disagreement_requires_signed_adjudication(self):
        candidate = balanced_index()
        candidate["reviews"][0]["requiresAdjudication"] = True

        report = audit_collection([candidate])

        self.assertFalse(report["collectionReady"])
        self.assertEqual(report["unresolvedAnalysisIDs"], ["analysis-0000"])

    def test_duplicate_source_video_cannot_inflate_collection_counts(self):
        candidate = balanced_index()
        candidate["reviews"][1]["sourceVideoSHA256"] = candidate["reviews"][0]["sourceVideoSHA256"]

        report = audit_collection([candidate])

        self.assertFalse(report["collectionReady"])
        self.assertTrue(report["duplicateSourceVideos"])

    def test_duplicate_capture_slot_cannot_inflate_collection_counts(self):
        candidate = balanced_index()
        candidate["reviews"][1]["capturePlanVerification"]["slotID"] = "slot-001"

        report = audit_collection([candidate])

        self.assertFalse(report["collectionReady"])
        self.assertTrue(report["duplicateCaptureSlots"])

    def test_missing_portable_task_coordinator_verification_fails(self):
        candidate = balanced_index()
        candidate.pop("portableTaskCoordinatorVerification")

        report = audit_collection([candidate])

        self.assertFalse(report["collectionReady"])
        self.assertTrue(any(
            item["gate"] == "verified portable-task coordinator indices"
            for item in report["deficits"]
        ))


if __name__ == "__main__":
    unittest.main()
