import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import numpy as np

from test_training_pipeline import package
from train_temporal_baseline import (
    app_priority_predictions,
    evaluate,
    fit_ridge,
    load_dataset,
    record_vector,
    train,
    validate_player_isolation,
    verify_temporal_dataset_consent,
    verify_temporal_task_coordinators,
)
from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING, SLOTS_BY_ID


def record(*, analysis="analysis-1", participant=None, split=None, video_hash="a" * 64, slot_id="slot-001"):
    annotation = package()
    slot = SLOTS_BY_ID[slot_id]
    participant = participant or slot["participantPseudonym"]
    split = split or slot["split"]
    return {
        "analysisID": analysis,
        "participantPseudonym": participant,
        "split": split,
        "cameraAngle": slot["cameraAngle"],
        "skillLevel": slot["skillLevel"],
        "cohorts": {
            "cameraAngle": slot["cameraAngle"],
            "skillLevel": slot["skillLevel"],
            "dominantHand": "right",
            "lighting": "evenDaylight",
            "resolution": "1080p",
            "frameRate": "60fps",
        },
        "sourceVideoSHA256": video_hash,
        "rubric": dict(CURRENT_RUBRIC_BINDING),
        "capturePlanProvenance": {
            "status": "PINNED — signed task matches frozen capture plan",
            "plan": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "slotID": slot_id,
            "participantPseudonym": slot["participantPseudonym"],
            "split": slot["split"],
        },
        "consentProvenance": {
            "consentRecordID": "consent-record-1",
            "consentReceiptID": "receipt-1",
        },
        "portableTaskProvenance": {"status": "LOCAL SAME-DEVICE LABELING — no portable task"},
        "featureEvidence": annotation["modelFeatureEvidence"],
        "labels": {
            "isVideoUsable": annotation["isVideoUsable"],
            "unusableReason": annotation.get("unusableReason"),
            "phaseBoundaries": annotation["phaseBoundaries"],
            "techniqueRatings": annotation["techniqueRatings"],
            "topPriority": annotation["topPriority"],
        },
    }


