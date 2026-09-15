--[[ core — client/vehicles.lua
     Core.Vehicles client side (DESIGN §6.8): lookups, the props table, the `locked` state-bag handler
     (core vehicles only), the entry guard that re-applies locks while the player tries to get in, and
     the Config.Vehicles.LockKey binding.
     Nothing here is authoritative: locking and prop saving go through the server (DESIGN §5).
     Extended condition natives (fxref verified 2026-09-15): GetVehicleDoorAngleRatio,
     SetVehicleDoorOpen/Shut, IsVehicleWindowIntact, SmashVehicleWindow, FixVehicleWindow,
     Get/SetVehicleLights, SetVehicleFullbeam, Get/SetVehicleIndicatorLights,
     Get/SetVehicleWheelHealth.
]]

local Vehicles = {}

local TOGGLE_MODS <const> = { 17, 18, 19, 20, 22 }   -- turbo, xenon (legacy), ... the toggle mod slots
local MAX_MOD_TYPE <const> = 49
local MAX_EXTRA <const> = 20
local MAX_WHEEL <const> = 7
local MAX_DOOR <const> = 7
local MAX_WINDOW <const> = 7
local MAX_SEAT <const> = 6
local CONTROL_TIMEOUT_MS <const> = 1000
local TOGGLE_DISTANCE <const> = 8.0
local GUARD_ACTIVE_MS <const> = 500     -- entry guard cadence while the ped is trying to get in
local GUARD_IDLE_MS <const> = 1500      -- ... and while it is not

local stopping = false

local function notify(message, kind)
    local ui = Core.UI
    if ui and ui.notify then ui.notify(message, kind or 'info') end
end

local function isVehicle(veh)
    return type(veh) == 'number' and veh ~= 0 and DoesEntityExist(veh)
end

-- Network ownership is needed before any Set* on a vehicle someone else owns.
local function requestControl(veh, timeoutMs)
    if NetworkHasControlOfEntity(veh) then return true end
    local deadline = GetGameTimer() + (timeoutMs or CONTROL_TIMEOUT_MS)
    repeat
        NetworkRequestControlOfEntity(veh)
        -- ownership is granted between frames, so the request has to be repeated per frame; the loop is
        -- bounded by CONTROL_TIMEOUT_MS (1 s) and only runs while a setProps/repair call is in flight
        -- fxlint-disable-next-line P002
        Wait(0)
    until NetworkHasControlOfEntity(veh) or GetGameTimer() >= deadline
    return NetworkHasControlOfEntity(veh)
end

--- The vehicle the local ped is in.
---@return integer veh 0 when on foot
function Vehicles.getCurrent()
    return GetVehiclePedIsIn(PlayerPedId(), false)
end

---@return boolean isDriver
function Vehicles.isDriver()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    return veh ~= 0 and GetPedInVehicleSeat(veh, -1, false) == ped
end

--- Seat index of the local ped (-1 = driver).
---@return integer|nil seat
function Vehicles.getSeat()
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 then return nil end
    for seat = -1, MAX_SEAT do
        if GetPedInVehicleSeat(veh, seat, false) == ped then return seat end
    end
    return nil
end

--- Closest vehicle to `coords` (default: the local ped) within `radius` (default 5.0).
--- On-demand pool scan only; never call this per frame.
---@return integer veh, number|nil distance
function Vehicles.getClosest(coords, radius)
    local origin = Core.Utils.isVector3(coords) and coords or GetEntityCoords(PlayerPedId(), false)
    local best, bestDist = 0, tonumber(radius) or 5.0
    local pool = GetGamePool('CVehicle')
    for i = 1, #pool do
        local veh = pool[i]
        if DoesEntityExist(veh) then
            local dist = #(origin - GetEntityCoords(veh, false))
            if dist <= bestDist then best, bestDist = veh, dist end
        end
    end
    if best == 0 then return 0, nil end
    return best, bestDist
end

---@param veh integer
---@return integer netId 0 when the entity is gone
function Vehicles.getNetId(veh)
    if not isVehicle(veh) then return 0 end
    return NetworkGetNetworkIdFromEntity(veh)
end

