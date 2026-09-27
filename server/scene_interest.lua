--[[
    core/server/scene_interest.lua — R.interest (DESIGN §55.6): focus, windows, rings, hysteresis, subscriptions.
    Internal: fills `Core.SceneRuntime.interest` (R, block-listed in server/api.lua). Cell ids: grid * 2^32 + key.

      focus     `core:scene:focus (x, y, z, vx, vy, vz, seq, held)` (Core.Net.on: schema, 250 ms, loaded) is
                CLAMPED to the nearest allowed point — the ped, the camera (GetPlayerFocusPos, only in the admin
                modes noclip / spectate / editor), a pin (Scene.setFocus), a prefetch target — when it lies farther
                than Slack + MaxSpeed × min(2 s, Δt) from all of them. The bucket is GetPlayerRoutingBucket(src).
      window    F and L = F + clamp(v × Lead.Seconds, Lead.Max): near cells ≤ NearRing of F → ring 1 (variant
                near), else ≤ FarRing of F or L → ring 2 (variant far); regions ≤ FarRegions of F or L; the global
                set always. Entering is instant; leaving needs LeaveMargin past the entry distance for LeaveDwellMs.
      changes   removed: UNSUB; added: SUB + nothing (the held version is current) | journal (R.index.since; it
                spends the per-player pack budget like a pack, and one over MaxEventBytes or the budget becomes the
                pack: RV1 F5) | pack (R.flush.queuePack, budgeted), filled by R.interest.fill right after the next
                drain (the index moves versions lazily; `sent` = PENDING until then; the fill budget is asked after
                every cell); a ring change: UNSUB + SUB of the other variant. `sent` per (src, cell) = what the
                client has or has in flight: a repeat resends nothing.
      bucket    any change (Player.setBucket, the raw native: onPlayerBucketChange, or a report / backstop visit
                that reads another bucket) resets the window: R.flush.reset purges everything queued for the old
                bucket (items and waiting packs) and puts RESET first in the next event — the client drops all it
                holds, LRU included — then the new window subscribes from scratch (no UNSUBs, no held hints; RV1
                F17 / F18). The gated holdings are forgotten without DELs (RESET dropped them).
      resync    `core:scene:resync`: a subscribed cell in its current variant only, at most once per cell per 2 s;
                the answer is the journal from the client's version when the budget allows, else the pack.
      backstop  every loaded player once per BackstopMs, sliced: PlayerGrid.positionOf + ≤ 2 natives; a focus
                outside every slack moves to the server position, a player without a window gets one. pin /
                prefetch refuse a src that is not connected (no window nothing would drop: RV1 F11).
      gated     the audience half of §55.6 (allows, gatedTargets, gated, syncCell, syncWindow, holders, PRIV
                sections) is defined on this table by server/scene_gated.lua, which loads next.

    Natives (fxref + natives_cfx.json 2026-09-26, all CFX apiset server): GetPlayerPed(playerSrc) -> Entity,
    GetEntityCoords(entity) -> vector3 (the server form, one argument), GetPlayerRoutingBucket(playerSrc) -> int,
    GetPlayerFocusPos(playerSrc) -> vector3, GetPlayerName(playerSrc) -> string (fxref 2026-09-27),
    GetGameTimer() -> long. Server event: onPlayerBucketChange
    (player, bucket, oldBucket). Runtime helpers: CreateThread, Wait, AddEventHandler.
]]

local R = Core.SceneRuntime
assert(type(R) == 'table' and type(R.kinds) == 'table' and type(R.index) == 'table',
    'server/scene_kinds.lua and server/scene_index.lua must load before server/scene_interest.lua')

local Interest = {}
R.interest = Interest

local Index = R.index
local Log = Core.Log

local KEY_OFFSET <const> = 32768          -- key = (cx + OFFSET) * SPAN + (cy + OFFSET), the §22.1 encoding
local KEY_SPAN <const> = 65536
local GRID_SPAN <const> = 4294967296      -- cid = grid * GRID_SPAN + key (key < 2^32)
local G_NEAR <const>, G_FAR <const>, G_GLOBAL <const> = 0, 1, 2
local V_NEAR <const>, V_FAR <const>, V_ONE <const> = 1, 2, 3
local MAX_HELD <const> = 48
local MAX_BUCKET <const> = 0x7FFFFFFF
local U32 <const> = 0xFFFFFFFF
local PREFETCH_MS <const> = 10000          -- a prefetch target stays an allowed focus point this long
local STEP_MS <const> = 250                -- backstop slice period
local IDLE_MS <const> = 1000               -- backstop with nobody loaded
local EMPTY <const> = {}
local PENDING <const> = -1                 -- w.sent value of a subscription whose content goes out at the next fill

--------------------------------------------------------------------------------
-- Config (Config.Scene; read ONCE — the key encoding depends on the sizes, the rest keeps this file cheap)
--------------------------------------------------------------------------------

local function cfgNum(tbl, key, default, lo, hi)
    local v = type(tbl) == 'table' and tonumber(tbl[key]) or nil
    if not v or v ~= v then return default end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local S = type(Config) == 'table' and type(Config.Scene) == 'table' and Config.Scene or EMPTY
local FOCUS = type(S.Focus) == 'table' and S.Focus or EMPTY
local LEAD = type(S.Lead) == 'table' and S.Lead or EMPTY