class TemporalBaselineTests(unittest.TestCase):
    def test_priority_evaluation_matches_native_visibility_and_support_contract(self):
        scores = np.asarray([
            [0.99, 0.10, 0.98, 0.20, 0.80, 0.30],
            [0.99, 0.90, 0.98, 0.80, 0.70, 0.60],
        ])
        visibility = np.asarray([
            [1, 1, 1, 1, 1, 1],
            [1, 0, 1, 0, 0, 0],
        ])

        selected = app_priority_predictions(scores, visibility)

        self.assertEqual(selected.tolist(), [0, 0])

    def test_dataset_record_tampering_is_rejected_before_training(self):
        records = [record()]
        dataset = {
            "schemaVersion": 3,
            "trainingEligible": True,
            "modelReleaseEligible": False,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "records": records,
            "datasetDigest": hashlib.sha256(
                json.dumps(records, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest(),
        }
        dataset["records"][0]["labels"]["topPriority"] = "contactReach"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "dataset.json"
            path.write_text(json.dumps(dataset))

            with self.assertRaisesRegex(ValueError, "digest"):
                load_dataset(path)

    def test_feature_vector_is_fixed_and_finite(self):
        vector = record_vector(record())

        self.assertEqual(vector.shape, (3 + 24 * (1 + 15 * 4),))
        self.assertTrue(np.all(np.isfinite(vector)))

    def test_capture_plan_substitution_is_rejected_before_training(self):
        records = [record()]
        records[0]["capturePlanProvenance"]["slotID"] = "slot-006"
        dataset = {
            "schemaVersion": 3,
            "trainingEligible": True,
            "modelReleaseEligible": False,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "records": records,
            "datasetDigest": hashlib.sha256(
                json.dumps(records, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest(),
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "dataset.json"
            path.write_text(json.dumps(dataset))
            with self.assertRaisesRegex(ValueError, "capture-plan provenance"):
                load_dataset(path)

    def test_player_leakage_is_rejected_before_training(self):
        records = [
            record(analysis="a", participant="same", split="train", video_hash="a" * 64),
            record(analysis="b", participant="same", split="test", video_hash="b" * 64),
            record(analysis="c", participant="other", split="validation", video_hash="c" * 64),
        ]

        errors = validate_player_isolation(records)

        self.assertTrue(any("cross data splits" in error for error in errors))

    def test_ridge_head_learns_a_simple_relation(self):
        x = np.asarray([[-1.0], [0.0], [1.0]])
        y = np.asarray([[0.0], [1.0], [2.0]])

        weights, intercept = fit_ridge(x, y, l2=0.001)
        prediction = x @ weights + intercept

        self.assertTrue(np.allclose(prediction, y, atol=0.01))

    def test_multitask_training_runs_across_player_isolated_splits(self):
        records = []
        counter = 0
        for split, player in (("train", "train-player"), ("validation", "validation-player"), ("test", "test-player")):
            for _ in range(2):
                records.append(record(
                    analysis=f"analysis-{counter}",
                    participant=player,
                    split=split,
                    video_hash=f"{counter + 1:064x}",
                ))
                counter += 1

        trained = train(records)
        metrics = evaluate(trained, "test")

        self.assertEqual(metrics["clipCount"], 2)
        self.assertEqual(trained["splitCounts"], {"train": 2, "validation": 2, "test": 2})

    def test_training_time_consent_rejects_post_assembly_revocation(self):
        candidate = record()
        consent_records = {
            "consent-record-1": {
                "active": False,
                "receiptSHA256": "d" * 64,
                "receipt": {
                    "consentReceiptID": "receipt-2",
                    "authorityID": "privacy-admin",
                    "participantPseudonym": candidate["participantPseudonym"],
                    "occurredAt": "2026-07-27T12:00:00Z",
                    "coveredVideoSHA256": ["a" * 64],
                },
            }
        }

        evidence, errors = verify_temporal_dataset_consent([candidate], consent_records)

        self.assertEqual(evidence, [])
        self.assertTrue(any("revoked after dataset assembly" in error for error in errors))

    def test_training_time_consent_accepts_current_video_bound_grant(self):
        candidate = record()
        consent_records = {
            "consent-record-1": {
                "active": True,
                "receiptSHA256": "d" * 64,
                "receipt": {
                    "consentReceiptID": "receipt-1",
                    "authorityID": "privacy-admin",
                    "participantPseudonym": candidate["participantPseudonym"],
                    "occurredAt": "2026-07-26T12:00:00Z",
                    "coveredVideoSHA256": ["a" * 64],
                },
            }
        }

        evidence, errors = verify_temporal_dataset_consent([candidate], consent_records)

        self.assertEqual(errors, [])
        self.assertEqual(evidence[0]["consentReceiptID"], "receipt-1")

    def test_training_accepts_local_same_device_task_provenance_without_coordinator(self):
        evidence, errors = verify_temporal_task_coordinators([record()], {})

        self.assertEqual(errors, [])
        self.assertEqual(evidence[0]["status"], "LOCAL SAME-DEVICE LABELING")

    def test_training_rejects_portable_task_after_coordinator_key_substitution(self):
        candidate = record()
        candidate["portableTaskProvenance"] = {
            "status": "AUTHORIZED by signed task coordinator registry",
            "taskID": "task-1",
            "taskSHA256": "f" * 64,
            "taskCreatedAt": "2026-07-26T12:00:00Z",
            "coordinatorPseudonym": "coordinator-1",
            "signerKeyID": "original-key",
        }
        current_registry = {
            "coordinator-1": {
                "signerKeyID": "substituted-key",
                "authorizedFrom": "2026-07-01T00:00:00Z",
                "expiresAt": "2027-07-01T00:00:00Z",
            }
        }

        evidence, errors = verify_temporal_task_coordinators([candidate], current_registry)

        self.assertEqual(evidence, [])
        self.assertTrue(any("current coordinator key differs" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
