return function(H)
    local check, clearFailures, eq, lastSent, newServer, printed, same, stubs, suite, vector3 =
        H.check, H.clearFailures, H.eq, H.lastSent, H.newServer, H.printed, H.same, H.stubs, H.suite, H.vector3

--- Runs the playerConnecting deferral for `src` to its end; returns { done, reason, updates }.
--- `extra` adds identifiers ({ discord = 'discord:1' }) next to the license.
local function connecting(env, src, license, extra)
    local ids = license and { license = license } or {}
    for kind, value in pairs(extra or {}) do ids[kind] = value end
    stubs.identifiers[src] = ids
    local result = { updates = 0 }
    local deferrals = {
        defer = function() end,
        update = function() result.updates = result.updates + 1 end,
        done = function(reason) result.done, result.reason = true, reason end,
    }
    env.CreateThread(function()
        stubs.triggerOn(env, 'playerConnecting', src, 'Name', function() end, deferrals)
    end)
    stubs.tick(10)
    return result
end

--- One ban row + its identifiers (§56.6: bans + ban_identifiers). `expires` is SQL for expires_at.
local function seedBan(id, reason, expires, identifiers, revoked)
    H.sql(('INSERT INTO bans (id, reason, expires_at, revoked_at) VALUES ($1, $2, %s, %s)')
        :format(expires or 'NULL', revoked and 'now()' or 'NULL'), { id, reason })
    for i = 1, #identifiers do
        H.sql('INSERT INTO ban_identifiers (ban_id, identifier) VALUES ($1, $2)', { id, identifiers[i] })
    end
end

