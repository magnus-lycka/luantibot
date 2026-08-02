# Luantibot — Implementation Plan

A test-driven build order for the Luanti builder bot: a Python service that
compiles high-level build intent into volumetric primitives, and a thin Lua mod
inside Luanti that applies them.

This document assumes the design decisions in [suggestion_claude.md](suggestion_claude.md)
and [suggestion_chatgpt.md](suggestion_chatgpt.md), with these amendments:

- The mod receives **ordered volumetric primitives** (`fill_box`, `fill_box_if`),
  not semantic operations (`corridor`) and not node arrays. Geometry compiles in
  Python.
- Single server, single worker, single user. No protection checks, no
  concurrency, no multi-worker addressing.
- Persistence is **SQLite**, one writer process.
- Lighting is deferred, not inline.
- Node validation is a **deny** list, not an allow-list — see "On node
  validation".
- Interrupted jobs are never resumed. Recovery is restore-then-re-run, manually
  triggered, and does not exist before M6 — see "Crash recovery protocol".

## Division of labour

**Python owns everything that requires thinking.**

- Geometry compilation: road/corridor/chamber/shaft intent → ordered box list.
- Terrain reasoning: where to tunnel, where to bridge, how deep pillars go.
- Job lifecycle, persistence, history.
- The MCP tool surface that Claude/ChatGPT calls.

**Lua owns everything that must touch the world.**

- Poll for a job, execute it, report back.
- Validate coordinates, volumes, and node names (registered, not `ignore`, not
  on the deny list).
- Emerge → VoxelManip read → apply boxes → write.
- Chunk work across server steps.
- Snapshot regions before writing, restore on request.

**The Lua mod contains no geometry.** If you find yourself writing a loop in Lua
that computes *where* something goes rather than *applying* what it was told,
that logic belongs in Python. This is not aesthetic — it is what keeps the
iteration loop fast, because changing Python is a process restart and changing
Lua is a server restart.

## Repository layout

```text
luantibot/
├── pyproject.toml
├── uv.lock
├── .pre-commit-config.yaml
├── .luacheckrc
├── .stylua.toml
├── docs/
│   └── implementation_plan.md
├── src/luantibot/
│   ├── __init__.py
│   ├── ops.py              # wire-format models, versioning
│   ├── geometry.py         # mapblocks and mapgen chunks; mirrors plan.lua
│   ├── compile/            # intent → ops. Pure functions, no I/O. (M7)
│   │   ├── boxes.py
│   │   ├── corridor.py
│   │   └── road.py
│   ├── service/
│   │   ├── app.py          # FastAPI app
│   │   ├── store.py        # SQLite and in-memory, one Store protocol
│   │   ├── logconfig.py    # timestamps, so lines line up with debug.txt
│   │   ├── __main__.py     # entry point
│   │   └── schema.sql
│   └── mcp_server.py       # MCP tools → HTTP client of the service
├── tests/
│   ├── unit/               # pure Python, fast
│   ├── api/                # FastAPI TestClient, run against both stores
│   └── contract/           # validates shared fixtures
├── contract/
│   └── fixtures/*.json     # shared between Python and Lua tests
├── scripts/
│   ├── lua-env.sh          # project-local LuaJIT rocks tree on PATH
│   ├── busted              # unit suite, output capped
│   ├── luacheck            # static analysis
│   ├── capped              # bounds a command's output and kills a runaway
│   ├── coverage            # luacov over src/, kept out of the normal run
│   └── integration         # boots a scratch server, asserts, shuts down
└── mods/luantibot/
    ├── mod.conf
    ├── init.lua            # wiring: acquires engine handles, injects them
    ├── .busted             # spec paths
    ├── .luacov             # coverage config; includeuntestedfiles matters
    ├── src/
    │   ├── version.lua     # pure: wire format acceptance
    │   ├── parse.lua       # pure: chat command arguments
    │   ├── identity.lua    # pure: which world is this, may we act in it
    │   ├── plan.lua        # pure: box → work units, ops clipped to a unit
    │   ├── validate.lua    # pure: the wire contract's rules
    │   ├── palette.lua     # pure: names → content ids, injected resolve
    │   ├── match.lua       # pure: names and group: → a content-id set
    │   ├── apply.lua       # pure: ops → mutate content and param2 arrays
    │   ├── survey.lua      # pure: columns → first walkable surface
    │   ├── emerge.lua      # pure: accounting for the emerge callback
    │   ├── poll.lua        # pure: the polling state machine
    │   ├── world.lua       # pure: the unit walk; engine injected
    │   ├── client.lua      # adapter: HTTP
    │   ├── storage.lua     # adapter: mod storage
    │   └── snapshot.lua    # pure: region ↔ self-describing bytes (M6)
    └── spec/               # busted tests, one per pure module
```

The mod must be visible to Luanti. Symlink it once:

```sh
ln -s /path/to/luantibot/mods/luantibot \
      ~/Library/Application\ Support/minetest/worlds/MyWorld/worldmods/luantibot
```

And in `minetest.conf`:

```ini
secure.http_mods = luantibot
```

## Python toolchain

```sh
uv init --package .
uv add fastapi uvicorn httpx pydantic mcp
uv add --dev pytest pytest-cov hypothesis ruff ty deptry bandit pre-commit
```

FastAPI over plain `http.server`: you get request validation from the same
Pydantic models that define the wire format, and `TestClient` makes the API
layer testable without a running process. Both matter here.

`pyproject.toml` additions:

```toml
[tool.ruff]
line-length = 100
src = ["src", "tests"]

[tool.ruff.lint]
select = ["E", "F", "I", "UP", "B", "SIM", "RUF"]

[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-q --strict-markers"

[tool.bandit]
exclude_dirs = ["tests"]

[tool.deptry.per_rule_ignores]
DEP002 = ["uvicorn"]   # imported by nothing; invoked as a server
```

## Lua toolchain

You need three tools. None of them are part of Luanti.

Luanti embeds **LuaJIT, which is Lua 5.1**. Homebrew's `lua` is 5.5, and the
differences land exactly where our risk is: integer/float division, `//`,
`unpack` vs `table.unpack`. Testing pure modules on 5.5 would give false
confidence about voxel index arithmetic. So install against LuaJIT, into a
project-local rocks tree:

```sh
brew install luajit luarocks stylua
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" \
         --tree=.luarocks install busted
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" \
         --tree=.luarocks install luacheck
```

Add `luacov` the same way for coverage. Every flag matters: Homebrew's luarocks
is itself a Lua 5.5 script and so defaults to installing there, where nothing in
this project can see it — and the failure is silent, because `luarocks list`
happily shows the rock it just put somewhere useless.

`scripts/lua-env.sh` wraps the resulting `LUA_PATH`/`PATH` dance; run the tools
through `./scripts/busted` and `./scripts/luacheck` rather than directly.

- **busted** — the standard Lua test framework. `describe`/`it`/`assert.are.same`,
  familiar shape if you've used pytest or RSpec. Run `busted` from
  `mods/luantibot/`.
