-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Executing a job across the world, one work unit at a time. This was an
-- adapter while it only forwarded an emerge callback; the unit walk, the
-- progress accounting and the decision to skip a VoxelManip are logic, and
-- logic in an adapter is logic without tests. The engine is injected instead --
-- see "The constraint that makes Lua testable" in docs/implementation_plan.md.
--
-- The contract this module owes its caller, and the reason `spec/world_spec.lua`
-- exists: **a unit never writes outside itself.** The VoxelManip hands back a
-- region at least as large as the unit and often larger, and apply.lua clips to
-- that region, not to the unit -- so the containment comes from clipping the
-- ops first, and nothing else. Break it and units stop being disjoint in what
-- they write, which is what unit-major execution rests on.

--- @param deps table {
---   emerge = <src/emerge.lua>,
---   apply  = <src/apply.lua>,
---   plan   = <src/plan.lua>,
---   emerge_area = function(p1, p2, on_block) -- on_block(kind, calls_remaining)
---   voxelmanip  = function(p1, p2) -> {
---       area, data, param2, write = function(data, param2) } }
--- @return table world
return function(deps)
    local world = {}

    --- Emerge every mapblock intersecting the box, then call on_done once.
    --- @param p1 table {x,y,z} minimum corner
    --- @param p2 table {x,y,z} maximum corner
    --- @param on_done function(result) result as returned by emerge.tracker
    function world.emerge(p1, p2, on_done)
        local tracker = deps.emerge.tracker()
        deps.emerge_area(p1, p2, function(kind, calls_remaining)
            local result = tracker:step(kind, calls_remaining)
            if result then
                on_done(result)
            end
        end)
    end

    --- Emerge one unit, apply the ops clipped to it, write it back.
    local function build_unit(unit, job_ops, pal, done)
        -- Clipped here and nowhere else. apply.lua bounds writes to the
        -- VoxelManip region, which reaches past the unit; this is what keeps
        -- them inside it.
        local unit_ops = deps.plan.clip_ops(job_ops, unit.min, unit.max)

        world.emerge(unit.min, unit.max, function(result)
            if not result.ok then
                return done(result)
            end

            -- Nothing writes here. Reading a VoxelManip back would mark every
            -- mapblock in the unit modified for no reason, which matters for a
            -- job whose bounds are large but whose ops touch only part of it.
            if not deps.apply.writes(unit_ops) then
                return done({ ok = true, blocks = result.blocks, written = 0 })
            end

            local vm = deps.voxelmanip(unit.min, unit.max)
            -- Both arrays: a node is content plus param2, and writing one
            -- without the other leaves the new node wearing the old one's
            -- orientation.
            local buf = { data = vm.data, param2 = vm.param2 }

            local written, code, message = deps.apply.run(buf, vm.area, unit_ops, pal)
            if written == nil then
                return done({ ok = false, code = code, error = message })
            end

            vm.write(buf.data, buf.param2)
            done({ ok = true, blocks = result.blocks, written = written })
        end)
    end

    --- Build across the whole of `bounds`, one unit at a time.
    ---
    --- The units are walked as a chain of emerge callbacks rather than a loop,
    --- which is what spreads the job over many server steps: each emerge yields
    --- to the engine and resumes on a later step. A job is therefore no longer
    --- bounded by what one VoxelManip can hold.
    ---
    --- Each unit sees the world as the previous ones left it, so ops that
    --- overlap across a seam compose correctly -- and because units are
    --- disjoint in what they write, the result matches op-major reference
    --- semantics. `spec/units_spec.lua` is the proof of that equivalence;
    --- `spec/world_spec.lua` is the proof that this function preserves it.
    ---
    --- @param p1 table {x,y,z} minimum corner
    --- @param p2 table {x,y,z} maximum corner
    --- @param job_ops table the job's op list, already validated
    --- @param pal table compiled palette, answering :id(wire_index)
    --- @param on_progress function(done, total, written)
    --- @param on_done function(result)
    function world.build(p1, p2, job_ops, pal, on_progress, on_done)
        local units = deps.plan.units(p1, p2)
        local total = #units
        local index, blocks, written = 0, 0, 0

        local function next_unit()
            index = index + 1
            if index > total then
                return on_done({
                    ok = true,
                    blocks = blocks,
                    written = written,
                    units = total,
                })
            end

            build_unit(units[index], job_ops, pal, function(result)
                if not result.ok then
                    result.units = total
                    result.units_done = index - 1
                    return on_done(result)
                end
                blocks = blocks + result.blocks
                written = written + result.written
                on_progress(index, total, written)
                next_unit()
            end)
        end

        next_unit()
    end

    return world
end
