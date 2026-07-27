"""MCP tools, so an AI agent can drive the builder.

    uv run python -m luantibot.mcp_server

Speaks MCP over stdio and talks to the builder service over HTTP. It is a
*client* of the service, never a second writer of the database: one process owns
the SQLite file, and everything else goes through the API.

Tool descriptions matter more than usual here. They are the only thing the model
reads before deciding what to call, so each one states what the tool does to the
world and what it costs.
"""

from __future__ import annotations

import os
from typing import Any

import httpx2 as httpx
from mcp.server.fastmcp import FastMCP

from luantibot import geometry
from luantibot.ops import FORMAT

SERVICE_URL = os.environ.get("LUANTIBOT_SERVICE_URL", "http://127.0.0.1:8080")

mcp = FastMCP(
    "luantibot",
    instructions=(
        "Build in a running Luanti world. Work is submitted as jobs to a local "
        "builder service; a mod inside Luanti polls for them and executes them.\n\n"
        "Jobs are asynchronous: submitting returns a job id, and the work "
        "happens over the following seconds or minutes. Use job_status to see "
        "how it went.\n\n"
        "Every job names a world. Call list_worlds first if you do not know "
        "which worlds exist -- a job for a world the mod is not running in will "
        "simply never be executed."
    ),
)


def _client() -> httpx.Client:
    return httpx.Client(base_url=SERVICE_URL, timeout=10.0)


def _service_error(exc: Exception) -> dict[str, Any]:
    return {
        "error": "the builder service is not reachable",
        "detail": str(exc),
        "hint": (
            f"Expected it at {SERVICE_URL}. Start it with "
            "`uv run python -m luantibot.service`, or set LUANTIBOT_SERVICE_URL."
        ),
    }


@mcp.tool()
def list_worlds() -> dict[str, Any]:
    """List the Luanti worlds the builder service knows about.

    A world appears here once its mod has registered, or once a job has been
    submitted naming it. Use the exact `name` when submitting jobs.
    """
    try:
        with _client() as client:
            response = client.get("/v1/worlds")
            response.raise_for_status()
            return {"worlds": response.json()}
    except Exception as exc:
        return _service_error(exc)


@mcp.tool()
def emerge_area(world: str, x: int, y: int, z: int, radius: int) -> dict[str, Any]:
    """Load or generate the map around a point, so it exists and can be built on.

    This does NOT place or change any nodes. It makes terrain exist: mapblocks
    that have never been visited are generated and written to the world
    permanently, and will appear on any map viewer. Existing terrain is left
    untouched.

    `radius` is in nodes and describes a cube, so cost grows cubically -- a
    radius of 64 is roughly six times the work of 32, not twice. Rough guide:
    radius 32 is 125 mapblocks (~8s), 64 is 729 (~45s), 112 is 3375 (~4min).
    Above ~112 the job is refused. Prefer small radii unless asked otherwise.

    Returns a job id immediately; the work happens asynchronously. Check it with
    job_status.
    """
    try:
        lo, hi = geometry.cube((x, y, z), radius)
    except ValueError as exc:
        return {"error": str(exc)}

    blocks = geometry.mapblock_count(lo, hi)
    if blocks > geometry.MAX_MAPBLOCKS:
        return {
            "error": (
                f"radius {radius} spans {blocks} mapblocks, over the limit of "
                f"{geometry.MAX_MAPBLOCKS}"
            ),
            "hint": "Try a radius of 112 or less, or emerge several smaller areas.",
        }

    job = {
        "format": FORMAT,
        "world": world,
        "bounds": {"min": list(lo), "max": list(hi)},
        "ops": [{"op": "emerge"}],
    }

    try:
        with _client() as client:
            response = client.post("/v1/jobs", json=job)
            if response.status_code == 422:
                return {"error": "the service rejected the job", "detail": response.json()}
            response.raise_for_status()
            body = response.json()
    except Exception as exc:
        return _service_error(exc)

    return {
        "job_id": body["job_id"],
        "world": world,
        "world_id": body["world_id"],
        "mapblocks": blocks,
        "bounds": {"min": list(lo), "max": list(hi)},
        "note": (
            "Queued. The mod picks this up within a couple of seconds; "
            f"expect roughly {max(1, round(blocks * 0.064))}s of generation."
        ),
    }


@mcp.tool()
def job_status(job_id: int) -> dict[str, Any]:
    """Check how a submitted job is going.

    States: `queued` (waiting to be picked up), `running`, `completed`,
    `failed`, `interrupted` (the server died mid-job). A job that stays
    `queued` usually means no Luanti server is polling for that world.
    """
    try:
        with _client() as client:
            response = client.get(f"/v1/jobs/{job_id}")
            if response.status_code == 404:
                return {"error": f"no job {job_id}"}
            response.raise_for_status()
            row = response.json()
    except Exception as exc:
        return _service_error(exc)

    return {
        "job_id": row["job_id"],
        "world": row["world"],
        "state": row["state"],
        "created_at": row["created_at"],
        "started_at": row["started_at"],
        "finished_at": row["finished_at"],
        "result": row["result"],
        "error_code": row["error_code"],
        "error_message": row["error_message"],
    }


@mcp.tool()
def build_history(world: str, limit: int = 20) -> dict[str, Any]:
    """What has been built in a world, most recent first.

    Coordinates repeat across worlds, so history is always world-scoped. Useful
    for answering "what did I do around here" before building something new.
    """
    try:
        with _client() as client:
            worlds = client.get("/v1/worlds")
            worlds.raise_for_status()
            match = next((w for w in worlds.json() if w["name"] == world), None)
            if match is None:
                return {
                    "error": f"no world named {world!r}",
                    "known_worlds": [w["name"] for w in worlds.json()],
                }

            response = client.get(f"/v1/worlds/{match['world_id']}/jobs", params={"limit": limit})
            response.raise_for_status()
            rows = response.json()
    except Exception as exc:
        return _service_error(exc)

    return {
        "world": world,
        "jobs": [
            {
                "job_id": r["job_id"],
                "state": r["state"],
                "created_at": r["created_at"],
                "bounds": r["request"]["bounds"],
                "ops": [op["op"] for op in r["request"]["ops"]],
                "result": r["result"],
                "error_message": r["error_message"],
            }
            for r in rows
        ],
    }


def main() -> None:
    mcp.run(transport="stdio")


if __name__ == "__main__":
    main()
