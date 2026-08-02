-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Job validation. The mod is the last authority before the world changes, so
-- everything here fails closed: anything not positively known to be valid is
-- rejected.
--
-- Covers rules 1, 2 and 4-7 of the wire contract. Rule 3 (palette resolution)
-- lives in palette.lua, which is the only module that can resolve a name to a
-- content id and so the only one that can tell whether an entry is real. See
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
    ---
    --- Since M4 this bounds *ambition*, not memory -- work units keep a
    --- VoxelManip small however large the job is. It stays at 4096 because
    --- nothing can cancel a running job, so this is the only limit on one that
    --- was a mistake. See `geometry.MAX_MAPBLOCKS` for the longer version.
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

    --- Rule 5, for one op's box: well formed, and inside the job's `bounds`.
    ---
    --- Containment is not a formality. `bounds` is what gets emerged and what
    --- the VoxelManip covers, so an op reaching outside it would be silently
    --- clipped by apply.lua and build something other than what was asked for.
    --- Refusing is the only way the caller finds out.
    local function check_box(op, index, lo, hi)
        local a = corner(op.min)
        local b = corner(op.max)
        if not a or not b then
            return "bad_box", string.format("op %d: min and max must each be three integers", index)
        end

        for _, axis in ipairs({ "x", "y", "z" }) do
            if a[axis] > b[axis] then
                return "bad_box", string.format("op %d: min exceeds max on %s", index, axis)
            end
            if a[axis] < lo[axis] or b[axis] > hi[axis] then
                return "box_outside_bounds",
                    string.format("op %d: box reaches outside the job bounds on %s", index, axis)
            end
        end

        return nil
    end

    --- Shared by fill_box and fill_box_if: box inside bounds, palette index and
    --- param2 well formed.
    local function check_fill(op, index, lo, hi)
        local code, message = check_box(op, index, lo, hi)
        if code then
            return code, message
        end
        -- The palette index only has to be a sane integer here; whether it
        -- names an entry is settled by palette.lua once the palette is
        -- resolved, which is the only place that knows the size.
        if not is_int(op.node) or op.node < 0 then
            return "bad_op",
                string.format("op %d: node must be a non-negative palette index", index)
        end
        -- Optional: absent means 0. One byte in the engine, so anything
        -- outside 0-255 is a caller error rather than something to truncate.
        if op.param2 ~= nil and (not is_int(op.param2) or op.param2 < 0 or op.param2 > 255) then
            return "bad_op", string.format("op %d: param2 must be 0-255", index)
        end
        return nil
    end

    --- What each op type requires beyond its box. Rule 4 is membership of this
    --- table: an op this mod does not implement is refused rather than skipped,
    --- so a job written against a newer service does not half-execute.
    local op_checks = {
        emerge = function()
            return nil
        end,

        fill_box = check_fill,

        -- Read-only, so no palette and no param2 -- only a box and how coarsely
        -- to sample it. A step of 0 would divide by zero in the sampler; a
        -- negative one would loop forever.
        survey = function(op, index, lo, hi)
            local code, message = check_box(op, index, lo, hi)
            if code then
                return code, message
            end
            if op.step ~= nil and (not is_int(op.step) or op.step < 1) then
                return "bad_op", string.format("op %d: step must be a positive integer", index)
            end
            return nil
        end,

        fill_box_if = function(op, index, lo, hi)
            local code, message = check_fill(op, index, lo, hi)
            if code then
                return code, message
            end
            -- Names and groups are only resolved once the registry is
            -- reachable; all this can say is that the list is well formed.
            if type(op.match) ~= "table" or #op.match == 0 then
                return "bad_op", string.format("op %d: match must be a non-empty list", index)
            end
            for j = 1, #op.match do
                if type(op.match[j]) ~= "string" then
                    return "bad_op",
                        string.format("op %d: match entry %d is not a string", index, j - 1)
                end
            end
            if op.invert ~= nil and type(op.invert) ~= "boolean" then
                return "bad_op", string.format("op %d: invert must be a boolean", index)
            end
            return nil
        end,
    }

    --- @return string|nil code, string|nil message
    local function check_ops(job, lo, hi)
        for i, op in ipairs(job.ops) do
            if type(op) ~= "table" then
                return "bad_ops", string.format("op %d is not a table", i)
            end
            local check = op_checks[op.op]
            if not check then
                return "unknown_op", string.format("op %d: unknown op %q", i, tostring(op.op))
            end
            local code, message = check(op, i, lo, hi)
            if code then
                return code, message
            end
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

        -- After check_bounds, so op containment is compared against corners
        -- already known to be well formed.
        local lo, hi = validate.positions(job)
        code, message = check_ops(job, lo, hi)
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

    --- The op list with every box converted from wire arrays to positions.
    ---
    --- On the wire a corner is `[x, y, z]`, which `core.parse_json` hands over
    --- as `{[1]=x, [2]=y, [3]=z}`; the pure modules and the engine both use
    --- `{x=, y=, z=}`. Something has to translate, and doing it here means it
    --- happens once, in the module that has already checked every corner is
    --- three integers -- rather than in each op handler, differently.
    ---
    --- Returns copies. The job document is what gets reported back, so it keeps
    --- the shape it arrived in.
    --- @param job table a job that has passed validate.job
    --- @return table ops
    function validate.ops_as_positions(job)
        local out = {}
        for i, op in ipairs(job.ops) do
            local copy = {}
            for k, v in pairs(op) do
                copy[k] = v
            end
            if op.min ~= nil then
                copy.min = corner(op.min)
                copy.max = corner(op.max)
            end
            out[i] = copy
        end
        return out
    end

    return validate
end
