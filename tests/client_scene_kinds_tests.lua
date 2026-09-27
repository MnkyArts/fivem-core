-- Offline tests for Core.Scene's built-in client kinds (DESIGN §55.12, §55.11 fades, §55.14 interactions):
-- client/scene_kinds.lua (prop, vehicle, ped, prompts, riding), client/scene_fx.lua (light, particle, marker, text,
-- the draw loop) and client/scene_world.lua (hide, zone, sound, group, the 4 Hz zone loop, the C.fx extensions),
-- plus Vehicles.setPropsLocal (client/vehicles.lua).
-- A stub client VM on the stubs' virtual clock with a FAKE materialiser (C.mat) that records registrations; the
-- handlers are called directly. Wait(0) is one 16 ms frame and is counted, so "the loop exists only while needed"
-- is measurable. Every native the files call is a recording stub; checks compare exact arguments.
local here = arg[0]:match('^(.*)/') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads checked-in stubs only
local stubs = dofile(here .. '/stubs.lua')
stubs.newWorld()
stubs.clear()

local passed = 0
local function ok(cond, label)
    assert(cond, 'FAIL: ' .. label)
    passed = passed + 1
end
local function eq(actual, expected, label)
    assert(actual == expected, label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end
local function near(actual, expected, label, eps)
    assert(type(actual) == 'number' and math.abs(actual - expected) <= (eps or 1e-6),
        label .. ': expected ~' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end

local env = stubs.newEnv('client', 'core')
local v3 = stubs.vector3
stubs.loadFile(env, 'import.lua')
stubs.loadFile(env, 'shared/config.lua')
stubs.loadFile(env, 'client/api.lua')
env.Config.Scene.Caps.hides, env.Config.Scene.Caps.sounds = 3, 2   -- small budgets, read at load

-- frames: Wait(0) is one 16 ms frame on the virtual clock, and is counted
local FRAME, frames = 16, 0
env.Wait = function(ms)
    ms = tonumber(ms) or 0
    if ms <= 0 then frames = frames + 1 end
    return coroutine.yield(ms > 0 and ms or FRAME)
end
local function tick(ms) stubs.tick(ms) end

-- recording natives --------------------------------------------------------------------------------------------
local log, seq = {}, 0
local function record(name, ...)
    local list = log[name]
    if not list then
        list = {}
        log[name] = list
    end
    seq = seq + 1
    local call = table.pack(...)
    call.seq = seq                     -- the global call order (paint before props, …)
    list[#list + 1] = call
end
local function nat(name, impl)
    env[name] = function(...)
        record(name, ...)
        if impl then return impl(...) end
    end
end
local function n(name) return log[name] and #log[name] or 0 end
local function last(name) local l = log[name] return l and l[#l] or nil end
local function clear() for k in pairs(log) do log[k] = nil end end
--- exact argument check of a recorded call (floats compared within 1e-6)
local function args(call, label, ...)
    assert(call, label .. ': no call recorded')
    local want = table.pack(...)
    for i = 1, math.max(want.n, call.n) do
        local a, b = call[i], want[i]
        if type(a) == 'number' and type(b) == 'number' then
            assert(math.abs(a - b) <= 1e-6,
                ('%s: arg %d expected %s, got %s'):format(label, i, tostring(b), tostring(a)))
        else
            assert(a == b, ('%s: arg %d expected %s, got %s'):format(label, i, tostring(b), tostring(a)))
        end
    end
    passed = passed + 1
end

-- entities
local ents, nextHandle = {}, 1000
local PLAYER_PED = 7
-- the mutable world the natives read: player, camera, clock, collision, failure switches
local W = { playerPos = v3(0.0, 0.0, 0.0), camPos = v3(0.0, 0.0, 0.0), camRot = v3(0.0, 0.0, 0.0), camSpeed = 0.0,
    clockNow = 10000, collision = false, failCreate = false, lodScale = 1.0, ptfxFail = false }
local function newEnt(kind, model, x, y, z)
    nextHandle = nextHandle + 1
    ents[nextHandle] = { kind = kind, model = model, x = x, y = y, z = z }
    return nextHandle
end
nat('CreateObjectNoOffset', function(h, x, y, z) return W.failCreate and 0 or newEnt(3, h, x, y, z) end)
nat('CreateVehicle', function(h, x, y, z) return newEnt(2, h, x, y, z) end)
nat('CreatePed', function(_, h, x, y, z) return newEnt(1, h, x, y, z) end)
nat('DoesEntityExist', function(e) return (ents[e] and not ents[e].deleted) and 1 or false end)
nat('DeleteEntity', function(e) ents[e].deleted = true end)
nat('GetEntityType', function(e) return ents[e] and ents[e].kind or 0 end)
env.PlayerPedId = function() return PLAYER_PED end
env.GetEntityCoords = function(e)
    if e == PLAYER_PED then return W.playerPos end
    local r = ents[e]
    return r and v3(r.x, r.y, r.z) or v3(0.0, 0.0, 0.0)
end
nat('GetOffsetFromEntityInWorldCoords', function(e, ox, oy, oz)
    local r = ents[e]
    return v3(r.x + ox, r.y + oy, r.z + oz)
end)
env.GetFinalRenderedCamCoord = function() return W.camPos end
env.GetFinalRenderedCamRot = function(order) assert(order == 2, 'rotation order 2') return W.camRot end

local vehModels, pedModels = {}, {}
nat('IsModelAVehicle', function(h) return vehModels[h] and 1 or false end)
nat('IsModelAPed', function(h) return pedModels[h] and 1 or false end)
local durations = {}   -- dict/clip -> seconds
nat('GetAnimDuration', function(d, c) return durations[d .. '/' .. c] or 0.0 end)
nat('HasCollisionLoadedAroundEntity', function() return W.collision and 1 or false end)
nat('PlaceObjectOnGroundProperly', function(e)   -- a ground probe: lands (true) unless the test says no ground
    if W.noGround then return false end
    ents[e].z = W.groundZ or ents[e].z
    return 1
end)
for _, name in ipairs({ 'SetEntityRotation', 'SetEntityCoordsNoOffset', 'SetEntityHeading', 'SetEntityLodDist',
    'FreezeEntityPosition', 'SetEntityCollision', 'SetEntityInvincible', 'SetDisableFragDamage', 'SetEntityVisible',
    'SetObjectTextureVariation', 'PlayEntityAnim', 'StopEntityAnim', 'SetEntityAnimCurrentTime', 'SetEntityAnimSpeed',
    'SetVehicleDoorsLocked', 'SetVehicleEngineOn', 'SetVehicleLights', 'SetVehicleFullbeam', 'SetVehicleSiren',
    'SetVehicleDoorOpen', 'SetVehicleDoorShut', 'SetVehicleDoorControl', 'SetVehicleDirtLevel',
    'SetVehicleNumberPlateText', 'SetPedDefaultComponentVariation', 'SetPedComponentVariation', 'SetPedPropIndex',
    'ClearPedProp', 'TaskStartScenarioInPlace', 'TaskPlayAnim', 'ClearPedTasksImmediately', 'GiveWeaponToPed',
    'RemoveAllPedWeapons', 'SetBlockingOfNonTemporaryEvents', 'SetPedCanRagdoll', 'SetEntityMaxHealth',
    'SetEntityHealth', 'AttachEntityToEntity', 'DetachEntity', 'DrawLightWithRange', 'DrawLightWithRangeAndShadow',
    'DrawSpotLight', 'DrawSpotLightWithShadow', 'UseParticleFxAsset', 'SetParticleFxLoopedAlpha',
    'SetParticleFxLoopedColour', 'SetParticleFxLoopedScale', 'SetParticleFxLoopedOffsets', 'StopParticleFxLooped',
    'DrawMarker', 'SetDrawOrigin', 'ClearDrawOrigin', 'SetTextFont', 'SetTextScale', 'SetTextColour',
    'SetTextCentre', 'SetTextOutline', 'BeginTextCommandDisplayText', 'AddTextComponentSubstringPlayerName',
    'EndTextCommandDisplayText', 'CreateModelHideExcludingScriptObjects', 'RemoveModelHide', 'PlaySoundFromCoord',
    'PlaySoundFromEntity', 'StopSound', 'ReleaseSoundId', 'SetVehicleModKit', 'SetVehicleColours',
    'SetVehicleCustomPrimaryColour', 'SetVehicleWindowTint', 'SetVehicleMod',
    'NetworkRequestControlOfEntity' }) do nat(name) end
nat('GetEntityBoneIndexByName', function() return 12 end)
nat('GetPedBoneIndex', function(_, tag) return tag == 57005 and 28 or 0 end)
local players = { [5] = 55 }                     -- server id -> player index; its ped below
nat('GetPlayerFromServerId', function(src) return players[src] or -1 end)
nat('GetPlayerPed', function(p) return p == 55 and 9001 or 0 end)
ents[9001] = { kind = 1, x = 1.0, y = 2.0, z = 3.0 }
local netEnts = {}
nat('NetworkDoesEntityExistWithNetworkId', function(id) return netEnts[id] and 1 or false end)
nat('NetworkGetEntityFromNetworkId', function(id) return netEnts[id] or 0 end)
nat('NetworkHasControlOfEntity', function() return false end)
env.GetVehiclePedIsTryingToEnter = function() return 0 end
local ptfxNext = 500
local function ptfx() if W.ptfxFail then return 0 end ptfxNext = ptfxNext + 1 return ptfxNext end
nat('StartParticleFxLoopedAtCoord', ptfx)
nat('StartParticleFxLoopedOnEntity', ptfx)
nat('StartParticleFxLoopedOnEntityBone', ptfx)
local sidNext, finished = 0, {}
nat('GetSoundId', function() sidNext = sidNext + 1 return sidNext end)
nat('HasSoundFinished', function(id) return finished[id] and 1 or false end)

-- Core stubs: the shared clock, prompts, appearance, the net emit ------------------------------------------------
rawset(env.Core, 'Clock', {
    now = function() return W.clockNow end,
    diff = function(a, b) return ((a - b + 2147483648) % 4294967296) - 2147483648 end,
})
local iadds, iremoved, inext, ilabels = {}, {}, 0, {}
rawset(env.Core, 'Interactions', {
    add = function(opts) inext = inext + 1 local id = 'core:i' .. inext iadds[id] = opts return id end,
    remove = function(id) iremoved[id] = true return true end,
    setLabel = function(id, text)
        ilabels[#ilabels + 1] = { id, text }
        if iadds[id] then iadds[id].label = text end
        return true
    end,
})
local looks = {}
rawset(env.Core, 'Spawn', { applyAppearance = function(ped, a) looks[#looks + 1] = { ped, a } return true end })
local emits = {}
env.Core.Net.emit = function(name, ...) emits[#emits + 1] = table.pack(name, ...) end

-- the fake materialiser -------------------------------------------------------------------------------------------
local registered, handles = {}, {}
env.CoreSceneRuntime = { mat = {
    registerKind = function(id, h) registered[#registered + 1] = id registered[id] = h end,
    handleOf = function(id) return handles[id] end,
    lodScale = function() return W.lodScale end,
    camera = function() return W.camPos.x, W.camPos.y, W.camPos.z, 0.0, 1.0, 0.0, W.camSpeed end,
} }

stubs.loadFile(env, 'client/vehicles.lua')
stubs.loadFile(env, 'client/scene_kinds.lua')
stubs.loadFile(env, 'client/scene_fx.lua')
stubs.loadFile(env, 'client/scene_world.lua')
local C = env.CoreSceneRuntime
local K, FX, H = C.kinds, C.fx, registered

local nid = 0
local function node(fields, extra)
    nid = nid + 1
    local nd = { id = nid, x = 100.0, y = 200.0, z = 30.0, rx = 0.0, ry = 0.0, rz = 90.0, parent = 0,
        fields = fields or {} }
    for k, v in pairs(extra or {}) do nd[k] = v end
    return nd
end
local function ctx(nd, late)
    return { x = nd.x, y = nd.y, z = nd.z, rx = nd.rx, ry = nd.ry, rz = nd.rz, late = late == true }
end
local function hash(name) return env.GetHashKey(name) end

-- 1. registration: every built-in kind, its class / budget / fade mode ------------------------------------------
local SHAPES = {
    prop = { 'prop', 'props', 'engine' }, vehicle = { 'vehicle', 'vehicles', 'alpha' },
    ped = { 'ped', 'peds', 'alpha' },
    light = { 'fx', 'lights', 'self' }, particle = { 'fx', 'particles', 'self' }, marker = { 'fx', 'markers', 'self' },
    text = { 'fx', 'texts', 'self' }, hide = { 'fx', 'hides', 'none' }, zone = { 'data', nil, 'none' },
    sound = { 'fx', 'sounds', 'none' }, group = { 'data', nil, 'none' },
}
eq(#registered, 11, 'eleven built-in kinds registered')
for id, s in pairs(SHAPES) do
    local h = H[id]
    ok(h and type(h.create) == 'function' and type(h.destroy) == 'function', id .. ': create + destroy')
    eq(h.class, s[1], id .. ' class')
    eq(h.budget, s[2], id .. ' budget')
    eq(h.fade, s[3], id .. ' fade')
end
eq(H.prop.place ~= nil and H.vehicle.place ~= nil and H.ped.place ~= nil, true, 'entity kinds place (movers)')
eq(table.concat(registered, ','), 'prop,vehicle,ped,light,particle,marker,text,hide,zone,sound,group',
    'manifest order: scene_kinds -> scene_fx -> scene_world')
ok(FX.handlers.light == H.light and FX.handlers.text == H.text, 'C.fx.handlers: the drawn kinds (scene_fx.lua)')
ok(FX.handlers.hide == H.hide and FX.handlers.group == H.group, '... and the world kinds (scene_world.lua)')
ok(type(FX.onZone) == 'function' and type(FX.zoneShape) == 'function', 'C.fx.onZone / zoneShape (scene_world.lua)')
do   -- scene_world.lua asserts that scene_fx.lua ran before it
    local env2 = stubs.newEnv('client', 'core')
    stubs.loadFile(env2, 'import.lua')
    stubs.loadFile(env2, 'shared/config.lua')
    env2.CoreSceneRuntime = { mat = env.CoreSceneRuntime.mat, kinds = K }
    local okLoad, err = pcall(stubs.loadFile, env2, 'client/scene_world.lua')
    ok(not okLoad and tostring(err):find('scene_fx.lua', 1, true) ~= nil, 'scene_world.lua refuses to load first')
end
eq(H.prop.radii, nil, 'entity kinds use the materialiser radii table')

-- 2. prop: create with defaults, exact natives -------------------------------------------------------------------
local BENCH = hash('prop_bench_01a')
local p1 = node({ model = 'prop_bench_01a', lod = 150 }, { rx = 1.0, ry = 2.0 })
local assets = H.prop.assets(p1)
eq(#assets, 1, 'prop assets: the model only')
eq(assets[1].type == 'model' and assets[1].hash, BENCH, 'prop asset = the model hash')
clear()
local e1 = H.prop.create(p1, ctx(p1))
ok(ents[e1] ~= nil, 'prop created')
args(last('CreateObjectNoOffset'), 'CreateObjectNoOffset local static', BENCH, 100.0, 200.0, 30.0, false, false, false)
args(last('SetEntityRotation'), 'prop rotation order 2', e1, 1.0, 2.0, 90.0, 2, false)
args(last('FreezeEntityPosition'), 'prop frozen by default', e1, true)
args(last('SetEntityLodDist'), 'prop lodDist = fields.lod', e1, 150)
eq(n('SetEntityCollision') + n('SetEntityInvincible') + n('SetEntityVisible') + n('SetObjectTextureVariation'), 0,
    'defaults cost no natives (collision on, not invincible, visible, no tint)')
eq(n('IsModelAVehicle') + n('IsModelAPed'), 2, 'model type asked once')
local p2 = node({ model = BENCH })
local e2 = H.prop.create(p2, ctx(p2))
eq(n('IsModelAVehicle') + n('IsModelAPed'), 2, 'same model: type cached')
args(last('SetEntityLodDist'), 'no lod from the server -> 100', e2, 100)
eq(K.stateOf(p1.id).e, e1, 'state keeps the entity')

-- non-defaults
clear()
local p3 = node({ model = BENCH, collision = false, invincible = true, visible = false, tint = 5, frozen = true })
local e3 = H.prop.create(p3, ctx(p3))
args(last('SetEntityCollision'), 'collision off', e3, false, false)
args(last('SetEntityInvincible'), 'invincible', e3, true, false)
args(last('SetDisableFragDamage'), 'no frag damage', e3, true)
args(last('SetEntityVisible'), 'invisible', e3, false, false)
args(last('SetObjectTextureVariation'), 'tint', e3, 5)
clear()
local p4 = node({ model = BENCH, tint = 20 })
H.prop.create(p4, ctx(p4))
eq(n('SetObjectTextureVariation'), 0, 'tint outside 0..15 ignored')

-- wrong model type / failed create
vehModels[hash('adder')], pedModels[hash('a_m_y_business_01')] = true, true
eq(H.prop.create(node({ model = 'adder' })), nil, 'a vehicle model is no prop')
eq(H.prop.create(node({})), nil, 'no model: failed')
W.failCreate = true
eq(H.prop.create(node({ model = BENCH })), nil, 'CreateObjectNoOffset answered 0: failed')
W.failCreate = false

-- 3. lod: the engine band must land inside our create radius (Radii.PropCap 500) ---------------------------------
eq(K.propLod({ lod = 600 }), 470, 'lod 600 at S 1: (500 - 20 - 10) / 1')
W.lodScale = 2.0
eq(K.propLod({ lod = 300 }), 235, 'lod 300 at S 2: floor(470 / 2)')
eq(K.propLod({ lod = 200 }), 200, 'lod 200 at S 2 fits (430 <= 500)')
W.lodScale = 1.0
eq(K.propLod({ lod = 15 }), 15, 'small lod keeps its value (band 5)')
eq(K.propLod({}), 100, 'default lod 100')

-- 4. clock-phased animations --------------------------------------------------------------------------------------
local A = { dict = 'anim@fan', clip = 'spin', loop = true, rate = 1, t0 = 1000 }
eq(K.phaseAt(A, 2000, 5000), 0.5, 'loop: (5000 / 2000) mod 1')
eq(K.phaseAt({ rate = 1.5 }, 2000, 5000), 0.75, 'rate 1.5: (7500 / 2000) mod 1')
eq(K.phaseAt(A, 2000, -500), 0.75, 'before t0 a loop keeps its phase (floored modulo)')
eq(K.phaseAt({ loop = false }, 2000, 3000), 1.0, 'once: clamped at the end')
eq(K.phaseAt({ loop = false }, 2000, -100), 0.0, 'once: clamped at the start')
eq(K.phaseAt(A, 0, 5000), 0.0, 'unknown duration: phase 0')
W.clockNow = 704
near(K.animPhase({ t0 = 4294967000 }, 2000), 0.5, 'wrap-safe: t0 before the u32 wrap, now after it')
W.clockNow = 10000
eq(K.animPhase({ dict = 'x', clip = 'y' }, 2000), 0.0, 'no t0: phase 0')
durations['anim@fan/spin'] = 2.0
clear()
eq(K.durationMs('anim@fan', 'spin'), 2000.0, 'GetAnimDuration seconds -> ms')
K.durationMs('anim@fan', 'spin')
eq(n('GetAnimDuration'), 1, 'duration cached per clip')
K.durationMs('anim@none', 'x')
K.durationMs('anim@none', 'x')
eq(n('GetAnimDuration'), 3, 'an unknown (0) duration is asked again')

W.clockNow = 6000   -- 5000 ms after t0
local p5 = node({ model = BENCH, anim = { dict = 'anim@fan', clip = 'spin', loop = true, rate = 1.5, t0 = 1000 } })
eq(#H.prop.assets(p5), 2, 'prop with anim: model + anim dict')
eq(H.prop.assets(p5)[2].name, 'anim@fan', 'anim asset = the dict')
clear()
local e5 = H.prop.create(p5, ctx(p5))
args(last('PlayEntityAnim'), 'PlayEntityAnim at the clock phase',
    e5, 'spin', 'anim@fan', 1000.0, true, true, false, 0.75, 0)
args(last('SetEntityAnimCurrentTime'), 'phase set', e5, 'anim@fan', 'spin', 0.75)
args(last('SetEntityAnimSpeed'), 'rate applied', e5, 'anim@fan', 'spin', 1.5)

-- 5. prop update in place / re-create / place / destroy -----------------------------------------------------------
clear()
p5.fields = { model = BENCH, tint = 3, anim = { dict = 'anim@fan', clip = 'wobble', t0 = 1000 } }
eq(H.prop.update(p5, e5, 'set', {}), true, 'field changes apply in place')
args(last('SetObjectTextureVariation'), 'tint in place', e5, 3)
args(last('StopEntityAnim'), 'old anim stopped', e5, 'spin', 'anim@fan', 1000.0)
eq(last('PlayEntityAnim')[2], 'wobble', 'new anim played')
clear()
eq(H.prop.update(p5, e5, 'set', {}), true, 'an unchanged update')
eq(n('SetObjectTextureVariation') + n('PlayEntityAnim') + n('FreezeEntityPosition'), 0, 'unchanged: no natives')
p5.fields = { model = BENCH }
H.prop.update(p5, e5, 'set', {})
args(last('SetObjectTextureVariation'), 'tint removed -> 0', e5, 0)
p5.fields = { model = 'prop_chair_01a' }
eq(H.prop.update(p5, e5, 'set', {}), false, 'another model: update answers false (re-create)')
p5.fields = { model = BENCH }
eq(H.prop.update(p5, 424242, 'set', {}), false, 'a handle that is not the node entity: false')
clear()
p5.x, p5.y, p5.z, p5.rx, p5.ry, p5.rz = 1.0, 2.0, 3.0, 4.0, 5.0, 6.0
H.prop.update(p5, e5, 'move')
args(last('SetEntityCoordsNoOffset'), "'move' re-places at the node pose", e5, 1.0, 2.0, 3.0, false, false, false)
args(last('SetEntityRotation'), "'move' rotates", e5, 4.0, 5.0, 6.0, 2, false)
H.prop.place(p5, e5, 7.0, 8.0, 9.0, 10.0, 11.0, 12.0)
args(last('SetEntityCoordsNoOffset'), 'place (movers)', e5, 7.0, 8.0, 9.0, false, false, false)
args(last('SetEntityRotation'), 'place rotation', e5, 10.0, 11.0, 12.0, 2, false)
clear()
H.prop.destroy(p5, e5)
args(last('DeleteEntity'), 'destroy deletes', e5)
eq(K.stateOf(p5.id), nil, 'state gone')
H.prop.destroy(p5, e5)
eq(n('DeleteEntity'), 1, 'a destroyed (or faded-out) entity is not deleted twice')
eq(H.prop.update(p5, e5, 'set', {}), false, 'update after destroy: false')

-- 6. holding still: unfrozen / 'local' physics entities wait for collision (the maintenance thread) ----------------
clear()
local p6 = node({ model = BENCH, physics = 'local' })
local e6 = H.prop.create(p6, ctx(p6))
args(log.FreezeEntityPosition[1], "physics 'local': created frozen", e6, true)
local w, f = K.pending()
eq(w, 1, 'one unfreeze pending')
W.camPos = v3(500.0, 500.0, 30.0)
tick(600)
eq(n('HasCollisionLoadedAroundEntity'), 0, 'camera farther than 30 m: collision not even asked')
W.camPos = v3(100.0, 210.0, 30.0)
tick(300)
ok(n('HasCollisionLoadedAroundEntity') >= 1, 'camera within 30 m: collision asked')
eq(#log.FreezeEntityPosition, 1, 'no collision yet: still frozen')
W.collision = true
tick(300)
args(last('FreezeEntityPosition'), 'collision loaded: unfrozen', e6, false)
eq(K.pending(), 0, 'nothing pending')
local asked = n('HasCollisionLoadedAroundEntity')
tick(2000)
eq(n('HasCollisionLoadedAroundEntity'), asked, 'the maintenance thread ended with its work')
W.collision = false
clear()
local p7 = node({ model = BENCH, frozen = false })
local e7 = H.prop.create(p7, ctx(p7))
args(last('FreezeEntityPosition'), 'frozen = false: created frozen too', e7, true)
W.camPos = v3(900.0, 900.0, 30.0)   -- F19: created far away, and the camera stays away
W.collision = true
tick(40000)
eq(select(1, K.pending()), 1, 'frozen = false far from the camera: still pending after 40 s (not given up)')
eq(last('FreezeEntityPosition')[2], true, '... and still frozen')
W.camPos = v3(100.0, 290.0, 30.0)   -- 90 m: within the 100 m wake range
tick(300)
args(last('FreezeEntityPosition'), 'unfrozen once the camera is within 100 m and collision is loaded', e7, false)
W.collision = false
local pm = node({ model = BENCH, frozen = false }, { motion = { t = 'spin', t0 = 0, axis = 'z', dps = 90 } })
clear()
local em = H.prop.create(pm, ctx(pm))
args(last('FreezeEntityPosition'), 'a mover is created frozen ...', em, true)
eq(select(1, K.pending()), 0, '... and stays frozen (movers are kinematic, no wake)')
pm.motion = nil
H.prop.update(pm, em, 'motion')
eq(select(1, K.pending()), 1, 'motion gone: frozen = false wakes again')
pm.motion = { t = 'spin', t0 = 0, axis = 'z', dps = 90 }
H.prop.update(pm, em, 'motion')
eq(select(1, K.pending()), 0, 'motion back: frozen, the wake dropped')
H.prop.destroy(pm, em)
local p8 = node({ model = BENCH, physics = 'local' })
local e8 = H.prop.create(p8, ctx(p8))
W.camPos = v3(900.0, 900.0, 30.0)
tick(40000)
eq(K.pending(), 1, "'local' prop: time spent far away does not count towards the 30 s timeout")
W.camPos, W.collision = v3(100.0, 205.0, 30.0), true
tick(300)
args(last('FreezeEntityPosition'), 'woken once the camera came near (40 s later)', e8, false)
W.collision = false
local p9 = node({ model = BENCH, physics = 'local' })
local e9 = H.prop.create(p9, ctx(p9))
tick(31000)
eq(K.pending(), 0, 'near but no collision for 30 s: given up')
eq(last('FreezeEntityPosition')[2], true, '... and left frozen')
H.prop.destroy(p8, e8)
H.prop.destroy(p9, e9)
p7.fields = { model = BENCH, frozen = true }
H.prop.update(p7, e7, 'set', {})
args(last('FreezeEntityPosition'), 'frozen again in place', e7, true)
H.prop.destroy(p7, e7)

-- 6b. §55.21.2 snap = 'ground': PlaceObjectOnGroundProperly after create, retried <= 5 times within 20 m while the
-- ground collision streams; then the object stays where it landed (nothing goes back to the server)
do
    W.camPos, W.collision, W.noGround, W.groundZ = v3(100.0, 205.0, 30.0), true, false, 28.5
    local g1 = node({ model = BENCH, frozen = true, collision = false, snap = 'ground' }, { rz = 135.0 })   -- a drop
    clear()
    local ge1 = H.prop.create(g1, ctx(g1))
    args(last('PlaceObjectOnGroundProperly'), 'snap: placed on the ground right after create', ge1)
    ok(last('CreateObjectNoOffset').seq < last('PlaceObjectOnGroundProperly').seq, '... after the create')
    eq(select(3, K.pending()), 0, 'collision loaded: done at once')
    eq(ents[ge1].z, 28.5, 'it landed')
    args(last('SetEntityCollision'), 'the drop recipe: no collision', ge1, false, false)
    W.collision = false
    W.camPos = v3(100.0, 400.0, 30.0)
    local g2 = node({ model = BENCH, snap = 'ground' })
    clear()
    local ge2 = H.prop.create(g2, ctx(g2))
    eq(n('PlaceObjectOnGroundProperly'), 1, 'one placement on create')
    eq(select(3, K.pending()), 1, 'collision not loaded: a retry is pending')
    tick(5000)
    eq(n('PlaceObjectOnGroundProperly'), 1, 'camera farther than 20 m: no retry spent')
    W.camPos = v3(100.0, 215.0, 30.0)   -- 15 m
    tick(300)
    eq(n('PlaceObjectOnGroundProperly'), 2, 'within 20 m: retried')
    W.collision = true
    tick(300)
    eq(n('PlaceObjectOnGroundProperly'), 3, 'collision loaded: one more placement ...')
    eq(select(3, K.pending()), 0, '... and done')
    tick(1000)
    eq(n('PlaceObjectOnGroundProperly'), 3, 'nothing after that: it stays where it landed')
    W.collision = false
    local g3 = node({ model = BENCH, snap = 'ground' })
    clear()
    local ge3 = H.prop.create(g3, ctx(g3))
    tick(5000)
    eq(n('PlaceObjectOnGroundProperly'), 1 + 5, 'collision never loads near the camera: 1 + at most 5 retries')
    eq(select(3, K.pending()), 0, '... then given up')
    W.collision = true
    g3.x = 110.0
    clear()
    H.prop.update(g3, ge3, 'move')
    args(last('SetEntityCoordsNoOffset'), "'move': re-placed at the node pose ...", ge3, 110.0, 200.0, 30.0,
        false, false, false)
    args(last('PlaceObjectOnGroundProperly'), '... and snapped again', ge3)
    ok(last('SetEntityCoordsNoOffset').seq < last('PlaceObjectOnGroundProperly').seq, '... in that order')
    g3.fields = { model = BENCH }
    clear()
    H.prop.update(g3, ge3, 'set', {})
    args(last('SetEntityCoordsNoOffset'), 'snap off: back at the authored pose', ge3, 110.0, 200.0, 30.0,
        false, false, false)
    eq(n('PlaceObjectOnGroundProperly'), 0, '... without a placement')
    local g4 = node({ model = BENCH, snap = 'ground' }, { motion = { t = 'spin', t0 = 0, axis = 'z', dps = 45 } })
    local g5 = node({ model = BENCH, snap = 'ground' }, { attach = { p = 5 } })
    clear()
    local ge4, ge5 = H.prop.create(g4, ctx(g4)), H.prop.create(g5, ctx(g5))
    eq(n('PlaceObjectOnGroundProperly'), 0, 'a mover and a rider are never snapped')
    for _, x in ipairs({ { g1, ge1 }, { g2, ge2 }, { g3, ge3 }, { g4, ge4 }, { g5, ge5 } }) do
        H.prop.destroy(x[1], x[2])
    end
    W.collision, W.groundZ = false, nil
end

-- 7. vehicle: a local copy, props through setPropsLocal (no network-control wait) ----------------------------------
local ADDER = hash('adder')
clear()
local v1 = node({ model = 'adder', props = { colorPrimary = 12, colorSecondary = 34, plate = 'OLD' }, plate = 'SCENE 1',
    engine = true, siren = true, dirt = 7, invincible = true, doors = { [0] = 1, [1] = 0.5, [4] = 0 } },
    { rx = 5.0, ry = -3.0, rz = 45.0 })
eq(#H.vehicle.assets(v1), 1, 'vehicle assets: the model')
local veh = H.vehicle.create(v1, ctx(v1))
args(last('CreateVehicle'), 'CreateVehicle local', ADDER, 100.0, 200.0, 30.0, 45.0, false, false)
args(last('SetEntityRotation'), 'pitch/roll by rotation', veh, 5.0, -3.0, 45.0, 2, false)
args(last('SetVehicleModKit'), 'props: mod kit first', veh, 0)
args(last('SetVehicleColours'), 'props: colours', veh, 12, 34)
eq(n('NetworkRequestControlOfEntity') + n('NetworkHasControlOfEntity'), 0, 'no network-control request, no wait')
eq(log.SetVehicleNumberPlateText[1][2], 'OLD', 'the props plate first ...')
args(last('SetVehicleNumberPlateText'), '... then the node plate wins', veh, 'SCENE 1')
args(last('SetVehicleDoorsLocked'), 'the local copy is always locked', veh, 2)
args(last('FreezeEntityPosition'), 'parked: frozen', veh, true)
args(last('SetVehicleEngineOn'), 'engine', veh, true, true, true)
args(last('SetVehicleLights'), 'lights 0 = forced off', veh, 1)
eq(n('SetVehicleFullbeam'), 0, 'no full beam call for lights 0')
args(last('SetVehicleSiren'), 'siren', veh, true)
args(log.SetVehicleDoorOpen[1], 'door ratio 1: open at once', veh, 0, false, true)
args(last('SetVehicleDoorControl'), 'door ratio 0.5', veh, 1, 5, 0.5)
eq(n('SetVehicleDoorShut'), 0, 'a shut door on a new vehicle costs nothing')
args(last('SetVehicleDirtLevel'), 'dirt', veh, 7.0)
args(last('SetEntityInvincible'), 'invincible', veh, true, false)
clear()
local v2 = node({ model = ADDER })
H.vehicle.create(v2, ctx(v2))
eq(n('SetEntityRotation'), 0, 'no pitch/roll: no rotation call')
eq(n('SetVehicleEngineOn') + n('SetVehicleSiren') + n('SetEntityInvincible') + n('SetVehicleModKit'), 0,
    'vehicle defaults cost nothing')
eq(H.vehicle.create(node({ model = BENCH })), nil, 'a prop model is no vehicle')
local v3n = node({ model = ADDER, frozen = false })
clear()
local veh3 = H.vehicle.create(v3n, ctx(v3n))
args(last('FreezeEntityPosition'), 'an unparked vehicle is still created frozen', veh3, true)
W.collision = true
tick(300)
args(last('FreezeEntityPosition'), '... and released once its ground collision is loaded', veh3, false)
W.collision = false
H.vehicle.destroy(v3n, veh3)
-- F19: the §55.11 case — a vehicle created at 255 m (its R_in), the player takes a while to come near
local keepCam = W.camPos
W.camPos = v3(100.0, 455.0, 30.0)
local v4n = node({ model = ADDER, frozen = false })
clear()
local veh4 = H.vehicle.create(v4n, ctx(v4n))
W.collision = true
tick(45000)
eq(n('FreezeEntityPosition'), 1, 'created 255 m away: frozen for 45 s while the player is far')
eq(select(1, K.pending()), 1, '... still waiting, not given up')
W.camPos = v3(100.0, 250.0, 30.0)
tick(300)
args(last('FreezeEntityPosition'), '... released when the player comes within 100 m', veh4, false)
W.collision, W.camPos = false, keepCam
H.vehicle.destroy(v4n, veh4)

clear()
v1.fields = { model = 'adder', props = v1.fields.props, plate = 'SCENE 1', lights = 2, doors = { [1] = 0.5 },
    dirt = 7 }
eq(H.vehicle.update(v1, veh, 'set', {}), true, 'vehicle update in place')
args(last('SetVehicleLights'), 'lights 2: forced on', veh, 2)
args(last('SetVehicleFullbeam'), '... and full beam', veh, true)
args(last('SetVehicleEngineOn'), 'engine off in place', veh, false, true, true)
args(last('SetVehicleSiren'), 'siren off in place', veh, false)
args(last('SetVehicleDoorShut'), 'door 0 shut', veh, 0, true)
eq(n('SetVehicleModKit'), 0, 'the same props table is not re-applied')
eq(n('SetVehicleDoorControl'), 0, 'an unchanged door costs nothing')
clear()
v1.fields.lights, v1.fields.props = 1, { colorPrimary = 1, colorSecondary = 2 }
H.vehicle.update(v1, veh, 'set', {})
args(last('SetVehicleFullbeam'), 'lights 1: full beam off', veh, false)
args(last('SetVehicleColours'), 'new props table applied whole', veh, 1, 2)
args(last('SetVehicleNumberPlateText'), 'the node plate re-asserted after new props', veh, 'SCENE 1')
eq(n('NetworkRequestControlOfEntity'), 0, 'still no control request')
-- run I1 (task 8): what a live local copy cannot take back re-creates it (update() false, like a model change)
clear()
v1.fields = { model = 'adder', props = { colorPrimary = 1, colorSecondary = 2 }, plate = 'SCENE 2', lights = 1,
    dirt = 7 }
eq(H.vehicle.update(v1, veh, 'set', {}), true, 'a plate CHANGE is applied in place')
args(last('SetVehicleNumberPlateText'), '... SetVehicleNumberPlateText', veh, 'SCENE 2')
clear()
v1.fields.plate = nil
eq(H.vehicle.update(v1, veh, 'set', {}), false, 'a REMOVED plate: re-create (a live copy keeps the plate it got)')
eq(n('SetVehicleNumberPlateText') + n('SetVehicleColours') + n('SetVehicleLights'), 0,
    '... nothing is applied to the old copy')
v1.fields.plate = ''
eq(H.vehicle.update(v1, veh, 'set', {}), false, "an empty plate is a removed one")
v1.fields.plate, v1.fields.dirt = 'SCENE 2', nil
eq(H.vehicle.update(v1, veh, 'set', {}), false, 'a removed dirt level: re-create')
v1.fields.dirt, v1.fields.props = 7, { colorPrimary = 1 }
eq(H.vehicle.update(v1, veh, 'set', {}), false, 'props without a key the applied ones had: re-create')
clear()
v1.fields.props = nil
eq(H.vehicle.update(v1, veh, 'set', {}), true, 'props removed that held colours only: in place ...')
eq(n('SetVehicleColours'), 1, '... the stable paint pair restores both colours')
clear()
v1.fields.props = { colorPrimary = 1, colorSecondary = 3, mods = { [11] = 2 } }
eq(H.vehicle.update(v1, veh, 'set', {}), true, 'props holding every applied key (more keys too): in place')
args(last('SetVehicleColours'), '... applied', veh, 1, 3)
v1.fields.props = { colorPrimary = 1, colorSecondary = 3, mods = { ['11'] = 0 } }
eq(H.vehicle.update(v1, veh, 'set', {}), true, 'a digit-string key is its integer key (a JSON round trip)')
v1.fields.props = { colorPrimary = 1, colorSecondary = 3, mods = {} }
eq(H.vehicle.update(v1, veh, 'set', {}), false, 'a mod entry that went: re-create (setPropsLocal sets keys present)')
v1.fields.props = { colorPrimary = 1, colorSecondary = 3, mods = { [11] = -1 }, plate = 'P 1' }
eq(H.vehicle.update(v1, veh, 'set', {}), true, 'a mod set back to stock (-1) is applied in place')
v1.fields.props = { colorPrimary = 1, colorSecondary = 3, mods = { [11] = -1 } }
eq(H.vehicle.update(v1, veh, 'set', {}), true, "a props plate that went while the node's own plate wins: in place")
-- review RV5 F2: a custom colour cleared with `false` (what the maps projector sends when an editor removes a
-- vehicle's colour) is cleared IN PLACE by setPropsLocal — never a re-create (a cross-fade of the whole car)
for _, name in ipairs({ 'SetVehicleCustomSecondaryColour', 'ClearVehicleCustomPrimaryColour',
    'ClearVehicleCustomSecondaryColour' }) do nat(name) end
v1.fields.props = { colorPrimary = 1, colorSecondary = 3, mods = { [11] = -1 }, customPrimary = { 10, 20, 30 },
    customSecondary = { 1, 2, 3 } }
eq(H.vehicle.update(v1, veh, 'set', {}), true, 'custom colours: applied in place')
clear()
v1.fields.props = { colorPrimary = 1, colorSecondary = 3, mods = { [11] = -1 }, customPrimary = false,
    customSecondary = false }
eq(H.vehicle.update(v1, veh, 'set', {}), true, 'RV5 F2: custom colours cleared with false: in place, no re-create')
eq(n('ClearVehicleCustomPrimaryColour') .. n('ClearVehicleCustomSecondaryColour'), '11',
    '... setPropsLocal clears both on the live copy')
v1.fields.props = { colorPrimary = 1, colorSecondary = 3, mods = { [11] = -1 }, customPrimary = { 10, 20, 30 } }
eq(H.vehicle.update(v1, veh, 'set', {}), true, 'a custom colour again')
v1.fields.props = { colorPrimary = 1, colorSecondary = 3, mods = { [11] = -1 } }
eq(H.vehicle.update(v1, veh, 'set', {}), false, 'a custom colour that simply went (no false): re-create, as before')
v1.fields.props = { windowTint = 2 }
eq(H.vehicle.update(v1, veh, 'set', {}), false, 'colours may go (repainted), the mods may not: re-create')
v1.fields.model = 'banshee'
eq(H.vehicle.update(v1, veh, 'set', {}), false, 'vehicle model change: re-create')
eq(K.applyVehicleProps(veh, { colorPrimary = 3, colorSecondary = 4 }), true, 'C.kinds.applyVehicleProps')
args(last('SetVehicleColours'), 'applyVehicleProps applies at once', veh, 3, 4)
eq(env.Core.Vehicles.setPropsLocal(0, {}), false, 'setPropsLocal refuses a missing vehicle')
eq(env.Core.Vehicles.setPropsLocal(veh, 'x'), false, 'setPropsLocal refuses non-table props')
clear()
local netOk
env.CreateThread(function() netOk = env.Core.Vehicles.setProps(veh, { colorPrimary = 5, colorSecondary = 6 }) end)
tick(1200)
ok(n('NetworkRequestControlOfEntity') > 0, 'setProps (networked) still asks for control')
eq(netOk, false, 'setProps without control gives up after its wait')
H.vehicle.place(v1, veh, 1.0, 2.0, 3.0, 0.0, 0.0, 90.0)
args(last('SetEntityCoordsNoOffset'), 'vehicle place', veh, 1.0, 2.0, 3.0, false, false, false)
H.vehicle.destroy(v1, veh)
args(last('DeleteEntity'), 'vehicle destroy', veh)

-- 7b. a vehicle without colours of its own gets the stable pair the server paints its promoted clone with ----------
do
    local Scene = env.Core.Scene   -- the real lib (lib/scene/shared.lua): ONE PAINTS list for both VMs
    ok(type(Scene.paintOf) == 'function' and type(Scene.PAINTS) == 'table', 'lib/scene/shared.lua: paintOf + PAINTS')
    local a = node({ model = ADDER })
    local pa, qa = Scene.paintOf(a.id)
    local pair = Scene.PAINTS[a.id % #Scene.PAINTS + 1]
    ok(pa == pair[1] and qa == pair[2], 'paintOf(id) = PAINTS[id % 22 + 1]')
    clear()
    local va = H.vehicle.create(a, ctx(a))
    args(last('SetVehicleColours'), 'no props: painted with paintOf(node.id)', va, pa, qa)
    eq(n('SetVehicleColours'), 1, '... once')
    eq(K.paintOf(a.id), pa, 'C.kinds.paintOf reads the lib')
    local b = node({ model = ADDER, props = { customPrimary = { 1, 2, 3 } } })
    clear()
    local vb = H.vehicle.create(b, ctx(b))
    local pb, qb = Scene.paintOf(b.id)
    args(last('SetVehicleColours'), 'props without colorPrimary: still the stable pair', vb, pb, qb)
    ok(n('SetVehicleCustomPrimaryColour') == 1
        and log.SetVehicleColours[1].seq < log.SetVehicleCustomPrimaryColour[1].seq,
        '... painted BEFORE the props are applied (the clone owner\'s order)')
    local c = node({ model = ADDER, props = { colorPrimary = 12, colorSecondary = 34 } })
    clear()
    local vc = H.vehicle.create(c, ctx(c))
    eq(n('SetVehicleColours'), 1, 'props with colours win: no paint call ...')
    args(last('SetVehicleColours'), '... only the props colours', vc, 12, 34)
    local pc, qc = Scene.paintOf(c.id)
    c.fields = { model = ADDER, props = { windowTint = 1 } }
    clear()
    H.vehicle.update(c, vc, 'set', {})
    args(last('SetVehicleColours'), 'props lost their colours: the stable pair again', vc, pc, qc)
    clear()
    H.vehicle.update(c, vc, 'set', {})
    eq(n('SetVehicleColours'), 0, 'unchanged props: no paint call')
    c.fields = { model = ADDER, props = { windowTint = 1, colorPrimary = 5, colorSecondary = 6 } }
    clear()
    H.vehicle.update(c, vc, 'set', {})
    eq(n('SetVehicleColours'), 1, 'colours back in the props: no paint call ...')
    args(last('SetVehicleColours'), '... the props colours', vc, 5, 6)
    c.fields = { model = ADDER, props = { windowTint = 1 } }
    clear()
    eq(H.vehicle.update(c, vc, 'set', {}), true, 'the colours went again: in place ...')
    args(last('SetVehicleColours'), '... the stable pair', vc, pc, qc)
    c.fields = { model = ADDER }
    clear()
    eq(H.vehicle.update(c, vc, 'set', {}), false, 'props removed while a window tint is on the copy: re-create')
    eq(n('SetVehicleColours'), 0, '... nothing painted on the old copy (the new one gets the stable pair)')
    local saved = Scene.paintOf
    Scene.paintOf = nil
    local d = node({ model = ADDER })
    clear()
    local vd = H.vehicle.create(d, ctx(d))
    eq(n('SetVehicleColours'), 0, 'a lib without paintOf: no paint (the game\'s colours), no error')
    Scene.paintOf = saved
    for _, x in ipairs({ { a, va }, { b, vb }, { c, vc }, { d, vd } }) do H.vehicle.destroy(x[1], x[2]) end
end

-- 8. ped: local ped, look, stillness, scenario / clock-phased anim, weapon -----------------------------------------
local BIZ = hash('a_m_y_business_01')
local look = { components = { [11] = { drawable = 4 } } }
clear()
local d1 = node({ model = 'a_m_y_business_01', appearance = look, health = 150, weapon = 'WEAPON_PISTOL',
    scenario = 'WORLD_HUMAN_SMOKING', anim = { dict = 'x', clip = 'y' } }, { rz = 180.0 })
local ped = H.ped.create(d1, ctx(d1))
args(last('CreatePed'), 'CreatePed local', 4, BIZ, 100.0, 200.0, 30.0, 180.0, false, false)
args(last('SetPedDefaultComponentVariation'), 'deterministic look first', ped)
eq(#looks, 1, 'appearance through Spawn.applyAppearance')
ok(looks[1][1] == ped and looks[1][2] == look, 'applyAppearance(ped, fields.appearance)')
args(last('SetEntityInvincible'), 'invincible by default', ped, true, false)
args(last('FreezeEntityPosition'), 'frozen by default', ped, true)
args(last('SetBlockingOfNonTemporaryEvents'), 'events blocked by default', ped, true)
args(last('SetPedCanRagdoll'), 'frozen + invincible: no ragdoll', ped, false)
args(last('SetEntityMaxHealth'), 'health max', ped, 150)
args(last('SetEntityHealth'), 'health', ped, 150, 0, 0)
args(last('GiveWeaponToPed'), 'weapon in hand', ped, hash('WEAPON_PISTOL'), 0, false, true)
args(last('TaskStartScenarioInPlace'), 'scenario, no enter anim', ped, 'WORLD_HUMAN_SMOKING', 0, false)
eq(n('TaskPlayAnim'), 0, 'a scenario wins over an anim')
eq(H.ped.create(node({ model = ADDER })), nil, 'a vehicle model is no ped')
local dw = node({ model = BIZ, frozen = false })
clear()
local pedw = H.ped.create(dw, ctx(dw))
eq(n('SetPedCanRagdoll'), 0, 'not frozen: ragdoll allowed (default), no call')
W.collision = true
tick(300)
args(last('FreezeEntityPosition'), 'a free ped is released once collision is loaded', pedw, false)
W.collision = false
H.ped.destroy(dw, pedw)

clear()
local d2 = node({ model = BIZ, invincible = false, blockEvents = false,
    variation = { components = { [11] = { 5, 2, 0 }, ['3'] = { drawable = 1, texture = 0 } },
        props = { [0] = { drawable = 3, texture = 1 }, [1] = false } } })
local ped2 = H.ped.create(d2, ctx(d2))
eq(#looks, 1, 'variation does not use applyAppearance')
eq(n('SetPedComponentVariation'), 2, 'two components (a JSON string key too)')
ok(last('SetPedPropIndex')[1] == ped2 and last('SetPedPropIndex')[3] == 3, 'prop 0 set')
args(last('SetPedPropIndex'), 'SetPedPropIndex args', ped2, 0, 3, 1, true, 0)
args(last('ClearPedProp'), 'prop false cleared', ped2, 1, 0)
eq(n('SetEntityInvincible') + n('SetBlockingOfNonTemporaryEvents') + n('SetPedCanRagdoll'), 0,
    'not invincible / not blocking on a fresh ped: no calls')

W.clockNow = 6000
durations['amb@idle/base'] = 4.0
clear()
local d3 = node({ model = BIZ, anim = { dict = 'amb@idle', clip = 'base', t0 = 1000, rate = 2 } })
local ped3 = H.ped.create(d3, ctx(d3))
eq(#H.ped.assets(d3), 2, 'ped assets: model + anim dict')
args(last('TaskPlayAnim'), 'TaskPlayAnim at the clock phase, instant blend, looping',
    ped3, 'amb@idle', 'base', 1000.0, -1000.0, -1, 1, 0.5, false, false, false)
local _, pendingFix = K.pending()
eq(pendingFix, 1, 'a phase fix-up is pending')
W.clockNow = 6500
tick(300)
args(last('SetEntityAnimCurrentTime'), 'fix-up one tick later, re-phased on the clock', ped3, 'amb@idle', 'base', 0.75)
args(last('SetEntityAnimSpeed'), 'fix-up applies the rate', ped3, 'amb@idle', 'base', 2.0)
eq(select(2, K.pending()), 0, 'fix-up done')

clear()
d1.fields = { model = BIZ, appearance = { eyeColor = 3 }, invincible = false, scenario = 'WORLD_HUMAN_GUARD_STAND',
    weapon = 'WEAPON_BAT' }
eq(H.ped.update(d1, ped, 'set', {}), true, 'ped update in place')
args(last('SetPedDefaultComponentVariation'), 'a new look starts from the default', ped)
eq(looks[#looks][2].eyeColor, 3, 'the new appearance applied')
args(last('SetEntityInvincible'), 'invincible off', ped, false, false)
args(last('SetPedCanRagdoll'), 'ragdoll back once not invincible', ped, true)
args(last('ClearPedTasksImmediately'), 'old scenario cleared', ped)
args(last('TaskStartScenarioInPlace'), 'new scenario', ped, 'WORLD_HUMAN_GUARD_STAND', 0, false)
args(last('RemoveAllPedWeapons'), 'old weapon removed', ped, true)
args(last('GiveWeaponToPed'), 'new weapon', ped, hash('WEAPON_BAT'), 0, false, true)
clear()
d1.fields = { model = BIZ, appearance = d1.fields.appearance, invincible = false,
    anim = { dict = 'amb@idle', clip = 'base', loop = false, t0 = 6000 } }
H.ped.update(d1, ped, 'set', {})
args(last('RemoveAllPedWeapons'), 'weapon gone', ped, true)
eq(n('GiveWeaponToPed'), 0, 'no weapon given')
args(last('TaskPlayAnim'), 'anim on update: normal blend, hold last frame',
    ped, 'amb@idle', 'base', 8.0, -8.0, -1, 2, 0.125, false, false, false)
H.ped.place(d1, ped, 1.0, 2.0, 3.0, 9.0, 9.0, 270.0)
args(last('SetEntityCoordsNoOffset'), 'ped place', ped, 1.0, 2.0, 3.0, false, false, false)
args(last('SetEntityHeading'), 'ped heading from rz', ped, 270.0)
d1.fields.model = ADDER
eq(H.ped.update(d1, ped, 'set', {}), false, 'ped model change: re-create')
H.ped.destroy(d1, ped)
H.ped.destroy(d2, ped2)
H.ped.destroy(d3, ped3)
eq(K.pending(), 0, 'destroy drops pending work')

-- 9. riding: children on their parent's entity, attach targets -----------------------------------------------------
local parentNode = node({ model = BENCH })
local parentE = H.prop.create(parentNode, ctx(parentNode))
handles[parentNode.id] = parentE
clear()
local c1 = node({ model = BENCH }, { parent = parentNode.id, offset = { x = 0.5, y = 0.0, z = 1.0 },
    offrot = { 0.0, 0.0, 90.0 } })
local ce1 = H.prop.create(c1, ctx(c1))
args(last('AttachEntityToEntity'), 'child attached to the parent entity',
    ce1, parentE, 0, 0.5, 0.0, 1.0, 0.0, 0.0, 90.0, false, false, false, false, 2, true, false)
clear()
H.prop.place(c1, ce1, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0)
eq(n('SetEntityCoordsNoOffset'), 0, 'a rider is never placed by movers')
local c2 = node({ model = BENCH }, { parent = parentNode.id, bone = 'door_dside_f' })
local ce2 = H.prop.create(c2, ctx(c2))
args(last('GetEntityBoneIndexByName'), 'bone by name', parentE, 'door_dside_f')
eq(last('AttachEntityToEntity')[3], 12, 'the named bone index')
handles[parentNode.id] = true
local c3 = node({ model = BENCH }, { parent = parentNode.id })
clear()
H.prop.create(c3, ctx(c3))
eq(n('AttachEntityToEntity'), 0, 'a parent without an entity (group, fx): no attach')
clear()
local c4 = node({ model = BENCH }, { attach = { p = 5 }, bone = 57005 })
local ce4 = H.prop.create(c4, ctx(c4))
args(last('GetPlayerFromServerId'), 'player target by server id', 5)
args(last('GetPedBoneIndex'), 'ped bone tag', 9001, 57005)
args(last('AttachEntityToEntity'), 'attached to the player ped (isPed = true on a ped anchor: review RV6 F10)',
    ce4, 9001, 28, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, false, false, false, true, 2, true, false)
clear()
local c5 = node({ model = BENCH }, { attach = { n = 77 } })
local ce5 = H.prop.create(c5, ctx(c5))
args(last('NetworkDoesEntityExistWithNetworkId'), 'net id guard first', 77)
eq(n('NetworkGetEntityFromNetworkId'), 0, 'no lookup for an id this client does not hold')
eq(n('AttachEntityToEntity'), 0, 'target absent: not attached')
netEnts[77] = parentE
handles[parentNode.id] = parentE
clear()
eq(H.prop.update(c5, ce5, 'attach'), true, "an 'attach' update")
args(last('NetworkGetEntityFromNetworkId'), 'resolved once it exists', 77)
eq(last('AttachEntityToEntity')[2], parentE, 're-attached to the target')
clear()
c5.attach = nil
H.prop.update(c5, ce5, 'attach')
args(last('DetachEntity'), 'detached', ce5, false, false)
args(last('SetEntityCoordsNoOffset'), 'back at the node pose', ce5, 100.0, 200.0, 30.0, false, false, false)
do  -- run I1 (task 3): the node's rotation order (PUT extra `q` → the cache's node.rotOrder) reaches the attach
    clear()
    local c6 = node({ model = BENCH }, { parent = parentNode.id, offrot = { 10.0, 20.0, 30.0 }, rotOrder = 1 })
    local ce6 = H.prop.create(c6, ctx(c6))
    args(last('AttachEntityToEntity'), 'rotOrder 1: the 14th argument (a child)',
        ce6, parentE, 0, 0.0, 0.0, 0.0, 10.0, 20.0, 30.0, false, false, false, false, 1, true, false)
    local c7 = node({ model = BENCH }, { attach = { p = 5 }, bone = 57005, rotOrder = 0 })
    local ce7 = H.prop.create(c7, ctx(c7))
    eq(last('AttachEntityToEntity')[14], 0, 'rotOrder 0 on a player attachment')
    clear()
    c7.rotOrder = 5
    eq(H.prop.update(c7, ce7, 'attach'), true, "a new rotOrder is an 'attach' update ...")
    eq(last('AttachEntityToEntity')[14], 5, '... re-attached in the new order')
    c7.rotOrder = nil
    H.prop.update(c7, ce7, 'attach')
    eq(last('AttachEntityToEntity')[14], 2, 'no rotOrder: the engine default 2')
    H.prop.destroy(c6, ce6)
    H.prop.destroy(c7, ce7)
end
for _, x in ipairs({ { c1, ce1 }, { c2, ce2 }, { c4, ce4 }, { c5, ce5 } }) do H.prop.destroy(x[1], x[2]) end

-- 9b. run I1 (task 4): model hashes — '0x%08X' strings (server/remote.lua) are the hash, in GetHashKey's signed
-- int32 convention (the game answers signed; a joaat stand-in here), so one model is one cache / budget key -------
do
    local function joaat(name)                 -- GTA's one-at-a-time hash, signed like GetHashKey in the game
        local h = 0
        for i = 1, #name do
            h = (h + name:lower():byte(i)) & 0xFFFFFFFF
            h = (h + (h << 10)) & 0xFFFFFFFF
            h = h ~ (h >> 6)
        end
        h = (h + (h << 3)) & 0xFFFFFFFF
        h = h ~ (h >> 11)
        h = (h + (h << 15)) & 0xFFFFFFFF
        return h >= 0x80000000 and h - 0x100000000 or h
    end
    local stubHash = env.GetHashKey
    env.GetHashKey = joaat
    eq(joaat('adder'), -1216765807, 'the stand-in is the game hash (adder = 0xB779A091, signed)')
    eq(K.hashOf('adder'), -1216765807, 'a name goes through Utils.hash (GetHashKey)')
    eq(K.hashOf('0xB779A091'), -1216765807, "'0xB779A091' is that hash, signed like GetHashKey")
    eq(K.hashOf(('0x%08X'):format(joaat('prop_bench_01a') & 0xFFFFFFFF)), joaat('prop_bench_01a'),
        "server/remote.lua's '0x%08X' of a name's hash = the name's hash (one key, never two)")
    eq(K.hashOf('0xC2161726'), -1038739674, "'0xC2161726' (the attachment suite's hash)")
    eq(K.hashOf('0x0000051A'), 0x51A, 'leading zeros')
    eq(K.hashOf('0x1f'), 31, 'lower-case hex and fewer digits')
    eq(K.hashOf('0XFFFFFFFF'), -1, "'0X' and the top value (-1)")
    eq(K.hashOf(3078201489), -1216765807, 'an unsigned integer folds into the signed form')
    eq(K.hashOf(-1216765807), -1216765807, 'a signed one stays')
    eq(K.hashOf(3078201489.0), -1216765807, 'an integral float too')
    eq(K.hashOf(math.tointeger(2 ^ 40)), nil, 'beyond 32 bits: unusable')
    eq(K.hashOf('0x123456789'), joaat('0x123456789'), 'nine hex digits are no hash: a name')
    eq(K.hashOf('0xZZ'), joaat('0xZZ'), 'not hex: a name')
    eq(K.hashOf(''), nil, 'an empty name: unusable')
    local hn = node({ model = '0xB779A091' })
    eq(H.vehicle.assets(hn)[1].hash, -1216765807, "the model asset of a '0x' model is the signed hash")
    env.GetHashKey = stubHash
end

-- 10. §55.14 interactions: one prompt per descriptor while the node exists; a press asks the server ----------------
local function addsFor(id)
    local list = {}
    for iid, o in pairs(iadds) do
        if o.data and o.data.scene == id and not iremoved[iid] then list[#list + 1] = o end
    end
    table.sort(list, function(a, b) return a.data.action < b.data.action end)
    return list
end
local ia = { { action = 'sit', label = 'Sit down', distance = 1.5, cooldownMs = 800 }, { action = 'use' } }
local q1 = node({ model = BENCH }, { interact = ia })
local qe1 = H.prop.create(q1, ctx(q1))
local prompts = addsFor(q1.id)
eq(#prompts, 2, 'two descriptors, two prompts')
eq(K.interactCount(q1.id), 2, 'interactCount')
eq(prompts[1].entity, qe1, 'entity kinds target their entity')
eq(prompts[1].coords, nil, '... not coords')
eq(prompts[1].radius, 1.5, 'distance -> radius')
eq(prompts[1].label, 'Sit down', 'label')
eq(prompts[1].cooldown, 800, 'cooldownMs -> cooldown')
eq(prompts[2].label, 'use', 'no label: the action')
eq(prompts[2].radius, 2.0, 'default distance 2 m')
eq(prompts[2].cooldown, 500, 'default cooldown 500 ms')
eq(prompts[1].worldPrompt, nil, 'world prompt per Config.Interactions.WorldPrompt (off)')
prompts[1].onInteract({})
local em = emits[#emits]
ok(em and em[1] == 'core:scene:interact' and em[2] == q1.id and em[3] == 'sit' and em.n == 3,
    "a press sends core:scene:interact (id, action)")
local before = inext
H.prop.update(q1, qe1, 'set', {})
eq(inext, before, 'the same descriptors: no re-add')
q1.interact = { { action = 'open', label = 'Open' } }
H.prop.update(q1, qe1, 'set', { i = q1.interact })
eq(#addsFor(q1.id), 1, 'replaced descriptors: old prompts removed, new added')
eq(addsFor(q1.id)[1].data.action, 'open', 'the new prompt')
q1.interact = nil
H.prop.update(q1, qe1, 'interact')
eq(#addsFor(q1.id), 0, 'descriptors removed: prompts gone')
eq(K.interactCount(q1.id), 0, 'interactCount 0')
q1.interact = { { action = 'a' }, { action = 'b' }, { label = 'no action' }, { action = 'c' }, { action = 'd' },
    { action = 'e' }, { action = 'f' } }
H.prop.update(q1, qe1, 'interact')
eq(#addsFor(q1.id), 3, 'at most 4 descriptors looked at; one without action skipped')
H.prop.destroy(q1, qe1)
eq(#addsFor(q1.id), 0, 'destroy removes the prompts')
-- non-entity kinds: a point at the node
local q2 = node({ type = 1 }, { interact = { { action = 'buy', label = 'Buy' } } })
H.marker.create(q2, ctx(q2))
local mp = addsFor(q2.id)[1]
ok(mp and mp.entity == nil and env.type(mp.coords) == 'vector3', 'fx kinds: coords, no entity')
ok(mp.coords.x == 100.0 and mp.coords.y == 200.0 and mp.coords.z == 30.0, 'at the node position')
q2.x = 150.0
H.marker.update(q2, true, 'move')
eq(addsFor(q2.id)[1].coords.x, 150.0, "'move': the prompt follows")
H.marker.destroy(q2)
eq(#addsFor(q2.id), 0, 'fx destroy removes the prompts')
local g1 = node({}, { radius = 100.0, interact = { { action = 'join' } } })
eq(H.group.create(g1, ctx(g1)), true, 'group create: true')
eq(#addsFor(g1.id), 1, 'a group can carry prompts')
H.group.destroy(g1)
eq(#addsFor(g1.id), 0, 'group destroy removes them')
local gr = { H.group.radii(g1) }
ok(gr[1] == 100.0 and gr[2] == 100.0 and gr[3] == 125.0, 'group radii: the server radius (+ 25 %)')

-- 10b. §55.21.2 interaction descriptor `prompt = { world, offsetZ, range }`; a label-only change relabels in place --
do
    local function promptsOf(id)
        local list = {}
        for iid, o in pairs(iadds) do
            if o.data and o.data.scene == id and not iremoved[iid] then list[#list + 1] = { iid = iid, o = o } end
        end
        return list
    end
    local drop = node({ model = BENCH }, { interact = { { action = 'pickup', label = 'Water x2', distance = 1.6,
        prompt = { world = true, offsetZ = 0.4, range = 5 } } } })
    local de = H.prop.create(drop, ctx(drop))
    local pr = promptsOf(drop.id)
    eq(#pr, 1, 'one prompt')
    local wp = pr[1].o.worldPrompt
    ok(type(wp) == 'table', 'prompt.world = true: the world dot (even with Config.Interactions.WorldPrompt off)')
    ok(wp.offsetZ == 0.4 and wp.range == 5.0, 'offsetZ lifts the anchor, range = the draw range (§6.7 worldPrompt)')
    eq(pr[1].o.label, 'Water x2', 'the label')
    local before, removedBefore = inext, 0
    for _ in pairs(iremoved) do removedBefore = removedBefore + 1 end
    drop.interact = { { action = 'pickup', label = 'Water x3', distance = 1.6,
        prompt = { world = true, offsetZ = 0.4, range = 5 } } }   -- a count change: Scene.set(id, {}, { interact })
    H.prop.update(drop, de, 'interact')
    local removedAfter = 0
    for _ in pairs(iremoved) do removedAfter = removedAfter + 1 end
    ok(inext == before and removedAfter == removedBefore, 'a label-only change: nothing removed, nothing added')
    ok(ilabels[#ilabels][1] == pr[1].iid and ilabels[#ilabels][2] == 'Water x3', '... the live prompt is relabelled')
    eq(promptsOf(drop.id)[1].o.label, 'Water x3', 'the prompt shows the new count')
    local labelsBefore = #ilabels
    H.prop.update(drop, de, 'interact')
    eq(#ilabels, labelsBefore, 'the same list again: no call at all')
    drop.interact = { { action = 'pickup', label = 'Water x3', distance = 2.5,
        prompt = { world = true, offsetZ = 0.4, range = 5 } } }   -- another distance: a different prompt
    H.prop.update(drop, de, 'interact')
    ok(inext == before + 1 and #promptsOf(drop.id) == 1, 'anything but the label changed: re-created')
    eq(promptsOf(drop.id)[1].o.radius, 2.5, '... with the new distance')
    drop.interact = { { action = 'pickup', label = 'Water x3', prompt = { world = false } } }
    H.prop.update(drop, de, 'interact')
    eq(promptsOf(drop.id)[1].o.worldPrompt, false, 'prompt.world = false: the text UI, never the dot')
    drop.interact = { { action = 'pickup', prompt = { offsetZ = 0.4 } } }
    H.prop.update(drop, de, 'interact')
    eq(promptsOf(drop.id)[1].o.worldPrompt, nil, 'world absent: Config.Interactions.WorldPrompt decides (unchanged)')
    drop.interact = { { action = 'pickup', prompt = { world = true, offsetZ = 50, range = 0.1 } } }
    H.prop.update(drop, de, 'interact')
    local wp2 = promptsOf(drop.id)[1].o.worldPrompt
    ok(wp2.offsetZ == 10.0 and wp2.range == 0.5, 'offsetZ / range clamped (-10..10 m, 0.5..100 m)')
    H.prop.destroy(drop, de)
    eq(#promptsOf(drop.id), 0, 'destroy removes the prompt')
end

-- 11. lights and the per-frame draw loop (exists only while something is drawn) -----------------------------------
tick(100)   -- let any earlier loop finish
local f0 = frames
tick(1000)
eq(frames, f0, 'nothing drawn: no per-frame loop')
W.camPos, W.camRot, W.camSpeed = v3(100.0, 190.0, 30.0), v3(0.0, 0.0, 0.0), 0.0
local L1 = node({ color = { 255, 128, 0 }, intensity = 8, range = 10 })
local lr = { H.light.radii(L1) }
ok(lr[1] == 30.0 and lr[2] == 80.0 and lr[3] == 110.0, 'light radii: range x 3 | + 50 | + 30')
lr = { H.light.radii(node({ range = 100 })) }
ok(lr[1] == 300.0 and lr[2] == 300.0 and lr[3] == 330.0, 'light radii: R_in capped at 300')
clear()
eq(H.light.create(L1, ctx(L1)), true, 'light create answers true (no entity)')
eq(FX.stats().lights, 1, 'one light live')
args(last('DrawLightWithRange'), 'point light drawn at once', 100.0, 200.0, 30.0, 255, 128, 0, 10.0, 8.0)
local f1 = frames
tick(160)
ok(frames - f1 >= 9 and frames - f1 <= 11, 'drawn every frame while live')
eq(n('DrawLightWithRange'), frames - f1 + 1, 'one draw per frame')
W.camPos = v3(100.0, 250.0, 30.0)   -- 50 m away: beyond range x 3 (30 m), still LIVE (R_in 80 m)
tick(32)                            -- the pass that notices
clear()
local f3 = frames
tick(1000)
eq(n('DrawLightWithRange'), 0, 'past range x 3: not drawn')
eq(frames - f3, 0, 'F21: nothing within its draw range -> no per-frame loop')
eq(FX.stats().drawing, true, '... but the loop still exists (distance-gated)')
W.camPos = v3(100.0, 190.0, 30.0)
L1.fields = { color = { 255, 128, 0 }, intensity = 8, range = 10, falloff = 64 }
eq(H.light.update(L1, true, 'set', {}), true, 'light update in place')
tick(260)                           -- the idling loop comes back within IDLE_MS (250)
local f4 = frames
clear()
tick(160)
ok(frames - f4 >= 9, 'back within range: per frame again')
args(last('DrawLightWithRangeAndShadow'), 'falloff -> the falloff-exponent variant', 100.0, 200.0, 30.0, 255, 128, 0,
    10.0, 8.0, 64.0)
-- spot lights: direction from rotation (0 = down), `dir` wins; shadowed ids per frame, <= 4
local S1 = node({ type = 'spot', range = 20, intensity = 10, shadow = true })
H.light.create(S1, ctx(S1))
local sr = FX.recordOf(S1.id)
near(sr.dx, 0.0, 'spot from rotation 0: x')
near(sr.dz, -1.0, 'spot from rotation 0: points down')
local S2 = node({ type = 'spot', dir = { 0, 3, 4 }, shadow = true, inner = 5, outer = 40, falloff = 2 })
H.light.create(S2, ctx(S2))
local s2 = FX.recordOf(S2.id)
ok(math.abs(s2.dy - 0.6) < 1e-9 and math.abs(s2.dz - 0.8) < 1e-9, '`dir` normalised')
local S3 = node({ type = 'spot' }, { rx = 90.0, rz = 0.0 })
H.light.create(S3, ctx(S3))
local s3 = FX.recordOf(S3.id)
ok(math.abs(s3.dy - 1.0) < 1e-9 and math.abs(s3.dz) < 1e-9, 'pitch 90, yaw 0: horizontal along +y')
H.light.place(S3, true, 100.0, 200.0, 30.0, 90.0, 0.0, 90.0)
near(s3.dx, -1.0, 'movers turn a spot light (yaw 90 -> -x)')
local more = {}
for i = 1, 4 do
    more[i] = node({ type = 'spot', shadow = true })
    H.light.create(more[i], ctx(more[i]))
end
clear()
tick(16)
eq(n('DrawSpotLightWithShadow'), 4, 'at most 4 shadowed spot lights per frame')
eq(n('DrawSpotLight'), 3, 'the rest (and unshadowed ones) draw without a shadow')
local ids = {}
for _, c in ipairs(log.DrawSpotLightWithShadow) do ids[#ids + 1] = c[15] end
eq(table.concat(ids, ','), '0,1,2,3', 'shadow ids 0..n-1 per frame')
for _, c in ipairs(log.DrawSpotLightWithShadow) do
    if c[10] == 20.0 then args(c, 'spot args: range, intensity, inner 1, outer 30, exponent 1',
        100.0, 200.0, 30.0, 0.0, 0.0, -1.0, 255, 255, 255, 20.0, 10.0, 1.0, 30.0, 1.0, c[15]) end
end
for _, x in ipairs({ S1, S2, S3, more[1], more[2], more[3], more[4] }) do H.light.destroy(x) end
eq(FX.stats().fading, 7, 'seven spot lights destroyed in view: all fading out')
tick(500)
eq(FX.stats().fading + FX.stats().lights, 1, 'faded out and gone (L1 stays)')

-- flicker: deterministic, seeded, shared clock
local fl = FX.flickerAt
for t = 0, 2000, 97 do
    local g = fl(1, t, 7)
    ok(g >= 0.5 and g <= 1.0, 'candle within 0.5 .. 1 at t=' .. t)
end
eq(fl(3, 0, 0), 1.0, 'strobe on')
eq(fl(3, 50, 0), 0.0, 'strobe off 50 ms later')
eq(fl(3, 100, 0), 1.0, 'strobe on again')
local on = 0
for t = 0, 120 * 999, 120 do if fl(2, t, 3) == 1.0 then on = on + 1 end end
ok(on > 900 and on < 1000, 'neon: mostly on, some drop-outs (' .. on .. '/1000)')
eq(fl(2, 12345, 3), fl(2, 12345, 3), 'the same answer for the same clock and seed')
eq(fl(0, 5, 5), 1.0, 'no flicker: 1')

-- self fades: a late light ramps in; a destroy in view ramps out; a far destroy goes at once
clear()
local L2 = node({ intensity = 10, range = 10, flicker = 'strobe' })
H.light.create(L2, ctx(L2, true))
local l2 = FX.recordOf(L2.id)
eq(l2.a, 0.0, 'late arrival starts at 0')
tick(150)
ok(l2.a > 0.4 and l2.a < 0.65, 'half way after 150 of 300 ms (' .. l2.a .. ')')
tick(200)
eq(l2.a, 1.0, 'fully in after 300 ms')
eq(FX.stats().fading, 0, 'fade done')
W.clockNow = 50   -- strobe off phase for seed = id
L2.fields.flicker = nil
H.light.update(L2, true, 'set', {})
L2.fields.flicker = 'strobe'
H.light.update(L2, true, 'set', {})
clear()
H.light.destroy(L2)
eq(l2.dying, true, 'destroy in view: dying, fading out')
tick(200)
ok(l2.a > 0.3 and l2.a < 0.8 and FX.recordOf(L2.id) == l2, 'still fading (' .. l2.a .. ')')
tick(300)
eq(FX.recordOf(L2.id), nil, 'gone after 450 ms')
ok(l2.gone, 'finalised')
local L3 = node({ range = 10 })
H.light.create(L3, ctx(L3))
H.light.destroy(L3)
H.light.create(L3, ctx(L3))
eq(FX.recordOf(L3.id).dying, false, 'created again while fading out: the record is taken back')
W.camPos = v3(5000.0, 5000.0, 30.0)
H.light.destroy(L3)
eq(FX.recordOf(L3.id), nil, 'destroy far away: gone at once')
W.camPos, W.camSpeed = v3(100.0, 190.0, 30.0), 120.0
local L4 = node({ range = 10 })
H.light.create(L4, ctx(L4, true))
eq(FX.recordOf(L4.id).a, 1.0, 'no fade above Speed.NoFadeAbove')
H.light.destroy(L4)
eq(FX.recordOf(L4.id), nil, '... in either direction')
W.camSpeed = 0.0
eq(H.light.update(L4, true, 'set', {}), false, 'update of a gone light: false')
H.light.destroy(L1)
tick(600)
local f2 = frames
tick(500)
eq(frames, f2, 'the draw loop ended with the last light')
eq(FX.stats().drawing, false, 'not drawing')

-- 12. markers: DrawMarker in the loop, alpha over the last 10 m, culled behind the camera ------------------------
W.camPos, W.camRot = v3(100.0, 170.0, 30.0), v3(0.0, 0.0, 0.0)   -- 30 m south of the node, looking north (+y)
local M1 = node({ type = 2, scale = { 1, 2, 3 }, color = { r = 10, g = 20, b = 30, a = 200 }, bob = true, face = true,
    rotate = true, drawDistance = 50 })
local mr = { H.marker.radii(M1) }
ok(mr[1] == 50.0 and mr[2] == 60.0 and mr[3] == 80.0, 'marker radii: drawDistance | + 10 | + 20')
clear()
H.marker.create(M1, ctx(M1))
args(last('DrawMarker'), 'DrawMarker args', 2, 100.0, 200.0, 30.0, 0.0, 0.0, 0.0, 0.0, 0.0, 90.0, 1.0, 2.0, 3.0,
    10, 20, 30, 200, true, true, 2, true, nil, nil, false)
W.camPos = v3(100.0, 155.0, 30.0)   -- 45 m: 5 m into the 10 m band
clear()
tick(16)
eq(last('DrawMarker')[17], 100, 'alpha halved 5 m before the draw distance')
W.camPos = v3(100.0, 140.0, 30.0)   -- 60 m: beyond
clear()
tick(16)
eq(n('DrawMarker'), 0, 'beyond drawDistance: not drawn')
W.camPos, W.camRot = v3(100.0, 230.0, 30.0), v3(0.0, 0.0, 0.0)   -- 30 m north, looking north: behind the camera
tick(260)   -- the idling loop (nothing was in range) comes back within IDLE_MS
clear()
local f5 = frames
tick(160)
eq(n('DrawMarker'), 0, 'behind the camera: not drawn')
ok(frames - f5 >= 9, 'within range behind the camera: still per frame (turning around is instant)')
W.camRot = v3(0.0, 0.0, 180.0)   -- turn around
tick(16)
eq(n('DrawMarker'), 1, 'in front again: drawn')
M1.fields = { scale = 2, color = { 1, 2, 3 }, type = 99 }
H.marker.update(M1, true, 'set', {})
clear()
tick(16)
local mk = last('DrawMarker')
ok(mk[1] == 1 and mk[11] == 2.0 and mk[12] == 2.0 and mk[13] == 2.0, 'type 99 -> 1, number scale on all axes')
ok(mk[14] == 1 and mk[15] == 2 and mk[16] == 3, 'colour table as an array')
H.marker.destroy(M1)
tick(600)

-- 13. text: the §6.5 recipe per frame, long text in components, <= 20 draw-origin groups a frame --------------------
W.camPos, W.camRot = v3(100.0, 190.0, 30.0), v3(0.0, 0.0, 0.0)
local T1 = node({ text = 'Hello', scale = 0.5, font = 0, color = { 250, 240, 230, 255 }, outline = true })
local tr = { H.text.radii(T1) }
ok(tr[1] == 25.0 and tr[2] == 35.0 and tr[3] == 55.0, 'text radii: drawDistance 25 | + 10 | + 20')
clear()
H.text.create(T1, ctx(T1))
args(last('SetDrawOrigin'), 'SetDrawOrigin at the node', 100.0, 200.0, 30.0, false)
args(last('SetTextScale'), 'scale', 0.0, 0.5)
args(last('SetTextFont'), 'font', 0)
args(last('SetTextColour'), 'colour, alpha at full inside the band', 250, 240, 230, 255)
args(last('SetTextCentre'), 'centred', true)
eq(n('SetTextOutline'), 1, 'outline')
args(last('BeginTextCommandDisplayText'), 'STRING for short text', 'STRING')
args(last('AddTextComponentSubstringPlayerName'), 'the text', 'Hello')
args(last('EndTextCommandDisplayText'), 'drawn at the origin', 0.0, 0.0, 0)
eq(n('ClearDrawOrigin'), 1, 'origin cleared')
local long = string.rep('a', 97) .. 'éé' .. string.rep('b', 20)   -- é = 2 bytes; byte 99 is inside the first é
local label, t1, t2, t3 = FX.splitText(long)
eq(label, 'CELL_EMAIL_BCON', '> 99 bytes: the multi-component label')
eq(#t1, 99, 'first chunk 99 bytes (97 + one é)')
eq(t2, 'é' .. string.rep('b', 20), 'the next chunk starts at a character boundary')
eq(t3, nil, 'two chunks')
local _, a1 = FX.splitText(string.rep('x', 98) .. 'é')
eq(#a1, 98, 'a 2-byte character across byte 99 moves to the next chunk')
eq(FX.splitText('short'), 'STRING', 'short text: STRING')
eq(H.text.create(node({ text = '' }), nil), nil, 'text without text: failed')
eq(FX.recordOf(nid), nil, '... and no record left')
local many = {}
for i = 1, 25 do
    many[i] = node({ text = 't' .. i })
    H.text.create(many[i], ctx(many[i]))
end
clear()
tick(16)
eq(n('SetDrawOrigin'), 20, '26 texts in view: 20 draw-origin groups a frame')
H.text.destroy(T1)
for i = 1, 25 do H.text.destroy(many[i]) end
tick(600)

-- 14. particles: asset in WARM, UseParticleFxAsset before every start, alpha ramps, stop ---------------------------
local P1 = node({ asset = 'core', name = 'ent_amb_smoke_foundry', scale = 2, color = { 255, 0, 0 }, alpha = 0.5 },
    { rx = 1.0, ry = 2.0, rz = 3.0 })
local pa = H.particle.assets(P1)
ok(#pa == 1 and pa[1].type == 'ptfx' and pa[1].name == 'core', 'particle asset: the ptfx dictionary')
eq(#H.particle.assets(node({ asset = 'core' })), 0, 'no effect name: no assets')
local pr = { H.particle.radii(P1) }
ok(pr[1] == 150.0 and pr[2] == 160.0 and pr[3] == 180.0, 'particle radii: drawDistance 150 | + 10 | + 20')
clear()
eq(H.particle.create(P1, ctx(P1)), true, 'particle create: true (the ptfx handle stays private)')
args(last('UseParticleFxAsset'), 'asset first', 'core')
args(last('StartParticleFxLoopedAtCoord'), 'looped at the node', 'ent_amb_smoke_foundry', 100.0, 200.0, 30.0,
    1.0, 2.0, 3.0, 2.0, false, false, false, false)
local ph = FX.recordOf(P1.id).h
args(last('SetParticleFxLoopedColour'), 'colour 0..1', ph, 1.0, 0.0, 0.0, false)
args(last('SetParticleFxLoopedAlpha'), 'alpha', ph, 0.5)
clear()
P1.fields.scale, P1.fields.color = 3, nil
eq(H.particle.update(P1, true, 'set', {}), true, 'particle update in place')
args(last('SetParticleFxLoopedScale'), 'scale in place', ph, 3.0)
args(last('SetParticleFxLoopedColour'), 'colour removed -> white', ph, 1.0, 1.0, 1.0, false)
H.particle.place(P1, true, 5.0, 6.0, 7.0, 0.0, 0.0, 45.0)
args(last('SetParticleFxLoopedOffsets'), 'movers move the effect', ph, 5.0, 6.0, 7.0, 0.0, 0.0, 45.0)
P1.fields.name = 'other'
eq(H.particle.update(P1, true, 'set', {}), false, 'another effect: re-create')
P1.fields.name = 'ent_amb_smoke_foundry'
W.camPos = v3(100.0, 190.0, 30.0)
clear()
H.particle.destroy(P1)   -- in view (the record sits at 5, 6, 7 after place: move it back first)
args(last('StopParticleFxLooped'), 'destroyed out of view: stopped at once', ph, false)
eq(FX.recordOf(P1.id), nil, 'record gone')
local P2 = node({ asset = 'core', name = 'fire' })
clear()
H.particle.create(P2, ctx(P2, true))
local p2 = FX.recordOf(P2.id)
args(log.SetParticleFxLoopedAlpha[#log.SetParticleFxLoopedAlpha], 'late: alpha starts at 0', p2.h, 0.0)
tick(160)
local mid = last('SetParticleFxLoopedAlpha')[2]
ok(mid > 0.3 and mid < 0.7, 'alpha ramps in (' .. mid .. ')')
tick(200)
args(last('SetParticleFxLoopedAlpha'), 'fully in', p2.h, 1.0)
clear()
local p2h = p2.h
H.particle.destroy(P2)
eq(n('StopParticleFxLooped'), 0, 'destroyed in view: not stopped yet')
tick(500)
args(last('StopParticleFxLooped'), 'stopped once faded out', p2h, false)
eq(last('SetParticleFxLoopedAlpha')[2], 0.0, 'ramped to 0 first')
local P3 = node({ asset = 'core', name = 'spark' }, { parent = parentNode.id, offset = { 0.0, 0.0, 1.0 } })
clear()
H.particle.create(P3, ctx(P3))
args(last('StartParticleFxLoopedOnEntity'), 'a child plays on its parent entity', 'spark', parentE, 0.0, 0.0, 1.0,
    0.0, 0.0, 0.0, 1.0, false, false, false)
local P4 = node({ asset = 'core', name = 'spark' }, { parent = parentNode.id, bone = 'exhaust' })
H.particle.create(P4, ctx(P4))
args(last('StartParticleFxLoopedOnEntityBone'), 'with a bone', 'spark', parentE, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 12,
    1.0, false, false, false)
clear()
H.particle.place(P3, true, 1.0, 1.0, 1.0, 0.0, 0.0, 0.0)
eq(n('SetParticleFxLoopedOffsets'), 0, 'an effect on an entity is not moved by movers')
eq(H.particle.update(P3, true, 'attach'), false, "an 'attach' change re-creates the effect")
local keepLit = node({ range = 10 })
H.light.create(keepLit, ctx(keepLit))
eq(FX.stats().drawing, true, 'the draw loop is running')
local P5 = node({ asset = 'core', name = 'fire' })
clear()
H.particle.create(P5, ctx(P5, true))
args(last('SetParticleFxLoopedAlpha'), 'late while the loop runs: alpha 0 before any frame', FX.recordOf(P5.id).h, 0.0)
H.particle.destroy(P5)
H.light.destroy(keepLit)
W.ptfxFail = true
eq(H.particle.create(node({ asset = 'core', name = 'bad' })), nil, 'a failed start: nil')
W.ptfxFail = false
H.particle.destroy(P3)
H.particle.destroy(P4)
tick(600)

-- 15. hides: CreateModelHideExcludingScriptObjects while live, budget (Caps.hides = 3 here), swaps in place -----------
local ROCK = hash('prop_rock_4_a')
local hr = { H.hide.radii(node({ model = ROCK, radius = 2 })) }
ok(hr[1] == 0 and hr[2] == 152.0 and hr[3] == 202.0, 'hide radii: none | radius + 150 | + 50')
clear()
local hn = {}
for i = 1, 5 do
    hn[i] = node({ model = 'prop_rock_4_a', radius = 2 }, { x = 10.0 * i })
    eq(H.hide.create(hn[i], ctx(hn[i])), true, 'hide ' .. i .. ' live')
end
eq(n('CreateModelHideExcludingScriptObjects'), 3, 'only Caps.hides applied')
args(log.CreateModelHideExcludingScriptObjects[1], 'hide args', 10.0, 200.0, 30.0, 2.0, ROCK, true)
eq(FX.stats().hidesWaiting, 2, 'two wait for a slot')
eq(FX.stats().zoning, false, '... and keep no world loop alive (run I1: only a release frees a hide slot)')
eq(FX.recordOf(hn[1].id).kind, 'hide', 'C.fx.recordOf covers scene_world.lua records')
ok(FX.stats().lights ~= nil and FX.stats().hides == 3, 'C.fx.stats: both files in one table')
H.hide.destroy(hn[2])
args(last('RemoveModelHide'), 'RemoveModelHide on destroy', 20.0, 200.0, 30.0, 2.0, ROCK, false)
args(last('CreateModelHideExcludingScriptObjects'), 'the oldest waiter takes the slot',
    40.0, 200.0, 30.0, 2.0, ROCK, true)
H.hide.destroy(hn[5])
eq(n('RemoveModelHide'), 1, 'a waiting hide was never applied: nothing to remove')
eq(FX.stats().hidesWaiting, 0, '... and it left the queue')
clear()
hn[1].x = 11.0
eq(H.hide.update(hn[1], true, 'move'), true, 'hide move')
args(last('RemoveModelHide'), 'old hide removed', 10.0, 200.0, 30.0, 2.0, ROCK, false)
args(last('CreateModelHideExcludingScriptObjects'), 'new hide at the new place', 11.0, 200.0, 30.0, 2.0, ROCK, true)
eq(FX.stats().hides, 3, 'the slot was kept')
eq(H.hide.create(node({ radius = 2 })), nil, 'a hide without a model: failed')

-- 15b. F13 after phase D: Core.Maps' hides are scene hide nodes, so Caps.hides alone is the one map-change budget —
-- Core.Maps.stats() is never sampled (run I1: the 1/s read was dead and allocated) ---------------------------------
do
local mapsStats = 0
env.Core.Maps = { stats = function() mapsStats = mapsStats + 1 return { hides = 5, objects = 9 } end }
H.hide.destroy(hn[3])                      -- scene hides 3 -> 2 (Caps.hides = 3 in this suite)
tick(1100)
clear()
local hm = node({ model = 'prop_rock_4_a', radius = 2 }, { x = 70.0 })
eq(H.hide.create(hm, ctx(hm)), true, 'a hide in the last free slot is live ...')
args(last('CreateModelHideExcludingScriptObjects'), '... and applied at once (2 scene hides < Caps.hides 3)',
    70.0, 200.0, 30.0, 2.0, ROCK, true)
eq(FX.stats().mapsHides, nil, 'no separate Core.Maps hide count any more')
tick(3000)
eq(mapsStats, 0, 'Core.Maps.stats() is never read')
eq(FX.stats().hidesWaiting, 0, 'nothing waits')
env.Core.Maps = nil
end

-- 16. zones: 4 Hz containment of the player ped -> enter / exit through C.fx.onZone ----------------------------------
local zev, emitted = {}, {}
ok(FX.onZone(function(nd, ev) zev[#zev + 1] = nd.id .. ':' .. ev end), 'onZone registered')
C.emit = function(ev, nd) emitted[#emitted + 1] = ev .. ':' .. nd.id end   -- client/scene.lua's listener entry
eq(FX.onZone('x'), false, 'onZone wants a function')
local contains, zticks = env.Core.Geometry.contains, 0
env.Core.Geometry.contains = function(...) zticks = zticks + 1 return contains(...) end
local Z1 = node({ shape = { type = 'sphere', radius = 5 } })
local zr = { H.zone.radii(Z1) }
ok(zr[1] == 0 and zr[2] == 25.0 and zr[3] == 45.0, 'zone radii: none | bounding radius + 20 | + 20')
local zb = FX.zoneShape({ type = 'box', size = { 2, 2, 2 } }, 1.0, 2.0, 3.0, 45.0)
ok(zb and zb.coords.x == 1.0 and zb.rotation == 45.0, 'a box without coords/rotation takes the node pose and yaw')
W.playerPos = v3(0.0, 0.0, 0.0)
eq(H.zone.create(Z1, ctx(Z1)), true, 'zone create')
eq(H.zone.create(node({ shape = { type = 'nope' } })), nil, 'an unusable shape: failed')
tick(260)
eq(#zev, 0, 'player outside: no event')
W.playerPos = v3(101.0, 201.0, 30.0)
tick(250)
eq(zev[#zev], Z1.id .. ':enter', 'enter')
eq(emitted[#emitted], 'enter:' .. Z1.id, "... raised through C.emit('enter', node) as well")
tick(250)
eq(#zev, 1, 'no repeat while inside')
H.zone.place(Z1, true, 200.0, 200.0, 30.0)   -- a mover carries the zone away
tick(250)
eq(zev[#zev], Z1.id .. ':exit', 'exit when the zone moved away')
H.zone.place(Z1, true, 100.0, 200.0, 30.0)
tick(250)
eq(zev[#zev], Z1.id .. ':enter', 'enter again')
Z1.fields = { shape = Z1.fields.shape, events = false }
H.zone.update(Z1, true, 'set', {})
W.playerPos = v3(0.0, 0.0, 0.0)
tick(250)
eq(zev[#zev], Z1.id .. ':enter', 'events = false: silent')
Z1.fields.events = true
H.zone.update(Z1, true, 'set', {})
W.playerPos = v3(101.0, 201.0, 30.0)
tick(250)
H.zone.destroy(Z1)
eq(zev[#zev], Z1.id .. ':exit', 'a zone destroyed while inside says exit')
eq(emitted[#emitted], 'exit:' .. Z1.id, '... through C.emit too')
eq(#emitted, #zev, 'C.emit and onZone heard the same events')
local zt = zticks
tick(1000)
eq(zticks, zt, 'no zone, no containment loop')

-- 17. sounds: ids <= Caps.sounds (2 here), the rest wait; one-shots release their id when finished -------------------
local sr1 = { H.sound.radii(node({ range = 30 })) }
ok(sr1[1] == 30.0 and sr1[2] == 50.0 and sr1[3] == 70.0, 'sound radii: range | + 20 | + 40')
clear()
local so = {}
for i = 1, 3 do
    so[i] = node({ name = 'Loop' .. i, set = 'SET' }, { x = i + 0.0 })
    eq(H.sound.create(so[i], ctx(so[i])), true, 'sound ' .. i .. ' live')
end
eq(n('GetSoundId'), 2, 'two sound ids taken')
args(log.PlaySoundFromCoord[1], 'PlaySoundFromCoord args', 1, 'Loop1', 1.0, 200.0, 30.0, 'SET', false, 0, false)
eq(FX.stats().soundsWaiting, 1, 'the third waits')
H.sound.destroy(so[1])
args(last('StopSound'), 'stop', 1)
args(last('ReleaseSoundId'), 'release', 1)
eq(last('PlaySoundFromCoord')[2], 'Loop3', 'the waiter plays on the freed id')
H.sound.destroy(so[2])
H.sound.destroy(so[3])
eq(FX.stats().sounds, 0, 'all ids back')
clear()
local one = node({ name = 'Beep', looped = false })
H.sound.create(one, ctx(one))
local sid = last('GetSoundId') and sidNext
tick(300)
eq(n('ReleaseSoundId'), 0, 'still playing')
finished[sid] = true
tick(300)
args(last('ReleaseSoundId'), 'finished one-shot: id released', sid)
eq(n('StopSound'), 0, '... without a stop')
H.sound.event(one, true, 'play', nil, 0)
eq(n('GetSoundId'), 2, "C4 'play' plays it again on a new id")
H.sound.event(one, true, 'stop', nil, 0)
args(last('StopSound'), "C4 'stop'", sidNext)
local child = node({ name = 'Engine' }, { parent = parentNode.id })
clear()
H.sound.create(child, ctx(child))
args(last('PlaySoundFromEntity'), 'a child sound plays from its parent entity',
    sidNext, 'Engine', parentE, nil, false, 0)
child.fields = { name = 'Engine2' }
H.sound.update(child, true, 'set', {})
eq(last('PlaySoundFromEntity')[2], 'Engine2', 'another sound: restarted in place')
eq(H.sound.create(node({})), nil, 'a sound without a name: failed')

-- 17b. F20: guarded loops — a failing record is logged once and dropped; the loop and the others keep going ----------
do
local logged, logLib = {}, env.Core.Log
local origError = logLib.error
logLib.error = function(fmt, ...) logged[#logged + 1] = tostring(fmt):format(...) end
local function loggedWith(needle)
    local c = 0
    for _, m in ipairs(logged) do if m:find(needle, 1, true) then c = c + 1 end end
    return c
end
-- (a) the fx draw loop: one light's draw throws
W.camPos, W.camRot = v3(100.0, 190.0, 30.0), v3(0.0, 0.0, 0.0)
local drawLightNat = env.DrawLightWithRange
env.DrawLightWithRange = function(...)
    drawLightNat(...)
    if select(8, ...) == 13.0 then error('bad light') end
end
local goodL, badL = node({ range = 10, intensity = 4 }), node({ range = 10, intensity = 13 }, { x = 101.0 })
H.light.create(goodL, ctx(goodL))
H.light.create(badL, ctx(badL))
tick(200)
eq(loggedWith('fx draw loop'), 1, 'draw loop: the error is logged once')
eq(FX.recordOf(badL.id), nil, '... the failing light is dropped')
ok(FX.recordOf(goodL.id) ~= nil, '... the other light stays')
clear()
local f7 = frames
tick(160)
ok(frames - f7 >= 9 and n('DrawLightWithRange') >= 9, 'the loop still draws the good light every frame')
eq(H.light.update(badL, true, 'set', {}), false, "the dropped light's next update asks for a re-create")
eq(loggedWith('fx draw loop'), 1, 'still logged once')
env.DrawLightWithRange = drawLightNat
H.light.destroy(goodL)
tick(600)
-- (b) the world tick: one zone's containment throws
local containsNow = env.Core.Geometry.contains
env.Core.Geometry.contains = function(shape, pt)
    if shape.radius == 7 then error('bad shape') end
    return containsNow(shape, pt)
end
W.playerPos = v3(0.0, 0.0, 0.0)
local zGood = node({ shape = { type = 'sphere', radius = 5 } })
local zBad = node({ shape = { type = 'sphere', radius = 7 } })
H.zone.create(zGood, ctx(zGood))
H.zone.create(zBad, ctx(zBad))
tick(260)
eq(loggedWith('world tick'), 1, 'world tick: the error is logged once')
eq(FX.recordOf(zBad.id), nil, '... the failing zone is dropped')
W.playerPos = v3(101.0, 201.0, 30.0)
tick(260)
eq(zev[#zev], zGood.id .. ':enter', 'the other zone still fires enter')
tick(1000)
eq(loggedWith('world tick'), 1, 'still logged once')
env.Core.Geometry.contains = containsNow
H.zone.destroy(zGood)
-- (c) the kinds maintenance thread: one entity's collision read throws
local hasCollNat, badE = env.HasCollisionLoadedAroundEntity, nil
env.HasCollisionLoadedAroundEntity = function(e)
    if e == badE then error('bad entity') end
    return hasCollNat(e)
end
W.camPos, W.collision = v3(100.0, 205.0, 30.0), true
local wGood, wBad = node({ model = BENCH, frozen = false }), node({ model = BENCH, frozen = false })
local eGood = H.prop.create(wGood, ctx(wGood))
badE = H.prop.create(wBad, ctx(wBad))
clear()
tick(300)
eq(loggedWith('kinds maintenance'), 1, 'maintenance: the error is logged once')
args(last('FreezeEntityPosition'), 'the other entity is still woken', eGood, false)
eq(select(1, K.pending()), 0, 'the failing entry was dropped (nothing pending, the thread ends)')
env.HasCollisionLoadedAroundEntity = hasCollNat
W.collision = false
H.prop.destroy(wGood, eGood)
H.prop.destroy(wBad, badE)
logLib.error = origError
end

-- 18. shutdown: everything the game holds goes, nothing waits, nothing fires ------------------------------------------
local ZS = node({ shape = { type = 'sphere', radius = 50 } })
H.zone.create(ZS, ctx(ZS))
tick(260)
local evs = #zev
local keep = node({ model = BENCH })
local keepE = H.prop.create(keep, ctx(keep))
local lastLight = node({ range = 10 })
H.light.create(lastLight, ctx(lastLight))
eq(FX.stats().lights, 1, 'a light is live before the shutdown')
clear()
FX.shutdown()
K.shutdown()
eq(n('RemoveModelHide'), 3, 'hides removed')
eq(FX.stats().lights + FX.stats().fading, 0, 'FX.shutdown covers scene_fx.lua too')
eq(FX.recordOf(lastLight.id), nil, '... the light is gone at once (no fade-out while core stops)')
ok(n('StopSound') >= 1 and FX.stats().sounds == 0, 'sounds stopped')
eq(#zev, evs, 'no exit fired while core stops')
ok(ents[keepE].deleted, 'entities deleted')
eq(K.stats().prop + K.stats().vehicle + K.stats().ped, 0, 'no entity state left')
eq(K.stats().prompts, 0, 'no prompts left')

-- 19. §55.21.3 player attachments end to end: the REAL materialiser + movers (A5's harness) with this file's prop
-- create(): the kind attaches at create, the movers adopt it and re-attach when the player's ped handle changes
do
    -- fxlint-disable-next-line S006 -- offline harness loads checked-in stubs only
    local HS = dofile(here .. '/client_scene_harness.lua')
    local h = HS.new({})
    h.loadMat()
    for _, name in ipairs({ 'SetEntityCollision', 'SetEntityInvincible', 'SetDisableFragDamage', 'SetEntityVisible',
        'SetObjectTextureVariation' }) do h.env[name] = function() end end
    h.load('client/scene_kinds.lua')
    local M = h.C.mat
    h.cam(0, 0, 20, 0, 0)
    local ped = h.newEntity(0, 0, 20, 0, 1)        -- type 1: a ped
    h.players[5] = ped
    local HP = 0x51A7
    M.add(h.node(1, 'prop', 'prop', 0, 20, 0, { model = HP, collision = false },
        { attach = { player = 5 }, bone = 57005, offset = { x = 0.1, y = 0.0, z = 0.0 }, rotOrder = 1 }))
    h.tick(1500)
    local e = M.handleOf(1)
    ok(e ~= nil, "§55.21.3: the player's attached prop exists (real materialiser)")
    eq(h.ents[e].attachedTo, ped, "the kind's create() attached it to the player's ped")
    eq(h.ents[e].bone, 57005 + 1000, '... on the ped bone of the tag (GetPedBoneIndex)')
    eq(h.ents[e].attachArgs.n, 16, '... with the 16-argument AttachEntityToEntity')
    eq(h.ents[e].attachArgs[14], 1, "... in the node's rotation order (Core.Attachments sends 1)")
    local attaches = h.n('AttachEntityToEntity')
    eq(attaches, 1, "one AttachEntityToEntity: the kind's own")
    h.frames(60)
    eq(h.n('AttachEntityToEntity'), attaches, 'the movers adopt that attachment: attached once')
    h.ents[ped].deleted = true                       -- a respawn: the old ped is gone, a new one takes over
    local ped2 = h.newEntity(0, 0, 25, 0, 1)
    h.players[5] = ped2
    h.tick(1000)
    eq(h.ents[e].attachedTo, ped2, 'respawn: re-attached to the new ped within 1 s')
    eq(h.ents[e].attachArgs[14], 1, "... the movers' re-attach (C.mat.attachTo) keeps the rotation order")
    local ped3 = h.newEntity(0, 0, 30, 0, 1)         -- a model swap while the old ped still exists
    h.players[5] = ped3
    h.tick(1000)
    eq(h.ents[e].attachedTo, ped3, 'model swap: re-attached within 1 s')
    eq(h.ents[e].bone, 57005 + 1000, '... on the same bone')
    M.shutdown()
    h.tick(1000)
end

-- 19b. run I1 end to end on the REAL materialiser: task 8 — a REMOVED plate re-creates the local vehicle copy (a plate
-- change stays in place); task 4 — a prop by name and one by '0x' + its hash share ONE model key. A function of its
-- own: the main chunk is at Lua's 200-locals limit.
local function endToEndI1()
    -- fxlint-disable-next-line S006 -- offline harness loads checked-in stubs only
    local HS = dofile(here .. '/client_scene_harness.lua')
    local h = HS.new({})
    h.loadMat()
    local calls = {}
    local function stub(name, fn)
        h.env[name] = function(...)
            calls[name] = (calls[name] or 0) + 1
            if fn then return fn(...) end
        end
    end
    for _, name in ipairs({ 'SetEntityCollision', 'SetEntityInvincible', 'SetDisableFragDamage', 'SetEntityVisible',
        'SetObjectTextureVariation', 'SetVehicleColours', 'SetVehicleNumberPlateText', 'SetVehicleDoorsLocked',
        'SetVehicleEngineOn', 'SetVehicleLights', 'SetVehicleFullbeam', 'SetVehicleSiren', 'SetVehicleDirtLevel' }) do
        stub(name)
    end
    stub('CreateVehicle', function(model, x, y, z) return h.newEntity(model, x, y, z, 2) end)
    local function joaat(name)                 -- signed, like GetHashKey in the game
        local x = 0
        for i = 1, #name do
            x = (x + name:lower():byte(i)) & 0xFFFFFFFF
            x = (x + (x << 10)) & 0xFFFFFFFF
            x = x ~ (x >> 6)
        end
        x = (x + (x << 3)) & 0xFFFFFFFF
        x = x ~ (x >> 11)
        x = (x + (x << 15)) & 0xFFFFFFFF
        return x >= 0x80000000 and x - 0x100000000 or x
    end
    h.env.GetHashKey = joaat
    h.load('client/scene_kinds.lua')
    local M = h.C.mat
    h.cam(0, 0, 20, 0, 0)
    local ADDERH = joaat('adder')
    h.models[ADDERH] = { mode = 'vehicle' }
    local vn = h.node(1, 'vehicle', 'vehicle', 0, 20, 0, { model = 'adder', plate = 'AB 12', dirt = 3 })
    M.add(vn)
    h.tick(3000)
    local e1 = M.handleOf(1)
    ok(e1 ~= nil and h.ents[e1].model == ADDERH, 'I1: the local vehicle copy is live (real materialiser)')
    eq(calls.SetVehicleNumberPlateText, 1, 'I1: its plate was set')
    vn.fields = { model = 'adder', plate = 'CD 34', dirt = 3 }
    M.update(vn, 'fields', { plate = true })
    h.tick(500)
    eq(M.handleOf(1), e1, 'I1: a plate CHANGE keeps the copy (in place)')
    eq(calls.SetVehicleNumberPlateText, 2, 'I1: ... with the new plate')
    local created = calls.CreateVehicle
    vn.fields = { model = 'adder', dirt = 3 }
    M.update(vn, 'fields', { plate = true })
    h.tick(4000)
    local e2 = M.handleOf(1)
    ok(e2 ~= nil and e2 ~= e1, 'I1: the plate REMOVED: the materialiser re-created the copy')
    eq(calls.CreateVehicle, created + 1, 'I1: ... one new CreateVehicle')
    ok(h.ents[e1].deleted, 'I1: ... the copy with the stale plate is gone')
    eq(calls.SetVehicleNumberPlateText, 2, "I1: ... and the new one keeps the game's own plate")
    local PB = joaat('prop_bench_01a')
    M.add(h.node(2, 'prop', 'prop', 2, 20, 0, { model = 'prop_bench_01a' }))
    M.add(h.node(3, 'prop', 'prop', -2, 20, 0, { model = ('0x%08X'):format(PB & 0xFFFFFFFF) }))
    h.tick(3000)
    local p2, p3 = M.handleOf(2), M.handleOf(3)
    ok(p2 ~= nil and p3 ~= nil, "I1: a prop by name and one by its '0x%08X' hash are live")
    ok(h.ents[p2].model == PB and h.ents[p3].model == PB, 'I1: ... both created from the same (signed) hash')
    eq(h.requested[PB], 1, 'I1: ONE model request for both (one asset key, never two)')
    eq(M.stats().models.props, 1, 'I1: one prop model slot in use')
    M.shutdown()
    h.tick(1000)
end
endToEndI1()

-- 19c. the final fix round (FX2) end to end on the REAL materialiser + kinds: RV6 F4 — a removed node's prompt goes
-- at once while its entity still retires (`restart inventory` showed every drop's prompt twice); RV6 F10 — a player
-- attachment rides the ped with isPed = true. A function of its own (the main chunk's 200-locals limit).
local function endToEndFX2()
    -- fxlint-disable-next-line S006 -- offline harness loads checked-in stubs only
    local HS = dofile(here .. '/client_scene_harness.lua')
    local h = HS.new({})
    h.loadMat()
    for _, name in ipairs({ 'SetEntityInvincible', 'SetDisableFragDamage', 'SetObjectTextureVariation' }) do
        h.env[name] = function() end
    end
    local live, seq = {}, 0
    h.env.Core.Interactions = {
        add = function(o)
            seq = seq + 1
            live[seq] = o
            return seq
        end,
        remove = function(id) live[id] = nil end,
        setLabel = function() end,
    }
    local function prompts()
        local c = 0
        for _ in pairs(live) do c = c + 1 end
        return c
    end
    h.load('client/scene_kinds.lua')
    local M, KK = h.C.mat, h.C.kinds
    h.cam(0, 0, 20, 0, 0)
    local drop = { { action = 'pickup', label = 'Bread' } }
    local n1 = h.node(1, 'prop', 'prop', 0, 20, 0, { model = 1001 }, { interact = drop })
    M.add(n1)
    h.tick(3000)
    local e1 = M.handleOf(1)
    ok(e1 ~= nil and KK.interactCount(1) == 1 and prompts() == 1, 'FX2 e2e: a drop-like prop with its prompt')
    M.remove(n1)                                                   -- `stop inventory`: DEL normal, in view
    ok(not h.ents[e1].deleted, 'RV6 F4 e2e: removed in view, the entity still retires ...')
    eq(prompts(), 0, 'RV6 F4 e2e: ... but its prompt is gone at once')
    M.add(h.node(2, 'prop', 'prop', 0, 20, 0, { model = 1001 }, { interact = drop }))   -- `ensure inventory`
    h.tick(3000)
    eq(prompts(), 1, 'RV6 F4 e2e: the drop rebuilt as a new node shows its prompt ONCE (was twice)')
    h.players[5] = h.newEntity(0, 3.0, 20.0, 0.0, 1)
    M.add(h.node(3, 'prop', 'prop', 3, 20, 0, { model = 1001 }, { attach = { p = 5 }, bone = 28422, rotOrder = 1 }))
    h.tick(3000)
    local a = M.handleOf(3)
    ok(a ~= nil and h.ents[a].attachedTo == h.players[5], 'FX2 e2e: a player attachment rides the ped')
    eq(a and h.ents[a].attachArgs[13], true, 'RV6 F10 e2e: ... with isPed = true (the retired applier did)')
    eq(a and h.ents[a].attachArgs[14], 1, '... in its rotation order')
    M.shutdown()
    h.tick(1000)
end
endToEndFX2()

eq(#stubs.failures, 0, 'no thread errors')
print(('client scene kinds: %d passed, 0 failed'):format(passed))
