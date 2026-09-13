-- core/server/db.lua
-- Core.DB (DESIGN §4.1): collections of JSON documents kept in memory, written through to an adapter.
-- Default adapter = resource KVP (`doc:<collection>:<id>`), *NoSync writes + a flush timer.
-- Every document handed out is a deep copy; every document stored went through Core.Utils.jsonSafe.

local DB = {}
Core.DB = DB

local collections = {}          -- [name] = { docs = { [id] = doc }, loaded = true }
local degraded = {}             -- [name] = reason string when the backend could not be read or written
local loading = {}              -- [name] = promise while a load is in flight (one loader per collection)
local pendingWrites = false     -- something was put/removed since the last adapter flush
local running = true            -- stops the flush thread when core stops

local KEY_PREFIX <const> = (Config.DB and Config.DB.KeyPrefix) or 'doc:'
local FLUSH_INTERVAL <const> = (Config.DB and Config.DB.FlushIntervalMs) or 5000
local MAX_ID_LENGTH <const> = 64
local EXPORT_DIR <const> = 'data/'
local MAX_EXPORT_BYTES <const> = 32 * 1024 * 1024

local function isCollectionName(v)
    return type(v) == 'string' and #v >= 1 and #v <= 32 and v:match('^[%w_%-]+$') ~= nil
end

local function isDocumentId(v)
    return type(v) == 'string' and #v >= 1 and #v <= MAX_ID_LENGTH and v:match('^[%w_%-:]+$') ~= nil
end

-- KVP adapter (default) -----------------------------------------------------

local function kvpPrefix(collection)
    return KEY_PREFIX .. collection .. ':'
end

