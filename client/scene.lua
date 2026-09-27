--[[ core — client/scene.lua — Core.Scene on the client (DESIGN §55.10, §55.13)
     LAST of the client scene files: the public client API on the lib namespace Core.Scene (plugins reach it
     through the proxy; handle / on / off of plugins are lib/scene/client.lua's), listeners, the plugin-kind
     bridge, `/scene` and `/scene debug`. It clears the one-shot global `CoreSceneRuntime` at the end.

       Scene.get(id) -> { id, kind, pos, rot, fields, parent, state } | nil       a copy
       Scene.handleOf(id) -> entity | nil                 Scene.idOf(entity) -> id | nil
       Scene.isAreaReady(pos, radius = 50) -> boolean     Scene.waitAreaReady(pos, radius?, timeoutMs?) -> boolean
                                                          (not ready while C.mapsPending — client/maps.lua — reports
                                                          a queued server map projection there; same timeout)
       Scene.hold(id) -> entity | nil / Scene.release(id) -> boolean      owner-tracked (Registry 'sceneHold')
       Scene.on(event, kindOrId, fn(id, info)) -> handle / Scene.off(handle)    core's own VM: direct calls
       Scene.listen(kindOrId, event) / Scene.unlisten(kindOrId, event)   the lib's half ('sceneListener')
       Scene.claim(kind) / Scene.bind(id, entity | 0)     the plugin-kind bridge (Registry 'sceneHandler')
       Scene.stats() -> { cells…, nodes, bytesIn, … the materialiser's counters, plugin = { … } }
     Listener events (raised through C.emit by the cache, the materialiser and scene_fx): 'live' (a = entity),
     'gone', 'changed' (a = change bits), 'event' (a = name, b = params, c = age, d, e, f = x, y, z), 'enter',
     'exit', 'promoted' (a = netId), 'demoted'. `core:scene:ev (event, id, info)` is triggered only for a kind,
     node or '*' some plugin listens to, so an unlistened event costs a table lookup.
     Plugin kinds: the materialiser's 'custom' handler here turns create / update / destroy / event into one
     local event `core:scene:kind (op, kind, id, view, target)` (never per frame: dead-reckoning ticks are not
     forwarded, the movers place the entity); the claiming resource's lib runs its handler and answers
     Scene.bind(id, entity | 0) — within the event (create returns the entity), or later when its handler yields:
     then create answers C.mat.PENDING (the node stays STAGED) and the bind finishes it with C.mat.bound(node,
     entity); the materialiser times a missing bind out (5 s: destroy(node, nil), the node fails once). Without
     late binds in the materialiser the node is LIVE without an entity, only handleOf / idOf learn the late one,
     and the bridge forgets a bind that did not come within 5 s.

     Natives (fxref 2026-09-26; apiset client unless noted): IsAceAllowed(object) (CFX shared),
       GetResourceState(name) (CFX shared), DoesEntityExist(entity), NetworkGetEntityIsNetworked(entity),
       GetEntityType(entity), IsPedAPlayer(ped), GetGameTimer(), GetFinalRenderedCamCoord(),
       DrawMarker(type, x, y, z, dirX, dirY, dirZ, rotX, rotY, rotZ, sx, sy, sz, r, g, b, a, bob, face, p19,
       rotate, dict, name, drawOnEnts), SetDrawOrigin(x, y, z, p3), ClearDrawOrigin(), SetTextFont(font),
       SetTextScale(scale, size), SetTextColour(r, g, b, a), SetTextOutline(), SetTextCentre(align),
       BeginTextCommandDisplayText(text), AddTextComponentSubstringPlayerName(text),
       EndTextCommandDisplayText(x, y, p2). Runtime helpers: RegisterCommand, TriggerEvent, AddEventHandler,
       CreateThread, Wait, SetTimeout.
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and type(C.cache) == 'table' and type(C.focus) == 'table' and type(C.mat) == 'table',
    'client/scene.lua loads after the other client scene files (CoreSceneRuntime.cache / .focus / .mat)')
local cache, focus, mat = C.cache, C.focus, C.mat
local Scene = Core.Scene                  -- the lib namespace (lib/scene/*.lua): extend, never replace
local Registry, Log, Utils = Core.Registry, Core.Log, Core.Utils
local mtype, tointeger, sqrt = math.type, math.tointeger, math.sqrt

local cfg = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
local AREA_RADIUS <const>, MAX_AREA <const> = 50.0, 500.0
local DEFAULT_WAIT_MS <const>, MAX_WAIT_MS <const>, WAIT_POLL_MS <const> = 5000, 60000, 50
local BIND_TIMEOUT_MS <const> = 5000
local EVENTS <const> = { live = true, gone = true, changed = true, event = true, enter = true, exit = true,
    promoted = true, demoted = true }
local STATE_NAMES <const> = { [0] = 'known', 'warm', 'staged', 'live', 'retiring', 'failed', 'off' }
local selfName <const> = GetCurrentResourceName()
local stopped = false

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function int(v)
    if type(v) ~= 'number' then return nil end
    return mtype(v) == 'integer' and v or tointeger(v)
end

local function finite(v, limit)
    return type(v) == 'number' and v == v and v >= -limit and v <= limit
end

local function readCoords(c)
    local t = type(c)
    if t ~= 'vector3' and t ~= 'vector4' and t ~= 'table' then return nil end
    local x, y, z = c.x, c.y, c.z
    if not (finite(x, 20000) and finite(y, 20000) and finite(z, 5000)) then return nil end
    return x + 0.0, y + 0.0, z + 0.0
end

local function areaRadius(radius)
    radius = tonumber(radius) or AREA_RADIUS
    if radius ~= radius or radius < 0 then return 0.0 end
    return radius > MAX_AREA and MAX_AREA or radius + 0.0
end

--- A deep copy of decoded (plain) data: a caller of Scene.get can never touch the cache.
local function copy(v, depth)
    if type(v) ~= 'table' or depth > 8 then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x, depth + 1) end
    return out
end

--- A kind id, a node id or '*' (nil = '*'); nil when unusable.
local function keyOf(kindOrId)
    if kindOrId == nil or kindOrId == '*' then return '*' end
    if type(kindOrId) == 'number' then
        local id = int(kindOrId)
        return (id and id > 0) and id or nil
    end
    return Scene.validKindId(kindOrId) and kindOrId or nil
end

--- The materialiser's state of a node as a name: its record (node.m, set by C.mat.add) carries `st`; a node the
--- materialiser does not know (unwanted, placeholder) is 'known'.
local function stateOf(node)
    local fn = mat.stateOf
    local st = fn and fn(node.id)
    if st == nil then
        local m = node.m
        st = type(m) == 'table' and m.st or nil
    end
    if type(st) == 'number' then return STATE_NAMES[st] or 'known' end
    if type(st) == 'string' then return st end
    return 'known'
end

--------------------------------------------------------------------------------
-- listeners: core-side (direct) and plugin (`core:scene:ev`, only for what someone listens to)
--------------------------------------------------------------------------------

local listens = {}                        -- event -> key -> count of plugin listens (key: kind id | node id | '*')
local listenBy = {}                       -- registry id -> { event, key, n }
local coreL, coreN = {}, {}               -- handle -> { event, key, fn }; event -> count
local nextHandle = 0

local function bump(event, key, d)
    local map = listens[event]
    if not map then
        if d <= 0 then return end
        map = {}
        listens[event] = map
    end
    local n = (map[key] or 0) + d
    map[key] = n > 0 and n or nil
    if next(map) == nil then listens[event] = nil end
end

local function matches(key, kid, nid)
    return key == '*' or key == nid or (kid ~= nil and key == kid)
end

--- The names of the change bits of a 'changed' event.
local function changeNames(bits)
    local out = {}
    if bits & cache.BITS.kind ~= 0 then out[#out + 1] = 'kind' end
    if bits & cache.BITS.promote ~= 0 then out[#out + 1] = 'promote' end
    if bits & cache.BITS.demote ~= 0 then out[#out + 1] = 'demote' end
    local whats = cache.WHATS
    for i = 1, #whats do
        if bits & whats[i][1] ~= 0 then out[#out + 1] = whats[i][2] end
    end
    return out
end

local function infoOf(event, node, kid, a, b, c, d, e, f)
    local info = { event = event, kind = kid }
    if event == 'live' then
        info.entity = (mtype(a) == 'integer' and a ~= 0) and a or nil
    elseif event == 'changed' then
        info.changes = changeNames(mtype(a) == 'integer' and a or 0)
        local chg = node and node.chg
        if chg then
            local names = {}
            for name in pairs(chg) do names[#names + 1] = name end
            info.fields = names
        end
    elseif event == 'event' then
        info.name, info.params, info.age = a, b, c
        if d then info.pos = vector3(d, e, f) end
    elseif event == 'promoted' then
        info.netId = a
    end
    return info
end

--- Raised by the cache, the materialiser and scene_fx: listeners of the event hear it (see the header).
function C.emit(event, node, a, b, c, d, e, f)
    local plug, n = listens[event], coreN[event]
    if not plug and not n then return end
    local k = node and node.kind
    local kid, nid = k and k.id or nil, node and node.id or 0
    local toPlugins = plug ~= nil and (plug['*'] ~= nil or plug[nid] ~= nil or (kid ~= nil and plug[kid] ~= nil))
    local toCore = false
    if n then
        for _, l in pairs(coreL) do
            if l.event == event and matches(l.key, kid, nid) then toCore = true break end
        end
    end
    if not toPlugins and not toCore then return end
    local info = infoOf(event, node, kid, a, b, c, d, e, f)
    if toPlugins then TriggerEvent('core:scene:ev', event, nid, info) end
    if toCore then
        for _, l in pairs(coreL) do
            if l.event == event and matches(l.key, kid, nid) then
                local ok, err = pcall(l.fn, nid, info)
                if not ok then Log.warn('scene: %s listener failed: %s', event, tostring(err)) end
            end
        end
    end
end

-- the materialiser's LIVE / GONE transitions (its 'event' calls are the cache's to raise: it sees every node)
if mat.setListener then
    mat.setListener(function(event, node, h)
        if event == 'live' then C.emit('live', node, h) elseif event == 'gone' then C.emit('gone', node) end
    end)
end

--- Core-side listener (core's own VM; a plugin's Scene.on is the lib's). Owner-tracked.
---@return integer|nil handle
function Scene.on(event, kindOrId, fn)
    local key = keyOf(kindOrId)
    if not EVENTS[event] or key == nil or not Utils.isCallable(fn) then return nil end
    nextHandle = nextHandle + 1
    coreL[nextHandle] = { event = event, key = key, fn = fn }
    coreN[event] = (coreN[event] or 0) + 1
    Registry.track('sceneListener', 'L' .. nextHandle, Registry.getCaller())
    return nextHandle
end

local function offHandle(handle)
    local l = coreL[handle]
    if not l then return false end
    coreL[handle] = nil
    local n = coreN[l.event] - 1
    coreN[l.event] = n > 0 and n or nil
    return true
end

function Scene.off(handle)
    if not offHandle(handle) then return false end
    Registry.untrack('sceneListener', 'L' .. handle)
    return true
end

--- A plugin VM listens (the lib's Scene.on): core triggers `core:scene:ev` for this kind / id / '*'.
function Scene.listen(kindOrId, event)
    local key = keyOf(kindOrId)
    if not EVENTS[event] or key == nil then return false end
    local owner = Registry.getCaller()
    local rid = ('%s|%s|%s'):format(owner, event, type(key) == 'number' and ('#' .. key) or key)
    local rec = listenBy[rid]
    if not rec then
        rec = { event = event, key = key, n = 0 }
        listenBy[rid] = rec
        Registry.track('sceneListener', rid, owner)
    end
    rec.n = rec.n + 1
    bump(event, key, 1)
    return true
end

function Scene.unlisten(kindOrId, event)
    local key = keyOf(kindOrId)
    if not EVENTS[event] or key == nil then return false end
    local owner = Registry.getCaller()
    local rid = ('%s|%s|%s'):format(owner, event, type(key) == 'number' and ('#' .. key) or key)
    local rec = listenBy[rid]
    if not rec then return false end
    rec.n = rec.n - 1
    bump(event, key, -1)
    if rec.n <= 0 then
        listenBy[rid] = nil
        Registry.untrack('sceneListener', rid)
    end
    return true
end

Registry.onOwnerStop('sceneListener', function(rid)
    local handle = rid:match('^L(%d+)$')
    if handle then return offHandle(tonumber(handle)) end
    local rec = listenBy[rid]
    if not rec then return end
    listenBy[rid] = nil
    bump(rec.event, rec.key, -rec.n)
end)

--------------------------------------------------------------------------------
-- the read API
--------------------------------------------------------------------------------

local bridged, byEntity = {}, {}          -- node id -> entity a plugin bound late; entity -> node id

--- A read-only copy of a cached node: { id, kind, pos, rot, fields, parent, state } | nil.
function Scene.get(id)
    id = int(id)
    local node = id and cache.node(id)
    if not node or node.dependency then return nil end
    local k = node.kind
    return {
        id = node.id, kind = k and k.id or nil,
        pos = vector3(node.x, node.y, node.z), rot = vector3(node.rx, node.ry, node.rz),
        fields = copy(node.fields, 0), parent = node.parent ~= 0 and node.parent or nil, state = stateOf(node),
    }
end

--- The entity of a node on this client: its local copy, a plugin's late-bound entity, or — while the node is
--- promoted and its local copy has gone — the networked clone (client/scene_promote.lua, looked up at call time).
function Scene.handleOf(id)
    id = int(id)
    if not id or id <= 0 then return nil end
    local h = mat.handleOf(id)
    if mtype(h) == 'integer' and h ~= 0 then return h end
    h = bridged[id]
    if h then return h end
    local P = C.promote
    return P and P.cloneOf and P.cloneOf(id) or nil
end

--- The node id of an entity the runtime created, a plugin bound, or a promoted node's clone (when
--- client/scene_promote.lua maps clones back: C.promote.idOfClone), or nil.
function Scene.idOf(entity)
    if mtype(entity) ~= 'integer' or entity == 0 then return nil end
    local id = mat.idOf(entity) or byEntity[entity]
    if id then return id end
    local P = C.promote
    return P and P.idOfClone and P.idOfClone(entity) or nil
end

--- The area's readiness: no queued server map projection touches it (client/maps.lua's C.mapsPending: a box of
--- GlobalState 'core:mapsPending' of this client's bucket — the server still projects map content there; absent
--- without the maps client), its cells are current and the materialiser has what a camera there would want.
local function areaReadyAt(x, y, z, r)
    local pending = C.mapsPending
    if pending then
        local ok, busy = pcall(pending, x, y, r)
        if ok and busy then return false end
    end
    return cache.areaReady(x, y, r) and mat.areaReady(x, y, z, r) == true
end

--- True when no map projection is still queued there, the cells around `pos` are current and every node within
--- `radius` a camera there would want is materialised (or failed, or capped).
function Scene.isAreaReady(pos, radius)
    local x, y, z = readCoords(pos)
    if not x then return false end
    return areaReadyAt(x, y, z, areaRadius(radius))
end

--- Waits in the calling thread until Scene.isAreaReady(pos, radius) or timeoutMs (default 5000) passed. It only
--- waits: the materialiser's teleport budgets follow the faded screen, never a waiter (RV2 F7).
---@return boolean ready
function Scene.waitAreaReady(pos, radius, timeoutMs)
    local x, y, z = readCoords(pos)
    if not x then return false end
    local r = areaRadius(radius)
    local ms = int(tonumber(timeoutMs)) or DEFAULT_WAIT_MS
    if ms < 0 then ms = 0 elseif ms > MAX_WAIT_MS then ms = MAX_WAIT_MS end
    local deadline = GetGameTimer() + ms
    focus.reportSoon()
    while not stopped do
        if areaReadyAt(x, y, z, r) then return true end
        if GetGameTimer() >= deadline then return false end
        Wait(WAIT_POLL_MS)
    end
    return false
end

--------------------------------------------------------------------------------
-- holds (the editor drags an entity: the runtime leaves it alone), owner-tracked
--------------------------------------------------------------------------------

local holders, holdIds = {}, {}          -- node id -> { [owner] = true }; registry id -> node id

local function holdId(owner, id) return owner .. '|' .. id end

--- Keeps the runtime away from a node's entity (no move, re-create or delete) until released; returns the
--- entity when there is one.
function Scene.hold(id)
    id = int(id)
    if not id or id <= 0 then return nil end
    local owner = Registry.getCaller()
    local set = holders[id]
    if not set then
        set = {}
        holders[id] = set
    end
    if not set[owner] then
        set[owner] = true
        local rid = holdId(owner, id)
        holdIds[rid] = id
        Registry.track('sceneHold', rid, owner)
        mat.hold(id, owner)
    end
    return Scene.handleOf(id)
end

local function releaseFor(id, owner)
    local set = holders[id]
    if not set or not set[owner] then return false end
    set[owner] = nil
    holdIds[holdId(owner, id)] = nil
    if next(set) == nil then holders[id] = nil end
    mat.release(id, owner)                -- what changed while held applies now
    return true
end

--- Gives the caller's hold back.
function Scene.release(id)
    id = int(id)
    if not id then return false end
    local owner = Registry.getCaller()
    if not releaseFor(id, owner) then return false end
    Registry.untrack('sceneHold', holdId(owner, id))
    return true
end

Registry.onOwnerStop('sceneHold', function(rid, owner)
    local id = holdIds[rid]
    if id then releaseFor(id, owner) end
end)

--------------------------------------------------------------------------------
-- plugin kinds (§55.13): claims, the 'custom' handler, binds
--------------------------------------------------------------------------------

local claims = {}                          -- plugin kind id -> the resource that handles it
local made = {}                            -- node id -> { kind, target } of a create sent to a plugin
local waiting = {}                         -- node id -> { node, at } a create whose bind has not come yet
local creating, syncBind = nil, nil        -- the node whose create event is being dispatched, its bind
local nWaiting = 0

--- This resource draws plugin kind `kind` (the lib's Scene.handle). A second resource is refused while the
--- first runs; the kind's server definition may name its handler (meta.handler): the cache checks that.
function Scene.claim(kindId)
    if not Scene.isPluginKind(kindId) then return false end
    local owner = Registry.getCaller()
    local cur = claims[kindId]
    if cur and cur ~= owner and GetResourceState(cur) == 'started' then
        Log.warn('Scene.claim: %s is handled by %s; %s refused', kindId, cur, owner)
        return false
    end
    claims[kindId] = owner
    Registry.track('sceneHandler', kindId, owner)
    cache.setClaim(kindId, owner)
    return true
end

local function forget(id)
    made[id] = nil
    if waiting[id] then waiting[id], nWaiting = nil, nWaiting - 1 end
    local e = bridged[id]
    if e then bridged[id], byEntity[e] = nil, nil end
end

Registry.onOwnerStop('sceneHandler', function(kindId, owner)
    if claims[kindId] ~= owner then return end
    claims[kindId] = nil
    for id, rec in pairs(made) do
        if rec.kind == kindId then forget(id) end   -- the stopped resource's entities went with it
    end
    cache.setClaim(kindId, nil)            -- its nodes turn unwanted: the materialiser lets them go
end)

--- What the plugin's handler gets (TriggerEvent copies it into the plugin's VM).
local function viewOf(node, what, data)
    local k = node.kind
    local view = {
        id = node.id, kind = k and k.id or nil,
        pos = vector3(node.x, node.y, node.z), rot = vector3(node.rx, node.ry, node.rz),
        fields = node.fields, parent = node.parent ~= 0 and node.parent or nil, radius = node.radius,
        motion = node.motion, interact = node.interact, attach = node.attach, offset = node.offset,
        offrot = node.offrot, bone = node.bone, netId = node.netId, changed = what,
    }
    if what == 'fields' and type(data) == 'table' then
        local names = {}
        for name in pairs(data) do names[#names + 1] = name end
        view.changedFields = names
    end
    return view
end

--- Interaction prompts (§55.14) of a plugin node: client/scene_kinds.lua's helper (entity target or coords).
local function syncPrompts(node, entity)
    local K = C.kinds
    if K and K.syncInteract then K.syncInteract(node, entity, node.x, node.y, node.z) end
end

--- A late bind (the plugin's handler yielded) or its timeout: the materialiser learns the entity when it
--- takes late binds (mat.bound); Scene.handleOf / idOf know it either way.
local function lateBind(node, entity)
    if entity ~= 0 then bridged[node.id], byEntity[entity] = entity, node.id end
    if mat.bound then mat.bound(node, entity) end
    syncPrompts(node, entity ~= 0 and entity or nil)
end

local function armTimeout(node)
    SetTimeout(BIND_TIMEOUT_MS, function()
        local w = waiting[node.id]
        if not w or w.node ~= node then return end
        waiting[node.id], nWaiting = nil, nWaiting - 1
        Log.warn('scene: %s did not bind node %d within %d ms', tostring(made[node.id] and made[node.id].target),
            node.id, BIND_TIMEOUT_MS)
        lateBind(node, 0)
    end)
end

local BRIDGE = { class = 'custom', budget = 'custom', fade = 'alpha' }

function BRIDGE.create(node)
    local k = node.kind
    local target = k and claims[k.id]
    if not target then return nil end
    local id = node.id
    forget(id)
    made[id] = { kind = k.id, target = target }
    creating, syncBind = id, nil
    TriggerEvent('core:scene:kind', 'create', k.id, id, viewOf(node), target)
    local b = syncBind
    creating, syncBind = nil, nil
    if b ~= nil then                       -- answered inside the event (a handler that did not yield)
        syncPrompts(node, b ~= 0 and b or nil)
        return b ~= 0 and b or true
    end
    waiting[id], nWaiting = { node = node, at = GetGameTimer() }, nWaiting + 1
    if mat.PENDING ~= nil then return mat.PENDING end   -- STAGED until C.mat.bound; the materialiser times it out
    armTimeout(node)                       -- (a materialiser without late binds: the bridge gives up itself)
    return true
end

function BRIDGE.update(node, _, what, data)
    local rec = made[node.id]
    if not rec or what == 'wanted' or what == 'dr' then return end
    TriggerEvent('core:scene:kind', 'update', rec.kind, node.id, viewOf(node, what, data), rec.target)
    if what == 'interact' or what == 'move' then syncPrompts(node, Scene.handleOf(node.id)) end
end

function BRIDGE.destroy(node)
    local rec = made[node.id]
    local K = C.kinds
    if K and K.clearInteract then K.clearInteract(node.id) end
    forget(node.id)
    if rec then TriggerEvent('core:scene:kind', 'destroy', rec.kind, node.id, viewOf(node), rec.target) end
end

function BRIDGE.event(node, _, name, params, age)
    local rec = made[node.id]
    if not rec then return end
    local view = viewOf(node)
    view.event = { name = name, params = params, age = age }
    TriggerEvent('core:scene:kind', 'event', rec.kind, node.id, view, rec.target)
end

mat.registerKind('custom', BRIDGE)

local refusedWarned = {}                  -- kind .. reason -> true: a refused bind is logged once per kind

--- An entity core must never fade, move, attach to or delete (RV2 F8): a player's ped, a networked entity (this is
--- a local-copy system; networked copies are promotion's, §55.15), one the runtime already owns or has bound to
--- another node. -> the reason, or nil when the entity is the plugin's own local one.
local function foreign(entity)
    if mat.idOf(entity) ~= nil or byEntity[entity] ~= nil then return 'owned' end
    if NetworkGetEntityIsNetworked(entity) then return 'networked' end
    if GetEntityType(entity) == 1 and IsPedAPlayer(entity) then return 'player' end
    return nil
end

--- The plugin's answer to a create: the entity its handler returned (0 = none). false = not wanted any more
--- (destroyed or timed out meanwhile): the plugin deletes its entity itself. false, 'refused' = an entity core
--- will not take (foreign above): the node counts as created without one and the plugin keeps what it returned.
function Scene.bind(id, entity)
    id, entity = int(id), int(entity) or 0
    local rec = id and made[id]
    if not rec or rec.target ~= Registry.getCaller() then return false end
    if entity < 0 or (entity ~= 0 and not DoesEntityExist(entity)) then entity = 0 end
    local why = entity ~= 0 and foreign(entity) or nil
    if why then
        local key = rec.kind .. '|' .. why
        if not refusedWarned[key] then
            refusedWarned[key] = true
            Log.warn('scene: %s bound a %s entity to a node of %s: ignored (core never deletes or moves it)',
                rec.target, why, rec.kind)
        end
        entity = 0
    end
    if creating == id then
        syncBind = entity
    else
        local w = waiting[id]
        if not w then return false end
        waiting[id], nWaiting = nil, nWaiting - 1
        lateBind(w.node, entity)
    end
    if why then return false, 'refused' end
    return true
end

--------------------------------------------------------------------------------
-- stats, /scene and /scene debug
--------------------------------------------------------------------------------

--- The materialiser's counters with the cache's (cells, cache nodes, bytes in, gaps, …) and the focus
--- reporter's (bucket, reports, resyncs, …) next to them.
function Scene.stats()
    local out = {}
    local m = mat.stats and mat.stats() or nil
    if type(m) == 'table' then
        for k, v in pairs(m) do out[k] = v end
    end
    for k, v in pairs(cache.stats()) do
        if k == 'pending' or k == 'live' or k == 'lru' then out['cells' .. k:sub(1, 1):upper() .. k:sub(2)] = v
        elseif out[k] == nil or k == 'nodes' then out[k] = v end
    end
    for k, v in pairs(focus.stats()) do out[k] = v end
    local nClaims, nListens = 0, 0
    for _ in pairs(claims) do nClaims = nClaims + 1 end
    for _, rec in pairs(listenBy) do nListens = nListens + rec.n end
    out.plugin = { claims = nClaims, waiting = nWaiting, bound = next(bridged) ~= nil, listens = nListens }
    return out
end

--- /scene is for staff and development: Config.Scene.Debug, the ACE core.admin, or staff on duty.
local function allowed()
    if cfg.Debug == true then return true end
    local ok, yes = pcall(IsAceAllowed, 'core.admin')
    if ok and yes then return true end
    local getSelf = type(Core.Admin) == 'table' and Core.Admin.getSelf or nil
    if Utils.isCallable(getSelf) then
        local ok2, s = pcall(getSelf)
        if ok2 and type(s) == 'table' and s.duty == true then return true end
    end
    return false
end

local debugOn, looping = false, false
local NEAR <const> = 32
local nearNode, nearD, nearN = {}, {}, 0         -- the nearest nodes, nearest first (refreshed at 2 Hz)
local labels, colour = {}, {}
local lines, nLines = {}, 0
local camX, camY, camZ = 0.0, 0.0, 0.0
local COLOURS <const> = { known = { 160, 160, 160 }, warm = { 240, 210, 60 }, staged = { 80, 190, 255 },
    live = { 80, 230, 110 }, retiring = { 255, 150, 40 }, failed = { 255, 60, 60 }, off = { 110, 110, 110 } }

--- Keeps the NEAR closest nodes (insertion into the sorted arrays; no allocation).
local function consider(node)
    if node.dependency then return end
    local dx, dy, dz = node.x - camX, node.y - camY, node.z - camZ
    local d2 = dx * dx + dy * dy + dz * dz
    if nearN == NEAR and d2 >= nearD[NEAR] then return end
    local i = nearN < NEAR and nearN + 1 or NEAR
    nearN = i
    while i > 1 and nearD[i - 1] > d2 do
        nearD[i], nearNode[i] = nearD[i - 1], nearNode[i - 1]
        i = i - 1
    end
    nearD[i], nearNode[i] = d2, node
end

local function refreshOverlay()
    local cam = GetFinalRenderedCamCoord()
    camX, camY, camZ = cam.x, cam.y, cam.z
    nearN = 0
    cache.forEachNode(consider)
    for i = 1, nearN do
        local node = nearNode[i]
        local st = stateOf(node)
        local k = node.kind
        labels[i] = ('%d %s %s %.0fm%s'):format(node.id, k and k.id or '?', st, sqrt(nearD[i]),
            node.gated and ' gated' or '')
        colour[i] = COLOURS[st] or COLOURS.known
    end
    local s = Scene.stats()
    lines[1] = ('scene  cells %d (pending %d, live %d, lru %d)  nodes %d  gated %d  deps %d  kinds %d'):format(
        s.cells or 0, s.cellsPending or 0, s.cellsLive or 0, s.cellsLru or 0, s.nodes or 0, s.gated or 0,
        s.deps or 0, s.kinds or 0)
    lines[2] = ('in %d B / %d payloads (%d latent)  gaps %d  resyncs %d  buffered %d  reports %d'):format(
        s.bytesIn or 0, s.payloads or 0, s.latent or 0, s.gaps or 0, s.resyncs or 0, s.buffered or 0,
        s.reports or 0)
    local by = type(s.byState) == 'table' and s.byState or {}
    lines[3] = ('states  warm %s  staged %s  live %s  retiring %s  failed %s   plugin waiting %d'):format(
        tostring(by.warm or by[1] or 0), tostring(by.staged or by[2] or 0), tostring(by.live or by[3] or 0),
        tostring(by.retiring or by[4] or 0), tostring(by.failed or by[5] or 0), s.plugin.waiting)
    nLines = 3
end

local function text(str, x, y, scale, r, g, b, centre)
    SetTextFont(0)
    SetTextScale(0.0, scale)
    SetTextColour(r, g, b, 255)
    SetTextCentre(centre)
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(str)
    EndTextCommandDisplayText(x, y, 0)
end

--- The overlay loop: exists only while /scene debug is on; per frame it only draws prepared strings.
local function overlayLoop()
    local nextRefresh = 0
    while debugOn and not stopped do
        local t = GetGameTimer()
        if t >= nextRefresh then
            refreshOverlay()
            nextRefresh = t + 500
        end
        for i = 1, nLines do text(lines[i], 0.015, 0.30 + (i - 1) * 0.022, 0.28, 255, 255, 255, false) end
        for i = 1, nearN do
            local node, c = nearNode[i], colour[i]
            if not node.gone then
                DrawMarker(28, node.x, node.y, node.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.3, 0.3, 0.3,
                    c[1], c[2], c[3], 150, false, false, 2, false, nil, nil, false)
                SetDrawOrigin(node.x, node.y, node.z + 0.45, 0)
                text(labels[i], 0.0, 0.0, 0.25, c[1], c[2], c[3], true)
                ClearDrawOrigin()
            end
        end
        -- fxlint-disable-next-line P002 -- the overlay draws every frame while /scene debug is on, ends with it
        Wait(0)
    end
    nearN, nLines, looping = 0, 0, false
end

RegisterCommand('scene', function(_, args)
    if not allowed() then
        print('[core] /scene needs Config.Scene.Debug, the ACE core.admin or staff duty')
        return
    end
    if args and args[1] == 'debug' then
        debugOn = not debugOn
        print(('[core] scene debug overlay %s'):format(debugOn and 'on' or 'off'))
        if debugOn and not looping then
            looping = true
            -- fxlint-disable-next-line P004 -- one loop at most: started by the toggle only while none runs
            CreateThread(overlayLoop)
        end
        return
    end
    local s = Scene.stats()
    local keys = {}
    for k in pairs(s) do keys[#keys + 1] = k end
    table.sort(keys)
    for i = 1, #keys do
        local v = s[keys[i]]
        if type(v) == 'table' then v = json.encode(v) end
        print(('[core] scene %-16s %s'):format(keys[i], tostring(v)))
    end
end, false)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= selfName then return end
    stopped, debugOn = true, false
end)

-- fxlint-disable-next-line C003 -- clears the one-shot handoff created by client/scene_cache.lua
CoreSceneRuntime = nil