local CELL <const> = cfgNum(S, 'CellSize', 128, 16, 1024) + 0.0
local REGION <const> = cfgNum(S, 'RegionSize', 512, 64, 4096) + 0.0
local NEAR_RING <const> = cfgNum(S, 'NearRing', 160, 0, 4096) + 0.0
local FAR_RING <const> = math.max(NEAR_RING, cfgNum(S, 'FarRing', 448, 0, 8192) + 0.0)
local FAR_REGIONS <const> = cfgNum(S, 'FarRegions', 1024, 0, 16384) + 0.0
local MARGIN <const> = cfgNum(S, 'LeaveMargin', 64, 0, 1024) + 0.0
local DWELL <const> = math.floor(cfgNum(S, 'LeaveDwellMs', 3000, 0, 600000))
local SLACK <const> = cfgNum(FOCUS, 'Slack', 50, 0, 10000) + 0.0
local MAX_SPEED <const> = cfgNum(FOCUS, 'MaxSpeed', 90, 0, 10000) + 0.0
local COOLDOWN_MS <const> = math.floor(cfgNum(FOCUS, 'MinIntervalMs', 250, 0, 60000))
local BACKSTOP_MS <const> = math.floor(cfgNum(S, 'BackstopMs', 5000, 250, 600000))
local MAX_EVENT <const> = math.floor(cfgNum(S, 'MaxEventBytes', 16384, 1024, 1048576))
local LEAD_S <const> = cfgNum(LEAD, 'Seconds', 1.5, 0, 60) + 0.0
local LEAD_MAX <const> = cfgNum(LEAD, 'Max', 150, 0, 4096) + 0.0

local NEAR2 <const>, FAR2 <const>, REG2 <const> = NEAR_RING ^ 2, FAR_RING ^ 2, FAR_REGIONS ^ 2
local NEAR_OUT2 <const> = (NEAR_RING + MARGIN) ^ 2
local FAR_OUT2 <const> = (FAR_RING + MARGIN) ^ 2
local REG_OUT2 <const> = (FAR_REGIONS + MARGIN) ^ 2

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local windows = {}      -- [src] = w (see newWindow)
local subs = {}         -- [bucket] = { [cid] = { [src] = ring } }   (the live sets R.interest.subscribers returns)
local modeCache = {}    -- [src] = bits: 1 free camera (noclip / spectate / editor), 2 Admin mode editor
local changes = { n = 0 }   -- the reused change list of one evaluation: cid / old / new / d2 per slot
local fillList, fillN = {}, 0   -- windows with subscriptions waiting for their SUB + content (Interest.fill)
local counts = {
    reports = 0, clamped = 0, evaluations = 0, subs = 0, unsubs = 0, ringChanges = 0, packs = 0, journals = 0,
    heldHits = 0, empties = 0, backstops = 0, corrections = 0, created = 0, bucketChanges = 0, prefetches = 0,
    resyncs = 0, pins = 0,
}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local floor, sqrt = math.floor, math.sqrt

local function Codec() return Core.SceneCodec end
local function Flush() return R.flush end

local function isFinite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

local function isSrc(src)
    return math.type(src) == 'integer' and src > 0
end

--- Cell index of one axis value for a cell size, clamped into the key range.
local function axis(v, size)
    local c = floor(v / size)
    if c < -KEY_OFFSET then return -KEY_OFFSET end
    if c >= KEY_OFFSET then return KEY_OFFSET - 1 end
    return c
end

local function cidOf(grid, cx, cy)
    return grid * GRID_SPAN + (cx + KEY_OFFSET) * KEY_SPAN + (cy + KEY_OFFSET)
end

--- cid → grid, key
local function split(cid)
    local grid = cid // GRID_SPAN
    return grid, cid - grid * GRID_SPAN
end

--- The variant a ring of a grid subscribes to, and the outbox priority of its content.
local function variantOf(grid, ring)
    if grid ~= G_NEAR then return V_ONE end
    return ring == 1 and V_NEAR or V_FAR
end

local function prioOf(grid, ring)
    if grid == G_NEAR then return ring == 1 and 2 or 3 end
    return grid == G_GLOBAL and 2 or 3
end

--------------------------------------------------------------------------------
-- Windows and subscriber sets
--------------------------------------------------------------------------------

--- One record per player; tables inside are reused for the life of the session.
local function newWindow(src)
    return {
        src = src, bucket = nil, n = 0,
        cells = {},      -- [cid] = ring (1 near / 2 far; regions and the global set: 1)
        sent = {},       -- [cid] = version the client has or has in flight (absent = 0 / empty)
        past = {},       -- [cid] = ms the cell was first seen past its leave distance
        priv = {},       -- [id] = cid of the gated nodes this client holds
        held = {}, heldVar = {}, heldN = 0,   -- the last report's `held` ([cid] = version / variant, 0 = any)
        pend = { n = 0 }, filling = false,    -- cids waiting for Interest.fill, in evaluation order
        pendingAt = 0,   -- earliest due dwell drop (0 = none)
        fx = nil, fy = 0.0, fz = 0.0, lx = 0.0, ly = 0.0, vx = 0.0, vy = 0.0, vz = 0.0,
        at = nil, seq = 0,
        px = nil, py = 0.0, pz = 0.0,     -- server-known position (ped) at the last check
        pin = nil, pre = nil,             -- { x, y, z } trusted pin; { x, y, z, untilMs } prefetch target
        kindsV = 0,
        box = { false, 0, 0, 0, 0, 0, 0, 0, 0 }, nOut = 0,
    }
end

local function windowOf(src)
    local w = windows[src]
    if not w then
        w = newWindow(src)
        windows[src] = w
    end
    return w
end

local function link(bucket, cid, src, ring)
    local b = subs[bucket] or {}
    subs[bucket] = b
    local set = b[cid] or {}
    b[cid] = set
    set[src] = ring
end

local function unlink(bucket, cid, src)
    local b = subs[bucket]
    local set = b and b[cid]
    if not set then return end
    set[src] = nil
    if next(set) == nil then
        b[cid] = nil
        if next(b) == nil then subs[bucket] = nil end
    end
end

--- R.flush.queue when the flush module is loaded (it loads after this file).
local function queue(src, blob, prio)
    local flush = Flush()
    if flush and blob and blob ~= '' then flush.queue(src, blob, prio) end
