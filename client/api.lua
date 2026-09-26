--[[
    core/client/api.lua -- loads FIRST on the client (DESIGN §1).

    Owns:
      * the single `call` export every plugin VM proxies into (DESIGN §2.2),
      * `Core.Registry`: who registered what, and the automatic sweep when that
        owner's resource stops (DESIGN §2.3).

    Every other client module registers its remover here once, at file scope.
]]

local currentCaller <const> = 'core'
local caller = currentCaller
-- Per-coroutine caller. A dispatched call may yield for seconds (Core.UI.menu.open
-- and friends await an NUI answer); another plugin's call running during that yield
-- must not take over the first call's ownership. Weak keys: finished coroutines drop
-- out on their own, the dispatcher clears its own entry anyway.
local callerByCoroutine = setmetatable({}, { __mode = 'k' })

---@type table<string, table<string, string>>  kind -> id -> owner resource
local tracked = {}
---@type table<string, fun(id: string, owner: string)>  kind -> remover
local removers = {}

-- Namespaces that exist inside core's VM but are not part of the plugin API:
-- the world scheduler (DESIGN §6.3 -- its draw callbacks must stay local Lua
-- functions, never cross-VM funcrefs), the registry itself (a plugin must not
-- be able to set a caller name or replace a kind's remover) and the seam
-- client/ui.lua and client/ui_plugins.lua share (DESIGN §38.4: it can send raw
-- NUI messages and answer held page requests).
local INTERNAL_NS <const> = { World = true, Registry = true, UIInternal = true, UIForms = true }

local Registry = {}

--- Set by the `call` export before dispatch; registration APIs read it back.
--- Recorded for the calling coroutine as well as globally (see getCaller).
---@param name string|nil
function Registry.setCaller(name)
    caller = (type(name) == 'string' and name ~= '') and name or currentCaller
    local co = coroutine.running()
    if co then callerByCoroutine[co] = caller end
end

--- The resource whose call is currently being dispatched ('core' when internal).
--- The coroutine-local value wins, so concurrent (yielding) calls keep their own
--- owner; the global value is the fallback for core's own threads.
---@return string
function Registry.getCaller()
    local co = coroutine.running()
    local owner = co and callerByCoroutine[co]
    return owner or caller
end

-- Internal callback ownership scope: never changes the global fallback across a yield.
function Registry.withCaller(owner, callback, ...)
    local co = coroutine.running()
    local previous = co and callerByCoroutine[co]
    if co then callerByCoroutine[co] = owner end
    local result = table.pack(pcall(callback, ...))
    if co then callerByCoroutine[co] = previous end
    return table.unpack(result, 1, result.n)
end

--- Remember that `owner` created `id` of `kind` ('marker', 'label', 'blip', ...).
---@param kind string
---@param id string
---@param owner string|nil
function Registry.track(kind, id, owner)
    if type(kind) ~= 'string' or type(id) ~= 'string' then return end
    local byId = tracked[kind]
    if not byId then
        byId = {}
        tracked[kind] = byId
    end
    byId[id] = (type(owner) == 'string' and owner ~= '') and owner or currentCaller
end

--- Forget `id`; called by the module that owns the kind when it removes the item.
---@param kind string
---@param id string
function Registry.untrack(kind, id)
    local byId = tracked[kind]
    if byId then byId[id] = nil end
end

--- Register the one function that removes an item of `kind` on owner stop.
---@param kind string
---@param fn fun(id: string, owner: string)
function Registry.onOwnerStop(kind, fn)
    if type(kind) ~= 'string' or type(fn) ~= 'function' then return end
    removers[kind] = fn
end

--- Ids of `kind` owned by `owner` (used by the modules' `removeAll`).
---@param kind string
---@param owner string
---@return string[]
function Registry.idsOf(kind, owner)
    local list = {}
    local byId = tracked[kind]
    if not byId or type(owner) ~= 'string' then return list end
    for id, ownerName in pairs(byId) do
        if ownerName == owner then list[#list + 1] = id end
    end
    return list
end

Core.Registry = Registry

--- Resolve 'fn' or one level of dotted sub-name ('menu.open') inside a namespace.
---@param ns table
---@param fn string
---@return function|nil
local function resolve(ns, fn)
    local f = rawget(ns, fn)
    if type(f) == 'function' then return f end

    local head, tail = fn:match('^([^.]+)%.([^.]+)$')
    if not head then return nil end

    local sub = rawget(ns, head)
    if type(sub) ~= 'table' then return nil end

    f = rawget(sub, tail)
    return type(f) == 'function' and f or nil
end

exports('call', function(callerName, namespace, fn, ...)
    if type(namespace) ~= 'string' or type(fn) ~= 'string' then
        error('core: call(namespace, fn) expects two strings', 2)
    end

    if INTERNAL_NS[namespace] then
        error(('core: %s is internal to core'):format(namespace), 2)
    end

    local ns = rawget(Core, namespace)
    local f = type(ns) == 'table' and resolve(ns, fn) or nil
    if not f then
        error(('core: no API %s.%s'):format(namespace, fn), 2)
    end

    local co = coroutine.running()
    local prevCaller, prevCoCaller = caller, co and callerByCoroutine[co]
    Registry.setCaller(callerName)

    -- pcall so the caller is restored even when the API function errors; pcall is
    -- yieldable in Lua 5.4, so an API that waits (NUI, callbacks) still works.
    local ret = table.pack(pcall(f, ...))

    if co then callerByCoroutine[co] = prevCoCaller end
    caller = prevCaller

    if not ret[1] then error(ret[2], 0) end
    return table.unpack(ret, 2, ret.n)
end)

--- Sweep everything a stopping resource registered. Synchronous: no Wait here.
AddEventHandler('onResourceStop', function(resource)
    if type(resource) ~= 'string' then return end

    for kind, byId in pairs(tracked) do
        local remove = removers[kind]
        for id, owner in pairs(byId) do
            if owner == resource then
                byId[id] = nil
                if remove then
                    local ok, err = pcall(remove, id, owner)
                    if not ok then
                        print(('[core] registry sweep failed for %s %s: %s'):format(kind, id, tostring(err)))
                    end
                end
            end
        end
    end
end)
