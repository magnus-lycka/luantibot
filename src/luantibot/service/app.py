"""HTTP surface.

Luanti cannot run an incoming HTTP server, so the mod is the *client*: it polls
this service for work and posts results back. Everything here is designed around
that inversion.

Binds to 127.0.0.1 only. The mod runs on the same machine, and nothing about
this API is safe to expose.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import Body, FastAPI, HTTPException, Response
from pydantic import BaseModel, Field

from luantibot.ops import JobDocument, JobRequest, RestoreOp
from luantibot.service.store import Job, NotFound, State, Store, World, WrongState

CompletionResult = Annotated[dict[str, Any], Body(default_factory=dict)]
"""Free-form completion payload -- changed_nodes, affected bounds, timings. The
service records it without interpreting it, so the mod can add fields as later
milestones learn to report more."""


class SubmitResponse(BaseModel):
    job_id: int
    world_id: int


class RegisterWorld(BaseModel):
    name: str = Field(min_length=1)


class WorldView(BaseModel):
    world_id: int
    name: str
    created_at: str


class FailureReport(BaseModel):
    code: str = Field(min_length=1)
    message: str = ""


class ProgressReport(BaseModel):
    units_done: int = Field(ge=0)
    units_total: int = Field(ge=1)


def _world_view(world: World) -> WorldView:
    return WorldView(
        world_id=world.world_id,
        name=world.name,
        created_at=world.created_at.isoformat(),
    )


def _row(job: Job, world: World) -> dict[str, Any]:
    """The inspection view of a job. Deliberately not the storage schema."""

    def when(value: Any) -> str | None:
        return value.isoformat() if value else None

    return {
        "job_id": job.job_id,
        "world_id": job.world_id,
        "world": world.name,
        "state": str(job.state),
        "created_at": when(job.created_at),
        "reserved_at": when(job.reserved_at),
        "started_at": when(job.started_at),
        "finished_at": when(job.finished_at),
        # Exposed because "is this job alive or wedged" is the question you ask
        # of a long-running row, and the answer is the age of this timestamp.
        "heartbeat_at": when(job.heartbeat_at),
        "units_done": job.units_done,
        "units_total": job.units_total,
        "result": job.result,
        "error_code": job.error_code,
        "error_message": job.error_message,
        "request": job.request.model_dump(),
    }


def create_app(store: Store) -> FastAPI:
    app = FastAPI(title="luantibot builder service", version="0.1.0")

    # Step 3 of the recovery protocol. A `running` row with a cold heartbeat
    # means the mod died without reporting; it becomes `interrupted` rather
    # than blocking the queue forever.
    store.sweep_stale()

    def lookup(job_id: int) -> Job:
        try:
            return store.get(job_id)
        except NotFound:
            raise HTTPException(status_code=404, detail=f"no job {job_id}") from None

    def lookup_world(world_id: int) -> World:
        try:
            return store.get_world(world_id)
        except NotFound:
            raise HTTPException(status_code=404, detail=f"no world {world_id}") from None

    def transition(fn: Any, job_id: int, *args: Any) -> Response:
        lookup(job_id)
        try:
            fn(job_id, *args)
        except WrongState as exc:
            # The mod is reporting on a job it does not hold -- a stale report
            # after a restart, or a double report. Neither should mutate state.
            raise HTTPException(status_code=409, detail=str(exc)) from None
        return Response(status_code=204)

    @app.post("/v1/worlds", status_code=201)
    def register(body: RegisterWorld) -> WorldView:
        # Adopts by name: a mod installed into a world the service already knows
        # attaches to that row rather than forking a duplicate.
        return _world_view(store.register_world(body.name))

    @app.get("/v1/worlds")
    def worlds() -> list[WorldView]:
        return [_world_view(w) for w in store.list_worlds()]

    @app.get("/v1/worlds/{world_id}")
    def world(world_id: int) -> WorldView:
        return _world_view(lookup_world(world_id))

    @app.post("/v1/jobs", status_code=201)
    def submit(request: JobRequest) -> SubmitResponse:
        # Submission names a world; the mod is handed an id. Creating the world
        # on demand keeps job submission from needing a separate setup step.
        world = store.register_world(request.world)
        job = store.create(world.world_id, request)
        return SubmitResponse(job_id=job.job_id, world_id=world.world_id)

    @app.get("/v1/jobs/{job_id}")
    def inspect(job_id: int) -> dict[str, Any]:
        job = lookup(job_id)
        return _row(job, store.get_world(job.world_id))

    @app.get("/v1/worlds/{world_id}/jobs")
    def world_jobs(world_id: int, limit: int = 50) -> list[dict[str, Any]]:
        world = lookup_world(world_id)
        return [_row(j, world) for j in store.list_jobs(world_id, limit=min(limit, 200))]

    @app.get(
        "/v1/worlds/{world_id}/jobs/next",
        response_model=JobDocument,
        responses={204: {"description": "no work available"}},
    )
    def next_job(world_id: int) -> Any:
        lookup_world(world_id)
        job = store.reserve(world_id)
        if job is None:
            # 204 rather than an empty 200: the mod polls this every couple of
            # seconds when idle, and "nothing" should not need parsing.
            return Response(status_code=204)
        return JobDocument(
            job_id=job.job_id,
            world_id=job.world_id,
            **job.request.model_dump(),
        )

    @app.post("/v1/jobs/{job_id}/started")
    def started(job_id: int) -> Response:
        # Distinct from reservation: the service hands a job out, and only the
        # mod can say it actually began. The gap matters after a crash.
        return transition(store.mark_started, job_id)

    @app.post("/v1/jobs/{job_id}/completed")
    def completed(job_id: int, result: CompletionResult) -> Response:
        return transition(store.mark_completed, job_id, result)

    @app.post("/v1/jobs/{job_id}/failed")
    def failed(job_id: int, report: FailureReport) -> Response:
        return transition(store.mark_failed, job_id, report.code, report.message)

    @app.post("/v1/jobs/{job_id}/progress")
    def progress(job_id: int, report: ProgressReport) -> Response:
        # Also renews the heartbeat, which is what lets a long job be told
        # apart from a dead one.
        return transition(store.mark_progress, job_id, report.units_done, report.units_total)

    @app.post("/v1/jobs/{job_id}/undo", status_code=201)
    def undo(job_id: int) -> SubmitResponse:
        """Enqueue a job that puts the region back the way this one found it.

        A new job rather than a state change on the old one: undoing is work,
        it can fail, and it wants the same lifecycle -- progress, heartbeat,
        recovery -- as any other. The original row stays exactly as it was, so
        history says what happened rather than what was later regretted.
        """
        original = lookup(job_id)
        if original.state is State.QUEUED:
            raise HTTPException(
                status_code=409,
                detail=f"job {job_id} has not run yet, so there is nothing to undo",
            )

        request = JobRequest(
            world=original.request.world,
            bounds=original.request.bounds,
            ops=[
                RestoreOp(
                    op="restore",
                    min=original.request.bounds.min,
                    max=original.request.bounds.max,
                    job=job_id,
                )
            ],
        )
        job = store.create(original.world_id, request)
        return SubmitResponse(job_id=job.job_id, world_id=original.world_id)

    @app.post("/v1/jobs/{job_id}/abandoned")
    def abandoned(job_id: int) -> Response:
        # The mod restarted holding this job id. Reported rather than inferred,
        # so history distinguishes "the executor came back" from "nobody did".
        return transition(store.mark_abandoned, job_id)

    @app.get("/v1/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "states": ",".join(s.value for s in State)}

    return app
