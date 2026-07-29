#!/usr/bin/env python3
"""Fail-closed task and annotation ingestion for the ServeAI research portal."""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[1]
TRAINING_ROOT = PROJECT_ROOT / "Training"
if str(TRAINING_ROOT) not in sys.path:
    sys.path.insert(0, str(TRAINING_ROOT))

from coach_auth import (  # noqa: E402
    CoachAuthorizationError,
    load_verified_registry,
    require_registry_secret,
    verify_artifact_signature,
)
from adjudicate_coach_labels import compile_ground_truth, validate_resolution  # noqa: E402
from capture_plan import validate_annotation_assignment, validate_task_assignment  # noqa: E402
from prepare_coach_dataset import compare, validate  # noqa: E402
from task_coordinator_auth import (  # noqa: E402
    TaskCoordinatorAuthorizationError,
    authorize_labeling_task,
    load_verified_task_coordinator_registry,
    require_task_coordinator_registry_secret,
    verify_native_task_signature,
)


MAX_TASK_BYTES = 5 * 1024 * 1024
MAX_ANNOTATION_BYTES = 20 * 1024 * 1024
MAX_VIDEO_BYTES = 500 * 1024 * 1024
VIDEO_EXTENSIONS = {".mov", ".mp4", ".m4v"}


class WorkflowError(ValueError):
    pass


@dataclass(frozen=True)
class RegistryConfiguration:
    task_registry_path: Path | None
    coach_registry_path: Path | None

    def status(self) -> dict[str, bool]:
        return {
            "taskRegistryPath": bool(self.task_registry_path and self.task_registry_path.is_file()),
            "taskRegistrySecret": len(os.environ.get("SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET", "")) >= 32,
            "coachRegistryPath": bool(self.coach_registry_path and self.coach_registry_path.is_file()),
            "coachRegistrySecret": len(os.environ.get("SERVEAI_COACH_REGISTRY_SECRET", "")) >= 32,
        }

    @property
    def ready(self) -> bool:
        return all(self.status().values())

    def task_coordinators(self) -> dict[str, dict]:
        if not self.task_registry_path:
            raise WorkflowError("task import is locked until a signed coordinator registry is configured")
        try:
            return load_verified_task_coordinator_registry(
                self.task_registry_path, require_task_coordinator_registry_secret()
            )
        except TaskCoordinatorAuthorizationError as error:
            raise WorkflowError(str(error)) from error

    def coaches(self) -> dict[str, dict]:
        if not self.coach_registry_path:
            raise WorkflowError("annotation upload is locked until a signed coach registry is configured")
        try:
            return load_verified_registry(self.coach_registry_path, require_registry_secret())
        except CoachAuthorizationError as error:
            raise WorkflowError(str(error)) from error


