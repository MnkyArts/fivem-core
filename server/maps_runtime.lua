--[[
    core/server/maps_runtime.lua — the world side of Core.Maps (DESIGN §52.2, §52.4a). Internal: extends
    `Core.MapsRuntime` (R, created by maps_types.lua, which loads first).

      contexts         one per (map, bucket) whose content is ACTIVE: a live map's elements or a draft's
                       published snapshot in its targetBucket, a draft's working copy in its editor bucket
      representation   client-rendered kinds (prop, marker, hide, point, zone, and placeholders of undefined
                       types) become §52.4a tuples for Core.MapRegions.put/remove/clearBucket; networked
                       kinds (vehicle, ped, networked prop) become server entities, created by ONE worker
                       thread that exists only while its queue is non-empty
      in place         a changed networked element keeps its entity (and net id) when type, kind, model and
                       bucket are the same and a client owns the living entity: the config goes out as RPCs
                       + the `mapCfg` bag, the pose as `core:maps:pose` to the owning client (SET_ENTITY_COORDS
                       offsets peds and vehicles; client/maps.lua applies it with the no-offset native); ~2 s
                       later an entity still at its pre-move pose is re-created at the target. Everything else
                       is re-created as before. Handles are reused: only an entity whose `mapEl` is the uid is
                       ever deleted or treated as alive.
      paint            a vehicle without a `color` field gets a paint pair picked from its uid (stable across
                       re-creations and between the editor bucket and the target bucket)
      events           Maps.on(typeId|'*', fn) listeners get 'added'|'changed'|'removed' for active content,
                       delivered in order by one drain thread (handlers may Wait); Maps.records(typeId)

    A context holds a REFERENCE to its element table ({ [elementId] = element }); maps.lua replaces element
    tables on change (never mutates one in place), so a context always sees the current content and a diff
    only compares updatedAt. Core.MapRegions is looked up at call time (maps_regions.lua may load later in
    the manifest) and every call is pcall'ed: a failing region module never breaks an apply.

    Natives (fxref + natives_cfx.json 2026-09-26; apiset server, or client with a server RPC form — a
    context RPC reaches the entity's owner, and is queued until a client owns it — runtime-facts §7):
      CreateVehicleServerSetter(modelHash, type, x, y, z, heading) (server); CreatePed(pedType, modelHash,
      x, y, z, heading, isNetwork, bScriptHostPed) and CreateObjectNoOffset(modelHash, x, y, z, isNetwork,
      bScriptHostObj, dynamic) (entity RPCs, created on the server); SetEntityRotation(entity, pitch, roll,
      yaw, rotationOrder, bDeadCheck), FreezeEntityPosition(entity, toggle), SetVehicleNumberPlateText(vehicle,
      plateText), SetVehicleDoorsLocked(vehicle, doorLockStatus), SetVehicleColours(vehicle, colorPrimary,
      colorSecondary), SetVehicleCustomPrimaryColour / SetVehicleCustomSecondaryColour(vehicle, r, g, b),
      ClearPedTasks(ped) (context RPCs, fallible — the `mapCfg` state bag carries the config for
      client/maps.lua); SetEntityRoutingBucket(entity, bucket), GetEntityRoutingBucket(entity),
      SetEntityOrphanMode(entity, mode), DoesEntityExist(entity), DeleteEntity(entity), GetEntityCoords(entity),
      GetEntityHeading(entity), GetEntityHealth(entity) (the synced health node: 0 until a client synced it),
      NetworkGetNetworkIdFromEntity(entity), GetPedInVehicleSeat(vehicle, seatIndex) (server; 0 = empty);
      NetworkGetEntityOwner(entity) (shared: a player's net
      id, -1 while the server owns it). Entity(e).state, CreateThread, Wait, SetTimeout, GetGameTimer and
      TriggerClientEvent are runtime helpers.
]]

local R = Core.MapsRuntime
assert(R and R.types, 'server/maps_types.lua must load before server/maps_runtime.lua')

local Log = Core.Log
local Utils = Core.Utils
local Registry = Core.Registry

local types = R.types
local xyz, rgba, isFinite = R.xyz, R.rgba, R.isFinite

local LISTENER_KIND <const> = 'mapsListener'
local MAX_LISTENERS <const> = 512
local DEFAULT_LOD <const> = 150
local SPAWN_TIMEOUT_MS <const> = 5000
local SPAWN_POLL_MS <const> = 50
local PED_TYPE <const> = 4                  -- PED_TYPE_CIVMALE, as every server-created ped in core
local ORPHAN_KEEP <const> = 2               -- SetEntityOrphanMode: KeepEntity
local LOCKED <const>, UNLOCKED <const> = 2, 1   -- SetVehicleDoorsLocked
local POSE_EVENT <const> = 'core:maps:pose'
local VERIFY_MS <const> = 2000              -- an in-place move is checked against the synced pose this late
local VERIFY_DIST <const> = 0.75            -- metres, horizontal (props fall and vehicles settle in z)
local VERIFY_HEADING <const> = 20           -- degrees (vehicles and peds; a prop's rotation rides mapCfg.rot)
-- Normal GTA paint indexes { primary, secondary } for vehicles without a `color` field, picked by the uid's
-- joaat: metallic black, graphite, silver, dark silver, shadow silver, gun metal, white, frost white, red,
-- cabernet red, orange, race yellow, green, racing green, dark blue, blue, bright blue, midnight blue,
-- bronze, champagne, golden brown, purple (vehicleColors indexes 0..145).
local PAINTS <const> = { { 0, 0 }, { 1, 1 }, { 4, 4 }, { 3, 3 }, { 7, 7 }, { 10, 10 }, { 111, 111 },
    { 112, 112 }, { 27, 27 }, { 34, 34 }, { 38, 38 }, { 89, 89 }, { 53, 53 }, { 50, 50 }, { 62, 62 },
    { 64, 64 }, { 70, 70 }, { 61, 61 }, { 90, 90 }, { 93, 93 }, { 97, 97 }, { 145, 145 } }
local KIND_CODE <const> = { prop = 1, marker = 2, hide = 3, point = 4, zone = 5 }
local FLAG_COLLISION <const>, FLAG_FROZEN <const>, FLAG_UNBREAKABLE <const> = 1, 2, 4
local FLAG_EDITOR <const>, FLAG_DATA <const> = 8, 16

local hashCache = {}        -- [model] = signed joaat

local function hashOf(model)
    local h = hashCache[model]
    if not h then
        h = R.joaat(model)
        hashCache[model] = h
    end
    return h
end

local function round(v, mult)
    return math.floor(v * mult + 0.5) / mult
end

--------------------------------------------------------------------------------
-- Tuples (§52.4a) and the region module
--------------------------------------------------------------------------------

local function uidOf(mapId, elementId)
    return mapId .. ':' .. elementId
end
R.uidOf = uidOf

local regionsWarned = false

--- Core.MapRegions at call time (it may load after this file), or nil with one warning.
local function regions()
    local mr = rawget(Core, 'MapRegions')
    if mr then return mr end
    if not regionsWarned then
        regionsWarned = true
        Log.warn('maps: Core.MapRegions is not loaded; client-rendered map content is not streamed')
    end
    return nil
end

local function regionCall(name, ...)
    local mr = regions()
    local fn = mr and mr[name]
    if type(fn) ~= 'function' then return end
    local ok, err = pcall(fn, ...)
    if not ok then Log.warn('maps: MapRegions.%s failed: %s', name, tostring(err)) end
end

--- A boolean field of the element when the type declares it, else the fallback.
local function flag(el, name, fallback)
    local v = el.fields and el.fields[name]
    if type(v) == 'boolean' then return v end
    return fallback
end

--- Marker extra from the fields (core:marker names), then the type's first marker preview, then defaults.
local function markerExtra(def, el)
    local f = el.fields or {}
    local pv
    if def and def.preview then
        for i = 1, #def.preview do
            if def.preview[i].kind == 'marker' then pv = def.preview[i] break end
        end
    end
    local r, g, b, a = rgba(f.color)
    if not r and pv then r, g, b, a = rgba(pv.color) end
    if not r then r, g, b, a = 224, 163, 58, 180 end
    local sx, sy, sz = xyz(f.scale)
    if not sx and pv and type(pv.scale) == 'table' then sx, sy, sz = xyz(pv.scale) end
    if not sx and pv and type(pv.scale) == 'number' then sx, sy, sz = pv.scale, pv.scale, pv.scale end
    if not sx then sx, sy, sz = 1.0, 1.0, 1.0 end
    local mtype = math.tointeger(f.markerType) or (pv and pv.type) or 1
    local dd = isFinite(f.drawDistance) and f.drawDistance or 50
    return { type = mtype, r = r, g = g, b = b, a = a, sx = round(sx, 1000), sy = round(sy, 1000),
        sz = round(sz, 1000), dd = round(dd, 100), bob = flag(el, 'bob', false), face = flag(el, 'faceCamera', false) }
end

--- extra for the editor view of data kinds and placeholders: t = the type id, f = the values of the fields
--- a '$field' label preview shows (scalars as strings, <= 64 chars). `extra` is added to when given.
local function editorExtra(def, el, extra)
    extra = extra or {}
    extra.t = el.type
    local names = def and def.labelFields
    if names then
        local f
        for i = 1, #names do
            local v = el.fields and el.fields[names[i]]
            local kind = type(v)
            if kind == 'string' or kind == 'number' or kind == 'boolean' then
                f = f or {}
                f[names[i]] = tostring(v):sub(1, 64)
            end
        end
        extra.f = f
    end
    return extra
end

--- The §52.4a tuple of a client-rendered element; an undefined type is packed as an editor-only point.
local function tupleOf(mapId, el)
    local def = types[el.type]
    local p, r = el.pos, el.rot
    local kind = def and def.kind or 'point'
    local code = def and KIND_CODE[kind] or 4
    local hash, flags, extra = 0, 0, nil
    local lod = DEFAULT_LOD
    if not def then
        flags = FLAG_EDITOR | FLAG_DATA
        extra = editorExtra(nil, el)
    elseif kind == 'prop' then
        local model = R.modelOf(def, el)
        hash = model and hashOf(model) or 0
        flags = (flag(el, 'collision', true) and FLAG_COLLISION or 0) | (flag(el, 'frozen', true) and FLAG_FROZEN or 0)
            | (flag(el, 'unbreakable', false) and FLAG_UNBREAKABLE or 0)
        if el.info and el.info.lod then lod = el.info.lod end
    elseif kind == 'marker' then
        extra = markerExtra(def, el)
    elseif kind == 'hide' then
        local model = el.fields and el.fields.model
        hash = type(model) == 'string' and hashOf(model) or 0
        local radius = el.fields and el.fields.radius
        extra = { radius = isFinite(radius) and round(radius, 100) or 2 }
    elseif kind == 'zone' then
        flags = FLAG_DATA
        local sx, sy, sz = xyz(el.fields and el.fields.size)
        if not sx then sx, sy, sz = 4, 4, 3 end
        extra = editorExtra(def, el, { sx = round(sx, 1000), sy = round(sy, 1000), sz = round(sz, 1000) })
    else                                        -- point
        flags = FLAG_DATA
        extra = editorExtra(def, el)
    end
    return { uidOf(mapId, el.id), code, hash, round(p.x, 1000), round(p.y, 1000), round(p.z, 1000),
        round(r.x, 100), round(r.y, 100), round(r.z, 100), flags, math.tointeger(lod) or DEFAULT_LOD, extra }
end
R.tupleOf = tupleOf

--------------------------------------------------------------------------------
-- Networked elements (§52.2): server entities, one spawn worker
--------------------------------------------------------------------------------

local contexts = {}         -- [ctxKey] = ctx
local byMap = {}            -- [mapId] = { [bucket] = ctx }
local perBucket = {}        -- [bucket] = number of contexts in it (clearBucket only when alone)
-- ['<bucket>|<uid>'] = { key, ctxKey, elementId, uid, bucket, entity?, cancelled?, done? (the worker took
-- it), ready? (configured) + what the entity was made with: type, kind, model, pose, cfg, looks; in-place moves:
-- poseSeq, prevPose, anchor, verifying }
local instances = {}
local netTotal = 0          -- networked elements active in every context (desired, spawned or not)
-- [spawnHead..spawnTail] = queued instances; an explicit tail, since `#` of a queue whose consumed head is nil
-- can read 0 and put a new entry behind the worker's head (it was lost)
local spawnQueue, spawnHead, spawnTail, spawning = {}, 1, 0, false
local updateNet             -- forward: spawnOne hands an element that moved meanwhile back to it

local function instKey(bucket, uid)
    return bucket .. '|' .. uid
end

--- Is `entity` still the map entity of `uid`? Server handles are pool slots handed to the next entity once one is
--- gone (a client may delete a map entity), so the handle alone never proves it: the `mapEl` bag does.
local function ours(entity, uid)
    return entity ~= nil and entity ~= 0 and DoesEntityExist(entity) and Entity(entity).state.mapEl == uid
end

--- Deletes the instance's entity, never a foreign one that reused its handle.
local function deleteEntity(entity, uid)
    if ours(entity, uid) then DeleteEntity(entity) end
end

--- The paint pair of a vehicle without a `color` field: the same for a uid on every spawn.
local function paintOf(uid)
    local pair = PAINTS[R.joaat(uid) % #PAINTS + 1]
    return pair[1], pair[2]
end
R.paintOf = paintOf

--- Config the client applies to a map entity (RPC natives are fallible; the state bag is the source of
--- truth for client/maps.lua): peds invincible/frozen/scenario, vehicles locked, physics props rot.
local function entityConfig(def, el)
    local f = el.fields or {}
    local cfg, any = {}, false
    if def.kind == 'ped' then
        cfg.invincible, cfg.frozen = flag(el, 'invincible', false), flag(el, 'frozen', false)
        if type(f.scenario) == 'string' and f.scenario ~= '' then cfg.scenario = f.scenario end
        any = true
    elseif def.kind == 'vehicle' then
        cfg.locked = flag(el, 'locked', false)
        any = true
    elseif def.kind == 'prop' then              -- networked physics prop: the owning client re-applies it
        cfg.rot = { x = el.rot.x, y = el.rot.y, z = el.rot.z }
        any = true
    end
    return any and cfg or nil
end

local function sameCfg(a, b)
    if a == nil or b == nil then return a == b end
    if a.invincible ~= b.invincible or a.frozen ~= b.frozen or a.scenario ~= b.scenario or a.locked ~= b.locked then
        return false
    end
    local ra, rb = a.rot, b.rot
    if ra == nil or rb == nil then return ra == rb end
    return ra.x == rb.x and ra.y == rb.y and ra.z == rb.z
end

--- What only the server's RPCs set on a vehicle: { plate?, color? (0xRRGGBB) }; {} for other kinds.
local function looksOf(def, el)
    if def.kind ~= 'vehicle' then return {} end
    local f = el.fields or {}
    local cr, cg, cb = rgba(f.color)
    return { plate = type(f.plate) == 'string' and f.plate ~= '' and f.plate or nil,
        color = cr and (cr << 16 | cg << 8 | cb) or nil }
end

local function setCustomColour(entity, rgb)
    local r, g, b = (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255
    SetVehicleCustomPrimaryColour(entity, r, g, b)
    SetVehicleCustomSecondaryColour(entity, r, g, b)
end

--- { x, y, z, rx, ry, rz } of an element (floats, as the natives take them).
local function poseOf(el)
    local p, r = el.pos, el.rot
    return { p.x + 0.0, p.y + 0.0, p.z + 0.0, r.x + 0.0, r.y + 0.0, r.z + 0.0 }
end

--- Vehicles and peds are created with a heading only, so only a physics prop compares pitch and roll.
local function samePose(kind, a, b)
    if a[1] ~= b[1] or a[2] ~= b[2] or a[3] ~= b[3] or a[6] ~= b[6] then return false end
    return kind ~= 'prop' or (a[4] == b[4] and a[5] == b[5])
end

--- Creates the entity; returns the handle or 0.
local function createEntity(def, el, model)
    local hash = hashOf(model)
    local p, r = el.pos, el.rot
    if def.kind == 'vehicle' then
        local vt = el.info and el.info.vehicleType or 'automobile'
        return CreateVehicleServerSetter(hash, vt, p.x + 0.0, p.y + 0.0, p.z + 0.0, (r.z % 360) + 0.0)
    elseif def.kind == 'ped' then
        return CreatePed(PED_TYPE, hash, p.x + 0.0, p.y + 0.0, p.z + 0.0, (r.z % 360) + 0.0, true, true)
    end
    return CreateObjectNoOffset(hash, p.x + 0.0, p.y + 0.0, p.z + 0.0, true, true, true)
end

--- Everything after the entity exists: bucket first (server entities start in 0), orphan mode, state bags,
--- then the fallible cosmetic RPCs (queued by the server until a client owns the entity). Remembers the
--- config on the instance for in-place updates.
local function configureEntity(inst, def, el, entity)
    SetEntityRoutingBucket(entity, inst.bucket)
    SetEntityOrphanMode(entity, ORPHAN_KEEP)
    local state = Entity(entity).state
    state:set('mapEl', inst.uid, true)
    local cfg, looks = entityConfig(def, el), looksOf(def, el)
    if cfg then state:set('mapCfg', cfg, true) end
    local r = el.rot
    if def.kind == 'prop' and (r.x ~= 0 or r.y ~= 0 or r.z ~= 0) then
        SetEntityRotation(entity, r.x + 0.0, r.y + 0.0, r.z + 0.0, 2, false)
    elseif def.kind == 'vehicle' then
        local primary, secondary = paintOf(inst.uid)
        SetVehicleColours(entity, primary, secondary)   -- a set `color` below paints over it
        if looks.plate then SetVehicleNumberPlateText(entity, looks.plate) end
        if looks.color then setCustomColour(entity, looks.color) end
        if cfg and cfg.locked then SetVehicleDoorsLocked(entity, LOCKED) end
    elseif def.kind == 'ped' and cfg and cfg.frozen then
        FreezeEntityPosition(entity, true)
    end
    inst.cfg, inst.looks = cfg, looks
end

--- One queued instance: still wanted? create, wait for it to exist (<= 5 s), configure. It reads the
--- element when it starts, so a change while it waits in the queue costs nothing; a change while the
--- entity is being created replaces the instance (updateNet), and this one deletes its entity.
local function spawnOne(inst)
    if instances[inst.key] ~= inst or inst.cancelled or inst.entity then return end
    inst.done = true                            -- set first: every exit below is final for this instance
    local ctx = contexts[inst.ctxKey]
    local el = ctx and ctx.els[inst.elementId]
    local def = el and types[el.type]
    local model = def and R.modelOf(def, el)
    if not model or not R.isNetworked(def) then return end
    local entity = createEntity(def, el, model)
    if not entity or entity == 0 then
        Log.warn('maps: could not create %s (%s) for %s', def.kind, model, inst.uid)
        return
    end
    inst.entity = entity
    -- wait even when cancelled meanwhile: an entity can only be deleted once it exists
    local deadline = GetGameTimer() + SPAWN_TIMEOUT_MS
    while not DoesEntityExist(entity) and GetGameTimer() < deadline do
        Wait(SPAWN_POLL_MS)
    end
    if inst.cancelled or instances[inst.key] ~= inst then
        -- the handle the create native just returned (no mapEl yet): the one unchecked delete
        if DoesEntityExist(entity) then DeleteEntity(entity) end
        return
    end
    if not DoesEntityExist(entity) then
        Log.warn('maps: %s (%s) for %s did not appear within %d ms', def.kind, model, inst.uid, SPAWN_TIMEOUT_MS)
        inst.entity = nil
        return
    end
    local cur = ctx.els[inst.elementId] or el
    configureEntity(inst, def, cur, entity)
    inst.type, inst.kind, inst.model, inst.pose, inst.ready = el.type, def.kind, model, poseOf(el), true
    -- a change while it was created replaced this instance; a same-version copy placed elsewhere would not
    if cur ~= el and not samePose(def.kind, inst.pose, poseOf(cur)) then updateNet(ctx, cur) end
end

local function queueSpawn(inst)
    spawnTail = spawnTail + 1
    spawnQueue[spawnTail] = inst
    if spawning then return end
    spawning = true
    -- one worker; it ends as soon as the queue is empty
    -- fxlint-disable-next-line P004
    CreateThread(function()
        while spawnHead <= spawnTail do
            local item = spawnQueue[spawnHead]
            spawnQueue[spawnHead] = nil
            spawnHead = spawnHead + 1
            local ok, err = pcall(spawnOne, item)
            if not ok then Log.error('maps: spawning %s failed: %s', tostring(item.uid), tostring(err)) end
        end
        spawnQueue, spawnHead, spawnTail, spawning = {}, 1, 0, false
    end)
end

local function spawnFor(ctx, el)
    local uid = uidOf(ctx.mapId, el.id)
    local key = instKey(ctx.bucket, uid)
    local old = instances[key]
    if old then
        old.cancelled = true
        deleteEntity(old.entity, uid)
    end
    local inst = { key = key, ctxKey = ctx.key, elementId = el.id, uid = uid, bucket = ctx.bucket }
    instances[key] = inst
    queueSpawn(inst)
end

local function despawn(bucket, uid)
    local key = instKey(bucket, uid)
    local inst = instances[key]
    if not inst then return end
    instances[key] = nil
    inst.cancelled = true
    deleteEntity(inst.entity, uid)
end

local function near(c, p)
    local dx, dy = c.x - p[1], c.y - p[2]
    return dx * dx + dy * dy <= VERIFY_DIST * VERIFY_DIST
end

local function nearHeading(h, p)
    local d = (h - p[6]) % 360
    return math.min(d, 360 - d) <= VERIFY_HEADING
end

--- A vehicle somebody sits in is theirs to move: never re-created under them (seats -1..15).
local function occupied(entity)
    for seat = -1, 15 do
        if GetPedInVehicleSeat(entity, seat) ~= 0 then return true end
    end
    return false
end

--- ~VERIFY_MS after an in-place move: did the owning client apply it? Re-created only when the synced pose is
--- still where the entity was BEFORE the move (the pose before the last move, or before the first of a burst)
--- and not at the target — an entity that landed and then moved on (driven, kicked, bumped) is left alone, and
--- so is any vehicle with an occupant. Horizontal position, plus the heading of vehicles and peds while they
--- stand at the target position (a physics prop's rotation rides mapCfg.rot).
local function verifyPose(inst, seq)
    if instances[inst.key] ~= inst or inst.cancelled or inst.poseSeq ~= seq then return end
    inst.verifying = false
    local entity = inst.entity
    if not ours(entity, inst.uid) then return end   -- destroyed or its handle reused: Maps.respawn's job
    if inst.kind == 'vehicle' and occupied(entity) then return end
    local p, prev, anchor, c = inst.pose, inst.prevPose, inst.anchor, GetEntityCoords(entity)
    local stuck
    if near(c, p) then
        if inst.kind == 'prop' then return end
        local h = GetEntityHeading(entity)
        stuck = not nearHeading(h, p) and (nearHeading(h, prev) or nearHeading(h, anchor))
    else
        stuck = near(c, prev) or near(c, anchor)
    end
    if not stuck then return end
    local ctx = contexts[inst.ctxKey]
    local el = ctx and ctx.els[inst.elementId]
    if not el or ctx.reps[el.id] ~= 'net' then return end
    Log.debug('maps: %s did not move in place; re-created', inst.uid)
    spawnFor(ctx, el)
end

--- The transitions only a re-creation undoes: a cleared plate (the random one is gone), a cleared custom
--- colour and a ped that stops being invincible (both natives are client-only, and the client applies the
--- "on" states of mapCfg only).
local function keepable(inst, cfg, looks)
    local oc, ol = inst.cfg or {}, inst.looks or {}
    if (ol.plate and not looks.plate) or (ol.color and not looks.color) then return false end
    return not (oc.invincible and not (cfg and cfg.invincible))
end

--- Updates a spawned entity to `el` without re-creating it -> true, or false when it has to be re-created:
--- another type, kind or model, the entity gone, not ours, in another bucket, dead, owned by the server
--- (nobody near: a re-creation is exact and unseen) or a transition keepable() refuses.
local function moveInPlace(inst, def, el)
    local entity = inst.entity
    if not def or def.kind ~= inst.kind or el.type ~= inst.type or R.modelOf(def, el) ~= inst.model then
        return false
    end
    if not ours(entity, inst.uid) or GetEntityRoutingBucket(entity) ~= inst.bucket then return false end
    local state = Entity(entity).state
    local owner = NetworkGetEntityOwner(entity)
    if type(owner) ~= 'number' or owner < 1 then return false end
    if def.kind ~= 'prop' and GetEntityHealth(entity) <= 0 then return false end
    local cfg, looks = entityConfig(def, el), looksOf(def, el)
    if not keepable(inst, cfg, looks) then return false end
    local oc, ol = inst.cfg or {}, inst.looks or {}
    if def.kind == 'vehicle' then
        if looks.plate and looks.plate ~= ol.plate then SetVehicleNumberPlateText(entity, looks.plate) end
        if looks.color and looks.color ~= ol.color then setCustomColour(entity, looks.color) end
        if cfg.locked ~= oc.locked then SetVehicleDoorsLocked(entity, cfg.locked and LOCKED or UNLOCKED) end
    elseif def.kind == 'ped' then
        if cfg.frozen ~= oc.frozen then FreezeEntityPosition(entity, cfg.frozen) end
        if oc.scenario and not cfg.scenario then ClearPedTasks(entity) end
    end
    if not sameCfg(inst.cfg, cfg) then state:set('mapCfg', cfg, true) end   -- invincible / scenario / rot
    inst.cfg, inst.looks = cfg, looks
    local pose = poseOf(el)
    if not samePose(inst.kind, inst.pose, pose) then
        -- a burst of moves before the check keeps the pose before its first move as the anchor
        if not inst.verifying then inst.anchor = inst.pose end
        inst.prevPose, inst.pose = inst.pose, pose
        inst.poseSeq, inst.verifying = (inst.poseSeq or 0) + 1, true
        TriggerClientEvent(POSE_EVENT, owner, NetworkGetNetworkIdFromEntity(entity), inst.uid,
            pose[1], pose[2], pose[3], pose[4], pose[5], pose[6])
        local seq = inst.poseSeq
        SetTimeout(VERIFY_MS, function() verifyPose(inst, seq) end)
    end
    return true
end

--- A changed networked element: still queued → nothing (spawnOne reads the latest element); being
--- created or failed → created again; spawned → updated in place when it can be, else re-created.
-- fxlint-disable-next-line C003 -- assigns the forward-declared local `updateNet` (spawnOne calls it)
updateNet = function(ctx, el)
    local inst = instances[instKey(ctx.bucket, uidOf(ctx.mapId, el.id))]
    if inst and not inst.done and not inst.cancelled then return end
    if inst and inst.ready and not inst.cancelled and moveInPlace(inst, types[el.type], el) then return end
    spawnFor(ctx, el)
end

--------------------------------------------------------------------------------
-- Events: Maps.on / Maps.records (active content only)
--------------------------------------------------------------------------------

local listeners = {}        -- [handle] = { handle, seq, typeId, fn, owner }
local listenerCount, listenerSeq = 0, 0
local listenedTypes = {}    -- [typeId|'*'] = number of listeners
local eventQueue, eventHead, draining = {}, 1, false

local function recordOf(ctx, el)
    local uid = uidOf(ctx.mapId, el.id)
    return { uid = uid, key = ctx.bucket .. '|' .. uid, mapId = ctx.mapId, id = el.id, type = el.type,
        pos = el.pos, rot = el.rot, fields = el.fields, layer = el.layer, bucket = ctx.bucket,
        editor = ctx.source == 'draft' }
end

--- Queued only: flushEvents() starts the drain once the caller finished its pass, so a listener that
--- calls back into Core.Maps never runs in the middle of a context update.
local function emit(event, ctx, el)
    if listenerCount == 0 or not (listenedTypes[el.type] or listenedTypes['*']) then return end
    eventQueue[#eventQueue + 1] = { event = event, record = recordOf(ctx, el), mapId = ctx.mapId, typeId = el.type }
end

local function deliver(item)
    local list = {}
    for _, l in pairs(listeners) do
        if l.typeId == item.typeId or l.typeId == '*' then list[#list + 1] = l end
    end
    table.sort(list, function(a, b) return a.seq < b.seq end)
    for i = 1, #list do
        local l = list[i]
        if listeners[l.handle] == l then
            local ok, err = pcall(l.fn, item.event, Utils.deepCopy(item.record), item.mapId)
            if not ok then Log.warn('maps: listener of %s failed on %s: %s', l.owner, item.event, tostring(err)) end
        end
    end
end

local function flushEvents()
    if draining or eventHead > #eventQueue then return end
    draining = true
    -- one drain thread at a time, ending when the queue is empty; listeners may Wait
    -- fxlint-disable-next-line P004
    CreateThread(function()
        while eventHead <= #eventQueue do
            local item = eventQueue[eventHead]
            eventQueue[eventHead] = nil
            eventHead = eventHead + 1
            deliver(item)
        end
        eventQueue, eventHead, draining = {}, 1, false
    end)
end

--- Maps.on(typeId|'*', fn(event, record, mapId)) -> handle|nil. Owner-swept; seed with Maps.records.
function R.on(typeId, fn)
    if typeId ~= '*' and (type(typeId) ~= 'string' or #typeId > 64 or not typeId:find('^[%w_%-]+:[%w_%-]+$')) then
        return nil
    end
    if not Utils.isCallable(fn) or listenerCount >= MAX_LISTENERS then return nil end
    listenerSeq = listenerSeq + 1
    local handle = 'maps:on:' .. listenerSeq
    local owner = Registry.getCaller()
    listeners[handle] = { handle = handle, seq = listenerSeq, typeId = typeId, fn = fn, owner = owner }
    listenerCount = listenerCount + 1
    listenedTypes[typeId] = (listenedTypes[typeId] or 0) + 1
    Registry.track(LISTENER_KIND, handle, owner)
    return handle
end

local function dropListener(handle)
    local l = listeners[handle]
    if not l then return false end
    listeners[handle] = nil
    listenerCount = listenerCount - 1
    local n = listenedTypes[l.typeId] - 1
    listenedTypes[l.typeId] = n > 0 and n or nil
    Registry.untrack(LISTENER_KIND, handle)
    return true
end

--- Maps.off(handle) -> bool (its owner or core).
function R.off(handle)
    local l = type(handle) == 'string' and listeners[handle]
    if not l then return false end
    local caller = Registry.getCaller()
    if caller ~= l.owner and caller ~= 'core' then return false end
    return dropListener(handle)
end

Registry.onOwnerStop(LISTENER_KIND, dropListener)

--------------------------------------------------------------------------------
-- Contexts: active content per (map, bucket)
--------------------------------------------------------------------------------

local function ctxKeyOf(mapId, bucket)
    return mapId .. '@' .. bucket
end

--- 'net' for server entities, 'tuple' for everything the clients render (placeholders included).
local function repOf(el)
    return R.isNetworked(types[el.type]) and 'net' or 'tuple'
end

local function show(ctx, el)
    local rep = repOf(el)
    ctx.reps[el.id] = rep
    if rep == 'tuple' then
        regionCall('put', ctx.bucket, uidOf(ctx.mapId, el.id), tupleOf(ctx.mapId, el))
    else
        ctx.netCount, netTotal = ctx.netCount + 1, netTotal + 1
        spawnFor(ctx, el)
    end
end

--- bulk = the caller clears the whole bucket afterwards (no per-uid remove).
local function hide(ctx, id, bulk)
    local rep = ctx.reps[id]
    if not rep then return end
    ctx.reps[id] = nil
    local uid = uidOf(ctx.mapId, id)
    if rep == 'tuple' then
        if not bulk then regionCall('remove', ctx.bucket, uid) end
    else
        ctx.netCount, netTotal = ctx.netCount - 1, netTotal - 1
        despawn(ctx.bucket, uid)
    end
end

--- A changed element: a tuple is re-put (the region module moves it), an entity is updated in place when
--- it can be (updateNet), anything that changes representation is hidden and shown again.
local function reshow(ctx, el)
    local was, now = ctx.reps[el.id], repOf(el)
    if was == 'tuple' and now == 'tuple' then
        regionCall('put', ctx.bucket, uidOf(ctx.mapId, el.id), tupleOf(ctx.mapId, el))
    elseif was == 'net' and now == 'net' then
        updateNet(ctx, el)
    else
        hide(ctx, el.id)
        show(ctx, el)
    end
end

--- Numeric element ids in ascending order (deterministic passes and event order).
local function sortedIds(t)
    local ids = {}
    for id in pairs(t) do ids[#ids + 1] = id end
    table.sort(ids, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb and na ~= nb then return na < nb end
        return a < b
    end)
    return ids
end
R.sortedIds = sortedIds

--- Activates `els` of `mapId` in `bucket`. source: 'live' | 'published' | 'draft' (the editor bucket).
function R.openContext(mapId, bucket, source, els)
    local key = ctxKeyOf(mapId, bucket)
    if contexts[key] then return contexts[key] end
    local ctx = { key = key, mapId = mapId, bucket = bucket, source = source, els = els, reps = {}, netCount = 0 }
    contexts[key] = ctx
    byMap[mapId] = byMap[mapId] or {}
    byMap[mapId][bucket] = ctx
    perBucket[bucket] = (perBucket[bucket] or 0) + 1
    local ids = sortedIds(els)
    for i = 1, #ids do
        local el = els[ids[i]]
        show(ctx, el)
        emit('added', ctx, el)
    end
    flushEvents()
    return ctx
end

--- Deactivates a context. An editor bucket nobody else renders into is cleared in one region call.
function R.closeContext(mapId, bucket)
    local key = ctxKeyOf(mapId, bucket)
    local ctx = contexts[key]
    if not ctx then return false end
    local exclusive = ctx.source == 'draft' and perBucket[bucket] == 1
    local ids = sortedIds(ctx.reps)
    for i = 1, #ids do
        local id = ids[i]
        hide(ctx, id, exclusive)
        local el = ctx.els[id]
        if el then emit('removed', ctx, el) end
    end
    if exclusive then regionCall('clearBucket', bucket) end
    contexts[key] = nil
    byMap[mapId][bucket] = nil
    if next(byMap[mapId]) == nil then byMap[mapId] = nil end
    local n = perBucket[bucket] - 1
    perBucket[bucket] = n > 0 and n or nil
    flushEvents()
    return true
end

--- Replaces a context's content (publish / rollback): only what differs (id, type, updatedAt) is touched.
function R.swapContext(mapId, bucket, els)
    local ctx = contexts[ctxKeyOf(mapId, bucket)]
    if not ctx then return false end
    local old = ctx.els
    ctx.els = els
    local gone = sortedIds(old)
    for i = 1, #gone do
        local id = gone[i]
        if not els[id] and ctx.reps[id] then
            hide(ctx, id)
            emit('removed', ctx, old[id])
        end
    end
    local ids = sortedIds(els)
    for i = 1, #ids do
        local el, prev = els[ids[i]], old[ids[i]]
        if not ctx.reps[el.id] then
            show(ctx, el)
            emit('added', ctx, el)
        elseif not prev or prev.updatedAt ~= el.updatedAt or prev.type ~= el.type then
            reshow(ctx, el)
            emit('changed', ctx, el)
        end
    end
    flushEvents()
    return true
end

--- After an apply on a map's working set: every context showing it (`source` 'live' or 'draft')
--- re-renders the touched ids. ids = ordered array, before = { [id] = element|false } (false: new).
function R.applyChanges(mapId, source, ids, before)
    local ctxs = byMap[mapId]
    if not ctxs then return end
    for _, ctx in pairs(ctxs) do
        if ctx.source == source then
            for i = 1, #ids do
                local id = ids[i]
                local el, shown = ctx.els[id], ctx.reps[id] ~= nil
                if el and shown then
                    reshow(ctx, el)
                    emit('changed', ctx, el)
                elseif el then
                    show(ctx, el)
                    emit('added', ctx, el)
                elseif shown then
                    hide(ctx, id)
                    if before[id] then emit('removed', ctx, before[id]) end
                end
            end
        end
    end
    flushEvents()
end

--- A type was (re)defined or removed: its active elements are rendered again (no events: the content
--- did not change, only how it is shown).
function R.refreshType(typeId)
    for _, ctx in pairs(contexts) do
        for id, el in pairs(ctx.els) do
            if el.type == typeId and ctx.reps[id] then reshow(ctx, el) end
        end
    end
end

function R.contextsOf(mapId) return byMap[mapId] or {} end
function R.getContext(mapId, bucket) return contexts[ctxKeyOf(mapId, bucket)] end
function R.netTotal() return netTotal end

--- Re-creates destroyed networked elements of a map's active contexts (all, or one element id).
--- An instance still being created is left alone. Returns how many were queued.
function R.respawn(mapId, elementId)
    local count = 0
    for _, ctx in pairs(byMap[mapId] or {}) do
        for id, rep in pairs(ctx.reps) do
            if rep == 'net' and (elementId == nil or id == elementId) then
                local inst = instances[instKey(ctx.bucket, uidOf(mapId, id))]
                -- queued, being created, or spawned and still ours (a reused handle is someone else's entity)
                local alive = inst and (not inst.done or (not inst.ready and inst.entity ~= nil)
                    or (inst.ready and ours(inst.entity, inst.uid)))
                if not alive and ctx.els[id] then
                    spawnFor(ctx, ctx.els[id])
                    count = count + 1
                end
            end
        end
    end
    return count
end

--- Every active record of a type (all types with '*'): editor buckets included (record.editor = true).
function R.records(typeId)
    local out = {}
    for _, ctx in pairs(contexts) do
        local ids = sortedIds(ctx.els)
        for i = 1, #ids do
            local el = ctx.els[ids[i]]
            if typeId == '*' or el.type == typeId then out[#out + 1] = Utils.deepCopy(recordOf(ctx, el)) end
        end
    end
    return out
end

function R.stats()
    local n, spawned = 0, 0
    for _ in pairs(contexts) do n = n + 1 end
    for _, inst in pairs(instances) do
        if inst.entity then spawned = spawned + 1 end
    end
    return { contexts = n, networked = netTotal, spawned = spawned, listeners = listenerCount }
end

-- Core stops: its server entities go with it (orphan mode 2 would keep them otherwise).
AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    for _, inst in pairs(instances) do
        inst.cancelled = true
        deleteEntity(inst.entity, inst.uid)
    end
    instances = {}
end)
