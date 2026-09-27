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
    eq(H.row('SELECT seq FROM map_journal WHERE map_id = $1 AND seq = 1', { map.id }), nil, 'the oldest rows are deleted')
    check(H.row('SELECT seq FROM map_journal WHERE map_id = $1 AND seq = 103', { map.id }) ~= nil, 'the newest are kept')
    eq(H.row('SELECT count(*)::int AS n FROM map_journal WHERE map_id = $1', { map.id }).n, 100,
        'the table holds exactly maps.journalMax rows of the map')

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
    local left = H.row('SELECT (SELECT count(*) FROM maps WHERE id = $1) + (SELECT count(*) FROM map_elements '
        .. 'WHERE map_id = $1) + (SELECT count(*) FROM map_versions WHERE map_id = $1) + (SELECT count(*) FROM '
        .. 'map_journal WHERE map_id = $1) AS n', { dropped.id })
    eq(left and left.n, 0, 'with its elements, versions and journal (the foreign keys cascade)')
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

    _, Core = newServer({ keepDb = true })
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

    -- the element load streams one batch per server tick: callers arriving meanwhile park on the barrier
    local env
    env, Core = newServer({ keepDb = true, loadBatch = 1 })
    Maps = Core.Maps
    local got = {}
    env.CreateThread(function() got[1] = Maps.get(liveId) end)
    env.CreateThread(function() got[2] = Maps.list() end)
    eq(got[1], nil, 'callers park while the tables load')
    stubs.tick(1000)
    check(got[1] and got[1].id == liveId and #got[2] == 2, 'every parked caller gets the loaded maps')
    eq(#H.statements('^crud select maps'), 1, 'the maps table was read exactly once')
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
    H.cronJobs[1].fn()                          -- the 10 s job re-reads the settings (applies never read them)
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
    H.cronJobs[1].fn()

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


--------------------------------------------------------------------------------
-- the database (DESIGN §56): rows and their columns, start-up reads metadata only, one transaction per commit,
-- pruning by rows and by weight, rollback reads the snapshot, delete cascades, failed reads never look empty
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    as('catalogue', 'setModelValidator', callable(function() return true end))
    local expires = os.time() + 3600
    local draft = Maps.create({ name = 'Rows', mode = 'draft', targetBucket = 7, meta = { description = 'd' },
        limits = { elements = 50 }, expiresAt = expires }, 1)
    check(draft and draft.id:find('^m%d+$'), 'a map id m<n> from the maps counter')
    local mrow = H.row('SELECT * FROM maps WHERE id = $1', { draft.id })
    check(mrow and mrow.mode == 'draft' and mrow.active == false and mrow.target_bucket == 7 and mrow.meta.description == 'd'
        and mrow.limits.elements == 50 and mrow.expires_at == expires and mrow.created_by.accountId == 'acc1',
        'create: the map row exists when create returns (columns mapped)')
    Maps.apply(draft.id, { { op = 'create', type = 'core:vehicle', pos = { x = 1.5, y = 2, z = 3 }, fields = { model = 'adder' } },
        { op = 'create', type = 'core:point', pos = { x = 4, y = 0, z = 0 }, cam = { x = 1, y = 2, z = 3 } } }, 1)
    local els = Maps.elements(draft.id)
    local erows = H.sql('SELECT element_id, type, author, rev, pos, fields, cam, layer FROM map_elements WHERE map_id = $1 '
        .. 'ORDER BY element_id', { draft.id })
    check(#erows == 2 and erows[1].author == 'acc1' and erows[1].rev == els[1].updatedAt and erows[1].pos.x == 1.5
        and erows[1].fields.model == 'adder' and erows[1].cam == nil and erows[2].cam.z == 3 and erows[2].layer == 'default',
        'element rows: author = by, rev = the ms stamp, pos / fields / cam jsonb')
    eq(Maps.publish(draft.id, 1, 'first'), 1, 'publish v1')
    local vrow = H.row('SELECT version, count, author, author_name, note, from_version, elements FROM map_versions '
        .. 'WHERE map_id = $1', { draft.id })
    check(vrow and vrow.count == 2 and vrow.author == 'acc1' and vrow.author_name == 'Player1' and vrow.note == 'first'
        and vrow.from_version == nil and #vrow.elements == 2 and vrow.elements[1].by == 'acc1'
        and vrow.elements[1].updatedAt == els[1].updatedAt, 'the version row: metadata columns and the snapshot')
    local jrows = H.sql('SELECT seq, author, source, actor, count, w, clear, ops, ids FROM map_journal WHERE map_id = $1',
        { draft.id })
    check(#jrows == 1 and jrows[1].author == 'acc1' and jrows[1].source == 'api' and jrows[1].actor.name == 'Player1'
        and jrows[1].count == 2 and jrows[1].w == 2 and jrows[1].clear == false and #jrows[1].ops == 2 and jrows[1].ids == nil,
        'the journal row: author = by, weight, ops')
    Maps.apply(draft.id, { { op = 'update', id = 1, set = { pos = { x = 9, y = 9, z = 9 } } } }, 1)
    eq(Maps.publish(draft.id, 1), 2, 'publish v2 (the vehicle moved)')

    -- a restart reads metadata only: never the journal's ops / ids, never every snapshot
    H.fail('[%s,]ops[%s,].*FROM map_journal', '42501 the start-up must not read journal payloads')
    H.fail('[%s,]ids[%s,].*FROM map_journal', '42501 the start-up must not read journal payloads')
    H.fail('SELECT %* FROM "map_', '42501 no whole-row reads of map tables')
    env, Core = newServer({ keepDb = true })
    Maps, R = Core.Maps, Core.MapsRuntime
    H.unfail()
    local js, vs = H.statements('map_journal'), H.statements('map_versions')
    check(Maps.get(draft.id) and #Maps.versions(draft.id) == 2 and #Maps.journal(draft.id) == 2,
        'the restart loaded (the payload reads above would have failed it)')
    as('catalogue', 'setModelValidator', callable(function() return true end))
    check(#js == 1 and js[1]:find('SELECT map_id, seq, w FROM map_journal', 1, true) ~= nil, 'the journal load: (map_id, seq, w)')
    check(#vs == 2 and vs[1]:find('from_version FROM map_versions ORDER', 1, true) ~= nil and not vs[1]:find('elements'),
        'the version index: metadata columns only')
    check(vs[2]:find('v.elements FROM map_versions v JOIN maps m', 1, true) ~= nil and vs[2]:find('m.published_version', 1, true)
        ~= nil, 'snapshots: only the published one of each draft')
    check(#H.statements('FROM map_elements') == 1 and H.statements('FROM map_elements')[1]:find('^DECLARE') ~= nil,
        'elements: one streamed cursor')
    check(#H.statements('^crud select maps') == 1, 'maps: one select')

    -- rollback reads its snapshot (one query) and republishes exactly it
    Maps.setActive(draft.id, true, 1)
    local mark = #H.sqlLog
    reset()
    eq(Maps.rollback(draft.id, 1, 1), 3, 'rollback to v1 -> v3')
    eq(#H.statements('^SELECT elements FROM map_versions WHERE map_id = %$1 AND version = %$2', mark + 1), 1,
        'rollback read the snapshot with one query')
    local v3 = H.row('SELECT elements, from_version FROM map_versions WHERE map_id = $1 AND version = 3', { draft.id })
    check(v3 and v3.from_version == 1 and #v3.elements == 2 and v3.elements[1].pos.x == 1.5, 'v3 = the v1 snapshot, from 1')
    check(node(draft.id .. ':1', 7) and node(draft.id .. ':1', 7).pos.x == 1.5, 'and the world shows it')
    local list = Maps.versions(draft.id)
    check(list[1].version == 3 and list[1].from == 1 and list[1].by == 'acc1' and list[1].byName == 'Player1'
        and list[1].current == true, 'versions: by, byName, from (the camelCase shape)')
    H.fail('^SELECT elements FROM map_versions', 'XX000 simulated failure')
    local okRb, errRb = Maps.rollback(draft.id, 2, 1)
    check(okRb == nil and errRb == 'db', 'a failed snapshot read is db, never version')
    eq(select(2, Maps.rollback(draft.id, 99, 1)), 'version', 'an unknown version needs no query')
    H.fail('FROM map_journal WHERE map_id', 'XX000 simulated failure')
    local rowsJ, errJ = Maps.journal(draft.id)
    check(rowsJ == nil and errJ ~= nil, 'a failed journal read answers nil, err (never an empty page)')
    H.unfail()

    -- one commit = one transaction: a lost connection on the journal insert leaves every row as it was
    local live = Maps.create({ name = 'Tx', mode = 'live' }, 1)
    Maps.apply(live.id, { { op = 'create', type = 'core:point', pos = { x = 1, y = 0, z = 0 } } }, 1)
    H.release()
    H.fail('INSERT INTO "map_journal"', '08006 simulated connection loss')
    check(Maps.apply(live.id, { { op = 'update', id = 1, set = { pos = { x = 5, y = 0, z = 0 } } },
        { op = 'create', type = 'core:point', pos = { x = 2, y = 0, z = 0 } } }, 1), 'the apply commits in memory')
    H.release()                                  -- the flush of that slice runs (and fails)
    local okU, errU = Maps.apply(live.id, { { op = 'create', type = 'core:point', pos = { x = 3, y = 0, z = 0 } } }, 1)
    check(okU == nil and errU == 'db', 'while core_db reports the database unhealthy, applies answer db')
    local tx = H.row('SELECT (SELECT pos FROM map_elements WHERE map_id = $1 AND element_id = 1) AS pos, '
        .. '(SELECT count(*)::int FROM map_elements WHERE map_id = $1) AS els, (SELECT count(*)::int FROM map_journal '
        .. 'WHERE map_id = $1) AS js, (SELECT journal_seq FROM maps WHERE id = $1) AS seq', { live.id })
    check(tx and tx.pos.x == 1 and tx.els == 1 and tx.js == 1 and tx.seq == 1,
        'nothing of the failed commit landed: element, new element, journal row and map row all unchanged')
    H.unfail()
    eq(H.sync(), true, 'the queue retries the whole transaction')
    tx = H.row('SELECT (SELECT pos FROM map_elements WHERE map_id = $1 AND element_id = 1) AS pos, '
        .. '(SELECT count(*)::int FROM map_elements WHERE map_id = $1) AS els, (SELECT count(*)::int FROM map_journal '
        .. 'WHERE map_id = $1) AS js, (SELECT journal_seq FROM maps WHERE id = $1) AS seq', { live.id })
    check(tx and tx.pos.x == 5 and tx.els == 2 and tx.js == 2 and tx.seq == 2, 'then all of it landed together')
    check(Maps.apply(live.id, { { op = 'create', type = 'core:point', pos = { x = 3, y = 0, z = 0 } } }, 1),
        'applies work again')

    -- pruning: rows of the table follow the index (by rows, by weight, server-wide)
    local get = Core.Settings.get
    Core.Settings.get = function(key)
        if key == 'maps.journalMax' then return 4 end
        if key == 'maps.journalMaxOps' then return 6 end
        return get(key)
    end
    H.cronJobs[1].fn()
    for i = 1, 6 do Maps.apply(live.id, { { op = 'update', id = 1, set = { pos = { x = i, y = 1, z = 0 } } } }, 1) end
    local seqs = H.sql('SELECT seq FROM map_journal WHERE map_id = $1 ORDER BY seq', { live.id })
    check(#seqs == 4 and seqs[1].seq == 6 and seqs[4].seq == 9, 'by rows: the newest journalMax rows are left in the table')
    local three = {}
    for i = 1, 3 do three[i] = { op = 'create', type = 'core:point', pos = { x = i, y = 5, z = 0 } } end
    Maps.apply(live.id, three, 1)
    Maps.apply(live.id, three, 1)
    seqs = H.sql('SELECT seq, w FROM map_journal WHERE map_id = $1 ORDER BY seq', { live.id })
    check(#seqs == 2 and seqs[1].w == 3 and seqs[2].w == 3 and seqs[2].seq == 11, 'by weight: 6 ops = the last two rows')
    Core.Settings.get = get
    H.cronJobs[1].fn()
    R.journalOpsTotal = 5
    Maps.apply(live.id, { { op = 'update', id = 1, set = { pos = { x = 0, y = 0, z = 0 } } } }, 1)
    local sum = H.row('SELECT COALESCE(sum(w), 0)::int AS w FROM map_journal')
    check(sum and sum.w == R.state.journalTotal and sum.w <= 5, 'server-wide: the table weight equals the index total')
    R.journalOpsTotal = 200000

    -- delete: one queued statement, the foreign keys cascade
    mark = #H.sqlLog
    eq(Maps.delete(draft.id, 1), true, 'delete the draft')
    eq(#H.statements('^DELETE FROM maps WHERE id = %$1', mark + 1), 1, 'one DELETE statement')
    eq(#H.statements('^remove ', mark + 1), 0, 'no row-by-row removes')
    local gone = H.row('SELECT (SELECT count(*)::int FROM map_elements WHERE map_id = $1) + (SELECT count(*)::int FROM '
        .. 'map_versions WHERE map_id = $1) + (SELECT count(*)::int FROM map_journal WHERE map_id = $1) AS n', { draft.id })
    eq(gone and gone.n, 0, 'elements, versions and journal cascaded')

    -- a failed create changes nothing; a failed load is never "no maps"
    H.fail('INSERT INTO "maps"', 'XX000 simulated failure')
    local okC, errC = Maps.create({ name = 'Nope', mode = 'live' }, 1)
    check(okC == nil and errC == 'db' and #Maps.list({ text = 'Nope' }) == 0, 'a failed insert: db, no map in memory')
    H.unfail()
    stubs.osTime = 5000000
    H.fail('SELECT %* FROM "maps"', '08006 simulated connection loss')
    env, Core = newServer({ keepDb = true })
    Maps = Core.Maps
    H.unfail()
    check(#Maps.list() == 0 and Maps.get(live.id) == nil, 'a failed load: nothing is shown')
    eq(select(2, Maps.create({ name = 'X', mode = 'live' }, 1)), 'unavailable', 'and nothing is written (unavailable)')
    local got
    env.CreateThread(function() got = Maps.list() end)
    eq(got and #got, 0, 'the load is retried at most every 10 s')
    stubs.osTime = 5000011
    env.CreateThread(function() got = Maps.list() end)
    check(got and #got == 1 and got[1].id == live.id, 'then it loads (the rows were never touched)')
    stubs.osTime = nil
end

--------------------------------------------------------------------------------
-- review R3a: nothing yields between a stale staging and its writes (item 3); the keyed journal prune (item 8)
--------------------------------------------------------------------------------
do
    local env, Core = newServer()
    local Maps, R = Core.Maps, Core.MapsRuntime
    local slow = {}                             -- models whose validation waits 100 ms (a validator's own DB read)
    as('catalogue', 'setModelValidator', callable(function(_, model)
        if slow[model] then env.Wait(100) end
        return true
    end))
    local function veh(model, x) return { op = 'create', type = 'core:vehicle', pos = { x = x or 0, y = 0, z = 0 },
        fields = { model = model } } end
    local function count(sql, id) return H.row(sql, { id }).n end
    local ROWS = 'SELECT (SELECT count(*) FROM maps WHERE id = $1) + (SELECT count(*) FROM map_elements WHERE map_id = $1)'
        .. ' + (SELECT count(*) FROM map_versions WHERE map_id = $1) + (SELECT count(*) FROM map_journal WHERE map_id = $1)'
        .. ' AS n'

    -- the map row is persisted as a PATCH: a write after the delete does not bring the row back
    local gone = Maps.create({ name = 'Gone', mode = 'live' }, 1)
    local stale = R.state.maps[gone.id]
    local mark = #H.sqlLog
    Maps.delete(gone.id, 1)
    R.persistMap(stale)
    check(#H.statements('^patch maps', mark + 1) == 1 and #H.statements('^save maps', mark + 1) == 0,
        'the map row is written with patch, never save')
    eq(count(ROWS, gone.id), 0, 'a persist after the delete leaves the map deleted')

    -- a validator yields, the map is deleted meanwhile: the apply answers not_found and writes nothing
    local m = Maps.create({ name = 'Race', mode = 'live' }, 1)
    slow.slow_a = true
    local res
    env.CreateThread(function() res = table.pack(Maps.apply(m.id, { veh('slow_a') }, 1)) end)
    eq(res, nil, 'the apply waits in the model validator')
    eq(Maps.delete(m.id, 1), true, 'the map is deleted meanwhile')
    stubs.tick(200)
    check(res and res[1] == nil and res[2] == 'not_found', 'the apply resumes: not_found')
    eq(count(ROWS, m.id), 0, 'and nothing of it reached the database (no map row came back)')

    -- two applies on one map: the one that waited re-stages on the other's result (no id is used twice)
    local twin = Maps.create({ name = 'Twin', mode = 'live' }, 1)
    Maps.apply(twin.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
    slow.slow_b = true
    local resA
    env.CreateThread(function() resA = table.pack(Maps.apply(twin.id, { veh('slow_b', 3) }, 1)) end)
    local okB, appliedB = Maps.apply(twin.id, { { op = 'create', type = 'core:point', pos = { x = 5, y = 0, z = 0 } } }, 1)
    check(okB and appliedB.ops[1].id == '2', 'the other apply commits element 2 while the first waits')
    stubs.tick(200)
    check(resA and resA[1] == true and resA[2].ops[1].id == '3', 'the waiting apply re-staged: element 3, not a second 2')
    local rows = H.sql('SELECT element_id, type FROM map_elements WHERE map_id = $1 ORDER BY element_id', { twin.id })
    check(#rows == 3 and rows[2].type == 'core:point' and rows[3].type == 'core:vehicle', 'both elements are in the table')
    eq(Maps.get(twin.id).journalSeq, 3, 'three journal rows')

    -- its expect is checked again on the new state
    local at3 = Maps.elements(twin.id)[3].updatedAt
    slow.slow_c = true
    local resC
    env.CreateThread(function()
        resC = table.pack(Maps.apply(twin.id, { { op = 'update', id = 3, set = { fields = { model = 'slow_c' } } } }, 1,
            { expect = { [3] = at3 } }))
    end)
    check(Maps.apply(twin.id, { { op = 'update', id = 3, set = { pos = { x = 9, y = 9, z = 9 } } } }, 2),
        'someone moves element 3 meanwhile')
    stubs.tick(200)
    check(resC and resC[1] == nil and resC[2] == 'conflict' and resC[3].id == '3', 'the waiting update: conflict (expect)')
    local el3 = Maps.elements(twin.id)[3]
    check(el3.fields.model == 'slow_b' and el3.pos.x == 9, 'element 3 keeps the move and its model')

    -- a rollback whose validator yields while the draft is deleted
    local d = Maps.create({ name = 'RbRace', mode = 'draft' }, 1)
    Maps.apply(d.id, { veh('adder') }, 1)
    eq(Maps.publish(d.id, 1), 1, 'v1')
    slow.adder = true
    as('catalogue', 'setModelValidator', callable(function(_, model)   -- a new validator: its cache is empty
        if slow[model] then env.Wait(100) end
        return true
    end))
    local resR
    env.CreateThread(function() resR = table.pack(Maps.rollback(d.id, 1, 1)) end)
    eq(resR, nil, 'the rollback waits in the validator')
    Maps.delete(d.id, 1)
    stubs.tick(200)
    check(resR and resR[1] == nil and resR[2] == 'not_found', 'the rollback resumes: not_found')
    eq(count(ROWS, d.id), 0, 'no version row, no map row')

    -- the limits never wait for Core.Settings: an apply, a publish, setActive and openDraft read none
    local get = Core.Settings.get
    Core.Settings.get = function(key) error('Core.Settings.get(' .. tostring(key) .. ') during a map change') end
    local lm = Maps.create({ name = 'NoSettings', mode = 'draft' }, 1)
    check(Maps.apply(lm.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1)
        and Maps.publish(lm.id, 1) == 1 and Maps.setActive(lm.id, true, 1) and Maps.openDraft(lm.id, 1) ~= nil,
        'no map change reads Core.Settings (the settings as last read)')
    Core.Settings.get = get
    Maps.closeDraft(lm.id)
    Core.Settings.set('maps.limits.opsPerApply', 1)
    local two = { { op = 'create', type = 'core:point', pos = { x = 1, y = 0, z = 0 } },
        { op = 'create', type = 'core:point', pos = { x = 2, y = 0, z = 0 } } }
    eq(select(2, Maps.apply(lm.id, two, 1)), 'too_many_ops', 'a changed setting reaches the limits (onChange)')
    Core.Settings.reset('maps.limits.opsPerApply')
    check(Maps.apply(lm.id, two, 1), 'and its reset too')

    -- item 8: the prune of a full journal is ONE keyed statement per map; the newer bound supersedes the older
    Core.Settings.get = function(key)
        if key == 'maps.journalMax' then return 2 end
        return get(key)
    end
    H.cronJobs[1].fn()
    local drops = 0
    local handler = env.AddEventHandler('core:hook:dbWriteFailed', function(_, kind, tbl)
        if kind == 'sql' and tbl == nil then drops = drops + 1 end
    end)
    H.fail('^DELETE FROM map_journal', 'XX000 simulated failure')
    mark = #H.sqlLog
    for i = 1, 3 do Maps.apply(lm.id, { { op = 'update', id = 1, set = { pos = { x = i, y = 0, z = 0 } } } }, 1) end
    local prunes = H.sqlLog
    local keyed = 0
    for i = mark + 1, #prunes do
        if prunes[i].sql:find('^DELETE FROM map_journal') and prunes[i].key == 'core:maps.prune:' .. lm.id then
            keyed = keyed + 1
        end
    end
    eq(keyed, 3, 'each apply queued its prune with the key core:maps.prune:<id>')
    H.release()                                  -- the three applies = one slice = one flush
    eq(drops, 1, 'core_db ran ONE prune statement for the three (the older twins were superseded)')
    H.unfail()
    Maps.apply(lm.id, { { op = 'update', id = 1, set = { pos = { x = 0, y = 0, z = 0 } } } }, 1)
    local left = H.sql('SELECT seq FROM map_journal WHERE map_id = $1 ORDER BY seq', { lm.id })
    local idx = R.state.journalIdx[lm.id]
    check(#left == 2 and left[1].seq == idx.seq[idx.first] and left[2].seq == idx.seq[idx.last],
        'the next prune covers the rows the failed one left: the table equals the index again')
    Core.Settings.get = get
    H.cronJobs[1].fn()
    env.RemoveEventHandler(handler)

    -- a clear is ONE statement; an edit, the clear and its undo in one slice still leave the undo in the table
    local cm = Maps.create({ name = 'ClearUndo', mode = 'live' }, 1)
    Maps.apply(cm.id, { { op = 'create', type = 'core:point', pos = { x = 1, y = 0, z = 0 } },
        { op = 'create', type = 'core:point', pos = { x = 2, y = 0, z = 0 } } }, 1)
    H.release()
    mark = #H.sqlLog
    Maps.apply(cm.id, { { op = 'update', id = 1, set = { pos = { x = 7, y = 0, z = 0 } } } }, 1)
    local okClear, cleared = Maps.clear(cm.id, 1)
    check(okClear and Maps.apply(cm.id, (Maps.invert(cleared)), 1), 'edit, clear and undo in one slice')
    eq(#H.statements('^DELETE FROM map_elements WHERE map_id = %$1', mark + 1), 1, 'the clear is one statement')
    eq(#H.statements('^remove map_elements', mark + 1), 0, 'no row-by-row removes')
    rows = H.sql('SELECT element_id, pos FROM map_elements WHERE map_id = $1 ORDER BY element_id', { cm.id })
    check(#rows == 2 and rows[1].pos.x == 7 and rows[2].pos.x == 2,
        'the undo landed after the DELETE (a raw statement is a coalescing barrier): both elements are in the table')
end

H.finish()
