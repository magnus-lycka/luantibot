-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- The ops that write nodes, applied to the flat arrays a VoxelManip hands out.
-- Nothing here knows what a VoxelManip is: `buf` is a pair of plain arrays and
-- `area` is anything answering `:index(x, y, z)` with a 1-based offset into
-- them, which is exactly what Luanti's VoxelArea does and what the specs fake.
--
-- A node is content id plus `param2`, and `param2` is not decoration: it is the
-- facing of a trapdoor, the half of a slab, the colour of a dyed block. Writing
-- content alone leaves the new node wearing whatever orientation the old one
-- had, so every write sets both. Ops that do not care pass 0.
--
-- Two invariants hold for every op in this file, and the unit decomposition in
-- "Ordering and work units" depends on both:
--
--   * Node-local. No op reads a neighbouring node, so a cell's outcome depends
--     only on the ordered sequence of ops covering it. This is what makes
--     unit-major execution equivalent to the op-major reference semantics.
--   * Clipped, never wrapped. A box reaching outside the area is trimmed to it.
--     Writing outside the VoxelManip's region would corrupt an unrelated part
--     of the array, and silently -- the index arithmetic stays in range.

local apply = {}

--- Intersect a box with the area's extent.
--- Corners may be given in any order.
--- @return table|nil lo, table|nil hi -- nil when the box misses the area entirely
local function clip(area, p1, p2)
    local lo, hi = {}, {}
    for _, axis in ipairs({ "x", "y", "z" }) do
        local a = math.min(p1[axis], p2[axis])
        local b = math.max(p1[axis], p2[axis])
        lo[axis] = math.max(a, area.MinEdge[axis])
        hi[axis] = math.min(b, area.MaxEdge[axis])
        if lo[axis] > hi[axis] then
            return nil
        end
    end
    return lo, hi
end

apply.clip = clip

--- Set every node in the box to `content_id`.
---
--- Walks x innermost and indexes once per row, relying on x being contiguous in
--- the array. That is the documented VoxelArea layout and the idiom every
--- mapgen mod uses; `apply_spec.lua` pins it by faking the real index formula
--- rather than a permissive stub, so a wrong assumption fails there.
---
--- @param buf table { data = <content ids>, param2 = <param2 bytes> }, 1-based
--- @param area table anything with MinEdge, MaxEdge and :index(x, y, z)
--- @param p1 table {x,y,z} one corner
--- @param p2 table {x,y,z} the opposite corner
--- @param content_id number
--- @param param2 number|nil orientation and friends; 0 when not given
--- @return number nodes written
function apply.fill_box(buf, area, p1, p2, content_id, param2)
    local lo, hi = clip(area, p1, p2)
    if not lo then
        return 0
    end

    local data, p2data = buf.data, buf.param2
    param2 = param2 or 0
    local width = hi.x - lo.x
    local written = 0
    for z = lo.z, hi.z do
        for y = lo.y, hi.y do
            local base = area:index(lo.x, y, z)
            for i = 0, width do
                data[base + i] = content_id
                p2data[base + i] = param2
            end
            written = written + width + 1
        end
    end
    return written
end

--- Ops that read the world without changing it. Listed apart from `ops` because
--- the caller needs the distinction: a unit holding only these still needs the
--- VoxelManip read, but must not be written back.
local readers = {
    survey = function(buf, area, op, _, env)
        if env == nil or env.survey == nil then
            return nil, "bad_op", "survey needs an environment with a survey module"
        end
        env.out = env.survey.merge(
            env.out or {},
            env.survey.columns(buf, area, op.min, op.max, op.step, op.anchor)
        )
        return 0
    end,
}

--- What each op does to the array. `emerge` is absent on purpose: it is
--- satisfied before the VoxelManip is ever read, so by the time this table is
--- consulted there is nothing left for it to do.
local ops = {
    fill_box = function(buf, area, op, pal)
        local id, message = pal:id(op.node)
        if id == nil then
            return nil, "bad_node", message
        end
        return apply.fill_box(buf, area, op.min, op.max, id, op.param2)
    end,

    -- Put a unit back the way a snapshot found it. A write, so the buffer is
    -- committed afterwards -- but the caller must not snapshot a restore, or
    -- undoing an undo would record the undone state as if it were original.
    restore = function(buf, area, op, _, env)
        if env == nil or env.restore == nil then
            return nil, "bad_op", "restore needs an environment that can load snapshots"
        end
        if env.unit_index == nil then
            return nil, "bad_op", "restore needs to know which unit it is in"
        end
        return env.restore(env.unit_index, buf, area, op.min, op.max)
    end,

    fill_box_if = function(buf, area, op, pal)
        local id, message = pal:id(op.node)
        if id == nil then
            return nil, "bad_node", message
        end
        -- match.prepare attaches this before execution. Missing means the
        -- caller skipped that step, which would otherwise match nothing at all
        -- and silently build a hole where a pillar was asked for.
        if type(op.matchset) ~= "table" then
            return nil, "bad_match", "match set was never compiled"
        end
        return apply.fill_box_if(buf, area, op.min, op.max, id, op.param2, op.matchset, op.invert)
    end,
}

