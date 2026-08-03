# ServeAI model-development workspace

This directory makes model work reproducible and keeps unvalidated research artifacts out of the shipping app.

## Local owner-video calibration

Owner-supplied videos can enter a local calibration workflow before the formal
300-slot collection. Preserve each original unchanged, bind it to its SHA-256,
and keep every clip from the same person under one participant pseudonym. A
source containing multiple serves is still one source video; it cannot be
inflated into independent release examples by trimming it repeatedly.

`build_local_calibration_review.py` creates a self-contained local review page
from a source manifest and sampled filmstrips. The reviewer chooses one serve
per original, corrects ten phase anchors, rates only visible technique, and
downloads the decisions as JSON. That JSON remains calibration-only until the
original is processed through the iPhone pose pipeline and separately signed
training consent is present:

```sh
python3 Training/build_local_calibration_review.py
```

The restricted macOS runtime may be unable to initialize Apple Vision.
`extract_vision_pose_frames.swift` is a frame-based fallback for an authorized
macOS environment; it does not change the requirement to bind evidence to the
original video or to verify the sequence on the target iPhone runtime.

For `participant-local-001`, the validated decisions are materialized as two
single-serve clips by `materialize_local_calibration_clips.py`. The
`build_pose_calibration_derivatives.py` step then creates calibration-only
center crops that preserve the full body, ball, racket, landing, and phase
anchors while increasing the player scale. Every derivative is bound to its
selected clip and original source by SHA-256; it is tagged BT.709/H.264 level
4.1 for iPhone decoding and remains `trainingEligible: false`.

The iOS 26.5 Simulator cannot supply Apple Vision's human-pose weights
(`cnn_human_pose.espresso.weights`). `PoseCalibrationIntegrationTests` therefore
skips there instead of turning a runtime limitation into a false clip-quality
failure. To collect the next evidence:

1. Connect and trust a physical iPhone, enable Developer Mode, and select an
   Apple Development team for both `ServeAI` and `ServeAITests` in Xcode.
2. Select that iPhone as the test destination.
3. Run
   `PoseCalibrationIntegrationTests.testPoseCropCalibrationEvidence`.
4. Preserve the JSON test attachment with the pose coverage, mean confidence,
   full-body coverage, edge-clipping ratio, issues, and exact derivative hashes.

The device test is a recording-quality calibration only. A passing result does
not make the manually reviewed technique labels coach ground truth and does not
make either clip release evidence without signed consent and independent
validation.

## What is trained now

`train_pose_baseline.py` trains a small two-layer classifier directly from the CC BY 4.0 COCO keypoints in the Tennis Player Actions dataset. It distinguishes backhand, forehand, ready-position, and serve frames. It uses body-centered, height-normalized joint coordinates, left/right mirroring, joint dropout, and coordinate jitter. No image pixels or scraped videos are used.

Run:

```sh
python3 Training/verify_datasets.py
python3 Training/train_pose_baseline.py
```

The generated model and evaluation report are written to the gitignored
`Training/artifacts/` directory. The artifact is explicitly
`releaseEligible: false`. Public training media and pseudo-label sources do not
establish new-player generalization, so generated datasets and models are not
published with the application source.

## Racket and ball perception baseline

Body pose cannot locate the racket head or tennis ball. The object-perception
workstream therefore has its own license and accuracy gates. The Open Images
intake retains only explicit Tennis racket and Tennis ball boxes, requires a
per-image Creative Commons Attribution license, writes the complete attribution
record beside each sample, and hashes every downloaded image:

```sh
python3 Training/prepare_open_images_racket_ball.py \
  --split validation \
  --output Training/data/open_images_racket_ball_validation \
  --download
```

`evaluate_coreml_racket_ball_detector.swift` evaluates a Core ML detector at
IoU 0.50 without treating object detection as coaching accuracy. The current
research baseline is Apple's 59 MB YOLOv3Int8LUT model, pinned by SHA-256 in
`OBJECT_PERCEPTION_BASELINE.json`. On 30 licensed Open Images validation images,
it reaches 0.90 racket recall and 0.82 racket precision, but only 0.60 ball
recall and 0.33 ball precision at confidence 0.10. That is useful feasibility
evidence and insufficient for release.

`audit_coreml_racket_ball_video.swift` measures unlabeled temporal detection
coverage on a private local clip without exporting the clip or claiming that a
detection is correct. It is intended to expose domain shift before annotation.
The candidate is not bundled in ServeAI: bounding boxes do not identify racket
orientation or racket-head low point, the COCO sports-ball class is broader than
tennis balls, and the target-domain participant/angle gates have not passed.

