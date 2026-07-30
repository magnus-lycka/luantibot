local validate = require("validate")({
    version = require("version"),
    plan = require("plan"),
})

-- `{ world_id = nil }` in a table literal has no key at all, so a sentinel is
-- needed to express "remove this field" -- which is exactly what a malformed
-- job document looks like.
local NONE = {}

local function job(overrides)
    local j = {
        format = 1,
        job_id = 7,
        world_id = 3,
        world = "TestWorld",
        bounds = { min = { 0, 0, 0 }, max = { 15, 15, 15 } },
        ops = { { op = "emerge" } },
    }
    for k, v in pairs(overrides or {}) do
        j[k] = (v ~= NONE) and v or nil
    end
    return j
end

describe("validate.job", function()
    local ctx = { world_id = 3, max_blocks = 4096 }

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

describe("validate.job bounds", function()
    -- The chat command has always had a cap. Jobs arriving over HTTP reached
    -- emerge with no coordinate or volume check at all, so a malformed request
    -- could permanently generate an enormous region.
    local ctx = { world_id = 3, max_blocks = 64 }

    it("rejects a missing bounds block", function()
        local ok, code = validate.job(job({ bounds = NONE }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_bounds", code)
    end)

    it("rejects malformed corners", function()
        assert.is_false(validate.job(job({ bounds = { min = { 0, 0 }, max = { 1, 1, 1 } } }), ctx))
        assert.is_false(validate.job(job({ bounds = { min = { 0, 0, 0 } } }), ctx))
        assert.is_false(validate.job(job({ bounds = "everywhere" }), ctx))
    end)

    it("rejects non-integer and non-finite coordinates", function()
        local inf = math.huge
        assert.is_false(
            validate.job(job({ bounds = { min = { 0.5, 0, 0 }, max = { 1, 1, 1 } } }), ctx)
        )
        assert.is_false(
            validate.job(job({ bounds = { min = { -inf, 0, 0 }, max = { 1, 1, 1 } } }), ctx)
        )
        assert.is_false(
            validate.job(job({ bounds = { min = { 0, 0, 0 }, max = { inf - inf, 1, 1 } } }), ctx)
        )
    end)

    it("rejects inverted corners", function()
        local ok, code =
            validate.job(job({ bounds = { min = { 10, 0, 0 }, max = { 0, 1, 1 } } }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_bounds", code)
    end)

    it("rejects coordinates outside the world", function()
        local ok, code =
            validate.job(job({ bounds = { min = { 0, 0, 0 }, max = { 40000, 1, 1 } } }), ctx)
        assert.is_false(ok)
        assert.are.equal("out_of_range", code)
    end)

    it("rejects a volume over the mapblock cap", function()
        -- 5x5x5 mapblocks = 125, over the ctx cap of 64.
        local ok, code, msg =
            validate.job(job({ bounds = { min = { 0, 0, 0 }, max = { 79, 79, 79 } } }), ctx)
        assert.is_false(ok)
        assert.are.equal("too_large", code)
        assert.is_truthy(msg:find("125"))
    end)

    it("accepts a volume at the cap", function()
        -- 4x4x4 mapblocks = 64, exactly the cap.
        assert.is_true(
            validate.job(job({ bounds = { min = { 0, 0, 0 }, max = { 63, 63, 63 } } }), ctx)
        )
    end)

    it("applies a default cap when none is configured", function()
        local ok, code = validate.job(
            job({ bounds = { min = { -20000, -100, -20000 }, max = { 20000, 100, 20000 } } }),
            { world_id = 3 }
        )
        assert.is_false(ok)
        assert.are.equal("too_large", code)
    end)
end)

describe("validate.job op vocabulary", function()
    local ctx = { world_id = 3, max_blocks = 4096 }

    it("accepts fill_box inside the bounds", function()
        local ok = validate.job(
            job({ ops = { { op = "fill_box", min = { 1, 1, 1 }, max = { 3, 3, 3 }, node = 0 } } }),
            ctx
        )
        assert.is_true(ok)
    end)

    it("accepts an op box exactly filling the bounds", function()
        local whole = { op = "fill_box", min = { 0, 0, 0 }, max = { 15, 15, 15 }, node = 0 }
        assert.is_true(validate.job(job({ ops = { whole } }), ctx))
    end)

    -- Rule 4. A job written against a newer service must not half-execute.
    it("rejects an unknown op", function()
        local ok, code = validate.job(job({ ops = { { op = "summon_dragon" } } }), ctx)
        assert.is_false(ok)
        assert.are.equal("unknown_op", code)
    end)

    it("rejects an op that is not a table", function()
        local ok, code = validate.job(job({ ops = { "fill_box" } }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_ops", code)
    end)

    it("reports the first bad op when several are present", function()
        local ok, code, message = validate.job(
            job({ ops = { { op = "emerge" }, { op = "nope" }, { op = "also_nope" } } }),
            ctx
        )
        assert.is_false(ok)
        assert.are.equal("unknown_op", code)
        assert.matches("op 2", message)
    end)
end)

describe("validate.job op boxes", function()
    local ctx = { world_id = 3, max_blocks = 4096 }

    local function fill(overrides)
        local op = { op = "fill_box", min = { 1, 1, 1 }, max = { 3, 3, 3 }, node = 0 }
        for k, v in pairs(overrides or {}) do
            op[k] = (v ~= NONE) and v or nil
        end
        return job({ ops = { op } })
    end

    -- Rule 5. apply.lua would clip such a box silently, building something
    -- other than what was asked for.
    it("rejects a box reaching past the bounds", function()
        local ok, code, message = validate.job(fill({ max = { 99, 3, 3 } }), ctx)
        assert.is_false(ok)
        assert.are.equal("box_outside_bounds", code)
        assert.matches("x", message)
    end)

    it("rejects a box starting before the bounds", function()
        local ok, code = validate.job(fill({ min = { -1, 1, 1 } }), ctx)
        assert.is_false(ok)
        assert.are.equal("box_outside_bounds", code)
    end)

    it("rejects an inverted box", function()
        local ok, code = validate.job(fill({ min = { 3, 1, 1 }, max = { 1, 3, 3 } }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_box", code)
    end)

    it("rejects a missing corner", function()
        local ok, code = validate.job(fill({ max = NONE }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_box", code)
    end)

    it("rejects a corner that is not three integers", function()
        local ok, code = validate.job(fill({ min = { 1, 1 } }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_box", code)
    end)

    -- Rule 7, reaching the op boxes and not just the bounds.
    it("rejects a fractional corner", function()
        local ok, code = validate.job(fill({ min = { 1.5, 1, 1 } }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_box", code)
    end)

    it("rejects a missing node index", function()
        local ok, code = validate.job(fill({ node = NONE }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_op", code)
    end)

    it("rejects a negative node index", function()
        local ok, code = validate.job(fill({ node = -1 }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_op", code)
    end)

    it("rejects a fractional node index", function()
        local ok, code = validate.job(fill({ node = 1.5 }), ctx)
        assert.is_false(ok)
        assert.are.equal("bad_op", code)
    end)
end)
