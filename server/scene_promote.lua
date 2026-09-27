--[[
    core/server/scene_promote.lua — R.promote (DESIGN §55.15): the promotion ENGINE of Core.Scene — policy, budgets,
    the clone and its snCfg, the spawn worker, the 1 Hz monitor (rest / idle / follow), demotions, the index taps.
    Loads RIGHT AFTER server/scene.lua (asserts it); server/scene_promote_api.lua loads right after this file and
    takes R.promoteInternal ONCE (the entry points: Scene.promote / demote / lease, adopt, beforeChange, the net
    events, interactions, onEntityBucketChange, player drops, the core stop). Here: policy(node), ours(e, id, snv),
    modelHash(model). Policy: class default (vehicle { promote, proximity 20, enter, damage }; prop, ped { local };
    a physics = 'promote' prop { local, damage }) → kind.authority → node.authority; restMs 3000, idleMs 20000,
    onDestroyed 'keep'. Budgets: Promote.MaxEntities (queued included), proximity promotions ≤ ProximityShare of it;
    at the cap an enter / manual / action promotion evicts the oldest idle proximity one (RV4 F9); MaxPropsPerArea.
    A vehicle clone's snCfg = { props (COSMETIC: every owner re-applies them), plate, paint?, invincible?, frozen?,
    once = { wear?, locked?, dirt? } } — its first owner applies `once` and sends core:scene:applied, the bag then
    keeps the rest (RV5 F1). Monitor: the clone's pose + bucket (a synced vehicle's healths / dirt / burst tyres
    once `once` was applied) are sampled; the node FOLLOWS (R.store.follow) past 1 m / 5° or into another bucket,
    staying on its pre-promotion pose within 0.2 m / 2°; demote when unleased, at rest, nobody of the CLONE's bucket
    near for idleMs, no occupant. Demotion: the owner's props read-back merges only the wear whitelist
    (Scene.mergeWear; plate = the node's: RV4 F1); an occupant meanwhile aborts it; the final pose + bucket followed,
    ver + 1, DEMOTE, hook demoted(copy, info = { reason = 'rest'|'manual'|'forced'|'evicted'|'lost'|'destroyed',
    destroyed, pos, rot, bucket, wear? }); the clone goes DeleteDelayMs later unless someone got in (kept and
    promoted again: RV4 F12). A lost clone (gone / wrecked) demotes where last seen with its last known wear (RV4 F5).
    ours(e) = DoesEntityExist(e) and state sn == id and snv (handles are reused, §52 review F1). R.index.put / remove
    are WRAPPED: a root placement re-evaluates the proximity policy; removing a promoted root drops its clone.

    Natives (fxref + natives_cfx.json 2026-09-27; server / CFX forms; BOOL answers read by truthiness):
      CreateVehicleServerSetter(modelHash, type, x, y, z, heading), CreatePed(pedType, modelHash, x, y, z, heading,
      isNetwork, bScriptHostPed), CreateObjectNoOffset(modelHash, x, y, z, isNetwork, netMissionEntity, doorFlag),
      SetEntityRotation(entity, pitch, roll, yaw, rotationOrder, bDeadCheck), SetEntityRoutingBucket(entity, bucket),
      GetEntityRoutingBucket(entity), SetEntityOrphanMode(entity, orphanMode), DoesEntityExist(entity),
      DeleteEntity(entity), GetEntityCoords(entity), GetEntityRotation(entity), GetEntityVelocity(entity),
      GetEntityHealth(entity), GetVehicleEngineHealth(vehicle), GetVehicleBodyHealth(vehicle),
      GetVehiclePetrolTankHealth(vehicle), GetVehicleDirtLevel(vehicle) (the synced nodes: 0 before the first sync),
      IsVehicleTyreBurst(vehicle, wheelID, completely) (server: an exact status match, so both forms are asked),
      NetworkGetNetworkIdFromEntity(entity), NetworkGetEntityOwner(entity) (-1 = the server), GetPedInVehicleSeat(
      vehicle, seatIndex), GetPlayerPed(playerSrc), GetPlayerRoutingBucket(playerSrc), GetVehiclePedIsIn(ped,
      lastVehicle), SetVehicleColours(vehicle, primary, secondary), SetVehicleNumberPlateText(vehicle, plateText),
      SetVehicleDoorsLocked(vehicle, doorLockStatus), FreezeEntityPosition(entity, toggle), GetHashKey(model),
      GetGameTimer(). Runtime helpers: Entity(e).state, CreateThread, Wait, SetTimeout.
]]

local R = Core.SceneRuntime
assert(type(R) == 'table' and R.store and R.index and R.interest and R.kinds and R.valid and R.storeInternal == nil
    and type(R.store.follow) == 'function' and type(Core.Scene) == 'table' and Core.Scene.adopt ~= nil
    and type(Core.Scene.mergeWear) == 'function',
    'server/scene_promote.lua loads right after server/scene.lua (R.store, the Scene API, lib/scene mergeWear)')

local Scene, Log = Core.Scene, Core.Log
local store, K, I = R.store, R.kinds, R.index

local type, pairs, pcall, tostring, next = type, pairs, pcall, tostring, next
local floor, toint, mtype, abs = math.floor, math.tointeger, math.type, math.abs

local PM = {}
R.promote = PM

local function cfgNum(t, key, default, lo, hi)
    local v = type(t) == 'table' and tonumber(t[key]) or nil
    if not v or v ~= v then return default end
    return v < lo and lo or (v > hi and hi or v)
end

local SC = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
local PC = type(SC.Promote) == 'table' and SC.Promote or {}
local MAX_ENTITIES <const> = floor(cfgNum(PC, 'MaxEntities', 1000, 0, 65535))
local PROX_MAX <const> = floor(MAX_ENTITIES * cfgNum(PC, 'ProximityShare', 0.7, 0, 1))
local MAX_PROPS_AREA <const> = floor(cfgNum(PC, 'MaxPropsPerArea', 32, 0, 100000))
local DELETE_DELAY_MS <const> = floor(cfgNum(PC, 'DeleteDelayMs', 500, 0, 60000))
local REST_SPEED <const> = cfgNum(PC, 'RestSpeed', 0.05, 0, 100)

