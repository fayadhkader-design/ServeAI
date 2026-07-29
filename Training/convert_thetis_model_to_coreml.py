#!/usr/bin/env python3
"""Convert the frozen THETIS research ridge heads to a Core ML model.

The resulting model is intentionally tagged experimental and research-only.
Conversion parity does not promote it or establish coaching accuracy.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

import coremltools as ct
import numpy as np
from coremltools.models import datatypes
from coremltools.models.neural_network import NeuralNetworkBuilder

from train_temporal_baseline import record_vector


ROOT = Path(__file__).resolve().parent
DEFAULT_MODEL = ROOT / "artifacts/thetis_pseudo_coach_model.json"
DEFAULT_DATASET = ROOT / "artifacts/thetis_pseudo_coach_dataset.json"
DEFAULT_OUTPUT = ROOT.parent / "ServeAI/Resources/Models/ServeAITennisPseudoCoach.mlmodel"
DEFAULT_PARITY = ROOT / "artifacts/thetis_coreml_parity.json"
HEAD_ORDER = (
    "usability", "phaseVisibility", "boundaries",
    "techniqueVisibility", "ratings", "priority",
)


def load_inputs(model_path: Path, dataset_path: Path) -> tuple[dict, dict]:
    model = json.loads(model_path.read_text())
    dataset = json.loads(dataset_path.read_text())
    if model.get("releaseEligible") is not False or model.get("commercialUseCleared") is not False:
        raise ValueError("research model eligibility metadata is not fail-closed")
    if dataset.get("sourceDataset", {}).get("productionUseAllowed") is not False:
        raise ValueError("dataset source terms are not fail-closed")
    if model.get("trainingDatasetDigest") != dataset.get("datasetDigest"):
        raise ValueError("model and dataset digests do not match")
    if set(model.get("heads", {})) != set(HEAD_ORDER):
        raise ValueError("model heads are missing or out of the stable output order")
    return model, dataset


def precomposed_head(model: dict, name: str) -> tuple[np.ndarray, np.ndarray]:
    mean = np.asarray(model["normalizationMean"], dtype=np.float64)
    scale = np.asarray(model["normalizationScale"], dtype=np.float64)
    head = model["heads"][name]
    weights = np.asarray(head["weights"], dtype=np.float64)
    intercept = np.asarray(head["intercept"], dtype=np.float64)
    composed_weights = weights / scale[:, None]
    composed_bias = intercept - (mean / scale) @ weights
    return composed_weights.astype(np.float32), composed_bias.astype(np.float32)


def convert(model: dict, output: Path) -> ct.models.MLModel:
    input_dimension = len(model["normalizationMean"])
    output_dimensions = {
        name: len(model["heads"][name]["intercept"])
        for name in HEAD_ORDER
    }
    builder = NeuralNetworkBuilder(
        [("features", datatypes.Array(input_dimension))],
        [(name, datatypes.Array(size)) for name, size in output_dimensions.items()],
        disable_rank5_shape_mapping=True,
    )
    for name in HEAD_ORDER:
        weights, bias = precomposed_head(model, name)
        builder.add_inner_product(
            name=f"{name}_linear",
            W=weights.T,
            b=bias,
            input_channels=input_dimension,
            output_channels=output_dimensions[name],
            has_bias=True,
            input_name="features",
            output_name=name,
        )
    spec = builder.spec
    spec.description.metadata.author = "ServeAI research pipeline"
    spec.description.metadata.license = "THETIS research use only; not cleared for commercial deployment"
    spec.description.metadata.shortDescription = (
        "Experimental player-isolated pseudo-coach student; not coach-validated"
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
        "com.serveai.coachVerified": "false",
        "com.serveai.commercialUseCleared": "false",
        "com.serveai.supportedAppViewsEvaluated": "false",
        "com.serveai.trainingDatasetDigest": model["trainingDatasetDigest"],
        "com.serveai.sourceRepositoryCommit": model["sourceRepositoryCommit"],
    })
    output.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(output))
    return ct.models.MLModel(str(output), compute_units=ct.ComputeUnit.CPU_ONLY)


def expected_outputs(model: dict, vector: np.ndarray) -> dict[str, np.ndarray]:
    mean = np.asarray(model["normalizationMean"], dtype=np.float64)
    scale = np.asarray(model["normalizationScale"], dtype=np.float64)
    normalized = (vector - mean) / scale
    result = {}
    for name in HEAD_ORDER:
        head = model["heads"][name]
        weights = np.asarray(head["weights"], dtype=np.float64)
        intercept = np.asarray(head["intercept"], dtype=np.float64)
        result[name] = normalized @ weights + intercept
    return result


def parity_report(mlmodel: ct.models.MLModel, model: dict, dataset: dict) -> dict:
    test_records = [record for record in dataset["records"] if record["split"] == "test"]
    selected = test_records[::max(1, len(test_records) // 12)][:12]
    maximum_error = 0.0
    per_output = {name: 0.0 for name in HEAD_ORDER}
    for record in selected:
        vector = record_vector(record).astype(np.float64)
        expected = expected_outputs(model, vector)
        actual = mlmodel.predict({"features": vector.astype(np.float32)})
        for name in HEAD_ORDER:
            observed = np.asarray(actual[name]).reshape(-1).astype(np.float64)
            error = float(np.max(np.abs(observed - expected[name])))
            per_output[name] = max(per_output[name], error)
            maximum_error = max(maximum_error, error)
    tolerance = 2e-4
    return {
        "schemaVersion": 1,
        "modelIdentifier": model["modelIdentifier"],
        "modelVersion": model["modelVersion"],
        "sampleCount": len(selected),
        "maximumAbsoluteError": maximum_error,
        "maximumAbsoluteErrorByOutput": per_output,
        "tolerance": tolerance,
        "passes": maximum_error <= tolerance,
        "releaseEligible": False,
        "note": "Conversion parity only; this does not measure coaching accuracy or promote the model.",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--parity-output", type=Path, default=DEFAULT_PARITY)
    args = parser.parse_args()
    try:
        model, dataset = load_inputs(args.model, args.dataset)
        converted = convert(model, args.output)
        parity = parity_report(converted, model, dataset)
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        print(f"Core ML conversion stopped: {error}")
        return 1
    args.parity_output.parent.mkdir(parents=True, exist_ok=True)
    args.parity_output.write_text(json.dumps(parity, indent=2, allow_nan=False) + "\n")
    print(f"wrote experimental Core ML model to {args.output}")
    print(f"wrote parity report to {args.parity_output}; passes={parity['passes']}; maxError={parity['maximumAbsoluteError']:.8g}")
    return 0 if parity["passes"] else 1


if __name__ == "__main__":
    os.environ.setdefault("COREMLTOOLS_HOME", str(ROOT.parent / "work/coremltools-cache"))
    raise SystemExit(main())
