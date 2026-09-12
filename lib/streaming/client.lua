--[[
    core lib: Core.Streaming (DESIGN §3.9) — timeout-bounded asset loading.
    Shape taken from the kit's patterns/model-loading.lua.

    Loaded into the CALLER's VM by import.lua (`local ns = ...`), client side only.

        Core.Streaming.requestModel(model, timeoutMs?) -> bool      / releaseModel(model)
        Core.Streaming.requestAnimDict(dict, timeoutMs?) -> bool    / releaseAnimDict(dict)
        Core.Streaming.requestAnimSet(set, timeoutMs?) -> bool      / releaseAnimSet(set)
        Core.Streaming.requestPtfx(name, timeoutMs?) -> bool        / releasePtfx(name)
        Core.Streaming.requestCollision(coords, timeoutMs?) -> bool

    Every request polls with a deadline so a bad asset name can never hang the calling coroutine, and
    every release is explicit (assets stay streamed in until the caller lets them go).

    Natives (verified with fxref 2026-09-12, all apiset client except the two MISC ones):
    RequestModel, HasModelLoaded, SetModelAsNoLongerNeeded, IsModelValid, IsModelInCdimage,
    RequestAnimDict, HasAnimDictLoaded, RemoveAnimDict, DoesAnimDictExist, RequestAnimSet,
    HasAnimSetLoaded, RemoveAnimSet, RequestNamedPtfxAsset, HasNamedPtfxAssetLoaded,
    RemoveNamedPtfxAsset, RequestCollisionAtCoord, HasCollisionLoadedAroundEntity, PlayerPedId,
    GetGameTimer (client+server), GetHashKey (client+server).
]]

local ns = ...

local DEFAULT_TIMEOUT_MS <const> = 10000

--- Explicit timeout, else Core.Config.StreamingTimeoutMs (DESIGN §2.0), else the built-in default.
local function timeoutOf(timeoutMs)
    if type(timeoutMs) == 'number' and timeoutMs > 0 then return timeoutMs end
    local cfg = Core.Config
    local configured = type(cfg) == 'table' and cfg.StreamingTimeoutMs or nil
    return type(configured) == 'number' and configured or DEFAULT_TIMEOUT_MS
end

--- Model name or hash -> hash, or nil when the argument is neither.
local function toHash(model)
    if type(model) == 'string' and model ~= '' then return GetHashKey(model) end
    if math.type(model) == 'integer' then return model end
    return nil
end

--- Polls `isLoaded(asset)` until it is true or the deadline passes. Returns the result.
local function waitLoaded(isLoaded, asset, timeoutMs)
    if isLoaded(asset) then return true end
    local deadline = GetGameTimer() + timeoutOf(timeoutMs)
    repeat
        Wait(0) -- per-frame: polling the streamer, bounded by the deadline
        if isLoaded(asset) then return true end
    until GetGameTimer() >= deadline
    return false
end

--- Streams in a model; false when the model is invalid or the timeout hits.
function ns.requestModel(model, timeoutMs)
    local hash = toHash(model)
    if not hash then return false end
    if not IsModelValid(hash) or not IsModelInCdimage(hash) then return false end
    if HasModelLoaded(hash) then return true end
    RequestModel(hash)
    return waitLoaded(HasModelLoaded, hash, timeoutMs)
end

--- Marks a model as no longer needed so the streamer may evict it.
function ns.releaseModel(model)
    local hash = toHash(model)
    if not hash then return end
    SetModelAsNoLongerNeeded(hash)
end

--- Streams in an animation dictionary; false when it does not exist or the timeout hits.
function ns.requestAnimDict(dict, timeoutMs)
    if type(dict) ~= 'string' or dict == '' then return false end
    if not DoesAnimDictExist(dict) then return false end
    if HasAnimDictLoaded(dict) then return true end
    RequestAnimDict(dict)
    return waitLoaded(HasAnimDictLoaded, dict, timeoutMs)
end

--- Releases an animation dictionary.
function ns.releaseAnimDict(dict)
    if type(dict) ~= 'string' or dict == '' then return end
    RemoveAnimDict(dict)
end

--- Streams in a movement clipset (anim set); false on timeout.
function ns.requestAnimSet(set, timeoutMs)
    if type(set) ~= 'string' or set == '' then return false end
    if HasAnimSetLoaded(set) then return true end
    RequestAnimSet(set)
    return waitLoaded(HasAnimSetLoaded, set, timeoutMs)
end

--- Releases a movement clipset.
function ns.releaseAnimSet(set)
    if type(set) ~= 'string' or set == '' then return end
    RemoveAnimSet(set)
end

--- Streams in a named particle asset; false on timeout.
function ns.requestPtfx(name, timeoutMs)
    if type(name) ~= 'string' or name == '' then return false end
    if HasNamedPtfxAssetLoaded(name) then return true end
    RequestNamedPtfxAsset(name)
    return waitLoaded(HasNamedPtfxAssetLoaded, name, timeoutMs)
end

--- Releases a named particle asset.
function ns.releasePtfx(name)
    if type(name) ~= 'string' or name == '' then return end
    RemoveNamedPtfxAsset(name)
end

--- Requests collision around `coords` and waits until it is loaded around the local ped.
--- Meant to be called right after teleporting the ped to those coords.
function ns.requestCollision(coords, timeoutMs)
    if type(coords) ~= 'vector3' then return false end
    local deadline = GetGameTimer() + timeoutOf(timeoutMs)
    repeat
        RequestCollisionAtCoord(coords.x, coords.y, coords.z)
        if HasCollisionLoadedAroundEntity(PlayerPedId()) then return true end
        Wait(0) -- per-frame: collision streams in over a few frames, bounded by the deadline
    until GetGameTimer() >= deadline
    return false
end
