--- core / client/player.lua — Core.Player client extras (DESIGN §6.2).
--- Holds the `loaded` payload (client/main.lua receives it and calls setCached)
--- and handles the targeted server → client player events.
--- Natives verified with fxref on 2026-09-12: PlayerPedId (client),
--- GetEntityCoords (client form: entity, alive), GetEntityHeading (client+server),
--- SetEntityHealth (client), GetEntityMaxHealth (client+server), SetPedArmour (client+server).

local Player = Core.Player          -- lib namespace from lib/player/client.lua — extend, never replace
local Net = Core.Net
local Utils = Core.Utils

local MAX_ARMOUR <const> = 100
local PUBLIC <const> = {            -- payload fields a plugin may read
    charId = true, name = true, model = true, appearance = true,
    position = true, money = true, faction = true, group = true,
}

local cached = nil                  -- last core:client:loaded payload

--- Stores the payload delivered by core:client:loaded (client/main.lua owns that handler).
function Player.setCached(payload)
    if type(payload) ~= 'table' then return false end
    cached = payload
    return true
end

--- Player.getData(key) -> value — public payload fields only, tables as copies.
function Player.getData(key)
    if not cached or not PUBLIC[key] then return nil end
    local value = cached[key]
    if type(value) == 'table' then return Utils.deepCopy(value) end
    return value
end

--- Asks the server to re-send the payload (answered on core:client:loaded).
function Player.refresh()
    Net.emit('core:server:requestLoad')
    return true
end

Net.on('core:client:setModel', { { 'string', max = 64 }, 'table?' }, function(model, appearance)
    if cached then                  -- keep getData('model') in sync with what we are wearing
        cached.model = model
        if appearance then cached.appearance = appearance end
    end
    Core.Spawn.setModel(model, appearance)
end)

Net.on('core:client:teleport', { 'vector3', 'number?' }, function(coords, heading)
    Core.Spawn.teleport(coords, heading)
end)

Net.on('core:client:revive', {}, function()
    local ped = PlayerPedId()
    Core.Spawn.spawnPlayer({
        coords = GetEntityCoords(ped, false),
        heading = GetEntityHeading(ped),
        resurrect = true,
        fade = false,
    })
end)

Net.on('core:client:heal', {}, function()
    local ped = PlayerPedId()
    SetEntityHealth(ped, GetEntityMaxHealth(ped), 0, 0)   -- (instigator, weaponType) = none
    SetPedArmour(ped, MAX_ARMOUR)
end)

-- Sent by the admin /car command (DESIGN §4.8/§5): put the player in the car
-- the server just spawned. TaskWarpPedIntoVehicle verified apiset client.
Net.on('core:client:warpIntoVehicle', { 'netId' }, function(netId)
    local vehicle = Core.Vehicles.fromNetId(netId, 5000)   -- waits for the entity to stream in
    if not vehicle or vehicle == 0 then return end
    TaskWarpPedIntoVehicle(PlayerPedId(), vehicle, -1)     -- seat -1 = driver
end)

-- end of file
