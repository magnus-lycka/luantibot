local identity = require("identity")

describe("identity.armed", function()
    -- Fail closed: a mod installed globally rather than per-world must do
    -- nothing until deliberately pointed at a world.
    it("refuses when unconfigured", function()
        local ok, why = identity.armed(nil, "Marduk1")
        assert.is_false(ok)
        assert.is_string(why)
    end)

    it("refuses when the configured world is blank", function()
        assert.is_false(identity.armed("", "Marduk1"))
        assert.is_false(identity.armed("   ", "Marduk1"))
    end)

    it("refuses when configured for a different world", function()
        local ok, why = identity.armed("Marduk1", "SomeOtherWorld")
        assert.is_false(ok)
        assert.is_truthy(why:find("Marduk1"))
        assert.is_truthy(why:find("SomeOtherWorld"))
    end)

    it("arms when the configured world matches", function()
        assert.is_true(identity.armed("Marduk1", "Marduk1"))
    end)

    it("ignores surrounding whitespace in configuration", function()
        assert.is_true(identity.armed("  Marduk1  ", "Marduk1"))
    end)
end)

describe("identity.world_name_from_path", function()
    it("takes the last path segment", function()
        assert.are.equal("Marduk1", identity.world_name_from_path("/a/b/worlds/Marduk1"))
    end)

    it("tolerates a trailing separator", function()
        assert.are.equal("Marduk1", identity.world_name_from_path("/a/b/worlds/Marduk1/"))
    end)

    it("handles a bare name", function()
        assert.are.equal("Marduk1", identity.world_name_from_path("Marduk1"))
    end)
end)

describe("identity.divergence", function()
    it("is silent when the names agree", function()
        assert.is_nil(identity.divergence("Marduk1", "Marduk1"))
    end)

    -- A legitimate rename and an accidental world copy look identical at this
    -- instant, so this warns and never refuses.
    it("warns when the service name differs from the local directory", function()
        local warning = identity.divergence("Marduk1", "Marduk1_copy")
        assert.is_string(warning)
        assert.is_truthy(warning:find("Marduk1"))
        assert.is_truthy(warning:find("Marduk1_copy"))
    end)

    it("is silent when the service name is not known yet", function()
        assert.is_nil(identity.divergence(nil, "Marduk1"))
    end)
end)

describe("identity.describe", function()
    it("renders an unregistered server", function()
        local text = identity.describe(nil, nil, "Marduk1")
        assert.is_truthy(text:find("unregistered"))
    end)

    it("renders id, service name and local directory", function()
        local text = identity.describe(3, "Marduk1", "Marduk1")
        assert.is_truthy(text:find("3"))
        assert.is_truthy(text:find("Marduk1"))
    end)
end)
