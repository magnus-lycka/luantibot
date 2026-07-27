# Luanti Programmable Builder Architecture

## Purpose

This system enables external programs and AI agents to build large structures in a running Luanti world without controlling a player, modifying the map database directly, or embedding planning logic in a Lua mod.

The central design principle is:

> External software decides what and where to build. A Luanti server-side Lua mod decides how to apply that plan safely to the world.

The first intended use case is constructing large underground complexes consisting of corridors, chambers, shafts, stairs, doors, markers, and reusable structures.

## Architecture

The system consists of three logical components:

```text
AI agent / design tools
          |
          | submit and inspect jobs
          v
Builder service
(local HTTP service, probably Python)
          ^
          | outbound HTTP polling
          |
Luanti server-side Lua mod
          |
          | emerge_area, VoxelManip, node APIs
          v
Luanti world
```

### Luanti server

Luanti remains the game server. Players connect to it normally.

The server-side Lua mod uses Luanti’s outbound HTTP API. In this particular relationship, the Luanti server acts as an HTTP client: it periodically asks the builder service whether work is available.

Luanti does not expose an incoming HTTP server to mods.

### Builder service

The builder service is a small local application, probably written in Python. It listens only on localhost unless remote access is deliberately added later.

It is responsible for:

- accepting construction plans from tools and AI agents;
- validating the external job format;
- queuing jobs;
- returning jobs to Luanti when requested;
- recording progress, results, and errors;
- retaining the high-level design independently of the voxel world;
- supporting inspection, cancellation, and eventual rebuilding;
- using PostgreSQL or another persistence mechanism internally.

Its database schema is an implementation detail of the service, not part of the interface between Luanti and external clients.

### Lua builder mod

The Lua mod is deliberately small and deterministic. It is responsible for:

- polling the builder service;
- accepting one job at a time;
- validating coordinates, dimensions, node names, and limits;
- loading or generating the required map area;
- translating high-level operations into voxel changes;
- applying those changes through supported Luanti APIs;
- processing large jobs incrementally to avoid freezing the server;
- reporting progress and completion;
- resuming or safely repeating interrupted work.

The Lua mod must never modify Luanti’s map database directly.

## Communication Direction

The normal flow is:

1. An external tool submits a construction job to the builder service.
2. The Lua mod asks the service for the next available job.
3. The service returns either a job or “no work”.
4. The mod validates and executes the job.
5. The mod periodically reports progress.
6. The mod reports completion or failure.
7. The mod asks for another job.

Example:

```text
Lua mod                         Builder service

GET /v1/workers/MyWorld/jobs/next
                         ---->

                         <----  204 No Content

GET /v1/workers/MyWorld/jobs/next
                         ---->

                         <----  200 OK + job document

POST /v1/jobs/173/started
                         ---->

POST /v1/jobs/173/progress
                         ---->

POST /v1/jobs/173/completed
                         ---->
```

Polling every one or two seconds is sufficient when idle. After completing a job, the mod may immediately request the next one.

The builder service should bind to `127.0.0.1` initially. The Lua mod must be authorized in `minetest.conf`:

```ini
secure.http_mods = programmable_builder
```

## HTTP Interface

The initial API can remain small.

### Submit a job

```http
POST /v1/jobs
Content-Type: application/json
```

The response contains the assigned job identifier.

### Fetch the next job

```http
GET /v1/workers/{worker_id}/jobs/next
```

Responses:

- `200 OK` with a job;
- `204 No Content` if no job is available.

Returning a job should atomically reserve it for that worker.

### Report that execution started

```http
POST /v1/jobs/{job_id}/started
Content-Type: application/json
```

### Report progress

```http
POST /v1/jobs/{job_id}/progress
Content-Type: application/json
```

Example:

```json
{
  "completed_units": 37,
  "total_units": 120,
  "message": "Excavating corridor segment 37 of 120"
}
```

### Report completion

```http
POST /v1/jobs/{job_id}/completed
Content-Type: application/json
```

Example:

```json
{
  "changed_nodes": 148220,
  "affected_min": [-6000, -20, -5500],
  "affected_max": [-5800, 30, -5350]
}
```

### Report failure

```http
POST /v1/jobs/{job_id}/failed
Content-Type: application/json
```

Example:

```json
{
  "code": "unknown_node",
  "message": "Node mcl_core:unknown_wall is not registered"
}
```

Cancellation and retry endpoints can be added after the basic execution path works.

## Construction Job Format

External clients should describe structures at a higher level than individual voxels.

An AI should say “build a corridor along this path”, not transmit several million node assignments.

Example job:

```json
{
  "version": 1,
  "world": "MyWorld",
  "operations": [
    {
      "type": "corridor",
      "path": [
        [-6000, 12, -5500],
        [-5900, 12, -5480],
        [-5800, 10, -5400]
      ],
      "inner_width": 3,
      "inner_height": 3,
      "wall_thickness": 1,
      "wall_node": "mcl_core:stonebrick",
      "floor_node": "mcl_core:stonebrick",
      "ceiling_node": "mcl_core:stonebrick",
      "interior_node": "air"
    },
    {
      "type": "chamber",
      "center": [-5800, 10, -5400],
      "inner_size": [30, 12, 40],
      "wall_thickness": 1,
      "wall_node": "mcl_core:stonebrick",
      "interior_node": "air"
    }
  ]
}
```

The initial operation vocabulary should be intentionally limited:

- `corridor`
- `chamber`
- `shaft`
- `stairs`
- `place_nodes`
- `place_schematic`
- `label`

More specialized operations can be added after these primitives are reliable.

## Coordinate and Measurement Conventions

All coordinates in the execution API are Luanti node coordinates.

The higher-level design system may use Traveller measurements, but conversion to node coordinates should occur before or during job compilation according to an explicit project scale.

