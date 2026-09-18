--[[
    core / lib/net/shared.lua  —  Core.Net (DESIGN §3.6)

    Validated net events. The server wrapper runs its checks in exactly this
    order: `local src = source` -> schema (`Core.Validate.check`) -> cooldown ->
    requireLoaded -> permission -> distance -> `handler(src, ...)` in `pcall`.
    Rejections are silent for the client; they go to `opts.onReject` when given,
    otherwise to `Core.Log.debug`.

    Both gates are server-owned truth, never a client-writable source:
    requireLoaded asks `Core.Player.isLoaded(src)` (the session table, not the
    `loaded` state bag, which a client can write while `sv_stateBagStrictMode`
    is off) and permission asks `Core.Perms.has(src, perm)` (ACE plus the
    `Config.Perms.Groups` fallback, the same gate `Core.Commands` uses).

    The client half validates server -> client payloads against the same schema
    language: that catches bugs, not cheaters (the server is trusted).

    Natives: IsDuplicityVersion (shared); server side GetGameTimer,
    GetPlayerPed(playerSrc), GetEntityCoords(entity) (the server form takes one
    argument), IsPlayerAceAllowed(playerSrc, object) (only as the fallback when
    `Core.Perms` cannot be reached), TriggerClientEventInternal(eventName,
    eventTarget, eventPayload, payloadLength) (CFX, server; fxref 2026-09-18 — the
    backing function of TriggerClientEvent, used by `emitMany` to pack once).
]]

local ns = ...

local DEFAULT_COOLDOWN_MS <const> = 250
local DEFAULT_DISTANCE <const> = 5.0
local NO_OPTS <const> = {}

--- Shared argument check for `Net.on`.
local function validRegistration(name, handler)
    if type(name) ~= 'string' or #name == 0 or #name > 128 then
        Core.Log.error('Net.on: invalid event name %s', tostring(name))
        return false
    end
    if type(handler) ~= 'function' then
        Core.Log.error('Net.on: handler for %s is not a function', name)
        return false
    end
    return true
end

--- Run the handler, never letting an error escape into the event dispatcher.
local function runHandler(name, handler, ...)
    local ok, err = pcall(handler, ...)
    if not ok then
        Core.Log.error('net %s handler errored: %s', name, tostring(err))
    end
end