--- DESIGN §47 (connect path, Player.ban delegation) and §48 (sticky states, setCoords opts, the
--- account reader, bucketChanged) — the server/player.lua half of the admin additions — plus the §56 database
--- paths of server/getters.lua (findAccountsByIdentifier, Vehicles.setData/getData).
local function suitePlayerAdmin()
    suite('player admin')
    stubs.resetServer()
    local env, Core = newServer()
    local P = Core.Player
    local realBans = rawget(Core, 'Bans')
    Core.Bans = nil
    local log, clearLog = H.spyDB(env)

    -- 1. connect path without Core.Bans: ONE indexed query on ban_identifiers + bans (§56.8)
    seedBan('B900', 'old shape', nil, { 'license:old' })
    seedBan('B901', 'new shape', "now() + interval '10 minutes'", { 'discord:1', 'license:new' })
    seedBan('B902', 'r', nil, { 'license:revoked' }, true)
    seedBan('B903', 'e', "now() - interval '1 minute'", { 'license:expired' })
    clearLog()
    local res = connecting(env, 30, 'license:old')
    eq(res.done, true, 'the deferral finishes')
    check((res.reason or ''):find('permanently banned', 1, true) ~= nil, 'a permanent ban rejects')
    check((res.reason or ''):find('old shape', 1, true) ~= nil, 'the reject text carries the reason')
    check((res.reason or ''):find('(ban B900)', 1, true) ~= nil, '... and the ban id')
    local banReads = {}
    for i = 1, #log do
        if log[i].fn == 'query' or log[i].fn == 'crud' then banReads[#banReads + 1] = log[i] end
    end
    eq(#banReads, 1, 'the check is one awaited statement')
    local banSql = banReads[1] and banReads[1].args[1] or ''
    check(type(banSql) == 'string' and banSql:find('FROM ban_identifiers', 1, true) and banSql:find('ANY($1', 1, true),
        '... on the ban_identifiers index', tostring(banSql))
    res = connecting(env, 31, 'license:new')
    check((res.reason or ''):find('banned until', 1, true) ~= nil, 'a timed ban on the license rejects with its expiry')
    res = connecting(env, 36, 'license:alt', { discord = 'discord:1' })
    check((res.reason or ''):find('new shape', 1, true) ~= nil, 'any identifier of the connection matches (discord)')
    eq(connecting(env, 32, 'license:revoked').reason, nil, 'a revoked ban lets the player in')
    eq(connecting(env, 33, 'license:expired').reason, nil, 'an expired ban lets the player in')
    res = connecting(env, 34, 'license:clean')
    eq(res.done, true, 'a clean license passes')
    eq(res.reason, nil, '... with done() and no reason')
    check((connecting(env, 35, nil).reason or ''):find('No license', 1, true) ~= nil, 'no license identifier is refused first')

    -- 2. connect path with Core.Bans.checkConnecting (§47)
    local asked = {}
    Core.Bans = { checkConnecting = function(src)
        asked[#asked + 1] = src
        if src == 40 then return { id = 'b40', reason = 'aimbot', expiresAt = 0 }, 'custom text (ban b40)' end
        if src == 41 then return { id = 'b41', reason = 'wallhack', expiresAt = 0 } end
        if src == 42 then error('index exploded') end
        return nil
    end }
    eq(connecting(env, 40, 'license:a').reason, 'custom text (ban b40)', "Bans' reject text is used verbatim")
    eq(asked[1], 40, 'checkConnecting got the connecting src')
    res = connecting(env, 41, 'license:b')
    check((res.reason or ''):find('wallhack', 1, true) and (res.reason or ''):find('(ban b41)', 1, true),
        'a ban without text gets reason + id from player.lua')
    eq(connecting(env, 43, 'license:old').reason, nil, 'with Core.Bans the ban query is not consulted')
    res = connecting(env, 42, 'license:old')
    check((res.reason or ''):find('old shape', 1, true) ~= nil, 'a failing checkConnecting falls back to the ban query')
    check(printed('using the identifier check') ~= nil, '... and says so')

    -- M4: Bans answering `nil, 'unavailable'`, and a ban query that FAILS (§56.8 rule 4: driven by the error)
    Core.Bans = { checkConnecting = function() return nil, 'unavailable' end }
    check((connecting(env, 44, 'license:old').reason or ''):find('old shape', 1, true) ~= nil,
        "'unavailable' falls back to the ban query")
    eq(connecting(env, 45, 'license:clean2').reason, nil, '... which admits a clean license while bans is readable')
    H.bridge.fail('FROM ban_identifiers', 'XX000 simulated read failure')
    eq(connecting(env, 46, 'license:clean3').reason, 'Ban service unavailable, please try again in a minute.',
        'a ban query that fails refuses the connection (bans.failClosed defaults to true)')
    local realSettings = rawget(Core, 'Settings')
    Core.Settings = { get = function(key) if key == 'bans.failClosed' then return false end end }
    eq(connecting(env, 47, 'license:clean4').reason, nil, 'bans.failClosed = false admits instead')
    Core.Settings = realSettings
    H.bridge.unfail()
    local realState = env.GetResourceState
    env.GetResourceState = function(res2) if res2 == 'core_db' then return 'stopped' end return realState(res2) end
    eq(connecting(env, 48, 'license:clean5').reason, 'Ban service unavailable, please try again in a minute.',
        'core_db not running fails closed too')
    env.GetResourceState = realState
    -- R2a-10: the fallback read gives up after 5 s, and is skipped when core_db is down anyway
    clearLog()
    connecting(env, 49, 'license:clean6')
    local fallback
    for i = 1, #log do
        if log[i].fn == 'query' and tostring(log[i].args[1]):find('FROM ban_identifiers', 1, true) then fallback = log[i] end
    end
    eq(fallback and type(fallback.args[3]) == 'table' and fallback.args[3].timeoutMs, 5000,
        'the fallback ban query carries { timeout = 5000 }')
    local realHealthy = Core.DB.isHealthy
    Core.DB.isHealthy = function() return false end
    clearLog()
    eq(connecting(env, 50, 'license:clean7').reason, 'Ban service unavailable, please try again in a minute.',
        'Core.Bans unavailable + core_db unhealthy refuses at once')
    local skipped = true
    for i = 1, #log do
        if log[i].fn == 'query' then skipped = false end
    end
    eq(skipped, true, '... without running the fallback query (it would only wait for its timeout)')
    Core.DB.isHealthy = realHealthy
    clearFailures()

    -- §47: the engine PREFIX-matches the identifier type — ask 'license:', never take 'license2:'
    local realById = env.GetPlayerIdentifierByType
    env.GetPlayerIdentifierByType = function(src, kind)
        local ordered = { 'license2:second', 'license:real', 'fivem:9' }
        if tonumber(src) ~= 49 then return realById(src, kind) end
        for i = 1, #ordered do
            if ordered[i]:sub(1, #kind) == kind then return ordered[i] end
        end
        return nil
    end
    stubs.connectPlayer(env, 49, { license = 'license:ignored', name = 'Prefix' })
    eq(P.getLicense(49), 'license:real', "the session license is the 'license:' one, not license2")
    eq(P.getAccount(49).identifiers.fivem, 'fivem:9', 'the other identifier types are asked with the colon too')
    env.GetPlayerIdentifierByType = realById
    stubs.dropPlayer(env, 49)

    -- 3. Player.ban delegates to Core.Bans.add (§47)
    stubs.connectPlayer(env, 1, { license = 'license:p1', name = 'Ada', coords = vector3(10.0, 0.0, 0.0) })
    local added = {}
    Core.Bans = { add = function(opts)
        added[#added + 1] = opts
        if opts.reason == 'refuse' then return nil, 'nope' end
        return { id = 'ban' .. #added }
    end }
    stubs.dropped = {}
    eq(P.ban(1, 'cheating', 3600, 7), true, 'ban delegates and reports success')
    eq(added[1].target, 1, 'Bans.add gets the online src as target')
    eq(added[1].reason, 'cheating', '... the reason')
    eq(added[1].duration, 3600, '... the duration in seconds')
    eq(added[1].by, 7, '... and who issued it')
    eq(#stubs.dropped, 0, 'player.lua leaves the kick to Bans.add')
    eq(H.scalar('SELECT count(*) AS n FROM bans'), 4, 'player.lua wrote no ban row of its own')
    P.ban(1, 'forever')
    eq(added[2].duration, 0, 'no seconds = permanent (duration 0)')
    P.ban(1, 'neg', -5)
    eq(added[3].duration, 0, 'a negative duration is permanent too')
    stubs.dropped = {}
    eq(P.ban(1, 'refuse'), false, 'a refused Bans.add reports false')
    check(printed('Bans.add refused') ~= nil, '... and is logged')
    eq(stubs.dropped[1] and stubs.dropped[1].src, 1, 'R2a-6: the player is kicked all the same')
    eq(stubs.dropped[1] and stubs.dropped[1].reason, 'refuse', '... with the reason')
    eq(P.ban(99, 'x'), false, 'an unconnected src never reaches Bans.add')
    eq(#added, 4, 'the refused call was the last one')
    Core.Bans = realBans

    -- 4. sticky states live in the session and reach the client (§48)
    local states = P.getStates(1)
    eq(states.frozen, false, 'a new session is not frozen')
    eq(states.visible, true, '... is visible')
    eq(states.controls, true, '... has controls')
    eq(states.invincible, false, '... and is not invincible')
    stubs.clear()
    eq(P.setFrozen(1, true), true, 'setFrozen')
    eq(P.getStates(1).frozen, true, 'getStates reads the sticky value back')
    local sent = lastSent('core:client:playerState')
    eq(sent and sent.target, 1, 'the state goes to that client alone')
    eq(sent and sent.args[1].frozen, true, '... carrying only the changed key')
    eq(sent and sent.args[1].visible, nil, '... and nothing else')
    eq(P.setVisible(1, false), true, 'setVisible')
    eq(P.setInvincible(1, true), true, 'setInvincible')
    eq(P.setControls(1, false), true, 'setControls')
    states = P.getStates(1)
    eq(states.visible == false and states.invincible and states.controls == false, true, 'all four are stored')
    states.frozen = false
    eq(P.getStates(1).frozen, true, 'getStates hands out a copy')
    eq(P.setFrozen(1, 'yes'), false, 'a non-boolean state is refused')
    eq(P.getStates(1).frozen, true, '... and changes nothing')
    eq(P.setFrozen(99, true), false, 'no session, no state')
    eq(P.getStates(99), nil, 'getStates without a session is nil')
    stubs.clear()
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 1) end)
    local payload = lastSent('core:client:loaded').args[1]
    eq(payload.states and payload.states.frozen, true, 'the loaded payload carries the sticky states')
    eq(payload.states and payload.states.visible, false, '... every one of them')
    stubs.tick(1100)
    P.setFrozen(1, false)
    stubs.clear()
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 1) end)
    eq(lastSent('core:client:loaded').args[1].states.frozen, false, 'a state change invalidates the cached payload')

    -- 5. setBucket tells the client (§48, for the §52 map runtime)
    stubs.clear()
    eq(P.setBucket(1, 12), true, 'setBucket')
    sent = lastSent('core:client:bucketChanged')
    eq(sent and sent.target, 1, 'core:client:bucketChanged goes to that player')
    eq(sent and sent.args[1], 12, '... with the new bucket')
    P.setBucket(1, 0)

    -- 6. setCoords opts (§48)
    stubs.loadFile(env, 'server/getters.lua')   -- Player.getInVehicle, for the riders of a bucket move
    stubs.clear()
    eq(P.setCoords(1, vector3(1.0, 2.0, 3.0), 90.0), true, 'setCoords without opts')
    sent = lastSent('core:client:teleport')
    eq(sent.args[3], nil, 'a plain faded teleport sends no opts table')
    eq(P.setCoords(1, vector3(1.0, 2.0, 3.0), 90.0, { fade = false }), true, 'fade = false')
    sent = lastSent('core:client:teleport')
    eq(sent.args[3] and sent.args[3].fade, false, 'the client is told to skip the fade')
    eq(sent.args[3] and sent.args[3].withVehicle, false, '... and not to take a car')
    stubs.clear()
    eq(P.setCoords(1, vector3(1.0, 2.0, 3.0), nil, { withVehicle = true }), true, 'withVehicle while on foot')
    eq(lastSent('core:client:teleport').args[3], nil, 'on foot there is no car to take along')
    eq(P.setCoords(1, vector3(1.0, 2.0, 3.0), nil, 'x'), false, 'opts must be a table')
    eq(P.setCoords(1, vector3(1.0, 2.0, 3.0), nil, { bucket = -3 }), false, 'a bad bucket refuses the teleport')
    eq(P.setCoords(1, vector3(1.0, 2.0, 3.0), nil, { bucket = 1.5 }), false, 'so does a fractional one')
    eq(lastSent('core:client:bucketChanged'), nil, '... before anything moved')

    -- the driver of a car with a second player in it
    stubs.connectPlayer(env, 2, { license = 'license:p2', name = 'Bo' })
    local car = stubs.newEntity(2, {})
    local ped1, ped2 = stubs.peds[1], stubs.peds[2]
    stubs.pedVehicle[ped1], stubs.pedVehicle[ped2] = car, car
    stubs.vehicleSeats[car] = { [-1] = ped1, [0] = ped2 }
    stubs.clear()
    eq(P.setCoords(1, vector3(50.0, 60.0, 70.0), 180.0, { withVehicle = true, bucket = 44 }), true,
        'a driver teleports with the car into another bucket')
    sent = lastSent('core:client:teleport')
    eq(sent.args[3] and sent.args[3].withVehicle, true, 'the driver is told to move the car')
    eq(sent.args[3] and sent.args[3].fade, true, '... faded')
    eq(stubs.buckets[1], 44, 'the driver changed bucket')
    eq(stubs.entities[car].bucket, 44, 'the car went along')
    eq(stubs.buckets[2], nil, 'the passenger stays unless the caller asks (moveRiders, R2-13)')
    eq(P.setCoords(1, vector3(50.0, 60.0, 70.0), 180.0, { withVehicle = true, bucket = 45, moveRiders = true }), true,
        'moveRiders = true')
    eq(stubs.buckets[2], 45, '... takes the passenger along')
    eq(stubs.buckets[1], 45, '... and the driver')
    eq(P.getData(1, 'position').x, 50.0, 'the stored position followed')
    local order = {}
    for i = 1, #stubs.sent do order[#order + 1] = stubs.sent[i].target .. ':' .. stubs.sent[i].name end
    local joined = table.concat(order, ' ')
    check(joined:find('1:core:client:bucketChanged', 1, true) < joined:find('1:core:client:teleport', 1, true),
        'the bucket changes before the teleport', joined)
    stubs.clear()
    P.setCoords(2, vector3(0.0, 0.0, 0.0), nil, { withVehicle = true })
    eq(lastSent('core:client:teleport').args[3], nil, 'a passenger never takes the car')
    stubs.pedVehicle[ped1], stubs.pedVehicle[ped2] = nil, nil

    -- 7. the account reader (§48)
    Core.Perms.grant(1, 'core.test', 'account')
    local acc = P.getAccount(1)
    eq(acc.name, 'Ada', 'getAccount carries the name')
    eq(acc.group, 'user', '... the group')
    eq(acc.identifiers.license, 'license:p1', '... the identifiers')
    eq(type(acc.firstSeen), 'number', '... firstSeen')
    eq(acc.banned, false, '... banned')
    eq(acc.permissions, nil, '... and never the permissions list')
    eq(acc.license, nil, 'only the documented fields are copied')
    acc.identifiers.license = 'tampered'
    eq(P.getAccount(1).identifiers.license, 'license:p1', 'getAccount hands out a copy')
    eq(P.getAccount(99), nil, 'no session, no account')
    local accountId = P.getInfo(1).accountId
    H.sql("UPDATE accounts SET name = 'Stale' WHERE id = $1", { accountId })
    eq(P.getAccountById(accountId).name, 'Ada', 'getAccountById prefers the live session while online')
    stubs.dropPlayer(env, 1)
    H.sql("UPDATE accounts SET name = 'Offline' WHERE id = $1", { accountId })
    clearLog()
    local offline = P.getAccountById(accountId) or {}
    eq(offline.name, 'Offline', 'offline it reads the stored row')
    local accountReads = 0
    for i = 1, #log do
        if log[i].fn == 'query' or log[i].fn == 'crud' then accountReads = accountReads + 1 end
    end
    eq(accountReads, 1, '... in ONE awaited query (the row and its identifiers)')
    eq(offline.id, accountId, '... id included')
    eq(offline.identifiers and offline.identifiers.license, 'license:p1', '... identifiers from account_identifiers')
    eq(offline.group, 'user', '... the group')
    eq(type(offline.firstSeen), 'number', '... times as Unix seconds')
    eq(offline.banned, false, '... banned')
    eq(offline.permissions, nil, '... and never the permissions list')
    eq(P.getAccountById('nope'), nil, 'an unknown id is nil')
    eq(P.getAccountById({}), nil, 'a table is not an id')
    H.bridge.fail('FROM accounts a', 'XX000 simulated read failure')
    eq(P.getAccountById(accountId), nil, 'a read error answers nil ...')
    H.bridge.unfail()
    check(printed('the account cannot be read') ~= nil, '... and is logged')

    -- 8. setGroup asks Perms.groupExists when perms v2 provides it (§44)
    local realExists = rawget(Core.Perms, 'groupExists')
    Core.Perms.groupExists = function(name) return name == 'eventstaff' end
    eq(P.setGroup(2, 'eventstaff'), true, 'a group that only exists in perm_groups is accepted')
    eq(P.getInfo(2).group, 'eventstaff', '... and stored')
    local p2Account = P.getInfo(2).accountId
    eq(H.scalar('SELECT perm_group FROM accounts WHERE id = $1', { p2Account }), 'eventstaff',
        '... as accounts.perm_group, at once')
    eq(P.setGroup(2, 'admin'), false, 'groupExists is the authority, not the config seed')
    Core.Perms.groupExists = realExists
    eq(P.setGroup(2, 'admin'), true, 'the restored lookup accepts a seeded group')
    eq(P.setGroup(2, 'eventstaff'), false, '... and knows no eventstaff')

    -- 9. L2: group and grant writes announce permsChanged (perms caches, staff sets); each is queued at once
    local changes = {}
    Core.on('permsChanged', function(src, what) changes[#changes + 1] = tostring(src) .. ':' .. tostring(what) end)
    P.setGroup(2, 'mod')
    check(table.concat(changes, ' '):find('2:group', 1, true) ~= nil, 'setGroup emits permsChanged (src, group)')
    changes = {}
    P.setAccountData(2, 'group', 'admin')
    check(table.concat(changes, ' '):find('2:group', 1, true) ~= nil, "setAccountData('group') too")
    eq(H.scalar('SELECT perm_group FROM accounts WHERE id = $1', { p2Account }), 'admin', '... through perm_group')
    changes = {}
    P.setAccountData(2, 'permissions', { 'x.y' })
    eq(changes[1], '2:grants', "setAccountData('permissions') emits (src, grants)")
    eq(H.scalar("SELECT array_to_string(permissions, ',') AS p FROM accounts WHERE id = $1", { p2Account }), 'x.y',
        '... stored in accounts.permissions (text[])')
    changes = {}
    P.setAccountData(2, 'tempPermissions', { ['x.z'] = 1900000000 })
    eq(changes[1], '2:grants', "... and so does 'tempPermissions'")
    eq(H.scalar("SELECT (temp_permissions ->> 'x.z')::bigint AS t FROM accounts WHERE id = $1", { p2Account }),
        1900000000, '... stored in accounts.temp_permissions')
    changes = {}
    P.setAccountData(2, 'note', 'hello')
    eq(#changes, 0, 'any other account field is silent')
    eq(H.scalar("SELECT data ->> 'note' AS n FROM accounts WHERE id = $1", { p2Account }), 'hello',
        '... and lands in accounts.data')
    P.setAccountData(2, 'banned', true)
    eq(H.scalar('SELECT banned FROM accounts WHERE id = $1', { p2Account }), true, "'banned' is the banned column")
    P.setAccountData(2, 'banned', false)
    eq(P.setAccountData(2, 'identifiers', { license = 'license:forged' }), false,
        'the engine-sourced identifiers cannot be overwritten')
    eq(P.setAccountData(2, 'createdAt', 5), false, '... nor the row\'s own identity')
    stubs.dropPlayer(env, 2)
    stubs.connectPlayer(env, 2, { license = 'license:p2', name = 'Bo' })
    eq(P.getAccount(2).group, 'admin', 'a reconnect reads the group back')
    eq(P.getData(2, 'note'), nil, 'account plugin keys never leak into the character')

    -- 10. Player.findAccountsByIdentifier (§47 offline bans): ONE indexed query, no in-memory index
    local F = P.findAccountsByIdentifier
    check(type(F) == 'function', 'getters.lua installed findAccountsByIdentifier')
    H.bridge.fail('FROM account_identifiers WHERE identifier', 'XX000 simulated read failure')
    local none, why = F('license:p1')
    H.bridge.unfail()
    eq(none, nil, 'R2-11: accounts that cannot be read answer nil ...')
    eq(why, 'unavailable', "... 'unavailable' (never 'nobody holds it')")
    local offlineId = accountId                              -- Ada's account, player 1 dropped above
    clearLog()
    same(F('license:p1'), { offlineId }, 'an offline account is found by its license')
    local lookups = {}
    for i = 1, #log do
        if log[i].fn == 'query' or log[i].fn == 'crud' then lookups[#lookups + 1] = log[i] end
    end
    eq(#lookups, 1, 'one awaited statement per lookup')
    local lookupSql = lookups[1] and lookups[1].args[1] or ''
    check(type(lookupSql) == 'string' and lookupSql:find('WHERE identifier = $1', 1, true) ~= nil,
        '... on the identifier index', tostring(lookupSql))
    check(type(lookups[1] and lookups[1].args[3]) == 'table' and lookups[1].args[3].sync == true,
        '... with { sync = true } (identifiers queued by a join a moment ago count)')
    same(F('license:p2'), { p2Account }, 'an online one too')
    same(F('fivem:2'), { p2Account }, 'any identifier type works')
    stubs.connectPlayer(env, 6, { name = 'Dee', identifiers = { license = 'license:p6', discord = 'discord:shared' } })
    stubs.connectPlayer(env, 7, { name = 'Eve', identifiers = { license = 'license:p7', discord = 'discord:shared' } })
    local six, seven = P.getInfo(6).accountId, P.getInfo(7).accountId
    local expected = { six, seven }
    table.sort(expected)
    same(F('discord:shared'), expected, 'a shared identifier lists both accounts, sorted')
    stubs.dropPlayer(env, 7)
    stubs.connectPlayer(env, 8, { name = 'Eve', identifiers = { license = 'license:p7', discord = 'discord:new' } })
    same(F('discord:shared'), { six }, 'an identifier the account no longer carries is not reported')
    same(F('discord:new'), { seven }, 'its new one is')
    same(F('discord:nobody'), {}, 'an unknown identifier: empty')
    same(F('nocolon'), {}, 'not type:value: empty')
    same(F(42), {}, 'not a string: empty')
    same(F('ip:127.0.0.1'), {}, 'ip: is never stored')

    -- R2-3: every identifier type the engine lists is stored (license2, xbl, live …), never ip:
    local list = { 'license:p9', 'license2:p9b', 'xbl:p9x', 'live:p9l', 'discord:p9d', 'ip:10.0.0.9' }
    env.GetNumPlayerIdentifiers = function(src) return tonumber(src) == 9 and #list or 0 end
    env.GetPlayerIdentifier = function(src, i) return tonumber(src) == 9 and list[i + 1] or nil end
    stubs.connectPlayer(env, 9, { name = 'Nine', identifiers = { license = 'license:p9' } })
    env.GetNumPlayerIdentifiers, env.GetPlayerIdentifier = nil, nil
    local nine = P.getAccount(9)
    eq(nine.identifiers.license2, 'license2:p9b', 'license2 is stored')
    eq(nine.identifiers.xbl, 'xbl:p9x', 'xbl is stored')
    eq(nine.identifiers.live, 'live:p9l', 'live is stored')
    eq(nine.identifiers.ip, nil, 'ip is not')
    eq(H.scalar("SELECT count(*) AS n FROM account_identifiers WHERE account_id = $1 AND kind = 'ip'", { nine.id }), 0,
        '... not even in account_identifiers')
    same(F('license2:p9b'), { nine.id }, 'license2 finds the account')
    same(F('live:p9l'), { nine.id }, 'live finds the account')
    -- rows written without a join (the legacy import, an admin tool) are found at once: there is no index to rebuild
    H.sql("INSERT INTO accounts (id, license, name) VALUES ('imp0000000000000000000000000001', 'license:imp', 'Imp')")
    H.sql("INSERT INTO account_identifiers (account_id, kind, identifier) VALUES "
        .. "('imp0000000000000000000000000001', 'discord', 'discord:imp')")
    same(F('discord:imp'), { 'imp0000000000000000000000000001' }, 'an account written without a join is found')
    same(F('license:imp'), { 'imp0000000000000000000000000001' }, '... by its license column as well')
    H.sql("UPDATE account_identifiers SET identifier = 'discord:changed' WHERE account_id = "
        .. "'imp0000000000000000000000000001' AND kind = 'discord'")
    same(F('discord:changed'), { 'imp0000000000000000000000000001' }, 'an in-place identifier edit is seen at once')
    same(F('discord:imp'), {}, '... and the old value is gone')

    -- 11. Vehicles.setData / getData (server/getters.lua): ONE atomic statement each (§56.8 rule 2)
    local V = Core.Vehicles
    H.sql([[INSERT INTO vehicles (id, model, plate, meta) VALUES
        ('vehA', 1, 'W1A0001', '{"vehType":"car"}'), ('vehB', 2, 'W1A0002', '[]')]])
    clearLog()
    eq(V.setData('vehA', 'fuel', 50), true, 'setData writes one meta key')
    local writes = {}
    for i = 1, #log do
        if log[i].fn == 'query' or log[i].fn == 'crud' or log[i].fn == 'enqueue' then writes[#writes + 1] = log[i] end
    end
    eq(#writes, 1, '... in ONE statement (no read-modify-write round trip)')
    eq(writes[1] and type(writes[1].args[3]) == 'table' and writes[1].args[3].sync, nil,
        'R2a-7: ... without { sync } (no queued entry ever writes meta)')
    check(writes[1] and type(writes[1].args[1]) == 'string' and writes[1].args[1]:find('jsonb_set', 1, true) ~= nil,
        '... a jsonb_set UPDATE inside Postgres')
    eq(V.setData('vehA', 'inventory', { slots = 20 }), true, 'a second key')
    local meta = H.sql("SELECT meta FROM vehicles WHERE id = 'vehA'")[1].meta
    eq(meta.vehType, 'car', 'the other keys survive (no lost update)')
    eq(meta.fuel, 50, '... the first key')
    eq(meta.inventory and meta.inventory.slots, 20, '... and the second')
    eq(V.getData('vehA', 'fuel'), 50, 'getData reads one key')
    eq(V.getData('vehA').inventory.slots, 20, 'getData without a key answers the whole meta')
    eq(V.setData('vehA', 'fuel', nil), true, 'a nil value removes the key')
    eq(V.getData('vehA', 'fuel'), nil, '... it is gone')
    eq(V.getData('vehA', 'vehType'), 'car', '... and nothing else is')
    eq(V.setData('vehB', 'pos', vector3(1.0, 2.0, 3.0)), true, 'a legacy [] meta takes a key as an object')
    eq(H.scalar("SELECT jsonb_typeof(meta) AS t FROM vehicles WHERE id = 'vehB'"), 'object', '... meta is an object now')
    eq(V.getData('vehB', 'pos').y, 2, '... and a vector3 was stored as { x, y, z }')
    eq(V.setData('nope', 'x', 1), false, 'an unknown record: false')
    eq(V.getData('nope', 'x'), nil, '... and nil')
    eq(V.setData('vehA', '', 1), false, 'an empty key is refused')
    eq(V.setData('vehA', ('k'):rep(65), 1), false, 'a key over 64 characters is refused')
    eq(V.setData('vehA', 'fn', print), false, 'a function value is refused')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

    return suitePlayerAdmin
end
