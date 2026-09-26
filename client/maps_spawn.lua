--[[ core — client/maps_spawn.lua — the streaming engine of the map runtime (DESIGN §52.4)
     The 64 m spawn grid, the evaluation, the spawn/despawn queues, ref-counted models and the local
     objects. Internal to core's client VM: client/maps_view.lua (markers, hides, editor previews) and
     client/maps.lua (wire, regions, window, API) take it over through the one-shot global
     `CoreMapsEngine` (cleared by maps.lua), so nothing here is reachable through the `call` export.

     Budget: a bare 500 ms sleep while nothing is loaded; still = one camera read per 500 ms; an
     evaluation (camera moved >= 4 m, or content changed) visits only the cells within MaxSpawnRadius +
     15 m, skips cells wholly out of range or wholly in range and resolved, allocates nothing and queues
     nearest-first through 16 m rings; Wait(0) only while a spawn or despawn queue is non-empty.

     Natives (fxref 2026-09-26, apiset client; BOOL answers read by truthiness, DESIGN §30.4):
       GetFinalRenderedCamCoord() -> vector3, GetGameTimer(),
       CreateObjectNoOffset(modelHash, x, y, z, isNetwork, bScriptHostObj, dynamic),
       SetEntityRotation(entity, pitch, roll, yaw, rotationOrder, p5), FreezeEntityPosition(entity, toggle),
       SetEntityCollision(entity, toggle, keepPhysics), SetEntityLodDist(entity, value),
       SetEntityInvincible(entity, toggle, dontResetOnCleanup), SetDisableFragDamage(object, toggle),
       SetEntityCoordsNoOffset(entity, x, y, z, xAxis, yAxis, zAxis), DoesEntityExist(entity),
       DeleteEntity(entity), RequestModel(model), HasModelLoaded(model), SetModelAsNoLongerNeeded(model),
       IsModelInCdimage(model), IsModelValid(model), IsModelAVehicle(model), IsModelAPed(model).
]]

local floor, sqrt, abs = math.floor, math.sqrt, math.abs

local cfg = (type(Config) == 'table' and type(Config.Maps) == 'table') and Config.Maps or {}
local function setting(value, default, low, high)
    value = tonumber(value) or default
    if value ~= value or value < low then return low end
    return value > high and high or value
end

local MAX_R <const> = setting(cfg.MaxSpawnRadius, 400, 30, 2000)
local SPAWN_PER_FRAME <const> = floor(setting(cfg.SpawnPerFrame, 8, 1, 64))
local DESPAWN_PER_FRAME <const> = floor(setting(cfg.DespawnPerFrame, 32, 1, 256))
local MAX_OBJECTS <const> = floor(setting(cfg.MaxLocalObjects, 1500, 1, 10000))
local MAX_MARKERS <const> = floor(setting(cfg.MaxMarkers, 64, 0, 512))

local CELL <const> = 64               -- spawn grid cell (m)
local MIN_R <const> = 30              -- smallest spawn radius, whatever the lod says
local OUT <const> = 15                -- despawn hysteresis (m)
local RING <const> = 16               -- nearest-first ring width (m)
local NRINGS <const> = floor(MAX_R / RING) + 1
local LIMIT <const> = MAX_R + OUT     -- nothing beyond this is ever spawned
local LIMIT2 <const> = LIMIT * LIMIT
local EVAL_MOVE2 <const> = 16         -- re-evaluate after 4 m of camera travel
local MOVING2 <const> = 0.25          -- 0.5 m between checks = moving
local CHECK_MOVING_MS <const>, CHECK_STILL_MS <const> = 100, 500   -- camera checks: moving / still
local LOADING_POLL_MS <const> = 50    -- only models streaming in: poll at 20 Hz, no frame spin
local VISITS_PER_FRAME <const> = 64   -- queue entries looked at per frame (created or not)
local MODEL_TIMEOUT_MS <const>, MODEL_RELEASE_MS <const> = 10000, 30000
local RELEASE_SCAN_MS <const>, CREATE_BACKOFF_MS <const> = 1000, 1000
local EDITOR2 <const> = 150.0 * 150.0 -- editor previews within 150 m

-- element states (live elements are counted per state)
local IDLE <const>, WAITING <const>, SPAWNED <const>, FAILED <const> = 0, 1, 2, 3
-- categories: what the runtime does with an element
local PROP <const>, MARKER <const>, DATA <const> = 1, 2, 4
-- tuple flags (§52.4a)
local F_COLLISION <const>, F_FROZEN <const>, F_UNBREAKABLE <const> = 1, 2, 4
local F_EDITOR_ONLY <const> = 8 | 16  -- editor-only helper, data kind: never spawned by the runtime
-- model entry states
local M_LOADING <const>, M_LOADED <const>, M_FAILED <const>, M_RELEASED <const> = 1, 2, 3, 4

