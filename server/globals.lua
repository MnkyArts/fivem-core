--[[
    core/server/globals.lua — Core.Globals (DESIGN §22): a small, persisted key/value store for
    server-wide values (event state, counters, feature flags).

    Backed by the single Core.DB document `globals`/`server`:
        { id = 'server', values = { [key] = value }, mirror = { [key] = true } }

    `Globals.set(key, value, true)` additionally mirrors the value into GlobalState['g:<key>'] so
    clients can read it without a round trip; the mirror flag is persisted, so mirrored keys are
    republished after a restart. Server writes, clients read (§8) — no client ever writes these.

    Not a hot path: every set writes through Core.DB (KVP is buffered and flushed by db.lua's
    timer). Do not call it per tick; for per-player data use Core.Player.setData.
]]

local Globals = {}
Core.Globals = Globals

local Utils = Core.Utils
local Log = Core.Log

local COLLECTION <const> = 'globals'
local DOCUMENT <const> = 'server'
local MIRROR_PREFIX <const> = 'g:'
local MAX_KEY <const> = 64
local KEY_PATTERN <const> = '^[%w_%.%-:]+$'

local values                -- [key] = value, loaded from the document on first access
local mirror = {}           -- [key] = true for keys published to GlobalState
local loaded = false

--- A usable global key: short, printable, safe as a GlobalState key.
local function isKey(key)
    if type(key) ~= 'string' or #key < 1 or #key > MAX_KEY then return false end
    return key:match(KEY_PATTERN) ~= nil
end

--- Loads the document once. Missing document = empty store; nothing is written until the first set.
local function ensureLoaded()
    if loaded then return values end
    loaded = true
    local doc = Core.DB.get(COLLECTION, DOCUMENT)
    values = (doc and type(doc.values) == 'table') and doc.values or {}
    mirror = (doc and type(doc.mirror) == 'table') and doc.mirror or {}
    for key in pairs(mirror) do
        if isKey(key) and values[key] ~= nil then
            GlobalState[MIRROR_PREFIX .. key] = values[key]
        end
    end
    return values
end

--- Write-through; DB.set creates the document when it does not exist yet.
local function persist()
    if Core.DB.set(COLLECTION, DOCUMENT, { values = values, mirror = mirror }) then return true end
    Log.warn('globals: could not persist %s/%s', COLLECTION, DOCUMENT)
    return false
end

--- Publishes or clears the GlobalState mirror of one key.
local function publish(key)
    if not mirror[key] then return end
    GlobalState[MIRROR_PREFIX .. key] = values[key]
end

--- Stored value, or `default` when the key is unset. Tables come back as a deep copy.
function Globals.get(key, default)
    if not isKey(key) then return default end
    local store = ensureLoaded()
    local value = store[key]
    if value == nil then return default end
    if type(value) == 'table' then return Utils.deepCopy(value) end
    return value
end

--- Stores `value` (nil unsets). `mirrored = true` also writes GlobalState['g:' .. key].
function Globals.set(key, value, mirrored)
    if not isKey(key) then return false end
    local kind = type(value)
    if kind == 'function' or kind == 'thread' or kind == 'userdata' then return false end
    if value == nil then return Globals.unset(key) end
    local store = ensureLoaded()
    -- vectors and cycles cannot be persisted as JSON; store the safe form so the in-memory
    -- value and the document never drift apart.
    store[key] = (kind == 'table' or kind == 'vector3' or kind == 'vector2') and Utils.jsonSafe(value) or value
    if mirrored == true then mirror[key] = true end
    publish(key)
    return persist()
end

--- Adds `delta` (default 1) to a numeric global and returns the new value, or nil on a bad key
--- or a non-numeric current value. Unset keys start at 0.
function Globals.increment(key, delta)
    if not isKey(key) then return nil end
    local step = delta == nil and 1 or delta
    if type(step) ~= 'number' or step ~= step then return nil end
    local store = ensureLoaded()
    local current = store[key]
    if current == nil then current = 0 end
    if type(current) ~= 'number' then return nil end
    local value = current + step
    store[key] = value
    publish(key)
    persist()
    return value
end

--- Removes the key (and its GlobalState mirror). False when it was not set.
function Globals.unset(key)
    if not isKey(key) then return false end
    local store = ensureLoaded()
    if store[key] == nil then return false end
    store[key] = nil
    if mirror[key] then
        GlobalState[MIRROR_PREFIX .. key] = nil
        mirror[key] = nil
    end
    return persist()
end
