local factory = require("survey")

local function p(x, y, z)
    return { x = x, y = y, z = z }
end

-- Content ids. The distinction the module exists for: 1 and 2 are things you
-- stand on, 3 and 4 are nodes that are not.
local AIR, STONE, DIRT, GRASS, TRAPDOOR = 0, 1, 2, 3, 4
local WALKABLE = { [STONE] = true, [DIRT] = true }
local NAMES = {
    [AIR] = "air",
    [STONE] = "mcl_core:stone",
    [DIRT] = "mcl_core:dirt",
    [GRASS] = "mcl_flowers:tallgrass",
    [TRAPDOOR] = "mcl_doors:iron_trapdoor",
}

local survey = factory({
    walkable = function(id)
        return WALKABLE[id] == true
    end,
    name = function(id)
        return NAMES[id]
    end,
})

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

local function world(a)
    local n = (a.MaxEdge.x - a.MinEdge.x + 1)
        * (a.MaxEdge.y - a.MinEdge.y + 1)
        * (a.MaxEdge.z - a.MinEdge.z + 1)
    local data = {}
    for i = 1, n do
        data[i] = AIR
    end
    return { data = data }
end

--- Fill a column from `lo` up to and including `hi` with `id`.
local function column(buf, a, x, z, lo, hi, id)
    for y = lo, hi do
        buf.data[a:index(x, y, z)] = id
    end
end

