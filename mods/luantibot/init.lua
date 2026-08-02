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
-- Engine capabilities as closures, so world.lua stays pure and testable. The
-- EMERGE_* constants and the VoxelManip dance are pure translation and belong
-- here, on the adapter side of the line.
local function emerge_kind(action)
    if action == core.EMERGE_ERRORED then
        return "errored"
    elseif action == core.EMERGE_CANCELLED then
        return "cancelled"
    end
    return "ok"
end

-- `walkable` is what separates a surface from a node that merely occupies a
-- cell: a trapdoor, a plant, a slab's empty half. Defaults to true in Luanti,
-- so the test is against an explicit false. `name` turns ids back into
-- something the caller can read.
local survey = load("survey")({
    walkable = function(id)
        local def = core.registered_nodes[core.get_name_from_content_id(id)]
        return def == nil or def.walkable ~= false
    end,
    name = function(id)
        return core.get_name_from_content_id(id)
    end,
})

local snapshot = load("snapshot")({
    name = function(id)
        return core.get_name_from_content_id(id)
    end,
    resolve = function(name)
        if core.registered_nodes[name] == nil then
            return nil
        end
        return core.get_content_id(name)
    end,
})

local world = load("world")({
    emerge = emerge,
    apply = apply,
    plan = plan,
    survey = survey,
    snapshot = snapshot,
    emerge_area = function(p1, p2, on_block)
        core.emerge_area(p1, p2, function(_, action, calls_remaining)
            on_block(emerge_kind(action), calls_remaining)
        end)
    end,
    voxelmanip = function(p1, p2)
        local vm = core.get_voxel_manip()
        local emin, emax = vm:read_from_map(p1, p2)
        return {
            area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax }),
            data = vm:get_data(),
            param2 = vm:get_param2_data(),
            write = function(data, param2)
                vm:set_data(data)
                vm:set_param2_data(param2)
                -- `false` is the lighting flag: raw nodes, no lighting pass, no
                -- liquid update. M8 does lighting as its own job type.
                vm:write_to_map(false)
            end,
        }
    end,
})

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

-- Snapshots live under the world directory, so they travel with the world and
-- are removed with it. `core.safe_file_write` is what M0 established works from
-- a non-trusted mod; whether it is internally atomic is still open, which is
-- why snapstore reads every snapshot back before letting the world change.
local SNAPSHOT_ROOT = core.get_worldpath() .. "/luantibot_snapshots"

local snapstore = load("snapstore")({
    snapshot = snapshot,
    root = SNAPSHOT_ROOT,
    json = { encode = core.write_json, decode = core.parse_json },
    fs = {
        exists = function(path)
            local f = io.open(path, "rb")
            if f then
                f:close()
                return true
            end
            return false
        end,
        read = function(path)
            local f = io.open(path, "rb")
            if not f then
                return nil
            end
            local data = f:read("*a")
            f:close()
            return data
        end,
        write = function(path, data)
            core.mkdir(path:match("^(.*)/[^/]+$"))
            return core.safe_file_write(path, data) ~= false
        end,
        list = function(dir)
            return core.get_dir_list(dir, false) or {}
        end,
        remove = function(path)
            return os.remove(path) ~= nil
        end,
    },
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

-- Step 2 of the recovery protocol. A job id still in storage means the last
-- run died between writing it and clearing it, so this server was mid-job when
-- it stopped. Saying so is strictly better than letting the service infer it
-- from five minutes of silence: it is immediate, and it distinguishes "the
-- executor came back" from "nobody has".
--
-- Reported, then forgotten unconditionally. If the POST is lost the service
-- still sweeps the row as `interrupted`, whereas keeping the id would make
-- every future startup re-report a job nobody is working on.
local orphan = storage.job_id()
if orphan then
    core.log(
        "warning",
        string.format(
            "[luantibot] job %d was running when this server stopped; abandoning it",
            orphan
        )
    )
    poller:report(string.format("/v1/jobs/%d/abandoned", orphan), {})
    storage.set_job_id(nil)
end

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
    storage.set_job_id(nil)
    poller:finish(false, { code = code, message = message })
end

--- Which job's snapshots a restore replays, or nil if this is not one.
local function restores_from(job)
    for _, op in ipairs(job.ops or {}) do
        if op.op == "restore" then
            return op.job
        end
    end
    return nil
end

--- The snapshot half of the environment `world.build` runs a job in.
---
--- A job either records what it is about to change, or puts back what another
--- one changed -- never both. Snapshotting a restore would record the undone
--- state as if it were original, so undoing an undo would restore the undo.
local function snapshot_env(job)
    local from = restores_from(job)

    if from then
        return {
            restore = function(unit_index, buf, area, lo, hi)
                local region, code, message = snapstore.load(from, unit_index)
                if not region then
                    -- No snapshot means this unit was never modified, so there
                    -- is nothing to put back. Only a damaged one is an error.
                    if code == "snapshot_missing" then
                        return 0
                    end
                    return nil, code, message
                end
                return snapshot.restore_into(buf, area, lo, hi, region)
            end,
        }
    end

    -- Uncommitted leftovers from an attempt that died mid-write. Removed before
    -- this attempt starts, so nothing can mistake one for a commit.
    snapstore.sweep_temp(job.job_id)
    snapstore.write_manifest(job.job_id, {
        bounds = { min = job.bounds.min, max = job.bounds.max },
        unit_blocks = plan.UNIT_BLOCKS,
        partitioner = plan.PARTITIONER,
    })

    return {
        snapshot = function(unit_index, region)
            return snapstore.capture(job.job_id, unit_index, region, region.count)
        end,
    }
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

    -- Written before the first node is touched. If this server dies mid-job the
    -- value survives in mod storage, and the next startup reports `abandoned`
    -- rather than leaving the row for the service to time out.
    storage.set_job_id(job.job_id)

    -- Three kinds of job, and only the first can skip the VoxelManip. Choosing
    -- on `writes` would send a survey down the emerge-only path and it would
    -- read nothing at all.
    local reads = apply.reads(job.ops)
    local kind = "emerging"
    if reads then
        kind = apply.writes(job.ops) and "building" or "surveying"
    end
    core.log("action", string.format("[luantibot] job %d: %s", job.job_id, kind))

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
        storage.set_job_id(nil)
        poller:finish(true, {
            blocks = result.blocks,
            nodes = result.written or 0,
            units = result.units or 1,
            ms = ms,
            -- Only present for a survey; the whole point of the job is what it
            -- read, so it travels back in the completion rather than being
            -- something the caller has to fetch separately.
            columns = result.columns,
        })
    end

    -- Best effort, and never retried: losing one progress ping must not stall
    -- the job it describes. Its other purpose is renewing the heartbeat, and
    -- the next unit will renew it again.
    local function progress(done, total)
        poller:report(
            string.format("/v1/jobs/%d/progress", job.job_id),
            { units_done = done, units_total = total }
        )
    end

    if reads then
        -- Positions first, then predicates: both turn the wire document into
        -- the form the executor wants, and both work on copies so the job
        -- document keeps the shape it arrived in.
        local prepared, mcode, mmessage = matcher.prepare(validate.ops_as_positions(job))
        if not prepared then
            fail_job(job, mcode, mmessage)
            return
        end
        world.build(p1, p2, prepared, pal, progress, finished, snapshot_env(job))
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
