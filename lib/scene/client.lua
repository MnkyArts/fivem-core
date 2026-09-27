--[[
    core / lib/scene/client.lua  —  Core.Scene on the client, the in-VM part (DESIGN §55.10, §55.13)

    Loaded into the CALLER's VM by import.lua (`local ns = ...`), client side only. Everything not defined here
    (get, handleOf, idOf, isAreaReady, waitAreaReady, hold, release, stats, bind, claim, listen, unlisten) is
    core's client/scene.lua, reached through the proxy; in core's own VM client/scene.lua replaces on/off with
    direct listeners. Module scope defines functions only: the event handlers are added on first use.

      Scene.handle(kind, { create, update?, destroy?, event? }) -> boolean
          This resource draws the nodes of plugin kind `kind` (defined on its server with handler = this
          resource). Core decides WHEN (radius, budget, priority, fades, visibility-safe deletes) and sends one
          local event `core:scene:kind (op, kind, id, view, target)` per state change — never per frame; this
          lib runs the handler (pcall) in this VM and reports what create() returned with the proxy call
          Scene.bind(id, entity | 0), so fades, handleOf and children work.
              create(node) -> entity | nil       update(node, entity, changed)
              destroy(node, entity)              event(node, entity, name, params, age)
          `node` is a copy: { id, kind, pos, rot, fields, parent, radius, motion, interact, attach, offset,
          offrot, bone, netId, changed?, changedFields? }. A handler that yields (model streaming) is fine:
          core waits up to 5 s for the bind.
      Scene.on(event, kindOrId, fn(id, info)) -> handle | nil          Scene.off(handle) -> boolean
          event = 'live' | 'gone' | 'changed' | 'event' | 'enter' | 'exit' | 'promoted' | 'demoted';
          kindOrId = a kind id, a node id or '*'. One local handler on `core:scene:ev` per VM; core triggers
          it only for what some resource listens to (proxy Scene.listen / Scene.unlisten).
    A core restart re-sends the claims and listens; a core stop destroys this VM's plugin-kind entities
    through their handlers (nothing would ask for it later).

    Natives: none (AddEventHandler, GetCurrentResourceName, GetResourceState are runtime helpers).
]]

local ns = ...

local RESOURCE <const> = GetCurrentResourceName()
local EVENTS <const> = { live = true, gone = true, changed = true, event = true, enter = true, exit = true,
    promoted = true, demoted = true }

local handlers = {}        -- kind id -> the handler table given to Scene.handle (this VM)
local entities = {}        -- node id -> the entity this VM's create() returned
local views = {}           -- node id -> the last view (a destroy when core stops)
local listeners = {}       -- handle -> { event, key, fn }
local nextHandle = 0
local wired = false

local function coreUp() return GetResourceState('core') == 'started' end

local function logError(fmt, ...)
    Core.Log.error('Scene: ' .. fmt, ...)
end

--- Runs a plugin handler; an error is logged and answers nil.
local function run(what, fn, ...)
    if fn == nil then return nil end
    local ok, res = pcall(fn, ...)
    if not ok then
        logError('%s handler failed: %s', what, tostring(res))
        return nil
    end
    return res
end

--- A kind id, a node id (integer) or '*' (nil = '*'); nil when unusable.
local function keyOf(kindOrId)
    if kindOrId == nil or kindOrId == '*' then return '*' end
    if type(kindOrId) == 'number' then
        local id = math.tointeger(kindOrId)
        return (id and id > 0) and id or nil
    end
    return ns.validKindId(kindOrId) and kindOrId or nil
end