- **luacheck** — static analysis. Its main job here is catching typo'd globals,
  which in Lua are silently `nil` rather than an error. This is the single
  highest-value Lua tool.
- **stylua** — formatter. Rust binary, no config needed beyond a line width.
- **luacov** — line coverage, via `./scripts/coverage`. Deliberately not part of
  the normal run: `debug.sethook` turns LuaJIT's compiler off, so an
  instrumented suite costs a few hundred times a plain one, which looks
  indistinguishable from a hang. Its config lives in `mods/luantibot/.luacov`,
  and `includeuntestedfiles` there is load-bearing — without it a module with no
  spec at all is simply absent from the report and the total is computed over
  whatever happened to run. It read 98.89% while two modules sat at zero.

**Every test run goes through `scripts/capped`.** Python test runners truncate
their own assertion diffs; busted does not, so an assertion over a large
collection formats the entire difference into one string. One did, and the
editor reached 20 GB before it could be stopped. The wrapper caps the stream and
kills the producer rather than merely hiding the output — but the real lesson is
in the assertions: report a count and a couple of examples, never a whole
collection.

`.luacheckrc`:

```lua
std = "lua51"
max_line_length = 100
read_globals = {
    "core", "minetest", "vector", "VoxelManip", "VoxelArea",
    "ItemStack", "PseudoRandom", "PerlinNoise", "dump", "dump2",
}
globals = { "luantibot" }
ignore = { "212/self" }
```

`.stylua.toml`:

```toml
column_width = 100
indent_type = "Spaces"
indent_width = 4
```

### The constraint that makes Lua testable

Busted runs in a plain Lua interpreter. There is no `core` table, no
`VoxelManip`, no world. Any module that calls `core.*` cannot be unit tested
without an engine mock, and engine mocks rot.

So every Lua file is one of exactly two kinds, and the kind is stated at the top
of the file:

**Pure modules** never reference `core`, `VoxelManip`, or any other engine
global. Where they need an engine capability they receive it as an argument:
`palette.lua` takes a `resolve(name) -> content_id` function, `poll.lua` takes
`http` and `json` tables, `plan.lua` takes nothing but numbers. They are unit
tested with busted and fakes that are a dozen lines each.

**Adapters** may touch the engine, and in exchange are allowed no logic — no
branching on job content, no arithmetic beyond argument shuffling. `world.lua`
wraps `core.emerge_area`, `core.get_voxel_manip`, `core.get_content_id`.
`client.lua` wraps HTTP and `storage.lua` wraps mod storage. `snapshot.lua` was
expected to join them and did not: encoding a region is arithmetic over two
arrays, so it is pure and the file I/O is injected like every other engine
capability. Being able to encode under one node registry and decode under
another — which is the whole point of the format — is only testable that way. `init.lua` is the wiring that acquires engine handles at load
time — including `core.request_http_api()`, which *must* run at top level — and
injects them into the pure modules. Adapters get integration coverage only.

> **`require()` is disabled under Luanti's mod security.** A pure module cannot
> import a sibling pure module: busted resolves `require` happily via `lpath`,
> and the same file then dies inside the engine with *"require() is disabled
> when mod security is on"*. So a pure module needing another is written as a
> factory taking its dependencies — exactly like engine capabilities are
> injected. `validate.lua` is the first of these:
> `load("validate")({ version = version })`.
>
> The consequence worth internalising: **a green busted run does not prove a
> module loads in Luanti.** Only the integration harness catches this class,
> which is an argument for running it at every milestone rather than at the end.

The test for which file something belongs in: if you can imagine a bug in it, it
goes in a pure module. `apply.lua` doesn't take a VoxelManip, it takes a flat
array of content ids plus area bounds and mutates the array — that's where the
real correctness risk lives (off-by-one on box bounds, wrong index arithmetic)
and it must be unit testable.

There is a project called **mineunit** that mocks the Luanti API for busted.
Evaluate it if you want, but with the engine surface confined to two adapters
you don't need it, and a hand-rolled fake is less likely to break on a Luanti
upgrade.

## Testing strategy

Four layers, in decreasing order of how often you run them.

**1. Lua unit (busted, milliseconds).** Pure modules. Box math, validation,
chunking, palette resolution. Most of your Lua tests live here.

**2. Python unit (pytest, milliseconds).** The geometry compiler is pure
functions from intent to box lists — ideal for property-based tests with
hypothesis. Assert invariants rather than exact output, or the tests break every
time you improve the compiler:

- every emitted box lies inside the job's declared bounding box;
- the interior of a corridor is connected end to end;
- no box has `min > max` on any axis;
- compiling twice with the same inputs gives the same output.

One more property belongs here. Model `apply.lua`'s per-node semantics in a few
lines of Python and assert, over random worlds and **op lists the compiler
actually emits**:

```python
assert apply(apply(world, ops), ops) == apply(world, ops)
```

Note the restriction. Op lists in general are *not* idempotent — see "Why
re-running is not safe in general" below — so this is a property of the
compiler's output, not of the op vocabulary.

It is not a recovery property: `retry` restores before re-running and doesn't
depend on it. What it catches is a compiler emitting order-dependent nonsense,
which surfaces the moment you submit the same intent twice — an ordinary thing to
do while iterating on a design.

**3. Python API (pytest + TestClient, ~1s).** Job submission, reservation,
progress, completion, restart sweep. Runs against a temporary SQLite file.
Because these test the HTTP surface rather than the store, they don't change
when the storage layer does.

**4. Integration (real Luanti, ~30s).** A headless server on a scratch world,
with the mod driven by a real Python service. This is the only place the adapters
— `world.lua`, `snapshot.lua`, `init.lua` — and the real `emerge_area` and
VoxelManip get exercised. Run it per milestone, not per save.

### Contract fixtures

`contract/fixtures/` holds JSON job documents that both sides load. Python tests
assert its compiler emits documents matching them; Lua tests assert its parser
accepts them and produces the expected work units. When you change the wire
format, both suites fail, which is the point. This catches drift without needing
a full integration run.

### Integration harness

Use a **scratch world**, never a world you care about, on the SQLite map backend
so it is disposable. Build it inside the repo under `tests/integration/run/`
(gitignored) and delete it on every run, rather than anywhere near the real
worlds directory.

Drive the server headless and let a test mod assert and shut down:

```sh
"$LUANTI" --server --world "$RUN_DIR/world" --config "$CONF" --gameid "$GAMEID"
```

Machine-specific values — the binary path especially — belong in
`scripts/local.env`, which is gitignored and sourced by the harness. Nothing
about one developer's setup should be committed.

Assertions go in a `luantibot_test` mod that runs on
`core.register_on_mods_loaded`, exercises the real API, calls
`core.request_shutdown()`, and writes a result file the shell script checks.
`core.log("error", ...)` lines in `debug.txt` are your test output.

Confirm in M0 that this build actually supports `--server`; if the macOS bundle
is client-only, run the client with `--go --gameid ...` in a headless-friendly
config instead, or build the server target separately.

## Pre-commit

Run Python tools through `uv run` as local hooks rather than pre-commit's own
isolated environments. That guarantees the hook uses the version in `uv.lock`,
so CI, your shell, and the hook can't disagree.

