--[[
    core/client/remote.lua — client half of the remote player control APIs (DESIGN §20)

    Receives what server/remote.lua sends:
      * `core:client:native (name, args)` + callback `core:native`  -> `_G[name](...)`, checked a
        second time here against Config.Native.Allow (§28) and against core's hard deny list,
      * `core:client:anim (op, dict, clip, opts)`                   -> Core.Anim (§3.10),
      * `core:client:audio (op, data)`                              -> Core.Audio (lib/audio/client.lua),
      * `core:client:waypoint (op, coords)` + callback `core:waypoint:get` -> Core.Blips (§6.6),
      * callback `core:raycast (distance)`                          -> Core.Raycast (§6.9).

    It also owns the attachments applier: EVERY client attaches the props listed on
    `Player(<serverId>).state.attachments` to that player's ped — driven by the state-bag change
    handler for new values and by a 2000 ms sweep for peds that only just streamed in. The objects
    are local (`CreateObject(model, x, y, z, false, false, false)`), never networked, and are deleted
    when the entry disappears, the player leaves or the resource stops.

    Natives (verified with fxref 2026-09-12, apiset client unless noted): CreateObject,
    AttachEntityToEntity, DeleteEntity (client+server), GetPedBoneIndex, PlayerPedId, GetPlayerPed
    (client+server), GetPlayerFromServerId, GetPlayerServerId, GetActivePlayers, DoesEntityExist
    (client+server), NetworkGetEntityIsNetworked, NetworkGetNetworkIdFromEntity (client+server),
    AddStateBagChangeHandler (shared).
]]

local Net = Core.Net
local Log = Core.Log
local Utils = Core.Utils
local Callback = Core.Callback

local MAX_NAME_LEN <const> = 64
local MAX_ARGS <const> = 16
local NATIVE_PATTERN <const> = '^%u[%w_]+$'
local SWEEP_INTERVAL_MS <const> = 2000

local allowCache = { list = false, set = nil }
local audioWarned = false

--------------------------------------------------------------------------------
-- Core.Native (DESIGN §20) — the client-side allowlist and the two entry points
--------------------------------------------------------------------------------

