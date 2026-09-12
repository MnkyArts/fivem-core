--[[
    core/server/http.lua — Core.Http (DESIGN §24)

    Outbound: `Http.fetch(url, opts)` wraps the `PerformHttpRequest` runtime helper in a promise and
    suspends on `Citizen.Await` until the response or the timeout arrives, so callers read like plain
    code. It must therefore be called from a thread that may yield (a CreateThread body, a command, a
    callback handler) — never from a state-bag change handler or an `onResourceStop`.

    Inbound: `Http.route(method, path, handler)` fills one table that a SINGLE `SetHttpHandler`
    dispatcher reads. Requests reach it as `http://<server>:<port>/core/<path>`. Bodies arrive through
    `req.setDataHandler`, which only fires when a body was actually sent, so bodyless methods dispatch
    straight away and everything else gets a fallback timer — every request is answered exactly once.

    Secrets: `Http.setToken(name, convarName)` reads a plain (non-`setr`) convar, which never reaches a
    client. Tokens are kept in this module only and are never printed, logged or sent to the NUI.

    Outbound host policy: `Config.Http = { AllowPrivate = false, AllowHosts = nil }`. Loopback and
    RFC1918 literals are refused by default and an `AllowHosts` list, when present, is exclusive — so a
    plugin cannot use core to reach the box's own admin ports. Refused hosts are logged at warn.

    Natives: SetHttpHandler (server), GetConvar (shared). PerformHttpRequest is a server runtime helper.
]]

local Http = {}
Core.Http = Http

local Log = Core.Log

local routes = {}            -- [METHOD] = { [path] = handler }
local tokens = {}            -- [name] = secret string (never logged)
local dispatcherInstalled = false
local inflight = 0           -- inbound requests occupying a slot (body wait + handler run)

local DEFAULT_TIMEOUT_MS <const> = 10000
local MIN_TIMEOUT_MS <const> = 1000
local MAX_TIMEOUT_MS <const> = 60000
local BODY_WAIT_MS <const> = 5000       -- fallback when setDataHandler never fires
local MAX_IN_BODY <const> = 1024 * 1024 -- 1 MB inbound body cap
local MAX_QUERY_PAIRS <const> = 32
local MAX_PATH_LEN <const> = 256
local MAX_INFLIGHT <const> = 32         -- inbound concurrency cap (503 above it)
local JSON_TYPE <const> = 'application/json; charset=utf-8'

local METHODS <const> = {
    GET = true, POST = true, PUT = true, PATCH = true, DELETE = true, HEAD = true, OPTIONS = true,
}
local BODYLESS <const> = { GET = true, HEAD = true, OPTIONS = true }

--- 'get' / 'Get' / 'GET' -> 'GET'; nil -> fallback; anything unknown -> nil.
local function normaliseMethod(method, fallback)
    if method == nil then return fallback end
    if type(method) ~= 'string' then return nil end
    local upper = method:upper()
    return METHODS[upper] and upper or nil
end

--- Case-insensitive header lookup (servers send `Content-Type`, proxies send `content-type`).
local function headerValue(headers, name)
    if type(headers) ~= 'table' then return nil end
    local wanted = name:lower()
    for key, value in pairs(headers) do
        if type(key) == 'string' and key:lower() == wanted then
            if type(value) == 'table' then value = value[1] end
            return type(value) == 'string' and value or nil
        end
    end
    return nil
end

local function isJsonType(value)
    return type(value) == 'string' and value:lower():find('application/json', 1, true) ~= nil
end

--- Only string keys/values survive: a header table is handed to the runtime as-is.
local function cleanHeaders(headers)
    local out = {}
    if type(headers) ~= 'table' then return out end
    for key, value in pairs(headers) do
        if type(key) == 'string' and (type(value) == 'string' or type(value) == 'number') then
            out[key] = tostring(value)
        end
    end
    return out
end