`train_createml_racket_ball_detector.swift` also tested a two-class ObjectPrint
transfer-learning model on 1,022 licensed Open Images samples. After 1,000
iterations, its Create ML validation mAP@0.50 was 0.40 despite 0.77 training
mAP@0.50. Under the same fixed confidence/IoU protocol as the Apple baseline,
it reached only 0.31 racket precision / 0.83 recall and 0.22 ball precision /
0.27 recall. On the two available owner serve clips it detected no ball frames
and only one racket frame in total. This is a documented rejected experiment,
not an app dependency. Improving pronation and racket-drop evidence therefore
requires target-domain serve frames labeled for ball and racket keypoints—not
more training iterations on general tennis stills.

Build the local target-domain labeling pilot from an existing reviewed
calibration file and its unchanged source videos:

```sh
python3 Training/build_racket_ball_annotation_review.py
```

The page samples 15 critical frames per serve around racket drop, upward
acceleration, contact, and post-contact rotation. The reviewer places the
handle butt, racket throat, hoop top/left/right, and ball center when visible;
untouched points are explicitly marked not visible when a frame is finished.
Every normalized label is bound to both source-video and extracted-frame
SHA-256 values. Browser drafts and generated frames remain local. The export is
a one-participant workflow pilot, not release ground truth, and its 2D racket
shape cannot by itself establish three-dimensional forearm pronation.

## Internet-sourced pseudo-coach experiment

When qualified coaches are unavailable, `generate_pseudo_coach_dataset.py` uses all 500 ordered serve frames from the same CC BY 4.0 source and the published biomechanics references in `biomechanics_sources.json`. It detects 33 trophy-like overhead-arm maxima, retains 31 complete cycles, and produces transparent weak labels only for measurements supported by 2D body joints. Racket drop, pronation, toss consistency, trophy-alignment quality, true impact, ball speed, and racket speed remain unavailable.

Run:

```sh
python3 Training/generate_pseudo_coach_dataset.py
python3 Training/train_pseudo_coach_baseline.py
```

The distilled model currently reaches 0.086-second phase-boundary error, 0.88-point pseudo-technique-rating error, and 67% top-priority agreement on a six-cycle test time block from the same athlete. This measures agreement with the rule teacher, not agreement with a coach. It misses ServeAI's technique and priority gates and has no new-player test, so it is not integrated into the app. See `PSEUDO_COACH_MODEL_CARD.md`; `build_pseudo_label_review.py` can generate the gitignored local visual audit.

## Multi-player THETIS research model and Core ML conversion

`fetch_thetis_serves.py` pins the public THETIS repository to an immutable commit, downloads only the 495 RGB flat/kick/slice serve clips, records source SHA-256 values, and transcodes them without temporal edits for AVFoundation. The authors permit research use; no commercial grant is stated. The footage is frontal, staged indoors, and contains no ball, so it does not match ServeAI's side/rear real-court protocol.

Apple Vision recovers 32 pose samples from every clip. The dataset builder excludes one byte-identical source duplicate and 39 clips without a defensible overhead-arm event, leaving 455 pseudo-labeled serves from all 55 players. The fixed player-isolated split contains 295/67/93 train/validation/test clips from 36/8/11 players.

Run the reproducible stages:

```sh
python3 Training/fetch_thetis_serves.py
xcrun swiftc -parse-as-library Training/extract_vision_pose_sequences.swift \
  -framework AVFoundation -framework Vision -framework CryptoKit -framework ImageIO \
  -O -o work/bin/extract_vision_pose_sequences
work/bin/extract_vision_pose_sequences \
  --input Training/data/raw/thetis_serves/flat_service \
  --output Training/artifacts/thetis_flat_service_poses.jsonl --samples 32
# Repeat extraction for kick_service and slice_service.
python3 Training/generate_thetis_pseudo_coach_dataset.py
python3 Training/train_thetis_pseudo_coach.py
PYTHONPATH=work/coremltools:Training \
  /path/to/python3.12 Training/convert_thetis_model_to_coreml.py
python3 Training/build_thetis_model_review.py
```

On 93 clips from 11 unseen players, the model reaches 0.104-second pseudo-boundary MAE, 0.92-point pseudo-technique-rating MAE, and 46% pseudo-priority agreement. Only the phase timing subset passes. Core ML conversion parity passes at 5.61e-7 maximum absolute error. The `.mlmodel` is available only in local Debug experiments behind `SERVEAI_ANALYSIS_MODE=experimentalcoreml`; it is never the default, every report is labeled experimental, and the artifact remains `releaseEligible: false`, `coachVerified: false`, and `commercialUseCleared: false`. The Release target excludes and guards it so research-only, commercially uncleared weights cannot ship. See `THETIS_PSEUDO_COACH_MODEL_CARD.md`; `build_thetis_model_review.py` can regenerate the gitignored local visual audit.

