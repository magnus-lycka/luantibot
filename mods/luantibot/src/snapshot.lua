-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Serialising a unit's region so it can be put back. Bytes in, bytes out; the
-- file I/O is somebody else's problem.
--
-- **Content ids are not durable.** They are assigned at registration time and
-- depend on the mod set and the order it loaded in, so they move across a
-- server restart -- and recovery spans restarts by definition. A snapshot
-- holding raw ids would silently restore the wrong nodes after any mod change,
-- which is the kind of corruption nobody notices until much later. So the file
-- carries its own id-to-name table and the body stores indices into it:
--
--     magic    "LBS" and a format byte
--     width    1 or 2 bytes per index, chosen from how many distinct nodes
--              a unit actually holds -- natural terrain has a few dozen, so
--              one byte usually does, which halves the file
--     names    the distinct node names, in first-seen order
--     count    nodes in the region
--     data     `count` indices into the name table
--     param2   `count` raw bytes, unchanged
--
-- `param2` needs no remapping: it is per-node raw data, meaningful only against
-- the node definition it was written for, and the name check already guards
-- that. `param1` is deliberately absent -- it is lighting, which builds do not
-- maintain anyway, so a restored value would be no more correct than a
-- recomputed one.
--
-- Written for Lua 5.1: LuaJIT has no `string.pack`, so the packing here is by
-- hand and big-endian throughout.

local MAGIC = "LBS"
local FORMAT = 1

