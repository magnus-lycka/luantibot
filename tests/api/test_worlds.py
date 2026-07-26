"""World identity: registration, scoping, and durability across renames.

Build history is world-scoped and permanent, so these are the tests that protect
"what did I build, and where" -- see "World identity" in
docs/implementation_plan.md.
"""

from collections.abc import Callable
from typing import Any

from fastapi.testclient import TestClient

Submit = Callable[[dict[str, Any]], int]
Register = Callable[[str], int]


def test_registration_returns_an_id(client: TestClient, register: Register) -> None:
    assert register("Marduk1") > 0


def test_registration_adopts_an_existing_world_by_name(
    client: TestClient, register: Register
) -> None:
    # A mod installed into a world the service already knows must attach to
    # that row, not fork a duplicate and detach its build history.
    first = register("Marduk1")
    second = register("Marduk1")

    assert first == second
    assert len(client.get("/v1/worlds").json()) == 1


def test_distinct_names_are_distinct_worlds(client: TestClient, register: Register) -> None:
    # This is how a copied world is split off: bind it under a new name.
    assert register("Marduk1") != register("Marduk1_v2")
    assert len(client.get("/v1/worlds").json()) == 2


def test_unknown_world_is_404(client: TestClient, register: Register) -> None:
    assert client.get("/v1/worlds/999").status_code == 404
    assert client.get("/v1/worlds/999/jobs/next").status_code == 404


def test_submitting_registers_the_named_world(
    client: TestClient, job_doc: dict[str, Any], submit: Submit, register: Register
) -> None:
    response = client.post("/v1/jobs", json=job_doc)
    assert response.status_code == 201

    world_id = response.json()["world_id"]
    assert client.get(f"/v1/worlds/{world_id}").json()["name"] == job_doc["world"]


def test_a_job_is_never_offered_to_another_world(
    client: TestClient, job_doc: dict[str, Any], submit: Submit, register: Register
) -> None:
    """The guard that makes cross-world execution structurally impossible.

    If this ever fails, a job compiled for one world could be applied to
    another -- irreversibly, once fill_box exists in M2.
    """
    mine = register("Marduk1")
    other = register("Marduk1_v2")
    submit(job_doc)  # belongs to Marduk1

    assert client.get(f"/v1/worlds/{other}/jobs/next").status_code == 204
    assert client.get(f"/v1/worlds/{mine}/jobs/next").status_code == 200


def test_each_world_gets_its_own_queue(
    client: TestClient, job_doc: dict[str, Any], submit: Submit, register: Register
) -> None:
    mine = register("Marduk1")
    other = register("Marduk1_v2")

    a = submit(job_doc)
    b = submit({**job_doc, "world": "Marduk1_v2"})

    assert client.get(f"/v1/worlds/{mine}/jobs/next").json()["job_id"] == a
    assert client.get(f"/v1/worlds/{other}/jobs/next").json()["job_id"] == b


def test_job_document_carries_world_id_and_name(
    client: TestClient, job_doc: dict[str, Any], world_id: int, submit: Submit
) -> None:
    # Names for humans, ids for machines: the mod matches on world_id and logs
    # the name.
    submit(job_doc)
    body = client.get(f"/v1/worlds/{world_id}/jobs/next").json()

    assert body["world_id"] == world_id
    assert body["world"] == job_doc["world"]


def test_history_is_world_scoped(
    client: TestClient, job_doc: dict[str, Any], submit: Submit, register: Register
) -> None:
    job_id = submit(job_doc)
    row = client.get(f"/v1/jobs/{job_id}").json()

    assert row["world"] == "Marduk1"
    assert row["world_id"] == register("Marduk1")
