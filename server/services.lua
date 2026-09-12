--[[
    core/server/services.lua — Core.Services and Core.Api (DESIGN §22).

    Services are named, swappable implementations of a documented interface: core registers its own
    notification/currency/death (and time/weather once Core.World exists) at start, and a plugin may
    replace any of them with `Core.Services.register(name, impl)`. Consumers always ask
    `Core.Services.get('currency')` instead of hard-depending on a specific resource.

    Documented interfaces (README):
        notification { send(src, message, type), broadcast(message, type) }
        currency     { add(src, account, n, reason), sub(...), has(src, account, n), get(src, account) }
        death        { respawn(src, coords, heading), revive(src) }
        items        { add(src, id, qty, data), sub(...), has(...), remove(src, uid), get(src) }   -- inventory plugin
        time         { set(hour, minute), get() }
        weather      { set(type, transitionSec), get() }

    A name from that list must be registered with every function of its contract; any other name is
    accepted as a free-form service. Registering an interface twice is allowed (last one wins) and
    logged, so a swapped implementation is visible in the console.

    Core's own implementations live in a separate `defaults` table: a plugin registration shadows the
    default while the plugin runs, and `Services.get` falls back to the default again as soon as that
    plugin stops (the owner sweep only ever removes plugin registrations). Core's defaults cannot be
    unregistered — `Services.unregister` removes the plugin implementation, not the fallback.
]]

local Services = {}
Core.Services = Services

local Log = Core.Log

local MAX_NAME <const> = 64
local NAME_PATTERN <const> = '^[%w_%.%-:]+$'

local INTERFACES <const> = {
    notification = { 'send', 'broadcast' },
    currency = { 'add', 'sub', 'has', 'get' },
    death = { 'respawn', 'revive' },
    items = { 'add', 'sub', 'has', 'remove', 'get' },
    time = { 'set', 'get' },
    weather = { 'set', 'get' },
}

local services = {}     -- [name] = { impl = table, owner = resource } — plugin registrations
local defaults = {}     -- [name] = impl — core's own implementations, never swept

--- A usable service/API name: short and printable.
local function isName(name)
    if type(name) ~= 'string' or #name < 1 or #name > MAX_NAME then return false end
    return name:match(NAME_PATTERN) ~= nil
end

--- Does `impl` satisfy the documented contract of `name`? Free-form names always do.
--- @return boolean ok, string|nil missingFunction
local function implements(name, impl)
    local contract = INTERFACES[name]
    if not contract then return true end
    for i = 1, #contract do
        if not Core.Utils.isCallable(impl[contract[i]]) then return false, contract[i] end
    end
    return true
end

--- Core's own fallback for `name`. Internal: a plugin always goes through Services.register, which
--- never writes `defaults`, so a plugin can shadow a default but never overwrite or delete it.
local function registerDefault(name, impl)
    if not isName(name) or type(impl) ~= 'table' then return false end
    local ok, missing = implements(name, impl)
    if not ok then
        Log.warn("services: core default '%s' not registered, impl.%s() is missing", name, tostring(missing))
        return false
    end
    defaults[name] = impl
    return true
end

--- Registers (or replaces) the implementation of `name`. Returns false when the contract is unmet.
function Services.register(name, impl)
    if not isName(name) or type(impl) ~= 'table' then return false end
    local ok, missing = implements(name, impl)
    if not ok then
        Log.warn("services: '%s' not registered, impl.%s() is missing", name, tostring(missing))
        return false
    end
    local owner = Core.Registry.getCaller()
    if owner == Core.name then
        defaults[name] = impl
        return true
    end
    local previous = services[name]
    if previous then
        Log.info("services: '%s' replaced by %s (was %s)", name, owner, previous.owner)
    elseif defaults[name] then
        Log.info("services: '%s' provided by %s (core's default is the fallback)", name, owner)
    end
    services[name] = { impl = impl, owner = owner }
    return true
end

--- The active implementation table: the plugin registration if there is one, else core's own
--- default (which stays available for the whole uptime), else nil.
function Services.get(name)
    if not isName(name) then return nil end
    local entry = services[name]
    if entry then return entry.impl end
    return defaults[name]
end

--- True when anything implements `name` (plugin registration or core default).
function Services.has(name)
    if not isName(name) then return false end
    return services[name] ~= nil or defaults[name] ~= nil
end

