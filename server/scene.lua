--[[
    core/server/scene.lua — Core.Scene, the server API (DESIGN §55.4): validation order, owner rules and owner
    cleanup, the interaction path (§55.14), C2 driving (§55.9), C4 events, queries. Seventh of the scene server
    files (scene_kinds → scene_index → scene_interest → scene_gated → scene_flush → scene_store → scene →
    scene_promote → scene_audio → scene_voice: phase B/C hook in through R.promote / R.audio / R.voice, looked up
    at call time); the node store, the server hooks and persistence are server/scene_store.lua (its internals
    arrive once through R.storeInternal).

      Scene.spawn(def) -> id | nil, err, detail       def = { kind, pos, rot?, bucket?, parent?, offset?, offrot?,
                                                        bone?, rotOrder? (children: 0..5, nil = 2), motion?, fields?,
                                                        model?, audience?, radius?, global?, persist?, interact?,
                                                        authority?, allowChildren? }
      Scene.set(id, patch, opts?) -> ok, err, detail  patch = partial fields (merged, the result checked whole);
                                                        opts = { remove = { names }, interact = list|false,
                                                        audience = t|false, radius = m|false, allowChildren = … }
      Scene.move(id, pos, rot?, { duration?, ease?, rotOrder? }) / motion(id, desc|nil) / detach(id) /
      Scene.attach(id, target, { offset?, offrot?, bone?, rotOrder? }?)
      Scene.remove(id, { fade? }) / emit(id | { pos, bucket? }, name, params?, { radius?, horizonMs? })
      Scene.drive(id, pos, vel, yaw) -> ok, sent       C2: a DR op only past Config.Scene.DeadReckoning thresholds
      Scene.get(id) / query(q) / list(filter) / batch(fn, ...) / kinds() / defineKind(def) / stats() / setModelInfo(fn)
      Scene.adopt(id, owner?) (core only) / setFocus(src, pos|nil) / prefetch(src, pos) (core-internal; both refuse a
                                                        src nobody is connected as)
      Scene.promote / demote / lease / voice.start|stop|list / audio.kill   phase B/C: nil, 'unavailable' until
                                                        R.promote / R.voice / R.audio exist
      Scene.on / onInteract / off                      server/scene_store.lua
    Core's tags (review RV4 F11): the fields mapEl, mapType (Core.Maps' elements) and vehId (parked cars) are set,
    changed and removed by core only — anyone else gets 'fields' { [name] = 'reserved' }; no plugin kind declares them.
    Owner rules: set/move/motion/attach/detach/remove/emit/drive by the node's owner or core; everyone reads. A node
    hangs under another resource's node only when that node allows it (`allowChildren` = true | { resources }, set by
    its owner; core always may) — else 'owner'. A root carries at most Config.Scene.MaxChildren (64) descendants and
    a plugin at most Global.MaxPerOwner (64) global nodes ('limit').
    Errors: 'unavailable' (not loaded), 'def', 'kind', 'fields' (+ Schema errs), 'pos', 'rot', 'offset', 'offrot',
    'bone', 'rotOrder', 'motion', 'model', 'parent', 'deps', 'audience', 'interact', 'authority', 'radius', 'global',
    'persist', 'bucket', 'limit', 'hook' (+ reason), 'missing', 'owner', 'dependency', 'attach', 'duration', 'ease',
    'name', 'params', 'horizonMs', 'vel', 'yaw', 'allowChildren', 'motion_future' (a plan whose t0 is more than 24 h
    ahead),
    and R.audio.admit's codes unchanged ('audio_disabled' | 'audio_streams' | 'audio_rate': asked last, audio kinds).
    Phase C: R.promote.beforeChange(node, what) runs before move / motion / drive / attach / detach / a fields set;
    R.promote.refuses(src, node, action) can refuse an interaction before its dispatch.
    Index calls: spawn → put (not for dependency nodes); fields → changed 'set' (patch { f, x, d }); interact →
    changed 'interact'; audience / radius / tier → put; move → changed 'move' (+ 'motion'); motion → 'motion';
    player / net attach → 'attach'; node attach / detach of a child → remove(handover) + put of the subtree;
    remove → remove(normal | fade) (children go with it; a source's emitters are removed with it); emit → event;
    drive → 'motion' once, then dr. A { net } attachment whose entity is gone (or whose net id names another one)
    ends at its last pose within a second (a sliced watcher: changed 'attach' + 'move').
    Interactions: bucket → every audience level of the node's path (R.interest.allows per level) → descriptor →
    perm → server distance (a promoted node: its clone) → the descriptor cooldown (<= 64 running per player; a full
    map refuses, never forgets) → R.promote.refuses → data (<= 1 KiB) → handlers of the id, then of the kind.

    Natives: GetPlayerPed, GetEntityCoords, GetEntityModel, GetPlayerName, NetworkGetEntityFromNetworkId,
    DoesEntityExist, GetPlayerRoutingBucket (all server / CFX forms, fxref 2026-09-26/27). AddEventHandler,
    CreateThread, Wait and SetTimeout are runtime helpers.
]]

local R = Core.SceneRuntime
local S = R and R.storeInternal
assert(S and R.store, 'server/scene_store.lua must load right before server/scene.lua')
R.storeInternal = nil

local Scene = Core.Scene
local K, V, Codec, Motion = R.kinds, R.valid, Core.SceneCodec, Core.SceneMotion
local Utils, Log, Registry = Core.Utils, Core.Log, Core.Registry

local type, pairs, next, pcall, tostring = type, pairs, next, pcall, tostring
local toint = math.tointeger

local NODE_KIND <const>, FOCUS_KIND <const> = 'sceneNode', 'sceneFocus'
local MAX_DEPTH <const> = 4
local EVENT_NAME <const> = '^[%w_%-:%.]+$'
local EVENT_PARAMS_MAX <const>, INTERACT_DATA_MAX <const> = 1024, 1024
local ZERO <const> = { x = 0.0, y = 0.0, z = 0.0 }
local EMPTY <const> = {}
local RELATIVE <const> = { spin = true, osc = true }   -- motions relative to the base pose survive a teleport
local EASE <const> = { linear = true, ['in'] = true, out = true, inout = true }

local nodes, kidsOf, dependents, driving = S.nodes, S.kidsOf, S.dependents, S.driving
local same, v3, toId, isFinite, ownerOk, bumpVer, copyNode = S.same, S.v3, S.toId, S.isFinite, S.ownerOk, S.bumpVer,
    S.copyNode