local function only(found)
    assert.are.equal(1, #found)
    return found[1]
end

describe("survey.columns", function()
    local a, buf
    before_each(function()
        a = area(p(0, 0, 0), p(7, 31, 7))
        buf = world(a)
    end)

    it("reports the height and the node of the surface", function()
        column(buf, a, 0, 0, 0, 9, STONE)
        local c = only(survey.columns(buf, a, p(0, 0, 0), p(0, 31, 0), 1))
        assert.are.equal(9, c.y)
        assert.are.equal("mcl_core:stone", c.node)
        assert.are.equal(0, c.x)
        assert.are.equal(0, c.z)
    end)

    -- The lesson this module exists for.
    it("looks past a node you cannot stand on", function()
        column(buf, a, 0, 0, 0, 9, DIRT)
        buf.data[a:index(0, 10, 0)] = GRASS

        local c = only(survey.columns(buf, a, p(0, 0, 0), p(0, 31, 0), 1))
        assert.are.equal(9, c.y, "tallgrass at y10 is not a surface")
        assert.are.equal("mcl_core:dirt", c.node)
    end)

    it("looks past a trapdoor, which fills almost none of its cell", function()
        column(buf, a, 0, 0, 0, 5, STONE)
        buf.data[a:index(0, 20, 0)] = TRAPDOOR

        assert.are.equal(5, only(survey.columns(buf, a, p(0, 0, 0), p(0, 31, 0), 1)).y)
    end)

    it("reports no height for a column of air", function()
        local c = only(survey.columns(buf, a, p(0, 0, 0), p(0, 31, 0), 1))
        assert.is_nil(c.y)
        assert.is_nil(c.node)
        assert.are.equal(0, c.x)
    end)

    -- Scanning up from the floor would answer with the cave's own floor.
    it("finds the surface above a cave, not the rock below it", function()
        column(buf, a, 0, 0, 0, 4, STONE) -- floor
        column(buf, a, 0, 0, 5, 8, AIR) -- void
        column(buf, a, 0, 0, 9, 12, STONE) -- roof and surface

        assert.are.equal(12, only(survey.columns(buf, a, p(0, 0, 0), p(0, 31, 0), 1)).y)
    end)

    it("scans only within the box it was given", function()
        column(buf, a, 0, 0, 0, 20, STONE)
        local c = only(survey.columns(buf, a, p(0, 0, 0), p(0, 10, 0), 1))
        assert.are.equal(10, c.y, "the box stops at y10, so the answer must too")
    end)

    it("visits every column at step 1", function()
        local found = survey.columns(buf, a, p(0, 0, 0), p(3, 31, 3), 1)
        assert.are.equal(16, #found)
    end)

    it("downsamples on both axes", function()
        local found = survey.columns(buf, a, p(0, 0, 0), p(7, 31, 7), 4)
        assert.are.equal(4, #found)
        for _, c in ipairs(found) do
            assert.are.equal(0, c.x % 4)
            assert.are.equal(0, c.z % 4)
        end
    end)

    -- Absolute anchoring would mean a box containing no multiple of the step --
    -- a single line at an odd coordinate -- reported nothing at all.
    it("starts the grid at the box when no anchor is given", function()
        local b = area(p(-16, 0, -16), p(15, 31, 15))
        local d = world(b)
        local found = survey.columns(d, b, p(-10, 0, -10), p(10, 31, 10), 8)

        assert.are.equal(9, #found) -- -10, -2, 6 on each axis
        assert.are.equal(-10, found[1].x)
        assert.are.equal(-10, found[1].z)
    end)

    it("samples a single line whatever its coordinate", function()
        local b = area(p(-16, 0, -16), p(15, 31, 15))
        local d = world(b)
        column(d, b, 0, -7, 0, 4, STONE)

        local found = survey.columns(d, b, p(-10, 0, -7), p(10, 31, -7), 8)
        assert.is_true(#found > 0, "a line at z=-7 must not vanish because 8 does not divide it")
        assert.are.equal(-7, found[1].z)
    end)

    -- The seam property. Two units see different clipped boxes; anchoring both
    -- to the caller's original corner is what stops the grid from shifting
    -- between them, which would duplicate columns on one side and drop them on
    -- the other.
    it("keeps one grid across boxes clipped differently", function()
        local b = area(p(0, 0, 0), p(63, 31, 63))
        local d = world(b)
        local anchor = p(5, 0, 5)

        local left = survey.columns(d, b, p(5, 0, 5), p(29, 31, 29), 8, anchor)
        local right = survey.columns(d, b, p(30, 0, 5), p(60, 31, 29), 8, anchor)

        local xs = {}
        for _, c in ipairs(left) do
            xs[c.x] = true
        end
        for _, c in ipairs(right) do
            assert.is_nil(xs[c.x], "column x=" .. c.x .. " sampled on both sides of the seam")
            assert.are.equal(5, c.x % 8, "the grid shifted between the two boxes")
        end
    end)
end)

describe("survey.merge", function()
    it("keeps the higher answer when a column spans two units", function()
        local acc = {}
        survey.merge(acc, { { x = 1, z = 2, y = 5, node = "low" } })
        survey.merge(acc, { { x = 1, z = 2, y = 40, node = "high" } })
        assert.are.equal(40, acc["1,2"].y)
        assert.are.equal("high", acc["1,2"].node)
    end)

    it("does not let a lower unit overwrite a higher one", function()
        local acc = {}
        survey.merge(acc, { { x = 1, z = 2, y = 40, node = "high" } })
        survey.merge(acc, { { x = 1, z = 2, y = 5, node = "low" } })
        assert.are.equal(40, acc["1,2"].y)
    end)

    -- An empty unit says "nothing solid here", which a unit below may contradict.
    it("lets a solid answer replace an empty one", function()
        local acc = {}
        survey.merge(acc, { { x = 1, z = 2 } })
        survey.merge(acc, { { x = 1, z = 2, y = 5, node = "rock" } })
        assert.are.equal(5, acc["1,2"].y)
    end)

    it("does not let an empty answer replace a solid one", function()
        local acc = {}
        survey.merge(acc, { { x = 1, z = 2, y = 5, node = "rock" } })
        survey.merge(acc, { { x = 1, z = 2 } })
        assert.are.equal(5, acc["1,2"].y)
    end)

    it("keeps distinct columns apart", function()
        local acc = {}
        survey.merge(acc, { { x = 1, z = 2, y = 5 }, { x = 2, z = 1, y = 9 } })
        assert.are.equal(5, acc["1,2"].y)
        assert.are.equal(9, acc["2,1"].y)
    end)
end)

describe("survey.finish", function()
    it("orders by z then x, so the result does not depend on unit order", function()
        local acc = {}
        survey.merge(acc, {
            { x = 5, z = 9, y = 1 },
            { x = 1, z = 9, y = 1 },
            { x = 3, z = 2, y = 1 },
        })
        local out = survey.finish(acc)
        assert.are.same({ { x = 3, z = 2 }, { x = 1, z = 9 }, { x = 5, z = 9 } }, {
            { x = out[1].x, z = out[1].z },
            { x = out[2].x, z = out[2].z },
            { x = out[3].x, z = out[3].z },
        })
    end)

    it("returns an empty array for an empty survey", function()
        assert.are.same({}, survey.finish({}))
    end)
end)
