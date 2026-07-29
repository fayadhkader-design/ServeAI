#!/usr/bin/env python3
"""Create ServeAI's signed, fail-closed validated-model release envelope.

The production command reconstructs evaluation evidence from the frozen model,
dataset, signed repeatability tasks, parity report, and rights document before
signing. The private P-256 key is read from an external PEM file and is never
generated or stored by this script.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import math
import pathlib
import subprocess
import tempfile
from typing import Any

from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING


REQUIRED_SUBGROUPS = {
    "cameraAngle",
    "skillGroup",
    "handedness",
    "lighting",
    "resolution",
    "frameRate",
}
REQUIRED_CAMERA_ANGLES = {"side", "rear"}
REQUIRED_SKILL_GROUPS = {"beginner", "intermediate", "advanced", "competitive"}
REQUIRED_OUTPUTS = ["phaseVisibility", "boundaries", "techniqueVisibility", "ratings", "priority"]


class ReleaseGateError(ValueError):
    pass


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_artifact(path: pathlib.Path) -> str:
    if path.is_file():
        return sha256_file(path)
    if not path.is_dir():
        raise ReleaseGateError(f"artifact does not exist: {path}")
    digest = hashlib.sha256(b"serveai-artifact-tree-v1\n")
    files = sorted(
        item for item in path.rglob("*")
        if item.is_file()
        and not any(part.startswith(".") for part in item.relative_to(path).parts)
    )
    for item in files:
        relative = item.relative_to(path).as_posix()
        if "\n" in relative:
            raise ReleaseGateError("artifact paths may not contain newlines")
        digest.update(f"{relative}\t{sha256_file(item)}\n".encode())
    return digest.hexdigest()


def read_json(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise ReleaseGateError(f"invalid JSON document {path}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseGateError(f"JSON document must be an object: {path}")
    return value


def require(document: dict[str, Any], path: str) -> Any:
    value: Any = document
    for component in path.split("."):
        if not isinstance(value, dict) or component not in value:
            raise ReleaseGateError(f"missing required field: {path}")
        value = value[component]
    return value


def require_true(document: dict[str, Any], path: str, failures: list[str]) -> None:
    if require(document, path) is not True:
        failures.append(path)


def finite_number(document: dict[str, Any], path: str) -> float:
    value = require(document, path)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ReleaseGateError(f"field must be a finite number: {path}")
    return float(value)


def evaluation_failures(evaluation: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    if require(evaluation, "schemaVersion") != 4:
        failures.append("schemaVersion")
    if require(evaluation, "rubric") != CURRENT_RUBRIC_BINDING:
        failures.append("rubric")
    if require(evaluation, "capturePlan") != CURRENT_CAPTURE_PLAN_BINDING:
        failures.append("capturePlan")
    for field in (
        "releaseEligible",
        "passesProductionAccuracyGates",
        "commercialUseCleared",
        "coachGroundTruthVerified",
        "independentAdjudicationPolicyVerified",
        "coreMLParityPassed",
        "design.usesPlayerHeldOutSplit",
        "design.allClipsHaveTrainingConsent",
        "design.provenanceVerified",
    ):
        require_true(evaluation, field, failures)
    if finite_number(evaluation, "conversionParityMaximumAbsoluteError") > 0.0001:
        failures.append("conversionParityMaximumAbsoluteError")
    if finite_number(evaluation, "conversionParitySampleCount") < 60:
        failures.append("conversionParitySampleCount")
    if finite_number(evaluation, "design.heldOutClipCount") < 60:
        failures.append("design.heldOutClipCount")
    if finite_number(evaluation, "design.uniquePlayerCount") < 10:
        failures.append("design.uniquePlayerCount")
    if finite_number(evaluation, "design.repeatabilityPairCount") < 30:
        failures.append("design.repeatabilityPairCount")
    if finite_number(evaluation, "design.repeatabilityPlayerCount") < 10:
        failures.append("design.repeatabilityPlayerCount")
    require_true(evaluation, "design.repeatabilityUsesExactSameVideo", failures)
    if not REQUIRED_SUBGROUPS.issubset(set(require(evaluation, "design.auditedSubgroupDimensions"))):
        failures.append("design.auditedSubgroupDimensions")
    if require(evaluation, "design.failedMaterialSubgroups"):
        failures.append("design.failedMaterialSubgroups")
    if not REQUIRED_CAMERA_ANGLES.issubset(set(require(evaluation, "design.evaluatedCameraAngles"))):
        failures.append("design.evaluatedCameraAngles")
    if not REQUIRED_SKILL_GROUPS.issubset(set(require(evaluation, "design.evaluatedSkillGroups"))):
        failures.append("design.evaluatedSkillGroups")

    minimums = {
        "metrics.qualityPrecision": 0.90,
        "metrics.qualityRecall": 0.90,
        "metrics.phaseVisibilityF1": 0.85,
        "metrics.priorityAgreement": 0.75,
        "metrics.repeatabilityWithinFivePoints": 0.90,
    }
    maximums = {
        "metrics.boundaryMeanAbsoluteErrorSeconds": 0.12,
        "metrics.techniqueRatingMeanAbsoluteError": 0.60,
    }
    for field, minimum in minimums.items():
        if finite_number(evaluation, field) < minimum:
            failures.append(field)
    for field, maximum in maximums.items():
        if finite_number(evaluation, field) > maximum:
            failures.append(field)
    return failures


def rights_failures(rights: dict[str, Any]) -> list[str]:
    failures: list[str] = []
    if require(rights, "schemaVersion") != 1:
        failures.append("rights.schemaVersion")
    if require(rights, "commercialUseCleared") is not True:
        failures.append("rights.commercialUseCleared")
    sources = require(rights, "trainingSources")
    if not isinstance(sources, list) or not sources:
        return failures + ["rights.trainingSources"]
    for index, source in enumerate(sources):
        if not isinstance(source, dict):
            failures.append(f"rights.trainingSources[{index}]")
            continue
        if not source.get("sourceIdentifier") or not source.get("licenseIdentifier"):
            failures.append(f"rights.trainingSources[{index}].identity")
        evidence_hash = source.get("evidenceSHA256", "")
        if len(evidence_hash) != 64 or any(c not in "0123456789abcdef" for c in evidence_hash):
            failures.append(f"rights.trainingSources[{index}].evidenceSHA256")
        if source.get("permitsCommercialModelTraining") is not True:
            failures.append(f"rights.trainingSources[{index}].permitsCommercialModelTraining")
    return failures


def openssl(command: list[str], *, input_data: bytes | None = None) -> bytes:
    result = subprocess.run(
        ["openssl", *command],
        input=input_data,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise ReleaseGateError(result.stderr.decode(errors="replace").strip() or "OpenSSL failed")
    return result.stdout


def public_key_x963(private_key: pathlib.Path) -> bytes:
    details = openssl(["pkey", "-in", str(private_key), "-text_pub", "-noout"])
    if b"NIST CURVE: P-256" not in details and b"ASN1 OID: prime256v1" not in details:
        raise ReleaseGateError("private signing key must use P-256")
    der = openssl(["ec", "-in", str(private_key), "-pubout", "-conv_form", "uncompressed", "-outform", "DER"])
    if len(der) < 65 or der[-65] != 4:
        raise ReleaseGateError("private key is not an uncompressed P-256 signing key")
    point = der[-65:]
    # P-256 uncompressed points are exactly 04 || X(32 bytes) || Y(32 bytes).
    if len(point) != 65:
        raise ReleaseGateError("private key is not P-256")
    return point


def sign_payload(private_key: pathlib.Path, payload: bytes) -> bytes:
    with tempfile.NamedTemporaryFile() as handle:
        handle.write(payload)
        handle.flush()
        return openssl(["dgst", "-sha256", "-sign", str(private_key), handle.name])


def resource(path: pathlib.Path, digest: str) -> dict[str, str]:
    suffix = path.suffix.removeprefix(".")
    name = path.name[: -(len(path.suffix))] if path.suffix else path.name
    if not name or not suffix or any(separator in name for separator in ("/", "\\")):
        raise ReleaseGateError(f"artifact needs a safe name and extension: {path}")
    return {"name": name, "fileExtension": suffix, "sha256": digest}


def create_release_for_documents(
    *,
    model: pathlib.Path,
    evaluation_path: pathlib.Path,
    evaluation: dict[str, Any],
    evaluation_digest: str,
    rights_path: pathlib.Path,
    rights: dict[str, Any],
    private_key: pathlib.Path,
    issued_at_text: str,
) -> tuple[dict[str, Any], str]:
    failures = evaluation_failures(evaluation) + rights_failures(rights)
    model_hash = sha256_artifact(model)
    if require(evaluation, "modelSHA256") != model_hash:
        failures.append("evaluation.modelSHA256")
    if require(evaluation, "modelIdentifier") != require(rights, "modelIdentifier"):
        failures.append("rights.modelIdentifier")
    if require(evaluation, "modelVersion") != require(rights, "modelVersion"):
        failures.append("rights.modelVersion")
    if failures:
        raise ReleaseGateError("release refused; failed gates: " + ", ".join(sorted(set(failures))))
    if not private_key.is_file():
        raise ReleaseGateError(f"private signing key does not exist: {private_key}")
    try:
        issued_at = dt.datetime.fromisoformat(issued_at_text.replace("Z", "+00:00"))
    except ValueError as error:
        raise ReleaseGateError("issued-at must be an ISO-8601 timestamp") from error
    if issued_at.tzinfo is None:
        raise ReleaseGateError("issued-at must include a UTC offset")
    if issued_at.utcoffset() != dt.timedelta(0):
        raise ReleaseGateError("issued-at must be UTC")

    payload = {
        "schemaVersion": 2,
        "modelIdentifier": evaluation["modelIdentifier"],
        "modelVersion": evaluation["modelVersion"],
        "model": resource(model, model_hash),
        "evaluation": resource(evaluation_path, evaluation_digest),
        "rightsEvidence": resource(rights_path, sha256_artifact(rights_path)),
        "featureSchemaVersion": 2,
        "encoderIdentifier": "serveai.pose-sequence",
        "encoderVersion": "2.0.0",
        "inputFeatureName": "features",
        "inputFeatureCount": 1467,
        "outputFeatureNames": REQUIRED_OUTPUTS,
        "outputFeatureSizes": {
            "phaseVisibility": 10,
            "boundaries": 20,
            "techniqueVisibility": 6,
            "ratings": 6,
            "priority": 6,
        },
        "issuedAt": issued_at_text,
    }
    payload_bytes = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    public_key = public_key_x963(private_key)
    key_id = hashlib.sha256(public_key).hexdigest()
    signature = sign_payload(private_key, payload_bytes)
    envelope = {
        "schemaVersion": 1,
        "payloadBase64": base64.b64encode(payload_bytes).decode(),
        "signature": {
            "algorithm": "P256-SHA256",
            "keyID": key_id,
            "derBase64": base64.b64encode(signature).decode(),
        },
    }
    return envelope, key_id


def create_release(args: argparse.Namespace) -> tuple[dict[str, Any], str]:
    """Validate and sign an existing evaluation document for programmatic tests.

    The production CLI does not expose this weaker path; it always calls
    ``create_release_from_evidence`` and reconstructs the evaluation first.
    """
    model = args.model.resolve()
    evaluation_path = args.evaluation.resolve()
    rights_path = args.rights_evidence.resolve()
    return create_release_for_documents(
        model=model,
        evaluation_path=evaluation_path,
        evaluation=read_json(evaluation_path),
        evaluation_digest=sha256_artifact(evaluation_path),
        rights_path=rights_path,
        rights=read_json(rights_path),
        private_key=args.private_key.resolve(),
        issued_at_text=args.issued_at,
    )


def create_release_from_evidence(
    args: argparse.Namespace,
    *,
    verified_task_registry: dict[str, dict] | None = None,
) -> tuple[dict[str, Any], bytes, dict[str, Any], str]:
    # Lazy imports avoid the evaluator/signing constants' intentional cycle.
    from build_repeatability_report import build_report
    from evaluate_release_candidate import build_evaluation
    from task_coordinator_auth import (
        load_verified_task_coordinator_registry,
        require_task_coordinator_registry_secret,
    )

    evaluation_output = args.evaluation_output.resolve()
    envelope_output = args.output.resolve()
    if evaluation_output.exists() or envelope_output.exists():
        raise ReleaseGateError("release outputs already exist; refusing to overwrite frozen evidence")
    registry_path = args.task_coordinator_registry.resolve()
    registry = verified_task_registry
    if registry is None:
        registry = load_verified_task_coordinator_registry(
            registry_path,
            require_task_coordinator_registry_secret(),
        )
    repeatability = build_report(
        compiled_model_path=args.model.resolve(),
        research_model_path=args.research_model.resolve(),
        dataset_path=args.dataset.resolve(),
        pair_manifest_path=args.repeatability_pair_manifest.resolve(),
        registry=registry,
        registry_path=registry_path if registry_path.is_file() else None,
    )
    evaluation = build_evaluation(
        compiled_model_path=args.model.resolve(),
        research_model_path=args.research_model.resolve(),
        dataset_path=args.dataset.resolve(),
        offline_evaluation_path=args.offline_evaluation.resolve(),
        repeatability_path=None,
        parity_path=args.coreml_parity.resolve(),
        rights_path=args.rights_evidence.resolve(),
        repeatability_document=repeatability,
    )
    generation = evaluation.get("evidenceGeneration") or {}
    if generation.get("repeatabilitySource") != "verified signed native task pairs":
        raise ReleaseGateError("evaluation was not reconstructed from signed native repeatability tasks")
    evaluation_bytes = (
        json.dumps(evaluation, indent=2, sort_keys=True, allow_nan=False) + "\n"
    ).encode()
    evaluation_digest = hashlib.sha256(evaluation_bytes).hexdigest()
    rights_path = args.rights_evidence.resolve()
    envelope, key_id = create_release_for_documents(
        model=args.model.resolve(),
        evaluation_path=evaluation_output,
        evaluation=evaluation,
        evaluation_digest=evaluation_digest,
        rights_path=rights_path,
        rights=read_json(rights_path),
        private_key=args.private_key.resolve(),
        issued_at_text=args.issued_at,
    )
    return evaluation, evaluation_bytes, envelope, key_id


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=pathlib.Path, required=True, help="Compiled .mlmodelc artifact")
    parser.add_argument("--research-model", type=pathlib.Path, required=True)
    parser.add_argument("--dataset", type=pathlib.Path, required=True)
    parser.add_argument("--offline-evaluation", type=pathlib.Path, required=True)
    parser.add_argument("--repeatability-pair-manifest", type=pathlib.Path, required=True)
    parser.add_argument("--task-coordinator-registry", type=pathlib.Path, required=True)
    parser.add_argument("--coreml-parity", type=pathlib.Path, required=True)
    parser.add_argument("--rights-evidence", type=pathlib.Path, required=True)
    parser.add_argument("--evaluation-output", type=pathlib.Path, required=True)
    parser.add_argument("--private-key", type=pathlib.Path, required=True, help="External P-256 PEM key")
    parser.add_argument("--issued-at", required=True, help="UTC ISO-8601 timestamp fixed by release CI")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        _, evaluation_bytes, envelope, key_id = create_release_from_evidence(args)
        args.evaluation_output.parent.mkdir(parents=True, exist_ok=True)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.evaluation_output.write_bytes(evaluation_bytes)
        args.output.write_text(json.dumps(envelope, indent=2, sort_keys=True) + "\n")
    except (ReleaseGateError, ValueError, OSError) as error:
        raise SystemExit(str(error)) from error
    print(f"derived frozen evaluation: {args.evaluation_output}")
    print(f"signed release envelope: {args.output}")
    print(f"pin P-256 X9.63 public key ID in the app: {key_id}")


if __name__ == "__main__":
    main()
