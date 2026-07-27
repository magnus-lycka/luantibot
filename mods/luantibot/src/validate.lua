-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Job validation. The mod is the last authority before the world changes, so
-- everything here fails closed: anything not positively known to be valid is
-- rejected.
--
-- Covers rules 1, 2 and 5-7 of the wire contract. Rules 3 and 4 (palette
-- resolution, op vocabulary) arrive in M2 with the ops that need them. See
-- "Wire contract" in docs/implementation_plan.md.
--
-- A factory rather than a plain table, because `require()` is disabled under
-- Luanti's mod security: a pure module cannot import another pure module, so
-- sibling dependencies are injected exactly like engine capabilities are.

--- @param deps table { version = <src/version.lua>, plan = <src/plan.lua> }
return function(deps)
    local validate = {}

    --- Luanti refuses to generate beyond this; a job naming coordinates outside
    --- it is malformed rather than merely ambitious.
    validate.WORLD_LIMIT = 31000

    --- Applied when the caller supplies no cap. Never unlimited: a job arriving
    --- over HTTP must not be able to ask for an unbounded region.
    validate.DEFAULT_MAX_BLOCKS = 4096

    local function is_int(v)
        if type(v) ~= "number" or v ~= v then
            return false
        end
        return v > -math.huge and v < math.huge and math.floor(v) == v
    end

    local function corner(c)
        if type(c) ~= "table" or #c ~= 3 then
            return nil
        end
        for i = 1, 3 do
            if not is_int(c[i]) then
                return nil
            end
        end
        return { x = c[1], y = c[2], z = c[3] }
    end

    --- Rules 5-7: well-formed box, inside the world, under the volume cap.
    --- @return string|nil code, string|nil message -- nil, nil when the box is fine
    local function check_bounds(job, ctx)
        local bounds = job.bounds
        if type(bounds) ~= "table" then
            return "bad_bounds", "job has no bounds"
        end

        local p1 = corner(bounds.min)
        local p2 = corner(bounds.max)
        if not p1 or not p2 then
            return "bad_bounds", "bounds corners must each be three integers"
        end

        for _, axis in ipairs({ "x", "y", "z" }) do
            if p1[axis] > p2[axis] then
                return "bad_bounds", "bounds.min exceeds bounds.max on " .. axis
            end
            if
                math.abs(p1[axis]) > validate.WORLD_LIMIT
                or math.abs(p2[axis]) > validate.WORLD_LIMIT
            then
                return "out_of_range",
                    string.format("bounds exceed the world limit of %d", validate.WORLD_LIMIT)
            end
        end

        local max_blocks = ctx.max_blocks or validate.DEFAULT_MAX_BLOCKS
        local blocks = deps.plan.block_count(p1, p2)
        if blocks > max_blocks then
            return "too_large",
                string.format("job spans %d mapblocks, over the limit of %d", blocks, max_blocks)
        end

        return nil
    end

    --- Check a job document against this server's identity and limits.
    --- @param job table the decoded job document
    --- @param ctx table { world_id = <registered id or nil>, max_blocks = <cap> }
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

        if type(job.ops) ~= "table" or #job.ops == 0 then
            return false, "bad_ops", "job has no ops list"
        end

        local code, message = check_bounds(job, ctx)
        if code then
            return false, code, message
        end

        return true
    end

    --- Bounds as engine positions, for a job that has already validated.
    --- @return table p1, table p2
    function validate.positions(job)
        return corner(job.bounds.min), corner(job.bounds.max)
    end

    return validate
end
