--[[
    core/server/player.lua — Core.Player (DESIGN §4.2, §5, §8, §56)

    Sessions: the connection lifecycle (playerConnecting deferrals + ban check, playerJoining load,
    core:server:requestLoad answer), the autosave loop, death/respawn, and the replication of the §8
    player state-bag keys through the single replicate(src, key?) helper. Core owns those keys
    (CORE_STATE_KEYS below); plugin keys go through Player.setReplicated.

    Persistence (§56.6, §56.8) lives in server/player_store.lua, which loads RIGHT BEFORE this file and hands
    its table over once (the global CorePlayerStore). A session is read with { sync = true } (a READ ERROR
    refuses the join, it never creates a row); every change (setData, setModel, setCoords, money, the death
    counter, setAccountData, setGroup) is QUEUED at once; the autosave adds position, playtime, last_seen /
    last_played and whatever is still dirty. Save paths never yield. Plugins never write the `characters` /
    `accounts` rows directly while a session exists (its next write wins): use setData / Money / setGroup.

    Natives (fxref 2026-09-26, CFX server): GetVehiclePedIsIn(ped, lastVehicle), GetPedInVehicleSeat(vehicle,
    seatIndex), SetEntityRoutingBucket(entity, bucket), SetPlayerRoutingBucket, GetPlayerRoutingBucket, GetPlayerName,
    GetPlayerPed, GetEntityCoords, GetEntityHeading, GetEntityHealth, DropPlayer, NetworkGetNetworkIdFromEntity
    (the identifier natives and the connect-time ban gate live in server/player_store.lua).
]]

-- runtime Player(src) state-bag accessor, captured before the module table shadows the global
local playerBag = Player

local Store = CorePlayerStore
assert(type(Store) == 'table', 'server/player_store.lua must load right before server/player.lua (CorePlayerStore)')
-- fxlint-disable-next-line C003 -- clears the one-shot hand-off created by server/player_store.lua
CorePlayerStore = nil

local Player = {}

local Log = Core.Log
local Utils = Core.Utils
local Net = Core.Net

local sessions = {}      -- [src] = session table (see DESIGN §4.2)
local byCharId = {}      -- [charId] = src
local byAccountId = {}   -- [accountId] = src (Player.getAccountById prefers the live session)
local loadCooldown = {}  -- [src] = GetGameTimer() of the last requestLoad
local loading = {}       -- [src] = true while its session loads (the reads yield)
local loadingLicense = {} -- [license] = src while a load of that license runs (one account, one character)
local autosaveRunning = false

local MAX_BUCKET <const> = 65535
local LOAD_WAIT_MS <const> = 10000
local LOAD_POLL_MS <const> = 250

-- character keys that mirror into the player state bag (§8)
local REPLICATED <const> = { name = true, money = true, faction = true }

-- player state-bag keys core writes itself (§8, §18, §20); plugins may not take them over
local CORE_STATE_KEYS <const> = {
    loaded = true, name = true, charId = true, group = true, cash = true, bank = true,
    faction = true, dead = true, stats = true, attachments = true,
    -- §51: server-written staff state (Core.Admin duty + sanctioned modes); a plugin must never overwrite it
    duty = true, staffModes = true,
}

-- sticky player states (§48): the client re-applies every value that differs from these
local STATE_DEFAULTS <const> = { frozen = false, invincible = false, visible = true, controls = true }

-- the read-only account view of Player.getAccount / getAccountById (§48): no permissions list
local ACCOUNT_FIELDS <const> = { 'id', 'name', 'group', 'identifiers', 'firstSeen', 'lastSeen', 'playtime', 'banned' }

--- Sanitized display name for a connected player.
local function playerName(src)
    return Utils.sanitize(GetPlayerName(src) or 'Unknown', Config.Player.MaxNameLength)
end

local identifierOf, collectIdentifiers = Store.identifierOf, Store.collectIdentifiers

--- Faction summary for the state bag (§8): the six public fields, or false when in no faction.
local function factionSummary(src)
    local factions = Core.Factions
    if not factions or type(factions.getPlayerFaction) ~= 'function' then return false end
    local ok, faction = pcall(factions.getPlayerFaction, src)
    if not ok or type(faction) ~= 'table' then return false end
    return {
        id = faction.id, name = faction.name, tag = faction.tag,
        color = faction.color, rank = faction.rank, rankName = faction.rankName,
    }
end

