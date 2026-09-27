-- Offline tests for the Core.Scene client cache and API (DESIGN §55.10, §55.13): client/scene_cache.lua,
-- client/scene_focus.lua, client/scene.lua, lib/scene/shared.lua, lib/scene/client.lua. A stub client VM on the stubs' virtual clock with
-- the REAL codec, motion and clock libs and a fake materialiser that records every call; plugin VMs built from
-- import.lua whose proxy reaches core's `call` export (the wiring of client_ui_tests.lua's key-capture suite).
local here = arg[0]:match('^(.*)/') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads checked-in stubs only
local stubs = dofile(here .. '/stubs.lua')
stubs.newWorld()
stubs.clear()

local passed, failed = 0, 0
local cur = { group = '' }
local function suite(name) cur.group = name end
local function check(cond, label)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print(('FAIL [%s] %s'):format(cur.group, label))
    end
end
local function eq(actual, expected, label)
    check(actual == expected, ('%s: expected %s, got %s'):format(label, tostring(expected), tostring(actual)))
end

-- the core VM ---------------------------------------------------------------------------------------------------
local v3 = stubs.vector3
local env = stubs.newEnv('client', 'core')
local cam = v3(100.0, 100.0, 30.0)
local camReads, markers = 0, 0
env.GetFinalRenderedCamCoord = function() camReads = camReads + 1 return cam end
-- Wait(0) is one 16 ms frame on the virtual clock (the overlay's draw loop), like client_maps_tests.lua
env.Wait = function(ms) return coroutine.yield((tonumber(ms) or 0) > 0 and ms or 16) end
env.DrawMarker = function() markers = markers + 1 end
env.SetTextOutline = function() end
-- Scene.bind's entity checks (RV2 F8); BOOLs answer 1 / false like the default invoke route (AGENTS §8)
env.NetworkGetEntityIsNetworked = function(e)
    local r = stubs.entities[e]
    return (r and r.networked) and 1 or false
end
env.GetEntityType = function(e)
    local r = stubs.entities[e]
    return r and r.type or 0
end
env.IsPedAPlayer = function(e)
    local r = stubs.entities[e]
    return (r and r.player) and 1 or false
end
stubs.loadFile(env, 'import.lua')
stubs.loadFile(env, 'shared/config.lua')
env.Config.Scene.ClientLruCells = 3                   -- read once by scene_cache.lua: a small LRU to evict from
stubs.loadFile(env, 'client/api.lua')
stubs.loadFile(env, 'shared/scene_codec.lua')
stubs.loadFile(env, 'shared/scene_motion.lua')
stubs.loadFile(env, 'client/scene_cache.lua')
local C = env.CoreSceneRuntime
stubs.loadFile(env, 'client/scene_focus.lua')         -- right after the cache (the manifest order)

-- the fake materialiser (INTERFACES §5 C.mat): records every call ---------------------------------------------------
local log, handlers, holdLog, handles, ids, states, bounds, teleports = {}, {}, {}, {}, {}, {}, {}, {}
local areaOk = true
local M = { PENDING = 'pending' }
function M.add(node) log[#log + 1] = { op = 'add', id = node.id, node = node, wanted = C.cache.wanted(node) } end
function M.update(node, what, data) log[#log + 1] = { op = 'update', id = node.id, what = what, data = data } end
function M.remove(node, how) log[#log + 1] = { op = 'remove', id = node.id, how = how } end
function M.event(node, name, params, age, x, y, z)
    log[#log + 1] = { op = 'event', id = node and node.id or 0, name = name, params = params, age = age, x = x, y = y, z = z }
end
function M.registerKind(k, h) handlers[k] = h end
function M.handleOf(id) return handles[id] end
function M.idOf(e) return ids[e] end
function M.hold(id, owner) holdLog[#holdLog + 1] = 'hold ' .. id .. ' ' .. owner end
function M.release(id, owner) holdLog[#holdLog + 1] = 'release ' .. id .. ' ' .. owner end
function M.areaReady() return areaOk end
function M.setTeleport(on) teleports[#teleports + 1] = on end
function M.stats() return { byState = { live = 2 }, queued = 0, live = 7, fades = 1 } end
function M.stateOf(id) return states[id] end
function M.bound(node, e) bounds[#bounds + 1] = { id = node.id, e = e } end
function M.worldReset() log[#log + 1] = { op = 'worldReset' } end
C.mat = M

check(C.codec == env.Core.SceneCodec and C.motion == env.Core.SceneMotion, 'C.codec / C.motion are the shared libs')
for _, fn in ipairs({ 'node', 'kind', 'kindById', 'forEachNode', 'stats', 'wanted', 'setClaim', 'areaReady',
    'flush', 'reset', 'cell', 'lru', 'count', 'housekeep', 'baseOf' }) do
    eq(type(C.cache[fn]), 'function', 'C.cache.' .. fn)
end
for _, fn in ipairs({ 'requestResync', 'reportSoon', 'stats' }) do
    eq(type(C.focus[fn]), 'function', 'C.focus.' .. fn)
end
eq(C.cache.reportSoon, nil, 'reporting is scene_focus.lua\'s, not the cache\'s')
stubs.loadFile(env, 'client/scene.lua')

local Core = env.Core
local Scene, Codec, Clock, Registry = Core.Scene, Core.SceneCodec, Core.Clock, Core.Registry
local cache = C.cache

-- helpers -------------------------------------------------------------------------------------------------------
local function clearLog() for i = #log, 1, -1 do log[i] = nil end end
local function count(op, id, what)
    local n = 0
    for _, e in ipairs(log) do
        if e.op == op and (id == nil or e.id == id) and (what == nil or e.what == what) then n = n + 1 end
    end
    return n
end
local function find(op, id, what)
    for _, e in ipairs(log) do
        if e.op == op and (id == nil or e.id == id) and (what == nil or e.what == what) then return e end
    end
    return nil
end
local function sent(name)
    local out = {}
    for _, s in ipairs(stubs.sent) do
        if s.name == name then out[#out + 1] = s.args end
    end
    return out
end
local function tick(ms) stubs.tick(ms) end
local function key(cx, cy) return (cx + 32768) * 65536 + (cy + 32768) end
--- one reliable stream payload (header = the server's clock now)
local function stream(...) stubs.triggerOn(env, 'core:scene:s', 65535, Codec.header(Clock.now()) .. table.concat({ ... })) end
--- one latent payload stamped `t`
local function latent(t, ...) stubs.triggerOn(env, 'core:scene:p', 65535, Codec.header(t) .. table.concat({ ... })) end
local function put(id, kind, ver, o)
    o = o or {}
    return Codec.put(id, kind, ver, o.parent or 0, o.flags or 0, o.x or 10.0, o.y or 10.0, o.z or 30.0, o.rx or 0.0,
        o.ry or 0.0, o.rz or 0.0, o.radius or 100, o.extra and Codec.pack(o.extra) or '')
end
local function cell(k, from, to, n, grid, variant) return Codec.cell(grid or 0, k, variant or 1, from, to, n) end
local function sub(k, v, grid, variant) return Codec.sub(grid or 0, k, variant or 1, v) end

-- shared between the groups below (each group is a do-block: assignments, not new locals)
local K1, K2, K3, K4, K5, K6 = key(0, 0), key(1, 0), key(2, 0), key(3, 0), key(4, 0), key(5, 0)
local K7, K8 = key(6, 0), key(7, 0)
local vK2, vK3 = 3, 4
local c1, n101, n102

local KINDS = Codec.kinds({
    { idx = 1, id = 'prop', class = 1, meta = { budget = 'props', handler = 'core' } },
    { idx = 2, id = 'fireworks:battery', class = 7, meta = { handler = 'fireworks', budget = 'custom' } },
    { idx = 3, id = 'audio.source', class = 6, meta = { dep = true, handler = 'core' } },
    { idx = 4, id = 'audio', class = 6, meta = { handler = 'core' } },
    { idx = 5, id = 'marker', class = 4, meta = { budget = 'markers', handler = 'core' } },
})

-----------------------------------------------------------------------------------------------------------------
do
    suite('shape')
    eq(env.CoreSceneRuntime, nil, 'client/scene.lua clears the one-shot handoff global')
    for _, fn in ipairs({ 'get', 'handleOf', 'idOf', 'isAreaReady', 'waitAreaReady', 'hold', 'release', 'on', 'off',
        'listen', 'unlisten', 'claim', 'bind', 'stats', 'handle', 'validKindId', 'isPluginKind', 'tierOf' }) do
        eq(type(Scene[fn]), 'function', 'Core.Scene.' .. fn)
    end
    check(handlers.custom ~= nil, 'the plugin bridge registered as the materialiser handler of class custom')
    eq(handlers.custom and handlers.custom.class, 'custom', 'the bridge is class custom')
    eq(handlers.custom and handlers.custom.fade, 'alpha', 'plugin entities fade by alpha (§55.13)')
    check(env.__vm.netEvents['core:scene:s'] and env.__vm.netEvents['core:scene:p'], 'the stream and latent events are net events')
    check(env.__vm.netEvents['core:client:bucketChanged'] ~= nil, 'bucket changes are heard')
    check(env.__vm.commands.scene ~= nil, '/scene is registered')
    eq(Scene.validKindId('fireworks:battery'), true, 'a plugin kind id is valid')
    eq(Scene.validKindId('audio.source'), true, 'a built-in plain id is valid')
    eq(Scene.validKindId('Bad Id'), false, 'spaces are not')
    eq(Scene.isPluginKind('prop'), false, 'a plain id is no plugin kind')
    eq(Scene.tierOf(100), 'S', 'tier S ≤ 160')
    eq(Scene.tierOf(300), 'M', 'tier M ≤ 448')
    eq(Scene.tierOf(900), 'L', 'tier L above')
    eq(Scene.tierOf(10, true), 'G', 'global nodes are tier G')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('kinds')
    stream(KINDS)
    local kp = cache.kind(1)
    check(kp ~= nil and kp.id == 'prop' and kp.class == 'prop', 'KINDS: idx 1 = prop, the class code becomes its name')
    eq(cache.kindById('audio.source').dependency, true, 'meta.dep marks a dependency kind')
    eq(cache.kindById('fireworks:battery').ready, false, 'a plugin kind is not handled before its resource claims it')
    eq(cache.kindById('prop').ready, true, 'a built-in kind is ready')
    eq(cache.kindById('fireworks:battery').meta.handler, 'fireworks', 'meta travels with the kind')
    eq(cache.stats().kinds, 5, 'five kinds known')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('subscribe + snapshot')
    clearLog()
    stream(sub(K1, 5), cell(K1, 0, 5, 3),
        put(101, 1, 3, { x = 12.5, y = -4.25, z = 30.0, rz = 90.0, radius = 120,
            extra = { f = { model = 'prop_bench_01a', frozen = true }, i = { { action = 'use', label = 'Sit' } } } }),
        put(102, 1, 4, { flags = 64, extra = { f = { model = 'prop_table' } } }),
        put(103, 1, 5, { parent = 102, extra = { f = { model = 'prop_cup' }, o = { x = 0.0, y = 0.0, z = 0.8 }, b = 'root' } }))
    c1 = cache.cell(0, K1)
    eq(c1 and c1.state, 2, 'SUB + snapshot in one payload: the cell is live')
    eq(c1.v, 5, 'at the snapshot version')
    eq(c1.n, 3, 'with its three nodes')
    eq(count('add'), 3, 'three materialiser adds')
    check(find('add', 101).wanted == true, 'a node of a live cell and a ready kind is wanted when added')
    n101 = cache.node(101)
    eq(n101.x, 12.5, 'x decoded from centimetres')
    eq(n101.y, -4.25, 'y')
    eq(n101.rz, 90.0, 'rotation from centi-degrees')
    eq(n101.radius, 120, 'radius in whole metres')
    eq(n101.fields.model, 'prop_bench_01a', 'fields from extra.f')
    eq(n101.fields.frozen, true, 'a boolean field')
    eq(n101.interact[1].action, 'use', 'interact descriptors from extra.i')
    eq(n101.kind.id, 'prop', 'the kind record is resolved')
    eq(n101.ver, 3, 'ver')
    eq(n101.parent, 0, 'a root has parent 0')
    check(type(n101.children) == 'table' and n101.m == nil, 'the record carries a children table (node.m is the materialiser\'s)')
    local n103 = cache.node(103)
    eq(n103.parent, 102, "a child's parent id")
    eq(cache.node(102).children[1], 103, 'the parent lists its child')
    eq(n103.offset.z, 0.8, 'offset from extra.o')
    eq(n103.bone, 'root', 'bone from extra.b')
    eq(n103.cellRef, c1, "the child's cell is its root's")
    local order = {}
    for _, e in ipairs(log) do if e.op == 'add' then order[#order + 1] = e.id end end
    eq(table.concat(order, ','), '101,102,103', 'adds in pack order: the parent before its child')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('journal')
    clearLog()
    stream(cell(K1, 5, 6, 3),
        Codec.set(101, 6, Codec.pack({ f = { frozen = false, tint = 3 } })),
        Codec.move(102, 7, 20.0, 21.0, 31.0, 0.0, 0.0, 45.0),
        Codec.set(101, 8, Codec.pack({ x = { 'tint' } })))
    eq(c1.v, 6, 'a chained entry applies and advances the version')
    eq(count('update', 101, 'fields'), 1, 'two SETs of one node in one payload: one fields update')
    local fu = find('update', 101, 'fields')
    check(fu.data and fu.data.frozen and fu.data.tint, 'the update names every changed field (merged)')
    eq(n101.fields.frozen, false, 'the SET applied')
    eq(n101.fields.tint, nil, 'a removed field (patch.x) is gone')
    eq(n101.ver, 8, 'ver follows the newest op')
    eq(count('update', 102, 'move'), 1, 'MOVE: a move update')
    n102 = cache.node(102)
    check(n102.x == 20.0 and n102.y == 21.0 and n102.z == 31.0 and n102.rz == 45.0, 'the new pose')
    eq(count('add'), 0, 'no adds for known nodes')
    clearLog()
    stream(cell(K1, 6, 7, 3),
        Codec.motion(101, 9, Codec.pack({ t = 'spin', t0 = 1000, axis = 'z', dps = 90 })),
        Codec.set(101, 10, Codec.pack({ i = { { action = 'kick' } } })),
        Codec.del(103, 11, 0))
    eq(find('update', 101, 'motion').data.t, 'spin', 'MOTION: a motion update carrying the descriptor')
    eq(n101.motion.dps, 90, 'node.motion is the descriptor')
    eq(find('update', 101, 'interact').data[1].action, 'kick', 'SET.i replaces the interact list')
    eq(find('remove', 103).how, 0, 'DEL normal: removed')
    eq(cache.node(103), nil, 'gone from the cache')
    eq(#n102.children, 0, 'and from its parent')
    eq(c1.n, 2, 'the cell has two nodes left')
    eq(c1.v, 7, 'version 7')
    clearLog()
    stream(cell(K1, 7, 8, 1), Codec.motion(101, 12, ''))
    eq(n101.motion, nil, 'an empty MOTION blob makes the node static again')
    check(find('update', 101, 'motion') ~= nil and find('update', 101, 'motion').data == nil, 'a motion update with nil')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('ver guard')
    clearLog()
    stream(cell(K1, 8, 9, 2), Codec.set(101, 11, Codec.pack({ f = { frozen = true } })),
        Codec.move(102, 5, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0))
    eq(#log, 0, 'ops with ver <= the node ver change nothing')
    eq(n101.fields.frozen, false, 'the stale SET is ignored')
    eq(n102.x, 20.0, 'the stale MOVE is ignored')
    eq(c1.v, 9, 'the entry itself still advances the cell')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('gap and resync')
    clearLog()
    local rs0 = #sent('core:scene:resync')
    stream(cell(K1, 20, 21, 1), Codec.set(101, 30, Codec.pack({ f = { tint = 9 } })))
    eq(c1.v, 9, 'a gap is not applied')
    eq(n101.fields.tint, nil, 'its ops are dropped')
    eq(cache.stats().gaps, 1, 'counted as a gap')
    tick(0)
    local rs = sent('core:scene:resync')
    eq(#rs, rs0 + 1, 'the gap asks for a resync')
    local r1 = rs[#rs]
    check(r1[1] == 0 and r1[2] == K1 and r1[3] == 1 and r1[4] == 9, 'resync (grid, key, variant, the version held)')
    stream(cell(K1, 21, 22, 0))
    tick(500)
    eq(#sent('core:scene:resync'), rs0 + 1, 'a second gap of the same cell within 2 s asks nothing more')
    clearLog()
    stream(sub(K2, vK2), cell(K2, 0, vK2, 1), put(201, 1, 3, { x = 140.0 }),
        sub(K3, vK3), cell(K3, 0, vK3, 1), put(301, 1, 4, { x = 300.0 }))
    eq(count('add'), 2, 'two more cells with a node each')
    stream(cell(K2, 10, 11, 0), cell(K3, 10, 11, 0))
    tick(0)
    eq(#sent('core:scene:resync'), rs0 + 2, 'two gaps at once: the first request goes')
    tick(60)
    eq(#sent('core:scene:resync'), rs0 + 2, 'the next waits for the gap between requests')
    tick(60)
    eq(#sent('core:scene:resync'), rs0 + 3, '... and goes 110 ms after the first')
    rs = sent('core:scene:resync')
    check(rs[#rs - 1][2] == K2 and rs[#rs][2] == K3, 'one request per cell, in order')
    tick(2000)
    stream(cell(K1, 30, 31, 0))
    tick(0)
    eq(#sent('core:scene:resync'), rs0 + 4, 'after 2 s the same cell may ask again')
    local stale = cache.stats().stale
    stream(cell(K1, 3, 4, 0))
    tick(200)
    eq(#sent('core:scene:resync'), rs0 + 4, 'an entry the cell already has (to <= v) is old news, not a gap')
    eq(C.focus.stats().resyncs, #sent('core:scene:resync'), 'the focus stats count every request sent')
    eq(cache.stats().stale, stale + 1, 'counted as stale')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('snapshot replace')
    -- K1 holds 101 and 102; 201 moves into K1: the K1 snapshot lists it while K2's handover DEL is still to come
    clearLog()
    stream(cell(K1, 0, 25, 3), put(101, 1, 13, { extra = { f = { model = 'prop_bench_01a', frozen = false } } }),
        put(104, 1, 13), put(201, 1, 13, { x = 140.0 }))
    eq(c1.v, 25, 'a snapshot (from = 0) sets the version')
    eq(find('remove', 102) and find('remove', 102).how, 0, 'a node the snapshot does not list leaves (102)')
    eq(count('add', 104), 1, 'a new node is added (104)')
    eq(count('update', 101, 'fields'), 0, 'an unchanged re-PUT names no field')
    eq(count('update', 101, 'move'), 1, 'a re-PUT at another pose is a move')
    eq(count('update', 101, 'interact'), 1, 'a re-PUT without interact clears it')
    eq(n101.interact, nil, 'interact gone')
    eq(c1.n, 3, 'the cell lists 101, 104 and 201')
    local n201 = cache.node(201)
    eq(n201.refs, 2, '201 sits in two cells for a moment')
    eq(count('add', 201), 0, 'and is not added twice')
    clearLog()
    eq(cache.cell(0, K2).v, vK2, 'K2 is still at the version of its snapshot (its gap was not applied)')
    stream(cell(K2, vK2, 12, 1), Codec.del(201, 13, 1))
    vK2 = 12
    eq(count('remove', 201), 0, "K2's handover DEL: 201 stays (K1 holds it)")
    eq(n201.refs, 1, 'one cell left')
    eq(n201.cellRef, c1, 'its cell is K1 now')
    clearLog()
    stream(cell(K1, 0, 27, 2), put(101, 1, 13), put(104, 1, 13))
    eq(count('remove', 201), 1, 'a later K1 snapshot without it removes it')
    check(cache.node(201) == nil, '201 is gone')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('handover')
    -- 301 (K3) moves to K2: DEL(handover) in K3 and PUT in K2 in ONE payload, both orders
    clearLog()
    stream(cell(K3, vK3, 12, 1), Codec.del(301, 20, 1), cell(K2, vK2, 13, 1), put(301, 1, 20, { x = 150.0 }))
    vK2, vK3 = 13, 12
    eq(count('remove', 301), 0, 'DEL(handover) then PUT in one payload: the entity stays')
    eq(count('add', 301), 0, 'no re-add')
    eq(count('update', 301, 'move'), 1, 'the materialiser hears the move')
    local n301 = cache.node(301)
    eq(n301.cellRef, cache.cell(0, K2), 'the node belongs to its new cell')
    eq(n301.refs, 1, 'one membership')
    clearLog()
    stream(cell(K3, vK3, 13, 1), put(301, 1, 21, { x = 290.0 }), cell(K2, vK2, 14, 1), Codec.del(301, 21, 1))
    vK2, vK3 = 14, 13
    eq(count('remove', 301), 0, 'PUT in the new cell first, then the handover DEL: stays too')
    eq(count('update', 301, 'move'), 1, 'one move')
    eq(n301.cellRef, cache.cell(0, K3), 'back in K3')
    clearLog()
    stream(cell(K3, vK3, 14, 1), Codec.del(301, 22, 1))
    vK3 = 14
    eq(find('remove', 301) and find('remove', 301).how, 1,
        'a handover without a PUT in the payload: removed as a handover (the materialiser keeps the entity a moment)')
    eq(cache.node(301), nil, 'gone from the cache')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('pending buffer')
    clearLog()
    local subNow = Clock.now()
    local buffered0 = cache.stats().buffered
    stream(sub(K4, 40))                                   -- the SUB announces v40; its pack travels latent
    local c4 = cache.cell(0, K4)
    eq(c4.state, 1, 'a subscription without content is pending')
    tick(50)
    stream(cell(K4, 40, 41, 1), Codec.set(401, 41, Codec.pack({ f = { lit = true } })))
    stream(cell(K4, 41, 42, 1), put(402, 1, 42))
    eq(c4.v, 0, 'journal entries of a pending cell wait for its snapshot')
    eq(count('add'), 0, 'nothing applied yet')
    eq(cache.stats().buffered - buffered0, 2, 'two entries buffered')
    latent(Clock.add(subNow, -1000), cell(K4, 0, 40, 1), put(499, 1, 40))
    eq(cache.node(499), nil, 'a latent snapshot stamped before the SUB (an older subscription) is ignored')
    eq(c4.state, 1, 'still pending')
    latent(subNow, cell(K4, 0, 40, 1), put(401, 1, 40, { extra = { f = { lit = false } } }))
    eq(c4.state, 2, 'the snapshot and the buffered entries make the cell live')
    eq(c4.v, 42, 'at the newest buffered version')
    eq(cache.node(401).fields.lit, true, 'the buffered SET applied after the snapshot')
    check(cache.node(402) ~= nil and count('add', 402) == 1, 'the buffered PUT too')
    eq(count('update', 401), 0, 'the node was new in this payload: one add, no update')
    clearLog()
    latent(subNow, cell(K4, 0, 40, 1), put(401, 1, 40))
    eq(count('add') + count('update') + count('remove'), 0, 'the same pack arriving again is old news')
    -- a buffered entry that does not chain onto the snapshot asks for a resync
    local rsBefore = #sent('core:scene:resync')
    local sub5 = Clock.now()
    stream(sub(K5, 50))
    stream(cell(K5, 52, 53, 1), put(502, 1, 53))
    latent(sub5, cell(K5, 0, 50, 1), put(501, 1, 50))
    local c5 = cache.cell(0, K5)
    eq(c5.v, 50, 'the snapshot applies')
    eq(cache.node(502), nil, 'the entry after a gap does not')
    tick(300)
    eq(#sent('core:scene:resync'), rsBefore + 1, 'and the cell asks for a resync')
    -- a journal that chains onto the version the client still had (a return from the LRU) needs no pack
    stream(cell(K5, 50, 53, 1), put(502, 1, 53))
    eq(c5.v, 53, 'a chained journal on a pending cell applies at once')
    eq(c5.state, 2, 'live')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('lru')
    stream(cell(K2, vK2, 15, 1), put(205, 1, 15, { x = 140.0 }))
    vK2 = 15
    clearLog()
    local c2 = cache.cell(0, K2)
    stream(Codec.unsub(0, K2))
    eq(c2.state, 3, 'UNSUB keeps the cell in the LRU')
    eq(find('remove', 205) and find('remove', 205).how, 0, 'its nodes leave the wanted set: the materialiser lets them go')
    check(cache.node(205) ~= nil, 'the cache keeps them')
    eq(cache.wanted(cache.node(205)), false, 'wanted() agrees')
    eq(cache.stats().lru, 1, 'one LRU cell')
    clearLog()
    stream(sub(K2, c2.v))
    eq(c2.state, 2, 'a SUB at the version it holds: live again, nothing to fetch')
    eq(count('add', 205), 1, 'wanted again: added')
    clearLog()
    stream(Codec.unsub(0, K2), sub(K2, c2.v))
    eq(#log, 0, 'UNSUB + SUB in one payload: no materialiser churn')
    -- a variant change (a ring change: UNSUB + SUB of the far variant) keeps the old content until the new pack
    clearLog()
    local farNow = Clock.now()
    stream(Codec.unsub(0, K2), sub(K2, 77, 0, 2))
    eq(c2.state, 1, 'the other variant is pending')
    eq(cache.baseOf(c2, 2), 0, 'with no base version of the far variant')
    check(c2.cv == 1 and c2.v == 15, 'the near content (v15) stays cached meanwhile')
    eq(count('remove'), 0, 'the old content stays while the new variant is in flight')
    latent(farNow, cell(K2, 0, 77, 1, 0, 2), put(205, 1, 30, { x = 160.0 }))
    eq(c2.state, 2, 'the far pack lands')
    eq(c2.variant, 2, 'the cell is the far variant now')
    eq(count('remove', 205), 0, 'the node carried over keeps its entity')
    eq(count('update', 205, 'move'), 1, 'and hears its new pose')
    -- eviction by count: ClientLruCells = 3
    clearLog()
    stream(Codec.unsub(0, K2), Codec.unsub(0, K3), Codec.unsub(0, K4))
    eq(cache.stats().lru, 3, 'three LRU cells')
    check(cache.node(205) ~= nil and cache.node(401) ~= nil, 'their nodes stay cached')
    stream(Codec.unsub(0, K5))
    eq(cache.stats().lru, 3, 'a fourth pushes the oldest out')
    eq(cache.cell(0, K2), nil, 'K2 (the oldest) is dropped')
    eq(cache.node(205), nil, 'with its node')
    eq(count('remove', 205), 1, 'which the materialiser had let go at the UNSUB (once)')
    check(cache.cell(0, K5) ~= nil and cache.cell(0, K5).state == 3, 'K5 is in the LRU')
    stream(Codec.unsub(0, 999999))
    eq(cache.stats().lru, 3, 'an UNSUB of an unknown cell changes nothing')
    -- an UNSUB of a pending cell without content drops it
    local c6pending = Clock.now()
    stream(sub(K6, 60))
    stream(Codec.unsub(0, K6))
    eq(cache.cell(0, K6), nil, 'a pending cell without content is not kept')
    latent(c6pending, cell(K6, 0, 60, 1), put(601, 1, 60))
    eq(cache.node(601), nil, 'its pack arriving late is ignored')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('gated')
    clearLog()
    stream(Codec.priv(1), put(611, 1, 5, { flags = 32, x = 50.0 }))
    local g = cache.node(611)
    check(g ~= nil and g.gated == true and g.priv == true, 'a PRIV PUT is a gated node')
    eq(find('add', 611).wanted, true, 'wanted without any cell (gated and present)')
    eq(cache.stats().gated, 1, 'one gated node')
    clearLog()
    stream(Codec.priv(1), Codec.set(611, 6, Codec.pack({ f = { a = 1 } })))
    eq(count('update', 611, 'fields'), 1, 'ops in a PRIV section apply to the node')
    clearLog()
    stream(Codec.priv(1), Codec.del(611, 6, 0))
    eq(count('remove', 611), 1, 'a PRIV DEL at the same ver (its audience lost it) removes it')
    eq(cache.node(611), nil, 'gone')
    eq(cache.stats().gated, 0, 'no gated node left')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('dependencies')
    clearLog()
    stream(sub(K7, 10), cell(K7, 0, 10, 2),
        put(701, 3, 10, { extra = { f = { type = 'loop', url = 'https://radio.example/a.mp3' } } }),
        put(702, 4, 10, { extra = { f = { ['source'] = 701, range = 40 }, d = { 701 } } }))
    eq(count('add', 701), 0, 'a dependency (audio.source) never reaches the materialiser')
    eq(count('add', 702), 1, 'its dependent does')
    local src = cache.node(701)
    check(src ~= nil and src.dependency == true, 'the dependency is cached (the audio handler reads it)')
    eq(cache.wanted(src), false, 'and never wanted')
    eq(cache.node(702).deps[1], 701, 'the dependent lists it')
    eq(cache.stats().deps, 1, 'one dependency held')
    clearLog()
    stream(cell(K7, 10, 11, 1), Codec.set(701, 11, Codec.pack({ f = { url = 'https://radio.example/b.mp3' } })))
    eq(count('update', 702, 'dep'), 1, 'a change of the source is a dep update of its emitter')
    eq(count('update', 701), 0, 'and nothing for the source itself')
    eq(src.fields.url, 'https://radio.example/b.mp3', 'the source record changed')
    clearLog()
    stream(cell(K7, 11, 12, 1), Codec.del(702, 12, 0))
    eq(count('remove', 702), 1, 'the emitter goes')
    eq(cache.node(701), nil, 'the source nobody depends on goes with it (ref-counted)')
    eq(count('remove', 701), 0, 'without a materialiser call')
    eq(cache.stats().deps, 0, 'no dependency held')
    clearLog()
    stream(cell(K7, 12, 13, 1), put(703, 3, 13))
    eq(cache.node(703), nil, 'a dependency PUT without a dependent does not outlive its payload')
    clearLog()
    stream(cell(K7, 13, 14, 3), put(704, 3, 14), put(705, 4, 14, { extra = { d = { 704 } } }),
        put(706, 4, 14, { extra = { d = { 704 } } }))
    stream(cell(K7, 14, 15, 1), Codec.set(705, 15, Codec.pack({ d = {} })))
    check(cache.node(704) ~= nil, 'a source two emitters use stays while one of them still does')
    stream(cell(K7, 15, 16, 1), Codec.del(706, 16, 0))
    eq(cache.node(704), nil, 'and goes with the last')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('placeholders and kinds')
    clearLog()
    stream(cell(K7, 16, 17, 1), put(801, 9, 17))
    eq(count('add', 801), 0, 'a node of an unknown kind index (a placeholder) is not handed to the materialiser')
    check(cache.node(801) ~= nil and cache.wanted(cache.node(801)) == false, 'it is cached, unwanted')
    clearLog()
    stream(Codec.kinds({ { idx = 9, id = 'lamp', class = 4, meta = {} } }))
    eq(count('add', 801), 1, 'KINDS for its index: wanted now, added')
    eq(cache.node(801).kind.id, 'lamp', 'the node points at the new kind')
    clearLog()
    stream(Codec.kinds({ { idx = 9, id = 'lamp', class = 4, meta = {} } }))
    eq(#log, 0, 'the same kind again changes nothing')
    stream(Codec.kinds({ { idx = 9, id = '' } }))
    eq(find('remove', 801) and find('remove', 801).how, 0, 'undefined: a placeholder again, let go')
    eq(cache.kind(9), nil, 'the index is forgotten')
    eq(cache.kindById('lamp'), nil, 'and the id')
    stream(cell(K7, 17, 18, 1), put(803, 1, 18))
    clearLog()
    stream(cell(K7, 18, 19, 1), put(803, 5, 19, { x = 99.0 }))
    eq(count('update', 803, 'kind'), 1, 'a re-PUT with another kind index is a kind update (a re-create)')
    eq(count('update', 803, 'move'), 0, 'which subsumes the other changes')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('events')
    clearLog()
    local t0 = Clock.now()
    stream(Codec.event(101, Clock.add(t0, -250), 1.0, 2.0, 3.0, 'bang', Codec.pack({ power = 3 })),
        Codec.event(0, t0, 5.0, 6.0, 7.0, 'boom', ''), Codec.event(9999, t0, 0, 0, 0, 'lost', ''))
    local ev = find('event', 101)
    check(ev ~= nil and ev.name == 'bang', 'EVENT reaches the materialiser with its node')
    eq(ev.params.power, 3, 'params decoded')
    eq(ev.age, 250, 'age = Clock.now() - t')
    eq(ev.x, 1.0, 'the event position')
    local pe = find('event', 0)
    eq(pe and pe.name, 'boom', 'a positional event (id 0) arrives without a node')
    eq(count('event'), 2, 'an event of an unknown node is dropped')
    clearLog()
    stream(Codec.event(101, Clock.add(t0, 500), 0, 0, 0, 'later', ''))
    eq(find('event', 101).age, -500, 'a future-stamped event has a negative age')
    clearLog()
    stream(cell(K7, 19, 20, 1), put(802, 1, 20), Codec.event(802, t0, 0, 0, 0, 'hello', ''))
    local iAdd, iEv
    for i, e in ipairs(log) do
        if e.op == 'add' and e.id == 802 then iAdd = i end
        if e.op == 'event' and e.id == 802 then iEv = i end
    end
    check(iAdd and iEv and iAdd < iEv, 'an event after the PUT of its node in one payload comes after the add')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('dead reckoning')
    clearLog()
    local tdr = Clock.now()
    stream(Codec.dr(101, tdr, 1.0, 2.0, 3.0, 4.0, 0.0, 0.0, 90.0))
    local dm = n101.motion
    check(dm ~= nil and dm.t == 'dr', 'DR makes the motion a dr descriptor')
    eq(dm.t0, tdr, 'sample time in t0')
    check(dm.p.x == 1.0 and dm.p.y == 2.0 and dm.v.x == 4.0 and dm.yaw == 90.0, 'position, velocity, yaw')
    eq(count('update', 101, 'dr'), 1, 'a dr update')
    clearLog()
    stream(Codec.dr(101, Clock.add(tdr, -100), 9.0, 9.0, 9.0, 0.0, 0.0, 0.0, 0.0))
    eq(count('update', 101, 'dr'), 0, 'an older DR sample is ignored')
    eq(n101.motion.p.x, 1.0, 'the newer one stays')
    stream(Codec.dr(101, Clock.add(tdr, 100), 1.4, 2.0, 3.0, 4.0, 0.0, 0.0, 90.0))
    eq(n101.motion, dm, 'one reused descriptor table per node')
    local px = Core.SceneMotion.pose(0, 0, 0, 0, 0, 0, n101.motion, Clock.add(tdr, 600))
    check(math.abs(px - 3.4) < 1e-6, 'the real Motion lib extrapolates it (p + v * 0.5 s)')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('promotion')
    local vK1 = c1.v
    clearLog()
    stream(cell(K1, vK1, vK1 + 1, 1), Codec.promote(101, 50, 77))
    eq(find('update', 101, 'promote') and find('update', 101, 'promote').data, 77, 'PROMOTE: a promote update with the netId')
    eq(n101.netId, 77, 'node.netId')
    local handoffs = {}
    C.promote = { onPromote = function(_, netId) handoffs[#handoffs + 1] = 'p' .. netId end,
        onDemote = function(node) handoffs[#handoffs + 1] = 'd' .. node.id end }
    clearLog()
    stream(cell(K1, vK1 + 1, vK1 + 2, 1), Codec.demote(101, 51, 5.0, 5.0, 5.0, 0.0, 0.0, 0.0))
    eq(handoffs[1], 'd101', 'with client/scene_promote.lua present the hand-off is its (onDemote)')
    eq(count('update', 101, 'demote'), 0, 'not the materialiser')
    eq(count('update', 101, 'move'), 1, 'the pose moved to the demoted one')
    eq(n101.netId, nil, 'no netId')
    C.promote = nil
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('truncated payload')
    local errs = cache.stats().decodeErrors
    local rsT = #sent('core:scene:resync')
    tick(2500)
    local cut = Codec.header(Clock.now()) .. cell(K1, 0, 90, 2) .. put(101, 1, 60) .. put(105, 1, 60)
    stubs.triggerOn(env, 'core:scene:s', 65535, cut:sub(1, #cut - 5))
    eq(cache.stats().decodeErrors, errs + 1, 'a cut payload is a decode error')
    check(c1.v ~= 90, 'a cut snapshot does not set the version')
    check(cache.node(104) ~= nil, 'and removes nothing it did not mention')
    tick(300)
    eq(#sent('core:scene:resync'), rsT + 1, 'the cell asks for its content again')
    stubs.triggerOn(env, 'core:scene:s', 65535, 'xx')
    stubs.triggerOn(env, 'core:scene:s', 65535, 42)
    eq(cache.stats().decodeErrors, errs + 1, 'a non-payload is ignored before decoding')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('focus reporter')
    eq(camReads, 0, 'no camera read before the player is loaded')
    eq(#sent('core:scene:focus'), 0, 'and no report')
    local focusTimes = {}
    local origTSE = env.TriggerServerEvent
    env.TriggerServerEvent = function(name, ...)
        if name == 'core:scene:focus' then focusTimes[#focusTimes + 1] = stubs.now() end
        return origTSE(name, ...)
    end
    env.LocalPlayer.state.loaded = true
    tick(1000)
    local fr = sent('core:scene:focus')
    eq(#fr, 1, 'the first sample after loading reports')
    local r = fr[1]
    check(r[1] == 100.0 and r[2] == 100.0 and r[3] == 30.0, 'x, y, z = the rendered camera')
    eq(r[7], 1, 'seq 1')
    check(type(r[8]) == 'table', 'held is a table')
    local nHeld = 0
    for k, v in pairs(r[8]) do
        nHeld = nHeld + 1
        check(type(k) == 'string' and k:match('^%d:%d+:%d$') ~= nil and math.type(v) == 'integer', 'held entry ' .. tostring(k))
    end
    eq(nHeld, 3, 'held lists the three LRU cells')
    eq(r[8][('0:%d:1'):format(K5)], cache.cell(0, K5).v, "held = { ['<grid>:<key>:<variant>'] = version }")
    local lruList = cache.lru()
    eq(#lruList, 3, 'cache.lru() lists the LRU cells')
    eq(lruList[#lruList], cache.cell(0, K5), 'oldest first, newest last')
    eq(C.focus.stats().reports, 1, 'the focus stats count reports')
    eq(C.focus.stats().loaded, true, 'and know the player is loaded')
    local reads = camReads
    tick(3000)
    check(camReads - reads >= 2 and camReads - reads <= 4, 'a still camera is sampled once a second')
    eq(#sent('core:scene:focus'), 1, 'and not reported again')
    cam = v3(120.0, 100.0, 30.0)
    tick(1000)
    fr = sent('core:scene:focus')
    eq(#fr, 2, 'a move of 20 m reports')
    check(fr[2][4] > 15 and fr[2][4] < 25 and fr[2][5] == 0.0, 'with the camera velocity in m/s')
    eq(fr[2][7], 2, 'seq 2')
    cam = v3(125.0, 100.0, 30.0)
    tick(250)
    eq(#sent('core:scene:focus'), 2, 'moving (250 ms samples): 5 m in the same cell is no report')
    cam = v3(130.0, 100.0, 30.0)
    tick(250)
    eq(#sent('core:scene:focus'), 3, 'crossing a near-cell border (x = 128) reports')
    local n0 = #sent('core:scene:focus')
    for i = 1, 24 do
        cam = v3(130.0 + i * 0.2, 100.0, 30.0)
        tick(250)
    end
    eq(#sent('core:scene:focus'), n0 + 1, 'a camera moving less than 16 m still reports every 5 s')
    local base = #focusTimes
    for i = 1, 8 do
        cam = v3(200.0 + i * 20.0, 100.0, 30.0)
        tick(250)
    end
    tick(100)
    local minGap = math.huge
    for i = base + 1, #focusTimes do
        local gap = focusTimes[i] - focusTimes[i - 1]
        if gap < minGap then minGap = gap end
    end
    check(minGap >= 280, 'reports stay >= MinIntervalMs + 30 ms apart (got ' .. tostring(minGap) .. ')')
    check(#focusTimes - base >= 6, 'and a fast camera still reports about every 280 ms')
    cam = v3(3000.0, 3000.0, 30.0)
    tick(1000)
    fr = sent('core:scene:focus')
    check(fr[#fr][1] == 3000.0 and fr[#fr][4] == 0.0, 'a jump (teleport) reports the new place with no velocity')
    local seqs = true
    for i = 2, #fr do if fr[i][7] ~= fr[i - 1][7] + 1 then seqs = false end end
    check(seqs, 'seq counts every report')
    clearLog()
    tick(121000)
    eq(cache.stats().lru, 0, 'LRU cells older than ClientLruMs are dropped')
    check(cache.node(401) == nil and cache.node(501) == nil, 'with their nodes')
    eq(count('remove'), 0, 'which the materialiser had already let go (no second remove)')
    local K99 = key(9, 9)
    local function asked(k)
        local n = 0
        for _, a in ipairs(sent('core:scene:resync')) do if a[2] == k then n = n + 1 end end
        return n
    end
    local k1Asked = asked(K1)
    stream(sub(K99, 90))
    tick(10000)
    eq(asked(K99), 0, 'a pending subscription waits for its pack')
    tick(6000)
    eq(asked(K99), 1, 'and asks again after 15 s without content')
    check(asked(K1) > k1Asked, 'a live cell whose resync answer never came (the cut payload above) asks again too')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('bucket change')
    clearLog()
    local before, known = 0, 0
    cache.forEachNode(function(n)
        known = known + 1
        if n.added then before = before + 1 end
    end)
    check(before > 0 and known > before, 'the cache holds nodes, some of them unwanted')
    -- the FIRST notice only tells the client its bucket: nothing is dropped (RV2 F1 — Player.setBucket notifies
    -- even when the bucket stays, an admin goto / return in bucket 0, and the server keeps what it sent)
    local reports0 = #sent('core:scene:focus')
    stubs.triggerOn(env, 'core:client:bucketChanged', 65535, 0)
    local nc0, nn0 = cache.count()
    check(nc0 > 0 and nn0 == known, 'the first notice (bucket 0, where the content is from) keeps the cache')
    eq(count('remove'), 0, 'nothing is removed')
    eq(C.focus.stats().bucket, 0, 'the bucket is seeded')
    tick(300)
    eq(#sent('core:scene:focus'), reports0 + 1, 'and a report goes out')
    stubs.triggerOn(env, 'core:client:bucketChanged', 65535, 0)
    eq(select(2, cache.count()), known, 'the same bucket again keeps it too')
    local reports = #sent('core:scene:focus')
    local rsB = #sent('core:scene:resync')
    local vK1 = cache.cell(0, K1).v
    tick(2100)
    stream(cell(K1, vK1 + 5, vK1 + 6, 0))              -- a gap: a resync is queued ...
    eq(C.focus.stats().resyncQueued, 1, 'a resync is queued')
    stubs.triggerOn(env, 'core:client:bucketChanged', 65535, 7)
    eq(C.focus.stats().resyncQueued, 0, '... and a bucket change clears the queue')
    eq(cache.stats().nodes, 0, 'a new bucket drops every cached node')
    eq(cache.stats().cells, 0, 'and every cell')
    eq(count('remove'), before, 'the materialiser hears the removal of each node it knew')
    local world, firstWorld, firstRemove = 0, nil, nil
    for i, e in ipairs(log) do
        if e.op == 'remove' and e.how == 3 then world = world + 1 end
        if e.op == 'worldReset' and not firstWorld then firstWorld = i end
        if e.op == 'remove' and not firstRemove then firstRemove = i end
    end
    eq(world, before, "RV6 F3: a bucket change removes with how 3 ('world': gone at once, no visibility-safe linger)")
    check(firstWorld ~= nil and firstWorld < firstRemove, '... after C.mat.worldReset (what already retires goes too)')
    tick(300)
    eq(#sent('core:scene:focus'), reports + 1, 'a real change reports at once')
    eq(#sent('core:scene:resync'), rsB, "no request for the old bucket's cell")
    eq(C.focus.stats().bucket, 7, 'the bucket is remembered (scene_focus.lua)')
    eq(Scene.stats().bucket, 7, 'and merged into Scene.stats()')
    local nc, nn = cache.count()
    check(nc == 0 and nn == 0, 'cache.count() is 0, 0 after the reset')
    stream(sub(K1, 5), cell(K1, 0, 5, 2), put(101, 1, 3, { x = 12.5 }), put(102, 1, 4, { x = 20.0 }))
    stubs.triggerOn(env, 'core:client:bucketChanged', 65535, 7)
    check(cache.node(101) ~= nil, 'the same bucket again keeps the content')
    stubs.triggerOn(env, 'core:client:bucketChanged', 65535, -3)
    check(cache.node(101) ~= nil, 'a malformed bucket is ignored')
    c1 = cache.cell(0, K1)
    n101 = cache.node(101)
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('Scene.get / handleOf / idOf')
    states[101] = 3
    local view = Scene.get(101)
    check(view ~= nil and view.id == 101 and view.kind == 'prop', 'get: id and kind id')
    check(env.type(view.pos) == 'vector3' and view.pos.x == 12.5, 'pos is a vector3')
    check(env.type(view.rot) == 'vector3', 'rot is a vector3')
    eq(view.state, 'live', "state = the materialiser's state by name")
    eq(view.parent, nil, 'a root has no parent')
    view.fields.model = 'hacked'
    eq(n101.fields.model, nil, 'get answers a copy: the cache is untouched')
    states[101] = nil
    eq(Scene.get(101).state, 'known', 'no materialiser state: known')
    eq(Scene.get(99999), nil, 'an unknown id: nil')
    eq(Scene.get('101'), nil, 'a string id: nil')
    handles[101], ids[5001] = 5001, 101
    eq(Scene.handleOf(101), 5001, "handleOf = the materialiser's entity")
    eq(Scene.idOf(5001), 101, 'idOf')
    eq(Scene.handleOf(102), nil, 'no entity: nil')
    eq(Scene.idOf(0), nil, 'entity 0: nil')
    eq(Scene.handleOf(-4), nil, 'a bad id: nil')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('isAreaReady / waitAreaReady')
    eq(Scene.isAreaReady(v3(64.0, 64.0, 30.0), 50), true, 'the near cell around the point is live, the materialiser agrees')
    eq(Scene.isAreaReady(v3(10.0, 10.0, 30.0), 50), false, 'a neighbouring near cell was never subscribed: not ready')
    areaOk = false
    eq(Scene.isAreaReady(v3(64.0, 64.0, 30.0), 50), false, 'the materialiser decides the node half')
    areaOk = true
    local regionNow = Clock.now()
    stream(sub(K1, 3, 1, 3))
    eq(Scene.isAreaReady(v3(64.0, 64.0, 30.0), 50), false, 'a subscribed region still waiting for its pack blocks')
    latent(regionNow, cell(K1, 0, 3, 1, 1, 3), put(901, 1, 3, { x = 64.0, y = 64.0, radius = 900 }))
    eq(Scene.isAreaReady(v3(64.0, 64.0, 30.0), 50), true, 'ready once it landed')
    eq(Scene.isAreaReady({ x = 'a' }, 50), false, 'bad coordinates: false')
    eq(Scene.isAreaReady(v3(64.0, 64.0, 30.0)), true, 'the default radius is 50 m')
    local result, reportsW = nil, #sent('core:scene:focus')
    env.CreateThread(function() result = Scene.waitAreaReady(v3(300.0, 300.0, 30.0), 50, 2000) end)
    tick(500)
    eq(result, nil, 'waitAreaReady waits while the area is not subscribed')
    eq(#teleports, 0, 'waiting never switches the materialiser into teleport mode (RV2 F7)')
    check(#sent('core:scene:focus') > reportsW, 'and a focus report goes out at once')
    stream(sub(key(2, 2), 0), sub(key(1, 2), 0), sub(key(2, 1), 0), sub(key(1, 1), 0))
    tick(100)
    eq(result, true, 'ready once the cells arrived (empty cells count)')
    eq(#teleports, 0, 'not even when it returns')
    local timedOut
    env.CreateThread(function() timedOut = Scene.waitAreaReady(v3(-5000.0, -5000.0, 30.0), 50, 300) end)
    tick(400)
    eq(timedOut, false, 'a timeout answers false')
    eq(Scene.waitAreaReady('nope'), false, 'bad coordinates answer false at once')
    -- a map projection the server still runs in slices (client/maps.lua's C.mapsPending over GlobalState
    -- 'core:mapsPending') keeps the area not ready — client/spawn.lua's teleports wait on Scene.waitAreaReady only
    eq(C.mapsPending, nil, 'no maps client in this VM: nothing pending (everything above unchanged)')
    local boxes = {}
    C.mapsPending = function(x, y, r)
        for _, b in ipairs(boxes) do
            local dx, dy = math.max(b[1] - x, 0.0, x - b[3]), math.max(b[2] - y, 0.0, y - b[4])
            if dx * dx + dy * dy <= r * r then return true end
        end
        return false
    end
    boxes[1] = { 0.0, 0.0, 100.0, 100.0 }
    eq(Scene.isAreaReady(v3(64.0, 64.0, 30.0), 50), false, 'a pending map box over the point: not ready')
    eq(Scene.isAreaReady(v3(300.0, 300.0, 30.0), 50), true, '... one elsewhere changes nothing')
    local waited
    env.CreateThread(function() waited = Scene.waitAreaReady(v3(64.0, 64.0, 30.0), 50, 3000) end)
    tick(500)
    eq(waited, nil, 'waitAreaReady waits while the projection is queued there')
    boxes[1] = nil
    tick(100)
    eq(waited, true, '... and answers true once it is done')
    boxes[1] = { 0.0, 0.0, 100.0, 100.0 }
    local capped
    env.CreateThread(function() capped = Scene.waitAreaReady(v3(64.0, 64.0, 30.0), 50, 300) end)
    tick(400)
    eq(capped, false, '... bounded by the same timeout')
    C.mapsPending = function() error('boom') end
    eq(Scene.isAreaReady(v3(64.0, 64.0, 30.0), 50), true, 'a failing hand-off is ignored')
    C.mapsPending = nil
    eq(Scene.isAreaReady(v3(64.0, 64.0, 30.0), 50), true, 'no hand-off: ready as before')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('hold / release')
    eq(Scene.hold(101), 5001, 'hold answers the entity')
    eq(holdLog[#holdLog], 'hold 101 core', 'the materialiser holds it for the caller')
    local nHolds = #holdLog
    Scene.hold(101)
    eq(#holdLog, nHolds, 'a second hold of the same owner is one hold')
    eq(Scene.release(101), true, 'release')
    eq(holdLog[#holdLog], 'release 101 core', 'the materialiser releases it')
    eq(Scene.release(101), false, 'a second release is refused')
    Registry.withCaller('editor', Scene.hold, 102)
    eq(holdLog[#holdLog], 'hold 102 editor', 'a plugin holds (owner = the caller)')
    stubs.triggerOn(env, 'onResourceStop', 0, 'editor')
    eq(holdLog[#holdLog], 'release 102 editor', 'a stopping owner releases its holds')
    eq(Scene.hold('x'), nil, 'a bad id holds nothing')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('stats')
    local st = Scene.stats()
    eq(st.fades, 1, "the materialiser's counters")
    eq(st.live, 7, "'live' is the materialiser's (materialised nodes)")
    check((st.cellsLive or 0) >= 1, 'the cache cell states are cellsPending / cellsLive / cellsLru')
    eq(st.nodes, cache.stats().nodes, 'nodes = the cache count')
    check(type(st.plugin) == 'table' and st.plugin.claims == 0, 'plugin counters')
    check(st.bytesIn > 0 and st.payloads > 0, 'bytes and payloads in')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('listeners (core VM)')
    local evTriggers = 0
    local origTE = env.TriggerEvent
    env.TriggerEvent = function(name, ...)
        if name == 'core:scene:ev' then evTriggers = evTriggers + 1 end
        return origTE(name, ...)
    end
    local heard = {}
    local h1 = Scene.on('changed', 'prop', function(id, info) heard[#heard + 1] = { id = id, info = info } end)
    check(math.type(h1) == 'integer', 'on answers a handle')
    local vA = c1.v
    stream(cell(K1, vA, vA + 1, 1), Codec.set(101, 20, Codec.pack({ f = { a = 1 } })))
    eq(#heard, 1, "a core listener hears a change of its kind")
    eq(heard[1].id, 101, 'with the node id')
    eq(heard[1].info.kind, 'prop', 'and the kind id')
    local hasFields = false
    for _, w in ipairs(heard[1].info.changes) do if w == 'fields' then hasFields = true end end
    check(hasFields, "info.changes names 'fields'")
    eq(heard[1].info.fields and heard[1].info.fields[1], 'a', 'info.fields names the changed field')
    eq(evTriggers, 0, 'no plugin listens: no core:scene:ev')
    local evs = {}
    local h2 = Scene.on('event', 101, function(_, info) evs[#evs + 1] = info end)
    stream(Codec.event(101, Clock.now(), 1.0, 2.0, 3.0, 'pop', Codec.pack({ k = 1 })))
    check(evs[1] and evs[1].name == 'pop' and evs[1].params.k == 1 and evs[1].age == 0, 'an event listener by node id')
    eq(evs[1] and evs[1].pos.x, 1.0, 'with the event position')
    local all = {}
    local h3 = Scene.on('event', '*', function(id) all[#all + 1] = id end)
    stream(Codec.event(0, Clock.now(), 1.0, 2.0, 3.0, 'boom', ''))
    eq(all[#all], 0, "a '*' listener hears positional events (id 0)")
    eq(Scene.off(h1), true, 'off')
    eq(Scene.off(h1), false, 'off twice: false')
    vA = c1.v
    stream(cell(K1, vA, vA + 1, 1), Codec.set(101, 21, Codec.pack({ f = { a = 2 } })))
    eq(#heard, 1, 'an removed listener hears nothing')
    eq(Scene.on('nope', '*', print), nil, 'an unknown event: nil')
    eq(Scene.on('changed', 'bad id!', print), nil, 'a malformed kind id: nil')
    local lives = {}
    local h4 = Scene.on('live', 'prop', function(_, info) lives[#lives + 1] = info.entity end)
    C.emit('live', n101, 5001)
    eq(lives[1], 5001, "'live' from the materialiser (C.emit) carries the entity")
    local proms = {}
    local h5 = Scene.on('promoted', 101, function(_, info) proms[#proms + 1] = info.netId end)
    vA = c1.v
    stream(cell(K1, vA, vA + 1, 1), Codec.promote(101, 22, 88))
    eq(proms[1], 88, "'promoted' with the netId")
    local bad = Scene.on('changed', 101, function() error('boom') end)
    vA = c1.v
    stream(cell(K1, vA, vA + 1, 1), Codec.set(101, 23, Codec.pack({ f = { a = 3 } })))
    eq(n101.fields.a, 3, 'a failing listener breaks nothing')
    Scene.off(h2); Scene.off(h3); Scene.off(h4); Scene.off(h5); Scene.off(bad)
    env.TriggerEvent = origTE
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('plugin bridge (two VMs)')
    stubs.resourceStates.fireworks = 'started'
    local penv = stubs.newEnv('client', 'fireworks')
    penv.Wait = env.Wait
    stubs.loadImport(penv)
    local PCore = penv.Core
    -- FiveM: a local event reaches every client VM, each handler in its own coroutine with msgpack-copied args
    local vms = { env, penv }
    local evCount = {}
    local function deep(v, seen)
        if type(v) ~= 'table' then return v end
        local out = setmetatable({}, getmetatable(v))
        for k, x in pairs(v) do out[k] = deep(x) end
        return out
    end
    local function broadcast(name, ...)
        evCount[name] = (evCount[name] or 0) + 1
        local args = table.pack(...)
        for _, e in ipairs(vms) do
            local list = e.__vm.handlers[name]
            if list then
                local copyList = { table.unpack(list) }
                for i = 1, #copyList do
                    local fn, a = copyList[i].fn, deep(args)
                    e.CreateThread(function() fn(table.unpack(a, 1, a.n)) end)
                end
            end
        end
    end
    env.TriggerEvent, penv.TriggerEvent = broadcast, broadcast

    check(rawget(PCore.Scene, 'handle') ~= nil and rawget(PCore.Scene, 'on') ~= nil, 'the lib defines handle / on / off in the plugin VM')
    eq(rawget(PCore.Scene, 'claim'), nil, 'claim is not the lib\'s: the proxy fills it in')
    local ent = stubs.newEntity(3, {})
    local made, updates, destroyed, fired = {}, {}, {}, {}
    local H = {
        create = function(node) made[#made + 1] = node return ent end,
        update = function(node, e, changed) updates[#updates + 1] = { node = node, e = e, changed = changed } end,
        destroy = function(node, e) destroyed[#destroyed + 1] = { node = node, e = e } end,
        event = function(node, e, name, params, age) fired[#fired + 1] = { node = node, e = e, name = name, params = params, age = age } end,
    }
    eq(PCore.Scene.handle('fireworks:battery', H), true, 'Scene.handle in the plugin VM (claims through the proxy)')
    check(rawget(PCore.Scene, 'claim') ~= nil, 'the proxy call was made (a cached proxy closure)')
    eq(cache.kindById('fireworks:battery').ready, true, 'the kind is ready: the resource its meta.handler names claimed it')
    eq(PCore.Scene.handle('prop', H), false, 'a built-in kind cannot be handled by a plugin')
    eq(PCore.Scene.handle('fireworks:x', {}), false, 'a handler table needs create')
    clearLog()
    local vB = c1.v
    stream(cell(K1, vB, vB + 1, 1), put(1001, 2, 5, { x = 30.0, extra = { f = { shells = 12 }, i = { { action = 'light' } } } }))
    eq(find('add', 1001).wanted, true, 'a node of a claimed plugin kind is wanted')
    local bridge = handlers.custom
    local pnode = cache.node(1001)
    local h = bridge.create(pnode, { late = false })
    eq(h, ent, 'a handler that answers at once: create returns its entity (bound inside the event)')
    eq(#made, 1, "the plugin's create ran in its own VM")
    check(made[1].id == 1001 and made[1].kind == 'fireworks:battery', 'with the node id and kind')
    eq(made[1].fields.shells, 12, 'and its fields')
    eq(penv.type(made[1].pos), 'vector3', 'pos is a vector3')
    check(made[1].fields ~= pnode.fields, 'the plugin got a copy')
    eq(Scene.idOf(ent), nil, 'a sync bind is the materialiser\'s to index (it got the handle)')
    bridge.update(pnode, h, 'fields', { shells = true })
    eq(#updates, 1, 'update reaches the plugin')
    eq(updates[1].e, ent, 'with the entity its create returned')
    eq(updates[1].changed, 'fields', 'and what changed')
    eq(updates[1].node.changedFields[1], 'shells', 'the changed field names')
    bridge.update(pnode, h, 'wanted', false)
    eq(#updates, 1, "the materialiser's own 'wanted' never reaches a plugin")
    bridge.update(pnode, h, 'dr', pnode.motion)
    eq(#updates, 1, 'nor a dead-reckoning tick (the movers place the entity)')
    bridge.event(pnode, h, 'launch', { n = 3 }, 120)
    check(fired[1] and fired[1].name == 'launch' and fired[1].params.n == 3 and fired[1].age == 120, 'event(name, params, age)')
    eq(fired[1].e, ent, 'with the entity')
    bridge.destroy(pnode, h)
    eq(#destroyed, 1, 'destroy reaches the plugin')
    eq(destroyed[1].e, ent, 'with its entity')
    eq(destroyed[1].node.id, 1001, 'and the node')
    bridge.update(pnode, h, 'fields', {})
    eq(#updates, 1, 'after destroy nothing more is sent')

    -- a handler that yields (it streams a model first): the create waits for the late bind
    local ent2 = stubs.newEntity(3, {})
    H.create = function() penv.Wait(300) return ent2 end
    local r2 = bridge.create(pnode, {})
    eq(r2, 'pending', "a handler that yields: create answers the materialiser's PENDING")
    eq(Scene.handleOf(1001), nil, 'no entity yet')
    tick(350)
    check(bounds[#bounds] and bounds[#bounds].id == 1001 and bounds[#bounds].e == ent2, 'the late bind reaches the materialiser (mat.bound)')
    eq(Scene.handleOf(1001), ent2, 'handleOf knows a late-bound entity')
    eq(Scene.idOf(ent2), 1001, 'idOf too')
    bridge.destroy(pnode, ent2)
    eq(Scene.handleOf(1001), nil, 'destroy forgets it')
    local savedPending, savedBound = M.PENDING, M.bound
    M.PENDING, M.bound = nil, nil
    local ent4 = stubs.newEntity(3, {})
    H.create = function() penv.Wait(200) return ent4 end
    eq(bridge.create(pnode, {}), true, 'a materialiser without late binds: a yielding create answers true')
    tick(250)
    eq(Scene.handleOf(1001), ent4, 'the late entity is still known to handleOf')
    eq(Scene.idOf(ent4), 1001, 'and idOf')
    bridge.destroy(pnode, true)
    H.create = function() penv.Wait(60000) return 0 end
    bridge.create(pnode, {})
    eq(Scene.stats().plugin.waiting, 1, 'a create waits for its bind')
    tick(5100)
    eq(Scene.stats().plugin.waiting, 0, 'without late binds in the materialiser the bridge gives up after 5 s')
    bridge.destroy(pnode, true)
    M.PENDING, M.bound = savedPending, savedBound
    H.create = function() penv.Wait(60000) return 0 end
    local nb = #bounds
    local dSlow = #destroyed
    bridge.create(pnode, {})
    tick(5100)
    eq(#bounds, nb, 'a missing bind: with C.mat.PENDING the materialiser times it out itself (no bridge timer)')
    bridge.destroy(pnode, nil)                        -- the materialiser's timeout: destroy(node, nil)
    eq(#destroyed, dSlow + 1, 'the plugin hears destroy(node, nil)')
    eq(destroyed[#destroyed].e, nil, 'without an entity')
    eq(Scene.stats().plugin.waiting, 0, 'and the bridge forgets the create')
    local ent3 = stubs.newEntity(3, {})
    local lateDestroy = #destroyed
    H.create = function() penv.Wait(100) return ent3 end
    bridge.create(pnode, {})
    bridge.destroy(pnode, nil)
    tick(200)
    eq(#destroyed, lateDestroy + 2, 'a bind for a node destroyed meanwhile is refused: the plugin deletes its entity')
    eq(destroyed[#destroyed].e, ent3, 'the late entity is the one it deletes')
    -- the bind is the claimant's only
    local rogue = stubs.newEnv('client', 'rogue')
    stubs.loadImport(rogue)
    stubs.resourceStates.rogue = 'started'
    H.create = function() return ent end
    bridge.create(pnode, {})
    eq(rogue.Core.Scene.bind(1001, ent), false, 'another resource cannot bind a node of this kind')
    eq(rogue.Core.Scene.claim('fireworks:battery'), false, 'nor claim a kind a running resource handles')
    eq(Scene.bind(1001, ent), false, "not even core's own code")
    -- prompts: client/scene_kinds.lua's helper when it is there
    local prompts = {}
    C.kinds = { syncInteract = function(node, target) prompts[#prompts + 1] = { node.id, target } end,
        clearInteract = function(id) prompts[#prompts + 1] = { 'clear', id } end }
    bridge.create(pnode, {})
    check(prompts[1] and prompts[1][1] == 1001 and prompts[1][2] == ent, 'a created plugin node gets its prompts on the entity')
    bridge.destroy(pnode, ent)
    eq(prompts[#prompts][1], 'clear', 'and loses them on destroy')
    C.kinds = nil

    -- plugin listeners: core:scene:ev only for listened kinds
    local pheard = {}
    local ph = PCore.Scene.on('changed', 'prop', function(id, info) pheard[#pheard + 1] = { id = id, info = info } end)
    check(ph ~= nil, "a plugin's Scene.on answers a handle")
    local ev0 = evCount['core:scene:ev'] or 0
    vB = c1.v
    stream(cell(K1, vB, vB + 1, 1), Codec.set(101, 40, Codec.pack({ f = { a = 9 } })))
    eq(#pheard, 1, 'the plugin hears a change of the kind it listens to')
    eq(pheard[1].id, 101, 'with the id')
    eq(pheard[1].info.kind, 'prop', 'and the kind')
    eq(evCount['core:scene:ev'], ev0 + 1, 'one local event')
    vB = c1.v
    stream(cell(K1, vB, vB + 1, 1), Codec.set(1001, 41, Codec.pack({ f = { shells = 2 } })))
    eq(evCount['core:scene:ev'], ev0 + 1, 'a kind nobody listens to triggers nothing')
    eq(PCore.Scene.off(ph), true, 'off')
    vB = c1.v
    stream(cell(K1, vB, vB + 1, 1), Codec.set(101, 42, Codec.pack({ f = { a = 10 } })))
    eq(evCount['core:scene:ev'], ev0 + 1, 'after off (unlisten) nothing is triggered')
    eq(#pheard, 1, 'and nothing heard')
    eq(PCore.Scene.on('nope', '*', print), nil, 'an unknown event: nil')
    local pall = {}
    PCore.Scene.on('event', '*', function(id) pall[#pall + 1] = id end)
    stream(Codec.event(0, Clock.now(), 0, 0, 0, 'boom', ''))
    eq(pall[#pall], 0, "a plugin's '*' listener hears positional events")

    -- owner stop: the claim and the listens of the stopped resource go
    clearLog()
    stubs.triggerOn(env, 'onResourceStop', 0, 'fireworks')
    eq(cache.kindById('fireworks:battery').ready, false, 'a stopping handler resource unclaims its kind')
    eq(find('remove', 1001) and find('remove', 1001).how, 0, 'its nodes turn unwanted: the materialiser lets them go')
    local ev1 = evCount['core:scene:ev'] or 0
    stream(Codec.event(0, Clock.now(), 0, 0, 0, 'boom', ''))
    eq(evCount['core:scene:ev'], ev1, "the stopped resource's listens are gone")
    eq(Scene.stats().plugin.claims, 0, 'no claim left')
    -- core restarted (seen from the plugin VM): the lib claims and listens again
    stubs.triggerOn(penv, 'onClientResourceStart', 0, 'core')
    eq(cache.kindById('fireworks:battery').ready, true, 'the lib claims again when core starts')
    stream(Codec.event(0, Clock.now(), 0, 0, 0, 'boom', ''))
    eq(evCount['core:scene:ev'], ev1 + 1, 'and listens again')
    -- core stops (seen from the plugin VM): its plugin-kind entities are destroyed through the handler
    bridge.create(pnode, {})
    local d0 = #destroyed
    stubs.triggerOn(penv, 'onClientResourceStop', 0, 'core')
    eq(#destroyed, d0 + 1, 'a core stop destroys the entities of this VM')
    eq(destroyed[#destroyed].e, ent, 'the right one')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('claims and handlers')
    stream(Codec.kinds({ { idx = 20, id = 'lights:neon', class = 7, meta = { handler = 'lights' } } }))
    local neon = cache.kindById('lights:neon')
    eq(neon.ready, false, 'a plugin kind nobody claimed is not handled')
    Registry.withCaller('fireworks', Scene.claim, 'lights:neon')
    eq(neon.ready, false, 'a claim by a resource other than meta.handler does not make it ready')
    Registry.withCaller('lights', Scene.claim, 'lights:neon')
    eq(neon.ready, false, 'while that resource runs, the named handler cannot take it over')
    stubs.triggerOn(env, 'onResourceStop', 0, 'fireworks')
    Registry.withCaller('lights', Scene.claim, 'lights:neon')
    eq(neon.ready, true, 'the named handler claims it once the other one stopped')
    eq(Scene.claim('bad id'), false, 'a malformed kind id cannot be claimed')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('gated dependencies')
    clearLog()
    stream(Codec.priv(2), put(1101, 3, 9), put(1102, 4, 9, { flags = 32, extra = { d = { 1101 } } }))
    eq(count('add', 1102), 1, 'a gated emitter is added')
    eq(count('add', 1101), 0, 'its source (same PRIV section) is not')
    check(cache.node(1101) ~= nil, 'the source is cached')
    clearLog()
    stream(Codec.priv(1), Codec.del(1102, 9, 0))
    eq(count('remove', 1102), 1, 'the gated emitter goes')
    eq(cache.node(1101), nil, 'and its source with it')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('forEachNode / cell')
    local seen = 0
    cache.forEachNode(function() seen = seen + 1 end)
    eq(seen, cache.stats().nodes, 'forEachNode visits every cached node')
    local first = 0
    cache.forEachNode(function() first = first + 1 return true end)
    eq(first, 1, 'returning true stops it')
    local cr = cache.cell(0, K1)
    check(cr ~= nil and cr.grid == 0 and cr.key == K1 and cr.state == 2, 'cell(grid, key) answers the record')
    eq(cache.STATE_NAME[cr.state], 'live', 'with a state name table')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('/scene')
    local cmd = env.__vm.commands.scene.fn
    local function printedHas(needle)
        for i = #stubs.printed, 1, -1 do
            if stubs.printed[i]:find(needle, 1, true) then return true end
        end
        return false
    end
    cmd(0, {})
    check(printedHas('/scene needs'), '/scene without Debug, ACE or duty is refused')
    env.IsAceAllowed = function(object) return object == 'core.admin' and 1 or false end
    cmd(0, {})
    check(printedHas('scene nodes'), 'the ACE core.admin (BOOL 1) allows it: stats are printed')
    env.IsAceAllowed = nil
    env.Config.Scene.Debug = true
    local m0 = markers
    cmd(0, { 'debug' })
    check(printedHas('debug overlay on'), '/scene debug turns the overlay on')
    states[101] = 3
    tick(600)
    check(markers > m0, 'the overlay draws markers at the nearest nodes')
    local labelled = false
    for _, t in ipairs(stubs.drawTexts) do
        if t:find('^101 prop live') then labelled = true end
    end
    check(labelled, "a node label reads '<id> <kind> <state> <distance>'")
    local lined = false
    for _, t in ipairs(stubs.drawTexts) do
        if t:find('^scene  cells') then lined = true end
    end
    check(lined, 'the screen lines show the counts')
    cmd(0, { 'debug' })
    tick(50)
    local m1 = markers
    tick(500)
    eq(markers, m1, '/scene debug again: the loop ends, nothing more is drawn')
    cmd(0, { 'debug' })
    cmd(0, { 'debug' })
    cmd(0, { 'debug' })
    tick(50)
    local m2 = markers
    tick(160)
    check(markers - m2 <= (cache.stats().nodes + 1) * 11, 'toggling quickly never runs two draw loops')
    cmd(0, { 'debug' })
    tick(50)
    env.Config.Scene.Debug = false
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('resync in flight')
    -- a live cell misses entries (the server dropped a backlog): it asks for its content and keeps what comes meanwhile
    stream(sub(K8, 10), cell(K8, 0, 10, 1), put(1201, 1, 10))
    local c8 = cache.cell(0, K8)
    eq(c8.state, 2, 'a live cell')
    tick(2100)
    local rsA = #sent('core:scene:resync')
    stream(cell(K8, 14, 15, 1), put(1202, 1, 15))
    tick(0)
    eq(#sent('core:scene:resync'), rsA + 1, 'a gap asks for the content')
    check(c8.awaiting == true, 'the cell awaits the answer')
    stream(cell(K8, 15, 16, 1), put(1203, 1, 16))
    eq(cache.node(1203), nil, 'entries after the gap wait while the answer is in flight')
    local answerAt = Clock.now()
    latent(answerAt, cell(K8, 0, 15, 2), put(1201, 1, 10), put(1202, 1, 15))
    eq(c8.v, 16, 'the answer (a pack) and the kept entry bring the cell up to date')
    check(cache.node(1202) ~= nil and cache.node(1203) ~= nil, 'both nodes are there')
    eq(c8.awaiting, nil, 'no longer awaiting')
    eq(#sent('core:scene:resync'), rsA + 1, 'without a second request')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('protocol errors')
    clearLog()
    stream(put(1301, 1, 5))
    eq(cache.node(1301), nil, 'a PUT outside any CELL / PRIV section is ignored')
    stream(Codec.priv(1), put(1302, 1, 5, { flags = 32 }))
    eq(cache.node(1302).gated, true, 'a PRIV node is gated')
    stream(cell(K8, 16, 17, 1), put(1302, 1, 6), Codec.priv(1), Codec.del(1302, 6, 0))
    local pub = cache.node(1302)
    check(pub ~= nil and pub.gated == false, 'a gated node that became public (PRIV DEL + cell PUT) stays, ungated')
    eq(count('remove', 1302), 0, 'without losing its entity')
    stubs.triggerOn(env, 'core:scene:s', 65535, Codec.header(Clock.now()) .. string.char(0x7F, 1, 2, 3))
    eq(cache.node(1302) ~= nil, true, 'an unknown op stops the payload, nothing breaks')
    stream(cell(K8, 17, 18, 1), put(1303, 9, 18))
    local u = cache.node(1303)
    eq(cache.wanted(u), false, 'a node of an undefined kind is unwanted')
    u.m = { st = 0 }                                  -- the materialiser took it in on its own (a warmed child)
    clearLog()
    stream(cell(K8, 18, 19, 1), Codec.del(1303, 19, 0))
    eq(count('remove', 1303), 1, 'the materialiser hears its removal all the same')
end


-----------------------------------------------------------------------------------------------------------------
do
    suite('held versions (A3b fill)')
    local K9 = key(8, 0)
    local function lastHeld()
        C.focus.reportSoon()
        tick(400)
        local fr = sent('core:scene:focus')
        return fr[#fr][8]
    end
    stream(sub(K9, 20), cell(K9, 0, 20, 2), put(1401, 1, 20, { x = 1100.0 }), put(1402, 1, 20, { x = 1110.0 }))
    local c9 = cache.cell(0, K9)
    eq(c9.state, 2, 'a live cell at v20')
    stream(Codec.unsub(0, K9))
    eq(c9.state, 3, 'UNSUB: kept in the LRU at v20')
    eq(lastHeld()[('0:%d:1'):format(K9)], 20, 'the next focus report lists it as held at v20')
    -- the return: A3b's fill sends only SUB(v) when the held version is current (no pack, no journal)
    local rs0 = #sent('core:scene:resync')
    clearLog()
    stream(sub(K9, 20))
    eq(c9.state, 2, 'SUB at the held version: live at once')
    eq(count('add', 1401) + count('add', 1402), 2, 'its nodes are wanted again at once')
    tick(16000)
    eq(#sent('core:scene:resync'), rs0, 'nothing is asked for, not even after 15 s (no pack is coming)')
    stream(cell(K9, 20, 21, 1), Codec.set(1401, 21, Codec.pack({ f = { lit = true } })))
    eq(c9.v, 21, 'the next journal entry chains on the held version')

    -- a mismatch: the cell changed while away -> SUB(v) + the journal from the held version
    stream(Codec.unsub(0, K9))
    clearLog()
    stream(sub(K9, 23))
    eq(c9.state, 1, 'SUB above the held version: pending')
    eq(count('add', 1401), 1, 'the held content shows meanwhile')
    stream(cell(K9, 21, 22, 1), Codec.move(1401, 22, 1101.0, 0.0, 30.0, 0.0, 0.0, 0.0),
        cell(K9, 22, 23, 1), put(1403, 1, 23, { x = 1120.0 }))
    eq(c9.state, 2, 'the journal from the held version makes it live')
    eq(c9.v, 23, 'at the announced version')
    check(cache.node(1403) ~= nil, 'with the node that came meanwhile')
    eq(#sent('core:scene:resync'), rs0, 'no resync for any of it')

    -- a mismatch the journal no longer covers: SUB(v) + a pack
    stream(Codec.unsub(0, K9))
    local subAt = Clock.now()
    stream(sub(K9, 30))
    eq(c9.state, 1, 'pending until the pack')
    tick(100)
    eq(c9.state, 1, 'still pending while the latent pack travels')
    latent(subAt, cell(K9, 0, 30, 2), put(1401, 1, 30), put(1403, 1, 30))
    eq(c9.state, 2, 'live once the pack landed')
    eq(cache.node(1402), nil, 'the pack replaced the content')

    -- a ring change and back while the old variant's content is still cached
    clearLog()
    stream(Codec.unsub(0, K9), sub(K9, 88, 0, 2))
    eq(c9.state, 1, 'near -> far: the far variant is pending')
    eq(count('remove', 1401), 0, 'the near content stays meanwhile')
    stream(Codec.unsub(0, K9), sub(K9, 30, 0, 1))
    eq(c9.state, 2, 'back to near at the version it still holds: live at once')
    eq(c9.variant, 1, 'subscribed to near again')
    latent(Clock.now(), cell(K9, 0, 88, 1, 0, 2), put(1499, 1, 88))
    eq(cache.node(1499), nil, "the far pack arriving late is the other variant's: ignored")
    stream(cell(K9, 0, 30, 2), put(1401, 1, 30), put(1403, 1, 30))
    eq(count('remove') + count('add'), 0, 'a near pack at the version it holds is old news (no churn)')
    stream(cell(K9, 30, 31, 1), Codec.set(1401, 31, Codec.pack({ f = { lit = false } })))
    eq(c9.v, 31, 'the near journal chains on')

    -- a SUB older than the content it holds (same variant): live; the journal from it is old news
    stream(Codec.unsub(0, K9))
    local stale0 = cache.stats().stale
    stream(sub(K9, 29))
    eq(c9.state, 2, 'a SUB older than the content held: live at once')
    stream(cell(K9, 29, 30, 1), Codec.set(1401, 30, Codec.pack({ f = { n = 0 } })),
        cell(K9, 30, 31, 1), Codec.set(1401, 31, Codec.pack({ f = { n = 1 } })))
    eq(cache.stats().stale, stale0 + 2, 'the journal up to the content it holds is old news')
    eq(cache.node(1401).fields.n, nil, 'and changes nothing')
    stream(cell(K9, 31, 32, 1), Codec.set(1401, 32, Codec.pack({ f = { n = 2 } })))
    eq(c9.v, 32, 'the entry after it applies')
    eq(cache.node(1401).fields.n, 2, 'with its change')
    eq(#sent('core:scene:resync'), rs0, 'still no resync')

    -- a far subscription pending over near content: a re-ask names the far variant with v 0
    stream(Codec.unsub(0, K9), sub(K9, 90, 0, 2))
    tick(16000)
    local rs = sent('core:scene:resync')
    check(#rs == rs0 + 1 and rs[#rs][2] == K9 and rs[#rs][3] == 2 and rs[#rs][4] == 0,
        'the pending re-ask names the far variant with v 0 (it holds none of it)')
    stream(Codec.unsub(0, K9))
    local held = lastHeld()
    eq(held[('0:%d:1'):format(K9)], 32, "an LRU cell's held key names the variant of its CONTENT (near v32)")
    eq(held[('0:%d:2'):format(K9)], nil, 'not the variant it was last subscribed to')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('RV2 F15 near fields')
    local KA = key(20, 0)
    clearLog()
    stream(sub(KA, 40, 0, 2), cell(KA, 0, 40, 1, 0, 2),
        put(1501, 1, 5, { flags = 8, extra = { f = { model = 'prop_box' } } }))
    eq(cache.node(1501).fields.label, nil, 'the far variant omits the near fields')
    clearLog()
    stream(Codec.unsub(0, KA), sub(KA, 41, 0, 1), cell(KA, 0, 41, 1, 0, 1),
        put(1501, 1, 5, { extra = { f = { model = 'prop_box', label = 'Open crate' } } }))
    eq(cache.node(1501).fields.label, 'Open crate', 'the near snapshot at the same node ver brings them')
    local fu = find('update', 1501, 'fields')
    check(fu ~= nil and fu.data ~= nil and fu.data.label == true, 'as a fields update naming them')
    eq(cache.node(1501).flags & 8, 0, 'the record is the near one now')
    clearLog()
    stream(Codec.unsub(0, KA), sub(KA, 42, 0, 2), cell(KA, 0, 42, 1, 0, 2),
        put(1501, 1, 5, { flags = 8, extra = { f = { model = 'prop_box' } } }))
    eq(cache.node(1501).fields.label, 'Open crate', 'back to the far variant at the same ver: the near fields stay')
    eq(count('update', 1501, 'fields'), 0, 'and nothing is re-applied')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('RV2 F3 subtrees')
    local KB = key(21, 0)
    stream(sub(KB, 5), cell(KB, 0, 5, 3), put(1601, 1, 5, { flags = 64 }), put(1602, 1, 5, { parent = 1601 }),
        put(1603, 1, 5, { parent = 1602 }))
    local r1, r2 = cache.node(1601), cache.node(1602)
    clearLog()
    stream(cell(KB, 5, 6, 1), Codec.del(1601, 6, 2))
    local order = {}
    for _, e in ipairs(log) do if e.op == 'remove' then order[#order + 1] = e.id .. '/' .. e.how end end
    eq(table.concat(order, ','), '1601/2,1602/2,1603/2', 'a removed root reaches the materialiser first, its subtree after it (same how)')
    eq(r2.parent, 1601, 'a child keeps its parent id')
    eq(r1.children[1], 1602, 'the root keeps its children list')
    stream(cell(KB, 6, 7, 3), put(1611, 1, 7, { flags = 64 }), put(1612, 1, 7, { parent = 1611 }),
        put(1613, 1, 7, { parent = 1612 }))
    for round = 1, 3 do                                      -- pairs() order must not matter: every bulk drop
        clearLog()
        if round == 1 then
            stream(cell(KB, 0, 8, 0))                        -- an empty snapshot
        elseif round == 2 then
            cache.reset()                                    -- a dropped cell (a real bucket change)
        else
            stream(sub(KB, 0))                               -- SUB of an empty cell
        end
        order = {}
        for _, e in ipairs(log) do
            if e.op == 'remove' and e.id >= 1611 and e.id <= 1613 then order[#order + 1] = e.id end
        end
        eq(table.concat(order, ','), '1611,1612,1613', 'bulk drop ' .. round .. ': root first, then its subtree')
        if round < 3 then
            stream(sub(KB, 9 + round), cell(KB, 0, 9 + round, 3), put(1611, 1, 7, { flags = 64 }),
                put(1612, 1, 7, { parent = 1611 }), put(1613, 1, 7, { parent = 1612 }))
        end
    end
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('RV2 F6 pack before its SUB')
    local KC = key(22, 0)
    local now0 = Clock.now()
    local rsC = #sent('core:scene:resync')
    clearLog()
    latent(now0, cell(KC, 0, 9, 1), put(1701, 1, 9))
    eq(cache.cell(0, KC), nil, 'no cell yet: its SUB has not come')
    eq(cache.stats().parkedNow, 1, 'the pack is parked')
    stream(sub(KC, 9))
    local cc = cache.cell(0, KC)
    eq(cc.state, 2, 'the SUB finds its pack: live at once')
    check(cache.node(1701) ~= nil and count('add', 1701) == 1, 'with its content')
    eq(cache.stats().parkedNow, 0, 'the parked pack is used up')
    tick(16000)
    eq(#sent('core:scene:resync'), rsC, 'nothing is asked for (no 15 s wait)')
    latent(Clock.now(), cell(key(23, 0), 0, 3, 1), put(1702, 1, 3))
    eq(cache.stats().parkedNow, 1, 'a pack whose SUB never comes is parked ...')
    tick(4000)
    eq(cache.stats().parkedNow, 0, '... and dropped after 3 s')
    local KO = key(24, 0)
    latent(Clock.add(Clock.now(), -2000), cell(KO, 0, 4, 1), put(1703, 1, 4))
    stream(sub(KO, 4))
    eq(cache.node(1703), nil, 'a parked pack stamped well before its SUB (an older subscription) is not used')
    eq(cache.cell(0, KO).state, 1, 'the cell waits for its own pack')
    local KR = key(25, 0)                                   -- a ring change: the far pack before the far SUB
    stream(sub(KR, 7), cell(KR, 0, 7, 1), put(1704, 1, 7))
    local farNow = Clock.now()
    latent(farNow, cell(KR, 0, 77, 1, 0, 2), put(1704, 1, 8))
    eq(cache.stats().parkedNow, 1, 'a pack of the other variant (its SUB still to come) is parked too')
    stream(Codec.unsub(0, KR), sub(KR, 77, 0, 2))
    eq(cache.cell(0, KR).state, 2, 'and applied with the ring change')
    eq(cache.cell(0, KR).cv, 2, 'the content is the far variant now')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('RV2 F8 foreign entities')
    stubs.resourceStates.lamps = 'started'
    local lenv = stubs.newEnv('client', 'lamps')
    lenv.Wait = env.Wait
    stubs.loadImport(lenv)
    local vms = { env, lenv }
    local function broadcast(name, ...)
        local args = table.pack(...)
        for _, e in ipairs(vms) do
            local list = e.__vm.handlers[name]
            if list then
                for _, rec in ipairs({ table.unpack(list) }) do
                    e.CreateThread(function() rec.fn(table.unpack(args, 1, args.n)) end)
                end
            end
        end
    end
    local savedTE = env.TriggerEvent
    env.TriggerEvent, lenv.TriggerEvent = broadcast, broadcast
    stream(Codec.kinds({ { idx = 30, id = 'lamps:post', class = 7, meta = { handler = 'lamps' } } }))
    local KD = key(26, 0)
    stream(sub(KD, 5), cell(KD, 0, 5, 1), put(1801, 30, 5))
    local playerPed = stubs.newEntity(1, { player = true })
    local netVeh = stubs.newEntity(2, { networked = true })
    local own = stubs.newEntity(3, {})
    local ret, destroyedL, updatedE = playerPed, {}, {}
    lenv.Core.Scene.handle('lamps:post', {
        create = function() return ret end,
        update = function(_, e) updatedE[#updatedE + 1] = e or 0 end,
        destroy = function(_, e) destroyedL[#destroyedL + 1] = e or 0 end,
    })
    local bridge = handlers.custom
    local ln = cache.node(1801)
    eq(bridge.create(ln, {}), true, "a player's ped is refused: the node counts as created without an entity")
    eq(Scene.handleOf(1801), nil, 'core does not take it')
    bridge.update(ln, true, 'fields', {})
    eq(updatedE[#updatedE], 0, 'the plugin gets no entity back in its update')
    bridge.destroy(ln, nil)
    ret = netVeh
    eq(bridge.create(ln, {}), true, 'a networked entity is refused')
    bridge.destroy(ln, nil)
    ids[own] = 999                                        -- the materialiser already owns it (another node's)
    ret = own
    eq(bridge.create(ln, {}), true, 'an entity core already owns is refused')
    ids[own] = nil
    bridge.destroy(ln, nil)
    local bad = false
    for _, e in ipairs(destroyedL) do if e == playerPed or e == netVeh or e == own then bad = true end end
    check(not bad, 'and the plugin is never told to delete an entity core refused')
    eq(bridge.create(ln, {}), own, "the plugin's own local entity is taken")
    local warned = false
    for _, line in ipairs(stubs.printed) do
        if line:find('bound a player entity', 1, true) then warned = true end
    end
    check(warned, 'a refusal is logged (once per kind and reason)')
    bridge.destroy(ln, own)
    env.TriggerEvent = savedTE
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('RV2 F9 DR is no change')
    local KD = key(27, 0)
    stream(sub(KD, 5), cell(KD, 0, 5, 1), put(1851, 1, 5))
    local changedN, evs = 0, 0
    local hc = Scene.on('changed', '*', function() changedN = changedN + 1 end)
    local savedTE = env.TriggerEvent
    env.TriggerEvent = function(name, ...)
        if name == 'core:scene:ev' then evs = evs + 1 end
        return savedTE(name, ...)
    end
    Scene.listen('*', 'changed')                           -- a plugin VM listening to every change (the lib's path)
    clearLog()
    local t = Clock.now()
    for i = 1, 20 do
        t = Clock.add(t, 100)
        stream(Codec.dr(1851, t, 10.0 + i * 0.5, 10.0, 30.0, 5.0, 0.0, 0.0, 90.0))
    end
    eq(count('update', 1851, 'dr'), 20, 'the materialiser still hears every DR sample')
    eq(changedN, 0, "no 'changed' for a core listener")
    eq(evs, 0, 'and no core:scene:ev for a plugin listening to every change')
    stream(cell(KD, 5, 6, 1), Codec.set(1851, 6, Codec.pack({ f = { lit = true } })))
    eq(changedN, 1, 'a real change still is one')
    eq(evs, 1, 'for plugins too')
    Scene.off(hc)
    Scene.unlisten('*', 'changed')
    env.TriggerEvent = savedTE
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('RV2 F10 second gap')
    local KE = key(28, 0)
    stream(sub(KE, 10), cell(KE, 0, 10, 1), put(1901, 1, 10))
    local ce = cache.cell(0, KE)
    tick(2100)
    local r0 = #sent('core:scene:resync')
    stream(cell(KE, 12, 13, 1), put(1902, 1, 13))                 -- gap 1 (10 -> 12 missing)
    tick(200)
    eq(#sent('core:scene:resync'), r0 + 1, 'gap 1 asks')
    stream(cell(KE, 10, 13, 1), put(1902, 1, 13))                 -- the answer: 10 -> 13
    eq(ce.v, 13, 'answered')
    eq(ce.awaiting, nil, 'nothing awaited any more')
    tick(700)
    stream(cell(KE, 15, 16, 1), Codec.del(1901, 16, 0))           -- gap 2 (13 -> 15 missing), 0.9 s later
    tick(300)
    eq(#sent('core:scene:resync'), r0 + 1, 'within 2 s of the last request it waits ...')
    eq(ce.awaiting, true, '... remembering that it misses content')
    check(cache.node(1901) ~= nil, 'the entry after the gap is kept, not applied')
    tick(1200)
    local rs = sent('core:scene:resync')
    eq(#rs, r0 + 2, '... and asks once the 2 s are over: the need is deferred, never dropped')
    eq(rs[#rs][4], 13, 'from the version it holds')
    stream(cell(KE, 13, 15, 0))                                   -- the answer: 13 -> 15
    eq(ce.v, 16, 'the kept entry (15 -> 16) chains on the answer')
    eq(cache.node(1901), nil, 'with its DEL')
    tick(3000)
    eq(#sent('core:scene:resync'), r0 + 2, 'nothing more is asked once the content is complete')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('RV2 F14 stream RESET')
    local KG, KH = key(29, 0), key(30, 0)
    stream(sub(KG, 100), cell(KG, 0, 100, 3), put(2001, 1, 100, { flags = 64 }), put(2002, 1, 100, { parent = 2001 }),
        put(2003, 1, 100))
    stream(sub(KH, 50), cell(KH, 0, 50, 1), put(2004, 1, 50))
    stream(Codec.unsub(0, KH))                                    -- an LRU cell of the old bucket
    latent(Clock.now(), cell(key(31, 0), 0, 7, 1), put(2005, 1, 7))   -- a parked pack of the old bucket
    check(cache.stats().lru >= 1 and cache.stats().parkedNow >= 1, 'old-bucket content: live, LRU and a parked pack')
    tick(400)
    local rep0 = #sent('core:scene:focus')
    local resets0 = C.focus.stats().streamResets
    clearLog()
    -- the server moved the player without telling the client (RV2 demo): RESET, then the new bucket's content
    stream(Codec.reset(Codec.RESET.BUCKET), sub(KG, 60), cell(KG, 0, 60, 1), put(2101, 1, 60))
    check(cache.node(2001) == nil and cache.node(2002) == nil and cache.node(2003) == nil, "the old bucket's nodes are gone")
    local order = {}
    for _, e in ipairs(log) do
        if e.op == 'remove' and (e.id == 2001 or e.id == 2002) then order[#order + 1] = e.id end
    end
    eq(table.concat(order, ','), '2001,2002', 'a subtree leaves root first')
    local hows = {}
    for _, e in ipairs(log) do
        if e.op == 'remove' and (e.id == 2001 or e.id == 2002 or e.id == 2003) then hows[#hows + 1] = e.how end
    end
    eq(table.concat(hows, ','), '3,3,3', "RV6 F3: RESET(BUCKET) is a new world: how 3 ('world')")
    eq(cache.node(2004), nil, 'the LRU content goes too (its versions are the old bucket)')
    eq(cache.stats().lru, 0, 'the LRU is empty')
    eq(cache.stats().parkedNow, 0, 'parked packs go')
    local cg = cache.cell(0, KG)
    check(cg ~= nil and cg.state == 2 and cg.v == 60, "the new bucket's content after the RESET applies (v60 < the old v100)")
    check(cache.node(2101) ~= nil and count('add', 2101) == 1, 'with its node')
    eq(C.focus.stats().streamResets, resets0 + 1, 'the focus reporter heard it')
    eq(C.focus.stats().lastResetReason, Codec.RESET.BUCKET, 'with its reason')
    tick(300)
    check(#sent('core:scene:focus') > rep0, 'and a focus report goes out at once')
    clearLog()
    stream(Codec.reset(Codec.RESET.EPOCH))
    eq(select(2, cache.count()), 0, 'a RESET for a server restart (epoch) drops everything as well')
    local epochHow = {}
    for _, e in ipairs(log) do
        if e.op == 'remove' then epochHow[e.how] = true end
        if e.op == 'worldReset' then epochHow.world = true end
    end
    check(epochHow[0] and not epochHow[3] and not epochHow.world,
        '... visibility-safely (how 0): the same world, only the stream restarted')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('RV2 F17 big packs')
    local KF = key(32, 0)
    local N = 700
    local ops = {}
    for i = 1, N do ops[i] = put(3000 + i, 1, 9, { x = 4096.0 + i * 0.1 }) end
    local blob = table.concat(ops)
    check(#blob > 16384, 'a pack above 16 KiB (' .. #blob .. ' bytes)')
    stream(sub(KF, 9))
    local subNow = Clock.now()
    clearLog()
    local chunks0 = cache.stats().chunks
    latent(subNow, cell(KF, 0, 9, N), blob)
    local first = count('add')
    check(first > 0 and first <= 256, 'the first frame hands at most 256 nodes to the materialiser (' .. first .. ')')
    stream(cell(KF, 9, 10, 1), Codec.set(3001, 10, Codec.pack({ f = { lit = true } })))
    eq(cache.node(3001) and cache.node(3001).fields.lit, nil, 'a payload arriving meanwhile waits behind it (stream order)')
    local worst = first
    for _ = 1, 8 do
        local b = count('add')
        tick(16)
        if count('add') - b > worst then worst = count('add') - b end
    end
    check(worst <= 256, 'no frame hands more than 256 (' .. worst .. ')')
    eq(count('add'), N, 'every node arrives within a few frames')
    check(cache.stats().chunks - chunks0 >= 2, 'in several chunks')
    eq(cache.node(3001).fields.lit, true, 'then the waiting payload applies, in order')
    local cf = cache.cell(0, KF)
    check(cf.state == 2 and cf.v == 10, 'the cell is live at v10')
    eq(cache.stats().queuedPayloads, 0, 'nothing is left queued')
    -- a DEL(handover) and its PUT in two chunks of one big payload: the entity stays
    local KF2 = key(33, 0)
    stream(sub(KF2, 3), cell(KF2, 0, 3, 0))
    local filler = {}
    for i = 1, 400 do filler[i] = put(3800 + i, 1, 11, { x = 4100.0 + i * 0.1 }) end
    clearLog()
    latent(Clock.now(), cell(KF, 10, 11, 401), Codec.del(3001, 12, 1), table.concat(filler),
        cell(KF2, 3, 4, 1), put(3001, 1, 12, { x = 4250.0 }))
    tick(200)
    eq(count('remove', 3001), 0, 'a handover split over two chunks keeps its entity')
    eq(cache.node(3001).cellRef, cache.cell(0, KF2), 'and the node its new cell')
    -- a real bucket change while a big payload is worked through: the reset waits for it (stream order)
    local more = {}
    for i = 1, 600 do more[i] = put(3900 + i, 1, 13, { x = 4200.0 + i * 0.1 }) end
    stubs.triggerOn(env, 'core:client:bucketChanged', 65535, 7)   -- the bucket is known (7): seed
    latent(Clock.now(), cell(KF, 11, 13, 600), table.concat(more))
    stubs.triggerOn(env, 'core:client:bucketChanged', 65535, 8)   -- a real change while it is in work
    check(select(2, cache.count()) > 0, 'the reset waits behind the payload being worked through')
    tick(300)
    eq(select(2, cache.count()), 0, 'then everything is dropped, the late nodes included')
    eq(cache.stats().queuedPayloads, 0, 'the queue is empty')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('promotion clones and paints')
    local KP = key(34, 0)
    stream(sub(KP, 5), cell(KP, 0, 5, 1), put(4001, 1, 5))
    local clone = stubs.newEntity(2, { networked = true })
    handles[4001] = nil
    eq(Scene.handleOf(4001), nil, 'no local entity, no promotion: nil')
    local asked = {}
    C.promote = { cloneOf = function(id)
        asked[#asked + 1] = id
        return id == 4001 and clone or nil
    end }
    eq(Scene.handleOf(4001), clone, 'a promoted node without a local copy answers its networked clone')
    eq(asked[#asked], 4001, 'asked from client/scene_promote.lua at call time')
    handles[4001] = 5555
    eq(Scene.handleOf(4001), 5555, 'the local copy wins while it exists')
    handles[4001] = nil
    eq(Scene.idOf(clone), nil, 'without idOfClone a clone maps to nothing')
    C.promote.idOfClone = function(e) return e == clone and 4001 or nil end
    eq(Scene.idOf(clone), 4001, 'with idOfClone the clone maps back to its node')
    eq(Scene.idOf(123456), nil, 'an unknown entity: nil')
    C.promote = nil
    eq(Scene.handleOf(4001), nil, 'no promote module: nil')

    eq(#Scene.PAINTS, 22, 'Scene.PAINTS holds 22 pairs')
    local p, q = Scene.paintOf(0)
    check(p == 0 and q == 0, 'paintOf(0) = the first pair')
    p, q = Scene.paintOf(21)
    check(p == 145 and q == 145, 'paintOf(21) = the last pair')
    p, q = Scene.paintOf(23)
    check(p == 1 and q == 1, 'paintOf(23) wraps to the second pair')
    eq(Scene.paintOf('x'), nil, 'a non-integer id: nil')
    local src = stubs.readFile(stubs.root .. '/server/scene_promote.lua')
    local lit = src and src:match('local PAINTS <const> = (%b{})')
    if lit then
        -- fxlint-disable-next-line S006 -- a literal cut from a checked-in core file, offline only
        local list = load('return ' .. lit)()
        local same = #list == #Scene.PAINTS
        for i = 1, #list do
            if list[i][1] ~= Scene.PAINTS[i][1] or list[i][2] ~= Scene.PAINTS[i][2] then same = false end
        end
        check(same, "the same list as server/scene_promote.lua's")
    else
        check(src ~= nil, 'server/scene_promote.lua reads the shared list')
    end
    local pv = stubs.newEnv('client', 'garage')
    stubs.loadImport(pv)
    check(rawget(pv.Core.Scene, 'paintOf') ~= nil, 'a plugin VM has paintOf from the lib (no export hop)')
    local a, b = pv.Core.Scene.paintOf(4001)
    local cp, cs = Scene.paintOf(4001)
    check(a == cp and b == cs and a ~= nil, 'and computes the same paint in its own VM')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('RV1 F6 versions across the wrap')
    local MAXV = 4294967295
    local KW = key(35, 0)
    stream(sub(KW, MAXV - 1), cell(KW, 0, MAXV - 1, 1), put(5001, 1, MAXV))
    local cw, n5 = cache.cell(0, KW), cache.node(5001)
    eq(cw.state, 2, 'a cell at the end of the version range is live')
    eq(n5.ver, MAXV, 'a node at ver 4294967295')
    clearLog()
    stream(cell(KW, MAXV - 1, MAXV, 1), Codec.set(5001, 1, Codec.pack({ f = { a = 1 } })))
    eq(n5.fields.a, 1, 'node ver 4294967295 -> 1 is newer (it wraps, never through 0)')
    eq(n5.ver, 1, 'the node is at ver 1')
    eq(cw.v, MAXV, 'the cell at 4294967295')
    clearLog()
    stream(cell(KW, MAXV, 1, 2), Codec.set(5001, MAXV, Codec.pack({ f = { a = 2 } })),
        Codec.move(5001, 2, 1.0, 2.0, 3.0, 0.0, 0.0, 0.0))
    eq(cw.v, 1, 'a journal entry 4294967295 -> 1 chains across the wrap')
    eq(n5.fields.a, 1, 'an op at ver 4294967295 after ver 1 is older: ignored')
    eq(count('update', 5001, 'move'), 1, 'ver 2 after ver 1 applies')
    local stale0, rs0 = cache.stats().stale, #sent('core:scene:resync')
    stream(cell(KW, MAXV - 1, MAXV, 0))
    eq(cache.stats().stale, stale0 + 1, 'an entry from before the wrap is old news, not a gap')
    tick(300)
    eq(#sent('core:scene:resync'), rs0, 'and asks for nothing')
    stream(cell(KW, 3, 4, 0))
    tick(300)
    eq(#sent('core:scene:resync'), rs0 + 1, 'an entry after the wrap that skips versions is a gap')
    stream(cell(KW, 0, 5, 1), put(5001, 1, 3))
    eq(cw.v, 5, 'the answer, a snapshot at v5, replaces content at v1')
    eq(cw.state, 2, 'the cell is live (v5 reached the SUB target 4294967294 across the wrap)')
    eq(n5.ver, 3, 'with the node at ver 3')
    stream(cell(KW, 5, 6, 1), put(5002, 1, MAXV))
    stream(cell(KW, 6, 7, 1), Codec.del(5002, 1, 0))
    eq(cache.node(5002), nil, 'a DEL at ver 1 deletes a node at ver 4294967295 (newer across the wrap)')

    local KW2 = key(36, 0)
    stream(sub(KW2, MAXV), cell(KW2, 0, MAXV, 1), put(5003, 1, 9))
    stream(Codec.unsub(0, KW2))
    stream(sub(KW2, 2))
    local cw2 = cache.cell(0, KW2)
    eq(cw2.state, 1, 'SUB at v2 over held content at 4294967295: pending (v2 is newer across the wrap)')
    stream(cell(KW2, MAXV, 1, 0), cell(KW2, 1, 2, 0))
    eq(cw2.v, 2, 'the journal across the wrap (4294967295 -> 1 -> 2) ...')
    eq(cw2.state, 2, '... makes it live')
    stream(Codec.unsub(0, KW2), sub(KW2, MAXV))
    eq(cw2.state, 2, 'a SUB at 4294967295 over held content at v2 (older across the wrap): live at once')

    local KW3 = key(37, 0)
    latent(Clock.now(), cell(KW3, 0, MAXV, 1), put(5005, 1, MAXV))
    latent(Clock.now(), cell(KW3, 0, 2, 1), put(5005, 1, 2))
    eq(cache.stats().parkedNow, 1, 'two packs of one cell before its SUB: one is parked')
    stream(sub(KW3, 2))
    eq(cache.cell(0, KW3).state, 2, 'the SUB at v2 is served')
    eq(cache.node(5005).ver, 2, 'by the pack from after the wrap (v2 is newer than 4294967295)')
end

-----------------------------------------------------------------------------------------------------------------
do
    suite('I1 map tags and rotOrder')
    -- Core.Maps' mapEl / mapType are ordinary fields (never near-only): a FAR PUT of an M node carries them, and the
    -- materialiser gets the node with them (client/maps.lua reads node.fields.mapEl of every materialised node)
    local KQ = key(40, 0)
    clearLog()
    stream(sub(KQ, 50, 0, 2), cell(KQ, 0, 50, 2, 0, 2),
        put(9601, 1, 3, { flags = 8, extra = { f = { model = 'prop_bench_01a', mapEl = 'dt:12',
            mapType = 'core:prop' } } }),
        put(9602, 1, 3, { flags = 8, extra = { f = { model = 'prop_bench_01a' } } }))
    local nq = cache.node(9601)
    check(nq ~= nil and nq.fields.mapEl == 'dt:12' and nq.fields.mapType == 'core:prop', 'mapEl / mapType in a FAR PUT')
    local added = find('add', 9601)
    check(added ~= nil and added.node.fields.mapEl == 'dt:12', '... the materialiser adds the node with them')
    eq(cache.node(9602).fields.mapEl, nil, 'a node Maps did not make has none')
    -- rotOrder: PUT extra q -> node.rotOrder (0..5); a change of it alone is an 'attach' update
    local KR = key(41, 0)
    local function att(q)
        return { f = { model = 'm' }, a = { p = 5 }, b = 28422, o = { x = 0.1, y = 0.0, z = 0.0 }, q = q }
    end
    clearLog()
    stream(sub(KR, 60), cell(KR, 0, 60, 3), put(9701, 1, 2, { extra = att(1) }), put(9702, 1, 2, { extra = att(nil) }),
        put(9703, 1, 2, { extra = att(0) }))
    eq(cache.node(9701).rotOrder, 1, 'PUT extra q -> node.rotOrder')
    eq(cache.node(9702).rotOrder, nil, 'no q: nil (the engine default 2)')
    eq(cache.node(9703).rotOrder, 0, 'q = 0 is a value')
    clearLog()
    stream(cell(KR, 60, 61, 1), put(9701, 1, 3, { extra = att(4) }))
    eq(cache.node(9701).rotOrder, 4, 'a new q is taken')
    eq(count('update', 9701, 'attach'), 1, "... as an 'attach' update (the entity is attached again)")
    eq(count('update', 9701), 1, '... and nothing else')
    clearLog()
    stream(cell(KR, 61, 62, 1), put(9701, 1, 4, { extra = att(nil) }))
    eq(cache.node(9701).rotOrder, nil, 'q gone: the default again')
    eq(count('update', 9701, 'attach'), 1, "... an 'attach' update too")
    clearLog()
    stream(cell(KR, 62, 63, 1), put(9701, 1, 5, { extra = att(9) }))
    eq(cache.node(9701).rotOrder, nil, 'q outside 0..5 is ignored')
    eq(count('update', 9701), 0, '... and is no change')
end

-----------------------------------------------------------------------------------------------------------------
if #stubs.failures > 0 then
    for _, f in ipairs(stubs.failures) do print('thread/handler error: ' .. f) end
    failed = failed + #stubs.failures
end
print(('client scene cache: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
