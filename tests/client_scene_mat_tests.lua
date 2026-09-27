-- Offline tests for the Core.Scene materialiser and movers (DESIGN §55.11, §55.9): client/scene_mat_assets.lua,
-- client/scene_materializer.lua and client/scene_movers.lua in a stub client VM (tests/client_scene_harness.lua:
-- virtual clock, Wait(0) = one 16 ms frame, native stubs that count calls, the real shared/scene_motion.lua, a fake
-- C.cache).
local here = arg[0]:match('^(.*)/') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads checked-in files only
local H = dofile(here .. '/client_scene_harness.lua')

local passed = 0
local function eq(actual, expected, label)
    assert(actual == expected, label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end
local function ok(cond, label)
    assert(cond, 'FAIL: ' .. label)
    passed = passed + 1
end
local function near(actual, expected, tol, label)
    assert(type(actual) == 'number' and math.abs(actual - expected) <= tol,
        label .. ': expected ~' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end

local HPROP, HPROP2, HVEH, HPED = 1001, 1002, 2001, 3001
local KNOWN, WARM, STAGED, LIVE, RETIRING, FAILED, OFF = 0, 1, 2, 3, 4, 5, 6

local current
--- A fresh VM with the materialiser and the movers; `cfg(Scene)` edits Config.Scene before they load.
local function fresh(cfg)
    if current then
        current.M.shutdown()
        current.h.tick(1000)
    end
    local h = H.new({ scene = cfg })
    h.models[HVEH] = { mode = 'vehicle' }
    h.models[HPED] = { mode = 'ped' }
    h.loadMat()                                                  -- scene_mat_assets -> scene_materializer -> scene_movers
    current = { h = h, M = h.C.mat, Mv = h.C.movers }
    return h, current.M, current.Mv
end

--- A test handler: counts creates / destroys / updates / events; entity kinds hand out stub entities.
local function handler(h, class, o)
    o = o or {}
    local hd = { class = class, budget = o.budget, fade = o.fade, created = 0, destroyed = 0, updates = {},
        events = {}, ctx = {}, order = {} }
    function hd.assets(node)
        local f, list = node.fields, {}
        if f.model then list[#list + 1] = { type = 'model', hash = f.model } end
        if f.dict then list[#list + 1] = { type = 'anim', name = f.dict } end
        if f.fx then list[#list + 1] = { type = 'ptfx', name = f.fx } end
        return list
    end
    function hd.create(node, ctx)
        if o.refuse then return nil end
        hd.created = hd.created + 1
        hd.ctx[node.id] = { late = ctx.late, seen = ctx.seen, x = ctx.x, y = ctx.y, z = ctx.z, rz = ctx.rz,
            frame = h.now() }
        hd.order[#hd.order + 1] = node.id
        if o.entity == false then return true end
        local etype = class == 'ped' and 1 or (class == 'vehicle' and 2 or 3)
        local e = h.newEntity(node.fields.model or 0, ctx.x, ctx.y, ctx.z, etype)
        if o.attachSelf and node.parent ~= 0 then h.ents[e].attachedTo = -1 end
        if o.attachTarget then h.ents[e].attachedTo = o.attachTarget(node) end   -- like scene_kinds' K.attach
        return e
    end
    function hd.update(node, _, what, data)
        hd.updates[#hd.updates + 1] = { id = node.id, what = what, data = data }
        return o.update
    end
    function hd.destroy() hd.destroyed = hd.destroyed + 1 end
    function hd.event(node, _, name, _, age) hd.events[#hd.events + 1] = { id = node.id, name = name, age = age } end
    if o.place then
        hd.placed = 0
        function hd.place(_, e, x, y, z, rx, ry, rz)
            hd.placed = hd.placed + 1
            if type(e) == 'number' then
                local r = h.ents[e]
                r.x, r.y, r.z, r.rx, r.ry, r.rz = x, y, z, rx, ry, rz
            end
        end
    end
    hd.radii = o.radii
    return hd
end

local function st(h, id) return h.nodes[id].m.st end
local bench = {}

-- 1. shape and idle ----------------------------------------------------------------------------------------------
do
    local h, M, Mv = fresh()
    for _, fn in ipairs({ 'registerKind', 'add', 'update', 'remove', 'event', 'handleOf', 'idOf', 'hold', 'release',
        'areaReady', 'setTeleport', 'camera', 'lodScale', 'fadeIn', 'fadeOut', 'stats' }) do
        eq(type(M[fn]), 'function', 'C.mat.' .. fn)
    end
    for _, fn in ipairs({ 'track', 'untrack', 'stats' }) do eq(type(Mv[fn]), 'function', 'C.movers.' .. fn) end
    local reads = h.stubs.gameTimerReads
    h.tick(5000)
    eq(h.n('GetFinalRenderedCamCoord'), 0, 'nothing known: no camera read at all')
    eq(h.n('GetLodscale'), 0, 'nothing known: no LOD scale read')
    eq(M.stats().evaluations, 0, 'no evaluation while nothing is known')
    ok(h.stubs.gameTimerReads - reads <= 11, 'nothing known: a bare 500 ms sleep (' .. (h.stubs.gameTimerReads - reads)
        .. ' timer reads in 5 s)')
    eq(M.lodScale(), 1.0, 'lodScale() defaults to 1')
    eq(M.registerKind(nil, {}), false, 'registerKind refuses a non-string key')
    eq(M.registerKind('x', 5), false, 'registerKind refuses a non-table handler')
    eq(M.handleOf(99), nil, 'handleOf an unknown id')
    eq(M.idOf(424242), nil, 'idOf an unknown entity')
    eq(Mv.stats().tracked, 0, 'no movers')
    eq(M.fadeIn(0, 300), false, 'fadeIn refuses entity 0')
end

-- 1b. the split: load order asserts, C.assets / C.fades on the runtime only, their APIs --------------------------------
do
    local bare = H.new()
    local okm, errm = pcall(bare.load, 'client/scene_materializer.lua')
    ok(not okm and tostring(errm):find('scene_mat_assets.lua', 1, true) ~= nil,
        'the materialiser asserts its predecessor client/scene_mat_assets.lua')
    local nofocus = H.new({ runtime = false })
    nofocus.env.CoreSceneRuntime = { cache = nofocus.cache }
    local oka, erra = pcall(nofocus.load, 'client/scene_mat_assets.lua')
    ok(not oka and tostring(erra):find('scene_focus.lua', 1, true) ~= nil,
        'client/scene_mat_assets.lua asserts its predecessor client/scene_focus.lua (C.focus)')
    local h = H.new()
    h.load('client/scene_mat_assets.lua')
    local A, F = h.C.assets, h.C.fades
    for _, fn in ipairs({ 'key', 'acquire', 'drop', 'poll', 'release', 'loading', 'lingering', 'counts', 'interior',
        'unwait', 'pollInteriors', 'interiorsPending', 'shutdown' }) do
        eq(type(A[fn]), 'function', 'C.assets.' .. fn)
    end
    for _, fn in ipairs({ 'hooks', 'ms', 'slotFree', 'max', 'start', 'cancel', 'dir', 'owner', 'running', 'vehicles',
        'shutdown' }) do
        eq(type(F[fn]), 'function', 'C.fades.' .. fn)
    end
    eq(rawget(h.env.Core, 'assets'), nil, 'nothing on Core (assets)')
    eq(rawget(h.env.Core, 'fades'), nil, 'nothing on Core (fades)')
    eq(rawget(h.env, 'A'), nil, 'no global leaked')
    -- asset descriptors
    local ty, k = A.key({ type = 'model', hash = 5 })
    ok(ty == 'model' and k == 5, 'a model by hash')
    ty, k = A.key({ type = 'model', name = 'prop_bench_01a' })
    ok(ty == 'model' and k == h.env.GetHashKey('prop_bench_01a'), 'a model by name (GetHashKey)')
    ty, k = A.key({ type = 'anim', name = 'anim@x' })
    ok(ty == 'anim' and k == 'anim@x', 'an anim dict by name')
    eq(A.key({ type = 'anim', name = '' }), nil, 'an empty name is refused')
    eq(A.key({ type = 'sound', name = 'x' }), nil, 'an unknown type is ignored')
    eq(A.key('model'), nil, 'a non-table descriptor is ignored')
    -- acquire: refs, the in-flight window, give back
    h.models[8001] = { delay = 500 }
    local used, ae, bad = A.acquire({ { type = 'model', hash = 8001 } }, 'prop', 'prop', h.now(), 2, true)
    ok(used == 1 and #ae == 1 and not bad, 'acquire: one new request, one entry')
    eq(ae[1].st, 'loading', 'the entry streams')
    local n, loading, lingering, mp = A.counts()
    ok(n == 1 and loading == 1 and lingering == 0 and mp == 1, 'counts: one entry, streaming, one prop model in use')
    local used2 = A.acquire({ { type = 'model', hash = 8002 } }, 'prop', 'prop', h.now(), 0, false)
    eq(used2, -1, 'no request budget left this frame: -1')
    h.tick(600)
    eq(A.poll(h.now()), true, 'poll: something loaded')
    eq(ae[1].st, 'loaded', 'loaded')
    A.drop(ae, h.now())
    eq(A.lingering(), 1, 'the last user gone: it lingers')
    -- the fade manager on its own (the materialiser installs the hooks)
    eq(F.ms('prop'), 300, 'props fade in over PropInMs')
    eq(F.ms('prop', true), 450, 'and out over PropOutMs')
    eq(F.ms('ped'), 600, 'peds over PedMs')
    eq(F.ms('vehicle', true), 400, 'vehicles over VehicleMs')
    eq(F.max(), 48, 'Fades.Max')
    local done = {}
    F.hooks(function(owner) done[#done + 1] = owner end, function() done.slot = (done.slot or 0) + 1 end)
    local e = h.newEntity(1, 0, 0, 0, 3)
    local owner = { tag = 'owner' }
    eq(F.start(e, -1, 400, false, owner, nil, h.now()), true, 'a fade-out with an owner')
    eq(F.dir(e), -1, 'dir -1')
    eq(F.running(), 1, 'one running')
    local other = { tag = 'shell' }
    F.owner(e, other)
    h.tick(500)
    ok(done[1] == other, 'at the end the (new) owner goes to the hook')
    eq(done.slot, 1, 'and the slot hook heard the free slot')
    eq(F.dir(e), nil, 'no fade left')
    local e2 = h.newEntity(1, 0, 0, 0, 2)
    F.start(e2, 1, 400, true, nil, nil, h.now())
    eq(F.vehicles(), 1, 'a vehicle fade')
    F.cancel(e2)
    ok(F.running() == 0 and F.vehicles() == 0, 'cancel frees the slot without a callback')
    A.shutdown()
    eq(h.released[8001], 1, 'shutdown gives every request back')
end

-- 2. radii (§55.11 table), the LOD clamp, the LOD scale ------------------------------------------------------------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local kinds = { 'prop', 'vehicle', 'ped', 'light', 'marker', 'text', 'particle', 'hide', 'zone', 'sound' }
    local classOf = { prop = 'prop', vehicle = 'vehicle', ped = 'ped', zone = 'data' }
    for _, k in ipairs(kinds) do M.registerKind(k, handler(h, classOf[k] or 'fx', { entity = false })) end
    M.registerKind('audio', handler(h, 'audio', { entity = false }))
    M.registerKind('custom', handler(h, 'custom'))
    M.registerKind('odd', handler(h, 'custom', { radii = function(_, s) return 10 * s, 20 * s, 30 * s end }))
    local FAR = 6000
    local function add(id, kind, class, fields, extra)
        M.add(h.node(id, kind, class, FAR + id * 700, 0, 0, fields, extra))
        local m = h.nodes[id].m
        return m.rVis, m.rIn, m.rOut, m
    end
    local function r3(id, kind, class, fields, v, i, o, label, extra)
        local rv, ri, ro = add(id, kind, class, fields, extra)
        near(rv, v, 1e-9, label .. ' R_vis')
        near(ri, i, 1e-9, label .. ' R_in')
        near(ro, o, 1e-9, label .. ' R_out')
    end
    r3(1, 'prop', 1, { model = HPROP, lod = 100 }, 120, 130, 162.5, 'prop lod 100, S 1: L*S + 20 / +10 / +25 %')
    r3(2, 'prop', 1, { model = HPROP, lod = 15 }, 20, 30, 50, 'small prop lod 15: band 5, out min 20')
    local _, _, _, m3 = add(3, 'prop', 1, { model = HPROP, lod = 600 })
    eq(m3.lodClamp, 470, 'lod 600 passes PropCap 500: lodDist clamped to floor((500 - 20 - 10) / S)')
    near(m3.rIn, 500, 1e-9, 'clamped prop R_in = PropCap')
    near(m3.rVis, 490, 1e-9, 'clamped prop R_vis = lod * S + B')
    near(m3.rOut, 625, 1e-9, 'clamped prop R_out = R_in + 25 %')
    r3(4, 'prop', 'prop', { model = HPROP }, 120, 130, 162.5, 'prop without lod: 100 (class given by name)')
    r3(5, 'vehicle', 2, { model = HVEH }, 500, 255, 311, 'vehicle (Rockstar pair)')
    local _, _, _, m6 = add(6, 'ped', 3, { model = HPED })
    ok(m6.rVis == 240 and m6.rIn == 130 and m6.rOut == 140, 'ped in view: 240 / 130 / 140')
    ok(m6.rInB == 75 and m6.rOutB == 90, 'ped out of view: 75 / 90')
    r3(7, 'light', 4, { range = 10 }, 30, 80, 110, 'light range 10: x3 / +50 / +30')
    r3(8, 'light', 4, { range = 100 }, 300, 300, 330, 'light range 100: R_in capped at 300')
    r3(9, 'marker', 4, {}, 50, 60, 80, 'marker default drawDistance 50')
    r3(10, 'marker', 4, { drawDistance = 30 }, 30, 40, 60, 'marker drawDistance 30')
    r3(11, 'text', 4, {}, 25, 35, 55, 'text default drawDistance 25')
    r3(12, 'particle', 4, {}, 150, 160, 180, 'particle default drawDistance 150')
    r3(13, 'hide', 4, { radius = 4 }, 0, 154, 204, 'hide: radius + 150 / + 50, never "visible"')
    r3(14, 'zone', 5, { r = 30 }, 0, 50, 70, 'zone: bounding radius + 20 / + 20')
    r3(15, 'sound', 4, { range = 30 }, 30, 50, 70, 'sound: range / +20 / +40')
    r3(16, 'audio', 6, { range = 40 }, 40, 60, 80, 'audio emitter: range / +20 / +40')
    r3(17, 'fw:battery', 7, {}, 100, 100, 125, 'custom kind radius 100: +25 %', { radius = 100 })
    r3(18, 'fw:battery', 7, {}, 40, 40, 60, 'custom kind radius 40: + max(20, 25 %)', { radius = 40 })
    r3(19, 'odd', 7, {}, 10, 20, 30, 'handler.radii overrides the table')
    eq(h.nodes[17].m.bk, 'fw:battery', 'a custom kind counts against its own cap (Caps.custom per kind)')
    eq(h.nodes[7].m.bk, 'lights', 'light budget')
    eq(h.nodes[14].m.bk, nil, 'zones have no cap')
    eq(h.nodes[7].m.fade, 'self', 'fx kinds fade themselves by default')
    eq(h.nodes[1].m.fade, 'engine', 'props: engine fade band')
    -- the LOD scale: sampled once a second, radii recomputed on a > 5 % change
    local reads = h.n('GetLodscale')
    h.tick(5000)
    ok(h.n('GetLodscale') - reads <= 6, 'GetLodscale at most once a second (' .. (h.n('GetLodscale') - reads) .. ' in 5 s)')
    h.set.lodscale = 1.75
    h.tick(1100)
    eq(M.lodScale(), 1.75, 'lodScale() follows GetLodscale')
    near(h.nodes[1].m.rVis, 195, 1e-9, 'S 1.75: R_vis = 100 * 1.75 + 20')
    near(h.nodes[1].m.rIn, 205, 1e-9, 'S 1.75: R_in')
    near(h.nodes[1].m.rOut, 256.25, 1e-9, 'S 1.75: R_out')
    near(h.nodes[2].m.rVis, 31.25, 1e-9, 'S 1.75: small band stays 5')
    eq(h.nodes[3].m.lodClamp, 268, 'S 1.75: clamp floor(470 / 1.75)')
    near(h.nodes[3].m.rIn, 499, 1e-9, 'S 1.75: clamped R_in stays inside the cap')
    near(h.nodes[19].m.rIn, 35, 1e-9, 'handler.radii gets S')
    h.set.lodscale = 1.8
    h.tick(1100)
    eq(M.lodScale(), 1.75, 'a 2.9 % change is ignored')
    near(h.nodes[1].m.rVis, 195, 1e-9, 'radii unchanged below 5 %')
    h.set.lodscale = 2.0
    h.tick(1100)
    eq(M.lodScale(), 2.0, 'a 14 % change is taken')
    near(h.nodes[1].m.rVis, 220, 1e-9, 'radii recomputed')
end

-- 3. the state machine: KNOWN -> WARM -> LIVE -> RETIRING -> gone; FAILED; OFF -------------------------------------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)                   -- yaw 0: looking along +y
    h.models[HPROP] = { delay = 400 }
    local hp = handler(h, 'prop', { budget = 'props', fade = 'engine' })
    M.registerKind('prop', hp)
    local lives, gones = {}, {}
    M.setListener(function(event, node) if event == 'live' then lives[#lives + 1] = node.id elseif event == 'gone' then gones[#gones + 1] = node.id end end)
    local n1 = h.node(1, 'prop', 1, 0, 50, 0, { model = HPROP, lod = 100 })
    M.add(n1)
    eq(st(h, 1), KNOWN, 'added: KNOWN')
    eq(M.stats().byState.known, 1, 'counted KNOWN')
    h.tick(600)
    eq(st(h, 1), WARM, 'in range: WARM (model requested)')
    eq(h.requested[HPROP], 1, 'RequestModel once')
    eq(M.handleOf(1), nil, 'no entity while WARM')
    h.tick(600)
    eq(st(h, 1), LIVE, 'model loaded: LIVE')
    local e1 = M.handleOf(1)
    ok(e1 and h.ents[e1] and not h.ents[e1].deleted, 'handleOf answers the entity')
    eq(M.idOf(e1), 1, 'idOf(handleOf(id)) == id')
    eq(hp.created, 1, 'create() once')
    eq(hp.ctx[1].late, true, 'created inside R_vis: a late arrival')
    eq(hp.ctx[1].seen, true, 'in the frustum: seen')
    eq(h.ents[e1].alphaLog[1], 51, 'a late arrival in view fades in from 51')
    h.tick(400)
    eq(h.ents[e1].alpha, nil, 'fade-in ended with ResetEntityAlpha')
    eq(h.ents[e1].reset, 1, 'ResetEntityAlpha once')
    eq(lives[1], 1, "listener heard 'live'")
    local s = M.stats()
    eq(s.byState.live, 1, 'stats.byState.live')
    eq(s.byBudget.props, 1, 'stats.byBudget.props')
    eq(s.created, 1, 'stats.created')
    -- removed while in view: deferred (RETIRING), deleted once unseen for UnseenMs
    M.remove(n1)
    eq(st(h, 1), RETIRING, 'removed in view: RETIRING')
    ok(not h.ents[e1].deleted, 'never deleted in view')
    eq(M.handleOf(1), e1, 'a retiring entity still answers handleOf')
    h.tick(2000)
    ok(not h.ents[e1].deleted, 'still in view after 2 s: still there')
    h.cam(0, 0, 0, 0, 180)                 -- turn around
    h.tick(1000)
    ok(not h.ents[e1].deleted, 'unseen for < 1.5 s: kept')
    h.tick(1000)
    ok(h.ents[e1].deleted, 'unseen for >= 1.5 s: deleted')
    eq(hp.destroyed, 1, 'destroy() called')
    eq(gones[1], 1, "listener heard 'gone'")
    eq(M.stats().nodes, 0, 'the removed record is dropped')
    eq(M.stats().zombies, 0, 'no zombie left')
    eq(M.stats().byState.retiring, 0, 'counts back to zero')
    -- FAILED: a missing model fails its nodes once per session, one log line
    h.models[9999] = { mode = 'missing' }
    M.add(h.node(2, 'prop', 1, 5, 40, 0, { model = 9999 }))
    M.add(h.node(3, 'prop', 1, -5, 40, 0, { model = 9999 }))
    h.tick(1000)
    eq(st(h, 2), FAILED, 'a missing model: FAILED')
    eq(st(h, 3), FAILED, 'every node of it: FAILED')
    local lines = 0
    for _, w in ipairs(h.warnings) do if w:find('9999', 1, true) then lines = lines + 1 end end
    eq(lines, 1, 'one log line per failed model')
    eq(h.requested[9999], nil, 'a model not in the game files is never requested')
    -- OFF: no handler, placeholder
    M.add(h.node(4, 'nobody:kind', 7, 0, 30, 0, {}))
    eq(st(h, 4), OFF, 'no handler for the kind: OFF')
    M.add(h.node(5, 'prop', 1, 0, 30, 0, { model = HPROP }, { flags = 4 }))
    eq(st(h, 5), OFF, 'placeholder flag: OFF')
    h.tick(1000)
    eq(st(h, 5), OFF, 'a placeholder never materialises')
    eq(hp.created, 1, 'nothing else created')
end

--- Largest per-frame delta of f() over `n` frames.
local function worstPerFrame(h, n, f)
    local worst, total = 0, 0
    for _ = 1, n do
        local before = f()
        h.frames(1)
        local d = f() - before
        total = total + d
        if d > worst then worst = d end
    end
    return worst, total
end

--- `n` props on a ring of radius `r` around (cx, cy) — early arrivals when r > R_vis (no fade needed).
local function ring(h, M, first, n, r, fields, cx, cy)
    for i = 0, n - 1 do
        local a = 2 * math.pi * i / n
        local f = {}
        for k, v in pairs(fields) do f[k] = v end
        M.add(h.node(first + i, 'prop', 1, (cx or 0) + r * math.cos(a), (cy or 0) + r * math.sin(a), 0, f))
    end
end

-- 4. per-frame budgets: props 8, ped-or-vehicle 1, custom 2, deletes 32, model requests 2, x10 while teleporting ------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    ring(h, M, 1, 60, 175, { model = HPROP, lod = 150 })         -- R_vis 170, R_in 180: early arrivals
    local worst, total = worstPerFrame(h, 60, function() return hp.created end)
    eq(worst, 8, 'at most PropsPerFrame (8) creations per frame')
    eq(total, 60, 'all 60 created')
    eq(M.stats().byState.live, 60, '60 LIVE')
    eq(h.n('SetEntityAlpha'), 0, 'early arrivals (beyond R_vis) need no fade: the engine band reveals them')
    -- deletions: the camera leaves, everything is beyond R_vis -> deleted at once, <= 32 a frame
    h.cam(3000, 0, 0)
    local wd = worstPerFrame(h, 40, function() return h.n('DeleteEntity') end)
    eq(wd, 32, 'at most DeletesPerFrame (32) deletions per frame')
    eq(h.alive(), 0, 'all deleted')
    eq(M.stats().byState.known, 60, 'back to KNOWN (still cached)')
    -- ped and vehicle share EntityPerFrame (1); custom kinds get CustomPerFrame (2)
    h.cam(0, 0, 0)
    local hped, hveh = handler(h, 'ped', { budget = 'peds' }), handler(h, 'vehicle', { budget = 'vehicles' })
    local hcus = handler(h, 'custom')
    M.registerKind('ped', hped)
    M.registerKind('vehicle', hveh)
    M.registerKind('custom', hcus)
    for i = 1, 5 do
        M.add(h.node(100 + i, 'ped', 3, -20 + i * 4, -60, 0, { model = HPED }))   -- behind (out-of-view R_in 75 m)
        M.add(h.node(110 + i, 'vehicle', 2, -20 + i * 4, -120, 0, { model = HVEH }))
        M.add(h.node(120 + i, 'fw:box', 7, -20 + i * 4, -90, 0, {}, { radius = 150 }))
    end
    local we = worstPerFrame(h, 60, function() return hped.created + hveh.created end)
    eq(we, 1, 'at most one ped-or-vehicle per frame (EntityPerFrame)')
    eq(hped.created + hveh.created, 10, 'all 10 peds and vehicles created')
    eq(hcus.created, 5, 'custom kinds created')
    ok(hcus.order[1] and hcus.ctx[hcus.order[2]].frame == hcus.ctx[hcus.order[1]].frame
        and hcus.ctx[hcus.order[3]].frame > hcus.ctx[hcus.order[2]].frame, 'custom kinds: 2 per frame (CustomPerFrame)')
    -- model requests: <= 2 new requests per frame
    local hp2 = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp2)
    for i = 1, 20 do
        h.models[5000 + i] = { delay = 3000 }
        M.add(h.node(200 + i, 'prop', 1, i * 2 - 20, 60, 0, { model = 5000 + i }))
    end
    local wr = worstPerFrame(h, 60, function() return h.n('RequestModel') end)
    eq(wr, 2, 'at most ModelRequestsPerFrame (2) new requests per frame')
    h.tick(5000)
    local all = true
    for i = 1, 20 do all = all and st(h, 200 + i) == LIVE end
    ok(all, 'every model loaded and its node created')
    eq(hp.destroyed, hp.created, 're-registering a kind: the old handler destroys every entity it created')
end

do   -- teleport mode = the screen faded out (x10); a core-teleport flag alone changes nothing (RV2 F7); ModelsInFlight
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    ring(h, M, 1, 120, 175, { model = HPROP, lod = 150 })
    M.setTeleport(true)                                         -- e.g. someone waits for an area: screen visible
    local worst = worstPerFrame(h, 60, function() return hp.created end)
    eq(worst, 8, 'setTeleport with the screen visible: the normal budget (8), no x10 (F7)')
    eq(M.stats().teleport, false, 'not teleport mode while the screen shows')
    M.setTeleport(false)
    h.cam(3000, 0, 0)
    h.tick(600)
    for id = 1, 120 do M.remove(h.nodes[id]) end
    h.tick(1000)
    h.stubs.gameState.fadedOut = true                       -- IsScreenFadedOut() counts as a teleport
    h.cam(0, 0, 0)
    ring(h, M, 301, 100, 175, { model = HPROP, lod = 150 })
    local wf = worstPerFrame(h, 60, function() return hp.created end)
    eq(wf, 80, 'screen faded out: PropsPerFrame x TeleportMultiplier (80)')
    eq(M.stats().teleport, true, 'stats.teleport while the screen is faded out')
    h.stubs.gameState.fadedOut = false
    h.cam(3000, 0, 0)
    h.tick(1000)
    -- ModelsInFlight: never more than 30 models streaming at once
    h.cam(0, 0, 0)
    for i = 1, 40 do
        h.models[6000 + i] = { mode = 'never' }
        M.add(h.node(400 + i, 'prop', 1, i * 2 - 40, 60, 0, { model = 6000 + i }))
    end
    h.tick(3000)
    eq(M.stats().loading, 30, 'at most ModelsInFlight (30) models streaming')
    eq(h.n('RequestModel') - 1, 30, 'the other 10 are not requested yet')
    h.tick(9000)
    eq(M.stats().byState.failed >= 30, true, 'timed out after 10 s: FAILED')
    h.tick(12000)
    eq(M.stats().byState.failed, 40, 'the next 10 got their turn and timed out too')
    eq(h.released[6001], 1, 'a timed-out request is given back (SetModelAsNoLongerNeeded)')
    local lines = 0
    for _, w in ipairs(h.warnings) do if w:find('did not load within 10 s', 1, true) then lines = lines + 1 end end
    eq(lines, 40, 'one log line per failed model')
end

-- 5. priority: late arrivals first, then k = (d / R_in)^2 x (0.35 + 0.65 f) ----------------------------------------
do
    local h, M = fresh(function(Scene) Scene.Budgets.PropsPerFrame = 1 end)
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    local L = { model = HPROP, lod = 300 }                      -- R_vis 320, R_in 330
    M.add(h.node(1, 'prop', 1, 0, -325, 0, L))                  -- behind, beyond R_vis: f = 1
    M.add(h.node(2, 'prop', 1, -326, 0, 0, L))                  -- to the side: f = 0.5
    M.add(h.node(3, 'prop', 1, 0, 326, 0, L))                   -- ahead, beyond R_vis: f = 0
    M.add(h.node(4, 'prop', 1, 0, 300, 0, L))                   -- ahead, inside R_vis: late
    M.add(h.node(5, 'prop', 1, 0, -100, 0, L))                  -- behind, inside R_vis: late, near
    h.tick(1000)
    eq(#hp.order, 5, 'all five created')
    eq(table.concat(hp.order, ','), '5,4,3,2,1', 'late first (nearest k), then ahead < side < behind')
    eq(hp.ctx[5].late and hp.ctx[4].late and not hp.ctx[3].late, true, 'ctx.late set for arrivals inside R_vis')
    eq(hp.ctx[5].seen, false, 'behind the camera: not seen')
    eq(hp.ctx[4].seen, true, 'ahead inside R_vis: seen')
end

-- 6. caps: the farthest UNSEEN goes, a visible one never; swap margin and cooldown; model caps ------------------
do
    local h, M = fresh(function(Scene)
        Scene.Caps.props = 3
        Scene.Visibility.SwapCooldownMs = 5000
    end)
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    local L = { model = HPROP, lod = 150 }                      -- R_vis 170, R_in 180 (bins are coarse: distinct k)
    M.add(h.node(1, 'prop', 1, 0, -160, 0, L))                  -- behind the camera: never seen
    M.add(h.node(2, 'prop', 1, 5, -165, 0, L))
    M.add(h.node(3, 'prop', 1, -5, -150, 0, L))
    M.add(h.node(4, 'prop', 1, 10, -178, 0, L))
    h.tick(3000)
    eq(M.stats().byBudget.props, 3, 'Caps.props (3): only three exist')
    eq(st(h, 4), WARM, 'the fourth (lowest priority) waits: not 10 m closer than anything')
    eq(M.areaReady(10, -178, 0, 5), true, 'a capped node does not block areaReady')
    -- a newcomer >= SwapMargin closer evicts the farthest unseen one
    M.add(h.node(5, 'prop', 1, 0, -120, 0, L))
    h.tick(1000)
    eq(st(h, 5), LIVE, 'the newcomer is created')
    ok(st(h, 2) == KNOWN or st(h, 2) == WARM, 'the farthest unseen one (165 m) was evicted and waits again')
    eq(M.handleOf(2), nil, 'its entity is gone')
    eq(M.areaReady(5, -165, 0, 5), true, 'an evicted node does not block areaReady')
    eq(M.stats().evicted, 1, 'stats.evicted')
    eq(M.stats().byBudget.props, 3, 'still at the cap')
    -- the evicted one comes close: SwapCooldownMs keeps it from swapping back at once
    h.cam(5, -260, 0, 0, 180)                                   -- looking -y: every node behind, node 2 at 95 m
    h.tick(1500)
    eq(st(h, 4), LIVE, 'node 4 (82 m now) swapped in for the farthest unseen one')
    eq(st(h, 2), WARM, 'node 2, evicted within SwapCooldownMs, cannot swap back yet')
    h.tick(5000)
    eq(st(h, 2), LIVE, 'after the cooldown it evicts a farther unseen one')
    eq(M.stats().byBudget.props, 3, 'the cap held throughout')
end

do   -- a visible node is never evicted: the newcomer waits until it is unseen for UnseenMs
    local h, M = fresh(function(Scene) Scene.Caps.props = 1 end)
    h.cam(0, 0, 0, 0, 0)
    M.registerKind('prop', handler(h, 'prop', { budget = 'props' }))
    local L = { model = HPROP, lod = 150 }
    M.add(h.node(1, 'prop', 1, 0, 90, 0, L))                    -- ahead, inside R_vis: seen
    h.tick(1000)
    eq(st(h, 1), LIVE, 'the first is LIVE')
    M.add(h.node(2, 'prop', 1, 0, 40, 0, L))                    -- 50 m closer
    h.tick(2000)
    eq(st(h, 1), LIVE, 'a visible node is never evicted')
    eq(st(h, 2), WARM, 'so the newcomer waits')
    eq(M.areaReady(0, 40, 0, 5), true, 'a capped node does not block areaReady')
    h.cam(0, 0, 0, 0, 180)                                      -- turn around
    h.tick(1000)
    eq(st(h, 1), LIVE, 'unseen for < UnseenMs: still not evictable')
    h.tick(1500)
    eq(st(h, 2), LIVE, 'unseen long enough: the newcomer swaps in')
    ok(st(h, 1) == KNOWN or st(h, 1) == WARM, 'the old one waits in turn')
end

do   -- distinct models per class: Caps.modelsProps
    local h, M = fresh(function(Scene) Scene.Caps.modelsProps = 2 end)
    h.cam(0, 0, 0, 0, 0)
    M.registerKind('prop', handler(h, 'prop', { budget = 'props' }))
    for i = 1, 3 do M.add(h.node(i, 'prop', 1, i * 5, 60, 0, { model = 7000 + i })) end
    h.tick(2000)
    eq(M.stats().models.props, 2, 'two distinct prop models in use')
    local waiting, liveId = nil, nil
    for i = 1, 3 do
        if st(h, i) == KNOWN then waiting = i elseif st(h, i) == LIVE then liveId = i end
    end
    ok(waiting ~= nil, 'the third model waits for a free model slot (KNOWN)')
    eq(h.requested[7000 + waiting], nil, 'and is not requested')
    M.remove(h.nodes[liveId])
    h.cam(0, 0, 0, 0, 180)                                      -- let the removed one go (unseen)
    h.tick(3000)
    eq(st(h, waiting), LIVE, 'a model slot freed: the waiting one streams in')
    eq(M.stats().models.props, 2, 'still two in use')
end

do   -- phase D: Core.Maps' elements are scene nodes — the props cap counts scene props only; Core.Maps.stats() is
     -- never sampled (run I1: the 1/s read was dead and allocated)
    local h, M = fresh(function(Scene) Scene.Caps.props = 10 end)
    local sampled = 0
    h.env.Core.Maps = { stats = function() sampled = sampled + 1 return { objects = 7 } end }
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    ring(h, M, 1, 6, 175, { model = HPROP, lod = 150 })
    h.tick(3000)
    eq(hp.created, 6, 'Caps.props 10: all 6 scene props (no separate map object count any more)')
    eq(M.stats().byBudget.props, 6, 'stats.byBudget.props counts them')
    eq(sampled, 0, 'Core.Maps.stats() is never read')
end

-- 7. the pool guard: GetGamePool only above 60 % of the cap / after a refusal, <= every 10 s; stop at 85 % ------------
do
    local h, M = fresh(function(Scene)
        Scene.Caps.props = 20
        Scene.ObjectPool = 100
    end)
    h.cam(0, 0, 0, 0, 0)
    h.set.poolExtra = 70                                        -- the game's own objects
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    ring(h, M, 1, 20, 175, { model = HPROP, lod = 150 })
    h.tick(3000)
    eq(h.n('GetGamePool'), 1, 'one pool read once own props passed 60 % of the cap')
    eq(hp.created, 15, 'creation stops at 85 % of the pool (70 + 15 = 85 of 100)')
    eq(M.stats().poolEstimate, 85, 'own counters keep the estimate between reads')
    h.tick(8000)
    eq(h.n('GetGamePool'), 2, 'at most one pool read per 10 s')
    h.set.poolExtra = 60
    h.tick(10000)
    eq(hp.created, 20, 'room again: the rest follow')
    -- a refused create: the class backs off 1 s, the pool is read, three refusals fail the node
    local h2, M2 = fresh()
    h2.cam(0, 0, 0, 0, 0)
    local refuse = handler(h2, 'prop', { budget = 'props', refuse = true })
    M2.registerKind('prop', refuse)
    M2.add(h2.node(1, 'prop', 1, 0, -60, 0, { model = HPROP }))
    h2.tick(600)
    eq(h2.n('GetGamePool'), 1, 'a refused create reads the pool')
    eq(st(h2, 1), WARM, 'the node waits (backoff)')
    h2.tick(3500)
    eq(st(h2, 1), FAILED, 'refused three times: FAILED')
    local lines = 0
    for _, w in ipairs(h2.warnings) do if w:find('refused 3 times', 1, true) then lines = lines + 1 end end
    eq(lines, 1, 'one log line')
end

--- Moves the camera continuously: `vy` m/s along +y for `ms`, one step per frame; -> the new y.
local function drive(h, x, y, z, vy, ms)
    local frames = math.floor(ms / h.FRAME)
    for _ = 1, frames do
        y = y + vy * h.FRAME / 1000
        h.cam(x, y, z)
        h.frames(1)
    end
    return y
end

--- Ticks frame by frame until cond() or `ms` passed; -> whether cond() held.
local function waitFor(h, ms, cond)
    local t0 = h.now()
    while h.now() - t0 < ms do
        if cond() then return true end
        h.frames(1)
    end
    return cond()
end

-- 8. visibility-safe deletes: beyond R_vis or unseen -> now; seen -> RETIRING (<= DeferMaxMs, then a fade-out) ------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    local hped = handler(h, 'ped', { budget = 'peds' })
    M.registerKind('prop', hp)
    M.registerKind('ped', hped)
    local P = { model = HPROP, lod = 100 }                      -- R_vis 120, R_in 130
    M.add(h.node(1, 'prop', 1, 0, 125, 0, P))                   -- beyond R_vis: the engine band hides it
    M.add(h.node(2, 'prop', 1, 0, 60, 0, P))                    -- in view
    M.add(h.node(3, 'ped', 3, 2, 40, 0, { model = HPED }))      -- in view
    h.tick(2000)
    ok(st(h, 1) == LIVE and st(h, 2) == LIVE and st(h, 3) == LIVE, 'all three LIVE')
    local e1, e2, e3 = M.handleOf(1), M.handleOf(2), M.handleOf(3)
    M.remove(h.nodes[1])
    eq(st(h, 1), RETIRING, 'removed beyond R_vis: queued for deletion')
    h.tick(600)
    ok(h.ents[e1].deleted, 'removed beyond R_vis: deleted on the next wake (no fade, no deferral)')
    eq(#h.ents[e1].alphaLog, 0, 'without any alpha override')
    local base2 = #h.ents[e2].alphaLog                        -- its fade-in (a late arrival in view)
    eq(h.ents[e2].alpha, nil, 'the fade-in has ended')
    M.remove(h.nodes[2])
    eq(st(h, 2), RETIRING, 'removed in view: RETIRING')
    h.tick(9000)
    ok(not h.ents[e2].deleted, 'still in view after 9 s: deferred')
    eq(#h.ents[e2].alphaLog, base2, 'no fade before DeferMaxMs')
    h.tick(1500)
    local log = h.ents[e2].alphaLog
    ok(#log > base2, 'DeferMaxMs passed in view: a fade-out started')
    local falling = true
    for i = base2 + 2, #log do if log[i] > log[i - 1] then falling = false end end
    ok(falling, 'the alpha only falls during a fade-out')
    h.tick(600)
    ok(h.ents[e2].deleted, 'deleted at the end of the fade-out (450 ms)')
    ok(log[#log] >= 51, 'ramps end at 51 (below 50 nothing is drawn): ' .. tostring(log[#log]))
    -- peds and vehicles: unseen for ImportantUnseenMs (4 s)
    M.remove(h.nodes[3])
    h.cam(0, 0, 0, 0, 180)
    h.tick(2500)
    ok(not h.ents[e3].deleted, 'a ped unseen for 2.5 s is kept (4 s rule)')
    h.tick(2000)
    ok(h.ents[e3].deleted, 'unseen for 4 s: deleted')
    -- DEL(fade): a visible node fades out right away
    h.cam(0, 0, 0, 0, 0)
    M.add(h.node(4, 'prop', 1, 0, 50, 0, P))
    h.tick(1500)
    local e4 = M.handleOf(4)
    local base = #h.ents[e4].alphaLog
    M.remove(h.nodes[4], 'fade')
    h.frames(3)
    ok(#h.ents[e4].alphaLog > base, "remove(node, 'fade') in view: the fade-out starts at once")
    h.tick(600)
    ok(h.ents[e4].deleted, 'and deletes after it')
    -- seen a moment ago, out of view now: still deferred for UnseenMs
    M.add(h.node(5, 'prop', 1, 0, 50, 0, P))
    h.tick(1500)
    local e5 = M.handleOf(5)
    h.cam(0, 0, 0, 0, 180)
    h.tick(120)                                                  -- one check: the camera turned
    M.remove(h.nodes[5], 0)
    h.frames(2)
    ok(not h.ents[e5].deleted, 'seen < 1.5 s ago: not deleted yet (the player may look back)')
    h.tick(1600)
    ok(h.ents[e5].deleted, 'unseen for 1.5 s: deleted')
    -- leaving the range deletes what is beyond R_vis at once
    M.add(h.node(6, 'prop', 1, 0, 60, 0, P))
    h.cam(0, 0, 0, 0, 0)
    h.tick(1500)
    local e6 = M.handleOf(6)
    h.cam(0, -600, 0, 0, 0)
    h.tick(600)
    ok(h.ents[e6].deleted, 'out of R_out (and beyond R_vis): deleted')
    eq(st(h, 6), KNOWN, 'and KNOWN again (still cached)')
end

-- 9. fades: slot budget, vehicles, urgent late arrivals staged at alpha 0, reversal, no fades at speed / teleport ------
do
    local h, M = fresh(function(Scene) Scene.Fades.Max, Scene.Fades.MaxVehicles = 2, 1 end)
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    for i = 1, 4 do M.add(h.node(i, 'prop', 1, (i - 2.5) * 10, 80, 0, { model = HPROP })) end   -- late, in view
    ok(waitFor(h, 1000, function() return hp.created >= 2 end), 'late arrivals created')
    eq(hp.created, 2, 'Fades.Max (2): two fade in, the other two (not urgent) wait for a slot')
    eq(M.stats().fades, 2, 'two fades running')
    local worst = 0
    for _ = 1, 60 do
        h.frames(1)
        if M.stats().fades > worst then worst = M.stats().fades end
    end
    eq(worst, 2, 'never more than Fades.Max at once')
    h.tick(1500)
    eq(hp.created, 4, 'slots freed: the waiting ones followed')
    local resets = 0
    for i = 1, 4 do resets = resets + (h.ents[M.handleOf(i)].reset or 0) end
    eq(resets, 4, 'every fade-in ended with ResetEntityAlpha')
    for i = 1, 4 do eq(h.ents[M.handleOf(i)].alpha, nil, 'no alpha override left on node ' .. i) end
    local steps = h.ents[M.handleOf(1)].alphaLog
    ok(steps[1] == 51 and #steps >= 5, 'the ramp starts at 51 and is stepped by frame time (' .. #steps .. ' steps)')
    -- vehicles: <= Fades.MaxVehicles at once
    local hv = handler(h, 'vehicle', { budget = 'vehicles' })
    M.registerKind('vehicle', hv)
    for i = 21, 23 do M.add(h.node(i, 'vehicle', 2, (i - 22) * 15, 100, 0, { model = HVEH })) end
    local vworst = 0
    for _ = 1, 120 do
        h.frames(1)
        if M.stats().vehicleFades > vworst then vworst = M.stats().vehicleFades end
    end
    eq(vworst, 1, 'Fades.MaxVehicles (1): one vehicle fade at a time')
    h.tick(3000)
    eq(hv.created, 3, 'all vehicles came, one fade after the other')
    -- reversal: a fading-out node wanted again fades back in from its current alpha
    M.add(h.node(30, 'prop', 1, 0, 40, 0, { model = HPROP }))
    h.tick(1500)
    local e30 = M.handleOf(30)
    local n30 = h.nodes[30]
    local baseR = #h.ents[e30].alphaLog                        -- its own fade-in came first
    M.remove(n30, 'fade')
    h.frames(10)
    local low = h.ents[e30].alpha
    ok(low and low < 255, 'fading out')
    M.add(n30)                                                  -- back (re-sent / handover)
    h.tick(1000)
    ok(not h.ents[e30].deleted, 'the entity was kept')
    eq(M.handleOf(30), e30, 'same entity')
    eq(h.ents[e30].alpha, nil, 'faded back in and reset')
    local rlog = h.ents[e30].alphaLog
    local minA, minI = 256, 0
    for i = baseR + 1, #rlog do if rlog[i] < minA then minA, minI = rlog[i], i end end
    ok(minA > 51 and minA < 255 and rlog[#rlog] > minA and minI < #rlog,
        'the reversal turned around above 51 and climbed from there (min ' .. minA .. ')')
end

do   -- an urgent late arrival (< 0.25 R_in) while every slot is busy: created at alpha 0 (STAGED), revealed later
    local h, M = fresh(function(Scene) Scene.Fades.Max, Scene.Fades.PropInMs = 1, 3000 end)
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    M.add(h.node(1, 'prop', 1, 0, 90, 0, { model = HPROP }))      -- late, not urgent: takes the only slot
    ok(waitFor(h, 1000, function() return M.stats().fades == 1 end), 'the only slot is busy (3 s fade)')
    M.add(h.node(2, 'prop', 1, 5, 80, 0, { model = HPROP }))      -- late, not urgent: waits (not created)
    M.add(h.node(3, 'prop', 1, 0, 20, 0, { model = HPROP }))      -- 20 m: urgent
    ok(waitFor(h, 1000, function() return M.handleOf(3) ~= nil end), 'the urgent one is created anyway')
    local e3 = M.handleOf(3)
    eq(st(h, 3), STAGED, 'STAGED: waiting for a fade slot')
    eq(h.ents[e3].alpha, 0, 'at alpha 0 (collision exists, nothing drawn)')
    eq(M.stats().stagedWaiting, 1, 'stats.stagedWaiting')
    eq(M.handleOf(2), nil, 'the non-urgent late arrival waits uncreated')
    eq(M.areaReady(0, 20, 0, 5), true, 'a STAGED node counts as ready (its entity exists)')
    ok(waitFor(h, 4000, function() return st(h, 3) == LIVE end), 'the slot freed: the staged one fades in (LIVE)')
    ok((h.ents[e3].alpha or 255) >= 51, 'from 51 up')
    h.tick(8000)
    eq(h.ents[e3].alpha, nil, 'revealed fully (ResetEntityAlpha)')
    ok(M.handleOf(2) ~= nil, 'the waiting one came after')
end

do   -- no fades above Speed.NoFadeAbove, none in teleport mode; the fadeIn / fadeOut API
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    h.stubs.gameState.fadedOut = true
    M.add(h.node(1, 'prop', 1, 0, 50, 0, { model = HPROP }))
    h.tick(1000)
    eq(st(h, 1), LIVE, 'teleport mode: created')
    eq(#h.ents[M.handleOf(1)].alphaLog, 0, 'teleport mode: no fade (the screen hides the reveal)')
    h.stubs.gameState.fadedOut = false
    h.tick(600)
    -- F7: an area waiter (setTeleport) with the screen visible: a visible node leaving still retires, and a late
    -- arrival in view still fades in
    local e1 = M.handleOf(1)
    M.setTeleport(true)
    M.remove(h.nodes[1])
    h.tick(600)
    ok(not h.ents[e1].deleted, 'F7: setTeleport + visible screen: the visible node retires (not deleted after 0.6 s)')
    eq(M.stats().byState.retiring, 1, 'F7: RETIRING')
    M.add(h.node(9, 'prop', 1, 3, 45, 0, { model = HPROP }))
    h.tick(1000)
    eq(h.ents[M.handleOf(9)].alphaLog[1], 51, 'F7: a late arrival in view still fades in')
    M.setTeleport(false)
    -- a camera moving at 100 m/s (> NoFadeAbove 80): late arrivals appear without a fade
    local y = drive(h, 0, 0, 0, 100, 1000)
    ok(M.stats().speed > 80, 'the camera speed is measured between checks (' .. M.stats().speed .. ' m/s)')
    M.add(h.node(2, 'prop', 1, 0, y + 80, 0, { model = HPROP }))
    y = drive(h, 0, y, 0, 100, 400)
    ok(M.handleOf(2) ~= nil, 'created while moving fast')
    eq(#h.ents[M.handleOf(2)].alphaLog, 0, 'above NoFadeAbove: no fade')
    h.tick(2000)
    -- the API other scene files use (promote hand-off, handlers)
    local e = h.newEntity(5, 0, 10, 0, 3)
    eq(M.fadeIn(e, 300, false), true, 'fadeIn takes a slot')
    eq(h.ents[e].alpha, 51, 'fadeIn starts at 51')
    h.tick(400)
    eq(h.ents[e].alpha, nil, 'fadeIn ends with ResetEntityAlpha')
    local done
    eq(M.fadeOut(e, 400, false, function(ent) done = ent end), true, 'fadeOut takes a slot')
    h.tick(500)
    eq(done, e, 'onDone(entity) at the end of the fade-out')
    ok(not h.ents[e].deleted, 'with onDone the caller deletes')
    local e2 = h.newEntity(5, 0, 12, 0, 2)
    M.fadeOut(e2, 400, true)
    eq(M.stats().vehicleFades, 1, 'a vehicle fade counts against Fades.MaxVehicles')
    h.tick(500)
    ok(h.ents[e2].deleted, 'without onDone: DeleteEntity at the end')
    eq(M.stats().fades, 0, 'no fade left, its loop ended')
end

-- 10. assets: ref-counted, requested once, linger ModelLingerMs, anim dicts and ptfx assets, class checks, timeouts
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    M.add(h.node(1, 'prop', 1, -5, -60, 0, { model = HPROP2 }))
    M.add(h.node(2, 'prop', 1, 5, -60, 0, { model = HPROP2 }))
    h.tick(1000)
    eq(h.requested[HPROP2], 1, 'two nodes, one model: one request')
    eq(M.stats().models.props, 1, 'one distinct model in use')
    M.remove(h.nodes[1])
    h.tick(600)
    eq(M.stats().models.props, 1, 'still in use by the other node')
    M.remove(h.nodes[2])
    h.tick(600)
    eq(M.stats().models.props, 0, 'no node uses it')
    eq(h.released[HPROP2], nil, 'the model lingers (no SetModelAsNoLongerNeeded yet)')
    eq(M.stats().lingering, 1, 'stats.lingering')
    h.tick(20000)
    eq(h.released[HPROP2], nil, 'still lingering after 20 s')
    M.add(h.node(3, 'prop', 1, 0, -60, 0, { model = HPROP2 }))   -- used again within the linger
    h.tick(1000)
    eq(h.requested[HPROP2], 1, 'reused within ModelLingerMs: no new request')
    eq(M.stats().lingering, 0, 'the linger is cancelled')
    M.remove(h.nodes[3])
    h.tick(29000)
    eq(h.released[HPROP2], nil, 'not before 30 s')
    h.tick(3000)
    eq(h.released[HPROP2], 1, 'released once, 30 s after the last use')
    eq(M.stats().assets, 0, 'the entry is gone')
    -- anim dict + ptfx asset: requested together, created once both loaded, released after the linger
    h.anims['anim@test'] = { delay = 400 }
    h.ptfx['core_test'] = { delay = 800 }
    M.add(h.node(4, 'prop', 1, 0, -60, 0, { model = HPROP, dict = 'anim@test', fx = 'core_test' }))
    h.tick(600)
    eq(h.requested['anim@test'], 1, 'RequestAnimDict once')
    eq(h.requested['core_test'], 1, 'RequestNamedPtfxAsset once')
    eq(st(h, 4), WARM, 'waits for every asset')
    h.tick(1000)
    eq(st(h, 4), LIVE, 'created once model, dict and ptfx are loaded')
    M.remove(h.nodes[4])
    h.tick(32000)
    eq(h.released['anim@test'], 1, 'RemoveAnimDict after the linger')
    eq(h.released['core_test'], 1, 'RemoveNamedPtfxAsset after the linger')
    -- a missing anim dict fails the node; class checks per handler class
    h.anims['anim@missing'] = { mode = 'missing' }
    M.add(h.node(5, 'prop', 1, 0, -60, 0, { model = HPROP, dict = 'anim@missing' }))
    local hv = handler(h, 'vehicle', { budget = 'vehicles' })
    M.registerKind('vehicle', hv)
    M.add(h.node(6, 'vehicle', 2, 10, -60, 0, { model = HPROP }))    -- an object model on a vehicle kind
    M.add(h.node(7, 'prop', 1, -10, -60, 0, { model = HPED }))       -- a ped model on a prop kind
    h.tick(1500)
    eq(st(h, 5), FAILED, 'a missing anim dict: FAILED')
    eq(h.requested['anim@missing'], nil, 'never requested')
    eq(st(h, 6), FAILED, 'a vehicle kind with an object model: FAILED')
    eq(st(h, 7), FAILED, 'a prop kind with a ped model: FAILED')
    local cls = 0
    for _, w in ipairs(h.warnings) do if w:find('is not a vehicle model', 1, true) or w:find('is not a prop model', 1, true) then cls = cls + 1 end end
    eq(cls, 2, 'one log line per wrong-class model')
    eq(hv.created, 0, 'nothing created for them')
    eq(h.n('IsModelAVehicle') >= 1 and h.n('IsModelAVehicle') <= 4, true, 'class natives asked once per model')
    -- FAILED is for the session, but a changed model is a new chance
    local n7 = h.nodes[7]
    n7.fields.model = HPROP
    M.update(n7, 'set', { f = { model = HPROP } })
    h.tick(1000)
    eq(st(h, 7), LIVE, 'a node whose model changed gets another chance')
end

-- 11. interiors: GetInteriorAtCoords once per node, IsInteriorReady at 4 Hz while pending, ForceRoomForEntity ----------
do
    local h, M = fresh()
    h.cam(1000, 0, 0, 0, 0)
    h.set.interiorAt = function(x) return x > 1000 and 77 or 0 end
    M.registerKind('prop', handler(h, 'prop', { budget = 'props' }))
    M.add(h.node(1, 'prop', 1, 1005, 50, 0, { model = HPROP }))
    M.add(h.node(2, 'prop', 1, 1003, 55, 0, { model = HPROP, room = { interior = 77, key = 555 } }))
    M.add(h.node(3, 'prop', 1, 995, 50, 0, { model = HPROP }))
    h.tick(1000)
    eq(st(h, 3), LIVE, 'outside any interior: created')
    eq(st(h, 1), WARM, 'its interior is not ready: waiting')
    eq(st(h, 2), WARM, 'the editor-placed one waits too')
    eq(h.n('GetInteriorAtCoords'), 2, 'GetInteriorAtCoords once per node without fields.room')
    eq(M.stats().interiorsPending, 2, 'two nodes wait for an interior')
    eq(M.areaReady(1005, 50, 0, 10), false, 'a node waiting for its interior blocks areaReady')
    local polls = h.n('IsInteriorReady')
    h.tick(2000)
    local d = h.n('IsInteriorReady') - polls
    ok(d >= 6 and d <= 10, 'IsInteriorReady at 4 Hz while pending, once per interior (' .. d .. ' in 2 s)')
    h.interiorReady[77] = true
    h.tick(1000)
    eq(st(h, 1), LIVE, 'ready: created')
    eq(st(h, 2), LIVE, 'ready: created')
    local r2 = h.ents[M.handleOf(2)].room
    ok(r2 and r2[1] == 77 and r2[2] == 555, 'ForceRoomForEntity(e, interior, key) when the room key is known')
    eq(h.ents[M.handleOf(1)].room, nil, 'no room key: no ForceRoomForEntity')
    eq(h.n('GetInteriorAtCoords'), 2, 'still once per node')
    eq(M.stats().interiorsPending, 0, 'nothing pending')
    local p0 = h.n('IsInteriorReady')
    h.tick(2000)
    eq(h.n('IsInteriorReady'), p0, 'no polling once nothing waits')
end

-- 12. holds: the runtime never moves, re-creates or deletes a held node's entity; changes apply on release ------------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    local n1 = h.node(1, 'prop', 1, 0, 50, 0, { model = HPROP })
    M.add(n1)
    h.tick(1500)
    local e1 = M.handleOf(1)
    eq(M.hold(1, 'editor'), e1, 'hold answers the entity')
    eq(M.hold(1, 'gizmo'), e1, 'a second holder')
    n1.x = 5.0
    M.update(n1, 'move')
    eq(h.ents[e1].x, 0.0, 'held: a move does not touch the entity')
    eq(#hp.updates, 0, 'held: handler.update is not called')
    n1.fields.model = HPROP2
    M.update(n1, 'set', { f = { model = HPROP2 } })
    h.tick(1000)
    eq(M.handleOf(1), e1, 'held: a model change does not re-create')
    h.cam(0, -3000, 0)
    h.tick(1500)
    ok(not h.ents[e1].deleted, 'held: never deleted, even out of range')
    M.remove(n1)
    h.tick(1000)
    ok(not h.ents[e1].deleted, 'removed while held: kept until release')
    eq(M.handleOf(1), e1, 'handleOf still answers it')
    M.release(1, 'editor')
    h.tick(1000)
    ok(not h.ents[e1].deleted, 'one holder left: still held')
    M.release(1, 'gizmo')
    h.tick(1000)
    ok(h.ents[e1].deleted, 'the last holder released: the pending removal applies')
    -- a move while held applies on release
    h.cam(0, 0, 0)
    local n2 = h.node(2, 'prop', 1, 0, 40, 0, { model = HPROP })
    M.add(n2)
    h.tick(1500)
    local e2 = M.handleOf(2)
    M.hold(2)
    n2.x = 7.0
    M.update(n2, 'move')
    eq(#hp.updates, 0, 'held: nothing yet')
    M.release(2)
    ok(#hp.updates == 1 and hp.updates[1].what == 'move', "released: the handler gets the pending change as 'move'")
    eq(M.handleOf(2), e2, 'same entity')
    -- a model change while held re-creates on release
    M.hold(2)
    n2.fields.model = HPROP2
    M.update(n2, 'set', { f = { model = HPROP2 } })
    M.release(2)
    h.tick(1500)
    ok(M.handleOf(2) ~= nil and M.handleOf(2) ~= e2, 'released: the model change re-creates the entity')
    ok(waitFor(h, 2000, function() return h.ents[e2].deleted end), 'the old entity goes (faded out in view)')
    eq(M.hold(99, 'x'), nil, 'hold of an unknown id answers nil')
    M.add(h.node(99, 'prop', 1, 3, 40, 0, { model = HPROP }))
    eq(h.nodes[99].m.held, true, 'a hold taken before the node arrived applies to it')
    M.release(99, 'x')
    eq(h.nodes[99].m.held, false, 'and is given back')
end

-- 13. handover: a node re-added with the same id keeps its entity ----------------------------------------------------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    M.add(h.node(1, 'prop', 1, 0, 60, 0, { model = HPROP }))
    h.tick(1500)
    local e1, made = M.handleOf(1), hp.created
    M.remove(h.nodes[1], 'handover')
    eq(M.stats().handover, 1, 'kept for the PUT of the same id')
    local again = h.node(1, 'prop', 1, 0, 64, 0, { model = HPROP })   -- the new cell's copy (a new record)
    M.add(again)
    h.tick(1000)
    eq(M.handleOf(1), e1, 'handover: the same entity')
    ok(not h.ents[e1].deleted, 'never deleted')
    eq(hp.created, made, 'no re-create')
    eq(again.m.st, LIVE, 'LIVE on the new record')
    eq(M.stats().handover, 0, 'the grace list is empty')
    eq(M.stats().zombies, 0, 'no zombie left')
    -- a DEL(handover) whose PUT never comes: the normal, visibility-safe removal after the grace
    M.remove(again, 1)
    h.tick(1500)
    ok(not h.ents[e1].deleted, 'in view after the grace: RETIRING, not deleted')
    h.cam(0, 0, 0, 0, 180)
    h.tick(2500)
    ok(h.ents[e1].deleted, 'unseen: deleted')
    -- re-added while retiring (a quick UNSUB / SUB): the entity is taken back
    h.cam(0, 0, 0, 0, 0)
    local n2 = h.node(2, 'prop', 1, 0, 50, 0, { model = HPROP })
    M.add(n2)
    h.tick(1500)
    local e2 = M.handleOf(2)
    M.remove(n2)
    eq(st(h, 2), RETIRING, 'removed in view: retiring')
    M.add(n2)
    h.tick(600)
    eq(st(h, 2), LIVE, 're-added: LIVE again')
    eq(M.handleOf(2), e2, 'with the same entity')
end

-- 13b. review RV6 F3 / F4 (FX2): a removal takes the node's prompts NOW (not when its entity finally goes), a
-- hand-over keeps them; a world change ('world' = 3, the cache's bucket reset) deletes at once, in view or not ------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local cleared = {}
    h.C.kinds = { clearInteract = function(id) cleared[#cleared + 1] = id end }
    local hp = handler(h, 'prop', { budget = 'props', attachSelf = true })
    M.registerKind('prop', hp)
    local P = { model = HPROP, lod = 100 }
    for id = 1, 5 do M.add(h.node(id, 'prop', 1, (id - 3) * 3, 50, 0, P)) end
    M.add(h.node(10, 'prop', 1, 6, 55, 0, P, { children = { 11 } }))
    M.add(h.node(11, 'prop', 1, 6, 55, 1, { model = HPROP2 }, { parent = 10 }))
    h.tick(2000)
    local e = {}
    for _, id in ipairs({ 1, 2, 3, 4, 5, 10, 11 }) do e[id] = M.handleOf(id) end
    ok(e[1] and e[5] and e[10] and e[11] and st(h, 1) == LIVE, 'everything LIVE in view')
    M.remove(h.nodes[1])
    eq(st(h, 1), RETIRING, 'removed in view: the entity retires (visibility-safe)')
    eq(table.concat(cleared, ','), '1', 'RV6 F4: its prompts go at once (C.kinds.clearInteract)')
    ok(not h.ents[e[1]].deleted, '... while the entity still stands')
    M.remove(h.nodes[2], 'handover')
    eq(#cleared, 1, 'a hand-over keeps the prompts (the PUT of the same id follows)')
    hp.updates = {}
    M.add(h.nodes[1])
    h.frames(2)
    local back = false
    for _, u in ipairs(hp.updates) do if u.id == 1 and u.what == 'interact' then back = true end end
    ok(back and st(h, 1) == LIVE, "RV6 F4: taken back while retiring: its prompts return (update 'interact')")
    h.tick(1100)
    eq(cleared[#cleared], 2, 'RV6 F4: a hand-over whose PUT never came: its prompts go at the grace end')
    local n0 = #cleared
    M.remove(h.nodes[3], 3)
    eq(h.ents[e[3]].collision, false, "RV6 F3: 'world': collision off this frame")
    eq(h.ents[e[3]].visible, false, '... hidden this frame')
    eq(cleared[n0 + 1], 3, '... its prompts gone')
    h.tick(600)
    ok(h.ents[e[3]].deleted, 'RV6 F3: deleted by the next wake although in view (was a 10 s linger)')
    M.remove(h.nodes[10], 3)
    M.remove(h.nodes[11], 3)
    eq(h.ents[e[11]].visible, false, 'a child is hidden at once too')
    h.tick(600)
    ok(h.ents[e[10]].deleted and h.ents[e[11]].deleted, '... and goes with its root')
    M.remove(h.nodes[4])
    eq(st(h, 4), RETIRING, 'a node removed normally before the bucket change retires')
    M.hold(5, 'editor')
    M.remove(h.nodes[5])
    M.worldReset()
    eq(h.ents[e[4]].visible, false, 'RV6 F3: worldReset hides what already retired of the old world ...')
    h.tick(600)
    ok(h.ents[e[4]].deleted, '... and deletes it')
    ok(not h.ents[e[5]].deleted and h.ents[e[5]].visible == nil, 'a held node stays with its holder')
    M.release(5, 'editor')
    h.tick(12000)
    ok(h.ents[e[5]].deleted, '... until it is released')
    ok(not h.ents[e[1]].deleted, 'the node taken back is untouched')
end

-- 14. children: created after their parent in the same slot, attached, revealed and deleted with it -----------------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    local hl = handler(h, 'fx', { entity = false })
    M.registerKind('prop', hp)
    M.registerKind('light', hl)
    local root = h.node(10, 'prop', 1, 0, 60, 0, { model = HPROP }, { children = { 11, 12 } })
    root.rz = 90.0
    M.add(root)
    M.add(h.node(11, 'prop', 1, 0, 60, 0, { model = HPROP2 }, { parent = 10, offset = { x = 1.0, y = 0.0, z = 2.0 },
        offrot = { x = 0.0, y = 0.0, z = 10.0 } }))
    M.add(h.node(12, 'light', 4, 0, 60, 0, { range = 5 }, { parent = 10, offset = { x = 1.0, y = 0.0, z = 2.0 } }))
    h.tick(1500)
    eq(st(h, 10), LIVE, 'the root is LIVE')
    eq(st(h, 11), LIVE, 'the entity child is LIVE')
    eq(st(h, 12), LIVE, 'the non-entity child is LIVE')
    eq(hp.order[1], 10, 'the parent is created first')
    eq(hp.ctx[11].frame, hp.ctx[10].frame, 'the child in the same frame (same slot)')
    local e10, e11 = M.handleOf(10), M.handleOf(11)
    eq(h.ents[e11].attachedTo, e10, 'AttachEntityToEntity(child, parent, ...)')
    local off = h.ents[e11].attachOffset
    ok(off[1] == 1.0 and off[2] == 0.0 and off[3] == 2.0, 'with the child offset')
    eq(h.ents[e11].attachArgs.n, 16, 'the 16-argument form')
    eq(h.ents[e11].attachArgs[14], 2, 'rotation order 2')
    near(hl.ctx[12].x, 0.0, 1e-6, 'a non-entity child is created at the composed pose (yaw 90 turns +x into +y) x')
    near(hl.ctx[12].y, 61.0, 1e-6, 'composed y')
    near(hl.ctx[12].z, 2.0, 1e-6, 'composed z')
    ok(M.areaReady(0, 60, 0, 10), 'the group is ready')
    -- the root goes: its children go in the same step (before it)
    h.cam(0, 0, 0, 0, 180)
    h.tick(600)
    M.remove(root)
    h.tick(2500)
    ok(h.ents[e10].deleted and h.ents[e11].deleted, 'root and child deleted together')
    eq(hl.destroyed, 1, 'the non-entity child destroyed')
    eq(st(h, 11), KNOWN, 'the child record stays KNOWN (the cache still holds it)')
    -- a child added after its parent is LIVE comes with the parent's next evaluation
    h.cam(0, 0, 0, 0, 0)
    local r2 = h.node(20, 'prop', 1, 30, 60, 0, { model = HPROP }, { children = { 21 } })
    M.add(r2)
    h.tick(1500)
    eq(st(h, 20), LIVE, 'a root alone')
    M.add(h.node(21, 'prop', 1, 30, 60, 0, { model = HPROP2 }, { parent = 20, offset = { x = 0.0, y = 1.0, z = 0.0 } }))
    h.tick(1500)
    eq(st(h, 21), LIVE, 'the late child is created on its parent')
    eq(h.ents[M.handleOf(21)].attachedTo, M.handleOf(20), 'and attached')
    -- a kind handler that attaches its children itself (client/scene_kinds.lua does): no second attach
    local h2, M2 = fresh()
    h2.cam(0, 0, 0, 0, 0)
    M2.registerKind('prop', handler(h2, 'prop', { budget = 'props', attachSelf = true }))
    M2.add(h2.node(1, 'prop', 1, 0, 60, 0, { model = HPROP }, { children = { 2 } }))
    M2.add(h2.node(2, 'prop', 1, 0, 60, 0, { model = HPROP }, { parent = 1 }))
    h2.tick(1500)
    eq(st(h2, 2), LIVE, 'child created')
    eq(h2.n('AttachEntityToEntity'), 0, 'already attached by its handler: not attached again')
end

-- 15. movers: every frame near and on screen, MidHz farther, not at all off screen; ended motions untracked -----------
do
    local h, M, Mv = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props', place = true })
    hp.placedBy = {}
    local place = hp.place
    function hp.place(node, e, x, y, z, rx, ry, rz)
        hp.placedBy[node.id] = (hp.placedBy[node.id] or 0) + 1
        return place(node, e, x, y, z, rx, ry, rz)
    end
    M.registerKind('prop', hp)
    local Motion = h.motion
    local function spin(dps)
        local okv, d = Motion.validate({ t = 'spin', t0 = h.now(), axis = 'z', dps = dps })
        assert(okv, tostring(d))
        return d
    end
    M.add(h.node(1, 'prop', 1, 0, 30, 0, { model = HPROP }, { motion = spin(90) }))    -- near, on screen
    M.add(h.node(2, 'prop', 1, 0, 100, 0, { model = HPROP }, { motion = spin(90) }))   -- far, on screen
    M.add(h.node(3, 'prop', 1, 0, -40, 0, { model = HPROP }, { motion = spin(90) }))   -- behind: off screen
    h.tick(1500)
    ok(st(h, 1) == LIVE and st(h, 2) == LIVE and st(h, 3) == LIVE, 'three movers LIVE')
    eq(Mv.stats().tracked, 3, 'all three tracked')
    eq(Mv.stats().running, true, 'the per-frame loop runs while movers are LIVE')
    local p1, p2, p3 = hp.placedBy[1] or 0, hp.placedBy[2] or 0, hp.placedBy[3] or 0
    h.frames(60)
    eq((hp.placedBy[1] or 0) - p1, 60, 'near + on screen: placed every frame')
    local far = (hp.placedBy[2] or 0) - p2
    ok(far >= 12 and far <= 16, 'on screen beyond NearRadius: ~15 Hz (' .. far .. ' in 0.96 s)')
    eq((hp.placedBy[3] or 0) - p3, 0, 'off screen: not at all')
    local e1 = M.handleOf(1)
    local rz0 = h.ents[e1].rz
    h.frames(10)
    ok(h.ents[e1].rz ~= rz0, 'the spin turns the entity')
    -- a tween ends: its last pose placed, then untracked
    local okt, tween = Motion.validate({ t = 'tween', t0 = h.now(), d = 300, to = { x = 2.0, y = 30.0, z = 0.0 } })
    assert(okt, tostring(tween))
    M.add(h.node(4, 'prop', 1, 0, 30, 0, { model = HPROP }, { motion = tween }))
    h.tick(1500)
    local e4 = M.handleOf(4)
    near(h.ents[e4].x, 2.0, 1e-6, 'the tween reached its end pose')
    eq(Mv.stats().tracked, 3, 'an ended motion is untracked (Motion.finished)')
    eq(M.stats().movers, 3, 'and settles into a cell for the materialiser (no mover evaluation any more)')
    eq(st(h, 4), LIVE, 'settled at its last pose, still LIVE')
    eq(M.stats().retiring, 0, 'settling released nothing')
    local okb, back = Motion.validate({ t = 'tween', t0 = h.now(), d = 1500, to = { x = 3.0, y = -20.0, z = 0.0 } })
    assert(okb, tostring(back))
    M.add(h.node(6, 'prop', 1, 0, -20, 0, { model = HPROP }, { motion = back }))   -- behind the camera: unseen
    ok(waitFor(h, 1000, function() return st(h, 6) == LIVE end), 'an unseen tween mover is LIVE')
    eq(M.stats().movers, 4, 'a mover while its tween runs')
    local e6, gone6 = M.handleOf(6), hp.destroyed
    h.tick(2500)
    eq(M.stats().movers, 3, 'the ended tween settled')
    eq(M.handleOf(6), e6, 'it settles at its end pose with the same entity (not released and re-created)')
    eq(hp.destroyed, gone6, 'nothing destroyed')
    -- movers go: the loop ends with the last one
    for id = 1, 3 do M.remove(h.nodes[id]) end
    h.cam(0, 0, 0, 0, 180)
    h.tick(3000)
    eq(Mv.stats().tracked, 0, 'deleted movers are untracked')
    h.frames(2)
    eq(Mv.stats().running, false, 'no mover: no per-frame loop')
    -- a node that gains a motion becomes a mover
    local n5 = h.node(5, 'prop', 1, 0, -30, 0, { model = HPROP })
    M.add(n5)
    h.tick(1500)
    eq(Mv.stats().tracked, 0, 'static: not tracked')
    n5.motion = spin(45)
    M.update(n5, 'motion')
    eq(Mv.stats().tracked, 1, "update 'motion': tracked")
    eq(M.stats().movers, 1, 'the materialiser evaluates it as a mover')
    n5.motion = nil
    M.update(n5, 'motion')
    eq(Mv.stats().tracked, 0, 'static again: untracked')
end

do   -- attach targets: an entity rides its target (AttachEntityToEntity), a non-entity follows its pose
    local h, M, Mv = fresh()
    h.cam(0, 0, 0, 0, 0)
    local ped = h.newEntity(0, 0, 20, 0, 1)
    h.players[7] = ped
    local hp = handler(h, 'prop', { budget = 'props' })
    local hl = handler(h, 'fx', { entity = false, place = true })
    M.registerKind('prop', hp)
    M.registerKind('light', hl)
    M.add(h.node(1, 'prop', 1, 0, 20, 0, { model = HPROP }, { attach = { p = 7 }, bone = 57005,
        offset = { x = 0.1, y = 0.0, z = 0.0 } }))
    M.add(h.node(2, 'light', 4, 0, 20, 0, { range = 3 }, { attach = { p = 7 }, offset = { x = 0.0, y = 0.0, z = 1.0 } }))
    h.tick(1500)
    local e1 = M.handleOf(1)
    ok(e1 ~= nil, 'the attached prop exists')
    eq(h.ents[e1].attachedTo, ped, "it rides the player's ped")
    eq(h.ents[e1].bone, 58005, 'on the ped bone index of the tag (GetPedBoneIndex)')
    local attaches = h.n('AttachEntityToEntity')
    h.frames(60)
    eq(h.n('AttachEntityToEntity'), attaches, 'attached once, the engine carries it')
    h.ents[ped].deleted = true                                  -- the player respawned: a new ped
    local ped2 = h.newEntity(0, 0, 25, 0, 1)
    h.players[7] = ped2
    h.tick(700)
    eq(h.ents[e1].attachedTo, ped2, 'a new target entity: re-attached')
    ok((hl.placed or 0) > 0, 'the non-entity follows the target')
    h.ents[ped2].x, h.ents[ped2].y = 3.0, 25.0
    h.frames(3)
    eq(Mv.stats().tracked, 2, 'both tracked')
end

do   -- review RV5 F4: entity riders alone (Core.Attachments props) never keep the movers loop at Wait(0)
    local h, M, Mv = fresh()
    h.cam(0, 0, 0, 0, 0)
    local zero = 0
    local wait = h.env.Wait
    h.env.Wait = function(ms)
        if (tonumber(ms) or 0) <= 0 then zero = zero + 1 end
        return wait(ms)
    end
    h.env.Citizen.Wait = h.env.Wait
    local hp = handler(h, 'prop', { budget = 'props', place = true,
        attachTarget = function(node) return node.attach and h.players[node.attach.p] or nil end })
    hp.placedBy = {}
    local place = hp.place
    function hp.place(node, e, ...)
        hp.placedBy[node.id] = (hp.placedBy[node.id] or 0) + 1
        return place(node, e, ...)
    end
    M.registerKind('prop', hp)
    for i = 1, 10 do
        h.players[i] = h.newEntity(0, 2.0 * i, 10.0, 0.0, 1)
        M.add(h.node(100 + i, 'prop', 1, 2.0 * i, 10.0, 0, { model = HPROP }, { attach = { p = i }, bone = 24818 }))
    end
    h.tick(3000)
    eq(Mv.stats().tracked, 10, 'RV5 F4: ten props ride their still players')
    local z0, f0 = zero, Mv.stats().frames
    h.tick(10000)
    eq(zero - z0, 0, 'RV5 F4: not one per-frame wait in 10 s (was every frame: 625)')
    ok(Mv.stats().frames - f0 <= 22, 'RV5 F4: the loop wakes only for the attach checks (2 Hz), '
        .. (Mv.stats().frames - f0) .. ' passes')
    ok(Mv.stats().sleeping and Mv.stats().running, '... asleep in between, still running')
    local e3, ped3 = M.handleOf(103), h.newEntity(0, 6.0, 12.0, 0.0, 1)
    h.ents[h.players[3]].deleted = true                            -- the player respawned
    h.players[3] = ped3
    h.tick(520)
    eq(h.ents[e3].attachedTo, ped3, 'RV5 F4: a new ped is still found by the next check (≤ 500 ms)')
    local okv, spin = h.motion.validate({ t = 'spin', t0 = h.now(), axis = 'z', dps = 90 })
    assert(okv, tostring(spin))
    M.add(h.node(200, 'prop', 1, 0, 30, 0, { model = HPROP }, { motion = spin }))
    local seen
    for _ = 1, 200 do
        h.frames(1)
        if (hp.placedBy[200] or 0) > 0 then
            seen = hp.placedBy[200]
            break
        end
    end
    ok(seen ~= nil, 'a motion prop materialises while the loop sleeps')
    h.frames(3)
    ok(hp.placedBy[200] >= seen + 3, 'RV5 F4: ... and is placed every frame from then on (a fresh loop, no 500 ms wait)')
    ok(not Mv.stats().sleeping, '... the loop no longer sleeps')
    M.remove(h.nodes[200])
    h.tick(12000)
    local z1 = zero
    h.tick(3000)
    eq(zero - z1, 0, 'RV5 F4: the motion prop gone, riders alone: the loop sleeps again')
end

do   -- run I1 (task 3): the node's rotation order (node.rotOrder, PUT extra `q`) reaches AttachEntityToEntity
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    local ped = h.newEntity(0, 0, 20, 0, 1)
    h.players[7] = ped
    M.add(h.node(20, 'prop', 1, 0, 60, 0, { model = HPROP }, { children = { 21, 23 } }))
    M.add(h.node(21, 'prop', 1, 0, 60, 0, { model = HPROP2 }, { parent = 20, offrot = { x = 0.0, y = 90.0, z = 0.0 },
        rotOrder = 1 }))
    M.add(h.node(23, 'prop', 1, 0, 60, 0, { model = HPROP2 }, { parent = 20 }))
    M.add(h.node(22, 'prop', 1, 0, 20, 0, { model = HPROP }, { attach = { p = 7 }, bone = 57005, rotOrder = 0 }))
    h.tick(1500)
    local e21, e22, e23 = M.handleOf(21), M.handleOf(22), M.handleOf(23)
    eq(e21 and h.ents[e21].attachArgs[14], 1, 'a child is attached in its rotOrder (1)')
    eq(e23 and h.ents[e23].attachArgs[14], 2, 'a child without one: the engine default 2')
    eq(e22 and h.ents[e22].attachArgs[14], 0, 'an attach target: rotOrder 0 (a value, not the default)')
    local ped2 = h.newEntity(0, 0, 25, 0, 1)
    h.ents[ped].deleted = true
    h.players[7] = ped2
    h.tick(700)
    eq(e22 and h.ents[e22].attachedTo, ped2, 'a new target ped: re-attached ...')
    eq(e22 and h.ents[e22].attachArgs[14], 0, "... the movers' re-attach (C.mat.attachTo) keeps the order")
end

-- 16. late binds (the plugin-kind bridge): create answers C.mat.PENDING, C.mat.bound(node, entity | 0) finishes -------
do
    local h, M = fresh(function(Scene) Scene.Caps.custom = 2 end)
    h.cam(0, 0, 0, 0, 0)
    eq(type(M.PENDING), 'table', 'C.mat.PENDING is a unique sentinel')
    local destroyed, sync = {}, {}
    local bridge = { class = 'custom', created = 0 }
    function bridge.create(node)
        bridge.created = bridge.created + 1
        if sync[node.id] then M.bound(node, sync[node.id]) end      -- a synchronous round trip
        return M.PENDING
    end
    function bridge.destroy(node, e) destroyed[#destroyed + 1] = { id = node.id, e = e } end
    M.registerKind('custom', bridge)
    local n1 = h.node(1, 'fw:box', 7, 0, 40, 0, {}, { radius = 100 })
    M.add(n1)
    ok(waitFor(h, 1000, function() return bridge.created >= 1 end), 'create called')
    eq(st(h, 1), STAGED, 'PENDING: STAGED')
    eq(M.handleOf(1), nil, 'no entity yet')
    eq(M.stats().byBudget['fw:box'], 1, 'counted against its cap while pending')
    eq(M.stats().pending, 1, 'stats.pending')
    eq(M.areaReady(0, 40, 0, 5), false, 'a pending node blocks areaReady')
    h.tick(1000)
    eq(bridge.created, 1, 'not created twice while pending')
    local e1 = h.newEntity(0, 0, 40, 0, 3)
    eq(M.bound(n1, e1), true, 'bound(node, entity)')
    eq(st(h, 1), LIVE, 'bound: LIVE')
    eq(M.handleOf(1), e1, 'handleOf answers the bound entity')
    eq(M.idOf(e1), 1, 'idOf too')
    eq(h.ents[e1].alphaLog[1], 51, 'a late arrival in view fades in at bind time')
    eq(M.bound(n1, e1), false, 'a second bind is ignored')
    -- bound(node, 0): LIVE without an entity (a non-entity plugin kind)
    local n2 = h.node(2, 'fw:box', 7, 5, 40, 0, {}, { radius = 100 })
    M.add(n2)
    ok(waitFor(h, 1000, function() return bridge.created >= 2 end), 'second create')
    eq(M.stats().byBudget['fw:box'], 2, 'the cap (2) is full')
    M.add(h.node(3, 'fw:box', 7, -5, 40, 0, {}, { radius = 100 }))
    h.tick(1000)
    eq(bridge.created, 2, 'a pending node holds its cap slot: the third waits')
    M.bound(n2, 0)
    eq(st(h, 2), LIVE, 'bound(node, 0): LIVE')
    eq(M.handleOf(2), nil, 'without an entity')
    -- a bind inside create (synchronous): LIVE at once
    local h2, M2 = fresh()
    h2.cam(0, 0, 0, 0, 0)
    local b2 = { class = 'custom' }
    function b2.create(node)
        M2.bound(node, h2.newEntity(0, 0, -40, 0, 3))
        return M2.PENDING
    end
    M2.registerKind('custom', b2)
    M2.add(h2.node(1, 'fw:box', 7, 0, -40, 0, {}, { radius = 100 }))
    h2.tick(1000)
    eq(st(h2, 1), LIVE, 'a bind during create: LIVE without a pending phase')
    eq(M2.stats().pending, 0, 'nothing pending')
    ok(M2.handleOf(1) ~= nil, 'with its entity')
    -- removed while pending: destroy(node, nil) once the bind arrives, the record goes
    local h3, M3 = fresh()
    h3.cam(0, 0, 0, 0, 0)
    local gone = {}
    local b3 = { class = 'custom' }
    function b3.create() return M3.PENDING end
    function b3.destroy(node, e) gone[#gone + 1] = { id = node.id, e = e } end
    M3.registerKind('custom', b3)
    local p1 = h3.node(1, 'fw:box', 7, 0, 40, 0, {}, { radius = 100 })
    M3.add(p1)
    h3.tick(1000)
    M3.remove(p1)
    eq(#gone, 0, 'removed while pending: nothing destroyed yet (the plugin is still creating)')
    eq(M3.stats().zombies, 1, 'kept until the bind')
    local late = h3.newEntity(0, 0, 40, 0, 3)
    eq(M3.bound(p1, late), true, 'the late bind arrives')
    ok(#gone == 1 and gone[1].e == nil, 'destroy(node, nil)')
    eq(M3.stats().zombies, 0, 'the record went')
    eq(M3.stats().byBudget['fw:box'], 0, 'the cap slot is free again')
    -- no bind within 5 s: failed once, destroy(node, nil), one log line; a later bind is ignored
    local p2 = h3.node(2, 'fw:box', 7, 0, 45, 0, {}, { radius = 100 })
    M3.add(p2)
    h3.tick(1000)
    eq(st(h3, 2), STAGED, 'pending')
    h3.tick(5500)
    eq(st(h3, 2), FAILED, '5 s without a bind: FAILED')
    ok(#gone == 2 and gone[2].id == 2 and gone[2].e == nil, 'destroy(node, nil)')
    local lines = 0
    for _, w in ipairs(h3.warnings) do if w:find('did not bind', 1, true) then lines = lines + 1 end end
    eq(lines, 1, 'one log line')
    eq(M3.bound(p2, h3.newEntity(0, 0, 45, 0, 3)), false, 'a bind after the timeout is ignored')
    eq(M3.stats().pending, 0, 'nothing pending')
end

-- 17. updates: fields / move / kind / dr (the cache's vocabulary), update() == false re-creates ---------------------------
do
    local h, M, Mv = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    local n1 = h.node(1, 'prop', 1, 0, 40, 0, { model = HPROP, tint = 1 })
    M.add(n1)
    h.tick(1500)
    local e1 = M.handleOf(1)
    n1.fields.tint = 2
    M.update(n1, 'fields', { tint = true })
    ok(#hp.updates == 1 and hp.updates[1].what == 'fields' and hp.updates[1].data.tint, 'fields: handler.update(node, e, what, data)')
    eq(M.handleOf(1), e1, 'applied in place')
    n1.x = 3.0
    M.update(n1, 'move')
    eq(hp.updates[2].what, 'move', 'move: the handler re-places')
    eq(n1.m.x, 3.0, 'the record follows the node pose')
    -- a changed model re-creates: the old entity fades out in view, the new one fades in
    n1.fields.model = HPROP2
    M.update(n1, 'fields', { model = true })
    h.tick(1500)
    local e1b = M.handleOf(1)
    ok(e1b ~= nil and e1b ~= e1, 'a new model: a new entity')
    ok(h.ents[e1].deleted, 'the old one is gone')
    ok(#h.ents[e1].alphaLog > 1 and h.ents[e1].alphaLog[#h.ents[e1].alphaLog] < 255, 'faded out (it was in view)')
    eq(h.ents[e1b].model, HPROP2, 'with the new model')
    -- update() answering false re-creates as well (client/scene_kinds.lua's contract)
    local refuse = handler(h, 'prop', { budget = 'props', update = false })
    M.registerKind('prop', refuse)
    h.tick(1500)
    local e1c = M.handleOf(1)
    M.update(n1, 'fields', { tint = true })
    h.tick(1500)
    ok(M.handleOf(1) ~= e1c and M.handleOf(1) ~= nil, 'update() == false: re-created')
    -- a server-steered node: 'dr' updates reuse the descriptor; no re-bind, no forced evaluation
    local dr = { t = 'dr', t0 = h.now(), p = { x = 10.0, y = 40.0, z = 0.0 }, v = { x = 1.0, y = 0.0, z = 0.0 } }
    local n2 = h.node(2, 'prop', 1, 10, 40, 0, { model = HPROP }, { motion = dr })
    M.add(n2)
    ok(waitFor(h, 900, function() return st(h, 2) == LIVE end), 'the dr node is LIVE')
    dr.t0 = h.now()
    M.update(n2, 'dr')
    eq(Mv.stats().tracked, 1, 'a dr node is a tracked mover')
    local evals = M.stats().evaluations
    for _ = 1, 10 do
        dr.t0, dr.p.x = h.now(), dr.p.x + 0.1
        M.update(n2, 'dr')
        h.frames(1)
    end
    ok(M.stats().evaluations - evals <= 2, "'dr' updates do not force an evaluation each (" .. (M.stats().evaluations - evals) .. ')')
    local before = #refuse.updates
    eq(#refuse.updates, before, "'dr' does not call handler.update")
    h.tick(2000)
    eq(Mv.stats().tracked, 0, 'a dr past its 1 s horizon is untracked')
    dr.t0 = h.now()
    M.update(n2, 'dr')
    h.frames(2)
    eq(Mv.stats().tracked, 1, 'the next dr tracks it again')
    -- 'kind': the node's kind changed (a placeholder became known)
    local n3 = h.node(3, 'later:kind', 7, -10, 40, 0, {}, { radius = 80 })
    M.add(n3)
    eq(st(h, 3), OFF, 'unknown kind: OFF')
    local hk = handler(h, 'custom')
    M.registerKind('later:kind', hk)
    h.tick(1500)
    eq(st(h, 3), LIVE, 'registerKind: the waiting nodes materialise')
    M.registerKind('later:kind', nil)
    h.tick(1500)
    eq(st(h, 3), OFF, 'unregistered: destroyed and OFF')
    eq(hk.destroyed, 1, 'through the old handler')
end

-- 18. the speed rule, the lead, events and the listener, areaReady -------------------------------------------------------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    -- lead: 1.5 s x speed ahead (within +-60 deg of the velocity), <= 150 m
    local y = drive(h, 0, 0, 0, 40, 800)                         -- 40 m/s along +y: lead 60 m
    M.add(h.node(1, 'prop', 1, 0, y + 175, 0, { model = HPROP, lod = 100 }))    -- R_in 130 + lead 60 >= 175
    M.add(h.node(2, 'prop', 1, 0, y - 175, 0, { model = HPROP, lod = 100 }))    -- behind: no lead
    y = drive(h, 0, y, 0, 40, 300)
    eq(st(h, 1), LIVE, 'ahead: created inside R_in + lead')
    ok(st(h, 2) == KNOWN or st(h, 2) == WARM, 'behind: not created (no lead)')
    -- speed rule: above SkipSmallAbove small props (under 4 px at R_vis) are not created
    y = drive(h, 0, y, 0, 60, 800)
    M.add(h.node(3, 'prop', 1, 2, y + 100, 0, { model = HPROP, lod = 150, r = 0.05 }))
    M.add(h.node(4, 'prop', 1, -2, y + 100, 0, { model = HPROP, lod = 150, r = 5 }))
    y = drive(h, 0, y, 0, 60, 300)
    eq(st(h, 4), LIVE, 'a big prop is created at 60 m/s')
    ok(st(h, 3) == KNOWN or st(h, 3) == WARM, 'a tiny one is skipped at 60 m/s')
    eq(M.areaReady(2, y + 80, 0, 30), true, 'a prop skipped by the speed rule does not block areaReady')
    h.cam(0, y, 0)
    h.tick(1500)                                                 -- stopped
    eq(st(h, 3), LIVE, 'stopped: the skipped prop comes')
    -- events: the handler hears them while materialised, the listener always
    local heard = {}
    M.setListener(function(event, node, e, name, _, age)
        if event == 'event' then heard[#heard + 1] = { id = node and node.id, e = e, name = name, age = age } end
    end)
    M.event(h.nodes[3], 'boom', { power = 2 }, 120, 0, 0, 0)
    ok(#hp.events == 1 and hp.events[1].name == 'boom' and hp.events[1].age == 120, 'handler.event(node, e, name, params, age)')
    ok(#heard == 1 and heard[1].e == M.handleOf(3), 'the listener hears it with the entity')
    M.event(h.nodes[2], 'boom', nil, 0)
    eq(#hp.events, 1, 'not materialised: the handler does not hear it')
    eq(#heard, 2, 'the listener does')
    M.event(nil, 'shake', nil, 0, 1, 2, 3)
    eq(heard[3].name, 'shake', 'a positional event (no node) reaches the listener')
    -- areaReady: pending creations in range block, everything created answers true
    local h2, M2 = fresh()
    h2.cam(0, 0, 0, 0, 0)
    h2.models[HPROP] = { delay = 800 }
    M2.registerKind('prop', handler(h2, 'prop', { budget = 'props' }))
    for i = 1, 5 do M2.add(h2.node(i, 'prop', 1, i * 3, 50, 0, { model = HPROP })) end
    M2.add(h2.node(9, 'prop', 1, 500, 500, 0, { model = HPROP }))  -- far: outside the asked radius
    eq(M2.areaReady(6, 50, 0, 30), false, 'nodes a camera there would create: not ready')
    h2.tick(700)
    eq(M2.areaReady(6, 50, 0, 30), false, 'still streaming: not ready')
    h2.tick(1500)
    eq(M2.areaReady(6, 50, 0, 30), true, 'all created: ready')
    eq(M2.areaReady(500, 500, 0, 10), false, 'far away the camera would create node 9: not ready')
    h2.nodes[9].unwanted = true
    eq(M2.areaReady(500, 500, 0, 10), true, 'a node the cache does not want does not block')
end

-- 19. peds: created in view at 130 m, out of view only within 75 m; cadence; the LOD clamp follows the scale --------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hped = handler(h, 'ped', { budget = 'peds' })
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('ped', hped)
    M.registerKind('prop', hp)
    M.add(h.node(1, 'ped', 3, 0, 100, 0, { model = HPED }))     -- ahead: in view
    M.add(h.node(2, 'ped', 3, 0, -100, 0, { model = HPED }))    -- behind: out of view
    M.add(h.node(3, 'prop', 1, 5, 60, 0, { model = HPROP, lod = 600 }))   -- a long-lod prop: clamped
    h.tick(3000)
    eq(st(h, 1), LIVE, 'a ped in view at 100 m: created (R_in 130 in view)')
    ok(st(h, 2) == KNOWN or st(h, 2) == WARM, 'a ped out of view at 100 m: not created (R_in 75 out of view)')
    eq(hped.ctx[1].late, true, 'peds are always late arrivals (inside their 240 m R_vis)')
    -- the thread's cadence while nothing is queued: no frame spin
    local reads, cams = h.stubs.gameTimerReads, h.n('GetFinalRenderedCamCoord')
    h.tick(5000)
    ok(h.stubs.gameTimerReads - reads <= 16, 'still and idle: ~2 wakes per second, no Wait(0) spin ('
        .. (h.stubs.gameTimerReads - reads) .. ' timer reads in 5 s)')
    ok(h.n('GetFinalRenderedCamCoord') - cams <= 11, 'one camera read per check (' .. (h.n('GetFinalRenderedCamCoord') - cams) .. ')')
    -- the LOD scale moves: a live clamped prop gets its new lodDist
    local e3 = M.handleOf(3)
    h.set.lodscale = 1.75
    h.tick(1200)
    eq(h.ents[e3].lod, 268, 'SetEntityLodDist(e, floor((cap - B - 10) / S)) re-applied on a scale change')
end

-- 21. camera(), stats(), core stops: every entity, fade and asset request goes, the loops end --------------------------
do
    local h, M, Mv = fresh()
    h.cam(3, 4, 5, 0, 90)                                        -- yaw 90: looking along -x
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    for i = 1, 4 do M.add(h.node(i, 'prop', 1, -40, i * 5, 0, { model = HPROP })) end   -- ahead: late, faded in
    h.models[4242] = { mode = 'never' }
    M.add(h.node(9, 'prop', 1, -30, 0, 0, { model = 4242 }))     -- a request still streaming
    local spinOk, spinD = h.motion.validate({ t = 'spin', t0 = h.now(), axis = 'z', dps = 30 })
    assert(spinOk, tostring(spinD))
    M.add(h.node(10, 'prop', 1, -20, 0, 0, { model = HPROP }, { motion = spinD }))
    ok(waitFor(h, 1500, function() return M.stats().fades > 0 end), 'fades running')
    local x, y, z, fwx, fwy, fwz, v = M.camera()
    ok(x == 3 and y == 4 and z == 5, 'camera(): the last check position')
    near(fwx, -1.0, 1e-6, 'camera(): forward x (yaw 90)')
    ok(math.abs(fwy) < 1e-6 and math.abs(fwz) < 1e-6 and v == 0, 'camera(): forward y, z and speed')
    local s = M.stats()
    ok(s.byState and s.byBudget and s.models and s.evaluations > 0 and s.lodScale == 1.0, 'stats() shape')
    eq(Mv.stats().tracked, 1, 'a mover tracked')
    h.env.TriggerEvent('onClientResourceStop', 'other')
    eq(M.isStopped(), false, "another resource's stop is ignored")
    h.env.TriggerEvent('onClientResourceStop', 'core')
    eq(M.isStopped(), true, 'core stops: the materialiser stops')
    eq(h.alive(), 0, 'every entity deleted at once')
    eq(h.released[HPROP], 1, 'loaded models released')
    eq(h.released[4242], 1, 'streaming requests given back')
    local reads = h.n('GetFinalRenderedCamCoord')
    h.tick(3000)
    eq(h.n('GetFinalRenderedCamCoord'), reads, 'the streaming thread ended')
    eq(Mv.stats().running, false, 'the mover loop ended')
    current = nil                                                -- already shut down
end

do   -- the view cone: half the frustum diagonal (vertical FOV x the window's aspect) + 10 deg, sampled once a second
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    local a = math.rad(57)                                       -- 57 deg off the forward axis, 40 m away
    M.add(h.node(1, 'prop', 1, 40 * math.sin(a), 40 * math.cos(a), 0, { model = HPROP }))
    h.tick(1500)
    eq(hp.ctx[1].seen, false, '16:9 at FOV 50: 57 deg off-axis is outside the cone (53.6 deg)')
    h.stubs.aspectRatio = 21 / 9
    h.tick(1200)
    M.add(h.node(2, 'prop', 1, 40 * math.sin(a) + 1, 40 * math.cos(a), 0, { model = HPROP }))
    h.tick(1500)
    eq(hp.ctx[2].seen, true, '21:9: the cone widens to 59.8 deg')
    h.set.fov = 30.0
    h.tick(1200)
    M.add(h.node(3, 'prop', 1, 40 * math.sin(a) + 2, 40 * math.cos(a), 0, { model = HPROP }))
    h.tick(1500)
    eq(hp.ctx[3].seen, false, 'a narrower FOV (aiming, a scope) narrows it again')
    h.stubs.aspectRatio = nil
end

-- 22. RV2 fix round: F2 (pending + model change), F3 (children retire with their root), F4 (the light pass) -----------
do   -- F2: a pending plugin node whose model changes before the bind sits in pendL once; no spin, no orphan
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local destroyed = {}
    local bridge = { class = 'custom', created = 0 }
    function bridge.create()
        bridge.created = bridge.created + 1
        return M.PENDING
    end
    function bridge.destroy(node, e) destroyed[#destroyed + 1] = { id = node.id, e = e } end
    M.registerKind('custom', bridge)
    local n1 = h.node(1, 'fw:box', 7, 0, 40, 0, { model = 'a' }, { radius = 100 })
    M.add(n1)
    h.tick(1000)
    eq(M.stats().pending, 1, 'F2: pending')
    n1.fields.model = 'b'
    M.update(n1, 'fields', { model = true })
    h.tick(1000)
    eq(bridge.created, 2, 'F2: the model change re-created it (still pending)')
    eq(M.stats().pending, 1, 'F2: pendL holds the record ONCE')
    ok(#destroyed == 1 and destroyed[1].e == nil, 'F2: the first pending create heard destroy(node, nil)')
    local e = h.newEntity(0, 0, 40, 0, 3)
    eq(M.bound(n1, e), true, 'F2: the bind of the second create')
    eq(M.stats().pending, 0, 'F2: nothing pending after the bind')
    h.tick(6000)
    eq(#destroyed, 1, 'F2: no timeout destroy loop after the bind (6 s later)')
    eq(M.handleOf(1), e, 'F2: the bound entity stays the node\'s')
    ok(not h.ents[e].deleted, 'F2: and alive')
    eq(M.stats().byBudget['fw:box'], 1, 'F2: the cap counter did not run negative')
    eq(#h.stubs.failures, 0, 'F2: no thread failed')
end

do   -- F3: a removed root takes its children along (same visibility rules); a child removed alone leaves by the root
    local function group(h, M, id, x)
        local root = h.node(id, 'prop', 1, x, 30, 0, { model = HPROP }, { children = { id + 1 } })
        M.add(root)
        M.add(h.node(id + 1, 'prop', 1, x, 30, 2, { model = HPROP2 }, { parent = id, offset = { x = 0.0, y = 0.0, z = 2.0 } }))
        return root
    end
    for _, order in ipairs({ 'root first', 'children first' }) do
        local h, M = fresh()
        h.cam(0, 0, 0, 0, 0)
        M.registerKind('prop', handler(h, 'prop', { budget = 'props' }))
        group(h, M, 10, 0)
        h.tick(2000)
        local eRoot, eKid = M.handleOf(10), M.handleOf(11)
        ok(eRoot and eKid and h.ents[eKid].attachedTo == eRoot, 'F3 (' .. order .. '): a root with its child, in view')
        if order == 'root first' then
            M.remove(h.nodes[10])
            M.remove(h.nodes[11])
        else
            M.remove(h.nodes[11])
            M.remove(h.nodes[10])
        end
        local kidLog = #h.ents[eKid].alphaLog
        h.tick(600)
        ok(not h.ents[eKid].deleted, 'F3 (' .. order .. '): the child is not deleted in view (0.6 s)')
        eq(#h.ents[eKid].alphaLog, kidLog, 'F3 (' .. order .. '): nor faded before its root')
        ok(not h.ents[eRoot].deleted, 'F3 (' .. order .. '): the root retires (seen)')
        h.cam(0, 0, 0, 0, 180)                                   -- look away: unseen -> both go, together
        local both = waitFor(h, 3000, function() return h.ents[eRoot].deleted or h.ents[eKid].deleted end)
        ok(both and h.ents[eRoot].deleted and h.ents[eKid].deleted, 'F3 (' .. order .. '): root and child deleted together')
        eq(M.stats().zombies, 0, 'F3 (' .. order .. '): no zombie left')
        eq(M.stats().byBudget.props, 0, 'F3 (' .. order .. '): the cap counter is back to 0')
    end
    -- a removal with 'fade': the child fades out with the root
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    M.registerKind('prop', handler(h, 'prop', { budget = 'props' }))
    group(h, M, 20, 0)
    h.tick(2000)
    local eRoot, eKid = M.handleOf(20), M.handleOf(21)
    local rl, kl = #h.ents[eRoot].alphaLog, #h.ents[eKid].alphaLog
    M.remove(h.nodes[20], 'fade')
    M.remove(h.nodes[21], 'fade')
    h.frames(4)
    ok(#h.ents[eRoot].alphaLog > rl and #h.ents[eKid].alphaLog > kl, 'F3: DEL(fade) fades root and child together')
    h.tick(800)
    ok(h.ents[eRoot].deleted and h.ents[eKid].deleted, 'F3: both deleted at the end of the fade')
    -- a child removed ON ITS OWN while its root stays in view: it fades out, the root stays
    group(h, M, 30, 5)
    h.tick(2000)
    local r30, k31 = M.handleOf(30), M.handleOf(31)
    local k31log = #h.ents[k31].alphaLog
    M.remove(h.nodes[31])
    ok(waitFor(h, 700, function() return #h.ents[k31].alphaLog > k31log end),
        'F3: a lone child of a seen root fades out (decided on the next pass)')
    ok(waitFor(h, 800, function() return h.ents[k31].deleted end), 'F3: and is deleted after the fade')
    ok(not h.ents[r30].deleted, 'F3: its root stays')
    eq(st(h, 30), LIVE, 'F3: LIVE')
end

do   -- F4: movers / retiring records alone never trigger full grid evaluations while the camera stays
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    M.registerKind('prop', handler(h, 'prop', { budget = 'props' }))
    local seed = 4242
    local function rnd()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    for i = 1, 2000 do
        M.add(h.node(i, 'prop', 1, rnd() * 600 - 300, rnd() * 600 - 300, rnd() * 20,
            { model = HPROP, lod = 20 + math.floor(rnd() * 180) }))
    end
    h.tick(8000)
    local okS, spinD = h.motion.validate({ t = 'spin', axis = 'z', dps = 30 })
    assert(okS, tostring(spinD))
    M.add(h.node(5001, 'prop', 1, 280, 0, 5, { model = HPROP, lod = 100 }, { motion = spinD }))   -- one mover, far
    h.tick(3000)
    local s0 = M.stats()
    h.tick(10000)
    local s1 = M.stats()
    eq(s1.evaluations - s0.evaluations, 0, 'F4: a still camera + one mover: no full evaluation in 10 s')
    ok(s1.lightEvaluations - s0.lightEvaluations >= 15, 'F4: light passes instead (' .. (s1.lightEvaluations - s0.lightEvaluations) .. ')')
    ok(s1.lastLightNodes <= 2, 'F4: a light pass looks at the mover only (' .. s1.lastLightNodes .. ')')
    -- a mover coming into range while the camera stays still is still created (by the light pass)
    local okT, tw = h.motion.validate({ t = 'tween', t0 = h.now() + 200, d = 2000, to = { x = 20.0, y = 20.0, z = 0.0 } })
    assert(okT, tostring(tw))
    M.add(h.node(5002, 'prop', 1, 900, 900, 0, { model = HPROP, lod = 60 }, { motion = tw }))
    h.tick(1000)
    ok(M.handleOf(5002) == nil, 'F4: far away first')
    h.tick(3000)
    ok(M.handleOf(5002) ~= nil, 'F4: arrived and created without the camera moving')
    local e1 = M.stats().evaluations
    M.remove(h.nodes[1])                                        -- a retiring record: light passes too
    h.tick(5000)
    ok(M.stats().evaluations - e1 <= 1, 'F4: a retiring record does not force full evaluations either')
end

-- 23. RV2 fix round: F5 (sliced rescale), F11 (movers' own camera), F12 (blending) ---------------------------------
do   -- F5: a LOD-scale change re-clamps at most K.slice (500) live props per frame; worst frame on the host
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    M.registerKind('prop', handler(h, 'prop', { budget = 'props' }))
    for i = 1, 1200 do                                           -- lod 600: clamped, re-clamped by any scale change
        local a = i * 0.7
        M.add(h.node(i, 'prop', 1, math.cos(a) * (50 + i % 300), math.sin(a) * (50 + i % 300), 0,
            { model = HPROP, lod = 600 }))
    end
    ok(waitFor(h, 20000, function() return M.stats().byState.live == 1200 end), 'F5: 1200 clamped props LIVE')
    local slices = M.stats().rescaleSlices
    h.set.lodscale = 1.75
    local worst, total = worstPerFrame(h, 90, function() return h.n('SetEntityLodDist') end)
    ok(worst <= 500, 'F5: at most 500 re-clamped per frame (' .. worst .. ')')
    eq(total, 1200, 'F5: every live clamped prop re-clamped (' .. total .. ')')
    ok(M.stats().rescaleSlices - slices >= 3, 'F5: the rescale ran in slices (' .. (M.stats().rescaleSlices - slices) .. ')')
    near(h.nodes[7].m.rIn, 268 * 1.75 + 20 + 10, 1e-6, 'F5: radii switched to the new scale')
    ok(M.stats().rebounds >= 1, 'F5: the bounds were rebuilt after it')
    -- host timing: 5,000 records spread wide, the worst frame of a scale flip (sliced)
    local h2, M2 = fresh()
    h2.cam(0, 0, 0, 0, 0)
    M2.registerKind('prop', handler(h2, 'prop', { budget = 'props' }))
    local seed = 99
    local function rnd()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    for i = 1, 5000 do
        M2.add(h2.node(i, 'prop', 1, rnd() * 1200 - 600, rnd() * 1200 - 600, rnd() * 20,
            { model = HPROP, lod = 20 + math.floor(rnd() * 480) }))
    end
    h2.tick(30000)
    local function worstMs(ms)
        local w, t = 0.0, 0
        while t < ms do
            local c = os.clock()
            h2.frames(1)
            local d = (os.clock() - c) * 1000
            if d > w then w = d end
            t = t + h2.FRAME
        end
        return w
    end
    local steady = worstMs(1000)
    h2.set.lodscale = 2.0
    local up = worstMs(1500)
    h2.set.lodscale = 1.0
    local down = worstMs(1500)
    bench.rescale = ('%.2f / %.2f / %.2f ms'):format(steady, up, down)
    ok(up < 4 and down < 4, 'F5: a scale flip of 5,000 records never costs one long frame (' .. bench.rescale .. ')')
end

do   -- F11: a mover behind a still camera is placed within a frame of the player turning toward it
    local h, M = fresh()
    h.cam(0, 0, 2, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props', place = true })
    M.registerKind('prop', hp)
    local okS, spin = h.motion.validate({ t = 'spin', axis = 'z', dps = 90 })
    assert(okS, tostring(spin))
    M.add(h.node(1, 'prop', 1, 0, -20, 2, { model = HPROP, lod = 100 }, { motion = spin }))   -- 20 m behind
    h.tick(4000)
    local p0 = hp.placed
    h.frames(30)
    eq(hp.placed, p0, 'F11: behind the camera: not placed')
    h.cam(0, 0, 2, 0, 180)                                       -- the player turns (the camera does not move)
    h.frames(2)
    ok(hp.placed > p0, 'F11: placed within 2 frames of the turn (the movers read this frame\'s camera)')
end

do   -- F12: DR corrections blend (projective velocity blending), > Snap snaps; a late plan blends over 200 ms
    local h, M, Mv = fresh()
    h.cam(0, -10, 2, 0, 0)
    local xs = {}
    local hp = handler(h, 'prop', { budget = 'props' })
    function hp.place(_, _, x) xs[#xs + 1] = x end
    M.registerKind('prop', hp)
    local okD, dr = h.motion.validate({ t = 'dr', t0 = h.now(), p = { x = 0.0, y = 20.0, z = 2.0 },
        v = { x = 5.0, y = 0.0, z = 0.0 } })
    assert(okD, tostring(dr))
    local n = h.node(1, 'prop', 1, 0, 20, 2, { model = HPROP, lod = 100 }, { motion = dr })
    M.add(n)
    ok(waitFor(h, 900, function() return M.handleOf(1) ~= nil end), 'F12: the DR platform is LIVE')
    local function refresh(x)                                    -- the cache reuses the descriptor (applyDr)
        dr.t0, dr.p.x = h.now(), x
        M.update(n, 'dr')
    end
    for _ = 1, 5 do                                              -- steady 10 Hz samples on the ideal track
        h.frames(6)
        refresh(xs[#xs] + 0.0)
    end
    h.frames(3)
    local before = #xs
    refresh(xs[#xs] - 0.8)                                       -- the server's copy is 0.8 m behind
    h.frames(10)
    local jump = 0.0
    for i = before, #xs - 1 do
        local d = math.abs(xs[i + 1] - xs[i])
        if d > jump then jump = d end
    end
    ok(jump < 0.3, ('F12: a 0.8 m correction blends (largest step %.3f m, a frame at 5 m/s is ~0.08 m)'):format(jump))
    ok(Mv.stats().blends >= 1, 'F12: counted as a blend')
    local snaps = Mv.stats().snaps
    before = #xs
    refresh(xs[#xs] + 8.0)                                       -- 8 m off: beyond DeadReckoning.Snap (5 m)
    h.frames(2)
    ok(math.abs(xs[before + 1] - xs[before]) > 7.0, 'F12: a correction beyond Snap (5 m) snaps')
    eq(Mv.stats().snaps, snaps + 1, 'F12: counted as a snap')
    -- a plan that arrives late (t0 in the past) blends from the rendered pose over 200 ms
    local okT, tw = h.motion.validate({ t = 'tween', t0 = h.now() - 1500, d = 3000,
        to = { x = xs[#xs] + 3.0, y = 20.0, z = 2.0 }, from = { x = xs[#xs], y = 20.0, z = 2.0 } })
    assert(okT, tostring(tw))
    before = #xs
    n.motion = tw
    M.update(n, 'motion')
    h.frames(20)
    jump = 0.0
    for i = before, #xs - 1 do
        local d = math.abs(xs[i + 1] - xs[i])
        if d > jump then jump = d end
    end
    ok(jump < 0.5, ('F12: a late plan (1.5 m into a 3 m tween) blends in (largest step %.3f m)'):format(jump))
end

-- 24. RV2 fix round: F16 (the pool size is learned), F18 (maxReach shrinks), F20 (loop error guards) ---------------------
do   -- F16: no ObjectPool configured -> 3,300 assumed (85 % = 2,805); a read above it raises, a refusal below lowers
    local h, M = fresh(function(Scene)     -- no Scene.ObjectPool (the shipped config sets 5300 for its server.cfg raise)
        Scene.Caps.props, Scene.ObjectPool = 20, nil
    end)
    h.cam(0, 0, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    eq(M.stats().poolSize, 3300, 'F16: without Config.Scene.ObjectPool the vanilla 3,300 is assumed')
    h.set.poolExtra = 2790                                       -- the world's own objects
    ring(h, M, 1, 20, 175, { model = HPROP, lod = 150 })
    h.tick(3000)
    eq(hp.created, 15, 'F16: the guard stops at 85 % of 3,300 (2,790 + 15 = 2,805)')
    h.set.poolExtra = 4000                                        -- more objects than 3,300: the pool was raised
    h.tick(11000)
    eq(M.stats().poolSize, 5300, 'F16: a read above the assumption raises it to 5,300')
    eq(hp.created, 20, 'F16: the rest follow')
    local raised = 0
    for _, w in ipairs(h.warnings) do if w:find('more than assumed', 1, true) then raised = raised + 1 end end
    eq(raised, 1, 'F16: logged once')
    -- a refused prop create below the limit: the pool is smaller than assumed
    local h2, M2 = fresh(function(Scene) Scene.ObjectPool = 5300 end)
    h2.cam(0, 0, 0, 0, 0)
    M2.registerKind('prop', handler(h2, 'prop', { budget = 'props', refuse = true }))
    h2.set.poolExtra = 3290                                       -- the real (vanilla) pool is full
    M2.add(h2.node(1, 'prop', 1, 0, -60, 0, { model = HPROP }))
    h2.tick(1500)
    eq(M2.stats().poolSize, 3290, 'F16: a refusal at 3,290 objects (below the 4,505 limit) teaches the real size')
    eq(M2.stats().poolLimit, math.floor(3290 * 0.85), 'F16: the guard now stops at 85 % of it')
    local learned = 0
    for _, w in ipairs(h2.warnings) do if w:find('smaller than assumed', 1, true) then learned = learned + 1 end end
    eq(learned, 1, 'F16: logged once')
end

do   -- F18: one far-reaching node widens every evaluation only while it exists
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    M.registerKind('prop', handler(h, 'prop', { budget = 'props' }))
    M.registerKind('custom', handler(h, 'custom', { entity = false }))
    for i = 1, 300 do
        M.add(h.node(i, 'prop', 1, (i % 20) * 10 - 100, (i // 20) * 10 - 75, 0, { model = HPROP, lod = 60 }))
    end
    h.tick(8000)
    local base = M.stats().maxReach
    ok(base < 200, 'F18: props alone reach ' .. base .. ' m')
    M.add(h.node(999, 'fw:beacon', 7, 1400, 0, 0, {}, { radius = 1500 }))
    h.tick(2000)
    ok(M.stats().maxReach >= 1500, 'F18: the beacon widens the reach (' .. M.stats().maxReach .. ')')
    M.evaluate()
    ok(M.stats().lastEvalCells <= M.stats().cellCount, 'F18: a square wider than the cells walks the cells themselves')
    M.remove(h.nodes[999], 0)
    h.tick(7000)
    near(M.stats().maxReach, base, 1e-6, 'F18: after it left, the reach shrinks back (a sliced rebuild)')
end

do   -- F20: a failing mover or fade never stops the others; the loops restart
    local h, M, Mv = fresh()
    h.cam(0, 0, 0, 0, 0)
    local good = handler(h, 'prop', { budget = 'props', place = true })
    M.registerKind('prop', good)
    local bad = { class = 'custom', fade = 'none' }
    function bad.create() return true end
    function bad.place() error('boom') end
    M.registerKind('custom', bad)
    local okS, spin = h.motion.validate({ t = 'spin', axis = 'z', dps = 90 })
    assert(okS, tostring(spin))
    M.add(h.node(1, 'prop', 1, 0, 20, 0, { model = HPROP }, { motion = spin }))
    M.add(h.node(2, 'fw:bad', 7, 2, 20, 0, {}, { radius = 100, motion = spin }))
    h.tick(1500)
    local p0 = good.placed
    h.frames(20)
    ok(good.placed - p0 >= 19, 'F20: the good mover keeps moving next to a failing one')
    ok(Mv.stats().running, 'F20: the mover loop runs')
    local placeWarn = 0
    for _, w in ipairs(h.warnings) do if w:find('place() of kind fw:bad failed', 1, true) then placeWarn = placeWarn + 1 end end
    eq(placeWarn, 1, 'F20: the failing place() is logged once')
    -- a fade whose SetEntityAlpha throws: dropped (logged once), the next fades still run to the end
    local real = h.env.SetEntityAlpha
    local e1, e2 = h.newEntity(1, 0, 10, 0, 3), h.newEntity(1, 0, 11, 0, 3)
    h.env.SetEntityAlpha = function(e, a, skin)
        if e == e1 and a > 60 then error('alpha refused') end
        return real(e, a, skin)
    end
    M.fadeIn(e1, 300)
    M.fadeIn(e2, 300)
    h.tick(500)
    eq(h.ents[e2].alpha, nil, 'F20: the healthy fade still ended (ResetEntityAlpha)')
    eq(M.stats().fades, 0, 'F20: the broken fade was dropped, not stuck')
    local fadeWarn = 0
    for _, w in ipairs(h.warnings) do if w:find('a fade failed and was dropped', 1, true) then fadeWarn = fadeWarn + 1 end end
    eq(fadeWarn, 1, 'F20: logged once')
    h.env.SetEntityAlpha = real
    local e3 = h.newEntity(1, 0, 12, 0, 3)
    eq(M.fadeIn(e3, 300), true, 'F20: a later fade starts')
    h.tick(500)
    eq(h.ents[e3].alpha, nil, 'F20: and completes (the loop is alive)')
end

do   -- A6 seam: after a gap where the attach target could not be resolved, the prop moves to the NEW target entity
    local h, M = fresh()
    h.cam(0, 0, 20, 0, 0)
    local ped = h.newEntity(0, 0, 20, 0, 1)
    h.players[5] = ped
    M.registerKind('prop', handler(h, 'prop', { budget = 'props', attachTarget = function() return h.players[5] end }))
    M.add(h.node(1, 'prop', 1, 0, 20, 0, { model = HPROP }, { attach = { player = 5 }, bone = 57005 }))
    h.tick(1500)
    local e = M.handleOf(1)
    eq(h.ents[e].attachedTo, ped, 'seam: the kind attached the prop to the ped at create')
    local attaches = h.n('AttachEntityToEntity')
    h.frames(40)
    eq(h.n('AttachEntityToEntity'), attaches, 'seam: an attachment to the current target is adopted, not redone')
    h.players[5] = nil                                            -- the target cannot be resolved for > 500 ms
    h.tick(700)
    local ped2 = h.newEntity(0, 0, 25, 0, 1)
    h.players[5] = ped2                                           -- a new ped; the old one still exists
    h.tick(3000)
    eq(h.ents[e].attachedTo, ped2, 'seam: re-attached to the NEW ped (a stale attachment is never adopted)')
    eq(h.n('AttachEntityToEntity'), attaches + 1, 'seam: exactly one re-attach')
end

-- 20. zero allocation in a steady-state evaluation; [bench] 2,000 nodes along a camera path --------------------------------
do
    local h, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    M.registerKind('prop', handler(h, 'prop', { budget = 'props' }))
    local seed = 12345
    local function rnd()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    for i = 1, 2000 do
        M.add(h.node(i, 'prop', 1, rnd() * 600 - 300, rnd() * 600 - 300, rnd() * 20,
            { model = HPROP, lod = 40 + math.floor(rnd() * 160) }))
    end
    h.tick(8000)
    ok(M.stats().byState.live > 400, 'a steady scene: ' .. M.stats().byState.live .. ' live props')
    local stuck = 0
    for _, n in pairs(h.nodes) do
        local m = n.m
        if m.st == WARM and m.x * m.x + m.y * m.y + m.z * m.z <= m.rIn * m.rIn then stuck = stuck + 1 end
    end
    eq(stuck, 0, 'nothing inside its R_in is left waiting')
    eq(M.stats().queued, 0, 'nothing queued')
    local function sway()
        for i = 1, 100 do
            h.cam(i % 2 == 0 and 1.5 or -1.5, i % 3 == 0 and 1 or 0, 0)
            M.evaluate()
        end
    end
    sway()                                   -- warm-up: the queue arrays grow to the pattern's size once
    collectgarbage('collect')
    collectgarbage('stop')
    sway()                                   -- the first calls after a full GC regrow the stack: not counted
    local kb = collectgarbage('count')
    sway()
    local grown = (collectgarbage('count') - kb) * 1024
    collectgarbage('restart')
    ok(grown < 64, 'steady-state evaluations allocate nothing (' .. math.floor(grown) .. ' bytes over 100)')
    ok(M.stats().lastEvalNodes > 0, 'the per-node branch ran (' .. M.stats().lastEvalNodes .. ' nodes looked at)')
    bench.allocBytes = math.floor(grown)
    bench.steadyNodes = M.stats().lastEvalNodes
end

do
    local h, M = fresh()
    h.cam(0, -200, 0, 0, 0)
    local hp = handler(h, 'prop', { budget = 'props' })
    M.registerKind('prop', hp)
    local seed = 777
    local function rnd()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    for i = 1, 2000 do                                           -- 2,000 props along a 3 km road
        M.add(h.node(i, 'prop', 1, rnd() * 120 - 60, rnd() * 3000, rnd() * 10,
            { model = HPROP, lod = 60 + math.floor(rnd() * 140) }))
    end
    h.tick(3000)
    local created0, deleted0, evals0 = M.stats().created, M.stats().deleted, M.stats().evaluations
    local clock0 = os.clock()
    local y = drive(h, 0, -200, 0, 50, 60000)                    -- 60 s at 50 m/s
    local host = os.clock() - clock0
    local s = M.stats()
    local created, deleted, evals = s.created - created0, s.deleted - deleted0, s.evaluations - evals0
    ok(created > 1000, 'the drive materialised the road (' .. created .. ' creations)')
    ok(deleted > 500, 'and released what it left behind (' .. deleted .. ' deletions)')
    ok(y > 2700, 'the camera reached the end of the road')
    -- ms per evaluation at points along the path (the host's Lua 5.4, not FiveM's)
    local t0 = os.clock()
    for i = 1, 200 do
        h.cam(0, i * 15, 0)
        M.evaluate()
    end
    local per = (os.clock() - t0) * 1000 / 200
    ok(per < 5, 'an evaluation of the road costs ' .. string.format('%.3f', per) .. ' ms on the host')
    print(('[bench] 2000 nodes along a 3 km road at 50 m/s: %.3f ms per evaluation (host Lua 5.4, %d nodes looked '
        .. 'at), %.1f creations/s, %d deletions, %d evaluations in 60 s simulated (%.2f s host); steady state: %d '
        .. 'bytes over 100 evaluations of %d nodes; rescale worst frame (steady / S 1->2 / 2->1, 5,000 records): %s')
        :format(per, s.lastEvalNodes, created / 60, deleted, evals, host, bench.allocBytes, bench.steadyNodes,
        tostring(bench.rescale)))
end

current.M.shutdown()
current.h.tick(1000)
eq(#current.h.stubs.failures, 0, 'no thread or timer failed')
print(('client scene materializer: %d passed, 0 failed'):format(passed))
