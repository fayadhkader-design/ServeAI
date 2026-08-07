# ServeAI Release Checklist

## Verified locally

- [x] Release configuration compiles for a generic iOS device.
- [x] Store-style bundle validation succeeds.
- [x] App Icon is compiled into the Release bundle.
- [x] Camera, microphone, and Photos permission descriptions are present.
- [x] A valid no-tracking/no-collection privacy manifest is present at the app-bundle root.
- [x] The build declares no non-exempt encryption.
- [x] Evaluation-only model artifacts are excluded and guarded in Release.
- [x] Training/release pipeline regression tests pass.
- [x] Annotation portal regression tests pass.

## Device validation

- [ ] Grant the Apple Development private key to Apple signing tools.
- [ ] Run `PoseCalibrationIntegrationTests.testPoseCropCalibrationEvidence` on the connected iPhone.
- [ ] Preserve and inspect the JSON calibration attachment.
- [ ] Run the full native test suite on the physical iPhone.
- [ ] Perform manual camera, Photos import, processing, report, history, deletion, permissions, VoiceOver, Dynamic Type, and Reduce Motion smoke tests.

## App Store Connect

- [ ] Confirm active paid Apple Developer Program membership and agreements.
- [x] Create the ServeAI app record using bundle ID `com.serveai.app`.
- [x] Verify the deployed privacy policy and support pages at the GitHub Pages HTTPS URLs recorded in `APP_STORE_COPY.md` (HTTP 200 with matching local content on August 7, 2026).
- [x] Replace every placeholder in the local policy/support copy without publishing private contact information.
- [ ] Complete App Privacy as “Data Not Collected” only if the shipped build still has no transmission or third-party collection.
- [ ] Complete age rating, content rights, category, DSA trader status, export-compliance, and availability questions.
- [ ] Capture final required iPhone screenshots from the signed Release candidate.
- [x] Archive, validate, and upload build 3.
- [ ] Add App Review contact details and the prepared review notes.
- [ ] Test through internal TestFlight before requesting external TestFlight or App Review.

## Model truthfulness gate

- [x] Release defaults to the on-device Vision heuristic.
- [x] Reports distinguish video evidence from model correctness.
- [x] Unvalidated models cannot claim production validation.
- [ ] A trained model must not replace the heuristic until the signed held-out-player, subgroup, repeatability, rights, and coach-ground-truth gates all pass.
