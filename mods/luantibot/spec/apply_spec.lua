local apply = require("apply")

local function p(x, y, z)
    return { x = x, y = y, z = z }
end

--- A stand-in for Luanti's VoxelArea, using its actual index formula.
---
--- Deliberately not a permissive stub: `apply.fill_box` indexes once per row and
--- then walks x by increments, so a fake that ignored the stride layout would
--- let a wrong assumption pass. This one reproduces the engine's arithmetic, so
--- the tests fail if that assumption ever stops holding.
local function area(min, max)
    local ystride = max.x - min.x + 1
    local zstride = ystride * (max.y - min.y + 1)
    return {
        MinEdge = min,
        MaxEdge = max,
        ystride = ystride,
        zstride = zstride,
        index = function(self, x, y, z)
            return (z - self.MinEdge.z) * zstride
                + (y - self.MinEdge.y) * ystride
                + (x - self.MinEdge.x)
                + 1
        end,
    }
end

--- A buffer of `fill` covering the whole area, so a stray write is visible.
--- param2 starts at a sentinel of its own, so "was param2 written" and "was
--- content written" are separate questions in the assertions below.
local function blank(a, fill)
    local n = (a.MaxEdge.x - a.MinEdge.x + 1)
        * (a.MaxEdge.y - a.MinEdge.y + 1)
        * (a.MaxEdge.z - a.MinEdge.z + 1)
    local data, param2 = {}, {}
    for i = 1, n do
        data[i] = fill
        param2[i] = 99
    end
    return { data = data, param2 = param2 }
end

