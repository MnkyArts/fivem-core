--[[
    core/server/remote.lua — remote player control (DESIGN §20)

    Server-side half of `Core.Native`, `Core.Anim`, `Core.Audio`, `Core.Attachments`, `Core.Waypoint`,
    `Core.Raycast` and `Core.Screenshot`: a plugin calls these with a `src` and core forwards the work
    to that player's client (client/remote.lua), either fire-and-forget through `Core.Net.emit` or as a
    `Core.Callback.awaitClient` round trip (§3.5, `Config.CallbackTimeoutMs`).

    Native invocation is allow-listed here AND on the client: only the names in
    `Config.Native.Allow` (§28) may run, no list at all denies everything, and the hard DENY set
    below is refused on both sides whatever the config says.

    Attachments live on the character document (`data.attachments`) and are replicated as ONE table on
    `Player(src).state.attachments` (§8) — every client applies them to that player's ped.

    Natives (verified with fxref 2026-09-12): GetPlayerPed (apiset server, `playerSrc`),
    GetEntityCoords (apiset server, ONE argument), NetworkGetEntityFromNetworkId (apiset server),
    DoesEntityExist (client+server), GetResourceState (shared).
    `Player(src).state`, `promise`, `Citizen.Await`, `SetTimeout` and `exports` are runtime helpers.
]]

local Native = {}
local Anim = {}
local Audio = {}
local Attachments = {}
local Waypoint = {}
local Raycast = {}
local Screenshot = {}

local Log = Core.Log
local Net = Core.Net
local Utils = Core.Utils
local Callback = Core.Callback

local MAX_SRC <const> = 4096
local MAX_NAME_LEN <const> = 64
local MAX_ARGS <const> = 16               -- arguments forwarded to one native call
local NATIVE_PATTERN <const> = '^%u[%w_]+$'
local AUDIO_MAX_TARGETS <const> = 20      -- DESIGN §20: playAt never fans out further than this
local AUDIO_DEFAULT_RANGE <const> = 20.0
local AUDIO_MAX_RANGE <const> = 200.0
local MAX_ATTACHMENTS <const> = 12        -- bounds the replicated state-bag payload
local DEFAULT_BONE <const> = 28422        -- PH_R_Hand, the usual prop bone
local RAYCAST_MAX_DISTANCE <const> = 100.0
local RAYCAST_SLACK <const> = 5.0         -- the client's hit may sit slightly past the probe end
local MAX_NET_ID <const> = 65535
local SCREENSHOT_RES <const> = 'screenshot-basic'
local SCREENSHOT_TIMEOUT_MS <const> = 15000

local allowCache = { list = false, set = nil }     -- memoised Config.Native.Allow lookup
local screenshotPending = {}                       -- [src] = true while one request is in flight

--- Integer server id inside the sane range, or nil.
local function toSrc(value)
    if math.type(value) ~= 'integer' then
        if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
        value = math.floor(value)
    end
    if value < 1 or value > MAX_SRC then return nil end
    return value
end

--- Server id of a player with a loaded session, or nil (every §20 API needs one).
local function toLoaded(value)
    local src = toSrc(value)
    if not src or not Core.Player.isLoaded(src) then return nil end
    return src
end

--- vector3 from a vector3 or a { x, y, z } table, else nil. Every component has to be a
--- finite number: NaN/±inf survive tonumber() and would poison every distance check later.
local function toVector3(value)
    local x, y, z
    if type(value) == 'vector3' then
        x, y, z = value.x, value.y, value.z
    elseif type(value) == 'table' then
        x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
    else
        return nil
    end
    if not (Utils.isNumber(x) and Utils.isNumber(y) and Utils.isNumber(z)) then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

--------------------------------------------------------------------------------
-- Core.Native (DESIGN §20) — run a client native on one player
--------------------------------------------------------------------------------

