"""Fixtures for the HTTP API tests.

These tests exercise the HTTP surface only. Swapping the store underneath them
(in-memory -> SQLite in M1.3) changed only this file: that is the proof the API
contract does not leak the storage schema.
"""

from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from luantibot.service.app import create_app
from luantibot.service.store import InMemoryStore, SqliteStore, Store

WORLD_NAME = "TestWorld"


@pytest.fixture(params=["sqlite", "memory"])
def store(request: pytest.FixtureRequest, tmp_path: Path) -> Iterator[Store]:
    """Every API test runs against both implementations of the Store protocol.

    The claim in the module docstring above -- that swapping the store changed
    only this file, and that this proves the API contract does not leak the
    storage schema -- was true when written and then quietly stopped being
    checked. Only SQLite was exercised, so the in-memory implementation could
    drift without anything failing, and during M4 it did: two new transitions
    were written into both stores and run in one.
    """
    if request.param == "sqlite":
        sqlite = SqliteStore(tmp_path / "luantibot.sqlite")
        yield sqlite
        sqlite.close()
    else:
        yield InMemoryStore()


@pytest.fixture
def client(store: Store) -> Iterator[TestClient]:
    with TestClient(create_app(store)) as c:
        yield c


@pytest.fixture
def world_id(client: TestClient) -> int:
    """The single Luanti server that polls this service. Server is world."""
    response = client.post("/v1/worlds", json={"name": WORLD_NAME})
    assert response.status_code == 201, response.text
    return int(response.json()["world_id"])


@pytest.fixture
def job_doc() -> dict[str, Any]:
    """A minimal valid job: emerge one region, touching nothing."""
    return {
        "format": 1,
        "world": WORLD_NAME,
        "bounds": {"min": [-32, -32, -32], "max": [31, 31, 31]},
        "ops": [{"op": "emerge"}],
    }


@pytest.fixture
def fill_job() -> Callable[..., dict[str, Any]]:
    """Factory for a job that emerges a region and fills a box inside it (M2).

    A factory rather than a plain dict because most of these tests vary one
    field and keep the rest valid, and a shared mutable dict would let one
    test's edit leak into the next.
    """

    def _fill_job(**overrides: Any) -> dict[str, Any]:
        doc: dict[str, Any] = {
            "format": 1,
            "world": WORLD_NAME,
            "palette": ["air", "mcl_core:stone"],
            "bounds": {"min": [0, 0, 0], "max": [31, 31, 31]},
            "ops": [
                {"op": "emerge"},
                {"op": "fill_box", "min": [1, 1, 1], "max": [20, 5, 20], "node": 1},
            ],
        }
        doc.update(overrides)
        return doc

    return _fill_job


@pytest.fixture
def submit(client: TestClient) -> Callable[[dict[str, Any]], int]:
    """Submit a job and return its id, asserting the submission succeeded."""

    def _submit(doc: dict[str, Any]) -> int:
        response = client.post("/v1/jobs", json=doc)
        assert response.status_code == 201, response.text
        return int(response.json()["job_id"])

    return _submit


@pytest.fixture
def register(client: TestClient) -> Callable[[str], int]:
    """Register (or adopt) a world by name and return its id."""

    def _register(name: str) -> int:
        response = client.post("/v1/worlds", json={"name": name})
        assert response.status_code == 201, response.text
        return int(response.json()["world_id"])

    return _register
