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
   a throwaway file and never touches PostgreSQL or `Marduk1`.
3. Writes a `map_meta.txt` selecting the **flat** mapgen — deterministic, so
   region comparisons in M2 and M6 mean something, and fast to emerge.
4. Symlinks `mods/luantibot` and `tests/integration/mods/luantibot_test` into the
   world's `worldmods/`.
5. Boots `luanti --server` on port 30001.
6. The test mod asserts, writes `result.json`, and calls
   `core.request_shutdown()`. A process still alive at `TIMEOUT` means it hung.

## Environment

| Variable  | Default                                                            |
|-----------|--------------------------------------------------------------------|
| `LUANTI`  | `~/work/luanti/build-postgresql/macos/luanti.app/Contents/MacOS/luanti` |
| `GAMEID`  | `mineclonia`                                                       |
| `TIMEOUT` | `60` seconds                                                       |

## Confirmed against this build (Luanti 5.16.1)

Resolved from the plan's "To verify before relying on it" list:

- `--server` is supported by the macOS bundle. No separate server target needed.
- Map backends available: `dummy`, `postgresql`, `sqlite3`.
- `core.safe_file_write` and `core.get_dir_list` **do** work from a non-trusted
  mod (not in `secure.trusted_mods`), writing into the world path. M6 snapshots
  can therefore be written directly by the mod rather than shipped over HTTP to
  Python. Whether `safe_file_write` is internally atomic (temp-then-rename) is
  still open and matters for M6's commit protocol.
