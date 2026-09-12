--- core/client/environment.lua — applies what server/environment.lua decides (DESIGN §17).
--- Reads GlobalState['core:time'] / ['core:weather'] (server writes, clients read), the targeted
--- override events, `core:client:screen` ops and `core:client:playerState`.
--- Exactly one 1000 ms thread, and it only runs while something needs re-applying: a per-player
--- time override, frozen world time, or a weather transition waiting to be pinned.
--- Natives verified with fxref on 2026-09-12 (all apiset client unless noted):
--- NetworkOverrideClockTime(hours, minutes, seconds), NetworkClearClockTimeOverride(),
--- SetWeatherTypeOvertimePersist(weatherType, time)
--- (alias _SET_WEATHER_TYPE_OVER_TIME), SetWeatherTypeNowPersist(weatherType), ClearOverrideWeather(),
--- ClearWeatherTypePersist(), DoScreenFadeOut/In(duration), TriggerScreenblurFadeIn/Out(transitionTime),
--- AnimpostfxPlay(effectName, duration, looped), AnimpostfxStop(effectName), AnimpostfxStopAll(),
--- SetTimecycleModifier(modifierName), SetTimecycleModifierStrength(strength), ClearTimecycleModifier(),
--- SetPlayerControl(player, bHasControl, flags) (client+server), FreezeEntityPosition(entity, toggle)
--- (client+server), SetEntityInvincible(entity, toggle, dontResetOnCleanup), SetEntityVisible(entity,
--- toggle, p2), SetEntityHealth(entity, health, instigator, weaponType), GetEntityMaxHealth(entity),
--- SetPedArmour(ped, amount) (client+server), PlayerPedId(), PlayerId(), GetGameTimer() (client+server),
--- AddStateBagChangeHandler(keyFilter, bagFilter, handler) (shared).

local Net = Core.Net
local Log = Core.Log

local TICK_MS <const> = 1000
local MAX_ARMOUR <const> = 100
local BOOT_TRIES <const> = 20       -- 20 x 500 ms: GlobalState lands shortly after the join
local BOOT_WAIT_MS <const> = 500

local globalTime = nil              -- { h, m, s, frozen } from GlobalState['core:time']
local globalWeather = nil           -- { type, transition } from GlobalState['core:weather']
local timeOverride = nil            -- { h, m } while a per-player override is active
local weatherOverride = nil         -- { type, transition } while a per-player override is active
local pinWeatherAt = 0              -- GetGameTimer() at which a transition ends (0 = nothing pending)
local pinWeatherType = nil
local threadRunning = false

--- Both GlobalState values and the override payloads are server-written, but a malformed one
--- would crash the game (NetworkOverrideClockTime documents a crash for hours > 23), so the
--- clock is range-checked before it ever reaches a native.
local function clockUnit(value, max)
    if math.type(value) ~= 'integer' then
        if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
        value = math.floor(value)
    end
    if value < 0 or value > max then return nil end
    return value
end

--- The override wins over the global clock; nothing is applied until one of them exists.
local function applyTime()
    local current = timeOverride or globalTime
    if not current then return end
    NetworkOverrideClockTime(current.h, current.m, current.s or 0)
end

--- ClearOverrideWeather() first, and unconditionally: clearing a per-player override while the
--- server has published no global weather yet must still drop the override the player is seeing.
--- A transition (> 0 s) is pinned with SetWeatherTypeNowPersist once it has finished, otherwise
--- the game drifts back to its own weather cycle.
local function applyWeather()
    local current = weatherOverride or globalWeather
    ClearOverrideWeather()
    if not current or type(current.type) ~= 'string' then
        pinWeatherAt, pinWeatherType = 0, nil   -- nothing to pin: a stale pin would re-apply the old type
        return
    end
    local transition = type(current.transition) == 'number' and current.transition or 0.0
    if transition > 0.0 then
        SetWeatherTypeOvertimePersist(current.type, transition + 0.0)
        pinWeatherAt = GetGameTimer() + math.floor(transition * 1000) + 500
        pinWeatherType = current.type
    else
        SetWeatherTypeNowPersist(current.type)
        pinWeatherAt, pinWeatherType = 0, nil
    end
