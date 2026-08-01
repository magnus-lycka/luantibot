-- The equivalence that unit-major execution rests on.
--
-- Reference semantics are op-major: apply each op, in order, across the whole
-- of `bounds`. The mod cannot afford that -- it would emerge and VoxelManip the
-- entire bounds once per op -- so it runs unit-major instead, one emerge/VM
-- cycle per unit, walking the op list inside each.
--
-- The two agree only because fill_box and fill_box_if are node-local. This file
-- is the proof, and it is written the way the plan asks: against a reference
-- implementation rather than a hand-written expected world, with ops that
-- straddle a unit boundary so the seams are exercised rather than the interiors.

local plan = require("plan")
local apply = require("apply")

local function p(x, y, z)
    return { x = x, y = y, z = z }
end

local function key(x, y, z)
    return string.format("%d,%d,%d", x, y, z)
end

--- A palette mapping wire index n to content id 100 + n.
local pal = {
    size = 4,
    id = function(_, i)
        return (i >= 0 and i < 4) and (100 + i) or nil
    end,
}

--- VoxelArea stand-in using the engine's real index formula.
local function area(min, max)
    local ystride = max.x - min.x + 1
    local zstride = ystride * (max.y - min.y + 1)
    return {
        MinEdge = min,
        MaxEdge = max,
        index = function(self, x, y, z)
            return (z - self.MinEdge.z) * zstride
                + (y - self.MinEdge.y) * ystride
                + (x - self.MinEdge.x)
                + 1
        end,
    }
end

local EMPTY = 0

local function blank(a)
    local n = (a.MaxEdge.x - a.MinEdge.x + 1)
        * (a.MaxEdge.y - a.MinEdge.y + 1)
        * (a.MaxEdge.z - a.MinEdge.z + 1)
    local data, param2 = {}, {}
    for i = 1, n do
        data[i], param2[i] = EMPTY, 0
    end
    return { data = data, param2 = param2 }
end

--- Op-major over the whole bounds: the definition of what a job means.
local function reference(ops, lo, hi)
    local world = {}
    for _, op in ipairs(ops) do
        if op.min then
            local id = pal:id(op.node)
            for x = math.max(op.min.x, lo.x), math.min(op.max.x, hi.x) do
                for y = math.max(op.min.y, lo.y), math.min(op.max.y, hi.y) do
                    for z = math.max(op.min.z, lo.z), math.min(op.max.z, hi.z) do
                        if op.op == "fill_box" then
                            world[key(x, y, z)] = id
                        elseif op.op == "fill_box_if" then
                            local cur = world[key(x, y, z)] or EMPTY
                            if (op.matchset[cur] == true) ~= (op.invert == true) then
                                world[key(x, y, z)] = id
                            end
                        end
                    end
                end
            end
        end
    end
    return world
end