local ORPHAN_KEEP <const>, PED_TYPE <const> = 2, 4                       -- orphan KeepEntity, CIVMALE
local SPAWN_TIMEOUT_MS <const>, SPAWN_POLL_MS <const> = 5000, 50
local TICK_MS <const>, SLICES <const>, CHECK_MS <const> = 100, 10, 1000  -- the monitor: every node once a second
local AREA <const> = 256.0                                               -- MaxPropsPerArea squares
local SEAT_FIRST <const>, SEAT_LAST <const> = -1, 15
local SNAP_M <const>, SNAP_DEG <const> = 0.2, 2.0         -- within this of the pre-promotion pose: that pose
local FOLLOW_M <const>, FOLLOW_DEG <const> = 1.0, 5.0     -- the node follows its clone past this (or a new bucket)
local WHEEL_LAST <const>, WEAR_FULL_EVERY <const> = 7, 10  -- burst tyres 0..7: when healths changed or every 10th
local IDLE_RADIUS <const> = 20.0            -- the idle check of a policy without a proximity
local SYNC_MS <const> = 1000                -- after 'applied': the owner's applied wear reaches the server first
local PROPS_TIMEOUT_MS <const>, LOG_EVERY_MS <const> = 1000, 60000
local ZERO <const> = { x = 0.0, y = 0.0, z = 0.0 }
local EMPTY <const> = setmetatable({}, { __newindex = function() error('read-only', 2) end })
local RESERVED <const> = { enter = true, manual = true, action = true }  -- may evict an idle proximity promotion

local function now() return R.now() end
local function since(t) return R.diff(R.now(), t) end
local function isFinite(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end
local function wrap180(a) a = a % 360.0 return a > 180.0 and a - 360.0 or a end

local stats = { promoted = 0, demoted = 0, destroyed = 0, lost = 0, removed = 0, aborted = 0, forced = 0,
    evicted = 0, rescued = 0, adopted = 0, follows = 0, propsRead = 0, propsRefused = 0,
    refused = { limit = 0, share = 0, area = 0, create = 0, timeout = 0 }, reports = { enter = 0, damaged = 0,
    applied = 0 } }
local warnedAt = {}                          -- reason -> Clock ms of the last log line

--- Refusals and failures are logged at most once a minute per reason (a busy proximity sweep would spam).
local function logLimited(reason, fmt, ...)
    local last = warnedAt[reason]
    if last and since(last) < LOG_EVERY_MS then return end
    warnedAt[reason] = now()
    Log.warn('scene: ' .. fmt, ...)
end

--------------------------------------------------------------------------------
-- Policy: class default → kind.authority → node.authority (cached per node, kind version and physics field)
--------------------------------------------------------------------------------

local CLASS_DEFAULT <const> = { vehicle = { mode = 'promote', proximity = 20, enter = true, damage = true },
    prop = { mode = 'local' }, ped = { mode = 'local' } }
local PHYS_PROMOTE <const> = { mode = 'local', damage = true }   -- a prop with physics = 'promote'
local NONE <const> = setmetatable({ none = true }, { __newindex = function() error('read-only', 2) end })
-- resolved policies, shared: per kind table and physics value for nodes without node.authority, per node else
local byKind = setmetatable({}, { __mode = 'k' })                -- kind -> { kv, [physics or 1] = policy }
local byNode = setmetatable({}, { __mode = 'k' })                -- node -> policy

local function overlay(pol, a)
    if type(a) ~= 'table' then return end
    for key, v in pairs(a) do
        if key == 'actions' then
            local set = {}
            for i = 1, type(v) == 'table' and #v or 0 do set[v[i]] = true end
            pol.actions = set
        elseif key ~= 'cls' and key ~= 'kv' and key ~= 'phys' and key ~= 'prox' then
            pol[key] = v
        end
    end
end

local function resolve(node, k, kv, phys)
    local cls = k.class
    local base = (cls == 'prop' and phys == 'promote') and PHYS_PROMOTE or CLASS_DEFAULT[cls]
    local pol = { cls = cls, kv = kv, phys = phys, mode = base.mode, proximity = base.proximity,
        enter = base.enter == true, damage = base.damage == true, restMs = 3000, idleMs = 20000,
        onDestroyed = 'keep' }
    overlay(pol, k.authority)
    overlay(pol, node.authority)
    pol.enter, pol.damage = pol.enter == true and cls == 'vehicle', pol.damage == true
    pol.prox = pol.mode ~= 'local' and isFinite(pol.proximity) and pol.proximity > 0
    return pol
end

--- The node's resolved policy (NONE for what cannot be promoted), cached per kind version. Never mutate it.
local function policyOf(node)
    local k = node.k
    if type(k) ~= 'table' or k.dependency or not CLASS_DEFAULT[k.class] then return NONE end
    local kv, f = K.version(), node.fields
    local phys = type(f) == 'table' and f.physics or nil
    if node.authority == nil then
        local slot = byKind[k]
        if not slot or slot.kv ~= kv then
            slot = { kv = kv }
            byKind[k] = slot
        end
        local c = slot[phys or 1]
        if not c then
            c = resolve(node, k, kv, phys)
            slot[phys or 1] = c
        end
        return c
    end
    local c = byNode[node]
    if c and c.kv == kv and c.phys == phys then return c end
    c = resolve(node, k, kv, phys)
    byNode[node] = c
    return c
end
PM.policy = policyOf

--------------------------------------------------------------------------------
-- State: promotions, leases, budgets
--------------------------------------------------------------------------------

-- [id] = { id, node, cls, phase = 'queued'|'spawning'|'live'|'demoting', trigger, by, prox, area, entity, netId,
--          snv, since, due, restSince, idleSince, healthSeen, cancelled, once, applied, home, last, wear, wearN }
local P, nP = {}, 0
local count, proxCount = 0, 0                -- promotions holding a budget slot (queued ones included) / by proximity
local areas = {}                             -- ['<bucket>:<key>'] = promoted props in that 256 m square
local leases = {}                            -- [id] = { src, seq, untilMs } (Scene.lease: scene_promote_api.lua)
local doomed = {}                            -- [entity] = { id, snv }: clones deleted DeleteDelayMs later
local byEntity = {}                          -- [live clone] = its promotion (onEntityBucketChange)
local stopping = false
local wakeMonitor, adoptEntity               -- forward: the monitor thread / a live entity as a node's clone

local function areaKey(node)
    local p = node.pos or ZERO
    local ax, ay = floor(p.x / AREA) + 32768, floor(p.y / AREA) + 32768
    return ('%d:%d'):format(node.bucket or 0, ax * 65536 + ay)
end

--- Is `e` still the clone of node `id` (promoted at version `snv`)? The handle alone never proves it.
local function ours(e, id, snv)
    if not e or e == 0 or not DoesEntityExist(e) then return false end
    local st = Entity(e).state
    return st.sn == id and (snv == nil or st.snv == snv)
end
PM.ours = ours

--- The promotion gives its budget slots back and leaves the table.
local function release(pr)
    if pr.released then return end
    pr.released, count = true, count - 1
    if pr.prox then proxCount = proxCount - 1 end
    if P[pr.id] == pr then P[pr.id], nP = nil, nP - 1 end
    if pr.entity and byEntity[pr.entity] == pr then byEntity[pr.entity] = nil end
    if pr.area then
        local n = (areas[pr.area] or 1) - 1
        areas[pr.area] = n > 0 and n or nil
    end
end

local function leaseOf(id)
    local L = leases[id]
    if L and R.diff(now(), L.untilMs) >= 0 then L, leases[id] = nil, nil end
    return L
end

local function occupied(e)
    for seat = SEAT_FIRST, SEAT_LAST do
        local ped = GetPedInVehicleSeat(e, seat)
        if ped and ped ~= 0 then return true end
    end
    return false
end

local REST2 <const> = REST_SPEED * REST_SPEED
local function moving(e)
    local v = GetEntityVelocity(e)
    return v.x * v.x + v.y * v.y + v.z * v.z >= REST2
end

--- The clone goes DeleteDelayMs after the op (clients hand back to their local copies first). `demotion`: a clone
--- that got an occupant in that window is kept — the node is promoted again with it (RV4 F12).
local function doom(pr, demotion)
    local e = pr.entity
    if not e then return end
    local id, snv, node, cls = pr.id, pr.snv, pr.node, pr.cls
    doomed[e] = { id = id, snv = snv }
    SetTimeout(DELETE_DELAY_MS, function()
        if doomed[e] and doomed[e].id == id then doomed[e] = nil end
        if not ours(e, id, snv) then return end
        if demotion and cls == 'vehicle' and not stopping and occupied(e) and store.get(id) == node
            and not P[id] and not node.promoted then
            stats.rescued = stats.rescued + 1
            adoptEntity(node, e, 'rescue')
            return
        end
        DeleteEntity(e)
    end)
end

--------------------------------------------------------------------------------
-- The clone: what it is created with, what its owner applies (snCfg), the one spawn worker
--------------------------------------------------------------------------------

--- A prop the clone of which simulates physics (created dynamic, not frozen).
local function dynamicProp(f)
    return f.physics == 'promote' or f.frozen == false
end

--- A vehicle clone's snCfg (D-A): the COSMETIC props (every owner re-applies them, idempotent: a read-back can never
--- change them, RV4 F1), plate, the stable paint (no props colours), per-owner flags; with `once` the damage / wear /
--- lock part its FIRST owner applies (then core:scene:applied: the bag keeps the rest + applied = true).
local function vehicleCfg(node, withOnce)
    local f = type(node.fields) == 'table' and node.fields or EMPTY
    local cosmetic, wear = Scene.splitProps(f.props)
    local cfg = { props = next(cosmetic) and cosmetic or nil, plate = f.plate, invincible = f.invincible == true or nil,
        frozen = node.motion ~= nil or nil }   -- (a kinematic mover)
    local primary, secondary = Scene.paintOf(node.id)
    if primary and cosmetic.colorPrimary == nil then cfg.paint = { primary, secondary } end
    if not withOnce then
        cfg.applied = true
        return cfg
    end
    local once = { wear = next(wear) and wear or nil, locked = f.locked == true or nil,
        dirt = isFinite(f.dirt) and f.dirt or nil }
    if next(once) then cfg.once = once end
    return cfg
