--[[ core — client/scene_world.lua — the built-in non-entity kinds of Core.Scene that neither draw nor fade
     (DESIGN §55.12): hide, zone, sound, group. Split out of client/scene_fx.lua (2026-09-27); it loads right
     after that file and EXTENDS the same internal table `C.fx`: C.fx.onZone(fn) lives here now, and
     C.fx.stats() / .shutdown() / .recordOf() / .handlers cover both files (scene_fx.lua keeps light, particle,
     marker, text and the per-frame draw loop).
     `create` answers `true`; every record of these kinds lives here, keyed by node id, and goes at once on
     destroy (nothing here fades: `fade = 'none'`). update() re-reads node.fields and answers false only for
     unusable fields (= the materialiser re-creates).
     - ONE 4 Hz loop exists only while a zone lives, a one-shot sound plays or a sound waits for a slot:
       containment of the player ped (Core.Geometry.contains) -> local enter/exit through C.emit(event, node)
       (client/scene.lua's Scene.on) and C.fx.onZone(fn(node, 'enter'|'exit')) — advisory, never authority;
       finished one-shot sound ids go back; waiting sounds are offered a slot again at most once a second (the
       game may hand sound ids back). A waiting hide needs no loop: only a release frees a hide slot, and every
       release hands it on at once. Every tick runs under pcall: an error is logged once (C.kinds.warnOnce) and
       each zone / one-shot is run on its own once more — the one that fails is dropped, the loop and the others
       keep going.
     - budgets this file keeps itself: sound ids ≤ Caps.sounds, and model hides ≤ Caps.hides (the game's 256
       map-change slots, R9; Core.Maps' hides are scene hide nodes since phase D, §55.21.1, so they count here);
       over budget a record WAITS and takes the next free slot.
     - zones: a sphere/box without `coords` is centred on the node (a box without `rotation` takes the node's
       yaw) and follows movers by translation; polygons are absolute. Sounds: C4 events 'play' and 'stop'.

     Natives (fxref + natives.json runtime names, 2026-09-26, apiset client; Rockstar headers for the meaning):
       CreateModelHideExcludingScriptObjects(x, y, z, radius, hash, true = survive map reload),
       RemoveModelHide(x, y, z, radius, hash, false = not lazy),
       GetSoundId(), PlaySoundFromCoord(id, name, x, y, z, set, isNetwork, networkRange, isExteriorLoc),
       PlaySoundFromEntity(id, name, entity, set, isNetwork, networkRange), HasSoundFinished(id), StopSound(id),
       ReleaseSoundId(id), GetEntityCoords(entity, alive), PlayerPedId(), GetGameTimer(), GetCurrentResourceName().
]]

local C = CoreSceneRuntime
assert(C and C.mat and C.kinds and C.fx, 'client/scene_world.lua needs client/scene_fx.lua first')

local K, FX = C.kinds, C.fx
local Geometry = Core.Geometry
local sqrt = math.sqrt
local num, hashOf, pose = K.num, K.hashOf, K.pose   -- the readers scene_kinds uses

local cfg = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
local caps = type(cfg.Caps) == 'table' and cfg.Caps or {}

local CAP_SOUNDS <const> = tonumber(caps.sounds) or 24
local CAP_HIDES <const> = tonumber(caps.hides) or 200
local ZONE_MS <const> = 250            -- 4 Hz containment
local RETRY_MS <const> = 1000          -- waiting sounds ask for a slot again at most this often

local R = {}                  -- node id -> record (hide, zone, sound)
local FINAL = {}              -- kind -> fn(rec): what finalising a record of that kind releases
local zones, nZones = {}, 0   -- zone records (rec.zi = index)
local nOneShot = 0            -- one-shot sounds playing (the 4 Hz loop releases them when finished)
local zoneListeners = {}
local zoning, stopped = false, false
local EMPTY <const> = {}
local fwd = {}                -- defined further down: ensureZoning()

--------------------------------------------------------------------------------
-- records: one per node id, finalised at once
--------------------------------------------------------------------------------

local function finalize(rec)
    local fin = FINAL[rec.kind]
    if fin then fin(rec) end
    if R[rec.id] == rec then R[rec.id] = nil end
    rec.gone = true
end

--- The node a record belongs to right now (the cache may have replaced the table since).
local function nodeOf(rec)
    local cache = C.cache
    local node = cache and cache.node and cache.node(rec.id) or nil
    return node or rec.node
end

local function setPose(rec, x, y, z, rx, ry, rz)
    rec.x, rec.y, rec.z, rec.rx, rec.ry, rec.rz = x, y, z, rx, ry, rz
end

local function newRecord(node, kind, ctx)
    local rec = { id = node.id, kind = kind, node = node }
    setPose(rec, pose(node, ctx))
    R[node.id] = rec
    return rec
end

local function live(node)
    local rec = R[node.id]
    if not rec then return nil end
    rec.node = node
    return rec
end

--------------------------------------------------------------------------------
-- hide, zone and sound share: a capped slot pool with a FIFO of waiters, one create and one destroy path
--------------------------------------------------------------------------------

local function unqueue(q, rec)
    for i = 1, #q do
        if q[i] == rec then return table.remove(q, i) end
    end
end

--- Room in `pool`: its slots in use under the cap.
local function room(pool)
    return pool.used < pool.cap
end

--- A slot of `pool` came free: the oldest waiter takes it (`start` applies it, or queues it again).
local function poolFreed(pool, start)
    local q = pool.wait
    while #q > 0 and room(pool) and not stopped do
        local w = table.remove(q, 1)
        if w.waiting and not w.gone then
            w.waiting = false
            start(w)
            if w.waiting then return end   -- the game had no slot either
        end
    end
end

--- Over budget: the record waits and every release hands its slot on at once; a pool the game can refuse
--- (`retry`: sound ids) also has the world tick offer the slot again at most once a second.
local function poolWait(pool, rec)
    rec.waiting = true
    pool.wait[#pool.wait + 1] = rec
    if pool.retry then fwd.ensureZoning() end
end

--- create(): a fresh record (a stale one is finalised first), fields, start; nil when the fields are unusable.
local function createPlain(node, ctx, kind, fieldsFn, startFn)
    local old = R[node.id]
    if old then finalize(old) end
    local rec = newRecord(node, kind, ctx)
    if not fieldsFn(rec, node.fields or EMPTY) then
        R[node.id] = nil
        return nil
    end
    startFn(rec)
    K.syncInteract(node, nil, rec.x, rec.y, rec.z)
    return true
end

local function destroyPlain(node)
    K.clearInteract(node.id)
    local rec = R[node.id]
    if rec then finalize(rec) end
end

--------------------------------------------------------------------------------
-- hide (world model hides; ≤ Caps.hides applied, the rest wait for a slot)
--------------------------------------------------------------------------------

-- The game's map-change slots (256, R9) are ONE budget for core: Caps.hides covers every scene hide — Core.Maps'
-- hides included (scene nodes since phase D) — and the rest is left to other resources.
local hides = { used = 0, cap = CAP_HIDES, wait = {} }

local function hideOn(rec)
    if not room(hides) then return poolWait(hides, rec) end
    CreateModelHideExcludingScriptObjects(rec.x, rec.y, rec.z, rec.radius, rec.hash, true)
    rec.on, hides.used = true, hides.used + 1
end

local function hideOff(rec)
    if rec.on then
        RemoveModelHide(rec.x, rec.y, rec.z, rec.radius, rec.hash, false)
        rec.on, hides.used = false, hides.used - 1
        poolFreed(hides, hideOn)
    elseif rec.waiting then
        rec.waiting = false
        unqueue(hides.wait, rec)
    end
end

local function hideFields(rec, f)
    rec.hash, rec.radius = hashOf(f.model), num(f.radius, 1.0, 0.5, 50.0)
    return rec.hash ~= nil and rec.hash ~= 0
end

local HIDE = { class = 'fx', budget = 'hides', fade = 'none' }

function HIDE.radii(node)   -- no visible range | radius + 150 | + 50 (§55.11)
    local rin = num((node.fields or EMPTY).radius, 1.0, 0.5, 50.0) + 150
    return 0, rin, rin + 50
end

function HIDE.create(node, ctx) return createPlain(node, ctx, 'hide', hideFields, hideOn) end

--- A changed model, radius or position swaps the hide in place (the slot is kept).
function HIDE.update(node, _, what)
    local rec = live(node)
    if not rec then return false end
    local hash, radius, x, y, z = rec.hash, rec.radius, rec.x, rec.y, rec.z
    if not hideFields(rec, node.fields or EMPTY) then return false end
    if what == 'move' then setPose(rec, pose(node, nil)) end
    if rec.on and (hash ~= rec.hash or radius ~= rec.radius or x ~= rec.x or y ~= rec.y or z ~= rec.z) then
        RemoveModelHide(x, y, z, radius, hash, false)
        CreateModelHideExcludingScriptObjects(rec.x, rec.y, rec.z, rec.radius, rec.hash, true)
    end
    K.syncInteract(node, nil, rec.x, rec.y, rec.z)
    return true
end

HIDE.destroy, FINAL.hide = destroyPlain, hideOff

--------------------------------------------------------------------------------
-- zone (containment of the player ped at 4 Hz -> local enter / exit; advisory, never authority)
--------------------------------------------------------------------------------

--- The node's Core.Geometry shape, normalised: a sphere/box without coords is centred on the node pose,
--- a box without rotation takes the node's yaw. nil when the definition is unusable.
local function zoneShape(def, x, y, z, rz)
    if type(def) ~= 'table' then return nil end
    local d = {}
    for k, v in pairs(def) do d[k] = v end
    if d.type ~= 'polygon' and d.type ~= 'poly' then
        if d.coords == nil then d.coords = vector3(x, y, z) end
        if d.type == 'box' and d.rotation == nil then d.rotation = rz end
    end
    return Geometry.normalize(d)
end
FX.zoneShape = zoneShape

local function zoneFields(rec, f, force)
    if force or f.shape ~= rec.def then   -- a new definition, or a new base pose ('move')
        local shape = zoneShape(f.shape, rec.x, rec.y, rec.z, rec.rz)
        if not shape then return false end
        rec.shape, rec.def = shape, f.shape
        rec.bx, rec.by, rec.bz, rec.tx, rec.ty, rec.tz = rec.x, rec.y, rec.z, 0.0, 0.0, 0.0
    end
    rec.events = f.events ~= false
    return true
end

local function zoneAdd(rec)
    nZones = nZones + 1
    zones[nZones], rec.zi, rec.inside = rec, nZones, false
    fwd.ensureZoning()
end

--- enter / exit: the public listeners through C.emit (client/scene.lua: Scene.on('enter' | 'exit')), then any
--- core-internal C.fx.onZone hook.
local function fireZone(rec, event)
    local node = nodeOf(rec)
    local emit = C.emit
    if emit then
        local ok, err = pcall(emit, event, node)
        if not ok then Core.Log.error('scene zone %s failed: %s', event, tostring(err)) end
    end
    for i = 1, #zoneListeners do
        local ok, err = pcall(zoneListeners[i], node, event)
        if not ok then Core.Log.error('scene zone listener failed: %s', tostring(err)) end
    end
end

local ZONE = { class = 'data', fade = 'none' }

function ZONE.radii(node)   -- bounding radius (from the node) + 20 | + 20 (§55.11)
    local x, y, z, _, _, rz = pose(node, nil)
    local shape = zoneShape((node.fields or EMPTY).shape, x, y, z, rz)
    if not shape then return 0, 0, 0 end
    local c = shape.coords
    local dx, dy, dz = c.x - x, c.y - y, c.z - z
    local rin = sqrt(dx * dx + dy * dy + dz * dz) + (tonumber(shape.radius) or 0) + 20
    return 0, rin, rin + 20
end

function ZONE.create(node, ctx) return createPlain(node, ctx, 'zone', zoneFields, zoneAdd) end

function ZONE.update(node, _, what)
    local rec = live(node)
    if not rec then return false end
    if what == 'move' then setPose(rec, pose(node, nil)) end
    if not zoneFields(rec, node.fields or EMPTY, what == 'move') then return false end
    K.syncInteract(node, nil, rec.x, rec.y, rec.z)
    return true
end

--- Movers: the shape follows by translation.
function ZONE.place(node, _, x, y, z)
    local rec = R[node.id]
    if rec then rec.tx, rec.ty, rec.tz = x - rec.bx, y - rec.by, z - rec.bz end
end

ZONE.destroy = destroyPlain

function FINAL.zone(rec)
    local i = rec.zi
    if i then
        local last = zones[nZones]
        zones[i], last.zi = last, i
        zones[nZones], rec.zi = nil, nil
        nZones = nZones - 1
    end
    if rec.inside then   -- a zone that goes while the player is inside says so (not while core stops)
        rec.inside = false
        if rec.events and not stopped then fireZone(rec, 'exit') end
    end
end

--------------------------------------------------------------------------------
-- sound (GTA sounds by name/set; ids ≤ Caps.sounds, the rest wait; a one-shot's id goes back when it ends)
--------------------------------------------------------------------------------

local sounds = { used = 0, cap = CAP_SOUNDS, wait = {}, retry = true }
local oneShots = {}   -- playing one-shot records (rec.oi = index), released by the 4 Hz loop when finished

local function soundStart(rec)
    if rec.sid or rec.waiting then return end
    local sid = sounds.used < sounds.cap and GetSoundId() or -1
    if not sid or sid < 0 then return poolWait(sounds, rec) end
    sounds.used, rec.sid = sounds.used + 1, sid
    local anchor = K.anchorOf(rec.node)   -- children / attached nodes play from their entity
    if anchor then
        PlaySoundFromEntity(sid, rec.name, anchor, rec.set, false, 0)
    else
        PlaySoundFromCoord(sid, rec.name, rec.x, rec.y, rec.z, rec.set, false, 0, false)
    end
    if not rec.looped then
        nOneShot = nOneShot + 1
        oneShots[nOneShot], rec.oi = rec, nOneShot
        fwd.ensureZoning()
    end
end

--- Gives the id back (stopping the sound first when `stop`); the oldest waiter takes it.
local function soundRelease(rec, stop)
    local sid = rec.sid
    if not sid then return end
    if stop then StopSound(sid) end
    ReleaseSoundId(sid)
    rec.sid, sounds.used = nil, sounds.used - 1
    local i = rec.oi
    if i then
        local last = oneShots[nOneShot]
        oneShots[i], last.oi = last, i
        oneShots[nOneShot], rec.oi = nil, nil
        nOneShot = nOneShot - 1
    end
    poolFreed(sounds, soundStart)
end

local function soundStop(rec)
    if rec.sid then
        soundRelease(rec, true)
    elseif rec.waiting then
        rec.waiting = false
        unqueue(sounds.wait, rec)
    end
end

local function soundFields(rec, f)
    if type(f.name) ~= 'string' or f.name == '' then return false end
    local set = (type(f.set) == 'string' and f.set ~= '') and f.set or nil
    local looped = f.looped ~= false
    local changed = f.name ~= rec.name or set ~= rec.set or looped ~= rec.looped
    rec.name, rec.set, rec.looped, rec.range = f.name, set, looped, num(f.range, 30.0, 1.0, 500.0)
    return true, changed
end

local SOUND = { class = 'fx', budget = 'sounds', fade = 'none' }

function SOUND.radii(node)   -- range | + 20 (enters silent) | + 40 (§55.11, the audio row)
    local range = num((node.fields or EMPTY).range, 30.0, 1.0, 500.0)
    return range, range + 20, range + 40
end

function SOUND.create(node, ctx) return createPlain(node, ctx, 'sound', soundFields, soundStart) end

function SOUND.update(node, _, what)
    local rec = live(node)
    if not rec then return false end
    local ok, changed = soundFields(rec, node.fields or EMPTY)
    if not ok then return false end
    if what == 'move' or what == 'attach' then
        setPose(rec, pose(node, nil))
        changed = changed or rec.looped   -- a looped sound restarts where it is now
    end
    if changed then
        soundStop(rec)
        soundStart(rec)
    end
    K.syncInteract(node, nil, rec.x, rec.y, rec.z)
    return true
end

--- C4 events: 'play' (re)starts the sound (one-shots), 'stop' stops it.
function SOUND.event(node, _, name)
    local rec = live(node)
    if not rec then return end
    if name == 'play' or name == 'stop' then soundStop(rec) end
    if name == 'play' then soundStart(rec) end
end

SOUND.destroy, FINAL.sound = destroyPlain, soundStop

--------------------------------------------------------------------------------
-- group (nothing of its own: its children stream with it; prompts only)
--------------------------------------------------------------------------------

local GROUP = { class = 'data', fade = 'none' }

function GROUP.radii(node)   -- the server's radius covers the children
    local r = num(node.radius, 50.0, 1.0, 5000.0)
    return r, r, r + (r * 0.25 > 20 and r * 0.25 or 20)
end

function GROUP.create(node, ctx)
    local x, y, z = pose(node, ctx)
    K.syncInteract(node, nil, x, y, z)
    return true
end

function GROUP.update(node)
    local x, y, z = pose(node, nil)
    K.syncInteract(node, nil, x, y, z)
    return true
end

function GROUP.destroy(node) K.clearInteract(node.id) end

--------------------------------------------------------------------------------
-- the 4 Hz loop: zone containment, finished one-shot sounds, slots offered to waiters (<= 1/s); every tick runs
-- under pcall, a record that fails on its own is dropped, the events are fired after the pass
--------------------------------------------------------------------------------

local probe = { x = 0.0, y = 0.0, z = 0.0 }   -- reused containment point
local evRec, evName, nEv = {}, {}, 0          -- this tick's zone events, fired after the pass
local retryAt = 0

local function zoneOne(zr, px, py, pz)
    if not zr.events then return end
    probe.x, probe.y, probe.z = px - zr.tx, py - zr.ty, pz - zr.tz
    local inside = Geometry.contains(zr.shape, probe) == true
    if inside ~= zr.inside then
        zr.inside = inside
        nEv = nEv + 1
        evRec[nEv], evName[nEv] = zr, inside and 'enter' or 'exit'
    end
end

--- A finished one-shot gives its id back (soundRelease swaps the last one-shot into its slot).
local function oneShotDone(rec)
    if HasSoundFinished(rec.sid) then
        soundRelease(rec, false)
        return true
    end
    return false
end

local function tick()
    if nZones > 0 then
        local p = GetEntityCoords(PlayerPedId(), false)
        local px, py, pz = p.x, p.y, p.z
        for i = 1, nZones do zoneOne(zones[i], px, py, pz) end
    end
    local i = 1
    while i <= nOneShot do
        if not oneShotDone(oneShots[i]) then i = i + 1 end
    end
    if #sounds.wait > 0 then
        local now = GetGameTimer()
        if now >= retryAt then
            retryAt = now + RETRY_MS
            poolFreed(sounds, soundStart)
        end
    end
end

--- Takes a record out for good, by hand (lists and slot counts) when finalising it fails too.
local function drop(rec)
    if pcall(finalize, rec) then return end
    local i = rec.zi
    if i then
        local last = zones[nZones]
        zones[i], last.zi = last, i
        zones[nZones], rec.zi = nil, nil
        nZones = nZones - 1
    end
    i = rec.oi
    if i then
        local last = oneShots[nOneShot]
        oneShots[i], last.oi = last, i
        oneShots[nOneShot], rec.oi = nil, nil
        nOneShot = nOneShot - 1
    end
    if rec.sid then rec.sid, sounds.used = nil, sounds.used - 1 end   -- the id is lost, the slot is not
    if rec.on then rec.on, hides.used = false, hides.used - 1 end
    if R[rec.id] == rec then R[rec.id] = nil end
    rec.gone = true
end

--- A tick failed: every zone and one-shot once more on its own; one that fails is dropped (the error was logged
--- once), so a bad record never stops the others — nor the loop.
local function isolate()
    local p = GetEntityCoords(PlayerPedId(), false)
    local px, py, pz = p.x, p.y, p.z
    local i = 1
    while i <= nZones do
        local zr = zones[i]
        if pcall(zoneOne, zr, px, py, pz) then
            i = i + 1
        else
            drop(zr)
            if zones[i] == zr then i = i + 1 end
        end
    end
    i = 1
    while i <= nOneShot do
        local rec = oneShots[i]
        local ok, done = pcall(oneShotDone, rec)
        if not ok then
            drop(rec)
            if oneShots[i] == rec then i = i + 1 end
        elseif not done then
            i = i + 1
        end
    end
end

local function fireEvents()
    for j = 1, nEv do
        local rec, name = evRec[j], evName[j]
        evRec[j], evName[j] = nil, nil
        if not rec.gone then
            local ok, err = pcall(fireZone, rec, name)
            if not ok then K.warnOnce('scene zone event', err) end
        end
    end
    nEv = 0
end

function fwd.ensureZoning()
    if zoning or stopped then return end
    zoning = true
    CreateThread(function()
        while not stopped and nZones + nOneShot + #sounds.wait > 0 do
            Wait(ZONE_MS)
            local ok, err = pcall(tick)
            if not ok then
                K.warnOnce('world tick', err)
                local ok2, err2 = pcall(isolate)
                if not ok2 then K.warnOnce('world tick (isolation)', err2) end
            end
            fireEvents()
        end
        zoning = false
    end)
end

--------------------------------------------------------------------------------
-- registration and the C.fx extensions (onZone lives here; stats / shutdown / recordOf cover both files)
--------------------------------------------------------------------------------

local ORDER <const> = { 'hide', 'zone', 'sound', 'group' }
local HANDLERS <const> = { hide = HIDE, zone = ZONE, sound = SOUND, group = GROUP }
for i = 1, #ORDER do
    local id = ORDER[i]
    FX.handlers[id] = HANDLERS[id]
    C.mat.registerKind(id, HANDLERS[id])
end

--- Zone hook for client/scene.lua (core's VM, plain functions): fn(node, 'enter' | 'exit') from the 4 Hz loop.
function FX.onZone(fn)
    if type(fn) ~= 'function' then return false end
    zoneListeners[#zoneListeners + 1] = fn
    return true
end

local fxRecordOf, fxStats, fxShutdown = FX.recordOf, FX.stats, FX.shutdown

--- The record of node `id` in either file (tests, the debug overlay): read-only.
function FX.recordOf(id) return R[id] or fxRecordOf(id) end

--- scene_fx.lua's counters plus this file's.
function FX.stats()
    local s = fxStats()
    s.zones, s.sounds, s.soundsWaiting, s.oneShots = nZones, sounds.used, #sounds.wait, nOneShot
    s.hides, s.hidesWaiting, s.zoning = hides.used, #hides.wait, zoning
    return s
end

--- Core stops: every hide and sound goes now; nothing waits, nothing fires.
local function shutdown()
    stopped = true
    for _, q in ipairs({ hides.wait, sounds.wait }) do
        for i = #q, 1, -1 do q[i].waiting, q[i] = false, nil end
    end
    for _, rec in pairs(R) do finalize(rec) end
end

--- Both files at once (each file's stop handler runs its own half).
function FX.shutdown()
    shutdown()
    fxShutdown()
end

local SELF <const> = GetCurrentResourceName()
AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= SELF then return end
    shutdown()
end)
