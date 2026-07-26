-- ADAPTER. Wiring only: acquires engine handles at load time and injects them
-- into pure modules. No logic belongs here -- see "The constraint that makes
-- Lua testable" in docs/implementation_plan.md.

local modpath = core.get_modpath(core.get_current_modname())

luantibot = {
    version = dofile(modpath .. "/src/version.lua"),
}

core.log("action", "[luantibot] loaded, wire format " .. luantibot.version.FORMAT)
