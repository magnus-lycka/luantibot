-- ADAPTER. May touch the engine; in exchange, carries no logic.
--
-- Translates between Luanti's engine API and the pure modules. All the
-- decisions live in emerge.lua; this file only maps EMERGE_* constants to
-- strings and forwards the callback. Covered by the integration harness, not
-- by busted -- see docs/implementation_plan.md, "Testing strategy".

--- @param deps table { emerge = <src/emerge.lua>, apply = <src/apply.lua> }
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

    --- Emerge the box, then apply the job's ops to it through a VoxelManip.
    ---
    --- The read region the engine hands back is at least the box and usually
    --- larger, since it aligns to mapblocks. That is harmless: apply.lua clips
    --- to the area, and validate.lua has already refused any op reaching outside
    --- `bounds`, so nothing is written beyond what the job asked for.
    ---
    --- @param p1 table {x,y,z} minimum corner
    --- @param p2 table {x,y,z} maximum corner
    --- @param job_ops table the job's op list, already validated
    --- @param pal table compiled palette, answering :id(wire_index)
    --- @param on_done function(result)
    function world.build(p1, p2, job_ops, pal, on_done)
        world.emerge(p1, p2, function(result)
            if not result.ok then
                return on_done(result)
            end

            local vm = core.get_voxel_manip()
            local emin, emax = vm:read_from_map(p1, p2)
            local area = VoxelArea:new({ MinEdge = emin, MaxEdge = emax })
            local data = vm:get_data()

            local written, code, message = deps.apply.run(data, area, job_ops, pal)
            if written == nil then
                return on_done({
                    ok = false,
                    code = code,
                    error = message,
                    blocks = result.blocks,
                })
            end

            vm:set_data(data)
            -- `false` is the lighting flag. M2 writes raw nodes and nothing
            -- else: no lighting pass, no liquid update. Both arrive later, and
            -- calling them here would make the result depend on node callbacks
            -- a VoxelManip write deliberately bypasses.
            vm:write_to_map(false)

            on_done({ ok = true, blocks = result.blocks, written = written })
        end)
    end

    return world
end
