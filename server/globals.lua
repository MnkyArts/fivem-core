--[[
    core/server/globals.lua — Core.Globals (DESIGN §22, storage §56.6): a small, persisted key/value store for
    server-wide values (event state, counters, feature flags).

    Backed by the table `globals`: one row per key `{ key, value jsonb, mirror bool, updated_at }`. All rows
    are loaded ONCE (a small table) into `values` / `mirror`, which are then authoritative; every change is
    written behind with a queued `Core.DB.save('globals', { key, value, mirror })` / `Core.DB.remove`, so
    `set`/`increment`/`unset` never yield and `increment` stays atomic (read-modify-write in memory). A write
    the queue refuses is undone in memory and in GlobalState; NaN / ±inf are refused (no JSON form).

    `Globals.set(key, value, true)` additionally mirrors the value into GlobalState['g:<key>'] so
    clients can read it without a round trip; the mirror flag is persisted, so mirrored keys are
    republished when the rows load after a restart. Server writes, clients read (§8) — no client ever
    writes these.

    The first access loads (it yields: a thread, a handler or an export call); callers arriving during the
    load wait on the same barrier. A FAILED load is never "empty": get answers its default, set/increment/
    unset refuse (false / nil) and nothing is written until a retry (at most every 10 s, on the next access)
    has read the rows. Not a hot path: do not call it per tick; for per-player data use Core.Player.setData.
]]

local Globals = {}
Core.Globals = Globals

local Utils = Core.Utils
local Log = Core.Log
local DB = Core.DB

local TABLE <const> = 'globals'
local MIRROR_PREFIX <const> = 'g:'
local MAX_KEY <const> = 64
local KEY_PATTERN <const> = '^[%w_%.%-:]+$'
local LOAD_RETRY_S <const> = 10

local values = {}           -- [key] = value, authoritative once `loaded`
local mirror = {}           -- [key] = true for keys published to GlobalState
local loaded = false
local loading               -- the promise the first loader parks while the select is out (DESIGN §22)
local failedAt = nil        -- os.time() of the last failed load (retry throttle)

--- A usable global key: short, printable, safe as a GlobalState key.
local function isKey(key)
    if type(key) ~= 'string' or #key < 1 or #key > MAX_KEY then return false end
    return key:match(KEY_PATTERN) ~= nil
end

--- Loads every row once (ONE select, `sync` = after the queued writes of a previous core run). The first
--- caller parks a promise and every caller that arrives during the load waits for it — `loaded` only flips
--- once the rows are in memory. A failed read leaves memory untouched and `loaded` false (retried at most
--- every LOAD_RETRY_S seconds); a call outside a coroutine is not a failure (the next thread loads).
--- @return boolean loaded
local function ensureLoaded()
    if loaded then return true end
    if loading then
        local ok, err = pcall(Citizen.Await, loading)
        if not ok then Log.error('globals: waiting for the %s load failed: %s', TABLE, tostring(err)) end
        return loaded
    end
    if failedAt and os.time() - failedAt < LOAD_RETRY_S then return false end
    local barrier = promise.new()
    loading = barrier
    local ok, rows, err = pcall(DB.select, TABLE, nil, { sync = true })
    if not ok then rows, err = nil, rows end
    if type(rows) == 'table' then
        local v, m = {}, {}
        for i = 1, #rows do
            local row = rows[i]
            if type(row) == 'table' and isKey(row.key) and row.value ~= nil then
                v[row.key] = row.value
                if row.mirror == true then m[row.key] = true end
            end
        end
        values, mirror, loaded, failedAt = v, m, true, nil
    elseif err ~= 'not_in_coroutine' then
        Log.error('globals: could not read %s (%s); globals are unavailable until it loads', TABLE, tostring(err))
        failedAt = os.time()
    end
    loading = nil
    barrier:resolve(true)
    if loaded then
        for key in pairs(mirror) do
            GlobalState[MIRROR_PREFIX .. key] = values[key]
        end
    end
    return loaded
