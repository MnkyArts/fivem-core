--[[
    core lib: Core.Audio (DESIGN §20) — frontend and world sounds, client side only.

    Loaded into the CALLER's VM by import.lua (`local ns = ...`).

        Core.Audio.playFrontend(name, set?) -> soundId|nil     -- 2D UI/feedback sound
        Core.Audio.playAt(coords, name, set?, range?) -> soundId|nil
        Core.Audio.stop(soundId) -> boolean

    Every sound gets its own id from GetSoundId so it can be stopped; ids are a limited engine
    resource, so one that was never stopped is released automatically after 30 s (long enough for
    any one-shot sound, and the sound keeps playing to its end either way).

    Natives (verified with fxref 2026-09-12, apiset client): GetSoundId, PlaySoundFrontend,
    PlaySoundFromCoord, StopSound, ReleaseSoundId. `SetTimeout` and `AddEventHandler` are runtime
    helpers. The stop handler compares against `Core.name` — this chunk runs in the CALLER's VM,
    so that is the resource whose stop has to release our ids.
]]

local ns = ...

local DEFAULT_RANGE <const> = 20
local MAX_RANGE <const> = 200
local AUTO_RELEASE_MS <const> = 30000
local MAX_NAME_LEN <const> = 64

local live = {}      -- [soundId] = true while the id is ours

--- Give the id back to the engine, once.
local function release(soundId)
    if not live[soundId] then return false end
    live[soundId] = nil
    ReleaseSoundId(soundId)
    return true
end

--- A usable sound/ref name, or nil.
local function soundName(value)
    if type(value) ~= 'string' or value == '' or #value > MAX_NAME_LEN then return nil end
    return value
end

--- Reserve an id and arm its auto-release. nil when the engine has none left (-1).
local function acquire()
    local soundId = GetSoundId()
    if math.type(soundId) ~= 'integer' or soundId < 0 then return nil end
    live[soundId] = true
    SetTimeout(AUTO_RELEASE_MS, function() release(soundId) end)
    return soundId
end

--- Play a frontend (2D) sound. `set` is the audio ref/sound set, nil for the default one.
--- @return integer|nil soundId
function ns.playFrontend(name, set)
    local audioName = soundName(name)
    if not audioName then return nil end
    local soundId = acquire()
    if not soundId then return nil end
    PlaySoundFrontend(soundId, audioName, soundName(set), true)
    return soundId
end

--- Play a sound at world coordinates.
--- @param coords vector3|table
--- @return integer|nil soundId
function ns.playAt(coords, name, set, range)
    local audioName = soundName(name)
    if not audioName then return nil end
    local x, y, z
    if type(coords) == 'vector3' then
        x, y, z = coords.x, coords.y, coords.z
    elseif type(coords) == 'table' then
        x, y, z = tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
    end
    if not x or not y or not z then return nil end

    local audioRange = math.floor(tonumber(range) or DEFAULT_RANGE)
    if audioRange < 1 then audioRange = DEFAULT_RANGE end
    if audioRange > MAX_RANGE then audioRange = MAX_RANGE end

    local soundId = acquire()
    if not soundId then return nil end
    PlaySoundFromCoord(soundId, audioName, x + 0.0, y + 0.0, z + 0.0, soundName(set), false, audioRange, false)
    return soundId
end

--- Stop a sound started by playFrontend/playAt and release its id.
--- @return boolean stopped
function ns.stop(soundId)
    if math.type(soundId) ~= 'integer' or not live[soundId] then return false end
    StopSound(soundId)
    return release(soundId)
end

-- Ids are engine-wide: hand every one of ours back when this resource stops (synchronous, no Wait).
AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= Core.name then return end
    for soundId in pairs(live) do
        StopSound(soundId)
        live[soundId] = nil
        ReleaseSoundId(soundId)
    end
end)
