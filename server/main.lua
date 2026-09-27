--- core/server/main.lua — boot, readiness flag, session restore after a restart and the
--- synchronous teardown. Loads last (DESIGN §4.9, §8, §56.1).
---
--- Boot waits for core's migrations (server/db.lua registered them at file scope): until they applied,
--- core is NOT ready — GlobalState['core:ready'] stays unset, no autosave runs and no session is restored.
--- A failed migration keeps it that way (loudly logged); fix the database and `restart core`.
--- Once ready, the players still connected after a `restart core` get their sessions back: ONE
--- Core.DB.flush() (every write the stopped core queued has committed), then reads WITHOUT sync on a
--- bounded pool of worker threads — 2,000 players load in about a second instead of one sync flush each.

local Log = Core.Log
local DB = Core.DB

local MIGRATION_WAIT_MS <const> = 120000
local RESTORE_WORKERS <const> = 12

--- After a core restart the players are already connected: give them a session again. `loadSession` is
--- internal to server/player.lua (block-listed in the export), so it is called defensively and the
--- `isLoaded` guard keeps it idempotent with a join that raced it. Yields until every worker finished.
local function loadConnectedSessions()
    local player = Core.Player
    local loadSession = player and rawget(player, 'loadSession')
    if type(loadSession) ~= 'function' then
        Log.debug('main: no Core.Player.loadSession, sessions load on playerJoining only')
        return 0
    end
    local players, list = GetPlayers(), {}
    for i = 1, #players do
        local src = tonumber(players[i])
        if src and not player.isLoaded(src) then list[#list + 1] = src end
    end
    if list[1] == nil then return 0 end
    local ok, err = DB.flush()
    if not ok then Log.warn('main: the flush before the session restore answered %s', tostring(err)) end
    local nextIndex, loaded, pending = 1, 0, math.min(RESTORE_WORKERS, #list)
    local done = promise.new()
    for _ = 1, pending do
        -- fxlint-disable-next-line P004 -- a bounded pool (RESTORE_WORKERS), once per core start
        CreateThread(function()
            while nextIndex <= #list do
                local src = list[nextIndex]
                nextIndex = nextIndex + 1
                if not player.isLoaded(src) and loadSession(src, false) then loaded = loaded + 1 end
            end
            pending = pending - 1
            if pending == 0 then done:resolve(true) end
        end)
    end
    if pending > 0 then Citizen.Await(done) end
    return loaded
end

--- The periodic work is owned by the modules themselves: server/player.lua runs the autosave loop
--- (Player.startAutosave is idempotent); core_db runs the write-behind queue.
local function startLoops()
    local start = rawget(Core.Player, 'startAutosave')
    if type(start) == 'function' then start() end
end

-- The runtime runs every event handler in its own thread (CreateThreadNow), so this one may wait for the
-- migrations and the session reads without holding up anything else.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= Core.name then return end
    local ok, err = DB.awaitMigrations(MIGRATION_WAIT_MS)
    if not ok then
        Log.error('core is NOT ready: its database migrations did not apply (%s). Check core_db and the '
            .. 'core_pg_url convar, then restart core (DESIGN §56.4).', tostring(err))
        return
    end
    GlobalState['core:ready'] = true
    startLoops()
    Core.emitHook('ready')
    Log.info('core %s ready', Core.version)
    -- the restore runs after `ready`: a client asking for its load meanwhile waits for its session (requestLoad)
    local loaded = loadConnectedSessions()
    if loaded > 0 then Log.info('restored %d session(s) after restart', loaded) end
end)

-- txAdmin's shutdown (server stop / restart) warns before `quit`: queue every session's state now — core_db
-- flushes on the same event (DESIGN §56.3.5), so position and playtime reach the database.
AddEventHandler('txAdmin:events:serverShuttingDown', function()
    Core.Player.saveAll()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    -- synchronous teardown: never Wait here, the resource is already stopping. saveAll only QUEUES its writes;
    -- core_db (a separate resource) commits them after core is gone, so there is no flush to wait for (§56.1).
    Core.Player.saveAll()
    local vehicles = Core.Vehicles.list()
    for i = 1, #vehicles do
        Core.Vehicles.delete(vehicles[i])
    end
    GlobalState['core:ready'] = false
end)