local pose, rootOf, depthOf, descendants, heightOf, rebuildChildren = S.pose, S.rootOf, S.depthOf, S.descendants,
    S.heightOf, S.rebuildChildren
local link, unlink, setDeps, depsFor, fire = S.link, S.unlink, S.setDeps, S.depsFor, S.fire
local ensureLoaded, touch, markDirty, limitOk, allocId, unparent = S.ensureLoaded, S.touch, S.markDirty, S.limitOk,
    S.allocId, S.unparent
local setMotion = S.setMotion

local function cfg() return Config.Scene end
local function planLead() return (cfg().Motion or EMPTY).PlanLeadMs or 200 end
local function maxChildren() return cfg().MaxChildren or 64 end        -- descendants per root (review F3)

--------------------------------------------------------------------------------
-- The API: spawn / set
--------------------------------------------------------------------------------

--- Phase C's pre-change hook: R.promote.beforeChange(node, what) demotes a promoted node (or cancels a queued
--- promotion) before move / motion / drive / attach / detach / a fields set changes it. Looked up at call time;
--- synchronous; its answer (demoted?) changes nothing here.
local function beforeChange(node, what)
    local PR = R.promote
    local f = PR and PR.beforeChange
    if f then f(node, what) end
end

--- An emitter's source must be an existing dependency node (a persistent one for a persistent emitter).
local function checkDeps(kind, fields, persist)
    local deps = depsFor(kind, fields)
    for i = 1, deps and #deps or 0 do
        local d = nodes[deps[i]]
        if not d or not (d.k and d.k.dependency) or (persist and not d.persist) then return nil, 'deps' end
    end
    return deps
end

local function radiusArg(v, global)
    if v == nil then return nil end
    if not isFinite(v) or v < 1 or v > (global and 65535 or (cfg().TierL or 1500)) then return nil, 'radius' end
    return v
end

local function motionArg(desc)
    if type(desc) ~= 'table' then return nil, 'motion' end
    local d = Utils.deepCopy(desc)
    if d.t ~= 'dr' and d.t0 == nil then d.t0 = R.add(R.now(), planLead()) end
    local ok, norm = Motion.validate(d)
    if not ok then return nil, 'motion', norm end
    if norm.t0 and R.diff(norm.t0, R.now()) > 86400000 then return nil, 'motion_future' end   -- rebase cannot move it
    return norm
end