--- Config.Native.Allow as a name -> true set. No list (or an empty one) means DENY everything:
--- a plugin may only run what the server operator listed in shared/config.lua (§28).
--- Memoised on the config table itself so a reload of core picks a new list up.
local function allowSet()
    local list = Config.Native and Config.Native.Allow
    if type(list) ~= 'table' then return nil end
    if allowCache.list == list then return allowCache.set end
    local set = {}
    for key, value in pairs(list) do
        if type(value) == 'string' then set[value] = true            -- array form { 'SetEntityHealth' }
        elseif value == true and type(key) == 'string' then set[key] = true end
    end
    allowCache.list, allowCache.set = list, set
    return set
end

--- Never runnable on a client, even when the operator put one of them in Config.Native.Allow:
--- these would let any resource run console commands, forge net events in the player's name, take
--- over the NUI, rewrite the KVP store or spawn loops.
--- client/remote.lua carries the same list and refuses them a second time.
local DENY <const> = {
    ExecuteCommand = true, TriggerServerEvent = true, TriggerClientEvent = true, TriggerEvent = true,
    TriggerLatentServerEvent = true, RegisterCommand = true, RegisterNetEvent = true,
    AddEventHandler = true, RemoveEventHandler = true, RegisterKeyMapping = true,
    LoadResourceFile = true, SendNuiMessage = true, SetNuiFocus = true, SetNuiFocusKeepInput = true,
    RegisterNuiCallback = true, SetResourceKvp = true, SetResourceKvpInt = true,
    SetResourceKvpFloat = true, SetResourceKvpNoSync = true, DeleteResourceKvp = true,
    DeleteResourceKvpNoSync = true, NetworkResurrectLocalPlayer = true, CreateThread = true,
    SetTimeout = true, Wait = true,
}

--- True when `name` is a well-formed native name the deny list and the config both permit.
--- A denied name is audited with the resource that asked for it (DESIGN §8 `audit` hook).
local function isAllowed(name, src)
    if type(name) ~= 'string' or #name > MAX_NAME_LEN or not name:match(NATIVE_PATTERN) then return false end
    if DENY[name] then
        Log.audit('native', src, 'resource %s tried to run denied native %s',
            tostring(Core.Registry.getCaller()), name)
        return false
    end
    local set = allowSet()
    return set ~= nil and set[name] == true
end

--- Argument list for one native call: a packed table (nils preserved), bounded length.
--- Returns nil when an argument cannot cross the wire safely.
local function packArgs(...)
    local args = table.pack(...)
    if args.n > MAX_ARGS then return nil end
    for i = 1, args.n do
        local t = type(args[i])
        if t == 'function' or t == 'thread' or t == 'userdata' then return nil end
        if t == 'table' then args[i] = Utils.jsonSafe(args[i]) end
    end
    return args
end

--- Fire-and-forget: the client calls `_G[name](...)` when the name is allowed there too.
--- @return boolean queued
function Native.invoke(src, name, ...)
    local target = toLoaded(src)
    if not target or not isAllowed(name, target) then
        Log.error('Native.invoke: refused %s for src %s', tostring(name), tostring(src))
        return false
    end
    local args = packArgs(...)
    if not args then
        Log.error('Native.invoke: %s has unsupported arguments', name)
        return false
    end
    Net.emit(target, 'core:client:native', name, args)
    return true
end

