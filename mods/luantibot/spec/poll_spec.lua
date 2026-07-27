local poll = require("poll")

local function new(cfg)
    cfg = cfg or {}
    return poll.new({
        world_name = cfg.world_name or "Marduk1",
        world_id = cfg.world_id,
        interval = cfg.interval or 2,
        backoff_max = cfg.backoff_max or 30,
    })
end

--- Advance past the poll interval and return whatever request comes out.
local function due(p, seconds)
    return p:tick(seconds or 99)
end

describe("poll registration", function()
    it("starts unregistered and asks to register", function()
        local p = new()
        assert.are.equal("register", p:state())

        local req = due(p)
        assert.are.equal("register", req.kind)
        assert.are.equal("POST", req.method)
        assert.are.equal("/v1/worlds", req.path)
        assert.are.same({ name = "Marduk1" }, req.body)
    end)

    it("registers immediately rather than waiting out the interval", function()
        local p = new({ interval = 60 })
        assert.is_table(p:tick(0))
    end)

    it("adopts the id from the response and becomes idle", function()
        local p = new()
        due(p)
        local event = p:on_response({ ok = true, code = 201, body = { world_id = 3 } })

        assert.are.equal("registered", event.kind)
        assert.are.equal(3, event.world_id)
        assert.are.equal(3, p:world_id())
        assert.are.equal("idle", p:state())
    end)

    it("skips registration when an id is already known", function()
        local p = new({ world_id = 7 })
        assert.are.equal("idle", p:state())
        assert.are.equal("next", due(p).kind)
    end)

    it("stays unregistered if the response carries no id", function()
        local p = new()
        due(p)
        local event = p:on_response({ ok = true, code = 201, body = {} })

        assert.are.equal("error", event.kind)
        assert.are.equal("register", p:state())
    end)
end)

describe("poll job fetching", function()
    it("polls the world-scoped endpoint", function()
        local p = new({ world_id = 3 })
        local req = due(p)

        assert.are.equal("GET", req.method)
        assert.are.equal("/v1/worlds/3/jobs/next", req.path)
    end)

    it("waits out the interval between polls", function()
        local p = new({ world_id = 3, interval = 2 })
        due(p)
        p:on_response({ ok = true, code = 204 })

        assert.is_nil(p:tick(0.5))
        assert.is_nil(p:tick(1.0))
        assert.is_table(p:tick(1.0))
    end)

    it("treats 204 as no work", function()
        local p = new({ world_id = 3 })
        due(p)
        local event = p:on_response({ ok = true, code = 204 })

        assert.are.equal("none", event.kind)
        assert.are.equal("idle", p:state())
    end)

    it("hands a job out and goes busy", function()
        local p = new({ world_id = 3 })
        due(p)
        local job = { job_id = 9, world_id = 3, format = 1, ops = {} }
        local event = p:on_response({ ok = true, code = 200, body = job })

        assert.are.equal("job", event.kind)
        assert.are.equal(9, event.job.job_id)
        assert.are.equal("busy", p:state())
    end)

    -- The executor owns the world while a job runs; polling during that would
    -- reserve a second job the mod cannot start.
    it("emits nothing while busy", function()
        local p = new({ world_id = 3 })
        due(p)
        p:on_response({ ok = true, code = 200, body = { job_id = 9, ops = {} } })

        assert.is_nil(due(p))
        assert.is_nil(due(p))
    end)

    it("issues one request at a time", function()
        local p = new({ world_id = 3 })
        assert.is_table(due(p))
        -- A request is in flight; a second tick must not start another.
        assert.is_nil(due(p))
    end)
end)

