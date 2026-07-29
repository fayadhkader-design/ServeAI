#!/usr/bin/env python3
"""Convert a frozen coach-trained temporal model and prove compiled parity.

This stage never promotes a model. It creates the exact ``.mlmodelc`` artifact
used by the release evaluator and a schema-v2 parity report bound to that
compiled directory's deterministic SHA-256.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import numpy as np

from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import (
    CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING,
    validate_record_provenance,
)
from sign_validated_model_release import sha256_artifact
from train_temporal_baseline import JOINTS, PHASES, RESAMPLED_STEPS, TECHNIQUES, record_vector


HEAD_ORDER = (
    "usability", "phaseVisibility", "boundaries",
    "techniqueVisibility", "ratings", "priority",
)
OUTPUT_DIMENSIONS = {
    "usability": 1,
    "phaseVisibility": 10,
    "boundaries": 20,
    "techniqueVisibility": 6,
    "ratings": 6,
    "priority": 6,
}
INPUT_DIMENSION = 1_467
PARITY_TOLERANCE = 0.0001
MINIMUM_PARITY_SAMPLES = 60
SWIFT_PARITY_RUNNER = Path(__file__).with_name("run_compiled_coreml_parity.swift")


class TemporalCoreMLConversionError(ValueError):
    pass


def read_object(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise TemporalCoreMLConversionError(f"{label} is unreadable JSON: {error}") from error
    if not isinstance(value, dict):
        raise TemporalCoreMLConversionError(f"{label} must be a JSON object")
    return value


def canonical_records_digest(records: list[dict[str, Any]]) -> str:
    import hashlib

    return hashlib.sha256(
        json.dumps(records, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


def numeric_array(value: object, *, name: str, shape: tuple[int, ...]) -> np.ndarray:
    try:
        array = np.asarray(value, dtype=np.float64)
    except (TypeError, ValueError) as error:
        raise TemporalCoreMLConversionError(f"{name} is not numeric") from error
    if array.shape != shape or not np.all(np.isfinite(array)):
        raise TemporalCoreMLConversionError(f"{name} must be finite with shape {shape}")
    return array


def validate_inputs(model: dict[str, Any], dataset: dict[str, Any]) -> list[dict[str, Any]]:
    if model.get("schemaVersion") != 1 or model.get("releaseEligible") is not False:
        raise TemporalCoreMLConversionError("model is not a fail-closed temporal research artifact")
    if dataset.get("schemaVersion") != 3 or dataset.get("trainingEligible") is not True:
        raise TemporalCoreMLConversionError("dataset is not an eligible assembled temporal artifact")
    if dataset.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise TemporalCoreMLConversionError("dataset is not bound to the current coach rubric")
    if model.get("rubricContract") != CURRENT_RUBRIC_BINDING:
        raise TemporalCoreMLConversionError("model is not bound to the current coach rubric")
    if dataset.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise TemporalCoreMLConversionError("dataset is not bound to the frozen capture plan")
    if model.get("capturePlanContract") != CURRENT_CAPTURE_PLAN_BINDING:
        raise TemporalCoreMLConversionError("model is not bound to the frozen capture plan")
    if dataset.get("modelReleaseEligible") is not False:
        raise TemporalCoreMLConversionError("dataset contains an invalid model-release claim")
    records = dataset.get("records")
    if not isinstance(records, list) or not records:
        raise TemporalCoreMLConversionError("dataset records are missing")
    digest = canonical_records_digest(records)
    if dataset.get("datasetDigest") != digest or model.get("trainingDatasetDigest") != digest:
        raise TemporalCoreMLConversionError("model and dataset are not bound to the same frozen records")
    if not all(isinstance(model.get(field), str) and model[field].strip() for field in ("modelIdentifier", "modelVersion")):
        raise TemporalCoreMLConversionError("model identity is incomplete")
    if (
        model.get("featureSchemaVersion") != 2
        or model.get("resampledSteps") != RESAMPLED_STEPS
        or tuple(model.get("jointOrder") or []) != JOINTS
        or tuple(model.get("phaseOrder") or []) != PHASES
        or tuple(model.get("techniqueOrder") or []) != TECHNIQUES
    ):
        raise TemporalCoreMLConversionError("model feature/label contract is incompatible with the app")
    if set(model.get("heads") or {}) != set(HEAD_ORDER):
        raise TemporalCoreMLConversionError("model heads do not match the stable Core ML output contract")

    mean = numeric_array(model.get("normalizationMean"), name="normalizationMean", shape=(INPUT_DIMENSION,))
    scale = numeric_array(model.get("normalizationScale"), name="normalizationScale", shape=(INPUT_DIMENSION,))
    if np.any(scale <= 0):
        raise TemporalCoreMLConversionError("normalizationScale must be strictly positive")
    for name in HEAD_ORDER:
        head = model["heads"][name]
        if not isinstance(head, dict):
            raise TemporalCoreMLConversionError(f"head {name} is malformed")
        numeric_array(
            head.get("weights"), name=f"heads.{name}.weights",
            shape=(INPUT_DIMENSION, OUTPUT_DIMENSIONS[name]),
        )
        numeric_array(
            head.get("intercept"), name=f"heads.{name}.intercept",
            shape=(OUTPUT_DIMENSIONS[name],),
        )

    seen_analyses: set[str] = set()
    player_splits: dict[str, set[str]] = {}
    for record in records:
        if record.get("rubric") != CURRENT_RUBRIC_BINDING:
            raise TemporalCoreMLConversionError("one or more records are not bound to the current coach rubric")
        capture_errors = validate_record_provenance(record)
        if capture_errors:
            raise TemporalCoreMLConversionError(
                "one or more records have invalid capture-plan provenance: " + capture_errors[0]
            )
        analysis_id = record.get("analysisID")
        participant = record.get("participantPseudonym")
        split = record.get("split")
        if not isinstance(analysis_id, str) or not analysis_id or analysis_id in seen_analyses:
            raise TemporalCoreMLConversionError("dataset analysis IDs must be present and unique")
        if not isinstance(participant, str) or not participant or split not in {"train", "validation", "test"}:
            raise TemporalCoreMLConversionError("dataset player/split provenance is incomplete")
        vector = record_vector(record)
        if vector.shape != (INPUT_DIMENSION,) or not np.all(np.isfinite(vector)):
            raise TemporalCoreMLConversionError(f"analysis {analysis_id} violates the native feature contract")
        seen_analyses.add(analysis_id)
        player_splits.setdefault(participant, set()).add(split)
    if any(len(splits) != 1 for splits in player_splits.values()):
        raise TemporalCoreMLConversionError("dataset contains player leakage across splits")
    if {record["split"] for record in records} != {"train", "validation", "test"}:
        raise TemporalCoreMLConversionError("dataset must contain train, validation, and test records")
    return records


def precomposed_head(model: dict[str, Any], name: str) -> tuple[np.ndarray, np.ndarray]:
    mean = np.asarray(model["normalizationMean"], dtype=np.float64)
    scale = np.asarray(model["normalizationScale"], dtype=np.float64)
    weights = np.asarray(model["heads"][name]["weights"], dtype=np.float64)
    intercept = np.asarray(model["heads"][name]["intercept"], dtype=np.float64)
    composed_weights = weights / scale[:, None]
    composed_bias = intercept - (mean / scale) @ weights
    return composed_weights.astype(np.float32), composed_bias.astype(np.float32)


def expected_outputs(model: dict[str, Any], vector: np.ndarray) -> dict[str, np.ndarray]:
    mean = np.asarray(model["normalizationMean"], dtype=np.float64)
    scale = np.asarray(model["normalizationScale"], dtype=np.float64)
    normalized = (vector.astype(np.float64) - mean) / scale
    return {
        name: normalized @ np.asarray(model["heads"][name]["weights"], dtype=np.float64)
        + np.asarray(model["heads"][name]["intercept"], dtype=np.float64)
        for name in HEAD_ORDER
    }


def build_uncompiled_model(model: dict[str, Any], output: Path) -> None:
    try:
        import coremltools as ct
        from coremltools.models import datatypes
        from coremltools.models.neural_network import NeuralNetworkBuilder
    except ImportError as error:
        raise TemporalCoreMLConversionError(
            "coremltools is unavailable; run with the pinned Python 3.12 conversion environment"
        ) from error

    builder = NeuralNetworkBuilder(
        [("features", datatypes.Array(INPUT_DIMENSION))],
        [(name, datatypes.Array(OUTPUT_DIMENSIONS[name])) for name in HEAD_ORDER],
        disable_rank5_shape_mapping=True,
    )
    for name in HEAD_ORDER:
        weights, bias = precomposed_head(model, name)
        builder.add_inner_product(
            name=f"{name}_linear",
            W=weights.T,
            b=bias,
            input_channels=INPUT_DIMENSION,
            output_channels=OUTPUT_DIMENSIONS[name],
            has_bias=True,
            input_name="features",
            output_name=name,
        )
    spec = builder.spec
    spec.description.metadata.author = "ServeAI model-development pipeline"
    spec.description.metadata.license = "Release candidate; see separately signed rights evidence"
    spec.description.metadata.shortDescription = (
        "Coach-trained temporal serve release candidate; not active until signed release verification"
    )
    spec.description.input[0].shortDescription = (
        "ServeAI schema-v2 flattened 24-step normalized Apple Vision pose sequence"
    )
    descriptions = {
        "usability": "Raw usable-video score",
        "phaseVisibility": "Raw visibility scores for ten serve phases",
        "boundaries": "Raw normalized start/end predictions for ten serve phases",
        "techniqueVisibility": "Raw visibility scores for six technique labels",
        "ratings": "Raw normalized 1-to-5 technique-rating predictions",
        "priority": "Raw priority scores for six technique labels",
    }
    for feature in spec.description.output:
        feature.shortDescription = descriptions[feature.name]
    mlmodel = ct.models.MLModel(spec, compute_units=ct.ComputeUnit.CPU_ONLY)
    mlmodel.user_defined_metadata.update({
        "com.serveai.modelIdentifier": model["modelIdentifier"],
        "com.serveai.modelVersion": model["modelVersion"],
        "com.serveai.releaseEligible": "false",
        "com.serveai.featureSchemaVersion": "2",
        "com.serveai.encoderIdentifier": "serveai.pose-sequence",
        "com.serveai.encoderVersion": "2.0.0",
        "com.serveai.trainingDatasetDigest": model["trainingDatasetDigest"],
        "com.serveai.rubricIdentifier": CURRENT_RUBRIC_BINDING["identifier"],
        "com.serveai.rubricVersion": CURRENT_RUBRIC_BINDING["version"],
        "com.serveai.rubricSHA256": CURRENT_RUBRIC_BINDING["sha256"],
        "com.serveai.capturePlanIdentifier": CURRENT_CAPTURE_PLAN_BINDING["identifier"],
        "com.serveai.capturePlanVersion": CURRENT_CAPTURE_PLAN_BINDING["version"],
        "com.serveai.capturePlanSHA256": CURRENT_CAPTURE_PLAN_BINDING["sha256"],
    })
    mlmodel.save(str(output))


def compile_model(uncompiled: Path, compiled_output: Path) -> None:
    if compiled_output.suffix != ".mlmodelc":
        raise TemporalCoreMLConversionError("compiled output must end in .mlmodelc")
    if compiled_output.exists():
        raise TemporalCoreMLConversionError("compiled output already exists; refusing to overwrite it")
    compiled_output.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(uncompiled), str(compiled_output.parent)],
        check=False,
        capture_output=True,
        text=True,
    )
    generated = compiled_output.parent / f"{uncompiled.stem}.mlmodelc"
    if result.returncode != 0 or not generated.is_dir():
        detail = (result.stderr or result.stdout).strip()
        raise TemporalCoreMLConversionError(f"Apple Core ML compilation failed: {detail}")
    if generated != compiled_output:
        raise TemporalCoreMLConversionError("compiled artifact name does not match the requested frozen output")


class CompiledCoreMLPredictor:
    def __init__(self, compiled_output: Path):
        self.compiled_output = compiled_output

    def predict_batch(self, vectors: list[np.ndarray]) -> list[dict[str, list[float]]]:
        if not SWIFT_PARITY_RUNNER.is_file():
            raise TemporalCoreMLConversionError("native compiled-parity runner is missing")
        with tempfile.TemporaryDirectory(prefix="serveai-compiled-parity-") as temporary:
            directory = Path(temporary)
            executable = directory / "run_compiled_coreml_parity"
            input_path = directory / "inputs.json"
            output_path = directory / "outputs.json"
            compiled = subprocess.run(
                [
                    "xcrun", "swiftc", "-parse-as-library", str(SWIFT_PARITY_RUNNER),
                    "-framework", "CoreML", "-framework", "Foundation", "-O", "-o", str(executable),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            if compiled.returncode != 0:
                raise TemporalCoreMLConversionError(
                    f"native parity runner compilation failed: {(compiled.stderr or compiled.stdout).strip()}"
                )
            input_path.write_text(json.dumps({
                "samples": [vector.astype(np.float64).tolist() for vector in vectors],
            }, separators=(",", ":")))
            executed = subprocess.run(
                [str(executable), str(self.compiled_output), str(input_path), str(output_path)],
                check=False,
                capture_output=True,
                text=True,
            )
            if executed.returncode != 0 or not output_path.is_file():
                raise TemporalCoreMLConversionError(
                    f"compiled Core ML parity execution failed: {(executed.stderr or executed.stdout).strip()}"
                )
            try:
                document = json.loads(output_path.read_text())
            except (OSError, json.JSONDecodeError) as error:
                raise TemporalCoreMLConversionError("native parity output is unreadable") from error
            predictions = document.get("predictions") if isinstance(document, dict) else None
            if not isinstance(predictions, list) or len(predictions) != len(vectors):
                raise TemporalCoreMLConversionError("native parity output count is invalid")
            return predictions


def build_parity_report(
    predictor: Any,
    model: dict[str, Any],
    records: list[dict[str, Any]],
    compiled_output: Path,
) -> dict[str, Any]:
    test_records = [record for record in records if record["split"] == "test"]
    if not test_records:
        raise TemporalCoreMLConversionError("held-out test split is empty")
    maximum_error = 0.0
    per_output = {name: 0.0 for name in HEAD_ORDER}
    vectors = [record_vector(record).astype(np.float64) for record in test_records]
    if hasattr(predictor, "predict_batch"):
        actual_outputs = predictor.predict_batch(vectors)
    else:
        actual_outputs = [
            predictor.predict({"features": vector.astype(np.float32)})
            for vector in vectors
        ]
    for record, vector, actual in zip(test_records, vectors, actual_outputs, strict=True):
        expected = expected_outputs(model, vector)
        for name in HEAD_ORDER:
            if name not in actual:
                raise TemporalCoreMLConversionError(f"compiled model output {name} is missing")
            observed = np.asarray(actual[name]).reshape(-1).astype(np.float64)
            if observed.shape != (OUTPUT_DIMENSIONS[name],) or not np.all(np.isfinite(observed)):
                raise TemporalCoreMLConversionError(f"compiled model output {name} is malformed")
            error = float(np.max(np.abs(observed - expected[name])))
            per_output[name] = max(per_output[name], error)
            maximum_error = max(maximum_error, error)
    if not math.isfinite(maximum_error):
        raise TemporalCoreMLConversionError("compiled parity produced a non-finite error")
    sample_count = len(test_records)
    return {
        "schemaVersion": 2,
        "modelIdentifier": model["modelIdentifier"],
        "modelVersion": model["modelVersion"],
        "compiledModelSHA256": sha256_artifact(compiled_output),
        "rubricContract": CURRENT_RUBRIC_BINDING,
        "capturePlanContract": CURRENT_CAPTURE_PLAN_BINDING,
        "sampleCount": sample_count,
        "maximumAbsoluteError": maximum_error,
        "maximumAbsoluteErrorByOutput": per_output,
        "tolerance": PARITY_TOLERANCE,
        "passes": sample_count >= MINIMUM_PARITY_SAMPLES and maximum_error <= PARITY_TOLERANCE,
        "releaseEligible": False,
        "note": "Compiled conversion parity only; production eligibility requires every separate release gate.",
    }


def convert_and_evaluate(
    *,
    model_path: Path,
    dataset_path: Path,
    compiled_output: Path,
) -> dict[str, Any]:
    model = read_object(model_path, "temporal model")
    dataset = read_object(dataset_path, "temporal dataset")
    records = validate_inputs(model, dataset)
    with tempfile.TemporaryDirectory(prefix="serveai-coreml-conversion-") as temporary:
        uncompiled = Path(temporary) / f"{compiled_output.stem}.mlmodel"
        build_uncompiled_model(model, uncompiled)
        compile_model(uncompiled, compiled_output)
    predictor = CompiledCoreMLPredictor(compiled_output)
    return build_parity_report(predictor, model, records, compiled_output)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--compiled-output", type=Path, required=True)
    parser.add_argument("--parity-output", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        parity = convert_and_evaluate(
            model_path=args.model,
            dataset_path=args.dataset,
            compiled_output=args.compiled_output,
        )
    except (TemporalCoreMLConversionError, OSError, KeyError, TypeError, ValueError) as error:
        print(f"Core ML conversion stopped; no parity report was written: {error}")
        return 1
    args.parity_output.parent.mkdir(parents=True, exist_ok=True)
    args.parity_output.write_text(json.dumps(parity, indent=2, sort_keys=True, allow_nan=False) + "\n")
    print(f"wrote compiled release candidate to {args.compiled_output}")
    print(
        f"wrote parity report to {args.parity_output}; passes={parity['passes']}; "
        f"samples={parity['sampleCount']}; maxError={parity['maximumAbsoluteError']:.8g}"
    )
    return 0 if parity["passes"] else 2


if __name__ == "__main__":
    os.environ.setdefault("COREMLTOOLS_HOME", str(Path(__file__).resolve().parents[1] / "work/coremltools-cache"))
    raise SystemExit(main())
