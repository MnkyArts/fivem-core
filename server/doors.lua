--- core/server/doors.lua — Core.Doors (server).
--- Registered doors (table `doors`, DESIGN §56.6), the permission chain, the `door:<id>` GlobalState
--- entries clients read, the `core:server:doorToggle` net event and the `core:doors:canUse`
--- callback. Contract: DESIGN.md §16 (API + wire + §56 port notes), §4.4 (Perms), §4.5 (factions),
--- §8 (state bags + hooks), §9 (budget).
---
--- Persistence: every door row is loaded ONCE at start (a small table, §56.8 rule 1) by a file-scope
--- thread and restored as a runtime door, so doors survive a restart even before the plugin that owns
--- them re-registers. `Doors.register` keeps the stored `locked` flag (read from memory, never a
--- per-register query) and queues a save only when the door differs from its row; `setLocked` queues a
--- patch of `locked`. Nothing here yields. A door registered before the load finished is merged when it
--- lands (the stored lock wins unless setLocked changed it meanwhile) and saved then.
--- `Doors.unregister` drops the runtime door and its GlobalState key but keeps the row, so a later
--- re-register restores the lock state (Core.DB.remove('doors', id) forgets it from the next restart on).
---
--- Natives: GetPlayerPed(playerSrc), GetEntityCoords(entity) — the server form takes one argument.

local Doors = {}
Core.Doors = Doors

local Validate = Core.Validate
local Utils = Core.Utils
local Log = Core.Log
local Net = Core.Net
local DB = Core.DB

local TABLE <const> = 'doors'
local LOAD_BACKOFF_MS <const> = { 1000, 2000, 5000, 10000, 30000 }
local DEFAULT_RADIUS <const> = 3.0
local TOGGLE_DISTANCE <const> = 3.5
local TOGGLE_COOLDOWN_MS <const> = 500
local PUBLISH_BATCH <const> = 40        -- GlobalState keys per drain pass; budget is 75/s (DESIGN §9)
local PUBLISH_INTERVAL_MS <const> = 1000
local UNPUBLISH_DELAY_MS <const> = 500  -- how long the `false` tombstone stays before the key goes
local MAX_PERMS <const> = 16
local PERM_MAX_LEN <const> = 64
local AUTOLOCK_MIN_MS <const> = 1000
local CANUSE_COOLDOWN_MS <const> = 500
local CANUSE_DISTANCE <const> = 10.0
local REMOVE <const> = {}               -- publish-queue sentinel: delete the key, don't write a value

local doors = {}        -- [id] = { id, model, coords (vector3), locked, perms, autoLockMs, meta }
local stored = {}       -- [id] = the door as its row holds it (loaded, then kept in step with every queued write)
local loaded = false
local running = true
local unsaved = {}      -- [id] = true: registered before the load landed (merged and saved then)
local lockTouched = {}  -- [id] = true: setLocked ran before the load landed (its state beats the stored one)
local autoLockGen = {}  -- [id] = counter; a stale SetTimeout callback sees a newer value and returns
local publishQueue = {} -- [id] = value | false | REMOVE; at most one pending write per door
local draining = false
local lastCanUse = {}   -- [src] = GetGameTimer() of the last canUse callback; cleared on drop

--- Validate positional arguments; nil when ok, the error string otherwise.
local function invalid(schema, ...)
    local ok, err = Validate.check(schema, ...)
    if ok then return nil end
    return err or 'invalid_arguments'
end

