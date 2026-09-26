-- core/server/buckets.lua
-- Core.Buckets (DESIGN §50): routing buckets handed out from Config.Buckets.Range, owner-tracked (kind 'bucket').
--
-- `allocate` picks the next free id after the last one handed out (round robin, so a just-released id is not
-- reused at once), applies the population and entity-lockdown settings and remembers the calling resource as
-- the owner. `release` is owner-only (core itself may release any) and moves the players still inside back to
-- bucket 0: a loaded player through Core.Player.setBucket (so `core:client:bucketChanged` reaches the map
-- runtime), anyone else with the raw native. That is one pass over the connected players — release is rare (a
-- map closes, a plugin stops), so the pass is acceptable even at 2,000 players; nothing here runs on a timer.
-- Entities left inside are not touched: their owner removes them (core's vehicles, a map runtime).
-- When the owning resource stops, its buckets are released through the Registry sweep.
--
-- Natives (fxref 2026-09-26, apiset server): SetRoutingBucketPopulationEnabled(bucketId, mode),
-- SetRoutingBucketEntityLockdownMode(bucketId, mode), GetPlayerRoutingBucket(playerSrc) -> integer,
-- SetPlayerRoutingBucket(playerSrc, bucket). GetPlayers is a runtime helper, not a native.

local Buckets = {}
Core.Buckets = Buckets

local KIND <const> = 'bucket'
local MAX_LABEL <const> = 64
local LOCKDOWN <const> = { strict = true, relaxed = true, inactive = true }

local allocated = {}   -- [bucket] = { owner, label, population, lockdown }
local count = 0
local cursor = nil     -- the last id handed out

--- The configured [lo, hi] range (integers, lo >= 1, lo <= hi), or the §50 default.
local function range()
    local cfg = Config.Buckets and Config.Buckets.Range
    local lo, hi = cfg and math.tointeger(cfg[1]), cfg and math.tointeger(cfg[2])
    if lo and hi and lo >= 1 and lo <= hi then return lo, hi end
    return 10000, 60000
end

--- The next free id after the cursor (wrapping inside the range), or nil when the range is full.
local function nextFree()
    local lo, hi = range()
    local size = hi - lo + 1
    if count >= size then return nil end
    local start = (cursor and cursor >= lo and cursor < hi) and cursor + 1 or lo
    for i = 0, size - 1 do
        local id = lo + (start - lo + i) % size
        if not allocated[id] then return id end
    end
    return nil
end

--- Move every connected player still inside `bucket` back to bucket 0; returns how many were moved.
local function evacuate(bucket)
    local moved = 0
    local players, player = GetPlayers(), type(Core.Player) == 'table' and Core.Player or {}
    local isLoaded, setBucket = rawget(player, 'isLoaded'), rawget(player, 'setBucket')   -- server/player.lua's
    for i = 1, #players do
        local src = players[i]
        if GetPlayerRoutingBucket(src) == bucket then
            local id = tonumber(src)
            local loaded = setBucket and id and isLoaded(id) and setBucket(id, 0) == true
            if not loaded then SetPlayerRoutingBucket(src, 0) end
            moved = moved + 1
        end
    end
    return moved
end

local function free(bucket)
    local entry = allocated[bucket]
    if not entry then return false end
    allocated[bucket] = nil
    count = count - 1
    Core.Registry.untrack(KIND, bucket)
    local moved = evacuate(bucket)
    Core.Log.debug('buckets: released %d (%s, owner %s, %d player(s) moved to 0)', bucket,
        entry.label or '-', entry.owner, moved)
    return true
end

--- Allocate a routing bucket for the calling resource.
--- opts = { label?, population = false, lockdown = 'strict'|'relaxed'|'inactive' (default 'strict') }
---@return integer|nil bucket
function Buckets.allocate(opts)
    if opts ~= nil and type(opts) ~= 'table' then return nil end
    opts = opts or {}
    local lockdown = opts.lockdown == nil and 'strict' or opts.lockdown
    if not LOCKDOWN[lockdown] then
        Core.Log.warn('Buckets.allocate: lockdown must be strict, relaxed or inactive (got %s)', tostring(lockdown))
        return nil
    end
    if opts.population ~= nil and type(opts.population) ~= 'boolean' then return nil end
    if opts.label ~= nil and type(opts.label) ~= 'string' then return nil end
    local bucket = nextFree()
    if not bucket then
        Core.Log.error('Buckets.allocate: the range %d..%d is exhausted', range())
        return nil
    end
    local population = opts.population == true
    SetRoutingBucketPopulationEnabled(bucket, population)
    SetRoutingBucketEntityLockdownMode(bucket, lockdown)
    local owner = Core.Registry.getCaller()
    allocated[bucket] = { owner = owner, label = opts.label and opts.label:sub(1, MAX_LABEL) or nil,
        population = population, lockdown = lockdown }
    count = count + 1
    cursor = bucket
    Core.Registry.track(KIND, bucket, owner)
    return bucket
end

--- Release a bucket. Only its owner (or core) may; players still inside go back to bucket 0.
function Buckets.release(bucket)
    local id = math.tointeger(bucket)
    local entry = id and allocated[id]
    if not entry then return false end
    local caller = Core.Registry.getCaller()
    if caller ~= entry.owner and caller ~= 'core' then
        Core.Log.warn('Buckets.release: %s may not release bucket %d (owner %s)', caller, id, entry.owner)
        return false
    end
    return free(id)
end

--- { owner, label, population, lockdown } of an allocated bucket, or nil.
function Buckets.info(bucket)
    local id = math.tointeger(bucket)
    local entry = id and allocated[id]
    if not entry then return nil end
    return { owner = entry.owner, label = entry.label, population = entry.population, lockdown = entry.lockdown }
end

--- Every allocated bucket, ascending: { bucket, owner, label, population, lockdown }.
function Buckets.list()
    local out = {}
    for id, entry in pairs(allocated) do
        out[#out + 1] = { bucket = id, owner = entry.owner, label = entry.label,
            population = entry.population, lockdown = entry.lockdown }
    end
    table.sort(out, function(a, b) return a.bucket < b.bucket end)
    return out
end

-- The owner stopped: its buckets are released (players inside return to bucket 0).
Core.Registry.onOwnerStop(KIND, function(bucket)
    free(bucket)
end)
