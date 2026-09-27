--[[
    core/tests/scene_server_tests.lua — offline suite for the Core.Scene server (DESIGN §55.3, §55.4, §55.9 C2,
    §55.12, §55.14, §55.16 kinds, §55.18, §55.19 interact row).

        lua5.4 tests/scene_server_tests.lua    (from the resource directory, or from tests/)

    Kinds (built-ins, plugin kinds, owners, the KINDS table), every built-in kind's fields, the model-info chain,
    radius policies and tiers, spawn validation order and refusals, set / move / motion / attach / detach /
    remove, parents and dependencies, owner stop, persistence round trips, the interaction path (every refusal),
    C2 driving, emit / query / list / batch / stats, hooks, the motion lifecycle (far-future plans, settle,
    rebased persistence), a failed database read, core_db not started — and the exact R.index calls of each API call.
    Harness: tests/scene_server_harness.lua (recording fakes of R.index / R.interest / R.flush; the stored rows are
    read through the Postgres test bridge, DESIGN §56.10). Exit 1 on failure.
]]

local here = (arg and arg[0] or 'tests/scene_server_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local H = dofile(here .. '/scene_server_harness.lua')
local stubs, check, eq, near, callable, calls, trace, reset = H.stubs, H.check, H.eq, H.near, H.callable, H.calls,
    H.trace, H.reset
local newServer, as, stop = H.newServer, H.as, H.stop

local P0 = { x = 100, y = 200, z = 30 }
local ZERO = { x = 0, y = 0, z = 0 }
local function at(dx, dy, dz) return { x = P0.x + (dx or 0), y = P0.y + (dy or 0), z = P0.z + (dz or 0) } end
local function errOf(...) return select(2, ...) end
local function detailOf(...) return select(3, ...) end

--------------------------------------------------------------------------------
-- built-in kinds, the KINDS table, the public list
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local K, Scene = R.kinds, Core.Scene
    local expected = { prop = { 'prop', 'props' }, vehicle = { 'vehicle', 'vehicles' }, ped = { 'ped', 'peds' },
        light = { 'fx', 'lights' }, particle = { 'fx', 'particles' }, marker = { 'fx', 'markers' },
        text = { 'fx', 'texts' }, hide = { 'fx', 'hides' }, zone = { 'data', 'data' }, sound = { 'fx', 'sounds' },
        group = { 'data', 'data' }, ['audio.source'] = { 'audio', 'audio' }, audio = { 'audio', 'audio' } }
    local n = 0
    for id, cb in pairs(expected) do
        n = n + 1
        local k = K.get(id)
        check(k and k.class == cb[1] and k.budget == cb[2] and k.owner == 'core' and k.builtin and k.handler == 'core',
            'built-in ' .. id .. ' = ' .. cb[1] .. ' / ' .. cb[2])
    end
    eq(K.count(), n, 'thirteen built-in kinds')
    eq(K.get('audio.source').dependency, true, 'audio.source is a dependency kind')
    eq(K.get('audio').dependency, nil, 'audio emitters are not')
    local list = K.table(0)
    eq(#list, 13, 'KINDS: the full table has every kind')
    check(list[1].idx == 1 and list[13].idx == 13, 'indexes 1..13, ascending')
    local byId = {}
    for _, e in ipairs(list) do byId[e.id] = e end
    eq(byId.prop.class, 1, 'class codes come from Codec.CLASS (prop 1)')
    eq(byId.light.class, 4, 'fx = 4')
    eq(byId.prop.meta.budget, 'props', 'meta carries the budget')
    eq(byId.prop.meta.handler, 'core', 'meta carries the handler')
    eq(byId['audio.source'].meta.dep, true, 'meta flags dependency kinds')
    eq(#K.table(K.version()), 0, 'since = the current version: nothing newer')
    eq(#K.table(K.version() - 1), 1, 'since = version - 1 → the last defined kind only')
    local pub = Scene.kinds()
    eq(#pub, 13, 'Scene.kinds() lists them')
    local prop
    for _, k in ipairs(pub) do if k.id == 'prop' then prop = k end end
    eq(prop.fields[1].name, 'model', 'public fields keep their order')
    local fns = 0
    local function scan(v)
        for _, x in pairs(v) do
            if type(x) == 'function' then fns = fns + 1 elseif type(x) == 'table' then scan(x) end
        end
    end
    scan(pub)
    eq(fns, 0, 'no functions in the public list')
    pub[1].id = 'changed'
    check(Scene.kinds()[1].id ~= 'changed', 'every call is a fresh copy')
    local vf
    for _, k in ipairs(pub) do if k.id == 'vehicle' then vf = k end end
    local names = {}
    for _, f in ipairs(vf.fields) do names[f.name] = f.type end
    eq(names.props, 'table', 'free-form fields are listed as type table')
    check(R.store and R.store.get and R.store.pose and R.store.root and R.store.dependents and R.store.count,
        'R.store exposes get / pose / root / dependents / count')
    eq(R.storeInternal, nil, 'the private hand-off is taken and cleared by scene.lua')
end

--------------------------------------------------------------------------------
-- plugin kinds: ids, owners, redefinition, refusals, the KINDS delta, owner stop
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local K = R.kinds
    local def = { id = 'fireworks:battery', class = 'custom', handler = 'fireworks', radius = 300,
        fields = { { name = 'shots', type = 'integer', min = 1, max = 99, default = 10 },
            { name = 'label', type = 'string', maxLength = 32 }, { name = 'pattern', type = 'table' } },
        nearFields = { 'label' }, authority = { mode = 'local' } }
    eq(as('fireworks', 'defineKind', def), true, 'a plugin defines <resource>:<name>')
    local k = K.get('fireworks:battery')
    check(k and k.owner == 'fireworks' and k.idx == 14 and k.budget == 'custom' and k.nearFields.label, 'kind stored')
    eq(Core.Registry.getOwned('fireworks').sceneKind['fireworks:battery'], true, "tracked as Registry kind 'sceneKind'")
    local v1 = K.version()
    local refusals = {
        { 'fireworks', { id = 'battery', class = 'custom' }, 'id' },
        { 'fireworks', { id = 'other:battery', class = 'custom' }, 'id' },
        { 'fireworks', { id = 'prop', class = 'prop' }, 'id' },
        { 'other', { id = 'fireworks:battery', class = 'custom' }, 'id' },
        { 'fireworks', { id = 'fireworks:x', class = 'blob' }, 'class' },
        { 'fireworks', { id = 'fireworks:x', class = 'custom', fields = { { name = 'a', type = 'nope' } } },
            'fields:' },
        { 'fireworks', { id = 'fireworks:x', class = 'custom', fields = { { name = 'a', type = 'boolean' },
            { name = 'a', type = 'table' } } }, 'fields:duplicate' },
        { 'fireworks', { id = 'fireworks:x', class = 'custom', fields = { { name = '1a', type = 'table' } } },
            'fields:1' },
        { 'fireworks', { id = 'fireworks:x', class = 'custom', fields = { { name = 't', type = 'table',
            validate = 5 } } }, 'fields:t' },
        { 'fireworks', { id = 'fireworks:x', class = 'custom', nearFields = { 'missing' } }, 'nearFields' },
        { 'fireworks', { id = 'fireworks:x', class = 'custom', radius = 0 }, 'radius' },
        { 'fireworks', { id = 'fireworks:x', class = 'custom', handler = 'bad handler' }, 'handler' },
        { 'fireworks', { id = 'fireworks:x', class = 'custom', authority = { mode = 'teleport' } }, 'authority' },
        { 'fireworks', { id = 'fireworks:x', class = 'custom', budget = 'a b' }, 'budget' },
        { 'fireworks', 'nope', 'def' },
    }
    for i, r in ipairs(refusals) do
        local ok, err = as(r[1], 'defineKind', r[2])
        check(ok == false and type(err) == 'string' and err:sub(1, #r[3]) == r[3],
            ('defineKind refusal %d -> %s (got %s)'):format(i, r[3], tostring(err)))
    end
    eq(K.version(), v1, 'refusals change nothing')
    eq(errOf(as('other', 'defineKind', { id = 'other:x', class = 'custom' })), nil, 'another resource defines its own')
    eq(errOf(Core.Scene.defineKind({ id = 'fireworks:core_made', class = 'data' })), nil, 'core may define any prefix')
    eq(errOf(as('other', 'defineKind', { id = 'fireworks:core_made', class = 'data' })), 'id', 'a plugin may not')
    local ok, err = as('fireworks', 'defineKind', { id = 'fireworks:battery', class = 'custom', radius = 120 })
    check(ok == true and err == nil, 'the owner may redefine its kind')
    eq(K.get('fireworks:battery').idx, 14, 'a redefinition keeps the index')
    local delta = K.table(v1)
    local ids = {}
    for _, e in ipairs(delta) do ids[e.id] = e end
    check(ids['fireworks:battery'] and ids['other:x'] and ids['fireworks:core_made'],
        'KINDS delta since v1 lists the changes')
    local v2 = K.version()
    stop(env, 'fireworks')
    eq(K.get('fireworks:battery'), nil, 'owner stop removes its kind')
    check(K.get('fireworks:core_made') ~= nil, "core's kind with that prefix stays")
    local d = K.table(v2)
    eq(#d, 1, 'the delta after the stop has one entry')
    check(d[1].idx == 14 and d[1].id == '' and d[1].class == 0, 'a removed kind travels as { idx, id = "" }')
    eq(as('fireworks', 'defineKind', def), true, 'defined again after a restart')
    eq(K.get('fireworks:battery').idx, 14, 'the same id gets its old index back')
    eq(K.byIdx(14).id, 'fireworks:battery', 'byIdx finds it')
    eq(#K.undefineOwner('fireworks'), 1, 'undefineOwner removes and lists the owner kinds')
    eq(K.undefine('prop'), false, 'built-ins cannot be removed')
end

--------------------------------------------------------------------------------
-- built-in kind fields (§55.12): valid, invalid, defaults
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local K, Scene = R.kinds, Core.Scene
    local function ok(kind, fields, label)
        local good, out = K.check(K.get(kind), fields, false)
        local k, v = next(out or {})
        check(good, label .. (good and '' or (' → ' .. tostring(k) .. '=' .. tostring(v))))
        return good and out or {}
    end
    local function bad(kind, fields, name, code, label)
        local good, errs = K.check(K.get(kind), fields, false)
        local got = type(errs) == 'table' and errs[name]
        check(not good and type(got) == 'string' and got:sub(1, #code) == code,
            ('%s → %s = %s (got %s)'):format(label, name, code, tostring(got)))
    end
    local prop = ok('prop', { model = 'prop_bench_01a' }, 'prop: a model is enough')
    check(prop.frozen == true and prop.collision == true and prop.invincible == false and prop.visible == true
        and prop.physics == 'static', 'prop defaults: frozen, collision, not invincible, visible, static')
    bad('prop', {}, 'model', 'required', 'prop without a model')
    bad('prop', { model = 'bad model!' }, 'model', 'pattern', 'prop model pattern')
    bad('prop', { model = 'm', tint = 16 }, 'tint', 'max', 'prop tint 0..15')
    bad('prop', { model = 'm', physics = 'ragdoll' }, 'physics', 'option', 'prop physics enum')
    local anim = ok('prop', { model = 'm', anim = { dict = 'amb@world_human@base', clip = 'base' } }, 'prop anim').anim
    check(anim.loop == true and anim.rate == 1, 'prop anim defaults: loop, rate 1')
    bad('prop', { model = 'm', anim = { clip = 'x' } }, 'anim', 'dict.required', 'prop anim needs a dict')
    bad('prop', { model = 'm', anim = { dict = 'd', clip = 'c', speed = 2 } }, 'anim', 'speed.unknown',
        'prop anim keys')
    ok('prop', { model = 'm', room = { interior = 1234, key = -99 } }, 'prop room { interior, key }')
    bad('prop', { model = 'm', room = { key = 1 } }, 'room', 'interior.required', 'prop room needs an interior')
    bad('prop', { model = 'm', lodDist = 5 }, 'lodDist', 'unknown', 'prop unknown field')
    local served = ok('prop', { model = 'm', lod = 999, r = 50 }, 'prop: server-filled lod / r are ignored on input')
    check(served.lod == nil and served.r == nil, 'the check drops them (the model-info chain fills them)')

    local veh = ok('vehicle', { model = 'adder', props = { plate = 'AB 12', colors = { [0] = 1, [1] = 2 } },
        doors = { ['0'] = 1, [4] = 0.5 } }, 'vehicle with props and doors')
    check(veh.locked == false and veh.engine == false and veh.siren == false and veh.frozen == true
        and veh.invincible == false, 'vehicle defaults')
    check(veh.doors[0] == 1 and veh.doors[4] == 0.5, 'door keys become integers (a JSON round trip)')
    bad('vehicle', { model = 'adder', doors = { [9] = 1 } }, 'doors', 'type', 'vehicle door 0..7')
    bad('vehicle', { model = 'adder', doors = { [1] = 2 } }, 'doors', 'type', 'vehicle door ratio 0..1')
    bad('vehicle', { model = 'adder', props = { [1] = 'x' } }, 'props', 'custom:props',
        'vehicle props keys are strings')
    bad('vehicle', { model = 'adder', props = { plate = string.rep('x', 40) } }, 'props', 'custom:props',
        'props strings <= 32')
    bad('vehicle', { model = 'adder', plate = 'TOO-LONG-PLATE' }, 'plate', 'length', 'plate <= 8')
    bad('vehicle', { model = 'adder', lights = 3 }, 'lights', 'max', 'lights 0..2')
    bad('vehicle', { model = 'adder', dirt = 16 }, 'dirt', 'max', 'dirt 0..15')
    bad('vehicle', { model = 'adder', props = { fn = print } }, 'props', 'type', 'props must be plain data')

    local ped = ok('ped', { model = 'a_m_y_skater_01', appearance = { hair = 3 }, weapon = 'weapon_pistol',
        anim = { dict = 'd', clip = 'c', flag = 49 } }, 'ped with appearance, weapon and anim')
    check(ped.invincible == true and ped.frozen == true and ped.blockEvents == true, 'ped defaults')
    bad('ped', { model = 'p', scenario = 'WORLD HUMAN' }, 'scenario', 'pattern', 'ped scenario pattern')
    bad('ped', { model = 'p', health = -1 }, 'health', 'min', 'ped health >= 0')
    bad('ped', { model = 'p', appearance = string.rep('x', 9000) }, 'appearance', 'size',
        'table fields <= MaxFieldBytes')

    local light = ok('light', {}, 'light: all defaults')
    check(light.type == 'point' and light.color == '#FFFFFF' and light.intensity == 1 and light.range == 10
        and light.shadow == false and light.flicker == 'none', 'light defaults')
    ok('light', { type = 'spot', dir = { x = 0, y = 0, z = -1 }, inner = 10, outer = 30, flicker = 'candle',
        seed = 7 }, 'a spot light')
    bad('light', { range = 0 }, 'range', 'min', 'light range 0.1..100')
    bad('light', { intensity = 101 }, 'intensity', 'max', 'light intensity 0..100')
    bad('light', { flicker = 'disco' }, 'flicker', 'option', 'light flicker enum')
    bad('light', { color = 'red' }, 'color', 'pattern', 'light colour #RRGGBB')

    local fx = ok('particle', { asset = 'core', name = 'ent_amb_smoke_foundry' }, 'particle')
    check(fx.scale == 1 and fx.alpha == 1 and fx.drawDistance == 150, 'particle defaults')
    bad('particle', { asset = 'core' }, 'name', 'required', 'particle name required')
    bad('particle', { asset = 'core', name = 'x', alpha = 2 }, 'alpha', 'max', 'particle alpha 0..1')

    local marker = ok('marker', {}, 'marker: all defaults')
    check(marker.type == 1 and marker.scale.x == 1 and marker.drawDistance == 50 and marker.bob == false,
        'marker defaults')
    bad('marker', { type = 44 }, 'type', 'max', 'marker type 0..43')
    ok('marker', { color = '#FF000080' }, 'marker colour with alpha')

    local text = ok('text', { text = 'Hello' }, 'text')
    check(text.drawDistance == 25 and text.outline == true and text.font == 4, 'text defaults')
    bad('text', {}, 'text', 'required', 'text required')
    bad('text', { text = string.rep('a', 129) }, 'text', 'length', 'text <= 128')

    ok('hide', { model = 'prop_bin_01a', radius = 3 }, 'hide')
    eq(ok('hide', { model = 'x' }, 'hide default radius').radius, 2, 'hide radius defaults to 2')
    bad('hide', { model = 'x', radius = 60 }, 'radius', 'max', 'hide radius 0.5..50')

    local zone = ok('zone', { shape = { type = 'sphere', coords = stubs.vector3(1, 2, 3), radius = 4 } }, 'zone sphere')
    check(getmetatable(zone.shape.coords) == nil and zone.shape.coords.x == 1,
        'shape vectors are stored as plain tables')
    eq(zone.events, true, 'zone events default on')
    bad('zone', { shape = { type = 'blob' } }, 'shape', 'custom:type', 'zone shape must normalise')
    bad('zone', {}, 'shape', 'required', 'zone shape required')

    local sound = ok('sound', { name = 'Beep_Red', set = 'DLC_HEIST_HACKING_SNAKE_SOUNDS' }, 'sound')
    check(sound.looped == true and sound.range == 30, 'sound defaults')
    bad('sound', { name = 'x', range = 0 }, 'range', 'min', 'sound range 1..500')

    ok('group', {}, 'group has no fields')
    bad('group', { x = 1 }, 'x', 'unknown', 'group refuses any field')

    local src = ok('audio.source', { file = '@radio/music/a.ogg' }, 'audio.source: a file clip')
    check(src.type == 'clip' and src.rate == 1 and src.volume == 1 and src.category == 'sfx' and src.paused == false,
        'audio.source defaults')
    check(math.type(src.t0) == 'integer' and R.diff(src.t0, R.now()) == 200,
        'audio.source t0 defaults to Clock.at(200)')
    bad('audio.source', { url = 'https://radio.example/stream.mp3' }, 'url', 'unavailable',
        'no remote URL without scene_audio')
    bad('audio.source', { url = 'http://x/a.mp3' }, 'url', 'pattern', 'http:// is refused')
    bad('audio.source', { file = '@a/b.ogg', url = 'https://x/y' }, 'url', 'source', 'exactly one of url / file')
    bad('audio.source', { type = 'timeline' }, 'items', 'required', 'a timeline needs items')
    ok('audio.source', { type = 'timeline', items = { { file = '@a/1.ogg', duration = 1000 },
        { file = '@a/2.ogg' } } }, 'timeline of files')
    bad('audio.source', { type = 'voice', file = '@a/b.ogg' }, 'type', 'voice', 'a voice source has no media')
    bad('audio.source', { type = 'stream', file = '@a/b.ogg' }, 'url', 'source', 'a stream needs a url')
    bad('audio.source', { file = '@a/b.ogg', volume = 3 }, 'volume', 'max', 'volume 0..2')
    R.audio = { check = function(f)
        if f.url and f.url:find('bad') then return false, 'host', 'url' end
        local out = {}
        for k, v in pairs(f) do out[k] = v end
        if out.url then out.resolved = { url = out.url, codec = 'mp3', kind = 'mp3' } end
        return true, out
    end }
    local remote = ok('audio.source', { type = 'stream', url = 'https://radio.example/live' },
        'R.audio.check accepts a URL')
    eq(remote.resolved and remote.resolved.codec, 'mp3', 'the resolved stream info is filled by R.audio')
    bad('audio.source', { url = 'https://bad.example/a' }, 'url', 'host',
        'R.audio.check refusals surface as field errors')
    R.audio = nil

    local em = ok('audio', { source = 5 }, 'audio emitter')
    check(em.range == 40 and em.volume == 1 and em.curve == 'game' and em.ref == 2 and em.priority == 3
        and em.occlusion == true, 'emitter defaults')
    bad('audio', {}, 'source', 'required', 'emitter needs a source')
    bad('audio', { source = 1, range = 601 }, 'range', 'max', 'emitter range 1..600')
    bad('audio', { source = 1, curve = 'log' }, 'curve', 'option', 'emitter curve enum')
    ok('audio', { source = 1, cone = { inner = 30, outer = 90 } }, 'emitter cone')
    check(not K.check(K.get('prop'), 'nope', false), 'non-table fields are refused')
    local partial = select(2, K.check(K.get('light'), { range = 5 }, true))
    check(partial.range == 5 and partial.color == nil, 'partial checks fill no defaults')
    check(Scene.spawn({ kind = 'prop', pos = P0, fields = { model = 'm', big = string.rep('x', 9000) } }) == nil,
        'spawn refuses oversized / unknown fields')
end

--------------------------------------------------------------------------------
-- the model-info chain (§55.12): provider → Maps validator (lazy) → defaults; cache; owners
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer({ maps = true })
    local K, Scene = R.kinds, Core.Scene
    local info = K.modelInfo('prop', 'prop_bench_01a')
    check(info.lod == 100 and info.r == 2 and info.vtype == nil,
        'no provider, no validator: prop defaults lod 100, r 2')
    eq(K.modelInfo('vehicle', 'adder').vtype, 'automobile', 'vehicle default vtype automobile')
    check(K.modelInfo('weapon', 'x') == nil and K.modelInfo('prop', '') == nil, 'only prop / vehicle / ped models')
    local maps = {}
    Core.MapsRuntime.setModelValidator(function(kind, model)
        maps[#maps + 1] = kind .. ':' .. model
        if model == 'nope' then return false end
        return true, { lod = 300, vehicleType = kind == 'vehicle' and 'bike' or nil }
    end)
    eq(K.modelInfo('prop', 'm1').lod, 300, 'the Maps validator (lazily) gives the lod')
    eq(K.modelInfo('vehicle', 'bati').vtype, 'bike', 'and the vehicle type')
    local nope = K.modelInfo('prop', 'nope')
    check(nope and nope.lod == 100 and nope.r == 2,
        'a model the Maps validator refuses is NOT refused by Scene: it gets the defaults (an info source only)')
    eq(K.modelInfo('vehicle', 'nope').vtype, 'automobile', '... a vehicle the default vtype')
    check(K.modelInfo('prop', '0xC2161726') ~= nil, "a '0x%08X' hash string (server/remote.lua) passes")
    local calls0 = 0
    local answers = { big = { lod = 1200, radius = 12 }, boxed = { bbox = { min = { x = -1, y = -2, z = -2 },
        max = { x = 1, y = 2, z = 2 } } },
        refused = false, veh = { vehicleType = 'heli' } }
    eq(as('models', 'setModelInfo', function(kind, model)
        calls0 = calls0 + 1
        if model == 'boom' then error('provider bug') end
        return answers[model]
    end), true, 'a plugin installs the model-info provider')
    eq(Core.Registry.getOwned('models').sceneModelInfo.provider, true, "tracked as Registry kind 'sceneModelInfo'")
    local big = K.modelInfo('prop', 'big')
    check(big.lod == 1200 and big.r == 12, 'the provider wins: lod and radius')
    K.modelInfo('prop', 'big')
    eq(calls0, 1, 'provider answers are cached per <class>:<model>')
    near(K.modelInfo('prop', 'boxed').r, 3, 1e-9, 'a bbox gives the bounding radius (half diagonal)')
    eq(errOf(K.modelInfo('prop', 'refused')), 'model', 'false from the provider refuses the model')
    eq(K.modelInfo('vehicle', 'veh').vtype, 'heli', 'the provider gives the vehicle type')
    eq(K.modelInfo('prop', 'm2').lod, 300, 'nil from the provider falls through to the Maps validator')
    eq(K.modelInfo('prop', 'boom').lod, 300, 'a failing provider falls through too')
    local c = calls0
    K.modelInfo('prop', 'm2')
    eq(calls0, c, 'a nil answer is cached as well')
    eq(as('other', 'setModelInfo', nil), false, 'only its owner (or core) clears the provider')
    eq(as('other', 'setModelInfo', 5), false, 'a provider must be callable')
    stop(env, 'models')
    eq(K.modelInfo('prop', 'big').lod, 300, 'owner stop removes the provider (and its cache)')
    Scene.setModelInfo(callable(function(kind) if kind == 'prop' then return { lod = 40 } end end))
    eq(K.modelInfo('prop', 'big').lod, 40, 'a callable table (export hop) works; the cache was cleared')
    local id = Scene.spawn({ kind = 'prop', pos = P0, model = 'big' })
    local n = Scene.get(id)
    check(n.fields.lod == 40 and n.fields.r == 2, 'spawn fills lod / r from the chain')
    eq(n.radius, 150, 'prop radius = lod × 1.75 + 80')
    eq(n.tier, 'S', 'and its tier')
    local nv = Scene.spawn({ kind = 'vehicle', pos = P0, model = 'nope' })
    eq(nv and Scene.get(nv).fields.vtype, 'automobile',
        'spawn takes a model the Maps validator refuses (addon / streamed models, weapon objects)')
    Scene.setModelInfo(callable(function(_, model) if model == 'nope' then return false end end))
    eq(errOf(Scene.spawn({ kind = 'vehicle', pos = P0, model = 'nope' })), 'model',
        'only a provider answering false refuses a model')
    Scene.setModelInfo(callable(function(kind) if kind == 'prop' then return { lod = 40 } end end))
    local vid = Scene.spawn({ kind = 'vehicle', pos = P0, model = 'bati' })
    eq(Scene.get(vid).fields.vtype, 'bike', 'vehicles get vtype')
end

--------------------------------------------------------------------------------
-- radius policies (§55.11 / §55.12) and tiers
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local K, Scene = R.kinds, Core.Scene
    local lods = {}
    Scene.setModelInfo(function(_, model) return lods[model] and { lod = lods[model] } or nil end)
    local function spawned(def)
        local id, err = Scene.spawn(def)
        check(id ~= nil, 'spawn ' .. tostring(def.kind) .. ' (' .. tostring(err) .. ')')
        return Scene.get(id) or {}
    end
    local cases = {
        { { kind = 'prop', pos = P0, model = 'p100' }, 255, 'M', 'prop lod 100 → 255' },
        { { kind = 'vehicle', pos = P0, model = 'adder' }, 330, 'M', 'vehicle → 330' },
        { { kind = 'ped', pos = P0, model = 'a_m_y_skater_01' }, 150, 'S', 'ped → 150' },
        { { kind = 'light', pos = P0, fields = { range = 20 } }, 140, 'S', 'light min(range × 3 + 80, 330)' },
        { { kind = 'light', pos = P0, fields = { range = 100 } }, 330, 'M', 'light capped at 330' },
        { { kind = 'particle', pos = P0, fields = { asset = 'core', name = 'x' } }, 180, 'M',
            'particle drawDistance + 30' },
        { { kind = 'marker', pos = P0 }, 80, 'S', 'marker 50 + 30' },
        { { kind = 'text', pos = P0, fields = { text = 'x' } }, 55, 'S', 'text 25 + 30' },
        { { kind = 'hide', pos = P0, fields = { model = 'x', radius = 5 } }, 205, 'M', 'hide radius + 200' },
        { { kind = 'sound', pos = P0, fields = { name = 'x' } }, 70, 'S', 'sound range + 40' },
        { { kind = 'group', pos = P0 }, 250, 'M', 'group: the default 250' },
        { { kind = 'prop', pos = P0, model = 'p100', radius = 1400 }, 1400, 'L', 'an explicit radius wins → tier L' },
        { { kind = 'prop', pos = P0, model = 'p100', global = true, radius = 3000 }, 3000, 'G', 'global → tier G' },
    }
    for _, cs in ipairs(cases) do
        local n = spawned(cs[1])
        eq(n.radius, cs[2], cs[4])
        eq(n.tier, cs[3], cs[4] .. ': tier')
    end
    lods.huge = 5000
    local n = spawned({ kind = 'prop', pos = P0, model = 'huge' })
    check(n.radius == 1500 and n.tier == 'L', 'computed radii are capped at TierL (1500)')
    local zone = spawned({ kind = 'zone', pos = P0, fields = { shape = { type = 'sphere', coords = at(30, 40, 0),
        radius = 10 } } })
    eq(zone.radius, 50 + 10 + 40, 'zone: distance to the shape + its bounding radius + 40')
    local zc = spawned({ kind = 'zone', parent = zone.id, offset = { x = 30, y = 40, z = 0 },
        fields = { shape = { type = 'sphere', coords = at(30, 40, 0), radius = 10 } } })
    eq(zc.radius, 50, "a child's radius is computed at its world pose (shape centred on it: 10 + 40)")
    local src = Scene.spawn({ kind = 'audio.source', fields = { file = '@a/b.ogg' } })
    local em = spawned({ kind = 'audio', pos = P0, fields = { source = src, range = 300 } })
    check(em.radius == 340 and em.tier == 'M', 'audio emitter: range + 40')
    local srcNode = Scene.get(src)
    check(srcNode.tier == nil, 'a dependency node has no tier')
    Scene.defineKind({ id = 'core:fixed', class = 'custom', radius = 90 })
    Scene.defineKind({ id = 'core:fn', class = 'custom', radius = callable(function(node) return node.fields.r * 2 end),
        fields = { { name = 'r', type = 'number' } } })
    Scene.defineKind({ id = 'core:plugprop', class = 'prop', fields = { { name = 'model', type = 'model',
        required = true } } })
    Scene.defineKind({ id = 'core:plain', class = 'custom' })
    eq(spawned({ kind = 'core:fixed', pos = P0 }).radius, 90, 'custom kind: its number radius')
    eq(spawned({ kind = 'core:fn', pos = P0, fields = { r = 60 } }).radius, 120, 'custom kind: fn(nodeCopy)')
    local pp = spawned({ kind = 'core:plugprop', pos = P0, model = 'p100' })
    check(pp.radius == 255 and pp.fields.lod == 100, 'a plugin prop kind gets the prop policy and model info')
    eq(spawned({ kind = 'core:plain', pos = P0 }).radius, 250, 'custom kinds default to 250')
    check(K.tier(160, false) == 'S' and K.tier(160.5, false) == 'M' and K.tier(448, false) == 'M'
        and K.tier(449, false) == 'L' and K.tier(10, true) == 'G', 'tier boundaries 160 / 448 / global')
    eq(errOf(Scene.spawn({ kind = 'prop', pos = P0, model = 'x', radius = 1501 })), 'radius',
        'explicit radius > TierL needs global')
    eq(errOf(Scene.spawn({ kind = 'prop', pos = P0, model = 'x', radius = 0 })), 'radius', 'radius >= 1')
end

--------------------------------------------------------------------------------
-- spawn: validation order (§55.4), refusals, limits, the hook, the node record
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Scene = Core.Scene
    local function refuse(def, want, label)
        local id, err = Scene.spawn(def)
        check(id == nil and err == want, ('%s → %s (got %s)'):format(label, want, tostring(err)))
    end
    refuse('prop', 'def', 'a non-table def')
    refuse({ kind = 'nope', pos = P0 }, 'kind', 'an unknown kind')
    refuse({ kind = 'prop', pos = { x = 1e6, y = 0, z = 0 }, fields = { tint = 99 } }, 'fields',
        'fields before the pose')
    refuse({ kind = 'prop', model = 'm', pos = { x = 10001, y = 0, z = 0 }, rot = 'x' }, 'pos', 'pose before rotation')
    refuse({ kind = 'prop', model = 'm', pos = { x = 0, y = -10001, z = 0 } }, 'pos', 'y inside ±10000')
    refuse({ kind = 'prop', model = 'm', pos = { x = 0, y = 0, z = -1001 } }, 'pos', 'z >= -1000')
    refuse({ kind = 'prop', model = 'm', pos = { x = 0, y = 0, z = 3001 } }, 'pos', 'z <= 3000')
    refuse({ kind = 'prop', model = 'm', pos = { x = 0 / 0, y = 0, z = 0 } }, 'pos', 'NaN')
    refuse({ kind = 'prop', model = 'm' }, 'pos', 'a root needs a pos')
    refuse({ kind = 'prop', model = 'm', pos = P0, rot = { x = math.huge, y = 0, z = 0 } }, 'rot', 'a finite rotation')
    refuse({ kind = 'prop', model = 'm', pos = P0, motion = { t = 'warp' } }, 'motion', 'an invalid motion')
    Scene.setModelInfo(function(_, model) if model == 'nope' then return false end end)
    refuse({ kind = 'prop', model = 'nope', pos = P0, parent = 999 }, 'model', 'the model before the parent')
    refuse({ kind = 'prop', model = 'm', parent = 999 }, 'parent', 'a missing parent')
    refuse({ kind = 'prop', model = 'm', pos = P0, audience = { players = {} }, interact = 5 }, 'audience',
        'audience before interact')
    refuse({ kind = 'prop', model = 'm', pos = P0, interact = { { action = 'bad action' } } }, 'interact',
        'interact action pattern')
    refuse({ kind = 'prop', model = 'm', pos = P0, authority = { mode = 'x' } }, 'authority', 'authority shape')
    refuse({ kind = 'prop', model = 'm', pos = P0, persist = 'yes' }, 'persist', 'persist is a boolean')
    refuse({ kind = 'prop', model = 'm', pos = P0, global = 1 }, 'global', 'global is a boolean')
    refuse({ kind = 'prop', model = 'm', pos = P0, bucket = -1 }, 'bucket', 'bucket >= 0')
    local detail = detailOf(Scene.spawn({ kind = 'light', pos = P0, fields = { range = 0, shadow = 1 } }))
    check(detail and detail.range == 'min' and detail.shadow == 'type', 'field errors come back as the Schema map')
    local okAud = { { players = { 1, 2 } }, { faction = 'police' }, { perm = 'core.admin' }, { editors = true },
        { near = 50 },
        { fn = callable(function() return true end) }, { any = { { faction = 'police' }, { all = { { perm = 'x' },
            { near = 5 } } } } } }
    for i, a in ipairs(okAud) do check(Scene.spawn({ kind = 'marker', pos = P0, audience = a }) ~= nil,
        'audience shape ' .. i) end
    local many = {}
    for i = 1, 257 do many[i] = i end
    local badAud = { { players = many }, { players = { 0 } }, { players = { 1, 1 } }, { faction = 'police',
        perm = 'x' },
        { near = 201 }, { near = 0 }, { editors = false }, { fn = 5 }, { any = {} }, { unknown = 1 },
        { all = { { any = { { all = { { any = { { near = 1 } } } } } } } } } }
    for i, a in ipairs(badAud) do eq(errOf(Scene.spawn({ kind = 'marker', pos = P0, audience = a })), 'audience',
        'bad audience ' .. i) end
    eq(errOf(Scene.spawn({ kind = 'marker', pos = P0, persist = true, audience = { fn = print } })), 'audience',
        'fn audiences are refused for persistent nodes')
    eq(errOf(Scene.spawn({ kind = 'marker', pos = P0, persist = true,
        audience = { any = { { near = 5 }, { fn = print } } } })), 'audience', '… anywhere in the tree')
    local function interact(list) return errOf(Scene.spawn({ kind = 'marker', pos = P0, interact = list })) end
    eq(interact({ { action = 'use' }, { action = 'b' }, { action = 'c' }, { action = 'd' }, { action = 'e' } }),
        'interact', '<= 4 descriptors')
    eq(interact({ { action = 'use' }, { action = 'use' } }), 'interact', 'unique actions')
    eq(interact({ { action = string.rep('a', 33) } }), 'interact', 'action <= 32')
    eq(interact({ { action = 'use', distance = 0.4 } }), 'interact', 'distance >= 0.5')
    eq(interact({ { action = 'use', distance = 21 } }), 'interact', 'distance <= 20')
    eq(interact({ { action = 'use', colour = 'x' } }), 'interact', 'unknown descriptor keys')
    eq(interact({ { action = 'use', data = string.rep('x', 1100) } }), 'interact', 'data <= 1 KiB')
    eq(interact({ { action = 'use', perm = 'bad perm' } }), 'interact', 'perm pattern')
    local iid = Scene.spawn({ kind = 'marker', pos = P0, interact = { { action = 'use', data = { a = 1 } } } })
    local d = Scene.get(iid).interact[1]
    check(d.label == 'use' and d.distance == 2 and d.cooldownMs == 500 and d.data.a == 1,
        'descriptor defaults: label, 2 m, 500 ms')
    -- the hook (fail-closed veto), data-only payload
    local seen
    local hook = Core.Hooks.register('scene:beforeSpawn', function(p)
        seen = p
        if p.fields.text == 'veto' then return false, 'no thanks' end
        return true
    end)
    local id, err, reason = Scene.spawn({ kind = 'text', pos = P0, fields = { text = 'veto' } })
    check(id == nil and err == 'hook' and reason == 'no thanks', 'scene:beforeSpawn vetoes with its reason')
    check(seen and seen.kind == 'text' and seen.owner == 'core' and seen.pos.x == P0.x and seen.bucket == 0,
        'the hook sees kind, owner, pos, bucket')
    Scene.spawn({ kind = 'marker', pos = P0, audience = { fn = print } })
    eq(seen.audience.fn, true, 'the hook payload is data only (fn → true)')
    Core.Hooks.remove(hook)
    -- a clean spawn: the record, the index call, ownership
    reset()
    local nid = as('shop', 'spawn', { kind = 'prop', pos = at(1, 2, 3), rot = { x = 0, y = 0, z = 270 }, model = 'm',
        bucket = 4, fields = { tint = 3 } })
    local n = Scene.get(nid)
    check(n.kind == 'prop' and n.owner == 'shop' and n.bucket == 4 and n.fields.tint == 3 and n.persist == false
        and n.global == false, 'the node record (kind, owner, bucket, fields, persist, global)')
    eq(n.rot.z, -90, 'rotations are normalised to (-180, 180]')
    eq(trace(), 'put:' .. nid, 'spawn → exactly one R.index.put')
    eq(calls('put')[1].tier, 'M', 'put with the tier set')
    eq(Core.Registry.getOwned('shop').sceneNode[nid], true, "non-persistent nodes are tracked ('sceneNode')")
    n.fields.tint = 9
    eq(Scene.get(nid).fields.tint, 3, 'Scene.get answers a detached copy')
    eq(n.k, nil, 'copies carry no kind table')
    local a, b = Scene.spawn({ kind = 'marker', pos = P0 }), Scene.spawn({ kind = 'marker', pos = P0 })
    check(b == a + 1, 'ids come from one counter')
    check(Scene.get(a).ver == 1 and Scene.get(b).ver == 1, 'ver is per node: a new node starts at 1')
    eq(Scene.get(Scene.spawn({ kind = 'prop', pos = P0, model = 'm', fields = { model = 'n' } })).fields.model, 'n',
        'fields.model wins over the model shorthand')
    eq(Scene.get(12345), nil, 'Scene.get of an unknown id is nil')
end

do
    local _, Core = newServer({ config = function(Config)
        Config.Scene.MaxNodesPerOwner, Config.Scene.Global.MaxNodes, Config.Scene.MaxPersistent = 6, 2, 3
        Config.Scene.CoreReserve = nil                    -- core's reserve has its own section (FX2)
    end })
    local Scene = Core.Scene
    -- limits (MaxNodesPerOwner 6, Global.MaxNodes 2, MaxPersistent 3 in this VM)
    for i = 1, 3 do check(as('lim', 'spawn', { kind = 'marker', pos = P0, global = i <= 2, persist = i == 3 }) ~= nil,
        'limit fill ' .. i) end
    eq(errOf(as('lim', 'spawn', { kind = 'marker', pos = P0, global = true })), 'limit', 'Global.MaxNodes')
    check(as('lim2', 'spawn', { kind = 'marker', pos = P0, persist = true }) and as('lim2', 'spawn',
        { kind = 'marker', pos = P0, persist = true }),
        'persistent nodes up to MaxPersistent')
    eq(errOf(as('lim2', 'spawn', { kind = 'marker', pos = P0, persist = true })), 'limit', 'MaxPersistent')
    for _ = 1, 3 do as('lim', 'spawn', { kind = 'marker', pos = P0 }) end
    eq(errOf(as('lim', 'spawn', { kind = 'marker', pos = P0 })), 'limit', 'MaxNodesPerOwner')
    check(as('lim3', 'spawn', { kind = 'marker', pos = P0 }) ~= nil, 'another owner still spawns')
    Core.Scene.remove(Scene.list({ owner = 'lim3' })[1])
    check(as('lim', 'spawn', { kind = 'marker', pos = P0 }) == nil, 'a removal of another owner frees nothing for lim')
end

--------------------------------------------------------------------------------
-- Scene.set: merge + whole check, removals, no-ops, owners, interact / audience / radius, index calls
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Scene = Core.Scene
    local lods = { small = 20, big = 400 }
    Scene.setModelInfo(function(_, model) return lods[model] and { lod = lods[model], radius = 1 } or nil end)
    local id = as('shop', 'spawn', { kind = 'light', pos = P0, fields = { range = 20, seed = 5 } })
    local ver = Scene.get(id).ver
    reset()
    eq(as('shop', 'set', id, { intensity = 5, color = '#FF0000' }), true, 'the owner sets fields')
    local n = Scene.get(id)
    check(n.fields.intensity == 5 and n.fields.color == '#FF0000' and n.fields.range == 20, 'the patch merges')
    check(n.ver > ver, 'ver bumps')
    eq(trace(), 'changed:' .. id .. ':set', 'a field change → changed(set)')
    local patch = calls('changed')[1].data
    check(patch.f.intensity == 5 and patch.f.color == '#FF0000' and patch.f.range == nil and patch.x == nil,
        'the SET patch carries only the changed fields')
    reset()
    eq(as('shop', 'set', id, { intensity = 5 }), true, 'a no-op set succeeds')
    eq(trace(), '', '… and costs no index call')
    eq(Scene.get(id).ver, n.ver, '… and no ver')
    eq(errOf(as('other', 'set', id, { intensity = 1 })), 'owner', 'another resource may not set')
    eq(Scene.set(id, { intensity = 2 }), true, 'core may')
    eq(errOf(Scene.set(999, {})), 'missing', 'unknown id')
    eq(errOf(Scene.set(id, 'x')), 'def', 'a non-table patch')
    local _, err, errs = Scene.set(id, { range = 0, bogus = 1 })
    check(err == 'fields' and errs.range == 'min' and errs.bogus == 'unknown', 'a bad patch → fields + the Schema map')
    eq(Scene.get(id).fields.range, 20, 'a refused set changes nothing')
    reset()
    eq(Scene.set(id, nil, { remove = { 'seed' } }), true, 'opts.remove deletes an optional field')
    eq(Scene.get(id).fields.seed, nil, 'seed is gone')
    local p2 = calls('changed')[1].data
    check(p2.x and p2.x[1] == 'seed' and next(p2.f) == nil, 'the SET patch lists removed names in x')
    Scene.set(id, nil, { remove = { 'intensity' } })
    eq(Scene.get(id).fields.intensity, 1, 'removing a field with a default resets it to the default')
    local tid = Scene.spawn({ kind = 'text', pos = P0, fields = { text = 'a' } })
    eq(errOf(Scene.set(tid, nil, { remove = { 'text' } })), 'fields', 'a required field cannot be removed')
    -- model changes re-run the model-info chain; the radius / tier follow
    local pid = Scene.spawn({ kind = 'prop', pos = P0, model = 'small' })
    check(Scene.get(pid).radius == 115 and Scene.get(pid).tier == 'S', 'lod 20 → 115 m, tier S')
    reset()
    Scene.set(pid, { model = 'big' })
    local pn = Scene.get(pid)
    check(pn.fields.lod == 400 and pn.fields.r == 1 and pn.radius == 780 and pn.tier == 'L',
        'a new model: lod 400 → 780 m, tier L')
    eq(trace(), 'put:' .. pid, 'a tier change re-puts the node instead of a SET')
    reset()
    Scene.set(pid, { tint = 2, lod = 1, r = 99 })
    pn = Scene.get(pid)
    check(pn.fields.lod == 400 and pn.fields.r == 1 and pn.fields.tint == 2,
        'server-filled values survive a set (input ignored)')
    eq(trace(), 'changed:' .. pid .. ':set', 'same tier → SET')
    -- interact / audience / radius options
    reset()
    eq(Scene.set(pid, nil, { interact = { { action = 'sit', label = 'Sit' } } }), true,
        'opts.interact replaces the descriptors')
    eq(trace(), 'changed:' .. pid .. ':interact', '… → changed(interact)')
    eq(Scene.get(pid).interact[1].action, 'sit', 'stored')
    reset()
    Scene.set(pid, nil, { interact = { { action = 'sit', label = 'Sit' } } })
    eq(trace(), '', 'the same descriptors again: no call')
    Scene.set(pid, nil, { interact = false })
    eq(Scene.get(pid).interact, nil, 'interact = false clears them')
    eq(errOf(Scene.set(pid, nil, { interact = { { action = 'bad action' } } })), 'interact',
        'bad descriptors are refused')
    reset()
    eq(Scene.set(pid, nil, { audience = { faction = 'police' } }), true, 'opts.audience gates the node')
    eq(trace(), 'put:' .. pid, 'an audience change re-puts (the index re-gates it)')
    eq(Scene.get(pid).audience.faction, 'police', 'stored')
    Scene.set(pid, nil, { audience = false })
    eq(Scene.get(pid).audience, nil, 'audience = false makes it public again')
    eq(errOf(Scene.set(pid, nil, { audience = { near = 999 } })), 'audience', 'a bad audience is refused')
    reset()
    Scene.set(pid, nil, { radius = 60 })
    check(Scene.get(pid).radius == 60 and Scene.get(pid).tier == 'S', 'opts.radius sets an explicit radius')
    eq(trace(), 'put:' .. pid, 'a radius change re-puts')
    Scene.set(pid, nil, { radius = false })
    eq(Scene.get(pid).radius, 780, 'radius = false returns to the kind policy')
    eq(errOf(Scene.set(pid, nil, { radius = 5000 })), 'radius', 'an explicit radius > TierL is refused')
    reset()
    Scene.set(pid, { tint = 4 }, { interact = { { action = 'use' } } })
    eq(trace(), ('changed:%d:set changed:%d:interact'):format(pid, pid),
        'fields + interact in one call → SET then interact')
end

--------------------------------------------------------------------------------
-- move / motion (C3)
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local id = as('lift', 'spawn', { kind = 'prop', pos = P0, model = 'm' })
    reset()
    eq(as('lift', 'move', id, at(10, 0, 0), { x = 0, y = 0, z = 45 }), true, 'a teleport')
    local n = Scene.get(id)
    check(n.pos.x == P0.x + 10 and n.rot.z == 45, 'the base pose moved')
    eq(trace(), 'changed:' .. id .. ':move', '… → changed(move)')
    eq(errOf(as('other', 'move', id, P0)), 'owner', 'only the owner (or core) moves it')
    eq(errOf(Scene.move(id, { x = 0, y = 0, z = 5000 })), 'pos', 'a move outside the world is refused')
    eq(errOf(Scene.move(id, P0, 'r')), 'rot', 'a bad rotation is refused')
    reset()
    eq(Scene.motion(id, { t = 'spin', axis = 'z', dps = 90 }), true, 'a spin motion')
    local m = Scene.get(id).motion
    check(m.t == 'spin' and R.diff(m.t0, R.now()) == 200, 't0 defaults to Clock.at(PlanLeadMs = 200)')
    eq(trace(), 'changed:' .. id .. ':motion', '… → changed(motion)')
    stubs.tick(1200)
    local _, _, _, _, _, rz = store.pose(store.get(id), R.now())
    near(rz, 45 + 90, 1e-6, 'the server evaluates the spin (1 s × 90°/s on top of the base)')
    reset()
    Scene.move(id, at(20, 0, 0))
    eq(Scene.get(id).motion.t, 'spin', 'a teleport keeps a relative motion (spin / osc)')
    eq(trace(), 'changed:' .. id .. ':move', '… and sends only the MOVE')
    Scene.motion(id, { t = 'path', pts = { at(0, 0, 0), at(50, 0, 0) }, sp = 5 })
    reset()
    Scene.move(id, at(30, 0, 0))
    eq(Scene.get(id).motion, nil, 'a teleport ends an absolute motion (path / tween / orbit / keys)')
    eq(trace(), ('changed:%d:move changed:%d:motion'):format(id, id), '… MOVE then MOTION (static)')
    reset()
    local now = R.now()
    eq(Scene.move(id, at(30, 100, 0), { x = 0, y = 0, z = 10 }, { duration = 4000, ease = 'linear' }), true,
        'a tween move')
    n = Scene.get(id)
    check(n.motion.t == 'tween' and n.motion.d == 4000 and n.motion.e == 'linear', 'a tween descriptor (C3)')
    check(n.motion.from.y == P0.y and n.motion.to.y == P0.y + 100, 'from = the current pose, to = the target')
    check(n.pos.y == P0.y + 100, 'the base pose is the destination')
    eq(trace(), ('changed:%d:move changed:%d:motion'):format(id, id), '… MOVE + MOTION')
    stubs.tick(200 + 2000)
    local _, y = store.pose(store.get(id), R.diff(R.now(), now) >= 0 and R.now() or now)
    near(y, P0.y + 50, 0.5, 'half way through the tween at t0 + 2 s')
    eq(errOf(Scene.move(id, P0, nil, { duration = 0 })), 'duration', 'duration 1..600000')
    eq(errOf(Scene.move(id, P0, nil, { duration = 10, ease = 'bounce' })), 'ease', 'ease enum')
    eq(errOf(Scene.motion(id, { t = 'spin', dps = 1e9 })), 'motion', 'Motion.validate refuses bad descriptors')
    reset()
    eq(Scene.motion(id, nil), true, 'nil clears the motion')
    eq(Scene.get(id).motion, nil, 'static again')
    eq(Scene.motion(id, nil), true, 'clearing twice is a no-op')
    eq(trace(), 'changed:' .. id .. ':motion', '… with one MOTION op only')
    local src = Scene.spawn({ kind = 'audio.source', fields = { file = '@a/b.ogg' } })
    eq(errOf(Scene.move(src, P0)), 'dependency', 'a dependency node has no pose')
    eq(errOf(Scene.motion(src, { t = 'spin', dps = 1 })), 'dependency', '… and no motion')
end

--------------------------------------------------------------------------------
-- parents and children (§55.3): offsets, depth, bucket, the root's children list, removal
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local root = Scene.spawn({ kind = 'group', pos = P0, rot = { x = 0, y = 0, z = 90 } })
    reset()
    local c1 = Scene.spawn({ kind = 'light', parent = root, offset = { x = 1, y = 0, z = 2 },
        allowChildren = { 'fx' } })
    eq(trace(), 'put:' .. c1, 'a child is put (the index emits it in its root cell)')
    eq(calls('put')[1].parent, root, 'with its parent')
    local x, y, z = store.pose(store.get(c1))
    check(math.abs(x - P0.x) < 1e-9 and math.abs(y - (P0.y + 1)) < 1e-9 and z == P0.z + 2,
        "a child's pose = its parent's pose ∘ offset (yaw 90: +x → +y)")
    local c2 = Scene.spawn({ kind = 'light', parent = c1, offset = { x = 0, y = 1, z = 0 } })
    local c3 = Scene.spawn({ kind = 'light', parent = c2 })
    local c4 = Scene.spawn({ kind = 'light', parent = c3 })
    eq(errOf(Scene.spawn({ kind = 'light', parent = c4 })), 'parent', 'depth <= 4')
    local r = Scene.get(root)
    eq(table.concat(r.children, ','), table.concat({ c1, c2, c3, c4 }, ','),
        'root.children = every descendant, parent first')
    eq(Scene.get(c1).children, nil, 'non-roots carry no children list')
    eq(store.root(store.get(c4)).id, root, 'R.store.root walks up')
    eq(errOf(Scene.spawn({ kind = 'light', parent = root, bucket = 3 })), 'parent',
        'a child lives in its parent bucket')
    local r5 = Scene.spawn({ kind = 'group', pos = P0, bucket = 5 })
    eq(Scene.get(Scene.spawn({ kind = 'light', parent = r5 })).bucket, 5, "without a bucket a child takes its parent's")
    local src = Scene.spawn({ kind = 'audio.source', fields = { file = '@a/b.ogg' } })
    eq(errOf(Scene.spawn({ kind = 'light', parent = src })), 'parent', 'a dependency cannot be a parent')
    eq(errOf(Scene.spawn({ kind = 'light', parent = root, persist = true })), 'parent',
        'a persistent child needs a persistent parent')
    eq(errOf(Scene.spawn({ kind = 'light', parent = root, offset = { x = 2000, y = 0, z = 0 } })), 'offset',
        'offsets within ±1000 m')
    eq(errOf(Scene.spawn({ kind = 'light', parent = root, motion = { t = 'spin', dps = 1 } })), 'motion',
        'children have no motion')
    eq(errOf(Scene.spawn({ kind = 'light', parent = root, bone = 'bad bone' })), 'bone', 'bone = an index or a name')
    check(Scene.spawn({ kind = 'light', parent = root, bone = 57005 }) ~= nil, 'a bone index')
    local other = as('fx', 'spawn', { kind = 'light', parent = c1 })
    reset()
    eq(Scene.move(c2, { x = 0, y = 3, z = 0 }), true, 'moving a child sets its offset')
    eq(Scene.get(c2).offset.y, 3, 'offset stored')
    eq(trace(), 'changed:' .. c2 .. ':move', '… → changed(move)')
    eq(errOf(Scene.move(c2, P0, nil, { duration = 100 })), 'parent', 'no tween on a child')
    eq(errOf(Scene.motion(c2, { t = 'spin', dps = 1 })), 'parent', 'no motion on a child')
    reset()
    local removed = {}
    Scene.on('removed', '*', function(node, reason) removed[#removed + 1] = node.id .. ':' .. reason end)
    eq(Scene.remove(c2), true, 'remove a mid-level child')
    eq(trace(), 'remove:' .. c2 .. ':0', 'ONE index remove (its children go with it)')
    check(store.get(c3) == nil and store.get(c4) == nil and store.get(c1) ~= nil,
        'the subtree is gone, the parent stays')
    eq(table.concat(removed, ' '), ('%d:parent %d:parent %d:remove'):format(c4, c3, c2),
        "hooks: descendants ('parent') then the node")
    local list = Scene.get(root).children
    check(#list == 3 and list[1] == c1, "the root's list is rebuilt")
    reset()
    Scene.remove(root)
    eq(trace(), 'remove:' .. root .. ':0', 'removing the root: one call')
    check(store.get(other) == nil, "another owner's child goes with the root")
    eq(store.count(), 3, 'only the audio source and the bucket-5 pair are left')
end

--------------------------------------------------------------------------------
-- attach / detach: node targets (re-parent), players, net entities
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local a = Scene.spawn({ kind = 'group', pos = P0 })
    local b = Scene.spawn({ kind = 'prop', pos = at(50, 0, 0), model = 'm' })
    local bc = Scene.spawn({ kind = 'light', parent = b, offset = { x = 0, y = 0, z = 1 } })
    reset()
    eq(Scene.attach(b, { node = a }, { offset = { x = 1, y = 0, z = 0 } }), true,
        'attach a root (with a child) to a node')
    eq(trace(), ('remove:%d:1 put:%d put:%d'):format(b, b, bc), 'handover DEL of the old root, then PUT of the subtree')
    check(Scene.get(b).parent == a and Scene.get(b).offset.x == 1, 'b is a child of a')
    local list = Scene.get(a).children
    eq(table.concat(list, ','), b .. ',' .. bc, "a's children list has the whole subtree")
    eq(Scene.get(b).children, nil, 'b is no root any more')
    local bx = store.pose(store.get(b))
    eq(bx, P0.x + 1, 'the pose follows the new parent')
    eq(errOf(Scene.attach(a, { node = bc })), 'parent', 'a cycle is refused')
    eq(errOf(Scene.attach(a, { node = a })), 'parent', 'self is refused')
    local far = Scene.spawn({ kind = 'group', pos = P0, bucket = 2 })
    eq(errOf(Scene.attach(b, { node = far })), 'parent', 'another bucket is refused')
    local chain = Scene.spawn({ kind = 'group', pos = P0 })
    local l1 = Scene.spawn({ kind = 'group', parent = chain })
    local l2 = Scene.spawn({ kind = 'group', parent = l1 })
    local l3 = Scene.spawn({ kind = 'group', parent = l2 })
    eq(errOf(Scene.attach(b, { node = l3 })), 'parent', 'depth: parent depth 3 + b (1) + its child (1) > 4')
    local p1 = Scene.spawn({ kind = 'group', pos = P0, persist = true })
    eq(errOf(Scene.attach(p1, { node = a })), 'parent', 'a persistent node cannot hang under a non-persistent one')
    reset()
    local x0, y0 = store.pose(store.get(b))
    eq(Scene.detach(b), true, 'detach a child')
    eq(trace(), ('remove:%d:1 put:%d put:%d'):format(b, b, bc), 'handover DEL in the old root cell, PUT as a root')
    local nb = Scene.get(b)
    check(nb.parent == nil and nb.pos.x == x0 and nb.pos.y == y0 and nb.children[1] == bc,
        'b is a root at its world pose, with its child')
    eq(Scene.get(a).children, nil, "a's list is rebuilt (empty)")
    eq(Scene.detach(b), true, 'detaching a free root is a no-op')
    -- players
    H.player(env, 3, at(0, 10, 0))
    reset()
    eq(Scene.attach(b, { player = 3 }, { offset = { x = 0, y = 0, z = 1 }, bone = 24818 }), true, 'attach to a player')
    eq(trace(), 'changed:' .. b .. ':attach', '… → changed(attach)')
    check(Scene.get(b).attach.player == 3 and Scene.get(b).bone == 24818, 'stored (bone kept for the client)')
    local x, y, z = store.pose(store.get(b))
    check(x == P0.x and y == P0.y + 10 and z == P0.z + 1, 'the pose = the server-known player position ∘ offset')
    H.movePlayer(3, at(0, 40, 0))
    x, y = store.pose(store.get(b))
    eq(y, P0.y + 40, 'and follows the player')
    eq(errOf(Scene.attach(b, { player = 77 })), 'attach', 'a player without a ped is refused')
    eq(errOf(Scene.attach(bc, { player = 3 })), 'parent', 'a child rides its parent (detach first)')
    eq(errOf(Scene.drive(b, P0, ZERO)), 'attach', 'an attached node cannot be driven')
    stubs.dropPlayer(env, 3)
    local nd = Scene.get(b)
    check(nd.attach == nil and nd.pos.y == P0.y + 40, 'a dropped player: the attachment ends at the last pose')
    -- net entities
    local ent = stubs.newEntity(2, {})
    stubs.coords[ent] = stubs.vector3(P0.x + 5, P0.y, P0.z)
    stubs.headings[ent] = 180
    local net = stubs.entities[ent].netId
    reset()
    eq(Scene.attach(b, { net = net }, { offset = { x = 0, y = 2, z = 0 } }), true, 'attach to a net entity')
    x, y = store.pose(store.get(b))
    check(math.abs(x - (P0.x + 5)) < 1e-9 and math.abs(y - (P0.y - 2)) < 1e-9,
        'offset rotated by the entity heading (180°)')
    eq(errOf(Scene.attach(b, { net = 9999 })), 'attach', 'an unknown net id is refused')
    reset()
    Scene.detach(b)
    eq(trace(), ('changed:%d:attach changed:%d:move'):format(b, b), 'detach from an entity → attach + move')
    eq(Scene.get(b).attach, nil, 'detached')
    eq(errOf(Scene.attach(b, { wat = 1 })), 'attach', 'an unknown target')
    eq(errOf(as('other', 'attach', b, { node = a })), 'owner', 'owner rule')
end

--------------------------------------------------------------------------------
-- dependency nodes (audio.source) and their dependents (INTERFACES §7)
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    reset()
    local s1 = Scene.spawn({ kind = 'audio.source', fields = { file = '@radio/a.ogg', type = 'loop' } })
    eq(trace(), '', 'a dependency node is never put')
    eq(errOf(Scene.spawn({ kind = 'audio.source', fields = { file = '@a/b.ogg' }, audience = { near = 5 } })),
        'audience',
        'dependencies are never gated (v1)')
    eq(errOf(Scene.spawn({ kind = 'audio.source', fields = { file = '@a/b.ogg' }, interact = { { action = 'x' } } })),
        'interact',
        'and have no interactions')
    local e1 = Scene.spawn({ kind = 'audio', pos = P0, fields = { source = s1 } })
    eq(Scene.get(e1).deps[1], s1, 'an emitter lists its source in deps')
    eq(store.dependents(s1)[e1], true, 'R.store.dependents(source) has the emitter')
    eq(errOf(Scene.spawn({ kind = 'audio', pos = P0, fields = { source = 424242 } })), 'deps',
        'a missing source is refused')
    local prop = Scene.spawn({ kind = 'prop', pos = P0, model = 'm' })
    eq(errOf(Scene.spawn({ kind = 'audio', pos = P0, fields = { source = prop } })), 'deps',
        'the source must be a dependency node')
    eq(errOf(Scene.spawn({ kind = 'audio', pos = P0, persist = true, fields = { source = s1 } })), 'deps',
        'a persistent emitter needs a persistent source')
    local s2 = Scene.spawn({ kind = 'audio.source', fields = { file = '@radio/b.ogg' } })
    reset()
    Scene.set(e1, { source = s2 })
    local patch = calls('changed')[1].data
    check(patch.f.source == s2 and patch.d[1] == s2, 'switching the source: the SET patch carries f and d')
    check(store.dependents(s1) == nil and store.dependents(s2)[e1], 'dependents move to the new source')
    reset()
    Scene.set(s2, { volume = 0.5 })
    eq(trace(), 'changed:' .. s2 .. ':set', 'a SET of a dependency goes to the index (it fans out to the dependents)')
    local e2 = Scene.spawn({ kind = 'audio', pos = at(10, 0, 0), fields = { source = s2 } })
    local removed = {}
    Scene.on('removed', '*', function(node, reason) removed[#removed + 1] = node.id .. ':' .. reason end)
    reset()
    eq(Scene.remove(s2, { fade = true }), true, 'removing a source')
    eq(trace(), ('remove:%d:2 remove:%d:2 remove:%d:2'):format(s2, e1, e2),
        'the source DEL first, then its emitters (fade = 2)')
    eq(table.concat(removed, ' '), ('%d:source %d:source %d:remove'):format(e1, e2, s2),
        "emitters go with reason 'source'")
    check(store.get(e1) == nil and store.dependents(s2) == nil, 'records and bookkeeping are gone')
    eq(errOf(Scene.emit(s1, 'ping')), 'dependency', 'no events on a dependency node')
    eq(errOf(Scene.set(s1, nil, { radius = 50 })), 'radius', 'no radius on a dependency node')
end

--------------------------------------------------------------------------------
-- owner stop (§55.1 Registry kinds): nodes, kinds → placeholders, listeners, interact handlers, focus pins
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    as('drops', 'defineKind', { id = 'drops:bag', class = 'custom', fields = { { name = 'items', type = 'integer',
        default = 1 } } })
    local temp = as('drops', 'spawn', { kind = 'drops:bag', pos = P0 })
    local kept = as('drops', 'spawn', { kind = 'drops:bag', pos = at(5, 0, 0), persist = true })
    local mine = as('drops', 'spawn', { kind = 'marker', pos = P0 })
    local foreign = Scene.spawn({ kind = 'drops:bag', pos = at(9, 0, 0) })
    local owned = Core.Registry.getOwned('drops')
    check(owned.sceneNode[temp] and owned.sceneNode[mine] and not owned.sceneNode[kept],
        'persistent nodes are not tracked')
    local hookCalls = 0
    as('drops', 'on', 'spawned', '*', function() hookCalls = hookCalls + 1 end)
    local ih = as('drops', 'onInteract', 'drops:bag', function() end)
    H.player(env, 5, P0)
    as('drops', 'setFocus', 5, P0)
    local changes = {}
    Scene.on('changed', 'drops:bag', function(node, what) changes[#changes + 1] = node.id .. ':' .. what end)
    local kindVer = R.kinds.version()
    local verKept = Scene.get(kept).ver
    reset()
    stop(env, 'drops')
    check(store.get(temp) == nil and store.get(mine) == nil, "owner stop removes the resource's non-persistent nodes")
    check(store.get(kept) ~= nil and store.get(foreign) ~= nil, 'persistent nodes and other owners stay')
    eq(R.kinds.get('drops:bag'), nil, 'its kind is removed')
    local nk = Scene.get(kept)
    check(nk.placeholder == true and nk.kind == 'drops:bag' and nk.fields.items == 1,
        'nodes of a removed kind stay as placeholders')
    check(nk.ver > verKept, 'with a new ver')
    local puts = {}
    for _, c in ipairs(calls('put')) do puts[c.id] = c.kind end
    check(puts[kept] == false and puts[foreign] == false,
        'placeholders are re-put (the index packs them as kind 0 + PLACEHOLDER)')
    local removes = {}
    for _, c in ipairs(calls('remove')) do removes[c.id] = c.how end
    check(removes[temp] == 0 and removes[mine] == 0 and removes[kept] == nil,
        'removals are NORMAL DELs of the owned nodes only')
    check(changes[1] == kept .. ':kind' or changes[2] == kept .. ':kind', "'changed' hooks with what = 'kind'")
    check(R.kinds.version() > kindVer, 'the kinds version moved (KINDS delta)')
    eq(Scene.spawn({ kind = 'marker', pos = P0 }) ~= nil and hookCalls, 0, "the stopped resource's listeners are gone")
    eq(Scene.off(ih), false, 'its interact handles are gone')
    check(#calls('pin', 5) == 1 and calls('pin', 5)[1].x == nil, 'its focus pins are cleared')
    eq(errOf(Scene.set(kept, { items = 3 })), 'kind', 'fields of a placeholder cannot change')
    eq(Scene.move(kept, at(6, 0, 0)), true, 'but it can still move')
    reset()
    changes = {}
    as('drops', 'defineKind', { id = 'drops:bag', class = 'custom', fields = { { name = 'items', type = 'integer',
        default = 1 },
        { name = 'weight', type = 'number', default = 2.5 } } })
    local back = Scene.get(kept)
    check(back.placeholder == nil and back.fields.weight == 2.5,
        'redefined: the node is live again, new defaults filled')
    puts = {}
    for _, c in ipairs(calls('put')) do puts[c.id] = c.kind end
    check(puts[kept] == 'drops:bag' and puts[foreign] == 'drops:bag', 'nodes of the kind are re-put with it')
    check(#changes == 2, "'changed' (kind) fires per node")
    eq(Scene.adopt(kept), true, 'core adopts a node')
    eq(Scene.get(kept).owner, 'core', 'the owner changed')
    eq(errOf(as('drops', 'adopt', kept)), 'owner', 'adopt is core only')
    local t = Scene.spawn({ kind = 'marker', pos = P0 })
    eq(Scene.adopt(t, 'drops'), true, 'core hands a node to a resource')
    eq(Core.Registry.getOwned('drops').sceneNode[t], true, 'the Registry follows the new owner')
    stop(env, 'drops')
    eq(store.get(t), nil, 'so it goes when that resource stops')
end

--------------------------------------------------------------------------------
-- Scene.on hooks: spawned / changed / removed, id / kind / '*', copies, off, errors
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local Scene = Core.Scene
    local log = {}
    local h1 = Scene.on('spawned', 'marker',
        function(node) log[#log + 1] = 'spawn:' .. node.kind; node.fields.type = 42 end)
    local h2 = Scene.on('changed', '*', function(node, what) log[#log + 1] = 'changed:' .. what end)
    Scene.on('spawned', '*', callable(function() error('listener bug') end))
    check(type(h1) == 'string' and h1:sub(1, 3) == 'sl:', 'Scene.on returns a handle')
    local id = Scene.spawn({ kind = 'marker', pos = P0 })
    eq(log[1], 'spawn:marker', 'spawned fires for the kind')
    eq(Scene.get(id).fields.type, 1, 'a listener mutating its copy changes nothing')
    Scene.on('removed', id, function(node, reason) log[#log + 1] = 'removed:' .. node.id .. ':' .. reason end)
    Scene.set(id, { bob = true })
    Scene.move(id, at(1, 0, 0))
    eq(log[2] .. ' ' .. log[3], 'changed:set changed:move', 'changed passes what changed')
    eq(Scene.on('exploded', '*', print), nil, 'unknown events are refused')
    eq(Scene.on('spawned', '*', 5), nil, 'fn must be callable')
    eq(Scene.on('spawned', {}, print), nil, 'kindOrId is a kind id, a node id or *')
    eq(as('other', 'off', h2), false, "another resource cannot remove a listener")
    eq(Scene.off(h2), true, 'Scene.off removes it')
    Scene.set(id, { bob = false })
    eq(#log, 3, 'no more changed calls')
    Scene.remove(id)
    eq(log[4], 'removed:' .. id .. ':remove', "removed fires with reason 'remove'")
    eq(Scene.off('sl:999'), false, 'unknown handles')
end

--------------------------------------------------------------------------------
-- persistence (§55.18, §56.6): coalesced queued writes, rows (columns + doc), restart round trip, ids, the counter
-- row, motion re-anchor, placeholders
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local log = H.recordDb(env)
    local function writes(id) return H.writeCount(log, id) end
    as('drops', 'defineKind', { id = 'drops:bag', class = 'custom', fields = { { name = 'items', type = 'integer',
        default = 1 } } })
    local spin = as('shop', 'spawn', { kind = 'prop', pos = P0, model = 'm', persist = true, fields = { tint = 2 },
        motion = { t = 'spin', axis = 'z', dps = 30 }, interact = { { action = 'buy', perm = 'shop.buy' } } })
    local temp = Scene.spawn({ kind = 'marker', pos = P0 })
    local root = Scene.spawn({ kind = 'group', pos = at(10, 0, 0), persist = true, rot = { x = 0, y = 0, z = 90 } })
    local child = Scene.spawn({ kind = 'light', parent = root, offset = { x = 2, y = 0, z = 1 }, persist = true,
        bone = 'chassis' })
    local src = Scene.spawn({ kind = 'audio.source', persist = true, fields = { file = '@radio/a.ogg',
        type = 'loop' } })
    local em = Scene.spawn({ kind = 'audio', pos = at(20, 0, 0), persist = true, fields = { source = src } })
    local bag = as('drops', 'spawn', { kind = 'drops:bag', pos = at(30, 0, 0), persist = true, fields = { items = 4 },
        audience = { faction = 'police' } })
    local car = Scene.spawn({ kind = 'vehicle', pos = at(40, 0, 0), persist = true, model = 'adder',
        fields = { doors = { [1] = 0.5 } } })
    Scene.drive(car, at(45, 0, 0), { x = 2, y = 0, z = 0 }, 90)
    Scene.set(spin, { tint = 3 })
    Scene.set(spin, { tint = 4 })
    eq(writes(spin), 0, 'nothing is written at once')
    eq(H.row(spin), nil, '... nothing is in the table either')
    stubs.tick(1000)
    eq(writes(spin), 1, 'three changes inside a second → one write')
    eq(H.doc(temp), nil, 'non-persistent nodes are never written')
    eq(H.counter(), car + 1, "the id counter lives in core_counters('scene_nodes'): the next id")
    local doc = H.doc(spin)
    check(doc.kind == 'prop' and doc.owner == 'shop' and doc.motion.t0 == nil and doc.mphase == 0
        and type(doc.motion.a0) == 'number', 'the document stores the motion rebased (spin angle in a0, mphase 0)')
    local row = H.row(spin)
    check(row.kind == 'prop' and row.owner == 'shop' and row.bucket == 0 and row.parent == nil,
        'kind, owner, bucket are columns; a root has a NULL parent')
    check(row.doc.kind == nil and row.doc.owner == nil and row.doc.bucket == nil and row.doc.parent == nil
        and row.doc.id == nil, '... and are not repeated in doc')
    eq(row.doc.v, 1, 'doc keeps its shape version (v = 1, like the imported legacy rows)')
    local crow = H.row(child)
    check(crow.parent == root and crow.doc.offset.x == 2 and crow.doc.bone == 'chassis',
        'a child row: the parent column, offset and bone in doc')
    eq(H.row(bag).doc.audience.faction, 'police', 'the audience (serialisable form) is in doc')
    local W = R.now()
    local _, _, _, _, _, rzBefore = store.pose(store.get(spin), W)
    local srcPhase = R.diff(W, Scene.get(src).fields.t0)
    local x0 = H.xmin(spin)
    Scene.set(spin, { tint = 5 })
    stubs.tick(400)
    eq(writes(spin), 1, '≤ one write per second')
    eq(H.xmin(spin), x0, '... the row is untouched (its xmin did not move)')
    stubs.tick(600)
    eq(writes(spin), 2, 'the next second writes the change')
    check(H.xmin(spin) ~= x0 and H.doc(spin).fields.tint == 5, '... one committed row version with tint 5')
    W = R.now()
    _, _, _, _, _, rzBefore = store.pose(store.get(spin), W)
    local gone = Scene.spawn({ kind = 'marker', pos = P0, persist = true })
    stubs.tick(1000)
    check(H.row(gone) ~= nil, 'written')
    Scene.remove(gone)
    stubs.tick(1000)
    eq(H.row(gone), nil, 'a removed persistent node loses its row (a queued remove)')
    local lastSpawn = Scene.spawn({ kind = 'marker', pos = P0, persist = true })
    local stopLog = H.recordDb(env)
    local co = coroutine.create(function() env.TriggerEvent('onResourceStop', 'core') end)
    local resumed = coroutine.resume(co)
    check(resumed and coroutine.status(co) == 'dead', 'the stop runs through without yielding')
    local awaited = {}
    for _, c in ipairs(stopLog) do if c.fn ~= 'enqueue' then awaited[#awaited + 1] = c.fn end end
    check(#stopLog > 0 and #awaited == 0, 'core stop only QUEUES (enqueue; no flush / sync, no awaited call): '
        .. table.concat(awaited, ','))
    check(H.writeCount(stopLog, lastSpawn) == 1 and H.writeCount(stopLog, 'counter') == 1,
        '... the dirty node and the counter (one slice: one transaction, §56.3.3)')
    check(H.row(lastSpawn) ~= nil and H.counter() == lastSpawn + 1, 'core stop writes what is still dirty (it lands)')

    -- restart over the same database
    local env2, Core2, R2 = newServer({ keepDb = true })
    local S2, st2 = Core2.Scene, R2.store
    local L = R2.now()
    for _, id in ipairs({ spin, root, child, src, em, bag, car, lastSpawn }) do check(st2.get(id) ~= nil,
        'id ' .. id .. ' is back') end
    eq(st2.get(temp), nil, 'non-persistent nodes are not')
    local s = S2.get(spin)
    check(s.owner == 'shop' and s.fields.tint == 5 and s.fields.invincible == false and s.persist == true,
        'owner and fields round trip (false included)')
    eq(s.interact[1].perm, 'shop.buy', 'interactions round trip')
    local _, _, _, _, _, rzAfter = st2.pose(st2.get(spin), L)
    near(rzAfter, rzBefore, 1e-6, 'motion is re-anchored: the phase at the write is the phase at the load')
    check(R2.diff(L, S2.get(src).fields.t0) == srcPhase, 'Clock-valued fields (audio.source t0) are re-anchored too')
    local c = S2.get(child)
    check(c.parent == root and c.offset.x == 2 and c.bone == 'chassis', 'a child keeps its parent, offset and bone')
    eq(S2.get(root).children[1], child, "the root's children list is rebuilt")
    eq(st2.dependents(src)[em], true, 'dependents are rebuilt')
    local v = S2.get(car)
    check(v.motion == nil and v.pos.x == P0.x + 45,
        "'dr' motion is transient: the vehicle reloads at its last driven pos")
    eq(v.fields.doors[1], 0.5, 'vehicle door keys survive JSON (digit strings back to integers)')
    local b = S2.get(bag)
    check(b.placeholder == true and b.fields.items == 4 and b.audience.faction == 'police',
        'an undefined kind loads as a placeholder')
    local loadPuts = {}
    for _, cl in ipairs(calls('put')) do loadPuts[#loadPuts + 1] = cl.id end
    eq(table.concat(loadPuts, ','), table.concat({ spin, root, child, em, bag, car, lastSpawn }, ','),
        'the load puts every root (then its children), never the dependency')
    local nextId = S2.spawn({ kind = 'marker', pos = P0 })
    check(nextId > lastSpawn, 'the counter is restored: new ids never collide with persistent ones')
    reset()
    eq(as('drops', 'defineKind', { id = 'drops:bag', class = 'custom', fields = { { name = 'items',
        type = 'integer' } } }), true,
        'the plugin comes back')
    eq(S2.get(bag).placeholder, nil, 'its nodes are live again')
    eq(calls('put', bag)[1].kind, 'drops:bag', 're-put with the kind')
    check(H.row(temp) == nil and env2 ~= env, 'a clean second VM')
end

--------------------------------------------------------------------------------
-- §56 port (run W2d): a detach writes a NULL parent, the columns win at load, the counter row behind / ahead, a
-- streamed load over several batches, core_db not started, only a caller that can yield starts the load
--------------------------------------------------------------------------------
local function printedHas(needle)
    for _, line in ipairs(stubs.printed) do if line:find(needle, 1, true) then return true end end
    return false
end
do
    local _, Core = newServer()
    local Scene = Core.Scene
    local root = Scene.spawn({ kind = 'group', pos = P0, persist = true })
    local kid = Scene.spawn({ kind = 'light', parent = root, offset = { x = 1, y = 0, z = 0 }, persist = true })
    stubs.tick(1000)
    eq(H.row(kid).parent, root, 'the child row names its parent (column)')
    eq(Scene.detach(kid), true, 'detach')
    stubs.tick(1000)
    eq(H.row(kid).parent, nil, 'a detach writes the parent column as NULL (the upsert overwrites it)')
    H.putRow({ id = 900, kind = 'marker', owner = 'shop', bucket = 3, doc = { v = 1, kind = 'prop', owner = 'evil',
        bucket = 9, parent = root, pos = P0, rot = ZERO, fields = { type = 1 } } })
    H.setCounter(1)                                                 -- behind the rows (a lost counter write)
    local _, Core2 = newServer({ keepDb = true })
    local n = Core2.Scene.get(900)
    check(n and n.kind == 'marker' and n.owner == 'shop' and n.bucket == 3 and n.parent == nil,
        'the columns win over stale keys in doc (kind, owner, bucket, parent)')
    eq(Core2.Scene.get(kid).parent, nil, 'the detached child reloads as a root')
    eq(Core2.Scene.spawn({ kind = 'marker', pos = P0 }), 901,
        'a counter behind the rows: ids go on after the highest row')
    H.setCounter(5000)
    local _, Core3 = newServer({ keepDb = true })
    eq(Core3.Scene.spawn({ kind = 'marker', pos = P0 }), 5000, 'a counter ahead of the rows is kept (ids never reused)')
end
do  -- a streamed load: 2,500 rows in batches of 1000 (one FETCH per batch), a parent with a higher id than its child
    newServer()
    H.sql("INSERT INTO scene_nodes (id, kind, owner, bucket, doc) SELECT g, 'marker', 'core', 0, "
        .. "jsonb_build_object('v', 1, 'pos', jsonb_build_object('x', 100 + g % 50, 'y', 200, 'z', 30), "
        .. "'fields', jsonb_build_object('type', 1)) FROM generate_series(1, 2500) AS g")
    H.sql('UPDATE scene_nodes SET parent = 2450 WHERE id = 7')
    local log
    local _, Core, R = newServer({ keepDb = true, beforeStore = function(e) log = H.recordDb(e) end })
    local fetches = 0
    for _, c in ipairs(log) do
        if c.fn == 'txQuery' and tostring(c.args[2]):find('^FETCH 1000 FROM') then fetches = fetches + 1 end
    end
    eq(fetches, 3, 'Core.DB.stream in batches of 1000: three FETCHes for 2,500 rows')
    eq(R.store.count(), 2500, 'every row is a node')
    check(Core.Scene.get(7).parent == 2450 and Core.Scene.get(2450).children[1] == 7,
        'a child whose parent has a higher id (a later batch) is linked: all rows are read before any is linked')
    eq(Core.Scene.spawn({ kind = 'marker', pos = P0 }), 2501, 'no counter row: ids go on after the highest row')
end
do  -- review R3a #6: a row that cannot be built (rowOf throws) costs only that node — the others of the pass land,
    -- it stays dirty (logged once) and is written once it can be built; at the stop the others' final rows land
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local a = Scene.spawn({ kind = 'marker', pos = P0, persist = true })
    local b = Scene.spawn({ kind = 'marker', pos = at(1, 0, 0), persist = true })
    local c = Scene.spawn({ kind = 'marker', pos = at(2, 0, 0), persist = true })
    stubs.tick(1000)
    local xa, xb, xc = H.xmin(a), H.xmin(b), H.xmin(c)
    for _, id in ipairs({ a, b, c }) do Scene.set(id, { bob = true }) end
    store.get(b).offset = 5                                         -- a corrupt record: v3(5) throws in rowOf
    stubs.printed = {}
    stubs.tick(1000)
    check(H.xmin(a) ~= xa and H.xmin(c) ~= xc and H.doc(a).fields.bob == true and H.doc(c).fields.bob == true,
        'the other dirty nodes of the pass are written')
    eq(H.xmin(b), xb, 'the node whose row throws is not')
    local function failures()
        local n = 0
        for _, line in ipairs(stubs.printed) do
            if line:find(('node %d could not be persisted'):format(b), 1, true) then n = n + 1 end
        end
        return n
    end
    eq(failures(), 1, '... it is logged')
    stubs.tick(3000)
    eq(failures(), 1, '... once, while it stays dirty and is retried every second')
    store.get(b).offset = nil
    stubs.tick(1000)
    check(H.xmin(b) ~= xb and H.doc(b).fields.bob == true, 'once its row can be built, it is written')
    Scene.set(a, { bob = false })
    Scene.set(b, { bob = false })
    store.get(b).offset = 5
    env.TriggerEvent('onResourceStop', 'core')
    check(H.doc(a).fields.bob == false and H.doc(b).fields.bob == true,
        'at the stop a throwing row loses only itself: the other final rows land')
    check(printedHas('lost at the stop'), '... and the loss is logged')
    store.get(b).offset = nil
end
do  -- core_db not started: rows stay dirty and are retried every second; a stop meanwhile logs what is lost
    local env, Core = newServer()
    local Scene = Core.Scene
    stubs.resourceStates.core_db = 'stopped'
    local id = Scene.spawn({ kind = 'marker', pos = P0, persist = true })
    stubs.tick(3000)
    eq(H.row(id), nil, 'core_db not started: nothing is written')
    stubs.resourceStates.core_db = nil
    stubs.tick(1000)
    check(H.row(id) ~= nil and H.counter() == id + 1, '... it is back: the next second writes the node and the counter')
    stubs.resourceStates.core_db = 'stopped'
    Scene.set(id, { bob = true })
    env.TriggerEvent('onResourceStop', 'core')
    stubs.resourceStates.core_db = nil
    check(printedHas('lost at the stop'), 'a stop while core_db is not started logs the lost writes')
    eq(H.doc(id).fields.bob, false, '... the row keeps its last committed state')
end
do  -- the load needs a caller that can yield: a plugin's export call before the start thread ran neither loads nor
    -- fails the load
    local _, Core, R = newServer({ noStart = true })
    local Scene = Core.Scene
    local id, err = Scene.spawn({ kind = 'marker', pos = P0 })
    check(id == nil and err == 'unavailable' and not R.store.loaded(),
        'before the start thread ran, a non-yieldable caller gets unavailable')
    check(not printedHas('could not be loaded') and not printedHas('outside a coroutine'),
        '... without starting (or failing) a load')
    stubs.tick(0)
    check(R.store.loaded() and Scene.spawn({ kind = 'marker', pos = P0 }) ~= nil,
        'the start thread loads at once (no 10 s retry wait)')
end

--------------------------------------------------------------------------------
-- core:scene:interact (§55.14 / §55.19): every refusal step, distance to a moving node, dispatch order
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene = Core.Scene
    check(env.__vm.netEvents['core:scene:interact'] == true, 'core:scene:interact is registered (Core.Net.on)')
    local hits = {}
    local function handler(tag) return function(src, node, action, data)
        hits[#hits + 1] = { tag = tag, src = src, id = node.id, action = action, data = data }
        node.fields.model = 'hacked'
    end end
    local id = as('shop', 'spawn', { kind = 'prop', pos = P0, model = 'm', interact = {
        { action = 'use', distance = 2, cooldownMs = 1000 }, { action = 'rob', perm = 'shop.rob', distance = 3 } } })
    local hId = as('shop', 'onInteract', id, handler('id'))
    as('shop', 'onInteract', 'prop', handler('kind'))
    as('other', 'onInteract', 'prop', callable(function() error('handler bug') end))
    check(type(hId) == 'string' and hId:sub(1, 3) == 'si:', 'onInteract returns a handle')
    H.player(env, 1, at(1, 0, 0))
    local function press(src, nid, action, data, wait)
        hits = {}
        stubs.tick(wait or 300)
        H.interact(env, src, nid, action, data)
        return #hits
    end
    eq(press(1, id, 'use'), 2, 'a valid press reaches the handlers')
    check(hits[1].tag == 'id' and hits[2].tag == 'kind', 'handlers of the id first, then of the kind')
    check(hits[1].src == 1 and hits[1].id == id and hits[1].action == 'use',
        'handlers get (src, nodeCopy, action, data)')
    eq(Scene.get(id).fields.model, 'm', 'handlers get copies')
    eq(press(1, id, 'use', nil, 300), 0, "the descriptor's cooldownMs (1000) holds")
    eq(press(1, id, 'use', nil, 800), 2, '… and passes after it')
    hits = {}
    H.interact(env, 1, id, 'use')
    eq(#hits, 0, 'the event cooldown (250 ms per player) holds')
    eq(press(1, 'x', 'use'), 0, 'schema: the id is an integer')
    eq(press(1, id, 'bad action'), 0, 'schema: the action pattern')
    eq(press(1, id, string.rep('a', 33)), 0, 'schema: action <= 32')
    eq(press(1, id, 'use', string.rep('x', 2000), 1100), 0, 'data <= 1 KiB')
    eq(press(1, id, 'use', { note = 'hi' }, 1100), 2, 'small data passes')
    eq(hits[1].data.note, 'hi', 'data reaches the handler')
    H.unloaded[1] = true
    eq(press(1, id, 'use', nil, 1100), 0, 'a player who is not loaded is refused')
    H.unloaded[1] = nil
    eq(press(1, 999, 'use', nil, 1100), 0, 'an unknown node')
    local src = Scene.spawn({ kind = 'audio.source', fields = { file = '@a/b.ogg' } })
    eq(press(1, src, 'use', nil, 1100), 0, 'a dependency node')
    stubs.buckets[1] = 2
    eq(press(1, id, 'use', nil, 1100), 0, 'another bucket')
    stubs.buckets[1] = 0
    eq(press(1, id, 'open', nil, 1100), 0, 'a missing descriptor')
    eq(press(1, id, 'rob', nil, 1100), 0, 'a perm the player lacks')
    H.perms['1|shop.rob'] = true
    eq(press(1, id, 'rob', nil, 1100), 2, 'the perm granted')
    H.movePlayer(1, at(3.9, 0, 0))
    eq(press(1, id, 'use', nil, 1100), 2, 'distance: descriptor distance + 2 m (3.9 <= 4)')
    H.movePlayer(1, at(4.1, 0, 0))
    eq(press(1, id, 'use', nil, 1100), 0, 'distance: 4.1 > 4 is refused')
    Scene.set(id, nil, { audience = { faction = 'staff' } })
    H.movePlayer(1, at(1, 0, 0))
    eq(press(1, id, 'use', nil, 1100), 0, 'a gated node the player may not see')
    H.allows[1] = true
    eq(press(1, id, 'use', nil, 1100), 2, 'R.interest.allows decides for gated nodes')
    Scene.set(id, nil, { audience = false })
    -- a moving node: the server-evaluated pose counts, not the base
    local mover = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', interact = { { action = 'grab', distance = 1 } },
        motion = { t = 'path', pts = { P0, at(0, 100, 0) }, d = 10000 } })
    Scene.onInteract(mover, handler('mover'))
    stubs.tick(200 + 5000)
    H.movePlayer(1, P0)
    eq(press(1, mover, 'grab', nil, 0), 0, 'the node moved 50 m away from its base: refused at the base')
    H.movePlayer(1, at(0, 50.3, 0))
    eq(press(1, mover, 'grab', nil, 300), 2, 'accepted where the node is now (its id handler + the prop kind handler)')
    H.movePlayer(1, at(1, 0, 0))
    Core.Scene.off(hId)
    eq(press(1, id, 'use', nil, 1100), 1, 'Scene.off stops a handler')
    local promoted
    R.promote = { onInteract = function(_, node, action) promoted = node.id .. ':' .. action end }
    press(1, id, 'use', nil, 1100)
    eq(promoted, id .. ':use', 'promotion triggers hear the same path (R.promote.onInteract)')
    R.promote = nil
    stubs.dropPlayer(env, 1)
    check(#stubs.failures == 0, 'no uncaught errors on the interaction path')
end

--------------------------------------------------------------------------------
-- Scene.drive (C2, §55.9): the server's dead-reckoned copy, thresholds, rate caps, heartbeat
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local Scene = Core.Scene
    local car = as('race', 'spawn', { kind = 'vehicle', pos = P0, model = 'adder' })
    reset()
    local ok, sent = as('race', 'drive', car, P0, { x = 10, y = 0, z = 0 }, 0)
    check(ok and sent, 'the first drive is sent')
    eq(trace(), 'changed:' .. car .. ':motion', '… as a MOTION op (the dr state becomes the motion, versioned)')
    local m = Scene.get(car).motion
    check(m.t == 'dr' and m.v.x == 10 and m.t0 == R.now(), 'a dr descriptor: t0 = now, p, v')
    reset()
    stubs.tick(100)
    ok, sent = Scene.drive(car, at(1.1, 0, 0), { x = 10, y = 0, z = 0 }, 0)
    check(ok and not sent, 'on the predicted track (1.0 m after 100 ms, 0.1 m off): nothing is sent')
    stubs.tick(100)
    ok, sent = Scene.drive(car, at(2.4, 0, 0), { x = 10, y = 0, z = 0 }, 0)
    check(ok and sent, '0.4 m off > DeadReckoning.Near (0.25, tier M) → a DR op')
    local dr = calls('dr')[1]
    check(dr and dr.id == car and dr.x == P0.x + 2.4 and dr.vx == 10 and dr.yaw == 0 and dr.t == R.now(),
        'R.index.dr(node, t, pos, vel, yaw)')
    eq(#calls('changed'), 0, 'DR ops carry no version (no changed call)')
    stubs.tick(50)
    ok, sent = Scene.drive(car, at(9, 0, 0), { x = 10, y = 0, z = 0 }, 0)
    check(ok and not sent, 'the per-node rate cap (NearHz 10 → 100 ms) holds even a big error')
    stubs.tick(60)
    ok, sent = Scene.drive(car, at(9, 0, 0), { x = 10, y = 0, z = 0 }, 0)
    check(sent, 'and releases it after 100 ms')
    stubs.tick(200)
    local x = select(1, R.store.pose(R.store.get(car)))
    ok, sent = Scene.drive(car, { x = x, y = P0.y, z = P0.z }, { x = 10, y = 0, z = 0 }, 5)
    check(sent, 'a heading error over 3 degrees → DR')
    reset()
    stubs.tick(2000)
    Scene.drive(car, at(20, 0, 0), ZERO, 5)
    stubs.tick(200)
    ok, sent = Scene.drive(car, at(20, 0, 0), ZERO, 5)
    check(not sent, 'standing still exactly where predicted: nothing')
    stubs.tick(5000)
    ok, sent = Scene.drive(car, at(20, 0, 0), ZERO, 5)
    check(sent, 'HeartbeatMs (5 s) sends anyway')
    local plane = Scene.spawn({ kind = 'vehicle', pos = P0, model = 'lazer', radius = 1200 })
    Scene.drive(plane, P0, ZERO, 0)
    stubs.tick(500)
    ok, sent = Scene.drive(plane, at(5, 0, 0), ZERO, 0)
    check(not sent, 'tier L: FarHz (1 Hz) holds a 5 m error for a second')
    stubs.tick(500)
    ok, sent = Scene.drive(plane, at(0.8, 0, 0), ZERO, 0)
    check(not sent, 'tier L uses DeadReckoning.Far (1 m): 0.8 m is fine')
    ok, sent = Scene.drive(plane, at(1.5, 0, 0), ZERO, 0)
    check(sent, '1.5 m after a second → DR')
    eq(errOf(as('other', 'drive', car, P0, ZERO, 0)), 'owner', 'owner rule')
    eq(errOf(Scene.drive(car, { x = 1e5, y = 0, z = 0 }, ZERO, 0)), 'pos', 'world bounds')
    eq(errOf(Scene.drive(car, P0, { x = 400, y = 0, z = 0 }, 0)), 'vel', 'speed <= 300 m/s')
    eq(errOf(Scene.drive(car, P0, ZERO, 0 / 0)), 'yaw', 'a finite yaw')
    local child = Scene.spawn({ kind = 'light', parent = car })
    eq(errOf(Scene.drive(child, P0, ZERO, 0)), 'parent', 'children are not driven')
    reset()
    Scene.motion(car, nil)
    Scene.drive(car, P0, ZERO, 0)
    eq(trace(), ('changed:%d:motion changed:%d:motion'):format(car, car),
        'after a motion change the next drive re-seeds with MOTION')
end

--------------------------------------------------------------------------------
-- emit (C4), query, list, batch, stats, focus, prefetch, phase B/C entry points
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene = Core.Scene
    local id = as('fx', 'spawn', { kind = 'prop', pos = P0, model = 'm', bucket = 3, motion = { t = 'spin',
        dps = 10 } })
    reset()
    eq(as('fx', 'emit', id, 'boom', { power = 3 }), true, 'a node event')
    local e = calls('event')[1]
    check(e.id == id and e.x == P0.x and e.bucket == 3 and e.name == 'boom' and e.params.power == 3 and e.radius == 255
        and e.horizonMs == 2000 and e.t == R.now(),
            'R.index.event(node, pose, bucket, name, params, t, node radius, 2000 ms)')
    eq(errOf(as('other', 'emit', id, 'boom')), 'owner', "someone else's node")
    reset()
    eq(as('other', 'emit', { pos = at(5, 0, 0), bucket = 1 }, 'thunder', nil, { radius = 800, horizonMs = 500 }), true,
        'a positional event (anyone)')
    e = calls('event')[1]
    check(e.id == false and e.x == P0.x + 5 and e.bucket == 1 and e.radius == 800 and e.horizonMs == 500
        and e.params == nil,
        'positional: pos, bucket, radius, horizon')
    eq(Scene.emit({ pos = P0 }, 'x') and calls('event')[2].radius, 150, 'positional default radius 150')
    eq(errOf(Scene.emit(id, 'bad name!')), 'name', 'event names are plain')
    eq(errOf(Scene.emit(id, string.rep('a', 33))), 'name', 'names <= 32')
    eq(errOf(Scene.emit(id, 'x', string.rep('p', 2000))), 'params', 'params <= 1 KiB packed')
    eq(errOf(Scene.emit(id, 'x', { 1, 2, n = 2 })), 'params',
        'a sequence with an n key is refused (FiveM msgpack drops n)')
    eq(errOf(Scene.emit(id, 'x', nil, { radius = 0 })), 'radius', 'radius 1..TierL')
    eq(errOf(Scene.emit(id, 'x', nil, { horizonMs = 40000 })), 'horizonMs', 'horizon 0..30000')
    eq(errOf(Scene.emit({ pos = { x = 0, y = 0, z = 9999 } }, 'x')), 'pos', 'a positional event inside the world')
    eq(errOf(Scene.emit(4242, 'x')), 'missing', 'an unknown node')
    -- query / list
    local a = Scene.spawn({ kind = 'marker', pos = at(0, 0, 0), bucket = 3 })
    local b = Scene.spawn({ kind = 'marker', pos = at(30, 0, 0), bucket = 3 })
    local c = as('shop', 'spawn', { kind = 'light', pos = at(10, 0, 0), bucket = 3 })
    local far = Scene.spawn({ kind = 'marker', pos = at(900, 0, 0), bucket = 3 })
    local g = Scene.spawn({ kind = 'marker', pos = at(3000, 3000, 0), bucket = 3, global = true })
    local L = Scene.spawn({ kind = 'prop', pos = at(20, 0, 0), bucket = 3, model = 'm', radius = 1000 })
    local ch = Scene.spawn({ kind = 'light', parent = c, bucket = 3, offset = { x = 1, y = 0, z = 0 } })
    Scene.spawn({ kind = 'marker', pos = P0, bucket = 0 })
    local q = Scene.query({ pos = P0, radius = 25, bucket = 3 })
    local ids = {}
    for i, n in ipairs(q) do ids[i] = n.id end
    eq(table.concat(ids, ','), table.concat({ id, a, c, ch, L }, ','),
        'query: exact test, nearest first (ties by id), children and L-tier included')
    check(q[1].fields ~= nil and q[1].owner == 'fx' and q[1].k == nil, 'query answers node copies')
    eq(#Scene.query({ pos = P0, radius = 25 }), 1, 'bucket 0 by default')
    eq(#Scene.query({ pos = P0, radius = 25, bucket = 3, kind = 'marker' }), 1, 'kind filter')
    eq(#Scene.query({ pos = P0, radius = 25, bucket = 3, owner = 'shop' }), 1, 'owner filter')
    eq(#Scene.query({ pos = P0, radius = 100, bucket = 3, limit = 2 }), 2, 'limit')
    eq(#Scene.query({ pos = at(3000, 3000, 0), radius = 5, bucket = 3 }), 1,
        'global nodes are found through the global set')
    check(#Scene.query({ pos = P0, radius = 0, bucket = 3 }) == 0 and #Scene.query('x') == 0, 'bad queries answer {}')
    local l = Scene.list({ bucket = 3 })
    eq(#l, 8, 'list by bucket (children included)')
    eq(table.concat(Scene.list({ owner = 'shop' }), ','), tostring(c), 'list by owner')
    eq(#Scene.list({ kind = 'marker', bucket = 3 }), 4, 'list by kind + bucket')
    eq(#Scene.list({ owner = 'nobody' }), 0, 'an unknown owner')
    check(far and g, 'fixtures exist')
    -- batch
    local x, y = Scene.batch(function(k)
        Scene.set(a, { bob = true })
        Scene.move(b, at(31, 0, 0))
        return k, 'done'
    end, 7)
    check(x == 7 and y == 'done' and Scene.get(a).fields.bob == true, "batch runs fn and returns fn's results")
    check(select(2, Scene.batch(function() error('oops') end)) == 'error' and select(2, Scene.batch(5)) == 'fn',
        'batch errors')
    -- stats
    local st = Scene.stats()
    check(st.nodes == 9 and st.byKind.marker == 5 and st.kinds == 13 and st.loaded == true,
        'stats: nodes, byKind, kinds, loaded')
    check(st.subscribers == 7 and st.flushMs.p99 == 4 and st.bytesPerSecond == 1234 and st.cells ~= nil,
        'stats merge the index / interest / flush stats')
    -- focus pins, prefetch
    reset()
    eq(as('cam', 'setFocus', 4, at(1, 2, 3)), false, 'setFocus refuses a src nobody is connected as (review F11)')
    eq(Scene.prefetch(4, P0), false, '… and so does prefetch')
    H.player(env, 4, P0)
    eq(as('cam', 'setFocus', 4, at(1, 2, 3)), true, 'setFocus pins a trusted focus')
    local pin = calls('pin')[1]
    check(pin.id == 4 and pin.x == P0.x + 1 and pin.z == P0.z + 3, 'R.interest.pin(src, x, y, z)')
    eq(Core.Registry.getOwned('cam').sceneFocus[4], true, "owner-tracked ('sceneFocus')")
    eq(as('cam', 'setFocus', 4, nil), true, 'nil clears')
    check(calls('pin')[2].x == nil, 'R.interest.pin(src, nil)')
    check(not Scene.setFocus(0, P0) and not Scene.setFocus(4, { x = 'a' }), 'bad focus arguments')
    eq(Scene.prefetch(4, P0), true, 'prefetch (core-internal)')
    check(calls('prefetch')[1].id == 4 and calls('prefetch')[1].y == P0.y, 'R.interest.prefetch(src, x, y, z)')
    -- phase B/C
    for _, fn in ipairs({ Scene.promote, Scene.demote, Scene.lease, Scene.voice.start, Scene.voice.stop,
        Scene.voice.list,
        Scene.audio.kill }) do
        check(select(2, fn(a)) == 'unavailable', 'phase B/C entry points answer unavailable before their files exist')
    end
    R.promote = { promote = function(nid) return 'net:' .. nid end }
    eq(Scene.promote(a), 'net:' .. a, 'and delegate once R.promote exists')
    eq(select(2, stubs.exports.core.call('p', 'Scene', 'voice.start', {})), 'unavailable',
        'voice.start resolves through the export')
    R.promote = nil
    local seenPromo
    Scene.on('promoted', a, function(node, netId) seenPromo = node.id .. ':' .. netId end)
    R.store.notify('promoted', R.store.get(a), 99)
    eq(seenPromo, a .. ':99', 'R.store.notify fires promoted / demoted listeners (phase C)')
    check(R.store.count() == 9 and R.store.copy(R.store.get(a)).id == a, 'R.store.count / copy')
    local counted = 0
    R.store.each(function() counted = counted + 1 end)
    eq(counted, 9, 'R.store.each')
    check(env ~= nil, 'done')
end

--------------------------------------------------------------------------------
-- size caps, MaxNodes, n-key sequences, a degraded database (the load barrier retries)
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer({ config = function(Config) Config.Scene.MaxNodes = 3 end })
    local Scene, K = Core.Scene, R.kinds
    local half = {}
    for i = 1, 60 do half['k' .. i] = string.rep('x', 70) end
    local ok, errs = K.check(K.get('ped'), { model = 'p', appearance = half, variation = half }, false)
    check(not ok and errs['*'] == 'size', 'the whole fields table is capped at MaxFieldBytes packed')
    check(K.check(K.get('ped'), { model = 'p', appearance = half }, false), 'one half fits')
    Scene.defineKind({ id = 'core:free', class = 'data', fields = { { name = 'data', type = 'table' } } })
    local _, e1 = K.check(K.get('core:free'), { data = { 1, 2, n = 2 } }, false)
    eq(e1 and e1.data, 'type', 'a table field may not hold a sequence with an n key')
    local _, e2 = K.check(K.get('core:free'), { data = { list = { 'a', n = 1 } } }, false)
    eq(e2 and e2.data, 'type', '… nested either')
    check(K.check(K.get('core:free'), { data = { n = 1, m = 2 } }, false), 'an n key in a map is fine')
    for _ = 1, 3 do Scene.spawn({ kind = 'marker', pos = P0 }) end
    eq(errOf(Scene.spawn({ kind = 'marker', pos = P0 })), 'limit', 'MaxNodes (server-wide)')
end
do  -- a failed read (§56.8 rule 4): the load fails — never an empty world — and is retried; no half state
    local _, Core0 = newServer()
    local kept = Core0.Scene.spawn({ kind = 'marker', pos = P0, persist = true })
    local kid = Core0.Scene.spawn({ kind = 'light', parent = kept, persist = true })
    stubs.tick(1000)
    local bridge = H.bridge
    bridge.fail('FROM scene_nodes ORDER BY id')                     -- the stream's cursor
    local _, Core = newServer({ keepDb = true })
    local Scene = Core.Scene
    local id, err = Scene.spawn({ kind = 'marker', pos = P0 })
    check(id == nil and err == 'unavailable', 'while scene_nodes cannot be read, the API answers unavailable')
    check(#Scene.list() == 0 and Scene.get(kept) == nil and #Scene.query({ pos = P0, radius = 5 }) == 0,
        'reads are empty')
    local logged = false
    for _, line in ipairs(stubs.printed) do logged = logged or line:find('could not be loaded', 1, true) ~= nil end
    check(logged, 'the failed load is logged')
    bridge.unfail()
    bridge.fail('FROM core_counters WHERE name')                    -- the counter read fails the load as well
    stubs.tick(10000)
    eq(Scene.get(kept), nil, 'a failed counter read is a failed load too (ids could collide otherwise)')
    bridge.unfail()
    stubs.tick(10000)
    check(Scene.get(kept) ~= nil and Scene.get(kid).parent == kept,
        'the start thread retries (10 s): the rows are back')
    local fresh = Scene.spawn({ kind = 'marker', pos = P0 })
    check(fresh ~= nil and fresh > kid, '... and new ids never collide with them')
end

--------------------------------------------------------------------------------
-- motion lifecycle: far-future plans, R.store.settle (finished plans), rebased persistence
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local day = 86400000
    local far = { t = 'spin', dps = 10, t0 = R.add(R.now(), day + 60000) }
    eq(errOf(Scene.spawn({ kind = 'prop', pos = P0, model = 'm', motion = far })), 'motion_future',
        'a plan more than 24 h ahead is refused at spawn')
    local id = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', persist = true })
    eq(errOf(Scene.motion(id, far)), 'motion_future', '… and by Scene.motion (rebase could never move it)')
    eq(Scene.motion(id, { t = 'spin', dps = 10, t0 = R.add(R.now(), day - 60000) }), true, '23 h ahead is fine')
    -- settle: the index's movers sweep folds a finished plan into the base pose
    local tw = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', persist = true })
    local kid = Scene.spawn({ kind = 'light', parent = tw, offset = { x = 0, y = 0, z = 2 } })
    Scene.move(tw, at(10, 0, 0), nil, { duration = 100 })
    local changes = {}
    Scene.on('changed', tw, function(_, what) changes[#changes + 1] = what end)
    local ver = Scene.get(tw).ver
    reset()
    eq(store.settle(store.get(tw), P0.x + 10, P0.y, P0.z, 0, 0, 370), true, 'R.store.settle folds the end pose in')
    local n = Scene.get(tw)
    check(n.motion == nil and n.pos.x == P0.x + 10 and n.rot.z == 10 and n.ver > ver,
        'base pose = end pose, no motion, new ver')
    eq(trace(), ('changed:%d:move changed:%d:motion'):format(tw, tw), '… then changed(move) + changed(motion)')
    eq(changes[1], 'motion', "a 'changed' hook (what = motion)")
    eq(Scene.get(kid).offset.z, 2, 'children keep their offsets')
    reset()
    eq(store.settle(store.get(tw), 1, 2, 3), false, 'a node without motion: no-op')
    eq(store.settle({ id = 999, motion = {} }, 1, 2, 3), false, 'a node that is not in the store: no-op')
    eq(trace(), '', 'no index calls for no-ops')
    stubs.tick(1000)
    local doc = H.doc(tw)
    check(doc.motion == nil and doc.pos.x == P0.x + 10, 'a settled persistent node is persisted at its end pose')
    -- rebased persistence: osc keeps its own `phase`, a finished tween persists as an ended tween
    local osc = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', persist = true,
        motion = { t = 'osc', dir = { x = 0, y = 0, z = 1 }, amp = 2, period = 4000, phase = 90 } })
    local done = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', persist = true })
    Scene.move(done, at(0, 30, 0), nil, { duration = 500 })
    stubs.tick(1000)
    local W = R.now()
    local _, _, oz = store.pose(store.get(osc), W)
    local _, dy = store.pose(store.get(done), W)
    env.TriggerEvent('onResourceStop', 'core')
    local _, Core2, R2 = newServer({ keepDb = true })
    local st2 = R2.store
    local L = R2.now()
    local _, _, oz2 = st2.pose(st2.get(osc), L)
    check(Core2.Scene.get(osc).motion.t == 'osc', 'the osc motion survives')
    near(oz2, oz, 1e-3, 'the osc resumes at its written phase (its own phase field is not clobbered)')
    local _, dy2 = st2.pose(st2.get(done), L)
    near(dy2, dy, 1e-6, 'a finished tween reloads at its end pose')
end

--------------------------------------------------------------------------------
-- review RV1 (A2's part) — R.store.audienceOf + F2: the effective audience; the interaction path honours it
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local pub = Scene.spawn({ kind = 'group', pos = P0 })
    local pubKid = Scene.spawn({ kind = 'prop', parent = pub, model = 'm' })
    eq(store.audienceOf(store.get(pubKid)), nil, 'audienceOf: a public root and a public child → nil')
    local groot = Scene.spawn({ kind = 'prop', pos = at(2, 0, 0), model = 'm', audience = { players = { 1 } } })
    local gkid = Scene.spawn({ kind = 'prop', parent = groot, model = 'm', offset = { x = 0, y = 0, z = 0.5 },
        interact = { { action = 'open', distance = 2 } } })
    local rootAud = store.get(groot).audience
    eq(store.audienceOf(store.get(gkid)), rootAud, "a child of a gated root: the root's audience (the live table)")
    local own = Scene.spawn({ kind = 'prop', parent = pub, model = 'm', audience = { players = { 2 } },
        interact = { { action = 'use', distance = 20 } } })
    eq(store.audienceOf(store.get(own)).players[1], 2, 'a gated child of a public root: its own audience')
    local both = Scene.spawn({ kind = 'prop', parent = gkid, model = 'm', audience = { faction = 'x' } })
    local eff = store.audienceOf(store.get(both))
    check(eff.all and #eff.all == 2 and eff.all[1] == rootAud and eff.all[2].faction == 'x',
        'several levels: { all = { rootAud, …, nodeAud } }, root first (the §55.3 grammar)')
    H.player(env, 1, at(2, 0, 0))
    H.player(env, 2, at(2, 0, 0))
    local hits = {}
    Scene.onInteract('prop', function(src, node) hits[#hits + 1] = src .. '@' .. node.id end)
    local function press(src, id, action)
        hits = {}
        stubs.tick(300)
        H.interact(env, src, id, action)
        return table.concat(hits, ' ')
    end
    eq(press(2, gkid, 'open'), '', "review F2: outside the gated root's audience, its child's interaction is refused")
    eq(press(1, gkid, 'open'), '1@' .. gkid, 'the audience member uses it')
    eq(press(1, own, 'use'), '', "a gated child of a public root: its own audience decides (1 is not in it)")
    eq(press(2, own, 'use'), '2@' .. own, '… and admits 2')
    local r2 = Scene.spawn({ kind = 'group', pos = at(2, 0, 0), audience = { players = { 1, 2 } } })
    local k2 = Scene.spawn({ kind = 'prop', parent = r2, model = 'm', audience = { players = { 2 } },
        interact = { { action = 'use', distance = 3 } } })
    eq(press(1, k2, 'use'), '', 'both levels gated: every level must admit (1 fails the child)')
    eq(press(2, k2, 'use'), '2@' .. k2, '… 2 passes both')
    eq(store.kids(groot)[gkid], true, 'R.store.kids(id): the direct children set')
end

--------------------------------------------------------------------------------
-- review RV1 F3: MaxChildren per root; removals rebuild a root's list once (the owner sweep included)
--------------------------------------------------------------------------------
do
    local env, Core = newServer({ config = function(C) C.Scene.MaxChildren = 5 end })
    local Scene = Core.Scene
    local root = Scene.spawn({ kind = 'group', pos = P0 })
    local kids = {}
    for i = 1, 5 do kids[i] = Scene.spawn({ kind = 'light', parent = i <= 3 and root or kids[1] }) end
    check(kids[5] ~= nil, 'MaxChildren (5 in this VM): five descendants fit')
    eq(errOf(Scene.spawn({ kind = 'light', parent = kids[2] })), 'limit', 'the sixth descendant (any depth) is refused')
    local other = Scene.spawn({ kind = 'group', pos = at(20, 0, 0) })
    Scene.spawn({ kind = 'light', parent = other })
    eq(errOf(Scene.attach(other, { node = kids[1] })), 'limit', 'attaching a subtree past the cap is refused')
    eq(Scene.attach(kids[5], { node = kids[2] }), true, 'a move inside the same root is not counted')
    local r2 = Scene.spawn({ kind = 'group', pos = P0, allowChildren = { 'kids' } })
    local mine = Scene.spawn({ kind = 'light', parent = r2 })
    as('kids', 'spawn', { kind = 'light', parent = r2 })
    as('kids', 'spawn', { kind = 'light', parent = r2 })
    stop(env, 'kids')
    eq(table.concat(Scene.get(r2).children, ','), tostring(mine),
        "after the owner sweep the root's list is rebuilt (once): only the child that stayed")
end
do
    local big = function(C) C.Scene.MaxChildren = 10000 end
    newServer({ config = big })
    H.setCounter(5000000)                                         -- long-session ids: the Registry set is hashed
    local env, Core, R = newServer({ keepDb = true, config = big })
    local root = as('prefab', 'spawn', { kind = 'group', pos = P0 })
    for i = 1, 2000 do as('prefab', 'spawn', { kind = 'prop', parent = root, model = 'm', offset = { x = i % 40,
        y = 0, z = 0 } }) end
    local first = next(Core.Registry.getOwned('prefab').sceneNode)
    local t0 = os.clock()
    stop(env, 'prefab')
    local ms = (os.clock() - t0) * 1000
    eq(R.store.count(), 0, 'the owner sweep removed the root and its 2,000 children')
    check(first == root or ms < 60, ('review F3: an owner stop that hands 2,000 children out before their root is O(n) '
        .. '(%.1f ms here; the per-child rebuild took ~200 ms)'):format(ms))
end

--------------------------------------------------------------------------------
-- review RV1 F6: per-node versions, u32, wrap to 1, serial arithmetic
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local id = Scene.spawn({ kind = 'marker', pos = P0 })
    eq(Scene.get(id).ver, 1, 'versions are per node: a new node starts at 1')
    Scene.set(id, { bob = true })
    eq(Scene.get(id).ver, 2, '+1 per change')
    local other = Scene.spawn({ kind = 'marker', pos = P0 })
    Scene.set(other, { bob = true })
    eq(Scene.get(id).ver, 2, "another node's changes never move it")
    store.get(id).ver = 0xFFFFFFFF
    reset()
    Scene.set(id, { bob = false })
    eq(Scene.get(id).ver, 1, 'after 2^32 - 1 the version wraps to 1 (never 0, always a u32)')
    eq(calls('changed')[1].ver, 1, 'the index sees the wrapped version')
    check(pcall(Core.SceneCodec.set, id, Scene.get(id).ver, ''), 'and it encodes as I4 (no overflow)')
    check(R.diff(1, 0xFFFFFFFF) > 0 and R.diff(0xFFFFFFFF, 1) < 0, 'the serial rule: 1 is newer than 2^32 - 1')
end

--------------------------------------------------------------------------------
-- review RV1 F8: persistent nodes cannot keep `players` audiences (server ids are per session)
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Scene = Core.Scene
    eq(errOf(Scene.spawn({ kind = 'marker', pos = P0, persist = true, audience = { players = { 1 } } })), 'audience',
        'a persistent node with a players audience is refused')
    eq(errOf(Scene.spawn({ kind = 'marker', pos = P0, persist = true,
        audience = { any = { { faction = 'x' }, { players = { 1 } } } } })), 'audience', '… anywhere in the tree')
    check(Scene.spawn({ kind = 'marker', pos = P0, audience = { players = { 1 } } }) ~= nil,
        'non-persistent nodes still may')
    local p = Scene.spawn({ kind = 'marker', pos = P0, persist = true, audience = { faction = 'x' } })
    eq(errOf(Scene.set(p, nil, { audience = { players = { 3 } } })), 'audience', 'nor through Scene.set')
    H.putRow({ id = 777, kind = 'marker', owner = 'core', bucket = 0, doc = { v = 1, pos = P0, rot = ZERO,
        fields = { type = 1 }, audience = { players = { 1 } } } })          -- written before the fix
    local _, Core2 = newServer({ keepDb = true })
    local old = Core2.Scene.get(777)
    check(old and old.audience and old.audience.editors == true and old.audience.players == nil,
        'an old players audience reloads fail-closed as editors-only')
end

--------------------------------------------------------------------------------
-- review RV1 F10: the interaction cooldown map is bounded without ever forgetting a running cooldown
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Scene = Core.Scene
    Scene.defineKind({ id = 'core:slot', class = 'data' })
    H.player(env, 1, P0)
    local reward = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', interact = { { action = 'collect',
        cooldownMs = 60000 } } })
    local fired, slotHits = 0, 0
    Scene.onInteract(reward, function() fired = fired + 1 end)
    Scene.onInteract('core:slot', function() slotHits = slotHits + 1 end)
    local function four(ms)
        return { { action = 'a', cooldownMs = ms }, { action = 'b', cooldownMs = ms }, { action = 'c',
            cooldownMs = ms },
            { action = 'd', cooldownMs = ms } }
    end
    local free, busy = {}, {}
    for i = 1, 16 do
        free[i] = Scene.spawn({ kind = 'core:slot', pos = P0, interact = four(0) })
        busy[i] = Scene.spawn({ kind = 'core:slot', pos = P0, interact = four(60000) })
    end
    stubs.tick(300)
    H.interact(env, 1, reward, 'collect')
    for i = 1, 16 do
        for _, a in ipairs({ 'a', 'b', 'c', 'd' }) do
            stubs.tick(260)
            H.interact(env, 1, free[i], a)
        end
    end
    stubs.tick(260)
    H.interact(env, 1, reward, 'collect')
    check(fired == 1 and slotHits == 64, '64 other interactions never reset a running 60 s cooldown')
    slotHits = 0
    for i = 1, 16 do
        for _, a in ipairs({ 'a', 'b', 'c', 'd' }) do
            stubs.tick(260)
            H.interact(env, 1, busy[i], a)
        end
    end
    eq(slotHits, 63, '64 cooldowns running (the reward + 63): the 64th new key is refused, none is forgotten')
    stubs.tick(260)
    H.interact(env, 1, reward, 'collect')
    eq(fired, 1, 'the reward is still cooling down')
    stubs.tick(60000)
    H.interact(env, 1, busy[16], 'd')
    H.interact(env, 1, reward, 'collect')
    eq(slotHits, 64, 'once they expire, expired entries are evicted and new keys fit')
end

--------------------------------------------------------------------------------
-- review RV1 F13: foreign parents need the owner's consent; per-owner global slots; kind ids per plugin
--------------------------------------------------------------------------------
do
    local _, Core = newServer({ config = function(C) C.Scene.Global.MaxPerOwner = 2 end })
    local Scene = Core.Scene
    local rootA = as('pluginA', 'spawn', { kind = 'group', pos = P0 })
    eq(errOf(as('pluginB', 'spawn', { kind = 'light', parent = rootA })), 'owner',
        "no child under another resource's node by default (spawn)")
    local nb = as('pluginB', 'spawn', { kind = 'prop', pos = P0, model = 'm' })
    eq(errOf(as('pluginB', 'attach', nb, { node = rootA })), 'owner', '… nor by attach')
    check(Scene.spawn({ kind = 'light', parent = rootA }) ~= nil, 'core may')
    eq(errOf(as('pluginB', 'set', rootA, nil, { allowChildren = true })), 'owner', 'only the owner changes the consent')
    eq(as('pluginA', 'set', rootA, nil, { allowChildren = { 'pluginB' } }), true, 'the owner allows pluginB')
    eq(Scene.get(rootA).allowChildren[1], 'pluginB', 'stored')
    eq(as('pluginB', 'attach', nb, { node = rootA }), true, 'now pluginB may attach')
    eq(errOf(as('pluginC', 'spawn', { kind = 'light', parent = rootA })), 'owner', 'pluginC still may not')
    eq(errOf(as('pluginA', 'set', rootA, nil, { allowChildren = { 'bad name!' } })), 'allowChildren',
        'a bad list is refused')
    as('pluginA', 'set', rootA, nil, { allowChildren = true })
    check(as('pluginC', 'spawn', { kind = 'light', parent = rootA }) ~= nil,
        'allowChildren = true admits every resource')
    eq(errOf(Scene.spawn({ kind = 'group', pos = P0, allowChildren = 5 })), 'allowChildren', 'spawn validates it')
    check(as('greedy', 'spawn', { kind = 'marker', pos = P0, global = true })
        and as('greedy', 'spawn', { kind = 'marker', pos = P0, global = true }), 'two global nodes')
    eq(errOf(as('greedy', 'spawn', { kind = 'marker', pos = P0, global = true })), 'limit',
        'Global.MaxPerOwner (2 here)')
    check(as('police', 'spawn', { kind = 'marker', pos = P0, global = true }) ~= nil,
        'another resource still gets a slot')
    check(Scene.spawn({ kind = 'marker', pos = P0, global = true }) and Scene.spawn({ kind = 'marker', pos = P0,
        global = true })
        and Scene.spawn({ kind = 'marker', pos = P0, global = true }), 'core is bound by Global.MaxNodes only')
    local g = Scene.list({ owner = 'greedy' })[1]
    Scene.remove(g)
    check(as('greedy', 'spawn', { kind = 'marker', pos = P0, global = true }) ~= nil, 'a removal frees the slot')
    local n = 0
    for i = 1, 257 do if as('gen', 'defineKind', { id = 'gen:k' .. i, class = 'data' }) then n = n + 1 end end
    eq(n, 256, 'a plugin introduces at most 256 kind ids per session')
    eq(errOf(as('gen', 'defineKind', { id = 'gen:k300', class = 'data' })), 'limit', 'the next new id is refused')
    eq(as('gen', 'defineKind', { id = 'gen:k1', class = 'data', radius = 50 }), true,
        'redefining a known id still works')
    eq(as('other', 'defineKind', { id = 'other:k1', class = 'data' }), true, 'another plugin has its own quota')
    eq(errOf(as('gen', 'defineKind', { id = 'other:k2', class = 'data' })), 'id',
        "a plugin defines '<its name>:*' only")
end
do
    local _, Core = newServer()
    local root = Core.Scene.spawn({ kind = 'group', pos = P0, persist = true, allowChildren = { 'decor' } })
    stubs.tick(1000)
    local _, Core2 = newServer({ keepDb = true })
    eq(Core2.Scene.get(root).allowChildren[1], 'decor', 'allowChildren survives a restart')
    check(as('decor', 'spawn', { kind = 'light', parent = root }) ~= nil, '… and still admits that resource')
end

--------------------------------------------------------------------------------
-- review RV1 F20: a { net } attachment keeps its entity's identity; it ends when the entity is gone
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local car = stubs.newEntity(2, { model = 777 })
    stubs.coords[car] = stubs.vector3(P0.x + 10, P0.y, P0.z)
    local net = stubs.entities[car].netId
    local id = Scene.spawn({ kind = 'prop', pos = P0, model = 'm' })
    eq(Scene.attach(id, { net = net }, { offset = { x = 0, y = 0, z = 1 } }), true, 'attach to a net entity')
    eq(store.pose(store.get(id)), P0.x + 10, 'the node follows its entity')
    stubs.entities[car].exists = false
    local other = stubs.newEntity(2, { model = 777 })
    stubs.entities[other].netId = net                                -- the server hands the net id on
    stubs.coords[other] = stubs.vector3(P0.x + 500, P0.y, P0.z)
    eq(store.pose(store.get(id)), P0.x + 10, 'a reused net id never moves it: the pose holds at the last one seen')
    reset()
    stubs.tick(1000)
    local n = Scene.get(id)
    check(n.attach == nil and n.pos.x == P0.x + 10 and n.pos.z == P0.z + 1,
        'the watcher ends the attachment at the last pose')
    eq(trace(), ('changed:%d:attach changed:%d:move'):format(id, id), '… with changed(attach) + changed(move)')
    local van = stubs.newEntity(2, { model = 5 })
    stubs.coords[van] = stubs.vector3(P0.x + 20, P0.y, P0.z)
    Scene.attach(id, { net = stubs.entities[van].netId })
    stubs.entities[van].model = 6                                   -- the same handle now names another model
    stubs.coords[van] = stubs.vector3(P0.x + 90, P0.y, P0.z)
    eq(store.pose(store.get(id)), P0.x + 20, 'a changed model is another entity: the pose holds')
    stubs.tick(1000)
    eq(Scene.get(id).attach, nil, 'and the attachment ends')
    local bus = stubs.newEntity(2, { model = 9 })
    Scene.attach(id, { net = stubs.entities[bus].netId })
    Scene.remove(id)
    stubs.tick(2000)
    check(#stubs.failures == 0, 'a removed node leaves the watcher quietly')
end

--------------------------------------------------------------------------------
-- review RV1 F11 / F21: focus only for connected players; a dropped player leaves nothing behind
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Scene = Core.Scene
    eq(as('cam', 'setFocus', 9, P0), false, 'no focus pin for a src nobody is connected as')
    H.player(env, 9, P0)
    eq(as('cam', 'setFocus', 9, P0), true, 'a connected player')
    local id = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', interact = { { action = 'use',
        cooldownMs = 60000 } } })
    local hits = 0
    Scene.onInteract(id, function() hits = hits + 1 end)
    Scene.attach(Scene.spawn({ kind = 'prop', pos = P0, model = 'm' }), { player = 9 })
    stubs.tick(300)
    H.interact(env, 9, id, 'use')
    stubs.dropPlayer(env, 9)
    eq(Core.Registry.getOwned('cam'), nil, 'the focus entry goes with the player')
    eq(#Scene.list({ kind = 'prop' }) == 2 and Scene.get(Scene.list({ kind = 'prop' })[2]).attach, nil,
        'the player attachment ends')
    H.player(env, 9, P0)
    stubs.tick(300)
    H.interact(env, 9, id, 'use')
    eq(hits, 2, 'a new player with the same src starts without cooldowns')
end

--------------------------------------------------------------------------------
-- review integration C1: R.promote.refuses / beforeChange / the clone's pose / stats
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    H.fakePromote(R)
    local id = Scene.spawn({ kind = 'prop', pos = P0, model = 'm' })
    local car = Scene.spawn({ kind = 'vehicle', pos = P0, model = 'adder' })
    local g = Scene.spawn({ kind = 'group', pos = P0 })
    Scene.move(id, at(1, 0, 0))
    eq(H.promoteLog[1].x, P0.x, 'beforeChange runs before the change')
    Scene.motion(id, { t = 'spin', dps = 1 })
    Scene.set(id, { tint = 1 })
    Scene.set(id, nil, { interact = { { action = 'x' } } })
    Scene.set(id, nil, { audience = { faction = 'f' } })
    Scene.set(id, nil, { radius = 50 })
    Scene.set(id, { tint = 1 })
    Scene.drive(car, P0, ZERO, 0)
    Scene.attach(id, { node = g })
    Scene.detach(id)
    Scene.detach(id)
    Scene.remove(g)
    local seq = {}
    for i, c in ipairs(H.promoteLog) do seq[i] = c.what end
    eq(table.concat(seq, ','), 'move,motion,set,drive,attach,detach',
        'beforeChange: move / motion / a fields set / drive / attach / detach — never interact / audience / '
            .. 'radius, a no-op or a remove')
    H.player(env, 1, P0)
    local use = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', interact = { { action = 'use', distance = 2 } } })
    local hits = 0
    Scene.onInteract(use, function() hits = hits + 1 end)
    H.refuse['1:' .. use] = true
    stubs.tick(300)
    H.interact(env, 1, use, 'use')
    eq(hits, 0, 'R.promote.refuses (a lease of another player) refuses before the dispatch')
    H.refuse['1:' .. use] = nil
    stubs.tick(300)
    H.interact(env, 1, use, 'use')
    eq(hits, 1, 'otherwise it is dispatched')
    local clone = stubs.newEntity(2, { model = 5 })
    stubs.coords[clone] = stubs.vector3(P0.x + 50, P0.y, P0.z)
    stubs.entities[clone].rot, stubs.entities[clone].sn = { x = 0, y = 0, z = 90 }, use
    store.get(use).promoted = { netId = stubs.entities[clone].netId, entity = clone, since = 0 }
    local x, _, _, _, _, rz = store.pose(store.get(use))
    check(x == P0.x + 50 and rz == 90, "a promoted node's pose is its clone's (R.promote.ours)")
    stubs.tick(300)
    H.interact(env, 1, use, 'use')
    eq(hits, 1, 'the interaction distance uses the clone: 50 m away now')
    H.movePlayer(1, at(50, 0, 0))
    stubs.tick(300)
    H.interact(env, 1, use, 'use')
    eq(hits, 2, '… and succeeds next to it')
    stubs.entities[clone].sn = 999
    eq(store.pose(store.get(use)), P0.x, 'a clone that is not ours (a reused handle) is ignored')
    local st = Scene.stats()
    check(st.promote and st.promote.promoted == 0 and st.audio == nil and st.voice == nil,
        'stats carry promote / audio / voice (nil while missing)')
end

--------------------------------------------------------------------------------
-- review integration B2: R.audio.admit(payload, owner) runs last, for audio kinds, and its code comes back
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local Scene = Core.Scene
    local seen = {}
    R.audio = { admit = function(def, owner)
        seen[#seen + 1] = def.kind .. ':' .. owner
        if def.fields.title == 'no' then return false, 'audio_rate' end
        return true
    end }
    local sid = as('radio', 'spawn', { kind = 'audio.source', fields = { file = '@r/a.ogg' } })
    check(sid ~= nil and seen[1] == 'audio.source:radio', 'admit(payload, owner) for an audio source')
    eq(select(2, as('radio', 'spawn', { kind = 'audio.source', fields = { file = '@r/a.ogg', title = 'no' } })),
        'audio_rate', 'its refusal code comes back unchanged')
    Scene.spawn({ kind = 'marker', pos = P0 })
    Scene.spawn({ kind = 'audio.source', fields = { url = 'http://plain' } })
    eq(#seen, 2, 'other kinds and invalid spawns never reach it (every pass costs a token)')
    local hook = Core.Hooks.register('scene:beforeSpawn', function() return false, 'nope' end)
    eq(errOf(Scene.spawn({ kind = 'audio.source', fields = { file = '@r/b.ogg' } })), 'hook', 'a hook veto comes first')
    eq(#seen, 2, '… so admit is not asked')
    Core.Hooks.remove(hook)
    check(Scene.spawn({ kind = 'audio', pos = P0, fields = { source = sid } }) ~= nil and seen[3] == 'audio:core',
        'emitters (class audio) are asked too')
    R.audio = nil
    check(Scene.spawn({ kind = 'audio.source', fields = { file = '@r/c.ogg' } }) ~= nil, 'without R.audio: skipped')
end

--------------------------------------------------------------------------------
-- DESIGN §55.21.2 (phase D): descriptor `prompt`, prop field `snap = 'ground'` — the inventory drop node
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local Scene, K, store = Core.Scene, R.kinds, R.store
    local function spawnWith(prompt)
        return Scene.spawn({ kind = 'marker', pos = P0, interact = { { action = 'use', prompt = prompt } } })
    end
    local id = spawnWith({ world = true, offsetZ = 0.35, range = 12 })
    local d = Scene.get(id).interact[1]
    check(d.prompt and d.prompt.world == true and d.prompt.offsetZ == 0.35 and d.prompt.range == 12,
        'a descriptor keeps its prompt options')
    eq(store.get(id).interact[1].prompt.range, 12,
        'the node record carries them unchanged (the index sends node.interact)')
    local p2 = Scene.get(spawnWith({ world = false })).interact[1].prompt
    check(p2.world == false and p2.offsetZ == nil and p2.range == nil, 'every prompt key is optional')
    eq(Scene.get(spawnWith({})).interact[1].prompt, nil, 'an empty prompt is dropped')
    local bad = { 'x', { world = 1 }, { offsetZ = 5.5 }, { offsetZ = -6 }, { range = 0.5 }, { range = 51 },
        { range = 0 / 0 }, { size = 3 }, setmetatable({}, {}) }
    for i, b in ipairs(bad) do eq(select(2, spawnWith(b)), 'interact', 'a bad prompt is refused (' .. i .. ')') end
    check(spawnWith({ offsetZ = -5, range = 50 }) ~= nil and spawnWith({ offsetZ = 5, range = 1 }) ~= nil,
        'the bounds are inclusive (offsetZ -5..5, range 1..50)')
    check(K.check(K.get('prop'), { model = 'm', snap = 'ground' }, false), "prop snap = 'ground'")
    local _, e1 = K.check(K.get('prop'), { model = 'm', snap = 'water' }, false)
    eq(e1 and e1.snap, 'option', 'snap is the enum { ground }')
    local _, e2 = K.check(K.get('marker'), { snap = 'ground' }, false)
    eq(e2 and e2.snap, 'unknown', 'only props have it')
    eq(select(2, K.check(K.get('prop'), { model = 'm' }, false)).snap, nil, 'snap has no default')
    local drop = as('inventory', 'spawn', { kind = 'prop', pos = P0, bucket = 0, rot = { x = 0, y = 0, z = 135 },
        fields = { model = 'prop_cs_box_clothes', frozen = true, collision = false, snap = 'ground' },
        interact = { { action = 'pickup', label = 'Water x3', distance = 2.5,
            prompt = { world = true, offsetZ = 0.2, range = 8 } } } })
    local dn = drop and Scene.get(drop)
    check(dn and dn.fields.snap == 'ground' and dn.fields.collision == false and dn.interact[1].prompt.world == true,
        'the drop node of §55.21.2 spawns')
    reset()
    eq(as('inventory', 'set', drop, {}, { interact = { { action = 'pickup', label = 'Water x2', distance = 2.5,
        prompt = { world = true, range = 8 } } } }), true, 'a count change = Scene.set(id, {}, { interact = … })')
    eq(trace(), 'changed:' .. drop .. ':interact', '… only the descriptors travel (no fields SET)')
    local after = Scene.get(drop).interact[1]
    check(after.label == 'Water x2' and after.prompt.offsetZ == nil and after.prompt.range == 8,
        'the new descriptor (and its prompt) replaced the old one')
    eq(errOf(as('inventory', 'set', drop, {}, { interact = { { action = 'pickup', prompt = { range = 99 } } } })),
        'interact', 'Scene.set validates the prompt too')
    local kept = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', persist = true, fields = { snap = 'ground' },
        interact = { { action = 'use', prompt = { world = false, offsetZ = -1 } } } })
    stubs.tick(1000)
    local _, Core2 = newServer({ keepDb = true })
    local k2 = Core2.Scene.get(kept)
    local kp = k2 and k2.interact[1].prompt
    check(k2 and k2.fields.snap == 'ground' and kp.world == false and kp.offsetZ == -1,
        'snap and the prompt survive a restart')
end

--------------------------------------------------------------------------------
-- phase-D integration fixes (run I1) — 1. mapEl / mapType on the kinds Core.Maps projects onto (§55.21.1)
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer()
    local Scene, K = Core.Scene, R.kinds
    local uid, typ = 'downtown_2:123456789', 'core:physprop'
    local function defOf(kind, fields)
        local f = fields or {}
        if kind == 'prop' then f.model = 'prop_bench_01a'
        elseif kind == 'vehicle' then f.model = 'adder'
        elseif kind == 'ped' then f.model = 'a_m_y_skater_01'
        elseif kind == 'hide' then f.model = 'prop_bin_01a' end
        return { kind = kind, pos = P0, fields = f }
    end
    for _, kind in ipairs({ 'prop', 'vehicle', 'ped', 'marker', 'hide' }) do
        local id, err = Scene.spawn(defOf(kind, { mapEl = uid, mapType = typ }))
        local n = id and Scene.get(id)
        check(n and n.fields.mapEl == uid and n.fields.mapType == typ,
            kind .. ': mapEl / mapType are accepted (' .. tostring(err) .. ')')
        local nf = K.get(kind).nearFields
        check(not nf.mapEl and not nf.mapType, kind .. ': neither is a near field (every variant carries them)')
        check(Scene.spawn(defOf(kind, { mapEl = string.rep('a', 48), mapType = string.rep('t', 64) })) ~= nil,
            kind .. ': mapEl <= 48 and mapType <= 64 characters')
        local _, e1, d1 = Scene.spawn(defOf(kind, { mapEl = string.rep('a', 49) }))
        check(e1 == 'fields' and d1 and d1.mapEl == 'length', kind .. ': a 49-character mapEl is refused')
        local _, e2, d2 = Scene.spawn(defOf(kind, { mapType = string.rep('t', 65) }))
        check(e2 == 'fields' and d2 and d2.mapType == 'length', kind .. ': a 65-character mapType is refused')
        local _, e3, d3 = Scene.spawn(defOf(kind, { mapEl = 5 }))
        check(e3 == 'fields' and d3 and d3.mapEl == 'type', kind .. ': mapEl is a string')
        for _, e in ipairs(K.table(0)) do
            if e.id == kind then check(e.meta.near == nil, kind .. ': KINDS meta lists no near fields') end
        end
    end
    local _, lerr = K.check(K.get('light'), { mapEl = uid }, false)
    eq(lerr and lerr.mapEl, 'unknown', 'kinds Maps never projects onto have no mapEl')
    local id = Scene.spawn(defOf('prop', { mapEl = uid, mapType = typ }))
    eq(Scene.set(id, { mapEl = 'downtown_2:7' }), true, 'Scene.set changes mapEl')
    eq(Scene.get(id).fields.mapEl, 'downtown_2:7', '... stored')
    eq(Scene.set(id, {}, { remove = { 'mapEl', 'mapType' } }), true, 'and removes both')
    check(Scene.get(id).fields.mapEl == nil and Scene.get(id).fields.mapType == nil, '... gone')
end

-- the REAL index: both fields travel in every variant a node materialises from (NEAR, FAR of an M root, ONE)
do
    local _, Core, R = newServer({ beforeStore = function(env) stubs.loadFile(env, 'server/scene_index.lua') end })
    local Scene, I, Codec = Core.Scene, R.index, Core.SceneCodec
    check(I.pack ~= nil and I.drain ~= nil, 'the real server/scene_index.lua replaced the recording fake')
    local function tag(n) return { mapEl = 'dt:' .. n, mapType = 'core:t' .. n } end
    local m = Scene.spawn({ kind = 'prop', pos = P0, model = 'prop_bench_01a', fields = tag(1) })   -- 255 m: M
    local l = Scene.spawn({ kind = 'vehicle', pos = at(5, 0, 0), model = 'adder', radius = 1000, fields = tag(2) })
    local s = Scene.spawn({ kind = 'marker', pos = at(0, 5, 0), fields = tag(3) })                  -- 80 m: S
    local h = Scene.spawn({ kind = 'hide', pos = at(0, 9, 0), fields = { model = 'x', mapEl = 'dt:4',
        mapType = 'core:t4' } })                                                                       -- 202 m: M
    eq(Scene.get(m).tier .. Scene.get(l).tier .. Scene.get(s).tier .. Scene.get(h).tier, 'MLSM', 'the tiers')
    local function extras(blob)
        local out = {}
        local function onPut(id, ...) out[id] = select(12, ...) end   -- extra = the 13th argument
        local okd, err = Codec.decode(Codec.header(0) .. blob, { put = onPut })
        check(okd, 'the pack decodes (' .. tostring(err) .. ')')
        return out
    end
    local near = extras(I.pack(0, 0, I.keyOf(0, P0.x, P0.y), 1))
    local far = extras(I.pack(0, 0, I.keyOf(0, P0.x, P0.y), 2))
    local one = extras(I.pack(0, 1, I.keyOf(1, P0.x + 5, P0.y), 3))
    for _, c in ipairs({ { near, m, 1, 'NEAR: the M prop' }, { near, s, 3, 'NEAR: the S marker' },
        { near, h, 4, 'NEAR: the M hide' }, { far, m, 1, 'FAR: the M prop' }, { far, h, 4, 'FAR: the M hide' },
        { one, l, 2, 'ONE (far region): the L vehicle' } }) do
        local x = c[1][c[2]]
        check(x and x.f and x.f.mapEl == 'dt:' .. c[3] and x.f.mapType == 'core:t' .. c[3], c[4] .. ' carries both')
    end
    eq(far[s], nil, 'an S node is in no FAR variant (it materialises from NEAR only)')
end

--------------------------------------------------------------------------------
-- phase-D integration fixes (run I1) — 3. rotOrder: children, attach, move, detach, copies, persistence
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local root = Scene.spawn({ kind = 'group', pos = P0 })
    local c = Scene.spawn({ kind = 'prop', parent = root, model = 'm', offset = { x = 0, y = 0, z = 1 }, rotOrder = 1 })
    eq(store.get(c).rotOrder, 1, 'a child keeps its rotOrder')
    eq(Scene.get(c).rotOrder, 1, '... and Scene.get copies it')
    eq(Scene.get(Scene.spawn({ kind = 'prop', parent = root, model = 'm' })).rotOrder, nil,
        'no rotOrder = nil (the engine default 2)')
    check(Scene.spawn({ kind = 'prop', parent = root, model = 'm', rotOrder = 0 }) ~= nil
        and Scene.spawn({ kind = 'prop', parent = root, model = 'm', rotOrder = 5 }) ~= nil, 'the range is 0..5')
    for _, bad in ipairs({ -1, 6, 1.5, '1', true, 0 / 0 }) do
        eq(errOf(Scene.spawn({ kind = 'prop', parent = root, model = 'm', rotOrder = bad })), 'rotOrder',
            'spawn refuses rotOrder ' .. tostring(bad))
    end
    eq(Scene.spawn({ kind = 'prop', parent = root, model = 'm', rotOrder = 3.0 }) and 'ok', 'ok',
        'an integral float is the integer')
    local r2 = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', rotOrder = 4 })
    eq(Scene.get(r2).rotOrder, nil, 'a root ignores rotOrder (like offset / bone: a child or attachment matter)')
    -- attach
    local b = Scene.spawn({ kind = 'prop', pos = at(10, 0, 0), model = 'm' })
    eq(Scene.attach(b, { node = root }, { offset = { x = 1, y = 0, z = 0 }, rotOrder = 0 }), true,
        'attach to a node with rotOrder 0')
    eq(store.get(b).rotOrder, 0, '... kept (0 is a value)')
    eq(errOf(Scene.attach(b, { node = root }, { rotOrder = 9 })), 'rotOrder', 'attach refuses rotOrder 9')
    eq(store.get(b).rotOrder, 0, '... and changes nothing')
    Scene.attach(b, { node = root }, { offset = { x = 2, y = 0, z = 0 } })
    eq(store.get(b).rotOrder, nil, 'a new attach without rotOrder is the default again')
    H.player(env, 4, at(0, 20, 0))
    reset()
    eq(Scene.attach(r2, { player = 4 }, { bone = 28422, rotOrder = 1 }), true, 'attach to a player with rotOrder 1')
    eq(store.get(r2).rotOrder, 1, '... stored')
    eq(trace(), 'changed:' .. r2 .. ':attach', "one 'attach' change (the index re-sends the whole node)")
    -- move: a child's / attached node's offset; the order is kept unless opts.rotOrder names one
    reset()
    eq(Scene.move(r2, { x = 0, y = 0, z = 0.5 }, { x = 0, y = 0, z = 90 }), true, 'move an attached node (offset)')
    eq(store.get(r2).rotOrder, 1, 'a move without rotOrder keeps the order')
    eq(Scene.move(r2, { x = 0, y = 0, z = 0.5 }, nil, { rotOrder = 5 }), true, 'a move with rotOrder 5')
    eq(store.get(r2).rotOrder, 5, '... sets it')
    eq(trace(), ('changed:%d:move changed:%d:move'):format(r2, r2), "each a 'move' change (a whole PUT)")
    eq(errOf(Scene.move(r2, { x = 0, y = 0, z = 0.5 }, nil, { rotOrder = 'x' })), 'rotOrder', 'move refuses a bad one')
    eq(store.get(r2).rotOrder, 5, '... and changes nothing')
    Scene.move(c, { x = 0, y = 0, z = 2 }, nil, { rotOrder = 2 })
    eq(store.get(c).rotOrder, 2, "a child's move sets it too")
    -- detach
    Scene.detach(r2)
    eq(store.get(r2).rotOrder, nil, 'detaching from a player drops it')
    Scene.detach(c)
    eq(store.get(c).rotOrder, nil, 'a detached child drops it')
    stubs.dropPlayer(env, 4)
end

do  -- persistence: a persistent child keeps its rotOrder across a restart
    local _, Core = newServer()
    local Scene = Core.Scene
    local root = Scene.spawn({ kind = 'group', pos = P0, persist = true })
    local kid = Scene.spawn({ kind = 'prop', parent = root, model = 'm', persist = true, rotOrder = 4, bone = 'b1' })
    local plain = Scene.spawn({ kind = 'prop', parent = root, model = 'm', persist = true })
    stubs.tick(1000)
    local doc = H.doc(kid)
    eq(doc.rotOrder, 4, 'the document stores rotOrder (like bone)')
    eq(H.doc(plain).rotOrder, nil, '... only when set')
    local _, Core2, R2 = newServer({ keepDb = true })
    local n = R2.store.get(kid)
    check(n and n.rotOrder == 4 and n.bone == 'b1', 'the reloaded child has its rotOrder and bone')
    eq(R2.store.get(plain).rotOrder, nil, 'the other one none')
    eq(Core2.Scene.get(kid).rotOrder, 4, 'Scene.get after the reload')
end

--------------------------------------------------------------------------------
-- phase-D integration fixes (run I1) — 7. Config.Scene.OwnerCaps; 6. no hook bookkeeping left per removed node
--------------------------------------------------------------------------------
do
    local _, Core = newServer({ config = function(Config)
        Config.Scene.MaxNodesPerOwner, Config.Scene.OwnerCaps = 3, { big = 5, core = 4 }
    end })
    local Scene = Core.Scene
    for i = 1, 5 do check(as('big', 'spawn', { kind = 'marker', pos = P0 }) ~= nil, 'OwnerCaps.big: node ' .. i) end
    eq(errOf(as('big', 'spawn', { kind = 'marker', pos = P0 })), 'limit', 'OwnerCaps.big = 5: the sixth is refused')
    for i = 1, 3 do check(as('small', 'spawn', { kind = 'marker', pos = P0 }) ~= nil, 'MaxNodesPerOwner: node ' .. i) end
    eq(errOf(as('small', 'spawn', { kind = 'marker', pos = P0 })), 'limit',
        'an owner without an entry: MaxNodesPerOwner (3)')
    for i = 1, 4 do check(Scene.spawn({ kind = 'marker', pos = P0 }) ~= nil, 'OwnerCaps.core: node ' .. i) end
    eq(errOf(Scene.spawn({ kind = 'marker', pos = P0 })), 'limit', 'core is bound by its OwnerCaps entry (4) too')
    Scene.remove(Scene.list({ owner = 'big' })[1])
    check(as('big', 'spawn', { kind = 'marker', pos = P0 }) ~= nil, 'a removal frees a slot under the cap')
end

do  -- the shipped config: core gets 60,000, everyone else MaxNodesPerOwner
    local env = newServer()
    local caps = env.Config.Scene.OwnerCaps
    eq(type(caps) == 'table' and caps.core, 60000, 'Config.Scene.OwnerCaps = { core = 60000 }')
end

do  -- OwnerCaps not a table: MaxNodesPerOwner for everyone
    local _, Core = newServer({ config = function(Config)
        Config.Scene.MaxNodesPerOwner, Config.Scene.OwnerCaps = 2, 'x'
    end })
    check(Core.Scene.spawn({ kind = 'marker', pos = P0 }) and Core.Scene.spawn({ kind = 'marker', pos = P0 }), 'two')
    eq(errOf(Core.Scene.spawn({ kind = 'marker', pos = P0 })), 'limit', 'a malformed OwnerCaps is ignored')
end

do  -- 1,000 nodes that come and go with a pickup handler and a listener of their own: nothing stays behind
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local base = store.hookStats()
    local fired = 0
    for _ = 1, 1000 do
        local id = as('drops', 'spawn', { kind = 'prop', pos = P0, model = 'm', interact = { { action = 'pickup' } } })
        local hi = as('drops', 'onInteract', id, function() fired = fired + 1 end)
        local hl = as('drops', 'on', 'changed', id, function() end)
        local hr = as('drops', 'on', 'removed', id, function() end)
        as('drops', 'off', hi)
        as('drops', 'off', hl)
        as('drops', 'off', hr)
        as('drops', 'remove', id)
    end
    local st = store.hookStats()
    check(st.handles == base.handles and st.interactKeys == base.interactKeys and st.listenKeys == base.listenKeys
        and st.listenEvents == base.listenEvents,
        ('1,000 add / remove cycles leave no keys (handles %d, interact keys %d, listen keys %d, events %d)')
            :format(st.handles, st.interactKeys, st.listenKeys, st.listenEvents))
    eq(st.interactKeys, 0, 'no interactBy[id] list is left')
    eq(st.listenEvents, 0, 'no listen[event] map is left')
    -- the owner-stop path drops the same way; a shared key keeps its list while one handle remains
    local ids = {}
    for i = 1, 50 do
        ids[i] = as('drops', 'spawn', { kind = 'marker', pos = P0 })
        as('drops', 'onInteract', ids[i], function() end)
        as('drops', 'on', 'spawned', ids[i], function() end)
    end
    local keep = as('shop', 'on', 'changed', 'marker', function() end)
    local k1 = as('shop', 'on', 'removed', 'marker', function() end)
    local k2 = as('shop', 'on', 'removed', 'marker', function() end)
    as('shop', 'off', k1)
    eq(store.hookStats().listenKeys, 50 + 2, 'a key list with a handle left stays')
    stop(env, 'drops')
    st = store.hookStats()
    check(st.interactKeys == 0 and st.listenKeys == 2 and st.listenEvents == 2 and st.handles == 2,
        ('an owner stop leaves only the other owner\'s lists (%d / %d / %d / %d)'):format(st.interactKeys,
            st.listenKeys, st.listenEvents, st.handles))
    as('shop', 'off', keep)
    as('shop', 'off', k2)
    st = store.hookStats()
    check(st.handles == 0 and st.listenKeys == 0 and st.listenEvents == 0, 'the last off empties everything')
    local again = as('shop', 'on', 'changed', 'marker', function() fired = fired + 1 end)
    Scene.set(Scene.spawn({ kind = 'marker', pos = P0 }), { bob = true })
    eq(fired, 1, 'a listener added after its list was dropped still fires')
    as('shop', 'off', again)
end

--------------------------------------------------------------------------------
-- phase-D integration fixes (run I1) — 9. the vehicle kind of parked cars (§55.21.4): vehId, plates with a dash,
-- integer model hashes (prop / ped too), an INPUT vtype (kept; the model info fills it only when absent)
--------------------------------------------------------------------------------
do
    local _, Core, R = newServer({ maps = true })
    local Scene, K = Core.Scene, R.kinds
    local function veh(fields, extra)
        local d = { kind = 'vehicle', pos = P0, fields = fields }
        for k, v in pairs(extra or {}) do d[k] = v end
        return Scene.spawn(d)
    end
    local function fieldErr(kind, fields)
        local _, err, detail = Scene.spawn({ kind = kind, pos = P0, fields = fields })
        return err == 'fields' and detail or {}
    end
    local id = veh({ model = 'adder', vehId = 'veh:12_ab-3', plate = 'LS 12-34' })
    local n = id and Scene.get(id)
    check(n and n.fields.vehId == 'veh:12_ab-3' and n.fields.plate == 'LS 12-34',
        "vehId, and a plate with a dash and a space (core's default 'LS-' plates)")
    eq(fieldErr('vehicle', { model = 'adder', vehId = 'veh 1' }).vehId, 'pattern', "vehId '^[%w_%-:]+$'")
    eq(fieldErr('vehicle', { model = 'adder', vehId = string.rep('v', 65) }).vehId, 'length', 'vehId <= 64')
    eq(fieldErr('vehicle', { model = 'adder', plate = 'AB!' }).plate, 'pattern', 'plate: letters, digits, space, dash')
    -- integer model hashes: kept as they are
    local HASH = -1216765807
    local vid = veh({ model = HASH })
    eq(vid and Scene.get(vid).fields.model, HASH, 'an integer model hash is kept as is')
    eq(vid and math.type(Scene.get(vid).fields.model), 'integer', '... as an integer')
    eq(Scene.get(veh({ model = 3078201489 })).fields.model, 3078201489, '... the unsigned form too')
    eq(Scene.get(Scene.spawn({ kind = 'vehicle', pos = P0, model = HASH + 0.0 })).fields.model, HASH,
        'an integral float (a JSON round trip) becomes the integer')
    for _, bad in ipairs({ 0, 1.5, math.tointeger(2 ^ 40), -0x80000001 }) do
        eq(fieldErr('vehicle', { model = bad }).model, 'type', 'model ' .. tostring(bad) .. ' is refused')
    end
    eq(Scene.get(Scene.spawn({ kind = 'prop', pos = P0, model = 0x51A7 })).fields.model, 0x51A7, 'a prop takes one')
    eq(Scene.get(Scene.spawn({ kind = 'ped', pos = P0, model = -1 })).fields.model, -1, 'a ped too')
    eq(fieldErr('ped', { model = 'p', weapon = 5 }).weapon, 'type', "the ped's weapon field stays a name")
    local pn = Scene.get(Scene.spawn({ kind = 'prop', pos = P0, model = 0x51A7 }))
    check(pn.fields.lod == 100 and pn.fields.r == 2, 'an integer prop model gets the model info (defaults here)')
    eq(K.modelInfo('vehicle', HASH).vtype, 'automobile', 'modelInfo takes integers: the Maps validator knows names only')
    check(K.modelInfo('vehicle', 0) == nil and K.modelInfo('vehicle', 2.5) == nil, '... never 0 or a fraction')
    local asked = {}
    Scene.setModelInfo(function(kind, model)
        asked[#asked + 1] = kind .. ':' .. tostring(model) .. ':' .. (math.type(model) or type(model))
        if model == 777 then return { vehicleType = 'heli' } end
        if model == 'blimpy' then return { vehicleType = 'blimp' } end
        if model == 'amphi' then return { vehicleType = 'amphibious_automobile' } end
        if model == 'hover' then return { vehicleType = 'hovercraft' } end
    end)
    eq(K.modelInfo('vehicle', 777).vtype, 'heli', 'the provider is asked with the integer')
    K.modelInfo('vehicle', 777)
    eq(table.concat(asked, ' '), 'vehicle:777:integer', "... once: cached as 'vehicle:#777'")
    eq(K.modelInfo('vehicle', '777').vtype, 'automobile', "the NAME '777' is another key than the hash 777")
    eq(K.modelInfo('vehicle', 'blimpy').vtype, 'heli', 'a vehicles.meta type becomes its net type (blimp → heli)')
    eq(K.modelInfo('vehicle', 'amphi').vtype, 'automobile', 'amphibious_automobile → automobile')
    eq(K.modelInfo('vehicle', 'hover').vtype, 'automobile', 'an unknown type → the default')
    Scene.setModelInfo(nil)
    Core.MapsRuntime.setModelValidator(function(kind, model)
        if kind ~= 'vehicle' then return true, {} end
        if model == 'bati' then return true, { vehicleType = 'bike' } end
        if model == 'blimp' then return true, { vehicleType = 'blimp' } end
        return false
    end)
    -- vtype: an input is kept, the model info fills it when absent, 'automobile' last
    local function vt(fields) local v = veh(fields) return v and Scene.get(v).fields.vtype end
    eq(vt({ model = 'bati' }), 'bike', 'no vtype: filled from the model info')
    eq(vt({ model = 'nope' }), 'automobile', "... 'automobile' last (a model the validator refuses)")
    eq(vt({ model = 'adder', vtype = 'heli' }), 'heli', 'an input vtype is kept over the default')
    eq(vt({ model = 'bati', vtype = 'boat' }), 'boat', '... and over the model info')
    eq(vt({ model = HASH, vtype = 'plane' }), 'plane', '... for an integer model (what D4 parks)')
    eq(vt({ model = 'blimp' }), 'heli', "the validator's vehicles.meta type is its net type")
    for alias, net in pairs({ quadbike = 'automobile', amphibious_automobile = 'automobile',
        amphibious_quadbike = 'automobile', submarinecar = 'automobile', blimp = 'heli' }) do
        eq(vt({ model = 'adder', vtype = alias }), net, "input '" .. alias .. "' is stored as " .. net)
    end
    for _, t in ipairs({ 'automobile', 'bike', 'boat', 'heli', 'plane', 'submarine', 'trailer', 'train' }) do
        eq(vt({ model = 'adder', vtype = t }), t, "the net type '" .. t .. "' (CreateVehicleServerSetter)")
    end
    eq(fieldErr('vehicle', { model = 'adder', vtype = 'hovercraft' }).vtype, 'option', 'an unknown vtype is refused')
    local b = veh({ model = 'bati', vtype = 'boat' })
    eq(Scene.set(b, { plate = 'B 1' }), true, 'a set without a model change')
    eq(Scene.get(b).fields.vtype, 'boat', '... keeps the vtype')
    eq(Scene.set(b, { model = 'blimp' }), true, 'a model change without a vtype')
    eq(Scene.get(b).fields.vtype, 'heli', '... re-derives it (the old one described the old model)')
    eq(Scene.set(b, { model = 'bati', vtype = 'train' }), true, 'a model change with a vtype')
    eq(Scene.get(b).fields.vtype, 'train', '... keeps the patched one')
    eq(Scene.set(b, {}, { remove = { 'vtype' } }), true, 'removing the vtype')
    eq(Scene.get(b).fields.vtype, 'bike', '... fills it again from the model info')
    eq(Scene.set(b, Scene.get(b).fields), true, 'a Scene.get → Scene.set round trip is valid')
    Scene.defineKind({ id = 'core:car', class = 'vehicle', fields = { { name = 'model', type = 'model',
        required = true } } })
    local car = Scene.get(Scene.spawn({ kind = 'core:car', pos = P0, model = 'bati', fields = { vtype = 'boat' } }))
    eq(car.fields.vtype, 'bike', 'a vehicle kind without a vtype field: server-filled as before (input ignored)')
    local p = veh({ model = HASH, vtype = 'boat', vehId = 'v7' }, { persist = true })
    stubs.tick(1000)
    local _, Core2 = newServer({ keepDb = true })
    local pv = Core2.Scene.get(p)
    check(pv and pv.fields.model == HASH and math.type(pv.fields.model) == 'integer' and pv.fields.vtype == 'boat'
        and pv.fields.vehId == 'v7', 'integer model, vtype and vehId survive a restart')
end

--------------------------------------------------------------------------------
-- final fix round (FX2) — I-2: R.store.follow, a promoted root follows its clone (D-C pose, D-D bucket)
--------------------------------------------------------------------------------
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    H.fakePromote(R)
    local hooks = 0
    Scene.on('changed', '*', function() hooks = hooks + 1 end)
    local root = Scene.spawn({ kind = 'prop', pos = P0, model = 'm' })
    local kid = Scene.spawn({ kind = 'prop', parent = root, model = 'm', offset = { x = 0, y = 0, z = 1 } })
    local grand = Scene.spawn({ kind = 'light', parent = kid })
    local node = store.get(root)
    check(type(store.follow) == 'function', 'R.store.follow exists (interface I-2)')
    eq(errOf(store.follow(node, at(5, 0, 0))), 'promoted', 'a local root never follows (Scene.move is its path)')
    node.promoted = { netId = 11 }
    store.get(kid).promoted = { netId = 12 }
    eq(errOf(store.follow(store.get(kid), at(5, 0, 0))), 'parent', 'a child rides its root: it never follows alone')
    store.get(kid).promoted = nil
    H.player(env, 4, at(0, 80, 0))
    local worn = Scene.spawn({ kind = 'prop', pos = at(0, 80, 0), model = 'm' })
    Scene.attach(worn, { player = 4 })
    store.get(worn).promoted = { netId = 14 }
    eq(errOf(store.follow(store.get(worn), at(1, 80, 0))), 'parent', 'an attached node follows its target')
    local src = Scene.spawn({ kind = 'audio.source', fields = { file = '@radio/a.ogg', type = 'loop' } })
    store.get(src).promoted = { netId = 15 }
    eq(errOf(store.follow(store.get(src), at(1, 0, 0))), 'parent', 'a dependency has no pose to follow')
    eq(errOf(store.follow(Scene.get(root), at(5, 0, 0))), 'missing', 'a copy is not the stored node')
    eq(errOf(store.follow(node, { x = 1, y = 0 / 0, z = 0 })), 'pos', 'a NaN position is refused')
    eq(errOf(store.follow(node, nil, { x = 'a', y = 0, z = 0 })), 'rot', 'a bad rotation is refused')
    eq(errOf(store.follow(node, nil, nil, -1)), 'bucket', 'a bad bucket is refused')
    eq(node.pos.x .. ':' .. node.bucket, P0.x .. ':0', '... and nothing changed')
    local v0 = node.ver
    reset()
    H.promoteLog, hooks = {}, 0
    eq(store.follow(node, at(40, -3, 1), { x = 1, y = 2, z = 370 }), true, 'a promoted root follows its clone')
    check(node.pos.x == P0.x + 40 and node.pos.y == P0.y - 3 and node.pos.z == P0.z + 1, '... its base position')
    check(node.rot.x == 1 and node.rot.y == 2 and node.rot.z == 10, '... and rotation (wrapped)')
    eq(node.ver, v0 + 1, '... with a new ver')
    eq(trace(), 'changed:' .. root .. ':follow', "one 'follow' change of the index (no put, no motion)")
    eq(#H.promoteLog, 0, 'no beforeChange: nothing demotes it')
    check(node.promoted and node.promoted.netId == 11 and node.motion == nil, '... it stays promoted, no motion')
    eq(hooks, 0, 'no changed hook (following a clone is not an API change)')
    local kx, _, kz = store.pose(store.get(kid))
    check(math.abs(kx - (P0.x + 40)) < 0.1 and math.abs(kz - (P0.z + 2)) < 0.1, "the children's pose follows")
    reset()
    eq(store.follow(node, at(40.03, -3, 1), { x = 1, y = 2, z = 10.5 }), true, 'a 3 cm / 0.5° wobble is accepted')
    eq(node.ver, v0 + 1, '... but is no change (no ver)')
    eq(trace(), '', '... and no index call')
    eq(node.pos.x, P0.x + 40, '... the base keeps the followed pose (drift adds up against it)')
    eq(store.follow(node, at(40.06, -3, 1)), true, 'rot nil keeps the rotation')
    check(math.abs(node.pos.x - (P0.x + 40.06)) < 1e-9 and node.rot.z == 10, '... 6 cm is a change')
    store.follow(node, { x = 20000, y = -20000, z = -5000 })
    check(node.pos.x == 10000 and node.pos.y == -10000 and node.pos.z == -1000, 'the world bounds clamp a far clone')
    store.follow(node, at(40, -3, 1))
    reset()
    local kv, gv = store.get(kid).ver, store.get(grand).ver
    eq(store.follow(node, nil, nil, 7), true, 'the clone went to bucket 7')
    eq(node.bucket .. store.get(kid).bucket .. store.get(grand).bucket, '777', 'the root moves WITH its subtree')
    check(store.get(kid).ver == kv and store.get(grand).ver == gv, "the children's ids and vers are kept")
    eq(trace(), 'changed:' .. root .. ':follow', 'one index change re-places the whole subtree')
    eq(#Scene.list({ bucket = 7 }), 3, 'Scene.list finds the three in bucket 7')
    eq(#Scene.query({ pos = at(40, -3, 1), radius = 5, bucket = 7 }), 3, 'Scene.query finds them there')
    eq(#Scene.query({ pos = at(40, -3, 1), radius = 5, bucket = 0 }), 0, '... and no longer in bucket 0')
    local c2 = Scene.spawn({ kind = 'prop', parent = root, model = 'm' })
    eq(Scene.get(c2).bucket, 7, "a new child takes the root's bucket")
    eq(errOf(Scene.spawn({ kind = 'prop', parent = root, model = 'm', bucket = 0 })), 'parent', '... bucket 0 no more')
    local spin = Scene.spawn({ kind = 'prop', pos = at(0, 60, 0), model = 'm', motion = { t = 'spin', axis = 'z',
        dps = 30 } })
    local sn = store.get(spin)
    sn.promoted = { netId = 13 }
    eq(store.follow(sn, at(9, 60, 0), { x = 0, y = 0, z = 45 }, 3), true, 'a node with a motion follows')
    check(sn.pos.x == P0.x and sn.rot.z == 0 and sn.motion ~= nil, '... its motion keeps the pose')
    eq(sn.bucket, 3, '... its bucket follows')
    eq(errOf(store.follow(sn, { x = 'x' })), 'pos', '... a bad position is still refused')
    check(Scene.demote == nil or #H.promoteLog == 0, 'no demotion anywhere in this section')
end

-- follow: persistence at most once per 30 s per node (the last pose of a burst), persistNow / a bucket move at once
do
    local env, Core, R = newServer()
    local Scene, store = Core.Scene, R.store
    local log = H.recordDb(env)
    local car = Scene.spawn({ kind = 'vehicle', pos = P0, model = 'adder', persist = true })
    local seat = Scene.spawn({ kind = 'prop', parent = car, model = 'm', persist = true })
    local other = Scene.spawn({ kind = 'vehicle', pos = at(0, 30, 0), model = 'adder', persist = true })
    local key, kkey = car, seat
    local writes = setmetatable({}, { __index = function(_, id) return H.writeCount(log, id) end })
    stubs.tick(1000)
    local node = store.get(car)
    node.promoted = { netId = 21 }
    local doc = H.doc
    local w0 = writes[key]
    store.follow(node, at(10, 0, 0))
    stubs.tick(1000)
    eq(writes[key], w0 + 1, 'the first followed pose is written (the coalesced writer, ≤ 1 s)')
    eq(doc(key).pos.x, P0.x + 10, '... with the new base position')
    for i = 2, 6 do
        stubs.tick(1000)
        store.follow(node, at(10 * i, 0, 0))
    end
    stubs.tick(1000)
    eq(writes[key], w0 + 1, 'a drive: no write within 30 s of the last one')
    eq(doc(key).pos.x, P0.x + 10, '... the document keeps the older pose meanwhile')
    stubs.tick(24000)
    eq(writes[key], w0 + 2, 'its 30 s are up: one write')
    eq(doc(key).pos.x, P0.x + 60, '... of the LAST followed pose')
    stubs.tick(40000)
    eq(writes[key], w0 + 2, 'nothing followed since: nothing more (one timer, no polling)')
    store.follow(node, at(70, 0, 0))
    stubs.tick(1000)
    eq(writes[key], w0 + 3, 'a follow 30 s after the last write is written at once')
    store.follow(node, at(80, 0, 0), nil, nil, true)
    stubs.tick(1000)
    eq(writes[key], w0 + 4, 'persistNow writes within the second, whatever the 30 s')
    eq(doc(key).pos.x, P0.x + 80, '... the pose of that call')
    store.follow(node, at(80, 0, 0), nil, nil, true)
    stubs.tick(1000)
    eq(writes[key], w0 + 5, 'persistNow without a change still writes (the stop path)')
    local kw = writes[kkey]
    store.follow(node, nil, nil, 4)
    stubs.tick(1000)
    check(writes[key] == w0 + 6 and writes[kkey] == kw + 1, 'a bucket move is written at once, the child too')
    check(doc(key).bucket == 4 and doc(kkey).bucket == 4, '... both documents carry bucket 4')
    local on = store.get(other)
    on.promoted = { netId = 22 }
    store.follow(on, at(5, 30, 0))
    store.follow(on, at(9, 30, 0))
    stubs.tick(1000)
    Scene.remove(other)
    stubs.tick(40000)
    eq(H.row(other), nil, 'a removed node keeps no row (its pending followed write is dropped)')
    local _, Core2 = newServer({ keepDb = true })
    local back, backSeat = Core2.Scene.get(car), Core2.Scene.get(seat)
    check(back and back.bucket == 4 and back.pos.x == P0.x + 80 and back.promoted == nil,
        'a restart finds the car where and in the bucket it was followed to (demoted)')
    check(backSeat and backSeat.bucket == 4 and backSeat.parent == car, '... its child with it')
end

-- follow on the REAL index: a bucket move = DEL (normal) to the old bucket, PUT to the new (children too, the
-- promoted flag kept); inside a cell a MOVE; across a border only past the movers' tolerance (hand-over)
do
    local _, Core, R = newServer({ beforeStore = function(env) stubs.loadFile(env, 'server/scene_index.lua') end })
    local Scene, store, I, Codec = Core.Scene, R.store, R.index, Core.SceneCodec
    local root = Scene.spawn({ kind = 'prop', pos = P0, model = 'prop_bench_01a' })
    local kid = Scene.spawn({ kind = 'prop', parent = root, model = 'm', offset = { x = 0, y = 0, z = 1 } })
    local node = store.get(root)
    node.promoted = { netId = 31 }
    local function drained()
        local set = {}
        local entries = I.drain()
        for i = 1, #entries do
            local e = entries[i]
            local okd, err = Codec.decode(Codec.header(0) .. e.blob, {
                put = function(id, _, _, _, flags, _, _, _, _, _, _, _, extra)
                    local net = type(extra) == 'table' and extra.n or nil
                    set[('b%d:put:%d%s'):format(e.bucket, id, (flags & 2 ~= 0 and net == 31) and ':P31' or '')] = true
                end,
                del = function(id, _, how) set[('b%d:del:%d:%d'):format(e.bucket, id, how)] = true end,
                move = function(id, _, x) set[('b%d:move:%d:%s'):format(e.bucket, id, x)] = true end,
            })
            check(okd, 'a drained entry decodes (' .. tostring(err) .. ')')
        end
        local out = {}
        for k in pairs(set) do out[#out + 1] = k end
        table.sort(out)
        return table.concat(out, ' ')
    end
    drained()
    eq(store.follow(node, nil, nil, 5), true, 'bucket 0 → 5')
    local r, k = tostring(root), tostring(kid)
    eq(drained(), ('b0:del:%s:0 b0:del:%s:0 b5:put:%s:P31 b5:put:%s'):format(r, k, r, k),
        'the old bucket gets DELs (normal: no hand-over across buckets), the new one PUTs (promoted, net id)')
    eq(store.follow(node, at(3, 0, 0)), true, 'a move inside the cell')
    eq(drained(), ('b5:move:%s:103.0'):format(r), '... one MOVE op to the cell')
    eq(store.follow(node, at(30, 0, 0)), true, '2 m past the cell border (x 128)')
    eq(drained(), ('b5:move:%s:130.0'):format(r), "... inside the movers' tolerance: still a MOVE in the old cell")
    eq(store.follow(node, at(40, 0, 0)), true, '12 m past it')
    eq(drained(), ('b5:del:%s:1 b5:del:%s:1 b5:put:%s:P31 b5:put:%s'):format(r, k, r, k),
        '... re-celled: a hand-over DEL and a PUT, the child with it')
    eq(node.promoted.netId, 31, 'still promoted')
end

-- Config.Scene.CoreReserve (D-E, review RV4 F3): plugins stop short of MaxNodes / MaxPersistent, core never does
do
    local _, Core = newServer({ config = function(Config)
        Config.Scene.MaxNodes, Config.Scene.MaxPersistent = 10, 6
        Config.Scene.CoreReserve = { nodes = 4, persistent = 2 }
    end })
    local Scene = Core.Scene
    for i = 1, 4 do
        check(as('plug', 'spawn', { kind = 'marker', pos = P0, persist = true }) ~= nil, 'a plugin persists ' .. i)
    end
    eq(errOf(as('plug', 'spawn', { kind = 'marker', pos = P0, persist = true })), 'limit',
        'a plugin stops at MaxPersistent - CoreReserve.persistent (4 of 6)')
    for i = 1, 2 do check(as('plug', 'spawn', { kind = 'marker', pos = P0 }) ~= nil, 'a plain plugin node ' .. i) end
    eq(errOf(as('plug', 'spawn', { kind = 'marker', pos = P0 })), 'limit',
        'plugins stop at MaxNodes - CoreReserve.nodes (6 of 10)')
    eq(errOf(as('other', 'spawn', { kind = 'marker', pos = P0 })), 'limit', '... whichever plugin asks')
    check(Scene.spawn({ kind = 'marker', pos = P0, persist = true }) ~= nil
        and Scene.spawn({ kind = 'marker', pos = P0, persist = true }) ~= nil, 'core persists into its reserve (6 of 6)')
    eq(errOf(Scene.spawn({ kind = 'marker', pos = P0, persist = true })), 'limit', '... up to MaxPersistent')
    check(Scene.spawn({ kind = 'marker', pos = P0 }) ~= nil and Scene.spawn({ kind = 'marker', pos = P0 }) ~= nil,
        'core fills the rest (10 of 10)')
    eq(errOf(Scene.spawn({ kind = 'marker', pos = P0 })), 'limit', '... up to MaxNodes')
    Scene.remove(Scene.list({ owner = 'plug' })[1])
    eq(errOf(as('plug', 'spawn', { kind = 'marker', pos = P0 })), 'limit', "a slot freed inside the reserve stays core's")
    check(Scene.spawn({ kind = 'marker', pos = P0 }) ~= nil, '... and core takes it')
end

-- review RV4 F11: mapEl / mapType / vehId are core's tags — a plugin can neither set, change nor remove them, nor
-- declare them on a kind of its own (the client's map index and the parked-car lookup trust them)
do
    local _, Core = newServer()
    local Scene = Core.Scene
    for _, tag in ipairs({ 'mapEl', 'mapType', 'vehId' }) do
        local kind, model = tag == 'vehId' and 'vehicle' or 'prop', tag == 'vehId' and 'adder' or 'm'
        local id, err, detail = as('evil', 'spawn', { kind = kind, pos = P0, model = model, fields = { [tag] = 'm1:5' } })
        check(id == nil and err == 'fields' and type(detail) == 'table' and detail[tag] == 'reserved',
            'a plugin cannot stamp ' .. tag .. ' (' .. tostring(err) .. ')')
    end
    local mine = as('evil', 'spawn', { kind = 'prop', pos = P0, model = 'm' })
    eq(errOf(as('evil', 'set', mine, { mapEl = 'm1:5' })), 'fields', '... nor set it on its node later')
    local tagged = Scene.spawn({ kind = 'prop', pos = P0, model = 'm', fields = { mapEl = 'm1:5', mapType = 'core:t' } })
    eq(Scene.get(tagged).fields.mapEl, 'm1:5', 'core stamps it')
    eq(Scene.adopt(tagged, 'evil'), true, 'a plugin may own a core-tagged node (adopt)')
    eq(errOf(as('evil', 'set', tagged, { mapEl = 'm1:6' })), 'fields', '... but cannot change the tag')
    eq(errOf(as('evil', 'set', tagged, {}, { remove = { 'mapType' } })), 'fields', '... nor remove it')
    eq(as('evil', 'set', tagged, { tint = 3 }), true, '... other fields are fine (the tag rides along unchanged)')
    eq(as('evil', 'set', tagged, Scene.get(tagged).fields), true, '... a get → set round trip too')
    eq(Scene.set(tagged, { mapEl = 'm1:7' }), true, 'core changes it')
    local okK, errK = as('evil', 'defineKind', { id = 'evil:thing', class = 'prop', fields = {
        { name = 'model', type = 'model', required = true }, { name = 'mapEl', type = 'string', default = 'm1:5' } } })
    check(okK == false and errK == 'fields:reserved:mapEl', 'a plugin kind cannot declare mapEl (' .. tostring(errK) .. ')')
    eq(Scene.defineKind({ id = 'core:tagged', class = 'data', fields = { { name = 'vehId', type = 'string' } } }), true,
        'core may')
end

-- review RV4 F1 (4) / D-A: the vehicle kind's props are clamped to their native ranges (a stranger's
-- { tankHealth = -1000, engineHealth = -4000 } can never make a car burn at each promotion)
do
    local _, Core, R = newServer()
    local Scene = Core.Scene
    local function at2(t, i) return t[i] == nil and t[tostring(i)] or t[i] end
    local id = Scene.spawn({ kind = 'vehicle', pos = P0, model = 'adder', fields = { props = {
        engineHealth = -4000, bodyHealth = 5000, tankHealth = -1000, dirtLevel = 99, fuelLevel = -5,
        colorPrimary = 999, colorSecondary = -3, pearlescentColor = 12.6, wheelColor = 300, interiorColor = -1,
        dashboardColor = 256, wheels = 40, windowTint = 9, livery = -7, livery2 = 400, plateIndex = 99, xenonColor = 40,
        neonColor = { 300, -5, 12.4 }, tyreSmokeColor = { 255, 256, 0 }, customPrimary = { 1000, 0, 0 },
        customSecondary = false, mods = { [11] = 999, [12] = -9, [13] = 2 }, tyreHealth = { [0] = 5000, [1] = -3,
        [2] = 350.5 }, lights = { true, false, 7 }, burstTyres = { [0] = true }, modTurbo = true, plate = 'ABC' } } })
    check(id ~= nil, 'out-of-range props are clamped, not refused')
    local p = Scene.get(id).fields.props
    check(p.engineHealth == 0 and p.bodyHealth == 1000 and p.tankHealth == 0, 'healths 0..1000 (never burning)')
    check(p.dirtLevel == 15 and p.fuelLevel == 0, 'dirt 0..15, fuel 0..100')
    check(p.colorPrimary == 255 and p.colorSecondary == 0 and p.pearlescentColor == 12 and p.wheelColor == 255
        and p.interiorColor == 0 and p.dashboardColor == 255, 'palette indexes: integers (floored) 0..255')
    check(p.wheels == 12 and p.windowTint == 6 and p.livery == -1 and p.livery2 == 127 and p.plateIndex == 12,
        'wheel type, tint, liveries, plate style: their enums (the rules of server/vehicles.lua cleanProps)')
    eq(p.xenonColor, nil, 'a xenon colour outside 0..12 / 255 is dropped')
    check(p.neonColor[1] == 255 and p.neonColor[2] == 0 and p.neonColor[3] == 12 and p.tyreSmokeColor[2] == 255
        and p.customPrimary[1] == 255, '{ r, g, b } 0..255')
    eq(p.customSecondary, false, 'false (no custom colour) stays')
    check(at2(p.mods, 11) == 254 and at2(p.mods, 12) == -1 and at2(p.mods, 13) == 2, 'mod indexes -1..254')
    check(at2(p.tyreHealth, 0) == 1000 and at2(p.tyreHealth, 1) == 0 and at2(p.tyreHealth, 2) == 350.5,
        'tyre health 0..1000 (fractions kept)')
    eq(p.lights[3], 3, 'indicators 0..3')
    check(p.modTurbo == true and p.plate == 'ABC' and at2(p.burstTyres, 0) == true, 'everything else unchanged')
    eq(Scene.set(id, { props = { engineHealth = -1, bodyHealth = 700.5 } }), true, 'Scene.set goes through the same clamp')
    local q = Scene.get(id).fields.props
    check(q.engineHealth == 0 and q.bodyHealth == 700.5, '... 0 and a fraction')
    local red = Scene.spawn({ kind = 'vehicle', pos = P0, model = 'adder', fields = { props = { colorPrimary = 'red',
        customSecondary = true, plateIndex = 3 } } })
    local rp = red and Scene.get(red).fields.props
    check(rp and rp.colorPrimary == nil and rp.customSecondary == nil and rp.plateIndex == 3,
        'a known key of the wrong type is dropped (a custom colour is false or RGB), the rest kept')
    eq(errOf(Scene.spawn({ kind = 'vehicle', pos = P0, model = 'adder', fields = { props = { mods = { [99] = 1 } } } })),
        'fields', 'a bad map index is still refused by the shape check')
    check(type(R.vehiclePropsNorm) == 'function', 'the ranges are reachable for other props writes (R.vehiclePropsNorm)')
end

H.finish()
