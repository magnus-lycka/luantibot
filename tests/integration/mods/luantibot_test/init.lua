-- Integration assertions. Runs inside a real Luanti server against the real
-- engine, writes a result file, and shuts the server down.
--
-- This is the only place adapters (world.lua, snapshot.lua, init.lua) get
-- exercised. Pure modules are covered far more cheaply by busted.

local results = {}
local failures = 0

-- `detail` describes the failure, so it is only recorded when one happened.
local function check(name, ok, detail)
    if ok then
        results[#results + 1] = { name = name, ok = true }
        core.log("action", "[luantibot_test] pass " .. name)
    else
        results[#results + 1] = { name = name, ok = false, detail = tostring(detail) }
        failures = failures + 1
        core.log("error", "[luantibot_test] FAIL " .. name .. ": " .. tostring(detail))
    end
end

-- Asynchronous checks resolve through this: each one registered here must call
-- finish() exactly once, and the run only completes when all have.
local pending = 0
local on_all_done = nil

local function async(fn)
    pending = pending + 1
    fn(function()
        pending = pending - 1
        if pending == 0 and on_all_done then
            on_all_done()
        end
    end)
end

local function check_emerge(done)
    local centre = { x = 100, y = 8, z = 100 }
    local p1, p2 = luantibot.plan.emerge_bounds(centre, 8)
    check("emerge_bounds returns a box", p1 ~= nil, p2)
    if not p1 then
        return done()
    end

    local expected = luantibot.plan.block_count(p1, p2)
    local started = core.get_us_time()

    luantibot.world.emerge(p1, p2, function(result)
        local ms = (core.get_us_time() - started) / 1000
        check("emerge succeeds", result.ok, result.error)
        -- The tracker counts engine callbacks; plan.block_count predicts them
        -- from geometry. If these disagree, one of the two is wrong.
        check(
            "emerge reports one callback per mapblock",
            result.blocks == expected,
            string.format("expected %d, got %d", expected, result.blocks)
        )
        core.log(
            "action",
            string.format("[luantibot_test] emerged %d blocks in %d ms", result.blocks, ms)
        )

        -- Emerged means the map is loaded, so nodes must now read as something
        -- other than "ignore". The name is logged because a fixed mapgen seed
        -- should make it identical on every run -- the determinism that M2 and
        -- M6 region comparisons rest on.
        local node = core.get_node({ x = centre.x, y = centre.y, z = centre.z })
        check("emerged area reads a real node", node.name ~= "ignore", node.name)
        core.log(
            "action",
            string.format(
                "[luantibot_test] probe (%d,%d,%d) = %s",
                centre.x,
                centre.y,
                centre.z,
                node.name
            )
        )

        done()
    end)
end

-- The mod registers with the service on its first poll, so this waits for the
-- handshake rather than asserting immediately. Covers the whole M1.4 path:
-- globalstep -> HTTP -> service -> SQLite -> mod storage.
local function check_registration(done)
    local waited = 0
    local function poll_until_registered()
        local id = luantibot.poller and luantibot.poller:world_id()
        if id then
            check("registered with the service", type(id) == "number", tostring(id))
            -- Any state but "register" means the handshake completed. Not
            -- specifically "idle": if a job was already queued, the poller has
            -- rightly moved on to it by the time we look.
            check(
                "poller left the registration state",
                luantibot.poller:state() ~= "register",
                luantibot.poller:state()
            )
            core.log("action", "[luantibot_test] registered as world_id=" .. tostring(id))
            return done()
        end
        waited = waited + 1
        if waited > 30 then
            check("registered with the service", false, "no world_id after 15s")
            return done()
        end
        core.after(0.5, poll_until_registered)
    end
    poll_until_registered()
end

-- M1's success criterion: a job submitted to the service from outside is
-- fetched, executed, and reported, with no chat command involved.
-- scripts/integration queues the job before the server boots, and asserts the
-- resulting row is `completed` after it exits.
local function check_job_round_trip(done)
    local waited = 0
    local function poll_until_done()
        local stats = luantibot.stats or {}
        if (stats.jobs_done or 0) + (stats.jobs_failed or 0) > 0 then
            check("executed a job from the service", stats.jobs_done == 1, "job failed")
            return done()
        end
        waited = waited + 1
        if waited > 60 then
            check("executed a job from the service", false, "no job executed after 30s")
            return done()
        end
        core.after(0.5, poll_until_done)
    end
    poll_until_done()
end

local function run_checks()
    check("mod loaded", luantibot ~= nil, "global luantibot table missing")

    -- Being loaded in this world is the whole opt-in; there is no arming
    -- setting to get wrong. What keeps work in the right world is the
    -- world_id check in validate.lua.
    check(
        "wire format exposed",
        luantibot and luantibot.version and luantibot.version.FORMAT == 1,
        "unexpected format version"
    )

    check(
        "chat command registered",
        core.registered_chatcommands["lb_emerge"] ~= nil,
        "lb_emerge missing"
    )

    -- Answers a question the plan flagged for M6: can a non-trusted mod write
    -- files at all? If this fails, snapshots must go over HTTP to Python
    -- instead, and M6 gets substantially bigger.
    local probe = core.get_worldpath() .. "/write_probe.txt"
    local wrote = core.safe_file_write(probe, "probe")
    check("safe_file_write works from a non-trusted mod", wrote, "returned false")

    local listed = false
    for _, entry in ipairs(core.get_dir_list(core.get_worldpath(), false) or {}) do
        if entry == "write_probe.txt" then
            listed = true
        end
    end
    check("get_dir_list sees the written file", listed, "probe file not listed")

    async(check_emerge)
    async(check_registration)
    async(check_job_round_trip)
end

local function finish()
    core.safe_file_write(
        core.get_worldpath() .. "/result.json",
        core.write_json({ failures = failures, checks = results })
    )
    core.log("action", "[luantibot_test] done, failures=" .. failures)
    core.request_shutdown("integration run complete")
end

core.register_on_mods_loaded(function()
    -- Defer past startup so the server is fully up before we assert or shut down.
    core.after(0.5, function()
        on_all_done = finish

        local ok, err = pcall(run_checks)
        if not ok then
            check("harness", false, err)
        end

        -- Nothing asynchronous was registered, or it all resolved synchronously.
        if pending == 0 then
            finish()
        end
    end)
end)
