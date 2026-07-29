# Validated model release contract

ServeAI does not promote a model by renaming a file or changing `releaseEligible`. Validated Core ML mode loads only an exact compiled `.mlmodelc` directory whose release envelope passes every check in both `sign_validated_model_release.py` and `ValidatedModelReleaseVerifier`.

## Bound artifacts

The P-256 signature covers a byte-exact payload containing:

- model identifier and semantic version
- SHA-256 of the compiled Core ML directory
- SHA-256 of the held-out evaluation JSON
- SHA-256 of the commercial-rights evidence JSON
- feature schema and encoder versions
- exact Core ML input/output names and tensor sizes, including the priority head used by the report UI
- a release-CI timestamp

Directory hashes are deterministic: regular files are sorted by relative path, each file is hashed, and those path/digest records are hashed under the `serveai-artifact-tree-v1` domain. Native and Python parity tests pin this contract.

The app then independently decodes the evaluation and rights documents. It refuses unknown signing keys, a changed signature, any artifact mismatch, incompatible feature names/schema, missing side or rear evaluation, missing skill/subgroup coverage, non-independent labels, failed Core ML parity, missing commercial training rights, or any accuracy result below the published gates.

## Required evaluation JSON

Use schema version 2 with the exact fields represented by `ModelReleaseEvaluationDocument` in the app. Do not author this document by hand: `evaluate_release_candidate.py` deterministically derives it from the frozen model, dataset, offline evaluation, repeatability, Core ML parity, and rights artifacts. Required evidence includes:

- at least 60 held-out clips from at least 10 player-isolated test participants
- every held-out record bound to a unique slot in the frozen target-domain capture plan
- two-coach ground truth with independently adjudicated disagreements
- verified consent and provenance
- side and rear captures plus every supported skill level
- camera angle, skill group, handedness, lighting, resolution, and frame-rate subgroup audits with no material failure
- all seven published accuracy/repeatability gates
- at least 30 exact-video repeatability pairs covering at least 10 held-out players
- Core ML conversion parity on at least 60 samples with maximum absolute error no greater than `0.0001`
- explicit `releaseEligible`, `passesProductionAccuracyGates`, and `commercialUseCleared` values of `true`

The rights document must match the same model identifier/version and list every training source with a license/evidence identifier, an evidence SHA-256, and an explicit commercial-model-training grant.

The offline priority metric is not a generic six-class argmax. It must use the same contract as the report UI: choose the highest-scoring visible technique that maps to a measurable native phase, and count unsupported or invisible coach priorities as disagreement. The evaluator rejects any other priority contract. It also recomputes subgroup failures from each frozen cohort's metrics and exact dataset counts, so an empty `failedMaterialSubgroups` declaration cannot hide a weak cohort.

## Compile the coach-trained candidate

The temporal trainer emits a fail-closed JSON research artifact. Convert that exact artifact and its bound assembled dataset with the pinned Core ML conversion runtime:

```sh
uv python install 3.12
PYTHONPATH=work/coremltools:Training \
  uv run --python 3.12 --no-project python \
  Training/convert_temporal_model_to_coreml.py \
  --model /frozen/temporal_model.json \
  --dataset /frozen/temporal_dataset.json \
  --compiled-output /frozen/ServeAIValidated.mlmodelc \
  --parity-output /frozen/coreml-parity.json
```

Install the pinned converter dependency into `work/coremltools` if it is not already present:

```sh
uv pip install --python 3.12 --target work/coremltools 'coremltools==9.0'
```

The converter validates all six trained heads, the 1,467-value native feature contract, normalization tensors, player isolation, model/dataset digest, and every source feature vector. It refuses to overwrite an existing compiled artifact. It then calls Apple's `coremlcompiler` and runs every held-out test clip through the resulting `.mlmodelc` using a native Swift/Core ML batch runner. The schema-v2 parity report is bound to the deterministic hash of that exact compiled directory and passes only with at least 60 samples and maximum absolute error no greater than `0.0001`.

## Stage the exact candidate for device evaluation

After compiled parity passes, stage the candidate into the Debug app with the generated research model and parity report:

```sh
python3 Training/stage_evaluation_candidate.py \
  --compiled-model /frozen/ServeAIValidated.mlmodelc \
  --research-model /frozen/temporal_model.json \
  --coreml-parity /frozen/coreml-parity.json
```

The staging command validates the model identity, fail-closed research status, six-head contract, at least 60 parity samples, `0.0001` error ceiling, and exact compiled-artifact hash. It atomically writes `ServeAI/Resources/EvaluationCandidate/` and refuses to overwrite an existing candidate. The manifest is restricted to `release-evaluation-only`; it contains no accuracy or release claim. The native loader independently hashes the staged `.mlmodelc` and parity JSON before inference and records the exact identifier, version, artifact SHA-256, `validatedReleaseVerified: false`, and app build in every signed task.

