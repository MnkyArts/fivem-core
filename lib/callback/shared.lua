--[[
    core / lib/callback/shared.lua  —  Core.Callback (DESIGN §3.5)

    Promise-based callbacks, shaped after the kit pattern `patterns/callback.lua`
    (promise.new + Citizen.Await + SetTimeout, whichever fires first wins).

    Wire: request `core:cb:req:<name>` carries `(key, ...)`, response
    `core:cb:res:<name>` carries `(key, ok, ...)`. `key = Core.name .. ':' .. n`,
    so keys are unique across VMs and every VM only resolves the keys it owns
    (an unknown key is simply not in its `pending` table). Response events are
    registered lazily, once per name and VM. Timeout: `Core.Config.CallbackTimeoutMs`.

    The server request handler rate-limits per src with a token bucket
    (`Core.Config.RateLimits.CallbackPerSecond`), cleared in `playerDropped`, and
    `pcall`s the handler; a handler error answers `ok = false` and logs.

    Arguments may be validated like net events: pass a DESIGN §3.3 schema as the
    second argument — `Callback.register(name, { 'id', 'integer' }, fn)` — and the
    request handler runs `Core.Validate.check(schema, ...)` before the handler,
    answering `ok = false` (the caller's `await` returns nil) when it fails.
    `Callback.register(name, fn)` without a schema keeps working unchanged.

    `await` / `awaitClient` suspend the calling coroutine, so they must run
    inside a thread, command or event handler (like `Wait`). They use
    `Core.Config.CallbackTimeoutMs`; for answers that legitimately take longer
    than that (an open menu, a confirmation prompt) use the explicit-timeout
    variants `Callback.awaitTimeout(name, timeoutMs, ...)` (client) and
    `Callback.awaitClientTimeout(src, name, timeoutMs, ...)` (server), where
    `timeoutMs` is an integer 100..3600000 and anything else falls back to the
    configured timeout.

    Natives: IsDuplicityVersion (shared), GetGameTimer (client + server).
]]

local ns = ...

local REQ <const> = 'core:cb:req:'
local RES <const> = 'core:cb:res:'
local DEFAULT_TIMEOUT_MS <const> = 5000
local MIN_TIMEOUT_MS <const> = 100
local MAX_TIMEOUT_MS <const> = 3600000
local DEFAULT_RATE <const> = 20
local MAX_KEY_LEN <const> = 96

local handlers = {}        -- name -> function
local schemas = {}         -- name -> schema (optional, DESIGN §3.3)
local pending = {}         -- key -> { promise = promise, src = targetSrc|nil }
local reqRegistered = {}   -- name -> true (request event registered in this VM)
local resRegistered = {}   -- name -> true (response event registered in this VM)
local counter = 0

local function nextKey()
    counter = counter + 1
    return ('%s:%d'):format((Core and Core.name) or 'core', counter)
end

local function timeoutMs()
    local cfg = Core and Core.Config   -- lazy: core's config, never the plugin's own `Config` (DESIGN §2.0)
    local t = cfg and cfg.CallbackTimeoutMs
    if math.type(t) == 'integer' and t > 0 then return t end
    return DEFAULT_TIMEOUT_MS
end

--- An explicit `timeoutMs` (integer 100..3600000) or the configured default.
local function resolveTimeout(ms)
    if ms == nil then return timeoutMs() end
    local whole = math.tointeger(ms)
    if whole and whole >= MIN_TIMEOUT_MS and whole <= MAX_TIMEOUT_MS then return whole end
    Core.Log.warn('Callback: timeout %s is not an integer %d..%d, using the configured timeout',
        tostring(ms), MIN_TIMEOUT_MS, MAX_TIMEOUT_MS)
    return timeoutMs()
end

--- Create the pending entry before the request goes out.
--- @return string key, table promise
local function prepare(targetSrc)
    local key = nextKey()
    local p = promise.new()
    pending[key] = { promise = p, src = targetSrc }
    return key, p
end

--- Arm the timeout and suspend until the response (or the timeout) resolves.
local function finish(key, p, ms)
    SetTimeout(ms, function()
        local entry = pending[key]
        if not entry then return end
        pending[key] = nil
        entry.promise:resolve(nil)
    end)
    local results = Citizen.Await(p)
    if not results then return nil end
    return table.unpack(results, 1, results.n)
end

--- `register(name, fn)` and `register(name, schema, fn)` in one signature.
local function registerArgs(schema, fn)
    if fn == nil then return nil, schema end
    return schema, fn
end

--- Shared argument check for `register` on both sides.
local function validRegistration(name, schema, fn)
    if type(name) ~= 'string' or #name == 0 or #name > 64 then
        Core.Log.error('Callback.register: invalid name %s', tostring(name))
        return false
    end
    if type(fn) ~= 'function' then
        Core.Log.error('Callback.register: handler for %s is not a function', name)
        return false
    end
    if schema ~= nil and type(schema) ~= 'table' and type(schema) ~= 'string' then
        Core.Log.error('Callback.register: schema for %s must be a table, a spec string or nil', name)
        return false
    end
    if handlers[name] then
        Core.Log.warn('Callback.register: %s registered twice, replacing the handler', name)
    end
    return true
end

if IsDuplicityVersion() then
    local buckets = {}   -- src -> { tokens = number, last = ms }

    --- Token bucket: `Core.Config.RateLimits.CallbackPerSecond` requests/s per
    --- src, burst = the same value. A limit <= 0 disables the limiter.
    local function allow(src)
        local cfg = Core and Core.Config   -- lazy: core's config, not the plugin's `Config` (DESIGN §2.0)
        local limit = (cfg and cfg.RateLimits and cfg.RateLimits.CallbackPerSecond) or DEFAULT_RATE
        if type(limit) ~= 'number' or limit <= 0 then return true end
        local now = GetGameTimer()
        local bucket = buckets[src]
        if not bucket then
            bucket = { tokens = limit, last = now }
            buckets[src] = bucket
        else
            local elapsed = now - bucket.last
            if elapsed > 0 then
                bucket.tokens = math.min(limit, bucket.tokens + (elapsed * limit) / 1000)
                bucket.last = now
            end
        end
        if bucket.tokens < 1 then return false end
        bucket.tokens = bucket.tokens - 1
        return true
    end

    --- Responses to `awaitClient`, registered once per name.
    local function ensureResponse(name)
        if resRegistered[name] then return end
        resRegistered[name] = true
        RegisterNetEvent(RES .. name, function(key, ok, ...)
            local src = source
            if type(key) ~= 'string' or #key > MAX_KEY_LEN then return end
            local entry = pending[key]
            if not entry or entry.src ~= src then return end   -- unknown, timed out, or wrong client
            pending[key] = nil
            entry.promise:resolve(ok and table.pack(...) or nil)
        end)
    end

    --- Register a name clients may `Core.Callback.await(name, ...)` into.
    --- `register(name, fn)` or `register(name, schema, fn)` (DESIGN §3.3 schema).
    function ns.register(name, schema, fn)
        schema, fn = registerArgs(schema, fn)
        if not validRegistration(name, schema, fn) then return end
        handlers[name] = fn
        schemas[name] = schema
        if reqRegistered[name] then return end
        reqRegistered[name] = true
        RegisterNetEvent(REQ .. name, function(key, ...)
            local src = source
            if type(key) ~= 'string' or #key == 0 or #key > MAX_KEY_LEN then return end
            if not allow(src) then
                Core.Log.debug('callback %s rate-limited for src %s', name, src)
                return
            end
            local handler = handlers[name]
            if not handler then
                TriggerClientEvent(RES .. name, src, key, false)
                return
            end
            local schema = schemas[name]
            if schema then
                local valid, err = Core.Validate.check(schema, ...)
                if not valid then
                    Core.Log.debug('callback %s: bad payload from src %s (%s)', name, src, tostring(err))
                    TriggerClientEvent(RES .. name, src, key, false)
                    return
                end
            end
            local result = table.pack(pcall(handler, src, ...))
            if not result[1] then
                Core.Log.error('callback %s errored: %s', name, tostring(result[2]))
                TriggerClientEvent(RES .. name, src, key, false)
                return
            end
            TriggerClientEvent(RES .. name, src, key, true, table.unpack(result, 2, result.n))
        end)
    end

    --- Ask one client for a value, waiting `timeoutMs` (integer 100..3600000;
    --- anything else falls back to `Core.Config.CallbackTimeoutMs`).
    --- Returns nil on timeout, handler error or drop.
    function ns.awaitClientTimeout(src, name, ms, ...)
        if math.type(src) ~= 'integer' or src < 1 then
            Core.Log.error('Callback.awaitClient: invalid src %s', tostring(src))
            return nil
        end
        if type(name) ~= 'string' or #name == 0 then
            Core.Log.error('Callback.awaitClient: invalid name %s', tostring(name))
            return nil
        end
        local wait = resolveTimeout(ms)
        ensureResponse(name)
        local key, p = prepare(src)
        TriggerClientEvent(REQ .. name, src, key, ...)
        return finish(key, p, wait)
    end

    --- Ask one client for a value with the configured timeout.
    function ns.awaitClient(src, name, ...)
        return ns.awaitClientTimeout(src, name, nil, ...)
    end

    AddEventHandler('playerDropped', function()
        local src = source
        buckets[src] = nil
        for key, entry in pairs(pending) do
            if entry.src == src then
                pending[key] = nil
                entry.promise:resolve(nil)
            end
        end
    end)
else
    --- Responses to `await`, registered once per name.
    local function ensureResponse(name)
        if resRegistered[name] then return end
        resRegistered[name] = true
        RegisterNetEvent(RES .. name, function(key, ok, ...)
            if type(key) ~= 'string' or #key > MAX_KEY_LEN then return end
            local entry = pending[key]
            if not entry then return end   -- not ours, or already timed out
            pending[key] = nil
            entry.promise:resolve(ok and table.pack(...) or nil)
        end)
    end

    --- Register a name the server may `Core.Callback.awaitClient(src, name, ...)` into.
    --- `register(name, fn)` or `register(name, schema, fn)` (DESIGN §3.3 schema).
    function ns.register(name, schema, fn)
        schema, fn = registerArgs(schema, fn)
        if not validRegistration(name, schema, fn) then return end
        handlers[name] = fn
        schemas[name] = schema
        if reqRegistered[name] then return end
        reqRegistered[name] = true
        RegisterNetEvent(REQ .. name, function(key, ...)
            if type(key) ~= 'string' or #key == 0 or #key > MAX_KEY_LEN then return end
            local handler = handlers[name]
            if not handler then
                TriggerServerEvent(RES .. name, key, false)
                return
            end
            local schema = schemas[name]
            if schema then
                local valid, err = Core.Validate.check(schema, ...)
                if not valid then
                    Core.Log.warn('callback %s: bad payload (%s)', name, tostring(err))
                    TriggerServerEvent(RES .. name, key, false)
                    return
                end
            end
            local result = table.pack(pcall(handler, ...))
            if not result[1] then
                Core.Log.error('callback %s errored: %s', name, tostring(result[2]))
                TriggerServerEvent(RES .. name, key, false)
                return
            end
            TriggerServerEvent(RES .. name, key, true, table.unpack(result, 2, result.n))
        end)
    end

    --- Ask the server for a value, waiting `timeoutMs` (integer 100..3600000;
    --- anything else falls back to `Core.Config.CallbackTimeoutMs`).
    --- Returns nil on timeout or handler error.
    function ns.awaitTimeout(name, ms, ...)
        if type(name) ~= 'string' or #name == 0 then
            Core.Log.error('Callback.await: invalid name %s', tostring(name))
            return nil
        end
        local wait = resolveTimeout(ms)
        ensureResponse(name)
        local key, p = prepare(nil)
        TriggerServerEvent(REQ .. name, key, ...)
        return finish(key, p, wait)
    end

    --- Ask the server for a value with the configured timeout.
    function ns.await(name, ...)
        return ns.awaitTimeout(name, nil, ...)
    end
end
