local factory = require("match")

local KNOWN = {
    ["air"] = 126,
    ["mcl_core:stone"] = 1,
    ["mcl_core:water_source"] = 9,
    ["mcl_core:lava_source"] = 10,
    ["mcl_core:sand"] = 12,
    ["ignore"] = 127,
}

local GROUPS = {
    liquid = { 9, 10 },
    falling_node = { 12 },
    empty_group = {},
}

local function match(known, groups)
    return factory({
        resolve = function(name)
            return (known or KNOWN)[name]
        end,
        ids_in_group = function(group)
            return (groups or GROUPS)[group] or {}
        end,
    })
end

describe("match.compile", function()
    it("resolves plain node names to a set of ids", function()
        local set = match().compile({ "air", "mcl_core:stone" })
        assert.is_true(set[126])
        assert.is_true(set[1])
        assert.is_nil(set[9])
    end)

    it("expands a group to every id in it", function()
        local set = match().compile({ "group:liquid" })
        assert.is_true(set[9])
        assert.is_true(set[10])
        assert.is_nil(set[126])
    end)

    it("mixes names and groups, which is the usual case", function()
        -- The tunnel shell predicate from the plan.
        local set = match().compile({ "air", "group:liquid", "group:falling_node" })
        assert.is_true(set[126])
        assert.is_true(set[9])
        assert.is_true(set[10])
        assert.is_true(set[12])
        assert.is_nil(set[1])
    end)

    it("de-duplicates overlapping entries", function()
        local set = match().compile({ "mcl_core:water_source", "group:liquid" })
        assert.is_true(set[9])
        local n = 0
        for _ in pairs(set) do
            n = n + 1
        end
        assert.are.equal(2, n)
    end)

    -- A game with no falling nodes is unusual, not malformed.
    it("accepts a group that matches nothing", function()
        local set = match().compile({ "group:empty_group" })
        assert.are.same({}, set)
    end)

    it("rejects an unknown node", function()
        local set, code, message = match().compile({ "mcl_core:nope" })
        assert.is_nil(set)
        assert.are.equal("unknown_node", code)
        assert.matches("mcl_core:nope", message)
    end)

    it("rejects ignore, which means the emerge did not happen", function()
        local set, code = match().compile({ "ignore" })
        assert.is_nil(set)
        assert.are.equal("bad_match", code)
    end)

    it("rejects an empty group name", function()
        local set, code = match().compile({ "group:" })
        assert.is_nil(set)
        assert.are.equal("bad_match", code)
    end)

    it("rejects an empty match list", function()
        local set, code = match().compile({})
        assert.is_nil(set)
        assert.are.equal("bad_match", code)
    end)

    it("rejects a match that is not a list", function()
        assert.is_nil(match().compile("air"))
        assert.is_nil(match().compile(nil))
    end)

    it("rejects a non-string entry", function()
        local set, code = match().compile({ 7 })
        assert.is_nil(set)
        assert.are.equal("bad_match", code)
    end)
end)

describe("match.prepare", function()
    it("attaches a compiled set to every fill_box_if", function()
        local ops = {
            { op = "emerge" },
            { op = "fill_box", node = 0 },
            { op = "fill_box_if", node = 0, match = { "air" } },
        }
        local out = match().prepare(ops)
        assert.are.equal(ops, out)
        assert.is_nil(ops[1].matchset)
        assert.is_nil(ops[2].matchset)
        assert.is_true(ops[3].matchset[126])
    end)

    it("compiles each op's own predicate", function()
        local ops = {
            { op = "fill_box_if", node = 0, match = { "air" } },
            { op = "fill_box_if", node = 0, match = { "group:liquid" } },
        }
        match().prepare(ops)
        assert.is_true(ops[1].matchset[126])
        assert.is_nil(ops[1].matchset[9])
        assert.is_true(ops[2].matchset[9])
    end)

    it("reports which op failed", function()
        local ops = {
            { op = "fill_box_if", node = 0, match = { "air" } },
            { op = "fill_box_if", node = 0, match = { "mcl_core:nope" } },
        }
        local out, code, message = match().prepare(ops)
        assert.is_nil(out)
        assert.are.equal("unknown_node", code)
        assert.matches("op 2", message)
    end)
end)
