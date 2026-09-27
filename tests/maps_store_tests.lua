--[[
    core/tests/maps_store_tests.lua — offline suite for Core.Maps (DESIGN §52.2), part 2.

        lua5.4 tests/maps_store_tests.lua    (from the resource directory, or from tests/)

    The journal (rows, update diffs, clear summaries, per-map and server-wide caps), clear, expiry,
    placeholders, networkedTotal, delete, rollback re-checks, the persistence round trip, the async load
    barrier, applying before the Scene store loaded, expect / conflict / invert (undo, redo), events
    (Maps.on / records), hooks, type.validate, parents, refs, migrate, restores, id caps, 'referenced', target
    buckets, apply validation and atomicity, limits (settings, per map, increase-only). Harness:
    tests/maps_harness.lua (a recording fake of Core.Scene). Exit 1 on failure.
]]

local here = (arg and arg[0] or 'tests/maps_store_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local H = dofile(here .. '/maps_harness.lua')
H.name = 'maps store'
local stubs, check, eq, callable, calls, reset, same = H.stubs, H.check, H.eq, H.callable, H.calls, H.reset, H.same
local newServer, as, stop, lastAudit, byUid, node = H.newServer, H.as, H.stop, H.lastAudit, H.byUid, H.node

--------------------------------------------------------------------------------
-- journal, clear, expiry, placeholders, networkedTotal, delete
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps = Core.Maps
    local map = Maps.create({ name = 'J', mode = 'live' }, 1)
    for i = 1, 3 do
        Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = i, y = 0, z = 0 } } }, i % 2 == 0 and 2 or 1,
            { source = 'editor' })
    end
    local rows = Maps.journal(map.id)
    check(#rows == 3 and rows[1].seq == 3 and rows[3].seq == 1, 'journal rows, newest first')
    check(rows[1].source == 'editor' and rows[1].count == 1 and rows[1].ops[1].op == 'create' and rows[1].actor.name == 'Player1',
        'a row: source, count, ops, actor')
    eq(#Maps.journal(map.id, { author = 'acc2' }), 1, 'filter by author (the by value)')
    local page = Maps.journal(map.id, { before = 3, limit = 1 })
    check(#page == 1 and page[1].seq == 2, 'cursor + limit')
    Core.Settings.set('maps.journalMax', 100)
    for i = 1, 100 do
        Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = i, y = 0, z = 0 } } } }, 1)
    end
    eq(#Maps.journal(map.id, { limit = 200 }), 100, 'pruned to maps.journalMax')
    eq(stubs.kvp['doc:map_journal:' .. map.id .. ':j1'], nil, 'the oldest rows are deleted')
    check(stubs.kvp['doc:map_journal:' .. map.id .. ':j103'] ~= nil, 'the newest are kept')

    reset()
    local ok, applied = Maps.clear(map.id, 1)
    check(ok and #applied.ops == 3, 'clear deletes every element in one apply')
    eq(#calls('remove', 0), 3, 'and removes each node')
    eq(#Maps.elements(map.id), 0, 'the map is empty')
    eq(lastAudit('maps.clear').ctx.elements, 3, 'clear is audited')
    eq(Maps.journal(map.id, { limit = 1 })[1].count, 3, 'and journaled as one row')
    check(Maps.apply(map.id, (Maps.invert(applied)), 1), 'an undone clear restores everything')
    eq(#Maps.elements(map.id), 3, 'three elements again')
    local okEmpty = Maps.clear(Maps.create({ name = 'empty', mode = 'live' }, 1).id, 1)
    eq(okEmpty, true, 'clearing an empty map is fine')

    stubs.osTime = 1000000
    local ev = Maps.create({ name = 'Event', mode = 'live', expiresAt = 1000060 }, 1)
    Maps.apply(ev.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    check(#H.cronJobs == 1 and H.cronJobs[1].ms == 10000, 'one Cron job checks expiry every 10 s')
    reset()
    H.cronJobs[1].fn()
    eq(Maps.get(ev.id).active, true, 'not expired yet')
    stubs.osTime = 1000061
    H.cronJobs[1].fn()
    local exp = Maps.get(ev.id)
    check(exp.active == false and exp.expiresAt == nil, 'expired: deactivated, expiry cleared, not deleted')
    eq(#calls('remove', 0), 1, 'its content left the world')
    eq(lastAudit('maps.setActive').ctx.reason, 'expired', 'audited as an expiry')
    check(Maps.setActive(ev.id, true, 1), 'it can be switched on again')
    eq(select(2, Maps.update(ev.id, { expiresAt = 1000000 })), 'expiresAt', 'an expiry in the past is refused')
    eq(Maps.update(ev.id, { expiresAt = 1000500 }).expiresAt, 1000500, 'update sets an expiry')
    eq(Maps.update(ev.id, { expiresAt = false }).expiresAt, nil, 'expiresAt = false clears it')
    stubs.osTime = nil

    eq(as('deco', 'defineType', { id = 'deco:lamp', kind = 'prop', model = 'prop_lamp' }), true, 'a fixed-model prop type')
    local deco = Maps.create({ name = 'Deco', mode = 'live' }, 1)
    Maps.apply(deco.id, { { op = 'create', type = 'deco:lamp', pos = { x = 0, y = 0, z = 0 } } }, 1)
    reset()
    stop(env, 'deco')
    local ph = calls('spawn', 0)[1]
    check(ph and ph.uid == deco.id .. ':1' and ph.def.kind == 'map:data' and ph.def.fields.k == 'placeholder'
        and ph.def.fields.t == 'deco:lamp' and same(ph.def.audience, { editors = true }) and #calls('remove', 0) == 1,
        'a record of an undefined type becomes an editor-only placeholder node (t = its type)')
    eq(#Maps.elements(deco.id), 1, 'the record is kept')
    check(Maps.apply(deco.id, { { op = 'update', id = 1, set = { pos = { x = 1, y = 1, z = 1 } } } }, 1),
        'a placeholder can still be moved')
    eq(select(2, Maps.apply(deco.id, { { op = 'update', id = 1, set = { fields = {} } } }, 1)), 'type',
        'but its fields cannot change')
    reset()
    as('deco', 'defineType', { id = 'deco:lamp', kind = 'prop', model = 'prop_lamp' })
    check(calls('spawn', 0)[1].def.kind == 'prop', 'the type returns: a prop node again')

    as('catalogue', 'setModelValidator', callable(function() return true end))
    Core.Settings.set('maps.limits.networkedTotal', 1)
    local n1 = Maps.create({ name = 'N1', mode = 'live' }, 1)
    local n2 = Maps.create({ name = 'N2', mode = 'live' }, 1)
    local veh = { op = 'create', type = 'core:vehicle', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'adder' } }
    check(Maps.apply(n1.id, { veh }, 1), 'one networked element server-wide')
    local okN, errN, detN = Maps.apply(n2.id, { veh }, 1)
    check(okN == nil and errN == 'limit' and detN.limit == 'networkedTotal', 'the second exceeds networkedTotal')
    Maps.setActive(n2.id, false, 1)
    check(Maps.apply(n2.id, { veh }, 1), 'an inactive map may hold it')
    local okA, errA = Maps.setActive(n2.id, true, 1)
    check(okA == false and errA == 'limit', 'but cannot be activated over the limit')
    Core.Settings.reset('maps.limits.networkedTotal')

    reset()
    local dropped = Maps.create({ name = 'Drop', mode = 'draft' }, 1)
    Maps.apply(dropped.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    Maps.setActive(dropped.id, true, 1)
    Maps.publish(dropped.id, 1)
    local eb = Maps.openDraft(dropped.id, 1)
    reset()
    eq(Maps.delete(dropped.id, 1), true, 'delete a map')
    eq(#calls('remove', 0), 1, 'its published content leaves the world')
    eq(#calls('remove', eb), 1, 'its editor bucket is emptied')
    eq(Maps.get(dropped.id), nil, 'it is gone')
    local left = 0
    for key in pairs(stubs.kvp) do
        if key:find(dropped.id .. ':', 1, true) or key == 'doc:maps:' .. dropped.id then left = left + 1 end
    end
    eq(left, 0, 'with its elements, versions and journal')
    eq(lastAudit('maps.delete').targets[1].id, dropped.id, 'delete is audited')
end

--------------------------------------------------------------------------------
-- persistence round trip, the async load barrier, before the Scene store loaded
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps = Core.Maps
    local live = Maps.create({ name = 'Live', mode = 'live' }, 1)
    Maps.apply(live.id, { { op = 'create', type = 'core:prop', pos = { x = 1, y = 0, z = 0 }, fields = { model = 'prop_a' } },
        { op = 'create', type = 'core:point', pos = { x = 2, y = 0, z = 0 } } }, 1)
    local draft = Maps.create({ name = 'Draft', mode = 'draft', targetBucket = 4 }, 1)
    Maps.apply(draft.id, { { op = 'create', type = 'core:point', pos = { x = 5, y = 0, z = 0 } },
        { op = 'create', type = 'core:point', pos = { x = 7, y = 0, z = 0 } } }, 1)
    Maps.setActive(draft.id, true, 1)
    Maps.publish(draft.id, 1)
    Maps.apply(draft.id, { { op = 'update', id = 1, set = { pos = { x = 6, y = 0, z = 0 } } } }, 1)
    local stampBefore = Maps.elements(draft.id)[1].updatedAt
    local liveStamp = Maps.elements(live.id)[1].updatedAt
    local liveId, draftId = live.id, draft.id

    _, Core = newServer({ keepKvp = true })
    Maps = Core.Maps
    eq(#Maps.list(), 2, 'both maps are loaded after a restart')
    eq(#calls('spawn', 0), 2, 'the active live map is shown again')
    local shown = calls('spawn', 4)
    check(#shown == 2 and byUid(shown, draftId .. ':1').def.pos.x == 5.0, 'the draft shows its published snapshot, not the edit')
    eq(Maps.elements(draftId)[1].pos.x, 6.0, 'the draft keeps its edit')
    eq(Maps.get(draftId).dirty, true, 'and is still dirty')
    eq(#Maps.journal(draftId), 2, 'the journal index is rebuilt')
    eq(#Maps.versions(draftId), 1, 'the version index is rebuilt')
    local _, again = Maps.apply(liveId, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    eq(again.ops[1].id, '3', 'element ids continue')
    check(again.ops[1].after.updatedAt > stampBefore, 'stamps keep increasing across a restart')
    eq(Maps.elements(liveId)[1].updatedAt, liveStamp, 'the element stamp survives the restart exactly')
    eq(Maps.get(liveId).journalSeq, 2, 'the journal sequence continues')
    reset()
    eq(Maps.publish(draftId, 1), 2, 'publish after a restart')
    eq(H.trace(), 'move:' .. draftId .. ':1', 'only the edited element is moved (stamps survived the restart)')

    local mapLoads = 0
    local function asyncAdapter(env)
        return {
            loadAll = function(collection)
                if collection == 'maps' then mapLoads = mapLoads + 1 end
                local p = env.promise.new()
                env.SetTimeout(50, function() p:resolve(true) end)
                env.Citizen.Await(p)
                local out = {}
                local prefix = 'doc:' .. collection .. ':'
                for key, value in pairs(stubs.kvp) do
                    if key:sub(1, #prefix) == prefix then out[key:sub(#prefix + 1)] = value end
                end
                return out
            end,
            put = function(collection, id, encoded) stubs.kvp['doc:' .. collection .. ':' .. id] = encoded end,
            remove = function(collection, id) stubs.kvp['doc:' .. collection .. ':' .. id] = nil end,
            flush = function() end,
        }
    end
    local env
    env, Core = newServer({ keepKvp = true, adapter = asyncAdapter })
    Maps = Core.Maps
    local got = {}
    env.CreateThread(function() got[1] = Maps.get(liveId) end)
    env.CreateThread(function() got[2] = Maps.list() end)
    eq(got[1], nil, 'callers park while the collections load')
    stubs.tick(1000)
    check(got[1] and got[1].id == liveId and #got[2] == 2, 'every parked caller gets the loaded maps')
    eq(mapLoads, 1, 'the maps collection was loaded exactly once')
    eq(#calls('spawn', 0), 3, 'and activated once')

    stubs.clear()
    _, Core = newServer({ sceneLoaded = false })
    local m = Core.Maps.create({ name = 'NoScene', mode = 'live' }, 1)
    check(Core.Maps.apply(m.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1),
        'applies work before the Scene store loaded')
    eq(#calls('spawn'), 0, 'nothing is projected yet')
    H.sceneLoaded = true
    stubs.tick(200)
    eq(#calls('spawn'), 1, 'the content appears once it loaded')
end

--------------------------------------------------------------------------------
-- journal size: update diffs, clear summaries, per-map ops cap, server-wide cap
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    local map = Maps.create({ name = 'J2', mode = 'live' }, 1)
    Maps.apply(map.id, { { op = 'create', type = 'core:marker', pos = { x = 0, y = 0, z = 0 } } }, 1)
    local _, applied = Maps.apply(map.id, { { op = 'update', id = 1, set = { pos = { x = 1, y = 0, z = 0 },
        fields = { bob = true } } } }, 1)
    check(applied.ops[1].before.fields.markerType == 1 and applied.ops[1].after.type == 'core:marker',
        'apply still returns the full records')
    local row = Maps.journal(map.id, { limit = 1 })[1]
    local b, a = row.ops[1].before, row.ops[1].after
    check(b.pos.x == 0 and a.pos.x == 1 and b.rot == nil and a.type == nil and a.updatedAt ~= nil, 'an update row keeps the changed keys')
    check(b.fields.bob == false and a.fields.bob == true and b.fields.markerType == nil, 'and only the changed fields')
    Maps.clear(map.id, 1)
    row = Maps.journal(map.id, { limit = 1 })[1]
    check(row.clear == true and row.count == 1 and row.ids[1] == '1' and row.ops == nil, 'a clear row is a summary')

    local get = Core.Settings.get
    Core.Settings.get = function(key)
        if key == 'maps.journalMaxOps' then return 3 end
        return get(key)
    end
    local ops = {}
    for i = 1, 5 do
        Maps.apply(map.id, { { op = 'create', type = 'core:point', pos = { x = i, y = 0, z = 0 } } }, 1)
    end
    eq(#Maps.journal(map.id), 3, 'pruned to maps.journalMaxOps stored ops')
    for i = 1, 5 do ops[i] = { op = 'create', type = 'core:point', pos = { x = i, y = 1, z = 0 } } end
    Maps.apply(map.id, ops, 1)
    local rows = Maps.journal(map.id)
    check(#rows == 1 and rows[1].count == 5, 'a row heavier than the cap is kept alone (the newest stays)')
    Core.Settings.get = get

    R.journalOpsTotal = 10
    local other = Maps.create({ name = 'J3', mode = 'live' }, 1)
    for i = 1, 8 do Maps.apply(other.id, { { op = 'create', type = 'core:point', pos = { x = i, y = 2, z = 0 } } }, 1) end
    check(R.state.journalTotal <= 10, 'the server-wide journal stays within R.journalOpsTotal')
    check(#Maps.journal(map.id) == 1 and #Maps.journal(other.id) == 5, 'the fullest map loses its oldest rows first')
end

--------------------------------------------------------------------------------
-- rollback re-checks the snapshot: today's model validator and limits
--------------------------------------------------------------------------------
do
    local _, Core = newServer()
    local Maps = Core.Maps
    local banned = {}
    as('catalogue', 'setModelValidator', callable(function(_, model) return not banned[model] end))
    local map = Maps.create({ name = 'RB', mode = 'draft' }, 1)
    Maps.apply(map.id, { { op = 'create', type = 'core:prop', pos = { x = 0, y = 0, z = 0 }, fields = { model = 'prop_ok' } },
        { op = 'create', type = 'core:prop', pos = { x = 1, y = 0, z = 0 }, fields = { model = 'prop_bad' } } }, 1)
    eq(Maps.publish(map.id, 1), 1, 'v1 with both')
    Maps.apply(map.id, { { op = 'delete', id = 2 } }, 1)
    eq(Maps.publish(map.id, 1), 2, 'v2 without the second')
    banned.prop_bad = true
    Core.MapsRuntime.setModelValidator(callable(function(_, model) return not banned[model] end))
    local ok, err, detail = Maps.rollback(map.id, 1, 1)
    check(ok == nil and err == 'model' and detail.ids[1] == '2' and #detail.ids == 1, 'a model refused today blocks the rollback')
    banned.prop_bad = nil
    Core.MapsRuntime.setModelValidator(callable(function() return true end))
    Maps.update(map.id, { limits = { elements = 1 } }, 1)
    ok, err, detail = Maps.rollback(map.id, 1, 1)
    check(ok == nil and err == 'limit' and detail.limit == 'elements', 'so do the limits')
    Maps.update(map.id, { limits = false }, 1)
    eq(Maps.rollback(map.id, 1, 1), 3, 'then it goes through')
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
            and after.journalSeq == before.journalSeq and #H.log == 0, label .. ': nothing changed')
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
    eq(H.trace(), 'spawn:' .. map.id .. ':1', 'the world got the final state once')
    eq(node(map.id .. ':1').pos.x, 1.0, 'the updated position')
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


H.finish()
