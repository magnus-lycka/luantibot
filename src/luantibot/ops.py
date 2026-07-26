"""The wire contract between the service and the Luanti mod.

Versioned from the first commit, because the mod and the service restart
independently. See "Wire contract" in docs/implementation_plan.md.
"""

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

FORMAT = 1
"""Current wire format. The mod refuses documents it does not recognise."""

Vec3 = tuple[int, int, int]
"""A node position as [x, y, z]. Integers only: floats and non-finite values are
rejected at parse time rather than reaching emerge_area as a bound."""


class Strict(BaseModel):
    """Reject unknown fields everywhere. A typo'd key in a job document should
    fail loudly here, not be silently dropped and then not happen in-world."""

    model_config = ConfigDict(extra="forbid")


class Bounds(Strict):
    min: Vec3
    max: Vec3

    @model_validator(mode="after")
    def min_before_max(self) -> Bounds:
        if any(lo > hi for lo, hi in zip(self.min, self.max, strict=True)):
            raise ValueError("bounds.min must not exceed bounds.max on any axis")
        return self


class EmergeOp(Strict):
    """Load or generate the mapblocks covering the job's bounds. Writes nothing.

    Ops carry no bounds of their own at M1; `emerge` applies to the whole job.
    Box-carrying ops arrive in M2.
    """

    op: Literal["emerge"]


Op = Annotated[EmergeOp, Field(discriminator="op")]


class JobRequest(Strict):
    """What a client submits."""

    format: Literal[1] = FORMAT
    world: str = Field(min_length=1)
    palette: list[str] = Field(default_factory=list)
    bounds: Bounds
    ops: list[Op] = Field(min_length=1)


class JobDocument(JobRequest):
    """What the mod fetches: the request plus its assigned identity.

    `world_id` is what the mod matches against its own stored id before touching
    anything; `world` (inherited from JobRequest) is the human-readable label,
    for logs. Names for humans, ids for machines -- see "World identity" in
    docs/implementation_plan.md.
    """

    job_id: int
    world_id: int
