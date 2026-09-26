-- Offline tests for the client map runtime (DESIGN §52.4): client/maps_spawn.lua (engine),
-- client/maps_view.lua (markers, hides, editor view) and client/maps.lua (wire, regions, window, API).
-- A stub client VM on the stubs' virtual clock; Wait(0) is a 16 ms frame so per-frame budgets show.
local here = arg[0]:match('^(.*)/') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads checked-in stubs only
local stubs = dofile(here .. '/stubs.lua')
stubs.newWorld()
stubs.clear()

local passed = 0
local function eq(actual, expected, label)
    assert(actual == expected, label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end
local function ok(cond, label)
    assert(cond, 'FAIL: ' .. label)
    passed = passed + 1
end

local env = stubs.newEnv('client', 'core')
local v3 = stubs.vector3
local json = stubs.json
stubs.loadFile(env, 'import.lua')
stubs.loadFile(env, 'shared/config.lua')
stubs.loadFile(env, 'client/api.lua')
local Maps = env.Config.Maps
Maps.MaxLocalObjects, Maps.CacheRegions, Maps.MaxMarkers = 50, 3, 4

-- frames: Wait(0) is one 16 ms frame on the virtual clock
local FRAME = 16
env.Wait = function(ms) return coroutine.yield((tonumber(ms) or 0) > 0 and ms or FRAME) end

-- natives ----------------------------------------------------------------------
local calls = {}
local function count(name) calls[name] = (calls[name] or 0) + 1 end
local function n(name) return calls[name] or 0 end
local cam = v3(100.0, 100.0, 30.0)
env.GetFinalRenderedCamCoord = function() count('GetFinalRenderedCamCoord') return cam end

local objects, nextHandle, createFails = {}, 5000, false
local created = {}      -- handles in creation order
env.CreateObjectNoOffset = function(hash, x, y, z, network, host, dynamic, p7)
    count('CreateObjectNoOffset')
    assert(network == false and host == false and dynamic == false and p7 == nil, 'local static object')
    if createFails then return 0 end
    nextHandle = nextHandle + 1
    objects[nextHandle] = { hash = hash, x = x, y = y, z = z }
    created[#created + 1] = nextHandle
    return nextHandle
end
env.SetEntityRotation = function(h, rx, ry, rz, o, p5) count('SetEntityRotation') objects[h].rot = { rx, ry, rz, o, p5 } end
env.FreezeEntityPosition = function(h, on) count('FreezeEntityPosition') objects[h].frozen = on end
env.SetEntityCollision = function(h, on, keep) count('SetEntityCollision') objects[h].collision = { on, keep } end
env.SetEntityLodDist = function(h, lod) count('SetEntityLodDist') objects[h].lod = lod end
env.SetEntityInvincible = function(h, on, keep) count('SetEntityInvincible') objects[h].invincible = { on, keep } end
env.SetDisableFragDamage = function(h, on) count('SetDisableFragDamage') objects[h].frag = on end
env.SetEntityCoordsNoOffset = function(h, x, y, z, keepTasks, keepIK, warp)
    count('SetEntityCoordsNoOffset') objects[h].x, objects[h].y, objects[h].z = x, y, z
    objects[h].moveFlags = { keepTasks, keepIK, warp }
end
env.SetEntityHeading = function(h, heading) count('SetEntityHeading') objects[h].heading = heading end
-- BOOL natives answer 1/false like the default invoke route (AGENTS §8)
env.DoesEntityExist = function(h) count('DoesEntityExist') return (objects[h] and not objects[h].deleted) and 1 or false end
env.DeleteEntity = function(h) count('DeleteEntity') objects[h].deleted = true end

local modelMode, modelDelay, requestAt, requested, released = {}, {}, {}, {}, {}
env.IsModelInCdimage = function(h) return modelMode[h] ~= 'missing' and 1 or false end
env.IsModelValid = function(h) return modelMode[h] ~= 'missing' and 1 or false end
env.RequestModel = function(h)
    count('RequestModel') requested[h], requestAt[h] = (requested[h] or 0) + 1, requestAt[h] or stubs.now()
end
env.HasModelLoaded = function(h)
    count('HasModelLoaded')
    if modelMode[h] == 'never' or not requestAt[h] then return false end
    return stubs.now() - requestAt[h] >= (modelDelay[h] or 0) and 1 or false
end
env.SetModelAsNoLongerNeeded = function(h)
    count('SetModelAsNoLongerNeeded') released[h], requestAt[h] = (released[h] or 0) + 1, nil
end

local hideLog = {}
env.CreateModelHideExcludingScriptObjects = function(...) hideLog[#hideLog + 1] = { 'create', ... } end
env.RemoveModelHide = function(...) hideLog[#hideLog + 1] = { 'remove', ... } end
env.DrawMarker = function(t) count('DrawMarker') calls.lastMarkerType = t end
local camRot = v3(0.0, 0.0, 0.0)   -- yaw 0: the camera looks along +y
env.GetFinalRenderedCamRot = function(order) count('GetFinalRenderedCamRot') assert(order == 2) return camRot end
local HVEH, HPED = 1101, 1102
env.IsModelAVehicle = function(h) return h == HVEH and 1 or false end
env.IsModelAPed = function(h) return h == HPED and 1 or false end
env.DrawLine = function() count('DrawLine') end
env.SetTextOutline = function() end

-- the server: window/types callbacks answered by the test ---------------------------
local requests = {}
env.Core.Callback = { await = function(name, payload)
    local p = env.promise.new()
    requests[#requests + 1] = { name = name, payload = payload, p = p }
    return env.Citizen.Await(p)
end }
local warnings = {}
local function warn(fmt, ...) warnings[#warnings + 1] = fmt:format(...) end
env.Core.Log = { warn = warn, error = warn, info = function() end, debug = function() end }

-- networked map entities (server-created): records live in `objects` too, flagged `net`
local netEntities, bagHandlers = {}, {}
env.AddStateBagChangeHandler = function(keyFilter, _, fn) bagHandlers[keyFilter] = fn return 1 end
env.NetworkDoesEntityExistWithNetworkId = function(id) count('NetworkDoesEntityExistWithNetworkId') return netEntities[id] and 1 or false end
env.NetworkGetEntityFromNetworkId = function(id) count('NetworkGetEntityFromNetworkId') return netEntities[id] and netEntities[id].entity or 0 end
env.NetworkHasControlOfEntity = function(e) return (objects[e] and objects[e].control) and 1 or false end
env.GetEntityType = function(e) return objects[e] and objects[e].type or 0 end
env.Entity = function(e) return { state = objects[e] and objects[e].state or {} } end
env.SetBlockingOfNonTemporaryEvents = function(e, on) objects[e].blocking, objects[e].blockCalls = on, (objects[e].blockCalls or 0) + 1 end
env.IsPedUsingScenario = function(e, sc) return objects[e].scenario == sc and 1 or false end
env.TaskStartScenarioInPlace = function(e, sc, delay, enter)   -- (ped, name, 0, true)
    assert(delay == 0 and enter == true) objects[e].scenario, objects[e].scenarioStarts = sc, (objects[e].scenarioStarts or 0) + 1
end
env.SetVehicleDoorsLocked = function(e, status) objects[e].locked = status end

stubs.loadFile(env, 'client/maps_spawn.lua')
stubs.loadFile(env, 'client/maps_view.lua')
stubs.loadFile(env, 'client/maps.lua')
local M = env.Core.Maps
local Registry = env.Core.Registry

-- helpers ------------------------------------------------------------------------
local function key(rx, ry) return (rx + 32768) * 65536 + (ry + 32768) end
local function tick(ms) stubs.tick(ms) end
local function take(name)
    for i, r in ipairs(requests) do
        if r.name == name then return table.remove(requests, i) end
    end
    return nil
end
local function pendingCount(name)
    local c = 0
    for _, r in ipairs(requests) do if r.name == name then c = c + 1 end end
    return c
end
--- versions for the 3x3 around (cx, cy): `fill` everywhere, `extra` overrides
local function window9(cx, cy, fill, extra)
    local v = {}
    for dx = -1, 1 do for dy = -1, 1 do v[key(cx + dx, cy + dy)] = fill end end
    for k, ver in pairs(extra or {}) do v[k] = ver end
    return v
end
local function answer(b, v, w)
    local r = take('core:maps:window')
    assert(r, 'a window request is pending')
    r.p:resolve({ b = b, v = v, w = w })
    return r.payload
end
local function send(name, ...) stubs.triggerOn(env, name, 65535, ...) end
local H1, H2, H3, HMISSING, HNEVER = 1001, 1002, -1003, 1004, 1005
modelMode[HMISSING], modelMode[HNEVER] = 'missing', 'never'
local function prop(uid, x, y, z, o)
    o = o or {}
    return { uid, 1, o.hash or H1, x, y, z, 0, 0, o.rz or 0, o.flags or 3, o.lod or 150, o.extra }
end
local function pack(b, k, v, list) send('core:maps:pack', b, k, json.encode({ v = v, e = list })) end
local function live()
    local c = 0
    for _, o in pairs(objects) do if not o.deleted and not o.net then c = c + 1 end end
    return c
end
--- runs `frames` frames and returns the largest per-frame delta of a native's count
local function frames(count_, name)
    local worst = 0
    for _ = 1, count_ do
        local before = n(name)
        tick(FRAME)
        local d = n(name) - before
        if d > worst then worst = d end
    end
    return worst
end
local function settle(ms) tick(ms or 2000) end
--- every stubbed native call so far (GetGameTimer comes from the stubs' own counter)
local function nativeTotal()
    local total = stubs.gameTimerReads
    for name, c in pairs(calls) do if name ~= 'lastMarkerType' then total = total + c end end
    return total
end
local bench = {}
local marks, lines

-- 1. shape and idle ------------------------------------------------------------------
ok(type(M) == 'table', 'Core.Maps exists on the client')
for _, fn in ipairs({ 'isAreaReady', 'waitAreaReady', 'handleOf', 'uidOf', 'hold', 'release', 'setEditorView', 'stats' }) do
    eq(type(M[fn]), 'function', 'Core.Maps.' .. fn)
end
eq(env.CoreMapsEngine, nil, 'the engine handoff global is cleared')
tick(3000)
eq(n('GetFinalRenderedCamCoord'), 0, 'no camera read before the player is loaded and with nothing loaded')
eq(#requests, 0, 'no window request before the player is loaded')
eq(M.isAreaReady(v3(100, 100, 30)), false, 'nothing is ready before the first answer')

-- 2. first window: request with empty versions, answer, pack ------------------------------
local adminSelf = { modes = { editor = true } }
env.Core.Admin = { getSelf = function() return adminSelf end }   -- client/adminstate.lua (loads later)
env.LocalPlayer.state.loaded = true
tick(1000)
eq(pendingCount('core:maps:window'), 1, 'loaded: one window request')
local payload = requests[1].payload
eq(payload.c, key(0, 0), 'centred on the camera region')
eq(next(payload.h), nil, 'nothing cached yet: empty versions')
answer(0, window9(0, 0, 0, { [key(0, 0)] = 3 }))
eq(M.stats().bucket, 0, 'bucket learned from the answer')
eq(M.isAreaReady(v3(100, 100, 30)), false, 'the centre pack is still on its way')
eq(M.isAreaReady(v3(-300, 100, 30)), true, 'an empty region (version 0) is ready')

local list = {}
for i = 1, 20 do list[#list + 1] = prop(i, 100 + i * 5, 100, 30) end
list[#list + 1] = { 'hide1', 3, H2, 150, 150, 30, 0, 0, 0, 0, 150, { radius = 4.5 } }
list[#list + 1] = { 'mk1', 2, 0, 110, 100, 30, 0, 0, 0, 0, 150, { type = 2, r = 10, g = 20, b = 30, a = 40, dd = 50 } }
list[#list + 1] = { 'pt1', 4, 0, 105, 100, 30, 0, 0, 0, 16, 150 }
list[#list + 1] = { 'helper1', 1, H1, 106, 100, 30, 0, 0, 0, 8 | 3, 150 }
list[#list + 1] = { 'bad', 9, 0, 1, 1, 1 }
pack(0, key(0, 0), 3, list)
eq(#hideLog, 1, 'hide applied on region load')
local h = hideLog[1]
ok(h[1] == 'create' and h[2] == 150 and h[3] == 150 and h[4] == 30 and h[5] == 4.5 and h[6] == H2 and h[7] == true,
    'CreateModelHideExcludingScriptObjects(x, y, z, radius, hash, true)')
ok(#warnings == 1 and warnings[1]:find('malformed', 1, true) ~= nil, 'a malformed tuple is skipped with one warning')
local worst, worstNatives = 0, 0
for _ = 1, 60 do
    local before, nativesBefore = n('CreateObjectNoOffset'), nativeTotal()
    tick(FRAME)
    worst = math.max(worst, n('CreateObjectNoOffset') - before)
    worstNatives = math.max(worstNatives, nativeTotal() - nativesBefore)
end
bench.spawnFrame = worstNatives
eq(n('CreateObjectNoOffset'), 20, 'the 20 props spawn (data kind, helper, marker and hide do not)')
ok(worst <= 8 and worst > 0, 'at most SpawnPerFrame (8) creations per frame, got ' .. worst)
eq(requested[H1], 1, 'RequestModel once per model')
eq(M.isAreaReady(v3(100, 100, 30)), true, 'area ready once the props are spawned')
local s = M.stats()
eq(s.regions, 9, '9 regions known')
eq(s.elements, 23, '23 elements indexed (20 props, marker, point, helper)')
eq(s.spawned, 20, 'stats.spawned')
eq(s.hides, 1, 'stats.hides')
eq(s.models, 1, 'stats.models')

-- 3. nearest first, flags, what the runtime does not spawn -------------------------------------
local lastRing, ordered = -1, true
for _, handle in ipairs(created) do
    local ring = math.floor((objects[handle].x - 100) / 16)
    if ring < lastRing then ordered = false end
    lastRing = ring
end
ok(ordered, 'creation order is nearest-first by 16 m rings')
local o1 = objects[M.handleOf(1)]
ok(o1 and o1.frozen == true, 'flag 2: frozen')
eq(o1.collision, nil, 'flag 1: collision stays on (no SetEntityCollision call)')
eq(o1.lod, 150, 'SetEntityLodDist(lod)')
ok(o1.rot[4] == 2 and o1.rot[5] == false, 'SetEntityRotation(..., 2, false)')
eq(o1.invincible, nil, 'no unbreakable flag: no invincibility')
eq(M.handleOf('helper1'), nil, 'editor-only helper (flag 8) is not spawned')
eq(M.handleOf('pt1'), nil, 'data kind (flag 16) is not spawned')
eq(M.uidOf(M.handleOf(7)), 7, 'uidOf(handleOf(uid)) == uid')
eq(M.uidOf(424242), nil, 'uidOf an unknown entity is nil')

-- 4. markers: one per-frame loop while something is in draw distance ---------------------------
local before = n('DrawMarker')
tick(FRAME * 10)
ok(n('DrawMarker') - before >= 9, 'the marker is drawn every frame')
eq(calls.lastMarkerType, 2, 'marker type from extra')
eq(M.stats().markers, 1, 'one marker gathered')

-- 5. still camera: no evaluation, one camera read per 500 ms per thread, the safety net at 60 s -------
local evals, reads = M.stats().evaluations, n('GetFinalRenderedCamCoord')
tick(10000)
eq(M.stats().evaluations, evals, 'a still camera does not re-evaluate')
local r = n('GetFinalRenderedCamCoord') - reads
ok(r >= 25 and r <= 32, 'still: ~2 camera reads per second across both threads (got ' .. r .. ' in 10 s)')
eq(pendingCount('core:maps:window'), 0, 'no window request while still')
tick(50000)
eq(pendingCount('core:maps:window'), 1, 'safety net: a request after 60 s even when still')
do payload = answer(0, window9(0, 0, 0, { [key(0, 0)] = 3 })) end
eq(payload.h[key(0, 0)], 3, 'the request carries the cached version')
eq(payload.h[key(1, 1)], 0, 'and the known-empty ones')
eq(n('CreateObjectNoOffset'), 20, 'an unchanged answer changes nothing')

-- 6. camera moves inside the region: evaluation without a window request; hysteresis -------------
do cam = v3(100.0 + 3.0, 100.0, 30.0) end
tick(1000)
eq(M.stats().evaluations, evals, 'less than 4 m: no evaluation')
do cam = v3(100.0 + 10.0, 100.0, 30.0) end
tick(1000)
eq(M.stats().evaluations, evals + 1, '4 m or more: one evaluation')
do cam = v3(512 + 60, 100, 30) end
tick(1000)
eq(pendingCount('core:maps:window'), 0, 'inside the 64 m hysteresis: no re-centre')
tick(1000)
eq(live(), 0, 'the camera left: every prop despawned')
eq(n('DeleteEntity'), 20, 'DeleteEntity once per object')
eq(released[H1], nil, 'the model is not released at once')
do cam = v3(100.0, 100.0, 30.0) end
tick(1000)
settle(1000)
eq(live(), 20, 'back within 30 s: respawned')
eq(requested[H1], 1, 'no second RequestModel: the entry was still held')
do cam = v3(512 + 60, 100, 30) end
tick(1000)
tick(31000)
eq(live(), 0, 'away again')
eq(released[H1], 1, 'SetModelAsNoLongerNeeded 30 s after the last instance went')

-- 7. re-centre, cached versions, LRU eviction (CacheRegions = 3), hide removed with its region ------
local function answerAsIs(b, overrides)
    local r = take('core:maps:window')
    assert(r, 'a window request is pending')
    local p = r.payload
    local cx, cy = p.c // 65536 - 32768, p.c % 65536 - 32768
    local v = {}
    for dx = -1, 1 do for dy = -1, 1 do
        local k = key(cx + dx, cy + dy)
        v[k] = p.h[k] or 0
    end end
    for k, ver in pairs(overrides or {}) do v[k] = ver end
    r.p:resolve({ b = b, v = v })
    return p
end
local function goRegion(rx)
    cam = v3(rx * 512 + 256.0, 100.0, 30.0)
    tick(1000)
    return answerAsIs(0)
end
do payload = goRegion(1) end
eq(payload.c, key(1, 0), 'beyond the hysteresis: re-centred on the camera region')
eq(payload.h[key(0, 0)], 3, 're-centre request carries the cached versions')
eq(payload.h[key(2, 0)], nil, 'unknown regions are not in the versions')
eq(M.stats().cached, 12, 'the 3 regions that left stay cached')
goRegion(2)
eq(M.stats().cached, 12, 'LRU: the oldest 3 evicted, 3 newer cached')
local removedBefore = 0
for _, e in ipairs(hideLog) do if e[1] == 'remove' then removedBefore = removedBefore + 1 end end
eq(removedBefore, 0, 'the hide stays while its region is cached')
goRegion(3)
local last = hideLog[#hideLog]
ok(last[1] == 'remove' and last[2] == 150 and last[5] == 4.5 and last[6] == H2 and last[7] == false,
    'evicting the region: RemoveModelHide(x, y, z, radius, hash, false)')
eq(M.stats().elements, 0, 'the evicted region took its elements along')
eq(M.stats().hides, 0, 'no hide left')

-- 8. despawn budget, cap, models streaming in, failing models ---------------------------------------
local cx3 = 3 * 512 + 256.0
list = {}
for i = 1, 45 do list[i] = prop(100 + i, cx3 + (i % 9) * 3, 100 + (i // 9) * 3, 30) end
pack(0, key(3, 0), 1, list)
tick(1000)
settle(500)
eq(live(), 45, '45 props spawned')
do cam = v3(cx3 + 300, 100, 30) end
local nativesBefore = nativeTotal()
do worst = frames(60, 'DeleteEntity') end
bench.despawn45 = nativeTotal() - nativesBefore
eq(live(), 0, 'all despawned')
ok(worst <= 32 and worst > 8, 'at most DespawnPerFrame (32) deletions per frame, got ' .. worst)
for i = 46, 60 do list[i] = prop(100 + i, cx3 + 50 + i, 100, 30) end
pack(0, key(3, 0), 2, list)
do cam = v3(cx3, 100, 30) end
tick(1000)
settle(1000)
eq(live(), 50, 'MaxLocalObjects (50) caps the spawned objects')
eq(M.stats().capped, 10, 'ten wanted elements stay capped')
local capped = 0
for i = 51, 60 do if M.handleOf(100 + i) == nil then capped = capped + 1 end end
eq(capped, 10, 'the farthest ones are the capped ones')
eq(M.isAreaReady(v3(cx3, 100, 30)), true, 'capped elements do not block readiness')

-- 9. pack replace keeps unchanged objects; models streaming in; failing models ------------------------
local handles = {}
for i = 1, 45 do handles[i] = M.handleOf(100 + i) end
local deletesBefore = n('DeleteEntity')
modelDelay[H3] = 2000
local list2 = {}
for i = 1, 45 do list2[i] = list[i] end
list2[46] = prop('slow1', cx3 + 1, 90, 30, { hash = H3 })
list2[47] = prop('slow2', cx3 + 2, 90, 30, { hash = H3 })
list2[48] = prop('never1', cx3 + 3, 90, 30, { hash = HNEVER })
list2[49] = prop('missing1', cx3 + 4, 90, 30, { hash = HMISSING, flags = 1 | 2 | 4 })
warnings = {}
pack(0, key(3, 0), 3, list2)
tick(600)
local same = 0
for i = 1, 45 do if M.handleOf(100 + i) == handles[i] then same = same + 1 end end
eq(same, 45, 'a new pack version keeps the objects of unchanged elements')
eq(n('DeleteEntity') - deletesBefore, 5, 'only the 5 elements the pack dropped are deleted')
eq(M.stats().waiting, 3, 'two slow models and one that never loads: three waiting')
eq(requested[HMISSING], nil, 'a model not in the game files is never requested')
eq(M.stats().failed, 1, 'and its element failed at once')
ok(#warnings == 1 and warnings[1]:find('game files', 1, true) ~= nil, 'logged once')
local polls = n('HasModelLoaded')
tick(1000)
local pollRate = n('HasModelLoaded') - polls
ok(pollRate >= 20 and pollRate <= 50, 'streaming models are polled at ~20 Hz, not every frame (' .. pollRate .. '/s)')
tick(1000)
ok(M.handleOf('slow1') ~= nil and M.handleOf('slow2') ~= nil, 'slow models spawn once loaded')
eq(requested[H3], 1, 'one RequestModel for both')
tick(9000)
eq(M.stats().failed, 2, 'a model that never loads fails after 10 s')
eq(released[HNEVER], 1, 'its request is released')
ok(#warnings == 2 and warnings[2]:find('10 s', 1, true) ~= nil, 'logged once')
eq(M.isAreaReady(v3(cx3, 100, 30)), true, 'failed elements do not block readiness')

-- 10. moved in place, model change re-creates ---------------------------------------------------------
local h1, h2 = M.handleOf(101), M.handleOf(102)
local list3 = {}
for i = 1, 49 do list3[i] = list2[i] end
list3[1] = prop(101, list2[1][4] + 2, list2[1][5], 30)
list3[2] = prop(102, list2[2][4], list2[2][5], 30, { hash = H3 })
local moves = n('SetEntityCoordsNoOffset')
pack(0, key(3, 0), 4, list3)
tick(600)
eq(M.handleOf(101), h1, 'same model: the object is kept')
eq(n('SetEntityCoordsNoOffset') - moves, 1, 'and moved in place once')
eq(objects[h1].x, list2[1][4] + 2, 'to the new position')
ok(objects[h2].deleted and M.handleOf(102) ~= nil and M.handleOf(102) ~= h2, 'another model: re-created')

-- 11. deltas and stale notices -----------------------------------------------------------------------
send('core:maps:delta', 0, key(3, 0), 4, 5, json.encode({
    { o = 'put', t = prop(200, cx3 + 5, 95, 30) }, { o = 'del', u = 103 },
}))
tick(600)
ok(M.handleOf(200) ~= nil, 'delta put: spawned')
eq(M.handleOf(103), nil, 'delta del: gone')
eq(M.stats().regions >= 1, true, 'regions still known')
send('core:maps:delta', 0, key(3, 0), 4, 5, json.encode({ { o = 'del', u = 200 } }))
ok(M.handleOf(200) ~= nil, 'a delta the region already has is ignored')
send('core:maps:delta', 5, key(3, 0), 5, 6, json.encode({ { o = 'del', u = 200 } }))
ok(M.handleOf(200) ~= nil, 'a delta of another bucket is ignored')
send('core:maps:delta', 0, key(3, 0), 7, 8, json.encode({ { o = 'del', u = 200 } }))
tick(400)
eq(pendingCount('core:maps:window'), 1, 'a version gap asks for the region again')
eq(M.isAreaReady(v3(cx3, 100, 30)), false, 'not ready while behind the server')
do payload = answerAsIs(0, { [key(3, 0)] = 8 }) end
eq(payload.h[key(3, 0)], 5, 'the request carries our version (5)')
eq(M.isAreaReady(v3(cx3, 100, 30)), false, 'still not ready: the pack is announced')
list3[50] = { 'hide2', 3, H2, cx3, 120, 30, 0, 0, 0, 0, 150, { radius = 2 } }
pack(0, key(3, 0), 8, list3)
tick(600)
eq(M.handleOf(200), nil, 'the pack brought the newer content')
eq(M.stats().hides, 1, 'the hide of the new pack is applied')
eq(M.isAreaReady(v3(cx3, 100, 30)), true, 'ready again')
send('core:maps:stale', 0, key(3, 0), 9)
tick(400)
eq(pendingCount('core:maps:window'), 1, 'a stale notice asks for the region again')
answerAsIs(0, { [key(3, 0)] = 9 })
pack(0, key(3, 0), 9, list3)
send('core:maps:pack', 0, key(3, 0), json.encode({ v = 8, e = {} }))
ok(M.handleOf(101) ~= nil, 'an older pack that arrives late is ignored')
local elementsBefore = M.stats().elements
send('core:maps:stale', 0, key(4, 0), 3)
tick(400)
answerAsIs(0, { [key(4, 0)] = 3 })
pack(0, key(4, 0), 3, { prop('east', 2100, 100, 30) })
eq(M.stats().elements, elementsBefore + 1, 'a neighbour region loaded')
send('core:maps:stale', 0, key(4, 0), 4)
tick(400)
answerAsIs(0, { [key(4, 0)] = 0 })
eq(M.stats().elements, elementsBefore, 'emptied (version 0): its elements dropped')
pack(0, key(4, 0), 3, { prop('east', 2100, 100, 30) })
eq(M.stats().elements, elementsBefore, 'a late pack of an older version does not bring them back')

-- 12. holds: the runtime leaves a held element alone until released ------------------------------------
Registry.setCaller('editor_a')
local hh = M.hold(104)
ok(hh ~= nil and hh == M.handleOf(104), 'hold returns the entity')
do moves = n('SetEntityCoordsNoOffset') end
local list4 = {}
for i = 1, #list3 do list4[i] = list3[i] end
list4[4] = prop(104, list3[4][4] + 1, list3[4][5], 30)
send('core:maps:delta', 0, key(3, 0), 9, 10, json.encode({ { o = 'put', t = list4[4] } }))
tick(600)
eq(n('SetEntityCoordsNoOffset'), moves, 'a held element is not moved by a delta')
do cam = v3(cx3 + 300, 100, 30) end
tick(1500)
eq(M.handleOf(104), hh, 'nor despawned when the camera leaves')
ok(not objects[hh].deleted, 'its object is alive')
Registry.setCaller('editor_b')
M.hold(104)
Registry.setCaller('editor_a')
eq(M.release(104), true, 'release by the first holder')
tick(600)
ok(not objects[hh].deleted, 'still held by the second holder')
eq(M.release(104), false, 'a second release by the same owner is refused')
stubs.triggerOn(env, 'onResourceStop', 0, 'editor_b')
tick(1000)
ok(objects[hh].deleted, 'the holder stopped: released, and out of range it despawns')
do cam = v3(cx3, 100, 30) end
tick(1000)
settle(600)
local hh2 = M.handleOf(104)
ok(hh2 ~= nil and objects[hh2].x == list3[4][4] + 1, 'respawned at the position the delta set while held')
M.hold(104)
send('core:maps:delta', 0, key(3, 0), 10, 11, json.encode({ { o = 'del', u = 104 } }))
tick(600)
ok(not objects[hh2].deleted, 'a held element deleted by the server keeps its object until release')
eq(M.handleOf(104), hh2, 'handleOf still answers for it')
M.release(104)
tick(600)
ok(objects[hh2].deleted, 'released: the orphan goes')
eq(M.handleOf(104), nil, 'and is forgotten')
Registry.setCaller('core')

-- 13. unbreakable and collision flags, a refused create -------------------------------------------------
send('core:maps:delta', 0, key(3, 0), 11, 12, json.encode({
    { o = 'put', t = prop('ub', cx3 + 6, 96, 30, { flags = 4 }) },
}))
tick(600)
local ub = objects[M.handleOf('ub')]
ok(ub.invincible and ub.invincible[1] == true and ub.frag == true, 'flag 4: SetEntityInvincible + SetDisableFragDamage')
ok(ub.collision and ub.collision[1] == false, 'no flag 1: SetEntityCollision(false)')
eq(ub.frozen, nil, 'no flag 2: not frozen')
do createFails = true end
send('core:maps:delta', 0, key(3, 0), 12, 13, json.encode({ { o = 'put', t = prop('late', cx3 + 7, 96, 30) } }))
tick(600)
eq(M.handleOf('late'), nil, 'a refused create (pool full) leaves it unspawned')
do createFails = false end
tick(1500)
ok(M.handleOf('late') ~= nil, 'and it is retried after the back-off')

-- 13b. a prop tuple whose model is a vehicle or a ped is never created (checked once per model) ------------
do warnings = {} end
local requestsBefore = n('RequestModel')
send('core:maps:delta', 0, key(3, 0), 13, 14, json.encode({
    { o = 'put', t = prop('car', cx3 + 8, 96, 30, { hash = HVEH }) },
    { o = 'put', t = prop('man', cx3 + 9, 96, 30, { hash = HPED }) },
}))
tick(600)
ok(M.handleOf('car') == nil and M.handleOf('man') == nil, 'vehicle and ped models are not spawned as props')
eq(n('RequestModel'), requestsBefore, 'and never requested')
ok(#warnings == 2 and warnings[1]:find('vehicle or ped', 1, true) ~= nil, 'logged once per model')

-- 14. withheld packs: kept content, not ready, asked again ~2 s later -----------------------------------
local objectsBefore = live()
tick(61000)
eq(pendingCount('core:maps:window'), 1, 'the safety-net request')
local rq = take('core:maps:window')
rq.p:resolve({ b = 0, v = window9(3, 0, 0, { [key(3, 0)] = 15 }), w = { [key(3, 0)] = true } })
tick(600)
eq(live(), objectsBefore, 'a withheld pack keeps the cached content')
eq(M.isAreaReady(v3(cx3, 100, 30)), false, 'but the region is not ready')
tick(1000)
eq(pendingCount('core:maps:window'), 0, 'no retry before ~2 s')
tick(600)
eq(pendingCount('core:maps:window'), 1, 'retried after ~2 s')
do payload = answerAsIs(0, { [key(3, 0)] = 15 }) end
eq(payload.h[key(3, 0)], 14, 'the retry still carries the version we hold')
pack(0, key(3, 0), 15, list4)
eq(M.isAreaReady(v3(cx3, 100, 30)), false, 'the new pack is applied, spawning follows')
settle(1000)
eq(M.isAreaReady(v3(cx3, 100, 30)), true, 'ready')

-- 15. the evaluation allocates nothing ---------------------------------------------------------------------
settle(1000)
-- 80..115 m west of the props: every prop stays within its 150 m, but no cell is wholly in range, so the
-- evaluation walks the elements one by one (the per-element branch) without changing any state
for step = 1, 8 do   -- warm up: the streaming thread switches to its 100 ms moving cadence
    cam = v3(cx3 - 40 - step * 5.0, 100, 30)
    tick(100)
end
local path = {}
for step = 9, 15 do path[#path + 1] = v3(cx3 - 40 - step * 5.0, 100, 30) end
collectgarbage('collect')
collectgarbage('stop')
do cam = path[1] end   -- the first step after a full GC regrows the coroutine stacks: not counted
tick(100)
local evalsBefore = M.stats().evaluations
local kb = collectgarbage('count')
for i = 2, #path do
    cam = path[i]
    tick(100)
end
local grown = (collectgarbage('count') - kb) * 1024
collectgarbage('restart')
print(('[bench] 5 moving evaluations: %d bytes, %d elements looked at in the last one'):format(
    math.floor(grown), M.stats().lastEvalElements))
ok(M.stats().evaluations - evalsBefore >= 4, 'moving 5 m per 100 ms re-evaluates')
ok(grown < 64, 'steady-state evaluations allocate nothing (' .. math.floor(grown) .. ' bytes)')
ok(M.stats().lastEvalElements > 0, 'the per-element branch ran (' .. M.stats().lastEvalElements .. ' elements)')
eq(M.stats().despawning + M.stats().queued, 0, 'and changed nothing')
do cam = v3(cx3, 100, 30) end
settle(1000)

-- 16. buckets: other buckets ignored, a bucket change resets everything ----------------------------------
local before16 = n('CreateObjectNoOffset')
pack(5, key(3, 0), 99, { prop('other', cx3, 100, 30) })
tick(600)
eq(M.handleOf('other'), nil, 'a pack of another bucket is ignored')
eq(n('CreateObjectNoOffset'), before16, 'nothing spawned for it')
send('core:maps:delta', 0, key(3, 0), 15, 16, json.encode({
    { o = 'put', t = { 'mk16', 2, 0, cx3 + 1, 100, 30, 0, 0, 0, 0, 150, { type = 1, dd = 30 } } },
}))
tick(600)
do marks = n('DrawMarker') end
tick(FRAME * 3)
eq(n('DrawMarker') - marks, 3, 'a marker drawn every frame')
local hidesBefore = #hideLog
send('core:client:bucketChanged', 7)
eq(hideLog[#hideLog][1], 'remove', 'bucket change: hides removed at once')
eq(#hideLog, hidesBefore + 1, 'the one hide')
tick(400)
eq(live(), 0, 'bucket change: every object deleted (through the despawn queue)')
eq(M.stats().elements, 0, 'every element forgotten')
do marks = n('DrawMarker') end
tick(FRAME * 3)
eq(n('DrawMarker') - marks, 0, 'the draw loop ended with its region')
eq(pendingCount('core:maps:window'), 1, 'and the window asked for again')
do payload = answer(7, window9(3, 0, 0, { [key(3, 0)] = 1 })) end
eq(next(payload.h), nil, 'with no cached versions')
eq(M.stats().bucket, 7, 'the new bucket')
pack(7, key(3, 0), 1, { prop('b7', cx3, 101, 30) })
settle(600)
ok(M.handleOf('b7') ~= nil, 'content of the new bucket spawns')
tick(61000)
answer(8, window9(3, 0, 0))
tick(400)
eq(M.handleOf('b7'), nil, 'an answer for another bucket than cached resets')
eq(pendingCount('core:maps:window'), 1, 'and asks again')
answer(8, window9(3, 0, 0))
eq(M.stats().bucket, 8, 'bucket 8 now')

-- 17. waitAreaReady: re-centres on a teleport target, waits for its content, times out otherwise ---------
local result, doneAt
local startedAt = stubs.now()
do cam = v3(10 * 512 + 100.0, 100.0, 30.0) end   -- the teleport moved the ped (and so the camera) first
env.CreateThread(function()
    result = M.waitAreaReady(v3(10 * 512 + 100.0, 100.0, 30.0), 3000)
    doneAt = stubs.now()
end)
eq(M.stats().centre, key(10, 0), 'waitAreaReady moved the window onto the target at once')
tick(400)
do payload = take('core:maps:window') end
ok(payload and payload.payload.c == key(10, 0), 'and asked for it')
payload.p:resolve({ b = 8, v = window9(10, 0, 0, { [key(10, 0)] = 2 }) })
tick(200)
eq(result, nil, 'still waiting for the pack')
pack(8, key(10, 0), 2, { prop('platform', 10 * 512 + 100.0, 101, 29), prop('rail', 10 * 512 + 104.0, 101, 29) })
tick(1500)
eq(result, true, 'waitAreaReady returns true once the platform exists')
ok(doneAt - startedAt < 3000, 'before the timeout')
do result = nil end
send('core:maps:stale', 8, key(9, 0), 5)
tick(400)
answerAsIs(8, { [key(9, 0)] = 5 })   -- announced, but this pack never lands
env.CreateThread(function() result = M.waitAreaReady(v3(9 * 512 + 100.0, 100.0, 30.0), 1000) end)
tick(1500)
eq(result, false, 'the pack never lands: waitAreaReady times out with false')

-- 18. editor view: previews of data kinds and helpers, owner-tracked; the draw loop lives only while needed ---
local base = 10 * 512 + 100.0
send('core:maps:delta', 8, key(10, 0), 2, 3, json.encode({
    { o = 'put', t = { 'spot', 4, 0, base + 3, 100, 30, 0, 0, 0, 16, 150, { t = 'test:spot', f = { name = 'Alpha' } } } },
    { o = 'put', t = { 'zone', 5, 0, base + 6, 100, 30, 0, 0, 45, 16, 150, { sx = 4, sy = 2, sz = 3 } } },
    { o = 'put', t = { 'far', 4, 0, base + 200, 100, 30, 0, 0, 0, 16, 150 } },
}))
tick(600)
lines, marks = n('DrawLine'), n('DrawMarker')
tick(FRAME * 5)
eq(n('DrawLine') - lines, 0, 'editor view off: no previews drawn')
eq(n('DrawMarker') - marks, 0, 'and no draw loop without markers')
Registry.setCaller('editor_a')
eq(M.setEditorView('yes'), false, 'setEditorView wants a boolean')
eq(M.setEditorView(true), true, 'editor view on')
Registry.setCaller('core')
tick(600)
eq(pendingCount('core:maps:types'), 1, 'the type list is fetched once')
lines, marks = n('DrawLine'), n('DrawMarker')
tick(FRAME * 4)
eq(n('DrawLine') - lines, 4 * 12, 'before the types: the zone box (12 lines) per frame')
eq(n('DrawMarker') - marks, 4, 'and the point default (a marker) per frame')
take('core:maps:types').p:resolve({
    { id = 'test:spot', label = 'Spot', preview = { { kind = 'box', size = { 1, 1, 2 } }, { kind = 'label', text = '$name' } } },
})
tick(600)
stubs.drawTexts = {}
lines, marks = n('DrawLine'), n('DrawMarker')
tick(FRAME * 4)
eq(n('DrawLine') - lines, 4 * 24, 'with the types: the spot box and the zone box per frame')
eq(n('DrawMarker') - marks, 0, 'the point uses its type preview now')
eq(stubs.drawTexts[1], 'Alpha', 'a $field label reads the element fields')
eq(M.stats().previews, 2, 'two previews within 150 m (the far point is not)')
eq(M.stats().editorView, true, 'stats.editorView')
Registry.setCaller('editor_b')
M.setEditorView(true)
Registry.setCaller('editor_a')
M.setEditorView(false)
Registry.setCaller('core')
tick(FRAME * 3)
ok(M.stats().editorView, 'still on while another owner has it')
stubs.triggerOn(env, 'onResourceStop', 0, 'editor_b')
tick(FRAME * 3)
do lines = n('DrawLine') end
tick(FRAME * 4)
eq(n('DrawLine') - lines, 0, 'the last owner stopped: previews gone')
eq(M.stats().editorView, false, 'editor view off')
eq(pendingCount('core:maps:types'), 0, 'no second type fetch')

-- markers: gathered within their draw distance, the loop ends when none is near ----------------------
send('core:maps:delta', 8, key(10, 0), 3, 4, json.encode({
    { o = 'put', t = { 'mk', 2, 0, base + 2, 100, 30, 0, 0, 0, 0, 150, { type = 1, dd = 20 } } },
    { o = 'put', t = { 'mk2', 2, 0, base + 3, 100, 30, 0, 0, 0, 0, 150, { type = 1, dd = 20 } } },
    { o = 'put', t = { 'mkb', 2, 0, base, 85, 30, 0, 0, 0, 0, 150, { type = 1, dd = 900 } } },
}))
tick(600)
eq(M.stats().markers, 3, 'three markers gathered (a 900 m draw distance is capped at 150 m)')
do marks = n('DrawMarker') end
local rotReads = n('GetFinalRenderedCamRot')
tick(FRAME * 4)
eq(n('DrawMarker') - marks, 8, 'two markers drawn every frame; the one 15 m behind the camera is culled')
eq(n('GetFinalRenderedCamRot') - rotReads, 4, 'one camera rotation read per frame for the cull')
do camRot = v3(0.0, 0.0, 180.0) end   -- turned around: now looking along -y
do marks = n('DrawMarker') end
tick(FRAME * 4)
eq(n('DrawMarker') - marks, 12, 'turned around: the marker in front is drawn, the two beside the camera too')
do camRot = v3(0.0, 0.0, 0.0) end
do cam = v3(base + 60, 100, 30) end
tick(1000)
do marks = n('DrawMarker') end
tick(FRAME * 4)
eq(n('DrawMarker') - marks, 0, 'beyond their draw distance: the loop is gone')
do cam = v3(base, 100, 30) end
tick(1000)

-- 18b. held elements that move region: same model hands the object over, another model goes on release ---
do cam = v3(5610.0, 100.0, 30.0) end
send('core:maps:delta', 8, key(10, 0), 4, 5, json.encode({
    { o = 'put', t = prop('mover', 5600, 100, 30) }, { o = 'put', t = prop('mover2', 5605, 100, 30) },
}))
tick(1000)
settle(600)
local hm, hm2 = M.handleOf('mover'), M.handleOf('mover2')
ok(hm ~= nil and hm2 ~= nil, 'both spawned')
Registry.setCaller('editor_c')
M.hold('mover')
M.hold('mover2')
send('core:maps:delta', 8, key(11, 0), 0, 1, json.encode({
    { o = 'put', t = prop('mover', 5640, 100, 30) }, { o = 'put', t = prop('mover2', 5645, 100, 30, { hash = H3 }) },
}))
tick(600)
eq(M.handleOf('mover'), hm, 'moved region, same model: the held object is handed over')
eq(objects[hm].x, 5600, 'and not moved while held')
ok(not objects[hm2].deleted, 'moved region, another model: the held object stays')
send('core:maps:delta', 8, key(10, 0), 5, 6, json.encode({ { o = 'del', u = 'mover' }, { o = 'del', u = 'mover2' } }))
tick(600)
ok(not objects[hm].deleted and not objects[hm2].deleted, 'the server deleted the old copies: kept while held')
M.release('mover')
M.release('mover2')
Registry.setCaller('core')
tick(600)
settle(600)
eq(objects[hm].x, 5640, 'released: moved in place to the new position')
ok(not objects[hm].deleted, 'the same object')
ok(objects[hm2].deleted, 'released: the other-model object goes')
local nh2 = M.handleOf('mover2')
ok(nh2 ~= nil and nh2 ~= hm2 and objects[nh2].hash == H3, 'the new copy has its own object')
do cam = v3(base, 100, 30) end
tick(1000)

-- 19. argument checks ------------------------------------------------------------------------------------
eq(M.isAreaReady('nope'), false, 'isAreaReady: bad coords')
eq(M.isAreaReady(v3(0 / 0, 0, 0)), false, 'isAreaReady: NaN')
eq(M.hold({}), nil, 'hold: bad uid')
eq(M.release(string.rep('x', 65)), false, 'release: uid too long')
eq(M.handleOf(1.5), nil, 'handleOf: non-integral number')
eq(M.uidOf('x'), nil, 'uidOf: not an entity')
eq(M.waitAreaReady(nil, 10), false, 'waitAreaReady: bad coords')
send('core:maps:pack', 'x', key(10, 0), '{}')
send('core:maps:delta', 8, key(10, 0), 4, 5, 42)
send('core:maps:stale', 8, 'k', 1)
send('core:client:bucketChanged', -1)
eq(M.stats().bucket, 8, 'malformed pushes change nothing')
ok(M.handleOf('platform') ~= nil, 'content intact')

-- 19b. networked map entities: the controlling client applies mapCfg ----------------------------------
local function netEntity(netId, entity, kind, control, state)
    objects[entity] = { net = true, type = kind, control = control, state = state }
    netEntities[netId] = { entity = entity }
    return objects[entity]
end
local handler = bagHandlers.mapCfg
eq(type(handler), 'function', 'a mapCfg state-bag change handler is registered')
local pedCfg = { invincible = true, frozen = true, scenario = 'WORLD_HUMAN_SMOKING' }
local ped = netEntity(77, 9077, 1, true, { mapEl = 'm1:1' })
handler('entity:77', 'mapCfg', pedCfg)
ok(ped.blocking == true and ped.invincible[1] == true and ped.frozen == true, 'ped: blocking, invincible, frozen')
eq(ped.scenario, 'WORLD_HUMAN_SMOKING', 'ped: the scenario started')
ped.state.mapCfg = pedCfg
local veh = netEntity(78, 9078, 2, false, { mapEl = 'm1:2', mapCfg = { locked = true } })
handler('entity:78', 'mapCfg', { locked = true })
eq(veh.locked, nil, 'vehicle: nothing applied without network control')
veh.control = true
tick(1100)
eq(veh.locked, 2, 'the sweep applies it once this client took control')
local blocks = ped.blockCalls
tick(2200)
eq(ped.blockCalls, blocks, 'applied once per control, not per sweep')
ped.control = false
tick(1100)
ped.control = true
tick(1100)
eq(ped.blockCalls, blocks + 1, 'control lost and regained: applied again')
eq(ped.scenarioStarts, 1, 'a running scenario is not restarted')
netEntities[78] = nil   -- out of scope
local gets = n('NetworkGetEntityFromNetworkId')
tick(2200)
eq(n('NetworkGetEntityFromNetworkId'), gets + 2, 'the net-id guard: no entity lookup for the id out of scope')
local other = netEntity(78, 9500, 2, true, {})   -- the net id was recycled for an unrelated vehicle
tick(2200)
eq(other.locked, nil, 'a recycled net id without mapEl is left alone')
local checks = n('NetworkDoesEntityExistWithNetworkId')
tick(2200)
eq(n('NetworkDoesEntityExistWithNetworkId') - checks, 2, 'and forgotten (only the ped is swept now)')
handler('entity:77', 'mapCfg', nil)
do checks = n('NetworkDoesEntityExistWithNetworkId') end
tick(2200)
eq(n('NetworkDoesEntityExistWithNetworkId'), checks, 'a cleared mapCfg stops the sweep')
handler('player:1', 'mapCfg', { locked = true })
handler(42, 'mapCfg', { locked = true })
eq(n('NetworkDoesEntityExistWithNetworkId'), checks, 'bags that are not entities are ignored')
handler('entity:90', 'mapCfg', { locked = true })   -- a map vehicle that never comes into this client's scope
do checks = n('NetworkDoesEntityExistWithNetworkId') end
tick(2200)
eq(n('NetworkDoesEntityExistWithNetworkId') - checks, 2, 'an absent entity is still swept for a while')
tick(12000)
do checks = n('NetworkDoesEntityExistWithNetworkId') end
tick(3000)
eq(n('NetworkDoesEntityExistWithNetworkId'), checks, 'absent for 10 sweeps: forgotten (review F12)')

-- 19b2. an in-place move (core:maps:pose): the controlling client moves the entity its mapEl names ------------
local pv = netEntity(81, 9081, 2, true, { mapEl = 'm1:5' })
send('core:maps:pose', 81, 'm1:5', 12.5, 13.5, 30.25, 0.0, 0.0, -90.0)
ok(pv.x == 12.5 and pv.y == 13.5 and pv.z == 30.25, 'a vehicle moves to the exact position (no offset)')
ok(pv.moveFlags[1] == true and pv.moveFlags[2] == false and pv.moveFlags[3] == true, 'keepTasks, no IK reset, warp')
eq(pv.heading, 270.0, 'a vehicle takes the heading (rz mod 360)')
eq(pv.rot, nil, 'and no rotation call')
local pp = netEntity(82, 9082, 3, true, { mapEl = 'm1:6' })
send('core:maps:pose', 82, 'm1:6', 1.0, 2.0, 3.0, 15.0, 0.0, 30.0)
ok(pp.rot and pp.rot[1] == 15.0 and pp.rot[3] == 30.0 and pp.rot[4] == 2 and pp.rot[5] == false,
    'a physics prop takes its full rotation (order 2)')
eq(pp.heading, nil, 'and no heading call')
local moves = n('SetEntityCoordsNoOffset')
pv.control = false
send('core:maps:pose', 81, 'm1:5', 50.0, 50.0, 30.0, 0.0, 0.0, 0.0)
eq(n('SetEntityCoordsNoOffset'), moves, 'not applied without network control')
pv.control = true
send('core:maps:pose', 81, 'm1:9', 50.0, 50.0, 30.0, 0.0, 0.0, 0.0)
eq(n('SetEntityCoordsNoOffset'), moves, 'not applied to an entity whose mapEl names another element')
local lookups = n('NetworkGetEntityFromNetworkId')
send('core:maps:pose', 99, 'm1:5', 50.0, 50.0, 30.0, 0.0, 0.0, 0.0)
eq(n('NetworkGetEntityFromNetworkId'), lookups, 'the net-id guard: no lookup for an id out of scope')
send('core:maps:pose', 81, 'm1:5', 0 / 0, 50.0, 30.0, 0.0, 0.0, 0.0)
send('core:maps:pose', 81, 42, 50.0, 50.0, 30.0, 0.0, 0.0, 0.0)
send('core:maps:pose', 81, 'm1:5', 50.0, 50.0, 30.0, 0.0, 0.0)
eq(n('SetEntityCoordsNoOffset'), moves, 'a NaN, a uid that is no string or a missing value is refused')
eq(pv.x, 12.5, 'the vehicle stayed where the last valid move put it')
netEntities[81], netEntities[82] = nil, nil

-- 19c. the editor audience: an `editor` staff-mode flip asks for the window again, versions forgotten ---------
tick(20000)   -- let every retry settle, then answer what is still out
while pendingCount('core:maps:window') > 0 do
    take('core:maps:window').p:resolve({ b = 8, v = window9(10, 0, 0,
        { [key(10, 0)] = 6, [key(11, 0)] = 1, [key(9, 0)] = 5 }) })
    tick(400)
end
-- (the editor mode was seeded as on by Core.Admin.getSelf() when the player loaded, section 2)
local function staff(modes) stubs.triggerOn(env, 'core:hook:staffSelfChanged', 0, { modes = modes }) end
local function resendWindow(rq, editorPack)
    rq.p:resolve({ b = 8, v = window9(10, 0, 0, { [key(10, 0)] = 6, [key(11, 0)] = 1 }) })
    local l10 = { prop('platform', 10 * 512 + 100.0, 101, 29), prop('rail', 10 * 512 + 104.0, 101, 29) }
    if editorPack then l10[3] = { 'pt10', 4, 0, base + 1, 100, 30, 0, 0, 0, 16, 150 } end
    pack(8, key(10, 0), 6, l10)
    pack(8, key(11, 0), 1, { prop('mover', 5640, 100, 30) })
    settle(600)
end
staff({ noclip = true, editor = true })
tick(400)
eq(pendingCount('core:maps:window'), 0, 'seeded from Core.Admin.getSelf() (editor on): no flip, no request')
local elementsBefore19 = M.stats().elements
staff({ noclip = true })
eq(M.stats().elements, elementsBefore19, 'editor off: content is kept until the new packs land')
eq(M.isAreaReady(v3(base, 100, 30)), false, 'not ready meanwhile')
tick(400)
eq(pendingCount('core:maps:window'), 1, 'the window is asked for again')
local rq19 = take('core:maps:window')
eq(next(rq19.payload.h), nil, 'with the versions of the window forgotten, so every region is resent')
resendWindow(rq19, false)
eq(M.isAreaReady(v3(base, 100, 30)), true, 'the same version resent for the new audience is applied')
eq(M.stats().elements, 3, 'the region content is the non-editor pack now')
staff({ noclip = true, editor = false })
tick(400)
eq(pendingCount('core:maps:window'), 0, 'editor = false is still off: no flip, no request')
staff({ editor = true })
tick(400)
eq(pendingCount('core:maps:window'), 1, 'editor on: asked again')
local rq19b = take('core:maps:window')
staff({})   -- flips off again while that request is out
rq19b.p:resolve({ b = 8, v = window9(10, 0, 0, { [key(10, 0)] = 6, [key(11, 0)] = 1 }) })
tick(400)
eq(pendingCount('core:maps:window'), 1, 'an answer from before the latest flip is ignored and asked again')
local rq19c = take('core:maps:window')
eq(next(rq19c.payload.h), nil, 'still without versions')
resendWindow(rq19c, false)
eq(M.isAreaReady(v3(base, 100, 30)), true, 'current again')
staff({ editor = true })
tick(400)
resendWindow(take('core:maps:window'), true)
eq(M.stats().elements, 4, 'editor on: the editor pack (with its data kind) is applied')

-- 20. core stops: every object, hide and model request goes at once --------------------------------------
send('core:maps:delta', 8, key(10, 0), 6, 7, json.encode({
    { o = 'put', t = { 'hide3', 3, H2, base, 120, 30, 0, 0, 0, 0, 150, { radius = 3 } } },
}))
tick(600)
eq(M.stats().hides, 1, 'a hide to clean up')
local alive = live()
ok(alive >= 2, 'objects to clean up')
local releases = n('SetModelAsNoLongerNeeded')
stubs.triggerOn(env, 'onClientResourceStop', 0, 'core')
eq(live(), 0, 'core stop: every object deleted at once')
eq(hideLog[#hideLog][1], 'remove', 'core stop: hides removed')
ok(n('SetModelAsNoLongerNeeded') > releases, 'core stop: model requests released')
local readsAtStop = n('GetFinalRenderedCamCoord')
tick(5000)
eq(n('GetFinalRenderedCamCoord'), readsAtStop, 'the threads are gone')
eq(#stubs.failures, 0, 'no thread or handler errors: ' .. tostring(stubs.failures[1]))

print(('[bench] natives: worst spawn frame %d (8 props, first use of the model included), 45 despawns %d in total')
    :format(bench.spawnFrame, bench.despawn45))
print(('client maps: %d passed, 0 failed'):format(passed))
