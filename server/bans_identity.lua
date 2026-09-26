--[[
    core/server/bans_identity.lua — Core.BanIdentity (DESIGN §47, internal: listed in INTERNAL_NAMESPACES).

    The identity half of server/bans.lua (split off to keep bans.lua < 900 lines; loads right before it):
      BanIdentity.isKey(v)                          a storable identifier/token ('type:value', never 'ip:')
      BanIdentity.collect(src) -> ids, tokens       every identifier (no ip:, <= 32) and token (<= 64) of a player
      BanIdentity.holders(ids, tokens, targetSrc?, tokenMatches) -> accounts, srcs, unreadable
      BanIdentity.outranksAll(actorSrc, accounts, srcs) -> bool
      BanIdentity.playerApi() / BanIdentity.info(src)  Core.Player / Player.getInfo without ever throwing

    Online index: the identity of every connected player is read ONCE at playerJoining (~15 natives) into
    `online[src]` / `onlineByKey[key]` and dropped at playerDropped; a core restart seeds it from GetPlayers().
    So "who online holds this identifier/token" is a lookup, never a walk over the players.

    Accounts: Player.findAccountsByIdentifier (server/getters.lua, an in-memory index) when present, else a
    one-off non-copying scan of `accounts` (offline bans are rare admin actions). `unreadable` is true when
    that lookup failed or `accounts` is degraded: bans.lua then refuses a player actor (review R2-11).

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
        local value = GetPlayerIdentifier(src, i)
        if isKey(value) then ids[#ids + 1] = value end
    end
    count = math.tointeger(tonumber(GetNumPlayerTokens(src)) or 0) or 0
    for i = 0, math.min(count, MAX_TOKENS) - 1 do
        local value = GetPlayerToken(src, i)
        if isKey(value) then tokens[#tokens + 1] = value end
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

--- Every account holding one of `ids` — Player.findAccountsByIdentifier (player.lua's in-memory index), else a
--- one-off scan of `accounts` read in place (offline bans are rare admin actions) — and every connected src
--- the ban would refuse: one identifier, or at least bans.tokenMatches distinct tokens.
function Identity.holders(ids, tokens, targetSrc, tokenMatches)
    local accounts, seen = {}, {}
    local function add(doc)
        if type(doc) == 'table' and type(doc.id) == 'string' and not seen[doc.id] then
            seen[doc.id] = true
            accounts[#accounts + 1] = { id = doc.id, group = doc.group, name = doc.name }
        end
    end
    local player, unreadable = playerApi(), false
    local lookup = player and rawget(player, 'findAccountsByIdentifier')
    if #ids > 0 and type(lookup) == 'function' then
        for i = 1, #ids do
            local ok, list = pcall(lookup, ids[i])
            unreadable = unreadable or not ok or type(list) ~= 'table'
            for j = 1, (ok and type(list) == 'table') and #list or 0 do
                if not seen[list[j]] then add(Core.DB.get('accounts', list[j])) end
            end
        end
    elseif #ids > 0 then
        local want = {}
        for i = 1, #ids do want[ids[i]] = true end
        Core.DB.find('accounts', function(doc)
            local hit = type(doc.license) == 'string' and want[doc.license] == true
            for _, value in pairs(type(doc.identifiers) == 'table' and doc.identifiers or {}) do
                if hit then break end
                hit = want[value] == true
            end
            if hit then add(doc) end
            return false
        end)
    end
    unreadable = unreadable or (#ids > 0 and Core.DB.isDegraded('accounts'))
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
