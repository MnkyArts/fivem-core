--[[
    core/tests/maps_tests.lua — offline suite for Core.Maps (DESIGN §52.1, §52.2, §52.4a), part 1.

        lua5.4 tests/maps_tests.lua    (from the resource directory, or from tests/)

    Types, documents, tuples per kind, apply validation/atomicity, limits, the validator and networked
    elements (native stubs), expect/conflict/invert/restore, drafts (editor bucket, publish, rollback),
    events, hooks, validate, parents, refs, migrate, id caps. Harness: tests/maps_harness.lua. Journal,
    clear, expiry, persistence: tests/maps_store_tests.lua. Exit 1 on failure.
]]

local here = (arg and arg[0] or 'tests/maps_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local H = dofile(here .. '/maps_harness.lua')
local stubs, check, eq, callable, calls, reset = H.stubs, H.check, H.eq, H.callable, H.calls, H.reset
local newServer, as, stop, lastAudit, byUid = H.newServer, H.as, H.stop, H.lastAudit, H.byUid

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
-- documents, a live map, tuples per kind (§52.4a)
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
    eq(#calls('put', 0), 5, 'five tuples are put in bucket 0')
    local prop = byUid(calls('put'), map.id .. ':1').tuple
    eq(prop[1], map.id .. ':1', 'tuple uid = <mapId>:<elementId>')
    eq(prop[2], 1, 'kind code 1 = prop')
    eq(prop[3], R.joaat('prop_barrier'), 'signed joaat model hash')
    eq(prop[4], 1.235, 'coordinates rounded to 3 decimals')
    eq(prop[9], 12.35, 'rotations rounded to 2 decimals')
    eq(prop[10], 7, 'flags: collision | frozen | unbreakable')
    eq(prop[11], 150, 'lod 150 without validator info')
    eq(prop[12], nil, 'props carry no extra')
    local marker = byUid(calls('put'), map.id .. ':2').tuple
    eq(marker[2], 2, 'kind code 2 = marker')
    eq(marker[3], 0, 'non-model kinds hash 0')
    local ex = marker[12]
    check(ex.type == 2 and ex.r == 255 and ex.g == 0 and ex.b == 0 and ex.a == 128, 'marker extra: type and rgba')
    check(ex.sx == 2 and ex.sz == 1 and ex.dd == 50 and ex.bob == true and ex.face == false, 'marker extra: scale, dd, bob, face')
    local hide = byUid(calls('put'), map.id .. ':3').tuple
    check(hide[2] == 3 and hide[3] == R.joaat('prop_bin_01a') and hide[12].radius == 3, 'hide: kind 3, model hash, radius')
    local point = byUid(calls('put'), map.id .. ':4').tuple
    check(point[2] == 4 and point[10] == 16 and point[9] == 90 and point[12].t == 'core:point'
        and point[12].f.label == 'start', 'point: kind 4, data flag, yaw, extra t + the $label field')
    local zone = byUid(calls('put'), map.id .. ':5').tuple
    check(zone[2] == 5 and zone[10] == 16 and zone[12].sx == 5 and zone[12].sz == 7 and zone[12].t == 'core:zone'
        and zone[12].f == nil, 'zone: kind 5, data flag, size, extra t (no label preview: no f)')
    Maps.apply(map.id, { { op = 'create', type = 'garage:spot', pos = { x = 0, y = 0, z = 0 }, fields = { note = ('n'):rep(70) } } }, 1)
    local spotX = byUid(calls('put'), map.id .. ':6').tuple[12]
    check(spotX.t == 'garage:spot' and spotX.f.slot == '3' and #spotX.f.note == 64, 'extra.f: $field labels as strings <= 64')
    check(stubs.kvp['doc:map_elements:' .. map.id .. ':1'] ~= nil, 'each element is its own document')
    eq(#Maps.elements(map.id), 6, 'elements() lists the working set')
    eq(Maps.elements(map.id)[1].id, '1', 'ascending ids')
    eq(Maps.get(map.id).counts.elements, 6, 'get() counts elements')
    eq(Maps.get(map.id).counts.uniqueModels, 1, 'hides do not count as streamed models')

    reset()
    local kvpBefore = stubs.kvp['doc:map_elements:' .. map.id .. ':2']
    ok = Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 5, y = 5, z = 5 } } } }, 1)
    check(ok, 'an update by numeric id')
    eq(#calls('put', 0), 1, 'one put moves the element')
    eq(calls('put', 0)[1].tuple[4], 5.0, 'at its new position')
    eq(stubs.kvp['doc:map_elements:' .. map.id .. ':2'], kvpBefore, 'untouched elements are not rewritten')
    reset()
    ok = Maps.apply(map.id, { { op = 'delete', id = '1' } }, 1)
    check(ok, 'a delete')
    eq(#calls('remove', 0), 1, 'one remove')
    eq(calls('remove', 0)[1].uid, map.id .. ':1', 'of that uid')
    eq(stubs.kvp['doc:map_elements:' .. map.id .. ':1'], nil, 'its document is gone')

    reset()
    local updated = Maps.update(map.id, { targetBucket = 5, name = 'Arena' }, 1)
    eq(updated.targetBucket, 5, 'update moves the target bucket')
    eq(#calls('remove', 0), 5, 'content leaves bucket 0')
    eq(#calls('put', 5), 5, 'and appears in bucket 5')
    local u = lastAudit('maps.update')
    check(u and #u.changes == 2, 'update is audited with its changes')
    eq(select(2, Maps.update(map.id, { name = 5 })), 'name', 'update refuses a bad name')
    eq(Maps.get(map.id).name, 'Arena', 'and changes nothing then')
end

--------------------------------------------------------------------------------
-- apply validation and atomicity
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps = Core.Maps
    local map = Maps.create({ name = 'V', mode = 'live' }, 1)
    local prop = { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'prop_a' } }
    local function refused(ops, want, label, opts)
        reset()
        local before = Maps.get(map.id)
        local ok, err, detail = Maps.apply(map.id, ops, 1, opts)
        check(ok == nil and err == want, ('%s -> %s (got %s)'):format(label, want, tostring(err)))
        local after = Maps.get(map.id)
        check(after.counts.elements == before.counts.elements and after.nextElementId == before.nextElementId
            and after.journalSeq == before.journalSeq and #H.regionLog == 0, label .. ': nothing changed')
        return detail
    end
    local detail = refused({ prop, { op = 'create', type = 'nope:x', pos = { x = 0, y = 0, z = 0 } } }, 'type',
        'an unknown type after a valid create')
    eq(detail.index, 2, 'the detail names the failing op')
    refused({ { op = 'create', type = 'core:prop', pos = { x = 20000, y = 0, z = 0 }, fields = { model = 'p' } } },
        'bounds', 'outside the world')
    refused({ { op = 'create', type = 'core:prop', pos = { x = 0 / 0, y = 0, z = 0 }, fields = { model = 'p' } } },
        'position', 'a NaN position')
    refused({ { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 }, rot = { x = 10, y = 0, z = 0 } } },
        'rotation', 'pitch on a yaw-only type')
    refused({ { op = 'create', type = 'core:hide', pos = { x = 0, y = 0, z = 0 }, rot = { x = 0, y = 0, z = 5 },
        fields = { model = 'x' } } }, 'rotation', 'any rotation on a fixed type')
    detail = refused({ { op = 'create', type = 'core:marker', pos = { x = 0, y = 0, z = 0 }, fields = { markerType = 99 } } },
        'fields', 'a field out of range')
    eq(detail.fields.markerType, 'max', 'the field error is reported')
    detail = refused({ { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 }, fields = { color = 1 } } },
        'fields', 'an unknown field')
    eq(detail.fields.color, 'unknown', 'as unknown')
    refused({ { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'bad model' } } },
        'fields', 'a model name that is not a name')
    refused({ { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } } },
        'no_validator', 'a vehicle without a model validator')
    refused({ { op = 'create', type = 'core:physprop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'p' } } },
        'no_validator', 'a networked prop without a model validator')
    refused({ { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'p' }, layer = 'a b' } },
        'layer', 'a bad layer name')
    refused({ { op = 'spin', id = 1 } }, 'op', 'an unknown op')
    refused({ { op = 'update', id = 99, set = {} } }, 'not_found', 'updating a missing element')
    refused({ { op = 'delete', id = 'x' } }, 'not_found', 'deleting a bad id')
    refused({}, 'ops', 'an empty op list')
    refused({ prop }, 'source', 'an unknown source', { source = 'hack' })
    check(Maps.apply('nope', { prop }, 1) == nil, 'an unknown map is refused')

    reset()
    local ok, applied = Maps.apply(map.id, { prop, { op = 'update', id = 1, set = { pos = { x = 1, y = 1, z = 1 } } },
        { op = 'create', type = 'core:point', pos = { x = 2, y = 2, z = 2 } }, { op = 'delete', id = 2 } }, 1)
    check(ok, 'later ops see earlier ones (create, update it, create, delete it)')
    eq(#Maps.elements(map.id), 1, 'one element remains')
    eq(Maps.elements(map.id)[1].pos.x, 1.0, 'with the update applied')
    eq(#calls('put', 0), 1, 'the world got the final state once')
    eq(#calls('remove', 0), 0, 'and nothing was removed (element 2 never existed outside the apply)')
    eq(applied.seq, 1, 'the journal sequence')
    eq(Maps.get(map.id).nextElementId, 3, 'both ids are used up')

    Core.Settings.set('maps.limits.opsPerApply', 2)
    refused({ prop, prop, prop }, 'too_many_ops', 'more ops than maps.limits.opsPerApply')
end

--------------------------------------------------------------------------------
-- limits (settings and per map), increase-only refusal
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps = Core.Maps
    local map = Maps.create({ name = 'L', mode = 'live' }, 1)
    local function create(model, typeId)
        return { op = 'create', type = typeId or 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = model } }
    end
    Core.Settings.set('maps.limits.elements', 3)
    check(Maps.apply(map.id, { create('a'), create('b'), create('c') }, 1), 'up to the element limit')
    local ok, err, detail = Maps.apply(map.id, { create('d') }, 1)
    check(ok == nil and err == 'limit' and detail.limit == 'elements' and detail.max == 3, 'the element limit')
    Core.Settings.set('maps.limits.elements', 2)
    check(Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 1, y = 1, z = 1 } } } }, 1),
        'a lowered limit does not block an update')
    check(Maps.apply(map.id, { { op = 'delete', id = 3 } }, 1), 'nor a delete')
    Core.Settings.reset('maps.limits.elements')

    Maps.update(map.id, { limits = { perModel = 2 } }, 1)
    check(Maps.apply(map.id, { create('a') }, 1), 'a second of one model')
    ok, err, detail = Maps.apply(map.id, { create('a') }, 1)
    check(err == 'limit' and detail.limit == 'perModel' and detail.model == 'a', 'the per-model limit (per-map override)')
    Maps.update(map.id, { limits = { uniqueModels = 2 } }, 1)
    ok, err, detail = Maps.apply(map.id, { create('z') }, 1)
    check(err == 'limit' and detail.limit == 'uniqueModels', 'the unique-model limit')
    eq(Maps.get(map.id).limits.perModel, nil, 'update replaces the per-map limits')
    Maps.update(map.id, { limits = false }, 1)
    eq(Maps.get(map.id).limits, nil, 'limits = false clears them')

    eq(as('race', 'defineType', { id = 'race:start', kind = 'point', limits = { perMap = 1 } }), true, 'a type with perMap')
    check(Maps.apply(map.id, { { op = 'create', type = 'race:start', pos = { x = 0, y = 0, z = 0 } } }, 1), 'one start')
    ok, err, detail = Maps.apply(map.id, { { op = 'create', type = 'race:start', pos = { x = 1, y = 0, z = 0 } } }, 1)
    check(err == 'limit' and detail.limit == 'perMap' and detail.type == 'race:start', 'the per-type limit')