end

--- What the owning client applies (client/scene_promote.lua): the server's RPC natives are fallible, so the bag is the
--- source of truth for the clone's config (the §52 mapCfg pattern).
local function snCfgOf(cls, node, rx, ry, rz)
    if cls == 'vehicle' then return vehicleCfg(node, true) end
    local f = type(node.fields) == 'table' and node.fields or EMPTY
    if cls == 'ped' then
        return { appearance = f.appearance, variation = f.variation, invincible = f.invincible ~= false,
            frozen = f.frozen ~= false, blockEvents = f.blockEvents ~= false, scenario = f.scenario,
            weapon = f.weapon }
    end
    return { rot = { x = rx, y = ry, z = rz }, frozen = not dynamicProp(f), collision = f.collision ~= false,
        invincible = f.invincible == true or nil }
end

-- CreateVehicleServerSetter's types (fxref: the `type` of vehicles.meta)
local VTYPES <const> = { automobile = true, bike = true, boat = true, heli = true, plane = true, submarine = true,
    trailer = true, train = true }

--- A node's model -> the hash the create natives take: an integer (u32 or signed; normalised to the signed 32-bit
--- form GetHashKey answers), a '0x%08X' string (the hash form of the kinds, any case) or a name; nil if unusable.
local function modelHash(m)
    if type(m) == 'string' then
        local hex = m:match('^0[xX](%x+)$')
        if not hex then return #m > 0 and GetHashKey(m) or nil end
        if #hex > 8 then return nil end
        m = tonumber(hex, 16)
    end
    local n = mtype(m) == 'integer' and m or (type(m) == 'number' and toint(m) or nil)
    if not n or n < -0x80000000 or n > 0xFFFFFFFF then return nil end
    return n > 0x7FFFFFFF and n - 0x100000000 or n
end
PM.modelHash = modelHash

--- A vehicle node's CreateVehicleServerSetter type: its `vtype` field, else the model info (a name), else automobile.
local function vehicleType(f)
    if type(f.vtype) == 'string' and VTYPES[f.vtype] then return f.vtype end
    local info = type(f.model) == 'string' and K.modelInfo('vehicle', f.model) or nil
    return (info and VTYPES[info.vtype]) and info.vtype or 'automobile'
end