--- Unit-major, the way world.lua runs it.
---
--- `margin` inflates each unit's VoxelArea beyond the unit itself, which is
--- what the engine really hands back: read_from_map rounds outward. Without
--- plan.clip_ops an op would then write into a neighbouring unit, so the
--- margin is what makes the disjointness assertion meaningful.
local function unit_major(ops, lo, hi, blocks, margin)
    margin = margin or 0
    local world = {}
    local spilled = {}
    for _, unit in ipairs(plan.units(lo, hi, blocks)) do
        local amin = p(unit.min.x - margin, unit.min.y - margin, unit.min.z - margin)
        local amax = p(unit.max.x + margin, unit.max.y + margin, unit.max.z + margin)
        local a = area(amin, amax)
        local buf = blank(a)

        -- Each unit reads the world as it stands, exactly as a VoxelManip does.
        for x = amin.x, amax.x do
            for y = amin.y, amax.y do
                for z = amin.z, amax.z do
                    local v = world[key(x, y, z)]
                    if v then
                        buf.data[a:index(x, y, z)] = v
                    end
                end
            end
        end

        apply.run(buf, a, plan.clip_ops(ops, unit.min, unit.max), pal)

        for x = amin.x, amax.x do
            for y = amin.y, amax.y do
                for z = amin.z, amax.z do
                    local v = buf.data[a:index(x, y, z)]
                    local inside = x >= unit.min.x
                        and x <= unit.max.x
                        and y >= unit.min.y
                        and y <= unit.max.y
                        and z >= unit.min.z
                        and z <= unit.max.z
                    if inside then
                        if v ~= EMPTY then
                            world[key(x, y, z)] = v
                        end
                    elseif v ~= EMPTY and v ~= world[key(x, y, z)] then
                        spilled[#spilled + 1] = key(x, y, z)
                    end
                end
            end
        end
    end
    return world, spilled
end

local function volume(b)
    return (b.max.x - b.min.x + 1) * (b.max.y - b.min.y + 1) * (b.max.z - b.min.z + 1)
end

--- Do two boxes share a node?
local function overlaps(a, b)
    for _, axis in ipairs({ "x", "y", "z" }) do
        if a.min[axis] > b.max[axis] or b.min[axis] > a.max[axis] then
            return false
        end
    end
    return true
end

describe("plan.units", function()
    -- Disjoint and covering, checked as arithmetic on the boxes rather than by
    -- walking every node. Pairwise non-overlap plus volumes summing to the whole
    -- is the same claim, and it is a few dozen comparisons instead of tens of
    -- thousands of table writes -- which matters under coverage instrumentation,
    -- where every line executed carries a debug hook.
    it("covers the aligned box exactly once", function()
        local lo, hi = p(0, 0, 0), p(159, 15, 15)
        local units = plan.units(lo, hi, 5)

        local total = 0
        for i, u in ipairs(units) do
            total = total + volume(u)
            for j = i + 1, #units do
                local msg = string.format("units %d and %d overlap", i, j)
                assert.is_false(overlaps(u, units[j]), msg)
            end
        end
        assert.are.equal(160 * 16 * 16, total)
    end)

    it("aligns to mapblocks, expanding a ragged box outward", function()
        local units = plan.units(p(1, 1, 1), p(2, 2, 2), 5)
        assert.are.equal(1, #units)
        assert.are.same(p(0, 0, 0), units[1].min)
        assert.are.same(p(15, 15, 15), units[1].max)
    end)

    it("splits a long box along its length", function()
        -- 160 nodes of x is two 5-mapblock units; y and z are one each.
        assert.are.equal(2, #plan.units(p(0, 0, 0), p(159, 15, 15), 5))
    end)

    it("clamps the last unit to the box rather than overhanging", function()
        local units = plan.units(p(0, 0, 0), p(95, 15, 15), 5)
        assert.are.equal(2, #units)
        assert.are.equal(95, units[2].max.x)
    end)
end)

describe("plan.clip_ops", function()
    local unit_lo, unit_hi = p(0, 0, 0), p(79, 79, 79)

    it("keeps original order", function()
        local ops = {
            { op = "fill_box", min = p(0, 0, 0), max = p(9, 9, 9), node = 1 },
            { op = "fill_box", min = p(0, 0, 0), max = p(9, 9, 9), node = 2 },
            { op = "fill_box", min = p(0, 0, 0), max = p(9, 9, 9), node = 3 },
        }
        local out = plan.clip_ops(ops, unit_lo, unit_hi)
        assert.are.same({ 1, 2, 3 }, { out[1].node, out[2].node, out[3].node })
    end)

    it("trims a box to the unit", function()
        local ops = { { op = "fill_box", min = p(-50, 0, 0), max = p(200, 9, 9), node = 0 } }
        local out = plan.clip_ops(ops, unit_lo, unit_hi)
        assert.are.equal(0, out[1].min.x)
        assert.are.equal(79, out[1].max.x)
    end)

    it("drops an op that misses the unit entirely", function()
        local ops = { { op = "fill_box", min = p(200, 0, 0), max = p(300, 9, 9), node = 0 } }
        assert.are.equal(0, #plan.clip_ops(ops, unit_lo, unit_hi))
    end)

    it("passes box-less ops through", function()
        local out = plan.clip_ops({ { op = "emerge" } }, unit_lo, unit_hi)
        assert.are.same({ { op = "emerge" } }, out)
    end)

    it("copies rather than mutating the caller's ops", function()
        local ops = { { op = "fill_box", min = p(-50, 0, 0), max = p(200, 9, 9), node = 0 } }
        plan.clip_ops(ops, unit_lo, unit_hi)
        assert.are.equal(-50, ops[1].min.x)
    end)

    it("carries every other field to the clipped copy", function()
        local ops = {
            {
                op = "fill_box_if",
                min = p(0, 0, 0),
                max = p(200, 9, 9),
                node = 2,
                param2 = 7,
                invert = true,
                matchset = { [0] = true },
            },
        }
        local out = plan.clip_ops(ops, unit_lo, unit_hi)
        assert.are.equal(7, out[1].param2)
        assert.is_true(out[1].invert)
        assert.is_true(out[1].matchset[0])
    end)
end)

-- This is the test the milestone exists for.
describe("unit-major equals op-major", function()
    -- Three mapblocks along x, one each in y and z, and units of a single
    -- mapblock: two seams, at x=16 and x=32. Small on purpose. What the
    -- equivalence needs is a seam, ops crossing it and a read margin above
    -- zero; volume adds cost and proves nothing further.
    local lo, hi = p(0, 0, 0), p(47, 15, 15)
    local BLOCKS, MARGIN = 1, 8

    --- Shell then carve, both crossing both seams.
    local function shell_and_carve()
        return {
            { op = "emerge" },
            { op = "fill_box", min = p(4, 2, 2), max = p(43, 13, 13), node = 1 },
            { op = "fill_box", min = p(9, 4, 4), max = p(38, 11, 11), node = 0 },
        }
    end

    it("agrees for a shell and a carve straddling the seam", function()
        local ops = shell_and_carve()
        local want = reference(ops, lo, hi)
        local got, spilled = unit_major(ops, lo, hi, BLOCKS, MARGIN)
        assert.are.same({}, spilled)
        assert.are.same(want, got)
    end)

    it("agrees when a conditional fill straddles the seam", function()
        local ops = {
            { op = "fill_box", min = p(4, 2, 2), max = p(43, 13, 13), node = 1 },
            {
                op = "fill_box_if",
                min = lo,
                max = hi,
                node = 2,
                matchset = { [EMPTY] = true },
            },
        }
        local want = reference(ops, lo, hi)
        local got, spilled = unit_major(ops, lo, hi, BLOCKS, MARGIN)
        assert.are.same({}, spilled)
        assert.are.same(want, got)
    end)

    it("agrees at every unit size, so the size is a free parameter", function()
        local ops = shell_and_carve()
        local want = reference(ops, lo, hi)
        for _, blocks in ipairs({ 1, 2, 3 }) do
            local got = unit_major(ops, lo, hi, blocks, MARGIN)
            assert.are.same(want, got, "mismatch at " .. blocks .. " mapblocks per unit")
        end
    end)

    -- The failure mode the plan names: grouping or sorting ops inside a unit.
    -- Reversing them must break the equivalence, or this fixture proves nothing.
    it("detects an op list walked out of order", function()
        local ops = shell_and_carve()
        local want = reference(ops, lo, hi)
        local reversed = { ops[1], ops[3], ops[2] }
        local got = unit_major(reversed, lo, hi, BLOCKS, MARGIN)
        assert.are_not.same(want, got)
    end)

    it("writes nothing outside a unit even with a wide read margin", function()
        local ops = { { op = "fill_box", min = p(0, 0, 0), max = p(159, 15, 15), node = 1 } }
        local _, spilled = unit_major(ops, lo, hi, BLOCKS, MARGIN)
        assert.are.same({}, spilled)
    end)
end)
