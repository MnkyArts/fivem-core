--- core/server/main.lua — boot, readiness flag, session restore after a restart and the
--- synchronous teardown. Loads last (DESIGN §4.9, §8).

local Log = Core.Log

--- After a core restart the players are already connected: give them a session again.
--- `loadSession` is internal to server/player.lua, so it is called defensively and the
--- `isLoaded` guard keeps it idempotent with player.lua's own restart handling.
local function loadConnectedSessions()
    local player = Core.Player
    local loadSession = player and rawget(player, 'loadSession')
    if type(loadSession) ~= 'function' then
        Log.debug('main: no Core.Player.loadSession, sessions load on playerJoining only')
        return 0
    end
    local players = GetPlayers()
    local loaded = 0
    for i = 1, #players do
        local src = tonumber(players[i])
        if src and not Core.Player.isLoaded(src) then
            loadSession(src)
            loaded = loaded + 1
        end
    end
    return loaded
end

--- The periodic work is owned by the modules themselves: server/player.lua runs the
--- autosave loop (Player.startAutosave is idempotent) and server/db.lua runs the dirty-only
--- KVP flush timer. main.lua only makes sure the autosave loop is running after a restart.
local function startLoops()
    local start = rawget(Core.Player, 'startAutosave')
    if type(start) == 'function' then start() end
end

AddEventHandler('onResourceStart', function(resource)
    if resource ~= Core.name then return end
    GlobalState['core:ready'] = true
    startLoops()
    local loaded = loadConnectedSessions()
    if loaded > 0 then Log.info('restored %d session(s) after restart', loaded) end
    Core.emitHook('ready')
    Log.info('core %s ready', Core.version)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    -- synchronous teardown: never Wait here, the resource is already stopping
    Core.Player.saveAll()
    local vehicles = Core.Vehicles.list()
    for i = 1, #vehicles do
        Core.Vehicles.delete(vehicles[i])
    end
    Core.DB.flush()
    GlobalState['core:ready'] = false
end)