--- Every position in the area whose value is not `fill`, as "x,y,z" strings.
local function changed(buf, a, fill)
    local out = {}
    for z = a.MinEdge.z, a.MaxEdge.z do
        for y = a.MinEdge.y, a.MaxEdge.y do
            for x = a.MinEdge.x, a.MaxEdge.x do
                if buf.data[a:index(x, y, z)] ~= fill then
                    out[#out + 1] = string.format("%d,%d,%d", x, y, z)
                end
            end
        end
    end
    table.sort(out)
    return out
end

describe("apply.fill_box", function()
    local a, data
    before_each(function()
        a = area(p(0, 0, 0), p(3, 3, 3))
        data = blank(a, 0)
    end)

    it("writes a single-node box", function()
        assert.are.equal(1, apply.fill_box(data, a, p(1, 2, 3), p(1, 2, 3), 7))
        assert.are.same({ "1,2,3" }, changed(data, a, 0))
        assert.are.equal(7, data.data[a:index(1, 2, 3)])
    end)

    it("writes every node of a larger box and nothing else", function()
        assert.are.equal(8, apply.fill_box(data, a, p(0, 0, 0), p(1, 1, 1), 5))
        assert.are.same({
            "0,0,0",
            "0,0,1",
            "0,1,0",
            "0,1,1",
            "1,0,0",
            "1,0,1",
            "1,1,0",
            "1,1,1",
        }, changed(data, a, 0))
    end)

    it("fills the whole area", function()
        assert.are.equal(64, apply.fill_box(data, a, p(0, 0, 0), p(3, 3, 3), 9))
        assert.are.equal(64, #changed(data, a, 0))
    end)

    it("accepts corners in any order", function()
        assert.are.equal(8, apply.fill_box(data, a, p(1, 1, 1), p(0, 0, 0), 5))
        assert.are.equal(5, data.data[a:index(0, 0, 0)])
        assert.are.equal(5, data.data[a:index(1, 1, 1)])
    end)

    -- The two cases the plan calls out as where index bugs live.
    it("clips a box that overhangs the area", function()
        assert.are.equal(8, apply.fill_box(data, a, p(2, 2, 2), p(9, 9, 9), 4))
        assert.are.same({
            "2,2,2",
            "2,2,3",
            "2,3,2",
            "2,3,3",
            "3,2,2",
            "3,2,3",
            "3,3,2",
            "3,3,3",
        }, changed(data, a, 0))
    end)

    it("clips a box that overhangs the low corner", function()
        assert.are.equal(1, apply.fill_box(data, a, p(-5, -5, -5), p(0, 0, 0), 4))
        assert.are.same({ "0,0,0" }, changed(data, a, 0))
    end)

    it("writes nothing for a box entirely outside", function()
        assert.are.equal(0, apply.fill_box(data, a, p(10, 10, 10), p(20, 20, 20), 4))
        assert.are.same({}, changed(data, a, 0))
    end)

    it("writes nothing for a box outside on one axis only", function()
        assert.are.equal(0, apply.fill_box(data, a, p(0, 99, 0), p(3, 99, 3), 4))
        assert.are.same({}, changed(data, a, 0))
    end)

    it("handles an area not anchored at the origin", function()
        local b = area(p(-16, -16, -16), p(-13, -13, -13))
        local d = blank(b, 0)
        assert.are.equal(1, apply.fill_box(d, b, p(-16, -16, -16), p(-16, -16, -16), 3))
        assert.are.same({ "-16,-16,-16" }, changed(d, b, 0))
        assert.are.equal(3, d.data[1])
    end)

    it("stays inside the array when filling the far corner", function()
        local b = area(p(-2, -2, -2), p(1, 1, 1))
        local d = blank(b, 0)
        apply.fill_box(d, b, p(1, 1, 1), p(1, 1, 1), 6)
        assert.are.equal(6, d.data[64])
        assert.are.equal(nil, d.data[65])
    end)

    it("applies later ops over earlier ones at the same cell", function()
        apply.fill_box(data, a, p(0, 0, 0), p(3, 3, 3), 1)
        apply.fill_box(data, a, p(1, 1, 1), p(2, 2, 2), 2)
        assert.are.equal(1, data.data[a:index(0, 0, 0)])
        assert.are.equal(2, data.data[a:index(1, 1, 1)])
        assert.are.equal(2, data.data[a:index(2, 2, 2)])
        assert.are.equal(1, data.data[a:index(3, 3, 3)])
    end)
end)

--- A palette that maps wire index n to content id 100 + n.
local function fake_palette(size)
    return {
        size = size,
        id = function(_, index)
            if index < 0 or index >= size then
                return nil,
                    string.format("palette index %d is outside a palette of %d", index, size)
            end
            return 100 + index
        end,
    }
end

describe("apply.run", function()
    local a, data, pal
    before_each(function()
        a = area(p(0, 0, 0), p(3, 3, 3))
        data = blank(a, 0)
        pal = fake_palette(2)
    end)

    it("ignores emerge, which is already satisfied by then", function()
        assert.are.equal(0, apply.run(data, a, { { op = "emerge" } }, pal))
        assert.are.same({}, changed(data, a, 0))
    end)

    it("applies a single fill_box through the palette", function()
        local ops = { { op = "fill_box", min = p(1, 1, 1), max = p(1, 1, 1), node = 1 } }
        assert.are.equal(1, apply.run(data, a, ops, pal))
        assert.are.equal(101, data.data[a:index(1, 1, 1)])
    end)

    -- Original order is the contract. Shell before carve depends on it.
    it("applies ops in the order given, later winning at a shared cell", function()
        local ops = {
            { op = "fill_box", min = p(0, 0, 0), max = p(3, 3, 3), node = 1 },
            { op = "fill_box", min = p(1, 1, 1), max = p(2, 2, 2), node = 0 },
        }
        assert.are.equal(64 + 8, apply.run(data, a, ops, pal))
        assert.are.equal(101, data.data[a:index(0, 0, 0)])
        assert.are.equal(100, data.data[a:index(1, 1, 1)])
        assert.are.equal(101, data.data[a:index(3, 3, 3)])
    end)

    it("reports the total nodes written across ops", function()
        local ops = {
            { op = "emerge" },
            { op = "fill_box", min = p(0, 0, 0), max = p(1, 1, 1), node = 0 },
            { op = "fill_box", min = p(2, 2, 2), max = p(3, 3, 3), node = 1 },
        }
        assert.are.equal(16, apply.run(data, a, ops, pal))
    end)

    it("fails on a palette index with no entry behind it", function()
        local ops = { { op = "fill_box", min = p(0, 0, 0), max = p(1, 1, 1), node = 5 } }
        local n, code, message = apply.run(data, a, ops, pal)
        assert.is_nil(n)
        assert.are.equal("bad_node", code)
        assert.matches("op 1", message)
    end)

    it("stops at the failing op rather than applying the rest", function()
        local ops = {
            { op = "fill_box", min = p(0, 0, 0), max = p(0, 0, 0), node = 0 },
            { op = "fill_box", min = p(1, 1, 1), max = p(1, 1, 1), node = 9 },
            { op = "fill_box", min = p(2, 2, 2), max = p(2, 2, 2), node = 1 },
        }
        local n, code = apply.run(data, a, ops, pal)
        assert.is_nil(n)
        assert.are.equal("bad_node", code)
        assert.are.equal(0, data.data[a:index(2, 2, 2)])
    end)

    -- validate.lua refuses these first; this is the drift guard behind it.
    it("fails on an op with no handler", function()
        local n, code = apply.run(data, a, { { op = "summon_dragon" } }, pal)
        assert.is_nil(n)
        assert.are.equal("unknown_op", code)
    end)
end)

-- The seam that shipped a crash: ops arrive from core.parse_json with array
-- corners, `{[1]=x, [2]=y, [3]=z}`, while everything below expects `{x=,y=,z=}`.
-- Every test above uses positions, so none of them could have caught it. These
-- start from a document shaped exactly as the wire delivers one.
describe("wire ops through validate into apply", function()
    local validate = require("validate")({
        version = require("version"),
        plan = require("plan"),
    })

    local function wire_job(ops)
        return {
            format = 1,
            job_id = 7,
            world_id = 3,
            world = "TestWorld",
            palette = { "stone" },
            bounds = { min = { 0, 0, 0 }, max = { 15, 15, 15 } },
            ops = ops,
        }
    end

    local a, data, pal
    before_each(function()
        a = area(p(0, 0, 0), p(3, 3, 3))
        data = blank(a, 0)
        pal = fake_palette(2)
    end)

    it("converts array corners to positions", function()
        local job =
            wire_job({ { op = "fill_box", min = { 1, 2, 3 }, max = { 4, 5, 6 }, node = 0 } })
        local ops = validate.ops_as_positions(job)
        assert.are.same(p(1, 2, 3), ops[1].min)
        assert.are.same(p(4, 5, 6), ops[1].max)
        assert.are.equal("fill_box", ops[1].op)
        assert.are.equal(0, ops[1].node)
    end)

    it("leaves the job document in the shape it arrived in", function()
        local job =
            wire_job({ { op = "fill_box", min = { 1, 2, 3 }, max = { 4, 5, 6 }, node = 0 } })
        validate.ops_as_positions(job)
        assert.are.same({ 1, 2, 3 }, job.ops[1].min)
    end)

    it("passes emerge through untouched", function()
        local ops = validate.ops_as_positions(wire_job({ { op = "emerge" } }))
        assert.are.same({ { op = "emerge" } }, ops)
    end)

    it("applies a wire-shaped fill_box to the right cells", function()
        local job = wire_job({
            { op = "emerge" },
            { op = "fill_box", min = { 1, 1, 1 }, max = { 2, 2, 2 }, node = 1 },
        })
        assert.is_true(validate.job(job, { world_id = 3, max_blocks = 4096 }))

        local written = apply.run(data, a, validate.ops_as_positions(job), pal)
        assert.are.equal(8, written)
        assert.are.same({
            "1,1,1",
            "1,1,2",
            "1,2,1",
            "1,2,2",
            "2,1,1",
            "2,1,2",
            "2,2,1",
            "2,2,2",
        }, changed(data, a, 0))
    end)
end)

-- param2 carries orientation, slab half, dye colour. A fill replaces the node
-- outright, so it must set param2 too: inheriting the facing of whatever was
-- overwritten is how a trapdoor ends up hinged on the wrong side.
describe("apply.fill_box param2", function()
    local a, buf
    before_each(function()
        a = area(p(0, 0, 0), p(3, 3, 3))
        buf = blank(a, 0) -- param2 pre-filled with the sentinel 99
    end)

    it("writes the given param2 alongside the content id", function()
        apply.fill_box(buf, a, p(1, 1, 1), p(2, 2, 2), 7, 3)
        assert.are.equal(7, buf.data[a:index(1, 1, 1)])
        assert.are.equal(3, buf.param2[a:index(1, 1, 1)])
        assert.are.equal(3, buf.param2[a:index(2, 2, 2)])
    end)

    it("defaults to 0 rather than leaving the old value", function()
        apply.fill_box(buf, a, p(1, 1, 1), p(1, 1, 1), 7)
        assert.are.equal(0, buf.param2[a:index(1, 1, 1)])
    end)

    it("leaves param2 outside the box alone", function()
        apply.fill_box(buf, a, p(1, 1, 1), p(1, 1, 1), 7, 3)
        assert.are.equal(99, buf.param2[a:index(0, 0, 0)])
        assert.are.equal(99, buf.param2[a:index(3, 3, 3)])
    end)

    it("clips param2 writes exactly as it clips content", function()
        apply.fill_box(buf, a, p(2, 2, 2), p(9, 9, 9), 4, 5)
        assert.are.equal(5, buf.param2[a:index(3, 3, 3)])
        assert.are.equal(99, buf.param2[a:index(1, 1, 1)])
    end)

    it("writes no param2 for a box entirely outside", function()
        apply.fill_box(buf, a, p(10, 10, 10), p(20, 20, 20), 4, 5)
        for i = 1, 64 do
            assert.are.equal(99, buf.param2[i])
        end
    end)

    it("lets a later op overwrite an earlier param2", function()
        apply.fill_box(buf, a, p(0, 0, 0), p(3, 3, 3), 1, 2)
        apply.fill_box(buf, a, p(1, 1, 1), p(2, 2, 2), 1, 4)
        assert.are.equal(2, buf.param2[a:index(0, 0, 0)])
        assert.are.equal(4, buf.param2[a:index(1, 1, 1)])
    end)
end)

describe("apply.run param2", function()
    local a, buf, pal
    before_each(function()
        a = area(p(0, 0, 0), p(3, 3, 3))
        buf = blank(a, 0)
        pal = fake_palette(2)
    end)

    it("passes an op's param2 through", function()
        local op = { op = "fill_box", min = p(1, 1, 1), max = p(1, 1, 1), node = 1, param2 = 12 }
        apply.run(buf, a, { op }, pal)
        assert.are.equal(101, buf.data[a:index(1, 1, 1)])
        assert.are.equal(12, buf.param2[a:index(1, 1, 1)])
    end)

    it("uses 0 when an op omits it", function()
        local ops = { { op = "fill_box", min = p(1, 1, 1), max = p(1, 1, 1), node = 1 } }
        apply.run(buf, a, ops, pal)
        assert.are.equal(0, buf.param2[a:index(1, 1, 1)])
    end)
end)

describe("apply.fill_box_if", function()
    local a, buf, MATCH
    before_each(function()
        a = area(p(0, 0, 0), p(3, 3, 3))
        buf = blank(a, 0) -- content 0 everywhere, param2 sentinel 99
        MATCH = { [0] = true } -- content 0 is the "empty" the tests fill
    end)

    it("writes where the predicate holds", function()
        assert.are.equal(8, apply.fill_box_if(buf, a, p(0, 0, 0), p(1, 1, 1), 5, 0, MATCH))
        assert.are.equal(5, buf.data[a:index(0, 0, 0)])
        assert.are.equal(5, buf.data[a:index(1, 1, 1)])
    end)

    it("leaves cells the predicate rejects alone", function()
        buf.data[a:index(1, 1, 1)] = 42
        assert.are.equal(7, apply.fill_box_if(buf, a, p(0, 0, 0), p(1, 1, 1), 5, 0, MATCH))
        assert.are.equal(42, buf.data[a:index(1, 1, 1)])
        assert.are.equal(99, buf.param2[a:index(1, 1, 1)])
    end)

    -- The plan's done-criterion: a pillar dropped from above stops at the
    -- ground, with nobody having computed the terrain height.
    it("stops at solid ground, which is what makes a pillar work", function()
        for y = 0, 1 do
            for x = 0, 3 do
                for z = 0, 3 do
                    buf.data[a:index(x, y, z)] = 42 -- rock at y0..y1
                end
            end
        end
        local n = apply.fill_box_if(buf, a, p(1, 0, 1), p(1, 3, 1), 5, 0, MATCH)
        assert.are.equal(2, n) -- only y2 and y3 were air
        assert.are.equal(42, buf.data[a:index(1, 0, 1)])
        assert.are.equal(42, buf.data[a:index(1, 1, 1)])
        assert.are.equal(5, buf.data[a:index(1, 2, 1)])
        assert.are.equal(5, buf.data[a:index(1, 3, 1)])
    end)

    it("inverts the predicate, which is how a shaft carves upward", function()
        buf.data[a:index(1, 0, 1)] = 42
        buf.data[a:index(1, 1, 1)] = 42
        local n = apply.fill_box_if(buf, a, p(1, 0, 1), p(1, 3, 1), 0, 0, MATCH, true)
        assert.are.equal(2, n) -- the two solid cells became content 0
        assert.are.equal(0, buf.data[a:index(1, 0, 1)])
        assert.are.equal(0, buf.data[a:index(1, 3, 1)])
    end)

    it("counts cells changed, not the size of the box", function()
        buf.data[a:index(0, 0, 0)] = 42
        assert.are.equal(63, apply.fill_box_if(buf, a, p(0, 0, 0), p(3, 3, 3), 5, 0, MATCH))
    end)

    it("returns zero when nothing matches", function()
        assert.are.equal(0, apply.fill_box_if(buf, a, p(0, 0, 0), p(3, 3, 3), 5, 0, {}))
        assert.are.same({}, changed(buf, a, 0))
    end)

    it("writes param2 only on the cells it changes", function()
        buf.data[a:index(1, 1, 1)] = 42
        apply.fill_box_if(buf, a, p(0, 0, 0), p(1, 1, 1), 5, 7, MATCH)
        assert.are.equal(7, buf.param2[a:index(0, 0, 0)])
        assert.are.equal(99, buf.param2[a:index(1, 1, 1)])
    end)

    it("clips to the area like fill_box does", function()
        assert.are.equal(0, apply.fill_box_if(buf, a, p(9, 9, 9), p(12, 12, 12), 5, 0, MATCH))
    end)
end)

describe("apply.run with fill_box_if", function()
    local a, buf, pal
    before_each(function()
        a = area(p(0, 0, 0), p(3, 3, 3))
        buf = blank(a, 0)
        pal = fake_palette(2)
    end)

    it("uses the compiled match set", function()
        local op = {
            op = "fill_box_if",
            min = p(0, 0, 0),
            max = p(1, 1, 1),
            node = 1,
            matchset = { [0] = true },
        }
        assert.are.equal(8, apply.run(buf, a, { op }, pal))
        assert.are.equal(101, buf.data[a:index(0, 0, 0)])
    end)

    it("honours invert through run", function()
        buf.data[a:index(0, 0, 0)] = 42
        local op = {
            op = "fill_box_if",
            min = p(0, 0, 0),
            max = p(1, 1, 1),
            node = 1,
            matchset = { [0] = true },
            invert = true,
        }
        assert.are.equal(1, apply.run(buf, a, { op }, pal))
        assert.are.equal(101, buf.data[a:index(0, 0, 0)])
    end)

    -- The same guard fill_box has. Covered separately because the two ops
    -- resolve the palette independently, and only fill_box's branch was tested.
    it("fails on a palette index with no entry behind it", function()
        local op = {
            op = "fill_box_if",
            min = p(0, 0, 0),
            max = p(1, 1, 1),
            node = 9,
            matchset = { [0] = true },
        }
        local n, code, message = apply.run(buf, a, { op }, pal)
        assert.is_nil(n)
        assert.are.equal("bad_node", code)
        assert.matches("op 1", message)
    end)

    -- A missing set would match nothing and quietly build a hole where a
    -- pillar was asked for, so it fails loudly instead.
    it("fails when the match set was never compiled", function()
        local op = { op = "fill_box_if", min = p(0, 0, 0), max = p(1, 1, 1), node = 1 }
        local n, code = apply.run(buf, a, { op }, pal)
        assert.is_nil(n)
        assert.are.equal("bad_match", code)
    end)

    it("counts as a writing op", function()
        assert.is_true(apply.writes({ { op = "fill_box_if" } }))
        assert.is_false(apply.writes({ { op = "emerge" } }))
    end)
end)

describe("apply survey op", function()
    local a, buf, pal
    before_each(function()
        a = area(p(0, 0, 0), p(3, 3, 3))
        buf = blank(a, 0)
        pal = fake_palette(2)
    end)

    local function env()
        return {
            survey = require("survey")({
                walkable = function(id)
                    return id ~= 0
                end,
                name = function(id)
                    return "id" .. tostring(id)
                end,
            }),
        }
    end

    it("counts as a read but not as a write", function()
        local ops = { { op = "survey", min = p(0, 0, 0), max = p(3, 3, 3) } }
        assert.is_true(apply.reads(ops))
        assert.is_false(apply.writes(ops))
    end)

    it("gathers columns into the environment without touching the buffer", function()
        buf.data[a:index(1, 2, 1)] = 5 -- something for the survey to find
        local before = changed(buf, a, 0)

        local ops = { { op = "survey", min = p(0, 0, 0), max = p(3, 3, 3), step = 1 } }
        local e = env()

        assert.are.equal(0, apply.run(buf, a, ops, pal, e))
        assert.are.same(before, changed(buf, a, 0), "a survey must leave the buffer alone")
        assert.are.equal(2, e.out["1,1"].y)
    end)

    -- Same shape as the missing matchset guard: reaching here means the caller
    -- skipped a preparation step, and answering with an empty survey would look
    -- like flat terrain rather than a mistake.
    it("fails when no environment was supplied", function()
        local ops = { { op = "survey", min = p(0, 0, 0), max = p(1, 1, 1) } }
        local n, code = apply.run(buf, a, ops, pal)
        assert.is_nil(n)
        assert.are.equal("bad_op", code)
    end)
end)

describe("apply restore op", function()
    local a, buf, pal
    before_each(function()
        a = area(p(0, 0, 0), p(3, 3, 3))
        buf = blank(a, 0)
        pal = fake_palette(2)
    end)

    local function op()
        return { op = "restore", job = 7, min = p(0, 0, 0), max = p(1, 1, 1) }
    end

    it("counts as both a read and a write", function()
        assert.is_true(apply.reads({ op() }))
        assert.is_true(apply.writes({ op() }))
    end)

    -- The bug the integration oracle caught: a snapshot covers the whole unit,
    -- while the op's box has been clipped to the part of it the caller asked
    -- about. Restoring into the box would be the wrong size whenever the
    -- caller's region was not mapblock-aligned.
    it("restores the unit, not the clipped op box", function()
        local seen
        local env = {
            unit_index = 4,
            unit_min = p(0, 0, 0),
            unit_max = p(3, 3, 3),
            restore = function(index, _, _, lo, hi)
                seen = { index = index, lo = lo, hi = hi }
                return 8
            end,
        }
        -- The op's box is 2x2x2 inside a 4x4x4 unit.
        assert.are.equal(8, apply.run(buf, a, { op() }, pal, env))
        assert.are.equal(4, seen.index)
        assert.are.same(p(0, 0, 0), seen.lo)
        assert.are.same(p(3, 3, 3), seen.hi, "restored the op box instead of the unit")
    end)

    it("passes a failure straight through", function()
        local env = {
            unit_index = 0,
            unit_min = p(0, 0, 0),
            unit_max = p(1, 1, 1),
            restore = function()
                return nil, "snapshot_missing", "no snapshot at /x/0.bin"
            end,
        }
        local n, code = apply.run(buf, a, { op() }, pal, env)
        assert.is_nil(n)
        assert.are.equal("snapshot_missing", code)
    end)

    it("fails without an environment that can load snapshots", function()
        local n, code = apply.run(buf, a, { op() }, pal, {})
        assert.is_nil(n)
        assert.are.equal("bad_op", code)
    end)

    -- Reaching here without one means the unit walk stopped setting it, and
    -- restoring the wrong unit's snapshot is silent corruption.
    it("fails when the unit index is missing", function()
        local n, code, message = apply.run(buf, a, { op() }, pal, {
            restore = function()
                return 1
            end,
        })
        assert.is_nil(n)
        assert.are.equal("bad_op", code)
        assert.matches("which unit", message)
    end)
end)