--- `core:scene:kind`: one state change of a node of a kind this VM handles (`target` = the claimant).
local function onKind(op, kind, id, view, target)
    if target ~= nil and target ~= RESOURCE then return end
    local h = handlers[kind]
    if not h or math.type(id) ~= 'integer' then return end
    if op == 'create' then
        local e = run('create', h.create, view)
        e = (math.type(e) == 'integer' and e > 0) and e or 0
        entities[id], views[id] = e ~= 0 and e or nil, view
        local ok, accepted, why = pcall(ns.bind, id, e)
        if ok and why == 'refused' then                    -- a player ped, a networked or core-owned entity:
            entities[id] = nil                              -- core ignores it, and so does this lib (logged there)
        elseif (not ok or accepted == false) and e ~= 0 then   -- core no longer wants it: ours to delete
            entities[id], views[id] = nil, nil
            run('destroy', h.destroy, view, e)
        end
    elseif op == 'update' then
        views[id] = view
        run('update', h.update, view, entities[id], type(view) == 'table' and view.changed or nil)
    elseif op == 'destroy' then
        local e = entities[id]
        entities[id], views[id] = nil, nil
        run('destroy', h.destroy, view, e)
    elseif op == 'event' then
        local ev = type(view) == 'table' and view.event or nil
        if type(ev) ~= 'table' then return end
        run('event', h.event, view, entities[id], ev.name, ev.params, ev.age)
    end
end

--- `core:scene:ev (event, id, info)`: this VM's Scene.on listeners that match.
local function onEv(event, id, info)
    local kind = type(info) == 'table' and info.kind or nil
    local hits = nil
    for _, l in pairs(listeners) do
        if l.event == event and (l.key == '*' or l.key == id or (kind ~= nil and l.key == kind)) then
            hits = hits or {}
            hits[#hits + 1] = l.fn
        end
    end
    if not hits then return end
    for i = 1, #hits do run(event, hits[i], id, info) end
end

--- Claims and listens again for a (re)started core; pcall'd: a refusal must not break the others.
local function resend()
    for kind in pairs(handlers) do
        local ok, err = pcall(ns.claim, kind)
        if not ok then logError('claim %s failed: %s', kind, tostring(err)) end
    end
    for _, l in pairs(listeners) do pcall(ns.listen, l.key, l.event) end
end

--- Core stopped: nobody will ask for a destroy any more, so this VM's plugin-kind entities go now.
local function dropAll()
    for id, e in pairs(entities) do
        local view = views[id]
        local h = type(view) == 'table' and handlers[view.kind] or nil
        if h then run('destroy', h.destroy, view, e) end
    end
    entities, views = {}, {}
end

local function wire()
    if wired then return end
    wired = true
    AddEventHandler('core:scene:kind', onKind)
    AddEventHandler('core:scene:ev', onEv)
    AddEventHandler('onClientResourceStart', function(res)
        if res == 'core' then resend() end
    end)
    AddEventHandler('onClientResourceStop', function(res)
        if res == 'core' then dropAll() end
    end)
end

--- This resource creates the nodes of plugin kind `kind` (DESIGN §55.13).
---@param kind string '<resource>:<name>'
---@param h table { create = fn(node) -> entity|nil, update?, destroy?, event? }
---@return boolean
function ns.handle(kind, h)
    if not ns.isPluginKind(kind) or type(h) ~= 'table' or not Core.Utils.isCallable(h.create) then
        logError("handle needs a plugin kind id ('<resource>:<name>') and { create = fn, ... }")
        return false
    end
    handlers[kind] = h
    wire()
    if not coreUp() then return true end                   -- claimed when core starts
    local ok, res = pcall(ns.claim, kind)
    if not ok then
        logError('claim %s failed: %s', kind, tostring(res))
        return false
    end
    return res ~= false
end

--- Listens to a client scene event of a kind, a node or everything ('*').
---@param event string
---@param kindOrId string|integer|nil
---@param fn fun(id: integer, info: table)
---@return integer|nil handle
function ns.on(event, kindOrId, fn)
    local key = keyOf(kindOrId)
    if not EVENTS[event] or key == nil or not Core.Utils.isCallable(fn) then return nil end
    wire()
    nextHandle = nextHandle + 1
    listeners[nextHandle] = { event = event, key = key, fn = fn }
    if coreUp() then pcall(ns.listen, key, event) end
    return nextHandle
end

--- Removes a listener added with Scene.on.
---@param handle integer
---@return boolean
function ns.off(handle)
    local l = listeners[handle]
    if not l then return false end
    listeners[handle] = nil
    if coreUp() then pcall(ns.unlisten, l.key, l.event) end
    return true
end
