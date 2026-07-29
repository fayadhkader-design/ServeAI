# ServeAI biomechanics pseudo-coach baseline

## Intended use

This artifact tests whether ServeAI's temporal feature and model code can learn transparent, source-cited 2D serve rules when no qualified coach labels are available. It is a research diagnostic and review aid only. It is not active in the iPhone app.

## Data and labels

- Source: Wang, Lai, Huang, and Lin (2024), *Tennis Player Actions Dataset for Human Pose Estimation*, DOI `10.17632/nv3rpsxhhk.1`, CC BY 4.0.
- Input: all 500 ordered serve frames and their published COCO/OpenPose-style keypoints.
- Segmentation: 33 trophy-like overhead-arm maxima produce 31 complete midpoint-bounded cycles; the two incomplete edge cycles are omitted.
- Athlete coverage: one recorded athlete. Train, validation, and test are contiguous time blocks from that same athlete.
- Teacher: deterministic 2D measurements informed by the biomechanics sources in `biomechanics_sources.json`.

The teacher labels visible starting stance, toss, loading, trophy-event timing, leg drive, upward acceleration, a low-confidence post-trophy contact-position proxy, and follow-through. It pseudo-rates loading sequence, leg-drive timing, contact reach, and landing balance. Racket drop, pronation, toss consistency, and trophy-alignment quality are deliberately unavailable because the source cannot support those claims.

## Training and evaluation

`train_pseudo_coach_baseline.py` fits deterministic ridge heads over the same schema-v2 temporal joint sequence used by the production research pipeline. Regularization is selected using only the validation time block. The frozen test block contains six cycles from the same athlete.

Current test teacher-agreement results:

- phase-boundary mean absolute error: 0.086 seconds
- pseudo-technique-rating mean absolute error: 0.88 points on the four-point 1–5 span
- top-priority agreement: 67%

These results miss ServeAI's own technique-rating and priority gates even before considering the much larger missing requirement: independent coach and new-player validation.

## Prohibited claims

- Teacher agreement is not coaching accuracy.
- A same-athlete time split is not player-held-out evaluation.
- The overhead contact proxy is not observed ball-racket impact.
- The labels do not establish racket drop, pronation, ball speed, racket speed, exact 3D rotation, injury risk, or medical conclusions.
- The artifact must not be renamed, surfaced, or described as a validated ServeAI model.

## Reproduce

```sh
python3 Training/generate_pseudo_coach_dataset.py
python3 Training/train_pseudo_coach_baseline.py
```

The generated dataset, model, and evaluation are written locally to the
gitignored `Training/artifacts/` directory. Every artifact states
`releaseEligible: false` or `modelReleaseEligible: false`; generated research
artifacts are not distributed with the public application source.
