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

SERVICE_URL = os.environ.get("LUANTIBOT_SERVICE_URL", "http://127.0.0.1:8099")

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


SECONDS_PER_CHUNK = 0.5
"""Rough fit to measured slab jobs; see `geometry.mapgen_chunks` for the spread.

Estimates in tool descriptions get believed and planned against, so this one is
measured rather than guessed -- and measured *per mapgen chunk*, because a
per-mapblock constant cannot fit both shapes at once. An earlier per-mapblock
value here was fifteen times too pessimistic for cubes; refitting it to cubes
then ran five times too optimistic for slabs. Chunks are the unit generation
actually works in.

It still only sets the order of magnitude: identical slab jobs varied by 50%,
and compact boxes finish in about half what this predicts."""


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
    radius 32 is 125 mapblocks (~1s), 64 is 729 (~3s), 112 is 3375 (~15s).
    Above ~112 the job is refused.

    A cube is usually the wrong shape: surface terrain is a thin horizontal
    sheet, so a radius wide enough to be useful buys far more height than you
    need. Prefer `emerge_slab`, which sizes X/Z and Y independently.

    Returns a job id immediately; the work happens asynchronously. Check it with
    job_status.
    """
    try:
        lo, hi = geometry.cube((x, y, z), radius)
    except ValueError as exc:
        return {"error": str(exc)}

    return _submit_emerge(
        world,
        lo,
        hi,
        oversize_hint="Try a radius of 112 or less, or use emerge_slab to keep Y thin.",
    )


@mcp.tool()
def emerge_slab(world: str, x: int, z: int, side: int, y_min: int, y_max: int) -> dict[str, Any]:
    """Load or generate a wide, thin horizontal slab of map.

    Like `emerge_area`, this only makes terrain exist -- it places nothing and
    leaves existing nodes untouched. The difference is shape: `side` sizes the
    square in X/Z (centred on `x`,`z`) while `y_min`..`y_max` sets the height
    independently, so covering ground does not drag a tall column along with it.

    The 4096-mapblock ceiling means a slab one mapblock tall (e.g. y_min=0,
    y_max=15) can be 1024 nodes square; a slab 64 nodes tall can be 256 square.

    Time is set by mapgen chunks (80 nodes cubed) at roughly 0.55s each, NOT by
    mapblocks. Height below 80 nodes is therefore close to free but never
    cheaper than one chunk: y_min=0,y_max=15 costs the same as y_min=0,y_max=79.
    Widening X/Z is what costs -- doubling `side` quadruples the time.

    Returns a job id immediately; check it with job_status.
    """
    try:
        lo, hi = geometry.slab((x, z), side, y_min, y_max)
    except ValueError as exc:
        return {"error": str(exc)}

    return _submit_emerge(
        world,
        lo,
        hi,
        oversize_hint=("Reduce `side`, narrow y_min..y_max, or emerge several slabs side by side."),
    )


def _submit_emerge(
    world: str,
    lo: geometry.Vec3,
    hi: geometry.Vec3,
    oversize_hint: str,
) -> dict[str, Any]:
    """Queue a job that only generates terrain."""
    return _submit(world, lo, hi, [{"op": "emerge"}], [], oversize_hint)


def _submit(
    world: str,
    lo: geometry.Vec3,
    hi: geometry.Vec3,
    ops: list[dict[str, Any]],
    palette: list[str],
    oversize_hint: str,
) -> dict[str, Any]:
    """Cap-check a mapblock-aligned box and queue it as a job."""
    blocks = geometry.mapblock_count(lo, hi)
    chunks = geometry.mapgen_chunks(lo, hi)
    if blocks > geometry.MAX_MAPBLOCKS:
        return {
            "error": (
                f"that area spans {blocks} mapblocks, over the limit of {geometry.MAX_MAPBLOCKS}"
            ),
            "hint": oversize_hint,
        }

    job = {
        "format": FORMAT,
        "world": world,
        "palette": palette,
        "bounds": {"min": list(lo), "max": list(hi)},
        "ops": ops,
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
            f"expect roughly {max(1, round(chunks * SECONDS_PER_CHUNK))}s of generation."
        ),
    }


@mcp.tool()
def fill_box(
    world: str,
    x1: int,
    y1: int,
    z1: int,
    x2: int,
    y2: int,
    z2: int,
    node: str,
    param2: int = 0,
) -> dict[str, Any]:
    """Set every node in a box to one node type. THIS CHANGES THE WORLD.

    Unlike the emerge tools, this destroys whatever was there. The corners are
    inclusive, given in any order, and name actual nodes -- the box is exactly
    what you specify, not rounded outward. The surrounding mapblocks are
    generated first if they do not exist yet.

    `node` is a registered node name for the game in that world, such as
    "mcl_core:stone" or "air" under Mineclonia. An unregistered name fails the
    job without writing anything. Filling with "air" is how you carve.

    `param2` is the node's second byte: facing for a trapdoor or stair, which
    half a slab occupies, the shade of a dyed block. It defaults to 0, and a
    fill always sets it -- a replaced node never keeps the orientation of the
    one it displaced. Nodes that ignore param2, such as stone, ignore it here.

    Nodes are written raw: no lighting update, no liquid flow, and node
    callbacks do not run, so filling a box with a liquid gives you a static
    block of it rather than something that spreads.

    Returns a job id immediately; check it with job_status.
    """
    lo, hi = geometry.align((x1, y1, z1), (x2, y2, z2))
    box_lo = (min(x1, x2), min(y1, y2), min(z1, z2))
    box_hi = (max(x1, x2), max(y1, y2), max(z1, z2))

    return _submit(
        world,
        lo,
        hi,
        [
            {"op": "emerge"},
            {
                "op": "fill_box",
                "min": list(box_lo),
                "max": list(box_hi),
                "node": 0,
                "param2": param2,
            },
        ],
        [node],
        oversize_hint="Fill a smaller box, or split it into several jobs.",
    )


@mcp.tool()
def fill_box_if(
    world: str,
    x1: int,
    y1: int,
    z1: int,
    x2: int,
    y2: int,
    z2: int,
    node: str,
    match: list[str],
    invert: bool = False,
    param2: int = 0,
) -> dict[str, Any]:
    """Set only the nodes in a box that match a predicate. THIS CHANGES THE WORLD.

    The conditional form of `fill_box`, and the one to reach for whenever the
    terrain's shape matters but its height is unknown.

    `match` lists node names, or groups written as "group:liquid" and
    "group:falling_node". A group covers every node the game registers into it,
    which is the only practical way to say "wherever there is water".

    `invert` writes where the predicate does NOT hold. The two directions cover
    most terrain work:

      match=["air", "group:liquid"]              a pillar dropped from above
                                                 fills the gap and stops at
                                                 rock, without anyone measuring
                                                 the ground

      match=["air"], invert=True                 carve a shaft up through
                                                 whatever is solid

    It cannot finish a run with something else -- a footing at the bottom, a
    grating at the top. That needs to know where the run ended, which this op
    does not track. Read the terrain and send explicit boxes for the ends.

    Returns a job id immediately; check it with job_status. The reported node
    count is how many cells actually changed, so 0 means the predicate never
    matched.
    """
    lo, hi = geometry.align((x1, y1, z1), (x2, y2, z2))
    box_lo = (min(x1, x2), min(y1, y2), min(z1, z2))
    box_hi = (max(x1, x2), max(y1, y2), max(z1, z2))

    return _submit(
        world,
        lo,
        hi,
        [
            {"op": "emerge"},
            {
                "op": "fill_box_if",
                "min": list(box_lo),
                "max": list(box_hi),
                "node": 0,
                "param2": param2,
                "match": match,
                "invert": invert,
            },
        ],
        [node],
        oversize_hint="Fill a smaller box, or split it into several jobs.",
    )


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
