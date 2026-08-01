-- ADAPTER. May touch the engine; in exchange, carries no logic.
--
-- The world's cached identity. Mod storage is per-mod, per-world, living in
-- <world>/mod_storage.sqlite -- it travels with the world directory, which is
-- what makes the binding durable across renames, and also why a copied world
-- inherits its parent's id.

--- @param deps table { storage = <core.get_mod_storage()> }
--- @return table storage adapter
return function(deps)
    local store = {}
    local KEY = "world_id"

    --- @return number|nil
    function store.world_id()
        local raw = deps.storage:get_string(KEY)
        if raw == nil or raw == "" then
            return nil
        end
        return tonumber(raw)
    end

    --- @param id number
    function store.set_world_id(id)
        deps.storage:set_string(KEY, tostring(id))
    end

    function store.clear()
        deps.storage:set_string(KEY, "")
    end

    local JOB_KEY = "current_job"

    --- The job this server was executing when it last wrote here.
    ---
    --- Written before the first node is touched and cleared once the job
    --- reaches a terminal state, so a value surviving a restart means the
    --- server died mid-job. That is what the mod reports as `abandoned` --
    --- a confession, as against the `interrupted` the service infers from a
    --- cold heartbeat. See "Crash recovery protocol" in
    --- docs/implementation_plan.md.
    --- @return number|nil
    function store.job_id()
        local raw = deps.storage:get_string(JOB_KEY)
        if raw == nil or raw == "" then
            return nil
        end
        return tonumber(raw)
    end

    --- @param id number|nil nil clears it
    function store.set_job_id(id)
        deps.storage:set_string(JOB_KEY, id and tostring(id) or "")
    end

    return store
end