def _load_json(data: bytes, label: str, maximum: int) -> dict:
    if len(data) > maximum:
        raise WorkflowError(f"{label} exceeds the {maximum // (1024 * 1024)} MB limit")
    try:
        value = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise WorkflowError(f"{label} is not valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise WorkflowError(f"{label} must contain one JSON object")
    return value


def _uuid_text(value: object, label: str) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as error:
        raise WorkflowError(f"{label} must be a UUID") from error


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def inspect_video(filename: str, data: bytes) -> str:
    suffix = Path(filename).suffix.lower()
    if suffix not in VIDEO_EXTENSIONS:
        raise WorkflowError("video must use .mov, .mp4, or .m4v")
    if not data or len(data) > MAX_VIDEO_BYTES:
        raise WorkflowError("video is empty or exceeds the 500 MB pilot limit")
    # ISO base media files contain an ftyp box at offset 4. MOV and MP4 share it.
    if len(data) < 12 or data[4:8] != b"ftyp":
        raise WorkflowError("video bytes are not a recognized MOV/MP4 container")
    return "video/quicktime" if suffix == ".mov" else "video/mp4"


def verify_task_upload(
    task_data: bytes,
    video_filename: str,
    video_data: bytes,
    registries: RegistryConfiguration,
) -> tuple[dict, dict]:
    task = _load_json(task_data, "task JSON", MAX_TASK_BYTES)
    try:
        signer = verify_native_task_signature(task)
        authorization = authorize_labeling_task(task, registries.task_coordinators())
    except TaskCoordinatorAuthorizationError as error:
        raise WorkflowError(str(error)) from error
    payload = task.get("payload") or {}
    if payload.get("schemaVersion") != 2:
        raise WorkflowError("portal collection requires a schema-2 task payload with a signed capture-plan assignment")
    analysis = payload.get("analysis") or {}
    if analysis.get("source") == "simulated":
        raise WorkflowError("simulated analyses cannot enter the annotation queue")
    task_id = _uuid_text(payload.get("taskID"), "task ID")
    analysis_id = _uuid_text(payload.get("analysisID"), "analysis ID")
    expected_hash = str(payload.get("sourceVideoSHA256") or "")
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        raise WorkflowError("task source-video fingerprint is invalid")
    video_mime = inspect_video(video_filename, video_data)
    actual_hash = hashlib.sha256(video_data).hexdigest()
    if not hmac.compare_digest(expected_hash, actual_hash):
        raise WorkflowError("selected video does not match the task's signed SHA-256 fingerprint")
    if analysis.get("id") != payload.get("analysisID"):
        raise WorkflowError("task analysis snapshot has a conflicting analysis ID")
    camera_angle = analysis.get("cameraAngle")
    skill_level = analysis.get("skillLevel")
    if camera_angle not in {"side", "rear"} or skill_level not in {
        "beginner", "intermediate", "advanced", "competitive",
    }:
        raise WorkflowError("task camera angle or skill level is invalid")
    capture_slot, capture_errors = validate_task_assignment(payload)
    if capture_errors or capture_slot is None:
        raise WorkflowError("task capture-plan assignment is invalid: " + "; ".join(capture_errors))
    return task, {
        "task_id": task_id,
        "analysis_id": analysis_id,
        "coordinator_pseudonym": authorization["coordinatorID"],
        "source_video_filename": str(payload.get("sourceVideoFilename") or video_filename),
        "source_video_sha256": expected_hash,
        "camera_angle": camera_angle,
        "skill_level": skill_level,
        "capture_plan_id": payload["capturePlanAssignment"]["plan"]["identifier"],
        "capture_plan_sha256": payload["capturePlanAssignment"]["plan"]["sha256"],
        "capture_slot_id": capture_slot["slotID"],
        "participant_pseudonym": capture_slot["participantPseudonym"],
        "split": capture_slot["split"],
        "signer_key_id": signer["signerKeyID"],
        "video_mime": video_mime,
    }


def verify_annotation_upload(
    annotation_data: bytes,
    signature_data: bytes,
    coach_pseudonym: str,
    task: dict,
    registries: RegistryConfiguration,
) -> tuple[dict, dict | None]:
    package = _load_json(annotation_data, "annotation JSON", MAX_ANNOTATION_BYTES)
    sidecar = _load_json(signature_data, "signature JSON", MAX_TASK_BYTES)
    if package.get("annotatorPseudonym") != coach_pseudonym:
        raise WorkflowError("annotation pseudonym does not match the signed-in coach")
    embedded_task = package.get("labelingTask")
    task_json = json.loads(Path(task["task_path"]).read_text())
    if embedded_task != task_json:
        raise WorkflowError("annotation is not bound to this exact signed labeling task")
    if _uuid_text(package.get("analysisID"), "annotation analysis ID") != task["analysis_id"]:
        raise WorkflowError("annotation analysis ID does not match the assigned task")
    _, capture_errors = validate_annotation_assignment(package)
    if capture_errors:
        raise WorkflowError("annotation conflicts with its signed capture-plan slot: " + "; ".join(capture_errors))

    verified_coaches = registries.coaches()
    task_coordinators = registries.task_coordinators()
    with tempfile.TemporaryDirectory(prefix="serveai-portal-verify-") as temporary:
        directory = Path(temporary)
        annotation_path = directory / "annotation.json"
        signature_path = directory / "annotation.signature.json"
        annotation_path.write_bytes(annotation_data)
        signature_path.write_bytes(signature_data)
        try:
            verify_artifact_signature(annotation_path, coach_pseudonym, verified_coaches, signature_path)
        except CoachAuthorizationError as error:
            raise WorkflowError(str(error)) from error
        errors = validate(
            package,
            annotation_path,
            verified_coaches=set(verified_coaches),
            verified_task_coordinators=task_coordinators,
        )
    if errors:
        cleaned = [error.split(": ", 1)[-1] for error in errors]
        raise WorkflowError("annotation failed dataset checks: " + "; ".join(cleaned[:8]))
    annotation_id = _uuid_text(package.get("annotationID"), "annotation ID")
    if sidecar.get("artifactID") != package.get("annotationID"):
        raise WorkflowError("signature artifact ID does not match the annotation")
    return package, {"annotation_id": annotation_id}


def compare_submission_paths(paths: list[str]) -> dict | None:
    if len(paths) < 2:
        return None
    first, second = (json.loads(Path(path).read_text()) for path in paths[:2])
    return compare(first, second)


def verify_adjudication_upload(
    resolution_data: bytes,
    signature_data: bytes,
    adjudicator_pseudonym: str,
    task: dict,
    registries: RegistryConfiguration,
) -> tuple[dict, dict, dict]:
    """Verify a third coach's signed resolution and compile unsigned ground truth."""
    resolution = _load_json(resolution_data, "adjudication JSON", MAX_ANNOTATION_BYTES)
    sidecar = _load_json(signature_data, "adjudication signature JSON", MAX_TASK_BYTES)
    submissions = task.get("submissions") or []
    if len(submissions) != 2 or len({item.get("coach_id") for item in submissions}) != 2:
        raise WorkflowError("exactly two distinct verified source labels are required")
    source_coaches = {item.get("pseudonym") for item in submissions}
    if adjudicator_pseudonym in source_coaches:
        raise WorkflowError("the adjudicator must be independent from both source coaches")
    if resolution.get("adjudicatorPseudonym") != adjudicator_pseudonym:
        raise WorkflowError("adjudication pseudonym does not match the signed-in coach")
    annotations = [json.loads(Path(item["annotation_path"]).read_text()) for item in submissions]
    verified_coaches = registries.coaches()
    task_coordinators = registries.task_coordinators()

    with tempfile.TemporaryDirectory(prefix="serveai-portal-adjudication-") as temporary:
        directory = Path(temporary)
        resolution_path = directory / "adjudication.json"
        signature_path = directory / "adjudication.signature.json"
        resolution_path.write_bytes(resolution_data)
        signature_path.write_bytes(signature_data)
        failures: list[str] = []
        for submission, annotation in zip(submissions, annotations, strict=True):
            annotation_path = Path(submission["annotation_path"])
            try:
                verify_artifact_signature(
                    annotation_path,
                    annotation["annotatorPseudonym"],
                    verified_coaches,
                    Path(submission["signature_path"]),
                )
            except (CoachAuthorizationError, KeyError) as error:
                failures.append(str(error))
            failures.extend(
                validate(
                    annotation,
                    annotation_path,
                    verified_coaches=set(verified_coaches),
                    verified_task_coordinators=task_coordinators,
                )
            )
        failures.extend(validate_resolution(resolution, annotations, verified_coaches))
        if not failures:
            try:
                verify_artifact_signature(
                    resolution_path,
                    adjudicator_pseudonym,
                    verified_coaches,
                    signature_path,
                )
            except CoachAuthorizationError as error:
                failures.append(str(error))
    if failures:
        cleaned = [failure.split(": ", 1)[-1] for failure in failures]
        raise WorkflowError("adjudication failed evidence checks: " + "; ".join(cleaned[:10]))
    adjudication_id = _uuid_text(resolution.get("adjudicationID"), "adjudication ID")
    if sidecar.get("artifactID") != resolution.get("adjudicationID"):
        raise WorkflowError("signature artifact ID does not match the adjudication")
    ground_truth = compile_ground_truth(resolution, annotations)
    return resolution, ground_truth, {"adjudication_id": adjudication_id}


def verify_ground_truth_signature_upload(
    signature_data: bytes,
    adjudicator_pseudonym: str,
    task: dict,
    registries: RegistryConfiguration,
) -> dict:
    """Verify the adjudicator's signature over the portal-compiled ground truth bytes."""
    sidecar = _load_json(signature_data, "ground-truth signature JSON", MAX_TASK_BYTES)
    adjudication = task.get("adjudication")
    if not adjudication or adjudication.get("status") != "needs_ground_truth_signature":
        raise WorkflowError("this task is not awaiting a ground-truth signature")
    if adjudication.get("pseudonym") != adjudicator_pseudonym:
        raise WorkflowError("only the assigned adjudicator may sign the compiled ground truth")
    ground_truth_path = Path(adjudication["ground_truth_path"])
    ground_truth = json.loads(ground_truth_path.read_text())
    if ground_truth.get("adjudicatorPseudonym") != adjudicator_pseudonym:
        raise WorkflowError("compiled ground truth names a different adjudicator")
    verified_coaches = registries.coaches()
    with tempfile.TemporaryDirectory(prefix="serveai-portal-ground-truth-") as temporary:
        signature_path = Path(temporary) / "ground-truth.signature.json"
        signature_path.write_bytes(signature_data)
        try:
            verify_artifact_signature(
                ground_truth_path,
                adjudicator_pseudonym,
                verified_coaches,
                signature_path,
            )
        except CoachAuthorizationError as error:
            raise WorkflowError(str(error)) from error
    if sidecar.get("artifactID") != ground_truth.get("groundTruthID"):
        raise WorkflowError("signature artifact ID does not match the compiled ground truth")
    return sidecar


def verify_completed_evidence(task: dict, registries: RegistryConfiguration) -> None:
    """Reverify every cryptographic and content binding immediately before export."""
    adjudication = task.get("adjudication")
    if not adjudication or adjudication.get("status") != "verified":
        raise WorkflowError("ground truth is not verified")
    video_path = Path(task["video_path"])
    actual_video_hash = _sha256_file(video_path)
    if not hmac.compare_digest(actual_video_hash, task["source_video_sha256"]):
        raise WorkflowError("stored source video no longer matches its signed fingerprint")
    resolution_data = Path(adjudication["resolution_path"]).read_bytes()
    resolution_signature = Path(adjudication["resolution_signature_path"]).read_bytes()
    resolution, compiled_ground_truth, _ = verify_adjudication_upload(
        resolution_data,
        resolution_signature,
        adjudication["pseudonym"],
        task,
        registries,
    )
    stored_ground_truth_path = Path(adjudication["ground_truth_path"])
    stored_ground_truth = json.loads(stored_ground_truth_path.read_text())
    if stored_ground_truth != compiled_ground_truth:
        raise WorkflowError("stored ground truth differs from the verified adjudication result")
    verified_coaches = registries.coaches()
    try:
        verify_artifact_signature(
            stored_ground_truth_path,
            resolution["adjudicatorPseudonym"],
            verified_coaches,
            Path(adjudication["ground_truth_signature_path"]),
        )
    except CoachAuthorizationError as error:
        raise WorkflowError(str(error)) from error
