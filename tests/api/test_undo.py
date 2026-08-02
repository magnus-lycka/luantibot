"""`undo` (M6).

Undoing is work, not a state change: it can fail, it takes time, and it wants
the same lifecycle as any other job. So it enqueues one, and the original row is
left exactly as it was — history should say what happened, not what was later
regretted.
"""

from collections.abc import Callable
from typing import Any

from fastapi.testclient import TestClient

Submit = Callable[[dict[str, Any]], int]
FillJob = Callable[..., dict[str, Any]]


def run_to_completion(client: TestClient, world_id: int, job_id: int) -> None:
    client.get(f"/v1/worlds/{world_id}/jobs/next")
    client.post(f"/v1/jobs/{job_id}/started")
    client.post(f"/v1/jobs/{job_id}/completed", json={})


def test_undo_enqueues_a_restore_job(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    original = submit(fill_job())
    run_to_completion(client, world_id, original)

    response = client.post(f"/v1/jobs/{original}/undo")
    assert response.status_code == 201

    undo_id = response.json()["job_id"]
    row = client.get(f"/v1/jobs/{undo_id}").json()
    assert row["state"] == "queued"
    assert row["request"]["ops"] == [
        {
            "op": "restore",
            "min": [0, 0, 0],
            "max": [31, 31, 31],
            "job": original,
        }
    ]


def test_the_restore_covers_the_original_bounds(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    """Not the op boxes: a unit the ops never touched was still snapshotted if
    anything in it was written, and the whole region has to come back."""
    original = submit(fill_job())
    run_to_completion(client, world_id, original)

    undo_id = client.post(f"/v1/jobs/{original}/undo").json()["job_id"]
    row = client.get(f"/v1/jobs/{undo_id}").json()
    assert row["request"]["bounds"] == {"min": [0, 0, 0], "max": [31, 31, 31]}


def test_the_undo_job_goes_to_the_same_world(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    original = submit(fill_job())
    run_to_completion(client, world_id, original)

    response = client.post(f"/v1/jobs/{original}/undo")
    assert response.json()["world_id"] == world_id


def test_the_original_row_is_untouched(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    original = submit(fill_job())
    run_to_completion(client, world_id, original)
    before = client.get(f"/v1/jobs/{original}").json()

    client.post(f"/v1/jobs/{original}/undo")

    assert client.get(f"/v1/jobs/{original}").json() == before


def test_a_queued_job_cannot_be_undone(
    client: TestClient, submit: Submit, fill_job: FillJob
) -> None:
    """It never ran, so there are no snapshots and nothing to put back."""
    original = submit(fill_job())
    response = client.post(f"/v1/jobs/{original}/undo")
    assert response.status_code == 409
    assert "nothing to undo" in response.text


def test_a_failed_job_can_be_undone(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    """This is the case that matters most: a job that died partway wrote some
    units and the operator wants them back."""
    original = submit(fill_job())
    client.get(f"/v1/worlds/{world_id}/jobs/next")
    client.post(f"/v1/jobs/{original}/failed", json={"code": "emerge_failed"})

    assert client.post(f"/v1/jobs/{original}/undo").status_code == 201


def test_an_abandoned_job_can_be_undone(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    original = submit(fill_job())
    client.get(f"/v1/worlds/{world_id}/jobs/next")
    client.post(f"/v1/jobs/{original}/abandoned")

    assert client.post(f"/v1/jobs/{original}/undo").status_code == 201


def test_undoing_an_undo_is_allowed(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    """A restore is a build like any other. Whether its own snapshots are useful
    is the mod's business, not the API's."""
    original = submit(fill_job())
    run_to_completion(client, world_id, original)
    undo_id = client.post(f"/v1/jobs/{original}/undo").json()["job_id"]
    run_to_completion(client, world_id, undo_id)

    second = client.post(f"/v1/jobs/{undo_id}/undo")
    assert second.status_code == 201
    row = client.get(f"/v1/jobs/{second.json()['job_id']}").json()
    assert row["request"]["ops"][0]["job"] == undo_id


def test_undoing_a_job_that_does_not_exist(client: TestClient) -> None:
    assert client.post("/v1/jobs/9999/undo").status_code == 404


# --- retry ---------------------------------------------------------------


def interrupt(client: TestClient, world_id: int, job_id: int) -> None:
    client.get(f"/v1/worlds/{world_id}/jobs/next")
    client.post(f"/v1/jobs/{job_id}/abandoned")


def test_retry_restores_then_re_runs(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    """The restore comes first, and the original ops follow unchanged. Not a
    resumption: an interrupted job left a state nobody described."""
    original = submit(fill_job())
    interrupt(client, world_id, original)

    retry_id = client.post(f"/v1/jobs/{original}/retry").json()["job_id"]
    ops = client.get(f"/v1/jobs/{retry_id}").json()["request"]["ops"]

    assert ops[0] == {
        "op": "restore",
        "min": [0, 0, 0],
        "max": [31, 31, 31],
        "job": original,
    }
    assert [o["op"] for o in ops[1:]] == ["emerge", "fill_box"]


def test_retry_keeps_the_palette(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    """The re-run resolves the same names, so a job whose palette was dropped
    would fail on its own ops."""
    original = submit(fill_job())
    interrupt(client, world_id, original)

    retry_id = client.post(f"/v1/jobs/{original}/retry").json()["job_id"]
    row = client.get(f"/v1/jobs/{retry_id}").json()
    assert row["request"]["palette"] == ["air", "mcl_core:stone"]


def test_retry_is_for_a_job_that_stopped(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    queued = submit(fill_job())
    assert client.post(f"/v1/jobs/{queued}/retry").status_code == 409

    client.get(f"/v1/worlds/{world_id}/jobs/next")  # now running
    assert client.post(f"/v1/jobs/{queued}/retry").status_code == 409


def test_an_interrupted_job_can_be_retried(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    original = submit(fill_job())
    interrupt(client, world_id, original)
    assert client.post(f"/v1/jobs/{original}/retry").status_code == 201


def test_a_failed_job_can_be_retried(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    original = submit(fill_job())
    client.get(f"/v1/worlds/{world_id}/jobs/next")
    client.post(f"/v1/jobs/{original}/failed", json={"code": "emerge_failed"})
    assert client.post(f"/v1/jobs/{original}/retry").status_code == 201


def test_retry_snapshots_are_attributed_to_the_original(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    """The restore op names the first attempt, and that id is also where the
    re-run records the units the first attempt never reached — which is what
    makes the write-once rule span attempts."""
    original = submit(fill_job())
    interrupt(client, world_id, original)

    first = client.post(f"/v1/jobs/{original}/retry").json()["job_id"]
    interrupt(client, world_id, first)
    second = client.post(f"/v1/jobs/{first}/retry").json()["job_id"]

    ops = client.get(f"/v1/jobs/{second}").json()["request"]["ops"]
    # Retrying a retry names the retry, not the first attempt: each restores
    # whatever the job it names recorded.
    assert ops[0]["job"] == first


def test_retrying_a_job_that_does_not_exist(client: TestClient) -> None:
    assert client.post("/v1/jobs/9999/retry").status_code == 404
