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
local world = load("world")({ emerge = emerge })

luantibot = {
    version = version,
    plan = plan,
    world = world,
}

-- A typo'd radius should not ask the engine to generate half a planet. The
-- real per-job cap arrives with validate.lua in M2; this guards the chat path.
local MAX_EMERGE_BLOCKS = tonumber(core.settings:get("luantibot_max_emerge_blocks")) or 4096

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

core.log("action", "[luantibot] loaded, wire format " .. version.FORMAT)
