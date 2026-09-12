--- core / client / main.lua
--- Boot (DESIGN §6.11): auto-spawn off, character load request, death watch, spawn handling,
--- the /tpm client command and the synchronous stop cleanup.

local Net = Core.Net
local Log = Core.Log
local UI = Core.UI
local Spawn = Core.Spawn
local Player = Core.Player

local LOAD_RETRY_MS <const> = 5000
local MAX_LOAD_TRIES <const> = 12
local DEATH_WATCH_MS <const> = 1000
local RESPAWN_RETRY_MS <const> = 5000
local MAX_RESPAWN_TRIES <const> = 12
local LOADING_KEY <const> = 'core:loading'
local RESPAWN_KEY <const> = 'core:respawn'

local loaded = false
local loadingShown = false
local deadSince = nil
local lastRespawnEmit = 0
local respawnTries = 0
local respawnFailed = false

local function clearDeathState()
    deadSince = nil
    lastRespawnEmit = 0
    respawnTries = 0
    respawnFailed = false
end

--- Character documents store the position as a plain table; fall back to the configured spawn point.
local function coordsFromPosition(position)
    if type(position) == 'table' then
        local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
        if x and y and z then
            return vector3(x, y, z), tonumber(position.heading) or 0.0
        end
    end
    local point = Config.Player.SpawnPoint
    return point.coords, point.heading or 0.0
end

local function hideLoadingText()
    if not loadingShown then return end
    loadingShown = false
    UI.textUI.hide()
end

CreateThread(function()
    -- spawnmanager is a base resource; a missing export raises, so the call is guarded
    if not pcall(function() exports.spawnmanager:setAutoSpawn(false) end) then
        Log.debug('spawnmanager unavailable, auto-spawn left untouched')
    end

    Core.emitHook('ready')

    local tries = 0
    while not loaded and tries < MAX_LOAD_TRIES do
        tries = tries + 1
        Net.emit('core:server:requestLoad')
        Wait(LOAD_RETRY_MS)
        if not loaded and not loadingShown then
            loadingShown = true
            UI.textUI.show(LOADING_KEY, Config.Texts.loading)
        end
    end

    if not loaded then
        hideLoadingText()
        Log.error('no core:client:loaded after %d requests - character not loaded', MAX_LOAD_TRIES)
    end
end)

--- payload = { charId, name, model, appearance, position, money, faction, group, respawn } (§4.2)
Net.on('core:client:loaded', { 'table' }, function(payload)
    loaded = true
    hideLoadingText()
    Player.setCached(payload)

    if payload.respawn then
        local coords, heading = coordsFromPosition(payload.position)
        Spawn.spawnPlayer({
            coords = coords,
            heading = heading,
            model = payload.model,
            appearance = payload.appearance,
        })
    end

    clearDeathState()
    Core.emitHook('playerLoaded')
    UI.hud.setVisible(Config.UI.HudEnabled)
end)

--- Server-driven spawn: first spawn, respawn after death and admin revives (§4.2).
Net.on('core:client:spawn', { 'vector3', 'number?', 'boolean?' }, function(coords, heading, respawn)
    if deadSince then UI.textUI.hide() end
    clearDeathState()

    Spawn.spawnPlayer({
        coords = coords,
        heading = heading or 0.0,
        model = Player.getData('model'),
        appearance = Player.getData('appearance'),
        resurrect = respawn ~= false,
    })

    Core.emitHook('playerRespawned')
end)

--- Death watch: one 1 s thread, countdown rendered from the same loop (§9).
CreateThread(function()
    while true do
        if loaded then
            local dead = IsPedDeadOrDying(PlayerPedId(), true)

            if dead and not deadSince then
                clearDeathState()
                deadSince = GetGameTimer()
                Net.emit('core:server:died')
                Core.emitHook('playerDied')
            elseif not dead and deadSince then
                clearDeathState()
                UI.textUI.hide()
            end

            if deadSince then
                local now = GetGameTimer()
                local remaining = Config.Respawn.DelayMs - (now - deadSince)
                if remaining > 0 then
                    UI.textUI.show(RESPAWN_KEY, (Config.Texts.respawn_in):format(math.ceil(remaining / 1000)))
                elseif respawnTries >= MAX_RESPAWN_TRIES then
                    if not respawnFailed then
                        respawnFailed = true
                        UI.textUI.hide()
                        Log.error('no core:client:spawn after %d respawn requests', MAX_RESPAWN_TRIES)
                    end
                elseif now - lastRespawnEmit >= RESPAWN_RETRY_MS then
                    respawnTries = respawnTries + 1
                    lastRespawnEmit = now
                    UI.textUI.show(RESPAWN_KEY, Config.Texts.respawn_now)
                    Net.emit('core:server:respawn')
                end
            end
        end

        Wait(DEATH_WATCH_MS)
    end
end)

-- Client commands cannot be ACE-restricted; core:server:teleportToWaypoint checks core.admin server-side.
RegisterCommand('tpm', function()
    local coords = Core.Blips.getWaypoint()
    if not coords then
        UI.notify({ message = 'No waypoint set', type = 'error' })
        return
    end
    Net.emit('core:server:teleportToWaypoint', coords)
end, false)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= Core.name then return end
    -- synchronous: releases NUI focus and hides pages, overlays and text UI
    pcall(UI.closeAll)
end)
