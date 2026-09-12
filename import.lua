--[[
    core/import.lua — THE consumer include (DESIGN §2).

    Plugins put '@core/import.lua' first in shared_scripts and get the `Core` global:
      * lib namespaces (Utils, Math, Validate, ...) are compiled into the caller's own VM,
        so they cost no cross-resource hop;
      * every other namespace (Markers, Money, Factions, ...) is an export proxy that
        forwards to core's single `call` export.

    This file runs in EVERY VM, core's own included, so it uses shared natives only
    (GetCurrentResourceName, IsDuplicityVersion, LoadResourceFile, GetResourceState) and
    never touches a client- or server-only native at file scope.
]]

local resourceName = GetCurrentResourceName()
local isServer = IsDuplicityVersion()
local side = isServer and 'server' or 'client'
local isCore = resourceName == 'core'

Core = {
    name = resourceName,
    isServer = isServer,
    isClient = not isServer,
    isCore = isCore,
    version = '1.0.0',
}

-- namespace -> lib directory (DESIGN §2.1). Everything not listed here is a pure proxy.
local LIB_MODULES <const> = {
    Utils = 'utils', Math = 'math', Validate = 'validate', Log = 'log', Callback = 'callback',
    Net = 'net', Commands = 'commands', Keys = 'keys', Streaming = 'streaming', Anim = 'anim',
    Player = 'player', UI = 'ui', Locale = 'locale', Audio = 'audio',
}

-- the one nesting level the proxy understands: Core.UI.menu.open -> call('UI', 'menu.open')
local SUB_NAMESPACES <const> = {
    UI = { menu = true, input = true, alert = true, progress = true, textUI = true, hud = true, keys = true, spinner = true, stats = true, state = true, locale = true },
}

local READY_POLL_MS <const> = 100
local READY_TIMEOUT_MS <const> = 30000

--------------------------------------------------------------------------------
-- Lazy lib loading (DESIGN §2.1)
--------------------------------------------------------------------------------

--- Compiles one lib file out of core's packfile and runs it with the namespace table.
--- Returns false when the file does not exist (LoadResourceFile gives nil or '').
local function runLibFile(path, ns)
    local code = LoadResourceFile('core', path)
    if not code or code == '' then return false end
    -- fxlint-disable-next-line S006 -- fixed path inside core's own resource files, not user input
    local chunk, err = load(code, '@core/' .. path, 't', _ENV)
    if not chunk then
        error(('core: failed to compile %s (%s)'):format(path, tostring(err)), 0)
    end
    chunk(ns)
    return true
end

--------------------------------------------------------------------------------
-- Export proxy (DESIGN §2.2)
--------------------------------------------------------------------------------

--- One cached closure per (namespace, fn): Core.Money.add(...) -> exports.core:call(...)
local function remoteFn(namespace, fn)
    return function(...)
        if GetResourceState('core') ~= 'started' then
            error(('core is not running: Core.%s.%s (register inside Core.onReady)')
                :format(namespace, fn), 2)
        end
        -- this file is shipped into plugin VMs, which do declare dependency 'core';
        -- inside core itself the proxy is never installed, so the export is never used here
        -- fxlint-disable-next-line C012 -- core is the host of this file, not a dependency of it
        return exports.core:call(resourceName, namespace, fn, ...)
    end
end

--- Sub-namespace proxy, one nesting level only: Core.UI.menu.open -> call('UI', 'menu.open').
--- The proxy is also callable so Core.UI.progress({...}) reaches call('UI', 'progress') while
--- Core.UI.progress.cancel() still reaches call('UI', 'progress.cancel') (DESIGN §6.10).
local function subProxy(namespace, sub)
    local prefix = sub .. '.'
    local selfFn = remoteFn(namespace, sub)
    return setmetatable({}, {
        __index = function(t, key)
            if type(key) ~= 'string' then return nil end
            local fn = remoteFn(namespace, prefix .. key)
            rawset(t, key, fn)
            return fn
        end,
        __call = function(_, ...)
            return selfFn(...)
        end,
    })
end

--------------------------------------------------------------------------------
-- Core.Player(src) handle sugar, server side only (DESIGN §2.1)
--------------------------------------------------------------------------------

