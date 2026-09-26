--[[
    core/server/maps_regions.lua — Core.MapRegions (DESIGN §52.3, §52.4a), the server half of map streaming.

    The world is cut into square regions of Config.Maps.RegionSize (512 m, read ONCE: the key encoding depends
    on it), integer key `(rx + 32768) * 65536 + (ry + 32768)` with `rx = floor(x / size)`. Per (bucket, region):
    a version, the client-rendered element tuples by uid and a lazily built pack string
    `json.encode({ v = version, e = { tuples } })` — one encode serves every client until the next change.

        MapRegions.put(bucket, uid, tuple) -> bool     add or move (remembers each (bucket, uid)'s region)
        MapRegions.remove(bucket, uid) -> bool
        MapRegions.clearBucket(bucket) -> removed      every element of a bucket; subscribers get `stale`
        MapRegions.stats() -> table                    counters for diagnostics
        MapRegions.keyOf(x, y) -> key                  MapRegions.version(bucket, key) -> integer (0 = empty)
        MapRegions.unsubscribe(src) -> bool            drop a player's window (playerDropped does it)
        MapRegions.reaudience(src, modeOn?) -> bool    re-check an editor now; true = downgraded to public

    Identity is (bucket, uid): a draft in an editor bucket and its published copy in bucket 0 may share uids.
    `tuple` (§52.4a) is owned by this module after `put` — pass a fresh table and never mutate it again;
    `tuple[1]` must equal `uid`, `tuple[4]`/`tuple[5]` are x/y.

    Versions come from ONE module-wide counter, so a region that runs empty (version 0, table dropped: memory
    stays bounded) and fills again can never repeat a version some client still caches. 0 always means empty.

    Audiences (review M6): tuples flagged FLAG_DATA (16) or FLAG_EDITOR (8) — points, zones, placeholders —
    reach EDITORS only (Admin mode `editor`, or standing in an open draft's editor bucket; re-evaluated on every
    window request). Each region keeps its full version `v` and a public version `pv` (0 when nothing public is
    left, `v` itself while no hidden tuple exists, else a counter value of its own — one number never names two
    contents) and two cached packs; deltas are split per audience, a data-only change reaches editors only.
    The wire format does not change: a client simply only ever sees its audience's version.
    Losing the audience applies at once (review R2-8): the `staffModeChanged` / `permsChanged` hooks and a
    per-flush re-check of every editor target (live bucket + editor status) downgrade the src to public and
    send `core:maps:stale` for its regions whose public view differs. A gain waits for the next window request.

    Clients: callback `core:maps:window` `{ c = centreKey, h = { [key] = version } }` (cooldown 250 ms) moves
    the caller's subscription to the 3×3 block around `c` in the bucket the SERVER reads, answers
    `{ b = bucket, v = { [key] = version }, w = { [key] = true } }` (w: withheld, below) and sends each
    non-empty region whose version differs from `h[key]` as a latent `core:maps:pack (bucket, key, pack)` — unless that exact version already went to this
    src during its current subscription (it holds it or it is in flight: a repeated request cannot make the
    server send the same bytes twice; the memory is dropped when the key leaves the window or the bucket
    changes). Packs also spend a per-src token bucket (`PackBudgetBytes`, 2 MB, full again after
    `PackBudgetWindowMs`, 10 s; the centre region is served first): a pack that does not fit is WITHHELD —
    the answer's `w = { [key] = true }` lists it (its `v` is still reported) and the client asks again ~2 s
    later. So every region `v` lists ≠ h[key] and ≠ 0 is either in `w` or has its pack in flight/delivered.
    Changes are coalesced per server tick: one SetTimeout(0) flush per dirty cycle sends
    `core:maps:delta (bucket, key, fromV, toV, opsJson)` (≤ PushOpsMax ops) or `core:maps:stale (bucket, key,
    toV)` with Core.Net.emitMany to that region's subscribers only.
    No loop over players anywhere; a region without subscribers costs a version bump and nothing on the wire.

    INTERNAL: `MapRegions` belongs in INTERNAL_NAMESPACES (server/api.lua); server/maps.lua is the only caller.

    Natives (fxref 2026-09-26): GetPlayerRoutingBucket(playerSrc) -> integer (server, CFX).
    Runtime helpers, not natives: TriggerLatentClientEvent(name, target, bps, ...) (citizen scheduler.lua),
    SetTimeout, AddEventHandler, json.encode.
]]

local MapRegions = {}
Core.MapRegions = MapRegions

local KEY_OFFSET <const> = 32768          -- key = (rx + OFFSET) * SPAN + (ry + OFFSET)
local KEY_SPAN <const> = 65536
local KEY_MAX <const> = KEY_SPAN * KEY_SPAN - 1
local DEFAULT_REGION_SIZE <const> = 512.0
local MIN_REGION_SIZE <const> = 64.0
local MAX_REGION_SIZE <const> = 4096.0
local DEFAULT_BPS <const> = 250000
local MIN_BPS <const> = 1000
local DEFAULT_PUSH_OPS <const> = 32
local DEFAULT_BUDGET_BYTES <const> = 2000000   -- per-src pack budget (token bucket capacity)
local DEFAULT_BUDGET_WINDOW_MS <const> = 10000 -- time for an empty budget to refill completely
local MAX_PUSH_OPS <const> = 1000
local MAX_BUCKET <const> = 0x7FFFFFFF
local MAX_UID_LEN <const> = 128
local WINDOW_MAX <const> = 9               -- the 3×3 block; also the cap on `h` entries
local COOLDOWN_MS <const> = 250
local HIDDEN_FLAGS <const> = 8 | 16         -- FLAG_EDITOR | FLAG_DATA (§52.4a): editors only (M6)
local PUBLIC <const> = 1                    -- subscriber audiences (the value in subs[bucket][key][src])
local EDITOR <const> = 2
local EMPTY <const> = {}

--- Config.Maps.RegionSize, resolved ONCE: every key a client computed depends on it.
local REGION_SIZE <const> = (function()
    local maps = type(Config) == 'table' and Config.Maps or nil
    local size = type(maps) == 'table' and tonumber(maps.RegionSize) or nil
    if not size or size ~= size then return DEFAULT_REGION_SIZE end
    return math.min(MAX_REGION_SIZE, math.max(MIN_REGION_SIZE, size + 0.0))
end)()

-- [bucket] = { [key] = { v (full version), pv (public version), e = { [uid] = tuple }, n, nd (hidden count),
--              pack (public), packFull } }
local regions = {}
local where = {}       -- [bucket] = { [uid] = key }
local subs = {}        -- [bucket] = { [key] = { [src] = PUBLIC|EDITOR } }
local win = {}         -- [src] = { bucket, editor, n, keys = { key, … }, sent = { [key] = version }, tokens, at }
local dirty = {}       -- [bucket] = { [key] = { full = change, pub = change|nil } }, change = { from, to, ops, n, over }
local seq = 0          -- the module-wide version counter
local flushQueued = false
local counts = {
    regions = 0, elements = 0, hidden = 0, subscribers = 0, packs = 0,   -- current sizes
    encodes = 0, packsSent = 0, deltas = 0, stales = 0, packets = 0, windows = 0,   -- totals since start
    withheld = 0,
}
local editorTargets, editorLen = {}, 0   -- the reused emitMany target arrays, one per audience
local publicTargets, publicLen = {}, 0
local block = {}                    -- the reused 3×3 key block of a window request

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function mapsConfig()
    local maps = type(Config) == 'table' and Config.Maps or nil
    return type(maps) == 'table' and maps or EMPTY
end

--- Config.Maps.LatentBps (live), at least MIN_BPS.
local function latentBps()
    local v = tonumber(mapsConfig().LatentBps)
    if not v or v ~= v or v < MIN_BPS then return DEFAULT_BPS end
    return math.floor(math.min(v, 1e9))
end

--- Config.Maps.PushOpsMax (live), 0..MAX_PUSH_OPS; 0 turns every change into a `stale` notice.
local function pushOpsMax()
    local v = tonumber(mapsConfig().PushOpsMax)
    if not v or v ~= v or v < 0 then return DEFAULT_PUSH_OPS end
    return math.floor(math.min(v, MAX_PUSH_OPS))
end

--- Config.Maps.PackBudgetBytes (live), > 0: the burst a src may download in packs.
local function budgetBytes()
    local v = tonumber(mapsConfig().PackBudgetBytes)
    if not v or v ~= v or v <= 0 or v == math.huge then return DEFAULT_BUDGET_BYTES end
    return v
end

--- Config.Maps.PackBudgetWindowMs (live), > 0: an empty budget is full again after this long.
local function budgetWindowMs()
    local v = tonumber(mapsConfig().PackBudgetWindowMs)
    if not v or v ~= v or v <= 0 or v == math.huge then return DEFAULT_BUDGET_WINDOW_MS end
    return v
end

local function isBucket(bucket)
    return math.type(bucket) == 'integer' and bucket >= 0 and bucket <= MAX_BUCKET
end

local function isUid(uid)
    if math.type(uid) == 'integer' then return true end
    return type(uid) == 'string' and #uid > 0 and #uid <= MAX_UID_LEN
end

local function isFinite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

--- Region index of one world axis value, clamped into the key range.
local function axis(v)
    local c = math.floor(v / REGION_SIZE)
    if c < -KEY_OFFSET then return -KEY_OFFSET end
    if c >= KEY_OFFSET then return KEY_OFFSET - 1 end
    return c
end

local function keyOf(x, y)
    return (axis(x) + KEY_OFFSET) * KEY_SPAN + (axis(y) + KEY_OFFSET)
end

--- The §52.4a shape: tuple[1] == uid, tuple[2..11] finite numbers (flags, [10], an integer >= 0),
--- tuple[12] (extra) absent or a table.
local function isTuple(uid, tuple)
    if type(tuple) ~= 'table' or tuple[1] ~= uid then return false end
    for i = 2, 11 do
        if not isFinite(tuple[i]) then return false end
    end
    if math.type(tuple[10]) ~= 'integer' or tuple[10] < 0 then return false end
    local extra = tuple[12]
    return extra == nil or type(extra) == 'table'
end

--- A tuple every subscriber may see: neither FLAG_DATA nor FLAG_EDITOR (those reach editors only).
local function isPublic(tuple)
    return tuple[10] & HIDDEN_FLAGS == 0
end

--- json.encode that never throws (the runtime's encoder refuses NaN and some mixed tables). nil on failure.
local function encode(value)
    local ok, out = pcall(json.encode, value)
    if ok and type(out) == 'string' then return out end
    Core.Log.error('MapRegions: a region could not be encoded (%s)', tostring(out))
    return nil
end

--------------------------------------------------------------------------------
-- Audiences (review M6 / R2-8)
--------------------------------------------------------------------------------

--- Is `bucket` an open draft's editor bucket? (Core.MapsRuntime.state.editorBuckets, [mapId] = bucket: a
--- handful of open drafts at most.)
local function inEditorBucket(bucket)
    local runtime = Core.MapsRuntime
    local open = runtime and runtime.state and runtime.state.editorBuckets
    if type(open) == 'table' then
        for _, editorBucket in pairs(open) do
            if editorBucket == bucket then return true end
        end
    end
    return false
end

--- Admin mode `editor` on for `src`?
local function editorMode(src)
    local admin = Core.Admin
    if not (admin and admin.getModes) then return false end
    local modes = admin.getModes(src)
    return type(modes) == 'table' and modes.editor ~= nil
end

--- An editor sees the hidden (FLAG_DATA / FLAG_EDITOR) tuples: Admin mode `editor` is on, or `src` stands in
--- an open draft's editor bucket. Evaluated on every window request; a LOSS is also applied server-side at
--- once (staffModeChanged / permsChanged hooks, and the per-flush check of every editor target, R2-8).
local function isEditor(src, bucket)
    return editorMode(src) or inEditorBucket(bucket)
end

--- The review R2-8 guard: an EDITOR subscriber is re-checked before it receives a full delta — still in that
--- bucket (a server-side bucket change is seen here) and still an editor. Memoised per flush.
local confirmed = {}   -- [src] = boolean, cleared at the end of every flush
local function confirmEditor(src, bucket)
    local known = confirmed[src]
    if known == nil then
        known = math.tointeger(GetPlayerRoutingBucket(src)) == bucket and isEditor(src, bucket)
        confirmed[src] = known
    end
    return known
end

--- Takes the editor audience away from `src` at once: every subscription of its window becomes PUBLIC and
--- each region whose public view differs from the full one gets `core:maps:stale (bucket, key, pv)`, so the
--- client drops the hidden tuples and re-fetches the public pack. @return boolean it was an editor
local function downgrade(src)
    local w = win[src]
    if not w or not w.editor then return false end
    w.editor = false
    local bucket = w.bucket
    local bsubs, byKey = subs[bucket], regions[bucket]
    for i = 1, w.n do
        local key = w.keys[i]
        local set = bsubs and bsubs[key]
        if set and set[src] ~= nil then set[src] = PUBLIC end
        local region = byKey and byKey[key]
        if region and region.v ~= region.pv then
            Core.Net.emit(src, 'core:maps:stale', bucket, key, region.pv)
            counts.stales = counts.stales + 1
            counts.packets = counts.packets + 1
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Pushes: changes queue per (bucket, key) and audience; one flush per dirty cycle
--------------------------------------------------------------------------------

--- Splits a subscriber set into the reused editor / public target arrays (tails cleared: `#` is exact).
--- @return integer editors, integer publics
local function splitTargets(set, bucket)
    local ne, np = 0, 0
    for src, audience in pairs(set) do
        if audience == EDITOR and not confirmEditor(src, bucket) then
            downgrade(src)   -- sets set[src] = PUBLIC (assigning an existing key while traversing is allowed)
            audience = PUBLIC
        end
        if audience == EDITOR then
            ne = ne + 1
            editorTargets[ne] = src
        else
            np = np + 1
            publicTargets[np] = src
        end
    end
    for i = ne + 1, editorLen do editorTargets[i] = nil end
    for i = np + 1, publicLen do publicTargets[i] = nil end
    editorLen, publicLen = ne, np
    return ne, np
end

--- One audience's coalesced change of a region: a delta with its ops, or a stale notice.
local function push(targets, bucket, key, change)
    if not change or change.from == change.to then return end
    local sent
    local ops = not change.over and encode(change.ops) or nil
    if ops then
        sent = Core.Net.emitMany(targets, 'core:maps:delta', bucket, key, change.from, change.to, ops)
        counts.deltas = counts.deltas + 1
    else   -- too many ops, a clear, or ops that would not encode: the clients re-fetch
        sent = Core.Net.emitMany(targets, 'core:maps:stale', bucket, key, change.to)
        counts.stales = counts.stales + 1
    end
    counts.packets = counts.packets + (sent or 0)
end

--- Sends every change queued since the last flush — editors get the full change, everybody else the public
--- one (only when the public view changed) — and nothing for a region nobody holds. Runs from the
--- SetTimeout(0) of the cycle, and synchronously before a window answer so a fresh subscriber never
--- receives a delta it already has.
local function flush()
    flushQueued = false
    local batch = dirty
    if next(batch) == nil then return end
    dirty = {}
    for bucket, byKey in pairs(batch) do
        local bsubs = subs[bucket]
        if bsubs then
            for key, entry in pairs(byKey) do
                local set = bsubs[key]
                if set then
                    local ne, np = splitTargets(set, bucket)
                    if ne > 0 then push(editorTargets, bucket, key, entry.full) end
                    if np > 0 then push(publicTargets, bucket, key, entry.pub) end
                end
            end
        end
    end
    splitTargets(EMPTY)   -- do not keep srcs referenced between flushes
    for src in pairs(confirmed) do confirmed[src] = nil end
end

--- Records one version step of one audience; `op` nil = that audience must re-fetch (stale).
local function step(change, toV, op)
    change.to = toV
    if change.over then return end
    local n = change.n + 1
    if op == nil or n > pushOpsMax() then
        change.over, change.ops = true, nil   -- a stale notice needs no ops: free them now
    else
        change.ops[n], change.n = op, n
    end
end

--- Queues one change of (bucket, key): the full view always, the public view only when `pubChanged`.
local function queue(bucket, key, fullFrom, fullTo, op, pubChanged, pubFrom, pubTo, pubOp)
    local byKey = dirty[bucket]
    if not byKey then
        byKey = {}
        dirty[bucket] = byKey
    end
    local entry = byKey[key]
    if not entry then
        entry = { full = { from = fullFrom, to = fullFrom, ops = {}, n = 0, over = false }, pub = nil }
        byKey[key] = entry
    end
    step(entry.full, fullTo, op)
    if pubChanged then
        local pub = entry.pub
        if not pub then
            pub = { from = pubFrom, to = pubFrom, ops = {}, n = 0, over = false }
            entry.pub = pub
        end
        step(pub, pubTo, pubOp)
    end
    if not flushQueued then
        flushQueued = true
        SetTimeout(0, flush)
    end
end

local function dropPacks(region, full, public)
    if full and region.packFull then
        region.packFull = nil
        counts.packs = counts.packs - 1
    end
    if public and region.pack then
        region.pack = nil
        counts.packs = counts.packs - 1
    end
end

--- Bumps a region after its content changed and queues the ops. The full version always moves (0 once
--- empty); the public version only when the public view changed: 0 when no public tuple is left, the full
--- version itself while the region holds no hidden tuple (same content, same number), else a number of its
--- own — so a version number never stands for two different contents, whoever holds it.
local function touch(bucket, key, region, op, pubChanged, pubOp)
    local fullFrom, pubFrom = region.v, region.pv
    local fullTo = 0
    if region.n > 0 then
        seq = seq + 1
        fullTo = seq
    end
    region.v = fullTo
    local pubTo = pubFrom
    if pubChanged then
        if region.n - region.nd <= 0 then
            pubTo = 0
        elseif region.nd == 0 then
            pubTo = fullTo
        else
            seq = seq + 1
            pubTo = seq
        end
        region.pv = pubTo
    end
    dropPacks(region, true, pubChanged)
    queue(bucket, key, fullFrom, fullTo, op, pubChanged, pubFrom, pubTo, pubOp)
end

--------------------------------------------------------------------------------
-- Content: put / remove / clearBucket
--------------------------------------------------------------------------------

--- Takes `uid` out of the region `key` of `bucket` (a remove, or the old half of a move).
local function detach(bucket, uid, key)
    local locs = where[bucket]
    if locs then
        locs[uid] = nil
        if next(locs) == nil then where[bucket] = nil end
    end
    local byKey = regions[bucket]
    local region = byKey and byKey[key]
    local old = region and region.e[uid]
    if old == nil then return end
    local wasPublic = isPublic(old)
    region.e[uid] = nil
    region.n = region.n - 1
    counts.elements = counts.elements - 1
    if not wasPublic then
        region.nd = region.nd - 1
        counts.hidden = counts.hidden - 1
    end
    local op = { o = 'del', u = uid }
    touch(bucket, key, region, op, wasPublic, wasPublic and op or nil)
    if region.n == 0 then
        dropPacks(region, true, true)
        byKey[key] = nil
        counts.regions = counts.regions - 1
        if next(byKey) == nil then regions[bucket] = nil end
    end
end

--- Adds or moves one client-rendered element. A move to another region deletes it from the old one first.
--- A tuple flagged FLAG_DATA / FLAG_EDITOR is hidden: only editor subscribers ever see it (§52.3, M6).
--- @return boolean ok
function MapRegions.put(bucket, uid, tuple)
    if not isBucket(bucket) or not isUid(uid) or not isTuple(uid, tuple) then
        Core.Log.warn('MapRegions.put: invalid bucket %s / uid %s / tuple', tostring(bucket), tostring(uid))
        return false
    end
    local key = keyOf(tuple[4], tuple[5])
    local locs = where[bucket]
    local oldKey = locs and locs[uid]
    if oldKey and oldKey ~= key then detach(bucket, uid, oldKey) end
    local byKey = regions[bucket]
    if not byKey then
        byKey = {}
        regions[bucket] = byKey
    end
    local region = byKey[key]
    if not region then
        region = { v = 0, pv = 0, e = {}, n = 0, nd = 0, pack = nil, packFull = nil }
        byKey[key] = region
        counts.regions = counts.regions + 1
    end
    local old = region.e[uid]
    local wasPublic = old ~= nil and isPublic(old)
    local nowPublic = isPublic(tuple)
    if old == nil then
        region.n = region.n + 1
        counts.elements = counts.elements + 1
    elseif not wasPublic then
        region.nd = region.nd - 1
        counts.hidden = counts.hidden - 1
    end
    if not nowPublic then
        region.nd = region.nd + 1
        counts.hidden = counts.hidden + 1
    end
    region.e[uid] = tuple
    locs = where[bucket]
    if not locs then
        locs = {}
        where[bucket] = locs
    end
    locs[uid] = key
    local op = { o = 'put', t = tuple }
    -- the public view: a put when it is public now, a del when it just became hidden, nothing otherwise
    local pubOp = nowPublic and op or (wasPublic and { o = 'del', u = uid }) or nil
    touch(bucket, key, region, op, wasPublic or nowPublic, pubOp)
    return true
end

--- Removes one element. @return boolean removed (false when (bucket, uid) is unknown)
function MapRegions.remove(bucket, uid)
    local locs = where[bucket]
    local key = locs and locs[uid]
    if not key then return false end
    detach(bucket, uid, key)
    return true
end

--- Removes every element of `bucket`; each region that had content becomes a `stale` notice (toV 0) for its
--- subscribers — public subscribers only where public content existed (coalesced with anything else that
--- changes in the same tick). @return integer removed
function MapRegions.clearBucket(bucket)
    if not isBucket(bucket) then return 0 end
    local byKey = regions[bucket]
    where[bucket] = nil
    if not byKey then return 0 end
    regions[bucket] = nil
    local removed = 0
    for key, region in pairs(byKey) do
        removed = removed + region.n
        counts.elements = counts.elements - region.n
        counts.hidden = counts.hidden - region.nd
        counts.regions = counts.regions - 1
        dropPacks(region, true, true)
        queue(bucket, key, region.v, 0, nil, region.pv ~= 0, region.pv, 0, nil)
    end
    return removed
end

--------------------------------------------------------------------------------
-- Windows: subscriptions and the `core:maps:window` callback
--------------------------------------------------------------------------------

--- Removes `src` from the subscriber set of (bucket, key), dropping emptied tables.
local function unlink(src, bucket, key)
    local bsubs = subs[bucket]
    local set = bsubs and bsubs[key]
    if not set then return end
    set[src] = nil
    if next(set) == nil then
        bsubs[key] = nil
        if next(bsubs) == nil then subs[bucket] = nil end
    end
end

--- Fills the reused `block` with the (up to 9) keys of the 3×3 block around `c`, the centre FIRST (it gets
--- the pack budget first: the camera is there). @return integer count
local function blockAround(c)
    local rx, ry = c // KEY_SPAN - KEY_OFFSET, c % KEY_SPAN - KEY_OFFSET
    block[1] = c
    local n = 1
    for dx = -1, 1 do
        local x = rx + dx
        if x >= -KEY_OFFSET and x < KEY_OFFSET then
            for dy = -1, 1 do
                local y = ry + dy
                if (dx ~= 0 or dy ~= 0) and y >= -KEY_OFFSET and y < KEY_OFFSET then
                    n = n + 1
                    block[n] = (x + KEY_OFFSET) * KEY_SPAN + (y + KEY_OFFSET)
                end
            end
        end
    end
    for i = n + 1, WINDOW_MAX do block[i] = nil end
    return n
end

local function inBlock(n, key)
    for i = 1, n do
        if block[i] == key then return true end
    end
    return false
end

--- Moves `src`'s subscription to the `n` keys in `block` of `bucket` with `audience`. Keys that stay cost
--- nothing; a bucket change drops the whole old block. @return table the src's window record
local function subscribe(src, bucket, n, audience)
    local w = win[src]
    if not w then
        w = { bucket = bucket, editor = false, n = 0, keys = {}, sent = {}, tokens = budgetBytes(),
            at = GetGameTimer() }
        win[src] = w
        counts.subscribers = counts.subscribers + 1
    end
    local keys, sent = w.keys, w.sent
    if w.bucket ~= bucket then
        for i = 1, w.n do unlink(src, w.bucket, keys[i]) end
        for key in pairs(sent) do sent[key] = nil end
        w.bucket = bucket
    else
        for i = 1, w.n do
            local key = keys[i]
            if not inBlock(n, key) then
                unlink(src, bucket, key)
                sent[key] = nil
            end
        end
    end
    local bsubs = subs[bucket]
    if not bsubs then
        bsubs = {}
        subs[bucket] = bsubs
    end
    for i = 1, n do
        local key = block[i]
        local set = bsubs[key]
        if not set then
            set = {}
            bsubs[key] = set
        end
        set[src] = audience
        keys[i] = key
    end
    for i = n + 1, WINDOW_MAX do keys[i] = nil end
    w.n, w.editor = n, audience == EDITOR
    return w
end

--- Refills `w`'s pack budget (token bucket: `PackBudgetBytes` capacity, full again after `PackBudgetWindowMs`).
--- @return number capacity
local function refill(w)
    local cap = budgetBytes()
    local now = GetGameTimer()
    local elapsed = now - w.at
    if elapsed > 0 then
        w.tokens = w.tokens + elapsed * cap / budgetWindowMs()
        w.at = now
    end
    if w.tokens > cap then w.tokens = cap end
    return cap
end

--- The region's pack string for one audience (`full`: every tuple at `v`; public: the public tuples at `pv`),
--- encoded on the first request after a change and cached until the next one. While `v == pv` the two views
--- are the same content, so one encode serves both.
local function packOf(region, full)
    local field = full and 'packFull' or 'pack'
    local pack = region[field]
    if pack then return pack end
    if region.v == region.pv then
        pack = region[full and 'pack' or 'packFull']
        if pack then
            region[field] = pack
            counts.packs = counts.packs + 1
            return pack
        end
    end
    local list, n = {}, 0
    for _, tuple in pairs(region.e) do
        if full or isPublic(tuple) then
            n = n + 1
            list[n] = tuple
        end
    end
    counts.encodes = counts.encodes + 1
    pack = encode({ v = full and region.v or region.pv, e = list })
    if not pack then return nil end
    region[field] = pack
    counts.packs = counts.packs + 1
    return pack
end

--- `core:maps:window`. The schema (type, c's range, h's size) and the 250 ms cooldown ran in the Callback
--- wrapper; here: h's entries, then the bucket from the server, never from the payload, then the audience.
local function onWindow(src, req)
    local h = req.h
    if h ~= nil then
        for key, version in pairs(h) do
            if math.type(key) ~= 'integer' or math.type(version) ~= 'integer' or version < 0 then return nil end
        end
    end
    local bucket = math.tointeger(GetPlayerRoutingBucket(src))
    if not isBucket(bucket) then return nil end
    if flushQueued then flush() end   -- pending deltas reach the current subscribers first
    local n = blockAround(req.c)
    local editor = isEditor(src, bucket)
    local w = subscribe(src, bucket, n, editor and EDITOR or PUBLIC)
    local sent = w.sent
    local byKey = regions[bucket]
    local versions, withheld = {}, {}
    local bps = latentBps()
    local cap = refill(w)
    for i = 1, n do
        local key = block[i]
        local region = byKey and byKey[key]
        -- the audience's version: a region with nothing public is 0 (empty) for everyone but editors
        local v = region and (editor and region.v or region.pv) or 0
        versions[key] = v
        if v ~= 0 then
            -- `sent`: this pack already went to this src during the current subscription (it holds it or it is
            -- in flight), so a repeated request cannot make the server send the same bytes again. A version
            -- number names exactly one content for either audience, so this holds across audience changes.
            if (h and h[key]) ~= v and sent[key] ~= v then
                local pack = packOf(region, editor)
                -- the budget: a pack that does not fit is withheld (w[key]) and asked for again later; a pack
                -- larger than the whole budget goes out when the budget is full and leaves it in debt
                if pack and (#pack <= w.tokens or w.tokens >= cap) then
                    w.tokens = w.tokens - #pack
                    sent[key] = v
                    TriggerLatentClientEvent('core:maps:pack', src, bps, bucket, key, pack)
                    counts.packsSent = counts.packsSent + 1
                elseif pack then
                    withheld[key] = true
                    counts.withheld = counts.withheld + 1
                end
            end
        end
    end
    counts.windows = counts.windows + 1
    return { b = bucket, v = versions, w = withheld }
end

local WINDOW_SCHEMA <const> = { { 'table', max = 2, keys = {
    c = { 'integer', min = 0, max = KEY_MAX },
    h = { 'table', max = WINDOW_MAX, optional = true },
} } }

Core.Callback.register('core:maps:window', WINDOW_SCHEMA, onWindow, { cooldownMs = COOLDOWN_MS })

--- Drops `src`'s window (all its subscriptions). @return boolean had one
function MapRegions.unsubscribe(src)
    local w = win[src]
    if not w then return false end
    for i = 1, w.n do unlink(src, w.bucket, w.keys[i]) end
    win[src] = nil
    counts.subscribers = counts.subscribers - 1
    return true
end

AddEventHandler('playerDropped', function()
    local src = source
    MapRegions.unsubscribe(tonumber(src) or src)
end)

--- Re-checks `src`'s audience now (review R2-8): still in its window's bucket and still an editor there.
--- Only a LOSS acts server-side (the editor flag goes at once, full deltas stop, `core:maps:stale` for every
--- region whose public view differs); a gain waits for the client's next window request.
--- `modeOn` (optional): whether Admin mode `editor` is on, when the caller already knows it.
--- @return boolean downgraded
function MapRegions.reaudience(src, modeOn)
    local w = win[src]
    if not w or not w.editor then return false end
    local bucket = w.bucket
    local still = math.tointeger(GetPlayerRoutingBucket(src)) == bucket
    if still then
        if modeOn == nil then modeOn = editorMode(src) end
        still = modeOn == true or inEditorBucket(bucket)
    end
    if still then return false end
    return downgrade(src)
end

--- `editor` in a staffModeChanged payload: a { [mode] = data } map or an array of names; nil = unreadable.
local function editorInPayload(modes)
    if type(modes) ~= 'table' then return nil end
    if modes.editor ~= nil then return true end
    for _, name in ipairs(modes) do
        if name == 'editor' then return true end
    end
    return false
end

if type(Core.on) == 'function' then
    -- server hooks (local events): mode changes from server/adminapi.lua, rank changes from perms / player
    Core.on('staffModeChanged', function(src, modes)
        MapRegions.reaudience(tonumber(src) or src, editorInPayload(modes))
    end)
    Core.on('permsChanged', function(src)
        MapRegions.reaudience(tonumber(src) or src)
    end)
end

--------------------------------------------------------------------------------
-- Diagnostics
--------------------------------------------------------------------------------

--- The region key of a world position (the same maths the client uses).
function MapRegions.keyOf(x, y)
    if not isFinite(x) or not isFinite(y) then return nil end
    return keyOf(x, y)
end

--- The current versions of (bucket, key): full (what editors see) and public; 0 = empty for that audience.
--- @return integer full, integer public
function MapRegions.version(bucket, key)
    local byKey = regions[bucket]
    local region = byKey and byKey[key]
    if not region then return 0, 0 end
    return region.v, region.pv
end

--- Counters: current sizes (regions, elements, hidden = editor-only elements, subscribers = players with a
--- window, packs = cached pack slots) and totals since start (encodes, packsSent, deltas, stales, pushes =
--- deltas + stales, packets = client packets pushed, windows = window requests answered, withheld = packs held
--- back by the per-src budget). `regionSize` and `version` (the counter) for context.
function MapRegions.stats()
    return {
        regions = counts.regions, elements = counts.elements, hidden = counts.hidden,
        subscribers = counts.subscribers,
        packs = counts.packs, encodes = counts.encodes, packsSent = counts.packsSent,
        deltas = counts.deltas, stales = counts.stales, pushes = counts.deltas + counts.stales,
        packets = counts.packets, windows = counts.windows, withheld = counts.withheld,
        regionSize = REGION_SIZE, version = seq,
    }
end