--- Resolve a net id to a local entity, waiting for it to stream in (default 5 s).
--- Must be called from a thread/event handler.
---@return integer veh 0 on timeout
function Vehicles.fromNetId(netId, timeoutMs)
    if type(netId) ~= 'number' or netId <= 0 then return 0 end
    local deadline = GetGameTimer() + (tonumber(timeoutMs) or 5000)
    repeat
        if NetworkDoesEntityExistWithNetworkId(netId) then
            local veh = NetworkGetEntityFromNetworkId(netId)
            if isVehicle(veh) then return veh end
        end
        Wait(50)
    until GetGameTimer() >= deadline
    return 0
end

---@param veh integer
---@return string plate trimmed
function Vehicles.getPlate(veh)
    if not isVehicle(veh) then return '' end
    return Core.Utils.trim(GetVehicleNumberPlateText(veh) or '')
end

--- Localised display name of a vehicle entity, model name or model hash.
---@param vehOrModel integer|string
---@return string
function Vehicles.getDisplayName(vehOrModel)
    local model
    if type(vehOrModel) == 'string' then
        model = Core.Utils.hash(vehOrModel)
    elseif isVehicle(vehOrModel) then
        model = GetEntityModel(vehOrModel)
    else
        model = vehOrModel
    end
    if type(model) ~= 'number' then return '' end
    local label = GetDisplayNameFromVehicleModel(model)
    if not label or label == '' then return '' end
    local text = GetFilenameForAudioConversation(label)   -- _GET_LABEL_TEXT
    if not text or text == '' or text == 'NULL' then return label end
    return text
end

---@param veh integer
---@return boolean locked state bag value
function Vehicles.isLocked(veh)
    if not isVehicle(veh) then return false end
    return Entity(veh).state.locked == true
end

--- Explicit virtual-key holder of a core vehicle (state bag read; false for any other vehicle).
--- Item-key vehicles deliberately carry no virtual owner key; their plugin verifies its physical item.
---@param veh integer
---@return boolean
function Vehicles.hasKeys(veh)
    if not isVehicle(veh) then return false end
    local state = Entity(veh).state
    if not state.coreVeh then return false end
    local charId = Core.Player.get('charId')
    if not charId then return false end
    local keys = state.keys
    return type(keys) == 'table' and keys[charId] == true
end

--- Reads the full appearance/condition set (DESIGN §6.8). JSON-safe: numbers, booleans, strings
--- and arrays/maps of those only.
---@param veh integer
---@return table|nil props
function Vehicles.getProps(veh)
    if not isVehicle(veh) then return nil end
    SetVehicleModKit(veh, 0)

    local colorPrimary, colorSecondary = GetVehicleColours(veh)
    local pearlescentColor, wheelColor = GetVehicleExtraColours(veh)
    local neonR, neonG, neonB = GetVehicleNeonColour(veh)
    local smokeR, smokeG, smokeB = GetVehicleTyreSmokeColor(veh)

    local props = {
        model = GetEntityModel(veh),
        plate = Vehicles.getPlate(veh),
        plateIndex = GetVehicleNumberPlateTextIndex(veh),
        colorPrimary = colorPrimary,
        colorSecondary = colorSecondary,
        pearlescentColor = pearlescentColor,
        wheelColor = wheelColor,
        interiorColor = GetVehicleExtraColour_5(veh),
        dashboardColor = GetVehicleExtraColour_6(veh),
        wheels = GetVehicleWheelType(veh),
        windowTint = GetVehicleWindowTint(veh),
        livery = GetVehicleLivery(veh),
        livery2 = GetVehicleLivery2(veh),
        xenonColor = GetVehicleXenonLightColorIndex(veh),
        neonColor = { neonR, neonG, neonB },
        tyreSmokeColor = { smokeR, smokeG, smokeB },
        engineHealth = Core.Utils.round(GetVehicleEngineHealth(veh), 1),
        bodyHealth = Core.Utils.round(GetVehicleBodyHealth(veh), 1),
        tankHealth = Core.Utils.round(GetVehiclePetrolTankHealth(veh), 1),
        fuelLevel = Core.Utils.round(GetVehicleFuelLevel(veh), 1),
        dirtLevel = Core.Utils.round(GetVehicleDirtLevel(veh), 1),
    }

    props.customPrimary = false
    if GetIsVehiclePrimaryColourCustom(veh) then
        local r, g, b = GetVehicleCustomPrimaryColour(veh)
        props.customPrimary = { r, g, b }
    end
    props.customSecondary = false
    if GetIsVehicleSecondaryColourCustom(veh) then
        local r, g, b = GetVehicleCustomSecondaryColour(veh)
        props.customSecondary = { r, g, b }
    end

    local neon = {}
    for i = 0, 3 do neon[i + 1] = GetVehicleNeonEnabled(veh, i) and true or false end
    props.neonEnabled = neon

    local extras = {}
    for extraId = 0, MAX_EXTRA do
        if DoesExtraExist(veh, extraId) then
            extras[extraId] = IsVehicleExtraTurnedOn(veh, extraId) and true or false
        end
    end
    props.extras = extras

    local mods, variations = {}, {}
    for modType = 0, MAX_MOD_TYPE do
        local index = GetVehicleMod(veh, modType)
        if index and index ~= -1 then
            mods[modType] = index
            local variation = GetVehicleModVariation(veh, modType)
            if variation and variation ~= 0 then variations[modType] = true end
        end
    end
    props.mods = mods
    if next(variations) then props.modVariations = variations end

    local toggles = {}
    for i = 1, #TOGGLE_MODS do
        local modType = TOGGLE_MODS[i]
        toggles[modType] = IsToggleModOn(veh, modType) and true or false
    end
    props.modToggles = toggles

    local burst, tyreHealth = {}, {}
    for wheel = 0, MAX_WHEEL do
        if IsVehicleTyreBurst(veh, wheel, false) then burst[wheel] = true end
        tyreHealth[wheel] = Core.Utils.round(GetVehicleWheelHealth(veh, wheel), 1)
    end
    props.burstTyres, props.tyreHealth = burst, tyreHealth

    local doors, windows = {}, {}
    for door = 0, MAX_DOOR do doors[door] = GetVehicleDoorAngleRatio(veh, door) > 0.05 end
    for window = 0, MAX_WINDOW do windows[window] = IsVehicleWindowIntact(veh, window) and true or false end
    props.doors, props.windows = doors, windows

    local _, lightsOn, highBeams = GetVehicleLightsState(veh)
    props.lights = { lightsOn == true, highBeams == true, GetVehicleIndicatorLights(veh) }

    return props
