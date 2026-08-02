-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Reading the world instead of writing it: per column, the height of the first
-- surface you could stand on, and what it is made of. That is what Python needs
-- to decide where a road tunnels, where it bridges, and how far a pillar falls.
--
-- **A node is not a full cube, and this is the module where that matters.** A
-- trapdoor occupies the bottom of its cell and leaves the rest open; a slab
-- fills half; tallgrass and snow fill almost nothing but are still nodes. A
-- survey that reported "the highest cell containing anything" would put the
-- surface on top of a flower and hang a bridge in the air. So the test is
-- `walkable`, injected from the node registry, and never "is not air".
--
-- Sampling is anchored to where the caller's box began, which `plan.clip_ops`
-- preserves as `anchor` when it trims an op to a unit. Anchoring to the trimmed
-- corner would shift the grid from unit to unit, giving duplicates on one side
-- of a seam and holes on the other; anchoring to absolute zero would mean a box
-- containing no multiple of the step -- a single line at z=-1354, sampled every
-- eighth column -- reports nothing at all.

--- @param deps table {
---   walkable = function(content_id) -> boolean,
---   name     = function(content_id) -> string }
return function(deps)
    local survey = {}

    --- The first sample at or after `v` on a grid of `step` through `anchor`.
    local function first_sample(v, step, anchor)
        return anchor + math.ceil((v - anchor) / step) * step
    end

    --- Scan every sampled column in the box, top down, for the first walkable
    --- node.
    ---
    --- Top down rather than bottom up because the answer wanted is the surface,
    --- not the floor: a column over a cave has solid ground both above and
    --- below the void, and only the upper one is somewhere you could build.
    ---
    --- @param buf table { data = <content ids> }
    --- @param area table VoxelArea or equivalent
    --- @param lo table {x,y,z} box minimum, already clipped to the area
    --- @param hi table {x,y,z} box maximum
    --- @param step number sample every Nth column on both axes
    --- @param anchor table|nil {x,z} the grid passes through this point;
    ---   defaults to `lo`, which is right only when the box was never clipped
    --- @return table array of { x, z, y, node }, and { x, z } alone when the
    ---   column held nothing solid
    function survey.columns(buf, area, lo, hi, step, anchor)
        step = step or 1
        anchor = anchor or lo
        local out = {}
        local data = buf.data

        for z = first_sample(lo.z, step, anchor.z), hi.z, step do
            for x = first_sample(lo.x, step, anchor.x), hi.x, step do
                local found = nil
                for y = hi.y, lo.y, -1 do
                    local id = data[area:index(x, y, z)]
                    if id ~= nil and deps.walkable(id) then
                        found = { x = x, z = z, y = y, node = deps.name(id) }
                        break
                    end
                end
                out[#out + 1] = found or { x = x, z = z }
            end
        end

        return out
    end

    --- Fold one unit's columns into the accumulating result.
    ---
    --- A column can be split across units when the job is taller than one, and
    --- the units are walked bottom up. The higher answer wins: it is nearer the
    --- sky, and a lower unit reporting solid ground says nothing about whether
    --- there is more above it.
    ---
    --- @param acc table keyed by "x,z"
    --- @param found table as returned by survey.columns
    function survey.merge(acc, found)
        for _, c in ipairs(found) do
            local key = c.x .. "," .. c.z
            local seen = acc[key]
            if seen == nil or (c.y ~= nil and (seen.y == nil or c.y > seen.y)) then
                acc[key] = c
            end
        end
        return acc
    end

    --- The accumulated columns as a plain array, in a stable order.
    ---
    --- Sorted because the result crosses the wire and is diffed by humans and
    --- tests; unit order is an implementation detail nobody should see.
    function survey.finish(acc)
        local out = {}
        for _, c in pairs(acc) do
            out[#out + 1] = c
        end
        table.sort(out, function(a, b)
            if a.z ~= b.z then
                return a.z < b.z
            end
            return a.x < b.x
        end)
        return out
    end

    return survey
end