local E = {}

local grid = {}                -- cellKey -> cell
local byUid = {}               -- uid -> the live element of that uid (the latest put)
local kept = {}                -- uid -> { [element] = true }: removed or superseded copies a holder keeps
local heldUids = {}            -- uid -> true while held (client/maps.lua owns the holders)
local byHandle = {}            -- entity -> element or shell
local spawned, nSpawned = {}, 0            -- every local entity we own (elements and shells), x.si
local counts = { [IDLE] = 0, [WAITING] = 0, [SPAWNED] = 0, [FAILED] = 0 }
local nElements = 0
local spawnQ, sqHead, sqN = {}, 1, 0       -- rebuilt by every evaluation, nearest first
local readyQ, rqHead, rqN = {}, 1, 0       -- waiters whose model just loaded
local despawnQ, dqHead, dqN = {}, 1, 0
local models, nModels = {}, 0              -- hash -> model entry
local loading, nLoading, nReleasing = {}, 0, 0
local rings, ringN = {}, {}
for i = 1, NRINGS do rings[i], ringN[i] = {}, 0 end
local markers, previews = {}, {}           -- gathered per evaluation, drawn by client/maps_view.lua
local view = { nm = 0, np = 0, cx = 0.0, cy = 0.0, cz = 0.0 }   -- counts + evaluation camera (draw loop)
local camX, camY, camZ                     -- the camera of the last evaluation
local evalId, qgen, nCapped, pvGen = 0, 0, 0, 0
local dirty = false             -- content changed since the last evaluation
local editorOn = false
local buildPreview, startDraw, markerFields  -- installed by client/maps_view.lua (E.setView)
local stopped = false
local createPauseUntil = 0
local stat = { evaluations = 0, created = 0, deleted = 0, lastEvalCells = 0, lastEvalElements = 0 }

local now = GetGameTimer

local function logWarn(fmt, ...)
    local log = Core.Log
    if log and log.warn then log.warn(fmt, ...) else print(('[core] maps: ' .. fmt):format(...)) end
end

local function cellKey(gx, gy) return (gx + 32768) * 65536 + (gy + 32768) end

