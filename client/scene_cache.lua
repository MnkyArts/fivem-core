--[[ core — client/scene_cache.lua — Core.Scene's client cache (DESIGN §55.10; wire format §55.8)
     FIRST of the client scene files: it creates the one-shot global `CoreSceneRuntime` (C) with C.codec,
     C.motion and C.cache; client/scene_focus.lua (right after this file: the focus reporter, resync requests,
     bucket changes), the materialiser, kinds, fx and movers add theirs; client/scene.lua (the LAST one) adds the
     public API and clears the global, so nothing internal is reachable through the `call` export (§52).

     Receive: `core:scene:s` (one reliable payload per server tick) and `core:scene:p` (latent packs, unordered)
     are decoded with Core.SceneCodec in the event handler, never per frame; a payload above 16 KiB (and whatever
     arrives while one is in work) goes to a worker thread that applies 256 node ops per frame, in stream order.
     Per cell { grid, key, variant (subscribed), cv / v (the cached content's variant and version), target, state
     = pending|live|lru, nodes }; per node the decoded record and its `ver`:
       * CELL from = 0 replaces the cell's content (a node another cell holds stays), from = v applies, to ≤ v
         is old news; anything else is a gap: the entry and what follows are kept until the content lands, and
         a live cell asks for it (C.focus.requestResync: throttled, deferred — never dropped — within 2 s).
       * A pending cell (SUB seen, content in flight) keeps its journal entries the same way; a latent snapshot
         stamped before the cell's SUB belongs to an older subscription and is ignored, one that comes BEFORE its
         SUB is parked (≤ 3 s, 16 packs) and applied when the SUB arrives.
       * A SUB at the version the cell holds (a held LRU cell, a ring change back) is live at once.
       * A node op whose ver is not newer than the node's changes nothing but cell membership — except a near PUT
         for a record that came from the far variant (its near fields); DEL(handover) keeps the node for a PUT of
         the same id later in the payload (the entity survives the cell change). Node vers (per node) and cell
         versions are u32 that wrap 4294967295 -> 1: every comparison is wrap-aware (vdiff), never < / <=.
       * RESET (the server dropped every subscription: a bucket change it detected, a restart) drops everything,
         LRU and parked packs included, and has the focus reporter report at once.
       * The materialiser (C.mat, looked up at call time: scene_materializer.lua loads after this file) knows
         exactly the WANTED nodes — in a subscribed cell or gated-and-present, kind known and handled, parent
         here: add = entered that set, remove = left it (or the cache; a subtree root first, then its children,
         links intact), update(node, what, data) once per payload for what changed, event(...) after the node work.
       * Dependency nodes (§55.16 audio sources, INTERFACES §7) are ref-counted by their dependents and never
         reach C.mat; a change of one is an update(node, 'dep') of every dependent.
     LRU: an UNSUBbed cell keeps its nodes (unwanted) for ClientLruMs, at most ClientLruCells cells; the focus
     report lists their versions (Cache.lru) so a return costs a journal, not a pack. Cache.housekeep(t) (called
     by the focus thread) expires them, and parked packs, and re-asks for subscriptions whose content never came.

     Natives (fxref 2026-09-26, apiset client): GetGameTimer().
     Runtime helpers: RegisterNetEvent, AddEventHandler, CreateThread, Wait.
]]

local Codec = Core.SceneCodec
assert(type(Codec) == 'table' and type(Codec.decode) == 'function',
    'client/scene_cache.lua needs shared/scene_codec.lua (fxmanifest shared_scripts) first')
local Log, Clock = Core.Log, Core.Clock
local floor, mtype, tointeger = math.floor, math.type, math.tointeger

local C = { codec = Codec, motion = Core.SceneMotion }
local Cache = {}
C.cache = Cache

local cfg = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
local function setting(value, default, low, high)
    value = tonumber(value) or default
    if value ~= value or value < low then return low end
    return value > high and high or value
end

local CELL_SIZE <const> = setting(cfg.CellSize, 128, 8, 8192)       -- read once: the key encoding (§55.5)
local REGION_SIZE <const> = setting(cfg.RegionSize, 512, 16, 32768)
local LRU_CELLS <const> = floor(setting(cfg.ClientLruCells, 48, 0, 1024))
local LRU_MS <const> = floor(setting(cfg.ClientLruMs, 120000, 0, 3600000))

local PENDING_MS <const> = 15000         -- a subscription whose content never came asks again
local LATENT_SLACK_MS <const> = 25       -- a latent snapshot stamped this long before its SUB is an older one
local BUFFER_MAX_OPS <const> = 4096      -- per pending cell; beyond it the entries go (a later gap resyncs)
local PARK_MS <const>, PARK_MAX <const>, PARK_OPS <const> = 3000, 16, 8192   -- latent packs ahead of their SUB
local CHUNK_OPS <const> = 256            -- node ops per frame while the worker takes a big payload apart
local BIG_BYTES <const> = 16384          -- payloads above this (latent packs, merged backlogs) go to the worker
local MAX_PAYLOAD <const> = 8 * 1024 * 1024
local MAX_ID <const> = 0x7FFFFFFF
local WARN_EVERY_MS <const> = 60000

local PENDING <const>, LIVE <const>, LRU <const> = 1, 2, 3
local STATE_NAME <const> = { 'pending', 'live', 'lru' }
local DEL_NORMAL <const>, DEL_HANDOVER <const> = 0, 1
local DEL_WORLD <const> = 3              -- client-side only: a bucket reset — the materialiser deletes at once (RV6 F3)
local F_PROMOTED <const>, F_FAR <const>, F_GATED <const> = 2, 8, 32
local GRID_NEAR <const>, GRID_FAR <const>, GRID_GLOBAL <const> = 0, 1, 2
local SKIP <const>, APPLY <const>, SNAPSHOT <const>, BUFFER <const>, PARK <const> = 0, 1, 2, 3, 4
local OP_PUT <const>, OP_SET <const>, OP_MOVE <const>, OP_MOTION <const> = 1, 2, 3, 4
local OP_DEL <const>, OP_PROMOTE <const>, OP_DEMOTE <const> = 5, 6, 7

-- What changed on a node since the materialiser last heard of it: one bit per C.mat.update `what`.
local B_FIELDS <const>, B_MOVE <const>, B_MOTION <const>, B_INTERACT <const> = 1, 2, 4, 8
local B_ATTACH <const>, B_KIND <const>, B_PROMOTE <const>, B_DEMOTE <const> = 16, 32, 64, 128
local B_DR <const>, B_DEP <const>, B_RADIUS <const>, B_WANTED <const> = 256, 512, 1024, 2048
-- a re-create (kind changed) reads the whole node again: these need no call of their own
local B_SUBSUMED <const> = B_FIELDS | B_MOVE | B_MOTION | B_INTERACT | B_ATTACH | B_RADIUS | B_DR | B_DEP
-- the order C.mat.update hears them in
local WHATS <const> = {
    { B_FIELDS, 'fields' }, { B_RADIUS, 'radius' }, { B_ATTACH, 'attach' }, { B_MOVE, 'move' },
    { B_MOTION, 'motion' }, { B_DR, 'dr' }, { B_INTERACT, 'interact' }, { B_DEP, 'dep' },
}
Cache.BITS = { fields = B_FIELDS, move = B_MOVE, motion = B_MOTION, interact = B_INTERACT, attach = B_ATTACH,
    kind = B_KIND, promote = B_PROMOTE, demote = B_DEMOTE, dr = B_DR, dep = B_DEP, radius = B_RADIUS }
Cache.WHATS = WHATS

local EMPTY <const> = setmetatable({}, { __newindex = function() error('read-only', 2) end })
local PRIV_SEC <const> = {}              -- the target of a node op of a PRIV section (gated nodes)

local cells, nCells = {}, 0              -- cell key (grid * 2^32 + key) -> cell
local counts = { 0, 0, 0 }               -- cells per state
local nodes, nNodes = {}, 0              -- id -> node
local nPriv = 0                          -- gated nodes present
local kindsByIdx, kindsById, nKinds = {}, {}, 0
local claims = {}                        -- plugin kind id -> the resource that handles it (client/scene.lua)
local lru = {}                           -- cells in the LRU, oldest first
local dependents, depCount = {}, {}      -- dependency id -> { [node id] = true }, number of them
local orphans = {}                       -- parent id -> { child ids } (children that came before their parent)
local touched, nTouched = {}, 0          -- nodes with materialiser work pending (this payload)
local events, nEvents = {}, 0            -- EVENT ops of this payload, delivered after the node work
local gcDeps, nGc = {}, 0                -- dependency ids to check at the payload's end
local flushing, stopped = false, false
local stats = { payloads = 0, latent = 0, bytesIn = 0, decodeErrors = 0, gaps = 0, stale = 0,
    buffered = 0, bufferDropped = 0, parked = 0, unparked = 0, resets = 0, chunks = 0, events = 0, ops = 0 }
local parked, nParked, parkedOps = {}, 0, 0   -- park key -> a latent snapshot that came before its SUB (RV2 F6)
local chunking, chunkOps, payloadActive = false, 0, false  -- the worker's big payload (F17); a payload is open
local warnedAt = -WARN_EVERY_MS

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function ckey(grid, key) return grid * 4294967296 + key end

--- a - b for u32 versions, which wrap 4294967295 -> 1 and are never 0 (RV1 F6): > 0 = a is newer. Node vers
--- (per node) and cell versions (one server counter) are only ever compared through these, never with < / <=.
local function vdiff(a, b) return (a - b + 2147483648) % 4294967296 - 2147483648 end
--- `to` is newer than `base` (0 = no content: anything is newer).
local function vnewer(to, base) return base == 0 or vdiff(to, base) > 0 end
--- `v` reached `target` (0 = nothing announced).
local function vreached(v, target) return target == 0 or (v ~= 0 and vdiff(v, target) >= 0) end

--- The grid key of a world point (the server's R.index.keyOf encoding, §55.5).
local function keyOf(x, y, size) return (floor(x / size) + 32768) * 65536 + (floor(y / size) + 32768) end

--- Deep equality of decoded values (fields, motion, interact); tables compared up to 8 levels.
local function same(a, b, depth)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' or depth > 8 then return false end
    for k, v in pairs(a) do
        if not same(v, b[k], depth + 1) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

local function tableOrNil(v) return type(v) == 'table' and v or nil end

local function warn(fmt, ...)
    local t = GetGameTimer()
    if t - warnedAt < WARN_EVERY_MS then return end
    warnedAt = t
    Log.warn('scene: ' .. fmt, ...)
end

--- Queues materialiser work for `node` (bits of what changed), delivered by flush() at the payload's end.
local function touch(node, bits)
    node.pend = node.pend | bits
    if not node.touched then
        node.touched = true
        nTouched = nTouched + 1
        touched[nTouched] = node
    end
end

local function newNode(id)
    local node = { id = id, kindIdx = 0, kind = nil, ver = 0, parent = 0, flags = 0,
        x = 0.0, y = 0.0, z = 0.0, rx = 0.0, ry = 0.0, rz = 0.0, radius = 0, fields = EMPTY,
        children = {}, gated = false, cellRef = nil,
        refs = 0, priv = false, dependency = false, pend = 0, touched = false, added = false, seen = false }
    nodes[id] = node
    nNodes = nNodes + 1
    return node
end

--- The node is wanted: in a subscribed cell or gated-and-present, its kind known (and handled), its parent here.
local function wanted(node)
    if node.gone or node.dependency then return false end
    local k = node.kind
    if not k or k.ready == false then return false end
    if node.parent ~= 0 and nodes[node.parent] == nil then return false end
    if node.priv then return true end
    local c = node.cellRef
    return c ~= nil and c.state ~= LRU
end

local function isDependencyKind(k)
    if not k then return false end
    local meta = k.meta
    return (type(meta) == 'table' and (meta.dependency == true or meta.dep == true)) or k.id == 'audio.source'
end

--- Nothing keeps the node any more: no cell, no PRIV section — or, for a dependency, no dependent.
local function unheld(node)
    if node.dependency then return depCount[node.id] == nil end
    return node.refs <= 0 and not node.priv
end

--------------------------------------------------------------------------------
-- cell membership (a node may sit in two cells for a moment: a handover, a snapshot racing a journal)
--------------------------------------------------------------------------------

local snapCell, snapOld = nil, nil       -- the cell whose snapshot is being applied, and its previous node set

--- Another cell that holds the node, a subscribed one first (only for nodes held by several cells: rare).
local function otherCell(node, except)
    if node.refs <= 0 then return nil end
    local id, fallback = node.id, nil
    for _, c in pairs(cells) do
        if c ~= except and c.nodes[id] then
            if c.state ~= LRU then return c end
            fallback = fallback or c
        end
    end
    return fallback
end

local function addMember(node, cell)
    local id, set = node.id, cell.nodes
    if not set[id] then
        set[id] = true
        cell.n = cell.n + 1
        if cell == snapCell and snapOld[id] then
            snapOld[id] = nil                -- held before the snapshot too: the same reference
        else
            node.refs = node.refs + 1
        end
    end
    local ref = node.cellRef
    if ref ~= cell and (ref == nil or ref.state == LRU or not ref.nodes[id]) then
        node.cellRef = cell
        touch(node, B_WANTED)
    end
end

local function removeMember(node, cell)
    local id = node.id
    if not cell.nodes[id] then return end
    cell.nodes[id] = nil
    cell.n = cell.n - 1
    node.refs = node.refs - 1
    if node.cellRef == cell then
        node.cellRef = otherCell(node, cell)
        touch(node, B_WANTED)
    end
end

--------------------------------------------------------------------------------
-- parents and children (children ride their root: same cell section, created after it)
--------------------------------------------------------------------------------

local function unlinkParent(node)
    local pid = node.parent
    if pid == 0 then return end
    local p = nodes[pid]
    local list = p and p.children or orphans[pid]
    if not list then return end
    for i = #list, 1, -1 do
        if list[i] == node.id then table.remove(list, i) end
    end
    if not p and #list == 0 then orphans[pid] = nil end
end

local function linkParent(node, pid)
    node.parent = pid
    if pid == 0 then return end
    local p = nodes[pid]
    local list = p and p.children
    if not list then
        list = orphans[pid]
        if not list then
            list = {}
            orphans[pid] = list
        end
    end
    list[#list + 1] = node.id
end

--- A parent arrived: the children that came before it are linked to it now (and may be wanted).
local function adoptOrphans(node)
    local list = orphans[node.id]
    if not list then return end
    orphans[node.id] = nil
    local ch = node.children
    for i = 1, #list do
        local child = nodes[list[i]]
        if child and child.parent == node.id then
            ch[#ch + 1] = child.id
            touch(child, B_WANTED | B_ATTACH)
        end
    end
end

--------------------------------------------------------------------------------
-- dependencies (INTERFACES §7): ref-counted by their dependents, never materialised by the cache's callers
--------------------------------------------------------------------------------

local function gcLater(id)
    nGc = nGc + 1
    gcDeps[nGc] = id
end

local function unref(depId, nodeId)
    local set = dependents[depId]
    if not set or not set[nodeId] then return end
    set[nodeId] = nil
    local n = depCount[depId] - 1
    if n > 0 then
        depCount[depId] = n
        return
    end
    dependents[depId], depCount[depId] = nil, nil
    gcLater(depId)
end

local function ref(depId, nodeId)
    local set = dependents[depId]
    if not set then
        set = {}
        dependents[depId], depCount[depId] = set, 0
    end
    if set[nodeId] then return end
    set[nodeId] = true
    depCount[depId] = depCount[depId] + 1
end

--- node.deps = the valid ids of `list` (a fresh array) or nil; the dependents index follows.
local function setDeps(node, list)
    local old = node.deps
    if old then
        for i = 1, #old do unref(old[i], node.id) end
    end
    local deps = nil
    if type(list) == 'table' then
        for i = 1, math.min(#list, 64) do
            local d = tointeger(list[i])
            if d and d > 0 and d <= MAX_ID and d ~= node.id then
                deps = deps or {}
                deps[#deps + 1] = d
                ref(d, node.id)
            end
        end
    end
    node.deps = deps
end

--- A dependency changed or went: every dependent hears it (update 'dep'; the audio handler re-reads it).
local function touchDependents(depId)
    local set = dependents[depId]
    if not set then return end
    for id in pairs(set) do
        local n = nodes[id]
        if n then touch(n, B_DEP) end
    end
end

--------------------------------------------------------------------------------
-- removal
--------------------------------------------------------------------------------

--- The node leaves the cache now; the materialiser hears it at the payload's end (flush). Its children go
--- with it, AFTER it and in tree order (the server sends their DELs too; whichever comes first wins): the flush
--- then calls C.mat.remove(root) before remove(child), each child keeps `parent` and the root keeps its
--- `children` list, so the materialiser retires the subtree with its root (RV2 F3, agreed with A5).
local function dropNode(node, how)
    if node.gone then return end
    local id = node.id
    unlinkParent(node)
    if node.priv then
        node.priv = false
        nPriv = nPriv - 1
    end
    if snapOld and snapOld[id] then
        snapOld[id] = nil
        node.refs = node.refs - 1
    end
    if node.refs > 0 then
        local c = node.cellRef
        if node.refs == 1 and c and c.nodes[id] then
            c.nodes[id], c.n = nil, c.n - 1
        else
            for _, cell in pairs(cells) do
                if cell.nodes[id] then cell.nodes[id], cell.n = nil, cell.n - 1 end
            end
        end
        node.refs = 0
    end
    node.cellRef = nil
    if node.deps then setDeps(node, nil) end
    if node.dependency then touchDependents(id) end
    node.gone, node.goneHow = true, how
    nodes[id] = nil
    nNodes = nNodes - 1
    touch(node, 0)
    local ch = node.children
    for i = 1, #ch do
        local child = nodes[ch[i]]
        if child and child.parent == id then dropNode(child, how) end
    end
end

--- Drops the nodes of `set` (ids -> true) that nothing holds any more, every subtree from its root: a node whose
--- parent goes in the same drop is left to the parent's cascade (RV2 F3: root first, children with it).
local function dropUnheld(set, how)
    how = how or DEL_NORMAL
    for id in pairs(set) do
        local node = nodes[id]
        if node and unheld(node) then
            local p = node.parent ~= 0 and nodes[node.parent] or nil
            if not (p and set[p.id] and unheld(p)) then dropNode(node, how) end
        end
    end
    for id in pairs(set) do                                  -- a child whose root stays (held elsewhere)
        local node = nodes[id]
        if node and unheld(node) then dropNode(node, how) end
    end
end

--------------------------------------------------------------------------------
-- cells: states, LRU, drop
--------------------------------------------------------------------------------

local function lruRemove(cell)
    for i = 1, #lru do
        if lru[i] == cell then
            table.remove(lru, i)
            return
        end
    end
end

--- Changes a cell's state; subscribed <-> LRU flips the wantedness of its nodes.
local function setState(cell, state)
    local was = cell.state
    if was == state then return end
    cell.state = state
    counts[was], counts[state] = counts[was] - 1, counts[state] + 1
    if (was == LRU) == (state == LRU) then return end
    for id in pairs(cell.nodes) do
        local node = nodes[id]
        if node then
            local ref0 = node.cellRef
            if state == LRU then
                if ref0 == cell and node.refs > 1 then node.cellRef = otherCell(node, cell) or cell end
            elseif ref0 ~= cell and (ref0 == nil or ref0.state == LRU) then
                node.cellRef = cell
            end
            touch(node, B_WANTED)
        end
    end
end

--- The cell leaves the cache with every node nothing else holds.
local function dropCell(cell, how)
    if cell.dropped then return end
    if cell.state == LRU then lruRemove(cell) end
    cells[cell.ck] = nil
    nCells = nCells - 1
    counts[cell.state] = counts[cell.state] - 1
    cell.dropped, cell.buf = true, nil
    local set = cell.nodes
    cell.nodes, cell.n = {}, 0
    for id in pairs(set) do                                   -- every membership first ...
        local node = nodes[id]
        if node then
            node.refs = node.refs - 1
            if node.cellRef == cell then
                node.cellRef = otherCell(node, cell)
                touch(node, B_WANTED)
            end
        end
    end
    dropUnheld(set, how)                                      -- ... then the drops (a root takes its children)
end

--- Every node of the cell leaves it (the cell stays): SUB of an empty cell.
local function clearCell(cell)
    local set = cell.nodes
    cell.nodes, cell.n = {}, 0
    for id in pairs(set) do
        local node = nodes[id]
        if node then
            node.refs = node.refs - 1
            if node.cellRef == cell then
                node.cellRef = otherCell(node, cell)
                touch(node, B_WANTED)
            end
        end
    end
    dropUnheld(set)
end

--------------------------------------------------------------------------------
-- kinds (KINDS ops: the per-session index table, §55.3)
--------------------------------------------------------------------------------

--- A plugin (custom) kind is handled only while the resource it names runs its client handler (§55.13).
local function claimOk(k)
    if k.class ~= 'custom' then return true end
    local owner = claims[k.id]
    if not owner then return false end
    local want = type(k.meta) == 'table' and k.meta.handler or nil
    return want == nil or want == '' or want == owner
end

local function kindChanged(changed)
    for _, node in pairs(nodes) do
        if changed[node.kindIdx] then
            local k = kindsByIdx[node.kindIdx]
            node.kind = k
            node.dependency = isDependencyKind(k)
            if node.dependency then gcLater(node.id) end
            touch(node, B_KIND | B_WANTED)
        end
    end
end

local function applyKinds(list)
    if type(list) ~= 'table' then return end
    local changed = nil
    for i = 1, #list do
        local e = list[i]
        local idx = type(e) == 'table' and tointeger(e.idx) or nil
        if idx and idx > 0 then
            local old, id = kindsByIdx[idx], e.id
            if type(id) ~= 'string' or id == '' then          -- undefined (§55.3: its nodes stay placeholders)
                if old then
                    kindsByIdx[idx], nKinds = nil, nKinds - 1
                    if kindsById[old.id] == old then kindsById[old.id] = nil end
                    changed = changed or {}
                    changed[idx] = true
                end
            else
                local class = e.class
                if mtype(class) == 'integer' then class = Codec.CLASS_NAME[class] end
                local meta = type(e.meta) == 'table' and e.meta or {}
                if not (old and old.id == id and old.class == class and same(old.meta, meta, 0)) then
                    if old then
                        if kindsById[old.id] == old then kindsById[old.id] = nil end
                    else
                        nKinds = nKinds + 1
                    end
                    local k = { idx = idx, id = id, class = class, meta = meta }
                    k.dependency = isDependencyKind(k)
                    k.ready = claimOk(k)
                    kindsByIdx[idx], kindsById[id] = k, k
                    changed = changed or {}
                    changed[idx] = true
                end
            end
        end
    end
    if changed then kindChanged(changed) end
end

--------------------------------------------------------------------------------
-- node ops (`sec` = the cell of the op's section, PRIV_SEC, or nil outside any section)
--------------------------------------------------------------------------------

local function validId(id) return mtype(id) == 'integer' and id > 0 and id <= MAX_ID end

--- Field names that differ between two field tables go into `chg`; true when any did.
local function diffFields(old, new, chg)
    local any = false
    for k, v in pairs(new) do
        if not same(old[k], v, 0) then chg[k], any = true, true end
    end
    for k in pairs(old) do
        if new[k] == nil then chg[k], any = true, true end
    end
    return any
end

local function applyPut(sec, id, kindIdx, ver, parent, flags, x, y, z, rx, ry, rz, radius, extra)
    if sec == nil or not validId(id) then return end         -- a PUT outside CELL / PRIV has no home
    local node = nodes[id]
    local fresh = node == nil
    if fresh then node = newNode(id) end
    if sec == PRIV_SEC then
        if not node.priv then
            node.priv, node.gated, nPriv = true, true, nPriv + 1
            touch(node, B_WANTED)
        end
    else
        addMember(node, sec)
    end
    -- old news: membership only — except a near-variant PUT for a record that came from the FAR variant (flag 8:
    -- kind.nearFields omitted): same node ver, but it carries fields the client never had (RV2 F15)
    local d = vdiff(ver, node.ver)
    if not fresh and d <= 0 and not (d == 0 and node.flags & F_FAR ~= 0 and flags & F_FAR == 0) then return end
    local e = type(extra) == 'table' and extra or EMPTY
    local fields = type(e.f) == 'table' and e.f or {}
    local motion, interact, attach = tableOrNil(e.m), tableOrNil(e.i), tableOrNil(e.a)
    local offset, offrot, bone, netId = tableOrNil(e.o), tableOrNil(e.r), e.b, tointeger(e.n)
    local rotOrder = tointeger(e.q)                     -- the attachment's rotation order; nil = the engine's 2
    if rotOrder and (rotOrder < 0 or rotOrder > 5) then rotOrder = nil end
    parent = validId(parent) and parent or 0
    local bits = 0
    if fresh then
        linkParent(node, parent)
        adoptOrphans(node)
        setDeps(node, e.d)
    else
        if kindIdx ~= node.kindIdx then bits = bits | B_KIND end
        if parent ~= node.parent then
            unlinkParent(node)
            linkParent(node, parent)
            bits = bits | B_ATTACH | B_WANTED
        end
        if x ~= node.x or y ~= node.y or z ~= node.z or rx ~= node.rx or ry ~= node.ry or rz ~= node.rz then
            bits = bits | B_MOVE
        end
        if radius ~= node.radius then bits = bits | B_RADIUS end
        local chg = node.chg or {}
        if diffFields(node.fields, fields, chg) then
            node.chg = chg
            bits = bits | B_FIELDS
        end
        if not same(node.motion, motion, 0) then bits = bits | B_MOTION end
        if not same(node.interact, interact, 0) then bits = bits | B_INTERACT end
        if not (same(node.offset, offset, 0) and same(node.offrot, offrot, 0) and node.bone == bone
            and node.rotOrder == rotOrder and same(node.attach, attach, 0)) then bits = bits | B_ATTACH end
        if netId ~= node.netId then bits = bits | (netId and B_PROMOTE or B_DEMOTE) end
        if not same(node.deps, e.d, 0) then
            setDeps(node, e.d)
            bits = bits | B_DEP
        end
    end
    node.kindIdx, node.ver, node.flags, node.radius = kindIdx, ver, flags, radius
    node.x, node.y, node.z, node.rx, node.ry, node.rz = x, y, z, rx, ry, rz
    node.fields, node.motion, node.interact, node.attach = fields, motion, interact, attach
    node.offset, node.offrot, node.bone, node.rotOrder, node.netId = offset, offrot, bone, rotOrder, netId
    node.gated = node.priv or (flags & F_GATED) ~= 0
    local k = kindIdx > 0 and kindsByIdx[kindIdx] or nil
    if fresh or bits & B_KIND ~= 0 then
        node.kind = k
        node.dependency = isDependencyKind(k)
        if node.dependency then gcLater(id) end
    end
    if node.dependency and not fresh then touchDependents(id) end
    touch(node, bits)
end

--- The node an op of version `ver` may change: known and older (out-of-order safe), else nil.
local function newer(id, ver)
    local node = nodes[id]
    if node and vdiff(ver, node.ver) > 0 then return node end
    return nil
end

local function applySet(id, ver, patch)
    local node = newer(id, ver)
    if not node then return end
    node.ver = ver
    if type(patch) ~= 'table' then return end
    local bits = 0
    local f, x = patch.f, patch.x
    if type(f) == 'table' or type(x) == 'table' then
        local fields, chg = node.fields, node.chg or {}
        if fields == EMPTY then
            fields = {}
            node.fields = fields
        end
        node.chg = chg
        if type(f) == 'table' then
            for k, v in pairs(f) do fields[k], chg[k] = v, true end
        end
        if type(x) == 'table' then
            for i = 1, #x do fields[x[i]], chg[x[i]] = nil, true end
        end
        bits = B_FIELDS
    end
    if patch.i ~= nil then node.interact, bits = tableOrNil(patch.i), bits | B_INTERACT end
    if patch.a ~= nil then node.attach, bits = tableOrNil(patch.a), bits | B_ATTACH end
    if patch.d ~= nil then
        setDeps(node, patch.d)
        bits = bits | B_DEP
    end
    if node.dependency then touchDependents(id) end
    touch(node, bits)
end

local function applyMove(id, ver, x, y, z, rx, ry, rz)
    local node = newer(id, ver)
    if not node then return end
    node.ver = ver
    node.x, node.y, node.z, node.rx, node.ry, node.rz = x, y, z, rx, ry, rz
    touch(node, B_MOVE)
end

local function applyMotion(id, ver, motion)
    local node = newer(id, ver)
    if not node then return end
    node.ver, node.motion = ver, tableOrNil(motion)
    touch(node, B_MOTION)
end

local function applyPromote(id, ver, netId)
    local node = newer(id, ver)
    if not node then return end
    node.ver, node.netId, node.flags = ver, netId, node.flags | F_PROMOTED
    touch(node, B_PROMOTE)
end

local function applyDemote(id, ver, x, y, z, rx, ry, rz)
    local node = newer(id, ver)
    if not node then return end
    node.ver, node.netId, node.flags = ver, nil, node.flags & ~F_PROMOTED
    node.x, node.y, node.z, node.rx, node.ry, node.rz = x, y, z, rx, ry, rz
    touch(node, B_DEMOTE | B_MOVE)
end

--- DEL: the node leaves the op's cell (or PRIV set) whatever its ver; a newer normal/fade DEL deletes it, a
--- handover waits for the payload's end (a PUT of another cell may follow), an orphaned one goes.
local function applyDel(sec, id, ver, how)
    local node = nodes[id]
    if not node then return end
    if sec == PRIV_SEC then
        if node.priv then
            node.priv, node.gated, nPriv = false, false, nPriv - 1
            touch(node, B_WANTED)
        end
    elseif sec then
        removeMember(node, sec)
    end
    if how ~= DEL_HANDOVER and (vdiff(ver, node.ver) > 0 or sec == nil) then
        dropNode(node, how)
    elseif unheld(node) then
        if how == DEL_HANDOVER then
            node.handover = true
            touch(node, 0)
        else
            dropNode(node, how)
        end
    end
end

--- C2 dead reckoning (§55.9): the node's motion becomes a 'dr' descriptor (one reused table per node).
local function applyDr(id, t, x, y, z, vx, vy, vz, yaw)
    local node = nodes[id]
    if not node then return end
    local d = node.dr
    if d and node.motion == d and Clock.diff(t, d.t0) <= 0 then return end   -- an older sample
    if not d then
        d = { t = 'dr', t0 = t, p = { x = x, y = y, z = z }, v = { x = vx, y = vy, z = vz }, yaw = yaw }
        node.dr = d
    else
        local p, v = d.p, d.v
        d.t0, d.yaw = t, yaw
        p.x, p.y, p.z, v.x, v.y, v.z = x, y, z, vx, vy, vz
    end
    node.motion = d
    touch(node, B_DR)
end

local function applyEvent(id, t, x, y, z, name, params)
    local node = false
    if id ~= 0 then
        node = nodes[id]
        if not node then return end
    end
    nEvents = nEvents + 1
    events[nEvents] = { node, name, params, t, x, y, z }
end

--- Replays one buffered op (a pending cell's journal entry, after its snapshot) into `cell`.
local function applyBuffered(cell, op)
    local code = op[1]
    if code == OP_PUT then
        applyPut(cell, op[2], op[3], op[4], op[5], op[6], op[7], op[8], op[9], op[10], op[11], op[12], op[13], op[14])
    elseif code == OP_SET then applySet(op[2], op[3], op[4])
    elseif code == OP_MOVE then applyMove(op[2], op[3], op[4], op[5], op[6], op[7], op[8], op[9])
    elseif code == OP_MOTION then applyMotion(op[2], op[3], op[4])
    elseif code == OP_DEL then applyDel(cell, op[2], op[3], op[4])
    elseif code == OP_PROMOTE then applyPromote(op[2], op[3], op[4])
    elseif code == OP_DEMOTE then applyDemote(op[2], op[3], op[4], op[5], op[6], op[7], op[8], op[9])
    end
end

--- Asks the server for a cell's content again: client/scene_focus.lua's throttled queue (it loads right after
--- this file, so it is looked up at call time; it marks the cell `awaiting` once the request went out).
local function requestResync(cell)
    local F = C.focus
    if F then F.requestResync(cell) end
end

--------------------------------------------------------------------------------
-- sections: SUB / UNSUB / CELL (snapshot, journal, buffer) / PRIV
--------------------------------------------------------------------------------

local secMode, secCell, secTo, secLeft, secEntry = SKIP, nil, 0, 0, nil
local payloadNow, payloadLatent = 0, false

--- The version of the content the cell holds OF `variant` (0 = none: no content, or the other variant's). The
--- cached content is one (cv, v) pair; the subscription is (variant, target) — they differ after a ring change
--- until the new variant's content lands.
local function baseOf(cell, variant)
    return cell.cv == variant and cell.v or 0
end
Cache.baseOf = baseOf

--- A pending cell turns live once its content of the subscribed variant reached the version its SUB announced.
local function settle(cell)
    if cell.state == PENDING and cell.cv == cell.variant and vreached(cell.v, cell.target) then setState(cell, LIVE) end
end

--- Buffered journal entries of a pending cell, after its snapshot: old ones skipped, a chain applied, a gap
--- asks for a resync.
local function replayBuffer(cell)
    local buf = cell.buf
    if not buf then return end
    cell.buf = nil
    for i = 1, #buf do
        local e = buf[i]
        if vnewer(e.to, cell.v) then
            if e.from ~= cell.v then
                stats.gaps = stats.gaps + 1
                return requestResync(cell)
            end
            for j = 1, #e do applyBuffered(cell, e[j]) end
            cell.v = e.to
        end
    end
end

local function endSection()
    local mode, cell, to = secMode, secCell, secTo
    secMode, secCell, secLeft, secEntry = SKIP, nil, 0, nil
    if mode == SNAPSHOT then
        local old = snapOld
        snapCell, snapOld = nil, nil
        for id in pairs(old) do                             -- not in the snapshot: they left the cell ...
            local node = nodes[id]
            if node then
                node.refs = node.refs - 1
                if node.cellRef == cell then
                    node.cellRef = otherCell(node, cell)
                    touch(node, B_WANTED)
                end
            end
        end
        dropUnheld(old)                                     -- ... and go when nothing else holds them
    end
    if mode == SNAPSHOT or mode == APPLY then
        cell.v, cell.cv, cell.awaiting = to, cell.variant, nil
        replayBuffer(cell)
        settle(cell)
    end
end

--- A section the payload cut short (a decode error): a snapshot removes nothing it did not mention, and
--- the cell asks for its content again.
local function abortSection()
    local mode, cell, entry = secMode, secCell, secEntry
    secMode, secCell, secLeft, secEntry = SKIP, nil, 0, nil
    if mode == SNAPSHOT then
        local old = snapOld
        snapCell, snapOld = nil, nil
        for id in pairs(old) do
            if nodes[id] and not cell.nodes[id] then cell.nodes[id], cell.n = true, cell.n + 1 end
        end
    elseif mode == BUFFER then
        local buf = cell.buf
        if buf and buf[#buf] == entry then buf[#buf] = nil end
        return
    elseif mode == PARK then
        if entry and parked[entry.pk] == entry then unpark(entry.pk) end
        return
    end
    if mode ~= SKIP then requestResync(cell) end
end

local function parkKey(grid, key, variant) return ckey(grid, key) * 4 + variant end

local function unpark(pk)
    local e = parked[pk]
    if e then parked[pk], nParked, parkedOps = nil, nParked - 1, parkedOps - e.n end
end

local function oldestParked()
    local best, at = nil, nil
    for pk, e in pairs(parked) do
        if not at or e.at < at then best, at = pk, e.at end
    end
    return best
end

local function onCell(grid, key, variant, from, to, n)
    if secMode ~= SKIP then abortSection() end
    local cell = cells[ckey(grid, key)]
    local mode = SKIP
    if cell and cell.state ~= LRU and cell.variant == variant then
        local base = baseOf(cell, variant)
        if from == 0 then
            if vnewer(to, base) and vreached(to, cell.target) and not (payloadLatent and cell.subAt
                and Clock.diff(payloadNow, cell.subAt) < -LATENT_SLACK_MS) then
                mode = SNAPSHOT
            else
                stats.stale = stats.stale + 1
            end
        elseif from == base then
            mode = APPLY
        elseif not vnewer(to, base) then
            stats.stale = stats.stale + 1                    -- old news (a duplicate or a replayed entry)
        else                                                 -- content missing below it: kept for after it
            mode = BUFFER
            if cell.state ~= PENDING then                    -- (a pending cell's content is on its way)
                if not cell.awaiting then stats.gaps = stats.gaps + 1 end
                cell.awaiting = true                         -- a gap: live content asks for the rest; asked again
                requestResync(cell)                          -- after 2 s if still missing (RV2 F10)
            end
        end
    elseif from == 0 and payloadLatent then
        mode = PARK                                          -- a snapshot ahead of its SUB (latent is unordered)
    end
    if mode == SNAPSHOT then
        snapCell, snapOld = cell, cell.nodes
        cell.nodes, cell.n = {}, 0
    elseif mode == BUFFER then
        local buf = cell.buf or { ops = 0 }
        if buf.ops + n > BUFFER_MAX_OPS then
            cell.buf, mode = nil, SKIP
            stats.bufferDropped = stats.bufferDropped + 1
        else
            cell.buf, buf.ops = buf, buf.ops + n
            secEntry = { from = from, to = to }
            buf[#buf + 1] = secEntry
            stats.buffered = stats.buffered + 1
        end
    elseif mode == PARK then                                 -- kept a moment for its SUB (RV2 F6)
        local pk = parkKey(grid, key, variant)
        local old = parked[pk]
        if n > PARK_OPS or (old and not vnewer(to, old.to)) then
            mode = SKIP
        else
            if old then unpark(pk) end
            while nParked >= PARK_MAX or parkedOps + n > PARK_OPS do unpark(oldestParked()) end
            secEntry = { to = to, now = payloadNow, at = GetGameTimer(), n = n, pk = pk }
            parked[pk], nParked, parkedOps = secEntry, nParked + 1, parkedOps + n
            stats.parked = stats.parked + 1
        end
    end
    secMode, secCell, secTo, secLeft = mode, cell, to, n
    if n == 0 then endSection() end
end

--- A parked snapshot whose SUB arrived: applied now, as if it had come after it (RV2 F6).
local function applyParked(cell, e)
    if secMode ~= SKIP then abortSection() end
    snapCell, snapOld = cell, cell.nodes
    cell.nodes, cell.n = {}, 0
    secMode, secCell, secTo, secLeft, secEntry = SNAPSHOT, cell, e.to, 0, nil
    for i = 1, #e do applyBuffered(cell, e[i]) end
    stats.unparked = stats.unparked + 1
    endSection()
end

local function onSub(grid, key, variant, v)
    local ck = ckey(grid, key)
    local cell = cells[ck]
    if not cell then
        cell = { ck = ck, grid = grid, key = key, variant = variant, cv = variant, v = 0, target = v,
            state = PENDING, nodes = {}, n = 0, subAt = payloadNow, subLocal = 0, lruAt = 0 }
        cells[ck], nCells, counts[PENDING] = cell, nCells + 1, counts[PENDING] + 1
    else
        if cell.state == LRU then lruRemove(cell) end
        if cell.variant ~= variant then cell.buf = nil end    -- entries kept for the other variant are no use
        cell.variant, cell.target, cell.subAt = variant, v, payloadNow
    end
    cell.subLocal = GetGameTimer()
    if v == 0 then                                            -- empty: nothing follows
        clearCell(cell)
        cell.v, cell.cv, cell.buf = 0, variant, nil
        setState(cell, LIVE)
    elseif vreached(baseOf(cell, variant), v) then
        -- it holds this variant at the announced version (a held LRU cell, a ring change back while the old
        -- content is still cached): the server sends nothing more, the cell is live now. Content newer than
        -- announced is live too: the journal the server sends from `v` is old news up to it and chains on.
        setState(cell, LIVE)
    else
        setState(cell, PENDING)                               -- held content stays shown until the new lands
    end
    local pk = parkKey(grid, key, variant)
    local e = parked[pk]
    if e then                                                 -- its pack came first (latent is unordered)
        unpark(pk)
        if GetGameTimer() - e.at <= PARK_MS and Clock.diff(e.now, payloadNow) >= -LATENT_SLACK_MS
            and vreached(e.to, v) and vnewer(e.to, baseOf(cell, variant)) then
            applyParked(cell, e)
        end
    end
end

local function onUnsub(grid, key)
    local cell = cells[ckey(grid, key)]
    if not cell or cell.state == LRU then return end
    cell.buf, cell.target = nil, 0
    if cell.v == 0 or LRU_CELLS == 0 or LRU_MS == 0 then return dropCell(cell) end
    cell.lruAt = GetGameTimer()
    setState(cell, LRU)
    lru[#lru + 1] = cell
    while #lru > LRU_CELLS do dropCell(lru[1]) end
end

--------------------------------------------------------------------------------
-- the decoder's handler table (INTERFACES §2); node ops get the reused ctx last
--------------------------------------------------------------------------------

--- Where a node op goes: its section's cell (applied), PRIV_SEC, nil (loose op), or false (skipped).
local function target(s)
    if s == 'cell' then return (secMode == APPLY or secMode == SNAPSHOT) and secCell or false end
    if s == 'priv' then return PRIV_SEC end
    return nil
end

--- Counts a node op of the current section; the section ends with its last op.
local function stepped(s)
    stats.ops = stats.ops + 1
    if s == 'cell' then
        secLeft = secLeft - 1
        if secLeft <= 0 then endSection() end
    end
    if chunking then                                         -- a big payload: CHUNK_OPS node ops per frame (F17)
        chunkOps = chunkOps + 1
        if chunkOps >= CHUNK_OPS then
            chunkOps = 0
            stats.chunks = stats.chunks + 1
            Cache.flush()                                    -- what is decided so far reaches the materialiser
            Wait(0)                                          -- the rest next frame (order and versions unchanged)
        end
    end
end

--- In a buffering section the op is kept for later (true), else it is applied now.
local function buffered(s, ...)
    if s ~= 'cell' or (secMode ~= BUFFER and secMode ~= PARK) then return false end
    secEntry[#secEntry + 1] = { ... }
    return true
end

local H = {}
function H.header(_, now) payloadNow = now end
H.kinds, H.sub, H.unsub, H.cell = applyKinds, onSub, onUnsub, onCell

function H.put(id, kindIdx, ver, parent, flags, x, y, z, rx, ry, rz, radius, extra, ctx)
    local s = ctx.section
    if not buffered(s, OP_PUT, id, kindIdx, ver, parent, flags, x, y, z, rx, ry, rz, radius, extra) then
        local sec = target(s)
        if sec ~= false then applyPut(sec, id, kindIdx, ver, parent, flags, x, y, z, rx, ry, rz, radius, extra) end
    end
    stepped(s)
end

function H.set(id, ver, patch, ctx)
    local s = ctx.section
    if not buffered(s, OP_SET, id, ver, patch) and target(s) ~= false then applySet(id, ver, patch) end
    stepped(s)
end

function H.move(id, ver, x, y, z, rx, ry, rz, ctx)
    local s = ctx.section
    if not buffered(s, OP_MOVE, id, ver, x, y, z, rx, ry, rz) and target(s) ~= false then
        applyMove(id, ver, x, y, z, rx, ry, rz)
    end
    stepped(s)
end

function H.motion(id, ver, motion, ctx)
    local s = ctx.section
    if not buffered(s, OP_MOTION, id, ver, motion) and target(s) ~= false then applyMotion(id, ver, motion) end
    stepped(s)
end

function H.del(id, ver, how, ctx)
    local s = ctx.section
    if not buffered(s, OP_DEL, id, ver, how) then
        local sec = target(s)
        if sec ~= false then applyDel(sec, id, ver, how) end
    end
    stepped(s)
end

function H.promote(id, ver, netId, ctx)
    local s = ctx.section
    if not buffered(s, OP_PROMOTE, id, ver, netId) and target(s) ~= false then applyPromote(id, ver, netId) end
    stepped(s)
end

function H.demote(id, ver, x, y, z, rx, ry, rz, ctx)
    local s = ctx.section
    if not buffered(s, OP_DEMOTE, id, ver, x, y, z, rx, ry, rz) and target(s) ~= false then
        applyDemote(id, ver, x, y, z, rx, ry, rz)
    end
    stepped(s)
end

-- transient ops (not versioned, never journaled): applied whatever the section's fate
function H.event(id, t, x, y, z, name, params, ctx)
    applyEvent(id, t, x, y, z, name, params)
    stepped(ctx.section)
end

function H.dr(id, t, x, y, z, vx, vy, vz, yaw, ctx)
    applyDr(id, t, x, y, z, vx, vy, vz, yaw)
    stepped(ctx.section)
end

--------------------------------------------------------------------------------
-- flush: the materialiser hears each touched node once per payload (C.mat looked up now: it loads later)
--------------------------------------------------------------------------------

local function dataOf(node, bit)
    if bit == B_FIELDS then return node.chg end
    if bit == B_MOTION or bit == B_DR then return node.motion end
    if bit == B_INTERACT then return node.interact end
    if bit == B_RADIUS then return node.radius end
    return nil
end

--- Promotion hand-offs (§55.15): client/scene_promote.lua when it exists (phase C), else the materialiser.
local function promoteRound(node, bits, mat, emit)
    local P = C.promote
    if bits & B_PROMOTE ~= 0 then
        if P and P.onPromote then
            P.onPromote(node, node.netId)
        elseif mat then
            mat.update(node, 'promote', node.netId)
        end
        if emit then emit('promoted', node, node.netId) end
    end
    if bits & B_DEMOTE ~= 0 then
        if P and P.onDemote then
            P.onDemote(node)
        elseif mat then
            mat.update(node, 'demote')
        end
        if emit then emit('demoted', node) end
    end
end

--- One node's round: the materialiser knows exactly the WANTED nodes (add = entered the wanted set, remove =
--- left it or the cache; C.mat's reading of INTERFACES §5); a known one hears what changed, once per payload.
local function flushNode(node, mat, emit)
    local bits = node.pend
    node.touched, node.pend = false, 0
    if not node.gone and node.handover then                  -- a handover without a new home in the payload:
        node.handover = nil                                  -- the materialiser keeps the entity a moment for
        if unheld(node) then dropNode(node, DEL_HANDOVER) end   -- a PUT of the same id in a later payload
    end
    local w = wanted(node)
    local changed = node.seen and bits & ~B_WANTED or 0
    if not node.gone and bits & (B_PROMOTE | B_DEMOTE) ~= 0 and node.seen then
        promoteRound(node, bits, node.added and mat or nil, emit)
    end
    if not w then
        if node.added or node.m ~= nil then                 -- (node.m: the materialiser took it in on its own,
            node.added = false                               -- a child its root warmed; remove is idempotent)
            if mat then mat.remove(node, node.gone and node.goneHow or DEL_NORMAL) end
        end
    elseif not node.added then
        node.added = true
        if mat then mat.add(node) end
    elseif mat and changed ~= 0 then
        local b = changed & ~(B_PROMOTE | B_DEMOTE)
        if b & B_KIND ~= 0 then
            mat.update(node, 'kind', node.kind)
            b = b & ~B_SUBSUMED
        end
        for i = 1, #WHATS do
            local wh = WHATS[i]
            if b & wh[1] ~= 0 then mat.update(node, wh[2], dataOf(node, wh[1])) end
        end
    end
    -- DR ticks (up to 10 Hz per driven node) are the movers' business, never a listener's 'changed' (RV2 F9)
    local told = changed & ~B_DR
    if emit and told ~= 0 and not node.gone then emit('changed', node, told) end
    node.seen, node.chg = true, nil
end

--- One EVENT op (§55.8 C4): its age from Core.Clock (negative = still in the future).
local function deliver(ev, mat, emit)
    local node = ev[1] or nil
    if node and node.gone then return end
    local age = Clock.diff(Clock.now(), ev[4])
    stats.events = stats.events + 1
    if mat then mat.event(node, ev[2], ev[3], age, ev[5], ev[6], ev[7]) end
    if emit then emit('event', node, ev[2], ev[3], age, ev[5], ev[6], ev[7]) end
end

local carry, nCarry = {}, 0              -- touched nodes a flush inside an open payload leaves for its end

--- Runs the queued work: dependency GC, one materialiser round per touched node, then the events. A failing
--- materialiser call costs that node's round only (logged at most once a minute). Inside an open payload (the
--- worker's chunks, housekeeping, a claim) a pending DEL(handover) stays undecided: its PUT may still come.
local function flush()
    if flushing then return end
    flushing = true
    local final = not payloadActive
    repeat
        for i = 1, nGc do                                    -- dependencies nothing depends on any more
            local id = gcDeps[i]
            gcDeps[i] = nil
            local n = nodes[id]
            if n and n.dependency and depCount[id] == nil then dropNode(n, DEL_NORMAL) end
        end
        nGc = 0
        local mat, emit = C.mat, C.emit
        local i = 1
        while i <= nTouched do
            local node = touched[i]
            touched[i], i = nil, i + 1
            if not final and node.handover and not node.gone then
                nCarry = nCarry + 1
                carry[nCarry] = node
            else
                local ok, err = pcall(flushNode, node, mat, emit)
                if not ok then warn('materialiser round of node %d failed: %s', node.id, tostring(err)) end
            end
        end
        nTouched = 0
        local j = 1
        while j <= nEvents do                                -- after the nodes they may name
            local ev = events[j]
            events[j], j = nil, j + 1
            local ok, err = pcall(deliver, ev, mat, emit)
            if not ok then warn('event %s failed: %s', tostring(ev[2]), tostring(err)) end
        end
        nEvents = 0
    until nTouched == 0 and nGc == 0
    for j = 1, nCarry do                                     -- still touched: the payload's end decides them
        touched[j], carry[j] = carry[j], nil
    end
    nTouched, nCarry = nCarry, 0
    flushing = false
end
Cache.flush = flush

--------------------------------------------------------------------------------
-- receive (reliable stream + latent packs), reset, core stop
--------------------------------------------------------------------------------

local function process(blob, latent)
    stats.payloads, stats.bytesIn = stats.payloads + 1, stats.bytesIn + #blob
    if latent then stats.latent = stats.latent + 1 end
    payloadNow, payloadLatent, payloadActive = 0, latent, true
    local ok, res, err = pcall(Codec.decode, blob, H)
    if secMode ~= SKIP then abortSection() end               -- cut short (decode error or a handler error)
    secLeft, secCell, payloadActive = 0, nil, false
    if not ok or not res then
        stats.decodeErrors = stats.decodeErrors + 1
        warn('undecodable %s payload (%d bytes): %s', latent and 'latent' or 'stream', #blob,
            tostring(ok and err or res))
    end
    flush()
end

--- Drops everything: cells, the LRU, nodes, parked packs (a new bucket: the content belonged to the old one).
--- `how` = DEL_WORLD for a bucket change (RV6 F3: the old world's entities go at once, collision off — nothing of it
--- lingers visibility-safely next to the new one, no attachment is doubled on a ped), else DEL_NORMAL.
local function resetNow(how)
    how = how or DEL_NORMAL
    if secMode ~= SKIP then abortSection() end
    local mat = C.mat
    if how == DEL_WORLD and mat and mat.worldReset then     -- what already retires of the old world goes too
        local ok, err = pcall(mat.worldReset)
        if not ok then warn('the materialiser world reset failed: %s', tostring(err)) end
    end
    for _, cell in pairs(cells) do dropCell(cell, how) end
    for _, node in pairs(nodes) do                            -- what no cell held (gated): roots first ...
        if not node.gone and (node.parent == 0 or nodes[node.parent] == nil) then dropNode(node, how) end
    end
    for _, node in pairs(nodes) do                            -- ... then anything left
        if not node.gone then dropNode(node, how) end
    end
    for pk in pairs(parked) do parked[pk] = nil end
    nParked, parkedOps = 0, 0
    stats.resets = stats.resets + 1
    flush()
end

-- The worker (RV2 F17): a payload above BIG_BYTES, and everything that arrives while one is in work, is queued
-- and taken apart CHUNK_OPS node ops per frame in stream order; a small payload with nothing queued is applied
-- at once, in its event handler.
local inbox, inHead, inTail, busy = {}, 1, 0, false
local RESET_ITEM <const> = {}

local function work()
    while inHead <= inTail and not stopped do
        local item = inbox[inHead]
        inbox[inHead], inHead = nil, inHead + 1
        if item == RESET_ITEM then
            resetNow(DEL_WORLD)
        else
            chunking, chunkOps = true, 0
            local ok, err = pcall(process, item[1], item[2])
            chunking = false
            if not ok then warn('scene payload failed: %s', tostring(err)) end
        end
    end
    for i = inHead, inTail do inbox[i] = nil end
    inHead, inTail, busy = 1, 0, false
end

local function receive(blob, latent)
    if stopped or type(blob) ~= 'string' or #blob < 5 or #blob > MAX_PAYLOAD then return end
    if not busy and #blob <= BIG_BYTES then return process(blob, latent) end
    inTail = inTail + 1
    inbox[inTail] = { blob, latent }
    if not busy then
        busy = true
        CreateThread(work)
    end
end

RegisterNetEvent('core:scene:s', function(blob) receive(blob, false) end)
RegisterNetEvent('core:scene:p', function(blob) receive(blob, true) end)

--- Drops everything (client/scene_focus.lua on a real bucket change: the old world's entities go at once, RV6 F3).
--- While the worker holds the stream the reset queues behind the payloads that came before it.
function Cache.reset()
    if busy then
        inTail = inTail + 1
        inbox[inTail] = RESET_ITEM
        return
    end
    resetNow(DEL_WORLD)
end

--- RESET (reason): the server dropped every subscription of this client (a bucket change it detected, RV2 F14):
--- everything goes — LRU included, whose versions belong to the old bucket — and a focus report goes out at once.
--- Reason 1 (BUCKET) is a new world (RV6 F3: its entities go at once); EPOCH / RESYNC keep the visibility-safe drop.
function H.reset(reason)
    resetNow(reason == 1 and DEL_WORLD or DEL_NORMAL)
    local F = C.focus
    if F and F.onReset then F.onReset(reason) end
end

--- Once per focus sample (client/scene_focus.lua's thread): LRU cells past ClientLruMs go, subscriptions whose
--- content never came and live cells whose resync answer never came ask again. Allocation-free.
local lastScan = -1000
function Cache.housekeep(t)
    while lru[1] and t - lru[1].lruAt >= LRU_MS do dropCell(lru[1]) end
    if nParked > 0 then
        for pk, e in pairs(parked) do
            if t - e.at > PARK_MS then unpark(pk) end        -- its SUB never came
        end
    end
    if t - lastScan >= 1000 then                              -- once a second, allocation-free
        lastScan = t
        for _, cell in pairs(cells) do
            if cell.state == PENDING and t - cell.subLocal >= PENDING_MS then
                cell.subLocal = t
                requestResync(cell)
            elseif cell.awaiting and cell.state == LIVE and t - (cell.resyncAt or 0) >= PENDING_MS then
                requestResync(cell)                          -- a lost answer: a quiet cell never asks otherwise
            end
        end
    end
    if nTouched > 0 or nGc > 0 then flush() end
end

AddEventHandler('onClientResourceStop', function(resource)
    if resource == GetCurrentResourceName() then stopped = true end
end)

--------------------------------------------------------------------------------
-- C.cache (INTERFACES §5) — internal: the materialiser, kinds, fx, movers and client/scene.lua read it
--------------------------------------------------------------------------------

function Cache.node(id) return nodes[id] end
function Cache.kind(idx) return kindsByIdx[idx] end
function Cache.kindById(id) return kindsById[id] end
Cache.wanted = wanted

--- fn(node) for every cached node (dependencies included); returning true stops. Never add or drop inside.
function Cache.forEachNode(fn)
    for _, node in pairs(nodes) do
        if fn(node) == true then return end
    end
end

--- The cell record of (grid, key), read-only: { grid, key, variant, v, target, state = 1|2|3, n, nodes }.
function Cache.cell(grid, key) return cells[ckey(grid, key)] end
Cache.STATE_NAME = STATE_NAME
Cache.STATE = { pending = PENDING, live = LIVE, lru = LRU }

--- The LRU cells, oldest first (the live array: read it, never change it) — the focus report's `held`.
function Cache.lru() return lru end

--- Cells and nodes cached.
function Cache.count() return nCells, nNodes end

--- Records which resource handles a plugin kind (client/scene.lua's claim; nil = nobody): its nodes turn
--- wanted / unwanted accordingly.
function Cache.setClaim(kindId, owner)
    claims[kindId] = owner
    local k = kindsById[kindId]
    if not k then return end
    local ready = claimOk(k)
    if ready == k.ready then return end
    k.ready = ready
    for _, node in pairs(nodes) do
        if node.kind == k then touch(node, B_WANTED) end
    end
    flush()
end

--- True when the near cells around (x, y) within r are subscribed and current (the server sends SUB even
--- for an empty cell), and the region and global set, when subscribed, are not waiting for content.
function Cache.areaReady(x, y, r)
    if nCells == 0 then return false end
    for cx = floor((x - r) / CELL_SIZE), floor((x + r) / CELL_SIZE) do
        for cy = floor((y - r) / CELL_SIZE), floor((y + r) / CELL_SIZE) do
            local c = cells[ckey(GRID_NEAR, (cx + 32768) * 65536 + (cy + 32768))]
            if not c or c.state ~= LIVE then return false end
        end
    end
    local region = cells[ckey(GRID_FAR, keyOf(x, y, REGION_SIZE))]
    if region and region.state == PENDING then return false end
    local global = cells[ckey(GRID_GLOBAL, 0)]
    return not (global and global.state == PENDING)
end

function Cache.stats()
    local deps = 0
    for id in pairs(depCount) do
        if nodes[id] then deps = deps + 1 end
    end
    local out = { cells = nCells, pending = counts[PENDING], live = counts[LIVE], lru = counts[LRU],
        nodes = nNodes, gated = nPriv, deps = deps, kinds = nKinds, parkedNow = nParked,
        queuedPayloads = inTail - inHead + 1 }
    for k, v in pairs(stats) do out[k] = v end
    return out
end

-- fxlint-disable-next-line C003 -- one-shot handoff to the scene files after this one; client/scene.lua clears it
CoreSceneRuntime = C
