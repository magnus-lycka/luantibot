local identity = require("identity")

-- `identity.armed` and the `luantibot_world` setting behind it are gone on
-- purpose. A single global world name capped the system at one world, which
-- contradicts routing jobs per `world_id` so several servers can build at once.
-- Installing the mod in a world is the intent; what keeps it from building in
-- the wrong one is the world_id check in validate.lua, covered by its own spec.

describe("identity.world_name_from_path", function()
    it("takes the last path segment", function()
        assert.are.equal("TestWorld", identity.world_name_from_path("/a/b/worlds/TestWorld"))
    end)

    it("tolerates a trailing separator", function()
        assert.are.equal("TestWorld", identity.world_name_from_path("/a/b/worlds/TestWorld/"))
    end)

    it("handles a bare name", function()
        assert.are.equal("TestWorld", identity.world_name_from_path("TestWorld"))
    end)
end)

describe("identity.divergence", function()
    it("is silent when the names agree", function()
        assert.is_nil(identity.divergence("TestWorld", "TestWorld"))
    end)

    -- A legitimate rename and an accidental world copy look identical at this
    -- instant, so this warns and never refuses.
    it("warns when the service name differs from the local directory", function()
        local warning = identity.divergence("TestWorld", "TestWorld_copy")
        assert.is_string(warning)
        assert.is_truthy(warning:find("TestWorld"))
        assert.is_truthy(warning:find("TestWorld_copy"))
    end)

    it("is silent when the service name is not known yet", function()
        assert.is_nil(identity.divergence(nil, "TestWorld"))
    end)
end)

describe("identity.describe", function()
    it("renders an unregistered server", function()
        local text = identity.describe(nil, nil, "TestWorld")
        assert.is_truthy(text:find("unregistered"))
    end)

    it("renders id, service name and local directory", function()
        local text = identity.describe(3, "TestWorld", "TestWorld")
        assert.is_truthy(text:find("3"))
        assert.is_truthy(text:find("TestWorld"))
    end)
end)
