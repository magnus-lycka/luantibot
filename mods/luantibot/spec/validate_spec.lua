local validate = require("validate")({ version = require("version") })

-- `{ world_id = nil }` in a table literal has no key at all, so a sentinel is
-- needed to express "remove this field" -- which is exactly what a malformed
-- job document looks like.
local NONE = {}

local function job(overrides)
    local j = { format = 1, job_id = 7, world_id = 3, world = "Marduk1", ops = {} }
    for k, v in pairs(overrides or {}) do
        j[k] = (v ~= NONE) and v or nil
    end
    return j
end

describe("validate.job", function()
    local ctx = { world_id = 3 }

    it("accepts a job for this world", function()
        local ok = validate.job(job(), ctx)
        assert.is_true(ok)
    end)

    it("rejects an unknown wire format", function()
        local ok, code = validate.job(job({ format = 99 }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_format", code)
    end)

    it("rejects a missing format", function()
        local ok, code = validate.job(job({ format = NONE }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_format", code)
    end)

    -- The guard that stops a job compiled for one world being applied to
    -- another. Irreversible once fill_box exists, so it must fail closed.
    it("rejects a job for a different world", function()
        local ok, code, msg = validate.job(job({ world_id = 4 }), ctx)
        assert.is_false(ok)
        assert.are.equal("wrong_world", code)
        assert.is_truthy(msg:find("4"))
        assert.is_truthy(msg:find("3"))
    end)

    it("rejects a job with no world_id at all", function()
        local ok, code = validate.job(job({ world_id = NONE }), ctx)
        assert.is_false(ok)
        assert.are.equal("wrong_world", code)
    end)

    it("rejects a job when this server has no identity yet", function()
        -- Unregistered: we cannot prove the job is ours, so we must not run it.
        local ok, code = validate.job(job(), { world_id = nil })
        assert.is_false(ok)
        assert.are.equal("wrong_world", code)
    end)

    it("rejects a non-table job", function()
        assert.is_false(validate.job(nil, ctx))
        assert.is_false(validate.job("job", ctx))
    end)

    it("rejects a job with no ops", function()
        local ok, code = validate.job(job({ ops = NONE }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_ops", code)
    end)
end)