`.pre-commit-config.yaml`:

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-merge-conflict
      - id: check-added-large-files
      - id: check-toml
      - id: check-yaml
      - id: check-json

  - repo: local
    hooks:
      - id: ruff-check
        name: ruff check
        entry: uv run ruff check --fix
        language: system
        types: [python]

      - id: ruff-format
        name: ruff format
        entry: uv run ruff format
        language: system
        types: [python]

      - id: ty
        name: ty check
        entry: uv run ty check
        language: system
        types: [python]
        pass_filenames: false

      - id: deptry
        name: deptry
        entry: uv run deptry src
        language: system
        pass_filenames: false
        files: ^(src/|pyproject\.toml)

      - id: bandit
        name: bandit
        entry: uv run bandit -c pyproject.toml -q -r src
        language: system
        pass_filenames: false
        files: ^src/

      - id: stylua
        name: stylua
        entry: stylua
        language: system
        types: [lua]

      - id: luacheck
        name: luacheck
        entry: luacheck
        language: system
        types: [lua]

      - id: pytest
        name: pytest
        entry: uv run pytest
        language: system
        pass_filenames: false
        stages: [pre-push]

      - id: busted
        name: busted
        entry: sh -c 'cd mods/luantibot && busted'
        language: system
        pass_filenames: false
        stages: [pre-push]
```

Test suites on `pre-push` rather than `pre-commit` — small commits stay fast,
and nothing broken reaches the remote.

`ty` is very new. If it produces noise on FastAPI or Pydantic types, narrow it
to `src/luantibot/compile` and `src/luantibot/ops.py` first — the pure code is
where type checking pays off anyway — and widen as it matures.

## Wire contract

Versioned from the first commit, because the mod and service restart
independently.

```json
{
  "format": 1,
  "job_id": 173,
  "world_id": 3,
  "world": "MyWorld",
  "palette": ["air", "mcl_core:stonebrick", "mcl_core:stone"],
  "bounds": {"min": [-6000, -20, -5500], "max": [-5800, 30, -5350]},
  "ops": [
    {"op": "emerge"},
    {"op": "survey", "min": [-6000,-20,-5500], "max": [-5800,30,-5350],
     "step": 8},
    {"op": "fill_box_if", "min": [-6000,10,-5500], "max": [-5995,15,-5495],
     "node": 2, "param2": 0,
     "match": ["air", "group:liquid", "group:falling_node"], "invert": false},
    {"op": "fill_box", "min": [-5999,11,-5499], "max": [-5996,14,-5496],
     "node": 0, "param2": 0}
  ]
}
```

`param2` is not decoration and not optional: it is a trapdoor's facing, a slab's
half, a dyed block's colour. A fill replaces the node completely, so leaving it
unset would let the new node inherit the orientation of whatever it overwrote.
Every writing op therefore carries it, defaulted to 0.

`survey` writes nothing. Its answer comes back in the job's completion result
under `columns`, one entry per sampled column, giving the height and name of the
first **walkable** node — not the first node, which would put a surface on top
of a flower.

Rules the mod enforces, in order, before touching the world:

1. `format` is recognised.
2. `world` matches this server.
3. Every palette entry is a registered node, is not `ignore`, and is not on the
   deny list. Resolve to content ids once.
4. Every op type is known.
5. Every box is well-formed, inside `bounds`, and inside the world limits.
6. Total volume of `bounds` is under a configured cap.
7. All numbers are finite integers.

Group expressions (`group:liquid`) are permitted only in a `match` predicate,
never in `palette`. A palette entry names one concrete node.

### On node validation

Rule 3 is a **deny** list, not an allow-list, and that is deliberate. VoxelManip
writes bypass node callbacks, so the frightening cases mostly aren't: TNT written
by VM does not detonate. The two node classes that actually cause damage are
liquids and gravity nodes, and `fill_box_if` (M3) exists precisely to handle
them. An allow-list would block you the first time you want a lava-lit hall in a
Traveller complex, in exchange for guarding against an adversary this system
doesn't have.

So: ship an empty deny list and a config key to populate it. Add entries when
something surprises you, not in anticipation.

### Ordering and work units

**Reference semantics.** Apply each op, in original order, across the whole of
`bounds`. Shell before carve. This is the definition of what a job means, and
it's the obvious op-major loop: `for op in ops: for cell in op.box: apply`.

**Implementation.** Op-major execution would require emerging and VoxelManip'ing
the entire bounds once per op, which is unaffordable. So the mod runs unit-major
instead, one emerge/VM cycle per unit:

> Partition `bounds` into **disjoint** mapblock-aligned units. For each unit,
> walk the op list in original order, intersect each op's box with that unit, and
> apply the intersection.

The two traversals are equivalent **because `fill_box` and `fill_box_if` are
node-local**: neither reads a neighbouring node, so each cell's outcome depends
only on the ordered sequence of ops covering that cell, which unit-major
preserves exactly. Unit-major is chosen for cost, not for semantics.

Three things break that equivalence, and only these three:

1. **Reordering ops at a node.** Within a unit the op list must be walked in
   original order. Grouping or sorting ops by anything is what goes wrong.
2. **Units overlapping in what they write.** If a later milestone reads a margin
   of surrounding mapblocks (M8 lighting will want one), the VoxelManip region
   overlaps its neighbours but the written region must not.
3. **Neighbour-reading ops.** Flood fill, connected-component selection,
   structural support detection. Adding one invalidates unit decomposition
   outright and needs a different execution model. Do not add one without
   revisiting this section.

   The first real candidate has already come up and been declined: a
   conditional fill that marches in a direction and places a terminator where it
   stops. See "What `fill_box_if` deliberately does not do" under M3 for why it
   is a survey-plus-explicit-boxes problem instead.

Reporting endpoints as in [suggestion_chatgpt.md](suggestion_chatgpt.md#L120):
`GET /v1/workers/{id}/jobs/next`, `POST /v1/jobs/{id}/{started,progress,completed,failed}`,
plus `abandoned` from M4 and `undo` / `retry` from M6.

## World identity

Builds are permanent and world-scoped: "what did I build, and in which world"
must stay answerable for the life of the project. Coordinates repeat across
worlds, so build history is meaningless without a durable world identity —
and neither the Luanti world name nor the directory name is durable, since
both can be renamed.

So the service owns identity and the mod caches it:

```sql
CREATE TABLE world (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL UNIQUE,   -- display label, changeable
    created_at TEXT NOT NULL
);
```

`job.world_id` references it. Renaming a world is one `UPDATE` and detaches
nothing.

`AUTOINCREMENT` is not decorative. Without it SQLite reuses the highest rowid
after a delete, and we plan to prune old snapshot directories — a reused job id
would silently attach an old snapshot to a new job, which surfaces only when an
`undo` restores the wrong terrain.

### Registration handshake

The mod learns its id once and remembers it:

1. On load, read `world_id` from `core.get_mod_storage()`.
2. Absent → `POST /v1/worlds {"name": "<local world name>"}`. The service
   returns an existing row if the name matches, or creates one. Persist the id.
3. Present → poll `GET /v1/worlds/{world_id}/jobs/next` from then on.

Mod storage is per-mod, per-world, living in `<world>/mod_storage.sqlite`. It
travels with the world directory, which is exactly what makes the binding
durable — and exactly why a copied world inherits its parent's identity.

**Registration adopts by name.** Binding a copied world under the *same* name
merges it into the original's history, silently. The name passed to `bind` is
the decision; the id follows it.

### Rebinding

`world_id` must be changeable, or a world copy can never become a separate
world. Three chat commands, all `server` priv, all logged:

- `/lb_world` — show stored id, the service's name for it, and the local world
  directory name.
- `/lb_world_bind <name>` — register under `<name>` and overwrite the stored id.
  This is what splits a copy off: `cp -r MyWorld MyWorld_v2`, boot it, then
  `/lb_world_bind MyWorld_v2`.
- `/lb_world_forget` — clear the id; re-register on next start.

Two safeguards, because everything that goes wrong here goes wrong silently:

- **Log identity on every startup**: `[luantibot] world_id=3 "MyWorld"
  (dir: MyWorld)`.
- **Warn, do not refuse, on divergence** between the service's name and the
  local directory name. A legitimate rename and an accidental copy look
  identical at that instant, so refusing would break the legitimate case.

### Routing and the world check

Two layers, deliberately:

1. **The service never offers a foreign job.** Reservation filters on
   `world_id`, so cross-world execution is structurally impossible rather than
   something the mod must catch in time. One Luanti server hosts one world, so
   server ≡ world — there is no separate "worker" concept.
2. **The mod asserts anyway**, before any node is touched. A mismatch means
   misconfiguration, so it fails the job with `wrong_world` and reports it. It
   does **not** return the job to the queue: that would fetch and reject the
   same job forever.

Job submission takes a world *name* and resolves it; the document handed to the
mod carries `world_id` for matching and `world` for logging. Names for humans,
ids for machines.

Until the mod-side check lands, the only thing protecting a real world is that
the mod is not installed in it. That is a deployment fact, not an invariant, and
it stops being sufficient the moment `fill_box` exists.

## Crash recovery protocol

Two processes hold state about the same job: the service (a row) and the mod (a
job id in `core.get_mod_storage()`). They reconcile at mod startup, and the rule
is that **the mod never resumes**.

1. On startup, if mod storage holds a job id, the mod reports
   `POST /v1/jobs/{id}/abandoned` with the unit count it reached, clears storage,
   and goes on to ask for the next job. It does not attempt to continue.
2. The service moves that row to `interrupted`.
3. On *service* startup, any `running` row whose `heartbeat_at` is older than the
   stale threshold also moves to `interrupted`. This covers the mod dying without
   getting its report out.
4. `interrupted` is terminal until you act on it. What "acting on it" means
   depends on the milestone — see below.

Requeue is deliberately manual. A job that crashes the server would otherwise
auto-retry into a crash loop, and this is a tool you sit in front of — you would
rather see the row than have it thrash.

Mod storage exists for *reconciliation*, not resumption: its only job is to let
the mod name the job it was killed during.

### Why re-running is not safe in general

An interrupted job leaves the world partially modified. Re-running the same op
list over that partial state does **not** reliably reproduce the intended
result, because an ordered sequence of `fill_box_if` operations is not
idempotent. The minimal counterexample:

```text
op1: stone -> dirt
op2: air   -> stone