--- Set every node in the box that matches the predicate, leaving the rest.
---
--- `matchset` is keyed by content id, compiled once per job by match.lua, so
--- the test per cell is one table lookup. `invert` flips it: `{air, liquid}`
--- fills the empty space under a bridge, and the same set inverted carves a
--- shaft up through whatever is solid.
---
--- Still node-local. The predicate looks only at the cell being written, never
--- at its neighbours or at how many cells came before it, which is what keeps
--- unit decomposition valid -- see "Ordering and work units" and "What
--- `fill_box_if` deliberately does not do" in docs/implementation_plan.md.
---
--- Unlike `fill_box`, the return is the number of cells actually *changed*,
--- not the size of the box. That is the useful number here: it is how the
--- caller learns a pillar found rock immediately, or that a predicate matched
--- nothing at all.
---
--- @param buf table { data, param2 }
--- @param area table VoxelArea or equivalent
--- @param p1 table {x,y,z}
--- @param p2 table {x,y,z}
--- @param content_id number
--- @param param2 number|nil
--- @param matchset table set of content ids, `{ [id] = true }`
--- @param invert boolean|nil write where the predicate does *not* hold
--- @return number nodes changed
function apply.fill_box_if(buf, area, p1, p2, content_id, param2, matchset, invert)
    local lo, hi = clip(area, p1, p2)
    if not lo then
        return 0
    end

    local data, p2data = buf.data, buf.param2
    param2 = param2 or 0
    invert = invert == true
    local width = hi.x - lo.x
    local changed = 0
    for z = lo.z, hi.z do
        for y = lo.y, hi.y do
            local base = area:index(lo.x, y, z)
            for i = 0, width do
                local idx = base + i
                -- XOR: matched and not inverted, or unmatched and inverted.
                if (matchset[data[idx]] == true) ~= invert then
                    data[idx] = content_id
                    p2data[idx] = param2
                    changed = changed + 1
                end
            end
        end
    end
    return changed
end

--- Does this op list need to look at the world at all?
---
--- Distinct from `writes`, and the distinction is the point: a survey needs the
--- VoxelManip read and must never be written back, while a job that only
--- generates terrain needs no VoxelManip whatsoever. Reading one back marks
--- every mapblock in it modified and forces a re-save, which is the opposite of
--- what an emerge-only job is for.
--- @return boolean
function apply.reads(job_ops)
    for _, op in ipairs(job_ops) do
        if ops[op.op] or readers[op.op] then
            return true
        end
    end
    return false
end

--- Does this op list change any node? Decides whether the buffer is written
--- back, not whether it is read -- see `apply.reads`.
--- @return boolean
function apply.writes(job_ops)
    for _, op in ipairs(job_ops) do
        if ops[op.op] then
            return true
        end
    end
    return false
end

--- Walk a job's op list in order, applying each to the array.
---
--- Original order is the contract, and the reason this is a plain sequential
--- loop with no grouping or sorting: reordering ops at a node is the first of
--- the three things that break unit decomposition. See "Ordering and work
--- units" in docs/implementation_plan.md.
---
--- @param buf table { data = <content ids>, param2 = <param2 bytes> }
--- @param area table VoxelArea or equivalent
--- @param job_ops table array of op tables, already validated
--- @param pal table compiled palette, answering :id(wire_index)
--- @param env table|nil capabilities and output for ops that need more than the
---   buffer -- `survey` reads the node registry and produces columns. Kept out
---   of the module's construction so that `fill_box`, which is arithmetic over
---   an array, does not acquire a dependency on the registry.
--- @return number|nil written, string|nil code, string|nil message
function apply.run(buf, area, job_ops, pal, env)
    local written = 0
    for i, op in ipairs(job_ops) do
        local handler = ops[op.op] or readers[op.op]
        if handler then
            local n, code, message = handler(buf, area, op, pal, env)
            if n == nil then
                return nil, code, string.format("op %d: %s", i, message)
            end
            written = written + n
        elseif op.op ~= "emerge" then
            -- validate.lua refuses unknown ops before this runs, so reaching
            -- here means the two lists have drifted apart.
            return nil, "unknown_op", string.format("op %d: no handler for %q", i, tostring(op.op))
        end
    end
    return written
end

return apply
