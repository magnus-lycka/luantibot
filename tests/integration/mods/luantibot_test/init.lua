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

local function run_checks()
    check("mod loaded", luantibot ~= nil, "global luantibot table missing")

    check(
        "wire format exposed",
        luantibot and luantibot.version and luantibot.version.FORMAT == 1,
        "unexpected format version"
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
end

core.register_on_mods_loaded(function()
    -- Defer past startup so the server is fully up before we assert or shut down.
    core.after(0.5, function()
        local ok, err = pcall(run_checks)
        if not ok then
            check("harness", false, err)
        end

        core.safe_file_write(
            core.get_worldpath() .. "/result.json",
            core.write_json({ failures = failures, checks = results })
        )
        core.log("action", "[luantibot_test] done, failures=" .. failures)
        core.request_shutdown("integration run complete")
    end)
end)
