--[[
    core/server/bans.lua — Core.Bans (DESIGN §47, §56): bans on identifiers AND tokens.

    add({ target = src | { accountId?, identifiers?, tokens?, name? }, reason, duration, by, evidence?, source? })
    remove(banId, by, reason) · get(id) · list(opts) · forAccount(accountId) · check(identifiers, tokens) · sweep()
    checkConnecting(src) -> ban, text | nil | nil, 'unavailable'   (internal: the playerConnecting path)

    Rows (DESIGN §56.6, sql/0001_core_schema.sql): `bans` (id = 'B' || nextval('ban_number_seq'), expires_at NULL =
    permanent, revoked_at + revoked_by_* + revoke_reason, hits, last_hit_at, relink), `ban_accounts` (position 0 =
    the explicit account), `ban_identifiers` and `ban_tokens` (indexed by identifier / token). Callers keep the
    document shape — { id, _v = 2, accountId?, accountIds, name, identifiers, tokens, reason, evidence?, by =
    { accountId?, name }, createdAt, expiresAt (0 = permanent), revoked? = { by, at, reason }, hits, lastHitAt?,
    relink?, updatedAt } — and rowToBan is the one place that maps it. `ip:` is never stored. The v1 shape
    { license, by = 'name', until } is imported by sql/0002_core_legacy_import.sql (there is no Lua migration).

    Data access (§56.8: no in-memory index, every question is an indexed statement):
      check / checkConnecting  ONE statement: candidates from ban_identifiers ∪ ban_tokens → active bans → the
                               identifier / token-count rule → best first. A failed read answers nil, 'unavailable'
                               (the connect path in server/player_store.lua then applies bans.failClosed); the
                               connect read gives up after CONNECT_TIMEOUT_MS so an outage falls back fast.
      enrich                   a refused connection's writes are QUEUED in one slice and never as an unkeyed
                               barrier: hits as a patch, new identifiers/tokens as PK-only saves, a learned
                               account (+ link + flag, from the guard's RETURNING) as ONE statement keyed per ban.
      add                      ONE awaited transaction: the ban (id from the sequence, RETURNING id), its link rows
                               and accounts.banned; a primary-key clash with an imported 'B<n>' retries.
      remove                   ONE awaited transaction: the revoke, and accounts.banned cleared when it was the
                               account's last active ban.
      get / list / forAccount  awaited reads; list pages in SQL (cursor '<createdAt>/<id>', ILIKE text filter).
      sweep                    one statement per run: the bans that expired since the last sweep and the flags of
                               their accounts and of every touched account (+ the R2-12 relink statement until it
                               succeeded once). At start and every SWEEP_MS — replaces the old lazy expiry on a hit.
    accounts.banned = EXISTS (an active ban whose own `account_id` names it; not accountIds), recomputed in ONE
    statement wherever it changes (FLAG_SQL in add/remove, the sweep); a changed ONLINE account also goes through
    Player.setAccountData so the live session agrees (it is the source of truth of its account while it exists).
    READ COMMITTED lets a concurrent add/remove miss each other's row, so every account they touched is recomputed
    by the next sweep; the first sweep after start recomputes every flagged account and every account an active
    ban names (imported or stale flags). Identifiers and tokens are stored and matched LOWER-CASED (Identity.key).

    Matching: one identifier overlap, or >= `bans.tokenMatches` (default 2, 0 = never) DISTINCT tokens of one
    ban. Enrichment on a refused connection: tokens (`bans.enrichTokens`), identifiers only after an identifier
    match or >= 2 tokens (`bans.enrichIdentifiers`), an account only from an identifier match — one shared
    token (cafés, cloud gaming) must never spread a ban to a stranger's identity. A player actor may only ban
    identities whose accounts and online holders it outranks (`'rank'`); every online holder is kicked with the
    target. The identity half (identifiers/tokens of a player, the online index, account reads, the rank check) is
    server/bans_identity.lua, which loads right before this file.

    Natives: GetPlayerName, DropPlayer (server); the identity natives live in server/bans_identity.lua.
]]

local Bans = {}
Core.Bans = Bans

local DB = Core.DB
local Log = Core.Log
local Utils = Core.Utils
-- server/bans_identity.lua (loads right before this file): identity reads, the online index, the rank check
local Identity = Core.BanIdentity or error('core: server/bans_identity.lua must load before server/bans.lua', 0)

local VERSION <const> = 2               -- the shape version callers have always seen (`_v`)
local MAX_IDENTIFIERS <const> = 32      -- collected per player
local MAX_TOKENS <const> = 64
local MAX_BAN_IDENTIFIERS <const> = 64  -- kept per ban (enrichment adds up to this)
local MAX_BAN_TOKENS <const> = 128
local MAX_REASON <const> = 256
local MAX_EVIDENCE <const> = 512
local MAX_NAME <const> = 64
local MAX_ID <const> = 64
local MAX_TEXT <const> = 128
local CONNECT_TIMEOUT_MS <const> = 5000   -- the connect check: an outage falls back fast (player_store, failClosed)
local MAX_DURATION <const> = 100 * 365 * 86400
local DEFAULT_LIMIT <const> = 50
local MAX_LIMIT <const> = 200
local SWEEP_MS <const> = 60000
local ID_ATTEMPTS <const> = 16
local ID_PATTERN <const> = '^[%w_%-:]+$'

local options = { tokenMatches = 2, enrichTokens = true, enrichIdentifiers = true }   -- settings cache
local startedAt = os.time()   -- the first sweep counts only bans that ended after core started
local lastSweepAt = nil       -- os.time() of the last successful sweep (nil: none yet — the full flag pass is due)
local touched = {}            -- [accountId] = true: flags add/remove/enrich wrote since the last sweep (re-checked)
local hitCounts = {}          -- [banId] = the hits this core last queued (a queued patch may not have landed yet)
local relinkDone = false      -- the R2-12 relink statement succeeded once (nothing creates `relink` any more)

local SETTINGS_SECTION <const> = {
    id = 'bans', title = 'Bans', icon = 'gavel', order = 910, properties = {
        ['bans.tokenMatches'] = { type = 'integer', default = 2, min = 0, max = 10, unit = 'tokens',
            label = 'Token matches', group = 'Matching', order = 1,
            description = 'Distinct hardware tokens of a player that must be in one ban for a token-only match '
                .. '(0 = tokens never match alone). Identifiers always match on one overlap.' },
        ['bans.enrichTokens'] = { type = 'boolean', default = true, label = 'Learn new tokens',
            group = 'Enrichment', order = 2,
            description = "On a refused connection, add the player's unseen tokens to the ban." },
        ['bans.enrichIdentifiers'] = { type = 'boolean', default = true, label = 'Learn new identifiers',
            group = 'Enrichment', order = 3,
            description = "On a refused connection, add the player's unseen identifiers to the ban (only after "
                .. 'an identifier match or at least two matching tokens).' },
        ['bans.failClosed'] = { type = 'boolean', default = true, label = 'Refuse while unavailable',
            group = 'Availability', order = 4,
            description = 'While the ban list cannot be read, refuse connections ("try again in a minute") '
                .. 'instead of letting everyone in (the connect path in server/player_store.lua reads this).' },
    },
}

-- == SQL ====================================================================================================

-- one ban and its link rows; every read selects this and rowToBan maps it
local BAN_COLUMNS <const> = [[
b.id, b.account_id, b.name, b.reason, b.evidence, b.by_account_id, b.by_name, b.expires_at, b.revoked_at,
b.revoked_by_account_id, b.revoked_by_name, b.revoke_reason, b.hits, b.last_hit_at, b.relink, b.created_at,
b.updated_at,
ARRAY(SELECT x.account_id FROM ban_accounts x WHERE x.ban_id = b.id ORDER BY x.position, x.account_id) AS account_ids,
ARRAY(SELECT x.identifier FROM ban_identifiers x WHERE x.ban_id = b.id ORDER BY x.identifier) AS identifier_list,
ARRAY(SELECT x.token FROM ban_tokens x WHERE x.ban_id = b.id ORDER BY x.token) AS token_list]]

-- newest first; within one second the longer counter id is the newer ('B10' before 'B9')
local NEWEST_FIRST <const> = 'ORDER BY b.created_at DESC, length(b.id) DESC, b.id COLLATE "C" DESC'

-- the connect check: $1 identifiers, $2 tokens (distinct), $3 now, $4 bans.tokenMatches, $5 the connecting license
local CHECK_SQL <const> = [[
WITH hit AS (
    SELECT c.ban_id, bool_or(c.by_identifier) AS by_identifier,
           count(*) FILTER (WHERE NOT c.by_identifier) AS token_hits
    FROM (SELECT ban_id, true AS by_identifier FROM ban_identifiers WHERE identifier = ANY($1::text[])
          UNION ALL
          SELECT ban_id, false FROM ban_tokens WHERE token = ANY($2::text[])) AS c
    GROUP BY c.ban_id
)
SELECT h.by_identifier, h.token_hits, la.id AS license_account_id, la.name AS license_account_name,
]] .. BAN_COLUMNS .. [[

FROM hit h
JOIN bans b ON b.id = h.ban_id
LEFT JOIN accounts la ON la.license = $5::text
WHERE b.revoked_at IS NULL AND (b.expires_at IS NULL OR b.expires_at > to_timestamp($3))
  AND (h.by_identifier OR ($4::int > 0 AND h.token_hits >= $4::int))
ORDER BY b.expires_at DESC NULLS FIRST, b.created_at DESC, b.id DESC
LIMIT 1]]

-- enrichment: account learning as ONE keyed queued statement — the link row and the flag follow only when the
-- `account_id IS NULL` guard really updated the ban. $1 ban, $2 account, $3 name, $4 link position
local LEARN_SQL <const> = [[
WITH learned AS (
    UPDATE bans SET account_id = $2::text, name = CASE WHEN name = 'unknown' THEN $3::text ELSE name END
    WHERE id = $1::text AND account_id IS NULL
    RETURNING id, account_id
), linked AS (
    INSERT INTO ban_accounts (ban_id, account_id, position)
    SELECT l.id, l.account_id, $4::smallint FROM learned l
    ON CONFLICT (ban_id, account_id) DO NOTHING
)
UPDATE accounts a SET banned = true FROM learned l WHERE a.id = l.account_id AND NOT a.banned]]

-- accounts.banned = "an active ban names the account", written in ONE statement wherever it changes.
-- $1 account ids, $2 now → the rows whose flag changed { id, banned }
local FLAG_SQL <const> = [[
UPDATE accounts a SET banned = f.banned
FROM (SELECT c.id, EXISTS (SELECT 1 FROM bans x WHERE x.account_id = c.id AND x.revoked_at IS NULL
                           AND (x.expires_at IS NULL OR x.expires_at > to_timestamp($2))) AS banned
      FROM unnest($1::text[]) AS c(id)) AS f
WHERE a.id = f.id AND a.banned IS DISTINCT FROM f.banned
RETURNING a.id, a.banned]]

-- remove: $1 id, $2 now, $3 revoker account, $4 revoker name, $5 reason
local REVOKE_SQL <const> = [[
UPDATE bans SET revoked_at = to_timestamp($2), revoked_by_account_id = $3, revoked_by_name = $4, revoke_reason = $5
WHERE id = $1 AND revoked_at IS NULL
RETURNING id, account_id, name, (expires_at IS NULL OR expires_at > to_timestamp($2)) AS was_active]]

-- sweep: $1 now, $2 the last sweep (NULL = every ended ban), $3 the floor of the count, $4 accounts touched by
-- add/remove/enrich since the last sweep (a concurrent writer's READ COMMITTED view may have left them wrong),
-- $5 full = the first sweep after start (every flagged account and every account an active ban names — imported
-- or stale flags; one pass over the flagged accounts per start). The flag is recomputed for every candidate.
local SWEEP_SQL <const> = [[
WITH ended AS (
    SELECT b.account_id, b.expires_at FROM bans b
    WHERE b.revoked_at IS NULL AND b.expires_at <= to_timestamp($1)
      AND ($2::bigint IS NULL OR b.expires_at > to_timestamp($2::bigint))
), candidates AS (
    SELECT e.account_id AS id FROM ended e WHERE e.account_id IS NOT NULL
    UNION SELECT t.id FROM unnest($4::text[]) AS t(id)
    UNION SELECT a.id FROM accounts a WHERE $5::boolean AND a.banned
    UNION SELECT b.account_id FROM bans b
          WHERE $5::boolean AND b.account_id IS NOT NULL AND b.revoked_at IS NULL
            AND (b.expires_at IS NULL OR b.expires_at > to_timestamp($1))
), changed AS (
    UPDATE accounts a SET banned = f.banned
    FROM (SELECT c.id, EXISTS (SELECT 1 FROM bans x WHERE x.account_id = c.id AND x.revoked_at IS NULL
                               AND (x.expires_at IS NULL OR x.expires_at > to_timestamp($1))) AS banned
          FROM candidates c) AS f
    WHERE a.id = f.id AND a.banned IS DISTINCT FROM f.banned
    RETURNING a.id, a.banned
)
SELECT (SELECT count(*) FROM ended WHERE expires_at > to_timestamp($3))::int AS expired,
       ARRAY(SELECT id FROM changed WHERE banned) AS flagged, ARRAY(SELECT id FROM changed WHERE NOT banned) AS cleared]]

-- R2-12: bans imported with `relink = <license>` (their account was unreadable when the old Lua migration ran)
-- take the account behind the license (flagged while the ban is active); the marker goes either way. $1 now.
local RELINK_SQL <const> = [[
WITH pending AS (
    SELECT b.id, a.id AS found_id, a.name AS found_name
    FROM bans b LEFT JOIN accounts a ON a.license = b.relink
    WHERE b.relink IS NOT NULL
), linked AS (
    UPDATE bans b SET relink = NULL, account_id = COALESCE(b.account_id, p.found_id),
        name = CASE WHEN b.account_id IS NULL AND p.found_id IS NOT NULL AND b.name = 'unknown'
                    THEN left(COALESCE(NULLIF(p.found_name, ''), 'unknown'), 64) ELSE b.name END
    FROM pending p WHERE b.id = p.id
    RETURNING b.id, b.account_id, b.revoked_at, b.expires_at
), links AS (
    INSERT INTO ban_accounts (ban_id, account_id, position)
    SELECT l.id, l.account_id, 0 FROM linked l WHERE l.account_id IS NOT NULL
    ON CONFLICT (ban_id, account_id) DO NOTHING
), flagged AS (
    UPDATE accounts a SET banned = true FROM linked l
    WHERE a.id = l.account_id AND l.revoked_at IS NULL
      AND (l.expires_at IS NULL OR l.expires_at > to_timestamp($1))
    RETURNING a.id
)
SELECT (SELECT count(*) FROM linked)::int AS relinked, ARRAY(SELECT id FROM flagged) AS flagged]]

-- == helpers ================================================================================================

local function clean(value, max)
    if value == nil then return nil end
    local text = Utils.sanitize(tostring(value), max)
    while #text > 0 and not utf8.len(text) do text = text:sub(1, -2) end
    if text == '' then return nil end
    return text
end

local function toSrc(value)
    if type(value) == 'string' and value:match('^%d+$') then value = tonumber(value) end
    if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
    value = math.tointeger(value)
    if not value or value <= 0 or value > 0x7FFFFFFF then return nil end
    return value
end

local keyOf = Identity.key   -- a storable identifier/token in canonical (lower-case) form, or nil

local function isBanId(value)
    return type(value) == 'string' and #value >= 1 and #value <= MAX_ID and value:match(ID_PATTERN) ~= nil
end

--- A de-duplicated array of valid identifiers/tokens (ip: dropped), at most `max`.
local function cleanKeys(list, max, into, seen)
    into, seen = into or {}, seen or {}
    if type(list) ~= 'table' then return into, seen end
    for i = 1, #list do
        if #into >= max then break end
        local key = keyOf(list[i])
        if key and not seen[key] then
            seen[key] = true
            into[#into + 1] = key
        end
    end
    return into, seen
end

--- A text[] column as a Lua sequence (absent / odd → empty).
local function listOf(value)
    return type(value) == 'table' and value or {}
end

--- `%`, `_` and `\` taken literally inside an ILIKE pattern (the default escape character is `\`).
local function likeEscape(text)
    return (text:gsub('[\\%%_]', '\\%0'))
end

local playerApi, infoOf, collectIdentity = Identity.playerApi, Identity.info, Identity.collect

--- [accountId] = src of every loaded player (built only when a flag change must reach live sessions).
local function onlineAccounts()
    local out = {}
    local player = playerApi()
    local getPlayers = player and rawget(player, 'getPlayers')
    if type(getPlayers) ~= 'function' then return out end
    local ok, list = pcall(getPlayers)
    if not ok or type(list) ~= 'table' then return out end
    for i = 1, #list do
        local info = infoOf(list[i])
        if info and info.accountId ~= nil then out[info.accountId] = list[i] end
    end
    return out
end

--- accounts.banned changes { { id, banned }, ... } (rows a statement already wrote) into the live sessions — the
--- session is the source of truth of its account while it exists (Player.setAccountData queues the same value).
--- `hintSrc` skips the player walk when the one account is that src's.
local function pushFlags(rows, hintSrc)
    if type(rows) ~= 'table' or rows[1] == nil then return end
    local player = playerApi()
    if not player or type(rawget(player, 'setAccountData')) ~= 'function' then return end
    local hinted, online = hintSrc and infoOf(hintSrc), nil
    for i = 1, #rows do
        local id, flag = rows[i].id, rows[i].banned == true
        local src
        if hinted and hinted.accountId == id then
            src = hintSrc
        else
            online = online or onlineAccounts()
            src = online[id]
        end
        if src then pcall(player.setAccountData, src, 'banned', flag) end
    end
end

--- The { id, banned } rows of the sweep's two id arrays.
local function flagRows(flagged, cleared)
    local rows = {}
    for _, id in ipairs(listOf(flagged)) do rows[#rows + 1] = { id = id, banned = true } end
    for _, id in ipairs(listOf(cleared)) do rows[#rows + 1] = { id = id, banned = false } end
    return rows
end

--- The ban shape of one row of BAN_COLUMNS (the ONE snake_case → camelCase mapping).
local function rowToBan(row)
    local revoked = nil
    if row.revoked_at ~= nil then
        revoked = { by = { accountId = row.revoked_by_account_id, name = row.revoked_by_name or 'console' },
            at = row.revoked_at, reason = row.revoke_reason }
    end
    return {
        id = row.id, _v = VERSION, accountId = row.account_id, accountIds = listOf(row.account_ids),
        name = row.name or 'unknown', identifiers = listOf(row.identifier_list), tokens = listOf(row.token_list),
        reason = row.reason or 'No reason given', evidence = row.evidence,
        by = { accountId = row.by_account_id, name = row.by_name or 'console' },
        createdAt = row.created_at or 0, expiresAt = row.expires_at or 0, revoked = revoked,
        hits = math.tointeger(row.hits) or 0, lastHitAt = row.last_hit_at, relink = row.relink,
        updatedAt = row.updated_at,
    }
end

--- Bans matching `whereSql` (placeholders in `params`), mapped → list | nil, err. Awaited.
local function selectBans(whereSql, params, tail)
    local rows, err = DB.query(('SELECT %s\nFROM bans b\nWHERE %s\n%s'):format(BAN_COLUMNS, whereSql, tail or ''), params)
    if not rows then return nil, err end
    local out = {}
    for i = 1, #rows do out[i] = rowToBan(rows[i]) end
    return out
end

--- The best active ban for these identifiers / tokens (the ONE statement of the connect path) →
--- { ban, byIdentifier, tokenHits, licenseAccount? } | false (none) | nil, err. Awaited.
local function findActive(ids, tokens, license, opts)
    if ids[1] == nil and tokens[1] == nil then return false end
    local need = math.tointeger(options.tokenMatches) or 2
    local rows, err = DB.query(CHECK_SQL, { ids, tokens, os.time(), need, license or DB.NULL }, opts)
    if not rows then return nil, err end
    local row = rows[1]
    if row == nil then return false end
    return {
        ban = rowToBan(row), byIdentifier = row.by_identifier == true,
        tokenHits = math.tointeger(row.token_hits) or 0,
        licenseAccount = row.license_account_id ~= nil
            and { id = row.license_account_id, name = row.license_account_name } or nil,
    }
end

--- Reads the three bans.* settings into `options` (Settings.get may yield once: threads only).
local function refreshSettings()
    local settings = rawget(Core, 'Settings')
    local get = type(settings) == 'table' and rawget(settings, 'get') or nil
    if type(get) ~= 'function' then return end
    for _, key in ipairs({ 'tokenMatches', 'enrichTokens', 'enrichIdentifiers' }) do
        local ok, value = pcall(get, 'bans.' .. key)
        local count = ok and math.type(value) and math.tointeger(value)
        if count and count >= 0 and count <= 10 then options[key] = count end
        if ok and type(value) == 'boolean' then options[key] = value end
    end
end

--- Core's 'bans' settings section (owner core) + a change watcher; a no-op without Core.Settings.
local function defineSettings()
    local settings = rawget(Core, 'Settings')
    if type(settings) ~= 'table' or type(rawget(settings, 'define')) ~= 'function' then return false end
    local ok, err = settings.define(SETTINGS_SECTION)
    if not ok then
        Log.warn('bans: settings section refused: %s', tostring(err))
        return false
    end
    if type(rawget(settings, 'onChange')) == 'function' then
        settings.onChange('bans.', function() refreshSettings() end)
    end
    refreshSettings()
    return true
end

-- == messages, actors, audit ================================================================================

--- The text a banned player sees (kick and connect rejection).
local function rejectMessage(ban)
    local reason = clean(ban.reason, 128) or 'No reason given'
    local expiresAt = math.tointeger(tonumber(ban.expiresAt) or 0) or 0
    if expiresAt <= 0 then
        return ('You are permanently banned. Reason: %s (ban %s)'):format(reason, tostring(ban.id))
    end
    return ('You are banned until %s. Reason: %s (ban %s)')
        :format(os.date('%Y-%m-%d %H:%M', expiresAt), reason, tostring(ban.id))
end

--- by = src | 0 | nil (console) | a legacy name string -> { accountId?, name } + the Core.Audit actor.
local function actorOf(by)
    if by == nil or by == 0 or by == '0' or by == 'console' then return { name = 'console' }, 0 end
    local src = toSrc(by)
    if src then
        local info = infoOf(src)
        local name = clean(info and info.name or GetPlayerName(src), MAX_NAME) or ('player ' .. src)
        if info then return { accountId = clean(info.accountId, MAX_ID), name = name }, src end
        return { name = name }, src
    end
    local name = clean(by, MAX_NAME) or 'console'
    return { name = name }, { kind = 'system', name = name }
end

local function audit(action, actor, ban, reason, message, source, onlineSrc, ctx)
    local api = rawget(Core, 'Audit')
    if type(api) ~= 'table' or type(api.record) ~= 'function' then return end
    local targets = { { type = 'ban', id = ban.id, name = ban.name } }
    if onlineSrc then
        targets[#targets + 1] = { type = 'player', id = onlineSrc, name = ban.name, accountId = ban.accountId }
    elseif ban.accountId then
        targets[#targets + 1] = { type = 'account', id = ban.accountId, name = ban.name }
    end
    local ok, err = pcall(api.record, {
        actor = actor, action = action, source = source, targets = targets, reason = reason,
        message = message, ctx = ctx,
    })
    if not ok then Log.warn('bans: audit failed: %s', tostring(err)) end
end

local function describeDuration(seconds)
    if seconds == 0 then return 'permanently' end
    if seconds % 86400 == 0 then return ('for %d day(s)'):format(seconds // 86400) end
    if seconds % 3600 == 0 then return ('for %d hour(s)'):format(seconds // 3600) end
    return ('for %d s'):format(seconds)
end

-- == targets and enrichment =================================================================================

--- target = src | { accountId?, identifiers?, tokens?, name? } -> { src?, accountId?, name?, ids, tokens }.
--- An explicit account that does not exist is dropped (bans.account_id references accounts). Yields.
local function resolveIdentity(target)
    local src = toSrc(target)
    if src then
        if not GetPlayerName(src) then return nil, 'not_connected' end
        local ids, tokens = collectIdentity(src)
        local info = infoOf(src)
        return { src = src, accountId = info and clean(info.accountId, MAX_ID) or nil,
            name = clean(info and info.name or GetPlayerName(src), MAX_NAME), ids = ids, tokens = tokens }
    end
    if type(target) ~= 'table' then return nil, 'invalid_target' end
    local accountId = nil
    if target.accountId ~= nil then
        if not isBanId(target.accountId) then return nil, 'invalid_account' end
        accountId = target.accountId
    end
    local ids, seenIds = cleanKeys(target.identifiers, MAX_IDENTIFIERS)
    local tokens, seenTokens = cleanKeys(target.tokens, MAX_TOKENS)
    local name = clean(target.name, MAX_NAME)
    if accountId then
        src = onlineAccounts()[accountId]
        if src then
            local liveIds, liveTokens = collectIdentity(src)
            cleanKeys(liveIds, MAX_BAN_IDENTIFIERS, ids, seenIds)
            cleanKeys(liveTokens, MAX_BAN_TOKENS, tokens, seenTokens)
            local info = infoOf(src)
            name = name or clean(info and info.name, MAX_NAME)
        else
            local account, err = Identity.account(accountId)
            if account == nil then
                Log.error('bans: account %s cannot be read (%s)', accountId, tostring(err))
                return nil, 'db'
            end
            if not account then
                if #ids == 0 and #tokens == 0 then return nil, 'unknown_account' end
                accountId = nil
            else
                local stored = account.identifiers
                table.sort(stored)
                cleanKeys(stored, MAX_BAN_IDENTIFIERS, ids, seenIds)
                name = name or clean(account.name, MAX_NAME)
            end
        end
    end
    return { src = src, accountId = accountId, name = name, ids = ids, tokens = tokens }
end

--- resolveIdentity, then every account holding one of the identifiers and every online player the ban would
--- refuse (§47, review H2): `accounts` = { { id, group } }, `holders` = { src }, `accountIds` = { id } with the
--- explicit account first. An identifier-only target with exactly one holding account gets that accountId.
local function resolveTarget(target)
    local resolved, err = resolveIdentity(target)
    if not resolved then return nil, err end
    local accounts, holders, unreadable = Identity.holders(resolved.ids, resolved.tokens, resolved.src,
        options.tokenMatches)
    resolved.accountsUnreadable = unreadable
    local accountIds, seen = { resolved.accountId }, { [resolved.accountId or false] = true }
    for i = 1, #accounts do
        if not seen[accounts[i].id] then
            seen[accounts[i].id] = true
            accountIds[#accountIds + 1] = accounts[i].id
        end
    end
    if not resolved.accountId and #accounts == 1 then
        resolved.accountId = accounts[1].id
        resolved.name = resolved.name or clean(accounts[1].name, MAX_NAME)
    end
    resolved.accounts, resolved.holders, resolved.accountIds = accounts, holders, accountIds
    return resolved
end

--- One queued enrichment write (the call goes LAST so both of its results arrive); a refusal is logged — the
--- refusal of the connection itself is already decided.
local function queued(what, banId, ok, err)
    if not ok then Log.warn('bans: the %s of %s was not queued (%s)', what, banId, tostring(err)) end
end

--- A hit on connect: new identifiers/tokens join the ban (a second account on the same PC is caught next
--- time), hits/lastHitAt move. Review M3: identifiers join only after an identifier match or >= 2 matching
--- tokens (never after one shared token), and an account-less ban learns an account only from an identifier
--- match, never from tokens alone — and only the account of a license the ban holds (now). Every write is QUEUED
--- in this one slice and none is an unkeyed barrier (a player spamming reconnects must not fragment the flushes):
--- hits as a `patch` (an absolute count: this core is the only writer, `hitCounts` covers a patch still queued),
--- new identifiers/tokens as PK-only `save`s (DO NOTHING), the account learning as one statement keyed per ban.
--- The returned ban already shows them. Never yields.
local function enrich(hit, ids, tokens, license)
    local ban = hit.ban
    local idList, seenIds = cleanKeys(ban.identifiers, MAX_BAN_IDENTIFIERS)
    local tokenList, seenTokens = cleanKeys(ban.tokens, MAX_BAN_TOKENS)
    local idCount, tokenCount = #idList, #tokenList
    if options.enrichIdentifiers and (hit.byIdentifier or hit.tokenHits >= 2) then
        cleanKeys(ids, MAX_BAN_IDENTIFIERS, idList, seenIds)
    end
    if options.enrichTokens then cleanKeys(tokens, MAX_BAN_TOKENS, tokenList, seenTokens) end
    local now = os.time()
    local hits = math.max(ban.hits, hitCounts[ban.id] or 0) + 1
    hitCounts[ban.id] = hits
    queued('hit', ban.id, DB.patch('bans', ban.id, { hits = hits, last_hit_at = now }))
    for i = idCount + 1, #idList do
        queued('identifier', ban.id, DB.save('ban_identifiers', { ban_id = ban.id, identifier = idList[i] }))
    end
    for i = tokenCount + 1, #tokenList do
        queued('token', ban.id, DB.save('ban_tokens', { ban_id = ban.id, token = tokenList[i] }))
    end
    ban.hits, ban.lastHitAt, ban.identifiers, ban.tokens = hits, now, idList, tokenList
    local account = hit.licenseAccount
    if not ban.accountId and hit.byIdentifier and account and license and seenIds[license] then
        local name = clean(account.name, MAX_NAME)
        queued('account', ban.id, DB.enqueue(LEARN_SQL, { ban.id, account.id, name or 'unknown', #ban.accountIds },
            'core:bans.learn:' .. ban.id))
        touched[account.id] = true   -- the next sweep re-checks the flag the statement wrote
        ban.accountId = account.id
        if ban.name == 'unknown' and name then ban.name = name end
        local listed = false
        for i = 1, #ban.accountIds do listed = listed or ban.accountIds[i] == account.id end
        if not listed then ban.accountIds[#ban.accountIds + 1] = account.id end
    end
    return ban
end

--- The ban, its link rows and accounts.banned (recomputed: it sees the new ban) in ONE transaction → the new id
--- (the sequence's 'B<n>') and the changed flags { { id, banned } } | nil, err.
--- An imported 'B<n>' above the sequence clashes on the primary key: the next attempt takes the next number.
local function insertBan(row, accountIds, ids, tokens)
    local lastErr
    for _ = 1, ID_ATTEMPTS do
        local ok, result = DB.transaction(function(tx)
            local inserted, err = tx.insert('bans', row, { returning = { 'id' } })
            if not inserted then return false, err end
            local id = inserted.id
            local links, keys, toks = {}, {}, {}
            for i = 1, #accountIds do links[i] = { ban_id = id, account_id = accountIds[i], position = i - 1 } end
            for i = 1, #ids do keys[i] = { ban_id = id, identifier = ids[i] } end
            for i = 1, #tokens do toks[i] = { ban_id = id, token = tokens[i] } end
            for _, batch in ipairs({ { 'ban_accounts', links }, { 'ban_identifiers', keys }, { 'ban_tokens', toks } }) do
                if batch[2][1] ~= nil then
                    local count, linkErr = tx.insertMany(batch[1], batch[2])
                    if not count then return false, linkErr end
                end
            end
            local flags = {}
            if row.account_id then
                local changed, flagErr = tx.query(FLAG_SQL, { { row.account_id }, row.created_at })
                if not changed then return false, flagErr end
                flags = changed
            end
            return { id = id, flags = flags }
        end)
        if ok then return result.id, result.flags end
        lastErr = result
        if DB.errorCode(result) ~= '23505' or not tostring(result):find('bans_pkey', 1, true) then break end
    end
    return nil, lastErr
end

-- == public API =============================================================================================

--- Ban an online player (identifiers + tokens collected now, then kicked) or an offline identity. Yields.
--- opts = { target, reason, duration = seconds (0 = permanent), by = src|0, evidence?, source? }
--- @return table|nil ban, string|nil err
function Bans.add(opts)
    if type(opts) ~= 'table' then return nil, 'invalid' end
    local duration = opts.duration == nil and 0 or opts.duration
    if type(duration) ~= 'number' or duration ~= duration or duration < 0 or duration > MAX_DURATION then
        return nil, 'invalid_duration'
    end
    local whole = math.floor(duration)
    if whole == 0 and duration ~= 0 then return nil, 'invalid_duration' end   -- (0, 1) s is no ban, never "permanent"
    duration = whole
    if opts.evidence ~= nil and type(opts.evidence) ~= 'string' then return nil, 'invalid_evidence' end
    local target, err = resolveTarget(opts.target)
    if not target then return nil, err end
    if #target.ids == 0 and #target.tokens == 0 then return nil, 'no_identifiers' end
    local by, actor = actorOf(opts.by)
    -- a player actor never bans an identity that reaches its own rank or above (review H2)
    if math.type(actor) == 'integer' and actor > 0 then
        if target.accountsUnreadable then return nil, 'db' end   -- R2-11: never pass the check blind
        if not Identity.outranksAll(actor, target.accounts, target.holders) then return nil, 'rank' end
    end
    local now = os.time()
    local expiresAt = duration > 0 and now + duration or 0
    local ban = {
        _v = VERSION, accountId = target.accountId, accountIds = target.accountIds, name = target.name or 'unknown',
        identifiers = target.ids, tokens = target.tokens, reason = clean(opts.reason, MAX_REASON) or 'No reason given',
        evidence = clean(opts.evidence, MAX_EVIDENCE), by = by, createdAt = now, expiresAt = expiresAt, hits = 0,
    }
    local id, flags = insertBan({
        account_id = ban.accountId, name = ban.name, reason = ban.reason, evidence = ban.evidence,
        by_account_id = by.accountId, by_name = by.name, expires_at = expiresAt > 0 and expiresAt or nil,
        hits = 0, created_at = now, updated_at = now,
    }, ban.accountIds, ban.identifiers, ban.tokens)
    if not id then
        Log.error('bans: the ban on %s could not be stored (%s)', ban.name, tostring(flags))
        return nil, 'db'
    end
    ban.id, ban.updatedAt = id, now
    if ban.accountId then touched[ban.accountId] = true end
    pushFlags(flags, target.src)
    local span = describeDuration(duration)
    audit('ban.add', actor, ban, ban.reason, ('%s banned %s'):format(ban.name, span), opts.source, target.src,
        { duration = duration, expiresAt = ban.expiresAt, accounts = #target.accountIds, kicked = #target.holders })
    Log.info('ban %s: %s banned %s by %s', ban.id, ban.name, span, by.name or '?')
    -- everyone online the ban would refuse at their next connect leaves now (the target first)
    local notice = rejectMessage(ban)
    if target.src then DropPlayer(target.src, notice) end
    for i = 1, #target.holders do
        if target.holders[i] ~= target.src then DropPlayer(target.holders[i], notice) end
    end
    return ban
end

--- Revoke a ban (kept for history). Clears account.banned when it was the account's last active ban. Yields.
--- @return boolean ok, string|nil err
function Bans.remove(banId, by, reason)
    if not isBanId(banId) then return false, 'invalid' end
    local revokedBy, actor = actorOf(by)
    local text = clean(reason, MAX_REASON)
    local now = os.time()
    local ok, result = DB.transaction(function(tx)
        local rows, err = tx.query(REVOKE_SQL, { banId, now, revokedBy.accountId or DB.NULL,
            revokedBy.name or 'console', text or DB.NULL })
        if not rows then return false, err end
        local row = rows[1]
        if row == nil then
            local state, stateErr = tx.query('SELECT revoked_at FROM bans WHERE id = $1', { banId })
            if not state then return false, stateErr end
            return false, state[1] ~= nil and 'already_revoked' or 'not_found'
        end
        local flags = {}
        if row.account_id ~= nil then
            local changed, flagErr = tx.query(FLAG_SQL, { { row.account_id }, now })
            if not changed then return false, flagErr end
            flags = changed
        end
        return { id = row.id, accountId = row.account_id, name = row.name, wasActive = row.was_active == true,
            flags = flags }
    end)
    if not ok then
        if result == 'already_revoked' or result == 'not_found' then return false, result end
        Log.error('bans: %s could not be revoked (%s)', banId, tostring(result))
        return false, 'db'
    end
    if result.accountId then touched[result.accountId] = true end
    pushFlags(result.flags)
    audit('ban.remove', actor, result, text, ('ban %s on %s revoked'):format(banId, result.name or 'unknown'), nil, nil,
        { wasActive = result.wasActive })
    return true
end

--- One ban (history included) or nil; nil, 'db' when it cannot be read. Yields.
function Bans.get(banId)
    if not isBanId(banId) then return nil end
    local list, err = selectBans('b.id = $1', { banId })
    if not list then
        Log.error('bans: %s cannot be read (%s)', banId, tostring(err))
        return nil, 'db'
    end
    return list[1]
end

--- The best active ban for these identifiers/tokens, or nil; nil, 'unavailable' when bans cannot be read. Yields.
function Bans.check(identifiers, tokens)
    local hit, err = findActive((cleanKeys(identifiers, MAX_IDENTIFIERS)), (cleanKeys(tokens, MAX_TOKENS)))
    if hit == nil then
        Log.error('bans: the ban list cannot be read (%s)', tostring(err))
        return nil, 'unavailable'
    end
    return hit and hit.ban or nil
end

--- The connect path (playerConnecting deferral, server/player_store.lua): collect identifiers (no ip:) and
--- tokens, ONE check statement, enrich the ban on a hit (queued). Returns the ban and the finished rejection
--- text; `nil, 'unavailable'` when the check cannot be read (the caller decides: its own lookup, then
--- bans.failClosed). A plain `nil` = not banned. Yields (one query).
--- @return table|nil ban, string|nil messageOrUnavailable
function Bans.checkConnecting(src)
    src = toSrc(src)
    if not src then return nil end
    local rawIds, rawTokens = collectIdentity(src)
    local ids, tokens = cleanKeys(rawIds, MAX_IDENTIFIERS), cleanKeys(rawTokens, MAX_TOKENS)
    local license = nil
    for i = 1, #ids do
        if ids[i]:sub(1, 8) == 'license:' then
            license = ids[i]
            break
        end
    end
    local hit, err = findActive(ids, tokens, license, { timeout = CONNECT_TIMEOUT_MS })
    if hit == nil then
        Log.error('bans: the ban list cannot be read for [%d] (%s)', src, tostring(err))
        return nil, 'unavailable'
    end
    if not hit then return nil end
    local ban = enrich(hit, ids, tokens, license)
    Log.info('ban %s refused a connection from %s', ban.id, clean(GetPlayerName(src), MAX_NAME) or '?')
    return ban, rejectMessage(ban)
end

--- opts = { active? = true (false = every ban, history included), text?, accountId?, limit? = 50 (<= 200),
--- before? = cursor } -> { rows, next }, newest first; nil, 'db' when bans cannot be read. The cursor is
--- '<createdAt>/<id>'; `text` is a case-insensitive substring of id, name, reason, account or an identifier.
function Bans.list(opts)
    if type(opts) ~= 'table' then opts = {} end
    local accountId = isBanId(opts.accountId) and opts.accountId or nil
    if opts.accountId ~= nil and not accountId then return { rows = {} } end   -- never widen the result
    local text = type(opts.text) == 'string' and opts.text ~= '' and opts.text:sub(1, MAX_TEXT) or nil
    local limit = (type(opts.limit) == 'number' and opts.limit == opts.limit)
        and math.max(1, math.min(MAX_LIMIT, math.floor(opts.limit))) or DEFAULT_LIMIT
    local where, params = { 'TRUE' }, {}
    local function param(value)
        params[#params + 1] = value
        return '$' .. #params
    end
    if accountId then
        local p = param(accountId)
        where[#where + 1] = ('(b.account_id = %s OR EXISTS (SELECT 1 FROM ban_accounts x WHERE x.ban_id = b.id '
            .. 'AND x.account_id = %s))'):format(p, p)
    end
    if opts.active ~= false then
        where[#where + 1] = ('b.revoked_at IS NULL AND (b.expires_at IS NULL OR b.expires_at > to_timestamp(%s))')
            :format(param(os.time()))
    end
    if text then
        local p = param('%' .. likeEscape(text) .. '%')
        where[#where + 1] = ('(b.id ILIKE %s OR b.name ILIKE %s OR b.reason ILIKE %s OR b.account_id ILIKE %s OR '
            .. 'EXISTS (SELECT 1 FROM ban_identifiers x WHERE x.ban_id = b.id AND x.identifier ILIKE %s))')
            :format(p, p, p, p, p)
    end
    if opts.before ~= nil then
        local at, id = tostring(opts.before):match('^(%d+)/(.+)$')
        if not at or #at > 12 or #id > MAX_ID then return { rows = {} } end
        local pAt, pLen, pId = param(tonumber(at)), param(#id), param(id)
        -- after the cursor row: an older second, or the same second and a shorter / smaller id
        where[#where + 1] = ('(b.created_at < to_timestamp(%s) OR (b.created_at < to_timestamp(%s) + interval \'1 second\' '
            .. 'AND (length(b.id) < %s OR (length(b.id) = %s AND b.id COLLATE "C" < %s))))')
            :format(pAt, pAt, pLen, pLen, pId)
    end
    local rows, err = selectBans(table.concat(where, ' AND '), params,
        ('%s LIMIT %d'):format(NEWEST_FIRST, limit + 1))
    if not rows then
        Log.error('bans: the ban list cannot be read (%s)', tostring(err))
        return nil, 'db'
    end
    local more = #rows > limit
    if more then rows[#rows] = nil end
    local last = rows[#rows]
    return { rows = rows, next = (more and last) and ('%d/%s'):format(last.createdAt, last.id) or nil }
end

--- Every ban of one account (history included; its `accountId` or listed in `accountIds`), newest first;
--- nil, 'db' when bans cannot be read. Yields.
function Bans.forAccount(accountId)
    if not isBanId(accountId) then return {} end
    local rows, err = selectBans('(b.account_id = $1 OR EXISTS (SELECT 1 FROM ban_accounts x WHERE x.ban_id = b.id '
        .. 'AND x.account_id = $1))', { accountId }, NEWEST_FIRST)
    if not rows then
        Log.error('bans: the bans of %s cannot be read (%s)', accountId, tostring(err))
        return nil, 'db'
    end
    return rows
end

--- R2-12: link imported bans that still carry `relink` (one statement, until it succeeded once). → relinked
local function relinkPending(now)
    if relinkDone then return 0 end
    local row, err = DB.single(RELINK_SQL, { now })
    if not row then
        Log.warn('bans: imported bans could not be relinked yet (%s); the next sweep retries', tostring(err))
        return 0
    end
    relinkDone = true
    pushFlags(flagRows(row.flagged, nil))
    local count = math.tointeger(row.relinked) or 0
    if count > 0 then Log.info('bans: %d imported ban(s) linked to their account', count) end
    return count
end

--- Bans that expired since the last sweep: recomputes account.banned for their accounts and every account touched
--- since the last sweep (the first run: every flagged account and every one an active ban names), live sessions
--- through Player.setAccountData; then the relink pass. One statement each. Yields.
--- @return integer expired (bans that ended since the previous sweep; the first one counts from core's start)
function Bans.sweep()
    local now = os.time()
    local expired = 0
    local recheck, list = touched, {}
    touched = {}
    for id in pairs(recheck) do list[#list + 1] = id end
    local row, err = DB.single(SWEEP_SQL, { now, lastSweepAt or DB.NULL, lastSweepAt or startedAt, list,
        lastSweepAt == nil })
    if row then
        lastSweepAt = now
        expired = math.tointeger(row.expired) or 0
        pushFlags(flagRows(row.flagged, row.cleared))
        if expired > 0 then Log.info('bans: %d ban(s) expired', expired) end
    else
        for id in pairs(recheck) do touched[id] = true end   -- the next sweep checks them again
        Log.error('bans: the expiry sweep failed (%s)', tostring(err))
    end
    relinkPending(now)
    return expired
end

-- == start ==================================================================================================

local running = true

-- every server file has loaded (Wait(0)); the first sweep waits for core's migrations inside core_db
CreateThread(function()
    Wait(0)
    defineSettings()
    Bans.sweep()
    while running do
        Wait(SWEEP_MS)
        if running and DB.isHealthy() then Bans.sweep() end   -- an outage is logged by core_db, not every minute
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == Core.name then running = false end
end)
