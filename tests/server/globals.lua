return function(H)
    local check, eq, newServer, stubs, suite =
        H.check, H.eq, H.newServer, H.stubs, H.suite
    local bridge = stubs.bridge

--- The stored row of one global ({ value, mirror }), or nil.
local function row(key)
    local rows = bridge.sql('SELECT value, mirror FROM globals WHERE key = $1', { key })
    return rows and rows[1]
end

--- Core.Globals (DESIGN §22, storage §56.6): the persisted key/value store (one `globals` row per key, written
--- behind with queued saves), its GlobalState mirror, the first-access load barrier — two callers during a
--- yielding load both get the rows, loaded once (the postgres race of 2026-09-16: a plugin's onReady and its
--- cron) — and a failed load that is never read as "empty". A restart is a new VM over the same database.
local function suiteGlobals()
    suite('globals')
    stubs.resetServer()
    local env, Core = newServer()
    local G = Core.Globals

    eq(G.get('unset', 7), 7, 'get of an unset key returns the default')
    eq(G.get('unset'), nil, 'and nil without one')
    eq(G.set('bad key!', 1), false, 'set refuses an invalid key')
    eq(G.get('bad key!', 'd'), 'd', 'get of an invalid key returns the default')
    eq(G.set('season', 'winter'), true, 'set stores a value')
    eq(G.get('season'), 'winter', 'get returns it')
    eq(G.set('flag', true, true), true, 'set with the mirror flag')
    eq(env.GlobalState['g:flag'], true, 'a mirrored key is published to GlobalState')
    eq(env.GlobalState['g:season'], nil, 'an unmirrored key is not')
    eq(G.set('fn', function() end), false, 'set refuses a function')
    eq(G.increment('count'), 1, 'increment starts an unset key at 0')
    eq(G.increment('count', 4), 5, 'increment adds the delta')
    eq(G.increment('season'), nil, 'increment of a non-number is nil')
    eq(row('count') and row('count').value, 5, 'the incremented value is written behind')
    eq(G.unset('count'), true, 'unset removes the key')
    eq(G.unset('count'), false, 'a second unset is false')
    eq(G.get('count'), nil, 'the key is gone')
    eq(row('count'), nil, 'unset removes the row')
    G.set('box', { a = { 1, 2 } })
    G.get('box').a[1] = 99
    eq(G.get('box').a[1], 1, 'a stored table comes back as a copy')

    -- one row per key (§56.6): value jsonb, mirror flag
    local season, flag = row('season'), row('flag')
    eq(season and season.value, 'winter', 'set writes the row of its key')
    eq(season and season.mirror, false, 'an unmirrored key is stored with mirror = false')
    eq(flag and flag.mirror, true, 'the mirror flag is stored')
    eq(G.set('off', false), true, 'false is a value')
    eq(G.get('off', 'd'), false, 'get returns false, not the default')
    eq(row('off') and row('off').value, false, 'false is stored as JSON false')
    eq(G.set('gone', 1, true), true, 'a mirrored key to unset')
    eq(G.unset('gone'), true, 'unset of a mirrored key')
    eq(env.GlobalState['g:gone'], nil, 'unset clears its GlobalState mirror')
    for _ = 1, 10 do G.increment('visits') end
    eq(G.get('visits'), 10, 'ten increments in a row are atomic in memory')
    eq(row('visits') and row('visits').value, 10, 'and the last one is stored')

    -- NaN / ±inf have no JSON form (the row's value would be NULL and poison its flush): refused, nothing changes
    eq(G.set('bad', 0 / 0), false, 'set refuses NaN')
    eq(G.set('bad', math.huge), false, 'set refuses +inf')
    eq(G.set('bad', -math.huge), false, 'set refuses -inf')
    eq(G.get('bad'), nil, 'nothing was stored for them')
    eq(G.increment('visits', math.huge), nil, 'increment refuses an infinite delta')
    eq(G.increment('visits', 0 / 0), nil, 'and a NaN delta')
    eq(G.set('big', 1.5e308), true, 'a huge finite number is fine')
    eq(G.increment('big', 1.5e308), nil, 'a sum that overflows to inf is refused')
    eq(G.get('big'), 1.5e308, 'and the value stays')
    eq(G.unset('big'), true, 'cleanup')
    eq(G.get('visits'), 10, 'the counter is untouched by the refused increments')

    -- a write the queue refuses (core_db stopped) is undone: memory and GlobalState never hold what the table will not
    stubs.resourceStates.core_db = 'stopped'
    eq(G.set('season', 'summer'), false, 'set answers false when the queue refuses the write')
    eq(G.get('season'), 'winter', 'memory keeps the old value')
    eq(G.set('flag', false, true), false, 'a refused set of a mirrored key')
    eq(env.GlobalState['g:flag'], true, 'the mirror keeps the old value')
    eq(G.set('fresh', 1, true), false, 'a refused new mirrored key')
    eq(env.GlobalState['g:fresh'], nil, 'is not left published')
    eq(G.get('fresh'), nil, 'nor in memory')
    eq(G.increment('visits'), nil, 'a refused increment answers nil')
    eq(G.get('visits'), 10, 'and leaves the counter')
    eq(G.unset('flag'), false, 'a refused unset')
    eq(G.get('flag'), true, 'keeps the key')
    eq(env.GlobalState['g:flag'], true, 'and its mirror')
    stubs.resourceStates.core_db = nil
    eq(row('season') and row('season').value, 'winter', 'the table never saw the refused writes')

    -- a restart: a fresh VM reads the rows back and republishes the mirror
    local env2, Reloaded = newServer()
    eq(Reloaded.Globals.get('season'), 'winter', 'a fresh VM reads the rows back')
    eq(env2.GlobalState['g:flag'], true, 'mirrored keys are republished on load')
    eq(env2.GlobalState['g:season'], nil, 'unmirrored keys still are not')
    eq(env2.GlobalState['g:gone'], nil, 'an unset mirrored key is not republished')
    eq(Reloaded.Globals.get('off', 'd'), false, 'false survives a restart')
    local box = Reloaded.Globals.get('box')
    eq(box and box.a and box.a[2], 2, 'a table survives a restart')
    eq(Reloaded.Globals.increment('visits'), 11, 'increment continues from the stored value after a restart')
    eq(Reloaded.Globals.set('flag', false), true, 'set of a mirrored key without the flag')
    eq(env2.GlobalState['g:flag'], false, 'it stays mirrored (the new value is published)')
    eq(row('flag') and row('flag').mirror, true, 'and the row keeps mirror = true')
    eq(Reloaded.Globals.set('season', 'spring'), true, 'a change after the restart')

    -- the first-access barrier: a load that yields, two callers at once
    local env3, Core3 = newServer()
    local DB3 = Core3.DB
    local realSelect = DB3.select
    local loads = 0
    DB3.select = function(tbl, ...)
        if tbl == 'globals' then
            loads = loads + 1
            env3.Wait(50)                      -- the round trip yields in game
        end
        return realSelect(tbl, ...)
    end
    local results = {}
    env3.CreateThread(function() results.first = Core3.Globals.get('season', 'none') end)
    env3.CreateThread(function() results.second = Core3.Globals.get('season', 'none') end)
    eq(results.first, nil, 'the first caller is parked inside the load')
    eq(results.second, nil, 'the second caller is parked on the barrier')
    stubs.tick(100)
    eq(results.first, 'spring', 'the first caller gets the loaded value')
    eq(results.second, 'spring', 'the caller that arrived during the load waits for it and gets it too')
    eq(loads, 1, 'the rows were loaded once')
    eq(env3.GlobalState['g:flag'], false, 'the mirror is republished after the load')
    eq(#stubs.failures, 0, 'no thread errored')
    eq(Core3.Globals.get('season'), 'spring', 'later callers read the loaded store')
    DB3.select = realSelect

    -- a failed load is never "empty": defaults, refused writes, nothing overwritten, retried later
    stubs.osTime = 1790000000
    bridge.fail('SELECT %* FROM "globals"', 'XX000 simulated failure')
    local env4, Core4 = newServer()
    local G4 = Core4.Globals
    eq(G4.get('season', 'none'), 'none', 'a failed load answers the default')
    eq(G4.set('season', 'autumn'), false, 'set refuses while the rows could not be read')
    eq(G4.increment('visits'), nil, 'increment refuses')
    eq(G4.unset('season'), false, 'unset refuses')
    eq(env4.GlobalState['g:flag'], nil, 'nothing is published from a failed load')
    check(H.printed('globals: could not read globals') ~= nil, 'the failed load is logged')
    bridge.unfail()
    eq(row('season') and row('season').value, 'spring', 'the stored row was never overwritten')
    eq(row('visits') and row('visits').value, 11, 'nor the counter')
    eq(G4.get('season', 'none'), 'none', 'no retry within 10 s of the failure')
    stubs.osTime = 1790000000 + 11
    eq(G4.get('season', 'none'), 'spring', 'the next access after 10 s loads the rows')
    eq(env4.GlobalState['g:flag'], false, 'and republishes the mirror')
    eq(G4.increment('visits'), 12, 'writes work again after the retry')
    stubs.osTime = nil
    eq(#stubs.failures, 0, 'no thread errored')
end

    return suiteGlobals
end
