--[[
    core/server/scene_flush.lua — R.flush (DESIGN §55.7): the 20 Hz flush, outboxes, one reliable event per client
    per tick, latent packs under a byte budget. Loads after server/scene_gated.lua (asserted) and before
    server/scene_store.lua; internal (Core.SceneRuntime, block-listed in server/api.lua).

      thread    exists only while something is pending (a queued item, a waiting pack, a capped DR op, or
                R.index.pending()); R.flush.wake() / queue / queuePack start it (its first step waits a frame, so a
                wake from inside an index call never runs a tick re-entrantly), it ends after the first idle check —
                no polling, no natives while idle. One tick per FlushMs: R.index.drain() → entries to the subscribers
                whose ring reads the variant and whose `sent` is the entry's `from` (nothing when they already have
                `to`, else SUB + the pack: resync; an entry over MaxEventBytes is never one giant reliable event —
                SUB(to) + the cell's pack, forced latent: RV1 F9) → R.interest.fill(over) (new subscriptions at
                clean versions; the budget is asked after every cell, the rest resumes) → R.interest.gated (PRIV
                sections) → C4 events (subscribers of the event's cell / region / global set whose focus is within
                the radius; a node with an effective audience — R.store.audienceOf: own + ancestors — reaches only
                the holders of its unit) → C2 DR ops (same rule; per node and ring ≤ NearHz / FarHz, latest wins)
                → every dirty client's ONE `core:scene:s` → then packs, clients from a rotating start,
                ≤ TICK_PACK_BYTES per tick in all.
      queues    per client, in send order: control (the SUBs and UNSUBs of R.interest and of this file), PRIV
                (R.flush.queuePriv: gated sections, FIFO, never dropped), near, far, transient (expiring). The
                event: header, RESET first after R.flush.reset (a bucket change: everything queued and every waiting
                pack of the old bucket is purged — RV1 F17 / F18), a KINDS delta when the client's table is older,
                then the queues in order up to MaxEventBytes (an item larger than that goes alone: `oversized`).
                R.flush.queue's documented priorities 1..4 (control, near, far, transient) map onto them.
      packs     R.flush.queuePack(src, blob, prio, key, latent?) spends a per-src token bucket (PackBudgetBytes,
                full again after PackBudgetWindowMs; a pack larger than the whole budget goes when it is full and
                leaves it in debt). R.flush.spend(src, bytes, force?) charges the same bucket for journal answers
                (RV1 F5) and PRIV grants (force: never held back). Small packs ride the reliable stream while its
                backlog is short; the rest go as ONE `core:scene:p` latent event per client per tick (header and
                packs in one concatenation, LatentBps), never before their SUB left. Withheld packs wait (FIFO) and
                are retried every tick; a newer pack of the same key replaces a waiting one; R.flush.cancel drops
                one whose cell left the window.
      backlog   a client whose queued near / far / transient bytes exceed MaxBacklogBytes loses them and every
                subscription is resynced through a latent pack (SUB first). Control and PRIV are neither counted
                nor dropped (a lost PRIV DEL would leak a gated node; RV1 F14).
      stats     flush ms p50 / p99 over the last 256 ticks; a tick over 5 ms logs its counters once a minute.

    Natives (fxref + natives_cfx.json 2026-09-26, CFX apiset server): TriggerClientEventInternal(eventName,
    eventTarget, eventPayload, payloadLength), GetGameTimer() -> long. Runtime helpers: TriggerLatentClientEvent
    (scheduler.lua), TriggerClientEvent (the offline fallback), msgpack.pack_args, CreateThread, Wait.
]]

local R = Core.SceneRuntime
assert(type(R) == 'table' and type(R.index) == 'table' and type(R.interest) == 'table'
    and type(R.interest.gated) == 'function', 'server/scene_gated.lua must load before server/scene_flush.lua')

local Flush = {}
R.flush = Flush

local Index, Interest = R.index, R.interest
local Log = Core.Log

