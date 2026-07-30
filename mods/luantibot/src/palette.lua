-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Rule 3 of the wire contract: turn the job's palette of node names into content
-- ids, once, before anything is written. Resolution is injected
-- (`core.get_content_id` in init.lua) so this stays testable outside Luanti.
--
-- Fails closed. A name that does not resolve fails the job rather than
-- defaulting to air, because a job that half-builds is worse than one that
-- refuses: the caller can retry a refusal, but cannot see a silent substitution.
--
-- Indices are 0-based on the wire (`{"op": "fill_box", "node": 0}` means the
-- first palette entry) and Lua arrays are 1-based. That conversion lives in
-- `pal:id()` and nowhere else -- see "Wire contract" in
-- docs/implementation_plan.md.

--- @param deps table { resolve = function(name) -> content_id|nil }
return function(deps)
    local palette = {}

    --- Never a palette entry, whatever the deny list says. CONTENT_IGNORE is a
    --- real content id that `get_content_id` resolves happily, and writing it
    --- through a VoxelManip leaves undefined nodes behind.
    palette.RESERVED = { ["ignore"] = true }

    local Pal = {}
    Pal.__index = Pal

    --- Content id for a 0-based wire index.
    --- @return number|nil id, string|nil message
    function Pal:id(index)
        if type(index) ~= "number" or index ~= index or math.floor(index) ~= index then
            return nil, string.format("palette index %s is not an integer", tostring(index))
        end
        local id = self._ids[index + 1]
        if id == nil then
            return nil,
                string.format("palette index %d is outside a palette of %d", index, self.size)
        end
        return id
    end

    --- Resolve a list of node names to content ids.
    --- @param names table array of strings from the job document
    --- @param deny table|nil set of node names to refuse, `{ ["name"] = true }`
    --- @return table|nil pal, string|nil code, string|nil message
    function palette.compile(names, deny)
        if type(names) ~= "table" then
            return nil, "bad_palette", "palette must be a list of node names"
        end

        local ids = {}
        for i = 1, #names do
            local name = names[i]
            if type(name) ~= "string" then
                return nil, "bad_palette", string.format("palette entry %d is not a string", i - 1)
            end

            -- Groups select many nodes; a palette entry must name exactly one.
            -- Permitted in a `match` predicate only -- see the wire contract.
            if name:sub(1, 6) == "group:" then
                return nil,
                    "bad_palette",
                    string.format("palette entry %d (%q) is a group, not a node", i - 1, name)
            end

            if palette.RESERVED[name] then
                return nil,
                    "bad_palette",
                    string.format("palette entry %d (%q) is reserved", i - 1, name)
            end

            if deny and deny[name] then
                return nil,
                    "denied_node",
                    string.format("palette entry %d (%q) is on the deny list", i - 1, name)
            end

            local id = deps.resolve(name)
            if id == nil then
                return nil,
                    "unknown_node",
                    string.format("palette entry %d (%q) is not a registered node", i - 1, name)
            end
            ids[i] = id
        end

        return setmetatable({ _ids = ids, size = #ids }, Pal)
    end

    --- Parse a deny list from a settings string: names separated by commas or
    --- whitespace. Empty or nil yields an empty set, which is the shipped
    --- default -- see "On node validation".
    --- @return table set of names
    function palette.deny_set(spec)
        local deny = {}
        if type(spec) ~= "string" then
            return deny
        end
        for name in spec:gmatch("[^%s,]+") do
            deny[name] = true
        end
        return deny
    end

    return palette
end