describe("poll reporting", function()
    local function busy_with_job()
        local p = new({ world_id = 3 })
        due(p)
        p:on_response({ ok = true, code = 200, body = { job_id = 9, ops = {} } })
        return p
    end

    it("reports completion", function()
        local p = busy_with_job()
        p:finish(true, { changed_nodes = 0 })

        local req = due(p)
        assert.are.equal("report", req.kind)
        assert.are.equal("POST", req.method)
        assert.are.equal("/v1/jobs/9/completed", req.path)
        assert.are.same({ changed_nodes = 0 }, req.body)
    end)

    it("reports failure with a code and message", function()
        local p = busy_with_job()
        p:finish(false, { code = "wrong_world", message = "not ours" })

        local req = due(p)
        assert.are.equal("/v1/jobs/9/failed", req.path)
        assert.are.equal("wrong_world", req.body.code)
    end)

    it("reports without waiting out the interval", function()
        local p = busy_with_job()
        p:finish(true, {})
        assert.is_table(p:tick(0))
    end)

    it("returns to idle and polls again straight away once reported", function()
        local p = busy_with_job()
        p:finish(true, {})
        due(p)
        p:on_response({ ok = true, code = 204 })

        assert.are.equal("idle", p:state())
        assert.are.equal("next", p:tick(0).kind)
    end)

    -- A dropped completion report must not strand the mod: the job is finished
    -- either way, and the service will sweep its row as interrupted.
    it("gives up on the report rather than retrying forever", function()
        local p = busy_with_job()
        p:finish(true, {})
        due(p)
        p:on_response({ ok = false, code = 0 })

        assert.are.equal("idle", p:state())
    end)
end)

describe("poll backoff", function()
    it("backs off after a failure instead of spinning", function()
        local p = new({ world_id = 3, interval = 2 })
        due(p)
        p:on_response({ ok = false, code = 0 })

        assert.is_nil(p:tick(2))
        assert.is_table(p:tick(99))
    end)

    it("grows the delay on repeated failures", function()
        local p = new({ world_id = 3, interval = 2 })
        local delays = {}
        for _ = 1, 4 do
            due(p)
            p:on_response({ ok = false, code = 500 })
            delays[#delays + 1] = p:wait()
        end

        assert.is_true(delays[2] > delays[1])
        assert.is_true(delays[3] > delays[2])
    end)

    it("caps the delay", function()
        local p = new({ world_id = 3, interval = 2, backoff_max = 8 })
        for _ = 1, 20 do
            due(p)
            p:on_response({ ok = false, code = 500 })
        end

        assert.is_true(p:wait() <= 8)
    end)

    it("resets the delay after a success", function()
        local p = new({ world_id = 3, interval = 2 })
        for _ = 1, 3 do
            due(p)
            p:on_response({ ok = false, code = 500 })
        end
        due(p)
        p:on_response({ ok = true, code = 204 })

        assert.are.equal(2, p:wait())
    end)

    it("treats a 5xx as a failure", function()
        local p = new({ world_id = 3 })
        due(p)
        local event = p:on_response({ ok = true, code = 503, body = nil })
        assert.are.equal("error", event.kind)
    end)
end)

describe("poll rebinding", function()
    it("forgetting the id returns it to registration", function()
        local p = new({ world_id = 3 })
        p:forget()

        assert.is_nil(p:world_id())
        assert.are.equal("register", p:state())
        assert.are.equal("register", due(p).kind)
    end)

    it("rebinding under a new name registers with that name", function()
        local p = new({ world_id = 3 })
        p:rebind("Marduk1_v2")

        local req = due(p)
        assert.are.equal("register", req.kind)
        assert.are.same({ name = "Marduk1_v2" }, req.body)
    end)

    it("a response arriving after a rebind is ignored", function()
        -- Otherwise a poll in flight when you rebind could resolve against the
        -- old identity and attach work to the wrong world.
        local p = new({ world_id = 3 })
        due(p)
        p:rebind("Marduk1_v2")
        local event = p:on_response({ ok = true, code = 200, body = { job_id = 9, ops = {} } })

        assert.are.equal("stale", event.kind)
        assert.are.equal("register", p:state())
    end)
end)
