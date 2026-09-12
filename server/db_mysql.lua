-- core/server/db_mysql.lua
-- oxmysql adapter for Core.DB (DESIGN §27). Loads right after db.lua and, when active, replaces the KVP
-- adapter before any collection is read.
--
-- UNTESTED: this dev server has no MySQL and oxmysql is not installed, so nothing below has ever run
-- against a real database. The export names follow oxmysql's documented `query_async` / `execute` shape;
-- verify them against the oxmysql version you deploy before trusting this in production.
--
-- Activation: Config.DB.Adapter == 'mysql' AND GetResourceState('oxmysql') == 'started'.
-- Schema: core_documents(collection, id, data, updated_at), PRIMARY KEY (collection, id).

if (Config.DB and Config.DB.Adapter) ~= 'mysql' then return end

if GetResourceState('oxmysql') ~= 'started' then
    Core.Log.error('DB: Config.DB.Adapter is "mysql" but oxmysql is not started — staying on the KVP adapter')
    return
end

local TABLE_NAME <const> = 'core_documents'

local SCHEMA <const> = [[CREATE TABLE IF NOT EXISTS core_documents (
    collection VARCHAR(64) NOT NULL,
    id VARCHAR(64) NOT NULL,
    data LONGTEXT NOT NULL,
    updated_at BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (collection, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]]

local SELECT_ALL <const> = 'SELECT id, data FROM core_documents WHERE collection = ?'
local UPSERT <const> = 'INSERT INTO core_documents (collection, id, data, updated_at) VALUES (?, ?, ?, ?)'
    .. ' ON DUPLICATE KEY UPDATE data = VALUES(data), updated_at = VALUES(updated_at)'
local DELETE_ONE <const> = 'DELETE FROM core_documents WHERE collection = ? AND id = ?'

local schemaReady = false

--- CitizenFX promises expose :next through their metatable.
local function isPromise(value)
    return type(value) == 'table' and type(value.next) == 'function'
end

--- Calls one oxmysql export. `wait` resolves the promise the `_async` exports return, so the caller sees a
--- synchronous result; without it the query is fire-and-forget. Returns ok, result.
local function run(method, sql, params, wait)
    local ok, result = pcall(function()
        return exports.oxmysql[method](exports.oxmysql, sql, params or {})
    end)
    if not ok then
        Core.Log.error('db_mysql: oxmysql:%s failed: %s', method, tostring(result))
        return false, nil
    end
    if not wait or not isPromise(result) then
        return true, result
    end
    local awaited
    ok, awaited = pcall(Citizen.Await, result)
    if not ok then
        Core.Log.error('db_mysql: awaiting oxmysql:%s failed: %s', method, tostring(awaited))
        return false, nil
    end
    return true, awaited
end

--- CREATE TABLE IF NOT EXISTS, once. Must be called from inside a coroutine (it awaits).
local function ensureSchema()
    if schemaReady then return true end
    local ok = run('execute', SCHEMA, {}, true)
    schemaReady = ok
    if not ok then
        Core.Log.error('db_mysql: could not create %s — reads will come back empty', TABLE_NAME)
    end
    return ok
end

--- A fire-and-forget query still reports failures: attach a rejection handler that logs and degrades the
--- collection, so Core.DB stops writing into a backend that is not accepting them.
local function watch(result, collection, id, what)
    if not isPromise(result) then return end
    local ok, err = pcall(function()
        result:next(nil, function(rejection)
            Core.Log.error('db_mysql: %s failed for %s:%s: %s', what, collection, tostring(id),
                tostring(rejection))
            Core.DB.markDegraded(collection, 'mysql ' .. what .. ' failed')
        end)
    end)
    if not ok then
        Core.Log.debug('db_mysql: could not attach a rejection handler for %s (%s)', what, tostring(err))
    end
end

local adapter = {}

--- { [id] = jsonString } for one collection; synchronous from Core.DB's point of view.
--- Returns nil + a reason when the backend could not be read — never an empty table, which Core.DB would
--- read as "this collection is empty" and then overwrite the real rows on the next save.
function adapter.loadAll(collection)
    if not ensureSchema() then
        return nil, 'the core_documents table is not available'
    end
    local ok, rows = run('query_async', SELECT_ALL, { collection }, true)
    if not ok then
        return nil, 'the SELECT failed'
    end
    if type(rows) ~= 'table' then
        return nil, 'oxmysql returned no result set'
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
    local ok, result = run('execute', UPSERT, { collection, id, encoded, os.time() }, false)
    if not ok then
        Core.DB.markDegraded(collection, 'mysql upsert failed')
        return
    end
    watch(result, collection, id, 'upsert')
end

function adapter.remove(collection, id)
    local ok, result = run('execute', DELETE_ONE, { collection, id }, false)
    if not ok then
        Core.DB.markDegraded(collection, 'mysql delete failed')
        return
    end
    watch(result, collection, id, 'delete')
end

--- No-op: every put/remove already went to MySQL.
function adapter.flush()
end

if not Core.DB.setAdapter(adapter) then
    Core.Log.error('DB: oxmysql adapter was refused — staying on the KVP adapter')
    return
end

Core.Log.info('DB: oxmysql adapter active (table %s)', TABLE_NAME)

-- Create the table early so the first collection read does not pay for it (and so a broken schema shows up
-- in the console at start instead of on the first player join).
CreateThread(function()
    ensureSchema()
end)