end

--------------------------------------------------------------------------------
-- Admin modes, cached per src and refreshed by the staffModeChanged hook (the audience code reads them too)
--------------------------------------------------------------------------------

--- Admin modes as bits: 1 = a free camera (noclip / spectate / editor), 2 = editor. `modes` is a
--- { [name] = data } map (getModes / the staffModeChanged hook) or an array of names.
local function bitsOf(modes)
    if type(modes) ~= 'table' then return 0 end
    local bits = 0
    if modes.noclip ~= nil or modes.spectate ~= nil then bits = bits | 1 end
    if modes.editor ~= nil then bits = bits | 3 end
    for i = 1, #modes do
        local name = modes[i]
        if name == 'noclip' or name == 'spectate' then bits = bits | 1 elseif name == 'editor' then bits = bits | 3 end
    end
    return bits
end

local function modeBits(src)
    local bits = modeCache[src]
    if bits == nil then
        bits = 0
        local admin = Core.Admin
        if admin and admin.getModes then
            local ok, modes = pcall(admin.getModes, src)
            if ok then bits = bitsOf(modes) end
        end
        modeCache[src] = bits
    end
    return bits
end

--------------------------------------------------------------------------------
-- Window evaluation (§55.6): rings from F, the far ring and regions also from the lead point L, the global
-- set always; entering is instant, leaving needs the margin AND the dwell. Zero allocation after warm-up.
--------------------------------------------------------------------------------

local colF, colL, rowF, rowL = {}, {}, {}, {}   -- squared axis distances of the current box (reused)
local sorted = {}

local function change(cid, old, new, d2)
    local n = changes.n + 1
    changes.n = n
    local slot = changes[n]
    if not slot then
        slot = {}
        changes[n] = slot
    end
    slot[1], slot[2], slot[3], slot[4] = cid, old, new, d2
end

