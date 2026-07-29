import copy
import unittest

from capture_plan import (
    CURRENT_BINDING,
    SLOTS_BY_ID,
    assignment_for_slot,
    validate_annotation_assignment,
    validate_task_assignment,
)
from test_training_pipeline import attach_signed_labeling_task, package


class CapturePlanContractTests(unittest.TestCase):
    def test_frozen_plan_has_expected_player_isolation(self):
        self.assertEqual(len(SLOTS_BY_ID), 300)
        self.assertEqual(SLOTS_BY_ID["slot-001"]["participantPseudonym"], "participant-001")
        self.assertEqual(SLOTS_BY_ID["slot-006"]["participantPseudonym"], "participant-002")
        self.assertEqual(assignment_for_slot("slot-001")["plan"], CURRENT_BINDING)

    def test_signed_task_and_annotation_match_frozen_slot(self):
        candidate = attach_signed_labeling_task(package())

        slot, task_errors = validate_task_assignment(candidate["labelingTask"]["payload"])
        _, annotation_errors = validate_annotation_assignment(candidate)

        self.assertEqual(slot["slotID"], "slot-001")
        self.assertEqual(task_errors, [])
        self.assertEqual(annotation_errors, [])

    def test_participant_or_cohort_substitution_is_rejected(self):
        candidate = attach_signed_labeling_task(package())
        changed_participant = copy.deepcopy(candidate)
        changed_participant["participantPseudonym"] = "participant-002"
        changed_metadata = copy.deepcopy(candidate)
        changed_metadata["collectionMetadata"]["lighting"] = "harshSun"

        self.assertTrue(any(
            "participant" in error
            for error in validate_annotation_assignment(changed_participant)[1]
        ))
        self.assertTrue(any(
            "lighting" in error
            for error in validate_annotation_assignment(changed_metadata)[1]
        ))


if __name__ == "__main__":
    unittest.main()