local GRID_SPAN <const> = 4294967296
local KEY_OFFSET <const> = 32768
local KEY_SPAN <const> = 65536
local G_NEAR <const>, G_FAR <const>, G_GLOBAL <const> = 0, 1, 2
local V_NEAR <const>, V_FAR <const>, V_ONE <const> = 1, 2, 3
local PENDING <const> = -1                 -- R.interest's `sent` of a subscription waiting for its fill
local IDLE_MS <const> = 250
local SLOW_TICK_MS <const> = 5
local LOG_EVERY_MS <const> = 60000
local LATENT_MAX <const> = 524288          -- bytes of packs in one latent event (the rest waits a tick)
local FILL_BUDGET_US <const> = 4000        -- new subscriptions filled per tick at most this long (join storms)
local TICK_PACK_BYTES <const> = 1048576    -- pack bytes released per tick, all clients (bounds a join storm's frame)
local RING <const> = 256                   -- tick durations kept for p50 / p99
local EMPTY <const> = {}

local function cfgNum(tbl, key, default, lo, hi)
    local v = type(tbl) == 'table' and tonumber(tbl[key]) or nil
    if not v or v ~= v then return default end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local S = type(Config) == 'table' and type(Config.Scene) == 'table' and Config.Scene or EMPTY
local DR = type(S.DeadReckoning) == 'table' and S.DeadReckoning or EMPTY
local FLUSH_MS <const> = math.floor(cfgNum(S, 'FlushMs', 50, 0, 1000))
local MAX_EVENT <const> = math.floor(cfgNum(S, 'MaxEventBytes', 16384, 1024, 1048576))
local MAX_BACKLOG <const> = math.floor(cfgNum(S, 'MaxBacklogBytes', 262144, 16384, 67108864))
local LATENT_BPS <const> = math.floor(cfgNum(S, 'LatentBps', 750000, 1000, 1e9))
local BUDGET <const> = cfgNum(S, 'PackBudgetBytes', 2000000, 1024, 1e9) + 0.0
local BUDGET_MS <const> = cfgNum(S, 'PackBudgetWindowMs', 10000, 1, 3600000) + 0.0
local NEAR_GAP_MS <const> = math.floor(1000 / cfgNum(DR, 'NearHz', 10, 0.01, 1000))
local FAR_GAP_MS <const> = math.floor(1000 / cfgNum(DR, 'FarHz', 1, 0.01, 1000))
local FAR_RING <const> = cfgNum(S, 'FarRing', 448, 0, 8192) + 0.0
local FAR_REGIONS <const> = cfgNum(S, 'FarRegions', 1024, 0, 16384) + 0.0
local CELL <const> = cfgNum(S, 'CellSize', 128, 16, 1024) + 0.0
local REGION <const> = cfgNum(S, 'RegionSize', 512, 64, 4096) + 0.0

local packArgs = type(msgpack) == 'table' and msgpack.pack_args or nil
local microtime = (type(os) == 'table' and (os.microtime or (os.clock and function() return os.clock() * 1e6 end)))
    or function() return 0 end

local function Codec() return Core.SceneCodec end

local function isSrc(src) return math.type(src) == 'integer' and src > 0 end

local function variantOf(grid, ring)
    if grid ~= G_NEAR then return V_ONE end
    return ring == 1 and V_NEAR or V_FAR
end

--- A near-cell subscriber on the far ring holds M-tier roots only (the far variant's rule): DR ops follow it.
local function ringCovers(node, grid, ring)
    return grid ~= G_NEAR or ring == 1 or node.tier == 'M'
end

--- Core.Clock.now() when the lib is there (u32 ms), else the game timer: the timeline of the wire header.
local function clockNow()
    local clock = Core.Clock
    local fn = clock and clock.now
    if fn then return fn() end
    return GetGameTimer() & 0xFFFFFFFF
end

local counts = {
    ticks = 0, events = 0, bytesOut = 0, latentEvents = 0, latentBytes = 0, packs = 0, packBytes = 0,
    withheld = 0, dropped = 0, droppedBytes = 0, overflows = 0, resyncs = 0, skipped = 0, entries = 0,
    transient = 0, expired = 0, drSent = 0, drCapped = 0, kinds = 0, oversized = 0, slowTicks = 0,
    resets = 0, bigEntries = 0, privSections = 0, privBytes = 0,
}

-- The queues of a client, in send order: control (SUB / UNSUB), PRIV (gated ops: ordered, never dropped), near,
-- far, transient. Flush.queue's documented priorities 1..4 (control, near, far, transient) map onto them.
local P_CONTROL <const>, P_PRIV <const>, P_NEAR <const>, P_FAR <const>, P_TRANSIENT <const> = 1, 2, 3, 4, 5
local EXTERNAL <const> = { P_CONTROL, P_NEAR, P_FAR, P_TRANSIENT }

--- a is newer than b as serial numbers (the signed 32-bit difference: versions wrap after 2^32).
local function newer(a, b)
    return ((a - b + 0x80000000) & 0xFFFFFFFF) - 0x80000000 > 0
end

--- The effective audience (R.store.audienceOf: own + ancestors, looked up at call time), else the node's own.
local function audienceOf(node)
    local store = R.store
    local fn = store and store.audienceOf
    if fn then
        local ok, aud = pcall(fn, node)
        if ok then return aud end
    end
    return node.audience
end
local lastSlowLog = -LOG_EVERY_MS

--------------------------------------------------------------------------------
-- Outboxes and the thread's start
--------------------------------------------------------------------------------

local boxes = {}       -- [src] = { [1..5] = { h, t, [i] = blob }, exp, bytes, pub, reset, pk, pkKey, tokens, at }
local dirty = {}       -- [src] = true: something queued
local woken = false
local runner = { on = false }   -- the flush thread: runner.on while it exists; runner.loop is defined at the end

--- Starts the flush thread unless it runs (wake, queue, queuePack).
local function start()
    if runner.on then return end
    runner.on = true
    CreateThread(runner.loop)
end

local function newQueue() return { h = 1, t = 0 } end

--- A client's queues: [1..5] (control, PRIV, near, far, transient), `exp` the transient expiries, `bytes` all
--- queued bytes, `pub` those of near / far / transient (the backlog guard's measure), `reset` = RESET goes first
--- in the next event, `pk` the waiting packs as parallel arrays (blob / prio / key / latent / sub = its SUB's
--- position in the control queue, which never restarts its indexes; blob false = cancelled), `pkKey` [key] =
--- slot, the token bucket.
local function boxOf(src)
    local box = boxes[src]
    if not box then
        box = { newQueue(), newQueue(), newQueue(), newQueue(), newQueue(), exp = {}, bytes = 0, pub = 0,
            reset = false, pk = { h = 1, t = 0, blob = {}, prio = {}, key = {}, latent = {}, sub = {} }, pkKey = {},
            tokens = BUDGET, at = GetGameTimer() }
        boxes[src] = box
    end
    return box
end

--- The unchecked append of the hot paths: `box` is `src`'s, `p` one of the five queues, blob non-empty.
local function enqueue(box, src, blob, p)
    local q = box[p]
    local t = q.t + 1
    q.t, q[t] = t, blob
    local len = #blob
    box.bytes = box.bytes + len
    if p >= P_NEAR then box.pub = box.pub + len end
    dirty[src] = true
    if not runner.on then start() end
end

--- Queues one item for `src`'s next reliable event. prio 1 control, 2 near, 3 far, 4 transient (`expires`:
--- Clock ms after which a transient item is dropped unsent). FIFO within a priority.
function Flush.queue(src, blob, prio, expires)
    if not isSrc(src) or type(blob) ~= 'string' or blob == '' then return false end
    local p = EXTERNAL[prio] or P_NEAR
    local box = boxOf(src)
    enqueue(box, src, blob, p)
    if p == P_TRANSIENT then box.exp[box[P_TRANSIENT].t] = expires or false end
    return true
end

--- A PRIV section (server/scene_gated.lua): after the control ops, FIFO, never dropped by the backlog guard
--- and not counted by it (RV1 F14).
function Flush.queuePriv(src, blob)
    if not isSrc(src) or type(blob) ~= 'string' or blob == '' then return false end
    enqueue(boxOf(src), src, blob, P_PRIV)
    counts.privSections, counts.privBytes = counts.privSections + 1, counts.privBytes + #blob
    return true
end

--- A bucket reset (R.interest): everything queued and every waiting pack of `src` belongs to the old bucket
--- and goes; the next event starts with RESET (the client drops everything, LRU included, and reports its
--- focus), then the new window's SUBs (RV1 F17 / F18).
function Flush.reset(src)
    if not isSrc(src) then return false end
    local box = boxOf(src)
    for p = 1, P_TRANSIENT do
        local q = box[p]
        for i = q.h, q.t do q[i] = nil end
        if p == P_CONTROL then q.h = q.t + 1 else q.h, q.t = 1, 0 end
    end
    local exp = box.exp
    for i in pairs(exp) do exp[i] = nil end
    local pk = box.pk
    for i = pk.h, pk.t do pk.blob[i], pk.prio[i], pk.key[i], pk.latent[i], pk.sub[i] = nil, nil, nil, nil, nil end
    pk.h, pk.t = 1, 0
    for k in pairs(box.pkKey) do box.pkKey[k] = nil end
    box.bytes, box.pub, box.reset = 0, 0, true
    counts.resets = counts.resets + 1
    dirty[src] = true
    start()
    return true
end

--- Something will be pending for the next tick (R.index calls it when it queues ops): start the thread.
function Flush.wake()
    woken = true
    start()
end

--------------------------------------------------------------------------------
-- Packs: budgeted, reliable while the backlog is short, else latent (one event per client per tick)
--------------------------------------------------------------------------------

--- Queues a snapshot for `src`. `key` (the cell) dedupes: a newer pack replaces one still waiting (keeping its
--- place). `latent` forces the latent path. The SUB announcing it must have been queued before (prio 1).
function Flush.queuePack(src, blob, prio, key, latent)
    if not isSrc(src) or type(blob) ~= 'string' or blob == '' then return false end
    local box = boxOf(src)
    local pk = box.pk
    local slot = key ~= nil and box.pkKey[key] or nil
    if not slot then
        slot = pk.t + 1
        pk.t = slot
        pk.key[slot] = key or false
        if key ~= nil then box.pkKey[key] = slot end
    end
    pk.blob[slot], pk.prio[slot], pk.latent[slot], pk.sub[slot] = blob, EXTERNAL[prio] or P_NEAR, latent == true,
        box[P_CONTROL].t
    dirty[src] = true
    start()
    return true
end

function Flush.queueLatent(src, blob, key)
    return Flush.queuePack(src, blob, 3, key, true)
end

--- Drops a waiting pack of `key`; true when one was dropped (the client never got it).
function Flush.cancel(src, key)
    local box = boxes[src]
    local slot = box and box.pkKey[key]
    if not slot then return false end
    box.pkKey[key] = nil
    box.pk.blob[slot] = false
    return true
end

function Flush.cancelAll(src)
    local box = boxes[src]
    if not box then return 0 end
    local n, blobs = 0, box.pk.blob
    for key, slot in pairs(box.pkKey) do
        box.pkKey[key] = nil
        blobs[slot] = false
        n = n + 1
    end
    return n
end

function Flush.drop(src)
    boxes[src], dirty[src] = nil, nil
end

--- Queued reliable bytes of `src` (not counting waiting packs).
function Flush.backlog(src)
    local box = boxes[src]
    return box and box.bytes or 0
end

--- Every subscription of `src` again from its pack (the backlog guard): SUB, then a latent pack each.
local function resyncAll(src)
    local w = Interest.windowOf(src)
    if not w or w.bucket == nil then return 0 end
    local codec, n = Codec(), 0
    for cid, ring in pairs(w.cells) do
        local grid = cid // GRID_SPAN
        local key = cid - grid * GRID_SPAN
        local variant = variantOf(grid, ring)
        local pack, pv = Index.pack(w.bucket, grid, key, variant)
        pv = math.tointeger(pv) or 0
        Flush.queue(src, codec.sub(grid, key, variant, pv), 1)
        if pv ~= 0 and type(pack) == 'string' and pack ~= '' then
            w.sent[cid] = pv
            Flush.queuePack(src, pack, (grid == G_NEAR and ring == 2 or grid == G_FAR) and 3 or 2, cid, true)
            n = n + 1
        else
            w.sent[cid] = nil
        end
    end
    counts.resyncs = counts.resyncs + n
    return n
end

--- The backlog guard: the public near / far / transient items go (counted), every subscription resyncs through a
--- latent pack. Control and PRIV stay (a lost PRIV DEL would leak a gated node).
local function overflow(src, box)
    counts.overflows = counts.overflows + 1
    for p = P_NEAR, P_TRANSIENT do
        local q = box[p]
        for i = q.h, q.t do
            local blob = q[i]
            q[i] = nil
            if p == P_TRANSIENT then box.exp[i] = nil end
            box.bytes = box.bytes - #blob
            counts.dropped, counts.droppedBytes = counts.dropped + 1, counts.droppedBytes + #blob
        end
        q.h, q.t = 1, 0
    end
    box.pub = 0
    resyncAll(src)
end

--- Token bucket (PackBudgetBytes, full again after PackBudgetWindowMs).
local function refill(box, now)
    local elapsed = now - box.at
    if elapsed > 0 then
        box.tokens = math.min(BUDGET, box.tokens + elapsed * BUDGET / BUDGET_MS)
        box.at = now
    end
end

--- Spends `bytes` of `src`'s pack budget: journal answers (RV1 F5) and PRIV grants (`force`: never held back,
--- debt allowed — the packs behind them wait). @return boolean spent
function Flush.spend(src, bytes, force)
    if not isSrc(src) then return false end
    local box = boxOf(src)
    refill(box, GetGameTimer())
    if force or bytes <= box.tokens or box.tokens >= BUDGET then
        box.tokens = box.tokens - bytes
        return true
    end
    counts.withheld = counts.withheld + 1
    return false
end

local latentParts = {}
local tickPackBytes = 0                    -- pack bytes released in this tick (TICK_PACK_BYTES)

--- `src`'s waiting packs in order, while the budget allows: into the reliable queue while its backlog stays short,
--- else into this tick's latent event — and only once the pack's SUB left in a reliable event (the client ignores
--- a latent snapshot stamped before its SUB).
local function sendPacks(src, box, header, now)
    local pk = box.pk
    local h, t = pk.h, pk.t
    if h > t then return end
    refill(box, now)
    local blobs, prios, keys, latents, subs = pk.blob, pk.prio, pk.key, pk.latent, pk.sub
    local ln, lbytes = 0, 0
    while h <= t do
        local blob = blobs[h]
        if blob then
            local size = #blob
            if size > box.tokens and box.tokens < BUDGET then
                counts.withheld = counts.withheld + 1
                break
            end
            if tickPackBytes > 0 and tickPackBytes + size > TICK_PACK_BYTES then break end
            local reliable = not latents[h] and size <= MAX_EVENT and box.bytes + size <= 2 * MAX_EVENT
            if not reliable and (box[P_CONTROL].h <= subs[h] or (ln > 0 and lbytes + size > LATENT_MAX)) then break end
            box.tokens, tickPackBytes = box.tokens - size, tickPackBytes + size
            if reliable then
                enqueue(box, src, blob, prios[h])
            else
                ln, lbytes = ln + 1, lbytes + size
                latentParts[ln + 1] = blob              -- [1] is the header: ONE concatenation (RV1 F12)
            end
            counts.packs, counts.packBytes = counts.packs + 1, counts.packBytes + size
            local key = keys[h]
            if key and box.pkKey[key] == h then box.pkKey[key] = nil end
        end
        blobs[h], prios[h], keys[h], latents[h], subs[h] = nil, nil, nil, nil, nil
        h = h + 1
    end
    if h > t then h, t = 1, 0 end
    pk.h, pk.t = h, t
    if ln > 0 then
        latentParts[1] = header
        local payload = table.concat(latentParts, '', 1, ln + 1)
        for i = 1, ln + 1 do latentParts[i] = nil end
        TriggerLatentClientEvent('core:scene:p', src, LATENT_BPS, payload)
        counts.latentEvents, counts.latentBytes = counts.latentEvents + 1, counts.latentBytes + #payload
    end
end

--------------------------------------------------------------------------------
-- The tick
--------------------------------------------------------------------------------

--- A journal entry to every subscriber whose ring reads its variant: appended when the subscriber's `sent` is the
--- entry's `from`; nothing when it already has `to` or newer (serial numbers); the pack otherwise (resync). An
--- entry larger than MaxEventBytes is never one giant reliable event: its subscribers get SUB(to) and the cell's
--- pack through the budgeted pack path, forced latent (RV1 F9; one cached pack for all of them).
local function processEntries(entries)
    local codec, windowOf = Codec(), Interest.windowOf
    for i = 1, #entries do
        local e = entries[i]
        local grid, key, variant = e.grid, e.key, e.variant
        local subs = Interest.subscribers(e.bucket, grid, key)
        if subs then
            local from, to, blob = e.from, e.to, e.blob
            local cid = grid * GRID_SPAN + key
            local ext = (variant == V_NEAR or grid == G_GLOBAL) and 2 or 3
            local p = EXTERNAL[ext]
            local big = #blob > MAX_EVENT
            local pack, pv = nil, 0
            for src, ring in pairs(subs) do
                local w = variantOf(grid, ring) == variant and windowOf(src)
                if w then
                    local sentMap = w.sent
                    local sent = sentMap[cid] or 0
                    if sent == from and not big then
                        if blob ~= '' then enqueue(boxOf(src), src, blob, p) end
                        sentMap[cid] = to ~= 0 and to or nil
                        counts.entries = counts.entries + 1
                    elseif sent == PENDING or sent == to or (to ~= 0 and sent ~= 0 and newer(sent, to)) then
                        counts.skipped = counts.skipped + 1
                    else
                        if pack == nil then
                            pack, pv = Index.pack(e.bucket, grid, key, variant)
                            pv = math.tointeger(pv) or 0
                        end
                        Flush.queue(src, codec.sub(grid, key, variant, pv), 1)
                        sentMap[cid] = pv ~= 0 and pv or nil
                        if pv ~= 0 then Flush.queuePack(src, pack, ext, cid, big) end
                        if big then counts.bigEntries = counts.bigEntries + 1 else counts.resyncs = counts.resyncs + 1 end
                    end
                end
            end
        end
    end
end

--- The subscribers an event's position reaches: its near cell (radius ≤ FarRing: everyone whose focus is that
--- close has the cell in a ring), else its region (≤ FarRegions), else the bucket's global set (everyone).
local function eventSubs(ev, r)
    if ev.grid == G_GLOBAL or r > FAR_REGIONS then return Interest.subscribers(ev.bucket, G_GLOBAL, 0) end
    local grid, size = G_NEAR, CELL
    if r > FAR_RING then grid, size = G_FAR, REGION end
    local cx = math.floor(ev.x / size) + KEY_OFFSET
    local cy = math.floor(ev.y / size) + KEY_OFFSET
    if cx < 0 or cy < 0 or cx >= KEY_SPAN or cy >= KEY_SPAN then return nil end
    return Interest.subscribers(ev.bucket, grid, cx * KEY_SPAN + cy)
