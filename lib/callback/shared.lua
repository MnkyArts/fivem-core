--[[
    core / lib/callback/shared.lua  —  Core.Callback (DESIGN §3.5)

    Promise-based callbacks, shaped after the kit pattern `patterns/callback.lua`
    (promise.new + Citizen.Await + SetTimeout, whichever fires first wins).

    Wire: request `core:cb:req:<name>` carries `(key, ...)`, response
    `core:cb:res:<name>` carries `(key, true, ...results)` or, for a refusal,
    `(key, false, reason)`. `key = Core.name .. ':' .. n`,
    so keys are unique across VMs and every VM only resolves the keys it owns
    (an unknown key is simply not in its `pending` table). Response events are
    registered lazily, once per name and VM. Timeout: `Core.Config.CallbackTimeoutMs`.

    The server request handler rate-limits per src with a token bucket
    (`Core.Config.RateLimits.CallbackPerSecond`), cleared in `playerDropped`, and
    `pcall`s the handler. Every refusal answers `(key, false, reason)` and the caller's `await` returns
    `nil, err` with err in rate_limit | schema | cooldown | permission | timeout | error (a handler error
    is logged and answered 'error'); callers that read one value are unaffected.

    Arguments may be validated like net events: pass a DESIGN §3.3 schema as the
    second argument — `Callback.register(name, { 'id', 'integer' }, fn)` — and the
    request handler runs `Core.Validate.check(schema, ...)` before the handler,
    refusing with 'schema' (the caller's `await` returns `nil, 'schema'`) when it fails.
    `Callback.register(name, fn)` without a schema keeps working unchanged.

    Server registrations take a fourth argument (DESIGN §44), enforced before
    the handler exactly like `Net.on`'s options, in the order schema ->
    cooldown -> permission:
        Callback.register(name, schema?, fn, { permission = 'core.audit.view', cooldownMs = 250 })
    `permission` asks `Core.Perms.has(src, perm)` (direct inside core, one
    export hop from a plugin; plain ACE only when core cannot be reached) and
    `cooldownMs` is per src and name (cleared in `playerDropped`). A refusal
    answers 'cooldown' or 'permission' (the caller's `await` returns `nil, err`).
    `register(name, fn, opts)` works too. Invalid opts refuse the registration.
    Client registrations accept the argument and ignore it (the server is the
    authority).

    `await` / `awaitClient` suspend the calling coroutine, so they must run
    inside a thread, command or event handler (like `Wait`). They use
    `Core.Config.CallbackTimeoutMs`; for answers that legitimately take longer
    than that (an open menu, a confirmation prompt) use the explicit-timeout
    variants `Callback.awaitTimeout(name, timeoutMs, ...)` (client) and
    `Callback.awaitClientTimeout(src, name, timeoutMs, ...)` (server), where
    `timeoutMs` is an integer 100..3600000 and anything else falls back to the
    configured timeout.

    Refusals carry a reason. Every await form returns the handler's results
    unchanged, or `nil, err` with err one of 'rate_limit' | 'schema' |
    'cooldown' | 'permission' | 'timeout' (no answer in time, or the asked
    player dropped) | 'error' (handler error or no handler). Callers that only
    read the first value keep working. Rate-limit answers are capped at
    NOTICES_PER_SECOND per src, so a flood is never mirrored back in full
    (the rest time out). A reason arriving from the other side is checked
    against that list ('error' otherwise).

    Natives: IsDuplicityVersion (shared), GetGameTimer (client + server),
    IsPlayerAceAllowed(playerSrc, object) (server; only when `Core.Perms` cannot
    be reached, BOOL read by truthiness).
]]

local ns = ...

local REQ <const> = 'core:cb:req:'
local RES <const> = 'core:cb:res:'
local DEFAULT_TIMEOUT_MS <const> = 5000
local MIN_TIMEOUT_MS <const> = 100
local MAX_TIMEOUT_MS <const> = 3600000
local DEFAULT_RATE <const> = 20
local NOTICES_PER_SECOND <const> = 10
local REASONS <const> = { rate_limit = true, schema = true, cooldown = true, permission = true, timeout = true,
    error = true }
local MAX_KEY_LEN <const> = 96

local handlers = {}        -- name -> function
local schemas = {}         -- name -> schema (optional, DESIGN §3.3)
local options = {}         -- name -> { permission = string|nil, cooldownMs = number } (server, DESIGN §44)
local lastUse = {}         -- name -> { [src] = ms } (server, per-src cooldown)
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

--- What a response resolves its promise with: the packed results, or `{ err = reason }` (a known reason).
local function outcome(ok, ...)
    if ok then return table.pack(...) end
    local reason = ...
    return { err = REASONS[reason] and reason or 'error' }
end

--- Arm the timeout and suspend until the response (or the timeout) resolves: the results, or nil + reason.
local function finish(key, p, ms)
    SetTimeout(ms, function()
        local entry = pending[key]
        if not entry then return end
        pending[key] = nil
        entry.promise:resolve({ err = 'timeout' })
    end)
    local results = Citizen.Await(p)
    if type(results) ~= 'table' then return nil, 'timeout' end
    if results.err then return nil, results.err end
    return table.unpack(results, 1, results.n)
end

--- `register(name, fn[, opts])` and `register(name, schema, fn[, opts])` in one signature.
local function registerArgs(schema, fn, opts)
    if fn == nil or type(schema) == 'function' then return nil, schema, fn end
    return schema, fn, opts
end

--- `{ permission?, cooldownMs? }` (`cooldown` is accepted as Net.on's spelling), or nil + a reason.
local function readOptions(opts)
    if opts == nil then return { cooldownMs = 0 } end
    if type(opts) ~= 'table' then return nil, 'opts must be a table' end
    local permission = opts.permission
    if permission ~= nil and (type(permission) ~= 'string' or #permission == 0 or #permission > 64) then
        return nil, 'opts.permission must be a permission name'
    end
    local cooldown = opts.cooldownMs
    if cooldown == nil then cooldown = opts.cooldown end
    if cooldown ~= nil and (type(cooldown) ~= 'number' or cooldown ~= cooldown or cooldown < 0) then
        return nil, 'opts.cooldownMs must be a number >= 0'
    end
    return { permission = permission, cooldownMs = cooldown or 0 }
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
    local buckets = {}   -- src -> { tokens = number, last = ms, noticeAt = ms, notices = n }

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

    --- May a rate-limited request of `src` be answered with 'rate_limit'? At most NOTICES_PER_SECOND per second.
    local function notice(src)
        local bucket = buckets[src]
        if not bucket then return true end
        local now = GetGameTimer()
        if not bucket.noticeAt or now - bucket.noticeAt >= 1000 then bucket.noticeAt, bucket.notices = now, 0 end
        bucket.notices = bucket.notices + 1
        return bucket.notices <= NOTICES_PER_SECOND
    end

    --- `Core.Perms.has` (direct inside core, the export proxy in a plugin); plain ACE only when core cannot be
    --- reached. A BOOL native answers `false`/`1` or a real boolean depending on the invoke path: truthiness.
    local function hasPermission(src, perm)
        local ok, allowed = pcall(function() return Core.Perms.has(src, perm) end)
        if ok then return allowed == true end
        return IsPlayerAceAllowed(tostring(src), perm) and true or false
    end

    --- Cooldown then permission (DESIGN §44, Net.on's order); the refusal reason ('cooldown'|'permission') or nil.
    local function refuse(name, src)
        local opts = options[name]
        if not opts then return nil end
        if opts.cooldownMs > 0 then
            local uses = lastUse[name]
            local now, last = GetGameTimer(), uses[src]   -- nil, not 0: the first request of a src always passes
            if last and now - last < opts.cooldownMs then return 'cooldown' end
            uses[src] = now
        end
        if opts.permission and not hasPermission(src, opts.permission) then return 'permission' end
        return nil
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
            entry.promise:resolve(outcome(ok, ...))
        end)
    end

    --- Register a name clients may `Core.Callback.await(name, ...)` into.
    --- `register(name, fn)` or `register(name, schema, fn)` (DESIGN §3.3 schema), plus an optional last
    --- `opts = { permission?, cooldownMs? }` (DESIGN §44).
    function ns.register(name, schema, fn, opts)
        schema, fn, opts = registerArgs(schema, fn, opts)
        if not validRegistration(name, schema, fn) then return end
        local parsed, reason = readOptions(opts)
        if not parsed then
            Core.Log.error('Callback.register: %s refused: %s', name, reason)
            return
        end
        handlers[name] = fn
        schemas[name] = schema
        options[name] = parsed
        lastUse[name] = lastUse[name] or {}
        if reqRegistered[name] then return end
        reqRegistered[name] = true
        RegisterNetEvent(REQ .. name, function(key, ...)
            local src = source
            if type(key) ~= 'string' or #key == 0 or #key > MAX_KEY_LEN then return end
            if not allow(src) then
                Core.Log.debug('callback %s rate-limited for src %s', name, src)
                if notice(src) then TriggerClientEvent(RES .. name, src, key, false, 'rate_limit') end
                return
            end
            local handler = handlers[name]
            if not handler then
                TriggerClientEvent(RES .. name, src, key, false, 'error')
                return
            end
            local schema = schemas[name]
            if schema then
                local valid, err = Core.Validate.check(schema, ...)
                if not valid then
                    Core.Log.debug('callback %s: bad payload from src %s (%s)', name, src, tostring(err))
                    TriggerClientEvent(RES .. name, src, key, false, 'schema')
                    return
                end
            end
            local refused = refuse(name, src)
            if refused then
                Core.Log.debug('callback %s refused for src %s: %s', name, src, refused)
                TriggerClientEvent(RES .. name, src, key, false, refused)
                return
            end
            local result = table.pack(pcall(handler, src, ...))
            if not result[1] then
                Core.Log.error('callback %s errored: %s', name, tostring(result[2]))
                TriggerClientEvent(RES .. name, src, key, false, 'error')
                return
            end
            TriggerClientEvent(RES .. name, src, key, true, table.unpack(result, 2, result.n))
        end)
    end

    --- Ask one client for a value, waiting `timeoutMs` (integer 100..3600000;
    --- anything else falls back to `Core.Config.CallbackTimeoutMs`).
    --- Returns the client's results, or nil + 'timeout' (no answer, or the player dropped) | 'schema' | 'error'.
    function ns.awaitClientTimeout(src, name, ms, ...)
        if math.type(src) ~= 'integer' or src < 1 then
            Core.Log.error('Callback.awaitClient: invalid src %s', tostring(src))
            return nil, 'error'
        end
        if type(name) ~= 'string' or #name == 0 then
            Core.Log.error('Callback.awaitClient: invalid name %s', tostring(name))
            return nil, 'error'
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
        for _, uses in pairs(lastUse) do uses[src] = nil end
        for key, entry in pairs(pending) do
            if entry.src == src then
                pending[key] = nil
                entry.promise:resolve({ err = 'timeout' })   -- the asked player is gone: no answer will come
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
            entry.promise:resolve(outcome(ok, ...))
        end)
    end

    --- Register a name the server may `Core.Callback.awaitClient(src, name, ...)` into.
    --- `register(name, fn)` or `register(name, schema, fn)` (DESIGN §3.3 schema); a trailing `opts`
    --- is accepted and ignored on the client (the server is the authority, DESIGN §44).
    function ns.register(name, schema, fn, opts)
        schema, fn = registerArgs(schema, fn, opts)
        if not validRegistration(name, schema, fn) then return end
        handlers[name] = fn
        schemas[name] = schema
        if reqRegistered[name] then return end
        reqRegistered[name] = true
        RegisterNetEvent(REQ .. name, function(key, ...)
            if type(key) ~= 'string' or #key == 0 or #key > MAX_KEY_LEN then return end
            local handler = handlers[name]
            if not handler then
                TriggerServerEvent(RES .. name, key, false, 'error')
                return
            end
            local schema = schemas[name]
            if schema then
                local valid, err = Core.Validate.check(schema, ...)
                if not valid then
                    Core.Log.warn('callback %s: bad payload (%s)', name, tostring(err))
                    TriggerServerEvent(RES .. name, key, false, 'schema')
                    return
                end
            end
            local result = table.pack(pcall(handler, ...))
            if not result[1] then
                Core.Log.error('callback %s errored: %s', name, tostring(result[2]))
                TriggerServerEvent(RES .. name, key, false, 'error')
                return
            end
            TriggerServerEvent(RES .. name, key, true, table.unpack(result, 2, result.n))
        end)
    end

    --- Ask the server for a value, waiting `timeoutMs` (integer 100..3600000;
    --- anything else falls back to `Core.Config.CallbackTimeoutMs`).
    --- Returns the handler's results, or nil + 'rate_limit' | 'schema' | 'cooldown' | 'permission' | 'timeout' |
    --- 'error'.
    function ns.awaitTimeout(name, ms, ...)
        if type(name) ~= 'string' or #name == 0 then
            Core.Log.error('Callback.await: invalid name %s', tostring(name))
            return nil, 'error'
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
