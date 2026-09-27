--[[
    core/server/settings.lua — Core.Settings (DESIGN §45): runtime-editable, schema-validated settings
    that any plugin declares; a generic UI (the admin plugin) lists and edits them.

      Settings.define({ id, title?, icon?, order?, properties = { ['<id>.<key>'] = prop } }) -> bool, err
      Settings.get(key) -> value                          effective: override > config > default
      Settings.set(key, value, actorSrc?, reason?) -> bool, err
      Settings.reset(key, actorSrc?, reason?) -> bool, err
      Settings.inspect(key) -> { value, default, config, override, source, ... } | nil
      Settings.list(viewerSrc?) -> sections
      Settings.onChange(prefix, fn(key, new, old)) -> handle;  Settings.offChange(handle) -> bool

    A property is a Core.Schema field (§43) plus the settings keys `scope` ('server' only), `edit`, `view`,
    `replicate`, `restart`, `deprecated` and `config`. Sections are owner-tracked (Registry kind
    'settings'); their definitions go when the owner stops, their overrides stay in the DB and apply
    again on the next define. Watchers are owner-tracked too (kind 'settingsWatch').

    Storage: table `settings` (§56.6), one row per OVERRIDE: `key` (dotted), `value` jsonb (any JSON value,
    `false` and tables included), `updated_by` jsonb (the `by` table), `updated_at`. Loaded once with ONE
    select, behind the same barrier as server/globals.lua (§22): the load yields and every caller arriving
    meanwhile waits on it; a failed load (driven by the DB error) leaves `get` on config/default and makes
    `set`/`reset` answer 'unavailable' until a retry (≥ 10 s later) succeeds. `set` is an awaited upsert and
    `reset` an awaited delete (the caller learns 'persist' when the write failed; memory changes only after
    the write committed; writes of one key never overlap). `get`/`set` therefore belong in a thread, a
    handler or an export call — as always.

    Replication: `replicate = true` keys are mirrored to GlobalState['cs:<key>'] and the sorted key list
    to GlobalState['cs:keys'] (the client's seed, client/settings.lua). Writes go through one paced
    queue (the state-bag budget, like server/doors.lua); each write is skipped when the value did not
    change. Settings changes are rare admin actions, never per player or per tick.

    Natives: none (GlobalState, CreateThread, Wait, AddEventHandler are runtime helpers).
]]

local Settings = {}
Core.Settings = Settings

local Log = Core.Log
local Utils = Core.Utils
local Schema = Core.Schema
local Registry = Core.Registry
local DB = Core.DB

local TABLE <const> = 'settings'
local KIND <const> = 'settings'
local WATCH_KIND <const> = 'settingsWatch'
local STATE_PREFIX <const> = 'cs:'
local INDEX_KEY <const> = 'cs:keys'          -- never a setting key: those always contain a dot
local DEFAULT_EDIT <const> = 'core.admin'
local DEFAULT_VIEW <const> = 'core.settings.view'
local MASK <const> = '••••'
local ID_PATTERN <const> = '^[%a_][%w_]*$'
local ID_MAX <const> = 32
local KEY_MAX <const> = 64
local PERM_PATTERN <const> = '^[%w_%.%-:]+$'
local PERM_MAX <const> = 64
local MAX_PROPERTIES <const> = 128
local TITLE_MAX <const> = 64
local ICON_MAX <const> = 32
local REASON_MAX <const> = 256
local PUBLISH_BATCH <const> = 40             -- GlobalState keys per drain pass (DESIGN §9, doors §16)
local PUBLISH_INTERVAL_MS <const> = 1000
local LOAD_RETRY_S <const> = 10
local SETTING_KEYS <const> = {               -- property keys that are not part of the schema field
    scope = true, edit = true, view = true, replicate = true, restart = true, deprecated = true,
    config = true, name = true,
}

local sections = {}      -- [id] = { id, title, icon, order, owner, keys = { sorted keys } }
local defs = {}          -- [key] = { key, section, owner, field, edit, view, replicate, secret, restart, ... }
local overrides = {}     -- [key] = { value, updatedAt, by, checkedFor, valid, norm } (defined or not)
local watchers = {}      -- [handle] = { id, prefix, fn, owner }
local nextWatch = 0
local running = {}       -- [key] = { [owner] = depth }: onChange handlers in flight (recursion guard)

local loaded = false
local loading            -- the promise the first loader parks while the select is out
local failedAt = nil     -- os.time() of the last failed load (retry throttle)
local served = false     -- a value was answered (get/inspect/list) before the overrides loaded
local retrying = false   -- the retry thread is waiting (after a failed load)
local stopped = false    -- core is stopping: the retry thread ends
local writing = {}       -- [key] = promise while a set/reset of that key is being written
local late = {}          -- snapshot / afterLoad / scheduleRetry: defined below the loader that calls them

local publishQueue = {}  -- [key] = true: the drain writes the CURRENT effective value
local published = {}     -- [key] = { value } last value written to GlobalState
local indexed = {}       -- [key] = true: listed in GlobalState['cs:keys']
local indexDirty = false
local draining = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function isFinite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function isSectionId(v)
    return type(v) == 'string' and #v <= ID_MAX and v:find(ID_PATTERN) ~= nil
end

--- '<id>.<segment>(.<segment>)*', every segment [%w_]+, at most 64 bytes.
local function isKey(v)
    if type(v) ~= 'string' or #v > KEY_MAX then return false end
    if not v:find('^[%a_][%w_]*%.[%w_%.]*[%w_]$') then return false end
    return v:find('..', 1, true) == nil
end

local function isPerm(v)
    return type(v) == 'string' and #v <= PERM_MAX and v:find(PERM_PATTERN) ~= nil
end

--- Console (0) or a server id; anything else is refused before it reaches Perms.
local function toActor(v)
    if v == 0 then return 0 end
    if type(v) ~= 'number' or v ~= v or v % 1 ~= 0 or v < 1 or v > 65535 then return nil end
    return math.tointeger(v)
end

local function copy(v)
    if type(v) == 'table' then return Utils.deepCopy(v) end
    return v
end

--- Plain-data equality (settings values are JSON-shaped: scalars and tables of scalars).
local function deepEqual(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function masked(def, value)
    if def.secret and value ~= nil then return MASK end
    return copy(value)
end

--------------------------------------------------------------------------------
-- Overrides: load once (async barrier, DESIGN §22) and resolve
--------------------------------------------------------------------------------

--- Loads every stored override (ONE select; `sync` = after this core's own queued writes). Returns true
--- once they are in memory. A failed read (`nil, err` — never "no overrides") leaves `loaded` false and
--- memory untouched — get() then answers config/default, set() refuses — and is retried by the next
--- caller at most every LOAD_RETRY_S seconds (`force` skips that throttle), by a retry thread and on the
--- `dbStatus` hook. A call outside a coroutine ('not_in_coroutine') is not a failure: the next caller in a
--- thread loads. A load that lands after values were answered without the overrides republishes and
--- dispatches what changed (afterLoad).
local function ensureLoaded(force)
    if loaded then return true end
    if loading then
        local ok, err = pcall(Citizen.Await, loading)
        if not ok then Log.error('settings: waiting for the %s load failed: %s', TABLE, tostring(err)) end
        return loaded
    end
    if not force and failedAt and os.time() - failedAt < LOAD_RETRY_S then return false end
    local barrier = promise.new()
    loading = barrier
    local ok, rows, err = pcall(DB.select, TABLE, nil, { sync = true })
    if not ok then rows, err = nil, rows end
    local before = nil
    if type(rows) == 'table' then
        if served then before = late.snapshot() end     -- what was answered so far (config/default)
        for i = 1, #rows do
            local row = rows[i]
            -- a JSON null value is no override (the old store skipped value-less documents too)
            if type(row) == 'table' and isKey(row.key) and row.value ~= nil and overrides[row.key] == nil then
                overrides[row.key] = { value = row.value, updatedAt = row.updated_at, by = row.updated_by }
            end
        end
        loaded, failedAt = true, nil
    elseif err ~= 'not_in_coroutine' then
        Log.error('settings: could not read %s (%s); overrides are not applied until it loads', TABLE, tostring(err))
        failedAt = os.time()
        late.scheduleRetry()
    end
    loading = nil
    barrier:resolve(true)
    if loaded then late.afterLoad(before) end
    return loaded
end

--- After a failed load: one thread retries every LOAD_RETRY_S seconds until the overrides are in (the
--- `dbStatus` hook retries at once when the database comes back).
function late.scheduleRetry()
    if retrying or stopped then return end
    retrying = true
    CreateThread(function()
        while not loaded and not stopped do
            Wait(LOAD_RETRY_S * 1000)
            if loaded or stopped then break end
            ensureLoaded(true)
        end
        retrying = false
    end)
end

--- Effective value and its source. Internal tables — callers copy. A stored override that no longer
--- passes the field (the owner tightened a bound) is ignored with one warning per definition.
local function resolve(key)
    local def = defs[key]
    if not def then return nil, nil end
    local o = overrides[key]
    if o then
        if o.checkedFor ~= def then
            local ok, value = Schema.check(def.field, o.value)
            o.checkedFor, o.valid, o.norm = def, ok, nil
            if ok then
                o.norm = value                     -- never `ok and value or nil`: false is a real value
            else
                Log.warn('settings: the stored override of %s is not valid any more (%s) and is ignored',
                    key, tostring(value))
            end
        end
        if o.valid then return o.norm, 'override' end
    end
    if def.config ~= nil then return def.config, 'config' end
    return def.field.default, 'default'
end

--------------------------------------------------------------------------------
-- Replication: one paced queue into GlobalState
--------------------------------------------------------------------------------

--- Writes at most PUBLISH_BATCH keys; the index goes last, once the queue is empty.
--- Returns true while work is left. Nothing yields inside.
local function drainOnce()
    local written = 0
    for key in pairs(publishQueue) do
        publishQueue[key] = nil
        local def = defs[key]
        if def and def.replicate then
            if not indexed[key] then indexed[key], indexDirty = true, true end
            local value = resolve(key)
            local last = published[key]
            if not last or not deepEqual(last.value, value) then
                GlobalState[STATE_PREFIX .. key] = value
                published[key] = { value = copy(value) }
                written = written + 1
            end
        else
            if indexed[key] then indexed[key], indexDirty = nil, true end
            if published[key] then
                GlobalState[STATE_PREFIX .. key] = nil
                published[key] = nil
                written = written + 1
            end
        end
        if written >= PUBLISH_BATCH then break end
    end
    if next(publishQueue) ~= nil then return true end
    if indexDirty then
        indexDirty = false
        local list = {}
        for key in pairs(indexed) do list[#list + 1] = key end
        table.sort(list)
        GlobalState[INDEX_KEY] = list
    end
    return false
end

--- Queues a key whose replicated value may have changed (or that stopped replicating).
local function queuePublish(key)
    publishQueue[key] = true
    if draining then return end
    draining = true
    -- exactly one drain thread; it ends as soon as the queue runs dry
    -- fxlint-disable-next-line P004
    CreateThread(function()
        ensureLoaded()            -- the effective value needs the overrides
        while drainOnce() do
            Wait(PUBLISH_INTERVAL_MS)
        end
        draining = false
    end)
end

--------------------------------------------------------------------------------
-- Change dispatch, recursion guard, audit
--------------------------------------------------------------------------------

local function enter(key, owner)
    local byOwner = running[key]
    if not byOwner then
        byOwner = {}
        running[key] = byOwner
    end
    byOwner[owner] = (byOwner[owner] or 0) + 1
end

local function leave(key, owner)
    local byOwner = running[key]
    if not byOwner then return end
    local depth = (byOwner[owner] or 1) - 1
    byOwner[owner] = depth > 0 and depth or nil
    if next(byOwner) == nil then running[key] = nil end
end

--- A set of K by a resource whose onChange handler for K is running right now.
local function isRecursive(key, caller)
    local byOwner = running[key]
    return byOwner ~= nil and byOwner[caller] ~= nil
end

--- Runs every matching watcher in ONE new thread, in registration order, after persist.
local function dispatch(key, new, old)
    local list = {}
    for _, w in pairs(watchers) do
        if key:sub(1, #w.prefix) == w.prefix then list[#list + 1] = w end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b) return a.id < b.id end)
    CreateThread(function()
        for i = 1, #list do
            local w = list[i]
            if watchers[w.id] == w then            -- an earlier handler may have removed it
                enter(key, w.owner)
                local ok, err = pcall(w.fn, key, copy(new), copy(old))
                leave(key, w.owner)
                if not ok then
                    Log.warn('settings: onChange handler of %s failed for %s: %s', w.owner, key, tostring(err))
                end
            end
        end
    end)
end

--- Every defined key's effective value as answered BEFORE the overrides loaded (config/default).
function late.snapshot()
    local out = {}
    for key in pairs(defs) do out[key] = { value = copy((resolve(key))) } end
    return out
end

--- Once the overrides are in: every replicated key is queued (the drain skips unchanged values), and when
--- values were answered without them (`before`, a late load after a failed one) every key whose effective
--- value differs is dispatched to the watchers — a module that read a default during the outage (bans'
--- tokenMatches) hears the stored value.
function late.afterLoad(before)
    served = false
    for key, def in pairs(defs) do
        if def.replicate then queuePublish(key) end
    end
    if not before then return end
    for key, was in pairs(before) do
        if defs[key] then
            local now = resolve(key)
            if not deepEqual(was.value, now) then dispatch(key, now, was.value) end
        end
    end
end

--- Who wrote an override (stored with it).
local function actorInfo(actor, caller)
    if actor == nil then return { kind = 'resource', resource = caller } end
    if actor == 0 then return { kind = 'console' } end
    local Player = Core.Player
    local info = Player and Player.getInfo and Player.getInfo(actor)
    return {
        kind = 'player', src = actor,
        accountId = info and info.accountId or nil,
        name = Player and Player.getName and Player.getName(actor) or nil,
    }
end

--- One audit row per set/reset (§46), secret values masked. Core.Audit may not exist (older core,
--- or audit.lua failed): then nothing is recorded, the setting still changes.
local function audit(def, op, actor, reason, old, new, result)
    local Audit = Core.Audit
    if not (Audit and Audit.record) then return end
    local ok, err = pcall(Audit.record, {
        actor = actor or 'system',
        action = 'settings.set',
        source = actor ~= nil and 'api' or 'core',
        targets = { { type = 'setting', id = def.key } },
        changes = { { key = def.key, old = masked(def, old), new = masked(def, new) } },
        reason = reason,
        ctx = { op = op, section = def.section },
        result = result,
        message = result == 'denied' and 'permission' or nil,
    })
    if not ok then Log.warn('settings: audit record failed for %s: %s', def.key, tostring(err)) end
end

--------------------------------------------------------------------------------
-- Definitions
--------------------------------------------------------------------------------

--- One property -> the internal definition, or nil + err. The schema part goes through Core.Schema;
--- a config value that fails it falls back to the default with a warning (never refuses the define).
local function buildDef(key, prop, id, owner)
    if type(prop) ~= 'table' then return nil, 'property' end
    local scope = prop.scope == nil and 'server' or prop.scope
    if scope ~= 'server' then return nil, 'scope' end        -- faction/player scopes are not implemented
    for _, flag in ipairs({ 'replicate', 'restart', 'deprecated' }) do
        if prop[flag] ~= nil and type(prop[flag]) ~= 'boolean' then return nil, flag end
    end
    if prop.edit ~= nil and not isPerm(prop.edit) then return nil, 'edit' end
    if prop.view ~= nil and not isPerm(prop.view) then return nil, 'view' end
    if prop.secret == true and prop.replicate == true then return nil, 'secret_replicate' end
    local schemaDef = {}
    for k, v in pairs(prop) do
        if not SETTING_KEYS[k] then schemaDef[k] = v end
    end
    local field, err = Schema.field(schemaDef)
    if not field then return nil, err end
    local config
    if prop.config ~= nil then
        local ok, value = Schema.check(field, prop.config)
        if ok then
            config = value
        else
            Log.warn('settings: %s: the config value is refused (%s), using the default', key, tostring(value))
        end
    end
    return {
        key = key, section = id, owner = owner, field = field, scope = scope,
        edit = prop.edit, view = prop.view, config = config,
        replicate = prop.replicate == true, secret = field.secret == true,
        restart = prop.restart == true, deprecated = prop.deprecated == true,
    }
end

local function dropKey(key)
    local def = defs[key]
    if not def then return end
    defs[key] = nil
    if def.replicate then queuePublish(key) end
end

local function removeSection(id)
    local section = sections[id]
    if not section then return end
    sections[id] = nil
    for i = 1, #section.keys do dropKey(section.keys[i]) end
end

--- Declares (or, for the same owner, replaces) a section. Every key must start with '<id>.'.
---@return boolean ok, string|nil err
function Settings.define(def)
    if type(def) ~= 'table' then return false, 'def' end
    local id = def.id
    if not isSectionId(id) then return false, 'id' end
    local title = def.title == nil and id or def.title
    if type(title) ~= 'string' or #title == 0 or #title > TITLE_MAX then return false, 'title' end
    if def.icon ~= nil and (type(def.icon) ~= 'string' or #def.icon > ICON_MAX) then return false, 'icon' end
    if def.order ~= nil and not isFinite(def.order) then return false, 'order' end
    if type(def.properties) ~= 'table' then return false, 'properties' end
    local owner = Registry.getCaller()
    local current = sections[id]
    if current and current.owner ~= owner then return false, 'owner' end
    local prefix = id .. '.'
    local built, keys = {}, {}
    for key, prop in pairs(def.properties) do
        if #keys >= MAX_PROPERTIES then return false, 'properties' end
        if not isKey(key) or key:sub(1, #prefix) ~= prefix then
            return false, 'key:' .. tostring(key):sub(1, KEY_MAX)
        end
        local other = defs[key]
        if other and other.owner ~= owner then return false, 'owner:' .. key end
        local entry, err = buildDef(key, prop, id, owner)
        if not entry then return false, key .. ':' .. err end
        built[key] = entry
        keys[#keys + 1] = key
    end
    if #keys == 0 then return false, 'properties' end
    table.sort(keys, function(a, b)
        local oa, ob = built[a].field.order or 0, built[b].field.order or 0
        if oa ~= ob then return oa < ob end
        return a < b
    end)
    if current then
        for i = 1, #current.keys do
            local key = current.keys[i]
            if not built[key] then dropKey(key) end
        end
    end
    for i = 1, #keys do
        local key = keys[i]
        local old = defs[key]
        defs[key] = built[key]
        if built[key].replicate or (old and old.replicate) then queuePublish(key) end
    end
    sections[id] = {
        id = id, title = title, icon = def.icon, order = def.order or 0, owner = owner, keys = keys,
    }
    Registry.track(KIND, id, owner)
    return true
end

Registry.onOwnerStop(KIND, function(id)
    removeSection(id)
end)

--------------------------------------------------------------------------------
-- Reading
--------------------------------------------------------------------------------

--- The effective value (override > config > default); tables come back as a deep copy.
--- Undefined keys answer nil. May yield once, while the overrides load on an async backend.
function Settings.get(key)
    if type(key) ~= 'string' or not defs[key] then return nil end
    if not ensureLoaded() then served = true end   -- a config/default answer: a later load dispatches changes
    return copy((resolve(key)))
end

--- (internal, block-listed in server/api.lua) Are the stored overrides in memory? False while the first
--- load is out or failed — every value answered meanwhile is config/default. server/audit.lua never prunes
--- with limits read in that state.
function Settings.isLoaded()
    return loaded
end

--- Every layer of one key. Secret values are masked here too: `get` is the only way to read one.
function Settings.inspect(key)
    if type(key) ~= 'string' or not defs[key] then return nil end
    if not ensureLoaded() then served = true end
    local def = defs[key]
    if not def then return nil end
    local value, source = resolve(key)
    local o = overrides[key]
    local override = nil
    if o then override = masked(def, o.value) end
    return {
        key = key,
        value = masked(def, value),
        default = masked(def, def.field.default),
        config = masked(def, def.config),
        override = override,
        source = source,
        updatedAt = o and o.updatedAt or nil,
        by = o and copy(o.by) or nil,
        secret = def.secret or nil,
        owner = def.owner,
    }
end

--------------------------------------------------------------------------------
-- Writing
--------------------------------------------------------------------------------

--- Shared front of set/reset, in the §3 order: type → existence → value → recursion → permission.
--- Returns def, actor (or nil + err). `value` is only checked for a set (checkValue = true).
local function admit(key, actorSrc, reason, checkValue, value)
    if type(key) ~= 'string' then return nil, nil, 'key' end
    local actor = nil
    if actorSrc ~= nil then
        actor = toActor(actorSrc)
        if not actor then return nil, nil, 'actor' end
    end
    if reason ~= nil and (type(reason) ~= 'string' or #reason > REASON_MAX) then return nil, nil, 'reason' end
    if not ensureLoaded() then return nil, nil, 'unavailable' end
    local def = defs[key]
    if not def then return nil, nil, 'unknown' end
    local normalized = nil
    if checkValue then
        local ok, res = Schema.check(def.field, value)
        if not ok then return nil, nil, res end
        normalized = res
    end
    if isRecursive(key, Registry.getCaller()) then return nil, nil, 'recursive' end
    if actor ~= nil and not Core.Perms.has(actor, def.edit or DEFAULT_EDIT) then
        audit(def, checkValue and 'set' or 'reset', actor, reason, (resolve(key)), normalized, 'denied')
        return nil, nil, 'permission'
    end
    if defs[key] ~= def then return nil, nil, 'unknown' end      -- a yield above let the owner stop
    return def, actor, nil, normalized
end

--- After a successful write: replicate, then the watchers (only when the value really changed).
local function changed(def, old)
    local new = resolve(def.key)
    if def.replicate then queuePublish(def.key) end
    if not deepEqual(old, new) then dispatch(def.key, new, old) end
    return new
end

--- Runs `fn` holding the write slot of one key: writes of a key never overlap, so two awaited writes can
--- never commit in another order than memory saw them. Waits (a coroutine) while another write of the key
--- is out. `fn` runs under pcall so the slot is always released. Returns fn's results, or false, 'persist'
--- when it would have to wait and cannot yield, or when fn raised.
local function withSlot(key, fn)
    while writing[key] do
        if not coroutine.isyieldable() then return false, 'persist' end
        Citizen.Await(writing[key])
    end
    local slot = promise.new()
    writing[key] = slot
    local ok, result, err = pcall(fn)
    writing[key] = nil
    slot:resolve(true)
    if not ok then
        Log.error('settings: writing %s failed: %s', key, tostring(result))
        return false, 'persist'
    end
    return result, err
end

--- A write that TIMED OUT may still commit inside core_db after the slot would be freed, and then land
--- after a newer write of the key. Still holding the slot, write what memory holds again (the override
--- memory kept, or its absence), so the table converges on memory; logged when that fails too.
local function reassert(key)
    local entry = overrides[key]
    local ok, err
    if entry then
        ok, err = DB.upsert(TABLE, { key = key, value = entry.value, updated_by = entry.by, updated_at = entry.updatedAt },
            'key', { returning = false })
    else
        ok, err = DB.delete(TABLE, { key = key })
    end
    if ok == nil or ok == false then
        Log.error('settings: %s may differ in the database until its next write (%s)', key, tostring(err))
    end
end

--- Stores an override. With `actorSrc` the actor needs the property's `edit` permission
--- (default 'core.admin'); without one it is a trusted server-side call. Awaited: the override is in
--- memory (and watchers run) only once the upsert committed; 'persist' when it failed. A value the field
--- normalises to nil (an optional field set to nil) is a reset: the value falls back to config/default.
---@return boolean ok, string|nil err
function Settings.set(key, value, actorSrc, reason)
    local def, actor, err, normalized = admit(key, actorSrc, reason, true, value)
    if not def then return false, err end
    if normalized == nil then return Settings.reset(key, actorSrc, reason) end
    local by = actorInfo(actor, Registry.getCaller())
    local old
    local ok, writeErr = withSlot(key, function()
        if defs[key] ~= def then return false, 'unknown' end   -- the owner stopped while this write waited
        old = copy((resolve(key)))
        local entry = { value = normalized, updatedAt = os.time(), by = by }
        local stored, dbErr = DB.upsert(TABLE, {
            key = key, value = normalized, updated_by = by, updated_at = entry.updatedAt,
        }, 'key', { returning = false })
        if not stored then
            Log.warn('settings: could not store %s (%s)', key, tostring(dbErr))
            if DB.errorCode(dbErr) == 'timeout' then reassert(key) end
            return false, 'persist'
        end
        overrides[key] = entry
        return true
    end)
    if not ok then return false, writeErr end
    local new = changed(def, old)
    audit(def, 'set', actor, reason, old, new, 'ok')
    return true
end

--- Deletes the override (the value falls back to config/default). True when there was none. Awaited:
--- 'persist' when the delete failed (the override then stays).
---@return boolean ok, string|nil err
function Settings.reset(key, actorSrc, reason)
    local def, actor, err = admit(key, actorSrc, reason, false)
    if not def then return false, err end
    if overrides[key] == nil then return true end
    local old
    local outcome, writeErr = withSlot(key, function()
        if defs[key] ~= def then return false, 'unknown' end   -- the owner stopped while this write waited
        if overrides[key] == nil then return 'none' end         -- a reset that held the slot first did it
        old = copy((resolve(key)))
        local removed, dbErr = DB.delete(TABLE, { key = key })
        if removed == nil then
            Log.warn('settings: could not delete %s (%s)', key, tostring(dbErr))
            if DB.errorCode(dbErr) == 'timeout' then reassert(key) end
            return false, 'persist'
        end
        overrides[key] = nil
        return 'done'
    end)
    if not outcome then return false, writeErr end
    if outcome == 'done' then
        local new = changed(def, old)
        audit(def, 'reset', actor, reason, old, new, 'ok')
    end
    return true
end

--------------------------------------------------------------------------------
-- Listing (the generic settings UI)
--------------------------------------------------------------------------------

--- One property for list(): the public schema (Core.Schema.public, secret defaults removed) plus
--- key/name, value, source and the settings flags. Secret values are masked.
local function describe(def, editable)
    local p = Schema.public(def.field)[1]
    local value, source = resolve(def.key)
    p.key, p.name = def.key, def.key
    p.value = masked(def, value)
    p.source = source
    p.modified = source == 'override'
    if def.config ~= nil and not def.secret then p.config = copy(def.config) end
    p.scope, p.section = def.scope, def.section
    p.edit, p.view = def.edit or DEFAULT_EDIT, def.view or DEFAULT_VIEW
    p.replicate, p.restart, p.deprecated = def.replicate, def.restart, def.deprecated
    p.editable = editable
    return p
end

--- Sections sorted by order then id, properties in definition order. With `viewerSrc` only the
--- properties that viewer may see (`view`, default 'core.settings.view') are listed, each with
--- `editable` (the `edit` permission); sections left empty are dropped.
function Settings.list(viewerSrc)
    local viewer = nil
    if viewerSrc ~= nil then
        viewer = toActor(viewerSrc)
        if not viewer then return {} end
    end
    if not ensureLoaded() then served = true end
    local memo = {}
    local function allowed(perm)
        if viewer == nil then return true end
        local answer = memo[perm]
        if answer == nil then
            answer = Core.Perms.has(viewer, perm) and true or false
            memo[perm] = answer
        end
        return answer
    end
    local out = {}
    for _, section in pairs(sections) do
        local props = {}
        for i = 1, #section.keys do
            local def = defs[section.keys[i]]
            if def and allowed(def.view or DEFAULT_VIEW) then
                props[#props + 1] = describe(def, allowed(def.edit or DEFAULT_EDIT))
            end
        end
        if #props > 0 then
            out[#out + 1] = {
                id = section.id, title = section.title, icon = section.icon, order = section.order,
                owner = section.owner, properties = props,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.order ~= b.order then return a.order < b.order end
        return a.id < b.id
    end)
    return out
end

--------------------------------------------------------------------------------
-- Watchers
--------------------------------------------------------------------------------

--- fn(key, new, old) for every change of a key starting with `prefix` ('' = every key). Runs in a new
--- thread after persist; errors are logged, never propagated. Owner-swept.
---@return integer|nil handle
function Settings.onChange(prefix, fn)
    if type(prefix) ~= 'string' or #prefix > KEY_MAX then return nil end
    if not Utils.isCallable(fn) then return nil end
    nextWatch = nextWatch + 1
    local owner = Registry.getCaller()
    watchers[nextWatch] = { id = nextWatch, prefix = prefix, fn = fn, owner = owner }
    Registry.track(WATCH_KIND, nextWatch, owner)
    return nextWatch
end

--- Removes a watcher; only its owner (or core) may.
function Settings.offChange(handle)
    local w = watchers[handle]
    if not w then return false end
    local caller = Registry.getCaller()
    if caller ~= w.owner and caller ~= 'core' then return false end
    watchers[handle] = nil
    Registry.untrack(WATCH_KIND, handle)
    return true
end

Registry.onOwnerStop(WATCH_KIND, function(id)
    watchers[id] = nil
end)

--------------------------------------------------------------------------------
-- Core's own sections (DESIGN §45): the map runtime limits (§52) and audit retention (§46)
--------------------------------------------------------------------------------

local function limit(order, default, min, max, label, description)
    return {
        type = 'integer', default = default, min = min, max = max, label = label,
        description = description, group = 'Limits', order = order,
    }
end

local coreSections = {
    {
        id = 'maps', title = 'Maps', icon = 'map', order = 800, properties = {
            ['maps.limits.elements'] = limit(1, 3000, 1, 100000, 'Elements per map',
                'Most elements one map may hold, of every type together.'),
            ['maps.limits.perModel'] = limit(2, 300, 1, 10000, 'Elements per model',
                'Most elements of one model inside one map.'),
            ['maps.limits.uniqueModels'] = limit(3, 200, 1, 5000, 'Different models per map',
                'Most distinct models one map may use (each one is streamed by every client that loads it).'),
            ['maps.limits.networked'] = limit(4, 20, 0, 500, 'Networked elements per map',
                'Server-created entities (vehicles, peds, networked props) one map may hold.'),
            ['maps.limits.networkedTotal'] = limit(5, 200, 0, 2000, 'Networked elements, all maps',
                'Server-created entities across every active map together.'),
            ['maps.limits.opsPerApply'] = limit(6, 200, 1, 1000, 'Operations per apply',
                'Most operations one editor apply may carry.'),
            ['maps.journalMax'] = {
                type = 'integer', default = 5000, min = 100, max = 100000, label = 'Journal entries per map',
                description = 'Undo/redo journal entries kept per map; the oldest are pruned.',
                group = 'History', order = 7,
            },
            ['maps.journalMaxOps'] = {
                type = 'integer', default = 20000, min = 1000, max = 1000000, label = 'Journal operations per map',
                description = 'Stored operations kept in one map\'s journal; the oldest rows are pruned.',
                group = 'History', order = 8,
            },
        },
    },
    {
        id = 'audit', title = 'Audit trail', icon = 'history', order = 900, properties = {
            ['audit.retentionDays'] = {
                type = 'integer', default = 90, min = 1, max = 3650, unit = 'days', label = 'Retention',
                description = 'Audit rows older than this are pruned daily (sanctions and bans are kept four times as long).',
                order = 1,
            },
            ['audit.maxRows'] = {
                type = 'integer', default = 50000, min = 1000, max = 1000000, unit = 'rows', label = 'Maximum rows',
                description = 'Oldest rows beyond this count are pruned daily; sanction and ban rows are exempt.',
                order = 2,
            },
            ['audit.logMaxRows'] = {
                type = 'integer', default = 20000, min = 1000, max = 1000000, unit = 'rows', label = 'Maximum log rows',
                description = 'Oldest Log.audit mirror rows of gameplay categories (money, faction, security, …) beyond '
                    .. 'this count are pruned daily; they never evict the admin trail.',
                order = 3,
            },
        },
    },
}

for i = 1, #coreSections do
    local ok, err = Settings.define(coreSections[i])
    if not ok then Log.error('settings: core section %s refused: %s', coreSections[i].id, tostring(err)) end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

-- Load the overrides as soon as every core file ran (the select waits for core's migrations inside core_db),
-- so the first get() rarely waits and a broken database shows up in the console at start.
AddEventHandler('onResourceStart', function(resource)
    if resource ~= Core.name then return end
    -- once per core start (the handler returns for every other resource), and the thread ends after the load
    -- fxlint-disable-next-line P004
    CreateThread(function() ensureLoaded() end)
end)

-- The database is back (core_db's health flipped to healthy, §56.2.5): a load that failed retries at once,
-- without waiting for the retry thread or the next caller.
Core.on('dbStatus', function(healthy)
    if healthy ~= true or loaded or not failedAt or stopped then return end
    -- one short thread per recovery; a later load joins the barrier
    -- fxlint-disable-next-line P004
    CreateThread(function()
        Wait(0)   -- never inside core_db's own callback (the event may fire while a statement is answered)
        if not loaded and not stopped then ensureLoaded(true) end
    end)
end)

-- Synchronous teardown: the mirrored keys go with core (a restart publishes them again).
AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    stopped = true
    for key in pairs(published) do
        GlobalState[STATE_PREFIX .. key] = nil
    end
    if next(indexed) ~= nil then GlobalState[INDEX_KEY] = nil end
end)
