--[[
    core/server/scene_index.lua — R.index (DESIGN §55.5): cells, tiers, versions, journals, packs, the movers re-cell.

    Grids: 0 = near cells of Config.Scene.CellSize (128 m), 1 = far regions of RegionSize (512 m), both keyed
    `(floor(x / size) + 32768) * 65536 + (floor(y / size) + 32768)` (sizes read ONCE); 2 = the bucket's global set
    (key 0). S/M roots live in the near cell of their position, L roots in the far region, G roots in the global set.
    Children never have an entry: they ride in their ROOT's cell, and every op of a child follows the root's. The
    tree is kept as direct-children sets (rec.dk, rec.nk): every tree operation is one parent-first walk, O(subtree).
    Dependency nodes (kind.dependency, INTERFACES §7) have no entry either: their PUT goes right before the first
    dependent of every entry/pack, their SET/DEL into every variant that holds a dependent.

    Variants: a near cell has NEAR (every public node, every field) and FAR (M roots only, without kind.nearFields,
    FAR flag); regions and the global set have ONE. Each has its own version from ONE module-wide counter (0 = empty,
    wrapping past 2^32 - 1 to 1; the index only ever compares versions for equality). Versions move lazily: the first
    change after the content was observed (a drained entry, a pack, version()) takes a fresh number, later changes of
    the tick reuse it, so one number names one content (the §52 rule) — except the C2 DR pose (pack dropped only).

    Gating (RV1 F1): a node whose EFFECTIVE audience (its own + its ancestors') is set never enters a public blob.
    A child with its own audience is a GATE HEAD: a gated unit of its own with its subtree (registered in its root's
    cell: gatedIn, node.cell), whatever its root is. Gated ops come out of drain() as items addressed to the unit head.

    Per tick (drain): ops are coalesced per node — PUT absorbs every later op, SET merges (names only: values are read
    at drain), MOVE/MOTION/PROMOTE/DEMOTE keep the last, DEL wins, a node created and removed in one tick sends nothing,
    two or more kinds of change collapse into one PUT (one op per node per entry). A root that changes cell emits
    DEL(HANDOVER) in the old cell and PUT in the new one in the same tick (children follow).
    Each drained entry `{ bucket, grid, key, variant, from, to, blob, n, at, big? }` (blob = CELL .. ops; big = larger
    than MaxEventBytes: the flush sends the pack latent instead, RV1 F9) is also kept in the variant's journal
    (≤ JournalOps entries, ≤ JournalMs); consecutive entries chain, so since(v) is a concatenation. A variant nobody
    subscribes to (R.interest.subscribers) skips the encode and clears its journal (since() → nil → the pack serves).

    Movers (roots with motion or an attachment) are re-celled at Motion.ServerHz (2 Hz) by one thread that exists
    only while movers exist, and only when ≥ Motion.RecellTolerance (8 m) past the border. A plan whose bounding box
    stays inside its cell ± tolerance (spin, osc, orbit, bounded paths / keys / tweens) is PARKED instead (RV1 F19):
    never posed, only woken from a heap at its finish or rebase time. A finished plan goes to R.store.settle (a 'dr'
    plan only after 6 heartbeats without a sample); a plan near the end of Clock.diff's window is rebased
    (Motion.needsRebase / rebase, a 'motion' change); a driven (C2) root is re-celled by each dr() sample. Roots
    attached to a PLAYER ride in one group per player instead (RV4 F7): one PlayerGrid.positionOf read per player per
    sweep, nothing more while the player stays inside the box where none of them could be re-celled. A promoted root
    follows its clone through R.store.follow ('follow': a 'move' with the movers' tolerance).

    True idle: the first thing a tick queues calls R.flush.wake() once (reset by drain); pending() says whether a
    drain has work. Node vers travel masked to u32 (RV1 F6). Every encode is pcall'ed: a node that fails is logged
    once and skipped. Each node caches its PUT ops (node.opN / node.opF, keyed by the flags byte) until it changes.
    INTERNAL: R = Core.SceneRuntime (created by server/scene_kinds.lua, block-listed in server/api.lua); R.store,
    R.interest and R.flush are looked up at CALL time.

    Natives (fxref 2026-09-26, all client+server; the server forms): GetGameTimer() -> integer,
    NetworkGetEntityFromNetworkId(netId) -> entity (0 when unknown), DoesEntityExist(entity) -> BOOL,
    GetEntityCoords(entity) -> vector3. Runtime helpers: CreateThread, Wait.
]]

local R = Core.SceneRuntime
assert(type(R) == 'table' and type(R.kinds) == 'table',
    'server/scene_index.lua must load right after server/scene_kinds.lua (Core.SceneRuntime.kinds missing)')
local Codec = Core.SceneCodec
assert(type(Codec) == 'table' and type(Codec.put) == 'function',
    'server/scene_index.lua needs shared/scene_codec.lua (Core.SceneCodec missing)')

local Index = {}
R.index = Index

local floor, ceil, max, min, abs, mathType = math.floor, math.ceil, math.max, math.min, math.abs, math.type
local toint, concat, tremove = math.tointeger, table.concat, table.remove

local KEY_OFFSET <const> = 32768
local KEY_SPAN <const> = 65536
local GRID_SPAN <const> = 4294967296       -- cells[bucket][grid * GRID_SPAN + key]
local MAX_OPS <const> = 65535               -- a CELL section counts its ops in a u16
local MAX_DEPTH <const> = 8                 -- parent hops walked (the store allows 4)
local NEAR <const>, FAR <const>, ONE <const> = 1, 2, 3
local DEL_NORMAL <const>, DEL_HANDOVER <const>, DEL_FADE <const> = 0, 1, 2
local F_MOTION <const>, F_PROMOTED <const>, F_PLACEHOLDER <const>, F_FAR <const> = 1, 2, 4, 8
local F_INTERACT <const>, F_GATED <const>, F_CHILDREN <const> = 16, 32, 64
local GRID_OF <const> = { S = 0, M = 0, L = 1, G = 2 }
local HOW_OF <const> = { normal = DEL_NORMAL, handover = DEL_HANDOVER, fade = DEL_FADE }
local SET_KEYS <const> = { f = true, x = true, i = true, a = true, d = true }
local MOVERS_PER_SLICE <const> = 250        -- more movers than this: the period is cut into slices
local MAX_SLICES <const> = 10
local REBASE_MS <const> = 1073741824        -- Motion.needsRebase: |Clock.diff(t, t0)| > 2^30 ms
local PARK_MIN_MS <const> = 250             -- a parked plan is looked at again no sooner than this
local PARK_BUDGET <const> = 256             -- parked plans handled per wake of the thread
local EMPTY <const> = setmetatable({}, { __newindex = function() error('read-only', 2) end })

local function sceneCfg()
    local s = type(Config) == 'table' and Config.Scene or nil
    return type(s) == 'table' and s or EMPTY
end

local function num(v, default, lo, hi)
    v = tonumber(v)
    if not v or v ~= v then return default end
    if lo and v < lo then return lo end
    if hi and v > hi then return hi end
    return v
end

--- Cell and region sizes, resolved ONCE: every key a client computed depends on them.
local CELL_SIZE <const> = num(sceneCfg().CellSize, 128, 16, 4096) + 0.0
local REGION_SIZE <const> = num(sceneCfg().RegionSize, 512, 64, 8192) + 0.0

local function journalOps() return floor(num(sceneCfg().JournalOps, 64, 0, 100000)) end
local function journalMs() return num(sceneCfg().JournalMs, 10000, 0, 3600000) end
local function motionCfg()
    local m = sceneCfg().Motion
    return type(m) == 'table' and m or EMPTY
end

local function isFinite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

--- x, y, z of a vector3, a { x, y, z } map or a { [1], [2], [3] } array; nil when not three finite numbers.
local function xyz(t)
    local ty = type(t)
    if ty ~= 'table' and ty ~= 'vector3' then return nil end
    local x, y, z = t.x, t.y, t.z
    if x == nil then x, y, z = t[1], t[2], t[3] end
    if isFinite(x) and isFinite(y) and isFinite(z) then return x, y, z end
    return nil
end

--- Core.Clock.now() (u32 ms); GetGameTimer() & 0xFFFFFFFF when the lib is not there.
local function clockNow()
    local clock = Core.Clock
    if clock and clock.now then return clock.now() end
    return GetGameTimer() & 0xFFFFFFFF
end

--- a - b of two Clock stamps as a signed 32-bit difference (Core.Clock.diff when present).
local function clockDiff(a, b)
    local clock = Core.Clock
    if clock and clock.diff then return clock.diff(a, b) end
    return floor((a - b + 0x80000000) % 0x100000000) - 0x80000000
end

local seq = 0
--- The module-wide version counter: never 0, wraps after 2^32 - 1.
local function nextSeq()
    seq = seq + 1
    if seq > 0xFFFFFFFF then seq = 1 end
    return seq
end

--- A node's ver as it travels: u32 (the store's counter may run past 2^32; clients compare serial numbers, F6).
local function verOf(node)
    local v = toint(node.ver)
    return v and (v & 0xFFFFFFFF) or 0
end

local function axis(v, size)
    local c = floor(v / size)
    if c < -KEY_OFFSET then return -KEY_OFFSET end
    if c >= KEY_OFFSET then return KEY_OFFSET - 1 end
    return c
end

local function keyOf(grid, x, y)
    if grid == 2 then return 0 end
    local size = grid == 1 and REGION_SIZE or CELL_SIZE
    return (axis(x, size) + KEY_OFFSET) * KEY_SPAN + (axis(y, size) + KEY_OFFSET)
end

local counters = { packBuilds = 0, packBytes = 0, entries = 0, entryBytes = 0, drains = 0, gatedOps = 0,
    events = 0, drs = 0, encodeErrors = 0, recells = 0, handovers = 0, skipped = 0, opHits = 0, opBuilds = 0,
    ridePasses = 0 }

local failed = {}   -- [id] = true: logged once
local function fail(id, err)
    counters.encodeErrors = counters.encodeErrors + 1
    if id ~= nil and failed[id] then return end
    if id ~= nil then failed[id] = true end
    local log = Core.Log
    local line = ('Scene index: node %s could not be encoded and is skipped (%s)'):format(tostring(id), tostring(err))
    if log and log.error then log.error('%s', line) else print(line) end
end

--- Codec.pack (it answers nil, err instead of raising) as blob | nil, err.
local function packOf(v)
    local ok, blob, err = pcall(Codec.pack, v)
    if ok and type(blob) == 'string' then return blob end
    return nil, ok and err or blob
end

--------------------------------------------------------------------------------
-- Cells and variants
--------------------------------------------------------------------------------

-- cells[bucket][grid * GRID_SPAN + key] = { bucket, grid, key, roots = { [id] = rec } (public roots), nRoots,
--   nM (public M roots), gated = { [id] = rec } (gated roots AND child gate heads), nGated, [NEAR|FAR|ONE] = var }
-- var = { cell, variant, v, drained (the `to` of its last entry), observed, seen (a number of this tick went out),
--   pack, packV, j (journal), parts ([1] = the CELL header slot), np, nops (ops incl. skipped encodes), egen, dgen,
--   fgen, skip, depMark = { [depId] = mark } }
local cells = {}
local nCells = 0
local gen = 1                          -- the tick generation: +1 at the end of every drain
local mark = 0                         -- one fresh value per blob build: a dependency once per blob
local dirtyList, dirtyN = {}, 0        -- recs changed this tick, in order
local dirtyVars, dirtyVarN = {}, 0     -- variants whose content changed this tick
local emptied, emptiedN = {}, 0        -- cells a gated unit left (no variant saw it): drop checks at the drain
local woken = false                    -- R.flush.wake() went out this tick (reset by drain)

--- Wakes the flush (R.flush, looked up now) the first time this tick queues anything a drain returns; a wake
--- is never lost: without a flush module nothing is recorded and the next change tries again.
local function wake()
    if woken then return end
    local flush = R.flush
    if flush and flush.wake then
        woken = true
        flush.wake()
    end
end

local function getCell(bucket, grid, key, create)
    local byKey = cells[bucket]
    local gk = grid * GRID_SPAN + key
    local cell = byKey and byKey[gk]
    if cell or not create then return cell end
    if not byKey then
        byKey = {}
        cells[bucket] = byKey
    end
    cell = { bucket = bucket, grid = grid, key = key, roots = {}, nRoots = 0, nM = 0, gated = {}, nGated = 0 }
    byKey[gk] = cell
    nCells = nCells + 1
    return cell
end

--- Drops a cell that holds nothing any more (its versions are 0 and its journals go with it).
local function dropIfEmpty(cell)
    if cell.nRoots > 0 or cell.nGated > 0 then return end
    local byKey = cells[cell.bucket]
    local gk = cell.grid * GRID_SPAN + cell.key
    if not byKey or byKey[gk] ~= cell then return end
    byKey[gk] = nil
    nCells = nCells - 1
    if next(byKey) == nil then cells[cell.bucket] = nil end
end

local function varOf(cell, variant)
    local var = cell[variant]
    if not var then
        var = { cell = cell, variant = variant, v = 0, drained = 0, observed = true, packV = 0, np = 0, nops = 0,
            egen = 0, dgen = 0, fgen = 0, skip = false, parts = {}, depMark = {} }
        cell[variant] = var
    end
    return var
end

--- Public roots a variant holds (FAR: the M roots only).
local function countOf(var)
    local cell = var.cell
    return var.variant == FAR and cell.nM or cell.nRoots
end

--- A change of a variant's content: a fresh version when the current one was observed (or it was empty), 0 when
--- it is empty now; the cached pack goes. Recorded for this tick's drain.
local function touchVar(cell, variant)
    wake()
    local var = varOf(cell, variant)
    if countOf(var) == 0 then
        var.v = 0
    elseif var.v == 0 or var.observed then
        var.v = nextSeq()
        var.observed = false
    end
    var.pack = nil
    if var.dgen ~= gen then
        var.dgen = gen
        dirtyVarN = dirtyVarN + 1
        dirtyVars[dirtyVarN] = var
    end
end

--------------------------------------------------------------------------------
-- Kinds, tiers, positions, audiences
--------------------------------------------------------------------------------

local function storeGet(id)
    local store = R.store
    return store and store.get and store.get(id) or nil
end

--- The node's live kind: node.k while it is still the registered definition of its id, else nil (placeholder).
local function kindOf(node)
    local k = node.k
    if type(k) ~= 'table' then return nil end
    local get = R.kinds.get
    if get and k.id ~= nil and get(k.id) ~= k then return nil end
    return k
end

local function radiusOf(node, k)
    local r = tonumber(node.radius)
    if r == nil and k and R.kinds.radius then
        local ok, rr = pcall(R.kinds.radius, k, node)
        r = ok and tonumber(rr) or nil
    end
    return r or 0
end

--- node.tier when set ('S'|'M'|'L'|'G'), else derived from global / radius through R.kinds.tier.
local function tierOf(node)
    local t = node.tier
    if GRID_OF[t] then return t end
    if node.global then return 'G' end
    local r = radiusOf(node, type(node.k) == 'table' and node.k or nil)
    local tier = R.kinds.tier
    if tier then
        local ok, tt = pcall(tier, r, node.global)
        if ok and GRID_OF[tt] then return tt end
    end
    local s = sceneCfg()
    if r <= num(s.TierS, 160) then return 'S' end
    if r <= num(s.TierM, 448) then return 'M' end
    return 'L'
end

local function bucketOf(node)
    local b = mathType(node.bucket) == 'integer' and node.bucket or toint(node.bucket)
    if b and b >= 0 and b <= 0x7FFFFFFF then return b end
    return 0
end

--- Is a node gated? Its EFFECTIVE audience (its own and every ancestor's): R.store.audienceOf (F1), else
--- `fallback` (the index's own walk of the audiences on the path).
local function effGated(node, fallback)
    local store = R.store
    local fn = store and store.audienceOf
    if fn then
        local ok, a = pcall(fn, node)
        if ok then return a ~= nil end
    end
    return fallback
end

local function rootGated(node) return effGated(node, node.audience ~= nil) end

--- Where a root is at `t`: its attachment target (players through PlayerGrid.positionOf; net entities and nodes
--- through R.store.pose, which checks the entity is still the one attached and holds the last pose while it is
--- gone, RV1 F20), its motion (R.store.pose / SceneMotion.pose: x, y, z, rx, ry, rz), else its base position.
--- nil when unknown right now.
local function posNow(node, t)
    local att = node.attach
    if type(att) == 'table' then
        if att.player ~= nil then
            local grid = Core.PlayerGrid
            if grid and grid.positionOf then
                local x, y, z = grid.positionOf(att.player)
                if isFinite(x) and isFinite(y) then return x, y, z end
            end
            return nil
        end
        local store = R.store
        if store and store.pose then
            local ok, x, y, z = pcall(store.pose, node, t)
            if ok and isFinite(x) and isFinite(y) then return x, y, z end
            return nil
        end
        local netId = toint(att.net)                          -- no store (offline): the entity itself
        local e = netId and NetworkGetEntityFromNetworkId(netId) or 0
        if e and e ~= 0 and DoesEntityExist(e) then
            local c = GetEntityCoords(e)
            if c and isFinite(c.x) and isFinite(c.y) then return c.x, c.y, c.z end
        end
        return nil
    end
    if node.motion ~= nil then
        local store = R.store
        if store and store.pose then
            local ok, x, y, z, rx, ry, rz = pcall(store.pose, node, t)
            if ok and isFinite(x) and isFinite(y) then return x, y, z, rx, ry, rz end
        else
            local motion = Core.SceneMotion
            local bx, by, bz = xyz(node.pos)
            if motion and motion.pose and bx then
                local brx, bry, brz = xyz(node.rot)
                local ok, x, y, z, rx, ry, rz = pcall(motion.pose, bx, by, bz, brx or 0.0, bry or 0.0, brz or 0.0,
                    node.motion, t)
                if ok and isFinite(x) and isFinite(y) then return x, y, z, rx, ry, rz end
            end
        end
    end
    return xyz(node.pos)
end

--- How far (m) a point lies outside the square of cell `key` (0 inside): the re-cell tolerance test.
local function outside(grid, key, x, y)
    local size = grid == 1 and REGION_SIZE or CELL_SIZE
    local x0 = (key // KEY_SPAN - KEY_OFFSET) * size
    local y0 = (key % KEY_SPAN - KEY_OFFSET) * size
    return max(x0 - x, x - (x0 + size), y0 - y, y - (y0 + size), 0)
end

--------------------------------------------------------------------------------
-- Records (one per indexed node), the tree, placement
--------------------------------------------------------------------------------

-- rec = { id, node, t = 'root'|'kid'|'dep', removed,
--   tree:   up (parent rec), dk = { [id] = childRec } (direct, non-removed children), nk (#dk), depth (0 = root)
--   roots:  cell (current cell record), tier, isM, gated, gh = { [id] = headRec } (child gate heads), mIdx / parked
--   kids:   root (root rec), hroot (the root it is registered under as a gate head)
--   published at the last drain: pb (bucket, nil = nowhere), pk (grid * GRID_SPAN + key), pf (1 NEAR | 2 FAR |
--     4 ONE | 8 gated), ph (its unit head when gated), pDeps (copy of node.deps)
--   pending this tick: dgen, ggen, pgen, dq (a root's dirty children), fput, fset = { [name] = true }, fsetFar,
--     finter, fdeps, fmove, fmotion, fpromo = 'promote'|'demote', netId, fdel (how) }
local recs = {}
local byTier = { S = 0, M = 0, L = 0, G = 0 }

local function markDirty(rec)
    wake()
    if rec.dgen ~= gen then
        rec.dgen = gen
        dirtyN = dirtyN + 1
        dirtyList[dirtyN] = rec
    end
end

local function touchCell(cell, withFar)
    if cell.grid == 0 then
        touchVar(cell, NEAR)
        if withFar then touchVar(cell, FAR) end
    else
        touchVar(cell, ONE)
    end
end

--- Touches the variants a public root's cell holds it in (FAR only when `farToo` and it is an M root).
local function touchPlacement(root, farToo)
    local cell = root and root.cell
    if not cell or root.gated or root.removed then return end
    touchCell(cell, farToo and root.isM)
end

--- node.cell of an indexed root or gate head: { grid, key } of its (root's) cell, reused; nil in none.
local function setNodeCell(node, cell)
    if not cell then
        node.cell = nil
        return
    end
    local nc = node.cell
    if type(nc) ~= 'table' then
        nc = {}
        node.cell = nc
    end
    nc.grid, nc.key = cell.grid, cell.key
end

local function joinGated(cell, rec)
    if cell.gated[rec.id] then return end
    cell.gated[rec.id] = rec
    cell.nGated = cell.nGated + 1
end

local function leaveGated(cell, rec)
    if cell.gated[rec.id] ~= rec then return end
    cell.gated[rec.id] = nil
    cell.nGated = cell.nGated - 1
    emptiedN = emptiedN + 1
    emptied[emptiedN] = cell
end

local function unplace(rec)
    local cell = rec.cell
    if not cell then return end
    rec.cell = nil
    rec.node.cell = nil
    byTier[rec.tier] = byTier[rec.tier] - 1
    for _, h in pairs(rec.gh or EMPTY) do   -- its child gate heads leave with it
        leaveGated(cell, h)
        h.node.cell = nil
    end
    if rec.gated then return leaveGated(cell, rec) end
    cell.roots[rec.id] = nil
    cell.nRoots = cell.nRoots - 1
    if rec.isM then cell.nM = cell.nM - 1 end
    touchCell(cell, rec.isM)
end

local function place(rec, cell)
    rec.cell = cell
    setNodeCell(rec.node, cell)
    byTier[rec.tier] = byTier[rec.tier] + 1
    for _, h in pairs(rec.gh or EMPTY) do
        joinGated(cell, h)
        setNodeCell(h.node, cell)
    end
    if rec.gated then return joinGated(cell, rec) end
    cell.roots[rec.id] = rec
    cell.nRoots = cell.nRoots + 1
    if rec.isM then cell.nM = cell.nM + 1 end
    touchCell(cell, rec.isM)
end

local function recellTolerance() return num(motionCfg().RecellTolerance, 8, 0, 4096) end

--- Puts a root into the cell its tier, bucket, audience and position ask for. `exact` = false applies the re-cell
--- tolerance (movers): a root that only drifted across a border stays until it is RecellTolerance past it.
--- `px`, `py`: its position when the caller knows it (a rider group), else posNow.
--- @return boolean the placement changed
local function placeRoot(rec, exact, t, px, py)
    local node = rec.node
    local tier = tierOf(node)
    local grid = GRID_OF[tier]
    local bucket = bucketOf(node)
    local gated = rootGated(node)
    local cell = rec.cell
    local x, y = px, py                      -- a rider's group read its player's position once for all of them
    if x == nil then x, y = posNow(node, t or clockNow()) end
    if not x then
        if cell then return false end   -- a mover whose target is unknown right now stays where it is
        x, y = xyz(node.pos)
        if not x then return false end
    end
    local key = keyOf(grid, x, y)
    if cell and cell.bucket == bucket and cell.grid == grid and rec.gated == gated and rec.tier == tier then
        if cell.key == key then return false end
        if not exact and outside(grid, cell.key, x, y) < recellTolerance() then return false end
    end
    if cell then counters.recells = counters.recells + 1 end
    unplace(rec)
    rec.tier, rec.isM, rec.gated = tier, tier == 'M', gated
    place(rec, getCell(bucket, grid, key, true))
    return true
end

local STACK, top = {}, 0
--- Parent-first walk of the subtree BELOW `rec` (direct-children sets): fn(child, a, b) answering true skips that
--- child's subtree. Re-entrant (a nested walk works above the current top of the shared stack), O(subtree).
local function walk(rec, fn, a, b)
    local dk = rec.dk
    if not dk then return end
    local base = top
    for _, c in pairs(dk) do
        top = top + 1
        STACK[top] = c
    end
    while top > base do
        local c = STACK[top]
        STACK[top] = nil
        top = top - 1
        if not fn(c, a, b) then
            local ck = c.dk
            if ck then
                for _, g in pairs(ck) do
                    top = top + 1
                    STACK[top] = g
                end
            end
        end
    end
end

--- Makes `rec` a direct child of `parent` (nil = of nobody); rec.nk counts a node's direct children (O(1) CHILDREN).
local function link(rec, parent)
    local old = rec.up
    if old == parent then return end
    if old and old.dk and old.dk[rec.id] == rec then
        old.dk[rec.id] = nil
        old.nk = old.nk - 1
    end
    rec.up = parent
    if parent then
        local dk = parent.dk
        if not dk then
            dk = {}
            parent.dk, parent.nk = dk, 0
        end
        dk[rec.id] = rec
        parent.nk = parent.nk + 1
    end
end

--- The unit of a node: the nearest ancestor-or-self below the root carrying its own audience (a gate head), else
--- the root. O(depth).
local function unitHead(rec)
    local root = rec.root
    local cur = rec
    for _ = 1, MAX_DEPTH do
        if cur == nil or cur == root then return root end
        if cur.node.audience ~= nil then return cur end
        cur = cur.up
    end
    return root
end

--- A child with its own audience is a gate head (F1): registered under its root (root.gh) and, while the root is
--- in a cell, in that cell's gated set with node.cell = the root's cell. Re-checked whenever it or its root changes.
local function syncHead(rec)
    local want = rec.t == 'kid' and not rec.removed and rec.node.audience ~= nil and rec.root or nil
    local cur = rec.hroot
    if cur == want then return end
    if cur then
        if cur.gh then cur.gh[rec.id] = nil end
        if cur.cell then leaveGated(cur.cell, rec) end
        rec.node.cell = nil
    end
    rec.hroot = want
    if want then
        local gh = want.gh
        if not gh then
            gh = {}
            want.gh = gh
        end
        gh[rec.id] = rec
        if want.cell then
            joinGated(want.cell, rec)
            setNodeCell(rec.node, want.cell)
        end
    end
end

--- Where `rec` is now: bucket, grid, key, in NEAR, in FAR, in ONE, gated, its unit head — nil when in no cell.
local function placement(rec)
    if rec.removed or rec.t == 'dep' then return nil end
    local root = rec.t == 'kid' and rec.root or rec
    local cell = root and not root.removed and root.cell
    if not cell then return nil end
    local head = rec.t == 'kid' and unitHead(rec) or rec
    local gated = root.gated
    if rec ~= root then gated = effGated(rec.node, head ~= root or gated) end
    if gated then return cell.bucket, cell.grid, cell.key, false, false, false, true, head end
    if cell.grid == 0 then return cell.bucket, 0, cell.key, true, root.isM, false, false, root end
    return cell.bucket, cell.grid, cell.key, false, false, true, false, root
end

--------------------------------------------------------------------------------
-- Movers: roots with motion or an attachment. Swept at Motion.ServerHz while their plan may leave the cell;
-- parked (a heap of wake-up times) while its bounding box stays inside the cell ± tolerance (RV1 F19)
--------------------------------------------------------------------------------

local movers, moverN, moverCursor, moverThread = {}, 0, 0, false
local hDue, hRec, hStamp, heapN, parkedN = {}, {}, {}, 0, 0

local function heapPush(due, rec, stamp)
    heapN = heapN + 1
    local i = heapN
    while i > 1 do
        local p = i // 2
        if hDue[p] <= due then break end
        hDue[i], hRec[i], hStamp[i] = hDue[p], hRec[p], hStamp[p]
        i = p
    end
    hDue[i], hRec[i], hStamp[i] = due, rec, stamp
end

local function heapPop()
    local rec, stamp = hRec[1], hStamp[1]
    local due, r, s = hDue[heapN], hRec[heapN], hStamp[heapN]
    hDue[heapN], hRec[heapN], hStamp[heapN] = nil, nil, nil
    heapN = heapN - 1
    if heapN > 0 then
        local i = 1
        while true do
            local c = i * 2
            if c > heapN then break end
            if c < heapN and hDue[c + 1] < hDue[c] then c = c + 1 end
            if hDue[c] >= due then break end
            hDue[i], hRec[i], hStamp[i] = hDue[c], hRec[c], hStamp[c]
            i = c
        end
        hDue[i], hRec[i], hStamp[i] = due, r, s
    end
    return rec, stamp
end

--- Drops the stale entries (a re-parked or unparked plan leaves its old entry behind) once they outnumber the live.
local function heapCompact()
    local d, r, s, n = hDue, hRec, hStamp, heapN
    hDue, hRec, hStamp, heapN = {}, {}, {}, 0
    for i = 1, n do
        local rec = r[i]
        if rec.parked and rec.hstamp == s[i] then heapPush(d[i], rec, s[i]) end
    end
end

--- The XY bounding box a plan can ever reach, or nil (unbounded / unknown: swept). Absolute plans ignore the base.
local function motionBox(node, d)
    local kind = d.t
    local bx, by = xyz(node.pos)
    if kind == 'spin' then
        if bx then return bx, by, bx, by end
        return nil
    elseif kind == 'osc' then
        local dir, a = d.dir, tonumber(d.amp)
        if not (bx and a and type(dir) == 'table') then return nil end
        local ex, ey = abs((tonumber(dir.x) or 0) * a), abs((tonumber(dir.y) or 0) * a)
        return bx - ex, by - ey, bx + ex, by + ey
    elseif kind == 'orbit' then
        local c, r = d.c, tonumber(d.r)
        if not (r and type(c) == 'table' and isFinite(c.x) and isFinite(c.y)) then return nil end
        r = abs(r)
        return c.x - r, c.y - r, c.x + r, c.y + r
    elseif kind == 'tween' then
        local f, to = d.from, d.to
        local fx, fy = bx, by
        if type(f) == 'table' and isFinite(f.x) and isFinite(f.y) then fx, fy = f.x, f.y end
        if not (fx and type(to) == 'table' and isFinite(to.x) and isFinite(to.y)) then return nil end
        return min(fx, to.x), min(fy, to.y), max(fx, to.x), max(fy, to.y)
    end
    local list = kind == 'path' and d.pts or (kind == 'keys' and d.keys) or nil
    if type(list) ~= 'table' or list[1] == nil then return nil end
    local x0, y0, x1, y1, seg = math.huge, math.huge, -math.huge, -math.huge, 0
    local px, py
    for i = 1, #list do
        local p = list[i]
        local x, y = tonumber(p.x), tonumber(p.y)
        if not (isFinite(x) and isFinite(y)) then return nil end
        x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
        if px then seg = max(seg, abs(x - px) + abs(y - py)) end
        px, py = x, y
    end
    -- a Catmull-Rom / Hermite curve may bulge past its points: half the longest segment is a generous bound
    local m = ((kind == 'path' and d.curve == 'catmull') or (kind == 'keys' and d.smooth)) and seg * 0.5 or 0
    return x0 - m, y0 - m, x1 + m, y1 + m
end

--- Does the box stay less than the re-cell tolerance outside `cell` (so the node can never be re-celled)?
local function boxInside(cell, x0, y0, x1, y1)
    if cell.grid == 2 then return true end
    local size = cell.grid == 1 and REGION_SIZE or CELL_SIZE
    local cx0 = (cell.key // KEY_SPAN - KEY_OFFSET) * size
    local cy0 = (cell.key % KEY_SPAN - KEY_OFFSET) * size
    local tol = recellTolerance()
    return x0 > cx0 - tol and x1 < cx0 + size + tol and y0 > cy0 - tol and y1 < cy0 + size + tol
end

--- A 'once' path's pass time (ms): d, or its polyline length at sp (a lower bound for a curve: re-checked).
local function pathMs(d)
    local dd = tonumber(d.d)
    if dd then return dd end
    local sp, pts = tonumber(d.sp), d.pts
    if not (sp and sp > 0 and type(pts) == 'table') then return 0 end
    local len = 0
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local dx, dy, dz = (b.x or 0) - (a.x or 0), (b.y or 0) - (a.y or 0), (b.z or 0) - (a.z or 0)
        len = len + math.sqrt(dx * dx + dy * dy + dz * dz)
    end
    return len / sp * 1000
end

--- Milliseconds until a parked plan needs a look: its end (tween, 'once' path, non-looping keys) or the moment
--- Motion.needsRebase turns true, whichever comes first (never sooner than PARK_MIN_MS).
local function parkWait(d, t)
    local age = clockDiff(t, d.t0 or t)
    local wait = REBASE_MS - age + 1
    local kind, finish = d.t, nil
    if kind == 'tween' then
        finish = (tonumber(d.d) or 0) - age
    elseif kind == 'keys' and not d.loop then
        local keys = d.keys
        local last = type(keys) == 'table' and keys[#keys]
        finish = (last and tonumber(last.t) or 0) - age
    elseif kind == 'path' and (d.loop == nil or d.loop == 'once') then
        finish = pathMs(d) - age
    end
    if finish and finish + 1 < wait then wait = finish + 1 end
    return max(PARK_MIN_MS, wait)
end

local function finished(desc, t)
    local motion = Core.SceneMotion
    if not (motion and motion.finished) then return false end
    local ok, done = pcall(motion.finished, desc, t or clockNow())
    return ok and done == true
end

local function wantsMover(rec, t)
    if rec.t ~= 'root' or rec.removed or rec.tier == 'G' then return false end
    local node = rec.node
    if node.attach ~= nil then return true end
    local desc = node.motion
    if desc == nil then return false end
    if finished(desc, t) then   -- kept until the sweep handed it to R.store.settle (once per plan)
        local store = R.store
        return store ~= nil and store.settle ~= nil and rec.settled ~= desc
    end
    return true
end

local sweeper = {}   -- sweeper.loop (below): the thread body; a field, so updateMover can start it

local function startThread()
    if moverThread then return end
    moverThread = true
    CreateThread(sweeper.loop)
end

-- Riders (review RV4 F7): roots attached to a PLAYER are never swept one by one. They ride in ONE group per player
-- (RIDE.by[src] = { src, recs = { [rec] = true }, nrec, i, x0, y0, x1, y1 }), swept at Motion.ServerHz with the
-- movers: one PlayerGrid.positionOf read per player per sweep, and while the player stays inside the group's safe
-- box — the intersection of its roots' cells ± the re-cell tolerance, where placeRoot could not re-cell any of them —
-- nothing else runs. Out of it, the player's roots are re-placed from that one position and the box is rebuilt.
-- Any re-place from outside the sweep (put, changed) clears the box (x0 = nil: the next sweep re-places).
local RIDE = { by = {}, list = {}, n = 0, cursor = 0 }

local function rideLeave(rec)
    local g = rec.rg
    if not g then return end
    rec.rg = nil
    g.recs[rec], g.nrec, g.x0 = nil, g.nrec - 1, nil
    if g.nrec > 0 then return end
    RIDE.by[g.src] = nil
    local list, n = RIDE.list, RIDE.n
    local last = list[n]
    list[g.i], last.i = last, g.i
    list[n], RIDE.n = nil, n - 1
end

local function rideJoin(rec, src)
    local g = rec.rg
    if g and g.src ~= src then
        rideLeave(rec)
        g = nil
    end
    if not g then
        g = RIDE.by[src]
        if not g then
            g = { src = src, recs = {}, nrec = 0 }
            RIDE.n = RIDE.n + 1
            RIDE.list[RIDE.n], g.i = g, RIDE.n
            RIDE.by[src] = g
        end
        g.recs[rec], g.nrec = true, g.nrec + 1
        rec.rg = g
        startThread()
    end
    g.x0 = nil
end

--- The group's safe box from its roots' current cells (open interval: placeRoot re-cells at >= the tolerance).
local function rideBox(g)
    local tol = recellTolerance()
    local x0, y0, x1, y1 = -math.huge, -math.huge, math.huge, math.huge
    for rec in pairs(g.recs) do
        local cell = rec.cell
        if not cell then
            g.x0 = nil
            return
        end
        if cell.grid ~= 2 then
            local size = cell.grid == 1 and REGION_SIZE or CELL_SIZE
            local cx = (cell.key // KEY_SPAN - KEY_OFFSET) * size
            local cy = (cell.key % KEY_SPAN - KEY_OFFSET) * size
            x0, y0 = max(x0, cx - tol), max(y0, cy - tol)
            x1, y1 = min(x1, cx + size + tol), min(y1, cy + size + tol)
        end
    end
    g.x0, g.y0, g.x1, g.y1 = x0, y0, x1, y1
end

--- One group: one position read; inside the safe box nothing happens, else every root of the player is re-placed.
local function rideSweep(g, t)
    local grid = Core.PlayerGrid
    local fn = grid and grid.positionOf
    if not fn then return end
    local x, y = fn(g.src)
    if not (isFinite(x) and isFinite(y)) then return end      -- unknown right now: its roots stay where they are
    if g.x0 and x > g.x0 and x < g.x1 and y > g.y0 and y < g.y1 then return end
    counters.ridePasses = counters.ridePasses + 1
    for rec in pairs(g.recs) do
        if placeRoot(rec, false, t, x, y) then markDirty(rec) end
    end
    rideBox(g)
end

--- Swept, parked, riding (a player attachment) or neither: re-evaluated whenever the node, its motion or its cell
--- may have changed.
local function updateMover(rec, t)
    local want = wantsMover(rec, t)
    local node = rec.node
    local att = want and node.attach or nil
    local rider = type(att) == 'table' and att.player or nil
    if rider ~= nil then rideJoin(rec, rider) elseif rec.rg then rideLeave(rec) end
    local park = false
    if want and node.attach == nil and rec.cell then
        local desc = node.motion
        if desc ~= nil and desc.t ~= 'dr' then
            local x0, y0, x1, y1 = motionBox(node, desc)
            park = x0 ~= nil and boxInside(rec.cell, x0, y0, x1, y1)
        end
    end
    local swept, i = want and not park and rider == nil, rec.mIdx
    if swept and not i then
        moverN = moverN + 1
        movers[moverN] = rec
        rec.mIdx = moverN
        startThread()
    elseif not swept and i then
        local last = movers[moverN]
        movers[i] = last
        last.mIdx = i
        movers[moverN] = nil
        moverN = moverN - 1
        rec.mIdx = nil
    end
    if want and park then
        if not rec.parked then
            rec.parked = true
            parkedN = parkedN + 1
        end
        local due = GetGameTimer() + parkWait(node.motion, t or clockNow())
        if rec.hdue == nil or abs(due - rec.hdue) > 50 then
            rec.hstamp, rec.hdue = (rec.hstamp or 0) + 1, due
            heapPush(due, rec, rec.hstamp)
            if heapN > 2 * parkedN + 64 then heapCompact() end
        end
        startThread()
    elseif rec.parked then
        rec.parked, rec.hdue, rec.hstamp = nil, nil, (rec.hstamp or 0) + 1
        parkedN = parkedN - 1
    end
end

--- A finished plan: the store folds its exact end pose into the base pose (R.store.settle: motion cleared, new
--- ver, 'move' + 'motion' changes back here), once per plan; a store without settle (or one that refused): the
--- exact final cell. Either way the node is untracked. A C2 'dr' plan "finishes" 1 s after every sample while a
--- script may still drive it, so it is settled only after several heartbeats without one.
local function settle(rec, desc, t)
    local node, store = rec.node, R.store
    local fn = store and store.settle
    if desc ~= nil and fn and rec.settled ~= desc then
        if desc.t == 'dr' then
            local dr = sceneCfg().DeadReckoning
            local idle = max(10000, 6 * num(type(dr) == 'table' and dr.HeartbeatMs, 5000, 0, 600000))
            if clockDiff(t, desc.t0 or t) < idle then return end
        end
        rec.settled = desc
        local x, y, z, rx, ry, rz = posNow(node, t)
        local brx, bry, brz = xyz(node.rot)
        if x and isFinite(z) then
            local ok, err = pcall(fn, node, x, y, z, isFinite(rx) and rx or brx or 0.0,
                isFinite(ry) and ry or bry or 0.0, isFinite(rz) and rz or brz or 0.0)
            if not ok then fail(node.id, err) end
        end
    end
    if placeRoot(rec, true, t) then markDirty(rec) end
    return updateMover(rec, t)
end

--- One mover (swept, or parked and due): a plan close to Clock.diff's ±24.8-day window is rebased
--- (Motion.needsRebase / rebase, a 'motion' change: new ver, new plan to clients); a finished plan is settled
--- (above); a spin never moves the position (no pose); everything else is re-celled past the tolerance.
local function sweep(rec, t)
    if rec.removed or rec.t ~= 'root' then return updateMover(rec, t) end
    local node = rec.node
    local motion, desc = Core.SceneMotion, node.motion
    if desc ~= nil and motion and motion.needsRebase and motion.rebase then
        local ok, due = pcall(motion.needsRebase, desc, t)
        local fresh
        if ok and due then ok, fresh = pcall(motion.rebase, desc, t) end
        if ok and due and type(fresh) == 'table' then
            node.motion = fresh
            local store = R.store
            if store and store.bump then store.bump(node) end
            Index.changed(node, 'motion')
            desc = node.motion
        end
    end
    if node.attach == nil and (desc == nil or finished(desc, t)) then return settle(rec, desc, t) end
    if not wantsMover(rec, t) then
        if placeRoot(rec, true, t) then markDirty(rec) end
        return updateMover(rec, t)
    end
    if node.attach == nil and desc.t == 'spin' then return end
    if placeRoot(rec, false, t) then markDirty(rec) end
end

function sweeper.loop()
    while moverN > 0 or parkedN > 0 or RIDE.n > 0 do
        local hz = num(motionCfg().ServerHz, 2, 0.1, 20)
        local t, now, budget = clockNow(), GetGameTimer(), PARK_BUDGET
        while heapN > 0 and budget > 0 and hDue[1] <= now do   -- parked plans whose time came
            budget = budget - 1
            local rec, stamp = heapPop()
            if rec.parked and rec.hstamp == stamp and not rec.removed then
                rec.hdue = nil
                sweep(rec, t)
                updateMover(rec, t)
            end
        end
        local slices = max(1, min(MAX_SLICES, ceil(max(moverN, RIDE.n) / MOVERS_PER_SLICE)))
        if moverN > 0 then
            for _ = 1, ceil(moverN / slices) do
                if moverN == 0 then break end
                moverCursor = moverCursor + 1
                if moverCursor > moverN then moverCursor = 1 end
                sweep(movers[moverCursor], t)
            end
        end
        local list = RIDE.list
        for _ = 1, ceil(RIDE.n / slices) do        -- player groups: one position read each (RV4 F7)
            local n = RIDE.n
            if n == 0 then break end
            local c = RIDE.cursor + 1
            if c > n then c = 1 end
            RIDE.cursor = c
            rideSweep(list[c], t)
        end
        Wait(max(1, floor(1000 / hz / slices)))
    end
    for i = 1, heapN do hDue[i], hRec[i], hStamp[i] = nil, nil, nil end   -- only stale entries are left
    heapN, moverThread = 0, false
end

--------------------------------------------------------------------------------
-- Encoding (every call pcall'ed: a failing node is logged once and skipped). No per-op temp tables: X / FF / AT /
-- SF / SX are reused (Codec.pack only reads them), each node keeps its PUT ops until it changes (RV1 F12).
--------------------------------------------------------------------------------

local X, FF, AT, SF, SX = {}, {}, {}, {}, {}

--- The PUT extra of a node for the near or the far variant (`far`: without kind.nearFields). @return blob|nil, err
local function extraBlob(node, k, far)
    local fields, near = node.fields, k and k.nearFields
    local f = fields
    if far and type(near) == 'table' and type(fields) == 'table' then
        for name in pairs(near) do
            if fields[name] ~= nil then
                f = FF
                break
            end
        end
        if f == FF then
            for name, v in pairs(fields) do
                if not near[name] then FF[name] = v end
            end
        end
    end
    local att, a = node.attach, nil
    if type(att) == 'table' then
        if att.player ~= nil then
            AT.p, a = att.player, AT
        elseif att.net ~= nil then
            AT.n, a = att.net, AT
        end
    end
    local promoted, q = node.promoted, node.rotOrder
    X.f, X.m, X.o, X.r, X.b = f, node.motion, node.offset, node.offrot, node.bone
    X.a, X.i, X.d = a, node.interact, node.deps
    X.n = type(promoted) == 'table' and promoted.netId or nil
    X.q = (q ~= nil and q ~= 2) and q or nil      -- rotation order: only a non-default one travels
    local blob, err = packOf(X)
    X.f, X.m, X.o, X.r, X.b, X.a, X.i, X.d, X.n, X.q = nil, nil, nil, nil, nil, nil, nil, nil, nil, nil
    AT.p, AT.n = nil, nil
    if f == FF then
        for name in pairs(FF) do FF[name] = nil end
    end
    return blob, err
end

--- One PUT op: the node's base pose (header), kind index (0 + PLACEHOLDER when its kind is gone), flags, extra.
--- Cached on the node per variant side (opN / opF) and keyed by the flags byte; every change drops the cache.
local function encodePut(node, far, gated, hasKids)
    local k = kindOf(node)
    local flags = 0
    if node.motion ~= nil then flags = flags | F_MOTION end
    if node.promoted ~= nil then flags = flags | F_PROMOTED end
    if not k then flags = flags | F_PLACEHOLDER end
    if far then flags = flags | F_FAR end
    if node.interact ~= nil then flags = flags | F_INTERACT end
    if gated then flags = flags | F_GATED end
    if hasKids then flags = flags | F_CHILDREN end
    local cached
    if far then
        if node.opFf == flags then cached = node.opF end
    elseif node.opNf == flags then
        cached = node.opN
    end
    if cached then
        counters.opHits = counters.opHits + 1
        return cached
    end
    local extra, err = extraBlob(node, k, far)
    if not extra then
        fail(node.id, err)
        return nil
    end
    local x, y, z = xyz(node.pos)
    if not x then x, y, z = 0.0, 0.0, 0.0 end
    local rx, ry, rz = xyz(node.rot)
    if not rx then rx, ry, rz = 0.0, 0.0, 0.0 end
    local ok, op = pcall(Codec.put, node.id, k and k.idx or 0, verOf(node), node.parent or 0, flags,
        x, y, z, rx, ry, rz, radiusOf(node, k), extra)
    if not ok then
        fail(node.id, op)
        return nil
    end
    counters.opBuilds = counters.opBuilds + 1
    if far then node.opF, node.opFf = op, flags else node.opN, node.opNf = op, flags end
    return op
end

--- Drops a node's cached PUT ops (every change); `keepFar`: a near-field-only SET leaves the far op valid.
local function dropOps(node, keepFar)
    node.opN, node.opNf = nil, nil
    if not keepFar then node.opF, node.opFf = nil, nil end
end

--- One SET op from the names changed this tick (values read now: the latest wins, a nil value is a removal);
--- `far` drops kind.nearFields. nil when nothing is left for this variant (or on an encode error).
local function encodeSet(rec, far, depsCh)
    local node = rec.node
    local k = far and kindOf(node) or nil
    local near = k and k.nearFields or nil
    local set, nf, nx = rec.fset, 0, 0
    if set and next(set) ~= nil then
        local fields = type(node.fields) == 'table' and node.fields or EMPTY
        for name in pairs(set) do
            if not (near and near[name]) then
                local v = fields[name]
                if v ~= nil then
                    SF[name], nf = v, nf + 1
                else
                    nx = nx + 1
                    SX[nx] = name
                end
            end
        end
    end
    if nf > 0 then X.f = SF end
    if nx > 0 then X.x = SX end
    if rec.finter then X.i = node.interact or false end
    if depsCh then X.d = node.deps or false end
    local blob, err
    if X.f ~= nil or X.x ~= nil or X.i ~= nil or X.d ~= nil then blob, err = packOf(X) end
    X.f, X.x, X.i, X.d = nil, nil, nil, nil
    if nf > 0 then
        for name in pairs(SF) do SF[name] = nil end
    end
    for i = 1, nx do SX[i] = nil end
    if not blob then
        if err ~= nil then fail(node.id, err) end
        return nil
    end
    local ok, op = pcall(Codec.set, node.id, verOf(node), blob)
    if not ok then
        fail(node.id, op)
        return nil
    end
    return op
end

--- One MOVE / MOTION / PROMOTE / DEMOTE op.
local function encodeOne(rec, what)
    local node = rec.node
    local id, ver = node.id, verOf(node)
    local ok, op
    if what == 'move' or what == 'demote' then
        local x, y, z = xyz(node.pos)
        if not x then x, y, z = 0.0, 0.0, 0.0 end
        local rx, ry, rz = xyz(node.rot)
        if not rx then rx, ry, rz = 0.0, 0.0, 0.0 end
        ok, op = pcall(what == 'move' and Codec.move or Codec.demote, id, ver, x, y, z, rx, ry, rz)
    elseif what == 'motion' then
        local blob
        blob, op = packOf(node.motion)
        ok = blob ~= nil
        if ok then ok, op = pcall(Codec.motion, id, ver, blob) end
    else   -- promote
        local netId = rec.netId
        if netId == nil and type(node.promoted) == 'table' then netId = node.promoted.netId end
        ok, op = pcall(Codec.promote, id, ver, netId or 0)
    end
    if not ok then
        fail(id, op)
        return nil
    end
    return op
end

--- Appends one op to a blob builder (a variant during drain, PB for packs / gatedPut / gated items). parts[1] is
--- the CELL header slot, so a blob is ONE concat (no header .. body copy).
local function add(b, op)
    local n = b.np + 1
    b.np = n
    b.parts[n + 1] = op
end

local function clearParts(b)
    local parts = b.parts
    for i = 1, b.np + 1 do parts[i] = nil end
    b.np = 0
end

--- The PUT of every dependency of `node` that this blob does not carry yet (`marks[depId] == m`: carried; every
--- blob build takes a fresh `m` from the one `mark` counter, so marks never collide).
local function emitDeps(b, marks, node, far, m)
    local deps = node.deps
    if type(deps) ~= 'table' then return end
    for i = 1, #deps do
        local did = deps[i]
        if did ~= nil and marks[did] ~= m then
            marks[did] = m
            local dr = recs[did]
            local dnode
            if dr then dnode = not dr.removed and dr.node or nil else dnode = storeGet(did) end
            local op = dnode and encodePut(dnode, far, false, false)
            if op then add(b, op) end
        end
    end
end

--------------------------------------------------------------------------------
-- Changes (called by server/scene.lua; each is O(1) plus the node's cell work, O(subtree) for tree changes)
--------------------------------------------------------------------------------

local pendEvents, outEvents = {}, {}           -- C4 events of this tick / handed out by the last drain
local drByNode, pendDrs, outDrs = {}, {}, {}   -- C2 records reused per node; this tick's / the last drain's
local SUB, subN = {}, 0                        -- scratch: a subtree collected before it is dismantled

--- Touches every variant that holds a dependent of the dependency `rec`.
local function depTouch(rec)
    local store = R.store
    local users = store and store.dependents and store.dependents(rec.id)
    if type(users) ~= 'table' then return end
    for uid in pairs(users) do
        local ur = recs[uid]
        if ur and not ur.removed then touchPlacement(ur.t == 'kid' and ur.root or ur, true) end
    end
end

--- walk() callbacks: a child moved with its subtree to `root`; a child whose unit changed; a subtree collected.
local function rehomeKid(kid, root)
    kid.root = root
    kid.depth = (kid.up and kid.up.depth or 0) + 1
    syncHead(kid)
    markDirty(kid)
    return false
end

local function markKid(kid)
    markDirty(kid)
    return false
end

local function collectKid(kid)
    subN = subN + 1
    SUB[subN] = kid
    return false
end

--- Inserts or re-indexes a node (its subtree follows a new root or parent); queues a PUT.
function Index.put(node)
    if type(node) ~= 'table' or mathType(node.id) ~= 'integer' then return false end
    local id = node.id
    local rec = recs[id]
    if not rec then
        rec = { id = id, node = node, dgen = 0, ggen = 0, depth = 0 }
        recs[id] = rec
    end
    rec.node, rec.removed, rec.fdel = node, nil, nil
    dropOps(node)
    local was, wasHead = rec.t, rec.hroot ~= nil
    if type(node.k) == 'table' and node.k.dependency then      -- a dependency: no pose, no entry
        if was == 'root' then unplace(rec) end
        if was == 'kid' then touchPlacement(rec.root, true) end
        link(rec, nil)
        rec.t, rec.root = 'dep', nil
        syncHead(rec)
        updateMover(rec)
        depTouch(rec)
    elseif node.parent ~= nil then                             -- a child: rides in its root's cell
        local pr = recs[node.parent]
        if (not pr or pr.removed or pr.t == 'dep') and node.parent ~= id then
            local pn = storeGet(node.parent)                    -- a parent the index has not seen (load order)
            if pn then Index.put(pn) end
            pr = recs[node.parent]
        end
        local root = pr and not pr.removed and (pr.t == 'root' and pr or (pr.t == 'kid' and pr.root)) or nil
        local a = pr                                            -- a parent inside the node's own subtree: a cycle
        for _ = 1, MAX_DEPTH do
            if a == nil or a == rec then break end
            a = a.up
        end
        if not root or a == rec then
            if was == nil then recs[id] = nil end
            return false
        end
        if was == 'root' then unplace(rec) end
        local oldRoot = was == 'kid' and rec.root or nil
        rec.t = 'kid'
        updateMover(rec)
        link(rec, pr)
        local depth = (pr.depth or 0) + 1
        if oldRoot ~= root or rec.depth ~= depth then
            touchPlacement(oldRoot, true)
            rec.root, rec.depth = root, depth
            walk(rec, rehomeKid, root)
        end
        touchPlacement(root, true)
        syncHead(rec)
    else                                                       -- a root
        if was == 'kid' then
            touchPlacement(rec.root, true)
            link(rec, nil)
        end
        rec.t, rec.root, rec.depth = 'root', nil, 0
        syncHead(rec)
        placeRoot(rec, true)
        touchPlacement(rec, true)
        updateMover(rec)
        if was == 'kid' then walk(rec, rehomeKid, rec) end
    end
    if (rec.hroot ~= nil) ~= wasHead then walk(rec, markKid) end   -- its subtree changed units (F1)
    rec.fput = true
    markDirty(rec)
    local list = was == nil and node.children or nil            -- a new root lists children the index lacks
    if type(list) == 'table' then
        for i = 1, #list do
            local cn = recs[list[i]] == nil and storeGet(list[i]) or nil
            if cn and cn.parent ~= nil then Index.put(cn) end
        end
    end
    return true
end

--- Records the field names a 'set' patch touched (values are read at drain). Takes the wire-shaped patch
--- { f = { name = value }, x = { names }, i?, a?, d? } or a flat { name = value } map.
--- @return boolean the far variant is affected (a non-near field, or anything but fields)
local function noteSet(rec, node, data)
    if type(data) ~= 'table' then
        rec.fput = true
        return true
    end
    local near = type(node.k) == 'table' and node.k.nearFields or nil
    local set = rec.fset
    if not set then
        set = {}
        rec.fset = set
    end
    local wire = data.f ~= nil or data.x ~= nil or data.i ~= nil or data.a ~= nil or data.d ~= nil
    for key in pairs(data) do
        if not SET_KEYS[key] then
            wire = false
            break
        end
    end
    local far = false
    if wire then
        if type(data.f) == 'table' then for name in pairs(data.f) do set[name] = true end end
        if type(data.x) == 'table' then for _, name in ipairs(data.x) do set[name] = true end end
        if data.i ~= nil then rec.finter = true end
        if data.a ~= nil then rec.fput = true end    -- an attachment comes with offset / bone: the whole node
        if data.d ~= nil then rec.fdeps = true end
        far = data.i ~= nil or data.a ~= nil or data.d ~= nil
    else
        for name in pairs(data) do set[name] = true end
    end
    for name in pairs(set) do
        if not (near and near[name]) then
            far = true
            break
        end
    end
    if far then rec.fsetFar = true end
    return far
end

--- The record of `node`; a dependency gets one on first use (the store never put()s dependencies).
local function recOf(node)
    if type(node) ~= 'table' then return nil end
    local rec = recs[node.id]
    if not rec and type(node.k) == 'table' and node.k.dependency and mathType(node.id) == 'integer' then
        rec = { id = node.id, node = node, t = 'dep', dgen = 0, ggen = 0, depth = 0 }
        recs[node.id] = rec
    end
    return rec
end

--- A change of an indexed node: what = 'set' (patch) | 'move' | 'follow' | 'motion' | 'promote' (netId) | 'demote' |
--- 'interact' | 'attach' | 'deps'. 'attach', a child's 'move' (new offset / offrot / bone) and anything unknown
--- re-send the whole node; every change drops the node's cached ops (a near-field-only 'set' keeps the far one).
--- Tier / bucket / audience drift re-places. 'follow' (R.store.follow: a promoted root's pose / bucket follows its
--- clone) is a 'move' re-celled with the movers' tolerance — a bucket change re-places at once (DEL there, PUT here).
function Index.changed(node, what, data)
    local rec = recOf(node)
    if not rec or rec.removed then return false end
    rec.node = node
    local farToo = true
    if what == 'set' then
        farToo = noteSet(rec, node, data)
        dropOps(node, not farToo)
    else
        dropOps(node)
        if what == 'move' or what == 'follow' then   -- a child's / an attached root's move is a new offset: all again
            if rec.t == 'root' and node.attach == nil then rec.fmove = true else rec.fput = true end
        elseif what == 'motion' then rec.fmotion = true
        elseif what == 'promote' or what == 'demote' then
            rec.fpromo, rec.netId = what, what == 'promote' and data or nil
        elseif what == 'interact' then rec.finter = true
        elseif what == 'attach' then rec.fput = true   -- a new offset / offrot / bone too, which no SET carries
        elseif what == 'deps' then rec.fdeps = true
        else rec.fput = true end
    end
    if rec.t == 'dep' then
        depTouch(rec)
    elseif rec.t == 'root' then
        placeRoot(rec, what == 'move' or what == 'demote' or what == 'attach')   -- 'follow': the tolerance
        updateMover(rec)
        touchPlacement(rec, farToo)
    else
        touchPlacement(rec.root, farToo)
    end
    markDirty(rec)
    return true
end

local function removeOne(r, how)
    r.removed, r.fdel = true, how
    markDirty(r)
    if r.t == 'root' then
        unplace(r)
        updateMover(r)
    elseif r.t == 'kid' then
        touchPlacement(r.root, true)
    end
    syncHead(r)
end

--- Removes a node (how = 'normal'|'fade'|'handover' or Codec.DEL.*): queues its DEL; its subtree goes with it.
function Index.remove(node, how)
    local rec = recOf(node)
    if not rec or rec.removed then return false end
    rec.node = node
    how = HOW_OF[how] or ((how == 0 or how == 1 or how == 2) and how) or DEL_NORMAL
    if rec.t == 'dep' then
        rec.removed, rec.fdel = true, how
        markDirty(rec)
        depTouch(rec)
        return true
    end
    subN = 0
    walk(rec, collectKid)                       -- collected first: the removal dismantles the tree
    removeOne(rec, how)
    link(rec, nil)
    for i = 1, subN do
        local kid = SUB[i]
        SUB[i] = nil
        if not kid.removed then removeOne(kid, how) end
        link(kid, nil)
    end
    subN = 0
    return true
end

--- A C4 one-shot event (not journaled): the node's cell, or for a positional one the grid its radius asks for.
--- `gate` = the node's unit head when it is gated (its effective audience decides who hears it, RV1 F2).
function Index.event(node, x, y, z, bucket, name, params, t, radius, horizonMs)
    if not (isFinite(x) and isFinite(y) and isFinite(z)) or type(name) ~= 'string' then return false end
    radius = num(radius, 100, 0, 1e6)
    horizonMs = num(horizonMs, 2000, 0, 600000)
    if mathType(t) ~= 'integer' then t = clockNow() end
    local id, grid, key, gate = 0, nil, nil, nil
    if type(node) == 'table' then
        id = node.id
        local rec = recs[id]
        local b, g, k, _, _, _, gt, head
        if rec then b, g, k, _, _, _, gt, head = placement(rec) end
        if b then bucket, grid, key = b, g, k else bucket = bucketOf(node) end
        if gt then gate = head.node end
    end
    if mathType(bucket) ~= 'integer' or bucket < 0 then bucket = 0 end
    if not grid then
        local s = sceneCfg()
        grid = radius <= num(s.TierM, 448) and 0 or (radius <= num(s.TierL, 1500) and 1 or 2)
        key = keyOf(grid, x, y)
    end
    local blob, op = packOf(params)
    local ok = blob ~= nil
    if ok then ok, op = pcall(Codec.event, id, t, x, y, z, name, blob) end
    if not ok then
        fail(id, op)
        return false
    end
    wake()
    pendEvents[#pendEvents + 1] = { bucket = bucket, grid = grid, key = key, x = x, y = y, z = z, radius = radius,
        horizonMs = horizonMs, t = t, blob = op, node = type(node) == 'table' and node or nil, gate = gate }
    counters.events = counters.events + 1
    return true
end

--- A C2 dead-reckoning update (not journaled, latest per node per tick): the packs of the node's cell are dropped
--- WITHOUT a version bump — new subscribers get the new pose, current ones converge through the DR op.
function Index.dr(node, t, x, y, z, vx, vy, vz, yaw)
    local rec = type(node) == 'table' and recs[node.id]
    if not rec or rec.removed or rec.t == 'dep' then return false end
    local ok, op = pcall(Codec.dr, node.id, t, x, y, z, vx, vy, vz, yaw)
    if not ok then
        fail(node.id, op)
        return false
    end
    local root = rec.t == 'kid' and rec.root or rec
    local cell = root and root.cell
    if cell then
        for v = NEAR, ONE do
            if cell[v] then cell[v].pack = nil end
        end
    end
    dropOps(node)
    if rec.t == 'root' then   -- a driven root follows its samples across cells (its 'dr' plan ends 1 s after each)
        if placeRoot(rec, false) then markDirty(rec) end
        updateMover(rec)
    end
    local _, _, _, _, _, _, gt, head = placement(rec)
    local d = drByNode[node.id]
    if not d then
        d = { node = node, gen = 0 }
        drByNode[node.id] = d
    end
    d.node, d.blob, d.gate = node, op, gt and head.node or nil
    if d.gen ~= gen then
        d.gen = gen
        pendDrs[#pendDrs + 1] = d
    end
    wake()
    counters.drs = counters.drs + 1
    return true
end

--------------------------------------------------------------------------------
-- Drain: this tick's coalesced ops -> journal entries, gated items, events, DRs
--------------------------------------------------------------------------------

local finVars, finN = {}, 0            -- variants that received ops during this drain
local groups, groupN, depList, depN = {}, 0, {}, 0
local outEntries, outN, gatedOut, gatedN = {}, 0, {}, 0
local PB = { parts = {}, np = 0 }      -- builder of packs, gatedPut and gated items
local GM = {}                          -- dependency marks of gated items
local drainMark = 0                    -- the mark of every variant blob of the running drain

--- Anyone to encode for? R.interest.subscribers (when loaded): ring 1 reads NEAR, ring 2 FAR, any ring ONE.
local function watched(cell, variant)
    local interest = R.interest
    local subscribers = interest and interest.subscribers
    if not subscribers then return true end
    local subs = subscribers(cell.bucket, cell.grid, cell.key)
    if type(subs) ~= 'table' then return false end
    if variant == ONE then return next(subs) ~= nil end
    for _, ring in pairs(subs) do
        if ring == variant then return true end
    end
    return false
end

local function varFor(bucket, grid, key, slot)
    local var = varOf(getCell(bucket, grid, key, true), slot)
    if var.egen ~= gen then
        var.egen, var.np, var.nops = gen, 0, 0
        var.skip = not watched(var.cell, slot)
        finN = finN + 1
        finVars[finN] = var
    end
    return var
end

local function depsChanged(rec)
    if rec.fdeps then return true end
    if not (rec.fset or rec.fput) then return false end
    local cur, old = rec.node.deps, rec.pDeps
    local nc = type(cur) == 'table' and #cur or 0
    if nc ~= (old and #old or 0) then return true end
    for i = 1, nc do
        if cur[i] ~= old[i] then return true end
    end
    return false
end

--- How many kinds of change of `rec` reach one variant (`far`: near-only field sets do not), and the kind when
--- it is exactly one.
local function pending(rec, far, dch)
    local n, one = 0, nil
    if rec.finter or dch or (far and rec.fsetFar) or (not far and rec.fset and next(rec.fset)) then
        n, one = 1, 'set'
    end
    if rec.fmove then n, one = n + 1, 'move' end
    if rec.fmotion then n, one = n + 1, 'motion' end
    if rec.fpromo then n, one = n + 1, rec.fpromo end
    return n, one
end

--- `rec`'s op for one variant it is in: a PUT when it is new there, re-sent or changed in several ways, else its
--- single SET / MOVE / MOTION / PROMOTE / DEMOTE. Dependencies' PUTs go first (once per entry).
local function emitIn(rec, bucket, grid, key, slot, here, full, dch)
    local var = varFor(bucket, grid, key, slot)
    local far, n, one = slot == FAR, 0, nil
    if here and not full then
        n, one = pending(rec, far, dch)
        if n == 0 then return end
    end
    var.nops = var.nops + 1
    if var.skip then return end
    local node, op = rec.node, nil
    if n ~= 1 then
        op = encodePut(node, far, false, (rec.nk or 0) > 0)
        if op then emitDeps(var, var.depMark, node, far, drainMark) end
    elseif one == 'set' then
        op = encodeSet(rec, far, dch)
        if op and dch then emitDeps(var, var.depMark, node, far, drainMark) end
    else
        op = encodeOne(rec, one)
    end
    if op then add(var, op) end
end

local function emitDel(bucket, grid, key, slot, node, how)
    local var = varFor(bucket, grid, key, slot)
    if how == DEL_HANDOVER then counters.handovers = counters.handovers + 1 end
    var.nops = var.nops + 1
    if var.skip then return end
    local ok, op = pcall(Codec.del, node.id, verOf(node), how)
    if ok then add(var, op) else fail(node.id, op) end
end

--- One gated item from the ops in PB: `node` = the unit head (its effective audience and its root's cell decide
--- the targets; for a DEL the head the node was PUBLISHED under), `id` = the node the ops are about, `n` = the exact
--- op count of `blob`, `public` = it left the private channel for its cell's public content.
local function gatedItem(rec, op, public, id, head)
    local n = PB.np
    if n == 0 then return end
    local h = head or (rec.t == 'kid' and rec.root) or rec
    gatedN = gatedN + 1
    gatedOut[gatedN] = { node = h.node, id = id or rec.id, op = op, blob = concat(PB.parts, '', 2, n + 1), n = n,
        public = public or nil }
    clearParts(PB)
    counters.gatedOps = counters.gatedOps + n
end

--- The private side of `rec`: 'put' when it enters its unit (or moved / changed unit / is re-sent; dependencies
--- first), 'set' with its single change, 'del' when it leaves (removed, or public now).
local function gatedOps(rec, bucket, same, gt, full, dch, wasGated, head)
    local node = rec.node
    if not gt then
        local ok, op = pcall(Codec.del, node.id, verOf(node), bucket ~= nil and DEL_HANDOVER or rec.fdel or DEL_NORMAL)
        if not ok then return fail(node.id, op) end
        add(PB, op)
        return gatedItem(rec, 'del', bucket ~= nil, nil, rec.ph)
    end
    local n, one = 0, nil
    if wasGated and same and not full and rec.ph == head then
        n, one = pending(rec, false, dch)
        if n == 0 then return end
    end
    local op
    if n ~= 1 then op = encodePut(node, false, true, (rec.nk or 0) > 0)
    elseif one == 'set' then op = encodeSet(rec, false, dch)
    else op = encodeOne(rec, one) end
    if not op then return end
    if n ~= 1 or dch then
        mark = mark + 1
        emitDeps(PB, GM, node, false, mark)
    end
    if n ~= 1 then rec.gpGen = gen end
    add(PB, op)
    gatedItem(rec, n ~= 1 and 'put' or 'set', nil, nil, head)
end

local function copyList(t)
    if type(t) ~= 'table' or #t == 0 then return nil end
    return table.move(t, 1, #t, 1, {})
end

--- Emits `rec`'s coalesced ops into the variants it left (DEL), entered (PUT) or stayed in (its change), plus its
--- gated items, and records the new placement as published. @return boolean its placement changed
--- (Published state, compact: pb = bucket | nil, pk = grid * GRID_SPAN + key, pf = 1 NEAR | 2 FAR | 4 ONE | 8 gated,
--- ph = the unit head it was published under while gated.)
local function processRec(rec, force)
    local node = rec.node
    local b, g, k, inN, inF, inO, gt, head = placement(rec)
    local nf = (inN and 1 or 0) | (inF and 2 or 0) | (inO and 4 or 0) | (gt and 8 or 0)
    local gk = b ~= nil and g * GRID_SPAN + k or nil
    local pb, pgk, pf = rec.pb, rec.pk, rec.pf or 0
    local same = pb ~= nil and b == pb and gk == pgk
    local dch = depsChanged(rec)
    local full = rec.fput or force
    if pb ~= nil then
        local pg, pk = pgk // GRID_SPAN, pgk % GRID_SPAN
        local how = DEL_NORMAL                                  -- a bucket change, or a variant lost in place
        if rec.removed or b == nil then how = rec.fdel or DEL_NORMAL
        elseif b == pb and (not same or gt) then how = DEL_HANDOVER end   -- another cell / grid, or private now
        if pf & 1 ~= 0 and not (same and inN) then emitDel(pb, pg, pk, NEAR, node, how) end
        if pf & 2 ~= 0 and not (same and inF) then emitDel(pb, pg, pk, FAR, node, how) end
        if pf & 4 ~= 0 and not (same and inO) then emitDel(pb, pg, pk, ONE, node, how) end
    end
    if inN then emitIn(rec, b, g, k, NEAR, same and pf & 1 ~= 0, full, dch) end
    if inF then emitIn(rec, b, g, k, FAR, same and pf & 2 ~= 0, full, dch) end
    if inO then emitIn(rec, b, g, k, ONE, same and pf & 4 ~= 0, full, dch) end
    if gt or pf & 8 ~= 0 then gatedOps(rec, b, same, gt, full, dch, pf & 8 ~= 0, head) end
    local changed = not same or pf ~= nf
    if dch or full or changed then rec.pDeps = copyList(node.deps) end
    rec.pb, rec.pk, rec.pf, rec.ph = b, gk, nf, gt and head or nil
    return changed
end

local function depOp(dep, far)
    local node = dep.node
    if dep.removed then
        local ok, op = pcall(Codec.del, node.id, verOf(node), dep.fdel or DEL_NORMAL)
        if ok then return op end
        return fail(node.id, op)
    end
    if dep.fput or dep.fmove or dep.fmotion or dep.fpromo or dep.finter or dep.fdeps then
        return encodePut(node, far, false, false)
    end
    return encodeSet(dep, far, false)
end

--- A dependency's SET / DEL / re-PUT into every variant holding one of its dependents (once per entry: an entry
--- whose new dependent already carried the dependency's PUT gets nothing more), gated dependents as items.
local function depPhase(dep)
    local store = R.store
    local users = store and store.dependents and store.dependents(dep.id)
    if type(users) ~= 'table' then return end
    for uid in pairs(users) do
        local ur = recs[uid]
        local b, g, k, inN, inF, inO, gt, head
        if ur and not ur.removed then b, g, k, inN, inF, inO, gt, head = placement(ur) end
        if b and gt then
            if ur.gpGen ~= gen then
                local op = depOp(dep, false)
                if op then
                    add(PB, op)
                    gatedItem(ur, dep.removed and 'del' or 'set', nil, dep.id, head)
                end
            end
        elseif b then
            for slot = NEAR, ONE do
                if (slot == NEAR and inN) or (slot == FAR and inF) or (slot == ONE and inO) then
                    local var = varFor(b, g, k, slot)
                    if var.depMark[dep.id] ~= drainMark then
                        var.depMark[dep.id] = drainMark
                        var.nops = var.nops + 1
                        local op = not var.skip and depOp(dep, slot == FAR)
                        if op then add(var, op) end
                    end
                end
            end
        end
    end
end

--- CELL header(s) + ops (parts[1] is the header slot: one concat). A section counts its ops in a u16: more than
--- 65,535 ops are cut into chained sections through intermediate versions (fresh numbers, the chain stays unique).
local function sections(grid, key, variant, from, to, parts, n)
    if n <= MAX_OPS then
        parts[1] = Codec.cell(grid, key, variant, from, to, n)
        local blob = concat(parts, '', 1, n + 1)
        parts[1] = nil
        return blob
    end
    local out, o, i, cur = {}, 0, 1, from
    while i <= n do
        local j = min(n, i + MAX_OPS - 1)
        local nxt = j == n and to or nextSeq()
        out[o + 1], out[o + 2] = Codec.cell(grid, key, variant, cur, nxt, j - i + 1), concat(parts, '', i + 1, j + 1)
        o, cur, i = o + 2, nxt, j + 1
    end
    return concat(out, '', 1, o)
end

--- Drops journal entries beyond JournalOps or older than JournalMs (`maxN` / `maxMs`: read once per drain).
local function journalTrim(var, now, maxN, maxMs)
    local j = var.j
    if not j then return end
    maxN, maxMs = maxN or journalOps(), maxMs or journalMs()
    while #j > 0 and (#j > maxN or now - j[1].at > maxMs or now < j[1].at) do tremove(j, 1) end
end

--- Closes a variant's tick: one entry from its last drained version to the current one (nothing when the version
--- did not move; the version goes back when the changes cancelled out and nobody saw the new number).
local function finalize(var, now, maxN, maxMs, limit)
    if var.fgen == gen then return end
    var.fgen = gen
    local cell, mine = var.cell, var.egen == gen
    local np, nops = mine and var.np or 0, mine and var.nops or 0
    local from, to = var.drained, countOf(var) == 0 and 0 or var.v
    if to ~= 0 and to == from and nops > 0 then to = nextSeq() end   -- ops without a touch: still a new version
    if to ~= from and to ~= 0 and nops == 0 and not var.seen and from ~= 0 then to = from end   -- cancelled, unseen
    var.v, var.seen = to, nil
    if to ~= from then
        local skip = (mine and var.skip) or (not mine and not watched(cell, var.variant))
        local ok, blob = not skip, nil
        if ok then ok, blob = pcall(sections, cell.grid, cell.key, var.variant, from, to, var.parts, np) end
        if ok then
            local entry = { bucket = cell.bucket, grid = cell.grid, key = cell.key, variant = var.variant,
                from = from, to = to, blob = blob, n = np, at = now, big = #blob > limit or nil }
            local j = var.j or {}
            var.j = j
            j[#j + 1] = entry
            journalTrim(var, now, maxN, maxMs)
            outN = outN + 1
            outEntries[outN] = entry
            counters.entries, counters.entryBytes = counters.entries + 1, counters.entryBytes + #blob
        else   -- nobody to send to (or an encode error): a gap, so since() answers nil until the journal restarts
            if skip then counters.skipped = counters.skipped + 1 else fail(nil, blob) end
            var.j = nil
        end
        var.drained, var.observed = to, true
    end
    clearParts(var)
    var.nops = 0
end

local function drainKid(kid, force)
    kid.pgen = gen
    processRec(kid, force and not kid.removed)
    return false
end

--- This tick's work: entries (every changed, watched variant), gated items, C4 events and C2 DRs. The four arrays
--- are reused: valid until the next drain(). entries = { bucket, grid, key, variant, from, to, blob, n, at, big? };
--- gated = { node (unit head), id, op = 'put'|'set'|'del', blob (ops, no header), n, public? };
--- events = { bucket, grid, key, x, y, z, radius, horizonMs, t, blob, node?, gate? }; drs = { node, blob, gate? }.
function Index.drain()
    for i = 1, outN do outEntries[i] = nil end
    for i = 1, gatedN do gatedOut[i] = nil end
    outN, gatedN = 0, 0
    outEvents, pendEvents = pendEvents, outEvents
    for i = #pendEvents, 1, -1 do pendEvents[i] = nil end
    local drs, kept = pendDrs, 0
    pendDrs, outDrs = outDrs, drs
    for i = #pendDrs, 1, -1 do pendDrs[i] = nil end
    for i = 1, #drs do                                 -- DRs of nodes removed this tick go
        local d = drs[i]
        local rec = recs[d.node.id]
        drs[i] = nil
        if rec and not rec.removed then
            kept = kept + 1
            drs[kept] = d
        end
    end
    mark = mark + 1
    drainMark = mark
    local now = GetGameTimer()
    for i = 1, dirtyN do                               -- groups: every dirty root; a dirty child queues on its root
        local rec = dirtyList[i]
        if rec.t == 'dep' then
            depN = depN + 1
            depList[depN] = rec
        else
            local root = rec.t == 'kid' and rec.root or rec
            if root.ggen ~= gen then
                root.ggen = gen
                groupN = groupN + 1
                groups[groupN] = root
            end
            if root ~= rec then
                local q = root.dq
                if not q then
                    q = {}
                    root.dq = q
                end
                q[#q + 1] = rec
            end
        end
    end
    for i = 1, groupN do                               -- a root, then its children parent first (O(subtree))
        local root = groups[i]
        groups[i] = nil
        root.pgen = gen
        local changed = processRec(root, false)
        if root.t == 'root' and (changed or root.fput) then walk(root, drainKid, true) end
        local q = root.dq
        local n = q and #q or 0
        if n > 0 then
            for d = 1, MAX_DEPTH + 1 do                -- the dirty children not walked, by depth (parent first)
                for j = 1, n do
                    local kid = q[j]
                    if kid.pgen ~= gen and (d > MAX_DEPTH or kid.depth == d) then
                        kid.pgen = gen
                        processRec(kid, false)
                    end
                end
            end
            for j = 1, n do q[j] = nil end
        end
    end
    for i = 1, depN do
        depPhase(depList[i])
        depList[i] = nil
    end
    local maxN, maxMs = journalOps(), journalMs()
    local limit = num(sceneCfg().MaxEventBytes, 16384, 256, 1e9)
    for i = 1, dirtyVarN do finalize(dirtyVars[i], now, maxN, maxMs, limit) end
    for i = 1, finN do finalize(finVars[i], now, maxN, maxMs, limit) end
    for i = 1, dirtyN do
        local rec = dirtyList[i]
        dirtyList[i] = nil
        rec.fput, rec.fset, rec.fsetFar, rec.finter, rec.fdeps = nil, nil, nil, nil, nil
        rec.fmove, rec.fmotion, rec.fpromo, rec.netId = nil, nil, nil, nil
        if rec.removed and recs[rec.id] == rec then
            recs[rec.id], failed[rec.id], drByNode[rec.id] = nil, nil, nil
        end
    end
    for i = 1, dirtyVarN do
        dropIfEmpty(dirtyVars[i].cell)
        dirtyVars[i] = nil
    end
    for i = 1, finN do
        dropIfEmpty(finVars[i].cell)
        finVars[i] = nil
    end
    for i = 1, emptiedN do
        dropIfEmpty(emptied[i])
        emptied[i] = nil
    end
    dirtyN, dirtyVarN, finN, groupN, depN, emptiedN = 0, 0, 0, 0, 0, 0
    gen, woken = gen + 1, false
    counters.drains = counters.drains + 1
    return outEntries, gatedOut, outEvents, outDrs
end

--- True while a drain would have something to do (changed nodes or variants, events, DRs): the flush sleeps
--- without polling otherwise (R.flush.wake() tells it when this turns true).
function Index.pending()
    return dirtyN > 0 or dirtyVarN > 0 or #pendEvents > 0 or #pendDrs > 0
end

--------------------------------------------------------------------------------
-- Reads (scene_interest.lua, scene_flush.lua, scene_gated.lua, scene.lua)
--------------------------------------------------------------------------------

local VARIANTS <const> = { [0] = { [NEAR] = true, [FAR] = true }, { [ONE] = true }, { [ONE] = true } }
local SCRATCH = {}

--- The cell of (bucket, grid, key) when the arguments name one and it exists.
local function cellAt(bucket, grid, key)
    if not VARIANTS[grid] or mathType(key) ~= 'integer' or mathType(bucket) ~= 'integer' then return nil end
    return getCell(bucket, grid, key, false)
end

local function lookup(bucket, grid, key, variant)
    local cell = cellAt(bucket, grid, key)
    return cell and VARIANTS[grid][variant] and cell[variant] or nil
end

local PK_marks, PK_far, PK_gated = nil, false, false
--- walk() callback of buildTree: one node of the unit (a nested gate head starts a unit of its own: skipped with
--- its subtree; a node whose parent could not be encoded goes with it).
local function packKid(kid)
    if kid.removed or kid.node.audience ~= nil then return true end
    local up = kid.up
    if not up or up.pmark ~= mark then return true end
    local op = encodePut(kid.node, PK_far, PK_gated, (kid.nk or 0) > 0)
    if not op then return true end
    emitDeps(PB, PK_marks, kid.node, PK_far, mark)
    add(PB, op)
    kid.pmark = mark
    return false
end

--- A unit's PUTs into PB: its head, then its subtree parent first (dependencies before their first dependent).
--- For a public root that excludes every gated child unit (F1); O(subtree). Uses the current `mark`.
local function buildTree(head, marks, far, gated)
    local op = encodePut(head.node, far, gated, (head.nk or 0) > 0)
    if not op then return end
    emitDeps(PB, marks, head.node, far, mark)
    add(PB, op)
    head.pmark = mark
    if not head.dk then return end
    PK_marks, PK_far, PK_gated = marks, far, gated
    walk(head, packKid)
    PK_marks = nil
end

--- The bare ops in PB (no CELL header) and their count; PB is emptied.
local function takePB()
    local n = PB.np
    local blob = concat(PB.parts, '', 2, n + 1)
    clearParts(PB)
    return blob, n
end

--- The snapshot of a variant: CELL(from 0) .. PUT… (public roots + their public subtrees, dependencies before their
--- first dependent), built on the first request after a change and cached. @return string blob, integer v ('' , 0)
function Index.pack(bucket, grid, key, variant)
    local var = lookup(bucket, grid, key, variant)
    if not var or countOf(var) == 0 then return '', 0 end
    if var.v == 0 then var.v = nextSeq() end
    var.observed = true
    if var.v ~= var.drained then var.seen = true end
    if var.pack and var.packV == var.v then return var.pack, var.v end
    mark = mark + 1
    clearParts(PB)
    local far = variant == FAR
    for _, root in pairs(var.cell.roots) do
        if not far or root.isM then buildTree(root, var.depMark, far, false) end
    end
    local ok, blob = pcall(sections, grid, key, variant, 0, var.v, PB.parts, PB.np)
    clearParts(PB)
    if not ok then
        fail(nil, blob)
        return '', 0
    end
    var.pack, var.packV = blob, var.v
    counters.packBuilds, counters.packBytes = counters.packBuilds + 1, counters.packBytes + #blob
    return blob, var.v
end

--- Everything since version `fromV` as the concatenation of journal entries ('' when `fromV` is the last drained
--- version); nil when the journal does not cover it (the pack serves).
function Index.since(bucket, grid, key, variant, fromV)
    if not (VARIANTS[grid] and VARIANTS[grid][variant]) or mathType(fromV) ~= 'integer' then return nil end
    local var = lookup(bucket, grid, key, variant)
    if fromV == (var and var.drained or 0) then return '' end
    if not (var and var.j) then return nil end
    journalTrim(var, GetGameTimer())
    local j = var.j
    for i = 1, #j do
        if j[i].from == fromV then
            local n = #j - i + 1
            if n == 1 then return j[i].blob end
            for m = 1, n do SCRATCH[m] = j[i + m - 1].blob end
            local blob = concat(SCRATCH, '', 1, n)
            for m = 1, n do SCRATCH[m] = nil end
            return blob
        end
    end
    return nil
end

--- The current version of a variant (0 = empty).
function Index.version(bucket, grid, key, variant)
    local var = lookup(bucket, grid, key, variant)
    if not var or countOf(var) == 0 then return 0 end
    if var.v == 0 then var.v = nextSeq() end
    var.observed = true
    if var.v ~= var.drained then var.seen = true end   -- a number of this tick went out: finalize keeps it
    return var.v
end

local function nodesOf(set, out, n, rootsOnly)
    for _, rec in pairs(set) do
        if not rootsOnly or rec.t == 'root' then
            n = n + 1
            out[n] = rec.node
        end
    end
    return n
end

--- The gate heads of a cell (a fresh array): gated roots and child heads (F1).
function Index.gatedIn(bucket, grid, key)
    local cell, out = cellAt(bucket, grid, key), {}
    if cell then nodesOf(cell.gated, out, 0, false) end
    return out
end

--- Every ROOT of a cell, public and gated (a fresh array): promote proximity scans, Scene.query.
function Index.nodesIn(bucket, grid, key)
    local cell, out = cellAt(bucket, grid, key), {}
    if cell then nodesOf(cell.gated, out, nodesOf(cell.roots, out, 0, true), true) end
    return out
end

--- The PRIV-ready PUT ops of one gate head for a new audience member: its dependencies, its own PUT (GATED), its
--- unit's subtree (nested heads excluded: units of their own). @return string blob, integer n ('' , 0 when the
--- node is not an indexed gate head any more)
function Index.gatedPut(node)
    local rec = type(node) == 'table' and recs[node.id]
    if not rec or rec.removed then return '', 0 end
    local head = (rec.t == 'root' and rec.gated and rec.cell) or (rec.t == 'kid' and rec.hroot and rec.hroot.cell)
    if not head then return '', 0 end
    mark = mark + 1
    clearParts(PB)
    buildTree(rec, GM, false, true)
    return takePB()
end

--- Keys of the cells of `grid` (default 0) with content whose square comes within `radius` of (x, y).
function Index.cellsNear(bucket, x, y, radius, grid)
    grid = grid or 0
    local out, n = {}, 0
    local byKey = mathType(bucket) == 'integer' and cells[bucket]
    if not byKey or not VARIANTS[grid] or not (isFinite(x) and isFinite(y)) then return out end
    if grid == 2 then
        local cell = byKey[2 * GRID_SPAN]
        if cell and (cell.nRoots > 0 or cell.nGated > 0) then out[1] = 0 end
        return out
    end
    local r = num(radius, 0, 0, 1e6)
    local size, r2 = grid == 1 and REGION_SIZE or CELL_SIZE, r * r
    local cx0, cx1, cy0, cy1 = axis(x - r, size), axis(x + r, size), axis(y - r, size), axis(y + r, size)
    local function near(cell, cx, cy)
        if not cell or (cell.nRoots == 0 and cell.nGated == 0) then return end
        if cx < cx0 or cx > cx1 or cy < cy0 or cy > cy1 then return end
        local dx = max(cx * size - x, x - (cx + 1) * size, 0)
        local dy = max(cy * size - y, y - (cy + 1) * size, 0)
        if dx * dx + dy * dy <= r2 then
            n = n + 1
            out[n] = cell.key
        end
    end
    if (cx1 - cx0 + 1) * (cy1 - cy0 + 1) <= 4096 then   -- walk the square, or the bucket's cells when smaller
        for cx = cx0, cx1 do
            for cy = cy0, cy1 do
                near(byKey[grid * GRID_SPAN + (cx + KEY_OFFSET) * KEY_SPAN + cy + KEY_OFFSET], cx, cy)
            end
        end
    else
        for _, cell in pairs(byKey) do
            if cell.grid == grid then near(cell, cell.key // KEY_SPAN - KEY_OFFSET, cell.key % KEY_SPAN - KEY_OFFSET) end
        end
    end
    return out
end

--- The key of (x, y) on `grid` (0 near, 1 far, 2 global = 0); nil for bad input.
function Index.keyOf(grid, x, y)
    if not VARIANTS[grid] then return nil end
    if grid == 2 then return 0 end
    if not (isFinite(x) and isFinite(y)) then return nil end
    return keyOf(grid, x, y)
end

--- Counters: current sizes (cells, roots by tier, record kinds, gate heads, swept / parked movers, riders = players
--- with attached roots and riding = those roots, journals, cached packs) and totals since start (pack builds and
--- bytes, entries and bytes, drains, gated ops, events, DRs, encode errors, re-cells, handovers, skipped entries, op
--- cache hits / builds, ridePasses = rider groups re-placed); `version` = the counter.
function Index.stats()
    local out = { cells = nCells, nodes = { S = byTier.S, M = byTier.M, L = byTier.L, G = byTier.G }, roots = 0,
        kids = 0, deps = 0, gated = 0, heads = 0, movers = moverN, parked = parkedN, heap = heapN, riders = RIDE.n,
        riding = 0, moverThread = moverThread, journalEntries = 0, journalBytes = 0, packsCached = 0,
        packCacheBytes = 0, version = seq, cellSize = CELL_SIZE, regionSize = REGION_SIZE }
    for i = 1, RIDE.n do out.riding = out.riding + RIDE.list[i].nrec end
    for name, value in pairs(counters) do out[name] = value end
    for _, rec in pairs(recs) do
        local t = rec.t
        if t == 'root' then
            out.roots = out.roots + 1
            if rec.gated then out.gated = out.gated + 1 end
        elseif t == 'kid' then
            out.kids = out.kids + 1
            if rec.hroot then out.heads = out.heads + 1 end
        elseif t == 'dep' then out.deps = out.deps + 1 end
    end
    for _, byKey in pairs(cells) do
        for _, cell in pairs(byKey) do
            for v = NEAR, ONE do
                local var = cell[v]
                if var and var.pack and var.packV == var.v then
                    out.packsCached, out.packCacheBytes = out.packsCached + 1, out.packCacheBytes + #var.pack
                end
                local j = var and var.j
                if j then
                    out.journalEntries = out.journalEntries + #j
                    for i = 1, #j do out.journalBytes = out.journalBytes + #j[i].blob end
                end
            end
        end
    end
    return out
end
