-- core/server/api.lua
-- Loads FIRST on the server (DESIGN §1): it owns the single `exports.core:call` dispatcher (§2.2) and
-- `Core.Registry` (§2.3), the owner bookkeeping every other core module registers its remover into.
-- `Core` and `Config` are the two deliberate globals (import.lua / shared/config.lua).

local ownerOf = {}          -- [kind] = { [id] = ownerResource }
local byOwner = {}          -- [ownerResource] = { [kind] = { [id] = true } }
local removers = {}         -- [kind] = fn(id, owner)
local currentCaller = 'core'
-- A dispatched function may yield (Wait); a second `call` arriving meanwhile would clobber the global.
-- The per-coroutine record keeps each in-flight dispatch on its own caller. Weak keys: dead coroutines go.
local callerByCoroutine = setmetatable({}, { __mode = 'k' })

local Registry = {}
Core.Registry = Registry

--- Called by the `call` export right before dispatch; anything else is 'core'.
function Registry.setCaller(name)
    currentCaller = (type(name) == 'string' and name ~= '') and name or 'core'
end

--- The resource whose call is currently being served ('core' when core called itself).
function Registry.getCaller()
    local co = coroutine.running()
    local owner = co and callerByCoroutine[co]
    if owner then return owner end
    return currentCaller
end

local function forget(kind, id)
    local owner = ownerOf[kind] and ownerOf[kind][id]
    if not owner then return nil end
    ownerOf[kind][id] = nil
    local owned = byOwner[owner]
    if owned and owned[kind] then
        owned[kind][id] = nil
        if next(owned[kind]) == nil then owned[kind] = nil end
        if next(owned) == nil then byOwner[owner] = nil end
    end
    return owner
end

--- Remember that `owner` (default: the current caller) created `id` of `kind`.
function Registry.track(kind, id, owner)
    if type(kind) ~= 'string' or kind == '' then return false end
    if type(id) ~= 'string' and type(id) ~= 'number' then return false end
    owner = (type(owner) == 'string' and owner ~= '') and owner or Registry.getCaller()
    forget(kind, id)
    local ids = ownerOf[kind]
    if not ids then
        ids = {}
        ownerOf[kind] = ids
    end
    ids[id] = owner
    local owned = byOwner[owner]
    if not owned then
        owned = {}
        byOwner[owner] = owned
    end
    local kindIds = owned[kind]
    if not kindIds then
        kindIds = {}
        owned[kind] = kindIds
    end
    kindIds[id] = true
    return true
end

--- Drop the bookkeeping for one id (the module has already removed the thing itself).
function Registry.untrack(kind, id)
    if type(kind) ~= 'string' then return false end
    return forget(kind, id) ~= nil
end

--- A module registers its remover once at file scope: fn(id, owner).
function Registry.onOwnerStop(kind, fn)
    if type(kind) ~= 'string' or type(fn) ~= 'function' then return false end
    removers[kind] = fn
    return true
end

--- Everything `owner` still holds, by kind; used by the sweep and by admin tooling.
function Registry.getOwned(owner)
    return byOwner[owner]
end

-- Not reachable through the export: core's own plumbing. A plugin replacing a remover, the DB adapter or
-- the session/autosave machinery would take the whole server down with it when it stops.
-- PlayerGrid (§22.1) is core's own spatial index; plugins reach it through Player.getInRange/getClosest.
local INTERNAL_NAMESPACES <const> = { Registry = true, PlayerGrid = true,}
local INTERNAL_FUNCTIONS <const> = {
    ['DB.setAdapter'] = true,
    ['Player.loadSession'] = true,
    ['Player.loadAllConnected'] = true,
    ['Player.startAutosave'] = true,
    ['Player.stopAutosave'] = true, ['DB.markDegraded'] = true,
}

--- Look up an API function. Dotted sub-names ('menu.open') are stored flat on the namespace (§2.2);
--- the nested form is accepted as a fallback so a module may define either.
--- Returns nil, 'internal' for block-listed names.
local function resolve(namespace, fn)
    if type(namespace) ~= 'string' or type(fn) ~= 'string' then return nil end
    if INTERNAL_NAMESPACES[namespace] or INTERNAL_FUNCTIONS[namespace .. '.' .. fn] then
        return nil, 'internal'
    end
    local ns = Core[namespace]
    if type(ns) ~= 'table' then return nil end
    local f = rawget(ns, fn)
    if type(f) == 'function' then return f end
    local head, rest = fn:match('^([^.]+)%.([^.]+)$')
    if not head then return nil end
    local sub = rawget(ns, head)
    if type(sub) ~= 'table' then return nil end
    f = rawget(sub, rest)
    return type(f) == 'function' and f or nil
end

-- The one export of the server side. `caller` is what import.lua's proxy declares; the runtime's own view
-- of the invoking resource wins when it has one.
exports('call', function(caller, namespace, fn, ...)
    local owner = (type(caller) == 'string' and caller ~= '') and caller or nil
    local invoker = GetInvokingResource()
    if type(invoker) == 'string' and invoker ~= '' then owner = invoker end
    local f, blocked = resolve(namespace, fn)
    if not f then
        if blocked then
            error(('core: %s.%s is internal'):format(tostring(namespace), tostring(fn)), 0)
        end
        error(('core: no API %s.%s'):format(tostring(namespace), tostring(fn)), 0)
    end
    owner = owner or 'core'
    local co = coroutine.running()
    local previousGlobal = currentCaller
    local previousForCo = co and callerByCoroutine[co]
    Registry.setCaller(owner)
    if co then callerByCoroutine[co] = owner end
    local returned = table.pack(pcall(f, ...))
    if co then callerByCoroutine[co] = previousForCo end
    Registry.setCaller(previousGlobal)
    if not returned[1] then error(returned[2], 0) end
    return table.unpack(returned, 2, returned.n)
end)

-- A plugin stopped: remove everything it registered through core, kind by kind. Synchronous, no Wait.
-- Kinds without a registered remover (e.g. 'vehicle') keep their bookkeeping: DESIGN §2.3 only deletes
-- core vehicles when core itself stops.
AddEventHandler('onResourceStop', function(res)
    if type(res) ~= 'string' or res == Core.name then return end
    local owned = byOwner[res]
    if not owned then return end
    local kinds = {}
    for kind in pairs(owned) do kinds[#kinds + 1] = kind end
    for i = 1, #kinds do
        local kind = kinds[i]
        local remover = removers[kind]
        local ids = owned[kind]
        if remover and ids then
            local list = {}
            for id in pairs(ids) do list[#list + 1] = id end
            for j = 1, #list do
                local id = list[j]
                local ok, err = pcall(remover, id, res)
                if not ok then
                    Core.Log.warn('registry: %s remover failed for %s (%s)', kind, tostring(id), tostring(err))
                end
                forget(kind, id)
            end
        end
    end
end)
