"""The three refusals `Bounds` makes at submission.

Each exists so a bad job fails as a 422 to the caller rather than two seconds
later inside Luanti, where the only trace is a line in `debug.txt`. They are
worth testing directly rather than through the API, because the API tests use
valid bounds and would only reach these by accident.
"""

import pytest
from pydantic import ValidationError

from luantibot import geometry
from luantibot.ops import WORLD_LIMIT, Bounds


def test_accepts_a_well_formed_box() -> None:
    b = Bounds(min=(0, 0, 0), max=(15, 15, 15))
    assert b.mapblocks == 1


def test_refuses_an_inverted_box() -> None:
    with pytest.raises(ValidationError, match="must not exceed"):
        Bounds(min=(10, 0, 0), max=(0, 0, 0))


@pytest.mark.parametrize("axis", [0, 1, 2])
def test_refuses_an_inversion_on_any_single_axis(axis: int) -> None:
    lo = [0, 0, 0]
    hi = [10, 10, 10]
    lo[axis] = 20
    with pytest.raises(ValidationError, match="must not exceed"):
        Bounds(min=(lo[0], lo[1], lo[2]), max=(hi[0], hi[1], hi[2]))


def test_refuses_coordinates_past_the_world_limit() -> None:
    """Luanti will not generate out there, so the job is malformed rather than
    merely ambitious."""
    with pytest.raises(ValidationError, match="world limit"):
        Bounds(min=(0, 0, 0), max=(WORLD_LIMIT + 1, 0, 0))


def test_refuses_a_negative_coordinate_past_the_limit() -> None:
    with pytest.raises(ValidationError, match="world limit"):
        Bounds(min=(-WORLD_LIMIT - 1, 0, 0), max=(0, 0, 0))


def test_accepts_the_limit_itself() -> None:
    Bounds(min=(0, 0, 0), max=(WORLD_LIMIT, 0, 0))


def test_refuses_a_box_over_the_mapblock_cap() -> None:
    """The cap bounds ambition, not memory -- work units keep a VoxelManip small
    however large the job is. See geometry.MAX_MAPBLOCKS."""
    side = 16 * 17  # 17 mapblocks cubed is 4913, over 4096
    with pytest.raises(ValidationError, match="over the limit of"):
        Bounds(min=(0, 0, 0), max=(side - 1, side - 1, side - 1))


def test_accepts_a_box_exactly_at_the_cap() -> None:
    lo, hi = geometry.slab((0, 0), 1024, 0, 15)
    assert Bounds(min=lo, max=hi).mapblocks == geometry.MAX_MAPBLOCKS
