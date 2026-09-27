-- Offline tests for Core.Maps on the client after phase D (DESIGN §55.21.1, the §52.4 client API): client/maps_preview.lua
-- (the 'map:data' handler: editor previews, the type list, the draw loop and its budgets) and client/maps.lua (the
-- facade: the uid index on C.mat.add / update / remove, handleOf / uidOf incl. promoted clones, owner-tracked holds,
-- area readiness, the editor view, stats). They run on the REAL materialiser (tests/client_scene_harness.lua: virtual
-- clock, Wait(0) = one 16 ms frame, counting native stubs, a fake cache fed with h.node + C.mat.add), and once more on
-- the real cache fed through the codec with client/scene.lua loaded last (the manifest order).
local here = arg[0]:match('^(.*)/') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads checked-in files only
local H = dofile(here .. '/client_scene_harness.lua')

local passed = 0
local function eq(actual, expected, label)
    assert(actual == expected, label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end
local function ok(cond, label)
    assert(cond, 'FAIL: ' .. label)
    passed = passed + 1
end
local function near(actual, expected, label, eps)
    assert(type(actual) == 'number' and math.abs(actual - expected) <= (eps or 1e-6),
        label .. ': expected ~' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end

local HPROP, HPROP2 = 1001, 1002
local KNOWN, LIVE = 0, 3
local FRAME = 16

--- The draw natives the harness lacks: counted, the last call's arguments kept in a reused table per native (no
--- allocation per call); label strings and DrawLine endpoints recorded only while h.recordTexts / h.recordLines.
local DRAWN <const> = { 'DrawMarker', 'DrawLine', 'SetDrawOrigin', 'ClearDrawOrigin', 'SetTextFont', 'SetTextScale',
    'SetTextColour', 'SetTextCentre', 'SetTextOutline', 'BeginTextCommandDisplayText',
    'AddTextComponentSubstringPlayerName', 'EndTextCommandDisplayText' }
local function stubDraw(h)
    h.last, h.texts, h.lines, h.markers, h.origins = {}, {}, {}, {}, {}
    h.recordTexts, h.recordLines = true, false
    for _, name in ipairs(DRAWN) do
        h.env[name] = function(...)
            h.calls[name] = (h.calls[name] or 0) + 1
            local last = h.last[name]
            if not last then
                last = {}
                h.last[name] = last
            end
            local n = select('#', ...)
            last.n = n
            for i = 1, n do last[i] = (select(i, ...)) end
            if h.recordTexts then
                if name == 'AddTextComponentSubstringPlayerName' then h.texts[#h.texts + 1] = ... end
                if name == 'SetDrawOrigin' then h.origins[#h.origins + 1] = { ... } end
                if name == 'DrawMarker' then h.markers[#h.markers + 1] = { ... } end
            end
            if h.recordLines and name == 'DrawLine' then h.lines[#h.lines + 1] = { ... } end
        end
    end
end

--- core:maps:types answered by the test: h.typeRequests[i] = { name, p } (resolve p with the list).
local function stubTypes(h)
    h.typeRequests = {}
    h.env.Core.Callback = { await = function(name)
        local p = h.env.promise.new()
        h.typeRequests[#h.typeRequests + 1] = { name = name, p = p }
        return h.env.Citizen.Await(p)
    end }
end

--- A prop handler for the real materialiser: stub entities, no update() (the materialiser moves them in place).
local function propHandler(h)
    local hd = { class = 'prop', budget = 'props', fade = 'engine', created = 0, destroyed = 0 }
    function hd.assets(node) return { { type = 'model', hash = node.fields.model } } end
    function hd.create(node, ctx)
        hd.created = hd.created + 1
        return h.newEntity(node.fields.model, ctx.x, ctx.y, ctx.z, 3)
    end
    function hd.destroy() hd.destroyed = hd.destroyed + 1 end
    return hd
end

local current
--- Stops the previous VM (its threads share the stub scheduler) and builds a new one: harness + materialiser + the
--- test prop handler + client/maps_preview.lua + client/maps.lua, in the manifest order.
local function fresh(o)
    o = o or {}
    if current then
        eq(table.concat(current.warnings, ' | '), '', 'the previous VM logged no warning')
        current.stubs.triggerOn(current.env, 'onClientResourceStop', 0, 'core')
        current.tick(1000)
    end
    local h = H.new()
    h.env.Config.Maps.MaxMarkers = o.maxMarkers or 64
    stubDraw(h)
    stubTypes(h)
    h.bagHandlers, h.bagFns = 0, {}
    h.env.AddStateBagChangeHandler = function(key, bag, fn)
        h.bagHandlers = h.bagHandlers + 1
        h.bagFns[tostring(key) .. '@' .. tostring(bag)] = fn
        return 0
    end
    if o.pending ~= nil then h.env.GlobalState['core:mapsPending'] = o.pending end
    h.cacheReady = true
    h.cache.areaReady = function() return h.cacheReady end
    h.reports = 0
    h.C.focus.reportSoon = function() h.reports = h.reports + 1 end
    h.loadMat()
    h.prop = propHandler(h)
    h.C.mat.registerKind('prop', h.prop)
    h.load('client/maps_preview.lua')
    h.load('client/maps.lua')
    h.Maps, h.M, h.P, h.Registry = h.env.Core.Maps, h.C.mat, h.C.mapsPreview, h.env.Core.Registry
    current = h
    return h, h.Maps, h.M
end

local function settle(h, ms) h.tick(ms or 1500) end
--- A map prop node (fields.mapEl = uid) added through C.mat.add like the cache does.
local function addProp(h, id, uid, x, y, z, extra)
    local node = h.node(id, 'prop', 'prop', x, y, z, { model = HPROP, mapEl = uid }, extra)
    h.M.add(node)
    return node
end
--- A map:data node (points, zones, helpers, placeholders).
local function addData(h, id, fields, x, y, z, extra)
    local node = h.node(id, 'map:data', 'data', x, y, z, fields, extra)
    h.M.add(node)
    return node
end
local function as(h, owner, fn, ...)
    h.Registry.setCaller(owner)
    local a, b = fn(...)
    h.Registry.setCaller('core')
    return a, b
end

-- 1. shape, load order, nothing of the §52 wire left -----------------------------------------------------------------
do
    local h, Maps = fresh()
    for _, fn in ipairs({ 'isAreaReady', 'waitAreaReady', 'handleOf', 'uidOf', 'hold', 'release', 'setEditorView',
        'stats' }) do
        eq(type(Maps[fn]), 'function', 'Core.Maps.' .. fn)
    end
    eq(type(h.P.setEditor), 'function', 'the preview hand-off: setEditor')
    eq(type(h.P.stats), 'function', 'the preview hand-off: stats')
    eq(rawget(h.env, 'CoreMapsEngine'), nil, 'no §52 engine hand-off global any more')
    eq(rawget(h.env.Core, 'mapsPreview'), nil, 'nothing internal on Core')
    for name in pairs(h.env.__vm.netEvents) do
        ok(not name:find('^core:maps:'), 'no core:maps:* net event registered (' .. name .. ')')
    end
    for name in pairs(h.env.__vm.handlers) do
        ok(not name:find('^core:maps:'), 'no core:maps:* handler (' .. name .. ')')
    end
    eq(h.env.__vm.netEvents['core:client:bucketChanged'], nil, 'bucket changes are the scene focus reporter\'s now')
    eq(h.bagHandlers, 1, 'one state-bag handler (no mapCfg / mapEl any more)')
    eq(type(h.bagFns['core:mapsPending@global']), 'function', 'it is the global core:mapsPending (the server\'s queue)')
    local s = Maps.stats()
    eq(s.elements, 0, 'stats: no elements yet')
    eq(s.editorView, false, 'stats: editor view off')
    eq(s.objects, nil, 'stats: no objects field (the scene counts map props against its own cap)')
    eq(s.hides, nil, 'stats: no hides field (map hides are scene hides)')
    -- load order: each file asserts its predecessor
    local bare = H.new()
    local okP, errP = pcall(bare.load, 'client/maps_preview.lua')
    ok(not okP and tostring(errP):find('maps_preview.lua loads after', 1, true) ~= nil,
        'client/maps_preview.lua asserts the materialiser before it (' .. tostring(errP) .. ')')
    local noPreview = H.new()
    noPreview.loadMat()
    local okM, errM = pcall(noPreview.load, 'client/maps.lua')
    ok(not okM and tostring(errM):find('maps_preview.lua', 1, true) ~= nil,
        'client/maps.lua asserts client/maps_preview.lua right before it (' .. tostring(errM) .. ')')
    noPreview.stubs.triggerOn(noPreview.env, 'onClientResourceStop', 0, 'core')   -- its materialiser thread ends
    current = h
end

-- 2. the uid index: handleOf / uidOf through C.mat.add / update / remove ------------------------------------------
do
    local h, Maps, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local n1 = addProp(h, 1, 'm1:1', 0, 20, 0)
    local n2 = h.node(2, 'prop', 'prop', 3, 20, 0, { model = HPROP })          -- a scene prop, no map element
    M.add(n2)
    eq(Maps.stats().elements, 1, 'one map element indexed as soon as the materialiser hears of it')
    eq(Maps.handleOf('m1:1'), nil, 'no entity before it is materialised')
    settle(h)
    local e1, e2 = M.handleOf(1), M.handleOf(2)
    ok(e1 ~= nil and e2 ~= nil, 'both props are LIVE on the real materialiser')
    eq(Maps.handleOf('m1:1'), e1, 'handleOf(uid) = the node\'s local copy')
    eq(Maps.uidOf(e1), 'm1:1', 'uidOf(entity) = fields.mapEl of its node')
    eq(Maps.uidOf(e2), nil, 'a scene node without mapEl is no map element')
    eq(Maps.handleOf('m1:2'), nil, 'an unknown uid')
    for _, bad in ipairs({ false, 5, 1.5, '', string.rep('x', 129), {} }) do
        eq(Maps.handleOf(bad), nil, 'handleOf refuses ' .. tostring(bad))
    end
    for _, bad in ipairs({ 0, 1.5, 'x', false, 424242 }) do
        eq(Maps.uidOf(bad), nil, 'uidOf refuses / does not know ' .. tostring(bad))
    end
    local s = Maps.stats()
    eq(s.elements, 1, 'stats.elements')
    eq(s.spawned, 1, 'stats.spawned: map elements with a local entity')
    eq(type(s.queued), 'number', 'stats.queued: the scene\'s queue')
    -- mapEl changes on a fields update (never expected from the projector, but the index follows it)
    n1.fields = { model = HPROP, mapEl = 'm1:9' }
    M.update(n1, 'fields', { mapEl = true })
    eq(Maps.handleOf('m1:1'), nil, 'the old uid is gone')
    eq(Maps.handleOf('m1:9'), e1, 'the new uid answers the same entity')
    eq(Maps.uidOf(e1), 'm1:9', 'uidOf follows')
    eq(Maps.stats().elements, 1, 'still one element')
    -- a handover (DEL handover + PUT of the same id in one payload) keeps the index and the entity
    M.remove(n1, 'handover')
    eq(Maps.stats().elements, 0, 'between the handover DEL and the PUT the uid is no element')
    eq(Maps.handleOf('m1:9'), e1, 'but the kept entity still answers for it (it stands)')
    M.add(n1)
    eq(Maps.handleOf('m1:9'), e1, 'the PUT of the same id: the same entity again')
    eq(Maps.stats().elements, 1, 'an element again')
    -- removal: no element any more at once; the entity goes through the materialiser and keeps its uid while it
    -- stands (review RV5 F3)
    M.remove(n1)
    eq(Maps.stats().elements, 0, 'no elements left')
    eq(Maps.handleOf('m1:9'), e1, 'removed, still standing: handleOf answers its copy')
    eq(Maps.uidOf(e1), 'm1:9', 'and uidOf maps it back (never world geometry for the editor)')
    h.cam(0, 0, 0, 0, 180)                            -- looking away: deleted once unseen (1.5 s), not deferred
    settle(h, 2500)
    h.cam(0, 0, 0, 0, 0)
    ok(h.ents[e1].deleted, 'the materialiser deleted the entity')
    eq(Maps.uidOf(e1), nil, 'a deleted entity has no uid')
    eq(Maps.handleOf('m1:9'), nil, 'and the uid no entity')
    -- two nodes carrying one uid for a moment (a context swap): the newest wins, the old one's removal keeps it
    addProp(h, 3, 'm1:3', 0, 25, 0)
    addProp(h, 4, 'm1:3', 0, 26, 0)
    settle(h)
    eq(Maps.handleOf('m1:3'), M.handleOf(4), 'the newest node of a uid answers')
    eq(Maps.uidOf(M.handleOf(3)), 'm1:3', 'the older one still maps back to its uid')
    M.remove(h.nodes[3])
    eq(Maps.handleOf('m1:3'), M.handleOf(4), 'removing the older node keeps the newer')
    eq(Maps.stats().elements, 1, 'counted once')
    M.remove(h.nodes[4])
    eq(Maps.stats().elements, 0, 'and gone with the newer')
end

-- 3. promoted clones: handleOf answers the clone when no local copy exists, uidOf maps a clone back -----------------
do
    local h, Maps, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local clone = h.newEntity(HPROP, 0, 400, 0, 2)
    h.C.promote = {
        cloneOf = function(id) return id == 5 and clone or nil end,
        idOfClone = function(e) return e == clone and 5 or nil end,
    }
    addProp(h, 5, 'm1:5', 0, 400, 0)                  -- far away: the local copy is never created
    settle(h)
    eq(M.handleOf(5), nil, 'no local copy')
    eq(Maps.handleOf('m1:5'), clone, 'handleOf(uid) = the promoted clone standing in')
    eq(Maps.uidOf(clone), 'm1:5', 'uidOf(clone) = the uid of the node it stands in for')
    eq(Maps.stats().spawned, 0, 'stats.spawned counts local copies only')
    h.C.promote = nil
    eq(Maps.handleOf('m1:5'), nil, 'without the promote module: nil')
    eq(Maps.uidOf(clone), nil, 'and no clone lookup')
end
-- 4. holds: owner-tracked per uid, applied to the node when it comes, isolated from Scene.hold ---------------------
do
    local h, Maps, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local function held(id) return h.nodes[id] and h.nodes[id].m and h.nodes[id].m.held end
    -- a hold taken before the element's node arrives
    eq(as(h, 'editor_a', Maps.hold, 'm1:10'), nil, 'hold of a uid with no node yet: nil (nothing to hand out)')
    eq(Maps.stats().held, 1, 'the hold is kept per uid')
    local n10 = addProp(h, 10, 'm1:10', 0, 20, 0)
    eq(held(10), true, 'the node arrives: its record starts held')
    settle(h)
    local e10 = M.handleOf(10)
    ok(e10 ~= nil, 'holding does not stop a missing entity from being created')
    eq(as(h, 'editor_a', Maps.hold, 'm1:10'), e10, 'hold again (same owner): the entity, nothing doubled')
    eq(#h.Registry.idsOf('mapHold', 'editor_a'), 1, 'one registry entry per (owner, uid)')
    -- a move while held waits for the release
    n10.x = 6.0
    M.update(n10, 'move')
    settle(h, 300)
    eq(h.ents[e10].x, 0.0, 'moved on the server while held: the entity stays')
    eq(as(h, 'editor_b', Maps.release, 'm1:10'), false, 'release by a resource that holds nothing: false')
    eq(as(h, 'editor_a', Maps.release, 'm1:10'), true, 'release by the holder: true')
    eq(held(10), false, 'released: the record is free again')
    eq(h.ents[e10].x, 6.0, 'what changed meanwhile applies on release (moved in place)')
    eq(M.handleOf(10), e10, 'the same entity')
    eq(#h.Registry.idsOf('mapHold', 'editor_a'), 0, 'untracked')
    eq(Maps.release(nil), false, 'release(nil): false')
    eq(Maps.hold(''), nil, 'hold(\'\'): nil')
    -- removed while held: the entity stays, handleOf / uidOf still know it until the release
    as(h, 'editor_a', Maps.hold, 'm1:10')
    M.remove(n10)
    settle(h, 2500)
    ok(not h.ents[e10].deleted, 'removed by the server while held: the entity stays')
    eq(Maps.handleOf('m1:10'), e10, 'handleOf answers the held copy')
    eq(Maps.uidOf(e10), 'm1:10', 'uidOf still maps it back')
    eq(Maps.stats().elements, 0, 'but it is no element any more')
    as(h, 'editor_a', Maps.release, 'm1:10')
    h.cam(0, 0, 0, 0, 180)
    settle(h, 2500)
    h.cam(0, 0, 0, 0, 0)
    ok(h.ents[e10].deleted, 'released: the removed copy goes')
    eq(Maps.handleOf('m1:10'), nil, 'handleOf: nil')
    eq(Maps.uidOf(e10), nil, 'uidOf: nil')
    eq(Maps.stats().held, 0, 'no holds left')
    -- two owners; the second's resource stops
    addProp(h, 11, 'm1:11', 2, 20, 0)
    settle(h)
    as(h, 'editor_a', Maps.hold, 'm1:11')
    as(h, 'editor_b', Maps.hold, 'm1:11')
    as(h, 'editor_a', Maps.release, 'm1:11')
    eq(held(11), true, 'one of two holders released: still held')
    h.stubs.triggerOn(h.env, 'onResourceStop', 0, 'editor_b')
    eq(held(11), false, 'the other holder\'s resource stopped: released (Registry mapHold)')
    eq(Maps.stats().held, 0, 'no holds left')
    -- a resource's Scene.hold (C.mat owner = the resource) and Maps.hold never release each other
    M.hold(11, 'editor_a')
    as(h, 'editor_a', Maps.hold, 'm1:11')
    as(h, 'editor_a', Maps.release, 'm1:11')
    eq(held(11), true, 'Maps.release leaves the same resource\'s Scene hold alone')
    M.release(11, 'editor_a')
    eq(held(11), false, 'the Scene hold released on its own')
    -- a held uid whose node is replaced (a context swap re-spawns it): both copies held until the release
    addProp(h, 12, 'm1:12', 4, 20, 0)
    settle(h)
    local e12 = M.handleOf(12)
    as(h, 'editor_a', Maps.hold, 'm1:12')
    M.remove(h.nodes[12])
    addProp(h, 13, 'm1:12', 4, 21, 0)
    eq(held(13), true, 'the new node of a held uid is held too')
    settle(h)
    local e13 = M.handleOf(13)
    ok(e13 ~= nil and e13 ~= e12, 'the new node gets its own entity')
    ok(not h.ents[e12].deleted, 'the replaced copy stays while held')
    eq(Maps.handleOf('m1:12'), e13, 'handleOf prefers the current node')
    eq(Maps.uidOf(e12), 'm1:12', 'both copies map back to the uid')
    as(h, 'editor_a', Maps.release, 'm1:12')
    h.cam(0, 0, 0, 0, 180)
    settle(h, 2500)
    h.cam(0, 0, 0, 0, 0)
    ok(h.ents[e12].deleted, 'released: the replaced copy goes')
    ok(not h.ents[e13].deleted, 'the current one stays')
    eq(held(13), false, 'and is free')
end
-- 5. area readiness: the scene's (cache cells + materialiser), waitAreaReady reports the focus at once ---------------
do
    local h, Maps = fresh()
    local v3 = h.stubs.vector3
    h.cam(0, 0, 0, 0, 0)
    local spot = v3(0.0, 40.0, 0.0)
    eq(Maps.isAreaReady(spot), true, 'nothing known there: ready')
    eq(Maps.isAreaReady(nil), false, 'no coords')
    for _, bad in ipairs({ 5, 'x', { x = 1 }, v3(0 / 0, 0, 0), v3(1e9, 0, 0) }) do
        eq(Maps.isAreaReady(bad), false, 'bad coords: ' .. tostring(bad))
    end
    h.cacheReady = false
    eq(Maps.isAreaReady(spot), false, 'cells still arriving (the cache half): not ready')
    h.cacheReady = true
    addProp(h, 20, 'm1:20', 0, 45, 0)
    eq(Maps.isAreaReady(spot), false, 'a map prop a camera there would create, not created yet: not ready')
    eq(Maps.isAreaReady(spot, 2), true, 'outside a 2 m radius: ready')
    eq(Maps.isAreaReady(spot, -5), true, 'a negative radius is 0 m')
    local result, doneAt = nil, nil
    local reports = h.reports
    h.env.CreateThread(function()
        result = Maps.waitAreaReady(spot, 5000)
        doneAt = h.now()
    end)
    eq(h.reports - reports, 1, 'waitAreaReady asks the focus reporter to report at once')
    local started = h.now()
    settle(h)
    eq(result, true, 'waitAreaReady: true once the prop is LIVE')
    ok(doneAt and doneAt - started < 1500, 'within the materialiser\'s first rounds (' .. tostring(doneAt and doneAt - started) .. ' ms)')
    -- a timeout
    h.cacheReady = false
    result, doneAt = nil, nil
    started = h.now()
    h.env.CreateThread(function()
        result = Maps.waitAreaReady(spot, 300)
        doneAt = h.now()
    end)
    settle(h, 1000)
    eq(result, false, 'never ready: false after the timeout')
    ok(doneAt and doneAt - started >= 300 and doneAt - started <= 400, 'after ~300 ms (' .. tostring(doneAt and doneAt - started) .. ')')
    result = nil
    h.env.CreateThread(function() result = Maps.waitAreaReady(spot, -20) end)
    settle(h, 100)
    eq(result, false, 'a negative timeout checks once')
    h.env.CreateThread(function() result = Maps.waitAreaReady('nope', 1000) end)
    eq(result, false, 'bad coords: false at once')
    h.cacheReady = true
    -- core stops: a waiter gives up
    h.cacheReady = false
    result = nil
    h.env.CreateThread(function() result = Maps.waitAreaReady(spot, 60000) end)
    settle(h, 200)
    h.stubs.triggerOn(h.env, 'onClientResourceStop', 0, 'core')
    settle(h, 200)
    eq(result, false, 'core stopped: waitAreaReady returns false')
    eq(table.concat(h.warnings, ' | '), '', 'no warning logged')
    current = nil                         -- stopped already
end
-- 6. the editor view: map:data records, defaults before the type list, type previews, placeholders -----------------
local TYPES = {
    { id = 'core:point', kind = 'point', label = 'Point',
        preview = { { kind = 'sphere', radius = 0.5 }, { kind = 'label', text = '$label' } } },
    { id = 'core:zone', kind = 'zone', label = 'Zone', preview = { { kind = 'box', size = '$size' } } },
    { id = 'test:spot', kind = 'point', label = 'Spot',
        preview = { { kind = 'marker', type = 2, scale = { x = 0.5, y = 0.5, z = 1.0 }, color = '#FF000080' } } },
    { id = 'test:plain', kind = 'point', label = 'Plain' },
}
local function n(h, name) return h.calls[name] or 0 end
--- Counts of the draw natives over `frames` frames.
local function drawn(h, frames)
    local m, l, t = n(h, 'DrawMarker'), n(h, 'DrawLine'), n(h, 'AddTextComponentSubstringPlayerName')
    h.tick(frames * FRAME)
    return n(h, 'DrawMarker') - m, n(h, 'DrawLine') - l, n(h, 'AddTextComponentSubstringPlayerName') - t
end
--- min / max of the DrawLine endpoints of one frame whose x lies in [x0, x1]
local function extents(h, x0, x1)
    h.lines, h.recordLines = {}, true
    h.tick(FRAME)
    h.recordLines = false
    local b = { x = { math.huge, -math.huge }, y = { math.huge, -math.huge }, z = { math.huge, -math.huge }, n = 0 }
    for _, l in ipairs(h.lines) do
        if l[1] >= x0 and l[1] <= x1 then
            b.n, b.colour = b.n + 1, { l[7], l[8], l[9], l[10] }
            for _, k in ipairs({ { 'x', 1, 4 }, { 'y', 2, 5 }, { 'z', 3, 6 } }) do
                local r = b[k[1]]
                r[1] = math.min(r[1], l[k[2]], l[k[3]])
                r[2] = math.max(r[2], l[k[2]], l[k[3]])
            end
        end
    end
    return b
end
do
    local h, Maps, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    local n21 = addData(h, 21, { mapEl = 'm2:1', mapType = 'core:point', t = 'core:point', k = 'point',
        f = { label = 'Alpha' } }, 0, 20, 0)
    local n22 = addData(h, 22, { mapEl = 'm2:2', t = 'core:zone', k = 'zone', size = { x = 4, y = 2, z = 3 } },
        5, 20, 0, { rz = 90.0 })
    addData(h, 23, { mapEl = 'm2:3', t = 'gone:type' }, -5, 20, 0)                  -- a placeholder
    addData(h, 24, { mapEl = 'm2:4', t = 'core:point', k = 'point' }, 0, 155, 0)    -- created, beyond 150 m
    addData(h, 25, { mapEl = 'm2:5', t = 'core:point', k = 'point' }, 0, 400, 0)    -- never created
    settle(h)
    eq(h.nodes[21].m.st, LIVE, 'a map:data node is LIVE on the materialiser (the handler answered true)')
    eq(h.nodes[24].m.st, LIVE, 'within 160 m: created')
    eq(h.nodes[25].m.st, KNOWN, 'beyond 160 m: not created')
    near(h.nodes[21].m.rIn, 160, 'map:data radii: R_in 160')
    near(h.nodes[21].m.rOut, 190, 'map:data radii: R_out 190')
    eq(h.nodes[21].m.fade, 'self', 'fade self (no alpha fades for previews)')
    eq(h.P.stats().dataNodes, 4, 'four records')
    eq(M.handleOf(21), nil, 'a record has no entity')
    eq(Maps.handleOf('m2:1'), nil, 'handleOf of a data element: nil (no object)')
    eq(Maps.stats().elements, 5, 'data elements are indexed too (holds work on them)')
    local dm, dl, dt = drawn(h, 10)
    ok(dm == 0 and dl == 0 and dt == 0, 'editor view off: nothing drawn')
    eq(h.P.stats().drawing, false, 'and no draw loop')
    eq(#h.typeRequests, 0, 'no type list fetched while nobody edits')
    -- on: the type list is asked for; until it comes, per-kind defaults
    eq(as(h, 'editor_a', Maps.setEditorView, 'yes'), false, 'setEditorView wants a boolean')
    eq(as(h, 'editor_a', Maps.setEditorView, true), true, 'editor view on')
    eq(Maps.stats().editorView, true, 'stats.editorView')
    eq(#h.typeRequests, 1, 'the type list is fetched')
    eq(h.typeRequests[1].name, 'core:maps:types', 'through core:maps:types')
    h.tick(FRAME)
    dm, dl, dt = drawn(h, 4)
    eq(dm, 4, 'before the list: the point is a small sphere marker, per frame (the 155 m one is not drawn)')
    eq(dl, 4 * 24, 'the zone box and the placeholder box: 12 lines each, per frame')
    eq(dt, 0, 'no labels without the list')
    eq(h.last.DrawMarker[1], 28, 'the point default: marker 28')
    near(h.last.DrawMarker[11], 0.35, 'scale 0.35')
    local zb = extents(h, 3, 7)
    eq(zb.n, 12, 'one zone box')
    ok(math.abs(zb.x[1] - 4) < 1e-6 and math.abs(zb.x[2] - 6) < 1e-6, 'zone turned 90 deg: 2 m wide in x')
    ok(math.abs(zb.y[1] - 18) < 1e-6 and math.abs(zb.y[2] - 22) < 1e-6, 'and 4 m long in y')
    ok(math.abs(zb.z[1] + 1.5) < 1e-6 and math.abs(zb.z[2] - 1.5) < 1e-6, 'and 3 m high, centred')
    local pb = extents(h, -7, -3)
    ok(pb.n == 12 and math.abs(pb.x[2] - pb.x[1] - 1) < 1e-6 and math.abs(pb.z[2] - pb.z[1] - 1) < 1e-6,
        'an element without its type (no kind) is a 1 m box')
    -- the list arrives: type previews; the placeholder's type is asked for once more, then left alone
    local askedAt = h.now()
    h.typeRequests[1].p:resolve(TYPES)
    h.tick(FRAME * 2)                     -- the records rebuild at the next gather
    eq(#h.typeRequests, 1, 'a record names a type the list lacks: the next fetch waits for the cooldown')
    h.tick(1600)
    eq(#h.typeRequests, 2, 'one more fetch, >= 1.5 s after the last (the callback cooldown is 1 s)')
    h.typeRequests[2].p:resolve(TYPES)
    h.tick(1600)
    eq(#h.typeRequests, 2, 'still unknown after that: a placeholder, no further fetch')
    ok(h.now() - askedAt >= 1500, 'spaced')
    h.texts, h.origins = {}, {}
    dm, dl, dt = drawn(h, 4)
    eq(dm, 4, 'the point draws its type preview: one sphere')
    eq(dl, 4 * 24, 'the zone box from $size and the placeholder box')
    eq(dt, 4, 'the point label, per frame')
    eq(h.texts[1], 'Alpha', 'a $label reads the node\'s label fields (f)')
    near(h.origins[1][3], 0.6, 'the label sits 0.6 m above the element')
    near(h.last.DrawMarker[11], 0.5, 'the sphere preview radius 0.5')
    eq(h.P.stats().types, 4, 'four types known')
    zb = extents(h, 3, 7)
    ok(math.abs(zb.x[2] - zb.x[1] - 2) < 1e-6 and math.abs(zb.y[2] - zb.y[1] - 4) < 1e-6, '$size resolves to the node\'s size')
    pb = extents(h, -7, -3)
    ok(math.abs(pb.x[2] - pb.x[1] - 1) < 1e-6, 'the placeholder stays a 1 m box')
    ok(pb.colour[1] == 255 and pb.colour[2] == 170 and pb.colour[3] == 60, 'in the placeholder colour')
    -- a marker preview with a '#RRGGBBAA' colour; a type without a preview draws its kind's default + its label
    addData(h, 26, { mapEl = 'm2:6', t = 'test:spot', k = 'point' }, 2, 30, 0)
    addData(h, 27, { mapEl = 'm2:7', t = 'test:plain', k = 'point' }, -2, 30, 0)
    settle(h, 600)
    h.markers, h.texts = {}, {}
    h.tick(FRAME)
    local spot
    for _, mk in ipairs(h.markers) do if mk[1] == 2 then spot = mk end end
    ok(spot ~= nil, 'the marker preview is drawn with its type')
    ok(spot and spot[11] == 0.5 and spot[12] == 0.5 and spot[13] == 1.0, 'with its scale vector')
    ok(spot and spot[14] == 255 and spot[15] == 0 and spot[16] == 0 and spot[17] == 128, 'and its #RRGGBBAA colour')
    local plain = false
    for _, t in ipairs(h.texts) do if t == 'Plain' then plain = true end end
    ok(plain, 'a type without a preview: its label under the default shape')
    M.remove(h.nodes[26])
    M.remove(h.nodes[27])
    settle(h, 600)                        -- the materialiser's deletion queue runs within its 500 ms check
    -- changes: fields (the label), a move (the box follows)
    n21.fields = { mapEl = 'm2:1', t = 'core:point', k = 'point', f = { label = 'Beta' } }
    M.update(n21, 'fields', { f = true })
    h.texts = {}
    h.tick(FRAME * 2)
    eq(table.concat(h.texts, ','), 'Beta,Beta', 'a fields update rebuilds the label (the removed ones are gone)')
    n22.x = 25.0
    M.update(n22, 'move')
    zb = extents(h, 23, 27)
    ok(zb.n == 12 and math.abs(zb.x[1] - 24) < 1e-6, 'a move rebuilds the box where the node went')
    -- the view is turned around: what is behind the camera is skipped
    addData(h, 28, { mapEl = 'm2:8', t = 'core:zone', k = 'zone', size = { x = 1, y = 1, z = 1 } }, 0, -30, 0)
    settle(h, 600)
    eq(extents(h, -1, 1).n, 0, 'a box 30 m behind the camera is not drawn')
    h.cam(0, 0, 0, 0, 180)
    settle(h, 300)
    eq(extents(h, -1, 1).n, 12, 'turned around: it is')
    eq(extents(h, 23, 27).n, 0, 'and the zone now behind is not')
    h.cam(0, 0, 0, 0, 0)
    settle(h, 300)
    -- removal
    M.remove(n21)
    settle(h, 600)
    h.texts = {}
    dm = drawn(h, 4)
    eq(dm, 0, 'the point went: no sphere')
    eq(#h.texts, 0, 'no label')
    eq(h.P.stats().dataNodes, 4, 'records: the zone, the placeholder, the 155 m point, the box behind')
    -- owners: on while any has it on; a stopped resource's view goes
    as(h, 'editor_b', Maps.setEditorView, true)
    as(h, 'editor_a', Maps.setEditorView, false)
    local _, l2 = drawn(h, 4)
    ok(l2 > 0, 'still drawn while another owner has the view on')
    eq(as(h, 'editor_a', Maps.setEditorView, false), true, 'switching off twice is fine')
    h.stubs.triggerOn(h.env, 'onResourceStop', 0, 'editor_b')
    eq(Maps.stats().editorView, false, 'the last owner stopped: view off (Registry mapEditorView)')
    h.tick(600)
    _, l2 = drawn(h, 10)
    eq(l2, 0, 'nothing drawn')
    eq(h.P.stats().drawing, false, 'the draw loop ended')
    eq(h.P.stats().previews, 0, 'no previews gathered')
    -- on again: the list is fresh (< 60 s) so no fetch; after 60 s it is asked for again
    as(h, 'editor_a', Maps.setEditorView, true)
    eq(#h.typeRequests, 2, 'view on again within 60 s: no fetch')
    as(h, 'editor_a', Maps.setEditorView, false)
    h.tick(61000)
    as(h, 'editor_a', Maps.setEditorView, true)
    eq(#h.typeRequests, 3, 'view on again after 60 s: the list is fetched again')
    h.typeRequests[3].p:resolve(nil)      -- refused (the callback's cooldown: the editor asked a moment ago)
    h.tick(1000)
    eq(#h.typeRequests, 3, 'a refused fetch is not retried at once')
    h.tick(600)
    eq(#h.typeRequests, 4, 'but 1.5 s later')
    h.typeRequests[4].p:resolve(nil)
    h.tick(1600)
    eq(#h.typeRequests, 5, 'and once more')
    h.typeRequests[5].p:resolve(nil)
    h.tick(3200)
    eq(#h.typeRequests, 5, 'three attempts in all')
    eq(h.P.stats().typesState, 'ok', 'then the list it had stays')
    eq(h.P.stats().types, 4, 'with its four types')
    _, l2 = drawn(h, 2)
    ok(l2 > 0, 'and keeps drawing')
    as(h, 'editor_a', Maps.setEditorView, false)
end
-- 7. budgets: <= MaxMarkers previews nearest first, <= 10 labels a frame, per frame only while one is within 150 m ----
do
    local h, Maps, M = fresh({ maxMarkers = 3 })
    h.cam(0, 0, 0, 0, 0)
    for i = 1, 5 do addData(h, 30 + i, { mapEl = 'm3:' .. i, t = 'core:point', k = 'point' }, 0, i * 10, 0) end
    settle(h)
    as(h, 'editor_a', Maps.setEditorView, true)
    h.typeRequests[1].p:resolve({})         -- an empty list: every record is a placeholder box...
    h.tick(1600)
    h.typeRequests[2].p:resolve({ { id = 'core:point', kind = 'point', label = 'Point' } })   -- ...until it names the type
    h.tick(FRAME * 2)
    h.markers, h.texts = {}, {}
    local dm, dl, dt = drawn(h, 1)
    eq(dm, 3, 'MaxMarkers 3: three previews a frame')
    eq(dl, 0, 'all of them points (the second list named the type)')
    eq(dt, 3, 'with their type label')
    local ys = {}
    for _, mk in ipairs(h.markers) do ys[#ys + 1] = mk[3] end
    table.sort(ys)
    eq(table.concat(ys, ','), '10.0,20.0,30.0', 'the nearest three')
    eq(Maps.stats().previews, 3, 'stats.previews')
    h.cam(0, 60, 0, 0, 180)                  -- at the far end, looking back along -y
    settle(h, 300)
    h.markers = {}
    drawn(h, 1)
    ys = {}
    for _, mk in ipairs(h.markers) do ys[#ys + 1] = mk[3] end
    table.sort(ys)
    eq(table.concat(ys, ','), '30.0,40.0,50.0', 'moved: again the nearest three')
end
do
    local h, Maps = fresh()
    h.cam(0, 0, 0, 0, 0)
    for i = 1, 12 do
        addData(h, 40 + i, { mapEl = 'm4:' .. i, t = 'core:point', k = 'point', f = { label = 'P' .. i } }, i, 20, 0)
    end
    settle(h)
    as(h, 'editor_a', Maps.setEditorView, true)
    h.typeRequests[1].p:resolve(TYPES)
    h.tick(FRAME * 2)
    local dm, _, dt = drawn(h, 2)
    eq(dm, 2 * 12, 'twelve spheres a frame')
    eq(dt, 2 * 10, 'but at most ten labels a frame')
    eq(n(h, 'SetDrawOrigin'), n(h, 'ClearDrawOrigin'), 'every draw origin is cleared')
end
do
    local h, Maps, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    addData(h, 51, { mapEl = 'm5:1', t = 'core:point', k = 'point' }, 0, 100, 0)
    settle(h)
    as(h, 'editor_a', Maps.setEditorView, true)
    h.tick(FRAME)
    -- count the preview loop's own passes: its camera reads come from client/maps_preview.lua
    local camFn, passes = h.env.GetFinalRenderedCamCoord, 0
    h.env.GetFinalRenderedCamCoord = function()
        if debug.getinfo(2, 'S').source == '@client/maps_preview.lua' then passes = passes + 1 end
        return camFn()
    end
    h.tick(20 * FRAME)
    eq(passes, 20, 'in range: one pass per frame')
    h.cam(0, -55, 0, 0, 0)                   -- 155 m away: out of the view's reach, the record stays (R_out 190)
    h.tick(1000)
    eq(h.nodes[51].m.st, LIVE, 'the record stays LIVE')
    passes = 0
    local dm = drawn(h, 125)                 -- 2 s
    eq(dm, 0, 'nothing within 150 m: nothing drawn')
    ok(passes >= 3 and passes <= 6, 'a distance check every <= 500 ms instead (' .. passes .. ' passes in 2 s)')
    eq(h.P.stats().drawing, true, 'the loop idles, it does not end')
    h.cam(0, 0, 0, 0, 0)
    h.tick(520)
    dm = drawn(h, 2)
    eq(dm, 2, 'back within range: drawn again within 500 ms')
    h.env.GetFinalRenderedCamCoord = camFn
    -- no records: the loop ends; a new record starts it again
    M.remove(h.nodes[51])
    h.tick(1200)
    eq(h.P.stats().dataNodes, 0, 'no records')
    eq(h.P.stats().drawing, false, 'no records: no loop')
    addData(h, 52, { mapEl = 'm5:2', t = 'core:point', k = 'point' }, 0, 30, 0)
    settle(h, 600)
    eq(h.P.stats().drawing, true, 'a record arrives while the view is on: the loop is back')
    ok(drawn(h, 2) == 2, 'and draws it')
end
-- 8. zero allocation per frame while previews are drawn ------------------------------------------------------------
do
    local h, Maps = fresh()
    h.cam(0, 0, 0, 0, 0)
    for i = 1, 8 do
        addData(h, 60 + i, { mapEl = 'm6:' .. i, t = 'core:zone', k = 'zone', size = { x = 2, y = 2, z = 2 } },
            i * 3, 20, 0)
    end
    for i = 1, 4 do addData(h, 70 + i, { mapEl = 'm7:' .. i, t = 'test:spot', k = 'point' }, -i * 3, 25, 0) end
    settle(h)
    as(h, 'editor_a', Maps.setEditorView, true)
    h.typeRequests[1].p:resolve(TYPES)
    h.recordTexts = false
    -- until phase D's cleanup the materialiser and scene_world sample Core.Maps.stats() once a second for the §52
    -- objects / hides (dead now: the facade reports neither); that call allocates, so it is kept out of this count
    h.env.Core.Maps = nil
    h.tick(60 * FRAME)                        -- warm-up: every reused table has its size
    collectgarbage('collect')
    collectgarbage('stop')
    h.tick(FRAME)                             -- the first frame after a full GC regrows the stacks: not counted
    local kb = collectgarbage('count')
    local lines = n(h, 'DrawLine')
    h.tick(60 * FRAME)
    local grown = (collectgarbage('count') - kb) * 1024
    collectgarbage('restart')
    h.env.Core.Maps = Maps
    eq(n(h, 'DrawLine') - lines, 60 * 8 * 12, 'eight boxes drawn every frame')
    print(('[bench] 60 preview frames (8 boxes, 4 markers): %d bytes'):format(math.floor(grown)))
    ok(grown < 64, 'steady-state preview frames allocate nothing (' .. math.floor(grown) .. ' bytes)')
end
-- 9. stats, core stop ------------------------------------------------------------------------------------------------
do
    local h, Maps, M = fresh()
    h.cam(0, 0, 0, 0, 0)
    addProp(h, 81, 'm8:1', 0, 20, 0)
    addProp(h, 82, 'm8:2', 0, 600, 0)                 -- never created
    addData(h, 83, { mapEl = 'm8:3', t = 'core:point', k = 'point' }, 2, 20, 0)
    settle(h)
    as(h, 'editor_a', Maps.hold, 'm8:2')
    as(h, 'editor_a', Maps.setEditorView, true)
    h.tick(FRAME * 2)
    local s = Maps.stats()
    eq(s.elements, 3, 'stats.elements: every map node the runtime was told about')
    eq(s.spawned, 1, 'stats.spawned: the one with a local entity')
    eq(s.held, 1, 'stats.held: held uids')
    eq(s.dataNodes, 1, 'stats.dataNodes: LIVE map:data records')
    eq(s.previews, 1, 'stats.previews: drawn now')
    eq(s.editorView, true, 'stats.editorView')
    eq(s.types, 0, 'stats.types: the list has not come yet')
    ok(type(s.queued) == 'number' and type(s.models) == 'number' and type(s.failed) == 'number',
        'stats.queued / models / failed: the scene\'s counters')
    eq(s.regions, nil, 'no §52 regions any more')
    -- core stops: the materialiser destroys the records, the preview loop ends, nothing throws
    h.stubs.triggerOn(h.env, 'onClientResourceStop', 0, 'core')
    h.tick(1000)
    eq(h.P.stats().dataNodes, 0, 'core stopped: the records went with the materialiser')
    eq(h.P.stats().drawing, false, 'and the draw loop')
    local _, dl = drawn(h, 4)
    eq(dl, 0, 'nothing drawn after the stop')
    eq(M.stats().nodes, 0, 'the materialiser is empty')
    eq(table.concat(h.warnings, ' | '), '', 'no warning logged')
    current = nil
end

-- 10. the real cache fed through the codec, client/scene.lua loaded last --------------------------------------------
do
    local h = H.new({ runtime = false })
    stubDraw(h)
    stubTypes(h)
    h.load('shared/scene_codec.lua')
    h.load('client/scene_cache.lua')
    h.C = h.env.CoreSceneRuntime
    h.load('client/scene_focus.lua')
    h.loadMat()
    h.prop = propHandler(h)
    h.C.mat.registerKind('prop', h.prop)
    h.load('client/maps_preview.lua')
    h.load('client/maps.lua')
    h.load('client/scene.lua')
    eq(h.env.CoreSceneRuntime, nil, 'client/scene.lua loads after the maps files and clears the hand-off')
    local Core = h.env.Core
    local Maps, Scene, Codec, Clock = Core.Maps, Core.Scene, Core.SceneCodec, Core.Clock
    local function stream(...)
        h.stubs.triggerOn(h.env, 'core:scene:s', 65535, Codec.header(Clock.now()) .. table.concat({ ... }))
    end
    local function put(id, kind, ver, x, y, z, fields)
        return Codec.put(id, kind, ver, 0, 0, x, y, z, 0.0, 0.0, 0.0, 100, Codec.pack({ f = fields }))
    end
    local K = 32768 * 65536 + 32768           -- the near cell (0, 0)
    h.cam(64, 40, 0, 0, 0)
    local v3 = h.stubs.vector3
    eq(Maps.isAreaReady(v3(64.0, 64.0, 0.0), 40), false, 'nothing subscribed: not ready (the cache half)')
    stream(Codec.kinds({
        { idx = 1, id = 'prop', class = 1, meta = { budget = 'props', handler = 'core' } },
        { idx = 2, id = 'map:data', class = 5, meta = { handler = 'core' } },
    }), Codec.sub(0, K, 1, 1), Codec.cell(0, K, 1, 0, 1, 2),
        put(91, 1, 1, 64.0, 80.0, 0.0, { model = HPROP, mapEl = 'm9:1' }),
        put(92, 2, 1, 60.0, 70.0, 0.0, { mapEl = 'm9:2', mapType = 'core:point', t = 'core:point', k = 'point',
            f = { label = 'Gate' } }))
    eq(Maps.stats().elements, 2, 'two map elements arrived through the codec')
    eq(Maps.isAreaReady(v3(64.0, 64.0, 0.0), 40), false, 'the prop is not LIVE yet: not ready')
    settle(h)
    local e = Maps.handleOf('m9:1')
    ok(e ~= nil and h.ents[e] ~= nil, 'handleOf(uid): the local copy of the streamed prop')
    eq(Scene.idOf(e), 91, 'Core.Scene.idOf agrees on the node')
    eq(Scene.handleOf(91), e, 'Core.Scene.handleOf too')
    eq(Maps.uidOf(e), 'm9:1', 'uidOf: node -> fields.mapEl')
    eq(Maps.isAreaReady(v3(64.0, 64.0, 0.0), 40), true, 'cell live, prop LIVE: ready')
    Core.Registry.setCaller('editor_a')
    eq(Maps.hold('m9:1'), e, 'hold answers the entity')
    eq(Maps.setEditorView(true), true, 'editor view on')
    Core.Registry.setCaller('core')
    eq(#h.typeRequests, 1, 'the type list is asked for')
    h.typeRequests[1].p:resolve(TYPES)
    h.tick(FRAME * 2)
    h.texts = {}
    local dm, _, dt = drawn(h, 3)
    eq(dm, 3, 'the streamed point draws its sphere every frame')
    eq(dt, 3, 'and its label')
    eq(h.texts[1], 'Gate', 'from the node\'s label fields')
    -- the server moves the held prop: nothing moves until the release
    stream(Codec.cell(0, K, 1, 1, 2, 1), Codec.move(91, 2, 70.0, 80.0, 0.0, 0.0, 0.0, 0.0))
    settle(h, 600)
    near(h.ents[e].x, 64.0, 'held: the server\'s move waits')
    Core.Registry.setCaller('editor_a')
    eq(Maps.release('m9:1'), true, 'released')
    Core.Registry.setCaller('core')
    near(h.ents[e].x, 70.0, 'the move applies on release')
    -- DEL: no element at once; the entity leaves through the materialiser and keeps its uid while it stands
    stream(Codec.cell(0, K, 1, 2, 3, 1), Codec.del(91, 3, 0))
    eq(Maps.stats().elements, 1, 'one element left (the point)')
    eq(Maps.uidOf(e), 'm9:1', 'DEL: the copy that still stands keeps its uid (review RV5 F3)')
    h.cam(64, 40, 0, 0, 180)
    settle(h, 2500)
    ok(h.ents[e].deleted, 'the prop entity is deleted')
    eq(Maps.handleOf('m9:1'), nil, 'then handleOf answers nil')
    eq(#h.warnings, 0, 'no warning from the cache, the materialiser or the maps files')
    h.stubs.triggerOn(h.env, 'onClientResourceStop', 0, 'core')
    h.tick(1000)
end

-- 12. review RV5 F3: an element removed while in view (DEL normal: RETIRING up to DeferMaxMs 10 s) keeps its uid for
-- as long as its copy stands, so the editor never takes it for world geometry (a Del on it wrote a core:hide into the
-- map); a replaced uid hands out the new node's copy, never the doomed one; a faded removal (the projector's
-- editor-driven removals) is gone within ~0.5 s -----------------------------------------------------------------------
do
    local h, Maps, M = fresh()
    h.cam(0, 0, 0, 0, 0)                              -- the editor looks at the element 20 m ahead
    local node = addProp(h, 1, 'm1:7', 0, 20, 0)
    settle(h)
    local e = Maps.handleOf('m1:7')
    ok(e ~= nil, 'the element is LIVE')
    M.remove(node)                                    -- the projector removed it (DEL normal)
    settle(h, 3000)
    ok(not h.ents[e].deleted, '3 s later it still stands (in view: RETIRING)')
    eq(Maps.uidOf(e), 'm1:7', 'uidOf still maps it to the element (not a world object)')
    eq(Maps.handleOf('m1:7'), e, 'handleOf answers it (no node carries the uid)')
    eq(Maps.stats().elements, 0, 'but it is no element any more')
    settle(h, 8000)
    ok(h.ents[e].deleted, 'deleted after DeferMaxMs')
    eq(Maps.uidOf(e), nil, 'gone: no uid')
    eq(Maps.handleOf('m1:7'), nil, 'gone: no entity')
    -- replaced (another kind: remove + a new node of the same uid) while the old copy still stands
    local n2 = addProp(h, 2, 'm1:8', 0, 22, 0)
    settle(h)
    local old = M.handleOf(2)
    M.remove(n2)
    local n3 = addProp(h, 3, 'm1:8', 0, 22, 0)
    eq(Maps.handleOf('m1:8'), nil, 'the new node has no copy yet: nil — never the doomed one')
    eq(Maps.uidOf(old), 'm1:8', 'the doomed copy still maps back to the uid')
    settle(h)
    local new = M.handleOf(3)
    ok(new ~= nil and new ~= old, 'the new node\'s copy')
    eq(Maps.handleOf('m1:8'), new, 'handleOf answers it')
    -- a faded removal (how 2): gone in about half a second
    M.remove(n3, 2)
    settle(h, 1000)
    ok(h.ents[new].deleted, 'DEL fade: deleted within a second')
    eq(Maps.uidOf(new), nil, 'no uid left')
    -- many retired copies: the index sweeps the deleted ones (bounded)
    for i = 10, 99 do addProp(h, i, 'm2:' .. i, (i % 10) * 2, 30, 0) end
    settle(h)
    for i = 10, 99 do M.remove(h.nodes[i], 2) end
    settle(h, 2000)
    for i = 100, 170 do addProp(h, i, 'm3:' .. i, 0, 40, 0) end
    settle(h)
    for i = 100, 170 do M.remove(h.nodes[i]) end
    local stale, standing = 0, 0
    for i = 10, 99 do
        local hnd = Maps.handleOf('m2:' .. i)
        if hnd ~= nil and h.ents[hnd].deleted then stale = stale + 1 end
        if hnd ~= nil and not h.ents[hnd].deleted then standing = standing + 1 end
    end
    eq(stale, 0, 'a deleted copy never answers')
    ok(standing > 0, 'copies still standing (no fade slot free: RETIRING) keep answering (' .. standing .. ')')
    settle(h, 11000)
    standing = 0
    for i = 10, 99 do if Maps.handleOf('m2:' .. i) ~= nil then standing = standing + 1 end end
    eq(standing, 0, 'all gone after DeferMaxMs: none answers')
end

-- 13. honest readiness while the server still projects (GlobalState core:mapsPending, server/maps_runtime.lua) -------
do
    local h, Maps = fresh({ pending = { { 0, -10.0, 30.0, 10.0, 50.0 }, 'junk', { 'x', 1, 2, 3, 4 } } })
    local v3 = h.stubs.vector3
    local spot = v3(0.0, 40.0, 0.0)
    eq(Maps.isAreaReady(spot), false, 'seeded at load: a box of this bucket (0) covers the spot: not ready')
    eq(Maps.isAreaReady(v3(0.0, 400.0, 0.0)), true, 'far from the box: ready')
    eq(h.C.mapsPending(0.0, 40.0, 5.0), true, 'the hand-off for client/scene.lua agrees')
    local set = h.bagFns['core:mapsPending@global']
    set(nil, nil, { { 7, -10.0, 30.0, 10.0, 50.0 } })
    eq(Maps.isAreaReady(spot), true, 'a box of another bucket: ready')
    h.C.focus.stats = function() return { bucket = 7 } end
    eq(Maps.isAreaReady(spot), false, 'the client is in bucket 7 now: not ready')
    eq(Maps.isAreaReady(v3(0.0, 58.0, 0.0), 10), false, 'a circle reaching into the box counts (8 m off, 10 m)')
    eq(Maps.isAreaReady(v3(0.0, 65.0, 0.0), 5), true, 'one 15 m off with 5 m does not')
    local result
    h.env.CreateThread(function() result = Maps.waitAreaReady(spot, 5000) end)
    settle(h, 500)
    eq(result, nil, 'waitAreaReady waits while the server projects there')
    set(nil, nil, nil)
    settle(h, 200)
    eq(result, true, 'and answers true once the box is cleared')
    set(nil, nil, 'nonsense')
    eq(Maps.isAreaReady(spot), true, 'junk values are ignored')
    h.C.focus.stats = nil
end

eq(#H.new().stubs.failures, 0, 'no thread, timer or handler error anywhere in the suite')
print('client maps: ' .. passed .. ' passed, 0 failed')
