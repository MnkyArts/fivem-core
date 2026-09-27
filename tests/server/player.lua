return function(H)
    local check, eq, lastSent, newServer, printed, stubs, suite, vector3 =
        H.check, H.eq, H.lastSent, H.newServer, H.printed, H.stubs, H.suite, H.vector3

--- The awaited reads in a spy log: { op = 'first'|'select'|'count'|'query'|..., sql?, where?, sync? }.
local function readsOf(log)
    local out = {}
    for i = 1, #log do
        local e = log[i]
        if e.fn == 'crud' then
            local args = e.args[3] or {}
            out[#out + 1] = { op = e.args[1], tbl = e.args[2], where = args.where, sync = args.sync == true }
        elseif e.fn == 'query' or e.fn == 'txQuery' then
            local sql = e.fn == 'query' and e.args[1] or e.args[2]
            local opts = e.fn == 'query' and e.args[3] or nil
            out[#out + 1] = { op = e.fn, sql = sql, sync = type(opts) == 'table' and opts.sync == true }
        end
    end
    return out
end

--- Every queued entry in a spy log: { t, table, key, changes, row, sql }.
local function queuedOf(log)
    local out = {}
    for i = 1, #log do
        if log[i].fn == 'enqueue' then
            local entries = log[i].args[1] or {}
            for j = 1, #entries do out[#out + 1] = entries[j] end
        end
    end
    return out
end

local function characterRow(charId)
    return H.sql('SELECT * FROM characters WHERE id = $1', { charId })[1]
end

local function moneyOf(charId)
    local out = {}
    for _, row in ipairs(H.sql('SELECT account, balance FROM character_money WHERE character_id = $1', { charId })) do
        out[row.account] = row.balance
    end
    return out
end

--- Core.Player (DESIGN §4.2, §5, §8, §56.6, §56.8): join, requestLoad, data paths, replication, drop, kick/ban,
--- and the rows behind a session — indexed reads only, immediate queued writes, a failed read refuses the join.
local function suitePlayer()
    suite('player')
    stubs.resetServer()
    local env, Core = newServer()
    local P = Core.Player
    local log, clearLog = H.spyDB(env)

    -- 1. playerJoining creates the account, its identifiers, the character and its money rows
    stubs.connectPlayer(env, 1, { license = 'license:abc', name = 'Ada',
        coords = vector3(10.0, 20.0, 30.0), heading = 90.0 })
    eq(P.isLoaded(1), true, 'playerJoining built the session')
    eq(P.count(), 1, 'one session is live')
    local info = P.getInfo(1)
    eq(info.name, 'Ada', 'the session carries the sanitized name')
    eq(info.group, 'user', 'a new account starts in the user group')
    eq(info.license, 'license:abc', 'getInfo carries the license for server code')
    eq(P.getSrcByCharId(info.charId), 1, 'byCharId points at the src')
    eq(#(info.accountId or ''), 32, 'the account id is a 32-hex uuid')
    eq(#(info.charId or ''), 32, '... and so is the character id')
    local account = H.sql('SELECT * FROM accounts WHERE id = $1', { info.accountId })[1] or {}
    eq(account.license, 'license:abc', 'the account row was created')
    eq(account.name, 'Ada', '... with the player name')
    eq(account.perm_group, 'user', '... in the user group')
    eq(account.banned, false, 'a new account is not banned')
    eq(account.playtime, 0, 'playtime starts at zero')
    local ids = {}
    for _, row in ipairs(H.sql('SELECT kind, identifier FROM account_identifiers WHERE account_id = $1',
        { info.accountId })) do ids[row.kind] = row.identifier end
    eq(ids.license, 'license:abc', 'the license identifier was upserted')
    eq(ids.fivem, 'fivem:1', 'every identifier type was collected')
    local character = characterRow(info.charId) or {}
    eq(character.account_id, info.accountId, 'the character points at its account')
    eq(character.model, Core.Config.Player.DefaultModel, 'the character gets the default model')
    eq(character.position and character.position.x, Core.Config.Player.SpawnPoint.coords.x, 'it spawns at the configured point')
    eq(character.stats and character.stats.deaths, 0, 'the stats block exists')
    local money = moneyOf(info.charId)
    eq(money.cash, 5000, 'Config.Player.NewCharacter seeded cash as a money row')
    eq(money.bank, 25000, '... and bank')
    eq(H.scalar('SELECT count(*) AS n FROM accounts'), 1, 'exactly one account row')
    eq(H.scalar('SELECT count(*) AS n FROM characters'), 1, 'exactly one character row')
    local data = P.getData(1)
    eq(data.accountId, info.accountId, 'getData() keeps the document shape: accountId')
    eq(data.money.cash, 5000, '... money = { cash, bank }')
    eq(data.faction, false, '... faction = false without a membership')
    eq(type(data.createdAt), 'number', '... times as Unix seconds')
    eq(P.getAccount(1).identifiers.fivem, 'fivem:1', 'getAccount carries the identifiers as { kind = id }')
    -- §56.8 rules 1 and 5: a join reads by index only, with read-your-writes
    local reads = readsOf(log)
    local unindexed, unsynced = {}, {}
    for i = 1, #reads do
        local r = reads[i]
        if (r.op == 'select' or r.op == 'first' or r.op == 'count') and (type(r.where) ~= 'table' or next(r.where) == nil) then
            unindexed[#unindexed + 1] = r.op .. ' ' .. tostring(r.tbl)
        elseif (r.op == 'query' or r.op == 'txQuery') and type(r.sql) == 'string' and r.sql:upper():find('^%s*SELECT')
            and not r.sql:upper():find('WHERE', 1, true) then
            unindexed[#unindexed + 1] = r.sql:sub(1, 60)
        end
        if (r.op == 'first' and r.tbl == 'accounts') or (r.op == 'query' and r.sql:find('FROM characters c', 1, true)) then
            if not r.sync then unsynced[#unsynced + 1] = r.op end
        end
    end
    check(#unindexed == 0, 'a join never reads a whole table', table.concat(unindexed, ' | '))
    check(#unsynced == 0, 'the account and character reads use { sync = true }', table.concat(unsynced, ' | '))
    local txIds = {}
    for i = 1, #log do
        local e = log[i]
        if e.fn == 'crud' and (e.args[1] == 'insert' or e.args[1] == 'insertMany')
            and (e.args[2] == 'characters' or e.args[2] == 'character_money') then
            txIds[#txIds + 1] = e.args[4]
        end
    end
    check(#txIds == 2 and txIds[1] ~= 0 and txIds[1] ~= nil and txIds[1] == txIds[2],
        'the character and its money rows are created in ONE transaction', tostring(#txIds))
    stubs.connectPlayer(env, 1, { license = 'license:abc', name = 'Ada' })
    eq(H.scalar('SELECT count(*) AS n FROM characters'), 1, 'a second playerJoining for a live session creates nothing')

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
    eq(payload.money and payload.money.cash, 5000, 'the payload carries the money table')
    eq(payload.faction, false, 'the payload carries faction = false')
    eq(type(payload.appearance), 'table', 'the payload carries appearance')
    eq(payload.position and payload.position.x, Core.Config.Player.SpawnPoint.coords.x, 'the payload carries the position')
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

    -- 4. getData / setData dot paths — and every change is queued at once (§56.8 rule 3)
    eq(P.setData(1, 'meta.job.title', 'medic'), true, 'setData creates a missing dot path')
    eq(P.getData(1, 'meta.job.title'), 'medic', 'getData walks the dot path')
    eq(P.getData(1, 'meta.job').title, 'medic', 'getData of a table returns the subtree')
    eq(H.scalar("SELECT meta #>> '{job,title}' AS t FROM characters WHERE id = $1", { info.charId }), 'medic',
        'the meta column was written without an autosave')
    eq(P.getData(1, 'meta.nope'), nil, 'a missing path reads nil')
    eq(P.getData(1, 'meta.job.title.deeper'), nil, 'a path through a non-table reads nil')
    local snapshot = P.getData(1, 'meta')
    snapshot.job.title = 'thief'
    eq(P.getData(1, 'meta.job.title'), 'medic', 'getData hands out a deep copy')
    eq(P.getData(1).charId, nil, 'getData() returns the character document, not the session')
    eq(P.getData(1).model, Core.Config.Player.DefaultModel, 'getData() returns the whole document')
    eq(P.setData(1, '', 'x'), false, 'an empty path is refused')
    eq(P.setData(1, 42, 'x'), false, 'a non-string path is refused')
    eq(P.setData(1, 'id', 'x'), false, 'the stored identity (id, accountId, createdAt, updatedAt) is read-only')
    eq(P.setData(99, 'meta.x', 1), false, 'setData without a session is refused')
    eq(P.getData(99, 'meta'), nil, 'getData without a session is nil')
    -- a plugin key (no column) lands in characters.data as a JSON object
    eq(P.setData(1, 'myplugin.level', 3), true, 'setData on a plugin key')
    local stored = H.sql('SELECT data, jsonb_typeof(data) AS kind FROM characters WHERE id = $1', { info.charId })[1] or {}
    eq(stored.data and stored.data.myplugin and stored.data.myplugin.level, 3, 'the plugin key is stored in characters.data')
    eq(stored.data and stored.data.meta, nil, '... next to the columns, never duplicating them')
    P.setData(1, 'myplugin', nil)
    eq(H.scalar('SELECT jsonb_typeof(data) AS kind FROM characters WHERE id = $1', { info.charId }), 'object',
        'removing the last plugin key keeps data a JSON object (never [])')
    P.setData(1, 'myplugin', { level = 4, tags = { 'a', 'b' } })
    P.setData(1, 'faction', { id = 'f1', rank = 1 })
    eq(H.sql('SELECT data FROM characters WHERE id = $1', { info.charId })[1].data.faction, nil,
        'faction is session-only, never stored on the character')
    P.setData(1, 'faction', false)

    -- 5. only the replicated top-level keys write to the bag; money is durable at once
    P.setData(1, 'money', { cash = 10, bank = 20 })
    eq(env.Player(1).state.cash, 10, 'setData on money re-replicates cash')
    eq(env.Player(1).state.bank, 20, '... and bank')
    eq(moneyOf(info.charId).cash, 10, 'the cash row was saved at once')
    eq(moneyOf(info.charId).bank, 20, '... and the bank row')
    P.setData(1, 'name', 'Ada L')
    eq(env.Player(1).state.name, 'Ada L', 'setData on name re-replicates')
    eq(P.getName(1), 'Ada L', 'the session name follows data.name')
    local beforeMeta = env.Player(1).state.meta
    P.setData(1, 'meta.secret', 'hidden')
    eq(env.Player(1).state.meta, beforeMeta, 'an unreplicated key never reaches the bag')
    eq(Core.Money.add(1, 'cash', 5, 'tip'), true, 'Money.add')
    eq(moneyOf(info.charId).cash, 15, 'the money row is visible right after Money.add (no autosave)')

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
    local saved = characterRow(info.charId) or {}
    eq(moneyOf(info.charId).cash, 15, 'the money rows hold the last balance')
    eq(saved.name, 'Ada L', 'the renamed character was saved')
    eq(saved.meta and saved.meta.secret, 'hidden', 'unreplicated data was saved too')
    eq(saved.position and saved.position.x, 1, 'the last ped position was written to the row')
    eq(saved.position and saved.position.heading, 45, '... heading included')
    eq(P.getSrcByCharId(info.charId), nil, 'byCharId was cleared')
    eq(P.save(1), false, 'saving a gone session is false')

    -- 6b. a reconnect reads its own last save back (reads with { sync = true }), plugin keys included
    clearLog()
    stubs.connectPlayer(env, 11, { license = 'license:abc', name = 'Ada' })
    eq(P.getInfo(11).charId, info.charId, 'the reconnect gets the same character')
    eq(P.getData(11, 'money.cash'), 15, '... its last balance')
    eq(P.getData(11, 'meta.secret'), 'hidden', '... its meta')
    eq(P.getData(11, 'myplugin.level'), 4, '... and the plugin key from characters.data')
    eq(P.getData(11, 'myplugin.tags')[2], 'b', '... nested values included')
    eq(P.getData(11, 'position').x, 1, '... and the position saved on drop')
    local sessionReads = {}
    for _, r in ipairs(readsOf(log)) do
        if r.tbl == 'accounts' or (r.sql and r.sql:find('characters', 1, true)) then sessionReads[#sessionReads + 1] = r end
    end
    eq(#sessionReads, 2, 'a returning player costs two awaited reads (account; character + money + faction)')
    check(sessionReads[1] and sessionReads[1].sync and sessionReads[2] and sessionReads[2].sync, 'both with { sync = true }')
    local inserts = 0
    for i = 1, #log do
        if log[i].fn == 'txBegin' or (log[i].fn == 'crud' and log[i].args[1] == 'insert') then inserts = inserts + 1 end
    end
    eq(inserts, 0, '... and creates nothing')
    stubs.dropPlayer(env, 11)

    -- 6c. a READ ERROR refuses the join and creates nothing (§56.8 rule 4)
    stubs.dropped = {}
    H.bridge.fail('FROM "accounts" WHERE "license"', 'XX000 simulated read failure')
    stubs.connectPlayer(env, 12, { license = 'license:readfail', name = 'Err' })
    H.bridge.unfail()
    eq(P.isLoaded(12), false, 'no session after a failed account read')
    eq(stubs.dropped[1] and stubs.dropped[1].src, 12, 'the player is dropped ...')
    check((stubs.dropped[1] and stubs.dropped[1].reason or ''):find('reconnect', 1, true) ~= nil, '... with a retry message')
    check(printed('join refused') ~= nil, '... and it is logged')
    eq(H.scalar("SELECT count(*) AS n FROM accounts WHERE license = 'license:readfail'"), 0, 'no account was created')
    stubs.dropPlayer(env, 12)
    stubs.connectPlayer(env, 13, { license = 'license:charfail', name = 'Cf' })
    local cfAccount = P.getInfo(13).accountId
    stubs.dropPlayer(env, 13)
    stubs.dropped = {}
    H.bridge.fail('FROM characters c', 'XX000 simulated read failure')
    stubs.connectPlayer(env, 14, { license = 'license:charfail', name = 'Cf' })
    H.bridge.unfail()
    eq(P.isLoaded(14), false, 'no session after a failed character read')
    eq(stubs.dropped[1] and stubs.dropped[1].src, 14, 'that join is refused too')
    eq(H.scalar('SELECT count(*) AS n FROM characters WHERE account_id = $1', { cfAccount }), 1,
        'and no second character was created')
    stubs.dropPlayer(env, 14)
    -- a concurrent join of the same license wins the UNIQUE race: the loser's insert answers 23505 and re-selects
    local spyObj = rawget(env.exports, 'core_db')
    local raced = false
    rawset(env.exports, 'core_db', setmetatable({ synchronous = true }, { __index = function(_, fnName)
        return function(_, ...)
            local args = table.pack(...)
            if fnName == 'crud' and args[1] == 'insert' and args[2] == 'accounts' and not raced then
                raced = true
                H.sql("INSERT INTO accounts (id, license, name) VALUES ('race0000000000000000000000000001', "
                    .. "'license:race', 'First')")
            end
            return spyObj[fnName](spyObj, table.unpack(args, 1, args.n))
        end
    end }))
    stubs.connectPlayer(env, 15, { license = 'license:race', name = 'Second' })
    rawset(env.exports, 'core_db', spyObj)
    eq(raced, true, 'the race was staged inside the account insert')
    eq(P.getInfo(15) and P.getInfo(15).accountId, 'race0000000000000000000000000001',
        'a lost UNIQUE race (23505) re-selects the winner\'s account')
    eq(H.scalar("SELECT count(*) AS n FROM accounts WHERE license = 'license:race'"), 1, '... and makes no second one')
    stubs.dropPlayer(env, 15)

    -- 7. an unclean reconnect takes the character over from the ghost session
    stubs.connectPlayer(env, 2, { license = 'license:ghost', name = 'Bo' })
    local ghostInfo = P.getInfo(2)
    eq(Core.Money.add(2, 'cash', 777, 'test'), true, 'the ghost earns money')
    eq(P.getData(2, 'money.cash'), 5777, 'the ghost session holds the newer balance')
    eq(moneyOf(ghostInfo.charId).cash, 5777, 'the row already has it (queued at once, not at the autosave)')
    P.setData(2, 'meta.ghostNote', 'unsaved?')
    stubs.connectPlayer(env, 3, { license = 'license:ghost', name = 'Bo' })
    eq(P.isLoaded(2), false, 'the ghost session was evicted')
    eq(P.isLoaded(3), true, 'the new session is live')
    eq(P.getInfo(3).charId, ghostInfo.charId, 'the character moved to the new src')
    eq(P.getSrcByCharId(ghostInfo.charId), 3, 'byCharId points at the new src')
    eq(H.scalar('SELECT count(*) AS n FROM characters WHERE account_id = $1', { ghostInfo.accountId }), 1,
        'no second character was created for the same account')
    eq(P.getData(3, 'money.cash'), 5777, 'the money change survived the handover')
    eq(P.getData(3, 'meta.ghostNote'), 'unsaved?', '... and so did the ghost\'s other data')
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

    -- Player.ban without Core.Bans (suitePlayerAdmin covers the delegation): nothing can record a ban any more,
    -- so the player is kicked, the error is logged and false says that no ban exists
    stubs.dropped = {}
    local realBans = rawget(Core, 'Bans')
    Core.Bans = nil
    eq(P.ban(44, 'x'), false, 'ban refuses an unconnected src')
    eq(P.ban(3, 'cheating', 3600, 'admin'), false, 'without Core.Bans no ban is recorded (false)')
    eq(stubs.dropped[1] and stubs.dropped[1].src, 3, '... but the player is kicked')
    eq(stubs.dropped[1] and stubs.dropped[1].reason, 'cheating', '... with the reason')
    check(printed('Core.Bans is not loaded') ~= nil, '... and the missing ban module is logged as an error')
    eq(H.scalar('SELECT count(*) AS n FROM bans'), 0, 'no ban row was written')
    Core.Bans = realBans

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
    local moved = characterRow(ghostInfo.charId) or {}
    eq(moved.position and moved.position.x, 5, 'setCoords queued the position at once')
    eq(P.setCoords(3, { x = 1.0, y = 2.0, z = 3.0 }), true, 'setCoords accepts a plain table')
    eq(P.setCoords(3, 'nope'), false, 'setCoords refuses anything else')
    eq(P.setModel(3, 'a_m_y_beach_01', { hair = 3 }), true, 'setModel')
    eq(P.getData(3, 'model'), 'a_m_y_beach_01', 'the model was stored')
    local look = characterRow(ghostInfo.charId) or {}
    eq(look.model, 'a_m_y_beach_01', 'setModel queued the model ...')
    eq(look.appearance and look.appearance.hair, 3, '... and the appearance at once')
    eq(P.setModel(3, 42), false, 'setModel refuses a non-string')
    -- kick/ban only call DropPlayer; the session lives until the engine fires playerDropped
    stubs.connectPlayer(env, 5, { license = 'license:perm', name = 'Cy' })
    eq(P.count(), 2, 'the kicked session and a new one are loaded')
    eq(P.saveAll(), 2, 'saveAll saves every live session')
    local seen = {}
    P.forEach(function(_, playerInfo) seen[#seen + 1] = playerInfo.charId end)
    eq(#seen, 2, 'forEach visits every session')
    eq(#P.getPlayers(), 2, 'getPlayers lists the loaded sessions')

    -- 10. saves write only what is dirty (§56.8 rule 6): a clean session writes nothing
    stubs.osTime = 1800000000
    local spawn = env.Config.Player.SpawnPoint     -- the ped stands where the new character is stored
    stubs.connectPlayer(env, 6, { license = 'license:clean', name = 'Clean', coords = spawn.coords, heading = spawn.heading })
    local cleanInfo = P.getInfo(6)
    clearLog()
    eq(P.save(6), true, 'Player.save of a clean session')
    eq(#queuedOf(log), 0, 'writes nothing (no second passed, nothing changed)')
    env.Config.Player.SaveIntervalMs = 1000
    P.startAutosave()
    clearLog()
    stubs.tick(1010)
    local writes = queuedOf(log)
    local cleanWrites = 0
    for i = 1, #writes do
        local key = writes[i].key
        if key == cleanInfo.charId or key == cleanInfo.accountId then cleanWrites = cleanWrites + 1 end
    end
    eq(cleanWrites, 0, 'an autosave pass writes nothing for a session that did not move or play a second')
    stubs.coords[stubs.peds[6]] = vector3(150.0, 5.0, 0.0)
    clearLog()
    stubs.tick(1000)
    writes = queuedOf(log)
    local positionPatch
    for i = 1, #writes do
        if writes[i].table == 'characters' and writes[i].key == cleanInfo.charId then positionPatch = writes[i] end
    end
    check(positionPatch ~= nil and positionPatch.t == 'patch' and positionPatch.changes.position ~= nil
        and positionPatch.changes.stats == nil, 'a moved ped: ONE characters patch with the position only')
    stubs.osTime = 1800000060
    clearLog()
    stubs.tick(1000)
    local accountPatch, charPatch
    for _, entry in ipairs(queuedOf(log)) do
        if entry.table == 'accounts' and entry.key == cleanInfo.accountId then accountPatch = entry end
        if entry.table == 'characters' and entry.key == cleanInfo.charId then charPatch = entry end
    end
    check(charPatch and charPatch.changes.stats and charPatch.changes.last_played and not charPatch.changes.position,
        'a played minute: the character patch carries stats + last_played')
    check(accountPatch and accountPatch.changes.playtime == 60 and accountPatch.changes.last_seen ~= nil,
        '... and ONE accounts patch playtime + last_seen')
    eq(H.scalar('SELECT playtime FROM accounts WHERE id = $1', { cleanInfo.accountId }), 60, 'accounts.playtime = 60 s')
    eq(H.scalar("SELECT (stats ->> 'playtime')::int AS p FROM characters WHERE id = $1", { cleanInfo.charId }), 60,
        'characters.stats.playtime = 60 s')
    check(H.scalar('SELECT last_played IS NOT NULL AS ok FROM characters WHERE id = $1', { cleanInfo.charId }) == true,
        'last_played is set')
    P.stopAutosave()
    stubs.tick(1000)
    stubs.osTime = nil

    -- 11. core_db down: a queued write that could not be handed over stays dirty and the next save sends it;
    -- a value its column cannot take is logged and dropped (never retried at every autosave)
    local realState = env.GetResourceState
    env.GetResourceState = function(res) if res == 'core_db' then return 'stopped' end return realState(res) end
    eq(P.setData(6, 'meta.offline', 7), true, 'setData works on the session while core_db is down')
    eq(Core.Money.add(6, 'bank', 100, 'offline'), true, 'so does Money.add')
    env.GetResourceState = realState
    eq(H.scalar("SELECT (meta ->> 'offline')::int AS v FROM characters WHERE id = $1", { cleanInfo.charId }), nil,
        'nothing reached the database meanwhile')
    eq(P.save(6), true, 'the next save ...')
    eq(H.scalar("SELECT (meta ->> 'offline')::int AS v FROM characters WHERE id = $1", { cleanInfo.charId }), 7,
        '... sends the dirty meta column')
    eq(moneyOf(cleanInfo.charId).bank, 25100, '... and the unsaved balance')
    stubs.clear()
    eq(P.setData(6, 'name', { first = 'bad' }), true, 'a name that is no string is kept in the session')
    check(printed('character.name of ' .. cleanInfo.charId .. ' must be a string') ~= nil, '... but logged, not saved')
    clearLog()
    P.save(6)
    eq(#queuedOf(log), 0, '... and not retried by the next save')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

--- Every printed line containing `needle`, counted.
local function printedCount(needle)
    local n = 0
    for i = 1, #stubs.printed do
        if stubs.printed[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

--- Review R2a (2026-09-27): loads racing releases, the ghost's drop hook, values JSON cannot carry, the restore
--- after `restart core`, the `data` statements, dbWriteFailed and the txAdmin shutdown save.
local function suitePlayerRaces()
    suite('player races')
    stubs.resetServer()
    local env, Core = newServer()
    local P = Core.Player
    local log, clearLog = H.spyDB(env)

    -- R2a-2: a takeover releases the ghost like a drop — position refreshed, playerDropped emitted (once)
    stubs.connectPlayer(env, 21, { license = 'license:gh', name = 'Gh', coords = vector3(5.0, 5.0, 5.0) })
    local ghostChar = P.getInfo(21).charId
    local dropped = {}
    Core.on('playerDropped', function(src, charId)
        dropped[#dropped + 1] = { src = src, charId = charId, loaded = P.isLoaded(src) }
    end)
    stubs.coords[stubs.peds[21]] = vector3(77.0, 88.0, 9.0)
    eq(Core.PlayerGrid.cellOf(21) ~= nil, true, 'the ghost src is in the player grid')
    stubs.connectPlayer(env, 22, { license = 'license:gh', name = 'Gh' })
    eq(#dropped, 1, 'the takeover emitted playerDropped for the ghost src')
    eq(dropped[1] and dropped[1].src, 21, '... naming the ghost src')
    eq(dropped[1] and dropped[1].charId, ghostChar, '... and its character')
    eq(dropped[1] and dropped[1].loaded, true, '... while its session was still loaded (like a drop)')
    eq(Core.PlayerGrid.cellOf(21), nil, 'so the grid forgot the ghost src')
    eq(P.getData(22, 'position').x, 77, 'the ghost\'s live position was refreshed and read back by the new session')
    stubs.dropPlayer(env, 21)
    eq(#dropped, 1, 'the ghost\'s late real drop emits nothing twice')
    stubs.dropPlayer(env, 22)

    -- R2a-1: a session released WHILE the load of its license is in flight is read again (sync)
    stubs.connectPlayer(env, 23, { license = 'license:rel', name = 'Rel' })
    local relChar = P.getInfo(23).charId
    local restore = H.deferDB(env, 50)
    env.CreateThread(function() stubs.connectPlayer(env, 24, { license = 'license:rel', name = 'Rel' }) end)
    stubs.tick(60)                                            -- the account read landed, the character read is out
    eq(P.isLoaded(24), false, 'src 24 is still loading')
    eq(Core.Money.add(23, 'cash', 500, 'late transfer'), true, 'the old session is credited meanwhile')
    stubs.dropPlayer(env, 23)                                 -- ... and released: its final save is queued
    stubs.tick(400)
    eq(P.isLoaded(24), true, 'src 24 got its session')
    eq(P.getData(24, 'money.cash'), 5500, 'with the credit the old session saved while the reads were in flight')
    eq(P.getInfo(24).charId, relChar, '... on the same character')
    -- the same while the old session is still live when the reads land (it is taken over, then read again)
    env.CreateThread(function() stubs.connectPlayer(env, 25, { license = 'license:rel', name = 'Rel' }) end)
    stubs.tick(60)
    eq(Core.Money.add(24, 'cash', 250, 'late transfer 2'), true, 'the live session is credited mid-load')
    stubs.tick(400)
    eq(P.isLoaded(24), false, 'the old src was taken over')
    eq(P.getData(25, 'money.cash'), 5750, 'and the credit made after the reads started is not lost')
    stubs.dropPlayer(env, 24)                                 -- the engine drops the taken-over connection later

    -- R2a-5: a second load of a src that waits on its busy license returns at once (no second session)
    env.CreateThread(function() stubs.connectPlayer(env, 26, { license = 'license:busy', name = 'Busy' }) end)
    stubs.tick(10)
    env.CreateThread(function() stubs.connectPlayer(env, 27, { license = 'license:busy', name = 'Busy' }) end)
    stubs.tick(10)
    local second
    env.CreateThread(function() second = P.loadSession(27) end)
    stubs.tick(10)
    eq(second, false, 'a second load of src 27 while it waits on the license answers at once')
    stubs.clear()
    stubs.tick(2000)
    eq(P.isLoaded(27), true, 'src 27 was loaded once the license was free')
    eq(printedCount('session ready for [27]'), 1, 'exactly one session was built for it')
    restore()
    stubs.dropPlayer(env, 26)
    stubs.dropPlayer(env, 27)
    stubs.dropPlayer(env, 25)

    -- R2a-3: every value goes through jsonSafe; one value JSON cannot carry never blocks the others
    stubs.connectPlayer(env, 28, { license = 'license:json', name = 'Json' })
    local jsonChar, jsonAccount = P.getInfo(28).charId, P.getInfo(28).accountId
    eq(P.setData(28, 'spot', vector3(1.0, 2.0, 3.0)), true, 'a vector3 plugin value')
    local data = H.sql('SELECT data FROM characters WHERE id = $1', { jsonChar })[1].data
    eq(data.spot and data.spot.y, 2, '... is stored as { x, y, z }')
    stubs.clear()
    eq(P.setData(28, 'broken', print), true, 'a function value stays in the session')
    check(printed('key broken of ' .. jsonChar .. ' is not JSON-encodable') ~= nil, '... and is logged, not stored')
    eq(P.setData(28, 'later', 6), true, 'a plugin key set afterwards')
    data = H.sql('SELECT data FROM characters WHERE id = $1', { jsonChar })[1].data
    eq(data.later, 6, '... still persists')
    eq(data.spot and data.spot.x, 1, '... and so do the older keys')
    eq(data.broken, nil, '... the broken one alone is left out')
    P.setData(28, 'broken', nil)
    eq(P.setAccountData(28, 'home', vector3(4.0, 5.0, 6.0)), true, 'a vector3 account value')
    eq(H.scalar("SELECT (data -> 'home' ->> 'z')::float8 AS z FROM accounts WHERE id = $1", { jsonAccount }), 6,
        '... lands in accounts.data as { x, y, z }')
    stubs.clear()
    P.setData(28, 'meta.fn', print)
    check(printed('character.meta of ' .. jsonChar .. ' must be JSON-encodable') ~= nil,
        'a column holding a function is logged, not queued')
    eq(P.setCoords(28, vector3(9.0, 8.0, 7.0)), true, 'another column in the next save')
    eq(H.scalar("SELECT (position ->> 'x')::float8 AS x FROM characters WHERE id = $1", { jsonChar }), 9,
        '... is written all the same')
    P.setData(28, 'meta.fn', nil)

    -- R2a-8: `data` is a patch (bulk, coalesced); only an EMPTY map adds the keyed statement that turns [] into {}
    clearLog()
    P.setData(28, 'later', 7)
    local entries = {}
    for i = 1, #log do
        if log[i].fn == 'enqueue' then
            for _, entry in ipairs(log[i].args[1] or {}) do entries[#entries + 1] = entry end
        end
    end
    eq(#entries, 1, 'a plugin key is one queued entry ...')
    check(entries[1] and entries[1].t == 'patch' and entries[1].table == 'characters' and entries[1].changes
        and entries[1].changes.data and entries[1].changes.data.later == 7, '... a characters patch of `data`')
    clearLog()
    P.setData(28, 'later', nil)
    P.setData(28, 'spot', nil)
    local normalise
    for i = 1, #log do
        if log[i].fn == 'enqueue' then
            for _, entry in ipairs(log[i].args[1] or {}) do
                if entry.t == 'sql' then normalise = entry end
            end
        end
    end
    check(normalise ~= nil and normalise.key == 'core:characters.data:' .. jsonChar, 'the empty map adds ONE keyed statement')
    eq(H.scalar('SELECT jsonb_typeof(data) AS t FROM characters WHERE id = $1', { jsonChar }), 'object',
        '... so `data` stays a JSON object')
    H.sql([[UPDATE characters SET data = '{"k":2}'::jsonb WHERE id = $1]], { jsonChar })
    H.sql(normalise and normalise.sql or 'SELECT 1', normalise and { jsonChar } or nil)
    eq(H.scalar("SELECT data ->> 'k' AS k FROM characters WHERE id = $1", { jsonChar }), '2',
        'and it never touches an object (order-safe against a later patch of the row)')

    -- R2a-9: a queued write core_db drops (dbWriteFailed) is sent again by the next save
    H.bridge.fail('INSERT INTO "character_money"', 'XX000 simulated write failure')
    eq(Core.Money.add(28, 'cash', 1, 'dropped'), true, 'Money.add while its row write fails')
    H.bridge.unfail()
    local function cash() return H.scalar("SELECT balance FROM character_money WHERE character_id = $1 AND account = 'cash'",
        { jsonChar }) end
    eq(cash(), 5000, 'core_db dropped the money row')
    eq(P.save(28), true, 'the next save ...')
    eq(cash(), 5001, '... sends the balance again')
    H.bridge.fail('UPDATE "characters" AS x', 'XX000 simulated write failure')
    P.setData(28, 'meta.retry', 'yes')
    H.bridge.unfail()
    eq(H.scalar("SELECT meta ->> 'retry' AS r FROM characters WHERE id = $1", { jsonChar }), nil,
        'a dropped characters patch')
    P.save(28)
    eq(H.scalar("SELECT meta ->> 'retry' AS r FROM characters WHERE id = $1", { jsonChar }), 'yes',
        '... is re-sent by the next save')
    stubs.dropPlayer(env, 28)

    -- R2a-4 / R2a-12: the restore after `restart core` (server/main.lua) and the txAdmin shutdown save
    for src = 31, 33 do
        stubs.connectPlayer(env, src, { license = ('license:rs%d'):format(src), name = 'Rs' .. src,
            coords = vector3(src + 0.0, 1.0, 1.0) })
        Core.Money.add(src, 'bank', src, 'before restart')
    end
    P.saveAll()
    local env2, Core2 = newServer()                          -- core restarts: the players stay connected
    stubs.loadFile(env2, 'server/main.lua')
    local log2, clearLog2 = H.spyDB(env2)
    local atReady
    Core2.on('ready', function() atReady = Core2.Player.count() end)
    local restore2 = H.deferDB(env2, 50)
    stubs.clear()
    env2.CreateThread(function() env2.TriggerEvent('onResourceStart', 'core') end)
    stubs.tick(260)
    eq(atReady, 0, '`ready` is emitted before the restore')
    eq(Core2.Player.count(), 3, 'every connected player has a session again within ~2 reads (parallel workers)')
    eq(Core2.Player.getData(32, 'money.bank'), 25032, '... read back from the rows')
    check(printed('restored 3 session(s) after restart') ~= nil, 'the restore is logged')
    restore2()
    local flushes, syncedReads, reads = 0, 0, 0
    for i = 1, #log2 do
        local e = log2[i]
        if e.fn == 'sync' then flushes = flushes + 1 end
        local sessionRead = (e.fn == 'crud' and e.args[2] == 'accounts')
            or (e.fn == 'query' and type(e.args[1]) == 'string' and e.args[1]:find('FROM characters c', 1, true))
        if sessionRead then
            reads = reads + 1
            local opts = e.fn == 'crud' and e.args[3] or e.args[3]
            if type(opts) == 'table' and opts.sync == true then syncedReads = syncedReads + 1 end
        end
    end
    eq(flushes, 1, 'ONE flush before the restore')
    eq(reads, 6, 'two reads per player')
    eq(syncedReads, 0, '... none of them waits for the queue (sync)')
    stubs.coords[stubs.peds[31]] = vector3(500.0, 600.0, 7.0)
    clearLog2()
    env2.TriggerEvent('txAdmin:events:serverShuttingDown')
    local shutdownPatch
    for i = 1, #log2 do
        if log2[i].fn == 'enqueue' then
            for _, entry in ipairs(log2[i].args[1] or {}) do
                if entry.table == 'characters' and entry.key == Core2.Player.getInfo(31).charId then shutdownPatch = entry end
            end
        end
    end
    check(shutdownPatch ~= nil and shutdownPatch.changes.position ~= nil and shutdownPatch.changes.position.x == 500,
        'txAdmin\'s shutdown warning queues every session (position included)')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

    return function()
        suitePlayer()
        suitePlayerRaces()
    end
end
