import unittest

import audit_pose_evidence_stability as audit


class PoseEvidenceStabilityTests(unittest.TestCase):
    def test_audit_reports_coverage_without_claiming_accuracy(self):
        records = [self.record("thetis-p1"), self.record("thetis-p40")]

        report = audit.audit_records(records, "a" * 64)

        self.assertEqual(report["overall"]["sequenceCount"], 2)
        self.assertEqual(report["participantGroups"]["beginner"]["sequenceCount"], 1)
        self.assertEqual(report["participantGroups"]["expert"]["sequenceCount"], 1)
        self.assertEqual(report["overall"]["robustKneeEvidence"]["count"], 2)
        self.assertEqual(report["overall"]["consistentHittingArm"]["count"], 2)
        for field in (
            "robustTossEvent",
            "robustLoadingEvent",
            "robustWristDropEvent",
            "robustLikelyContactEvent",
            "allCoreBodyProxyEvents",
            "allRobustBodyProxyEvents",
        ):
            self.assertIn(field, report["overall"])
            self.assertGreaterEqual(report["overall"][field]["rate"], 0)
            self.assertLessEqual(report["overall"][field]["rate"], 1)
        self.assertGreater(
            report["overall"]["sequencesWithConfidenceBasedArmSwitches"]["count"],
            0,
        )
        self.assertFalse(report["releaseInterpretation"]["canEstablishTechniqueAccuracy"])
        self.assertFalse(report["releaseInterpretation"]["canTrainCommercialReleaseModel"])

    def test_percentile_interpolates(self):
        self.assertAlmostEqual(audit.percentile([51, 108, 110, 112, 114], 0.20), 96.6)

    def test_robust_extreme_rejects_one_frame_spike(self):
        samples = [
            {"index": index, "value": 0.4, "confidence": 0.9}
            for index in range(12)
        ]
        samples[6]["value"] = 1.8

        self.assertIsNone(audit.robust_extreme_anchor(samples, 0, 12, True, 0.2))

    def record(self, participant):
        frames = []
        for index in range(8):
            progress = index / 7
            left_confidence = 0.95 if index % 2 == 0 else 0.65
            right_confidence = 0.65 if index % 2 == 0 else 0.95
            left_height = 0.20 + max(0, 0.4 - progress) * 0.5
            right_height = -0.15 + progress * 0.85
            frames.append({
                "joints": [
                    self.joint("root", 0.50, 0.45),
                    self.joint("neck", 0.50, 0.70),
                    self.joint("leftShoulder", 0.42, 0.64),
                    self.joint("rightShoulder", 0.58, 0.64),
                    self.joint("leftElbow", 0.40, 0.68),
                    self.joint("rightElbow", 0.60, 0.62),
                    self.joint("leftWrist", 0.39, 0.64 + left_height, left_confidence),
                    self.joint("rightWrist", 0.63, 0.64 + right_height, right_confidence),
                    self.joint("leftHip", 0.46, 0.43),
                    self.joint("leftKnee", 0.46, 0.28),
                    self.joint("leftAnkle", 0.58, 0.18),
                    self.joint("rightHip", 0.54, 0.43),
                    self.joint("rightKnee", 0.54, 0.28),
                    self.joint("rightAnkle", 0.42, 0.18),
                ]
            })
        return {"participantPseudonym": participant, "frames": frames}

    @staticmethod
    def joint(name, x, y, confidence=0.9):
        return {
            "joint": name,
            "x": x,
            "y": y,
            "confidence": confidence,
            "isPresent": True,
        }


if __name__ == "__main__":
    unittest.main()