--- A subscribed cell whose wanted ring is worse than its current one: past the leave distance (entry distance
--- + margin) it starts its dwell; once the dwell ran out it drops one ring (a near cell still inside the far
--- ring's band becomes far) or out. dF / dL are squared distances.
local function leave(w, cid, cur, grid, dF, dL, now)
    local beyond
    if grid ~= G_NEAR then
        beyond = dF > REG_OUT2 and dL > REG_OUT2
    elseif cur == 1 then
        beyond = dF > NEAR_OUT2
    else
        beyond = dF > FAR_OUT2 and dL > FAR_OUT2
    end
    local past = w.past
    if not beyond then
        if past[cid] then past[cid] = nil end
        return
    end
    local since = past[cid]
    if not since then
        since = now
        past[cid] = now
    end
    local due = since + DWELL
    if now >= due then
        past[cid] = nil
        local to = 0
        if grid == G_NEAR and cur == 1 and (dF <= FAR_OUT2 or dL <= FAR_OUT2) then to = 2 end
        change(cid, cur, to, dF)
    elseif w.pendingAt == 0 or due < w.pendingAt then
        w.pendingAt = due
    end
end

--- One grid's box around F and L (half-size = outer ring + margin): every cell whose nearest point decides.
--- @return integer x0, integer x1, integer y0, integer y1 the box in cell coordinates
local function evalGrid(w, grid, now)
    local size = grid == G_NEAR and CELL or REGION
    local half = (grid == G_NEAR and FAR_RING or FAR_REGIONS) + MARGIN
    local fx, fy, lx, ly = w.fx, w.fy, w.lx, w.ly
    local x0, x1 = axis((fx < lx and fx or lx) - half, size), axis((fx > lx and fx or lx) + half, size)
    local y0, y1 = axis((fy < ly and fy or ly) - half, size), axis((fy > ly and fy or ly) + half, size)
    for i = 0, x1 - x0 do
        local a = (x0 + i) * size
        local b = a + size
        local d = fx < a and a - fx or (fx > b and fx - b or 0.0)
        colF[i] = d * d
        d = lx < a and a - lx or (lx > b and lx - b or 0.0)
        colL[i] = d * d
    end
    for j = 0, y1 - y0 do
        local a = (y0 + j) * size
        local b = a + size
        local d = fy < a and a - fy or (fy > b and fy - b or 0.0)
        rowF[j] = d * d
        d = ly < a and a - ly or (ly > b and ly - b or 0.0)
        rowL[j] = d * d
    end
    local cells, past = w.cells, w.past
    local near = grid == G_NEAR
    for i = 0, x1 - x0 do
        local base = grid * GRID_SPAN + (x0 + i + KEY_OFFSET) * KEY_SPAN + KEY_OFFSET + y0
        local cf, cl = colF[i], colL[i]
        for j = 0, y1 - y0 do
            local cid = base + j
            local dF, dL = cf + rowF[j], cl + rowL[j]
            local want
            if near then
                want = dF <= NEAR2 and 1 or ((dF <= FAR2 or dL <= FAR2) and 2 or 0)
            else
                want = (dF <= REG2 or dL <= REG2) and 1 or 0
            end
            local cur = cells[cid]
            if cur == nil then
                if want ~= 0 then change(cid, 0, want, dF) end
            elseif want ~= 0 and want <= cur then
                if want ~= cur then change(cid, cur, want, dF) end
                if past[cid] then past[cid] = nil end
            else
                leave(w, cid, cur, grid, dF, dL, now)
            end
        end
    end
    return x0, x1, y0, y1
end

--- Subscribed cells outside both boxes are beyond every leave distance: dwell, then out.
local function evalOutside(w, now, box)
    local out = 0
    for cid, cur in pairs(w.cells) do
        local grid = cid // GRID_SPAN
        if grid ~= G_GLOBAL then
            local key = cid - grid * GRID_SPAN
            local cx, cy = key // KEY_SPAN - KEY_OFFSET, key % KEY_SPAN - KEY_OFFSET
            local o = grid == G_NEAR and 1 or 5
            if cx < box[o + 1] or cx > box[o + 2] or cy < box[o + 3] or cy > box[o + 4] then
                out = out + 1
                leave(w, cid, cur, grid, math.huge, math.huge, now)
            end
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- Subscription changes: SUB/UNSUB (prio 1), then the content — nothing, a journal or a pack
--------------------------------------------------------------------------------

--- The gated nodes of one cell against a changed subscription (server/scene_gated.lua defines syncCell).
local function gate(w, cid, ring)
    local fn = Interest.syncCell
    if fn then fn(w, cid, ring) end
end

--- SUB + the content of a subscribed (cid, ring): nothing when the client holds the current version (its
--- last report's `held`, or what it had when the cell left its window), the journal from its held version
--- when the index still covers it, else the pack (budgeted, reliable or latent: R.flush.queuePack). Runs from
--- Interest.fill, right after the tick's drain: versions are clean there (R.index moves them lazily and since()
--- only covers drained entries).
local function fillCell(w, cid, ring)
    local codec, src, bucket = Codec(), w.src, w.bucket
    local grid, key = split(cid)
    local variant = variantOf(grid, ring)
    local v = Index.version(bucket, grid, key, variant) or 0
    local hv = w.held[cid]
    if hv then
        local hvar = w.heldVar[cid]
        if hvar ~= 0 and hvar ~= variant then hv = nil end
    end
    if v == 0 then
        queue(src, codec.sub(grid, key, variant, 0), 1)
        w.sent[cid] = nil
        counts.empties = counts.empties + 1
        return
    end
    if hv == v then
        queue(src, codec.sub(grid, key, variant, v), 1)
        w.sent[cid] = v
        counts.heldHits = counts.heldHits + 1
        return
    end
    local prio = prioOf(grid, ring)
    if hv and hv ~= 0 then
        -- the journal spends the pack budget like a pack (RV1 F5); one too big for an event, or over the budget,
        -- becomes the pack (latent, budgeted)
        local blob = Index.since(bucket, grid, key, variant, hv)
        local flush = Flush()
        if blob and blob ~= '' and #blob <= MAX_EVENT and (not flush or not flush.spend or flush.spend(src, #blob)) then
            queue(src, codec.sub(grid, key, variant, v), 1)
            queue(src, blob, prio)
            w.sent[cid] = v
            counts.journals = counts.journals + 1
            return
        end
    end
    local pack, pv = Index.pack(bucket, grid, key, variant)
    pv = math.tointeger(pv) or 0
    queue(src, codec.sub(grid, key, variant, pv), 1)
    if pv == 0 or type(pack) ~= 'string' or pack == '' then
        w.sent[cid] = nil
        counts.empties = counts.empties + 1
        return
    end
    w.sent[cid] = pv
    local flush = Flush()
    if flush then flush.queuePack(src, pack, prio, cid) end
    counts.packs = counts.packs + 1
end

--- Marks (w, cid) for its SUB + content at the next flush tick (`sent` = PENDING until then: the tick's
--- entries skip it, the fill sends the state that already includes them).
local function content(w, cid, ring)
    w.sent[cid] = PENDING
    local pend = w.pend
    local n = pend.n + 1
    pend.n, pend[n] = n, cid
    if not w.filling then
        w.filling = true
        fillN = fillN + 1
        fillList[fillN] = w
    end
end

--- server/scene_flush.lua, once per tick after the drain's entries: every pending subscription, in the order
--- the evaluation sorted them (nearest first — the pack budget goes there first). `over` (optional) is asked
--- after every cell (a first pack build of a dense cell costs ~1 ms: RV1 F12); when it answers true the rest
--- waits for the next tick (join storms: no long server frame).
--- @return boolean everything filled
--- Keeps fillList[from..fillN] (moved to the front) for the next tick.
local function keepFrom(from)
    local n = fillN - from + 1
    if n <= 0 then
        fillN = 0
        return
    end
    table.move(fillList, from, fillN, 1)
    for k = n + 1, fillN do fillList[k] = nil end
    fillN = n
end

function Interest.fill(over)
    local i = 1
    while i <= fillN do
        local w = fillList[i]
        local pend, live = w.pend, windows[w.src] == w
        local j, stop = pend.at or 1, false
        while j <= pend.n and not stop do
            local cid = pend[j]
            pend[j] = nil
            j = j + 1
            local ring = live and w.cells[cid]
            if ring and w.sent[cid] == PENDING then
                fillCell(w, cid, ring)
                stop = over ~= nil and over()
            end
        end
        if j <= pend.n then                 -- over the budget inside this window: it resumes here next tick
            pend.at = j
            keepFrom(i)
            return false
        end
        pend.n, pend.at, w.filling = 0, nil, false
        fillList[i] = nil
        i = i + 1
        if stop then
            keepFrom(i)
            return fillN == 0
        end
    end
    fillN = 0
    return true
end

--- Drops a pending (withheld) pack of the cell; true when one was dropped (the client never got it).
local function cancelPack(src, cid)
    local flush = Flush()
    return flush and flush.cancel and flush.cancel(src, cid) or false
end

local function addCell(w, cid, ring)
    w.cells[cid] = ring
    w.n = w.n + 1
    link(w.bucket, cid, w.src, ring)
    content(w, cid, ring)
    gate(w, cid, ring)
    counts.subs = counts.subs + 1
end

--- UNSUB: the client keeps the content in its LRU at the version it had, which becomes this window's `held`
--- hint for a later return (the next report replaces it with the client's own view).
local function removeCell(w, cid)
    local grid, key = split(cid)
    local ring, v = w.cells[cid], w.sent[cid]
    w.cells[cid], w.sent[cid], w.past[cid] = nil, nil, nil
    if w.rs then w.rs[cid] = nil end
    w.n = w.n - 1
    unlink(w.bucket, cid, w.src)
    queue(w.src, Codec().unsub(grid, key), 1)
    if not cancelPack(w.src, cid) and v and v ~= PENDING and w.heldN < MAX_HELD * 2 then
        if not w.held[cid] then w.heldN = w.heldN + 1 end
        w.held[cid], w.heldVar[cid] = v, variantOf(grid, ring)
    end
    gate(w, cid, nil)
    counts.unsubs = counts.unsubs + 1
end

--- A ring change of a near cell: UNSUB + SUB of the other variant (+ its journal or pack). The client keeps
--- one variant per cell, so whatever it held of the cell is no hint for the new variant.
local function ringCell(w, cid, new)
    local grid, key = split(cid)
    w.cells[cid], w.sent[cid] = new, nil
    link(w.bucket, cid, w.src, new)
    queue(w.src, Codec().unsub(grid, key), 1)
    cancelPack(w.src, cid)
    if w.held[cid] then
        w.held[cid], w.heldVar[cid] = nil, nil
        w.heldN = w.heldN - 1
    end
    content(w, cid, new)
    gate(w, cid, new)
    counts.ringChanges = counts.ringChanges + 1
end

local function byDistance(a, b) return a[4] < b[4] end

--- Removals first, then ring changes and additions nearest first (the camera is there: the pack budget and
--- the outbox order go to it first). Then the PRIV ops those changes caused.
local function apply(w)
    local n = changes.n
    local m = 0
    for i = 1, n do
        local slot = changes[i]
        if slot[3] == 0 then
            removeCell(w, slot[1])
        else
            m = m + 1
            sorted[m] = slot
        end
    end
    if m > 1 then table.sort(sorted, byDistance) end
    for i = 1, m do
        local slot = sorted[i]
        sorted[i] = nil
        if slot[2] == 0 then addCell(w, slot[1], slot[3]) else ringCell(w, slot[1], slot[3]) end
    end
    changes.n = 0
    local flushPriv = Interest.privFlush
    if flushPriv then flushPriv() end
    if n > 0 then
        local flush = Flush()
        if flush then flush.wake() end
    end
end

--- Recomputes `w`'s window around its focus and applies the difference.
local function evaluate(w, now)
    counts.evaluations = counts.evaluations + 1
    changes.n = 0
    w.pendingAt = 0
    local box = w.box
    local a, b, c, d = evalGrid(w, G_NEAR, now)
    local e, f, g, h = evalGrid(w, G_FAR, now)
    if not box[1] or w.nOut > 0 or box[2] ~= a or box[3] ~= b or box[4] ~= c or box[5] ~= d
        or box[6] ~= e or box[7] ~= f or box[8] ~= g or box[9] ~= h then
        box[1], box[2], box[3], box[4], box[5], box[6], box[7], box[8], box[9] = true, a, b, c, d, e, f, g, h
        w.nOut = evalOutside(w, now, box)
    end
    local global = G_GLOBAL * GRID_SPAN
    if not w.cells[global] then change(global, 0, 1, 0.0) end
    apply(w)
end

--------------------------------------------------------------------------------
-- Focus: validation (clamp), lead, bucket, the client events
--------------------------------------------------------------------------------

--- Stores the validated focus and the lead point L = F + clamp(v × Lead.Seconds, Lead.Max) (horizontal).
local function setFocus(w, x, y, z, vx, vy, vz)
    local sp2 = vx * vx + vy * vy + vz * vz
    if sp2 > MAX_SPEED * MAX_SPEED then
        local k = MAX_SPEED / sqrt(sp2)
        vx, vy, vz = vx * k, vy * k, vz * k
    end
    w.fx, w.fy, w.fz, w.vx, w.vy, w.vz = x, y, z, vx, vy, vz
    local lx, ly = vx * LEAD_S, vy * LEAD_S
    local len2 = lx * lx + ly * ly
    if len2 > LEAD_MAX * LEAD_MAX then
        local k = LEAD_MAX / sqrt(len2)
        lx, ly = lx * k, ly * k
    end
    w.lx, w.ly = x + lx, y + ly
end

local function nearer(best, bx, by, bz, x, y, z, ax, ay, az)
    if not ax then return best, bx, by, bz end
    local dx, dy, dz = x - ax, y - ay, z - az
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 < best then return d2, ax, ay, az end
    return best, bx, by, bz
end

--- The nearest allowed point to (x, y, z) and its squared distance: the ped (px, py, pz: nil without a ped),
--- the camera in a free-camera admin mode (one native), the pin, a live prefetch target. nil = none at all.
local function allowedPoint(w, x, y, z, px, py, pz, now)
    local best, bx, by, bz = math.huge, nil, nil, nil
    best, bx, by, bz = nearer(best, bx, by, bz, x, y, z, px, py, pz)
    if modeBits(w.src) & 1 ~= 0 then
        local q = GetPlayerFocusPos(w.src)
        if q then best, bx, by, bz = nearer(best, bx, by, bz, x, y, z, q.x, q.y, q.z) end
    end
    local pin = w.pin
    if pin then best, bx, by, bz = nearer(best, bx, by, bz, x, y, z, pin[1], pin[2], pin[3]) end
    local pre = w.pre
    if pre then
        if now > pre[4] then
            w.pre = nil
        else
            best, bx, by, bz = nearer(best, bx, by, bz, x, y, z, pre[1], pre[2], pre[3])
        end
    end
    return bx, by, bz, best
end

--- `held` of a report: { ['<grid>:<key>[:<variant>]'] = version } (or { [cid] = version }); false = malformed.
local function readHeld(w, held)
    local map, vars = w.held, w.heldVar
    for k in pairs(map) do map[k] = nil end
    for k in pairs(vars) do vars[k] = nil end
    w.heldN = 0
    if held == nil then return true end
    local n = 0
    for k, v in pairs(held) do
        if math.type(v) ~= 'integer' or v < 0 or v > U32 then return false end
        local grid, key, variant
        if math.type(k) == 'integer' then
            grid, key, variant = k // GRID_SPAN, k % GRID_SPAN, 0
        elseif type(k) == 'string' and #k <= 24 then
            local g, kk, vv = k:match('^(%d):(%d+):?(%d?)$')
            grid, key, variant = tonumber(g), math.tointeger(tonumber(kk)), tonumber(vv) or 0
        end
        if not grid or grid > G_GLOBAL or not key or key > U32 or variant > V_ONE then return false end
        local cid = grid * GRID_SPAN + key
        map[cid], vars[cid] = v, variant
        n = n + 1
    end
    w.heldN = n
    return true
end

--- A new bucket (a report, the backstop, onPlayerBucketChange — a Player.setBucket or the raw native): the client
--- gets RESET first in its next event (it drops everything, LRU included, and reports its focus) and its queued
--- old-bucket items and waiting packs go (R.flush.reset); `sent`, dwells, hints and private holdings are
--- forgotten; the caller evaluates the new window (RV1 F17 / F18). A first window only takes the bucket.
local function resetBucket(w, bucket)
    local old = w.bucket
    if old ~= nil then
        counts.bucketChanges = counts.bucketChanges + 1
        for cid in pairs(w.cells) do
            unlink(old, cid, w.src)
            w.cells[cid] = nil
        end
        local forget = Interest.forgetHeld
        if forget then forget(w) end
        local flush = Flush()
        if flush and flush.reset then flush.reset(w.src) end
        for _, t in ipairs({ w.sent, w.past, w.held, w.heldVar }) do
            for k in pairs(t) do t[k] = nil end
        end
        local pend = w.pend
        for i = 1, pend.n do pend[i] = nil end
        pend.n, pend.at = 0, nil
        w.heldN, w.n, w.nOut, w.pendingAt, w.box[1], w.rs = 0, 0, 0, 0, false, nil
    end
    w.bucket = bucket
end

--- Re-checks the `near` audiences of `w`'s gated nodes (the server-known position changed).
local function regateNear(w)
    local fn = Interest.syncWindow
    if fn then fn(w, true) end
end

local function wake()
    local flush = Flush()
    if flush then flush.wake() end
end

local FOCUS_SCHEMA <const> = { 'number', 'number', 'number', 'number', 'number', 'number',
    { 'integer', min = 0, max = U32 }, { 'table', max = MAX_HELD, optional = true } }

--- `core:scene:focus`: schema, cooldown and the loaded check ran in Core.Net.on. The focus is clamped to the
--- nearest allowed point when it lies outside every slack; the bucket is the server's.
local function onFocus(src, x, y, z, vx, vy, vz, seq, held)
    local w = windowOf(src)
    if not readHeld(w, held) then return end
    local now = GetGameTimer()
    local bucket = math.tointeger(GetPlayerRoutingBucket(src)) or 0
    local ped = GetPlayerPed(src)
    local px, py, pz
    if ped ~= 0 then
        local c = GetEntityCoords(ped)
        px, py, pz = c.x, c.y, c.z
        w.px, w.py, w.pz = px, py, pz
    end
    local bx, by, bz, d2 = allowedPoint(w, x, y, z, px, py, pz, now)
    if not bx then return end                     -- no ped, no pin, no prefetch: nothing to validate against
    counts.reports = counts.reports + 1
    local dt = w.at and (now - w.at) / 1000 or 2.0
    if dt > 2.0 then dt = 2.0 elseif dt < 0 then dt = 0.0 end
    local slack = SLACK + MAX_SPEED * dt
    if d2 > slack * slack then
        counts.clamped = counts.clamped + 1
        x, y, z, vx, vy, vz = bx, by, bz, 0.0, 0.0, 0.0
    end
    w.seq, w.at = seq, now
    setFocus(w, x, y, z, vx, vy, vz)
    if bucket ~= w.bucket then resetBucket(w, bucket) end
    evaluate(w, now)
    regateNear(w)
    wake()
end

local RESYNC_SCHEMA <const> = { { 'integer', min = 0, max = G_GLOBAL }, { 'integer', min = 0, max = U32 },
    { 'integer', min = V_NEAR, max = V_ONE }, { 'integer', min = 0, max = U32 } }
local RESYNC_CELL_MS <const> = 2000   -- answers per cell (the client asks at most once per cell per 2 s; RV1 F5)

--- `core:scene:resync (grid, key, variant, v)`: only a subscribed cell in its current variant, once per 2 s per
--- cell (the Net.on cooldown keeps the whole event ≤ 16/s), every answer budgeted (journal or pack). Nothing when `v` is the current version; else
--- SUB + the journal from `v` when covered, else the pack (budgeted like every pack) — or SUB(…, 0) when the cell
--- is empty (a pending client cell asking with v = 0 learns that it stays empty). Filled after the next drain.
local function onResync(src, grid, key, variant, v)
    local w = windows[src]
    if not w or w.bucket == nil then return end
    local cid = grid * GRID_SPAN + key
    local ring = w.cells[cid]
    if not ring or variantOf(grid, ring) ~= variant then return end
    local now = GetGameTimer()
    local rs = w.rs
    if not rs then
        rs = {}
        w.rs = rs
    end
    local last = rs[cid]
    if last and now - last < RESYNC_CELL_MS then return end
    rs[cid] = now
    counts.resyncs = counts.resyncs + 1
    local cur = Index.version(w.bucket, grid, key, variant) or 0
    if cur == v and v ~= 0 then                  -- a live cell that is current: nothing to send
        w.sent[cid] = v
        return
    end
    -- the client's version is the hint: none (0) gets SUB(…, 0) for an empty cell, else the pack; v the journal
    if v ~= 0 then
        if not w.held[cid] then w.heldN = w.heldN + 1 end
        w.held[cid], w.heldVar[cid] = v, variant
    elseif w.held[cid] then
        w.held[cid], w.heldVar[cid] = nil, nil
        w.heldN = w.heldN - 1
    end
    content(w, cid, ring)
    wake()
end

Core.Net.on('core:scene:focus', FOCUS_SCHEMA, onFocus, { cooldown = COOLDOWN_MS })
Core.Net.on('core:scene:resync', RESYNC_SCHEMA, onResync, { cooldown = 62 })

--------------------------------------------------------------------------------
-- Backstop (§55.6): every loaded player once per BackstopMs, sliced; ≤ 2 natives each
--------------------------------------------------------------------------------

local order, orderN, cursor, orderDirty = {}, 0, 0, true

--- One player: the server position from the player grid (no native), the bucket (one native), the camera in a
--- free-camera mode (one native). A focus outside every slack is replaced by the server position (lost or
--- lying reports); a player without a window gets one; due dwell drops are applied; `near` audiences re-run.
local function backstop(src, now)
    local grid = Core.PlayerGrid
    local x, y, z, at
    if grid and grid.positionOf then x, y, z, at = grid.positionOf(src) end
    if not x then return end
    counts.backstops = counts.backstops + 1
    local w = windowOf(src)
    w.px, w.py, w.pz = x, y, z
    local bucket = math.tointeger(GetPlayerRoutingBucket(src)) or 0
    local moved = false
    if bucket ~= w.bucket then
        resetBucket(w, bucket)
        moved = true
    end
    local ok = false
    if w.fx then
        local dt = (now - math.min(w.at or now, at or now)) / 1000
        local slack = SLACK + MAX_SPEED * (dt > 2.0 and 2.0 or (dt < 0 and 0.0 or dt))
        local _, _, _, d2 = allowedPoint(w, w.fx, w.fy, w.fz, x, y, z, now)
        ok = d2 <= slack * slack
    end
    if not ok then
        if w.fx then counts.corrections = counts.corrections + 1 else counts.created = counts.created + 1 end
        setFocus(w, x, y, z, 0.0, 0.0, 0.0)
        w.at = now
        moved = true
    end
    if moved or (w.pendingAt ~= 0 and now >= w.pendingAt) then evaluate(w, now) end
    regateNear(w)
end

local function rebuildOrder()
    local player = Core.Player
    local list = player and player.getPlayers and player.getPlayers() or EMPTY
    local n = #list
    for i = 1, n do order[i] = list[i] end
    for i = n + 1, orderN do order[i] = nil end
    orderN, orderDirty = n, false
    if cursor > n then cursor = 0 end
end

CreateThread(function()
    while true do
        if orderDirty then rebuildOrder() end
        if orderN == 0 then
            Wait(IDLE_MS)
        else
            local now = GetGameTimer()
            for _ = 1, math.ceil(orderN * STEP_MS / BACKSTOP_MS) do
                cursor = cursor + 1
                if cursor > orderN then cursor = 1 end
                local src = order[cursor]
                if src then
                    local ok, err = pcall(backstop, src, now)
                    if not ok then Log.error('Scene: backstop of %s failed: %s', tostring(src), tostring(err)) end
                end
            end
            local flushPriv = Interest.privFlush
            if flushPriv then flushPriv() end    -- a queued PRIV op / window change wakes the flush itself
            Wait(STEP_MS)
        end
    end
end)

--------------------------------------------------------------------------------
-- Server-side focus control: prefetch (teleports) and pins (Scene.setFocus)
--------------------------------------------------------------------------------

--- Moves `w`'s window to a trusted point at once (bucket read from the server).
local function jump(w, x, y, z, now)
    local bucket = math.tointeger(GetPlayerRoutingBucket(w.src)) or 0
    setFocus(w, x, y, z, 0.0, 0.0, 0.0)
    w.at = now
    if bucket ~= w.bucket then resetBucket(w, bucket) end
    evaluate(w, now)
    wake()
end

--- A loaded session (Core.Player.isLoaded): pins and prefetches of anybody else would create a window nothing drops.
--- A connected player (the server knows its name): a window for anyone else would never be dropped — the
--- engine's playerDropped, which drops windows, only comes for connected players (RV1 F11).
local function connected(src)
    local name = GetPlayerName(src)
    return name ~= nil and name ~= ''
end

--- Subscribes the window around a teleport destination before the player gets there (Player.setCoords); the
--- target stays an allowed focus point for PREFETCH_MS so the client's first reports there are not clamped.
--- Refused for a src that is not connected (RV1 F11).
function Interest.prefetch(src, x, y, z)
    if not isSrc(src) or not isFinite(x) or not isFinite(y) or not isFinite(z or 0.0) then return false end
    if not connected(src) then return false end
    local w = windowOf(src)
    local now = GetGameTimer()
    local pre = w.pre or {}
    pre[1], pre[2], pre[3], pre[4] = x + 0.0, y + 0.0, (z or 0.0) + 0.0, now + PREFETCH_MS
    w.pre = pre
    counts.prefetches = counts.prefetches + 1
    jump(w, pre[1], pre[2], pre[3], now)
    return true
end

--- A trusted focus (Scene.setFocus): an allowed point for validation, and the window moves there now.
--- pin(src, nil) clears it; the backstop / next report bring the window back to the player.
function Interest.pin(src, x, y, z)
    if not isSrc(src) then return false end
    if x == nil then
        local w = windows[src]
        if w and w.pin then
            w.pin = nil
            counts.pins = counts.pins + 1
            if w.px then backstop(src, GetGameTimer()) end
        end
        return true
    end
    if not isFinite(x) or not isFinite(y) or not isFinite(z or 0.0) then return false end
    if not connected(src) then return false end        -- nobody behind the src: no window (RV1 F11)
    local w = windowOf(src)
    local pin = w.pin or {}
    pin[1], pin[2], pin[3] = x + 0.0, y + 0.0, (z or 0.0) + 0.0
    w.pin = pin
    counts.pins = counts.pins + 1
    jump(w, pin[1], pin[2], pin[3], GetGameTimer())
    return true
end

--------------------------------------------------------------------------------
-- Lifecycle and hooks
--------------------------------------------------------------------------------

function Interest.drop(src)
    modeCache[src] = nil
    local forget = Interest.forgetGated
    if forget then forget(src) end
    local flush = Flush()
    if flush and flush.drop then flush.drop(src) end
    local w = windows[src]
    if not w then return false end
    for cid in pairs(w.cells) do unlink(w.bucket, cid, src) end
    windows[src] = nil
    orderDirty = true
    return true
end

AddEventHandler('playerDropped', function()
    local src = source
    Interest.drop(tonumber(src) or src)
end)

-- the engine's server event (a local event: clients cannot raise it): the new bucket applies at once
AddEventHandler('onPlayerBucketChange', function(player, bucket)
    local src = math.tointeger(tonumber(player))
    local w = src and windows[src]
    bucket = math.tointeger(tonumber(bucket))
    if w and w.fx and bucket and bucket ~= w.bucket and bucket >= 0 and bucket <= MAX_BUCKET then
        local now = GetGameTimer()
        resetBucket(w, bucket)
        evaluate(w, now)
        wake()
    end
end)

Core.on('playerLoaded', function() orderDirty = true end)

Core.on('staffModeChanged', function(value, modes)
    local src = math.tointeger(tonumber(value))
    if not src then return end
    modeCache[src] = bitsOf(modes)
    local w = windows[src]
    local fn = Interest.syncWindow
    if w and fn then
        fn(w)
        local flushPriv = Interest.privFlush
        if flushPriv then flushPriv() end
        wake()
    end
end)

--------------------------------------------------------------------------------
-- Interface (INTERFACES §4) and the hand-offs to server/scene_gated.lua and server/scene_flush.lua
--------------------------------------------------------------------------------

--- The live { [src] = ring } of (bucket, grid, key), nil when nobody subscribes. Callers never mutate it.
function Interest.subscribers(bucket, grid, key)
    local b = subs[bucket]
    return b and b[grid * GRID_SPAN + key]
end

--- The version `src` has (or has in flight) of a subscribed cell in that variant: 0 = empty, nil = not subscribed.
function Interest.sent(src, grid, key, variant)
    local w = windows[src]
    local cid = grid * GRID_SPAN + key
    local ring = w and w.cells[cid]
    if not ring or (variant ~= nil and variantOf(grid, ring) ~= variant) then return nil end
    return w.sent[cid] or 0
end

function Interest.setSent(src, grid, key, variant, v)
    local w = windows[src]
    local cid = grid * GRID_SPAN + key
    local ring = w and w.cells[cid]
    if not ring or (variant ~= nil and variantOf(grid, ring) ~= variant) then return false end
    w.sent[cid] = (math.tointeger(v) or 0) ~= 0 and v or nil
    return true
end

function Interest.kindsVersion(src)
    local w = windows[src]
    return w and w.kindsV or 0
end

function Interest.setKindsVersion(src, v)
    local w = windows[src]
    if w then w.kindsV = math.tointeger(v) or 0 end
end

function Interest.bucketOf(src)
    local w = windows[src]
    return w and w.bucket
end

function Interest.focusOf(src)
    local w = windows[src]
    if not w or not w.fx then return nil end
    return w.fx, w.fy, w.fz
end

--- The live window record (server/scene_gated.lua, server/scene_flush.lua) and the iterator over all of them.
function Interest.windowOf(src) return windows[src] end
function Interest.each() return next, windows, nil end
Interest.modeBits = modeBits

--- Debug copy: bucket, focus, lead, the cells as { ['<grid>:<key>'] = ring }, their sent versions and dwell starts.
function Interest.window(src)
    local w = windows[src]
    if not w then return nil end
    local cells, sent, past = {}, {}, {}
    for cid, ring in pairs(w.cells) do
        local grid, key = split(cid)
        local name = ('%d:%d'):format(grid, key)
        cells[name], sent[name], past[name] = ring, w.sent[cid] or 0, w.past[cid]
    end
    return { bucket = w.bucket, n = w.n, focus = w.fx and { x = w.fx, y = w.fy, z = w.fz } or nil,
        lead = w.fx and { x = w.lx, y = w.ly } or nil, cells = cells, sent = sent, past = past,
        pendingAt = w.pendingAt, pinned = w.pin ~= nil, kindsV = w.kindsV, seq = w.seq }
end

function Interest.stats()
    local out = { windows = 0, subscriptions = 0, cells = 0 }
    for _, w in pairs(windows) do
        out.windows = out.windows + 1
        out.subscriptions = out.subscriptions + w.n
    end
    for _, b in pairs(subs) do
        for _ in pairs(b) do out.cells = out.cells + 1 end
    end
    for k, v in pairs(counts) do out[k] = v end
    local gated = Interest.gatedStats
    if gated then
        for k, v in pairs(gated()) do out[k] = v end
    end
    out.subscribers, out.cellSize, out.regionSize = out.windows, CELL, REGION
    return out
end

-- the index's key maths must be ours (both follow §55.5); a mismatch would subscribe the wrong cells
do
    local ok, key = pcall(Index.keyOf, G_NEAR, 1000.5, -2000.5)
    if ok and key ~= nil and key ~= cidOf(G_NEAR, axis(1000.5, CELL), axis(-2000.5, CELL)) then
        Log.error('Scene: R.index.keyOf disagrees with the interest key maths (cell size?)')
    end
end
