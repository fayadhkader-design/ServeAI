# ServeAI model-development consent governance

This is an engineering control, not legal advice or a substitute for review by the accountable data controller and qualified counsel. Cryptographic signatures prove that exact bytes were approved by an authorized key. They do **not** independently prove identity, capacity, understanding, voluntariness, or compliance with every jurisdiction.

## Current MVP boundary

- Model-development collection accepts adults only. `ageAssurance` must be `adultConfirmed`.
- A coach cannot authorize data use. The annotation's local consent record is only a reference.
- A separately registered consent/privacy authority must sign an immutable receipt.
- Each grant must cover the participant pseudonym, current notice version and digest, affirmative-action evidence digest, training and evaluation purposes, video/pose/label data categories, exact source-video SHA-256 values, validity and retention dates, and a real withdrawal route.
- A later revocation is a new signed receipt linked through `supersedesReceiptID`; history is never overwritten.
- Raw identity and age-verification material stays outside this repository and training artifacts. Only pseudonymous IDs and cryptographic digests enter the pipeline.
- Children are excluded from this workflow. Do not replace `adultConfirmed` with a checkbox. A future minor workflow needs jurisdiction-specific review and a verifiable parental-consent method before collection, not merely before training.

## Why the record is structured this way

Regulatory guidance emphasizes demonstrable records of who consented, when, what they were told, how they consented, and whether they later withdrew. ServeAI therefore records versioned notice and affirmative-action digests rather than only `consent=true`. The source-video binding prevents a broad participant record from silently authorizing unrelated footage.

Primary references checked for this contract:

- [UK ICO: how to obtain, record, and manage consent](https://ico.org.uk/for-organisations/uk-gdpr-guidance-and-resources/lawful-basis/consent/how-should-we-obtain-record-and-manage-consent/)
- [FTC: complying with COPPA](https://www.ftc.gov/business-guidance/resources/complying-coppa-frequently-asked-questions)
- [FTC: verifiable parental consent](https://www.ftc.gov/business-guidance/privacy-security/verifiable-parental-consent-childrens-online-privacy-rule)
- [NIST AI Risk Management Framework 1.0](https://www.nist.gov/publications/artificial-intelligence-risk-management-framework-ai-rmf-10)

## Collection procedure

1. The accountable organization approves the real participant notice and withdrawal route. Do not deploy the placeholder example as consent text.
2. Before collection, the participant sees the approved notice and takes a recorded affirmative action. The study operator confirms adult eligibility without placing a birth date or identity document in the model workspace.
3. ServeAI exports the coach annotation. Copy its `consentRecordID`, `participantPseudonym`, and `modelFeatureEvidence.provenance.videoSHA256` into a fresh receipt based on `consent_receipt.example.json`.
4. Hash the exact approved notice and the retained affirmative-action record using SHA-256. Store those digests in the receipt; keep the source evidence in the controlled consent system.
5. A registered consent authority signs the exact receipt bytes. The authority must not use a coach key.
6. Two independent registered coaches sign their annotations. Preparation verifies both trust domains.
7. If consent is withdrawn, issue and sign a `revoked` receipt naming the prior receipt in `supersedesReceiptID`, include it in every future build, stop new use, and apply the organization's deletion/suppression procedure to datasets and retraining schedules.

## Key setup and signing

Generate a dedicated EC P-256 consent-authority keypair outside the repository:

```sh
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out consent-private.pem
openssl pkey -in consent-private.pem -pubout -out consent-public.pem
```

Fill a copy of `consent_registry.example.json`, then have its administrator authorize it with a separate external secret:

```sh
export SERVEAI_CONSENT_REGISTRY_SECRET='use-a-distinct-random-secret-of-at-least-32-characters'
python3 Training/sign_consent_registry.py unsigned-consent-registry.json \
  --output signed-consent-registry.json
```

Fill and sign each immutable receipt:

```sh
python3 Training/sign_consent_receipt.py consent-grant.json \
  --authority-id privacy-admin-001 --private-key consent-private.pem
```

Immediately before preparation, assembly, and training, the consent authority creates a complete signed ledger snapshot of every grant and revocation receipt:

```sh
python3 Training/create_consent_ledger.py /path/to/authoritative-consent-receipts \
  --authority-id privacy-admin-001 \
  --private-key consent-private.pem \
  --output signed-consent-ledger.json
```

Ledger snapshots expire after 24 hours. The pipeline requires the supplied receipt set to match every signed ledger entry byte-for-byte, preventing a caller from omitting a later revocation while presenting an older grant. Training repeats this verification immediately before model fitting, so a withdrawal after dataset assembly still stops the run.

The pipeline rejects an invalid signature, modified or omitted receipt, stale ledger, inactive authority, expired grant/retention period, broken decision chain, latest revocation, participant mismatch, consent-version mismatch, missing purpose/category, or source-video mismatch.

## Operational limitations still requiring policy

- The controller must define and operate deletion, incident-response, access-request, and model-retraining procedures.
- The withdrawal route and notice text must be real, accessible, and organization-specific.
- The consent receipt directory used to create each ledger must be the authoritative append-only store, including revocations. Restrict write access and preserve its audit logs outside this repository.
- Re-identification keys, names, contact details, signatures, identity documents, and raw age-verification data must not enter training artifacts.
- Legal review must determine applicable biometric, employment, education, health, consumer, state, national, and cross-border requirements before external collection or deployment.