start = air:   run 1 gives stone   (op1 misses, op2 fires)
               run 2 gives dirt    (op1 now fires on the stone op2 wrote)
```

The structural cause is that an earlier op's predicate matches a later op's
output. Some op lists survive this — the tunnel pattern does, because the carve
op is an unconditional `fill_box` and unconditional writes erase history — but
that is a property of particular compiler output, not a guarantee of the op
vocabulary. Do not build recovery on it.

### Recovery, by milestone

**Before M6 (no snapshots).** There is no sound automatic recovery. `interrupted`
is genuinely terminal: inspect the row, look at the world, and fix it by hand or
submit a corrected job. Do not add a `retry` endpoint yet — an endpoint that is
usually right is worse than no endpoint, because you will trust it.

**From M6 onward.** `POST /v1/jobs/{id}/retry` is defined as **restore, then
re-run**, as one operation: replay the job's existing snapshots in reverse,
reset `units_done` to zero, and requeue. The region is then back at its recorded
pre-job **node type and orientation** — not metadata, inventories, timers or
lighting, none of which are snapshotted (see M6). That is enough for the re-run
to be sound, because every op's predicate reads only node type; it is not a
claim that the world is byte-for-byte as it was.

The re-run keeps snapshotting on, per-unit, under the rule in M6: units already
holding a snapshot file are skipped, units the failed attempt never reached are
snapshotted as they come. Suppressing snapshots wholesale during a retry would
leave the untouched tail with no record and break `undo`.

The property test in Testing strategy layer 2 no longer supports recovery at
all — retry doesn't need it. It stays as a **compiler** sanity check: submitting
the same intent twice should not build something different the second time, which
is an ordinary authoring action and a plausible source of order-dependent
compiler bugs. It says nothing about whether a half-built structure is coherent;
it isn't.

## Build collisions

A job whose ops land on nodes an earlier job built is usually a mistake — a
pillar dropped through a bridge deck, a road driven through a tunnel someone
spent an evening on. Usually, but not always: turning old houses into ruins is a
legitimate build, and so is widening something that already exists.

So the rule is **warn, do not refuse**, with intent as an explicit field rather
than a heuristic:

```json
{"intent": "fresh"}     // default: warn when ops touch a previous build
{"intent": "replace"}   // deliberate; build over it without complaint
```

**Compare op boxes, not `bounds`.** Bounds are what gets emerged and are far
larger than what gets written; two bridges at different heights have overlapping
bounds and not one node in common. The op boxes are already stored in each job's
`request`, so this needs no new data — only an index over them.

**This is not the unit seam, and conflating the two would be a bad mistake.**
The seam is where the mod chopped one job into work units, at whatever multiple
of 80 nodes the arithmetic produced. Nobody chose it, nobody can see it, and a
result that depends on where it fell is a defect in the mod — see "Ordering and
work units". A build collision is the opposite in every respect: it is in the
design, the author can see it, and the right response is to say so rather than
to resolve it silently. One is an invariant we owe the user; the other is a
question we owe them.

Two limits worth stating up front. It can only see what *this service* built, so
hand-placed nodes and mapgen structures are invisible to it — a village is not
protected. And the history grows without bound, so comparing a new job against
every previous one in a world stops being free somewhere in the thousands; that
is an indexing problem, not a reason to skip the check.

Belongs with the geometry compiler in M7, which is the first point at which
jobs are generated rather than hand-written and so the first at which a
collision is likely to be accidental.

## Milestones

Each has a **Done when** you can actually check. Don't start the next one until
it passes.

### ✅ M0 — Skeleton and tooling — DONE

*Delivered in `0f724ce`.*

No functionality. The goal is that both test suites run and pre-commit is green,
so every later step has somewhere to put its test.

1. ✅ `uv init`, add dependencies, commit `uv.lock`.
2. ✅ `pyproject.toml` config, one trivial passing pytest.
3. ✅ Install luajit/luarocks/busted/luacheck/stylua. `.luacheckrc`,
   `.stylua.toml`, one trivial passing busted spec.
4. ✅ `.pre-commit-config.yaml`, `pre-commit install --install-hooks`,
   `pre-commit install --hook-type pre-push`.
5. ✅ Create the scratch world and confirm the custom Luanti build starts
   headless and shuts down on command. Documented in
   `tests/integration/README.md`.

**Done when** `pre-commit run --all-files` is clean, `uv run pytest` and
`busted` both pass, and you have a one-line command that boots and stops a
scratch server. — *All met: 14 hooks clean, 1 pytest, 3 busted,
`./scripts/integration` boots, asserts and shuts down.*

Two things came out differently than written:

- **LuaJIT, not Homebrew `lua`.** Homebrew ships 5.5; Luanti embeds 5.1. Tools
  are installed against LuaJIT into a project-local `.luarocks/` tree and run
  via `./scripts/busted` and `./scripts/luacheck`. See "Lua toolchain".
- **The M6 file-writing question got answered early**, by folding a probe into
  the M0 harness. `core.safe_file_write` and `core.get_dir_list` work from a
  non-trusted mod, so M6 snapshots stay on the Lua side.

### ✅ M1 — Emerge, end to end — DONE

The whole pipeline with the one operation that cannot damage anything. Nothing
here writes a node.

**1.1 — Mod loads and emerges via chat command.** ✅ **DONE**
`mod.conf` with `name = luantibot`. `world.lua` exposes
`emerge(p1, p2, on_done)` wrapping `core.emerge_area`; completion is the
callback invocation with `calls_remaining == 0`, and any callback with action
`core.EMERGE_ERRORED` or `EMERGE_CANCELLED` fails the whole operation. Register
`/lb_emerge <x> <y> <z> <radius>`.

*Test first:* a busted spec for `plan.lua` that converts a centre+radius into a
mapblock-aligned `(p1, p2)` pair. That's the pure part. Then verify the chat
command by hand on the scratch world and watch `debug.txt`.

> **Emerge callbacks do not run on the main thread.** Verified against 5.16.1
> source: `EmergeThread::runCompletionCallbacks` invokes the Lua callback from
> the emerge worker thread, and `LuaEmergeAreaCallback` takes a
> `Server::EnvAutoLock` around it. So the callback is *serialised* against the
> server step, but it is not *on* it, and any work done inline holds the
> environment lock for its whole duration.
>
> This shapes M2 and M4: the emerge callback must only record "unit N is ready"
> and return. The VoxelManip read/apply/write belongs in a globalstep on the
> main thread, which is where the plan's per-unit state machine was going
> anyway. Do not do map work inside the emerge callback.

**1.2 — Service with an in-memory queue.** ✅ **DONE**
`POST /v1/jobs`, `GET /v1/workers/{id}/jobs/next` returning 200 or 204,
`POST /v1/jobs/{id}/completed`, `POST /v1/jobs/{id}/failed`. Also `started`
(from the wire contract) and `GET /v1/jobs/{id}` for inspection.

*Test first:* API tests for submit → fetch → complete, fetch-when-empty → 204,
and fetching twice reserves only once.

Delivered as `ops.py` (Pydantic wire models), `service/store.py` (`Store`
protocol + `InMemoryStore`) and `service/app.py`. 21 API tests. Notes:

- **Models are `extra="forbid"`.** A typo'd key in a job document must fail
  loudly rather than be silently dropped, or the build quietly does something
  other than what was asked. `Vec3 = tuple[int, int, int]` also rejects floats
  and non-finite values at parse time, so they can never reach `emerge_area`.
- **Reserved ≠ started.** Reservation is the service handing work out; `started`
  is the mod confirming it began. The gap is what distinguishes "died before
  starting" from "died mid-job" after a crash, which M4 needs.
- **Reporting on a job that isn't `running` is 409**, not a silent no-op — that
  is a stale report from a restarted mod, or a double report, and neither should
  mutate state.
- The store is a `Protocol`, so M1.3 swaps SQLite in underneath without the API
  or its tests changing. Only `tests/api/conftest.py` knows which store is live.

**1.3 — SQLite behind the same API.** ✅ **DONE**
Two tables. `world` per "World identity" above, and
`job(id, world_id, created_at, state, intent_json, ops_json,
bbox_min_x…bbox_max_z, heartbeat_at, started_at, finished_at, units_done,
units_total, error_code, error_msg, snapshot_path)`, both `AUTOINCREMENT`.
WAL mode, one writer.

`world_id` and the bbox are **columns, not JSON**, because "what did I build
around here in MyWorld" is the query the whole history exists to answer:

```sql
SELECT * FROM job WHERE world_id = ? AND state = 'completed'
  AND bbox_min_x <= ? AND bbox_max_x >= ? ...