--- Resource behind the implementation `Services.get` returns: the plugin's name, or core's own
--- name for a default. nil when nobody implements `name`.
function Services.getOwner(name)
    if not isName(name) then return nil end
    local entry = services[name]
    if entry then return entry.owner end
    return defaults[name] and Core.name or nil
end

--- Removes the plugin implementation of `name`; core's default (if any) becomes active again.
--- False when no plugin implementation was registered.
function Services.unregister(name)
    if not isName(name) or not services[name] then return false end
    services[name] = nil
    return true
end

-- ---------------------------------------------------------------------------
-- Core's own implementations: the `defaults` fallbacks, shadowed (never replaced) by a plugin.
-- ---------------------------------------------------------------------------

registerDefault('notification', {
    send = function(src, message, kind, duration) return Core.Notify.send(src, message, kind, duration) end,
    broadcast = function(message, kind) return Core.Notify.broadcast(message, kind) end,
})

registerDefault('currency', {
    add = function(src, account, amount, reason) return Core.Money.add(src, account, amount, reason) end,
    sub = function(src, account, amount, reason) return Core.Money.remove(src, account, amount, reason) end,
    has = function(src, account, amount) return Core.Money.canAfford(src, account, amount) end,
    get = function(src, account) return Core.Money.get(src, account) end,
})

registerDefault('death', {
    respawn = function(src, coords, heading) return Core.Player.respawn(src, coords, heading) end,
    -- revive = respawn where the player already is (no coords -> Player.respawn keeps the current ones)
    revive = function(src) return Core.Player.respawn(src) end,
})

-- Core.World (server/environment.lua, §17) may load after this file, or not at all in a trimmed
-- build: bind time/weather on the ready hook and never let a missing module break the start-up.
Core.on('ready', function()
    local world = rawget(Core, 'World')
    if type(world) ~= 'table' then
        Log.debug('services: no Core.World — time/weather services not registered')
        return
    end
    local ok, err = pcall(function()
        registerDefault('time', {
            set = function(hour, minute) return world.setTime(hour, minute) end,
            get = function() return world.getTime() end,
        })
        registerDefault('weather', {
            set = function(weatherType, transition) return world.setWeather(weatherType, transition) end,
            get = function() return world.getWeather() end,
        })
    end)
    if not ok then Log.warn('services: time/weather registration failed (%s)', tostring(err)) end
end)

-- ---------------------------------------------------------------------------
-- Core.Api (DESIGN §22) — plugin-to-plugin API sharing through core.
--
-- COST WARNING: the registered table stays in the registering resource's VM. Every call another
-- resource makes on it crosses core's `call` export AND a funcref, i.e. two msgpack hops per call
-- (rulebook §4) — fine for wiring and occasional calls, far too expensive per frame or inside a
-- per-player loop. Share data and coarse operations, never per-tick work. A funcref belonging to a
-- stopped resource is dead, so Api.get stops handing out that table when its owner stops.
-- ---------------------------------------------------------------------------

local Api = {}
Core.Api = Api

local apis = {}     -- [name] = { api = table, owner = resource }

--- Publishes a table under `name` (the convention is the resource's own name). Returns false on a
--- bad name/table or when a different resource already owns that name.
function Api.register(name, api)
    if not isName(name) or type(api) ~= 'table' then return false end
    local owner = Core.Registry.getCaller()
    local previous = apis[name]
    if previous and previous.owner ~= owner then
        Log.warn("api: '%s' is already registered by %s", name, previous.owner)
        return false
    end
    apis[name] = { api = api, owner = owner }
    return true
end

--- The table registered under `name`, or nil (also nil once the owning resource stopped).
function Api.get(name)
    local entry = isName(name) and apis[name] or nil
    return entry and entry.api or nil
end

-- A stopped resource takes its funcrefs with it: drop everything it registered so nobody calls a
-- dead one. Only plugin registrations are swept — core's `defaults` stay, so a service a plugin had
-- replaced falls back to core's implementation instead of disappearing. Synchronous, no Wait.
AddEventHandler('onResourceStop', function(resource)
    if type(resource) ~= 'string' or resource == Core.name then return end
    for name, entry in pairs(services) do
        if entry.owner == resource then
            services[name] = nil
            local fallback = defaults[name] and ' (core default active again)' or ''
            Log.debug("services: '%s' dropped, %s stopped%s", name, resource, fallback)
        end
    end
    for name, entry in pairs(apis) do
        if entry.owner == resource then apis[name] = nil end
    end
end)
