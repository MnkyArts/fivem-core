--[[
    core/server/player.lua — Core.Player (DESIGN §4.2, §5, §8)

    Sessions and persistence: account + character documents (Core.DB), the connection lifecycle
    (playerConnecting deferrals + ban check, playerJoining load, core:server:requestLoad answer),
    the autosave loop, death/respawn, and the replication of the §8 player state-bag keys through
    the single replicate(src, key?) helper.

    Plugins must never write the `characters` / `accounts` collections directly while a session
    exists: Player.save rewrites both documents from the live session, so a direct Core.DB write is
    lost at the next autosave. Use Core.Player.setData (and Core.Money / Core.Player.setGroup).

    Core owns the §8 player state-bag keys (CORE_STATE_KEYS below); plugin keys go through
    Player.setReplicated. Server side only: every native used here is apiset server or client+server.
]]

-- runtime Player(src) state-bag accessor, captured before the module table shadows the global
local playerBag = Player

local Player = {}

local Log = Core.Log
local Utils = Core.Utils
local Net = Core.Net

local sessions = {}      -- [src] = session table (see DESIGN §4.2)
local byCharId = {}      -- [charId] = src
local loadCooldown = {}  -- [src] = GetGameTimer() of the last requestLoad
local autosaveRunning = false

local MAX_BUCKET <const> = 65535
local LOAD_WAIT_MS <const> = 10000
local LOAD_POLL_MS <const> = 250
local ID_TYPES <const> = { 'license', 'discord', 'fivem', 'steam' }

-- character keys that mirror into the player state bag (§8)
local REPLICATED <const> = { name = true, money = true, faction = true }

-- player state-bag keys core writes itself (§8, §18, §20); plugins may not take them over
local CORE_STATE_KEYS <const> = {
    loaded = true, name = true, charId = true, group = true, cash = true, bank = true,
    faction = true, dead = true, stats = true, attachments = true,
}

--- Sanitized display name for a connected player.
local function playerName(src)
    return Utils.sanitize(GetPlayerName(src) or 'Unknown', Config.Player.MaxNameLength)
end

--- Collects the identifier set stored on the account document.
local function collectIdentifiers(src)
    local out = {}
    for i = 1, #ID_TYPES do
        local kind = ID_TYPES[i]
        local value = GetPlayerIdentifierByType(src, kind)
        if type(value) == 'string' and value ~= '' then out[kind] = value end
    end
    return out
end

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

--- Marks the session dirty and drops the cached core:client:loaded payload (§5 requestLoad).
local function touch(session)
    session.dirty = true
    session.loadPayload = nil
end

--- Refreshes data.position from the live ped (skipped while dead or without a ped).
local function refreshPosition(session)
    if session.deadSince then return end
    local ped = GetPlayerPed(session.src)
    if ped == 0 then return end
    local coords = GetEntityCoords(ped)
    if coords.x == 0.0 and coords.y == 0.0 and coords.z == 0.0 then return end
    session.data.position = {
        x = coords.x, y = coords.y, z = coords.z, heading = GetEntityHeading(ped) + 0.0,
    }
    touch(session)
end

--- Adds the seconds elapsed since the last accounting tick to the character and account playtime.
local function addPlaytime(session)
    local now = os.time()
    local elapsed = now - (session.playtimeAt or now)
    if elapsed <= 0 then
        session.playtimeAt = now
        return
    end
    session.playtimeAt = now
    local stats = session.data.stats
    if type(stats) ~= 'table' then
        stats = { deaths = 0, playtime = 0 }
        session.data.stats = stats
    end
    stats.playtime = (stats.playtime or 0) + elapsed
    session.account.playtime = (session.account.playtime or 0) + elapsed
    touch(session)
end

--- Default character document for a brand new account (§4.2, §10 Config.Player.NewCharacter).
local function newCharacterDoc(account)
    local spawn = Config.Player.SpawnPoint
    local defaults = Config.Player.NewCharacter or {}
    return {
        accountId = account.id,
        name = account.name,
        model = Config.Player.DefaultModel,
        appearance = {},
        position = {
            x = spawn.coords.x, y = spawn.coords.y, z = spawn.coords.z, heading = spawn.heading + 0.0,
        },
        money = Utils.deepCopy(defaults.money or { cash = 0, bank = 0 }),
        stats = { deaths = 0, playtime = 0 },
        meta = {},
    }
end