## Cryptographic production promotion

Validated mode now has a separate fail-closed release path. `evaluate_release_candidate.py` derives the native schema-v4 evaluation document from frozen evidence instead of accepting caller-authored pass flags. It binds the exact training dataset, compiled model, frozen coach-rubric identity, and frozen target-domain capture-plan identity; checks independently adjudicated coach truth; recomputes every material subgroup result from exact cohort counts; verifies that offline priority agreement matches the priority actually displayed by the app; and incorporates signed exact-video repeatability plus Core ML parity. The production CLI in `sign_validated_model_release.py` does not accept that finished evaluation as input: it independently rebuilds repeatability from the raw authorized native tasks, recalculates the evaluation, writes the exact generated bytes, and only then signs them with the model and rights artifacts. The app pins the release authority's P-256 public key, verifies the signature, recomputes all three artifact hashes, verifies both frozen contracts, and re-runs every gate before inference. A manifest flag by itself cannot promote a model.

End-to-end repeatability is built by `build_repeatability_report.py` from two coordinator-authorized native task exports for each held-out video. Each signed export now carries structured model/app trace data, so a report cannot count a heuristic run, a different model artifact, a different build, a changed video, or the same analysis twice. See `MODEL_RELEASE.md` and `repeatability_pairs.example.json`.

`stage_evaluation_candidate.py` closes the pre-release device-testing loop without calling an unvalidated model production-ready. It accepts only the exact `.mlmodelc` bound to a passing schema-v2 parity report, writes an overwrite-resistant evaluation-only manifest, and enables the Debug-only `SERVEAI_ANALYSIS_MODE=evaluationcoreml` path. The app rechecks both the compiled-model and parity-report hashes and exports the exact unvalidated model/app trace. `unstage_evaluation_candidate.py` removes only a recognizable staging directory and refuses unknown files. Release builds cannot activate this mode, exclude all candidate-prefixed resources, and fail packaging if a candidate artifact is still discovered in the built app.

No production key is pinned yet, and the current pseudo-label model is covered by a regression test that proves it cannot be promoted. See `MODEL_RELEASE.md` for the evidence schema and offline signing procedure.

## Coach ground truth

The in-app Coach Calibration export is schema v8. Before labeling, a coach must start a new blind session or resume only their own saved session. Each analysis can retain multiple drafts keyed by distinct annotation IDs; starting a new session never loads another coach's decisions, and export filenames use the annotation ID so independent files cannot overwrite one another. The export records a stable anonymous participant code so all clips from one player can remain in exactly one split. It also records a locked coach pseudonym, ten phase decisions, six visible technique ratings, the top priority, usability, a local consent-record reference, and the collection cohorts needed to detect accuracy gaps: handedness, environment, lighting, device category/model, subject contrast, recording issues, resolution, and nominal frame rate. Schema v8 binds every decision to `coach_rubric_v1.json` using its identifier, semantic version, and pinned SHA-256. It replaces the impossible single-repetition “toss consistency” target with observable toss placement, requires the coaching priority to be one of the lowest-rated visible techniques, and forbids ball-contact, force, exact-angle, racket, or injury claims when the required evidence is hidden. It also embeds the exact normalized pose sequence used for model development plus source-video and capture provenance. For cross-device work, it retains the immutable signed coach-task manifest that transported that evidence.

The native editor shows the same 1–5 anchors, required-visibility cues, and do-not-infer rules contained in the frozen JSON. The contract is grounded in the published 8-stage serve framework, a 2024 systematic review of serve key events, and a 2D expert inter-rater study. These sources support a conservative observational protocol; they do not make a phone video equivalent to laboratory biomechanics or guarantee that a label is correct.

The shipping Vision rules follow the separate [heuristic calibration policy](HEURISTIC_CALIBRATION.md): multi-frame evidence replaces single-frame extrema, image-plane angles are camera-aware, and low-confidence proxies cannot drive the overall score or coaching priority. This reduces known false penalties but is not a substitute for the coach-ground-truth release process below.

The coach-side consent reference is not dataset authorization. Dataset preparation additionally requires an immutable signed consent receipt from a separately registered consent/privacy authority. The receipt binds the current notice, affirmative action, adult-only age assurance, purposes, data categories, retention period, participant pseudonym, and exact source-video fingerprint. See `CONSENT_GOVERNANCE.md`, `consent_registry.example.json`, and `consent_receipt.example.json` before collecting data.