--- Only known-shaped perm strings survive: an ACE/group perm, `faction:<id>` or
--- `faction:<id>:<minRank>` (DESIGN §16). Anything else is dropped at registration time.
local function sanitizePerms(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    for i = 1, #list do
        if #out >= MAX_PERMS then break end
        local perm = list[i]
        if type(perm) == 'string' then
            perm = Utils.trim(perm)
            if #perm > 0 and #perm <= PERM_MAX_LEN then out[#out + 1] = perm end
        end
    end
    return out
end

--- Write at most PUBLISH_BATCH keys, newest value per door. Nothing yields inside the loop, so
--- no other coroutine can add keys while it runs. Returns true while work is left.
local function drainOnce()
    local written = 0
    for id, value in pairs(publishQueue) do
        publishQueue[id] = nil
        GlobalState['door:' .. id] = (value ~= REMOVE) and value or nil
        written = written + 1
        if written >= PUBLISH_BATCH then break end
    end
    return next(publishQueue) ~= nil
end

--- Every GlobalState write of this module goes through one paced queue: a start-up loop
--- registering hundreds of doors would otherwise blow the state-bag budget (75/s, burst 125),
--- and over-budget writes are discarded silently — clients would keep stale doors forever.
--- A single queued write lands on the next tick; only a backlog is paced.
local function queueWrite(id, value)
    publishQueue[id] = value
    if draining then return end
    draining = true
    -- exactly one drain thread, and it ends as soon as the queue runs dry
    -- fxlint-disable-next-line P004
    CreateThread(function()
        while drainOnce() do
            Wait(PUBLISH_INTERVAL_MS)
        end
        draining = false
    end)
end

--- The value clients read (DESIGN §16): the whole entry, flat, never partially updated.
local function publish(entry)
    queueWrite(entry.id, {
        locked = entry.locked,
        model = entry.model,
        x = entry.coords.x, y = entry.coords.y, z = entry.coords.z,
    })
end

--- `false` first so client change handlers fire (DESIGN §8), then the key goes away entirely:
--- a permanent tombstone per door would grow GlobalState for every door ever registered.
-- `local function` declares the local before the body, so the retry below sees itself
local function scheduleRemoval(id)
    SetTimeout(UNPUBLISH_DELAY_MS, function()
        if doors[id] then return end                        -- registered again: keep its value
        if publishQueue[id] ~= nil then return scheduleRemoval(id) end   -- tombstone still queued
        queueWrite(id, REMOVE)
    end)
end

local function unpublish(id)
    queueWrite(id, false)
    scheduleRemoval(id)
end

--- Deep equality of plain values (perms lists, meta maps); `{}` equals `{}` whatever JSON made of it.
local function same(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for key, value in pairs(a) do
        if not same(value, b[key]) then return false end
    end
    for key in pairs(b) do
        if a[key] == nil then return false end
    end
    return true
end

--- The door as its row holds it: what `stored` keeps and what a register is compared with.
local function snapshotOf(entry)
    return {
        model = entry.model, x = entry.coords.x, y = entry.coords.y, z = entry.coords.z, locked = entry.locked,
        perms = entry.perms, autoLockMs = entry.autoLockMs, meta = entry.meta,
    }
end

local function sameAsStored(entry)
    local snap = stored[entry.id]
    if not snap then return false end
    local c = entry.coords
    return snap.model == entry.model and snap.x == c.x and snap.y == c.y and snap.z == c.z
        and snap.locked == entry.locked and snap.autoLockMs == entry.autoLockMs
        and same(snap.perms, entry.perms) and same(snap.meta, entry.meta)
end

--- Queues the whole row (upsert by id) unless it already holds exactly this door. Never yields.
local function persist(entry)
    if sameAsStored(entry) then return true end
    local ok, err = DB.save(TABLE, {
        id = entry.id,
        model = entry.model,
        coords = { x = entry.coords.x, y = entry.coords.y, z = entry.coords.z },
        locked = entry.locked,
        perms = entry.perms,
        auto_lock_ms = entry.autoLockMs,
        meta = entry.meta or DB.NULL,
    })
    if not ok then
        Log.error('doors: the row of %s could not be queued (%s)', entry.id, tostring(err))
        return false
    end
    stored[entry.id] = snapshotOf(entry)
    return true
end

--- A lock change: one queued patch of `locked` (the whole row when it was never written). Never yields.
local function persistLock(entry)
    local snap = stored[entry.id]
    if not snap then return persist(entry) end
    if snap.locked == entry.locked then return true end
    local ok, err = DB.patch(TABLE, entry.id, { locked = entry.locked })
    if not ok then
        Log.error('doors: the lock of %s could not be queued (%s)', entry.id, tostring(err))
        return false
    end
    snap.locked = entry.locked
    return true
end

--- Stored row -> runtime entry (coords come back as a { x, y, z } table; NULL columns are absent keys).
local function entryFromRow(row)
    if type(row) ~= 'table' or type(row.id) ~= 'string' or type(row.coords) ~= 'table' then return nil end
    local model = math.floor(tonumber(row.model) or 0)
    if model == 0 then return nil end
    return {
        id = row.id,
        model = model,
        coords = Utils.tableToVector3(row.coords),
        locked = row.locked == true,
        perms = sanitizePerms(row.perms),
        autoLockMs = math.max(0, math.floor(tonumber(row.auto_lock_ms) or 0)),
        meta = type(row.meta) == 'table' and row.meta or nil,
    }
end

--- Re-lock an unlocked door after `autoLockMs`. One timer per unlock; the generation counter
--- makes every earlier timer a no-op, so re-unlocking simply restarts the countdown.
local function scheduleAutoLock(entry)
    local gen = (autoLockGen[entry.id] or 0) + 1
    autoLockGen[entry.id] = gen
    if entry.locked or entry.autoLockMs < AUTOLOCK_MIN_MS then return end
    local id = entry.id
    SetTimeout(entry.autoLockMs, function()
        if autoLockGen[id] ~= gen then return end
        local current = doors[id]
        if current and not current.locked then Doors.setLocked(id, true) end
    end)
end

-- ---------------------------------------------------------------------------
-- Permission chain (DESIGN §16): any entry may allow; an empty list is public
-- ---------------------------------------------------------------------------

--- `faction:<id>` / `faction:<id>:<minRank>` against the caller's faction summary
--- (`Core.Factions.getPlayerFaction` -> { id, rank, ... }).
local function factionAllows(faction, spec)
    if not faction then return false end
    local factionId, rankPart = spec:match('^([^:]+):?(%d*)$')
    if not factionId or faction.id ~= factionId then return false end
    if rankPart == '' then return true end
    local minRank = tonumber(rankPart)
    return minRank ~= nil and (tonumber(faction.rank) or 0) >= minRank
end

--- May `src` toggle this door? Doors without perms are public.
---@param src integer
---@param id string
---@return boolean
function Doors.canUse(src, id)
    if invalid({ 'src', 'id' }, src, id) then return false end
    local entry = doors[id]
    if not entry then return false end
    local perms = entry.perms
    if #perms == 0 then return true end

    local faction    -- resolved at most once per call: false = looked up, no faction
    for i = 1, #perms do
        local perm = perms[i]
        local factionSpec = perm:match('^faction:(.+)$')
        if factionSpec then
            if faction == nil then faction = Core.Factions.getPlayerFaction(src) or false end
            if factionAllows(faction, factionSpec) then return true end
        elseif Core.Perms.has(src, perm) then
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- API (DESIGN §16)
-- ---------------------------------------------------------------------------

--- Register (or re-register) a door. opts: id, model (name or hash), coords, locked,
--- perms, autoLockMs, meta. A stored `locked` flag wins over `opts.locked`.
---@param opts table
---@return string|nil id
function Doors.register(opts)
    if type(opts) ~= 'table' then
        Log.error('Doors.register: opts must be a table')
        return nil
    end
    local err = invalid({ 'id', 'vector3' }, opts.id, opts.coords)
    if err then
        Log.error('Doors.register: %s', err)
        return nil
    end
    if type(opts.model) ~= 'string' and type(opts.model) ~= 'number' then
        Log.error('Doors.register: model must be a model name or a hash')
        return nil
    end
    -- a JSON round-trip can hand back the hash as a float; the door natives want an integer
    local model = math.floor(tonumber(Utils.hash(opts.model)) or 0)
    if model == 0 then
        Log.error('Doors.register: model %s hashes to 0', tostring(opts.model))
        return nil
    end

    local id = opts.id
    local entry = {
        id = id,
        model = model,
        coords = opts.coords,
        locked = opts.locked == true,
        perms = sanitizePerms(opts.perms),
        autoLockMs = math.max(0, math.floor(tonumber(opts.autoLockMs) or 0)),
        meta = type(opts.meta) == 'table' and Utils.deepCopy(opts.meta) or nil,
    }

    -- persisted lock state wins: a restart (or a re-register) never re-opens a locked door. Memory, not a query:
    -- the rows were loaded at start; before that the merge in loadDoors applies it.
    local snap = stored[id]
    if snap then entry.locked = snap.locked end

    doors[id] = entry
    lockTouched[id] = nil
    if loaded then persist(entry) else unsaved[id] = true end
    publish(entry)
    scheduleAutoLock(entry)
    return id
end

--- Drop the runtime door and its GlobalState key. The document stays (see the file header).
---@param id string
---@return boolean removed
function Doors.unregister(id)
    if invalid({ 'id' }, id) or not doors[id] then return false end
    doors[id] = nil
    autoLockGen[id] = (autoLockGen[id] or 0) + 1
    unpublish(id)
    return true
end

--- A copy of one door, or nil.
---@param id string
---@return table|nil
function Doors.get(id)
    local entry = doors[id]
    if not entry then return nil end
    return Utils.deepCopy(entry)
end

--- Every registered door, as copies.
---@return table[]
function Doors.list()
    local out = {}
    for _, entry in pairs(doors) do
        out[#out + 1] = Utils.deepCopy(entry)
    end
    return out
end

--- Force a lock state. `src` is only passed on to the hook (nil = system/plugin).
---@param id string
---@param locked boolean
---@param src integer|nil
---@return boolean ok
function Doors.setLocked(id, locked, src)
    if invalid({ 'id', 'boolean', 'src?' }, id, locked, src) then return false end
    local entry = doors[id]
    if not entry then return false end
    if entry.locked == locked then return true end

    entry.locked = locked
    publish(entry)
    if loaded then persistLock(entry) else lockTouched[id] = true end
    scheduleAutoLock(entry)
    Core.emitHook(locked and 'doorLocked' or 'doorUnlocked', id, src)
    return true
end

--- Flip a door for a player, permission-checked.
---@param src integer
---@param id string
---@return boolean ok, string|nil err
function Doors.toggle(src, id)
    local err = invalid({ 'src', 'id' }, src, id)
    if err then return false, 'invalid_arguments' end
    local entry = doors[id]
    if not entry then return false, 'unknown_door' end
    if not Doors.canUse(src, id) then return false, 'no_permission' end
    if not Doors.setLocked(id, not entry.locked, src) then return false, 'failed' end
    return true
end

--- The closest door to the player within `radius`, by id.
---@param src integer
---@param radius number|nil default 3.0
---@return string|nil id
function Doors.getNearest(src, radius)
    if invalid({ 'src' }, src) then return nil end
    local max = tonumber(radius) or DEFAULT_RADIUS
    local ped = GetPlayerPed(src)
    if ped == 0 then return nil end
    local coords = GetEntityCoords(ped)
    local bestId, bestDist
    for id, entry in pairs(doors) do
        local dist = #(coords - entry.coords)
        if dist <= max and (not bestDist or dist < bestDist) then
            bestId, bestDist = id, dist
        end
    end
    return bestId
end

-- ---------------------------------------------------------------------------
-- Wire (DESIGN §16): one net event, one callback
-- ---------------------------------------------------------------------------

--- Distance target for Core.Net: the door's own coords, looked up server-side.
local function doorCoords(_, id)
    local entry = type(id) == 'string' and doors[id] or nil
    return entry and entry.coords or nil
end

Net.on('core:server:doorToggle', { 'id' }, function(src, id)
    local ok, err = Doors.toggle(src, id)
    if not ok and err == 'no_permission' then
        Core.Notify.send(src, Config.Texts.no_permission, 'error')
    end
end, {
    cooldown = TOGGLE_COOLDOWN_MS,
    requireLoaded = true,
    distance = { coords = doorCoords, max = TOGGLE_DISTANCE },
})

--- The client asks once per door on approach (cached client-side) to decide whether to show the
--- prompt. The answer is advisory — the toggle re-checks everything — but the question itself is
--- a permission lookup, so it is gated like any other event: type -> existence -> loaded ->
--- cooldown -> distance -> permission. Every rejection answers a plain `false`.
Core.Callback.register('core:doors:canUse', function(src, id)
    if type(id) ~= 'string' then return false end
    local entry = doors[id]
    if not entry then return false end
    if Core.Player.isLoaded(src) ~= true then return false end

    local now = GetGameTimer()
    if now - (lastCanUse[src] or 0) < CANUSE_COOLDOWN_MS then return false end
    lastCanUse[src] = now

    local ped = GetPlayerPed(src)
    if ped == 0 then return false end
    if #(GetEntityCoords(ped) - entry.coords) > CANUSE_DISTANCE then return false end

    return Doors.canUse(src, id)
end)

--- Every runtime door in the GlobalState shape (DESIGN §16): a client that started after the keys
--- were published (join, or a core restart mid-session) never sees a change event for them, so it
--- asks once on load. Positions are public anyway; the answer is the same for everyone.
Core.Callback.register('core:doors:list', function(src)
    if Core.Player.isLoaded(src) ~= true then return {} end
    local out = {}
    for id, entry in pairs(doors) do
        out[id] = {
            locked = entry.locked,
            model = entry.model,
            x = entry.coords.x, y = entry.coords.y, z = entry.coords.z,
        }
    end
    return out
end)

AddEventHandler('playerDropped', function()
    local src = source
    lastCanUse[src] = nil
end)

-- ---------------------------------------------------------------------------
-- Lifecycle: GlobalState is empty again after a core restart (DESIGN §8, §16)
-- ---------------------------------------------------------------------------

--- Every stored row becomes a runtime door (even one no plugin registers again, like before); a door that was
--- registered before the rows landed takes the stored lock (unless setLocked changed it meanwhile) and is saved
--- now. The restore only fills the publish queue, which the drain thread paces at PUBLISH_BATCH keys per
--- PUBLISH_INTERVAL_MS.
local function merge(rows)
    local restored = 0
    for i = 1, #rows do
        local entry = entryFromRow(rows[i])
        if entry then
            local id = entry.id
            stored[id] = snapshotOf(entry)
            local current = doors[id]
            if not current then
                doors[id] = entry
                publish(entry)
                scheduleAutoLock(entry)
                restored = restored + 1
            elseif unsaved[id] and not lockTouched[id] and current.locked ~= entry.locked then
                current.locked = entry.locked
                publish(current)
                scheduleAutoLock(current)
            end
        end
    end
    loaded = true
    for id in pairs(unsaved) do
        if doors[id] then persist(doors[id]) end
    end
    unsaved, lockTouched = {}, {}
    if restored > 0 then Log.info('doors: restored %d door(s) from the database', restored) end
end

--- The load thread (file scope, one whole-table read of a small table; `sync` = after what a previous core
--- run queued). A failed read is retried with backoff and never counts as "no doors".
-- one thread per core start, and it ends with the load
-- fxlint-disable-next-line P004
CreateThread(function()
    local attempt = 0
    while running and not loaded do
        local rows, err = DB.select(TABLE, nil, { sync = true })
        if rows then
            merge(rows)
        else
            attempt = attempt + 1
            Log.error('doors: could not load the doors (%s) — retrying; lock changes wait in memory', tostring(err))
            Wait(LOAD_BACKOFF_MS[math.min(attempt, #LOAD_BACKOFF_MS)])
        end
    end
end)

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName ~= Core.name then return end
    running = false
end)

-- end of file
