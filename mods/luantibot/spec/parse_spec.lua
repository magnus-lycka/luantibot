local parse = require("parse")

describe("parse.emerge_args", function()
    it("parses four integers", function()
        local centre, radius = parse.emerge_args("10 20 30 40")
        assert.are.same({ x = 10, y = 20, z = 30 }, centre)
        assert.are.equal(40, radius)
    end)

    it("tolerates extra whitespace", function()
        local centre, radius = parse.emerge_args("  -5   0\t7  16 ")
        assert.are.same({ x = -5, y = 0, z = 7 }, centre)
        assert.are.equal(16, radius)
    end)

    it("rejects the wrong number of arguments", function()
        assert.is_nil(parse.emerge_args("1 2 3"))
        assert.is_nil(parse.emerge_args("1 2 3 4 5"))
        assert.is_nil(parse.emerge_args(""))
        assert.is_nil(parse.emerge_args(nil))
    end)

    it("rejects non-numeric arguments", function()
        assert.is_nil(parse.emerge_args("a b c d"))
        assert.is_nil(parse.emerge_args("1 2 3 here"))
    end)

    -- "1e400" parses as inf via tonumber, and "0x10" as 16. Neither is a
    -- coordinate a human typed, and inf would reach emerge_area as a bound.
    it("rejects non-integer and non-finite numbers", function()
        assert.is_nil(parse.emerge_args("1.5 2 3 4"))
        assert.is_nil(parse.emerge_args("1 2 3 4.5"))
        assert.is_nil(parse.emerge_args("1e400 2 3 4"))
    end)

    it("returns a message explaining the rejection", function()
        local centre, err = parse.emerge_args("nope")
        assert.is_nil(centre)
        assert.is_string(err)
    end)
end)
