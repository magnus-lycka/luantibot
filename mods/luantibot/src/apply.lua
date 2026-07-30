-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- The ops that write nodes, applied to the flat content-id array a VoxelManip
-- hands out. Nothing here knows what a VoxelManip is: `data` is a plain array
-- and `area` is anything answering `:index(x, y, z)` with a 1-based offset into
-- it, which is exactly what Luanti's VoxelArea does and what the specs fake.
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
--- @param data table flat array of content ids, 1-based
--- @param area table anything with MinEdge, MaxEdge and :index(x, y, z)
--- @param p1 table {x,y,z} one corner
--- @param p2 table {x,y,z} the opposite corner
--- @param content_id number
--- @return number nodes written
function apply.fill_box(data, area, p1, p2, content_id)
    local lo, hi = clip(area, p1, p2)
    if not lo then
        return 0
    end

    local width = hi.x - lo.x
    local written = 0
    for z = lo.z, hi.z do
        for y = lo.y, hi.y do
            local base = area:index(lo.x, y, z)
            for i = 0, width do
                data[base + i] = content_id
            end
            written = written + width + 1
        end
    end
    return written
end

--- What each op does to the array. `emerge` is absent on purpose: it is
--- satisfied before the VoxelManip is ever read, so by the time this table is
--- consulted there is nothing left for it to do.
local ops = {
    fill_box = function(data, area, op, pal)
        local id, message = pal:id(op.node)
        if id == nil then
            return nil, "bad_node", message
        end
        return apply.fill_box(data, area, op.min, op.max, id)
    end,
}

--- Does this op list change any node?
---
--- The caller uses this to skip the VoxelManip entirely for an emerge-only job.
--- That is not just an optimisation: reading and writing back a VoxelManip
--- marks every mapblock in it modified, so a job that was asked to generate
--- terrain and nothing else would dirty the whole region and force it to be
--- re-saved.
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
--- @param data table flat array of content ids
--- @param area table VoxelArea or equivalent
--- @param job_ops table array of op tables, already validated
--- @param pal table compiled palette, answering :id(wire_index)
--- @return number|nil written, string|nil code, string|nil message
function apply.run(data, area, job_ops, pal)
    local written = 0
    for i, op in ipairs(job_ops) do
        local handler = ops[op.op]
        if handler then
            local n, code, message = handler(data, area, op, pal)
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
