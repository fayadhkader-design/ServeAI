from __future__ import annotations

import http.cookiejar
import copy
import hashlib
import json
import os
import sqlite3
import subprocess
import tempfile
import threading
import unittest
import urllib.parse
import urllib.request
import uuid
import zipfile
from io import BytesIO
from pathlib import Path

import AnnotationPortal.storage as storage
from AnnotationPortal.server import PortalApplication, PortalConfiguration, PortalHandler
from AnnotationPortal.storage import PortalStore
from AnnotationPortal.workflow import RegistryConfiguration, WorkflowError, _uuid_text, inspect_video
from coach_auth import sign_artifact, sign_registry_payload
from task_coordinator_auth import sign_task_coordinator_registry_payload
from test_adjudication import resolution
from test_training_pipeline import attach_signed_labeling_task, package
from Training.generate_capture_plan import build_plan
from Training.coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING
from http.server import ThreadingHTTPServer


class PortalStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="serveai-portal-test-")
        self.original_iterations = storage.PBKDF2_ITERATIONS
        storage.PBKDF2_ITERATIONS = 1_000
        self.store = PortalStore(Path(self.temporary.name) / "portal.sqlite3")

    def tearDown(self) -> None:
        storage.PBKDF2_ITERATIONS = self.original_iterations
        self.temporary.cleanup()

    def test_tokens_are_hashed_and_authentication_is_constant_contract(self) -> None:
        token = self.store.create_user("coordinator-001", "coordinator")
        with self.store.connect() as database:
            row = database.execute("SELECT token_hash, token_salt FROM users").fetchone()
        self.assertNotIn(token.encode(), bytes(row["token_hash"]))
        self.assertEqual(len(row["token_salt"]), 16)
        self.assertIsNotNone(self.store.authenticate("coordinator-001", token))
        self.assertIsNone(self.store.authenticate("coordinator-001", "wrong"))
        self.assertIsNone(self.store.authenticate("missing-user", "wrong"))

    def test_session_csrf_and_explicit_role(self) -> None:
        token = self.store.create_user("coach-001", "coach")
        coach = self.store.authenticate("coach-001", token)
        session, csrf = self.store.create_session(coach["id"])
        signed_in = self.store.session_user(session)
        self.assertEqual(signed_in["role"], "coach")
        self.assertTrue(self.store.verify_csrf(signed_in, csrf))
        self.assertFalse(self.store.verify_csrf(signed_in, "wrong"))

    def test_double_assignment_progress_and_append_only_audit(self) -> None:
        coordinator_token = self.store.create_user("coordinator-001", "coordinator")
        coach_a_token = self.store.create_user("coach-001", "coach")
        coach_b_token = self.store.create_user("coach-002", "coach")
        coordinator = self.store.authenticate("coordinator-001", coordinator_token)
        coach_a = self.store.authenticate("coach-001", coach_a_token)
        coach_b = self.store.authenticate("coach-002", coach_b_token)
        record = {
            "task_id": "7a0abdd3-97fe-4e46-84fa-0b72ee5b3270",
            "analysis_id": "6cf70f32-dfb5-40fb-a1b4-1ff188fb4d30",
            "coordinator_pseudonym": "coordinator-001",
            "source_video_filename": "serve.mov",
            "source_video_sha256": "a" * 64,
            "camera_angle": "side",
            "skill_level": "advanced",
            "signer_key_id": "b" * 64,
            "task_path": str(Path(self.temporary.name) / "task.json"),
            "video_path": str(Path(self.temporary.name) / "video.mov"),
            "video_mime": "video/quicktime",
        }
        self.store.add_task(record, coordinator["id"])
        self.store.assign(record["task_id"], coach_a["id"], coordinator["id"])
        self.store.assign(record["task_id"], coach_b["id"], coordinator["id"])
        with self.assertRaisesRegex(ValueError, "two independent"):
            self.store.assign(record["task_id"], coach_a["id"], coordinator["id"])
        task = self.store.task(record["task_id"], coordinator)
        self.assertEqual(task["workflow_status"], "Assigned")
        self.assertEqual(task["assignment_count"], 2)
        valid, count = self.store.verify_audit_chain()
        self.assertTrue(valid)
        self.assertGreaterEqual(count, 6)
        with self.assertRaises(sqlite3.IntegrityError):
            with self.store.connect() as database:
                database.execute("UPDATE audit_events SET action = 'tampered' WHERE id = 1")

    def test_path_identity_and_video_container_reject_traversal_or_disguise(self) -> None:
        with self.assertRaises(WorkflowError):
            _uuid_text("../../escape", "task ID")
        valid_header = b"\x00\x00\x00\x18ftypqt  " + b"payload"
        self.assertEqual(inspect_video("serve.mov", valid_header), "video/quicktime")
        with self.assertRaises(WorkflowError):
            inspect_video("serve.mov", b"not a video")
        with self.assertRaises(WorkflowError):
            inspect_video("serve.exe", valid_header)

    def test_capture_slot_can_only_be_imported_once(self) -> None:
        coordinator_token = self.store.create_user("coordinator-001", "coordinator")
        coordinator = self.store.authenticate("coordinator-001", coordinator_token)
        record = {
            "task_id": "7a0abdd3-97fe-4e46-84fa-0b72ee5b3270",
            "analysis_id": "6cf70f32-dfb5-40fb-a1b4-1ff188fb4d30",
            "coordinator_pseudonym": "coordinator-001",
            "source_video_filename": "serve.mov",
            "source_video_sha256": "a" * 64,
            "camera_angle": "side",
            "skill_level": "advanced",
            "capture_plan_id": "serveai-target-domain-pilot-v1",
            "capture_plan_sha256": "b" * 64,
            "capture_slot_id": "slot-001",
            "participant_pseudonym": "participant-001",
            "split": "train",
            "signer_key_id": "c" * 64,
            "task_path": str(Path(self.temporary.name) / "task-1.json"),
            "video_path": str(Path(self.temporary.name) / "video-1.mov"),
            "video_mime": "video/quicktime",
        }
        self.store.add_task(record, coordinator["id"])

        duplicate = dict(record)
        duplicate["task_id"] = "91f5ec63-e5b1-48cc-8452-bc3a8c99b3be"
        duplicate["analysis_id"] = "c25d2d8e-d3e2-4821-98ac-bff43b5d75d1"
        duplicate["task_path"] = str(Path(self.temporary.name) / "task-2.json")
        duplicate["video_path"] = str(Path(self.temporary.name) / "video-2.mov")
        with self.assertRaises(sqlite3.IntegrityError):
            self.store.add_task(duplicate, coordinator["id"])

        with self.store.connect() as database:
            indexes = {
                row["name"] for row in database.execute("PRAGMA index_list(tasks)").fetchall()
            }
        self.assertIn("tasks_capture_slot_unique", indexes)