end

-- json round-trips turn integer keys into strings; accept both.
local function numKey(key)
    return type(key) == 'number' and key or tonumber(key)
end

local function applyColors(veh, props)
    if props.colorPrimary and props.colorSecondary then
        SetVehicleColours(veh, props.colorPrimary, props.colorSecondary)
    end
    if props.pearlescentColor and props.wheelColor then
        SetVehicleExtraColours(veh, props.pearlescentColor, props.wheelColor)
    end
    if props.customPrimary ~= nil then
        if type(props.customPrimary) == 'table' then
            SetVehicleCustomPrimaryColour(veh, props.customPrimary[1], props.customPrimary[2], props.customPrimary[3])
        else
            ClearVehicleCustomPrimaryColour(veh)
        end
    end
    if props.customSecondary ~= nil then
        if type(props.customSecondary) == 'table' then
            SetVehicleCustomSecondaryColour(veh, props.customSecondary[1], props.customSecondary[2],
                props.customSecondary[3])
        else
            ClearVehicleCustomSecondaryColour(veh)
        end
    end
    if props.interiorColor then SetVehicleExtraColour_5(veh, props.interiorColor) end
    if props.dashboardColor then SetVehicleExtraColour_6(veh, props.dashboardColor) end
    if type(props.neonColor) == 'table' then
        SetVehicleNeonColour(veh, props.neonColor[1], props.neonColor[2], props.neonColor[3])
    end
    if type(props.neonEnabled) == 'table' then
        for i = 1, 4 do SetVehicleNeonEnabled(veh, i - 1, props.neonEnabled[i] == true) end
    end
    if type(props.tyreSmokeColor) == 'table' then
        SetVehicleTyreSmokeColor(veh, props.tyreSmokeColor[1], props.tyreSmokeColor[2], props.tyreSmokeColor[3])
    end
end