Each coach needs an EC P-256 key whose private half never enters the repository. Create one and give the study administrator only the public half:

```sh
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out coach-private.pem
openssl pkey -in coach-private.pem -pubout -out coach-public.pem
```

Add the public key, verified qualification, status, and expiry to a copy of `coach_registry.example.json`. The administrator then authorizes that registry using a secret held outside the repository:

```sh
export SERVEAI_COACH_REGISTRY_SECRET='use-a-random-secret-of-at-least-32-characters'
python3 Training/sign_coach_registry.py unsigned-registry.json --output signed-registry.json
```

Cross-device tasks use a separate administrative authorization domain. First export a signed coach task from ServeAI. Verify it and extract the exact device key and coordinator pseudonym into an unsigned registry entry:

```sh
python3 Training/extract_task_coordinator_entry.py serveai-coach-task.json \
  --organization 'Accountable study organization' \
  --role 'Dataset collection coordinator' \
  --expires-at '2027-07-26T20:00:00Z' \
  --output coordinator-entry.json
```

After the study administrator verifies the person, organization, role, and validity window, add that entry to a copy of `task_coordinator_registry.example.json` and sign the registry with a separate secret:

```sh
export SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET='use-an-independent-random-secret-of-at-least-32-characters'
python3 Training/sign_task_coordinator_registry.py unsigned-task-registry.json \
  --output signed-task-registry.json
```

The ECDSA signature embedded in the task proves task integrity and device-key continuity. The signed coordinator registry separately proves that the exact pseudonym and key were administratively authorized for that organization, role, and time window. Unknown, expired, substituted, or out-of-window keys fail closed.

After exporting an annotation from ServeAI, its coach signs the exact JSON bytes:

```sh
python3 Training/sign_coach_artifact.py annotation.json \
  --coach-id coach-001 --private-key coach-private.pem
```

Set up and sign the separate consent authority and receipt as described in `CONSENT_GOVERNANCE.md`. After two coaches independently export and sign labels for each clip, prepare the annotations with both trust registries:

```sh
python3 Training/prepare_coach_dataset.py /path/to/exported-json \
  --coach-registry signed-registry.json \
  --task-coordinator-registry signed-task-registry.json \
  --consent-registry signed-consent-registry.json \
  --consent-ledger signed-consent-ledger.json \
  --consent-receipts /path/to/authoritative-consent-receipts
```

The preparation step rejects missing or revoked consent, receipts that do not cover the exact source video, inactive or expired consent authorities/coaches, invalid signatures, modified files, missing player/coach codes, incomplete phase decisions, a missing or modified rubric binding, a priority that is not the lowest visible rating, conflicting identities, and single-coach examples by default. It reports disagreement for adjudication rather than turning averages into fake ground truth.

When two labels disagree, copy `adjudication.example.json`, explicitly decide every disputed boundary/rating/priority against the video, and have a third authorized coach sign it. Then compile ground truth:

```sh
python3 Training/sign_coach_artifact.py adjudication.json \
  --coach-id coach-003 --private-key coach-003-private.pem
python3 Training/adjudicate_coach_labels.py first.json second.json \
  --resolution adjudication.json \
  --coach-registry signed-registry.json \
  --output ground-truth.json
python3 Training/sign_coach_artifact.py ground-truth.json \
  --coach-id coach-003 --private-key coach-003-private.pem
```

Coach and consent private keys, the device task-signing private key, and all three registry administrator secrets must remain outside the repository and exported dataset. The device task-signing key remains in the iPhone Keychain. A successfully adjudicated record is eligible to become ground truth; it is still explicitly ineligible for model release until the held-out accuracy gates pass.

Before training, audit one or more prepared indices and include every signed adjudication needed to resolve disagreement:

```sh
python3 Training/audit_collection.py Training/artifacts/coach_dataset_index.json \
  --ground-truth /path/to/adjudicated/*.json \
  --output Training/artifacts/collection_audit.json
```

The initial collection gate requires at least 300 analyses from 40 players, at least 180/45/60 train/validation/test clips, at least 10 held-out players, strict player isolation, unique source-video fingerprints, verified coach and portable-task coordinator indices, no unresolved disagreements, four iPhone models, deliberately captured failure cases, and minimum coverage for every recorded camera, skill, handedness, environment, lighting, contrast, resolution, and frame-rate cohort. The exact minimums are versioned in `audit_collection.py`. Passing this audit permits training and held-out evaluation only; it never marks a model as accurate or release eligible.

