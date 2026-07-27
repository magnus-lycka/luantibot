# Integration harness

Boots a real headless Luanti server on a disposable world, runs the assertions in
`mods/luantibot_test/init.lua`, and exits non-zero on failure.

```sh
./scripts/integration
```

This is the only layer that exercises the adapters (`world.lua`, `snapshot.lua`,
`init.lua`) and the real `emerge_area` / VoxelManip. Pure modules are covered far
more cheaply by `./scripts/busted`. Run this per milestone, not per save.

## What it does

1. Deletes and recreates `tests/integration/run/` (gitignored).
2. Writes a `world.mt` using the **sqlite3** map backend, so the scratch world is
   a throwaway file and never touches PostgreSQL or any world you care about.
3. Copies `test.conf` and appends `mg_name` / `fixed_map_seed`, letting the
   engine create the world.
4. Symlinks `mods/luantibot` and `tests/integration/mods/luantibot_test` into the
   world's `worldmods/`.
5. Boots `luanti --server` on port 30001.
6. The test mod asserts, writes `result.json`, and calls
   `core.request_shutdown()`. A process still alive at `TIMEOUT` means it hung.

## Environment

Machine-specific values belong in `scripts/local.env`, which is gitignored and
sourced automatically. Copy `scripts/local.env.example` to start. Anything there
can also be given on the command line: `MAPGEN=v5 ./scripts/integration`.

- `LUANTI` — path to the server binary. Defaults to `luantiserver` or `luanti`
  from `PATH`; set it if you run a self-built binary or a macOS app bundle.
- `GAMEID` — defaults to `mineclonia`.
- `MAPGEN` — defaults to `v7`. See below.
- `SEED` — defaults to `1`.
- `TIMEOUT` — seconds before the run is treated as hung. Defaults to `120`.

## Mapgen and world creation

Two traps, both hit during M1.1:

- **Do not hand-write `map_meta.txt`.** A world created that way has no mapgen
  noise parameters, and mineclonia reads them back during generation — it dies
  on `tonumber(nil)` in `mcl_mapgen_models`, which surfaces as every mapblock
  emerging as `EMERGE_ERRORED`/`CANCELLED`. Set the mapgen in the config and let
  the engine write a complete `map_meta.txt` when it creates the world.
- **Set the mapgen and seed to match the world you build in.** Put `MAPGEN` and
  `SEED` in `scripts/local.env` and the scratch terrain becomes representative of
  what the builder will actually meet — real hills to tunnel through in M3 and
  M5 — rather than something the code only works against by accident.

  Either way the seed is fixed, so terrain is reproducible run to run. That
  repeatability is what M2 and M6 region comparisons rest on. The harness probes
  one node and logs it on every run, so a regression in it is visible rather
  than silent.

  Do not substitute the other mapgens: `flat` crashes mineclonia's levelgen and
  `singlenode` hangs it during stronghold placement.

## Confirmed against this build (Luanti 5.16.1)

Resolved from the plan's "To verify before relying on it" list:

- `--server` is supported by the macOS bundle. No separate server target needed.
- Map backends available: `dummy`, `postgresql`, `sqlite3`.
- `core.safe_file_write` and `core.get_dir_list` **do** work from a non-trusted
  mod (not in `secure.trusted_mods`), writing into the world path. M6 snapshots
  can therefore be written directly by the mod rather than shipped over HTTP to
  Python. Whether `safe_file_write` is internally atomic (temp-then-rename) is
  still open and matters for M6's commit protocol.
