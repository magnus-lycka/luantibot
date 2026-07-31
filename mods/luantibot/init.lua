-- ADAPTER. Wiring only: acquires engine handles at load time and injects them
-- into pure modules. No logic belongs here -- see "The constraint that makes
-- Lua testable" in docs/implementation_plan.md.

local modpath = core.get_modpath(core.get_current_modname())

local function load(name)
    return dofile(modpath .. "/src/" .. name .. ".lua")
end

local version = load("version")
local plan = load("plan")
local emerge = load("emerge")
local parse = load("parse")
local identity = load("identity")
local apply = load("apply")
local validate = load("validate")({ version = version, plan = plan })
local poll = load("poll")
local world = load("world")({ emerge = emerge, apply = apply })

-- `core.get_content_id` raises on a name the game never registered, so the
-- registry is consulted first: palette.lua wants nil for "no such node", not an
-- error that would take the whole globalstep down with it.
local function resolve_node(name)
    if core.registered_nodes[name] == nil then
        return nil
    end
    return core.get_content_id(name)
end

local palette = load("palette")({ resolve = resolve_node })

local matcher = load("match")({
    resolve = resolve_node,
    -- Walks the registry, so it is called once per job by match.prepare rather
    -- than per op or per mapblock. Which nodes carry a group is fixed at load
    -- time, so a job could not observe it changing mid-flight anyway.
    ids_in_group = function(group)
        local ids = {}
        for name, def in pairs(core.registered_nodes) do
            if def.groups and (def.groups[group] or 0) ~= 0 then
                ids[#ids + 1] = core.get_content_id(name)
            end
        end
        return ids
    end,
})

-- MUST be at load time. core.request_http_api() returns nil if called later,
-- or if this mod is not listed in secure.http_mods.
local http = core.request_http_api()

local settings = core.settings
local storage = load("storage")({ storage = core.get_mod_storage() })

local LOCAL_WORLD = identity.world_name_from_path(core.get_worldpath())
local BASE_URL = settings:get("luantibot_service_url") or "http://127.0.0.1:8099"
local MAX_EMERGE_BLOCKS = tonumber(settings:get("luantibot_max_emerge_blocks")) or 4096

-- Empty by default, and deliberately so: rule 3 is a deny list, not an
-- allow-list. VoxelManip writes bypass node callbacks, so the frightening nodes
-- mostly are not -- add an entry when something actually surprises you. See "On
-- node validation" in docs/implementation_plan.md.
local DENY = palette.deny_set(settings:get("luantibot_deny_nodes"))

luantibot = {
    version = version,
    plan = plan,
    world = world,
    apply = apply,
    palette = palette,
    identity = identity,
    validate = validate,
    local_world = LOCAL_WORLD,
}

-- Logged before the HTTP gate below, so this line appears whether or not the
-- service is configured. It is what INSTALL.md tells people to look for.
core.log("action", "[luantibot] loaded, wire format " .. version.FORMAT)

core.register_chatcommand("lb_emerge", {
    params = "<x> <y> <z> <radius>",
    description = "Emerge the mapblocks around a point (luantibot)",
    privs = { server = true },
    func = function(_, param)
        local centre, radius = parse.emerge_args(param)
        if not centre then
            return false, radius
        end

        local p1, p2 = plan.emerge_bounds(centre, radius)
        if not p1 then
            return false, p2
        end

        local blocks = plan.block_count(p1, p2)
        if blocks > MAX_EMERGE_BLOCKS then
            return false,
                string.format(
                    "refusing: %d mapblocks exceeds the limit of %d",
                    blocks,
                    MAX_EMERGE_BLOCKS
                )
        end

        local started = core.get_us_time()
        world.emerge(p1, p2, function(result)
            local ms = (core.get_us_time() - started) / 1000
            local msg = string.format(
                "[luantibot] emerge %s: %d mapblocks in %d ms",
                result.ok and "ok" or "FAILED",
                result.blocks,
                ms
            )
            if not result.ok then
                msg = msg .. " -- " .. result.error
            end
            core.log(result.ok and "action" or "error", msg)
        end)

        return true,
            string.format(
                "emerging %d mapblocks (%d,%d,%d)..(%d,%d,%d); watch the log",
                blocks,
                p1.x,
                p1.y,
                p1.z,
                p2.x,
                p2.y,
                p2.z
            )
    end,
})

-- Everything below needs the service. /lb_emerge above deliberately does not:
-- it is a local operation, and must stay usable when the service is down or
-- was never started.
if not http then
    core.log(
        "warning",
        "[luantibot] no HTTP API; /lb_emerge works but job polling is off. "
            .. "Add 'secure.http_mods = luantibot' to minetest.conf to enable it."
    )
    return
end

local client = load("client")({ http = http, base_url = BASE_URL })

local poller = poll.new({
    world_name = LOCAL_WORLD,
    world_id = storage.world_id(),
    interval = tonumber(settings:get("luantibot_poll_interval")) or 2,
})
luantibot.poller = poller
luantibot.stats = { jobs_done = 0, jobs_failed = 0 }

local function log_identity()
    core.log(
        "action",
        "[luantibot] " .. identity.describe(poller:world_id(), poller:known_as(), LOCAL_WORLD)
    )
end

-- Warn, never refuse: a legitimate rename and an accidental world copy look
-- identical from here, so refusing would break the legitimate case.
local function warn_on_divergence()
    local warning = identity.divergence(poller:known_as(), LOCAL_WORLD)
    if warning then
        core.log("warning", "[luantibot] " .. warning)
    end
end

-- Executes a job the service handed us, then tells the poller how it went.
local function fail_job(job, code, message)
    core.log("error", string.format("[luantibot] job %s failed: %s", tostring(job.job_id), message))
    luantibot.stats.jobs_failed = luantibot.stats.jobs_failed + 1
    poller:finish(false, { code = code, message = message })
end

local function run_job(job)
    local ok, code, message = validate.job(job, {
        world_id = poller:world_id(),
        max_blocks = MAX_EMERGE_BLOCKS,
    })
    if not ok then
        fail_job(job, code, message)
        return
    end

    -- Rule 3. Resolved once, before anything is written, so an unregistered
    -- name fails the job rather than one op of it.
    local pal, pcode, pmessage = palette.compile(job.palette or {}, DENY)
    if not pal then
        fail_job(job, pcode, pmessage)
        return
    end

    local p1, p2 = validate.positions(job)
    local started = core.get_us_time()

    -- Reserved is not started: only the mod can say the work actually began,
    -- and after a crash that distinction is what separates "died before
    -- starting" from "died mid-job".
    poller:report(string.format("/v1/jobs/%d/started", job.job_id), {})

    -- An emerge-only job never touches a VoxelManip. Reading one back would
    -- mark every mapblock in the region modified and force it to be re-saved,
    -- which is the opposite of what a generate-terrain job is for.
    local writes = apply.writes(job.ops)
    core.log(
        "action",
        string.format("[luantibot] job %d: %s", job.job_id, writes and "building" or "emerging")
    )

    local function finished(result)
        local ms = math.floor((core.get_us_time() - started) / 1000)
        if not result.ok then
            fail_job(job, result.code or "emerge_failed", result.error)
            return
        end
        core.log(
            "action",
            string.format(
                "[luantibot] job %d: %d mapblocks, %d nodes in %d ms",
                job.job_id,
                result.blocks,
                result.written or 0,
                ms
            )
        )
        luantibot.stats.jobs_done = luantibot.stats.jobs_done + 1
        poller:finish(true, { blocks = result.blocks, nodes = result.written or 0, ms = ms })
    end

    if writes then
        -- Positions first, then predicates: both turn the wire document into
        -- the form the executor wants, and both work on copies so the job
        -- document keeps the shape it arrived in.
        local prepared, mcode, mmessage = matcher.prepare(validate.ops_as_positions(job))
        if not prepared then
            fail_job(job, mcode, mmessage)
            return
        end
        world.build(p1, p2, prepared, pal, finished)
    else
        world.emerge(p1, p2, finished)
    end
end

local function handle(event)
    if event.kind == "registered" then
        storage.set_world_id(event.world_id)
        log_identity()
        warn_on_divergence()
    elseif event.kind == "world" then
        log_identity()
        warn_on_divergence()
    elseif event.kind == "job" then
        run_job(event.job)
    elseif event.kind == "error" then
        core.log("warning", "[luantibot] " .. event.message)
    end
end

core.register_globalstep(function(dtime)
    local req = poller:tick(dtime)
    if req then
        client.send(req, function(res)
            handle(poller:on_response(res))
        end)
    end
end)

core.register_chatcommand("lb_world", {
    description = "Show this server's luantibot world identity",
    privs = { server = true },
    func = function()
        return true, identity.describe(poller:world_id(), poller:known_as(), LOCAL_WORLD)
    end,
})

core.register_chatcommand("lb_world_bind", {
    params = "<name>",
    description = "Register this world under <name> and adopt the returned id",
    privs = { server = true },
    func = function(caller, param)
        local name = (param or ""):gsub("^%s*(.-)%s*$", "%1")
        if name == "" then
            return false, "usage: /lb_world_bind <name>"
        end
        if poller:state() == "busy" or poller:state() == "report" then
            return false, "a job is running; rebinding now would orphan it. Wait for it to finish."
        end
        -- Binding a world *copy* under the original's name merges their
        -- histories, silently. The name is the decision; the id follows it.
        core.log("action", string.format("[luantibot] %s rebinding world to %q", caller, name))
        storage.clear()
        poller:rebind(name)
        return true, "rebinding to " .. name .. "; watch the log"
    end,
})

core.register_chatcommand("lb_world_forget", {
    description = "Forget the cached world id and re-register on the next poll",
    privs = { server = true },
    func = function(caller)
        if poller:state() == "busy" or poller:state() == "report" then
            return false, "a job is running; forgetting now would orphan it. Wait for it to finish."
        end
        core.log("action", "[luantibot] " .. caller .. " cleared the cached world id")
        storage.clear()
        poller:forget()
        return true, "forgotten; will re-register as " .. LOCAL_WORLD
    end,
})

log_identity()
