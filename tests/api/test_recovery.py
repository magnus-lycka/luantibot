"""Step 3 of the crash recovery protocol: the service-startup sweep.

A `running` job whose heartbeat has gone cold means the mod died without getting
its report out. It becomes `interrupted` -- terminal, requeued only on an
explicit retry, which does not exist before M6 because there is no snapshot to
restore from first.
"""

from collections.abc import Callable
from datetime import timedelta
from pathlib import Path
from typing import Any

from fastapi.testclient import TestClient

from luantibot.service.app import create_app
from luantibot.service.store import STALE_AFTER, SqliteStore, State, _now

Submit = Callable[[dict[str, Any]], int]


def post_job(client: TestClient, doc: dict[str, Any]) -> int:
    """Submit against a caller-supplied client.

    The `submit` fixture is bound to the shared `client`; the restart tests
    below stand up their own, so they need this.
    """
    response = client.post("/v1/jobs", json=doc)
    assert response.status_code == 201, response.text
    return int(response.json()["job_id"])


def test_sweep_leaves_a_fresh_job_alone(
    client: TestClient, store: SqliteStore, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    submit(job_doc)
    client.get(f"/v1/worlds/{world_id}/jobs/next")

    assert store.sweep_stale() == 0


def test_sweep_interrupts_a_cold_job(
    client: TestClient, store: SqliteStore, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    job_id = submit(job_doc)
    client.get(f"/v1/worlds/{world_id}/jobs/next")

    assert store.sweep_stale(now=_now() + STALE_AFTER + timedelta(seconds=1)) == 1
    assert store.get(job_id).state is State.INTERRUPTED


def test_sweep_ignores_finished_jobs(
    client: TestClient, store: SqliteStore, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    job_id = submit(job_doc)
    client.get(f"/v1/worlds/{world_id}/jobs/next")
    client.post(f"/v1/jobs/{job_id}/completed", json={})

    assert store.sweep_stale(now=_now() + STALE_AFTER + timedelta(days=1)) == 0
    assert store.get(job_id).state is State.COMPLETED


def test_interrupted_jobs_are_not_handed_out_again(
    client: TestClient, store: SqliteStore, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    # Terminal until an explicit retry. Auto-requeue would let a job that
    # crashes the server retry into a crash loop.
    submit(job_doc)
    client.get(f"/v1/worlds/{world_id}/jobs/next")
    store.sweep_stale(now=_now() + STALE_AFTER + timedelta(seconds=1))

    assert client.get(f"/v1/worlds/{world_id}/jobs/next").status_code == 204


def test_state_survives_a_service_restart(tmp_path: Path, job_doc: dict[str, Any]) -> None:
    """The whole point of SQLite over the in-memory store."""
    db = tmp_path / "restart.sqlite"

    first = SqliteStore(db)
    with TestClient(create_app(first)) as client:
        job_id = post_job(client, job_doc)
        world_id = client.get(f"/v1/jobs/{job_id}").json()["world_id"]
    first.close()

    second = SqliteStore(db)
    with TestClient(create_app(second)) as client:
        row = client.get(f"/v1/jobs/{job_id}").json()
        assert row["state"] == "queued"
        assert row["world_id"] == world_id
        # The world registry survived too, so the mod's cached world_id still
        # resolves after a service restart -- which is the entire point of it
        # being stored rather than derived from the world's name.
        assert client.get(f"/v1/worlds/{world_id}").json()["name"] == job_doc["world"]
    second.close()


def test_startup_sweeps_a_job_left_running_by_a_crash(
    tmp_path: Path, job_doc: dict[str, Any]
) -> None:
    db = tmp_path / "crash.sqlite"

    first = SqliteStore(db)
    with TestClient(create_app(first)) as client:
        job_id = post_job(client, job_doc)
        world_id = client.get(f"/v1/jobs/{job_id}").json()["world_id"]
        client.get(f"/v1/worlds/{world_id}/jobs/next")
        # Reserved and never reported on. Now kill the service.
    first.close()

    # Restart with a zero staleness window, so the job reserved a moment ago is
    # already cold. Same production path as a real restart hours later.
    second = SqliteStore(db, stale_after=timedelta(0))
    with TestClient(create_app(second)) as client:
        assert client.get(f"/v1/jobs/{job_id}").json()["state"] == "interrupted"
    second.close()
