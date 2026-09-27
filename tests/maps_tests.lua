--[[
    core/tests/maps_tests.lua — offline suite for Core.Maps (DESIGN §52.1, §52.2, §55.21.1), part 1.

        lua5.4 tests/maps_tests.lua    (from the resource directory, or from tests/)

    Types, documents, the projection onto Core.Scene (the map:data kind, the exact node def of every element
    kind, contexts opening, closing and swapping by diff, changes keeping their node, kind changes, placeholders,
    respawn — promoted, displaced, changed, missing nodes —, the Scene store barrier and its waiter, calls as
    core, refusals, re-entrancy, the per-uid vehicle paint), the networked limits, the validator, drafts (editor
    bucket, publish, rollback), the final-review fixes (RV4 F2 / RV6 F6 slicing: <= SLICE Scene calls per worker
    slice, an honest API mid-projection, adoption of a closing context, the pending boxes in GlobalState; RV4 F3
    'limit' retries with backoff; RV5 F3 faded editor removals; RV6 F8 promotion policies) and passes against the
    REAL scene server files. Harness: tests/maps_harness.lua (a recording fake of Core.Scene). Journal, clear, expiry, persistence, expect / conflict / invert, events,
    hooks, validate, parents, refs, migrate, restores, id caps, apply validation and limits:
    tests/maps_store_tests.lua. Exit 1 on failure.
]]

