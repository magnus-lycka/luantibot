-- Mod storage: the world's cached identity and the job that was running.
--
-- Small, but it is the durable half of two protocols. A wrong answer here does
-- not fail loudly -- it makes the mod adopt another world's id, or forget that
-- it died mid-job. Both matter more than the size of the module suggests.
--
-- Luanti's mod storage returns "" for a key that was never set, never nil, so
-- every read here has to treat empty and absent as the same thing.

local factory = require("storage")

--- Stands in for core.get_mod_storage(). Only get_string/set_string are used,
--- and the empty-string-for-missing behaviour is the point of the fake.
local function fake()
    local values = {}
    return values,
        {
            get_string = function(_, key)
                return values[key] or ""
            end,
            set_string = function(_, key, value)
                values[key] = value
            end,
        }
end

local function store()
    local values, backing = fake()
    return factory({ storage = backing }), values
end

describe("storage world id", function()
    it("is nil before anything is stored", function()
        local s = store()
        assert.is_nil(s.world_id())
    end)

    it("round-trips a number", function()
        local s = store()
        s.set_world_id(7)
        assert.are.equal(7, s.world_id())
    end)

    -- Stored as a string, so this is the conversion that matters.
    it("returns a number, not the string it was stored as", function()
        local s, values = store()
        s.set_world_id(12)
        assert.are.equal("12", values.world_id)
        assert.are.equal("number", type(s.world_id()))
    end)

    it("treats an empty value as absent", function()
        local s = store()
        s.set_world_id(3)
        s.clear()
        assert.is_nil(s.world_id())
    end)

    it("survives being cleared twice", function()
        local s = store()
        s.clear()
        s.clear()
        assert.is_nil(s.world_id())
    end)
end)

describe("storage current job", function()
    it("is nil before anything is stored", function()
        local s = store()
        assert.is_nil(s.job_id())
    end)

    it("round-trips a job id as a number", function()
        local s = store()
        s.set_job_id(1806)
        assert.are.equal(1806, s.job_id())
    end)

    -- Written before the first node is touched and cleared on a terminal state.
    -- A value surviving a restart is what the mod reports as `abandoned`.
    it("is cleared by setting nil", function()
        local s = store()
        s.set_job_id(1806)
        s.set_job_id(nil)
        assert.is_nil(s.job_id())
    end)

    it("keeps the job id independent of the world id", function()
        local s = store()
        s.set_world_id(2)
        s.set_job_id(99)

        s.set_job_id(nil)
        assert.are.equal(2, s.world_id())

        s.set_job_id(99)
        s.clear()
        assert.are.equal(99, s.job_id())
    end)
end)
