-- Builder service storage. One writer process; see service/store.py.
--
-- AUTOINCREMENT is deliberate on both tables. Without it SQLite reuses the
-- highest rowid after a delete, and snapshot directories are keyed by job id
-- (M6) with pruning planned -- a reused id would silently attach an old
-- snapshot to a new job, surfacing only when an undo restores wrong terrain.

PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

-- Durable world identity. The Luanti world name and directory name are both
-- renameable, so neither can be the key; the mod caches this id in its
-- per-world mod storage. See "World identity" in docs/implementation_plan.md.
CREATE TABLE IF NOT EXISTS world (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS job (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    world_id      INTEGER NOT NULL REFERENCES world (id),
    state         TEXT    NOT NULL,
    request_json  TEXT    NOT NULL,

    -- Promoted out of request_json because "what did I build around here in
    -- this world" is the query the build history exists to answer, and
    -- coordinates repeat across worlds.
    bbox_min_x INTEGER NOT NULL,
    bbox_min_y INTEGER NOT NULL,
    bbox_min_z INTEGER NOT NULL,
    bbox_max_x INTEGER NOT NULL,
    bbox_max_y INTEGER NOT NULL,
    bbox_max_z INTEGER NOT NULL,

    created_at    TEXT NOT NULL,
    reserved_at   TEXT,
    started_at    TEXT,
    heartbeat_at  TEXT,
    finished_at   TEXT,

    units_done    INTEGER NOT NULL DEFAULT 0,
    units_total   INTEGER NOT NULL DEFAULT 0,

    result_json   TEXT,
    error_code    TEXT,
    error_message TEXT,
    snapshot_path TEXT
);

-- Reservation scans for the oldest queued job in one world.
CREATE INDEX IF NOT EXISTS job_world_state ON job (world_id, state, id);

-- History lookups by region. A range scan is ample at this scale.
CREATE INDEX IF NOT EXISTS job_world_bbox ON job (world_id, bbox_min_x, bbox_max_x);