local here = (arg and arg[0] or 'tests/maps_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local H = dofile(here .. '/maps_harness.lua')
local stubs, check, eq, callable, calls, reset, same = H.stubs, H.check, H.eq, H.callable, H.calls, H.reset, H.same
local newServer, as, stop, lastAudit, node = H.newServer, H.as, H.stop, H.lastAudit, H.node

local function printed(needle)
    local n = 0
    for i = 1, #stubs.printed do
        if stubs.printed[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

--------------------------------------------------------------------------------
-- element types: built-ins, define, ownership, public list, callback
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    local list = Maps.types()
    local ids = {}
    for i = 1, #list do ids[list[i].id] = list[i] end
    for _, id in ipairs({ 'core:prop', 'core:physprop', 'core:vehicle', 'core:ped', 'core:marker', 'core:hide', 'core:point',
        'core:zone' }) do check(ids[id] ~= nil and ids[id].owner == 'core', 'built-in ' .. id .. ' is defined by core') end
    check(ids['core:vehicle'].transform.rotate == 'yaw' and ids['core:hide'].transform.rotate == 'none', 'rotate defaults')
    eq(ids['core:physprop'].networked, true, 'core:physprop is networked')
    eq(ids['core:prop'].fields[1].name, 'model', 'public fields keep their order')
    eq(ids['core:prop'].fields[1].kinds[1], 'prop', 'the model field is limited to props')
    eq(type(ids['core:prop'].validate), 'nil', 'no functions in the public list')
    check(R.joaat('adder') == -1216765807 and R.joaat('ADDER') == -1216765807, 'joaat = signed GetHashKey, lower-cased')

    local refusals = {
        { { id = 'bad', kind = 'point', label = 'x' }, 'id' }, { { id = 'a:b', kind = 'blob' }, 'kind' },
        { { id = 'a:b', kind = 'prop' }, 'model_field' }, { { id = 'a:b', kind = 'point', networked = true }, 'networked' },
        { { id = 'a:b', kind = 'point', parents = { 'bad' } }, 'parents' }, { { id = 'a:b', kind = 'point', validate = 5 }, 'validate' },
        { { id = 'a:b', kind = 'point', preview = { { kind = 'blob' } } }, 'preview' },
        { { id = 'a:b', kind = 'point', transform = { rotate = 'tilt' } }, 'transform' },
        { { id = 'a:b', kind = 'point', fields = { { name = 'x', type = 'nope' } } }, 'fields:' },
    }
    for i, r in ipairs(refusals) do
        local ok, err = Maps.defineType(r[1])
        check(ok == false and type(err) == 'string' and err:sub(1, #r[2]) == r[2],
            ('defineType refusal %d -> %s (got %s)'):format(i, r[2], tostring(err)))
    end

    eq(as('garage', 'defineType', { id = 'garage:spot', label = 'Garage spot', kind = 'point',
        fields = { { name = 'slot', type = 'integer', min = 1, max = 20, default = 1 } },
        preview = { { kind = 'marker', type = 36, color = '#ffffff' }, { kind = 'label', text = '$slot' } } }),
        true, 'a plugin defines a type')
    local ok, err = as('other', 'defineType', { id = 'garage:spot', kind = 'point' })
    check(ok == false and err == 'owner', 'another resource cannot redefine it')
    eq(as('garage', 'defineType', { id = 'garage:spot', label = 'Spot', kind = 'point', version = 2 }), true,
        'the owner may redefine it')
    local spot
    for _, t in ipairs(Maps.types()) do if t.id == 'garage:spot' then spot = t end end
    check(spot and spot.owner == 'garage' and spot.label == 'Spot' and spot.version == 2, 'the redefinition replaced it')
    eq(Core.Registry.getOwned('garage').mapType['garage:spot'], true, "tracked as Registry kind 'mapType'")
    stop(env, 'garage')
    spot = nil
    for _, t in ipairs(Maps.types()) do if t.id == 'garage:spot' then spot = t end end
    eq(spot, nil, 'the owner stopped: the type is gone')
    check(env.__vm.netEvents['core:cb:req:core:maps:types'] == true, 'callback core:maps:types is registered')
end

--------------------------------------------------------------------------------
-- the map:data kind: defined once, as core, when core starts (before any plugin could take the id)
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local defs = calls('defineKind')
    eq(#defs, 1, 'core start defines one scene kind')
    local def = defs[1] and defs[1].def or {}
    check(def.id == 'map:data' and def.class == 'data' and def.radius == 150 and defs[1].caller == 'core',
        'map:data: class data, radius 150 (the editor view), defined as core')
    local names = {}
    for i, f in ipairs(def.fields or {}) do names[f.name] = f end
    check(names.t and names.t.required and names.k and names.k.required and names.size and names.size.type == 'vector3'
        and names.f and names.f.type == 'table' and names.mapEl and names.mapType, 'fields t, k, size, f, mapEl, mapType')
    local validate = names.f and names.f.validate
    check(validate({ label = 'x', slot = '3' }) == true, 'f: label values pass')
    check(validate({ label = 5 }) == false and validate({ ['bad name'] = 'x' }) == false
        and validate({ x = ('y'):rep(65) }) == false, 'f: only field-named strings <= 64')
    local many = {}
    for i = 1, 17 do many['f' .. i] = 'x' end
    eq(validate(many), false, 'f: at most 16 labels')
    local map = Core.Maps.create({ name = 'K', mode = 'live' }, 1)
    Core.Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    eq(#calls('defineKind'), 1, 'a map:data spawn does not define it again')
    env.TriggerEvent('onResourceStart', 'other')
    eq(#calls('defineKind'), 1, "another resource's start defines nothing")

    local _, Core2 = newServer({ refuse = { defineKind = 'owner' } })
    eq(printed('map:data was refused: owner'), 1, 'a refusal at start is logged')
    reset()
    local m2 = Core2.Maps.create({ name = 'K2', mode = 'live' }, 1)
    Core2.Maps.apply(m2.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    eq(#calls('defineKind'), 1, 'a map:data spawn asks again')
    eq(printed('map:data was refused'), 1, 'a second refusal within a minute is not logged')
    H.refuse.defineKind = nil
    Core2.Maps.apply(m2.id, { { op = 'create', type = 'core:zone', pos = { x = 1, y = 0, z = 0 } } }, 1)
    Core2.Maps.apply(m2.id, { { op = 'create', type = 'core:zone', pos = { x = 2, y = 0, z = 0 } } }, 1)
    eq(#calls('defineKind'), 2, 'the next one defines it, and nothing asks after that')
    eq(#calls('spawn'), 3, 'the nodes were spawned all along')
end

--------------------------------------------------------------------------------
-- documents, a live map, the node def of every kind (§55.21.1)
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    local map = Maps.create({ name = '  Event Arena ', mode = 'live', meta = { description = 'friday' } }, 1)
    check(map ~= nil, 'create a live map')
    eq(map.name, 'Event Arena', 'the name is trimmed')
    eq(map.active, true, 'a live map starts active')
    eq(map.targetBucket, 0, 'targetBucket defaults to 0')
    eq(map.createdBy.accountId, 'acc1', 'createdBy is the account snapshot')
    local a = lastAudit('maps.create')
    check(a and a.actor == 1 and a.targets[1].id == map.id, 'create is audited')
    local draft = Maps.create({ name = 'Garage', mode = 'draft' }, 0)
    eq(draft.active, false, 'a draft starts inactive')
    check(draft.id ~= map.id, 'ids are unique')
    check(select(2, Maps.create({ name = '', mode = 'live' })) == 'name' and select(2, Maps.create({ name = 'x', mode = 'b' }))
        == 'mode', 'an empty name and an unknown mode are refused')
    eq(select(2, Maps.create({ name = 'x', mode = 'live', targetBucket = -1 })), 'targetBucket', 'a negative bucket is refused')
    eq(select(2, Maps.create({ name = 'x', mode = 'live', expiresAt = 5 })), 'expiresAt', 'a past expiry is refused')
    eq(select(2, Maps.create({ name = 'x', mode = 'live', limits = { elements = 0 } })), 'limits', 'a limit out of range is refused')
    check(#Maps.list() == 2 and #Maps.list({ mode = 'draft' }) == 1, 'list has both and filters by mode')
    eq(Maps.list({ text = 'FRIDAY' })[1].id, map.id, 'text matches the description, case-insensitive')
    eq(#Maps.list({ active = true }), 1, 'list filters by active')

    as('garage', 'defineType', { id = 'garage:spot', kind = 'point', preview = { { kind = 'label', text = '$slot' },
        { kind = 'label', text = '$note' } }, fields = { { name = 'slot', type = 'integer', default = 3 },
        { name = 'note', type = 'string', maxLength = 200 } } })
    reset()
    local ok, applied = Maps.apply(map.id, {
        { op = 'create', type = 'core:prop', pos = { x = 1.23456, y = 2, z = 3 }, rot = { x = 0, y = 0, z = 12.3456 },
            fields = { model = 'prop_barrier' } },
        { op = 'create', type = 'core:marker', pos = { x = 10, y = 0, z = 0 },
            fields = { color = '#FF000080', markerType = 2, scale = { x = 2, y = 2, z = 1 }, bob = true } },
        { op = 'create', type = 'core:hide', pos = { x = 20, y = 0, z = 0 }, fields = { model = 'prop_bin_01a', radius = 3 } },
        { op = 'create', type = 'core:point', pos = { x = 30, y = 0, z = 0 }, rot = { z = 90, x = 0, y = 0 }, fields = { label = 'start' } },
        { op = 'create', type = 'core:zone', pos = { x = 40, y = 0, z = 0 }, fields = { size = { x = 5, y = 6, z = 7 } } },
    }, 1, { source = 'editor' })
    check(ok == true, 'apply creates five elements')
    eq(#applied.ops, 5, 'applied lists every op')
    check(applied.ops[1].id == '1' and applied.ops[5].id == '5', 'element ids count from 1 per map')
    eq(applied.ops[1].after.fields.collision, true, 'field defaults are filled')
    eq(applied.ops[1].after.by, 'acc1', 'by = the actor account')
    check(applied.ops[1].after.updatedAt > 0, 'updatedAt is stamped')
    check(applied.ops[2].after.updatedAt > applied.ops[1].after.updatedAt, 'stamps are strictly increasing')
    local spawns = calls('spawn', 0)
    eq(#spawns, 5, 'five nodes are spawned in bucket 0')
    local function uid(id) return map.id .. ':' .. id end
    local function defOf(id) local c = H.byUid(spawns, uid(id)) return c and c.def end
    check(same(defOf(1), { kind = 'prop', bucket = 0, persist = false, pos = { x = 1.235, y = 2, z = 3 },
        rot = { x = 0, y = 0, z = 12.35 }, fields = { model = 'prop_barrier', frozen = true, collision = true,
        invincible = true, mapEl = uid(1), mapType = 'core:prop' } }),
        'prop: model, frozen, collision, invincible = unbreakable (lod is Scene-filled), mapEl, mapType')
    check(same(defOf(2), { kind = 'marker', bucket = 0, persist = false, pos = { x = 10, y = 0, z = 0 },
        rot = { x = 0, y = 0, z = 0 }, fields = { type = 2, color = '#FF000080', scale = { x = 2, y = 2, z = 1 },
        drawDistance = 50, bob = true, face = false, mapEl = uid(2), mapType = 'core:marker' } }),
        'marker: type, colour, scale, drawDistance, bob, face')
    check(same(defOf(3), { kind = 'hide', bucket = 0, persist = false, pos = { x = 20, y = 0, z = 0 },
        rot = { x = 0, y = 0, z = 0 }, fields = { model = 'prop_bin_01a', radius = 3, mapEl = uid(3),
        mapType = 'core:hide' } }), 'hide: model name and radius')
    check(same(defOf(4), { kind = 'map:data', bucket = 0, persist = false, pos = { x = 30, y = 0, z = 0 },
        rot = { x = 0, y = 0, z = 90 }, audience = { editors = true }, fields = { t = 'core:point', k = 'point',
        f = { label = 'start' }, mapEl = uid(4), mapType = 'core:point' } }),
        'point: map:data for editors, t, k, the $label value in f')
    check(same(defOf(5), { kind = 'map:data', bucket = 0, persist = false, pos = { x = 40, y = 0, z = 0 },
        rot = { x = 0, y = 0, z = 0 }, audience = { editors = true }, fields = { t = 'core:zone', k = 'zone',
        size = { x = 5, y = 6, z = 7 }, mapEl = uid(5), mapType = 'core:zone' } }),
        'zone: map:data with its size (no label preview: no f)')
    for _, c in ipairs(spawns) do check(c.caller == 'core', 'spawned as core: ' .. tostring(c.uid)) end
    check(same(R.nodeDef({ mapId = 'm9', bucket = 4 }, { id = '7', type = 'core:marker', pos = { x = 0, y = 0, z = 0 },
        rot = { x = 0, y = 0, z = 0 }, fields = {} }).fields, { type = 1, color = '#E0A33AB4',
        scale = { x = 1, y = 1, z = 1 }, drawDistance = 50, bob = false, face = false, mapEl = 'm9:7',
        mapType = 'core:marker' }), 'a marker without fields gets the defaults')
    Maps.apply(map.id, { { op = 'create', type = 'garage:spot', pos = { x = 0, y = 0, z = 0 }, fields = { note = ('n'):rep(70) } } }, 1)
    local spot = H.byUid(calls('spawn', 0), uid(6)).def.fields
    check(spot.t == 'garage:spot' and spot.k == 'point' and spot.f.slot == '3' and #spot.f.note == 64,
        'f: $field labels as strings <= 64')
    check(H.row('SELECT element_id FROM map_elements WHERE map_id = $1 AND element_id = 1', { map.id }) ~= nil,
        'each element is its own row')
    eq(#Maps.elements(map.id), 6, 'elements() lists the working set')
    eq(Maps.elements(map.id)[1].id, '1', 'ascending ids')
    eq(Maps.get(map.id).counts.elements, 6, 'get() counts elements')
    eq(Maps.get(map.id).counts.uniqueModels, 1, 'hides do not count as streamed models')
    eq(Core.MapsRuntime.stats().nodes, 6, 'stats: six nodes')

    reset()
    local before = node(uid(1))
    local rowBefore = H.row('SELECT xmin::text AS x FROM map_elements WHERE map_id = $1 AND element_id = 2', { map.id })
    ok = Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 5, y = 5, z = 5 } } } }, 1)
    check(ok, 'an update by numeric id')
    eq(H.trace(), 'move:' .. uid(1), 'one move, nothing else')
    check(node(uid(1)) == before and node(uid(1)).pos.x == 5.0, 'the same node, at its new position')
    local rowAfter = H.row('SELECT xmin::text AS x FROM map_elements WHERE map_id = $1 AND element_id = 2', { map.id })
    check(rowBefore and rowAfter and rowAfter.x == rowBefore.x, 'untouched elements are not rewritten (same row version)')
    reset()
    ok = Maps.apply(map.id, { { op = 'delete', id = '1' } }, 1)
    check(ok, 'a delete')
    eq(H.trace(), 'remove:' .. uid(1), 'one remove of that uid')
    eq(node(uid(1)), nil, 'its node is gone')
    eq(H.row('SELECT element_id FROM map_elements WHERE map_id = $1 AND element_id = 1', { map.id }), nil,
        'its row is gone')

    reset()
    local updated = Maps.update(map.id, { targetBucket = 5, name = 'Arena' }, 1)
    eq(updated.targetBucket, 5, 'update moves the target bucket')
    eq(#calls('remove', 0), 5, 'content leaves bucket 0')
    eq(#calls('spawn', 5), 5, 'and appears in bucket 5')
    local u = lastAudit('maps.update')
    check(u and #u.changes == 2, 'update is audited with its changes')
    eq(select(2, Maps.update(map.id, { name = 5 })), 'name', 'update refuses a bad name')
    eq(Maps.get(map.id).name, 'Arena', 'and changes nothing then')
end

--------------------------------------------------------------------------------
-- the model validator; vehicles, peds and physics props are nodes too (local copies Scene may promote)
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, paintOf = Core.Maps, Core.MapsRuntime.paintOf
    local seen = {}
    local validator = callable(function(kind, model)
        seen[#seen + 1] = kind .. ':' .. model
        if model == 'nope' then return false end
        if kind == 'vehicle' then return true, { vehicleType = model == 'bati' and 'bike' or 'automobile' } end
        if model == 'prop_tall' then return true, { lod = 300, junk = 'x' } end
        return true
    end)
    eq(as('catalogue', 'setModelValidator', validator), true, 'a plugin registers the model validator')
    eq(Core.Registry.getOwned('catalogue').mapsModelValidator.validator, true, "tracked as 'mapsModelValidator'")
    local map = Maps.create({ name = 'N', mode = 'live', targetBucket = 7 }, 1)
    local function uid(id) return map.id .. ':' .. id end
    reset()
    local ok, applied = Maps.apply(map.id, {
        { op = 'create', type = 'core:vehicle', pos = { x = 1, y = 2, z = 3 }, rot = { x = 0, y = 0, z = 90 },
            fields = { model = 'bati', plate = 'EVENT 1', color = '#102030', locked = true } },
        { op = 'create', type = 'core:ped', pos = { x = 4, y = 5, z = 6 }, fields = { model = 'a_m_y_x', scenario = 'WORLD_HUMAN_SMOKING' } },
        { op = 'create', type = 'core:physprop', pos = { x = 7, y = 8, z = 9 }, rot = { x = 10, y = 0, z = 0 }, fields = { model = 'prop_crate' } },
        { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'prop_tall' } },
        { op = 'create', type = 'core:prop', pos = { x = 1, y = 0, z = 0 }, fields = { model = 'prop_tall' } },
    }, 1)
    check(ok, 'vehicle, ped and physics prop pass with a validator')
    eq(#seen, 4, 'the validator is asked once per distinct model')
    eq(applied.ops[1].after.info.vehicleType, 'bike', 'the vehicle type is kept on the element')
    eq(applied.ops[4].after.info.lod, 300, 'the lod is kept on the element')
    eq(applied.ops[4].after.info.junk, nil, 'nothing else from the validator is kept')
    eq(#calls('spawn', 7), 5, 'every element is a node in the target bucket')
    local function defOf(id) return H.byUid(calls('spawn', 7), uid(id)).def end
    local p1, s1 = paintOf(uid(1))
    check(same(defOf(1), { kind = 'vehicle', bucket = 7, persist = false, pos = { x = 1, y = 2, z = 3 },
        rot = { x = 0, y = 0, z = 90 }, fields = { model = 'bati', plate = 'EVENT 1', locked = true, frozen = true,
        props = { colorPrimary = p1, colorSecondary = s1, customPrimary = { 16, 32, 48 },
        customSecondary = { 16, 32, 48 } }, mapEl = uid(1), mapType = 'core:vehicle' },
        authority = { mode = 'local' } }),
        "vehicle: model, plate, locked, frozen, the uid's paint and the colour as both custom colours on top")
    check(same(defOf(1).authority, { mode = 'local' }),
        "vehicle in its target bucket: authority local (enter / damage promote it, a passer-by does not; RV6 F8)")
    check(same(defOf(2), { kind = 'ped', bucket = 7, persist = false, pos = { x = 4, y = 5, z = 6 },
        rot = { x = 0, y = 0, z = 0 }, fields = { model = 'a_m_y_x', scenario = 'WORLD_HUMAN_SMOKING', invincible = true,
        frozen = true, blockEvents = true, mapEl = uid(2), mapType = 'core:ped' } }),
        'ped: model, scenario, invincible, frozen, blockEvents (authority: the class default, local)')
    check(same(defOf(3), { kind = 'prop', bucket = 7, persist = false, pos = { x = 7, y = 8, z = 9 },
        rot = { x = 10, y = 0, z = 0 }, fields = { model = 'prop_crate', frozen = true, collision = true,
        invincible = false, physics = 'promote', mapEl = uid(3), mapType = 'core:physprop' } }),
        "physics prop: a prop with physics = 'promote'")
    check(defOf(4).fields.lod == nil and defOf(4).fields.physics == nil, "a plain prop: no physics, lod is Scene's (chain)")
    eq(Core.MapsRuntime.netTotal(), 3, 'three networked elements are counted')
    eq(Maps.get(map.id).counts.networked, 3, 'and reported per map')

    reset()
    local vehicle = node(uid(1))
    check(Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 50, y = 50, z = 50 } } } }, 1), 'move the vehicle')
    eq(H.trace(), 'move:' .. uid(1), 'a move of its node')
    check(node(uid(1)) == vehicle and vehicle.pos.x == 50.0 and vehicle.rot.z == 90, 'the same node, moved')
    check(Maps.apply(map.id, { { op = 'delete', id = 2 } }, 1), 'delete the ped')
    eq(node(uid(2)), nil, 'its node is removed')
    eq(Core.MapsRuntime.netTotal(), 2, 'and it no longer counts')

    reset()
    local ok2, err = Maps.apply(map.id, { { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'nope' } } }, 1)
    check(ok2 == nil and err == 'model', 'the validator refuses a model')
    eq(#H.log, 0, 'and nothing reaches the scene')
    check(Maps.setActive(map.id, false, 1), 'deactivate the live map')
    eq(next(H.nodes), nil, 'deactivation removes every node')
    eq(#calls('remove', 7), 4, 'four removes in the target bucket')
    eq(Core.MapsRuntime.netTotal(), 0, 'nothing networked is shown')
    check(Maps.setActive(map.id, true, 1), 'activate again')
    eq(#calls('spawn', 7), 4, 'the nodes come back with the content')
    check(node(uid(1)) ~= nil and node(uid(1)) ~= vehicle, 'as new nodes')
    stop(env, 'catalogue')
    local ok3, err3 = Maps.apply(map.id, { { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } } }, 1)
    check(ok3 == nil and err3 == 'no_validator', 'the validator goes with its resource')
    eq(node(uid(1)).fields.model, 'bati', 'active vehicles stay (their models were checked when placed)')
end

--------------------------------------------------------------------------------
-- a map vehicle's paint: per element UID, exactly the pre-migration rule (§52 notes, run UX C2)
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    -- pinned with the pre-migration code: HEAD:server/maps_runtime.lua PAINTS[R.joaat(uid) % #PAINTS + 1]
    local pinned = { ['m1:1'] = 50, ['m1:2'] = 3, ['m7:42'] = 89, ['m12:3'] = 70, ['event_arena:999'] = 4 }
    for uid, index in pairs(pinned) do
        local p, s = R.paintOf(uid)
        check(p == index and s == index, ('paint of %s = { %d, %d }, as before the migration'):format(uid, index, index))
    end
    local list = Core.Scene.PAINTS
    check(#list == 22 and same(list[1], { 0, 0 }) and same(list[7], { 111, 111 }) and same(list[22], { 145, 145 }),
        'Scene.PAINTS is the 22-paint §52 list, in its order')
    local stable, distinct, seen = true, 0, {}
    for i = 1, 60 do
        local uid = 'm' .. i .. ':' .. i
        local p = R.paintOf(uid)
        stable = stable and R.paintOf(uid) == p and p == list[R.joaat(uid) % 22 + 1][1]
        if not seen[p] then seen[p], distinct = true, distinct + 1 end
    end
    check(stable and distinct >= 10, 'a uid always gets the same paint, and uids spread over the list')

    as('catalogue', 'setModelValidator', callable(function() return true end))
    local map = Maps.create({ name = 'Paint', mode = 'draft', targetBucket = 4, active = true }, 1)
    local uid = map.id .. ':1'
    Maps.apply(map.id, { { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } } }, 1)
    Maps.publish(map.id, 1)
    local bucket = Maps.openDraft(map.id, 1)
    local p, s = R.paintOf(uid)
    local target, editor = node(uid, 4), node(uid, bucket)
    check(target.id ~= editor.id and same(target.fields.props, { colorPrimary = p, colorSecondary = s,
        customPrimary = false, customSecondary = false }) and same(editor.fields.props, target.fields.props),
        'the editor bucket and the target bucket show the same paint (two nodes, one uid)')
    Maps.setActive(map.id, false, 1)
    Maps.setActive(map.id, true, 1)
    local again = node(uid, 4)
    check(again.id ~= target.id and again.fields.props.colorPrimary == p, 'a new node after a setActive toggle: the same paint')
    Maps.apply(map.id, { { op = 'update', id = 1, set = { fields = { color = '#00FF00' } } } }, 1)
    local ep = node(uid, bucket).fields.props
    check(ep.colorPrimary == p and ep.colorSecondary == s and same(ep.customPrimary, { 0, 255, 0 }),
        'a set colour goes on top of the paint')
    Maps.closeDraft(map.id)
    newServer({ keepDb = true })
    local restarted = node(uid, 4)
    check(restarted and restarted.fields.props.colorPrimary == p, 'after a restart: the same paint')
end

--------------------------------------------------------------------------------
-- the networked limits still bound vehicles, peds and physics props (per map and server-wide)
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    as('catalogue', 'setModelValidator', callable(function() return true end))
    local map = Maps.create({ name = 'Net', mode = 'live', limits = { networked = 2 } }, 1)
    local function op(typeId, model)
        return { op = 'create', type = typeId, pos = { x = 0, y = 0, z = 0 }, fields = model and { model = model } or nil }
    end
    check(Maps.apply(map.id, { op('core:vehicle', 'adder'), op('core:ped', 'a_m_y_x'), op('core:prop', 'prop_a'),
        op('core:point') }, 1), 'two networked elements (and two that are not)')
    local ok, err, detail = Maps.apply(map.id, { op('core:physprop', 'prop_crate') }, 1)
    check(ok == nil and err == 'limit' and detail.limit == 'networked' and detail.max == 2,
        'a physics prop is the third networked element: refused')
    check(Maps.apply(map.id, { op('core:prop', 'prop_b'), op('core:marker') }, 1), 'plain props and markers are not')
    Core.Settings.set('maps.limits.networkedTotal', 3)
    local other = Maps.create({ name = 'Net2', mode = 'live' }, 1)
    check(Maps.apply(other.id, { op('core:vehicle', 'adder') }, 1), 'three server-wide')
    ok, err, detail = Maps.apply(other.id, { op('core:ped', 'a_m_y_x') }, 1)
    check(ok == nil and err == 'limit' and detail.limit == 'networkedTotal', 'the fourth exceeds networkedTotal')
    eq(R.netTotal(), 3, 'R.netTotal counts what is shown')
    eq(R.stats().networked, 3, 'stats too')
end

--------------------------------------------------------------------------------
-- a change keeps its node: moves, field diffs (set + remove), kind changes, placeholders, refusals, lost nodes
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    as('catalogue', 'setModelValidator', callable(function() return true end))
    eq(as('deco', 'defineType', { id = 'deco:thing', kind = 'point' }), true, 'a plugin point type')
    eq(as('garage', 'defineType', { id = 'garage:car', kind = 'vehicle', model = 'adder' }), true, 'a plugin vehicle type')
    local map = Maps.create({ name = 'C', mode = 'live' }, 1)
    local function uid(id) return map.id .. ':' .. id end
    local function update(id, set, replace)
        return Maps.apply(map.id, { { op = 'update', id = id, set = set, replace = replace } }, 1)
    end
    check(Maps.apply(map.id, {
        { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 },
            fields = { model = 'adder', plate = 'EVENT', color = '#102030' } },
        { op = 'create', type = 'core:ped', pos = { x = 5, y = 0, z = 0 }, fields = { model = 'a_m_y_x', scenario = 'X' } },
        { op = 'create', type = 'deco:thing', pos = { x = 10, y = 0, z = 0 } },
        { op = 'create', type = 'garage:car', pos = { x = 15, y = 0, z = 0 } },
    }, 1), 'four elements')
    eq(R.netTotal(), 3, 'vehicle, ped and the plugin vehicle count as networked')
    local veh = node(uid(1))

    reset()
    check(update(1, { fields = { plate = 'NEW' } }), 'change the plate')
    local c = calls('set')[1]
    check(#H.log == 1 and c.id == veh.id and same(c.patch, { plate = 'NEW' }) and c.remove == nil,
        'one set of the changed field on the same node')
    reset()
    check(update(1, { fields = { model = 'adder' } }, true), 'replace the fields: plate and colour gone')
    c = calls('set')[1]
    local p1, s1 = R.paintOf(uid(1))
    check(#H.log == 1 and same(c.patch, { props = { colorPrimary = p1, colorSecondary = s1, customPrimary = false,
        customSecondary = false } }) and same(c.remove, { 'plate' }),
        'the custom colours are cleared explicitly (the paint stays), the plate removed')
    eq(veh.fields.plate, nil, 'the node has no plate')
    reset()
    check(update(1, { pos = { x = 1, y = 1, z = 0 }, rot = { x = 0, y = 0, z = 45 }, fields = { locked = true } }),
        'move, turn and lock it in one update')
    eq(H.trace(), 'move:' .. uid(1) .. ' set:' .. uid(1), 'the move first, then the set')
    check(same(calls('move')[1].rot, { x = 0, y = 0, z = 45 }) and same(calls('set')[1].patch, { locked = true }),
        'with the new rotation and only the changed field')
    reset()
    check(update(1, { layer = 'deco' }), 'a change the node does not show (layer)')
    eq(#H.log, 0, 'no scene call')
    check(node(uid(1)) == veh, 'still the first node')
    reset()
    check(update(2, { fields = { model = 'a_m_y_x' } }, true), 'the ped loses its scenario')
    c = calls('set')[1]
    check(c and c.patch and next(c.patch) == nil and same(c.remove, { 'scenario' }), 'set with remove = { scenario }')

    local got = {}
    as('events', 'on', '*', callable(function(event, record) got[#got + 1] = event .. ':' .. record.uid end))
    reset()
    local first = node(uid(3))
    eq(first.kind, 'map:data', 'the point type is map:data')
    eq(as('deco', 'defineType', { id = 'deco:thing', kind = 'marker' }), true, 'the owner redefines it as a marker')
    eq(H.trace(), 'remove:' .. uid(3) .. ' spawn:' .. uid(3), 'another scene kind: remove + spawn')
    check(node(uid(3)).kind == 'marker' and node(uid(3)).audience == nil, 'a public marker node now')
    stop(env, 'deco')
    local ph = node(uid(3))
    check(ph.kind == 'map:data' and same(ph.fields, { t = 'deco:thing', k = 'placeholder', mapEl = uid(3),
        mapType = 'deco:thing' }) and same(ph.audience, { editors = true }),
        'its resource stopped: an editor-only placeholder (k = placeholder, t = the type id)')
    eq(#Maps.elements(map.id), 4, 'the record is kept')
    reset()
    eq(as('deco', 'defineType', { id = 'deco:thing', kind = 'marker' }), true, 'the type returns')
    eq(H.trace(), 'remove:' .. uid(3) .. ' spawn:' .. uid(3), 'the placeholder becomes a marker again')
    stop(env, 'garage')
    eq(node(uid(4)).fields.k, 'placeholder', 'a vehicle of a stopped type is a placeholder too')
    eq(R.netTotal(), 2, 'and no longer counts as networked (the core vehicle and the ped do)')
    as('garage', 'defineType', { id = 'garage:car', kind = 'vehicle', model = 'adder' })
    check(node(uid(4)).kind == 'vehicle' and R.netTotal() == 3, 'back: a vehicle node, counted again')
    stubs.tick(10)
    eq(#got, 0, 'type changes emit no events (the content did not change)')

    reset()
    H.refuse.set = 'fields'
    local before = printed('failed: fields')
    check(update(1, { fields = { plate = 'A1' } }), 'the apply itself succeeds')
    eq(printed('failed: fields'), before + 1, 'a refused set is logged')
    check(update(1, { fields = { plate = 'A2' } }), 'another change')
    eq(printed('failed: fields'), before + 1, 'the next refusal within a minute is not')
    H.refuse.set = nil
    reset()
    check(update(1, { fields = { plate = 'A3' } }), 'once Scene accepts again')
    check(same(calls('set')[1].patch, { plate = 'A3' }) and node(uid(1)).fields.plate == 'A3',
        'the next change brings the node up to date')

    H.refuse.spawn = 'hook'                                  -- a veto (not 'limit': that one is retried, below)
    check(Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 30, y = 0, z = 0 } } }, 1),
        'an element Scene refuses to spawn')
    eq(node(uid(5)), nil, 'has no node')
    check(#Maps.records('core:point') == 1, 'but it is active content (records, events)')
    eq(R.stats().retrying, 0, 'a veto is not retried')
    H.refuse.spawn = nil
    check(update(5, { pos = { x = 31, y = 0, z = 0 } }), 'its next change')
    eq(node(uid(5)).pos.x, 31.0, 'spawns it')

    local lost = node(uid(2))
    H.nodes[lost.id] = nil
    reset()
    check(update(2, { pos = { x = 6, y = 0, z = 0 } }), 'a node that went missing behind our back')
    eq(H.trace(), 'move:nil spawn:' .. uid(2), 'the move answers missing: spawned again')
    check(node(uid(2)) ~= nil and node(uid(2)).id ~= lost.id, 'a new node')
    eq(R.stats().nodes, 5, 'five nodes')
end

--------------------------------------------------------------------------------
-- respawn: promoted, displaced, changed and missing nodes go back to their authored state
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps, paintOf = Core.Maps, Core.MapsRuntime.paintOf
    as('catalogue', 'setModelValidator', callable(function() return true end))
    local map = Maps.create({ name = 'Respawn', mode = 'live', targetBucket = 3 }, 1)
    local function uid(id) return map.id .. ':' .. id end
    check(Maps.apply(map.id, {
        { op = 'create', type = 'core:vehicle', pos = { x = 1, y = 2, z = 3 }, rot = { x = 0, y = 0, z = 90 },
            fields = { model = 'adder', color = '#FF0000' } },
        { op = 'create', type = 'core:ped', pos = { x = 4, y = 0, z = 0 }, fields = { model = 'a_m_y_x' } },
        { op = 'create', type = 'core:physprop', pos = { x = 8, y = 0, z = 0 }, fields = { model = 'prop_crate' } },
        { op = 'create', type = 'core:point', pos = { x = 9, y = 0, z = 0 } },
    }, 1), 'vehicle, ped, physics prop, point')
    reset()
    eq(Maps.respawn(map.id), 0, 'nothing to do while every node is as placed')
    eq(#calls('move') + #calls('set') + #calls('spawn'), 0, 'and no scene call')

    local veh = node(uid(1))
    veh.promoted = { netId = 55 }
    veh.pos = { x = 40, y = 40, z = 3 }                     -- somebody drove it away
    veh.fields.props = { colorPrimary = 12, customPrimary = false }   -- props read back on a demote
    reset()
    eq(Maps.respawn(map.id, 1), 1, 'respawn of the promoted, driven vehicle')
    local mv, st = calls('move')[1], calls('set')[1]
    check(mv and mv.id == veh.id and mv.promoted == true and same(mv.pos, { x = 1, y = 2, z = 3 })
        and same(mv.rot, { x = 0, y = 0, z = 90 }), 'Scene.move of the promoted node to the authored pose (Scene demotes it)')
    local p1, s1 = paintOf(uid(1))
    check(st and st.id == veh.id and same(st.patch, { props = { colorPrimary = p1, colorSecondary = s1,
        customPrimary = { 255, 0, 0 }, customSecondary = { 255, 0, 0 } } }), 'Scene.set puts the authored props back')
    check(node(uid(1)) == veh and veh.promoted == nil and #calls('spawn') == 0, 'the same node, no new one')

    local ped = node(uid(2))
    ped.pos = { x = 4.5, y = 0, z = 0 }
    local prop = node(uid(3))
    prop.rot = { x = 0, y = 0, z = 0.005 }                  -- within 0.01°: not displaced
    reset()
    eq(Maps.respawn(map.id), 1, 'respawn all: only the displaced ped')
    check(#calls('move') == 1 and calls('move')[1].id == ped.id and ped.pos.x == 4, 'the ped is moved back')

    H.nodes[prop.id] = nil                                   -- the node is gone (e.g. removed with its clone)
    reset()
    eq(Maps.respawn(map.id, '3'), 1, 'respawn of an element whose node is missing (string id)')
    check(node(uid(3)) ~= nil and node(uid(3)).id ~= prop.id and calls('spawn')[1].uid == uid(3), 'spawned again')
    eq(Maps.respawn(map.id, 99), 0, 'an unknown element')
    eq(Maps.respawn('nope'), 0, 'an unknown map')
    eq(Maps.respawn(map.id, 'x'), 0, 'a bad id')

    local draft = Maps.create({ name = 'RD', mode = 'draft', targetBucket = 3 }, 1)
    Maps.apply(draft.id, { { op = 'create', type = 'core:ped', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'a_m_y_x' } } }, 1)
    Maps.setActive(draft.id, true, 1)
    Maps.publish(draft.id, 1)
    local bucket = Maps.openDraft(draft.id, 1)
    local a, na = node(draft.id .. ':1', bucket)
    local b = node(draft.id .. ':1', 3)
    check(na == 1 and a and b and a ~= b, 'a draft element has a node in its editor bucket and one in the target')
    a.pos, b.pos = { x = 1, y = 0, z = 0 }, { x = 2, y = 0, z = 0 }
    eq(Maps.respawn(draft.id), 2, 'respawn covers every active context of the map')
    check(a.pos.x == 0 and b.pos.x == 0, 'both are back')
end

--------------------------------------------------------------------------------
-- the Scene store barrier, the waiter, calls as core
--------------------------------------------------------------------------------
do
    local _, Core = newServer({ sceneLoaded = false })
    local Maps, R = Core.Maps, Core.MapsRuntime
    eq(#calls('defineKind'), 1, 'map:data is defined at start even before the store loaded')
    as('catalogue', 'setModelValidator', callable(function() return true end))
    local got = {}
    as('events', 'on', '*', callable(function(event, record) got[#got + 1] = event .. ':' .. record.uid end))
    local map = Maps.create({ name = 'Early', mode = 'live' }, 1)
    reset()
    check(Maps.apply(map.id, {
        { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } },
        { op = 'create', type = 'core:prop', pos = { x = 1, y = 0, z = 0 }, fields = { model = 'prop_a' } },
        { op = 'create', type = 'core:point', pos = { x = 2, y = 0, z = 0 } } }, 1), 'apply before the store loaded')
    check(Maps.apply(map.id, { { op = 'update', id = 2, set = { pos = { x = 3, y = 0, z = 0 } } } }, 1), 'and change it')
    eq(#H.log, 0, 'nothing reaches the scene')
    stubs.tick(10)
    eq(#got, 4, 'the events go on (three added, one changed)')
    eq(R.netTotal(), 1, 'the counts go on')
    eq(Maps.respawn(map.id), 0, 'respawn has nothing to do yet')
    check(R.stats().waiting == true and R.stats().nodes == 0, 'stats: waiting, no nodes')
    local draft = Maps.create({ name = 'Gone', mode = 'draft' }, 1)
    Maps.apply(draft.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    Maps.openDraft(draft.id, 1)
    Maps.closeDraft(draft.id)
    stubs.tick(2000)
    eq(#H.log, 0, 'still nothing while the store loads')
    H.sceneLoaded = true
    stubs.tick(1000)
    eq(#calls('spawn', 0), 3, 'the waiter projects every context once the store is there')
    eq(node(map.id .. ':2').pos.x, 3.0, 'with the current content')
    eq(#calls('remove'), 0, 'a context closed meanwhile costs nothing')
    check(R.stats().waiting == false and R.stats().nodes == 3, 'stats: done, three nodes')
    stubs.tick(5000)
    eq(#calls('spawn'), 3, 'the waiter is gone')

    local _, Core2 = newServer({ sceneLoaded = false })
    local m2 = Core2.Maps.create({ name = 'Slow', mode = 'live' }, 1)
    Core2.Maps.apply(m2.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    stubs.tick(29000)
    eq(printed('has not loaded'), 0, 'no warning before 30 s')
    stubs.tick(2000)
    eq(printed('has not loaded after 30 s'), 1, 'one warning after 30 s')
    stubs.tick(60000)
    eq(printed('has not loaded'), 1, 'and only one')
    H.sceneLoaded = true
    stubs.tick(1000)
    eq(#calls('spawn'), 1, 'projected once it loads')

    local _, Core3 = newServer()
    local m3 = Core3.Maps.create({ name = 'Plugin', mode = 'live' }, 1)
    reset()
    local ok = as('admin', 'apply', m3.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    check(ok == true, 'a plugin applies through the export')
    check(calls('spawn')[1].caller == 'core' and node(m3.id .. ':1').owner == 'core', 'the node is spawned AS core')
    as('admin', 'apply', m3.id, { { op = 'update', id = 1, set = { pos = { x = 1, y = 0, z = 0 } } } }, 1)
    as('admin', 'setActive', m3.id, false, 1)
    check(calls('move')[1].caller == 'core' and calls('remove')[1].caller == 'core', 'moved and removed as core too')
end

--------------------------------------------------------------------------------
-- drafts: editor bucket, publish, dirty, rollback, closeDraft, owner sweep
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps = Core.Maps
    local map = Maps.create({ name = 'Garage', mode = 'draft', targetBucket = 3 }, 1)
    reset()
    check(Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 1, y = 1, z = 1 } },
        { op = 'create', type = 'core:point', pos = { x = 2, y = 2, z = 2 } } }, 1), 'edit a closed draft')
    eq(#H.log, 0, 'a closed, unpublished draft shows nothing')
    local bucket = as('admin', 'openDraft', map.id, 1)
    local lo = Core.Config.Buckets.Range[1]
    check(type(bucket) == 'number' and bucket >= lo, 'openDraft allocates a bucket from the range')
    eq(Core.Buckets.info(bucket).owner, 'core', 'owned by core even when a plugin opens it')
    check(H.population[bucket] == false and H.lockdown[bucket] == 'strict', 'population off, lockdown strict')
    eq(as('admin', 'openDraft', map.id, 2), bucket, 'a second editor gets the same bucket')
    eq(#calls('spawn', bucket), 2, 'the draft is live in its editor bucket')
    eq(Maps.get(map.id).editorBucket, bucket, 'get() reports the editor bucket')
    eq(select(2, Maps.update(map.id, { targetBucket = bucket })), 'targetBucket', 'an editor bucket cannot be a target')
    reset()
    check(Maps.setActive(map.id, true, 1), 'activate the unpublished draft')
    eq(#calls('spawn', 3), 0, 'nothing published, nothing shown')
    eq(Maps.publish(map.id, 1, 'first'), 1, 'publish -> version 1')
    eq(#calls('spawn', 3), 2, 'the snapshot is shown in the target bucket')
    local target = node(map.id .. ':1', 3)
    eq(lastAudit('maps.publish').changes[1].new, 1, 'publish is audited')
    eq(Maps.get(map.id).dirty, false, 'not dirty after publishing')
    reset()
    check(Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 9, y = 9, z = 9 } } } }, 1), 'edit the draft')
    eq(#calls('move', bucket), 1, 'the editor bucket sees the edit')
    eq(#calls('move', 3), 0, 'the world does not')
    eq(Maps.get(map.id).dirty, true, 'dirty after an edit')
    reset()
    eq(Maps.publish(map.id, 1), 2, 'publish -> version 2')
    eq(H.trace(), 'move:' .. map.id .. ':1', 'only the changed element is moved (a diff by updatedAt)')
    check(node(map.id .. ':1', 3) == target and target.pos.x == 9.0, 'the same node, at its new position')
    reset()
    eq(Maps.rollback(map.id, 1, 1), 3, 'rollback publishes a copy as version 3')
    eq(H.trace(), 'move:' .. map.id .. ':1', 'the element goes back')
    eq(target.pos.x, 1.0, 'to its version-1 position')
    eq(Maps.elements(map.id)[1].pos.x, 9.0, 'the draft is untouched')
    eq(Maps.get(map.id).dirty, true, 'and differs from what is published')
    local versions = Maps.versions(map.id)
    check(#versions == 3 and versions[1].version == 3 and versions[1].current and versions[1].from == 1,
        'versions: newest first, current flagged, rollback source kept')
    eq(select(2, Maps.rollback(map.id, 42, 1)), 'version', 'rollback to an unknown version')
    eq(lastAudit('maps.rollback').ctx.from, 1, 'rollback is audited')
    local live = Maps.create({ name = 'L', mode = 'live' }, 1)
    eq(select(2, Maps.publish(live.id, 1)), 'mode', 'live maps are not published')
    eq(select(2, Maps.openDraft(live.id, 1)), 'mode', 'nor opened as drafts')
    reset()
    eq(Maps.closeDraft(map.id), true, 'closeDraft')
    eq(#calls('remove', bucket), 2, 'the editor bucket loses its nodes')
    eq(node(map.id .. ':1', bucket), nil, 'none is left there')
    eq(Core.Buckets.info(bucket), nil, 'the bucket is released')
    check(Maps.closeDraft(map.id) == false and #calls('remove', 3) == 0, 'closing twice is false; the published content stays')
    local b2 = as('admin', 'openDraft', map.id, 1)
    check(b2 ~= nil, 'open again')
    reset()
    stop(env, 'admin')
    eq(Maps.get(map.id).editorBucket, nil, 'the opener stopping closes the draft')
    eq(#calls('remove', b2), 2, 'and empties its bucket')
    for i = 1, 22 do Maps.publish(map.id, 1, 'v' .. i) end
    eq(#Maps.versions(map.id), 20, 'the newest 20 versions are kept')
    eq(H.row('SELECT version FROM map_versions WHERE map_id = $1 AND version = 1', { map.id }), nil,
        'older snapshots are deleted')
    eq(H.row('SELECT count(*)::int AS n FROM map_versions WHERE map_id = $1', { map.id }).n, 20, 'twenty rows are left')
end

--------------------------------------------------------------------------------
-- publish / rollback swap the target context by diff: removed, changed, added, untouched
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps = Core.Maps
    local map = Maps.create({ name = 'Swap', mode = 'draft', targetBucket = 9, active = true }, 1)
    local function uid(id) return map.id .. ':' .. id end
    Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 1, y = 0, z = 0 }, fields = { label = 'a' } },
        { op = 'create', type = 'core:point', pos = { x = 2, y = 0, z = 0 } },
        { op = 'create', type = 'core:marker', pos = { x = 3, y = 0, z = 0 } } }, 1)
    eq(Maps.publish(map.id, 1), 1, 'v1')
    local one, three = node(uid(1), 9), node(uid(3), 9)
    local got = {}
    as('events', 'on', '*', callable(function(event, record) got[#got + 1] = event .. ':' .. record.id end))
    Maps.apply(map.id, { { op = 'delete', id = 2 }, { op = 'update', id = 3, set = { fields = { bob = true } } },
        { op = 'create', type = 'core:hide', pos = { x = 4, y = 0, z = 0 }, fields = { model = 'prop_bench' } } }, 1)
    reset()
    eq(Maps.publish(map.id, 1), 2, 'v2')
    eq(H.trace(), 'remove:' .. uid(2) .. ' set:' .. uid(3) .. ' spawn:' .. uid(4),
        'the target bucket: element 2 removed, 3 set (same node), 4 spawned; 1 untouched')
    check(node(uid(1), 9) == one and node(uid(3), 9) == three and three.fields.bob == true, 'the kept nodes are the same')
    stubs.tick(10)
    eq(table.concat(got, ' '), 'removed:2 changed:3 added:4', 'and the events of the swap')
    reset()
    eq(Maps.rollback(map.id, 1, 1), 3, 'rollback to v1')
    eq(H.trace(), 'remove:' .. uid(4) .. ' spawn:' .. uid(2) .. ' set:' .. uid(3),
        'the same diff backwards (gone first, then ascending ids)')
    eq(three.fields.bob, false, 'the marker is as it was')
end

--------------------------------------------------------------------------------
-- re-entrancy: a synchronous Scene listener that calls back into Core.Maps mid-pass counts nothing twice
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    as('catalogue', 'setModelValidator', callable(function() return true end))
    local map = Maps.create({ name = 'Re', mode = 'live', active = false }, 1)
    Maps.apply(map.id, { { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } },
        { op = 'create', type = 'core:vehicle', pos = { x = 5, y = 0, z = 0 }, fields = { model = 'adder' } } }, 1)
    H.onSpawn = function()
        Maps.apply(map.id, { { op = 'update', id = 2, set = { pos = { x = 6, y = 0, z = 0 } } } }, 1)
    end
    check(Maps.setActive(map.id, true, 1), 'activate: the first spawn re-enters Core.Maps and shows element 2')
    local _, n2 = node(map.id .. ':2')
    check(R.netTotal() == 2 and n2 == 1 and node(map.id .. ':2').pos.x == 6.0, 'two counted, one node each, the latest pose')
    check(Maps.setActive(map.id, false, 1) and R.netTotal() == 0 and next(H.nodes) == nil, 'and all of it goes again')
end

--------------------------------------------------------------------------------
-- a Scene that throws: logged once a minute, the element stays active without a node
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps = Core.Maps
    local spawn = Core.Scene.spawn
    Core.Scene.spawn = function() error('boom') end
    local map = Maps.create({ name = 'Err', mode = 'live' }, 1)
    check(Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } },
        { op = 'create', type = 'core:point', pos = { x = 1, y = 0, z = 0 } } }, 1), 'the apply succeeds')
    eq(printed('Scene.spawn failed'), 1, 'one error line for two throws')
    eq(#Maps.records('core:point'), 2, 'the content is active')
    eq(Core.MapsRuntime.stats().nodes, 0, 'without nodes')
    Core.Scene.spawn = spawn
    eq(Maps.respawn(map.id), 2, 'respawn spawns them once Scene works again')
    eq(Core.MapsRuntime.stats().nodes, 2, 'two nodes')
end

--------------------------------------------------------------------------------
-- slicing (reviews RV4 F2, RV6 F6): a big activation makes <= SLICE Scene calls per server tick (one worker slice
-- per Wait(0)); the API stays honest mid-projection: stats, a second apply, a deactivation, a re-activation (the
-- standing nodes are adopted), core stopping; the pending boxes in GlobalState; openDraft, a first publish, the
-- boot projection and a type refresh go through the same worker
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    local SLICE, N = R.SLICE or 200, 1000
    eq(SLICE, 200, 'SLICE: 200 Scene calls per worker slice')
    H.countYields(env)
    local writes = H.recordGlobal(env, 'core:mapsPending')
    local map = H.bigMap(Maps, 'Big', N)
    local function uid(id) return map.id .. ':' .. id end
    eq(#calls('spawn'), 0, 'an inactive map projects nothing')
    reset()
    check(Maps.setActive(map.id, true, 1), 'activate a map of 1,000 props')
    local s = R.stats()
    eq(s.nodes, SLICE, 'right after the call ONE slice is projected (not 1,000 spawns in the caller\'s tick)')
    eq(s.pending, N - SLICE, 'stats: the rest is pending')
    eq(s.projecting, true, 'stats: the worker runs')
    eq(#Maps.records('core:prop'), N, 'the content itself is active at once (records, events)')
    eq(#writes, 0, 'no pending box for a run that may end within PUBLISH_AFTER slices')
    stubs.tick(0)
    local sl = H.slices()
    eq(sl[1].spawn, nil, 'nothing inline: the activation went through the worker')
    eq(#sl - 1, N // SLICE, 'five worker slices')
    local most = 0
    for i = 2, #sl do most = math.max(most, H.sliceCalls(sl[i])) end
    eq(most, SLICE, 'no slice made more than SLICE Scene calls')
    eq(#H.yields, #sl - 2, 'a Wait(0) (the next server tick) after every slice but the last')
    s = R.stats()
    check(s.nodes == N and s.pending == 0 and s.projecting == false, 'drained: 1,000 nodes, nothing pending, no worker')
    eq(#calls('spawn'), N, 'one spawn per element')
    eq(#writes, 2, 'a long run publishes its box once and clears it at the end')
    check(type(writes[1]) == 'table' and same(writes[1], { { 0, 1, 0, N, 0 } }),
        'GlobalState core:mapsPending = { { bucket 0, x1 1, y1 0, x2 1000, y2 0 } } while it ran')
    eq(writes[2], 'nil', 'and nil once the queue drained')

    -- a small change is reconciled inline: no worker, no pending box
    reset()
    check(Maps.apply(map.id, { { op = 'update', id = 3, set = { pos = { x = 3, y = 9, z = 0 } } } }, 1), 'a small apply')
    eq(H.trace(), 'move:' .. uid(3), 'moved inline')
    eq(#H.slices(), 1, 'no worker slice')
    eq(#writes, 2, 'no GlobalState write')

    -- a second apply mid-projection: a queued element changes (projected at once, its queue entry goes stale), a
    -- queued one is deleted (never spawned), a projected one moves
    check(Maps.setActive(map.id, false, 1), 'deactivate')
    stubs.tick(0)
    eq(R.stats().nodes, 0, 'every node removed (sliced)')
    reset()
    Maps.setActive(map.id, true, 1)
    eq(node(uid(900)), nil, 'element 900 is still queued')
    check(Maps.apply(map.id, { { op = 'update', id = 900, set = { pos = { x = 900, y = 5, z = 0 } } },
        { op = 'delete', id = 950 }, { op = 'update', id = 10, set = { pos = { x = 10, y = 5, z = 0 } } } }, 1),
        'an apply while the projection runs')
    check(node(uid(900)) ~= nil and node(uid(900)).pos.y == 5.0, 'the queued element is projected at once, changed')
    eq(node(uid(10)).pos.y, 5.0, 'the projected one moved')
    eq(R.stats().pending, N - SLICE - 2, 'stats: 900 left the queue, 950 is gone from it')
    stubs.tick(0)
    local _, n900 = node(uid(900))
    eq(n900, 1, 'one node for 900: its stale queue entry did nothing')
    eq(node(uid(950)), nil, 'the deleted element never spawned')
    eq(#calls('spawn'), N - 1, 'every other element spawned exactly once')
    eq(R.stats().nodes, N - 1, 'stats: 999 nodes')

    -- a deactivation mid-projection: what stands goes, what was queued never comes
    local m2 = H.bigMap(Maps, 'Big2', N, { y = 100 })
    reset()
    Maps.setActive(m2.id, true, 1)
    check(Maps.setActive(m2.id, false, 1), 'deactivated while its projection runs')
    s = R.stats()
    eq(s.pending, N - SLICE, 'stats: the queued entries are still due (they reconcile to nothing)')
    stubs.tick(0)
    eq(#calls('spawn'), SLICE, 'no spawn after the deactivation')
    eq(#calls('remove'), SLICE, 'the 200 that stood were removed')
    check(R.stats().pending == 0 and R.stats().closing == 0, 'stats: nothing pending, no closing context')

    -- a re-activation while the removal of the same context runs: the standing nodes are adopted, not re-made
    Maps.setActive(m2.id, true, 1)
    stubs.tick(0)
    reset()
    check(Maps.setActive(m2.id, false, 1), 'deactivate 1,000 standing nodes')
    eq(#calls('remove'), SLICE, 'the first removal slice ran at once')
    eq(R.stats().closing, 1, 'stats: the closed context keeps its other 800 nodes for the worker')
    eq(R.stats().nodes, (N - 1) + (N - SLICE), 'stats: nodes counts what still stands (the first map + 800)')
    check(Maps.setActive(m2.id, true, 1), 're-activated before the removal finished')
    stubs.tick(0)
    eq(#calls('remove'), SLICE, 'no further removal: the new context adopted the 800 standing nodes')
    eq(#calls('spawn'), SLICE, 'only the 200 removed ones were made again')
    check(R.stats().nodes == 2 * N - 1 and R.stats().closing == 0, 'stats: both maps fully projected again')
    local writesBefore = #writes

    -- core stops mid-projection: the worker ends without another Scene call
    local m3 = H.bigMap(Maps, 'Big3', N, { y = 200 })
    reset()
    Maps.setActive(m3.id, true, 1)
    stubs.tick(0)
    eq(#writes, writesBefore + 2, 'the long run published its box and cleared it')
    reset()
    Maps.setActive(m3.id, false, 1)
    Maps.setActive(m3.id, true, 1)                  -- adopted: 200 to make again, the worker holds them
    stubs.tick(0)
    reset()
    Maps.setActive(m3.id, false, 1)                 -- 1,000 to remove, one slice ran
    local after = #H.log
    H.shutdown(env)
    stubs.tick(1000)
    eq(#H.log, after, 'core stopped mid-slice: no Scene call after the stop')
    eq(#stubs.failures, 0, 'nothing threw')
end

do  -- openDraft, a first publish, the boot projection and a type refresh are sliced too
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    local SLICE, N = R.SLICE or 200, 600
    local draft = H.bigMap(Maps, 'Draft', N, { mode = 'draft', bucket = 4 })
    reset()
    local bucket = Maps.openDraft(draft.id, 1)
    eq(#calls('spawn', bucket), SLICE, 'openDraft: one slice in the caller\'s tick')
    stubs.tick(0)
    eq(#calls('spawn', bucket), N, 'the editor bucket fills over the next ticks')
    reset()
    Maps.setActive(draft.id, true, 1)
    eq(Maps.publish(draft.id, 1), 1, 'the first publish')
    eq(#calls('spawn', 4), SLICE, 'the first publish: one slice in the caller\'s tick')
    stubs.tick(0)
    eq(#calls('spawn', 4), N, 'then the rest')
    local most = 0
    for _, s in ipairs(H.slices()) do most = math.max(most, H.sliceCalls(s)) end
    check(most <= SLICE, 'no slice above SLICE')
    -- a plugin type with N elements: its resource stops (placeholders) and comes back — both sliced
    eq(as('deco', 'defineType', { id = 'deco:lamp', kind = 'prop', model = 'prop_lamp' }), true, 'a plugin prop type')
    local live = H.bigMap(Maps, 'Deco', N, { type = 'deco:lamp' })
    Maps.setActive(live.id, true, 1)
    stubs.tick(0)
    reset()
    stop(env, 'deco')
    eq(#calls('remove'), SLICE // 2, 'a type refresh of 600 elements: a kind change is remove + spawn, sliced')
    stubs.tick(0)
    check(#calls('remove') == N and #calls('spawn') == N, 'every element became a placeholder')
    most = 0
    for _, s in ipairs(H.slices()) do most = math.max(most, H.sliceCalls(s)) end
    check(most <= SLICE, 'no slice above SLICE')
    H.shutdown(env)

    -- the boot projection after a restart: every active context, through the worker
    local _, Core2 = newServer({ keepDb = true, sceneLoaded = false })
    local R2 = Core2.MapsRuntime
    eq(#calls('spawn'), 0, 'nothing before the scene store loaded')
    eq(R2.stats().pending, 2 * N, 'stats: the whole boot projection is pending (the published draft + the live map)')
    H.sceneLoaded = true
    stubs.tick(100)
    local sl = H.slices()
    eq(#sl - 1, 2 * N // SLICE, 'the boot projection ran in slices')
    most = 0
    for i = 1, #sl do most = math.max(most, H.sliceCalls(sl[i])) end
    eq(most, SLICE, 'none above SLICE')
    eq(R2.stats().nodes, 2 * N, 'every active context projected')
    H.shutdown(_)
end

--------------------------------------------------------------------------------
-- capacity (review RV4 F3): a spawn refused 'limit' is retried with backoff (5 s, doubling to 60 s while nothing gets
-- placed); after one 'limit' answer the rest of a pass is not tried; a freed slot of ours lets spawns through again
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    H.cap = 3                                          -- the fake answers 'limit' while 3 nodes exist
    local map = Maps.create({ name = 'Cap', mode = 'live' }, 1)
    local function uid(id) return map.id .. ':' .. id end
    local ops = {}
    for i = 1, 6 do ops[i] = { op = 'create', type = 'core:point', pos = { x = i, y = 0, z = 0 } } end
    check(Maps.apply(map.id, ops, 1), 'six elements, room for three')
    eq(R.stats().nodes, 3, 'three nodes')
    eq(#calls('spawn'), 4, 'the fourth spawn was refused; the fifth and sixth were not even tried')
    eq(R.stats().retrying, 3, 'stats: three elements wait for capacity')
    check(printed('failed: limit') >= 1, 'the refusal is logged')
    stubs.tick(4900)
    eq(#calls('spawn'), 4, 'nothing before the first retry (5 s)')
    stubs.tick(200)
    eq(#calls('spawn'), 5, 'a retry round at 5 s: one refused attempt, the rest held back')
    stubs.tick(9700)
    eq(#calls('spawn'), 5, 'the next round waits 10 s (nothing was placed)')
    stubs.tick(200)
    eq(#calls('spawn'), 6, 'round 2 at 15 s')
    stubs.tick(20000)
    eq(#calls('spawn'), 7, 'round 3 at 35 s (20 s later)')
    stubs.tick(40000)
    eq(#calls('spawn'), 8, 'round 4 at 75 s (40 s later)')
    stubs.tick(60000)
    eq(#calls('spawn'), 9, 'round 5 at 135 s (60 s: the cap of the backoff)')
    H.cap = 10                                         -- the cap frees
    stubs.tick(60000)
    eq(R.stats().nodes, 6, 'the next round places every waiting element')
    eq(R.stats().retrying, 0, 'nobody waits any more')
    local spawns = #calls('spawn')
    stubs.tick(300000)
    eq(#calls('spawn'), spawns, 'and the retry thread is gone')

    -- a removal of ours frees a slot: the held spawns pass at once (no waiting for the backoff)
    H.cap = 6
    check(Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 7, y = 0, z = 0 } } }, 1), 'a 7th')
    eq(node(uid(7)), nil, 'refused: the cap is full')
    check(Maps.apply(map.id, { { op = 'delete', id = 1 }, { op = 'update', id = 7, set = { pos = { x = 8, y = 0, z = 0 } } } }, 1),
        'delete one and change the waiting one in one apply')
    check(node(uid(7)) ~= nil and node(uid(7)).pos.x == 8.0, 'the freed slot takes it at once')
    eq(R.stats().retrying, 0, 'it no longer waits')
    -- respawn tries a held-back spawn again
    check(Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 9, y = 0, z = 0 } } }, 1), 'an 8th')
    eq(node(uid(8)), nil, 'refused')
    H.cap = 10
    eq(Maps.respawn(map.id, 8), 1, 'Maps.respawn of the waiting element')
    check(node(uid(8)) ~= nil and R.stats().retrying == 0, 'placed at once')
    -- a deactivated context forgets its waiting elements
    H.cap = 7
    check(Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 10, y = 0, z = 0 } } }, 1), 'a 9th')
    eq(R.stats().retrying, 1, 'waits')
    Maps.setActive(map.id, false, 1)
    eq(R.stats().retrying, 0, 'deactivated: nothing waits')
    H.shutdown(env)
end

--------------------------------------------------------------------------------
-- removals the editor watches fade (review RV5 F3); a live map switched off or swapped leaves visibility-safely
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps = Core.Maps
    as('catalogue', 'setModelValidator', callable(function() return true end))
    eq(as('deco', 'defineType', { id = 'deco:thing', kind = 'point' }), true, 'a plugin point type')
    local live = Maps.create({ name = 'Fade', mode = 'live' }, 1)
    Maps.apply(live.id, { { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'p' } },
        { op = 'create', type = 'deco:thing', pos = { x = 1, y = 0, z = 0 } },
        { op = 'create', type = 'core:prop', pos = { x = 2, y = 0, z = 0 }, fields = { model = 'p' } } }, 1)
    reset()
    Maps.apply(live.id, { { op = 'delete', id = 1 } }, 1, { source = 'editor' })
    eq(calls('remove')[1].fade, true, 'an element an apply deleted fades (it no longer lingers ≤ 10 s in view)')
    reset()
    eq(as('deco', 'defineType', { id = 'deco:thing', kind = 'marker' }), true, 'another scene kind for element 2')
    eq(H.trace(), 'remove:' .. live.id .. ':2 spawn:' .. live.id .. ':2', 'remove + spawn')
    eq(calls('remove')[1].fade, true, 'the old copy fades while the new one comes (no overlap of two copies)')
    reset()
    Maps.setActive(live.id, false, 1)
    local r = calls('remove')
    check(#r == 2 and not r[1].fade and not r[2].fade, 'a live map switched off: visibility-safe removal (no fade)')

    local draft = Maps.create({ name = 'FadeD', mode = 'draft', targetBucket = 6, active = true }, 1)
    Maps.apply(draft.id, { { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'p' } },
        { op = 'create', type = 'core:prop', pos = { x = 1, y = 0, z = 0 }, fields = { model = 'p' } } }, 1)
    Maps.publish(draft.id, 1)
    local bucket = Maps.openDraft(draft.id, 1)
    Maps.apply(draft.id, { { op = 'delete', id = 2 } }, 1)
    reset()
    Maps.publish(draft.id, 1)
    local pr = calls('remove', 6)
    check(#pr == 1 and not pr[1].fade, 'a publish swap removes the published copy visibility-safely (players)')
    reset()
    Maps.closeDraft(draft.id)
    local er = calls('remove', bucket)
    check(#er == 1 and er[1].fade == true, 'closeDraft: the editor bucket\'s nodes fade')
end

--------------------------------------------------------------------------------
-- promotion policy (review RV6 F8): nothing in an editor bucket is ever promoted; a map vehicle in its target bucket
-- is promoted by enter / damage only (no proximity), props and peds there keep the class default
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps = Core.Maps
    as('catalogue', 'setModelValidator', callable(function() return true end))
    local draft = Maps.create({ name = 'Auth', mode = 'draft', targetBucket = 8, active = true }, 1)
    Maps.apply(draft.id, {
        { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } },
        { op = 'create', type = 'core:ped', pos = { x = 1, y = 0, z = 0 }, fields = { model = 'a_m_y_x' } },
        { op = 'create', type = 'core:physprop', pos = { x = 2, y = 0, z = 0 }, fields = { model = 'prop_crate' } },
        { op = 'create', type = 'core:prop', pos = { x = 3, y = 0, z = 0 }, fields = { model = 'prop_a' } },
        { op = 'create', type = 'core:marker', pos = { x = 4, y = 0, z = 0 } },
        { op = 'create', type = 'core:point', pos = { x = 5, y = 0, z = 0 } } }, 1)
    Maps.publish(draft.id, 1)
    local bucket = Maps.openDraft(draft.id, 1)
    local function auth(id, b) local n = node(draft.id .. ':' .. id, b) return n and n.authority end
    local EDITOR = { mode = 'local', enter = false, damage = false }
    for id = 1, 4 do
        check(same(auth(id, bucket), EDITOR), 'editor bucket: element ' .. id .. ' is never promoted (local, no enter, no damage)')
    end
    check(auth(5, bucket) == nil and auth(6, bucket) == nil, 'markers and data nodes carry no policy')
    check(same(auth(1, 8), { mode = 'local' }), 'target bucket: the vehicle promotes on enter / damage only')
    check(auth(2, 8) == nil and auth(3, 8) == nil and auth(4, 8) == nil,
        'target bucket: ped, physics prop and prop keep their class default')
    local live = Maps.create({ name = 'AuthL', mode = 'live' }, 1)
    Maps.apply(live.id, { { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } } }, 1)
    check(same(node(live.id .. ':1', 0).authority, { mode = 'local' }), 'a live map vehicle: local too')
end

--------------------------------------------------------------------------------
-- against the REAL scene server (scene_kinds → scene_store → scene): every def validates, the model-info chain
-- fills lod / vtype from the §52 validator, moves keep the node, respawn demotes a promoted node (R.promote)
--------------------------------------------------------------------------------
do
    local _, Core = newServer({ scene = 'real' })
    local Maps, Scene, SR, paintOf = Core.Maps, Core.Scene, Core.SceneRuntime, Core.MapsRuntime.paintOf
    local kind = SR.kinds.get('map:data')
    check(kind and kind.owner == 'core' and kind.class == 'data' and kind.handler == 'core' and kind.radius == 150,
        'map:data is a core kind: class data, handler core, radius 150')
    eq(SR.kinds.tier(SR.kinds.radius(kind, { fields = {} }), false), 'S', 'its nodes are near-grid (tier S)')
    as('catalogue', 'setModelValidator', callable(function(k, model)
        if k == 'vehicle' then return true, { vehicleType = 'bike' } end
        if model == 'prop_tall' then return true, { lod = 300 } end
        return true
    end))
    eq(as('deco', 'defineType', { id = 'deco:sign', kind = 'point', preview = { { kind = 'label', text = '$text' } },
        fields = { { name = 'text', type = 'string', maxLength = 32 } } }), true, 'a plugin point type')
    local map = Maps.create({ name = 'Real', mode = 'live', targetBucket = 7 }, 1)
    local function uid(id) return map.id .. ':' .. id end
    check(Maps.apply(map.id, {
        { op = 'create', type = 'core:prop', pos = { x = 1, y = 2, z = 3 }, rot = { x = 10, y = 0, z = 45 },
            fields = { model = 'prop_tall', collision = false } },
        { op = 'create', type = 'core:physprop', pos = { x = 2, y = 2, z = 3 }, fields = { model = 'prop_crate' } },
        { op = 'create', type = 'core:vehicle', pos = { x = 3, y = 2, z = 3 }, rot = { x = 0, y = 0, z = 90 },
            fields = { model = 'bati', plate = 'AB 12', color = '#102030', locked = true } },
        { op = 'create', type = 'core:ped', pos = { x = 4, y = 2, z = 3 }, fields = { model = 'a_m_y_x', scenario = 'WORLD_HUMAN_SMOKING' } },
        { op = 'create', type = 'core:marker', pos = { x = 5, y = 2, z = 3 }, fields = { color = '#FF000080', bob = true } },
        { op = 'create', type = 'core:hide', pos = { x = 6, y = 2, z = 3 }, fields = { model = 'prop_bin_01a', radius = 3 } },
        { op = 'create', type = 'core:point', pos = { x = 7, y = 2, z = 3 }, fields = { label = 'start' } },
        { op = 'create', type = 'core:zone', pos = { x = 8, y = 2, z = 3 }, fields = { size = { x = 5, y = 6, z = 7 } } },
        { op = 'create', type = 'deco:sign', pos = { x = 9, y = 2, z = 3 }, fields = { text = 'hello' } },
    }, 1), 'one element of every kind')
    stop(_, 'deco')
    local ids = Scene.list({ owner = 'core' })
    eq(#ids, 9, 'the real Scene took a node for every element (the plugin type now a placeholder)')
    local byUid = {}
    for _, id in ipairs(ids) do
        local n = Scene.get(id)
        byUid[n.fields.mapEl] = n
    end
    local function n(id) return byUid[uid(id)] or {} end
    for i = 1, 9 do
        local x = n(i)
        check(x.bucket == 7 and x.persist == false and x.owner == 'core' and x.fields and x.fields.mapType ~= nil,
            'node ' .. i .. ': bucket 7, not persistent, owned by core, carries mapEl + mapType')
    end
    local p = n(1).fields or {}
    check(n(1).kind == 'prop' and p.lod == 300 and p.r == 2 and p.collision == false and p.frozen == true
        and p.invincible == true and p.physics == 'static', "prop: lod 300 through Scene's model-info chain")
    check(n(1).rot and n(1).rot.x == 10 and n(1).rot.z == 45, 'with its full rotation')
    eq((n(2).fields or {}).physics, 'promote', "physics prop: physics = 'promote'")
    local v = n(3).fields or {}
    check(n(3).kind == 'vehicle' and v.vtype == 'bike' and v.plate == 'AB 12' and v.locked == true and v.frozen == true
        and v.props and v.props.customPrimary[1] == 16 and v.props.customSecondary[3] == 48,
        'vehicle: vtype from the chain, plate, locked, frozen, custom colours')
    local pp, ps = paintOf(uid(3))
    check(v.props and v.props.colorPrimary == pp and v.props.colorSecondary == ps, "vehicle: the uid's paint passes the props rules")
    local pd = n(4).fields or {}
    check(n(4).kind == 'ped' and pd.scenario == 'WORLD_HUMAN_SMOKING' and pd.invincible and pd.frozen and pd.blockEvents,
        'ped: scenario, invincible, frozen, blockEvents')
    local mk = n(5).fields or {}
    check(n(5).kind == 'marker' and mk.color == '#FF000080' and mk.bob == true and mk.type == 1, 'marker')
    check(n(6).kind == 'hide' and (n(6).fields or {}).radius == 3, 'hide')
    for _, i in ipairs({ 7, 8, 9 }) do
        check(n(i).kind == 'map:data' and same(n(i).audience, { editors = true }), 'data node ' .. i .. ': editors only')
    end
    check((n(7).fields or {}).f and n(7).fields.f.label == 'start', 'point: f')
    check((n(8).fields or {}).size and n(8).fields.size.y == 6, 'zone: size')
    check((n(9).fields or {}).k == 'placeholder' and n(9).fields.t == 'deco:sign', 'placeholder: k, t')

    local propId = n(1).id
    check(Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 11, y = 2, z = 3 } } } }, 1), 'move the prop')
    local moved = Scene.get(propId)
    check(moved and moved.pos.x == 11 and moved.fields.mapEl == uid(1), 'the same node moved')
    check(Maps.apply(map.id, { { op = 'update', id = 4, replace = true, set = { fields = { model = 'a_m_y_x' } } } }, 1),
        'clear the ped scenario')
    eq(Scene.get(n(4).id).fields.scenario, nil, 'Scene.set removed it')

    local vehId = n(3).id
    SR.store.get(vehId).promoted = { netId = 9 }            -- promoted by proximity meanwhile
    H.promoteLog = {}
    eq(Maps.respawn(map.id), 1, 'respawn: only the promoted vehicle')
    local pl = H.promoteLog[1]
    check(pl and pl.what == 'move' and pl.id == vehId and pl.promoted == true,
        'Scene.move ran R.promote.beforeChange(node, move) on the promoted node')
    eq(Scene.get(vehId).promoted, nil, 'demoted')
    check(Maps.apply(map.id, { { op = 'update', id = 3, set = { fields = { plate = 'ZZ 99' } } } }, 1), 'a new plate')
    check(H.promoteLog[#H.promoteLog].what == 'set' and Scene.get(vehId).fields.plate == 'ZZ 99',
        'Scene.set (beforeChange set) on the same node')

    check(same(Scene.get(vehId).authority, { mode = 'local' }),
        'the real Scene took the map vehicle\'s policy (local: no proximity promotion, RV6 F8)')

    check(Maps.setActive(map.id, false, 1), 'deactivate')
    eq(#Scene.list({ owner = 'core' }), 0, 'every node is removed')
    H.shutdown(_)
end

do  -- review RV4 F3 on the REAL scene store: the global node cap is full (a plugin's nodes), a map element is refused
    -- 'limit'; once the plugin frees its nodes the retry gives the element its node — no Maps.respawn needed. And the
    -- editor bucket's policy passes the real Scene's authority check.
    local env, Core = newServer({ scene = 'real' })
    local Maps, Scene, R = Core.Maps, Core.Scene, Core.MapsRuntime
    env.Config.Scene.MaxNodes = 5
    env.Config.Scene.CoreReserve = { nodes = 0, persistent = 0 }
    local plugin = {}
    for i = 1, 5 do
        local _, id = Core.Registry.withCaller('someplugin', Scene.spawn, { kind = 'prop', pos = { x = i, y = 0, z = 0 },
            fields = { model = 'prop_a' } })
        plugin[i] = id
    end
    eq(#Scene.list({ owner = 'someplugin' }), 5, 'a plugin holds the whole (lowered) global budget')
    local map = Maps.create({ name = 'Cap', mode = 'live' }, 1)
    check(Maps.apply(map.id, { { op = 'create', type = 'core:prop', pos = { x = 50, y = 50, z = 10 },
        fields = { model = 'prop_a' } } }, 1), 'an element is created')
    check(R.stats().nodes == 0 and R.stats().retrying == 1, 'refused (limit): no node, it waits for capacity')
    for i = 1, 5 do Core.Registry.withCaller('someplugin', Scene.remove, plugin[i]) end
    stubs.tick(6000)
    eq(R.stats().nodes, 1, 'the plugin freed its nodes: the retry placed the element')
    eq(#Scene.list({ owner = 'core' }), 1, 'the real Scene holds it, owned by core')
    env.Config.Scene.MaxNodes = 100000
    as('catalogue', 'setModelValidator', callable(function() return true end))
    local draft = Maps.create({ name = 'Ed', mode = 'draft' }, 1)
    Maps.apply(draft.id, { { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } } }, 1)
    local bucket = Maps.openDraft(draft.id, 1)
    local ids = Scene.list({ owner = 'core', kind = 'vehicle' })
    local veh = ids[1] and Scene.get(ids[1])
    check(veh and veh.bucket == bucket and same(veh.authority, { mode = 'local', enter = false, damage = false }),
        'the editor bucket\'s vehicle: the real Scene keeps "never promote" (RV6 F8)')
    H.shutdown(env)
end

H.finish()
