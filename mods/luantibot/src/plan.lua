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
