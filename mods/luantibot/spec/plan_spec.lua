local plan = require("plan")

local function p(x, y, z)
    return { x = x, y = y, z = z }
end

describe("plan.blockpos", function()
    it("maps a node position to its mapblock", function()
        assert.are.same(p(0, 0, 0), plan.blockpos(p(0, 0, 0)))
        assert.are.same(p(0, 0, 0), plan.blockpos(p(15, 15, 15)))
        assert.are.same(p(1, 0, 0), plan.blockpos(p(16, 0, 0)))
    end)

    -- Integer division toward zero would put -1 in block 0, which silently
    -- misaligns everything below the origin. Luanti floors.
    it("floors toward negative infinity", function()
        assert.are.same(p(-1, -1, -1), plan.blockpos(p(-1, -1, -1)))
        assert.are.same(p(-1, 0, 0), plan.blockpos(p(-16, 0, 0)))
        assert.are.same(p(-2, 0, 0), plan.blockpos(p(-17, 0, 0)))
    end)
end)

describe("plan.align", function()
    it("expands a box out to whole mapblocks", function()
        local a, b = plan.align(p(1, 1, 1), p(2, 2, 2))
        assert.are.same(p(0, 0, 0), a)
        assert.are.same(p(15, 15, 15), b)
    end)

    it("leaves an already-aligned box alone", function()
        local a, b = plan.align(p(0, 0, 0), p(15, 15, 15))
        assert.are.same(p(0, 0, 0), a)
        assert.are.same(p(15, 15, 15), b)
    end)

    it("aligns across the origin", function()
        local a, b = plan.align(p(-1, -1, -1), p(0, 0, 0))
        assert.are.same(p(-16, -16, -16), a)
        assert.are.same(p(15, 15, 15), b)
    end)

    it("normalises a box given corners in any order", function()
        local a, b = plan.align(p(20, 0, 0), p(0, 20, 0))
        assert.are.same(p(0, 0, 0), a)
        assert.are.same(p(31, 31, 15), b)
    end)
end)

describe("plan.emerge_bounds", function()
    it("covers the requested cube", function()
        local a, b = plan.emerge_bounds(p(0, 0, 0), 20)
        -- cube is [-20, 20]; blocks -2..1 on each axis
        assert.are.same(p(-32, -32, -32), a)
        assert.are.same(p(31, 31, 31), b)
    end)

    it("accepts radius 0 as the single containing mapblock", function()
        local a, b = plan.emerge_bounds(p(8, 8, 8), 0)
        assert.are.same(p(0, 0, 0), a)
        assert.are.same(p(15, 15, 15), b)
    end)

    it("rejects a negative radius", function()
        local a, err = plan.emerge_bounds(p(0, 0, 0), -1)
        assert.is_nil(a)
        assert.is_string(err)
    end)

    it("rejects non-integer coordinates", function()
        assert.is_nil(plan.emerge_bounds(p(0.5, 0, 0), 1))
        assert.is_nil(plan.emerge_bounds(p(0, 0, 0), 1.5))
    end)

    it("rejects non-finite coordinates", function()
        local inf = math.huge
        assert.is_nil(plan.emerge_bounds(p(inf, 0, 0), 1))
        assert.is_nil(plan.emerge_bounds(p(inf - inf, 0, 0), 1))
    end)

    it("rejects a malformed position", function()
        assert.is_nil(plan.emerge_bounds({ x = 0, y = 0 }, 1))
        assert.is_nil(plan.emerge_bounds(nil, 1))
        assert.is_nil(plan.emerge_bounds("0,0,0", 1))
    end)
end)

describe("plan.block_count", function()
    it("counts mapblocks in an aligned box", function()
        assert.are.equal(1, plan.block_count(p(0, 0, 0), p(15, 15, 15)))
        assert.are.equal(8, plan.block_count(p(0, 0, 0), p(31, 31, 31)))
    end)

    -- This is the number the emerge cap is applied to, so it must count the
    -- blocks actually touched, not the ones asked for.
    it("counts partially covered mapblocks", function()
        assert.are.equal(2, plan.block_count(p(0, 0, 0), p(16, 0, 0)))
    end)
end)
