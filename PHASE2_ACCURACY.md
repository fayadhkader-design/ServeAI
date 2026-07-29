# Phase 2 — Accuracy Validation Beta

## What this phase changes

Phase 2 turns ServeAI from a polished product prototype into a measurable model-development system. The app still must not claim biomechanical accuracy until the acceptance gates below pass on a held-out test set.

The first implemented slice includes:

- a real on-device recording-quality gate before every analysis
- a versioned, normalized pose-sequence feature contract
- a `ServeInferenceModel` boundary and non-deceptive unavailable-model implementation
- a consent-safe coach annotation JSON schema and exporter
- an evaluation harness for input screening, event timing, priority agreement, and repeatability
- an in-app coach calibration editor with blind multi-session drafts, locked coach identity, frame stepping, phase-boundary labels, technique ratings, usability review, consent state, and collision-safe JSON export
- a license-gated dataset manifest with immutable checksums and blocked-use records
- a trained research-only tennis pose/action baseline with contiguous-block evaluation and a model card
- schema-v8 participant pseudonyms, frozen rubric identity/version/SHA-256, operational 1–5 anchors, required-visibility rules, corrected single-serve toss-placement target, capture/cohort metadata, source-video fingerprints, signed portable coach tasks, signed pose-sequence evidence, persistent blind local drafts, separately authorized and signed video-bound consent receipts, deterministic player-isolated splits, EC-signed coach artifacts, admin-authorized coach public keys, double-label enforcement, explicit third-coach adjudication, and executable collection/assembly gates
- a local research annotation portal with hashed access tokens, expiring CSRF-protected sessions, fail-closed registry verification, exact video/task binding, exactly two blind source labels, independent third-coach adjudication, adjudicator-signed compiled ground truth, reverified evidence export, and a tamper-evident append-only audit trail
- a deterministic 300-clip / 60-participant target-domain capture plan with 180/60/60 participant-isolated train/validation/test clips, signed slot assignments, duplicate-slot rejection, and every executable cohort/failure floor represented
- a P-256-signed production model-release contract that binds the exact compiled model, evaluation, rights evidence, feature contract, and model identity; native code rehashes every artifact and re-runs every gate before inference
- a deterministic schema-v2 release evaluator plus signed exact-video repeatability builder; native task evidence binds both runs to the verified model artifact and app build, and the priority metric mirrors the coaching priority actually displayed in the report
- a coach-model Core ML converter that validates the complete temporal artifact contract, compiles without overwriting prior candidates, and runs every held-out clip through Apple's native runtime to produce parity evidence bound to the exact `.mlmodelc` directory
- a Debug-only, hash-verified evaluation-candidate loader and atomic staging/removal tools, so the exact coach-trained `.mlmodelc` can collect signed device repeatability evidence without appearing production-validated or presenting its output as coaching advice
- an explicit evidence-quality contract: visibility, pose quality, camera suitability, and usable frames are labeled **video evidence**, never model correctness; the report displays model assurance separately and states that clear video cannot rescue a failed or unvalidated coaching model

## Recording-quality policy

The app samples up to 24 frames at 3 fps and runs Apple Vision body-pose detection before enabling analysis. A clip is rejected when any blocking condition is met:

- short video edge below 480 px
- pose detected in less than 45% of samples
- average detected-pose confidence below 35%
- full upper/lower body visible in less than 30% of samples
- detected pose touches a frame edge in more than 65% of tracked samples
- multiple people detected

Warnings are shown for weaker-but-usable evidence: below 720p, below 30 fps, pose coverage below 70%, confidence below 55%, full-body coverage below 60%, tight framing, or a clip outside the preferred 3–15 second range. These are initial engineering thresholds and must be calibrated against coach-labeled usable/unusable clips.

The frozen pilot's 50 intentional failure slots use a separate research-only save action after rejection. It requires at least 18 authentic single-player detected frames and omits ambiguous multi-person frames. The resulting sample contains pose evidence but no score, phase result, technique measurement, coaching priority, or drill. Native task signing and dataset preparation both enforce that it stays an unusable failure example, so it can train and test rejection/usability only.

## Dataset protocol

Target the first internal dataset at 300–500 single-serve clips, balanced across:

