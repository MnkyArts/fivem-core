--[[
    core/server/scene_gated.lua — the audience half of R.interest (DESIGN §55.6): gated nodes never enter cell blobs;
    every subscriber of a gated unit's cell whose audience admits it gets the unit in a PRIV section of its stream.
    Internal: attaches to Core.SceneRuntime.interest (R, block-listed in server/api.lua). Loads between
    server/scene_interest.lua and server/scene_flush.lua (asserts the first; the flush asserts this file).

      units      a gated unit is a HEAD (a gated root, or a child with its own audience under a public root — the
                 index decides) and its subtree; head.cell is its root's cell. Targets = subscribers of that cell
                 (a far-ring subscriber of a near cell only when the ROOT is M-tier) whose EFFECTIVE audience
                 (R.store.audienceOf: own + ancestors; head.audience when the store lacks it) admits them.
      audiences  players = { src… } | { [src] = true }, faction = id | { ids }, perm = 'x', editors = true,
                 near = r, fn = callable(src, nodeId), any = { … }, all = { … }; several keys in one table must all
                 hold; fail closed (unknown key, malformed value, nesting > 8). `near` = exact distance from the
                 server-known position (focus reports, backstop). `fn` MUST be synchronous: it runs in a runner
                 coroutine — a yield (a DB await, Wait) counts as NOT allowed and is logged once per owner (a yield
                 must never suspend the flush); over 0.2 ms is counted and logged once a minute.
      holders    per NODE: holders[id][src] = the head the node was published under; w.priv[head] = cid (granted
                 heads), w.psub[head] = { [id] = true } (every PUT id of what went out). A grant publishes every
                 PUT of R.index.gatedPut(head) (deps, head, subtree); a revoke DELs exactly what was published; a
                 drain DEL for a node reaches every src that holds it, whatever head it belongs to now (re-parent,
                 reveal, detach); a head that left the private channel has its leftovers DELed at the end of the
                 call. PRIV DELs carry the node's ver (the client applies a PRIV DEL whatever its ver).
      triggers   R.interest.gated(items) (the flush, once per tick), syncCell (a subscription changed), syncWindow
                 (hooks factionChanged / permsChanged / playerLoaded here — a global permsChanged is sliced over
                 ticks; staffModeChanged in scene_interest.lua; `near` heads of the window's cells on focus reports
                 and backstop visits: O(window), never the bucket); forgetHeld (a bucket reset: the client got RESET).
      PRIV       ops collect per src during one entry point with their OP counts and leave as PRIV(n) .. ops sections
                 (≤ MaxEventBytes, ≤ 65,535 ops; a big PUT-only blob is cut at op boundaries) through
                 R.flush.queuePriv: ordered, after control ops, never dropped by the backlog guard. Grants spend the
                 per-player pack budget (debt allowed: DELs are never held back).

    Interface on R.interest: allows(node, src), gatedTargets(node), gated(items, count?), syncCell(w, cid, ring),
    syncWindow(w, nearOnly?), holders(id), privFlush(), forgetGated(src), forgetHeld(w), gatedStats().

    Natives: GetGameTimer() -> long (CFX server: log stamps). Runtime helpers: Core.on (hooks), CreateThread, Wait.
]]

local R = Core.SceneRuntime
assert(type(R) == 'table' and type(R.interest) == 'table' and type(R.interest.windowOf) == 'function',
    'server/scene_interest.lua must load before server/scene_gated.lua')

local Interest, Index = R.interest, R.index
local Log = Core.Log

local GRID_SPAN <const> = 4294967296      -- cid = grid * GRID_SPAN + key
local G_NEAR <const> = 0
local PRIV_MAX_OPS <const> = 65535
local PUT_OP <const> = 0x10
local PUT_FIXED <const> = 38               -- a PUT's bytes before its extra: B I4 H I4 I4 B i4×3 i2×3 H + the s2 length
local FN_BUDGET_US <const> = 200           -- an audience `fn` over this is counted and logged (once a minute)
local LOG_EVERY_MS <const> = 60000
local REGATE_SLICE <const> = 50            -- windows re-gated per server frame after a global permsChanged
local MAX_EVENT <const> = (function()
    local s = type(Config) == 'table' and type(Config.Scene) == 'table' and Config.Scene or nil
    local v = s and tonumber(s.MaxEventBytes) or 16384
    if v ~= v then v = 16384 end
    return math.floor(math.min(1048576, math.max(1024, v)))
end)()
local SECTION_BYTES <const> = MAX_EVENT - 8

