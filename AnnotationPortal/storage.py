#!/usr/bin/env python3
"""SQLite storage and integrity primitives for the ServeAI research portal."""

from __future__ import annotations

import hashlib
import hmac
import json
import secrets
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path


PBKDF2_ITERATIONS = 600_000
SESSION_HOURS = 12


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def canonical_json(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def _secret_hash(secret: str, salt: bytes) -> bytes:
    return hashlib.pbkdf2_hmac("sha256", secret.encode("utf-8"), salt, PBKDF2_ITERATIONS)


class PortalStore:
    """Small repository with hashed credentials and a tamper-evident audit log."""

    def __init__(self, database_path: Path):
        self.database_path = database_path
        self._write_lock = threading.RLock()
        database_path.parent.mkdir(parents=True, exist_ok=True)
        self._initialize()

    @contextmanager
    def connect(self):
        connection = sqlite3.connect(self.database_path)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        try:
            with connection:
                yield connection
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self._write_lock, self.connect() as database:
            database.executescript(
                """
                CREATE TABLE IF NOT EXISTS users (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    pseudonym TEXT NOT NULL UNIQUE,
                    role TEXT NOT NULL CHECK(role IN ('coordinator', 'coach')),
                    token_salt BLOB NOT NULL,
                    token_hash BLOB NOT NULL,
                    active INTEGER NOT NULL DEFAULT 1 CHECK(active IN (0, 1)),
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    session_hash TEXT PRIMARY KEY,
                    user_id INTEGER NOT NULL REFERENCES users(id),
                    csrf_hash TEXT NOT NULL,
                    expires_at TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS tasks (
                    task_id TEXT PRIMARY KEY,
                    analysis_id TEXT NOT NULL,
                    coordinator_pseudonym TEXT NOT NULL,
                    source_video_filename TEXT NOT NULL,
                    source_video_sha256 TEXT NOT NULL,
                    camera_angle TEXT NOT NULL,
                    skill_level TEXT NOT NULL,
                    capture_plan_id TEXT,
                    capture_plan_sha256 TEXT,
                    capture_slot_id TEXT,
                    participant_pseudonym TEXT,
                    split TEXT,
                    signer_key_id TEXT NOT NULL,
                    task_path TEXT NOT NULL,
                    video_path TEXT NOT NULL,
                    video_mime TEXT NOT NULL,
                    imported_at TEXT NOT NULL,
                    imported_by INTEGER NOT NULL REFERENCES users(id)
                );
                CREATE TABLE IF NOT EXISTS assignments (
                    task_id TEXT NOT NULL REFERENCES tasks(task_id),
                    coach_id INTEGER NOT NULL REFERENCES users(id),
                    assigned_at TEXT NOT NULL,
                    assigned_by INTEGER NOT NULL REFERENCES users(id),
                    status TEXT NOT NULL DEFAULT 'assigned'
                        CHECK(status IN ('assigned', 'submitted', 'needs_revision')),
                    PRIMARY KEY(task_id, coach_id)
                );
                CREATE TABLE IF NOT EXISTS submissions (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL REFERENCES tasks(task_id),
                    coach_id INTEGER NOT NULL REFERENCES users(id),
                    annotation_id TEXT NOT NULL UNIQUE,
                    annotation_path TEXT NOT NULL,
                    signature_path TEXT NOT NULL,
                    submitted_at TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'awaiting_adjudication'
                        CHECK(status IN ('awaiting_adjudication', 'needs_revision', 'adjudicated')),
                    UNIQUE(task_id, coach_id)
                );
                CREATE TABLE IF NOT EXISTS adjudication_assignments (
                    task_id TEXT PRIMARY KEY REFERENCES tasks(task_id),
                    coach_id INTEGER NOT NULL REFERENCES users(id),
                    assigned_at TEXT NOT NULL,
                    assigned_by INTEGER NOT NULL REFERENCES users(id),
                    status TEXT NOT NULL DEFAULT 'assigned'
                        CHECK(status IN ('assigned', 'resolution_submitted', 'completed'))
                );
                CREATE TABLE IF NOT EXISTS adjudications (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    task_id TEXT NOT NULL UNIQUE REFERENCES tasks(task_id),
                    adjudicator_id INTEGER NOT NULL REFERENCES users(id),
                    adjudication_id TEXT NOT NULL UNIQUE,
                    resolution_path TEXT NOT NULL,
                    resolution_signature_path TEXT NOT NULL,
                    ground_truth_path TEXT NOT NULL,
                    ground_truth_signature_path TEXT,
                    submitted_at TEXT NOT NULL,
                    completed_at TEXT,
                    status TEXT NOT NULL DEFAULT 'needs_ground_truth_signature'
                        CHECK(status IN ('needs_ground_truth_signature', 'verified'))
                );
                CREATE TABLE IF NOT EXISTS audit_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    occurred_at TEXT NOT NULL,
                    actor_user_id INTEGER REFERENCES users(id),
                    action TEXT NOT NULL,
                    target TEXT NOT NULL,
                    details_json TEXT NOT NULL,
                    previous_hash TEXT NOT NULL,
                    event_hash TEXT NOT NULL UNIQUE
                );
                CREATE TRIGGER IF NOT EXISTS audit_no_update
                BEFORE UPDATE ON audit_events BEGIN
                    SELECT RAISE(ABORT, 'audit events are append-only');
                END;
                CREATE TRIGGER IF NOT EXISTS audit_no_delete
                BEFORE DELETE ON audit_events BEGIN
                    SELECT RAISE(ABORT, 'audit events are append-only');
                END;
                CREATE INDEX IF NOT EXISTS assignment_coach_index ON assignments(coach_id, status);
                CREATE INDEX IF NOT EXISTS submission_task_index ON submissions(task_id);
                CREATE INDEX IF NOT EXISTS adjudication_coach_index
                    ON adjudication_assignments(coach_id, status);
                """
            )
            existing_columns = {
                row["name"] for row in database.execute("PRAGMA table_info(tasks)").fetchall()
            }
            for name in (
                "capture_plan_id", "capture_plan_sha256", "capture_slot_id",
                "participant_pseudonym", "split",
            ):
                if name not in existing_columns:
                    database.execute(f"ALTER TABLE tasks ADD COLUMN {name} TEXT")
            database.execute(
                """CREATE UNIQUE INDEX IF NOT EXISTS tasks_capture_slot_unique
                   ON tasks(capture_plan_id, capture_slot_id)
                   WHERE capture_slot_id IS NOT NULL"""
            )

    def create_user(self, pseudonym: str, role: str, actor_user_id: int | None = None) -> str:
        normalized = pseudonym.strip()
        if role not in {"coordinator", "coach"}:
            raise ValueError("role must be coordinator or coach")
        if not 3 <= len(normalized) <= 48 or not all(character.isalnum() or character in "-_" for character in normalized):
            raise ValueError("pseudonym must be 3–48 letters, numbers, hyphens, or underscores")
        token = secrets.token_urlsafe(32)
        salt = secrets.token_bytes(16)
        digest = _secret_hash(token, salt)
        with self._write_lock, self.connect() as database:
            cursor = database.execute(
                "INSERT INTO users(pseudonym, role, token_salt, token_hash, created_at) VALUES (?, ?, ?, ?, ?)",
                (normalized, role, salt, digest, utc_now()),
            )
            self._append_audit(database, actor_user_id, "user.created", normalized, {"role": role, "userID": cursor.lastrowid})
        return token

    def authenticate(self, pseudonym: str, token: str) -> dict | None:
        with self.connect() as database:
            row = database.execute(
                "SELECT * FROM users WHERE pseudonym = ? AND active = 1", (pseudonym.strip(),)
            ).fetchone()
        if row is None:
            # Perform equivalent work to reduce obvious user-enumeration timing differences.
            _secret_hash(token, b"\0" * 16)
            return None
        if not hmac.compare_digest(_secret_hash(token, row["token_salt"]), row["token_hash"]):
            return None
        return dict(row)

    def create_session(self, user_id: int) -> tuple[str, str]:
        session_token = secrets.token_urlsafe(32)
        csrf_token = secrets.token_urlsafe(24)
        session_hash = hashlib.sha256(session_token.encode()).hexdigest()
        csrf_hash = hashlib.sha256(csrf_token.encode()).hexdigest()
        expires_at = (datetime.now(timezone.utc) + timedelta(hours=SESSION_HOURS)).isoformat().replace("+00:00", "Z")
        with self._write_lock, self.connect() as database:
            database.execute("DELETE FROM sessions WHERE expires_at <= ?", (utc_now(),))
            database.execute(
                "INSERT INTO sessions(session_hash, user_id, csrf_hash, expires_at, created_at) VALUES (?, ?, ?, ?, ?)",
                (session_hash, user_id, csrf_hash, expires_at, utc_now()),
            )
            self._append_audit(database, user_id, "session.created", str(user_id), {})
        return session_token, csrf_token

    def session_user(self, session_token: str | None) -> dict | None:
        if not session_token:
            return None
        digest = hashlib.sha256(session_token.encode()).hexdigest()
        with self.connect() as database:
            row = database.execute(
                """SELECT users.*, sessions.csrf_hash, sessions.session_hash
                   FROM sessions JOIN users ON users.id = sessions.user_id
                   WHERE sessions.session_hash = ? AND sessions.expires_at > ? AND users.active = 1""",
                (digest, utc_now()),
            ).fetchone()
        return dict(row) if row else None

    def verify_csrf(self, user: dict, token: str | None) -> bool:
        if not token:
            return False
        return hmac.compare_digest(hashlib.sha256(token.encode()).hexdigest(), user["csrf_hash"])

    def destroy_session(self, session_token: str | None) -> None:
        if not session_token:
            return
        with self._write_lock, self.connect() as database:
            database.execute(
                "DELETE FROM sessions WHERE session_hash = ?",
                (hashlib.sha256(session_token.encode()).hexdigest(),),
            )

    def users(self, role: str | None = None) -> list[dict]:
        query = "SELECT id, pseudonym, role, active, created_at FROM users"
        parameters: tuple = ()
        if role:
            query += " WHERE role = ?"
            parameters = (role,)
        query += " ORDER BY pseudonym"
        with self.connect() as database:
            return [dict(row) for row in database.execute(query, parameters).fetchall()]

    def add_task(self, record: dict, actor_user_id: int) -> None:
        with self._write_lock, self.connect() as database:
            database.execute(
                """INSERT INTO tasks(
                    task_id, analysis_id, coordinator_pseudonym, source_video_filename,
                    source_video_sha256, camera_angle, skill_level, signer_key_id,
                    capture_plan_id, capture_plan_sha256, capture_slot_id,
                    participant_pseudonym, split,
                    task_path, video_path, video_mime, imported_at, imported_by
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    record["task_id"], record["analysis_id"], record["coordinator_pseudonym"],
                    record["source_video_filename"], record["source_video_sha256"],
                    record["camera_angle"], record["skill_level"], record["signer_key_id"],
                    record.get("capture_plan_id"), record.get("capture_plan_sha256"), record.get("capture_slot_id"),
                    record.get("participant_pseudonym"), record.get("split"),
                    record["task_path"], record["video_path"], record["video_mime"], utc_now(), actor_user_id,
                ),
            )
            self._append_audit(
                database, actor_user_id, "task.imported", record["task_id"],
                {
                    "videoSHA256": record["source_video_sha256"],
                    "signerKeyID": record["signer_key_id"],
                    "captureSlotID": record.get("capture_slot_id"),
                    "participantPseudonym": record.get("participant_pseudonym"),
                },
            )

    def capture_slot_statuses(self) -> dict[str, str]:
        with self.connect() as database:
            rows = database.execute(
                """SELECT capture_slot_id,
                          CASE
                            WHEN EXISTS(SELECT 1 FROM adjudications
                              WHERE adjudications.task_id = tasks.task_id
                                AND adjudications.status = 'verified') THEN 'ground_truth_verified'
                            ELSE 'in_progress'
                          END AS status
                   FROM tasks WHERE capture_slot_id IS NOT NULL"""
            ).fetchall()
        return {row["capture_slot_id"]: row["status"] for row in rows}

    def assign(self, task_id: str, coach_id: int, actor_user_id: int) -> None:
        with self._write_lock, self.connect() as database:
            coach = database.execute(
                "SELECT pseudonym FROM users WHERE id = ? AND role = 'coach' AND active = 1", (coach_id,)
            ).fetchone()
            if coach is None:
                raise ValueError("active coach account not found")
            assigned_count = database.execute(
                "SELECT COUNT(*) AS count FROM assignments WHERE task_id = ?", (task_id,)
            ).fetchone()["count"]
            if assigned_count >= 2:
                raise ValueError("two independent labeling coaches are already assigned")
            database.execute(
                "INSERT INTO assignments(task_id, coach_id, assigned_at, assigned_by) VALUES (?, ?, ?, ?)",
                (task_id, coach_id, utc_now(), actor_user_id),
            )
            self._append_audit(database, actor_user_id, "task.assigned", task_id, {"coach": coach["pseudonym"]})

    def add_submission(self, record: dict, actor_user_id: int) -> int:
        with self._write_lock, self.connect() as database:
            cursor = database.execute(
                """INSERT INTO submissions(
                    task_id, coach_id, annotation_id, annotation_path, signature_path, submitted_at
                ) VALUES (?, ?, ?, ?, ?, ?)""",
                (
                    record["task_id"], actor_user_id, record["annotation_id"],
                    record["annotation_path"], record["signature_path"], utc_now(),
                ),
            )
            database.execute(
                "UPDATE assignments SET status = 'submitted' WHERE task_id = ? AND coach_id = ?",
                (record["task_id"], actor_user_id),
            )
            self._append_audit(
                database, actor_user_id, "annotation.submitted", record["task_id"],
                {"annotationID": record["annotation_id"], "submissionID": cursor.lastrowid},
            )
            return int(cursor.lastrowid)

    def assign_adjudicator(self, task_id: str, coach_id: int, actor_user_id: int) -> None:
        with self._write_lock, self.connect() as database:
            coach = database.execute(
                "SELECT pseudonym FROM users WHERE id = ? AND role = 'coach' AND active = 1", (coach_id,)
            ).fetchone()
            if coach is None:
                raise ValueError("active adjudicator account not found")
            submissions = database.execute(
                "SELECT coach_id FROM submissions WHERE task_id = ? ORDER BY id", (task_id,)
            ).fetchall()
            source_coach_ids = {row["coach_id"] for row in submissions}
            if len(source_coach_ids) != 2:
                raise ValueError("exactly two verified source labels are required before adjudication")
            if coach_id in source_coach_ids:
                raise ValueError("the adjudicator must be independent from both source coaches")
            database.execute(
                """INSERT INTO adjudication_assignments(
                    task_id, coach_id, assigned_at, assigned_by
                ) VALUES (?, ?, ?, ?)""",
                (task_id, coach_id, utc_now(), actor_user_id),
            )
            self._append_audit(
                database, actor_user_id, "adjudication.assigned", task_id,
                {"adjudicator": coach["pseudonym"]},
            )

    def add_adjudication(self, record: dict, actor_user_id: int) -> int:
        with self._write_lock, self.connect() as database:
            assignment = database.execute(
                """SELECT status FROM adjudication_assignments
                   WHERE task_id = ? AND coach_id = ?""",
                (record["task_id"], actor_user_id),
            ).fetchone()
            if assignment is None or assignment["status"] != "assigned":
                raise ValueError("active adjudication assignment not found")
            cursor = database.execute(
                """INSERT INTO adjudications(
                    task_id, adjudicator_id, adjudication_id, resolution_path,
                    resolution_signature_path, ground_truth_path, submitted_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (
                    record["task_id"], actor_user_id, record["adjudication_id"],
                    record["resolution_path"], record["resolution_signature_path"],
                    record["ground_truth_path"], utc_now(),
                ),
            )
            database.execute(
                """UPDATE adjudication_assignments SET status = 'resolution_submitted'
                   WHERE task_id = ? AND coach_id = ?""",
                (record["task_id"], actor_user_id),
            )
            self._append_audit(
                database, actor_user_id, "adjudication.resolution_submitted", record["task_id"],
                {"adjudicationID": record["adjudication_id"], "adjudicationRecordID": cursor.lastrowid},
            )
            return int(cursor.lastrowid)

    def complete_ground_truth(self, task_id: str, signature_path: str, actor_user_id: int) -> None:
        with self._write_lock, self.connect() as database:
            adjudication = database.execute(
                """SELECT id FROM adjudications
                   WHERE task_id = ? AND adjudicator_id = ? AND status = 'needs_ground_truth_signature'""",
                (task_id, actor_user_id),
            ).fetchone()
            if adjudication is None:
                raise ValueError("ground-truth signature is not currently expected from this coach")
            now = utc_now()
            database.execute(
                """UPDATE adjudications
                   SET ground_truth_signature_path = ?, completed_at = ?, status = 'verified'
                   WHERE id = ?""",
                (signature_path, now, adjudication["id"]),
            )
            database.execute(
                """UPDATE adjudication_assignments SET status = 'completed'
                   WHERE task_id = ? AND coach_id = ?""",
                (task_id, actor_user_id),
            )
            database.execute(
                "UPDATE submissions SET status = 'adjudicated' WHERE task_id = ?",
                (task_id,),
            )
            self._append_audit(
                database, actor_user_id, "ground_truth.verified", task_id,
                {"adjudicationRecordID": adjudication["id"]},
            )

    def record_export(self, task_id: str, actor_user_id: int, bundle_sha256: str) -> None:
        with self._write_lock, self.connect() as database:
            verified = database.execute(
                "SELECT 1 FROM adjudications WHERE task_id = ? AND status = 'verified'", (task_id,)
            ).fetchone()
            if verified is None:
                raise ValueError("only verified ground truth can be exported")
            self._append_audit(
                database, actor_user_id, "evidence.exported", task_id,
                {"bundleSHA256": bundle_sha256},
            )

    def tasks(self, user: dict) -> list[dict]:
        if user["role"] == "coordinator":
            query = """
                SELECT tasks.*,
                    (SELECT COUNT(*) FROM assignments WHERE assignments.task_id = tasks.task_id)
                        AS assignment_count,
                    (SELECT COUNT(*) FROM submissions WHERE submissions.task_id = tasks.task_id)
                        AS submission_count,
                    (SELECT status FROM adjudication_assignments
                        WHERE adjudication_assignments.task_id = tasks.task_id)
                        AS adjudication_assignment_status,
                    (SELECT status FROM adjudications WHERE adjudications.task_id = tasks.task_id)
                        AS adjudication_status,
                    0 AS is_adjudicator
                FROM tasks ORDER BY tasks.imported_at DESC
            """
            parameters: tuple = ()
        else:
            query = """
                SELECT tasks.*,
                    (SELECT COUNT(*) FROM assignments WHERE assignments.task_id = tasks.task_id)
                        AS assignment_count,
                    (SELECT COUNT(*) FROM submissions WHERE submissions.task_id = tasks.task_id)
                        AS submission_count,
                    (SELECT status FROM assignments
                        WHERE assignments.task_id = tasks.task_id AND assignments.coach_id = ?)
                        AS assignment_status,
                    (SELECT status FROM adjudication_assignments
                        WHERE adjudication_assignments.task_id = tasks.task_id)
                        AS adjudication_assignment_status,
                    (SELECT status FROM adjudications WHERE adjudications.task_id = tasks.task_id)
                        AS adjudication_status,
                    CASE WHEN EXISTS(
                        SELECT 1 FROM adjudication_assignments
                        WHERE adjudication_assignments.task_id = tasks.task_id
                          AND adjudication_assignments.coach_id = ?
                    ) THEN 1 ELSE 0 END AS is_adjudicator
                FROM tasks
                WHERE EXISTS(
                    SELECT 1 FROM assignments
                    WHERE assignments.task_id = tasks.task_id AND assignments.coach_id = ?
                ) OR EXISTS(
                    SELECT 1 FROM adjudication_assignments
                    WHERE adjudication_assignments.task_id = tasks.task_id
                      AND adjudication_assignments.coach_id = ?
                )
                ORDER BY tasks.imported_at DESC
            """
            parameters = (user["id"], user["id"], user["id"], user["id"])
        with self.connect() as database:
            rows = [dict(row) for row in database.execute(query, parameters).fetchall()]
        for row in rows:
            row["workflow_status"] = self.workflow_status(row)
        return rows

    @staticmethod
    def workflow_status(task: dict) -> str:
        submissions = int(task.get("submission_count", 0))
        assignments = int(task.get("assignment_count", 0))
        adjudication_status = task.get("adjudication_status")
        adjudication_assignment = task.get("adjudication_assignment_status")
        if adjudication_status == "verified":
            return "Ground truth verified"
        if adjudication_status == "needs_ground_truth_signature":
            return "Ground-truth signature needed"
        if adjudication_assignment == "assigned":
            return "Adjudication assigned"
        if submissions >= 2:
            return "Ready for adjudication"
        if submissions == 1:
            return "One label received"
        if assignments:
            return "Assigned"
        return "Unassigned"

    def task(self, task_id: str, user: dict) -> dict | None:
        visible = {task["task_id"]: task for task in self.tasks(user)}
        task = visible.get(task_id)
        if task is None:
            return None
        with self.connect() as database:
            task["assignments"] = [
                dict(row) for row in database.execute(
                    """SELECT users.id, users.pseudonym, assignments.status, assignments.assigned_at
                       FROM assignments JOIN users ON users.id = assignments.coach_id
                       WHERE assignments.task_id = ? ORDER BY users.pseudonym""", (task_id,)
                ).fetchall()
            ]
            task["submissions"] = [
                dict(row) for row in database.execute(
                    """SELECT submissions.*, users.pseudonym
                       FROM submissions JOIN users ON users.id = submissions.coach_id
                       WHERE submissions.task_id = ? ORDER BY submissions.submitted_at""", (task_id,)
                ).fetchall()
            ]
            adjudication_assignment = database.execute(
                """SELECT users.id, users.pseudonym, adjudication_assignments.status,
                          adjudication_assignments.assigned_at
                   FROM adjudication_assignments
                   JOIN users ON users.id = adjudication_assignments.coach_id
                   WHERE adjudication_assignments.task_id = ?""",
                (task_id,),
            ).fetchone()
            task["adjudication_assignment"] = (
                dict(adjudication_assignment) if adjudication_assignment else None
            )
            adjudication = database.execute(
                """SELECT adjudications.*, users.pseudonym
                   FROM adjudications JOIN users ON users.id = adjudications.adjudicator_id
                   WHERE adjudications.task_id = ?""",
                (task_id,),
            ).fetchone()
            task["adjudication"] = dict(adjudication) if adjudication else None
        return task

    def metrics(self, user: dict) -> dict[str, int]:
        tasks = self.tasks(user)
        return {
            "tasks": len(tasks),
            "unassigned": sum(task["workflow_status"] == "Unassigned" for task in tasks),
            "active": sum(task["workflow_status"] in {"Assigned", "One label received"} for task in tasks),
            "adjudication": sum(
                task["workflow_status"] in {
                    "Ready for adjudication", "Adjudication assigned", "Ground-truth signature needed"
                }
                for task in tasks
            ),
        }

    def verify_audit_chain(self) -> tuple[bool, int]:
        previous = "0" * 64
        count = 0
        with self.connect() as database:
            rows = database.execute("SELECT * FROM audit_events ORDER BY id").fetchall()
        for row in rows:
            payload = {
                "occurredAt": row["occurred_at"], "actorUserID": row["actor_user_id"],
                "action": row["action"], "target": row["target"],
                "details": json.loads(row["details_json"]), "previousHash": row["previous_hash"],
            }
            expected = hashlib.sha256(canonical_json(payload)).hexdigest()
            if row["previous_hash"] != previous or not hmac.compare_digest(row["event_hash"], expected):
                return False, count
            previous = row["event_hash"]
            count += 1
        return True, count

    def _append_audit(
        self,
        database: sqlite3.Connection,
        actor_user_id: int | None,
        action: str,
        target: str,
        details: dict,
    ) -> None:
        last = database.execute("SELECT event_hash FROM audit_events ORDER BY id DESC LIMIT 1").fetchone()
        previous = last["event_hash"] if last else "0" * 64
        occurred_at = utc_now()
        payload = {
            "occurredAt": occurred_at, "actorUserID": actor_user_id, "action": action,
            "target": target, "details": details, "previousHash": previous,
        }
        event_hash = hashlib.sha256(canonical_json(payload)).hexdigest()
        database.execute(
            """INSERT INTO audit_events(
                occurred_at, actor_user_id, action, target, details_json, previous_hash, event_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
            (occurred_at, actor_user_id, action, target, canonical_json(details).decode(), previous, event_hash),
        )