end

--------------------------------------------------------------------------------
-- the model validator and networked elements (server entities)
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
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
    reset()
    local ok, applied = Maps.apply(map.id, {
        { op = 'create', type = 'core:vehicle', pos = { x = 1, y = 2, z = 3 }, rot = { x = 0, y = 0, z = 90 },
            fields = { model = 'bati', plate = 'EVENT 1', color = '#102030', locked = true } },
        { op = 'create', type = 'core:ped', pos = { x = 4, y = 5, z = 6 }, fields = { model = 'a_m_y_x', scenario = 'WORLD_HUMAN_SMOKING' } },
        { op = 'create', type = 'core:physprop', pos = { x = 7, y = 8, z = 9 }, rot = { x = 10, y = 0, z = 0 }, fields = { model = 'prop_crate' } },
        { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'prop_tall' } },
        { op = 'create', type = 'core:prop', pos = { x = 1, y = 0, z = 0 }, fields = { model = 'prop_tall' } },
    }, 1)
    check(ok, 'networked elements pass with a validator')
    eq(#seen, 4, 'the validator is asked once per distinct model')
    eq(applied.ops[1].after.info.vehicleType, 'bike', 'the vehicle type is kept on the element')
    eq(applied.ops[4].after.info.lod, 300, 'the lod is kept on the element')
    eq(applied.ops[4].after.info.junk, nil, 'nothing else from the validator is kept')
    eq(byUid(calls('put', 7), map.id .. ':4').tuple[11], 300, 'the prop tuple uses the validator lod')
    eq(#calls('put'), 2, 'networked elements are never packed')
    eq(#H.natives, 3, 'three entities are created')
    local veh = H.natives[1]
    check(veh.name == 'CreateVehicleServerSetter' and veh.args[1] == R.joaat('bati') and veh.args[2] == 'bike'
        and veh.args[6] == 90.0, 'CreateVehicleServerSetter(hash, vehicleType, x, y, z, heading)')
    local ped = H.natives[2]
    check(ped.name == 'CreatePed' and ped.args[1] == 4 and ped.args[7] == true and ped.args[8] == true, 'CreatePed(4, …, true, true)')
    local obj = H.natives[3]
    check(obj.name == 'CreateObjectNoOffset' and obj.args[5] == true and obj.args[6] == true and obj.args[7] == true,
        'CreateObjectNoOffset(…, true, true, true)')
    local function entityOf(elementId)
        for handle, rec in pairs(stubs.entities) do
            local state = stubs.entityState(env, handle)
            if rec.exists and state.mapEl == map.id .. ':' .. elementId then return handle, rec, state end
        end
    end
    local vh, vrec, vstate = entityOf('1')
    check(vh ~= nil, 'the vehicle carries the mapEl state bag')
    eq(vrec.bucket, 7, 'entities are moved into the target bucket')
    eq(vrec.orphanMode, 2, 'orphan mode 2 (keep)')
    eq(vrec.plate, 'EVENT 1', 'the plate is set')
    eq(vrec.lockState, 2, 'locked')
    check(vrec.primary[1] == 16 and vrec.secondary[3] == 48, 'the colour is set')
    eq(vstate.mapCfg.locked, true, 'mapCfg carries the lock for the client')
    local _, prec, pstate = entityOf('2')
    eq(prec.frozen, true, 'a frozen ped is frozen')
    check(pstate.mapCfg.invincible == true and pstate.mapCfg.scenario == 'WORLD_HUMAN_SMOKING', 'mapCfg: invincible, scenario')
    local _, orec, ostate = entityOf('3')
    check(orec.rot and orec.rot.x == 10.0 and orec.rot.order == 2, 'a rotated physics prop gets SetEntityRotation(…, 2)')
    check(ostate.mapCfg.rot.x == 10 and ostate.mapCfg.rot.z == 0, 'mapCfg.rot for the owning client')

    reset()
    local sentBefore = #stubs.sent
    check(Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 50, y = 50, z = 50 } } } }, 1), 'move the vehicle')
    eq(vrec.exists, true, 'moved in place: the entity stays')
    eq(#H.natives, 0, 'nothing is created')
    local pose = H.poses(sentBefore + 1)
    check(#pose == 1 and pose[1].target == 1 and pose[1].args[1] == vrec.netId and pose[1].args[2] == map.id .. ':1'
        and pose[1].args[3] == 50.0 and pose[1].args[8] == 90.0, 'core:maps:pose (netId, uid, x, y, z, rx, ry, rz) to the owner')
    stubs.coords[vh], stubs.headings[vh] = stubs.vector3(50.0, 50.0, 50.4), 90.0   -- the owning client applied it
    stubs.tick(2100)
    eq(entityOf('1'), vh, 'the synced pose matches: still the same entity')
    local nh = vh
    eq(Maps.respawn(map.id), 0, 'respawn has nothing to do while every entity exists')
    stubs.entities[nh].exists = false
    eq(Maps.respawn(map.id, 1), 1, 'respawn re-creates a destroyed element')
    check(entityOf('1') ~= nil, 'the vehicle is back')
    check(Maps.apply(map.id, { { op = 'delete', id = 2 } }, 1), 'delete the ped')
    eq(prec.exists, false, 'its entity is deleted')

    stubs.spawnDelayMs = 200
    reset()
    check(Maps.apply(map.id, { { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } } }, 1),
        'a slow vehicle')
    local slow = nil
    for handle, rec in pairs(stubs.entities) do if rec.model == R.joaat('adder') then slow = handle end end
    eq(stubs.entities[slow].exists, false, 'not there yet')
    check(Maps.apply(map.id, { { op = 'delete', id = 6 } }, 1), 'deleted while it is still being created')
    stubs.tick(300)
    eq(stubs.entities[slow].exists, false, 'the worker deletes it once it appears')
    stubs.spawnDelayMs = 0

    reset()
    local ok2, err = Maps.apply(map.id, { { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'nope' } } }, 1)
    check(ok2 == nil and err == 'model', 'the validator refuses a model')
    check(Maps.setActive(map.id, false, 1), 'deactivate the live map')
    local alive = 0
    for _, rec in pairs(stubs.entities) do if rec.exists then alive = alive + 1 end end
    eq(alive, 0, 'deactivation deletes every map entity')
    eq(#calls('remove', 7), 2, 'and removes both props from the regions')
    check(Maps.setActive(map.id, true, 1), 'activate again')
    check(entityOf('1') ~= nil, 'entities come back with the content')
    stop(env, 'catalogue')
    local ok3, err3 = Maps.apply(map.id, { { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } } }, 1)
    check(ok3 == nil and err3 == 'no_validator', 'the validator goes with its resource')
    stop(env, 'core')
    eq(entityOf('1'), nil, 'core stopping deletes its map entities')