--- Finds or creates the account + character documents and builds the in-memory session.
--- fresh = true for a real join (the client should spawn), false when core restarted under a
--- player who is already in the world.
local function loadSession(src, fresh)
    local existing = sessions[src]
    if existing then return existing end

    local license = GetPlayerIdentifierByType(src, 'license')
    if type(license) ~= 'string' or license == '' then
        DropPlayer(src, 'No license identifier.')
        return nil
    end

    local db = Core.DB
    local name = playerName(src)
    local account = db.findOne('accounts', { license = license })
    if not account then
        local accountId = db.create('accounts', {
            license = license, identifiers = collectIdentifiers(src), name = name, group = 'user',
            firstSeen = os.time(), lastSeen = os.time(), playtime = 0, banned = false,
        })
        account = accountId and db.get('accounts', accountId)
    end
    if not account then
        Log.error('could not load or create an account for [%d] %s', src, name)
        return nil
    end
    local function stampAccount(doc)
        doc.name = name
        doc.lastSeen = os.time()
        doc.identifiers = collectIdentifiers(src)
        return doc
    end
    stampAccount(account)

    local character = db.findOne('characters', { accountId = account.id })
    if not character then
        local charId = db.create('characters', newCharacterDoc(account))
        character = charId and db.get('characters', charId)
    end
    if not character then
        Log.error('could not load or create a character for [%d] %s', src, name)
        return nil
    end

    -- Unclean disconnect + reconnect before the server noticed the drop: the character is still
    -- bound to an older src. That ghost session holds the newest state, so persist it, release it
    -- and re-read both documents -- otherwise its next save would overwrite this one with stale
    -- data and its playerDropped would clear byCharId for the live src.
    local ghostSrc = byCharId[character.id]
    local ghost = ghostSrc and ghostSrc ~= src and sessions[ghostSrc] or nil
    if ghost then
        Log.warn('character %s was still bound to [%d]; handing it to [%d]', character.id, ghostSrc, src)
        Player.save(ghostSrc)
        sessions[ghostSrc] = nil
        loadCooldown[ghostSrc] = nil
        byCharId[ghost.charId] = nil
        character = db.get('characters', character.id) or character
        account = stampAccount(db.get('accounts', account.id) or account)
    end

    local now = os.time()
    local session = {
        src = src, accountId = account.id, charId = character.id, license = license,
        name = character.name or name, account = account, data = character,
        dirty = true, loadedAt = now, playtimeAt = now, deadSince = nil,
        fresh = fresh and true or false, answered = false,
    }
    sessions[src] = session
    byCharId[character.id] = src
    replicate(src)
    Log.info('session ready for [%d] %s (character %s)', src, session.name, character.id)
    return session
end

AddEventHandler('playerConnecting', function(_, _, deferrals)
    local src = source
    deferrals.defer()
    Wait(0) -- required: at least one tick between defer() and update()/done()
    deferrals.update(Config.Texts.loading or 'Checking your account...')

    local license = GetPlayerIdentifierByType(src, 'license')
    if type(license) ~= 'string' or license == '' then
        return deferrals.done('No license identifier — restart FiveM and reconnect.')
    end

    local now = os.time()
    local ban = Core.DB.findOne('bans', function(doc)
        local expiry = doc['until'] or 0
        return doc.license == license and (expiry == 0 or expiry > now)
    end)
    if ban then
        local expiry = ban['until'] or 0
        local reason = Utils.sanitize(ban.reason or 'No reason given', 128)
        if expiry == 0 then
            return deferrals.done(('You are permanently banned. Reason: %s'):format(reason))
        end
        return deferrals.done(('You are banned until %s. Reason: %s')
            :format(os.date('%Y-%m-%d %H:%M', expiry), reason))
    end

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
    if not session then return end
    refreshPosition(session)
    addPlaytime(session)
    Core.emitHook('playerDropped', src, session.charId)
    Player.save(src)
    -- only when this src still owns the character: a fast reconnect may have re-bound it already
    if byCharId[session.charId] == src then byCharId[session.charId] = nil end
    sessions[src] = nil
end)

-- ---------------------------------------------------------------------------
-- API (DESIGN §4.2) — every function returns nil/false without a loaded session
-- ---------------------------------------------------------------------------

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
    if type(value) == 'table' then return Utils.deepCopy(value) end
    return value
end