```

Add `POST /v1/worlds` (register, adopting by name) and `GET /v1/worlds`.
Reservation becomes world-scoped and is a single
`UPDATE … WHERE world_id = ? AND state='queued' … RETURNING`. Implement step 3
of the recovery protocol here — the service-startup sweep of stale `running`
rows. `abandoned` waits until M4, when there is work long enough to be
interrupted; `retry` until M6, when there is a snapshot to restore from.

*Test first:* the M1.2 API tests must pass against the new store with only the
storage fixture changed — that's the proof the API doesn't leak the schema.
Then add tests for registration, world-scoped reservation, the startup sweep,
and double-reservation under a repeated call.

> The endpoint moves from `/v1/workers/{worker}/…` to `/v1/worlds/{world_id}/…`
> and `worker` disappears — it was always the world. That is a deliberate
> contract change, not schema leakage, made while the contract has no users.

Delivered as `schema.sql`, `SqliteStore` beside `InMemoryStore`, and the world
endpoints. 37 Python tests. The criterion held: all 21 M1.2 job tests passed
against SQLite with only `conftest.py` changed. Notes:

- **The store takes a lock, and that is the design.** FastAPI runs sync handlers
  on a threadpool, so `check_same_thread=False` plus an `RLock` around every
  operation. "One writer" is the claim the recovery model rests on; the lock is
  what makes it true rather than aspirational. WAL is on so a separate
  read-only connection can inspect a live database without blocking it.
- **`stale_after` is injectable** on both stores. The startup-sweep test then
  exercises the real production path — construct with a zero window, restart,
  observe `interrupted` — instead of reaching into the database to backdate a
  heartbeat, or adding a mutator that exists only for tests.
- **No `assert` for narrowing.** `_parse_required` raises, because asserts are
  stripped under `python -O` and a NULL in a NOT NULL column means the schema
  and the code disagree, which should be loud.

**1.4 — Lua polls over HTTP.** ✅ **DONE**
`local http = core.request_http_api()` at the **top level** of `init.lua` — it
returns nil if called later or if the mod isn't in `secure.http_mods`. Use
`core.parse_json` / `core.write_json`; you do not need dkjson. A globalstep
accumulates `dtime` and fetches every ~2s when idle, immediately after a
completed job.

Also the mod side of "World identity": the registration handshake against
`core.get_mod_storage()`, `/lb_world`, `/lb_world_bind`, `/lb_world_forget`, and
the startup identity log.

And **rule 2 of the wire contract, brought forward from M2**: compare the job's
`world_id` against the stored one and fail with `wrong_world` on mismatch. It
belongs here rather than in M2 because M1.4 is the first milestone where the mod
executes work it did not originate, and M2 is the first that writes nodes — the
guard has to exist before the thing it guards against.

M1.4 also shipped a fail-closed `luantibot_world` setting, naming the one world
the mod would act in. **Removed after M2.** A single global world name capped the
system at one world, contradicting the per-`world_id` routing that exists so
several servers can build at once — and it failed silently, since a disarmed mod
loads normally and merely leaves its jobs queued. Installing the mod in a world
is the opt-in; the world check above is what makes that safe.

Delivered as pure `poll.lua`, `identity.lua`, `validate.lua`; adapters
`client.lua`, `storage.lua`; and the wiring in `init.lua`. 75 Lua tests. The
integration harness now runs the **real service** alongside the server, so a job
queued by `curl` before boot is fetched, executed and reported with nothing
in-world triggering it — and the run asserts the service's own row reads
`completed`. Notes:

- **`poll.lua` never touches HTTP.** It emits request descriptions and consumes
  response descriptions, which is what lets a bare Lua interpreter test the
  whole state machine — backoff, one-request-in-flight, report-then-poll — with
  no network and no engine.
- **Rebinding drops the in-flight request**, so a reply that arrives afterwards
  has nothing to be attributed to and is answered `stale`. Without it, a poll in
  flight when you `/lb_world_bind` could resolve against the identity you just
  abandoned and attach work to the wrong world.

  There was an epoch counter beside this doing the same job, and it was removed
  once coverage showed it could never fire: clearing the in-flight record always
  caught the case first. Two mechanisms for one hazard, one of them unreachable,
  is worse than one with a test — `spec/poll_spec.lua` now asserts the
  behaviour after both `rebind` and `forget`, so the guarantee survives whoever
  next edits `_reset_timing`.
- **A failed completion report does not retry forever.** The job is finished
  either way and the service sweeps a cold row as `interrupted`; retrying would
  strand the mod on a job it has already done.

*Test first:* busted specs for `poll.lua`'s state machine with an injected fake
`http` — idle → job → running → report → idle, plus what happens when the
service is down (back off, don't spin).

**1.5 — MCP tool.** ✅ **DONE**
One tool, `emerge_area(min, max)`, that POSTs a job and returns the id. The MCP
server is an HTTP client of the service, not a second SQLite writer.

Delivered as `mcp_server.py` with four tools — `list_worlds`, `emerge_area`,
`job_status`, `build_history` — plus `geometry.py` and a job-history endpoint.
Notes:

- **`emerge_area` takes centre and radius**, not min/max. It mirrors
  `/lb_emerge`, and it is what a person actually says: "the area around
  -5900, 10, -5450". The tool converts to mapblock-aligned bounds.
- **`geometry.py` mirrors `plan.lua`.** Both sides need mapblock arithmetic —
  the mod to size work, the service to refuse an oversized job at submission
  instead of letting it fail two seconds later in-world. The duplication is
  pinned by a test asserting the Python matches values *measured from the Lua*,
  so the two cannot drift silently.
- **Tool docstrings are load-bearing.** They are the only thing the model reads
  before choosing what to call, so each states what the tool does to the world
  and what it costs — including that emerge writes terrain permanently and that
  cost grows cubically.
- **Errors are returned, not raised.** An unreachable service comes back as a
  readable hint naming the command to start it, because the agent has to act on
  it rather than see a stack trace.

**Done when** you say "emerge the area around -5900, 10, -5450" to Claude, the
mapblocks generate, and the job row in SQLite reads `completed` with a sensible
duration. — *Met, and then some: two full sweeps of Marduk1 at ±15000, 900 jobs
per layer, 3.5M mapblocks each. That scale is also where the gaps showed --
`interrupted` rows needing a repair pass, and generation cost tracking mapgen
chunks rather than mapblocks.*

### ✅ M2 — `fill_box`, the first mutation — DONE

1. `apply.lua`: `fill_box(data, area, min, max, content_id)` over a flat array.
   *Heavily unit tested* — this is where index arithmetic bugs live. Cover
   single-node boxes, boxes clipped to the area edge, and boxes entirely outside.
2. `palette.lua`: names → content ids through an injected `resolve` function
   (`core.get_content_id`, supplied by `init.lua`), failing the job on any
   unregistered name. Reject `ignore` and deny-list entries explicitly. Unit
   tested with a table-backed fake resolver.
3. `validate.lua`: the seven rules above, with a spec per rule.
4. `world.lua`: emerge → `vm:get_data` → apply → `vm:set_data` → `vm:write_to_map`.
   No lighting call. No liquid update.
5. Extend the job format and the service to carry `palette` and `ops`.

**Done when** a single job builds a 20×5×20 stone slab in the scratch world,
you can see it in-game, and re-running the identical job changes nothing. —
*Slab built (job 1807, 2000 nodes) and visible. The idempotency re-run was never
performed: the milestone was carried by the motorway build that followed, which
exercised `fill_box` far harder. Worth closing properly when M6 lands, since a
snapshot makes "changed nothing" checkable rather than merely plausible.*

**What building with it taught us**, none of which the plan anticipated:
`param2` is not optional -- without it every oriented node comes out wearing
whatever the old node was facing, which is why it arrived mid-milestone. And a
cross-section read from the world is authoritative about form but silent about
repetition: replaying one column along a road gave a solid lane marking where a
dashed one belonged, and copied 43 nodes of terrain that were never part of the
design.

### ✅ M3 — `fill_box_if` — DONE

Conditional replacement against a match set: explicit node names plus the two
groups that matter, `liquid` and `falling_node`. Resolve groups to a content-id
set once at job start, so the inner loop is a set lookup.

Plus an `invert` flag on the match. Two shapes of work need opposite predicates
and they are otherwise the same op:

- **Pillars and bridge supports** — `match: [air, group:liquid]`. Fill the empty
  space, leave everything solid alone.
- **Shafts** — the same match, inverted. Carve what is *not* air, which drives a
  vertical shaft up through ground until the ground runs out.

**Done when** a tunnel shell built with
`fill_box_if(air|liquid|falling_node → stone)` leaves existing stone untouched,
and a pillar dropped from y=40 stops at the ground without Python knowing the
terrain height. — *Met. Bridge pillars wrote zero blocks where the ground was
already at deck level and four where there was a gap, with nothing on either
side measuring the terrain.*

*The limitation below was not theoretical for long.* A stone lens sitting one
node under a beam is indistinguishable, to a node-local predicate, from the
bedrock beneath it -- the difference is how far down it is, a property of the
column. That one was settled by reading the column here and sending explicit
boxes, which is exactly the survey-plus-boxes path this section describes.

#### What `fill_box_if` deliberately does not do

A run of conditional fill often wants to *finish* with something: a footing
where the pillar reaches rock, a grating where the shaft breaks the surface.
That needs a distinction this op cannot make — between the predicate being false
on the first cell, and being false after some cells were already filled. The
second is a property of the run, not of the cell, so evaluating it means reading
back along the direction of travel.

That is a neighbour-reading op, the third of the three things listed under
"Ordering and work units" that break unit decomposition, and the reason a
marching variant is not in M3. A ray crossing a mapblock boundary would restart
in each unit and terminate in the wrong place.

The intended answer is the one M7 already describes: `survey` (M5) reads the
column, Python computes where the run ends, and the job carries explicit boxes
including the cap. The mod stays node-local; the arithmetic lives where it can
see the whole ray. Periodic placement — shafts every N blocks, alternating
sides — belongs in the same layer for the same reason.

Reconsider a marching op only if that round trip proves too expensive in
practice, and revise "Ordering and work units" first rather than after. One
capability is genuinely lost until then: stopping at the *first* cell where the
predicate flips, as opposed to treating every cell in the box independently.

### ✅ M4 — Work units and progress — DONE

1. `plan.lua` (pure): partition `bounds` into disjoint mapblock-aligned units,
   and for a given unit return the ops clipped to it, in original order — the
   algorithm in "Ordering and work units" above. One unit per emerge/VM cycle.
2. Progress reports, which also renew `heartbeat_at`.
3. The recovery protocol, minus retry: persist the current job id in
   `core.get_mod_storage()` and report `abandoned` on startup. `interrupted` is
   terminal at this milestone; `retry` arrives with snapshots in M6.

*Test first, and this is the test that matters:* a contract fixture with a shell
op and a carve op that both **straddle a unit boundary**, asserting that
unit-major execution produces the same world as the op-major reference
semantics. Write the reference implementation — it's a dozen lines — and compare
against it, rather than hand-writing the expected world. The failure this
catches is walking the op list out of order within a unit, which only shows at
unit seams.

Since nobody else is on this server, size units for memory and emerge throughput,
not for latency — start around 5×5×5 mapblocks (80³ nodes) and measure. Add a
configurable per-step budget only if you find yourself wanting to watch it build.

**Done when** a 400-node-long job completes across many server steps, progress
rows advance in SQLite, and `kill -9` on the server mid-job leaves an
`interrupted` row naming the right job, with the mod cleanly picking up new work
on restart rather than trying to continue. — *All met. A 400-node job ran as 5
units in 2.1s with `units_done` advancing 0 → 2 → 4; `kill -9` at 5/20 of a
1600-node job left the row `running` with a frozen heartbeat, and the mod
reported it 48 seconds later on restart.*

*The row reads `abandoned`, not `interrupted`, and the distinction is the whole
point of step 2: the service never had to infer anything from silence. It would
have said `interrupted` only if the restart had taken longer than `STALE_AFTER`.
The wording above predates the `abandoned` state.*

**One defect this found.** A completed job read `4/5`, because the completion
report deliberately outranks queued progress and so overtakes the last unit's.
`mark_completed` now sets `units_done = units_total`; a finished job that looks
stranded is worse than no counter at all.

### ✅ M5 — `survey` — DONE

A read-only job returning, per column in a region, the surface height and the
first solid node — enough for Python to plan tunnels, bridges and pillar depths.
Downsample on the Lua side; a 4×1000 road strip is a few thousand columns.

**Done when** Python can fetch a profile along a route and print where it would
need to tunnel. — *Met. A 750-node profile east of the motorway, sampled every
eighth column, printed 72 columns wanting a bridge and 18 wanting a tunnel, with
the ground falling to y-9 across a bay and rising to y29 into a ridge.*

**The surface is the first walkable node, not the first node**, and that is the
whole design rather than a detail. Snow, tall grass, and a trapdoor set into a
ceiling all occupy a cell without being ground. The proof came free in the first
real profile: over water the survey reported `seagrass_sand` on the seabed,
because water is not walkable — the naive reading would have run the deck along
the surface of the bay.

Two things the shape of the answer forced:

- **Scan top down.** A column over a cave has solid ground both above and below
  the void, and only the upper one can be built on.
- **Anchor the sample grid to the caller's box**, carried through
  `plan.clip_ops` as `anchor`. Anchoring to the clipped corner shifts the grid
  between work units, duplicating columns on one side of a seam and dropping
  them on the other; anchoring to absolute zero means a profile along a single
  line at an odd coordinate samples nothing at all. Both were found by trying to
  use it.

`world.build` now has three cases rather than two: no VoxelManip, read it, or
read and write it. A survey must never be written back -- doing so would mark
every mapblock in the region modified for a job that changed nothing.

### M6 — Snapshot and undo

Between reading a unit's region and writing it back, serialise that unit's
`data` **and `param2`** arrays to `snapshots/{job_id}/{unit_index}.bin`. One
file per unit, not one per job — a job has many units and they must not
overwrite each other. Restore replays the present files in reverse index order.

#### Content ids are not durable — the file must be self-describing

Content ids are runtime identifiers assigned at registration time and depend on
the mod set and registration order. They are **not** stable across a server
restart, and recovery spans restarts by definition, so a snapshot storing raw
`data` ids can silently restore the wrong nodes after any mod change.

So the file carries its own id→name table, and ids are rewritten to be
file-local:

```text
header:  format version
         name table: ["air", "mcl_core:stone", "mcl_core:dirt", …]
