local poll = require("poll")

-- Most specs care about fetching and reporting, not identity, so a cached
-- world_id also gets a known name by default -- otherwise every one of them
-- would have to step through the world lookup first. Pass
-- `world_known_as = false` to get a poller that still has to look it up.
--
-- Written as an explicit branch, not `x and y or z`: that idiom cannot yield
-- nil when the alternative is falsy, which is exactly the case here.
local function new(cfg)
    cfg = cfg or {}

    local known_as
    if cfg.world_known_as == nil then
        known_as = cfg.world_id and "TestWorld" or nil
    elseif cfg.world_known_as ~= false then
        known_as = cfg.world_known_as
    end

    return poll.new({
        world_name = cfg.world_name or "TestWorld",
        world_id = cfg.world_id,
        world_known_as = known_as,
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
        assert.are.same({ name = "TestWorld" }, req.body)
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

    -- A dropped completion report is retried rather than discarded, and
    -- abandoned rather than retried forever. Both halves live in
    -- "poll terminal report retry" below.
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
        p:rebind("TestWorld_copy")

        local req = due(p)
        assert.are.equal("register", req.kind)
        assert.are.same({ name = "TestWorld_copy" }, req.body)
    end)

    it("a response arriving after a rebind is ignored", function()
        -- Otherwise a poll in flight when you rebind could resolve against the
        -- old identity and attach work to the wrong world.
        local p = new({ world_id = 3 })
        due(p)
        p:rebind("TestWorld_copy")
        local event = p:on_response({ ok = true, code = 200, body = { job_id = 9, ops = {} } })

        assert.are.equal("stale", event.kind)
        assert.are.equal("register", p:state())
    end)
end)

describe("poll side reports", function()
    local function busy_with_job()
        local p = new({ world_id = 3 })
        due(p)
        p:on_response({ ok = true, code = 200, body = { job_id = 9, ops = {} } })
        return p
    end

    -- `started` (and, from M4, `progress`) must go out *while* a job runs.
    -- Without this channel the mod is silent between reservation and
    -- completion, so a crash mid-job is indistinguishable from one before it.
    it("emits a queued side report even while busy", function()
        local p = busy_with_job()
        p:report("/v1/jobs/9/started", {})

        local req = p:tick(0)
        assert.is_table(req)
        assert.are.equal("side", req.kind)
        assert.are.equal("/v1/jobs/9/started", req.path)
    end)

    it("stays busy after a side report resolves", function()
        local p = busy_with_job()
        p:report("/v1/jobs/9/started", {})
        p:tick(0)
        local event = p:on_response({ ok = true, code = 204 })

        assert.are.equal("reported", event.kind)
        assert.are.equal("busy", p:state())
    end)

    it("does not retry a dropped side report", function()
        -- Best-effort: losing a progress ping must not stall the job.
        local p = busy_with_job()
        p:report("/v1/jobs/9/started", {})
        p:tick(0)
        p:on_response({ ok = false, code = 0 })

        assert.is_nil(p:tick(0))
        assert.are.equal("busy", p:state())
    end)

    it("prefers the completion report over queued side reports", function()
        local p = busy_with_job()
        p:report("/v1/jobs/9/progress", { done = 1 })
        p:finish(true, {})

        assert.are.equal("/v1/jobs/9/completed", p:tick(0).path)
    end)
end)

describe("poll terminal report retry", function()
    local function reported_failure(attempts)
        local p = new({ world_id = 3, interval = 2 })
        due(p)
        p:on_response({ ok = true, code = 200, body = { job_id = 9, ops = {} } })
        p:finish(true, {})
        for _ = 1, attempts do
            due(p)
            p:on_response({ ok = false, code = 0 })
        end
        return p
    end

    -- A transient failure must not lose the completion: the world work is done,
    -- and the service would otherwise hold the row `running` until a restart.
    it("retries a dropped completion report", function()
        local p = reported_failure(1)
        assert.are.equal("report", p:state())
        assert.are.equal("/v1/jobs/9/completed", due(p).path)
    end)

    it("gives up after the retry budget and returns to polling", function()
        local p = reported_failure(4)
        assert.are.equal("idle", p:state())
        assert.are.equal("next", due(p).kind)
    end)
end)

describe("poll world name", function()
    -- Starting from a cached id, the mod knows its number but not the name the
    -- service has for it -- which is what the divergence warning compares.
    it("asks for the world when starting from a cached id", function()
        local p = new({ world_id = 3, world_known_as = false })
        local req = due(p)
        assert.are.equal("world", req.kind)
        assert.are.equal("/v1/worlds/3", req.path)
    end)

    it("reports the name and then polls for work", function()
        local p = new({ world_id = 3, world_known_as = false })
        due(p)
        local event = p:on_response({ ok = true, code = 200, body = { world_id = 3, name = "W" } })

        assert.are.equal("world", event.kind)
        assert.are.equal("W", event.name)
        assert.are.equal("next", p:tick(0).kind)
    end)

    it("carries the name straight through registration", function()
        local p = new()
        due(p)
        local event = p:on_response({ ok = true, code = 201, body = { world_id = 3, name = "W" } })

        assert.are.equal("W", event.name)
        assert.are.equal("next", p:tick(0).kind)
    end)

    it("does not ask again once known", function()
        local p = new({ world_id = 3, world_known_as = false })
        due(p)
        p:on_response({ ok = true, code = 200, body = { world_id = 3, name = "W" } })
        assert.are.equal("next", p:tick(0).kind)
    end)
end)
