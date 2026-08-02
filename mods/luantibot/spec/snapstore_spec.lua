-- The write-once rule, and the crash cases it exists for.
--
-- A fake filesystem stands in for the disk, which is what makes the interesting
-- cases testable at all: a process dying between two syscalls, a file that
-- looks committed but is truncated, a retry arriving to find some units already
-- recorded and others not.

local factory = require("snapstore")
local snapshot_factory = require("snapshot")

local NODES = { "air", "mcl_core:stone", "mcl_core:dirt" }

local function registry()
    local by_id, by_name = {}, {}
    for i, name in ipairs(NODES) do
        by_id[i] = name
        by_name[name] = i
    end
    return by_id, by_name
end

--- A filesystem in a table. `fail_write` makes the next write fail; `corrupt`
--- truncates whatever is written next, standing in for a crash mid-write that
--- still left a file behind.
local function disk()
    local d = { files = {}, writes = 0, fail_write = false, corrupt = false }

    d.fs = {
        exists = function(path)
            return d.files[path] ~= nil
        end,
        read = function(path)
            return d.files[path]
        end,
        write = function(path, data)
            d.writes = d.writes + 1
            if d.fail_write then
                return false
            end
            d.files[path] = d.corrupt and data:sub(1, 6) or data
            return true
        end,
        list = function(dir)
            local out = {}
            for path in pairs(d.files) do
                local rest = path:match("^" .. dir:gsub("([^%w])", "%%%1") .. "/(.+)$")
                if rest and not rest:find("/") then
                    out[#out + 1] = rest
                end
            end
            table.sort(out)
            return out
        end,
        remove = function(path)
            d.files[path] = nil
            return true
        end,
    }
    return d
end

local function store(d)
    local by_id, by_name = registry()
    return factory({
        fs = d.fs,
        snapshot = snapshot_factory({
            name = function(id)
                return by_id[id]
            end,
            resolve = function(name)
                return by_name[name]
            end,
        }),
        json = {
            -- Enough for a manifest; the real one is core.write_json.
            encode = function(t)
                local parts = {}
                for k, v in pairs(t) do
                    parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
                end
                table.sort(parts)
                return table.concat(parts, ";")
            end,
            -- Returns nil on anything malformed, as core.parse_json does. A
            -- fake that threw instead would hide the store's own handling.
            decode = function(s)
                local t = {}
                for pair in s:gmatch("[^;]+") do
                    local k, v = pair:match("^(.-)=(.*)$")
                    if k == nil or k == "" then
                        return nil
                    end
                    t[k] = tonumber(v) or v
                end
                return t
            end,
        },
        root = "/world/snapshots",
    })
end

local function region(count, id, param2)
    local data, p2 = {}, {}
    for i = 1, count do
        data[i] = id or 2
        p2[i] = param2 or 7
    end
    return { data = data, param2 = p2 }
end

describe("snapstore.capture", function()
    local d, s
    before_each(function()
        d = disk()
        s = store(d)
    end)

    it("writes a snapshot for a unit that has none", function()
        assert.are.equal("written", s.capture(1, 0, region(10), 10))
        assert.is_true(d.fs.exists("/world/snapshots/1/0.bin"))
    end)

    -- The rule. The existing file describes pre-job state and must survive.
    it("never overwrites a unit that already has one", function()
        s.capture(1, 0, region(10, 2), 10)
        local first = d.files["/world/snapshots/1/0.bin"]

        assert.are.equal("present", s.capture(1, 0, region(10, 3), 10))
        assert.are.equal(first, d.files["/world/snapshots/1/0.bin"])
    end)

    it("does not even write when a snapshot is present", function()
        s.capture(1, 0, region(10), 10)
        local before = d.writes
        s.capture(1, 0, region(10), 10)
        assert.are.equal(before, d.writes)
    end)

    -- The case a directory-level rule gets wrong: an attempt that died after
    -- unit 1 leaves units 2 and 3 unrecorded, and the retry must record them.
    it("snapshots the units a dead attempt never reached", function()
        s.capture(1, 0, region(10), 10)
        s.capture(1, 1, region(10), 10) -- ...then the server died

        assert.are.equal("present", s.capture(1, 0, region(10), 10))
        assert.are.equal("present", s.capture(1, 1, region(10), 10))
        assert.are.equal("written", s.capture(1, 2, region(10), 10))
        assert.are.equal("written", s.capture(1, 3, region(10), 10))

        assert.are.same({ 3, 2, 1, 0 }, s.committed(1))
    end)

    it("keeps jobs apart", function()
        s.capture(1, 0, region(10), 10)
        assert.are.equal("written", s.capture(2, 0, region(10), 10))
        assert.are.same({ 0 }, s.committed(1))
        assert.are.same({ 0 }, s.committed(2))
    end)

    it("reports a write that failed outright", function()
        d.fail_write = true
        local status, code = s.capture(1, 0, region(10), 10)
        assert.is_nil(status)
        assert.are.equal("snapshot_failed", code)
    end)

    -- The one the read-back exists for. A truncated file that looked committed
    -- would make a retry skip the unit and a later undo restore garbage.
    it("refuses a snapshot that did not survive the write", function()
        d.corrupt = true
        local status, code, message = s.capture(1, 0, region(10), 10)
        assert.is_nil(status)
        assert.are.equal("bad_snapshot", code)
        assert.matches("did not survive", message)
    end)

    -- Encoding fails before anything reaches the disk, so nothing is left
    -- behind for a retry to mistake for a commit.
    it("reports a region it could not encode, without writing", function()
        local buf = { data = { 9999 }, param2 = { 0 } } -- id with no name
        local status, code = s.capture(1, 0, buf, 1)
        assert.is_nil(status)
        assert.are.equal("bad_snapshot", code)
        assert.are.equal(0, d.writes)
    end)

    -- A write that reports success but leaves nothing readable. Rarer than a
    -- truncation and worse: proceeding would modify the world with no record.
    it("refuses when the file cannot be read back at all", function()
        d.fs.write = function()
            return true
        end
        local status, code, message = s.capture(1, 0, region(10), 10)
        assert.is_nil(status)
        assert.are.equal("snapshot_failed", code)
        assert.matches("could not read it back", message)
    end)

    it("refuses a snapshot that came back the wrong size", function()
        local by_id = registry()
        local shortened = snapshot_factory({
            name = function(id)
                return by_id[id]
            end,
            resolve = function()
                return 1
            end,
        }).encode(region(5), 5)
        d.files["/world/snapshots/1/0.bin"] = nil
        d.fs.write = function(path)
            d.files[path] = shortened
            return true
        end

        local status, code, message = s.capture(1, 0, region(10), 10)
        assert.is_nil(status)
        assert.are.equal("snapshot_failed", code)
        assert.matches("holds 5 nodes, expected 10", message)
    end)
end)

describe("snapstore.committed", function()
    local d, s
    before_each(function()
        d = disk()
        s = store(d)
    end)

    it("is empty for a job that never ran", function()
        assert.are.same({}, s.committed(99))
    end)

    -- Reverse order: later units may have written over earlier ones where an
    -- op crossed a seam, so undoing backwards returns the region to the state
    -- before any of it happened.
    it("lists units newest first", function()
        for i = 0, 4 do
            s.capture(1, i, region(4), 4)
        end
        assert.are.same({ 4, 3, 2, 1, 0 }, s.committed(1))
    end)

    it("sorts numerically, not as text", function()
        for _, i in ipairs({ 2, 10, 1 }) do
            s.capture(1, i, region(4), 4)
        end
        assert.are.same({ 10, 2, 1 }, s.committed(1))
    end)

    it("ignores the manifest and anything else in the directory", function()
        s.capture(1, 0, region(4), 4)
        s.write_manifest(1, { bounds = "x" })
        d.files["/world/snapshots/1/0.bin.tmp"] = "junk"
        d.files["/world/snapshots/1/notes.txt"] = "junk"

        assert.are.same({ 0 }, s.committed(1))
    end)
end)

describe("snapstore.load", function()
    local d, s
    before_each(function()
        d = disk()
        s = store(d)
    end)

    it("returns the region that was captured", function()
        s.capture(1, 0, region(12, 2, 19), 12)
        local buf = s.load(1, 0)
        assert.are.equal(12, buf.count)
        assert.are.equal(2, buf.data[1])
        assert.are.equal(19, buf.param2[12])
    end)

    it("reports a unit that was never snapshotted", function()
        local buf, code = s.load(1, 7)
        assert.is_nil(buf)
        assert.are.equal("snapshot_missing", code)
    end)
end)

describe("snapstore manifest", function()
    local d, s
    before_each(function()
        d = disk()
        s = store(d)
    end)

    it("round-trips what it was given", function()
        s.write_manifest(1, { unit_blocks = 5, partitioner = 1 })
        local m = s.manifest(1)
        assert.are.equal(5, m.unit_blocks)
        assert.are.equal(1, m.partitioner)
    end)

    it("reports a job with no manifest", function()
        local m, code = s.manifest(1)
        assert.is_nil(m)
        assert.are.equal("snapshot_missing", code)
    end)

    it("reports a manifest it cannot read", function()
        d.files["/world/snapshots/1/manifest.json"] = "\1\2\3"
        local m, code = s.manifest(1)
        assert.is_nil(m)
        assert.are.equal("bad_snapshot", code)
    end)

    it("reports a write that failed", function()
        d.fail_write = true
        local ok, code = s.write_manifest(1, {})
        assert.is_nil(ok)
        assert.are.equal("snapshot_failed", code)
    end)
end)

describe("snapstore.sweep_temp", function()
    it("removes uncommitted leftovers and nothing else", function()
        local d = disk()
        local s = store(d)
        s.capture(1, 0, region(4), 4)
        d.files["/world/snapshots/1/1.bin.tmp"] = "half"
        d.files["/world/snapshots/1/2.bin.tmp"] = "half"

        assert.are.equal(2, s.sweep_temp(1))
        assert.is_true(d.fs.exists("/world/snapshots/1/0.bin"))
        assert.is_false(d.fs.exists("/world/snapshots/1/1.bin.tmp"))
    end)

    it("is harmless when there is nothing to sweep", function()
        assert.are.equal(0, store(disk()).sweep_temp(1))
    end)
end)