- side and rear camera angles
- beginner, intermediate, advanced, and competitive players
- indoor/outdoor courts and varied clothing/background contrast
- right- and left-handed servers
- phone generations, 30/60/120 fps, and common 720p/1080p/4K sources
- deliberately poor framing, occlusion, low light, and multi-person negatives

Keep players, not clips, isolated between train/validation/test splits. Otherwise multiple serves from one player can leak their body shape and motion signature into the test set.

Every dataset package must contain an explicit positive local consent reference, but that reference alone is never dataset authorization. `CoachServeAnnotationPackage.draft` intentionally exports `allowsResearchAndModelTraining = false`. Preparation, final assembly, and training separately reverify immutable ECDSA-signed consent receipts issued by an authorized privacy/study administrator against a complete signed ledger snapshot no more than 24 hours old. The latest receipt must remain an unexpired grant and must bind the participant, current notice, affirmative evidence, purposes, data categories, retention window, and exact source-video SHA-256. A later linked revocation disables the record even after dataset assembly. Children are excluded from the current collection contract. The pipeline also requires handedness, environment, lighting, device, contrast, recording-issue, resolution, and frame-rate metadata so subgroup results cannot silently omit hard conditions. The signed annotation binds those labels to a schema-v2 pose sequence; identical videos cannot inflate collection counts.

Two qualified tennis coaches should independently label a calibration subset before the main annotation pass. Both must use the frozen `serveai.single-serve-observational` v1.0.0 rubric. Reconcile phase definitions and record disagreement instead of silently averaging it away. A top priority must be a lowest-rated visible technique; hidden evidence is unavailable, not neutral or inferred.

For different devices, the coordinator opens a real Vision/Core ML report and chooses **Send blind coach task**, then enters the assigned capture slot and participant code. ServeAI verifies the slot/participant relationship, hashes the original video, and exports a P-256-signed JSON containing the frozen plan binding, slot, participant, immutable analysis snapshot, and pose evidence. Send that JSON and the unchanged source video to each coach. On the coach device, choose **Import coach task**, select the JSON, then the video. The app rejects a changed signature, wrong video, unsupported/simulated evidence, future-dated task, duplicate analysis, or malformed plan assignment before creating a blank coach session; the participant code stays locked. The portal independently matches the assignment against the pinned plan and rejects a duplicate slot or camera/skill/cohort mismatch. Each schema-v8 annotation embeds that exact task and rubric digest. Preparation and assembly independently reverify the evidence; training, conversion, and release evaluation retain the capture-plan contract. Unknown, expired, substituted, or out-of-window keys fail closed.

`Training/audit_collection.py` is the fail-closed gate before model training. It checks the 300-clip floor, player-isolated 180/45/60 minimum split coverage, 40 total and 10 held-out players, unique source videos and capture slots, pinned slot assignments, verified coach/consent/coordinator evidence, resolved disagreements, multiple iPhone models, failure examples, and explicit overall/test-set cohort minimums. `Training/assemble_temporal_dataset.py` then reverifies consent, source-coach, adjudicator, coordinator, capture-plan, and pose-evidence bindings. Both tools refuse partial output and leave `modelReleaseEligible` false.

## First model contract

`ServeModelFeatureSequence` schema version 2 contains:

- camera angle and clip duration
- ordered timestamps
- one fixed entry for every supported body joint per frame
- body-centered, scale-normalized x/y coordinates
- body confidence plus confidence and presence mask for every joint

`ServeModelFeatureProvenance` additionally records the source-video SHA-256, pose detector identifier/revision, encoder identifier/version, generation time, requested sampling rate, smoothing window, and sampled/detected frame counts.

The initial model should predict visible serve phase boundaries, phase-level coaching estimates, and technical measurements that are truly observable from the selected angle. Racket speed, ball speed, exact 3D rotation, and medical/injury conclusions remain out of scope.

