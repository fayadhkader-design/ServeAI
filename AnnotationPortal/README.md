# ServeAI Research Annotation Portal

This portal is the local pilot workflow for collecting qualified-coach ground truth. It does not make the current experimental model release-ready by itself. Its job is to protect the evidence needed to train and evaluate a better model.

## What it enforces

- Coordinator and coach accounts use random bearer tokens stored only as PBKDF2-SHA256 hashes.
- Sessions expire after 12 hours and use HttpOnly, SameSite=Strict cookies plus CSRF tokens.
- A native ServeAI task must retain its valid P-256 signature and match an active coordinator in the admin-signed registry.
- Uploaded MOV/MP4 bytes must exactly match the SHA-256 fingerprint signed into the task.
- A coach annotation must be schema 8, bound to the exact task and frozen rubric, signed by that coach's registered P-256 key, and pass the dataset validator.
- Exactly two coaches label independently. Two submissions become **ready for adjudication**, never automatic ground truth.
- The coordinator must assign a third active coach who did not author either source label.
- The adjudicator uploads a signed schema-v3 rubric-bound resolution, downloads the portal-compiled ground truth, and signs those exact bytes before the evidence chain can complete.
- Evidence export reverifies the stored video fingerprint, task authorization, both source annotations, adjudication, compiled ground truth, and every current coach signature before producing a deterministic-layout ZIP manifest.
- Source video is deliberately excluded from the evidence ZIP; the manifest retains its signed SHA-256 fingerprint.
- The audit log is hash-chained and protected by SQLite update/delete triggers.
- Import routes fail closed when either signed registry or its out-of-repository secret is missing.

Independent, video-bound consent receipts are still reverified by `Training/prepare_coach_dataset.py` and `Training/assemble_temporal_dataset.py`. The portal never treats an annotation's own consent field as sufficient legal authorization.

## Adjudication workflow

1. Assign exactly two independent source coaches and wait for both signed schema-v8 annotations.
2. Assign a third coach. The portal rejects either source coach as adjudicator.
3. The adjudicator reviews the video and both signed labels, downloads the pre-bound template, explicitly resolves every field, and signs the completed JSON.
4. The portal validates the resolution and compiles ground truth without averaging any value.
5. The adjudicator downloads that exact compiled file, signs it, and uploads the signature sidecar.
6. The coordinator exports the verified evidence ZIP. Each export is recorded in the append-only audit chain.

Verified ground truth is still marked `modelReleaseEligible: false`; it becomes eligible input to the separately consent-verified dataset assembly and held-out evaluator.

## Start a local pilot

Create the first coordinator account. The access token is displayed once:

```bash
python3 -m AnnotationPortal.server init \
  --data-dir AnnotationPortal/data \
  --pseudonym coordinator-001
```

Start in locked setup mode:

```bash
python3 -m AnnotationPortal.server serve \
  --data-dir AnnotationPortal/data \
  --port 8765
```

Open `http://127.0.0.1:8765`. Locked mode allows account/workflow setup but refuses task and annotation imports.

For verified imports, first create and sign the registries described in [Training/README.md](../Training/README.md), then run:

```bash
export SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET='at-least-32-private-characters'
export SERVEAI_COACH_REGISTRY_SECRET='a-different-32-character-secret'

python3 -m AnnotationPortal.server serve \
  --data-dir AnnotationPortal/data \
  --task-registry /absolute/path/task-coordinator-registry.signed.json \
  --coach-registry /absolute/path/coach-registry.signed.json \
  --port 8765
```

Do not commit registry HMAC secrets or coach private keys. A coach account grants portal access only; that pseudonym must separately be active in the signed coach registry before the portal accepts a label.

## Collection plan

Regenerate the 300-slot, 60-participant target-domain plan with:

```bash
python3 Training/generate_capture_plan.py
```

The plan is written to `Training/artifacts/target_capture_plan.json`. It contains study pseudonyms and cohort targets, not names or contact details. Its fixed split is 180 train / 60 validation / 60 held-out test clips. New native task payloads sign the plan ID/version/SHA-256, slot ID, and participant code. The portal matches each import against the frozen slot, refuses duplicate slots, shows live slot progress on `/capture`, and rechecks the planned cohorts when annotations arrive.

## Test

```bash
python3 -W error::ResourceWarning -m unittest discover -s AnnotationPortal/tests -v
```

The portal suite includes a real P-256 end-to-end test that creates three coach keys and both signed registries, imports a signed task and matching MOV bytes, verifies two annotations, completes independent adjudication, signs compiled ground truth, exports the evidence ZIP, and then proves a tampered ground-truth file is rejected.

## Production boundary

The standard-library server is intentionally a local pilot. It defaults to loopback, refuses remote binding without an explicit acknowledgement, and requires secure cookies for remote mode. Public or multi-organization use still needs reviewed HTTPS termination, managed secrets, backups, rate limiting, privacy/security review, retention enforcement, incident response, and the study's approved recruitment/consent process.