--- Config.Native.Allow as a set (Core.Config, §2.0 — core's own config in this VM).
--- No list means DENY everything: only what the operator listed in shared/config.lua may run.
local function allowSet()
    local list = Core.Config.Native and Core.Config.Native.Allow
    if type(list) ~= 'table' then return nil end
    if allowCache.list == list then return allowCache.set end
    local set = {}
    for key, value in pairs(list) do
        if type(value) == 'string' then set[value] = true
        elseif value == true and type(key) == 'string' then set[key] = true end
    end
    allowCache.list, allowCache.set = list, set
    return set
end

-- The same hard deny list server/remote.lua enforces, checked here a second time so a wrong
-- Config.Native.Allow entry (or a server that skipped the check) still cannot run these.
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

--- Run one allow-listed global. Returns the packed return values, or nil when it was refused.
local function runNative(name, args)
    if type(name) ~= 'string' or #name > MAX_NAME_LEN or not name:match(NATIVE_PATTERN) then return nil end
    if DENY[name] then
        Log.error('native %s is on core\'s deny list and is never run', name)
        return nil
    end
    local set = allowSet()
    if set == nil or not set[name] then
        Log.debug('native %s is not in Config.Native.Allow', name)
        return nil
    end
    local fn = _G[name]
    if type(fn) ~= 'function' then
        Log.debug('native %s does not exist in this VM', name)
        return nil
    end
    local count = math.type(args.n) == 'integer' and args.n or #args
    if count < 0 or count > MAX_ARGS then return nil end

    local returned = table.pack(pcall(fn, table.unpack(args, 1, count)))
    if not returned[1] then
        Log.error('native %s errored: %s', name, tostring(returned[2]))
        return nil
    end
    local out = { n = returned.n - 1 }
    for i = 2, returned.n do out[i - 1] = returned[i] end
    return out
end

Net.on('core:client:native', { { 'string', max = MAX_NAME_LEN }, 'table' }, function(name, args)
    runNative(name, args)
end)

Callback.register('core:native', { { 'string', max = MAX_NAME_LEN }, 'table' }, function(name, args)
    return runNative(name, args)
end)

--------------------------------------------------------------------------------
-- Anim / Audio / Waypoint / Raycast
--------------------------------------------------------------------------------

Net.on('core:client:anim', { { 'enum', values = { 'play', 'stop' } }, 'string?', 'string?', 'table?' },
    function(op, dict, clip, opts)
        local ped = PlayerPedId()
        if op == 'stop' then
            Core.Anim.stop(ped)
            return
        end
        if type(dict) ~= 'string' or type(clip) ~= 'string' then return end
        Core.Anim.play(ped, dict, clip, opts)
    end)

--- Core.Audio comes from lib/audio/client.lua, loaded on first access like every other lib (§2.1).
local function audioLib()
    local audio = Core.Audio
    if type(audio) == 'table' and type(audio.playFrontend) == 'function' then return audio end
    if not audioWarned then
        audioWarned = true
        Log.error("Core.Audio is unavailable — import.lua's LIB_MODULES needs `Audio = 'audio'`")
    end
    return nil
end

Net.on('core:client:audio', { { 'enum', values = { 'frontend', 'at' } }, 'table' }, function(op, data)
    local audio = audioLib()
    if not audio or type(data.name) ~= 'string' then return end
    if op == 'frontend' then
        audio.playFrontend(data.name, data.set)
        return
    end
    audio.playAt(data.coords, data.name, data.set, data.range)
end)

Net.on('core:client:waypoint', { { 'enum', values = { 'set', 'clear' } }, 'vector3?' }, function(op, coords)
    if op == 'clear' then
        Core.Blips.clearWaypoint()
        return
    end
    if coords then Core.Blips.setWaypoint(coords) end
end)

Callback.register('core:waypoint:get', function()
    local coords = Core.Blips.getWaypoint()
    return coords and Utils.vector3ToTable(coords) or nil
end)

Callback.register('core:raycast', { 'number' }, function(distance)
    local hit, coords, _, entity = Core.Raycast.fromCamera(distance)
    local netId = 0
    if entity and entity ~= 0 and DoesEntityExist(entity) and NetworkGetEntityIsNetworked(entity) then
        netId = NetworkGetNetworkIdFromEntity(entity)
    end
    return { hit = hit == true, coords = coords and Utils.vector3ToTable(coords) or nil, netId = netId }
end)

--------------------------------------------------------------------------------
-- Core.Attachments applier (DESIGN §20) — props on every streamed-in player ped
--   `Player(<serverId>).state.attachments` is written by the server (§8); this client
--   mirrors it into local objects. State-bag change = immediate, sweep = catch-up.
--------------------------------------------------------------------------------

local DEFAULT_BONE <const> = 28422       -- PH_R_Hand, matches server/remote.lua
local MAX_ATTACHMENTS <const> = 12       -- matches server/remote.lua; the list is clamped here too
local MAX_MODEL_LEN <const> = 64

local attached = {}        -- [serverId] = { [attachmentId] = { object, sig, ped } }
local applying = {}        -- [serverId] = true while an apply is running (it yields on the model)
local hasAttachments = {}  -- [serverId] = true while that player's bag holds a non-empty list
local stopping = false

--- Finite x/y/z of an offset (vector3, { x, y, z } or nil = origin), or nil when anything is off.
local function xyz(value)
    if value == nil then return 0.0, 0.0, 0.0 end
    local x, y, z
    if type(value) == 'vector3' then
        x, y, z = value.x, value.y, value.z
    elseif type(value) == 'table' then
        x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
    else
        return nil
    end
    if not (Utils.isNumber(x) and Utils.isNumber(y) and Utils.isNumber(z)) then return nil end
    return x + 0.0, y + 0.0, z + 0.0
end

--- One validated entry of the replicated table, or nil. Nothing is created from a value that did
--- not pass through here: the bag is server-written, but a stale document can still hold junk.
local function toEntry(value)
    if type(value) ~= 'table' then return nil end
    local id = value.id
    if type(id) ~= 'string' or id == '' or #id > MAX_NAME_LEN then return nil end
    local model = value.model
    if type(model) == 'string' then
        if model == '' or #model > MAX_MODEL_LEN then return nil end
    elseif math.type(model) ~= 'integer' then
        return nil
    end
    if value.bone ~= nil and math.type(value.bone) ~= 'integer' then return nil end
    local ox, oy, oz = xyz(value.offset)
    local rx, ry, rz = xyz(value.rotation)
    if not ox or not rx then return nil end
    return {
        id = id, model = model, bone = value.bone or DEFAULT_BONE,
        ox = ox, oy = oy, oz = oz, rx = rx, ry = ry, rz = rz,
    }
end

--- What the object was built from: a changed signature means recreate it.
local function signature(entry)
    return ('%s|%d|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f'):format(tostring(entry.model), entry.bone,
        entry.ox, entry.oy, entry.oz, entry.rx, entry.ry, entry.rz)
end

local function destroyObject(object)
    if object and object ~= 0 and DoesEntityExist(object) then DeleteEntity(object) end
end

--- Drop every object we hold for one player, and let a new apply run for them.
local function detachAll(serverId)
    applying[serverId] = nil
    local records = attached[serverId]
    if not records then return end
    attached[serverId] = nil
    for _, record in pairs(records) do destroyObject(record.object) end
end

--- Create one prop and pin it to the ped's bone. Returns the object handle, or 0.
local function createProp(ped, entry)
    if not Core.Streaming.requestModel(entry.model) then return 0 end

    local coords = GetEntityCoords(ped, false)
    local object = CreateObject(entry.model, coords.x, coords.y, coords.z, false, false, false)
    Core.Streaming.releaseModel(entry.model)
    if object == 0 or not DoesEntityExist(object) then return 0 end

    AttachEntityToEntity(object, ped, GetPedBoneIndex(ped, entry.bone),
        entry.ox, entry.oy, entry.oz, entry.rx, entry.ry, entry.rz,
        true, true, false, true, 1, true, 0)
    return object
end

--- One apply pass; only ever called through applyFor (which owns the `applying` flag).
local function applyEntries(serverId, ped, list)
    local records = attached[serverId]
    if not records then
        records = {}
        attached[serverId] = records
    end

    local wanted = {}
    local count = #list
    if count > MAX_ATTACHMENTS then count = MAX_ATTACHMENTS end
    for i = 1, count do
        local entry = toEntry(list[i])
        if entry then
            wanted[entry.id] = true
            local sig = signature(entry)
            local record = records[entry.id]
            if record and (record.sig ~= sig or record.ped ~= ped or not DoesEntityExist(record.object)) then
                destroyObject(record.object)
                records[entry.id] = nil
                record = nil
            end
            if not record then
                local object = createProp(ped, entry)   -- may yield while the model streams in
                if object ~= 0 then records[entry.id] = { object = object, sig = sig, ped = ped } end
            end
        end
    end
    for id, record in pairs(records) do
        if not wanted[id] then
            destroyObject(record.object)
            records[id] = nil
        end
    end
end

--- Bring one player's props in line with their replicated table. The pass runs inside a pcall:
--- a failing native must not leave `applying` set, or that player would never update again.
local function applyFor(serverId)
    if stopping or applying[serverId] then return end
    local playerIdx = GetPlayerFromServerId(serverId)
    if playerIdx == -1 then                      -- gone, or simply out of scope: the bag comes back
        hasAttachments[serverId] = nil           -- (and fires the change handler) when they return
        return detachAll(serverId)
    end
    local ped = GetPlayerPed(playerIdx)
    if ped == 0 or not DoesEntityExist(ped) then return detachAll(serverId) end

    local list = Player(serverId).state.attachments   -- one state read (§4), the whole table
    if type(list) ~= 'table' or #list == 0 then
        hasAttachments[serverId] = nil
        return detachAll(serverId)
    end

    applying[serverId] = true
    local ok, err = pcall(applyEntries, serverId, ped, list)
    applying[serverId] = nil
    if not ok then Log.error('attachments: apply failed for player %s (%s)', serverId, tostring(err)) end
end

--- applyFor yields (model streaming) and may fail; never let either escape into a handler.
local function applySafe(serverId)
    local ok, err = pcall(applyFor, serverId)
    if not ok then Log.error('attachments: %s', tostring(err)) end
end

-- The bag name carries the server id (`player:<id>`). It is parsed instead of resolved with
-- GetPlayerFromStateBagName because that native returns a player *handle* on the client, and
-- handle 0 is a valid player — so the usual "0 means gone" check would not hold here.
AddStateBagChangeHandler('attachments', nil, function(bagName, _, value)
    if stopping or (value ~= nil and type(value) ~= 'table') then return end
    local serverId = tonumber(tostring(bagName):match('^player:(%d+)$'))
    if not serverId then return end
    hasAttachments[serverId] = (type(value) == 'table' and #value > 0) or nil
    SetTimeout(0, function() applySafe(serverId) end)   -- a bag handler must not yield
end)

-- Catch-up sweep: peds stream in and out without the bag changing, and a respawn gives the player
-- a new ped handle. Only players known to carry props (from the change handler) and players we
-- still hold objects for are visited — no bag read per active player.
CreateThread(function()
    -- One seeding pass: bags that were already replicated before this script registered its
    -- handler (a core restart mid-session) never fire a change, so they are read once here.
    local players = GetActivePlayers()
    for i = 1, #players do
        local serverId = GetPlayerServerId(players[i])
        if serverId and serverId > 0 then
            local list = Player(serverId).state.attachments
            if type(list) == 'table' and #list > 0 then hasAttachments[serverId] = true end
        end
    end

    local ids = {}
    while not stopping do
        for id in pairs(ids) do ids[id] = nil end
        for serverId in pairs(hasAttachments) do ids[serverId] = true end
        for serverId in pairs(attached) do ids[serverId] = true end
        for serverId in pairs(ids) do applySafe(serverId) end
        Wait(SWEEP_INTERVAL_MS)
    end
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= Core.name then return end
    stopping = true
    for serverId in pairs(attached) do detachAll(serverId) end
    for serverId in pairs(applying) do applying[serverId] = nil end
    for serverId in pairs(hasAttachments) do hasAttachments[serverId] = nil end
end)

-- end of file