-- Elements carry a checked tuple (§52.4a, read by client/maps.lua) plus derived hot-path fields.
local function category(kind, flags)   -- 1 prop, 2 marker, else data (hides are client/maps_view.lua's)
    return (flags & F_EDITOR_ONLY ~= 0 or kind >= 3) and DATA or kind
end

--- Shallow equality of two `extra` tables, one nested level (sizes, field bags).
local function sameExtra(a, b, depth)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        local w = b[k]
        if v ~= w and not ((depth or 0) < 1 and type(v) == 'table' and sameExtra(v, w, 1)) then return false end
    end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

--- Copies the tuple's fields onto the element and derives what the hot paths read.
local function assign(e, hash, x, y, z, rx, ry, rz, flags, lod, extra)
    e.hash, e.x, e.y, e.z, e.rx, e.ry, e.rz = hash, x, y, z, rx, ry, rz
    e.flags, e.lod, e.extra = flags, lod, extra
    local r = lod < MIN_R and MIN_R or (lod > MAX_R and MAX_R or lod)
    e.r, e.r2, e.ro2 = r, r * r, (r + OUT) * (r + OUT)
    e.pvg = -1   -- preview rebuilt on the next gather
    if e.cat == MARKER then markerFields(e, extra) end
end

--------------------------------------------------------------------------------
-- The spawn grid (64 m cells; props, markers and data kept apart per cell)
--------------------------------------------------------------------------------

local function isDone(st) return st == SPAWNED or st == FAILED end
--- State transition with the per-state counts and the per-cell bookkeeping the evaluation skips by.
local function setSt(e, st)
    local was = e.st
    if was == st then return end
    e.st = st
    if e.alive then counts[was], counts[st] = counts[was] - 1, counts[st] + 1 end
    local c = e.cell
    if c then
        if was == SPAWNED then c.nSp = c.nSp - 1 elseif st == SPAWNED then c.nSp = c.nSp + 1 end
        local wd, nd = isDone(was), isDone(st)
        if wd ~= nd then c.nDone = c.nDone + (nd and 1 or -1) end
    end
end

local function newCell(key, gx, gy)
    local c = {
        key = key, x0 = gx * CELL, y0 = gy * CELL, seen = 0,
        p = {}, np = 0, m = {}, nm = 0, d = {}, nd = 0, nSp = 0, nDone = 0,
        minR = MAX_R, maxR = 0, minZ = 1e9, maxZ = -1e9,   -- conservative bounds (grow only)
    }
    grid[key] = c
    return c
end

local function index(e)
    local cat = e.cat
    local gx, gy = floor(e.x / CELL), floor(e.y / CELL)
    local key = cellKey(gx, gy)
    local c = grid[key] or newCell(key, gx, gy)
    e.cell = c
    if cat == PROP then
        local n = c.np + 1
        c.np, c.p[n], e.ci = n, e, n
        if e.r < c.minR then c.minR = e.r end
        if e.r > c.maxR then c.maxR = e.r end
        if e.z < c.minZ then c.minZ = e.z end
        if e.z > c.maxZ then c.maxZ = e.z end
        if e.st == SPAWNED then c.nSp = c.nSp + 1 end
        if isDone(e.st) then c.nDone = c.nDone + 1 end
    elseif cat == MARKER then
        local n = c.nm + 1
        c.nm, c.m[n], e.ci = n, e, n
    else
        local n = c.nd + 1
        c.nd, c.d[n], e.ci = n, e, n
    end
end

local function unindex(e)
    local c = e.cell
    if not c then return end
    local cat, i = e.cat, e.ci
    local list, n
    if cat == PROP then
        list, n = c.p, c.np
        c.np = n - 1
        if e.st == SPAWNED then c.nSp = c.nSp - 1 end
        if isDone(e.st) then c.nDone = c.nDone - 1 end
        if n == 1 then c.minR, c.maxR, c.minZ, c.maxZ = MAX_R, 0, 1e9, -1e9 end
    elseif cat == MARKER then
        list, n = c.m, c.nm
        c.nm = n - 1
    else
        list, n = c.d, c.nd
        c.nd = n - 1
    end
    local last = list[n]
    list[i], last.ci = last, i
    list[n] = nil
    e.cell, e.ci = nil, 0
    if c.np + c.nm + c.nd == 0 then grid[c.key] = nil end
end

--------------------------------------------------------------------------------
-- Models: ref-counted (instances + waiters), requested once, polled, released 30 s after last use
--------------------------------------------------------------------------------

local function modelRef(m)
    m.refs = m.refs + 1
    if m.releaseAt then m.releaseAt, nReleasing = nil, nReleasing - 1 end
end

local function modelUnref(hash, t)
    local m = models[hash]
    if not m then return end
    m.refs = m.refs - 1
    if m.refs <= 0 then
        m.refs = 0
        if m.st ~= M_FAILED and not m.releaseAt then m.releaseAt, nReleasing = t + MODEL_RELEASE_MS, nReleasing + 1 end
    end
end

--- Marks a model failed for the session (logged once) and every element waiting on it failed.
local function failModel(m, why)
    if m.st == M_LOADING or m.st == M_LOADED then SetModelAsNoLongerNeeded(m.hash) end
    m.st = M_FAILED
    if m.releaseAt then m.releaseAt, nReleasing = nil, nReleasing - 1 end
    local waiters = m.waiters
    for i = 1, m.nw do
        local e = waiters[i]
        waiters[i] = nil
        if e.st == WAITING and e.hash == m.hash then setSt(e, FAILED) end
    end
    m.nw, m.refs = 0, 0
    logWarn('model %d (0x%08X) %s; its map elements stay unspawned this session', m.hash, m.hash & 0xFFFFFFFF, why)
end

--- The model's entry, requesting the model the first time it is needed.
local function modelFor(hash, t)
    local m = models[hash]
    if m then return m end
    m = { hash = hash, st = M_LOADING, at = t, refs = 0, waiters = {}, nw = 0, releaseAt = nil }
    models[hash], nModels = m, nModels + 1
    local bad = (not IsModelInCdimage(hash) or not IsModelValid(hash)) and 'is not in the game files'
        or ((IsModelAVehicle(hash) or IsModelAPed(hash)) and 'is a vehicle or ped model, not an object')
    if bad then   -- checked once per model (the entry is cached)
        m.st = M_FAILED   -- never requested, nothing to release
        failModel(m, bad)
        return m
    end
    RequestModel(hash)
    if HasModelLoaded(hash) then m.st = M_LOADED else nLoading = nLoading + 1; loading[nLoading] = m end
    return m
end

--- Polls the models that are streaming in; loaded ones hand their waiters to the ready queue.
local function pollModels(t)
    local i = 1
    while i <= nLoading do
        local m, finished = loading[i], true
        if m.st ~= M_LOADING then   -- released or failed meanwhile: dropped from the list below
        elseif HasModelLoaded(m.hash) then
            m.st = M_LOADED
            local waiters = m.waiters
            for w = 1, m.nw do
                local e = waiters[w]
                waiters[w] = nil
                if e.st == WAITING and e.alive and e.hash == m.hash then
                    rqN = rqN + 1
                    readyQ[rqN] = e
                end
            end
            m.nw = 0
        elseif t - m.at >= MODEL_TIMEOUT_MS then
            failModel(m, 'did not load within 10 s')
        else
            finished = false
        end
        if finished then
            loading[i] = loading[nLoading]
            loading[nLoading] = nil
            nLoading = nLoading - 1
        else
            i = i + 1
        end
    end
end

--- SetModelAsNoLongerNeeded for every model nobody used for 30 s.
local function releaseModels(t)
    for hash, m in pairs(models) do
        if m.releaseAt and t >= m.releaseAt then
            m.releaseAt, nReleasing = nil, nReleasing - 1
            if m.refs == 0 then
                SetModelAsNoLongerNeeded(hash)
                m.st = M_RELEASED   -- the loading list drops it on its next poll
                models[hash], nModels = nil, nModels - 1
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Objects
--------------------------------------------------------------------------------

local function spawnedAdd(x)
    nSpawned = nSpawned + 1
    spawned[nSpawned], x.si = x, nSpawned
end

local function spawnedRemove(x)
    local i = x.si
    if not i or i == 0 then return end
    local last = spawned[nSpawned]
    spawned[i], last.si = last, i
    spawned[nSpawned] = nil
    nSpawned = nSpawned - 1
    x.si = 0
end

--- Positions a spawned entity on the element's transform (a move in place, no re-create).
local function place(e)
    local h = e.handle
    SetEntityCoordsNoOffset(h, e.x, e.y, e.z, false, false, false)
    SetEntityRotation(h, e.rx, e.ry, e.rz, 2, false)
    SetEntityLodDist(h, e.lod)
    e.moved = false
end

--- Creates the local object; false when the game refused (object pool full).
local function createObject(e)
    local h = CreateObjectNoOffset(e.hash, e.x, e.y, e.z, false, false, false)
    if not h or h == 0 then return false end
    SetEntityRotation(h, e.rx, e.ry, e.rz, 2, false)
    local f = e.flags
    if f & F_FROZEN ~= 0 then FreezeEntityPosition(h, true) end
    if f & F_COLLISION == 0 then SetEntityCollision(h, false, false) end
    if f & F_UNBREAKABLE ~= 0 then
        SetEntityInvincible(h, true, false)
        SetDisableFragDamage(h, true)
    end
    SetEntityLodDist(h, e.lod)
    e.handle, e.mh, e.moved, e.recreate = h, e.hash, false, false
    byHandle[h] = e
    spawnedAdd(e)
    setSt(e, SPAWNED)
    stat.created = stat.created + 1
    return true
end

--- Deletes an entity now (element or shell) and gives its model reference back.
local function deleteNow(x, t)
    local h = x.handle
    if h then
        if DoesEntityExist(h) then DeleteEntity(h) end
        byHandle[h] = nil
        stat.deleted = stat.deleted + 1
    end
    spawnedRemove(x)
    x.handle = nil
    modelUnref(x.mh, t)
    if not x.shell then setSt(x, IDLE) end
end

local function pushDespawn(x)
    if x.dq then return end
    x.dq = true
    dqN = dqN + 1
    despawnQ[dqN] = x
end

--- Hands the entity to a shell that the despawn queue deletes; the element goes back to IDLE.
local function detach(e)
    local h = e.handle
    local shell = { shell = true, handle = h, mh = e.mh, si = e.si, alive = false, dq = false }
    spawned[e.si], byHandle[h] = shell, shell
    e.handle, e.si = nil, 0
    setSt(e, IDLE)
    pushDespawn(shell)
end

--- Hands the object of `from` (same model and flags) to `to`, a newer copy of the same uid: no blink.
local function transfer(from, to)
    local h = from.handle
    to.handle, to.mh, to.si = h, from.mh, from.si
    spawned[from.si], byHandle[h] = to, to
    from.handle, from.si = nil, 0
    if from.alive then setSt(from, IDLE) else from.st = IDLE end
    setSt(to, SPAWNED)
    if to.held then to.moved = true else place(to) end
end

--------------------------------------------------------------------------------
-- Elements: put (create or update), remove
--------------------------------------------------------------------------------

--- A removed or superseded copy of `uid` whose object a holder keeps until release.
local function keepCopy(uid, e)
    local keep = kept[uid] or {}
    kept[uid], keep[e] = keep, true
end

--- Takes an element out of the runtime. A spawned one goes to the despawn queue as a shell, unless a
--- holder keeps it (kept until release). The caller clears region.elems.
local function removeElement(e, t)
    if not e.alive then return end
    unindex(e)
    if e.st == WAITING then
        modelUnref(e.hash, t)
        setSt(e, IDLE)
    end
    if e.handle and not e.held then detach(e) end
    counts[e.st] = counts[e.st] - 1
    nElements = nElements - 1
    e.alive = false
    local uid = e.uid
    if byUid[uid] == e then byUid[uid] = nil end
    if e.handle then keepCopy(uid, e) end   -- held: the entity stays until release
    dirty = true
end

--- A changed tuple for an existing element: identical -> nothing; same model -> moved in place (or
--- remembered while held); other model or flags -> re-created through the queues.
local function update(e, hash, x, y, z, rx, ry, rz, flags, lod, extra, t)
    if e.hash == hash and e.x == x and e.y == y and e.z == z and e.rx == rx and e.ry == ry and e.rz == rz
        and e.flags == flags and e.lod == lod and sameExtra(e.extra, extra) then
        return
    end
    local cat = e.cat
    local sameModel = e.hash == hash and e.flags == flags
    local c = e.cell
    local recell = not c or floor(x / CELL) * CELL ~= c.x0 or floor(y / CELL) * CELL ~= c.y0
    if recell or cat == PROP then unindex(e) end   -- a prop re-indexes to keep its cell's bounds right
    if e.st == WAITING and not sameModel then
        modelUnref(e.hash, t)
        setSt(e, IDLE)
    end
    assign(e, hash, x, y, z, rx, ry, rz, flags, lod, extra)
    if not e.cell then index(e) end
    if e.handle then
        if not sameModel then
            if e.held then e.recreate = true else detach(e) end
        elseif e.held then
            e.moved = true
        else
            place(e)
        end
    end
    if e.st == FAILED and not sameModel then setSt(e, IDLE) end
    dirty = true
end

--- Creates or updates the element of a tuple inside `region` (its `elems` map). Returns the uid.
--- The fields come checked from client/maps.lua's tuple reader; hides never come here.
function E.put(region, uid, kind, hash, x, y, z, rx, ry, rz, flags, lod, extra)
    local cat = category(kind, flags)
    local t = now()
    local e = region.elems[uid]
    if e and e.alive then
        if e.cat == cat and e.kind == kind then
            update(e, hash, x, y, z, rx, ry, rz, flags, lod, extra, t)
            return uid
        end
        removeElement(e, t)
    end
    e = { uid = uid, kind = kind, cat = cat, rg = region, st = IDLE, alive = true, ci = 0, si = 0,
        held = heldUids[uid] == true, dq = false, capGen = -1 }
    assign(e, hash, x, y, z, rx, ry, rz, flags, lod, extra)
    region.elems[uid] = e
    counts[IDLE] = counts[IDLE] + 1
    nElements = nElements + 1
    local prev, keep = byUid[uid], kept[uid]
    byUid[uid] = e
    index(e)
    if cat == PROP then   -- an earlier copy (moved region, or kept while held) hands over its object
        local from = (prev and prev.handle and prev.mh == hash and prev.flags == flags) and prev or nil
        if keep then
            for k in pairs(keep) do
                if k.handle and k.mh == hash and k.flags == flags then from = k end
            end
            keep[from or 0] = nil
        end
        if from then transfer(from, e) end
    end
    if prev and prev.alive then
        prev.sup = true   -- the uid moved region: the old copy never spawns
        if prev.handle then
            if prev.held then keepCopy(uid, prev) else detach(prev) end
        end
    end
    if keep and next(keep) == nil and kept[uid] == keep then kept[uid] = nil end
    dirty = true
    return uid
end

--- Removes one element of `region` by uid.
function E.del(region, uid)
    local e = region.elems[uid]
    if not e then return false end
    region.elems[uid] = nil
    removeElement(e, now())
    return true
end

--- Removes every element of `region` (region evicted, emptied, or a bucket reset).
function E.clear(region)
    local t = now()
    for uid, e in pairs(region.elems) do
        region.elems[uid] = nil
        removeElement(e, t)
    end
end

--------------------------------------------------------------------------------
-- Holds (the editor drags an element: the runtime leaves its entity alone)
--------------------------------------------------------------------------------

--- The object of a uid: its live copy's, else one a holder keeps.
function E.handleOf(uid)
    local e, keep = byUid[uid], kept[uid]
    if e and e.handle then return e.handle end
    if keep then
        for k in pairs(keep) do if k.handle then return k.handle end end
    end
    return nil
end

--- Marks a uid held or released (release applies what changed meanwhile). Returns the entity or nil.
function E.setHeld(uid, on)
    local e, keep = byUid[uid], kept[uid]
    heldUids[uid] = on or nil
    if e then e.held = on end
    if on then
        if keep then for k in pairs(keep) do k.held = true end end
        return E.handleOf(uid)
    end
    if keep then   -- copies kept for the holder go now
        kept[uid] = nil
        for k in pairs(keep) do
            k.held = false
            if k.handle then
                if k.alive then detach(k) else pushDespawn(k) end
            end
        end
    end
    if e and e.handle then
        if e.recreate then detach(e) elseif e.moved then place(e) end
    end
    dirty = true
    return e and e.handle or nil
end

function E.uidOf(entity)
    local x = byHandle[entity]
    if x and not x.shell then return x.uid end
    return nil
end

--------------------------------------------------------------------------------
-- Evaluation (camera moved >= 4 m, or content changed): no allocation, cells within reach only
--------------------------------------------------------------------------------

local function evaluate(cx, cy, cz, t)
    evalId, qgen = evalId + 1, qgen + 1
    for i = 1, NRINGS do ringN[i] = 0 end
    local nm, np, visited, looked = 0, 0, 0, 0
    local ed = editorOn and buildPreview ~= nil
    local gx0, gx1 = floor((cx - LIMIT) / CELL), floor((cx + LIMIT) / CELL)
    local gy0, gy1 = floor((cy - LIMIT) / CELL), floor((cy + LIMIT) / CELL)
    for gx = gx0, gx1 do
        local x0 = gx * CELL
        local x1 = x0 + CELL
        local ndx = cx < x0 and x0 - cx or (cx > x1 and cx - x1 or 0.0)
        local fdx = cx - x0 > x1 - cx and cx - x0 or x1 - cx
        for gy = gy0, gy1 do
            local y0 = gy * CELL
            local y1 = y0 + CELL
            local ndy = cy < y0 and y0 - cy or (cy > y1 and cy - y1 or 0.0)
            local near2 = ndx * ndx + ndy * ndy
            local c = near2 <= LIMIT2 and grid[(gx + 32768) * 65536 + (gy + 32768)]
            if c then
                c.seen = evalId
                visited = visited + 1
                for i = 1, c.nm do
                    local e = c.m[i]
                    local dx, dy, dz = e.x - cx, e.y - cy, e.z - cz
                    if nm < MAX_MARKERS and dx * dx + dy * dy + dz * dz <= e.dd2 then
                        nm = nm + 1
                        markers[nm] = e
                    end
                end
                if ed and c.nd > 0 and near2 <= EDITOR2 then
                    for i = 1, c.nd do
                        local e = c.d[i]
                        local dx, dy, dz = e.x - cx, e.y - cy, e.z - cz
                        if np < MAX_MARKERS and dx * dx + dy * dy + dz * dz <= EDITOR2 then
                            if e.pvg ~= pvGen then e.pv, e.pvg = buildPreview(e), pvGen end
                            np = np + 1
                            previews[np] = e
                        end
                    end
                end
                local n = c.np
                if n > 0 then
                    local reach = c.maxR + OUT
                    if near2 > reach * reach then
                        -- wholly out of range: only spawned objects matter
                        if c.nSp > 0 then
                            for i = 1, n do
                                local e = c.p[i]
                                if e.handle and not e.held then pushDespawn(e) end
                            end
                        end
                    else
                        local fdy = cy - y0 > y1 - cy and cy - y0 or y1 - cy
                        local dz = abs(cz - c.minZ) > abs(cz - c.maxZ) and abs(cz - c.minZ) or abs(cz - c.maxZ)
                        local minR = c.minR
                        -- wholly in range and every prop spawned or failed: nothing to do
                        if c.nDone < n or fdx * fdx + fdy * fdy + dz * dz > minR * minR then
                            local p = c.p
                            looked = looked + n
                            for i = 1, n do
                                local e = p[i]
                                local dx, dy, ez = e.x - cx, e.y - cy, e.z - cz
                                local d2 = dx * dx + dy * dy + ez * ez
                                local st = e.st
                                if st == SPAWNED then
                                    if d2 > e.ro2 and not e.held then pushDespawn(e) end
                                elseif st == IDLE then
                                    if d2 <= e.r2 and e.rg.win and not e.sup then
                                        local ring = floor(sqrt(d2) / RING) + 1
                                        if ring > NRINGS then ring = NRINGS end
                                        local k = ringN[ring] + 1
                                        ringN[ring] = k
                                        rings[ring][k] = e
                                    end
                                elseif st == WAITING and d2 > e.ro2 then
                                    modelUnref(e.hash, t)
                                    setSt(e, IDLE)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- spawned elements in cells this evaluation did not reach are beyond MaxSpawnRadius + 15 m
    for i = 1, nSpawned do
        local x = spawned[i]
        if x.alive and not x.held and x.cell and x.cell.seen ~= evalId then pushDespawn(x) end
    end
    -- nearest first; the farthest wanted beyond MaxLocalObjects stay unspawned (capped)
    local room = MAX_OBJECTS - nSpawned - counts[WAITING]
    local n = 0
    nCapped = 0
    for ring = 1, NRINGS do
        local list = rings[ring]
        for i = 1, ringN[ring] do
            local e = list[i]
            list[i] = nil
            if n < room then
                n = n + 1
                spawnQ[n] = e
            else
                e.capGen = qgen
                nCapped = nCapped + 1
            end
        end
    end
    for i = n + 1, sqN do spawnQ[i] = nil end
    sqHead, sqN = 1, n
    for i = nm + 1, view.nm do markers[i] = nil end
    for i = np + 1, view.np do previews[i] = nil end
    view.nm, view.np, view.cx, view.cy, view.cz = nm, np, cx, cy, cz
    camX, camY, camZ = cx, cy, cz
    dirty = false
    stat.evaluations, stat.lastEvalCells, stat.lastEvalElements = stat.evaluations + 1, visited, looked
    if (nm > 0 or np > 0) and startDraw then startDraw() end
end

--------------------------------------------------------------------------------
-- One frame of work: <= SpawnPerFrame creations, <= DespawnPerFrame deletions
--------------------------------------------------------------------------------

--- Returns true while a queue still holds work for the next frame.
local function step(t)
    if nLoading > 0 then pollModels(t) end
    local created, visits = 0, 0
    local paused = t < createPauseUntil
    while not paused and created < SPAWN_PER_FRAME and visits < VISITS_PER_FRAME do
        local e
        if rqHead <= rqN then
            e = readyQ[rqHead]
            readyQ[rqHead], rqHead = nil, rqHead + 1
        elseif sqHead <= sqN then
            e = spawnQ[sqHead]
            spawnQ[sqHead], sqHead = nil, sqHead + 1
        else
            break
        end
        visits = visits + 1
        local st = e.st
        if e.alive and (st == IDLE or st == WAITING) then
            local dx, dy, dz = e.x - camX, e.y - camY, e.z - camZ
            if dx * dx + dy * dy + dz * dz > e.ro2 or not e.rg.win or e.sup then
                if st == WAITING then   -- went out of range while its model streamed in
                    modelUnref(e.hash, t)
                    setSt(e, IDLE)
                end
            else
                local m = modelFor(e.hash, t)
                local ms = m.st
                if ms == M_LOADED then
                    if st == IDLE then modelRef(m) end
                    if createObject(e) then
                        created = created + 1
                    else
                        modelUnref(e.hash, t)
                        setSt(e, IDLE)
                        createPauseUntil, paused = t + CREATE_BACKOFF_MS, true
                        dirty = true
                    end
                elseif ms == M_FAILED then
                    setSt(e, FAILED)
                elseif st == IDLE then
                    modelRef(m)
                    m.nw = m.nw + 1
                    m.waiters[m.nw] = e
                    setSt(e, WAITING)
                end
            end
        end
    end
    if rqHead > rqN then rqHead, rqN = 1, 0 end
    if sqHead > sqN then sqHead, sqN = 1, 0 end
    local deleted = 0
    while deleted < DESPAWN_PER_FRAME and dqHead <= dqN do
        local x = despawnQ[dqHead]
        despawnQ[dqHead], dqHead = nil, dqHead + 1
        x.dq = false
        if x.handle and not x.held then
            if not x.alive then
                deleteNow(x, t)
                deleted = deleted + 1
            else
                local dx, dy, dz = x.x - camX, x.y - camY, x.z - camZ
                if dx * dx + dy * dy + dz * dz > x.ro2 or x.sup then
                    deleteNow(x, t)
                    deleted = deleted + 1
                end
            end
        end
    end
    if dqHead > dqN then
        dqHead, dqN = 1, 0
        if deleted > 0 and nCapped > 0 then dirty = true end   -- room freed for capped elements
    end
    return rqHead <= rqN or (sqHead <= sqN and not paused) or dqHead <= dqN
end

--------------------------------------------------------------------------------
-- The streaming thread
--------------------------------------------------------------------------------

CreateThread(function()
    local nextCheck, nextRelease = 0, 0
    local lastX, lastY, lastZ
    local moving = false
    while not stopped do
        local t = now()
        if nElements == 0 and nSpawned == 0 and nLoading == 0 and nReleasing == 0 and dqN == 0 and not dirty then
            -- nothing loaded, nothing to clean up (the last change was evaluated): no camera read at all
            lastX, camX = nil, nil
            Wait(CHECK_STILL_MS)
        else
            if t >= nextCheck or dirty then   -- content changes are picked up on the next wake
                local cam = GetFinalRenderedCamCoord()
                local x, y, z = cam.x, cam.y, cam.z
                if lastX then
                    local dx, dy, dz = x - lastX, y - lastY, z - lastZ
                    moving = dx * dx + dy * dy + dz * dz >= MOVING2
                end
                lastX, lastY, lastZ = x, y, z
                local ex, ey, ez = x - (camX or x), y - (camY or y), z - (camZ or z)
                if dirty or not camX or ex * ex + ey * ey + ez * ez >= EVAL_MOVE2 then
                    local ok, err = pcall(evaluate, x, y, z, t)
                    if not ok then logWarn('evaluation failed: %s', tostring(err)) dirty = false end
                end
                nextCheck = t + (moving and CHECK_MOVING_MS or CHECK_STILL_MS)
                if nReleasing > 0 and t >= nextRelease then
                    releaseModels(t)
                    nextRelease = t + RELEASE_SCAN_MS
                end
            end
            local busy = false
            if camX then
                local ok, res = pcall(step, t)
                if ok then busy = res else logWarn('spawn step failed: %s', tostring(res)) end
            end
            -- a frame only while a queue holds work; models streaming in are polled at 20 Hz
            Wait((busy or dirty) and 0 or (nLoading > 0 and LOADING_POLL_MS) or (moving and CHECK_MOVING_MS or CHECK_STILL_MS))
        end
    end
end)

--------------------------------------------------------------------------------
-- Queries, editor view, shutdown
--------------------------------------------------------------------------------

--- True when every prop within `radius` of the point that a camera there would want is spawned,
--- failed, capped or held (the region half of the check is client/maps.lua's).
function E.areaReady(x, y, z, radius)
    local r2 = radius * radius
    for gx = floor((x - radius) / CELL), floor((x + radius) / CELL) do
        for gy = floor((y - radius) / CELL), floor((y + radius) / CELL) do
            local c = grid[cellKey(gx, gy)]
            if c and c.nDone < c.np then
                for i = 1, c.np do
                    local e = c.p[i]
                    local st = e.st
                    if st ~= SPAWNED and st ~= FAILED and e.capGen ~= qgen and not e.held and not e.sup then
                        local dx, dy, dz = e.x - x, e.y - y, e.z - z
                        local d2 = dx * dx + dy * dy + dz * dz
                        if d2 <= r2 and d2 <= e.r2 then return false end
                    end
                end
            end
        end
    end
    return true
end

function E.dirty() dirty = true end

--- client/maps_view.lua installs `build(e) -> preview items`, `start()` (the draw loop) and
--- `fields(e, extra)` (a marker's flattened draw fields).
function E.setView(build, start, fields)
    buildPreview, startDraw, markerFields = build, start, fields
end

--- Editor view on/off (previews of data kinds and helpers are gathered only while on).
function E.setEditor(on)
    editorOn = on == true
    if not editorOn then
        for i = 1, view.np do previews[i] = nil end
        view.np = 0
    end
    dirty = true
end

--- Drops every cached preview (the type list arrived or changed): rebuilt on the next gather.
function E.resetPreviews() pvGen, dirty = pvGen + 1, true end

function E.stats()
    local waiting = counts[WAITING]
    return { elements = nElements, spawned = counts[SPAWNED], objects = nSpawned, waiting = waiting,
        queued = (sqN - sqHead + 1) + (rqN - rqHead + 1) + waiting, despawning = dqN - dqHead + 1,
        capped = nCapped, failed = counts[FAILED], models = nModels, loadingModels = nLoading,
        markers = view.nm, previews = view.np, evaluations = stat.evaluations, created = stat.created,
        deleted = stat.deleted, lastEvalCells = stat.lastEvalCells, lastEvalElements = stat.lastEvalElements }
end

--- Core stops: every object, hide and model request goes now (no queue, no Wait).
function E.shutdown()
    stopped = true
    for i = nSpawned, 1, -1 do
        local x = spawned[i]
        local h = x.handle
        if h and DoesEntityExist(h) then DeleteEntity(h) end
        x.handle, x.si = nil, 0
        spawned[i] = nil
    end
    nSpawned = 0
    for hash, m in pairs(models) do
        if m.st == M_LOADING or m.st == M_LOADED then SetModelAsNoLongerNeeded(hash) end
        models[hash] = nil
    end
    nModels, nLoading, nReleasing = 0, 0, 0
    grid, byUid, kept, byHandle = {}, {}, {}, {}
    spawnQ, readyQ, despawnQ = {}, {}, {}
    sqHead, sqN, rqHead, rqN, dqHead, dqN = 1, 0, 1, 0, 1, 0
    for i = 1, view.nm do markers[i] = nil end
    for i = 1, view.np do previews[i] = nil end
    view.nm, view.np, nElements = 0, 0, 0
end

E.markers, E.previews, E.view = markers, previews, view
function E.isStopped() return stopped end

-- fxlint-disable-next-line C003 -- one-shot handoff to client/maps.lua, which clears it
CoreMapsEngine = E