local microtime = (type(os) == 'table' and (os.microtime or (os.clock and function() return os.clock() * 1e6 end)))
    or function() return 0 end
local sunpack, byte = string.unpack, string.byte

local function Codec() return Core.SceneCodec end

--- Core.Clock.now() when the lib is there (u32 ms), else the game timer (motion-evaluated poses of `near`).
local function clockNow()
    local clock = Core.Clock
    local fn = clock and clock.now
    if fn then return fn() end
    return GetGameTimer() & 0xFFFFFFFF
end

local counts = { privPuts = 0, privDels = 0, privSets = 0, privOps = 0, fnSlow = 0, fnErrors = 0, fnYield = 0,
    regates = 0 }
local lastFnLog = -LOG_EVERY_MS
local yieldLogged = {}   -- [owner] = true: a yielding audience fn was logged once

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local factionCache = {} -- [src] = faction id | false
local gset, gsetN = {}, {}       -- [bucket] = { [cid] = { [headId] = head } } (gated heads per cell), cell count
local gnear, gnearN = {}, {}     -- the same for heads whose effective audience uses `near`
local gwhere, gbucket = {}, {}   -- [headId] = cid / bucket where gset holds the head
local holders = {}      -- [nodeId] = { [src] = headId }: every node published privately, by the head it went with
local privBuf = {}      -- [src] = { n, [1..n] = op blobs, k = { [1..n] = op counts } } — this entry point's PRIV ops
local privList, privN = {}, 0
local seen, stamp = {}, 0
local leftW, leftH, leftN = {}, {}, 0   -- (window, head) pairs whose head left the private channel this call

--------------------------------------------------------------------------------
-- PRIV sections: blobs with their op counts; sections cut by bytes and ops (RV1 F16)
--------------------------------------------------------------------------------

--- R.flush.queuePriv when the flush is loaded (it loads right after this file).
local function queuePriv(src, section)
    local flush = R.flush
    if not flush then return end
    if flush.queuePriv then flush.queuePriv(src, section) else flush.queue(src, section, 1) end
end

local function bufOf(src)
    local buf = privBuf[src]
    if not buf then
        buf = { n = 0, k = {} }
        privBuf[src] = buf
    end
    if buf.n == 0 then
        privN = privN + 1
        privList[privN] = src
    end
    return buf
end

local function bufPush(buf, blob, ops)
    local n = buf.n + 1
    buf[n], buf.k[n], buf.n = blob, ops, n
end

--- Buffers `ops` node ops (`blob`) for `src`'s next PRIV section(s). A blob too big for one section that holds
--- only PUT ops (a gatedPut of a big unit) is cut at op boundaries, so no section outgrows MaxEventBytes.
local function privAdd(src, blob, ops)
    if type(blob) ~= 'string' or blob == '' then return end
    ops = math.tointeger(ops) or 1
    local buf = bufOf(src)
    counts.privOps = counts.privOps + ops
    local len = #blob
    if len <= SECTION_BYTES or byte(blob, 1) ~= PUT_OP then
        bufPush(buf, blob, ops)
        return
    end
    local pos, from, k = 1, 1, 0
    while pos <= len do
        if byte(blob, pos) ~= PUT_OP or pos + PUT_FIXED - 1 > len then   -- not PUT-only: keep the rest whole
            bufPush(buf, from == 1 and blob or blob:sub(from), ops)
            return
        end
        local size = PUT_FIXED + sunpack('<I2', blob, pos + 36)
        if pos > from and pos + size - from > SECTION_BYTES then
            bufPush(buf, blob:sub(from, pos - 1), k)
            ops, from, k = ops - k, pos, 0
        end
        pos, k = pos + size, k + 1
    end
    if from <= len then bufPush(buf, blob:sub(from), k) end
