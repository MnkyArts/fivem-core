--[[
    core/server/db.lua — core's migrations and /dbstatus (DESIGN §56.6, §56.11). Nothing else.

    `Core.DB` is the LIB (lib/db/server.lua, §56.5), compiled into every server VM by import.lua; it talks
    to the `core_db` resource (`dependency 'core_db'` in the manifest). This file registers core's schema at
    FILE SCOPE — `migrate` is synchronous and never yields — and server/main.lua waits for it
    (Core.DB.awaitMigrations) before core becomes ready. The Postgres URL is the convar `core_pg_url`, read
    by core_db only: nothing here ever sees or prints it.

    Natives: none (Core.DB, Core.Commands, Core.Log).
]]

local DB = Core.DB

local MIGRATIONS <const> = { 'sql/0001_core_schema.sql', 'sql/0002_core_legacy_import.sql' }

local registered, registerErr = DB.migrate(MIGRATIONS)
if not registered then
    Core.Log.error('DB: core\'s migrations could not be registered (%s) — core stays NOT ready; is core_db started?',
        tostring(registerErr))
end

local function count(value)
    return tostring(value == nil and '-' or value)
end

--- /dbstatus (server console only): health, pool, queue counters and the migration state per owner.
Core.Commands.register('dbstatus', {
    description = 'Database health, pool, write queue and migrations (server console only)',
    allowConsole = true,
}, function(src)
    if src ~= 0 then return end
    local status, err = DB.status()
    if type(status) ~= 'table' then
        Core.Log.error('/dbstatus: core_db did not answer (%s)', tostring(err))
        return
    end
    local pool = type(status.pool) == 'table' and status.pool or {}
    local queue = type(status.queue) == 'table' and status.queue or {}
    Core.Log.info('/dbstatus: %s', status.healthy == true and 'healthy' or 'UNHEALTHY')
    Core.Log.info('  pool: %s total, %s idle, %s waiting', count(pool.total), count(pool.idle), count(pool.waiting))
    Core.Log.info('  queue: %s pending, %s in flight, %s dropped, %s flushes, last flush %s ms%s',
        count(queue.pending), count(queue.inflight), count(queue.dropped), count(queue.flushes),
        count(queue.lastFlushMs), queue.lastError ~= nil and (', last error: ' .. tostring(queue.lastError)) or '')
    local owners = {}
    for owner in pairs(type(status.migrations) == 'table' and status.migrations or {}) do owners[#owners + 1] = owner end
    table.sort(owners)
    if owners[1] == nil then Core.Log.info('  migrations: none registered') end
    for i = 1, #owners do
        local entry = status.migrations[owners[i]]
        entry = type(entry) == 'table' and entry or {}
        Core.Log.info('  migrations %s: version %s (%s)', owners[i], count(entry.version), count(entry.state))
    end
end)
