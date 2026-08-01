"""Mapblock geometry.

This mirrors `mods/luantibot/src/plan.lua`. Both sides need it: the mod to size
work and enforce its cap, the service to reject an oversized job at submission
rather than letting it fail two seconds later in-world.

The duplication is deliberate and small. `tests/unit/test_geometry.py` pins it
to values measured from the Lua implementation, so the two cannot drift silently.
"""

from __future__ import annotations

MAPBLOCK = 16
"""Nodes along one edge of a mapblock."""

MAX_MAPBLOCKS = 4096
"""Submission-time ceiling, matching the mod's default
`luantibot_max_emerge_blocks`. The mod remains the final authority and has its
own configurable cap; this exists so an obviously oversized job is refused
before it is ever queued.

The number was originally what one VoxelManip could hold. Work units (M4) ended
that: memory is now bounded by the unit, not the job, and the cap could be
raised by orders of magnitude without any technical difficulty.

It stays at 4096 for a different reason. **There is no cancellation**, so the
cap is the only bound on a job you regret -- roughly 90 seconds of generation on
fresh terrain. The sweeps argue the same way from experience: 900 small jobs
survived two crashes at the cost of redoing one tile each, where a single job of
the same extent would have lost forty hours, since retry does not arrive until
snapshots in M6. Raise this when `cancel` exists, or when M6 makes a big job
cheap to undo."""

MAPGEN_CHUNK = 80
"""Nodes along one edge of a mapgen chunk (5 mapblocks, Luanti's default).

Generation happens a whole chunk at a time, which is why a thin slab is not
cheap: asking for 16 nodes of height still generates all 80. Cost tracks chunks
touched, not mapblocks -- see `mapgen_chunks`."""

Vec3 = tuple[int, int, int]


def blockpos(value: int) -> int:
    """Mapblock containing a node coordinate.

    Floors toward negative infinity, matching Luanti: node -1 is in block -1.
    Python's `//` already floors, which is why this reads as trivial — the same
    line in Lua needs an explicit `math.floor`.
    """
    return value // MAPBLOCK


def align(lo: Vec3, hi: Vec3) -> tuple[Vec3, Vec3]:
    """Expand a box out to whole mapblock boundaries.

    Corners may be given in any order; the result is normalised so the first
    return value is the minimum corner.
    """
    low = [blockpos(min(a, b)) * MAPBLOCK for a, b in zip(lo, hi, strict=True)]
    high = [blockpos(max(a, b)) * MAPBLOCK + MAPBLOCK - 1 for a, b in zip(lo, hi, strict=True)]
    return (low[0], low[1], low[2]), (high[0], high[1], high[2])


def cube(center: Vec3, radius: int) -> tuple[Vec3, Vec3]:
    """Mapblock-aligned box covering the cube of `radius` nodes around a point."""
    if radius < 0:
        raise ValueError("radius must not be negative")
    x, y, z = center
    return align(
        (x - radius, y - radius, z - radius),
        (x + radius, y + radius, z + radius),
    )


def mapgen_chunks(lo: Vec3, hi: Vec3) -> int:
    """Mapgen chunks a box touches -- the quantity that actually predicts time.

    `mapblock_count` is the right unit for the *cap* (it is what the mod's
    VoxelManip handles), but it badly mispredicts *duration* for flat boxes: a
    1024x1024x16 slab and a 1024x1024x80 one are 4096 and 20480 mapblocks, yet
    cost the same, because both generate one chunk of height.

    Counts partially covered chunks, since generation cannot do less than one.

    This predicts far better than mapblocks across shapes, but it is not
    precise: two runs of an identical 1024x1024x16 slab took 74.5s and 109.3s,
    so roughly 0.5s/chunk with 50% spread is as tight as the measurements
    support. Compact boxes come in cheaper per touched chunk (~0.23s) because
    more of their chunks are only clipped at the edges. Treat any estimate built
    on this as an order of magnitude, not a schedule.
    """
    spans = [
        (max(a, b) // MAPGEN_CHUNK) - (min(a, b) // MAPGEN_CHUNK) + 1
        for a, b in zip(lo, hi, strict=True)
    ]
    return spans[0] * spans[1] * spans[2]


def slab(center_xz: tuple[int, int], side: int, y_min: int, y_max: int) -> tuple[Vec3, Vec3]:
    """Mapblock-aligned box `side` nodes square in X/Z, spanning `y_min`..`y_max`.

    The cube is the wrong shape for surface work. Terrain anyone actually wants
    is a thin horizontal sheet, and `cube` ties the Y extent to the horizontal
    one -- so asking for a wide area silently buys a tall one, multiplying the
    cost by a factor nobody asked for. Here the two are independent.
    """
    if side <= 0:
        raise ValueError("side must be positive")
    if y_max < y_min:
        y_min, y_max = y_max, y_min
    x, z = center_xz
    lo_x = x - side // 2
    lo_z = z - side // 2
    return align((lo_x, y_min, lo_z), (lo_x + side - 1, y_max, lo_z + side - 1))


def mapblock_count(lo: Vec3, hi: Vec3) -> int:
    """Mapblocks a box touches, whole or partial.

    This is the quantity the caps are applied to — the work the engine actually
    does, which is why it counts partially covered blocks.
    """
    spans = [blockpos(max(a, b)) - blockpos(min(a, b)) + 1 for a, b in zip(lo, hi, strict=True)]
    return spans[0] * spans[1] * spans[2]