body:    data   — indices into that table, one per node
         param2 — raw bytes, unchanged
```

On write, scan the unit for its distinct content ids, emit the name table, and
store local indices. On restore, resolve each name through `core.get_content_id`
against the *current* registry and build a remap array, then translate the body.

Luanti embeds LuaJIT, which is Lua 5.1 and has **no `string.pack`** — that
arrived in 5.3. The packing is therefore by hand and big-endian, and bytes are
emitted in bounded chunks joined once at the end: `string.char` and `unpack`
both take a limited number of arguments, and appending a byte at a time to a
string would be quadratic over half a million nodes.

Two things fall out of this. It is also the compression fix: a unit of natural
terrain holds a few dozen distinct nodes, so local indices fit in one byte where
raw ids need two — record the index width in the header and pick it at write
time. And **if any recorded name is no longer registered, fail the restore job**
with `unknown_node` and the list of missing names. Never substitute air; a
half-correct restore is worse than a refused one, because you would not notice.

`param2` needs no remapping — it is per-node raw data. It is only meaningful
against the node definition it was written for, which the name check already
guards.

#### Built so far

`src/snapshot.lua` and its spec: the format above, encode and decode, with the
header readable on its own so `undo` can check every name is still registered
before it starts changing the world. Measured at 0.01s to encode a full 5×5×5
unit — 512,000 nodes, 1 MB at two bytes each.

Six of its tests encode under one registry and decode under a different one,
which is the case a format storing raw ids would get wrong silently. Still to
build: the per-unit rule and commit protocol below, the `undo` and `retry`
endpoints, and the element-wise oracle.

#### The snapshot rule

**A unit's snapshot file is written at most once, ever, and never overwritten.**
Note *unit*, not directory — that distinction is the whole rule:

- Reaching a unit that already has a snapshot file: skip snapshotting, apply
  normally. The existing file describes pre-job state and must be preserved.
- Reaching a unit with no snapshot file: snapshot it, even mid-retry.

The second case is what a directory-level rule gets wrong. An attempt that died
after unit 3 leaves units 4…n unsnapshotted; if the retry suppressed snapshotting
wholesale, it would modify those units with no record of their original state and
`undo` could never restore them. Per-unit, the two attempts between them cover
every unit either one touched.

#### Commit protocol

Ordering is read → snapshot → apply → write, and the snapshot step must be
atomic against a `kill -9`. Without atomicity a truncated file looks committed,
so a retry skips that unit and a later `undo` restores garbage over it. Per unit:

1. Write to `{unit_index}.bin.tmp`, flush, close.
2. Atomically rename to `{unit_index}.bin`.
3. Only then `vm:write_to_map()`.

Luanti's `core.safe_file_write` is write-temp-then-rename internally, so steps 1
and 2 should come free — confirm that before relying on it. Ignore and clean up
stray `.tmp` files on startup; they are by definition uncommitted.

**Derive the manifest from the directory, don't maintain one.** The committed set
is exactly the `.bin` files present, and unit bounds are recomputable by re-running
`plan.lua`'s partitioner, which is pure and deterministic. That removes the
second atomicity problem — a manifest update racing the snapshot write — because
there is no per-unit manifest update to make. Write `manifest.json` **once at job
start**, recording `bounds`, unit size, and partitioner version, so bounds stay
reconstructible even if `plan.lua` changes later. It is a header, not a log.

With that, the crash cases are: killed between snapshot and write — the file
describes an unmodified region, restoring it is a harmless no-op; killed after
the write — the file is exactly the pre-write state; killed mid-`.tmp` — no
commit, and no world change either. Every region any attempt modified has a
snapshot.

`param2` is not optional: it carries facedir and wallmounted rotation, and plant
and leaf variants. Content ids alone lose all of it. `param1` is deliberately
skipped — it is lighting, which we do not maintain during builds anyway, so a
restored `param1` would be no more correct than a recomputed one.

**What undo does not restore:** node metadata, inventories, and node timers.
Scanning a large region for metadata is expensive and raw terrain has none. So
the promise is *"restores node type and orientation"*, not "byte-identical". If
you build over an existing structure containing chests or machines, undo returns
the nodes and loses their contents. For a solo authoring tool that is a fine
trade — but it is a convenience, not a transactional guarantee, and the docs and
the MCP tool description should both say so.

`POST /v1/jobs/{id}/undo` enqueues a restore job. `POST /v1/jobs/{id}/retry`
becomes available here too, defined as restore-then-re-run per "Recovery, by
milestone". Snapshot directories are referenced by path from the job row, so
pruning is `rm -r`.

#### The oracle for these tests

`survey` is the wrong instrument here: it reports per-column surface height and
first solid node, so it cannot see `param2` at all, nor anything inside a sealed
chamber. Undo's whole promise is node type **and orientation**, and survey
observes neither directly.

So the integration test mod reads the region itself with VoxelManip and compares
`data` and `param2` element-wise, before the build and after the undo. Compare
`data` by **node name**, not by content id — map through
`core.get_name_from_content_id` before hashing. The kill-and-restart cases cross
a server restart, which is precisely when ids are allowed to move; a test that
compares raw ids would pass for the wrong reason and would miss the bug the name
table exists to prevent.

**Done when** all of these hold, each asserted with that comparison:

- you build a chamber over sloped terrain containing deliberately rotated nodes
  (facedir stairs, wallmounted torches), undo it, and the region matches
  element-wise on both `data` and `param2`;
- a `kill -9` partway through a **multi-unit** job, followed by `retry`, produces
  the same region as an uninterrupted run;
- `undo` after that retry restores the **whole** bounds — including the units the
  first attempt never reached, which is the case the per-unit rule exists for;
- killing the server repeatedly at random points and retrying each time still
  ends with a correct `undo`. This is the one worth automating: a loop that kills
  at a random tick, retries, and finally undoes, asserting against the pre-build
  region capture.

### M7 — Geometry compiler and intent tools

Now the Python side earns its keep: `road`, `corridor`, `chamber`, `shaft`,
`stairs` → ordered box lists, using survey data to decide tunnel spans and pillar
depths. Property-based tests as described above. MCP tools at this level are what
you'll actually talk to.

Also where the collision warning lands — see "Build collisions". This is the
first milestone where jobs are generated rather than hand-written, and so the
first where overwriting an earlier build is likely to be an accident rather than
a decision.

**Done when** "build a road from A to B" produces a road that tunnels through
hills and bridges valleys without you specifying either.

### M8 — Lighting repair

`fix_light(p1, p2)` as its own job type, run on demand over regions that touched
daylight. Never inline in a build.

**Done when** a surface road section renders with correct shadow after an
explicit repair job, and builds are no slower than before.

## Deliberately deferred

Parallel jobs. Protection checks. Cancellation. Fine-grained checkpointing.
Postgres. A semantic room/complex model. `place_schematic`. Anything that isn't
a box.

## To verify before relying on it

**Resolved in M0** (see `tests/integration/README.md`):

- ✅ The custom macOS build supports `--server`. Map backends: `dummy`,
  `postgresql`, `sqlite3`.
- ✅ `core.safe_file_write` and `core.get_dir_list` work from a **non-trusted**
  mod, writing into the world path. M6 snapshots can be written by the mod
  directly; they do not need to be shipped over HTTP to Python.
- ⚠️ Homebrew's `lua` is 5.5, which is not what Luanti runs. The Lua toolchain is
  installed against **LuaJIT (5.1)** into a project-local `.luarocks/` tree, so
  unit tests exercise the same semantics as the engine. See
  `scripts/lua-env.sh`.

**Still open:**

- Whether Mapserver's renderer ignores light values, which decides how much M8
  matters.
- `VoxelManip:calc_lighting`'s `propagate_shadow` argument and the deprecation
  status of the `write_to_map(light)` parameter in 5.16 — check the bundled
  `lua_api.md`, not older Minetest documentation.
- Whether `core.get_dir_list` and `core.safe_file_write` are usable for snapshot
  storage from a non-trusted mod, or whether snapshots need to go back over HTTP
  to Python. If the latter, M6 gets bigger; plan for it.
- Whether `core.safe_file_write` really is write-temp-then-atomic-rename, since
  M6's commit protocol leans on it. If it isn't, do the temp-and-rename by hand
  with `os.rename`, which is atomic within a filesystem.
- Snapshot volume before committing to M6's storage model. With byte-wide local
  indices, `data` plus `param2` is 2 bytes per node, so an 80³ unit is ~1 MB and
  a large complex still runs to gigabytes. Measure with a real job and decide on
  compression and a retention limit (last N jobs) before building it.
