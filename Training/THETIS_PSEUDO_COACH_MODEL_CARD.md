# THETIS pseudo-coach Core ML candidate

## Intended use

This model is an experimental research aid for inspecting ServeAI's temporal pose contract, player-isolated evaluation, and Core ML integration. It is not validated coaching advice and is not cleared for production or commercial use.

## Data

- Source: THETIS Three Dimensional Tennis Shots, repository pinned in `thetis_source_manifest.json`.
- Published scope used: 495 frontal RGB flat/kick/slice serve clips from 55 participants.
- Source filtering: one exact duplicate removed; 39 clips without a reliable overhead-arm event rejected.
- Model dataset: 455 clips from all 55 participants.
- Split: p1–p36 train, p37–p44 validation, p45–p55 test; no player crosses splits.
- Labels: deterministic 2D biomechanics proxies generated from Apple Vision poses; no coach labels.

The source actions are staged indoors, recorded from a frontal Kinect view, and performed without a ball. THETIS is described by its authors as available for research; no commercial grant is stated.

## Outputs

The model accepts a flattened 1,467-value ServeAI schema-v2 pose sequence: duration and view context plus 24 resampled frames of body confidence and 15 joints. Six linear heads produce usability, phase visibility, normalized phase boundaries, technique visibility, normalized technique ratings, and priority scores.

Racket drop, pronation, toss consistency, and trophy-alignment quality remain intentionally unavailable. The model does not track a racket or ball and cannot measure racket speed, ball speed, or true impact.

## Held-out pseudo-teacher agreement

Evaluation uses 93 clips from 11 unseen participants:

| Measure | Result | ServeAI gate |
| --- | ---: | ---: |
| Phase-boundary MAE | 0.104 s | ≤ 0.12 s — pass |
| Phase visibility F1 | 1.00 | ≥ 0.85 — pass |
| Technique-rating MAE | 0.92 | ≤ 0.60 — fail |
| Priority agreement | 46% | ≥ 75% — fail |

These values measure agreement with deterministic pseudo-label rules, not coaching accuracy.

## Core ML

`ServeAITennisPseudoCoach.mlmodel` reproduces the frozen NumPy heads with maximum absolute error 5.61e-7 across 12 held-out parity samples. Debug builds expose it only when `SERVEAI_ANALYSIS_MODE=experimentalcoreml` is set. Release builds exclude and guard the artifact because it failed coaching gates and lacks commercial-use clearance. The normal default remains the Vision heuristic, while the validated Core ML mode remains fail-closed.

## Release status

- `coachVerified: false`
- `coachingAccuracyMeasured: false`
- `commercialUseCleared: false`
- `sideRearViewEvaluation: false`
- `releaseEligible: false`

Promotion requires appropriately licensed real-ball side/rear iPhone data, independent ground truth, passing technique and priority gates, subgroup evaluation, repeatability testing, and a signed model release.
