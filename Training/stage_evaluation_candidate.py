#!/usr/bin/env python3
"""Stage an exact, parity-proven Core ML candidate for Debug device evaluation.

This does not promote or sign a model. It writes a fail-closed manifest whose
only purpose is repeatability and coach-comparison evidence collection.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import tempfile
from pathlib import Path
from typing import Any

from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING
from convert_temporal_model_to_coreml import HEAD_ORDER, OUTPUT_DIMENSIONS
from sign_validated_model_release import sha256_artifact


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT_DIRECTORY = ROOT / "ServeAI/Resources/EvaluationCandidate"
MODEL_RESOURCE_NAME = "ServeAIEvaluationCandidateModel"
PARITY_RESOURCE_NAME = "ServeAIEvaluationCandidateParity"
MANIFEST_RESOURCE_NAME = "ServeAIEvaluationCandidate"
PARITY_TOLERANCE = 0.0001


class EvaluationCandidateStagingError(ValueError):
    pass


def read_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise EvaluationCandidateStagingError(f"{label} is unreadable JSON: {error}") from error
    if not isinstance(value, dict):
        raise EvaluationCandidateStagingError(f"{label} must be a JSON object")
    return value


def sha256_file(path: Path) -> str:
    import hashlib

    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_candidate(
    *,
    compiled_model_path: Path,
    research_model: dict[str, Any],
    parity: dict[str, Any],
) -> tuple[str, str, str]:
    if compiled_model_path.suffix != ".mlmodelc" or not compiled_model_path.is_dir():
        raise EvaluationCandidateStagingError("compiled model must be an existing .mlmodelc directory")
    if research_model.get("schemaVersion") != 1 or research_model.get("releaseEligible") is not False:
        raise EvaluationCandidateStagingError("research model must remain fail-closed for release")
    if research_model.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise EvaluationCandidateStagingError("research model is not bound to the current coach rubric")
    if research_model.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise EvaluationCandidateStagingError("research model is not bound to the frozen capture plan")
    identity = (
        research_model.get("modelIdentifier"),
        research_model.get("modelVersion"),
    )
    if not all(isinstance(value, str) and value.strip() for value in identity):
        raise EvaluationCandidateStagingError("research model identity is incomplete")
    if (
        research_model.get("featureSchemaVersion") != 2
        or set(research_model.get("heads") or {}) != set(HEAD_ORDER)
    ):
        raise EvaluationCandidateStagingError("research model violates the native feature/output contract")

    model_hash = sha256_artifact(compiled_model_path)
    errors = parity.get("maximumAbsoluteErrorByOutput")
    if (
        parity.get("schemaVersion") != 2
        or parity.get("rubricContract") != CURRENT_RUBRIC_BINDING
        or parity.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING
        or parity.get("modelIdentifier") != identity[0]
        or parity.get("modelVersion") != identity[1]
        or parity.get("compiledModelSHA256") != model_hash
        or parity.get("passes") is not True
        or parity.get("releaseEligible") is not False
        or isinstance(parity.get("sampleCount"), bool)
        or not isinstance(parity.get("sampleCount"), int)
        or parity["sampleCount"] < 60
        or not isinstance(parity.get("maximumAbsoluteError"), (int, float))
        or not math.isfinite(parity["maximumAbsoluteError"])
        or parity["maximumAbsoluteError"] > PARITY_TOLERANCE
        or parity.get("tolerance") != PARITY_TOLERANCE
        or not isinstance(errors, dict)
        or set(errors) != set(HEAD_ORDER)
        or any(
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value > PARITY_TOLERANCE
            for value in errors.values()
        )
    ):
        raise EvaluationCandidateStagingError(
            "parity report does not prove the exact compiled candidate on at least 60 held-out clips"
        )
    return identity[0], identity[1], model_hash


def stage_candidate(
    *,
    compiled_model_path: Path,
    research_model_path: Path,
    parity_path: Path,
    output_directory: Path,
) -> dict[str, Any]:
    if output_directory.exists():
        raise EvaluationCandidateStagingError(
            "staging output already exists; refusing to overwrite an evaluation candidate"
        )
    research_model = read_object(research_model_path, "research model")
    parity = read_object(parity_path, "Core ML parity report")
    identifier, version, model_hash = validate_candidate(
        compiled_model_path=compiled_model_path,
        research_model=research_model,
        parity=parity,
    )
    manifest = {
        "schemaVersion": 1,
        "purpose": "release-evaluation-only",
        "modelIdentifier": identifier,
        "modelVersion": version,
        "model": {
            "name": MODEL_RESOURCE_NAME,
            "fileExtension": "mlmodelc",
            "sha256": model_hash,
        },
        "coreMLParity": {
            "name": PARITY_RESOURCE_NAME,
            "fileExtension": "json",
            "sha256": sha256_file(parity_path),
        },
        "featureSchemaVersion": 2,
        "encoderIdentifier": "serveai.pose-sequence",
        "encoderVersion": "2.0.0",
        "inputFeatureName": "features",
        "inputFeatureCount": 1467,
        "outputFeatureNames": [
            "phaseVisibility", "boundaries", "techniqueVisibility", "ratings", "priority",
        ],
        "outputFeatureSizes": {
            name: OUTPUT_DIMENSIONS[name]
            for name in ("phaseVisibility", "boundaries", "techniqueVisibility", "ratings", "priority")
        },
    }

    output_directory.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix="serveai-evaluation-stage-",
        dir=output_directory.parent,
    ) as temporary:
        staged = Path(temporary) / output_directory.name
        staged.mkdir()
        shutil.copytree(compiled_model_path, staged / f"{MODEL_RESOURCE_NAME}.mlmodelc")
        shutil.copy2(parity_path, staged / f"{PARITY_RESOURCE_NAME}.json")
        (staged / f"{MANIFEST_RESOURCE_NAME}.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True, allow_nan=False) + "\n"
        )
        staged.rename(output_directory)
    return manifest


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--compiled-model", type=Path, required=True)
    parser.add_argument("--research-model", type=Path, required=True)
    parser.add_argument("--coreml-parity", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, default=DEFAULT_OUTPUT_DIRECTORY)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        manifest = stage_candidate(
            compiled_model_path=args.compiled_model,
            research_model_path=args.research_model,
            parity_path=args.coreml_parity,
            output_directory=args.output_directory,
        )
    except (EvaluationCandidateStagingError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"evaluation-candidate staging stopped: {error}")
        return 1
    print(
        f"staged {manifest['modelIdentifier']} {manifest['modelVersion']} for Debug evaluation at "
        f"{args.output_directory}"
    )
    print("This candidate is not released, production-validated, or coaching advice.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
