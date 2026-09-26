-- Core.Player context (DESIGN §40): one local cache, no pool iteration or network traffic.
-- Natives verified via fxref 2026-09-20: PlayerPedId, DoesEntityExist, GetVehiclePedIsIn,
-- GetVehicleMaxNumberOfPassengers, GetPedInVehicleSeat (client third arg false),
-- GetSelectedPedWeapon, GetGameTimer. Existing pedChanged remains owned by main.lua.
local Player, Registry, Utils = Core.Player, Core.Registry, Core.Utils
local PERIOD <const> = 250
local KEYS <const> = { ped = true, vehicle = true, seat = true, weapon = true }
local cache = { ped = 0, vehicle = 0, weapon = 0 }
local listeners, listenerCount, sequence = {}, 0, 0
local sampledAt = nil
local running = false

local function bool(v) return v == true or v == 1 end

local function dispatch(id, target, value, previous)
    if target.pending then
        target.pending.value = value
    else
        target.pending = { value = value, previous = previous }
    end
    if target.busy then return end
    target.busy = true
    -- Slow subscribers get one coalesced pending change, not unbounded threads.
    CreateThread(function()
        while listeners[id] == target and target.pending do
            local event = target.pending
            target.pending = nil
            local ok, err = pcall(target.fn, event.value, event.previous)
            if not ok then Core.Log.error('context %s callback failed: %s', target.key, tostring(err)) end
        end
        target.busy = false
    end)
end

local function publish(key, value, previous)
    for id, listener in pairs(listeners) do
        if listener.key == key then
            dispatch(id, listener, value, previous)
        end
    end
end

local function sample()
    local now = GetGameTimer()
    if sampledAt and now - sampledAt >= 0 and now - sampledAt < PERIOD then return end
    sampledAt = now
    local ped = PlayerPedId()
    if ped == 0 or not bool(DoesEntityExist(ped)) then ped = 0 end
    local vehicle, seat, weapon = 0, nil, 0
    if ped ~= 0 then
        vehicle = GetVehiclePedIsIn(ped, false)
        if vehicle ~= 0 and not bool(DoesEntityExist(vehicle)) then vehicle = 0 end
        if vehicle ~= 0 then
            local oldSeat = cache.vehicle == vehicle and cache.seat or nil
            if oldSeat ~= nil and GetPedInVehicleSeat(vehicle, oldSeat, false) == ped then
                seat = oldSeat
            else
                local last = math.min(GetVehicleMaxNumberOfPassengers(vehicle) - 1, 31)
                for candidate = -1, last do
                    if GetPedInVehicleSeat(vehicle, candidate, false) == ped then seat = candidate; break end
                end
            end
        end
        weapon = GetSelectedPedWeapon(ped)
    end
    local oldPed, oldVehicle, oldSeat, oldWeapon = cache.ped, cache.vehicle, cache.seat, cache.weapon
    cache.ped, cache.vehicle, cache.seat, cache.weapon = ped, vehicle, seat, weapon
    -- Publish after the entire snapshot changes, so callbacks never observe mixed contexts.
    if oldPed ~= ped then publish('ped', ped, oldPed) end
    if oldVehicle ~= vehicle then publish('vehicle', vehicle, oldVehicle) end
    if oldSeat ~= seat then publish('seat', seat, oldSeat) end
    if oldWeapon ~= weapon then publish('weapon', weapon, oldWeapon) end
end

function Player.context()
    sample()
    return { ped = cache.ped, vehicle = cache.vehicle, seat = cache.seat, weapon = cache.weapon }
end

local function startLoop()
    if running then return end
    running = true
    CreateThread(function()
        while listenerCount > 0 do
            sample()
            Wait(PERIOD)
        end
        running = false
    end)
end

function Player.onContextChange(key, fn)
    if not KEYS[key] or not Utils.isCallable(fn) then return nil end
    sample()
    sequence = sequence + 1
    local id, owner = 'context:' .. sequence, Registry.getCaller()
    listeners[id] = { key = key, fn = fn, owner = owner }
    listenerCount = listenerCount + 1
    Registry.track('context', id, owner)
    startLoop()
    return id
end

local function remove(id)
    if not listeners[id] then return false end
    listeners[id] = nil
    listenerCount = listenerCount - 1
    Registry.untrack('context', id)
    return true
end

function Player.offContextChange(id)
    local entry = type(id) == 'string' and listeners[id]
    if not entry or entry.owner ~= Registry.getCaller() then return false end
    return remove(id)
end

Registry.onOwnerStop('context', remove)
