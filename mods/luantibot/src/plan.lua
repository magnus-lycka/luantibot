-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Geometry of mapblocks: aligning boxes to them, counting them, and turning a
-- centre+radius request into the box the mod will emerge.
--
-- Positions are plain tables {x=, y=, z=} of integers. This module deliberately
-- does not use Luanti's `vector` helpers, which are an engine global.

local plan = {}

--- Nodes along one edge of a mapblock.
plan.MAPBLOCK = 16

local function is_int(v)
    -- Rejects NaN (v ~= v), infinities, and fractions in one go. Order matters:
    -- math.floor(inf) == inf, so the finiteness test cannot be left to floor.
    if type(v) ~= "number" or v ~= v then
        return false
    end
    return v > -math.huge and v < math.huge and math.floor(v) == v
end

local function is_pos(v)
    return type(v) == "table" and is_int(v.x) and is_int(v.y) and is_int(v.z)
end

plan.is_pos = is_pos

--- Mapblock containing a node position.
--- Floors toward negative infinity, matching Luanti: node -1 is in block -1.
--- @param pos table {x,y,z} node position
--- @return table {x,y,z} block position
function plan.blockpos(pos)
    local n = plan.MAPBLOCK
    return {
        x = math.floor(pos.x / n),
        y = math.floor(pos.y / n),
        z = math.floor(pos.z / n),
    }
end

--- Expand a box out to whole mapblock boundaries.
--- Corners may be given in any order; the result is normalised so p1 <= p2.
--- @param p1 table {x,y,z}
--- @param p2 table {x,y,z}
--- @return table, table aligned minimum and maximum corners
function plan.align(p1, p2)
    local n = plan.MAPBLOCK
    local lo, hi = {}, {}
    for _, axis in ipairs({ "x", "y", "z" }) do
        local a = math.min(p1[axis], p2[axis])
        local b = math.max(p1[axis], p2[axis])
        lo[axis] = math.floor(a / n) * n
        hi[axis] = math.floor(b / n) * n + (n - 1)
    end
    return lo, hi
end

--- Mapblock-aligned box covering the cube of `radius` nodes around `centre`.
--- @param centre table {x,y,z} node position
--- @param radius number non-negative integer, in nodes
--- @return table|nil, table|string aligned min and max, or nil and an error
function plan.emerge_bounds(centre, radius)
    if not is_pos(centre) then
        return nil, "centre must be a position with integer x, y and z"
    end
    if not is_int(radius) or radius < 0 then
        return nil, "radius must be a non-negative integer"
    end

    local lo = { x = centre.x - radius, y = centre.y - radius, z = centre.z - radius }
    local hi = { x = centre.x + radius, y = centre.y + radius, z = centre.z + radius }
    return plan.align(lo, hi)
end

--- Mapblocks along one edge of a work unit.
---
--- 5x5x5 mapblocks is 512k nodes, a couple of megabytes of Lua array. The whole
--- point of units is that a job's size stops being bounded by what one
--- VoxelManip can hold: 4096 mapblocks is 16.7 million nodes, which is why that
--- cap exists at all. Sized for memory and emerge throughput rather than for
--- latency, because nobody else is on this server.
plan.UNIT_BLOCKS = 5

--- Partition a box into disjoint, mapblock-aligned work units.
---
--- Disjoint is the load-bearing word. Units may *read* overlapping regions --
--- a VoxelManip rounds outward, and M8 lighting will want a margin -- but two
--- units must never write the same node, or the op order between them would
--- decide the outcome and unit-major would stop matching the reference
--- semantics. See "Ordering and work units" in docs/implementation_plan.md.
---
--- @param p1 table {x,y,z}
--- @param p2 table {x,y,z}
--- @param blocks number|nil mapblocks per unit edge
--- @return table array of { min = {x,y,z}, max = {x,y,z} }
function plan.units(p1, p2, blocks)
    local step = (blocks or plan.UNIT_BLOCKS) * plan.MAPBLOCK
    local lo, hi = plan.align(p1, p2)
    local out = {}
    for z = lo.z, hi.z, step do
        for y = lo.y, hi.y, step do
            for x = lo.x, hi.x, step do
                out[#out + 1] = {
                    min = { x = x, y = y, z = z },
                    max = {
                        x = math.min(x + step - 1, hi.x),
                        y = math.min(y + step - 1, hi.y),
                        z = math.min(z + step - 1, hi.z),
                    },
                }
            end
        end
    end
    return out
end

--- Intersect two boxes.
--- @return table|nil lo, table|nil hi -- nil when they do not overlap
local function intersect(a1, a2, b1, b2)
    local lo, hi = {}, {}
    for _, axis in ipairs({ "x", "y", "z" }) do
        lo[axis] = math.max(math.min(a1[axis], a2[axis]), b1[axis])
        hi[axis] = math.min(math.max(a1[axis], a2[axis]), b2[axis])
        if lo[axis] > hi[axis] then
            return nil
        end
    end
    return lo, hi
end

plan.intersect = intersect

--- The ops touching a unit, clipped to it, in original order.
---
--- Clipping is not an optimisation. apply.lua already trims writes to the
--- VoxelArea, but that area is the *read* region and reaches past the unit;
--- without this an op would write into a neighbour's territory and the units
--- would no longer be disjoint in what they write.
---
--- Order is preserved exactly. Walking the op list out of order inside a unit
--- is the failure the contract fixture exists to catch, and it only shows at
--- unit seams.
---
--- @param ops table op list with `min`/`max` as positions
--- @param lo table {x,y,z} unit minimum
--- @param hi table {x,y,z} unit maximum
--- @return table ops for this unit
function plan.clip_ops(ops, lo, hi)
    local out = {}
    for _, op in ipairs(ops) do
        if op.min == nil then
            -- No box of its own: `emerge` applies to the whole job, and each
            -- unit emerges itself before anything is applied.
            out[#out + 1] = op
        else
            local a, b = intersect(op.min, op.max, lo, hi)
            if a then
                local copy = {}
                for k, v in pairs(op) do
                    copy[k] = v
                end
                copy.min, copy.max = a, b
                out[#out + 1] = copy
            end
        end
    end
    return out
end

--- Number of mapblocks a box touches, whole or partial.
--- This is the quantity emerge and work-unit caps are applied to.
--- @param p1 table {x,y,z}
--- @param p2 table {x,y,z}
--- @return number
function plan.block_count(p1, p2)
    local lo = plan.blockpos({
        x = math.min(p1.x, p2.x),
        y = math.min(p1.y, p2.y),
        z = math.min(p1.z, p2.z),
    })
    local hi = plan.blockpos({
        x = math.max(p1.x, p2.x),
        y = math.max(p1.y, p2.y),
        z = math.max(p1.z, p2.z),
    })
    return (hi.x - lo.x + 1) * (hi.y - lo.y + 1) * (hi.z - lo.z + 1)
end

return plan
