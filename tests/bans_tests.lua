--[[
    core/tests/bans_tests.lua — offline contract of Core.Bans (DESIGN §47, §56).

        lua5.4 tests/bans_tests.lua    (from the resource directory, or from tests/)

    One core server VM per case: import.lua, shared/config.lua, server/api.lua, server/db.lua, a FAKE
    Core.Player (sessions, getPlayers, setAccountData, findAccountsByIdentifier = getters.lua's query), a fake
    Core.Perms (the §44 weights), then server/cron.lua, server/audit.lua, server/bans_identity.lua and
    server/bans.lua. The bans, accounts and link rows live in the Postgres test database (DESIGN §56.10:
    tests/pgbridge.lua; every call is synchronous from here, queued writes land at once). The identity natives
    (GetNumPlayerIdentifiers/GetPlayerIdentifier/GetNumPlayerTokens/GetPlayerToken) are stubbed from a per-src
    table. The v1 ban shape is imported by core's SQL (sql/0002) — the first case feeds it a `core_documents`
    table after bridge.recreate(). Exit code 1 on failure.
]]

local here = (arg and arg[0] or 'tests/bans_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
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
local function has(list, value)
    for i = 1, #(list or {}) do
        if list[i] == value then return true end
    end
    return false
end

--- rows of a direct query (as the invoker `tests`); raises on an error so a broken fixture is loud.
local function sql(text, params)
    local rows, err = bridge.sql(text, params)
    if not rows then error('sql: ' .. tostring(err), 2) end
    return rows
end

local BASE_TIME <const> = 1790000000

--- A fresh core VM. opts.settings = true also loads the real server/settings.lua (the bans.* section);
--- opts.before() runs after the database reset and before any core file loads (fixtures, recreate);
--- opts.restart = true keeps the database (a core restart: nothing is reset).
local function newCore(opts)
    opts = opts or {}
    if not opts.restart then stubs.resetServer() end
    stubs.newWorld()
    stubs.clear()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
    stubs.exports.core = nil
    stubs.osTime = BASE_TIME
    stubs.tick(1000)
    if opts.before then opts.before() end
    local env = stubs.newEnv('server', 'core')
    env.GetConvar = function(_, fallback) return fallback end
    local identity = {}
    env.GetNumPlayerIdentifiers = function(src) local p = identity[tonumber(src)] return p and #p.ids or 0 end
    env.GetPlayerIdentifier = function(src, i) local p = identity[tonumber(src)] return p and p.ids[i + 1] or nil end
    env.GetNumPlayerTokens = function(src) local p = identity[tonumber(src)] return p and #p.tokens or 0 end
    env.GetPlayerToken = function(src, i) local p = identity[tonumber(src)] return p and p.tokens[i + 1] or nil end

    local Core = stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, 'server/api.lua')
    stubs.loadFile(env, 'server/db.lua')
    local sessions, accountWrites = {}, {}
    Core.Player = {
        getInfo = function(src)
            local s = sessions[src]
            if not s then return nil end
            return { src = src, accountId = s.accountId, name = s.name, group = s.group or 'user' }
        end,
        getPlayers = function()
            local out = {}
            for src in pairs(sessions) do out[#out + 1] = src end
            table.sort(out)
            return out
        end,
        setAccountData = function(src, key, value)
            accountWrites[#accountWrites + 1] = { src = src, key = key, value = value }
            return true
        end,
        -- server/getters.lua's query (one indexed statement per identifier)
        findAccountsByIdentifier = function(identifier)
            local rows = Core.DB.query('SELECT account_id AS id FROM account_identifiers WHERE identifier = $1 '
                .. 'UNION SELECT id FROM accounts WHERE license = $1', { identifier }, { sync = true })
            if not rows then return nil, 'unavailable' end
            local out = {}
            for i = 1, #rows do out[i] = rows[i].id end
            table.sort(out)
            return out
        end,
    }
    -- a Perms stand-in with the §44 weights: getWeight / canTarget / groups
    local WEIGHTS = { user = 0, helper = 100, mod = 200, admin = 300, senior = 400, owner = 1000 }
    local function weightOf(src)
        if src == 0 then return math.huge end
        local s = sessions[src]
        return s and WEIGHTS[s.group or 'user'] or 0
    end
    Core.Perms = {
        getWeight = weightOf,
        canTarget = function(actor, target)
            if actor == 0 or actor == target then return true end
            if weightOf(actor) > weightOf(target) then return true end
            return false, 'rank'
        end,
        groups = function()
            local out = {}
            for name, weight in pairs(WEIGHTS) do out[#out + 1] = { name = name, weight = weight } end
            return out
        end,
    }
    if opts.settings then stubs.loadFile(env, 'server/settings.lua') end
    if opts.store then stubs.loadFile(env, 'server/player_store.lua') end
    stubs.loadFile(env, 'server/cron.lua')
    stubs.loadFile(env, 'server/audit.lua')
    stubs.loadFile(env, 'server/bans_identity.lua')
    stubs.loadFile(env, 'server/bans.lua')
    local h = { env = env, identity = identity, sessions = sessions, accountWrites = accountWrites }

    --- An accounts row (+ account_identifiers { kind = identifier }), the way a join stores it. → id
    function h.account(id, license, name, group, identifiers)
        sql('INSERT INTO accounts (id, license, name, perm_group) VALUES ($1, $2, $3, $4)',
            { id, license, name or '', group or 'user' })
        for kind, value in pairs(identifiers or {}) do
            sql('INSERT INTO account_identifiers (account_id, kind, identifier) VALUES ($1, $2, $3)', { id, kind, value })
        end
        return id
    end

    --- accounts.banned of one account (the stored row).
    function h.banned(id)
        local row = sql('SELECT banned FROM accounts WHERE id = $1', { id })[1]
        return row and row.banned
    end

    --- Simulates a connected player: identity + name (+ a loaded session and its accounts row when accountId is
    --- given) and the playerJoining event (bans_identity.lua's online index).
    function h.connect(src, ids, tokens, name, accountId, group)
        identity[src] = { ids = ids or {}, tokens = tokens or {} }
        stubs.playerNames[src] = name or ('P' .. src)
        if accountId then
            sessions[src] = { accountId = accountId, name = name or ('P' .. src), group = group }
            local license = 'license:' .. accountId
            for i = 1, #(ids or {}) do
                if ids[i]:sub(1, 8) == 'license:' then license = ids[i] break end
            end
            sql('INSERT INTO accounts (id, license, name, perm_group) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING',
                { accountId, license, name or ('P' .. src), group or 'user' })
        end
        stubs.triggerOn(env, 'playerJoining', src, src)
    end

    --- The player leaves: playerDropped, identity and session gone.
    function h.drop(src)
        stubs.triggerOn(env, 'playerDropped', src, 'quit')
        identity[src], sessions[src], stubs.playerNames[src] = nil, nil, nil
    end

    --- Records every core_db call of this VM: { fn, args } (lib/db/server.lua reads the raw `synchronous`).
    function h.spy()
        local real = rawget(env.exports, 'core_db')
        local log = {}
        rawset(env.exports, 'core_db', setmetatable({ synchronous = rawget(real, 'synchronous') }, {
            __index = function(t, fnName)
                local fn = function(_, ...)
                    log[#log + 1] = { fn = fnName, args = table.pack(...) }
                    return real[fnName](real, ...)
                end
                rawset(t, fnName, fn)
                return fn
            end,
        }))
        return log, function() rawset(env.exports, 'core_db', real) end
    end
    return Core, h
end

local function settle()
    stubs.tick(10)
end

local function lastDrop()
    return stubs.dropped[#stubs.dropped]
end

--- The calls of one kind in a spy log.
local function calls(log, fn)
    local out = {}
    for i = 1, #log do
        if log[i].fn == fn then out[#out + 1] = log[i] end
    end
    return out
end

--------------------------------------------------------------------------------
-- the v1 shape (server/player.lua before §47) and the R2-12 relink marker: core's SQL import (sql/0002)
--------------------------------------------------------------------------------

do
    local json = stubs.json
    local docs = {
        { 'bans', 'old1', { license = 'license:old1', reason = 'cheating', by = 'AdminAnna', ['until'] = 0,
            createdAt = BASE_TIME - 100 } },
        { 'bans', 'old2', { license = 'license:old2', reason = 'toxic', by = 'console', ['until'] = BASE_TIME + 3600 } },
        { 'bans', 'old3', { license = 'license:old3', reason = 'past', ['until'] = BASE_TIME - 10 } },
        -- a v2 document the old Lua migration wrote while `accounts` was unreadable (review R2-12)
        { 'bans', 'rl1', { _v = 2, name = 'unknown', identifiers = { 'license:rl' }, tokens = { '2:rl' },
            relink = 'license:rl', reason = 'relinked', by = { name = 'Bob' }, expiresAt = 0,
            createdAt = BASE_TIME - 50, hits = 3 } },
        { 'accounts', 'accOld', { license = 'license:old1', name = 'Old One', banned = true } },
        { 'accounts', 'accRl', { license = 'license:rl', name = 'Rel Ink', banned = false } },
        { 'counters', 'bans', { value = 7 } },
    }
    local Core = newCore({ before = function()
        bridge.recreate()   -- an empty schema: core's migrations run again, 0002 finds core_documents
        sql('CREATE TABLE core_documents (collection text NOT NULL, id text NOT NULL, data jsonb NOT NULL, '
            .. 'updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (collection, id))')
        for i = 1, #docs do
            sql('INSERT INTO core_documents (collection, id, data) VALUES ($1, $2, $3::jsonb)',
                { docs[i][1], docs[i][2], json.encode(docs[i][3]) })
        end
    end })
    eq(Core.DB.awaitMigrations(), true, "core's migrations (the legacy import included) applied")
    eq(sql("SELECT to_regclass('legacy_documents') IS NOT NULL AS renamed")[1].renamed, true,
        'core_documents was renamed to legacy_documents')
    settle()
    local ban = Core.Bans.get('old1')
    check(ban ~= nil, 'a v1 ban survives the import')
    eq(ban._v, 2, 'it reads back in the v2 shape')
    eq(ban.identifiers and ban.identifiers[1], 'license:old1', 'license -> identifiers')
    eq(#(ban.tokens or { 0 }), 0, 'tokens start empty')
    eq(ban.expiresAt, 0, 'until 0 -> expiresAt 0 (permanent)')
    eq(ban.by and ban.by.name, 'AdminAnna', 'by string -> by.name')
    eq(ban.accountId, 'accOld', 'the account behind the license is found')
    check(has(ban.accountIds, 'accOld'), 'and listed in accountIds')
    eq(ban.name, 'Old One', "a nameless v1 ban takes its account's name (as the old Lua migration did)")
    eq(ban.license, nil, 'the old license field is gone')
    eq(ban['until'], nil, 'the old until field is gone')
    eq(ban.hits, 0, 'hits start at 0')
    eq(ban.createdAt, BASE_TIME - 100, 'createdAt is kept')
    eq(Core.Bans.get('old2').expiresAt, BASE_TIME + 3600, 'a temporary v1 ban keeps its expiry')
    eq(Core.Bans.get('old2').name, 'unknown', 'a ban without an account is named unknown')
    eq(Core.Bans.check({ 'license:old1' }).id, 'old1', 'an imported permanent ban hits')
    eq(Core.Bans.check({ 'license:old2' }).id, 'old2', 'an imported temporary ban hits')
    eq(Core.Bans.check({ 'license:old3' }), nil, 'an expired v1 ban does not hit')
    eq(Core.Bans.get('old3').expiresAt, BASE_TIME - 10, 'but it is kept for history')
    local relinked = Core.Bans.get('rl1')
    eq(relinked and relinked.accountId, 'accRl', 'R2-12: the start sweep links the relink marker to its account')
    eq(relinked and relinked.relink, nil, 'and the marker is gone')
    eq(relinked and relinked.name, 'Rel Ink', 'the ban takes the account name')
    eq(relinked and relinked.hits, 3, 'the imported hits are kept')
    check(relinked and has(relinked.tokens, '2:rl'), 'and the imported tokens')
    eq(sql("SELECT banned FROM accounts WHERE id = 'accRl'")[1].banned, true, 'the account of an active ban is flagged')
    eq(#Core.Bans.forAccount('accRl'), 1, 'forAccount finds the relinked ban')
    eq(Core.Bans.add({ target = { identifiers = { 'license:after' } } }).id, 'B8',
        'the ban sequence continues after the imported counters/bans value')
end

--------------------------------------------------------------------------------
-- add (online), the kick, audit, account flag, ip: never stored, check by token
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    settle()
    h.connect(5, { 'license:aaa', 'discord:111', 'ip:1.2.3.4', 'fivem:55' }, { '2:abc', '3:def' }, 'Five', 'acc5')
    h.connect(1, { 'license:admin' }, {}, 'Admin', 'accAdmin', 'admin')
    local ban, err = Core.Bans.add({ target = 5, reason = 'aimbot', duration = 3600, by = 1, evidence = 'clip.mp4',
        source = 'menu' })
    check(ban ~= nil, 'an online player is banned', tostring(err))
    eq(ban.id, 'B1', 'ban ids are short and sequential (the sequence)')
    eq(ban.accountId, 'acc5', 'the account is recorded')
    eq(ban.name, 'Five', 'the name is recorded')
    check(has(ban.identifiers, 'license:aaa') and has(ban.identifiers, 'discord:111'), 'identifiers are collected')
    check(not has(ban.identifiers, 'ip:1.2.3.4'), 'ip: is never stored')
    check(has(ban.tokens, '2:abc') and has(ban.tokens, '3:def'), 'tokens are collected')
    eq(ban.expiresAt, BASE_TIME + 3600, 'duration -> expiresAt')
    eq(ban.by.accountId, 'accAdmin', 'by src -> by.accountId')
    eq(ban.by.name, 'Admin', 'by src -> by.name')
    eq(ban.evidence, 'clip.mp4', 'evidence is kept')
    eq(ban._v, 2, 'a new ban carries _v = 2')
    eq(lastDrop() and lastDrop().src, 5, 'the online target is kicked')
    check(lastDrop() and lastDrop().reason:find('You are banned until', 1, true) ~= nil, 'with the ban text')
    check(lastDrop() and lastDrop().reason:find('(ban B1)', 1, true) ~= nil, 'naming the ban id')
    local write = h.accountWrites[#h.accountWrites]
    check(write and write.src == 5 and write.key == 'banned' and write.value == true,
        'account.banned goes through Player.setAccountData while online')
    eq(h.banned('acc5'), true, 'and the row is flagged in the same transaction')
    local stored = Core.Bans.get('B1')
    eq(stored and stored.expiresAt, BASE_TIME + 3600, 'get reads the stored row back')
    eq(stored and #stored.identifiers, 3, 'with its identifiers (license, discord, fivem)')
    eq(stored and stored.accountIds[1], 'acc5', 'and the explicit account first in accountIds')
    eq(stored and stored.by.accountId, 'accAdmin', 'and who banned')
    eq(sql("SELECT count(*)::int AS n FROM ban_tokens WHERE ban_id = 'B1'")[1].n, 2, 'one ban_tokens row per token')
    local row = Core.Audit.query({ action = 'ban.add' }).rows[1]
    check(row ~= nil, 'ban.add is audited')
    eq(row and row.actor.accountId, 'accAdmin', 'with the admin as actor')
    eq(row and row.source, 'menu', 'and the given source')
    eq(row and row.targets[1].type, 'ban', 'the ban is a target')
    eq(row and row.targets[2].type, 'player', 'the online player is a target')
    eq(row and row.ctx.duration, 3600, 'the duration is in ctx')

    eq(Core.Bans.check({}, { '3:def' }), nil, 'one token alone does not hit (tokenMatches defaults to 2)')
    eq(Core.Bans.check({}, { '3:def', '2:abc' }).id, 'B1', 'two distinct tokens hit')
    eq(Core.Bans.check({ 'discord:111' }).id, 'B1', 'any identifier hits')
    eq(Core.Bans.check({ 'ip:1.2.3.4' }), nil, 'ip: never hits')
    eq(Core.Bans.check({ 'license:zzz' }, { '9:nope' }), nil, 'an unknown identity does not hit')
    eq(Core.Bans.check(nil, 'junk'), nil, 'junk input never throws')

    -- an imported 'B<n>' above the sequence: the next add skips it
    sql("INSERT INTO bans (id, name) VALUES ('B2', 'squatter')")
    local perm = Core.Bans.add({ target = { identifiers = { 'license:aaa' } }, reason = 'again', duration = 0 })
    eq(perm and perm.id, 'B3', 'a primary-key clash retries with the next number')
    eq(Core.Bans.check({ 'license:aaa' }).id, perm.id, 'a permanent ban wins over a temporary one')
    eq(perm and perm.accountId, 'acc5', 'the account holding the identifier becomes the ban account')
    eq(Core.Bans.add({ target = 77, reason = 'x' }), nil, 'a src that is not connected is refused')
    eq(select(2, Core.Bans.add({ target = 77 })), 'not_connected', 'with not_connected')
    eq(select(2, Core.Bans.add({ target = {} })), 'no_identifiers', 'no identity -> no_identifiers')
    eq(select(2, Core.Bans.add({ target = { accountId = 'nope' } })), 'unknown_account', 'unknown account')
    local orphan = Core.Bans.add({ target = { accountId = 'gone', identifiers = { 'license:orphan' } } })
    eq(orphan and orphan.accountId, nil, 'an account that does not exist is not recorded (bans.account_id is a FK)')
    eq(select(2, Core.Bans.add({ target = 5, duration = -1 })), 'invalid_duration', 'negative duration')
    eq(select(2, Core.Bans.add({ target = 5, evidence = {} })), 'invalid_evidence', 'evidence must be a string')
    eq(select(2, Core.Bans.add('x')), 'invalid', 'a non-table is refused')
    local legacy = Core.Bans.add({ target = { identifiers = { 'license:lg' } }, by = 'OldAdmin' })
    eq(legacy.by.name, 'OldAdmin', 'a legacy name string as by is kept')
    eq(Core.Bans.get(legacy.id).by.name, 'OldAdmin', 'and stored')
    eq(Core.Bans.add({ target = { identifiers = { 'license:c1' } } }).by.name, 'console', 'no by = console')
    bridge.fail('^INSERT INTO "ban_identifiers"', 'XX000 simulated failure')
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'license:half' } } })), 'db',
        'a failed link row refuses the whole ban')
    bridge.unfail()
    eq(sql("SELECT count(*)::int AS n FROM bans WHERE name = 'unknown' AND reason = 'No reason given' "
        .. "AND id NOT IN (SELECT ban_id FROM ban_identifiers)")[1].n, 0, 'and the transaction left no ban row')

    -- R8: a duration under one second would floor to 0 = permanent; it is refused instead
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'license:halfsec' } }, duration = 0.5 })),
        'invalid_duration', 'R8: a duration in (0, 1) is refused')
    local oneSec = Core.Bans.add({ target = { identifiers = { 'license:onesec' } }, duration = 1.7 })
    eq(oneSec and oneSec.expiresAt, BASE_TIME + 1, 'R8: a fractional duration floors to whole seconds')
    eq(Core.Bans.add({ target = { identifiers = { 'license:perm0' } }, duration = 0 }).expiresAt, 0,
        'an explicit 0 is still permanent')

    -- R9: admin-typed identifiers and tokens are stored and matched lower-cased (the engine's are lower-case hex)
    local upper = Core.Bans.add({ target = { identifiers = { 'DISCORD:AbC123' }, tokens = { '2:ABCDEF', '3:FeDcBa' } } })
    eq(upper and upper.identifiers[1], 'discord:abc123', 'R9: a typed identifier is stored lower-cased')
    check(upper and has(upper.tokens, '2:abcdef') and has(upper.tokens, '3:fedcba'), 'R9: and so are typed tokens')
    eq(sql('SELECT identifier FROM ban_identifiers WHERE ban_id = $1', { upper.id })[1].identifier, 'discord:abc123',
        'R9: in the row too')
    eq(Core.Bans.check({ 'Discord:ABC123' }).id, upper.id, 'R9: a check matches in any case')
    eq(Core.Bans.check({}, { '2:abcdef', '3:fedcba' }).id, upper.id, "R9: the engine's tokens match the typed ones")
    eq(#stubs.failures, 0, 'no thread errors')
end

--------------------------------------------------------------------------------
-- the connect path: ONE indexed statement, enrichment (queued), hits, account learning
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    settle()
    h.connect(5, { 'license:aaa', 'discord:111' }, { '2:abc', '3:def' }, 'Five', 'acc5')
    local ban = Core.Bans.add({ target = 5, reason = 'wallhack', duration = 0 })
    h.sessions[5] = nil
    -- a second account on the same PC: new license, the PC's hardware tokens
    h.connect(9, { 'license:zzz', 'ip:9.9.9.9' }, { '2:abc', '3:def', '4:new' }, 'Alt')
    local log, restore = h.spy()
    local hit, message = Core.Bans.checkConnecting(9)
    restore()
    eq(hit and hit.id, ban.id, 'two shared tokens refuse the alt')
    eq(message, ('You are permanently banned. Reason: wallhack (ban %s)'):format(ban.id), 'the finished rejection text')
    local queries = calls(log, 'query')
    eq(#queries, 1, 'the check is ONE statement')
    local checkSql = queries[1] and queries[1].args[1] or ''
    check(checkSql:find('identifier = ANY($1::text[])', 1, true) and checkSql:find('token = ANY($2::text[])', 1, true),
        'it looks the candidates up by identifier and token')
    eq(#calls(log, 'crud') + #calls(log, 'txBegin') + #calls(log, 'batch'), 0, 'nothing else is read or awaited')
    local connectOpts = queries[1] and queries[1].args[3]
    eq(type(connectOpts) == 'table' and connectOpts.timeoutMs, 5000, 'R7: the connect read gives up after 5 s')
    check(#calls(log, 'enqueue') >= 3, 'the enrichment is queued (hit, identifiers, tokens)')
    local unkeyed, hitPatch, linkSaves = 0, false, 0
    for _, entry in ipairs(calls(log, 'enqueue')) do
        for _, e in ipairs(entry.args[1]) do
            if e.t == 'sql' and e.key == nil then unkeyed = unkeyed + 1 end
            if e.t == 'patch' and e.table == 'bans' then hitPatch = true end
            if e.t == 'save' and (e.table == 'ban_identifiers' or e.table == 'ban_tokens') then linkSaves = linkSaves + 1 end
        end
    end
    eq(unkeyed, 0, 'R10: no enrichment write is an unkeyed barrier')
    check(hitPatch, 'R10: the hit is a patch of the ban row (coalesced per ban)')
    eq(linkSaves, 2, 'R10: the new identifier and token are PK saves (bulk, DO NOTHING)')
    -- the statement is served by the link-table indexes (sequential scans switched off for the plan)
    local ok, plan = Core.DB.transaction(function(tx)
        tx.execute('SET LOCAL enable_seqscan = off')
        local rows = tx.query('EXPLAIN ' .. checkSql, queries[1].args[2])
        local lines = {}
        for i = 1, #(rows or {}) do lines[i] = rows[i]['QUERY PLAN'] end
        return table.concat(lines, '\n')
    end)
    check(ok and plan:find('ban_identifiers_identifier_idx', 1, true), 'the plan uses ban_identifiers_identifier_idx',
        tostring(plan))
    check(ok and plan:find('ban_tokens_token_idx', 1, true), 'and ban_tokens_token_idx')
    check(ok and not plan:find('Seq Scan', 1, true), 'and scans no table whole')

    local stored = Core.Bans.get(ban.id)
    check(has(stored.identifiers, 'license:zzz'), 'the new license joins the ban')
    check(not has(stored.identifiers, 'ip:9.9.9.9'), 'the ip does not')
    check(has(stored.tokens, '4:new'), 'the new token joins the ban')
    eq(stored.hits, 1, 'hits count up')
    eq(stored.lastHitAt, BASE_TIME, 'lastHitAt is stamped')
    eq(Core.Bans.check({ 'license:zzz' }).id, ban.id, 'the enriched identifier hits at once')
    eq(select(2, Core.Bans.checkConnecting(9)), message, 'a second attempt is refused the same way')
    eq(Core.Bans.get(ban.id).hits, 2, 'and counted')
    for _ = 1, 5 do Core.Bans.checkConnecting(9) end
    eq(Core.Bans.get(ban.id).hits, 7, 'R10: a reconnect spam counts every attempt once')
    sql('UPDATE bans SET hits = 0 WHERE id = $1', { ban.id })   -- as if the last patches were still queued
    Core.Bans.checkConnecting(9)
    eq(Core.Bans.get(ban.id).hits, 8, 'R10: a patch that has not landed yet is not undercounted')
    h.connect(10, { 'license:clean' }, { '5:clean' }, 'Clean')
    log, restore = h.spy()
    eq(Core.Bans.checkConnecting(10), nil, 'a clean player passes')
    restore()
    eq(#calls(log, 'query'), 1, 'with one statement')
    eq(#calls(log, 'enqueue'), 0, 'and no write')
    eq(Core.Bans.checkConnecting('junk'), nil, 'a bad src passes quietly')

    -- tokens count per ban: one token in each of two bans is no match
    Core.Bans.add({ target = { tokens = { '1:solo-a' } } })
    Core.Bans.add({ target = { tokens = { '1:solo-b' } } })
    eq(Core.Bans.check({}, { '1:solo-a', '1:solo-b' }), nil, 'tokens of two different bans do not add up')

    -- an identifier ban names the account holding the identifier at once (review H2)
    local known = h.account('accKim', 'license:kkk', 'Kim', 'user', { discord = 'discord:kim' })
    local byDiscord = Core.Bans.add({ target = { identifiers = { 'discord:kim' } }, reason = 'evasion' })
    eq(byDiscord.accountId, known, 'a discord identifier resolves to the account holding it')
    eq(byDiscord.name, 'Kim', 'and takes its name')
    eq(byDiscord.accountIds and byDiscord.accountIds[1], known, 'the matched accounts are listed')
    eq(h.banned(known), true, 'that (offline) account is flagged by the statement')

    -- an identifier-only ban for an account created later learns it on the first identifier hit
    local offline = Core.Bans.add({ target = { identifiers = { 'license:qqq' } }, reason = 'ban evasion', duration = 600 })
    eq(offline.accountId, nil, 'no account holds the identifier yet')
    local accId = h.account('accQ', 'license:qqq', 'Quinn', 'user')
    h.connect(11, { 'license:qqq' }, {}, 'Quinn')
    log, restore = h.spy()
    local _, text = Core.Bans.checkConnecting(11)
    restore()
    local learnKey
    for _, entry in ipairs(calls(log, 'enqueue')) do
        for _, e in ipairs(entry.args[1]) do
            if e.t == 'sql' then learnKey = e.key end
        end
    end
    eq(learnKey, 'core:bans.learn:' .. offline.id, 'R10: the account learning is one statement keyed per ban')
    check(text and text:find('You are banned until', 1, true) ~= nil, 'a temporary ban names its end')
    eq(Core.Bans.get(offline.id).accountId, accId, 'the ban learned the account')
    eq(Core.Bans.get(offline.id).name, 'Quinn', 'and its name')
    check(has(Core.Bans.get(offline.id).accountIds, accId), 'and lists it in accountIds')
    eq(h.banned(accId), true, "the offline account is flagged banned (from the learning statement's RETURNING)")
    eq(#Core.Bans.forAccount(accId), 1, 'forAccount finds it')

    -- R4: the flag follows the learning guard — an account another writer set in between wins, and no flag is
    -- written for the connecting account (its account_id IS NULL guard updated no row)
    local wBan = Core.Bans.add({ target = { identifiers = { 'license:www' } }, reason = 'w', duration = 0 })
    eq(wBan.accountId, nil, 'no account holds the identifier yet')
    local wAcc = h.account('accW', 'license:www', 'Www', 'user')
    local other = h.account('accOther', 'license:other1', 'Other', 'user')
    h.connect(16, { 'license:www' }, {}, 'Www')
    local real = rawget(h.env.exports, 'core_db')
    rawset(h.env.exports, 'core_db', setmetatable({ synchronous = true }, { __index = function(t, fnName)
        local fn = function(_, ...)
            local ret = real[fnName](real, ...)
            if fnName == 'query' then   -- right after the connect check read the ban: another writer links it
                sql('UPDATE bans SET account_id = $2 WHERE id = $1', { wBan.id, other })
            end
            return ret
        end
        rawset(t, fnName, fn)
        return fn
    end }))
    local wHit = Core.Bans.checkConnecting(16)
    rawset(h.env.exports, 'core_db', real)
    eq(wHit and wHit.id, wBan.id, 'the connection is refused')
    eq(Core.Bans.get(wBan.id).accountId, other, 'R4: the guard kept the account the other writer set')
    eq(h.banned(wAcc), false, 'R4: the connecting account is NOT flagged (no row learned)')
    eq(#sql('SELECT 1 FROM ban_accounts WHERE ban_id = $1 AND account_id = $2', { wBan.id, wAcc }), 0,
        'R4: nor linked')
end

--------------------------------------------------------------------------------
-- expiry (the sweep: at start, every minute, by hand), revoke, the account flag with several bans
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    settle()
    local accId = h.account('accExp', 'license:exp', 'Exp', 'user', { discord = 'discord:exp' })
    local short = Core.Bans.add({ target = { accountId = accId }, reason = 'short', duration = 60 })
    eq(short.name, 'Exp', 'an offline account ban takes the account name')
    check(has(short.identifiers, 'license:exp') and has(short.identifiers, 'discord:exp'),
        'and the identifiers stored for the account')
    eq(h.banned(accId), true, 'the offline account is flagged')
    stubs.osTime = BASE_TIME + 61
    eq(Core.Bans.check({ 'license:exp' }), nil, 'an expired ban does not hit')
    eq(Core.Bans.sweep(), 1, 'the sweep retires it')
    eq(h.banned(accId), false, 'the flag is cleared when the last ban expires')

    local a = Core.Bans.add({ target = { identifiers = { 'license:sw1' } }, duration = 30 })
    Core.Bans.add({ target = { identifiers = { 'license:sw2' } }, duration = 30 })
    Core.Bans.add({ target = { identifiers = { 'license:sw3' } }, duration = 0 })
    stubs.osTime = BASE_TIME + 100
    eq(Core.Bans.sweep(), 2, 'the sweep counts the bans that expired since the last one')
    eq(Core.Bans.sweep(), 0, 'and only once')
    check(Core.Bans.get(a.id) ~= nil, 'an expired ban stays in the table')
    eq(Core.Bans.check({ 'license:sw3' }) ~= nil, true, 'a permanent ban survives the sweep')

    -- two active bans on one online account: the flag clears with the last one only
    h.connect(6, { 'license:two' }, { '7:two' }, 'Two', 'acc6')
    local b1 = Core.Bans.add({ target = 6, reason = 'one', duration = 0 })
    local b2 = Core.Bans.add({ target = { accountId = 'acc6' }, reason = 'two', duration = 0 })
    local before = #h.accountWrites
    local ok, err = Core.Bans.remove(b1.id, 0, 'appeal accepted')
    check(ok, 'remove revokes a ban', tostring(err))
    eq(#h.accountWrites, before, 'the flag stays while another ban is active')
    eq(h.banned('acc6'), true, 'in the row as well')
    local revoked = Core.Bans.get(b1.id)
    eq(revoked.revoked and revoked.revoked.reason, 'appeal accepted', 'the revoke reason is kept')
    eq(revoked.revoked and revoked.revoked.by.name, 'console', 'and who revoked it')
    eq(revoked.revoked and revoked.revoked.at, BASE_TIME + 100, 'and when')
    eq(Core.Bans.check({ 'license:two' }).id, b2.id, 'the other ban still hits')
    Core.Bans.remove(b2.id, 0, 'second appeal')
    local write = h.accountWrites[#h.accountWrites]
    check(write and write.src == 6 and write.value == false, 'the flag clears with the last active ban (online)')
    eq(h.banned('acc6'), false, 'and in the row')
    eq(Core.Bans.check({ 'license:two' }, { '7:two' }), nil, 'a revoked ban never hits')
    eq(select(2, Core.Bans.remove(b2.id, 0, 'again')), 'already_revoked', 'a second revoke is refused')
    eq(select(2, Core.Bans.remove('nope', 0)), 'not_found', 'an unknown id is not_found')
    eq(select(2, Core.Bans.remove(5, 0)), 'invalid', 'a bad id is invalid')
    eq(#Core.Audit.query({ action = 'ban.remove' }).rows, 2, 'every revoke is audited')

    -- R4: accounts.banned is recomputed (EXISTS an active ban) — and a flag a concurrent writer left wrong
    -- (READ COMMITTED: remove did not see an add's row yet) is recomputed for every account touched since
    local raceAcc = h.account('accRace', 'license:race', 'Race', 'user')
    local raceBan = Core.Bans.add({ target = { accountId = raceAcc }, duration = 0 })
    sql("UPDATE accounts SET banned = false WHERE id = 'accRace'")   -- the lost race
    Core.Bans.sweep()
    eq(h.banned(raceAcc), true, 'R4: the next sweep recomputes a touched account')
    Core.Bans.remove(raceBan.id, 0, 'done')
    sql("UPDATE accounts SET banned = true WHERE id = 'accRace'")    -- the other way round
    Core.Bans.sweep()
    eq(h.banned(raceAcc), false, 'R4: in both directions')
    sql("UPDATE accounts SET banned = true WHERE id = 'accRace'")
    Core.Bans.sweep()
    eq(h.banned(raceAcc), true, 'only touched accounts are re-checked each minute (no scan; the start pass does all)')
    sql("UPDATE accounts SET banned = false WHERE id = 'accRace'")

    -- the sweep also runs every minute: a flag clears without a call
    local minute = h.account('accMin', 'license:min', 'Min', 'user')
    Core.Bans.add({ target = { accountId = minute }, duration = 30 })
    eq(h.banned(minute), true, 'flagged')
    stubs.osTime = stubs.osTime + 31
    stubs.tick(60000)
    eq(h.banned(minute), false, 'the minute sweep cleared the flag')
    eq(#stubs.failures, 0, 'no thread errors')
end

--------------------------------------------------------------------------------
-- list (paged SQL), forAccount, a restart reads the table
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    settle()
    h.account('accL', 'license:accl', 'L', 'user')
    local ids = {}
    for i = 1, 5 do
        stubs.osTime = BASE_TIME + i
        ids[i] = Core.Bans.add({ target = { identifiers = { 'license:l' .. i }, name = 'Name' .. i,
            accountId = i <= 2 and 'accL' or nil }, reason = i == 3 and 'Speedhack' or 'misc', duration = 0 }).id
    end
    Core.Bans.remove(ids[1], 0, 'revoked')
    local log, restore = h.spy()
    local list = Core.Bans.list({})
    restore()
    eq(#calls(log, 'query'), 1, 'one page is one statement')
    eq(#list.rows, 4, 'active only by default')
    eq(list.rows[1].id, ids[5], 'newest first')
    eq(list.next, nil, 'no cursor when everything fit')
    eq(#Core.Bans.list({ active = false }).rows, 5, 'active = false includes the history')
    eq(Core.Bans.list({ text = 'speedHACK' }).rows[1].id, ids[3], 'text search, case-insensitive (reason)')
    eq(Core.Bans.list({ text = 'license:l4' }).rows[1].id, ids[4], 'text search on identifiers')
    eq(#Core.Bans.list({ text = 'license:l4' }).rows, 1, 'and only that one')
    eq(#Core.Bans.list({ text = 'NAME' }).rows, 4, 'text search on names')
    eq(#Core.Bans.list({ accountId = 'accL', active = false }).rows, 2, 'accountId filter')
    local seen, cursor, pages = {}, nil, 0
    repeat
        local page = Core.Bans.list({ active = false, limit = 2, before = cursor })
        pages = pages + 1
        for i = 1, #page.rows do
            check(not seen[page.rows[i].id], 'a ban appears on one page only')
            seen[page.rows[i].id] = true
        end
        cursor = page.next
    until not cursor or pages > 5
    eq(pages, 3, 'five bans in pages of two')
    eq(#Core.Bans.list({ before = 'garbage' }).rows, 0, 'a bad cursor returns nothing')
    eq(#Core.Bans.list({ accountId = {} }).rows, 0, 'a bad accountId filter matches nothing')
    local history = Core.Bans.forAccount('accL')
    eq(#history, 2, 'forAccount returns the whole history')
    eq(history[1].id, ids[2], 'newest first')
    eq(#Core.Bans.forAccount(nil), 0, 'forAccount(nil) is empty')

    stubs.osTime = BASE_TIME + 10
    for i = 6, 10 do Core.Bans.add({ target = { identifiers = { 'license:t' .. i } } }) end
    local tie = Core.Bans.list({ limit = 2 })
    eq(tie.rows[1].id, 'B10', 'equal createdAt: the longer (newer) counter id first')
    eq(tie.rows[2].id, 'B9', 'then B9')
    eq(tie.next, ('%d/B9'):format(BASE_TIME + 10), "the cursor is '<createdAt>/<id>'")
    local after = Core.Bans.list({ limit = 3, before = tie.next })
    eq(after.rows[1] and after.rows[1].id, 'B8', 'the next page continues inside the same second')
    eq(after.rows[3] and after.rows[3].id, 'B6', 'down to the shortest id')
    eq(after.next, ('%d/B6'):format(BASE_TIME + 10), 'with a cursor')
    eq(Core.Bans.list({ limit = 1, before = after.next }).rows[1].id, ids[5], 'then the older seconds')

    -- LIKE wildcards in the text are literal
    stubs.osTime = BASE_TIME + 20
    local pct = Core.Bans.add({ target = { identifiers = { 'license:pct' } }, reason = 'sold 100% off' }).id
    Core.Bans.add({ target = { identifiers = { 'license:pct2' } }, reason = 'sold 1000 off' })
    local und = Core.Bans.add({ target = { identifiers = { 'license:und' } }, reason = 'a_b' }).id
    Core.Bans.add({ target = { identifiers = { 'license:und2' } }, reason = 'axb' })
    local hits = Core.Bans.list({ text = '100%' }).rows
    eq(#hits, 1, "'%' in the text is not a wildcard")
    eq(hits[1] and hits[1].id, pct, 'it matches the literal percent sign')
    hits = Core.Bans.list({ text = 'a_b' }).rows
    eq(#hits, 1, "'_' in the text is not a wildcard")
    eq(hits[1] and hits[1].id, und, 'it matches the literal underscore')
    eq(#Core.Bans.list({ text = '\\' }).rows, 0, 'a backslash is literal too')

    local Core2 = newCore({ restart = true })
    settle()
    eq(Core2.Bans.check({ 'license:l3' }) and Core2.Bans.check({ 'license:l3' }).id, ids[3],
        'a restarted core reads the bans from the table')
    eq(Core2.Bans.check({ 'license:l1' }), nil, 'a revoked ban stays inactive after a restart')
    eq(Core2.Bans.add({ target = { identifiers = { 'license:next' } } }).id, 'B15', 'the sequence continues')
end

--------------------------------------------------------------------------------
-- settings: bans.tokenMatches (0/1/2), the enrich switches, bans.failClosed; review M3 enrichment rules
--------------------------------------------------------------------------------

do
    local Core, h = newCore({ settings = true })
    settle()
    local S = Core.Settings
    eq(S.get('bans.tokenMatches'), 2, 'the bans section is defined: tokenMatches defaults to 2')
    eq(S.get('bans.enrichTokens'), true, 'enrichTokens defaults to true')
    eq(S.get('bans.enrichIdentifiers'), true, 'enrichIdentifiers defaults to true')
    eq(S.get('bans.failClosed'), true, 'failClosed defaults to true')
    local owner
    for _, section in ipairs(S.list()) do
        if section.id == 'bans' then owner = section.owner end
    end
    eq(owner, 'core', 'the section belongs to core')

    h.connect(5, { 'license:t5' }, { '2:aa', '3:bb' }, 'Five', 'acc5')
    local ban = Core.Bans.add({ target = 5, reason = 'x' })
    h.drop(5)
    eq(Core.Bans.check({ 'license:other' }, { '3:bb' }), nil, 'tokenMatches 2: one token is not enough')
    eq(Core.Bans.check({}, { '3:bb', '3:bb' }), nil, 'tokenMatches 2: a repeated token counts once')
    eq(Core.Bans.check({}, { '3:bb', '9:x', '2:aa' }).id, ban.id, 'tokenMatches 2: two distinct tokens match')
    eq(Core.Bans.check({ 'license:t5' }, {}).id, ban.id, 'identifiers still match on one overlap')

    check(S.set('bans.tokenMatches', 1), 'tokenMatches can be set to 1')
    stubs.tick(10)
    eq(Core.Bans.check({ 'license:other' }, { '3:bb' }).id, ban.id, 'tokenMatches 1: one shared token matches')
    -- M3: one shared token refuses, but never spreads identifiers or learns an account
    local strangerAcc = h.account('accStr', 'license:str1', 'Str', 'user')
    h.connect(12, { 'license:str1', 'discord:str1' }, { '3:bb', '8:own' }, 'Stranger')
    local hit = Core.Bans.checkConnecting(12)
    eq(hit and hit.id, ban.id, 'tokenMatches 1: the stranger with one shared token is refused')
    check(hit and not has(hit.identifiers, 'license:str1'), 'M3: a one-token hit adds no identifier')
    check(hit and has(hit.tokens, '8:own'), 'tokens still join (enrichTokens)')
    check(not has(Core.Bans.get(ban.id).identifiers, 'license:str1'), 'M3: nor does the stored ban')
    eq(h.banned(strangerAcc), false, 'M3: the stranger account is not flagged')

    S.set('bans.tokenMatches', 0)
    stubs.tick(10)
    eq(Core.Bans.check({}, { '3:bb', '2:aa' }), nil, 'tokenMatches 0: tokens never match on their own')
    eq(Core.Bans.check({ 'license:t5' }, { '2:aa' }).id, ban.id, 'tokenMatches 0: an identifier still matches')
    eq(Core.Bans.checkConnecting(12), nil, 'tokenMatches 0: the stranger on shared hardware gets in')
    check(not S.set('bans.tokenMatches', 11), 'tokenMatches above 10 is refused by the schema')
    stubs.tick(10)
    eq(Core.Bans.checkConnecting(12), nil, 'a refused set leaves the cached value alone')

    S.set('bans.tokenMatches', 2)
    S.set('bans.enrichTokens', false)
    S.set('bans.enrichIdentifiers', false)
    stubs.tick(10)
    h.connect(13, { 'license:alt13' }, { '2:aa', '3:bb', '9:new' }, 'Alt13')
    hit = Core.Bans.checkConnecting(13)
    eq(hit and hit.id, ban.id, 'two shared tokens refuse the alt')
    check(hit and not has(hit.identifiers, 'license:alt13'), 'enrichIdentifiers false: no new identifier')
    check(hit and not has(hit.tokens, '9:new'), 'enrichTokens false: no new token')
    local hits = hit and hit.hits
    S.set('bans.enrichTokens', true)
    stubs.tick(10)
    hit = Core.Bans.checkConnecting(13)
    eq(hit and hit.hits, hits + 1, 'every refused connection is counted')
    check(hit and has(hit.tokens, '9:new'), 'enrichTokens true: the new token joins')
    check(hit and not has(hit.identifiers, 'license:alt13'), 'the identifier switch is independent')
    S.set('bans.enrichIdentifiers', true)
    stubs.tick(10)
    hit = Core.Bans.checkConnecting(13)
    check(hit and has(hit.identifiers, 'license:alt13'), 'M3: >= 2 matching tokens let the identifier join')

    -- M3: a token-only hit never teaches an account-less ban an account
    local pcAcc = h.account('accPc', 'license:pc2', 'PcOwner', 'user')
    local pcBan = Core.Bans.add({ target = { identifiers = { 'license:gone' }, tokens = { '4:pc', '5:pc' } } })
    h.connect(14, { 'license:pc2' }, { '4:pc', '5:pc' }, 'PcOwner')
    eq(Core.Bans.checkConnecting(14) and true, true, 'the two tokens refuse the connection')
    check(has(Core.Bans.get(pcBan.id).identifiers, 'license:pc2'), 'the identifier joins (two tokens)')
    eq(Core.Bans.get(pcBan.id).accountId, nil, 'M3: but no account is learned from a token-only hit')
    eq(h.banned(pcAcc), false, 'and the account is not flagged')
    eq(#stubs.failures, 0, 'no thread errors with the real settings module')
end

--------------------------------------------------------------------------------
-- review H2: a player actor never bans an identity that reaches its rank; online holders are kicked
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    settle()
    local ownerAcc = h.account('accOwn', 'license:own', 'Owner', 'owner',
        { discord = 'discord:own', steam = 'steam:own' })
    local userAcc = h.account('accUsr', 'license:usr', 'User', 'user', { discord = 'discord:usr' })
    h.connect(1, { 'license:adm' }, {}, 'Admin', 'accAdm', 'admin')
    h.connect(2, { 'license:sen', 'discord:sen' }, { '6:sen', '7:sen' }, 'Senior', 'accSen', 'senior')
    h.connect(3, { 'license:cheat' }, {}, 'Cheater', 'accCheat', 'user')

    eq(select(2, Core.Bans.add({ target = { identifiers = { 'discord:own' } }, by = 1 })), 'rank',
        'an admin cannot ban the discord of an offline owner account')
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'steam:own' } }, by = 1 })), 'rank',
        'any identifier type maps to its account')
    eq(select(2, Core.Bans.add({ target = { accountId = ownerAcc }, by = 1 })), 'rank', 'nor the account itself')
    eq(select(2, Core.Bans.add({ target = 2, by = 1 })), 'rank', 'nor an online senior')
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'discord:sen' } }, by = 1 })), 'rank',
        'nor an identifier an online senior holds right now')
    eq(select(2, Core.Bans.add({ target = { tokens = { '6:sen', '7:sen' } }, by = 1 })), 'rank',
        'nor two of the tokens an online senior holds')
    check(Core.Bans.add({ target = { tokens = { '6:sen' } }, by = 1 }) ~= nil,
        'one token below tokenMatches does not reach the senior')
    eq(#stubs.dropped, 0, 'a refused ban kicks nobody')
    check(Core.Bans.add({ target = { identifiers = { 'discord:own' } }, by = 0 }) ~= nil, 'the console may')
    h.connect(9, { 'license:ghost' }, {}, 'Ghost')   -- connected, no session: weight 0
    eq(select(2, Core.Bans.add({ target = 3, by = 9 })), 'rank', 'an actor without a session outranks nobody')

    local ban = Core.Bans.add({ target = { identifiers = { 'discord:usr' } }, by = 1, reason = 'alt' })
    check(ban ~= nil, 'an admin may ban a user identity')
    eq(ban and ban.accountId, userAcc, 'the matched account becomes the ban account')
    eq(ban and ban.accountIds and #ban.accountIds, 1, 'accountIds lists the matched accounts')

    -- an online player holding a banned identifier leaves at once; a dropped one is forgotten
    h.connect(4, { 'license:alt4', 'discord:shared' }, {}, 'AltFour', 'accAlt4', 'user')
    h.connect(6, { 'license:gone6', 'discord:gone' }, {}, 'Gone', 'accGone', 'user')
    h.drop(6)
    local before = #stubs.dropped
    check(Core.Bans.add({ target = 3, by = 1, reason = 'cheat' }) ~= nil, 'the admin bans the online cheater')
    eq(stubs.dropped[before + 1] and stubs.dropped[before + 1].src, 3, 'the target is kicked')
    before = #stubs.dropped
    Core.Bans.add({ target = { identifiers = { 'discord:shared', 'discord:gone' } }, by = 1 })
    eq(#stubs.dropped, before + 1, 'exactly the online holder is kicked')
    eq(stubs.dropped[#stubs.dropped].src, 4, 'the player holding the identifier')

    -- Player.findAccountsByIdentifier answers the holders; their rows come in ONE query by id list
    local twinA = h.account('accTwA', 'license:twA', 'TwinA', 'user')
    local twinB = h.account('accTwB', 'license:twB', 'TwinB', 'mod')
    local asked = {}
    local realFind = Core.Player.findAccountsByIdentifier
    Core.Player.findAccountsByIdentifier = function(identifier)
        asked[#asked + 1] = identifier
        if identifier == 'discord:twin' then return { twinA, twinB } end
        return {}
    end
    local log, restore = h.spy()
    local shared = Core.Bans.add({ target = { identifiers = { 'discord:twin' } }, by = 1, reason = 'twins' })
    restore()
    eq(asked[1], 'discord:twin', 'the identifier index is asked')
    local reads = 0
    for _, entry in ipairs(calls(log, 'query')) do
        if entry.args[1]:find('FROM accounts WHERE id = ANY', 1, true) then reads = reads + 1 end
    end
    eq(reads, 1, 'the holder rows are one query by id list')
    eq(shared and #shared.accountIds, 2, 'both holding accounts are listed')
    eq(shared and shared.accountId, nil, 'several holders: no single ban account')
    eq(Core.Bans.list({ accountId = twinB, active = false }).rows[1].id, shared.id, 'list finds it by any listed account')
    eq(Core.Bans.forAccount(twinA)[1].id, shared.id, 'forAccount too')
    eq(h.banned(twinA), false, 'accounts.banned follows the ban account only')
    Core.Player.findAccountsByIdentifier = function(identifier)
        return identifier == 'discord:own' and { ownerAcc } or {}
    end
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'discord:own' } }, by = 1 })), 'rank',
        'the rank check works through the identifier index as well')
    Core.Player.findAccountsByIdentifier = realFind
end

--------------------------------------------------------------------------------
-- review M4: an unreadable ban list is reported, never treated as "not banned"; the connect gate fails closed
--------------------------------------------------------------------------------

do
    local Core, h = newCore({ settings = true, store = true })
    settle()
    local Store = h.env.CorePlayerStore
    h.connect(7, { 'license:seven' }, { '1:x' }, 'Seven')
    bridge.fail('FROM ban_identifiers', 'XX000 simulated failure')
    local ban, why = Core.Bans.checkConnecting(7)
    eq(ban, nil, 'no ban while the ban list is unreadable')
    eq(why, 'unavailable', "but checkConnecting says 'unavailable'")
    eq(select(2, Core.Bans.check({ 'license:seven' })), 'unavailable', 'Bans.check says so too')
    eq(Core.Settings.get('bans.failClosed'), true, 'failClosed (read by the connect gate) defaults to true')
    local refused, text = Store.connectingBan(7, 'license:seven')
    eq(refused, true, 'the connect gate refuses while neither lookup can read (fail closed)')
    eq(text, 'Ban service unavailable, please try again in a minute.', 'with the retry text')
    Core.Settings.set('bans.failClosed', false)
    stubs.tick(10)
    eq(Store.connectingBan(7, 'license:seven'), nil, 'failClosed false lets the player in')
    Core.Settings.set('bans.failClosed', true)
    bridge.unfail()
    local fine, reason = Core.Bans.checkConnecting(7)
    eq(fine, nil, 'once the database answers the check runs again')
    eq(reason, nil, 'and a clean player is plainly not banned')
    Core.Bans.add({ target = { identifiers = { 'license:seven' } }, reason = 'gate' })
    local gated, notice = Store.connectingBan(7, 'license:seven')
    eq(gated and gated.reason, 'gate', 'the gate hands back the ban')
    check(notice and notice:find('Reason: gate', 1, true) ~= nil, 'and its finished text')
    eq(Core.Bans.sweep(), 0, 'a sweep with nothing expired counts 0')
    bridge.fail('WITH ended AS', 'XX000 simulated failure')
    eq(Core.Bans.sweep(), 0, 'a failed sweep answers 0')
    bridge.unfail()
end

--------------------------------------------------------------------------------
-- review R2-12: a relink marker is linked once `accounts` can be read (retried by the minute sweep);
-- review R2-11: a player actor is refused while the account lookup cannot answer
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    sql("INSERT INTO accounts (id, license, name) VALUES ('accOld', 'license:old1', 'Old One')")
    sql("INSERT INTO bans (id, name, reason, by_name, relink, created_at) VALUES "
        .. "('old1', 'unknown', 'cheating', 'Anna', 'license:old1', to_timestamp($1))", { BASE_TIME - 100 })
    sql("INSERT INTO ban_identifiers (ban_id, identifier) VALUES ('old1', 'license:old1')")
    -- flags an import (or an older core) left behind: one without a ban, one ban without its flag
    sql("INSERT INTO accounts (id, license, name, banned) VALUES ('accStale', 'license:stale', 'Stale', true)")
    sql("INSERT INTO accounts (id, license, name, banned) VALUES ('accRevoked', 'license:rev', 'Rev', true)")
    sql("INSERT INTO bans (id, account_id, name, revoked_at) VALUES ('rev1', 'accRevoked', 'Rev', now())")
    sql("INSERT INTO accounts (id, license, name) VALUES ('accMissing', 'license:missing', 'Missing')")
    sql("INSERT INTO bans (id, account_id, name) VALUES ('mis1', 'accMissing', 'Missing')")
    bridge.fail('LEFT JOIN accounts a ON a.license = b.relink', 'XX000 accounts backend down')
    settle()   -- the start sweep: the relink statement fails
    eq(h.banned('accStale'), false, 'R4: the first sweep clears a flag no ban backs')
    eq(h.banned('accRevoked'), false, 'R4: and one whose ban was revoked')
    eq(h.banned('accMissing'), true, 'R4: and sets the flag an active ban implies')
    local ban = Core.Bans.get('old1')
    eq(ban and ban.accountId, nil, 'no account could be linked yet')
    eq(ban and ban.relink, 'license:old1', 'the license is kept on the row for later')
    eq(Core.Bans.check({ 'license:old1' }) and true, true, 'matching works meanwhile (the license is an identifier)')

    bridge.unfail()
    stubs.tick(61000)
    ban = Core.Bans.get('old1')
    eq(ban and ban.accountId, 'accOld', 'the account is linked by the next sweep')
    eq(ban and ban.relink, nil, 'and the marker is gone')
    eq(ban and ban.name, 'Old One', 'the ban takes the account name')
    eq(h.banned('accOld'), true, 'the account of an active ban is flagged')
    eq(#Core.Bans.forAccount('accOld'), 1, 'forAccount finds the relinked ban')

    -- R2-11: while `accounts` cannot answer, a player actor is refused; the console is not
    h.connect(1, { 'license:adm' }, {}, 'Admin', 'accAdm', 'admin')
    bridge.fail('account_identifiers', 'XX000 accounts backend down')
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'discord:x' } }, by = 1 })), 'db',
        'a player actor never passes the rank check blind')
    check(Core.Bans.add({ target = { identifiers = { 'discord:x' } }, by = 0 }) ~= nil, 'the console still may')
    eq(select(2, Core.Bans.add({ target = { accountId = 'accOld' }, by = 0 })), 'db',
        'an offline account target that cannot be read is refused')
    bridge.unfail()
end

do
    local Core, h = newCore()
    settle()
    h.connect(1, { 'license:adm' }, {}, 'Admin', 'accAdm', 'admin')
    Core.Player.findAccountsByIdentifier = function() return nil, 'unavailable' end
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'discord:y' } }, by = 1 })), 'db',
        'an unavailable identifier index refuses a player actor too')
    Core.Player.findAccountsByIdentifier = nil
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'discord:y' } }, by = 1 })), 'db',
        'and so does a missing one (nothing is ever scanned instead)')
end

print(('bans: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
