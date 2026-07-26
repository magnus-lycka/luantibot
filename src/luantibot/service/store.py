"""Job and world storage.

The HTTP layer talks to the `Store` protocol and never to a schema, so the
in-memory and SQLite implementations are interchangeable and the API tests do
not change when the storage does.

State machine (see "Crash recovery protocol" in docs/implementation_plan.md):

    queued --reserve--> running --+--> completed
                                  +--> failed
                                  +--> interrupted   (M4)

`interrupted` is terminal until an explicit retry, which does not exist before
M6 because there is no snapshot to restore from first.
"""

from __future__ import annotations

import json
import sqlite3
import threading
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from enum import StrEnum
from pathlib import Path
from typing import Any, Protocol

from luantibot.ops import JobRequest

SCHEMA = Path(__file__).with_name("schema.sql")

STALE_AFTER = timedelta(minutes=5)
"""How long a `running` job may go without a heartbeat before a service restart
treats it as interrupted."""


class State(StrEnum):
    QUEUED = "queued"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    INTERRUPTED = "interrupted"


def _now() -> datetime:
    return datetime.now(UTC)


@dataclass
class World:
    world_id: int
    name: str
    created_at: datetime = field(default_factory=_now)


@dataclass
class Job:
    job_id: int
    world_id: int
    request: JobRequest
    state: State = State.QUEUED
    created_at: datetime = field(default_factory=_now)
    reserved_at: datetime | None = None
    started_at: datetime | None = None
    heartbeat_at: datetime | None = None
    finished_at: datetime | None = None
    units_done: int = 0
    units_total: int = 0
    result: dict[str, Any] | None = None
    error_code: str | None = None
    error_message: str | None = None


class NotFound(LookupError):
    """No such job or world."""


class WrongState(RuntimeError):
    """The transition is not legal from the job's current state."""


class Store(Protocol):
    def register_world(self, name: str) -> World: ...

    def get_world(self, world_id: int) -> World: ...

    def list_worlds(self) -> list[World]: ...

    def create(self, world_id: int, request: JobRequest) -> Job: ...

    def get(self, job_id: int) -> Job: ...

    def reserve(self, world_id: int) -> Job | None: ...

    def mark_started(self, job_id: int) -> Job: ...

    def mark_completed(self, job_id: int, result: dict[str, Any]) -> Job: ...

    def mark_failed(self, job_id: int, code: str, message: str) -> Job: ...

    def sweep_stale(self, now: datetime | None = None) -> int: ...


class InMemoryStore:
    """Dict-backed store, for tests that do not care about persistence.

    Everything is lost on restart, which makes it useless for the recovery
    protocol -- hence SqliteStore.
    """

    def __init__(self, stale_after: timedelta = STALE_AFTER) -> None:
        self._stale_after = stale_after
        self._worlds: dict[int, World] = {}
        self._jobs: dict[int, Job] = {}
        self._next_world = 1
        self._next_job = 1

    def register_world(self, name: str) -> World:
        for world in self._worlds.values():
            if world.name == name:
                return world
        world = World(world_id=self._next_world, name=name)
        self._worlds[world.world_id] = world
        self._next_world += 1
        return world

    def get_world(self, world_id: int) -> World:
        try:
            return self._worlds[world_id]
        except KeyError:
            raise NotFound(f"no world {world_id}") from None

    def list_worlds(self) -> list[World]:
        return sorted(self._worlds.values(), key=lambda w: w.world_id)

    def create(self, world_id: int, request: JobRequest) -> Job:
        self.get_world(world_id)
        job = Job(job_id=self._next_job, world_id=world_id, request=request)
        self._jobs[job.job_id] = job
        self._next_job += 1
        return job

    def get(self, job_id: int) -> Job:
        try:
            return self._jobs[job_id]
        except KeyError:
            raise NotFound(f"no job {job_id}") from None

    def reserve(self, world_id: int) -> Job | None:
        for job in sorted(self._jobs.values(), key=lambda j: j.job_id):
            if job.world_id == world_id and job.state is State.QUEUED:
                job.state = State.RUNNING
                job.reserved_at = _now()
                job.heartbeat_at = job.reserved_at
                return job
        return None

    def _running(self, job_id: int) -> Job:
        job = self.get(job_id)
        if job.state is not State.RUNNING:
            raise WrongState(f"job {job_id} is {job.state}, not running")
        return job

    def mark_started(self, job_id: int) -> Job:
        job = self._running(job_id)
        job.started_at = _now()
        job.heartbeat_at = job.started_at
        return job

    def mark_completed(self, job_id: int, result: dict[str, Any]) -> Job:
        job = self._running(job_id)
        job.state = State.COMPLETED
        job.finished_at = _now()
        job.result = result
        return job

    def mark_failed(self, job_id: int, code: str, message: str) -> Job:
        job = self._running(job_id)
        job.state = State.FAILED
        job.finished_at = _now()
        job.error_code = code
        job.error_message = message
        return job

    def sweep_stale(self, now: datetime | None = None) -> int:
        cutoff = (now or _now()) - self._stale_after
        swept = 0
        for job in self._jobs.values():
            if job.state is State.RUNNING:
                beat = job.heartbeat_at or job.reserved_at or job.created_at
                if beat < cutoff:
                    job.state = State.INTERRUPTED
                    job.finished_at = now or _now()
                    swept += 1
        return swept