--- @param deps table {
---   name    = function(content_id) -> string,
---   resolve = function(name) -> content_id|nil }
return function(deps)
    local snapshot = {}

    snapshot.MAGIC = MAGIC
    snapshot.FORMAT = FORMAT

    --- `string.char` takes a bounded number of arguments and `unpack` has its
    --- own limit, so bytes are emitted in chunks and joined once. A unit is
    --- half a million nodes; concatenating one byte at a time would be
    --- quadratic.
    local CHUNK = 1024

    local Writer = {}
    Writer.__index = Writer

    local function writer()
        return setmetatable({ _parts = {}, _bytes = {}, _n = 0 }, Writer)
    end

    function Writer:byte(v)
        self._n = self._n + 1
        self._bytes[self._n] = v
        if self._n == CHUNK then
            self._parts[#self._parts + 1] = string.char(unpack(self._bytes))
            self._bytes, self._n = {}, 0
        end
    end

    function Writer:u16(v)
        self:byte(math.floor(v / 256) % 256)
        self:byte(v % 256)
    end

    function Writer:u32(v)
        self:byte(math.floor(v / 16777216) % 256)
        self:byte(math.floor(v / 65536) % 256)
        self:byte(math.floor(v / 256) % 256)
        self:byte(v % 256)
    end

    function Writer:raw(s)
        if self._n > 0 then
            self._parts[#self._parts + 1] = string.char(unpack(self._bytes, 1, self._n))
            self._bytes, self._n = {}, 0
        end
        self._parts[#self._parts + 1] = s
    end

    function Writer:done()
        if self._n > 0 then
            self._parts[#self._parts + 1] = string.char(unpack(self._bytes, 1, self._n))
            self._bytes, self._n = {}, 0
        end
        return table.concat(self._parts)
    end

    --- Serialise a region.
    ---
    --- Names are collected in first-seen order rather than sorted, which makes
    --- the output a deterministic function of the input: the same region always
    --- produces the same bytes, so a test can compare files rather than decode
    --- them.
    ---
    --- @param buf table { data, param2 } 1-based, at least `count` long
    --- @param count number nodes in the region
    --- @return string|nil blob, string|nil code, string|nil message
    function snapshot.encode(buf, count)
        if type(count) ~= "number" or count < 0 or math.floor(count) ~= count then
            return nil, "bad_snapshot", "count must be a non-negative integer"
        end

        local index_of, names = {}, {}
        for i = 1, count do
            local id = buf.data[i]
            if id == nil then
                return nil, "bad_snapshot", string.format("no content id at index %d", i)
            end
            if index_of[id] == nil then
                local name = deps.name(id)
                if type(name) ~= "string" then
                    return nil,
                        "bad_snapshot",
                        string.format("content id %s has no name", tostring(id))
                end
                names[#names + 1] = name
                index_of[id] = #names
            end
        end

        -- Indices are 0-based in the file, so 256 distinct names still fit in
        -- one byte.
        local width = (#names <= 256) and 1 or 2

        local w = writer()
        w:raw(MAGIC)
        w:byte(FORMAT)
        w:byte(width)
        w:u16(#names)
        for _, name in ipairs(names) do
            w:u16(#name)
            w:raw(name)
        end
        w:u32(count)

        for i = 1, count do
            local idx = index_of[buf.data[i]] - 1
            if width == 1 then
                w:byte(idx)
            else
                w:u16(idx)
            end
        end
        for i = 1, count do
            w:byte(buf.param2[i] or 0)
        end

        return w:done()
    end

    local function u8(blob, pos)
        return string.byte(blob, pos), pos + 1
    end

    local function u16(blob, pos)
        local a, b = string.byte(blob, pos, pos + 1)
        return a * 256 + b, pos + 2
    end

    local function u32(blob, pos)
        local a, b, c, d = string.byte(blob, pos, pos + 3)
        return ((a * 256 + b) * 256 + c) * 256 + d, pos + 4
    end

    --- Read the header alone: what the file claims and which names it needs.
    --- Separated so `undo` can check every name is still registered before it
    --- starts changing the world.
    --- @return table|nil header { format, width, names, count, body }
    function snapshot.header(blob)
        if type(blob) ~= "string" or #blob < 11 or blob:sub(1, 3) ~= MAGIC then
            return nil, "bad_snapshot", "not a luantibot snapshot"
        end
        local pos = 4
        local format, width, n
        format, pos = u8(blob, pos)
        if format ~= FORMAT then
            return nil, "bad_snapshot", string.format("unsupported snapshot format %d", format)
        end
        width, pos = u8(blob, pos)
        if width ~= 1 and width ~= 2 then
            return nil, "bad_snapshot", string.format("bad index width %d", width)
        end
        n, pos = u16(blob, pos)

        local names = {}
        for i = 1, n do
            local len
            len, pos = u16(blob, pos)
            if pos + len - 1 > #blob then
                return nil, "bad_snapshot", "truncated name table"
            end
            names[i] = blob:sub(pos, pos + len - 1)
            pos = pos + len
        end

        local count
        count, pos = u32(blob, pos)
        if pos + count * width + count - 1 > #blob then
            return nil, "bad_snapshot", "truncated body"
        end

        return { format = format, width = width, names = names, count = count, body = pos }
    end

    --- Rebuild the region, translating names back through the *current*
    --- registry.
    ---
    --- A name that is no longer registered fails the whole restore rather than
    --- becoming air. A half-correct restore is worse than a refused one,
    --- because nothing about it looks wrong.
    ---
    --- @return table|nil buf { data, param2, count }
    function snapshot.decode(blob)
        local h, code, message = snapshot.header(blob)
        if not h then
            return nil, code, message
        end

        local remap, missing = {}, {}
        for i, name in ipairs(h.names) do
            local id = deps.resolve(name)
            if id == nil then
                missing[#missing + 1] = name
            else
                remap[i - 1] = id
            end
        end
        if #missing > 0 then
            return nil,
                "unknown_node",
                "snapshot names nodes this game no longer registers: " .. table.concat(
                    missing,
                    ", "
                )
        end

        local data, param2 = {}, {}
        local pos = h.body
        if h.width == 1 then
            for i = 1, h.count do
                data[i] = remap[string.byte(blob, pos)]
                pos = pos + 1
            end
        else
            for i = 1, h.count do
                local v
                v, pos = u16(blob, pos)
                data[i] = remap[v]
            end
        end
        for i = 1, h.count do
            param2[i] = string.byte(blob, pos)
            pos = pos + 1
        end

        return { data = data, param2 = param2, count = h.count }
    end

    return snapshot
end
