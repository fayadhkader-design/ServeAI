import copy
import json
import tempfile
import unittest
from pathlib import Path

from assemble_temporal_dataset import assemble_records
from consent_auth import verify_annotation_consent
from prepare_coach_dataset import feature_evidence_digest, labeling_task_digest
from test_training_pipeline import attach_signed_labeling_task, package
from task_coordinator_auth import authorize_labeling_task
from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING


def prepared_index(directory: Path):
    first = package(coach="coach-a")
    second = package(coach="coach-b")
    paths = []
    for name, value in (("first.json", first), ("second.json", second)):
        path = directory / name
        path.write_text(json.dumps(value))
        paths.append(str(path))
    evidence = first["modelFeatureEvidence"]
    records = verified_consent_records()
    consent_evidence, errors = verify_annotation_consent(first, records)
    assert not errors
    return {
        "coachVerification": "ECDSA-P256 signatures checked against an admin-authorized coach registry",
        "consentVerification": "ECDSA-P256 consent receipts checked against a separately authorized consent registry",
        "portableTaskCoordinatorVerification": "HMAC-authorized registry matched each embedded task signer key",
        "consentLedgerVerification": {
            "consentLedgerSnapshotID": "snapshot-1",
            "authorityID": "privacy-admin",
            "issuedAt": "2026-07-26T12:00:00Z",
            "receiptCount": 1,
            "ledgerSHA256": "e" * 64,
        },
        "reviews": [{
            "analysisID": "analysis-1",
            "participantPseudonym": "player-a",
            "split": "train",
            "cameraAngle": "side",
            "skillLevel": "intermediate",
            "collectionMetadata": first["collectionMetadata"],
            "cohorts": {
                "cameraAngle": "side",
                "skillLevel": "intermediate",
                "dominantHand": "right",
                "environment": "outdoor",
                "lighting": "evenDaylight",
                "sourceDeviceCategory": "iPhone",
                "sourceDeviceModel": "iPhone 15 Pro",
                "subjectContrast": "typical",
                "resolution": "1080p",
                "frameRate": "60fps",
            },
            "featureEvidenceDigest": feature_evidence_digest(evidence),
            "sourceVideoSHA256": "a" * 64,
            "consentVerification": consent_evidence,
            "labelingTaskVerification": {"status": "LOCAL SAME-DEVICE LABELING — no portable task"},
            "annotationFiles": paths,
            "requiresAdjudication": False,
        }],
    }


def verified_consent_records():
    return {
        "76f75711-1126-4e9d-bac6-09333d55ee38": {
            "active": True,
            "receiptSHA256": "d" * 64,
            "receipt": {
                "consentReceiptID": "receipt-1",
                "consentRecordID": "76f75711-1126-4e9d-bac6-09333d55ee38",
                "participantPseudonym": "player-a",
                "authorityID": "privacy-admin",
                "decision": "granted",
                "occurredAt": "2026-07-26T12:00:00Z",
                "consentVersion": "2026-07",
                "notice": {"documentSHA256": "b" * 64},
                "coveredVideoSHA256": ["a" * 64],
            },
        }
    }