end

--- A finite number (NaN and ±inf have no JSON form: the row's value would be NULL and poison its flush).
local function isFinite(v)
    return v == v and v ~= math.huge and v ~= -math.huge
end

--- Publishes or clears the GlobalState mirror of one key.
local function publish(key)
    if not mirror[key] then return end
    GlobalState[MIRROR_PREFIX .. key] = values[key]
end

--- Makes the change of one key: memory, the GlobalState mirror, then the queued write (never yields; the
--- queue coalesces a burst of writes of that key). When the queue refuses the write (core_db stopped, a
--- validation error), memory and the mirror go back to what they were: memory never holds what the table
--- will not. `mirrored` = the key's mirror flag after the change.
--- @return boolean persisted
local function commit(key, value, mirrored)
    local oldValue, oldMirror = values[key], mirror[key]
    values[key], mirror[key] = value, mirrored or nil
    if oldMirror and not mirrored then GlobalState[MIRROR_PREFIX .. key] = nil end
    publish(key)
    local ok, err
    if value == nil then
        ok, err = DB.remove(TABLE, key)
    else
        ok, err = DB.save(TABLE, { key = key, value = value, mirror = mirrored == true })
    end
    if ok then return true end
    Log.warn('globals: could not persist %s (%s); the change is undone', key, tostring(err))
    values[key], mirror[key] = oldValue, oldMirror
    if mirrored and not oldMirror then GlobalState[MIRROR_PREFIX .. key] = nil end
    publish(key)
    return false
end

--- Stored value, or `default` when the key is unset (or the rows could not be read). Tables come back as a
--- deep copy.
function Globals.get(key, default)
    if not isKey(key) then return default end
    if not ensureLoaded() then return default end
    local value = values[key]
    if value == nil then return default end
    if type(value) == 'table' then return Utils.deepCopy(value) end
    return value
end

--- Stores `value` (nil unsets). `mirrored = true` also writes GlobalState['g:' .. key]. False on a bad key
--- or value (a function, NaN, ±inf), while the rows could not be read, or when the write could not be
--- queued (then nothing changed).
function Globals.set(key, value, mirrored)
    if not isKey(key) then return false end
    local kind = type(value)
    if kind == 'function' or kind == 'thread' or kind == 'userdata' then return false end
    if kind == 'number' and not isFinite(value) then return false end
    if value == nil then return Globals.unset(key) end
    if not ensureLoaded() then return false end
    -- vectors and cycles cannot be persisted as JSON; store the safe form so the in-memory
    -- value and the row never drift apart.
    local stored = (kind == 'table' or kind == 'vector3' or kind == 'vector2') and Utils.jsonSafe(value) or value
    return commit(key, stored, mirrored == true or mirror[key] == true)
end

--- Adds `delta` (default 1) to a numeric global and returns the new value, or nil on a bad key, a
--- non-numeric current value, a non-finite delta or sum, while the rows could not be read, or when the
--- write could not be queued (then nothing changed). Unset keys start at 0. Atomic: the sum is taken in
--- memory and the result queued.
function Globals.increment(key, delta)
    if not isKey(key) then return nil end
    local step = delta == nil and 1 or delta
    if type(step) ~= 'number' or not isFinite(step) then return nil end
    if not ensureLoaded() then return nil end
    local current = values[key]
    if current == nil then current = 0 end
    if type(current) ~= 'number' then return nil end
    local value = current + step
    if not isFinite(value) then return nil end
    if not commit(key, value, mirror[key] == true) then return nil end
    return value
end

--- Removes the key (and its GlobalState mirror). False when it was not set, while the rows could not be
--- read, or when the delete could not be queued (then the key stays).
function Globals.unset(key)
    if not isKey(key) then return false end
    if not ensureLoaded() then return false end
    if values[key] == nil then return false end
    return commit(key, nil, false)
end