--- The one replication helper (§8). Server writes, clients read. key = nil writes every key.
local function replicate(src, key)
    local session = sessions[src]
    if not session then return end
    session.loadPayload = nil -- every replicated key is also carried by the core:client:loaded payload
    local bag = playerBag(src)
    local state = bag and bag.state
    if not state then return end
    local data = session.data

    if key == nil or key == 'name' then
        state:set('name', data.name or session.name, true)
    end
    if key == nil or key == 'charId' then
        state:set('charId', session.charId, true)
    end
    if key == nil or key == 'group' then
        state:set('group', session.account.group or 'user', true)
    end
    if key == nil or key == 'money' then
        local money = data.money or {}
        state:set('cash', money.cash or 0, true)
        state:set('bank', money.bank or 0, true)
    end
    if key == nil or key == 'faction' then
        state:set('faction', factionSummary(src), true)
    end
    if key == nil or key == 'dead' then
        state:set('dead', session.deadSince ~= nil, true)
    end
    if key == nil then
        state:set('loaded', true, true)
    end
end

--- Walks a dot path ('money.cash'); returns the container table and the final key.
local function resolvePath(root, path, create)
    if type(path) ~= 'string' or path == '' then return nil end
    local node = root
    local last = nil
    for part in path:gmatch('[^%.]+') do
        if last then
            local nxt = node[last]
            if type(nxt) ~= 'table' then
                if not create then return nil end
                nxt = {}
                node[last] = nxt
            end
            node = nxt
        end
        last = part
    end
    return node, last
end

--- Drops the cached core:client:loaded payload (§5 requestLoad) after a change of the session.
local function touch(session)
    session.loadPayload = nil
end

--- Queues the given top-level character keys NOW (never yields): the queue coalesces per row, so money and
--- every other change are durable within one flush instead of one autosave (§56.8 rule 3).
local function persistChar(session, ...)
    for i = 1, select('#', ...) do Store.markChar(session, (select(i, ...))) end
    Store.flush({ session })
end

--- The same for account keys (setAccountData, setGroup).
local function persistAccount(session, key)
    Store.markAccount(session, key)
    Store.flush({ session })
end

-- a stored position within these of the live ped is not rewritten (standing still writes nothing)
local POSITION_EPSILON <const> = 0.05
local HEADING_EPSILON <const> = 1.0

--- Refreshes data.position from the live ped (skipped while dead or without a ped); marks it dirty only when
--- the ped moved (the autosave writes it).
local function refreshPosition(session)
    if session.deadSince then return end
    local ped = GetPlayerPed(session.src)
    if ped == 0 then return end
    local coords = GetEntityCoords(ped)
    if coords.x == 0.0 and coords.y == 0.0 and coords.z == 0.0 then return end
    local heading = GetEntityHeading(ped) + 0.0
    local stored = session.data.position
    if type(stored) == 'table' and type(stored.x) == 'number' and type(stored.y) == 'number'
        and type(stored.z) == 'number' and math.abs(stored.x - coords.x) < POSITION_EPSILON
        and math.abs(stored.y - coords.y) < POSITION_EPSILON and math.abs(stored.z - coords.z) < POSITION_EPSILON
        and math.abs((tonumber(stored.heading) or 0.0) - heading) < HEADING_EPSILON then
        return
    end
    session.data.position = { x = coords.x, y = coords.y, z = coords.z, heading = heading }
    Store.markChar(session, 'position')
    touch(session)
end

--- Adds the seconds elapsed since the last accounting tick to the character and account playtime and marks
--- stats / last_played / playtime / last_seen dirty (nothing when no second passed).
local function addPlaytime(session)
    local now = os.time()
    local elapsed = now - (session.playtimeAt or now)
    session.playtimeAt = now
    if elapsed <= 0 then return end
    local stats = session.data.stats
    if type(stats) ~= 'table' then
        stats = { deaths = 0, playtime = 0 }
        session.data.stats = stats
    end
    stats.playtime = (stats.playtime or 0) + elapsed
    session.account.playtime = (session.account.playtime or 0) + elapsed
    session.account.lastSeen = now
    session.playedAt = now
    Store.markChar(session, 'stats')
    Store.markAccount(session, 'playtime')
    Store.markAccount(session, 'lastSeen')
end

local LOAD_FAILED_TEXT <const> = 'Your account could not be loaded right now. Please reconnect in a minute.'

--- A read failed (or the load threw): the join is refused with a retry message — never a new row (§56.8 rule 4).
local function refuseLoad(src, what, err)
    Log.error('could not load the %s of [%d] (%s): join refused', what, src, tostring(err))
    if GetPlayerName(src) ~= nil then DropPlayer(src, LOAD_FAILED_TEXT) end
    return nil
end

-- [license] = releases of a session of that license WHILE a load of it runs. The load's { sync = true } reads only
-- wait for writes queued BEFORE they started: a session saved and released while they ran is read again.
local releaseGen = {}
local MAX_READS <const> = 3

