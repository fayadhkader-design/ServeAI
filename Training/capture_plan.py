"""Frozen target-domain capture-plan contract and assignment validation."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Any


PLAN_PATH = Path(__file__).with_name("artifacts") / "target_capture_plan.json"
PLAN_IDENTIFIER = "serveai-target-domain-pilot-v1"
PLAN_VERSION = "1.0.0"
PLAN_SHA256 = "a1ee7cda18662aad442e39992ca6b161fa36fc2cd635a2a5f8b0a3a40bc6198a"
CURRENT_BINDING = {
    "identifier": PLAN_IDENTIFIER,
    "version": PLAN_VERSION,
    "sha256": PLAN_SHA256,
}


def load_verified_plan() -> dict[str, Any]:
    raw = PLAN_PATH.read_bytes()
    if hashlib.sha256(raw).hexdigest() != PLAN_SHA256:
        raise ValueError("capture plan file does not match its pinned SHA-256")
    plan = json.loads(raw)
    if plan.get("schemaVersion") != 1 or plan.get("planID") != PLAN_IDENTIFIER:
        raise ValueError("capture plan identity does not match the pinned contract")
    slots = plan.get("slots")
    if not isinstance(slots, list) or len(slots) != 300:
        raise ValueError("capture plan must contain exactly 300 slots")
    identifiers = [slot.get("slotID") for slot in slots if isinstance(slot, dict)]
    if len(identifiers) != 300 or len(set(identifiers)) != 300:
        raise ValueError("capture plan slot identifiers must be complete and unique")
    return plan


VERIFIED_PLAN = load_verified_plan()
SLOTS_BY_ID = {slot["slotID"]: slot for slot in VERIFIED_PLAN["slots"]}


def assignment_for_slot(slot_id: str) -> dict[str, Any]:
    slot = SLOTS_BY_ID[slot_id]
    return {
        "plan": dict(CURRENT_BINDING),
        "slotID": slot_id,
        "participantPseudonym": slot["participantPseudonym"],
    }


def validate_task_assignment(payload: object) -> tuple[dict[str, Any] | None, list[str]]:
    if not isinstance(payload, dict):
        return None, ["labeling task payload is missing"]
    assignment = payload.get("capturePlanAssignment")
    if not isinstance(assignment, dict):
        return None, ["capture-plan assignment is missing"]
    errors: list[str] = []
    if assignment.get("plan") != CURRENT_BINDING:
        errors.append("capture-plan binding is missing or does not match the frozen pilot plan")
    slot = SLOTS_BY_ID.get(assignment.get("slotID"))
    if slot is None:
        errors.append("capture-plan slot is unknown")
        return None, errors
    if assignment.get("participantPseudonym") != slot.get("participantPseudonym"):
        errors.append("capture-plan participant does not match the assigned slot")
    analysis = payload.get("analysis") or {}
    if analysis.get("cameraAngle") != slot.get("cameraAngle"):
        errors.append("task camera angle does not match the capture-plan slot")
    if analysis.get("skillLevel") != slot.get("skillLevel"):
        errors.append("task skill level does not match the capture-plan slot")
    video_metadata = analysis.get("videoMetadata") or {}
    observed_metadata = {
        "videoWidth": video_metadata.get("width"),
        "videoHeight": video_metadata.get("height"),
        "nominalFrameRate": video_metadata.get("nominalFrameRate"),
    }
    if resolution_cohort(observed_metadata) != slot.get("resolution"):
        errors.append("task observed resolution does not match the capture-plan slot")
    if frame_rate_cohort(observed_metadata) != slot.get("frameRate"):
        errors.append("task observed frame rate does not match the capture-plan slot")
    return slot, errors


def resolution_cohort(metadata: dict[str, Any]) -> str | None:
    width = metadata.get("videoWidth")
    height = metadata.get("videoHeight")
    if isinstance(width, bool) or isinstance(height, bool):
        return None
    if not isinstance(width, (int, float)) or not isinstance(height, (int, float)):
        return None
    longest = max(width, height)
    if longest >= 3_500:
        return "4k"
    if longest >= 1_750:
        return "1080p"
    if longest >= 1_100:
        return "720p"
    return "other"


def frame_rate_cohort(metadata: dict[str, Any]) -> str | None:
    rate = metadata.get("nominalFrameRate")
    if isinstance(rate, bool) or not isinstance(rate, (int, float)):
        return None
    if rate >= 90:
        return "120fps"
    if rate >= 45:
        return "60fps"
    if rate >= 24:
        return "30fps"
    return "other"


def validate_annotation_assignment(package: object) -> tuple[dict[str, Any] | None, list[str]]:
    if not isinstance(package, dict):
        return None, ["annotation is missing"]
    task = package.get("labelingTask")
    payload = task.get("payload") if isinstance(task, dict) else None
    slot, errors = validate_task_assignment(payload)
    if slot is None:
        return None, errors
    assignment = payload["capturePlanAssignment"]
    if package.get("participantPseudonym") != assignment.get("participantPseudonym"):
        errors.append("annotation participant does not match the signed capture-plan assignment")
    metadata = package.get("collectionMetadata")
    if not isinstance(metadata, dict):
        errors.append("annotation collection metadata is missing for its capture-plan slot")
        return slot, errors
    exact_fields = (
        "dominantHand", "environment", "lighting", "sourceDeviceCategory",
        "sourceDeviceModel", "subjectContrast",
    )
    for field in exact_fields:
        if metadata.get(field) != slot.get(field):
            errors.append(f"annotation {field} does not match the capture-plan slot")
    if sorted(metadata.get("recordingIssueTags") or []) != sorted(slot.get("recordingIssueTags") or []):
        errors.append("annotation recording issues do not match the capture-plan slot")
    if resolution_cohort(metadata) != slot.get("resolution"):
        errors.append("annotation resolution does not match the capture-plan slot")
    if frame_rate_cohort(metadata) != slot.get("frameRate"):
        errors.append("annotation frame rate does not match the capture-plan slot")
    return slot, errors


def validate_record_provenance(record: object) -> list[str]:
    if not isinstance(record, dict):
        return ["temporal record is missing"]
    provenance = record.get("capturePlanProvenance")
    if not isinstance(provenance, dict):
        return ["capture-plan provenance is missing"]
    errors: list[str] = []
    if not str(provenance.get("status", "")).startswith("PINNED"):
        errors.append("capture-plan provenance is not pinned")
    if provenance.get("plan") != CURRENT_BINDING:
        errors.append("capture-plan provenance does not match the frozen plan")
    slot = SLOTS_BY_ID.get(provenance.get("slotID"))
    if slot is None:
        errors.append("capture-plan provenance names an unknown slot")
        return errors
    if provenance.get("participantPseudonym") != slot.get("participantPseudonym"):
        errors.append("capture-plan provenance participant conflicts with the slot")
    if provenance.get("split") != slot.get("split"):
        errors.append("capture-plan provenance split conflicts with the slot")
    if record.get("participantPseudonym") != slot.get("participantPseudonym"):
        errors.append("temporal record participant conflicts with its capture slot")
    if record.get("split") != slot.get("split"):
        errors.append("temporal record split conflicts with its capture slot")
    if record.get("cameraAngle") != slot.get("cameraAngle"):
        errors.append("temporal record camera angle conflicts with its capture slot")
    if record.get("skillLevel") != slot.get("skillLevel"):
        errors.append("temporal record skill level conflicts with its capture slot")
    return errors
