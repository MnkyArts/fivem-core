--[[
    core/tests/audit_tests.lua — offline contract of Core.Audit (DESIGN §46, storage §56) and the Log.audit mirror.

        scripts/test-db.sh up            (once: the throwaway database core_test)
        lua5.4 tests/audit_tests.lua     (from the resource directory, or from tests/)

    One core server VM per case: import.lua, shared/config.lua, server/api.lua, core's migrations registered
    through Core.DB (the lib, over the Postgres test bridge — §56.10.2), a FAKE Core.Player / Core.Settings /
    Core.Webhook (so this suite does not depend on player.lua or the HTTP stack), then server/cron.lua and
    server/audit.lua. Every DB call is synchronous through the bridge; `record` is a queued append, which the
    bridge flushes before it answers. A "restart" is a new VM over the same database. Exit code 1 on failure.
]]

local here = (arg and arg[0] or 'tests/audit_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local bridge = stubs.bridge

local passed, failed = 0, 0
local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  %s%s'):format(label, detail and ('\n        ' .. detail) or ''))
    return false
end
local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

local BASE_TIME <const> = 1790000000
local CORE_MIGRATIONS <const> = { 'sql/0001_core_schema.sql', 'sql/0002_core_legacy_import.sql' }

--- A fresh core VM. opts = { settings = { [key] = value }, convars = {}, before = fn(env, Core),
--- keep = true (a restart: the database is NOT reset) }
local function newCore(opts)
    opts = opts or {}
    if not opts.keep then stubs.resetServer() end
    stubs.newWorld()
    stubs.clear()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
    stubs.exports.core = nil
    stubs.resourceStates.core = 'started'
    stubs.resourceStates.core_db = nil
    stubs.osTime = opts.keep and stubs.osTime or BASE_TIME
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    local convars = opts.convars or {}
    env.GetConvar = function(name, fallback)
        local value = convars[name]
        if value == nil then return fallback end
        return value
    end
    local Core = stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, 'server/api.lua')
    -- core's migrations (server/db.lua registers them in the resource): applied once per bridge schema
    local DB = Core.DB
    assert(DB.migrate(CORE_MIGRATIONS))
    assert(DB.awaitMigrations())

    local sessions = { [1] = { accountId = 'acc1', name = 'Alice', group = 'admin' },
        [2] = { accountId = 'acc2', name = 'Bob', group = 'user' } }
    stubs.playerNames[1], stubs.playerNames[2], stubs.playerNames[3] = 'Alice', 'Bob', 'Carol'
    Core.Player = {
        getInfo = function(src)
            local s = sessions[src]
            if not s then return nil end
            return { src = src, accountId = s.accountId, name = s.name, group = s.group, charId = 'c' .. src }
        end,
    }
    local settingsHandlers = {}
    local settings = opts.settings
    if settings then
        Core.Settings = {
            get = function(key) return settings[key] end,
            onChange = function(prefix, fn) settingsHandlers[#settingsHandlers + 1] = { prefix = prefix, fn = fn } end,
        }
    end
    local sent = {}
    if opts.fakeWebhook ~= false then
        Core.Webhook = { send = function(name, embed) sent[#sent + 1] = { name = name, embed = embed } return true end }
    end
    if opts.before then opts.before(env, Core) end
    stubs.loadFile(env, 'server/cron.lua')
    stubs.loadFile(env, 'server/audit.lua')
    return env, Core, { sent = sent, settings = settings, settingsHandlers = settingsHandlers, convars = convars }
end

--- Runs the start thread (it Waits one tick, registers the jobs and prunes once).
local function settle(ms)
    stubs.tick(ms or 10)
end

local function actions(rows)
    local out = {}
    for i = 1, #rows do out[i] = rows[i].action end
    return table.concat(out, ',')
end

--- The newest stored row (record answers true; the id is the queue's identity).
local function newest(Core)
    local page = Core.Audit.query({ limit = 1 })
    return page and page.rows[1]
end

local function count(sql, params)
    local rows = bridge.sql(sql, params)
    return rows and rows[1] and rows[1].n
end

--------------------------------------------------------------------------------
-- record: normalisation, bounds, actor and target resolution
--------------------------------------------------------------------------------

do
    local _, Core = newCore()
    local Audit = Core.Audit
    settle()
    local ok = Audit.record({
        actor = 1, action = 'admin.kick', source = 'menu', reason = 'spam', message = 'kicked Bob',
        targets = { { type = 'player', id = 2 }, 3 }, changes = { { key = 'hp', old = 100, new = 0 } },
        ctx = { radius = 5, nested = { a = 1 } },
    })
    eq(ok, true, 'record answers true once the row is queued')
    local listed = newest(Core)
    check(listed ~= nil and type(listed.id) == 'string' and listed.id:match('^%d+$') ~= nil,
        'a stored row has a decimal string id (the identity)')
    local row = Audit.get(listed.id)
    check(row ~= nil, 'the row is stored and Audit.get reads it back')
    eq(row.action, 'admin.kick', 'get returns the row of that id')
    eq(Audit.get(tonumber(listed.id)).id, listed.id, 'get also takes the integer id')
    eq(row.actor.kind, 'player', 'actor src resolves to a player')
    eq(row.actor.accountId, 'acc1', 'actor snapshot carries the account')
    eq(row.actor.name, 'Alice', 'actor snapshot carries the name')
    eq(row.actor.group, 'admin', 'actor snapshot carries the group')
    eq(row.targets[1].accountId, 'acc2', 'a player target gains the accountId')
    eq(row.targets[1].name, 'Bob', 'a player target gains the name')
    eq(row.targets[2].type, 'player', 'a bare number is a player target')
    eq(row.targets[2].name, 'Carol', 'an unloaded player target falls back to GetPlayerName')
    eq(row.source, 'menu', 'a valid source is kept')
    eq(row.resource, 'core', 'the caller is recorded')
    eq(row.result, 'ok', 'result defaults to ok')
    eq(row.changes[1].new, 0, 'numbers stay numbers in changes')
    check(type(row.ctx.nested) == 'string' and row.ctx.nested:find('"a":1', 1, true) ~= nil, 'ctx tables are stringified')
    check(math.type(row.ts) == 'integer' and row.ts >= BASE_TIME * 1000, 'ts is wall-clock milliseconds')

    -- the stored columns (§56.6): pool, actor account, target keys, the lower-cased search haystack
    local stored = bridge.sql('SELECT pool, actor_account_id, target_keys, search, '
        .. '(extract(epoch FROM at) * 1000)::bigint AS ms FROM audit_log WHERE id = $1', { tonumber(listed.id) })[1]
    eq(stored.pool, 'main', 'an admin action is stored in the main pool')
    eq(stored.actor_account_id, 'acc1', 'actor_account_id is its own column')
    local keys = table.concat(stored.target_keys, ',')
    eq(keys, 'player:2,account:acc2,player:3', 'target_keys: type:id and account:<id> for player targets')
    check(stored.search:find('admin.kick alice kicked bob spam bob', 1, true) == 1, 'search: action, actor, message, reason, targets (lower case)')
    eq(stored.ms, row.ts, 'at keeps the millisecond of ts')

    eq(Audit.record({ actor = 0, action = 'x.y' }), true, 'a console row is queued')
    eq(newest(Core).actor.kind, 'console', 'actor 0 is the console')
    Audit.record({ action = 'x.y', source = 'bogus', result = 'nope' })
    local system = newest(Core)
    eq(system.actor.kind, 'system', 'no actor is the system')
    eq(system.source, 'core', 'an unknown source falls back to the caller kind')
    eq(system.result, 'ok', 'an unknown result falls back to ok')
    eq(system.targets, nil, 'no targets: the column is NULL (absent)')

    local long = string.rep('m', 700)
    local targets, changes = {}, {}
    for i = 1, 40 do targets[i] = { type = 'entity', id = i } end
    for i = 1, 70 do changes[i] = { 'k' .. i, string.rep('o', 300), { deep = string.rep('n', 300) } } end
    Audit.record({ action = 'bulk.edit', message = long, reason = long, targets = targets, changes = changes })
    local bounded = newest(Core)
    eq(#bounded.message, 512, 'message is bounded to 512')
    eq(#bounded.reason, 256, 'reason is bounded to 256')
    eq(#bounded.targets, 32, 'targets are bounded to 32')
    eq(#bounded.changes, 64, 'changes are bounded to 64')
    eq(bounded.changes[1].key, 'k1', 'positional changes are read')
    eq(#bounded.changes[1].old, 256, 'string values are bounded to 256')
    check(#bounded.changes[1].new <= 256, 'table values are stringified and bounded')
    local haystack = bridge.sql('SELECT length(search) AS n FROM audit_log WHERE id = $1', { tonumber(bounded.id) })[1]
    check(haystack.n <= 640, 'the search haystack is bounded to 640')
    Audit.record({ action = 'x.utf', message = string.rep('a', 511) .. 'é' })
    local utf = newest(Core)
    check(utf8.len(utf.message) ~= nil, 'a bound never cuts a UTF-8 sequence')
    Audit.record({ action = 'x.utf2', message = string.rep('é', 400) })
    eq(newest(Core).action, 'x.utf2', 'a haystack cut inside a UTF-8 sequence is still stored')
    Audit.record({ action = 'x.ctl', message = 'a\nb\0c' })
    eq(newest(Core).message, 'abc', 'control characters are stripped')

    eq(Audit.record(nil), nil, 'record(nil) is refused')
    eq(Audit.record({ action = 'bad action!' }), nil, 'an invalid action is refused')
    eq(Audit.record({ action = string.rep('a', 65) }), nil, 'an over-long action is refused')
    check(Audit.record({ action = 'x.z', targets = 'no', changes = 5, ctx = 'y', actor = {} }) ~= nil,
        'junk optional fields never throw')
    Audit.record({ action = 'same.ms1' })
    Audit.record({ action = 'same.ms2' })
    local pair = Audit.query({ limit = 2 }).rows
    check(pair[1].action == 'same.ms2' and tonumber(pair[2].id) < tonumber(pair[1].id),
        'two rows in the same millisecond get increasing ids in record order')
    eq(Audit.get('garbage'), nil, 'get of a malformed id is nil')
    eq(Audit.get(987654321), nil, 'get of an unknown id is nil')
    eq(#stubs.failures, 0, 'no thread errors')
end

--------------------------------------------------------------------------------
-- record never awaits: before the start thread, and outside any coroutine
--------------------------------------------------------------------------------

do
    local env, Core = newCore()
    local Audit = Core.Audit
    local early = Audit.record({ actor = 2, action = 'early.row' })
    eq(early, true, 'record works before the start thread ran')
    eq(Core.DB.count('audit_log'), 1, 'the row is appended at once (queued, flushed by the bridge)')
    settle()
    eq(Core.DB.count('audit_log'), 1, 'the start thread stores nothing twice')
    eq(#Audit.query({}).rows, 1, 'and it is queryable')

    -- a transport without the offline shortcut: awaited calls in the main chunk answer not_in_coroutine,
    -- queued calls still work — record is a queued append, query is awaited
    rawset(env.exports.core_db, 'synchronous', false)
    eq(Audit.record({ action = 'plain.context' }), true, 'record works outside any coroutine (queued append)')
    local page, err = Audit.query({})
    check(page == nil and err == 'not_in_coroutine', 'query is awaited: outside a coroutine it answers nil, err')
    rawset(env.exports.core_db, 'synchronous', true)
    eq(newest(Core).action, 'plain.context', 'the plain-context row was stored')

    -- core_db stopped: record refuses (nil), never throws, and warns once
    stubs.clear()
    stubs.resourceStates.core_db = 'stopped'
    eq(Audit.record({ action = 'lost.row' }), nil, 'record answers nil when the queue refuses the row')
    eq(Audit.record({ action = 'lost.row' }), nil, 'every refused row answers nil')
    local warned = 0
    for i = 1, #stubs.printed do
        if stubs.printed[i]:find('could not be stored', 1, true) then warned = warned + 1 end
    end
    eq(warned, 1, 'refused rows are logged once per 10 s, not per row')
    stubs.resourceStates.core_db = nil
    eq(#Audit.query({ action = 'lost.row' }).rows, 0, 'nothing was stored while core_db was down')

    -- a failing database: query answers nil, err (never an empty page)
    bridge.fail('FROM audit_log', 'XX000 simulated failure')
    page, err = Audit.query({})
    check(page == nil and tostring(err):find('simulated failure', 1, true) ~= nil, 'a failed query answers nil, err')
    local got, getErr = Audit.get(1)
    check(got == nil and getErr ~= nil, 'a failed get answers nil, err')
    bridge.unfail()
    eq(#Audit.query({}).rows, 2, 'the trail reads again once the database answers')
end

--------------------------------------------------------------------------------
-- query: newest first, filters (each ONE SQL query), keyset paging, a restart
--------------------------------------------------------------------------------

do
    local _, Core = newCore()
    local Audit = Core.Audit
    settle()
    Audit.record({ actor = 1, action = 'admin.kick', targets = { 2 }, message = 'Kicked for SPAM' })
    stubs.tick(5)
    Audit.record({ actor = 2, action = 'admin.heal', targets = { { type = 'player', id = 1 } }, result = 'denied' })
    stubs.tick(5)
    Audit.record({ actor = 1, action = 'settings.set', targets = { { type = 'setting', id = 'maps.max' } } })
    stubs.tick(5)
    stubs.exports.core.call('shop', 'Audit', 'record', { actor = 2, action = 'shop.buy', message = 'bread' })
    stubs.tick(5)
    Audit.record({ actor = 0, action = 'admin.kick', targets = { 1 }, result = 'error' })

    local all = Audit.query({})
    eq(actions(all.rows), 'admin.kick,shop.buy,settings.set,admin.heal,admin.kick', 'newest first')
    eq(all.next, nil, 'no cursor when everything fit')
    eq(#Audit.query({ action = 'admin.kick' }).rows, 2, 'filter: action')
    eq(actions(Audit.query({ actionPrefix = 'admin.' }).rows), 'admin.kick,admin.heal,admin.kick', 'filter: actionPrefix')
    eq(#Audit.query({ actorAccount = 'acc2' }).rows, 2, 'filter: actorAccount')
    eq(actions(Audit.query({ target = { type = 'player', id = 2 } }).rows), 'admin.kick', 'filter: player target')
    eq(actions(Audit.query({ target = { type = 'player', id = 2.0 } }).rows), 'admin.kick',
        'filter: a float id 2.0 is normalised like the write path (player:2)')
    eq(actions(Audit.query({ target = { type = 'player', id = '2' } }).rows), 'admin.kick', 'filter: a numeric string id too')
    eq(#Audit.query({ target = { type = 'player', id = 2.5 } }).rows, 0, 'filter: a fractional id (never stored) matches nothing')
    eq(actions(Audit.query({ target = { type = 'account', id = 'acc1' } }).rows), 'admin.kick,admin.heal',
        'filter: a player target is also found by its account')
    eq(actions(Audit.query({ target = { type = 'setting', id = 'maps.max' } }).rows), 'settings.set', 'filter: other target types')
    local shop = Audit.query({ resource = 'shop' }).rows
    eq(#shop, 1, 'filter: resource (a plugin call through the export)')
    eq(shop[1].source, 'api', 'a plugin row defaults to source api')
    eq(actions(Audit.query({ result = 'denied' }).rows), 'admin.heal', 'filter: result')
    eq(actions(Audit.query({ text = 'spam' }).rows), 'admin.kick', 'filter: text is case-insensitive')
    eq(#Audit.query({ text = 'bob' }).rows, 3, 'filter: text matches actor and target names')
    eq(actions(Audit.query({ action = 'admin.kick', result = 'error' }).rows), 'admin.kick', 'filters combine with AND')
    local rows = all.rows
    local mid = rows[3].ts
    eq(actions(Audit.query({ from = mid }).rows), 'admin.kick,shop.buy,settings.set', 'filter: from (ms)')
    eq(actions(Audit.query({ to = mid }).rows), 'settings.set,admin.heal,admin.kick', 'filter: to (ms)')
    eq(#Audit.query({ from = BASE_TIME, to = BASE_TIME + 60 }).rows, 5, 'from/to also accept seconds')
    eq(#Audit.query({ from = mid + 1, to = mid - 1 }).rows, 0, 'an empty time range matches nothing')

    -- LIKE wildcards in the filter text are literal, never patterns
    Audit.record({ action = 'lit.row', message = 'rate 100% off_peak' })
    Audit.record({ action = 'lit_row', message = 'plain' })
    eq(actions(Audit.query({ text = '100%' }).rows), 'lit.row', 'text: % is a literal')
    eq(#Audit.query({ text = '0%o' }).rows, 0, 'text: % never matches anything in between')
    eq(actions(Audit.query({ text = 'off_p' }).rows), 'lit.row', 'text: _ is a literal')
    eq(#Audit.query({ text = 'off_' .. 'x' }).rows, 0, 'text: _ never matches any one character')
    eq(actions(Audit.query({ actionPrefix = 'lit_' }).rows), 'lit_row', 'actionPrefix: _ is a literal')
    eq(actions(Audit.query({ actionPrefix = 'lit.' }).rows), 'lit.row', 'actionPrefix: . is a literal')

    -- every query is ONE statement: no per-row reads
    local DB = Core.DB
    local realQuery, realSingle = DB.query, DB.single
    local statements = 0
    DB.query = function(...) statements = statements + 1 return realQuery(...) end
    DB.single = function(...) statements = statements + 1 return realSingle(...) end
    Audit.query({ actionPrefix = 'admin.', text = 'bob', target = { type = 'account', id = 'acc1' }, limit = 200 })
    eq(statements, 1, 'a query with several filters is one SQL statement')
    DB.query, DB.single = realQuery, realSingle

    local seen, pages, cursor = {}, 0, nil
    local all7 = Audit.query({}).rows
    repeat
        local page = Audit.query({ limit = 2, before = cursor })
        pages = pages + 1
        for i = 1, #page.rows do
            check(not seen[page.rows[i].id], 'a row appears on one page only')
            seen[page.rows[i].id] = true
        end
        check(page.next == nil or type(page.next) == 'string', 'the cursor is a string')
        cursor = page.next
    until not cursor or pages > 5
    eq(pages, 4, 'seven rows in pages of two')
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    eq(n, 7, 'paging visits every row')
    eq(#all7, 7, 'the unpaged query sees the same seven')
    eq(#Audit.query({ limit = 2, before = rows[2].id }).rows, 2, 'a row id works as a cursor')
    eq(#Audit.query({ limit = 5, before = tonumber(rows[4].id) }).rows, 1, 'an integer id works as a cursor')
    eq(#Audit.query({ before = 'garbage' }).rows, 0, 'a bad cursor returns nothing')
    eq(#Audit.query({ before = '1790000000123/a1790000000123000' }).rows, 0, 'an old (ts/id) cursor returns nothing')
    eq(#Audit.query({ limit = 0 }).rows, 1, 'limit is clamped to at least 1')
    eq(#Audit.query('junk').rows, 7, 'a non-table filter is an empty filter')
    eq(#Audit.query({ text = string.rep('x', 200) }).rows, 0, 'an unusable filter matches nothing')
    eq(#Audit.query({ action = 5 }).rows, 0, 'a wrongly typed filter matches nothing')
    eq(#Audit.query({ target = { type = 'player' } }).rows, 0, 'a target without id matches nothing')
end

do
    -- persistence across a core restart: a new VM over the same database
    local _, Core = newCore()
    settle()
    for i = 1, 4 do
        Core.Audit.record({ action = 'restart.row' .. i })
        stubs.tick(3)
    end
    local _, Core2 = newCore({ keep = true })
    settle()
    eq(actions(Core2.Audit.query({}).rows), 'restart.row4,restart.row3,restart.row2,restart.row1',
        'the trail reads back in order after a restart')
    Core2.Audit.record({ action = 'restart.new' })
    eq(Core2.Audit.query({ limit = 1 }).rows[1].action, 'restart.new', 'a new row sorts after the reloaded ones')
end

--------------------------------------------------------------------------------
-- Log.audit mirror and webhook routing (no double posts)
--------------------------------------------------------------------------------

do
    local _, Core, ctx = newCore({ convars = { core_webhook_audit = 'https://example.invalid/a',
        core_webhook_audit_denied = 'https://example.invalid/d' } })
    local Audit = Core.Audit
    settle()
    eq(Core.Log.audit('money', 2, 'paid %d', 50), true, 'Log.audit still reports written')
    local row = Audit.query({ action = 'core.money' }).rows[1]
    check(row ~= nil, 'Log.audit records core.<category>')
    eq(row.actor.kind, 'system', 'the Log mirror row is a system row')
    eq(row.targets[1].id, 2, 'the Log mirror row targets the player src')
    eq(row.targets[1].accountId, 'acc2', 'and resolves the account')
    eq(row.message, 'paid 50', 'the formatted message is kept')
    eq(count("SELECT count(*)::int AS n FROM audit_log WHERE action = 'core.money' AND pool = 'log'"), 1,
        'a gameplay Log.audit row is stored in the log pool')
    eq(#ctx.sent, 0, 'a Log.audit row is NOT posted by Audit (webhook.lua posts it from the hook)')
    Core.Log.audit('odd cat!', 0, 'x')
    eq(Audit.query({ limit = 1 }).rows[1].action, 'core.odd_cat_', 'categories are made action-safe')
    eq(Audit.query({ limit = 1 }).rows[1].targets, nil, 'src 0 adds no target')

    Audit.record({ actor = 1, action = 'admin.kick' })
    eq(#ctx.sent, 1, 'an ok row is posted once')
    eq(ctx.sent[1].name, 'audit', 'to the audit webhook')
    eq(ctx.sent[1].embed.title, 'admin.kick', 'the embed title is the action')
    Audit.record({ actor = 1, action = 'admin.kick', result = 'denied' })
    eq(#ctx.sent, 3, 'a denied row goes to audit AND audit_denied')
    eq(ctx.sent[3].name, 'audit_denied', 'the second post is audit_denied')
    Audit.record({ actor = 1, action = 'admin.kick', result = 'error' })
    eq(#ctx.sent, 3, 'an error row is not posted')
    ctx.convars.core_webhook_audit = nil
    Audit.record({ action = 'quiet.row' })
    eq(#ctx.sent, 3, 'no convar, no post')
end

do
    -- the real webhook.lua: one Log.audit line becomes exactly ONE embed on the wire
    local posted = {}
    local env, Core = newCore({
        fakeWebhook = false,
        convars = { core_webhook_audit = 'https://example.invalid/a' },
        before = function(_, C)
            C.Http = { fetch = function(_, opts)
                for i = 1, #opts.body.embeds do posted[#posted + 1] = opts.body.embeds[i] end
                return 204
            end }
        end,
    })
    stubs.loadFile(env, 'server/webhook.lua')
    settle()
    Core.Log.audit('money', 2, 'paid %d', 50)
    stubs.tick(2500)
    eq(#posted, 1, 'a Log.audit line is posted exactly once (hook only)')
    eq(posted[1] and posted[1].title, 'audit: money', 'and it is the hook embed')
    Core.Audit.record({ actor = 1, action = 'admin.kick' })
    stubs.tick(2500)
    eq(#posted, 2, 'a plain Audit.record row is posted once')
    eq(posted[2] and posted[2].title, 'admin.kick', 'by Audit')
    eq(#stubs.failures, 0, 'no thread errors with the real webhook module')
end

--------------------------------------------------------------------------------
-- retention: days, maxRows, the sanction./ban. exemption, auto prune, cron + settings wiring
--------------------------------------------------------------------------------

do
    local settings = { ['audit.retentionDays'] = 1, ['audit.maxRows'] = 5 }
    local _, Core, ctx = newCore({ settings = settings })
    local Audit = Core.Audit
    settle()
    for i = 1, 8 do Audit.record({ action = 'test.row' .. i }) stubs.tick(2) end
    for i = 1, 3 do Audit.record({ action = 'ban.add', message = 'b' .. i }) stubs.tick(2) end
    for i = 1, 2 do Audit.record({ action = 'sanction.warn' }) stubs.tick(2) end
    eq(count("SELECT count(*)::int AS n FROM audit_log WHERE pool = 'exempt'"), 5, 'ban.* / sanction.* rows are stored as exempt')
    eq(Audit.prune(), 3, 'maxRows drops the oldest non-exempt rows')
    eq(actions(Audit.query({ actionPrefix = 'test.' }).rows), 'test.row8,test.row7,test.row6,test.row5,test.row4',
        'the newest maxRows rows stay')
    eq(#Audit.query({ actionPrefix = 'ban.' }).rows, 3, 'ban.* is exempt from maxRows')
    eq(#Audit.query({ actionPrefix = 'sanction.' }).rows, 2, 'sanction.* is exempt from maxRows')
    eq(Core.DB.count('audit_log'), 10, 'pruned rows are deleted from the table')
    eq(Audit.prune(), 0, 'a second prune finds nothing to do')

    stubs.osTime = BASE_TIME + 2 * 86400
    Audit.record({ action = 'fresh.row' })
    eq(Audit.prune(), 5, 'rows older than retentionDays go')
    eq(actions(Audit.query({ actionPrefix = 'test.' }).rows), '', 'no old non-exempt row is left')
    eq(#Audit.query({ actionPrefix = 'ban.' }).rows, 3, 'exempt rows live retentionDays x 4')
    eq(#Audit.query({ action = 'fresh.row' }).rows, 1, 'a fresh row stays')
    stubs.osTime = BASE_TIME + 5 * 86400
    Audit.prune()
    eq(#Audit.query({ actionPrefix = 'ban.' }).rows, 0, 'exempt rows go after retentionDays x 4')
    eq(#Audit.query({ actionPrefix = 'sanction.' }).rows, 0, 'sanction rows too')

    -- far past maxRows + slack: a prune is scheduled by record itself
    for i = 1, 510 do Audit.record({ action = 'flood.row', message = tostring(i) }) end
    stubs.tick(1500)
    eq(#Audit.query({ action = 'flood.row', limit = 200 }).rows, 5, 'record schedules a prune past the slack')
    eq(Audit.query({ action = 'flood.row' }).rows[1].message, '510', 'the newest rows survive it')

    eq(#ctx.settingsHandlers, 1, 'a settings change handler is registered')
    eq(ctx.settingsHandlers[1] and ctx.settingsHandlers[1].prefix, 'audit.', 'for the audit.* keys')
    settings['audit.maxRows'] = 2
    ctx.settingsHandlers[1].fn('audit.maxRows', 2, 5)
    stubs.tick(1500)
    eq(#Audit.query({ action = 'flood.row' }).rows, 2, 'a settings change re-prunes')

    local job
    for _, entry in ipairs(Core.Cron.list()) do
        if entry.expr == '30 4 * * *' then job = entry end
    end
    check(job ~= nil and job.owner == 'core', 'the daily prune is a core Cron job at 04:30')

    -- a database failure stops the pass (logged), never throws, and the next pass finishes the job
    for i = 1, 4 do Audit.record({ action = 'flood.row', message = 'late' .. i }) end
    bridge.fail('DELETE FROM audit_log', 'XX000 simulated failure')
    eq(Audit.prune(), 0, 'a failing prune removes nothing and answers 0')
    bridge.unfail()
    eq(Audit.prune(), 4, 'the next prune removes what is due')
    eq(#stubs.failures, 0, 'no thread errors while pruning')
end

do
    -- R2-6: Log.audit rows of gameplay categories live in their own pool and never evict the admin trail
    local settings = { ['audit.retentionDays'] = 30, ['audit.maxRows'] = 6, ['audit.logMaxRows'] = 3 }
    local _, Core = newCore({ settings = settings })
    local Audit = Core.Audit
    settle()
    for i = 1, 5 do Audit.record({ action = 'admin.kick', message = 'k' .. i }) stubs.tick(2) end
    Core.Log.audit('perms', 1, 'group set')
    for i = 1, 12 do Core.Log.audit('money', 2, 'paid %d', i) stubs.tick(2) end
    Audit.prune()
    eq(#Audit.query({ action = 'core.money' }).rows, 3, 'the log pool keeps audit.logMaxRows rows')
    eq(Audit.query({ action = 'core.money' }).rows[1].message, 'paid 12', 'the newest log rows stay')
    eq(#Audit.query({ action = 'admin.kick' }).rows, 5, 'gameplay log rows never evict the admin trail')
    eq(#Audit.query({ action = 'core.perms' }).rows, 1, 'a staff Log.audit category is kept in the main pool')
    for i = 1, 3 do Audit.record({ action = 'admin.heal' }) stubs.tick(2) end
    Audit.prune()
    eq(#Audit.query({ actionPrefix = 'admin.' }).rows + #Audit.query({ action = 'core.perms' }).rows, 6,
        'the main pool is capped by audit.maxRows on its own')
    eq(#Audit.query({ action = 'core.money' }).rows, 3, 'and that never touches the log pool')

    -- the log pool overflows on its own: a prune is scheduled past logMaxRows + slack
    for i = 1, 510 do Audit.record({ action = 'core.money', message = tostring(i) }) end
    stubs.tick(1500)
    eq(#Audit.query({ action = 'core.money', limit = 200 }).rows, 3, 'the log pool schedules its own prune')
    eq(#Audit.query({ actionPrefix = 'admin.' }).rows, 5, 'the admin trail is untouched by that prune')

    -- core's legacy staff commands (core.cmd.<name>, §4.8) are staff actions: main pool, never the log pool
    Audit.record({ action = 'core.cmd.kick', message = 'legacy kick' })
    eq(count("SELECT count(*)::int AS n FROM audit_log WHERE action = 'core.cmd.kick' AND pool = 'main'"), 1,
        'core.cmd.* is stored in the main pool')
    for i = 1, 510 do Audit.record({ action = 'core.money', message = 'x' .. i }) end
    stubs.tick(1500)
    eq(#Audit.query({ action = 'core.cmd.kick' }).rows, 1, 'a legacy command row survives a log-pool prune')

    -- rate cap: <= 20 gameplay rows a category and second, the rest counted into the next row
    stubs.tick(1000)
    local before = #Audit.query({ action = 'core.shop', limit = 200 }).rows
    for i = 1, 25 do Core.Log.audit('shop', 2, 'sold %d', i) end
    eq(#Audit.query({ action = 'core.shop', limit = 200 }).rows - before, 20, 'at most 20 rows a second per category')
    eq(Audit.recordLog('shop', 2, 'over the cap'), nil, 'a capped recordLog answers nil')
    stubs.tick(1000)
    Core.Log.audit('shop', 2, 'sold later')
    local latest = Audit.query({ action = 'core.shop', limit = 1 }).rows[1]
    eq(latest and latest.ctx and latest.ctx.suppressed, 6, 'the next row carries the suppressed count')
    eq(latest and latest.message, 'sold later', 'and is the row written after the cap')
    for i = 1, 25 do Core.Log.audit('player', 1, 'kicked %d', i) end
    eq(#Audit.query({ action = 'core.player', limit = 200 }).rows, 25, 'staff categories are never rate capped')
    eq(#stubs.failures, 0, 'no thread errors with two pools')
end

do
    -- R2-9: only the registrant (or core) removes a Cron job
    local env, Core = newCore()
    settle()
    local coreJob
    for _, job in ipairs(Core.Cron.list()) do
        if job.expr == '30 4 * * *' then coreJob = job.id end
    end
    check(coreJob ~= nil, 'the audit retention job exists')
    eq(stubs.exports.core.call('rogue', 'Cron', 'remove', coreJob), false, "a plugin cannot remove core's job")
    local own = stubs.exports.core.call('rogue', 'Cron', 'every', 60000, function() end)
    check(own ~= nil, 'a plugin registers its own job')
    eq(stubs.exports.core.call('other', 'Cron', 'remove', own), false, "nor another plugin's job")
    eq(stubs.exports.core.call('rogue', 'Cron', 'remove', own), true, 'but its own')
    local mine = stubs.exports.core.call('rogue', 'Cron', 'every', 60000, function() end)
    eq(Core.Cron.remove(mine), true, 'core itself may remove any job')
    local swept = stubs.exports.core.call('rogue', 'Cron', 'every', 60000, function() end)
    stubs.triggerOn(env, 'onResourceStop', 0, 'rogue')
    local left = false
    for _, job in ipairs(Core.Cron.list()) do
        if job.id == swept then left = true end
    end
    check(swept ~= nil and not left, "the owner-stop sweep still removes a stopped plugin's jobs")
    local still = false
    for _, job in ipairs(Core.Cron.list()) do
        if job.id == coreJob then still = true end
    end
    check(still, "core's job survives all of it")
end

do
    -- no prune while Core.Settings has not loaded its overrides: every limit read then is a DEFAULT, and a prune
    -- with defaults would delete rows an admin configured to keep (ban.* history included) — skipped, retried
    local settings = { ['audit.retentionDays'] = 1, ['audit.maxRows'] = 5 }
    local ready = false
    local _, Core = newCore({ settings = settings, before = function(_, C)
        C.Settings.isLoaded = function() return ready end
    end })
    local Audit = Core.Audit
    settle()
    for i = 1, 8 do Audit.record({ action = 'guard.row' .. i }) stubs.tick(2) end
    Audit.record({ action = 'ban.add', message = 'history' })
    stubs.osTime = BASE_TIME + 400 * 86400          -- past every default retention (90 d, exempt 360 d)
    eq(Audit.prune(), 0, 'no prune while the settings are not loaded')
    eq(Core.DB.count('audit_log'), 9, 'every row is kept (a default-limit prune would have deleted all of them)')
    local skipped = false
    for i = 1, #stubs.printed do
        if stubs.printed[i]:find('prune skipped', 1, true) then skipped = true end
    end
    check(skipped, 'the skipped prune is logged')
    ready = true
    stubs.tick(61000)
    eq(Core.DB.count('audit_log'), 0, 'the rescheduled prune runs with the loaded limits once they are in')
    eq(#stubs.failures, 0, 'no thread errors in the guarded prune')
end

do
    -- without Core.Settings: the defaults (90 days, 50000 rows)
    local _, Core = newCore()
    settle()
    Core.Audit.record({ action = 'x.old' })
    stubs.osTime = BASE_TIME + 89 * 86400
    eq(Core.Audit.prune(), 0, 'a row younger than 90 days stays by default')
    stubs.osTime = BASE_TIME + 91 * 86400
    eq(Core.Audit.prune(), 1, 'and goes after 90 days')
end

--------------------------------------------------------------------------------
-- a plugin VM: Log.audit reaches Core.Audit through the export proxy, and never throws
--------------------------------------------------------------------------------

do
    local _, Core = newCore()
    settle()
    local plugin = stubs.newEnv('server', 'shopkeeper')
    local PluginCore = stubs.loadImport(plugin)
    eq(PluginCore.Log.audit('shop', 2, 'bought %s', 'bread'), true, 'a plugin Log.audit still writes')
    local row = Core.Audit.query({ action = 'core.shop' }).rows[1]
    check(row ~= nil, 'the plugin line is recorded in core')
    eq(row and row.resource, 'shopkeeper', 'with the plugin as resource')
    eq(row and row.source, 'api', 'and source api')
    stubs.resourceStates.core = 'stopped'
    local ok = pcall(PluginCore.Log.audit, 'shop', 2, 'offline')
    check(ok, 'Log.audit never throws while core is stopped')
    stubs.resourceStates.core = 'started'
    stubs.exports.core = nil
    ok = pcall(PluginCore.Log.audit, 'shop', 2, 'no export')
    check(ok, 'Log.audit never throws when core has no export')
end

do
    -- core without server/audit.lua: Log.audit stays a print + hook
    stubs.resetServer()
    stubs.newWorld()
    stubs.clear()
    local env = stubs.newEnv('server', 'core')
    local Core = stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    local ok, written = pcall(Core.Log.audit, 'money', 1, 'x')
    check(ok and written == true, 'Log.audit works in a core without Core.Audit')
end

print(('audit: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
