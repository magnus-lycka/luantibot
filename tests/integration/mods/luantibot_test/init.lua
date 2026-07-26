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
        -- other than "ignore".
        local node = core.get_node({ x = centre.x, y = centre.y, z = centre.z })
        check("emerged area reads a real node", node.name ~= "ignore", node.name)

        done()
    end)
end

local function run_checks()
    check("mod loaded", luantibot ~= nil, "global luantibot table missing")

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
