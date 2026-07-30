# Installing and running luantibot

Two things get installed: a **Lua mod** inside your Luanti world, and a **Python
service** that hands it work. The mod alone is enough to use `/lb_emerge`; the
service is only needed for jobs submitted from outside Luanti.

Paths below are macOS. On Linux the Luanti data directory is `~/.minetest` or
`~/.luanti` instead of `~/Library/Application Support/minetest`.

---

## 1. Install the mod into a world

Symlink it into the world's `worldmods` directory, so it exists for that world
and no other:

```sh
WORLD=~/Library/Application\ Support/minetest/worlds/MyWorld

mkdir -p "$WORLD/worldmods"
ln -s /path/to/luantibot/mods/luantibot "$WORLD/worldmods/luantibot"
```

Mods in `worldmods` are normally enabled automatically. If the log does not show
`[luantibot] loaded`, add this to `$WORLD/world.mt`:

```ini
load_mod_luantibot = true
```

A symlink means `git pull` updates the mod; you only need to restart the server.

## 2. Arm it

There is nothing to configure to arm the mod. Symlinking it into a world's
`worldmods` is the opt-in: that world registers itself on startup and polls for
its own jobs, and several worlds can run at once, each with its own id.

What keeps a world from executing work meant for another is not configuration.
The service only ever offers a world its own jobs, and the mod compares
`world_id` before touching a node.

Start the server and check the log. Without the service configured you will see:

```text
ACTION[Main]:  [luantibot] loaded, wire format 1
WARNING[Main]: [luantibot] no HTTP API; /lb_emerge works but job polling is off.
```

That warning is expected and harmless at this stage — `/lb_emerge` is a local
operation and works without the service.

The line after it reports which world you are in and the id the service gave it:

```text
ACTION[Main]:  [luantibot] world_id=3 "MyWorld" (dir: MyWorld)
```

## 3. Optionally: the builder service

Only required for jobs submitted from outside Luanti. Add to `minetest.conf`:

```ini
secure.http_mods = luantibot
```

Luanti will not give a mod outbound HTTP without this, and the handle can only
be acquired at load time — so this needs a server restart, not a `/reload`.

Then run the service:

```sh
cd /path/to/luantibot
uv run python -m luantibot.service --db luantibot.sqlite
```

It binds to `127.0.0.1:8099` and nothing else. Nothing about this API is safe to
expose; there is no authentication because it is not reachable off the machine.

**Port 8099, not 8080** — Mapserver listens on 8080, and if you are running it
against the same world the two would collide. Override with `--port` and
`luantibot_service_url` if 8099 is taken too.

Restart Luanti. The warning about the HTTP API is gone, and on its first poll
the mod registers itself and logs its identity:

```text
ACTION[Main]:   [luantibot] loaded, wire format 1
ACTION[Main]:   [luantibot] unregistered (dir: MyWorld)
ACTION[Server]: [luantibot] world_id=1 "MyWorld" (dir: MyWorld)
```

The third line is the handshake completing. From then on the id is cached in the
world and that line appears at every startup.

---

## Using it

### Chat commands

All require the `server` privilege.

| Command | Purpose |
| --- | --- |
| `/lb_emerge <x> <y> <z> <radius>` | Load or generate mapblocks around a point |
| `/lb_world` | Show this server's world identity |
| `/lb_world_bind <name>` | Re-register under `<name>` and adopt the new id |
| `/lb_world_forget` | Drop the cached id; re-register on the next poll |

`/lb_emerge` works with or without the service. The `/lb_world*` commands only
exist when the service is configured.

`radius` is in **nodes** and describes a cube, which is then expanded out to
whole 16-node mapblocks. Cost therefore grows cubically, and faster than it
looks — a radius of 64 is not twice the work of 32, it is nearly six times:

| radius | mapblocks | rough time | |
| --- | --- | --- | --- |
| 8 | 8 | ~1 s | |
| 16 | 27 | ~2 s | |
| 32 | 125 | ~8 s | |
| 48 | 343 | ~22 s | |
| 64 | 729 | ~47 s | |
| 96 | 2197 | ~2.3 min | |
| 112 | 3375 | ~3.6 min | |
| 128 | 4913 | — | **refused**, over the 4096 cap |

So **~112 is the largest usable radius** at the default
`luantibot_max_emerge_blocks`. Times assume roughly 64 ms per mapblock, measured
on a mineclonia world; your mapgen, terrain and hardware will all shift it.

Emerging runs on its own threads, so the server keeps responding, but it is
CPU-heavy while it works.

### Jobs over HTTP

```sh
curl -X POST localhost:8099/v1/jobs -H 'Content-Type: application/json' \
  -d '{"format":1,"world":"MyWorld",
       "bounds":{"min":[-5960,0,-5510],"max":[-5897,63,-5447]},
       "ops":[{"op":"emerge"}]}'
```

Then watch it: `curl localhost:8099/v1/jobs/1`.

The mod polls every couple of seconds when idle, picks the job up, executes it,
and reports back. Endpoints:

- `POST /v1/jobs` — submit; names a world, which is registered on demand
- `GET /v1/jobs/{id}` — inspect a job
- `GET /v1/worlds` — list known worlds
- `POST /v1/worlds` — register or adopt a world by name
- `GET /v1/health`

The rest (`jobs/next`, `started`, `progress`, `completed`, `failed`) are the
mod's side of the conversation and are not meant to be called by hand.