local function applyMods(veh, props)
    if type(props.extras) == 'table' then
        for key, enabled in pairs(props.extras) do
            local extraId = numKey(key)
            if extraId and DoesExtraExist(veh, extraId) then
                SetVehicleExtra(veh, extraId, enabled and 0 or 1)   -- 1 disables the extra
            end
        end
    end
    if props.wheels then SetVehicleWheelType(veh, props.wheels) end
    if type(props.mods) == 'table' then
        local variations = type(props.modVariations) == 'table' and props.modVariations or nil
        for key, index in pairs(props.mods) do
            local modType = numKey(key)
            if modType and type(index) == 'number' then
                local custom = false
                if variations then custom = variations[key] == true or variations[modType] == true end
                SetVehicleMod(veh, modType, index, custom)
            end
        end
    end
    if type(props.modToggles) == 'table' then
        for key, on in pairs(props.modToggles) do
            local modType = numKey(key)
            if modType then ToggleVehicleMod(veh, modType, on == true) end
        end
    end
    if props.windowTint then SetVehicleWindowTint(veh, props.windowTint) end
    if props.livery then SetVehicleLivery(veh, props.livery) end
    if props.livery2 then SetVehicleLivery2(veh, props.livery2) end
    if props.xenonColor then SetVehicleXenonLightColorIndex(veh, props.xenonColor) end
end

local function applyCondition(veh, props)
    if props.engineHealth then SetVehicleEngineHealth(veh, props.engineHealth + 0.0) end
    if props.bodyHealth then SetVehicleBodyHealth(veh, props.bodyHealth + 0.0) end
    if props.tankHealth then SetVehiclePetrolTankHealth(veh, props.tankHealth + 0.0) end
    if props.fuelLevel then SetVehicleFuelLevel(veh, props.fuelLevel + 0.0) end
    if props.dirtLevel then SetVehicleDirtLevel(veh, props.dirtLevel + 0.0) end
    if type(props.burstTyres) == 'table' then
        for wheel = 0, MAX_WHEEL do
            if props.burstTyres[wheel] == true or props.burstTyres[tostring(wheel)] == true then
                SetVehicleTyreBurst(veh, wheel, true, 1000.0)
            else
                SetVehicleTyreFixed(veh, wheel)
            end
        end
    end
    if type(props.tyreHealth) == 'table' then
        for wheel = 0, MAX_WHEEL do
            local health = props.tyreHealth[wheel] or props.tyreHealth[tostring(wheel)]
            if type(health) == 'number' then SetVehicleWheelHealth(veh, wheel, health + 0.0) end
        end
    end
    if type(props.doors) == 'table' then
        for door = 0, MAX_DOOR do
            if props.doors[door] == true or props.doors[tostring(door)] == true then
                SetVehicleDoorOpen(veh, door, false, true)
            else
                SetVehicleDoorShut(veh, door, true)
            end
        end
    end
    if type(props.windows) == 'table' then
        for window = 0, MAX_WINDOW do
            if props.windows[window] == true or props.windows[tostring(window)] == true then
                FixVehicleWindow(veh, window)
            else
                SmashVehicleWindow(veh, window)
            end
        end
    end
    if type(props.lights) == 'table' then
        SetVehicleLights(veh, props.lights[1] == true and 3 or 4)
        SetVehicleFullbeam(veh, props.lights[2] == true)
        local indicators = tonumber(props.lights[3]) or 0
        SetVehicleIndicatorLights(veh, 1, (indicators & 1) ~= 0)
        SetVehicleIndicatorLights(veh, 0, (indicators & 2) ~= 0)
    end
end

--- Applies only the keys present. Yields while asking for network control, so call it from a thread.
---@param veh integer
---@param props table
---@return boolean ok
function Vehicles.setProps(veh, props)
    if not isVehicle(veh) or type(props) ~= 'table' then return false end
    if not requestControl(veh) then return false end
    -- requestControl yields for up to a second: the vehicle may have been deleted or streamed out
    if not DoesEntityExist(veh) then return false end

    SetVehicleModKit(veh, 0)
    if type(props.plate) == 'string' and props.plate ~= '' then
        SetVehicleNumberPlateText(veh, props.plate)
    end
    if props.plateIndex then SetVehicleNumberPlateTextIndex(veh, props.plateIndex) end

    applyColors(veh, props)
    applyMods(veh, props)
    applyCondition(veh, props)
    return true
end

---@param veh integer
---@param on boolean
---@return boolean ok
function Vehicles.setEngine(veh, on)
    if not isVehicle(veh) then return false end
    SetVehicleEngineOn(veh, on == true, true, true)
    return true
end

