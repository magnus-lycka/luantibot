-- ADAPTER. May touch the engine; in exchange, carries no logic.
--
-- Translates between Luanti's engine API and the pure modules. All the
-- decisions live in emerge.lua; this file only maps EMERGE_* constants to
-- strings and forwards the callback. Covered by the integration harness, not
-- by busted -- see docs/implementation_plan.md, "Testing strategy".

--- @param deps table { emerge = <src/emerge.lua> }
--- @return table world adapter
return function(deps)
    local world = {}

    local function kind_of(action)
        if action == core.EMERGE_ERRORED then
            return "errored"
        elseif action == core.EMERGE_CANCELLED then
            return "cancelled"
        end
        return "ok"
    end

    --- Emerge every mapblock intersecting the box, then call on_done once.
    --- @param p1 table {x,y,z} minimum corner
    --- @param p2 table {x,y,z} maximum corner
    --- @param on_done function(result) result as returned by emerge.tracker
    function world.emerge(p1, p2, on_done)
        local tracker = deps.emerge.tracker()
        core.emerge_area(p1, p2, function(_, action, calls_remaining)
            local result = tracker:step(kind_of(action), calls_remaining)
            if result then
                on_done(result)
            end
        end)
    end

    return world
end
