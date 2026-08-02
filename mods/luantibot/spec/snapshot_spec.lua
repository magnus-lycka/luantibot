-- The snapshot format, and above all the property it exists for: a region
-- restored after the content ids have moved must come back as the same *nodes*.
--
-- Ids are assigned at registration time and depend on the mod set and its load
-- order. Recovery spans a server restart by definition, so the ids in a
-- snapshot are meaningless by the time it is read. Several tests below encode
-- under one registry and decode under a different one, which is the case a
-- format storing raw ids would fail silently.

local factory = require("snapshot")

--- A node registry. `shift` renumbers everything, standing in for a restart
--- that loaded the mods in a different order.
local function registry(names, shift)
    shift = shift or 0
    local by_id, by_name = {}, {}
    for i, name in ipairs(names) do
        local id = i + shift
        by_id[id] = name
        by_name[name] = id
    end
    return {
        name = function(id)
            return by_id[id]
        end,
        resolve = function(name)
            return by_name[name]
        end,
        id = function(name)
            return by_name[name]
        end,
    }
end

local NODES = { "air", "mcl_core:stone", "mcl_core:dirt", "mcl_stairs:stair_stone" }

local function snap(reg)
    return factory({ name = reg.name, resolve = reg.resolve })
end

--- A buffer of `count` nodes, cycling through the given names.
local function region(reg, names, param2s, count)
    local data, param2 = {}, {}
    for i = 1, count do
        data[i] = reg.id(names[(i - 1) % #names + 1])
        param2[i] = param2s[(i - 1) % #param2s + 1]
    end
    return { data = data, param2 = param2 }
end

describe("snapshot round trip", function()
    local reg, s
    before_each(function()
        reg = registry(NODES)
        s = snap(reg)
    end)

    it("restores content and param2 exactly", function()
        local buf = region(reg, { "mcl_core:stone", "air", "mcl_core:dirt" }, { 0, 12, 255 }, 30)
        local out = s.decode(s.encode(buf, 30))

        assert.are.equal(30, out.count)
        for i = 1, 30 do
            assert.are.equal(buf.data[i], out.data[i], "content differs at " .. i)
            assert.are.equal(buf.param2[i], out.param2[i], "param2 differs at " .. i)
        end
    end)

    it("handles a region of one node", function()
        local buf = region(reg, { "air" }, { 0 }, 1)
        local out = s.decode(s.encode(buf, 1))
        assert.are.equal(1, out.count)
        assert.are.equal(buf.data[1], out.data[1])
    end)

    it("handles an empty region", function()
        local out = s.decode(s.encode({ data = {}, param2 = {} }, 0))
        assert.are.equal(0, out.count)
    end)

    it("preserves param2 across the whole byte range", function()
        local buf = { data = {}, param2 = {} }
        for i = 1, 256 do
            buf.data[i] = reg.id("mcl_core:stone")
            buf.param2[i] = i - 1
        end
        local out = s.decode(s.encode(buf, 256))
        for i = 1, 256 do
            assert.are.equal(i - 1, out.param2[i], "param2 " .. (i - 1) .. " did not survive")
        end
    end)

    -- Orientation is the whole reason param2 is in the file: facedir stairs and
    -- wallmounted torches carry their rotation there and nowhere else.
    it("preserves a rotated node's orientation", function()
        local buf = {
            data = { reg.id("mcl_stairs:stair_stone") },
            param2 = { 22 },
        }
        local out = s.decode(s.encode(buf, 1))
        assert.are.equal(22, out.param2[1])
    end)

    it("is deterministic: the same region gives the same bytes", function()
        local buf = region(reg, { "mcl_core:stone", "air" }, { 0, 3 }, 50)
        assert.are.equal(s.encode(buf, 50), s.encode(buf, 50))
    end)
end)

describe("snapshot across a registry change", function()
    -- The property the name table exists for.
    it("restores the same nodes when every id has moved", function()
        local before = registry(NODES)
        local mixed = { "mcl_core:dirt", "air", "mcl_stairs:stair_stone" }
        local buf = region(before, mixed, { 1, 2, 3 }, 30)
        local blob = snap(before).encode(buf, 30)

        local after = registry(NODES, 100) -- a restart renumbered everything
        local out = snap(after).decode(blob)

        for i = 1, 30 do
            local wanted = before.name(buf.data[i])
            assert.are.equal(wanted, after.name(out.data[i]), "node differs at " .. i)
            assert.are.equal(buf.param2[i], out.param2[i])
        end
    end)

    it("restores correctly when the registry gained nodes", function()
        local before = registry(NODES)
        local buf = region(before, { "mcl_core:stone" }, { 0 }, 10)
        local blob = snap(before).encode(buf, 10)

        local after = registry({ "some_mod:new", unpack(NODES) })
        local out = snap(after).decode(blob)
        assert.are.equal("mcl_core:stone", after.name(out.data[1]))
    end)

    -- Never substitute air. A half-correct restore is worse than a refused one,
    -- because nothing about it looks wrong.
    it("refuses to restore when a node is no longer registered", function()
        local before = registry(NODES)
        local buf = region(before, { "mcl_stairs:stair_stone", "air" }, { 0 }, 4)
        local blob = snap(before).encode(buf, 4)

        local after = registry({ "air", "mcl_core:stone", "mcl_core:dirt" })
        local out, code, message = snap(after).decode(blob)

        assert.is_nil(out)
        assert.are.equal("unknown_node", code)
        assert.matches("mcl_stairs:stair_stone", message)
    end)

    it("names every missing node, not just the first", function()
        local before = registry({ "air", "a:one", "b:two" })
        local buf = region(before, { "a:one", "b:two" }, { 0 }, 4)
        local blob = snap(before).encode(buf, 4)

        local _, _, message = snap(registry({ "air" })).decode(blob)
        assert.matches("a:one", message)
        assert.matches("b:two", message)
    end)
end)

describe("snapshot index width", function()
    local function distinct(n)
        local names = {}
        for i = 1, n do
            names[i] = "mod:node" .. i
        end
        return names
    end

    --- Bytes per node in the body, ignoring the header and name table.
    local function width_of(names)
        local reg = registry(names)
        local buf = region(reg, names, { 0 }, #names)
        local s = snap(reg)
        return s.header(s.encode(buf, #names)).width
    end

    -- The compression fix in the plan: natural terrain holds a few dozen
    -- distinct nodes, so one byte per index halves the body against raw ids.
    it("uses one byte for a region of few distinct nodes", function()
        assert.are.equal(1, width_of(distinct(30)))
    end)

    it("still uses one byte at exactly 256, since indices are 0-based", function()
        assert.are.equal(1, width_of(distinct(256)))
    end)

    it("widens to two bytes past 256", function()
        assert.are.equal(2, width_of(distinct(257)))
    end)

    it("round-trips a wide region", function()
        local names = distinct(300)
        local reg = registry(names)
        local buf = region(reg, names, { 7 }, 600)
        local out = snap(reg).decode(snap(reg).encode(buf, 600))
        for i = 1, 600 do
            assert.are.equal(buf.data[i], out.data[i], "content differs at " .. i)
        end
    end)
end)

describe("snapshot rejects damaged input", function()
    local reg, s
    before_each(function()
        reg = registry(NODES)
        s = snap(reg)
    end)

    local function blob()
        return s.encode(region(reg, { "mcl_core:stone", "air" }, { 0, 5 }, 40), 40)
    end

    it("rejects something that is not a snapshot", function()
        local out, code = s.decode("hello there")
        assert.is_nil(out)
        assert.are.equal("bad_snapshot", code)
    end)

    it("rejects an empty string", function()
        assert.is_nil(s.decode(""))
    end)

    it("rejects a non-string", function()
        assert.is_nil(s.decode(nil))
        assert.is_nil(s.decode(42))
    end)

    -- A truncated file is what a crash mid-write leaves behind. It must not
    -- decode into a short region that then restores over live world.
    it("rejects a truncated body", function()
        local b = blob()
        local out, code = s.decode(b:sub(1, #b - 10))
        assert.is_nil(out)
        assert.are.equal("bad_snapshot", code)
    end)

    it("rejects a truncated name table", function()
        local b = blob()
        local out, code = s.decode(b:sub(1, 12))
        assert.is_nil(out)
        assert.are.equal("bad_snapshot", code)
    end)

    it("rejects an unknown format version", function()
        local b = blob()
        local bad = b:sub(1, 3) .. string.char(99) .. b:sub(5)
        local out, code, message = s.decode(bad)
        assert.is_nil(out)
        assert.are.equal("bad_snapshot", code)
        assert.matches("format 99", message)
    end)

    it("rejects an impossible index width", function()
        local b = blob()
        local bad = b:sub(1, 4) .. string.char(7) .. b:sub(6)
        local out, code = s.decode(bad)
        assert.is_nil(out)
        assert.are.equal("bad_snapshot", code)
    end)
end)

describe("snapshot encode refuses bad input", function()
    it("refuses a hole in the data array", function()
        local reg = registry(NODES)
        local buf = { data = { reg.id("air"), nil, reg.id("air") }, param2 = { 0, 0, 0 } }
        local blob, code = snap(reg).encode(buf, 3)
        assert.is_nil(blob)
        assert.are.equal("bad_snapshot", code)
    end)

    it("refuses a content id the registry cannot name", function()
        local reg = registry(NODES)
        local buf = { data = { 9999 }, param2 = { 0 } }
        local blob, code = snap(reg).encode(buf, 1)
        assert.is_nil(blob)
        assert.are.equal("bad_snapshot", code)
    end)

    it("refuses a nonsense count", function()
        local reg = registry(NODES)
        assert.is_nil(snap(reg).encode({ data = {}, param2 = {} }, -1))
        assert.is_nil(snap(reg).encode({ data = {}, param2 = {} }, 1.5))
    end)

    it("treats a missing param2 as zero rather than failing", function()
        local reg = registry(NODES)
        local buf = { data = { reg.id("air") }, param2 = {} }
        local out = snap(reg).decode(snap(reg).encode(buf, 1))
        assert.are.equal(0, out.param2[1])
    end)
end)
