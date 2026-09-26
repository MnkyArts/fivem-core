--[[
    core/tests/maps_store_tests.lua — offline suite for Core.Maps (DESIGN §52.2), part 2.

        lua5.4 tests/maps_store_tests.lua    (from the resource directory, or from tests/)

    The journal (rows, update diffs, clear summaries, per-map and server-wide caps), clear, expiry,
    placeholders, networkedTotal, delete, rollback re-checks, the persistence round trip, the async load
    barrier and running without a region module. Harness: tests/maps_harness.lua. Exit 1 on failure.
]]

local here = (arg and arg[0] or 'tests/maps_store_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test files
local H = dofile(here .. '/maps_harness.lua')
H.name = 'maps store'
local stubs, check, eq, callable, calls, reset = H.stubs, H.check, H.eq, H.callable, H.calls, H.reset
local newServer, as, stop, lastAudit, byUid = H.newServer, H.as, H.stop, H.lastAudit, H.byUid

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
    eq(#calls('remove', 0), 3, 'and removes each from the regions')
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
    local ph = calls('put', 0)[1]
    check(ph and ph.uid == deco.id .. ':1' and ph.tuple[2] == 4 and ph.tuple[10] == 24 and ph.tuple[3] == 0
        and ph.tuple[12].t == 'deco:lamp', 'a record of an undefined type is re-put as an editor-only placeholder (extra.t)')
    eq(#Maps.elements(deco.id), 1, 'the record is kept')
    check(Maps.apply(deco.id, { { op = 'update', id = 1, set = { pos = { x = 1, y = 1, z = 1 } } } }, 1),
        'a placeholder can still be moved')
    eq(select(2, Maps.apply(deco.id, { { op = 'update', id = 1, set = { fields = {} } } }, 1)), 'type',
        'but its fields cannot change')
    reset()
    as('deco', 'defineType', { id = 'deco:lamp', kind = 'prop', model = 'prop_lamp' })
    check(calls('put', 0)[1].tuple[2] == 1, 'the type returns: rendered as a prop again')

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
    eq(#calls('clear', eb), 1, 'its editor bucket is cleared')
    eq(Maps.get(dropped.id), nil, 'it is gone')
    local left = 0
    for key in pairs(stubs.kvp) do
        if key:find(dropped.id .. ':', 1, true) or key == 'doc:maps:' .. dropped.id then left = left + 1 end
    end
    eq(left, 0, 'with its elements, versions and journal')
    eq(lastAudit('maps.delete').targets[1].id, dropped.id, 'delete is audited')
end

--------------------------------------------------------------------------------
-- persistence round trip, the async load barrier, no region module
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
    eq(#calls('put', 0), 2, 'the active live map is shown again')
    local shown = calls('put', 4)
    check(#shown == 2 and byUid(shown, draftId .. ':1').tuple[4] == 5.0, 'the draft shows its published snapshot, not the edit')
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
    eq(#calls('put', 4), 1, 'only the edited element is re-put (stamps survived the restart)')

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
    eq(#calls('put', 0), 3, 'and activated once')

    stubs.clear()
    _, Core = newServer({ noRegions = true })
    local m = Core.Maps.create({ name = 'NoRegions', mode = 'live' }, 1)
    check(Core.Maps.apply(m.id, { { op = 'create', type = 'core:point', pos = { x = 0, y = 0, z = 0 } } }, 1),
        'applies work without a region module')
    local warned = 0
    for i = 1, #stubs.printed do
        if stubs.printed[i]:find('MapRegions is not loaded', 1, true) then warned = warned + 1 end
    end
    eq(warned, 1, 'with one warning')
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


H.finish()