--- Creates the networked entity of a node at its pose; 0 when the native refused (or the model is unusable).
local function createEntity(pr, node, x, y, z, rx, ry, rz)
    local f = type(node.fields) == 'table' and node.fields or EMPTY
    local hash = modelHash(f.model)
    if not hash then return 0 end
    local heading = rz % 360.0
    if pr.cls == 'vehicle' then
        return CreateVehicleServerSetter(hash, vehicleType(f), x + 0.0, y + 0.0, z + 0.0, heading + 0.0) or 0
    elseif pr.cls == 'ped' then
        return CreatePed(PED_TYPE, hash, x + 0.0, y + 0.0, z + 0.0, heading + 0.0, true, true) or 0
    end
    local e = CreateObjectNoOffset(hash, x + 0.0, y + 0.0, z + 0.0, true, true, dynamicProp(f)) or 0
    if e ~= 0 and (rx ~= 0 or ry ~= 0 or rz ~= 0) then SetEntityRotation(e, rx + 0.0, ry + 0.0, rz + 0.0, 2, false) end
    return e
end

--- Bucket first (server entities start in bucket 0), orphan mode, the state bags, then the fallible RPCs.
local function configure(pr, node, e, rx, ry, rz)
    SetEntityRoutingBucket(e, node.bucket or 0)
    SetEntityOrphanMode(e, ORPHAN_KEEP)
    local st = Entity(e).state
    st:set('sn', node.id, true)
    st:set('snv', pr.snv, true)
    local cfg = snCfgOf(pr.cls, node, rx, ry, rz)
    st:set('snCfg', cfg, true)
    pr.once = cfg.once ~= nil
    local f = type(node.fields) == 'table' and node.fields or EMPTY
    if pr.cls == 'vehicle' then
        if cfg.paint then SetVehicleColours(e, cfg.paint[1], cfg.paint[2]) end
        if type(f.plate) == 'string' and f.plate ~= '' then SetVehicleNumberPlateText(e, f.plate) end
        if f.locked == true then SetVehicleDoorsLocked(e, 2) end
    elseif cfg.frozen then
        FreezeEntityPosition(e, true)
    end
end

--------------------------------------------------------------------------------
-- Following the clone (D-C / D-D): its pose, bucket and wear, sampled by the monitor; the node follows
--------------------------------------------------------------------------------

local function near(ax, ay, az, arx, ary, arz, x, y, z, rx, ry, rz, m, deg)
    local dx, dy, dz = x - ax, y - ay, z - az
    return dx * dx + dy * dy + dz * dz <= m * m and abs(wrap180(rx - arx)) <= deg and abs(wrap180(ry - ary)) <= deg
        and abs(wrap180(rz - arz)) <= deg
end

--- A node's base pose + bucket as a flat record (the pre-promotion pose a demotion snaps back to).
local function poseRec(node)
    local p, r = node.pos or ZERO, node.rot or ZERO
    return { x = p.x, y = p.y, z = p.z, rx = r.x, ry = r.y, rz = r.z, bucket = node.bucket or 0 }
end

--- A SYNCED vehicle clone's damage / wear as the server knows it: healths and dirt at every check, burst tyres when
--- a health changed or every WEAR_FULL_EVERY checks. Windows, doors and fuel come only from the owner's props (the
--- server reads a damage node that never synced as "every window broken").
local function sampleWear(pr, e)
    local w = pr.wear
    local eh, bh, th = GetVehicleEngineHealth(e), GetVehicleBodyHealth(e), GetVehiclePetrolTankHealth(e)
    pr.wearN = (pr.wearN or 0) + 1
    local full = w == nil or w.engineHealth ~= eh or w.bodyHealth ~= bh or w.tankHealth ~= th
        or pr.wearN % WEAR_FULL_EVERY == 0
    if not w then
        w = {}
        pr.wear = w
    end
    w.engineHealth, w.bodyHealth, w.tankHealth, w.dirtLevel = eh, bh, th, GetVehicleDirtLevel(e)
    if full then
        local burst = {}
        for i = 0, WHEEL_LAST do
            if IsVehicleTyreBurst(e, i, false) or IsVehicleTyreBurst(e, i, true) then burst[i] = true end
        end
        w.burstTyres = burst
    end
end

