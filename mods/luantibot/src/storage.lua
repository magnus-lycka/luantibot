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

    return store
end