class TemporalAssemblyTests(unittest.TestCase):
    def test_exact_double_coach_labels_assemble_with_bound_features(self):
        with tempfile.TemporaryDirectory() as directory:
            index = prepared_index(Path(directory))

            records, errors = assemble_records([index], [], consent_records=verified_consent_records())

            self.assertEqual(errors, [])
            self.assertEqual(len(records), 1)
            self.assertEqual(records[0]["featureEvidence"]["sequence"]["schemaVersion"], 2)
            self.assertEqual(records[0]["labelProvenance"]["kind"], "exactDoubleCoachAgreement")
            self.assertEqual(records[0]["rubric"], CURRENT_RUBRIC_BINDING)

    def test_index_feature_digest_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            index = prepared_index(Path(directory))
            index["reviews"][0]["featureEvidenceDigest"] = "0" * 64

            records, errors = assemble_records([index], [], consent_records=verified_consent_records())

            self.assertEqual(records, [])
            self.assertTrue(any("digest" in error for error in errors))

    def test_unresolved_label_disagreement_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            index = prepared_index(Path(directory))
            index["reviews"][0]["requiresAdjudication"] = True

            records, errors = assemble_records([index], [], consent_records=verified_consent_records())

            self.assertEqual(records, [])
            self.assertTrue(any("unresolved" in error for error in errors))

    def test_adjudication_cannot_point_to_different_pose_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            index = prepared_index(Path(directory))
            index["reviews"][0]["requiresAdjudication"] = True
            ground_truth = {
                "rubric": dict(CURRENT_RUBRIC_BINDING),
                "analysisID": "analysis-1",
                "groundTruthID": "ground-truth-1",
                "groundTruthEligible": True,
                "sourceAnnotationIDs": ["annotation-coach-a", "annotation-coach-b"],
                "featureEvidenceDigest": "f" * 64,
                "sourceVideoSHA256": "a" * 64,
                "adjudicatorPseudonym": "coach-c",
                "cohorts": copy.deepcopy(index["reviews"][0]["cohorts"]),
                "isVideoUsable": True,
                "phaseBoundaries": [],
                "techniqueRatings": [],
                "topPriority": "legDriveTiming",
            }

            records, errors = assemble_records(
                [index], [ground_truth], consent_records=verified_consent_records()
            )

            self.assertEqual(records, [])
            self.assertTrue(any("same video and pose evidence" in error for error in errors))

    def test_portable_task_authorization_is_rechecked_and_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = attach_signed_labeling_task(package(coach="coach-a"))
            second = package(coach="coach-b")
            second["modelReport"] = copy.deepcopy(first["modelReport"])
            second["cameraAngle"] = first["cameraAngle"]
            second["skillLevel"] = first["skillLevel"]
            second["participantPseudonym"] = first["participantPseudonym"]
            second["collectionMetadata"] = copy.deepcopy(first["collectionMetadata"])
            second["modelFeatureEvidence"] = copy.deepcopy(first["modelFeatureEvidence"])
            second["labelingTask"] = copy.deepcopy(first["labelingTask"])
            paths = []
            for name, annotation in (("portable-a.json", first), ("portable-b.json", second)):
                path = root / name
                path.write_text(json.dumps(annotation))
                paths.append(str(path))
            task = first["labelingTask"]
            signature = task["signature"]
            registry = {
                "coordinator-a": {
                    "coordinatorID": "coordinator-a",
                    "status": "active",
                    "organization": "Test study",
                    "role": "Collection coordinator",
                    "authorizedFrom": "2026-07-26T00:00:00Z",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "signerKeyID": signature["signerKeyID"],
                    "publicKeyX963": signature["publicKeyX963"],
                }
            }
            index = prepared_index(root)
            review = index["reviews"][0]
            review["participantPseudonym"] = first["participantPseudonym"]
            review["annotationFiles"] = paths
            review["labelingTaskVerification"] = {
                "status": "AUTHORIZED — ECDSA signature and coordinator registry key verified",
                "taskSHA256": labeling_task_digest(task),
                "taskID": task["payload"]["taskID"],
                "taskCreatedAt": task["payload"]["createdAt"],
                "coordinatorPseudonym": task["payload"]["coordinatorPseudonym"],
                "signerKeyID": signature["signerKeyID"],
                "authorization": authorize_labeling_task(task, registry),
            }

            consent_records = verified_consent_records()
            consent_records["76f75711-1126-4e9d-bac6-09333d55ee38"]["receipt"]["participantPseudonym"] = first["participantPseudonym"]
            records, errors = assemble_records(
                [index],
                [],
                consent_records=consent_records,
                task_coordinator_registry=registry,
            )

            self.assertEqual(errors, [])
            self.assertEqual(records[0]["portableTaskProvenance"]["taskID"], task["payload"]["taskID"])


if __name__ == "__main__":
    unittest.main()
