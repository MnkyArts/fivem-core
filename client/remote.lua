--[[
    core/client/remote.lua — client half of the remote player control APIs (DESIGN §20)

    Receives what server/remote.lua sends:
      * `core:client:native (name, args)` + callback `core:native`  -> `_G[name](...)`, checked a
        second time here against Config.Native.Allow (§28) and against core's hard deny list,
      * `core:client:anim (op, dict, clip, opts)`                   -> Core.Anim (§3.10),
      * `core:client:audio (op, data)`                              -> Core.Audio (lib/audio/client.lua),
      * `core:client:waypoint (op, coords)` + callback `core:waypoint:get` -> Core.Blips (§6.6),
      * callback `core:raycast (distance)`                          -> Core.Raycast (§6.9).

    Player attachments (Core.Attachments) are Core.Scene 'prop' nodes attached to the player since
    DESIGN §55.21.3: the scene's materialiser creates and attaches the objects (client/scene_kinds.lua),
    so this file no longer has an applier (the `attachments` state bag is not written any more).

    Natives (verified with fxref 2026-09-12, re-checked 2026-09-27; apiset client): PlayerPedId,
    DoesEntityExist, NetworkGetEntityIsNetworked, NetworkGetNetworkIdFromEntity.
]]

local Net = Core.Net
local Log = Core.Log
local Utils = Core.Utils
local Callback = Core.Callback

local MAX_NAME_LEN <const> = 64
local MAX_ARGS <const> = 16
local NATIVE_PATTERN <const> = '^%u[%w_]+$'

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

-- end of file
