--[[
    core/server/scene_store.lua — the Core.Scene node store (DESIGN §55.3, §55.4, §55.18): records, pose, parent /
    child structure, dependency bookkeeping, the server hooks (Scene.on / onInteract / off), persistence and the
    load barrier. Sixth of the scene server files (scene_kinds → scene_index → scene_interest → scene_gated →
    scene_flush → scene_store → scene → scene_promote → scene_audio → scene_voice): it asserts its predecessors
    and hands its internals to server/scene.lua (the API) ONCE through R.storeInternal, which scene.lua takes
    and clears — the manifest order is load-bearing.

      R.store (internal, read by the index / interest / flush / promote files):
        get(id) -> node | nil          pose(node, t) -> x, y, z, rx, ry, rz (motion-evaluated; a child = its
        root(node) -> node               parent's pose ∘ offset, no bones on the server; an attached node =
        dependents(id) -> set | nil      the target's server-known position ∘ offset)
        count() / copy(node) / bump(node) -> ver / notify(event, node, ...) / each(fn) / loaded() / flush()
        settle(node, x, y, z, rx, ry, rz)   a finished plan folded into the base pose (the index's movers sweep)
        follow(node, pos, rot, bucket, persistNow) -> true | nil, err   a PROMOTED root follows its clone (pose,
                                         bucket with its children; re-celled, ver + 1, no hooks, persisted ≤ 1 / 30 s)
        audienceOf(node) -> nil | audience   the EFFECTIVE audience: every level of the node's path (its own and
                                         each ancestor's) must admit a player. nil = public; one level carries one
                                         = that table (live, never mutate); several = { all = { rootAud, …,
                                         nodeAud } } (fresh, root first) — the §55.3 grammar, so an evaluator of
                                         node.audience takes it as is (`near` measured from the node evaluated)
        kids(id) -> set | nil             the node's DIRECT children { [childId] = true } (live, never mutate)
        hookStats() -> { handles, interactKeys, listenEvents, listenKeys }   (an emptied key list is dropped)
    node.ver is PER NODE: 1 on spawn / load, +1 per change, a u32 that wraps 4294967295 → 1 (never 0). Compare
    versions of one node with serial arithmetic — d = ((new − old + 2^31) % 2^32) − 2^31, newer iff d > 0 —
    never with < / <=. A promoted node's pose is its clone's (R.promote.ours); a { net } attachment holds only while
    the net id still names the entity (handle + model) it was made with, else the pose holds at the last one seen.
    Node records are written only here and by scene.lua (except node.cell — index — and node.promoted — promote).
    A root carries `children` = every descendant id, parent first (what the index packs after the root). Live
    descriptors are rebased by the index's movers sweep (Motion.needsRebase / rebase); finished plans come back
    here through settle.

    Persistence (§56.6): table `scene_nodes`, one row per persistent node (columns id, kind, owner, parent — NULL for
    a root —, bucket + `doc` jsonb = the rest); the id counter = row core_counters('scene_nodes') (the next id).
    Writes are coalesced (one thread, only while something is dirty, <= 1 write per node per second, a final write
    on core stop) and QUEUED (Core.DB.save / remove: never yield; core_db commits them after core is gone). A motion
    is stored rebased (Motion.rebase at the write) without t0, its time phase in `mphase`; Clock-valued fields
    (kind.clock) as phases in `clk`; both re-anchored at load. Player / net attachments and 'dr' are transient.
    Loaded once behind a promise barrier (the first caller loads — the counter with sync = true, then the rows
    through Core.DB.stream — everyone else waits; a failed read fails the load, retried at most every 10 s, never
    an empty world, no half state); undefined kinds load as placeholders.

    Natives: GetPlayerPed, GetEntityCoords, GetEntityHeading, GetEntityRotation, GetEntityModel,
    NetworkGetEntityFromNetworkId, DoesEntityExist (all server / CFX forms, fxref 2026-09-26/27). CreateThread, Wait,
    AddEventHandler, promise, Citizen.Await: runtime.
]]

local R = Core.SceneRuntime
assert(R and R.kinds and R.valid, 'server/scene_kinds.lua must load before server/scene_store.lua')
assert(R.index and R.interest and R.flush,
    'server/scene_index.lua, scene_interest.lua and scene_flush.lua must load before server/scene_store.lua')

local Scene = Core.Scene                     -- the lib namespace (lib/scene/*.lua when present); core adds the API
if type(Scene) ~= 'table' then
    Scene = {}
    Core.Scene = Scene
end

local K, V, Motion = R.kinds, R.valid, Core.SceneMotion
local Utils, Log, Registry = Core.Utils, Core.Log, Core.Registry
assert(Motion and Motion.pose and Motion.validate, 'shared/scene_motion.lua must load before server/scene_store.lua')

local type, pairs, next, pcall, tostring = type, pairs, next, pcall, tostring
local toint, huge, rad, cos, sin = math.tointeger, math.huge, math.rad, math.cos, math.sin

local LISTEN_KIND <const>, INTERACT_KIND <const> = 'sceneListener', 'sceneInteract'
local T_NODES <const>, T_COUNTERS <const>, COUNTER <const> = 'scene_nodes', 'core_counters', 'scene_nodes'
local LOAD_SQL <const> = 'SELECT id, kind, owner, parent, bucket, doc FROM scene_nodes ORDER BY id'
local COUNTER_SQL <const> = 'SELECT value FROM core_counters WHERE name = $1'
local LOAD_BATCH <const> = 1000
local ID_MAX <const> = 0x7FFFFFFF
local MAX_DEPTH <const> = 4
local LOAD_RETRY_MS <const> = 10000
local ZERO <const> = { x = 0.0, y = 0.0, z = 0.0 }
local EMPTY <const> = {}
local EVENTS <const> = { spawned = true, changed = true, removed = true, promoted = true, demoted = true }

local nodes, count = {}, 0          -- [id] = node
local kidsOf = {}                   -- [id] = { [childId] = true } (direct children)
local dependents = {}               -- [dependencyId] = { [nodeId] = true }
local byKind, byOwner, ownerCount = {}, {}, {}
local persistCount, globalCount = 0, 0
local globalByOwner = {}            -- [owner] = its global nodes (Global.MaxPerOwner)
local nextId = 1
local driving = {}                  -- [id] = { at = Clock ms of the last DR op }
local followAt, followLate = {}, {}   -- [id] = Clock ms of the last followed write / the pending write's token

local store = {}
R.store = store

local function cfg() return Config.Scene end
local function isFinite(v) return type(v) == 'number' and v == v and v ~= huge and v ~= -huge end
local function v3(v) return v and { x = v.x, y = v.y, z = v.z } or nil end
local function toId(id) local n = toint(id) return (n and n >= 1 and n <= ID_MAX) and n or nil end

--- Deep equality of plain data.
local function same(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function ownerOk(node)
    local caller = Registry.getCaller()
    return caller == 'core' or caller == node.owner
end

--- Per-node version (review F6): 1 for a new node, +1 per change, wraps 2^32 - 1 → 1 (serial arithmetic).
local function bumpVer(node)
    local v = (node.ver or 0) + 1
    if v > 0xFFFFFFFF then v = 1 end
    node.ver = v
    return v
end

--- The public, detached copy of a node (hooks, Scene.get, query). `audience.fn` becomes true.
local function copyNode(n)
    return { id = n.id, kind = n.kind, owner = n.owner, bucket = n.bucket, pos = v3(n.pos), rot = v3(n.rot),
        parent = n.parent, offset = v3(n.offset), offrot = v3(n.offrot), bone = n.bone, rotOrder = n.rotOrder,
        motion = n.motion and Utils.deepCopy(n.motion) or nil,
        attach = n.attach and { player = n.attach.player, net = n.attach.net } or nil,
        fields = Utils.deepCopy(n.fields), audience = V.audienceData(n.audience), radius = n.radius, tier = n.tier,
        global = n.global, persist = n.persist, interact = n.interact and Utils.deepCopy(n.interact) or nil,
        authority = n.authority and Utils.deepCopy(n.authority) or nil,
        deps = n.deps and { table.unpack(n.deps) } or nil,
        children = n.children and table.move(n.children, 1, #n.children, 1, {}) or nil, ver = n.ver,
        placeholder = n.k == nil or nil,
        allowChildren = type(n.allowChildren) == 'table' and { table.unpack(n.allowChildren) } or n.allowChildren,
        promoted = (n.promoted and n.promoted.netId) and { netId = n.promoted.netId } or nil }
end

--------------------------------------------------------------------------------
-- Pose, structure, bookkeeping
--------------------------------------------------------------------------------

--- An offset rotated by a GTA rotation (degrees, order 2: yaw · pitch · roll) — the server's approximation.
local function rotate(rx, ry, rz, ox, oy, oz)
    local x, y, z = rad(rx), rad(ry), rad(rz)
    local cx, sx, cy, sy, cz, sz = cos(x), sin(x), cos(y), sin(y), cos(z), sin(z)
    return ox * (cy * cz - sy * sx * sz) + oy * (-cx * sz) + oz * (sy * cz + cy * sx * sz),
        ox * (cy * sz + sy * sx * cz) + oy * (cx * cz) + oz * (sy * sz - cy * sx * cz),
        ox * (-sy * cx) + oy * sx + oz * (cy * cx)
end

--- The entity a { net } attachment still names — the handle and model it was made with (the server hands a
--- deleted entity's net id to the next one: review F20) — or nil.
local function netTarget(a)
    local e = NetworkGetEntityFromNetworkId(a.net)
    if not e or e == 0 or (a.ent and e ~= a.ent) or not DoesEntityExist(e) then return nil end
    if a.model and GetEntityModel(e) ~= a.model then return nil end
    return e
end

--- Server-known position + heading of an attachment target; while it is gone the last one seen (nil before any).
local function targetPose(a)
    local ent
    if a.player then
        ent = GetPlayerPed(a.player)
        if ent == 0 or not DoesEntityExist(ent) then ent = nil end
    elseif a.net then
        ent = netTarget(a)
    end
    if ent then
        local c = GetEntityCoords(ent)
        a.x, a.y, a.z, a.h = c.x, c.y, c.z, GetEntityHeading(ent)
    end
    return a.x, a.y, a.z, a.h
end

--- A promoted node's pose is its clone's while the clone is ours (R.promote.ours: exists, state sn = id).
local function clonePose(node)
    local e = node.promoted.entity
    local P = R.promote
    if not (e and P and P.ours and P.ours(e, node.id)) then return nil end
    local c, r = GetEntityCoords(e), GetEntityRotation(e)
    return c.x, c.y, c.z, r.x, r.y, r.z
end

--- The node's pose at Clock time t: a promoted node = its clone's; motion-evaluated; a child = its parent's pose ∘
--- offset (no bones on the server); an attached node = the target's server-known position ∘ offset (while the
--- target is gone: the last one seen, the base pose before any).
local function pose(node, t, depth)
    depth = depth or 0
    if node.promoted then
        local x, y, z, rx, ry, rz = clonePose(node)
        if x then return x, y, z, rx, ry, rz end
    end
    local parent = node.parent and nodes[node.parent]
    if parent and depth < MAX_DEPTH + 1 then
        local px, py, pz, prx, pry, prz = pose(parent, t, depth + 1)
        local o, q = node.offset or ZERO, node.offrot or ZERO
        local wx, wy, wz = rotate(prx, pry, prz, o.x, o.y, o.z)
        return px + wx, py + wy, pz + wz, V.wrap(prx + q.x), V.wrap(pry + q.y), V.wrap(prz + q.z)
    end
    local a = node.attach
    if a then
        local ax, ay, az, h = targetPose(a)
        if ax then
            local o, q = node.offset or ZERO, node.offrot or ZERO
            local wx, wy, wz = rotate(0, 0, h, o.x, o.y, o.z)
            return ax + wx, ay + wy, az + wz, q.x, q.y, V.wrap(h + q.z)
        end
    end
    local p, r = node.pos or ZERO, node.rot or ZERO
    if node.motion then
        local x, y, z, rx, ry, rz = Motion.pose(p.x, p.y, p.z, r.x, r.y, r.z, node.motion, t or R.now())
        if x then return x, y, z, rx, ry, rz end
    end
    return p.x, p.y, p.z, r.x, r.y, r.z
end

local function rootOf(node)
    local n, guard = node, 0
    while n.parent and nodes[n.parent] and guard <= MAX_DEPTH do
        n, guard = nodes[n.parent], guard + 1
    end
    return n
end

local function depthOf(node)
    local d, n = 0, node
    while n.parent and nodes[n.parent] and d <= MAX_DEPTH do
        n, d = nodes[n.parent], d + 1
    end
    return d
end

--- Descendant ids of `id`, parent first (children in ascending id order), appended to `out`.
local function descendants(id, out)
    local kids = kidsOf[id]
    if not kids then return out end
    local list = {}
    for cid in pairs(kids) do list[#list + 1] = cid end
    table.sort(list)
    for i = 1, #list do out[#out + 1] = list[i] end
    for i = 1, #list do descendants(list[i], out) end
    return out
end

--- Height of the subtree under `id` (0 = no children).
local function heightOf(id)
    local h = 0
    for cid in pairs(kidsOf[id] or EMPTY) do
        local c = heightOf(cid) + 1
        if c > h then h = c end
    end
    return h
end

--- root.children = every descendant, parent first (what the index packs after the root); nil on non-roots.
local function rebuildChildren(root)
    local list = descendants(root.id, {})
    root.children = #list > 0 and list or nil
end

local function link(node)
    local id, owner = node.id, node.owner
    nodes[id], count = node, count + 1
    byKind[node.kind] = byKind[node.kind] or {}
    byKind[node.kind][id] = true
    byOwner[owner] = byOwner[owner] or {}
    byOwner[owner][id] = true
    ownerCount[owner] = (ownerCount[owner] or 0) + 1
    if node.persist then persistCount = persistCount + 1 end
    if node.global then
        globalCount = globalCount + 1
        globalByOwner[owner] = (globalByOwner[owner] or 0) + 1
    end
    if node.parent then
        kidsOf[node.parent] = kidsOf[node.parent] or {}
        kidsOf[node.parent][id] = true
    end
    for i = 1, node.deps and #node.deps or 0 do
        local d = node.deps[i]
        dependents[d] = dependents[d] or {}
        dependents[d][id] = true
    end
end

local function setDeps(node, deps)
    for i = 1, node.deps and #node.deps or 0 do
        local set = dependents[node.deps[i]]
        if set then
            set[node.id] = nil
            if next(set) == nil then dependents[node.deps[i]] = nil end
        end
    end
    node.deps = deps
    for i = 1, deps and #deps or 0 do
        dependents[deps[i]] = dependents[deps[i]] or {}
        dependents[deps[i]][node.id] = true
    end
end

local function unlink(node)
    local id, owner = node.id, node.owner
    nodes[id], count = nil, count - 1
    local set = byKind[node.kind]
    if set then set[id] = nil if next(set) == nil then byKind[node.kind] = nil end end
    set = byOwner[owner]
    if set then set[id] = nil if next(set) == nil then byOwner[owner] = nil end end
    ownerCount[owner] = (ownerCount[owner] or 1) - 1
    if ownerCount[owner] <= 0 then ownerCount[owner] = nil end
    if node.persist then persistCount = persistCount - 1 end
    if node.global then
        globalCount = globalCount - 1
        globalByOwner[owner] = (globalByOwner[owner] or 1) - 1
        if globalByOwner[owner] <= 0 then globalByOwner[owner] = nil end
    end
    local kids = node.parent and kidsOf[node.parent]
    if kids then kids[id] = nil if next(kids) == nil then kidsOf[node.parent] = nil end end
    kidsOf[id] = nil
    setDeps(node, nil)
    dependents[id] = nil
    driving[id], followAt[id], followLate[id] = nil, nil, nil
end

--- The one write path of node.motion in the store and the API (the index's movers sweep rebases in place).
local function setMotion(node, m)
    node.motion = m
end

function store.get(id) return nodes[id] end
function store.kids(id) return kidsOf[id] end

--- The effective audience (header): every level of the node's path that carries one must admit a player.
function store.audienceOf(node)
    local first, list
    local n, guard = node, 0
    while n and guard <= MAX_DEPTH do
        local a = n.audience
        if a then
            if not first then
                first = a
            elseif not list then
                list = { a, first }                                  -- walking up: the ancestor goes first
            else
                table.insert(list, 1, a)
            end
        end
        n, guard = n.parent and nodes[n.parent], guard + 1
    end
    if list then return { all = list } end
    return first
end
function store.pose(node, t) return pose(node, t) end
function store.root(node) return rootOf(node) end
function store.dependents(id) return dependents[id] end
function store.count() return count end
function store.copy(node) return copyNode(node) end
function store.bump(node) return bumpVer(node) end
function store.each(fn) for _, node in pairs(nodes) do fn(node) end end

--------------------------------------------------------------------------------
-- Server hooks: Scene.on / onInteract / off (observers; every handler gets its own copy)
--------------------------------------------------------------------------------

local handles, handleSeq = {}, 0     -- [handle] = { what = 'listen'|'interact', event, key, fn, owner }
local listen, interactBy = {}, {}    -- [event] = { [key] = { handles } } / [key] = { handles }

local function keyOf(v)
    if type(v) == 'string' then return (#v >= 1 and #v <= 64) and v or nil end
    return toId(v)
end

local function pushHandle(entry, list)
    handleSeq = handleSeq + 1
    local h = (entry.what == 'listen' and 'sl:' or 'si:') .. handleSeq
    handles[h] = entry
    list[#list + 1] = h
    Registry.track(entry.what == 'listen' and LISTEN_KIND or INTERACT_KIND, h, entry.owner)
    return h
end

--- Removes one handle; an emptied list (and an emptied listen[event] map) goes with it — handles keyed by node ids
--- come and go with their nodes (a drop's pickup handler per node), so nothing may stay behind per key.
local function dropHandle(h)
    local e = handles[h]
    if not e then return false end
    handles[h] = nil
    local map = e.what == 'listen' and listen[e.event] or interactBy
    local list = map and map[e.key]
    if list then
        for i = #list, 1, -1 do if list[i] == h then table.remove(list, i) end end
        if #list == 0 then map[e.key] = nil end
        if e.what == 'listen' and next(map) == nil then listen[e.event] = nil end
    end
    Registry.untrack(e.what == 'listen' and LISTEN_KIND or INTERACT_KIND, h)
    return true
end
Registry.onOwnerStop(LISTEN_KIND, function(h) dropHandle(h) end)
Registry.onOwnerStop(INTERACT_KIND, function(h) dropHandle(h) end)

--- Runs the listeners of `event` for the node id, then its kind, then '*': fn(nodeCopy, ...), pcall'ed.
local function fire(event, node, ...)
    local map = listen[event]
    if not map then return end
    local keys = { node.id, node.kind, '*' }
    for i = 1, 3 do
        local list = map[keys[i]]
        if list and #list > 0 then
            local snapshot = table.move(list, 1, #list, 1, {})
            for j = 1, #snapshot do
                local e = handles[snapshot[j]]
                if e then
                    local ok, err = pcall(e.fn, copyNode(node), ...)
                    if not ok then Log.warn('scene: %s listener of %s failed: %s', event, e.owner, tostring(err)) end
                end
            end
        end
    end
end
store.notify = fire

--- Scene.on(event, kindOrId, fn) -> handle. event: spawned | changed (what) | removed (reason) | promoted | demoted.
function Scene.on(event, kindOrId, fn)
    local key = keyOf(kindOrId)
    if not EVENTS[event] or not key or not Utils.isCallable(fn) then return nil end
    listen[event] = listen[event] or {}
    listen[event][key] = listen[event][key] or {}
    return pushHandle({ what = 'listen', event = event, key = key, fn = fn, owner = Registry.getCaller() },
        listen[event][key])
end

--- Scene.onInteract(kindOrId, fn(src, nodeCopy, action, data)) -> handle.
function Scene.onInteract(kindOrId, fn)
    local key = keyOf(kindOrId)
    if not key or key == '*' or not Utils.isCallable(fn) then return nil end
    interactBy[key] = interactBy[key] or {}
    return pushHandle({ what = 'interact', key = key, fn = fn, owner = Registry.getCaller() }, interactBy[key])
end

--- Removes a Scene.on / onInteract handle (its owner or core).
function Scene.off(handle)
    local e = type(handle) == 'string' and handles[handle]
    if not e then return false end
    local caller = Registry.getCaller()
    if caller ~= 'core' and caller ~= e.owner then return false end
    return dropHandle(handle)
end

--- R.store.hookStats() -> { handles, interactKeys, listenEvents, listenKeys }: the hook bookkeeping (tests, debug).
function store.hookStats()
    local out = { handles = 0, interactKeys = 0, listenEvents = 0, listenKeys = 0 }
    for _ in pairs(handles) do out.handles = out.handles + 1 end
    for _ in pairs(interactBy) do out.interactKeys = out.interactKeys + 1 end
    for _, map in pairs(listen) do
        out.listenEvents = out.listenEvents + 1
        for _ in pairs(map) do out.listenKeys = out.listenKeys + 1 end
    end
    return out
end

--------------------------------------------------------------------------------
-- Persistence (§55.18, §56.6): table scene_nodes (columns + doc jsonb), counter core_counters('scene_nodes')
--------------------------------------------------------------------------------

local dirty, dirtyCount, counterDirty, flushing = {}, 0, false, false
local rowFailed = {}                -- [id] = true: its row could not be built (logged once; it stays dirty)

--- Clock-valued field paths (kind.clock: 't0', 'anim.t0', …) leave as phases: holder, key per path.
local function clockSlot(fields, path)
    local a, b = path:match('^([^.]+)%.(.+)$')
    if a then
        local holder = fields[a]
        return type(holder) == 'table' and holder or nil, b
    end
    return fields, path
end

--- Motion.rebase(desc, t): the same future with t0 at t (periodic phases folded into ph / phase / a0, a finished
--- motion an ended tween) — what a stored descriptor becomes before it is written and after it is read.
local function rebased(desc, now)
    local ok, out = pcall(Motion.rebase, desc, now)
    return (ok and type(out) == 'table') and out or desc
end

--- -> the descriptor to store (t0 removed) and its time phase `mphase` = now - t0 (0 once rebased; negative for a
--- plan that has not started). 'dr' is transient: nil.
local function motionOut(m, now)
    if not m or m.t == 'dr' then return nil end
    local out = Utils.deepCopy(rebased(m, now))
    local phase = toint(out.t0) and R.diff(now, out.t0) or nil
    out.t0 = nil
    return out, phase
end

local function motionIn(m, phase, now)
    if type(m) ~= 'table' then return nil end
    local d = Utils.deepCopy(m)
    d.t0 = toint(phase) and R.add(now, -phase) or nil
    local ok, norm = Motion.validate(d)
    return ok and rebased(norm, now) or nil
end

--- The node's scene_nodes row: kind / owner / parent / bucket are COLUMNS (a root's parent an explicit NULL, so a
--- detach overwrites the old one), everything else is `doc` (v = 1: the document shape, kept from the legacy rows).
local function rowOf(node, now)
    local fields, clk = Utils.deepCopy(node.fields), nil
    for _, path in ipairs(node.k and node.k.clock or EMPTY) do
        local holder, key = clockSlot(fields, path)
        if holder and toint(holder[key]) then
            clk = clk or {}
            clk[path], holder[key] = R.diff(now, holder[key]), nil
        end
    end
    local x, y, z, rx, ry, rz = pose(node, now)
    local derived = node.parent ~= nil or node.attach ~= nil
    local motion, mphase = motionOut(node.motion, now)
    local doc = { v = 1,
        pos = derived and { x = x, y = y, z = z } or v3(node.pos),
        rot = derived and { x = rx, y = ry, z = rz } or v3(node.rot),
        offset = v3(node.offset), offrot = v3(node.offrot), bone = node.bone,
        rotOrder = node.rotOrder, motion = motion, mphase = mphase, fields = fields, clk = clk,
        audience = V.audienceData(node.audience),
        radius = node.fixedRadius, global = node.global or nil,
        interact = node.interact and Utils.deepCopy(node.interact),
        authority = node.authority and Utils.deepCopy(node.authority), allowChildren = node.allowChildren }
    return { id = node.id, kind = node.kind, owner = node.owner, parent = node.parent or Core.DB.NULL,
        bucket = node.bucket, doc = doc }
end

local function keepDirty(id) if not dirty[id] then dirty[id], dirtyCount = true, dirtyCount + 1 end end

--- Queues every dirty row (Core.DB.save; a node that is gone or no longer persistent: Core.DB.remove) and the
--- counter. Never yields (queued writes only), so it runs in stop handlers too. While core_db is not started the
--- rest stays dirty and the coalescing thread tries again a second later; a refused row (a bug) is logged. A row
--- that cannot be BUILT (rowOf throws) costs only that node: it stays dirty, logged once (review R3a #6).
local function writeDirty()
    local DB, now, list = Core.DB, R.now(), dirty
    dirty, dirtyCount = {}, 0
    local down, refused, lastErr = false, 0, nil
    for id in pairs(list) do
        local node, ok, err = nodes[id], false, 'unavailable'
        if not down and node and node.persist then
            local built, row = pcall(rowOf, node, now)
            if built then
                rowFailed[id] = nil
                ok, err = DB.save(T_NODES, row)
            else
                if not rowFailed[id] then
                    rowFailed[id] = true
                    Log.error('scene: node %d could not be persisted (%s); it stays dirty', id, tostring(row))
                end
                ok, err = true, nil
                keepDirty(id)
            end
        elseif not down then
            rowFailed[id] = nil
            ok, err = DB.remove(T_NODES, id)
        end
        if not ok and (down or DB.errorCode(err) == 'unavailable') then
            down = true                                             -- core_db is not started: the rest stays dirty
            keepDirty(id)
        elseif not ok then
            refused, lastErr = refused + 1, err
        end
    end
    if counterDirty and not down then
        local ok, err = DB.save(T_COUNTERS, { name = COUNTER, value = nextId })
        counterDirty = not ok and DB.errorCode(err) == 'unavailable'
        if not ok and not counterDirty then refused, lastErr = refused + 1, err end
    end
    if refused > 0 then Log.error('scene: %d persistent write(s) refused: %s', refused, tostring(lastErr)) end
end
store.flush = writeDirty

--- Coalesced writes: one thread (only while something is dirty) writes every second at most.
local function markDirty(id)
    if id and not dirty[id] then
        dirty[id], dirtyCount = true, dirtyCount + 1
    end
    if flushing then return end
    flushing = true
    CreateThread(function()
        while dirtyCount > 0 or counterDirty do
            Wait(1000)
            local ok, err = pcall(writeDirty)
            if not ok then Log.error('scene: persisting nodes failed: %s', tostring(err)) end
        end
        flushing = false
    end)
end

local function touch(node)
    if node.persist then markDirty(node.id) end
end

--- R.store.settle(node, x, y, z, rx, ry, rz): a finished plan is folded into the base pose (called by the index's
--- movers sweep when Motion.finished is true): pos / rot = the end pose, no motion, a new ver, persisted, then
--- changed 'move' + 'motion' (one op per tick after coalescing). Children keep their offsets. No-op without a motion.
function store.settle(node, x, y, z, rx, ry, rz)
    if type(node) ~= 'table' or nodes[node.id] ~= node or not node.motion then return false end
    if not (isFinite(x) and isFinite(y) and isFinite(z)) then return false end
    local function c(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
    node.pos = { x = c(x, -10000, 10000), y = c(y, -10000, 10000), z = c(z, -1000, 3000) }
    node.rot = { x = V.wrap(isFinite(rx) and rx or node.rot.x), y = V.wrap(isFinite(ry) and ry or node.rot.y),
        z = V.wrap(isFinite(rz) and rz or node.rot.z) }
    setMotion(node, nil)
    driving[node.id] = nil
    bumpVer(node)
    R.index.changed(node, 'move')
    R.index.changed(node, 'motion')
    touch(node)
    fire('changed', node, 'motion')
    return true
end

--------------------------------------------------------------------------------
-- A promoted root follows its clone (§55.15 notes, D-C / D-D): R.store.follow — scene_promote only
--------------------------------------------------------------------------------

local FOLLOW_SAVE_MS <const> = 30000          -- a followed pose reaches the database at most once per 30 s per node
local FOLLOW_M2 <const>, FOLLOW_DEG <const> = 0.05 * 0.05, 1.0   -- closer than 5 cm and 1°: the same pose

--- Persists a followed node now (`now`, or its first / a 30 s old write) or once its 30 s are up (one timer per node).
local function followSave(node, now)
    if not node.persist then return end
    local id, t = node.id, R.now()
    local last = followAt[id]
    if now or last == nil or R.diff(t, last) >= FOLLOW_SAVE_MS then
        followAt[id], followLate[id] = t, nil
        return markDirty(id)
    end
    if followLate[id] then return end
    local token = {}
    followLate[id] = token
    SetTimeout(FOLLOW_SAVE_MS - R.diff(t, last), function()
        if followLate[id] ~= token or nodes[id] ~= node then return end
        followAt[id], followLate[id] = R.now(), nil
        markDirty(id)
    end)
end

local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

--- R.store.follow(node, pos, rot, bucket, persistNow) -> true | nil, err. For scene_promote only (never Core.Scene):
--- a PROMOTED root's base pose follows its clone — pos / rot = { x, y, z } (nil keeps it; a node with a motion keeps
--- its motion's pose: validated, then ignored), bucket (nil keeps it) moves the node WITH its children (the old
--- bucket's subscribers get a DEL, the new one's a PUT; ids and the children's vers kept). One change of the index
--- ('follow': re-celled with the movers' tolerance, a MOVE op or a hand-over) and a new ver; no motion, no
--- beforeChange / demotion, no hooks. Closer than 5 cm and 1° in the same bucket is no change. Persisted at most
--- once per 30 s per node (the last pose of a burst when its 30 s are up); a bucket move and persistNow at once.
--- Errors: 'missing' (not a stored node), 'parent' (a child, an attached node or a dependency), 'promoted' (not
--- promoted), 'pos' / 'rot' (not three finite numbers), 'bucket'.
function store.follow(node, pos, rot, bucket, persistNow)
    if type(node) ~= 'table' or nodes[node.id] ~= node then return nil, 'missing' end
    if node.parent or node.attach or (node.k and node.k.dependency) then return nil, 'parent' end
    if not node.promoted then return nil, 'promoted' end
    local p, r, b = node.pos, node.rot, node.bucket
    if pos ~= nil then
        local x, y, z = V.xyz(pos)
        if not x then return nil, 'pos' end
        if not node.motion then
            p = { x = clamp(x, -10000, 10000), y = clamp(y, -10000, 10000), z = clamp(z, -1000, 3000) }
        end
    end
    if rot ~= nil then
        local x, y, z = V.xyz(rot)
        if not x then return nil, 'rot' end
        if not node.motion then r = { x = V.wrap(x), y = V.wrap(y), z = V.wrap(z) } end
    end
    if bucket ~= nil then
        local err
        b, err = V.bucket(bucket)
        if not b then return nil, err end
    end
    local op, orr = node.pos or ZERO, node.rot or ZERO
    local moved = (p.x - op.x) ^ 2 + (p.y - op.y) ^ 2 + (p.z - op.z) ^ 2 > FOLLOW_M2
        or math.abs(V.wrap(r.x - orr.x)) > FOLLOW_DEG or math.abs(V.wrap(r.y - orr.y)) > FOLLOW_DEG
        or math.abs(V.wrap(r.z - orr.z)) > FOLLOW_DEG
    local rebucket = b ~= node.bucket
    if not (moved or rebucket) then
        if persistNow then followSave(node, true) end
        return true
    end
    if moved then node.pos, node.rot = p, r end
    if rebucket then
        node.bucket = b
        for i = 1, node.children and #node.children or 0 do   -- a child always shares its root's bucket
            local c = nodes[node.children[i]]
            if c then
                c.bucket = b
                touch(c)
            end
        end
    end
    bumpVer(node)
    R.index.changed(node, 'follow')
    followSave(node, persistNow or rebucket)
    return true
end

local loaded, loadBarrier, failedAt = false, nil, nil

--- Re-checks stored fields against a defined kind (fills new defaults); server-filled values are kept.
local function refit(kind, fields)
    local ok, out = K.check(kind, fields, false)
    if not ok then return fields end
    local missing = false
    for name in pairs(kind.filled or EMPTY) do
        if out[name] == nil then out[name] = fields[name] end
        missing = missing or out[name] == nil
    end
    if kind.hasModel then K.fillModel(kind, out, not missing) end   -- absent derived fields (vtype) always
    return out
end

local function depsFor(kind, fields)
    if kind and kind.builtin and kind.id == 'audio' and toId(fields.source) then return { toId(fields.source) } end
    return nil
end

--- A stored document (a row's doc with its columns folded in) -> a linked node (parents are linked before their
--- children), or nil.
local function nodeFromDoc(id, doc, now)
    if type(doc.kind) ~= 'string' or type(doc.owner) ~= 'string' then return nil end
    local k = K.get(doc.kind)
    local parent = toId(doc.parent)
    if parent and not nodes[parent] then parent = nil end          -- an orphan stays, as a root at its last pose
    local fields = type(doc.fields) == 'table' and doc.fields or {}
    for path, phase in pairs(type(doc.clk) == 'table' and doc.clk or EMPTY) do
        local holder, key = clockSlot(fields, path)
        if holder and toint(phase) then holder[key] = R.add(now, -phase) end
    end
    if k then fields = refit(k, fields) end
    local audience, aerr = V.audience(doc.audience, true)
    if aerr then                                    -- e.g. a { players } audience stored before review F8: fail closed
        audience = { editors = true }
        Log.warn('scene: node %d had an audience that cannot be restored; it is editors-only now', id)
    end
    local node = { id = id, kind = doc.kind, k = k, owner = doc.owner, bucket = V.bucket(doc.bucket) or 0,
        pos = V.pos(doc.pos) or v3(ZERO), rot = V.rot(doc.rot) or v3(ZERO), parent = parent,
        offset = parent and (V.offset(doc.offset) or v3(ZERO)) or nil,
        offrot = parent and (V.rot(doc.offrot) or v3(ZERO)) or nil, bone = parent and V.bone(doc.bone) or nil,
        rotOrder = parent and V.rotOrder(doc.rotOrder) or nil,
        motion = not parent and motionIn(doc.motion, doc.mphase, now) or nil, fields = fields,
        audience = audience, fixedRadius = isFinite(doc.radius) and doc.radius or nil,
        global = doc.global == true, persist = true, interact = V.interact(doc.interact),
        authority = V.authority(doc.authority), deps = depsFor(k, fields),
        allowChildren = V.allowChildren(doc.allowChildren) }
    node.radius = K.radius(k, node)
    node.tier = not (k and k.dependency) and K.tier(node.radius, node.global) or nil
    bumpVer(node)
    link(node)
    return node
end

--- Reads the counter (sync = true: whatever the last core queued at its stop has committed first) and every row
--- (streamed, ascending id) -> docs by id, ids ascending, the stored counter | nil, err. Nothing is linked yet.
local function readAll()
    local DB = Core.DB
    local stored, err = DB.scalar(COUNTER_SQL, { COUNTER }, { sync = true })
    if err then return nil, err end
    local docs, ids = {}, {}
    local total
    total, err = DB.stream(LOAD_SQL, {}, function(rows)
        for i = 1, #rows do
            local row = rows[i]
            local id = toId(row.id)
            if id and not docs[id] then
                local doc = type(row.doc) == 'table' and row.doc or {}
                doc.kind, doc.owner, doc.parent, doc.bucket = row.kind, row.owner, row.parent, row.bucket -- columns
                docs[id], ids[#ids + 1] = doc, id
            end
        end
    end, { batch = LOAD_BATCH })
    if not total then return nil, err end
    return docs, ids, toint(stored)
end

local function loadAll()
    local docs, ids, stored = readAll()
    if not docs then return false, ids end
    local now = R.now()                                             -- after the reads: they may have yielded
    local maxId = ids[#ids] or 0
    local made = {}
    for _ = 1, MAX_DEPTH + 2 do                                    -- parents first: at most depth + 1 passes
        for i = 1, #ids do
            local id = ids[i]
            local doc = docs[id]
            local p = toId(doc.parent)
            if not made[id] and (not p or made[p] or not docs[p] or p == id) then
                made[id] = nodeFromDoc(id, doc, now) or false
            end
        end
    end
    for i = 1, #ids do                                              -- the rest (cycles): their parents are roots now
        if made[ids[i]] == nil then made[ids[i]] = nodeFromDoc(ids[i], docs[ids[i]], now) or false end
    end
    local order = {}
    for i = 1, #ids do
        local node = made[ids[i]]
        if node and not node.parent then
            rebuildChildren(node)
            if not (node.k and node.k.dependency) then
                order[#order + 1] = node
                for j = 1, node.children and #node.children or 0 do order[#order + 1] = nodes[node.children[j]] end
            end
        end
    end
    for i = 1, #order do R.index.put(order[i]) end
    nextId = math.max(stored or 1, maxId + 1, 1)
    if nextId > ID_MAX then nextId = 1 end
    Log.debug('scene: loaded %d persistent node(s)', #ids)
    return true
end

--- The load barrier (§22): the first caller that can yield loads (the reads are awaited: a plugin's export call or
--- other non-yieldable code gets false and never starts or fails a load), everyone else waits. A failed load (never
--- an empty world, §56.8 rule 4) is retried at most every LOAD_RETRY_MS (the start thread keeps trying).
local function ensureLoaded()
    if loaded then return true end
    if loadBarrier then
        pcall(Citizen.Await, loadBarrier)
        return loaded
    end
    if not coroutine.isyieldable() then return false end
    if failedAt and R.diff(R.now(), failedAt) < LOAD_RETRY_MS then return false end
    local barrier = promise.new()
    loadBarrier = barrier
    local ok, res, err = pcall(loadAll)
    if ok and res then
        loaded = true
    else
        for _, t in ipairs({ nodes, kidsOf, dependents, byKind, byOwner, ownerCount, globalByOwner }) do
            for k in pairs(t) do t[k] = nil end                     -- a half load is dropped; the retry starts clean
        end
        count, persistCount, globalCount = 0, 0, 0
        failedAt = R.now()
        Log.error('scene: persistent nodes could not be loaded (%s); Core.Scene waits for the database',
            tostring(ok and err or res))
    end
    loadBarrier = nil
    barrier:resolve(loaded)
    return loaded
end
store.loaded = function() return loaded end

CreateThread(function()
    Wait(0)                                                          -- every server file has loaded
    while not ensureLoaded() do Wait(LOAD_RETRY_MS) end
end)

--- Core stops: what is still dirty is QUEUED now (never yields; core_db commits it after core is gone, §56.1).
AddEventHandler('onResourceStop', function(res)
    if res ~= Core.name then return end
    if dirtyCount > 0 or counterDirty then
        local ok, err = pcall(writeDirty)
        if not ok then Log.error('scene: final persist failed: %s', tostring(err)) end
        if dirtyCount > 0 or counterDirty then
            Log.error('scene: %d persistent node write(s) lost at the stop (core_db not started or a row that '
                .. 'could not be built)', dirtyCount)
        end
    end
end)

--- A kind was (re)defined or removed: its nodes are re-delivered (placeholders when it is gone).
K.onChange = function(id)
    local set = byKind[id]
    if not set then return end
    local kind = K.get(id)
    local list = {}
    for nid in pairs(set) do list[#list + 1] = nodes[nid] end
    table.sort(list, function(a, b)
        local da, db = depthOf(a), depthOf(b)
        if da ~= db then return da < db end
        return a.id < b.id
    end)
    for i = 1, #list do
        local node = list[i]
        node.k = kind
        if kind then
            node.fields = refit(kind, node.fields)
            if not kind.dependency then setDeps(node, depsFor(kind, node.fields)) end
        end
        node.radius = K.radius(kind, node)
        if not (kind and kind.dependency) then node.tier = K.tier(node.radius, node.global) end
        bumpVer(node)
        if not (kind and kind.dependency) then R.index.put(node) end
    end
    for i = 1, #list do if nodes[list[i].id] then fire('changed', list[i], 'kind') end end
end


--------------------------------------------------------------------------------
-- Counters, ids, owners — and the one-shot hand-off to server/scene.lua
--------------------------------------------------------------------------------

--- MaxNodes / the owner's cap / Global.MaxNodes / MaxPersistent (§55.4 step 8). The owner's cap is
--- Config.Scene.OwnerCaps[owner] when set (core: its map projection, attachments and parked cars), else
--- MaxNodesPerOwner. Core's reserve (Config.Scene.CoreReserve { nodes, persistent }, review RV4 F3): every other
--- owner is refused once the total would reach MaxNodes - nodes / MaxPersistent - persistent, so the last slots
--- of both stay core's whatever the plugins hold.
local function limitOk(owner, global, persist)
    local c = cfg()
    local caps, reserve = c.OwnerCaps, owner ~= 'core' and type(c.CoreReserve) == 'table' and c.CoreReserve or EMPTY
    local cap = type(caps) == 'table' and tonumber(caps[owner]) or nil
    if count >= (c.MaxNodes or 100000) - (tonumber(reserve.nodes) or 0)
        or (ownerCount[owner] or 0) >= (cap or c.MaxNodesPerOwner or 20000) then
        return false
    end
    local g = c.Global or EMPTY
    if global and (globalCount >= (g.MaxNodes or 256)
        or (owner ~= 'core' and (globalByOwner[owner] or 0) >= (g.MaxPerOwner or 64))) then return false end
    return not persist or persistCount < (c.MaxPersistent or 50000) - (tonumber(reserve.persistent) or 0)
end

--- The next free id of the one counter (ids in use are skipped after a wrap at 2^31 - 1).
local function allocId()
    for _ = 1, 4096 do
        local id = nextId
        nextId = nextId < ID_MAX and nextId + 1 or 1
        if not nodes[id] then return id end
    end
end

local function setOwner(node, owner)
    local old = node.owner
    local set = byOwner[old]
    if set then set[node.id] = nil if next(set) == nil then byOwner[old] = nil end end
    ownerCount[old] = (ownerCount[old] or 1) - 1
    if ownerCount[old] <= 0 then ownerCount[old] = nil end
    node.owner = owner
    byOwner[owner] = byOwner[owner] or {}
    byOwner[owner][node.id] = true
    ownerCount[owner] = (ownerCount[owner] or 0) + 1
    if node.global then
        globalByOwner[old] = (globalByOwner[old] or 1) - 1
        if globalByOwner[old] <= 0 then globalByOwner[old] = nil end
        globalByOwner[owner] = (globalByOwner[owner] or 0) + 1
    end
end

local function unparent(node)
    local kids = kidsOf[node.parent]
    if kids then
        kids[node.id] = nil
        if next(kids) == nil then kidsOf[node.parent] = nil end
    end
end

local function counts() return count, persistCount, globalCount end

R.storeInternal = {
    nodes = nodes, kidsOf = kidsOf, dependents = dependents, byKind = byKind, byOwner = byOwner, driving = driving,
    handles = handles, interactBy = interactBy, same = same, v3 = v3, toId = toId, isFinite = isFinite,
    ownerOk = ownerOk, bumpVer = bumpVer, copyNode = copyNode, pose = pose, rootOf = rootOf, depthOf = depthOf,
    descendants = descendants, heightOf = heightOf, rebuildChildren = rebuildChildren, link = link, unlink = unlink,
    setDeps = setDeps, depsFor = depsFor, fire = fire, ensureLoaded = ensureLoaded, touch = touch,
    markDirty = markDirty, limitOk = limitOk, allocId = allocId, setOwner = setOwner, unparent = unparent,
    setMotion = setMotion,
    counts = counts, persistNew = function() counterDirty = true end, loaded = function() return loaded end,
    netTarget = netTarget,
}
