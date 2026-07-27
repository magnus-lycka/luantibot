-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Job validation. The mod is the last authority before the world changes, so
-- everything here fails closed: anything not positively known to be valid is
-- rejected.
--
-- Rules 1 and 2 of the wire contract land here in M1.4. The rest (palette,
-- op types, box geometry, volume caps) arrive in M2 with the ops that need
-- them. See "Wire contract" in docs/implementation_plan.md.
--
-- A factory rather than a plain table, because `require()` is disabled under
-- Luanti's mod security: a pure module cannot import another pure module, so
-- sibling dependencies are injected exactly like engine capabilities are.

--- @param deps table { version = <src/version.lua> }
return function(deps)
    local validate = {}

    --- Check a job document against this server's identity.
    --- @param job table the decoded job document
    --- @param ctx table { world_id = <this server's registered id, or nil> }
    --- @return boolean ok, string|nil code, string|nil message
    function validate.job(job, ctx)
        if type(job) ~= "table" then
            return false, "bad_job", "job document is not a table"
        end

        if not deps.version.supported(job.format) then
            return false,
                "bad_format",
                string.format("unsupported wire format %s", tostring(job.format))
        end

        -- Rule 2. The service should never offer another world's job, so
        -- reaching here means something is misconfigured -- fail loudly rather
        -- than guess. An unregistered server has no identity to compare
        -- against and cannot prove the job is its own, which is also a refusal.
        if ctx.world_id == nil or job.world_id ~= ctx.world_id then
            return false,
                "wrong_world",
                string.format(
                    "job is for world %s, this server is world %s",
                    tostring(job.world_id),
                    tostring(ctx.world_id)
                )
        end

        if type(job.ops) ~= "table" then
            return false, "bad_ops", "job has no ops list"
        end

        return true
    end

    return validate
end