local kvpAdapter = {
    loadAll = function(collection)
        local out = {}
        local prefix = kvpPrefix(collection)
        local handle = StartFindKvp(prefix)
        if handle == -1 then return out end
        local key
        repeat
            key = FindKvp(handle)
            if key then
                local value = GetResourceKvpString(key)
                local id = key:sub(#prefix + 1)
                if value and id ~= '' then out[id] = value end
            end
        until not key
        EndFindKvp(handle)
        return out
    end,
    put = function(collection, id, encoded)
        SetResourceKvpNoSync(kvpPrefix(collection) .. id, encoded)
    end,
    remove = function(collection, id)
        DeleteResourceKvpNoSync(kvpPrefix(collection) .. id)
    end,
    flush = function()
        FlushResourceKvp()
    end,
}

local adapter = kvpAdapter

--- Replace the storage backend. adapter = { loadAll, put, remove, flush }; already loaded collections
--- are dropped so they are re-read from the new backend on next access.
function DB.setAdapter(newAdapter)
    if type(newAdapter) ~= 'table' then return false end
    for _, key in ipairs({ 'loadAll', 'put', 'remove', 'flush' }) do
        if type(newAdapter[key]) ~= 'function' then
            Core.Log.error('DB.setAdapter: adapter is missing %s()', key)
            return false
        end
    end
    adapter = newAdapter
    collections = {}
    degraded = {}
    loading = {}
    pendingWrites = false
    return true
end

local function writeDoc(collection, doc)
    doc.updatedAt = os.time()
    local ok, encoded = pcall(json.encode, doc)
    if not ok or type(encoded) ~= 'string' then
        Core.Log.error('DB: could not encode %s:%s (%s)', collection, tostring(doc.id), tostring(encoded))
        return false
    end
    adapter.put(collection, doc.id, encoded)
    pendingWrites = true
    return true
end

-- Migrations ----------------------------------------------------------------

local migrations = {}   -- [collection] = { { version = integer, fn = fn(doc) -> doc }, ... } ascending

--- Applies every registered migration newer than each document's `_v`, then persists what changed.
local function runMigrations(name, store)
    local list = migrations[name]
    if not list then return 0 end
    local changed = 0
    for id, doc in pairs(store.docs) do
        local version = math.type(doc._v) == 'integer' and doc._v or 0
        local updated = false
        for i = 1, #list do
            local step = list[i]
            if step.version > version then
                local ok, result = pcall(step.fn, doc)
                if not ok then
                    Core.Log.error('DB: migration %s v%d failed for %s: %s', name, step.version, tostring(id),
                        tostring(result))
                    break
                end
                if type(result) == 'table' and result ~= doc then
                    result.id = id
                    store.docs[id] = result
                    doc = result
                end
                doc._v = step.version
                updated = true
            end
        end
        if updated then
            writeDoc(name, doc)
            changed = changed + 1
        end
    end
    if changed > 0 then Core.Log.info('DB: migrated %d document(s) in %s', changed, name) end
    return changed
end

-- Collection access ---------------------------------------------------------

--- Reads one collection through the adapter. Returns nil when the backend could not be read: an empty
--- table would look like "no documents" and the next save would overwrite real rows.
local function loadCollection(name)
    local ok, raw, err = pcall(adapter.loadAll, name)
    if not ok then
        Core.Log.error('DB: loadAll(%s) threw: %s', name, tostring(raw))
        return nil
    end
    if type(raw) ~= 'table' then
        Core.Log.error('DB: loadAll(%s) failed: %s', name, tostring(err or 'the adapter returned no data'))
        return nil
    end
    local store = { docs = {}, loaded = true }
    local count = 0
    for id, encoded in pairs(raw) do
        local decoded
        if type(encoded) == 'string' and encoded ~= '' then
            decoded = json.decode(encoded)
        end
        if type(decoded) == 'table' then
            decoded.id = id
            store.docs[id] = decoded
            count = count + 1
        else
            Core.Log.warn('DB: dropping unreadable document %s:%s', name, tostring(id))
        end
    end
    runMigrations(name, store)
    Core.Log.debug('DB: loaded %d document(s) from %s', count, name)
    return store
end

--- Flags a collection as unusable and tells the server about it once.
local function markDegraded(name, reason)
    if degraded[name] then return end
    degraded[name] = reason or 'unknown'
    Core.Log.error('DB: collection %s is degraded (%s) — reads are empty and writes are refused',
        name, degraded[name])
    Core.emitHook('dbDegraded', name, degraded[name])
end

--- Lazily loads the collection on first access. `adapter.loadAll` may yield (mysql), so the first caller
--- parks a promise and every other caller waits for it instead of starting a second load.
--- Returns nil when the collection could not be read.
local function getStore(name)
    local store = collections[name]
    if store then return store end

    local pending = loading[name]
    if pending then
        local ok, err = pcall(Citizen.Await, pending)
        if not ok then
            Core.Log.error('DB: waiting for the %s load failed: %s', name, tostring(err))
        end
        return collections[name]
    end

    local barrier = promise.new()
    loading[name] = barrier
    local loaded = loadCollection(name)
    loading[name] = nil
    if loaded then
        collections[name] = loaded
        degraded[name] = nil
    else
        markDegraded(name, 'load failed')
    end
    barrier:resolve(true)
    return loaded
end

--- Store to write into, or nil (with an error logged) while the collection is degraded. getStore retries
--- a failed load first, so a backend that came back clears the flag by itself; a collection degraded by a
--- failed WRITE stays refused until the resource restarts (fix the backend, then restart).
local function writeStore(name)
    local store = getStore(name)
    if not store then
        Core.Log.error('DB: refusing to write to %s: it could not be read from the backend', name)
        return nil
    end
    if degraded[name] then
        Core.Log.error('DB: refusing to write to %s while it is degraded (%s)', name, degraded[name])
        return nil
    end
    return store
end

--- True while a collection could not be read (or a write to it failed).
function DB.isDegraded(collection)
    return degraded[collection] ~= nil
end

--- Called by an adapter when a backend operation failed (server/db_mysql.lua). Internal.
function DB.markDegraded(collection, reason)
    if not isCollectionName(collection) then return false end
    markDegraded(collection, type(reason) == 'string' and reason or 'adapter error')
    return true
end

-- Public API ----------------------------------------------------------------

--- Insert a new document. Assigns doc.id (uuid) and doc.createdAt when absent. Returns the id.
function DB.create(collection, doc)
    if not isCollectionName(collection) or type(doc) ~= 'table' then return nil end
    local stored = Core.Utils.jsonSafe(doc)
    local id = stored.id
    if id == nil then
        id = Core.Utils.uuid()
        stored.id = id
    end
    if not isDocumentId(id) then
        Core.Log.warn('DB.create: invalid document id for collection %s', collection)
        return nil
    end
    local store = writeStore(collection)
    if not store then return nil end
    if store.docs[id] then
        Core.Log.warn('DB.create: %s:%s already exists', collection, id)
        return nil
    end
    if stored.createdAt == nil then stored.createdAt = os.time() end
    store.docs[id] = stored
    if not writeDoc(collection, stored) then
        store.docs[id] = nil
        return nil
    end
    return id
end

--- A deep copy of the document, or nil.
function DB.get(collection, id)
    if not isCollectionName(collection) or not isDocumentId(id) then return nil end
    local store = getStore(collection)
    local doc = store and store.docs[id]
    if not doc then return nil end
    return Core.Utils.deepCopy(doc)
end

--- Replace the whole document (doc.id is forced to `id`). Creates it when missing.
function DB.set(collection, id, doc)
    if not isCollectionName(collection) or not isDocumentId(id) or type(doc) ~= 'table' then return false end
    local store = writeStore(collection)
    if not store then return false end
    local stored = Core.Utils.jsonSafe(doc)
    stored.id = id
    local previous = store.docs[id]
    if previous then
        if stored.createdAt == nil then stored.createdAt = previous.createdAt end
    elseif stored.createdAt == nil then
        stored.createdAt = os.time()
    end
    store.docs[id] = stored
    if not writeDoc(collection, stored) then
        store.docs[id] = previous
        return false
    end
    return true
end

--- Shallow merge of top-level keys (a nested table value replaces the old one). False if missing.
function DB.update(collection, id, partial)
    if not isCollectionName(collection) or not isDocumentId(id) or type(partial) ~= 'table' then return false end
    local store = writeStore(collection)
    if not store then return false end
    local doc = store.docs[id]
    if not doc then return false end
    local patch = Core.Utils.jsonSafe(partial)
    local backup = Core.Utils.deepCopy(doc)
    for key, value in pairs(patch) do
        if key ~= 'id' then doc[key] = value end
    end
    if not writeDoc(collection, doc) then
        store.docs[id] = backup
        return false
    end
    return true
end

--- Remove the document. False if it was not there.
function DB.delete(collection, id)
    if not isCollectionName(collection) or not isDocumentId(id) then return false end
    local store = writeStore(collection)
    if not store then return false end
    if not store.docs[id] then return false end
    store.docs[id] = nil
    adapter.remove(collection, id)
    pendingWrites = true
    return true
end

-- Queries -------------------------------------------------------------------

-- match = fn(doc) -> bool (in-VM callers only; functions do not survive the export hop) or a table of
-- top-level equalities. A function predicate gets the stored document and must not mutate it.
local function makePredicate(match)
    if Core.Utils.isCallable(match) then return match end
    if type(match) ~= 'table' then return nil end
    return function(doc)
        for key, value in pairs(match) do
            if doc[key] ~= value then return false end
        end
        return true
    end
end

local function each(collection, match, limit)
    local out = {}
    if not isCollectionName(collection) then return out end
    local predicate = makePredicate(match)
    local store = getStore(collection)
    if not store then return out end
    for _, doc in pairs(store.docs) do
        local hit = true
        if predicate then
            local ok, result = pcall(predicate, doc)
            hit = ok and result == true
        end
        if hit then
            out[#out + 1] = Core.Utils.deepCopy(doc)
            if limit and #out >= limit then break end
        end
    end
    return out
end

--- Array of deep copies of every matching document.
function DB.find(collection, match)
    return each(collection, match)
end

--- The first matching document, or nil.
function DB.findOne(collection, match)
    return each(collection, match, 1)[1]
end

--- Array of deep copies of the whole collection.
function DB.all(collection)
    return each(collection, nil)
end

--- Number of documents in the collection.
function DB.count(collection)
    if not isCollectionName(collection) then return 0 end
    local store = getStore(collection)
    if not store then return 0 end
    local n = 0
    for _ in pairs(store.docs) do n = n + 1 end
    return n
end

--- Push pending writes to disk now. No-op when nothing changed since the last flush.
function DB.flush()
    if not pendingWrites then return false end
    pendingWrites = false
    local ok, err = pcall(adapter.flush)
    if not ok then
        Core.Log.error('DB.flush failed: %s', tostring(err))
        return false
    end
    return true
end

-- Counters, migrations, export/import (DESIGN §22) ---------------------------

--- Persistent counter: document 'counters'/<name> holding { value }. Written on every call.
function DB.nextId(name)
    if not isDocumentId(name) then return nil end
    local store = writeStore('counters')
    if not store then return nil end
    local doc = store.docs[name]
    if not doc then
        doc = { id = name, value = 0, createdAt = os.time() }
        store.docs[name] = doc
    end
    local value = (math.type(doc.value) == 'integer' and doc.value or 0) + 1
    doc.value = value
    if not writeDoc('counters', doc) then return nil end
    return value
end

--- Register a migration for a collection. fn(doc) may mutate the document or return a new one; it runs
--- once per document whose `_v` is lower than `version`, in ascending version order, on first load.
function DB.migrate(collection, version, fn)
    if not isCollectionName(collection) or math.type(version) ~= 'integer' or version < 1 then return false end
    if not Core.Utils.isCallable(fn) then return false end
    local list = migrations[collection]
    if not list then
        list = {}
        migrations[collection] = list
    end
    for i = 1, #list do
        if list[i].version == version then
            -- A plugin restart replays its Core.onReady and registers the same version again: keep the
            -- newest function, quietly (documents below `version` were migrated on first load anyway).
            list[i].fn = fn
            Core.Log.debug('DB.migrate: %s v%d re-registered', collection, version)
            return true
        end
    end
    list[#list + 1] = { version = version, fn = fn }
    table.sort(list, function(a, b) return a.version < b.version end)
    local loaded = collections[collection]
    if loaded then
        Core.Log.warn('DB.migrate: %s was already loaded; applying v%d now', collection, version)
        runMigrations(collection, loaded)
    end
    return true
end

--- Every collection we know about: the loaded ones plus, on the KVP adapter, whatever the key scan finds.
local function discoverCollections()
    local names = {}
    for name in pairs(collections) do names[name] = true end
    if adapter ~= kvpAdapter then return names end
    local handle = StartFindKvp(KEY_PREFIX)
    if handle == -1 then return names end
    local key
    repeat
        key = FindKvp(handle)
        if key then
            local name = key:sub(#KEY_PREFIX + 1):match('^([^:]+):')
            if name and isCollectionName(name) then names[name] = true end
        end
    until not key
    EndFindKvp(handle)
    return names
end

--- Exports and imports live in core's own `data/` folder and are always .json: nothing else in the
--- resource (fxmanifest.lua, a script) can be written or read through these two calls.
local function isSafePath(path)
    return type(path) == 'string' and #path <= 128
        and path:sub(1, #EXPORT_DIR) == EXPORT_DIR and path:sub(-5) == '.json'
        and #path > #EXPORT_DIR + 5
        and not path:find('%.%.') and path:match('^[%w_%-%./]+$') ~= nil
end

--- Dump every collection to JSON inside the resource. Returns the path, or nil.
function DB.export(path)
    if path ~= nil and not isSafePath(path) then return nil end
    path = path or (EXPORT_DIR .. 'export-' .. os.time() .. '.json')
    local out, total = {}, 0
    for name in pairs(discoverCollections()) do
        local store = getStore(name)
        if store then
            local docs = {}
            for id, doc in pairs(store.docs) do
                docs[id] = Core.Utils.deepCopy(doc)
                total = total + 1
            end
            out[name] = docs
        else
            Core.Log.warn('DB.export: skipping %s, it could not be read', name)
        end
    end
    local ok, encoded = pcall(json.encode, { version = 1, exportedAt = os.time(), collections = out })
    if not ok or type(encoded) ~= 'string' then
        Core.Log.error('DB.export: encode failed (%s)', tostring(encoded))
        return nil
    end
    local bytes = #encoded
    Core.Log.info('DB.export: %d document(s), %d byte(s)', total, bytes)
    if bytes > MAX_EXPORT_BYTES then
        Core.Log.error('DB.export: %d bytes exceeds the %d byte limit — refusing to write %s',
            bytes, MAX_EXPORT_BYTES, path)
        return nil
    end
    if not SaveResourceFile(Core.name, path, encoded, -1) then
        Core.Log.error('DB.export: could not write %s', path)
        return nil
    end
    Core.Log.info('DB.export: wrote %s', path)
    return path
end

--- Read an export back in. mode 'merge' (default) keeps unknown documents, 'replace' empties each
--- imported collection first. Returns the number of documents written.
function DB.import(path, mode)
    if not isSafePath(path) then return 0 end
    mode = (mode == 'replace') and 'replace' or 'merge'
    local raw = LoadResourceFile(Core.name, path)
    if type(raw) ~= 'string' or raw == '' then
        Core.Log.error('DB.import: %s is missing or empty', path)
        return 0
    end
    local decoded = json.decode(raw)
    local payload = type(decoded) == 'table' and (decoded.collections or decoded) or nil
    if type(payload) ~= 'table' then
        Core.Log.error('DB.import: %s is not a valid export', path)
        return 0
    end
    local count = 0
    for name, docs in pairs(payload) do
        if isCollectionName(name) and type(docs) == 'table' then
            if mode == 'replace' then
                local store = getStore(name)
                local ids = {}
                if store then
                    for id in pairs(store.docs) do ids[#ids + 1] = id end
                end
                for i = 1, #ids do DB.delete(name, ids[i]) end
            end
            for id, doc in pairs(docs) do
                if isDocumentId(id) and type(doc) == 'table' and DB.set(name, id, doc) then
                    count = count + 1
                end
            end
        end
    end
    DB.flush()
    Core.Log.info('DB.import (%s): %d document(s) from %s', mode, count, path)
    return count
end

-- Console-only maintenance commands ------------------------------------------

Core.Commands.register('dbexport', {
    description = 'Write every collection to data/export-<timestamp>.json (server console only)',
    allowConsole = true,
}, function(src)
    if src ~= 0 then return end
    local path = DB.export()
    if not path then
        Core.Log.error('/dbexport failed')
        return
    end
    Core.Log.info('/dbexport wrote %s', path)
end)

Core.Commands.register('dbimport', {
    description = 'Import a JSON export from the core resource folder (server console only)',
    params = {
        { name = 'file', type = 'string', help = 'path inside the core resource, e.g. data/export-123.json' },
        { name = 'mode', type = 'string', optional = true, help = "'replace' wipes each collection first" },
    },
    allowConsole = true,
}, function(src, args)
    if src ~= 0 then return end
    DB.import(args.file, args.mode == 'replace' and 'replace' or 'merge')
end)

-- Flush timer: db.lua is the only owner of it, and it only touches the disk when something changed.
CreateThread(function()
    while running do
        Wait(FLUSH_INTERVAL)
        if running and pendingWrites then DB.flush() end
    end
end)

AddEventHandler('onResourceStart', function(res)
    if res == Core.name then running = true end
end)

-- Last chance to persist; synchronous on purpose (a stop handler may not Wait).
AddEventHandler('onResourceStop', function(res)
    if res ~= Core.name then return end
    running = false
    if not pendingWrites then return end
    pendingWrites = false
    pcall(adapter.flush)
end)
