#!/usr/bin/env python3
"""Train a reproducible research-only tennis-pose classifier with NumPy.

The model answers a narrow question: does one normalized body pose look like a
serve frame versus one of three other tennis actions? It does not score serve
technique, infer phases, or replace coach labels.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import numpy as np


ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data/raw/tennis_player_actions/annotations"
ARTIFACT_DIR = ROOT / "artifacts"
CLASSES = ("backhand", "forehand", "ready_position", "serve")
JOINTS = (
    "nose",
    "left_shoulder", "right_shoulder",
    "left_elbow", "right_elbow",
    "left_wrist", "right_wrist",
    "left_hip", "right_hip",
    "left_knee", "right_knee",
    "left_ankle", "right_ankle",
    "neck",
)
LEFT_RIGHT_PAIRS = (
    ("left_shoulder", "right_shoulder"),
    ("left_elbow", "right_elbow"),
    ("left_wrist", "right_wrist"),
    ("left_hip", "right_hip"),
    ("left_knee", "right_knee"),
    ("left_ankle", "right_ankle"),
)


@dataclass
class FoldResult:
    fold: int
    four_class_accuracy: float
    four_class_macro_f1: float
    serve_precision: float
    serve_recall: float
    serve_f1: float
    serve_brier: float
    confusion: list[list[int]]
    corrupted_four_class_accuracy: float = 0
    corrupted_serve_precision: float = 0
    corrupted_serve_recall: float = 0
    corrupted_serve_f1: float = 0


class TinyMLP:
    def __init__(self, inputs: int, hidden: int, outputs: int, seed: int):
        rng = np.random.default_rng(seed)
        self.w1 = rng.normal(0, math.sqrt(2 / inputs), (inputs, hidden))
        self.b1 = np.zeros(hidden)
        self.w2 = rng.normal(0, math.sqrt(2 / hidden), (hidden, outputs))
        self.b2 = np.zeros(outputs)

    def logits(self, x: np.ndarray) -> np.ndarray:
        hidden = np.maximum(0, x @ self.w1 + self.b1)
        return hidden @ self.w2 + self.b2

    def probabilities(self, x: np.ndarray) -> np.ndarray:
        values = self.logits(x)
        values -= values.max(axis=1, keepdims=True)
        exp = np.exp(values)
        return exp / exp.sum(axis=1, keepdims=True)

    def train(
        self,
        x: np.ndarray,
        y: np.ndarray,
        *,
        epochs: int,
        batch_size: int,
        learning_rate: float,
        weight_decay: float,
        seed: int,
    ) -> None:
        rng = np.random.default_rng(seed)
        parameters = [self.w1, self.b1, self.w2, self.b2]
        first = [np.zeros_like(p) for p in parameters]
        second = [np.zeros_like(p) for p in parameters]
        step = 0
        for _ in range(epochs):
            for start in range(0, len(x), batch_size):
                indices = rng.permutation(len(x))[start : start + batch_size]
                xb = x[indices].copy()
                yb = y[indices]
                # Train-time robustness to Vision jitter and occasional missed joints.
                xb[:, ::3] += rng.normal(0, 0.012, xb[:, ::3].shape)
                xb[:, 1::3] += rng.normal(0, 0.012, xb[:, 1::3].shape)
                missing = rng.random((len(xb), len(JOINTS))) < 0.025
                for joint_index in range(len(JOINTS)):
                    xb[missing[:, joint_index], joint_index * 3 : joint_index * 3 + 3] = 0

                pre = xb @ self.w1 + self.b1
                hidden = np.maximum(0, pre)
                logits = hidden @ self.w2 + self.b2
                logits -= logits.max(axis=1, keepdims=True)
                probabilities = np.exp(logits)
                probabilities /= probabilities.sum(axis=1, keepdims=True)
                probabilities[np.arange(len(yb)), yb] -= 1
                probabilities /= len(yb)

                dw2 = hidden.T @ probabilities + weight_decay * self.w2
                db2 = probabilities.sum(axis=0)
                dh = probabilities @ self.w2.T
                dh[pre <= 0] = 0
                dw1 = xb.T @ dh + weight_decay * self.w1
                db1 = dh.sum(axis=0)

                step += 1
                for index, gradient in enumerate((dw1, db1, dw2, db2)):
                    first[index] = 0.9 * first[index] + 0.1 * gradient
                    second[index] = 0.999 * second[index] + 0.001 * gradient * gradient
                    first_hat = first[index] / (1 - 0.9**step)
                    second_hat = second[index] / (1 - 0.999**step)
                    parameters[index] -= learning_rate * first_hat / (np.sqrt(second_hat) + 1e-8)


def load_examples() -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    features: list[np.ndarray] = []
    labels: list[int] = []
    frame_numbers: list[int] = []
    for class_index, class_name in enumerate(CLASSES):
        payload = json.loads((DATA_DIR / f"{class_name}.json").read_text())
        keypoint_names = payload["categories"][0]["keypoints"]
        keypoint_index = {name: index for index, name in enumerate(keypoint_names)}
        images = {item["id"]: item for item in payload["images"]}
        for annotation in payload["annotations"]:
            image = images[annotation["image_id"]]
            frame_number = int(Path(image["file_name"]).stem.split("_")[-1])
            points = np.asarray(annotation["keypoints"], dtype=np.float64).reshape(-1, 3)
            features.append(encode_pose(points, keypoint_index))
            labels.append(class_index)
            frame_numbers.append(frame_number)
    return np.stack(features), np.asarray(labels), np.asarray(frame_numbers)


def encode_pose(points: np.ndarray, indices: dict[str, int]) -> np.ndarray:
    selected = np.stack([points[indices[name]] for name in JOINTS]).astype(np.float64)
    present = selected[:, 2] > 0
    left_hip = selected[JOINTS.index("left_hip"), :2]
    right_hip = selected[JOINTS.index("right_hip"), :2]
    if present[JOINTS.index("left_hip")] and present[JOINTS.index("right_hip")]:
        center = (left_hip + right_hip) / 2
    else:
        center = selected[present, :2].mean(axis=0)
    visible_points = selected[present, :2]
    height = max(np.ptp(visible_points[:, 1]), 1.0)
    selected[:, :2] = (selected[:, :2] - center) / height
    selected[~present, :2] = 0
    # COCO visibility 1/2 becomes a confidence proxy; 0 remains absent.
    selected[:, 2] = selected[:, 2] / 2
    return selected.reshape(-1)


def mirror_features(x: np.ndarray) -> np.ndarray:
    mirrored = x.reshape(-1, len(JOINTS), 3).copy()
    mirrored[:, :, 0] *= -1
    index = {name: value for value, name in enumerate(JOINTS)}
    for left, right in LEFT_RIGHT_PAIRS:
        mirrored[:, [index[left], index[right]]] = mirrored[:, [index[right], index[left]]]
    return mirrored.reshape(len(x), -1)


def corrupted_copies(x: np.ndarray, repeats: int, seed: int) -> np.ndarray:
    """Approximate noisier pose extraction; this is a stress test, not a device benchmark."""
    rng = np.random.default_rng(seed)
    copies = np.tile(x, (repeats, 1)).reshape(-1, len(JOINTS), 3)
    copies[:, :, :2] += rng.normal(0, 0.02, copies[:, :, :2].shape)
    missing = rng.random(copies.shape[:2]) < 0.08
    copies[missing] = 0
    return copies.reshape(-1, len(JOINTS) * 3)


def confusion_matrix(y_true: np.ndarray, y_pred: np.ndarray) -> np.ndarray:
    result = np.zeros((len(CLASSES), len(CLASSES)), dtype=int)
    for truth, prediction in zip(y_true, y_pred, strict=True):
        result[truth, prediction] += 1
    return result


def safe_ratio(numerator: float, denominator: float) -> float:
    return float(numerator / denominator) if denominator else 0.0


def macro_f1(confusion: np.ndarray) -> float:
    scores = []
    for index in range(len(CLASSES)):
        true_positive = confusion[index, index]
        false_positive = confusion[:, index].sum() - true_positive
        false_negative = confusion[index, :].sum() - true_positive
        precision = safe_ratio(true_positive, true_positive + false_positive)
        recall = safe_ratio(true_positive, true_positive + false_negative)
        scores.append(safe_ratio(2 * precision * recall, precision + recall))
    return float(np.mean(scores))


def evaluate(fold: int, y: np.ndarray, probabilities: np.ndarray) -> FoldResult:
    predictions = probabilities.argmax(axis=1)
    confusion = confusion_matrix(y, predictions)
    serve_index = CLASSES.index("serve")
    truth_serve = y == serve_index
    predicted_serve = predictions == serve_index
    true_positive = np.logical_and(truth_serve, predicted_serve).sum()
    false_positive = np.logical_and(~truth_serve, predicted_serve).sum()
    false_negative = np.logical_and(truth_serve, ~predicted_serve).sum()
    precision = safe_ratio(true_positive, true_positive + false_positive)
    recall = safe_ratio(true_positive, true_positive + false_negative)
    return FoldResult(
        fold=fold,
        four_class_accuracy=float((predictions == y).mean()),
        four_class_macro_f1=macro_f1(confusion),
        serve_precision=precision,
        serve_recall=recall,
        serve_f1=safe_ratio(2 * precision * recall, precision + recall),
        serve_brier=float(np.mean((probabilities[:, serve_index] - truth_serve.astype(float)) ** 2)),
        confusion=confusion.tolist(),
    )


def standardize(train: np.ndarray, test: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    mean = train.mean(axis=0)
    scale = train.std(axis=0)
    scale[scale < 1e-6] = 1
    return (train - mean) / scale, (test - mean) / scale, mean, scale


def train_model(x: np.ndarray, y: np.ndarray, *, seed: int, epochs: int) -> tuple[TinyMLP, np.ndarray, np.ndarray]:
    augmented_x = np.concatenate([x, mirror_features(x)])
    augmented_y = np.concatenate([y, y])
    normalized, _, mean, scale = standardize(augmented_x, augmented_x)
    model = TinyMLP(normalized.shape[1], hidden=48, outputs=len(CLASSES), seed=seed)
    model.train(
        normalized,
        augmented_y,
        epochs=epochs,
        batch_size=96,
        learning_rate=0.002,
        weight_decay=0.0008,
        seed=seed + 1,
    )
    return model, mean, scale


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=180)
    parser.add_argument("--seed", type=int, default=240426)
    args = parser.parse_args()

    x, y, frame_numbers = load_examples()
    fold_results: list[FoldResult] = []
    # Five contiguous frame blocks are deliberately harder and less leaky than
    # a random frame split, though every fold still contains the same athlete.
    for fold in range(5):
        test = ((frame_numbers - 1) // 100) == fold
        train = ~test
        model, mean, scale = train_model(x[train], y[train], seed=args.seed + fold * 10, epochs=args.epochs)
        test_x = (x[test] - mean) / scale
        result = evaluate(fold + 1, y[test], model.probabilities(test_x))
        corrupted_x = corrupted_copies(x[test], repeats=5, seed=args.seed + fold)
        corrupted_y = np.tile(y[test], 5)
        stressed = evaluate(0, corrupted_y, model.probabilities((corrupted_x - mean) / scale))
        result.corrupted_four_class_accuracy = stressed.four_class_accuracy
        result.corrupted_serve_precision = stressed.serve_precision
        result.corrupted_serve_recall = stressed.serve_recall
        result.corrupted_serve_f1 = stressed.serve_f1
        fold_results.append(result)

    final_model, mean, scale = train_model(x, y, seed=args.seed + 100, epochs=args.epochs)
    report = {
        "schemaVersion": 1,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "modelIdentifier": "serveai.research.pose-action",
        "modelVersion": "0.1.0-research",
        "purpose": "single-frame tennis action / serve-likelihood baseline",
        "releaseEligible": False,
        "releaseBlockers": [
            "No player-held-out evaluation: the source dataset contains one athlete.",
            "No temporal phase labels.",
            "No coach technique-quality or correction-priority labels.",
            "COCO annotation confidence is not calibrated to Apple Vision confidence."
        ],
        "dataset": {
            "id": "tennis-player-actions-v1",
            "doi": "10.17632/nv3rpsxhhk.1",
            "license": "CC-BY-4.0",
            "examples": int(len(x)),
            "classes": list(CLASSES),
            "athletes": 1
        },
        "validation": {
            "method": "five contiguous 100-frame held-out blocks per action",
            "warning": "Same-athlete results measure within-recording discrimination, not real-player generalization.",
            "stressTest": {
                "method": "five deterministic copies with 0.02 normalized-coordinate jitter and 8% joint dropout",
                "warning": "Synthetic corruption probes fragility but is not a substitute for Apple Vision video evaluation."
            },
            "folds": [result.__dict__ for result in fold_results],
            "mean": {
                key: float(np.mean([getattr(result, key) for result in fold_results]))
                for key in (
                    "four_class_accuracy", "four_class_macro_f1", "serve_precision",
                    "serve_recall", "serve_f1", "serve_brier"
                    , "corrupted_four_class_accuracy", "corrupted_serve_precision",
                    "corrupted_serve_recall", "corrupted_serve_f1"
                )
            },
            "standardDeviation": {
                key: float(np.std([getattr(result, key) for result in fold_results]))
                for key in (
                    "four_class_accuracy", "four_class_macro_f1", "serve_precision",
                    "serve_recall", "serve_f1", "serve_brier"
                    , "corrupted_four_class_accuracy", "corrupted_serve_precision",
                    "corrupted_serve_recall", "corrupted_serve_f1"
                )
            }
        }
    }
    artifact = {
        "schemaVersion": 1,
        "modelIdentifier": report["modelIdentifier"],
        "modelVersion": report["modelVersion"],
        "releaseEligible": False,
        "classes": list(CLASSES),
        "joints": list(JOINTS),
        "inputLayout": "joint-major [normalizedX, normalizedY, visibility]",
        "normalizationMean": mean.tolist(),
        "normalizationScale": scale.tolist(),
        "weights": {
            "hiddenKernel": final_model.w1.tolist(),
            "hiddenBias": final_model.b1.tolist(),
            "outputKernel": final_model.w2.tolist(),
            "outputBias": final_model.b2.tolist()
        }
    }

    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    (ARTIFACT_DIR / "pose_action_evaluation.json").write_text(json.dumps(report, indent=2) + "\n")
    (ARTIFACT_DIR / "pose_action_model.json").write_text(json.dumps(artifact, separators=(",", ":")) + "\n")
    print(json.dumps(report["validation"]["mean"], indent=2))
    print("releaseEligible: false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