end

--------------------------------------------------------------------------------
-- networked elements updated in place, stable vehicle paint (§52.2 notes, run UX C2)
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    as('catalogue', 'setModelValidator', callable(function(kind)
        return true, kind == 'vehicle' and { vehicleType = 'automobile' } or nil
    end))
    local map = Maps.create({ name = 'Place', mode = 'live', targetBucket = 5 }, 1)
    local function uid(id) return map.id .. ':' .. id end
    local function entityOf(id, bucket)
        for handle, rec in pairs(stubs.entities) do
            if rec.exists and stubs.entityState(env, handle).mapEl == uid(id)
                and (bucket == nil or rec.bucket == bucket) then return handle, rec end
        end
    end
    local function alive(id)
        local n = 0
        for handle, rec in pairs(stubs.entities) do
            if rec.exists and stubs.entityState(env, handle).mapEl == uid(id) then n = n + 1 end
        end
        return n
    end
    local function update(id, set) return Maps.apply(map.id, { { op = 'update', id = id, set = set } }, 1) end
    local function replace(id, fields)
        return Maps.apply(map.id, { { op = 'update', id = id, replace = true, set = { fields = fields } } }, 1)
    end
    --- the owning client applied the pose event: the synced position/heading the server reads
    local function landed(h, x, y, z, heading) stubs.coords[h], stubs.headings[h] = stubs.vector3(x, y, z), heading end
    reset()
    check(Maps.apply(map.id, {
        { op = 'create', type = 'core:vehicle', pos = { x = 10, y = 10, z = 30 }, fields = { model = 'sultan' } },
        { op = 'create', type = 'core:ped', pos = { x = 20, y = 10, z = 30 }, rot = { x = 0, y = 0, z = 45 },
            fields = { model = 'a_m_y_x', frozen = true, invincible = true, scenario = 'WORLD_HUMAN_SMOKING' } },
        { op = 'create', type = 'core:physprop', pos = { x = 30, y = 10, z = 30 }, fields = { model = 'prop_crate' } },
        { op = 'create', type = 'core:vehicle', pos = { x = 40, y = 10, z = 30 },
            fields = { model = 'sultan', color = '#FF0000', plate = 'EVT' } },
    }, 1), 'a vehicle, a ped, a physics prop and a painted vehicle')

    -- paint: picked from the uid when `color` is unset; a set colour paints over it
    local vh, vrec = entityOf(1)
    local p1, s1 = R.paintOf(uid(1))
    check(math.type(p1) == 'integer' and p1 >= 0 and p1 <= 160 and math.type(s1) == 'integer', 'a paint index pair')
    check(vrec.colours and vrec.colours[1] == p1 and vrec.colours[2] == s1, 'a vehicle without colour gets its uid paint')
    eq(vrec.primary, nil, 'and no custom colour')
    local _, crec = entityOf(4)
    check(crec.primary and crec.primary[1] == 255 and crec.primary[2] == 0 and crec.secondary[1] == 255,
        'a set colour paints over it (custom primary + secondary)')
    local distinct, n = {}, 0
    for i = 1, 8 do
        local p = R.paintOf('m' .. i .. ':' .. i)
        if not distinct[p] then distinct[p], n = true, n + 1 end
        eq((R.paintOf('m' .. i .. ':' .. i)), p, 'the same uid always gets the same paint (' .. i .. ')')
    end
    check(n >= 2, 'different uids get different paints (' .. n .. ' of 8 distinct)')

    -- rotate: in place, the heading goes to the owning client, the paint is not touched
    reset()
    local from = #stubs.sent
    check(update(1, { rot = { x = 0, y = 0, z = 45 } }), 'rotate the vehicle')
    eq(entityOf(1), vh, 'rotated in place: the same entity (and net id)')
    check(#H.natives == 0 and vrec.exists, 'nothing is created or deleted')
    local ev = H.poses(from + 1)
    check(#ev == 1 and ev[1].target == 1 and ev[1].args[1] == vrec.netId and ev[1].args[2] == uid(1)
        and ev[1].args[3] == 10.0 and ev[1].args[8] == 45.0, 'core:maps:pose with the new heading to the owner')
    eq(#H.rpcCalls('SetVehicleColours'), 0, 'the paint is not set again')
    landed(vh, 10, 10, 30.2, 45.0)
    stubs.tick(2100)
    eq(entityOf(1), vh, 'the synced heading matches after 2 s: kept')

    -- a move the owning client never applied (it lost control meanwhile) is re-created there
    reset()
    check(update(1, { pos = { x = 15, y = 12, z = 30 } }), 'move the vehicle')
    eq(entityOf(1), vh, 'moved in place first')
    stubs.tick(2100)
    local vh2, vrec2 = entityOf(1)
    check(vh2 ~= nil and vh2 ~= vh and vrec.exists == false, 'still at the old place after 2 s: re-created')
    local c = H.natives[1]
    check(c and c.args[3] == 15.0 and c.args[4] == 12.0 and c.args[6] == 45.0, 'at the new pose')
    check(vrec2.colours[1] == p1 and vrec2.colours[2] == s1, 'with the same paint as the first spawn')

    -- what keeps the respawn path: another model, the server owning it, a wreck, another bucket
    reset()
    check(update(1, { fields = { model = 'adder' } }), 'another model')
    local vh3 = entityOf(1)
    check(vh3 ~= vh2 and stubs.entities[vh2].exists == false and #H.natives == 1, 'a model change re-creates')
    reset()
    H.owners[vh3] = -1
    check(update(1, { pos = { x = 16, y = 12, z = 30 } }), 'move while the server owns it')
    local vh4 = entityOf(1)
    check(vh4 ~= vh3 and #H.natives == 1, 'nobody near: re-created at once (exact and unseen)')
    reset()
    stubs.health[vh4] = 0
    check(update(1, { rot = { x = 0, y = 0, z = 90 } }), 'rotate a wreck')
    local vh5 = entityOf(1)
    check(vh5 ~= vh4 and #H.natives == 1, 'a dead entity is re-created')
    reset()
    stubs.entities[vh5].bucket = 99
    check(update(1, { pos = { x = 17, y = 12, z = 30 } }), 'move an entity someone put in another bucket')
    local vh6, r6 = entityOf(1)
    check(vh6 ~= vh5 and r6.bucket == 5, 'another bucket: re-created in the map bucket')

    -- field-only changes: RPCs + mapCfg, no pose event, no new entity
    reset()
    from = #stubs.sent
    check(update(1, { fields = { plate = 'NEW 1', locked = true } }), 'plate and lock')
    eq(entityOf(1), vh6, 'a field change keeps the entity')
    check(r6.plate == 'NEW 1' and r6.lockState == 2, 'plate and lock set by RPC')
    eq(stubs.entityState(env, vh6).mapCfg.locked, true, 'mapCfg carries the lock')
    eq(#H.poses(from + 1), 0, 'no pose event without a move')
    eq(#H.rpcCalls('SetVehicleNumberPlateText'), 1, 'one plate RPC')
    reset()
    check(update(1, { fields = { locked = false, color = '#00FF00' } }), 'unlock and paint')
    check(r6.lockState == 1 and r6.primary[2] == 255 and r6.secondary[2] == 255, 'unlocked (1) and painted in place')
    eq(stubs.entityState(env, vh6).mapCfg.locked, false, 'mapCfg: unlocked')
    check(entityOf(1) == vh6 and #H.rpcCalls('SetVehicleNumberPlateText') == 0, 'same entity, the plate untouched')
    reset()
    check(replace(1, { model = 'adder', plate = 'NEW 1' }), 'the colour cleared')
    local vh7, r7 = entityOf(1)
    check(vh7 ~= vh6 and r7.primary == nil and r7.colours[1] == p1, 'a cleared colour re-creates, back to the uid paint')
    reset()
    check(replace(1, { model = 'adder' }), 'the plate cleared')
    check(entityOf(1) ~= vh7, 'a cleared plate re-creates')

    -- a ped: frozen and scenario in place, invincible on -> off re-creates
    local ph, prec = entityOf(2)
    eq(prec.frozen, true, 'the ped was frozen on creation')
    reset()
    check(update(2, { fields = { frozen = false, scenario = 'WORLD_HUMAN_AA_COFFEE' } }), 'unfreeze, another scenario')
    eq(entityOf(2), ph, 'the ped stays')
    eq(prec.frozen, false, 'unfrozen by RPC')
    local pcfg = stubs.entityState(env, ph).mapCfg
    check(pcfg.frozen == false and pcfg.scenario == 'WORLD_HUMAN_AA_COFFEE' and pcfg.invincible == true,
        'mapCfg updated for the owning client')
    reset()
    check(replace(2, { model = 'a_m_y_x', invincible = true, frozen = false }), 'the scenario cleared')
    check(entityOf(2) == ph and prec.tasksCleared == true, 'ClearPedTasks ends it, same ped')
    reset()
    from = #stubs.sent
    check(update(2, { pos = { x = 21, y = 11, z = 30 }, rot = { x = 0, y = 0, z = 90 } }), 'move the ped')
    ev = H.poses(from + 1)
    check(entityOf(2) == ph and #ev == 1 and ev[1].args[3] == 21.0 and ev[1].args[8] == 90.0, 'a ped moves in place')
    landed(ph, 21, 11, 30, 90.0)
    reset()
    check(update(2, { fields = { invincible = false } }), 'no longer invincible')
    check(entityOf(2) ~= ph and prec.exists == false, 'invincible on -> off re-creates (the native is client-only)')

    -- a physics prop: full rotation in the pose event and mapCfg.rot, checked by position only
    local oh = entityOf(3)
    reset()
    from = #stubs.sent
    check(update(3, { rot = { x = 15, y = 0, z = 30 } }), 'tilt the physics prop')
    ev = H.poses(from + 1)
    check(entityOf(3) == oh and #ev == 1 and ev[1].args[6] == 15.0 and ev[1].args[8] == 30.0,
        'the prop stays, its full rotation goes to the owner')
    eq(stubs.entityState(env, oh).mapCfg.rot.x, 15, 'mapCfg.rot follows')
    stubs.tick(2100)
    eq(entityOf(3), oh, 'kept: a prop is checked by position (its rotation rides mapCfg.rot)')

    -- an unchanged element shown again (its type redefined by its owner) keeps its entity
    eq(as('garage', 'defineType', { id = 'garage:car', kind = 'vehicle', fields = {
        { name = 'model', type = 'model', kinds = { 'vehicle' }, required = true } } }), true, 'a plugin vehicle type')
    local ok5, ap5 = Maps.apply(map.id, { { op = 'create', type = 'garage:car', pos = { x = 50, y = 10, z = 30 },
        fields = { model = 'sultan' } } }, 1)
    check(ok5, 'a plugin vehicle')
    local gid = ap5.ops[1].id
    local gh = entityOf(gid)
    reset()
    from = #stubs.sent
    eq(as('garage', 'defineType', { id = 'garage:car', label = 'Car', kind = 'vehicle', fields = {
        { name = 'model', type = 'model', kinds = { 'vehicle' }, required = true } } }), true, 'redefined')
    check(entityOf(gid) == gh and #H.natives == 0 and #H.poses(from + 1) == 0, 'a redefinition re-renders in place')

    -- still being created when it moves: the old entity goes once it appears, the element ends at the latest pose
    reset()
    stubs.spawnDelayMs = 200
    local ok6, ap6 = Maps.apply(map.id, { { op = 'create', type = 'core:vehicle', pos = { x = 60, y = 10, z = 30 },
        fields = { model = 'sultan' } } }, 1)
    check(ok6, 'a slow vehicle')
    local sid = ap6.ops[1].id
    check(update(sid, { pos = { x = 65, y = 11, z = 30 }, rot = { x = 0, y = 0, z = 180 } }), 'moved while being created')
    stubs.tick(1000)
    local sh = entityOf(sid)
    eq(alive(sid), 1, 'one entity for the element')
    check(sh and stubs.coords[sh].x == 65.0 and stubs.headings[sh] == 180.0, 'at the latest pose')
    -- queued behind another creation: nothing extra, it reads the latest element when its turn comes
    reset()
    local ok7, ap7 = Maps.apply(map.id, {
        { op = 'create', type = 'core:vehicle', pos = { x = 70, y = 10, z = 30 }, fields = { model = 'sultan' } },
        { op = 'create', type = 'core:vehicle', pos = { x = 80, y = 10, z = 30 }, fields = { model = 'sultan' } } }, 1)
    check(ok7, 'two slow vehicles')
    local qid = ap7.ops[2].id
    check(update(qid, { pos = { x = 85, y = 12, z = 30 } }), 'the queued one moves')
    stubs.tick(1000)
    local qh = entityOf(qid)
    check(#H.natives == 2 and qh and stubs.coords[qh].x == 85.0, 'created once, at the latest position')
    stubs.spawnDelayMs = 0

    -- a draft: the editor bucket and the published copy share the uid paint; publish moves in place
    local draft = Maps.create({ name = 'D', mode = 'draft', targetBucket = 6 }, 1)
    local eb = as('admin', 'openDraft', draft.id, 1)
    check(Maps.apply(draft.id, { { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 30 },
        fields = { model = 'sultan' } } }, 1), 'a vehicle in the draft')
    check(Maps.setActive(draft.id, true, 1) and Maps.publish(draft.id, 1) == 1, 'published')
    local function draftEntity(bucket)
        for handle, rec in pairs(stubs.entities) do
            if rec.exists and rec.bucket == bucket and stubs.entityState(env, handle).mapEl == draft.id .. ':1' then
                return handle, rec
            end
        end
    end
    local eh, erec = draftEntity(eb)
    local th, trec = draftEntity(6)
    check(eh and th and eh ~= th, 'one entity in the editor bucket, one in the target bucket')
    check(erec.colours[1] == trec.colours[1] and erec.colours[2] == trec.colours[2], 'the same paint in both')
    reset()
    from = #stubs.sent
    check(Maps.apply(draft.id, { { op = 'update', id = 1, set = { pos = { x = 3, y = 0, z = 30 } } } }, 1), 'edit the draft')
    eq(draftEntity(eb), eh, 'the editor copy moves in place')
    eq(draftEntity(6), th, 'the world copy is untouched')
    eq(Maps.publish(draft.id, 1), 2, 'publish the move')
    check(draftEntity(6) == th and #H.natives == 0 and #H.poses(from + 1) == 2, 'publishing moves the world copy in place')
end

--------------------------------------------------------------------------------
-- expect / conflict and invert (undo, redo)
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps = Core.Maps
    eq(as('catalogue', 'setModelValidator', callable(function() return true end)), true, 'a permissive validator')
    local map = Maps.create({ name = 'U', mode = 'live' }, 1)
    local ok, created = Maps.apply(map.id, { { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 },
        fields = { model = 'adder' } } }, 1)
    check(ok, 'a vehicle without a plate')
    local at = created.ops[1].after.updatedAt
    local err, detail
    ok, err, detail = Maps.apply(map.id, { { op = 'update', id = 1, set = { fields = { plate = 'X' } } } }, 2,
        { expect = { ['1'] = at - 1 } })
    check(ok == nil and err == 'conflict' and detail.id == '1' and detail.current == at, 'a stale expect is a conflict')
    ok, err = Maps.apply(map.id, { { op = 'update', id = 1, set = {} } }, 2, { expect = { [9] = 1 } })
    check(ok == nil and err == 'conflict', 'expecting a missing element is a conflict')
    local changed
    ok, changed = Maps.apply(map.id, { { op = 'update', id = 1, set = { fields = { plate = 'EVENT', locked = true },
        pos = { x = 3, y = 3, z = 3 } } } }, 2, { expect = { [1] = at } })
    check(ok, 'the right expect passes (integer keys too)')
    eq(changed.ops[1].before.fields.plate, nil, 'before has no plate')
    eq(changed.ops[1].after.fields.plate, 'EVENT', 'after has the plate (partial fields merge)')
    eq(changed.ops[1].after.fields.model, 'adder', 'the merge kept the model')
    eq(changed.ops[1].after.by, 'acc1', 'by stays the creator')

    local undo, expect = Maps.invert(changed)
    eq(#undo, 1, 'invert of one update is one update')
    check(undo[1].restore ~= nil and undo[1].restore.fields.plate == nil, 'which restores the earlier record')
    eq(expect['1'], changed.ops[1].after.updatedAt, 'expect = the after stamp')
    local undone
    ok, undone = Maps.apply(map.id, undo, 2, { expect = expect })
    check(ok, 'undo applies')
    local el = Maps.elements(map.id)[1]
    check(el.fields.plate == nil and el.fields.locked == false and el.pos.x == 0, 'undo restored fields and position')
    ok, err = Maps.apply(map.id, undo, 2, { expect = expect })
    check(ok == nil and err == 'conflict', 'undoing twice is a conflict')
    local redo, redoExpect = Maps.invert(undone)
    check(Maps.apply(map.id, redo, 2, { expect = redoExpect }), 'redo = invert of the undo')
    eq(Maps.elements(map.id)[1].fields.plate, 'EVENT', 'redo is back')

    local _, deleted = Maps.apply(map.id, { { op = 'delete', id = 1 } }, 1)
    local restore = Maps.invert(deleted)
    eq(restore[1].op, 'create', 'invert of a delete is a create')
    local _, restored = Maps.apply(map.id, restore, 1)
    eq(restored.ops[1].id, '1', 'with the same id')
    eq(Maps.elements(map.id)[1].fields.plate, 'EVENT', 'and the same fields')
    ok, err = Maps.apply(map.id, restore, 1)
    check(ok == nil and err == 'exists', 'restoring over a live id is refused')
    local _, created2 = Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    eq(created2.ops[1].id, '2', 'new ids continue after a restored one')
    local removeIt, e2 = Maps.invert(created2)
    check(removeIt[1].op == 'delete' and Maps.apply(map.id, removeIt, 1, { expect = e2 }), 'invert of a create deletes it')
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
    eq(#H.regionLog, 0, 'a closed, unpublished draft shows nothing')
    local bucket = as('admin', 'openDraft', map.id, 1)
    local lo = Core.Config.Buckets.Range[1]
    check(type(bucket) == 'number' and bucket >= lo, 'openDraft allocates a bucket from the range')
    eq(Core.Buckets.info(bucket).owner, 'core', 'owned by core even when a plugin opens it')
    check(H.population[bucket] == false and H.lockdown[bucket] == 'strict', 'population off, lockdown strict')
    eq(as('admin', 'openDraft', map.id, 2), bucket, 'a second editor gets the same bucket')
    eq(#calls('put', bucket), 2, 'the draft is live in its editor bucket')
    eq(Maps.get(map.id).editorBucket, bucket, 'get() reports the editor bucket')
    eq(select(2, Maps.update(map.id, { targetBucket = bucket })), 'targetBucket', 'an editor bucket cannot be a target')
    reset()
    check(Maps.setActive(map.id, true, 1), 'activate the unpublished draft')
    eq(#calls('put', 3), 0, 'nothing published, nothing shown')
    eq(Maps.publish(map.id, 1, 'first'), 1, 'publish -> version 1')
    eq(#calls('put', 3), 2, 'the snapshot is shown in the target bucket')
    eq(lastAudit('maps.publish').changes[1].new, 1, 'publish is audited')
    eq(Maps.get(map.id).dirty, false, 'not dirty after publishing')
    reset()
    check(Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 9, y = 9, z = 9 } } } }, 1), 'edit the draft')
    eq(#calls('put', bucket), 1, 'the editor bucket sees the edit')
    eq(#calls('put', 3), 0, 'the world does not')
    eq(Maps.get(map.id).dirty, true, 'dirty after an edit')
    reset()
    eq(Maps.publish(map.id, 1), 2, 'publish -> version 2')
    eq(#calls('put', 3), 1, 'only the changed element is re-put')
    eq(calls('put', 3)[1].tuple[4], 9.0, 'at its new position')
    reset()
    eq(Maps.rollback(map.id, 1, 1), 3, 'rollback publishes a copy as version 3')
    eq(#calls('put', 3), 1, 'the element goes back')
    eq(calls('put', 3)[1].tuple[4], 1.0, 'to its version-1 position')
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
    eq(#calls('clear', bucket), 1, 'the editor bucket is cleared in one call')
    eq(#calls('remove', bucket), 0, 'without per-element removes')
    eq(Core.Buckets.info(bucket), nil, 'the bucket is released')
    check(Maps.closeDraft(map.id) == false and #calls('remove', 3) == 0, 'closing twice is false; the published content stays')
    local b2 = as('admin', 'openDraft', map.id, 1)
    check(b2 ~= nil, 'open again')
    reset()
    stop(env, 'admin')
    eq(Maps.get(map.id).editorBucket, nil, 'the opener stopping closes the draft')
    eq(#calls('clear', b2), 1, 'and clears its bucket')
    for i = 1, 22 do Maps.publish(map.id, 1, 'v' .. i) end
    eq(#Maps.versions(map.id), 20, 'the newest 20 versions are kept')
    eq(stubs.kvp['doc:map_versions:' .. map.id .. ':v1'], nil, 'older snapshots are deleted')
end

--------------------------------------------------------------------------------
-- events (Maps.on / records), hooks, type.validate, parents, refs, migrate
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps = Core.Maps
    local got = {}
    local handle = as('garage', 'on', 'core:point', callable(function(event, record, mapId)
        got[#got + 1] = { event = event, record = record, mapId = mapId }
    end))
    check(type(handle) == 'string', 'Maps.on returns a handle')
    eq(as('garage', 'on', 'bad', callable(function() end)), nil, 'a bad type id is refused')
    local map = Maps.create({ name = 'E', mode = 'live' }, 1)
    Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 1, y = 2, z = 3 }, fields = { label = 'a' } },
        { op = 'create', type = 'core:zone', pos = { x = 0, y = 0, z = 0 } } }, 1)
    eq(#got, 1, 'only the listened type is delivered')
    local r = got[1].record
    check(got[1].event == 'added' and got[1].mapId == map.id and r.uid == map.id .. ':1' and r.bucket == 0
        and r.editor == false and r.key == '0|' .. map.id .. ':1' and r.fields.label == 'a', 'added: the record')
    Maps.apply(map.id, { { op = 'update', id = 1, set = { fields = { label = 'b' } } } }, 1)
    check(got[2].event == 'changed' and got[2].record.fields.label == 'b', 'changed')
    local records = Maps.records('core:point')
    check(#records == 1 and records[1].fields.label == 'b', 'records() lists active content of a type')
    eq(#Maps.records('*'), 2, "records('*') lists everything active")
    Maps.apply(map.id, { { op = 'delete', id = 1 } }, 1)
    check(got[3].event == 'removed' and got[3].record.fields.label == 'b', 'removed carries the last record')
    local draft = Maps.create({ name = 'D', mode = 'draft' }, 1)
    Maps.apply(draft.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    eq(#got, 3, 'a closed draft emits nothing')
    local bucket = Maps.openDraft(draft.id, 1)
    check(got[4].event == 'added' and got[4].record.editor == true and got[4].record.bucket == bucket,
        'an open draft emits for its editor bucket (editor = true)')
    Maps.closeDraft(draft.id)
    eq(got[5].event, 'removed', 'closing it removes')
    stop(env, 'garage')
    Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    eq(#got, 5, 'listeners go with their resource')

    local payload
    local hook = Core.Hooks.register('maps:beforeApply', function(p)
        payload = p
        if p.ops[1].model == 'prop_forbidden' then return false, 'blacklisted' end
    end)
    local ok, err, detail = Maps.apply(map.id, { { op = 'create', type = 'core:prop', pos = { x = 1, y = 1, z = 1 },
        fields = { model = 'prop_forbidden' } } }, 1, { source = 'editor' })
    check(ok == nil and err == 'hook' and detail.reason == 'blacklisted', 'maps:beforeApply vetoes')
    check(payload.mapId == map.id and payload.source == 'editor' and payload.actor == 'acc1' and payload.count == 1
        and payload.ops[1].pos.x == 1, 'the hook payload')
    check(Maps.apply(map.id, { { op = 'create', type = 'core:prop', pos = { x = 1, y = 1, z = 1 }, fields = { model = 'prop_ok' } } }, 1),
        'the hook lets others pass')
    Core.Hooks.remove(hook)

    local ctxSeen
    eq(as('race', 'defineType', { id = 'race:start', kind = 'point' }), true, 'race:start')
    eq(as('race', 'defineType', { id = 'race:cp', kind = 'point', parents = { 'race:start' },
        fields = { { name = 'next', type = 'ref', refType = 'race:cp' }, { name = 'n', type = 'integer', default = 0 } },
        validate = callable(function(record, ctx)
            ctxSeen = ctx
            if record.fields.n > 9 then return false, 'too many laps' end
            return true
        end) }), true, 'race:cp with parents, a ref field and validate')
    local race = Maps.create({ name = 'Race', mode = 'live' }, 1)
    local function cp(extra)
        local op = { op = 'create', type = 'race:cp', pos = { x = 0, y = 0, z = 0 }, fields = {} }
        for k, v in pairs(extra or {}) do op.fields[k] = v end
        return op
    end
    ok, err = Maps.apply(race.id, { cp() }, 1)
    check(ok == nil and err == 'parents', 'a checkpoint needs a start')
    ok = Maps.apply(race.id, { { op = 'create', type = 'race:start', pos = { x = 0, y = 0, z = 0 } }, cp() }, 1)
    check(ok, 'start and checkpoint in one apply')
    check(ctxSeen and ctxSeen.mapId == race.id and ctxSeen.op == 'create' and ctxSeen.actor == 1, 'validate gets { mapId, actor, op }')
    ok, err, detail = Maps.apply(race.id, { cp({ n = 10 }) }, 1)
    check(ok == nil and err == 'validate' and detail.reason == 'too many laps', 'type.validate refuses')
    ok, err = Maps.apply(race.id, { { op = 'delete', id = 1 } }, 1)
    check(ok == nil and err == 'parents', 'the last start cannot go while checkpoints need it')
    ok, err = Maps.apply(race.id, { cp({ next = '99' }) }, 1)
    check(ok == nil and err == 'ref', 'a ref to a missing element')
    ok, err = Maps.apply(race.id, { cp({ next = '1' }) }, 1)
    check(ok == nil and err == 'ref', 'a ref to the wrong type')
    check(Maps.apply(race.id, { cp({ next = '2' }) }, 1), 'a ref to a checkpoint')

    eq(as('race', 'defineType', { id = 'race:cp', kind = 'point', parents = { 'race:start' }, version = 2,
        fields = { { name = 'next', type = 'ref', refType = 'race:cp' }, { name = 'laps', type = 'integer', default = 0 } },
        migrate = callable(function(fields, from)
            fields.laps = (fields.n or 0) + from
            fields.n = nil
            return fields
        end) }), true, 'race:cp version 2 renames a field')
    local _, migratedApply = Maps.apply(race.id, { { op = 'update', id = 2, set = { fields = { next = '3' } } } }, 1)
    local after = migratedApply and migratedApply.ops[1].after
    check(after and after.typeVersion == 2 and after.fields.laps == 1 and after.fields.n == nil and after.fields.next == '3',
        'migrate runs when an old element changes')
end

--------------------------------------------------------------------------------
-- restores (placeholders, cams, old type versions), id caps, 'referenced', target buckets
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps = Core.Maps
    local sign = { id = 'deco:sign', kind = 'point', fields = { { name = 'text', type = 'string' } } }
    eq(as('deco', 'defineType', sign), true, 'a plugin type')
    local map = Maps.create({ name = 'R', mode = 'live' }, 1)
    Maps.apply(map.id, { { op = 'create', type = 'deco:sign', pos = { x = 1, y = 1, z = 1 }, fields = { text = 'hi' } } }, 1)
    local _, moved = Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 2, y = 2, z = 2 },
        cam = { x = 9, y = 9, z = 9 } } } }, 1)
    sign.version = 2
    as('deco', 'defineType', sign)
    local _, retext = Maps.apply(map.id, { { op = 'update', id = 1, set = { fields = { text = 'yo' } } } }, 1)
    eq(retext.ops[1].after.typeVersion, 2, 'a field change moves the element to the current type version')
    local undo, expect = Maps.invert(retext)
    check(Maps.apply(map.id, undo, 1, { expect = expect }), 'undo the field change')
    local el = Maps.elements(map.id)[1]
    check(el.typeVersion == 1 and el.fields.text == 'hi', 'the restore keeps the old type version')
    undo = Maps.invert(moved)                  -- its expect is stale now (the undo above re-stamped it)
    check(Maps.apply(map.id, undo, 1), 'undo the move')
    el = Maps.elements(map.id)[1]
    check(el.cam == nil and el.pos.x == 1, 'undo removes the cam the update added')
    stop(env, 'deco')
    local _, moved2 = Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 5, y = 5, z = 5 } } } }, 1)
    local u2, e2 = Maps.invert(moved2)
    check(Maps.apply(map.id, u2, 1, { expect = e2 }), 'undo of an update on a placeholder')
    local _, gone = Maps.apply(map.id, { { op = 'delete', id = 1 } }, 2)
    check(Maps.apply(map.id, (Maps.invert(gone)), 2), 'undo of a placeholder delete')
    el = Maps.elements(map.id)[1]
    check(el and el.type == 'deco:sign' and el.fields.text == 'hi' and el.by == 'acc1' and el.pos.x == 1,
        'the raw record is back, creator kept')

    local ids = Maps.create({ name = 'Ids', mode = 'live' }, 1)
    local function pt(id) return { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 }, id = id } end
    eq(select(2, Maps.apply(ids.id, { pt(999999999) }, 1)), 'id', 'an id that would exhaust the id space is refused')
    check(Maps.apply(ids.id, { pt(999999998) }, 1), 'the id below it is fine')
    local _, last = Maps.apply(ids.id, { pt() }, 1)
    eq(last and last.ops[1].id, '999999999', 'the last automatic id')
    eq(select(2, Maps.apply(ids.id, { pt() }, 1)), 'id', 'then automatic ids are exhausted')
    check(Maps.apply(ids.id, { { op = 'delete', id = '999999999' } }, 1) and Maps.clear(ids.id, 1),
        'every element stays manageable')

    eq(as('race', 'defineType', { id = 'race:cp', kind = 'point',
        fields = { { name = 'next', type = 'ref', refType = 'race:cp' } } }), true, 'a type with a ref field')
    local race = Maps.create({ name = 'Race', mode = 'live' }, 1)
    Maps.apply(race.id, { { op = 'create', type = 'race:cp', pos = { x = 0, y = 0, z = 0 } },
        { op = 'create', type = 'race:cp', pos = { x = 1, y = 0, z = 0 }, fields = { next = '1' } } }, 1)
    local okR, errR, detR = Maps.apply(race.id, { { op = 'delete', id = 1 } }, 1)
    check(okR == nil and errR == 'referenced' and detR.id == '1' and detR.by == '2', 'deleting a referenced element')
    check(Maps.apply(race.id, { { op = 'update', id = 2, replace = true, set = { fields = {} } }, { op = 'delete', id = 1 } }, 1),
        'unless the same apply drops the reference')

    eq(select(2, Maps.create({ name = 'x', mode = 'live', targetBucket = 10000 })), 'targetBucket',
        'a target inside Config.Buckets.Range is refused')
    eq(select(2, Maps.update(race.id, { targetBucket = 60000 })), 'targetBucket', 'on update too')
    check(Maps.update(race.id, { targetBucket = 60001 }), 'above the range is fine')
end


H.finish()
