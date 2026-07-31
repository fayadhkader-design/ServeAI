# Heuristic calibration policy

ServeAI's shipping Vision path is a conservative 2D observation system, not a
laboratory biomechanics system and not a coach-validated machine-learning model.
This policy explains how research can constrain the rules without turning
published group averages into false individual diagnoses.

## Evidence rules

- Use the same inferred hitting arm across racket-drop, acceleration, contact,
  and post-contact proxies. Use the opposite arm for the toss event.
- Require stable multi-frame evidence. A single extreme pose is not a technical
  breakdown; it is rejected when it falls outside the plausible tracking range.
- Normalize unoriented image-plane lines. Reversing the endpoints of a shoulder
  line must not change its tilt.
- Respect camera projection. Rear-view shoulder-line tilt may be described as an
  image-plane observation. Side-view shoulder-line tilt is not graded as a 3D
  trophy-position measurement.
- Low-confidence numerical proxies do not affect the overall score and cannot
  become the highest coaching priority.
- Normalize distances and displacement by torso length so changing the crop or
  phone distance does not change a score. Use multi-frame percentiles instead
  of single maxima for toss-arm, wrist-elevation, contact, and landing evidence.
- Racket drop and pronation remain arm-path proxies. Body-pose joints cannot
  locate the racket head or directly measure axial forearm rotation.

## Toss and likely-contact calibration

Apple Vision body pose does not identify the ball. ServeAI therefore evaluates
only visible toss-arm height and elbow extension, and explicitly does not claim
toss placement. Likewise, the likely-contact proxy combines robust hitting-arm
extension and wrist elevation but does not claim that ball-racket impact was
detected. Feedback must not turn these arm-path measurements into a directional
diagnosis about the ball.

## Loading calibration

The 2024 systematic review reports a pooled trophy-position front-knee flexion
of 64.5° with substantial study-method variation. The papers define anatomical
flexion as 0° when straight, while ServeAI's geometric interior angle is 180°
when straight. These values therefore cannot be compared without conversion.

ServeAI samples the clearer leg in each loading frame, removes low-confidence
and physiologically implausible observations, and uses a robust percentile
rather than the minimum value. The broad scoring band is intentionally tolerant:
research does not establish one exact knee angle as the definition of a good
serve, and high-performance work emphasizes the timing and velocity of knee
extension rather than one deepest frame.

Leg drive is evaluated across the loading-to-acceleration sequence using robust
knee-extension range plus body-center rise normalized by torso length. This is
closer to the published discriminating variables than the previous first/last
raw frame-coordinate difference. It still does not measure force or racket
velocity.

## Trophy-position calibration

Published serve studies use different event definitions, joint-coordinate
systems, and 3D laboratory measurements. ServeAI therefore does not compare a
raw 2D shoulder-line direction to one exact published "ideal." It folds line
direction into an acute image-plane tilt, requires a stable shoulder span across
multiple frames, and declines to grade this proxy from a side view.

## Release boundary

These changes reduce known false penalties and make the report more honest. They
do not establish technique accuracy. Production promotion still requires the
independent, participant-grouped coach ground truth and release gates documented
in `MODEL_RELEASE.md`.

## Research-only stability audit

`audit_pose_evidence_stability.py` applies only the visibility and robustness
checks to 495 local THETIS pose sequences. The resulting
`POSE_EVIDENCE_AUDIT.json` found that choosing whichever wrist had higher
confidence on every frame would switch arms in 491 of 495 sequences, with 3,799
switches total. All 495 sequences also produced a raw shoulder-line direction
above 90° because endpoint order changes line direction; the acute-line rule
removes that representation error. Seven sequences contained an extreme knee
frame rejected by the robust filter while retaining multi-frame knee evidence.

These results test failure modes and evidence coverage only. The manifest marks
the footage as frontal, staged without a ball, and research-only; it cannot
establish technique accuracy or train a commercial release model.

Regenerate the audit locally with:

```sh
python3 Training/audit_pose_evidence_stability.py \
  --output Training/POSE_EVIDENCE_AUDIT.json
```

## Sources

- Jacquier-Bret & Gorce (2024), systematic review and meta-analysis:
  https://pmc.ncbi.nlm.nih.gov/articles/PMC11260724/
- Reid et al. (2008), lower-limb coordination in high-performance flat serves:
  https://pubmed.ncbi.nlm.nih.gov/18202570/
- Hornestam et al. (2025), knee-flexion training and whole-body serve changes:
  https://pubmed.ncbi.nlm.nih.gov/41065038/
- Tossing-arm timing and full-body serve kinematics (2025):
  https://pmc.ncbi.nlm.nih.gov/articles/PMC12294548/
- Observation of the Tennis Serve Analysis criteria and reliability study:
  https://pmc.ncbi.nlm.nih.gov/articles/PMC5455193/
- Markerless 2D camera-position validity study:
  https://pmc.ncbi.nlm.nih.gov/articles/PMC10635560/
