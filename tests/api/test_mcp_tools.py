"""MCP tools, exercised against a real service.

The tools are thin, but they are the whole surface an agent sees, so what
matters is that they behave sensibly against a live API and degrade readably
when it is absent. `SERVICE_URL` is read at import, so these point the module's
client factory at the test app instead.
"""

from collections.abc import Iterator
from typing import Any

import pytest
from fastapi.testclient import TestClient

from luantibot import mcp_server


class _Borrowed:
    """Lends the shared TestClient to code that owns its client.

    The tools use `with _client() as c:` and would otherwise close the fixture's
    client -- shutting down the app for every later assertion in the test.
    """

    def __init__(self, inner: TestClient) -> None:
        self._inner = inner

    def __enter__(self) -> TestClient:
        return self._inner

    def __exit__(self, *exc: object) -> bool:
        return False

    def __getattr__(self, name: str) -> Any:
        return getattr(self._inner, name)


@pytest.fixture
def tools(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Point the tools' HTTP client at the in-process test app."""
    monkeypatch.setattr(mcp_server, "_client", lambda: _Borrowed(client))
    yield


@pytest.fixture
def broken(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    def explode() -> Any:
        raise ConnectionError("connection refused")

    monkeypatch.setattr(mcp_server, "_client", explode)
    yield


class TestEmergeArea:
    def test_submits_a_job_and_reports_cost(self, tools: None) -> None:
        result = mcp_server.emerge_area("TestWorld", 0, 0, 0, 32)

        assert result["job_id"] > 0
        # Blocks -2..2 on each axis: the cube [-32, 32] is expanded out to
        # whole mapblocks, so 5^3 = 125 and the far corner lands on 47.
        assert result["mapblocks"] == 125
        assert result["bounds"] == {"min": [-32, -32, -32], "max": [47, 47, 47]}

    def test_the_job_is_queued_for_the_named_world(self, tools: None, client: TestClient) -> None:
        result = mcp_server.emerge_area("TestWorld", 0, 0, 0, 16)
        row = client.get(f"/v1/jobs/{result['job_id']}").json()

        assert row["world"] == "TestWorld"
        assert row["state"] == "queued"
        assert row["request"]["ops"] == [{"op": "emerge"}]

    def test_refuses_an_oversized_radius_without_submitting(
        self, tools: None, client: TestClient
    ) -> None:
        # The agent should be told immediately, not watch a job fail in-world.
        result = mcp_server.emerge_area("TestWorld", 0, 0, 0, 128)

        assert "error" in result
        assert "4913" in result["error"]
        assert client.get("/v1/worlds").json() == []

    def test_rejects_a_negative_radius(self, tools: None) -> None:
        assert "error" in mcp_server.emerge_area("TestWorld", 0, 0, 0, -1)

    def test_explains_an_unreachable_service(self, broken: None) -> None:
        result = mcp_server.emerge_area("TestWorld", 0, 0, 0, 16)

        assert "error" in result
        assert "luantibot.service" in result["hint"]


class TestJobStatus:
    def test_reports_state_and_result(self, tools: None, client: TestClient, world_id: int) -> None:
        job_id = mcp_server.emerge_area("TestWorld", 0, 0, 0, 16)["job_id"]
        client.get(f"/v1/worlds/{world_id}/jobs/next")
        client.post(f"/v1/jobs/{job_id}/completed", json={"blocks": 27})

        status = mcp_server.job_status(job_id)
        assert status["state"] == "completed"
        assert status["result"] == {"blocks": 27}
        assert status["world"] == "TestWorld"

    def test_surfaces_a_failure_message(
        self, tools: None, client: TestClient, world_id: int
    ) -> None:
        job_id = mcp_server.emerge_area("TestWorld", 0, 0, 0, 16)["job_id"]
        client.get(f"/v1/worlds/{world_id}/jobs/next")
        client.post(
            f"/v1/jobs/{job_id}/failed",
            json={"code": "emerge_failed", "message": "3 mapblocks errored"},
        )

        status = mcp_server.job_status(job_id)
        assert status["state"] == "failed"
        assert status["error_code"] == "emerge_failed"
        assert "3 mapblocks" in status["error_message"]

    def test_unknown_job(self, tools: None) -> None:
        assert "error" in mcp_server.job_status(999)


class TestListWorlds:
    def test_lists_registered_worlds(self, tools: None, world_id: int) -> None:
        names = [w["name"] for w in mcp_server.list_worlds()["worlds"]]
        assert names == ["TestWorld"]

    def test_explains_an_unreachable_service(self, broken: None) -> None:
        assert "error" in mcp_server.list_worlds()


class TestBuildHistory:
    def test_most_recent_first(self, tools: None) -> None:
        first = mcp_server.emerge_area("TestWorld", 0, 0, 0, 16)["job_id"]
        second = mcp_server.emerge_area("TestWorld", 100, 0, 100, 16)["job_id"]

        jobs = mcp_server.build_history("TestWorld")["jobs"]
        assert [j["job_id"] for j in jobs] == [second, first]
        assert jobs[0]["ops"] == ["emerge"]

    def test_is_world_scoped(self, tools: None) -> None:
        mcp_server.emerge_area("TestWorld", 0, 0, 0, 16)
        mcp_server.emerge_area("OtherWorld", 0, 0, 0, 16)

        assert len(mcp_server.build_history("TestWorld")["jobs"]) == 1
        assert len(mcp_server.build_history("OtherWorld")["jobs"]) == 1

    def test_names_the_known_worlds_when_asked_for_a_missing_one(
        self, tools: None, world_id: int
    ) -> None:
        result = mcp_server.build_history("Nowhere")

        assert "error" in result
        assert result["known_worlds"] == ["TestWorld"]


class TestFillBox:
    def test_submits_emerge_then_fill(self, tools: None, client: TestClient) -> None:
        result = mcp_server.fill_box("TestWorld", 0, 0, 0, 19, 4, 19, "mcl_core:stone")

        assert result["job_id"] > 0
        row = client.get(f"/v1/jobs/{result['job_id']}").json()

        # Terrain has to exist before it can be overwritten, so every fill
        # carries its own emerge.
        assert row["request"]["ops"] == [
            {"op": "emerge"},
            {"op": "fill_box", "min": [0, 0, 0], "max": [19, 4, 19], "node": 0, "param2": 0},
        ]
        assert row["request"]["palette"] == ["mcl_core:stone"]

    def test_bounds_are_rounded_out_but_the_box_is_not(self, tools: None) -> None:
        """The emerged region snaps to mapblocks; what gets written must not."""
        result = mcp_server.fill_box("TestWorld", 1, 1, 1, 2, 2, 2, "air")

        assert result["bounds"] == {"min": [0, 0, 0], "max": [15, 15, 15]}
        assert result["mapblocks"] == 1

    def test_accepts_corners_in_any_order(self, tools: None, client: TestClient) -> None:
        result = mcp_server.fill_box("TestWorld", 19, 4, 19, 0, 0, 0, "air")
        row = client.get(f"/v1/jobs/{result['job_id']}").json()

        assert row["request"]["ops"][1]["min"] == [0, 0, 0]
        assert row["request"]["ops"][1]["max"] == [19, 4, 19]

    def test_refuses_an_oversized_box_without_submitting(
        self, tools: None, client: TestClient
    ) -> None:
        result = mcp_server.fill_box("TestWorld", 0, 0, 0, 2000, 200, 2000, "air")

        assert "error" in result
        assert client.get("/v1/worlds").json() == []

    def test_reports_a_missing_service_readably(self, broken: None) -> None:
        result = mcp_server.fill_box("TestWorld", 0, 0, 0, 1, 1, 1, "air")
        assert "not reachable" in result["error"]

    def test_param2_reaches_the_job(self, tools: None, client: TestClient) -> None:
        result = mcp_server.fill_box(
            "TestWorld", 0, 0, 0, 1, 1, 1, "mcl_doors:iron_trapdoor", param2=2
        )
        row = client.get(f"/v1/jobs/{result['job_id']}").json()
        assert row["request"]["ops"][1]["param2"] == 2


class TestFillBoxIf:
    def test_submits_a_conditional_fill(self, tools: None, client: TestClient) -> None:
        result = mcp_server.fill_box_if(
            "TestWorld", 0, 0, 0, 4, 40, 4, "mcl_core:stone", ["air", "group:liquid"]
        )
        row = client.get(f"/v1/jobs/{result['job_id']}").json()

        assert row["request"]["ops"][1] == {
            "op": "fill_box_if",
            "min": [0, 0, 0],
            "max": [4, 40, 4],
            "node": 0,
            "param2": 0,
            "match": ["air", "group:liquid"],
            "invert": False,
        }
        assert row["request"]["palette"] == ["mcl_core:stone"]

    def test_invert_is_carried(self, tools: None, client: TestClient) -> None:
        result = mcp_server.fill_box_if("TestWorld", 0, 0, 0, 1, 1, 1, "air", ["air"], invert=True)
        row = client.get(f"/v1/jobs/{result['job_id']}").json()
        assert row["request"]["ops"][1]["invert"] is True

    def test_refuses_an_empty_match(self, tools: None, client: TestClient) -> None:
        result = mcp_server.fill_box_if("TestWorld", 0, 0, 0, 1, 1, 1, "air", [])
        assert "error" in result


class TestServiceDown:
    """Every tool degrades to the same readable error, not a traceback.

    This is the first thing an agent sees when the service is not running, and
    it is the message that has to say what to start.
    """

    def test_job_status_says_what_to_start(self, broken: None) -> None:
        result = mcp_server.job_status(1)
        assert "not reachable" in result["error"]
        assert "luantibot.service" in result["hint"]

    def test_build_history_says_what_to_start(self, broken: None) -> None:
        result = mcp_server.build_history("TestWorld")
        assert "not reachable" in result["error"]

    def test_list_worlds_says_what_to_start(self, broken: None) -> None:
        assert "not reachable" in mcp_server.list_worlds()["error"]


def test_emerge_slab_refuses_a_bad_side_without_submitting(tools: None, client: TestClient) -> None:
    """geometry.slab raises rather than returning; the tool has to turn that into
    an error an agent can read, not a traceback."""
    result = mcp_server.emerge_slab("TestWorld", 0, 0, 0, 0, 15)

    assert "side must be positive" in result["error"]
    assert client.get("/v1/worlds").json() == []
