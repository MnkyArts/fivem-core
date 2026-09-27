--[[
    core/server/bans_identity.lua — Core.BanIdentity (DESIGN §47, internal: listed in INTERNAL_NAMESPACES).

    The identity half of server/bans.lua (split off to keep bans.lua < 900 lines; loads right before it):
      BanIdentity.isKey(v)                          a storable identifier/token ('type:value', never 'ip:')
      BanIdentity.key(v) -> key | nil               the same in canonical form: LOWER-CASED (the engine's
                                                    identifiers and tokens are lower-case hex; an admin may type
                                                    'DISCORD:…' or paste upper-case hex) — every stored/matched key
      BanIdentity.collect(src) -> ids, tokens       every identifier (no ip:, <= 32) and token (<= 64) of a player
      BanIdentity.account(accountId) -> { id, name, identifiers } | false | nil, err   the stored account (yields)
      BanIdentity.holders(ids, tokens, targetSrc?, tokenMatches) -> accounts, srcs, unreadable   (yields)
      BanIdentity.outranksAll(actorSrc, accounts, srcs) -> bool
      BanIdentity.playerApi() / BanIdentity.info(src)  Core.Player / Player.getInfo without ever throwing

    Online index: the identity of every connected player is read ONCE at playerJoining (~15 natives) into
    `online[src]` / `onlineByKey[key]` and dropped at playerDropped; a core restart seeds it from GetPlayers().
    So "who online holds this identifier/token" is a lookup, never a walk over the players.

    Accounts (DESIGN §56.8): the holders of an identifier come from Player.findAccountsByIdentifier
    (server/getters.lua: one indexed query per identifier), their `id, perm_group, name` from ONE query by id
    list; the offline account of a ban target (license + account_identifiers) from one query by id. These reads
    are awaited — offline bans are rare admin actions and their callers (commands, callbacks, threads) can yield.
    `unreadable` is true when a lookup failed or Player.findAccountsByIdentifier is missing: bans.lua then refuses
    a player actor (review R2-11). Nothing is ever scanned.

    Natives: GetNumPlayerIdentifiers, GetPlayerIdentifier, GetNumPlayerTokens, GetPlayerToken (server).
]]

local Identity = {}
Core.BanIdentity = Identity

local MAX_IDENTIFIERS <const> = 32      -- collected per player
local MAX_TOKENS <const> = 64
local MAX_KEY <const> = 128
local KEY_PATTERN <const> = '^[%w_]+:[%w_%-%.]+$'

local online = {}           -- [src] = { identifiers and tokens } of every connected player
local onlineByKey = {}      -- [identifier|token] = { [src] = true }

function Identity.isKey(value)
    return type(value) == 'string' and #value <= MAX_KEY and value:match(KEY_PATTERN) ~= nil
        and value:sub(1, 3) ~= 'ip:'
end
local isKey = Identity.isKey

function Identity.key(value)
    if type(value) ~= 'string' then return nil end
    value = value:lower()
    return isKey(value) and value or nil
end
local keyOf = Identity.key

function Identity.playerApi()
    local player = rawget(Core, 'Player')
    return type(player) == 'table' and player or nil
end
local playerApi = Identity.playerApi

function Identity.info(src)
    local player = playerApi()
    local getInfo = player and rawget(player, 'getInfo')
    if type(getInfo) ~= 'function' then return nil end
    local ok, info = pcall(getInfo, src)
    return ok and type(info) == 'table' and info or nil
end
local infoOf = Identity.info