def _iso(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


def _parse(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value else None


def _parse_required(value: str | None) -> datetime:
    """For NOT NULL timestamp columns. A real raise, not an assert: asserts are
    stripped under `python -O`, and a NULL here means the schema and the code
    disagree, which should be loud."""
    if value is None:
        raise ValueError("expected a timestamp, got NULL")
    return datetime.fromisoformat(value)


class SqliteStore:
    """Durable store. One writer connection, WAL so a reader can inspect live.

    Every mutation is a single statement inside a transaction, so reservation
    cannot hand the same job out twice even if two polls arrive together.

    FastAPI runs sync handlers on a threadpool, so the connection is opened with
    `check_same_thread=False` and every operation takes `_lock`. That is not a
    workaround: "one writer" is the design, and the lock is what enforces it.
    Readers wanting concurrency should open their own read-only connection --
    WAL is on precisely so they can, without blocking this one.
    """

    def __init__(self, path: str | Path, stale_after: timedelta = STALE_AFTER) -> None:
        self._stale_after = stale_after
        self._lock = threading.RLock()
        self._db = sqlite3.connect(str(path), isolation_level=None, check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._db.executescript(SCHEMA.read_text())

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # -- worlds ----------------------------------------------------------

    def register_world(self, name: str) -> World:
        # Adopt by name: installing the mod into a world the service already
        # knows must attach to that row, not fork a duplicate. The flip side is
        # documented -- binding a world *copy* under the same name merges it.
        with self._lock, self._db:
            row = self._db.execute("SELECT * FROM world WHERE name = ?", (name,)).fetchone()
            if row is not None:
                return self._world(row)
            cur = self._db.execute(
                "INSERT INTO world (name, created_at) VALUES (?, ?) RETURNING *",
                (name, _iso(_now())),
            )
            return self._world(cur.fetchone())

    def get_world(self, world_id: int) -> World:
        with self._lock:
            row = self._db.execute("SELECT * FROM world WHERE id = ?", (world_id,)).fetchone()
            if row is None:
                raise NotFound(f"no world {world_id}")
            return self._world(row)

    def list_worlds(self) -> list[World]:
        with self._lock:
            rows = self._db.execute("SELECT * FROM world ORDER BY id").fetchall()
            return [self._world(r) for r in rows]

    @staticmethod
    def _world(row: sqlite3.Row) -> World:
        return World(
            world_id=row["id"],
            name=row["name"],
            created_at=_parse_required(row["created_at"]),
        )

    # -- jobs ------------------------------------------------------------

    def create(self, world_id: int, request: JobRequest) -> Job:
        with self._lock:
            self.get_world(world_id)
            lo, hi = request.bounds.min, request.bounds.max
            with self._db:
                cur = self._db.execute(
                    """
                INSERT INTO job (
                    world_id, state, request_json,
                    bbox_min_x, bbox_min_y, bbox_min_z,
                    bbox_max_x, bbox_max_y, bbox_max_z,
                    created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                RETURNING *
                """,
                    (
                        world_id,
                        State.QUEUED.value,
                        request.model_dump_json(),
                        lo[0],
                        lo[1],
                        lo[2],
                        hi[0],
                        hi[1],
                        hi[2],
                        _iso(_now()),
                    ),
                )
                return self._job(cur.fetchone())

    def get(self, job_id: int) -> Job:
        with self._lock:
            row = self._db.execute("SELECT * FROM job WHERE id = ?", (job_id,)).fetchone()
            if row is None:
                raise NotFound(f"no job {job_id}")
            return self._job(row)

    def reserve(self, world_id: int) -> Job | None:
        with self._lock:
            # Scoped to the world, so a server is never offered another world's
            # work -- cross-world execution is impossible rather than caught later.
            now = _iso(_now())
            with self._db:
                cur = self._db.execute(
                    """
                UPDATE job SET state = ?, reserved_at = ?, heartbeat_at = ?
                WHERE id = (
                    SELECT id FROM job
                    WHERE world_id = ? AND state = ?
                    ORDER BY id LIMIT 1
                )
                RETURNING *
                """,
                    (State.RUNNING.value, now, now, world_id, State.QUEUED.value),
                )
                row = cur.fetchone()
            return self._job(row) if row else None

    def _transition(self, job_id: int, sql: str, params: tuple[Any, ...]) -> Job:
        with self._lock:
            with self._db:
                cur = self._db.execute(sql, (*params, job_id, State.RUNNING.value))
                row = cur.fetchone()
            if row is not None:
                return self._job(row)
            # The UPDATE matched nothing: either no such job, or it is not running.
            job = self.get(job_id)
            raise WrongState(f"job {job_id} is {job.state}, not running")

    def mark_started(self, job_id: int) -> Job:
        now = _iso(_now())
        return self._transition(
            job_id,
            "UPDATE job SET started_at = ?, heartbeat_at = ? "
            "WHERE id = ? AND state = ? RETURNING *",
            (now, now),
        )

    def mark_completed(self, job_id: int, result: dict[str, Any]) -> Job:
        return self._transition(
            job_id,
            "UPDATE job SET state = ?, finished_at = ?, result_json = ? "
            "WHERE id = ? AND state = ? RETURNING *",
            (State.COMPLETED.value, _iso(_now()), json.dumps(result)),
        )

    def mark_failed(self, job_id: int, code: str, message: str) -> Job:
        return self._transition(
            job_id,
            "UPDATE job SET state = ?, finished_at = ?, error_code = ?, error_message = ? "
            "WHERE id = ? AND state = ? RETURNING *",
            (State.FAILED.value, _iso(_now()), code, message),
        )

    def sweep_stale(self, now: datetime | None = None) -> int:
        """Step 3 of the recovery protocol: on service startup, any `running`
        job whose heartbeat has gone cold is `interrupted`. Covers the mod dying
        without getting its `abandoned` report out.

        `interrupted` is terminal. Requeue is manual, and does not exist before
        M6 -- a job that crashed the server would otherwise auto-retry into a
        crash loop.
        """
        stamp = now or _now()
        with self._lock, self._db:
            cur = self._db.execute(
                """
                UPDATE job SET state = ?, finished_at = ?
                WHERE state = ?
                  AND COALESCE(heartbeat_at, reserved_at, created_at) < ?
                """,
                (
                    State.INTERRUPTED.value,
                    _iso(stamp),
                    State.RUNNING.value,
                    _iso(stamp - self._stale_after),
                ),
            )
            return cur.rowcount

    @staticmethod
    def _job(row: sqlite3.Row) -> Job:
        return Job(
            job_id=row["id"],
            world_id=row["world_id"],
            request=JobRequest.model_validate_json(row["request_json"]),
            state=State(row["state"]),
            created_at=_parse_required(row["created_at"]),
            reserved_at=_parse(row["reserved_at"]),
            started_at=_parse(row["started_at"]),
            heartbeat_at=_parse(row["heartbeat_at"]),
            finished_at=_parse(row["finished_at"]),
            units_done=row["units_done"],
            units_total=row["units_total"],
            result=json.loads(row["result_json"]) if row["result_json"] else None,
            error_code=row["error_code"],
            error_message=row["error_message"],
        )
