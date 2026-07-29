#!/usr/bin/env python3
"""Remove only a recognizable ServeAI evaluation-candidate staging directory."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from stage_evaluation_candidate import DEFAULT_OUTPUT_DIRECTORY, MANIFEST_RESOURCE_NAME, read_object


class EvaluationCandidateUnstagingError(ValueError):
    pass


def unstage_candidate(staging_directory: Path) -> None:
    manifest_path = staging_directory / f"{MANIFEST_RESOURCE_NAME}.json"
    if not staging_directory.is_dir() or not manifest_path.is_file():
        raise EvaluationCandidateUnstagingError("target is not a staged ServeAI evaluation candidate")
    manifest = read_object(manifest_path, "evaluation-candidate manifest")
    if manifest.get("schemaVersion") != 1 or manifest.get("purpose") != "release-evaluation-only":
        raise EvaluationCandidateUnstagingError("target manifest is not evaluation-only")
    permitted = {
        f"{MANIFEST_RESOURCE_NAME}.json",
        "ServeAIEvaluationCandidateModel.mlmodelc",
        "ServeAIEvaluationCandidateParity.json",
    }
    if {path.name for path in staging_directory.iterdir()} != permitted:
        raise EvaluationCandidateUnstagingError("staging directory contains unrecognized files")
    shutil.rmtree(staging_directory)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--staging-directory", type=Path, default=DEFAULT_OUTPUT_DIRECTORY)
    args = parser.parse_args()
    try:
        unstage_candidate(args.staging_directory)
    except (EvaluationCandidateUnstagingError, OSError, ValueError) as error:
        print(f"evaluation-candidate removal stopped: {error}")
        return 1
    print(f"removed staged evaluation candidate at {args.staging_directory}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
