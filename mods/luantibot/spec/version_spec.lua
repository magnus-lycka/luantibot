local version = require("version")

describe("version", function()
    it("accepts the current wire format", function()
        assert.is_true(version.supported(version.FORMAT))
    end)

    it("rejects other versions", function()
        assert.is_false(version.supported(version.FORMAT + 1))
        assert.is_false(version.supported(0))
    end)

    it("rejects missing or non-numeric formats", function()
        assert.is_false(version.supported(nil))
        assert.is_false(version.supported("1"))
    end)
end)
