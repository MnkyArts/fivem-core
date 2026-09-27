--[[
    core/tests/scene_parked_tests.lua — parked vehicles (DESIGN §55.21.4): server/vehicles.lua +
    server/vehicles_park.lua on a core server VM (the real api, hooks, db (the Postgres test bridge, DESIGN §56.10),
    player, playergrid) with a
    recording fake Core.Scene (spawn / get / set / move / remove / promote / demote / on / list / stats; set and move
    demote a promoted node first, like R.promote.beforeChange) and drivers for the promote worker and the demotion
    (clone with state sn, the promoted / demoted hooks). A client VM in the same world answers core:vehicles:props
    through client/vehicles.lua (the real round trip).

        lua5.4 tests/scene_parked_tests.lua    (from the resource directory, or from tests/)

    Covers park (netId / vehId, the owner's props, refusals, the caller), promotion → adoption, demotion → the
    record, spawnRecord / restoreRecord / store / delete / deleteRecord on parked records, getInfoByRecord,
    AutoPark (rest, radius, occupants, slices, the worker's re-check), the boot check and core stop; the §56 port
    (section 22): the boot's ONE world read in last_used_at order, a failed read that changes nothing, meta kept.
    Records written behind core's back go in by SQL (putRecord / bridge.sql); the mirror of the world records
    (server/vehicles.lua) learns such a change at the next read of that record (V.getRecord).
]]

local here = (arg and arg[0] or 'tests/scene_parked_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- the real-stack harness of sections 14 / 20 — and the ONE stubs instance (one test-database bridge per process)
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local RH = dofile(here .. '/scene_server_harness.lua')
local stubs = RH.stubs
local v3 = stubs.vector3
local bridge = stubs.bridge

--- A direct query (as the invoker `tests`); raises on an error.
local function sql(text, params)
    local rows, err = bridge.sql(text, params)
    if not rows then error('scene parked: ' .. tostring(err), 2) end
    return rows
end

--- A record written behind core's back (fixtures, a previous server): record fields -> one INSERT of the given
--- columns (absent = the column default; parked false = NULL; lastUsedAt in Unix seconds).
local function putRecord(id, t)
    local cols, vals, params = { 'id' }, { '$1' }, { id }
    local function add(col, v, cast)
        if v == nil then return end
        params[#params + 1] = v
        cols[#cols + 1] = col
        vals[#vals + 1] = (cast == 'ts' and 'to_timestamp($%d)' or ('$%d' .. (cast or ''))):format(#params)
    end
    add('owner_character_id', t.ownerCharId or nil)
    add('model', t.model or 1234)
    add('model_name', t.modelName)
    add('plate', t.plate or id:upper():sub(1, 8))
    add('props', t.props and stubs.json.encode(t.props), '::jsonb')
    add('stored', t.stored)
    add('destroyed', t.destroyed)
    add('parked', t.parked or nil)
    add('locked', t.locked)
    add('keys', t.keys, '::text[]')
    add('position', t.position and stubs.json.encode(t.position), '::jsonb')
    add('meta', t.meta and stubs.json.encode(t.meta), '::jsonb')
    add('last_used_at', t.lastUsedAt, 'ts')
    sql(('INSERT INTO vehicles (%s) VALUES (%s)'):format(table.concat(cols, ', '), table.concat(vals, ', ')), params)
end

--- A character row (the vehicles owner FK) for a fixture charId.
local function ensureChar(id)
    sql('INSERT INTO accounts (id, license) VALUES ($1, $2) ON CONFLICT DO NOTHING', { 'acc-' .. id, 'license:' .. id })
    sql('INSERT INTO characters (id, account_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', { id, 'acc-' .. id })
end

--- Records every core_db export call `env` makes from now on -> the live log { { fn, args } }.
local function recordDb(env)
    local inner, log = rawget(env.exports, 'core_db'), {}
    rawset(env.exports, 'core_db', setmetatable({ synchronous = true }, { __index = function(t, name)
        local f = inner[name]
        if type(f) ~= 'function' then return f end
        local wrapped = function(_, ...)
            log[#log + 1] = { fn = name, args = table.pack(...) }
            return f(inner, ...)
        end
        rawset(t, name, wrapped)
        return wrapped
    end }))
    return log
end

local passed, failed = 0, 0
local function check(cond, label)
    if cond then passed = passed + 1 return true end
    failed = failed + 1
    print('FAIL  [scene parked] ' .. label)
    return false
end
local function eq(actual, expected, label)
    return check(actual == expected, ('%s (expected %s, got %s)'):format(label, tostring(expected), tostring(actual)))
end
local function errOf(...) return select(2, ...) end

local function deep(t)
    if type(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deep(v) end
    return setmetatable(out, getmetatable(t))
end

--------------------------------------------------------------------------------
-- The fake Core.Scene (recording) and its drivers
--------------------------------------------------------------------------------

-- the real lib/scene/shared.lua (I-1: Scene.WEAR / splitProps / mergeWear), handed to the fake scene below
local sceneLib = {}
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in lib file
assert(loadfile(here .. '/../lib/scene/shared.lua'))(sceneLib)

local function fakeScene(env)
    local Core = env.Core
    local S = { nodes = {}, nextId = 1, log = {}, handlers = {}, loaded = true, clones = {}, promoteAnswer = { true },
        WEAR = sceneLib.WEAR, splitProps = sceneLib.splitProps, mergeWear = sceneLib.mergeWear }
    local function copy(n)
        local c = deep(n)
        if S.clones[n.id] then c.promoted = { netId = S.clones[n.id].netId } end
        return c
    end
    local function fire(event, n, ...)
        for _, fn in ipairs(S.handlers[event] or {}) do fn(copy(n), ...) end
    end
    S.fire = fire
    local function log(op, t)
        t.op, t.caller = op, Core.Registry.getCaller()
        S.log[#S.log + 1] = t
        return t
    end
    local function mine(id)
        local n = S.nodes[id]
        if not n then return nil, 'missing' end
        local caller = Core.Registry.getCaller()
        if caller ~= 'core' and caller ~= n.owner then return nil, 'owner' end
        return n
    end
    --- The engine's demoted payload (FX1b): { reason, destroyed, pos, rot, bucket, wear }.
    local function how(n, reason, destroyed)
        local _, wear = sceneLib.splitProps(n.fields.props)
        return { reason = reason, destroyed = destroyed == true, pos = deep(n.pos), rot = deep(n.rot),
            bucket = n.bucket, wear = wear }
    end
    --- R.promote.beforeChange: a promoted node is demoted (synchronously, at its stored pose) before a change.
    local function demoteFirst(n)
        if not S.clones[n.id] then return end
        S.clones[n.id] = nil
        fire('demoted', n, how(n, 'forced'))
    end
    function S.spawn(def)
        log('spawn', { def = deep(def) })
        if S.spawnAnswer then return table.unpack(S.spawnAnswer) end
        local id = S.nextId
        S.nextId = id + 1
        S.nodes[id] = { id = id, kind = def.kind, owner = Core.Registry.getCaller(), bucket = def.bucket or 0,
            pos = deep(def.pos), rot = deep(def.rot), fields = deep(def.fields) or {}, persist = def.persist == true,
            authority = deep(def.authority) }
        return id
    end
    function S.get(id)
        local n = S.nodes[id]
        return n and copy(n) or nil
    end
    function S.set(id, patch)
        log('set', { id = id, patch = deep(patch) })
        local n, err = mine(id)
        if not n then return false, err end
        demoteFirst(n)
        for k, v in pairs(patch or {}) do n.fields[k] = deep(v) end
        return true
    end
    function S.move(id, pos, rot)
        log('move', { id = id, pos = deep(pos), rot = deep(rot) })
        local n, err = mine(id)
        if not n then return false, err end
        demoteFirst(n)
        n.pos, n.rot = deep(pos), deep(rot or n.rot)
        return true
    end
    function S.remove(id)
        log('remove', { id = id })
        local n, err = mine(id)
        if not n then return false, err end
        S.nodes[id], S.clones[id] = nil, nil                  -- (the real index tap dooms the clone)
        fire('removed', n, 'remove')
        return true
    end
    function S.promote(id)
        log('promote', { id = id })
        return table.unpack(S.promoteAnswer)
    end
    function S.demote(id)
        log('demote', { id = id })
        if not S.clones[id] then return nil, 'not_promoted' end
        if S.demoteAnswer then return table.unpack(S.demoteAnswer) end
        return true
    end
    function S.on(event, key, fn)
        log('on', { event = event, key = key })
        S.handlers[event] = S.handlers[event] or {}
        table.insert(S.handlers[event], fn)
        return 'sl:' .. #S.log
    end
    function S.list(f)
        local out = {}
        for id, n in pairs(S.nodes) do
            if (not f.owner or n.owner == f.owner) and (not f.kind or n.kind == f.kind) then out[#out + 1] = id end
        end
        table.sort(out)
        return out
    end
    function S.stats() return { loaded = S.loaded } end

    --- The promote worker: a networked clone (state sn = id) at the node's pose, then the promoted hook.
    function S.promoteNow(id)
        local n = S.nodes[id]
        local model = n.fields.model
        local e = stubs.newEntity(2, { model = type(model) == 'number' and model or env.GetHashKey(model),
            vehType = n.fields.vtype, plate = n.fields.plate })
        stubs.coords[e], stubs.headings[e] = v3(n.pos.x, n.pos.y, n.pos.z), n.rot.z
        stubs.entityState(env, e).sn = id
        local netId = stubs.entities[e].netId
        S.clones[id] = { netId = netId, entity = e }
        fire('promoted', n, netId)
        return netId, e
    end
    --- finishDemote as the engine does it (FX1b): the node takes the clone's last pose (+ bucket), the owner's
    --- read-back changes only the WEAR keys of its props (Scene.mergeWear, the node's plate), then the hook
    --- demoted (copy, { reason, destroyed, pos, rot, bucket, wear }); the clone goes later.
    function S.demoteNow(id, readBack, pos, opts)
        opts = opts or {}
        local n, cl = S.nodes[id], S.clones[id]
        if pos then n.pos = deep(pos) end
        if opts.bucket then n.bucket = opts.bucket end
        if readBack then
            local merged = sceneLib.mergeWear(n.fields.props, readBack)
            merged.plate = n.fields.plate
            n.fields.props = merged
        end
        S.clones[id] = nil
        fire('demoted', n, how(n, opts.reason or 'rest', opts.destroyed))
        if cl then stubs.entities[cl.entity].exists = false end
    end
    --- R.promote.adopt (FX1b): an EXISTING networked entity becomes node id's clone (the promoted hook at once).
    function S.adopt(id, e)
        log('adopt', { id = id, e = e })
        local n = S.nodes[id]
        if not n then return nil, 'missing' end
        if S.adoptAnswer then return table.unpack(S.adoptAnswer) end
        stubs.entityState(env, e).sn = id
        local netId = stubs.entities[e].netId
        S.clones[id] = { netId = netId, entity = e }
        fire('promoted', n, netId)
        return true
    end
    function S.count(op)
        local c = 0
        for _, l in ipairs(S.log) do if l.op == op then c = c + 1 end end
        return c
    end
    function S.last(op)
        for i = #S.log, 1, -1 do if S.log[i].op == op then return S.log[i] end end
        return nil
    end
    return S
end

--------------------------------------------------------------------------------
-- The VMs: core server (+ the fake scene), optionally core client (client/vehicles.lua answers the props)
--------------------------------------------------------------------------------

local SERVER_FILES <const> = {
    'shared/ui_forms.lua', 'server/api.lua', 'shared/hooks.lua', 'server/db.lua',
    'server/globals.lua', 'server/notify.lua', 'server/perms.lua', 'server/player_store.lua', 'server/player.lua',
    'server/playergrid.lua', 'server/money.lua', 'server/factions.lua', 'server/vehicles.lua',
    'server/vehicles_park.lua', 'server/vehicles_fleet.lua', 'server/getters.lua',
}

local W                                             -- the world knobs: rot, vel, owner (entity -> src)
local hooks                                         -- { spawned = { {netId, info} }, deleted = { netId } }

--- opts = { keepDb (the same database: a core restart), config = fn(Config), before = fn(env, Core, S) (records /
---          nodes before the boot check),
---          noScene (no Core.Scene), client (a client VM too), adopt (R.promote.adopt = the fake S.adopt: the
---          engine's hand-off of a live car) }
local function newServer(opts)
    opts = opts or {}
    stubs.newWorld()
    stubs.clear()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
    if not opts.keepDb then stubs.resetServer() end
    stubs.tick(1000)
    W = { rot = {}, vel = {}, owner = {} }
    local env = stubs.newEnv('server', 'core')
    -- the server / CFX forms the stubs lack (fxref): rotation, velocity, bucket, network owner
    env.GetEntityRotation = function(e)
        local r = W.rot[e]
        return r and v3(r[1], r[2], r[3]) or v3(0.0, 0.0, stubs.headings[e] or 0.0)
    end
    env.GetEntityVelocity = function(e)
        local v = W.vel[e]
        return v and v3(v[1], v[2], v[3]) or v3(0.0, 0.0, 0.0)
    end
    env.GetEntityRoutingBucket = function(e) return stubs.entities[e] and stubs.entities[e].bucket or 0 end
    env.NetworkGetEntityOwner = function(e) return W.owner[e] or -1 end
    env.FreezeEntityPosition = function(e, on)         -- the server RPC form (fxref)
        local r = stubs.entities[e]
        if r then r.frozen = on end
    end
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    if opts.config then opts.config(env.Config) end
    for i = 1, #SERVER_FILES do stubs.loadFile(env, SERVER_FILES[i]) end
    local Core = env.Core
    local S = not opts.noScene and fakeScene(env) or nil
    if S then rawset(Core, 'Scene', S) end
    if S and opts.adopt then
        rawset(Core, 'SceneRuntime', { promote = { adopt = function(...) return S.adopt(...) end,
            beforeStop = function() return true end } })
    end
    hooks = { spawned = {}, deleted = {} }
    Core.on('vehicleSpawned', function(netId, info) hooks.spawned[#hooks.spawned + 1] = { netId = netId, info = info } end)
    Core.on('vehicleDeleted', function(netId) hooks.deleted[#hooks.deleted + 1] = netId end)
    if opts.before then opts.before(env, Core, S) end
    local client
    if opts.client then
        client = stubs.newEnv('client', 'core')
        client.GetVehiclePedIsTryingToEnter = function() return 0 end
        client.NetworkDoesEntityExistWithNetworkId = function(netId)
            for _, rec in pairs(stubs.entities) do if rec.netId == netId and rec.exists then return 1 end end
            return false
        end
        client.NetworkGetEntityFromNetworkId = function(netId)
            for e, rec in pairs(stubs.entities) do if rec.netId == netId and rec.exists then return e end end
            return 0
        end
        client.GetEntityType = function(e) return stubs.entities[e] and stubs.entities[e].type or 0 end
        client.NetworkHasControlOfEntity = function(e)
            return (W.owner[e] == stubs.clientSrc and not W.noControl) and 1 or false
        end
        client.Entity = function(e) return { state = stubs.entityState(client, e) } end
        stubs.loadImport(client)
        stubs.loadFile(client, 'shared/config.lua')
        stubs.loadFile(client, 'client/vehicles.lua')
        client.Core.Vehicles.getProps = function(veh)        -- the natives behind getProps are not the point here
            return { colorPrimary = 12, plate = 'FAKE', bodyHealth = 640.5, mods = { [11] = 3 }, veh = veh }
        end
    end
    stubs.tick(0)                                   -- the boot thread: the hooks, the check, AutoPark
    return env, Core, S, client
end

--- Runs fn(...) in a thread (park and spawnRecord yield); the returned getter answers its results once it ended.
local function async(env, fn, ...)
    local args, out = table.pack(...), nil
    env.CreateThread(function() out = table.pack(fn(table.unpack(args, 1, args.n))) end)
    return function() return out end
end

--- The last core:vehicles:props request, answered by `src` with `props` (ok = false: a refusal).
local function answerProps(env, src, props, ok)
    for i = #stubs.sent, 1, -1 do
        local s = stubs.sent[i]
        if s.name == 'core:cb:req:core:vehicles:props' then
            stubs.triggerOn(env, 'core:cb:res:core:vehicles:props', src, s.args[1], ok ~= false, props)
            return s
        end
    end
    return nil
end

local function propsRequests()
    local n = 0
    for i = 1, #stubs.sent do if stubs.sent[i].name == 'core:cb:req:core:vehicles:props' then n = n + 1 end end
    return n
end

--- A persisted vehicle (spawned by model name, owned by src 1's character) at pos; -> netId, entity, vehId.
local function persisted(Core, pos, extra)
    local opts = { model = 'adder', coords = pos or v3(500.0, 500.0, 20.0), heading = 90.0, ownerSrc = 1 }
    for k, v in pairs(extra or {}) do opts[k] = v end
    local netId = Core.Vehicles.spawn(opts)
    local vehId = Core.Vehicles.persist(netId)
    return netId, Core.Vehicles.getEntity(netId), vehId
end

--- Ends a section: core stops in that VM, so its threads (AutoPark, the park worker) end before the next VM reuses
--- the shared stub world (entity handles restart at 1001 after stubs.resetServer).
local function teardown(env)
    stubs.triggerOn(env, 'onResourceStop', 0, 'core')
    stubs.tick(2000)
end

local function player(env, src, pos)
    stubs.connectPlayer(env, src, { license = 'license:p' .. src, name = 'P' .. src, coords = pos or v3(0.0, 0.0, 0.0) })
    stubs.tick(0)
    return stubs.peds[src]
end

--------------------------------------------------------------------------------
-- 1. park(netId): the owner's props, the node (as core), the record, the entity goes
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer()
    local V = Core.Vehicles
    player(env, 1)
    local charId = Core.Player.getInfo(1).charId
    eq(S.count('on'), 3, 'the boot thread hooked promoted / demoted / removed')
    local netId, e, vehId = persisted(Core, v3(500.0, 500.0, 20.0), { plate = 'PARK1', locked = true })
    stubs.entities[e].bucket, W.rot[e], W.owner[e] = 7, { 2.0, -1.0, 90.0 }, 1
    eq(V.giveKeys(netId, 'friend-1'), true, 'an extra key')
    eq(V.saveProps(netId, { colorPrimary = 5, mods = { [0] = 2 } }), true, 'cached props')
    local done = async(env, V.park, netId)
    eq(done(), nil, 'park waits for the owner client')
    eq(propsRequests(), 1, 'the owner was asked for the props')
    -- RV4 F1: whoever owns the entity answers — only the damage / wear keys may change (clamped), never a colour,
    -- a mod or the plate
    answerProps(env, 1, { colorPrimary = 135, plate = 'HACKED', bodyHealth = 700.0, tankHealth = -1000.0,
        engineHealth = -4000.0, mods = { [0] = -1, [11] = 3 } })
    local res = done()
    local nodeId = res and res[1]
    check(math.type(nodeId) == 'integer', 'park -> the node id')
    local sp = S.last('spawn')
    eq(sp.caller, 'core', 'the node is spawned as core')
    eq(sp.def.kind, 'vehicle', 'a vehicle node')
    eq(sp.def.persist, true, 'a persistent one')
    eq(sp.def.bucket, 7, "in the vehicle's bucket")
    eq(sp.def.pos.x, 500.0, "at the entity's position")
    eq(sp.def.rot.x, 2.0, 'with its pitch')
    eq(sp.def.rot.z, 90.0, 'and its yaw')
    eq(sp.def.authority and sp.def.authority.mode, 'local', 'D-B: no proximity promotion (authority local)')
    local f = sp.def.fields
    eq(f.model, 'adder', 'the model name the spawn used')
    eq(f.plate, 'PARK1', 'the plate')
    eq(f.locked, true, 'the lock')
    eq(f.vehId, vehId, 'the record id')
    eq(f.vtype, 'automobile', 'vtype from the record meta')
    eq(f.props.colorPrimary, 5, 'RV4 F1: a read-back never changes the colour (the cached one stays)')
    eq(f.props.plate, 'PARK1', "the record's plate over the props' one")
    eq(f.props.mods and f.props.mods[0], 2, 'nor the mods (a zero-based map survives)')
    eq(f.props.mods and f.props.mods[11], nil, 'no mod is added by a read-back')
    eq(f.props.bodyHealth, 700.0, "the owner's damage is taken")
    eq(f.props.tankHealth, 0, 'clamped: a tank health below 0 (a burning car) becomes 0')
    eq(f.props.engineHealth, 0, 'clamped: engine health too')
    local rec = V.getRecord(vehId)
    eq(rec.parked, nodeId, 'the record names its node')
    eq(rec.stored, false, 'and stays out of the garage')
    eq(rec.props.colorPrimary, 5, 'the record keeps its colour')
    eq(rec.props.bodyHealth, 700.0, 'and gets the damage')
    eq(rec.props.plate, 'PARK1', 'and its own plate')
    eq(rec.locked, true, 'the record has the lock')
    eq(#rec.keys, 2, 'and the keys (owner + friend)')
    check(rec.keys[1] == charId or rec.keys[2] == charId, "the owner's key is in the list")
    eq(rec.position.x, 500.0, 'the position')
    eq(rec.position.heading, 90.0, 'the heading')
    eq(rec.position.bucket, 7, 'the bucket')
    eq(rec.modelName, 'adder', 'persist kept the model name')
    -- RV6 F11 (no engine hand-off here: the stop-gap): the car is never deleted first
    eq(stubs.entities[e].exists, true, 'RV6 F11: the live car stays while the local copies appear')
    eq(stubs.entities[e].frozen, true, '... frozen (the copies cannot push it)')
    eq(stubs.entities[e].lockState, 2, '... and locked (nobody gets in)')
    eq(V.exists(netId), false, 'the car is untracked at once')
    eq(V.getInfo(netId), nil, 'getInfo: nil')
    eq(hooks.deleted[#hooks.deleted], netId, 'vehicleDeleted fired')
    stubs.tick(999)
    eq(stubs.entities[e].exists, true, 'still there 999 ms later (DeleteDelayMs 500 + 500)')
    stubs.tick(2)
    eq(stubs.entities[e].exists, false, 'then the entity is deleted')

    -- the owner does not answer: the cached props (1 s timeout)
    local n2, e2, vehId2 = persisted(Core, v3(520.0, 500.0, 20.0))
    W.owner[e2] = 1
    V.saveProps(n2, { colorPrimary = 77 })
    done = async(env, V.park, n2)
    stubs.tick(999)
    eq(done(), nil, 'still waiting at 999 ms')
    stubs.tick(2)
    res = done()
    check(res and math.type(res[1]) == 'integer', 'parked after the timeout')
    eq(S.last('spawn').def.fields.props.colorPrimary, 77, 'with the cached props')
    -- invalid props from the owner: refused, the cached ones instead
    local n3, e3, vehId3 = persisted(Core, v3(540.0, 500.0, 20.0))
    W.owner[e3] = 1
    V.saveProps(n3, { colorPrimary = 3 })
    done = async(env, V.park, n3)
    answerProps(env, 1, { [1] = 'numeric key' })
    eq(done() and math.type(done()[1]), 'integer', 'parked')
    eq(S.last('spawn').def.fields.props.colorPrimary, 3, 'invalid owner props are ignored')
    eq(V.getRecord(vehId3).parked, done()[1], 'record parked')
    -- no owner client (the server holds it): no request, synchronous
    local before = propsRequests()
    local n4, _, vehId4 = persisted(Core, v3(560.0, 500.0, 20.0))
    local ok4, id4 = Core.Registry.withCaller('garage', V.park, n4)
    eq(ok4, true, 'a plugin may park')
    eq(id4, S.nextId - 1, 'and gets the node id')
    eq(V.getRecord(vehId4).parked, id4, 'the record is parked')
    eq(S.last('spawn').caller, 'core', "the node is core's whoever asked")
    eq(S.nodes[id4].owner, 'core', 'owner core')
    eq(propsRequests(), before, 'no owner client, no request (synchronous)')

    -- refusals
    eq(errOf(V.park(nil)), 'bad_target', 'nil target')
    eq(errOf(V.park(0)), 'bad_target', 'netId 0')
    eq(errOf(V.park(70000)), 'bad_target', 'netId out of range')
    eq(errOf(V.park(1.5)), 'bad_target', 'a fractional netId')
    eq(errOf(V.park(12345)), 'missing', 'an untracked netId')
    eq(errOf(V.park('bad id!')), 'bad_target', 'a malformed vehId')
    eq(errOf(V.park('no-such-record')), 'no_record', 'an unknown vehId')
    local loose = V.spawn({ model = 'adder', coords = v3(600.0, 500.0, 20.0) })
    eq(errOf(V.park(loose)), 'not_persisted', 'a vehicle without a record')
    local n5, e5 = persisted(Core, v3(620.0, 500.0, 20.0))
    stubs.vehicleSeats[e5] = { [2] = 999 }
    eq(errOf(V.park(n5)), 'occupied', 'somebody inside (any seat)')
    stubs.vehicleSeats[e5] = nil
    W.owner[e5] = 1
    done = async(env, V.park, n5)
    stubs.vehicleSeats[e5] = { [-1] = 998 }
    answerProps(env, 1, { colorPrimary = 1 })
    eq(done()[2], 'occupied', 'somebody got in while the props were read')
    stubs.vehicleSeats[e5] = nil
    done = async(env, V.park, n5)
    eq(errOf(V.park(n5)), 'busy', 'a second park while the first waits')
    eq(V.store(n5), true, 'stored meanwhile')
    answerProps(env, 1, { colorPrimary = 1 })
    eq(done()[2], 'gone', 'the vehicle left while the props were read')
    local n6, _, vehId6 = persisted(Core, v3(640.0, 500.0, 20.0))
    S.spawnAnswer = { nil, 'fields', { plate = 'pattern' } }
    local r6 = table.pack(V.park(n6))
    S.spawnAnswer = nil
    eq(r6[2], 'fields', "Scene.spawn's refusal is passed on")
    eq(type(r6[3]) == 'table' and r6[3].plate, 'pattern', 'with its detail')
    eq(V.exists(n6), true, 'the vehicle stays in the world')
    eq(V.getRecord(vehId6).parked, false, 'and is not parked')

    -- park(vehId): the parked record answers its node; a live vehicle parks; a stored record is refused;
    -- an out record without a live vehicle parks at its saved position
    local spawns = S.count('spawn')
    eq(V.park(vehId), nodeId, 'park(vehId) of a parked record -> its node')
    eq(S.count('spawn'), spawns, 'no second node')
    local n7, _, vehId7 = persisted(Core, v3(660.0, 500.0, 20.0))
    local id7 = V.park(vehId7)
    check(math.type(id7) == 'integer' and not V.exists(n7), 'park(vehId) of a live vehicle parks it')
    V.store(vehId7)
    eq(errOf(V.park(vehId7)), 'record_stored', 'a garaged record is refused')
    local outId = 'out1'
    putRecord(outId, { ownerCharId = charId, model = env.GetHashKey('blista'),
        plate = 'OUT1', props = { colorPrimary = 4 }, stored = false, locked = true, keys = { 'friend-2' },
        position = { x = 10.0, y = 20.0, z = 30.0, heading = 45.0, bucket = 3 }, meta = { vehType = 'bike' } })
    local idOut = V.park(outId)
    check(math.type(idOut) == 'integer', 'an out record parks from the record')
    sp = S.last('spawn')
    eq(sp.def.pos.y, 20.0, 'at the saved position')
    eq(sp.def.rot.z, 45.0, 'with the saved heading')
    eq(sp.def.bucket, 3, 'in the saved bucket')
    eq(sp.def.fields.model, env.GetHashKey('blista'), 'a record without a name parks with the hash')
    eq(sp.def.fields.vtype, 'bike', 'vtype from the record')
    eq(sp.def.fields.locked, true, 'the record lock')
    eq(V.getRecord(outId).parked, idOut, 'the record is parked')
    -- a live car whose record still names a node (it outlived a restore): the old node goes once it parks
    local n8, _, vehId8 = persisted(Core, v3(680.0, 500.0, 20.0))
    local old8 = V.park(n8)
    sql('UPDATE vehicles SET parked = NULL WHERE id = $1', { vehId8 })        -- (behind core's back)
    local live8 = V.restoreRecord(vehId8)
    sql('UPDATE vehicles SET parked = $2 WHERE id = $1', { vehId8, old8 })
    V.getRecord(vehId8)                                                       -- (the mirror learns it at a read)
    local new8 = V.park(live8)
    check(math.type(new8) == 'integer' and new8 ~= old8, 'the live car parks as a new node')
    eq(S.nodes[old8], nil, 'the stale node is removed')
    eq(V.getRecord(vehId8).parked, new8, 'the record names the new one')
    local bad = 'bad1'
    putRecord(bad, { model = 1, plate = 'BAD1', stored = false, position = { x = 'x' } })
    eq(errOf(V.park(bad)), 'bad_coords', 'an out record without a usable position')
    eq(#stubs.failures, 0, 'section 1: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 2. promoted: the clone is adopted; 3. demoted: props / pose / lock / keys into the record
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer()
    local V = Core.Vehicles
    player(env, 1)
    local charId = Core.Player.getInfo(1).charId
    local netId, _, vehId = persisted(Core, v3(500.0, 500.0, 20.0), { plate = 'PROMO1', locked = true })
    V.giveKeys(netId, 'friend-1')
    V.saveProps(netId, { colorPrimary = 5 })
    local nodeId = V.park(netId)
    local spawnedBefore = #hooks.spawned
    local clone, ce = S.promoteNow(nodeId)
    local info = V.getInfo(clone)
    check(info ~= nil, 'the clone is tracked')
    eq(info.vehId, vehId, 'under its record')
    eq(info.parked, nodeId, 'info.parked names the node')
    eq(info.plate, 'PROMO1', 'the plate')
    eq(info.ownerCharId, charId, 'the owner')
    eq(info.keyMode, 'virtual', 'the key mode')
    eq(info.locked, true, 'the lock from the node')
    eq(info.keys[charId], true, "the owner's key")
    eq(info.keys['friend-1'], true, 'the extra key survived the parking')
    eq(info.spawnedBy, 'core', 'spawned by core')
    local st = stubs.entityState(env, ce)
    eq(st.coreVeh, true, 'state coreVeh')
    eq(st.locked, true, 'state locked')
    eq(st.owner, charId, 'state owner')
    eq(st.keys['friend-1'], true, 'state keys')
    eq(st.keyMode, 'virtual', 'state keyMode')
    eq(st.plate, 'PROMO1', 'state plate')
    eq(st.vehId, vehId, 'state vehId')
    eq(st.coreProps, nil, 'no coreProps projection (snCfg carries the props)')
    eq(#hooks.spawned, spawnedBefore + 1, 'vehicleSpawned fired')
    eq(hooks.spawned[#hooks.spawned].info.parked, nodeId, 'its info names the node')
    eq(V.getInfoByRecord(vehId).netId, clone, 'getInfoByRecord answers the clone')
    eq(V.hasKeys(1, clone), true, 'netId APIs work: hasKeys')
    eq(V.getEntity(clone), ce, 'getEntity')
    local listed = false
    for _, id in ipairs(V.getPlayerVehicles(1)) do if id == clone then listed = true end end
    eq(listed, true, 'getPlayerVehicles lists the clone')

    -- not ours: a maps vehicle node, a plugin node naming a record, a node whose record is gone
    local maps = S.spawn({ kind = 'vehicle', pos = { x = 1.0, y = 1.0, z = 1.0 }, rot = { x = 0, y = 0, z = 0 },
        fields = { model = 'blista', mapEl = 'm:1' } })
    local mapsClone = S.promoteNow(maps)
    eq(V.getInfo(mapsClone), nil, 'a maps vehicle clone is not adopted')
    local ok, plugin = Core.Registry.withCaller('garage', S.spawn, { kind = 'vehicle', pos = { x = 2.0, y = 2.0,
        z = 2.0 }, rot = { x = 0, y = 0, z = 0 }, fields = { model = 'adder', vehId = vehId } })
    check(ok, 'a plugin node')
    eq(V.getInfo((S.promoteNow(plugin))), nil, "a plugin's node naming a record is not adopted")
    stubs.tick(0)
    eq(S.nodes[plugin] ~= nil, true, 'and left alone')
    eq(S.nodes[maps] ~= nil, true, 'the maps node is left alone too')
    local n2 = persisted(Core, v3(530.0, 500.0, 20.0))
    local vehId2 = V.getInfo(n2).vehId
    local node2 = V.park(n2)
    sql('DELETE FROM vehicles WHERE id = $1', { vehId2 })                    -- (behind core's back)
    V.getRecord(vehId2)
    local c2 = S.promoteNow(node2)
    eq(V.getInfo(c2), nil, 'a stale node (record gone) is not adopted')
    stubs.tick(0)
    eq(S.nodes[node2], nil, 'and removed')
    local n2b = persisted(Core, v3(535.0, 500.0, 20.0))
    local vehId2b = V.getInfo(n2b).vehId
    local node2b = V.park(n2b)
    sql('UPDATE vehicles SET parked = $2 WHERE id = $1', { vehId2b, node2b + 1000 })  -- it parks another node now
    V.getRecord(vehId2b)
    eq(V.getInfo((S.promoteNow(node2b))), nil, 'a node its record does not name is not adopted')
    stubs.tick(0)
    eq(S.nodes[node2b], nil, 'and removed')
    local n2c = persisted(Core, v3(537.0, 500.0, 20.0))
    local vehId2c = V.getInfo(n2c).vehId
    local node2c = V.park(n2c)
    sql('UPDATE vehicles SET stored = true WHERE id = $1', { vehId2c })      -- garaged behind the node's back
    V.getRecord(vehId2c)
    eq(V.getInfo((S.promoteNow(node2c))), nil, 'the node of a garaged record is not adopted')

    -- 3. while promoted: lock, props, keys change; the demotion carries them into the record and the node
    eq(V.setLocked(clone, false), true, 'unlocked while promoted')
    eq(V.saveProps(clone, { colorPrimary = 33 }), true, 'props saved while promoted')
    eq(stubs.entityState(env, ce).coreProps, nil, 'still no coreProps on the clone')
    eq(V.getRecord(vehId).props.colorPrimary, 33, 'the record got them at once')
    eq(V.removeKeys(clone, 'friend-1'), true, 'a key taken back')
    local sets = S.count('set')
    local deleted = #hooks.deleted
    S.demoteNow(nodeId, nil, { x = 510.0, y = 505.0, z = 20.5 })     -- the owner did not answer
    local rec = V.getRecord(vehId)
    eq(rec.parked, nodeId, 'still parked as the node')
    eq(rec.stored, false, 'out of the garage')
    eq(rec.position.x, 510.0, 'the demotion pose')
    eq(rec.props.colorPrimary, 33, 'the props saved while promoted win over the stale node props')
    eq(rec.locked, false, 'the lock')
    eq(#rec.keys, 1, 'the keys')
    eq(S.count('set'), sets + 1, 'the node fields follow')
    eq(S.nodes[nodeId].fields.locked, false, 'node locked = false')
    eq(S.nodes[nodeId].fields.props.colorPrimary, 33, 'node props')
    eq(S.last('set').caller, 'core', 'as core')
    eq(V.getInfo(clone), nil, 'the clone is untracked')
    eq(#hooks.deleted, deleted + 1, 'vehicleDeleted fired')
    eq(hooks.deleted[#hooks.deleted], clone, 'for the clone')
    local byRec = V.getInfoByRecord(vehId)
    eq(byRec.netId, nil, 'getInfoByRecord: no netId while parked')
    eq(byRec.parked, nodeId, 'parked')
    eq(byRec.locked, false, 'the lock from the node')

    -- promoted again: the adoption reads the new state; RV4 F1 (the demotion path): the owner's read-back changes
    -- only the wear — a stranger who owns the clone cannot repaint it, strip its mods or rename it
    local clone2 = S.promoteNow(nodeId)
    eq(V.getInfo(clone2).locked, false, 'the new clone is unlocked')
    eq(V.getInfo(clone2).keys['friend-1'], nil, 'without the taken key')
    sets = S.count('set')
    S.demoteNow(nodeId, { colorPrimary = 44, plate = 'HACKED', bodyHealth = 650.0, tankHealth = -1000.0 })
    rec = V.getRecord(vehId)
    eq(rec.props.colorPrimary, 33, 'RV4 F1: a read-back at the demotion never changes the colour')
    eq(rec.props.plate, 'PROMO1', '... nor the plate')
    eq(rec.props.bodyHealth, 650.0, "the owner's wear is taken")
    eq(rec.props.tankHealth, 0, '... clamped (a restored car never burns)')
    eq(S.count('set'), sets, 'the node already has them')
    -- props a key holder saved while promoted keep their cosmetics; the demotion's read-back adds its wear
    local clone3 = S.promoteNow(nodeId)
    V.saveProps(clone3, { colorPrimary = 55, bodyHealth = 1000.0 })
    S.demoteNow(nodeId, { colorPrimary = 66, dirtLevel = 9.0, bodyHealth = 400.0 })
    rec = V.getRecord(vehId)
    eq(rec.props.colorPrimary, 55, 'the saved colour wins over the read-back')
    eq(rec.props.dirtLevel, 9.0, 'the read-back dirt is taken')
    eq(rec.props.bodyHealth, 400.0, 'the read-back damage is newer than the saved one')
    eq(S.nodes[nodeId].fields.props.colorPrimary, 55, 'the node follows the saved colour')
    eq(S.nodes[nodeId].fields.props.plate, 'PROMO1', 'with its plate')
    -- park(clone): a forced demotion, refused while somebody sits in it
    local c6, ce6 = S.promoteNow(nodeId)
    stubs.vehicleSeats[ce6] = { [0] = 4711 }
    eq(errOf(V.park(c6)), 'occupied', 'park(clone) refuses an occupied clone')
    stubs.vehicleSeats[ce6] = nil
    eq(V.park(c6), nodeId, 'park(clone) -> the node id')
    eq(S.last('demote').id, nodeId, 'through Scene.demote')
    eq(S.last('demote').caller, 'core', 'as core')
    S.demoteNow(nodeId)
    -- an earlier clone that never demoted is replaced by the new one
    local c4 = S.promoteNow(nodeId)
    S.clones[nodeId] = nil
    local c5 = S.promoteNow(nodeId)
    eq(V.getInfo(c4), nil, 'the earlier clone is untracked')
    eq(V.getInfo(c5).parked, nodeId, 'the new one is adopted')
    eq(hooks.deleted[#hooks.deleted], c4, 'vehicleDeleted for the earlier one')
    eq(#stubs.failures, 0, 'section 2/3: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 4. spawnRecord / restoreRecord on parked records
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer()
    local V = Core.Vehicles
    player(env, 1)
    local netId, _, vehId = persisted(Core, v3(500.0, 500.0, 20.0))
    local nodeId = V.park(netId)
    local exit = v3(1.0, 2.0, 3.0)
    eq(errOf(V.restoreRecord(vehId)), 'parked', 'restoreRecord refuses a parked record (no duplicate at boot)')
    eq(errOf(V.spawnRecord(vehId, 'nope')), 'bad_coords', 'spawnRecord still validates the coords')
    local creates = 0
    for _, rec in pairs(stubs.entities) do if rec.type == 2 then creates = creates + 1 end end
    local done = async(env, V.spawnRecord, vehId, exit, 0.0, 1)
    eq(S.last('promote') and S.last('promote').id, nodeId, 'spawnRecord promotes the node')
    eq(S.last('promote').caller, 'core', 'as core')
    eq(done(), nil, 'and waits for the clone')
    stubs.tick(200)
    eq(done(), nil, 'still waiting')
    local clone = S.promoteNow(nodeId)
    stubs.tick(100)
    eq(done() and done()[1], clone, "-> the clone's netId")
    local after = 0
    for _, rec in pairs(stubs.entities) do if rec.type == 2 then after = after + 1 end end
    eq(after, creates + 1, 'no second car: only the clone was made')
    eq(V.spawnRecord(vehId, exit), clone, 'a promoted parked car answers its clone at once')
    eq(errOf(V.restoreRecord(vehId)), 'parked', 'restoreRecord refuses the promoted one too')
    S.demoteNow(nodeId)
    -- a refused promotion, a clone that never comes
    S.promoteAnswer = { nil, 'limit' }
    eq(errOf(V.spawnRecord(vehId, exit)), 'limit', "Scene.promote's refusal is passed on")
    S.promoteAnswer = { true }
    done = async(env, V.spawnRecord, vehId, exit)
    stubs.tick(10900)
    eq(done(), nil, 'waiting up to SpawnTimeoutMs + 6 s')
    stubs.tick(200)
    eq(done() and done()[2], 'spawn_timeout', '-> spawn_timeout')
    -- the node vanished: re-parked from the record first, then promoted
    S.nodes[nodeId] = nil
    local spawns = S.count('spawn')
    done = async(env, V.spawnRecord, vehId, exit)
    eq(S.count('spawn'), spawns + 1, 'a vanished node is re-parked from the record')
    local fresh = V.getRecord(vehId).parked
    check(fresh ~= nodeId and S.nodes[fresh] ~= nil, 'as a new node the record names')
    eq(S.last('promote').id, fresh, 'which is promoted')
    local clone2 = S.promoteNow(fresh)
    stubs.tick(100)
    eq(done() and done()[1], clone2, "-> its clone's netId")
    -- a garaged record still spawns at the exit (the §4.6 path)
    eq(V.store(clone2), true, 'garaged')
    local live = V.spawnRecord(vehId, exit, 10.0, 1)
    check(math.type(live) == 'integer' and V.getInfo(live).parked == nil, 'a stored record spawns a normal car')
    eq(stubs.coords[V.getEntity(live)].x, 1.0, 'at the exit')
    eq(V.getRecord(vehId).parked, false, 'not parked any more')
    eq(errOf(V.spawnRecord(vehId, exit)), 'already_spawned', 'the live one refuses a second spawn')
    eq(#stubs.failures, 0, 'section 4: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 5. store / delete / deleteRecord / a removal by someone else; 6. getInfoByRecord
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer()
    local V = Core.Vehicles
    player(env, 1)
    local charId = Core.Player.getInfo(1).charId
    -- store(clone): the node goes, the record is garaged
    local n1, _, vehId1 = persisted(Core, v3(500.0, 500.0, 20.0))
    local node1 = V.park(n1)
    local c1, ce1 = S.promoteNow(node1)
    stubs.coords[ce1] = v3(501.0, 502.0, 20.0)
    local deleted, printedBefore = #hooks.deleted, #stubs.printed
    eq(V.store(c1), true, "store(clone)")
    eq(S.nodes[node1], nil, 'its node is removed')
    eq(S.last('remove').caller, 'core', 'as core')
    local rec = V.getRecord(vehId1)
    eq(rec.stored, true, 'garaged')
    eq(rec.parked, false, 'not parked')
    eq(rec.position.x, 501.0, "at the clone's last position")
    eq(stubs.entities[ce1].exists, false, 'the clone is deleted at once')
    eq(V.getInfo(c1), nil, 'untracked')
    eq(#hooks.deleted, deleted + 1, 'one vehicleDeleted')
    local warned = false
    for i = printedBefore + 1, #stubs.printed do
        if stubs.printed[i]:find('was removed', 1, true) then warned = true end
    end
    eq(warned, false, 'our own removal is not reported as a foreign one')
    -- store(vehId): parked (not promoted), live, unknown
    local n2, _, vehId2 = persisted(Core, v3(520.0, 500.0, 20.0))
    local node2 = V.park(n2)
    S.nodes[node2].pos.x = 525.0                               -- the node moved since (a map editor, a nudge)
    eq(V.store(vehId2), true, 'store(vehId) of a parked record')
    eq(S.nodes[node2], nil, 'the node is removed')
    eq(V.getRecord(vehId2).stored, true, 'garaged')
    eq(V.getRecord(vehId2).position.x, 525.0, "at the node's pose")
    eq(V.store(vehId2), true, 'store(vehId) of a garaged record: nothing in the world, still true')
    local n3, _, vehId3 = persisted(Core, v3(540.0, 500.0, 20.0))
    eq(V.store(vehId3), true, 'store(vehId) of a live vehicle')
    eq(V.exists(n3), false, 'it left the world')
    eq(V.store('no-such-record'), false, 'an unknown record')
    eq(V.store('bad id!'), false, 'a malformed id')
    -- delete(clone): the node goes along, the record is out at the clone's pose
    local n4, _, vehId4 = persisted(Core, v3(560.0, 500.0, 20.0))
    local node4 = V.park(n4)
    local c4, ce4 = S.promoteNow(node4)
    stubs.coords[ce4] = v3(565.0, 500.0, 20.0)
    eq(V.delete(c4), true, 'delete(clone)')
    eq(S.nodes[node4], nil, 'the node went along')
    eq(V.getRecord(vehId4).parked, false, 'the record is not parked')
    eq(V.getRecord(vehId4).stored, false, 'but out (a domain plugin may restore it)')
    eq(V.getRecord(vehId4).position.x, 565.0, "at the clone's pose")
    eq(hooks.deleted[#hooks.deleted], c4, 'vehicleDeleted')
    eq(V.restoreRecord(vehId4) ~= nil, true, 'restoreRecord accepts it again')
    -- deleteRecord: a parked record's node goes; a promoted one's clone is untracked
    local n5, _, vehId5 = persisted(Core, v3(580.0, 500.0, 20.0))
    local node5 = V.park(n5)
    eq(V.deleteRecord(vehId5), true, 'deleteRecord of a parked record')
    eq(S.nodes[node5], nil, 'its node is removed')
    local n6, _, vehId6 = persisted(Core, v3(600.0, 500.0, 20.0))
    local node6 = V.park(n6)
    local c6 = S.promoteNow(node6)
    eq(V.deleteRecord(vehId6), true, 'deleteRecord of a promoted parked record')
    eq(S.nodes[node6], nil, 'its node is removed')
    eq(V.getInfo(c6), nil, 'the clone is untracked')
    eq(hooks.deleted[#hooks.deleted], c6, 'vehicleDeleted')
    eq(V.deleteRecord('nope'), false, 'an unknown record')
    -- someone else removes a node (core code elsewhere): the record is out again
    local n7, _, vehId7 = persisted(Core, v3(620.0, 500.0, 20.0))
    local node7 = V.park(n7)
    local c7 = S.promoteNow(node7)
    printedBefore = #stubs.printed
    S.remove(node7)
    eq(V.getRecord(vehId7).parked, false, 'a foreign removal un-parks the record')
    eq(V.getRecord(vehId7).stored, false, 'it stays out')
    eq(V.getInfo(c7), nil, 'the clone is untracked')
    warned = false
    for i = printedBefore + 1, #stubs.printed do
        if stubs.printed[i]:find('was removed', 1, true) then warned = true end
    end
    eq(warned, true, 'and it is logged')

    -- 6. getInfoByRecord: live, parked, garaged, unknown
    local n8, _, vehId8 = persisted(Core, v3(640.0, 500.0, 20.0), { locked = true })
    local i8 = V.getInfoByRecord(vehId8)
    eq(i8.netId, n8, 'live: the netId')
    eq(i8.stored, false, 'live: not stored')
    eq(i8.position.x, 640.0, "live: the entity's position")
    eq(i8.parked, nil, 'live: not parked')
    V.giveKeys(n8, 'friend-3')
    local node8 = V.park(n8)
    i8 = V.getInfoByRecord(vehId8)
    eq(i8.netId, nil, 'parked: no netId')
    eq(i8.parked, node8, 'parked: the node')
    eq(i8.locked, true, 'parked: the lock')
    eq(i8.keys['friend-3'], true, 'parked: the kept keys')
    eq(i8.keys[charId], true, "parked: the owner's key")
    eq(i8.ownerCharId, charId, 'parked: the owner')
    eq(i8.plate, V.getRecord(vehId8).plate, 'parked: the plate')
    eq(i8.position.x, 640.0, "parked: the node's pose")
    V.store(vehId8)
    i8 = V.getInfoByRecord(vehId8)
    eq(i8.stored, true, 'garaged: stored')
    eq(i8.parked, nil, 'garaged: not parked')
    eq(i8.netId, nil, 'garaged: no netId')
    eq(V.getInfoByRecord('no-such'), nil, 'an unknown record')
    eq(V.getInfoByRecord(42), nil, 'a malformed id')
    eq(#stubs.failures, 0, 'section 5/6: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 7. AutoPark: at rest for AutoParkIdleMs, nobody within AutoParkRadius, nobody inside; sliced; clones untouched
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer({ config = function(Config)
        Config.Vehicles.AutoPark, Config.Vehicles.AutoParkIdleMs = nil, 30000      -- nil = on (the default)
        Config.Vehicles.AutoParkRadius, Config.Vehicles.AutoParkSweepMs = 50, 10000
    end })
    local V = Core.Vehicles
    local ped = player(env, 1, v3(0.0, 0.0, 0.0))
    local a, _, vehA = persisted(Core, v3(500.0, 500.0, 20.0))          -- far, at rest
    local b, _, vehB = persisted(Core, v3(30.0, 0.0, 0.0))              -- 30 m from the player
    local c, ec, vehC = persisted(Core, v3(600.0, 600.0, 20.0))         -- somebody inside
    stubs.vehicleSeats[ec] = { [-1] = 4242 }
    local d, ed, vehD = persisted(Core, v3(700.0, 700.0, 20.0))         -- moving
    W.vel[ed] = { 5.0, 0.0, 0.0 }
    local loose = V.spawn({ model = 'adder', coords = v3(800.0, 800.0, 20.0) })    -- no record
    local f, ef, vehF = persisted(Core, v3(900.0, 900.0, 20.0), nil)   -- in another bucket, player-free
    stubs.entities[ef].bucket = 9
    stubs.tick(25000)
    eq(V.getRecord(vehA).parked, false, 'not before AutoParkIdleMs')
    stubs.tick(20000)
    check(V.getRecord(vehA).parked ~= false, 'a vehicle at rest, far from everyone, is parked')
    eq(V.exists(a), false, 'its entity is gone')
    eq(S.last('spawn') ~= nil and S.last('spawn').caller, 'core', 'as core')
    eq(V.getRecord(vehB).parked, false, 'a player within the radius keeps it live')
    eq(V.getRecord(vehC).parked, false, 'an occupied vehicle stays live')
    eq(V.getRecord(vehD).parked, false, 'a moving vehicle stays live')
    eq(V.getInfo(loose) ~= nil, true, 'a vehicle without a record is never parked')
    check(V.getRecord(vehF).parked ~= false, 'a vehicle in another bucket is parked (the player is in bucket 0)')
    -- the moving one stops: a whole idle period later it is parked
    W.vel[ed] = nil
    stubs.tick(25000)
    eq(V.getRecord(vehD).parked, false, 'a fresh rest stamp once it stopped')
    stubs.tick(20000)
    check(V.getRecord(vehD).parked ~= false, 'then parked')
    -- the player walks away from B; C is vacated
    stubs.coords[ped] = v3(-1000.0, -1000.0, 0.0)
    stubs.vehicleSeats[ec] = nil
    stubs.tick(45000)
    check(V.getRecord(vehB).parked ~= false, 'B once the player left')
    check(V.getRecord(vehC).parked ~= false, 'C once vacated')
    -- a vehicle pushed a little (> 1 m) between two sweeps is not at rest
    local _, eg, vehG = persisted(Core, v3(1000.0, 1000.0, 20.0))
    stubs.tick(20000)
    stubs.coords[eg] = v3(1003.0, 1000.0, 20.0)
    stubs.tick(20000)
    eq(V.getRecord(vehG).parked, false, 'a moved vehicle starts its rest again')
    stubs.tick(35000)
    check(V.getRecord(vehG).parked ~= false, 'and is parked a period later')
    -- clones are the scene's business: a promoted parked car is never auto-parked
    local node = V.getRecord(vehA).parked
    local clone = S.promoteNow(node)
    local demotes = S.count('demote')
    stubs.tick(60000)
    eq(S.count('demote'), demotes, 'a clone is not demoted by AutoPark')
    eq(V.getInfo(clone) ~= nil, true, 'and stays tracked')
    -- the owner client is asked for the props (a yield inside the worker)
    local _, eh, vehH = persisted(Core, v3(1100.0, 1100.0, 20.0))
    W.owner[eh] = 1
    local asked = propsRequests()
    for _ = 1, 100 do                                       -- until the worker asks (then its 1 s timeout runs)
        if propsRequests() > asked then break end
        stubs.tick(500)
    end
    eq(propsRequests(), asked + 1, 'the worker asks the owner client')
    eq(V.getRecord(vehH).parked, false, 'and waits for the answer')
    answerProps(env, 1, { colorPrimary = 21, fuelLevel = 42.0 })
    check(V.getRecord(vehH).parked ~= false, 'and parks after the answer')
    eq(V.getRecord(vehH).props.fuelLevel, 42.0, "with the owner's wear")
    eq(V.getRecord(vehH).props.colorPrimary, nil, 'never its colour (RV4 F1)')
    -- a refused park waits a whole idle period before it is tried again (logged once)
    local _, _, vehK = persisted(Core, v3(1200.0, 1200.0, 20.0))
    S.spawnAnswer = { nil, 'fields', { vehId = 'unknown' } }
    local spawns = S.count('spawn')
    stubs.tick(45000)
    eq(S.count('spawn'), spawns + 1, 'one attempt')
    stubs.tick(10000)
    eq(S.count('spawn'), spawns + 1, 'no retry within the idle period')
    S.spawnAnswer = nil
    stubs.tick(35000)
    check(V.getRecord(vehK).parked ~= false, 'parked once the scene accepts it')
    -- AutoPark off: nothing is parked
    Core.Config.Vehicles.AutoPark = false
    local m, _, vehM = persisted(Core, v3(1300.0, 1300.0, 20.0))
    stubs.tick(90000)
    eq(V.getRecord(vehM).parked, false, 'AutoPark = false parks nothing')
    eq(V.exists(m), true, 'the vehicle stays')
    eq(#stubs.failures, 0, 'section 7: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 7a. the worker re-checks a queued vehicle: somebody walked up while it waited behind another park
--------------------------------------------------------------------------------
do
    local env, Core = newServer({ config = function(Config)
        Config.Vehicles.AutoPark, Config.Vehicles.AutoParkIdleMs = true, 30000
        Config.Vehicles.AutoParkRadius, Config.Vehicles.AutoParkSweepMs = 50, 5000     -- a slice every 500 ms
    end })
    local V = Core.Vehicles
    local ped = player(env, 1, v3(0.0, 0.0, 0.0))
    local x1, e1, veh1 = persisted(Core, v3(500.0, 500.0, 20.0))
    local x2, e2, veh2 = persisted(Core, v3(800.0, 800.0, 20.0))
    W.owner[e1], W.owner[e2] = 1, 1                           -- each park waits (up to 1 s) for the owner's props
    local asked = propsRequests()
    for _ = 1, 600 do
        if propsRequests() > asked then break end
        stubs.tick(100)
    end
    local first
    for i = #stubs.sent, 1, -1 do
        if stubs.sent[i].name == 'core:cb:req:core:vehicles:props' then first = stubs.sent[i].args[2] break end
    end
    check(first == x1 or first == x2, 'the worker parks one of them and waits')
    local otherPos, otherVeh = first == x1 and v3(800.0, 800.0, 20.0) or v3(500.0, 500.0, 20.0),
        first == x1 and veh2 or veh1
    stubs.tick(500)                                           -- the next slice queued the other one
    stubs.coords[ped] = otherPos                              -- and now somebody walks up to it
    stubs.tick(2500)                                          -- the first park ends (timeout), the worker goes on
    check(V.getRecord(first == x1 and veh1 or veh2).parked ~= false, 'the first one is parked')
    eq(V.getRecord(otherVeh).parked, false, 'the queued one is skipped: somebody is near it now')
    eq(propsRequests(), asked + 1, 'its park never started')
    eq(#stubs.failures, 0, 'section 7a: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 7b. the sweep is sliced: 25 vehicles, 3 per slice, each looked at once per sweep
--------------------------------------------------------------------------------
do
    local reads = {}
    local env = newServer({ config = function(Config)
        Config.Vehicles.AutoPark, Config.Vehicles.AutoParkIdleMs = true, 30000
        Config.Vehicles.AutoParkRadius, Config.Vehicles.AutoParkSweepMs = 50, 10000
    end, before = function(env, Core)                        -- 25 records before the boot starts the sweep
        local get = env.GetEntityVelocity
        env.GetEntityVelocity = function(e)
            reads[e] = (reads[e] or 0) + 1
            return get(e)
        end
        for i = 1, 25 do
            Core.Vehicles.persist(Core.Vehicles.spawn({ model = 'adder', coords = v3(500.0 + i * 10, 500.0, 20.0) }))
        end
    end })
    local total = function()
        local n = 0
        for _, v in pairs(reads) do n = n + v end
        return n
    end
    eq(total(), 3, 'the first slice looks at ceil(25 / 10) vehicles')
    stubs.tick(1000)
    eq(total(), 6, 'the next one a second later')
    stubs.tick(7500)
    eq(total(), 25, 'one sweep looks at each vehicle once')
    local each = true
    for _, v in pairs(reads) do if v ~= 1 then each = false end end
    eq(each, true, 'exactly once')
    eq(#stubs.failures, 0, 'section 7b: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 8. boot: parked records against the loaded scene nodes (waits for the scene store)
--------------------------------------------------------------------------------
do
    local POS = { x = 50.0, y = 60.0, z = 7.0, heading = 180.0, bucket = 4 }
    local env, Core, S = newServer({ config = function(Config) Config.Vehicles.AutoPark = false end,
        before = function(_, _, S2)
            local function rec(id, t)
                t.position = t.position or POS
                putRecord(id, t)
            end
            local function node(id, owner, fields)
                S2.nodes[id] = { id = id, kind = 'vehicle', owner = owner, bucket = 0, pos = { x = 1.0, y = 2.0,
                    z = 3.0 }, rot = { x = 0.0, y = 0.0, z = 0.0 }, fields = fields, persist = true,
                    authority = { mode = 'local' } }
            end
            rec('keepme', { stored = false, parked = 1 })
            node(1, 'core', { model = 'adder', vehId = 'keepme' })
            rec('vanished', { stored = false, parked = 2, modelName = 'sultan', props = { colorPrimary = 8 },
                locked = true, meta = { vehType = 'automobile' } })
            rec('garaged', { stored = true, parked = 3 })
            node(3, 'core', { model = 'adder', vehId = 'garaged' })
            rec('adoptme', { stored = false })
            node(4, 'core', { model = 'adder', vehId = 'adoptme' })
            node(5, 'core', { model = 'adder', vehId = 'ghost' })
            node(6, 'core', { model = 'blista', mapEl = 'm:1' })
            node(7, 'garage', { model = 'adder', vehId = 'keepme' })
            node(8, 'core', { model = 'adder', vehId = 'keepme' })
            S2.nextId, S2.loaded = 100, false                  -- the scene store has not loaded yet
        end })
    eq(S.count('spawn') + S.count('remove'), 0, 'nothing is checked while the scene store is not loaded')
    local early = S.promoteNow(1)                                   -- a player gets in before the boot check ran
    S.loaded = true
    stubs.tick(5000)
    local V = Core.Vehicles
    eq(V.getRecord('keepme').parked, 1, 'a record with its node keeps it')
    check(S.nodes[1] ~= nil, 'and the node stays')
    eq(V.getInfo(early) and V.getInfo(early).parked, 1, '... even promoted meanwhile (its clone stays adopted)')
    local fresh = V.getRecord('vanished').parked
    eq(fresh, 100, 'a record whose node vanished is re-parked')
    local sp = S.last('spawn')
    eq(sp.def.pos.x, 50.0, 'at the record position')
    eq(sp.def.bucket, 4, 'in the record bucket')
    eq(sp.def.rot.z, 180.0, 'with the record heading')
    eq(sp.def.fields.model, 'sultan', 'by the record model name')
    eq(sp.def.fields.locked, true, 'locked like the record')
    eq(sp.def.fields.props.colorPrimary, 8, 'with the record props')
    eq(sp.caller, 'core', 'as core')
    eq(V.getRecord('garaged').parked, false, 'a garaged record drops its mark')
    eq(S.nodes[3], nil, 'and its node goes')
    eq(V.getRecord('adoptme').parked, 4, 'an out record adopts the node that names it')
    eq(S.nodes[5], nil, 'a node without a record goes')
    check(S.nodes[6] ~= nil, 'a maps vehicle node stays')
    check(S.nodes[7] ~= nil, "a plugin's node stays")
    eq(S.nodes[8], nil, 'a second node of a parked record goes')
    eq(S.count('spawn'), 1, 'one re-park, no spawn storm')
    eq(#stubs.failures, 0, 'section 8: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 9. core stops: a clone hands its final pose to its node; 10. a clone the world lost
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer()
    local V = Core.Vehicles
    player(env, 1)
    local n1, _, vehId1 = persisted(Core, v3(500.0, 500.0, 20.0), { locked = true })
    local node1 = V.park(n1)
    local c1, ce1 = S.promoteNow(node1)
    V.setLocked(c1, false)
    V.giveKeys(c1, 'friend-9')
    stubs.coords[ce1], W.rot[ce1] = v3(900.0, 910.0, 21.0), { 0.0, 0.0, 45.0 }   -- driven away, left there
    local _, e2, vehId2 = persisted(Core, v3(520.0, 500.0, 20.0))                -- a normal live one
    -- 10. the world loses a clone (another script deleted it): vehicleDeleted, then the scene demotes it
    local n3, _, vehId3 = persisted(Core, v3(540.0, 500.0, 20.0))
    local node3 = V.park(n3)
    local c3, ce3 = S.promoteNow(node3)
    local deleted = #hooks.deleted
    stubs.entities[ce3].exists = false
    stubs.triggerOn(env, 'entityRemoved', 0, ce3)
    eq(V.getInfo(c3), nil, 'a lost clone is untracked')
    eq(#hooks.deleted, deleted + 1, 'with vehicleDeleted')
    S.demoteNow(node3, nil, nil, { reason = 'lost' })
    eq(#hooks.deleted, deleted + 1, 'its demotion fires no second one')
    eq(V.getRecord(vehId3).parked, node3, 'the record stays parked')
    -- server/main.lua's stop loop deletes every tracked vehicle: a parked car's node survives it
    local n4, _, vehId4 = persisted(Core, v3(560.0, 500.0, 20.0))
    local node4 = V.park(n4)
    local c4 = S.promoteNow(node4)
    stubs.resourceStates.core = 'stopping'
    eq(V.delete(c4), true, 'a delete while core stops')
    stubs.resourceStates.core = 'started'
    check(S.nodes[node4] ~= nil, 'keeps the parked node')
    eq(V.getRecord(vehId4).parked, node4, 'and the record parked')

    stubs.triggerOn(env, 'onResourceStop', 0, 'core')
    local mv = S.last('move')
    eq(mv and mv.id, node1, "the clone's node is moved")
    eq(mv.caller, 'core', 'as core')
    eq(mv.pos.x, 900.0, "to the clone's final position")
    eq(mv.rot.z, 45.0, 'and rotation')
    eq(S.nodes[node1].pos.y, 910.0, 'the node keeps the final pose (persistent)')
    local rec = V.getRecord(vehId1)
    eq(rec.parked, node1, 'the record stays parked')
    eq(rec.stored, false, 'out of the garage')
    eq(rec.position.x, 900.0, 'at the final position')
    eq(rec.locked, false, 'with the lock state of the clone')
    local friend = false
    for _, k in ipairs(rec.keys or {}) do if k == 'friend-9' then friend = true end end
    eq(friend, true, 'and its keys')
    eq(S.nodes[node1].fields.locked, false, 'the node follows the lock')
    eq(stubs.entities[ce1].exists, false, 'the clone is deleted')
    eq(V.getInfo(c1), nil, 'and untracked')
    eq(S.nodes[node1] ~= nil, true, 'the node is not removed at stop')
    local rec2 = V.getRecord(vehId2)
    local stopNode = rec2.parked and S.nodes[rec2.parked]
    check(stopNode ~= nil, 'RV4 F14 / RV6 F2: a normal live vehicle is PARKED at stop (no limbo, no boot spawn)')
    eq(rec2.stored, false, 'it stays out of the garage')
    eq(stopNode and stopNode.pos.x, 520.0, "its node stands at the car's final pose")
    eq(stopNode and stopNode.persist, true, 'a persistent node')
    eq(stopNode and stopNode.authority and stopNode.authority.mode, 'local', 'with the parked policy')
    eq(stubs.entities[e2].exists, false, 'its entity is deleted')
    eq(#stubs.failures, 0, 'section 9/10: no uncaught error')
    stubs.tick(2000)
end

--------------------------------------------------------------------------------
-- 11. the client round trip: client/vehicles.lua answers core:vehicles:props for a vehicle it controls
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer({ client = true })
    local V = Core.Vehicles
    player(env, 1)
    local n1, e1, vehId1 = persisted(Core, v3(500.0, 500.0, 20.0), { plate = 'CLNT1' })
    W.owner[e1] = stubs.clientSrc
    local done = async(env, V.park, n1)
    local res = done()
    check(res and math.type(res[1]) == 'integer', 'parked in one go (the client answered at once)')
    local f = S.last('spawn').def.fields
    eq(f.props.colorPrimary, nil, "RV4 F1: the client's colour is not taken (a read-back changes only wear)")
    eq(f.props.bodyHealth, 640.5, 'its damage values are')
    eq(f.props.plate, 'CLNT1', "the record's plate, not the client's")
    eq(f.props.mods, nil, "nor the client's mods")
    eq(V.getRecord(vehId1).parked, res[1], 'the record is parked')
    -- the client does not control it (ownership moved on): a nil answer at once, the cached props
    local n2, e2 = persisted(Core, v3(520.0, 500.0, 20.0), { props = { colorPrimary = 2 } })
    W.owner[e2], W.noControl = stubs.clientSrc, true
    local done2 = async(env, V.park, n2)
    check(done2() and math.type(done2()[1]) == 'integer', 'parked at once (the client answered nil)')
    eq(S.last('spawn').def.fields.props.colorPrimary, 2, 'with the cached props')
    W.noControl = nil
    -- the owner is a player without a client here: the 1 s timeout, the cached props
    local n4, e4 = persisted(Core, v3(560.0, 500.0, 20.0), { props = { colorPrimary = 4 } })
    W.owner[e4] = 77
    local done4 = async(env, V.park, n4)
    stubs.tick(900)
    eq(done4(), nil, 'waiting for src 77')
    stubs.tick(200)
    check(done4() and math.type(done4()[1]) == 'integer', 'parked after the timeout')
    eq(S.last('spawn').def.fields.props.colorPrimary, 4, 'with the cached props')
    -- a vehicle that is no core vehicle (no coreVeh bag) is never answered
    local n3, e3 = persisted(Core, v3(540.0, 500.0, 20.0), { props = { colorPrimary = 6 } })
    W.owner[e3] = stubs.clientSrc
    stubs.entityState(env, e3).coreVeh = nil
    local done3 = async(env, V.park, n3)
    stubs.tick(1100)
    check(done3() and math.type(done3()[1]) == 'integer', 'parked')
    eq(S.last('spawn').def.fields.props.colorPrimary, 6, 'the client refused a non-core vehicle')
    eq(#stubs.failures, 0, 'section 11: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 12. without Core.Scene (offline suites): parking is unavailable, the §4.6 API unchanged
--------------------------------------------------------------------------------
do
    local env, Core = newServer({ noScene = true })
    local V = Core.Vehicles
    player(env, 1)
    local n1, _, vehId1 = persisted(Core, v3(500.0, 500.0, 20.0))
    eq(errOf(V.park(n1)), 'unavailable', 'park: unavailable')
    stubs.tick(90000)
    eq(V.exists(n1), true, 'no AutoPark without the scene')
    eq(V.store(n1), true, 'store works')
    local n2 = V.spawnRecord(vehId1, v3(1.0, 1.0, 1.0))
    check(math.type(n2) == 'integer', 'spawnRecord works')
    eq(V.getInfoByRecord(vehId1).netId, n2, 'getInfoByRecord works')
    eq(V.delete(n2), true, 'delete works')
    eq(V.restoreRecord(vehId1) ~= nil, true, 'restoreRecord works')
    eq(#stubs.failures, 0, 'section 12: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 13. the lock key on a parked car's LOCAL copy: client/vehicles.lua sends the node id, the server checks and toggles
--------------------------------------------------------------------------------
do
    local env, Core, S, client = newServer({ client = true })
    local V = Core.Vehicles
    local ped1 = player(env, 1, v3(500.0, 505.0, 20.0))
    player(env, 2, v3(502.0, 500.0, 20.0))
    local netId, _, vehId = persisted(Core, v3(500.0, 500.0, 20.0))               -- src 1's car (virtual key)
    local nodeId = V.park(netId)
    local texts = Core.Config.Texts
    local function lastNotify(src)
        for i = #stubs.sent, 1, -1 do
            local s = stubs.sent[i]
            if s.name == 'core:client:notify' and s.target == src then return s.args[1].message end
        end
        return nil
    end
    local function sentParked()
        local out = {}
        for i = 1, #stubs.sent do
            if stubs.sent[i].name == 'core:server:parkedLock' then out[#out + 1] = stubs.sent[i].args[1] end
        end
        return out
    end
    -- the client: a local copy (no state bags) resolved through Core.Scene.idOf / get (read-only)
    local copy = stubs.newEntity(2, { model = env.GetHashKey('adder') })
    stubs.coords[copy] = v3(500.0, 500.0, 20.0)
    local nodes = { [copy] = nodeId }
    rawset(client.Core, 'Scene', {
        idOf = function(e) return nodes[e] end,
        get = function(id)
            local n = S.nodes[id]
            return n and { id = id, kind = n.kind, fields = deep(n.fields) } or nil
        end,
    })
    local calls = #stubs.sent
    client.Core.Vehicles.toggleLock(copy)
    local sent = sentParked()
    eq(sent[#sent], nodeId, 'U on a parked copy sends core:server:parkedLock(node id)')
    eq(V.getRecord(vehId).locked, true, 'the owner locked it: the record')
    eq(S.nodes[nodeId].fields.locked, true, 'and the node field (the local copies follow)')
    eq(S.last('set').caller, 'core', 'set as core')
    eq(lastNotify(1), texts.locked, 'the owner hears "locked"')
    check(#stubs.sent > calls, 'the round trip went through the network stubs')
    client.Core.Vehicles.toggleLock(copy)
    eq(V.getRecord(vehId).locked, true, 'a second press within 500 ms: dropped (cooldown)')
    stubs.tick(600)
    client.Core.Vehicles.toggleLock(copy)
    eq(V.getRecord(vehId).locked, false, 'then unlocked')
    eq(S.nodes[nodeId].fields.locked, false, 'the node field too')
    eq(lastNotify(1), texts.unlocked, '"unlocked"')
    -- the client sends nothing for what is no parked core vehicle
    local maps = S.spawn({ kind = 'vehicle', pos = { x = 500.0, y = 498.0, z = 20.0 }, rot = { x = 0, y = 0, z = 0 },
        fields = { model = 'blista', mapEl = 'm:1' } })
    local copy2 = stubs.newEntity(2, {})
    nodes[copy2] = maps
    local before = #sentParked()
    client.Core.Vehicles.toggleLock(copy2)
    eq(#sentParked(), before, 'a maps vehicle copy: nothing sent')
    local plain = stubs.newEntity(2, {})
    client.Core.Vehicles.toggleLock(plain)
    eq(#sentParked(), before, 'a vehicle that is no node: nothing sent')
    -- the server: keys, distance, bucket, item keys, what the id names
    local function press(src, id)
        stubs.tick(600)
        stubs.triggerOn(env, 'core:server:parkedLock', src, id)
    end
    press(2, nodeId)
    eq(V.getRecord(vehId).locked, false, 'a player without keys: nothing toggles')
    eq(lastNotify(2), texts.no_keys, 'and hears "no keys"')
    stubs.coords[ped1] = v3(600.0, 600.0, 20.0)
    press(1, nodeId)
    eq(V.getRecord(vehId).locked, false, 'beyond LockDistance (from the server ped coords): refused')
    stubs.coords[ped1] = v3(500.0, 505.0, 20.0)
    stubs.buckets[1] = 5
    press(1, nodeId)
    eq(V.getRecord(vehId).locked, false, 'another bucket: refused')
    stubs.buckets[1] = 0
    press(1, maps)
    eq(S.nodes[maps].fields.locked, nil, 'a maps vehicle node: nothing')
    press(1, 424242)
    press(1, 'nope')
    eq(#stubs.failures, 0, 'an unknown id and a bad payload are dropped quietly')
    local itemNet, _, itemVeh = persisted(Core, v3(503.0, 500.0, 20.0), { keyMode = 'item' })
    local itemNode = V.park(itemNet)
    local notices = 0
    for i = 1, #stubs.sent do if stubs.sent[i].name == 'core:client:notify' then notices = notices + 1 end end
    press(1, itemNode)
    local after = 0
    for i = 1, #stubs.sent do if stubs.sent[i].name == 'core:client:notify' then after = after + 1 end end
    eq(V.getRecord(itemVeh).locked, false, 'an item-key car: not toggled (its domain plugin decides)')
    eq(after, notices, 'and silent (no "no keys")')
    -- promoted meanwhile: the clone's own lock rules
    local clone = S.promoteNow(nodeId)
    press(1, nodeId)
    eq(V.isLocked(clone), true, 'a node promoted meanwhile: the clone is locked')
    eq(lastNotify(1), texts.locked, 'with the same notification')
    eq(#stubs.failures, 0, 'section 13: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 14. core stop on the REAL scene stack (tests/scene_server_harness.lua + server/scene_promote.lua), in BOTH
-- onResourceStop handler orders: a promoted parked car's clone hands its final pose to its persistent node
--------------------------------------------------------------------------------
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local hs = RH.stubs                               -- (= stubs: RH was loaded at the top)
local RS = { wear = {}, vel = {}, owner = {} }   -- the real stack's world knobs: per-entity wear / velocity / owner

--- A core server VM on the REAL scene stack (tests/scene_server_harness.lua: store + API real, index / interest /
--- flush recording fakes) + the real promote engine (server/scene_promote.lua + scene_promote_api.lua) + the three
--- vehicles files; `promoteFirst` loads the engine first (the other stop-handler order). The server forms the
--- harness lacks (fxref: GetVehicle*Health, GetVehicleDirtLevel, IsVehicleTyreBurst, GetEntityVelocity, …) answer
--- from RS.wear[e] = { engine, body, tank, dirt, hp } (hp = GetEntityHealth; default 1000 = synced, alive).
local function realStack(promoteFirst, opts)
    opts = opts or {}
    RS.wear, RS.vel, RS.owner = {}, {}, {}
    local env, Core = RH.newServer({ config = opts.config })
    for _, id in ipairs({ 'char-1', 'char-3', 'char-9' }) do ensureChar(id) end   -- (the vehicles owner FK)
    local function w(e) return RS.wear[e] or {} end
    env.GetEntityVelocity = function(e) local v = RS.vel[e] return hs.vector3(v and v[1] or 0.0, 0.0, 0.0) end
    env.NetworkGetEntityOwner = function(e) return RS.owner[e] or -1 end
    env.GetEntityRoutingBucket = function(e) return hs.entities[e] and hs.entities[e].bucket or 0 end
    env.GetEntityHealth = function(e) return w(e).hp or 1000 end
    env.GetVehicleEngineHealth = function(e) return w(e).engine or 1000.0 end
    env.GetVehicleBodyHealth = function(e) return w(e).body or 1000.0 end
    env.GetVehiclePetrolTankHealth = function(e) return w(e).tank or 1000.0 end
    env.GetVehicleDirtLevel = function(e) return w(e).dirt or 0.0 end
    env.IsVehicleTyreBurst = function() return false end
    env.SetVehicleColours = function() end
    env.FreezeEntityPosition = function(e, on) if hs.entities[e] then hs.entities[e].frozen = on end end
    Core.PlayerGrid = { candidates = function(_, _, buf)
        local n = 0
        for src in pairs(hs.peds) do n = n + 1 buf[n] = src end
        return n
    end }
    Core.Player.getInfo = function(src)
        return opts.chars and opts.chars[src] and { charId = opts.chars[src] } or nil
    end
    Core.Notify = Core.Notify or { send = function() end }
    local promote = { 'server/scene_promote.lua', 'server/scene_promote_api.lua' }
    local vehicles = { 'server/vehicles.lua', 'server/vehicles_park.lua', 'server/vehicles_fleet.lua' }
    for _, group in ipairs(promoteFirst and { promote, vehicles } or { vehicles, promote }) do
        for _, file in ipairs(group) do
            if hs.readFile(hs.root .. '/' .. file) then hs.loadFile(env, file) end
        end
    end
    hs.tick(0)
    return env, Core
end

do
    local function run(promoteFirst)
        local env, Core = realStack(promoteFirst)
        local V, Scene = Core.Vehicles, Core.Scene
        local netId = V.spawn({ model = 'adder', coords = hs.vector3(100.0, 100.0, 10.0), ownerCharId = 'char-1' })
        local vehId = V.persist(netId)
        local nodeId = V.park(netId)
        Scene.promote(nodeId)
        hs.tick(200)
        local clone = V.getInfoByRecord(vehId).netId
        local e = V.getEntity(clone)
        hs.coords[e] = hs.vector3(300.0, 310.0, 11.0)                        -- driven away and left there
        hs.entities[e].rot = { x = 0.0, y = 0.0, z = 33.0 }
        env.TriggerEvent('onResourceStop', 'core')
        return Scene.get(nodeId), V.getRecord(vehId), RH.doc(nodeId), e, clone
    end
    for _, first in ipairs({ true, false }) do
        local label = first and 'scene_promote.lua stops first' or 'vehicles.lua stops first'
        local node, rec, doc, e, clone = run(first)
        check(math.type(clone) == 'integer', label .. ': the clone was adopted')
        eq(node and node.pos.x, 300.0, label .. ": the node took the clone's final pose")
        eq(node and node.rot.z, 33.0, label .. ': and rotation')
        eq(rec.position.x, 300.0, label .. ': the record too')
        eq(rec.parked, node and node.id, label .. ': still parked')
        eq(doc and doc.pos.x, 300.0, label .. ': persisted (scene_nodes)')
        eq(hs.entities[e].exists, false, label .. ': the clone is gone')
    end
    check(#hs.failures == 0, 'section 14: no uncaught error (' .. tostring(hs.failures[1]) .. ')')
end

--------------------------------------------------------------------------------
-- 15. D-C (review RV4 F5): a WRECKED clone never resurrects intact at its spot; a LOST one stays where it was
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer()
    local V = Core.Vehicles
    player(env, 1)
    local exit = v3(10.0, 10.0, 10.0)
    -- wrecked 2.7 km away: the record keeps its last saved state, is marked destroyed, the node goes
    local n1, _, vehId1 = persisted(Core, v3(100.0, 100.0, 20.0), { props = { modEngine = 3, bodyHealth = 1000.0 } })
    local node1 = V.park(n1)
    local saved = deep(V.getRecord(vehId1))
    local c1 = S.promoteNow(node1)
    local deleted, printedBefore = #hooks.deleted, #stubs.printed
    S.demoteNow(node1, { bodyHealth = 0.0 }, { x = 2000.0, y = 2000.0, z = 20.0 }, { reason = 'destroyed',
        destroyed = true })
    local rec = V.getRecord(vehId1)
    eq(S.nodes[node1], nil, 'RV4 F5: a wrecked clone takes its node along (no local copy back at the spot)')
    eq(S.last('remove').caller, 'core', 'removed as core')
    eq(rec.parked, false, 'the record is not parked')
    eq(rec.destroyed, true, 'it is marked destroyed')
    eq(rec.stored, false, 'not garaged either (the domain decides: insurance, impound)')
    eq(rec.position.x, saved.position.x, 'the record keeps its last saved position (no tow to the wreck)')
    eq(rec.props.bodyHealth, 1000.0, '... and its last saved props')
    eq(V.getInfo(c1), nil, 'the clone is untracked')
    eq(#hooks.deleted, deleted + 1, 'vehicleDeleted fired once')
    eq(V.getInfoByRecord(vehId1).destroyed, true, 'getInfoByRecord tells destroyed')
    eq(errOf(V.restoreRecord(vehId1)), 'destroyed', 'restoreRecord never brings a wreck back')
    eq(errOf(V.park(vehId1)), 'destroyed', 'park(vehId) neither')
    local foreign = false
    for i = printedBefore + 1, #stubs.printed do
        if stubs.printed[i]:find('was removed', 1, true) then foreign = true end
    end
    eq(foreign, false, 'its own removal is not reported as a foreign one')
    -- a garage / insurance plugin brings it back: a normal car at the exit, the mark cleared
    local back = V.spawnRecord(vehId1, exit, 0.0, 1)
    check(math.type(back) == 'integer' and V.getInfo(back).parked == nil, 'spawnRecord brings the wreck back')
    eq(stubs.coords[V.getEntity(back)].x, 10.0, '... at the exit')
    eq(V.getRecord(vehId1).destroyed, false, '... and clears the mark')
    -- lost (deleted by the world, not wrecked): the node stays at the last known pose with the last known wear
    local n2, _, vehId2 = persisted(Core, v3(300.0, 300.0, 20.0), { props = { colorPrimary = 4 } })
    local node2 = V.park(n2)
    S.promoteNow(node2)
    S.demoteNow(node2, { bodyHealth = 420.0, colorPrimary = 99 }, { x = 1500.0, y = 1400.0, z = 21.0 },
        { reason = 'lost' })
    rec = V.getRecord(vehId2)
    check(S.nodes[node2] ~= nil, 'a lost clone keeps its node')
    eq(rec.parked, node2, 'the record stays parked')
    eq(rec.destroyed, false, 'not destroyed')
    eq(rec.position.x, 1500.0, "at the clone's last known pose (not the old spot)")
    eq(rec.props.bodyHealth, 420.0, 'with the last known damage')
    eq(rec.props.colorPrimary, 4, 'and its own colour')
    eq(#stubs.failures, 0, 'section 15: no uncaught error')
    teardown(env)
    -- the boot never re-parks a wreck (the same database, a new core)
    local env2, Core2, S2 = newServer({ keepDb = true, config = function(Config) Config.Vehicles.AutoPark = false end,
        before = function()
            putRecord('wreck1', { model = 1234, plate = 'WRECK1', stored = false, parked = false,
                destroyed = true, position = { x = 5.0, y = 6.0, z = 7.0, heading = 0.0 } })
        end })
    stubs.tick(100)
    eq(Core2.Vehicles.getRecord('wreck1').parked, false, 'the boot check does not re-park a destroyed record')
    for _, l in ipairs(S2.log) do
        if l.op == 'spawn' and l.def.fields.vehId == 'wreck1' then check(false, 'no node for the wreck') end
    end
    eq(#stubs.failures, 0, 'section 15 (boot): no uncaught error')
    teardown(env2)
end

--------------------------------------------------------------------------------
-- 16. RV4 F13: lock and keys by vehId — a parked car without promoting it, a garaged record, a live car
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer()
    local V = Core.Vehicles
    player(env, 1)
    local charId = Core.Player.getInfo(1).charId
    local n1, _, vehId = persisted(Core, v3(100.0, 100.0, 20.0))
    local nodeId = V.park(n1)
    local promotes = S.count('promote')
    eq(V.setLocked(vehId, true), true, 'setLocked(vehId) on a parked car')
    eq(V.getRecord(vehId).locked, true, '... the record')
    eq(S.nodes[nodeId].fields.locked, true, '... and the node field (the local copies follow)')
    eq(S.last('set').caller, 'core', '... as core')
    eq(S.count('promote'), promotes, '... without a promotion')
    eq(V.giveKeys(vehId, 'friend-4'), true, 'giveKeys(vehId)')
    eq(V.removeKeys(vehId, charId), true, 'removeKeys(vehId): even the owner key can be taken')
    local keys = V.getInfoByRecord(vehId).keys
    eq(keys['friend-4'], true, 'the record has the new key')
    ensureChar('char-new')                                            -- (the vehicles owner FK)
    eq(V.setOwner(vehId, 'char-new'), true, 'setOwner(vehId)')
    local rec = V.getRecord(vehId)
    eq(rec.ownerCharId, 'char-new', 'the record owner')
    local listed = {}
    for _, k in ipairs(rec.keys) do listed[k] = true end
    eq(listed['char-new'], true, 'the new owner holds the virtual key')
    eq(listed[charId], nil, 'the old owner not')
    eq(listed['friend-4'], true, 'extra keys stay')
    -- the promotion reads all of it (the record decides, the node carries the lock)
    local clone = S.promoteNow(nodeId)
    local info = V.getInfo(clone)
    eq(info.locked, true, 'the clone is locked')
    eq(info.ownerCharId, 'char-new', 'owned by the new owner')
    eq(info.keys['friend-4'], true, 'with the given key')
    -- while live: the vehId routes to the netId API
    eq(V.setLocked(vehId, false), true, 'setLocked(vehId) of a live car')
    eq(V.isLocked(clone), false, '... acts on the clone')
    eq(V.giveKeys(vehId, 'friend-5'), true, 'giveKeys(vehId) of a live car')
    eq(V.hasKeys(1, clone), false, 'src 1 (the old owner) has no key')
    eq(V.getInfo(clone).keys['friend-5'], true, '... the clone got it')
    S.demoteNow(nodeId)
    eq(V.getRecord(vehId).locked, false, 'the demotion carries the lock into the record')
    -- a garaged record: keys and the lock without any node
    eq(V.store(vehId), true, 'garaged')
    eq(V.setLocked(vehId, true), true, 'setLocked(vehId) of a garaged record')
    eq(V.giveKeys(vehId, 'friend-6'), true, 'giveKeys(vehId) of a garaged record')
    local out = V.spawnRecord(vehId, v3(1.0, 1.0, 1.0), 0.0)
    eq(V.getInfo(out).locked, true, 'the garage spawn is locked like the record')
    eq(V.getInfo(out).keys['friend-6'], true, '... with its keys')
    -- refusals
    eq(V.setLocked('no-such', true), false, 'an unknown vehId')
    eq(V.setLocked(vehId, 'yes'), false, 'a non-boolean lock')
    eq(V.giveKeys('no-such', 'x'), false, 'giveKeys: unknown vehId')
    eq(V.giveKeys(vehId, 'bad id!'), false, 'giveKeys: a malformed charId')
    eq(V.setOwner('bad id!', 'x'), false, 'setOwner: a malformed vehId')
    eq(#stubs.failures, 0, 'section 16: no uncaught error')
    teardown(env)
end

--------------------------------------------------------------------------------
-- 17. RV6 F9: MaxParked — past the cap the longest-unused parked car (not a promoted one) is stored
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer({ config = function(Config)
        Config.Vehicles.MaxParked, Config.Vehicles.AutoPark = 3, false
    end })
    local V = Core.Vehicles
    player(env, 1)
    local stored = {}
    Core.on('vehicleAutoStored', function(vehId, why) stored[#stored + 1] = { vehId = vehId, why = why } end)
    local ids, nodes = {}, {}
    for i = 1, 3 do
        local netId, _, vehId = persisted(Core, v3(100.0 * i, 100.0, 20.0))
        ids[i] = vehId
        nodes[i] = V.park(netId)
        stubs.tick(10)
    end
    eq(#stored, 0, 'three parked cars fit MaxParked 3')
    -- car 1 is used (a promotion), car 2 is the longest unused now
    S.promoteNow(nodes[1])
    S.demoteNow(nodes[1])
    local n4, _, veh4 = persisted(Core, v3(400.0, 100.0, 20.0))
    local node4 = V.park(n4)
    check(math.type(node4) == 'integer', 'a fourth car parks')
    eq(#stored, 1, 'RV6 F9: past MaxParked one car is stored')
    eq(stored[1] and stored[1].vehId, ids[2], 'the longest unused one (car 1 was used since)')
    eq(stored[1] and stored[1].why, 'max_parked', 'hook vehicleAutoStored (vehId, "max_parked")')
    local rec2 = V.getRecord(ids[2])
    eq(rec2.stored, true, 'its record is garaged')
    eq(rec2.parked, false, 'not parked')
    eq(S.nodes[nodes[2]], nil, 'its node is removed')
    check(S.nodes[nodes[1]] and S.nodes[nodes[3]] and S.nodes[node4], 'the others stay')
    -- a promoted car is in use: never stored, even as the longest unused one
    S.promoteNow(nodes[3])
    for _, id in ipairs({ nodes[1], node4 }) do                       -- cars 1 and 4 used after it
        S.promoteNow(id)
        S.demoteNow(id)
    end
    local n5 = persisted(Core, v3(500.0, 100.0, 20.0))
    V.park(n5)
    eq(#stored, 2, 'the fifth car stores one more')
    eq(stored[2] and stored[2].vehId, ids[1], 'car 1: car 3 (the longest unused, but promoted) is skipped')
    check(S.nodes[nodes[3]] ~= nil, 'the promoted car keeps its node')
    eq(#stubs.failures, 0, 'section 17: no uncaught error')
    teardown(env)
    -- the boot rebuilds the order (last_used_at) and stores the excess of a lowered cap
    local env2, Core2 = newServer({ config = function(Config)
        Config.Vehicles.MaxParked, Config.Vehicles.AutoPark = 1, false
    end, before = function(_, _, S2)
        for i, vehId in ipairs({ 'new1', 'old1', 'mid1' }) do
            putRecord(vehId, { model = 1234, plate = 'P' .. i, stored = false, parked = 900 + i,
                position = { x = 1.0 * i, y = 0.0, z = 0.0, heading = 0.0 },
                lastUsedAt = ({ new1 = 3000, old1 = 1000, mid1 = 2000 })[vehId] })   -- the LRU order (last_used_at)
            S2.nodes[900 + i] = { id = 900 + i, kind = 'vehicle', owner = 'core', bucket = 0,
                pos = { x = 1.0 * i, y = 0.0, z = 0.0 }, rot = { x = 0.0, y = 0.0, z = 0.0 }, persist = true,
                fields = { model = 1234, vehId = vehId }, authority = { mode = 'local' } }
        end
    end })
    stubs.tick(100)
    local V2 = Core2.Vehicles
    local parkedNow = 0
    for _, vehId in ipairs({ 'old1', 'mid1', 'new1' }) do
        if V2.getRecord(vehId).stored == false then parkedNow = parkedNow + 1 end
    end
    eq(parkedNow, 1, 'a lowered MaxParked stores the excess at boot')
    eq(V2.getRecord('old1').stored, true, 'the longest unused first (last_used_at order) ...')
    eq(V2.getRecord('mid1').stored, true, '... then the next')
    eq(V2.getRecord('new1').stored, false, 'the most recently used stays parked')
    eq(#stubs.failures, 0, 'section 17 (boot): no uncaught error')
    teardown(env2)
end

--------------------------------------------------------------------------------
-- 18. RV6 F2 / RV4 F14 / D-E / D-B at boot: no out record without a node; 'limit' retried with backoff; old policy
--------------------------------------------------------------------------------
do
    local POS = { x = 70.0, y = 80.0, z = 9.0, heading = 90.0 }
    local env, Core, S = newServer({ config = function(Config) Config.Vehicles.AutoPark = false end,
        before = function(_, _, S2)
            putRecord('limbo1', { model = 1234, plate = 'LIMBO1', stored = false, position = POS,
                props = { colorPrimary = 3 } })                                   -- a stop without the scene / a crash
            putRecord('limbo2', { model = 1234, plate = 'LIMBO2', stored = false, parked = false,
                position = POS })                                                 -- a deleted clone
            putRecord('nopos', { model = 1234, plate = 'NOPOS', stored = false })
            putRecord('garage1', { model = 1234, plate = 'GARAGE1', stored = true, position = POS })
            putRecord('oldpol', { model = 1234, plate = 'OLDPOL', stored = false, parked = 50,
                position = POS })
            S2.nodes[50] = { id = 50, kind = 'vehicle', owner = 'core', bucket = 3, pos = { x = 1.0, y = 2.0, z = 3.0 },
                rot = { x = 0.0, y = 0.0, z = 45.0 }, persist = true, fields = { model = 1234, vehId = 'oldpol',
                plate = 'OLDPOL', props = { colorPrimary = 9 } } }               -- no authority: the class default
            S2.nextId, S2.loaded = 200, false
        end })
    S.loaded = true
    stubs.tick(5000)
    local V = Core.Vehicles
    local r1 = V.getRecord('limbo1')
    eq(type(r1.parked), 'number', 'RV6 F2: an out record with neither node nor car is parked at boot')
    local n1 = S.nodes[r1.parked]
    eq(n1 and n1.pos.x, 70.0, '... at its saved position')
    eq(n1 and n1.fields.props.colorPrimary, 3, '... with its props')
    eq(n1 and n1.authority and n1.authority.mode, 'local', '... and the parked policy')
    eq(type(V.getRecord('limbo2').parked), 'number', 'a deleted clone (parked = false) too')
    eq(V.getRecord('nopos').parked, false, 'a record without a usable position stays out (logged)')
    eq(V.getRecord('garage1').parked, false, 'a garaged record is left alone')
    local old = V.getRecord('oldpol')
    check(old.parked ~= 50 and S.nodes[old.parked] ~= nil, 'D-B: a parked node of the old policy is re-spawned')
    local mig = S.nodes[old.parked]
    eq(mig and mig.authority and mig.authority.mode, 'local', '... with authority local')
    eq(mig and mig.bucket, 3, '... in its bucket')
    eq(mig and mig.rot.z, 45.0, '... at its pose')
    eq(mig and mig.fields.props.colorPrimary, 9, '... with its fields')
    eq(S.nodes[50], nil, '... and the old node goes')
    eq(#stubs.failures, 0, 'section 18: no uncaught error')
    teardown(env)

    -- D-E: the scene refuses the re-park ('limit'): the stale mark goes (spawnRecord works meanwhile), backoff retry
    local env2, Core2, S2 = newServer({ config = function(Config) Config.Vehicles.AutoPark = false end,
        before = function(_, _, S3)
            putRecord('capped', { model = 1234, plate = 'CAPPED', stored = false, parked = 77,
                position = POS })
            S3.spawnAnswer, S3.loaded = { nil, 'limit' }, false
        end })
    S2.loaded = true
    stubs.tick(5000)
    local V2 = Core2.Vehicles
    eq(V2.getRecord('capped').parked, false, "D-E: a re-park refused 'limit' drops the stale mark")
    local tries = S2.count('spawn')
    stubs.tick(10500)
    eq(S2.count('spawn'), tries + 1, 'retried after 10 s')
    stubs.tick(10500)
    eq(S2.count('spawn'), tries + 1, 'backoff: not again after 10 s more ...')
    stubs.tick(10000)
    eq(S2.count('spawn'), tries + 2, '... but after 20 s')
    S2.spawnAnswer = nil
    stubs.tick(40500)
    check(math.type(V2.getRecord('capped').parked) == 'integer', 'parked once the scene has room')
    local after = S2.count('spawn')
    for _ = 1, 12 do stubs.tick(30000) end
    eq(S2.count('spawn'), after, 'the retry ends (no thread left)')
    eq(#stubs.failures, 0, 'section 18 (limit): no uncaught error')
    teardown(env2)

    -- RV6 F2 addendum: deleting a parked car's clone leaves the record out — the garage takes it back at once
    local env3, Core3, S3 = newServer()
    local V3 = Core3.Vehicles
    player(env3, 1)
    local netId, _, vehId = persisted(Core3, v3(100.0, 100.0, 20.0))
    local node = V3.park(netId)
    local clone = S3.promoteNow(node)
    eq(V3.delete(clone), true, 'delete(clone)')
    eq(V3.getRecord(vehId).parked, false, 'the record is out, not parked')
    local back = V3.spawnRecord(vehId, v3(5.0, 5.0, 5.0), 0.0, 1)
    check(math.type(back) == 'integer', "RV6 F2: spawnRecord takes it back (never 'already_spawned' for ever)")
    eq(#stubs.failures, 0, 'section 18 (delete): no uncaught error')
    teardown(env3)
end

--------------------------------------------------------------------------------
-- 19. RV6 F11: a live car parks with a hand-off, never deleted first — the engine path (R.promote.adopt + demote),
-- its refusal, the stop-gap's guards, core stop
--------------------------------------------------------------------------------
do
    local env, Core, S = newServer({ adopt = true })
    local V = Core.Vehicles
    player(env, 1)
    local netId, e, vehId = persisted(Core, v3(100.0, 100.0, 20.0), { props = { colorPrimary = 7 } })
    W.owner[e] = 1
    local spawnedBefore, deletedBefore = #hooks.spawned, #hooks.deleted
    local done = async(env, V.park, netId)
    answerProps(env, 1, { bodyHealth = 555.0, colorPrimary = 1 })       -- the wear is read first (≤ 1 s)
    local nodeId = done() and done()[1]
    check(math.type(nodeId) == 'integer', 'park -> the node id')
    local ad = S.last('adopt')
    eq(ad and ad.id, nodeId, 'RV6 F11: the live car is handed to its node (R.promote.adopt)')
    eq(ad and ad.e, e, '... the car itself, no new entity')
    eq(ad and ad.caller, 'core', '... as core')
    eq(S.last('demote') and S.last('demote').id, nodeId, 'then demoted on the normal path')
    eq(stubs.entities[e].exists, true, 'the car is not deleted by the park')
    eq(stubs.entities[e].frozen, nil, '(no stop-gap freeze on the engine path)')
    eq(V.getInfo(netId) and V.getInfo(netId).parked, nodeId, 'it is the parked node clone now (same netId)')
    eq(#hooks.spawned, spawnedBefore, 'no vehicleSpawned for the same car')
    eq(S.nodes[nodeId].fields.props.bodyHealth, 555.0, "the node starts with the car's real damage")
    eq(S.nodes[nodeId].fields.props.colorPrimary, 7, '... and its own colour')
    eq(V.getRecord(vehId).parked, nodeId, 'the record is parked before the hand-off')
    S.demoteNow(nodeId)                                                -- the engine's demotion finishes
    eq(V.getInfo(netId), nil, 'untracked at the demotion')
    eq(#hooks.deleted, deletedBefore + 1, 'one vehicleDeleted')
    eq(V.getRecord(vehId).props.bodyHealth, 555.0, 'the record keeps the damage')
    -- the engine refuses: the stop-gap retires the car instead
    local n2, e2, vehId2 = persisted(Core, v3(200.0, 100.0, 20.0))
    S.adoptAnswer = { nil, 'entity' }
    local node2 = V.park(n2)
    S.adoptAnswer = nil
    check(math.type(node2) == 'integer', 'an adopt refusal still parks')
    eq(V.getRecord(vehId2).parked, node2, '... the record')
    eq(stubs.entities[e2].frozen, true, '... the car frozen and locked while the copies appear')
    stubs.tick(1100)
    eq(stubs.entities[e2].exists, false, '... then deleted')
    -- the stop-gap never deletes a handle that names another car by then
    rawset(Core, 'SceneRuntime', nil)
    local n3, e3 = persisted(Core, v3(300.0, 100.0, 20.0))
    V.park(n3)
    stubs.entityState(env, e3).vehId = 'someone-else'                 -- (a reused handle)
    stubs.tick(1100)
    eq(stubs.entities[e3].exists, true, 'a reused handle is never deleted')
    -- core stops while a car retires: it goes at once (no timer after a stop)
    local n4, e4 = persisted(Core, v3(400.0, 100.0, 20.0))
    V.park(n4)
    eq(stubs.entities[e4].exists, true, 'retiring ...')
    stubs.triggerOn(env, 'onResourceStop', 0, 'core')
    eq(stubs.entities[e4].exists, false, '... deleted at core stop')
    eq(#stubs.failures, 0, 'section 19: no uncaught error')
    stubs.tick(2000)
end

--------------------------------------------------------------------------------
-- 20. the reviewers' scenarios on the REAL stack (RV4/f1_props, f1c_health, f5_destroyed, f8_adopt_clone;
-- RV6/e2e_parkblink): the vehicles files + the real promote engine
--------------------------------------------------------------------------------
do
    local EVIL = { colorPrimary = 135, colorSecondary = 135, modEngine = -1, modTurbo = false, windowTint = 1,
        plate = 'HACKED', tankHealth = -1000.0, engineHealth = -4000.0, bodyHealth = 480.0 }
    local env, Core = realStack(false, { chars = { [1] = 'char-1', [7] = 'char-9' } })
    local V, Scene, PM = Core.Vehicles, Core.Scene, Core.SceneRuntime.promote
    RH.player(env, 1, { x = 1000.0, y = 1000.0, z = 10.0 })           -- the victim, far away
    RH.player(env, 7, { x = 160.0, y = 100.0, z = 10.0 })             -- a stranger (no keys) who owns the entity
    local asked = {}
    Core.Callback.awaitClientTimeout = function(src, name)
        asked[#asked + 1] = name
        return src == 7 and EVIL or nil
    end
    -- RV4 F1 (A): the park-time read-back of a stranger
    local HONEST = { colorPrimary = 27, colorSecondary = 27, modEngine = 3, modTurbo = true }
    local netId = V.spawn({ model = 'adder', coords = hs.vector3(100.0, 100.0, 10.0), ownerCharId = 'char-1',
        props = HONEST })
    local vehId = V.persist(netId)
    local e = V.getEntity(netId)
    RS.owner[e] = 7
    local plate = V.getRecord(vehId).plate
    local nodeId = V.park(netId)
    check(math.type(nodeId) == 'integer', 'real stack: park')
    local rec = V.getRecord(vehId)
    eq(rec.props.colorPrimary, 27, "RV4 F1 (park): a stranger's read-back keeps the colour")
    eq(rec.props.modEngine, 3, '... the mods')
    eq(rec.props.modTurbo, true, '... the toggles')
    eq(rec.props.plate, plate, '... and the plate')
    eq(rec.props.tankHealth, 0, 'RV4 F1c: healths clamped (never a burning car)')
    eq(rec.props.engineHealth, 0, '... engine too')
    eq(Scene.get(nodeId).fields.props.colorPrimary, 27, 'the node keeps the colour')
    -- RV6 F11: the car was handed over, not deleted first
    eq(hs.entities[e].exists, true, 'RV6 F11: the live car still stands after the park (the DEMOTE hand-off)')
    eq(PM.get(nodeId), nil, '... already demoted (the node is local)')
    hs.tick(600)
    eq(hs.entities[e].exists, false, '... and goes DeleteDelayMs later')
    -- RV4 F1 (B): the demotion read-back of the stranger who owns the clone
    Scene.promote(nodeId)
    hs.tick(200)
    local clone = V.getInfoByRecord(vehId).netId
    check(math.type(clone) == 'integer', 'promoted (manual: D-B parked cars never promote by proximity)')
    RS.owner[V.getEntity(clone)] = 7
    Scene.demote(nodeId)
    hs.tick(100)
    rec = V.getRecord(vehId)
    eq(PM.get(nodeId), nil, 'demoted')
    eq(rec.props.colorPrimary, 27, "RV4 F1 (demotion): a stranger's read-back keeps the colour")
    eq(rec.props.modEngine, 3, '... the mods')
    eq(rec.props.plate, plate, '... the plate')
    eq(rec.props.bodyHealth, 480.0, '... and takes only the wear')
    hs.tick(1000)

    -- RV4 F5: a clone driven 2.7 km and WRECKED never comes back intact at its spot; a DELETED one stays where it was
    for _, mode in ipairs({ 'wrecked', 'deleted' }) do
        local n = V.spawn({ model = 'adder', coords = hs.vector3(100.0, 100.0, 10.0), ownerCharId = 'char-1',
            props = { modEngine = 3, bodyHealth = 1000.0 } })
        local veh = V.persist(n)
        local node = V.park(n)
        hs.tick(1000)
        Scene.promote(node)
        hs.tick(200)
        local ce = V.getEntity(V.getInfoByRecord(veh).netId)
        RS.wear[ce], RS.owner[ce] = { hp = 1000, body = 700.0 }, 1
        hs.triggerOn(env, 'core:scene:applied', 1, node)              -- its owner applied the one-shot part
        hs.coords[ce] = hs.vector3(2000.0, 2000.0, 10.0)
        hs.tick(2000)                                                  -- the monitor has seen it alive (synced)
        if mode == 'wrecked' then RS.wear[ce].hp = 0 else hs.entities[ce].exists = false end
        hs.tick(5000)
        local r, nd = V.getRecord(veh), Scene.get(node)
        if mode == 'wrecked' then
            eq(nd, nil, 'RV4 F5 (wrecked): no node back at the old spot')
            eq(r.parked, false, '... the record is not parked')
            eq(r.destroyed, true, '... it is marked destroyed')
            eq(r.position.x, 100.0, '... it keeps its last saved state')
            eq(r.props.bodyHealth, 1000.0, '... its last saved props (the domain decides what the wreck costs)')
        else
            eq(nd and nd.pos.x, 2000.0, 'RV4 F5 (deleted): the node stays at the last known pose')
            eq(r.position.x, 2000.0, '... the record too')
            eq(r.props.bodyHealth, 700.0, '... with the last known damage')
        end
    end

    -- RV4 F8: a map vehicle's clone cannot be adopted into a persistent record
    local _, mapNode = Core.Registry.withCaller('core', Scene.spawn, { kind = 'vehicle',
        pos = { x = 300.0, y = 300.0, z = 10.0 },
        fields = { model = 'adder', mapEl = 'm1:7', mapType = 'core:vehicle' } })
    Core.Registry.withCaller('core', Scene.promote, mapNode)
    hs.tick(200)
    local mapClone = PM.get(mapNode) and PM.get(mapNode).netId
    check(math.type(mapClone) == 'integer', 'the map vehicle is promoted')
    eq(errOf(V.adopt(mapClone, { ownerCharId = 'char-3' })), 'scene_clone', 'RV4 F8: adopt refuses the scene clone')
    eq(V.getInfo(mapClone), nil, '... it stays untracked')
    check(#hs.failures == 0, 'section 20: no uncaught error (' .. tostring(hs.failures[1]) .. ')')
end

--------------------------------------------------------------------------------
-- 21. client/vehicles.lua: FiveM's RUNTIME native names (natives.json + the Lua codegen rule; the earlier names do
-- not exist in game) and the QUIET damage apply of a local copy (review RV5: no glass / tyre / door event each time
-- a parked car streams in)
--------------------------------------------------------------------------------
do
    stubs.newWorld()
    stubs.clear()
    local client = stubs.newEnv('client', 'core')
    local calls, car = {}, nil
    local function rec(name, ...) calls[#calls + 1] = { name = name, args = table.pack(...) } end
    local function count(name)
        local n = 0
        for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end
        return n
    end
    local function nat(name, impl)
        client[name] = function(...)
            rec(name, ...)
            if impl then return impl(...) end
        end
    end
    -- the world: one vehicle 900 (a fresh local copy: every window intact, doors shut, tyres whole)
    local function fresh() car = { windows = {}, burst = {}, doors = {} } end
    fresh()
    client.GetVehiclePedIsTryingToEnter = function() return 0 end
    client.DoesEntityExist = function(e) return e == 900 and 1 or false end
    client.NetworkHasControlOfEntity = function() return 1 end
    -- getProps' reads by their runtime names (fxref + natives.json, 2026-09-27)
    local reads = { GetVehicleColours = { 1, 2 }, GetVehicleExtraColours = { 3, 4 }, GetVehicleNeonLightsColour =
        { 5, 6, 7 }, GetVehicleTyreSmokeColor = { 8, 9, 10 }, GetEntityModel = { 11 }, GetVehicleNumberPlateText =
        { 'PLATE1' }, GetVehicleNumberPlateTextIndex = { 1 }, GetVehicleInteriorColor = { 12 },
        GetVehicleDashboardColor = { 13 }, GetVehicleWheelType = { 2 }, GetVehicleWindowTint = { 1 },
        GetVehicleLivery = { 3 }, GetVehicleRoofLivery = { 4 }, GetVehicleXenonLightsColor = { 5 },
        GetVehicleEngineHealth = { 900.0 }, GetVehicleBodyHealth = { 800.0 }, GetVehiclePetrolTankHealth = { 700.0 },
        GetVehicleFuelLevel = { 50.0 }, GetVehicleDirtLevel = { 3.0 }, GetIsVehiclePrimaryColourCustom = { false },
        GetIsVehicleSecondaryColourCustom = { false }, IsVehicleNeonLightEnabled = { 1 }, DoesExtraExist = { false },
        GetVehicleMod = { -1 }, IsToggleModOn = { false }, GetVehicleWheelHealth = { 1000.0 },
        GetVehicleLightsState = { 1, false, false }, GetVehicleIndicatorLights = { 0 } }
    for name, answer in pairs(reads) do nat(name, function() return table.unpack(answer) end) end
    nat('IsVehicleWindowIntact', function(_, w) return not car.windows[w] and 1 or false end)
    nat('IsVehicleTyreBurst', function(_, w) return car.burst[w] and 1 or false end)
    nat('GetVehicleDoorAngleRatio', function(_, d) return car.doors[d] and 1.0 or 0.0 end)
    nat('RemoveVehicleWindow', function(_, w) car.windows[w] = true end)
    nat('SmashVehicleWindow', function(_, w) car.windows[w] = true end)
    nat('FixVehicleWindow', function(_, w) car.windows[w] = nil end)
    nat('SetTyreHealth', function(_, w) car.burst[w] = true end)
    nat('SetVehicleTyreBurst', function(_, w) car.burst[w] = true end)
    nat('SetVehicleTyreFixed', function(_, w) car.burst[w] = nil end)
    nat('SetVehicleDoorOpen', function(_, d) car.doors[d] = true end)
    nat('SetVehicleDoorShut', function(_, d) car.doors[d] = nil end)
    for _, name in ipairs({ 'SetVehicleModKit', 'SetVehicleNumberPlateText', 'SetVehicleNumberPlateTextIndex',
        'SetVehicleColours', 'SetVehicleExtraColours', 'SetVehicleInteriorColor', 'SetVehicleDashboardColor',
        'SetVehicleNeonLightsColour', 'SetVehicleNeonLightEnabled', 'SetVehicleTyreSmokeColor', 'SetVehicleWheelType',
        'SetVehicleWindowTint', 'SetVehicleLivery', 'SetVehicleRoofLivery', 'SetVehicleXenonLightsColor',
        'SetVehicleEngineHealth', 'SetVehicleBodyHealth', 'SetVehiclePetrolTankHealth', 'SetVehicleFuelLevel',
        'SetVehicleDirtLevel', 'SetVehicleWheelHealth', 'SetVehicleMod', 'ToggleVehicleMod', 'SetVehicleLights',
        'SetVehicleFullbeam', 'SetVehicleIndicatorLights', 'GetVehicleModVariation' }) do nat(name) end
    stubs.loadImport(client)
    stubs.loadFile(client, 'shared/config.lua')
    stubs.loadFile(client, 'client/vehicles.lua')
    local CV = client.Core.Vehicles
    for _, old in ipairs({ 'GetVehicleExtraColour_5', 'GetVehicleExtraColour_6', 'GetVehicleLivery2',
        'GetVehicleXenonLightColorIndex', 'GetVehicleNeonColour', 'GetVehicleNeonEnabled', 'SetVehicleExtraColour_5',
        'SetVehicleExtraColour_6', 'SetVehicleLivery2', 'SetVehicleXenonLightColorIndex', 'SetVehicleNeonColour',
        'SetVehicleNeonEnabled' }) do
        eq(rawget(client, old), nil, 'no such runtime native: ' .. old)
    end
    local ok, props = pcall(CV.getProps, 900)
    check(ok and type(props) == 'table', 'getProps runs on the runtime names (' .. tostring(ok or props) .. ')')
    props = ok and props or {}
    eq(props.interiorColor, 12, 'interiorColor: GetVehicleInteriorColor')
    eq(props.dashboardColor, 13, 'dashboardColor: GetVehicleDashboardColor')
    eq(props.livery2, 4, 'livery2: GetVehicleRoofLivery')
    eq(props.xenonColor, 5, 'xenonColor: GetVehicleXenonLightsColor')
    eq(props.neonColor and props.neonColor[3], 7, 'neonColor: GetVehicleNeonLightsColour')
    eq(props.neonEnabled and props.neonEnabled[1], true, 'neonEnabled: IsVehicleNeonLightEnabled (BOOL 1)')
    local full = { interiorColor = 1, dashboardColor = 2, livery2 = 3, xenonColor = 4, neonColor = { 1, 2, 3 },
        neonEnabled = { true, false, false, false } }
    check(pcall(CV.setPropsLocal, 900, full), 'applyProps runs on the runtime names')
    eq(count('SetVehicleRoofLivery') + count('SetVehicleXenonLightsColor') + count('SetVehicleInteriorColor'), 3,
        '... roof livery, xenon and interior colour set')
    -- RV5: a damaged parked car's local copy streams in — no smash, no burst, no door slam; only what differs
    local damage = { windows = { [0] = false, [1] = true, ['2'] = true, [3] = true, [4] = true, [5] = true,
        [6] = true, [7] = true }, burstTyres = { [2] = true }, doors = { [3] = true, [4] = false } }
    calls = {}
    CV.setPropsLocal(900, damage)
    eq(count('SmashVehicleWindow'), 0, 'RV5: no SmashVehicleWindow on a local copy (no glass sound)')
    eq(count('RemoveVehicleWindow'), 1, '... the broken window is removed instead')
    eq(count('FixVehicleWindow'), 0, '... intact windows are left alone')
    eq(count('SetVehicleTyreBurst'), 0, 'no SetVehicleTyreBurst (no pop)')
    eq(count('SetTyreHealth'), 1, '... the burst tyre gets its state (SetTyreHealth)')
    eq(count('SetVehicleTyreFixed'), 0, '... whole tyres are left alone')
    eq(count('SetVehicleDoorOpen'), 1, 'the open door is opened (instantly)')
    eq(count('SetVehicleDoorShut'), 0, '... shut doors are not shut again (no slam)')
    calls = {}
    CV.setPropsLocal(900, damage)
    eq(count('RemoveVehicleWindow') + count('SetTyreHealth') + count('SetVehicleDoorOpen') + count('FixVehicleWindow')
        + count('SetVehicleTyreFixed') + count('SetVehicleDoorShut'), 0,
        'the same props again: no condition call at all')
    calls = {}
    CV.setPropsLocal(900, { windows = { [0] = true }, burstTyres = { [2] = false }, doors = { [3] = false } })
    eq(count('FixVehicleWindow'), 1, 'a repaired window is fixed')
    eq(count('SetVehicleTyreFixed'), 1, 'a repaired tyre is fixed')
    eq(count('SetVehicleDoorShut'), 1, 'an open door is shut')
    eq(count('RemoveVehicleWindow') + count('SetTyreHealth') + count('SetVehicleDoorOpen'), 0,
        'indexes a map does not name are left alone (a partial map breaks nothing)')
    -- the networked apply (setProps: an owner applying a clone's one-shot wear) keeps the game's events
    fresh()
    calls = {}
    local done
    client.CreateThread(function() done = CV.setProps(900, damage) end)
    stubs.tick(0)
    eq(done, true, 'setProps on a vehicle this client controls')
    eq(count('SmashVehicleWindow'), 1, 'the networked apply smashes (its owner syncs it once)')
    eq(count('SetVehicleTyreBurst'), 1, '... and bursts')
    eq(#stubs.failures, 0, 'section 21: no uncaught error')
    stubs.triggerOn(client, 'onClientResourceStop', 0, 'core')
    stubs.tick(2000)
end

--------------------------------------------------------------------------------
-- 22. §56 port: the boot check reads the world records in ONE query in last_used_at order; a failed read changes
-- nothing (no node removed, no mark dropped) and is retried; the scene hooks and the lock key never read; every LRU
-- touch stamps last_used_at; no write of core's touches a plugin's meta key
--------------------------------------------------------------------------------
do
    local log
    local function node(S2, id, vehId)
        S2.nodes[id] = { id = id, kind = 'vehicle', owner = 'core', bucket = 0,
            pos = { x = 1.0 * id, y = 0.0, z = 0.0 }, rot = { x = 0.0, y = 0.0, z = 0.0 }, persist = true, fields = { model = 1234, vehId = vehId, props = {} },
            authority = { mode = 'local' } }
    end
    local env, Core, S = newServer({ config = function(Config)
        Config.Vehicles.MaxParked, Config.Vehicles.AutoPark = 3, false
    end, before = function(env2, _, S2)
        log = recordDb(env2)
        putRecord('lru_new', { stored = false, parked = 901, lastUsedAt = 3000 })
        putRecord('lru_old', { stored = false, parked = 902, lastUsedAt = 1000 })
        putRecord('lru_mid', { stored = false, parked = 903, lastUsedAt = 2000 })
        putRecord('lru_gar', { stored = true, lastUsedAt = 500 })               -- garaged: not part of the read
        for i, vehId in ipairs({ 'lru_new', 'lru_old', 'lru_mid' }) do node(S2, 900 + i, vehId) end
        S2.nextId = 950
    end })
    local V = Core.Vehicles
    local world, reads = 0, 0
    for _, c in ipairs(log) do
        if c.fn == 'txQuery' and tostring(c.args[2]):find('FROM vehicles WHERE stored = false OR parked IS NOT NULL',
            1, true) then world = world + 1 end
        if c.fn == 'crud' and c.args[2] == 'vehicles' then reads = reads + 1 end
        if c.fn == 'query' and tostring(c.args[1]):find('vehicles', 1, true) then reads = reads + 1 end
    end
    eq(world, 1, '§56: the boot check reads the world records in ONE (streamed) query')
    eq(reads, 0, '... and no record one by one')
    local stored = {}
    Core.on('vehicleAutoStored', function(vehId) stored[#stored + 1] = vehId end)
    player(env, 1)
    local n4 = persisted(Core, v3(400.0, 100.0, 20.0))
    check(math.type(V.park(n4)) == 'integer', 'a fourth car parks (MaxParked 3)')
    eq(stored[1], 'lru_old', '... and the longest unused by last_used_at is stored')
    -- the hooks and the lock key read nothing: the mirror answers
    for i = #log, 1, -1 do log[i] = nil end
    local clone = S.promoteNow(901)
    check(V.getInfo(clone) ~= nil, 'a promotion adopts the clone')
    S.demoteNow(901, { bodyHealth = 500.0 })
    local hookReads = 0
    for _, c in ipairs(log) do
        if c.fn ~= 'enqueue' and c.fn ~= 'isHealthy' then hookReads = hookReads + 1 end
    end
    eq(hookReads, 0, 'promotion and demotion: queued writes only (no read, no await)')
    local used = sql('SELECT extract(epoch FROM last_used_at)::bigint AS t FROM vehicles WHERE id = $1',
        { 'lru_new' })[1].t
    check(used > 3000, 'every LRU touch stamps last_used_at (' .. tostring(used) .. ')')
    -- a plugin's meta key survives the parking writes (park, demotion, lock key, saveProps, store)
    local n5, _, veh5 = persisted(Core, v3(500.0, 100.0, 20.0), { plate = 'META1' })
    eq(V.setData(veh5, 'insurance', 'gold'), true, 'a plugin key in meta')
    V.saveProps(n5, { colorPrimary = 3 })
    local node5 = V.park(n5)
    local c5 = S.promoteNow(node5)
    V.saveProps(c5, { colorPrimary = 4 })
    V.setLocked(c5, true)
    S.demoteNow(node5, { dirtLevel = 3.0 })
    stubs.tick(600)
    stubs.triggerOn(env, 'core:server:parkedLock', 1, node5)
    V.store(veh5)
    eq(V.getData(veh5, 'insurance'), 'gold', "the plugin's meta key survived park, demotion, lock key and store")
    eq(V.getData(veh5, 'vehType'), 'automobile', "... and core's own")
    eq(#stubs.failures, 0, 'section 22: no uncaught error')
    teardown(env)

    -- a FAILED boot read changes nothing: no node removed, no mark dropped, nothing parked; retried with backoff
    local POS = { x = 70.0, y = 80.0, z = 9.0, heading = 90.0 }
    local env2, Core2, S2 = newServer({ config = function(Config) Config.Vehicles.AutoPark = false end,
        before = function(_, _, S3)
            putRecord('kept1', { stored = false, parked = 960, position = POS })
            node(S3, 960, 'kept1')
            putRecord('limbo9', { stored = false, position = POS })             -- would be parked
            node(S3, 961, 'ghost9')                                               -- would be removed (no record)
            S3.nextId = 970
            bridge.fail('OR parked IS NOT NULL')
        end })
    bridge.unfail()
    local function parkedIn(id)
        local row = sql('SELECT parked FROM vehicles WHERE id = $1', { id })[1]
        return row and row.parked
    end
    check(S2.nodes[960] ~= nil and S2.nodes[961] ~= nil, '§56: a failed boot read removes no node')
    eq(S2.count('spawn'), 0, '... parks nothing')
    eq(parkedIn('kept1'), 960, '... and drops no mark')
    local warned = false
    for _, line in ipairs(stubs.printed) do
        if line:find('the parked vehicles could not be read', 1, true) then warned = true end
    end
    eq(warned, true, '... it is logged')
    stubs.tick(10500)
    eq(S2.nodes[961], nil, 'the retry (10 s later) runs the check: the orphan node goes')
    check(S2.nodes[960] ~= nil and parkedIn('kept1') == 960, '... the parked record keeps its node')
    check(math.type(parkedIn('limbo9')) == 'integer', '... and the out record is parked')
    eq(Core2.Vehicles.getRecord('limbo9').parked, parkedIn('limbo9'), '... (the record API agrees)')
    local removedApi = false
    for _, line in ipairs(stubs.printed) do
        if line:find('was removed (DESIGN §56)', 1, true) then removedApi = true end
    end
    eq(removedApi, false, 'no removed Core.DB name was called anywhere in this VM')
    eq(#stubs.failures, 0, 'section 22 (failed read): no uncaught error')
    teardown(env2)
end

-- @@SECTIONS@@

print(('scene parked: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