function Player.setData(src, path, value)
    local session = sessions[src]
    if not session then return false end
    local node, key = resolvePath(session.data, path, true)
    if not node or key == nil then return false end
    if type(value) == 'table' then value = Utils.jsonSafe(value) end
    node[key] = value
    touch(session)
    local top = path:match('^[^%.]+')
    if top == 'name' and type(session.data.name) == 'string' then session.name = session.data.name end
    if REPLICATED[top] then replicate(src, top) end
    local changed = session.data[top]
    Core.emitHook('playerDataChanged', src, top,
        type(changed) == 'table' and Utils.deepCopy(changed) or changed)
    return true
end

function Player.save(src)
    local session = sessions[src]
    if not session then return false end
    addPlaytime(session)
    local db = Core.DB
    db.set('characters', session.charId, session.data)
    db.set('accounts', session.accountId, session.account)
    session.dirty = false
    Core.emitHook('playerSaved', src)
    return true
end

function Player.saveAll()
    local count = 0
    for src in pairs(sessions) do
        if Player.save(src) then count = count + 1 end
    end
    return count
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

function Player.getName(src)
    local session = sessions[src]
    return session and session.name or nil
end

function Player.getLicense(src)
    local session = sessions[src]
    return session and session.license or nil
end

function Player.getPed(src)
    if not sessions[src] then return 0 end
    return GetPlayerPed(src) or 0
end

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

function Player.setCoords(src, coords, heading)
    local session = sessions[src]
    if not session then return false end
    local target = toVector3(coords)
    if not target then return false end
    local stored = session.data.position or {}
    local dir = Utils.isNumber(heading) and heading + 0.0 or (stored.heading or 0.0) + 0.0
    session.data.position = { x = target.x, y = target.y, z = target.z, heading = dir }
    touch(session)
    TriggerClientEvent('core:client:teleport', src, target, dir)
    return true
end

