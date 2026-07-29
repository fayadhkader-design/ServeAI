#!/usr/bin/env python3
"""ServeAI local research annotation portal.

This is a secure-by-default local pilot, not a public hosting stack. It binds to
loopback unless remote mode is explicitly acknowledged, applies same-origin
sessions and CSRF checks, and delegates cryptographic trust to the existing
ServeAI registry modules.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import io
import json
import os
import sqlite3
import sys
import tempfile
import threading
import urllib.parse
import zipfile
from dataclasses import dataclass
from datetime import datetime, timezone
from email import policy
from email.parser import BytesParser
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from AnnotationPortal.storage import PortalStore  # noqa: E402
from Training.coach_rubric import CURRENT_BINDING as CURRENT_RUBRIC_BINDING  # noqa: E402
from AnnotationPortal.workflow import (  # noqa: E402
    MAX_ANNOTATION_BYTES,
    MAX_TASK_BYTES,
    MAX_VIDEO_BYTES,
    RegistryConfiguration,
    WorkflowError,
    compare_submission_paths,
    verify_adjudication_upload,
    verify_annotation_upload,
    verify_completed_evidence,
    verify_ground_truth_signature_upload,
    verify_task_upload,
)


PROJECT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_DATA = Path(__file__).resolve().parent / "data"
STYLE_PATH = Path(__file__).resolve().parent / "static" / "styles.css"
FAVICON_PATH = Path(__file__).resolve().parent / "static" / "favicon.svg"
CAPTURE_PLAN_PATH = PROJECT_ROOT / "Training" / "artifacts" / "target_capture_plan.json"
RESEARCH_EVALUATION_PATH = PROJECT_ROOT / "Training" / "artifacts" / "thetis_pseudo_coach_evaluation.json"
MAX_REQUEST_BYTES = MAX_VIDEO_BYTES + MAX_ANNOTATION_BYTES + (2 * MAX_TASK_BYTES)


def e(value: object) -> str:
    return html.escape(str(value), quote=True)


def task_url(task_id: str) -> str:
    return "/tasks/" + urllib.parse.quote(task_id, safe="")


@dataclass(frozen=True)
class PortalConfiguration:
    data_directory: Path
    registries: RegistryConfiguration
    secure_cookie: bool = False


class PortalApplication:
    def __init__(self, configuration: PortalConfiguration):
        self.configuration = configuration
        self.data_directory = configuration.data_directory.resolve()
        self.data_directory.mkdir(parents=True, exist_ok=True)
        self.store = PortalStore(self.data_directory / "portal.sqlite3")
        self._notices: dict[str, dict[str, str]] = {}
        self._notice_lock = threading.Lock()

    def set_notice(self, user: dict, kind: str, message: str, token: str | None = None) -> None:
        with self._notice_lock:
            self._notices[user["session_hash"]] = {"kind": kind, "message": message, "token": token or ""}

    def pop_notice(self, user: dict) -> dict[str, str] | None:
        with self._notice_lock:
            return self._notices.pop(user["session_hash"], None)

    def import_task(
        self,
        user: dict,
        task_data: bytes,
        task_filename: str,
        video_data: bytes,
        video_filename: str,
    ) -> str:
        if Path(task_filename).suffix.lower() != ".json":
            raise WorkflowError("task manifest must be a .json file")
        task, record = verify_task_upload(task_data, video_filename, video_data, self.configuration.registries)
        directory = (self.data_directory / "tasks" / record["task_id"]).resolve()
        if self.data_directory not in directory.parents or directory.exists():
            raise WorkflowError("task already exists or its storage path is unsafe")
        directory.mkdir(parents=True)
        video_suffix = Path(video_filename).suffix.lower()
        task_path = directory / "task.json"
        video_path = directory / ("source" + video_suffix)
        self._atomic_write(task_path, json.dumps(task, indent=2, sort_keys=True).encode() + b"\n")
        self._atomic_write(video_path, video_data)
        record.update({"task_path": str(task_path), "video_path": str(video_path)})
        try:
            self.store.add_task(record, user["id"])
        except sqlite3.IntegrityError as error:
            raise WorkflowError("task or signed capture-plan slot is already registered") from error
        return record["task_id"]

    def submit_annotation(
        self,
        user: dict,
        task: dict,
        annotation_data: bytes,
        annotation_filename: str,
        signature_data: bytes,
        signature_filename: str,
    ) -> int:
        if Path(annotation_filename).suffix.lower() != ".json" or not signature_filename.endswith(".json"):
            raise WorkflowError("annotation and signature sidecar must both be JSON files")
        package, record = verify_annotation_upload(
            annotation_data, signature_data, user["pseudonym"], task, self.configuration.registries
        )
        directory = (self.data_directory / "submissions" / record["annotation_id"]).resolve()
        if self.data_directory not in directory.parents or directory.exists():
            raise WorkflowError("annotation already exists or its storage path is unsafe")
        directory.mkdir(parents=True)
        annotation_path = directory / "annotation.json"
        signature_path = directory / "annotation.signature.json"
        self._atomic_write(annotation_path, annotation_data)
        self._atomic_write(signature_path, signature_data)
        record.update(
            {
                "task_id": task["task_id"],
                "annotation_path": str(annotation_path),
                "signature_path": str(signature_path),
            }
        )
        try:
            return self.store.add_submission(record, user["id"])
        except sqlite3.IntegrityError as error:
            raise WorkflowError("this coach has already submitted a label for the task") from error

    def submit_adjudication(
        self,
        user: dict,
        task: dict,
        resolution_data: bytes,
        resolution_filename: str,
        signature_data: bytes,
        signature_filename: str,
    ) -> int:
        if Path(resolution_filename).suffix.lower() != ".json" or not signature_filename.endswith(".json"):
            raise WorkflowError("adjudication and signature sidecar must both be JSON files")
        resolution, ground_truth, record = verify_adjudication_upload(
            resolution_data,
            signature_data,
            user["pseudonym"],
            task,
            self.configuration.registries,
        )
        directory = (self.data_directory / "adjudications" / record["adjudication_id"]).resolve()
        if self.data_directory not in directory.parents or directory.exists():
            raise WorkflowError("adjudication already exists or its storage path is unsafe")
        directory.mkdir(parents=True)
        resolution_path = directory / "adjudication.json"
        resolution_signature_path = directory / "adjudication.signature.json"
        ground_truth_path = directory / "ground-truth.json"
        self._atomic_write(resolution_path, resolution_data)
        self._atomic_write(resolution_signature_path, signature_data)
        self._atomic_write(
            ground_truth_path,
            json.dumps(ground_truth, indent=2, sort_keys=True).encode("utf-8") + b"\n",
        )
        record.update(
            {
                "task_id": task["task_id"],
                "resolution_path": str(resolution_path),
                "resolution_signature_path": str(resolution_signature_path),
                "ground_truth_path": str(ground_truth_path),
            }
        )
        try:
            return self.store.add_adjudication(record, user["id"])
        except sqlite3.IntegrityError as error:
            raise WorkflowError("this task already has an adjudication") from error

    def complete_ground_truth_signature(
        self,
        user: dict,
        task: dict,
        signature_data: bytes,
        signature_filename: str,
    ) -> None:
        if not signature_filename.endswith(".json"):
            raise WorkflowError("ground-truth signature sidecar must be JSON")
        verify_ground_truth_signature_upload(
            signature_data,
            user["pseudonym"],
            task,
            self.configuration.registries,
        )
        adjudication = task["adjudication"]
        signature_path = Path(adjudication["ground_truth_path"]).with_suffix(".signature.json")
        self._atomic_write(signature_path, signature_data)
        self.store.complete_ground_truth(task["task_id"], str(signature_path), user["id"])

    def evidence_bundle(self, user: dict, task: dict) -> bytes:
        verify_completed_evidence(task, self.configuration.registries)
        files: dict[str, bytes] = {
            "task/task.json": Path(task["task_path"]).read_bytes(),
        }
        for submission in task["submissions"]:
            prefix = f"annotations/{submission['annotation_id']}"
            files[prefix + ".json"] = Path(submission["annotation_path"]).read_bytes()
            files[prefix + ".signature.json"] = Path(submission["signature_path"]).read_bytes()
        adjudication = task["adjudication"]
        files["adjudication/adjudication.json"] = Path(adjudication["resolution_path"]).read_bytes()
        files["adjudication/adjudication.signature.json"] = Path(
            adjudication["resolution_signature_path"]
        ).read_bytes()
        files["ground-truth/ground-truth.json"] = Path(adjudication["ground_truth_path"]).read_bytes()
        files["ground-truth/ground-truth.signature.json"] = Path(
            adjudication["ground_truth_signature_path"]
        ).read_bytes()
        manifest = {
            "schemaVersion": 1,
            "taskID": task["task_id"],
            "analysisID": task["analysis_id"],
            "sourceVideoIncluded": False,
            "sourceVideoSHA256": task["source_video_sha256"],
            "capturePlanAssignment": {
                "plan": {
                    "identifier": task["capture_plan_id"],
                    "sha256": task["capture_plan_sha256"],
                },
                "slotID": task["capture_slot_id"],
                "participantPseudonym": task["participant_pseudonym"],
                "split": task["split"],
            },
            "evidenceReverifiedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "files": {
                name: {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
                for name, data in sorted(files.items())
            },
            "modelReleaseEligible": False,
            "releaseBoundary": "Verified ground truth is training evidence, not proof that a model passed held-out release gates.",
        }
        files["manifest.json"] = json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8") + b"\n"
        output = io.BytesIO()
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, data in sorted(files.items()):
                info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o600 << 16
                archive.writestr(info, data)
        bundle = output.getvalue()
        self.store.record_export(task["task_id"], user["id"], hashlib.sha256(bundle).hexdigest())
        return bundle

    @staticmethod
    def _atomic_write(path: Path, data: bytes) -> None:
        with tempfile.NamedTemporaryFile(prefix=".incoming-", dir=path.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)


class PortalHandler(BaseHTTPRequestHandler):
    server_version = "ServeAIResearchPortal/2"

    @property
    def app(self) -> PortalApplication:
        return self.server.application  # type: ignore[attr-defined]

    def log_message(self, format: str, *args: object) -> None:
        sys.stderr.write("portal: " + format % args + "\n")

    def end_headers(self) -> None:
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self) -> None:  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        if path == "/static/styles.css":
            self._send_bytes(STYLE_PATH.read_bytes(), "text/css; charset=utf-8")
            return
        if path == "/favicon.ico" or path == "/static/favicon.svg":
            self._send_bytes(FAVICON_PATH.read_bytes(), "image/svg+xml")
            return
        user = self._current_user()
        if path == "/":
            if user:
                self._redirect("/dashboard")
            else:
                self._send_html(self._login_page())
            return
        if user is None:
            self._redirect("/")
            return
        if path == "/dashboard":
            self._send_html(self._dashboard(user))
        elif path == "/capture":
            self._send_html(self._capture_page(user))
        elif path.startswith("/tasks/"):
            self._task_get(path, user)
        elif path.startswith("/submissions/"):
            self._submission_get(path, user)
        else:
            self._error(404, "Page not found")

    def do_POST(self) -> None:  # noqa: N802
        path = urllib.parse.urlparse(self.path).path
        try:
            fields, files = self._read_form()
        except WorkflowError as error:
            self._error(400, str(error))
            return
        if path == "/login":
            self._login(fields)
            return
        user = self._current_user()
        if user is None:
            self._error(401, "Sign in required")
            return
        if not self.app.store.verify_csrf(user, fields.get("csrf")):
            self._error(403, "The form expired or failed its same-origin check. Reload and try again.")
            return
        try:
            if path == "/logout":
                self._logout()
            elif path == "/users":
                self._create_user(user, fields)
            elif path == "/tasks/import":
                self._import_task(user, files)
            elif path.startswith("/tasks/") and path.endswith("/assign"):
                self._assign(path, user, fields)
            elif path.startswith("/tasks/") and path.endswith("/assign-adjudicator"):
                self._assign_adjudicator(path, user, fields)
            elif path.startswith("/tasks/") and path.endswith("/submit"):
                self._submit(path, user, files)
            elif path.startswith("/tasks/") and path.endswith("/adjudicate"):
                self._adjudicate(path, user, files)
            elif path.startswith("/tasks/") and path.endswith("/sign-ground-truth"):
                self._sign_ground_truth(path, user, files)
            else:
                self._error(404, "Action not found")
        except (WorkflowError, ValueError, sqlite3.IntegrityError) as error:
            self.app.set_notice(user, "error", str(error))
            destination = "/dashboard"
            if path.startswith("/tasks/"):
                destination = path.rsplit("/", 1)[0]
            self._redirect(destination)

    def _login(self, fields: dict[str, str]) -> None:
        user = self.app.store.authenticate(fields.get("pseudonym", ""), fields.get("token", ""))
        if user is None:
            self._send_html(self._login_page("Pseudonym or access token is incorrect."), status=401)
            return
        session, csrf = self.app.store.create_session(user["id"])
        cookie = cookies.SimpleCookie()
        cookie["serveai_session"] = session
        cookie["serveai_session"]["httponly"] = True
        cookie["serveai_session"]["samesite"] = "Strict"
        cookie["serveai_session"]["path"] = "/"
        cookie["serveai_session"]["max-age"] = 12 * 60 * 60
        if self.app.configuration.secure_cookie:
            cookie["serveai_session"]["secure"] = True
        cookie["serveai_csrf"] = csrf
        cookie["serveai_csrf"]["samesite"] = "Strict"
        cookie["serveai_csrf"]["path"] = "/"
        cookie["serveai_csrf"]["max-age"] = 12 * 60 * 60
        self.send_response(303)
        for morsel in cookie.values():
            self.send_header("Set-Cookie", morsel.OutputString())
        self.send_header("Location", "/dashboard")
        self.end_headers()

    def _logout(self) -> None:
        self.app.store.destroy_session(self._cookie("serveai_session"))
        self.send_response(303)
        self.send_header("Set-Cookie", "serveai_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict")
        self.send_header("Set-Cookie", "serveai_csrf=; Path=/; Max-Age=0; SameSite=Strict")
        self.send_header("Location", "/")
        self.end_headers()

    def _create_user(self, user: dict, fields: dict[str, str]) -> None:
        self._require_role(user, "coordinator")
        token = self.app.store.create_user(fields.get("pseudonym", ""), "coach", user["id"])
        self.app.set_notice(
            user, "good", "Coach account created. Copy this access token now; it cannot be recovered.", token,
        )
        self._redirect("/dashboard")

    def _import_task(self, user: dict, files: dict[str, tuple[str, bytes]]) -> None:
        self._require_role(user, "coordinator")
        task_name, task_data = self._required_file(files, "task")
        video_name, video_data = self._required_file(files, "video")
        task_id = self.app.import_task(user, task_data, task_name, video_data, video_name)
        self.app.set_notice(user, "good", "Signed task and exact video imported. Assign two independent coaches next.")
        self._redirect(task_url(task_id))

    def _assign(self, path: str, user: dict, fields: dict[str, str]) -> None:
        self._require_role(user, "coordinator")
        task_id = urllib.parse.unquote(path[len("/tasks/") : -len("/assign")]).strip("/")
        self.app.store.assign(task_id, int(fields.get("coach_id", "0")), user["id"])
        self.app.set_notice(user, "good", "Coach assigned. The label remains independent until submission.")
        self._redirect(task_url(task_id))

    def _submit(self, path: str, user: dict, files: dict[str, tuple[str, bytes]]) -> None:
        self._require_role(user, "coach")
        task_id = urllib.parse.unquote(path[len("/tasks/") : -len("/submit")]).strip("/")
        task = self.app.store.task(task_id, user)
        if not task:
            raise WorkflowError("assigned task was not found")
        annotation_name, annotation_data = self._required_file(files, "annotation")
        signature_name, signature_data = self._required_file(files, "signature")
        self.app.submit_annotation(user, task, annotation_data, annotation_name, signature_data, signature_name)
        self.app.set_notice(
            user, "good", "Signature and schema verified. Submission is queued for independent comparison and adjudication.",
        )
        self._redirect(task_url(task_id))

    def _assign_adjudicator(self, path: str, user: dict, fields: dict[str, str]) -> None:
        self._require_role(user, "coordinator")
        task_id = urllib.parse.unquote(
            path[len("/tasks/") : -len("/assign-adjudicator")]
        ).strip("/")
        self.app.store.assign_adjudicator(
            task_id, int(fields.get("coach_id", "0")), user["id"]
        )
        self.app.set_notice(
            user,
            "good",
            "Independent adjudicator assigned. Both source labels are now available only to that coach and the coordinator.",
        )
        self._redirect(task_url(task_id))

    def _adjudicate(self, path: str, user: dict, files: dict[str, tuple[str, bytes]]) -> None:
        self._require_role(user, "coach")
        task_id = urllib.parse.unquote(path[len("/tasks/") : -len("/adjudicate")]).strip("/")
        task = self.app.store.task(task_id, user)
        if not task or not task.get("is_adjudicator"):
            raise WorkflowError("active adjudication assignment was not found")
        resolution_name, resolution_data = self._required_file(files, "resolution")
        signature_name, signature_data = self._required_file(files, "signature")
        self.app.submit_adjudication(
            user, task, resolution_data, resolution_name, signature_data, signature_name
        )
        self.app.set_notice(
            user,
            "good",
            "Adjudication verified. Download the compiled ground truth, sign its exact bytes, and upload the signature sidecar.",
        )
        self._redirect(task_url(task_id))

    def _sign_ground_truth(self, path: str, user: dict, files: dict[str, tuple[str, bytes]]) -> None:
        self._require_role(user, "coach")
        task_id = urllib.parse.unquote(
            path[len("/tasks/") : -len("/sign-ground-truth")]
        ).strip("/")
        task = self.app.store.task(task_id, user)
        if not task or not task.get("is_adjudicator"):
            raise WorkflowError("active adjudication assignment was not found")
        signature_name, signature_data = self._required_file(files, "signature")
        self.app.complete_ground_truth_signature(user, task, signature_data, signature_name)
        self.app.set_notice(
            user,
            "good",
            "Ground-truth signature verified. The coordinator can now export the reverified evidence bundle.",
        )
        self._redirect(task_url(task_id))

    def _task_get(self, path: str, user: dict) -> None:
        suffix = None
        raw = path[len("/tasks/") :]
        for candidate in (
            "/adjudication-template", "/ground-truth", "/bundle", "/video", "/manifest"
        ):
            if raw.endswith(candidate):
                raw, suffix = raw[: -len(candidate)], candidate
                break
        task_id = urllib.parse.unquote(raw.strip("/"))
        task = self.app.store.task(task_id, user)
        if task is None:
            self._error(404, "Task not found or not assigned to this account")
            return
        if suffix == "/video":
            self._send_file(Path(task["video_path"]), task["video_mime"])
        elif suffix == "/manifest":
            self._send_file(Path(task["task_path"]), "application/json; charset=utf-8", download=True)
        elif suffix == "/adjudication-template":
            self._send_adjudication_template(task, user)
        elif suffix == "/ground-truth":
            adjudication = task.get("adjudication")
            if not adjudication or not (
                user["role"] == "coordinator" or task.get("is_adjudicator")
            ):
                self._error(403, "Ground-truth artifact is not available to this account")
                return
            self._send_file(
                Path(adjudication["ground_truth_path"]),
                "application/json; charset=utf-8",
                download=True,
            )
        elif suffix == "/bundle":
            if user["role"] != "coordinator":
                self._error(403, "Coordinator access required")
                return
            try:
                bundle = self.app.evidence_bundle(user, task)
            except (WorkflowError, ValueError) as error:
                self._error(409, str(error))
                return
            self._send_download_bytes(
                bundle,
                "application/zip",
                f"serveai-evidence-{task['task_id']}.zip",
            )
        else:
            self._send_html(self._task_page(user, task))

    def _send_adjudication_template(self, task: dict, user: dict) -> None:
        if not task.get("is_adjudicator") or len(task.get("submissions") or []) != 2:
            self._error(403, "Adjudication template is available only to the assigned third coach")
            return
        template = {
            "schemaVersion": 3,
            "rubric": CURRENT_RUBRIC_BINDING,
            "adjudicationID": "replace-with-new-uuid",
            "analysisID": task["analysis_id"],
            "sourceAnnotationIDs": [item["annotation_id"] for item in task["submissions"]],
            "adjudicatorPseudonym": user["pseudonym"],
            "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "collectionMetadata": {},
            "isVideoUsable": True,
            "unusableReason": None,
            "phaseBoundaries": [],
            "techniqueRatings": [],
            "topPriority": None,
            "decisionNotes": "Resolve every disputed value against the source video; do not average labels.",
        }
        self._send_download_bytes(
            json.dumps(template, indent=2, sort_keys=True).encode("utf-8") + b"\n",
            "application/json; charset=utf-8",
            f"adjudication-template-{task['task_id']}.json",
        )

    def _submission_get(self, path: str, user: dict) -> None:
        parts = path.strip("/").split("/")
        if len(parts) != 3 or parts[2] not in {"annotation", "signature"}:
            self._error(404, "Submission artifact not found")
            return
        try:
            submission_id = int(parts[1])
        except ValueError:
            self._error(404, "Submission artifact not found")
            return
        with self.app.store.connect() as database:
            row = database.execute("SELECT * FROM submissions WHERE id = ?", (submission_id,)).fetchone()
        if row is None:
            self._error(404, "Submission artifact not found")
            return
        if user["role"] != "coordinator":
            task = self.app.store.task(row["task_id"], user)
            allowed = row["coach_id"] == user["id"] or bool(task and task.get("is_adjudicator"))
            if not allowed:
                self._error(403, "This evidence is not available to the signed-in coach")
                return
        key = "annotation_path" if parts[2] == "annotation" else "signature_path"
        self._send_file(Path(row[key]), "application/json; charset=utf-8", download=True)

    def _dashboard(self, user: dict) -> str:
        tasks = self.app.store.tasks(user)
        metrics = self.app.store.metrics(user)
        notice = self.app.pop_notice(user)
        research = json.loads(RESEARCH_EVALUATION_PATH.read_text()) if RESEARCH_EVALUATION_PATH.exists() else {}
        test = research.get("testPseudoTeacherAgreement") or {}
        rows = "".join(
            f"<tr><td><a class='task-link' href='{task_url(task['task_id'])}'>{e(task['task_id'][:8])}</a>"
            f"<div class='muted mono'>{e(task['source_video_filename'])}</div></td>"
            f"<td class='mono'>{e(task.get('capture_slot_id') or '—')}</td>"
            f"<td>{e(task['camera_angle'].title())}</td><td>{e(task['skill_level'].title())}</td>"
            f"<td>{self._status(task['workflow_status'])}</td>"
            f"<td>{task['submission_count']} / 2</td></tr>" for task in tasks
        ) or "<tr><td colspan='6' class='empty'>No tasks yet. Import a signed app task and matching source video.</td></tr>"
        config_status = self.app.configuration.registries.status()
        config_ready = all(config_status.values())
        banner = (
            "<div class='notice success'>Registry verification is active. Task and annotation imports fail closed on any signature, authorization, or fingerprint mismatch.</div>"
            if config_ready else
            "<div class='notice warning'>Pilot is running in locked mode. Configure both signed registries and their environment secrets before imports are accepted. The dashboard remains usable for account and workflow setup.</div>"
        )
        coordinator_tools = self._coordinator_tools(user) if user["role"] == "coordinator" else ""
        content = f"""
          {self._notice(notice)}
          <div class='page-context'>Ground-truth operations</div>
          <h1>Build labels the model can earn.</h1>
          <p class='lede'>Signed, double-labeled serve tasks move through independent review and explicit adjudication. Nothing uploaded here becomes training truth automatically.</p>
          {banner}
          <div class='metrics'>
            <div class='metric'><strong>{metrics['tasks']}</strong><span>visible tasks</span></div>
            <div class='metric'><strong>{metrics['unassigned']}</strong><span>unassigned</span></div>
            <div class='metric'><strong>{metrics['active']}</strong><span>in labeling</span></div>
            <div class='metric'><strong>{metrics['adjudication']}</strong><span>ready to adjudicate</span></div>
          </div>
          <div class='section-heading'><div><div class='section-context'>Release gap</div><h2>Technique and priority</h2></div><p class='muted'>Current experimental result vs. beta gate</p></div>
          <div class='panel gate-grid'>
            <div class='gate failed'><div class='gate-value'>{float(test.get('techniqueRatingMeanAbsoluteError', 0)):.2f} MAE</div><div class='gate-target'>Needs ≤ 0.60 on qualified-coach ground truth</div></div>
            <div class='gate failed'><div class='gate-value'>{float(test.get('priorityAgreement', 0))*100:.0f}% exact</div><div class='gate-target'>Needs ≥ 75% on qualified-coach ground truth</div></div>
          </div>
          <div class='section-heading'><h2>Serve tasks</h2><a class='button secondary' href='/capture'>View capture plan</a></div>
          <div class='panel table-panel'><table><thead><tr><th>Task</th><th>Slot</th><th>View</th><th>Level</th><th>Status</th><th>Labels</th></tr></thead><tbody>{rows}</tbody></table></div>
          {coordinator_tools}
        """
        return self._page("Research queue", user, content)

    def _coordinator_tools(self, user: dict) -> str:
        csrf = e(self._cookie("serveai_csrf") or "")
        coaches = self.app.store.users("coach")
        roster = "".join(
            f"<tr><td>{e(coach['pseudonym'])}</td><td>{'Active' if coach['active'] else 'Inactive'}</td><td class='mono'>{e(coach['created_at'][:10])}</td></tr>"
            for coach in coaches
        ) or "<tr><td colspan='3' class='empty'>No coach accounts yet.</td></tr>"
        return f"""
          <div class='section-heading'><h2>Bring verified work in</h2></div>
          <div class='split'>
            <section class='panel panel-body'><h3>Import signed task</h3><p class='muted'>The video fingerprint and frozen capture-plan slot must both match. A slot can be imported only once.</p>
              <form class='stack' action='/tasks/import' method='post' enctype='multipart/form-data'>
                <input type='hidden' name='csrf' value='{csrf}'>
                <label>ServeAI task JSON<input type='file' name='task' accept='.json,application/json' required></label>
                <label>Exact MOV/MP4 source video<input type='file' name='video' accept='.mov,.mp4,.m4v,video/quicktime,video/mp4' required></label>
                <button class='button' type='submit'>Verify and import</button>
              </form>
            </section>
            <section class='panel panel-body'><h3>Create coach access</h3><p class='muted'>Account access does not authorize labels; the coach must also appear in the signed coach registry.</p>
              <form class='stack' action='/users' method='post'>
                <input type='hidden' name='csrf' value='{csrf}'>
                <label>Coach pseudonym<input name='pseudonym' autocomplete='off' pattern='[A-Za-z0-9_-]{{3,48}}' required></label>
                <button class='button secondary' type='submit'>Create one-time token</button>
              </form>
            </section>
          </div>
          <div class='section-heading'><h2>Coach roster</h2></div>
          <div class='panel table-panel'><table><thead><tr><th>Pseudonym</th><th>Status</th><th>Created</th></tr></thead><tbody>{roster}</tbody></table></div>
        """

    def _task_page(self, user: dict, task: dict) -> str:
        notice = self.app.pop_notice(user)
        assignments = "".join(
            f"<tr><td>{e(item['pseudonym'])}</td><td>{self._status(item['status'].replace('_',' ').title())}</td><td>{e(item['assigned_at'][:10])}</td></tr>"
            for item in task["assignments"]
        ) or "<tr><td colspan='3' class='empty'>No coaches assigned.</td></tr>"
        can_review_sources = user["role"] == "coordinator" or bool(task.get("is_adjudicator"))
        submissions = "".join(
            f"<tr><td>{e(item['pseudonym'])}</td><td class='mono'>{e(item['annotation_id'][:8])}</td><td>{e(item['submitted_at'][:10])}</td>"
            + (
                f"<td><a href='/submissions/{item['id']}/annotation'>JSON</a> · "
                f"<a href='/submissions/{item['id']}/signature'>signature</a></td>"
                if can_review_sources else "<td>Verified and locked</td>"
            )
            + "</tr>" for item in task["submissions"]
        ) or "<tr><td colspan='4' class='empty'>No verified annotations yet.</td></tr>"
        comparison = compare_submission_paths([item["annotation_path"] for item in task["submissions"]])
        comparison_html = ""
        if comparison and can_review_sources:
            agreement = "Agree" if comparison["topPriorityAgreement"] else "Disagree"
            boundary = comparison.get("boundaryMeanAbsoluteDifference")
            boundary_text = "Unavailable" if boundary is None else f"{boundary:.3f} seconds"
            comparison_html = f"""
              <div class='notice warning'><strong>Independent comparison:</strong> top priority {agreement.lower()}, boundary mean difference {e(boundary_text)}. A third coach must explicitly decide every final value; the portal never averages labels.</div>
            """
        controls = (
            self._coordinator_task_controls(user, task)
            if user["role"] == "coordinator"
            else self._coach_task_controls(user, task)
        )
        adjudication = task.get("adjudication")
        adjudicator = task.get("adjudication_assignment")
        adjudication_row = (
            f"<tr><td>{e(adjudicator['pseudonym'])}</td><td>{self._status(adjudicator['status'].replace('_', ' ').title())}</td>"
            f"<td>{e(adjudicator['assigned_at'][:10])}</td></tr>"
            if adjudicator else
            "<tr><td colspan='3' class='empty'>No independent adjudicator assigned.</td></tr>"
        )
        release_artifacts = ""
        if adjudication:
            release_artifacts = f"""
              <div class='section-heading'><h2>Adjudicated ground truth</h2></div>
              <div class='panel panel-body facts'>
                <div class='fact'><span>Adjudicator</span>{e(adjudication['pseudonym'])}</div>
                <div class='fact'><span>State</span>{e(adjudication['status'].replace('_', ' ').title())}</div>
                <div class='fact'><span>Adjudication ID</span><span class='mono'>{e(adjudication['adjudication_id'])}</span></div>
                <div class='fact'><span>Release eligibility</span>Still requires held-out model gates</div>
              </div>
            """
        content = f"""
          {self._notice(notice)}
          <div class='page-context'>Signed task {e(task['task_id'][:8])}</div>
          <h1>Independent review.</h1>
          <p class='lede'>Source bytes, analysis evidence, and task identity are cryptographically bound. Coaches should label the video without seeing another coach's answer.</p>
          {comparison_html}
          <div class='split'>
            <section class='panel panel-body'>
              <video class='task-video' controls preload='metadata' src='{task_url(task['task_id'])}/video'></video>
              <div class='actions top-gap'><a class='button secondary' href='{task_url(task['task_id'])}/manifest'>Download task JSON</a></div>
            </section>
            <aside class='panel panel-body'><h2>Capture facts</h2><div class='facts'>
              <div class='fact'><span>Camera</span>{e(task['camera_angle'].title())}</div>
              <div class='fact'><span>Skill</span>{e(task['skill_level'].title())}</div>
              <div class='fact'><span>Capture slot</span><span class='mono'>{e(task.get('capture_slot_id') or 'Unbound')}</span></div>
              <div class='fact'><span>Participant</span><span class='mono'>{e(task.get('participant_pseudonym') or 'Unbound')}</span></div>
              <div class='fact'><span>Frozen split</span>{e((task.get('split') or 'unbound').title())}</div>
              <div class='fact'><span>Status</span>{e(task['workflow_status'])}</div>
              <div class='fact'><span>Coordinator</span>{e(task['coordinator_pseudonym'])}</div>
            </div><p class='muted mono top-gap'>Video SHA-256<br>{e(task['source_video_sha256'])}</p></aside>
          </div>
          {controls}
          <div class='section-heading'><h2>Independent assignments</h2></div>
          <div class='panel table-panel'><table><thead><tr><th>Coach</th><th>Status</th><th>Assigned</th></tr></thead><tbody>{assignments}</tbody></table></div>
          <div class='section-heading'><h2>Verified submissions</h2></div>
          <div class='panel table-panel'><table><thead><tr><th>Coach</th><th>Annotation</th><th>Submitted</th><th>Artifact</th></tr></thead><tbody>{submissions}</tbody></table></div>
          <div class='section-heading'><h2>Independent adjudicator</h2></div>
          <div class='panel table-panel'><table><thead><tr><th>Coach</th><th>Status</th><th>Assigned</th></tr></thead><tbody>{adjudication_row}</tbody></table></div>
          {release_artifacts}
        """
        return self._page("Task " + task["task_id"][:8], user, content)

    def _coordinator_task_controls(self, user: dict, task: dict) -> str:
        assigned_ids = {item["id"] for item in task["assignments"]}
        coaches = [coach for coach in self.app.store.users("coach") if coach["active"]]
        csrf = e(self._cookie("serveai_csrf") or "")
        if int(task["assignment_count"]) < 2:
            choices = "".join(
                f"<option value='{coach['id']}'>{e(coach['pseudonym'])}</option>"
                for coach in coaches if coach["id"] not in assigned_ids
            )
            if not choices:
                return "<div class='notice warning'>Create another active coach account before assigning the remaining independent label.</div>"
            return f"""
              <div class='section-heading'><h2>Assign blind reviewer</h2></div>
              <form class='panel panel-body form-grid' action='{task_url(task['task_id'])}/assign' method='post'>
                <input type='hidden' name='csrf' value='{csrf}'>
                <label>Qualified coach<select name='coach_id' required>{choices}</select></label>
                <button class='button form-end' type='submit'>Assign without revealing labels</button>
              </form>
            """
        if int(task["submission_count"]) < 2:
            return "<div class='notice information'>Both blind reviewers are assigned. Adjudicator selection unlocks only after two verified labels arrive.</div>"
        if not task.get("adjudication_assignment"):
            source_ids = {item["coach_id"] for item in task["submissions"]}
            choices = "".join(
                f"<option value='{coach['id']}'>{e(coach['pseudonym'])}</option>"
                for coach in coaches if coach["id"] not in source_ids
            )
            if not choices:
                return "<div class='notice warning'>Create a third active coach account. Neither source coach can adjudicate their own label.</div>"
            return f"""
              <div class='section-heading'><h2>Assign third-coach adjudication</h2></div>
              <form class='panel panel-body form-grid' action='{task_url(task['task_id'])}/assign-adjudicator' method='post'>
                <input type='hidden' name='csrf' value='{csrf}'>
                <label>Independent adjudicator<select name='coach_id' required>{choices}</select></label>
                <button class='button form-end' type='submit'>Assign adjudication</button>
              </form>
            """
        if task.get("adjudication_status") == "verified":
            return f"""
              <div class='notice success'><strong>Evidence chain complete.</strong> Every artifact is reverified against the current registries before export. The source video stays out of the bundle.</div>
              <div class='actions'><a class='button' href='{task_url(task['task_id'])}/bundle'>Export verified evidence bundle</a></div>
            """
        return "<div class='notice information'>Adjudication is assigned. The coordinator can monitor progress but cannot supply or sign the coach's decision.</div>"

    def _coach_task_controls(self, user: dict, task: dict) -> str:
        if task.get("is_adjudicator"):
            return self._adjudicator_controls(user, task)
        mine = next((item for item in task["assignments"] if item["id"] == user["id"]), None)
        if not mine or mine["status"] == "submitted":
            return "<div class='notice success'>Your verified submission is locked. Another reviewer and adjudicator handle the next steps.</div>"
        return f"""
          <div class='section-heading'><h2>Upload your signed annotation</h2></div>
          <form class='panel panel-body stack' action='{task_url(task['task_id'])}/submit' method='post' enctype='multipart/form-data'>
            <input type='hidden' name='csrf' value='{e(self._cookie('serveai_csrf') or '')}'>
            <p class='muted'>Export the completed schema-v8 annotation, sign its exact bytes with your registered P-256 key, then upload both files. Its rubric digest and independent consent receipts are reverified at dataset assembly.</p>
            <div class='form-grid'>
              <label>Annotation JSON<input type='file' name='annotation' accept='.json,application/json' required></label>
              <label>Signature sidecar<input type='file' name='signature' accept='.json,application/json' required></label>
            </div>
            <button class='button' type='submit'>Verify and submit</button>
          </form>
        """

    def _adjudicator_controls(self, user: dict, task: dict) -> str:
        csrf = e(self._cookie("serveai_csrf") or "")
        adjudication = task.get("adjudication")
        if not adjudication:
            sources = "".join(
                f"<a class='button secondary' href='/submissions/{item['id']}/annotation'>Label from {e(item['pseudonym'])}</a>"
                for item in task["submissions"]
            )
            return f"""
              <div class='section-heading'><h2>Resolve the source labels</h2></div>
              <div class='notice warning'>Review both signed labels against the video. Select every final boundary, rating, visibility decision, and priority explicitly—never average values.</div>
              <div class='actions'>{sources}<a class='button secondary' href='{task_url(task['task_id'])}/adjudication-template'>Download pre-bound template</a></div>
              <form class='panel panel-body stack top-gap-lg' action='{task_url(task['task_id'])}/adjudicate' method='post' enctype='multipart/form-data'>
                <input type='hidden' name='csrf' value='{csrf}'>
                <p class='muted'>Complete the schema-v3 rubric-bound template, sign its exact bytes with your registered P-256 key, and upload both artifacts.</p>
                <div class='form-grid'>
                  <label>Adjudication JSON<input type='file' name='resolution' accept='.json,application/json' required></label>
                  <label>Signature sidecar<input type='file' name='signature' accept='.json,application/json' required></label>
                </div>
                <button class='button' type='submit'>Verify and compile ground truth</button>
              </form>
            """
        if adjudication["status"] == "needs_ground_truth_signature":
            return f"""
              <div class='section-heading'><h2>Sign the compiled ground truth</h2></div>
              <div class='notice information'>The portal compiled this file only from your verified adjudication. Download it, sign the exact bytes, then upload the generated sidecar.</div>
              <div class='actions'><a class='button secondary' href='{task_url(task['task_id'])}/ground-truth'>Download compiled ground truth</a></div>
              <form class='panel panel-body stack top-gap-lg' action='{task_url(task['task_id'])}/sign-ground-truth' method='post' enctype='multipart/form-data'>
                <input type='hidden' name='csrf' value='{csrf}'>
                <label>Ground-truth signature sidecar<input type='file' name='signature' accept='.json,application/json' required></label>
                <button class='button' type='submit'>Verify final signature</button>
              </form>
            """
        return "<div class='notice success'><strong>Adjudication complete.</strong> Your signed decision and the compiled ground truth are locked for coordinator export.</div>"

    def _capture_page(self, user: dict) -> str:
        plan = json.loads(CAPTURE_PLAN_PATH.read_text()) if CAPTURE_PLAN_PATH.exists() else {}
        summary = plan.get("summary") or {}
        statuses = self.app.store.capture_slot_statuses()
        imported = len(statuses)
        verified = sum(status == "ground_truth_verified" for status in statuses.values())
        slot_rows = "".join(
            f"<tr><td class='mono'>{e(slot['slotID'])}</td>"
            f"<td class='mono'>{e(slot['participantPseudonym'])}</td>"
            f"<td>{e(slot['split'].title())}</td>"
            f"<td>{e(slot['cameraAngle'].title())} · {e(slot['skillLevel'].title())}</td>"
            f"<td>{self._status(('Ground truth verified' if statuses.get(slot['slotID']) == 'ground_truth_verified' else 'In progress' if slot['slotID'] in statuses else 'Open'))}</td></tr>"
            for slot in plan.get("slots", [])
        ) or "<tr><td colspan='5' class='empty'>Run Training/generate_capture_plan.py to build the plan.</td></tr>"
        cohort_rows = "".join(
            f"<tr><td>{e(item['dimension'])}</td><td>{e(item['target'])}</td><td>{e(item['reason'])}</td></tr>"
            for item in plan.get("coverageRequirements", [])
        ) or "<tr><td colspan='3' class='empty'>Run Training/generate_capture_plan.py to build the plan.</td></tr>"
        content = f"""
          <div class='page-context'>Target-domain collection</div>
          <h1>Record what the app will really see.</h1>
          <p class='lede'>The collection plan targets real-ball iPhone serves from supported side and rear views. Participants, consent, and video remain pseudonymous and must be handled under the study protocol.</p>
          <div class='metrics'>
            <div class='metric'><strong>{e(summary.get('targetClips', '—'))}</strong><span>target clips</span></div>
            <div class='metric'><strong>{e(summary.get('minimumParticipants', '—'))}</strong><span>minimum participants</span></div>
            <div class='metric'><strong>{e(summary.get('heldOutClips', '—'))}</strong><span>held-out clips</span></div>
            <div class='metric'><strong>{imported}</strong><span>signed slots imported</span></div>
            <div class='metric'><strong>{verified}</strong><span>ground truths verified</span></div>
          </div>
          <div class='split'>
            <section class='panel'><div class='panel-body'><h2>One complete serve, one stable view</h2></div><div class='steps'>
              <div class='step'><strong>Consent before capture</strong><div class='muted'>Issue the independently signed video-bound receipt; do not rely on a checkbox inside an annotation.</div></div>
              <div class='step'><strong>Frame the full body and racket</strong><div class='muted'>Phone stationary, 10–15 feet away, side or rear, normal speed, 60 FPS when available.</div></div>
              <div class='step'><strong>Capture target-domain variation</strong><div class='muted'>Balance skill, handedness, lighting, device, clothing contrast, and realistic failure examples.</div></div>
              <div class='step'><strong>Keep participants isolated</strong><div class='muted'>Every participant belongs to exactly one train, validation, or test split.</div></div>
              <div class='step'><strong>Blind and adjudicate</strong><div class='muted'>Two coaches label independently; disagreements go to a third qualified coach.</div></div>
            </div></section>
            <aside class='panel panel-body'><div class='section-context'>Release rule</div><h2>No shortcut through the test set</h2><p class='muted'>Tune only on training and validation participants. The final 60+ clip, 10+ player test set stays locked until the candidate model and thresholds are frozen.</p><a class='button secondary' href='/dashboard'>Back to queue</a></aside>
          </div>
          <div class='section-heading'><h2>Coverage requirements</h2></div>
          <div class='panel table-panel'><table><thead><tr><th>Dimension</th><th>Target</th><th>Why</th></tr></thead><tbody>{cohort_rows}</tbody></table></div>
          <div class='section-heading'><div><h2>Signed slot ledger</h2><p class='muted'>A slot becomes occupied only after the portal verifies its signed task assignment.</p></div></div>
          <div class='panel table-panel'><table><thead><tr><th>Slot</th><th>Participant</th><th>Split</th><th>Target</th><th>Status</th></tr></thead><tbody>{slot_rows}</tbody></table></div>
        """
        return self._page("Capture plan", user, content)

    def _login_page(self, error: str | None = None) -> str:
        message = f"<div class='notice error'>{e(error)}</div>" if error else ""
        return f"""<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>Sign in · ServeAI Research</title><link rel='icon' href='/static/favicon.svg'><link rel='stylesheet' href='/static/styles.css'></head><body><div class='shell'><main class='login'><a class='brand' href='/'><span class='mark'></span><strong>ServeAI Research</strong></a><div class='spacer'></div><div class='page-context'>Authorized study access</div><h1>Ground truth starts here.</h1><p class='lede'>Use the pseudonym and one-time token issued by the study coordinator.</p>{message}<form class='panel panel-body stack' action='/login' method='post'><label>Pseudonym<input name='pseudonym' autocomplete='username' required autofocus></label><label>Access token<input type='password' name='token' autocomplete='current-password' required></label><button class='button' type='submit'>Sign in</button></form><p class='muted top-gap-lg'>Local research pilot · Labels are not automatically promoted to training truth.</p></main></div></body></html>"""

    def _page(self, title: str, user: dict, content: str) -> str:
        csrf = e(self._cookie("serveai_csrf") or "")
        return f"""<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>{e(title)} · ServeAI Research</title><link rel='icon' href='/static/favicon.svg'><link rel='stylesheet' href='/static/styles.css'></head><body><div class='shell'><header><a class='brand' href='/dashboard'><span class='mark'></span><span><strong>ServeAI</strong><div class='brand-meta'>Research</div></span></a><nav><a href='/dashboard'>Queue</a><a href='/capture'>Capture plan</a><span class='muted account'>{e(user['pseudonym'])} · {e(user['role'])}</span><form action='/logout' method='post'><input type='hidden' name='csrf' value='{csrf}'><button class='link-button' type='submit'>Sign out</button></form></nav></header><main>{content}</main></div></body></html>"""

    def _notice(self, notice: dict[str, str] | None) -> str:
        if not notice:
            return ""
        token = f"<div class='token mono'>{e(notice['token'])}</div>" if notice.get("token") else ""
        return f"<div class='notice {e(notice['kind'])} flash'>{e(notice['message'])}{token}</div>"

    @staticmethod
    def _status(value: str) -> str:
        css = (
            "ready"
            if value in {"Ground truth verified", "Submitted", "Completed"}
            else "warn"
            if any(marker in value for marker in ("Ready", "One", "Needed"))
            else ""
        )
        return f"<span class='status {css}'>{e(value)}</span>"

    def _current_user(self) -> dict | None:
        return self.app.store.session_user(self._cookie("serveai_session"))

    def _cookie(self, name: str) -> str | None:
        raw = self.headers.get("Cookie", "")
        jar = cookies.SimpleCookie()
        try:
            jar.load(raw)
        except cookies.CookieError:
            return None
        return jar[name].value if name in jar else None

    def _read_form(self) -> tuple[dict[str, str], dict[str, tuple[str, bytes]]]:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError as error:
            raise WorkflowError("invalid request size") from error
        if length <= 0 or length > MAX_REQUEST_BYTES:
            raise WorkflowError("request is empty or exceeds the 530 MB pilot limit")
        body = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        fields: dict[str, str] = {}
        files: dict[str, tuple[str, bytes]] = {}
        if content_type.startswith("application/x-www-form-urlencoded"):
            parsed = urllib.parse.parse_qs(body.decode("utf-8"), keep_blank_values=True)
            fields = {key: values[-1] for key, values in parsed.items()}
        elif content_type.startswith("multipart/form-data"):
            prefix = f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode()
            message = BytesParser(policy=policy.default).parsebytes(prefix + body)
            if not message.is_multipart():
                raise WorkflowError("malformed multipart form")
            for part in message.iter_parts():
                name = part.get_param("name", header="content-disposition")
                if not name:
                    continue
                payload = part.get_payload(decode=True) or b""
                filename = part.get_filename()
                if filename:
                    files[name] = (Path(filename).name, payload)
                else:
                    fields[name] = payload.decode("utf-8")
        else:
            raise WorkflowError("unsupported form encoding")
        # Multipart posts carry the readable CSRF cookie as a hidden field.
        if "csrf" not in fields and self._cookie("serveai_csrf"):
            fields["csrf"] = ""
        return fields, files

    @staticmethod
    def _required_file(files: dict[str, tuple[str, bytes]], name: str) -> tuple[str, bytes]:
        value = files.get(name)
        if not value or not value[0] or not value[1]:
            raise WorkflowError(f"{name} file is required")
        return value

    @staticmethod
    def _require_role(user: dict, role: str) -> None:
        if user["role"] != role:
            raise WorkflowError(f"{role} access required")

    def _send_html(self, content: str, status: int = 200) -> None:
        self._send_bytes(content.encode("utf-8"), "text/html; charset=utf-8", status)

    def _send_bytes(self, content: bytes, content_type: str, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.end_headers()
        self.wfile.write(content)

    def _send_download_bytes(self, content: bytes, content_type: str, filename: str) -> None:
        safe_filename = Path(filename).name.replace('"', "")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Content-Disposition", f'attachment; filename="{safe_filename}"')
        self.end_headers()
        self.wfile.write(content)

    def _send_file(self, path: Path, content_type: str, download: bool = False) -> None:
        if not path.is_file() or self.app.data_directory not in path.resolve().parents:
            self._error(404, "Artifact not found")
            return
        size = path.stat().st_size
        start, end, status = 0, size - 1, 200
        requested = self.headers.get("Range")
        if requested and requested.startswith("bytes=") and "," not in requested:
            try:
                first, last = requested[6:].split("-", 1)
                start = int(first) if first else 0
                end = int(last) if last else size - 1
                if start < 0 or end < start or start >= size:
                    raise ValueError
                end = min(end, size - 1)
                status = 206
            except ValueError:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        if download:
            self.send_header("Content-Disposition", f"attachment; filename={path.name}")
        self.end_headers()
        with path.open("rb") as handle:
            handle.seek(start)
            remaining = end - start + 1
            while remaining:
                chunk = handle.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)

    def _redirect(self, location: str) -> None:
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def _error(self, status: int, message: str) -> None:
        self._send_html(f"<!doctype html><html><head><link rel='stylesheet' href='/static/styles.css'><title>Error</title></head><body><div class='shell'><main><div class='page-context'>Error {status}</div><h1>{e(message)}</h1><a class='button' href='/dashboard'>Return to dashboard</a></main></div></body></html>", status)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="ServeAI research annotation portal")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("init", "create-user"):
        item = subparsers.add_parser(command)
        item.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
        item.add_argument("--pseudonym", required=True)
        if command == "create-user":
            item.add_argument("--role", choices=("coordinator", "coach"), default="coach")
    serve = subparsers.add_parser("serve")
    serve.add_argument("--data-dir", type=Path, default=DEFAULT_DATA)
    serve.add_argument("--host", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=8765)
    serve.add_argument("--task-registry", type=Path)
    serve.add_argument("--coach-registry", type=Path)
    serve.add_argument("--secure-cookie", action="store_true")
    serve.add_argument("--allow-remote", action="store_true")
    return parser


def main() -> None:
    arguments = build_parser().parse_args()
    if arguments.command in {"init", "create-user"}:
        store = PortalStore(arguments.data_dir / "portal.sqlite3")
        role = "coordinator" if arguments.command == "init" else arguments.role
        token = store.create_user(arguments.pseudonym, role)
        print(f"created {role} account: {arguments.pseudonym}")
        print("copy this token now; it cannot be recovered:")
        print(token)
        return
    if arguments.host not in {"127.0.0.1", "localhost", "::1"}:
        if not arguments.allow_remote:
            raise SystemExit("remote binding refused; add --allow-remote only behind reviewed TLS access controls")
        if not arguments.secure_cookie:
            raise SystemExit("remote binding requires --secure-cookie and an HTTPS reverse proxy")
    configuration = PortalConfiguration(
        data_directory=arguments.data_dir,
        registries=RegistryConfiguration(arguments.task_registry, arguments.coach_registry),
        secure_cookie=arguments.secure_cookie,
    )
    application = PortalApplication(configuration)
    server = ThreadingHTTPServer((arguments.host, arguments.port), PortalHandler)
    server.application = application  # type: ignore[attr-defined]
    print(f"ServeAI research portal: http://{arguments.host}:{arguments.port}")
    if not configuration.registries.ready:
        print("LOCKED MODE: configure signed task/coach registries and their environment secrets to accept imports")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