end

--- True while the 1000 ms thread has work: an override, frozen time, or a weather pin due.
local function needsThread()
    if timeOverride then return true end
    if pinWeatherAt > 0 then return true end
    return globalTime ~= nil and globalTime.frozen == true
end

--- Starts the single thread; it exits by itself once nothing needs re-applying.
local function ensureThread()
    if threadRunning or not needsThread() then return end
    threadRunning = true
    CreateThread(function()
        while threadRunning and needsThread() do
            applyTime()
            if pinWeatherAt > 0 and GetGameTimer() >= pinWeatherAt then
                if pinWeatherType then SetWeatherTypeNowPersist(pinWeatherType) end
                pinWeatherAt, pinWeatherType = 0, nil
            end
            Wait(TICK_MS)
        end
        threadRunning = false
    end)
end

--------------------------------------------------------------------------------
-- GlobalState: server writes, clients read (DESIGN §8)
--------------------------------------------------------------------------------

--- { h, m, s, frozen }; anything else is dropped rather than passed to the clock native.
local function setGlobalTime(value)
    if type(value) ~= 'table' then return false end
    local h, m = clockUnit(value.h, 23), clockUnit(value.m, 59)
    if not h or not m then
        Log.warn('environment: ignoring malformed core:time value')
        return false
    end
    globalTime = { h = h, m = m, s = clockUnit(value.s, 59) or 0, frozen = value.frozen == true }
    if not timeOverride then applyTime() end
    ensureThread()
    return true
end

--- { type, transition }.
local function setGlobalWeather(value)
    if type(value) ~= 'table' or type(value.type) ~= 'string' or #value.type == 0 then
        Log.warn('environment: ignoring malformed core:weather value')
        return false
    end
    globalWeather = { type = value.type, transition = tonumber(value.transition) or 0.0 }
    if not weatherOverride then applyWeather() end
    ensureThread()
    return true
end

AddStateBagChangeHandler('core:time', 'global', function(_, _, value)
    setGlobalTime(value)
end)

AddStateBagChangeHandler('core:weather', 'global', function(_, _, value)
    setGlobalWeather(value)
end)

-- A change handler only sees values written after this VM started: whatever was already
-- replicated when the player joined is picked up here. The thread ends as soon as both keys
-- are known (or after BOOT_TRIES attempts on a server that never publishes them).
CreateThread(function()
    for _ = 1, BOOT_TRIES do
        local time, weather = GlobalState['core:time'], GlobalState['core:weather']
        local haveTime = globalTime ~= nil or (time ~= nil and setGlobalTime(time))
        local haveWeather = globalWeather ~= nil or (weather ~= nil and setGlobalWeather(weather))
        if haveTime and haveWeather then return end
        Wait(BOOT_WAIT_MS)
    end
end)

--------------------------------------------------------------------------------
-- Per-player overrides (targeted events; `false` clears)
--------------------------------------------------------------------------------

Net.on('core:client:timeOverride', { 'any', 'integer?' }, function(hour, minute)
    if hour == false then
        timeOverride = nil
        applyTime()             -- straight back to the global clock
        ensureThread()          -- frozen global time or a pending weather pin still needs the tick
        return
    end
    local h, m = clockUnit(hour, 23), clockUnit(minute, 59)
    if not h or not m then
        Log.warn('environment: ignoring malformed timeOverride payload')
        return
    end
    timeOverride = { h = h, m = m, s = 0 }
    applyTime()
    ensureThread()
end)

Net.on('core:client:weatherOverride', { 'any', 'number?' }, function(weatherType, transition)
    if weatherType == false then
        weatherOverride = nil
        applyWeather()          -- back to the global weather, with its own transition
        ensureThread()
        return
    end
    if type(weatherType) ~= 'string' or #weatherType == 0 or #weatherType > 32 then
        Log.warn('environment: ignoring malformed weatherOverride payload')
        return
    end
    weatherOverride = { type = weatherType, transition = tonumber(transition) or 0.0 }
    applyWeather()
    ensureThread()
end)

