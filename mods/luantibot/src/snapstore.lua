-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Where snapshots live, and the one rule that makes undo correct:
--
--     **A unit's snapshot file is written at most once, ever, and never
--     overwritten.**
--
-- Note *unit*, not job. An attempt that died after unit 3 leaves units 4..n
-- with no record of their original state; if a retry suppressed snapshotting
-- for the whole job because the directory already existed, it would modify
-- those units with nothing to restore them from and `undo` could never put them
-- back. Per unit, two attempts between them cover every unit either one
-- touched.
--
-- Filesystem access is injected. That keeps the rule testable against a table
-- standing in for a disk, including the cases that only happen when a process
-- dies between two syscalls.

--- @param deps table {
---   fs = { exists(path), read(path), write(path, data), list(dir), remove(path) },
---   snapshot = <src/snapshot.lua instance>,
---   json = { encode(t), decode(s) },
---   root = string }
return function(deps)
    local store = {}

    local MANIFEST = "manifest.json"

    function store.dir(job_id)
        return deps.root .. "/" .. tostring(job_id)
    end

    function store.path(job_id, unit_index)
        return store.dir(job_id) .. "/" .. tostring(unit_index) .. ".bin"
    end

    --- Has this unit already been snapshotted by any attempt?
    function store.has(job_id, unit_index)
        return deps.fs.exists(store.path(job_id, unit_index)) == true
    end

    --- Snapshot a unit unless it already has one.
    ---
    --- The read-back is not paranoia. Luanti's `safe_file_write` is *believed*
    --- to be write-temp-then-rename, but that is recorded in the plan as
    --- unverified, and the whole commit protocol rests on it: a truncated file
    --- that looks committed makes a retry skip the unit and a later `undo`
    --- restore garbage over live world. Reading the header back turns that from
    --- a filesystem promise into an observed fact, for the price of one read
    --- against work that is dominated by emerge anyway.
    ---
    --- @return string status "written", "present", or nil on failure
    --- @return string|nil code, string|nil message
    function store.capture(job_id, unit_index, buf, count)
        if store.has(job_id, unit_index) then
            return "present"
        end

        local blob, code, message = deps.snapshot.encode(buf, count)
        if not blob then
            return nil, code, message
        end

        local path = store.path(job_id, unit_index)
        if not deps.fs.write(path, blob) then
            return nil, "snapshot_failed", "could not write " .. path
        end

        local back = deps.fs.read(path)
        if back == nil then
            return nil, "snapshot_failed", "wrote " .. path .. " but could not read it back"
        end
        local header, hcode, hmessage = deps.snapshot.header(back)
        if not header then
            return nil, hcode, "snapshot at " .. path .. " did not survive the write: " .. hmessage
        end
        if header.count ~= count then
            return nil,
                "snapshot_failed",
                string.format(
                    "snapshot at %s holds %d nodes, expected %d",
                    path,
                    header.count,
                    count
                )
        end

        return "written"
    end

    --- Unit indices with a committed snapshot, newest work first.
    ---
    --- Descending because restore replays them in reverse: later units may have
    --- been written over earlier ones where boxes overlapped across a seam, and
    --- undoing in reverse order returns the region to the state before any of
    --- it happened.
    --- @return table array of numbers, descending
    function store.committed(job_id)
        local out = {}
        for _, entry in ipairs(deps.fs.list(store.dir(job_id)) or {}) do
            local n = entry:match("^(%d+)%.bin$")
            if n then
                out[#out + 1] = tonumber(n)
            end
        end
        table.sort(out, function(a, b)
            return a > b
        end)
        return out
    end

    --- @return table|nil buf { data, param2, count }
    function store.load(job_id, unit_index)
        local path = store.path(job_id, unit_index)
        local blob = deps.fs.read(path)
        if blob == nil then
            return nil, "snapshot_missing", "no snapshot at " .. path
        end
        return deps.snapshot.decode(blob)
    end

    --- Written once, at job start. A header, not a log.
    ---
    --- The committed set is the `.bin` files present, and unit bounds are
    --- recomputable by re-running the partitioner -- which is pure and
    --- deterministic. Recording bounds and the partitioner's version here keeps
    --- that reconstruction possible even if `plan.lua` changes later, without
    --- any per-unit bookkeeping that could race the snapshot write.
    function store.write_manifest(job_id, manifest)
        local path = store.dir(job_id) .. "/" .. MANIFEST
        if not deps.fs.write(path, deps.json.encode(manifest)) then
            return nil, "snapshot_failed", "could not write " .. path
        end
        return true
    end

    --- @return table|nil manifest
    function store.manifest(job_id)
        local raw = deps.fs.read(store.dir(job_id) .. "/" .. MANIFEST)
        if raw == nil then
            return nil, "snapshot_missing", "no manifest for job " .. tostring(job_id)
        end
        local ok = deps.json.decode(raw)
        if type(ok) ~= "table" then
            return nil, "bad_snapshot", "manifest for job " .. tostring(job_id) .. " is unreadable"
        end
        return ok
    end

    --- Remove uncommitted leftovers. A `.tmp` is by definition a write that
    --- never completed, so nothing is lost by deleting it -- and leaving it
    --- risks a later reader treating it as real.
    --- @return number removed
    function store.sweep_temp(job_id)
        local removed = 0
        for _, entry in ipairs(deps.fs.list(store.dir(job_id)) or {}) do
            if entry:match("%.tmp$") then
                deps.fs.remove(store.dir(job_id) .. "/" .. entry)
                removed = removed + 1
            end
        end
        return removed
    end

    return store
end