--- Every identifier and token of a connected (or connecting) player; `ip:` is skipped.
function Identity.collect(src)
    local ids, tokens = {}, {}
    local count = math.tointeger(tonumber(GetNumPlayerIdentifiers(src)) or 0) or 0
    for i = 0, math.min(count, MAX_IDENTIFIERS) - 1 do
        local value = keyOf(GetPlayerIdentifier(src, i))
        if value then ids[#ids + 1] = value end
    end
    count = math.tointeger(tonumber(GetNumPlayerTokens(src)) or 0) or 0
    for i = 0, math.min(count, MAX_TOKENS) - 1 do
        local value = keyOf(GetPlayerToken(src, i))
        if value then tokens[#tokens + 1] = value end
    end
    return ids, tokens
end
local collectIdentity = Identity.collect

-- == the online index and the holders of an identity =========================================================

local function untrackOnline(src)
    local keys = online[src]
    if not keys then return end
    for i = 1, #keys do
        local set = onlineByKey[keys[i]]
        if set then
            set[src] = nil
            if next(set) == nil then onlineByKey[keys[i]] = nil end
        end
    end
    online[src] = nil
end

--- One identity read per join (~15 natives), so "who online holds this identifier/token" is a lookup.
local function trackOnline(src)
    untrackOnline(src)
    local ids, tokens = collectIdentity(src)
    local keys = ids
    for i = 1, #tokens do keys[#keys + 1] = tokens[i] end
    for i = 1, #keys do
        local set = onlineByKey[keys[i]]
        if not set then
            set = {}
            onlineByKey[keys[i]] = set
        end
        set[src] = true
    end
    online[src] = keys
end

local HOLDERS_SQL <const> = 'SELECT id, perm_group, name FROM accounts WHERE id = ANY($1::text[])'
local ACCOUNT_SQL <const> = [[
SELECT a.id, a.name, a.license,
       ARRAY(SELECT i.identifier FROM account_identifiers i WHERE i.account_id = a.id ORDER BY i.kind) AS identifiers
FROM accounts a
WHERE a.id = $1]]

--- The stored account behind an offline ban target: its license first, then every account_identifiers entry
--- (read with { sync = true }: identifiers a join queued a moment ago count). false = no such account;
--- nil, err = the read failed. Yields.
function Identity.account(accountId)
    local rows, err = Core.DB.query(ACCOUNT_SQL, { accountId }, { sync = true })
    if not rows then return nil, err end
    local row = rows[1]
    if not row then return false end
    local stored = {}
    local license = keyOf(row.license)
    stored[1] = license
    for _, value in ipairs(type(row.identifiers) == 'table' and row.identifiers or {}) do
        local key = keyOf(value)
        if key and key ~= license then stored[#stored + 1] = key end
    end
    return { id = row.id, name = row.name, identifiers = stored }
end

--- Account ids holding one of `ids` (Player.findAccountsByIdentifier, in discovery order) → ids, unreadable.
local function holderIds(ids)
    local out, seen = {}, {}
    local player = playerApi()
    local lookup = player and rawget(player, 'findAccountsByIdentifier')
    if type(lookup) ~= 'function' then return out, true end   -- nobody can answer: never assume "nobody"
    local unreadable = false
    for i = 1, #ids do
        local ok, list = pcall(lookup, ids[i])
        if not ok or type(list) ~= 'table' then
            unreadable = true
        else
            for j = 1, #list do
                local id = list[j]
                if type(id) == 'string' and not seen[id] then
                    seen[id] = true
                    out[#out + 1] = id
                end
            end
        end
    end
    return out, unreadable
end

--- Every account holding one of `ids` ({ id, group, name }, discovery order: the holder ids, then ONE query for
--- their rows) and every connected src the ban would refuse: one identifier, or at least bans.tokenMatches
--- distinct tokens. Yields when `ids` is not empty.
function Identity.holders(ids, tokens, targetSrc, tokenMatches)
    local accounts, unreadable = {}, false
    if #ids > 0 then
        local found
        found, unreadable = holderIds(ids)
        if found[1] then
            local rows, err = Core.DB.query(HOLDERS_SQL, { found })
            local byId = {}
            if rows then
                for i = 1, #rows do byId[rows[i].id] = rows[i] end
            else
                unreadable = true   -- the ids stay listed (the ban still names them); their rank is unknown
                Core.Log.error('bans: the accounts holding a banned identifier cannot be read (%s)', tostring(err))
            end
            for i = 1, #found do
                local row = byId[found[i]]
                if row or not rows then
                    accounts[#accounts + 1] = { id = found[i], group = row and row.perm_group, name = row and row.name }
                end
            end
        end
    end
    local srcs, hitBy, tokenCount = {}, {}, {}
    if targetSrc then hitBy[targetSrc] = true end
    for i = 1, #ids do
        for src in pairs(onlineByKey[ids[i]] or {}) do hitBy[src] = true end
    end
    local need = math.tointeger(tokenMatches) or 2
    if need > 0 then
        for i = 1, #tokens do
            for src in pairs(onlineByKey[tokens[i]] or {}) do
                tokenCount[src] = (tokenCount[src] or 0) + 1
                if tokenCount[src] >= need then hitBy[src] = true end
            end
        end
    end
    for src in pairs(hitBy) do srcs[#srcs + 1] = src end
    table.sort(srcs)
    return accounts, srcs, unreadable
end

--- A player actor may ban only identities that do not reach anyone of its own weight or above: every
--- matched account's group weight must be < the actor's, every affected online player must be targetable.
--- Fails closed when Core.Perms cannot answer.
function Identity.outranksAll(actorSrc, accounts, srcs)
    local perms = rawget(Core, 'Perms')
    if type(perms) ~= 'table' or type(rawget(perms, 'getWeight')) ~= 'function'
        or type(rawget(perms, 'canTarget')) ~= 'function' or type(rawget(perms, 'groups')) ~= 'function' then
        return false
    end
    local ok, answer = pcall(function()
        local actorWeight = perms.getWeight(actorSrc)
        for i = 1, #srcs do
            if srcs[i] ~= actorSrc and not perms.canTarget(actorSrc, srcs[i]) then return false end
        end
        if #accounts == 0 then return true end
        local weights = {}
        for _, group in ipairs(perms.groups()) do weights[group.name] = group.weight end
        local info = infoOf(actorSrc)
        local own = info and info.accountId
        for i = 1, #accounts do
            local account = accounts[i]
            local weight = weights[account.group or 'user'] or weights.user or 0
            if account.id ~= own and weight >= actorWeight then return false end
        end
        return true
    end)
    return ok and answer == true
end

-- == lifecycle ==============================================================================================

AddEventHandler('playerJoining', function()
    local src = tonumber(source)
    if src then trackOnline(src) end
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then untrackOnline(src) end
end)

-- A core restart: the players already connected are read like new joins (one thread, ends at once).
CreateThread(function()
    Wait(0)
    local players = GetPlayers()
    for i = 1, #players do
        local src = tonumber(players[i])
        if src and not online[src] then trackOnline(src) end
    end
end)