--- Same, but waits for the client's return values (nil on timeout, refusal or error).
function Native.invokeWithResult(src, name, ...)
    local target = toLoaded(src)
    if not target or not isAllowed(name, target) then
        Log.error('Native.invokeWithResult: refused %s for src %s', tostring(name), tostring(src))
        return nil
    end
    local args = packArgs(...)
    if not args then return nil end
    local result = Callback.awaitClient(target, 'core:native', name, args)
    if type(result) ~= 'table' then return nil end
    return table.unpack(result, 1, math.min(result.n or #result, MAX_ARGS))
end

--------------------------------------------------------------------------------
-- Core.Anim (DESIGN §20) — the client runs it through the Core.Anim lib (§3.10)
--------------------------------------------------------------------------------

local ANIM_NUMBERS <const> = { blendIn = true, blendOut = true, playbackRate = true }
local ANIM_INTEGERS <const> = { flags = true, duration = true, timeout = true }
local ANIM_BOOLS <const> = { lockX = true, lockY = true, lockZ = true }

--- Copy of the caller's options reduced to the fields Core.Anim.play understands.
local function animOpts(opts)
    if type(opts) ~= 'table' then return nil end
    local out = {}
    for key, value in pairs(opts) do
        if ANIM_NUMBERS[key] and type(value) == 'number' and value == value then
            out[key] = value + 0.0
        elseif ANIM_INTEGERS[key] and math.type(value) == 'integer' then
            out[key] = value
        elseif ANIM_BOOLS[key] and type(value) == 'boolean' then
            out[key] = value
        end
    end
    return out
end

--- Play `clip` from `dict` on the player's ped.
--- @return boolean queued
function Anim.play(src, dict, clip, opts)
    local target = toLoaded(src)
    if not target or not Utils.isString(dict, MAX_NAME_LEN) or not Utils.isString(clip, MAX_NAME_LEN) then
        Log.error('Anim.play: invalid arguments (%s, %s, %s)', tostring(src), tostring(dict), tostring(clip))
        return false
    end
    Net.emit(target, 'core:client:anim', 'play', dict, clip, animOpts(opts))
    return true
end

--- Stop whatever the player's ped is playing (ClearPedTasks on the client).
--- @return boolean queued
function Anim.stop(src)
    local target = toLoaded(src)
    if not target then return false end
    Net.emit(target, 'core:client:anim', 'stop')
    return true
end

--------------------------------------------------------------------------------
-- Core.Audio (DESIGN §20) — frontend sounds and world sounds
--------------------------------------------------------------------------------

--- Frontend (2D) sound for one player.
--- @return boolean queued
function Audio.playFrontend(src, name, set)
    local target = toLoaded(src)
    if not target or not Utils.isString(name, MAX_NAME_LEN) then
        Log.error('Audio.playFrontend: invalid arguments (%s, %s)', tostring(src), tostring(name))
        return false
    end
    if set ~= nil and not Utils.isString(set, MAX_NAME_LEN) then return false end
    Net.emit(target, 'core:client:audio', 'frontend', { name = name, set = set })
    return true
end

--- World sound at `coords`, sent to every loaded player within `range` (at most 20).
--- @return integer targets
function Audio.playAt(coords, name, set, range)
    local pos = toVector3(coords)
    if not pos or not Utils.isString(name, MAX_NAME_LEN) then
        Log.error('Audio.playAt: invalid arguments (%s)', tostring(name))
        return 0
    end
    if set ~= nil and not Utils.isString(set, MAX_NAME_LEN) then return 0 end
    local maxRange = tonumber(range) or AUDIO_DEFAULT_RANGE
    if maxRange ~= maxRange or maxRange <= 0.0 then maxRange = AUDIO_DEFAULT_RANGE end
    if maxRange > AUDIO_MAX_RANGE then maxRange = AUDIO_MAX_RANGE end

    local payload = { name = name, set = set, coords = Utils.vector3ToTable(pos), range = math.floor(maxRange) }
    local players = Core.Player.getPlayers()
    local sent = 0
    for i = 1, #players do
        if sent >= AUDIO_MAX_TARGETS then break end
        local ped = GetPlayerPed(players[i])
        if ped ~= 0 and #(GetEntityCoords(ped) - pos) <= maxRange then
            Net.emit(players[i], 'core:client:audio', 'at', payload)
            sent = sent + 1
        end
    end
    return sent
end

--------------------------------------------------------------------------------
-- Core.Attachments (DESIGN §20) — props on the player's ped
--   stored on the character document (data.attachments), replicated as ONE table
--   on Player(src).state.attachments; client/remote.lua attaches the objects.
--------------------------------------------------------------------------------

local ID_PATTERN <const> = '^[%w_%-:]+$'

--- The stored list (a copy, always an array), clamped to MAX_ATTACHMENTS. A document that grew
--- past the cap (older data, a manual DB edit) is trimmed here, so every write and every
--- republish sends a bounded table.
local function readList(src)
    local list = Core.Player.getData(src, 'attachments')
    if type(list) ~= 'table' then return {} end
    local out = {}
    for i = 1, #list do
        if type(list[i]) == 'table' then
            out[#out + 1] = list[i]
            if #out >= MAX_ATTACHMENTS then break end
        end
    end
    return out
end

--- Persist + replicate in one step (the whole table, §8).
local function writeList(src, list)
    Core.Player.setData(src, 'attachments', list)
    Player(src).state:set('attachments', list, true)
end

--- Validated, JSON-safe entry from a caller's definition, or nil, err.
local function toEntry(def, existingId)
    if type(def) ~= 'table' then return nil, 'definition must be a table' end
    local model = def.model
    if not (Utils.isString(model, MAX_NAME_LEN) or math.type(model) == 'integer') then
        return nil, 'model must be a model name or a hash'
    end
    local id = def.id
    if id ~= nil then
        if not Utils.isString(id, MAX_NAME_LEN) or not id:match(ID_PATTERN) then return nil, 'invalid id' end
    else
        id = existingId or Utils.uuid()
    end
    local bone = math.type(def.bone) == 'integer' and def.bone or DEFAULT_BONE
    local offset = toVector3(def.offset) or vector3(0.0, 0.0, 0.0)
    local rotation = toVector3(def.rotation) or vector3(0.0, 0.0, 0.0)
    return {
        id = id, model = model, bone = bone,
        offset = Utils.vector3ToTable(offset), rotation = Utils.vector3ToTable(rotation),
    }
end

--- Attach a prop. An existing entry with the same id is replaced.
--- @return string|nil id, string|nil err
function Attachments.add(src, def)
    local target = toLoaded(src)
    if not target then return nil, 'no session' end
    local entry, err = toEntry(def)
    if not entry then
        Log.error('Attachments.add: %s', tostring(err))
        return nil, err
    end
    local list = readList(target)
    for i = 1, #list do
        if list[i].id == entry.id then
            list[i] = entry
            writeList(target, list)
            return entry.id
        end
    end
    if #list >= MAX_ATTACHMENTS then return nil, 'too many attachments' end
    list[#list + 1] = entry
    writeList(target, list)
    return entry.id
end

--- @return boolean removed
function Attachments.remove(src, id)
    local target = toLoaded(src)
    if not target or not Utils.isString(id, MAX_NAME_LEN) then return false end
    local list = readList(target)
    for i = 1, #list do
        if list[i].id == id then
            table.remove(list, i)
            writeList(target, list)
            return true
        end
    end
    return false
end

--- @return boolean ok
function Attachments.clear(src)
    local target = toLoaded(src)
    if not target then return false end
    writeList(target, {})
    return true
end

--- @return table list a copy of the stored entries
function Attachments.list(src)
    local target = toLoaded(src)
    if not target then return {} end
    return readList(target)
end

-- Stored props have to reach the bag again when the character comes back: server/player.lua
-- only replicates the §8 keys, `attachments` is written here and nowhere else.
Core.on('playerLoaded', function(src)
    local target = toLoaded(src)
    if not target then return end
    local list = readList(target)
    if #list == 0 then return end
    Player(target).state:set('attachments', list, true)
end)

--------------------------------------------------------------------------------
-- Core.Waypoint / Core.Raycast (DESIGN §20) — the client owns both, we ask it
--------------------------------------------------------------------------------

--- Set the player's personal waypoint.
--- @return boolean queued
function Waypoint.set(src, coords)
    local target = toLoaded(src)
    local pos = toVector3(coords)
    if not target or not pos then
        Log.error('Waypoint.set: invalid arguments (%s)', tostring(src))
        return false
    end
    Net.emit(target, 'core:client:waypoint', 'set', pos)
    return true
end

--- @return boolean queued
function Waypoint.clear(src)
    local target = toLoaded(src)
    if not target then return false end
    Net.emit(target, 'core:client:waypoint', 'clear')
    return true
end

--- The player's current waypoint, or nil when there is none / the client did not answer.
--- @return vector3|nil
function Waypoint.get(src)
    local target = toLoaded(src)
    if not target then return nil end
    return toVector3(Callback.awaitClient(target, 'core:waypoint:get'))
end

--- Shape test out of the player's camera.
--- @return boolean hit, vector3|nil coords, integer entityNetId 0 when nothing networked was hit
function Raycast.fromPlayer(src, distance)
    local target = toLoaded(src)
    if not target then return false, nil, 0 end
    local dist = tonumber(distance) or 10.0
    if dist ~= dist or dist <= 0.0 then dist = 10.0 end
    if dist > RAYCAST_MAX_DISTANCE then dist = RAYCAST_MAX_DISTANCE end

    local result = Callback.awaitClient(target, 'core:raycast', dist + 0.0)
    if type(result) ~= 'table' or result.hit ~= true then return false, nil, 0 end

    -- The answer comes from the client, so none of it is fact yet: the coordinates have to be
    -- finite and plausibly in front of that player, and the net id has to resolve to an entity
    -- the server itself knows (§14.12) — otherwise the hit is dropped entirely.
    local coords = toVector3(result.coords)
    if not coords then return false, nil, 0 end
    local ped = GetPlayerPed(target)
    if ped == 0 or #(coords - GetEntityCoords(ped)) > dist + RAYCAST_SLACK then return false, nil, 0 end

    local netId = 0
    if math.type(result.netId) == 'integer' and result.netId > 0 and result.netId <= MAX_NET_ID then
        local entity = NetworkGetEntityFromNetworkId(result.netId)
        if entity ~= 0 and DoesEntityExist(entity) then netId = result.netId end
    end
    return true, coords, netId
end

--------------------------------------------------------------------------------
-- Core.Screenshot (DESIGN §20) — optional, needs the screenshot-basic resource
--------------------------------------------------------------------------------

local SCREENSHOT_ENCODINGS <const> = { jpg = true, png = true, webp = true }

--- Only the two options a plugin may steer. `fileName` is deliberately not forwarded:
--- it makes screenshot-basic write anywhere on the server's disk.
local function screenshotOptions(opts)
    local out = { encoding = 'jpg' }
    if type(opts) ~= 'table' then return out end
    if type(opts.encoding) == 'string' and SCREENSHOT_ENCODINGS[opts.encoding] then
        out.encoding = opts.encoding
    end
    local quality = tonumber(opts.quality)
    if quality and quality == quality then out.quality = Utils.clamp(quality, 0.1, 1.0) end
    return out
end

--- Ask the player's client for a screenshot. Returns the data URL screenshot-basic produced,
--- or nil plus a reason ('unavailable', 'busy', 'timeout', 'failed').
--- @return string|nil url, string|nil err
function Screenshot.take(src, opts)
    local target = toLoaded(src)
    if not target then return nil, 'unavailable' end
    if GetResourceState(SCREENSHOT_RES) ~= 'started' then return nil, 'unavailable' end
    if screenshotPending[target] then return nil, 'busy' end

    screenshotPending[target] = true
    local p = promise.new()
    local settled = false
    local function settle(url, err)
        if settled then return end
        settled = true
        screenshotPending[target] = nil
        p:resolve({ url = url, err = err })
    end

    -- screenshot-basic is optional, so the export is resolved inside a pcall: a missing export
    -- raises instead of returning nil, and the resource may still be starting up.
    local ok, err = pcall(function()
        exports[SCREENSHOT_RES]:requestClientScreenshot(target, screenshotOptions(opts), function(failed, data)
            if failed or type(data) ~= 'string' then return settle(nil, 'failed') end
            settle(data)
        end)
    end)
    if not ok then
        Log.warn('Screenshot.take: %s export failed (%s)', SCREENSHOT_RES, tostring(err))
        settle(nil, 'unavailable')
    end
    SetTimeout(SCREENSHOT_TIMEOUT_MS, function() settle(nil, 'timeout') end)

    local result = Citizen.Await(p)
    return result.url, result.err
end

AddEventHandler('playerDropped', function()
    local src = source
    screenshotPending[src] = nil
end)

Core.Native = Native
Core.Anim = Anim
Core.Audio = Audio
Core.Attachments = Attachments
Core.Waypoint = Waypoint
Core.Raycast = Raycast
Core.Screenshot = Screenshot

-- end of file