--------------------------------------------------------------------------------
-- core:client:screen (op, ...) — the client half of Core.Screen
--------------------------------------------------------------------------------

local function isMs(value)
    return type(value) == 'number' and value == value and value >= 0
end

local function isName(value)
    return type(value) == 'string' and #value > 0 and #value <= 64
end

local SCREEN_OPS <const> = {
    fade = function(ms) if isMs(ms) then DoScreenFadeOut(math.floor(ms)) end end,
    unfade = function(ms) if isMs(ms) then DoScreenFadeIn(math.floor(ms)) end end,
    -- the blur natives take seconds as a float, the API speaks milliseconds everywhere else
    blur = function(ms) if isMs(ms) then TriggerScreenblurFadeIn(ms / 1000.0) end end,
    unblur = function(ms) if isMs(ms) then TriggerScreenblurFadeOut(ms / 1000.0) end end,
    effect = function(name, duration, looped)
        if isName(name) then AnimpostfxPlay(name, isMs(duration) and math.floor(duration) or 0, looped == true) end
    end,
    clearEffect = function(name) if isName(name) then AnimpostfxStop(name) end end,
    clearEffects = function() AnimpostfxStopAll() end,
    timecycle = function(name, strength)
        if not isName(name) then return end
        SetTimecycleModifier(name)
        if type(strength) == 'number' and strength == strength then
            SetTimecycleModifierStrength(math.min(math.max(strength, 0.0), 1.0) + 0.0)
        end
    end,
    clearTimecycle = function() ClearTimecycleModifier() end,
}

Net.on('core:client:screen', { 'string', 'any?', 'any?', 'any?' }, function(op, a, b, c)
    local apply = SCREEN_OPS[op]
    if not apply then
        Log.warn('environment: unknown screen op %s', tostring(op))
        return
    end
    apply(a, b, c)
end)

--------------------------------------------------------------------------------
-- core:client:playerState — Player.setControls/setFrozen/... (server/player.lua)
--------------------------------------------------------------------------------

Net.on('core:client:playerState', { 'table' }, function(payload)
    local ped = PlayerPedId()
    if payload.controls ~= nil then
        SetPlayerControl(PlayerId(), payload.controls == true, 0)   -- flags 0: no extra ped handling
    end
    if payload.frozen ~= nil then FreezeEntityPosition(ped, payload.frozen == true) end
    if payload.invincible ~= nil then
        SetEntityInvincible(ped, payload.invincible == true, false) -- dontResetOnCleanup = false
    end
    if payload.visible ~= nil then SetEntityVisible(ped, payload.visible == true, false) end
    if type(payload.health) == 'number' and payload.health == payload.health then
        local max = GetEntityMaxHealth(ped)
        SetEntityHealth(ped, math.floor(math.min(math.max(payload.health, 0), max)), 0, 0)
    end
    if type(payload.armour) == 'number' and payload.armour == payload.armour then
        SetPedArmour(ped, math.floor(math.min(math.max(payload.armour, 0), MAX_ARMOUR)))
    end
end)

-- Core stopping must never leave a player frozen, blacked out or invisible. Synchronous, no Wait.
AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= Core.name then return end
    threadRunning = false
    local ped = PlayerPedId()
    SetPlayerControl(PlayerId(), true, 0)
    FreezeEntityPosition(ped, false)
    SetEntityInvincible(ped, false, false)
    SetEntityVisible(ped, true, false)
    ClearTimecycleModifier()
    AnimpostfxStopAll()
    TriggerScreenblurFadeOut(0.0)
    DoScreenFadeIn(0)
    NetworkClearClockTimeOverride() -- otherwise the clock stays pinned at the last applied time
    ClearOverrideWeather()
    ClearWeatherTypePersist()       -- hand the weather back to the game's own cycle
end)

-- end of file
