"""Progress and the recovery protocol (M4).

Before work units a job was one burst of work, so a long job and a dead one
looked identical after five minutes of silence. Units make progress reportable,
and a job that reports cannot be mistaken for a corpse.
"""

from collections.abc import Callable
from typing import Any

from fastapi.testclient import TestClient

Submit = Callable[[dict[str, Any]], int]


def reserve(client: TestClient, world_id: int) -> dict[str, Any]:
    response = client.get(f"/v1/worlds/{world_id}/jobs/next")
    assert response.status_code == 200, response.text
    return response.json()


def test_progress_advances_the_unit_counters(
    client: TestClient, world_id: int, job_doc: dict[str, Any], submit: Submit
) -> None:
    job_id = submit(job_doc)
    reserve(client, world_id)

    assert (
        client.post(
            f"/v1/jobs/{job_id}/progress", json={"units_done": 3, "units_total": 8}
        ).status_code
        == 204
    )

    row = client.get(f"/v1/jobs/{job_id}").json()
    assert (row["units_done"], row["units_total"]) == (3, 8)
    assert row["state"] == "running"


def test_progress_renews_the_heartbeat(
    client: TestClient, world_id: int, job_doc: dict[str, Any], submit: Submit
) -> None:
    """The whole point: a reporting job must not be swept as stale."""
    job_id = submit(job_doc)
    reserve(client, world_id)
    before = client.get(f"/v1/jobs/{job_id}").json()["heartbeat_at"]

    client.post(f"/v1/jobs/{job_id}/progress", json={"units_done": 1, "units_total": 4})

    after = client.get(f"/v1/jobs/{job_id}").json()["heartbeat_at"]
    assert after > before


def test_progress_on_a_job_that_is_not_running_is_refused(
    client: TestClient, job_doc: dict[str, Any], submit: Submit
) -> None:
    job_id = submit(job_doc)  # queued, never reserved
    response = client.post(f"/v1/jobs/{job_id}/progress", json={"units_done": 1, "units_total": 2})
    assert response.status_code == 409


def test_abandoned_is_reported_not_inferred(
    client: TestClient, world_id: int, job_doc: dict[str, Any], submit: Submit
) -> None:
    job_id = submit(job_doc)
    reserve(client, world_id)

    assert client.post(f"/v1/jobs/{job_id}/abandoned").status_code == 204

    row = client.get(f"/v1/jobs/{job_id}").json()
    assert row["state"] == "abandoned"
    assert row["finished_at"] is not None


def test_abandoned_is_terminal(
    client: TestClient, world_id: int, job_doc: dict[str, Any], submit: Submit
) -> None:
    job_id = submit(job_doc)
    reserve(client, world_id)
    client.post(f"/v1/jobs/{job_id}/abandoned")

    # No further reports land on it -- retry arrives with snapshots in M6.
    assert client.post(f"/v1/jobs/{job_id}/completed", json={}).status_code == 409
    assert (
        client.post(
            f"/v1/jobs/{job_id}/progress", json={"units_done": 1, "units_total": 2}
        ).status_code
        == 409
    )


def test_an_abandoned_job_is_not_handed_out_again(
    client: TestClient, world_id: int, job_doc: dict[str, Any], submit: Submit
) -> None:
    submit(job_doc)
    reserve(client, world_id)
    job_id = client.get(f"/v1/worlds/{world_id}/jobs").json()[0]["job_id"]
    client.post(f"/v1/jobs/{job_id}/abandoned")

    assert client.get(f"/v1/worlds/{world_id}/jobs/next").status_code == 204


def test_abandoned_appears_in_the_state_list(client: TestClient) -> None:
    assert "abandoned" in client.get("/v1/health").json()["states"]


def test_a_completed_job_reads_as_fully_done(
    client: TestClient, world_id: int, job_doc: dict[str, Any], submit: Submit
) -> None:
    """The completion report outranks queued progress, so the last unit's report
    is normally overtaken by it. A finished job must still read n/n rather than
    n-1/n, which looks stranded."""
    job_id = submit(job_doc)
    reserve(client, world_id)
    client.post(f"/v1/jobs/{job_id}/progress", json={"units_done": 4, "units_total": 5})

    client.post(f"/v1/jobs/{job_id}/completed", json={})

    row = client.get(f"/v1/jobs/{job_id}").json()
    assert (row["units_done"], row["units_total"]) == (5, 5)
