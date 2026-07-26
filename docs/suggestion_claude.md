# Luanti Builder Bot — Design

An LLM-driven system to build structures (roads, tunnels, etc.) and emerge
blocks in a Luanti world, driven from Claude/ChatGPT rather than typed into
the Luanti client.

## Hard constraint

All map mutation — `core.emerge_area`, VoxelManip writes, `core.set_node` —
must run **inside the Luanti server, on the server main thread, in Lua**.
There is no external world API. This forces the split below: geometry and
planning live outside; only primitive application lives inside.

## Architecture

```
LLM (Claude/ChatGPT)
      │  tool call: build_road(a, b, material)
      ▼
Python service ── planner/geometry expands intent → node ops
      │  transport (see below)
      ▼
Luanti mod (dumb executor) ── emerge + VoxelManip apply
```

### Inside Luanti — a thin executor (Lua mod)

Keep it dumb: no geometry, no planning. It receives coordinate + node
payloads and applies them. Primitives:

- `emerge(p1, p2)` → `core.emerge_area` (async, callback-based).
- `set_region(p1, p2, node_ids)` → VoxelManip:
  `get_voxel_manip` → `read_from_map` → `set_data` → `write_to_map` →
  `calc_lighting`. This is the only viable path for bulk (roads/tunnels);
  a loop of `set_node` is far too slow.
- `get_node`, optionally `place_schematic`.

### Outside Luanti — Python

- **Planner / geometry library**: `build_road(a, b, material)`,
  `tunnel(a, b, radius)`, etc. expand into the coordinate+node payloads the
  mod consumes. All the real logic lives here.
- **LLM surface**: expose the planner as an **MCP server** so Claude/ChatGPT
  call tools at the intent level (`build_road`, `emerge`). A raw `set_region`
  tool covers freeform builds.
- **Durable state**: if wanted, Python owns Postgres. The mod never touches
  the DB.

## The sandbox reality (this decides transport)

Strict Luanti Lua can only make **outbound HTTP** (`core.request_http_api()`,
mod listed in `secure.http_mods`). Files, raw sockets, and native DB drivers
all require `core.request_insecure_environment()` + the mod in
`secure.trusted_mods`. On a self-hosted server that's grantable — but it means
files/sockets/postgres are just ergonomics choices, while HTTP is the only
option needing **no** trust escalation and **no** native libraries.

## Transport options

**HTTP poll — recommended default.**
Mod does `http.fetch` (~150 ms) against Python: "any pending ops?" → apply →
post results back. No trust escalation, no native libs, no on-disk
serialization, testable with curl. Costs: a long-running Python process and
poll latency — neither hurts a builder bot.

**Files / kanban (`todo` → `wip` → `done`/`failed`).**
Atomic `os.rename` between dirs = the maildir pattern: crash-resilient and
race-free if you always write-then-rename. Legit. Costs: needs insecure env,
and directory *listing* from Luanti Lua isn't clean (plain `io` can't
enumerate — wants LuaFileSystem, possibly not bundled, or an `io.popen("ls")`
hack). Sensible fallback if you'd rather not run a persistent Python process.

**Postgres as the mod's transport — avoid.**
The pain isn't the DB; it's loading a native driver (LuaSQL) into Luanti's
bundled Lua. Reframe: Postgres is Python's durable state, and Python exposes
HTTP to the mod. Keep the DB off the Lua side and the awkwardness disappears.

## Serialization

Independent of transport. JSON over the wire; both sides speak it (dkjson is
pure-Lua for the mod). Not an argument for a *Lua* web service — since all
geometry lives in Python, Python is the natural host for shared structures.

## Open decisions

1. **Trusted vs sandboxed mod** — HTTP poll (no trust) vs LuaSocket push or
   files (trusted). Determines transport code on both ends.
2. **Files vs HTTP** — hinges on whether directory listing works in the target
   Lua env (LuaFileSystem availability). To verify before choosing files.
3. **Python HTTP stack** — plain `http.server` / Flask vs FastAPI. FastAPI
   only earns its place if the typed/MCP tool surface is wanted there.
