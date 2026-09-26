--[[
    core/tests/bans_tests.lua — offline contract of Core.Bans (DESIGN §47).

        lua5.4 tests/bans_tests.lua    (from the resource directory, or from tests/)

    One core server VM per case: import.lua, shared/config.lua, server/api.lua, server/db.lua, a FAKE
    Core.Player (sessions, getPlayers, setAccountData), then server/cron.lua, server/audit.lua and
    server/bans.lua. The identity natives (GetNumPlayerIdentifiers/GetPlayerIdentifier/
    GetNumPlayerTokens/GetPlayerToken) are stubbed here from a per-src table. Exit code 1 on failure.
]]

local here = (arg and arg[0] or 'tests/bans_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
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
local function has(list, value)
    for i = 1, #(list or {}) do
        if list[i] == value then return true end
    end
    return false
end

local BASE_TIME <const> = 1790000000

--- A fresh core VM. opts.kvp = { [key] = table } pre-seeds raw KVP documents (before anything loads);
--- opts.settings = true also loads the real server/settings.lua (the bans.* section).
local function newCore(opts)
    opts = opts or {}
    stubs.resetServer()
    stubs.newWorld()
    stubs.clear()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
    stubs.exports.core = nil
    stubs.osTime = BASE_TIME
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    env.GetConvar = function(_, fallback) return fallback end
    local identity = {}
    env.GetNumPlayerIdentifiers = function(src) local p = identity[tonumber(src)] return p and #p.ids or 0 end
    env.GetPlayerIdentifier = function(src, i) local p = identity[tonumber(src)] return p and p.ids[i + 1] or nil end
    env.GetNumPlayerTokens = function(src) local p = identity[tonumber(src)] return p and #p.tokens or 0 end
    env.GetPlayerToken = function(src, i) local p = identity[tonumber(src)] return p and p.tokens[i + 1] or nil end
    for key, doc in pairs(opts.kvp or {}) do stubs.kvp[key] = env.json.encode(doc) end

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
    stubs.loadFile(env, 'server/cron.lua')
    stubs.loadFile(env, 'server/audit.lua')
    stubs.loadFile(env, 'server/bans_identity.lua')
    stubs.loadFile(env, 'server/bans.lua')
    local h = { env = env, identity = identity, sessions = sessions, accountWrites = accountWrites }

    --- Simulates a connected player: identity + name (+ a loaded session when accountId is given) and the
    --- playerJoining event (bans.lua's online index).
    function h.connect(src, ids, tokens, name, accountId, group)
        identity[src] = { ids = ids or {}, tokens = tokens or {} }
        stubs.playerNames[src] = name or ('P' .. src)
        if accountId then sessions[src] = { accountId = accountId, name = name or ('P' .. src), group = group } end
        stubs.triggerOn(env, 'playerJoining', src, src)
    end

    --- The player leaves: playerDropped, identity and session gone.
    function h.drop(src)
        stubs.triggerOn(env, 'playerDropped', src, 'quit')
        identity[src], sessions[src], stubs.playerNames[src] = nil, nil, nil
    end
    return Core, h
end

local function settle()
    stubs.tick(10)
end

local function lastDrop()
    return stubs.dropped[#stubs.dropped]
end

--------------------------------------------------------------------------------
-- migration v2: the license-only shape of server/player.lua before §47
--------------------------------------------------------------------------------

do
    local Core = newCore({ kvp = {
        ['doc:bans:old1'] = { license = 'license:old1', reason = 'cheating', by = 'AdminAnna', ['until'] = 0,
            createdAt = BASE_TIME - 100 },
        ['doc:bans:old2'] = { license = 'license:old2', reason = 'toxic', by = 'console', ['until'] = BASE_TIME + 3600 },
        ['doc:bans:old3'] = { license = 'license:old3', reason = 'past', ['until'] = BASE_TIME - 10 },
        ['doc:accounts:accOld'] = { license = 'license:old1', name = 'Old One', banned = true },
    } })
    settle()
    local ban = Core.Bans.get('old1')
    check(ban ~= nil, 'a v1 ban survives the migration')
    eq(ban._v, 2, 'it is stamped _v = 2')
    eq(ban.identifiers and ban.identifiers[1], 'license:old1', 'license -> identifiers')
    eq(#(ban.tokens or { 0 }), 0, 'tokens start empty')
    eq(ban.expiresAt, 0, "until 0 -> expiresAt 0 (permanent)")
    eq(ban.by and ban.by.name, 'AdminAnna', 'by string -> by.name')
    eq(ban.accountId, 'accOld', 'the account behind the license is found')
    eq(ban.name, 'Old One', 'and its name')
    eq(ban.license, nil, 'the old license field is gone')
    eq(ban['until'], nil, 'the old until field is gone')
    eq(ban.hits, 0, 'hits start at 0')
    eq(Core.Bans.get('old2').expiresAt, BASE_TIME + 3600, 'a temporary v1 ban keeps its expiry')
    eq(Core.Bans.get('old2').name, 'unknown', 'a ban without an account is named unknown')
    eq(Core.Bans.check({ 'license:old1' }).id, 'old1', 'a migrated permanent ban is indexed')
    eq(Core.Bans.check({ 'license:old2' }).id, 'old2', 'a migrated temporary ban is indexed')
    eq(Core.Bans.check({ 'license:old3' }), nil, 'an expired v1 ban is not indexed')
    eq(Core.Bans.get('old3').expiresAt, BASE_TIME - 10, 'but it is kept for history')
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
    eq(ban.id, 'B1', 'ban ids are short and sequential')
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

    local perm = Core.Bans.add({ target = { identifiers = { 'license:aaa' } }, reason = 'again', duration = 0 })
    eq(Core.Bans.check({ 'license:aaa' }).id, perm.id, 'a permanent ban wins over a temporary one')
    eq(Core.Bans.add({ target = 77, reason = 'x' }), nil, 'a src that is not connected is refused')
    eq(select(2, Core.Bans.add({ target = 77 })), 'not_connected', 'with not_connected')
    eq(select(2, Core.Bans.add({ target = {} })), 'no_identifiers', 'no identity -> no_identifiers')
    eq(select(2, Core.Bans.add({ target = { accountId = 'nope' } })), 'unknown_account', 'unknown account')
    eq(select(2, Core.Bans.add({ target = 5, duration = -1 })), 'invalid_duration', 'negative duration')
    eq(select(2, Core.Bans.add({ target = 5, evidence = {} })), 'invalid_evidence', 'evidence must be a string')
    eq(select(2, Core.Bans.add('x')), 'invalid', 'a non-table is refused')
    local legacy = Core.Bans.add({ target = { identifiers = { 'license:lg' } }, by = 'OldAdmin' })
    eq(legacy.by.name, 'OldAdmin', 'a legacy name string as by is kept')
    eq(Core.Bans.add({ target = { identifiers = { 'license:c1' } } }).by.name, 'console', 'no by = console')
    eq(#stubs.failures, 0, 'no thread errors')
end

--------------------------------------------------------------------------------
-- the connect path: check, enrichment, hits, account learning
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    settle()
    h.connect(5, { 'license:aaa', 'discord:111' }, { '2:abc', '3:def' }, 'Five', 'acc5')
    local ban = Core.Bans.add({ target = 5, reason = 'wallhack', duration = 0 })
    h.sessions[5] = nil
    -- a second account on the same PC: new license, the PC's hardware tokens
    h.connect(9, { 'license:zzz', 'ip:9.9.9.9' }, { '2:abc', '3:def', '4:new' }, 'Alt')
    local hit, message = Core.Bans.checkConnecting(9)
    eq(hit and hit.id, ban.id, 'two shared tokens refuse the alt')
    eq(message, ('You are permanently banned. Reason: wallhack (ban %s)'):format(ban.id), 'the finished rejection text')
    local stored = Core.Bans.get(ban.id)
    check(has(stored.identifiers, 'license:zzz'), 'the new license joins the ban')
    check(not has(stored.identifiers, 'ip:9.9.9.9'), 'the ip does not')
    check(has(stored.tokens, '4:new'), 'the new token joins the ban')
    eq(stored.hits, 1, 'hits count up')
    eq(stored.lastHitAt, BASE_TIME, 'lastHitAt is stamped')
    eq(Core.Bans.check({ 'license:zzz' }).id, ban.id, 'the enriched identifier is indexed at once')
    eq(select(2, Core.Bans.checkConnecting(9)), message, 'a second attempt is refused the same way')
    eq(Core.Bans.get(ban.id).hits, 2, 'and counted')
    h.connect(10, { 'license:clean' }, { '5:clean' }, 'Clean')
    eq(Core.Bans.checkConnecting(10), nil, 'a clean player passes')
    eq(Core.Bans.checkConnecting('junk'), nil, 'a bad src passes quietly')

    -- an identifier ban names the account holding the identifier at once (review H2)
    local known = Core.DB.create('accounts', { license = 'license:kkk', name = 'Kim', group = 'user',
        identifiers = { license = 'license:kkk', discord = 'discord:kim' } })
    local byDiscord = Core.Bans.add({ target = { identifiers = { 'discord:kim' } }, reason = 'evasion' })
    eq(byDiscord.accountId, known, 'a discord identifier resolves to the account holding it')
    eq(byDiscord.name, 'Kim', 'and takes its name')
    eq(byDiscord.accountIds and byDiscord.accountIds[1], known, 'the matched accounts are listed')
    eq(Core.DB.get('accounts', known).banned, true, 'that account is flagged')

    -- an identifier-only ban for an account created later learns it on the first identifier hit
    local offline = Core.Bans.add({ target = { identifiers = { 'license:qqq' } }, reason = 'ban evasion', duration = 600 })
    eq(offline.accountId, nil, 'no account holds the identifier yet')
    local accId = Core.DB.create('accounts', { license = 'license:qqq', name = 'Quinn', banned = false })
    h.connect(11, { 'license:qqq' }, {}, 'Quinn')
    local _, text = Core.Bans.checkConnecting(11)
    check(text and text:find('You are banned until', 1, true) ~= nil, 'a temporary ban names its end')
    eq(Core.Bans.get(offline.id).accountId, accId, 'the ban learned the account')
    eq(Core.Bans.get(offline.id).name, 'Quinn', 'and its name')
    eq(Core.DB.get('accounts', accId).banned, true, 'the offline account is flagged banned')
end

--------------------------------------------------------------------------------
-- expiry (lazy + sweep), revoke, the account flag with several bans
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    settle()
    local accId = Core.DB.create('accounts', { license = 'license:exp', name = 'Exp', banned = false,
        identifiers = { license = 'license:exp', discord = 'discord:exp' } })
    local short = Core.Bans.add({ target = { accountId = accId }, reason = 'short', duration = 60 })
    eq(short.name, 'Exp', 'an offline account ban takes the account name')
    check(has(short.identifiers, 'license:exp') and has(short.identifiers, 'discord:exp'),
        'and the identifiers stored on the account')
    eq(Core.DB.get('accounts', accId).banned, true, 'the offline account is flagged')
    stubs.osTime = BASE_TIME + 61
    eq(Core.Bans.check({ 'license:exp' }), nil, 'an expired ban does not hit (lazy)')
    eq(Core.DB.get('accounts', accId).banned, false, 'the flag is cleared when the last ban expires')

    local a = Core.Bans.add({ target = { identifiers = { 'license:sw1' } }, duration = 30 })
    Core.Bans.add({ target = { identifiers = { 'license:sw2' } }, duration = 30 })
    Core.Bans.add({ target = { identifiers = { 'license:sw3' } }, duration = 0 })
    stubs.osTime = BASE_TIME + 100
    eq(Core.Bans.sweep(), 2, 'the sweep retires expired bans')
    eq(Core.Bans.sweep(), 0, 'and only once')
    check(Core.Bans.get(a.id) ~= nil, 'an expired ban stays in the collection')
    eq(Core.Bans.check({ 'license:sw3' }) ~= nil, true, 'a permanent ban survives the sweep')

    -- two active bans on one online account: the flag clears with the last one only
    h.connect(6, { 'license:two' }, { '7:two' }, 'Two', 'acc6')
    local b1 = Core.Bans.add({ target = 6, reason = 'one', duration = 0 })
    local b2 = Core.Bans.add({ target = { accountId = 'acc6' }, reason = 'two', duration = 0 })
    local before = #h.accountWrites
    local ok, err = Core.Bans.remove(b1.id, 0, 'appeal accepted')
    check(ok, 'remove revokes a ban', tostring(err))
    eq(#h.accountWrites, before, 'the flag stays while another ban is active')
    local revoked = Core.Bans.get(b1.id)
    eq(revoked.revoked and revoked.revoked.reason, 'appeal accepted', 'the revoke reason is kept')
    eq(revoked.revoked and revoked.revoked.by.name, 'console', 'and who revoked it')
    eq(Core.Bans.check({ 'license:two' }).id, b2.id, 'the other ban still hits')
    Core.Bans.remove(b2.id, 0, 'second appeal')
    local write = h.accountWrites[#h.accountWrites]
    check(write and write.src == 6 and write.value == false, 'the flag clears with the last active ban')
    eq(Core.Bans.check({ 'license:two' }, { '7:two' }), nil, 'a revoked ban never hits')
    eq(select(2, Core.Bans.remove(b2.id, 0, 'again')), 'already_revoked', 'a second revoke is refused')
    eq(select(2, Core.Bans.remove('nope', 0)), 'not_found', 'an unknown id is not_found')
    eq(select(2, Core.Bans.remove(5, 0)), 'invalid', 'a bad id is invalid')
    eq(#Core.Audit.query({ action = 'ban.remove' }).rows, 2, 'every revoke is audited')

    local job
    for _, entry in ipairs(Core.Cron.list()) do
        if entry.expr == '40 4 * * *' then job = entry end
    end
    check(job ~= nil and job.owner == 'core', 'the daily sweep is a core Cron job at 04:40')
end

--------------------------------------------------------------------------------
-- list, forAccount, a restart rebuilds the index
--------------------------------------------------------------------------------

do
    local Core = newCore()
    settle()
    local ids = {}
    for i = 1, 5 do
        stubs.osTime = BASE_TIME + i
        ids[i] = Core.Bans.add({ target = { identifiers = { 'license:l' .. i }, name = 'Name' .. i,
            accountId = i <= 2 and 'accL' or nil }, reason = i == 3 and 'Speedhack' or 'misc', duration = 0 }).id
    end
    Core.Bans.remove(ids[1], 0, 'revoked')
    local list = Core.Bans.list({})
    eq(#list.rows, 4, 'active only by default')
    eq(list.rows[1].id, ids[5], 'newest first')
    eq(#Core.Bans.list({ active = false }).rows, 5, 'active = false includes the history')
    eq(Core.Bans.list({ text = 'speedHACK' }).rows[1].id, ids[3], 'text search, case-insensitive (reason)')
    eq(Core.Bans.list({ text = 'license:l4' }).rows[1].id, ids[4], 'text search on identifiers')
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
    local tie = Core.Bans.list({ limit = 2 }).rows
    eq(tie[1].id, 'B10', 'equal createdAt: the longer (newer) counter id first')
    eq(tie[2].id, 'B9', 'then B9')

    Core.DB.flush()
    local kvp = {}
    for k, v in pairs(stubs.kvp) do kvp[k] = v end
    local Core2 = newCore()
    for k, v in pairs(kvp) do stubs.kvp[k] = v end
    settle()
    eq(Core2.Bans.check({ 'license:l3' }) and Core2.Bans.check({ 'license:l3' }).id, ids[3],
        'the index is rebuilt from the collection after a restart')
    eq(Core2.Bans.check({ 'license:l1' }), nil, 'a revoked ban stays out of the rebuilt index')
    eq(Core2.Bans.add({ target = { identifiers = { 'license:next' } } }).id, 'B11', 'the counter continues')
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
    local strangerAcc = Core.DB.create('accounts', { license = 'license:str1', name = 'Str', banned = false })
    h.connect(12, { 'license:str1', 'discord:str1' }, { '3:bb', '8:own' }, 'Stranger')
    local hit = Core.Bans.checkConnecting(12)
    eq(hit and hit.id, ban.id, 'tokenMatches 1: the stranger with one shared token is refused')
    check(hit and not has(hit.identifiers, 'license:str1'), 'M3: a one-token hit adds no identifier')
    check(hit and has(hit.tokens, '8:own'), 'tokens still join (enrichTokens)')
    eq(Core.DB.get('accounts', strangerAcc).banned, false, 'M3: the stranger account is not flagged')

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
    local pcAcc = Core.DB.create('accounts', { license = 'license:pc2', name = 'PcOwner', banned = false })
    local pcBan = Core.Bans.add({ target = { identifiers = { 'license:gone' }, tokens = { '4:pc', '5:pc' } } })
    h.connect(14, { 'license:pc2' }, { '4:pc', '5:pc' }, 'PcOwner')
    eq(Core.Bans.checkConnecting(14) and true, true, 'the two tokens refuse the connection')
    check(has(Core.Bans.get(pcBan.id).identifiers, 'license:pc2'), 'the identifier joins (two tokens)')
    eq(Core.Bans.get(pcBan.id).accountId, nil, 'M3: but no account is learned from a token-only hit')
    eq(Core.DB.get('accounts', pcAcc).banned, false, 'and the account is not flagged')
    eq(#stubs.failures, 0, 'no thread errors with the real settings module')
end

--------------------------------------------------------------------------------
-- review H2: a player actor never bans an identity that reaches its rank; online holders are kicked
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    settle()
    local ownerAcc = Core.DB.create('accounts', { license = 'license:own', name = 'Owner', group = 'owner',
        identifiers = { license = 'license:own', discord = 'discord:own', steam = 'steam:own' } })
    local userAcc = Core.DB.create('accounts', { license = 'license:usr', name = 'User', group = 'user',
        identifiers = { license = 'license:usr', discord = 'discord:usr' } })
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

    -- Player.findAccountsByIdentifier (player.lua's index) is used when it exists: no accounts scan
    local twinA = Core.DB.create('accounts', { license = 'license:twA', name = 'TwinA', group = 'user' })
    local twinB = Core.DB.create('accounts', { license = 'license:twB', name = 'TwinB', group = 'mod' })
    local asked = {}
    Core.Player.findAccountsByIdentifier = function(identifier)
        asked[#asked + 1] = identifier
        if identifier == 'discord:twin' then return { twinA, twinB } end
        return {}
    end
    local shared = Core.Bans.add({ target = { identifiers = { 'discord:twin' } }, by = 1, reason = 'twins' })
    eq(asked[1], 'discord:twin', 'the identifier index is asked')
    eq(shared and #shared.accountIds, 2, 'both holding accounts are listed')
    eq(shared and shared.accountId, nil, 'several holders: no single ban account')
    eq(Core.Bans.list({ accountId = twinB, active = false }).rows[1].id, shared.id, 'list finds it by any listed account')
    eq(Core.Bans.forAccount(twinA)[1].id, shared.id, 'forAccount too')
    Core.Player.findAccountsByIdentifier = function(identifier)
        return identifier == 'discord:own' and { ownerAcc } or {}
    end
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'discord:own' } }, by = 1 })), 'rank',
        'the rank check works through the identifier index as well')
end

--------------------------------------------------------------------------------
-- review M4: an unreadable bans collection is reported, never treated as "not banned"
--------------------------------------------------------------------------------

do
    local Core, h = newCore({ settings = true })
    local kvp = Core.DB.setAdapter
    local down = true
    kvp({
        loadAll = function(collection)
            if collection == 'bans' and down then error('backend down', 0) end
            return {}
        end,
        put = function() end, remove = function() end, flush = function() end,
    })
    settle()
    h.connect(7, { 'license:seven' }, { '1:x' }, 'Seven')
    local ban, why = Core.Bans.checkConnecting(7)
    eq(ban, nil, 'no ban while the collection is unreadable')
    eq(why, 'unavailable', "but checkConnecting says 'unavailable'")
    eq(select(2, Core.Bans.check({ 'license:seven' })), 'unavailable', 'Bans.check says so too')
    eq(Core.Settings.get('bans.failClosed'), true, 'failClosed (read by player.lua) defaults to true')
    down = false
    local fine, reason = Core.Bans.checkConnecting(7)
    eq(fine, nil, 'once the backend is back the check runs again')
    eq(reason, nil, 'and a clean player is plainly not banned')
end

--------------------------------------------------------------------------------
-- review R2-12: a v1 ban migrated while `accounts` is unreadable keeps its license and is linked later;
-- review R2-11: a player actor is refused while the account lookup cannot answer
--------------------------------------------------------------------------------

do
    local Core, h = newCore()
    local json = h.env.json
    local store = {
        bans = { old1 = json.encode({ license = 'license:old1', reason = 'cheating', by = 'Anna', ['until'] = 0 }) },
        accounts = { accOld = json.encode({ license = 'license:old1', name = 'Old One', banned = false }) },
    }
    local accountsDown = true
    Core.DB.setAdapter({
        loadAll = function(collection)
            if collection == 'accounts' and accountsDown then error('accounts backend down', 0) end
            local out = {}
            for id, encoded in pairs(store[collection] or {}) do out[id] = encoded end
            return out
        end,
        put = function(collection, id, encoded)
            store[collection] = store[collection] or {}
            store[collection][id] = encoded
        end,
        remove = function(collection, id) if store[collection] then store[collection][id] = nil end end,
        flush = function() end,
    })
    settle()
    local ban = Core.Bans.get('old1')
    eq(ban and ban._v, 2, 'the v1 ban is migrated although accounts is unreadable')
    eq(ban and ban.accountId, nil, 'no account could be linked yet')
    eq(ban and ban.relink, 'license:old1', 'the license is kept on the document for later')
    eq(Core.Bans.check({ 'license:old1' }) and true, true, 'matching works meanwhile (the license is an identifier)')

    accountsDown = false
    stubs.tick(61000)
    ban = Core.Bans.get('old1')
    eq(ban and ban.accountId, 'accOld', 'the account is linked once accounts can be read')
    eq(ban and ban.relink, nil, 'and the marker is gone')
    eq(ban and ban.name, 'Old One', 'the ban takes the account name')
    eq(Core.DB.get('accounts', 'accOld').banned, true, 'the account of an active ban is flagged')
    eq(#Core.Bans.forAccount('accOld'), 1, 'forAccount finds the relinked ban')

    -- R2-11: while `accounts` cannot answer, a player actor is refused; the console is not
    h.connect(1, { 'license:adm' }, {}, 'Admin', 'accAdm', 'admin')
    Core.DB.markDegraded('accounts', 'test')
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'discord:x' } }, by = 1 })), 'db',
        'a player actor never passes the rank check blind')
    check(Core.Bans.add({ target = { identifiers = { 'discord:x' } }, by = 0 }) ~= nil, 'the console still may')
end

do
    local Core, h = newCore()
    settle()
    h.connect(1, { 'license:adm' }, {}, 'Admin', 'accAdm', 'admin')
    Core.Player.findAccountsByIdentifier = function() return nil, 'unavailable' end
    eq(select(2, Core.Bans.add({ target = { identifiers = { 'discord:y' } }, by = 1 })), 'db',
        'an unavailable identifier index refuses a player actor too')
end

print(('bans: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