The app’s Core ML mode is fail-closed: it accepts only a release signed by a pinned P-256 authority whose exact compiled model, evaluation report, and commercial-rights evidence match their signed SHA-256 values. It rechecks the feature contract, evaluation design, seven accuracy gates, independent adjudication, Core ML parity, supported side/rear and skill cohorts, and source rights before inference. Without that complete bundle it reports that no validated model is installed and never falls back silently to heuristic scores. A separate `evaluationcoreml` mode exists only in Debug builds: it requires a manifest and passing parity report bound to the exact staged candidate, labels all output evaluation-only, records validation as false, and cannot activate in Release. Release additionally excludes all candidate resources and runs a bundle guard that fails if any evaluation artifact is packaged. Production signing keys intentionally remain unprovisioned while the experimental model fails release criteria.

## Acceptance gates

The first beta model is eligible for limited pilot use only when a player-held-out test set meets all default gates in `AccuracyAcceptanceCriteria`:

| Measure | Minimum gate |
| --- | ---: |
| Usable-video precision | 90% |
| Usable-video recall | 90% |
| Mean absolute phase-boundary error | ≤ 0.12 s |
| Phase visibility F1 | ≥ 85% |
| Technique-rating mean absolute error | ≤ 0.60 on the 1–5 scale |
| Exact agreement with coach’s top priority | 75% |
| Repeat analyses within 5 score points | 90% |

The release evaluator additionally requires at least 60 held-out clips from at least 10 players, verified training consent and provenance, and audited results for camera angle, skill group, handedness, lighting, resolution, and frame-rate cohorts. Every cohort count must match the frozen dataset; a material cohort needs at least five clips from at least three players and must pass every applicable offline metric. At least 30 exact-video repeatability pairs must cover at least 10 held-out players. Each pair is reconstructed from two authorized native signatures bound to the exact model artifact and app build. These are minimum release checks, not evidence that 60 clips are enough to train the model; the collection target remains 300–500 clips.

The report’s evidence percentage is the same weighted quantity used for its low/medium/high tier: 35% visible/usable-frame coverage, 40% pose-detection quality, and 25% camera suitability. It answers “could the app see the motion?” It does **not** answer “is this coaching prediction correct?” Vision heuristics are labeled not coach-validated; experimental/evaluation candidates show failed or pending release status; a validated release states that population gates passed while explicitly avoiding a per-serve correctness guarantee.

## Truthfulness rules

- “Simulated” means the output does not describe the selected video.
- “Vision heuristic” means joints came from the video but tennis phases/scores were rule-based and not coach-validated.
- “Validated on-device model” may be shown only for a signed model version with a stored evaluation report that passed release criteria.
- A high pose confidence means Vision saw joints consistently. It does not mean the tennis advice is correct.

## Next implementation slices

An internet-sourced weak-supervision experiment now labels every complete cycle recoverable from the licensed 500-frame tennis-pose sequence. It yields 31 pseudo-labeled serves from one athlete and trains a temporal student model, but the held-out same-athlete block reaches only 0.88 rating MAE and 67% priority agreement. The experiment is useful for inspecting event logic and feature gaps; it is explicitly not coach ground truth and is not integrated into ServeAI. The visual audit is `outputs/serveai-pseudo-label-review.html`.

A second research-only experiment pins the THETIS repository, processes all 495 published RGB serves from 55 players through Apple Vision, excludes one exact duplicate and 39 clips without an overhead event, and retains 455 pseudo-labeled sequences. The fixed player-held-out test contains 93 clips from 11 unseen players. Phase timing reaches 0.104-second MAE, but technique-rating MAE is 0.92 and priority agreement is 46%; both fail. Core ML conversion parity passes at 5.61e-7 maximum absolute error. The resulting model is available only in Debug through the explicit `experimentalcoreml` configuration with failed-gate and research-license warnings. Release excludes and guards the artifact. It is not production eligible because labels are not coach ground truth, camera/ball conditions do not match the app, technique gates fail, and THETIS does not state commercial permission.

1. Run the signed-registry portal pilot and collect the planned side/rear, real-ball, consented iPhone serves; internet research footage cannot close the remaining camera-domain or truth-label gaps.
2. Complete two blind qualified-coach annotations plus explicit third-coach adjudication for disagreements before tuning technique or priority heads.
3. Convert the frozen coach-trained artifact, then verify all held-out clips against the exact compiled Core ML directory.
4. Re-run player-held-out evaluation and signed end-to-end repeatability on the supported capture protocol.
5. Promote a signed Core ML version only after every release gate and commercial-data-rights check passes.
