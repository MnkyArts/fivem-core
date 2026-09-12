-- core/server/db_pg.lua
-- Postgres adapter for Core.DB (DESIGN §33). Loads right after db_mysql.lua and, when active,
-- replaces the KVP adapter before any collection is read.
--
-- Activation: Config.DB.Adapter == 'postgres' AND a non-empty `core_pg_url` convar (the URL itself
-- stays in server.cfg and is only ever read by server/db_pg.js — never logged, never stored here).
-- Every statement goes through the Node bridge `exports.core:pgQuery(sql, params, cb)`; a second
-- export, `pgStatus(cb)`, is there for console/admin use and is not needed by this adapter.
-- Schema: core_documents(collection, id, data jsonb, updated_at), PRIMARY KEY (collection, id).
--
-- Natives: GetConvar (shared).

if (Config.DB and Config.DB.Adapter) ~= 'postgres' then return end

if GetConvar('core_pg_url', '') == '' then
    Core.Log.error('DB: Config.DB.Adapter is "postgres" but core_pg_url is empty — staying on KVP')
    return
end

local TABLE_NAME <const> = 'core_documents'
local QUERY_TIMEOUT_MS <const> = 10000

local SCHEMA <const> = [[CREATE TABLE IF NOT EXISTS core_documents (
    collection text   NOT NULL,
    id         text   NOT NULL,
    data       jsonb  NOT NULL,
    updated_at bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (collection, id)
)]]

local SELECT_ALL <const> = 'SELECT id, data::text AS data FROM core_documents WHERE collection = $1'
local UPSERT <const> = 'INSERT INTO core_documents (collection, id, data, updated_at)'
    .. ' VALUES ($1, $2, $3::jsonb, $4)'
    .. ' ON CONFLICT (collection, id) DO UPDATE SET data = EXCLUDED.data, updated_at = EXCLUDED.updated_at'
local DELETE_ONE <const> = 'DELETE FROM core_documents WHERE collection = $1 AND id = $2'

local schemaReady = false
local schemaPending = nil   -- promise while the first caller runs CREATE TABLE
local exportBroken = false

--- Calls the Node bridge. Returns false when the export itself is unreachable (Node runtime not up
--- yet, resource stopping, export refused); only the first such failure is logged.
local function callExport(sql, params, cb)
    local ok, err = pcall(function()
        return exports.core:pgQuery(sql, params, cb)
    end)
    if ok then return true end
    if not exportBroken then
        exportBroken = true
        Core.Log.error('db_pg: the pgQuery export is unusable (%s) — is server/db_pg.js loaded?',
            tostring(err))
    end
    return false
end

--- Runs one statement and waits for the answer (QUERY_TIMEOUT_MS deadline). Returns err, rows —
--- err is nil on success. Must be called from inside a coroutine: it may yield.
local function query(sql, params)
    local barrier = promise.new()
    local settled = false
    local function settle(err, rows)
        if settled then return end
        settled = true
        barrier:resolve({ err = err, rows = rows })
    end

    SetTimeout(QUERY_TIMEOUT_MS, function()
        settle(('no answer within %d ms'):format(QUERY_TIMEOUT_MS))
    end)
    if not callExport(sql, params or {}, settle) then
        settle('the pgQuery export is not available')
    end

    local ok, result = pcall(Citizen.Await, barrier)
    if not ok then
        return 'awaiting the query failed: ' .. tostring(result), nil
    end
    if type(result) ~= 'table' then
        return 'the query returned no answer', nil
    end
    return result.err, result.rows
end

--- CREATE TABLE IF NOT EXISTS, once. Concurrent callers park on the same promise instead of
--- starting a second CREATE; a failure is retried on the next access (the backend may come back).
local function ensureSchema()
    if schemaReady then return true end

    local pending = schemaPending
    if pending then
        local ok, value = pcall(Citizen.Await, pending)
        if not ok then
            Core.Log.error('db_pg: waiting for the schema check failed: %s', tostring(value))
            return false
        end
        return value == true
    end

    local barrier = promise.new()
    schemaPending = barrier
    local err = query(SCHEMA, {})
    schemaReady = err == nil
    schemaPending = nil
    if not schemaReady then
        Core.Log.error('db_pg: could not create %s (%s) — reads will come back empty', TABLE_NAME,
            tostring(err))
    end
    barrier:resolve(schemaReady)
    return schemaReady
end

--- Reports a failed fire-and-forget write: Core.DB stops writing into a backend that refuses them.
local function degrade(collection, id, what, err)
    Core.Log.error('db_pg: %s failed for %s:%s: %s', what, collection, tostring(id), tostring(err))
    Core.DB.markDegraded(collection, 'postgres ' .. what .. ' failed')
end

local adapter = {}

--- { [id] = jsonString } for one collection; synchronous from Core.DB's point of view.
--- Returns nil + a reason when the backend could not be read — never an empty table, which Core.DB
--- would read as "this collection is empty" and then overwrite the real rows on the next save.
function adapter.loadAll(collection)
    if not ensureSchema() then
        return nil, 'the core_documents table is not available'
    end
    local err, rows = query(SELECT_ALL, { collection })
    if err then
        return nil, 'the SELECT failed: ' .. tostring(err)
    end
    if type(rows) ~= 'table' then
        return nil, 'postgres returned no result set'
    end
    local out = {}
    for i = 1, #rows do
        local row = rows[i]
        if type(row) == 'table' and type(row.id) == 'string' and type(row.data) == 'string' then
            out[row.id] = row.data
        end
    end
    return out
end

--- Write-through upsert; not awaited, so a document write never blocks the caller.
function adapter.put(collection, id, encoded)
    local ok = callExport(UPSERT, { collection, id, encoded, os.time() }, function(err)
        if err then degrade(collection, id, 'upsert', err) end
    end)
    if not ok then
        degrade(collection, id, 'upsert', 'the pgQuery export is not available')
    end
end

function adapter.remove(collection, id)
    local ok = callExport(DELETE_ONE, { collection, id }, function(err)
        if err then degrade(collection, id, 'delete', err) end
    end)
    if not ok then
        degrade(collection, id, 'delete', 'the pgQuery export is not available')
    end
end

--- No-op: every put/remove already went to Postgres.
function adapter.flush()
end

if not Core.DB.setAdapter(adapter) then
    Core.Log.error('DB: the postgres adapter was refused — staying on the KVP adapter')
    return
end

Core.Log.info('DB: postgres adapter active (%s)', TABLE_NAME)

-- Create the table early so the first collection read does not pay for it (and so a broken
-- connection shows up in the console at start instead of on the first player join).
CreateThread(function()
    ensureSchema()
end)
