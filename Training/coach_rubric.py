"""Frozen ServeAI coach-label rubric contract.

The file digest is intentionally pinned in code and in the native app. Changing
wording, anchors, or observable cues requires a new rubric version and schema.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path


RUBRIC_PATH = Path(__file__).with_name("coach_rubric_v1.json")
RUBRIC_IDENTIFIER = "serveai.single-serve-observational"
RUBRIC_VERSION = "1.0.0"
RUBRIC_SHA256 = "5a28ab5084f931116f4056493df1ba39f78b14c852a9f671cfc393cbb2d61741"
TECHNIQUES = {
    "tossPlacement", "loadingSequence", "trophyAlignment",
    "legDriveTiming", "contactReach", "landingBalance",
}
CURRENT_BINDING = {
    "identifier": RUBRIC_IDENTIFIER,
    "version": RUBRIC_VERSION,
    "sha256": RUBRIC_SHA256,
}


def load_verified_rubric() -> dict:
    raw = RUBRIC_PATH.read_bytes()
    if hashlib.sha256(raw).hexdigest() != RUBRIC_SHA256:
        raise ValueError("coach rubric file does not match its pinned SHA-256")
    rubric = json.loads(raw)
    if rubric.get("rubricIdentifier") != RUBRIC_IDENTIFIER or rubric.get("rubricVersion") != RUBRIC_VERSION:
        raise ValueError("coach rubric identity does not match the pinned contract")
    labels = [item.get("label") for item in rubric.get("techniques") or []]
    if len(labels) != len(TECHNIQUES) or set(labels) != TECHNIQUES:
        raise ValueError("coach rubric technique contract is incomplete")
    ratings = [item.get("rating") for item in rubric.get("ratingScale") or []]
    if ratings != [1, 2, 3, 4, 5]:
        raise ValueError("coach rubric rating anchors must be ordered 1 through 5")
    return rubric


VERIFIED_RUBRIC = load_verified_rubric()


def validate_rubric_binding(binding: object) -> list[str]:
    if binding != CURRENT_BINDING:
        return [
            "coach rubric binding is missing or does not match "
            f"{RUBRIC_IDENTIFIER} v{RUBRIC_VERSION} ({RUBRIC_SHA256})"
        ]
    return []


def validate_priority(techniques: list[dict], priority: object) -> list[str]:
    visible = {
        item.get("label"): item.get("rating")
        for item in techniques
        if (
            isinstance(item, dict)
            and item.get("isVisible") is True
            and isinstance(item.get("rating"), int)
            and not isinstance(item.get("rating"), bool)
            and 1 <= item.get("rating") <= 5
        )
    }
    if priority not in visible:
        return ["top coaching priority must be a visible technique"]
    minimum = min(visible.values()) if visible else None
    if visible.get(priority) != minimum:
        return ["top coaching priority must use the lowest visible technique rating"]
    return []