end

--- Queues every buffered PRIV op as PRIV(n) .. ops sections of ≤ MaxEventBytes and ≤ 65,535 OPS each.
function Interest.privFlush()
    if privN == 0 then return end
    local codec = Codec()
    for i = 1, privN do
        local src = privList[i]
        privList[i] = nil
        local buf = privBuf[src]
        local n = buf and buf.n or 0
        local ks = buf and buf.k
        local first, bytes, ops = 1, 0, 0
        for j = 1, n do
            local len, k = #buf[j], ks[j]
            if j > first and (bytes + len > SECTION_BYTES or ops + k > PRIV_MAX_OPS) then
                queuePriv(src, codec.priv(ops) .. table.concat(buf, '', first, j - 1))
                first, bytes, ops = j, 0, 0
            end
            bytes, ops = bytes + len, ops + k
        end
        if n >= first and ops <= PRIV_MAX_OPS then
            queuePriv(src, codec.priv(ops) .. table.concat(buf, '', first, n))
        elseif n >= first then
            Log.error('Scene: a PRIV blob of %d ops for %s exceeds one section; dropped', ops, tostring(src))
        end
        for j = 1, n do buf[j], ks[j] = nil, nil end
        if buf then buf.n = 0 end
    end
    privN = 0
end

--------------------------------------------------------------------------------
-- Holders per node (RV1 F15)
--------------------------------------------------------------------------------

