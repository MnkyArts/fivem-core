--[[
    core/tests/scene_attach_tests.lua — Core.Attachments on Core.Scene (DESIGN §20, §55.21.3).

        lua5.4 tests/scene_attach_tests.lua    (from the resource directory, or from tests/)

    1. server/remote.lua's attachments against a RECORDING fake Core.Scene: the exact spawn / attach / set /
       remove calls and their caller (always core), the bone / offset / rotation mapping, re-adds in place,
       refusals, the retry thread (scene store loading, no ped yet), playerLoaded recreation, playerDropped
       removal, persistence across a reconnect and a core restart, routing buckets, a VM without a scene.
    2. The same file against the REAL scene store (tests/scene_server_harness.lua): the nodes it keeps.
    3. client/remote.lua without its old state-bag applier.

    Exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/scene_attach_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local H = dofile(here .. '/scene_server_harness.lua')   -- the real-scene VM of section 2 and the ONE stubs instance
local stubs = H.stubs
local vector3 = stubs.vector3

local passed, failed, section = 0, 0, '?'

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  [%s] %s%s'):format(section, label, detail and ('\n        ' .. detail) or ''))
    return false
end

local function show(v)
    if type(v) == 'string' then return ('%q'):format(v) end
    return tostring(v)
end

local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(show(expected), show(actual)))
end

--- A plain deep copy (vector3 stubs become { x, y, z } tables).
local function copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = copy(x) end
    return out
end

local function xyzEq(t, x, y, z, label)
    local ok = type(t) == 'table' and math.abs((t.x or 1e9) - x) < 1e-6 and math.abs((t.y or 1e9) - y) < 1e-6
        and math.abs((t.z or 1e9) - z) < 1e-6
    return check(ok, label, type(t) == 'table' and ('got %s, %s, %s'):format(show(t.x), show(t.y), show(t.z))
        or ('got ' .. show(t)))
end

local function printed(needle)
    for i = #stubs.printed, 1, -1 do
        if stubs.printed[i]:find(needle, 1, true) then return stubs.printed[i] end
    end
    return nil
end

--------------------------------------------------------------------------------
-- a recording Core.Scene (INTERFACES: the four calls server/remote.lua makes)
--------------------------------------------------------------------------------

--- F.log = { { op, id?, def? | target?, opts? | patch?, caller } } in call order; F.nodes = the live fake nodes.
--- F.ready drives R.store.loaded(); F.refuse.<op> = err makes that op answer nil / false, err.
local function fakeScene(env)
    local F = { log = {}, nodes = {}, nextId = 100, ready = true, refuse = {} }
    local Registry = env.Core.Registry
    local function rec(entry)
        entry.caller = Registry.getCaller()
        F.log[#F.log + 1] = entry
    end
    F.api = {
        spawn = function(def)
            rec({ op = 'spawn', def = copy(def) })
            if F.refuse.spawn then return nil, F.refuse.spawn end
            F.nextId = F.nextId + 1
            F.nodes[F.nextId] = { def = copy(def), owner = Registry.getCaller() }
            return F.nextId
        end,
        attach = function(id, target, opts)
            rec({ op = 'attach', id = id, target = copy(target), opts = copy(opts) })
            local n = F.nodes[id]
            if not n then return false, 'missing' end
            if F.refuse.attach then return false, F.refuse.attach end
            n.attach, n.opts = copy(target), copy(opts)
            return true
        end,
        set = function(id, patch, opts)
            rec({ op = 'set', id = id, patch = copy(patch), opts = copy(opts) })
            local n = F.nodes[id]
            if not n then return false, 'missing' end
            if F.refuse.set then return false, F.refuse.set end
            for k, v in pairs(patch or {}) do n.def.fields[k] = v end
            return true
        end,
        remove = function(id, opts)
            rec({ op = 'remove', id = id, opts = copy(opts) })
            if not F.nodes[id] then return false, 'missing' end
            F.nodes[id] = nil
            return true
        end,
    }
    rawset(env.Core, 'Scene', F.api)
    rawset(env.Core, 'SceneRuntime', { store = { loaded = function() return F.ready end } })
    return F
end

--- 'spawn attach remove:101' — the ops since index `from`, compact.
local function trace(F, from)
    local parts = {}
    for i = (from or 0) + 1, #F.log do
        local c = F.log[i]
        parts[#parts + 1] = c.id and (c.op .. ':' .. c.id) or c.op
    end
    return table.concat(parts, ' ')
end

local function callers(F, from)
    local set = {}
    for i = (from or 0) + 1, #F.log do set[F.log[i].caller] = true end
    local list = {}
    for k in pairs(set) do list[#list + 1] = tostring(k) end
    table.sort(list)
    return table.concat(list, ',')
end

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- one core server VM: api, hooks, db (KVP), perms, the REAL player.lua, a fake scene, server/remote.lua
--------------------------------------------------------------------------------

local SERVER_FILES <const> = { 'server/api.lua', 'shared/hooks.lua', 'server/db.lua', 'server/perms.lua',
    'server/player.lua' }

--- opts = { keepKvp (a restart over the same KVP store and connected players), noScene, before = fn(env, F) }
local function newVM(opts)
    opts = opts or {}
    stubs.newWorld()
    stubs.clear()
    if not opts.keepKvp then stubs.resetServer() end
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for i = 1, #SERVER_FILES do stubs.loadFile(env, SERVER_FILES[i]) end
    local F = not opts.noScene and fakeScene(env) or nil
    if opts.before then opts.before(env, F) end
    stubs.loadFile(env, 'server/remote.lua')
    env.TriggerEvent('onResourceStart', 'core')      -- player.lua: sessions of the connected players (a restart)
    return env, env.Core, F
end

--- A player joins (session) at `pos` in `bucket`; `load` also fires the load request (playerLoaded).
local function join(env, src, pos, bucket, load)
    stubs.connectPlayer(env, src, { coords = pos or vector3(100.0, 200.0, 30.0), license = 'license:p' .. src })
    stubs.buckets[src] = bucket or 0
    if load ~= false then
        env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', src) end)
    end
    return src
end

local PHONE <const> = { id = 'phone', model = 'prop_npc_phone_02', bone = 28422,
    offset = { x = 0.1, y = 0.02, z = -0.01 }, rotation = { x = 10.0, y = 0.0, z = 90.0 } }

local function def(over)
    local d = copy(PHONE)
    for k, v in pairs(over or {}) do d[k] = v end
    return d
end

--------------------------------------------------------------------------------
-- 1a. add: one spawn + one attach, as core, with the entry's bone / offset / rotation
--------------------------------------------------------------------------------

do
    section = 'add'
    local env, Core, F = newVM()
    local A = Core.Attachments
    local loads = 0
    Core.on('playerLoaded', function() loads = loads + 1 end)
    join(env, 1, vector3(100.0, 200.0, 30.0))
    eq(loads, 1, 'the load request fired playerLoaded')
    eq(#F.log, 0, 'playerLoaded of a player without attachments makes nothing')

    eq(A.add(1, def()), 'phone', 'add answers the id')
    eq(trace(F), 'spawn attach:101', 'one spawn, then one attach of that node')
    local sp, at = F.log[1], F.log[2]
    eq(sp.def.kind, 'prop', "the node is a 'prop'")
    eq(sp.def.bucket, 0, "in the player's routing bucket")
    xyzEq(sp.def.pos, 100.0, 200.0, 30.0, 'spawned at the ped')
    eq(sp.def.fields.model, 'prop_npc_phone_02', 'fields.model = the model')
    eq(sp.def.fields.collision, false, 'fields.collision = false')
    eq(sp.def.fields.frozen, false, 'fields.frozen = false')
    eq(count(sp.def.fields), 3, 'and no other field')
    eq(sp.def.persist, nil, 'not persistent (the character document is)')
    eq(at.target.player, 1, 'attach target = { player = src }')
    eq(count(at.target), 1, 'and nothing else')
    eq(at.opts.bone, 28422, 'bone -> bone')
    xyzEq(at.opts.offset, 0.1, 0.02, -0.01, 'offset -> offset')
    xyzEq(at.opts.offrot, 10.0, 0.0, 90.0, 'rotation -> offrot')
    eq(at.opts.rotOrder, 1, "rotOrder 1: the old applier's order (community prop tables), so offsets look the same")
    eq(callers(F), 'core', 'every scene call runs as core')
    eq(F.nodes[101].owner, 'core', 'the node is owned by core')
    eq(stubs.playerState(env, 1).attachments, nil, 'the attachments state bag is never written')

    local stored = Core.Player.getData(1, 'attachments')
    eq(#stored, 1, 'the entry is stored on the character')
    eq(stored[1].id, 'phone', 'with its id')
    eq(stored[1].model, 'prop_npc_phone_02', 'its model')
    eq(stored[1].bone, 28422, 'its bone')
    xyzEq(stored[1].offset, 0.1, 0.02, -0.01, 'its offset')
    xyzEq(stored[1].rotation, 10.0, 0.0, 90.0, 'its rotation')
    local listed = A.list(1)
    eq(#listed, 1, 'list answers from the character data')
    listed[1].model = 'mutated'
    eq(A.list(1)[1].model, 'prop_npc_phone_02', 'list hands out a copy')

    local before = #F.log
    stubs.tick(1100)
    eq(trace(F, before), '', 'the follow-up sync of a fresh holder is a no-op')

    -- a plugin's call through the export: the node is still core's
    before = #F.log
    eq(stubs.exports.core.call('shop', 'Attachments', 'add', 1, def({ id = 'bag', model = 'prop_cs_heist_bag_02',
        bone = 24818 })), 'bag', 'a plugin adds through the export')
    eq(trace(F, before), 'spawn attach:102', 'one spawn + attach')
    eq(callers(F, before), 'core', 'as core, not as the calling plugin')
    eq(F.nodes[102].owner, 'core', 'the plugin-made node is owned by core')
    eq(F.log[#F.log].opts.bone, 24818, 'its bone')

    -- re-adds of an existing id change the node in place
    before = #F.log
    eq(A.add(1, def()), 'phone', 'an identical re-add')
    eq(trace(F, before), '', 'changes nothing')
    before = #F.log
    A.add(1, def({ offset = vector3(0.2, 0.0, 0.0) }))
    eq(trace(F, before), 'attach:101', 'a new offset re-attaches the same node')
    xyzEq(F.log[#F.log].opts.offset, 0.2, 0.0, 0.0, 'with the new offset')
    eq(F.log[#F.log].opts.rotOrder, 1, '... and rotOrder 1 again')
    before = #F.log
    A.add(1, def({ offset = vector3(0.2, 0.0, 0.0), model = 'prop_phone_ing' }))
    eq(trace(F, before), 'set:101', 'a new model is one Scene.set of the same node')
    eq(F.log[#F.log].patch.model, 'prop_phone_ing', 'patch = { model }')
    eq(count(F.log[#F.log].patch), 1, 'and nothing else')
    before = #F.log
    A.add(1, def({ model = 'prop_npc_phone_02', bone = 'SKEL_L_Hand' }))
    eq(trace(F, before), 'set:101 attach:101', 'model and pose changed: set, then attach')
    eq(F.log[#F.log].opts.bone, 'SKEL_L_Hand', 'a bone name is passed on')
    eq(callers(F, before), 'core', 'still as core')
    eq(#A.list(1), 2, 're-adds never add entries')
    eq(A.list(1)[1].bone, 'SKEL_L_Hand', 'the stored entry follows')
    eq(#stubs.failures, 0, 'nothing escaped')
end

--------------------------------------------------------------------------------
-- 1b. the entry -> node mapping, validation, limits
--------------------------------------------------------------------------------

do
    section = 'mapping'
    local env, Core, F = newVM()
    local A = Core.Attachments
    join(env, 1)

    -- defaults and clamps of the old API: no bone = the hand bone, no offset / rotation = zero
    local before = #F.log
    eq(A.add(1, { id = 'cup', model = 'prop_cs_coffee' }), 'cup', 'model alone is enough')
    local at = F.log[#F.log]
    eq(at.op, 'attach', 'attached')
    eq(at.opts.bone, 28422, 'no bone -> PH_R_Hand (28422)')
    xyzEq(at.opts.offset, 0.0, 0.0, 0.0, 'no offset -> zero')
    xyzEq(at.opts.offrot, 0.0, 0.0, 0.0, 'no rotation -> zero')
    A.add(1, { id = 'cup', model = 'prop_cs_coffee', bone = 70000 })
    eq(trace(F, before), 'spawn attach:101', 'a bone past 65535 falls back to the default (no change here)')
    A.add(1, { id = 'cup', model = 'prop_cs_coffee', bone = -3 })
    eq(trace(F, before), 'spawn attach:101', 'so does a negative bone')
    A.add(1, { id = 'cup', model = 'prop_cs_coffee', bone = 1.5 })
    eq(trace(F, before), 'spawn attach:101', 'and a fractional one')
    A.add(1, { id = 'cup', model = 'prop_cs_coffee', bone = 'bad bone!' })
    eq(trace(F, before), 'spawn attach:101', 'and a malformed bone name')
    A.add(1, { id = 'cup', model = 'prop_cs_coffee', bone = 0 })
    eq(F.log[#F.log].opts.bone, 0, 'bone 0 is a valid tag')
    A.add(1, { id = 'cup', model = 'prop_cs_coffee', offset = 'junk', rotation = { x = 0 / 0, y = 1, z = 2 } })
    xyzEq(F.log[#F.log].opts.offset, 0.0, 0.0, 0.0, 'an unusable offset is zero (as before)')
    xyzEq(F.log[#F.log].opts.offrot, 0.0, 0.0, 0.0, 'a NaN rotation is zero')
    A.add(1, { id = 'cup', model = 'prop_cs_coffee', offset = vector3(1000.0, -1000.0, 0.5) })
    xyzEq(F.log[#F.log].opts.offset, 1000.0, -1000.0, 0.5, 'a vector3 offset up to ±1000 m passes')

    -- an integer model hash reaches the scene as '0x' + 8 hex digits
    before = #F.log
    eq(A.add(1, { id = 'hash', model = -1038739674 }), 'hash', 'a model hash is accepted')
    eq(F.log[before + 1].def.fields.model, ('0x%08X'):format(-1038739674 & 0xFFFFFFFF),
        "a negative hash -> its u32 '0x' form")
    eq(F.log[before + 1].def.fields.model, '0xC2161726', "(-1038739674 = '0xC2161726', upper-case hex)")
    eq(A.list(1)[2].model, -1038739674, 'the stored entry keeps the hash itself')
    A.add(1, { id = 'hash2', model = 0x1A2B })
    eq(F.log[#F.log - 1].def.fields.model, '0x00001A2B', 'a small hash is zero-padded')
    -- a JSON round trip may hand integers back as integral floats: they stay a hash / a bone tag
    before = #F.log
    A.add(1, { id = 'hash2', model = 6699.0, bone = 31086.0 })
    eq(trace(F, before), 'attach:103', 'an integral float model is the same hash (0x1A2B = 6699): no set')
    eq(F.log[#F.log].opts.bone, 31086, 'an integral float bone is a bone tag, not the default')
    eq(math.type(A.list(1)[3].model), 'integer', 'the stored model is an integer again')
    eq(math.type(A.list(1)[3].bone), 'integer', 'and is stored as an integer')

    -- refusals: nothing reaches the scene, nothing is stored
    local stored = #A.list(1)
    before = #F.log
    local id, err = A.add(1, { id = 'x', model = 'prop.with.dots' })
    eq(id, nil, 'a model name the scene cannot take is refused')
    eq(err, 'model must be a model name or a hash', 'with the old message')
    eq(select(2, A.add(1, { id = 'x', model = ('m'):rep(65) })), 'model must be a model name or a hash',
        'a model name over 64 characters')
    eq(select(2, A.add(1, { id = 'x', model = 1.5 })), 'model must be a model name or a hash', 'a float model')
    eq(select(2, A.add(1, { id = 'x', model = {} })), 'model must be a model name or a hash', 'a table model')
    eq(select(2, A.add(1, { id = 'bad id!', model = 'prop_cs_coffee' })), 'invalid id', 'a malformed id')
    eq(select(2, A.add(1, 'nope')), 'definition must be a table', 'a non-table definition')
    eq(select(2, A.add(1, { id = 'x', model = 'prop_cs_coffee', offset = vector3(0.0, 1000.5, 0.0) })),
        'offset out of range', 'an offset past ±1000 m (R.valid.offset)')
    eq(select(2, A.add(99, def())), 'no session', 'a src without a session')
    eq(select(2, A.add('1', def())), 'no session', 'a string src')
    eq(trace(F, before), '', 'none of them reached the scene')
    eq(#A.list(1), stored, 'none of them was stored')

    -- an id is generated when missing
    local gen = A.add(1, { model = 'prop_cs_coffee' })
    check(type(gen) == 'string' and #gen == 32, 'a missing id becomes a uuid', show(gen))

    -- MAX_ATTACHMENTS = 12: the 13th new id is refused, a re-add of a stored id still passes
    for i = #A.list(1) + 1, 12 do A.add(1, { id = 'n' .. i, model = 'prop_cs_coffee' }) end
    eq(#A.list(1), 12, 'twelve entries')
    before = #F.log
    eq(select(2, A.add(1, { id = 'thirteen', model = 'prop_cs_coffee' })), 'too many attachments', 'the 13th')
    eq(trace(F, before), '', 'reaches no scene call')
    eq(A.add(1, { id = 'cup', model = 'prop_cs_coffee', offset = vector3(0.0, 0.0, 1.0) }), 'cup',
        'a re-add of a stored id is not a new entry')
    eq(count(F.nodes), 12, 'twelve nodes live')
    eq(#stubs.failures, 0, 'nothing escaped')
end

--------------------------------------------------------------------------------
-- 1c. remove / clear, scene refusals, a transient refusal through the retry thread
--------------------------------------------------------------------------------

do
    section = 'remove'
    local env, Core, F = newVM()
    local A = Core.Attachments
    join(env, 1)
    A.add(1, def())
    A.add(1, def({ id = 'bag', model = 'prop_cs_heist_bag_02', bone = 24818 }))
    A.add(1, def({ id = 'hat', model = 'prop_ld_hat_01', bone = 31086 }))
    eq(count(F.nodes), 3, 'three nodes')

    local before = #F.log
    eq(A.remove(1, 'bag'), true, 'remove answers true for a stored id')
    eq(trace(F, before), 'remove:102', 'exactly that node is removed')
    eq(F.log[#F.log].opts.fade, true, 'faded out where it is seen (not left lingering)')
    eq(callers(F, before), 'core', 'as core')
    eq(#A.list(1), 2, 'the entry left the character data')
    eq(A.list(1)[1].id, 'phone', 'the others keep their order')
    eq(A.list(1)[2].id, 'hat', '...')
    before = #F.log
    eq(A.remove(1, 'bag'), false, 'a second remove answers false')
    eq(A.remove(1, 'nope'), false, 'an unknown id answers false')
    eq(A.remove(1, 42), false, 'a non-string id answers false')
    eq(A.remove(77, 'phone'), false, 'a src without a session answers false')
    eq(trace(F, before), '', 'none of them touched the scene')
    before = #F.log
    eq(stubs.exports.core.call('shop', 'Attachments', 'remove', 1, 'hat'), true, 'a plugin removes through the export')
    eq(trace(F, before), 'remove:103', 'its node goes')
    eq(callers(F, before), 'core', 'removed as core (a plugin could not remove a core node itself)')

    A.add(1, def({ id = 'bag', model = 'prop_cs_heist_bag_02' }))
    before = #F.log
    eq(A.clear(1), true, 'clear answers true')
    eq(trace(F, before):gsub('remove:%d+', 'remove'), 'remove remove', 'one remove per node')
    eq(count(F.nodes), 0, 'no node left')
    eq(#A.list(1), 0, 'list is empty')
    eq(#Core.Player.getData(1, 'attachments'), 0, 'and so is the character data')
    eq(A.clear(77), false, 'clear of a src without a session answers false')
    before = #F.log
    A.add(1, def())
    eq(trace(F, before), 'spawn attach:105', 'after a clear an add spawns anew')

    section = 'refusals'
    -- the scene refuses the model: add fails, nothing is stored
    F.refuse.spawn = 'model'
    before = #F.log
    local id, err = A.add(1, def({ id = 'odd', model = 'not_a_prop' }))
    eq(id, nil, 'a model the scene refuses fails the add')
    eq(err, 'scene refused the prop (model)', 'with the scene code in the message')
    eq(trace(F, before), 'spawn', 'no attach after a refused spawn')
    eq(#A.list(1), 1, 'nothing was stored')
    F.refuse.spawn = nil
    -- a model change the scene refuses: the node keeps its model and pose, the entry is not changed
    F.refuse.set = 'model'
    before = #F.log
    eq(A.add(1, def({ model = 'not_a_prop', offset = vector3(0.3, 0.0, 0.0) })), nil, 'a refused model change')
    eq(trace(F, before), 'set:105', 'the pose is not touched after a refused model')
    eq(A.list(1)[1].model, 'prop_npc_phone_02', 'the stored entry is unchanged')
    F.refuse.set = nil

    -- a node that vanished behind our back (core-privileged code removed it): a re-add makes a new one
    F.nodes[105] = nil
    before = #F.log
    eq(A.add(1, def({ offset = vector3(0.0, 0.0, 0.5) })), 'phone', 'a re-add of a vanished node')
    eq(trace(F, before), 'attach:105 spawn attach:106', "the re-attach answers 'missing': spawned anew")
    xyzEq(F.log[#F.log].opts.offset, 0.0, 0.0, 0.5, 'with the new offset')

    -- a transient refusal (the ped vanished between the check and the attach): stored, made by the retry thread
    F.refuse.attach = 'attach'
    before = #F.log
    eq(A.add(1, def({ id = 'later', model = 'prop_ld_hat_01' })), 'later', 'a transient refusal still stores')
    eq(trace(F, before), 'spawn attach:107 remove:107', 'the half-made node is removed at once')
    eq(A.list(1)[2].id, 'later', 'the entry is stored')
    F.refuse.attach = nil
    before = #F.log
    stubs.tick(1100)
    eq(trace(F, before), 'spawn attach:108', 'the retry thread makes it a second later')
    -- a re-add whose re-attach is refused transiently: the node is made again, later
    F.refuse.attach = 'attach'
    before = #F.log
    eq(A.add(1, def({ id = 'later', model = 'prop_ld_hat_01', bone = 12844 })), 'later', 'stored anyway')
    eq(trace(F, before), 'attach:108 remove:108 spawn attach:109 remove:109', 'half-updated node removed, retry fails')
    F.refuse.attach = nil
    before = #F.log
    stubs.tick(1100)
    eq(trace(F, before), 'spawn attach:110', 'the retry thread makes it with the new bone')
    eq(F.log[#F.log].opts.bone, 12844, '...')
    before = #F.log
    stubs.tick(5000)
    eq(trace(F, before), '', 'and then goes quiet (nobody waits)')
    local threads = 0
    local realThread = env.CreateThread
    env.CreateThread = function(fn) threads = threads + 1 return realThread(fn) end
    A.add(1, def({ id = 'cup', model = 'prop_cs_coffee' }))
    eq(threads, 0, 'an add that is made at once starts no thread')
    F.refuse.attach = 'attach'
    A.add(1, def({ id = 'again', model = 'prop_ld_hat_01' }))
    F.refuse.attach = nil
    eq(threads, 1, 'the retry thread had ended: the next wait starts a new one')
    A.add(1, def({ id = 'again', model = 'prop_ld_hat_01', bone = 1 }))
    eq(threads, 1, 'never a second one while it runs')
    stubs.tick(1100)
    eq(A.list(1)[4].id, 'again', 'stored')
    eq(count(F.nodes), 4, 'and made (phone, later, cup, again)')
    eq(A.list(1)[2].bone, 12844, "'later' was stored with its new bone")
    env.CreateThread = realThread
    eq(#stubs.failures, 0, 'nothing escaped')
end

--------------------------------------------------------------------------------
-- 1d. playerLoaded recreates the stored props; the retry thread; playerDropped; a reconnect
--------------------------------------------------------------------------------

do
    section = 'lifecycle'
    local env, Core, F = newVM()
    local A = Core.Attachments

    -- a character with stored props: the load request makes one node per usable entry, in list order
    join(env, 2, vector3(-50.0, 80.0, 12.0), 0, false)
    Core.Player.setData(2, 'attachments', {
        { id = 'phone', model = 'prop_npc_phone_02', bone = 28422, offset = { x = 0.1, y = 0.02, z = -0.01 },
            rotation = { x = 10.0, y = 0.0, z = 90.0 } },
        { model = 'prop_no_id' },                                     -- junk: no id
        { id = 'hat', model = 'prop_ld_hat_01', bone = 31086, offset = { x = 0.12, y = 0.0, z = 0.0 },
            rotation = { x = 0.0, y = 90.0, z = 180.0 } },
        { id = 'weird', model = 'bad model' },                        -- junk: a model the scene cannot take
        'not even a table',
    })
    eq(#F.log, 0, 'nothing before the load request')
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 2) end)
    eq(trace(F), 'spawn attach:101 spawn attach:102', 'playerLoaded: spawn + attach per usable entry, in order')
    xyzEq(F.log[1].def.pos, -50.0, 80.0, 12.0, 'spawned at the ped')
    eq(F.log[1].def.fields.model, 'prop_npc_phone_02', 'the first entry')
    eq(F.log[4].opts.bone, 31086, 'the second entry keeps its bone')
    xyzEq(F.log[4].opts.offset, 0.12, 0.0, 0.0, 'its offset')
    xyzEq(F.log[4].opts.offrot, 0.0, 90.0, 180.0, 'its rotation')
    eq(F.log[2].target.player, 2, 'attached to player 2')
    eq(callers(F), 'core', 'as core')
    check(printed('2 unusable stored attachment') ~= nil, 'the unusable entries are reported once')
    eq(#A.list(2), 4, 'list still answers every stored table entry (the data is untouched)')

    -- playerDropped removes every node; the document keeps the list
    local before = #F.log
    stubs.dropPlayer(env, 2)
    eq(trace(F, before), 'remove:101 remove:102', 'playerDropped removes each node')
    eq(F.log[#F.log].opts.fade, true, 'faded')
    eq(callers(F, before), 'core', 'as core')
    eq(count(F.nodes), 0, 'no node left behind')
    local doc
    for _, d in pairs(Core.DB.find('characters', function() return true end) or {}) do
        if type(d) == 'table' and d.attachments then doc = d end
    end
    check(doc ~= nil and #doc.attachments == 5, 'the character document kept the list (persisted by the drop save)')

    -- the same player comes back: the stored props come back
    before = #F.log
    join(env, 2, vector3(5.0, 6.0, 7.0))
    eq(trace(F, before), 'spawn attach:103 spawn attach:104', 'a reconnect recreates them from the document')
    xyzEq(F.log[before + 1].def.pos, 5.0, 6.0, 7.0, 'at the new ped')

    section = 'retry'
    -- the scene store still loads: nothing is made, the retry thread waits for it
    F.ready = false
    join(env, 3, vector3(1.0, 2.0, 3.0), 0, false)
    Core.Player.setData(3, 'attachments', { { id = 'phone', model = 'prop_npc_phone_02' } })
    before = #F.log
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 3) end)
    stubs.tick(3100)
    eq(trace(F, before), '', 'no scene call while the store loads')
    F.ready = true
    stubs.tick(1000)
    eq(trace(F, before), 'spawn attach:105', 'the retry thread makes the node once the store is ready')

    -- an add while the store loads is stored at once and made later
    F.ready = false
    before = #F.log
    eq(A.add(3, def({ id = 'bag', model = 'prop_cs_heist_bag_02' })), 'bag', 'an add while the store loads')
    eq(trace(F, before), '', 'reaches no scene call yet')
    eq(#A.list(3), 2, 'but is stored')
    F.ready = true
    stubs.tick(1000)
    eq(trace(F, before), 'spawn attach:106', 'and gets its node from the retry thread')

    -- no ped on the server yet: the same
    join(env, 4, vector3(1.0, 2.0, 3.0), 0, false)
    Core.Player.setData(4, 'attachments', { { id = 'hat', model = 'prop_ld_hat_01' } })
    local ped = stubs.peds[4]
    stubs.peds[4] = 0
    before = #F.log
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 4) end)
    stubs.tick(2100)
    eq(trace(F, before), '', 'no node without a ped')
    stubs.peds[4] = ped
    stubs.tick(1000)
    eq(trace(F, before), 'spawn attach:107', 'the node follows once the ped is there')

    -- a stored entry the scene refuses: one warning, later syncs skip it, a re-add tries again
    join(env, 6, vector3(1.0, 2.0, 3.0), 0, false)
    Core.Player.setData(6, 'attachments', { { id = 'odd', model = 'not_a_prop' }, { id = 'cap', model = 'prop_cap' } })
    F.refuse.spawn = 'model'
    before = #F.log
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 6) end)
    eq(trace(F, before), 'spawn spawn', 'both stored entries were tried')
    check(printed('the scene refused prop odd of player 6 (model)') ~= nil, 'the refusal is logged')
    F.refuse.spawn = nil
    before = #F.log
    stubs.triggerOn(env, 'onPlayerBucketChange', 0, '6', 0, 0)
    eq(trace(F, before), '', 'a later sync does not ask again for the same entries')
    eq(A.add(6, { id = 'cap', model = 'prop_cap' }), 'cap', 'a re-add')
    eq(trace(F, before), 'spawn attach:108', 'tries the refused entry again')

    -- a waiting player who leaves is forgotten
    stubs.peds[4] = 0
    A.add(4, def({ id = 'cup', model = 'prop_cs_coffee' }))
    before = #F.log
    stubs.dropPlayer(env, 4)
    eq(trace(F, before), 'remove:107', 'the drop removes the node that existed')
    stubs.tick(5000)
    eq(trace(F, before), 'remove:107', 'and the retry thread never makes one for the gone player')
    eq(#stubs.failures, 0, 'nothing escaped')
end

--------------------------------------------------------------------------------
-- 1e. a core restart (players stay connected), routing buckets, a VM without a scene
--------------------------------------------------------------------------------

do
    section = 'restart'
    local env, Core = newVM()
    join(env, 1, vector3(10.0, 20.0, 30.0))
    join(env, 2, vector3(40.0, 50.0, 60.0))
    Core.Attachments.add(1, def())
    Core.Attachments.add(2, def({ id = 'hat', model = 'prop_ld_hat_01', bone = 31086 }))
    Core.Attachments.add(2, def({ id = 'bag', model = 'prop_cs_heist_bag_02' }))
    Core.Player.saveAll()

    -- core restarts: a fresh VM over the same KVP store, both players still connected, the scene store loading
    local F2
    env, Core, F2 = newVM({ keepKvp = true, before = function(_, F) F.ready = false end })
    eq(Core.Player.isLoaded(1) and Core.Player.isLoaded(2), true, 'player.lua rebuilt both sessions')
    stubs.tick(0)
    stubs.tick(3000)
    eq(#F2.log, 0, 'nothing is made while the scene store loads')
    F2.ready = true
    stubs.tick(1000)
    eq(trace(F2), 'spawn attach:101 spawn attach:102 spawn attach:103',
        'once it is ready every loaded player gets the nodes back (no playerLoaded needed)')
    eq(F2.log[2].target.player, 1, "player 1's prop")
    eq(F2.log[4].target.player, 2, "player 2's first prop")
    eq(F2.log[6].target.player, 2, "player 2's second prop")
    eq(callers(F2), 'core', 'as core')
    -- the clients ask for their load again after the restart: playerLoaded is a no-op now
    local before = #F2.log
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 1) end)
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 2) end)
    stubs.tick(2000)
    eq(trace(F2, before), '', 'the playerLoaded after the restart finds everything in place')
    eq(#stubs.failures, 0, 'nothing escaped')

    section = 'buckets'
    local F
    env, Core, F = newVM()
    local A = Core.Attachments
    join(env, 5, vector3(1.0, 1.0, 1.0), 7)
    A.add(5, def())
    A.add(5, def({ id = 'hat', model = 'prop_ld_hat_01' }))
    eq(F.log[1].def.bucket, 7, "the node lives in the player's routing bucket")
    eq(F.log[3].def.bucket, 7, 'every node of that player')
    -- SetPlayerRoutingBucket raises the engine's onPlayerBucketChange (player, bucket, oldBucket): the nodes
    -- are made again in the new bucket
    local function moved(src, bucket, old)
        stubs.buckets[src] = bucket
        stubs.triggerOn(env, 'onPlayerBucketChange', 0, tostring(src), bucket, old)
    end
    before = #F.log
    moved(5, 9, 7)
    eq(trace(F, before), 'remove:101 remove:102 spawn attach:103 spawn attach:104', 'removed, then made in bucket 9')
    eq(F.log[before + 1].opts.fade, true, 'the old ones fade')
    eq(F.log[before + 3].def.bucket, 9, 'the new node is in bucket 9')
    eq(F.log[before + 5].def.bucket, 9, 'both of them')
    eq(callers(F, before), 'core', 'as core')
    before = #F.log
    moved(5, 9, 9)
    eq(trace(F, before), '', 'the same bucket again changes nothing')
    -- a move the event did not bring (yet) is noticed by the next add: that entry first, the rest by the retry thread
    stubs.buckets[5] = 0
    before = #F.log
    A.add(5, def({ id = 'cup', model = 'prop_cs_coffee' }))
    eq(trace(F, before), 'remove:103 remove:104 spawn attach:105', 'the old nodes go, the new entry is made')
    eq(F.log[#F.log - 1].def.bucket, 0, 'in bucket 0')
    before = #F.log
    stubs.tick(1100)
    eq(trace(F, before), 'spawn attach:106 spawn attach:107', 'the others follow into bucket 0')
    eq(F.log[before + 1].def.bucket, 0, '...')
    eq(count(F.nodes), 3, 'three nodes, all in bucket 0')
    -- a player without props, a player without a session: the event costs nothing
    join(env, 6, vector3(1.0, 1.0, 1.0), 0)
    before = #F.log
    moved(6, 3, 0)
    moved(66, 3, 0)
    stubs.triggerOn(env, 'onPlayerBucketChange', 0, 'junk', 3, 0)
    eq(trace(F, before), '', 'no props / no session / junk: no scene call')
    eq(#stubs.failures, 0, 'nothing escaped')

    section = 'no scene'
    env, Core = newVM({ noScene = true })
    join(env, 1)
    eq(Core.Attachments.add(1, def()), 'phone', 'without a scene an add is stored')
    eq(#Core.Attachments.list(1), 1, 'and listed')
    eq(Core.Attachments.remove(1, 'phone'), true, 'remove works')
    Core.Attachments.add(1, def())
    eq(Core.Attachments.clear(1), true, 'clear works')
    stubs.dropPlayer(env, 1)
    stubs.tick(5000)
    eq(stubs.playerState(env, 1).attachments, nil, 'no state bag either')
    eq(#stubs.failures, 0, 'nothing escaped (no retry thread spins without a scene)')
end

--------------------------------------------------------------------------------
-- 1f. scene capacity (review RV4 F3): a prop refused 'limit' stays stored and is retried with a backoff (5 s,
--     doubling to 60 s while nothing gets placed); one attempt per round, not one per waiting player
--------------------------------------------------------------------------------

do
    section = 'capacity'
    local env, Core, F = newVM()
    local A = Core.Attachments
    local function spawns(from)
        local n = 0
        for i = (from or 0) + 1, #F.log do if F.log[i].op == 'spawn' then n = n + 1 end end
        return n
    end
    -- the reviewer's scenario: a player with a stored phone reconnects while the scene is full
    join(env, 1, vector3(100.0, 200.0, 30.0))
    eq(A.add(1, def()), 'phone', 'a stored phone')
    stubs.dropPlayer(env, 1)
    F.refuse.spawn = 'limit'
    local before = #F.log
    join(env, 1, vector3(100.0, 200.0, 30.0))
    eq(spawns(before), 1, 'the reconnect tries the stored phone once: refused (limit)')
    check(printed('no room for a prop of player 1 (limit)') ~= nil, 'the capacity wait is logged')
    F.refuse.spawn = nil                                  -- the cap frees a second later
    stubs.tick(1000)
    eq(spawns(before), 1, 'not before the backoff (5 s)')
    stubs.tick(4100)
    eq(spawns(before), 2, 'the capacity round at 5 s makes it')
    eq(count(F.nodes), 1, 'the phone has its node again (it was never marked failed)')
    eq(F.log[#F.log].op, 'attach', 'spawned and attached')

    -- the cap stays full: one attempt per round (not one per waiting player), 5, 10, 20, 40, 60 s apart
    join(env, 2, vector3(10.0, 20.0, 30.0))
    join(env, 3, vector3(40.0, 50.0, 60.0))
    F.refuse.spawn = 'limit'
    before = #F.log
    eq(A.add(2, def({ id = 'bag', model = 'prop_cs_heist_bag_02' })), 'bag', 'an add while the scene is full stores the entry')
    eq(#A.list(2), 1, 'stored')
    eq(A.add(3, def({ id = 'hat', model = 'prop_ld_hat_01' })), 'hat', 'another player too')
    eq(spawns(before), 2, 'each add tried once')
    stubs.tick(1100)
    eq(spawns(before), 3, 'the new holders\' follow-up sync (1 s): one attempt, the other player held back 1 s')
    local t = spawns(before)
    stubs.tick(4000)
    eq(spawns(before), t + 1, 'round 1 at 5 s: one refused attempt, the other player held back')
    stubs.tick(9800)
    eq(spawns(before), t + 1, 'round 2 waits 10 s (nothing was placed)')
    stubs.tick(300)
    eq(spawns(before), t + 2, 'round 2')
    stubs.tick(20000)
    eq(spawns(before), t + 3, 'round 3, 20 s later')
    stubs.tick(40000)
    eq(spawns(before), t + 4, 'round 4, 40 s later')
    stubs.tick(60000)
    eq(spawns(before), t + 5, 'round 5, 60 s later (the cap of the backoff)')
    stubs.tick(60000)
    eq(spawns(before), t + 6, 'and every 60 s after that')
    F.refuse.spawn = nil
    stubs.tick(60000)
    eq(count(F.nodes), 3, 'room again: the next round makes both waiting props')
    local quiet = #F.log
    stubs.tick(300000)
    eq(#F.log, quiet, 'nobody waits: the retry thread is gone')

    -- a player who leaves while waiting is forgotten
    F.refuse.spawn = 'limit'
    eq(A.add(2, def({ id = 'cup', model = 'prop_cs_coffee' })), 'cup', 'stored while full')
    stubs.dropPlayer(env, 2)
    F.refuse.spawn = nil
    before = #F.log
    stubs.tick(70000)
    eq(spawns(before), 0, 'the dropped player gets no node later')
    eq(#stubs.failures, 0, 'nothing escaped')
    stubs.dropPlayer(env, 1)
    stubs.dropPlayer(env, 3)
end

--------------------------------------------------------------------------------
-- 2. against the REAL scene store (scene_kinds → scene_store → scene; the index / interest / flush are the
--    harness's recording fakes): what the scene keeps for an attachment
--------------------------------------------------------------------------------

do
    section = 'real scene'
    local env, Core = H.newServer()
    local data = {}                                   -- a Core.Player stand-in: [src] = the character data
    Core.Player = {
        isLoaded = function(src) return data[src] ~= nil end,
        getData = function(src, key) return data[src] and copy(data[src][key]) or nil end,
        setData = function(src, key, value)
            if not data[src] then return false end
            data[src][key] = copy(value)
            return true
        end,
        getPlayers = function()
            local out = {}
            for src in pairs(data) do out[#out + 1] = src end
            table.sort(out)
            return out
        end,
    }
    stubs.loadFile(env, 'server/remote.lua')          -- after the scene files, as in the manifest
    stubs.tick(0)
    local Scene, A = Core.Scene, Core.Attachments
    local function props() return Scene.list({ owner = 'core', kind = 'prop' }) end

    H.player(env, 1, { x = 100.0, y = 200.0, z = 30.0 }, 0)
    data[1] = {}
    Core.emitHook('playerLoaded', 1)
    eq(#props(), 0, 'no props, no nodes')

    eq(A.add(1, def()), 'phone', 'add answers the id')
    local ids = props()
    eq(#ids, 1, 'one core prop node')
    local n = Scene.get(ids[1]) or {}
    eq(n.kind, 'prop', "kind 'prop'")
    eq(n.owner, 'core', 'owned by core')
    eq(n.bucket, 0, 'bucket 0')
    eq(n.persist, false, 'not persistent')
    eq(n.attach and n.attach.player, 1, 'attach = { player = 1 }')
    eq(n.bone, 28422, 'bone')
    xyzEq(n.offset, 0.1, 0.02, -0.01, 'offset')
    xyzEq(n.offrot, 10.0, 0.0, 90.0, 'offrot')
    eq(n.rotOrder, 1, 'rotOrder 1 on the real node (the index sends it as extra.q)')
    eq(n.fields and n.fields.model, 'prop_npc_phone_02', 'fields.model')
    eq(n.fields and n.fields.collision, false, 'fields.collision = false')
    eq(n.fields and n.fields.frozen, false, 'fields.frozen = false')
    eq(n.parent, nil, 'a root (attached to the player, not parented)')
    local attachCalls = 0
    for _, c in ipairs(H.calls('changed', ids[1])) do if c.what == 'attach' then attachCalls = attachCalls + 1 end end
    eq(#H.calls('put', ids[1]), 1, 'the index got one PUT')
    eq(attachCalls, 1, "and one 'attach' change in the same run (coalesced by the index)")

    eq(stubs.exports.core.call('shop', 'Attachments', 'add', 1, def({ id = 'bag', model = 'prop_cs_heist_bag_02',
        bone = 'SKEL_Spine3' })), 'bag', 'a plugin adds through the export')
    ids = props()
    eq(#ids, 2, 'two nodes')
    local bag = Scene.get(ids[2]) or {}
    eq(bag.owner, 'core', "the plugin's attachment is still core's node")
    eq(bag.bone, 'SKEL_Spine3', 'a bone name is kept')
    eq(A.add(1, { id = 'hash', model = -1038739674 }), 'hash', 'a model hash')
    ids = props()
    eq(Scene.get(ids[3]).fields.model, '0xC2161726', "reaches the real scene as '0xC2161726'")

    -- re-adds change the same node in place
    A.add(1, def({ offset = vector3(0.2, 0.0, 0.0) }))
    eq(#props(), 3, 'a re-add makes no new node')
    xyzEq(Scene.get(ids[1]).offset, 0.2, 0.0, 0.0, 'the new offset is on the same node')
    eq(Scene.get(ids[1]).rotOrder, 1, '... still in rotation order 1')
    A.add(1, def({ offset = vector3(0.2, 0.0, 0.0), model = 'prop_phone_ing' }))
    eq(Scene.get(ids[1]).fields.model, 'prop_phone_ing', 'the new model is on the same node')

    eq(A.remove(1, 'bag'), true, 'remove')
    eq(Scene.get(ids[2]), nil, 'its node is gone')
    eq(#props(), 2, 'the rest stay')

    -- another bucket
    H.player(env, 2, { x = -300.0, y = 50.0, z = 20.0 }, 7)
    data[2] = { attachments = { { id = 'hat', model = 'prop_ld_hat_01', bone = 31086,
        offset = { x = 0.12, y = 0.0, z = 0.0 }, rotation = { x = 0.0, y = 90.0, z = 180.0 } } } }
    Core.emitHook('playerLoaded', 2)
    ids = props()
    eq(#ids, 3, "player 2's stored hat got its node")
    local hat = Scene.get(ids[3]) or {}
    eq(hat.bucket, 7, "in player 2's bucket")
    eq(hat.attach and hat.attach.player, 2, 'attached to player 2')
    xyzEq(hat.offrot, 0.0, 90.0, 180.0, 'offrot from the stored rotation')

    -- a drop: player.lua's hook first, then the raw event scene.lua listens to — nothing stays behind
    Core.emitHook('playerDropped', 1, 'char1')
    data[1] = nil
    stubs.dropPlayer(env, 1)
    ids = props()
    eq(#ids, 1, "player 1's nodes are gone, not left standing at the last pose")
    eq(Scene.get(ids[1]).attach.player, 2, "player 2's node stays")
    Core.emitHook('playerDropped', 2, 'char2')
    data[2] = nil
    stubs.dropPlayer(env, 2)
    eq(#props(), 0, 'nothing left')
    eq(#stubs.failures, 0, 'nothing escaped')
end

do  -- run I1 (task 2): admin's Maps model validator refuses every model it does not list — a weapon object or an
    -- addon prop on a player is no map element: Scene takes it (the validator informs, only a provider refuses)
    section = 'real scene + Maps validator'
    local env, Core = H.newServer({ maps = true })
    local data = { [1] = {} }
    Core.Player = {
        isLoaded = function(src) return data[src] ~= nil end,
        getData = function(src, key) return data[src] and copy(data[src][key]) or nil end,
        setData = function(src, key, value) data[src][key] = copy(value) return true end,
        getPlayers = function() return { 1 } end,
    }
    stubs.loadFile(env, 'server/remote.lua')
    stubs.tick(0)
    local asked = 0
    Core.MapsRuntime.setModelValidator(function() asked = asked + 1 return false end)
    H.player(env, 1, { x = 10.0, y = 20.0, z = 30.0 }, 0)
    Core.emitHook('playerLoaded', 1)
    local A, Scene = Core.Attachments, Core.Scene
    eq(A.add(1, { id = 'gun', model = 'w_pi_pistol', bone = 24818 }), 'gun', 'a weapon object on the player')
    eq(A.add(1, { id = 'hash', model = -1038739674 }), 'hash', 'a model hash')
    local ids = Scene.list({ owner = 'core', kind = 'prop' })
    eq(#ids, 2, 'both got their scene node although the Maps validator refuses them')
    check(asked >= 1, 'the validator was asked (and only informs)')
    eq(Scene.get(ids[1]).fields.lod, 100, 'the refused model got the default lod')
    Core.Scene.setModelInfo(function(_, model) if model == 'w_pi_pistol' then return false end end)
    eq(select(2, Scene.spawn({ kind = 'prop', pos = { x = 0, y = 0, z = 0 }, model = 'w_pi_pistol' })), 'model',
        'a model-info provider answering false still refuses')
    eq(#stubs.failures, 0, 'nothing escaped')
end

--------------------------------------------------------------------------------
-- 3. client/remote.lua: no state-bag applier any more
--------------------------------------------------------------------------------

do
    section = 'client'
    stubs.newWorld()
    stubs.clear()
    stubs.resetNui()
    local env = stubs.newEnv('client', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, 'client/api.lua')
    local bagHandlers, threads = {}, 0
    env.AddStateBagChangeHandler = function(key) bagHandlers[#bagHandlers + 1] = tostring(key) return 0 end
    local realThread = env.CreateThread
    env.CreateThread = function(fn) threads = threads + 1 return realThread(fn) end
    local stopBefore = #(env.__vm.handlers.onClientResourceStop or {})
    stubs.loadFile(env, 'client/remote.lua')
    eq(#bagHandlers, 0, 'no state-bag change handler (the attachments applier is gone)')
    eq(threads, 0, 'no sweep thread')
    eq(#(env.__vm.handlers.onClientResourceStop or {}), stopBefore, 'no stop handler of its own')
    for _, name in ipairs({ 'core:client:native', 'core:client:anim', 'core:client:audio', 'core:client:waypoint' }) do
        check(env.__vm.netEvents[name] == true, name .. ' is still registered')
    end
    local code = stubs.readFile(stubs.root .. '/client/remote.lua') or ''
    check(not code:find('AddStateBagChangeHandler', 1, true), 'the file registers no state-bag handler')
    check(not code:find('CreateObject', 1, true), 'and creates no objects itself')
    eq(#stubs.failures, 0, 'nothing escaped')
end

print(('scene attach: %d passed, %d failed'):format(passed, failed))
for i = 1, #stubs.failures do print('  uncaught: ' .. stubs.failures[i]) end
if failed > 0 or #stubs.failures > 0 then os.exit(1) end
