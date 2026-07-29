# ServeAI research pose-action baseline

## Intended use

Detect whether an already-extracted 2D body pose resembles a tennis-serve frame rather than a backhand, forehand, or ready-position frame. This is a research input-screening component only.

## Data

- 2,000 COCO pose annotations from the [Tennis Player Actions Dataset](https://doi.org/10.17632/nv3rpsxhhk.1), licensed CC BY 4.0.
- Four balanced classes with 500 frames each.
- One recorded athlete. Contiguous frames from a video are correlated.

## Model and validation

- Input: 14 joints × normalized x/y × visibility proxy.
- Model: 48-unit ReLU hidden layer and four-way softmax output.
- Robustness augmentation: horizontal mirroring, small coordinate jitter, and random joint dropout.
- Evaluation: five folds, each holding out a contiguous 100-frame block from every action.
- Stress evaluation: 0.02 normalized-coordinate jitter and 8% missing joints. This intentionally harsher test drops serve precision/recall below the production gate and confirms that the model must not ship.
- Exact results are machine-generated in `artifacts/pose_action_evaluation.json`.

## Prohibited claims

The result does not establish accuracy for a new player, camera, court, clothing style, handedness, skill level, or Apple Vision pose distribution. It does not detect serve phases and must not score technique or produce coach recommendations. The model stays outside the app until a player-held-out, consented dataset passes ServeAI's acceptance gates.

## Attribution

Wang, Chun-Yi; Lai, Kalin Guanlun; Huang, Hsu-Chun; Lin, Wei-Ting (2024), “Tennis Player Actions Dataset for Human Pose Estimation,” Mendeley Data, V1, doi: 10.17632/nv3rpsxhhk.1. Used under CC BY 4.0; coordinates were normalized and augmented for this experiment.
