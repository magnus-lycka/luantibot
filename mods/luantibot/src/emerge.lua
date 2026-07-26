-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- Accounting for core.emerge_area's callback protocol. The engine calls back
-- once per mapblock with a `calls_remaining` countdown; the emerge is complete
-- when that reaches zero, whatever happened along the way.
--
-- CANCELLED is treated as a failure even though the engine documents it as
-- "not an error". Its causes -- shutdown, outside mapgen limits, already being
-- emerged -- all leave the block *not present*, and a VoxelManip over a block
-- that was never loaded reads `ignore`, which we must never write back. Since
-- one job runs at a time, the benign "already being emerged" case should not
-- arise; if it ever does, that is a bug worth surfacing rather than ignoring.

local emerge = {}

local Tracker = {}
Tracker.__index = Tracker

--- Track one emerge_area call to completion.
--- @return table tracker
function emerge.tracker()
    return setmetatable({
        blocks = 0,
        errored = 0,
        cancelled = 0,
        resolved = false,
    }, Tracker)
end

--- Record one engine callback.
--- @param kind string "ok", "errored" or "cancelled"
--- @param calls_remaining number blocks still to be reported
--- @return table|nil result once complete, nil while still in progress
function Tracker:step(kind, calls_remaining)
    if self.resolved then
        return nil
    end

    self.blocks = self.blocks + 1
    if kind == "errored" then
        self.errored = self.errored + 1
    elseif kind == "cancelled" then
        self.cancelled = self.cancelled + 1
    end

    if calls_remaining ~= 0 then
        return nil
    end

    self.resolved = true
    local result = {
        ok = self.errored == 0 and self.cancelled == 0,
        blocks = self.blocks,
        errored = self.errored,
        cancelled = self.cancelled,
    }
    if not result.ok then
        result.error = string.format(
            "emerge failed: %d errored, %d cancelled of %d mapblocks",
            self.errored,
            self.cancelled,
            self.blocks
        )
    end
    return result
end

return emerge
