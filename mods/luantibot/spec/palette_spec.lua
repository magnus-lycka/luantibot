local factory = require("palette")

--- A table-backed stand-in for core.get_content_id.
local KNOWN = {
    ["air"] = 126,
    ["mcl_core:stone"] = 1,
    ["mcl_core:stonebrick"] = 2,
    ["mcl_core:lava_source"] = 9,
    -- CONTENT_IGNORE resolves for real, which is why "ignore" has to be
    -- rejected by name rather than by failing to resolve.
    ["ignore"] = 127,
}

local function palette(known)
    return factory({
        resolve = function(name)
            return (known or KNOWN)[name]
        end,
    })
end

describe("palette.compile", function()
    it("resolves names to content ids in order", function()
        local pal = palette().compile({ "air", "mcl_core:stone" })
        assert.are.equal(2, pal.size)
        assert.are.equal(126, pal:id(0))
        assert.are.equal(1, pal:id(1))
    end)

    it("accepts an empty palette", function()
        local pal = palette().compile({})
        assert.are.equal(0, pal.size)
    end)

    it("rejects a name that does not resolve", function()
        local pal, code, message = palette().compile({ "air", "mcl_core:nope" })
        assert.is_nil(pal)
        assert.are.equal("unknown_node", code)
        assert.matches("mcl_core:nope", message)
        -- Reported by wire index, which is 0-based.
        assert.matches("entry 1", message)
    end)

    it("rejects ignore even though it resolves", function()
        local pal, code = palette().compile({ "ignore" })
        assert.is_nil(pal)
        assert.are.equal("bad_palette", code)
    end)

    it("rejects a group expression", function()
        local pal, code, message = palette().compile({ "group:liquid" })
        assert.is_nil(pal)
        assert.are.equal("bad_palette", code)
        assert.matches("group", message)
    end)

    it("rejects a denied name", function()
        local deny = { ["mcl_core:lava_source"] = true }
        local pal, code = palette().compile({ "air", "mcl_core:lava_source" }, deny)
        assert.is_nil(pal)
        assert.are.equal("denied_node", code)
    end)

    it("allows a denied name when the deny list is empty, which is the default", function()
        local pal = palette().compile({ "mcl_core:lava_source" }, {})
        assert.are.equal(9, pal:id(0))
    end)

    it("rejects a non-string entry", function()
        local pal, code = palette().compile({ 7 })
        assert.is_nil(pal)
        assert.are.equal("bad_palette", code)
    end)

    it("rejects a palette that is not a list", function()
        local pal, code = palette().compile("air")
        assert.is_nil(pal)
        assert.are.equal("bad_palette", code)
    end)
end)

describe("palette id lookup", function()
    local pal
    before_each(function()
        pal = palette().compile({ "air", "mcl_core:stone", "mcl_core:stonebrick" })
    end)

    it("is 0-based, matching the wire", function()
        assert.are.equal(126, pal:id(0))
        assert.are.equal(2, pal:id(2))
    end)

    it("refuses an index past the end", function()
        local id, message = pal:id(3)
        assert.is_nil(id)
        assert.matches("outside a palette of 3", message)
    end)

    it("refuses a negative index", function()
        assert.is_nil(pal:id(-1))
    end)

    it("refuses a non-integer index", function()
        assert.is_nil(pal:id(1.5))
        assert.is_nil(pal:id("1"))
        assert.is_nil(pal:id(nil))
    end)
end)

describe("palette.deny_set", function()
    it("splits on commas and whitespace", function()
        local deny = palette().deny_set("a:one, a:two  a:three")
        assert.is_true(deny["a:one"])
        assert.is_true(deny["a:two"])
        assert.is_true(deny["a:three"])
    end)

    it("is empty for nil or blank, which is the shipped default", function()
        assert.are.same({}, palette().deny_set(nil))
        assert.are.same({}, palette().deny_set(""))
        assert.are.same({}, palette().deny_set("   "))
    end)
end)
