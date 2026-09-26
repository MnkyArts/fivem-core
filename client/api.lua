--[[
    core/client/api.lua -- loads FIRST on the client (DESIGN §1).

    Owns:
      * the single `call` export every plugin VM proxies into (DESIGN §2.2) — its caller is the
        engine's GetInvokingResource() (shared native, verified with fxref 2026-09-26); the name the
        proxy declares must match it or the call is refused (§54.1),
      * `Core.Registry`: who registered what, and the automatic sweep when that
        owner's resource stops (DESIGN §2.3).

    Every other client module registers its remover here once, at file scope.
]]

local currentCaller <const> = 'core'
-- The caller of the dispatch currently being served. A dispatched call may yield for seconds
-- (Core.UI.menu.open and friends await an NUI answer), and FiveM runs export calls, event handlers and
-- threads in coroutines: the caller therefore lives PER COROUTINE, and a coroutine without an entry is
-- core's own code ('core'). `caller` is used only on the main thread, where nothing can yield (resource
-- load, the offline suites). Weak keys: finished coroutines drop out on their own.
local caller = currentCaller
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

local function ownerName(name)
    return (type(name) == 'string' and name ~= '') and name or currentCaller
end

--- The running coroutine, or nil on the main thread.
local function running()
    local co, main = coroutine.running()
    if main then return nil end
    return co
end

--- Sets the caller of the running coroutine (the main-thread value outside one).
---@param name string|nil
function Registry.setCaller(name)
    local co = running()
    if co then
        callerByCoroutine[co] = ownerName(name)
    else
        caller = ownerName(name)
    end
end

--- The resource whose call is currently being dispatched in this coroutine ('core' when internal).
--- A coroutine without its own entry is core's (a thread core started, a handler, a timer).
---@return string
function Registry.getCaller()
    local co = running()
    if co then return callerByCoroutine[co] or currentCaller end
    return caller
end

--- Runs callback(...) as `owner` in this coroutine only, restored afterwards -> pcall results.
function Registry.withCaller(owner, callback, ...)
    local co = running()
    local previous
    if co then
        previous = callerByCoroutine[co]
        callerByCoroutine[co] = ownerName(owner)
    else
        previous = caller
        caller = ownerName(owner)
    end
    local result = table.pack(pcall(callback, ...))
    if co then callerByCoroutine[co] = previous else caller = previous end
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

-- (invoker .. '>' .. declared) -> true: a spoofing resource is logged once per pair, not per call
local spoofWarned = {}

--- The owner of an export call (DESIGN §2.2, §54): the RUNTIME's view of the invoking resource
--- (`GetInvokingResource()`, set by the engine for every cross-resource export call) is the truth;
--- the name import.lua's proxy declares is only checked against it. A resource that declares another
--- one's name is refused, so nobody can drop another resource's key capture, HUD or shell hide reason,
--- page or registration by passing its name. Without an invoking resource (offline suites, a direct
--- Lua call) the declared name stands. Returns owner, or nil + the refusal message.
local function exportCaller(declared)
    local claimed = (type(declared) == 'string' and declared ~= '') and declared or nil
    local invoker = GetInvokingResource()
    if type(invoker) ~= 'string' or invoker == '' then return claimed end
    if claimed and claimed ~= invoker then
        local pair = invoker .. '>' .. claimed
        if not spoofWarned[pair] then
            spoofWarned[pair] = true
            Core.Log.warn('call() refused: resource %s declared itself as %s', invoker, claimed)
        end
        return nil, ('core: call() refused: %s is not %s'):format(invoker, claimed)
    end
    return invoker
end

exports('call', function(callerName, namespace, fn, ...)
    if type(namespace) ~= 'string' or type(fn) ~= 'string' then
        error('core: call(namespace, fn) expects two strings', 2)
    end

    local owner, refused = exportCaller(callerName)
    if refused then error(refused, 2) end

    if INTERNAL_NS[namespace] then
        error(('core: %s is internal to core'):format(namespace), 2)
    end

    local ns = rawget(Core, namespace)
    local f = type(ns) == 'table' and resolve(ns, fn) or nil
    if not f then
        error(('core: no API %s.%s'):format(namespace, fn), 2)
    end

    -- withCaller pcalls, so the caller is restored even when the API function errors; pcall is
    -- yieldable in Lua 5.4, so an API that waits (NUI, callbacks) still works. Inside a coroutine only
    -- that coroutine's entry changes: an overlapping yielding call can never leak its owner.
    local ret = table.pack(Registry.withCaller(owner, f, ...))

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
