-- PURE MODULE. Must not reference core, VoxelManip, or any engine global.
--
-- The polling state machine. Luanti cannot run an incoming HTTP server, so the
-- mod is the client: it asks the service for work and posts results back.
--
-- This module never touches HTTP. It emits *request descriptions* and consumes
-- *response descriptions*, which is what makes it testable in a bare Lua
-- interpreter; init.lua turns those into core.request_http_api() calls.
--
--     register --> idle <--> busy --> (report) --> idle
--
-- One request is in flight at a time. Nothing is emitted while busy, because
-- the executor owns the world then and reserving a second job would strand it.

local poll = {}

local Poll = {}
Poll.__index = Poll

--- @param cfg table { world_name, world_id?, interval?, backoff_max? }
function poll.new(cfg)
    local self = setmetatable({
        world_name = cfg.world_name,
        _world_id = cfg.world_id,
        interval = cfg.interval or 2,
        backoff_max = cfg.backoff_max or 30,

        _wait = 0,
        _elapsed = 0,
        _inflight = nil,
        _job = nil,
        _report = nil,
        -- Bumped on rebind/forget so a response from the previous identity can
        -- be recognised as stale and dropped.
        _epoch = 1,
    }, Poll)
    self._state = self._world_id and "idle" or "register"
    return self
end

function Poll:state()
    return self._state
end

function Poll:world_id()
    return self._world_id
end

function Poll:wait()
    return self._wait
end

--- Drop the cached identity; the next tick re-registers.
function Poll:forget()
    self._world_id = nil
    self._state = "register"
    self:_reset_timing()
end

--- Re-register under a different name. This is what splits a copied world off
--- from the original: `cp -r`, boot, rebind.
function Poll:rebind(name)
    self.world_name = name
    self:forget()
end

function Poll:_reset_timing()
    self._epoch = self._epoch + 1
    self._inflight = nil
    self._wait = 0
    self._elapsed = 0
end

--- Advance the clock. Returns a request table, or nil if there is nothing to do.
--- Request: { kind, method, path, body }
function Poll:tick(dtime)
    if self._inflight or self._state == "busy" then
        return nil
    end

    self._elapsed = self._elapsed + (dtime or 0)
    if self._elapsed < self._wait then
        return nil
    end
    self._elapsed = 0

    local req
    if self._state == "register" then
        req = {
            kind = "register",
            method = "POST",
            path = "/v1/worlds",
            body = { name = self.world_name },
        }
    elseif self._state == "report" then
        req = self._report
    else
        req = {
            kind = "next",
            method = "GET",
            path = string.format("/v1/worlds/%d/jobs/next", self._world_id),
        }
    end

    self._inflight = { kind = req.kind, epoch = self._epoch }
    return req
end

local function failed(res)
    return not res.ok or (res.code or 0) >= 400 or (res.code or 0) == 0
end

function Poll:_backoff()
    local base = self._wait > 0 and self._wait or self.interval
    self._wait = math.min(base * 2, self.backoff_max)
    self._elapsed = 0
end

function Poll:_succeeded()
    self._wait = self.interval
    self._elapsed = 0
end

--- Feed an HTTP result back in. Returns an event describing what it meant:
---   { kind = "registered", world_id }  { kind = "job", job }
---   { kind = "none" }  { kind = "reported" }  { kind = "error", message }
---   { kind = "stale" } -- arrived after a rebind, ignored
--- @param res table { ok = boolean, code = number, body = table|nil }
function Poll:on_response(res)
    local inflight = self._inflight
    if not inflight then
        return { kind = "stale" }
    end
    if inflight.epoch ~= self._epoch then
        -- Identity changed while this was in flight. Acting on it would attach
        -- work to the world we just stopped being.
        return { kind = "stale" }
    end
    self._inflight = nil

    if inflight.kind == "report" then
        -- The job is finished either way, and the service sweeps a row whose
        -- heartbeat went cold. Retrying a report forever would strand the mod.
        self._state = "idle"
        self._report = nil
        self._job = nil
        if failed(res) then
            self:_backoff()
            return { kind = "error", message = "completion report was not accepted" }
        end
        self:_succeeded()
        self._elapsed = self._wait
        return { kind = "reported" }
    end

    if failed(res) then
        self:_backoff()
        return {
            kind = "error",
            message = string.format("request failed (code %s)", tostring(res.code)),
        }
    end

    if inflight.kind == "register" then
        local id = res.body and res.body.world_id
        if type(id) ~= "number" then
            self:_backoff()
            return { kind = "error", message = "registration response had no world_id" }
        end
        self._world_id = id
        self._state = "idle"
        self:_succeeded()
        -- Registered: go looking for work without waiting out an interval.
        self._elapsed = self._wait
        return { kind = "registered", world_id = id }
    end

    -- kind == "next"
    self:_succeeded()
    if res.code == 204 or res.body == nil then
        return { kind = "none" }
    end

    self._job = res.body
    self._state = "busy"
    return { kind = "job", job = res.body }
end

--- The executor tells us the job is done. `payload` is the completion body, or
--- `{ code, message }` on failure.
function Poll:finish(ok, payload)
    if self._state ~= "busy" or not self._job then
        return false
    end
    self._report = {
        kind = "report",
        method = "POST",
        path = string.format("/v1/jobs/%d/%s", self._job.job_id, ok and "completed" or "failed"),
        body = payload or {},
    }
    self._state = "report"
    -- Report at once rather than after another poll interval.
    self._wait = 0
    self._elapsed = 0
    return true
end

return poll
