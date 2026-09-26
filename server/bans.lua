--[[
    core/server/bans.lua — Core.Bans (DESIGN §47): bans on identifiers AND tokens.

    add({ target = src | { accountId?, identifiers?, tokens?, name? }, reason, duration, by, evidence?, source? })
    remove(banId, by, reason) · get(id) · list(opts) · forAccount(accountId) · check(identifiers, tokens) · sweep()
    checkConnecting(src) -> ban, text | nil | nil, 'unavailable'   (internal: the playerConnecting path)

    Document (`bans`, `_v = 2`): { id, accountId?, accountIds, name, identifiers, tokens, reason, evidence?,
    by = { accountId?, name }, createdAt, expiresAt (0 = permanent), revoked? = { by, at, reason }, hits,
    lastHitAt? }; `ip:` is never stored. v1 `{ license, by = 'name', until }` is migrated by DB.migrate('bans', 2).

    Memory: `index[identifier|token] = { [banId] = true }` (active bans), `active[banId] = { expiresAt,
    accountId, keys }`, `accountActive[accountId] = n` (account.banned clears with the last one). Expired bans
    leave on a hit and in the daily sweep. The identity half (reading a player's identifiers/tokens, the online
    index of who holds what, the account lookup and the rank check) is server/bans_identity.lua, which loads
    right before this file. v1 bans migrated while `accounts` was unreadable keep `relink = <license>` and
    are linked once it can be read (start thread, retried every minute; the daily sweep) — review R2-12.

    Matching: one identifier overlap, or >= `bans.tokenMatches` (default 2, 0 = never) DISTINCT tokens of one
    ban. Enrichment on a refused connection: tokens (`bans.enrichTokens`), identifiers only after an identifier
    match or >= 2 tokens (`bans.enrichIdentifiers`), an account only from an identifier match — one shared
    token (cafés, cloud gaming) must never spread a ban to a stranger's identity. `bans.failClosed` is read by
    the connect path when this module answers 'unavailable'. A player actor may only ban identities whose
    accounts and online holders it outranks (`'rank'`); every online holder is kicked with the target.

    Natives: GetPlayerName, DropPlayer (server); the identity natives live in server/bans_identity.lua.
]]

local Bans = {}
Core.Bans = Bans

local Log = Core.Log
local Utils = Core.Utils
-- server/bans_identity.lua (loads right before this file): identity reads, the online index, the rank check
local Identity = Core.BanIdentity or error('core: server/bans_identity.lua must load before server/bans.lua', 0)

local COLLECTION <const> = 'bans'
local VERSION <const> = 2
local MAX_IDENTIFIERS <const> = 32      -- collected per player
local MAX_TOKENS <const> = 64
local MAX_BAN_IDENTIFIERS <const> = 64  -- kept per ban (enrichment adds up to this)
local MAX_BAN_TOKENS <const> = 128
local MAX_REASON <const> = 256
local MAX_EVIDENCE <const> = 512
local MAX_NAME <const> = 64
local MAX_ID <const> = 64
local MAX_DURATION <const> = 100 * 365 * 86400
local DEFAULT_LIMIT <const> = 50
local MAX_LIMIT <const> = 200
local LOAD_RETRY_MS <const> = 30000
local ID_PATTERN <const> = '^[%w_%-:]+$'

local index = {}            -- [identifier|token] = { [banId] = true }
local active = {}           -- [banId] = { expiresAt, accountId, keys }
local accountActive = {}    -- [accountId] = active ban count
local loaded = false
local loadBarrier = nil
local legacyAccounts = nil  -- [license] = { id, name } while the v2 migration runs; false = accounts unreadable
local relinks = {}          -- [banId] = license: migrated while `accounts` was unreadable (R2-12)
local relinking = false
local options = { tokenMatches = 2, enrichTokens = true, enrichIdentifiers = true }   -- settings cache

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
                .. 'instead of letting everyone in (the connect path in server/player.lua reads this).' },
    },
}

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

local isKey = Identity.isKey

local function isBanId(value)
    return type(value) == 'string' and #value >= 1 and #value <= MAX_ID and value:match(ID_PATTERN) ~= nil
end