In the Debug scheme, set `SERVEAI_ANALYSIS_MODE=evaluationcoreml`. Processing and report screens label the result **Evaluation candidate · not released** and warn that it is for repeatability and coach comparison, not coaching advice. Release builds reject this mode and fall back to a safe non-evaluation default. The Release target also excludes every `ServeAIEvaluationCandidate*` resource, and a post-resource build guard fails the build if an evaluation artifact nevertheless reaches the `.app`. Thus forgetting to unstage cannot silently package the research candidate. Remove only the recognized staging bundle when the run is complete:

```sh
python3 Training/unstage_evaluation_candidate.py
```

The removal command refuses a directory with missing or unrecognized content so it cannot silently delete unrelated files.

## Signed repeatability workflow

Run the staged `evaluationcoreml` candidate in the exact Debug app build being evaluated. After release it may instead appear as validated Core ML. For at least 30 held-out clips spanning at least 10 test players, analyze the unchanged source video twice with the same camera-angle and skill settings. Export a signed coach task from each resulting report. New exports contain a structured signed trace with the model identifier, model version, compiled-artifact SHA-256, verified-release status, and app build identifier. This avoids a circular requirement: repeatability is measured before the model is permitted to call itself validated.

Create a pair manifest using `repeatability_pairs.example.json`, then build the report:

```sh
export SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET='use-the-independent-registry-secret'
python3 Training/build_repeatability_report.py \
  --compiled-model /frozen/ServeAIValidated.mlmodelc \
  --research-model /frozen/temporal_model.json \
  --dataset /frozen/temporal_dataset.json \
  --pair-manifest /frozen/repeatability-pairs.json \
  --task-coordinator-registry /frozen/signed-task-registry.json \
  --output /frozen/repeatability-report.json
```

The builder verifies both native P-256 signatures and the independently signed coordinator registry. It accepts only an exact hash-bound evaluation/experimental candidate with a false validation claim, or an already validated Core ML release. It rejects a changed score, wrong video, heuristic source, inconsistent validation claim, different model hash/version, different app build, changed capture settings, reused task, or reused analysis run.

## Deterministic evaluation workflow

Once offline held-out metrics, signed repeatability, compiled conversion parity, and rights evidence are frozen, this standalone command can derive a diagnostic evaluation report:

```sh
python3 Training/evaluate_release_candidate.py \
  --compiled-model /frozen/ServeAIValidated.mlmodelc \
  --research-model /frozen/temporal_model.json \
  --dataset /frozen/temporal_dataset.json \
  --offline-evaluation /frozen/temporal_evaluation.json \
  --repeatability /frozen/repeatability-report.json \
  --coreml-parity /frozen/coreml-parity.json \
  --rights-evidence /frozen/rights.json \
  --output /frozen/release-evaluation.json
```

Exit status `0` means every gate passed, `2` means structurally complete evidence missed at least one gate, and `1` means the evidence was invalid and no report was written. A failed report is useful for diagnosis but cannot be signed. The production signer does not trust this prebuilt report; it repeats evaluation directly from the raw signed pair manifest and other frozen evidence.

## Offline signing workflow

Keep the P-256 private key outside the repository and release workstation source tree. Compile the final model and freeze every raw evidence input, then run:

```sh
python3 Training/sign_validated_model_release.py \
  --model /frozen/ServeAIValidated.mlmodelc \
  --research-model /frozen/temporal_model.json \
  --dataset /frozen/temporal_dataset.json \
  --offline-evaluation /frozen/temporal_evaluation.json \
  --repeatability-pair-manifest /frozen/repeatability-pairs.json \
  --task-coordinator-registry /frozen/signed-task-registry.json \
  --coreml-parity /frozen/coreml-parity.json \
  --rights-evidence /frozen/rights.json \
  --evaluation-output /frozen/ServeAIValidatedEvaluation.json \
  --private-key /secure/offline/serveai-release-key.pem \
  --issued-at 2026-07-26T20:00:00Z \
  --output /frozen/ServeAIValidatedModelRelease.json
```

The CLI has no `--evaluation` input. It independently verifies the signed task-coordinator registry, reconstructs repeatability from all 60 native task signatures, recalculates aggregate and subgroup gates, binds parity/rights/model/dataset identities, serializes the derived evaluation, and signs its exact bytes. Existing evaluation or envelope output paths are refused rather than overwritten. If raw evidence is changed or any gate fails, neither output is written.

Provision only the printed P-256 X9.63 public key and its SHA-256 key ID in `productionPinnedPublicKeysX963`. Bundle the three named artifacts and the envelope with the app. Never bundle or commit the private key.

Production pinned keys intentionally remain empty today, so validated mode cannot activate yet. The current THETIS pseudo-coach artifact is covered by an explicit regression test and cannot be signed because it lacks coach ground truth, side/rear evaluation, commercial rights, repeatability evidence, and passing technique/priority results.
