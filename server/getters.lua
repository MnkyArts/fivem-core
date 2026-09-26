--[[
    core/server/getters.lua — proximity and lookup getters (DESIGN §22).

    Extends the existing `Core.Player` (server/player.lua) and `Core.Vehicles` (server/vehicles.lua)
    tables; both files load before this one (fxmanifest order), so the tables are the module tables,
    not import.lua's lazy proxies.

    The proximity getters (`getClosest`, `getInRange`) ask `Core.PlayerGrid` (§22.1) for the
    candidates of the queried circle and test the EXACT distance with live coordinates on those
    only — identical results, without the full loop over every loaded player (§9). Everything else
    here is O(players) or O(core vehicles) per call and meant for event handlers and commands —
    never for a per-tick loop. `Player.getStreet` asks the player's own client
    (Core.Callback.awaitClient) and therefore yields: call it from a thread/handler coroutine.

    Server side only: every native below is apiset server (or client+server) — note that
    GetVehicleMaxNumberOfPassengers is client-only, so seat scans use a fixed seat-index range.

    Also here: `Player.resolveTargets` (§49, the target selector grammar behind the `target` /
    `targets` command params), `Player.getHealth/getArmour` (§17) and the §5.2 callback
    'core:player:getInfo' (moved out of server/player.lua, which only keeps the session state).
    Natives: GetPlayerPed, GetEntityCoords, GetEntityHealth, GetPedArmour, GetPlayerName (server).
]]

local Player = Core.Player
local Vehicles = Core.Vehicles
local Validate = Core.Validate
local Utils = Core.Utils
local PlayerGrid = Core.PlayerGrid   -- server/playergrid.lua loads before this file (manifest order)

-- Reusable candidate buffers (§22.1): neither getter yields, and each one has its own array, so a
-- nested call can never clobber the other's. Only the returned count is meaningful — the tail is stale.
local closestBuffer = {}
local inRangeBuffer = {}

local DEFAULT_PLAYER_RANGE <const> = 50.0
local DEFAULT_VEHICLE_RANGE <const> = 20.0
local MAX_RANGE <const> = 2000.0
local DRIVER_SEAT <const> = -1
-- GTA's highest passenger seat index; GetVehicleMaxNumberOfPassengers is apiset client, so the
-- server scans the whole range and skips empty seats (GetPedInVehicleSeat returns 0 for those).
local MAX_SEAT_INDEX <const> = 15
local VEHICLE_COLLECTION <const> = 'vehicles'   -- mirrors COLLECTION in server/vehicles.lua
local MAX_META_KEY <const> = 64

--- vector3 from a vector3 or a { x, y, z } / { [1], [2], [3] } table; nil when unusable.
local function toVector3(value)
    if type(value) == 'vector3' then return value end
    if type(value) ~= 'table' then return nil end
    local x, y, z = value.x or value[1], value.y or value[2], value.z or value[3]
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    local coords = vector3(x + 0.0, y + 0.0, z + 0.0)
    return Validate.value('vector3', coords) and coords or nil
end

--- A positive, sane range; falls back to `default` for anything else.
local function rangeOf(value, default)
    if type(value) ~= 'number' or value ~= value or value <= 0.0 then return default end
    return math.min(value, MAX_RANGE)
end

--- Live world coordinates of a connected player, or nil when the ped is not (yet) there.
local function coordsOf(src)
    if not Validate.value('src', src) then return nil end
    local ped = GetPlayerPed(src)
    if ped == 0 then return nil end
    return GetEntityCoords(ped)
end

