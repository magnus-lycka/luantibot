"""The `fill_box` op on the wire (M2).

The service cannot tell whether a palette entry names a real node -- only the
mod can resolve names to content ids. What it can check is arithmetic: an index
with no palette entry behind it, and a box reaching outside the region that will
be emerged. Both are rejected at submission, so the failure arrives as a 422
instead of as a job that dies two seconds later in-world.
"""

from collections.abc import Callable
from typing import Any

import pytest
from fastapi.testclient import TestClient

Submit = Callable[[dict[str, Any]], int]
FillJob = Callable[..., dict[str, Any]]


def reject(client: TestClient, doc: dict[str, Any]) -> str:
    response = client.post("/v1/jobs", json=doc)
    assert response.status_code == 422, response.text
    return response.text


def test_fill_box_job_is_accepted(submit: Submit, fill_job: FillJob) -> None:
    assert submit(fill_job()) > 0


def test_palette_and_ops_reach_the_mod(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    submit(fill_job())

    body = client.get(f"/v1/worlds/{world_id}/jobs/next").json()

    assert body["palette"] == ["air", "mcl_core:stone"]
    # Order is the contract: ops apply in the order given, shell before carve.
    assert [op["op"] for op in body["ops"]] == ["emerge", "fill_box"]
    assert body["ops"][1] == {
        "op": "fill_box",
        "min": [1, 1, 1],
        "max": [20, 5, 20],
        "node": 1,
    }


def test_op_order_is_preserved_verbatim(
    client: TestClient, world_id: int, submit: Submit, fill_job: FillJob
) -> None:
    ops = [
        {"op": "fill_box", "min": [0, 0, 0], "max": [4, 4, 4], "node": 1},
        {"op": "fill_box", "min": [1, 1, 1], "max": [3, 3, 3], "node": 0},
        {"op": "fill_box", "min": [2, 2, 2], "max": [2, 2, 2], "node": 1},
    ]
    submit(fill_job(ops=ops))

    body = client.get(f"/v1/worlds/{world_id}/jobs/next").json()
    assert body["ops"] == ops


def test_node_index_past_the_palette_is_rejected(client: TestClient, fill_job: FillJob) -> None:
    doc = fill_job(ops=[{"op": "fill_box", "min": [1, 1, 1], "max": [2, 2, 2], "node": 2}])
    assert "outside a palette of 2" in reject(client, doc)


def test_node_index_into_an_empty_palette_is_rejected(
    client: TestClient, fill_job: FillJob
) -> None:
    doc = fill_job(
        palette=[],
        ops=[{"op": "fill_box", "min": [1, 1, 1], "max": [2, 2, 2], "node": 0}],
    )
    assert "outside a palette of 0" in reject(client, doc)


@pytest.mark.parametrize(
    ("lo", "hi", "axes"),
    [
        ([0, 0, 0], [99, 5, 5], "x"),
        ([-1, 0, 0], [5, 5, 5], "x"),
        ([0, 0, 0], [5, 99, 99], "y, z"),
    ],
)
def test_box_outside_bounds_is_rejected(
    client: TestClient, fill_job: FillJob, lo: list[int], hi: list[int], axes: str
) -> None:
    doc = fill_job(ops=[{"op": "fill_box", "min": lo, "max": hi, "node": 0}])
    assert f"outside the job bounds on {axes}" in reject(client, doc)


def test_box_exactly_filling_the_bounds_is_accepted(submit: Submit, fill_job: FillJob) -> None:
    doc = fill_job(ops=[{"op": "fill_box", "min": [0, 0, 0], "max": [31, 31, 31], "node": 0}])
    assert submit(doc) > 0


def test_inverted_box_is_rejected(client: TestClient, fill_job: FillJob) -> None:
    doc = fill_job(ops=[{"op": "fill_box", "min": [5, 0, 0], "max": [1, 5, 5], "node": 0}])
    assert "min must not exceed max" in reject(client, doc)


def test_negative_node_index_is_rejected(client: TestClient, fill_job: FillJob) -> None:
    doc = fill_job(ops=[{"op": "fill_box", "min": [1, 1, 1], "max": [2, 2, 2], "node": -1}])
    reject(client, doc)


def test_unknown_op_is_rejected(client: TestClient, fill_job: FillJob) -> None:
    reject(client, fill_job(ops=[{"op": "summon_dragon"}]))


def test_missing_box_is_rejected(client: TestClient, fill_job: FillJob) -> None:
    reject(client, fill_job(ops=[{"op": "fill_box", "node": 0}]))


def test_extra_field_on_an_op_is_rejected(client: TestClient, fill_job: FillJob) -> None:
    """Strict models everywhere: a typo'd key must not be silently dropped."""
    doc = fill_job(
        ops=[{"op": "fill_box", "min": [1, 1, 1], "max": [2, 2, 2], "node": 0, "nodes": 1}]
    )
    reject(client, doc)
