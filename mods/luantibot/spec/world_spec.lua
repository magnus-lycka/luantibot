-- The contract world.build owes: a unit never writes outside itself.
--
-- Nothing downstream enforces it. apply.lua clips to the VoxelManip region,
-- which is at least the unit and usually larger, so containment comes from
-- clipping the ops before they are applied and from nothing else. These tests
-- hand the module a VoxelManip whose region is deliberately far bigger than the
-- unit, and fail if a single node lands outside.
--
-- This file also exists because world.lua acquired logic during M4 and had no
-- spec, which let a missing `deps.plan` reach the mod uncaught.

local plan = require("plan")
local apply = require("apply")

local function p(x, y, z)
    return { x = x, y = y, z = z }
end

local pal = {
    size = 4,
    id = function(_, i)
        return (i >= 0 and i < 4) and (100 + i) or nil
    end,
}

--- A fake engine. `pad` inflates every VoxelManip region beyond the unit it was
--- asked for, which is what the real one does and what makes containment worth
--- asserting. Every write is recorded with the region it covered.
local function engine(pad)
    pad = pad or 16
    local e = { emerges = {}, writes = {}, cancel_at = nil, blocks_per_unit = 7 }

    e.deps = {
        emerge = require("emerge"),
        apply = apply,
        plan = plan,

        emerge_area = function(p1, p2, on_block)
            e.emerges[#e.emerges + 1] = { min = p1, max = p2 }
            local n = e.blocks_per_unit
            for i = n, 1, -1 do
                local kind = (e.cancel_at == #e.emerges) and "cancelled" or "ok"
                on_block(kind, i - 1)
            end
        end,

        voxelmanip = function(p1, p2)
            local min = p(p1.x - pad, p1.y - pad, p1.z - pad)
            local max = p(p2.x + pad, p2.y + pad, p2.z + pad)
            local ystride = max.x - min.x + 1
            local zstride = ystride * (max.y - min.y + 1)
            local area = {
                MinEdge = min,
                MaxEdge = max,
                index = function(self, x, y, z)
                    return (z - self.MinEdge.z) * zstride
                        + (y - self.MinEdge.y) * ystride
                        + (x - self.MinEdge.x)
                        + 1
                end,
            }
            local n = ystride * (max.y - min.y + 1) * (max.z - min.z + 1)
            local data, param2 = {}, {}
            for i = 1, n do
                data[i], param2[i] = 0, 0
            end
            return {
                area = area,
                data = data,
                param2 = param2,
                write = function(written_data)
                    local cells = {}
                    for x = min.x, max.x do
                        for y = min.y, max.y do
                            for z = min.z, max.z do
                                if written_data[area:index(x, y, z)] ~= 0 then
                                    cells[#cells + 1] = p(x, y, z)
                                end
                            end
                        end
                    end
                    e.writes[#e.writes + 1] = { unit_min = p1, unit_max = p2, cells = cells }
                end,
            }
        end,
    }
    return e
end

local function build(e, p1, p2, ops)
    local world = require("world")(e.deps)
    local progress, result = {}, nil
    world.build(p1, p2, ops, pal, function(done, total, written)
        progress[#progress + 1] = { done = done, total = total, written = written }
    end, function(r)
        result = r
    end)
    return result, progress
end

--- How many cells were written outside the unit that wrote them, and a couple
--- of examples.
---
--- Deliberately not the whole list. A broken clip puts hundreds of thousands of
--- cells outside, and an assertion carrying all of them makes busted format the
--- entire set into one failure string -- which is how this suite once took the
--- editor to 20 GB. A count plus two examples locates the bug just as well.
local EXAMPLES = 2

local function outside(e)
    local count, examples = 0, {}
    for _, w in ipairs(e.writes) do
        for _, c in ipairs(w.cells) do
            local inside = c.x >= w.unit_min.x
                and c.x <= w.unit_max.x
                and c.y >= w.unit_min.y
                and c.y <= w.unit_max.y
                and c.z >= w.unit_min.z
                and c.z <= w.unit_max.z
            if not inside then
                count = count + 1
                if #examples < EXAMPLES then
                    examples[#examples + 1] = string.format("%d,%d,%d", c.x, c.y, c.z)
                end
            end
        end
    end
    return { count = count, examples = examples }
end

local NONE = { count = 0, examples = {} }

describe("world.build containment", function()
    -- Two units of 5 mapblocks along x, so there is a seam at x=80.
    local lo, hi = p(0, 0, 0), p(159, 15, 15)

    it("writes nothing outside a unit, with a wide VoxelManip region", function()
        local e = engine(16)
        local ops = { { op = "fill_box", min = p(20, 2, 2), max = p(140, 13, 13), node = 1 } }
        local result = build(e, lo, hi, ops)
        assert.is_true(result.ok)
        assert.are.same(NONE, outside(e))
    end)

    it("holds for an op covering the whole of bounds", function()
        local e = engine(32)
        local ops = { { op = "fill_box", min = lo, max = hi, node = 1 } }
        build(e, lo, hi, ops)
        assert.are.same(NONE, outside(e))
    end)

    it("holds for a conditional fill", function()
        local e = engine(16)
        local ops = {
            {
                op = "fill_box_if",
                min = p(-999, -999, -999),
                max = p(999, 999, 999),
                node = 2,
                matchset = { [0] = true },
            },
        }
        build(e, lo, hi, ops)
        assert.are.same(NONE, outside(e))
    end)
end)

describe("world.build unit walk", function()
    local lo, hi = p(0, 0, 0), p(159, 15, 15)
    local function one_op()
        return { { op = "fill_box", min = lo, max = hi, node = 1 } }
    end

    it("visits every unit exactly once", function()
        local e = engine()
        build(e, lo, hi, one_op())
        assert.are.equal(#plan.units(lo, hi), #e.emerges)
    end)

    it("emerges each unit before writing it", function()
        local e = engine()
        build(e, lo, hi, one_op())
        for i, w in ipairs(e.writes) do
            assert.are.same(e.emerges[i].min, w.unit_min)
        end
    end)

    it("reports progress once per unit, cumulatively", function()
        local e = engine()
        local _, progress = build(e, lo, hi, one_op())
        assert.are.equal(2, #progress)
        assert.are.equal(1, progress[1].done)
        assert.are.equal(2, progress[1].total)
        assert.is_true(progress[2].written > progress[1].written)
    end)

    it("totals blocks and nodes across units", function()
        local e = engine()
        local result = build(e, lo, hi, one_op())
        assert.are.equal(2 * e.blocks_per_unit, result.blocks)
        assert.are.equal(160 * 16 * 16, result.written)
        assert.are.equal(2, result.units)
    end)

    -- The saving that makes a large bounds with small ops affordable.
    it("skips the VoxelManip for a unit no op touches", function()
        local e = engine()
        local ops = { { op = "fill_box", min = p(0, 0, 0), max = p(9, 9, 9), node = 1 } }
        build(e, lo, hi, ops)
        assert.are.equal(2, #e.emerges)
        assert.are.equal(1, #e.writes)
    end)

    it("never touches a VoxelManip for an emerge-only job", function()
        local e = engine()
        build(e, lo, hi, { { op = "emerge" } })
        assert.are.equal(2, #e.emerges)
        assert.are.equal(0, #e.writes)
    end)
end)

describe("world.build failure", function()
    local lo, hi = p(0, 0, 0), p(159, 15, 15)

    it("stops at a failed emerge rather than carrying on", function()
        local e = engine()
        e.cancel_at = 1
        local result = build(e, lo, hi, { { op = "fill_box", min = lo, max = hi, node = 1 } })
        assert.is_false(result.ok)
        assert.are.equal(1, #e.emerges)
        assert.are.equal(0, #e.writes)
    end)

    it("says how far it got", function()
        local e = engine()
        e.cancel_at = 2
        local result = build(e, lo, hi, { { op = "fill_box", min = lo, max = hi, node = 1 } })
        assert.is_false(result.ok)
        assert.are.equal(2, result.units)
        assert.are.equal(1, result.units_done)
    end)

    it("stops on a bad palette index without writing that unit", function()
        local e = engine()
        local ops = { { op = "fill_box", min = lo, max = hi, node = 9 } }
        local result = build(e, lo, hi, ops)
        assert.is_false(result.ok)
        assert.are.equal("bad_node", result.code)
        assert.are.equal(0, #e.writes)
    end)
end)
