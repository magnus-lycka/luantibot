"""Job lifecycle over HTTP: submit, reserve, report."""

from collections.abc import Callable
from typing import Any

from fastapi.testclient import TestClient

Submit = Callable[[dict[str, Any]], int]


def test_submit_returns_a_job_id(
    client: TestClient, job_doc: dict[str, Any], submit: Submit
) -> None:
    assert submit(job_doc) > 0


def test_submitted_job_starts_queued(
    client: TestClient, job_doc: dict[str, Any], submit: Submit
) -> None:
    job_id = submit(job_doc)
    row = client.get(f"/v1/jobs/{job_id}").json()
    assert row["state"] == "queued"
    assert row["reserved_at"] is None


def test_fetch_next_returns_the_job(
    client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    job_id = submit(job_doc)

    response = client.get(f"/v1/worlds/{world_id}/jobs/next")
    assert response.status_code == 200
    body = response.json()

    assert body["job_id"] == job_id
    assert body["format"] == 1
    assert body["ops"] == [{"op": "emerge"}]
    assert body["bounds"] == {"min": [-32, -32, -32], "max": [31, 31, 31]}


def test_fetch_next_is_204_when_idle(client: TestClient, world_id: int) -> None:
    response = client.get(f"/v1/worlds/{world_id}/jobs/next")
    assert response.status_code == 204
    assert not response.content


def test_reservation_happens_once(
    client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    submit(job_doc)

    assert client.get(f"/v1/worlds/{world_id}/jobs/next").status_code == 200
    # The job is now running. A second poll must not hand out the same work.
    assert client.get(f"/v1/worlds/{world_id}/jobs/next").status_code == 204


def test_reservation_records_world_and_state(
    client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    job_id = submit(job_doc)
    client.get(f"/v1/worlds/{world_id}/jobs/next")

    row = client.get(f"/v1/jobs/{job_id}").json()
    assert row["state"] == "running"
    assert row["world_id"] == world_id
    assert row["started_at"] is None, "reserved is not the same as started"


def test_jobs_are_handed_out_in_submission_order(
    client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    first = submit(job_doc)
    second = submit(job_doc)

    assert client.get(f"/v1/worlds/{world_id}/jobs/next").json()["job_id"] == first
    client.post(f"/v1/jobs/{first}/completed", json={"changed_nodes": 0})
    assert client.get(f"/v1/worlds/{world_id}/jobs/next").json()["job_id"] == second


def test_started_is_recorded(
    client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    job_id = submit(job_doc)
    client.get(f"/v1/worlds/{world_id}/jobs/next")

    assert client.post(f"/v1/jobs/{job_id}/started", json={}).status_code == 204

    row = client.get(f"/v1/jobs/{job_id}").json()
    assert row["started_at"] is not None
    assert row["state"] == "running"


def test_completion_records_the_result(
    client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    job_id = submit(job_doc)
    client.get(f"/v1/worlds/{world_id}/jobs/next")

    result = {"changed_nodes": 0, "blocks": 8}
    assert client.post(f"/v1/jobs/{job_id}/completed", json=result).status_code == 204

    row = client.get(f"/v1/jobs/{job_id}").json()
    assert row["state"] == "completed"
    assert row["finished_at"] is not None
    assert row["result"] == result


def test_failure_records_code_and_message(
    client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    job_id = submit(job_doc)
    client.get(f"/v1/worlds/{world_id}/jobs/next")

    failure = {"code": "unknown_node", "message": "mcl_core:nope is not registered"}
    assert client.post(f"/v1/jobs/{job_id}/failed", json=failure).status_code == 204

    row = client.get(f"/v1/jobs/{job_id}").json()
    assert row["state"] == "failed"
    assert row["error_code"] == "unknown_node"
    assert row["error_message"] == "mcl_core:nope is not registered"


def test_a_finished_job_is_not_handed_out_again(
    client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    job_id = submit(job_doc)
    client.get(f"/v1/worlds/{world_id}/jobs/next")
    client.post(f"/v1/jobs/{job_id}/completed", json={})

    assert client.get(f"/v1/worlds/{world_id}/jobs/next").status_code == 204


class TestRejections:
    def test_unknown_job_is_404(self, client: TestClient) -> None:
        assert client.get("/v1/jobs/999").status_code == 404
        assert client.post("/v1/jobs/999/completed", json={}).status_code == 404

    def test_reporting_on_a_queued_job_is_409(
        self, client: TestClient, job_doc: dict[str, Any], submit: Submit
    ) -> None:
        job_id = submit(job_doc)
        # Never reserved, so the mod cannot legitimately be reporting on it.
        assert client.post(f"/v1/jobs/{job_id}/completed", json={}).status_code == 409

    def test_double_completion_is_409(
        self, client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
    ) -> None:
        job_id = submit(job_doc)
        client.get(f"/v1/worlds/{world_id}/jobs/next")
        client.post(f"/v1/jobs/{job_id}/completed", json={})

        assert client.post(f"/v1/jobs/{job_id}/completed", json={}).status_code == 409

    def test_unknown_wire_format_is_rejected(
        self, client: TestClient, job_doc: dict[str, Any]
    ) -> None:
        assert client.post("/v1/jobs", json={**job_doc, "format": 99}).status_code == 422

    def test_unknown_op_is_rejected(
        self, client: TestClient, job_doc: dict[str, Any], submit: Submit
    ) -> None:
        doc = {**job_doc, "ops": [{"op": "detonate"}]}
        assert client.post("/v1/jobs", json=doc).status_code == 422

    def test_unknown_field_is_rejected(
        self, client: TestClient, job_doc: dict[str, Any], submit: Submit
    ) -> None:
        # A typo'd key must fail loudly rather than be dropped, or the build
        # silently does something other than what was asked.
        doc = {**job_doc, "bounds_": job_doc["bounds"]}
        assert client.post("/v1/jobs", json=doc).status_code == 422

    def test_malformed_bounds_are_rejected(
        self, client: TestClient, job_doc: dict[str, Any]
    ) -> None:
        doc = {**job_doc, "bounds": {"min": [0, 0], "max": [1, 1, 1]}}
        assert client.post("/v1/jobs", json=doc).status_code == 422

    def test_non_integer_coordinates_are_rejected(
        self, client: TestClient, job_doc: dict[str, Any]
    ) -> None:
        doc = {**job_doc, "bounds": {"min": [0.5, 0, 0], "max": [1, 1, 1]}}
        assert client.post("/v1/jobs", json=doc).status_code == 422

    def test_inverted_bounds_are_rejected(
        self, client: TestClient, job_doc: dict[str, Any]
    ) -> None:
        doc = {**job_doc, "bounds": {"min": [10, 0, 0], "max": [0, 1, 1]}}
        assert client.post("/v1/jobs", json=doc).status_code == 422

    def test_empty_op_list_is_rejected(
        self, client: TestClient, job_doc: dict[str, Any], submit: Submit
    ) -> None:
        assert client.post("/v1/jobs", json={**job_doc, "ops": []}).status_code == 422
