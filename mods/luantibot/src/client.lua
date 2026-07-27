-- ADAPTER. May touch the engine; in exchange, carries no logic.
--
-- Turns poll.lua's request descriptions into core.request_http_api() calls and
-- normalises the replies back into response descriptions. All decisions about
-- what to request and what a reply means live in poll.lua.

--- @param deps table { http = <handle from core.request_http_api()>, base_url, timeout }
--- @return table client adapter
return function(deps)
    local client = {}

    --- @param req table { method, path, body }
    --- @param on_response function(res) res = { ok, code, body }
    function client.send(req, on_response)
        local fetch = {
            url = deps.base_url .. req.path,
            method = req.method,
            timeout = deps.timeout or 10,
            extra_headers = { "Accept: application/json" },
        }
        if req.body ~= nil then
            fetch.data = core.write_json(req.body)
            fetch.extra_headers[#fetch.extra_headers + 1] = "Content-Type: application/json"
        end

        core.log("verbose", "[luantibot] " .. req.method .. " " .. req.path)

        deps.http.fetch(fetch, function(res)
            local body = nil
            if res.data and res.data ~= "" then
                -- parse_json returns nil on malformed input; poll.lua treats a
                -- missing body on a 200 as "no work", which is the safe read.
                body = core.parse_json(res.data)
            end
            on_response({
                ok = res.succeeded and res.completed,
                code = res.code or 0,
                body = body,
            })
        end)
    end

    return client
end