end

--- C4 events: subscribers whose focus is within the radius (a gated node's: its holders only), priority 4 with
--- the event's horizon as expiry; an event already older than its horizon is dropped.
local function processEvents(events, nowClock)
    local clock = Core.Clock
    for i = 1, #events do
        local ev = events[i]
        local horizon = tonumber(ev.horizonMs) or 2000
        local t = math.tointeger(ev.t) or nowClock
        local age = clock and clock.diff and clock.diff(nowClock, t) or (nowClock - t)
        if age > horizon then
            counts.expired = counts.expired + 1
        else
            local r = tonumber(ev.radius) or FAR_RING
            local node = ev.node
            local only = type(node) == 'table' and audienceOf(node) ~= nil and (Interest.holders(node.id) or EMPTY)
                or nil
            local subs = eventSubs(ev, r)
            if subs then
                local expires = (t + horizon) & 0xFFFFFFFF
                for src in pairs(subs) do
                    if not only or only[src] then
                        local fx, fy, fz = Interest.focusOf(src)
                        if fx then
                            local dx, dy, dz = fx - ev.x, fy - ev.y, fz - (ev.z or fz)
                            if dx * dx + dy * dy + dz * dz <= r * r then
                                Flush.queue(src, ev.blob, 4, expires)
                                counts.transient = counts.transient + 1
                            end
                        end
                    end
                end
            end
        end
    end
end

-- C2 dead reckoning: per node and class (near ring / far ring and regions) at most NearHz / FarHz; a capped op
-- waits (latest wins) and goes when its class's gap ran out.
local drLast = {}      -- [id] = { near = ms, far = ms }
local drPend = {}      -- [id] = { node, blob, near = bool, far = bool }

local function drSend(node, blob, far)
    local cell = node.cell
    if type(cell) ~= 'table' then return end
    local only = audienceOf(node) ~= nil and (Interest.holders(node.id) or EMPTY) or nil
    local subs = Interest.subscribers(node.bucket or 0, cell.grid, cell.key)
    if not subs then return end
    for src, ring in pairs(subs) do
        local isFar = cell.grid ~= G_NEAR or ring == 2
        if isFar == far and (not only or only[src]) and ringCovers(node, cell.grid, ring) then
            Flush.queue(src, blob, far and 3 or 2)
            counts.drSent = counts.drSent + 1
        end
    end
end

--- One class (near / far) of one DR op: sent when the class's gap ran out, else it waits (latest wins).
local function drClass(node, blob, now, far, last)
    local at = far and last.far or last.near
    if now - at >= (far and FAR_GAP_MS or NEAR_GAP_MS) then
        drSend(node, blob, far)
        if far then last.far = now else last.near = now end
        local pend = drPend[node.id]
        if pend then if far then pend.far = false else pend.near = false end end
        return
    end
    counts.drCapped = counts.drCapped + 1
    local pend = drPend[node.id]
    if not pend then
        pend = { node, blob, near = false, far = false }
        drPend[node.id] = pend
    end
    pend[1], pend[2] = node, blob
    if far then pend.far = true else pend.near = true end
end

local function drOffer(node, blob, now)
    local id = node.id
    local last = drLast[id]
    if not last then
        last = { near = -NEAR_GAP_MS - 1, far = -FAR_GAP_MS - 1 }
        drLast[id] = last
    end
    drClass(node, blob, now, false, last)
    drClass(node, blob, now, true, last)
    local pend = drPend[id]
    if pend and not pend.near and not pend.far then drPend[id] = nil end
end

local drPruneAt = 0

local function processDrs(drs, now)
    for i = 1, #drs do
        local d = drs[i]
        if type(d.node) == 'table' then drOffer(d.node, d.blob, now) end
    end
    for id, pend in pairs(drPend) do
        local last = drLast[id]
        if pend.near and now - last.near >= NEAR_GAP_MS then
            drSend(pend[1], pend[2], false)
            last.near, pend.near = now, false
        end
        if pend.far and now - last.far >= FAR_GAP_MS then
            drSend(pend[1], pend[2], true)
            last.far, pend.far = now, false
        end
        if not pend.near and not pend.far then drPend[id] = nil end
    end
    if now - drPruneAt >= 10000 then            -- forget the rate memory of nodes quiet for 10 s
        drPruneAt = now
        for id, last in pairs(drLast) do
            if not drPend[id] and now - last.near > 10000 and now - last.far > 10000 then drLast[id] = nil end
        end
    end
end

--- KINDS deltas, encoded once per (kinds version, client version).
local kindsBlobs, kindsAt = {}, -1
local function kindsBlob(since)
    local kinds = R.kinds
    local v = kinds.version()
    if v ~= kindsAt then
        for k in pairs(kindsBlobs) do kindsBlobs[k] = nil end
        kindsAt = v
    end
    local blob = kindsBlobs[since]
    if not blob then
        local ok, list = pcall(kinds.table, since)
        blob = ok and type(list) == 'table' and #list > 0 and Codec().kinds(list) or ''
        kindsBlobs[since] = blob
    end
    return blob
end

--- ONE reliable event: TriggerClientEventInternal with the payload msgpack-packed once (Core.Net.emitMany's
--- recipe); the plain TriggerClientEvent where the VM has no msgpack (the offline suites).
local function send(src, payload)
    if packArgs and TriggerClientEventInternal then
        local packed = packArgs(payload)
        TriggerClientEventInternal('core:scene:s', src, packed, #packed)
    else
        TriggerClientEvent('core:scene:s', src, payload)
    end
    counts.events, counts.bytesOut = counts.events + 1, counts.bytesOut + #payload
end

local parts = {}

--- `src`'s event of this tick: header, RESET first after a bucket reset, a KINDS delta when its table is older,
--- then the queues in order (control, PRIV, near, far, transient) up to MaxEventBytes (an item that alone
--- exceeds it goes alone); expired transient items are dropped.
local function sendReliable(src, box, header, nowClock, kindsNow)
    local n, size, taken = 1, #header, 0
    parts[1] = header
    if box.reset then
        box.reset = false
        local reset = Codec().reset(1)
        n, size = 2, size + #reset
        parts[2] = reset
    end
    local w = Interest.windowOf(src)
    if w and kindsNow > w.kindsV then
        local blob = kindsBlob(w.kindsV)
        if blob ~= '' then
            n, size = n + 1, size + #blob
            parts[n] = blob
            counts.kinds = counts.kinds + 1
        end
        w.kindsV = kindsNow
    end
    local full, exp = false, box.exp
    for p = 1, P_TRANSIENT do
        local q = box[p]
        local h, t = q.h, q.t
        if h > t then goto nextQueue end
        while h <= t do
            local blob = q[h]
            local len = #blob
            local e = p == P_TRANSIENT and exp[h] or nil
            if e and ((nowClock - e + 0x80000000) & 0xFFFFFFFF) - 0x80000000 > 0 then
                counts.expired = counts.expired + 1
            elseif size + len > MAX_EVENT and taken > 0 then
                full = true
                break
            else
                if size + len > MAX_EVENT then counts.oversized = counts.oversized + 1 end
                n, size, taken = n + 1, size + len, taken + 1
                parts[n] = blob
            end
            q[h] = nil
            if p == P_TRANSIENT then exp[h] = nil end
            box.bytes = box.bytes - len
            if p >= P_NEAR then box.pub = box.pub - len end
            h = h + 1
        end
        q.h = h
        if p ~= P_CONTROL and h > t then q.h, q.t = 1, 0 end
        if full then break end
        ::nextQueue::
    end
    if n > 1 then send(src, table.concat(parts, '', 1, n)) end
    for i = 1, n do parts[i] = nil end
end

local lastKinds = -1
local order, orderN, rotate = {}, 0, 0   -- this tick's dirty clients (reused)
local tickStart = 0
local function overFill() return microtime() - tickStart > FILL_BUDGET_US end

local function tick(now)
    woken = false
    tickStart = microtime()
    local nowClock = clockNow()
    local entries, gated, events, drs = Index.drain()
    processEntries(entries or EMPTY)
    if not Interest.fill(overFill) then woken = true end
    if gated and #gated > 0 then Interest.gated(gated) end
    processEvents(events or EMPTY, nowClock)
    processDrs(drs or EMPTY, now)
    local kindsNow = R.kinds.version()
    if kindsNow ~= lastKinds then      -- a define / undefine: every window gets its delta this tick
        lastKinds = kindsNow
        for src in Interest.each() do dirty[src] = true end
    end
    local header = Codec().header(nowClock)
    local n = 0
    for src in pairs(dirty) do            -- every client's event first (its SUBs leave before its packs)
        n = n + 1
        order[n] = src
        sendReliable(src, boxOf(src), header, nowClock, kindsNow)
    end
    for i = n + 1, orderN do order[i] = nil end
    orderN, tickPackBytes = n, 0
    rotate = rotate + 1
    for k = 0, n - 1 do                   -- then packs, from a rotating start (TICK_PACK_BYTES is shared)
        local src = order[(rotate + k) % n + 1]
        local box = boxes[src]
        sendPacks(src, box, header, now)
        if box.pub > MAX_BACKLOG then overflow(src, box) end
        if box.bytes == 0 and box.pk.h > box.pk.t then dirty[src] = nil end
    end
end

local durations, durN, durI = {}, 0, 0

local function record(us, now)
    durI = durI % RING + 1
    durations[durI] = us
    if durN < RING then durN = durN + 1 end
    counts.ticks = counts.ticks + 1
    if us > SLOW_TICK_MS * 1000 then
        counts.slowTicks = counts.slowTicks + 1
        if now - lastSlowLog >= LOG_EVERY_MS then
            lastSlowLog = now
            Log.warn('Scene: a flush tick took %.2f ms (entries %d, events %d, packs %d, withheld %d, overflows %d)',
                us / 1000, counts.entries, counts.events, counts.packs, counts.withheld, counts.overflows)
        end
    end
end

local rate = { at = {}, bytes = {}, i = 0, n = 0, last = -1000 }   -- one (ms, bytes out) sample per second, 10 kept

local function sample(now)
    if now - rate.last < 1000 then return end
    rate.last = now
    rate.i = rate.i % 10 + 1
    rate.at[rate.i], rate.bytes[rate.i] = now, counts.bytesOut + counts.latentBytes
    if rate.n < 10 then rate.n = rate.n + 1 end
end

--- Anything for a tick? A queued item or waiting pack, a capped DR op, a wake, or R.index.pending(). nil = the
--- index cannot tell (no `pending`): it is polled every 250 ms instead.
local function hasWork()
    if woken or next(dirty) ~= nil or next(drPend) ~= nil then return true end
    local pending = Index.pending
    if pending == nil then return nil end
    local ok, yes = pcall(pending)
    return ok and yes == true
end

--- The thread: waits a frame first (a wake from inside an index call never ticks re-entrantly), then one tick
--- per FlushMs while there is work; it ends at the first idle check — no polling and no natives while idle.
function runner.loop()
    Wait(0)
    while true do
        local work = hasWork()
        if work == false then break end
        local t0 = microtime()
        local now = GetGameTimer()
        local ok, err = pcall(tick, now)
        if not ok then Log.error('Scene: flush tick failed: %s', tostring(err)) end
        record(microtime() - t0, now)
        sample(now)
        Wait(work and FLUSH_MS or IDLE_MS)
    end
    runner.on = false
end

--- Counters since start, flush ms p50 / p99 over the last 256 ticks, clients with queued data and their bytes.
function Flush.stats()
    local out = {}
    for k, v in pairs(counts) do out[k] = v end
    local sorted = {}
    for i = 1, durN do sorted[i] = durations[i] end
    table.sort(sorted)
    out.flushMsP50 = durN > 0 and sorted[math.max(1, math.ceil(durN * 0.5))] / 1000 or 0
    out.flushMsP99 = durN > 0 and sorted[math.max(1, math.ceil(durN * 0.99))] / 1000 or 0
    out.clients, out.backlogBytes, out.packsWaiting = 0, 0, 0
    for _, box in pairs(boxes) do
        out.clients, out.backlogBytes = out.clients + 1, out.backlogBytes + box.bytes
        out.packsWaiting = out.packsWaiting + (box.pk.t - box.pk.h + 1)
    end
    out.drPending, out.running = 0, runner.on
    for _ in pairs(drPend) do out.drPending = out.drPending + 1 end
    local newest, oldest = rate.i, rate.n < 10 and 1 or rate.i % 10 + 1
    local span = rate.n > 1 and (rate.at[newest] - rate.at[oldest]) or 0
    out.bytesPerSecond = span > 0 and (rate.bytes[newest] - rate.bytes[oldest]) * 1000 / span or 0
    return out
end

--- One tick now (tests and the bench drive the flush directly); returns its duration in µs. Work it leaves
--- behind (capped DR ops, waiting packs) goes to the thread.
function Flush.tickNow()
    local t0 = microtime()
    local now = GetGameTimer()
    tick(now)
    local us = microtime() - t0
    record(us, now)
    if hasWork() ~= false then start() end
    return us
end