function Player.setModel(src, model, appearance)
    local session = sessions[src]
    if not session then return false end
    if not Utils.isString(model, 64) then return false end
    session.data.model = model
    if type(appearance) == 'table' then session.data.appearance = Utils.jsonSafe(appearance) end
    touch(session)
    TriggerClientEvent('core:client:setModel', src, model, session.data.appearance or {})
    -- Same hook `setData` emits (§22), so a plugin that mirrors the look (the inventory's clothing slots)
    -- learns about a creator save without the creator knowing it exists (2026-09-13, for `inventory`).
    Core.emitHook('playerDataChanged', src, 'model', model)
    if type(appearance) == 'table' then
        Core.emitHook('playerDataChanged', src, 'appearance', Utils.deepCopy(session.data.appearance))
    end
    return true
end

function Player.setBucket(src, bucket)
    if not sessions[src] then return false end
    if math.type(bucket) ~= 'integer' or bucket < 0 or bucket > MAX_BUCKET then return false end
    SetPlayerRoutingBucket(src, bucket)
    return true
end

function Player.getBucket(src)
    if not sessions[src] then return 0 end
    return GetPlayerRoutingBucket(src) or 0
end

--- Changes the account group. Core.Perms.setGroup routes through this so the live session, the
--- account document and the state bag never disagree.
function Player.setGroup(src, group)
    local session = sessions[src]
    if not session then return false end
    if type(group) ~= 'string' or Config.Perms.Groups[group] == nil then return false end
    session.account.group = group
    touch(session)
    if not Core.DB.update('accounts', session.accountId, { group = group }) then
        Log.warn('could not persist the group change for [%d]', src)
    end
    replicate(src, 'group')
    Log.audit('player', src, 'group set to %s', group)
    return true
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

--- Writes one field on the live account document and persists it (§22; perms.lua stores
--- account.permissions through this). 'group' is routed through setGroup so the bag stays in sync.
function Player.setAccountData(src, key, value)
    local session = sessions[src]
    if not session then return false end
    if not Utils.isString(key, 64) then return false end
    if key == 'group' then return Player.setGroup(src, value) end
    if key == 'id' or key == 'license' then return false end
    if type(value) == 'table' then value = Utils.jsonSafe(value) end
    session.account[key] = value
    touch(session)
    if not Core.DB.update('accounts', session.accountId, { [key] = value }) then
        Log.warn('could not persist the account field %s for [%d]', key, src)
    end
    return true
end

--- One targeted core:client:playerState event carrying only the field that changed (§17).
local function sendPlayerState(src, partial)
    if not sessions[src] then return false end
    TriggerClientEvent('core:client:playerState', src, partial)
    return true
end

function Player.setControls(src, enabled)
    if type(enabled) ~= 'boolean' then return false end
    return sendPlayerState(src, { controls = enabled })
end

function Player.setFrozen(src, frozen)
    if type(frozen) ~= 'boolean' then return false end
    return sendPlayerState(src, { frozen = frozen })
end

function Player.setInvincible(src, invincible)
    if type(invincible) ~= 'boolean' then return false end
    return sendPlayerState(src, { invincible = invincible })
end

function Player.setVisible(src, visible)
    if type(visible) ~= 'boolean' then return false end
    return sendPlayerState(src, { visible = visible })
end

function Player.setHealth(src, hp)
    if math.type(hp) ~= 'integer' or hp < 0 or hp > 200 then return false end
    return sendPlayerState(src, { health = hp })
end

function Player.setArmour(src, ap)
    if math.type(ap) ~= 'integer' or ap < 0 or ap > 100 then return false end
    return sendPlayerState(src, { armour = ap })
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
    local license = Player.getLicense(src) or GetPlayerIdentifierByType(src, 'license')
    if type(license) ~= 'string' or license == '' then return false end
    local text = Utils.sanitize(reason or 'Banned', 128)
    local expiry = 0
    if math.type(seconds) == 'integer' and seconds > 0 then expiry = os.time() + seconds end
    Core.DB.create('bans', {
        license = license, reason = text, by = Utils.sanitize(by or 'console', 64), ['until'] = expiry,
    })
    local session = sessions[src]
    if session then
        session.account.banned = true
        touch(session)
        Player.save(src)
    end
    local notice
    if expiry == 0 then
        Log.audit('player', src, 'banned permanently: %s', text)
        notice = ('You are permanently banned. Reason: %s'):format(text)
    else
        Log.audit('player', src, 'banned for %d s: %s', seconds, text)
        notice = ('You are banned until %s. Reason: %s')
            :format(os.date('%Y-%m-%d %H:%M', expiry), text)
    end
    DropPlayer(src, notice)
    return true
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

--- Builds the session for an already-connected player (core restart; DESIGN §4.2 step 2).
function Player.loadSession(src)
    return loadSession(src, false) ~= nil
end

--- Loads a session for every connected player that has none yet (called by server/main.lua).
function Player.loadAllConnected()
    local players = GetPlayers()
    for i = 1, #players do
        local src = tonumber(players[i])
        if src and not sessions[src] then loadSession(src, false) end
    end
end

-- ---------------------------------------------------------------------------
-- Net events (DESIGN §5) and the autosave loop
-- ---------------------------------------------------------------------------

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

    -- built once per session, invalidated by touch()/replicate(); the client re-requests after a
    -- core restart, so repeat requests are answered from the cache
    local payload = session.loadPayload
    if not payload then
        local data = session.data
        payload = {
            charId = session.charId,
            name = session.name,
            model = data.model or Config.Player.DefaultModel,
            appearance = Utils.deepCopy(data.appearance or {}),
            position = Utils.deepCopy(data.position or {}),
            money = Utils.deepCopy(data.money or {}),
            faction = factionSummary(src),
            group = session.account.group or 'user',
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

--- One autosave pass: refresh position + playtime, then persist the dirty sessions.
local function autosaveTick()
    for src, session in pairs(sessions) do
        refreshPosition(session)
        addPlaytime(session)
        if session.dirty then Player.save(src) end
    end
end

--- Starts the autosave thread (idempotent; server/main.lua calls this on start).
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

AddEventHandler('onResourceStart', function(resource)
    if resource ~= Core.name then return end
    Player.loadAllConnected()
    Player.startAutosave()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    autosaveRunning = false -- synchronous only; server/main.lua owns the final saveAll (§4.9)
end)

Core.Player = Player

-- DESIGN §5.2: the player's own info + money. The license stays server-side on purpose, so this
-- projects getInfo() instead of forwarding it.
Core.Callback.register('core:player:getInfo', function(src)
    local info = Player.getInfo(src)
    if not info then return nil end
    local money = Player.getData(src, 'money')
    if type(money) ~= 'table' then money = {} end
    return {
        src = info.src,
        charId = info.charId,
        accountId = info.accountId,
        name = info.name,
        group = info.group,
        money = { cash = money.cash or 0, bank = money.bank or 0 },
    }
end)