--- Scene.spawn(def) -> id | nil, err, detail. Validation order (§55.4): kind → fields → pose → rotation (and
--- motion) → model → parent / deps → audience (interact, authority, radius) → limits → 'scene:beforeSpawn'.
function Scene.spawn(def)
    if not ensureLoaded() then return nil, 'unavailable' end
    if type(def) ~= 'table' then return nil, 'def' end
    local owner = Registry.getCaller()
    local kind = type(def.kind) == 'string' and K.get(def.kind) or nil
    if not kind then return nil, 'kind' end
    local fields = def.fields
    if def.model ~= nil then
        if fields ~= nil and type(fields) ~= 'table' then return nil, 'fields', { ['*'] = 'type' } end
        local f = {}
        for k, v in pairs(fields or EMPTY) do f[k] = v end
        if f.model == nil then f.model = def.model end
        fields = f
    end
    local ok, out = K.check(kind, fields, false)
    if not ok then return nil, 'fields', out end
    fields = out
    local tag = owner ~= 'core' and K.reservedChange(fields, nil)
    if tag then return nil, 'fields', { [tag] = 'reserved' } end          -- core's tags (review RV4 F11)
    local dep, pos, rot, offset, offrot, bone, rotOrder, motion, err, detail = kind.dependency
    if dep then
        if def.parent ~= nil or def.motion ~= nil then return nil, def.parent ~= nil and 'parent' or 'motion' end
    elseif def.parent ~= nil then
        offset, err = V.offset(def.offset)
        if not err then offrot, err = V.rot(def.offrot, 'offrot') end
        if not err then bone, err = V.bone(def.bone) end
        if not err then rotOrder, err = V.rotOrder(def.rotOrder) end
        if not err and def.motion ~= nil then err = 'motion' end
        if err then return nil, err end
    else
        pos, err = V.pos(def.pos)
        if not err then rot, err = V.rot(def.rot) end
        if not err and def.motion ~= nil then motion, err, detail = motionArg(def.motion) end
        if err then return nil, err, detail end
    end
    local mok, merr = K.fillModel(kind, fields)
    if not mok then return nil, merr end
    local persist, global = def.persist, def.global
    if persist ~= nil and type(persist) ~= 'boolean' then return nil, 'persist' end
    if global ~= nil and type(global) ~= 'boolean' then return nil, 'global' end
    persist, global = persist == true, global == true and not dep and def.parent == nil   -- a child rides its root
    local bucket, parent, deps, audience, interact, authority, radius, allowChildren
    bucket, err = V.bucket(def.bucket)
    if err then return nil, err end
    if def.parent ~= nil then
        parent = nodes[toId(def.parent) or 0]
        if parent and def.bucket == nil then bucket = parent.bucket end    -- a child defaults to its parent's bucket
        if not parent or parent.bucket ~= bucket or (parent.k and parent.k.dependency)
            or depthOf(parent) + 1 > MAX_DEPTH or (persist and not parent.persist) then return nil, 'parent' end
        if not V.childAllowed(parent, owner) then return nil, 'owner' end   -- review F13: a foreign parent
    end
    deps, err = checkDeps(kind, fields, persist)
    if err then return nil, err end
    audience, err = V.audience(def.audience, persist)
    if err or (dep and audience) then return nil, 'audience' end
    interact, err = V.interact(def.interact)
    if err or (dep and interact) then return nil, 'interact' end
    authority, err = V.authority(def.authority)
    if not err then radius, err = radiusArg(def.radius, global) end
    if not err then allowChildren, err = V.allowChildren(def.allowChildren) end
    if err then return nil, err end
    if not limitOk(owner, global, persist)
        or (parent and #(rootOf(parent).children or EMPTY) >= maxChildren()) then return nil, 'limit' end
    local Hooks, A = rawget(Core, 'Hooks'), kind.class == 'audio' and R.audio or nil
    local payload
    if (Hooks and Hooks.run) or (A and A.admit) then
        payload = { kind = kind.id, owner = owner, bucket = bucket, pos = v3(pos), parent = parent and parent.id,
            offset = v3(offset), fields = Utils.deepCopy(fields), persist = persist, global = global,
            audience = V.audienceData(audience), radius = radius }
    end
    if Hooks and Hooks.run then
        local allowed, reason = Hooks.run('scene:beforeSpawn', payload)
        if not allowed then return nil, 'hook', reason end
    end
    if A and A.admit then                        -- B2's spawn policy, last: every pass costs a flood-guard token
        local admitted, code = A.admit(payload, owner)
        if not admitted then return nil, code end
    end
    local id = allocId()
    if not id then return nil, 'limit' end
    local node = { id = id, kind = kind.id, k = kind, owner = owner, bucket = bucket, pos = pos or v3(ZERO),
        rot = rot or v3(ZERO), parent = parent and parent.id, offset = offset, offrot = offrot, bone = bone,
        rotOrder = rotOrder, motion = motion, fields = fields, audience = audience, fixedRadius = radius,
        global = global, persist = persist, interact = interact, authority = authority, deps = deps,
        allowChildren = allowChildren }
    if parent then                                                   -- a child's pos / rot: its world pose (info)
        local x, y, z, rx, ry, rz = pose(node)
        node.pos, node.rot = { x = x, y = y, z = z }, { x = rx, y = ry, z = rz }
    end
    node.radius = K.radius(kind, node)
    node.tier = not dep and K.tier(node.radius, global) or nil
    bumpVer(node)
    link(node)
    if parent then
        local root = rootOf(node)
        root.children = root.children or {}
        root.children[#root.children + 1] = id
    end
    if not dep then R.index.put(node) end
    if persist then
        S.persistNew()
        markDirty(id)
    else
        Registry.track(NODE_KIND, id, owner)
    end
    fire('spawned', node)
    return id
end

--- Scene.set(id, patch, opts?) -> ok, err, detail. `patch` merges into the fields (the result is checked whole);
--- opts.remove deletes optional fields; opts.interact / audience / radius replace those (false clears).
function Scene.set(id, patch, opts)
    if not ensureLoaded() then return false, 'unavailable' end
    local node = nodes[toId(id) or 0]
    if not node then return false, 'missing' end
    if not ownerOk(node) then return false, 'owner' end
    if (patch ~= nil and type(patch) ~= 'table') or (opts ~= nil and type(opts) ~= 'table') then return false, 'def' end
    opts = opts or EMPTY
    local kind = node.k
    local dep, err = kind and kind.dependency
    local fields, changed, removed, deps = nil, nil, nil, node.deps
    if (patch and next(patch) ~= nil) or opts.remove ~= nil then
        if not kind then return false, 'kind' end
        local merged = {}
        for k, v in pairs(node.fields) do merged[k] = v end
        for k, v in pairs(patch or EMPTY) do merged[k] = v end
        if type(opts.remove) == 'table' then
            for i = 1, math.min(#opts.remove, 64) do merged[opts.remove[i]] = nil end
        elseif opts.remove ~= nil then
            return false, 'def'
        end
        local ok, out = K.check(kind, merged, false)
        if not ok then return false, 'fields', out end
        local tag = Registry.getCaller() ~= 'core' and K.reservedChange(out, node.fields)
        if tag then return false, 'fields', { [tag] = 'reserved' } end     -- set / change / remove: core only
        if kind.hasModel and out.model ~= node.fields.model then
            for name in pairs(kind.derived or EMPTY) do          -- the old model's vtype goes, unless patched in
                if (patch or EMPTY)[name] == nil then out[name] = nil end
            end
            local mok, merr = K.fillModel(kind, out)
            if not mok then return false, merr end
        elseif kind.hasModel then
            for name in pairs(kind.filled or EMPTY) do out[name] = node.fields[name] end
            local mok, merr = K.fillModel(kind, out, true)       -- a derived field removed here comes back
            if not mok then return false, merr end
        end
        deps, err = checkDeps(kind, out, node.persist)
        if err then return false, err end
        changed, removed = {}, {}
        for k, v in pairs(out) do if not same(v, node.fields[k]) then changed[k] = v end end
        for k in pairs(node.fields) do if out[k] == nil then removed[#removed + 1] = k end end
        if next(changed) ~= nil or #removed > 0 then fields = out end
    end
    local interact, iChange = node.interact, false
    if opts.interact ~= nil then
        if opts.interact == false then interact = nil else interact, err = V.interact(opts.interact) end
        if err or (dep and interact) then return false, 'interact' end
        iChange = not same(interact, node.interact)
    end
    local audience, aChange = node.audience, false
    if opts.audience ~= nil then
        if opts.audience == false then audience = nil else audience, err = V.audience(opts.audience, node.persist) end
        if err or (dep and audience) then return false, 'audience' end
        aChange = audience ~= nil or node.audience ~= nil
    end
    local fixed = node.fixedRadius
    if opts.radius ~= nil then
        if dep then return false, 'radius' end
        if opts.radius == false then fixed = nil else fixed, err = radiusArg(opts.radius, node.global) end
        if err then return false, err end
    end
    local allow, cChange = node.allowChildren, false
    if opts.allowChildren ~= nil then
        allow, err = V.allowChildren(opts.allowChildren)
        if err then return false, err end
        cChange = not same(allow, node.allowChildren)
    end
    if not (fields or iChange or aChange or cChange or fixed ~= node.fixedRadius) then return true end
    if fields then beforeChange(node, 'set') end          -- a fields change only (C1: not interact / audience / radius)
    node.allowChildren = allow                            -- server-side only: no index call
    if not (fields or iChange or aChange or fixed ~= node.fixedRadius) then   -- allowChildren only
        touch(node)
        fire('changed', node, 'set')
        return true
    end
    local oldRadius, oldTier, depsChanged = node.radius, node.tier, fields ~= nil and not same(deps, node.deps)
    if fields then node.fields = fields end
    if depsChanged then setDeps(node, deps) end
    node.interact, node.audience, node.fixedRadius = interact, audience, fixed
    if not dep then
        node.radius = K.radius(kind, node)
        node.tier = K.tier(node.radius, node.global)
    end
    bumpVer(node)
    local patchOut = fields and { f = changed, x = removed[1] and removed or nil, d = depsChanged and deps or nil }
    if dep then
        if patchOut then R.index.changed(node, 'set', patchOut) end
    elseif aChange or node.radius ~= oldRadius or node.tier ~= oldTier then
        R.index.put(node)
    else
        if patchOut then R.index.changed(node, 'set', patchOut) end
        if iChange then R.index.changed(node, 'interact') end
    end
    touch(node)
    fire('changed', node, 'set')
    return true
end

--------------------------------------------------------------------------------
-- The API: move / motion / attach / detach / remove
--------------------------------------------------------------------------------

--- The node for a mutating call: exists, owned by the caller (or core), optionally not a dependency.
local function mine(id, notDep)
    if not ensureLoaded() then return nil, 'unavailable' end
    local node = nodes[toId(id) or 0]
    if not node then return nil, 'missing' end
    if not ownerOk(node) then return nil, 'owner' end
    if notDep and node.k and node.k.dependency then return nil, 'dependency' end
    return node
end

local function changedDone(node, what)
    touch(node)
    fire('changed', node, what)
    return true
end

--- Scene.move(id, pos, rot?, { duration?, ease? }): a teleport (absolute motions end), or a tween from the current
--- pose. For a child or an attached node pos / rot are its offset / offrot (no tween; opts.rotOrder 0..5 replaces
--- its rotation order, which is kept when not given).
function Scene.move(id, pos, rot, opts)
    local node, err = mine(id, true)
    if not node then return false, err end
    if opts ~= nil and type(opts) ~= 'table' then return false, 'def' end
    local duration = opts and opts.duration
    if node.parent or node.attach then
        if duration ~= nil then return false, 'parent' end
        local offset, offrot, rotOrder
        offset, err = V.offset(pos)
        if not err and rot ~= nil then offrot, err = V.rot(rot, 'offrot') end
        if not err and opts then rotOrder, err = V.rotOrder(opts.rotOrder) end
        if err then return false, err end
        beforeChange(node, 'move')
        node.offset, node.offrot = offset, offrot or node.offrot or v3(ZERO)
        if rotOrder ~= nil then node.rotOrder = rotOrder end
        bumpVer(node)
        R.index.changed(node, 'move')
        return changedDone(node, 'move')
    end
    local p, r = V.pos(pos)
    if not p then return false, r end
    r = node.rot
    if rot ~= nil then
        r, err = V.rot(rot)
        if err then return false, err end
    end
    local oldMotion = node.motion
    if duration ~= nil then
        local d, ease = toint(duration), opts.ease == nil and 'inout' or opts.ease
        if not d or d < 1 or d > 600000 then return false, 'duration' end
        if not EASE[ease] then return false, 'ease' end
        beforeChange(node, 'move')
        local now = R.now()
        local x, y, z, rx, ry, rz = pose(node, now)
        local m, merr, detail = motionArg({ t = 'tween', t0 = R.add(now, planLead()), d = d, e = ease,
            from = { x = x, y = y, z = z, rx = rx, ry = ry, rz = rz },
            to = { x = p.x, y = p.y, z = p.z, rx = r.x, ry = r.y, rz = r.z } })
        if not m then return false, merr, detail end
        setMotion(node, m)
    else
        beforeChange(node, 'move')
        if oldMotion and not RELATIVE[oldMotion.t] then setMotion(node, nil) end
    end
    if node.motion ~= oldMotion then driving[node.id] = nil end
    node.pos, node.rot = p, r
    bumpVer(node)
    R.index.changed(node, 'move')
    if node.motion ~= oldMotion then R.index.changed(node, 'motion') end
    return changedDone(node, 'move')
end

--- Scene.motion(id, descriptor | nil): C3 (§55.9); t0 defaults to Clock.at(Motion.PlanLeadMs). Roots only.
function Scene.motion(id, desc)
    local node, err = mine(id, true)
    if not node then return false, err end
    if node.parent or node.attach then return false, 'parent' end
    local m, detail
    if desc ~= nil then
        m, err, detail = motionArg(desc)
        if not m then return false, err, detail end
    elseif node.motion == nil then
        return true
    end
    beforeChange(node, 'motion')
    setMotion(node, m)
    driving[node.id] = nil
    bumpVer(node)
    R.index.changed(node, 'motion')
    return changedDone(node, 'motion')
end

--- Every node of a subtree gets a new ver and a PUT (parent first) — after a re-parent / detach.
local function reput(node)
    local list = descendants(node.id, { node.id })
    for i = 1, #list do
        local n = nodes[list[i]]
        bumpVer(n)
        R.index.put(n)
    end
end

local function clampPos(x, y, z)
    local function c(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end
    return { x = c(x, -10000, 10000), y = c(y, -10000, 10000), z = c(z, -1000, 3000) }
end

--- A child becomes a root at its current world pose; a player / net attachment ends there.
local function detachNode(node)
    local x, y, z, rx, ry, rz = pose(node)
    if node.parent then
        local oldRoot = rootOf(node)
        R.index.remove(node, Codec.DEL.HANDOVER)
        unparent(node)
        node.parent, node.offset, node.offrot, node.bone, node.rotOrder = nil, nil, nil, nil, nil
        node.pos, node.rot = clampPos(x, y, z), V.rot({ x = rx, y = ry, z = rz })
        if nodes[oldRoot.id] then rebuildChildren(oldRoot) end
        rebuildChildren(node)
        reput(node)
    elseif node.attach then
        node.attach, node.offset, node.offrot, node.bone, node.rotOrder = nil, nil, nil, nil, nil
        node.pos, node.rot = clampPos(x, y, z), V.rot({ x = rx, y = ry, z = rz })
        bumpVer(node)
        R.index.changed(node, 'attach')
        R.index.changed(node, 'move')
    else
        return false
    end
    return true
end

local attachedTo = {}                -- [src] = { [id] = true }: player attachments (detached on drop)
local netAttached, netCount = {}, 0  -- [id] = true: { net } attachments (the watcher ends dead ones, review F20)
local netList, netAt, netWatching = nil, 1, false
local NET_CHECK_MS <const>, NET_CHECK_BATCH <const> = 1000, 256

--- One slice of the { net } watcher: an attachment whose net id no longer names its entity ends at the last pose.
local function checkNet()
    if not netList or netAt > #netList then
        netList, netAt = {}, 1
        for id in pairs(netAttached) do netList[#netList + 1] = id end
    end
    local last = math.min(#netList, netAt + NET_CHECK_BATCH - 1)
    for i = netAt, last do
        local id = netList[i]
        local node = nodes[id]
        local a = node and node.attach
        if not (a and a.net) then
            if netAttached[id] then netAttached[id], netCount = nil, netCount - 1 end
        elseif not S.netTarget(a) then
            netAttached[id], netCount = nil, netCount - 1
            if detachNode(node) then changedDone(node, 'detach') end
        end
    end
    netAt = last + 1
end

local function watchNet(id, on)
    if not on then
        if netAttached[id] then netAttached[id], netCount = nil, netCount - 1 end
        return
    end
    if netAttached[id] then return end
    netAttached[id], netCount = true, netCount + 1
    if netWatching then return end
    netWatching = true
    CreateThread(function()
        while netCount > 0 do
            Wait(NET_CHECK_MS)
            local ok, err = pcall(checkNet)
            if not ok then Log.error('scene: the net attachment check failed: %s', tostring(err)) end
        end
        netWatching, netList = false, nil
    end)
end

local function trackAttach(node, a)
    local old = node.attach
    if old and old.player and attachedTo[old.player] then attachedTo[old.player][node.id] = nil end
    if old and old.net then watchNet(node.id, false) end
    if a and a.player then
        attachedTo[a.player] = attachedTo[a.player] or {}
        attachedTo[a.player][node.id] = true
    end
    if a and a.net then watchNet(node.id, true) end
end

--- Scene.attach(id, { node = id } | { player = src } | { net = netId }, { offset?, offrot?, bone?, rotOrder? }).
--- A node target re-parents (same bucket, depth <= 4, no cycle, persistent under persistent); player / net targets
--- are transient attachments of a root (not persisted; a dropped player's attachments end at the last pose).
--- rotOrder (0..5, nil = the engine's 2) is the order the clients apply offrot in (AttachEntityToEntity).
function Scene.attach(id, target, opts)
    local node, err = mine(id, true)
    if not node then return false, err end
    if type(target) ~= 'table' or (opts ~= nil and type(opts) ~= 'table') then return false, 'attach' end
    opts = opts or EMPTY
    local offset, offrot, bone, rotOrder
    offset, err = V.offset(opts.offset)
    if not err then offrot, err = V.rot(opts.offrot, 'offrot') end
    if not err then bone, err = V.bone(opts.bone) end
    if not err then rotOrder, err = V.rotOrder(opts.rotOrder) end
    if err then return false, err end
    if target.node ~= nil then
        local p = nodes[toId(target.node) or 0]
        if not p or p.bucket ~= node.bucket or (p.k and p.k.dependency) or (node.persist and not p.persist)
            or depthOf(p) + 1 + heightOf(node.id) > MAX_DEPTH then return false, 'parent' end
        local a = p
        while a do
            if a == node then return false, 'parent' end              -- a cycle: the target is inside the subtree
            a = a.parent and nodes[a.parent]
        end
        if not V.childAllowed(p, Registry.getCaller()) then return false, 'owner' end   -- review F13
        local oldRoot, newRoot = rootOf(node), rootOf(p)
        if newRoot ~= oldRoot and #(newRoot.children or EMPTY) + 1 + #descendants(node.id, {}) > maxChildren() then
            return false, 'limit'
        end
        beforeChange(node, 'attach')
        R.index.remove(node, Codec.DEL.HANDOVER)
        if node.parent then unparent(node) end
        trackAttach(node, nil)
        node.parent, node.offset, node.offrot, node.bone, node.rotOrder = p.id, offset, offrot, bone, rotOrder
        node.attach = nil
        setMotion(node, nil)
        node.children, driving[node.id] = nil, nil
        kidsOf[p.id] = kidsOf[p.id] or {}
        kidsOf[p.id][node.id] = true
        if oldRoot ~= node and nodes[oldRoot.id] then rebuildChildren(oldRoot) end
        rebuildChildren(rootOf(node))
        reput(node)
    elseif target.player ~= nil or target.net ~= nil then
        if node.parent then return false, 'parent' end
        local a
        if target.player ~= nil then
            local src = toId(target.player)
            if not src or src > 65535 or GetPlayerPed(src) == 0 then return false, 'attach' end
            a = { player = src }
        else
            local net = toId(target.net)
            local e = net and net <= 65535 and NetworkGetEntityFromNetworkId(net) or 0
            if e == 0 or not DoesEntityExist(e) then return false, 'attach' end
            a = { net = net, ent = e, model = GetEntityModel(e) }    -- the identity it must keep (review F20)
        end
        beforeChange(node, 'attach')
        trackAttach(node, a)
        local hadMotion = node.motion ~= nil
        node.attach, node.offset, node.offrot, node.bone, node.rotOrder = a, offset, offrot, bone, rotOrder
        setMotion(node, nil)
        driving[node.id] = nil
        bumpVer(node)
        R.index.changed(node, 'attach')
        if hadMotion then R.index.changed(node, 'motion') end
    else
        return false, 'attach'
    end
    return changedDone(node, 'attach')
end

function Scene.detach(id)
    local node, err = mine(id, true)
    if not node then return false, err end
    if node.parent or node.attach then beforeChange(node, 'detach') end
    trackAttach(node, nil)
    if not detachNode(node) then return true end
    return changedDone(node, 'detach')
end

local dirtyRoots, flushQueued = {}, false   -- roots whose children list waits for one rebuild (review F3)

--- Rebuilds every dirty root still in the store once: O(children) per operation, never per removed child.
local function flushRoots()
    flushQueued = false
    for root in pairs(dirtyRoots) do
        dirtyRoots[root] = nil
        if nodes[root.id] == root then rebuildChildren(root) end
    end
end

--- Removes `node` with its subtree (and, for a dependency, its dependents): the index first (it reads the
--- subtree), then the records; `gone` collects { node, reason } for the 'removed' hooks; the root it hung under
--- is marked for one rebuild (flushRoots).
local function removeTree(node, how, reason, gone)
    local parent = node.parent and nodes[node.parent]
    local root = parent and rootOf(parent)
    R.index.remove(node, how)
    local deps = dependents[node.id]
    if deps then
        local list = {}
        for d in pairs(deps) do list[#list + 1] = d end
        table.sort(list)
        for i = 1, #list do
            local d = nodes[list[i]]
            if d then removeTree(d, how, 'source', gone) end
        end
    end
    local sub = descendants(node.id, {})
    for i = #sub, 1, -1 do
        local c = nodes[sub[i]]
        if c then
            unlink(c)
            if c.persist then markDirty(c.id) else Registry.untrack(NODE_KIND, c.id) end
            gone[#gone + 1] = { c, 'parent' }
        end
    end
    unlink(node)
    if node.persist then markDirty(node.id) else Registry.untrack(NODE_KIND, node.id) end
    gone[#gone + 1] = { node, reason }
    if root then dirtyRoots[root] = true end
end

--- `defer`: the owner sweep hands out one id at a time, so its roots are rebuilt once after the sweep.
local function removeAll(node, how, reason, defer)
    local gone = {}
    removeTree(node, how, reason, gone)
    for i = 1, #gone do
        local n = gone[i][1]
        local a = n.attach
        if a and a.player and attachedTo[a.player] then attachedTo[a.player][n.id] = nil end
        if a and a.net then watchNet(n.id, false) end
    end
    if not defer then
        flushRoots()
    elseif not flushQueued then
        flushQueued = true
        SetTimeout(0, flushRoots)                    -- the stop handler below flushes first; this is the fallback
    end
    for i = 1, #gone do fire('removed', gone[i][1], gone[i][2]) end
end

--- Scene.remove(id, { fade? }): the subtree goes with it; clients delete visibility-safely either way.
function Scene.remove(id, opts)
    local node, err = mine(id)
    if not node then return false, err end
    removeAll(node, (type(opts) == 'table' and opts.fade == true) and Codec.DEL.FADE or Codec.DEL.NORMAL, 'remove')
    return true
end

-- A stopped owner: its non-persistent nodes go (persistent ones stay, and are never tracked). The Registry sweep
-- (server/api.lua's onResourceStop handler, registered first) hands the ids out one by one: roots are rebuilt once,
-- by the handler below, which runs right after it.
Registry.onOwnerStop(NODE_KIND, function(id)
    local node = nodes[id]
    if node and not node.persist then removeAll(node, Codec.DEL.NORMAL, 'owner', true) end
end)
AddEventHandler('onResourceStop', function() if next(dirtyRoots) then flushRoots() end end)

--------------------------------------------------------------------------------
-- C4 events, C2 driving
--------------------------------------------------------------------------------

--- Scene.emit(id | { pos, bucket? }, name, params?, { radius?, horizonMs? }) -> ok: a one-shot to the clients
--- near it (not journaled). A node event is the owner's (or core's); a positional one anyone's (server API).
function Scene.emit(target, name, params, opts)
    if not ensureLoaded() then return false, 'unavailable' end
    if type(name) ~= 'string' or #name > 32 or not name:find(EVENT_NAME) then return false, 'name' end
    if opts ~= nil and type(opts) ~= 'table' then return false, 'def' end
    opts = opts or EMPTY
    local now, node, x, y, z, bucket, radius, err = R.now()
    if type(target) == 'table' then
        local p
        p, err = V.pos(target.pos)
        if not err then bucket, err = V.bucket(target.bucket) end
        if err then return false, err end
        x, y, z, radius = p.x, p.y, p.z, 150
    else
        node, err = mine(target, true)
        if not node then return false, err end
        x, y, z = pose(node, now)
        bucket, radius = node.bucket, node.radius
    end
    if opts.radius ~= nil then
        if not isFinite(opts.radius) or opts.radius < 1 or opts.radius > (cfg().TierL or 1500) then
            return false, 'radius'
        end
        radius = opts.radius
    end
    local horizon = opts.horizonMs == nil and 2000 or toint(opts.horizonMs)
    if not horizon or horizon < 0 or horizon > 30000 then return false, 'horizonMs' end
    local data
    if params ~= nil then
        data, err = V.plain(params, EVENT_PARAMS_MAX)
        if err then return false, 'params' end
    end
    R.index.event(node, x, y, z, bucket, name, data, now, radius, horizon)
    return true
end

--- Scene.drive(id, pos, vel, yaw) -> ok, sent. The server keeps the clients' dead-reckoned copy (a 'dr' motion):
--- the first call makes it the node's motion (a MOTION op); later calls send a DR op only when the copy errs more
--- than DeadReckoning.Near (S/M tiers) / Far (L/G) metres or Degrees, or HeartbeatMs passed — at most NearHz /
--- FarHz per node.
function Scene.drive(id, pos, vel, yaw)
    local node, err = mine(id, true)
    if not node then return false, err end
    if node.parent then return false, 'parent' end
    if node.attach then return false, 'attach' end
    local p
    p, err = V.pos(pos)
    if err then return false, err end
    local vx, vy, vz = V.xyz(vel == nil and ZERO or vel)
    if not vx or vx * vx + vy * vy + vz * vz > 300 * 300 then return false, 'vel' end
    if yaw == nil then yaw = node.rot.z end
    if not isFinite(yaw) then return false, 'yaw' end
    yaw = V.wrap(yaw)
    beforeChange(node, 'drive')
    local dr, now = cfg().DeadReckoning or EMPTY, R.now()
    local desc = { t = 'dr', t0 = now, p = { x = p.x, y = p.y, z = p.z }, v = { x = vx, y = vy, z = vz }, yaw = yaw }
    local m, last = node.motion, driving[node.id]
    if not (m and m.t == 'dr') then
        local ok, norm = Motion.validate(desc)
        if not ok then return false, 'motion', norm end
        setMotion(node, norm)
        node.pos, node.rot = p, { x = node.rot.x, y = node.rot.y, z = yaw }
        driving[node.id] = { at = now }
        bumpVer(node)
        R.index.changed(node, 'motion')
        changedDone(node, 'motion')
        return true, true
    end
    local near = node.tier == 'S' or node.tier == 'M'
    local age = R.diff(now, last and last.at or m.t0)
    if age < 1000 / ((near and dr.NearHz or dr.FarHz) or 10) then return true, false end
    local x, y, z, _, _, rz = pose(node, now)
    local limit = near and (dr.Near or 0.25) or (dr.Far or 1.0)
    local dx, dy, dz = p.x - x, p.y - y, p.z - z
    if dx * dx + dy * dy + dz * dz <= limit * limit and math.abs(V.wrap(yaw - rz)) <= (dr.Degrees or 3)
        and age < (dr.HeartbeatMs or 5000) then
        return true, false
    end
    local ok, norm = Motion.validate(desc)
    if not ok then return false, 'motion', norm end
    node.motion, node.pos, node.rot = norm, p, { x = node.rot.x, y = node.rot.y, z = yaw }   -- a mover already
    if last then last.at = now else driving[node.id] = { at = now } end
    R.index.dr(node, now, p.x, p.y, p.z, vx, vy, vz, yaw)
    touch(node)
    return true, true
end

--------------------------------------------------------------------------------
-- Reads
--------------------------------------------------------------------------------

function Scene.get(id)
    if not ensureLoaded() then return nil end
    local node = nodes[toId(id) or 0]
    return node and copyNode(node) or nil
end

--- Scene.query({ pos, radius, bucket? = 0, kind?, owner?, limit? = 256 }) -> node copies nearest first: the
--- index's cells (near, far, global; gated nodes included) around pos, then an exact test on the current pose.
function Scene.query(q)
    if not ensureLoaded() or type(q) ~= 'table' then return {} end
    local p, radius, bucket = V.pos(q.pos), q.radius, V.bucket(q.bucket)
    local limit = q.limit == nil and 256 or toint(q.limit)
    if not p or not isFinite(radius) or radius <= 0 or radius > 10000 or not bucket or not limit or limit < 1 then
        return {}
    end
    local now, r2, found, seen, kindF, ownerF = R.now(), radius * radius, {}, {}, q.kind, q.owner
    local function consider(n)
        if not n or seen[n.id] then return end
        seen[n.id] = true
        if n.bucket ~= bucket or (kindF and n.kind ~= kindF) or (ownerF and n.owner ~= ownerF) then return end
        local x, y, z = pose(n, now)
        local d2 = (x - p.x) ^ 2 + (y - p.y) ^ 2 + (z - p.z) ^ 2
        if d2 <= r2 then found[#found + 1] = { d2 = d2, n = n } end
    end
    local function visit(list)
        for i = 1, list and #list or 0 do
            local root = nodes[list[i].id]
            consider(root)
            for j = 1, root and root.children and #root.children or 0 do consider(nodes[root.children[j]]) end
        end
    end
    local I, reach = R.index, radius + ((cfg().Motion or EMPTY).RecellTolerance or 8) + 64
    for grid = 0, 1 do
        local keys = I.cellsNear(bucket, p.x, p.y, reach, grid)
        for i = 1, keys and #keys or 0 do
            visit(I.nodesIn(bucket, grid, keys[i]))
            if I.gatedIn then visit(I.gatedIn(bucket, grid, keys[i])) end
        end
    end
    visit(I.nodesIn(bucket, 2, 0))
    if I.gatedIn then visit(I.gatedIn(bucket, 2, 0)) end
    table.sort(found, function(a, b) return a.d2 < b.d2 or (a.d2 == b.d2 and a.n.id < b.n.id) end)
    local out = {}
    for i = 1, math.min(#found, limit, 4096) do out[i] = copyNode(found[i].n) end
    return out
end

--- Scene.list({ owner?, kind?, bucket? }) -> ascending ids.
function Scene.list(filter)
    if not ensureLoaded() or (filter ~= nil and type(filter) ~= 'table') then return {} end
    filter = filter or EMPTY
    local owner, kind, bucket = filter.owner, filter.kind, filter.bucket
    local set = nodes
    if owner ~= nil then set = S.byOwner[owner] or EMPTY elseif kind ~= nil then set = S.byKind[kind] or EMPTY end
    local out = {}
    for id in pairs(set) do
        local n = nodes[id]
        if n and (kind == nil or n.kind == kind) and (owner == nil or n.owner == owner)
            and (bucket == nil or n.bucket == bucket) then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

--- Scene.batch(fn, ...) -> fn's results | nil, 'error'. Changes made inside fn reach the same flush (the index
--- coalesces per node and versions per cell per tick) — fn must not yield (a Wait splits the batch).
function Scene.batch(fn, ...)
    if not Utils.isCallable(fn) then return nil, 'fn' end
    local res = table.pack(pcall(fn, ...))
    if not res[1] then
        Log.warn('scene: batch failed: %s', tostring(res[2]))
        return nil, 'error'
    end
    return table.unpack(res, 2, res.n)
end

--------------------------------------------------------------------------------
-- Kinds, model info, stats, focus, ownership, phase B/C entry points
--------------------------------------------------------------------------------

function Scene.defineKind(def) return K.define(def, Registry.getCaller()) end
function Scene.kinds() return K.public() end
function Scene.setModelInfo(fn) return K.setModelInfo(fn, Registry.getCaller()) end

--- Scene.stats() -> { nodes, byKind, persistent, global, kinds, loaded, cells, subscribers, bytesPerSecond,
--- flushMs = { p50, p99 }, index, interest, flush }.
function Scene.stats()
    local byKind = {}
    for kind, set in pairs(S.byKind) do
        local n = 0
        for _ in pairs(set) do n = n + 1 end
        byKind[kind] = n
    end
    local function sub(t)
        if not (t and t.stats) then return nil end
        local ok, s = pcall(t.stats)
        return ok and s or nil
    end
    local index, interest, flush = sub(R.index), sub(R.interest), sub(R.flush)
    local total, persistent, global = S.counts()
    return { nodes = total, byKind = byKind, persistent = persistent, global = global, kinds = K.count(),
        loaded = S.loaded(), cells = index and index.cells, subscribers = interest and interest.subscribers,
        bytesPerSecond = flush and flush.bytesPerSecond,
        flushMs = flush and { p50 = flush.flushMsP50, p99 = flush.flushMsP99 }, index = index, interest = interest,
        flush = flush, promote = sub(R.promote), audio = sub(R.audio), voice = sub(R.voice) }
end

--- Scene.setFocus(src, pos | nil): a trusted focus pin (§55.6), owner-tracked ('sceneFocus'); nil clears it.
--- A connected player (review F11: a window for a src nobody is behind would live for ever).
local function connected(src)
    local name = GetPlayerName(src)
    return name ~= nil and name ~= ''
end

function Scene.setFocus(src, pos)
    src = toId(src)
    if not src or src > 65535 or not connected(src) then return false end
    if pos == nil then
        R.interest.pin(src, nil)
        Registry.untrack(FOCUS_KIND, src)
        return true
    end
    local p = V.pos(pos)
    if not p then return false end
    R.interest.pin(src, p.x, p.y, p.z)
    Registry.track(FOCUS_KIND, src, Registry.getCaller())
    return true
end
Registry.onOwnerStop(FOCUS_KIND, function(src) R.interest.pin(src, nil) end)

--- Scene.prefetch(src, pos): core-internal (Player.setCoords, §55.6) — subscribes the destination window now.
function Scene.prefetch(src, pos)
    src = toId(src)
    local p = V.pos(pos)
    if not src or src > 65535 or not p or not connected(src) then return false end
    R.interest.prefetch(src, p.x, p.y, p.z)
    return true
end

--- Scene.adopt(id, owner? = 'core') -> ok: core only; re-owns a node (e.g. a persistent node of a gone resource).
function Scene.adopt(id, owner)
    if Registry.getCaller() ~= 'core' then return false, 'owner' end
    if not ensureLoaded() then return false, 'unavailable' end
    local node = nodes[toId(id) or 0]
    if not node then return false, 'missing' end
    owner = owner == nil and 'core' or owner
    if type(owner) ~= 'string' or #owner < 1 or #owner > 64 then return false, 'owner' end
    if owner == node.owner then return true end
    S.setOwner(node, owner)
    if not node.persist then Registry.track(NODE_KIND, node.id, owner) end
    return changedDone(node, 'owner')
end

--- Phase B/C entry points: delegate to R.promote / R.voice / R.audio once those files exist.
local function later(part, fn)
    return function(...)
        local impl = R[part]
        local f = impl and impl[fn]
        if not f then return nil, 'unavailable' end
        return f(...)
    end
end
Scene.promote, Scene.demote = later('promote', 'promote'), later('promote', 'demote')
Scene.lease = later('promote', 'lease')
Scene.voice = { start = later('voice', 'start'), stop = later('voice', 'stop'), list = later('voice', 'list') }
Scene.audio = { kill = later('audio', 'kill') }

--------------------------------------------------------------------------------
-- core:scene:interact (§55.14): schema → cooldown → loaded (Core.Net.on) → node / bucket / audience →
-- descriptor → perm → server-side distance → the descriptor's cooldown → handlers of the id, then of the kind
--------------------------------------------------------------------------------

local useAt = {}                      -- [src] = { n = count, ['<id>:<action>'] = expiry (Clock ms) }
local USES_MAX <const> = 64

--- Is the (player, node, action) cooldown still running?
local function cooling(src, key, now)
    local uses = useAt[src]
    local exp = uses and uses[key]
    return exp ~= nil and R.diff(exp, now) > 0
end

--- Starts a cooldown (review F10): at most USES_MAX RUNNING per player — expired entries are evicted first, and a
--- map full of running cooldowns refuses the interaction instead of forgetting one. -> ok
local function remember(src, key, ms, now)
    if ms <= 0 then return true end
    local uses = useAt[src]
    if not uses then
        uses = { n = 0 }
        useAt[src] = uses
    end
    if uses[key] == nil then
        if uses.n >= USES_MAX then
            for k, e in pairs(uses) do
                if k ~= 'n' and R.diff(e, now) <= 0 then uses[k], uses.n = nil, uses.n - 1 end
            end
            if uses.n >= USES_MAX then return false end
        end
        uses.n = uses.n + 1
    end
    uses[key] = R.add(now, ms)
    return true
end

local function dispatch(key, src, node, action, data)
    local list = S.interactBy[key]
    if not list or #list == 0 then return end
    local snapshot = table.move(list, 1, #list, 1, {})
    for i = 1, #snapshot do
        local e = S.handles[snapshot[i]]
        if e and nodes[node.id] then
            local ok, err = pcall(e.fn, src, copyNode(node), action, data ~= nil and Utils.deepCopy(data) or nil)
            if not ok then Log.warn('scene: interact handler of %s failed: %s', e.owner, tostring(err)) end
        end
    end
end

local function onInteract(src, id, action, data)
    if not S.loaded() then return end
    local node = nodes[id]
    if not node or (node.k and node.k.dependency) or GetPlayerRoutingBucket(src) ~= node.bucket then return end
    local n, guard = node, 0
    while n and guard <= MAX_DEPTH do                 -- every level with an audience must admit src (review F2)
        if n.audience and not R.interest.allows(n, src) then return end
        n, guard = n.parent and nodes[n.parent], guard + 1
    end
    local d
    for i = 1, node.interact and #node.interact or 0 do
        if node.interact[i].action == action then d = node.interact[i] break end
    end
    if not d or (d.perm and not Core.Perms.has(src, d.perm)) then return end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return end
    local c, now = GetEntityCoords(ped), R.now()
    local x, y, z = pose(node, now)                   -- a promoted node: its clone's pose
    local reach = d.distance + 2
    if (c.x - x) ^ 2 + (c.y - y) ^ 2 + (c.z - z) ^ 2 > reach * reach then return end
    local key = id .. ':' .. action
    if cooling(src, key, now) then return end
    local PR = R.promote                              -- a lease of another player refuses (phase C)
    if PR and PR.refuses and PR.refuses(src, node, action) then return end
    if data ~= nil then                               -- last: the cheap checks decide first
        local clean, err = V.plain(data, INTERACT_DATA_MAX)
        if err then return end
        data = clean
    end
    if not remember(src, key, d.cooldownMs, now) then return end
    dispatch(id, src, node, action, data)
    dispatch(node.kind, src, node, action, data)
    if PR and PR.onInteract then pcall(PR.onInteract, src, node, action, data) end
end

Core.Net.on('core:scene:interact', { { 'integer', min = 1, max = 0x7FFFFFFF },
    { 'string', max = 32, pattern = '^[%w_%-]+$' }, 'any?' }, onInteract, { cooldown = 250 })

AddEventHandler('playerDropped', function()
    local src = source
    useAt[src] = nil
    Registry.untrack(FOCUS_KIND, src)
    local set = attachedTo[src]
    if not set then return end
    attachedTo[src] = nil
    local list = {}
    for id in pairs(set) do list[#list + 1] = id end
    table.sort(list)
    for i = 1, #list do
        local node = nodes[list[i]]
        if node and node.attach and node.attach.player == src and detachNode(node) then
            changedDone(node, 'detach')
        end
    end
end)
