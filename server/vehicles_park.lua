--[[
    core/server/vehicles_park.lua — parked vehicles (DESIGN §55.21.4): the records and their scene nodes. Loads RIGHT
    AFTER server/vehicles.lua and takes its live maps and helpers once through the one-shot global CoreVehiclesPark
    (P, asserted); it adds its own helpers to P and leaves the global for server/vehicles_fleet.lua (AutoPark, the
    boot / stop reconciliation, MaxParked), which loads right after it and clears it.

      Vehicles.park(netId | vehId) -> nodeId | nil, err     a persisted vehicle becomes a persistent scene `vehicle`
          node owned by core: fields { model (the name when known, else the hash), props (the cached / record props;
          the owner client's read-back may change only the damage / wear keys, Scene.mergeWear), plate, locked, vehId,
          vtype (record meta.vehType) }, the entity's pose and bucket, authority { mode = 'local' } (no proximity
          promotion: enter / damage / actions still promote, D-B). A LIVE car is handed over, never deleted first
          (review RV6 F11): its node is spawned, the car becomes the node's clone (R.promote.adopt) and is demoted
          on the normal path (the owner's wear read, DEMOTE, the clone deleted DeleteDelayMs later); without that
          engine path the car stays frozen and locked until the local copies exist (DeleteDelayMs + 500 ms).
          The record gets parked = nodeId, stored = false, position (+ bucket), props, locked, keys.
      Vehicles.getInfoByRecord(vehId) -> info | nil          live, parked or garaged: getInfo's fields + parked,
                                                             stored, position, destroyed
      Vehicles.setLocked / giveKeys / removeKeys / setOwner(vehId, …) (review RV4 F13): a vehId acts on its live car,
          else on the record (and a parked node's `locked` field) — no promotion needed.
      wrapped (the rest is server/vehicles.lua's): spawnRecord (a parked record is promoted where it stands and the
          clone's netId returned after a bounded wait), restoreRecord ('parked'), store (netId | vehId: the node
          goes), delete (a clone takes its node along, except while core stops), deleteRecord (the node goes).
    Scene hooks (as core, kind 'vehicle', only core-owned nodes whose record parks them): promoted → the clone is
    adopted (the §8 bags, spawned / byVehId / clones, info.parked, vehicleSpawned); demoted (copy, info) → props (the
    node's, whose wear the engine merged from the owner's read-back; cosmetics a key holder saved while promoted win),
    pose (+ bucket), lock and keys into the record, the node's fields follow; the clone untracked (vehicleDeleted).
    A WRECKED clone (info.destroyed, D-C) never resurrects: the record keeps its last saved state and is marked
    destroyed = true, parked = false, the node is removed (spawnRecord brings it back; restoreRecord and the boot
    re-park refuse it). A lost (vanished, not wrecked) clone's node stays at its last pose with its last wear.
    Removed by anyone else → the record is out again. Every props write re-imposes props.plate = the record's plate.
    The lock key on a parked car's local copy: core:server:parkedLock(nodeId) (client/vehicles.lua) toggles the
    record's `locked` and the node field after the same checks as core:server:vehicleLock (keys, distance).
    Since the §56 port this file also holds the record reads of server/vehicles.lua (getRecord / getRecords /
    deleteRecord) and its spawnRecord / restoreRecord; the vehId setters (setLocked / giveKeys / removeKeys /
    setOwner by vehId) and the §5 net events are server/vehicles_fleet.lua's (the files' size).
    Database (§56): the hooks, the lock key, delete and the stop paths read only P.recs (the mirror of the world
    records, server/vehicles.lua) and QUEUE their writes (P.write: only the changed columns, never `meta`); a
    public call on a record the mirror lacks reads it (awaited). A hook that misses the mirror before the boot check
    read the world records (P.recovered) reads the record in a thread and runs again. Every LRU touch (a park, a
    promotion, a demotion, the lock key) stamps last_used_at (queued).

    Natives (fxref + natives_cfx.json 2026-09-27, server / CFX forms; BOOL answers read by truthiness):
      GetEntityCoords(entity), GetEntityRotation(entity), GetEntityRoutingBucket(entity),
      NetworkGetEntityFromNetworkId(netId), NetworkGetNetworkIdFromEntity(entity), NetworkGetEntityOwner(entity)
      (shared; -1 = the server), DoesEntityExist(entity), DeleteEntity(entity), GetPedInVehicleSeat(vehicle,
      seatIndex), GetPlayerRoutingBucket(playerSrc), GetResourceState(resourceName) (shared), SetVehicleDoorsLocked(
      vehicle, doorLockStatus) and FreezeEntityPosition(entity, toggle) (server RPC forms), GetGameTimer().
      Runtime: Entity(e).state, vector3, Wait, SetTimeout.
]]

local P = CoreVehiclesPark
assert(type(P) == 'table' and P.spawned and P.track and P.writeState and P.cleanProps,
    'server/vehicles_park.lua loads right after server/vehicles.lua (CoreVehiclesPark)')

local Vehicles, Validate, Utils, Log, DB = Core.Vehicles, Core.Validate, Core.Utils, Core.Log, Core.DB
local spawned, byVehId, clones, recs, spawning = P.spawned, P.byVehId, P.clones, P.recs, P.spawning
local entityOf, forget, track, writeState, publicInfo = P.entityOf, P.forget, P.track, P.writeState, P.publicInfo
local validateProps, cleanProps, positionOf = P.validateProps, P.cleanProps, P.positionOf
local write, readRecord, fromRead, mirrorOf, markWrite = P.write, P.readRecord, P.fromRead, P.mirrorOf, P.markWrite
local toint, mtype = math.tointeger, math.type

local TABLE <const> = 'vehicles'
local SEAT_FIRST <const>, SEAT_LAST <const> = -1, 15
local PROPS_TIMEOUT_MS <const> = 1000             -- the owner client's props before a car is parked (stop-gap path)
local UNPARK_EXTRA_MS <const> = 6000              -- spawnRecord of a parked car: the promotion queue + its 5 s wait
local RETIRE_EXTRA_MS <const> = 500               -- stop-gap: the car outlives its node's PUT by DeleteDelayMs + this
local LOCK_LOCKED <const> = 2
local EMPTY <const> = setmetatable({}, { __newindex = function() error('read-only', 2) end })
local PARKED_AUTHORITY <const> = { mode = 'local' } -- D-B: no proximity promotion (Scene.spawn copies it)

local removing = {}     -- [nodeId] = true while this file removes a parked node itself (the removed hook skips it)
local handoff = {}      -- [nodeId] = { netId, info } while parkLive hands a live car to its node (R.promote.adopt)
local retiring = {}     -- [entity] = { netId, vehId }: stop-gap cars that go once the local copies exist
local hooked = false    -- the Core.Scene hooks are registered (server/scene.lua loads after this file)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Deep equality of plain data (props compared across a promotion).
local function same(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then return false end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

--- keys { [charId] = true } -> the record's sorted array; the record's array (+ the virtual owner key) -> the set.
local keyList = P.keyList

local function keySet(list, owner, keyMode)
    local keys = {}
    for i = 1, type(list) == 'table' and #list or 0 do
        if Validate.value('id', list[i]) then keys[list[i]] = true end
    end
    if owner and keyMode == 'virtual' then keys[owner] = true end
    return keys
end

local function occupied(entity)
    for seat = SEAT_FIRST, SEAT_LAST do
        local ped = GetPedInVehicleSeat(entity, seat)
        if ped and ped ~= 0 then return true end
    end
    return false
end

local function finite(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end

local function stopping()
    return P.stopped == true or GetResourceState(Core.name) == 'stopping'
end

--- Core.Scene[name](...) as core (parked nodes are core's, whoever asked) -> its results; nil, 'unavailable'
--- without the scene API (offline suites without it), nil, 'error' when it raised.
local function sc(name, ...)
    local S = Core.Scene
    local fn = type(S) == 'table' and S[name] or nil
    if type(fn) ~= 'function' then return nil, 'unavailable' end
    local r = table.pack(Core.Registry.withCaller('core', fn, ...))
    if not r[1] then
        Log.error('vehicles: Scene.%s failed: %s', name, tostring(r[2]))
        return nil, 'error'
    end
    return table.unpack(r, 2, r.n)
end

--- `stored` with ONLY the damage / wear keys of `readBack` merged in (lib/scene/shared.lua Scene.mergeWear, I-1:
--- clamped, bad values dropped) — a read-back never changes mods, colours or the plate. nil without the lib.
local function mergeWear(stored, readBack)
    local S = Core.Scene
    local fn = type(S) == 'table' and S.mergeWear or nil
    if type(fn) ~= 'function' then return nil end
    return fn(stored, readBack)
end

--- The props a record / node stores: a copy with props.plate = the record's plate (review RV4 F1).
local function platedProps(props, plate)
    local p = type(props) == 'table' and Utils.deepCopy(props) or {}
    if type(plate) == 'string' then p.plate = plate end
    return p
end

--- The node id a record is parked as (an integer), or nil.
local function parkedOf(record)
    local v = type(record) == 'table' and record.parked or nil
    v = type(v) == 'number' and toint(v) or nil
    return (v and v > 0) and v or nil
end

--- The live parked node of a record (a copy, core's, whose fields name the record), or nil.
local function parkedNode(record)
    local id = parkedOf(record)
    local n = id and sc('get', id) or nil
    if type(n) == 'table' and n.kind == 'vehicle' and n.owner == 'core' and type(n.fields) == 'table'
        and n.fields.vehId == record.id then return n end
    return nil
end

--- A node copy's pose as a record position { x, y, z, heading, bucket? }.
local function nodePosition(n)
    local p, r, b = n.pos or EMPTY, n.rot or EMPTY, n.bucket or 0
    return { x = p.x or 0.0, y = p.y or 0.0, z = p.z or 0.0, heading = (r.z or 0.0) % 360.0,
        bucket = b ~= 0 and b or nil }
end

--- Removes a parked node as core -> ok.
local function removeNode(id)
    removing[id] = true
    local ok = sc('remove', id)
    removing[id] = nil
    return ok == true
end

--- The node fields of a record: the model name when known (the vehicle kind's Schema field; the hash otherwise),
--- the record's plate over whatever the props carry, vtype from the record.
local function nodeFields(record, props, locked)
    local p = platedProps(props, record.plate)
    p.model = nil
    local meta = type(record.meta) == 'table' and record.meta or EMPTY
    return { model = record.modelName or record.model, props = p, plate = record.plate, locked = locked == true,
        vehId = record.id, vtype = meta.vehType }
end

local function spawnNode(fields, pos, rot, bucket)
    return sc('spawn', { kind = 'vehicle', pos = pos, rot = rot, bucket = bucket or 0, persist = true,
        fields = fields, authority = PARKED_AUTHORITY })
end

-- MaxParked bookkeeping (server/vehicles_fleet.lua fills P.touch / P.untouch / P.grew; looked up at call time). A use
-- (park, promotion, demotion, lock key) also stamps last_used_at, the order the boot check rebuilds (queued).
local function touch(vehId, nodeId)
    local f = P.touch
    if f then f(vehId, nodeId) end
    write(vehId, { lastUsedAt = os.time() })
end
local function untouch(vehId) local f = P.untouch if f then f(vehId) end end
local function grew() local f = P.grew if f then f() end end

--------------------------------------------------------------------------------
-- The scene hooks: a parked car's clone is a core vehicle while it lives
--------------------------------------------------------------------------------

--- The mirrored record a core-owned vehicle node parks -> record | nil, ours (false: a maps / plugin vehicle node).
--- Never awaits: the hooks run inside promotions, demotions, removals and core's stop.
local function parkedRecordOf(node)
    local f = type(node) == 'table' and node.fields
    if type(f) ~= 'table' or type(f.vehId) ~= 'string' or node.owner ~= 'core' then return nil, false end
    local record = recs[f.vehId]
    if record and parkedOf(record) == node.id and record.stored == false then return record, true end
    return nil, true
end

--- A hook whose record the mirror lacks before the boot check read the world records (P.recovered): the record is
--- read in a thread — never inside the hook — and the hook runs once more. -> true when deferred
local function deferred(fn, node, arg, again)
    if again or P.recovered or stopping() then return false end
    local vehId = node.fields.vehId
    CreateThread(function()
        local _, err = readRecord(vehId)
        if err ~= nil then
            return Log.warn('vehicles: record %s of parked node %s could not be read (%s)', vehId, tostring(node.id),
                tostring(err))
        end
        fn(node, arg, true)
    end)
    return true
end

--- promoted (node, netId): the clone of a parked car is adopted — the §8 bags, tracking, vehicleSpawned. A live
--- car parkLive hands over (R.promote.adopt) keeps its tracking entry: it only becomes the node's clone.
local function onPromoted(node, netId, again)
    local record, ours = parkedRecordOf(node)
    if not ours or (not record and deferred(onPromoted, node, netId, again)) then return end
    local h = handoff[node.id]
    if h and h.netId == netId and record and spawned[netId] == h.info then
        local info = h.info
        clones[node.id], info.parked, info.promoProps, info.propsSaved = netId, node.id, node.fields.props, nil
        touch(record.id, node.id)
        return
    end
    local live = record and byVehId[record.id]
    if live and live ~= netId and clones[node.id] == live then  -- an earlier clone of this node that never demoted
        forget(live)
        Core.emitHook('vehicleDeleted', live)
        live = nil
    end
    if not record or (live and live ~= netId) then            -- stale (record gone / garaged / moved on) or a duplicate
        Log.warn('vehicles: parked node %s has no matching record (%s); it is removed', tostring(node.id),
            tostring(node.fields.vehId))
        SetTimeout(0, function() removeNode(node.id) end)
        return
    end
    local entity = mtype(netId) == 'integer' and NetworkGetEntityFromNetworkId(netId) or 0
    if entity == 0 or not DoesEntityExist(entity) or Entity(entity).state.sn ~= node.id then return end
    if spawned[netId] then forget(netId) end
    local f, meta = node.fields, type(record.meta) == 'table' and record.meta or EMPTY
    local owner, keyMode = record.ownerCharId or nil, meta.keyMode == 'item' and 'item' or 'virtual'
    local info = {
        netId = netId, entity = entity, model = record.model, modelName = record.modelName, plate = record.plate,
        ownerCharId = owner, keys = keySet(record.keys, owner, keyMode), keyMode = keyMode, locked = f.locked == true,
        vehId = record.id, spawnedBy = 'core', createdAt = os.time(), vehType = meta.vehType,
        props = type(f.props) == 'table' and f.props or {}, parked = node.id, promoProps = f.props,
    }
    track(info)
    writeState(entity, info)
    touch(record.id, node.id)
    Core.emitHook('vehicleSpawned', netId, publicInfo(info))
end

--- A wrecked clone (D-C): the car never comes back intact at its spot — the record keeps its last saved state and
--- is marked destroyed (not parked), the node goes. spawnRecord (a garage / an insurance plugin) brings it back.
local function wrecked(node, record)
    write(record.id, { parked = false, destroyed = true })
    untouch(record.id)
    removeNode(node.id)
    Log.info('vehicles: %s was wrecked (node %s removed; the record is marked destroyed)', record.id,
        tostring(node.id))
end

--- demoted (node, info): the car is a parked node again. The node's props carry the wear the engine merged from
--- the owner's read-back (info.wear, FX1b); cosmetics a key holder saved while promoted (saveProps) win over the
--- node's. Props (plated), pose (+ bucket), lock and keys go into the record (one queued patch — core's stop runs
--- this too); the node's fields follow lock / props (it is local now: Scene.set demotes nothing); the clone is
--- untracked (vehicleDeleted). info.destroyed: wrecked().
local function onDemoted(node, how, again)
    local record, ours = parkedRecordOf(node)
    if not ours or (not record and deferred(onDemoted, node, how, again)) then return end
    local netId = clones[node.id]
    local info = netId and spawned[netId]
    if record and type(how) == 'table' and how.destroyed == true then
        wrecked(node, record)
    elseif record then
        local f = node.fields
        local props = type(f.props) == 'table' and f.props or {}
        if info and info.propsSaved and type(info.props) == 'table' then
            props = mergeWear(info.props, f.props) or info.props       -- saved cosmetics + the demotion's wear
        end
        props = platedProps(props, record.plate)
        local patch = { stored = false, parked = node.id, position = nodePosition(node), props = props }
        if info then patch.locked, patch.keys = info.locked == true, keyList(info.keys) end
        write(record.id, patch)
        local fix
        if info and (f.locked == true) ~= (info.locked == true) then fix = { locked = info.locked == true } end
        if not same(props, f.props) then
            fix = fix or {}
            fix.props = props
        end
        if fix then sc('set', node.id, fix) end
        touch(record.id, node.id)
    end
    if info then
        forget(netId)
        Core.emitHook('vehicleDeleted', netId)
    end
end

--- removed (node, reason) by anyone but this file: the record is out again (not parked) at the node's — or its
--- clone's — last pose; an adopted clone is untracked.
local function onRemoved(node, reason, again)
    if removing[node.id] then return end
    local record, ours = parkedRecordOf(node)
    if not ours or (not record and deferred(onRemoved, node, reason, again)) then return end
    local netId = clones[node.id]
    local info = netId and spawned[netId]
    if record then
        local e = info and entityOf(netId) or 0
        write(record.id, { parked = false, position = e ~= 0 and positionOf(e) or nodePosition(node) })
        untouch(record.id)
        Log.warn('vehicles: the parked node %s of %s was removed (%s); the record is out, not parked',
            tostring(node.id), record.id, tostring(reason))
    end
    if info then
        forget(netId)
        Core.emitHook('vehicleDeleted', netId)
    end
end

--- Registers the scene hooks once Core.Scene exists -> parking available? The core-stop work (P.beforeStop, server/
--- vehicles_fleet.lua) is also registered as a pre-stop hook of the promote engine, which runs it before it
--- deletes any clone — so the clones' final poses reach their nodes whatever order the stop handlers run in.
local function hookScene()
    if hooked then return true end
    local S = Core.Scene
    if type(S) ~= 'table' or type(S.on) ~= 'function' or type(S.spawn) ~= 'function' then return false end
    hooked = sc('on', 'promoted', 'vehicle', onPromoted) ~= nil
    if hooked then
        sc('on', 'demoted', 'vehicle', onDemoted)
        sc('on', 'removed', 'vehicle', onRemoved)
        local R = rawget(Core, 'SceneRuntime')
        local PR = type(R) == 'table' and R.promote or nil
        if type(PR) == 'table' and type(PR.beforeStop) == 'function' then
            PR.beforeStop(function() if P.beforeStop then P.beforeStop() end end)
        else
            Log.warn('vehicles: no scene pre-stop hook; clones rely on the stop handler order')
        end
    end
    return hooked
end

--------------------------------------------------------------------------------
-- Parking
--------------------------------------------------------------------------------

--- Parks an out record that has no live vehicle, at its saved position (Vehicles.park(vehId), boot recovery). The
--- record carries props and position (a read); the mirror (its lock) wins where it has the record already.
local function parkRecord(record)
    if spawning[record.id] then return nil, 'busy' end          -- its car is being made (spawnRecord): never both
    local p = record.position
    if type(p) ~= 'table' or not (finite(p.x) and finite(p.y) and finite(p.z)) then return nil, 'bad_coords' end
    local e = recs[record.id] or mirrorOf(record)
    local id, err = spawnNode(nodeFields(record, record.props, e.locked), { x = p.x, y = p.y, z = p.z },
        { x = 0.0, y = 0.0, z = finite(p.heading) and p.heading or 0.0 }, toint(p.bucket) or 0)
    if not id or not write(record.id, { parked = id, stored = false }) then
        if id then removeNode(id) end
        P.settle(record.id)
        return nil, id and 'db' or err
    end
    touch(record.id, id)
    return id
end

--- The props of `entity` read back from the client that owns it, merged over `stored`: only the damage / wear keys
--- may change (D-A — any network owner answers, keys or not), or nil. Yields up to 1 s.
local function ownerProps(entity, netId, stored)
    local owner = NetworkGetEntityOwner(entity)
    if mtype(owner) ~= 'integer' or owner < 1 then return nil end
    local got = Core.Callback.awaitClientTimeout(owner, 'core:vehicles:props', PROPS_TIMEOUT_MS, netId)
    if type(got) ~= 'table' or not validateProps(got) then return nil end
    return mergeWear(stored, got)
end

--- The promote engine's hand-off (FX1b): R.promote.adopt(id, entity) makes an existing networked entity the clone
--- of node `id` (its promoted hook fires synchronously). nil without it.
local function adoptFn()
    local R = rawget(Core, 'SceneRuntime')
    local PR = type(R) == 'table' and R.promote or nil
    local fn = type(PR) == 'table' and PR.adopt or nil
    return type(fn) == 'function' and fn or nil
end

--- The stop-gap without the engine's hand-off (RV6 F11): the untracked car stays — locked (nobody gets in) and
--- frozen (the local copies appearing on it cannot push it) — until the clients' local copies exist, then goes.
local function retire(e, netId, vehId)
    SetVehicleDoorsLocked(e, LOCK_LOCKED)
    FreezeEntityPosition(e, true)
    retiring[e] = { netId = netId, vehId = vehId }
    local C = Config.Scene and Config.Scene.Promote
    local delay = math.floor(tonumber(C and C.DeleteDelayMs) or 500) + RETIRE_EXTRA_MS
    SetTimeout(delay, function()
        local r = retiring[e]
        if not r or r.netId ~= netId then return end
        retiring[e] = nil
        if DoesEntityExist(e) and NetworkGetNetworkIdFromEntity(e) == netId and Entity(e).state.vehId == vehId
            and not spawned[netId] then DeleteEntity(e) end
    end)
end

--- Core stops: the retiring cars go now (a timer would not fire any more).
local function retireNow()
    for e, r in pairs(retiring) do
        retiring[e] = nil
        if DoesEntityExist(e) and NetworkGetNetworkIdFromEntity(e) == r.netId and Entity(e).state.vehId == r.vehId
            and not spawned[r.netId] then DeleteEntity(e) end
    end
end

--- Parks a tracked, persisted vehicle that is no clone, with a hand-off (never deleted first, RV6 F11): the
--- owner's wear is read first (≤ 1 s, merged over the cached / record props: the node starts with the car's real
--- damage), a node at the entity's pose (+ bucket), the record; then the live car becomes the node's clone and is
--- demoted on the normal path (R.promote.adopt + Scene.demote) — or, without that engine path, it retires once the
--- local copies exist. vehicleDeleted either way.
--- The mirror entry of a live car's record (it is mirrored while the car lives; else read — AWAITED — and added).
--- -> entry | nil (no record) | nil, err
local function mirrored(vehId)
    local e = recs[vehId]
    if e then return e end
    local rec, err = readRecord(vehId)
    if not rec then return nil, err end
    return recs[vehId] or mirrorOf(rec)
end

local function parkLive(info)
    local netId = info.netId
    local e = entityOf(netId)
    if e == 0 then return nil, 'no_entity' end
    if info.parking then return nil, 'busy' end
    if occupied(e) then return nil, 'occupied' end
    info.parking = true
    local record, rerr = mirrored(info.vehId)
    local props = info.props or {}                            -- a live car's props are its record's (saveProps)
    local ok, got = true, nil
    if record then ok, got = pcall(ownerProps, e, netId, props) end
    info.parking = nil
    if rerr ~= nil then return nil, 'db' end
    if spawned[netId] ~= info or entityOf(netId) ~= e then return nil, 'gone' end
    record = recs[info.vehId]
    if not record then return nil, 'no_record' end
    if occupied(e) then return nil, 'occupied' end
    if ok and got then props = got end
    local adopt = adoptFn()
    local stale = parkedNode(record)                          -- a node of this record the live car outlived
    local fields = nodeFields({ id = info.vehId, plate = info.plate, model = info.model,
        modelName = info.modelName or record.modelName, meta = record.meta }, props, info.locked)
    local c, r, bucket = GetEntityCoords(e), GetEntityRotation(e), GetEntityRoutingBucket(e)
    local id, err, detail = spawnNode(fields, { x = c.x, y = c.y, z = c.z }, { x = r.x, y = r.y, z = r.z }, bucket)
    if not id then return nil, err, detail end
    if not write(info.vehId, { parked = id, stored = false, props = fields.props, locked = info.locked == true,
        keys = keyList(info.keys), position = positionOf(e) }) then
        removeNode(id)
        return nil, 'db'
    end
    if stale then removeNode(stale.id) end
    touch(info.vehId, id)
    if adopt then
        handoff[id] = { netId = netId, info = info }
        local ok, done, why = Core.Registry.withCaller('core', adopt, id, e)
        handoff[id] = nil
        if ok and done and clones[id] == netId then
            local demoted, derr = sc('demote', id)          -- the normal hand-off; 'occupied': it stays promoted
            if not demoted then
                Log.debug('vehicles: %s stays promoted after its park (%s)', info.vehId, tostring(derr))
            end
            grew()
            return id
        end
        Log.warn('vehicles: the hand-off of %s failed (%s); it retires instead', info.vehId,
            tostring(ok and why or done))
    end
    forget(netId)
    retire(e, netId, info.vehId)
    Core.emitHook('vehicleDeleted', netId)
    grew()
    return id
end

--- Vehicles.park(netId | vehId) -> nodeId | nil, err. Persisted vehicles only; yields up to 1 s. A parked car's
--- clone is demoted (the demotion finishes asynchronously); a parked record answers its node; an out record
--- without a live vehicle parks at its saved position. Errors: unavailable, bad_target, missing, not_persisted,
--- no_record, record_stored, destroyed, occupied, busy, gone, no_entity, bad_coords, db and Scene.spawn's /
--- Scene.demote's (fields + detail, limit, occupied, …).
function Vehicles.park(target)
    if not hookScene() then return nil, 'unavailable' end
    local info
    if type(target) == 'string' then
        if not Validate.value('id', target) then return nil, 'bad_target' end
        info = byVehId[target] and spawned[byVehId[target]]
        local node = not info and recs[target] and parkedNode(recs[target])
        if node then return node.id end
        if not info and spawning[target] then return nil, 'busy' end
        if not info then
            local record, err = readRecord(target)            -- (awaited: position and props for parkRecord)
            if err ~= nil then return nil, 'db' end
            if not record then return nil, 'no_record' end
            info = byVehId[target] and spawned[byVehId[target]]   -- it went live during the read
            if not info and spawning[target] then return nil, 'busy' end
            if not info then
                node = parkedNode(record)
                if node then return node.id end
                if record.stored ~= false then return nil, 'record_stored' end
                if record.destroyed == true then return nil, 'destroyed' end
                local id, perr = parkRecord(record)
                if id then grew() end
                return id, perr
            end
        end
    elseif Validate.value('netId', target) then
        info = spawned[target]
        if not info then return nil, 'missing' end
    else
        return nil, 'bad_target'
    end
    if not info.vehId then return nil, 'not_persisted' end
    if not info.parked then return parkLive(info) end
    local e = entityOf(info.netId)
    if e ~= 0 and occupied(e) then return nil, 'occupied' end
    local done, err = sc('demote', info.parked)
    if not done then return nil, err end
    return info.parked
end

--- spawnRecord of a parked record: its node is promoted instead of a second car being made (a vanished node is
--- re-parked first) -> the clone's netId once it is adopted (a bounded wait like spawn's) | nil, err.
local function unpark(record)
    local node = parkedNode(record)
    local id, err = node and node.id, nil
    if not id then
        id, err = parkRecord(record)
        if not id then return nil, err end
    end
    local netId = clones[id]
    if netId and spawned[netId] then return netId end
    local ok
    ok, err = sc('promote', id)
    if not ok then return nil, err or 'promote_failed' end
    touch(record.id, id)
    local deadline = GetGameTimer() + (Config.Vehicles.SpawnTimeoutMs or 5000) + UNPARK_EXTRA_MS
    repeat
        Wait(100)
        netId = clones[id]
        if netId and spawned[netId] then return netId end
    until GetGameTimer() >= deadline
    return nil, 'spawn_timeout'
end

--------------------------------------------------------------------------------
-- The record reads (§56: moved here from server/vehicles.lua) and the parked branches of the record API
--------------------------------------------------------------------------------

--- The records of a character (one indexed read, read-your-writes; AWAITED) -> array ({} and err when the read
--- failed — never mistake that for "no cars").
function Vehicles.getRecords(charId)
    if not Validate.value('id', charId) then return {} end
    local start = P.writeSeq()
    local rows, err = DB.select(TABLE, { owner_character_id = charId }, { orderBy = 'created_at, id', sync = true })
    if not rows then
        Log.error('vehicles: the records of %s could not be read (%s)', charId, tostring(err))
        return {}, err
    end
    local out = {}
    for i = 1, #rows do out[i] = fromRead(rows[i], start) end
    return out
end

--- The record (AWAITED) -> record | nil | nil, err (the read failed).
function Vehicles.getRecord(vehId)
    if not Validate.value('id', vehId) then return nil end
    local record, err = readRecord(vehId)
    if err ~= nil then Log.error('vehicles: record %s could not be read (%s)', vehId, tostring(err)) end
    return record, err
end

--- A record for spawnRecord / restoreRecord (AWAITED) -> record | nil, 'no_record' | nil, 'db' (the read failed).
local function recordFor(vehId)
    local record, err = Vehicles.getRecord(vehId)
    if err ~= nil then return nil, 'db' end
    if not record then return nil, 'no_record' end
    return record
end

--- restoreRecord on a record in hand (the saved position and bucket unless coords are given).
local function restoreFrom(record, coords, heading, ownerSrc)
    if record.stored ~= false then return nil, 'record_stored' end
    if record.destroyed == true then return nil, 'destroyed' end
    local bucket
    if coords == nil and type(record.position) == 'table' then
        local p = record.position
        if type(p.x) == 'number' and type(p.y) == 'number' and type(p.z) == 'number' then
            coords = vector3(p.x, p.y, p.z)
            heading = heading == nil and p.heading or heading
            bucket = math.tointeger(p.bucket)
            if bucket and (bucket < 1 or bucket > 65535) then bucket = nil end
        end
    end
    if not Validate.value('vector3', coords) then return nil, 'bad_coords' end
    return P.spawnFromRecord(record, coords, heading, ownerSrc, bucket)
end

-- core_db dropped a queued write of a record (§56.3.5, `key` = the vehId): the row keeps what it had, so the mirror
-- reads it again (the database wins) — in a thread after the current slice, never inside the hook.
Core.on('dbWriteFailed', function(owner, _, tbl, _, key)
    if owner ~= Core.name or tbl ~= TABLE or type(key) ~= 'string' then return end
    Log.warn('vehicles: a queued write of record %s was dropped; the record is read again', key)
    CreateThread(function()
        Wait(0)
        readRecord(key, true)
    end)
end)

local base = { store = Vehicles.store, delete = Vehicles.delete }

--- A parked record is promoted where it stands (coords / heading / ownerSrc unused): the clone's netId, valid
--- while it stays promoted (vehicleSpawned / vehicleDeleted tell). One read (AWAITED); 'db' when it failed.
function Vehicles.spawnRecord(vehId, coords, heading, ownerSrc)
    local record, err = recordFor(vehId)
    if not record then return nil, err end
    if not Validate.value('vector3', coords) then return nil, 'bad_coords' end
    if parkedOf(record) and record.stored == false and hookScene() then
        local live = byVehId[record.id]
        if live and spawned[live] and spawned[live].parked then return live end
        if live then return nil, 'already_spawned' end
        return unpark(record)
    end
    return P.spawnFromRecord(record, coords, heading, ownerSrc)
end

--- A parked record is in the world already (a scene node): 'parked' — a boot restore must not duplicate it.
function Vehicles.restoreRecord(vehId, coords, heading, ownerSrc)
    local record, err = recordFor(vehId)
    if not record then return nil, err end
    if record.stored == false and parkedOf(record) then return nil, 'parked' end
    return restoreFrom(record, coords, heading, ownerSrc)
end

--- store(netId | vehId): a vehId garages its live vehicle, its parked node, or a record with nothing in the world
--- (a mirrored — parked — record without a yield: MaxParked's eviction uses it); a parked car's clone takes its node
--- along.
function Vehicles.store(target)
    if type(target) == 'string' then
        if not Validate.value('id', target) then return false end
        if byVehId[target] then return Vehicles.store(byVehId[target]) end
        local record = recs[target]
        if not record then
            local rec, err = readRecord(target)
            if not rec or err ~= nil then return false end
            if byVehId[target] then return Vehicles.store(byVehId[target]) end   -- it went live during the read
            record = recs[target] or rec
        end
        local node = parkedNode(record)
        local patch = { stored = true, parked = false }
        if node then
            patch.position = nodePosition(node)
            local props = node.fields.props or record.props
            if props then patch.props = platedProps(props, record.plate) end
        end
        if not write(target, patch) then return false end
        untouch(target)
        if node then removeNode(node.id) end
        return true
    end
    local info = mtype(target) == 'integer' and spawned[target] or nil
    if info and info.parked then                              -- the node goes (its tap dooms the clone)
        local id = info.parked
        clones[id], info.parked = nil, nil
        removeNode(id)
        write(info.vehId, { parked = false })
        untouch(info.vehId)
    end
    return base.store(target)
end

--- A parked car's clone takes its node along (else the car would come back at its parking spot); the record is
--- out again at the clone's pose (spawnRecord takes it back, the boot check re-parks it). Not while core stops
--- (the node keeps the car). Never yields (server/main.lua's stop loop calls it).
function Vehicles.delete(netId)
    local info = mtype(netId) == 'integer' and spawned[netId] or nil
    if info and info.parked and not stopping() then
        local id, e = info.parked, entityOf(netId)
        local record = recs[info.vehId]
        if record and parkedOf(record) == id then
            write(info.vehId, { parked = false, position = e ~= 0 and positionOf(e) or nil })
        end
        clones[id], info.parked = nil, nil
        removeNode(id)
        untouch(info.vehId)
    end
    return base.delete(netId)
end

--- Deletes the record (one awaited DELETE — the caller learns whether it existed); its parked node goes, a promoted
--- one's clone is untracked. -> bool
function Vehicles.deleteRecord(vehId)
    if not Validate.value('id', vehId) then return false end
    if not recs[vehId] then readRecord(vehId) end             -- a parked record joins the mirror (its node)
    local count, err = DB.delete(TABLE, { id = vehId })
    if not count then
        Log.error('vehicles: record %s could not be deleted (%s)', vehId, tostring(err))
        return false
    end
    markWrite(vehId)
    local record = recs[vehId]                                -- (after the await: the node it parks now)
    local node = record and parkedNode(record)
    local liveNet = byVehId[vehId]
    local live = liveNet and spawned[liveNet]
    if live and not live.parked then                          -- its live car is a plain, unpersisted car now: no park
        byVehId[vehId], live.vehId = nil, nil                 -- of a deleted record (AutoPark, core stop)
        local e = entityOf(liveNet)
        if e ~= 0 then Entity(e).state:set('vehId', nil, true) end
    end
    recs[vehId] = nil
    if count < 1 then return false end
    untouch(vehId)
    if node then
        local netId = clones[node.id]
        removeNode(node.id)
        if netId and forget(netId) then Core.emitHook('vehicleDeleted', netId) end
    end
    return true
end

--- Vehicles.getInfoByRecord(vehId) -> getInfo's fields (netId only while a vehicle is live — a promoted parked
--- car's clone included) + parked (node id), stored, position { x, y, z, heading, bucket? }, destroyed | nil.
--- A record without a live car is read (AWAITED); nil, err when that failed.
function Vehicles.getInfoByRecord(vehId)
    if not Validate.value('id', vehId) then return nil end
    local netId = byVehId[vehId]
    local info = netId and spawned[netId]
    if info then
        local out, entity = publicInfo(info), entityOf(netId)
        out.stored, out.position, out.destroyed = false, entity ~= 0 and positionOf(entity) or nil, false
        return out
    end
    local record, err = readRecord(vehId)
    if not record then return nil, err end
    local meta = type(record.meta) == 'table' and record.meta or EMPTY
    local owner, keyMode = record.ownerCharId or nil, meta.keyMode == 'item' and 'item' or 'virtual'
    local node = parkedNode(record)
    local locked = record.locked == true
    if node then locked = node.fields.locked == true end
    return { model = record.model, plate = record.plate, ownerCharId = owner,
        keys = keySet(record.keys, owner, keyMode),
        keyMode = keyMode, locked = locked, vehId = vehId, createdAt = record.createdAt, parked = node and node.id,
        stored = record.stored == true, position = node and nodePosition(node) or record.position,
        destroyed = record.destroyed == true }
end

--------------------------------------------------------------------------------
-- The lock key on a parked car's local copy: core:server:parkedLock(nodeId)
--------------------------------------------------------------------------------

--- Where the key's target is: an adopted clone (promoted meanwhile), else the parked node's pose; nil when the id
--- names no vehicle node of core's (Core.Net.on's distance step refuses the event then).
local function lockCoords(_, id)
    local netId = clones[id]
    local e = netId and entityOf(netId) or 0
    if e ~= 0 then return GetEntityCoords(e) end
    local n = sc('get', id)
    local p = type(n) == 'table' and n.kind == 'vehicle' and n.owner == 'core' and n.pos or nil
    return p and vector3(p.x, p.y, p.z) or nil
end

local function notifyLock(src, locked)
    Core.Notify.send(src, locked and Config.Texts.locked or Config.Texts.unlocked, 'info')
end

--- The lock key (U) on a parked car's LOCAL copy (it carries no state bags, so the client sends the node id).
--- Order: the id (schema) → 500 ms per player → loaded → distance from the server's own ped coords to the node
--- (or its clone) ≤ LockDistance → the node parks a record, same bucket → keys like core:server:vehicleLock
--- (virtual keys of the record; an item-key car is its domain plugin's: silently ignored, §4.6) → the record's
--- `locked` and the node field toggle (the local copies follow). Promoted meanwhile: the clone's own rules.
Core.Net.on('core:server:parkedLock', { { 'integer', min = 1, max = 0x7FFFFFFF } }, function(src, id)
    local netId = clones[id]
    local info = netId and spawned[netId]
    if info then
        if info.keyMode == 'item' then return end
        if not Vehicles.hasKeys(src, netId) then return Core.Notify.send(src, Config.Texts.no_keys, 'error') end
        local locked = not Vehicles.isLocked(netId)
        if Vehicles.setLocked(netId, locked) then notifyLock(src, locked) end
        return
    end
    local n = sc('get', id)
    local record = n and parkedRecordOf(n)
    if not record or n.promoted ~= nil or GetPlayerRoutingBucket(src) ~= (n.bucket or 0) then return end
    local meta = type(record.meta) == 'table' and record.meta or EMPTY
    if meta.keyMode == 'item' then return end
    local player = Core.Player.getInfo(src)
    local charId = player and player.charId
    if not charId or not keySet(record.keys, record.ownerCharId or nil, 'virtual')[charId] then
        return Core.Notify.send(src, Config.Texts.no_keys, 'error')
    end
    local locked = n.fields.locked ~= true
    if not write(record.id, { locked = locked }) then return end
    sc('set', id, { locked = locked })
    touch(record.id, id)
    notifyLock(src, locked)
end, {
    cooldown = 500,
    requireLoaded = true,
    distance = { coords = lockCoords, max = Config.Vehicles.LockDistance },
})

-- The hand-off to server/vehicles_fleet.lua (it takes P and clears the global CoreVehiclesPark).
P.sc, P.parkedOf, P.parkedNode, P.nodePosition, P.removeNode = sc, parkedOf, parkedNode, nodePosition, removeNode
P.nodeFields, P.spawnNode, P.parkRecord, P.occupied, P.keyList = nodeFields, spawnNode, parkRecord, occupied, keyList
P.platedProps, P.finite, P.stopping, P.hookScene, P.retireNow = platedProps, finite, stopping, hookScene, retireNow
P.keySet = keySet
P.isHooked = function() return hooked end
P.parkedAuthority = PARKED_AUTHORITY
