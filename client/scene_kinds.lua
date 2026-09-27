--[[ core — client/scene_kinds.lua — the built-in ENTITY kinds of Core.Scene: prop, vehicle, ped (DESIGN §55.12)
     Handlers the materialiser (client/scene_materializer.lua, `C.mat`) drives: it decides WHEN a node exists
     (radii, budgets, fades, visibility-safe deletes); these decide WHAT the game gets. Every entity is LOCAL
     (non-networked); OneSync only sees a node while it is promoted (§55.15, phase C).
     Also here, shared with client/scene_fx.lua and the plugin-kind bridge through `C.kinds`:
       - §55.14 interactions: one Core.Interactions entry per `interact` descriptor while the node exists (entity
         target for entity kinds, coords otherwise); a press sends `core:scene:interact (id, action)`; a
         descriptor's `prompt = { world, offsetZ, range }` picks the world dot or the text UI (§55.21.2), and a new
         list that differs only in labels (a drop's count) relabels the live prompts (Interactions.setLabel),
       - children ride their parent's entity (AttachEntityToEntity with offset/offrot/bone), attach targets
         (`{ p = src }` a player's ped, `{ n = netId }` a networked entity) the same way,
       - `applyVehicleProps(veh, props)` = Core.Vehicles.setPropsLocal (no network-control wait, §6.8),
       - prop `snap = 'ground'` (§55.21.2): PlaceObjectOnGroundProperly after create and after every re-placement,
         retried ≤ 5 times by the maintenance thread while the camera is within 20 m and the collision streams.
     Player attachments (§55.21.3): create() attaches to the player's ped; client/scene_movers.lua adopts that
     attachment and re-attaches when the ped handle changes (respawn, model swap).
     Handler contract (INTERFACES §5): create(node, ctx) -> entity | nil (nil = failed), update(node, handle,
     what, data) -> false when the change needs a RE-CREATE (model changed), anything else = applied in place;
     update re-reads node.fields and diffs them against what this file applied, so it does not depend on the
     exact `what`/`data` shape ('move' re-places, 'interact' re-syncs, 'attach' re-attaches); destroy(node,
     handle) deletes the entity (tolerates one the materialiser's fade-out already deleted) and its prompts.
     One maintenance thread exists only while work is pending (unfreezes waiting for the camera and collision,
     ped anim phase fix-ups one tick after TaskPlayAnim, ground snaps): 250 ms, no Wait(0), nothing per frame; each
     tick runs under pcall — an error is logged once per site (K.warnOnce) and the failing entry is dropped, never
     the thread.

     Natives (fxref + natives.json runtime names, 2026-09-26, apiset client; BOOL returns read by truthiness):
       CreateObjectNoOffset(modelHash, x, y, z, isNetwork, bScriptHostObj, dynamic),
       CreateVehicle(modelHash, x, y, z, heading, isNetwork, bScriptHostVeh),
       CreatePed(pedType, modelHash, x, y, z, heading, isNetwork, bScriptHostPed),
       IsModelAVehicle(model), IsModelAPed(model) (once per model hash: a wrong-type model fails its nodes),
       SetEntityRotation(entity, pitch, roll, yaw, rotationOrder, p5), SetEntityCoordsNoOffset(entity, x, y, z,
       xAxis, yAxis, zAxis), SetEntityHeading(entity, heading), SetEntityLodDist(entity, value),
       FreezeEntityPosition(entity, toggle), SetEntityCollision(entity, toggle, keepPhysics),
       SetEntityInvincible(entity, toggle, dontResetOnCleanup), SetDisableFragDamage(object, toggle),
       SetEntityVisible(entity, toggle, p2), SetObjectTextureVariation(object, textureVariation),
       PlayEntityAnim(entity, animName, animDict, blendDelta, loop, holdLastFrame, driveToPose, startPhase,
       animFlags), StopEntityAnim(entity, animation, animGroup, blendDelta), SetEntityAnimCurrentTime(entity,
       animDictionary, animName, phase 0..1), SetEntityAnimSpeed(entity, animDictionary, animName, speed),
       GetAnimDuration(animDict, animName) -> SECONDS (dict loaded in WARM; Rockstar header),
       SetVehicleDoorsLocked(vehicle, 2), SetVehicleEngineOn(vehicle, value, instantly, disableAutoStart),
       SetVehicleLights(vehicle, 1 forced off | 2 forced on), SetVehicleFullbeam(vehicle, toggle),
       SetVehicleSiren(vehicle, toggle), SetVehicleDoorOpen(vehicle, doorId, loose, openInstantly),
       SetVehicleDoorShut(vehicle, doorId, closeInstantly), SetVehicleDoorControl(vehicle, doorId, speed, angle),
       SetVehicleDirtLevel(vehicle, dirtLevel), SetVehicleNumberPlateText(vehicle, plateText),
       SetVehicleColours(vehicle, colorPrimary, colorSecondary) (the stable paint of a vehicle without colours),
       SetPedDefaultComponentVariation(ped), SetPedComponentVariation(ped, componentId, drawableId, textureId,
       paletteId), SetPedPropIndex(ped, componentId, drawableId, textureId, attach, p5), ClearPedProp(ped, propId,
       p2), TaskStartScenarioInPlace(ped, scenarioName, unkDelay, playEnterAnim), TaskPlayAnim(ped, dict, clip,
       blendIn, blendOut, duration, flag, startPhase, phaseControlled, ikFlags, allowOverrideCloneUpdate),
       ClearPedTasksImmediately(ped), GiveWeaponToPed(ped, weaponHash, ammoCount, isHidden, bForceInHand),
       RemoveAllPedWeapons(ped, p1), SetBlockingOfNonTemporaryEvents(ped, toggle), SetPedCanRagdoll(ped, toggle),
       SetEntityMaxHealth(entity, value), SetEntityHealth(entity, health, instigator, weaponType),
       AttachEntityToEntity(entity1, entity2, boneIndex, x, y, z, rx, ry, rz, detachWhenDead, detachWhenRagdoll,
       activeCollisions, useBasicAttachIfPed, rotOrder 2, attachOffsetIsRelative, markNoLongerNeeded) — all 16,
       PlaceObjectOnGroundProperly(object) -> BOOL,
       DetachEntity(entity, applyVelocity, noCollisionUntilClear), GetEntityBoneIndexByName(entity, boneName),
       GetPedBoneIndex(ped, boneId), GetEntityType(entity), GetPlayerFromServerId(serverId), GetPlayerPed(player),
       NetworkDoesEntityExistWithNetworkId(netId) (always before NetworkGetEntityFromNetworkId(netId)),
       HasCollisionLoadedAroundEntity(entity), DoesEntityExist(entity), DeleteEntity(entity), GetHashKey (via
       Core.Utils.hash), GetGameTimer(), GetFinalRenderedCamCoord() (only without C.mat.camera),
       GetCurrentResourceName().
]]

local C = CoreSceneRuntime
assert(C and C.mat, 'client/scene_kinds.lua needs client/scene_materializer.lua first')

local Clock = Core.Clock
local Utils = Core.Utils
local floor, abs, mtype, tointeger = math.floor, math.abs, math.type, math.tointeger

local cfg = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
local radiiCfg = type(cfg.Radii) == 'table' and cfg.Radii or {}
local ipCfg = type(Config) == 'table' and type(Config.Interactions) == 'table' and Config.Interactions or {}
local wpCfg = type(ipCfg.WorldPrompt) == 'table' and ipCfg.WorldPrompt or {}

local BAND <const> = tonumber(radiiCfg.Band) or 20
local SMALL_BAND <const> = tonumber(radiiCfg.SmallBand) or 5
local MARGIN <const> = tonumber(radiiCfg.Margin) or 10
local PROP_CAP <const> = tonumber(radiiCfg.PropCap) or 500
local WP_ENABLED <const> = wpCfg.Enabled == true
local MAX_INTERACT <const> = 4          -- §55.14: ≤ 4 descriptors per node
local LOCAL_PHYSICS_RANGE2 <const> = 30.0 * 30.0   -- §55.11: 'local' physics props wake within 30 m
local WAKE_RANGE2 <const> = 100.0 * 100.0          -- other unfrozen entities: the ground collision streams near us
local SNAP_RANGE2 <const> = 20.0 * 20.0            -- snap = 'ground': placement retries while the camera is this near
local SNAP_TRIES <const> = 5                       -- ... at most this many, then the object stays where it landed
local TICK_MS <const> = 250             -- the maintenance thread's cadence (only while work is pending)
local PENDING_MAX_MS <const> = 30000    -- 30 s NEAR the camera without collision: the entity stays frozen
local DEFAULT_LOD <const> = 100         -- §55.12: prop lod when the model-info chain gave none
local EMPTY <const> = setmetatable({}, { __newindex = function() error('read-only', 2) end })

local K = {}              -- C.kinds
local warned = {}         -- error sites already logged (K.warnOnce)
local S = {}              -- node id -> the applied state of its entity
local modelOk = {}        -- model hash -> 'prop' | 'vehicle' | 'ped' (what IsModelA* said, asked once)
local animDur = {}        -- dict .. '/' .. clip -> duration in ms (GetAnimDuration, once per clip)
local stopped = false

--------------------------------------------------------------------------------
-- small readers (fields arrive decoded from msgpack: integer keys survive, but accept strings too)
--------------------------------------------------------------------------------

local function int(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return tointeger(floor(v))
end

local function num(v, default, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return default end
    if lo and v < lo then return lo end
    if hi and v > hi then return hi end
    return v + 0.0
end

local function flag(v, default)
    if v == nil then return default end
    return v == true
end
K.int, K.num, K.flag = int, num, flag

--- Logs an error of a loop / pass once per site (a guarded loop keeps running; the log must not flood).
function K.warnOnce(site, err)
    if warned[site] then return end
    warned[site] = true
    local log = Core.Log
    if log and log.error then
        log.error('scene %s failed (logged once): %s', site, tostring(err))
    else
        print(('[core] scene %s failed (logged once): %s'):format(site, tostring(err)))
    end
end

--- A 32-bit hash in GetHashKey's convention: a SIGNED int32 (-2^31..2^31-1). Unsigned forms fold into it, so one
--- model is one key of the model caches and budgets however it was written. nil outside 32 bits.
local function signed32(h)
    if h < -0x80000000 or h > 0xFFFFFFFF then return nil end
    if h >= 0x80000000 then return h - 0x100000000 end
    return h
end

--- A model name or hash -> hash (integer), nil when unusable. '0x' + 1..8 hex digits (server/remote.lua writes
--- integer hashes as '0x%08X': the scene's model field takes strings) is that hash, not a name.
local function hashOf(model)
    if mtype(model) == 'integer' then return signed32(model) end
    if type(model) == 'number' then
        local i = int(model)
        return i and signed32(i)
    end
    if type(model) == 'string' and model ~= '' then
        local hex = model:match('^0[xX](%x%x?%x?%x?%x?%x?%x?%x?)$')
        if hex then return signed32(tointeger(tonumber(hex, 16))) end
        return Utils.hash(model)
    end
    return nil
end
K.hashOf = hashOf

--- x, y, z of a { x, y, z } or { [1], [2], [3] } table (offsets, doors, colours), with a default.
local function vec(t, dx, dy, dz)
    if type(t) ~= 'table' then return dx, dy, dz end
    return num(t.x or t[1], dx), num(t.y or t[2], dy), num(t.z or t[3], dz)
end
K.vec = vec

--- The pose a handler creates at: the materialiser's ctx (motion-evaluated, children composed) or the node.
local function pose(node, ctx)
    if type(ctx) == 'table' and ctx.x then
        return ctx.x + 0.0, ctx.y + 0.0, ctx.z + 0.0, (ctx.rx or 0) + 0.0, (ctx.ry or 0) + 0.0, (ctx.rz or 0) + 0.0
    end
    return (node.x or 0) + 0.0, (node.y or 0) + 0.0, (node.z or 0) + 0.0,
        (node.rx or 0) + 0.0, (node.ry or 0) + 0.0, (node.rz or 0) + 0.0
end
K.pose = pose

--- Is `hash` a model of `class` ('prop' | 'vehicle' | 'ped')? Asked once per model hash (§52 hardening).
local function modelIs(hash, class)
    local kind = modelOk[hash]
    if not kind then
        kind = IsModelAVehicle(hash) and 'vehicle' or (IsModelAPed(hash) and 'ped' or 'prop')
        modelOk[hash] = kind
    end
    return kind == class
end

local function exists(e)
    return mtype(e) == 'integer' and e ~= 0 and DoesEntityExist(e) and true or false
end
K.exists = exists

--- Signed ms since `t0` on the shared clock (wrap-safe).
local function since(t0)
    local now = Clock.now()
    if Clock.diff then return Clock.diff(now, t0) end
    return now - t0
end

--------------------------------------------------------------------------------
-- clock-phased animations (§55.9: animation phases are functions of Core.Clock)
--------------------------------------------------------------------------------

--- Duration of a clip in ms (GetAnimDuration answers SECONDS; the dict is loaded in WARM). 0 = unknown
--- (not cached, so a clip asked before its dict landed is asked again).
local function durationMs(dict, clip)
    local key = dict .. '/' .. clip
    local d = animDur[key]
    if d then return d end
    d = (tonumber(GetAnimDuration(dict, clip)) or 0) * 1000.0
    if d ~= d or d <= 0 then return 0 end
    animDur[key] = d
    return d
end
K.durationMs = durationMs

--- Phase of `anim` = { dict, clip, loop = true, rate = 1, t0 } after `elapsedMs` since its t0 on the shared
--- clock: ((elapsed × rate) / duration) mod 1 for a loop — continuous through t0, so every client agrees at
--- every instant — clamped to [0, 1] when `loop == false`; 0 without a t0 or a known duration.
local function phaseAt(anim, durMs, elapsedMs)
    if not durMs or durMs <= 0 or not elapsedMs then return 0.0 end
    local p = elapsedMs * num(anim.rate, 1.0, 0.0, 16.0) / durMs
    if anim.loop == false then return p < 0 and 0.0 or (p > 1 and 1.0 or p + 0.0) end
    return (p % 1.0) + 0.0
end
K.phaseAt = phaseAt

--- The anim's phase right now (Clock.now()), 0 when it has no t0.
local function animPhase(anim, durMs)
    local t0 = int(anim.t0)
    if not t0 then return 0.0 end
    return phaseAt(anim, durMs, since(t0))
end
K.animPhase = animPhase

--- A usable anim descriptor ({ dict, clip } strings) or nil.
local function animOf(v)
    if type(v) ~= 'table' or type(v.dict) ~= 'string' or v.dict == '' or type(v.clip) ~= 'string'
        or v.clip == '' then return nil end
    return v
end

--- What identifies a playing anim: a change of any of these restarts it.
local function animKey(a)
    if not a then return nil end
    return ('%s/%s/%s/%s/%s/%s'):format(a.dict, a.clip, tostring(a.loop), tostring(a.rate), tostring(a.t0),
        tostring(a.flag))
end

--------------------------------------------------------------------------------
-- §55.14 interactions on nodes (every kind; client/scene_fx.lua and the plugin bridge call these too)
--------------------------------------------------------------------------------

local IX = {}   -- node id -> { list, target, x, y, z, n, [1..n] = Core.Interactions ids, sig = {}, label = {} }

--- Removes every prompt of node `id`.
function K.clearInteract(id)
    local r = IX[id]
    if not r then return end
    IX[id] = nil
    local remove = Core.Interactions.remove
    for i = 1, r.n do remove(r[i]) end
end

--- The descriptor's `prompt = { world, offsetZ, range }` (§55.21.2) as Core.Interactions' `worldPrompt` (§6.7):
--- false = the text UI instead of the world dot; a table = the dot (offsetZ lifts its anchor, range = how far it is
--- drawn); nil = Config.Interactions.WorldPrompt decides, as without the option.
local function promptOf(d)
    local pr = type(d.prompt) == 'table' and d.prompt or nil
    local world = pr and pr.world
    if world == false then return false end
    if world ~= true and not WP_ENABLED then return nil end
    return { icon = d.icon, description = d.description, offsetZ = pr and num(pr.offsetZ, nil, -10.0, 10.0) or nil,
        range = pr and num(pr.range, nil, 0.5, 100.0) or nil }
end

--- Everything of a descriptor but its label: when only labels differ, the live prompts are relabelled in place.
local function sigOf(d)
    local pr = type(d.prompt) == 'table' and d.prompt or EMPTY
    return ('%s|%s|%s|%s|%s|%s|%s|%s'):format(d.action, tostring(d.distance), tostring(d.cooldownMs),
        tostring(d.icon), tostring(d.description), tostring(pr.world), tostring(pr.offsetZ), tostring(pr.range))
end

local function labelOf(d)
    return (type(d.label) == 'string' and d.label ~= '') and d.label or d.action
end

local function usable(d)
    return type(d) == 'table' and type(d.action) == 'string' and d.action ~= ''
end

local function addDescriptor(id, d, target, x, y, z)
    local action = d.action
    local opts = {
        radius = num(d.distance, 2.0, 0.5, 25.0),
        label = labelOf(d),
        cooldown = int(d.cooldownMs) or 500,
        worldPrompt = promptOf(d),
        data = { scene = id, action = action },
        -- the press is only a request: the server re-checks bucket, audience, perm and distance (§55.14)
        onInteract = function() Core.Net.emit('core:scene:interact', id, action) end,
    }
    if target then opts.entity = target else opts.coords = vector3(x, y, z) end
    return Core.Interactions.add(opts)
end

--- A new descriptor list that differs only in labels (a drop's count, §55.21.2): Core.Interactions.setLabel on the
--- live prompts, nothing re-created. false when anything else differs.
local function relabel(r, list)
    local k = 0
    for i = 1, math.min(#list, MAX_INTERACT) do
        local d = list[i]
        if usable(d) then
            k = k + 1
            if k > r.n or r.sig[k] ~= sigOf(d) then return false end
        end
    end
    if k ~= r.n then return false end
    k = 0
    for i = 1, math.min(#list, MAX_INTERACT) do
        local d = list[i]
        if usable(d) then
            k = k + 1
            local label = labelOf(d)
            if label ~= r.label[k] then
                Core.Interactions.setLabel(r[k], label)
                r.label[k] = label
            end
        end
    end
    r.list = list
    return true
end

--- (Re)creates node's prompts when its descriptors (`node.interact`, replaced whole by a SET), its entity or
--- its position changed; label-only changes relabel the live prompts. `target` = the entity (entity kinds) or nil
--- (a point at x, y, z).
function K.syncInteract(node, target, x, y, z)
    local id, list = node.id, node.interact
    local r = IX[id]
    local same = r and r.target == target and (target or (r.x == x and r.y == y and r.z == z))
    if same and r.list == list then return end
    if same and type(list) == 'table' and relabel(r, list) then return end
    if r then K.clearInteract(id) end
    if type(list) ~= 'table' or #list == 0 then return end
    r = { list = list, target = target, x = x, y = y, z = z, n = 0, sig = {}, label = {} }
    for i = 1, math.min(#list, MAX_INTERACT) do
        local d = list[i]
        if usable(d) then
            local iid = addDescriptor(id, d, target, x, y, z)
            if iid then
                r.n = r.n + 1
                r[r.n], r.sig[r.n], r.label[r.n] = iid, sigOf(d), labelOf(d)
            end
        end
    end
    if r.n > 0 then IX[id] = r end
end

--- Number of live prompts of node `id` (tests, stats).
function K.interactCount(id)
    local r = IX[id]
    return r and r.n or 0
end

--------------------------------------------------------------------------------
-- riding: children on their parent's entity, attach targets (players, networked entities)
--------------------------------------------------------------------------------

local function boneOf(anchor, bone)
    if type(bone) == 'string' and bone ~= '' then
        local i = GetEntityBoneIndexByName(anchor, bone)
        return (mtype(i) == 'integer' and i >= 0) and i or 0
    end
    local b = int(bone)
    if not b or b < 0 then return 0 end
    if GetEntityType(anchor) == 1 then return GetPedBoneIndex(anchor, b) end   -- a ped bone TAG (57005 …)
    return b
end
K.boneOf = boneOf

--- The entity `node` rides: its parent node's entity (children), else its attach target (`{ p = src }` /
--- `{ n = netId }`, or the long forms `player`/`net`/`node`). nil = none, or not on this client right now.
function K.anchorOf(node)
    local parent = node.parent
    if parent and parent ~= 0 then
        local h = C.mat.handleOf(parent)
        return exists(h) and h or nil
    end
    local a = node.attach
    if type(a) ~= 'table' then return nil end
    local src = int(a.p or a.player)
    if src then
        local player = GetPlayerFromServerId(src)
        if not player or player == -1 then return nil end
        local ped = GetPlayerPed(player)
        return exists(ped) and ped or nil
    end
    local net = int(a.n or a.net)
    if net and net > 0 then
        if not NetworkDoesEntityExistWithNetworkId(net) then return nil end
        local e = NetworkGetEntityFromNetworkId(net)
        return exists(e) and e or nil
    end
    local other = int(a.node)
    if other then
        local h = C.mat.handleOf(other)
        return exists(h) and h or nil
    end
    return nil
end

--- Attaches entity `e` of `node` to its anchor (offset/offrot relative, in the node's rotation order: `rotOrder`
--- 0..5 from the wire, else the engine's 2). The isPed argument is true for a ped node AND for anything attached to
--- a PED (a player's attachment: the pre-scene applier and the materialiser's attach pass it, review RV6 F10 — "pitch
--- does not work when false"). -> anchor | nil
function K.attach(node, e, isPed)
    local anchor = K.anchorOf(node)
    if not anchor or anchor == e then return nil end
    local ox, oy, oz = vec(node.offset, 0.0, 0.0, 0.0)
    local rx, ry, rz = vec(node.offrot, 0.0, 0.0, 0.0)
    AttachEntityToEntity(e, anchor, boneOf(anchor, node.bone), ox, oy, oz, rx, ry, rz,
        false, false, false, isPed == true or GetEntityType(anchor) == 1, node.rotOrder or 2, true, false)
    return anchor
end

--------------------------------------------------------------------------------
-- maintenance: unfreezes waiting for collision, anim phase fix-ups (thread only while pending)
--------------------------------------------------------------------------------

local wake, nWake = {}, 0   -- node id -> { e, s, near, at }: frozen until collision (and camera ≤ 30 m)
local fix, nFix = {}, 0     -- node id -> { e, anim, dict, clip }: re-phase once the task has started the clip
local snaps, nSnap = {}, 0  -- node id -> { e, s, tries }: snap = 'ground' waiting for the camera / collision
local ticking = false

local function camera()
    local cam = C.mat.camera
    if cam then return cam() end
    local c = GetFinalRenderedCamCoord()
    return c.x, c.y, c.z
end

local function drop(id)
    if wake[id] then wake[id], nWake = nil, nWake - 1 end
    if fix[id] then fix[id], nFix = nil, nFix - 1 end
    if snaps[id] then snaps[id], nSnap = nil, nSnap - 1 end
end

--- One pending unfreeze: nothing happens while the camera is far (the entity waits for it, and only time spent
--- near counts towards the 30 s timeout), then FreezeEntityPosition(e, false) once the ground collision is there.
local function wakeOne(id, w, now, cx, cy, cz)
    local e, s = w.e, w.s
    if not exists(e) or now - w.at > PENDING_MAX_MS then
        wake[id], nWake = nil, nWake - 1   -- gone, or 30 s near the camera without collision: stays frozen
        return
    end
    local dx, dy, dz = s.x - cx, s.y - cy, s.z - cz   -- frozen where its state says: no native for the distance
    if dx * dx + dy * dy + dz * dz > (w.near and LOCAL_PHYSICS_RANGE2 or WAKE_RANGE2) then
        w.at = now
        return
    end
    if HasCollisionLoadedAroundEntity(e) then
        FreezeEntityPosition(e, false)
        wake[id], nWake = nil, nWake - 1
    end
end

local function fixOne(id, f)
    fix[id], nFix = nil, nFix - 1
    if exists(f.e) then
        local dur = durationMs(f.dict, f.clip)
        SetEntityAnimCurrentTime(f.e, f.dict, f.clip, animPhase(f.anim, dur))
        local rate = num(f.anim.rate, 1.0, 0.0, 16.0)
        if rate ~= 1.0 then SetEntityAnimSpeed(f.e, f.dict, f.clip, rate) end
    end
end

--- snap = 'ground' (§55.21.2): PlaceObjectOnGroundProperly while the camera is within 20 m — done once the ground
--- collision was loaded for a placement, or after SNAP_TRIES tries (the object stays where it landed). Far away
--- nothing is tried (and no try is spent). Purely client placement: nothing goes back to the server.
local function snapOne(id, sn, cx, cy, cz)
    local e, s = sn.e, sn.s
    if not exists(e) then
        snaps[id], nSnap = nil, nSnap - 1
        return
    end
    local dx, dy, dz = s.x - cx, s.y - cy, s.z - cz
    if dx * dx + dy * dy + dz * dz > SNAP_RANGE2 then return end
    sn.tries = sn.tries + 1
    local loaded = HasCollisionLoadedAroundEntity(e)
    local placed = PlaceObjectOnGroundProperly(e)
    if (loaded and placed) or sn.tries >= SNAP_TRIES then snaps[id], nSnap = nil, nSnap - 1 end
end

local function tickOnce()
    local now = GetGameTimer()
    local cx, cy, cz = camera()
    for id, w in pairs(wake) do wakeOne(id, w, now, cx, cy, cz) end
    for id, f in pairs(fix) do fixOne(id, f) end
    for id, sn in pairs(snaps) do snapOne(id, sn, cx, cy, cz) end
end

--- A tick failed: every entry once more on its own; one that fails is dropped (its entity keeps its state), so a
--- bad entry never stops the others — nor the thread.
local function isolate()
    local now = GetGameTimer()
    local cx, cy, cz = camera()
    for id, w in pairs(wake) do
        if not pcall(wakeOne, id, w, now, cx, cy, cz) and wake[id] then wake[id], nWake = nil, nWake - 1 end
    end
    for id, f in pairs(fix) do
        if not pcall(fixOne, id, f) and fix[id] then fix[id], nFix = nil, nFix - 1 end
    end
    for id, sn in pairs(snaps) do
        if not pcall(snapOne, id, sn, cx, cy, cz) and snaps[id] then snaps[id], nSnap = nil, nSnap - 1 end
    end
end

local function startTicking()
    if ticking or stopped then return end
    ticking = true
    CreateThread(function()
        while nWake + nFix + nSnap > 0 and not stopped do
            Wait(TICK_MS)
            local ok, err = pcall(tickOnce)
            if not ok then
                K.warnOnce('kinds maintenance', err)
                local ok2, err2 = pcall(isolate)
                if not ok2 then   -- not even the camera: give the pending work up rather than fail every tick
                    K.warnOnce('kinds maintenance (isolation)', err2)
                    wake, fix, snaps, nWake, nFix, nSnap = {}, {}, {}, 0, 0, 0
                end
            end
        end
        ticking = false
    end)
end

--- Keeps entity `e` frozen until the ground collision around it is loaded (and, `near`, the camera is
--- within 30 m — §55.11 'local' physics props), then unfreezes it.
local function wakeLater(id, e, s, near)
    if not wake[id] then nWake = nWake + 1 end
    wake[id] = { e = e, s = s, near = near == true, at = GetGameTimer() }
    startTicking()
end

local function fixLater(id, e, anim)
    if not fix[id] then nFix = nFix + 1 end
    fix[id] = { e = e, anim = anim, dict = anim.dict, clip = anim.clip }
    startTicking()
end

--- snap = 'ground': one placement now; when the ground collision was not loaded for it, the maintenance thread
--- tries again (camera within 20 m, <= SNAP_TRIES).
local function snapLater(id, e, s)
    local loaded = HasCollisionLoadedAroundEntity(e)
    local placed = PlaceObjectOnGroundProperly(e)
    if loaded and placed then
        if snaps[id] then snaps[id], nSnap = nil, nSnap - 1 end
        return
    end
    if not snaps[id] then nSnap = nSnap + 1 end
    snaps[id] = { e = e, s = s, tries = 0 }
    startTicking()
end

--- Pending work (tests, stats): unfreezes, anim fix-ups, ground snaps.
function K.pending() return nWake, nFix, nSnap end

--------------------------------------------------------------------------------
-- prop
--------------------------------------------------------------------------------

--- The lodDist to give a prop: the model's (`fields.lod`, server-filled), shortened when L·S + B + margin
--- would pass Radii.PropCap so the engine's fade band still lands inside our create radius (§55.11).
local function propLod(f)
    local lod = int(f.lod) or DEFAULT_LOD
    if lod < 1 then lod = DEFAULT_LOD end
    local s = C.mat.lodScale and tonumber(C.mat.lodScale()) or 1.0
    if not s or s <= 0 then s = 1.0 end
    local band = lod <= 20 and SMALL_BAND or BAND
    if lod * s + band + MARGIN > PROP_CAP then
        lod = floor((PROP_CAP - band - MARGIN) / s)
        if lod < 1 then lod = 1 end
    end
    return lod
end
K.propLod = propLod

local function propPlayAnim(e, a)
    local dur = durationMs(a.dict, a.clip)
    local phase = animPhase(a, dur)
    PlayEntityAnim(e, a.clip, a.dict, 1000.0, a.loop ~= false, true, false, phase, 0)
    SetEntityAnimCurrentTime(e, a.dict, a.clip, phase)
    local rate = num(a.rate, 1.0, 0.0, 16.0)
    if rate ~= 1.0 then SetEntityAnimSpeed(e, a.dict, a.clip, rate) end
end

--- Applies the prop fields that differ from `s` (the applied state; a fresh state applies non-defaults only).
--- Freezing is applyHold's (below).
local function propApply(_, e, s, f, fresh)
    local collision = flag(f.collision, true)
    if collision ~= s.collision then
        if not collision or not fresh then SetEntityCollision(e, collision, false) end
        s.collision = collision
    end
    local invincible = flag(f.invincible, false)
    if invincible ~= s.invincible then
        if invincible or not fresh then
            SetEntityInvincible(e, invincible, false)
            SetDisableFragDamage(e, invincible)
        end
        s.invincible = invincible
    end
    local visible = flag(f.visible, true)
    if visible ~= s.visible then
        if not visible or not fresh then SetEntityVisible(e, visible, false) end
        s.visible = visible
    end
    local tint = int(f.tint)
    if tint and (tint < 0 or tint > 15) then tint = nil end
    if tint ~= s.tint then
        if tint or not fresh then SetObjectTextureVariation(e, tint or 0) end
        s.tint = tint
    end
    local lod = propLod(f)
    if lod ~= s.lod then
        SetEntityLodDist(e, lod)
        s.lod = lod
    end
    local a = animOf(f.anim)
    local key = animKey(a)
    if key ~= s.animKey then
        if s.anim then StopEntityAnim(e, s.anim.clip, s.anim.dict, 1000.0) end
        if a then propPlayAnim(e, a) end
        s.anim, s.animKey = a, key
    end
end

--- 'frozen' | 'wake' | 'wakeNear': how an entity holds still. Everything is CREATED frozen (a dynamic entity
--- created before its ground collision loaded falls through the map, R3 §6.4); 'wake' unfreezes it once the
--- camera is within 100 m and the collision is there, 'wakeNear' within 30 m (§55.11 physics = 'local').
--- Far away an entity waits as long as it takes; only 30 s NEAR the camera without collision give up.
local function holdMode(node, f, class)
    if node.motion ~= nil then return 'frozen' end         -- movers are placed kinematically (§55.9)
    if class == 'prop' then
        local physics = f.physics
        if physics == 'local' then return 'wakeNear' end
        if physics == 'promote' then return 'frozen' end   -- a promoted clone moves; the local copy never does
    end
    return flag(f.frozen, true) and 'frozen' or 'wake'
end

local function applyHold(id, e, s, mode, fresh)
    if mode == s.hold then return end
    if fresh or mode == 'frozen' then FreezeEntityPosition(e, true) end
    if mode == 'frozen' then
        if wake[id] then wake[id], nWake = nil, nWake - 1 end
    else
        wakeLater(id, e, s, mode == 'wakeNear')
    end
    s.hold = mode
end

--- Re-places an entity at the node's (new) base pose; riders stay on their anchor.
local function moveTo(node, e, s, isPed)
    if s.anchor then return end
    s.x, s.y, s.z = (node.x or 0) + 0.0, (node.y or 0) + 0.0, (node.z or 0) + 0.0
    SetEntityCoordsNoOffset(e, s.x, s.y, s.z, false, false, false)
    if isPed then
        SetEntityHeading(e, (node.rz or 0) + 0.0)
    else
        SetEntityRotation(e, (node.rx or 0) + 0.0, (node.ry or 0) + 0.0, (node.rz or 0) + 0.0, 2, false)
    end
end

--- An attach change: off the old anchor, onto the new one (or back to the node's pose).
local function reattach(node, e, s, isPed)
    if s.anchor then
        DetachEntity(e, false, false)
        s.anchor = nil
    end
    s.anchor = K.attach(node, e, isPed)
    if not s.anchor then moveTo(node, e, s, isPed) end
end

--- snap = 'ground' for a prop that neither rides an anchor nor moves by itself: placed on create and after every
--- re-placement ('move', a detach); switched off -> back at the authored pose.
local function propSnap(node, e, s, f, placed)
    local want = f.snap == 'ground' and not s.anchor and node.motion == nil
    if want and (placed or not s.snap) then
        snapLater(node.id, e, s)
    elseif not want and s.snap then
        if snaps[node.id] then snaps[node.id], nSnap = nil, nSnap - 1 end
        if not s.anchor then
            s.x, s.y, s.z = (node.x or 0) + 0.0, (node.y or 0) + 0.0, (node.z or 0) + 0.0
            SetEntityCoordsNoOffset(e, s.x, s.y, s.z, false, false, false)
            SetEntityRotation(e, (node.rx or 0) + 0.0, (node.ry or 0) + 0.0, (node.rz or 0) + 0.0, 2, false)
        end
    end
    s.snap = want
end

local function newState(node, class, e, hash, x, y, z)
    local s = { class = class, e = e, hash = hash, x = x, y = y, z = z }
    S[node.id] = s
    return s
end

--- The common tail of update(): model check, the kind's field diff, then pose/attach/prompts.
local function updateEntity(node, e, what, class, applyFn, isPed)
    local s = S[node.id]
    if not s or s.e ~= e or not exists(e) then return false end
    local f = node.fields or EMPTY
    if hashOf(f.model) ~= s.hash then return false end   -- another model: the materialiser re-creates
    applyFn(node, e, s, f, false)
    if what == 'attach' then
        reattach(node, e, s, isPed)
    elseif what == 'move' then
        moveTo(node, e, s, isPed)
    end
    if class == 'prop' then propSnap(node, e, s, f, what == 'move' or what == 'attach') end
    K.syncInteract(node, e)
    return true
end

--- Deletes `e` (unless a fade-out already did) and, when it is the node's CURRENT entity, its state, prompts
--- and pending work — a stale handle never wipes the state of the entity that replaced it.
local function destroyEntity(node, e)
    local id = node.id
    local s = S[id]
    if not s or e == nil or s.e == e then
        S[id] = nil
        K.clearInteract(id)
        drop(id)
    end
    if exists(e) then DeleteEntity(e) end
end

local NO_ASSETS <const> = {}

local function modelAssets(node, withAnim)
    local f = node.fields or EMPTY
    local hash = hashOf(f.model)
    if not hash then return NO_ASSETS end
    local list = { { type = 'model', hash = hash } }
    local a = withAnim and animOf(f.anim) or nil
    if a then list[2] = { type = 'anim', name = a.dict } end
    return list
end

local PROP = { class = 'prop', budget = 'props', fade = 'engine' }

function PROP.assets(node) return modelAssets(node, true) end

function PROP.create(node, ctx)
    local f = node.fields or EMPTY
    local hash = hashOf(f.model)
    if not hash or not modelIs(hash, 'prop') then return nil end
    local x, y, z, rx, ry, rz = pose(node, ctx)
    local e = CreateObjectNoOffset(hash, x, y, z, false, false, false)
    if not e or e == 0 then return nil end
    SetEntityRotation(e, rx, ry, rz, 2, false)
    local s = newState(node, 'prop', e, hash, x, y, z)
    applyHold(node.id, e, s, holdMode(node, f, 'prop'), true)
    propApply(node, e, s, f, true)
    s.anchor = K.attach(node, e, false)
    propSnap(node, e, s, f, true)
    K.syncInteract(node, e)
    return e
end

local function propFields(node, e, s, f, fresh)
    applyHold(node.id, e, s, holdMode(node, f, 'prop'), fresh)
    propApply(node, e, s, f, fresh)
end

function PROP.update(node, e, what) return updateEntity(node, e, what, 'prop', propFields, false) end

function PROP.place(node, e, x, y, z, rx, ry, rz)
    local s = S[node.id]
    if s then
        if s.anchor then return end
        s.x, s.y, s.z = x, y, z
    end
    SetEntityCoordsNoOffset(e, x, y, z, false, false, false)
    SetEntityRotation(e, rx, ry, rz, 2, false)
end

PROP.destroy = destroyEntity

--------------------------------------------------------------------------------
-- vehicle (a local copy: always locked — entering goes through promotion, §55.15)
--------------------------------------------------------------------------------

--- Core.Vehicles.setPropsLocal: the §6.8 props apply without the network-control wait (local entities).
function K.applyVehicleProps(veh, props)
    local vehicles = Core.Vehicles
    if not vehicles or not vehicles.setPropsLocal then return false end
    return vehicles.setPropsLocal(veh, props)
end

local MAX_DOOR <const> = 7

--- doors = { [0..7] = open ratio 0..1 }: ≥ 0.95 open, ≤ 0.05 shut, else SetVehicleDoorControl to the ratio.
local function vehicleDoors(veh, doors, s)
    local applied = s.doors
    if not applied then
        applied = {}
        s.doors = applied
    end
    local has = type(doors) == 'table'
    for door = 0, MAX_DOOR do
        local r = has and num(doors[door] or doors[tostring(door)], nil, 0.0, 1.0) or nil
        local was = applied[door]
        if r ~= was then
            if r and r >= 0.95 then
                SetVehicleDoorOpen(veh, door, false, true)
            elseif r and r > 0.05 then
                SetVehicleDoorControl(veh, door, 5, r)
            elseif was and was > 0.05 then
                SetVehicleDoorShut(veh, door, true)
            end
            applied[door] = r
        end
    end
end

--- The stable paint pair of node `id`: lib/scene/shared.lua's paintOf — the SAME list the server paints a promoted
--- clone with (server/scene_promote.lua), so a vehicle without colours of its own keeps them through the swap.
--- nil, nil when the lib does not have it (the vehicle keeps the game's colours).
local function paintOf(id)
    local scene = Core.Scene
    local fn = scene and scene.paintOf
    if type(fn) ~= 'function' then return nil, nil end
    return fn(id)
end
K.paintOf = paintOf

local function vehicleApply(node, veh, s, f, fresh)
    if fresh or f.props ~= s.props then   -- a SET replaces the whole field: apply it whole, keys present only
        local props = type(f.props) == 'table' and f.props or nil
        if not (props and props.colorPrimary ~= nil) then   -- no colours of its own (the server's rule):
            local primary, secondary = paintOf(node.id)      -- the clone's pair, BEFORE the props like its owner
            if primary then SetVehicleColours(veh, primary, secondary) end
        end
        if props then K.applyVehicleProps(veh, props) end
        s.props, s.plate = f.props, nil   -- props may carry a plate: the node's own plate wins below
    end
    local plate = (type(f.plate) == 'string' and f.plate ~= '') and f.plate or nil
    if plate ~= s.plate then
        if plate then SetVehicleNumberPlateText(veh, plate) end
        s.plate = plate
    end
    if fresh then SetVehicleDoorsLocked(veh, 2) end   -- `locked` is the promoted clone's business
    applyHold(node.id, veh, s, holdMode(node, f, 'vehicle'), fresh)
    local engine = flag(f.engine, false)
    if engine ~= s.engine then
        if engine or not fresh then SetVehicleEngineOn(veh, engine, true, true) end
        s.engine = engine
    end
    local lights = int(f.lights) or 0
    lights = lights < 0 and 0 or (lights > 2 and 2 or lights)
    if lights ~= s.lights then
        SetVehicleLights(veh, lights == 0 and 1 or 2)          -- 1 forced off, 2 forced on (no driver decides)
        if lights == 2 or s.lights == 2 then SetVehicleFullbeam(veh, lights == 2) end
        s.lights = lights
    end
    local siren = flag(f.siren, false)
    if siren ~= s.siren then
        if siren or not fresh then SetVehicleSiren(veh, siren) end
        s.siren = siren
    end
    vehicleDoors(veh, f.doors, s)
    local dirt = f.dirt ~= nil and num(f.dirt, 0.0, 0.0, 15.0) or nil
    if dirt ~= s.dirt then
        if dirt then SetVehicleDirtLevel(veh, dirt) end
        s.dirt = dirt
    end
    local invincible = flag(f.invincible, false)
    if invincible ~= s.invincible then
        if invincible or not fresh then SetEntityInvincible(veh, invincible, false) end
        s.invincible = invincible
    end
end

local VEHICLE = { class = 'vehicle', budget = 'vehicles', fade = 'alpha' }

function VEHICLE.assets(node) return modelAssets(node, false) end

function VEHICLE.create(node, ctx)
    local f = node.fields or EMPTY
    local hash = hashOf(f.model)
    if not hash or not modelIs(hash, 'vehicle') then return nil end
    local x, y, z, rx, ry, rz = pose(node, ctx)
    local veh = CreateVehicle(hash, x, y, z, rz, false, false)
    if not veh or veh == 0 then return nil end
    if abs(rx) > 0.01 or abs(ry) > 0.01 then SetEntityRotation(veh, rx, ry, rz, 2, false) end
    local s = newState(node, 'vehicle', veh, hash, x, y, z)
    vehicleApply(node, veh, s, f, true)
    s.anchor = K.attach(node, veh, false)
    K.syncInteract(node, veh)
    return veh
end

--- Does `a` hold every key path of `b` (top-level keys in `skip` aside)? A digit-string key and its integer (a
--- JSON round trip) are one key; a missing table holds nothing.
local function covers(a, b, depth, skip)
    if type(b) ~= 'table' then return a ~= nil end
    if type(a) ~= 'table' then a = EMPTY end
    if depth > 4 then return true end
    for k, v in pairs(b) do
        if not (skip and skip[k]) then
            local x = a[k]
            if x == nil then
                if type(k) == 'string' then x = a[tonumber(k)] elseif mtype(k) == 'integer' then x = a[tostring(k)] end
            end
            if x == nil or not covers(x, v, depth + 1) then return false end
        end
    end
    return true
end

local RESTORED = {}   -- reused: the props keys vehicleApply puts back itself (vehicleLost)

--- A custom colour the live copy can drop in place: the new props clear it (`false`: setPropsLocal calls
--- Clear…CustomColour), or leave it out where it was already cleared (a fresh copy has none either). -> true | nil
local function cleared(props, applied, key)
    local v = props[key]
    return (v == false or (v == nil and type(applied) == 'table' and applied[key] == false)) or nil
end

--- What a live local copy cannot take back (§6.8 setPropsLocal applies the keys present only; a plate or a dirt
--- level stays once set): a removed `plate` or `dirt`, or props that no longer hold a key path the applied ones
--- had — except what vehicleApply restores deterministically: the colours (props without colorPrimary get the
--- stable paint pair, both colours), a custom colour the new props clear with `false` or leave out where it was
--- cleared already (review RV5 F2) and a props plate while the node's own plate wins over it.
local function vehicleLost(s, f)
    local plate = type(f.plate) == 'string' and f.plate ~= ''
    if s.plate ~= nil and not plate then return true end
    if s.dirt ~= nil and f.dirt == nil then return true end
    if s.props == nil then return false end
    local props = type(f.props) == 'table' and f.props or EMPTY
    local repaint = props.colorPrimary == nil or nil
    RESTORED.plate, RESTORED.colorPrimary, RESTORED.colorSecondary = plate or nil, repaint, repaint
    RESTORED.customPrimary = cleared(props, s.props, 'customPrimary')
    RESTORED.customSecondary = cleared(props, s.props, 'customSecondary')
    return not covers(props, s.props, 0, RESTORED)
end

--- Such a change answers false: the materialiser re-creates the copy (its model-change path), and the fresh copy is
--- exactly what a client streaming the node in now would build (the game's own plate, dirt and paint).
function VEHICLE.update(node, veh, what)
    local s = S[node.id]
    if s and s.e == veh and vehicleLost(s, node.fields or EMPTY) then return false end
    return updateEntity(node, veh, what, 'vehicle', vehicleApply, false)
end

VEHICLE.place = PROP.place
VEHICLE.destroy = destroyEntity

--------------------------------------------------------------------------------
-- ped
--------------------------------------------------------------------------------

local MAX_COMPONENT <const>, MAX_PED_PROP <const> = 11, 8

--- variation = { components = { [0..11] = { drawable, texture, palette } }, props = { [0..8] = { drawable,
--- texture } | false } } — entries may also be arrays { d, t, p }; a prop with drawable < 0 or false is cleared.
local function applyVariation(ped, v)
    if type(v.components) == 'table' then
        for key, c in pairs(v.components) do
            local id = int(key)
            if id and id >= 0 and id <= MAX_COMPONENT and type(c) == 'table' then
                SetPedComponentVariation(ped, id, int(c.drawable or c[1]) or 0, int(c.texture or c[2]) or 0,
                    int(c.palette or c[3]) or 0)
            end
        end
    end
    if type(v.props) == 'table' then
        for key, p in pairs(v.props) do
            local id = int(key)
            if id and id >= 0 and id <= MAX_PED_PROP then
                local drawable = type(p) == 'table' and int(p.drawable or p[1]) or nil
                if p == false or (drawable and drawable < 0) then
                    ClearPedProp(ped, id, 0)
                elseif drawable then
                    SetPedPropIndex(ped, id, drawable, int(p.texture or p[2]) or 0, true, 0)
                end
            end
        end
    end
end
K.applyVariation = applyVariation

--- TaskPlayAnim at the clock phase (its start-phase argument), then a fix-up one maintenance tick later:
--- SetEntityAnimCurrentTime / SetEntityAnimSpeed only act once the task has started the clip.
local function pedPlayAnim(id, ped, a, fresh)
    local dur = durationMs(a.dict, a.clip)
    local phase = animPhase(a, dur)
    local flags = int(a.flag) or (a.loop == false and 2 or 1)   -- AF_HOLD_LAST_FRAME | AF_LOOPING
    local blendIn, blendOut = 8.0, -8.0
    if fresh then blendIn, blendOut = 1000.0, -1000.0 end        -- INSTANT_BLEND_IN / _OUT on a new ped
    TaskPlayAnim(ped, a.dict, a.clip, blendIn, blendOut, -1, flags, phase, false, false, false)
    SetEntityAnimCurrentTime(ped, a.dict, a.clip, phase)
    fixLater(id, ped, a)
end

local function pedApply(node, ped, s, f, fresh)
    if f.appearance ~= s.appearance or f.variation ~= s.variation then
        if not fresh then SetPedDefaultComponentVariation(ped) end   -- a changed look starts from the default
        if type(f.appearance) == 'table' then
            Core.Spawn.applyAppearance(ped, f.appearance)                 -- §34, the players' own apply
        elseif type(f.variation) == 'table' then
            applyVariation(ped, f.variation)
        end
        s.appearance, s.variation = f.appearance, f.variation
    end
    local invincible = flag(f.invincible, true)
    if invincible ~= s.invincible then
        if invincible or not fresh then SetEntityInvincible(ped, invincible, false) end
        s.invincible = invincible
    end
    local mode = holdMode(node, f, 'ped')
    applyHold(node.id, ped, s, mode, fresh)
    local block = flag(f.blockEvents, true)
    if block ~= s.block then
        if block or not fresh then SetBlockingOfNonTemporaryEvents(ped, block) end
        s.block = block
    end
    local stiff = mode == 'frozen' and invincible   -- no ragdoll while frozen + invincible (§55.12)
    if stiff ~= s.stiff then
        if stiff or not fresh then SetPedCanRagdoll(ped, not stiff) end
        s.stiff = stiff
    end
    local health = int(f.health)
    if health and health <= 0 then health = nil end
    if health ~= s.health then
        if health then
            SetEntityMaxHealth(ped, health)
            SetEntityHealth(ped, health, 0, 0)
        end
        s.health = health
    end
    local weapon = hashOf(f.weapon)
    if weapon ~= s.weapon then
        if s.weapon then RemoveAllPedWeapons(ped, true) end
        if weapon then GiveWeaponToPed(ped, weapon, 0, false, true) end
        s.weapon = weapon
    end
    -- what the ped does: a scenario wins over an anim
    local scenario = (type(f.scenario) == 'string' and f.scenario ~= '') and f.scenario or nil
    local a = not scenario and animOf(f.anim) or nil
    local key = scenario and ('scenario:' .. scenario) or animKey(a)
    if key ~= s.activity then
        if s.activity then
            ClearPedTasksImmediately(ped)
            if fix[node.id] then fix[node.id], nFix = nil, nFix - 1 end
        end
        if scenario then
            TaskStartScenarioInPlace(ped, scenario, 0, false)   -- already there: no enter animation
        elseif a then
            pedPlayAnim(node.id, ped, a, fresh)
        end
        s.activity = key
    end
end

local PED = { class = 'ped', budget = 'peds', fade = 'alpha' }

function PED.assets(node) return modelAssets(node, true) end

function PED.create(node, ctx)
    local f = node.fields or EMPTY
    local hash = hashOf(f.model)
    if not hash or not modelIs(hash, 'ped') then return nil end
    local x, y, z, _, _, rz = pose(node, ctx)
    local ped = CreatePed(4, hash, x, y, z, rz, false, false)
    if not ped or ped == 0 then return nil end
    SetPedDefaultComponentVariation(ped)   -- the same look on every client (no random variation)
    local s = newState(node, 'ped', ped, hash, x, y, z)
    pedApply(node, ped, s, f, true)
    s.anchor = K.attach(node, ped, true)
    K.syncInteract(node, ped)
    return ped
end

function PED.update(node, ped, what) return updateEntity(node, ped, what, 'ped', pedApply, true) end

function PED.place(node, ped, x, y, z, _, _, rz)
    local s = S[node.id]
    if s then
        if s.anchor then return end
        s.x, s.y, s.z = x, y, z
    end
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    SetEntityHeading(ped, rz)
end

PED.destroy = destroyEntity

--------------------------------------------------------------------------------
-- registration, stats, shutdown
--------------------------------------------------------------------------------

K.handlers = { prop = PROP, vehicle = VEHICLE, ped = PED }
C.mat.registerKind('prop', PROP)
C.mat.registerKind('vehicle', VEHICLE)
C.mat.registerKind('ped', PED)

--- The applied state of node `id` (tests, the debug overlay): a read-only view, never mutate it.
function K.stateOf(id) return S[id] end

function K.stats()
    local n = { prop = 0, vehicle = 0, ped = 0 }
    for _, s in pairs(S) do n[s.class] = (n[s.class] or 0) + 1 end
    local prompts = 0
    for _, r in pairs(IX) do prompts = prompts + r.n end
    n.prompts, n.waking, n.fixups = prompts, nWake, nFix
    return n
end

--- Core stops: every entity and prompt goes now (idempotent; the materialiser may have destroyed them).
function K.shutdown()
    stopped = true
    for id, s in pairs(S) do
        if exists(s.e) then DeleteEntity(s.e) end
        S[id] = nil
    end
    for id in pairs(IX) do K.clearInteract(id) end
    wake, fix, snaps, nWake, nFix, nSnap = {}, {}, {}, 0, 0, 0
end

local SELF <const> = GetCurrentResourceName()
AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= SELF then return end
    K.shutdown()
end)

C.kinds = K
