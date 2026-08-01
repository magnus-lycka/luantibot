-- The HTTP adapter. It is meant to carry no logic, but it does carry a little:
-- how a reply becomes a response description. `ok` folds two engine flags into
-- one, a missing body is nil rather than an error, and an absent code becomes 0.
-- poll.lua acts on all three, so they are worth pinning.
--
-- `core` is an engine global here rather than an injected dependency. Faking it
-- in the spec is the smaller evil: this module's whole job is to touch the
-- engine, and injecting json encoding to make it testable would push engine
-- detail into the caller for no gain.

local factory = require("client")

--- Records what the engine was asked to do, and lets the test drive the reply.
local function engine()
    local e = { fetches = {}, logs = {} }

    _G.core = {
        write_json = function(t)
            -- Enough to assert on; the real encoder is the engine's problem.
            local parts = {}
            for k, v in pairs(t) do
                parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
            end
            table.sort(parts)
            return "{" .. table.concat(parts, ",") .. "}"
        end,
        parse_json = function(s)
            if s == "BAD" then
                return nil
            end
            return { parsed = s }
        end,
        log = function(level, msg)
            e.logs[#e.logs + 1] = { level = level, msg = msg }
        end,
    }

    e.client = factory({
        http = {
            fetch = function(fetch, cb)
                e.fetches[#e.fetches + 1] = fetch
                e.reply = cb
            end,
        },
        base_url = "http://svc:8099",
        timeout = 7,
    })
    return e
end

--- Send a request and hand back the response the adapter produced.
local function roundtrip(e, req, raw)
    local got
    e.client.send(req, function(res)
        got = res
    end)
    e.reply(raw)
    return got
end

describe("client.send request", function()
    local e
    before_each(function()
        e = engine()
    end)

    it("joins the base url and the path", function()
        e.client.send({ method = "GET", path = "/v1/worlds" }, function() end)
        assert.are.equal("http://svc:8099/v1/worlds", e.fetches[1].url)
        assert.are.equal("GET", e.fetches[1].method)
    end)

    it("passes the configured timeout", function()
        e.client.send({ method = "GET", path = "/x" }, function() end)
        assert.are.equal(7, e.fetches[1].timeout)
    end)

    it("always asks for json", function()
        e.client.send({ method = "GET", path = "/x" }, function() end)
        assert.are.same({ "Accept: application/json" }, e.fetches[1].extra_headers)
    end)

    it("sends no body and no content type when there is none", function()
        e.client.send({ method = "GET", path = "/x" }, function() end)
        assert.is_nil(e.fetches[1].data)
        assert.are.equal(1, #e.fetches[1].extra_headers)
    end)

    it("encodes a body and declares its type", function()
        e.client.send({ method = "POST", path = "/x", body = { a = 1 } }, function() end)
        assert.are.equal("{a=1}", e.fetches[1].data)
        assert.are.same({
            "Accept: application/json",
            "Content-Type: application/json",
        }, e.fetches[1].extra_headers)
    end)

    -- An empty table is a body: `POST /started {}` is how the mod reports.
    it("treats an empty body as a body", function()
        e.client.send({ method = "POST", path = "/x", body = {} }, function() end)
        assert.are.equal("{}", e.fetches[1].data)
        assert.are.equal(2, #e.fetches[1].extra_headers)
    end)

    it("logs the request at verbose, which is the only trace of a poll", function()
        e.client.send({ method = "GET", path = "/v1/worlds" }, function() end)
        assert.are.equal("verbose", e.logs[1].level)
        assert.matches("GET /v1/worlds", e.logs[1].msg)
    end)
end)

describe("client.send response", function()
    local e
    before_each(function()
        e = engine()
    end)

    it("is ok only when the engine reports both succeeded and completed", function()
        local req = { method = "GET", path = "/x" }
        assert.is_true(roundtrip(e, req, { succeeded = true, completed = true, code = 200 }).ok)
        assert.is_false(roundtrip(e, req, { succeeded = false, completed = true, code = 200 }).ok)
        assert.is_false(roundtrip(e, req, { succeeded = true, completed = false, code = 200 }).ok)
    end)

    it("parses a body when there is one", function()
        local res = roundtrip(e, { method = "GET", path = "/x" }, {
            succeeded = true,
            completed = true,
            code = 200,
            data = "hello",
        })
        assert.are.same({ parsed = "hello" }, res.body)
    end)

    -- poll.lua reads a missing body on a 200 as "no work", so this must be nil
    -- rather than an empty table or an error.
    it("leaves the body nil when the reply is empty", function()
        local res = roundtrip(e, { method = "GET", path = "/x" }, {
            succeeded = true,
            completed = true,
            code = 204,
            data = "",
        })
        assert.is_nil(res.body)
    end)

    it("leaves the body nil when there is no data field at all", function()
        local res = roundtrip(e, { method = "GET", path = "/x" }, {
            succeeded = true,
            completed = true,
            code = 204,
        })
        assert.is_nil(res.body)
    end)

    it("leaves the body nil when the json is malformed", function()
        local res = roundtrip(e, { method = "GET", path = "/x" }, {
            succeeded = true,
            completed = true,
            code = 200,
            data = "BAD",
        })
        assert.is_nil(res.body)
    end)

    -- A refused connection has no status. 0 is what poll.lua's `failed()` looks
    -- for, so it must not arrive as nil.
    it("reports a missing status code as 0", function()
        local res = roundtrip(e, { method = "GET", path = "/x" }, { succeeded = false })
        assert.are.equal(0, res.code)
    end)

    it("passes the status code through otherwise", function()
        local res = roundtrip(e, { method = "GET", path = "/x" }, {
            succeeded = true,
            completed = true,
            code = 409,
        })
        assert.are.equal(409, res.code)
    end)
end)