local function decodeComponent(s)
    s = s:gsub('+', ' ')
    return (s:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end

--- '/status?id=7&full=1' -> '/status', { id = '7', full = '1' }
local function splitPath(raw)
    if type(raw) ~= 'string' or raw == '' then return '/', {} end
    local path, queryString = raw:match('^([^?]*)%??(.*)$')
    if path == nil or path == '' then path = '/' end
    if #path > MAX_PATH_LEN then path = path:sub(1, MAX_PATH_LEN) end
    local query = {}
    if queryString and queryString ~= '' then
        local pairsSeen = 0
        for chunk in queryString:gmatch('[^&]+') do
            pairsSeen = pairsSeen + 1
            if pairsSeen > MAX_QUERY_PAIRS then break end
            local key, value = chunk:match('^([^=]+)=?(.*)$')
            if key and key ~= '' then query[decodeComponent(key)] = decodeComponent(value or '') end
        end
    end
    return path, query
end

local PRIVATE_HOSTS <const> = {
    localhost = true, ['::1'] = true, ['0.0.0.0'] = true, ['::'] = true, ['ip6-localhost'] = true,
}

--- The host of an absolute URL, lower-cased, without credentials or port ('[::1]:8080' -> '::1').
local function hostOf(url)
    local authority = url:match('^https?://([^/?#]+)')
    if not authority then return nil end
    authority = authority:match('([^@]+)$') or authority
    local host = authority:match('^%[(.-)%]') or authority:match('^([^:]+)')
    if not host or host == '' then return nil end
    return host:lower()
end

--- Loopback / link-local / RFC1918 literals. Only the literal host is checked: a name that *resolves*
--- to a private address still gets through, so this is a guard rail, not a sandbox.
local function isPrivateHost(host)
    if PRIVATE_HOSTS[host] then return true end
    if host:match('^127%.') or host:match('^10%.') or host:match('^192%.168%.')
        or host:match('^169%.254%.') then
        return true
    end
    local block = tonumber(host:match('^172%.(%d+)%.'))
    return block ~= nil and block >= 16 and block <= 31
end

--- `Config.Http = { AllowPrivate = false, AllowHosts = nil }`: an allow-list wins outright, otherwise
--- private ranges are refused unless AllowPrivate is on.
local function hostAllowed(host)
    local cfg = (Core.Config and Core.Config.Http) or {}
    local allow = cfg.AllowHosts
    if type(allow) == 'table' and #allow > 0 then
        for i = 1, #allow do
            if type(allow[i]) == 'string' and allow[i]:lower() == host then return true end
        end
        return false
    end
    if cfg.AllowPrivate == true then return true end
    return not isPrivateHost(host)
end

--- Route paths are stored with exactly one leading slash and no trailing one ('/' stays '/').
local function normalisePath(path)
    if type(path) ~= 'string' or path == '' then return nil end
    if #path > MAX_PATH_LEN then return nil end
    if path:sub(1, 1) ~= '/' then path = '/' .. path end
    if #path > 1 and path:sub(-1) == '/' then path = path:sub(1, -2) end
    if path:find('%s') then return nil end
    return path
end

-- Outbound ------------------------------------------------------------------

local function clampTimeout(value)
    if type(value) ~= 'number' or value ~= value then return DEFAULT_TIMEOUT_MS end
    return math.floor(math.min(MAX_TIMEOUT_MS, math.max(MIN_TIMEOUT_MS, value)))
end

--- One awaited HTTP request. Table bodies are json-encoded; a JSON response is decoded in `pcall`.
--- Yields, so call it from a thread that may wait.
--- @param url string absolute http:// or https:// URL
--- @param opts table|nil { method = 'GET', body = table|string, headers = {}, timeoutMs = 10000 }
--- @return integer|nil status, string|table|nil body, table|nil headers -- nil, reason on failure
function Http.fetch(url, opts)
    if type(url) ~= 'string' or not url:match('^https?://') then
        Log.error('Http.fetch: invalid url %s', tostring(url))
        return nil, 'invalid url'
    end
    local host = hostOf(url)
    if not host then
        Log.error('Http.fetch: invalid url %s', tostring(url))
        return nil, 'invalid url'
    end
    if not hostAllowed(host) then
        Log.warn('Http.fetch: host %s refused by Config.Http', host)
        return nil, 'host not allowed'
    end
    opts = type(opts) == 'table' and opts or {}
    local method = normaliseMethod(opts.method, 'GET')
    if not method then
        Log.error('Http.fetch: invalid method %s', tostring(opts.method))
        return nil, 'invalid method'
    end
    local headers = cleanHeaders(opts.headers)
    local body = opts.body
    if type(body) == 'table' then
        local ok, encoded = pcall(json.encode, Core.Utils.jsonSafe(body))
        if not ok or type(encoded) ~= 'string' then return nil, 'invalid body' end
        body = encoded
        if not headerValue(headers, 'content-type') then headers['Content-Type'] = JSON_TYPE end
    elseif body ~= nil and type(body) ~= 'string' then
        return nil, 'invalid body'
    end

    local p = promise.new()
    local settled = false
    -- Both the response callback and the timeout can arrive; a promise may only be resolved once.
    local function settle(value)
        if settled then return end
        settled = true
        p:resolve(value)
    end
    PerformHttpRequest(url, function(status, responseBody, responseHeaders, errorData)
        settle({ status = status, body = responseBody, headers = responseHeaders, err = errorData })
    end, method, body or '', headers)
    SetTimeout(clampTimeout(opts.timeoutMs), function() settle(false) end)

    local result = Citizen.Await(p)
    if type(result) ~= 'table' then
        Log.warn('Http.fetch: timeout after %d ms', clampTimeout(opts.timeoutMs))
        return nil, 'timeout'
    end
    local status = tonumber(result.status)
    if not status or status < 100 then
        local reason = type(result.err) == 'string' and result.err or 'request failed'
        return nil, reason
    end
    local text = type(result.body) == 'string' and result.body or ''
    local decoded = text
    if text ~= '' and isJsonType(headerValue(result.headers, 'content-type')) then
        local ok, value = pcall(json.decode, text)
        if ok and value ~= nil then decoded = value end
    end
    return math.floor(status), decoded, result.headers
end

-- Secrets -------------------------------------------------------------------

--- Read a secret from a plain (never `setr`/`sets`) convar and keep it in this module only.
--- @return boolean true when the convar held a non-empty value
function Http.setToken(name, convarName)
    if type(name) ~= 'string' or name == '' then return false end
    if type(convarName) ~= 'string' or convarName == '' then return false end
    local value = GetConvar(convarName, '')
    if type(value) ~= 'string' or value == '' then
        tokens[name] = nil
        -- The convar NAME is safe to print, the value is not.
        Log.warn('Http.setToken: convar %s is empty, token %s disabled', convarName, name)
        return false
    end
    tokens[name] = value
    Log.debug('Http.setToken: token %s loaded', name)
    return true
end

--- The stored secret, or nil. Callers put it in a header — never in a log line or a client payload.
function Http.getToken(name)
    if type(name) ~= 'string' then return nil end
    return tokens[name]
end

-- Inbound -------------------------------------------------------------------

--- Give the inbound slot back, exactly once per counted request.
local function release(ctx)
    if not ctx.counted or ctx.released then return end
    ctx.released = true
    inflight = inflight - 1
end

--- Every request is answered exactly once: `ctx.done` guards the data handler, the fallback timer
--- and the handler result against each other, and a cancelled request is never written to. Whichever
--- path gets here is terminal, so the inbound slot is released here too.
local function respond(ctx, status, body, headers)
    if ctx.done or ctx.cancelled then return end
    ctx.done = true
    local out = cleanHeaders(headers)
    local text
    if type(body) == 'table' then
        local ok, encoded = pcall(json.encode, Core.Utils.jsonSafe(body))
        text = (ok and type(encoded) == 'string') and encoded or '{}'
        if not headerValue(out, 'content-type') then out['Content-Type'] = JSON_TYPE end
    elseif body == nil then
        text = ''
    else
        text = tostring(body)
        if not headerValue(out, 'content-type') then out['Content-Type'] = 'text/plain; charset=utf-8' end
    end
    local ok, err = pcall(function()
        ctx.res.writeHead(status, out)
        ctx.res.send(text)
    end)
    if not ok then Log.warn('Http: response failed (%s)', tostring(err)) end
    release(ctx)
end

local function validStatus(value)
    if math.type(value) ~= 'integer' or value < 100 or value > 599 then return 200 end
    return value
end

--- Route handlers may yield (Core.Http.fetch, a DB read), while the dispatcher itself must return at
--- once — hence one short-lived thread per served request. The slot was taken in `dispatch` (a request
--- parked in the body wait counts too) and is given back by `respond`.
local function serve(handler, ctx, request)
    CreateThread(function()
        local ok, status, body, headers = pcall(handler, request)
        if not ok then
            Log.error('Http route %s %s failed: %s', request.method, request.path, tostring(status))
            respond(ctx, 500, { error = 'handler error' })
            return
        end
        respond(ctx, validStatus(status), body, headers)
    end)
end

--- The one SetHttpHandler dispatcher (installed on the first Http.route call).
local function dispatch(req, res)
    local ctx = { res = res, done = false, cancelled = false, counted = false, released = false }
    local method = normaliseMethod(req.method, nil)
    local rawPath, query = splitPath(req.path)
    local path = normalisePath(rawPath)
    local handler = (method and path and routes[method]) and routes[method][path] or nil
    if not handler then
        respond(ctx, 404, { error = 'not found' })
        return
    end
    if inflight >= MAX_INFLIGHT then
        respond(ctx, 503, { error = 'busy' })
        return
    end
    -- Counted from here on: waiting for a body occupies a slot just like running a handler does.
    ctx.counted = true
    inflight = inflight + 1
    if type(req.setCancelHandler) == 'function' then
        -- The client went away: nothing will be written, so the slot has to come back here.
        pcall(req.setCancelHandler, function()
            ctx.cancelled = true
            release(ctx)
        end)
    end
    local request = { method = method, path = path, query = query, headers = req.headers or {}, body = '' }
    local announced = tonumber(headerValue(request.headers, 'content-length'))
    if announced and announced > MAX_IN_BODY then
        respond(ctx, 413, { error = 'body too large' })
        return
    end
    -- No body to wait for: a bodyless method, an announced length of 0, or a runtime without the hook.
    if BODYLESS[method] or announced == 0 or type(req.setDataHandler) ~= 'function' then
        serve(handler, ctx, request)
        return
    end
    local taken = false
    req.setDataHandler(function(data)
        if taken then return end
        taken = true
        if type(data) ~= 'string' then data = '' end
        if #data > MAX_IN_BODY then
            respond(ctx, 413, { error = 'body too large' })
            return
        end
        request.body = data
        if isJsonType(headerValue(request.headers, 'content-type')) and data ~= '' then
            local ok, decoded = pcall(json.decode, data)
            if ok and decoded ~= nil then request.body = decoded end
        end
        serve(handler, ctx, request)
    end)
    -- setDataHandler only fires when a body was actually sent; answer the bodyless case too.
    SetTimeout(BODY_WAIT_MS, function()
        if taken then return end
        taken = true
        serve(handler, ctx, request)
    end)
end

--- Register an endpoint reachable at `http://<host>:<port>/core<path>`.
--- The handler gets `{ method, path, query, headers, body }` and returns `status, body, headers?`;
--- a table body is sent as JSON. Treat everything in the request as untrusted input.
--- @return boolean registered
function Http.route(method, path, handler)
    local verb = normaliseMethod(method, nil)
    if not verb then
        Log.error('Http.route: invalid method %s', tostring(method))
        return false
    end
    local key = normalisePath(path)
    if not key then
        Log.error('Http.route: invalid path %s', tostring(path))
        return false
    end
    if not Core.Utils.isCallable(handler) then
        Log.error('Http.route: handler for %s %s must be a function', verb, key)
        return false
    end
    local byPath = routes[verb]
    if not byPath then
        byPath = {}
        routes[verb] = byPath
    end
    if byPath[key] then Log.warn('Http.route: %s %s registered twice, replacing', verb, key) end
    byPath[key] = handler
    if not dispatcherInstalled then
        dispatcherInstalled = true
        SetHttpHandler(dispatch)
    end
    return true
end
