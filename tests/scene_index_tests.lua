--[[
    core/tests/scene_index_tests.lua — offline suite for R.index (DESIGN §55.5, scene INTERFACES §4 / §7).

        lua5.4 tests/scene_index_tests.lua    (from the resource directory, or from tests/)

    A core server VM with the REAL shared/scene_codec.lua and shared/scene_motion.lua; R.kinds and R.store are fakes
    (a kind table, a node table with flattened `children`, a dependents map). Every blob is decoded with
    Codec.decode. Covers keys, tiers → grids, both near-cell variants and their versions, every op kind, the
    coalescing matrix, handovers, children order, the dependency rule, gated nodes, journals (chaining, count and
    time bounds), the pack cache (N readers, change, DR), the movers thread (2 Hz, tolerance, player / net
    attachments, finished plans to R.store.settle — older and refusing stores, the 'dr' idle rule — rebase, exit),
    events / DRs once, cellsNear / nodesIn, encode failures, and a [bench] line
    (50,000 nodes in 8 × 8 km, 1,000 random changes per tick). Exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/scene_index_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local passed, failed = 0, 0

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  [scene_index] %s%s'):format(label, detail and ('\n        ' .. detail) or ''))
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

local OFF, SPAN = 32768, 65536
local function key(cx, cy) return (cx + OFF) * SPAN + (cy + OFF) end
local NEAR, FAR, ONE = 1, 2, 3
local F = { MOTION = 1, PROMOTED = 2, PLACEHOLDER = 4, FAR = 8, INTERACT = 16, GATED = 32, CHILDREN = 64 }

-- the world of one test server ------------------------------------------------------------------------------
local W = {}   -- env, I (R.index), R, Codec, nodes, deps, kinds, positions (fake PlayerGrid), ver

local function tierFor(r, global)
    if global then return 'G' end
    if r <= 160 then return 'S' elseif r <= 448 then return 'M' end
    return 'L'
end

local function newServer(cfg)
    stubs.newWorld()
    stubs.clear()
    stubs.resetServer()
    local env = stubs.newEnv('server', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for k, v in pairs(cfg or {}) do env.Config.Scene[k] = v end
    stubs.loadFile(env, 'shared/scene_codec.lua')
    stubs.loadFile(env, 'shared/scene_motion.lua')
    local nodes, deps, kinds, positions = {}, {}, {}, {}
    local byIdx = {}
    local function def(id, idx, extra)
        local k = { id = id, idx = idx, class = 'prop', nearFields = {} }
        for name, value in pairs(extra or {}) do k[name] = value end
        kinds[id], byIdx[idx] = k, k
        return k
    end
    def('prop', 1)
    def('text', 2, { class = 'fx', nearFields = { label = true } })
    def('audio.source', 3, { class = 'audio', dependency = true })
    def('audio', 4, { class = 'audio' })
    def('group', 5, { class = 'data' })
    local Motion = env.Core.SceneMotion
    local store = {}
    function store.get(id) return nodes[id] end
    function store.dependents(id) return deps[id] end
    function store.bump(node)
        W.ver = W.ver + 1
        node.ver = W.ver
        return node.ver
    end
    function store.settle(node, x, y, z, rx, ry, rz)
        W.settled[#W.settled + 1] = { id = node.id, x = x, y = y, z = z, rx = rx, ry = ry, rz = rz }
        node.pos, node.rot, node.motion = { x = x, y = y, z = z }, { x = rx, y = ry, z = rz }, nil
        store.bump(node)
        W.I.changed(node, 'move')
        W.I.changed(node, 'motion')
        return true
    end
    function store.root(node)
        while node and node.parent do node = nodes[node.parent] end
        return node
    end
    function store.pose(node, t)
        W.poses = (W.poses or 0) + 1
        if node.parent then
            local px, py, pz = store.pose(nodes[node.parent], t)
            local o = node.offset or { x = 0, y = 0, z = 0 }
            return px + o.x, py + o.y, pz + o.z, 0.0, 0.0, 0.0
        end
        local a = node.attach
        if a and a.net then   -- A2's rule: the entity it was made with (a.ent), else the last pose seen
            -- fxlint-disable-next-line K002 -- simulates the SERVER store: the net-id guard native is client-only
            local e = env.NetworkGetEntityFromNetworkId(a.net)
            if e ~= 0 and (a.ent == nil or a.ent == e) and env.DoesEntityExist(e) then
                local c = env.GetEntityCoords(e)
                a.x, a.y, a.z = c.x, c.y, c.z
            end
            if a.x then return a.x, a.y, a.z, 0.0, 0.0, 0.0 end
        end
        local p, r = node.pos, node.rot
        return Motion.pose(p.x, p.y, p.z, r.x, r.y, r.z, node.motion, t)
    end
    function store.audienceOf(node)   -- A2's shape: nil, the one level's table, or { all = { root first … } }
        local first, list, n = nil, nil, node
        for _ = 1, 8 do
            if not n then break end
            local a = n.audience
            if a and not first then
                first = a
            elseif a and not list then
                list = { a, first }
            elseif a then
                table.insert(list, 1, a)
            end
            n = n.parent and nodes[n.parent]
        end
        if list then return { all = list } end
        return first
    end
    local R = {
        kinds = {
            get = function(id) return kinds[id] end,
            byIdx = function(idx) return byIdx[idx] end,
            tier = tierFor,
            radius = function(_, node) return node.radius or 50 end,
        },
        store = store,
    }
    env.Core.SceneRuntime = R
    env.Core.PlayerGrid = {
        positionOf = function(src)
            local p = positions[src]
            if not p then return nil end
            return p.x, p.y, p.z, 0
        end,
    }
    stubs.loadFile(env, 'server/scene_index.lua')
    W.env, W.I, W.R, W.Codec, W.nodes, W.deps, W.kinds, W.positions = env, R.index, R, env.Core.SceneCodec, nodes,
        deps, kinds, positions
    W.ver, W.nextId, W.def, W.settled = 1000, 0, def, {}
    return W.I
end

local function bump(node)
    W.ver = W.ver + 1
    node.ver = W.ver
end

--- A store-shaped node (registered in the fake store; children join the root's flattened list).
local function mk(d)
    W.nextId = W.nextId + 1
    local id = d.id or W.nextId
    local radius = d.radius or 50
    local node = { id = id, kind = d.kind or 'prop', k = W.kinds[d.kind or 'prop'], owner = 'test', bucket = d.bucket or 0,
        pos = { x = d.x or 0.0, y = d.y or 0.0, z = d.z or 0.0 }, rot = { x = 0.0, y = 0.0, z = d.h or 0.0 },
        parent = d.parent, offset = d.offset, offrot = d.offrot, motion = d.motion,
        fields = d.fields or { model = 'prop_bench_01a' }, audience = d.audience, radius = radius,
        tier = d.tier or (not (W.kinds[d.kind or 'prop'] or {}).dependency and tierFor(radius, d.global) or nil),
        global = d.global, interact = d.interact, deps = d.deps, attach = d.attach }
    if d.placeholder then node.k = nil end
    bump(node)
    W.nodes[id] = node
    local root = d.parent and W.R.store.root(node)
    if root then
        root.children = root.children or {}
        root.children[#root.children + 1] = id
    end
    for _, dep in ipairs(d.deps or {}) do
        W.deps[dep] = W.deps[dep] or {}
        W.deps[dep][id] = true
    end
    return node
end

--- mk + R.index.put (dependencies are never put by the store).
local function spawn(d)
    local node = mk(d)
    if not (node.k and node.k.dependency) then W.I.put(node) end
    return node
end

-- decoding ----------------------------------------------------------------------------------------------------

--- Decodes a blob of CELL sections / bare ops (the header is prepended here) into { ok, err, cells, ops }.
local function decode(blob)
    local out = { cells = {}, ops = {} }
    local function node(op, ctx, rec)
        rec.op, rec.section, rec.grid, rec.key, rec.variant = op, ctx.section, ctx.grid, ctx.key, ctx.variant
        out.ops[#out.ops + 1] = rec
        return rec
    end
    local h = {
        cell = function(grid, k, variant, from, to, n)
            out.cells[#out.cells + 1] = { grid = grid, key = k, variant = variant, from = from, to = to, n = n }
        end,
        put = function(id, kind, ver, parent, flags, x, y, z, rx, ry, rz, radius, extra, ctx)
            node('put', ctx, { id = id, kind = kind, ver = ver, parent = parent, flags = flags, x = x, y = y, z = z,
                rx = rx, ry = ry, rz = rz, radius = radius, extra = extra })
        end,
        set = function(id, ver, patch, ctx) node('set', ctx, { id = id, ver = ver, patch = patch }) end,
        move = function(id, ver, x, y, z, rx, ry, rz, ctx)
            node('move', ctx, { id = id, ver = ver, x = x, y = y, z = z, rx = rx, ry = ry, rz = rz })
        end,
        motion = function(id, ver, motion, ctx) node('motion', ctx, { id = id, ver = ver, motion = motion }) end,
        del = function(id, ver, how, ctx) node('del', ctx, { id = id, ver = ver, how = how }) end,
        event = function(id, t, x, y, z, name, params, ctx)
            node('event', ctx, { id = id, t = t, x = x, y = y, z = z, name = name, params = params })
        end,
        dr = function(id, t, x, y, z, vx, vy, vz, yaw, ctx)
            node('dr', ctx, { id = id, t = t, x = x, y = y, z = z, vx = vx, vy = vy, vz = vz, yaw = yaw })
        end,
        promote = function(id, ver, netId, ctx) node('promote', ctx, { id = id, ver = ver, netId = netId }) end,
        demote = function(id, ver, x, y, z, rx, ry, rz, ctx)
            node('demote', ctx, { id = id, ver = ver, x = x, y = y, z = z, rx = rx, ry = ry, rz = rz })
        end,
    }
    out.ok, out.err = W.Codec.decode(W.Codec.header(0) .. blob, h)
    return out
end

--- drain() into copies: { entries = { … }, gated = { … }, events = { … }, drs = { … } } plus every decoded op of
--- the entries in order (op.entry = its entry).
local function drain()
    local entries, gated, events, drs = W.I.drain()
    local out = { entries = {}, gated = {}, events = {}, drs = {}, ops = {} }
    for i = 1, #entries do
        local e = entries[i]
        out.entries[i] = e
        local d = decode(e.blob)
        check(d.ok, 'entry blob decodes', tostring(d.err))
        for _, op in ipairs(d.ops) do
            op.entry = e
            out.ops[#out.ops + 1] = op
        end
    end
    for i = 1, #gated do out.gated[i] = gated[i] end
    for i = 1, #events do out.events[i] = events[i] end
    for i = 1, #drs do out.drs[i] = { node = drs[i].node, blob = drs[i].blob, gate = drs[i].gate } end
    return out
end

--- The ops of `d` about node `id` (optionally only those of one variant / op kind).
local function opsOf(d, id, variant, kind)
    local list = {}
    for _, op in ipairs(d.ops) do
        if op.id == id and (variant == nil or op.variant == variant) and (kind == nil or op.op == kind) then
            list[#list + 1] = op
        end
    end
    return list
end

local function entryOf(d, grid, k, variant)
    for _, e in ipairs(d.entries) do
        if e.grid == grid and e.key == k and e.variant == variant then return e end
    end
    return nil
end

--- The PUT ids of a pack in order, and the decoded pack.
local function packIds(blob)
    local d = decode(blob)
    local ids = {}
    for _, op in ipairs(d.ops) do ids[#ids + 1] = op.op == 'put' and op.id or (op.op .. ':' .. op.id) end
    return ids, d
end

local function count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- keys --------------------------------------------------------------------------------------------------------
do
    local I = newServer()
    eq(I.keyOf(0, 0.0, 0.0), key(0, 0), 'origin is near cell (0, 0)')
    eq(I.keyOf(0, 0.0, 0.0), 32768 * 65536 + 32768, 'the §55.5 key formula')
    eq(math.type(I.keyOf(0, 10.5, -3.25)), 'integer', 'keys are integers')
    eq(I.keyOf(0, 127.999, 127.999), key(0, 0), 'just below the 128 m border')
    eq(I.keyOf(0, 128.0, 0.0), key(1, 0), 'on the border is the next cell')
    eq(I.keyOf(0, -0.001, 0.0), key(-1, 0), 'floor, not truncation')
    eq(I.keyOf(0, -128.0, -128.001), key(-1, -2), 'negative borders')
    eq(I.keyOf(1, 511.9, 512.0), key(0, 1), 'far regions are 512 m')
    eq(I.keyOf(1, -3000.0, 7000.0), key(-6, 13), 'map-scale region keys')
    eq(I.keyOf(2, 1234.0, -99.0), 0, 'the global set is key 0')
    eq(I.keyOf(0, 1e12, -1e12), key(32767, -32768), 'absurd coordinates clamp into the key range')
    eq(I.keyOf(0, 0 / 0, 0.0), nil, 'NaN has no key')
    eq(I.keyOf(0, math.huge, 0.0), nil, 'inf has no key')
    eq(I.keyOf(3, 0.0, 0.0), nil, 'grid 3 does not exist')
    eq(I.keyOf(0, '1', 0.0), nil, 'strings have no key')
    eq(I.stats().cellSize, 128.0, 'cell size from Config.Scene.CellSize')
    eq(I.stats().regionSize, 512.0, 'region size from Config.Scene.RegionSize')
    local I2 = newServer({ CellSize = 100, RegionSize = 1000 })
    eq(I2.keyOf(0, 150.0, -50.0), key(1, -1), 'a configured cell size is used')
    eq(I2.keyOf(1, 1500.0, 999.0), key(1, 0), 'a configured region size is used')
    local I3 = newServer({ CellSize = 1 })
    eq(I3.stats().cellSize, 16.0, 'the cell size is clamped to >= 16')
end

-- tiers → grids, node.cell, stats by tier ---------------------------------------------------------------------
do
    local I = newServer()
    local s = spawn({ x = 10, y = 10, radius = 100 })            -- S
    local m = spawn({ x = 20, y = 20, radius = 300 })            -- M
    local l = spawn({ x = 30, y = 30, radius = 1000 })           -- L
    local g = spawn({ x = 40, y = 40, radius = 50, global = true })
    eq(s.tier .. m.tier .. l.tier .. g.tier, 'SMLG', 'the four tiers')
    local st = I.stats()
    eq(st.nodes.S, 1, 'one S root')
    eq(st.nodes.M, 1, 'one M root')
    eq(st.nodes.L, 1, 'one L root')
    eq(st.nodes.G, 1, 'one G root')
    eq(st.cells, 3, 'a near cell, a region and the global set')
    eq(s.cell.grid .. ':' .. s.cell.key, '0:' .. key(0, 0), 'S lives in its near cell (node.cell)')
    eq(m.cell.grid, 0, 'M lives in the near grid')
    eq(l.cell.grid .. ':' .. l.cell.key, '1:' .. key(0, 0), 'L lives in its far region')
    eq(g.cell.grid .. ':' .. g.cell.key, '2:0', 'G lives in the global set')
    check(I.version(0, 0, key(0, 0), NEAR) > 0, 'the near variant has a version')
    check(I.version(0, 0, key(0, 0), FAR) > 0, 'the far variant has one (an M root)')
    check(I.version(0, 1, key(0, 0), ONE) > 0, 'the region has one')
    check(I.version(0, 2, 0, ONE) > 0, 'the global set has one')
    eq(I.version(0, 1, key(0, 0), NEAR), 0, 'a region has no NEAR variant')
    eq(I.version(0, 0, key(0, 0), ONE), 0, 'a near cell has no ONE variant')
    eq(I.version(1, 0, key(0, 0), NEAR), 0, 'buckets do not share cells')
    local d = drain()
    local pn = decode(I.pack(0, 0, key(0, 0), NEAR))
    local pf = decode(I.pack(0, 0, key(0, 0), FAR))
    eq(#pn.ops, 2, 'the near pack holds S and M')
    eq(#pf.ops, 1, 'the far pack holds the M root only')
    eq(pf.ops[1].id, m.id, '... that one')
    check(pf.ops[1].flags & F.FAR ~= 0 and pn.ops[1].flags & F.FAR == 0, 'FAR flag only in the far variant')
    eq(#decode(I.pack(0, 1, key(0, 0), ONE)).ops, 1, 'the region pack holds the L root')
    eq(decode(I.pack(0, 2, 0, ONE)).ops[1].id, g.id, 'the global pack holds the G root')
    eq(#d.entries, 4, 'the first drain has one entry per filled variant')
    local nodes = I.nodesIn(0, 0, key(0, 0))
    eq(#nodes, 2, 'nodesIn lists the near cell roots')
    eq(#I.nodesIn(0, 2, 0), 1, 'nodesIn of the global set')
    eq(#I.nodesIn(0, 0, key(5, 5)), 0, 'an empty cell lists nothing')
end

-- variants and versions -----------------------------------------------------------------------------------
do
    local I = newServer()
    local c = key(0, 0)
    local s = spawn({ x = 5, y = 5, radius = 100, kind = 'text', fields = { text = 'hi', label = 'near only' } })
    local m = spawn({ x = 6, y = 6, radius = 300, kind = 'text', fields = { text = 'far', label = 'secret' } })
    drain()
    local vn, vf = I.version(0, 0, c, NEAR), I.version(0, 0, c, FAR)
    check(vn > 0 and vf > 0 and vn ~= vf, 'two variants, two versions')
    s.fields.text = 'changed'
    bump(s)
    I.changed(s, 'set', { f = { text = 'changed' } })
    check(I.version(0, 0, c, NEAR) > vn, 'an S change bumps vNear')
    eq(I.version(0, 0, c, FAR), vf, '... never vFar')
    local d = drain()
    eq(#d.entries, 1, 'one entry for the S change')
    eq(d.entries[1].variant, NEAR, '... in the near variant')
    vn = I.version(0, 0, c, NEAR)
    m.fields.label = 'new secret'
    bump(m)
    I.changed(m, 'set', { f = { label = 'new secret' } })
    check(I.version(0, 0, c, NEAR) > vn, 'an M near-field change bumps vNear')
    eq(I.version(0, 0, c, FAR), vf, '... but not vFar')
    d = drain()
    eq(#d.entries, 1, 'only the near variant has an entry')
    eq(opsOf(d, m.id, NEAR, 'set')[1].patch.f.label, 'new secret', 'the near SET carries the near field')
    vn = I.version(0, 0, c, NEAR)
    m.fields.text = 'far change'
    bump(m)
    I.changed(m, 'set', { f = { text = 'far change' } })
    check(I.version(0, 0, c, NEAR) > vn and I.version(0, 0, c, FAR) > vf, 'an M field change bumps both')
    d = drain()
    eq(#d.entries, 2, 'both variants have an entry')
    local fset = opsOf(d, m.id, FAR, 'set')[1]
    eq(fset.patch.f.text, 'far change', 'the far SET carries the field')
    local pf = decode(I.pack(0, 0, c, FAR)).ops[1]
    eq(pf.extra.f.label, nil, 'the far pack drops nearFields')
    eq(pf.extra.f.text, 'far change', '... and keeps the others')
    eq(decode(I.pack(0, 0, c, NEAR)).ops[2] and true, true, 'the near pack has both')
    -- lazy versions: one number per tick while nobody looks, a new one after a look
    vn = I.version(0, 0, c, NEAR)
    s.fields.text = 'a'
    I.changed(s, 'set', { f = { text = 'a' } })
    local v1 = I.version(0, 0, c, NEAR)
    check(v1 > vn, 'a change after an observation takes a fresh number')
    s.fields.text = 'b'
    I.changed(s, 'set', { f = { text = 'b' } })
    check(I.version(0, 0, c, NEAR) > v1, 'version() observed v1, so the next change takes another')
    local v2 = I.version(0, 0, c, NEAR)
    d = drain()
    eq(d.entries[1].from, vn, 'the entry starts at the last drained version')
    eq(d.entries[1].to, v2, '... and ends at the current one')
    eq(#opsOf(d, s.id), 1, 'one op for the node')
    -- a change and its undo in one tick that nobody saw: no entry, the version goes back
    local before = I.version(0, 0, c, NEAR)
    local tmp = mk({ x = 7, y = 7, radius = 100 })
    I.put(tmp)
    I.remove(tmp)
    d = drain()
    eq(#d.entries, 0, 'put + remove in one tick sends nothing')
    eq(I.version(0, 0, c, NEAR), before, 'and the version did not move')
    -- ... unless someone saw the intermediate number: an empty entry moves the chain on
    local tmp2 = mk({ x = 7, y = 7, radius = 100 })
    I.put(tmp2)
    local seen = I.version(0, 0, c, NEAR)
    I.remove(tmp2)
    d = drain()
    local e = entryOf(d, 0, c, NEAR)
    check(e ~= nil and e.from == before, 'an observed number keeps the entry')
    check(e and e.to ~= before and e.to ~= seen, '... to a number that names the content again')
    eq(#d.ops, 0, '... with no ops (the PUT + DEL cancelled)')
    -- emptying a variant: to = 0; refilling never repeats a number
    local last = I.version(0, 0, c, FAR)
    I.remove(m)
    d = drain()
    e = entryOf(d, 0, c, FAR)
    check(e and e.from == last and e.to == 0, 'the emptied far variant goes to 0')
    eq(I.version(0, 0, c, FAR), 0, 'and reads 0')
    eq(opsOf(d, m.id, FAR, 'del')[1].how, 0, 'with a normal DEL')
    local m2 = spawn({ x = 6, y = 6, radius = 300 })
    d = drain()
    e = entryOf(d, 0, c, FAR)
    check(e and e.from == 0 and e.to > last, 'a refilled variant starts from 0 with a fresh number')
    eq(opsOf(d, m2.id, FAR, 'put')[1].id, m2.id, '... carrying the PUT (a snapshot from empty)')
    I.remove(s)
    I.remove(m2)
    d = drain()
    eq(I.stats().cells, 0, 'an empty cell is dropped at the drain')
    eq(entryOf(d, 0, c, NEAR).to, 0, 'after its last entry went to 0')
end

-- every op kind ---------------------------------------------------------------------------------------------
do
    local I = newServer()
    local c = key(1, 2)
    local motion = { t = 'spin', t0 = 5000, axis = 'z', dps = 90 }
    local n = spawn({ x = 150.25, y = 300.5, z = 31.07, h = 90, radius = 120, fields = { model = 'm', tint = 3 },
        motion = motion, interact = { { action = 'use', label = 'Use', distance = 2 } } })
    local d = drain()
    local put = opsOf(d, n.id, NEAR, 'put')[1]
    check(put ~= nil, 'PUT reaches the near variant')
    eq(put.section, 'cell', '... inside a CELL section')
    eq(put.key, c, '... of the node cell')
    eq(put.kind, 1, 'kind index')
    eq(put.ver, n.ver, 'ver')
    eq(put.parent, 0, 'a root has parent 0')
    eq(put.x, 150.25, 'x in cm')
    eq(put.y, 300.5, 'y')
    eq(put.z, 31.07, 'z')
    eq(put.rz, 90.0, 'heading')
    eq(put.radius, 120, 'radius in whole metres')
    eq(put.flags, F.MOTION | F.INTERACT, 'flags: motion + interact')
    eq(put.extra.f.model, 'm', 'extra.f fields')
    eq(put.extra.f.tint, 3, 'extra.f integer field')
    eq(put.extra.m.t, 'spin', 'extra.m motion')
    eq(put.extra.i[1].action, 'use', 'extra.i interact')
    eq(d.entries[1].from, 0, 'the first entry of a cell starts at 0 (a snapshot)')
    eq(d.entries[1].n, 1, 'n = its op count')
    -- SET: f, x, i (removed = false), a (false = detached), d
    n.fields.tint, n.fields.model = nil, 'm2'
    bump(n)
    I.changed(n, 'set', { f = { model = 'm2' }, x = { 'tint' } })
    d = drain()
    local set = opsOf(d, n.id, NEAR, 'set')[1]
    eq(set.patch.f.model, 'm2', 'SET f carries the new value')
    eq(set.patch.x[1], 'tint', 'SET x names the removed field')
    eq(set.ver, n.ver, 'SET ver')
    n.interact = nil
    bump(n)
    I.changed(n, 'interact')
    eq(opsOf(drain(), n.id, NEAR, 'set')[1].patch.i, false, 'a removed interact list travels as i = false')
    n.interact = { { action = 'open' } }
    I.changed(n, 'interact')
    eq(opsOf(drain(), n.id, NEAR, 'set')[1].patch.i[1].action, 'open', 'SET i is the whole list')
    -- MOVE
    n.pos = { x = 160.0, y = 310.0, z = 32.0 }
    n.rot = { x = 1.0, y = 2.0, z = -170.0 }
    bump(n)
    I.changed(n, 'move')
    d = drain()
    local mv = opsOf(d, n.id, NEAR, 'move')[1]
    check(mv and mv.x == 160.0 and mv.y == 310.0 and mv.z == 32.0, 'MOVE carries the pose')
    check(mv and mv.rx == 1.0 and mv.ry == 2.0 and mv.rz == -170.0, 'MOVE carries the rotation')
    eq(#d.ops, 1, 'a move inside the cell is one MOVE')
    -- MOTION (a descriptor, then static)
    n.motion = { t = 'osc', t0 = 7000, dir = { x = 0, y = 0, z = 1 }, amp = 0.5, period = 2000 }
    bump(n)
    I.changed(n, 'motion')
    local mo = opsOf(drain(), n.id, NEAR, 'motion')[1]
    eq(mo and mo.motion.t, 'osc', 'MOTION carries the descriptor')
    n.motion = nil
    bump(n)
    I.changed(n, 'motion')
    mo = opsOf(drain(), n.id, NEAR, 'motion')[1]
    check(mo ~= nil and mo.motion == nil, 'MOTION with an empty blob = static')
    -- PROMOTE / DEMOTE
    n.promoted = { netId = 321, entity = 77, since = 0 }
    bump(n)
    I.changed(n, 'promote', 321)
    local pr = opsOf(drain(), n.id, NEAR, 'promote')[1]
    eq(pr and pr.netId, 321, 'PROMOTE carries the netId')
    local pp = decode(I.pack(0, 0, c, NEAR)).ops[1]
    eq(pp.flags & F.PROMOTED, F.PROMOTED, 'a promoted node packs with PROMOTED')
    eq(pp.extra.n, 321, '... and extra.n = netId')
    n.promoted = nil
    n.pos = { x = 161.5, y = 311.0, z = 32.5 }
    bump(n)
    I.changed(n, 'demote')
    local de = opsOf(drain(), n.id, NEAR, 'demote')[1]
    check(de and de.x == 161.5 and de.z == 32.5, 'DEMOTE carries the rest pose')
    eq(decode(I.pack(0, 0, c, NEAR)).ops[1].flags & F.PROMOTED, 0, 'demoted: no PROMOTED flag')
    -- attach: a whole PUT (an attachment comes with a new offset / offrot / bone, which no SET patch carries)
    W.positions[7] = { x = 161, y = 311, z = 30 }
    n.attach, n.offset, n.offrot, n.bone = { player = 7 }, { x = 0, y = 0, z = 1 }, { x = 0, y = 0, z = 90 }, 31086
    bump(n)
    I.changed(n, 'attach')
    local ad = drain()
    local ap = opsOf(ad, n.id, NEAR, 'put')[1]
    eq(#opsOf(ad, n.id), 1, 'an attach is one op')
    check(ap and ap.extra.a.p == 7, 'a player attachment: a PUT with extra.a = { p = src }')
    check(ap and ap.extra.o.z == 1 and ap.extra.r.z == 90 and ap.extra.b == 31086,
        '... carrying the new offset, offrot and bone')
    -- run I1 (task 3): the rotation order rides as extra.q, only when set and not the engine's 2 — every node
    -- without one packs exactly as before
    eq(ap and ap.extra.q, nil, 'no rotOrder: no q')
    local base = entryOf(ad, 0, c, NEAR).blob
    local function attachEntry(q)
        n.rotOrder = q
        bump(n)
        I.changed(n, 'attach')
        local dq = drain()
        return opsOf(dq, n.id, NEAR, 'put')[1], entryOf(dq, 0, c, NEAR).blob
    end
    local p2, b2 = attachEntry(2)
    check(p2 ~= nil and p2.extra.q == nil, 'rotOrder 2 (the default) is not sent')
    eq(#b2, #base, '... the entry is as long as one without a rotOrder')
    local p1, b1 = attachEntry(1)
    eq(p1 and p1.extra.q, 1, 'rotOrder 1: extra.q = 1')
    eq(#b1, #base + 3, '... three bytes more (the fixstr key q and a fixint)')
    local p5 = attachEntry(5)
    eq(p5 and p5.extra.q, 5, 'rotOrder 5')
    local p0 = attachEntry(0)
    eq(p0 and p0.extra.q, 0, 'rotOrder 0 is a value: sent')
    local pk = decode(I.pack(0, 0, c, NEAR)).ops[1]
    eq(pk and pk.extra.q, 0, 'the pack carries it too')
    n.rotOrder = nil
    local ent = stubs.newEntity(2, {})
    stubs.coords[ent] = stubs.vector3(161.0, 311.0, 30.0)
    n.attach, n.offset = { net = stubs.entities[ent].netId }, { x = 0, y = 2, z = 0 }
    bump(n)
    I.changed(n, 'attach')
    ap = opsOf(drain(), n.id, NEAR, 'put')[1]
    check(ap and ap.extra.a.n == stubs.entities[ent].netId and ap.extra.o.y == 2, 'a net attachment: extra.a = { n }')
    n.attach, n.offset, n.offrot, n.bone = nil, nil, nil, nil
    bump(n)
    I.changed(n, 'attach')
    I.changed(n, 'move')
    ap = opsOf(drain(), n.id, NEAR, 'put')[1]
    check(ap and ap.extra.a == nil and ap.extra.o == nil and ap.extra.b == nil, 'detached: a PUT without a / o / b')
    I.changed(n, 'set', { a = false })
    eq(opsOf(drain(), n.id, NEAR)[1].op, 'put', "a 'set' patch naming a is a whole PUT too")
    -- DEL normal / fade
    local f1 = spawn({ x = 150, y = 300, radius = 100 })
    local f2 = spawn({ x = 151, y = 301, radius = 100 })
    drain()
    I.remove(f1, 'fade')
    I.remove(f2, W.Codec.DEL.NORMAL)
    d = drain()
    eq(opsOf(d, f1.id, NEAR, 'del')[1].how, 2, 'DEL how = fade')
    eq(opsOf(d, f2.id, NEAR, 'del')[1].how, 0, 'DEL how = normal')
    eq(opsOf(d, f1.id, NEAR, 'del')[1].ver, f1.ver, 'DEL carries the node ver')
    eq(I.remove(f1), false, 'a second remove is false')
    eq(I.changed(f1, 'move'), false, 'a change of a removed node is false')
    eq(I.put('x'), false, 'put refuses a non-node')
    eq(I.put({ id = 1.5 }), false, 'put refuses a fractional id')
end

-- events and DRs: returned once, not journaled ---------------------------------------------------------------
do
    local I = newServer()
    local n = spawn({ x = 10, y = 10, radius = 100 })
    drain()
    check(I.event(n, 10, 10, 1, 0, 'boom', { power = 3 }, 1234, 50, 1500), 'a node event is accepted')
    check(I.event(nil, 2000, -3000, 5, 7, 'flare', nil, nil, 1000, nil), 'a positional event is accepted')
    eq(I.event(nil, 0 / 0, 0, 0, 0, 'x'), false, 'a NaN position is refused')
    eq(I.event(nil, 0, 0, 0, 0, 42), false, 'a non-string name is refused')
    local d = drain()
    eq(#d.entries, 0, 'events are not cell entries')
    eq(#d.events, 2, 'both events come out')
    local e1, e2 = d.events[1], d.events[2]
    eq(e1.grid .. ':' .. e1.key .. ':' .. e1.bucket, '0:' .. key(0, 0) .. ':0', 'a node event takes the node cell')
    eq(e1.radius, 50, 'radius')
    eq(e1.horizonMs, 1500, 'horizon')
    eq(e1.t, 1234, 't')
    eq(e1.node, n, 'the node rides along (gated targets)')
    local ev = decode(e1.blob).ops[1]
    check(ev and ev.op == 'event' and ev.id == n.id and ev.name == 'boom' and ev.params.power == 3,
        'the EVENT op decodes', ev and ev.name)
    eq(ev.section, 'none', 'events are bare ops (no CELL)')
    eq(e2.grid, 1, 'a 1,000 m positional event is keyed on the far grid')
    eq(e2.key, key(3, -6), '... at its region')
    eq(e2.bucket, 7, '... in its bucket')
    eq(decode(e2.blob).ops[1].id, 0, 'a positional event has id 0')
    eq(#drain().events, 0, 'events come out once')
    -- DR: latest per node, packs dropped without a version bump
    local v = I.version(0, 0, key(0, 0), NEAR)
    local p1 = I.pack(0, 0, key(0, 0), NEAR)
    local builds = I.stats().packBuilds
    check(I.dr(n, 100, 11, 10, 1, 1, 0, 0, 90), 'dr accepted')
    n.pos = { x = 12.0, y = 10.0, z = 1.0 }
    check(I.dr(n, 150, 12, 10, 1, 2, 0, 0, 90), 'a second dr in the tick')
    eq(I.version(0, 0, key(0, 0), NEAR), v, 'a DR never bumps the version')
    local p2, v2 = I.pack(0, 0, key(0, 0), NEAR)
    eq(v2, v, 'the pack keeps its version')
    eq(I.stats().packBuilds, builds + 1, 'but it is rebuilt')
    check(p2 ~= p1, '... with the new pose')
    eq(decode(p2).ops[1].x, 12.0, 'the rebuilt pack has x = 12')
    d = drain()
    eq(#d.drs, 1, 'one DR per node per tick')
    local dr = decode(d.drs[1].blob).ops[1]
    check(dr.op == 'dr' and dr.t == 150 and dr.x == 12.0 and dr.vx == 2.0 and dr.yaw == 90.0, 'the latest DR wins')
    eq(d.drs[1].node, n, 'the DR names its node')
    eq(#d.entries, 0, 'DRs are not journaled')
    eq(#drain().drs, 0, 'DRs come out once')
    -- a driven root crossing a border: re-celled by its samples (its 'dr' plan ends 1 s after each one)
    local Clock = W.env.Core.Clock
    n.motion = { t = 'dr', t0 = Clock.now(), p = { x = 12.0, y = 10.0, z = 1.0 }, v = { x = 0, y = 0, z = 0 } }
    I.changed(n, 'motion')
    drain()
    stubs.tick(1500)
    eq(I.stats().movers, 1, 'a dr plan past its 1 s horizon stays tracked (its driver may sample again)')
    eq(#W.settled, 0, '... and is not settled')
    n.pos = { x = 150.0, y = 10.0, z = 1.0 }
    n.motion = { t = 'dr', t0 = Clock.now(), p = { x = 150.0, y = 10.0, z = 1.0 }, v = { x = 10, y = 0, z = 0 } }
    I.dr(n, Clock.now(), 150, 10, 1, 10, 0, 0, 90)
    eq(n.cell.key, key(1, 0), 'a DR sample 22 m past the border re-cells the node')
    eq(I.stats().movers, 1, '... and tracks it again')
    d = drain()
    check(opsOf(d, n.id, NEAR, 'del')[1] and opsOf(d, n.id, NEAR, 'put')[1], '... as a handover')
    eq(#d.drs, 1, '... with its DR op')
    I.dr(n, 200, 13, 10, 1, 0, 0, 0, 0)
    I.remove(n)
    d = drain()
    eq(#d.drs, 0, 'the DR of a node removed in the same tick is dropped')
    eq(I.dr(n, 1, 0, 0, 0, 0, 0, 0, 0), false, 'dr of an unknown node is false')
end

-- the coalescing matrix ---------------------------------------------------------------------------------------
do
    local I = newServer()
    local function fresh(d)
        local n = spawn(d or { x = 20, y = 20, radius = 100 })
        drain()
        return n
    end
    -- PUT absorbs later SET / MOVE / MOTION
    local a = spawn({ x = 20, y = 20, radius = 100, fields = { model = 'a' } })
    a.fields.model = 'b'
    I.changed(a, 'set', { f = { model = 'b' } })
    a.pos = { x = 21.0, y = 20.0, z = 0.0 }
    I.changed(a, 'move')
    a.motion = { t = 'spin', t0 = 0, axis = 'z', dps = 10 }
    I.changed(a, 'motion')
    local d = drain()
    local ops = opsOf(d, a.id, NEAR)
    eq(#ops, 1, 'PUT + SET + MOVE + MOTION in one tick = one op')
    check(ops[1].op == 'put' and ops[1].extra.f.model == 'b' and ops[1].x == 21.0 and ops[1].extra.m.t == 'spin',
        '... the PUT with the latest state')
    -- PUT + DEL = nothing
    local b = spawn({ x = 20, y = 20, radius = 100 })
    I.remove(b)
    eq(#opsOf(drain(), b.id), 0, 'PUT + DEL in one tick sends nothing')
    -- SET + SET merge
    local c = fresh({ x = 20, y = 20, radius = 100, fields = { model = 'm', tint = 1, lod = 5 } })
    c.fields.tint = 2
    I.changed(c, 'set', { f = { tint = 2 } })
    c.fields.lod = 9
    I.changed(c, 'set', { f = { lod = 9 } })
    ops = opsOf(drain(), c.id)
    eq(#ops, 1, 'two SETs = one')
    check(ops[1].op == 'set' and ops[1].patch.f.tint == 2 and ops[1].patch.f.lod == 9, '... merged')
    -- f then x of the same field: x
    c.fields.tint = 5
    I.changed(c, 'set', { f = { tint = 5 } })
    c.fields.tint = nil
    I.changed(c, 'set', { x = { 'tint' } })
    ops = opsOf(drain(), c.id)
    check(#ops == 1 and ops[1].patch.f == nil and ops[1].patch.x[1] == 'tint', 'a later removal cancels a set')
    -- x then f: f
    c.fields.lod = nil
    I.changed(c, 'set', { x = { 'lod' } })
    c.fields.lod = 3
    I.changed(c, 'set', { f = { lod = 3 } })
    ops = opsOf(drain(), c.id)
    check(#ops == 1 and ops[1].patch.f.lod == 3 and ops[1].patch.x == nil, 'a later set cancels a removal')
    -- a flat patch map works too
    c.fields.model = 'flat'
    I.changed(c, 'set', { model = 'flat' })
    eq(opsOf(drain(), c.id)[1].patch.f.model, 'flat', 'a flat { name = value } patch')
    -- MOVE + MOVE, MOTION + MOTION: the last
    c.pos = { x = 25.0, y = 20.0, z = 0.0 }
    I.changed(c, 'move')
    c.pos = { x = 30.0, y = 21.0, z = 0.0 }
    I.changed(c, 'move')
    ops = opsOf(drain(), c.id)
    check(#ops == 1 and ops[1].op == 'move' and ops[1].x == 30.0, 'two MOVEs = the last')
    c.motion = { t = 'spin', t0 = 0, axis = 'z', dps = 1 }
    I.changed(c, 'motion')
    c.motion = { t = 'spin', t0 = 0, axis = 'z', dps = 2 }
    I.changed(c, 'motion')
    ops = opsOf(drain(), c.id)
    check(#ops == 1 and ops[1].op == 'motion' and ops[1].motion.dps == 2, 'two MOTIONs = the last')
    -- two kinds of change = one PUT (one op per node per entry)
    c.fields.model = 'x'
    I.changed(c, 'set', { f = { model = 'x' } })
    c.pos = { x = 31.0, y = 21.0, z = 0.0 }
    I.changed(c, 'move')
    ops = opsOf(drain(), c.id)
    check(#ops == 1 and ops[1].op == 'put' and ops[1].x == 31.0 and ops[1].extra.f.model == 'x',
        'SET + MOVE = one PUT')
    -- promote then demote: the last
    c.promoted = { netId = 5 }
    I.changed(c, 'promote', 5)
    c.promoted = nil
    I.changed(c, 'demote')
    ops = opsOf(drain(), c.id)
    check(#ops == 1 and ops[1].op == 'demote', 'PROMOTE then DEMOTE = the DEMOTE')
    -- DEL wins
    c.fields.model = 'y'
    I.changed(c, 'set', { f = { model = 'y' } })
    I.changed(c, 'move')
    I.remove(c)
    ops = opsOf(drain(), c.id)
    check(#ops == 1 and ops[1].op == 'del', 'DEL wins over SET and MOVE')
    -- remove then put again in one tick (a re-index through the store): one PUT
    local e = fresh()
    I.remove(e, W.Codec.DEL.HANDOVER)
    I.put(e)
    ops = opsOf(drain(), e.id)
    check(#ops == 1 and ops[1].op == 'put', 'remove + put in one tick = one PUT')
    -- a SET that only names unchanged near fields reaches no far subscriber
    local t = fresh({ kind = 'text', x = 20, y = 20, radius = 300, fields = { text = 'a', label = 'b' } })
    t.fields.label = 'c'
    I.changed(t, 'set', { f = { label = 'c' } })
    d = drain()
    eq(#opsOf(d, t.id, FAR), 0, 'a near-field SET has no far op')
    eq(#opsOf(d, t.id, NEAR), 1, '... one near op')
end

-- handover: across cells, across grids, buckets, variants ---------------------------------------------------
do
    local I = newServer()
    local r = spawn({ x = 100, y = 10, radius = 300 })                -- M in cell (0, 0)
    local k1 = spawn({ parent = r.id, offset = { x = 1, y = 0, z = 0 } })
    local k2 = spawn({ parent = k1.id, offset = { x = 0, y = 1, z = 0 } })
    drain()
    r.pos = { x = 140.0, y = 10.0, z = 0.0 }                          -- a teleport into cell (1, 0)
    bump(r)
    I.changed(r, 'move')
    local d = drain()
    local oldN, newN = key(0, 0), key(1, 0)
    for _, id in ipairs({ r.id, k1.id, k2.id }) do
        local del = opsOf(d, id, NEAR, 'del')[1]
        local put = opsOf(d, id, NEAR, 'put')[1]
        check(del and del.key == oldN and del.how == 1, 'node ' .. id .. ': DEL(HANDOVER) in the old near cell')
        check(put and put.key == newN, 'node ' .. id .. ': PUT in the new near cell')
        check(opsOf(d, id, FAR, 'del')[1] and opsOf(d, id, FAR, 'put')[1], 'node ' .. id .. ': the far variants too')
    end
    eq(r.cell.key, newN, 'node.cell follows')
    eq(#I.nodesIn(0, 0, oldN), 0, 'the old cell is empty')
    -- the entry order in the new cell: root, then its children parent first
    local order = {}
    for _, op in ipairs(d.ops) do
        if op.op == 'put' and op.variant == NEAR then order[#order + 1] = op.id end
    end
    eq(table.concat(order, ','), table.concat({ r.id, k1.id, k2.id }, ','), 'root, child, grandchild')
    -- a tier change across grids: S/M near cell -> L region
    r.radius, r.tier = 1000, 'L'
    bump(r)
    I.put(r)
    d = drain()
    check(opsOf(d, r.id, NEAR, 'del')[1].how == 1, 'M -> L: DEL(HANDOVER) in the near cell')
    check(opsOf(d, r.id, FAR, 'del')[1].how == 1, '... and in its far variant')
    local rp = opsOf(d, r.id, ONE, 'put')[1]
    check(rp and rp.grid == 1 and rp.key == key(0, 0), '... PUT in the far region')
    check(opsOf(d, k2.id, ONE, 'put')[1] ~= nil, 'the children follow into the region')
    -- back to M, then M -> S in place: the far variant loses it with a normal DEL
    r.radius, r.tier = 300, 'M'
    I.put(r)
    drain()
    r.radius, r.tier = 100, 'S'
    I.put(r)
    d = drain()
    eq(opsOf(d, r.id, FAR, 'del')[1].how, 0, 'M -> S: DEL(NORMAL) in the far variant')
    eq(#opsOf(d, r.id, NEAR, 'del'), 0, 'no DEL in the near variant (it stays)')
    eq(opsOf(d, r.id, NEAR, 'put')[1].id, r.id, 'the near variant gets the re-sent PUT')
    -- a bucket change is a normal DEL + PUT
    r.bucket = 5
    I.put(r)
    d = drain()
    eq(opsOf(d, r.id, NEAR, 'del')[1].how, 0, 'another bucket: DEL(NORMAL)')
    eq(opsOf(d, r.id, NEAR, 'put')[1].entry.bucket, 5, 'PUT in the new bucket')
    check(I.stats().handovers >= 6, 'handovers are counted')
end

-- children: packs, flags, ops follow the root -------------------------------------------------------------------
do
    local I = newServer()
    local root = spawn({ kind = 'group', x = 10, y = 10, radius = 100 })
    local a = spawn({ parent = root.id, offset = { x = 1, y = 0, z = 0 } })
    local b = spawn({ parent = root.id, offset = { x = 2, y = 0, z = 0 } })
    local aa = spawn({ parent = a.id, offset = { x = 0, y = 1, z = 0 } })
    local d = drain()
    eq(#d.entries, 1, 'children have no entry of their own')
    eq(I.stats().kids, 3, 'three children indexed')
    eq(I.stats().roots, 1, 'one root')
    local ids, pk = packIds(I.pack(0, 0, key(0, 0), NEAR))
    eq(ids[1], root.id, 'the pack starts with the root')
    eq(#ids, 4, 'the pack carries the children')
    local pos = {}
    for i, id in ipairs(ids) do pos[id] = i end
    check(pos[a.id] < pos[aa.id], 'a parent before its child')
    local flags = {}
    for _, op in ipairs(pk.ops) do flags[op.id] = op.flags end
    eq(flags[root.id] & F.CHILDREN, F.CHILDREN, 'CHILDREN on the root')
    eq(flags[a.id] & F.CHILDREN, F.CHILDREN, 'CHILDREN on a child with a child')
    eq(flags[b.id] & F.CHILDREN, 0, 'no CHILDREN on a leaf')
    eq(pk.ops[pos[aa.id]].parent, a.id, 'a grandchild names its parent')
    eq(pk.ops[pos[a.id]].extra.o.x, 1, 'a child carries its offset (extra.o)')
    -- a child's change is emitted in the root's cell, after the root's own op
    root.fields.model = 'g2'
    I.changed(root, 'set', { f = { model = 'g2' } })
    b.fields.model = 'b2'
    I.changed(b, 'set', { f = { model = 'b2' } })
    d = drain()
    check(#d.ops == 2 and d.ops[1].id == root.id and d.ops[2].id == b.id, 'the root op first, then the child op')
    eq(d.ops[2].key, key(0, 0), 'the child op is in the root cell')
    -- a child's move is a full PUT (a new offset)
    b.offset = { x = 3, y = 0, z = 0 }
    I.changed(b, 'move')
    local bo = opsOf(drain(), b.id)[1]
    check(bo.op == 'put' and bo.extra.o.x == 3, "a child's move re-sends it with the new offset")
    -- removing a child takes its subtree
    I.remove(a)
    d = drain()
    check(opsOf(d, a.id, NEAR, 'del')[1] and opsOf(d, aa.id, NEAR, 'del')[1], 'a removed child takes its child')
    eq(#opsOf(d, b.id), 0, 'its sibling stays')
    eq(I.stats().kids, 1, 'one child left')
    -- removing the root takes everything
    I.remove(root)
    d = drain()
    check(opsOf(d, root.id, NEAR, 'del')[1] and opsOf(d, b.id, NEAR, 'del')[1], 'the root takes its children')
    eq(I.stats().kids + I.stats().roots, 0, 'nothing left')
    -- re-parenting through the store's remove(handover) + put of the subtree
    local r1 = spawn({ x = 10, y = 10, radius = 100 })
    local r2 = spawn({ x = 300, y = 10, radius = 100 })
    local c = spawn({ parent = r1.id, offset = { x = 1, y = 0, z = 0 } })
    drain()
    I.remove(c, W.Codec.DEL.HANDOVER)
    c.parent = r2.id
    r1.children = nil
    r2.children = { c.id }
    bump(c)
    I.put(c)
    d = drain()
    check(opsOf(d, c.id, NEAR, 'del')[1].key == key(0, 0) and opsOf(d, c.id, NEAR, 'del')[1].how == 1,
        're-parent: DEL(HANDOVER) in the old root cell')
    eq(opsOf(d, c.id, NEAR, 'put')[1].key, key(2, 0), '... PUT in the new root cell')
    -- a child detached into a root of its own
    I.remove(c, W.Codec.DEL.HANDOVER)
    c.parent, c.pos = nil, { x = 301.0, y = 10.0, z = 0.0 }
    r2.children = nil
    I.put(c)
    d = drain()
    local cp = opsOf(d, c.id, NEAR, 'put')[1]
    check(cp and cp.parent == 0, 'a detached child is PUT as a root')
    eq(I.stats().roots, 3, 'three roots now')
    -- a root listing children the index has not seen gets them indexed (the persistence load order)
    local lr = mk({ x = 50, y = 50, radius = 100 })
    local lk = mk({ parent = lr.id })
    I.put(lr)
    d = drain()
    check(opsOf(d, lk.id, NEAR, 'put')[1] ~= nil, "put(root) indexes the root's listed children")
    eq(I.put(mk({ parent = 999999 })), false, 'a child whose parent does not exist is refused')
end

-- dependencies (INTERFACES §7): PUT before the first dependent, SET / DEL wherever a dependent is --------------
do
    local I = newServer()
    local src = mk({ kind = 'audio.source', fields = { type = 'loop', url = 'https://x/a.ogg', volume = 1 } })
    local e1 = spawn({ kind = 'audio', x = 10, y = 10, radius = 40, fields = { source = src.id }, deps = { src.id } })
    local e2 = spawn({ kind = 'audio', x = 20, y = 20, radius = 300, fields = { source = src.id }, deps = { src.id } })
    local e3 = spawn({ kind = 'audio', x = 1000, y = 10, radius = 40, fields = { source = src.id }, deps = { src.id } })
    local d = drain()
    local near = d.ops
    local order = {}
    for _, op in ipairs(near) do
        if op.key == key(0, 0) and op.variant == NEAR then order[#order + 1] = op.id end
    end
    eq(order[1], src.id, 'the source PUT comes first in the entry')
    eq(#order, 3, 'once per entry, then both emitters')
    eq(#opsOf(d, src.id, FAR, 'put'), 1, 'the far variant (M emitter) gets the source too')
    local s3 = opsOf(d, src.id, NEAR, 'put')
    eq(#s3, 2, 'every cell with a dependent carries the source')
    eq(opsOf(d, e1.id, NEAR, 'put')[1].extra.d[1], src.id, 'an emitter lists its dependencies (extra.d)')
    eq(I.stats().deps, 0, 'the source itself has no entry')
    local ids = packIds(I.pack(0, 0, key(0, 0), NEAR))
    eq(ids[1], src.id, 'the pack carries the source before its first dependent')
    eq(#ids, 3, '... once')
    eq(packIds(I.pack(0, 0, key(7, 0), NEAR))[1], src.id, 'the other cell pack too')
    -- the store never put()s a dependency; a change of one reaches every variant holding a dependent
    src.fields.volume = 0.5
    bump(src)
    check(I.changed(src, 'set', { f = { volume = 0.5 } }), 'changed() takes an unindexed dependency')
    d = drain()
    local sets = opsOf(d, src.id, nil, 'set')
    eq(#sets, 3, 'the source SET reaches near (2 cells) and far (the M emitter)')
    eq(sets[1].patch.f.volume, 0.5, '... with the new value')
    eq(#d.ops, 3, 'nothing else')
    -- a new dependent in the same tick as a source change: the PUT (current state) instead of a SET
    src.fields.volume = 0.25
    I.changed(src, 'set', { f = { volume = 0.25 } })
    local e4 = spawn({ kind = 'audio', x = 2000, y = 10, radius = 40, fields = { source = src.id }, deps = { src.id } })
    d = drain()
    local c4 = e4.cell.key
    local inC4 = {}
    for _, op in ipairs(d.ops) do
        if op.key == c4 then inC4[#inC4 + 1] = op.op .. ':' .. op.id end
    end
    eq(table.concat(inC4, ','), 'put:' .. src.id .. ',put:' .. e4.id, 'the new cell: source PUT, emitter PUT, no SET')
    eq(#opsOf(d, src.id, nil, 'set'), 3, 'the older cells get the SET')
    -- an emitter switching to another source: the new source PUT before the SET with d
    local src2 = mk({ kind = 'audio.source', fields = { type = 'clip', url = 'https://x/b.ogg' } })
    W.deps[src.id][e1.id] = nil
    W.deps[src2.id] = { [e1.id] = true }
    e1.fields.source, e1.deps = src2.id, { src2.id }
    bump(e1)
    I.changed(e1, 'set', { f = { source = src2.id }, d = { src2.id } })
    d = drain()
    local seq = {}
    for _, op in ipairs(d.ops) do seq[#seq + 1] = op.op .. ':' .. op.id end
    eq(table.concat(seq, ','), 'put:' .. src2.id .. ',set:' .. e1.id, 'new source PUT, then the SET')
    eq(opsOf(d, e1.id, NEAR, 'set')[1].patch.d[1], src2.id, 'the SET carries d')
    -- removing a dependency with dependents left: DEL wherever they are
    check(I.remove(src2), 'a dependency can be removed (it gets a record on first use)')
    eq(I.remove(src2), false, 'a second remove in the tick is false')
    d = drain()
    eq(opsOf(d, src2.id, NEAR, 'del')[1].key, key(0, 0), 'DEL where its dependent is')
end

-- gated nodes: never in blobs --------------------------------------------------------------------------------
do
    local I = newServer()
    local pub = spawn({ x = 10, y = 10, radius = 100 })
    local gt = spawn({ x = 11, y = 11, radius = 100, audience = { players = { 1 } } })
    local kid = spawn({ parent = gt.id, offset = { x = 0, y = 0, z = 1 } })
    local d = drain()
    eq(#opsOf(d, gt.id), 0, 'a gated root never reaches a cell entry')
    eq(#opsOf(d, kid.id), 0, '... nor its children')
    eq(#d.gated, 2, 'two gated items (root, child)')
    local g1 = d.gated[1]
    eq(g1.op, 'put', 'a new gated root: put')
    eq(g1.node, gt, 'item.node = the gated root (audience, cell)')
    eq(g1.id, gt.id, 'item.id = the node the ops are about')
    local gd = decode(g1.blob)
    check(gd.ok and gd.ops[1].op == 'put' and gd.ops[1].flags & F.GATED ~= 0, 'the item blob is a bare PUT with GATED')
    eq(gd.ops[1].section, 'none', 'no CELL header')
    eq(g1.n, 1, 'n = its op count')
    eq(d.gated[2].node, gt, "a child's item names the gated ROOT")
    eq(d.gated[2].id, kid.id, "... and the child's id")
    eq(#decode(I.pack(0, 0, key(0, 0), NEAR)).ops, 1, 'the pack holds only the public node')
    eq(I.stats().gated, 1, 'one gated root')
    local gin = I.gatedIn(0, 0, key(0, 0))
    eq(#gin, 1, 'gatedIn lists it')
    eq(gin[1], gt, '... that node')
    eq(#I.nodesIn(0, 0, key(0, 0)), 2, 'nodesIn lists public and gated roots')
    local blob, n = I.gatedPut(gt)
    local gp = decode(blob)
    eq(n, 2, 'gatedPut: root + child')
    check(gp.ops[1].id == gt.id and gp.ops[2].id == kid.id, '... parent first')
    check(gp.ops[1].flags & F.GATED ~= 0 and gp.ops[2].flags & F.GATED ~= 0, '... all GATED')
    eq(select(2, I.gatedPut(pub)), 0, 'gatedPut of a public node is empty')
    -- a change: one 'set' item
    gt.fields.model = 'secret'
    I.changed(gt, 'set', { f = { model = 'secret' } })
    d = drain()
    check(#d.gated == 1 and d.gated[1].op == 'set' and decode(d.gated[1].blob).ops[1].op == 'set', 'a change: set')
    eq(#d.entries, 0, 'no cell entry for a gated change')
    -- public -> gated: DEL(HANDOVER) in the cell + a gated put
    pub.audience = { perm = 'x' }
    I.put(pub)
    d = drain()
    eq(opsOf(d, pub.id, NEAR, 'del')[1].how, 1, 'public -> gated: DEL(HANDOVER) in the cell')
    check(d.gated[1] and d.gated[1].op == 'put' and d.gated[1].id == pub.id, '... and a gated put')
    -- gated -> public: a gated del flagged public + the cell PUT
    pub.audience = nil
    I.put(pub)
    d = drain()
    check(d.gated[1] and d.gated[1].op == 'del' and d.gated[1].public == true, 'gated -> public: del, public')
    eq(decode(d.gated[1].blob).ops[1].how, 1, '... a DEL(HANDOVER)')
    check(opsOf(d, pub.id, NEAR, 'put')[1] ~= nil, '... and the cell PUT')
    -- removal: del items for the root and its child
    I.remove(gt)
    d = drain()
    eq(#d.gated, 2, 'a removed gated root: two del items')
    check(d.gated[1].op == 'del' and d.gated[1].public == nil, '... not public')
    eq(I.stats().gated, 0, 'no gated root left')
    local lone = spawn({ x = 2000, y = 2000, radius = 100, audience = { players = { 1 } } })
    drain()
    local cells = I.stats().cells
    I.remove(lone)
    drain()
    eq(I.stats().cells, cells - 1, 'a cell that only held a gated root is dropped when it leaves')
    -- a gated emitter's source travels inside its item
    local src = mk({ kind = 'audio.source', fields = { url = 'https://x/c.ogg' } })
    local ge = spawn({ kind = 'audio', x = 12, y = 12, radius = 40, fields = { source = src.id }, deps = { src.id },
        audience = { players = { 2 } } })
    d = drain()
    local items = decode(d.gated[1].blob).ops
    check(#items == 2 and items[1].id == src.id and items[2].id == ge.id, 'a gated put: source first')
    eq(d.gated[1].n, 2, '... n = 2')
    src.fields.url = 'https://x/d.ogg'
    I.changed(src, 'set', { f = { url = 'https://x/d.ogg' } })
    d = drain()
    check(d.gated[1] and d.gated[1].node == ge and d.gated[1].id == src.id, 'a source change: an item per gated emitter')
    eq(#d.entries, 0, '... no cell entry')
end

-- journals: since() chains, bounds by count and by time ----------------------------------------------------
do
    local I = newServer({ JournalOps = 3, JournalMs = 10000 })
    local c = key(0, 0)
    local n = spawn({ x = 5, y = 5, radius = 100, fields = { model = 'a', step = 0 } })
    local d = drain()
    local v = { d.entries[1].to }
    eq(d.entries[1].from, 0, 'the first entry starts at 0')
    for i = 1, 2 do
        stubs.tick(100)
        n.fields.step = i
        I.changed(n, 'set', { f = { step = i } })
        d = drain()
        v[#v + 1] = d.entries[1].to
        eq(d.entries[1].from, v[#v - 1], 'entry ' .. i .. ' chains to the previous one')
    end
    eq(I.since(0, 0, c, NEAR, v[3]), '', 'since(current) is empty (nothing to send)')
    local s1 = decode(I.since(0, 0, c, NEAR, v[2]))
    eq(#s1.cells, 1, 'since(v2) = one entry')
    check(s1.cells[1].from == v[2] and s1.cells[1].to == v[3], '... v2 -> v3')
    local s0 = decode(I.since(0, 0, c, NEAR, 0))
    eq(#s0.cells, 3, 'since(0) = the whole chain (3 entries)')
    check(s0.cells[1].to == s0.cells[2].from and s0.cells[2].to == s0.cells[3].from, 'the chain links')
    eq(s0.ops[#s0.ops].patch.f.step, 2, 'applied in order it ends at the latest state')
    eq(I.since(0, 0, c, NEAR, 12345), nil, 'an unknown version is not covered')
    eq(I.since(0, 0, c, FAR, 0), '', 'an empty variant held at 0 is current')
    eq(I.since(0, 0, c, 7, 0), nil, 'a bad variant is nil')
    eq(I.since(0, 0, c, NEAR, 1.5), nil, 'a fractional version is nil')
    -- the count bound: a 4th entry pushes the first out
    n.fields.step = 3
    I.changed(n, 'set', { f = { step = 3 } })
    drain()
    eq(I.since(0, 0, c, NEAR, 0), nil, 'JournalOps = 3: the oldest entry is gone')
    check(I.since(0, 0, c, NEAR, v[2]) ~= nil, 'the newer ones stay')
    eq(I.stats().journalEntries, 3, 'three entries kept')
    -- the time bound
    stubs.tick(10001)
    eq(I.since(0, 0, c, NEAR, v[2]), nil, 'entries older than JournalMs are not used')
    local I0 = newServer({ JournalOps = 0 })
    spawn({ x = 5, y = 5, radius = 100 })
    drain()
    eq(I0.since(0, 0, c, NEAR, 0), nil, 'JournalOps = 0 keeps nothing')
end

-- the pack cache: once for N readers, rebuilt after a change, CELL from 0 -------------------------------------
do
    local I = newServer()
    local c = key(0, 0)
    for i = 1, 5 do spawn({ x = i, y = i, radius = 100 }) end
    drain()
    local b0 = I.stats().packBuilds
    local p1, v1 = I.pack(0, 0, c, NEAR)
    for _ = 1, 20 do I.pack(0, 0, c, NEAR) end
    eq(I.stats().packBuilds, b0 + 1, 'one build serves 21 readers')
    local dp = decode(p1)
    check(dp.ok and #dp.cells == 1 and dp.cells[1].from == 0 and dp.cells[1].to == v1, 'CELL(0 -> v) header')
    eq(dp.cells[1].n, 5, 'n = 5 PUTs')
    eq(I.stats().packsCached, 1, 'one cached pack')
    local n = I.nodesIn(0, 0, c)[1]
    n.fields.model = 'changed'
    I.changed(n, 'set', { f = { model = 'changed' } })
    local p2, v2 = I.pack(0, 0, c, NEAR)
    check(v2 ~= v1 and p2 ~= p1, 'a change: new version, new pack (even before the drain)')
    eq(I.stats().packBuilds, b0 + 2, 'rebuilt once')
    local d = drain()
    eq(d.entries[1].to, v2, 'the drain ends at the number the mid-tick pack carried')
    eq(select(1, I.pack(0, 0, key(9, 9), NEAR)), '', 'an empty cell packs to ""')
    eq(select(2, I.pack(0, 0, key(9, 9), NEAR)), 0, '... at version 0')
    eq(select(2, I.pack(0, 0, c, 9)), 0, 'a bad variant packs nothing')
    -- a placeholder (kind gone) packs as kind 0 + PLACEHOLDER
    local ph = spawn({ x = 7, y = 7, radius = 100, placeholder = true })
    local op = opsOf(drain(), ph.id, NEAR, 'put')[1]
    check(op.kind == 0 and op.flags & F.PLACEHOLDER ~= 0, 'a node of an undefined kind: kind 0 + PLACEHOLDER')
    local stale = spawn({ x = 8, y = 8, radius = 100 })
    stale.k = { id = 'prop', idx = 1, nearFields = {} }             -- a kind table that is no longer registered
    I.put(stale)
    op = opsOf(drain(), stale.id, NEAR, 'put')[1]
    eq(op.kind, 0, 'a stale kind table packs as a placeholder')
end

-- unwatched variants skip the encode (R.interest.subscribers) -------------------------------------------------
do
    local I = newServer()
    local subs = {}
    W.R.interest = { subscribers = function(bucket, grid, k) return subs[grid .. ':' .. k] end }
    local c = key(0, 0)
    local n = spawn({ x = 5, y = 5, radius = 300 })
    local d = drain()
    eq(#d.entries, 0, 'nobody subscribed: no entry is encoded')
    check(I.version(0, 0, c, NEAR) > 0, 'the version still moved')
    eq(I.since(0, 0, c, NEAR, 0), nil, 'the journal has a gap (since answers nil)')
    check(I.stats().skipped >= 2, 'skips are counted')
    subs['0:' .. c] = { [1] = 2 }                                        -- one far-ring subscriber
    n.fields.model = 'x'
    I.changed(n, 'set', { f = { model = 'x' } })
    d = drain()
    eq(#d.entries, 1, 'a far-ring subscriber: the far entry only')
    eq(d.entries[1].variant, FAR, '... FAR')
    subs['0:' .. c] = { [1] = 1, [2] = 2 }
    n.fields.model = 'y'
    I.changed(n, 'set', { f = { model = 'y' } })
    eq(#drain().entries, 2, 'both rings: both entries')
end

-- cellsNear / nodesIn ----------------------------------------------------------------------------------------
do
    local I = newServer()
    spawn({ x = 10, y = 10, radius = 100 })                  -- (0, 0)
    spawn({ x = 200, y = 10, radius = 100 })                 -- (1, 0)
    spawn({ x = -300, y = -300, radius = 100 })              -- (-3, -3)
    spawn({ x = 10, y = 10, radius = 800 })                  -- region (0, 0)
    spawn({ x = 10, y = 10, radius = 100, audience = { players = { 1 } } })
    spawn({ x = 0, y = 0, radius = 10, global = true })
    local keys = I.cellsNear(0, 20, 20, 50)
    eq(#keys, 1, 'cellsNear: the cell under the point')
    eq(keys[1], key(0, 0), '... (0, 0)')
    keys = I.cellsNear(0, 20, 20, 200)
    eq(#keys, 2, 'a 200 m radius reaches (1, 0)')
    keys = I.cellsNear(0, 20, 20, 600)
    eq(#keys, 3, 'a 600 m radius reaches (-3, -3)')
    eq(#I.cellsNear(0, 20, 20, 100000), 3, 'a huge radius walks the bucket instead of the square')
    eq(#I.cellsNear(0, 20, 20, 50, 1), 1, 'the far grid')
    eq(I.cellsNear(0, 20, 20, 50, 2)[1], 0, 'the global set (key 0)')
    eq(#I.cellsNear(1, 20, 20, 50), 0, 'another bucket')
    eq(#I.cellsNear(0, 0 / 0, 20, 50), 0, 'NaN: nothing')
    eq(#I.cellsNear(0, 5000, 5000, 50), 0, 'nothing there')
    eq(#I.nodesIn(0, 0, key(0, 0)), 2, 'nodesIn: public + gated')
    eq(#I.nodesIn(0, 1, key(0, 0)), 1, 'nodesIn of a region')
    eq(#I.nodesIn(0, 0, 'x'), 0, 'a bad key lists nothing')
end

-- encode failures: logged once, skipped, never breaking the drain --------------------------------------------
do
    local I = newServer()
    local good = spawn({ x = 5, y = 5, radius = 100 })
    local bad = spawn({ x = 6, y = 6, radius = 100, fields = { model = 'm', fn = function() end } })
    local huge = spawn({ x = 7, y = 7, radius = 100, fields = { blob = string.rep('x', 70000) } })
    local d = drain()
    check(opsOf(d, good.id, NEAR, 'put')[1] ~= nil, 'a good node still goes out')
    eq(#opsOf(d, bad.id), 0, 'an unpackable node is skipped')
    eq(#opsOf(d, huge.id), 0, 'a node whose extra exceeds s2 is skipped')
    check(I.stats().encodeErrors >= 2, 'errors are counted')
    local printed = #stubs.printed
    I.pack(0, 0, key(0, 0), NEAR)
    I.pack(0, 0, key(0, 0), NEAR)
    bad.fields.model = 'n'
    I.changed(bad, 'set', { f = { model = 'n' } })
    drain()
    I.pack(0, 0, key(0, 0), NEAR)
    eq(#stubs.printed, printed, 'each failing node is logged once')
    eq(#decode(I.pack(0, 0, key(0, 0), NEAR)).ops, 1, 'the pack skips them too')
end

-- the movers thread: 2 Hz, tolerance, attachments, exit ------------------------------------------------------
do
    local I = newServer()
    local Motion, Clock = W.env.Core.SceneMotion, W.env.Core.Clock
    eq(I.stats().moverThread, false, 'no movers, no thread')
    local ok, desc = Motion.validate({ t = 'tween', t0 = Clock.now(), d = 10000, e = 'linear',
        to = { x = 400.0, y = 10.0, z = 0.0 } })
    check(ok, 'a valid tween', tostring(desc))
    local n = spawn({ x = 100, y = 10, radius = 100, motion = desc })      -- 30 m/s along +x
    eq(I.stats().movers, 1, 'a node with motion is a mover')
    eq(I.stats().moverThread, true, 'the thread exists while movers exist')
    drain()
    local calls, pose = 0, W.R.store.pose
    W.R.store.pose = function(...)
        calls = calls + 1
        return pose(...)
    end
    stubs.tick(1000)
    eq(calls, 2, 'Motion.ServerHz = 2: two evaluations per second')
    eq(n.cell.key, key(0, 0), 'x = 130: 2 m past the border stays (RecellTolerance 8)')
    eq(#drain().ops, 0, 'no ops while inside the tolerance')
    stubs.tick(500)
    eq(n.cell.key, key(1, 0), 'x = 145: 17 m past the border is re-celled')
    local d = drain()
    check(opsOf(d, n.id, NEAR, 'del')[1].how == 1 and opsOf(d, n.id, NEAR, 'put')[1].key == key(1, 0),
        'a re-cell is a handover (DEL HANDOVER + PUT)')
    eq(opsOf(d, n.id, NEAR, 'put')[1].x, 100.0, 'the PUT keeps the base pose (clients evaluate the motion)')
    eq(opsOf(d, n.id, NEAR, 'put')[1].extra.m.t, 'tween', '... and the descriptor')
    check(I.stats().recells >= 1, 're-cells are counted')
    stubs.tick(10000)
    eq(n.cell.key, key(3, 0), 'the tween ends in cell (3, 0) (x = 400)')
    eq(I.stats().movers, 0, 'a finished plan is untracked (Motion.finished)')
    eq(#W.settled, 1, 'the finished plan went to R.store.settle')
    local st = W.settled[1] or {}
    check(st.id == n.id and st.x == 400.0 and st.y == 10.0 and st.z == 0.0 and st.rz == 0.0,
        '... with its exact end pose')
    eq(n.motion, nil, '... which folded it into the base pose')
    local sd = drain()
    local sp0 = opsOf(sd, n.id, NEAR, 'put')[1]
    check(sp0 and sp0.x == 400.0 and sp0.flags & F.MOTION == 0, 'clients get a static PUT at the end pose')
    eq(#opsOf(sd, n.id, NEAR, 'motion'), 0, '... one op, no separate MOTION')
    stubs.tick(600)
    eq(I.stats().moverThread, false, '... and the thread went with the last mover')
    W.R.store.pose = pose
    -- a finished plan gets its EXACT final cell even inside the tolerance
    local ok2, short = Motion.validate({ t = 'tween', t0 = Clock.now(), d = 1000, e = 'linear',
        to = { x = 131.0, y = 10.0, z = 0.0 } })
    check(ok2, 'a short tween')
    local fin = spawn({ x = 100, y = 10, radius = 100, motion = short })
    stubs.tick(1500)
    eq(fin.cell.key, key(1, 0), 'x = 131 (3 m past the border) after the end: the exact cell')
    eq(I.stats().movers, 0, 'and untracked')
    eq(W.settled[2] and W.settled[2].x, 131.0, 'settled at x = 131')
    I.remove(fin)
    -- an older store without settle: the exact final cell, untracked, the plan stays on the node
    local settleFn = W.R.store.settle
    W.R.store.settle = nil
    local _, short2 = Motion.validate({ t = 'tween', t0 = Clock.now(), d = 1000, e = 'linear',
        to = { x = 131.0, y = 10.0, z = 0.0 } })
    local older = spawn({ x = 100, y = 10, radius = 100, motion = short2 })
    stubs.tick(1500)
    eq(older.cell.key, key(1, 0), 'no settle: the exact final cell')
    eq(I.stats().movers, 0, '... untracked')
    check(older.motion ~= nil, '... the finished plan stays on the node')
    I.remove(older)
    -- a store that refuses: one attempt per plan
    local asked = 0
    W.R.store.settle = function()
        asked = asked + 1
        return false
    end
    local _, short3 = Motion.validate({ t = 'tween', t0 = Clock.now(), d = 1000, e = 'linear',
        to = { x = 131.0, y = 10.0, z = 0.0 } })
    local refused = spawn({ x = 100, y = 10, radius = 100, motion = short3 })
    stubs.tick(3000)
    eq(asked, 1, 'a refused settle is not retried')
    eq(I.stats().movers, 0, '... the node is untracked')
    eq(refused.cell.key, key(1, 0), '... in its exact final cell')
    I.remove(refused)
    W.R.store.settle = settleFn
    -- a C2 'dr' plan "finishes" 1 s after each sample: settled only after 6 heartbeats (30 s) without one
    local drn = spawn({ x = 50, y = 50, radius = 100,
        motion = { t = 'dr', t0 = Clock.now(), p = { x = 50.0, y = 50.0, z = 0.0 }, v = { x = 0, y = 0, z = 0 } } })
    local settledBefore = #W.settled
    stubs.tick(5000)
    eq(#W.settled, settledBefore, 'a dr plan 5 s after its sample is not settled')
    eq(I.stats().movers, 1, '... and stays tracked (its driver may sample again)')
    stubs.tick(26000)
    eq(#W.settled, settledBefore + 1, 'after 30 s without a sample it is settled')
    eq(drn.motion, nil, '... into a static node')
    eq(I.stats().movers, 0, '... and untracked')
    I.remove(drn)
    -- a spin never moves the position: tracked (for rebases) but never posed
    local spins, pose2 = 0, W.R.store.pose
    W.R.store.pose = function(...)
        spins = spins + 1
        return pose2(...)
    end
    local sp = spawn({ x = 5, y = 5, radius = 100, motion = { t = 'spin', t0 = Clock.now(), axis = 'z', dps = 45 } })
    spins = 0
    stubs.tick(1000)
    eq(I.stats().parked, 1, 'a spin is parked (its box is a point: it can never leave its cell)')
    eq(I.stats().movers, 0, '... not swept')
    eq(spins, 0, '... and never posed')
    -- rebase (the real Motion.needsRebase / rebase): a plan more than 2^30 ms old gets a fresh t0 — a MOTION to
    -- clients with a new ver, the same pose
    check(type(Motion.needsRebase) == 'function' and type(Motion.rebase) == 'function', 'Motion has rebase')
    local old = Clock.add(Clock.now(), -(2 ^ 30 + 5000))
    local rb = spawn({ x = 6, y = 6, radius = 100, motion = { t = 'spin', t0 = old, axis = 'z', dps = 10 } })
    drain()
    local ver = rb.ver
    stubs.tick(500)
    check(rb.motion.t0 ~= old, 'the sweep rebased the plan')
    eq(Motion.needsRebase(rb.motion, Clock.now()), false, '... which needs no rebase any more')
    check(rb.ver > ver, '... with a new ver (R.store.bump)')
    local mo = opsOf(drain(), rb.id, NEAR, 'motion')[1]
    eq(mo and mo.motion.t0, rb.motion.t0, '... sent as a MOTION')
    eq(I.stats().parked, 2, 'the rebased spin stays parked')
    I.remove(sp)
    I.remove(rb)
    W.R.store.pose = pose
    -- attachments: a player through PlayerGrid.positionOf, a net entity through the natives
    W.positions[3] = { x = 1000.0, y = 1000.0, z = 0.0 }
    local a = spawn({ x = 0, y = 0, radius = 100, attach = { player = 3 } })
    eq(a.cell.key, key(7, 7), 'a player attachment is placed at the player')
    check(I.stats().movers == 0 and I.stats().riders == 1, "a player attachment rides in its player's group (RV4 F7)")
    local e = stubs.newEntity(2, {})
    local netId = stubs.entities[e].netId
    stubs.coords[e] = stubs.vector3(-500.0, 300.0, 0.0)
    local na = spawn({ x = 0, y = 0, radius = 100, attach = { net = netId } })
    eq(na.cell.key, key(-4, 2), 'a net attachment is placed at the entity')
    drain()
    W.positions[3] = { x = 1100.0, y = 1000.0, z = 0.0 }
    stubs.coords[e] = stubs.vector3(-505.0, 300.0, 0.0)
    stubs.tick(500)
    eq(a.cell.key, key(8, 7), 'the player moved 76 m past the border: re-celled')
    eq(na.cell.key, key(-4, 2), 'the entity moved 7 m inside its cell: stays')
    stubs.coords[e] = stubs.vector3(-530.0, 300.0, 0.0)
    stubs.tick(500)
    eq(na.cell.key, key(-5, 2), 'the entity 18 m past the border: re-celled')
    W.positions[3] = nil
    stubs.tick(500)
    eq(a.cell.key, key(8, 7), 'a player that is gone leaves the node where it was')
    stubs.entities[e].exists = false
    stubs.tick(500)
    eq(na.cell.key, key(-5, 2), 'an entity that is gone too')
    d = drain()
    check(opsOf(d, a.id, NEAR, 'put')[1] and opsOf(d, na.id, NEAR, 'put')[1], 'both handovers went out')
    -- the thread goes when the last mover goes
    I.remove(n)
    I.remove(a)
    a.attach = nil
    na.attach = nil
    I.changed(na, 'attach')
    eq(I.stats().movers, 0, 'no movers left')
    stubs.tick(600)
    eq(I.stats().moverThread, false, 'the thread exited')
    local live = { t = 'spin', t0 = Clock.now(), axis = 'z', dps = 5 }
    local g = spawn({ x = 0, y = 0, radius = 50, global = true, motion = live })
    eq(I.stats().movers, 0, 'a global node never re-cells (not a mover)')
    I.remove(g)
    drain()
    -- a new mover starts a new thread
    local m2 = spawn({ x = 5, y = 5, radius = 100, motion = live })
    eq(I.stats().moverThread, true, 'a new mover starts the thread again')
    I.remove(m2)
    stubs.tick(600)
    eq(I.stats().moverThread, false, '... and it goes again')
    eq(#stubs.failures, 0, 'no thread errors', stubs.failures[1])
end

-- review RV4 F7: player attachments ride in ONE group per player — one PlayerGrid read per player per sweep, and no
-- per-node work while the player stays inside the box where none of them could be re-celled ----------------------
do
    local I = newServer()
    local reads = 0
    local grid = W.env.Core.PlayerGrid
    local inner = grid.positionOf
    grid.positionOf = function(src)
        reads = reads + 1
        return inner(src)
    end
    W.positions[5] = { x = 60.0, y = 60.0, z = 0.0 }
    W.positions[6] = { x = 60.0, y = 300.0, z = 0.0 }
    local worn = {}
    for i = 1, 12 do worn[i] = spawn({ x = 0, y = 0, radius = i == 12 and 900 or 100, attach = { player = 5 } }) end
    local other = spawn({ x = 0, y = 0, radius = 100, attach = { player = 6 } })
    local st = I.stats()
    check(st.movers == 0 and st.riders == 2 and st.riding == 13, 'two players, 13 attachments: two rider groups')
    eq(worn[12].cell.grid, 1, 'an L attachment rides in the same group (its far region)')
    drain()
    stubs.tick(1000)                         -- the first sweeps build the boxes
    reads = 0
    local passes = I.stats().ridePasses
    stubs.tick(5000)
    eq(reads, 20, 'players standing still: ONE position read per player per sweep (2 × 2 Hz × 5 s), not 13 per sweep')
    eq(I.stats().ridePasses, passes, '... and not one re-place pass')
    W.positions[5] = { x = 130.0, y = 60.0, z = 0.0 }       -- 2 m past the border at x = 128
    stubs.tick(1000)
    eq(I.stats().ridePasses, passes, 'walking 2 m past the border (inside the re-cell tolerance): still nothing')
    local stay = 0
    for i = 1, 11 do if worn[i].cell.key == key(0, 0) then stay = stay + 1 end end
    eq(stay, 11, '... every attachment keeps its cell')
    W.positions[5] = { x = 140.0, y = 60.0, z = 0.0 }       -- 12 m past it
    stubs.tick(500)
    eq(I.stats().ridePasses, passes + 1, 'past the tolerance: ONE pass for the whole group')
    local moved = 0
    for i = 1, 11 do if worn[i].cell.key == key(1, 0) then moved = moved + 1 end end
    eq(moved, 11, '... re-celling the eleven near attachments from that one read')
    eq(worn[12].cell.key, key(0, 0), '... the far one stays in its region (512 m)')
    local d = drain()
    check(opsOf(d, worn[1].id, NEAR, 'put')[1] and opsOf(d, worn[1].id, NEAR, 'del')[1], '... hand-overs went out')
    eq(other.cell.key, key(0, 2), 'the other player (did not move) is untouched')
    worn[3].attach = { player = 6 }
    I.changed(worn[3], 'attach')
    st = I.stats()
    check(st.riders == 2 and st.riding == 13, 'an attachment that changes players changes groups')
    eq(worn[3].cell.key, key(0, 2), '... placed at its new player at once')
    for i = 1, 12 do
        worn[i].attach = nil
        I.changed(worn[i], 'attach')
    end
    I.remove(other)
    st = I.stats()
    check(st.riders == 0 and st.riding == 0 and st.movers == 0, 'detached / removed: no group is left')
    stubs.tick(600)
    eq(I.stats().moverThread, false, '... and the thread goes')
    eq(#stubs.failures, 0, 'no thread errors', stubs.failures[1])
end

-- cached PUT ops (node.opN / opF): every kind of change drops them, for roots, children and dependencies ------------
do
    local I = newServer()
    local src = mk({ kind = 'audio.source', fields = { url = 'https://x/e.ogg', volume = 1 } })
    local root = spawn({ kind = 'group', x = 10, y = 10, radius = 300 })
    local kid = spawn({ parent = root.id, offset = { x = 1, y = 0, z = 0 } })
    spawn({ kind = 'audio', x = 12, y = 12, radius = 300, fields = { source = src.id }, deps = { src.id } })
    local c = key(0, 0)
    local function prime()
        drain()
        I.pack(0, 0, c, NEAR)
        I.pack(0, 0, c, FAR)
    end
    local whats = { 'set', 'move', 'motion', 'promote', 'demote', 'interact', 'attach', 'deps', 'other' }
    for _, case in ipairs({ { 'root', root }, { 'child', kid }, { 'dependency', src } }) do
        local label, node = case[1], case[2]
        for _, what in ipairs(whats) do
            prime()
            check(node.opN ~= nil and node.opF ~= nil, ('%s %s: the caches are primed'):format(label, what))
            I.changed(node, what, what == 'set' and { f = { volume = 2 } } or nil)
            check(node.opN == nil and node.opF == nil, ('%s: %s drops both cached ops'):format(label, what))
        end
    end
    prime()
    check(I.put(kid) and kid.opN == nil, 'put() drops them')
    prime()
    I.dr(root, 1, 10, 10, 0, 0, 0, 0, 0)
    eq(root.opN, nil, 'a DR drops them (the dr plan rides in extra.m)')
    -- what the refreshed extras carry: a child's new offset / bone after 'move' and after 'attach'
    prime()
    kid.offset, kid.bone = { x = 0, y = 0, z = 2 }, 57005
    I.changed(kid, 'move')
    local kp = opsOf(drain(), kid.id, NEAR, 'put')[1]
    check(kp and kp.extra.o.z == 2 and kp.extra.b == 57005, "a child's move: a PUT with the new offset and bone")
    eq(decode(I.pack(0, 0, c, NEAR)).ops[2].extra.o.z, 2, '... and the pack has it')
    kid.offrot = { x = 0, y = 0, z = 45 }
    I.changed(kid, 'attach')
    kp = opsOf(drain(), kid.id, NEAR, 'put')[1]
    check(kp and kp.extra.r.z == 45, "a child's attach change: a PUT with the new offrot")
    local fp
    for _, op in ipairs(decode(I.pack(0, 0, c, FAR)).ops) do
        if op.id == kid.id then fp = op end
    end
    check(fp and fp.extra.r.z == 45 and fp.flags & F.FAR ~= 0, '... the far pack too')
    -- a dependency's refreshed extra reaches every new blob that carries it
    src.fields.volume = 0.3
    I.changed(src, 'set', { f = { volume = 0.3 } })
    drain()
    local sp
    for _, op in ipairs(decode(I.pack(0, 0, c, NEAR)).ops) do
        if op.id == src.id then sp = op end
    end
    check(sp and sp.extra.f.volume == 0.3, 'the pack carries the changed dependency')
    -- a near-field SET keeps the far extra (its content did not change) and drops the near one
    local t = spawn({ kind = 'text', x = 20, y = 20, radius = 300, fields = { text = 'a', label = 'b' } })
    prime()
    local farOp = t.opF
    check(farOp ~= nil and farOp ~= t.opN, 'an M node caches a near and a far op')
    t.fields.label = 'c'
    I.changed(t, 'set', { f = { label = 'c' } })
    check(t.opN == nil and t.opF == farOp, 'a near-field SET drops only the near op')
    t.fields.text = 'd'
    I.changed(t, 'set', { f = { text = 'd' } })
    eq(t.opF, nil, 'any other field drops the far one too')
end

-- true idle: R.flush.wake() once per tick while something is queued; pending() -----------------------------------
do
    local I = newServer()
    local wakes = 0
    W.R.flush = { wake = function() wakes = wakes + 1 end }
    eq(I.pending(), false, 'nothing queued: not pending')
    local n = spawn({ x = 5, y = 5, radius = 100 })
    eq(wakes, 1, 'the first change of a tick wakes the flush')
    eq(I.pending(), true, '... and the index is pending')
    n.fields.model = 'x'
    I.changed(n, 'set', { f = { model = 'x' } })
    spawn({ x = 6, y = 6, radius = 100 })
    I.event(nil, 1, 1, 1, 0, 'e')
    eq(wakes, 1, 'further work in the same tick: no second wake')
    drain()
    eq(I.pending(), false, 'a drain empties it')
    I.event(nil, 1, 1, 1, 0, 'e')
    eq(wakes, 2, 'an event alone wakes the next tick')
    eq(I.pending(), true, '... and is pending')
    drain()
    I.dr(n, 1, 5, 5, 0, 0, 0, 0, 0)
    eq(wakes, 3, 'a DR alone wakes')
    check(I.pending(), 'a DR is pending')
    drain()
    local g = spawn({ x = 7, y = 7, radius = 100, audience = { players = { 1 } } })
    eq(wakes, 4, 'a gated change wakes')
    drain()
    I.remove(g)
    eq(wakes, 5, 'a gated removal wakes')
    drain()
    local src = mk({ kind = 'audio.source', fields = { url = 'https://x/f.ogg' } })
    spawn({ kind = 'audio', x = 8, y = 8, radius = 40, fields = { source = src.id }, deps = { src.id } })
    drain()
    local w0 = wakes
    src.fields.url = 'https://x/g.ogg'
    I.changed(src, 'set', { f = { url = 'https://x/g.ogg' } })
    eq(wakes, w0 + 1, 'a dependency change wakes')
    drain()
    eq(I.pending(), false, 'idle again')
    local Clock = W.env.Core.Clock
    local _, desc = W.env.Core.SceneMotion.validate({ t = 'tween', t0 = Clock.now(), d = 2000, e = 'linear',
        to = { x = 300.0, y = 5.0, z = 0.0 } })
    local m = spawn({ x = 5, y = 5, radius = 100, motion = desc })
    drain()
    w0 = wakes
    stubs.tick(500)
    eq(wakes, w0, 'a mover inside its cell wakes nobody')
    eq(I.pending(), false, '... and queues nothing')
    stubs.tick(1000)
    check(wakes > w0 and I.pending(), 'its re-cell wakes the flush')
    drain()
    I.remove(m)
    drain()
    W.R.flush = nil
    spawn({ x = 9, y = 9, radius = 100 })
    check(I.pending(), 'without a flush module the work is still pending')
    W.R.flush = { wake = function() wakes = wakes + 1 end }
    w0 = wakes
    spawn({ x = 10, y = 10, radius = 100 })
    eq(wakes, w0 + 1, '... and the next change wakes a flush that appeared (no lost wake)')
end

-- RV1 F1: a child with its own audience is a gated unit of its own (with its subtree), whatever its root is ---------
do
    local I = newServer()
    local c = key(0, 0)
    local root = spawn({ kind = 'group', x = 10, y = 10, radius = 300 })             -- a public M root
    local pub = spawn({ parent = root.id, offset = { x = 1, y = 0, z = 0 } })
    local head = spawn({ parent = root.id, offset = { x = 2, y = 0, z = 0 }, audience = { players = { 1 } } })
    local under = spawn({ parent = head.id, offset = { x = 0, y = 1, z = 0 } })
    local nested = spawn({ parent = head.id, offset = { x = 0, y = 2, z = 0 }, audience = { perm = 'x' } })
    local deep = spawn({ parent = nested.id, offset = { x = 0, y = 0, z = 1 } })
    local function items(d)
        local byId = {}
        for _, g in ipairs(d.gated) do byId[g.id] = g end
        return byId
    end
    local d = drain()
    for _, n in ipairs({ head, under, nested, deep }) do
        eq(#opsOf(d, n.id), 0, ('gated unit node %d never enters a public entry'):format(n.id))
    end
    check(opsOf(d, pub.id, NEAR, 'put')[1] and opsOf(d, pub.id, FAR, 'put')[1], 'the public child is in both variants')
    local g = items(d)
    check(g[head.id] and g[head.id].node == head and g[head.id].op == 'put', 'the head: a put item addressed to it')
    check(g[under.id] and g[under.id].node == head, 'its child: addressed to the head')
    check(g[nested.id] and g[nested.id].node == nested, 'a nested head is a unit of its own')
    check(g[deep.id] and g[deep.id].node == nested, "... its subtree's items are addressed to it")
    check(decode(g[head.id].blob).ops[1].flags & F.GATED ~= 0, 'items carry GATED PUTs')
    local inPack = {}
    for _, id in ipairs((packIds(I.pack(0, 0, c, NEAR)))) do inPack[id] = true end
    check(inPack[root.id] and inPack[pub.id], 'the public pack: the root and its public child')
    check(not (inPack[head.id] or inPack[under.id] or inPack[nested.id] or inPack[deep.id]), '... never a gated unit')
    eq(#decode(I.pack(0, 0, c, FAR)).ops, 2, 'the far pack: root + public child')
    local gi = {}
    for _, n in ipairs(I.gatedIn(0, 0, c)) do gi[n.id] = true end
    check(gi[head.id] and gi[nested.id] and not gi[root.id], 'gatedIn lists the child heads')
    eq(#I.nodesIn(0, 0, c), 1, 'nodesIn lists roots only')
    check(head.cell and head.cell.grid == 0 and head.cell.key == c, 'a child head carries its root cell (node.cell)')
    eq(under.cell, nil, 'a node inside a unit does not')
    local gp, gn = I.gatedPut(head)
    local gids = packIds(gp)
    eq(gn, 2, 'gatedPut(head): the head and its child (the nested unit excluded)')
    check(gids[1] == head.id and gids[2] == under.id, '... head first')
    eq(select(2, I.gatedPut(nested)), 2, 'gatedPut(nested head): itself and its child')
    eq(select(2, I.gatedPut(under)), 0, 'a node that is no head: nothing')
    eq(select(2, I.gatedPut(pub)), 0, 'a public child: nothing')
    eq(I.stats().heads, 2, 'two child heads')
    -- events and DRs name their unit (the effective audience decides who hears them, F2)
    check(I.event(deep, 10, 10, 0, 0, 'ping') and I.event(pub, 10, 10, 0, 0, 'ping'), 'two events')
    I.dr(under, 1, 12, 11, 0, 0, 0, 0, 0)
    d = drain()
    eq(d.events[1].gate, nested, "an event of a gated node carries its unit head (gate)")
    eq(d.events[2].gate, nil, 'a public one does not')
    eq(d.drs[1] and d.drs[1].gate, head, 'a DR too')
    -- the root moves: the heads follow (their cell, node.cell), put items for the units, nothing public
    root.pos = { x = 140.0, y = 10.0, z = 0.0 }
    I.changed(root, 'move')
    d = drain()
    check(head.cell.key == key(1, 0) and nested.cell.key == key(1, 0), 'the heads moved with their root')
    eq(#I.gatedIn(0, 0, c), 0, 'the old cell lists no head')
    eq(#I.gatedIn(0, 0, key(1, 0)), 2, 'the new cell lists both')
    g = items(d)
    check(g[head.id] and g[head.id].op == 'put' and g[deep.id] and g[deep.id].op == 'put', 'moved units: put items')
    local leak = 0
    for _, n in ipairs({ head, under, nested, deep }) do leak = leak + #opsOf(d, n.id) end
    eq(leak, 0, 'still nothing public of the units')
    -- the head loses its audience: its unit turns public (del items + public PUTs), the nested unit stays gated
    head.audience = nil
    I.put(head)
    d = drain()
    g = items(d)
    check(g[head.id] and g[head.id].op == 'del' and g[head.id].public == true, 'a revealed head: a public del item')
    check(g[under.id] and g[under.id].op == 'del' and g[under.id].node == head, '... and its child (published head)')
    check(opsOf(d, head.id, NEAR, 'put')[1] and opsOf(d, under.id, NEAR, 'put')[1], 'both are now public')
    eq(#opsOf(d, nested.id), 0, 'the nested unit stays out of the public blob')
    eq(select(2, I.gatedPut(head)), 0, 'gatedPut of a former head: nothing')
    eq(I.stats().heads, 1, 'one head left')
    -- a public child gains an audience: a handover DEL in the public blob, put items for its unit
    under.audience = { faction = 'lspd' }
    I.put(under)
    d = drain()
    local ud = opsOf(d, under.id, NEAR, 'del')[1]
    check(ud and ud.how == 1, 'a child turning gated leaves the public blob with DEL(HANDOVER)')
    g = items(d)
    check(g[under.id] and g[under.id].op == 'put' and g[under.id].node == under, '... and enters its own unit')
    -- removing a unit: del items addressed to the head it was published under
    I.remove(nested)
    d = drain()
    g = items(d)
    check(g[nested.id] and g[nested.id].op == 'del' and g[deep.id] and g[deep.id].op == 'del', 'a removed unit: dels')
    eq(g[deep.id] and g[deep.id].node, nested, '... addressed to the published head')
    eq(I.stats().heads, 1, 'the removed head is gone')
    -- under a GATED root: a child gaining its own audience changes units (a put item to the new head)
    local groot = spawn({ x = 300, y = 300, radius = 100, audience = { players = { 3 } } })
    local gk = spawn({ parent = groot.id, offset = { x = 1, y = 0, z = 0 } })
    d = drain()
    g = items(d)
    eq(g[gk.id] and g[gk.id].node, groot, "a gated root's child belongs to the root's unit")
    gk.audience = { perm = 'y' }
    I.put(gk)
    d = drain()
    g = items(d)
    check(g[gk.id] and g[gk.id].op == 'put' and g[gk.id].node == gk, 'a nested head appears: a put item to it')
    eq(select(2, I.gatedPut(groot)), 1, "the root's unit no longer carries it")
end

-- RV1 F3: every tree operation is O(children): a root with N children scales linearly --------------------------
do
    local function best(fn)
        local b = math.huge
        for _ = 1, 3 do
            local c0 = os.clock()
            fn()
            b = math.min(b, os.clock() - c0)
        end
        return b * 1000
    end
    local function tree(N, gated)
        local I = newServer()
        local root = spawn({ kind = 'group', x = 10, y = 10, radius = 100,
            audience = gated and { players = { 1 } } or nil })
        local kids = {}
        for i = 1, N do
            kids[i] = spawn({ parent = root.id, offset = { x = i % 40 * 0.5, y = i // 40 * 0.5, z = 0 } })
        end
        drain()
        return I, root, kids
    end
    local t = {}
    for _, N in ipairs({ 500, 2000 }) do
        local I, root, kids = tree(N)
        local rop = decode(I.pack(0, 0, root.cell.key, NEAR)).ops[1]
        check(rop.id == root.id and rop.flags & F.CHILDREN ~= 0, ('N=%d: the root packs first, with CHILDREN'):format(N))
        local x = 10.0
        t['move' .. N] = best(function()                 -- handover of the whole tree (every child re-PUT)
            x = x == 10.0 and 140.0 or 10.0
            root.pos = { x = x, y = 10.0, z = 0.0 }
            I.changed(root, 'move')
            I.drain()
        end)
        t['pack' .. N] = best(function()                 -- a pack rebuild after a change of the root
            root.fields.model = 'm' .. os.clock()
            I.changed(root, 'set', { f = { model = root.fields.model } })
            I.pack(0, 0, root.cell.key, NEAR)
        end)
        t['child' .. N] = best(function()                -- one child changes: the drain touches only it
            local k = kids[1]
            k.fields.model = 'k' .. os.clock()
            I.changed(k, 'set', { f = { model = k.fields.model } })
            I.drain()
        end)
        local order = {}
        for i = 1, N do order[i] = kids[(i * 7919) % N + 1] end   -- the owner sweep's arbitrary order
        local c0 = os.clock()
        for i = 1, N do I.remove(order[i]) end
        I.remove(root)
        I.drain()
        t['stop' .. N] = (os.clock() - c0) * 1000
        eq(I.stats().kids + I.stats().roots, 0, ('N=%d: everything removed'):format(N))
        local _, groot = tree(N, true)
        t['gput' .. N] = best(function() W.I.gatedPut(groot) end)
    end
    for _, what in ipairs({ 'move', 'pack', 'child', 'stop', 'gput' }) do
        local a, b = t[what .. 500], t[what .. 2000]
        check(b < 8 * a + 2, ('%s: 4× the children costs %.1f× the time (%.2f → %.2f ms; quadratic would be 16×)')
            :format(what, b / math.max(a, 0.001), a, b))
    end
    check(t.child2000 < 5, ('one changed child of a 2,000-child root drains in %.2f ms'):format(t.child2000))
    print(('[bench] scene_index F3: root with 2,000 children — handover drain %.1f ms, pack %.1f ms, one child %.2f ms, '
        .. 'owner sweep %.1f ms, gatedPut %.1f ms'):format(t.move2000, t.pack2000, t.child2000, t.stop2000, t.gput2000))
    -- the CHILDREN flag follows the direct-children count
    local I = newServer()
    local r = spawn({ x = 5, y = 5, radius = 100 })
    local a = spawn({ parent = r.id })
    local b = spawn({ parent = a.id })
    drain()
    local fl = {}
    for _, op in ipairs(decode(I.pack(0, 0, key(0, 0), NEAR)).ops) do fl[op.id] = op.flags end
    check(fl[r.id] & F.CHILDREN ~= 0 and fl[a.id] & F.CHILDREN ~= 0 and fl[b.id] & F.CHILDREN == 0, 'CHILDREN flags')
    I.remove(b)
    drain()
    fl = {}
    for _, op in ipairs(decode(I.pack(0, 0, key(0, 0), NEAR)).ops) do fl[op.id] = op.flags end
    eq(fl[a.id] & F.CHILDREN, 0, 'a child that lost its only child: no CHILDREN flag')
end

-- RV1 F6: node vers travel as u32 serial numbers; the cell version counter wraps past 2^32 - 1 to 1 -------------
do
    local I = newServer()
    local c = key(0, 0)
    local n = spawn({ x = 5, y = 5, radius = 100 })
    drain()
    n.ver = 0x100000000 + 5
    n.fields.model = 'wrap'
    I.changed(n, 'set', { f = { model = 'wrap' } })
    local d = drain()
    eq(opsOf(d, n.id, NEAR, 'set')[1] and opsOf(d, n.id, NEAR, 'set')[1].ver, 5, 'a ver past 2^32 travels masked')
    n.ver = 0x1FFFFFFFF
    I.put(n)
    eq(opsOf(drain(), n.id, NEAR, 'put')[1].ver, 0xFFFFFFFF, 'PUT: 2^33 - 1 travels as 2^32 - 1')
    n.ver = 0x100000000
    I.remove(n, 'fade')
    eq(opsOf(drain(), n.id, NEAR, 'del')[1].ver, 0, 'DEL: 2^32 travels as 0')
    eq(I.stats().encodeErrors, 0, 'no encode errors')
    -- the version counter: move it to the end of its range (test only) and cross the wrap
    local slot, nextSeq
    for i = 1, 64 do
        local name, v = debug.getupvalue(I.version, i)
        if name == nil then break end
        if name == 'nextSeq' then nextSeq = v end
    end
    for i = 1, 64 do
        local name = debug.getupvalue(nextSeq, i)
        if name == nil then break end
        if name == 'seq' then slot = i end
    end
    check(nextSeq and slot, 'found the counter (debug, test only)')
    debug.setupvalue(nextSeq, slot, 0xFFFFFFFF - 1)
    local m = spawn({ x = 6, y = 6, radius = 100 })
    local e1 = drain().entries[1]
    m.fields.model = 'a'
    I.changed(m, 'set', { f = { model = 'a' } })
    local e2 = drain().entries[1]
    m.fields.model = 'b'
    I.changed(m, 'set', { f = { model = 'b' } })
    local e3 = drain().entries[1]
    eq(e1.to, 0xFFFFFFFF, 'the last number before the wrap')
    check(e2.from == e1.to and e2.to == 1 and e3.from == 1 and e3.to == 2, 'the counter wraps to 1 (never 0), entries chain')
    local sc = decode(I.since(0, 0, c, NEAR, e1.from))
    check(#sc.cells == 3 and sc.cells[3].to == 2, 'since() covers the wrap (versions compared for equality only)')
end

-- RV1 F19: plans that can never leave their cell are parked (never posed), woken only at their end or rebase ------
do
    local I = newServer()
    local Motion, Clock = W.env.Core.SceneMotion, W.env.Core.Clock
    local function plan(d)
        local ok, n = Motion.validate(d)
        check(ok, 'a valid ' .. d.t .. ' plan', tostring(n))
        return n
    end
    local now = Clock.now()
    local bob = spawn({ x = 60, y = 60, radius = 100,
        motion = plan({ t = 'osc', t0 = now, dir = { x = 0, y = 0, z = 1 }, amp = 0.3, period = 2000 }) })
    spawn({ x = 60, y = 60, radius = 100,
        motion = plan({ t = 'orbit', t0 = now, c = { x = 60, y = 60, z = 0 }, r = 2, period = 8000 }) })
    spawn({ x = 60, y = 60, radius = 100, motion = plan({ t = 'path', t0 = now, loop = 'loop', sp = 2, curve = 'catmull',
        pts = { { x = 50, y = 50, z = 0 }, { x = 70, y = 50, z = 0 }, { x = 70, y = 70, z = 0 } } }) })
    spawn({ x = 60, y = 60, radius = 100, motion = plan({ t = 'keys', t0 = now, loop = true,
        keys = { { t = 0, x = 60, y = 60, z = 0 }, { t = 1000, x = 64, y = 60, z = 0 }, { t = 2000, x = 60, y = 60, z = 0 } } }) })
    eq(I.stats().parked, 4, 'bounded plans (osc, orbit, looping path, looping keys) are parked')
    eq(I.stats().movers, 0, 'none is swept')
    W.poses = 0
    stubs.tick(3000)
    eq(W.poses, 0, 'a parked plan is never posed')
    local wide = spawn({ x = 60, y = 60, radius = 100,
        motion = plan({ t = 'orbit', t0 = now, c = { x = 64, y = 64, z = 0 }, r = 100, period = 60000 }) })
    eq(I.stats().movers, 1, 'an orbit wider than its cell is swept')
    -- the tolerance: a box less than RecellTolerance (8 m) past the border parks, more is swept
    local edge = spawn({ x = 125, y = 60, radius = 100,
        motion = plan({ t = 'osc', t0 = now, dir = { x = 1, y = 0, z = 0 }, amp = 7, period = 4000 }) })
    eq(I.stats().parked, 5, 'a box 4 m past the border (tolerance 8) is parked')
    spawn({ x = 125, y = 60, radius = 100,
        motion = plan({ t = 'osc', t0 = now, dir = { x = 1, y = 0, z = 0 }, amp = 12, period = 4000 }) })
    eq(I.stats().movers, 2, 'a box 9 m past it is swept')
    -- a bounded tween parks and is settled at its end by a heap wake-up (no sweeping)
    local door = spawn({ x = 30, y = 30, radius = 100,
        motion = plan({ t = 'tween', t0 = Clock.now(), d = 1000, e = 'linear', to = { x = 32.0, y = 30.0, z = 0.0 } }) })
    eq(I.stats().parked, 6, 'a door tween inside its cell is parked')
    local before = #W.settled
    stubs.tick(1600)
    eq(#W.settled, before + 1, 'at its end it is settled (heap wake-up)')
    local st = W.settled[#W.settled] or {}
    check(st.id == door.id and st.x == 32.0, '... at its end pose')
    eq(door.motion, nil, '... folded into the base pose')
    eq(I.stats().parked, 5, '... and no longer parked')
    -- a parked plan that keeps changing never grows the heap past its bound (stale entries are compacted)
    for i = 1, 400 do
        local _, m = Motion.validate({ t = 'osc', t0 = Clock.add(Clock.now(), i * 100), dir = { x = 0, y = 0, z = 1 },
            amp = 0.3, period = 2000 })
        bob.motion = m
        I.changed(bob, 'motion')
    end
    local s1 = I.stats()
    check(s1.heap <= 2 * s1.parked + 65, ('the heap stays bounded (%d entries for %d parked)'):format(s1.heap, s1.parked))
    -- a plan that is edited to leave its cell goes back to the sweep, and the other way round
    wide.motion = plan({ t = 'orbit', t0 = Clock.now(), c = { x = 60, y = 60, z = 0 }, r = 1, period = 8000 })
    I.changed(wide, 'motion')
    eq(I.stats().movers, 1, 'the narrowed orbit left the sweep')
    edge.motion = plan({ t = 'osc', t0 = Clock.now(), dir = { x = 1, y = 0, z = 0 }, amp = 30, period = 4000 })
    I.changed(edge, 'motion')
    eq(I.stats().movers, 2, 'the widened osc joined it')
    -- every plan removed: the thread goes
    for _, n in pairs(W.nodes) do
        if n.motion then I.remove(n) end
    end
    eq(I.stats().parked + I.stats().movers, 0, 'nothing tracked')
    stubs.tick(600)
    eq(I.stats().moverThread, false, 'the thread went')
    eq(I.stats().heap, 0, 'and the heap is empty')
end

-- RV1 F20 (index side): net attachments are posed by R.store.pose (identity-checked; the last pose while gone) -----
do
    local I = newServer()
    local e1 = stubs.newEntity(2, {})
    local net = stubs.entities[e1].netId
    stubs.coords[e1] = stubs.vector3(500.0, 500.0, 0.0)
    local n = spawn({ x = 0, y = 0, radius = 100, attach = { net = net, ent = e1 } })
    eq(n.cell.key, key(3, 3), 'placed at the attached entity')
    drain()
    stubs.entities[e1].exists = false                          -- the car is deleted; its net id names another one
    local e2 = stubs.newEntity(2, {})
    stubs.entities[e2].netId = net
    stubs.coords[e2] = stubs.vector3(-900.0, -900.0, 0.0)
    stubs.tick(1000)
    eq(n.cell.key, key(3, 3), 'a reused net id does not drag the node to the other entity')
end

-- RV1 F12: a pack rebuilt after one change re-encodes that node only (the others come from their op caches) -------
do
    local I = newServer()
    local list = {}
    for i = 1, 20 do list[i] = spawn({ x = i, y = i, radius = 100 }) end
    drain()
    I.pack(0, 0, key(0, 0), NEAR)
    local s0 = I.stats()
    list[5].fields.model = 'changed'
    I.changed(list[5], 'set', { f = { model = 'changed' } })
    I.pack(0, 0, key(0, 0), NEAR)
    local s1 = I.stats()
    eq(s1.opBuilds - s0.opBuilds, 1, 'the rebuilt pack encoded one PUT')
    eq(s1.opHits - s0.opHits, 19, '... and reused 19 cached ones')
    local d = drain()
    eq(#d.ops, 1, 'the entry is one SET')
    eq(I.stats().opBuilds - s1.opBuilds, 0, '... no PUT encoded for it')
end

-- RV1 F9 (index side): an entry larger than MaxEventBytes is flagged big and the pack has its version ---------------
do
    local I = newServer()
    for i = 1, 1200 do I.put(mk({ x = 1 + i % 40 * 3, y = 1 + i // 40 * 3, radius = 100 })) end
    local d = drain()
    local e = entryOf(d, 0, key(0, 0), NEAR)
    check(e and #e.blob > 16384 and e.big == true, ('a %d-byte entry is flagged big'):format(e and #e.blob or 0))
    eq(e.n, 1200, '... one entry, every op (never chained into steps)')
    local blob, v = I.pack(0, 0, key(0, 0), NEAR)
    eq(v, e.to, 'Index.pack() right after the drain has the entry version (the flush sends the pack latent)')
    eq(#decode(blob).ops, 1200, '... with every node')
    local one = W.nodes[W.nextId]
    one.fields.model = 'x'
    I.changed(one, 'set', { f = { model = 'x' } })
    eq(entryOf(drain(), 0, key(0, 0), NEAR).big, nil, 'a small entry is not flagged')
end

-- more than 65,535 ops in one cell: chained CELL sections ------------------------------------------------------
do
    local I = newServer()
    local total = 65540
    for i = 1, total do
        local node = mk({ x = 1 + (i % 100), y = 1 + (i // 100 % 100), radius = 100, fields = {} })
        I.put(node)
    end
    local entries = W.I.drain()
    eq(#entries, 1, 'one entry for the crowded cell')
    local d = decode(entries[1].blob)
    check(d.ok, 'the split entry decodes', tostring(d.err))
    eq(#d.cells, 2, 'two CELL sections (the n field is a u16)')
    eq(d.cells[1].n + d.cells[2].n, total, 'every op is in one of them')
    check(d.cells[1].from == 0 and d.cells[1].to == d.cells[2].from and d.cells[2].to == entries[1].to,
        'the sections chain from 0 to the entry version')
    local p = decode(I.pack(0, 0, key(0, 0), NEAR))
    check(p.ok and #p.cells == 2 and #p.ops == total, 'the pack splits the same way')
end

-- [bench] 50,000 nodes in 8 × 8 km, 1,000 random changes per tick -------------------------------------------------
do
    local I = newServer()
    math.randomseed(20260926)
    local rnd = math.random
    local list = {}
    collectgarbage('collect')
    local mem0 = collectgarbage('count')
    local t0 = os.clock()
    for i = 1, 50000 do
        local roll = rnd()
        local radius = roll < 0.7 and 100 or (roll < 0.95 and 300 or 1000)
        local node = mk({ x = rnd() * 8000 - 4000, y = rnd() * 8000 - 4000, z = 30, radius = radius,
            fields = { model = 'prop_bench_' .. (i % 50), tint = i % 16 } })
        I.put(node)
        list[i] = node
    end
    local putMs = (os.clock() - t0) * 1000
    t0 = os.clock()
    local first = W.I.drain()
    local fillMs, fillBytes = (os.clock() - t0) * 1000, 0
    for i = 1, #first do fillBytes = fillBytes + #first[i].blob end
    local ticks, drainMs, bytes, nEntries, worst, allocKb = 20, 0, 0, 0, 0, 0
    for _ = 1, ticks do
        for _ = 1, 1000 do
            local node = list[rnd(#list)]
            local roll = rnd()
            if roll < 0.5 then
                node.fields.tint = (node.fields.tint + 1) % 16
                I.changed(node, 'set', { f = { tint = node.fields.tint } })
            elseif roll < 0.85 then
                node.pos = { x = node.pos.x + rnd() * 40 - 20, y = node.pos.y + rnd() * 40 - 20, z = node.pos.z }
                I.changed(node, 'move')
            else
                node.motion = { t = 'spin', t0 = 0, axis = 'z', dps = rnd(10, 90) }
                I.changed(node, 'motion')
            end
        end
        collectgarbage('stop')                        -- the drain's own CPU (the 120 MB test heap's GC pauses aside)
        local k0, c0 = collectgarbage('count'), os.clock()
        local entries = W.I.drain()
        local ms = (os.clock() - c0) * 1000
        allocKb = allocKb + collectgarbage('count') - k0
        collectgarbage('restart')
        drainMs, worst = drainMs + ms, math.max(worst, ms)
        for i = 1, #entries do bytes = bytes + #entries[i].blob end
        nEntries = nEntries + #entries
        stubs.tick(50)
    end
    -- a join storm: every cell's packs built once (GC paused: what the builds allocate, the packs included)
    local seen, cellsList = {}, {}
    for i = 1, #list do
        local cl = list[i].cell
        local gk = cl and cl.grid * 4294967296 + cl.key
        if gk and not seen[gk] then
            seen[gk] = true
            cellsList[#cellsList + 1] = cl
        end
    end
    collectgarbage('collect')
    collectgarbage('stop')
    local j0, jc = collectgarbage('count'), os.clock()
    for _, cl in ipairs(cellsList) do
        if cl.grid == 0 then
            I.pack(0, 0, cl.key, NEAR)
            I.pack(0, 0, cl.key, FAR)
        else
            I.pack(0, cl.grid, cl.key, ONE)
        end
    end
    local joinKb, joinMs = collectgarbage('count') - j0, (os.clock() - jc) * 1000
    collectgarbage('restart')
    local st = I.stats()
    collectgarbage('collect')
    local heap = (collectgarbage('count') - mem0) / 1024
    print(('[bench] scene_index: 50,000 nodes (8×8 km; %d cells, S/M/L %d/%d/%d); put %.0f ms, first drain %.0f ms '
        .. '(%.1f MB); 1,000 changes/tick over %d ticks: drain %.2f ms/tick (worst %.2f, GC paused), %.0f KB '
        .. 'allocated, %d entries and %.1f KB of blobs per tick; join storm (every pack once) %.0f ms, %.1f MB '
        .. 'allocated for %.1f MB of packs; %d movers, %d parked; heap +%.1f MB with the test nodes (pure-Lua msgpack, '
        .. 'stub type())')
        :format(st.cells, st.nodes.S, st.nodes.M, st.nodes.L, putMs, fillMs, fillBytes / 1e6, ticks,
            drainMs / ticks, worst, allocKb / ticks, nEntries // ticks, bytes / ticks / 1024, joinMs, joinKb / 1024,
            st.packCacheBytes / 1048576, st.movers, st.parked, heap))
    check(#list == 50000, 'bench: the nodes are alive for the heap figure')
    check(drainMs / ticks < 500, 'bench sanity: a 1,000-change drain is well under half a second offline')
    eq(st.encodeErrors, 0, 'bench: no encode errors')
end

print(('scene_index: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