local moneyMethods = {}
local moneyMeta = {
    __index = function(_, key)
        if type(key) ~= 'string' then return nil end
        local fn = moneyMethods[key]
        if not fn then
            fn = function(self, ...) return Core.Money[key](self.src, ...) end
            moneyMethods[key] = fn
        end
        return fn
    end,
}

local playerMethods = {}
local handleMeta = {
    __index = function(handle, key)
        if type(key) ~= 'string' then return nil end
        if key == 'money' then
            local money = setmetatable({ src = handle.src }, moneyMeta)
            rawset(handle, 'money', money)
            return money
        end
        local fn = playerMethods[key]
        if not fn then
            fn = function(self, ...) return Core.Player[key](self.src, ...) end
            playerMethods[key] = fn
        end
        return fn
    end,
}

--- Core.Player(src) -> handle; handle:addMoney('cash', 10) == Core.Player.addMoney(src, 'cash', 10)
--- and handle.money:add('cash', 10) == Core.Money.add(src, 'cash', 10).
local function playerHandle(_, src)
    return setmetatable({ src = src }, handleMeta)
end

--------------------------------------------------------------------------------
-- Namespaces (DESIGN §2.1 / §2.2)
--------------------------------------------------------------------------------

--- Gives a namespace table the proxy metatable, so anything not implemented in this VM
--- transparently reaches core. Never called inside core itself.
local function attachProxy(ns, name)
    local subs = SUB_NAMESPACES[name]
    local meta = {
        __index = function(t, key)
            if type(key) ~= 'string' then return nil end
            local value
            if subs and subs[key] then
                value = subProxy(name, key)
            else
                value = remoteFn(name, key)
            end
            rawset(t, key, value)
            return value
        end,
    }
    if isServer and name == 'Player' then
        meta.__call = playerHandle
    end
    return setmetatable(ns, meta)
end

local loadingLibs = {} -- namespace -> table, only while its chunks are running

--- Builds a lib namespace on first access: lib/<dir>/shared.lua then lib/<dir>/<side>.lua.
--- Nothing is published on Core until both chunks ran, so a chunk that errors leaves the
--- namespace uncached (the next access retries) instead of a half-built table.
local function createLib(name, dir)
    local pending = loadingLibs[name]
    if pending then return pending end -- a chunk touched its own namespace while loading
    local ns = rawget(Core, name) or {}
    loadingLibs[name] = ns
    local ok, err = pcall(function()
        runLibFile(('lib/%s/shared.lua'):format(dir), ns)
        runLibFile(('lib/%s/%s.lua'):format(dir, side), ns)
    end)
    loadingLibs[name] = nil
    if not ok then error(err, 0) end
    rawset(Core, name, ns)
    if not isCore then
        attachProxy(ns, name) -- adds the Core.Player(src) __call on the server as well
    elseif isServer and name == 'Player' and getmetatable(ns) == nil then
        setmetatable(ns, { __call = playerHandle })
    end
    return ns
end

--------------------------------------------------------------------------------
-- Core.Config — core's own config table in every VM (DESIGN §2.0)
--------------------------------------------------------------------------------

local cachedConfig = nil

--- Inside core this is the `Config` global (config.lua loads after this file, so it is
--- resolved on every access until it exists); everywhere else core's shared/config.lua is
--- compiled into a private environment so the plugin's own `Config` global stays untouched.
local function resolveConfig()
    if cachedConfig then return cachedConfig end
    if isCore then
        local cfg = rawget(_G, 'Config')
        if type(cfg) ~= 'table' then return nil end
        cachedConfig = cfg
        rawset(Core, 'Config', cfg)
        return cfg
    end
    local code = LoadResourceFile('core', 'shared/config.lua')
    local env = setmetatable({}, { __index = _G }) -- reads fall back to _G for vector3 etc.
    local chunk
    if code and code ~= '' then
        -- fxlint-disable-next-line S006 -- fixed path inside core's own resource files, not user input
        chunk = load(code, '@core/shared/config.lua', 't', env)
    end
    local cfg = chunk and pcall(chunk) and env.Config or nil
    if type(cfg) ~= 'table' then
        print(('[core] %s: shared/config.lua could not be loaded, using an empty Core.Config')
            :format(resourceName))
        cfg = {}
    end
    cachedConfig = cfg
    rawset(Core, 'Config', cfg)
    return cfg