--- A de-duplicated array of valid identifiers/tokens (ip: dropped), at most `max`.
local function cleanKeys(list, max, into, seen)
    into, seen = into or {}, seen or {}
    if type(list) ~= 'table' then return into, seen end
    for i = 1, #list do
        if #into >= max then break end
        local key = list[i]
        if isKey(key) and not seen[key] then
            seen[key] = true
            into[#into + 1] = key
        end
    end
    return into, seen
end

local playerApi, infoOf, collectIdentity = Identity.playerApi, Identity.info, Identity.collect

--- The loaded src of an account, or nil. A loop over the loaded players: add/remove/expiry only.
local function srcForAccount(accountId)
    local player = playerApi()
    local getPlayers = player and rawget(player, 'getPlayers')
    if type(getPlayers) ~= 'function' then return nil end
    local ok, list = pcall(getPlayers)
    if not ok or type(list) ~= 'table' then return nil end
    for i = 1, #list do
        local info = infoOf(list[i])
        if info and info.accountId == accountId then return list[i] end
    end
    return nil
end

--- account.banned: through the live session when online (Player.save would overwrite a direct write),
--- a plain document update when offline. `srcHint` skips the player walk when the caller knows the src.
local function setAccountBanned(accountId, flag, srcHint)
    if not accountId then return end
    local hinted = srcHint and infoOf(srcHint)
    local src = (hinted and hinted.accountId == accountId) and srcHint or srcForAccount(accountId)
    local player = playerApi()
    if src and player and type(rawget(player, 'setAccountData')) == 'function' then
        pcall(player.setAccountData, src, 'banned', flag)
        return
    end
    Core.DB.update('accounts', accountId, { banned = flag })
end

-- == the index ==============================================================================================

local function expiryOf(doc)
    local value = tonumber(doc.expiresAt) or 0
    if value ~= value or value <= 0 then return 0 end
    return math.floor(value)
end

local function isActive(doc, now)
    if type(doc.revoked) == 'table' then return false end
    local expiresAt = expiryOf(doc)
    return expiresAt == 0 or expiresAt > now
end

local function unindex(banId)
    local meta = active[banId]
    if not meta then return nil end
    for i = 1, #meta.keys do
        local set = index[meta.keys[i]]
        if set then
            set[banId] = nil
            if next(set) == nil then index[meta.keys[i]] = nil end
        end
    end
    active[banId] = nil
    local accountId = meta.accountId
    if accountId and accountActive[accountId] then
        local left = accountActive[accountId] - 1
        accountActive[accountId] = left > 0 and left or nil
    end
    return meta
end

--- (Re-)indexes one active ban document. Reads `doc`, never mutates it.
local function indexBan(doc)
    local banId = doc.id
    unindex(banId)
    local keys, seen = cleanKeys(doc.identifiers, MAX_BAN_IDENTIFIERS)
    cleanKeys(doc.tokens, MAX_BAN_IDENTIFIERS + MAX_BAN_TOKENS, keys, seen)
    for i = 1, #keys do
        local set = index[keys[i]]
        if not set then
            set = {}
            index[keys[i]] = set
        end
        set[banId] = true
    end
    local accountId = type(doc.accountId) == 'string' and doc.accountId or nil
    active[banId] = { expiresAt = expiryOf(doc), accountId = accountId, keys = keys }
    if accountId then accountActive[accountId] = (accountActive[accountId] or 0) + 1 end
end

--- Un-index a ban that ended (expired or revoked); clears account.banned with the account's last one.
local function retire(banId)
    local meta = unindex(banId)
    if meta and meta.accountId and not accountActive[meta.accountId] then
        setAccountBanned(meta.accountId, false)
    end
    return meta ~= nil
end

--- The best active ban (permanent first, then the latest expiry), or nil. An identifier matches on one
--- overlap; tokens match only when >= options.tokenMatches DISTINCT tokens are in the same ban (0 = never).
--- Expired bans met on the way are retired after the walk.
--- @return string|nil banId, boolean identifierMatch, integer distinctTokens (of that ban)
local function findActive(ids, tokens)
    local now = os.time()
    local best, bestExpiry, expired = nil, nil, nil
    local byIdentifier, counts = {}, {}
    local function consider(banId, meta)
        local expiresAt = meta.expiresAt
        if expiresAt ~= 0 and expiresAt <= now then
            expired = expired or {}
            expired[banId] = true
        elseif not best or (bestExpiry ~= 0 and (expiresAt == 0 or expiresAt > bestExpiry)) then
            best, bestExpiry = banId, expiresAt
        end
    end
    for i = 1, #ids do
        local set = index[ids[i]]
        if set then
            for banId in pairs(set) do
                local meta = active[banId]
                if meta then
                    byIdentifier[banId] = true
                    consider(banId, meta)
                end
            end
        end
    end
    local need = options.tokenMatches
    if #tokens > 0 then
        local seen = {}
        for i = 1, #tokens do
            local token = tokens[i]
            local set = not seen[token] and index[token] or nil
            seen[token] = true
            if set then
                for banId in pairs(set) do
                    local meta = active[banId]
                    if meta then
                        local n = (counts[banId] or 0) + 1
                        counts[banId] = n
                        if n == need then consider(banId, meta) end   -- need 0: counted, never matches
                    end
                end
            end
        end
    end
    if expired then
        for banId in pairs(expired) do retire(banId) end
    end
    if not best then return nil, false, 0 end
    return best, byIdentifier[best] == true, counts[best] or 0
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

-- == migration v2 and the load ==============================================================================

local function accountForLicense(license)
    if legacyAccounts == nil then
        legacyAccounts = {}
        local ok = pcall(Core.DB.find, 'accounts', function(doc)
            if type(doc.license) == 'string' then legacyAccounts[doc.license] = { id = doc.id, name = doc.name } end
            return false
        end)
        if not ok or Core.DB.isDegraded('accounts') then legacyAccounts = false end
    end
    if legacyAccounts == false then return nil, 'unavailable' end
    return legacyAccounts[license]
end

-- v1 (server/player.lua before §47): { id, license, reason, by = 'name', until = os.time() | 0, createdAt }
Core.DB.migrate(COLLECTION, VERSION, function(doc)
    if type(doc.identifiers) == 'table' and doc.expiresAt ~= nil then return doc end
    local license = type(doc.license) == 'string' and doc.license or nil
    local account, unavailable = nil, nil
    if license then account, unavailable = accountForLicense(license) end
    -- accounts unreadable now: keep the license so the account is linked later, never lose it (R2-12)
    if unavailable and not doc.accountId then doc.relink = license end
    doc.identifiers = isKey(license) and { license } or {}
    doc.tokens = {}
    doc.accountId = doc.accountId or (account and account.id) or nil
    doc.name = clean(doc.name or (account and account.name), MAX_NAME) or 'unknown'
    doc.reason = clean(doc.reason, MAX_REASON) or 'No reason given'
    if type(doc.by) ~= 'table' then doc.by = { name = clean(doc.by, MAX_NAME) or 'console' } end
    local expiry = tonumber(doc['until']) or 0
    doc.expiresAt = (expiry == expiry and expiry > 0) and math.floor(expiry) or 0
    doc.createdAt = doc.createdAt or os.time()
    doc.hits = math.tointeger(tonumber(doc.hits) or 0) or 0
    doc.license, doc['until'] = nil, nil
    return doc
end)

--- Links the bans the v2 migration could not link (accounts unreadable then) once accounts can be read: the
--- account behind the kept license (flagged banned while the ban is active), or none; the marker goes.
--- Start thread (retried every minute while it cannot) and the daily sweep. @return integer relinked
local function relinkPending()
    if relinking or next(relinks) == nil then return 0 end
    relinking = true
    local done = 0
    for banId, license in pairs(relinks) do
        local account = Core.DB.findOne('accounts', { license = license })
        if Core.DB.isDegraded('accounts') then break end
        relinks[banId] = nil
        local ban = Core.DB.get(COLLECTION, banId)
        if ban then
            ban.relink = nil
            if account and not ban.accountId then
                ban.accountId = account.id
                if ban.name == nil or ban.name == 'unknown' then ban.name = clean(account.name, MAX_NAME) end
            end
            if Core.DB.set(COLLECTION, banId, ban) and active[banId] and ban.accountId then
                indexBan(ban)
                setAccountBanned(ban.accountId, true)
            end
            done = done + 1
        end
    end
    relinking = false
    return done
end

--- Builds the index from the stored documents (read in place, nothing copied). One loader.
local function ensureLoaded()
    if loaded then return true end
    if loadBarrier then
        pcall(Citizen.Await, loadBarrier)
        return loaded
    end
    local barrier = promise.new()
    loadBarrier = barrier
    index, active, accountActive = {}, {}, {}
    local now = os.time()
    local ok, err = pcall(Core.DB.find, COLLECTION, function(doc)
        if isActive(doc, now) then indexBan(doc) end
        if type(doc.relink) == 'string' then relinks[doc.id] = doc.relink end
        return false
    end)
    legacyAccounts = nil
    if ok and not Core.DB.isDegraded(COLLECTION) then
        loaded = true
    else
        Log.error('bans: the %s collection could not be read (%s)', COLLECTION, tostring(ok and 'degraded' or err))
    end
    loadBarrier = nil
    barrier:resolve(loaded)
    return loaded
end

-- == messages, actors, audit ================================================================================

--- The text a banned player sees (kick and connect rejection).
local function rejectMessage(ban)
    local reason = clean(ban.reason, 128) or 'No reason given'
    local expiresAt = expiryOf(ban)
    if expiresAt == 0 then
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
        if info then return { accountId = clean(info.accountId, MAX_ID), name = clean(info.name, MAX_NAME) }, src end
        return { name = clean(GetPlayerName(src), MAX_NAME) or ('player ' .. src) }, src
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

--- 'B<n>' from the persistent counter (short enough to read out in an appeal); a uuid when the
--- counter cannot be written. Never re-uses an existing document id.
local function newBanId()
    for _ = 1, 16 do
        local n = Core.DB.nextId('bans')
        local id = n and ('B%d'):format(n) or Utils.uuid()
        if not Core.DB.get(COLLECTION, id) then return id end
    end
    return Utils.uuid()
end

-- == targets and enrichment =================================================================================

--- target = src | { accountId?, identifiers?, tokens?, name? } -> { src?, accountId?, name?, ids, tokens }
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
        src = srcForAccount(accountId)
        if src then
            local liveIds, liveTokens = collectIdentity(src)
            cleanKeys(liveIds, MAX_BAN_IDENTIFIERS, ids, seenIds)
            cleanKeys(liveTokens, MAX_BAN_TOKENS, tokens, seenTokens)
            local info = infoOf(src)
            name = name or clean(info and info.name, MAX_NAME)
        else
            local account = Core.DB.get('accounts', accountId)
            if not account and #ids == 0 and #tokens == 0 then return nil, 'unknown_account' end
            if account then
                local stored = {}
                if type(account.license) == 'string' then stored[1] = account.license end
                if type(account.identifiers) == 'table' then
                    for _, value in pairs(account.identifiers) do
                        if type(value) == 'string' then stored[#stored + 1] = value end
                    end
                end
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

--- A hit on connect: new identifiers/tokens join the ban (a second account on the same PC is caught next
--- time), hits/lastHitAt move. Review M3: identifiers join only after an identifier match or >= 2 matching
--- tokens (never after one shared token), and an account-less ban learns an account only from an identifier
--- match, never from tokens alone. bans.enrichIdentifiers / bans.enrichTokens switch each part off.
local function enrich(banId, ids, tokens, byIdentifier, tokenHits)
    local ban = Core.DB.get(COLLECTION, banId)
    if not ban then return nil end
    local idList, seenIds = cleanKeys(ban.identifiers, MAX_BAN_IDENTIFIERS)
    local tokenList, seenTokens = cleanKeys(ban.tokens, MAX_BAN_TOKENS)
    local idCount, tokenCount = #idList, #tokenList
    if options.enrichIdentifiers and (byIdentifier or tokenHits >= 2) then
        cleanKeys(ids, MAX_BAN_IDENTIFIERS, idList, seenIds)
    end
    if options.enrichTokens then cleanKeys(tokens, MAX_BAN_TOKENS, tokenList, seenTokens) end
    local grew = #idList > idCount or #tokenList > tokenCount
    local patch = { hits = (math.tointeger(tonumber(ban.hits) or 0) or 0) + 1, lastHitAt = os.time() }
    if grew then patch.identifiers, patch.tokens = idList, tokenList end
    if not ban.accountId and byIdentifier then
        for i = 1, #ids do
            -- only a license the ban holds (now) names its account
            if ids[i]:sub(1, 8) == 'license:' and seenIds[ids[i]] then
                local account = Core.DB.findOne('accounts', { license = ids[i] })
                if account then
                    patch.accountId = account.id
                    if ban.name == nil or ban.name == 'unknown' then patch.name = clean(account.name, MAX_NAME) end
                end
                break
            end
        end
    end
    if not Core.DB.update(COLLECTION, banId, patch) then
        Log.warn('bans: could not record the hit on %s', banId)
    end
    for key, value in pairs(patch) do ban[key] = value end
    if grew or patch.accountId then indexBan(ban) end
    if patch.accountId then setAccountBanned(patch.accountId, true) end
    return ban
end

-- == public API =============================================================================================

--- Ban an online player (identifiers + tokens collected now, then kicked) or an offline identity.
--- opts = { target, reason, duration = seconds (0 = permanent), by = src|0, evidence?, source? }
--- @return table|nil ban, string|nil err
function Bans.add(opts)
    if type(opts) ~= 'table' then return nil, 'invalid' end
    local duration = opts.duration == nil and 0 or opts.duration
    if type(duration) ~= 'number' or duration ~= duration or duration < 0 or duration > MAX_DURATION then
        return nil, 'invalid_duration'
    end
    duration = math.floor(duration)
    if opts.evidence ~= nil and type(opts.evidence) ~= 'string' then return nil, 'invalid_evidence' end
    local target, err = resolveTarget(opts.target)
    if not target then return nil, err end
    if #target.ids == 0 and #target.tokens == 0 then return nil, 'no_identifiers' end
    if not ensureLoaded() then return nil, 'db' end
    local by, actor = actorOf(opts.by)
    -- a player actor never bans an identity that reaches its own rank or above (review H2)
    if math.type(actor) == 'integer' and actor > 0 then
        if target.accountsUnreadable then return nil, 'db' end   -- R2-11: never pass the check blind
        if not Identity.outranksAll(actor, target.accounts, target.holders) then return nil, 'rank' end
    end
    local now = os.time()
    local ban = {
        id = newBanId(), _v = VERSION, accountId = target.accountId, accountIds = target.accountIds,
        name = target.name or 'unknown',
        identifiers = target.ids, tokens = target.tokens, reason = clean(opts.reason, MAX_REASON) or 'No reason given',
        evidence = clean(opts.evidence, MAX_EVIDENCE), by = by, createdAt = now,
        expiresAt = duration > 0 and now + duration or 0, hits = 0,
    }
    if not Core.DB.create(COLLECTION, ban) then return nil, 'db' end
    indexBan(ban)
    if ban.accountId then setAccountBanned(ban.accountId, true, target.src) end
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
    return Core.DB.get(COLLECTION, ban.id) or ban
end

--- Revoke a ban (kept for history). Clears account.banned when it was the account's last active ban.
--- @return boolean ok, string|nil err
function Bans.remove(banId, by, reason)
    if not isBanId(banId) then return false, 'invalid' end
    if not ensureLoaded() then return false, 'db' end
    local ban = Core.DB.get(COLLECTION, banId)
    if not ban then return false, 'not_found' end
    if type(ban.revoked) == 'table' then return false, 'already_revoked' end
    local revokedBy, actor = actorOf(by)
    local text = clean(reason, MAX_REASON)
    if not Core.DB.update(COLLECTION, banId, { revoked = { by = revokedBy, at = os.time(), reason = text } }) then
        return false, 'db'
    end
    local wasActive = retire(banId)
    audit('ban.remove', actor, ban, text, ('ban %s on %s revoked'):format(banId, ban.name or 'unknown'), nil, nil,
        { wasActive = wasActive })
    return true
end

function Bans.get(banId)
    if not isBanId(banId) then return nil end
    return Core.DB.get(COLLECTION, banId)
end

--- The best active ban for these identifiers/tokens (a copy), or nil. Expired bans met are retired.
function Bans.check(identifiers, tokens)
    if not ensureLoaded() then return nil, 'unavailable' end
    local banId = findActive((cleanKeys(identifiers, MAX_IDENTIFIERS)), (cleanKeys(tokens, MAX_TOKENS)))
    return banId and Core.DB.get(COLLECTION, banId) or nil
end

--- The connect path (playerConnecting deferral in server/player.lua): collect identifiers (no ip:)
--- and tokens, check, enrich the ban on a hit. Returns the ban and the finished rejection text; or
--- `nil, 'unavailable'` when the bans collection cannot be read (the caller decides: legacy lookup, then
--- bans.failClosed). A plain `nil` = not banned.
--- @return table|nil ban, string|nil messageOrUnavailable
function Bans.checkConnecting(src)
    src = toSrc(src)
    if not src then return nil end
    local ids, tokens = collectIdentity(src)
    if not ensureLoaded() then return nil, 'unavailable' end
    local banId, byIdentifier, tokenHits = findActive(ids, tokens)
    if not banId then return nil end
    local ban = enrich(banId, ids, tokens, byIdentifier, tokenHits)
    if not ban then return nil end
    Log.info('ban %s refused a connection from %s', banId, clean(GetPlayerName(src), MAX_NAME) or '?')
    return ban, rejectMessage(ban)
end

--- { createdAt, id } newest first; within one second the longer counter id is the newer ('B10' > 'B9').
--- Does this ban concern the account (its own, or one of the accounts matched at add time)?
local function concerns(doc, accountId)
    if doc.accountId == accountId then return true end
    for _, id in ipairs(type(doc.accountIds) == 'table' and doc.accountIds or {}) do
        if id == accountId then return true end
    end
    return false
end

local function newestFirst(a, b)
    local ca, cb = tonumber(a[1]) or 0, tonumber(b[1]) or 0
    if ca ~= cb then return ca > cb end
    local ia, ib = a[2], b[2]
    if #ia ~= #ib then return #ia > #ib end
    return ia > ib
end

--- opts = { active? = true (false = every ban, history included), text?, accountId?, limit? = 50 (<= 200),
--- before? = cursor } -> { rows, next }, newest first. The cursor is '<createdAt>/<id>'.
function Bans.list(opts)
    if type(opts) ~= 'table' then opts = {} end
    if not ensureLoaded() then return { rows = {} } end
    local onlyActive = opts.active ~= false
    local accountId = isBanId(opts.accountId) and opts.accountId or nil
    if opts.accountId ~= nil and not accountId then return { rows = {} } end   -- never widen the result
    local text = type(opts.text) == 'string' and opts.text ~= '' and opts.text:sub(1, 128):lower() or nil
    local limit = (type(opts.limit) == 'number' and opts.limit == opts.limit)
        and math.max(1, math.min(MAX_LIMIT, math.floor(opts.limit))) or DEFAULT_LIMIT
    local now, refs = os.time(), {}
    Core.DB.find(COLLECTION, function(doc)   -- a throwing predicate (odd legacy data) is a miss
        if accountId and not concerns(doc, accountId) then return false end
        if onlyActive and not isActive(doc, now) then return false end
        if text and not ('%s %s %s %s %s'):format(doc.id, doc.name or '', doc.reason or '', doc.accountId or '',
            table.concat(type(doc.identifiers) == 'table' and doc.identifiers or {}, ' ')):lower():find(text, 1, true) then
            return false
        end
        refs[#refs + 1] = { tonumber(doc.createdAt) or 0, tostring(doc.id) }
        return false
    end)
    table.sort(refs, newestFirst)
    local first = 1
    if opts.before ~= nil then
        local at, id = tostring(opts.before):match('^(%d+)/(.+)$')
        if not at then return { rows = {} } end
        local key = { tonumber(at), id }
        first = #refs + 1
        for i = 1, #refs do
            if newestFirst(key, refs[i]) then first = i break end
        end
    end
    local rows = {}
    local last = math.min(#refs, first + limit - 1)
    for i = first, last do
        local doc = Core.DB.get(COLLECTION, refs[i][2])
        if doc then rows[#rows + 1] = doc end
    end
    local more = last < #refs and last >= first
    return { rows = rows, next = more and ('%d/%s'):format(refs[last][1], refs[last][2]) or nil }
end

--- Every ban of one account (history included; its `accountId` or listed in `accountIds`), newest first.
function Bans.forAccount(accountId)
    if not isBanId(accountId) then return {} end
    local list = Core.DB.find(COLLECTION, function(doc) return concerns(doc, accountId) end)
    table.sort(list, function(a, b)
        return newestFirst({ a.createdAt, tostring(a.id) }, { b.createdAt, tostring(b.id) })
    end)
    return list
end

--- Drops expired bans from the index (and clears account.banned with an account's last one).
--- @return integer expired
function Bans.sweep()
    if not loaded then return 0 end
    local now, expired = os.time(), {}
    for banId, meta in pairs(active) do
        if meta.expiresAt ~= 0 and meta.expiresAt <= now then expired[#expired + 1] = banId end
    end
    for i = 1, #expired do retire(expired[i]) end
    if #expired > 0 then Log.info('bans: %d ban(s) expired', #expired) end
    relinkPending()
    return #expired
end

-- == start ==================================================================================================

local running = true

CreateThread(function()
    Wait(0)   -- every server file has loaded: the DB adapter is chosen, the v2 migration is registered
    defineSettings()
    while running and not ensureLoaded() do Wait(LOAD_RETRY_MS) end
    if not running then return end
    Bans.sweep()
    local cron = rawget(Core, 'Cron')
    if type(cron) == 'table' and type(cron.at) == 'function' then cron.at(4, 40, function() Bans.sweep() end) end
    while running and next(relinks) do   -- R2-12: bans migrated while accounts was unreadable
        relinkPending()
        if next(relinks) then Wait(60000) end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == Core.name then running = false end
end)