--- The clone's pose and bucket now (a synced vehicle's wear too) -> pr.last.
local function sample(pr, e)
    local c, r = GetEntityCoords(e), GetEntityRotation(e)
    local L = pr.last
    L.x, L.y, L.z, L.rx, L.ry, L.rz = c.x, c.y, c.z, r.x, r.y, r.z
    local b = toint(GetEntityRoutingBucket(e))
    if b and b >= 0 then L.bucket = b end
    -- (until its owner applied the one-shot part — and that synced — the clone shows pristine wear: never the car's)
    if pr.cls == 'vehicle' and pr.healthSeen and (not pr.once or (pr.applied and since(pr.appliedAt) >= SYNC_MS)) then
        sampleWear(pr, e)
    end
end

local fp, fr = { x = 0.0, y = 0.0, z = 0.0 }, { x = 0.0, y = 0.0, z = 0.0 }   -- (R.store.follow copies them)

--- The node follows its clone's last known pose + bucket: within SNAP_M / SNAP_DEG of the pre-promotion pose it
--- stays (or goes back) there; else past FOLLOW_M / FOLLOW_DEG or into another bucket; `exact` (a demotion, the core
--- stop) always writes; `persist` at once. A mover keeps its descriptor's pose (its bucket follows).
local function follow(pr, node, exact, persist)
    local L, H = pr.last, pr.home
    local b, ok, err = L.bucket, nil, nil
    if node.motion then
        if b == (node.bucket or 0) and not exact then return true end
        ok, err = store.follow(node, nil, nil, b, persist)
    else
        local x, y, z, rx, ry, rz = L.x, L.y, L.z, L.rx, L.ry, L.rz
        if H and b == H.bucket and near(H.x, H.y, H.z, H.rx, H.ry, H.rz, x, y, z, rx, ry, rz, SNAP_M, SNAP_DEG) then
            x, y, z, rx, ry, rz = H.x, H.y, H.z, H.rx, H.ry, H.rz
        end
        if not exact and b == (node.bucket or 0) then
            local p, r = node.pos or ZERO, node.rot or ZERO
            if near(p.x, p.y, p.z, r.x, r.y, r.z, x, y, z, rx, ry, rz, FOLLOW_M, FOLLOW_DEG) then return true end
        end
        fp.x, fp.y, fp.z, fr.x, fr.y, fr.z = x, y, z, rx, ry, rz
        ok, err = store.follow(node, fp, fr, b, persist)
    end
    if ok then
        stats.follows = stats.follows + 1
    else
        Log.debug('scene: node %d could not follow its clone (%s)', node.id, tostring(err))
    end
    return ok
end

--- Can `node` be promoted at all? -> class | nil, err
local function eligible(node)
    local pol = policyOf(node)
    if pol.none then return nil, 'class' end
    if node.parent then return nil, 'parent' end
    if node.attach then return nil, 'attach' end
    local f = node.fields
    local model = type(f) == 'table' and f.model or nil
    if type(model) ~= 'string' and not toint(model) then return nil, 'model' end
    return pol.cls
end

local function spawnOne(pr)
    if P[pr.id] ~= pr or pr.cancelled then return end
    local node = store.get(pr.id)
    if node ~= pr.node or not eligible(node) then return release(pr) end
    pr.phase = 'spawning'
    local x, y, z, rx, ry, rz = store.pose(node, now())
    local e = createEntity(pr, node, x, y, z, rx, ry, rz)
    if not e or e == 0 then
        stats.refused.create = stats.refused.create + 1
        logLimited('create', 'could not create the %s clone of node %d (%s)', pr.cls, pr.id,
            tostring(node.fields.model))
        return release(pr)
    end
    pr.entity = e
    -- wait even when cancelled meanwhile: an entity can only be deleted once it exists
    local deadline = GetGameTimer() + SPAWN_TIMEOUT_MS
    while not DoesEntityExist(e) and GetGameTimer() < deadline do Wait(SPAWN_POLL_MS) end
    if pr.cancelled or P[pr.id] ~= pr or store.get(pr.id) ~= node or stopping then
        -- the handle the create native just returned (no sn yet): the one unchecked delete
        if DoesEntityExist(e) then DeleteEntity(e) end
        pr.entity = nil
        return release(pr)
    end
    if not DoesEntityExist(e) then
        stats.refused.timeout = stats.refused.timeout + 1
        logLimited('timeout', 'the %s clone of node %d did not appear within %d ms', pr.cls, pr.id, SPAWN_TIMEOUT_MS)
        pr.entity = nil
        return release(pr)
    end
    pr.snv = store.bump(node)
    configure(pr, node, e, rx, ry, rz)
    pr.netId = NetworkGetNetworkIdFromEntity(e)
    pr.phase, pr.since = 'live', now()
    pr.due = R.add(pr.since, CHECK_MS)
    pr.home = poseRec(node)
    pr.last = { x = x, y = y, z = z, rx = rx, ry = ry, rz = rz, bucket = node.bucket or 0 }
    byEntity[e] = pr
    node.promoted = { netId = pr.netId, entity = e, since = pr.since, trigger = pr.trigger }
    I.changed(node, 'promote', pr.netId)
    stats.promoted = stats.promoted + 1
    store.notify('promoted', node, pr.netId)
    wakeMonitor()
end

local queue, qHead, qTail, working = {}, 1, 0, false

--- One worker for every spawn; it exists only while something is queued (an explicit tail: §52's lost-spawn fix).
local function enqueue(pr)
    qTail = qTail + 1
    queue[qTail] = pr
    if working then return end
    working = true
    CreateThread(function()
        while qHead <= qTail do
            local item = queue[qHead]
            queue[qHead], qHead = nil, qHead + 1
            local ok, err = pcall(spawnOne, item)
            if not ok then
                Log.error('scene: promoting node %s failed: %s', tostring(item.id), tostring(err))
                local e = item.entity
                if e and item.phase ~= 'live' and DoesEntityExist(e) then DeleteEntity(e) end
                release(item)
            end
        end
        queue, qHead, qTail, working = {}, 1, 0, false
    end)
end

--------------------------------------------------------------------------------
-- Demote, lost clones, eviction, promote, adoption
--------------------------------------------------------------------------------

local function sameValue(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
    for k, v in pairs(a) do if b[k] ~= v then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

--- Does a WEAR value say "as a fresh car" (full healths, the node's dirt, nothing burst / broken / open)? Such a key
--- is not written into props that never carried it.
local function pristine(key, v, f)
    if type(v) == 'number' then
        if key == 'dirtLevel' then return abs(v - (isFinite(f.dirt) and f.dirt or 0)) < 0.5 end
        return key ~= 'fuelLevel' and v >= 999.5
    end
    if type(v) ~= 'table' then return false end
    for _, x in pairs(v) do
        if key == 'windows' then
            if x ~= true then return false end
        elseif key == 'tyreHealth' then
            if type(x) ~= 'number' or x < 999.5 then return false end
        elseif x == true then                      -- doors open / tyres burst
            return false
        end
    end
    return true
end

--- A vehicle node's props after a demotion (RV4 F1): the stored props with ONLY the damage / wear of the server's
--- last sample, then of the owner's read-back, merged in (Scene.mergeWear: clamped; never mods, colours or the plate),
--- the plate re-imposed from the node field. nil when the wear did not change (no SET for every client).
local function wearProps(node, sampled, readBack)
    if sampled == nil and readBack == nil then return nil end
    local f = type(node.fields) == 'table' and node.fields or EMPTY
    local stored = type(f.props) == 'table' and f.props or EMPTY
    local merged = Scene.mergeWear(stored, sampled)
    if readBack ~= nil then merged = Scene.mergeWear(merged, readBack) end
    local same = true
    for key in pairs(Scene.WEAR) do
        local m, s = merged[key], stored[key]
        if s == nil and m ~= nil and pristine(key, m, f) then
            merged[key] = nil
        elseif not sameValue(m, s) then
            same = false
        end
    end
    if same then return nil end
    if type(f.plate) == 'string' and f.plate ~= '' then merged.plate = f.plate end
    return merged
end

--- The second argument of the hook demoted(copy, info): why, whether the clone was wrecked, where the node is now
--- (the clone's last known pose + bucket) and, for a vehicle, the WEAR keys of its props now.
local function demotedInfo(cls, node, reason, wrecked)
    local p, r, wear = node.pos or ZERO, node.rot or ZERO, nil
    if cls == 'vehicle' then
        local f = node.fields
        wear = select(2, Scene.splitProps(type(f) == 'table' and f.props or nil))
    end
    return { reason = reason, destroyed = wrecked == true, pos = { x = p.x, y = p.y, z = p.z },
        rot = { x = r.x, y = r.y, z = r.z }, bucket = node.bucket or 0, wear = wear }
end

--- The node is local again. `atClone`: first it takes the clone's last known pose + bucket (R.store.follow, while
--- node.promoted is still set; the pre-promotion pose within 0.2 m / 2°). Then its new props (as core), ver + 1, the
--- DEMOTE op, the hook demoted(copy, info); the clone goes DeleteDelayMs later (kept if someone got in: RV4 F12).
local function finishDemote(pr, node, atClone, props, reason, wrecked)
    if atClone and node.promoted then follow(pr, node, true, true) end
    node.promoted = nil                      -- every op from here on describes a local node, and the Scene calls
    release(pr)                              -- below find no promotion (beforeChange, the taps)
    local id = node.id
    if props then
        local ok, err = Scene.set(id, { props = props })
        local key = ok and 'propsRead' or 'propsRefused'
        stats[key] = stats[key] + 1
        if not ok then Log.debug('scene: props of node %d refused after the demotion (%s)', id, tostring(err)) end
    end
    store.bump(node)
    I.changed(node, 'demote')
    doom(pr, not wrecked)
    stats.demoted = stats.demoted + 1
    store.notify('demoted', node, demotedInfo(pr.cls, node, reason, wrecked))
end

--- The demotion's slow half (a thread: the props callback yields up to 1 s). An occupant that got in meanwhile
--- aborts it — whatever the reason (RV4 F12); so does a rest demotion's clone that moves again.
local function demoteNow(pr, why)
    local node, id, e = pr.node, pr.id, pr.entity
    local readBack
    if pr.cls == 'vehicle' and ours(e, id, pr.snv) then
        local owner = NetworkGetEntityOwner(e)
        if mtype(owner) == 'integer' and owner > 0 then
            local got = Core.Callback.awaitClientTimeout(owner, 'core:scene:props', PROPS_TIMEOUT_MS, pr.netId)
            if type(got) == 'table' then readBack = got end
        end
    end
    if P[id] ~= pr or store.get(id) ~= node or stopping then return end   -- removed / forced meanwhile
    if ours(e, id, pr.snv) then
        if (pr.cls == 'vehicle' and occupied(e)) or (why == 'rest' and not node.motion and moving(e)) then
            pr.phase, pr.restSince, pr.idleSince = 'live', nil, nil
            stats.aborted = stats.aborted + 1
            return
        end
        sample(pr, e)                        -- where it stands now (the pose it demotes at)
    end
    finishDemote(pr, node, true, pr.cls == 'vehicle' and wearProps(node, pr.wear, readBack) or nil, why, false)
end

local function demote(pr, why)
    if pr.phase ~= 'live' then return false end
    pr.phase = 'demoting'
    CreateThread(function()
        local ok, err = pcall(demoteNow, pr, why)
        if not ok then
            Log.error('scene: demoting node %d failed: %s', pr.id, tostring(err))
            if P[pr.id] == pr then pr.phase = 'live' end
        end
    end)
    return true
end

--- A lost clone (D-C, RV4 F5): gone, or wrecked (health 0 after it synced). Never back at its old spot, never
--- repaired: the node stays where the clone was last seen, with its last known wear (clamped: it never burns). A wreck
--- whose policy says onDestroyed 'remove' then loses its node (after the hook).
local function lost(pr, node, wrecked)
    local reason = wrecked and 'destroyed' or 'lost'
    stats[reason] = stats[reason] + 1
    finishDemote(pr, node, true, pr.cls == 'vehicle' and wearProps(node, pr.wear, nil) or nil, reason, wrecked)
    if wrecked and policyOf(node).onDestroyed == 'remove' and store.get(pr.id) == node then
        local ok, err = Scene.remove(pr.id)
        if not ok then Log.warn('scene: removing destroyed node %d failed: %s', pr.id, tostring(err)) end
    end
end

--- D-B (RV4 F9): at the cap an enter / manual / action promotion makes room — the OLDEST idle proximity promotion
--- (live, unleased, at rest, no occupant) is demoted now, with its last known wear (no owner read). -> freed a slot?
local function evictIdle()
    local best
    for _, pr in pairs(P) do
        if pr.prox and pr.phase == 'live' and (not best or R.diff(pr.since, best.since) < 0)
            and store.get(pr.id) == pr.node and not leaseOf(pr.id) then
            local e = pr.entity
            if ours(e, pr.id, pr.snv) and (pr.node.motion or not moving(e))
                and not (pr.cls == 'vehicle' and occupied(e)) then
                best = pr
            end
        end
    end
    if not best then return false end
    stats.evicted = stats.evicted + 1
    sample(best, best.entity)
    finishDemote(best, best.node, true, best.cls == 'vehicle' and wearProps(best.node, best.wear, nil) or nil,
        'evicted', false)
    return true
end

--- Queues the promotion of `node`: trigger 'proximity' | 'enter' | 'damage' | 'action' | 'manual', by = src | nil.
--- -> true | nil, err ('class' 'parent' 'attach' 'model' 'audience' 'limit' 'area' 'unavailable')
local function promote(node, trigger, by, manual)
    local id = node.id
    if P[id] then return true end
    local cls, err = eligible(node)
    if not cls then return nil, err end
    if node.audience ~= nil and not manual then return nil, 'audience' end
    if stopping then return nil, 'unavailable' end
    local prox = trigger == 'proximity'
    if prox and proxCount >= PROX_MAX then
        stats.refused.share = stats.refused.share + 1
        logLimited('share', 'proximity promotion of node %d refused: Promote.ProximityShare (%d of %d) reached', id,
            PROX_MAX, MAX_ENTITIES)
        return nil, 'limit'
    end
    local area = cls == 'prop' and areaKey(node) or nil
    if area and (areas[area] or 0) >= MAX_PROPS_AREA then
        stats.refused.area = stats.refused.area + 1
        logLimited('area', 'promotion of prop node %d refused: Promote.MaxPropsPerArea (%d per 256 m) reached', id,
            MAX_PROPS_AREA)
        return nil, 'area'
    end
    if count >= MAX_ENTITIES and not (RESERVED[trigger] and evictIdle()) then
        stats.refused.limit = stats.refused.limit + 1
        logLimited('limit', 'promotion of node %d refused: Promote.MaxEntities (%d) reached', id, MAX_ENTITIES)
        return nil, 'limit'
    end
    if area then areas[area] = (areas[area] or 0) + 1 end
    count, nP = count + 1, nP + 1
    if prox then proxCount = proxCount + 1 end
    local pr = { id = id, node = node, cls = cls, phase = 'queued', trigger = trigger, by = by, prox = prox,
        area = area }
    P[id] = pr
    enqueue(pr)
    return true
end

--- A live networked entity becomes the clone of `node`: 'adopt' (R.promote.adopt — vehicles_park parks a live car
--- through the hand-off, RV6 F11) or 'rescue' (a doomed clone somebody got into, RV4 F12). Nothing one-shot (the
--- entity has its state); never refused for the budget (it exists anyway); the node takes its pose + bucket.
-- fxlint-disable-next-line C003 -- assigns the forward-declared local `adoptEntity` (doom's timer calls it)
adoptEntity = function(node, e, trigger)
    local id, cls, t = node.id, policyOf(node).cls, now()
    local hp = cls ~= 'prop' and GetEntityHealth(e) or 0
    local pr = { id = id, node = node, cls = cls, phase = 'live', trigger = trigger, entity = e, applied = true,
        since = t, due = R.add(t, CHECK_MS), home = poseRec(node), last = poseRec(node), healthSeen = (hp or 0) > 0 }
    count, nP = count + 1, nP + 1
    P[id] = pr
    pr.snv = store.bump(node)
    SetEntityOrphanMode(e, ORPHAN_KEEP)
    local st = Entity(e).state
    st:set('sn', id, true)
    st:set('snv', pr.snv, true)
    local r = node.rot or ZERO
    st:set('snCfg', cls == 'vehicle' and vehicleCfg(node, false) or snCfgOf(cls, node, r.x, r.y, r.z), true)
    pr.netId = NetworkGetNetworkIdFromEntity(e)
    byEntity[e] = pr
    node.promoted = { netId = pr.netId, entity = e, since = t, trigger = trigger }
    sample(pr, e)
    follow(pr, node, true, true)
    I.changed(node, 'promote', pr.netId)
    stats.promoted = stats.promoted + 1
    if trigger == 'adopt' then stats.adopted = stats.adopted + 1 end
    store.notify('promoted', node, pr.netId)
    wakeMonitor()
    return pr
end

--------------------------------------------------------------------------------
-- The monitor: every promoted node once a second, the proximity sweep in 10 slices (one thread, only with work)
--------------------------------------------------------------------------------

local buf, pt = {}, { x = 0.0, y = 0.0 }

--- The first loaded player of `bucket` within r of (x, y, z) — on foot only when `foot` — or nil.
local function anyone(bucket, x, y, z, r, foot)
    local grid = Core.PlayerGrid
    pt.x, pt.y = x, y
    local n = grid and grid.candidates(pt, r, buf) or 0
    local r2 = r * r
    for i = 1, n do
        local src = buf[i]
        local ped = GetPlayerPed(src)
        if ped and ped ~= 0 then
            local p = GetEntityCoords(ped)
            local dx, dy, dz = p.x - x, p.y - y, p.z - z
            if dx * dx + dy * dy + dz * dz <= r2 and GetPlayerRoutingBucket(src) == bucket
                and (not foot or GetVehiclePedIsIn(ped, false) == 0) then
                return src
            end
        end
    end
    return nil
end

local prox, proxN, proxAt, slice = {}, 0, {}, 0    -- the nodes whose policy has a proximity (swap-remove array)

local function proxAdd(node)
    local i = proxAt[node.id]
    if i then return end
    proxN = proxN + 1
    prox[proxN], proxAt[node.id] = node, proxN
end

local function proxDrop(i)
    local node, last = prox[i], prox[proxN]
    prox[i] = last
    prox[proxN], proxN = nil, proxN - 1
    proxAt[node.id] = nil
    if last ~= node then proxAt[last.id] = i end
end

--- A promoted node, once a second: gone / wrecked → lost(); else sample its clone (the node follows it) and check
--- the demote conditions — in the CLONE's bucket (D-D, RV4 F6 / RV6 F13).
local function check(pr, t)
    local node = pr.node
    if store.get(pr.id) ~= node then                 -- removed past the tap (a dropped load): the clone goes
        node.promoted = nil
        doom(pr)
        return release(pr)
    end
    local e = pr.entity
    if not ours(e, pr.id, pr.snv) then return lost(pr, node, false) end
    local wrecked = false
    if pr.cls ~= 'prop' then
        local hp = GetEntityHealth(e)
        if hp and hp > 0 then
            pr.healthSeen = true
        elseif pr.healthSeen then
            wrecked = true
        end
    end
    sample(pr, e)
    if wrecked then return lost(pr, node, true) end
    follow(pr, node, false, false)
    if leaseOf(pr.id) or (not node.motion and moving(e)) then   -- (a motion descriptor is its own authority)
        pr.restSince, pr.idleSince = nil, nil
        return
    end
    local pol = policyOf(node)
    pr.restSince = pr.restSince or t
    local L = pr.last
    local r = (isFinite(pol.proximity) and pol.proximity > 0) and pol.proximity or IDLE_RADIUS
    if anyone(L.bucket, L.x, L.y, L.z, r, false) then
        pr.idleSince = nil
        return
    end
    pr.idleSince = pr.idleSince or t
    local restMs = node.motion and 0 or (toint(pol.restMs) or 3000)
    if R.diff(t, pr.restSince) < restMs or R.diff(t, pr.idleSince) < (toint(pol.idleMs) or 20000) then return end
    if pr.cls == 'vehicle' and occupied(e) then
        pr.idleSince = nil
        return
    end
    demote(pr, 'rest')
end

--- A proximity node in a near cell with near-ring subscribers: a player within its proximity promotes it (on foot
--- for mode 'promote', any player for 'networked').
local function proximity(node, pol, t)
    if node.parent or node.attach or node.audience ~= nil then return end
    local c = node.cell
    if type(c) ~= 'table' or c.grid ~= 0 then return end
    local subs = R.interest.subscribers(node.bucket or 0, 0, c.key)
    if not subs then return end
    local near1 = false
    for _, ring in pairs(subs) do
        if ring == 1 then
            near1 = true
            break
        end
    end
    if not near1 then return end
    local x, y, z = store.pose(node, t)
    local src = anyone(node.bucket or 0, x, y, z, pol.proximity, pol.mode ~= 'networked')
    if src then promote(node, 'proximity', src) end
end

--- Slice k of SLICES looks at every SLICES-th node from k: each node once a second. A dropped node's slot takes
--- the last node, which its own slice meets later.
local function sweepProx(t)
    slice = slice % SLICES + 1
    local i = slice
    while i <= proxN do
        local node = prox[i]
        local pol = store.get(node.id) == node and policyOf(node) or nil
        if not (pol and pol.prox) then
            proxDrop(i)
        elseif not P[node.id] then
            proximity(node, pol, t)
        end
        i = i + SLICES
    end
end

local monitoring, due = false, {}             -- the promotions due this tick (collected first: a check fires hooks,
local function monitor()                      -- and a hook may promote — never a change to P inside pairs(P))
    while not stopping and (nP > 0 or proxN > 0) do
        Wait(TICK_MS)
        local t, n = now(), 0
        for _, pr in pairs(P) do
            if pr.phase == 'live' and R.diff(t, pr.due or t) >= 0 then
                n = n + 1
                due[n] = pr
            end
        end
        for i = 1, n do
            local pr = due[i]
            due[i] = nil
            if P[pr.id] == pr and pr.phase == 'live' then
                pr.due = R.add(t, CHECK_MS)
                local ok, err = pcall(check, pr, t)
                if not ok then Log.error('scene: promotion check of node %d failed: %s', pr.id, tostring(err)) end
            end
        end
        if proxN > 0 and store.loaded() then
            local ok, err = pcall(sweepProx, t)
            if not ok then Log.error('scene: proximity sweep failed: %s', tostring(err)) end
        end
    end
    monitoring = false
end

-- fxlint-disable-next-line C003 -- assigns the forward-declared local `wakeMonitor` (the spawn worker calls it)
wakeMonitor = function()
    if monitoring or stopping then return end
    monitoring = true
    CreateThread(monitor)
end

--------------------------------------------------------------------------------
-- The two index taps (wrapped, called through): placements feed the proximity set, removals drop clones
--------------------------------------------------------------------------------

local function tapPut(node)
    if type(node) ~= 'table' or node.parent or not node.id then return end
    if policyOf(node).prox then
        proxAdd(node)
        wakeMonitor()
    end
end

local function tapRemove(node, how)
    local pr = type(node) == 'table' and P[node.id] or nil
    if not pr or pr.node ~= node then return end
    if pr.phase == 'queued' or pr.phase == 'spawning' then
        pr.cancelled = true                          -- the worker deletes what it created once it exists
        return release(pr)
    end
    node.promoted = nil
    doom(pr)
    release(pr)
    stats.removed = stats.removed + 1
    if how == 1 or how == 'handover' then                     -- re-parented: a child now
        store.notify('demoted', node, demotedInfo(pr.cls, node, 'forced', false))
    end
end

local indexPut, indexRemove = I.put, I.remove
function I.put(node, ...)
    local ok = indexPut(node, ...)
    local fine, err = pcall(tapPut, node)
    if not fine then Log.error('scene: promote tap (put) failed: %s', tostring(err)) end
    return ok
end

function I.remove(node, how, ...)
    local fine, err = pcall(tapRemove, node, how)
    if not fine then Log.error('scene: promote tap (remove) failed: %s', tostring(err)) end
    return indexRemove(node, how, ...)
end

--------------------------------------------------------------------------------
-- The internal hand-off: server/scene_promote_api.lua (loaded right after this file) takes it once and clears it
--------------------------------------------------------------------------------

local X = { P = P, leases = leases, doomed = doomed, stats = stats, promote = promote, demote = demote,
    eligible = eligible, leaseOf = leaseOf, occupied = occupied, sample = sample, finishDemote = finishDemote,
    wearProps = wearProps, maxEntities = MAX_ENTITIES, proxMax = PROX_MAX }
function X.persistentCfg(node) return vehicleCfg(node, false) end     -- what the bag keeps once `once` is applied
function X.adopt(node, e) return adoptEntity(node, e, 'adopt') end    -- R.promote.adopt (validated there)
function X.stopping() return stopping end
function X.stop() stopping = true end                                 -- core stops: nothing is promoted any more
function X.cancel(pr)                                                 -- a queued / spawning promotion is dropped
    pr.cancelled = true
    release(pr)
end

--- onEntityBucketChange (D-D, RV4 F6 / RV6 F13): a clone moved to another bucket takes its node along at once (the
--- monitor compares GetEntityRoutingBucket every second as well). -> followed?
function X.onBucket(e)
    local pr = byEntity[e]
    if not pr or (pr.phase ~= 'live' and pr.phase ~= 'demoting') or store.get(pr.id) ~= pr.node
        or not ours(e, pr.id, pr.snv) then return false end
    sample(pr, e)
    return follow(pr, pr.node, false, true) == true
end

--- Core stops (RV4 F5 / F6, RV6 F13): every live clone's pose + bucket goes into its node — persisted (queued: the
--- store's writes never yield; core_db commits them after core is gone, §56.1) — before the pre-stop hooks run and
--- the clones are deleted (the store's own stop writer has run already).
function X.followAll()
    for _, pr in pairs(P) do
        local node, e = pr.node, pr.entity
        if (pr.phase == 'live' or pr.phase == 'demoting') and store.get(pr.id) == node and node.promoted
            and ours(e, pr.id, pr.snv) then
            local ok, err = pcall(function()
                sample(pr, e)
                follow(pr, node, true, true)
            end)
            if not ok then Log.error('scene: node %d could not take its clone\'s pose at the stop: %s', pr.id,
                tostring(err)) end
        end
    end
    local ok, err = pcall(store.flush)
    if not ok then Log.error('scene: the stop flush failed: %s', tostring(err)) end
end

--- -> promotions, budget slots, proximity slots, prop areas, proximity nodes, worker running, monitor running
function X.counts()
    local nAreas = 0
    for _ in pairs(areas) do nAreas = nAreas + 1 end
    return nP, count, proxCount, nAreas, proxN, working, monitoring
end

R.promoteInternal = X
