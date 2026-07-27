-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Which world is this, and are we allowed to act in it?
--
-- Builds are permanent and world-scoped, and neither the Luanti world name nor
-- its directory name is durable -- both can be renamed. The service issues a
-- world id, the mod caches it in per-world mod storage, and everything here is
-- about keeping that binding visible and safe. See "World identity" in
-- docs/implementation_plan.md.

local identity = {}

local function trim(s)
    return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1"))
end

--- Last segment of a world path, which is the world's directory name.
--- @param path string
--- @return string
function identity.world_name_from_path(path)
    local cleaned = tostring(path or ""):gsub("[/\\]+$", "")
    return cleaned:match("([^/\\]+)$") or cleaned
end

--- May the mod act in this world at all?
---
--- Fail-closed on purpose. A mod installed into the global mods directory
--- rather than a single world's `worldmods` would otherwise be live in every
--- world at once, including the real one.
--- @param configured string|nil value of the `luantibot_world` setting
--- @param local_world string world directory name of the running server
--- @return boolean armed, string|nil reason when not armed
function identity.armed(configured, local_world)
    local want = trim(configured)
    if want == "" then
        return false,
            "luantibot_world is not set; refusing to act in any world. "
                .. "Set it to this world's directory name to arm the mod."
    end
    if want ~= local_world then
        return false,
            string.format(
                "luantibot_world is %q but this world is %q; refusing to act",
                want,
                local_world
            )
    end
    return true
end

--- Warn if the service's label and the local directory name have drifted.
---
--- Deliberately advisory. A rename in Luanti and an accidental `cp -r` of a
--- world look exactly alike from here, and refusing would break the legitimate
--- case. Say so and continue.
--- @param service_name string|nil the service's name for our world id
--- @param local_world string world directory name
--- @return string|nil warning
function identity.divergence(service_name, local_world)
    if service_name == nil or service_name == local_world then
        return nil
    end
    return string.format(
        "service knows world id as %q but the local world directory is %q "
            .. "-- a rename is fine; a copied world should be re-bound with /lb_world_bind",
        service_name,
        local_world
    )
end

--- One-line identity, for the startup log and /lb_world.
--- Most confusion here is silent; this is what makes it visible.
--- @param world_id number|nil
--- @param service_name string|nil
--- @param local_world string
--- @return string
function identity.describe(world_id, service_name, local_world)
    if world_id == nil then
        return string.format("unregistered (dir: %s)", local_world)
    end
    return string.format("world_id=%d %q (dir: %s)", world_id, service_name or "?", local_world)
end

return identity
