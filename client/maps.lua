--[[ core — client/maps.lua — Core.Maps on the client: a facade over Core.Scene (DESIGN §55.21.1, the §52.4 API)
     Map elements are scene nodes carrying `fields.mapEl = '<mapId>:<elementId>'` (server/maps_runtime.lua projects
     them); the materialiser streams them, client/maps_preview.lua (right before this file) draws the editor view.
     The admin editor's API stays: handleOf(uid) (local copy, else promoted clone, else a copy a holder keeps,
     else — no node carries the uid any more — the removed element's copy while it still stands), uidOf(entity)
     (also for a removed element's copy that still stands: it retires / fades out, review RV5 F3 — the editor must
     never take it for world geometry), hold / release (C.mat holds, owner-tracked 'mapHold'; a hold taken before
     the node is here applies when it arrives), setEditorView (owner-tracked 'mapEditorView'), isAreaReady /
     waitAreaReady (the scene's readiness, and not ready inside a box of GlobalState 'core:mapsPending' of this
     client's bucket: the server still projects map content there — server/maps_runtime.lua), stats. The uid index
     is fed by the one seam every wanted node passes: C.mat.add / update / remove, wrapped here (the cache looks
     them up at call time). No net event, no thread of its own; one global state-bag handler.
     Hand-off: C.mapsPending(x, y, r) -> true while such a box covers the circle (client/scene.lua may ask it).

     Natives (fxref 2026-09-27): GetGameTimer() (client), GetCurrentResourceName() (CFX shared),
     AddStateBagChangeHandler(keyFilter, bagFilter, handler) (CFX shared). Runtime helpers: Wait, AddEventHandler,
     GlobalState.
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and type(C.mapsPreview) == 'table' and type(C.mat) == 'table',
    'client/maps.lua loads right after client/maps_preview.lua (CoreSceneRuntime.mapsPreview)')
local mat, cache, focus, preview = C.mat, C.cache, C.focus, C.mapsPreview
local Registry = Core.Registry
local mtype = math.type

local AREA_RADIUS <const>, MAX_AREA <const> = 50.0, 500.0
local DEFAULT_WAIT_MS <const>, MAX_WAIT_MS <const>, WAIT_POLL_MS <const> = 5000, 60000, 50
local MAX_UID <const> = 128
local SELF <const> = GetCurrentResourceName()
local PENDING_KEY <const> = 'core:mapsPending'   -- server/maps_runtime.lua: { { bucket, x1, y1, x2, y2 }, ... }
local PENDING_MAX <const> = 64
local RETIRED_SWEEP <const> = 64                 -- retired copies kept before the first sweep of the gone ones

local Maps = {}
local nodeOf, idx, nIndexed = {}, {}, 0       -- uid -> the wanted node carrying it; node id -> uid (wanted nodes)
local holders, heldAt, heldUid = {}, {}, {}   -- uid -> { [owner] = true }; uid -> { [node id] = true }; id -> uid
local holdIds = {}                            -- registry id -> uid
local retired, retiredOf = {}, {}             -- node id -> uid: removed, its copy still stands; uid -> newest such id
local nRetired, retiredLimit = 0, RETIRED_SWEEP
local pending, nPending = {}, 0               -- flat: bucket, x1, y1, x2, y2 per box of queued server projection
local editors, nEditors = {}, 0
local stopped = false

local function readUid(uid)
    return (type(uid) == 'string' and #uid > 0 and #uid <= MAX_UID) and uid or nil
end

local function mapElOf(node)
    local f = node.fields
    return readUid(type(f) == 'table' and f.mapEl or nil)
end

local function finite(v, limit) return type(v) == 'number' and v == v and v >= -limit and v <= limit end

local function readCoords(c)
    local t = type(c)
    if t ~= 'vector3' and t ~= 'vector4' and t ~= 'table' then return nil end
    local x, y, z = c.x, c.y, c.z
    if not (finite(x, 20000) and finite(y, 20000) and finite(z, 5000)) then return nil end
    return x + 0.0, y + 0.0, z + 0.0
end

-- the uid index: every node the materialiser is told about passes C.mat.add / update / remove ------------------

--- The materialiser key of a Maps holder: a resource's Scene.hold and Maps.hold never release each other.
local function holdOwner(owner) return 'maps:' .. owner end

--- Every holder of `uid` holds node `id` too (a hold taken before the node came, or a new node of a held uid).
local function holdNode(uid, id)
    local at = heldAt[uid]
    if at[id] then return end
    at[id], heldUid[id] = true, uid
    for owner in pairs(holders[uid]) do mat.hold(id, holdOwner(owner)) end
end

local function untrack(id)
    local uid = idx[id]
    if uid == nil then return end
    idx[id] = nil
    if nodeOf[uid] == id then nodeOf[uid], nIndexed = nil, nIndexed - 1 end
end

--- A retired copy is gone (deleted, or its node came back): forgotten.
local function forget(id)
    local uid = retired[id]
    if uid == nil then return end
    retired[id], nRetired = nil, nRetired - 1
    if retiredOf[uid] == id then retiredOf[uid] = nil end
end

--- A removed map node whose entity still stands (retiring / fading out, or kept for a handover): its uid keeps
--- answering until the entity is gone. Entries of deleted entities are swept lazily (amortised O(1)).
local function retire(id, uid)
    if retired[id] == nil then nRetired = nRetired + 1 end
    retired[id], retiredOf[uid] = uid, id
    if nRetired <= retiredLimit then return end
    for rid in pairs(retired) do
        if mat.handleOf(rid) == nil then forget(rid) end
    end
    retiredLimit = math.max(RETIRED_SWEEP, nRetired * 2)
end

local function track(node)
    local id, uid = node.id, mapElOf(node)
    if retired[id] ~= nil then forget(id) end    -- wanted again (a handover's PUT, a revived record)
    if idx[id] ~= uid then untrack(id) end
    if uid == nil then return end
    idx[id] = uid
    if nodeOf[uid] ~= id then
        if nodeOf[uid] == nil then nIndexed = nIndexed + 1 end
        nodeOf[uid] = id
    end
    if holders[uid] then holdNode(uid, id) end   -- before the materialiser takes it: the record starts held
end

local baseAdd, baseUpdate, baseRemove = mat.add, mat.update, mat.remove

function mat.add(node)
    if type(node) == 'table' and node.id ~= nil then track(node) end
    return baseAdd(node)
end

function mat.update(node, what, data)
    if (what == 'fields' or what == 'kind') and type(node) == 'table' and node.id ~= nil then track(node) end
    return baseUpdate(node, what, data)
end

function mat.remove(node, how)
    local id = type(node) == 'table' and node.id or nil
    local uid = id ~= nil and idx[id] or nil
    if id ~= nil then untrack(id) end
    local r = baseRemove(node, how)
    if uid ~= nil and mat.handleOf(id) ~= nil then retire(id, uid) end
    return r
end

--- The entity of a map element: its local copy, the promoted clone standing in for it, or a copy a holder keeps
--- (the server removed or replaced the node while it was held). nil while nothing is materialised.
function Maps.handleOf(uid)
    uid = readUid(uid)
    if uid == nil then return nil end
    local id = nodeOf[uid]
    if id then
        local h = mat.handleOf(id)
        if h then return h end
        local P = C.promote
        h = P and P.cloneOf and P.cloneOf(id) or nil
        if h then return h end
    end
    local at = heldAt[uid]
    if at then
        for hid in pairs(at) do
            local h = mat.handleOf(hid)
            if h then return h end
        end
    end
    local rid = id == nil and retiredOf[uid] or nil  -- the element was removed: its copy while it still stands
    if rid then
        local h = mat.handleOf(rid)
        if h then return h end
        forget(rid)
    end
    return nil
end

--- The map element uid of an entity the runtime materialised (a local copy or a promoted clone), or nil.
function Maps.uidOf(entity)
    if mtype(entity) ~= 'integer' or entity == 0 then return nil end
    local id = mat.idOf(entity)
    if id == nil then
        local P = C.promote
        id = P and P.idOfClone and P.idOfClone(entity) or nil
    end
    if id == nil then return nil end
    local uid = idx[id] or heldUid[id]
    if uid == nil and retired[id] ~= nil then
        if mat.handleOf(id) ~= nil then return retired[id] end
        forget(id)
    end
    return uid
end

-- holds (the editor drags elements), owner-tracked ('mapHold') -------------------------------------------------

local function holdKey(owner, uid) return owner .. '|' .. uid end

--- The runtime leaves the element's entity alone (no move, re-create or delete; changes apply on release) until
--- every holder released it. Holding does not stop a missing entity from being created. -> the entity or nil.
function Maps.hold(uid)
    uid = readUid(uid)
    if uid == nil then return nil end
    local owner = Registry.getCaller()
    local set = holders[uid]
    if not set then
        set = {}
        holders[uid], heldAt[uid] = set, {}
    end
    if not set[owner] then
        set[owner] = true
        local rid = holdKey(owner, uid)
        holdIds[rid] = uid
        Registry.track('mapHold', rid, owner)
        for id in pairs(heldAt[uid]) do mat.hold(id, holdOwner(owner)) end
        local id = nodeOf[uid]
        if id then holdNode(uid, id) end
    end
    return Maps.handleOf(uid)
end

local function releaseFor(uid, owner)
    local set = holders[uid]
    if not set or not set[owner] then return false end
    set[owner] = nil
    holdIds[holdKey(owner, uid)] = nil
    local at, last = heldAt[uid], next(set) == nil
    if last then holders[uid], heldAt[uid] = nil, nil end
    for id in pairs(at) do
        if last then heldUid[id] = nil end
        mat.release(id, holdOwner(owner))    -- the last holder: what changed meanwhile applies now
    end
    return true
end

--- Gives the caller's hold back (false when it held nothing).
function Maps.release(uid)
    uid = readUid(uid)
    if uid == nil then return false end
    local owner = Registry.getCaller()
    if not releaseFor(uid, owner) then return false end
    Registry.untrack('mapHold', holdKey(owner, uid))
    return true
end

Registry.onOwnerStop('mapHold', function(rid, owner)
    local uid = holdIds[rid]
    if uid then releaseFor(uid, owner) end
end)

-- the server's queued projection (GlobalState core:mapsPending): boxes per bucket, validated, flat
local function readPending(value)
    nPending = 0
    if type(value) ~= 'table' then return end
    for i = 1, math.min(#value, PENDING_MAX) do
        local e = value[i]
        local b = type(e) == 'table' and math.tointeger(e[1]) or nil
        if b and b >= 0 and finite(e[2], 20000) and finite(e[3], 20000) and finite(e[4], 20000)
            and finite(e[5], 20000) then
            local k = nPending * 5
            pending[k + 1], pending[k + 2], pending[k + 3], pending[k + 4], pending[k + 5] = b, e[2], e[3], e[4], e[5]
            nPending = nPending + 1
        end
    end
end
readPending(GlobalState[PENDING_KEY])            -- seed: a handler never fires for a key set before this script ran
AddStateBagChangeHandler(PENDING_KEY, 'global', function(_, _, value) readPending(value) end)

--- Does a box of this client's bucket (0 until the focus reporter heard of another) touch the circle?
local function pendingAt(x, y, r)
    if nPending == 0 then return false end
    local st = focus and focus.stats and focus.stats()
    local b = st and math.tointeger(st.bucket) or 0
    for k = 0, (nPending - 1) * 5, 5 do
        if pending[k + 1] == b then
            local dx = math.max(pending[k + 2] - x, 0.0, x - pending[k + 4])
            local dy = math.max(pending[k + 3] - y, 0.0, y - pending[k + 5])
            if dx * dx + dy * dy <= r * r then return true end
        end
    end
    return false
end
C.mapsPending = pendingAt

-- area readiness: the scene's (cells current, every node a camera there would want materialised), and no map
-- projection still queued on the server around it
local function ready(x, y, z, r)
    return not pendingAt(x, y, r) and cache.areaReady(x, y, r) == true and mat.areaReady(x, y, z, r) == true
end

function Maps.isAreaReady(coords, radius)
    local x, y, z = readCoords(coords)
    if not x then return false end
    local r = tonumber(radius) or AREA_RADIUS
    if r ~= r or r < 0 then r = 0.0 elseif r > MAX_AREA then r = MAX_AREA end
    return ready(x, y, z, r)
end

--- Waits in the calling thread until the area around `coords` (50 m) is ready or `timeoutMs` passed. The focus
--- reporter reports at once; the wait itself never changes budgets (Spawn.teleport fades the screen for that).
function Maps.waitAreaReady(coords, timeoutMs)
    local x, y, z = readCoords(coords)
    if not x then return false end
    local ms = tonumber(timeoutMs) or DEFAULT_WAIT_MS
    if ms ~= ms or ms < 0 then ms = 0 elseif ms > MAX_WAIT_MS then ms = MAX_WAIT_MS end
    local deadline = GetGameTimer() + ms
    if focus and focus.reportSoon then focus.reportSoon() end
    while not stopped do
        if ready(x, y, z, AREA_RADIUS) then return true end
        if GetGameTimer() >= deadline then return false end
        Wait(WAIT_POLL_MS)
    end
    return false
end

--- Editor view for the calling resource: the map:data previews (points, zones, helpers, placeholders) within
--- 150 m, drawn while any owner has it on (client/maps_preview.lua). false for a non-boolean.
function Maps.setEditorView(on)
    if type(on) ~= 'boolean' then return false end
    local owner = Registry.getCaller()
    if on == (editors[owner] == true) then return true end
    if on then
        editors[owner], nEditors = true, nEditors + 1
        Registry.track('mapEditorView', owner, owner)
    else
        editors[owner], nEditors = nil, nEditors - 1
        Registry.untrack('mapEditorView', owner)
    end
    preview.setEditor(nEditors > 0)
    return true
end

Registry.onOwnerStop('mapEditorView', function(_, owner)
    if not editors[owner] then return end
    editors[owner], nEditors = nil, nEditors - 1
    preview.setEditor(nEditors > 0)
end)

--- A diagnostic snapshot: map elements the runtime wants (`elements`) and those with a local entity (`spawned`),
--- held uids, the scene's queue / asset / failure counters (map content is scene content), the editor view. No
--- `objects` / `hides`: the scene's caps count map content themselves.
function Maps.stats()
    local spawned, held = 0, 0
    for _, id in pairs(nodeOf) do
        if mat.handleOf(id) then spawned = spawned + 1 end
    end
    for _ in pairs(holders) do held = held + 1 end
    local s, p = mat.stats(), preview.stats()
    return { elements = nIndexed, spawned = spawned, held = held, queued = s.queued, models = s.assets,
        failed = s.failed, previews = p.previews, dataNodes = p.dataNodes, types = p.types, editorView = nEditors > 0 }
end

AddEventHandler('onClientResourceStop', function(resource)
    if resource == SELF then stopped = true end
end)

Core.Maps = Maps