Every job must state or inherit:

- world identifier;
- coordinate system version;
- unit convention;
- bounds of the affected region;
- operation-format version.

This prevents future changes in scale or interpretation from silently altering old plans.

## Execution Model

Large operations must not be performed as one uninterrupted Lua callback.

The Lua mod should:

1. Validate the entire job without changing the world.
2. Calculate its affected bounds.
3. Divide it into bounded work units, preferably aligned with mapblocks.
4. Call `emerge_area` for the next required region.
5. Wait for emergence to complete.
6. Modify the region with `VoxelManip`.
7. Write the region back and update lighting as required.
8. Report progress.
9. Yield before processing the next unit.

Only one construction job should run initially. Parallel execution can be considered later if it offers a demonstrated benefit.

For bulk terrain changes, `VoxelManip` should be preferred over calling `set_node` for every voxel. Ordinary node APIs remain appropriate for nodes whose callbacks, metadata, inventories, or orientation require special handling.

## Validation and Safety

Both the service and Lua mod should validate jobs. The Lua mod is the final authority because it changes the world.

Validation should include:

- recognized format version;
- correct world identifier;
- permitted operation types;
- coordinate limits;
- maximum affected volume;
- maximum work-unit size;
- registered and allow-listed node names;
- valid dimensions and wall thicknesses;
- valid schematic identifiers;
- protection policy;
- absence of malformed or non-finite numbers.

The service must not be able to request arbitrary Lua execution, shell commands, filesystem paths, SQL, or unrestricted node callbacks.

Authentication can initially use a shared bearer token because all traffic remains on localhost. The service should not listen on external interfaces by default.

## Idempotence and Recovery

Construction operations should be idempotent wherever practical:

> Repeating the same operation should produce the same final world state.

This is important because Luanti may stop after changing the world but before reporting completion.

Corridor excavation, chamber construction, and deterministic node placement are naturally idempotent. Operations involving inventories, spawned entities, or additive metadata require explicit duplicate protection.

Each job and operation should have a stable identifier. The Lua mod should persist enough local state to identify its current job across restarts.

Recovery policy for the first version:

- if a job was never started, execute it normally;
- if it was interrupted, safely restart it from the beginning;
- if it is idempotent, repeated work is acceptable;
- if it is not idempotent, reject automatic retry until that operation defines recovery semantics.

Fine-grained checkpointing can be added later.

## Persistence

The builder service owns persistent job and design data. PostgreSQL is a sensible implementation because it is already available, but the HTTP contract must not depend on its table structure.

At minimum, the service needs to retain:

- job identifier;
- submitted request;
- current state;
- assigned worker;
- creation, start, and completion times;
- latest progress;
- completion response or failure information;
- retry count;
- format version.

The service should also eventually store high-level complexes independently of execution jobs. A complex is a design; jobs are commands that materialize or modify that design.

## Separation of Design and Execution

The canonical design should not be the rendered voxel map alone.

A high-level model should retain concepts such as:

- sites;
- rooms;
- corridors;
- shafts;
- doors;
- connections;
- levels;
- labels;
- Traveller-specific notes;
- inhabitants and equipment;
- relationships between locations.

This model can be inspected, regenerated, transformed, or rendered through other tools.

The Lua mod receives compiled construction operations. It does not need to understand the full semantic model of a Traveller complex.

```text
Semantic design model
          |
          | compile
          v
Construction job
          |
          | execute
          v
Luanti voxels
```

## Mapserver Interaction

World changes must go through Luanti’s supported APIs so that mapblocks are saved normally and receive appropriate modification timestamps.

The builder must not write directly to the PostgreSQL `blocks` table.

Mapserver is expected to observe the resulting mapblock changes through its incremental rendering mechanism. Existing Mapserver pagination defects must be fixed separately; the builder should not attempt to compensate for them.

## AI Integration

AI agents should interact with the builder service, not directly with the Lua mod.

An AI may:

- create or revise the semantic design;
- compile a design into construction operations;
- submit jobs;
- inspect validation errors;
- monitor progress;
- generate follow-up corrections;
- request previews from separate mapping tools.

The service should validate AI-generated plans before they reach Luanti. Human approval can later be added for jobs exceeding specified size or risk thresholds.

The initial system should not permit an AI to submit arbitrary Lua code.

## Initial Implementation Plan

### Phase 1: Lua execution prototype

Implement a server-side mod with chat commands for:

- one straight corridor;
- one rectangular chamber;
- one vertical shaft.

Verify emergence, `VoxelManip`, lighting, saving, and Mapserver updates.

### Phase 2: Local HTTP polling

Add:

- HTTP authorization through `secure.http_mods`;
- worker identity;
- `jobs/next`;
- started, progress, completed, and failed reports;
- one active job at a time.

Use an in-memory queue in the service if that shortens initial development.

### Phase 3: Persistent builder service

Add PostgreSQL persistence, atomic job reservation, restart recovery, inspection, and cancellation.

### Phase 4: Structured design model

Represent complete sites, connections, rooms, shafts, labels, and Traveller metadata independently of individual build jobs.

### Phase 5: AI-assisted construction

Allow an AI agent to create and revise designs, submit validated jobs, monitor execution, and respond to failures.

## Non-Goals for the Initial Version

The first implementation does not need:

- an incoming HTTP server inside Luanti;
- a custom Luanti network client or player bot;
- direct writes to the Luanti map database;
- arbitrary Lua execution;
- several concurrent construction workers;
- real-time voxel streaming;
- a graphical editor;
- automatic generation of an entire planetary complex in one job.

The first success criterion is modest:

> An external program submits a deterministic corridor or chamber job, the running Luanti server builds it without freezing, and the service receives an accurate completion result.
>
