-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Chat command argument parsing. Kept out of init.lua so it can be unit tested;
-- init.lua only wires the result into core.register_chatcommand.

local parse = {}

local function words(s)
    local out = {}
    for w in string.gmatch(s, "%S+") do
        out[#out + 1] = w
    end
    return out
end

local function to_int(s)
    local n = tonumber(s)
    if n == nil then
        return nil
    end
    -- Rejects NaN, infinities (tonumber("1e400") is inf) and fractions.
    if n ~= n or n <= -math.huge or n >= math.huge or math.floor(n) ~= n then
        return nil
    end
    return n
end

--- Parse "<x> <y> <z> <radius>".
--- @param param string|nil raw chat command argument string
--- @return table|nil centre, number|string radius on success, error on failure
function parse.emerge_args(param)
    if type(param) ~= "string" then
        return nil, "expected: <x> <y> <z> <radius>"
    end

    local w = words(param)
    if #w ~= 4 then
        return nil, "expected 4 arguments: <x> <y> <z> <radius>"
    end

    local values = {}
    for i = 1, 4 do
        local n = to_int(w[i])
        if n == nil then
            return nil, string.format("argument %d (%q) is not an integer", i, w[i])
        end
        values[i] = n
    end

    return { x = values[1], y = values[2], z = values[3] }, values[4]
end

return parse
