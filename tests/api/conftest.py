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
from luantibot.service.store import SqliteStore

WORLD_NAME = "TestWorld"


@pytest.fixture
def store(tmp_path: Path) -> Iterator[SqliteStore]:
    s = SqliteStore(tmp_path / "luantibot.sqlite")
    yield s
    s.close()


@pytest.fixture
def client(store: SqliteStore) -> Iterator[TestClient]:
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