--- Every connected server id (GetPlayers is a runtime helper, not a native).
local function connectedSrcs()
    local players = GetPlayers()
    local out = {}
    for i = 1, #players do
        local src = tonumber(players[i])
        if src then out[#out + 1] = math.tointeger(src) or nil end
    end
    return out
end

--- { [ped] = src } for every connected player; built once per call instead of per seat.
local function pedOwners()
    local map = {}
    local srcs = connectedSrcs()
    for i = 1, #srcs do
        local ped = GetPlayerPed(srcs[i])
        if ped ~= 0 then map[ped] = srcs[i] end
    end
    return map
end

--- Entity handle for a netId: core vehicles through the registry, anything else through the
--- network id. Returns 0 when the vehicle does not exist on this server.
local function vehicleEntity(netId)
    if not Validate.value('netId', netId) then return 0 end
    local entity = Vehicles.getEntity(netId)
    if entity ~= 0 then return entity end
    entity = NetworkGetEntityFromNetworkId(netId)
    if entity ~= 0 and DoesEntityExist(entity) then return entity end
    return 0
end

-- ---------------------------------------------------------------------------
-- Core.Player getters (DESIGN §22)
-- ---------------------------------------------------------------------------

--- Nearest other loaded player to `src`. Returns src, distance — or nil when nobody is in range.
function Player.getClosest(src, maxDist)
    local origin = coordsOf(src)
    if not origin then return nil end
    local range = rangeOf(maxDist, DEFAULT_PLAYER_RANGE)
    local bestSrc, bestDist
    local count = PlayerGrid.candidates(origin, range, closestBuffer)
    for i = 1, count do
        local other = closestBuffer[i]
        if other ~= src then
            local coords = coordsOf(other)
            if coords then
                local dist = #(coords - origin)
                if dist <= range and (not bestDist or dist < bestDist) then
                    bestSrc, bestDist = other, dist
                end
            end
        end
    end
    if not bestSrc then return nil end
    return bestSrc, bestDist
end

--- Every loaded player within `range` of `coords`, nearest first: { { src = src, dist = n }, ... }.
function Player.getInRange(coords, range)
    local origin = toVector3(coords)
    local out = {}
    if not origin then return out end
    local max = rangeOf(range, DEFAULT_PLAYER_RANGE)
    local count = PlayerGrid.candidates(origin, max, inRangeBuffer)
    for i = 1, count do
        local src = inRangeBuffer[i]
        local at = coordsOf(src)
        if at then
            local dist = #(at - origin)
            if dist <= max then out[#out + 1] = { src = src, dist = dist } end
        end
    end
    table.sort(out, function(a, b) return a.dist < b.dist end)
    return out
end

--- Character name first, connection name second; both compared case-insensitively.
local function namesOf(src)
    return Player.getName(src), GetPlayerName(src)
end

--- Exact, case-insensitive name match over loaded players. Returns src | nil.
function Player.findByName(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local wanted = name:lower()
    local players = Player.getPlayers()
    for i = 1, #players do
        local src = players[i]
        local charName, connName = namesOf(src)
        if (type(charName) == 'string' and charName:lower() == wanted)
            or (type(connName) == 'string' and connName:lower() == wanted) then
            return src
        end
    end
    return nil
end

--- Case-insensitive substring match (plain, no patterns) over loaded players. Returns an array of src.
function Player.findByPartialName(part)
    local out = {}
    if type(part) ~= 'string' or part == '' then return out end
    local wanted = part:lower()
    local players = Player.getPlayers()
    for i = 1, #players do
        local src = players[i]
        local charName, connName = namesOf(src)
        if (type(charName) == 'string' and charName:lower():find(wanted, 1, true))
            or (type(connName) == 'string' and connName:lower():find(wanted, 1, true)) then
            out[#out + 1] = src
        end
    end
    return out
end

--- Every connected player sitting in the vehicle with this netId. Returns an array of src.
function Player.getInVehicle(netId)
    local out = {}
    if not Validate.value('netId', netId) then return out end
    local srcs = connectedSrcs()
    for i = 1, #srcs do
        local src = srcs[i]
        local ped = GetPlayerPed(src)
        if ped ~= 0 then
            local vehicle = GetVehiclePedIsIn(ped, false)
            if vehicle ~= 0 and NetworkGetNetworkIdFromEntity(vehicle) == netId then
                out[#out + 1] = src
            end
        end
    end
    return out
end

--- True when the player's ped is within `range` of `coords`.
function Player.isNear(src, coords, range)
    local origin = toVector3(coords)
    local at = coordsOf(src)
    if not origin or not at then return false end
    return #(at - origin) <= rangeOf(range, DEFAULT_PLAYER_RANGE)
end

--- Street and zone name, read on the player's own client (§21 callback in client/hudfeed.lua).
--- Yields: call it from a thread, event handler or command. nil on timeout or without a session.
function Player.getStreet(src)
    if not Validate.value('src', src) or not Player.isLoaded(src) then return nil end
    local street, zone = Core.Callback.awaitClient(src, 'core:player:street')
    if type(street) ~= 'string' then return nil end
    return street, type(zone) == 'string' and zone or nil
end

function Player.getHealth(src)
    local ped = Player.getPed(src)
    if ped == 0 then return 0 end
    return GetEntityHealth(ped) or 0
end

function Player.getArmour(src)
    local ped = Player.getPed(src)
    if ped == 0 then return 0 end
    return GetPedArmour(ped) or 0
end

-- DESIGN §5.2: the player's own info + money. The license stays server-side on purpose, so this
-- projects getInfo() instead of forwarding it.
Core.Callback.register('core:player:getInfo', function(src)
    local info = Player.getInfo(src)
    if not info then return nil end
    local money = Player.getData(src, 'money')
    if type(money) ~= 'table' then money = {} end
    return {
        src = info.src, charId = info.charId, accountId = info.accountId, name = info.name,
        group = info.group, money = { cash = money.cash or 0, bank = money.bank or 0 },
    }
end)

-- ---------------------------------------------------------------------------
-- Identifier → account index (§47: offline bans, Bans.resolveTarget)
-- ---------------------------------------------------------------------------
-- idIndex[identifier] = accountId, or { [accountId] = true } when several accounts share it. Built once, on
-- the first query, by a predicate walk over `accounts` that copies nothing (DB.find hands the predicate the
-- stored document); every join / session load adds the account's current identifiers afterwards. Entries go
-- stale only when an identifier is replaced, so a query re-checks each candidate against the account itself.
-- The identifiers are engine-sourced: Player.setAccountData refuses to write them. Accounts written without a
-- join (/dbimport, a migration, a direct DB write) are caught on a MISS: when the collection's document count
-- differs from the build's, or the build is older than INDEX_STALE_MS, the index is rebuilt once and re-asked.

local IDENTIFIER_MAX <const> = 128
local INDEX_WAIT_MS <const> = 10000
local INDEX_STALE_MS <const> = 300000
local idIndex = nil
local idIndexBuilding = false
local idIndexCount, idIndexAt = 0, 0   -- documents walked by the last build, and when it finished

local function indexOne(index, identifier, accountId)
    if type(identifier) ~= 'string' or identifier == '' or identifier:sub(1, 3) == 'ip:' then return end
    local entry = index[identifier]
    if entry == nil then
        index[identifier] = accountId
    elseif type(entry) == 'table' then
        entry[accountId] = true
    elseif entry ~= accountId then
        index[identifier] = { [entry] = true, [accountId] = true }
    end
end

local function indexAccount(index, accountId, license, identifiers)
    if accountId == nil then return end
    indexOne(index, license, accountId)
    if type(identifiers) == 'table' then
        for _, identifier in pairs(identifiers) do indexOne(index, identifier, accountId) end
    end
end

--- The index, built on first use. A second caller during the build (the first read of `accounts` may yield
--- on an asynchronous backend) waits for it, bounded.
local function ensureIdIndex()
    if idIndex then return idIndex end
    if idIndexBuilding then
        local deadline = GetGameTimer() + INDEX_WAIT_MS
        while not idIndex and GetGameTimer() < deadline do Wait(50) end
        return idIndex
    end
    local isDegraded = Core.DB.isDegraded
    local function degraded() return Utils.isCallable(isDegraded) and isDegraded('accounts') == true end
    if degraded() then return nil end   -- R2-11: a degraded collection reads EMPTY; never index that
    idIndexBuilding = true
    local built, walked = {}, 0
    local ok, err = pcall(Core.DB.find, 'accounts', function(doc)
        walked = walked + 1
        indexAccount(built, doc.id, doc.license, doc.identifiers)
        return false
    end)
    idIndexBuilding = false
    if not ok or degraded() then
        Core.Log.error('account identifier index not cached: accounts unreadable (%s)',
            ok and 'degraded' or tostring(err))
        return nil
    end
    local players = Player.getPlayers()   -- sessions stamped while the read yielded
    for i = 1, #players do
        local account = Player.getAccount(players[i])
        if account then indexAccount(built, account.id, nil, account.identifiers) end
    end
    idIndex, idIndexCount, idIndexAt = built, walked, GetGameTimer()
    return idIndex
end

--- A join or a session load (core restart) adds the account's current identifiers.
local function indexSession(src)
    if not idIndex then return end   -- not built yet: the build reads the documents anyway
    local account = Player.getAccount(src)
    if account then indexAccount(idIndex, account.id, nil, account.identifiers) end
end
AddEventHandler('playerJoining', function()
    local src = source
    indexSession(src)
end)
Core.on('playerLoaded', indexSession)

--- True while the account (live or stored) still carries the identifier.
local function accountHolds(accountId, identifier)
    local account = Player.getAccountById(accountId)
    if not account then return false end
    for _, value in pairs(type(account.identifiers) == 'table' and account.identifiers or {}) do
        if value == identifier then return true end
    end
    local doc = identifier:sub(1, 8) == 'license:' and Core.DB.get('accounts', accountId) or nil
    return doc ~= nil and doc.license == identifier   -- an old document may carry the license alone
end

--- Player.findAccountsByIdentifier(identifier) -> array of accountIds (sorted; empty when none). Any
--- `type:value` identifier ('license:…', 'discord:…', …); 'ip:' is never indexed. May yield on the first call.
--- nil, 'unavailable' while `accounts` cannot be read (degraded, or a concurrent build timed out) — a caller
--- that decides on rank (Bans, offline bans) must then refuse rather than assume nobody holds it (R2-11).
function Player.findAccountsByIdentifier(identifier)
    local out = {}
    if type(identifier) ~= 'string' or #identifier < 3 or #identifier > IDENTIFIER_MAX
        or not identifier:find(':', 1, true) then
        return out
    end
    for attempt = 1, 2 do
        local index = ensureIdIndex()
        if not index then return nil, 'unavailable' end
        local entry = index[identifier]
        if type(entry) == 'table' then
            for accountId in pairs(entry) do
                if accountHolds(accountId, identifier) then out[#out + 1] = accountId end
            end
        elseif entry ~= nil and accountHolds(entry, identifier) then
            out[1] = entry
        end
        -- a miss on an index that may have missed out-of-join writes: rebuild once and ask again
        if #out > 0 or attempt == 2 or idIndexBuilding
            or (Core.DB.count('accounts') == idIndexCount and GetGameTimer() - idIndexAt < INDEX_STALE_MS) then
            break
        end
        idIndex = nil
    end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

-- ---------------------------------------------------------------------------
-- Core.Vehicles getters (DESIGN §22)
-- ---------------------------------------------------------------------------

--- Core-spawned vehicles within `range` of `coords`, nearest first. Returns an array of netId.
function Vehicles.getInRange(coords, range)
    local origin = toVector3(coords)
    local out = {}
    if not origin then return out end
    local max = rangeOf(range, DEFAULT_VEHICLE_RANGE)
    local found = {}
    local netIds = Vehicles.list()
    for i = 1, #netIds do
        local netId = netIds[i]
        local entity = Vehicles.getEntity(netId)
        if entity ~= 0 then
            local dist = #(GetEntityCoords(entity) - origin)
            if dist <= max then found[#found + 1] = { netId = netId, dist = dist } end
        end
    end
    table.sort(found, function(a, b) return a.dist < b.dist end)
    for i = 1, #found do out[i] = found[i].netId end
    return out
end

--- Server id of the driver, or nil when the seat is empty or held by an NPC.
function Vehicles.getDriver(netId)
    local entity = vehicleEntity(netId)
    if entity == 0 then return nil end
    local ped = GetPedInVehicleSeat(entity, DRIVER_SEAT)
    if ped == 0 then return nil end
    return pedOwners()[ped]
end

--- Server ids of the players in the passenger seats (driver excluded), seat order.
function Vehicles.getPassengers(netId)
    local out = {}
    local entity = vehicleEntity(netId)
    if entity == 0 then return out end
    local owners = pedOwners()
    for seat = 0, MAX_SEAT_INDEX do
        local ped = GetPedInVehicleSeat(entity, seat)
        if ped ~= 0 then
            local src = owners[ped]
            if src then out[#out + 1] = src end
        end
    end
    return out
end

--- Nearest core-spawned vehicle to the player's ped. Returns netId | nil.
function Vehicles.getClosestToPlayer(src, maxDist)
    local origin = coordsOf(src)
    if not origin then return nil end
    local list = Vehicles.getInRange(origin, rangeOf(maxDist, DEFAULT_VEHICLE_RANGE))
    return list[1]
end

--- setData/getData address the persisted record: an integer is a netId (the spawned vehicle must
--- have been persisted, Vehicles.persist), a string is a vehId. Returns the vehId | nil.
local function recordIdOf(target)
    if math.type(target) == 'integer' then
        local info = Vehicles.getInfo(target)
        local vehId = info and info.vehId
        return (type(vehId) == 'string' and vehId ~= '') and vehId or nil
    end
    return Validate.value('id', target) and target or nil
end

--- Write one key of the record's `meta` table (nil removes it). Persisted through Core.DB,
--- so it survives restarts — for live, replicated flags use the vehicle's state bag instead.
function Vehicles.setData(target, key, value)
    local vehId = recordIdOf(target)
    if not vehId then return false end
    if type(key) ~= 'string' or #key < 1 or #key > MAX_META_KEY then return false end
    local kind = type(value)
    if kind == 'function' or kind == 'thread' or kind == 'userdata' then return false end
    local record = Core.DB.get(VEHICLE_COLLECTION, vehId)
    if not record then return false end
    local meta = type(record.meta) == 'table' and record.meta or {}
    meta[key] = value
    -- DB.update runs jsonSafe over the patch, so a vector3 inside `value` is stored as { x, y, z }.
    return Core.DB.update(VEHICLE_COLLECTION, vehId, { meta = meta })
end

--- One key of the record's `meta`, or the whole (copied) meta table when `key` is nil.
function Vehicles.getData(target, key)
    local vehId = recordIdOf(target)
    if not vehId then return nil end
    local record = Core.DB.get(VEHICLE_COLLECTION, vehId)
    local meta = record and record.meta
    if type(meta) ~= 'table' then return nil end
    if key == nil then return meta end
    if type(key) ~= 'string' then return nil end
    return meta[key]
end

-- ---------------------------------------------------------------------------
-- Target selectors (DESIGN §49): Player.resolveTargets(actorSrc, selector, opts?)
-- ---------------------------------------------------------------------------
-- `,` = union, `!token` = remove. me | ^ · <id> | $<id> · c:<charId> · r:<metres> · #<group> ·
-- %<group> · f:<faction> · * · others · anything else = partial name. Loaded players only, de-duplicated,
-- first-seen order (r: nearest first, set tokens by src). The cost of one call is bounded: tokens are
-- de-duplicated (case-insensitively, except c:), at most SET_CAP set tokens (* others r: f: # %) and NAME_CAP
-- partial names are allowed, the player list, the
-- lower-cased names and the group table are built at most ONCE per call (on first use, no per-player
-- allocation for weights), and opts.max stops the union as soon as it is exceeded.
-- opts.basic = true restricts the grammar to me / ^ / ids / c: / names (commands for non-staff).

local MAX_SELECTOR <const> = 256
local MAX_TOKENS <const> = 32
local SET_CAP <const> = 4
local NAME_CAP <const> = 8
local MAX_RADIUS <const> = 500.0
local MAX_CANDIDATES <const> = 10

--- The tokens that expand to a set of players: the costly ones, capped, and never `basic`.
local function isSetToken(token)
    local sigil = token:sub(1, 1)
    local lower = token:lower()
    return token == '*' or lower == 'others' or lower:find('^[rf]:.') ~= nil
        or ((sigil == '#' or sigil == '%') and #token > 1)
end

--- A partial-name token (anything that is not a keyword, an id, c:<charId> or a set token).
local function isNameToken(token)
    local lower = token:lower()
    return not (lower == 'me' or token == '^' or token:find('^%$?%d+$') or lower:find('^c:.') or isSetToken(token))
end

--- Loaded srcs, ascending — once per call.
local function ctxList(ctx)
    local list = ctx.list
    if not list then
        list = Player.getPlayers()
        table.sort(list)
        ctx.list = list
    end
    return list
end

--- { [group] = weight } from Perms.groups() (§44) or the config seed — once per call.
local function ctxGroups(ctx)
    if ctx.groups then return ctx.groups end
    local groups, perms, ok, list = {}, Core.Perms, false, nil
    if type(perms) == 'table' and Utils.isCallable(perms.groups) then ok, list = pcall(perms.groups) end
    if ok and type(list) == 'table' then
        for i = 1, #list do
            local group = list[i]
            if type(group) == 'table' and type(group.name) == 'string' then
                groups[group.name] = tonumber(group.weight) or 0
            end
        end
    else
        local cfg = Config.Perms or {}
        for name in pairs(cfg.Groups or {}) do groups[name] = tonumber((cfg.Weights or {})[name]) or 0 end
    end
    ctx.groups = groups
    return groups
end

--- The group the way Perms.getGroup reads it (unknown → 'user'), without allocating.
local function groupOf(ctx, src)
    local group = Player.getGroup(src)
    if group ~= nil and ctxGroups(ctx)[group] then return group end
    return 'user'
end

--- The group name as written, else lower-cased; nil when neither exists.
local function groupName(ctx, raw)
    local groups = ctxGroups(ctx)
    if groups[raw] then return raw end
    local lower = raw:lower()
    return groups[lower] and lower or nil
end

--- Lower-cased character and connection names, parallel to ctxList — once per call.
local function ctxNames(ctx)
    if ctx.chars then return ctx.chars, ctx.conns end
    local list, chars, conns = ctxList(ctx), {}, {}
    for i = 1, #list do
        local charName, connName = namesOf(list[i])
        chars[i] = type(charName) == 'string' and charName:lower() or ''
        conns[i] = type(connName) == 'string' and connName:lower() or ''
    end
    ctx.chars, ctx.conns = chars, conns
    return chars, conns
end

--- Online members of the faction whose id, tag or name (case-insensitive) is `value`; nil = no faction.
local function factionMembers(value)
    local factions = Core.Factions
    if type(factions) ~= 'table' or not Utils.isCallable(factions.list) then return nil end
    local wanted = value:lower()
    local list = factions.list()
    for i = 1, #list do
        local faction = list[i]
        if tostring(faction.id) == value or (type(faction.tag) == 'string' and faction.tag:lower() == wanted)
            or (type(faction.name) == 'string' and faction.name:lower() == wanted) then
            local out, members = {}, factions.getMembers(faction.id)
            for j = 1, #members do
                local online = members[j].online
                if online and Player.isLoaded(online) then out[#out + 1] = online end
            end
            table.sort(out)
            return out
        end
    end
    return nil
end

--- Partial, case-insensitive name: one match → it; several → the single EXACT match among them if there
--- is one, else 'ambiguous' with ≤ 10 { src, name }.
local function byName(ctx, token)
    local wanted = token:lower()
    local list = ctxList(ctx)
    local chars, conns = ctxNames(ctx)
    local first, count, exact, exactCount = nil, 0, nil, 0
    for i = 1, #list do
        if chars[i]:find(wanted, 1, true) or conns[i]:find(wanted, 1, true) then
            count = count + 1
            first = first or i
            if chars[i] == wanted or conns[i] == wanted then exact, exactCount = list[i], exactCount + 1 end
        end
    end
    if count == 1 then return list[first] end
    if count == 0 then return nil, 'not_found', token end
    if exactCount == 1 then return exact end
    local candidates = {}
    for i = first, #list do
        if #candidates >= MAX_CANDIDATES then break end
        if chars[i]:find(wanted, 1, true) or conns[i]:find(wanted, 1, true) then
            local src = list[i]
            local name = Player.getName(src) or GetPlayerName(src) or tostring(src)
            candidates[#candidates + 1] = { src = src, name = name }
        end
    end
    return nil, 'ambiguous', candidates
end

--- Feeds every src of `list` (optionally filtered by keep) to add; stops when add answers false.
local function feed(list, add, keep)
    for i = 1, #list do
        local src = list[i]
        if (not keep or keep(src)) and add(src) == false then return end
    end
end

--- One token: calls add(src) for every match (add answers false to stop). true | nil, err, detail.
local function resolveToken(ctx, token, add)
    local actor = ctx.actor
    local lower = token:lower()
    if lower == 'me' or token == '^' then
        if actor == 0 or not Player.isLoaded(actor) then return nil, 'no_self', token end
        add(actor)
        return true
    end
    local id = token:match('^%$?(%d+)$')
    if id then
        local src = math.tointeger(tonumber(id))
        if not (src and Player.isLoaded(src)) then return nil, 'not_found', token end
        add(src)
        return true
    end
    local prefix = lower:match('^([crf]):.')
    local value = prefix and token:sub(3)
    if prefix == 'c' then
        local numeric = tonumber(value)   -- ids are strings on every adapter; a numeric one is tried too
        local src = Player.getSrcByCharId(value) or (numeric and Player.getSrcByCharId(math.tointeger(numeric)))
        if not (src and Player.isLoaded(src)) then return nil, 'not_found', token end
        add(src)
        return true
    end
    local sigil = token:sub(1, 1)
    local isSet = isSetToken(token)
    if isSet and ctx.basic then return nil, 'not_allowed', token end
    if token == '*' then
        feed(ctxList(ctx), add)
    elseif lower == 'others' then
        feed(ctxList(ctx), add, function(src) return src ~= actor end)
    elseif prefix == 'r' then
        local radius = tonumber(value)
        if not radius or radius ~= radius or radius <= 0 or radius > MAX_RADIUS then return nil, 'bad_radius', token end
        if actor == 0 or not Player.isLoaded(actor) then return nil, 'no_origin', token end
        local near = Player.getInRange(Player.getCoords(actor), radius)
        for i = 1, #near do
            if Player.isLoaded(near[i].src) and add(near[i].src) == false then break end
        end
    elseif prefix == 'f' then
        local members = factionMembers(value)
        if not members then return nil, 'unknown_faction', token end
        feed(members, add)
    elseif isSet then   -- #group / %group
        local name = groupName(ctx, token:sub(2))
        if not name then return nil, 'unknown_group', token end
        if sigil == '#' then
            feed(ctxList(ctx), add, function(src) return groupOf(ctx, src) == name end)
        else
            local groups = ctxGroups(ctx)
            local floor = groups[name]
            feed(ctxList(ctx), add, function(src) return (groups[groupOf(ctx, src)] or 0) >= floor end)
        end
    else
        local src, err, detail = byName(ctx, token)
        if not src then return nil, err, detail end
        add(src)
    end
    return true
end

--- Player.resolveTargets(actorSrc, selector, opts? = { max?, allowSelf? = true, basic? = false })
---   -> array of src | nil, err, detail
--- err: 'bad_actor' | 'bad_selector' | 'not_allowed' | 'not_found' | 'ambiguous' (detail = ≤ 10 { src, name }) |
--- 'no_self' | 'no_origin' | 'bad_radius' | 'unknown_group' | 'unknown_faction' | 'self' | 'no_match' |
--- 'too_many' (detail = max + 1: the union stops there). Other errors carry the offending token as
--- detail. A `!` token that matches nobody is a no-op. Permission checks on multi-target selectors are the
--- caller's job (§51); opts.basic only narrows the grammar.
function Player.resolveTargets(actorSrc, selector, opts)
    local actor = type(actorSrc) == 'number' and math.tointeger(actorSrc) or nil
    if not actor or actor < 0 then return nil, 'bad_actor' end
    if opts ~= nil and type(opts) ~= 'table' then return nil, 'bad_selector' end
    opts = opts or {}
    local max = math.type(opts.max) == 'integer' and opts.max > 0 and opts.max or nil
    if math.type(selector) == 'integer' then selector = tostring(selector) end
    if type(selector) ~= 'string' or #selector > MAX_SELECTOR then return nil, 'bad_selector' end
    local basic = opts.basic == true

    -- pass 1: split, trim, de-duplicate, cap — before anything touches the player list
    local adds, removes, seenToken, tokens, sets, names = {}, {}, {}, 0, 0, 0
    for raw in selector:gmatch('[^,]+') do
        local token = raw:match('^%s*(.-)%s*$')
        if token ~= '' then
            tokens = tokens + 1
            if tokens > MAX_TOKENS then return nil, 'bad_selector' end
            local negate = token:sub(1, 1) == '!'
            if negate then
                if basic then return nil, 'not_allowed', token end
                token = token:sub(2):match('^%s*(.-)%s*$')
                if token == '' then return nil, 'bad_selector' end
            end
            -- names, keywords, groups and factions compare case-insensitively, so they de-duplicate that way
            -- too (R2-7: 'jo,Jo,JO,…' is ONE name scan); only a c:<charId> keeps its case
            local lower = token:lower()
            local key = (negate and '!' or '+') .. (lower:find('^c:') and token or lower)
            if not seenToken[key] then
                seenToken[key] = true
                if isSetToken(token) then
                    if basic then return nil, 'not_allowed', token end
                    sets = sets + 1
                    if sets > SET_CAP then return nil, 'bad_selector', token end
                elseif isNameToken(token) then
                    names = names + 1   -- each is a pass over every loaded name
                    if names > NAME_CAP then return nil, 'bad_selector', token end
                end
                local into = negate and removes or adds
                into[#into + 1] = token
            end
        end
    end
    if tokens == 0 then return nil, 'bad_selector' end

    -- pass 2: removals first, so the union below can stop the moment it passes opts.max
    local ctx = { actor = actor, basic = basic }
    local removed = {}
    local function remove(src) removed[src] = true end
    for i = 1, #removes do
        local ok, err, detail = resolveToken(ctx, removes[i], remove)
        if not ok and err ~= 'not_found' and err ~= 'no_self' then return nil, err, detail end
    end
    local out, seen, droppedSelf, over = {}, {}, false, false
    local allowSelf = opts.allowSelf ~= false
    local function add(src)
        if seen[src] then return true end
        seen[src] = true
        if removed[src] then return true end
        if src == actor and not allowSelf then
            droppedSelf = true
            return true
        end
        out[#out + 1] = src
        if max and #out > max then
            over = true
            return false
        end
        return true
    end
    for i = 1, #adds do
        local ok, err, detail = resolveToken(ctx, adds[i], add)
        if not ok then return nil, err, detail end
        if over then return nil, 'too_many', #out end
    end
    if #out == 0 then return nil, droppedSelf and 'self' or 'no_match' end
    return out
end