--- Removes a session after queueing its final save; the playerDropped hook runs first, while the session is still
--- loaded (the engine's drop and a takeover alike — every module forgets the src the same way).
local function releaseSession(src, session)
    refreshPosition(session)
    addPlaytime(session)
    Core.emitHook('playerDropped', src, session.charId)
    Player.save(src)
    -- only when this src still owns the character: a fast reconnect may have re-bound it already
    if byCharId[session.charId] == src then byCharId[session.charId] = nil end
    if byAccountId[session.accountId] == src then byAccountId[session.accountId] = nil end
    sessions[src] = nil
    loadCooldown[src] = nil
    if loadingLicense[session.license] then releaseGen[session.license] = (releaseGen[session.license] or 0) + 1 end
end

--- Unclean reconnect before the drop was noticed: the ghost session on the older src holds the newest state. It
--- is released like a drop (its save QUEUED); the load then reads again with { sync = true }, which waits for it.
local function releaseGhost(ghostSrc, src)
    local ghost = sessions[ghostSrc]
    Log.warn('character %s was still bound to [%d]; handing it to [%d]', tostring(ghost.charId), ghostSrc, src)
    releaseSession(ghostSrc, ghost)
end

--- The live src bound to this account or character other than `src`, or nil.
local function ghostOf(src, accountId, charId)
    local other = byAccountId[accountId]
    if other and other ~= src and sessions[other] then return other end
    other = charId and byCharId[charId]
    if other and other ~= src and sessions[other] then return other end
    return nil
end

--- Reads (or creates) the rows and builds the in-memory session; nil when the join was refused. Yields. The reads
--- repeat (with sync) while a session of this license was released meanwhile — a takeover included.
local function buildSession(src, fresh, license, sync)
    local name = playerName(src)
    local account, character
    for attempt = 1, MAX_READS do
        local generation = releaseGen[license]
        local ok, a, b = Store.readRows(license, name, sync or attempt > 1)
        if not ok then return refuseLoad(src, a, b) end
        account, character = a, b
        local ghostSrc = ghostOf(src, account.id, character and character.id)
        if ghostSrc then releaseGhost(ghostSrc, src) end
        if releaseGen[license] == generation then break end
        if attempt == MAX_READS then return refuseLoad(src, 'account', 'released again while it loaded') end
    end
    if character == false then
        local err
        character, err = Store.createCharacter(account.id, name)
        if not character then return refuseLoad(src, 'character', err) end
    end
    if GetPlayerName(src) == nil then   -- left while the reads ran: no session, nothing stamped
        Log.info('[%d] left while the session loaded', src)
        return nil
    end

    local now = os.time()
    account.name, account.lastSeen, account.identifiers = name, now, collectIdentifiers(src)
    local session = {
        src = src, accountId = account.id, charId = character.id, license = license,
        name = (type(character.name) == 'string' and character.name ~= '') and character.name or name,
        account = account, data = character, loadedAt = now, playtimeAt = now, deadSince = nil,
        fresh = fresh and true or false, answered = false,
        states = Utils.deepCopy(STATE_DEFAULTS),
    }
    Store.initSession(session)
    Store.markAccount(session, 'name')
    Store.markAccount(session, 'lastSeen')
    Store.flush({ session })
    Store.saveIdentifiers(account.id, account.identifiers)
    sessions[src] = session
    byCharId[character.id] = src
    byAccountId[account.id] = src
    replicate(src)
    Log.info('session ready for [%d] %s (character %s)', src, session.name, character.id)
    return session
end

--- Finds or creates the account + character rows and builds the in-memory session. fresh = true for a real
--- join (the client should spawn), false when core restarted under a player already in the world; sync = false
--- only for the restore after `restart core` (it flushed once). Yields.
local function loadSession(src, fresh, sync)
    local existing = sessions[src]
    if existing then return existing end
    if loading[src] then return nil end
    local license = identifierOf(src, 'license')
    if not license then
        DropPlayer(src, 'No license identifier.')
        return nil
    end
    loading[src] = true   -- a second load of this src (a join racing the restore) returns at once
    -- one load per license at a time: two quick joins of one account must never both create a character
    local deadline = GetGameTimer() + LOAD_WAIT_MS
    while loadingLicense[license] and GetGameTimer() < deadline do Wait(LOAD_POLL_MS) end
    if sessions[src] or loadingLicense[license] then
        loading[src] = nil
        if sessions[src] then return sessions[src] end
        return refuseLoad(src, 'account', 'another load of this license is running')
    end
    loadingLicense[license] = src
    local ok, session = pcall(buildSession, src, fresh, license, sync ~= false)
    loading[src], loadingLicense[license], releaseGen[license] = nil, nil, nil
    if not ok then return refuseLoad(src, 'session', session) end
    return session
end

AddEventHandler('playerConnecting', function(_, _, deferrals)
    local src = source
    deferrals.defer()
    Wait(0) -- required: at least one tick between defer() and update()/done()
    deferrals.update(Config.Texts.loading or 'Checking your account...')

    local license = identifierOf(src, 'license')
    if not license then
        return deferrals.done('No license identifier — restart FiveM and reconnect.')
    end

    local ban, notice = Store.connectingBan(src, license)
    if ban then return deferrals.done(notice) end
    deferrals.done()
end)

AddEventHandler('playerJoining', function()
    local src = source
    loadSession(src, true)
end)

AddEventHandler('playerDropped', function()
    local src = source
    loadCooldown[src] = nil
    local session = sessions[src]
    if session then releaseSession(src, session) end
end)

-- core_db dropped a queued write of core's (§56.3.5, `key` = the row key): the session re-sends that row next save
Core.on('dbWriteFailed', function(owner, _, tbl, _, key)
    if owner ~= Core.name then return end
    local src
    if tbl == 'characters' then src = byCharId[key]
    elseif tbl == 'accounts' then src = byAccountId[key]
    elseif tbl == 'character_money' and type(key) == 'table' then src = byCharId[key.character_id] end
    local session = src and sessions[src]
    if session then Store.writeFailed(session, tbl, key) end
end)

-- == API (DESIGN §4.2) — every function returns nil/false without a loaded session ==========================

function Player.isLoaded(src)
    return sessions[src] ~= nil
end

function Player.getInfo(src)
    local session = sessions[src]
    if not session then return nil end
    return {
        src = src, charId = session.charId, accountId = session.accountId,
        name = session.name, group = session.account.group or 'user', license = session.license,
    }
end

function Player.getData(src, path)
    local session = sessions[src]
    if not session then return nil end
    if path == nil then return Utils.deepCopy(session.data) end
    local node, key = resolvePath(session.data, path, false)
    if not node or key == nil then return nil end
    local value = node[key]
    return type(value) == 'table' and Utils.deepCopy(value) or value
end

-- the stored identity of the character (DESIGN §56.6: read-only columns) — setData never rewrites them
local READ_ONLY_KEYS <const> = { id = true, accountId = true, createdAt = true, updatedAt = true }

--- Sets a dot path of the character and QUEUES its top-level key at once (a column, the money rows, or the
--- plugin `data` map; `faction` is session-only). Never yields.
function Player.setData(src, path, value)
    local session = sessions[src]
    if not session then return false end
    local top = type(path) == 'string' and path:match('^[^%.]+') or nil
    if not top or READ_ONLY_KEYS[top] then return false end
    local node, key = resolvePath(session.data, path, true)
    if not node or key == nil then return false end
    value = Utils.jsonSafe(value)   -- every value (a vector3 too): what is stored is what JSON can carry
    node[key] = value
    touch(session)
    persistChar(session, top)
    if top == 'name' and type(session.data.name) == 'string' then session.name = session.data.name end
    if REPLICATED[top] then replicate(src, top) end
    local changed = session.data[top]
    Core.emitHook('playerDataChanged', src, top,
        type(changed) == 'table' and Utils.deepCopy(changed) or changed)
    return true
end

--- One chunk of sessions: playtime accounted, then everything dirty queued in table order (§56.8 rule 6).
--- The playerSaved hook fires for every session that wrote something. Never yields.
local function saveSessions(list, srcs)
    for i = 1, #list do addPlaytime(list[i]) end
    local wrote = Store.flush(list)
    for i = 1, #list do
        if wrote[i] then Core.emitHook('playerSaved', srcs[i]) end
    end
end

--- Queues the session's dirty state (never yields: safe in onResourceStop). True for a live session.
function Player.save(src)
    local session = sessions[src]
    if not session then return false end
    saveSessions({ session }, { src })
    return true
end

--- Every session, position included (core's stop, txAdmin's shutdown). Queued, never yields; internal (export-blocked).
function Player.saveAll()
    local list, srcs = {}, {}
    for src, session in pairs(sessions) do
        refreshPosition(session)
        list[#list + 1], srcs[#srcs + 1] = session, src
    end
    saveSessions(list, srcs)
    return #list
end

function Player.getPlayers()
    local out = {}
    for src in pairs(sessions) do out[#out + 1] = src end
    return out
end

function Player.forEach(fn)
    if not Core.Utils.isCallable(fn) then return end
    for src in pairs(sessions) do fn(src, Player.getInfo(src)) end
end

function Player.count()
    local count = 0
    for _ in pairs(sessions) do count = count + 1 end
    return count
end

function Player.getSrcByCharId(charId)
    local src = byCharId[charId]
    return src and sessions[src] and src or nil
end

function Player.getName(src) return sessions[src] and sessions[src].name or nil end
function Player.getLicense(src) return sessions[src] and sessions[src].license or nil end
function Player.getPed(src) return sessions[src] and (GetPlayerPed(src) or 0) or 0 end

function Player.getCoords(src)
    local session = sessions[src]
    if not session then return nil end
    local ped = GetPlayerPed(src)
    if ped ~= 0 then return GetEntityCoords(ped), GetEntityHeading(ped) end
    local position = session.data.position or {}
    return vector3(position.x or 0.0, position.y or 0.0, position.z or 0.0), position.heading or 0.0
end

--- Accepts a vector3 or a { x, y, z } table; returns a vector3 or nil.
local function toVector3(value)
    if type(value) == 'vector3' then return value end
    if type(value) == 'table' and Utils.isNumber(value.x) and Utils.isNumber(value.y)
        and Utils.isNumber(value.z) then
        return vector3(value.x + 0.0, value.y + 0.0, value.z + 0.0)
    end
    return nil
end

local function isBucket(bucket)
    return math.type(bucket) == 'integer' and bucket >= 0 and bucket <= MAX_BUCKET
end

--- The vehicle `src` sits in as its DRIVER, or 0 (a passenger never takes the car along).
local function drivenVehicle(src)
    local ped = GetPlayerPed(src)
    if ped == 0 then return 0 end
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 or GetPedInVehicleSeat(vehicle, -1) ~= ped then return 0 end
    return vehicle
end

--- §48 opts = { withVehicle = false, fade = true, bucket?, moveRiders = false }: the bucket changes first.
function Player.setCoords(src, coords, heading, opts)
    local session = sessions[src]
    if not session then return false end
    local target = toVector3(coords)
    if not target then return false end
    if opts ~= nil and type(opts) ~= 'table' then return false end
    opts = opts or {}
    local bucket = opts.bucket
    if bucket ~= nil and not isBucket(bucket) then return false end
    local vehicle = opts.withVehicle == true and drivenVehicle(src) or 0
    if bucket ~= nil then
        if vehicle ~= 0 then SetEntityRoutingBucket(vehicle, bucket) end
        -- other players ride along only on request: the CALLER vouches for its rank checks (R2-13)
        if vehicle ~= 0 and opts.moveRiders == true and Utils.isCallable(Player.getInVehicle) then
            local riders = Player.getInVehicle(NetworkGetNetworkIdFromEntity(vehicle))
            for i = 1, #riders do
                if riders[i] ~= src then Player.setBucket(riders[i], bucket) end
            end
        end
        Player.setBucket(src, bucket)
    end
    local stored = session.data.position or {}
    local dir = Utils.isNumber(heading) and heading + 0.0 or (stored.heading or 0.0) + 0.0
    session.data.position = { x = target.x, y = target.y, z = target.z, heading = dir }
    touch(session)
    persistChar(session, 'position')
    local flags = nil   -- only sent when something differs from the plain faded teleport
    if vehicle ~= 0 or opts.fade == false then
        flags = { withVehicle = vehicle ~= 0, fade = opts.fade ~= false }
    end
    -- §55.6: subscribe the destination's scene window before the client moves (Scene.waitAreaReady gates the reveal)
    local sceneRuntime = Core.SceneRuntime
    local interest = sceneRuntime and sceneRuntime.interest
    if interest and Utils.isCallable(interest.prefetch) then
        local ok, err = pcall(interest.prefetch, src, target.x, target.y, target.z)
        if not ok then Core.Log.warn('Player.setCoords: scene prefetch failed: %s', tostring(err)) end
    end
    TriggerClientEvent('core:client:teleport', src, target, dir, flags)
    return true
end

function Player.setModel(src, model, appearance)
    local session = sessions[src]
    if not session then return false end
    if not Utils.isString(model, 64) then return false end
    session.data.model = model
    if type(appearance) == 'table' then session.data.appearance = Utils.jsonSafe(appearance) end
    touch(session)
    persistChar(session, 'model', 'appearance')
    TriggerClientEvent('core:client:setModel', src, model, session.data.appearance or {})
    -- the hook setData emits (§22): a plugin mirroring the look (inventory clothing) learns of a creator save
    Core.emitHook('playerDataChanged', src, 'model', model)
    if type(appearance) == 'table' then
        Core.emitHook('playerDataChanged', src, 'appearance', Utils.deepCopy(session.data.appearance))
    end
    return true
end

function Player.setBucket(src, bucket)
    if not sessions[src] or not isBucket(bucket) then return false end
    SetPlayerRoutingBucket(src, bucket)
    TriggerClientEvent('core:client:bucketChanged', src, bucket)   -- §48: the map runtime (§52) listens
    return true
end

function Player.getBucket(src)
    if not sessions[src] then return 0 end
    return GetPlayerRoutingBucket(src) or 0
end

--- Changes the account group (Core.Perms.setGroup routes through this: session, document and bag agree).
function Player.setGroup(src, group)
    local session = sessions[src]
    if not session or type(group) ~= 'string' then return false end
    -- §44: any group in perm_groups; the config seed decides while perms v2 is not loaded
    local perms = Core.Perms
    if type(perms) == 'table' and Utils.isCallable(perms.groupExists) then
        if perms.groupExists(group) ~= true then return false end
    elseif Config.Perms.Groups[group] == nil then
        return false
    end
    session.account.group = group
    touch(session)
    persistAccount(session, 'group')   -- queued patch of accounts.perm_group
    replicate(src, 'group')
    Log.audit('player', src, 'group set to %s', group)
    Core.emitHook('permsChanged', src, 'group')   -- staff sets and rights caches refresh on it (§44, §51)
    return true
end

--- The raw account group (no allocation), nil without a session; Perms.getGroup reads unknown ones as 'user'.
function Player.getGroup(src)
    local session = sessions[src]
    return session and session.account.group or nil
end

--- Writes a plugin-owned key to the player state bag (§20). Core keys are refused.
function Player.setReplicated(src, key, value)
    if not sessions[src] then return false end
    if not Utils.isString(key, 64) then return false end
    if CORE_STATE_KEYS[key] then
        Log.warn("refused a plugin write to the core state key '%s' for [%d]", key, src)
        return false
    end
    local bag = playerBag(src)
    local state = bag and bag.state
    if not state then return false end
    state:set(key, type(value) == 'table' and Utils.jsonSafe(value) or value, true)
    return true
end

--- Writes one field of the live account and QUEUES it (§22): 'group' goes through setGroup, `permissions`,
--- `tempPermissions`, `banned`, `name` (…) are columns, any other key lands in `accounts.data`.
function Player.setAccountData(src, key, value)
    local session = sessions[src]
    if not session then return false end
    if not Utils.isString(key, 64) then return false end
    if key == 'group' then return Player.setGroup(src, value) end
    -- engine-sourced (loadSession stamps them into account_identifiers) or the row's own identity
    if Store.ACCOUNT_RESERVED[key] then return false end
    value = Utils.jsonSafe(value)
    session.account[key] = value
    touch(session)
    persistAccount(session, key)
    if key == 'permissions' or key == 'tempPermissions' then Core.emitHook('permsChanged', src, 'grants') end
    return true
end

--- The live account's raw `key` (a deep copy), nil without a session. Never yields: Core.Perms reads the account
--- grants through it on a permission check (§48 notes). Internal — blocked in server/api.lua's export list.
function Player.getAccountData(src, key)
    local session = sessions[src]
    if not session or type(key) ~= 'string' then return nil end
    local value = session.account[key]
    return type(value) == 'table' and Utils.deepCopy(value) or value
end

--- One targeted core:client:playerState event carrying only the field that changed (§17).
local function sendPlayerState(src, partial)
    if not sessions[src] then return false end
    TriggerClientEvent('core:client:playerState', src, partial)
    return true
end

--- §48 sticky state: session.states for the session's lifetime; the client re-applies it (new ped, spawn, teleport).
local function setSticky(src, key, value)
    local session = sessions[src]
    if not session or type(value) ~= 'boolean' then return false end
    session.states[key] = value
    session.loadPayload = nil   -- the core:client:loaded payload carries the states
    return sendPlayerState(src, { [key] = value })
end

function Player.setControls(src, enabled) return setSticky(src, 'controls', enabled) end
function Player.setFrozen(src, frozen) return setSticky(src, 'frozen', frozen) end
function Player.setInvincible(src, invincible) return setSticky(src, 'invincible', invincible) end
function Player.setVisible(src, visible) return setSticky(src, 'visible', visible) end

--- Player.getStates(src) -> { frozen, invincible, visible, controls } (a copy) | nil without a session.
function Player.getStates(src)
    local session = sessions[src]
    return session and Utils.deepCopy(session.states) or nil
end

--- Read-only copy of an account document's public fields (§48).
local function accountView(doc)
    local out = {}
    for _, key in ipairs(ACCOUNT_FIELDS) do
        out[key] = type(doc[key]) == 'table' and Utils.deepCopy(doc[key]) or doc[key]
    end
    out.group, out.banned = out.group or 'user', out.banned == true
    return out
end

--- Player.getAccount(src) -> { id, name, group, identifiers, firstSeen, lastSeen, playtime, banned } | nil
function Player.getAccount(src)
    local session = sessions[src]
    return session and accountView(session.account) or nil
end

--- The same view by account id: the live session while its player is online, else the stored row (one awaited
--- query with the identifiers — it yields). nil for an unknown id and on a read error (logged).
function Player.getAccountById(accountId)
    if not (Utils.isString(accountId, 64) or math.type(accountId) == 'integer') then return nil end
    local session = byAccountId[accountId] and sessions[byAccountId[accountId]]
    if session then return accountView(session.account) end
    local account, err = Store.readAccount(accountId)
    if account == nil then
        Log.warn('Player.getAccountById(%s): the account cannot be read (%s)', tostring(accountId), tostring(err))
        return nil
    end
    return account and accountView(account) or nil
end

function Player.setHealth(src, hp)
    if math.type(hp) ~= 'integer' or hp < 0 or hp > 200 then return false end
    return sendPlayerState(src, { health = hp })
end

function Player.setArmour(src, ap)
    if math.type(ap) ~= 'integer' or ap < 0 or ap > 100 then return false end
    return sendPlayerState(src, { armour = ap })
end

--- True for a src that is connected right now (DropPlayer must never take a stale id).
local function isConnected(src)
    if type(src) ~= 'number' then return false end
    return sessions[src] ~= nil or GetPlayerName(src) ~= nil
end

function Player.kick(src, reason)
    if not isConnected(src) then return false end
    local text = Utils.sanitize(reason or 'Kicked', 128)
    Log.audit('player', src, 'kicked: %s', text)
    DropPlayer(src, text)
    return true
end

function Player.ban(src, reason, seconds, by)
    if not isConnected(src) then return false end
    local text = Utils.sanitize(reason or 'Banned', 128)
    local duration = (math.type(seconds) == 'integer' and seconds > 0) and seconds or 0
    local bans = Core.Bans
    if type(bans) == 'table' and Utils.isCallable(bans.add) then
        -- §47: Bans.add collects identifiers + tokens, flags the account, audits and drops the player
        local ok, ban, err = pcall(bans.add, { target = src, reason = text, duration = duration, by = by })
        if ok and ban then return true end
        Log.warn('Player.ban: Bans.add refused [%d]: %s — kicked instead', src, tostring(ok and err or ban))
        Player.kick(src, text)   -- the offence must not go on while the ban could not be recorded
        return false
    end
    -- no Core.Bans (server/bans.lua did not load): nothing can record the ban (there is no legacy ban row any
    -- more, DESIGN §56.8) — the player is kicked so the offence does not continue, and false says no ban exists
    Log.error('Player.ban: Core.Bans is not loaded, [%d] is only kicked (reason: %s)', src, text)
    Player.kick(src, text)
    return false
end

function Player.notify(src, message, kind, duration)
    local notify = Core.Notify
    if not notify or type(notify.send) ~= 'function' then return false end
    notify.send(src, message, kind, duration)
    return true
end

function Player.respawn(src, coords, heading)
    local session = sessions[src]
    if not session then return false end
    local target, dir = toVector3(coords), Utils.isNumber(heading) and heading + 0.0 or nil
    if not target then
        local current, currentHeading = Player.getCoords(src)
        target, dir = current, dir or currentHeading
    end
    if not target then return false end
    session.deadSince = nil
    session.deadCoords = nil
    replicate(src, 'dead')
    TriggerClientEvent('core:client:spawn', src, target, dir or 0.0, true)
    Core.emitHook('playerRespawned', src)
    return true
end

--- Builds the session for an already-connected player (core restart; DESIGN §4.2 step 2). Yields (two reads);
--- server/main.lua calls it once the migrations applied, with sync = false after its one Core.DB.flush().
function Player.loadSession(src, sync)
    return loadSession(src, false, sync) ~= nil
end

--- Loads a session for every connected player that has none yet (yields; internal like loadSession).
function Player.loadAllConnected()
    local players = GetPlayers()
    for i = 1, #players do
        local src = tonumber(players[i])
        if src and not sessions[src] then loadSession(src, false) end
    end
end

-- == Net events (DESIGN §5) and the autosave loop ============================================================

-- raw by design (§5): it must answer before the session exists, so it cannot use requireLoaded
RegisterNetEvent('core:server:requestLoad', function()
    local src = source
    local now = GetGameTimer()
    local lastLoad = loadCooldown[src]
    if lastLoad and now - lastLoad < 1000 then return end
    loadCooldown[src] = now

    local session = sessions[src]
    local deadline = now + LOAD_WAIT_MS
    while not session and GetGameTimer() < deadline do
        Wait(LOAD_POLL_MS)
        session = sessions[src] -- cleared again in playerDropped, so this also covers a drop mid-wait
    end
    if not session then
        Log.warn('load request from [%d] timed out without a session', src)
        return
    end

    -- built once, invalidated by touch()/replicate(); repeat requests (core restart) come from the cache
    local payload = session.loadPayload
    if not payload then
        local data = session.data
        payload = {
            charId = session.charId, name = session.name, model = data.model or Config.Player.DefaultModel,
            appearance = Utils.deepCopy(data.appearance or {}), position = Utils.deepCopy(data.position or {}),
            money = Utils.deepCopy(data.money or {}), faction = factionSummary(src),
            group = session.account.group or 'user',
            states = Player.getStates(src),   -- §48: the client keeps re-applying the sticky ones
        }
        session.loadPayload = payload
    end

    local first = not session.answered
    payload.respawn = session.fresh and true or false
    session.fresh = false
    session.answered = true

    TriggerClientEvent('core:client:loaded', src, payload)
    if first then Core.emitHook('playerLoaded', src) end
end)

--- Respawn point of Config.Respawn.Points closest to the death coords.
local function nearestRespawnPoint(coords)
    local points = Config.Respawn.Points
    local best, bestDist = points[1], nil
    if type(coords) ~= 'vector3' then return best end
    for i = 1, #points do
        local dist = #(coords - points[i].coords)
        if not bestDist or dist < bestDist then best, bestDist = points[i], dist end
    end
    return best
end

Net.on('core:server:died', {}, function(src)
    local session = sessions[src]
    if not session or session.deadSince then return end
    local ped = GetPlayerPed(src)
    if ped ~= 0 and GetEntityHealth(ped) > 0 then return end

    session.deadSince = GetGameTimer()
    if ped ~= 0 then session.deadCoords = GetEntityCoords(ped) end
    local stats = session.data.stats
    if type(stats) ~= 'table' then
        stats = { deaths = 0, playtime = 0 }
        session.data.stats = stats
    end
    stats.deaths = (stats.deaths or 0) + 1
    touch(session)
    persistChar(session, 'stats')
    replicate(src, 'dead')
    Core.emitHook('playerDied', src)
end, { cooldown = 2000, requireLoaded = true })

Net.on('core:server:respawn', {}, function(src)
    local session = sessions[src]
    if not session or not session.deadSince then return end
    if GetGameTimer() - session.deadSince < Config.Respawn.DelayMs - 500 then return end
    local point = nearestRespawnPoint(session.deadCoords)
    Player.respawn(src, point and point.coords, point and point.heading)
end, { cooldown = 1000, requireLoaded = true })

--- Autosave in chunks (DESIGN §9 "Scale"): AUTOSAVE_CHUNK sessions, then AUTOSAVE_CHUNK_MS of air, so a
--- full server is spread over ~20 s instead of one tick; below one chunk the pass is a single tick.
local AUTOSAVE_CHUNK <const> = 25
local AUTOSAVE_CHUNK_MS <const> = 250

--- One autosave pass: per chunk, position and playtime of every session, then ONE queued pass over the chunk
--- (characters, money rows, accounts — §56.8 rule 6). It yields between chunks, so the srcs are snapshotted
--- first and a session that left meanwhile is skipped (playerDropped saved it).
local function autosaveTick()
    local order, count = {}, 0
    for src in pairs(sessions) do count = count + 1; order[count] = src end
    for first = 1, count, AUTOSAVE_CHUNK do
        if first > 1 then
            Wait(AUTOSAVE_CHUNK_MS)
            if not autosaveRunning then return end
        end
        local list, srcs = {}, {}
        for i = first, math.min(count, first + AUTOSAVE_CHUNK - 1) do
            local session = sessions[order[i]]
            if session then
                refreshPosition(session)
                list[#list + 1], srcs[#srcs + 1] = session, order[i]
            end
        end
        saveSessions(list, srcs)
    end
end

--- Starts the autosave thread (idempotent; server/main.lua calls it once the migrations applied).
function Player.startAutosave()
    if autosaveRunning then return end
    autosaveRunning = true
    CreateThread(function()
        local interval = Config.Player.SaveIntervalMs
        while autosaveRunning do
            Wait(interval)
            if not autosaveRunning then break end
            autosaveTick()
        end
    end)
end

function Player.stopAutosave()
    autosaveRunning = false
end

-- start-up (session restore + autosave) is server/main.lua's, after Core.DB.awaitMigrations (§56.1)
AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    autosaveRunning = false -- synchronous only; server/main.lua owns the final saveAll (§4.9)
end)

Core.Player = Player
-- Player.getHealth/getArmour and the §5.2 'core:player:getInfo' callback live in server/getters.lua.