--- Full local repair (needs network control).
---@param veh integer
---@return boolean ok
function Vehicles.repair(veh)
    if not isVehicle(veh) then return false end
    if not requestControl(veh) then return false end
    if not DoesEntityExist(veh) then return false end   -- requestControl yields; re-check
    SetVehicleFixed(veh)
    SetVehicleDeformationFixed(veh)
    SetVehicleEngineHealth(veh, 1000.0)
    SetVehicleBodyHealth(veh, 1000.0)
    SetVehiclePetrolTankHealth(veh, 1000.0)
    for wheel = 0, MAX_WHEEL do SetVehicleTyreFixed(veh, wheel) end
    return true
end

--- Ask the server to toggle the lock of `veh`, or the current/closest vehicle within 8 m.
--- The server re-checks keys, distance and ownership; the local check is UX only.
function Vehicles.toggleLock(veh)
    if not isVehicle(veh) then
        veh = Vehicles.getCurrent()
        if veh == 0 then veh = Vehicles.getClosest(nil, TOGGLE_DISTANCE) end
    end
    if not isVehicle(veh) then return end
    if not Entity(veh).state.coreVeh then return end
    if not Vehicles.hasKeys(veh) then
        notify(Config.Texts.no_keys, 'error')
        return
    end
    local netId = Vehicles.getNetId(veh)
    if netId == 0 then return end
    Core.Net.emit('core:server:vehicleLock', netId)
end

--- Send the current props to the server for persistence (DESIGN §5).
---@param veh integer
---@return boolean sent
function Vehicles.saveProps(veh)
    if not isVehicle(veh) then return false end
    local netId = Vehicles.getNetId(veh)
    if netId == 0 then return false end
    local props = Vehicles.getProps(veh)
    if not props then return false end
    Core.Net.emit('core:server:vehicleProps', netId, props)
    return true
end

--- GetEntityFromStateBagName resolves `entity:<netId>` through the game's lookup, which FiveM
--- patches to log a console warning for every entity this client does not hold — and entity bags
--- do reach clients that have the entity out of scope, so a server writing a bag every few
--- seconds spams the console. The existence check is warning-free, so it runs first.
local function entityFromBag(bagName)
    local netId = tonumber(string.match(bagName, '^entity:(%d+)$'))
    if netId then
        if not NetworkDoesEntityExistWithNetworkId(netId) then return 0 end
        return GetEntityFromStateBagName(bagName)
    end
    if string.find(bagName, '^localEntity:') then return GetEntityFromStateBagName(bagName) end
    return 0
end

-- Server writes `locked`, every client mirrors it onto the doors. Core vehicles only.
AddStateBagChangeHandler('locked', nil, function(bagName, _, value)
    if type(value) ~= 'boolean' then return end
    local veh = entityFromBag(bagName)
    if veh == 0 or not DoesEntityExist(veh) then return end
    if not Entity(veh).state.coreVeh then return end
    SetVehicleDoorsLocked(veh, value and 2 or 1)
end)

-- Entry guard: re-applies the lock on a vehicle that streamed in after the state change, and only
-- does any work while the player is actually trying to get in (DESIGN §6.8, §9).
CreateThread(function()
    while not stopping do
        local sleep = GUARD_IDLE_MS
        local veh = GetVehiclePedIsTryingToEnter(PlayerPedId())
        if veh ~= 0 then
            sleep = GUARD_ACTIVE_MS
            if DoesEntityExist(veh) then
                local state = Entity(veh).state
                if state.coreVeh and state.locked == true and GetVehicleDoorLockStatus(veh) ~= 2 then
                    SetVehicleDoorsLocked(veh, 2)
                end
            end
        end
        Wait(sleep)
    end
end)

-- Props pushed by the server for a vehicle this client owns (DESIGN §4.6/§5).
Core.Net.on('core:client:applyVehicleProps', { 'netId', 'table' }, function(netId, props)
    local veh = Vehicles.fromNetId(netId, Config.Vehicles.SpawnTimeoutMs)
    if veh == 0 then return end
    Vehicles.setProps(veh, props)
end)

Core.Keys.register({
    name = 'vehiclelock',
    description = 'Lock / unlock vehicle',
    key = Config.Vehicles.LockKey,
    debounce = 500,
    onPress = function()
        Vehicles.toggleLock()
    end,
})

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= Core.name then return end
    stopping = true
end)

Core.Vehicles = Vehicles

-- end of file
