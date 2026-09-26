--- core / client/player.lua — Core.Player client extras (DESIGN §6.2).
--- Holds the `loaded` payload (client/main.lua receives it and calls setCached)
--- and handles the targeted server → client player events.
--- Natives verified with fxref on 2026-09-12: PlayerPedId (client),
--- GetEntityCoords (client form: entity, alive), GetEntityHeading (client+server),
--- SetEntityHealth (client), GetEntityMaxHealth (client+server), SetPedArmour (client+server).
--- §48 sticky states (fxref 2026-09-26, client): PlayerId, SetPlayerControl(player, bHasControl, flags),
--- FreezeEntityPosition(entity, toggle), SetEntityInvincible(entity, toggle, dontResetOnCleanup),
--- SetEntityVisible(entity, toggle, p2).

local Player = Core.Player          -- lib namespace from lib/player/client.lua — extend, never replace
local Net = Core.Net
local Utils = Core.Utils

local MAX_ARMOUR <const> = 100
local PUBLIC <const> = {            -- payload fields a plugin may read
    charId = true, name = true, model = true, appearance = true,
    position = true, money = true, faction = true, group = true,
}

local cached = nil                  -- last core:client:loaded payload

-- §48 sticky states: the server's last word per key; every value that differs from its default is
-- re-applied after pedChanged, a (re)spawn and every teleport (client/spawn.lua calls reapplyStates)
local STATE_DEFAULTS <const> = { frozen = false, invincible = false, visible = true, controls = true }
local states = { frozen = false, invincible = false, visible = true, controls = true }

local function applyState(ped, key, value)
    if key == 'controls' then
        SetPlayerControl(PlayerId(), value, 0)          -- flags 0: no extra ped handling
    elseif key == 'frozen' then
        FreezeEntityPosition(ped, value)
    elseif key == 'invincible' then
        SetEntityInvincible(ped, value, false)          -- dontResetOnCleanup = false
    elseif key == 'visible' then
        SetEntityVisible(ped, value, false)
    end
end

--- Stores sticky values from the server and applies them now (client/environment.lua's
--- core:client:playerState handler). Core-internal: the server is the authority, see Player.setFrozen.
function Player.setStates(partial)
    if type(partial) ~= 'table' then return false end
    local ped = PlayerPedId()
    for key in pairs(STATE_DEFAULTS) do
        local value = partial[key]
        if type(value) == 'boolean' then
            states[key] = value
            applyState(ped, key, value)
        end
    end
    return true
end

--- Re-applies every sticky state that differs from its default to `ped` (default: the current ped).
function Player.reapplyStates(ped)
    ped = ped or PlayerPedId()
    for key, default in pairs(STATE_DEFAULTS) do
        if states[key] ~= default then applyState(ped, key, states[key]) end
    end
end

--- Player.getStates() -> { frozen, invincible, visible, controls } (a copy).
function Player.getStates()
    return { frozen = states.frozen, invincible = states.invincible, visible = states.visible,
        controls = states.controls }
end

--- Stores the payload delivered by core:client:loaded (client/main.lua owns that handler). Its
--- `states` replace the sticky set: a key that changed is applied, the other non-default ones are
--- re-applied, defaults that did not change are left alone (another resource may own them).
function Player.setCached(payload)
    if type(payload) ~= 'table' then return false end
    cached = payload
    local incoming = payload.states
    if type(incoming) == 'table' then
        local ped = PlayerPedId()
        for key in pairs(STATE_DEFAULTS) do
            local value = incoming[key]
            if type(value) == 'boolean' and value ~= states[key] then
                states[key] = value
                applyState(ped, key, value)
            end
        end
        Player.reapplyStates(ped)
    end
    return true
end

-- a new ped entity (model swap, spawn, character switch) loses everything bound to the old one
Core.on('pedChanged', function(ped) Player.reapplyStates(ped) end)

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

-- opts = { withVehicle, fade } (§48), only sent when something differs from a plain faded teleport
Net.on('core:client:teleport', { 'vector3', 'number?', 'table?' }, function(coords, heading, opts)
    Core.Spawn.teleport(coords, heading, opts)
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
