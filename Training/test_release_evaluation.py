import argparse
import base64
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

import evaluate_release_candidate as candidate
import sign_validated_model_release as signer
from coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from capture_plan import CURRENT_BINDING as CURRENT_CAPTURE_PLAN_BINDING, SLOTS_BY_ID


class ReleaseCandidateEvaluationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.compiled_model = self.root / "Validated.mlmodelc"
        self.compiled_model.write_bytes(b"frozen compiled model")
        self.model_hash = signer.sha256_artifact(self.compiled_model)
        self.identity = {
            "modelIdentifier": "serveai.synthetic-release-candidate",
            "modelVersion": "1.0.0-test",
        }
        self.dataset_path = self.root / "dataset.json"
        self.research_model_path = self.root / "research-model.json"
        self.offline_path = self.root / "offline.json"
        self.repeatability_path = self.root / "repeatability.json"
        self.parity_path = self.root / "parity.json"
        self.rights_path = self.root / "rights.json"
        self.write_passing_evidence()

    def tearDown(self):
        self.temporary.cleanup()

    def write_json(self, path, value):
        path.write_text(json.dumps(value, sort_keys=True))

    def record(self, *, analysis, video_hash, slot_id, index=0):
        slot = SLOTS_BY_ID[slot_id]
        participant = slot["participantPseudonym"]
        split = slot["split"]
        camera_angle = slot["cameraAngle"]
        skill_level = slot["skillLevel"]
        adjudicated = index % 2 == 0
        provenance = {
            "kind": "signedThirdCoachAdjudication" if adjudicated else "exactDoubleCoachAgreement",
            "sourceAnnotationIDs": [f"{analysis}-a", f"{analysis}-b"],
            "sourceCoachIDs": ["coach-a", "coach-b"],
            "consentRecordID": f"consent-{analysis}",
            "consentReceiptID": f"receipt-{analysis}",
        }
        if adjudicated:
            provenance["adjudicatorPseudonym"] = "coach-c"
        return {
            "analysisID": analysis,
            "participantPseudonym": participant,
            "split": split,
            "cameraAngle": camera_angle,
            "skillLevel": skill_level,
            "cohorts": {
                "cameraAngle": camera_angle,
                "skillLevel": skill_level,
                "dominantHand": ("right", "left")[index % 2],
                "lighting": ("evenDaylight", "indoorBright")[index % 2],
                "resolution": ("1080p", "720p")[index % 2],
                "frameRate": ("60fps", "30fps")[index % 2],
            },
            "sourceVideoSHA256": video_hash,
            "featureEvidenceDigest": f"{index + 1000:064x}",
            "consentProvenance": {
                "consentRecordID": f"consent-{analysis}",
                "consentReceiptID": f"receipt-{analysis}",
            },
            "portableTaskProvenance": {
                "status": "LOCAL SAME-DEVICE LABELING — no portable task",
            },
            "labelProvenance": provenance,
            "rubric": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanProvenance": {
                "status": "PINNED — signed task matches frozen capture plan",
                "plan": dict(CURRENT_CAPTURE_PLAN_BINDING),
                "slotID": slot_id,
                "participantPseudonym": participant,
                "split": split,
            },
        }

    def write_passing_evidence(self, *, priority=0.90, wrong_repeatability_video=False):
        records = [
            self.record(
                analysis="train-1", video_hash=f"{9001:064x}", slot_id="slot-001", index=101,
            ),
            self.record(
                analysis="validation-1", video_hash=f"{9002:064x}", slot_id="slot-181", index=102,
            ),
        ]
        test_records = []
        for player_index in range(12):
            for serve_index in range(5):
                index = player_index * 5 + serve_index
                test_records.append(self.record(
                    analysis=f"test-{index}",
                    video_hash=f"{index + 1:064x}",
                    slot_id=f"slot-{241 + index:03d}",
                    index=index,
                ))
        records.extend(test_records)
        dataset_digest = candidate.canonical_digest(records)
        self.write_json(self.dataset_path, {
            "schemaVersion": 3,
            "trainingEligible": True,
            "modelReleaseEligible": False,
            "datasetDigest": dataset_digest,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "records": records,
        })
        self.write_json(self.research_model_path, {
            "schemaVersion": 1,
            **self.identity,
            "trainingDatasetDigest": dataset_digest,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "releaseEligible": False,
        })
        metrics = {
            "clipCount": 60,
            "playerCount": 12,
            "qualityPrecision": 0.95,
            "qualityRecall": 0.95,
            "boundaryMeanAbsoluteErrorSeconds": 0.08,
            "phaseVisibilityF1": 0.90,
            "techniqueRatingMeanAbsoluteError": 0.40,
            "priorityAgreement": priority,
            "priorityContract": candidate.PRIORITY_CONTRACT,
        }
        subgroups = {}
        for name in candidate.SUBGROUP_NAME_MAP:
            subgroups[name] = {}
            values = sorted({record["cohorts"][name] for record in test_records})
            for value in values:
                members = [record for record in test_records if record["cohorts"][name] == value]
                subgroups[name][value] = {
                    **metrics,
                    "clipCount": len(members),
                    "playerCount": len({record["participantPseudonym"] for record in members}),
                }
        self.write_json(self.offline_path, {
            "schemaVersion": 1,
            **self.identity,
            "trainingDatasetDigest": dataset_digest,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "test": metrics,
            "subgroups": subgroups,
            "failedMaterialSubgroups": [],
        })
        repeat_pairs = []
        for player_index in range(10):
            for serve_index in range(3):
                record = test_records[player_index * 5 + serve_index]
                repeat_pairs.append({
                    "analysisID": record["analysisID"],
                    "participantPseudonym": record["participantPseudonym"],
                    "sourceVideoSHA256": ("f" * 64 if wrong_repeatability_video and not repeat_pairs else record["sourceVideoSHA256"]),
                    "cameraAngle": record["cameraAngle"],
                    "skillLevel": record["skillLevel"],
                    "firstScore": 80,
                    "repeatedScore": 83,
                })
        self.write_json(self.repeatability_path, {
            "schemaVersion": 1,
            **self.identity,
            "modelSHA256": self.model_hash,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "appBuildIdentifier": "com.serveai.app/1.0(1)",
            "protocol": "same compiled model, app build, settings, and exact source video analyzed twice",
            "pairs": repeat_pairs,
        })
        self.write_json(self.parity_path, {
            "schemaVersion": 2,
            **self.identity,
            "compiledModelSHA256": self.model_hash,
            "rubricContract": dict(CURRENT_RUBRIC_BINDING),
            "capturePlanContract": dict(CURRENT_CAPTURE_PLAN_BINDING),
            "sampleCount": 60,
            "maximumAbsoluteError": 0.00001,
            "passes": True,
        })
        self.write_json(self.rights_path, {
            "schemaVersion": 1,
            **self.identity,
            "commercialUseCleared": True,
            "trainingSources": [{
                "sourceIdentifier": "consented-first-party-data",
                "licenseIdentifier": "ServeAI-training-consent-v1",
                "evidenceSHA256": "a" * 64,
                "permitsCommercialModelTraining": True,
            }],
        })

    def build(self):
        return candidate.build_evaluation(
            compiled_model_path=self.compiled_model,
            research_model_path=self.research_model_path,
            dataset_path=self.dataset_path,
            offline_evaluation_path=self.offline_path,
            repeatability_path=self.repeatability_path,
            parity_path=self.parity_path,
            rights_path=self.rights_path,
        )

    def write_signed_task(self, *, record, run_id, task_id, score, private_key, public_x963):
        payload = {
            "schemaVersion": 1,
            "taskID": task_id,
            "analysisID": run_id,
            "createdAt": "2026-07-26T12:00:00Z",
            "coordinatorPseudonym": "coordinator-release-test",
            "sourceVideoFilename": f"{record['analysisID']}.mov",
            "sourceVideoSHA256": record["sourceVideoSHA256"],
            "analysis": {
                "id": run_id,
                "createdAt": "2026-07-26T12:00:00Z",
                "overallScore": score,
                "skillLevel": record["skillLevel"],
                "cameraAngle": record["cameraAngle"],
                "source": "experimentalCoreML",
                "modelFeatureEvidence": {
                    "provenance": {"videoSHA256": record["sourceVideoSHA256"]},
                },
                "modelTrace": {
                    **self.identity,
                    "modelArtifactSHA256": self.model_hash,
                    "validatedReleaseVerified": False,
                    "appBuildIdentifier": "com.serveai.app/1.0(42)",
                },
            },
        }
        content = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
        payload_path = self.root / f"{task_id}.payload"
        signature_path = self.root / f"{task_id}.sig"
        payload_path.write_bytes(content)
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(private_key), "-out", str(signature_path), str(payload_path)],
            check=True, capture_output=True,
        )
        return {
            "schemaVersion": 1,
            "payload": payload,
            "signature": {
                "algorithm": "ECDSA-P256-SHA256",
                "signerKeyID": hashlib.sha256(public_x963).hexdigest(),
                "publicKeyX963": base64.b64encode(public_x963).decode(),
                "signedContentSHA256": hashlib.sha256(content).hexdigest(),
                "signatureDER": base64.b64encode(signature_path.read_bytes()).decode(),
            },
        }

    def test_complete_frozen_evidence_builds_signer_compatible_report(self):
        report = self.build()

        self.assertTrue(report["releaseEligible"])
        self.assertEqual(report["schemaVersion"], 4)
        self.assertEqual(report["rubric"], CURRENT_RUBRIC_BINDING)
        self.assertEqual(report["failedCriteria"], [])
        self.assertEqual(report["design"]["repeatabilityPairCount"], 30)
        self.assertEqual(report["design"]["repeatabilityPlayerCount"], 10)
        self.assertEqual(signer.evaluation_failures(report), [])

    def test_production_signer_rebuilds_from_signed_runs_and_rejects_one_changed_score(self):
        task_key = self.root / "task-key.pem"
        task_public_der = self.root / "task-public.der"
        release_key = self.root / "release-key.pem"
        for key in (task_key, release_key):
            subprocess.run(
                ["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256", "-out", str(key)],
                check=True, capture_output=True,
            )
        subprocess.run(
            ["openssl", "pkey", "-in", str(task_key), "-pubout", "-outform", "DER", "-out", str(task_public_der)],
            check=True, capture_output=True,
        )
        public_x963 = task_public_der.read_bytes()[-65:]
        registry = {
            "coordinator-release-test": {
                "coordinatorID": "coordinator-release-test",
                "organization": "ServeAI release test",
                "role": "Repeatability coordinator",
                "authorizedFrom": "2026-07-26T00:00:00Z",
                "expiresAt": "2099-01-01T00:00:00Z",
                "signerKeyID": hashlib.sha256(public_x963).hexdigest(),
                "publicKeyX963": base64.b64encode(public_x963).decode(),
            },
        }
        registry_path = self.root / "signed-task-registry.json"
        registry_path.write_text(json.dumps({"testFixture": True}))
        dataset = json.loads(self.dataset_path.read_text())
        test_records = [record for record in dataset["records"] if record["split"] == "test"]
        selected = [test_records[player * 5 + serve] for player in range(10) for serve in range(3)]
        pairs = []
        first_task_path = None
        for index, record in enumerate(selected):
            paths = []
            for suffix, score in (("first", 80), ("repeat", 83)):
                task_id = f"task-{index}-{suffix}"
                run_id = f"run-{index}-{suffix}"
                path = self.root / f"{task_id}.json"
                path.write_text(json.dumps(self.write_signed_task(
                    record=record,
                    run_id=run_id,
                    task_id=task_id,
                    score=score,
                    private_key=task_key,
                    public_x963=public_x963,
                )))
                paths.append(path)
                first_task_path = first_task_path or path
            pairs.append({
                "analysisID": record["analysisID"],
                "firstTask": paths[0].name,
                "repeatedTask": paths[1].name,
            })
        pair_manifest = self.root / "repeatability-pairs.json"
        pair_manifest.write_text(json.dumps({
            "schemaVersion": 1,
            "appBuildIdentifier": "com.serveai.app/1.0(42)",
            "pairs": pairs,
        }))
        evaluation_output = self.root / "DerivedEvaluation.json"
        envelope_output = self.root / "SignedRelease.json"
        args = argparse.Namespace(
            model=self.compiled_model,
            research_model=self.research_model_path,
            dataset=self.dataset_path,
            offline_evaluation=self.offline_path,
            repeatability_pair_manifest=pair_manifest,
            task_coordinator_registry=registry_path,
            coreml_parity=self.parity_path,
            rights_evidence=self.rights_path,
            evaluation_output=evaluation_output,
            private_key=release_key,
            issued_at="2026-07-26T20:00:00Z",
            output=envelope_output,
        )

        evaluation, evaluation_bytes, envelope, _ = signer.create_release_from_evidence(
            args, verified_task_registry=registry
        )

        self.assertTrue(evaluation["releaseEligible"])
        self.assertEqual(
            evaluation["evidenceGeneration"]["repeatabilitySource"],
            "verified signed native task pairs",
        )
        payload = json.loads(base64.b64decode(envelope["payloadBase64"]))
        self.assertEqual(payload["evaluation"]["sha256"], hashlib.sha256(evaluation_bytes).hexdigest())
        self.assertFalse(evaluation_output.exists())
        self.assertFalse(envelope_output.exists())

        tampered = json.loads(first_task_path.read_text())
        tampered["payload"]["analysis"]["overallScore"] = 1
        first_task_path.write_text(json.dumps(tampered))
        with self.assertRaisesRegex(ValueError, "signed-content|signature"):
            signer.create_release_from_evidence(args, verified_task_registry=registry)

    def test_failed_priority_metric_produces_report_but_cannot_be_signed(self):
        self.write_passing_evidence(priority=0.74)

        report = self.build()

        self.assertFalse(report["releaseEligible"])
        self.assertIn("priorityAgreement", report["failedCriteria"])
        self.assertIn("metrics.priorityAgreement", signer.evaluation_failures(report))

    def test_offline_priority_metric_must_match_displayed_native_behavior(self):
        offline = json.loads(self.offline_path.read_text())
        offline["test"].pop("priorityContract")
        self.write_json(self.offline_path, offline)

        with self.assertRaisesRegex(candidate.EvaluationEvidenceError, "priority metric"):
            self.build()

    def test_tampered_rubric_is_rejected_before_release_evaluation(self):
        model = json.loads(self.research_model_path.read_text())
        model["rubricContract"]["version"] = "1.0.1"
        self.write_json(self.research_model_path, model)

        with self.assertRaisesRegex(candidate.EvaluationEvidenceError, "coach rubric"):
            self.build()

    def test_tampered_capture_plan_is_rejected_before_release_evaluation(self):
        dataset = json.loads(self.dataset_path.read_text())
        dataset["records"][0]["capturePlanProvenance"]["slotID"] = "slot-006"
        dataset["datasetDigest"] = candidate.canonical_digest(dataset["records"])
        model = json.loads(self.research_model_path.read_text())
        model["trainingDatasetDigest"] = dataset["datasetDigest"]
        offline = json.loads(self.offline_path.read_text())
        offline["trainingDatasetDigest"] = dataset["datasetDigest"]
        self.write_json(self.dataset_path, dataset)
        self.write_json(self.research_model_path, model)
        self.write_json(self.offline_path, offline)

        with self.assertRaisesRegex(candidate.EvaluationEvidenceError, "capture-plan provenance"):
            self.build()

    def test_recomputed_dataset_digest_cannot_substitute_for_trained_dataset(self):
        dataset = json.loads(self.dataset_path.read_text())
        dataset["records"][2]["participantPseudonym"] = "substituted-player"
        dataset["datasetDigest"] = candidate.canonical_digest(dataset["records"])
        self.write_json(self.dataset_path, dataset)

        with self.assertRaisesRegex(candidate.EvaluationEvidenceError, "trained model"):
            self.build()

    def test_repeatability_wrong_video_binding_fails_release(self):
        self.write_passing_evidence(wrong_repeatability_video=True)

        report = self.build()

        self.assertFalse(report["releaseEligible"])
        self.assertFalse(report["design"]["repeatabilityUsesExactSameVideo"])
        self.assertIn("repeatability source binding", report["failedCriteria"])

    def test_subgroup_counts_must_match_frozen_dataset(self):
        offline = json.loads(self.offline_path.read_text())
        subgroup = next(iter(offline["subgroups"]["lighting"].values()))
        subgroup["clipCount"] += 1
        self.write_json(self.offline_path, offline)

        with self.assertRaisesRegex(candidate.EvaluationEvidenceError, "counts do not match"):
            self.build()

    def test_undeclared_subgroup_failure_is_computed_from_metrics(self):
        offline = json.loads(self.offline_path.read_text())
        subgroup_name = next(iter(offline["subgroups"]["dominantHand"]))
        offline["subgroups"]["dominantHand"][subgroup_name]["priorityAgreement"] = 0.50
        offline["failedMaterialSubgroups"] = []
        self.write_json(self.offline_path, offline)

        report = self.build()

        self.assertFalse(report["releaseEligible"])
        self.assertIn("subgroup performance", report["failedCriteria"])

    def test_parity_report_must_bind_exact_compiled_artifact(self):
        parity = json.loads(self.parity_path.read_text())
        parity["compiledModelSHA256"] = "f" * 64
        self.write_json(self.parity_path, parity)

        with self.assertRaisesRegex(candidate.EvaluationEvidenceError, "compiled model"):
            self.build()


if __name__ == "__main__":
    unittest.main()