For the local collection pilot, generate the concrete 300-slot / 60-participant capture matrix and use the signed research portal. In the app, open **Pilot data capture**, enter the assigned `slot-NNN`, review the locked protocol, then record or import the serve. Every new native blind task includes its matching slot and `participant-NNN`; those values and the plan SHA-256 are signed with the video evidence. The app and portal reject reused slots and mismatched camera, skill, participant, resolution, frame rate, split, or cohort metadata:

```sh
python3 Training/generate_capture_plan.py
python3 -m AnnotationPortal.server serve --data-dir AnnotationPortal/data --port 8765
```

See `AnnotationPortal/README.md` for account bootstrap, registry configuration, security boundaries, and the verified task/annotation workflow. The portal queues two independent labels for adjudication; it does not replace signed consent receipts, qualification checks, or the dataset audit.

Slots 001–050 deliberately cover poor framing, occlusion, low light, multiple people, and motion blur. These examples do not bypass the product quality gate. When the normal gate rejects one, **Save failure sample** extracts only authentic unambiguous single-player poses and requires at least 18 detected frames; multiple-person frames are omitted rather than assigning an arbitrary person. The saved report is research-only and has no coaching outputs. Its signed annotation must remain unusable with no phase, technique, or priority labels, so it can supervise only rejection/usability behavior. Preparation rejects any attempt to promote it into coaching ground truth.

After the collection audit passes, assemble the signed labels and their bound pose sequences into one model-ready artifact. The assembler recomputes label disagreement, revalidates schema v8 and the frozen rubric digest, reverifies every coach, adjudicator, consent authority, and portable-task coordinator authorization, and refuses partial output:

```sh
python3 Training/assemble_temporal_dataset.py Training/artifacts/coach_dataset_index.json \
  --ground-truth /path/to/ground-truth/*.json \
  --coach-registry signed-registry.json \
  --task-coordinator-registry signed-task-registry.json \
  --consent-registry signed-consent-registry.json \
  --consent-ledger signed-consent-ledger.json \
  --consent-receipts /path/to/authoritative-consent-receipts \
  --output Training/artifacts/temporal_dataset.json
```

The assembled dataset remains `modelReleaseEligible: false`. It is an input to training and player-held-out evaluation, not proof that a model is accurate.

Train the deterministic multi-task research baseline only from an assembled dataset:

```sh
python3 Training/train_temporal_baseline.py Training/artifacts/temporal_dataset.json \
  --task-coordinator-registry signed-task-registry.json \
  --consent-registry signed-consent-registry.json \
  --consent-ledger signed-consent-ledger.json \
  --consent-receipts /path/to/authoritative-consent-receipts
```

The trainer first reverifies the fresh signed consent ledger and the current signed task-coordinator registry. It stops if any assembled record is missing, expired, out of scope, revoked after assembly, or bound to a coordinator key that is no longer active. It then fits usability, phase visibility/boundary, technique visibility/rating, and top-priority heads from the training players only. It reports validation, held-out test, and material subgroup results. Its JSON artifact records the training-time consent-ledger digest, coordinator-registry digest, and coordinator-evidence digest, and remains `releaseEligible: false` even if the offline subset passes because end-to-end repeatability and Core ML conversion parity still require separate evaluation.

Convert a frozen coach-trained artifact with `convert_temporal_model_to_coreml.py`. Unlike the THETIS-only experimental converter, this production-candidate converter verifies the assembled-dataset digest and complete native input/output contract, refuses to overwrite an existing artifact, compiles with Apple's `coremlcompiler`, and executes every held-out clip against the exact `.mlmodelc` through native Core ML. It writes the schema-v2, compiled-artifact-bound parity report required by `evaluate_release_candidate.py`. Conversion parity proves only that the compiled implementation matches the frozen research model; it does not promote the model or replace coach-accuracy, repeatability, subgroup, consent, provenance, or rights gates. See `MODEL_RELEASE.md` for commands.

## Evidence boundary

- The Tennis Player Actions data can support tennis-pose adaptation and serve-presence research, not coaching scores.
- The University of Bath data can support small motion/outcome experiments, not a production technique model.
- Penn Action remains blocked because its official page does not state reusable terms. THETIS is used only for the authors' stated research purpose and is blocked from commercial shipping.
- SportsPose and AthletePose3D are blocked from shipping under their academic/non-commercial terms unless separate permission is obtained.
- Random web and broadcast video is not ingested because copyright, participant consent, and coaching labels are not established.

See `datasets.json` for the source, license decision, checksums, and limitations of every researched dataset.