if IsDuplicityVersion() then
    local cooldownTables = {}   -- every per-event { [src] = lastMs } table, cleared on drop

    local function defaultCooldown()
        local cfg = Core and Core.Config   -- lazy: core's config, never the plugin's own `Config` (DESIGN §2.0)
        local c = cfg and cfg.Net and cfg.Net.DefaultCooldownMs
        if type(c) == 'number' and c >= 0 then return c end
        return DEFAULT_COOLDOWN_MS
    end

    --- Silent for the client; `onReject` when given, `Core.Log.debug` otherwise.
    local function reject(opts, name, src, reason)
        local onReject = opts.onReject
        if type(onReject) == 'function' then
            local ok, err = pcall(onReject, src, reason)
            if not ok then Core.Log.error('net %s: onReject errored: %s', name, tostring(err)) end
            return
        end
        Core.Log.debug('net %s rejected for src %s: %s', name, tostring(src), reason)
    end

    --- Resolve `opts.distance.coords` (a vector3 or a function of the payload).
    local function distanceCoords(distance, name, src, ...)
        local coords = distance.coords
        if type(coords) == 'function' then
            local ok, result = pcall(coords, src, ...)
            if not ok then
                Core.Log.error('net %s: distance.coords errored: %s', name, tostring(result))
                return nil
            end
            coords = result
        end
        if type(coords) ~= 'vector3' then return nil end
        return coords
    end

    --- Server-owned session truth. Never the `loaded` state bag: with
    --- `sv_stateBagStrictMode` off (the default) a modified client can write its
    --- own bag. Inside core this is a table lookup, from a plugin VM one export
    --- hop per event. Fails closed when core is not answering.
    local function isLoaded(src)
        local ok, loaded = pcall(function() return Core.Player.isLoaded(src) end)
        if not ok then
            Core.Log.error('net: Core.Player.isLoaded(%s) failed: %s', tostring(src), tostring(loaded))
            return false
        end
        return loaded == true
    end

    --- ACE + the `Config.Perms.Groups` fallback, same gate as `Core.Commands`.
    --- Plain `IsPlayerAceAllowed` only when `Core.Perms` cannot be reached.
    --- A BOOL native answers `false`/`1` through the runtime's default invoke path and a real boolean
    --- through the direct one (`use_experimental_fxv2_oal`); this lib runs in plugin VMs on either, so
    --- the answer is read by truthiness, never compared with `true`.
    local function hasPermission(src, perm)
        local ok, allowed = pcall(function() return Core.Perms.has(src, perm) end)
        if ok then return allowed == true end
        return IsPlayerAceAllowed(src, perm) and true or false
    end

    --- Register a validated client -> server event.
    --- opts: cooldown (ms per src, 0 disables), requireLoaded (default true),
    ---       permission (ace object / group perm), distance = { coords, max },
    ---       onReject(src, reason).
    function ns.on(name, schema, handler, opts)
        if not validRegistration(name, handler) then return end
        opts = type(opts) == 'table' and opts or NO_OPTS
        local cooldownMs = (type(opts.cooldown) == 'number' and opts.cooldown >= 0) and opts.cooldown or defaultCooldown()
        local requireLoaded = opts.requireLoaded ~= false
        local permission = type(opts.permission) == 'string' and opts.permission or nil
        local distance = type(opts.distance) == 'table' and opts.distance or nil
        local lastUse = {}
        cooldownTables[#cooldownTables + 1] = lastUse

        RegisterNetEvent(name, function(...)
            local src = source

            local ok, err = Core.Validate.check(schema, ...)
            if not ok then return reject(opts, name, src, 'schema: ' .. tostring(err)) end

            if cooldownMs > 0 then
                local now = GetGameTimer()
                local last = lastUse[src]   -- nil, not 0: the first event of a src always passes
                if last and now - last < cooldownMs then return reject(opts, name, src, 'cooldown') end
                lastUse[src] = now
            end

            if requireLoaded and not isLoaded(src) then
                return reject(opts, name, src, 'not loaded')
            end

            if permission and not hasPermission(src, permission) then
                return reject(opts, name, src, 'permission ' .. permission)
            end

            if distance then
                local coords = distanceCoords(distance, name, src, ...)
                if not coords then return reject(opts, name, src, 'distance: no target coords') end
                local ped = GetPlayerPed(src)
                if ped == 0 then return reject(opts, name, src, 'distance: no ped') end
                local max = type(distance.max) == 'number' and distance.max or DEFAULT_DISTANCE
                if #(GetEntityCoords(ped) - coords) > max then
                    return reject(opts, name, src, 'distance')
                end
            end

            runHandler(name, handler, src, ...)
        end)
    end

    --- Send to one client.
    function ns.emit(src, name, ...)
        if math.type(src) ~= 'integer' or src < 1 then
            Core.Log.error('Net.emit: invalid src %s', tostring(src))
            return
        end
        if type(name) ~= 'string' or #name == 0 then
            Core.Log.error('Net.emit: invalid event name %s', tostring(name))
            return
        end
        TriggerClientEvent(name, src, ...)
    end

    --- Send ONE payload to several clients (scoped delivery). The runtime's TriggerClientEvent
    --- msgpack-packs its arguments on every call; this packs once and issues one
    --- TriggerClientEventInternal(eventName, eventTarget, eventPayload, payloadLength) per target, so
    --- "the players near X" costs one encode, not one per player. `targets` is an array of srcs; an
    --- entry that is not a positive integer is skipped. Returns how many clients were addressed.
    ---@param targets integer[]
    ---@param name string
    ---@return integer sent
    function ns.emitMany(targets, name, ...)
        if type(targets) ~= 'table' then
            Core.Log.error('Net.emitMany: targets must be an array of srcs, got %s', type(targets))
            return 0
        end
        if type(name) ~= 'string' or #name == 0 then
            Core.Log.error('Net.emitMany: invalid event name %s', tostring(name))
            return 0
        end
        local count = #targets
        if count == 0 then return 0 end

        local sent = 0
        local packArgs = type(msgpack) == 'table' and msgpack.pack_args or nil
        if packArgs and TriggerClientEventInternal then
            local payload = packArgs(...)
            local length = #payload
            for i = 1, count do
                local src = targets[i]
                if math.type(src) == 'integer' and src >= 1 then
                    TriggerClientEventInternal(name, src, payload, length)
                    sent = sent + 1
                end
            end
            return sent
        end
        -- no msgpack in this VM (the offline suites): the plain call, once per target
        for i = 1, count do
            local src = targets[i]
            if math.type(src) == 'integer' and src >= 1 then
                TriggerClientEvent(name, src, ...)
                sent = sent + 1
            end
        end
        return sent
    end

    --- Send to every client. Never call this from a loop, and never for something only the players
    --- near a position care about: one reliable packet goes to EVERY connected client per broadcast —
    --- that is what `emitMany` with a scoped list is for.
    function ns.broadcast(name, ...)
        if type(name) ~= 'string' or #name == 0 then
            Core.Log.error('Net.broadcast: invalid event name %s', tostring(name))
            return
        end
        TriggerClientEvent(name, -1, ...)
    end

    AddEventHandler('playerDropped', function()
        local src = source
        for i = 1, #cooldownTables do
            cooldownTables[i][src] = nil
        end
    end)
else
    --- Register a schema-checked server -> client event.
    function ns.on(name, schema, handler)
        if not validRegistration(name, handler) then return end
        RegisterNetEvent(name, function(...)
            local ok, err = Core.Validate.check(schema, ...)
            if not ok then
                Core.Log.warn('net %s: bad payload (%s)', name, tostring(err))
                return
            end
            runHandler(name, handler, ...)
        end)
    end

    --- Send to the server.
    function ns.emit(name, ...)
        if type(name) ~= 'string' or #name == 0 then
            Core.Log.error('Net.emit: invalid event name %s', tostring(name))
            return
        end
        TriggerServerEvent(name, ...)
    end
end
