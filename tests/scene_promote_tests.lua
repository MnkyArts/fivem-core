--[[
    core/tests/scene_promote_tests.lua — offline suite for Core.Scene promotion (DESIGN §55.15; §55.19 rows
    core:scene:report and core:scene:props).

        lua5.4 tests/scene_promote_tests.lua    (from the resource directory, or from tests/)

    Server: server/scene_promote.lua on tests/scene_server_harness.lua (the real scene_kinds / scene_store /
    scene.lua, recording fakes of R.index / R.interest) — policies, every trigger and its refusals, the spawn worker
    (existence wait, bucket, orphan mode, state bags), budgets, the demote conditions, the props callback, the snap
    rule, the delayed 'ours' delete, reused handles, leases, onDestroyed, removals, core stop.
    Client: client/scene_promote.lua on tests/client_scene_harness.lua with the REAL materialiser, kinds and movers
    — the pending poll, swap vs fade, clone timeout, the hidden demotion copy and its reveal frame, the enter watch
    and TaskEnterVehicle, the damage event, snCfg (control + net-id guard), the props callback.
]]

local here = (arg and arg[0] or 'tests/scene_promote_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local H = dofile(here .. '/scene_server_harness.lua')
H.name = 'scene promote'
local stubs, check, eq, calls, reset = H.stubs, H.check, H.eq, H.calls, H.reset
local v3 = stubs.vector3

local P0 = { x = 100.0, y = 200.0, z = 30.0 }
local function at(dx, dy, dz) return { x = P0.x + (dx or 0), y = P0.y + (dy or 0), z = P0.z + (dz or 0) } end
local function errOf(...) return select(2, ...) end

--------------------------------------------------------------------------------
-- server harness additions: the natives the harness lacks, a PlayerGrid and subscriber fakes
--------------------------------------------------------------------------------

local W                                           -- the current server world's knobs and records

--- A core server VM with the scene files and server/scene_promote.lua. promote = Config.Scene.Promote overrides.
local function server(promote)
    local env, Core, R = H.newServer({ config = function(Config)
        for k, v in pairs(promote or {}) do Config.Scene.Promote[k] = v end
    end })
    W = { rot = {}, vel = {}, owners = {}, subs = {}, created = {}, colours = {}, frozen = {}, rotSet = {} }
    local function made(kind, rec, x, y, z, heading)
        local e = stubs.newEntity(kind, rec)
        stubs.coords[e] = v3(x, y, z)
        stubs.headings[e] = heading or 0.0
        W.created[#W.created + 1] = e
        return e
    end
    env.CreatePed = function(pedType, model, x, y, z, heading, net, host)
        return made(1, { model = model, pedType = pedType, net = net, host = host }, x, y, z, heading)
    end
    env.CreateObjectNoOffset = function(model, x, y, z, net, host, dynamic)
        return made(3, { model = model, net = net, host = host, dynamic = dynamic }, x, y, z)
    end
    env.SetEntityRotation = function(e, rx, ry, rz, order, p5) W.rotSet[e] = { rx, ry, rz, order, p5 } end
    env.GetEntityRotation = function(e)
        local r = W.rot[e]
        return r and v3(r[1], r[2], r[3]) or v3(0.0, 0.0, stubs.headings[e] or 0.0)
    end
    env.GetEntityVelocity = function(e)
        local v = W.vel[e]
        return v and v3(v[1], v[2], v[3]) or v3(0.0, 0.0, 0.0)
    end
    env.NetworkGetEntityOwner = function(e) return W.owners[e] or -1 end
    env.SetVehicleColours = function(e, a, b) W.colours[e] = { a, b } end
    env.FreezeEntityPosition = function(e, on) W.frozen[e] = on end
    -- the clone's bucket (SetEntityRoutingBucket raises onEntityBucketChange like FXServer: synchronously) and the
    -- synced damage the monitor samples (W.wear[e] = { engine, body, tank, dirt, burst = { [wheel] = 1|2 } })
    W.wear, W.bucketEvents = {}, 0
    env.GetEntityRoutingBucket = function(e) return stubs.entities[e] and stubs.entities[e].bucket or 0 end
    local setBucket = env.SetEntityRoutingBucket
    env.SetEntityRoutingBucket = function(e, b)
        local old = stubs.entities[e] and stubs.entities[e].bucket or 0
        setBucket(e, b)
        W.bucketEvents = W.bucketEvents + 1
        env.TriggerEvent('onEntityBucketChange', e, b, old)
    end
    local function wear(e) return W.wear[e] or {} end
    env.GetVehicleEngineHealth = function(e) return wear(e).engine or 1000.0 end
    env.GetVehicleBodyHealth = function(e) return wear(e).body or 1000.0 end
    env.GetVehiclePetrolTankHealth = function(e) return wear(e).tank or 1000.0 end
    env.GetVehicleDirtLevel = function(e) return wear(e).dirt or 0.0 end
    env.IsVehicleTyreBurst = function(e, wheel, completely)
        local s = (wear(e).burst or {})[wheel]
        return (completely and s == 2) or (not completely and s == 1)   -- the server's exact status match
    end
    Core.PlayerGrid = { candidates = function(_, _, out)
        local n = 0
        for i = 1, #stubs.connected do
            n = n + 1
            out[n] = stubs.connected[i]
        end
        return n
    end }
    R.interest.subscribers = function(bucket, grid, key) return W.subs[bucket .. ':' .. grid .. ':' .. key] end
    stubs.loadFile(env, 'server/scene_promote.lua')
    stubs.loadFile(env, 'server/scene_promote_api.lua')
    return env, Core, R
end

--- A vehicle node at `pos` (a root in a near cell; node.cell is the real index's job: set here).
local function vehicle(Core, R, pos, extra)
    local def = { kind = 'vehicle', model = 'adder', pos = pos or P0, rot = { x = 0, y = 0, z = 90 } }
    for k, v in pairs(extra or {}) do def[k] = v end
    local id = assert(Core.Scene.spawn(def))
    local node = R.store.get(id)
    local x, y = node.pos.x, node.pos.y
    node.cell = { grid = 0, key = R.index.keyOf(0, x, y) }
    return id, node
end

--- Marks the node's near cell as subscribed by `src` on `ring`.
local function subscribe(node, src, ring)
    local key = (node.bucket or 0) .. ':0:' .. node.cell.key
    W.subs[key] = W.subs[key] or {}
    W.subs[key][src] = ring or 1
end

local function clone(R, id) local p = R.promote.get(id) return p and p.entity end
local function state(env, e) return stubs.entityState(env, e) end
local function exists(e) return stubs.entities[e] ~= nil and stubs.entities[e].exists == true end
local function sentOf(name)
    local out = {}
    for _, s in ipairs(stubs.sent) do if s.name == name then out[#out + 1] = s end end
    return out
end
--- Answers the pending core:scene:props request of `src` (the lib's response event) with `props`.
local function answerProps(env, src, props)
    local req = sentOf('core:cb:req:core:scene:props')
    local last = req[#req]
    if not last then return false end
    stubs.triggerOn(env, 'core:cb:res:core:scene:props', src, last.args[1], true, props)
    return true
end
--- Ticks in 100 ms steps until node `id`'s promotion reaches `phase` (nil = gone); false after `maxMs`.
local function until_(R, id, phase, maxMs)
    for _ = 1, (maxMs or 30000) // 100 do
        local p = R.promote.get(id)
        if (p and p.phase) == phase then return true end
        stubs.tick(100)
    end
    local p = R.promote.get(id)
    return (p and p.phase) == phase
end

--------------------------------------------------------------------------------
-- S1. load order, policies (class default → kind → node), eligibility
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    check(type(PM) == 'table' and PM.promote and PM.demote and PM.lease and PM.onInteract and PM.refuses,
        'R.promote carries the scene.lua delegates and the interaction hooks')
    eq(errOf(Scene.promote(424242)), 'missing', 'Scene.promote delegates: an unknown id is missing')
    -- the file asserts it follows scene.lua
    local env2 = stubs.newEnv('server', 'core')
    stubs.loadImport(env2)
    env2.Core.SceneRuntime = { store = {} }
    local okLoad, errLoad = pcall(stubs.loadFile, env2, 'server/scene_promote.lua')
    check(not okLoad and tostring(errLoad):find('right after server/scene.lua', 1, true) ~= nil,
        'loading before scene.lua asserts')
    local vid = vehicle(Core, R)
    local pol = PM.policy(R.store.get(vid))
    check(pol.cls == 'vehicle' and pol.mode == 'promote' and pol.proximity == 20 and pol.enter and pol.damage
        and pol.prox, 'vehicle default: promote, proximity 20, enter, damage')
    check(pol.restMs == 3000 and pol.idleMs == 20000 and pol.onDestroyed == 'keep', 'defaults restMs / idleMs / keep')
    local prop = assert(Scene.spawn({ kind = 'prop', model = 'prop_bench_01a', pos = at(5) }))
    local pp = PM.policy(R.store.get(prop))
    check(pp.cls == 'prop' and pp.mode == 'local' and not pp.prox and not pp.damage and not pp.enter, 'prop: local')
    local ped = assert(Scene.spawn({ kind = 'ped', model = 'a_m_y_skater_01', pos = at(8) }))
    check(PM.policy(R.store.get(ped)).mode == 'local' and not PM.policy(R.store.get(ped)).prox, 'ped: local')
    local phys = assert(Scene.spawn({ kind = 'prop', model = 'prop_barrel_01a', pos = at(9),
        fields = { physics = 'promote' } }))
    local ph = PM.policy(R.store.get(phys))
    check(ph.damage and not ph.prox and not ph.enter, 'a prop with physics = promote promotes on damage')
    Scene.set(phys, { physics = 'static' })
    check(not PM.policy(R.store.get(phys)).damage, 'the cache follows a physics change')
    local mk = assert(Scene.spawn({ kind = 'marker', pos = at(3) }))
    check(PM.policy(R.store.get(mk)).none, 'a marker has no policy (not an entity class)')
    eq(errOf(Scene.promote(mk)), 'class', 'promoting a marker: class')
    -- a node override: actions, networked, restMs; a plugin kind's authority
    local over = assert(Scene.spawn({ kind = 'ped', model = 'a_m_y_skater_01', pos = at(12),
        authority = { actions = { 'talk', 'buy' }, mode = 'networked', proximity = 8, restMs = 0,
            onDestroyed = 'remove' } }))
    local po = PM.policy(R.store.get(over))
    check(po.actions.talk and po.actions.buy and po.mode == 'networked' and po.proximity == 8 and po.prox
        and po.restMs == 0 and po.onDestroyed == 'remove', 'node.authority overrides the class default')
    check(Scene.defineKind({ id = 'dealer:car', class = 'vehicle', fields = { { name = 'model', type = 'model',
        kinds = { 'vehicle' }, required = true } }, authority = { proximity = 5, damage = false } }), 'plugin kind')
    local dk = assert(Scene.spawn({ kind = 'dealer:car', model = 'adder', pos = at(20) }))
    local pk = PM.policy(R.store.get(dk))
    check(pk.cls == 'vehicle' and pk.proximity == 5 and not pk.damage and pk.enter, 'kind.authority over the class')
    local dk2 = assert(Scene.spawn({ kind = 'dealer:car', model = 'adder', pos = at(24),
        authority = { enter = false } }))
    check(not PM.policy(R.store.get(dk2)).enter and PM.policy(R.store.get(dk2)).proximity == 5,
        'node over kind over class')
    -- eligibility
    local child = assert(Scene.spawn({ kind = 'prop', model = 'prop_bench_01a', parent = vid,
        offset = { x = 0, y = 0, z = 1 } }))
    eq(errOf(Scene.promote(child)), 'parent', 'a child rides its root: parent')
    local att = assert(Scene.spawn({ kind = 'prop', model = 'prop_bench_01a', pos = at(30) }))
    stubs.connectPlayer(env, 1, { coords = v3(P0.x, P0.y, P0.z), joining = false })
    Scene.attach(att, { player = 1 })
    eq(errOf(Scene.promote(att)), 'attach', 'an attached node: attach')
    eq(errOf(H.as('someone', 'promote', vid)), 'owner', 'another resource may not promote a core node')
end

--------------------------------------------------------------------------------
-- S2. the spawn worker: natives by class, existence wait, bucket / orphan / state bags, op, hook; failures
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local vid, node = vehicle(Core, R, P0, { bucket = 7, fields = { plate = 'SCN 1', locked = true } })
    local heard = {}
    Scene.on('promoted', vid, function(copy, netId) heard[#heard + 1] = { copy.id, netId } end)
    stubs.spawnDelayMs = 300
    reset()
    local ver0 = node.ver
    eq(Scene.promote(vid), true, 'Scene.promote queues')
    eq(PM.get(vid).phase, 'spawning', 'the worker waits for the entity to exist')
    eq(node.promoted, nil, 'nothing is promoted before the entity exists')
    eq(#calls('changed', vid), 0, 'no op while spawning')
    eq(Scene.promote(vid), true, 'a second request while spawning is a no-op')
    eq(#W.created + 0, 0, 'vehicles come from CreateVehicleServerSetter (not the ped / object stubs)')
    stubs.tick(400)
    local e = clone(R, vid)
    local rec = stubs.entities[e]
    check(rec and rec.type == 2 and rec.vehType == 'automobile' and rec.model == env.GetHashKey('adder'),
        'CreateVehicleServerSetter(hash, vtype from the model-info chain, …)')
    check(stubs.coords[e].x == P0.x and stubs.coords[e].y == P0.y and stubs.headings[e] == 90.0,
        'created at the node pose, heading = rz')
    eq(rec.bucket, 7, 'SetEntityRoutingBucket to the node bucket')
    eq(rec.orphanMode, 2, 'SetEntityOrphanMode(e, 2)')
    local st = state(env, e)
    eq(st.sn, vid, 'state bag sn = id')
    eq(st.snv, node.ver, 'state bag snv = the promoted ver')
    check(node.ver > ver0, 'the promotion bumped the ver')
    check(type(st.snCfg) == 'table' and st.snCfg.plate == 'SCN 1' and type(st.snCfg.once) == 'table'
        and st.snCfg.once.locked == true and st.snCfg.locked == nil,
        'snCfg carries the config (the lock in the one-shot part)')
    local p1, p2 = Scene.paintOf(vid)
    check(p1 ~= nil and p1 == Scene.PAINTS[vid % #Scene.PAINTS + 1][1], 'the shared lib/scene paint list')
    check(st.snCfg.paint and st.snCfg.paint[1] == p1 and W.colours[e] and W.colours[e][1] == p1
        and W.colours[e][2] == p2,
        'no props colours: the stable paint (bag + SetVehicleColours)')
    eq(rec.plate, 'SCN 1', 'SetVehicleNumberPlateText')
    eq(rec.lockState, 2, 'SetVehicleDoorsLocked(e, 2) when locked')
    check(node.promoted and node.promoted.netId == rec.netId and node.promoted.entity == e
        and node.promoted.trigger == 'manual' and node.promoted.since ~= nil,
        'node.promoted = { netId, entity, since, trigger }')
    local ch = calls('changed', vid)
    check(#ch == 1 and ch[1].what == 'promote' and ch[1].data == rec.netId and ch[1].ver == node.ver,
        'R.index.changed(node, "promote", netId) after the bump')
    check(#heard == 1 and heard[1][1] == vid and heard[1][2] == rec.netId, 'hook promoted (copy, netId)')
    eq(Scene.get(vid).promoted.netId, rec.netId, 'Scene.get shows the netId')
    stubs.spawnDelayMs = 0
    -- props with colours: no stable paint
    local v2 = vehicle(Core, R, at(40), { fields = { props = { colorPrimary = 12, colorSecondary = 3 } } })
    Scene.promote(v2)
    local e2 = clone(R, v2)
    check(state(env, e2).snCfg.paint == nil and W.colours[e2] == nil, 'props with colours keep theirs')
    eq(state(env, e2).snCfg.props.colorPrimary, 12, 'snCfg.props')
    -- a ped and a prop
    local ped = assert(Scene.spawn({ kind = 'ped', model = 'a_m_y_skater_01', pos = at(0, 30),
        rot = { x = 0, y = 0, z = 45 },
        fields = { scenario = 'WORLD_HUMAN_SMOKING' } }))
    Scene.promote(ped)
    local pe = clone(R, ped)
    local pr = stubs.entities[pe]
    check(pr.type == 1 and pr.pedType == 4 and pr.net == true and pr.host == true and stubs.headings[pe] == 45,
        'CreatePed(4, hash, x, y, z, heading, true, true)')
    local pc = state(env, pe).snCfg
    check(pc.scenario == 'WORLD_HUMAN_SMOKING' and pc.frozen == true and pc.invincible == true and pc.blockEvents,
        'ped snCfg: scenario, frozen, invincible, blockEvents')
    eq(W.frozen[pe], true, 'a frozen ped: FreezeEntityPosition RPC')
    local prop = assert(Scene.spawn({ kind = 'prop', model = 'prop_bench_01a', pos = at(0, 40),
        rot = { x = 10, y = 0, z = 30 } }))
    Scene.promote(prop)
    local oe = clone(R, prop)
    local orec = stubs.entities[oe]
    check(orec.type == 3 and orec.net == true and orec.host == true and orec.dynamic == false,
        'CreateObjectNoOffset(hash, x, y, z, true, true, dynamic = false for a frozen prop)')
    local rs = W.rotSet[oe]
    check(rs and rs[1] == 10 and rs[3] == 30 and rs[4] == 2 and rs[5] == false,
        'SetEntityRotation(e, rx, ry, rz, 2, false)')
    check(state(env, oe).snCfg.rot.x == 10 and state(env, oe).snCfg.frozen == true, 'prop snCfg: rot, frozen')
    local phys = assert(Scene.spawn({ kind = 'prop', model = 'prop_barrel_01a', pos = at(0, 44),
        fields = { physics = 'promote' } }))
    Scene.promote(phys)
    eq(stubs.entities[clone(R, phys)].dynamic, true, 'physics = promote: a dynamic object')
    -- failures: a refused create, an entity that never appears, a removal while spawning
    local before = PM.stats().slots
    stubs.spawnFails = true
    local vf = vehicle(Core, R, at(0, 60))
    eq(Scene.promote(vf), true, 'queued')
    check(PM.get(vf) == nil and R.store.get(vf).promoted == nil and PM.stats().refused.create == 1,
        'CreateVehicleServerSetter answered 0: released, counted')
    eq(PM.stats().slots, before, 'its budget slot is back')
    stubs.spawnFails = false
    stubs.spawnDelayMs = 60000
    local vt = vehicle(Core, R, at(0, 70))
    Scene.promote(vt)
    local te = clone(R, vt)
    stubs.tick(5100)
    check(PM.get(vt) == nil and PM.stats().refused.timeout == 1 and state(env, te).sn == nil,
        'no entity within 5 s: released, never configured')
    local vr = vehicle(Core, R, at(0, 80))
    Scene.promote(vr)
    local re = clone(R, vr)
    stubs.spawnDelayMs = 0
    Scene.remove(vr)
    eq(PM.get(vr), nil, 'removed while spawning: released at once')
    stubs.entities[re].exists = true
    stubs.tick(100)
    check(not exists(re), 'the worker deletes the entity once it exists (the one unchecked delete)')
end

--------------------------------------------------------------------------------
-- S3. budgets: MaxEntities (queued ones count), MaxPropsPerArea per 256 m square; gated nodes
--------------------------------------------------------------------------------
do
    local _, Core, R = server({ MaxEntities = 3, MaxPropsPerArea = 2 })
    local PM, Scene = R.promote, Core.Scene
    local function prop(dx, dy)
        return assert(Scene.spawn({ kind = 'prop', model = 'prop_bench_01a', pos = at(dx, dy) }))
    end
    local a, b, c = prop(1, 1), prop(2, 2), prop(3, 3)
    eq(Scene.promote(a), true, 'first prop')
    eq(Scene.promote(b), true, 'second prop in the square')
    eq(errOf(Scene.promote(c)), 'area', 'a third prop in the same 256 m square: area')
    local far = prop(300, 0)
    eq(Scene.promote(far), true, 'another square has its own budget')
    local v = vehicle(Core, R, at(0, 20))
    eq(errOf(Scene.promote(v)), 'limit', 'MaxEntities 3 reached: limit')
    eq(PM.stats().refused.limit, 1, 'counted')
    eq(PM.stats().refused.area, 1, 'counted (area)')
    Scene.demote(a)
    stubs.tick(10)
    eq(PM.get(a), nil, 'demoted')
    eq(Scene.promote(c), true, 'the square has room again')
    Scene.demote(far)
    stubs.tick(10)
    eq(Scene.promote(v), true, 'and the server-wide budget too')
    local gated = assert(Scene.spawn({ kind = 'vehicle', model = 'adder', pos = at(0, 50),
        audience = { players = { 1 } } }))
    eq(PM.stats().slots, 3, 'three slots in use')
    Scene.demote(v)
    stubs.tick(10)
    eq(Scene.promote(gated), true, 'a gated node is promoted manually (the owner decides)')
end

--------------------------------------------------------------------------------
-- S4. proximity: 1 Hz, near cells with near-ring subscribers, PlayerGrid candidates, exact distance, on foot
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local vid, node = vehicle(Core, R)
    local src = H.player(env, 1, at(50, 0, 0))
    eq(PM.stats().proximityNodes, 1, 'the spawn put the vehicle into the proximity set (the index tap)')
    stubs.tick(2000)
    eq(PM.get(vid), nil, 'nobody near: not promoted')
    H.movePlayer(src, at(10, 0, 0))
    stubs.tick(2000)
    eq(PM.get(vid), nil, 'near, but the cell has no subscribers: not promoted')
    subscribe(node, src, 2)
    stubs.tick(2000)
    eq(PM.get(vid), nil, 'a far-ring subscriber only: not promoted')
    subscribe(node, src, 1)
    stubs.pedVehicle[stubs.peds[src]] = 9999
    stubs.tick(2000)
    eq(PM.get(vid), nil, 'a driving player does not promote (mode promote: on foot)')
    stubs.pedVehicle[stubs.peds[src]] = nil
    stubs.buckets[src] = 3
    stubs.tick(2000)
    eq(PM.get(vid), nil, 'a player in another bucket does not count')
    stubs.buckets[src] = 0
    H.movePlayer(src, at(19, 0, 5))
    local natives = stubs.entityCoordReads
    stubs.tick(1050)
    check(PM.get(vid) ~= nil and PM.get(vid).trigger == 'proximity' and PM.get(vid).by == src,
        'within 20 m on foot: promoted within a second (trigger proximity, by src)')
    check(stubs.entityCoordReads - natives <= 4, 'one sweep reads a handful of positions')
    -- a node with mode networked counts drivers; a prop (local) is never in the set
    local net = assert(Scene.spawn({ kind = 'prop', model = 'prop_bench_01a', pos = at(0, 60),
        authority = { mode = 'networked', proximity = 15 } }))
    local nn = R.store.get(net)
    nn.cell = { grid = 0, key = R.index.keyOf(0, nn.pos.x, nn.pos.y) }
    subscribe(nn, src, 1)
    H.movePlayer(src, at(0, 50, 0))
    stubs.pedVehicle[stubs.peds[src]] = 9999
    stubs.tick(1100)
    check(PM.get(net) ~= nil, 'mode networked: a player in a vehicle within 15 m promotes it')
    assert(Scene.spawn({ kind = 'prop', model = 'prop_bench_01a', pos = at(0, 70) }))
    eq(PM.stats().proximityNodes, 2, 'a local prop never enters the proximity set')
    -- the set loses removed nodes lazily
    Scene.remove(vid)
    stubs.tick(1100)
    eq(PM.stats().proximityNodes, 1, 'a removed node leaves the set at its next slice')
    -- a gated vehicle is not promoted by proximity
    local g = assert(Scene.spawn({ kind = 'vehicle', model = 'adder', pos = at(0, 90),
        audience = { players = { 1 } } }))
    local gn = R.store.get(g)
    gn.cell = { grid = 0, key = R.index.keyOf(0, gn.pos.x, gn.pos.y) }
    subscribe(gn, src, 1)
    stubs.pedVehicle[stubs.peds[src]] = nil
    H.movePlayer(src, at(0, 92, 0))
    stubs.tick(2100)
    eq(PM.get(g), nil, 'gated nodes are never promoted by a trigger')
end

--------------------------------------------------------------------------------
-- S5. core:scene:report: what, data, node, 500 ms per (player, node, what), bucket / audience, distance, policy
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local function rep(src, id, what, data) stubs.triggerOn(env, 'core:scene:report', src, id, what, data) end
    local a = H.player(env, 1, at(7, 0, 0))
    local b = H.player(env, 2, at(0, 0, 0))
    local v1 = vehicle(Core, R)
    rep(a, v1, 'enter')
    eq(PM.get(v1), nil, 'enter from 7 m: refused (6 m)')
    stubs.tick(300)
    H.movePlayer(a, at(5, 0, 0))
    rep(a, v1, 'enter')
    eq(PM.get(v1), nil, 'the same (player, node, what) within 500 ms: dropped')
    stubs.tick(300)
    rep(a, v1, 'enter')
    check(PM.get(v1) ~= nil and PM.get(v1).trigger == 'enter' and PM.get(v1).by == a, 'enter from 5 m: promoted')
    eq(PM.stats().reports.enter, 1, 'counted')
    local v2 = vehicle(Core, R, at(0, 40))
    stubs.tick(300)
    rep(b, v2, 'damaged')
    check(PM.get(v2) ~= nil and PM.get(v2).trigger == 'damage', 'damaged from 40 m: promoted')
    local v3n = vehicle(Core, R, at(0, 100))
    stubs.tick(300)
    rep(b, v3n, 'damaged')
    eq(PM.get(v3n), nil, 'damaged from 100 m: refused (60 m)')
    local prop = assert(Scene.spawn({ kind = 'prop', model = 'prop_bench_01a', pos = at(1) }))
    stubs.tick(300)
    rep(b, prop, 'damaged')
    eq(PM.get(prop), nil, 'a prop without damage in its policy: refused')
    local v4 = vehicle(Core, R, at(-2))
    stubs.tick(300)
    rep(b, v4, 'bogus')
    stubs.tick(300)
    rep(b, v4, 'enter', { blob = string.rep('x', 300) })
    eq(PM.get(v4), nil, 'an unknown what and data over 256 B: refused')
    stubs.tick(300)
    rep(b, v4, 'enter', { note = 'small' })
    check(PM.get(v4) ~= nil, 'a valid enter with small data: promoted')
    local v5 = vehicle(Core, R, at(-4), { authority = { enter = false } })
    stubs.tick(300)
    rep(b, v5, 'enter')
    eq(PM.get(v5), nil, 'the policy says no enter: refused')
    local v6 = vehicle(Core, R, at(-3))
    stubs.buckets[b] = 5
    stubs.tick(300)
    rep(b, v6, 'enter')
    eq(PM.get(v6), nil, 'a player of another bucket: refused')
    stubs.buckets[b] = 0
    local g = vehicle(Core, R, at(-3.5), { audience = { players = { a } } })
    stubs.tick(300)
    rep(b, g, 'enter')
    eq(PM.get(g), nil, 'a gated node the player may not see: refused')
    H.allows[b] = true
    stubs.tick(300)
    rep(b, g, 'enter')
    eq(PM.get(g), nil, 'a gated node is never promoted by a report either')
    -- Core.Net.on: 250 ms per player (<= 4/s)
    local v7, v8 = vehicle(Core, R, at(-1)), vehicle(Core, R, at(-1.5))
    stubs.tick(300)
    rep(b, v7, 'enter')
    rep(b, v8, 'enter')
    check(PM.get(v7) ~= nil and PM.get(v8) == nil, 'a second report of the player inside 250 ms is dropped')
    -- the dead 'rest' report path is gone (RV6 note: no client sent it; the 1 Hz monitor decides), and 'applied'
    -- has its own event: through core:scene:report both change nothing
    local e1 = clone(R, v1)
    W.owners[e1] = a
    stubs.tick(300)
    local cfg1 = state(env, e1).snCfg
    rep(a, v1, 'rest')
    stubs.tick(300)
    rep(a, v1, 'applied')
    check(PM.stats().reports.rest == nil and PM.get(v1).phase == 'live' and state(env, e1).snCfg == cfg1
        and PM.stats().reports.applied == 0, "core:scene:report 'rest' / 'applied' from the owner: ignored")
end

--------------------------------------------------------------------------------
-- S6. interactions (actions promote; leases refuse others on promoted nodes) and leases
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local a = H.player(env, 1, at(1, 0, 0))
    local b = H.player(env, 2, at(-1, 0, 0))
    local ped = assert(Scene.spawn({ kind = 'ped', model = 'a_m_y_skater_01', pos = P0,
        interact = { { action = 'talk', distance = 3 }, { action = 'look', distance = 3 } },
        authority = { actions = { 'talk' } } }))
    H.interact(env, a, ped, 'look')
    eq(PM.get(ped), nil, 'an action outside the policy does not promote')
    stubs.tick(300)
    H.interact(env, a, ped, 'talk')
    check(PM.get(ped) ~= nil and PM.get(ped).trigger == 'action' and PM.get(ped).by == a,
        'an accepted interaction with a policy action promotes (scene.lua → R.promote.onInteract)')
    local node = R.store.get(ped)
    -- leases
    eq(errOf(Scene.lease(424242, a)), 'missing', 'lease: missing node')
    eq(errOf(Scene.lease(ped, 77)), 'src', 'lease: an unknown player')
    eq(errOf(Scene.lease(ped, a, -5)), 'ms', 'lease: bad ms')
    local s1 = Scene.lease(ped, a)
    check(type(s1) == 'number', 'the first lease wins: a sequence number')
    eq(errOf(Scene.lease(ped, b)), 'leased', 'another player: leased')
    eq(Scene.lease(ped, a, 5000, s1), s1, 'the holder renews with its seq')
    eq(Scene.lease(ped, a), s1, 'the holder renews without a seq')
    eq(errOf(Scene.lease(ped, a, 5000, s1 + 7)), 'stale', 'a stale seq is refused')
    eq(errOf(H.as('someone', 'lease', ped, a)), 'owner', 'another resource may not lease a core node')
    check(PM.refuses(b, node, 'talk') and not PM.refuses(a, node, 'talk'),
        'refuses(): others, while leased and promoted')
    local unpromoted = assert(Scene.spawn({ kind = 'ped', model = 'a_m_y_skater_01', pos = at(0, 5) }))
    Scene.lease(unpromoted, a)
    check(not PM.refuses(b, R.store.get(unpromoted), 'x'), 'refuses(): only promoted nodes')
    eq(errOf(Scene.lease(ped, b, 0)), 'leased', 'only the holder releases')
    eq(Scene.lease(ped, a, 0), s1, 'the holder releases (ms = 0)')
    eq(errOf(Scene.lease(ped, a, 0)), 'none', 'nothing left to release')
    eq(errOf(Scene.lease(ped, b, 5000, s1)), 'stale', 'a renewal of an ended lease is stale')
    local s2 = Scene.lease(ped, b, 1000)
    check(s2 and s2 > s1, 'a new lease, a new sequence number')
    stubs.tick(1100)
    local s3 = Scene.lease(ped, a)
    check(s3 and s3 > s2, 'an expired lease is free for the next player')
    stubs.dropPlayer(env, a)
    eq(PM.refuses(b, node, 'talk'), false, 'a dropped holder loses its leases')
    eq(Scene.lease(ped, b) ~= nil, true, 'and the node is free')
end

--------------------------------------------------------------------------------
-- S7. demotion: rest / idle / occupant / lease conditions, the props callback, the snap rule, the delayed delete
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local a = H.player(env, 1, at(10, 0, 0))
    local vid, node = vehicle(Core, R)
    Scene.promote(vid)
    local e = clone(R, vid)
    local netId = node.promoted.netId
    W.owners[e] = a
    local heard = 0
    local info
    Scene.on('demoted', vid, function(_, i) heard, info = heard + 1, i end)
    stubs.tick(30000)
    check(PM.get(vid) and PM.get(vid).phase == 'live', 'a player within 20 m: stays promoted')
    H.movePlayer(a, at(80, 0, 0))
    W.vel[e] = { 1.0, 0, 0 }
    stubs.tick(30000)
    check(PM.get(vid).phase == 'live', 'moving (1 m/s > RestSpeed): stays promoted')
    W.vel[e] = { 0.01, 0, 0 }
    stubs.vehicleSeats[e] = { [2] = 777 }
    stubs.tick(30000)
    check(PM.get(vid).phase == 'live', 'an occupant (seat 2): stays promoted')
    stubs.vehicleSeats[e] = nil
    local seq = Scene.lease(vid, a, 60000)
    stubs.tick(30000)
    check(PM.get(vid).phase == 'live', 'leased: stays promoted')
    Scene.lease(vid, a, 0, seq)
    -- the clone came to rest 3.1 m away and turned: a new rest pose
    stubs.coords[e] = v3(P0.x + 3.0, P0.y + 1.0, P0.z - 0.2)
    W.rot[e] = { 1.0, -0.5, 120.0 }
    reset()
    stubs.sent = {}
    stubs.tick(21000)
    eq(PM.get(vid).phase, 'demoting', 'at rest, nobody near for idleMs, no occupant, no lease: demoting')
    local req = sentOf('core:cb:req:core:scene:props')
    check(#req == 1 and req[1].target == a and req[1].args[2] == netId, 'props asked from the clone owner (netId)')
    eq(node.promoted ~= nil, true, 'still promoted while the props are read')
    answerProps(env, a, { colorPrimary = 5, colorSecondary = 7, bodyHealth = 870.5, extras = { ['1'] = true } })
    eq(PM.get(vid), nil, 'demoted')
    eq(node.promoted, nil, 'node.promoted cleared')
    check(node.pos.x == P0.x + 3.0 and node.pos.y == P0.y + 1.0 and node.rot.z == 120.0,
        'the rest pose (the node follows its clone: R.store.follow)')
    check(node.fields.props.bodyHealth == 870.5 and node.fields.props.colorPrimary == nil
        and node.fields.props.extras == nil, 'the read-back: only the wear whitelist, never colours / extras (RV4 F1)')
    local tr = H.trace()
    check(tr:find('changed:' .. vid .. ':follow', 1, true) and tr:find('changed:' .. vid .. ':set', 1, true)
        and tr:find('changed:' .. vid .. ':demote', 1, true), 'index: follow, set, then demote (' .. tr .. ')')
    check(type(info) == 'table' and info.reason == 'rest' and info.destroyed == false and info.pos.x == P0.x + 3.0
        and info.bucket == 0 and type(info.wear) == 'table' and info.wear.bodyHealth == 870.5,
        'hook demoted(copy, info): reason, destroyed, pose, bucket, wear')
    local last = calls('changed', vid)
    eq(last[#last].what, 'demote', 'the demote op is the last change')
    eq(heard, 1, 'hook demoted')
    check(exists(e), 'the clone stays until DeleteDelayMs')
    stubs.tick(450)
    check(exists(e), 'still there at 450 ms')
    stubs.tick(100)
    check(not exists(e), 'deleted 500 ms after the op')
    eq(PM.stats().slots, 0, 'the budget slot is back')
    -- within 0.2 m / 2°: snap back to the authored pose (no move)
    Scene.promote(vid)
    local e2 = clone(R, vid)
    local px, py = node.pos.x, node.pos.y
    stubs.coords[e2] = v3(px + 0.1, py, node.pos.z + 0.05)
    W.rot[e2] = { node.rot.x + 1.0, node.rot.y, node.rot.z - 1.5 }
    reset()
    stubs.sent = {}
    stubs.tick(22100)
    eq(PM.get(vid), nil, 'demoted without an owner client (a server-owned clone)')
    eq(#sentOf('core:cb:req:core:scene:props'), 0, 'no owner: no props asked')
    check(node.pos.x == px and node.pos.y == py and #calls('changed', vid) == 1,
        'within 0.2 m / 2°: the pre-promotion pose (no follow op, no props: the one-shot wear was never applied)')
    -- a reused handle is never deleted: the entity at the handle is not ours any more
    stubs.tick(10)
    Scene.promote(vid)
    local e3 = clone(R, vid)
    Scene.demote(vid)
    stubs.tick(10)
    state(env, e3).sn = 999
    stubs.tick(600)
    check(exists(e3), 'the delayed delete skips an entity whose sn is not the node (handles are reused)')
    state(env, e3).sn = vid
    Scene.promote(vid)
    local e4 = clone(R, vid)
    Scene.demote(vid)
    stubs.tick(10)
    state(env, e4).snv = 123456
    stubs.tick(600)
    check(exists(e4), 'nor one of another promotion (snv)')
end

--------------------------------------------------------------------------------
-- S8. props refused / timed out, an abort, motion nodes, forced demotes, destroyed clones, removals, core stop
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local a = H.player(env, 1, at(200, 0, 0))
    local function promoted(id)
        Scene.promote(id)
        local e = clone(R, id)
        W.owners[e] = a
        return e
    end
    -- a read-back outside the wear whitelist is never taken (not even looked at), wear values are clamped (RV4 F1:
    -- engine -4000 would burn the car at every promotion, a cosmetic key would rewrite a stranger's car)
    local v1, n1 = vehicle(Core, R)
    local e1 = promoted(v1)
    check(until_(R, v1, 'demoting'), 'demoting')
    answerProps(env, a, { [string.rep('k', 40)] = 1, colorPrimary = 135, modEngine = -1, plate = 'HACKED',
        engineHealth = -4000.0, tankHealth = -1000.0, bodyHealth = 5000.0 })
    local p1 = n1.fields.props
    check(PM.get(v1) == nil and type(p1) == 'table' and p1.engineHealth == 0 and p1.tankHealth == 0
        and p1.bodyHealth == nil and p1.colorPrimary == nil and p1.modEngine == nil and p1.plate == nil
        and p1[string.rep('k', 40)] == nil and PM.stats().propsRefused == 0,
        'the read-back: wear clamped (0..1000; a full value is not written), nothing else taken, demoted')
    stubs.tick(600)
    check(not exists(e1), 'clone deleted')
    -- no answer: the demotion goes on after the 1 s timeout
    local v2, n2 = vehicle(Core, R, at(0, 30))
    promoted(v2)
    check(until_(R, v2, 'demoting'), 'waiting for the props')
    stubs.tick(1100)
    check(PM.get(v2) == nil and n2.promoted == nil, 'no props within 1 s: demoted without them')
    -- taken again while the props were read: aborted
    local v3n = vehicle(Core, R, at(0, 60))
    local e3 = promoted(v3n)
    check(until_(R, v3n, 'demoting'), 'demoting')
    stubs.vehicleSeats[e3] = { [-1] = 555 }
    answerProps(env, a, { colorPrimary = 1 })
    check(PM.get(v3n) and PM.get(v3n).phase == 'live' and PM.stats().aborted == 1, 'a driver got in meanwhile: aborted')
    stubs.vehicleSeats[e3] = nil
    -- a node with a motion descriptor: no rest condition, its pose is not rewritten
    local mid = assert(Scene.spawn({ kind = 'prop', model = 'prop_bench_01a', pos = at(0, 90),
        motion = { t = 'spin', axis = 'z', dps = 30 } }))
    local mn = R.store.get(mid)
    local me = promoted(mid)
    W.vel[me] = { 2.0, 0, 0 }
    stubs.coords[me] = v3(0, 0, 0)
    local mpos = mn.pos.x
    check(until_(R, mid, nil, 21500), 'demoted')
    check(PM.get(mid) == nil and mn.pos.x == mpos and mn.motion ~= nil, 'a mover demotes on idle alone; pose kept')
    -- forced demotes
    local v4 = vehicle(Core, R, at(0, 120))
    promoted(v4)
    H.movePlayer(a, at(0, 121, 0))
    eq(Scene.demote(v4), true, 'Scene.demote forces it (a player right next to it)')
    stubs.tick(1100)
    eq(PM.get(v4), nil, 'demoted')
    eq(errOf(Scene.demote(v4)), 'not_promoted', 'a node that is not promoted')
    stubs.spawnDelayMs = 60000
    local v5 = vehicle(Core, R, at(0, 150))
    Scene.promote(v5)
    local e5 = clone(R, v5)
    eq(Scene.demote(v5), true, 'demoting a spawning node cancels it')
    stubs.entities[e5].exists = true
    stubs.tick(100)
    check(PM.get(v5) == nil and not exists(e5), 'the cancelled spawn is deleted once it exists')
    stubs.spawnDelayMs = 0
    H.movePlayer(a, at(200, 0, 0))
    -- destroyed clones: onDestroyed keep (default) / remove
    local v6, n6 = vehicle(Core, R, at(0, 180))
    local e6 = promoted(v6)
    local info6
    Scene.on('demoted', v6, function(_, i) info6 = i end)
    stubs.coords[e6] = v3(n6.pos.x + 30, n6.pos.y, n6.pos.z)
    local p6 = n6.pos.x
    stubs.health[e6] = 0
    stubs.tick(1100)
    eq(PM.get(v6).phase, 'live', 'health 0 before any sync is not a death')
    stubs.health[e6] = 1000
    stubs.tick(1000)
    W.wear[e6] = { engine = -4000.0, body = 0.0, tank = -200.0 }
    stubs.health[e6] = 0
    stubs.tick(1100)
    check(PM.get(v6) == nil and n6.promoted == nil and n6.pos.x == p6 + 30 and PM.stats().destroyed == 1,
        'dead after a sync: keep → demoted where the wreck stands, never back at its old spot (RV4 F5)')
    check(n6.fields.props and n6.fields.props.engineHealth == 0 and n6.fields.props.bodyHealth == 0
        and n6.fields.props.tankHealth == 0, 'with its last known wear, clamped (never repaired, never burning)')
    check(info6 and info6.reason == 'destroyed' and info6.destroyed == true and info6.pos.x == p6 + 30,
        'hook demoted: destroyed = true, the wreck pose')
    stubs.tick(600)
    check(not exists(e6), 'the wreck goes DeleteDelayMs later')
    local v7, n7 = vehicle(Core, R, at(0, 210), { authority = { onDestroyed = 'remove' } })
    local e7 = promoted(v7)
    stubs.coords[e7] = v3(n7.pos.x + 12, n7.pos.y, n7.pos.z)
    stubs.tick(1100)
    stubs.entities[e7].exists = false
    stubs.tick(1100)
    check(Scene.get(v7) ~= nil and PM.get(v7) == nil and n7.promoted == nil and n7.pos.x == P0.x + 12
        and PM.stats().lost == 1, 'a clone gone WITHOUT a wreck: lost — the node stays at its last known pose (D-C)')
    local v7b = vehicle(Core, R, at(0, 225), { authority = { onDestroyed = 'remove' } })
    local e7b = promoted(v7b)
    stubs.health[e7b] = 1000
    stubs.tick(1100)
    stubs.health[e7b] = 0
    stubs.tick(1100)
    check(Scene.get(v7b) == nil and PM.get(v7b) == nil, 'a wreck + onDestroyed remove: the node is removed')
    -- the node removed while promoted (the index tap): the clone goes after the delay
    local v8 = vehicle(Core, R, at(0, 240))
    local e8 = promoted(v8)
    Scene.remove(v8)
    eq(PM.get(v8), nil, 'released at the removal')
    stubs.tick(450)
    check(exists(e8), 'still there inside DeleteDelayMs')
    stubs.tick(100)
    check(not exists(e8), 'then deleted')
    -- re-parented (attach to a node): the clone goes, the node lives on as a child
    local v9, n9 = vehicle(Core, R, at(0, 270))
    local e9 = promoted(v9)
    local host = assert(Scene.spawn({ kind = 'group', pos = at(0, 280) }))
    local demotedHooks = 0
    Scene.on('demoted', v9, function() demotedHooks = demotedHooks + 1 end)
    check(Scene.attach(v9, { node = host }), 'attach the promoted vehicle to another node')
    check(n9.promoted == nil and PM.get(v9) == nil and demotedHooks == 1, 'handover: demoted, hook fired')
    stubs.tick(600)
    check(not exists(e9), 'its clone deleted')
    -- core stop: every clone goes now
    local va = vehicle(Core, R, at(0, 300))
    local ea = promoted(va)
    local vb = vehicle(Core, R, at(0, 330))
    local eb = promoted(vb)
    Scene.demote(vb)
    stubs.tick(10)
    stubs.spawnDelayMs = 60000
    local vc = vehicle(Core, R, at(0, 360))
    Scene.promote(vc)
    local ec = clone(R, vc)
    stubs.entities[ec].exists = true
    H.stop(env, 'core')
    check(not exists(ea) and not exists(eb) and not exists(ec), 'core stop deletes live, doomed and spawning clones')
    stubs.spawnDelayMs = 0
    local st = PM.stats()
    check(type(st.phases) == 'table' and st.maxEntities == 1000 and type(st.refused) == 'table'
        and type(st.reports) == 'table', 'stats shape')
end

--------------------------------------------------------------------------------
-- S9. a lease of another player blocks the action trigger; an enter report of a promoted node is ignored
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local a = H.player(env, 1, at(1, 0, 0))
    local b = H.player(env, 2, at(-1, 0, 0))
    local ped = assert(Scene.spawn({ kind = 'ped', model = 'a_m_y_skater_01', pos = P0,
        interact = { { action = 'talk', distance = 3 } }, authority = { actions = { 'talk' } } }))
    Scene.lease(ped, a)
    H.interact(env, b, ped, 'talk')
    eq(PM.get(ped), nil, 'leased by another player: the action does not promote')
    stubs.tick(300)
    H.interact(env, a, ped, 'talk')
    check(PM.get(ped) ~= nil, 'the holder promotes it')
    local v = vehicle(Core, R, at(2))
    Scene.promote(v)
    local before = PM.stats().reports.enter
    stubs.tick(300)
    stubs.triggerOn(env, 'core:scene:report', a, v, 'enter')
    eq(PM.stats().reports.enter, before, 'enter for a promoted node: ignored (the client tasks the ped into the clone)')
end

--------------------------------------------------------------------------------
-- S10. beforeChange (§55.21.1): a move / set / motion of a promoted node demotes it first — synchronously, at the
-- NEW pose (set / motion: where the clone stands), DEMOTE + the change in one tick, the clone gone 500 ms later
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    -- scene.lua's wiring (A2): the API calls R.promote.beforeChange(node, what) first — re-entrant by design
    for _, fn in ipairs({ 'move', 'set', 'motion', 'drive', 'attach' }) do
        local orig = Scene[fn]
        Scene[fn] = function(id, ...)
            local n = R.store.get(id)
            if n then PM.beforeChange(n, fn) end
            return orig(id, ...)
        end
    end
    local a = H.player(env, 1, at(3, 0, 0))
    local function promoted(pos)
        local id, node = vehicle(Core, R, pos)
        Scene.promote(id)
        local e = clone(R, id)
        W.owners[e] = a
        return id, node, e
    end
    -- move: the change brings the pose
    local v1, n1, e1 = promoted(P0)
    local demoted = 0
    Scene.on('demoted', v1, function() demoted = demoted + 1 end)
    reset()
    local target = at(40, 0, 0)
    check(Scene.move(v1, target), 'Scene.move of a promoted node (beforeChange first)')
    check(n1.promoted == nil and PM.get(v1) == nil and demoted == 1, 'no promotion left, hook demoted once')
    check(n1.pos.x == target.x and n1.pos.y == target.y, 'the node is at the NEW pose')
    local tr = H.trace()
    check(tr:find('changed:' .. v1 .. ':demote changed:' .. v1 .. ':move', 1, true) ~= nil,
        'index: demote, then the move — one tick, the flush coalesces them (' .. tr .. ')')
    eq(#sentOf('core:cb:req:core:scene:props'), 0, 'no props asked: nothing yields')
    check(exists(e1), 'the clone stays for DeleteDelayMs')
    stubs.tick(550)
    check(not exists(e1), 'then it is deleted')
    eq(PM.beforeChange(n1, 'move'), false, 'not promoted any more: false')
    eq(PM.stats().demoted, 1, 'one demotion counted')
    -- set (fields): the node stays where its clone stands, then the fields change
    local v2, n2, e2 = promoted(at(0, 60))
    stubs.coords[e2] = v3(n2.pos.x + 12, n2.pos.y, n2.pos.z)
    W.rot[e2] = { 0.0, 0.0, 33.0 }
    local d2 = 0
    Scene.on('demoted', v2, function() d2 = d2 + 1 end)
    reset()
    check(Scene.set(v2, { plate = 'NEW 1' }), 'Scene.set of a promoted node')
    eq(d2, 1, 'one demoted hook although the demotion moved the node (no re-entry)')
    check(n2.pos.x == P0.x + 12 and n2.rot.z == 33.0 and n2.fields.plate == 'NEW 1',
        'a set leaves the node where its clone stood, with the new fields')
    tr = H.trace()
    check(tr:find(':follow', 1, true) and tr:find(':demote', 1, true) and tr:find(':set', 1, true),
        'follow + demote + set')
    -- within 0.2 m / 2°: the authored pose stays (no move)
    local v3n, n3, e3 = promoted(at(0, 90))
    local px = n3.pos.x
    stubs.coords[e3] = v3(px + 0.1, n3.pos.y, n3.pos.z)
    reset()
    check(Scene.motion(v3n, { t = 'spin', axis = 'z', dps = 10 }), 'Scene.motion of a promoted node')
    local ch3 = calls('changed', v3n)
    check(n3.pos.x == px and #ch3 == 2 and ch3[1].what == 'demote' and ch3[2].what == 'motion',
        'motion: the snap rule keeps the authored pose (demote + motion only)')
    -- other changes keep the promotion
    local v4, n4 = promoted(at(0, 120))
    eq(PM.beforeChange(n4, 'interact'), false, 'an interact-only change keeps the promotion')
    eq(PM.beforeChange(n4, 'bogus'), false, 'an unknown what keeps it too')
    check(PM.get(v4) and PM.get(v4).phase == 'live', 'still promoted')
    -- a promotion on its way is cancelled; a demotion waiting for props ends at once
    stubs.spawnDelayMs = 60000
    local v5, n5 = vehicle(Core, R, at(0, 150))
    Scene.promote(v5)
    local e5 = clone(R, v5)
    check(Scene.drive(v5, at(0, 151), { x = 1, y = 0, z = 0 }), 'Scene.drive of a spawning promotion')
    stubs.entities[e5].exists = true
    stubs.tick(100)
    check(PM.get(v5) == nil and not exists(e5), 'the cancelled spawn is deleted once it exists')
    stubs.spawnDelayMs = 0
    H.movePlayer(a, at(300, 0, 0))
    local v6, n6 = promoted(at(0, 180))
    check(until_(R, v6, 'demoting'), 'demoting: waiting for the props')
    check(Scene.attach(v6, { player = a }), 'Scene.attach of a node whose demotion waits for props')
    check(PM.get(v6) == nil and n6.promoted == nil, 'demoted synchronously')
    answerProps(env, a, { colorPrimary = 77 })
    check(n6.fields.props == nil, 'the late props answer is ignored')
    eq(PM.stats().forced, 5, 'five forced demotions counted')
end

--------------------------------------------------------------------------------
-- S10b. a vehicle's one-shot config (D-A: cosmetic props for every owner, `once` = wear + lock + dirt until the owner
-- sends core:scene:applied), the clone's model (integer / '0x%08X' / name) and vtype, the pre-stop hooks
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local function applied(src, id) stubs.triggerOn(env, 'core:scene:applied', src, id) end
    local a = H.player(env, 1, at(3, 0, 0))
    local b = H.player(env, 2, at(0, 3, 0))
    local v = vehicle(Core, R, P0, { fields = { plate = 'ONCE 1', locked = true, dirt = 4,
        props = { colorPrimary = 5, bodyHealth = 700.0 }, invincible = true } })
    eq(Scene.promote(v), true, 'promoted')
    local e = clone(R, v)
    local full = state(env, e).snCfg
    check(full.props and full.props.colorPrimary == 5 and full.props.bodyHealth == nil and full.paint == nil
        and full.applied == nil and full.locked == nil and full.dirt == nil,
        'the cosmetic props for every owner (no wear, no lock, no dirt at the top)')
    check(type(full.once) == 'table' and full.once.wear and full.once.wear.bodyHealth == 700.0
        and full.once.locked == true and full.once.dirt == 4, 'once = the wear, the lock, the dirt')
    W.owners[e] = a
    applied(b, v)
    eq(state(env, e).snCfg, full, "applied from a player who does not own the clone: the bag is kept")
    applied(a, v)
    local kept = state(env, e).snCfg
    check(kept ~= full and kept.applied == true and kept.once == nil and kept.props and kept.props.colorPrimary == 5,
        'from the owner (no shared cooldown with b): once leaves the bag, the cosmetic props stay (every owner)')
    check(kept.plate == 'ONCE 1' and kept.invincible == true and kept.frozen == nil, 'the per-owner part stays')
    eq(PM.stats().reports.applied, 1, 'counted')
    stubs.tick(600)
    applied(a, v)
    eq(state(env, e).snCfg, kept, 'a second applied changes nothing')
    eq(PM.stats().reports.applied, 1, 'and is not counted')
    local ped = assert(Scene.spawn({ kind = 'ped', model = 'a_m_y_skater_01', pos = at(0, 30) }))
    Scene.promote(ped)
    local pe = clone(R, ped)
    W.owners[pe] = a
    local pedCfg = state(env, pe).snCfg
    applied(a, ped)
    eq(state(env, pe).snCfg, pedCfg, 'applied for a ped: ignored (its config stays per owner)')
    local idle = vehicle(Core, R, at(0, 60))
    applied(a, idle)
    eq(PM.get(idle), nil, 'applied for a node that is not promoted: nothing happens')

    -- the clone's model: an integer hash (u32 or signed), a '0x%08X' string (any case), a name; the vtype field
    local adder = env.GetHashKey('adder')
    local u32 = adder < 0 and adder + 0x100000000 or adder
    local signed = u32 > 0x7FFFFFFF and u32 - 0x100000000 or u32
    eq(PM.modelHash(adder), signed, 'modelHash(GetHashKey(name)) = the signed hash')
    eq(PM.modelHash(u32), signed, 'an unsigned hash is normalised to the signed form')
    eq(PM.modelHash(('0x%08X'):format(u32)), signed, "a '0x%08X' string")
    eq(PM.modelHash(('0x%08x'):format(u32)), signed, 'lower-case hex')
    eq(PM.modelHash('0x1F'), 31, 'a short hex string')
    eq(PM.modelHash('adder'), adder, 'a name: GetHashKey')
    eq(PM.modelHash(u32 + 0.0), signed, 'an integral float (a JSON round trip)')
    eq(PM.modelHash('0x123456789'), nil, 'more than 8 hex digits: unusable')
    eq(PM.modelHash(0x100000000), nil, 'beyond 32 bits: unusable')
    eq(PM.modelHash(''), nil, 'an empty name: unusable')
    eq(PM.modelHash({}), nil, 'a table: unusable')
    local function promoteWith(model, vtype, pos)
        local id = vehicle(Core, R, pos)
        local node = R.store.get(id)
        node.fields.model, node.fields.vtype = model, vtype      -- (what an input vtype / hash field carries)
        Scene.promote(id)
        local ce = clone(R, id)
        return ce and stubs.entities[ce]
    end
    local r1 = promoteWith(u32, 'bike', at(0, 80))
    check(r1 and r1.model == signed and r1.vehType == 'bike', 'an integer hash and the vtype field: (hash, bike)')
    local r2 = promoteWith(('0x%08X'):format(u32), 'heli', at(0, 90))
    check(r2 and r2.model == signed and r2.vehType == 'heli', "a '0x%08X' model: the same hash, heli")
    local r3 = promoteWith('adder', 'boat', at(0, 100))
    check(r3 and r3.model == adder and r3.vehType == 'boat', 'a name: GetHashKey, boat')
    local r4 = promoteWith('adder', 'hovercraft', at(0, 110))
    check(r4 and r4.vehType == 'automobile', 'an unknown vtype: the model-info default (automobile)')
    local r5 = promoteWith(signed, nil, at(0, 120))
    check(r5 and r5.model == signed and r5.vehType == 'automobile', 'a hash without vtype: automobile')
    local created = PM.stats().refused.create
    local r6 = promoteWith('0x123456789', 'bike', at(0, 130))
    check(r6 == nil and PM.stats().refused.create == created + 1, 'an unusable model: no create native, refused')

    -- core stops: the pre-stop hooks run first (the clones still there), then the clones go
    local seen = {}
    eq(PM.beforeStop(function()
        seen.exists, seen.ours = exists(e), PM.ours(e, v)
        seen.moved = Scene.move(v, at(9, 9), { x = 0, y = 0, z = 45 })   -- (a hook may still demote-and-move)
    end), true, 'a pre-stop hook registers')
    local hook = function() seen.second = (seen.second or 0) + 1 end
    PM.beforeStop(hook)
    PM.beforeStop(hook)
    eq(PM.beforeStop('nope'), false, 'only functions')
    env.TriggerEvent('onResourceStop', 'core')
    eq(seen.exists, true, 'inside the hook the clone still exists')
    eq(seen.ours, true, 'and is still ours')
    eq(seen.moved, true, 'Scene.move still works there (the node is demoted first)')
    eq(R.store.get(v).pos.x, P0.x + 9, 'the node took the pose')
    eq(seen.second, 1, 'a hook registered twice runs once')
    eq(exists(e), false, 'then the clones go')
end

--------------------------------------------------------------------------------
-- S11. I-1 (lib/scene/shared.lua, every VM): Scene.WEAR, splitProps, mergeWear — the only keys a clone owner's
-- read-back may change, clamped (RV4 F1 (1)-(4), D-A)
--------------------------------------------------------------------------------
do
    local _, Core = server()
    local S = Core.Scene
    local keys = {}
    for k in pairs(S.WEAR) do keys[#keys + 1] = k end
    table.sort(keys)
    eq(table.concat(keys, ','), 'bodyHealth,burstTyres,dirtLevel,doors,engineHealth,fuelLevel,tankHealth,tyreHealth,'
        .. 'windows', 'WEAR: healths, dirt, fuel, doors, windows, burst tyres, tyre health')
    local props = { colorPrimary = 5, mods = { [11] = 3 }, plate = 'P 1', bodyHealth = 900.0, windows = { [0] = true } }
    local cos, wear = S.splitProps(props)
    check(cos.colorPrimary == 5 and cos.mods[11] == 3 and cos.plate == 'P 1' and cos.bodyHealth == nil
        and wear.bodyHealth == 900.0 and wear.windows[0] == true and wear.colorPrimary == nil,
        'splitProps: cosmetic vs wear')
    cos.mods[11], wear.windows[0] = 0, false
    check(props.mods[11] == 3 and props.windows[0] == true, 'splitProps: fresh copies (the input is untouched)')
    local c2, w2 = S.splitProps(nil)
    check(next(c2) == nil and next(w2) == nil, 'splitProps(nil): two empty tables')
    local stored = { colorPrimary = 27, modEngine = 3, plate = 'MINE', engineHealth = 900.0, fuelLevel = 50.0,
        burstTyres = { [0] = true }, windows = { [0] = true, [1] = true } }
    local m = S.mergeWear(stored, { colorPrimary = 135, modEngine = -1, plate = 'HACKED', neonEnabled = { true },
        engineHealth = -4000.0, tankHealth = 5000.0, bodyHealth = 0 / 0, dirtLevel = 20, fuelLevel = math.huge,
        burstTyres = {}, windows = { ['0'] = false, [1] = 'x', [9] = false }, doors = 'open',
        tyreHealth = { [0] = 1500, [1] = -3, ['2'] = 350 } })
    check(m.colorPrimary == 27 and m.modEngine == 3 and m.plate == 'MINE' and m.neonEnabled == nil,
        'mergeWear: mods, colours, neon and the plate never change')
    check(m.engineHealth == 0 and m.tankHealth == 1000 and m.dirtLevel == 15, 'healths 0..1000, dirt 0..15')
    check(m.bodyHealth == nil and m.fuelLevel == 50.0, 'non-finite values are dropped (the stored one stays)')
    check(next(m.burstTyres) == nil, 'a read-back map replaces the stored one (the tyre was fixed)')
    check(m.windows[0] == false and m.windows[1] == nil and m.windows[9] == nil,
        "index maps: '0' → 0, non-booleans and indexes past 7 dropped")
    check(m.doors == nil and m.tyreHealth[0] == 1000 and m.tyreHealth[1] == 0 and m.tyreHealth[2] == 350,
        'a wrongly typed value is dropped; tyre health clamped 0..1000')
    check(stored.engineHealth == 900.0 and stored.burstTyres[0] == true and m ~= stored, 'stored is untouched')
    local fresh = S.mergeWear(nil, { fuelLevel = -5 })
    eq(fresh.fuelLevel, 0, 'mergeWear(nil, …): a fresh table, fuel clamped 0..100')
    local cp = S.mergeWear(stored, nil)
    check(cp ~= stored and cp.windows ~= stored.windows and cp.windows[1] == true, 'mergeWear(stored, nil): a copy')
end

--------------------------------------------------------------------------------
-- S12. RV5 F1 / RV6 F1: 'applied' is its own event — sent ~150 ms after the owner's own 'damaged' report it is not
-- dropped by the reports' 250 ms per-player cooldown, so the bag loses the one-shot part
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM = R.promote
    local a = H.player(env, 1, at(20, 0, 0))                        -- a player driving past, 20 m away
    local id = vehicle(Core, R, P0, { fields = { plate = 'PARK 1', locked = true, dirt = 4,
        props = { colorPrimary = 5, bodyHealth = 1000.0, fuelLevel = 65.0 } } })
    stubs.tick(300)
    stubs.triggerOn(env, 'core:scene:report', a, id, 'damaged')     -- he rams the parked car
    check(PM.get(id) and PM.get(id).trigger == 'damage', 'promoted by the damaged report')
    local e = clone(R, id)
    W.owners[e] = a
    check(state(env, e).snCfg.once ~= nil, 'the bag carries the one-shot part')
    stubs.tick(150)
    stubs.triggerOn(env, 'core:scene:applied', a, id)
    local after = state(env, e).snCfg
    check(after.applied == true and after.once == nil and after.props.colorPrimary == 5
        and PM.stats().reports.applied == 1,
        "150 ms after the owner's damaged: applied is accepted (no shared cooldown), once leaves the bag")
end

--------------------------------------------------------------------------------
-- S13. RV4 F9 / D-B: proximity promotions use at most ProximityShare of MaxEntities; at the cap an enter / manual /
-- action promotion demotes the OLDEST idle proximity promotion (never an occupied or leased one)
--------------------------------------------------------------------------------
do
    local env, Core, R = server({ MaxEntities = 3 })                 -- 0.7 × 3 → 2 proximity slots
    local PM, Scene = R.promote, Core.Scene
    local cars, walkers = {}, {}
    for i = 1, 3 do
        local id, node = vehicle(Core, R, at(i * 100))
        cars[i] = id
        walkers[i] = H.player(env, 10 + i, at(i * 100 + 5))          -- on foot, 5 m from car i
        subscribe(node, walkers[i], 1)
    end
    stubs.tick(2100)
    check(PM.get(cars[1]) and PM.get(cars[2]) and not PM.get(cars[3]), 'two proximity promotions, the third refused')
    check(PM.stats().refused.share >= 1 and PM.stats().proximitySlots == 2 and PM.stats().proximityMax == 2,
        'refused by the proximity share (2 of 3)')
    H.movePlayer(walkers[3], at(300, 400))                            -- (car 3 is not asked for again)
    local c4 = vehicle(Core, R, at(0, -100))
    local owner4 = H.player(env, 4, at(2, -100))
    stubs.tick(300)
    stubs.triggerOn(env, 'core:scene:report', owner4, c4, 'enter')
    check(PM.get(c4) and PM.get(c4).trigger == 'enter', "the owner's enter uses the reserved share")
    stubs.tick(1100)
    local evicted
    Scene.on('demoted', cars[1], function(_, i) evicted = i end)
    local c5 = vehicle(Core, R, at(0, -200))
    eq(Scene.promote(c5), true, 'a manual promotion at the cap (a garage takes a parked car out)')
    check(PM.get(cars[1]) == nil and evicted and evicted.reason == 'evicted' and PM.stats().evicted == 1
        and PM.get(c5) ~= nil, 'the oldest idle proximity promotion made room')
    stubs.tick(1100)
    stubs.vehicleSeats[clone(R, cars[2])] = { [-1] = 777 }          -- someone sits in the other one
    local c6 = vehicle(Core, R, at(0, -300))
    eq(errOf(Scene.promote(c6)), 'limit', 'an occupied proximity promotion is never evicted: limit')
    local c7 = vehicle(Core, R, at(105, 30))                          -- 30 m from walker 1
    stubs.tick(300)
    stubs.triggerOn(env, 'core:scene:report', walkers[1], c7, 'damaged')
    eq(PM.get(c7), nil, 'a damage promotion at the cap evicts nothing')
end

--------------------------------------------------------------------------------
-- S14. D-C / RV4 F5 (+ RV6 F7, server half): while promoted the node FOLLOWS its clone; a clone deleted by the
-- world leaves the node at its last known pose with its last known wear — never back at the old spot, never
-- repaired; wear sampled before the owner applied the one-shot part is never taken
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local a = H.player(env, 1, at(3, 0, 0))
    local id, node = vehicle(Core, R, P0, { fields = { props = { colorPrimary = 5 } } })
    Scene.promote(id)
    local e = clone(R, id)
    W.owners[e], stubs.health[e] = a, 1000
    local info
    Scene.on('demoted', id, function(_, i) info = i end)
    reset()
    for i = 1, 27 do                                                -- the owner drives it 2.7 km
        stubs.coords[e] = v3(P0.x + i * 100, P0.y, P0.z)
        W.vel[e] = { 30.0, 0.0, 0.0 }
        H.movePlayer(a, at(i * 100 + 3, 0, 0))
        stubs.tick(1000)
    end
    local follows = 0
    for _, c in ipairs(calls('changed', id)) do if c.what == 'follow' then follows = follows + 1 end end
    check(node.promoted and node.pos.x == P0.x + 2700 and follows >= 25,
        'the node follows its driven clone (1 Hz): its cell leaves the old spot (' .. follows .. ' follows)')
    W.vel[e] = { 0.0, 0.0, 0.0 }
    W.wear[e] = { body = 400.0, engine = 800.0, burst = { [0] = 1 } }
    stubs.tick(1100)
    stubs.entities[e].exists = false                               -- deleted by the world (not wrecked)
    stubs.tick(1100)
    local p = node.fields.props
    check(PM.get(id) == nil and node.promoted == nil and node.pos.x == P0.x + 2700,
        'the clone is gone: the node stays where it was last seen (not at the old spot)')
    check(p.bodyHealth == 400.0 and p.engineHealth == 800.0 and p.burstTyres and p.burstTyres[0] == true
        and p.colorPrimary == 5, 'with the last known wear (no free repair); the cosmetics untouched')
    check(info and info.reason == 'lost' and info.destroyed == false and info.pos.x == P0.x + 2700
        and info.wear and info.wear.bodyHealth == 400.0 and PM.stats().lost == 1,
        'hook demoted: reason lost, the last pose, the wear')
    -- before its owner applied the one-shot wear the clone shows pristine health: never taken as the car's
    local id2, n2 = vehicle(Core, R, at(0, 50), { fields = { props = { bodyHealth = 700.0 } } })
    Scene.promote(id2)
    local e2 = clone(R, id2)
    W.owners[e2], stubs.health[e2] = a, 1000
    stubs.tick(2100)
    Scene.set(id2, { plate = 'GATE 1' })                           -- a forced demotion (beforeChange)
    eq(n2.fields.props.bodyHealth, 700.0, 'a pre-apply sample (1000) is ignored: the stored wear stays')
    Scene.promote(id2)
    local e3 = clone(R, id2)
    W.owners[e3], stubs.health[e3] = a, 1000
    stubs.tick(300)
    stubs.triggerOn(env, 'core:scene:applied', a, id2)
    W.wear[e3] = { body = 650.0 }
    stubs.tick(1100)
    eq(R.promote.get(id2).phase, 'live', 'still promoted')
    stubs.tick(1100)                                                -- (samples count 1 s after applied: synced)
    Scene.set(id2, { plate = 'GATE 2' })
    stubs.tick(10)
    check(n2.fields.props.bodyHealth == 650.0 and n2.fields.plate == 'GATE 2',
        "once applied, the synced wear is the car's (written after the set's own fields: both stay)")
end

--------------------------------------------------------------------------------
-- S15. D-D / RV4 F6 / RV6 F13: the clone's bucket is authoritative — onEntityBucketChange moves the node at once,
-- the idle check looks at the CLONE's bucket, the monitor catches a missed event, core stop persists pose + bucket
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local a = H.player(env, 1, at(3, 0, 0))
    local id, node = vehicle(Core, R, P0, { persist = true })
    Scene.promote(id)
    local e = clone(R, id)
    W.owners[e] = a
    local info
    Scene.on('demoted', id, function(_, i) info = i end)
    stubs.coords[e] = v3(-800.0, 300.0, 20.0)                      -- Player.setCoords(… withVehicle, bucket = 5)
    local events = W.bucketEvents
    env.SetEntityRoutingBucket(e, 5)
    check(W.bucketEvents == events + 1 and node.bucket == 5 and node.pos.x == -800.0 and node.promoted ~= nil,
        'onEntityBucketChange: the node follows its clone into bucket 5 at once')
    stubs.buckets[a] = 5
    H.movePlayer(a, { x = -803.0, y = 300.0, z = 20.0 })
    stubs.tick(30000)
    check(PM.get(id) and PM.get(id).phase == 'live', 'its owner 3 m away in bucket 5: never idle (RV4 F6)')
    H.movePlayer(a, { x = -700.0, y = 300.0, z = 20.0 })
    stubs.tick(25000)
    check(PM.get(id) == nil and node.bucket == 5 and node.pos.x == -800.0 and info and info.bucket == 5,
        'he walks off: demoted IN bucket 5, where the car stands (RV6 F13)')
    stubs.tick(1100)
    local doc = Core.DB.get('scene_nodes', 'n' .. id)
    check(doc and doc.bucket == 5 and doc.pos and doc.pos.x == -800.0, 'persisted in bucket 5')
    local id2, n2 = vehicle(Core, R, at(0, 40), { persist = true })
    Scene.promote(id2)
    local e2 = clone(R, id2)
    stubs.entities[e2].bucket = 7                                  -- moved without the event
    stubs.tick(1100)
    eq(n2.bucket, 7, 'the monitor compares GetEntityRoutingBucket every second')
    stubs.coords[e2] = v3(P0.x + 50, P0.y + 40, P0.z)
    stubs.entities[e2].bucket = 9
    local seen
    PM.beforeStop(function() seen = { bucket = n2.bucket, x = n2.pos.x } end)
    env.TriggerEvent('onResourceStop', 'core')
    check(seen and seen.bucket == 9 and seen.x == P0.x + 50,
        "core stop: the pre-stop hooks see the clone's pose + bucket")
    local doc2 = Core.DB.get('scene_nodes', 'n' .. id2)
    check(doc2 and doc2.bucket == 9 and doc2.pos and doc2.pos.x == P0.x + 50,
        'and it is persisted (R.store.flush + Core.DB.flush after the store\'s own stop writer)')
end

--------------------------------------------------------------------------------
-- S16. RV4 F12: occupants are re-checked right before a clone goes — Scene.demote refuses, a demotion aborts when
-- someone got in during the props read, and a clone somebody got into inside DeleteDelayMs is kept (re-promoted)
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local a = H.player(env, 1, at(40, 0, 0))
    local id, node = vehicle(Core, R)
    Scene.promote(id)
    local e = clone(R, id)
    W.owners[e] = a
    stubs.vehicleSeats[e] = { [-1] = 555 }
    eq(errOf(Scene.demote(id)), 'occupied', 'Scene.demote of an occupied clone: occupied')
    stubs.vehicleSeats[e] = nil
    eq(Scene.demote(id), true, 'empty: the forced demotion starts (the owner is asked for the props)')
    stubs.tick(10)
    stubs.vehicleSeats[e] = { [0] = 556 }                           -- a friend gets in during that second
    answerProps(env, a, { bodyHealth = 990.0 })
    check(PM.get(id) and PM.get(id).phase == 'live' and node.promoted ~= nil and exists(e)
        and PM.stats().aborted == 1, 'someone got in while the props were read: the manual demotion is aborted')
    stubs.vehicleSeats[e] = nil
    W.owners[e] = nil                                               -- (server-owned: no props wait)
    local hooks = {}
    Scene.on('demoted', id, function() hooks[#hooks + 1] = 'demoted' end)
    Scene.on('promoted', id, function(_, n) hooks[#hooks + 1] = 'promoted:' .. tostring(n) end)
    local netId = node.promoted.netId
    eq(Scene.demote(id), true, 'demote again')
    stubs.tick(10)
    eq(node.promoted, nil, 'demoted: the DEMOTE op is out, the clone doomed')
    stubs.vehicleSeats[e] = { [-1] = 557 }                          -- he got back in before the delete
    stubs.tick(600)
    check(exists(e) and node.promoted and node.promoted.entity == e and node.promoted.netId == netId
        and PM.get(id).trigger == 'rescue' and PM.stats().rescued == 1 and state(env, e).sn == id,
        'the doomed clone is kept: the node is promoted again with it')
    check(hooks[1] == 'demoted' and hooks[2] == 'promoted:' .. tostring(netId), 'hooks: demoted, then promoted')
end

--------------------------------------------------------------------------------
-- S17. R.promote.adopt (RV6 F11's hand-off: a live car becomes a node's clone, then demotes normally)
--------------------------------------------------------------------------------
do
    local env, Core, R = server()
    local PM, Scene = R.promote, Core.Scene
    local id, node = vehicle(Core, R, P0)
    local live = env.CreateVehicleServerSetter(env.GetHashKey('adder'), 'automobile', P0.x + 2, P0.y, P0.z, 45.0)
    eq(errOf(PM.adopt(424242, live)), 'missing', 'adopt: an unknown node')
    local mk = assert(Scene.spawn({ kind = 'marker', pos = at(3) }))
    eq(errOf(PM.adopt(mk, live)), 'class', 'a marker has no clone class')
    local ped = env.CreatePed(4, env.GetHashKey('a_m_y_skater_01'), P0.x, P0.y, P0.z, 0.0, true, true)
    eq(errOf(PM.adopt(id, ped)), 'entity', 'an entity of another class')
    eq(errOf(PM.adopt(id, 999999)), 'entity', 'no such entity')
    local other = vehicle(Core, R, at(0, 20))
    Scene.promote(other)
    eq(errOf(PM.adopt(id, clone(R, other))), 'entity', "another node's clone")
    local heard
    Scene.on('promoted', id, function(_, n) heard = n end)
    eq(PM.adopt(id, live), true, 'adopt a live vehicle')
    local pr = PM.get(id)
    check(pr and pr.entity == live and pr.trigger == 'adopt' and pr.phase == 'live' and node.promoted
        and node.promoted.entity == live, 'the live entity is its clone now')
    local cfg = state(env, live).snCfg
    check(state(env, live).sn == id and cfg and cfg.applied == true and cfg.once == nil,
        'its bags: sn, snv, snCfg without a one-shot part (it keeps its own state)')
    check(node.pos.x == P0.x + 2 and heard == pr.netId, 'the node took its pose; hook promoted(copy, netId)')
    eq(errOf(PM.adopt(id, live)), 'promoted', 'twice: promoted')
    eq(Scene.demote(id), true, 'then the normal hand-off')
    stubs.tick(100)
    eq(PM.get(id), nil, 'demoted')
    stubs.tick(600)
    check(not exists(live), 'the adopted entity goes DeleteDelayMs after the DEMOTE')
end

--------------------------------------------------------------------------------
-- client harness: the REAL materialiser, kinds, movers and client/scene_promote.lua in a stub client VM
--------------------------------------------------------------------------------

-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local CH = dofile(here .. '/client_scene_harness.lua')
local HVEH, HPED, HPROP = 2001, 3001, 1001
local cstubs                                         -- the client harness's own stubs instance

--- A client VM: C.cache is the harness fake; h.rec[name] = recorded calls; h.states[e] = entity bags;
--- h.control[e] = network control; h.bag = the snCfg state-bag handler; h.W = the ped's world.
local function client()
    local h = CH.new({})
    cstubs = h.stubs
    local env = h.env
    h.models[HVEH], h.models[HPED] = { mode = 'vehicle' }, { mode = 'ped' }
    h.rec, h.states, h.control, h.W = {}, {}, {}, { trying = 0, seat = -1, ped = 4242 }
    local function nat(name, impl)
        env[name] = function(...)
            local l = h.rec[name] or {}
            h.rec[name] = l
            l[#l + 1] = table.pack(...)
            if impl then return impl(...) end
        end
    end
    local function new(t)
        return function(model, x, y, z, heading)
            local e = h.newEntity(model, x, y, z, t)
            h.ents[e].rz = heading or 0.0
            return e
        end
    end
    nat('CreateVehicle', new(2))
    nat('CreatePed', function(_, model, x, y, z, heading) return new(1)(model, x, y, z, heading) end)
    for _, n in ipairs({ 'SetVehicleDoorsLocked', 'SetVehicleEngineOn', 'SetVehicleLights', 'SetVehicleFullbeam',
        'SetVehicleSiren', 'SetVehicleDirtLevel', 'SetVehicleNumberPlateText', 'SetEntityInvincible',
        'SetDisableFragDamage', 'SetObjectTextureVariation', 'SetPedDefaultComponentVariation',
        'SetBlockingOfNonTemporaryEvents', 'SetPedCanRagdoll', 'TaskStartScenarioInPlace', 'GiveWeaponToPed',
        'SetVehicleColours', 'TaskEnterVehicle', 'SetVehicleDoorShut', 'SetVehicleDoorOpen' }) do nat(n) end
    nat('IsPedUsingScenario', function() return false end)
    nat('SetEntityVisible', function(e, on) if h.ents[e] then h.ents[e].visible = on end end)
    nat('SetEntityCollision', function(e, on) if h.ents[e] then h.ents[e].collision = on end end)
    nat('GetVehiclePedIsTryingToEnter', function() return h.W.trying end)
    nat('GetSeatPedIsTryingToEnter', function() return h.W.seat end)
    env.PlayerPedId = function() return h.W.ped end
    h.ents[h.W.ped] = { model = 0, x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0, type = 1, alphaLog = {},
        foreign = true }
    env.NetworkHasControlOfEntity = function(e) return h.control[e] and 1 or false end
    env.Entity = function(e)
        h.states[e] = h.states[e] or {}
        return { state = h.states[e] }
    end
    env.AddStateBagChangeHandler = function(key, _, fn) if key == 'snCfg' then h.bag = fn end return 1 end
    local Core = env.Core
    h.prompts = {}
    Core.Interactions = { add = function(o) h.prompts[#h.prompts + 1] = o return #h.prompts end,
        remove = function(id) h.prompts[id] = false end }
    h.props = {}
    Core.Vehicles = { setPropsLocal = function() return true end,
        setProps = function(e, p) h.props[#h.props + 1] = { e = e, p = p } return true end,
        getProps = function(e) return { model = h.ents[e] and h.ents[e].model, colorPrimary = 9 } end }
    for _, f in ipairs({ 'client/scene_mat_assets.lua', 'client/scene_materializer.lua', 'client/scene_kinds.lua',
        'client/scene_movers.lua', 'client/scene_promote.lua' }) do h.load(f) end
    h.cam(0, 0, 0, 0, 0)
    h.Pr, h.M = h.C.promote, h.C.mat
    return h
end

--- A networked clone of node `id` with net id `netId` on this client (state sn = id).
local function makeClone(h, id, netId, x, y, z, rz, etype)
    local e = h.newEntity(HVEH, x, y, z, etype or 2)
    h.ents[e].rz, h.ents[e].foreign = rz or 0.0, true
    h.netEntities[netId] = e
    h.states[e] = { sn = id }
    return e
end

--- Client → server sends of `name` (for node `id` when given).
local function sentC(name, id)
    local out = {}
    for _, s in ipairs(cstubs.sent) do
        if s.name == name and (id == nil or s.args[1] == id) then out[#out + 1] = s end
    end
    return out
end
local function nrec(h, name) return h.rec[name] and #h.rec[name] or 0 end

--------------------------------------------------------------------------------
-- C1. the hand-off: the pending poll (only while needed), swap in the same frame vs fade, the stand-in record
--------------------------------------------------------------------------------
do
    local h = client()
    local Pr, M = h.Pr, h.M
    check(type(Pr) == 'table' and Pr.onPromote and Pr.onDemote and Pr.handlers.vehicle, 'C.promote is filled')
    local okLoad, errLoad = pcall(function()
        local bare = CH.new({})
        bare.load('client/scene_promote.lua')
    end)
    check(not okLoad and tostring(errLoad):find('after client/scene_movers.lua', 1, true) ~= nil,
        'the load order asserts')
    h = client()
    Pr, M = h.Pr, h.M
    local polls0 = h.n('NetworkDoesEntityExistWithNetworkId')
    h.tick(3000)
    eq(h.n('NetworkDoesEntityExistWithNetworkId') - polls0, 0, 'nothing promoted: no poll at all')
    local node = h.node(1, 'vehicle', 'vehicle', 0, 10, 0, { model = HVEH })
    M.add(node)
    h.tick(600)
    local local1 = M.handleOf(1)
    check(local1 and h.ents[local1].type == 2, 'the local copy exists')
    node.netId = 55
    Pr.onPromote(node, 55)
    eq(Pr.stats().polled, 1, 'promoted: the local copy is polled')
    local p0 = h.n('NetworkDoesEntityExistWithNetworkId')
    h.tick(1000)
    local rate = h.n('NetworkDoesEntityExistWithNetworkId') - p0
    check(rate >= 9 and rate <= 11, '10 Hz while the clone is missing (' .. rate .. ' in 1 s)')
    check(h.ents[local1].visible ~= false and not h.ents[local1].deleted, 'the local copy stays LIVE meanwhile')
    -- the clone arrives at the same pose: hidden in the same frame, then deleted by the materialiser
    local c1 = makeClone(h, 1, 55, 0, 10, 0, 0)
    h.states[c1].sn = 2
    h.tick(200)
    check(h.ents[local1].visible ~= false, 'a net id whose entity has another sn is not the clone')
    h.states[c1].sn = 1
    local swapsBefore = Pr.stats().swaps
    h.tick(100)
    eq(Pr.stats().swaps, swapsBefore + 1, 'swapped')
    eq(h.ents[local1].visible, false, 'within 5 cm / 2°: hidden in the swap frame')
    eq(h.ents[local1].collision, false, 'and without collision')
    eq(Pr.stats().cuts, 1, 'a cut, not a fade')
    h.tick(1000)
    check(h.ents[local1].deleted, 'the old local copy is deleted')
    eq(M.handleOf(1), nil, 'the node has no local entity: the clone stands in')
    eq(node.m.st, 3, 'the record is LIVE (the stand-in)')
    eq(Pr.cloneOf(1), c1, 'cloneOf(id) = the clone')
    eq(Pr.idOfClone(c1), 1, 'idOfClone(clone) = the node id')
    eq(Pr.idOfClone(local1), nil, 'idOfClone of a local copy: nil (C.mat.idOf answers those)')
    eq(Pr.idOfClone(424242), nil, 'idOfClone of an unknown entity: nil')
    eq(nrec(h, 'CreateVehicle'), 1, 'no second local copy was created')
    local pp = h.n('NetworkDoesEntityExistWithNetworkId')
    h.tick(3000)
    eq(Pr.stats().polled, 0, 'nothing polled any more')
    check(h.n('NetworkDoesEntityExistWithNetworkId') - pp <= 3, 'swapped: no 10 Hz poll')
    -- the fade case: a clone 1 m away and turned
    local n2 = h.node(2, 'vehicle', 'vehicle', 0, 20, 0, { model = HVEH })
    M.add(n2)
    h.tick(600)
    local local2 = M.handleOf(2)
    n2.netId = 56
    Pr.onPromote(n2, 56)
    makeClone(h, 2, 56, 1.0, 20, 0, 5)
    h.tick(100)
    eq(Pr.stats().fades, 1, 'off by 1 m / 5°: faded out over the clone')
    eq(h.ents[local2].collision, false, 'without collision at once')
    check(not h.ents[local2].deleted and h.ents[local2].alpha ~= nil, 'fading (alpha override running)')
    h.tick(400)
    check(h.ents[local2].deleted, 'deleted at the end of the 300 ms fade')
    -- a promoted node that arrives (fresh) with its clone here: no local copy at all
    local c3 = makeClone(h, 3, 57, 0, 30, 0, 0)
    local n3 = h.node(3, 'vehicle', 'vehicle', 0, 30, 0, { model = HVEH }, { netId = 57, flags = 2,
        interact = { { action = 'use', label = 'Use' } } })
    local created = nrec(h, 'CreateVehicle')
    M.add(n3)
    h.tick(600)
    eq(nrec(h, 'CreateVehicle'), created, 'arrived promoted with its clone here: never created locally')
    eq(n3.m.st, 3, 'LIVE as the stand-in')
    local pr = h.prompts[#h.prompts]
    check(pr and pr.entity == c3, 'its interaction prompt targets the clone')
    -- the stand-in of an older clone gets a new net id without its clone: the local copy comes back, polled
    n3.netId = 58
    Pr.onPromote(n3, 58)
    h.tick(600)
    local l3 = M.handleOf(3)
    check(l3 and not h.ents[l3].deleted and h.ents[l3].visible ~= false, 'the local copy is back, visible')
    eq(Pr.stats().polled, 1, 'and polled for the new clone')
end

--------------------------------------------------------------------------------
-- C2. clone timeout (the local copy stays; a late clone still swaps at 1 Hz), the demotion's hidden copy and its
-- reveal frame, a never-swapped copy at the demotion, a demotion without a clone here
--------------------------------------------------------------------------------
do
    local h = client()
    local Pr, M = h.Pr, h.M
    local node = h.node(1, 'vehicle', 'vehicle', 0, 10, 0, { model = HVEH })
    M.add(node)
    h.tick(600)
    local l1 = M.handleOf(1)
    node.netId = 60
    Pr.onPromote(node, 60)
    h.tick(10200)
    eq(Pr.stats().timeouts, 1, 'no clone within CloneWaitMs: timed out')
    check(not h.ents[l1].deleted and h.ents[l1].visible ~= false, 'the local copy stays')
    eq(Pr.stats().phases.late, 1, 'late')
    local p0 = h.n('NetworkDoesEntityExistWithNetworkId')
    h.tick(3000)
    local r = h.n('NetworkDoesEntityExistWithNetworkId') - p0
    check(r >= 2 and r <= 4, 'late: polled at 1 Hz (' .. r .. ' in 3 s)')
    local c1 = makeClone(h, 1, 60, 0, 10, 0, 0)
    h.tick(1100)
    check(Pr.cloneOf(1) == c1 and h.ents[l1].visible == false, 'a late clone still swaps')
    h.tick(1000)
    -- the demotion: the stand-in re-creates a HIDDEN local copy; revealed the frame the clone is gone
    node.netId = nil
    node.x, node.y = 2.0, 12.0                                     -- the DEMOTE pose (the cache set it)
    Pr.onDemote(node)
    eq(Pr.stats().phases.demoting, 1, 'demoting while the clone exists')
    h.tick(600)
    local l2 = M.handleOf(1)
    check(l2 and l2 ~= l1 and not h.ents[l2].deleted, 'a new local copy was created')
    check(h.ents[l2].x == 2.0 and h.ents[l2].y == 12.0, 'at the demotion pose')
    eq(h.ents[l2].visible, false, 'hidden while the clone exists')
    eq(h.ents[l2].collision, false, 'without collision (the clone is the physical one)')
    local f0 = cstubs.now()
    h.tick(2000)
    eq(h.ents[l2].visible, false, 'still hidden while the clone stays')
    eq(Pr.idOfClone(c1), 1, 'demoting: the clone still maps to its node')
    h.ents[c1].deleted = true                                      -- the server deleted the clone
    h.netEntities[60] = nil
    local frame = cstubs.now()
    h.frames(1)
    check(h.ents[l2].visible == true and h.ents[l2].collision == true, 'revealed the frame the clone is gone')
    check(cstubs.now() - frame <= 16 and cstubs.now() > f0, 'within one frame')
    eq(Pr.stats().reveals, 1, 'one reveal')
    h.tick(1100)
    eq(Pr.stats().known, 0, 'the promotion record is dropped')
    eq(Pr.idOfClone(c1), nil, 'a clone of a dropped promotion maps to nothing')
    local fr = h.n('DoesEntityExist')
    h.tick(2000)
    local reads = h.n('DoesEntityExist') - fr
    check(reads <= 10, 'no per-frame loop once nothing waits (' .. reads .. ')')
    -- a copy that never swapped (the clone arrived just as the demotion did): hidden now, revealed after
    local n2 = h.node(2, 'vehicle', 'vehicle', 0, 20, 0, { model = HVEH })
    M.add(n2)
    h.tick(600)
    local l3 = M.handleOf(2)
    n2.netId = 61
    Pr.onPromote(n2, 61)
    local c2 = makeClone(h, 2, 61, 0, 20, 0, 0)
    n2.netId = nil
    Pr.onDemote(n2)
    eq(h.ents[l3].visible, false, 'the never-swapped copy hides while the clone is still here')
    h.tick(500)                                                    -- the server deletes DeleteDelayMs after the op
    h.ents[c2].deleted = true
    h.netEntities[61] = nil
    h.frames(1)
    eq(h.ents[l3].visible, true, 'and shows the frame it goes')
    -- no clone on this client at the demotion: the stand-in simply re-creates a visible copy
    local c3 = makeClone(h, 3, 62, 0, 30, 0, 0)
    local n3 = h.node(3, 'vehicle', 'vehicle', 0, 30, 0, { model = HVEH }, { netId = 62, flags = 2 })
    M.add(n3)
    h.tick(600)
    eq(M.handleOf(3), nil, 'the stand-in')
    h.ents[c3].deleted = true
    h.netEntities[62] = nil
    n3.netId = nil
    Pr.onDemote(n3)
    h.tick(600)
    local l4 = M.handleOf(3)
    check(l4 and h.ents[l4].visible ~= false, 'a demotion without a clone here: a visible local copy')
    eq(Pr.stats().known, 0, 'nothing tracked')
end

--------------------------------------------------------------------------------
-- C3. the enter watch (cadence, report, TaskEnterVehicle into the clone), the damage event
--------------------------------------------------------------------------------
do
    local h = client()
    local Pr, M = h.Pr, h.M
    h.tick(2000)
    eq(nrec(h, 'GetVehiclePedIsTryingToEnter'), 0, 'no local vehicle copy: no enter watch at all')
    local node = h.node(1, 'vehicle', 'vehicle', 0, 30, 0, { model = HVEH })
    M.add(node)
    h.tick(600)
    local l1 = M.handleOf(1)
    eq(Pr.stats().vehicles, 1, 'the local vehicle copy is watched')
    h.ents[h.W.ped].y = 0.0                                         -- the ped 30 m away
    local c0 = nrec(h, 'GetVehiclePedIsTryingToEnter')
    h.tick(3000)
    eq(nrec(h, 'GetVehiclePedIsTryingToEnter') - c0, 0, 'farther than 6 m: the native is not asked')
    h.ents[h.W.ped].y = 26.0                                        -- 4 m
    h.tick(1100)
    local c1 = nrec(h, 'GetVehiclePedIsTryingToEnter')
    h.tick(1000)
    local rate = nrec(h, 'GetVehiclePedIsTryingToEnter') - c1
    check(rate >= 3 and rate <= 5, 'within 6 m: 4 Hz (' .. rate .. ' in 1 s)')
    eq(#sentC('core:scene:report'), 0, 'not trying to enter: no report')
    h.W.trying, h.W.seat = l1, 0
    h.tick(300)
    local reps = sentC('core:scene:report', 1)
    check(#reps == 1 and reps[1].args[2] == 'enter', 'trying to enter the local copy: core:scene:report(id, enter)')
    h.tick(1000)
    eq(#sentC('core:scene:report', 1), 1, 'at most once per 2 s per node')
    h.tick(1100)
    eq(#sentC('core:scene:report', 1), 2, 'again after 2 s while still trying')
    -- the server promotes; the swap tasks the ped into the clone (the seat it tried)
    node.netId = 70
    Pr.onPromote(node, 70)
    local c = makeClone(h, 1, 70, 0, 30, 0, 0)
    h.W.trying = 0
    h.tick(200)
    local task = h.rec.TaskEnterVehicle and h.rec.TaskEnterVehicle[1]
    check(task and task[1] == h.W.ped and task[2] == c and task[3] == 10000 and task[4] == 0 and task[5] == 1.0
        and task[6] == 1 and task[7] == 0, 'TaskEnterVehicle(ped, clone, 10000, seat 0, 1.0, 1, 0) after the swap')
    eq(Pr.stats().enterTasks, 1, 'counted')
    h.tick(1000)
    eq(Pr.stats().vehicles, 0, 'the local copy is gone: nothing watched')
    local c2 = nrec(h, 'GetVehiclePedIsTryingToEnter')
    h.tick(3000)
    eq(nrec(h, 'GetVehiclePedIsTryingToEnter') - c2, 0, 'the watch ended with the last local vehicle copy')
    -- damage: CEventNetworkEntityDamage naming a local copy → damaged (rate-limited); others ignored
    local ped = h.node(2, 'ped', 'ped', 5, 20, 0, { model = HPED })
    M.add(ped)
    h.tick(600)
    local lp = M.handleOf(2)
    local fire = function(name, args) cstubs.triggerOn(h.env, 'gameEventTriggered', 0, name, args) end
    fire('CEventNetworkPlayerEnteredVehicle', { lp })
    fire('CEventNetworkEntityDamage', { 999999, h.W.ped })
    eq(#sentC('core:scene:report', 2), 0, 'another event, an unknown victim: nothing')
    -- a wrong argument layout fails safe: nothing reported, nothing raised
    local failures = #cstubs.failures
    for _, bad in ipairs({ false, 'x', 5, {}, { 'abc' }, { 1.5 }, { -3 }, { {} }, { true },
        setmetatable({}, { __index = function() error('boom') end }) }) do
        fire('CEventNetworkEntityDamage', bad)
    end
    fire('CEventNetworkEntityDamage', nil)
    check(#sentC('core:scene:report', 2) == 0 and #cstubs.failures == failures, 'bad layouts: no report, no error')
    fire('CEventNetworkEntityDamage', { lp, h.W.ped, 0, 0, 0, 0 })
    fire('CEventNetworkEntityDamage', { lp, h.W.ped })
    local d = sentC('core:scene:report', 2)
    check(#d == 1 and d[1].args[2] == 'damaged', 'damaged, once (rate-limited per node)')
    fire('CEventNetworkEntityDamage', { c, h.W.ped })
    eq(#sentC('core:scene:report', 1) - 2, 0, 'the clone itself is never reported')
    -- promoted (by proximity) before the ped got to the door: no report, the swap still tasks the ped
    local n4 = h.node(4, 'vehicle', 'vehicle', 0, 50, 0, { model = HVEH })
    M.add(n4)
    h.tick(600)
    local l4 = M.handleOf(4)
    n4.netId = 75
    Pr.onPromote(n4, 75)
    h.ents[h.W.ped].y = 47.0
    h.W.trying, h.W.seat = l4, -1
    h.tick(1300)
    eq(#sentC('core:scene:report', 4), 0, 'promoted already: the attempt is not reported')
    local tasks = Pr.stats().enterTasks
    local c4 = makeClone(h, 4, 75, 0, 50, 0, 0)
    h.W.trying = 0
    h.tick(200)
    local last = h.rec.TaskEnterVehicle[#h.rec.TaskEnterVehicle]
    check(Pr.stats().enterTasks == tasks + 1 and last[2] == c4 and last[4] == -1,
        'the swap tasks the ped into the clone (driver seat)')
end

--------------------------------------------------------------------------------
-- C4. snCfg (net-id guard, control, once per control period), the props callback, a promoted mover's clone
--------------------------------------------------------------------------------
do
    local h = client()
    local Pr = h.Pr
    check(type(h.bag) == 'function', 'a snCfg state-bag handler is registered')
    local cfgV = { props = { colorPrimary = 4 }, plate = 'SCN 9', paint = { 12, 12 },
        once = { locked = true, dirt = 3 } }
    h.bag('entity:80', 'snCfg', cfgV)
    eq(Pr.stats().cfgApplied, 0, 'the net id is not here: nothing applied (the guard, no entity lookup)')
    eq(h.n('NetworkGetEntityFromNetworkId'), 0, 'NetworkGetEntityFromNetworkId never runs before the guard')
    local e = makeClone(h, 9, 80, 5, 5, 0, 0)
    h.bag('entity:80', 'snCfg', cfgV)
    h.states[e].snCfg = cfgV                                        -- the bag holds it after the handler
    eq(Pr.stats().cfgApplied, 0, 'here, but another client controls it: nothing')
    h.control[e] = true
    h.tick(1100)
    eq(Pr.stats().cfgApplied, 1, 'the sweep finds this client in control: applied once')
    check(#h.props == 1 and h.props[1].e == e and h.props[1].p.colorPrimary == 4, 'props through Vehicles.setProps')
    local lock = h.rec.SetVehicleDoorsLocked[#h.rec.SetVehicleDoorsLocked]
    check(lock[1] == e and lock[2] == 2, 'once.locked → SetVehicleDoorsLocked(e, 2)')
    local paint = h.rec.SetVehicleColours[#h.rec.SetVehicleColours]
    check(paint[1] == e and paint[2] == 12 and paint[3] == 12, 'the stable paint')
    local plate = h.rec.SetVehicleNumberPlateText[#h.rec.SetVehicleNumberPlateText]
    check(plate[1] == e and plate[2] == 'SCN 9', 'the plate after the props')
    h.tick(3000)
    eq(Pr.stats().cfgApplied, 1, 'not again while the control lasts')
    h.control[e] = nil
    h.tick(1100)
    h.control[e] = true
    h.tick(1100)
    eq(Pr.stats().cfgApplied, 2, 'a new control period: applied again')
    h.bag('entity:80', 'snCfg', { once = { locked = false } })
    h.states[e].snCfg = { once = { locked = false } }
    h.tick(10)
    eq(Pr.stats().cfgApplied, 3, 'a new config: applied at once')
    local locks = #h.rec.SetVehicleDoorsLocked
    eq(locks, 2, 'unlocked is not an "on" state: no lock native')
    h.bag('entity:80', 'snCfg', nil)
    eq(Pr.stats().configs, 0, 'a cleared bag forgets the entity')
    -- a ped clone
    local pe = makeClone(h, 10, 81, 6, 6, 0, 0, 1)
    h.control[pe] = true
    h.bag('entity:81', 'snCfg', { frozen = true, invincible = true, blockEvents = true,
        scenario = 'WORLD_HUMAN_SMOKING' })
    check(nrec(h, 'SetPedDefaultComponentVariation') >= 1 and h.ents[pe].frozen == true
        and h.rec.TaskStartScenarioInPlace[#h.rec.TaskStartScenarioInPlace][2] == 'WORLD_HUMAN_SMOKING',
        'ped: default look, frozen, scenario')
    -- the props callback (only the controlling client of a scene clone answers)
    local function ask(netId)
        local before = #cstubs.sent
        cstubs.triggerOn(h.env, 'core:cb:req:core:scene:props', 0, 'k' .. netId, netId)
        local last = cstubs.sent[#cstubs.sent]
        if #cstubs.sent == before or last.name ~= 'core:cb:res:core:scene:props' then return 'none' end
        return last.args[2], last.args[3]
    end
    local ok1, props = ask(80)
    check(ok1 == true and type(props) == 'table' and props.colorPrimary == 9, 'the owner answers Vehicles.getProps')
    h.control[e] = nil
    local ok2, p2 = ask(80)
    check(ok2 == true and p2 == nil, 'without control: no props')
    local ok3, p3 = ask(99)
    check(ok3 == true and p3 == nil, 'an unknown net id: no props')
    local ok4 = ask(81)
    eq(ok4, true, 'a ped: answered, without props')
    -- a promoted mover: its owner places the clone along the motion
    local mv = h.motion
    local okM, desc = mv.validate({ t = 'tween', t0 = 0, d = 100000, to = { x = 50, y = 0, z = 0 } })
    local node = h.node(11, 'prop', 'prop', 0, 40, 0, { model = HPROP }, { motion = okM and desc or nil,
        netId = 82, flags = 3 })
    local mc = makeClone(h, 11, 82, 0, 40, 0, 0, 3)
    h.control[mc] = true
    h.M.add(node)
    h.tick(1000)
    check(h.M.handleOf(11) == nil and (h.ents[mc].x ~= 0 or h.ents[mc].y ~= 40),
        'the owner moves the clone along the motion')
end

--------------------------------------------------------------------------------
-- C5. the drive loop (per frame only while in control), a clone that leaves this client, a re-promotion that
-- overtakes a demotion
--------------------------------------------------------------------------------
do
    local h = client()
    local Pr, M = h.Pr, h.M
    local okM, desc = h.motion.validate({ t = 'tween', t0 = 0, d = 100000, to = { x = 50, y = 0, z = 0 } })
    local node = h.node(1, 'prop', 'prop', 0, 40, 0, { model = HPROP }, { motion = okM and desc or nil,
        netId = 90, flags = 3 })
    local mc = makeClone(h, 1, 90, 0, 40, 0, 0, 3)
    M.add(node)
    h.tick(600)
    eq(Pr.stats().drives, 1, 'a promoted mover is driven by whoever controls its clone')
    local n0 = h.n('SetEntityCoordsNoOffset')
    h.tick(2000)
    eq(h.n('SetEntityCoordsNoOffset') - n0, 0, 'not in control: never placed')
    h.control[mc] = true
    h.tick(600)
    local n1 = h.n('SetEntityCoordsNoOffset')
    h.frames(10)
    local placed = h.n('SetEntityCoordsNoOffset') - n1
    check(placed >= 9 and placed <= 11, 'in control: placed every frame (' .. placed .. ' in 10 frames)')
    h.cam(0, 0, 0, 0, 180)                                          -- looking away: still driven
    local n2 = h.n('SetEntityCoordsNoOffset')
    h.frames(10)
    check(h.n('SetEntityCoordsNoOffset') - n2 >= 9, 'whatever the view')
    h.control[mc] = nil
    h.tick(600)
    local n3 = h.n('SetEntityCoordsNoOffset')
    h.tick(2000)
    eq(h.n('SetEntityCoordsNoOffset') - n3, 0, 'control lost: the per-frame loop ends')
    -- RV6 F7: the clone leaves this client while the node is still promoted — NO local copy at the stale pose (a
    -- frozen ghost at the parking spot): the record stands in, empty, until the clone is back or a DEMOTE
    h.cam(0, 0, 0, 0, 0)
    local v = h.node(2, 'vehicle', 'vehicle', 0, 20, 0, { model = HVEH }, { netId = 91, flags = 2 })
    local vc = makeClone(h, 2, 91, 0, 20, 0, 0)
    M.add(v)
    h.tick(600)
    eq(M.handleOf(2), nil, 'the stand-in')
    local made = nrec(h, 'CreateVehicle')
    h.ents[vc].deleted = true
    h.netEntities[91] = nil
    h.tick(1700)
    check(M.handleOf(2) == nil and nrec(h, 'CreateVehicle') == made and Pr.stats().phases.lost == 1,
        'the clone left while still promoted: no local copy at the stale pose (RV6 F7)')
    v.x = 30.0                                                      -- a MOVE of the pose the server follows
    M.update(v, 'move')
    h.tick(1100)
    check(M.handleOf(2) == nil and nrec(h, 'CreateVehicle') == made, 'a MOVE while promoted: still no local copy')
    local vc2 = makeClone(h, 2, 91, 0, 30, 0, 0)
    h.tick(1100)
    eq(Pr.cloneOf(2), vc2, 'the clone came back: it stands in again')
    -- a re-promotion overtakes a demotion: the hidden copy shows at once, then waits for the new clone
    v.netId = nil
    Pr.onDemote(v)
    h.tick(600)
    local l3 = M.handleOf(2)
    eq(h.ents[l3].visible, false, 'demoting: the new copy is hidden')
    v.netId = 92
    Pr.onPromote(v, 92)
    eq(h.ents[l3].visible, true, 're-promoted: revealed at once')
    eq(Pr.stats().polled, 1, 'and polled for the new clone')
end

--------------------------------------------------------------------------------
-- C6. a vehicle's one-shot config (D-A): the cosmetic props for every owner, `once` (wear, lock, dirt) until the
-- server strips it — reported through core:scene:applied; a core vehicle takes its lock from its `locked` bag only
--------------------------------------------------------------------------------
do
    local h = client()
    local e = makeClone(h, 21, 120, 5, 5, 0, 0)
    local full = { props = { colorPrimary = 4 }, plate = 'ONE 1',
        once = { wear = { bodyHealth = 650.0, fuelLevel = 40.0 }, locked = true, dirt = 5 } }
    h.states[e].snCfg = full
    h.control[e] = true
    h.bag('entity:120', 'snCfg', full)
    h.tick(10)
    check(#h.props == 1 and h.props[1].e == e and h.props[1].p.fuelLevel == 40.0 and h.props[1].p.colorPrimary == 4,
        'the first owner applies the cosmetic props and the one-shot wear in one setProps')
    eq(#sentC('core:scene:applied', 21), 1, 'and sends core:scene:applied(id) — its own event')
    eq(#sentC('core:scene:report', 21), 0, 'never core:scene:report (whose 250 ms cooldown dropped it: RV5 F1)')
    local kept = { props = { colorPrimary = 4 }, plate = 'ONE 1', applied = true }   -- what the server keeps
    h.states[e].snCfg = kept
    local plates = nrec(h, 'SetVehicleNumberPlateText')
    h.bag('entity:120', 'snCfg', kept)
    h.tick(10)
    local p2 = h.props[2] and h.props[2].p
    check(#h.props == 2 and p2.colorPrimary == 4 and p2.fuelLevel == nil and p2.bodyHealth == nil,
        'the stripped config: the cosmetic props again (idempotent), never the wear')
    eq(nrec(h, 'SetVehicleNumberPlateText'), plates + 1, 'the per-owner part too')
    eq(#sentC('core:scene:applied', 21), 1, 'and nothing is reported for it')
    local locks = nrec(h, 'SetVehicleDoorsLocked')
    h.control[e] = nil                                             -- another client takes over, then this one again
    h.tick(1100)
    h.control[e] = true
    h.tick(1100)
    local pl = h.props[#h.props].p
    check(#h.props == 3 and pl.fuelLevel == nil and pl.bodyHealth == nil and pl.colorPrimary == 4,
        'an owner change re-applies the cosmetics, never the wear (damage, fuel)')
    eq(nrec(h, 'SetVehicleDoorsLocked'), locks, 'nor the lock (a keys-unlock survives)')
    -- a core vehicle (state coreVeh): the snapshot's lock is never applied, its props are
    local e2 = makeClone(h, 22, 121, 8, 8, 0, 0)
    h.states[e2].coreVeh = true
    local cfg2 = { props = { colorPrimary = 1 }, once = { locked = true } }
    h.states[e2].snCfg = cfg2
    h.control[e2] = true
    local locks2, n2 = nrec(h, 'SetVehicleDoorsLocked'), #h.props
    h.bag('entity:121', 'snCfg', cfg2)
    h.tick(10)
    eq(nrec(h, 'SetVehicleDoorsLocked'), locks2, 'a core vehicle: no lock from the snapshot (its locked bag decides)')
    eq(#h.props, n2 + 1, 'its props')
    eq(#sentC('core:scene:applied', 22), 1, 'reported applied')
    -- control lost while the props went on: no report (the server checks the owner anyway)
    local e3 = makeClone(h, 23, 122, 9, 9, 0, 0)
    local cfg3 = { props = { colorPrimary = 2 }, once = { dirt = 2 } }
    h.states[e3].snCfg = cfg3
    h.control[e3] = true
    local V = h.env.Core.Vehicles
    local set = V.setProps
    V.setProps = function(ent, p)
        h.control[ent] = nil                                       -- (setProps waited, the control moved on)
        return set(ent, p)
    end
    h.bag('entity:122', 'snCfg', cfg3)
    h.tick(10)
    V.setProps = set
    eq(#sentC('core:scene:applied', 23), 0, 'control gone after the apply: nothing reported')
end

--------------------------------------------------------------------------------
-- C7. RV5 F1 / RV6 F1 (client): while this client controls a clone whose LIVE bag still carries the one-shot part
-- (the report was lost), its 1 s sweep sends core:scene:applied again (≥ 2 s apart); a trimmed bag stops it
--------------------------------------------------------------------------------
do
    local h = client()
    local e = makeClone(h, 31, 130, 5, 5, 0, 0)
    local full = { props = { colorPrimary = 3 }, once = { wear = { bodyHealth = 1000.0, fuelLevel = 65.0 },
        locked = true } }
    h.states[e].snCfg = full
    h.control[e] = true
    h.bag('entity:130', 'snCfg', full)
    h.tick(10)
    eq(#sentC('core:scene:applied', 31), 1, 'applied once, reported')
    h.tick(1000)
    eq(#sentC('core:scene:applied', 31), 1, 'not again inside 2 s')
    h.tick(1200)                                                    -- the server never got it: the bag keeps once
    eq(#sentC('core:scene:applied', 31), 2, 'the sweep reports again while the live bag keeps the one-shot part')
    h.tick(10000)
    local n = #sentC('core:scene:applied', 31)
    check(n >= 6 and n <= 8, 'about every 2 s while it stays (' .. n .. ')')
    eq(#h.props, 1, 'the one-shot part itself is applied once per control period')
    local kept = { props = { colorPrimary = 3 }, applied = true }
    h.states[e].snCfg = kept
    h.bag('entity:130', 'snCfg', kept)
    local n2 = #sentC('core:scene:applied', 31)
    h.tick(6000)
    eq(#sentC('core:scene:applied', 31), n2, 'trimmed by the server: no more reports')
    local e2 = makeClone(h, 32, 131, 7, 7, 0, 0)
    h.states[e2].snCfg = full
    h.bag('entity:131', 'snCfg', full)
    h.tick(5000)
    eq(#sentC('core:scene:applied', 32), 0, 'another client controls it: nothing applied, nothing reported')
end

--------------------------------------------------------------------------------
-- C8. RV6 F12: the demotion's hidden copy is never revealed mid fade-in — the materialiser's fade-in on it is ended
-- while the clone still stands, so the frame the clone goes it shows opaque
--------------------------------------------------------------------------------
do
    local h = client()
    local Pr, M = h.Pr, h.M
    local c = makeClone(h, 41, 140, 0, 10, 0, 0)
    local n = h.node(41, 'vehicle', 'vehicle', 0, 10, 0, { model = HVEH }, { netId = 140, flags = 2 })
    M.add(n)
    h.tick(600)
    eq(M.handleOf(41), nil, 'the clone stands in')
    n.netId = nil
    Pr.onDemote(n)                                                   -- DEMOTE: a new local copy, hidden
    local l
    for _ = 1, 60 do
        h.frames(1)
        l = M.handleOf(41)
        if l then break end
    end
    check(l and h.ents[l].visible == false, 'the new copy is created hidden')
    h.frames(2)
    local F = h.C.fades
    check(F.dir(l) == nil and h.ents[l].alpha == nil, 'its fade-in is ended at once while hidden (alpha reset)')
    h.ents[c].deleted = true                                         -- the server deletes the clone
    h.netEntities[140] = nil
    h.frames(1)
    check(h.ents[l].visible == true and h.ents[l].alpha == nil and F.dir(l) == nil,
        'revealed the frame the clone is gone: opaque, no fade running (RV6 F12)')
    check(Pr.stats().fadeEnds >= 1, 'counted')
end

--------------------------------------------------------------------------------
-- C9. RV4 F12 (client): a re-promotion with the SAME clone (the server kept it: someone got in during the delete
-- window) drops the hidden copy unseen; RV6 F7: a lost stand-in gets its local copy back through the DEMOTE only
--------------------------------------------------------------------------------
do
    local h = client()
    local Pr, M = h.Pr, h.M
    local c = makeClone(h, 51, 150, 0, 10, 0, 0)
    local n = h.node(51, 'vehicle', 'vehicle', 0, 10, 0, { model = HVEH }, { netId = 150, flags = 2 })
    M.add(n)
    h.tick(600)
    n.netId = nil
    Pr.onDemote(n)
    local l
    for _ = 1, 60 do
        h.frames(1)
        l = M.handleOf(51)
        if l then break end
    end
    check(l and h.ents[l].visible == false, 'demoting: the new copy is hidden under the clone')
    n.netId = 150
    Pr.onPromote(n, 150)
    check(h.ents[l].visible == false, 'promoted again with the SAME clone: the hidden copy is never shown')
    h.tick(1100)
    check(M.handleOf(51) == nil and Pr.cloneOf(51) == c and (h.ents[l].deleted or h.ents[l].visible == false),
        'the swap takes it away: the clone stands in again')
    eq(Pr.stats().kept, 1, 'counted')
    local c2 = makeClone(h, 52, 151, 0, 20, 0, 0)
    local n2 = h.node(52, 'vehicle', 'vehicle', 0, 20, 0, { model = HVEH }, { netId = 151, flags = 2 })
    M.add(n2)
    h.tick(600)
    h.ents[c2].deleted = true                                         -- the clone left this client
    h.netEntities[151] = nil
    h.tick(1100)
    check(M.handleOf(52) == nil and Pr.stats().phases.lost == 1, 'lost: no local copy while still promoted')
    n2.netId, n2.x = nil, 5.0                                         -- the DEMOTE, at the followed pose
    Pr.onDemote(n2)
    h.tick(600)
    local l2 = M.handleOf(52)
    check(l2 and h.ents[l2].visible ~= false and h.ents[l2].x == 5.0,
        'the DEMOTE brings the local copy back, at its pose, visible (the clone is gone)')
end

do
    local failures = cstubs and cstubs.failures or {}
    check(#failures == 0, 'client VM: no uncaught thread or handler errors (' .. tostring(failures[1]) .. ')')
end

H.finish()
