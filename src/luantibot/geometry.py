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
before it is ever queued."""

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


def mapblock_count(lo: Vec3, hi: Vec3) -> int:
    """Mapblocks a box touches, whole or partial.

    This is the quantity the caps are applied to — the work the engine actually
    does, which is why it counts partially covered blocks.
    """
    spans = [blockpos(max(a, b)) - blockpos(min(a, b)) + 1 for a, b in zip(lo, hi, strict=True)]
    return spans[0] * spans[1] * spans[2]
