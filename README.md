# luantibot

A bot to build worlds in Luanti faster and simpler.

Build large structures in a running [Luanti](https://www.luanti.org/) world from
outside the game — from a script, or from an AI agent — without controlling a
player or writing to the map database.

Built as a GM tool for mapping a tabletop Traveller setting: the world is a place
to walk around in and describe, and the structures in it are authored rather than
played into existence.

```text
        AI agent / scripts
                 │  submit jobs
                 ▼
        Builder service  (Python, SQLite, localhost)
                 ▲
                 │  outbound HTTP polling
        Luanti server-side mod  (Lua)
                 │  emerge_area, VoxelManip
                 ▼
           Luanti world
```

## The idea

All map mutation has to happen inside the Luanti server, on its main thread, in
Lua. There is no external world API. That forces a split:

- **Python decides what and where.** Geometry, terrain reasoning, job history —
  everything that requires thinking.
- **Lua decides how to apply it, safely.** It receives ordered volumetric
  primitives (fill this box; fill this box where the node matches) and applies
  them. No geometry, no planning.

The mod is the HTTP *client*: Luanti cannot run a server, so it polls for work
and posts results back. Nothing needs to reach into the game.

Keeping geometry in Python is what makes the loop fast — changing Python is a
process restart, changing Lua is a server restart — and it keeps the piece that
can damage a world small enough to reason about.

## Status

Early. The pipeline works end to end, for one operation.

| Milestone | Delivers | Status |
| --- | --- | --- |
| M0 | Toolchain, test harnesses, disposable integration world | ✅ done |
| M1 | Emerge end to end: mod ↔ service ↔ SQLite, world identity, job lifecycle, MCP tools | ✅ done |
| M2 | `fill_box` — the first operation that writes a node | planned |
| M3 | `fill_box_if` — conditional fill, for tunnel shells and pillars | planned |
| M4 | Work units, progress, crash recovery | planned |
| M5 | `survey` — read terrain back, so Python can plan | planned |
| M6 | Snapshot and undo | planned |
| M7 | Geometry compiler: roads, corridors, chambers, shafts | planned |
| M8 | Lighting repair | planned |

Today you can emerge mapblocks — by chat command, by submitting a job over HTTP,
or by asking an AI agent through the MCP tools. **Nothing writes nodes yet**;
that is M2.

## Getting started

See **[INSTALL.md](INSTALL.md)**. The short version: symlink the mod into a
world's `worldmods`, restart, and

```text
/lb_emerge -5900 10 -5450 32
```

That is 125 mapblocks, about 8 seconds. Cost grows cubically — see
[INSTALL.md](INSTALL.md) for the radius table before reaching for a big number.

The mod is fail-closed — it does nothing at all until you name the world it may
act in, so installing it is safe.

## Safety

Two properties matter, because the point of this tool is to change a world you
care about.

**One world, deliberately named.** The mod refuses to act unless configured for
the world it finds itself in. The service issues each world a durable id, cached
in that world's mod storage, and never offers a job to a world it was not
compiled for — cross-world execution is structurally impossible rather than
something the mod has to catch in time.

**Build history is world-scoped and permanent.** Which world a structure was
built in survives renaming the world, renaming it in the service, and copying it
(see the notes on copied worlds in [INSTALL.md](INSTALL.md)).

Undo arrives in M6. Until then, emerging generates new mapblocks permanently — it
will not alter existing terrain, but it is not reversible either.

## Layout

```text
src/luantibot/       Python: wire models, service, SQLite store
mods/luantibot/      Lua mod
  src/               pure modules (unit tested) + adapters (integration tested)
  spec/              busted tests
scripts/             busted, luacheck, integration harness
tests/               Python unit + API tests, integration harness
docs/                design and build order
```

The Lua mod holds a hard rule: a module either never touches the engine and is
unit tested, or it touches the engine and carries no logic. That split is what
makes any of the Lua testable at all — see
[docs/implementation_plan.md](docs/implementation_plan.md).

## Documentation

- **[INSTALL.md](INSTALL.md)** — setup, configuration, usage, troubleshooting
- **[docs/implementation_plan.md](docs/implementation_plan.md)** — design
  decisions, wire contract, recovery model, milestone-by-milestone build order
- **[docs/suggestion_claude.md](docs/suggestion_claude.md)** and
  **[docs/suggestion_chatgpt.md](docs/suggestion_chatgpt.md)** — the original
  design proposals this was built from
- **[tests/integration/README.md](tests/integration/README.md)** — the
  end-to-end harness