--- `w` now holds node `id` privately, published with head `headId` (moves it from another head's set).
local function publish(w, headId, id)
    local hs = holders[id]
    if not hs then
        hs = {}
        holders[id] = hs
    end
    local src = w.src
    local old = hs[src]
    if old == headId then return end
    local psub = w.psub
    if not psub then
        psub = {}
        w.psub = psub
    end
    if old then
        local s = psub[old]
        if s then s[id] = nil end
    end
    hs[src] = headId
    local s = psub[headId]
    if not s then
        s = {}
        psub[headId] = s
    end
    s[id] = true
end

--- Forgets that `w` holds `id` (no op goes out). @return the head it was held with, or nil
local function unpublish(w, id)
    local hs = holders[id]
    local src = w.src
    local head = hs and hs[src]
    if not head then return nil end
    hs[src] = nil
    if next(hs) == nil then holders[id] = nil end
    local s = w.psub and w.psub[head]
    if s then s[id] = nil end
    return head
end

--- Publishes the id of every PUT op at the start of `blob` (deps, a unit, its subtree) under `headId`; stops at
--- the first op that is not a PUT (a SET item: deps PUTs, then its one op).
local function scanPuts(blob, w, headId)
    local pos, len = 1, #blob
    while pos + PUT_FIXED - 1 <= len and byte(blob, pos) == PUT_OP do
        publish(w, headId, sunpack('<I4', blob, pos + 1))
        pos = pos + PUT_FIXED + sunpack('<I2', blob, pos + 36)
    end
end

--- A PRIV DEL of node `id` at its current ver (masked to the wire's u32; ver 0 when it no longer exists).
local function delOf(id)
    local store = R.store
    local node = store and store.get and store.get(id)
    local ver = node and math.tointeger(node.ver) or 0
    local codec = Codec()
    return codec.del(id, ver & 0xFFFFFFFF, codec.DEL.NORMAL)
end

--------------------------------------------------------------------------------
-- Audiences
--------------------------------------------------------------------------------

local function editorBucket(bucket)
    local runtime = Core.MapsRuntime
    local open = runtime and runtime.state and runtime.state.editorBuckets
    if type(open) == 'table' then
        for _, b in pairs(open) do
            if b == bucket then return true end
        end
    end
    return false
end

local function factionOf(src)
    local f = factionCache[src]
    if f == nil then
        f = false
        local player = Core.Player
        if player and player.getData then
            local ok, ref = pcall(player.getData, src, 'faction')
            if ok and type(ref) == 'table' and type(ref.id) == 'string' then f = ref.id end
        end
        factionCache[src] = f
    end
    return f
end

local function permHas(src, perm)
    local perms = Core.Perms
    if type(perm) ~= 'string' or not (perms and perms.has) then return false end
    local ok, allowed = pcall(perms.has, src, perm)
    return ok and allowed == true
end

local function isFinite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

--- The node's server pose now (motion evaluated by the store), else its base position.
local function nodePos(node)
    local store = R.store
    if store and store.pose then
        local ok, x, y, z = pcall(store.pose, node, clockNow())
        if ok and isFinite(x) and isFinite(y) and isFinite(z) then return x, y, z end
    end
    local p = node.pos
    if type(p) == 'table' or type(p) == 'vector3' then return p.x or p[1], p.y or p[2], p.z or p[3] end
    return nil
end

--- The effective audience: own + ancestors' (R.store.audienceOf, looked up at call time), else the node's own.
local function audienceOf(node)
    local store = R.store
    local fn = store and store.audienceOf
    if fn then
        local ok, aud = pcall(fn, node)
        if ok then return aud end
    end
    return node.audience
end

--- The tier of the node's root (children ride in their root's cell and its variants).
local function rootTier(node)
    local store = R.store
    local root = store and store.root and store.root(node) or node
    return (root or node).tier
end

-- An audience `fn` runs in a runner coroutine that is reused while calls return synchronously. A call that yields
-- (a DB await, Wait: in FiveM a cross-resource ref awaits inside its __call) parks the runner inside the plugin
-- and is answered NOT allowed; that runner is abandoned, never resumed by core again (RV1 F4).
local DONE <const> = {}
local fnRunner = nil

local function runnerBody(fn, src, id)
    repeat                          -- one call per resume; a resume without a function ends the runner
        local ok, res = pcall(fn, src, id)
        fn, src, id = coroutine.yield(DONE, ok, res)
    until fn == nil
end

local function callFn(fn, src, node)
    if not Core.Utils.isCallable(fn) then return false end
    local co = fnRunner
    if not co then
        co = coroutine.create(runnerBody)
        fnRunner = co
    end
    local t0 = microtime()
    local resumed, mark, ok, result = coroutine.resume(co, fn, src, node.id)
    local spent = microtime() - t0
    if not resumed or mark ~= DONE then
        fnRunner = nil
        if resumed then
            counts.fnYield = counts.fnYield + 1
            local owner = tostring(node.owner)
            if not yieldLogged[owner] then
                yieldLogged[owner] = true
                Log.warn('Scene: the audience fn of node %s (%s) yielded — audience fns must be synchronous; '
                    .. 'it counts as not allowed', tostring(node.id), owner)
            end
        else
            counts.fnErrors = counts.fnErrors + 1
        end
        return false
    end
    if spent > FN_BUDGET_US then counts.fnSlow = counts.fnSlow + 1 end
    if not ok then counts.fnErrors = counts.fnErrors + 1 end
    if not ok or spent > FN_BUDGET_US then
        local now = GetGameTimer()
        if now - lastFnLog >= LOG_EVERY_MS then
            lastFnLog = now
            Log.warn('Scene: the audience fn of node %s (%s) %s', tostring(node.id), tostring(node.owner),
                ok and ('took %.0f us (budget %d)'):format(spent, FN_BUDGET_US) or ('errored: ' .. tostring(result)))
        end
    end
    return ok and result and true or false
end

local function listHas(list, v)
    for i = 1, #list do
        if list[i] == v then return true end
    end
    return false
end

--- Fail closed: a table without one known key, a malformed value or a nesting deeper than 8 is `false`;
--- several keys in one table must all hold.
local function allowsAudience(aud, src, node, w, depth)
    if aud == nil then return true end
    if type(aud) ~= 'table' or depth > 8 then return false end
    local known, v = false, aud.players
    if v ~= nil then
        known = true
        if type(v) ~= 'table' or not (v[src] == true or listHas(v, src)) then return false end
    end
    v = aud.faction
    if v ~= nil then
        known = true
        local mine = factionOf(src)
        if not mine or (type(v) == 'table' and not listHas(v, mine)) or (type(v) ~= 'table' and v ~= mine) then
            return false
        end
    end
    v = aud.perm
    if v ~= nil then
        known = true
        if not permHas(src, v) then return false end
    end
    v = aud.editors
    if v ~= nil then
        known = true
        local bucket = w and w.bucket or node.bucket
        if v == true and not (Interest.modeBits(src) & 2 ~= 0 or editorBucket(bucket)) then return false end
    end
    v = aud.near
    if v ~= nil then
        known = true
        if not isFinite(v) or not w or not w.px then return false end
        local x, y, z = nodePos(node)
        if not x then return false end
        local dx, dy, dz = x - w.px, y - w.py, z - w.pz
        if dx * dx + dy * dy + dz * dz > v * v then return false end
    end
    v = aud.fn
    if v ~= nil then
        known = true
        if not callFn(v, src, node) then return false end
    end
    v = aud.any
    if v ~= nil then
        known = true
        if type(v) ~= 'table' then return false end
        local one = false
        for i = 1, #v do
            if allowsAudience(v[i], src, node, w, depth + 1) then
                one = true
                break
            end
        end
        if not one then return false end
    end
    v = aud.all
    if v ~= nil then
        known = true
        if type(v) ~= 'table' then return false end
        for i = 1, #v do
            if not allowsAudience(v[i], src, node, w, depth + 1) then return false end
        end
    end
    return known
end

--- Does the node's effective audience admit `src`? A node of another bucket never does.
function Interest.allows(node, src)
    if type(node) ~= 'table' then return false end
    local w = Interest.windowOf(src)
    if w and w.bucket ~= nil and node.bucket ~= nil and node.bucket ~= w.bucket then return false end
    return allowsAudience(audienceOf(node), src, node, w, 0)
end

--- A near-cell subscriber on the far ring holds the unit only when its ROOT is M-tier (the far variant's rule).
local function covers(grid, ring, head)
    return grid ~= G_NEAR or ring == 1 or rootTier(head) == 'M'
end

--------------------------------------------------------------------------------
-- The head index: gated heads per cell, and those whose audience uses `near` (RV1 F7)
--------------------------------------------------------------------------------

--- Does an audience (or a nested any / all) use `near`? Those heads are re-checked when a position changes.
local function usesNear(aud, depth)
    if type(aud) ~= 'table' or depth > 8 then return false end
    if aud.near ~= nil then return true end
    local list = aud.any
    for _ = 1, 2 do
        if type(list) == 'table' then
            for i = 1, #list do
                if usesNear(list[i], depth + 1) then return true end
            end
        end
        list = aud.all
    end
    return false
end

local function cellSetRemove(map, count, bucket, cid, id)
    local byCell = map[bucket]
    local heads = byCell and byCell[cid]
    if not heads or heads[id] == nil then return end
    heads[id] = nil
    if next(heads) == nil then
        byCell[cid] = nil
        count[bucket] = count[bucket] - 1
        if count[bucket] <= 0 then map[bucket], count[bucket] = nil, nil end
    end
end

local function cellSetAdd(map, count, bucket, cid, head)
    local byCell = map[bucket]
    if not byCell then
        byCell = {}
        map[bucket], count[bucket] = byCell, 0
    end
    local heads = byCell[cid]
    if not heads then
        heads = {}
        byCell[cid] = heads
        count[bucket] = count[bucket] + 1
    end
    heads[head.id] = head
end

local function unindexGated(id)
    local cid, bucket = gwhere[id], gbucket[id]
    if cid == nil then return end
    gwhere[id], gbucket[id] = nil, nil
    cellSetRemove(gset, gsetN, bucket, cid, id)
    cellSetRemove(gnear, gnearN, bucket, cid, id)
end

local function indexGated(head, bucket, cid)
    local id = head.id
    if gwhere[id] ~= cid or gbucket[id] ~= bucket then unindexGated(id) end
    cellSetAdd(gset, gsetN, bucket, cid, head)
    gwhere[id], gbucket[id] = cid, bucket
    if usesNear(audienceOf(head), 0) then
        cellSetAdd(gnear, gnearN, bucket, cid, head)
    else
        cellSetRemove(gnear, gnearN, bucket, cid, id)
    end
end

--------------------------------------------------------------------------------
-- Grants and revokes
--------------------------------------------------------------------------------

--- Gives `w` a whole unit: R.index.gatedPut(head) (deps, head, subtree), every PUT published under the head; the
--- bytes spend the pack budget (debt allowed). @return boolean sent
local function grant(w, head, cid)
    local ok, blob, n = pcall(Index.gatedPut, head)
    if not ok or type(blob) ~= 'string' or blob == '' then return false end
    local hid = head.id
    w.priv[hid] = cid
    publish(w, hid, hid)
    scanPuts(blob, w, hid)
    privAdd(w.src, blob, n)
    local flush = R.flush
    if flush and flush.spend then flush.spend(w.src, #blob, true) end
    counts.privPuts = counts.privPuts + 1
    return true
end

--- Takes a unit away from `w`: a PRIV DEL for every node published with it that `w` still holds with it.
local function revoke(w, hid)
    w.priv[hid] = nil
    local psub = w.psub
    local s = psub and psub[hid]
    if not s then return end
    psub[hid] = nil
    local src = w.src
    for id in pairs(s) do
        local hs = holders[id]
        if hs and hs[src] == hid then
            hs[src] = nil
            if next(hs) == nil then holders[id] = nil end
            privAdd(src, delOf(id), 1)
            counts.privDels = counts.privDels + 1
        end
    end
end

--- One (window, head): the unit when `w` should hold it and does not, its DELs the other way round.
local function syncHead(w, head, cid, ring)
    local hid = head.id
    local should = ring ~= nil and covers(cid // GRID_SPAN, ring, head) and Interest.allows(head, w.src)
    local has = w.priv[hid] ~= nil
    if should and not has then
        grant(w, head, cid)
    elseif has and not should then
        revoke(w, hid)
    elseif has then
        w.priv[hid] = cid
    end
end

--- The gated heads of one cell against a changed subscription of `w` (ring nil = the cell left the window).
function Interest.syncCell(w, cid, ring)
    local byCell = w.bucket ~= nil and gset[w.bucket]
    local heads = byCell and byCell[cid]
    if not heads then return end
    for _, head in pairs(heads) do syncHead(w, head, cid, ring) end
end

--- Heads of `map` (gset / gnear of the window's bucket) in `w`'s cells: walks whichever side is smaller.
local function syncCells(w, map, count)
    local bucket = w.bucket
    local byCell = bucket ~= nil and map[bucket]
    if not byCell then return end
    local cells = w.cells
    if (count[bucket] or 0) <= w.n then
        for cid, heads in pairs(byCell) do
            local ring = cells[cid]
            if ring then
                for _, head in pairs(heads) do syncHead(w, head, cid, ring) end
            end
        end
    else
        for cid, ring in pairs(cells) do
            local heads = byCell[cid]
            if heads then
                for _, head in pairs(heads) do syncHead(w, head, cid, ring) end
            end
        end
    end
end

--- Every gated head in `w`'s window, O(window) (hooks); `nearOnly`: only heads whose audience uses `near`
--- (a position changed) — the window's own cells, never every near head of the bucket (RV1 F7 / F22).
function Interest.syncWindow(w, nearOnly)
    if nearOnly then return syncCells(w, gnear, gnearN) end
    syncCells(w, gset, gsetN)
    local cells, bucket = w.cells, w.bucket
    for hid in pairs(w.priv) do            -- granted heads whose cell left the window or that left the index
        local cid = gwhere[hid]
        if gbucket[hid] ~= bucket or not cid or not cells[cid] then revoke(w, hid) end
    end
end

--- Forgets everything `w` holds privately WITHOUT sending (a bucket reset: the client got RESET and dropped it).
function Interest.forgetHeld(w)
    local src = w.src
    local psub = w.psub
    if psub then
        for _, s in pairs(psub) do
            for id in pairs(s) do
                local hs = holders[id]
                if hs and hs[src] then
                    hs[src] = nil
                    if next(hs) == nil then holders[id] = nil end
                end
            end
        end
        w.psub = {}
    end
    for hid in pairs(w.priv) do w.priv[hid] = nil end
    local buf = privBuf[src]
    if buf then
        for j = 1, buf.n do buf[j], buf.k[j] = nil, nil end
        buf.n = 0
    end
end

--------------------------------------------------------------------------------
-- The drain's gated items
--------------------------------------------------------------------------------

--- A node leaves the private channel ('del': removed, public now, re-parented under a public root, detached):
--- every src that holds it gets the item's DEL (the index's `how`) whatever head it came with; when it was a
--- head, what its holders still hold of the unit is DELed at the end of the call (children's own items first).
local function delItem(id, blob, ops)
    local hs = holders[id]
    if hs then
        holders[id] = nil
        for src, hid in pairs(hs) do
            local w = Interest.windowOf(src)
            if w then
                local s = w.psub and w.psub[hid]
                if s then s[id] = nil end
                if hid == id and w.priv[id] then
                    leftN = leftN + 1
                    leftW[leftN], leftH[leftN] = w, id
                end
                privAdd(src, blob ~= '' and blob or delOf(id), blob ~= '' and ops or 1)
                counts.privDels = counts.privDels + 1
            end
        end
    end
    if gwhere[id] then unindexGated(id) end
end

--- put / set about node `id` of unit `head`: allowed subscribers of the head's cell that hold the unit get the
--- ops (a PUT publishes the node, and its deps, with the head), the others get the whole unit; holders of the
--- unit that are no longer allowed or subscribed lose it; holders of `id` through another head that are no
--- target of this one lose `id` (it moved between units).
local function putItem(head, id, op, blob, ops)
    local cell = head.cell
    if type(cell) ~= 'table' then return end
    local hid = head.id
    local grid, bucket = cell.grid, head.bucket or 0
    local cid = grid * GRID_SPAN + cell.key
    indexGated(head, bucket, cid)
    stamp = stamp + 1
    local subs = Interest.subscribers(bucket, grid, cell.key)
    if subs then
        for src, ring in pairs(subs) do
            local w = Interest.windowOf(src)
            if w and covers(grid, ring, head) and Interest.allows(head, src) then
                seen[src] = stamp
                if w.priv[hid] then
                    w.priv[hid] = cid
                    privAdd(src, blob, ops)
                    if op == 'put' then scanPuts(blob, w, hid) end
                    counts.privSets = counts.privSets + 1
                else
                    grant(w, head, cid)
                end
            end
        end
    end
    local hs = holders[hid]
    if hs then
        for src, with in pairs(hs) do
            if with == hid and seen[src] ~= stamp then
                local w = Interest.windowOf(src)
                if w then revoke(w, hid) else hs[src] = nil end
            end
        end
    end
    if id ~= hid then
        hs = holders[id]
        if hs then
            for src, with in pairs(hs) do
                if with ~= hid and seen[src] ~= stamp then
                    local w = Interest.windowOf(src)
                    if w and unpublish(w, id) then
                        privAdd(src, delOf(id), 1)
                        counts.privDels = counts.privDels + 1
                    elseif not w then
                        hs[src] = nil
                    end
                end
            end
        end
    end
end

--- Heads that left the private channel in this call: what their former holders still hold of the unit (nodes
--- whose own DEL item did not come — deps, a child the index kept) is DELed now.
local function finishLeft()
    for i = 1, leftN do
        local w, hid = leftW[i], leftH[i]
        leftW[i], leftH[i] = nil, nil
        if w.priv[hid] then revoke(w, hid) end
    end
    leftN = 0
end

--- The drain's gated items { node (the unit head), id, op = 'put'|'set'|'del', blob, n (ops) } (§55.7 "then
--- gated-node ops"), once per tick from the flush.
function Interest.gated(items, count)
    local n = count or (type(items) == 'table' and #items or 0)
    for i = 1, n do
        local item = items[i]
        local head, op = item.node, item.op
        local hid = type(head) == 'table' and head.id
        if hid then
            local blob, ops = item.blob or '', math.tointeger(item.n) or 1
            if op == 'del' then
                delItem(item.id or hid, blob, ops)
            elseif blob ~= '' then
                putItem(head, item.id or hid, op, blob, ops)
            end
        end
    end
    finishLeft()
    Interest.privFlush()
end

--- Subscribers of the head's cell its effective audience admits (a fresh sorted array).
function Interest.gatedTargets(node)
    local out = {}
    local cell = type(node) == 'table' and node.cell
    if type(cell) ~= 'table' then return out end
    local subs = Interest.subscribers(node.bucket or 0, cell.grid, cell.key)
    if subs then
        for src, ring in pairs(subs) do
            if covers(cell.grid, ring, node) and Interest.allows(node, src) then out[#out + 1] = src end
        end
    end
    table.sort(out)
    return out
end

--- The live { [src] = headId } of the srcs that hold node `id` privately (events / DR of gated nodes go to them).
function Interest.holders(id) return holders[id] end

--- A dropped player: its private holdings, PRIV buffer, faction cache and per-src marks (RV1 F21).
function Interest.forgetGated(src)
    local w = Interest.windowOf(src)
    if w then Interest.forgetHeld(w) end
    factionCache[src], seen[src], privBuf[src] = nil, nil, nil
    for i = privN, 1, -1 do
        if privList[i] == src then
            table.remove(privList, i)
            privN = privN - 1
        end
    end
end

--------------------------------------------------------------------------------
-- Hooks (staffModeChanged lives in scene_interest.lua: it owns the Admin mode cache)
--------------------------------------------------------------------------------

local function regate(src)
    local w = src and Interest.windowOf(src)
    if not w then return end
    counts.regates = counts.regates + 1
    Interest.syncWindow(w)
    Interest.privFlush()          -- a queued PRIV op wakes the flush
end

-- A whole group changed (permsChanged nil): every window again, REGATE_SLICE per server frame (RV1 F22).
local regateQueue, regateHead, regateTail, regating = {}, 1, 0, false

local function regateLoop()
    while regateHead <= regateTail do
        for _ = 1, REGATE_SLICE do
            if regateHead > regateTail then break end
            local src = regateQueue[regateHead]
            regateQueue[regateHead], regateHead = nil, regateHead + 1
            regate(src)
        end
        Wait(0)   -- per-frame: a finite slice loop, REGATE_SLICE windows a frame until the queue is empty (RV1 F22)
    end
    regateHead, regateTail, regating = 1, 0, false
end

local function regateAll()
    for src in Interest.each() do
        regateTail = regateTail + 1
        regateQueue[regateTail] = src
    end
    if not regating and regateHead <= regateTail then
        regating = true
        CreateThread(regateLoop)
    end
end

Core.on('factionChanged', function(value, summary)
    local src = math.tointeger(tonumber(value))
    if not src then return end
    factionCache[src] = type(summary) == 'table' and type(summary.id) == 'string' and summary.id or false
    regate(src)
end)

Core.on('permsChanged', function(value)
    if value == nil then return regateAll() end
    regate(math.tointeger(tonumber(value)))
end)

Core.on('playerLoaded', function(value)
    local src = math.tointeger(tonumber(value))
    if src then
        factionCache[src] = nil
        regate(src)
    end
end)

--- The audience counters (R.interest.stats merges them).
function Interest.gatedStats()
    local out = {}
    for k, v in pairs(counts) do out[k] = v end
    local nodes, held = 0, 0
    for _, set in pairs(holders) do
        nodes = nodes + 1
        for _ in pairs(set) do held = held + 1 end
    end
    local marks = 0
    for _ in pairs(seen) do marks = marks + 1 end
    out.gatedHeldNodes, out.gatedHolders, out.regateQueued, out.seenSrcs = nodes, held, regateTail - regateHead + 1, marks
    return out
end
