--[[
    core/tests/audit_tests.lua — offline contract of Core.Audit (DESIGN §46) and the Log.audit mirror.

        lua5.4 tests/audit_tests.lua    (from the resource directory, or from tests/)

    One core server VM per case: import.lua, shared/config.lua, server/api.lua, server/db.lua, a FAKE
    Core.Player / Core.Settings / Core.Webhook (so this suite does not depend on player.lua or the HTTP
    stack), then server/cron.lua and server/audit.lua. Exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/audit_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

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

--- A fresh core VM. opts = { settings = { [key] = value }, convars = {}, before = fn(env, Core) }
local function newCore(opts)
    opts = opts or {}
    stubs.resetServer()
    stubs.newWorld()
    stubs.clear()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
    stubs.exports.core = nil
    stubs.resourceStates.core = 'started'
    stubs.osTime = BASE_TIME
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
    stubs.loadFile(env, 'server/db.lua')

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

--- Runs the start thread (it Waits one tick before it loads the index).
local function settle(ms)
    stubs.tick(ms or 10)
end

local function actions(rows)
    local out = {}
    for i = 1, #rows do out[i] = rows[i].action end
    return table.concat(out, ',')
end

--------------------------------------------------------------------------------
-- record: normalisation, bounds, actor and target resolution
--------------------------------------------------------------------------------

do
    local _, Core = newCore()
    local Audit = Core.Audit
    settle()
    local id = Audit.record({
        actor = 1, action = 'admin.kick', source = 'menu', reason = 'spam', message = 'kicked Bob',
        targets = { { type = 'player', id = 2 }, 3 }, changes = { { key = 'hp', old = 100, new = 0 } },
        ctx = { radius = 5, nested = { a = 1 } },
    })
    check(type(id) == 'string' and id:match('^a%d+$') ~= nil, 'record returns a sortable id')
    local row = Audit.get(id)
    check(row ~= nil, 'the row is stored')
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

    local console = Audit.get(Audit.record({ actor = 0, action = 'x.y' }))
    eq(console.actor.kind, 'console', 'actor 0 is the console')
    local system = Audit.get(Audit.record({ action = 'x.y', source = 'bogus', result = 'nope' }))
    eq(system.actor.kind, 'system', 'no actor is the system')
    eq(system.source, 'core', 'an unknown source falls back to the caller kind')
    eq(system.result, 'ok', 'an unknown result falls back to ok')

    local long = string.rep('m', 700)
    local targets, changes = {}, {}
    for i = 1, 40 do targets[i] = { type = 'entity', id = i } end
    for i = 1, 70 do changes[i] = { 'k' .. i, string.rep('o', 300), { deep = string.rep('n', 300) } } end
    local bounded = Audit.get(Audit.record({ action = 'bulk.edit', message = long, reason = long,
        targets = targets, changes = changes }))
    eq(#bounded.message, 512, 'message is bounded to 512')
    eq(#bounded.reason, 256, 'reason is bounded to 256')
    eq(#bounded.targets, 32, 'targets are bounded to 32')
    eq(#bounded.changes, 64, 'changes are bounded to 64')
    eq(bounded.changes[1].key, 'k1', 'positional changes are read')
    eq(#bounded.changes[1].old, 256, 'string values are bounded to 256')
    check(#bounded.changes[1].new <= 256, 'table values are stringified and bounded')
    local utf = Audit.get(Audit.record({ action = 'x.utf', message = string.rep('a', 511) .. 'é' }))
    check(utf8.len(utf.message) ~= nil, 'a bound never cuts a UTF-8 sequence')
    local stripped = Audit.get(Audit.record({ action = 'x.ctl', message = 'a\nb\0c' }))
    eq(stripped.message, 'abc', 'control characters are stripped')

    eq(Audit.record(nil), nil, 'record(nil) is refused')
    eq(Audit.record({ action = 'bad action!' }), nil, 'an invalid action is refused')
    eq(Audit.record({ action = string.rep('a', 65) }), nil, 'an over-long action is refused')
    check(Audit.record({ action = 'x.z', targets = 'no', changes = 5, ctx = 'y', actor = {} }) ~= nil,
        'junk optional fields never throw')
    local a, b = Audit.record({ action = 'same.ms' }), Audit.record({ action = 'same.ms' })
    check(a ~= b and a < b, 'two rows in the same millisecond get increasing ids')
    eq(#stubs.failures, 0, 'no thread errors')
end

--------------------------------------------------------------------------------
-- rows recorded before the start thread loaded the index are queued, then stored
--------------------------------------------------------------------------------

do
    local _, Core = newCore()
    local Audit = Core.Audit
    local early = Audit.record({ actor = 2, action = 'early.row' })
    check(early ~= nil, 'record works before the index is loaded')
    eq(Core.DB.count('audit'), 0, 'nothing is written before the load')
    eq(Audit.get(early).action, 'early.row', 'a queued row is readable by id')
    settle()
    eq(Core.DB.count('audit'), 1, 'the queued row is stored once the index loaded')
    eq(#Audit.query({}).rows, 1, 'and it is indexed')
end

--------------------------------------------------------------------------------
-- query: newest first, filters, cursor paging, the index survives a restart
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
    eq(actions(Audit.query({ target = { type = 'account', id = 'acc1' } }).rows), 'admin.kick,admin.heal',
        'filter: a player target is also found by its account')
    eq(actions(Audit.query({ target = { type = 'setting', id = 'maps.max' } }).rows), 'settings.set', 'filter: other target types')
    local shop = Audit.query({ resource = 'shop' }).rows
    eq(#shop, 1, 'filter: resource (a plugin call through the export)')
    eq(shop[1].source, 'api', 'a plugin row defaults to source api')
    eq(actions(Audit.query({ result = 'denied' }).rows), 'admin.heal', 'filter: result')
    eq(actions(Audit.query({ text = 'spam' }).rows), 'admin.kick', 'filter: text is case-insensitive')
    eq(#Audit.query({ text = 'bob' }).rows, 3, 'filter: text matches actor and target names')
    local rows = all.rows
    local mid = rows[3].ts
    eq(actions(Audit.query({ from = mid }).rows), 'admin.kick,shop.buy,settings.set', 'filter: from (ms)')
    eq(actions(Audit.query({ to = mid }).rows), 'settings.set,admin.heal,admin.kick', 'filter: to (ms)')
    eq(#Audit.query({ from = BASE_TIME, to = BASE_TIME + 60 }).rows, 5, 'from/to also accept seconds')

    local seen, pages, cursor = {}, 0, nil
    repeat
        local page = Audit.query({ limit = 2, before = cursor })
        pages = pages + 1
        for i = 1, #page.rows do
            check(not seen[page.rows[i].id], 'a row appears on one page only')
            seen[page.rows[i].id] = true
        end
        cursor = page.next
    until not cursor or pages > 5
    eq(pages, 3, 'five rows in pages of two')
    local count = 0
    for _ in pairs(seen) do count = count + 1 end
    eq(count, 5, 'paging visits every row')
    eq(#Audit.query({ limit = 2, before = rows[2].id }).rows, 2, 'a bare row id works as a cursor')
    eq(#Audit.query({ before = 'garbage' }).rows, 0, 'a bad cursor returns nothing')
    eq(#Audit.query({ limit = 0 }).rows, 1, 'limit is clamped to at least 1')
    eq(#Audit.query('junk').rows, 5, 'a non-table filter is an empty filter')
    eq(#Audit.query({ text = string.rep('x', 200) }).rows, 0, 'an unusable filter matches nothing')
    eq(#Audit.query({ action = 5 }).rows, 0, 'a wrongly typed filter matches nothing')
    eq(#Audit.query({ target = { type = 'player' } }).rows, 0, 'a target without id matches nothing')
end

do
    -- persistence across a core restart WITHOUT wiping KVP
    local _, Core = newCore()
    settle()
    for i = 1, 4 do
        Core.Audit.record({ action = 'restart.row' .. i })
        stubs.tick(3)
    end
    Core.DB.flush()
    local kvp = stubs.kvp
    local _, Core2 = newCore({ before = function() for k, v in pairs(kvp) do stubs.kvp[k] = v end end })
    settle()
    eq(actions(Core2.Audit.query({}).rows), 'restart.row4,restart.row3,restart.row2,restart.row1',
        'the index is rebuilt in order after a restart')
    local newer = Core2.Audit.record({ action = 'restart.new' })
    eq(Core2.Audit.query({ limit = 1 }).rows[1].id, newer, 'a new row sorts after the reloaded ones')
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
    eq(Audit.prune(), 3, 'maxRows drops the oldest non-exempt rows')
    eq(actions(Audit.query({ actionPrefix = 'test.' }).rows), 'test.row8,test.row7,test.row6,test.row5,test.row4',
        'the newest maxRows rows stay')
    eq(#Audit.query({ actionPrefix = 'ban.' }).rows, 3, 'ban.* is exempt from maxRows')
    eq(#Audit.query({ actionPrefix = 'sanction.' }).rows, 2, 'sanction.* is exempt from maxRows')
    eq(Core.DB.count('audit'), 10, 'pruned rows are deleted from the collection')

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
    for i = 1, 510 do Audit.record({ action = 'core.money', message = 'x' .. i }) end
    stubs.tick(1500)
    eq(#Audit.query({ action = 'core.cmd.kick' }).rows, 1, 'a legacy command row survives a log-pool prune')

    -- rate cap: <= 20 gameplay rows a category and second, the rest counted into the next row
    stubs.tick(1000)
    local before = #Audit.query({ action = 'core.shop', limit = 200 }).rows
    for i = 1, 25 do Core.Log.audit('shop', 2, 'sold %d', i) end
    eq(#Audit.query({ action = 'core.shop', limit = 200 }).rows - before, 20, 'at most 20 rows a second per category')
    stubs.tick(1000)
    Core.Log.audit('shop', 2, 'sold later')
    local latest = Audit.query({ action = 'core.shop', limit = 1 }).rows[1]
    eq(latest and latest.ctx and latest.ctx.suppressed, 5, 'the next row carries the suppressed count')
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