end

setmetatable(Core, {
    __index = function(_, key)
        if type(key) ~= 'string' then return nil end
        if key == 'Config' then return resolveConfig() end
        local dir = LIB_MODULES[key]
        if dir then return createLib(key, dir) end
        -- inside core the module files assign the real tables; a missing API stays nil
        -- so a typo fails loudly at call time instead of hopping through an export.
        if isCore or not key:find('^%u') then return nil end
        local ns = attachProxy({}, key)
        rawset(Core, key, ns)
        return ns
    end,

    -- core's own server/player.lua assigns a fresh table to Core.Player; keep the
    -- Core.Player(src) handle sugar of DESIGN §2.1 working for it as well.
    __newindex = function(t, k, v)
        rawset(t, k, v)
        if k == 'Player' and isServer and type(v) == 'table' and getmetatable(v) == nil then
            setmetatable(v, { __call = playerHandle })
        end
    end,
})

--------------------------------------------------------------------------------
-- Hooks and readiness (DESIGN §2.4)
--------------------------------------------------------------------------------

--- Core.on('playerLoaded', fn) — a local event on this side, shared by every resource.
function Core.on(hook, fn)
    if type(hook) ~= 'string' or type(fn) ~= 'function' then return nil end
    return AddEventHandler('core:hook:' .. hook, fn)
end

function Core.emitHook(hook, ...)
    if type(hook) ~= 'string' then return end
    return TriggerEvent('core:hook:' .. hook, ...)
end

function Core.isReady()
    return GetResourceState('core') == 'started'
end

local readyCallbacks = {}
local readyActive = false  -- core is started and this VM already dispatched for that run
local readyWatching = false

local function runCallback(fn)
    local ok, err = pcall(fn)
    if not ok then
        print(('[core] %s: onReady callback failed: %s'):format(resourceName, tostring(err)))
    end
end

--- One thread per callback: a callback that yields into core cannot stall the others.
local function runLater(fn)
    CreateThread(function() runCallback(fn) end)
end

local function dispatchReady()
    if readyActive then return end
    readyActive = true
    for i = 1, #readyCallbacks do
        runLater(readyCallbacks[i])
    end
end

--- One poll thread per VM (not one per callback); gives up after READY_TIMEOUT_MS.
local function watchReady()
    if readyWatching or readyActive then return end
    readyWatching = true
    CreateThread(function()
        local waited = 0
        while not Core.isReady() do
            if waited >= READY_TIMEOUT_MS then
                readyWatching = false
                print(('[core] %s: core is not started after %d ms, onReady callbacks stay pending')
                    :format(resourceName, READY_TIMEOUT_MS))
                return
            end
            Wait(READY_POLL_MS)
            waited = waited + READY_POLL_MS
        end
        readyWatching = false
        dispatchReady()
    end)
end

--- Runs fn once core is started, and again after every core restart.
function Core.onReady(fn)
    if type(fn) ~= 'function' then return end
    readyCallbacks[#readyCallbacks + 1] = fn
    if readyActive then
        runLater(fn) -- core is already up: just this one
        return
    end
    watchReady()
end

--- Client sugar: run fn now when the local player is already loaded, and in every case
--- keep it on the hook so a later load (respawn of the session, core restart) fires it
--- again. On the server there is no local player, so it is the plain hook (DESIGN §2.4).
function Core.onPlayerLoaded(fn)
    if type(fn) ~= 'function' then return nil end
    if not isServer then
        local player = LocalPlayer
        if player and player.state and player.state.loaded == true then
            runLater(fn)
        end
    end
    return Core.on('playerLoaded', fn)
end

local startEvent <const> = isServer and 'onResourceStart' or 'onClientResourceStart'
local stopEvent <const> = isServer and 'onResourceStop' or 'onClientResourceStop'

AddEventHandler(startEvent, function(res)
    if res ~= 'core' then return end -- a plugin's own start must not fire onReady again
    cachedConfig = nil               -- the restarted core may ship an edited config
    rawset(Core, 'Config', nil)
    dispatchReady()
end)

AddEventHandler(stopEvent, function(res)
    if res ~= 'core' then return end
    readyActive = false -- the next core start dispatches every callback again
end)