class CapturePlanTests(unittest.TestCase):
    def test_plan_meets_collection_floors_without_split_leakage(self) -> None:
        plan = build_plan()
        slots = plan["slots"]
        self.assertEqual(len(slots), 300)
        participants: dict[str, set[str]] = {}
        for slot in slots:
            participants.setdefault(slot["participantPseudonym"], set()).add(slot["split"])
        self.assertEqual(len(participants), 60)
        self.assertTrue(all(len(splits) == 1 for splits in participants.values()))
        self.assertEqual(plan["plannedCounts"]["split"], {"test": 60, "train": 180, "validation": 60})
        self.assertGreaterEqual(plan["plannedCounts"]["dominantHand"]["left"], 30)
        self.assertTrue(all(value >= 10 for value in plan["plannedCounts"]["recordingIssue"].values()))
        test = [slot for slot in slots if slot["split"] == "test"]
        self.assertGreaterEqual(len({slot["participantPseudonym"] for slot in test}), 10)
        for key, values in {
            "cameraAngle": {"side", "rear"},
            "skillLevel": {"beginner", "intermediate", "advanced", "competitive"},
            "dominantHand": {"left", "right"},
            "lighting": {"evenDaylight", "harshSun", "indoorBright", "lowLight"},
            "resolution": {"720p", "1080p", "4k"},
            "frameRate": {"30fps", "60fps", "120fps"},
        }.items():
            self.assertEqual({slot[key] for slot in test}, values)

    def test_portal_css_avoids_known_trust_and_readability_regressions(self) -> None:
        css = (Path(__file__).resolve().parents[1] / "static" / "styles.css").read_text()
        self.assertNotIn("repeating-linear-gradient", css)
        self.assertNotIn("border-left: 4px", css)
        self.assertNotIn("letter-spacing: -.05", css)
        self.assertIn(":focus-visible", css)
        self.assertIn("prefers-reduced-motion", css)


class CryptographicAdjudicationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="serveai-portal-crypto-")
        self.directory = Path(self.temporary.name)
        self.original_iterations = storage.PBKDF2_ITERATIONS
        storage.PBKDF2_ITERATIONS = 1_000
        self.task_secret = "task-registry-secret-that-is-at-least-32-characters"
        self.coach_secret = "coach-registry-secret-that-is-distinct-and-long"
        self.previous_task_secret = os.environ.get("SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET")
        self.previous_coach_secret = os.environ.get("SERVEAI_COACH_REGISTRY_SECRET")
        os.environ["SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET"] = self.task_secret
        os.environ["SERVEAI_COACH_REGISTRY_SECRET"] = self.coach_secret

    def tearDown(self) -> None:
        storage.PBKDF2_ITERATIONS = self.original_iterations
        if self.previous_task_secret is None:
            os.environ.pop("SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET", None)
        else:
            os.environ["SERVEAI_TASK_COORDINATOR_REGISTRY_SECRET"] = self.previous_task_secret
        if self.previous_coach_secret is None:
            os.environ.pop("SERVEAI_COACH_REGISTRY_SECRET", None)
        else:
            os.environ["SERVEAI_COACH_REGISTRY_SECRET"] = self.previous_coach_secret
        self.temporary.cleanup()

    def keypair(self, name: str) -> tuple[Path, Path]:
        private = self.directory / f"{name}-private.pem"
        public = self.directory / f"{name}-public.pem"
        subprocess.run(
            [
                "openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                "ec_paramgen_curve:P-256", "-out", str(private),
            ],
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(private), "-pubout", "-out", str(public)],
            check=True,
            capture_output=True,
        )
        return private, public

    def signed_artifact_bytes(self, value: dict, coach: str, private_key: Path, name: str) -> tuple[bytes, bytes]:
        path = self.directory / f"{name}.json"
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        signature_path = sign_artifact(path, coach, private_key)
        return path.read_bytes(), signature_path.read_bytes()

    def test_full_signed_adjudication_chain_exports_reverified_bundle(self) -> None:
        video = b"\x00\x00\x00\x18ftypqt  " + b"real-ball-serve-video"
        video_hash = hashlib.sha256(video).hexdigest()
        analysis_id = str(uuid.uuid4())

        first = package(coach="coach-a", participant="participant-001", priority="legDriveTiming")
        first["analysisID"] = analysis_id
        first["annotationID"] = str(uuid.uuid4())
        first["modelFeatureEvidence"]["provenance"]["videoSHA256"] = video_hash
        attach_signed_labeling_task(first)
        task_manifest = first["labelingTask"]
        second = package(coach="coach-b", participant="participant-001", priority="contactReach")
        second["analysisID"] = analysis_id
        second["annotationID"] = str(uuid.uuid4())
        second["modelFeatureEvidence"] = copy.deepcopy(first["modelFeatureEvidence"])
        second["modelReport"] = copy.deepcopy(first["modelReport"])
        second["cameraAngle"] = first["cameraAngle"]
        second["skillLevel"] = first["skillLevel"]
        second["participantPseudonym"] = first["participantPseudonym"]
        second["collectionMetadata"] = copy.deepcopy(first["collectionMetadata"])
        second["labelingTask"] = copy.deepcopy(task_manifest)

        private_keys: dict[str, Path] = {}
        coach_entries = []
        for coach in ("coach-a", "coach-b", "coach-c"):
            private, public = self.keypair(coach)
            private_keys[coach] = private
            coach_entries.append(
                {
                    "coachID": coach,
                    "status": "active",
                    "qualification": f"Verified test qualification for {coach}",
                    "expiresAt": "2099-01-01T00:00:00Z",
                    "publicKeyPEM": public.read_text(),
                }
            )
        coach_registry_path = self.directory / "coach-registry.json"
        coach_registry_path.write_text(
            json.dumps(
                sign_registry_payload(
                    {
                        "schemaVersion": 1,
                        "registryID": "portal-coaches",
                        "issuedAt": "2026-07-26T00:00:00Z",
                        "coaches": coach_entries,
                    },
                    self.coach_secret.encode(),
                )
            )
        )
        task_signature = task_manifest["signature"]
        task_registry_path = self.directory / "task-registry.json"
        task_registry_path.write_text(
            json.dumps(
                sign_task_coordinator_registry_payload(
                    {
                        "schemaVersion": 1,
                        "registryID": "portal-task-coordinators",
                        "issuedAt": "2026-07-26T00:00:00Z",
                        "coordinators": [
                            {
                                "coordinatorID": "coordinator-a",
                                "status": "active",
                                "organization": "ServeAI test study",
                                "role": "Collection coordinator",
                                "authorizedFrom": "2026-07-26T00:00:00Z",
                                "expiresAt": "2099-01-01T00:00:00Z",
                                "signerKeyID": task_signature["signerKeyID"],
                                "publicKeyX963": task_signature["publicKeyX963"],
                            }
                        ],
                    },
                    self.task_secret.encode(),
                )
            )
        )
        app = PortalApplication(
            PortalConfiguration(
                self.directory / "portal-data",
                RegistryConfiguration(task_registry_path, coach_registry_path),
            )
        )
        user_tokens = {
            identity: app.store.create_user(identity, role)
            for identity, role in (
                ("coordinator-001", "coordinator"),
                ("coach-a", "coach"),
                ("coach-b", "coach"),
                ("coach-c", "coach"),
            )
        }
        users = {
            identity: app.store.authenticate(identity, token)
            for identity, token in user_tokens.items()
        }
        task_id = app.import_task(
            users["coordinator-001"],
            json.dumps(task_manifest).encode(),
            "task.json",
            video,
            "serve.mov",
        )
        for coach in ("coach-a", "coach-b"):
            app.store.assign(task_id, users[coach]["id"], users["coordinator-001"]["id"])
        for coach, annotation in (("coach-a", first), ("coach-b", second)):
            annotation_data, signature_data = self.signed_artifact_bytes(
                annotation, coach, private_keys[coach], f"annotation-{coach}"
            )
            task = app.store.task(task_id, users[coach])
            app.submit_annotation(
                users[coach], task, annotation_data, "annotation.json",
                signature_data, "annotation.signature.json",
            )

        with self.assertRaisesRegex(ValueError, "independent from both source coaches"):
            app.store.assign_adjudicator(
                task_id, users["coach-a"]["id"], users["coordinator-001"]["id"]
            )
        app.store.assign_adjudicator(
            task_id, users["coach-c"]["id"], users["coordinator-001"]["id"]
        )
        decision = resolution(adjudicator="coach-c")
        decision["adjudicationID"] = str(uuid.uuid4())
        decision["analysisID"] = analysis_id
        decision["sourceAnnotationIDs"] = [first["annotationID"], second["annotationID"]]
        decision_data, decision_signature = self.signed_artifact_bytes(
            decision, "coach-c", private_keys["coach-c"], "adjudication"
        )
        adjudicator_task = app.store.task(task_id, users["coach-c"])
        app.submit_adjudication(
            users["coach-c"], adjudicator_task, decision_data, "adjudication.json",
            decision_signature, "adjudication.signature.json",
        )
        adjudicator_task = app.store.task(task_id, users["coach-c"])
        ground_truth_path = Path(adjudicator_task["adjudication"]["ground_truth_path"])
        ground_truth_signature_path = sign_artifact(
            ground_truth_path, "coach-c", private_keys["coach-c"],
            self.directory / "ground-truth.signature.json",
        )
        app.complete_ground_truth_signature(
            users["coach-c"], adjudicator_task,
            ground_truth_signature_path.read_bytes(), "ground-truth.signature.json",
        )

        coordinator_task = app.store.task(task_id, users["coordinator-001"])
        self.assertEqual(coordinator_task["workflow_status"], "Ground truth verified")
        bundle = app.evidence_bundle(users["coordinator-001"], coordinator_task)
        with zipfile.ZipFile(BytesIO(bundle)) as archive:
            names = set(archive.namelist())
            manifest = json.loads(archive.read("manifest.json"))
        self.assertIn("ground-truth/ground-truth.json", names)
        self.assertIn("ground-truth/ground-truth.signature.json", names)
        self.assertFalse(manifest["sourceVideoIncluded"])
        self.assertFalse(manifest["modelReleaseEligible"])
        self.assertEqual(manifest["sourceVideoSHA256"], video_hash)
        self.assertEqual(manifest["capturePlanAssignment"]["slotID"], "slot-001")
        self.assertEqual(manifest["capturePlanAssignment"]["participantPseudonym"], "participant-001")
        valid, event_count = app.store.verify_audit_chain()
        self.assertTrue(valid)
        self.assertGreaterEqual(event_count, 13)
        tampered = json.loads(ground_truth_path.read_text())
        tampered["topPriority"] = "landingBalance"
        ground_truth_path.write_text(json.dumps(tampered, indent=2, sort_keys=True) + "\n")
        with self.assertRaisesRegex(WorkflowError, "differs from the verified adjudication"):
            app.evidence_bundle(users["coordinator-001"], app.store.task(task_id, users["coordinator-001"]))


class PortalHTTPTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="serveai-portal-http-")
        self.original_iterations = storage.PBKDF2_ITERATIONS
        storage.PBKDF2_ITERATIONS = 1_000
        data = Path(self.temporary.name)
        configuration = PortalConfiguration(data, RegistryConfiguration(None, None))
        self.application = PortalApplication(configuration)
        self.token = self.application.store.create_user("coordinator-001", "coordinator")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), PortalHandler)
        self.server.application = self.application
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.jar = http.cookiejar.CookieJar()
        self.client = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        storage.PBKDF2_ITERATIONS = self.original_iterations
        self.temporary.cleanup()

    def test_login_security_headers_and_locked_dashboard(self) -> None:
        request = urllib.request.Request(
            self.base + "/login",
            data=urllib.parse.urlencode({"pseudonym": "coordinator-001", "token": self.token}).encode(),
            method="POST",
        )
        response = self.client.open(request)
        body = response.read().decode()
        self.assertEqual(response.geturl(), self.base + "/dashboard")
        self.assertIn("Pilot is running in locked mode", body)
        self.assertIn("frame-ancestors 'none'", response.headers["Content-Security-Policy"])
        session = next(cookie for cookie in self.jar if cookie.name == "serveai_session")
        self.assertTrue(session.has_nonstandard_attr("HttpOnly"))
        self.assertIn("0.92 MAE", body)
        self.assertIn("46% exact", body)

    def test_csrf_rejects_state_change(self) -> None:
        login = urllib.request.Request(
            self.base + "/login",
            data=urllib.parse.urlencode({"pseudonym": "coordinator-001", "token": self.token}).encode(),
            method="POST",
        )
        self.client.open(login).read()
        request = urllib.request.Request(
            self.base + "/users",
            data=urllib.parse.urlencode({"pseudonym": "coach-001", "csrf": "wrong"}).encode(),
            method="POST",
        )
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.client.open(request)
        self.assertEqual(caught.exception.code, 403)
        caught.exception.close()

    def test_assigned_adjudicator_sees_bound_resolution_workflow(self) -> None:
        coordinator = self.application.store.authenticate("coordinator-001", self.token)
        coach_tokens = {
            coach: self.application.store.create_user(coach, "coach", coordinator["id"])
            for coach in ("coach-a", "coach-b", "coach-c")
        }
        coaches = {
            coach: self.application.store.authenticate(coach, token)
            for coach, token in coach_tokens.items()
        }
        task_id = "7a0abdd3-97fe-4e46-84fa-0b72ee5b3270"
        data = Path(self.temporary.name)
        task_path = data / "task.json"
        video_path = data / "video.mov"
        task_path.write_text("{}")
        video_path.write_bytes(b"\x00\x00\x00\x18ftypqt  fake")
        self.application.store.add_task(
            {
                "task_id": task_id,
                "analysis_id": "6cf70f32-dfb5-40fb-a1b4-1ff188fb4d30",
                "coordinator_pseudonym": "coordinator-001",
                "source_video_filename": "serve.mov",
                "source_video_sha256": "a" * 64,
                "camera_angle": "side",
                "skill_level": "advanced",
                "signer_key_id": "b" * 64,
                "task_path": str(task_path),
                "video_path": str(video_path),
                "video_mime": "video/quicktime",
            },
            coordinator["id"],
        )
        for index, coach in enumerate(("coach-a", "coach-b"), start=1):
            self.application.store.assign(task_id, coaches[coach]["id"], coordinator["id"])
            annotation_path = data / f"annotation-{coach}.json"
            signature_path = data / f"annotation-{coach}.signature.json"
            annotation_path.write_text(
                json.dumps(
                    {
                        "annotationID": f"00000000-0000-0000-0000-00000000000{index}",
                        "annotatorPseudonym": coach,
                        "phaseBoundaries": [],
                        "techniqueRatings": [],
                        "topPriority": "legDriveTiming" if index == 1 else "contactReach",
                    }
                )
            )
            signature_path.write_text("{}")
            self.application.store.add_submission(
                {
                    "task_id": task_id,
                    "annotation_id": f"00000000-0000-0000-0000-00000000000{index}",
                    "annotation_path": str(annotation_path),
                    "signature_path": str(signature_path),
                },
                coaches[coach]["id"],
            )
        self.application.store.assign_adjudicator(
            task_id, coaches["coach-c"]["id"], coordinator["id"]
        )
        request = urllib.request.Request(
            self.base + "/login",
            data=urllib.parse.urlencode(
                {"pseudonym": "coach-c", "token": coach_tokens["coach-c"]}
            ).encode(),
            method="POST",
        )
        response = self.client.open(request)
        response.read()
        task_response = self.client.open(self.base + f"/tasks/{task_id}")
        body = task_response.read().decode()
        self.assertIn("Resolve the source labels", body)
        self.assertIn("Download pre-bound template", body)
        self.assertIn("Verify and compile ground truth", body)
        self.assertIn("Independent comparison", body)
        template_response = self.client.open(
            self.base + f"/tasks/{task_id}/adjudication-template"
        )
        template = json.loads(template_response.read())
        self.assertEqual(template["schemaVersion"], 3)
        self.assertEqual(template["rubric"], CURRENT_RUBRIC_BINDING)


if __name__ == "__main__":
    unittest.main()
