--[[
    core/tests/server_tests.lua — the offline test suite for server/**.

        lua5.4 tests/server_tests.lua    (from the resource directory, or from tests/)

    Same harness as run_tests.lua: every native and runtime helper comes from tests/stubs.lua,
    so this proves the pure Lua contracts of DESIGN §4, §5 and §8 — never in-game behaviour.
    One server VM per suite: import.lua, shared/config.lua, then the server modules in manifest
    order (the lib chunks load lazily from the real files). Exit code is 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/server_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
local stubs = dofile(here .. '/stubs.lua')

local vector3 = stubs.vector3

--------------------------------------------------------------------------------
-- assertions (identical style and exit code to run_tests.lua)
--------------------------------------------------------------------------------

local passed, failed, suiteName = 0, 0, '?'
local failures = {}

local function suite(name)
    suiteName = name
end

local function show(v)
    if type(v) == 'string' then return ('%q'):format(v) end
    return tostring(v)
end

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    local line = ('FAIL  [%s] %s'):format(suiteName, label)
    if detail then line = line .. '\n        ' .. detail end
    failures[#failures + 1] = line
    print(line)
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label,
        ('expected %s, got %s'):format(show(expected), show(actual)))
end

--- The error of a `pcall`ed API that returns `value, err` — second return value only.
local function errOf(...)
    return (select(2, ...))
end

--- The most recent printed line containing `needle`, or nil.
local function printed(needle)
    for i = #stubs.printed, 1, -1 do
        if stubs.printed[i]:find(needle, 1, true) then return stubs.printed[i] end
    end
    return nil
end

--- The most recent TriggerClientEvent packet with that event name, or nil.
local function lastSent(name)
    for i = #stubs.sent, 1, -1 do
        if stubs.sent[i].name == name then return stubs.sent[i] end
    end
    return nil
end

local function clearFailures()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
end

--------------------------------------------------------------------------------
-- one core server VM per suite
--------------------------------------------------------------------------------

-- manifest order; a file that does not exist yet is skipped so the suite keeps running
local SERVER_FILES <const> = {
    'server/api.lua', 'server/db.lua', 'server/db_mysql.lua', 'server/notify.lua', 'server/perms.lua',
    'server/player.lua', 'server/money.lua', 'server/factions.lua', 'server/vehicles.lua',
}

--- A fresh core VM with import.lua, shared/config.lua and the server modules loaded.
--- The KVP store is deliberately *not* reset here: a second newServer() re-reads it.
local function newServer()
    stubs.newWorld()
    stubs.clear()
    clearFailures()
    -- GetGameTimer() is never 0 in game, and server/player.lua:650 treats "no previous
    -- requestLoad" as t = 0, so a clock at 0 would swallow the very first load request
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for i = 1, #SERVER_FILES do
        if stubs.readFile(stubs.root .. '/' .. SERVER_FILES[i]) then
            stubs.loadFile(env, SERVER_FILES[i])
        end
    end
    return env, env.Core
end

--------------------------------------------------------------------------------
-- suites
--------------------------------------------------------------------------------

--- Core.DB (DESIGN §4.1): CRUD, queries, deep-copy isolation and the KVP round trip.
local function suiteDB()
    suite('db')
    stubs.resetServer()
    local _, Core = newServer()
    local DB = Core.DB

    -- create / get
    local id = DB.create('widgets', { name = 'gear', tags = { 'a', 'b' }, nested = { n = 1 } })
    check(type(id) == 'string', 'create returns an id')
    eq(#(id or ''), 32, 'the generated id is a uuid')
    local doc = DB.get('widgets', id)
    eq(doc.name, 'gear', 'get returns the document')
    eq(doc.id, id, 'the document carries its id')
    check(doc.createdAt ~= nil, 'create stamps createdAt')
    check(doc.updatedAt ~= nil, 'every write stamps updatedAt')
    eq(DB.get('widgets', 'missing'), nil, 'get of a missing document is nil')
    eq(DB.get('widgets', 'bad id'), nil, 'get refuses an invalid id')
    eq(DB.get('bad name!', id), nil, 'get refuses an invalid collection name')

    -- deep-copy isolation
    doc.nested.n = 99
    doc.name = 'tampered'
    eq(DB.get('widgets', id).nested.n, 1, 'a returned document is a deep copy, nested included')
    eq(DB.get('widgets', id).name, 'gear', 'mutating the copy never reaches the store')
    check(DB.get('widgets', id) ~= DB.get('widgets', id), 'two gets return two tables')
    local input = { id = 'w-0', box = { v = 1 } }
    DB.create('widgets', input)
    input.box.v = 7
    eq(DB.get('widgets', 'w-0').box.v, 1, 'the stored document is decoupled from the caller table')

    -- create: explicit ids, duplicates, bad input
    eq(DB.create('widgets', { id = 'w-1', name = 'bolt' }), 'w-1', 'create honours an explicit id')
    eq(DB.create('widgets', { id = 'w-1' }), nil, 'create refuses a duplicate id')
    check(printed('already exists') ~= nil, 'the duplicate is logged')
    eq(DB.create('widgets', { id = 'bad id' }), nil, 'create refuses an invalid id')
    eq(DB.create('bad name!', {}), nil, 'create refuses an invalid collection name')
    eq(DB.create('widgets', 'nope'), nil, 'create refuses a non-table document')

    -- update: shallow merge, id is never rewritten
    eq(DB.update('widgets', 'w-1', { name = 'nut', extra = true }), true, 'update merges top-level keys')
    eq(DB.get('widgets', 'w-1').name, 'nut', 'update replaced the key')
    eq(DB.get('widgets', 'w-1').extra, true, 'update added a new key')
    eq(DB.update('widgets', 'missing', { a = 1 }), false, 'update of a missing document is false')
    eq(DB.update('widgets', 'w-1', { id = 'hacked' }), true, 'update ignores an id in the patch')
    eq(DB.get('widgets', 'hacked'), nil, 'the id was not rewritten')
    eq(DB.get('widgets', 'w-1').id, 'w-1', 'the document kept its own id')

    -- set: whole-document replace
    eq(DB.set('widgets', 'w-1', { name = 'screw' }), true, 'set replaces the document')
    eq(DB.get('widgets', 'w-1').extra, nil, 'the old keys are gone')
    check(DB.get('widgets', 'w-1').createdAt ~= nil, 'set keeps the original createdAt')
    eq(DB.set('widgets', 'w-3', { name = 'new' }), true, 'set creates a missing document')
    eq(DB.get('widgets', 'w-3').name, 'new', 'the created document is readable')

    -- queries
    DB.create('widgets', { id = 'w-2', name = 'screw', kind = 'x' })
    eq(#DB.find('widgets', { name = 'screw' }), 2, 'find by top-level equality')
    eq(#DB.find('widgets', function(d) return d.kind == 'x' end), 1, 'find with a predicate')
    eq(#DB.find('widgets', { name = 'nothing' }), 0, 'find without a match is an empty array')
    eq(DB.findOne('widgets', { kind = 'x' }).id, 'w-2', 'findOne returns the document')
    eq(DB.findOne('widgets', { name = 'nothing' }), nil, 'findOne without a match is nil')
    eq(DB.findOne('widgets', function() error('bad predicate') end), nil,
        'a throwing predicate never escapes')
    eq(DB.count('widgets'), 5, 'count counts the collection')
    eq(#DB.all('widgets'), 5, 'all returns every document')
    eq(DB.count('empty-one'), 0, 'an unknown collection counts 0')
    DB.find('widgets', { name = 'screw' })[1].name = 'mutated'
    eq(DB.findOne('widgets', { kind = 'x' }).name, 'screw', 'find results are copies too')

    -- delete
    eq(DB.delete('widgets', 'w-2'), true, 'delete removes the document')
    eq(DB.delete('widgets', 'w-2'), false, 'a second delete is false')
    eq(DB.get('widgets', 'w-2'), nil, 'the document is gone')
    eq(DB.count('widgets'), 4, 'count followed the delete')

    -- flush
    eq(DB.flush(), true, 'flush pushes the pending writes')
    eq(stubs.kvpFlushes, 1, 'flush reached FlushResourceKvp')
    eq(DB.flush(), false, 'a flush with nothing pending is a no-op')
    eq(stubs.kvpFlushes, 1, 'and it did not touch the adapter')

    -- KVP layout + a round trip through a brand new VM (the store outlives it)
    check(stubs.kvp['doc:widgets:w-1'] ~= nil, 'documents live under doc:<collection>:<id>')
    eq(stubs.kvp['doc:widgets:w-2'], nil, 'a deleted document is gone from KVP')
    local _, Reloaded = newServer()
    eq(Reloaded.DB.count('widgets'), 4, 'a fresh VM reads the collection back from KVP')
    eq(Reloaded.DB.get('widgets', 'w-1').name, 'screw', 'the reloaded document keeps its values')
    eq(Reloaded.DB.get('widgets', id).nested.n, 1, 'nested tables survive the JSON round trip')
    eq(Reloaded.DB.get('widgets', id).tags[2], 'b', 'arrays survive the JSON round trip')
    eq(Reloaded.DB.get('widgets', id).id, id, 'the id is restored from the key, not the value')

    -- a swapped adapter takes over and the loaded collections are dropped
    local put = {}
    eq(Reloaded.DB.setAdapter({ loadAll = function() return { ['x-1'] = '{"name":"from-adapter"}' } end,
        put = function(_, docId) put[#put + 1] = docId end,
        remove = function() end, flush = function() end }), true, 'setAdapter accepts a full adapter')
    eq(Reloaded.DB.get('widgets', 'x-1').name, 'from-adapter', 'the collection is re-read from the new adapter')
    eq(Reloaded.DB.get('widgets', 'w-1'), nil, 'the KVP-loaded documents are gone')
    Reloaded.DB.create('widgets', { id = 'x-2' })
    eq(put[1], 'x-2', 'writes go to the new adapter')
    eq(Reloaded.DB.setAdapter({ loadAll = function() end }), false, 'an incomplete adapter is refused')
    eq(Reloaded.DB.setAdapter('nope'), false, 'a non-table adapter is refused')
end

--- Core.Perms (DESIGN §4.4): console, ACE, config group, and the setGroup delegation.
local function suitePerms()
    suite('perms')
    stubs.resetServer()
    local env, Core = newServer()
    local P = Core.Perms

    -- console and plain refusals
    eq(P.has(0, 'core.admin'), true, 'the console has every permission')
    eq(P.has(0, 'anything.at.all'), true, 'the console is not checked against a list')
    eq(P.has(0, ''), false, 'an empty permission name is refused even for the console')
    eq(P.has(0, 42), false, 'a non-string permission is refused')
    eq(P.has(1, 'core.admin'), false, 'an unknown src has nothing')
    eq(P.has('1', 'core.admin'), false, 'a string src is refused (identity is a number)')
    eq(P.has(-1, 'core.admin'), false, 'a negative src is refused')
    eq(P.has(5000, 'core.admin'), false, 'an out-of-range src is refused')
    eq(P.getGroup(99), 'user', 'a src without a session reads the default group')

    -- ACE wins before the group list
    stubs.aces['1|core.admin'] = true
    eq(P.has(1, 'core.admin'), true, 'an ACE grants the permission without a session')
    eq(P.isAdmin(1), true, 'isAdmin follows the ACE')
    stubs.aces['1|core.admin'] = nil
    eq(P.has(1, 'core.admin'), false, 'removing the ACE removes the permission')

    -- config groups on the live account document
    stubs.connectPlayer(env, 1, { license = 'license:p1', name = 'Mod' })
    eq(P.getGroup(1), 'user', 'a new account starts in the user group')
    eq(P.has(1, 'core.mod'), false, 'the user group grants nothing')
    eq(P.setGroup(1, 'mod'), true, 'setGroup moves the player into a configured group')
    eq(P.getGroup(1), 'mod', 'getGroup reads the account group')
    eq(P.has(1, 'core.mod'), true, 'the group list grants its own permission')
    eq(P.has(1, 'core.admin'), false, 'mod does not imply admin')
    check(printed('perms src=1') ~= nil, 'the group change is audited')

    -- core.admin implies everything the admin group lists
    eq(P.setGroup(1, 'admin'), true, 'setGroup to admin')
    eq(P.isAdmin(1), true, 'isAdmin')
    eq(P.has(1, 'core.mod'), true, 'core.admin implies the rest of the admin list')
    eq(P.has(1, 'core.nothing'), false, 'core.admin does not invent permissions')

    -- setGroup validation
    eq(P.setGroup(1, 'wizard'), false, 'an unconfigured group is refused')
    eq(P.setGroup(1, 42), false, 'a non-string group is refused')
    eq(P.setGroup(99, 'mod'), false, 'setGroup without a session is refused')
    eq(P.setGroup(0, 'mod'), false, 'the console has no group to set')
    eq(P.getGroup(1), 'admin', 'a refused setGroup changed nothing')

    -- Core.Player.setGroup is the single writer (DESIGN §14)
    local info = Core.Player.getInfo(1)
    eq(info.group, 'admin', 'the live session carries the new group')
    eq(env.Player(1).state.group, 'admin', 'the group state-bag key was re-replicated')
    eq(Core.DB.get('accounts', info.accountId).group, 'admin', 'the account document persisted the group')
    local realSetGroup = Core.Player.setGroup
    Core.Player.setGroup = function() return false end
    eq(P.setGroup(1, 'user'), false, 'Perms.setGroup refuses when Player.setGroup refuses')
    eq(P.getGroup(1), 'admin', 'and the group did not change')
    Core.Player.setGroup = realSetGroup

    -- an unknown stored group falls back to the default
    Core.Player.setData(1, 'ignored', true)
    Core.DB.update('accounts', info.accountId, { group = 'ghost-group' })
    eq(P.getGroup(1), 'admin', 'getGroup reads the session, not the document')
    local reloadedEnv, Reloaded = newServer()
    stubs.connectPlayer(reloadedEnv, 1, { license = 'license:p1', name = 'Mod' })
    eq(Reloaded.Player.getInfo(1).group, 'ghost-group', 'the session loaded the unknown group verbatim')
    eq(Reloaded.Perms.getGroup(1), 'user', 'an unknown group in the document reads back as user')
    eq(Reloaded.Perms.has(1, 'core.admin'), false, 'and grants nothing')
end

--- Core.Player (DESIGN §4.2, §5, §8): join, requestLoad, data paths, replication, drop, kick/ban.
local function suitePlayer()
    suite('player')
    stubs.resetServer()
    local env, Core = newServer()
    local P, DB = Core.Player, Core.DB

    -- 1. playerJoining creates the account and character documents
    stubs.connectPlayer(env, 1, { license = 'license:abc', name = 'Ada',
        coords = vector3(10.0, 20.0, 30.0), heading = 90.0 })
    eq(P.isLoaded(1), true, 'playerJoining built the session')
    eq(P.count(), 1, 'one session is live')
    local info = P.getInfo(1)
    eq(info.name, 'Ada', 'the session carries the sanitized name')
    eq(info.group, 'user', 'a new account starts in the user group')
    eq(info.license, 'license:abc', 'getInfo carries the license for server code')
    eq(P.getSrcByCharId(info.charId), 1, 'byCharId points at the src')
    local account = DB.get('accounts', info.accountId)
    eq(account.license, 'license:abc', 'the account document was created')
    eq(account.identifiers.fivem, 'fivem:1', 'every identifier type was collected')
    eq(account.banned, false, 'a new account is not banned')
    eq(account.playtime, 0, 'playtime starts at zero')
    local character = DB.get('characters', info.charId)
    eq(character.accountId, info.accountId, 'the character points at its account')
    eq(character.model, Core.Config.Player.DefaultModel, 'the character gets the default model')
    eq(character.money.cash, 5000, 'Config.Player.NewCharacter seeded cash')
    eq(character.money.bank, 25000, '... and bank')
    eq(character.position.x, Core.Config.Player.SpawnPoint.coords.x, 'it spawns at the configured point')
    eq(character.stats.deaths, 0, 'the stats block exists')
    eq(DB.count('accounts'), 1, 'exactly one account document')
    eq(DB.count('characters'), 1, 'exactly one character document')
    stubs.connectPlayer(env, 1, { license = 'license:abc', name = 'Ada' })
    eq(DB.count('characters'), 1, 'a second playerJoining for a live session creates nothing')

    -- 2. the replicated player:<src> state-bag keys (DESIGN §8)
    local state = env.Player(1).state
    eq(state.loaded, true, 'the loaded key')
    eq(state.name, 'Ada', 'the name key')
    eq(state.charId, info.charId, 'the charId key')
    eq(state.group, 'user', 'the group key')
    eq(state.cash, 5000, 'the cash key mirrors money.cash')
    eq(state.bank, 25000, 'the bank key mirrors money.bank')
    eq(state.faction, false, 'no faction replicates as false, never nil')
    eq(state.dead, false, 'the dead key')

    -- 3. core:server:requestLoad answers core:client:loaded (DESIGN §5)
    stubs.clear()
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 1) end)
    local answer = lastSent('core:client:loaded')
    check(answer ~= nil, 'requestLoad answers core:client:loaded')
    eq(answer and answer.target, 1, 'the answer is targeted at the caller alone')
    local payload = answer and answer.args[1] or {}
    eq(payload.charId, info.charId, 'the payload carries charId')
    eq(payload.name, 'Ada', 'the payload carries the name')
    eq(payload.model, Core.Config.Player.DefaultModel, 'the payload carries the model')
    eq(payload.group, 'user', 'the payload carries the group')
    eq(payload.money.cash, 5000, 'the payload carries the money table')
    eq(payload.faction, false, 'the payload carries faction = false')
    eq(type(payload.appearance), 'table', 'the payload carries appearance')
    eq(payload.position.x, Core.Config.Player.SpawnPoint.coords.x, 'the payload carries the position')
    eq(payload.license, nil, 'the payload never carries the license')
    eq(payload.respawn, true, 'a fresh join asks the client to spawn')
    stubs.clear()
    stubs.triggerOn(env, 'core:server:requestLoad', 1)
    eq(lastSent('core:client:loaded'), nil, 'a repeat inside the 1 s cooldown is dropped')
    stubs.tick(1100)
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 1) end)
    eq(lastSent('core:client:loaded').args[1].respawn, false, 'the second answer clears respawn')
    stubs.tick(1100)
    stubs.clear()
    env.CreateThread(function() stubs.triggerOn(env, 'core:server:requestLoad', 42) end)
    stubs.tick(11000)
    eq(lastSent('core:client:loaded'), nil, 'a request without a session is never answered')
    check(printed('timed out without a session') ~= nil, 'the timeout is logged')

    -- 4. getData / setData dot paths
    eq(P.setData(1, 'meta.job.title', 'medic'), true, 'setData creates a missing dot path')
    eq(P.getData(1, 'meta.job.title'), 'medic', 'getData walks the dot path')
    eq(P.getData(1, 'meta.job').title, 'medic', 'getData of a table returns the subtree')
    eq(P.getData(1, 'meta.nope'), nil, 'a missing path reads nil')
    eq(P.getData(1, 'meta.job.title.deeper'), nil, 'a path through a non-table reads nil')
    local snapshot = P.getData(1, 'meta')
    snapshot.job.title = 'thief'
    eq(P.getData(1, 'meta.job.title'), 'medic', 'getData hands out a deep copy')
    eq(P.getData(1).charId, nil, 'getData() returns the character document, not the session')
    eq(P.getData(1).model, Core.Config.Player.DefaultModel, 'getData() returns the whole document')
    eq(P.setData(1, '', 'x'), false, 'an empty path is refused')
    eq(P.setData(1, 42, 'x'), false, 'a non-string path is refused')
    eq(P.setData(99, 'meta.x', 1), false, 'setData without a session is refused')
    eq(P.getData(99, 'meta'), nil, 'getData without a session is nil')

    -- 5. only the replicated top-level keys write to the bag
    P.setData(1, 'money', { cash = 10, bank = 20 })
    eq(env.Player(1).state.cash, 10, 'setData on money re-replicates cash')
    eq(env.Player(1).state.bank, 20, '... and bank')
    P.setData(1, 'name', 'Ada L')
    eq(env.Player(1).state.name, 'Ada L', 'setData on name re-replicates')
    eq(P.getName(1), 'Ada L', 'the session name follows data.name')
    local beforeMeta = env.Player(1).state.meta
    P.setData(1, 'meta.secret', 'hidden')
    eq(env.Player(1).state.meta, beforeMeta, 'an unreplicated key never reaches the bag')

    -- 6. playerDropped saves and clears
    stubs.clear()
    stubs.coords[stubs.peds[1]] = vector3(1.0, 2.0, 3.0)
    stubs.headings[stubs.peds[1]] = 45.0
    local droppedHook = {}
    Core.on('playerDropped', function(src, charId)
        droppedHook[#droppedHook + 1] = { src = src, charId = charId, loaded = P.isLoaded(src) }
    end)
    stubs.dropPlayer(env, 1)
    eq(P.isLoaded(1), false, 'the session is gone after playerDropped')
    eq(P.count(), 0, 'no sessions are left')
    eq(#droppedHook, 1, 'the playerDropped hook fired once')
    eq(droppedHook[1].charId, info.charId, 'the hook carries the charId')
    eq(droppedHook[1].loaded, true, 'the hook runs before the session is removed')
    local saved = DB.get('characters', info.charId)
    eq(saved.money.cash, 10, 'the character document was saved on drop')
    eq(saved.name, 'Ada L', 'the renamed character was saved')
    eq(saved.meta.secret, 'hidden', 'unreplicated data was saved too')
    eq(saved.position.x, 1.0, 'the last ped position was written to the document')
    eq(saved.position.heading, 45.0, '... heading included')
    eq(P.getSrcByCharId(info.charId), nil, 'byCharId was cleared')
    eq(P.save(1), false, 'saving a gone session is false')

    -- 7. an unclean reconnect takes the character over from the ghost session
    stubs.connectPlayer(env, 2, { license = 'license:ghost', name = 'Bo' })
    local ghostInfo = P.getInfo(2)
    eq(Core.Money.add(2, 'cash', 777, 'test'), true, 'the ghost earns money it never saved')
    eq(P.getData(2, 'money.cash'), 5777, 'the ghost session holds the newer balance')
    eq(DB.get('characters', ghostInfo.charId).money.cash, 5000, 'the document is still stale')
    stubs.connectPlayer(env, 3, { license = 'license:ghost', name = 'Bo' })
    eq(P.isLoaded(2), false, 'the ghost session was evicted')
    eq(P.isLoaded(3), true, 'the new session is live')
    eq(P.getInfo(3).charId, ghostInfo.charId, 'the character moved to the new src')
    eq(P.getSrcByCharId(ghostInfo.charId), 3, 'byCharId points at the new src')
    eq(DB.count('characters'), 2, 'no second character was created for the same account')
    eq(DB.get('characters', ghostInfo.charId).money.cash, 5777, 'the ghost was saved before eviction')
    eq(P.getData(3, 'money.cash'), 5777, 'the unsaved money change survived the handover')
    eq(env.Player(3).state.cash, 5777, 'the new session replicated the balance')
    check(printed('was still bound to') ~= nil, 'the takeover is logged')
    stubs.dropPlayer(env, 2)
    eq(P.getSrcByCharId(ghostInfo.charId), 3, "the ghost's late playerDropped does not unbind the live src")
    eq(P.isLoaded(3), true, 'and the live session survives it')

    -- 8. kick and ban validation
    stubs.dropped = {}
    eq(P.kick(44, 'nope'), false, 'kick refuses an unconnected src')
    eq(P.kick('3', 'nope'), false, 'kick refuses a non-number src')
    eq(#stubs.dropped, 0, 'no DropPlayer was issued')
    eq(P.kick(3, 'be nice'), true, 'kick drops a connected player')
    eq(stubs.dropped[1].src, 3, 'DropPlayer got the src')
    eq(stubs.dropped[1].reason, 'be nice', 'DropPlayer got the reason')
    eq(P.kick(3), true, 'kick works without a reason')
    eq(stubs.dropped[2].reason, 'Kicked', 'the default kick reason')

    stubs.dropped = {}
    stubs.osTime = 1000000
    eq(P.ban(44, 'x'), false, 'ban refuses an unconnected src')
    eq(P.ban(3, 'cheating', 3600, 'admin'), true, 'ban writes the record and drops')
    local ban = DB.findOne('bans', { license = 'license:ghost' })
    check(ban ~= nil, 'the ban document was created')
    eq(ban and ban.reason, 'cheating', 'the ban carries the reason')
    eq(ban and ban.by, 'admin', 'the ban carries who issued it')
    eq(ban and ban['until'], 1000000 + 3600, 'a timed ban expires at now + seconds')
    eq(DB.get('accounts', P.getInfo(3).accountId).banned, true, 'the account is flagged banned')
    check((stubs.dropped[1].reason or ''):find('banned until') ~= nil, 'the drop message names the expiry')
    stubs.connectPlayer(env, 5, { license = 'license:perm', name = 'Cy' })
    eq(P.ban(5, 'forever'), true, 'a ban without seconds is permanent')
    eq(DB.findOne('bans', { license = 'license:perm' })['until'], 0, 'a permanent ban has until = 0')
    check((stubs.dropped[2].reason or ''):find('permanently banned') ~= nil, 'the drop message says permanent')
    eq(P.ban(5, 'again', -5), true, 'a negative duration falls back to permanent')
    stubs.osTime = nil

    -- 9. the rest of the per-session API
    eq(P.getBucket(3), 0, 'a session starts in bucket 0')
    eq(P.setBucket(3, 7), true, 'setBucket')
    eq(P.getBucket(3), 7, 'getBucket reads it back')
    eq(P.setBucket(3, -1), false, 'a negative bucket is refused')
    eq(P.setBucket(3, 1.5), false, 'a fractional bucket is refused')
    eq(P.setBucket(99, 1), false, 'setBucket without a session is refused')
    stubs.clear()
    eq(P.setCoords(3, vector3(5.0, 6.0, 7.0), 12.0), true, 'setCoords accepts a vector3')
    eq(lastSent('core:client:teleport').target, 3, 'the teleport is sent to that client')
    eq(P.getData(3, 'position').x, 5.0, 'the stored position followed')
    eq(P.setCoords(3, { x = 1.0, y = 2.0, z = 3.0 }), true, 'setCoords accepts a plain table')
    eq(P.setCoords(3, 'nope'), false, 'setCoords refuses anything else')
    eq(P.setModel(3, 'a_m_y_beach_01'), true, 'setModel')
    eq(P.getData(3, 'model'), 'a_m_y_beach_01', 'the model was stored')
    eq(P.setModel(3, 42), false, 'setModel refuses a non-string')
    -- kick/ban only call DropPlayer; the session lives until the engine fires playerDropped
    eq(P.count(), 2, 'the kicked and banned sessions are still loaded')
    eq(P.saveAll(), 2, 'saveAll saves every live session')
    local seen = {}
    P.forEach(function(_, playerInfo) seen[#seen + 1] = playerInfo.charId end)
    eq(#seen, 2, 'forEach visits every session')
    eq(#P.getPlayers(), 2, 'getPlayers lists the loaded sessions')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

--- Core.Money (DESIGN §4.3): add/remove/set, the transfer rollback and the moneyChanged hook.
local function suiteMoney()
    suite('money')
    stubs.resetServer()
    local env, Core = newServer()
    local M = Core.Money
    local MAX <const> = Core.Config.Money.MaxAmount
    stubs.connectPlayer(env, 1, { license = 'license:m1', name = 'Rich' })
    stubs.connectPlayer(env, 2, { license = 'license:m2', name = 'Poor' })

    local hooks = {}
    Core.on('moneyChanged', function(src, account, amount, delta, reason)
        hooks[#hooks + 1] = { src = src, account = account, amount = amount, delta = delta, reason = reason }
    end)

    -- reads
    eq(M.get(1, 'cash'), 5000, 'a new character starts with the configured cash')
    eq(M.get(1, 'bank'), 25000, '... and bank')
    eq(M.get(1, 'crypto'), 0, 'an unconfigured account reads 0')
    eq(M.get(99, 'cash'), 0, 'a src without a session reads 0')
    eq(M.canAfford(1, 'cash', 5000), true, 'canAfford at exactly the balance')
    eq(M.canAfford(1, 'cash', 5001), false, 'canAfford above the balance')
    eq(M.canAfford(1, 'cash', -1), false, 'canAfford refuses a negative amount')
    eq(M.canAfford(1, 'crypto', 0), false, 'canAfford refuses an unconfigured account')

    -- add
    eq(M.add(1, 'cash', 250, 'wage'), true, 'add')
    eq(M.get(1, 'cash'), 5250, 'the balance went up')
    eq(#hooks, 1, 'the moneyChanged hook fired once')
    eq(hooks[1].src, 1, 'the hook carries the src')
    eq(hooks[1].account, 'cash', 'the hook carries the account')
    eq(hooks[1].amount, 5250, 'the hook carries the new balance')
    eq(hooks[1].delta, 250, 'the hook carries the delta')
    eq(hooks[1].reason, 'wage', 'the hook carries the reason')
    eq(env.Player(1).state.cash, 5250, 'the cash state-bag key followed the change')
    check(printed('money src=1') ~= nil, 'the change is audited')
    eq(M.add(1, 'cash', 5), true, 'add without a reason works')
    eq(hooks[#hooks].reason, 'unknown', "an absent reason is audited as 'unknown'")

    -- add: rejected input never changes a balance
    local before = M.get(1, 'cash')
    eq(M.add(1, 'cash', 0), false, 'add of 0 is refused')
    eq(M.add(1, 'cash', -5), false, 'add of a negative amount is refused')
    eq(M.add(1, 'cash', 1.5), false, 'add of a float is refused')
    eq(M.add(1, 'cash', 0 / 0), false, 'add of NaN is refused')
    eq(M.add(1, 'cash', '100'), false, 'add of a numeric string is refused')
    eq(M.add(1, 'crypto', 5), false, 'add to an unconfigured account is refused')
    eq(M.add(1, 'cash', MAX + 1), false, 'add above MaxAmount is refused outright')
    eq(M.add(1, 'cash', MAX), false, 'add that would overflow MaxAmount is refused')
    eq(M.add(99, 'cash', 5), false, 'add without a session is refused')
    eq(M.get(1, 'cash'), before, 'no refused add moved the balance')

    -- remove
    eq(M.remove(1, 'cash', 255, 'fee'), true, 'remove')
    eq(M.get(1, 'cash'), 5000, 'the balance went down')
    eq(hooks[#hooks].delta, -255, 'the hook carries a negative delta')
    eq(M.remove(1, 'cash', 5001), false, 'remove more than the balance is refused')
    eq(M.get(1, 'cash'), 5000, 'an insufficient remove is never partial')
    eq(M.remove(1, 'cash', 0), false, 'remove of 0 is refused')
    eq(M.remove(99, 'cash', 1), false, 'remove without a session is refused')
    eq(M.remove(1, 'cash', 5000, 'all of it'), true, 'remove of the exact balance works')
    eq(M.get(1, 'cash'), 0, 'the account is empty')
    eq(env.Player(1).state.cash, 0, 'the empty balance replicated')

    -- set
    eq(M.set(1, 'cash', 1234), true, 'set')
    eq(M.get(1, 'cash'), 1234, 'set wrote the balance')
    eq(hooks[#hooks].delta, 1234, 'set reports the delta from the old balance')
    eq(hooks[#hooks].reason, 'set', "set audits as 'set' by default")
    eq(M.set(1, 'cash', 0), true, 'set to zero is allowed (unlike add/remove)')
    eq(M.set(1, 'cash', -1), false, 'set refuses a negative amount')
    eq(M.set(1, 'cash', MAX + 1), false, 'set refuses more than MaxAmount')
    eq(M.set(1, 'cash', 1.5), false, 'set refuses a float')
    eq(M.set(99, 'cash', 1), false, 'set without a session is refused')

    -- transfer
    M.set(1, 'cash', 5000, 'reset')
    M.set(2, 'cash', 5000, 'reset')
    eq(M.transfer(1, 2, 'cash', 1000, 'gift'), true, 'transfer moves money')
    eq(M.get(1, 'cash'), 4000, 'the sender paid')
    eq(M.get(2, 'cash'), 6000, 'the receiver got it')
    eq(M.transfer(1, 1, 'cash', 10), false, 'transfer to self is refused')
    eq(M.transfer(1, 99, 'cash', 10), false, 'transfer to a src without a session is refused')
    eq(M.transfer(99, 1, 'cash', 10), false, 'transfer from a src without a session is refused')
    eq(M.transfer(1, 2, 'cash', 0), false, 'transfer of 0 is refused')
    eq(M.transfer(1, 2, 'crypto', 10), false, 'transfer on an unconfigured account is refused')
    eq(M.transfer(1, 2, 'cash', 99999), false, 'transfer beyond the balance is refused')
    eq(M.get(1, 'cash'), 4000, 'a refused transfer moved nothing')
    eq(M.get(2, 'cash'), 6000, '... on either side')

    -- the receiver cannot take it: the sender is rolled back
    M.set(2, 'cash', MAX, 'fill')
    local hooksBefore = #hooks
    eq(M.transfer(1, 2, 'cash', 100), false, 'a transfer the receiver cannot take fails')
    eq(M.get(1, 'cash'), 4000, 'the sender was rolled back')
    eq(M.get(2, 'cash'), MAX, 'the receiver is unchanged')
    eq(env.Player(1).state.cash, 4000, 'the rolled-back balance replicated')
    eq(#hooks - hooksBefore, 2, 'the failed transfer emitted the removal and its rollback')
    eq(hooks[#hooks].reason, 'transfer rollback', 'the rollback is audited as such')
end

--- Core.Factions (DESIGN §4.5, §8): create, the membership chain, permission denials,
--- the invite squatting rule and the bank rollback on a failing document write.
local function suiteFactions()
    suite('factions')
    stubs.resetServer()
    local env, Core = newServer()
    local F, Money, Player = Core.Factions, Core.Money, Core.Player
    local cfg = Core.Config.Factions
    stubs.connectPlayer(env, 1, { license = 'license:f1', name = 'Boss' })
    stubs.connectPlayer(env, 2, { license = 'license:f2', name = 'Rook' })
    stubs.connectPlayer(env, 3, { license = 'license:f3', name = 'Rival' })
    local c1, c2 = Player.getInfo(1).charId, Player.getInfo(2).charId

    local updated, changed = {}, {}
    Core.on('factionUpdated', function(id) updated[#updated + 1] = id end)
    Core.on('factionChanged', function(src, summary) changed[#changed + 1] = { src = src, summary = summary } end)

    -- create charges CreateCost from CostAccount
    eq(Money.get(1, cfg.CostAccount), 25000, 'the founder can afford the fee')
    local id, createErr = F.create(1, 'Los Santos Cabs', 'lsc')
    check(type(id) == 'string', 'create returns the faction id', tostring(createErr))
    eq(Money.get(1, cfg.CostAccount), 25000 - cfg.CreateCost, 'CreateCost was charged')
    local doc = F.get(id)
    eq(doc.name, 'Los Santos Cabs', 'the document carries the name')
    eq(doc.tag, 'LSC', 'the tag is upper-cased')
    eq(doc.color, cfg.DefaultColor, 'the default colour is applied')
    eq(doc.ownerCharId, c1, 'the creator owns it')
    eq(doc.members[c1].rank, #cfg.DefaultRanks, 'the creator gets the highest default rank')
    eq(doc.bank, 0, 'the bank starts empty')
    eq(env.GlobalState['faction:' .. id].memberCount, 1, 'the faction was published to GlobalState')
    eq(env.GlobalState['faction:' .. id].tag, 'LSC', 'the GlobalState entry carries the tag')
    eq(env.Player(1).state.faction.tag, 'LSC', 'the faction state-bag key was written')
    eq(env.Player(1).state.faction.rankName, 'Leader', 'the state bag carries the rank name')
    eq(env.Player(1).state.faction.perms, nil, 'the state summary carries only the six public fields')
    eq(Player.getData(1, 'faction').id, id, 'the character document remembers the faction')
    eq(updated[#updated], id, 'the factionUpdated hook fired')
    eq(changed[#changed].summary.isOwner, true, 'the factionChanged hook carries the full summary')
    eq(F.getPlayerFaction(1).perms.manage, true, 'the owner has every permission')

    -- create refusals
    eq(errOf(F.create(1, 'Other Co', 'OTH')), 'already_in_faction', 'a member cannot found a second one')
    eq(errOf(F.create(2, 'los santos cabs', 'XX2')), 'name_taken', 'names are unique, case-insensitively')
    eq(errOf(F.create(2, 'Fresh Start', 'lsc')), 'tag_taken', 'tags are unique, case-insensitively')
    eq(errOf(F.create(2, 'ab', 'FRS')), 'invalid_name', 'the name minimum is enforced')
    eq(errOf(F.create(2, 'Fresh Start', 'f')), 'invalid_tag', 'the tag minimum is enforced')
    eq(errOf(F.create(2, 'Fresh Start', 'to long')), 'invalid_tag', 'the tag pattern is enforced')
    eq(errOf(F.create(2, 'Fresh Start', 'FRS', { color = 'blue' })), 'invalid_color', 'the colour must be #RRGGBB')
    eq(errOf(F.create(0, 'Fresh Start', 'FRS')), 'arg 1: expected src 1..4096, got 0', 'src 0 cannot found one')
    eq(errOf(F.create(99, 'Fresh Start', 'FRS')), 'not_loaded', 'a src without a session cannot found one')
    Money.set(2, cfg.CostAccount, cfg.CreateCost - 1, 'poor')
    eq(errOf(F.create(2, 'Fresh Start', 'FRS')), 'insufficient_funds', 'the fee must be affordable')
    eq(Core.DB.findOne('factions', { tag = 'FRS' }), nil, 'no document is left behind')
    eq(Core.DB.count('factions'), 1, 'exactly one faction exists')

    -- invite -> accept -> rank -> kick
    eq(errOf(F.invite(2, 3)), 'no_faction', 'a player in no faction cannot invite')
    eq(errOf(F.invite(1, 1)), 'self_target', 'nobody invites themselves')
    eq(errOf(F.invite(1, 99)), 'target_not_loaded', 'the target needs a session')
    stubs.clear()
    eq(F.invite(1, 2), true, 'the owner invites')
    check((lastSent('core:client:notify') or {}).target ~= nil, 'the invite is notified')
    eq(errOf(F.acceptInvite(3)), 'no_invite', 'accepting without an invite is refused')
    eq(F.acceptInvite(2), true, 'the invite is accepted')
    eq(F.get(id).members[c2].rank, 1, 'a new member joins at rank 1')
    eq(F.get(id).members[c2].name, 'Rook', 'the member row carries the display name')
    eq(env.Player(2).state.faction.rankName, 'Member', 'the member state bag carries the rank name')
    eq(env.GlobalState['faction:' .. id].memberCount, 2, 'the member count was republished')
    eq(#F.getMembers(id), 2, 'getMembers lists both')
    eq(F.getMembers(id)[1].charId, c1, 'getMembers sorts by rank, highest first')
    eq(F.getMembers(id)[1].online, 1, 'getMembers resolves the online src')
    eq(errOf(F.acceptInvite(2)), 'no_invite', 'the invite was consumed')

    -- permission denials for a rank-1 member
    eq(errOf(F.invite(2, 3)), 'no_permission', 'rank 1 may not invite')
    eq(errOf(F.kick(2, c1)), 'no_permission', 'rank 1 may not kick')
    eq(errOf(F.setRank(2, c1, 1)), 'no_permission', 'rank 1 may not manage ranks')
    eq(errOf(F.withdraw(2, 1)), 'no_permission', 'rank 1 may not withdraw')
    eq(errOf(F.update(2, { name = 'Renamed' })), 'no_permission', 'rank 1 may not rename')
    eq(errOf(F.disband(2)), 'not_owner', 'only the owner disbands')
    eq(errOf(F.leave(1)), 'owner_cannot_leave', 'the owner may not simply leave')
    eq(F.hasPerm(2, 'invite'), false, 'hasPerm agrees')
    eq(F.hasPerm(1, 'invite'), true, 'the owner has every perm')

    -- ranks
    eq(F.setRank(1, c2, 2), true, 'the owner promotes a member')
    eq(F.get(id).members[c2].rank, 2, 'the rank was written')
    eq(env.Player(2).state.faction.rankName, 'Officer', 'the promoted member re-replicated')
    eq(F.hasPerm(2, 'invite'), true, 'rank 2 may invite now')
    eq(F.hasPerm(2, 'bank'), false, 'rank 2 still may not touch the bank')
    eq(errOf(F.setRank(1, c1, 1)), 'self_target', 'the owner cannot demote himself')
    eq(errOf(F.setRank(1, 'no-such-char', 2)), 'target_not_member', 'an unknown member is refused')
    eq(errOf(F.setRank(1, c2, 99)), 'arg 3: expected integer 1..8, got 99', 'the rank is range-checked')
    eq(errOf(F.setRank(1, c2, 3)), nil, 'the owner may promote to his own rank')
    eq(F.setRank(1, c2, 2), true, 'and demote again')

    -- kick
    eq(errOf(F.kick(1, c1)), 'self_target', 'the owner cannot kick himself')
    eq(F.kick(1, c2), true, 'the owner kicks the member')
    eq(F.get(id).members[c2], nil, 'the member row is gone')
    eq(env.Player(2).state.faction, false, 'the kicked member replicates false, never nil')
    eq(Player.getData(2, 'faction'), false, 'the character document was cleared')
    eq(F.getPlayerFaction(2), nil, 'getPlayerFaction is nil again')
    eq(env.GlobalState['faction:' .. id].memberCount, 1, 'the member count shrank')
    eq(errOf(F.kick(1, c2)), 'target_not_member', 'kicking a non-member is refused')

    -- invite squatting: another faction may not overwrite a live invite
    local rivalId = F.create(3, 'Vagos', 'VGS')
    check(type(rivalId) == 'string', 'the rival faction was founded')
    eq(F.invite(1, 2), true, 'LSC invites the free agent')
    eq(errOf(F.invite(3, 2)), 'invite_pending', 'a second faction cannot squat on a pending invite')
    eq(F.invite(1, 2), true, 'the same faction may refresh its own invite')
    stubs.tick(cfg.InviteTimeoutMs + 1000)
    eq(F.invite(3, 2), true, 'once the invite expired another faction may invite')
    eq(F.acceptInvite(2), true, 'the free agent joins the rival')
    eq(F.getPlayerFaction(2).tag, 'VGS', 'and is now a Vago')
    eq(errOf(F.invite(1, 2)), 'target_in_faction', 'a member of another faction cannot be invited')
    eq(F.leave(2), true, 'a plain member may leave')
    eq(F.getPlayerFaction(2), nil, 'and is free again')

    -- an expired invite is refused on accept as well
    eq(F.invite(1, 2), true, 'invited once more')
    stubs.tick(cfg.InviteTimeoutMs + 1)
    eq(errOf(F.acceptInvite(2)), 'invite_expired', 'an expired invite cannot be accepted')
    eq(F.invite(1, 2), true, 'invited again')
    eq(F.declineInvite(2), true, 'decline drops the invite')
    eq(F.declineInvite(2), false, 'a second decline is false')
    eq(errOf(F.acceptInvite(2)), 'no_invite', 'the declined invite is gone')

    -- bank: deposit, withdraw and the rollback of a failing document write
    Money.set(1, cfg.CostAccount, 5000, 'topup')
    eq(F.deposit(1, 1000), true, 'a member deposits')
    eq(F.getBank(id), 1000, 'the faction bank grew')
    eq(Money.get(1, cfg.CostAccount), 4000, 'the depositor paid')
    eq(errOf(F.deposit(1, 999999)), 'insufficient_funds', 'you cannot deposit what you lack')
    eq(errOf(F.deposit(1, 0)), 'arg 2: expected integer 1..999999999, got 0', 'the amount is range-checked')
    eq(F.withdraw(1, 400), true, 'the owner withdraws')
    eq(F.getBank(id), 600, 'the faction bank shrank')
    eq(Money.get(1, cfg.CostAccount), 4400, 'the money arrived')
    eq(errOf(F.withdraw(1, 5000)), 'insufficient_funds', 'you cannot withdraw more than the bank holds')

    local realSet = Core.DB.set
    Core.DB.set = function(collection, ...)
        if collection == 'factions' then return false end
        return realSet(collection, ...)
    end
    eq(errOf(F.deposit(1, 100)), 'save_failed', 'a failing document write refuses the deposit')
    eq(Money.get(1, cfg.CostAccount), 4400, 'and rolls the money back')
    eq(errOf(F.withdraw(1, 100)), 'save_failed', 'a failing document write refuses the withdrawal')
    eq(Money.get(1, cfg.CostAccount), 4400, 'and takes the payout back')
    Core.DB.set = realSet
    eq(F.getBank(id), 600, 'the faction bank is untouched by either')
    check(printed('faction_deposit_rollback') ~= nil, 'the rollback is audited')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

--- Core.Vehicles (DESIGN §4.6, §5, §8): spawn, plates, keys, the lock net event and records.
local function suiteVehicles()
    suite('vehicles')
    stubs.resetServer()
    local env, Core = newServer()
    local V = Core.Vehicles
    stubs.connectPlayer(env, 1, { license = 'license:v1', name = 'Driver', coords = vector3(100.0, 100.0, 20.0) })
    local charId = Core.Player.getInfo(1).charId
    local ped = stubs.peds[1]

    local spawnedHook, deletedHook = {}, {}
    Core.on('vehicleSpawned', function(netId, info) spawnedHook[#spawnedHook + 1] = { netId = netId, info = info } end)
    Core.on('vehicleDeleted', function(netId) deletedHook[#deletedHook + 1] = netId end)

    -- spawn
    local netId, spawnErr = V.spawn({ model = 'adder', coords = vector3(100.0, 100.0, 20.0),
        heading = 90.0, ownerSrc = 1, locked = true, plate = 'LSTEST1', bucket = 3 })
    check(math.type(netId) == 'integer', 'spawn returns a netId', tostring(spawnErr))
    local entity = V.getEntity(netId)
    check(entity ~= 0, 'the entity handle is tracked')
    eq(V.exists(netId), true, 'exists')
    local record = stubs.entities[entity]
    eq(record.vehType, 'automobile', 'the default CreateVehicleServerSetter type')
    eq(record.model, env.GetHashKey('adder'), 'the model string was hashed')
    eq(record.plate, 'LSTEST1', 'SetVehicleNumberPlateText got the plate')
    eq(record.lockState, 2, 'a locked vehicle gets doorlock state 2')
    eq(record.orphanMode, 2, 'an owned vehicle is kept when orphaned')
    eq(record.bucket, 3, 'the routing bucket was applied')
    local state = stubs.entityState(env, entity)
    eq(state.coreVeh, true, 'the coreVeh state key')
    eq(state.locked, true, 'the locked state key')
    eq(state.owner, charId, 'the owner state key resolved ownerSrc to a charId')
    eq(state.plate, 'LSTEST1', 'the plate state key')
    eq(state.keys[charId], true, 'the owner holds a key')
    eq(#spawnedHook, 1, 'the vehicleSpawned hook fired')
    eq(spawnedHook[1].info.plate, 'LSTEST1', 'the hook carries the public info')
    eq(spawnedHook[1].info.entity, nil, 'the public info never leaks the entity handle')
    local info = V.getInfo(netId)
    eq(info.ownerCharId, charId, 'getInfo carries the owner')
    eq(info.spawnedBy, 'core', 'the calling resource is recorded')
    eq(info.locked, true, 'getInfo carries the lock state')
    info.keys[charId] = nil
    eq(V.hasKeys(1, netId), true, 'getInfo hands out a copy of the key table')

    -- spawn refusals
    eq(errOf(V.spawn('nope')), 'bad_opts', 'spawn refuses a non-table')
    eq(errOf(V.spawn({ model = 'adder' })), 'field "coords": expected vector3, got nil', 'coords are required')
    eq(errOf(V.spawn({ model = {}, coords = vector3(0, 0, 0) })), 'bad_model', 'the model must be a string or a hash')
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(0, 0, 0), plate = 'LSTEST1' })), 'plate_taken',
        'a plate already in use is refused')
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(0, 0, 0), plate = 'BAD!' })), 'bad_plate',
        'a plate with punctuation is refused')
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(0, 0, 0), plate = 'TOOLONGPLATE' })),
        'field "plate": expected string (len <= 8), got "TOOLONGPLATE"', 'an over-long plate is refused')
    stubs.spawnFails = true
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(0, 0, 0) })), 'create_failed',
        'a refusal from CreateVehicleServerSetter is passed on')
    stubs.spawnFails = false

    -- generated plates stay unique
    local netId2 = V.spawn({ model = 'adder', coords = vector3(0.0, 0.0, 0.0) })
    local plate2 = V.getInfo(netId2).plate
    check(plate2 ~= 'LSTEST1', 'a generated plate never collides')
    eq(plate2:sub(1, 2), Core.Config.Vehicles.PlatePrefix, 'the generated plate carries the configured prefix')
    check(#plate2 <= 8, 'the generated plate fits the 8 character limit')
    eq(stubs.entityState(env, V.getEntity(netId2)).owner, false, 'an unowned vehicle replicates owner = false')

    -- keys
    eq(V.hasKeys(1, netId), true, 'the owner holds the keys')
    eq(V.hasKeys(2, netId), false, 'a src without a session holds nothing')
    eq(V.hasKeys(1, netId2), false, 'no keys for an unowned vehicle')
    eq(V.giveKeys(netId2, charId), true, 'giveKeys')
    eq(V.hasKeys(1, netId2), true, 'the key grants access')
    eq(stubs.entityState(env, V.getEntity(netId2)).keys[charId], true, 'the keys state bag followed')
    eq(V.removeKeys(netId2, charId), true, 'removeKeys')
    eq(V.hasKeys(1, netId2), false, 'the key is gone')
    eq(V.giveKeys(netId2, 42), false, 'giveKeys validates the charId')
    eq(V.giveKeys(netId2, 'bad id'), false, 'giveKeys refuses a malformed charId')
    eq(V.giveKeys(999999, charId), false, 'giveKeys on an untracked netId')
    eq(V.setOwner(netId2, charId), true, 'setOwner')
    eq(V.getOwner(netId2), charId, 'getOwner')
    eq(V.hasKeys(1, netId2), true, 'the new owner holds the keys')
    eq(#V.getPlayerVehicles(1), 2, 'getPlayerVehicles lists both')
    eq(V.setOwner(netId2, nil), true, 'setOwner accepts nil to clear the owner')
    eq(V.getOwner(netId2), nil, 'the vehicle is unowned again')
    eq(stubs.entityState(env, V.getEntity(netId2)).owner, false, 'the owner state key is false again')
    -- keys follow ownership: setOwner(netId, nil) drops the owner AND the key that came with ownership
    eq(V.hasKeys(1, netId2), false, 'clearing the owner revokes the key that came with it')
    eq(V.removeKeys(netId2, charId), true, 'the key has to be taken back explicitly')
    eq(V.hasKeys(1, netId2), false, 'now the vehicle is truly out of reach')

    -- entityOf: untracked ids never resolve
    eq(V.getEntity(netId + 5000), 0, 'an untracked netId resolves to entity 0')
    eq(V.getEntity('nope'), 0, 'a non-integer netId resolves to 0')
    eq(V.getEntity(1.5), 0, 'a fractional netId resolves to 0')
    eq(V.exists(netId + 5000), false, 'exists is false for an untracked netId')
    eq(V.getInfo(netId + 5000), nil, 'getInfo of an untracked netId is nil')
    local foreign = stubs.newEntity(2, { model = 1 })
    eq(V.getEntity(stubs.entities[foreign].netId), 0, "another resource's vehicle is not reachable")
    eq(V.setLocked(stubs.entities[foreign].netId, true), false, 'and cannot be locked through the API')

    -- core:server:vehicleLock through the Core.Net wrapper (DESIGN §5)
    stubs.clear()
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId)
    eq(V.isLocked(netId), false, 'the lock toggled off')
    eq(stubs.entities[entity].lockState, 1, 'SetVehicleDoorsLocked got state 1')
    eq(stubs.entityState(env, entity).locked, false, 'the locked state key followed')
    eq((lastSent('core:client:notify') or {}).target, 1, 'only the caller is notified')
    eq(lastSent('core:client:notify').args[1].message, Core.Config.Texts.unlocked, 'the unlock message')
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId)
    eq(V.isLocked(netId), false, 'the 500 ms cooldown blocks an immediate repeat')

    stubs.tick(600)
    stubs.coords[ped] = vector3(1000.0, 1000.0, 20.0)
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId)
    eq(V.isLocked(netId), false, 'a player beyond LockDistance is refused')
    stubs.tick(600)
    stubs.coords[ped] = vector3(100.0, 100.0, 20.0)
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId)
    eq(V.isLocked(netId), true, 'back in range the lock toggles again')

    stubs.tick(600)
    stubs.clear()
    stubs.coords[ped] = vector3(1.0, 1.0, 0.0)               -- next to the unowned vehicle
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId2)
    eq(V.isLocked(netId2), false, 'a vehicle the player has no keys for stays unlocked')
    eq(lastSent('core:client:notify').args[1].message, Core.Config.Texts.no_keys, 'the refusal is notified')
    stubs.tick(600)
    stubs.clear()
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId + 5000)
    eq(lastSent('core:client:notify'), nil, 'an untracked netId is dropped silently')
    stubs.tick(600)
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, 'nope')
    eq(lastSent('core:client:notify'), nil, 'a payload that fails the schema is dropped')
    stubs.coords[ped] = vector3(100.0, 100.0, 20.0)

    -- records: persist, store, spawnRecord and the double-spawn refusal
    local vehId = V.persist(netId)
    check(type(vehId) == 'string', 'persist creates the vehicles record')
    eq(stubs.entityState(env, entity).vehId, vehId, 'the vehId state key was written')
    eq(V.persist(netId), vehId, 'persist is idempotent')
    eq(V.persist(netId + 5000), nil, 'persist of an untracked netId is nil')
    eq(V.getRecord(vehId).plate, 'LSTEST1', 'the record carries the plate')
    eq(V.getRecord(vehId).stored, false, 'a freshly persisted vehicle is not stored')
    eq(V.getRecord(vehId).meta.vehType, 'automobile', 'the record remembers the vehicle type')
    eq(#V.getRecords(charId), 1, 'getRecords finds the owner records')
    eq(#V.getRecords('no-such-char'), 0, 'getRecords of a stranger is empty')
    eq(errOf(V.spawnRecord(vehId, vector3(5.0, 5.0, 5.0))), 'already_spawned',
        'a record already in the world cannot be spawned again')
    eq(errOf(V.spawnRecord('nope', vector3(0, 0, 0))), 'no_record', 'an unknown record is refused')

    eq(V.store(netId), true, 'store writes the record and removes the entity')
    eq(V.exists(netId), false, 'the vehicle left the world')
    eq(V.getRecord(vehId).stored, true, 'the record is marked stored')
    eq(V.getRecord(vehId).position.x, 100.0, 'the last position was written')
    eq(#deletedHook, 1, 'store emitted vehicleDeleted')

    local respawned = V.spawnRecord(vehId, vector3(5.0, 5.0, 5.0), 10.0, 1)
    check(math.type(respawned) == 'integer', 'spawnRecord brings the vehicle back')
    eq(V.getInfo(respawned).plate, 'LSTEST1', 'the plate was freed and reused')
    eq(V.getInfo(respawned).ownerCharId, charId, 'the owner was restored from the record')
    eq(V.getInfo(respawned).vehId, vehId, 'the live vehicle points back at its record')
    eq(V.getRecord(vehId).stored, false, 'the record is no longer stored')
    eq(errOf(V.spawnRecord(vehId, vector3(6.0, 6.0, 6.0))), 'already_spawned',
        'a second spawn of the same record is refused')

    -- props and delete
    eq(V.saveProps(respawned, { modEngine = 3, colour = 'red', extras = { 1, 2 }, on = true }), true,
        'saveProps accepts a well-formed props table')
    eq(V.getRecord(vehId).props.modEngine, 3, 'the props reached the record')
    eq(V.saveProps(respawned, { [1] = 'no numeric keys' }), false, 'a numeric prop key is refused')
    eq(V.saveProps(respawned, { bad = { 'not a number' } }), false, 'a non-numeric array value is refused')
    eq(V.saveProps(respawned, { bad = print }), false, 'a function value is refused')
    eq(V.saveProps(respawned, 'nope'), false, 'a non-table is refused')
    eq(V.saveProps(netId + 5000, {}), false, 'saveProps on an untracked netId is refused')
    eq(V.getRecord(vehId).props.modEngine, 3, 'no refused props reached the record')

    eq(#V.list(), 2, 'list counts the live vehicles')
    eq(V.delete(respawned), true, 'delete removes a tracked vehicle')
    eq(V.getInfo(respawned), nil, 'the vehicle is untracked')
    eq(V.exists(respawned), false, 'and gone from the world')
    eq(V.delete(respawned), false, 'a second delete is false')
    eq(V.deleteRecord(vehId), true, 'deleteRecord removes the document')
    eq(V.getRecord(vehId), nil, 'the record is gone')
    eq(V.deleteRecord('nope'), false, 'deleteRecord of an unknown id is false')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

--- server/api.lua (DESIGN §2.2, §2.3, §14): the `call` export block list and the caller record.
local function suiteApi()
    suite('api')
    stubs.resetServer()
    local env, Core = newServer()
    local call = stubs.exports.core and stubs.exports.core.call
    check(type(call) == 'function', 'server/api.lua registered the call export')

    -- internal namespaces and functions are not reachable through the export
    local blocked = {
        { 'Registry', 'track' }, { 'Registry', 'getOwned' },
        { 'DB', 'setAdapter' }, { 'Player', 'loadSession' }, { 'Player', 'loadAllConnected' },
        { 'Player', 'startAutosave' }, { 'Player', 'stopAutosave' },
    }
    for i = 1, #blocked do
        local namespace, fn = blocked[i][1], blocked[i][2]
        local ok, err = pcall(call, 'plugin', namespace, fn)
        eq(ok, false, ('%s.%s is refused'):format(namespace, fn))
        eq(err, ('core: %s.%s is internal'):format(namespace, fn),
            ('%s.%s reports why'):format(namespace, fn))
    end
    eq(select(2, pcall(call, 'plugin', 'Nope', 'nothing')), 'core: no API Nope.nothing',
        'an unknown namespace errors instead of returning nil')
    -- DESIGN §14 blocks Core.World from the export, but that was written when Core.World meant the
    -- client-side scheduler of §6.3; §17 makes the *server* Core.World (time/weather) plugin-facing,
    -- so the server block list holds Registry only. This pins that reading.
    eq(select(2, pcall(call, 'plugin', 'World', 'setTime', 12, 0)), 'core: no API World.setTime',
        'the server Core.World is not block-listed (DESIGN §17 supersedes the §14 note)')
    eq(select(2, pcall(call, 'plugin', 'DB', 'nothing')), 'core: no API DB.nothing',
        'an unknown function on a real namespace errors too')

    -- the public half still works, and DB.setAdapter is callable from inside core
    stubs.connectPlayer(env, 1, { license = 'license:api', name = 'Api' })
    eq(call('plugin', 'Player', 'isLoaded', 1), true, 'a public API is reachable through the export')
    eq(call('plugin', 'Money', 'get', 1, 'cash'), 5000, 'arguments and return values pass through')
    local a, b = call('plugin', 'Player', 'getCoords', 1)
    check(a ~= nil and b ~= nil, 'multiple return values survive the export')
    check(type(rawget(Core.DB, 'setAdapter')) == 'function', 'DB.setAdapter is still callable in-VM')

    -- an error inside the target surfaces unchanged (no pcall wrapper text)
    Core.Testing = { boom = function() error('inner failure', 0) end }
    eq(select(2, pcall(call, 'plugin', 'Testing', 'boom')), 'inner failure',
        'the target error is re-raised as it was')

    -- the caller is per coroutine and survives a yield inside the dispatched function
    local seen = {}
    Core.Testing.who = function(tag, waitMs)
        seen[#seen + 1] = { tag = tag, at = 'enter', caller = Core.Registry.getCaller() }
        if waitMs then env.Wait(waitMs) end
        seen[#seen + 1] = { tag = tag, at = 'exit', caller = Core.Registry.getCaller() }
    end
    env.CreateThread(function() call('res_a', 'Testing', 'who', 'a', 100) end)
    env.CreateThread(function() call('res_b', 'Testing', 'who', 'b', 10) end)
    eq(#seen, 2, 'both dispatches ran up to their Wait')
    eq(seen[1].caller, 'res_a', 'the first dispatch sees its own caller')
    eq(seen[2].caller, 'res_b', 'the second dispatch sees its own caller')
    stubs.tick(200)
    eq(#seen, 4, 'both dispatches finished')
    eq(seen[3].tag, 'b', 'the shorter Wait resumed first')
    eq(seen[3].caller, 'res_b', 'the second dispatch still knows its caller after the yield')
    eq(seen[4].tag, 'a', 'the longer Wait resumed second')
    eq(seen[4].caller, 'res_a',
        'the first caller was not clobbered by the dispatch that overlapped it')
    eq(Core.Registry.getCaller(), 'core', 'the global caller is back to core once both finished')

    -- the runtime's own view of the invoking resource wins over the declared caller
    stubs.invokingResource = 'real_plugin'
    Core.Testing.owner = function() return Core.Registry.getCaller() end
    eq(call('lying_plugin', 'Testing', 'owner'), 'real_plugin',
        'GetInvokingResource() overrides the caller name the proxy declared')
    stubs.invokingResource = nil
    eq(call(nil, 'Testing', 'owner'), 'core', 'an absent caller name falls back to core')

    -- Core.Registry bookkeeping and the owner sweep (DESIGN §2.3)
    local removed = {}
    eq(Core.Registry.onOwnerStop('widget', function(id, owner)
        removed[#removed + 1] = { id = id, owner = owner }
    end), true, 'a module registers its remover')
    eq(Core.Registry.track('widget', 'w1', 'plugin_a'), true, 'track')
    eq(Core.Registry.track('vehicle', 7, 'plugin_a'), true, 'track accepts a numeric id')
    eq(Core.Registry.track('', 'w2'), false, 'track refuses an empty kind')
    eq(Core.Registry.track('widget', {}), false, 'track refuses a table id')
    eq(Core.Registry.getOwned('plugin_a').widget.w1, true, 'getOwned reports what the plugin holds')
    stubs.triggerOn(env, 'onResourceStop', 0, 'plugin_a')
    eq(#removed, 1, 'the registered remover ran for the stopped resource')
    eq(removed[1].id, 'w1', 'the remover got the id')
    eq(removed[1].owner, 'plugin_a', 'the remover got the owner')
    eq(Core.Registry.getOwned('plugin_a').widget, nil, 'the swept kind is forgotten')
    eq(Core.Registry.getOwned('plugin_a').vehicle[7], true,
        'a kind without a remover keeps its bookkeeping (core vehicles outlive a plugin)')
    eq(Core.Registry.untrack('vehicle', 7), true, 'untrack')
    eq(Core.Registry.untrack('vehicle', 7), false, 'a second untrack is false')
    eq(Core.Registry.getOwned('plugin_a'), nil, 'the owner entry disappears once it holds nothing')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

--- Core.UI shell visibility (DESIGN §31.5): validation and the op that is pushed.
--- server/ui.lua is loaded on top of the standard VM — it is not in SERVER_FILES,
--- so the other suites keep running without a Core.UI namespace.
local function suiteUI()
    suite('ui')
    stubs.resetServer()
    local env, Core = newServer()
    stubs.loadFile(env, 'server/ui.lua')
    local UI = Core.UI
    check(type(UI) == 'table', 'server/ui.lua installed Core.UI')
    stubs.connectPlayer(env, 1, { license = 'license:ui', name = 'Uiv' })

    --- op and positional arguments of the last core:client:ui push.
    local function lastPush()
        local packet = lastSent('core:client:ui')
        if not packet then return nil, nil, nil end
        return packet.args[1], packet.args[2], packet.target
    end

    -- hide: the reason is namespaced for the client, which stores it verbatim
    eq(UI.hide(1), true, 'hide pushes for a connected player')
    local op, args, target = lastPush()
    eq(op, 'hide', 'the op is hide')
    eq(args and args[1], 'server:default', 'an absent reason becomes server:default')
    eq(args and #args, 1, 'hide pushes exactly one argument')
    eq(target, 1, 'the push targets that player only')
    eq(UI.hide(1, 'cutscene'), true, 'hide takes a reason')
    op, args = lastPush()
    eq(args and args[1], 'server:cutscene', 'the reason is prefixed with server:')
    eq(UI.hide(1, 'mission.intro-2'), true, 'dots, dashes and digits are allowed')
    op, args = lastPush()
    eq(args and args[1], 'server:mission.intro-2', 'the reason passes through unchanged')

    -- show: same validation, the op is the only difference
    eq(UI.show(1, 'cutscene'), true, 'show pushes for a connected player')
    op, args = lastPush()
    eq(op, 'show', 'the op is show')
    eq(args and args[1], 'server:cutscene', 'show namespaces the reason the same way')
    eq(UI.show(1), true, 'show defaults to the default reason')
    op, args = lastPush()
    eq(args and args[1], 'server:default', 'show pushes server:default')

    -- src validation (§4): identity is the caller's argument, but it is still looked up
    local before = #stubs.sent
    eq(UI.hide(nil), false, 'hide refuses a missing src')
    eq(UI.hide(0), false, 'hide refuses src 0 (console)')
    eq(UI.hide('1'), false, 'hide refuses a non-integer src')
    eq(UI.hide(99), false, 'hide refuses a src nobody is connected on')
    eq(UI.show(99), false, 'show refuses a src nobody is connected on')
    eq(#stubs.sent, before, 'a bad src sends nothing')
    check(printed('is not a connected player') ~= nil, 'the bad src is logged')

    -- reason validation: pattern and length, both sides
    before = #stubs.sent
    eq(UI.hide(1, 'bad reason'), false, 'a space is not allowed in a reason')
    eq(UI.hide(1, ''), false, 'an empty reason is refused')
    eq(UI.hide(1, 42), false, 'a non-string reason is refused')
    eq(UI.hide(1, ('x'):rep(33)), false, 'a reason longer than 32 characters is refused')
    eq(UI.show(1, 'bad reason'), false, 'show validates its reason too')
    eq(#stubs.sent, before, 'an invalid reason sends nothing')
    check(printed('invalid reason') ~= nil, 'the invalid reason is logged')
    eq(UI.hide(1, ('x'):rep(32)), true, 'exactly 32 characters still passes')

    -- reachable through the export proxy like every other Core.UI function (§2.2)
    local call = stubs.exports.core and stubs.exports.core.call
    eq(call('plugin', 'UI', 'hide', 1, 'plugin_reason'), true, 'UI.hide is reachable from a plugin')
    op, args = lastPush()
    eq(op, 'hide', 'the proxied call pushed the same op')
    eq(args and args[1], 'server:plugin_reason',
        'a server-side plugin call is still a server reason (the client owns the caller namespace)')

    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

--- The Postgres adapter (DESIGN §33): the activation gate, the id -> json map, and how a failing
--- backend degrades a collection instead of letting it read as empty.
local function suiteDbPg()
    suite('db_pg')

    local HANG <const> = {}          -- a stubbed statement that never answers
    local DEADLINE_MS <const> = 10100

    -- db_pg.lua decides everything at load time, so each case gets its own VM: config, convar and
    -- the pgQuery stub have to be in place before the file runs.
    local function newPgServer(opts)
        stubs.resetServer()
        stubs.newWorld()
        stubs.clear()
        clearFailures()
        stubs.tick(1000)
        local env = stubs.newEnv('server', 'core')
        stubs.loadImport(env)
        stubs.loadFile(env, 'shared/config.lua')
        env.Config.DB.Adapter = opts.adapter or 'postgres'
        env.GetConvar = function(name, fallback)
            if name == 'core_pg_url' then return opts.url or '' end
            return fallback
        end
        local own = stubs.exports.core or {}
        stubs.exports.core = own
        own.pgQuery = opts.pgQuery
        stubs.loadFile(env, 'server/api.lua')
        stubs.loadFile(env, 'server/db.lua')
        stubs.loadFile(env, 'server/db_pg.lua')
        return env, env.Core
    end

    --- A pgQuery stub: records every statement and answers per kind — rows on success, a string as
    --- the error, HANG to never call back at all.
    local function recorder(answers)
        local seen = {}
        return seen, function(sql, params, cb)
            local kind = (sql:find('CREATE TABLE', 1, true) and 'schema')
                or (sql:find('SELECT', 1, true) and 'select')
                or (sql:find('INSERT', 1, true) and 'upsert')
                or 'delete'
            seen[#seen + 1] = { kind = kind, sql = sql, params = params }
            local answer = answers[kind]
            if answer == HANG then return end
            if type(answer) == 'string' then return cb(answer) end
            cb(nil, answer or {})
        end
    end

    -- the gate: postgres without a convar stays on KVP
    local _, noUrl = newPgServer({ url = '', pgQuery = function() end })
    check(printed('core_pg_url is empty') ~= nil, 'an empty core_pg_url refuses activation')
    check(printed('postgres adapter active') == nil, 'the adapter never announced itself')
    noUrl.DB.create('widgets', { id = 'k-1' })
    check(stubs.kvp['doc:widgets:k-1'] ~= nil, 'the writes still land in KVP')

    -- the gate: another adapter never touches the bridge
    local seenOff, pgOff = recorder({})
    local _, kvp = newPgServer({ adapter = 'kvp', url = 'postgres://core@127.0.0.1/core', pgQuery = pgOff })
    kvp.DB.create('widgets', { id = 'k-2' })
    eq(#seenOff, 0, 'Adapter = "kvp" never queries postgres')

    -- the happy path
    local seen, pg = recorder({ select = {
        { id = 'p-1', data = '{"name":"ann"}' },
        { id = 'p-2', data = '{"name":"bob","nested":{"n":1}}' },
    } })
    local _, Core = newPgServer({ url = 'postgres://core@127.0.0.1/core', pgQuery = pg })
    check(printed('postgres adapter active (core_documents)') ~= nil, 'the adapter announces itself')
    eq(seen[1] and seen[1].kind, 'schema', 'the start-up thread creates the table')
    eq(Core.DB.count('players'), 2, 'loadAll returns the id -> json map')
    eq(Core.DB.get('players', 'p-1').name, 'ann', 'the documents come back decoded')
    eq(Core.DB.get('players', 'p-2').nested.n, 1, 'nested tables survive the round trip')
    eq(Core.DB.get('players', 'p-2').id, 'p-2', 'the id comes from the row, not from the json')
    eq(seen[2] and seen[2].kind, 'select', 'the read is a SELECT')
    eq(seen[2] and seen[2].params[1], 'players', 'the SELECT is parameterised with the collection')

    Core.DB.count('vehicles')
    local creates = 0
    for i = 1, #seen do
        if seen[i].kind == 'schema' then creates = creates + 1 end
    end
    eq(creates, 1, 'the schema is created once, not once per collection')

    eq(Core.DB.create('players', { id = 'p-3' }), 'p-3', 'a write goes through')
    local last = seen[#seen]
    eq(last and last.kind, 'upsert', 'create upserts')
    eq(last and last.params[1], 'players', 'the upsert carries the collection')
    eq(last and last.params[2], 'p-3', 'the upsert carries the document id')
    check(last and last.sql:find('ON CONFLICT', 1, true) ~= nil, 'the upsert resolves conflicts')
    check(last and type(last.params[4]) == 'number', 'the upsert stamps updated_at')
    eq(Core.DB.delete('players', 'p-3'), true, 'delete removes the document')
    eq(seen[#seen].kind, 'delete', 'and reaches the backend')
    eq(seen[#seen].params[2], 'p-3', 'the DELETE is parameterised with the id')
    eq(Core.DB.flush(), true, 'flush is a no-op that still clears the pending flag')
    eq(Core.DB.isDegraded('players'), false, 'nothing degraded on the happy path')

    -- a failed SELECT: nil + reason, never an empty collection
    local _, pgSelect = recorder({ select = 'connection refused' })
    local _, failing = newPgServer({ url = 'postgres://core@127.0.0.1/core', pgQuery = pgSelect })
    eq(failing.DB.count('players'), 0, 'a failed SELECT reads as empty')
    eq(failing.DB.isDegraded('players'), true, 'and the collection is degraded, not "empty"')
    check(printed('the SELECT failed') ~= nil, 'the reason reaches the console')
    eq(failing.DB.create('players', { id = 'p-9' }), nil, 'a write into it is refused')

    -- a failed upsert degrades the collection
    local _, pgWrite = recorder({ upsert = 'deadlock detected' })
    local _, writeFail = newPgServer({ url = 'postgres://core@127.0.0.1/core', pgQuery = pgWrite })
    eq(writeFail.DB.isDegraded('players'), false, 'the collection starts healthy')
    eq(writeFail.DB.create('players', { id = 'p-4' }), 'p-4', 'the document is created')
    eq(writeFail.DB.isDegraded('players'), true, 'a failed upsert degrades the collection')
    check(printed('upsert failed') ~= nil, 'the failed upsert is logged')
    eq(writeFail.DB.create('players', { id = 'p-5' }), nil, 'the next write is refused')

    -- no Node bridge at all (db_pg.js missing or the runtime not up yet)
    local _, noBridge = newPgServer({ url = 'postgres://core@127.0.0.1/core', pgQuery = nil })
    check(printed('pgQuery export is unusable') ~= nil, 'a missing bridge is logged at start')
    eq(noBridge.DB.count('players'), 0, 'reads come back empty')
    eq(noBridge.DB.isDegraded('players'), true, 'and the collection is degraded')

    -- a query that never answers: the 10 s deadline releases the caller
    local _, pgHang = recorder({ schema = HANG })
    local hangEnv, stalled = newPgServer({ url = 'postgres://core@127.0.0.1/core', pgQuery = pgHang })
    local answered
    hangEnv.CreateThread(function()
        answered = stalled.DB.count('players')
    end)
    eq(answered, nil, 'a read waits for the unanswered query instead of inventing an answer')
    stubs.tick(DEADLINE_MS)
    eq(answered, 0, 'the deadline releases the caller with an empty read')
    eq(stalled.DB.isDegraded('players'), true, 'and degrades the collection')

    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
    stubs.exports.core.pgQuery = nil
    stubs.resetServer()
end

-- end of suites

--------------------------------------------------------------------------------
-- runner
--------------------------------------------------------------------------------

local suites = {
    { 'db', suiteDB },
    { 'db_pg', suiteDbPg },
    { 'perms', suitePerms },
    { 'player', suitePlayer },
    { 'money', suiteMoney },
    { 'factions', suiteFactions },
    { 'vehicles', suiteVehicles },
    { 'api', suiteApi },
    { 'ui', suiteUI },
}

for i = 1, #suites do
    local name, fn = suites[i][1], suites[i][2]
    local ok, err = pcall(fn)
    if not ok then
        suiteName = name
        check(false, 'the suite crashed', tostring(err))
    end
end

print(('\n%d passed, %d failed'):format(passed, failed))
if failed > 0 then
    print(('%d failing check(s):'):format(#failures))
    for i = 1, #failures do print('  ' .. failures[i]:gsub('\n%s+', ' -- ')) end
    os.exit(1)
end
os.exit(0)
