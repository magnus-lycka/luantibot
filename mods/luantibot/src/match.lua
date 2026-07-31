-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Rule 3's other half: the `match` predicate of `fill_box_if`. Where a palette
-- entry names exactly one node, a match entry may also name a *group* --
-- `group:liquid` covers every liquid the game registers, which is the only
-- practical way to say "wherever there is water" without enumerating mods.
--
-- Resolved once per job into a set keyed by content id, so the inner loop over
-- a box is a single table lookup rather than a name comparison. Both the
-- resolver and the group expansion are injected, exactly like palette.lua's.

--- @param deps table {
---   resolve = function(name) -> content_id|nil,
---   ids_in_group = function(group) -> table array of content ids }
return function(deps)
    local match = {}

    --- Never matchable. `ignore` is what a VoxelManip reads for a mapblock that
    --- was never loaded; after the job's emerge there should be none inside the
    --- bounds, and treating it as terrain would let a failed emerge quietly
    --- become a build.
    match.RESERVED = { ["ignore"] = true }

    local GROUP = "group:"

    --- Compile a match list into a set of content ids.
    --- @param names table array of node names and `group:` expressions
    --- @return table|nil set, string|nil code, string|nil message
    function match.compile(names)
        if type(names) ~= "table" or #names == 0 then
            return nil, "bad_match", "match must be a non-empty list of node names or groups"
        end

        local set = {}
        for i = 1, #names do
            local name = names[i]
            if type(name) ~= "string" then
                return nil, "bad_match", string.format("match entry %d is not a string", i - 1)
            end

            if name:sub(1, #GROUP) == GROUP then
                local group = name:sub(#GROUP + 1)
                if group == "" then
                    return nil, "bad_match", string.format("match entry %d names no group", i - 1)
                end
                local ids = deps.ids_in_group(group)
                -- An empty group is not an error: a game without a single
                -- `falling_node` is unusual, not malformed. It simply matches
                -- nothing, which is what the caller asked for.
                for j = 1, #ids do
                    set[ids[j]] = true
                end
            else
                if match.RESERVED[name] then
                    return nil,
                        "bad_match",
                        string.format("match entry %d (%q) is reserved", i - 1, name)
                end
                local id = deps.resolve(name)
                if id == nil then
                    return nil,
                        "unknown_node",
                        string.format("match entry %d (%q) is not a registered node", i - 1, name)
                end
                set[id] = true
            end
        end

        return set
    end

    --- Compile the predicate of every `fill_box_if` in an op list, attaching it
    --- as `matchset`.
    ---
    --- Done once before execution rather than per op inside the unit loop: with
    --- work units (M4) the same op is applied to every unit it touches, and
    --- resolving groups each time would scan the node registry once per
    --- mapblock. Mutates the ops, which are `validate.ops_as_positions` copies
    --- and never the job document itself.
    ---
    --- @param ops table op copies
    --- @return table|nil ops, string|nil code, string|nil message
    function match.prepare(ops)
        for i, op in ipairs(ops) do
            if op.op == "fill_box_if" then
                local set, code, message = match.compile(op.match)
                if not set then
                    return nil, code, string.format("op %d: %s", i, message)
                end
                op.matchset = set
            end
        end
        return ops
    end

    return match
end
