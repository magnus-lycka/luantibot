"""Mapblock geometry, pinned to the Lua implementation.

`geometry.py` and `plan.lua` compute the same thing in two languages. The table
below was measured by running the *Lua* implementation, so if either side drifts
these fail.
"""

import pytest

from luantibot import geometry


class TestBlockpos:
    def test_maps_a_coordinate_to_its_mapblock(self) -> None:
        assert geometry.blockpos(0) == 0
        assert geometry.blockpos(15) == 0
        assert geometry.blockpos(16) == 1

    def test_floors_toward_negative_infinity(self) -> None:
        # Truncation toward zero would put -1 in block 0, silently misaligning
        # everything below the origin. Luanti floors.
        assert geometry.blockpos(-1) == -1
        assert geometry.blockpos(-16) == -1
        assert geometry.blockpos(-17) == -2


class TestAlign:
    def test_expands_to_whole_mapblocks(self) -> None:
        assert geometry.align((1, 1, 1), (2, 2, 2)) == ((0, 0, 0), (15, 15, 15))

    def test_leaves_an_aligned_box_alone(self) -> None:
        assert geometry.align((0, 0, 0), (15, 15, 15)) == ((0, 0, 0), (15, 15, 15))

    def test_aligns_across_the_origin(self) -> None:
        assert geometry.align((-1, -1, -1), (0, 0, 0)) == ((-16, -16, -16), (15, 15, 15))

    def test_normalises_corners_given_in_any_order(self) -> None:
        assert geometry.align((20, 0, 0), (0, 20, 0)) == ((0, 0, 0), (31, 31, 15))


class TestMapblockCount:
    def test_counts_whole_blocks(self) -> None:
        assert geometry.mapblock_count((0, 0, 0), (15, 15, 15)) == 1
        assert geometry.mapblock_count((0, 0, 0), (31, 31, 31)) == 8

    def test_counts_partially_covered_blocks(self) -> None:
        assert geometry.mapblock_count((0, 0, 0), (16, 0, 0)) == 2


class TestCube:
    def test_radius_zero_is_the_containing_block(self) -> None:
        assert geometry.cube((8, 8, 8), 0) == ((0, 0, 0), (15, 15, 15))

    def test_rejects_a_negative_radius(self) -> None:
        with pytest.raises(ValueError, match="radius"):
            geometry.cube((0, 0, 0), -1)

    # Measured from plan.lua. Cost grows cubically and faster than it looks:
    # doubling the radius is roughly six times the work, not two.
    @pytest.mark.parametrize(
        ("radius", "blocks"),
        [(8, 8), (16, 27), (32, 125), (48, 343), (64, 729), (96, 2197), (112, 3375), (128, 4913)],
    )
    def test_matches_the_lua_implementation(self, radius: int, blocks: int) -> None:
        lo, hi = geometry.cube((0, 0, 0), radius)
        assert geometry.mapblock_count(lo, hi) == blocks

    def test_the_default_ceiling_sits_between_radius_112_and_128(self) -> None:
        # Documented in INSTALL.md as "~112 is the largest usable radius".
        under = geometry.mapblock_count(*geometry.cube((0, 0, 0), 112))
        over = geometry.mapblock_count(*geometry.cube((0, 0, 0), 128))
        assert under <= geometry.MAX_MAPBLOCKS < over