### From an AI agent (MCP)

The MCP server exposes the builder as tools. It talks to the builder service
over HTTP, so **the service must be running** for any of them to work.

Register it with Claude Code:

```sh
claude mcp add luantibot -- uv run --directory /path/to/luantibot \
    python -m luantibot.mcp_server
```

Or add it to a client's MCP config directly:

```json
{
  "mcpServers": {
    "luantibot": {
      "command": "uv",
      "args": ["run", "--directory", "/path/to/luantibot",
               "python", "-m", "luantibot.mcp_server"],
      "env": { "LUANTIBOT_SERVICE_URL": "http://127.0.0.1:8099" }
    }
  }
}
```

Four tools:

| Tool | Does |
| --- | --- |
| `list_worlds` | Which worlds the service knows about |
| `emerge_area(world, x, y, z, radius)` | Queue an emerge job; returns a job id |
| `job_status(job_id)` | State, timings and result of a job |
| `build_history(world, limit)` | What has been built in a world, newest first |

Then ask in plain language — *"emerge the area around -5900, 10, -5450 in
MyWorld"*. Jobs are asynchronous: the tool returns a job id straight away and
the agent can follow up with `job_status`.

An oversized radius is refused at the tool, before anything is queued, so the
agent gets told immediately rather than watching a job fail in-world.

---

## What this does to your world

**Emerging writes.** It generates mapblocks that do not exist yet and persists
them to your map database, permanently. Mapserver will render them. It does not
alter existing terrain — but "read-only" is the wrong mental model, and a large
`/lb_emerge` in an unexplored region is not undoable.

Nothing yet writes *nodes*. Until M2 lands, the mod can only load and generate.

---

## Configuration reference

All in `minetest.conf`.

| Setting | Default | Meaning |
| --- | --- | --- |
| `secure.http_mods` | *(none)* | Must include `luantibot` for job polling. |
| `luantibot_service_url` | `http://127.0.0.1:8099` | Where the builder service listens. |
| `luantibot_poll_interval` | `2` | Seconds between polls when idle. |
| `luantibot_max_emerge_blocks` | `4096` | Mapblock cap for `/lb_emerge`. |

Service flags: `--db` (default `luantibot.sqlite`), `--host` (`127.0.0.1`),
`--port` (`8099`).

---

## World identity, and copied worlds

The service issues each world a numeric id; the mod caches it in
`<world>/mod_storage.sqlite`. That binding is what keeps build history attached
to the right world, and it survives renaming the world *or* renaming it in the
service — neither name is the identity.

Because mod storage lives in the world directory, **copying a world copies its
identity**. `cp -r MyWorld MyWorld_v2` produces a second world claiming to be
world 1. To split them:

```text
/lb_world_bind MyWorld_v2
```

Run that in the copy. It registers under the new name, takes a new id, and the
two worlds have separate histories from then on.

Registration **adopts by name**: binding a copy under the original's name merges
their histories, silently. The name you pass is the decision.

---

## Troubleshooting

**The mod does nothing and logs nothing**
It is not loaded in this world. Check that `worldmods/luantibot` exists in the
world directory and points somewhere real.

**`[luantibot] no HTTP API`**
`secure.http_mods = luantibot` is missing. `/lb_emerge` still works; polling does
not. Requires a restart — the HTTP handle is only obtainable at mod load time.

**Mod does not appear at all**
Add `load_mod_luantibot = true` to the world's `world.mt`.

**`require() is disabled when mod security is on`**
A module is importing a sibling with `require`. Luanti forbids it; inject the
dependency instead. See "The constraint that makes Lua testable" in
[docs/implementation_plan.md](docs/implementation_plan.md).

**Every mapblock emerges as errored or cancelled**
Usually a broken mapgen configuration rather than anything in this mod — a world
whose `map_meta.txt` was written by hand lacks the noise parameters that games
like mineclonia read back. Let Luanti create worlds.

**Warning about the service name differing from the local directory**
Either the world was renamed (fine) or it is a copy that should be re-bound. The
mod warns and continues, because at that instant the two cases are
indistinguishable.

---

## Developing

Requires [uv](https://docs.astral.sh/uv/) and a Lua toolchain. Luanti embeds
**LuaJIT (Lua 5.1)**; Homebrew's `lua` is 5.5 and differs in ways that matter for
this code, so the tools are installed against LuaJIT into a project-local tree:

```sh
brew install luajit luarocks stylua
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" \
         --tree=.luarocks install busted
luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" \
         --tree=.luarocks install luacheck

uv sync
uv run pre-commit install --install-hooks
uv run pre-commit install --hook-type pre-push
```

| Command | Runs |
| --- | --- |
| `uv run pytest` | Python unit and API tests |
| `./scripts/busted` | Lua unit tests |
| `./scripts/luacheck` | Lua linter |
| `./scripts/integration` | Real Luanti server + real service, end to end |
| `uv run pre-commit run --all-files` | Everything else |

`./scripts/integration` builds a disposable world under `tests/integration/run/`
on the sqlite3 backend — it never touches your real worlds or PostgreSQL. It is
also the only layer that catches mod-loading problems, since a passing `busted`
run does not prove a module loads inside Luanti. Run it every milestone.

See [docs/implementation_plan.md](docs/implementation_plan.md) for the design and
the build order.
