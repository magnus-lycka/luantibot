"""The wire contract between the service and the Luanti mod.

Versioned from the first commit, because the mod and the service restart
independently. See "Wire contract" in docs/implementation_plan.md.
"""

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from luantibot import geometry

FORMAT = 1
"""Current wire format. The mod refuses documents it does not recognise."""

Vec3 = tuple[int, int, int]
"""A node position as [x, y, z]. Integers only: floats and non-finite values are
rejected at parse time rather than reaching emerge_area as a bound."""

WORLD_LIMIT = 31000
"""Luanti refuses to generate beyond this; coordinates outside it are malformed
rather than merely ambitious. Mirrors `validate.WORLD_LIMIT` in the mod."""


class Strict(BaseModel):
    """Reject unknown fields everywhere. A typo'd key in a job document should
    fail loudly here, not be silently dropped and then not happen in-world."""

    model_config = ConfigDict(extra="forbid")


class Bounds(Strict):
    min: Vec3
    max: Vec3

    @model_validator(mode="after")
    def well_formed(self) -> Bounds:
        if any(lo > hi for lo, hi in zip(self.min, self.max, strict=True)):
            raise ValueError("bounds.min must not exceed bounds.max on any axis")

        if any(abs(v) > WORLD_LIMIT for v in (*self.min, *self.max)):
            raise ValueError(f"bounds exceed the world limit of {WORLD_LIMIT}")

        # Refuse an oversized job at submission rather than letting it be
        # queued, fetched, and only then rejected in-world. The mod stays the
        # final authority and applies its own configurable cap.
        blocks = geometry.mapblock_count(self.min, self.max)
        if blocks > geometry.MAX_MAPBLOCKS:
            raise ValueError(
                f"bounds span {blocks} mapblocks, over the limit of {geometry.MAX_MAPBLOCKS}"
            )
        return self

    @property
    def mapblocks(self) -> int:
        return geometry.mapblock_count(self.min, self.max)


class EmergeOp(Strict):
    """Load or generate the mapblocks covering the job's bounds. Writes nothing.

    Carries no box of its own: `emerge` always applies to the whole job.
    """

    op: Literal["emerge"]


class FillBoxOp(Strict):
    """Set every node in a box to one palette entry.

    `node` is a 0-based index into the job's `palette`, not a node name. Names
    are resolved to content ids once, in the mod, so that a typo fails the job
    before anything is written rather than once per op.
    """

    op: Literal["fill_box"]
    min: Vec3
    max: Vec3
    node: int = Field(ge=0)
    param2: int = Field(default=0, ge=0, le=255)
    """Orientation, slab half, dye colour -- whatever the node uses it for.

    One byte in the engine. Defaulted rather than optional because a fill
    replaces the node completely: leaving it unset would let the new node
    inherit the facing of whatever it overwrote.
    """

    @model_validator(mode="after")
    def well_formed(self) -> FillBoxOp:
        if any(lo > hi for lo, hi in zip(self.min, self.max, strict=True)):
            raise ValueError("op min must not exceed max on any axis")
        return self


class FillBoxIfOp(Strict):
    """Set the nodes in a box that match a predicate, leaving the rest.

    `match` names nodes, or groups as `group:liquid`. Groups are the only
    practical way to say "wherever there is water" without enumerating every
    mod's liquids; they are resolved in the mod, once per job.

    `invert` writes where the predicate does *not* hold. The two directions are
    the same op: `[air, group:liquid]` fills the empty space under a bridge, and
    inverted it carves a shaft up through whatever is solid.
    """

    op: Literal["fill_box_if"]
    min: Vec3
    max: Vec3
    node: int = Field(ge=0)
    param2: int = Field(default=0, ge=0, le=255)
    match: list[str] = Field(min_length=1)
    invert: bool = False

    @model_validator(mode="after")
    def well_formed(self) -> FillBoxIfOp:
        if any(lo > hi for lo, hi in zip(self.min, self.max, strict=True)):
            raise ValueError("op min must not exceed max on any axis")
        # Whether a name is registered is the mod's call -- it owns the node
        # registry. Empty strings are malformed anywhere.
        if any(not name.strip() for name in self.match):
            raise ValueError("match entries must not be blank")
        return self


class SurveyOp(Strict):
    """Read a region and report, per column, the first surface you could stand on.

    Read-only: no palette entry, no `param2`, and the mod never writes the
    VoxelManip back. What comes back is in the job's completion result, under
    `columns`.

    `step` samples every Nth column on both axes -- a 4x1000 road strip is four
    thousand columns at step 1, and the answer is usually wanted as a profile
    rather than a census. Sampling is anchored to absolute coordinates, so the
    grid does not shift with the box.

    A column reports the highest **walkable** node, not the highest node. Snow,
    plants, and a trapdoor in a ceiling all occupy a cell without being
    something you could build on, and treating them as the surface would hang a
    bridge in the air.
    """

    op: Literal["survey"]
    min: Vec3
    max: Vec3
    step: int = Field(default=1, ge=1)

    @model_validator(mode="after")
    def well_formed(self) -> SurveyOp:
        if any(lo > hi for lo, hi in zip(self.min, self.max, strict=True)):
            raise ValueError("op min must not exceed max on any axis")
        return self


Op = Annotated[EmergeOp | FillBoxOp | FillBoxIfOp | SurveyOp, Field(discriminator="op")]


class JobRequest(Strict):
    """What a client submits."""

    format: Literal[1] = FORMAT
    world: str = Field(min_length=1)
    palette: list[str] = Field(default_factory=list)
    bounds: Bounds
    ops: list[Op] = Field(min_length=1)

    @model_validator(mode="after")
    def ops_fit_the_job(self) -> JobRequest:
        """Rules 3 and 5, as far as the service can check them.

        It cannot tell whether a palette entry names a registered node -- only
        the mod can -- but it can catch an index with no entry behind it and a
        box reaching outside what will be emerged. Both are pure arithmetic, and
        catching them here turns a job that fails two seconds later in-world
        into a 422 at submission.
        """
        for i, op in enumerate(self.ops):
            # Only a fill draws from the palette; containment applies to every
            # op that carries a box, or a survey could ask about a region that
            # was never emerged and be silently clipped to one that was.
            if isinstance(op, FillBoxOp | FillBoxIfOp) and op.node >= len(self.palette):
                raise ValueError(
                    f"op {i}: node index {op.node} is outside a palette of {len(self.palette)}"
                )

            if isinstance(op, EmergeOp):
                continue

            outside = [
                axis
                for axis, lo, hi, blo, bhi in zip(
                    "xyz", op.min, op.max, self.bounds.min, self.bounds.max, strict=True
                )
                if lo < blo or hi > bhi
            ]
            if outside:
                raise ValueError(
                    f"op {i}: box reaches outside the job bounds on {', '.join(outside)}"
                )
        return self


class JobDocument(JobRequest):
    """What the mod fetches: the request plus its assigned identity.

    `world_id` is what the mod matches against its own stored id before touching
    anything; `world` (inherited from JobRequest) is the human-readable label,
    for logs. Names for humans, ids for machines -- see "World identity" in
    docs/implementation_plan.md.
    """

    job_id: int
    world_id: int
