--- core/server/vehicles.lua — Core.Vehicles (server).
--- Server-owned vehicle spawning, ownership/keys, lock state, and the `vehicles` records. DESIGN §4.6 (API), §8
--- (state bags). Since the §56 port (the files' size) the record reads (getRecord / getRecords / deleteRecord) are
--- server/vehicles_park.lua's, the §5 net events (vehicleLock, vehicleProps, core:vehicles:mine) vehicles_fleet.lua's.
--- Parking (§55.21.4: park, the scene hooks, AutoPark, getInfoByRecord, the parked branches of spawnRecord /
--- restoreRecord / store / delete / deleteRecord) is server/vehicles_park.lua, which loads RIGHT AFTER this file
--- and takes the live maps and helpers once through the one-shot global `CoreVehiclesPark` (P); server/
--- vehicles_fleet.lua (AutoPark, boot / stop reconciliation, MaxParked) follows it and adds P.wake (a record
--- appeared: AutoPark) and P.beforeStop (core stops: clones hand their poses to their nodes, live cars park).
--- Props (review RV4 F1): every write goes through cleanProps — the JSON-safe copy with every known key clamped to
--- its native range (colour / mod indexes, healths 0..1000, fuel 0..100, dirt 0..15) and props.plate = the plate.
--- Records: spawnRecord answers 'already_spawned' only while the record's car is live (an out record with nothing
--- in the world is spawned: review RV6 F2); restoreRecord refuses a `destroyed` record (§55.21.4 notes, D-C).
--- Database (DESIGN §56.6 `vehicles`, port notes in §4.6): records are rows read by key / index (fromRow is the one
--- column ↔ field mapping); persist is an awaited insert (a plate collision of a core-chosen plate retries with a new
--- one), deleteRecord an awaited delete, every other change a QUEUED patch of only the changed columns (write) —
--- never `meta`, whose keys Vehicles.setData writes atomically (server/getters.lua). `recs` mirrors the columns the
--- park / fleet code needs (owner, plate, model, parked, stored, destroyed, locked, keys, meta.vehType / keyMode) of
--- every WORLD record (parked, or its car live), so the scene hooks, the lock key and the stop paths never await.
--- Natives (fxref + natives_cfx.json, server / CFX forms): CreateVehicleServerSetter, DoesEntityExist, DeleteEntity,
--- NetworkGetNetworkIdFromEntity, NetworkGetEntityFromNetworkId, GetEntityType, GetEntityModel, GetEntityCoords,
--- GetEntityHeading, GetEntityRoutingBucket, GetVehicleNumberPlateText, GetVehicleType, SetVehicleNumberPlateText,
--- SetVehicleDoorsLocked, SetEntityRoutingBucket, SetEntityOrphanMode, GetHashKey, GetGameTimer.
--- Runtime: Entity(e).state, Wait.

local Vehicles = {}
Core.Vehicles = Vehicles

local Validate = Core.Validate
local Utils = Core.Utils
local Log = Core.Log

local ENTITY_TYPE_VEHICLE <const> = 2
local LOCK_LOCKED <const> = 2
local LOCK_UNLOCKED <const> = 1
local ORPHAN_KEEP_ENTITY <const> = 2
local PLATE_ALPHABET <const> = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
local PLATE_MAX <const> = 8
local PROPS_MAX_KEYS <const> = 96
local PROPS_MAX_KEY_LEN <const> = 32
local PROPS_MAX_STRING <const> = 32
local PROPS_MAX_MAP_ENTRIES <const> = 64
local PROPS_MAX_MAP_INDEX <const> = 64
local TABLE <const> = 'vehicles'
local PLATE_BATCH <const>, PLATE_ROUNDS <const> = 16, 64   -- ≤ 1024 random candidates, one indexed query per batch
local PERSIST_TRIES <const> = 3                           -- a core-chosen plate that collides at the insert: re-plated
local RECENT_MS <const> = 60000                           -- a record written this recently is read with sync = true
local PLATES_SQL <const> = 'SELECT plate FROM vehicles WHERE plate = ANY($1::text[])'
-- record field -> column (§56.8 rule 5: the one mapping). `meta` is written by persist only, never patched.
local COLUMN <const> = { ownerCharId = 'owner_character_id', model = 'model', modelName = 'model_name', plate = 'plate',
    props = 'props', stored = 'stored', destroyed = 'destroyed', parked = 'parked', locked = 'locked', keys = 'keys',
    position = 'position', lastUsedAt = 'last_used_at' }
local MIRRORED <const> = { ownerCharId = true, model = true, modelName = true, plate = true, stored = true,
    destroyed = true, parked = true, locked = true, keys = true }
local MODEL_NAME <const> = '^[%w_%-]+$'   -- a model name the scene's vehicle kind takes (§55.21.4 node fields)

-- The native ranges of the props keys (fxref: SET_VEHICLE_COLOURS / _EXTRA_COLOURS / interior / dashboard paint
-- indexes are u8, NUMBER_PLATE_TEXT_INDEX 0..12 (b3095), WHEEL_TYPE 0..12, WINDOW_TINT -1..6, LIVERY / roof livery
-- -1 = none, SET_VEHICLE_MOD index -1..254, XENON 0..12 or 255 = stock; healths 0..1000 (a restored car never
-- burns: review RV4 F1), fuel 0..100, dirt 0..15). Values outside are clamped; a known key of the wrong type drops.
local PROP_INT <const> = { plateIndex = { 0, 12 }, colorPrimary = { 0, 255 }, colorSecondary = { 0, 255 },
    pearlescentColor = { 0, 255 }, wheelColor = { 0, 255 }, interiorColor = { 0, 255 }, dashboardColor = { 0, 255 },
    wheels = { 0, 12 }, windowTint = { -1, 6 }, livery = { -1, 127 }, livery2 = { -1, 127 } }
local PROP_FLOAT <const> = { engineHealth = { 0, 1000 }, bodyHealth = { 0, 1000 }, tankHealth = { 0, 1000 },
    fuelLevel = { 0, 100 }, dirtLevel = { 0, 15 } }
local PROP_RGB <const> = { neonColor = true, tyreSmokeColor = true, customPrimary = true, customSecondary = true }
local MOD_INDEX_MIN <const>, MOD_INDEX_MAX <const> = -1, 254
local XENON_MAX <const>, XENON_STOCK <const> = 12, 255

local SPAWN_SCHEMA <const> = {
    model = 'any', coords = 'vector3', heading = 'number?', type = { 'string', max = 16, optional = true },
    plate = { 'string', max = PLATE_MAX, optional = true }, ownerSrc = 'src?', ownerCharId = 'id?',
    keys = { 'array', of = 'id', max = 32, optional = true }, props = 'table?',
    keyMode = { 'enum', 'virtual', 'item', optional = true }, locked = 'boolean?', persistent = 'boolean?',
    bucket = { 'integer', min = 0, max = 65535, optional = true },
}

local ADOPT_SCHEMA <const> = { ownerSrc = 'src?', ownerCharId = 'id?',
    keyMode = { 'enum', 'virtual', 'item', optional = true }, locked = 'boolean?', props = 'table?' }

local spawned = {}      -- [netId] = info (live, includes the entity handle)
local byEntity = {}     -- [entity handle] = netId
local usedPlates = {}   -- [plate] = netId
local byVehId = {}      -- [vehId] = netId of the record's live vehicle (a parked car's adopted clone included)
local clones = {}       -- [nodeId] = netId: the adopted clone of a promoted parked car (server/vehicles_park.lua)
local rest = {}         -- [netId] = AutoPark's rest stamp (server/vehicles_park.lua)
local recs = {}         -- [vehId] = the mirror of a WORLD record (parked, or its car live): MIRRORED fields + id, meta
local spawning = {}     -- [vehId] = true while spawnFromRecord makes its car (a second spawnRecord waits for nothing)
-- The maps above are shared with server/vehicles_park.lua (P): they are cleared in place, never replaced.
local P = { spawned = spawned, byVehId = byVehId, clones = clones, rest = rest, recs = recs, spawning = spawning }

--------------------------------------------------------------------------------
-- Records: rows of `vehicles` (DESIGN §56.6), queued patches, the mirror of the world records
--------------------------------------------------------------------------------

local DB = Core.DB
local writeSeq = 0                                  -- +1 per queued write of this module
local recentAt, recentCur, recentPrev = 0, {}, {}   -- vehId -> writeSeq of its last write (2 generations, RECENT_MS)

local function rotateRecent()
    local now = GetGameTimer()
    if now - recentAt < RECENT_MS then return end
    recentPrev = now - recentAt < 2 * RECENT_MS and recentCur or {}
    recentCur, recentAt = {}, now
end

--- The writeSeq of this module's last write of `vehId` within the last RECENT_MS (at least), or nil.
local function lastWrite(vehId)
    rotateRecent()
    return recentCur[vehId] or recentPrev[vehId]
end

--- This module changed `vehId` now (a queued write, the delete): a read that began before never refreshes the mirror.
local function markWrite(vehId)
    writeSeq = writeSeq + 1
    rotateRecent()
    recentCur[vehId] = writeSeq
end

local function copyList(t)
    local out = {}
    for i = 1, type(t) == 'table' and #t or 0 do out[i] = t[i] end
    return out
end

--- keys { [charId] = true } -> the record's sorted list.
local function keyList(keys)
    local out = {}
    for charId in pairs(keys or {}) do out[#out + 1] = charId end
    table.sort(out)
    return out
end

--- The record of a row (SQL NULL columns are absent keys): ownerCharId / parked false when NULL, keys a list.
local function fromRow(row)
    return {
        id = row.id, ownerCharId = row.owner_character_id or false, model = row.model, modelName = row.model_name,
        plate = row.plate, props = type(row.props) == 'table' and row.props or {}, stored = row.stored == true,
        destroyed = row.destroyed == true, parked = math.tointeger(row.parked) or false, locked = row.locked,
        keys = type(row.keys) == 'table' and row.keys or {}, position = row.position,
        meta = type(row.meta) == 'table' and row.meta or {}, lastUsedAt = row.last_used_at,
        createdAt = row.created_at, updatedAt = row.updated_at,
    }
end

--- The mirror entry of a record (created or refreshed from it) -> the entry.
local function mirrorOf(rec)
    local e = recs[rec.id]
    if not e then
        e = { id = rec.id }
        recs[rec.id] = e
    end
    for k in pairs(MIRRORED) do e[k] = rec[k] end
    e.keys = copyList(rec.keys)
    local meta = type(rec.meta) == 'table' and rec.meta or {}
    e.meta = { vehType = meta.vehType, keyMode = meta.keyMode }
    return e
end

--- A record leaves the mirror once it is neither parked nor its car live.
local function settle(vehId)
    local e = recs[vehId]
    if e and not e.parked and not byVehId[vehId] then recs[vehId] = nil end
end

--- Queues ONE patch of exactly `changes` (record fields; an absent field stays as it is, false ownerCharId / parked =
--- NULL) and updates the mirror. Never yields. -> true | false (core_db refused it: nothing changed).
local function write(vehId, changes)
    local cols = {}
    for k, v in pairs(changes) do
        local col = COLUMN[k]
        if not col then error('vehicles: no column for ' .. tostring(k), 2) end
        if v == false and (k == 'ownerCharId' or k == 'parked') then v = DB.NULL end
        cols[col] = v
    end
    local ok, err = DB.patch(TABLE, vehId, cols)
    if not ok then
        Log.error('vehicles: the write of record %s was refused (%s)', tostring(vehId), tostring(err))
        return false
    end
    markWrite(vehId)
    local e = recs[vehId]
    if e then
        for k, v in pairs(changes) do
            if MIRRORED[k] then e[k] = k == 'keys' and copyList(v) or v end
        end
    end
    settle(vehId)
    return true
end

--- A row an awaited read returned; `start` = writeSeq when the read began. A write of ours since then wins (the
--- mirror's fields are laid over the record); otherwise the row refreshes the mirror (a parked record joins it).
--- -> record, stale (a write of ours raced the read and no mirror entry holds it: the row is out of date)
local function fromRead(row, start)
    local rec = fromRow(row)
    local e = recs[rec.id]
    if (lastWrite(rec.id) or 0) > start then
        if not e then return rec, true end
        for k in pairs(MIRRORED) do rec[k] = e[k] end
        rec.keys = copyList(e.keys)
    elseif e or rec.parked then
        mirrorOf(rec)
        settle(rec.id)
    end
    return rec, false
end

--- The record `vehId` (AWAITED: a coroutine only; read-your-writes when this module wrote it lately; read once more,
--- with sync, when a write of ours raced it) -> record | nil (no such record) | nil, err (the read failed — never
--- "no record").
local function readRecord(vehId, again)
    local start = writeSeq
    local row, err = DB.first(TABLE, { id = vehId }, { sync = again or lastWrite(vehId) ~= nil })
    if err ~= nil then return nil, err end
    local raced = (lastWrite(vehId) or 0) > start
    if not row then
        if raced and not again then return readRecord(vehId, true) end
        if not raced and not byVehId[vehId] then recs[vehId] = nil end
        return nil
    end
    local rec, stale = fromRead(row, start)
    if stale and not again then return readRecord(vehId, true) end
    return rec
end

--- Resolves a **tracked** netId to a live entity handle (0 when untracked or gone).
--- Deliberately no NetworkGetEntityFromNetworkId fallback: the exported API acts only on an entity core
--- already tracks, whether it was server-spawned or explicitly adopted by a trusted server resource.
local function entityOf(netId)
    if math.type(netId) ~= 'integer' then return 0 end
    local info = spawned[netId]
    local entity = info and info.entity
    if entity and entity ~= 0 and DoesEntityExist(entity) then return entity end
    return 0
end

--- Drops every book-keeping entry for a netId. Never touches the world.
local function forget(netId)
    local info = spawned[netId]
    if not info then return false end
    if info.entity then byEntity[info.entity] = nil end
    if info.plate and usedPlates[info.plate] == netId then usedPlates[info.plate] = nil end
    if info.vehId and byVehId[info.vehId] == netId then byVehId[info.vehId] = nil end
    if info.parked and clones[info.parked] == netId then clones[info.parked] = nil end
    spawned[netId], rest[netId] = nil, nil
    Core.Registry.untrack('vehicle', netId)
    if info.vehId then settle(info.vehId) end
    return true
end

--- Normalises a persistent plate. Hyphens support real registration layouts such as LS-48291.
--- A plate is globally unique across **stored and live** Core.Vehicles records, not only within the
--- current process (the live cars in memory, the records by the UNIQUE plate index — one indexed read, awaited;
--- the live map is checked again after it, so no yield separates the check from the caller's track()).
--- `recordId` is used solely by spawnRecord when restoring that same record: its plate is its own under the UNIQUE
--- index, so only the live map is asked (no read). -> taken? | nil, err (read failed)
local function plateTaken(plate, recordId)
    if usedPlates[plate] then return true end
    if recordId then return false end
    local row, err = DB.first(TABLE, { plate = plate }, { columns = { 'id' } })
    if err ~= nil then return nil, err end
    return usedPlates[plate] ~= nil or (row ~= nil and row.id ~= recordId)
end

local function normalizePlate(plate, recordId)
    if type(plate) ~= 'string' then return nil, 'bad_plate' end
    plate = Utils.trim(plate):upper()
    if #plate < 1 or #plate > PLATE_MAX then return nil, 'bad_plate' end
    if not plate:match('^[%w %-]+$') then return nil, 'bad_plate' end
    local taken, err = plateTaken(plate, recordId)
    if taken == nil then
        Log.error('vehicles: the plate check failed (%s)', tostring(err))
        return nil, 'db'
    end
    if taken then return nil, 'plate_taken' end
    return plate
end

--- A free random plate: batches of PLATE_BATCH candidates, ONE indexed query per batch (plate = ANY), never a scan;
--- the live map is checked again after the read. A FAILED read is accepted (a candidate not live): the UNIQUE index
--- and persist's re-plate still guard the records, and a spawn never fails because the database is slow or down.
--- -> plate | nil, 'plate_exhausted'
local function randomPlate()
    local prefix = Config.Vehicles.PlatePrefix or 'LS'
    for _ = 1, PLATE_ROUNDS do
        local batch, seen = {}, {}
        for _ = 1, PLATE_BATCH do
            local plate = (prefix .. Utils.randomString(5, PLATE_ALPHABET)):sub(1, PLATE_MAX):upper()
            if not usedPlates[plate] and not seen[plate] then
                seen[plate] = true
                batch[#batch + 1] = plate
            end
        end
        if #batch > 0 then
            local rows, err = DB.query(PLATES_SQL, { batch })
            if not rows then
                Log.warn('vehicles: the plate check failed (%s); a random plate is taken unchecked', tostring(err))
                rows = {}
            end
            local taken = {}
            for i = 1, #rows do taken[rows[i].plate] = true end
            for i = 1, #batch do
                if not taken[batch[i]] and not usedPlates[batch[i]] then return batch[i] end
            end
        end
    end
    return nil, 'plate_exhausted'
end

local function charIdOf(src)
    local info = Core.Player.getInfo(src)
    return info and info.charId or nil
end

--- Public (copied) view of a tracked vehicle — never hands out the entity handle. `parked` = the scene node id
--- while the vehicle is the adopted clone of a parked car (§55.21.4).
local function publicInfo(info)
    return {
        netId = info.netId, model = info.model, plate = info.plate,
        ownerCharId = info.ownerCharId, keys = Utils.deepCopy(info.keys), keyMode = info.keyMode,
        locked = info.locked, vehId = info.vehId, spawnedBy = info.spawnedBy,
        createdAt = info.createdAt, parked = info.parked,
    }
end

--- Deep-checks a client-supplied props table (DESIGN §5): string keys ≤ 32, scalar values
--- and bounded numeric maps. Core.Vehicles.getProps deliberately uses zero-based native ids for
--- extras/mods/tyres, and JSON can round those ids into numeric strings, so both forms are legal.
local function validateProps(props)
    if type(props) ~= 'table' then return false, 'props must be a table' end
    local count = 0
    for key, value in pairs(props) do
        count = count + 1
        if count > PROPS_MAX_KEYS then return false, 'too many props' end
        if type(key) ~= 'string' or #key < 1 or #key > PROPS_MAX_KEY_LEN then return false, 'bad prop key' end
        local kind = type(value)
        if kind == 'number' then
            if value ~= value or value == math.huge or value == -math.huge then return false, 'bad number: ' .. key end
        elseif kind == 'string' then
            if #value > PROPS_MAX_STRING then return false, 'string too long: ' .. key end
        elseif kind == 'table' then
            local n = 0
            for index, entry in pairs(value) do
                n = n + 1
                local mapIndex = math.type(index) == 'integer' and index or math.tointeger(tonumber(index))
                if mapIndex == nil or mapIndex < 0 or mapIndex > PROPS_MAX_MAP_INDEX or n > PROPS_MAX_MAP_ENTRIES then
                    return false, 'bad prop map: ' .. key
                end
                local entryKind = type(entry)
                if entryKind == 'number' then
                    if entry ~= entry or entry == math.huge or entry == -math.huge then
                        return false, 'bad prop map value: ' .. key
                    end
                elseif entryKind ~= 'boolean' then
                    return false, 'bad prop map value: ' .. key
                end
            end
        elseif kind ~= 'boolean' then
            return false, 'bad prop type: ' .. key
        end
    end
    local encoded = json.encode(props)
    if type(encoded) ~= 'string' or #encoded > (Config.Vehicles.MaxPropsBytes or 16384) then
        return false, 'props too large'
    end
    return true
end

local function clampInt(v, lo, hi)
    if type(v) ~= 'number' or v ~= v then return nil end
    v = math.floor(v)
    return v < lo and lo or (v > hi and hi or v)
end

local function clampNum(v, lo, hi)
    if type(v) ~= 'number' or v ~= v then return nil end
    return v < lo and lo or (v > hi and hi or v)
end

--- Clamps every number of a map (integer or digit-string keys) in place; other entries stay.
local function clampMap(t, lo, hi, int)
    for k, v in pairs(t) do
        if type(v) == 'number' then t[k] = int and clampInt(v, lo, hi) or clampNum(v, lo, hi) end
    end
end

--- The props every write stores (review RV4 F1): a JSON-safe COPY with each known key clamped to its native range
--- (PROP_* above; a known key of the wrong type is dropped) and, with `plate`, props.plate = plate (the record's —
--- a props table never renames a car). Unknown keys pass as validateProps left them.
local function cleanProps(props, plate)
    local p = type(props) == 'table' and Utils.jsonSafe(props) or {}
    for key, r in pairs(PROP_INT) do p[key] = clampInt(p[key], r[1], r[2]) end
    for key, r in pairs(PROP_FLOAT) do p[key] = clampNum(p[key], r[1], r[2]) end
    for key in pairs(PROP_RGB) do
        local v = p[key]
        if type(v) == 'table' then
            p[key] = { clampInt(v[1], 0, 255) or 0, clampInt(v[2], 0, 255) or 0, clampInt(v[3], 0, 255) or 0 }
        elseif v ~= nil and not (v == false and (key == 'customPrimary' or key == 'customSecondary')) then
            p[key] = nil
        end
    end
    local xenon = p.xenonColor
    if xenon ~= nil then
        xenon = clampInt(xenon, -1, XENON_STOCK)
        p.xenonColor = (xenon and (xenon <= XENON_MAX or xenon == XENON_STOCK)) and xenon or nil
    end
    if type(p.mods) == 'table' then clampMap(p.mods, MOD_INDEX_MIN, MOD_INDEX_MAX, true) end
    if type(p.tyreHealth) == 'table' then clampMap(p.tyreHealth, 0, 1000, false) end
    if type(p.lights) == 'table' and p.lights[3] ~= nil then p.lights[3] = clampInt(p.lights[3], 0, 3) end
    if type(plate) == 'string' then p.plate = plate end
    return p
end

--- The record position of an entity: { x, y, z, heading, bucket? } (bucket only when not 0, review RV4 F6).
local function positionOf(entity)
    local coords = GetEntityCoords(entity)
    local bucket = GetEntityRoutingBucket(entity)
    return { x = coords.x, y = coords.y, z = coords.z, heading = GetEntityHeading(entity),
        bucket = (math.type(bucket) == 'integer' and bucket ~= 0) and bucket or nil }
end

--- The §8 state bags of a tracked vehicle: vehId once persisted, coreProps unless it is a parked car's clone
--- (the scene's snCfg carries its props to the owner client).
local function writeState(entity, info)
    local state = Entity(entity).state
    state:set('coreVeh', true, true)
    state:set('locked', info.locked, true)
    state:set('owner', info.ownerCharId or false, true)
    state:set('keys', info.keys, true)
    state:set('keyMode', info.keyMode, true)
    state:set('plate', info.plate, true)
    if info.vehId then state:set('vehId', info.vehId, true) end
    if info.props and next(info.props) and not info.parked then state:set('coreProps', info.props, true) end
    return state
end

local function track(info)
    local netId = info.netId
    spawned[netId], byEntity[info.entity], usedPlates[info.plate] = info, netId, netId
    if info.vehId then byVehId[info.vehId] = netId end
    if info.parked then clones[info.parked] = netId end
    Core.Registry.track('vehicle', netId, info.spawnedBy)
end

--- A tracked vehicle has its record now (persist, spawnRecord): the vehId state key, the index, AutoPark.
local function setVehId(info, vehId)
    info.vehId = vehId
    byVehId[vehId] = info.netId
    local entity = entityOf(info.netId)
    if entity ~= 0 then Entity(entity).state:set('vehId', vehId, true) end
    if P.wake then P.wake() end
end

--- Spawns a vehicle server-side and tracks it. Yields while the entity materialises,
--- so it must be called from a thread/event handler. Returns netId | nil, err.
--- Internal spawn path. `restoreRecordId` is deliberately not exposed in the public options schema: otherwise
--- an arbitrary resource could pretend to restore somebody else's record and bypass global plate uniqueness.
local function spawn(opts, restoreRecordId)
    if type(opts) ~= 'table' then return nil, 'bad_opts' end
    local ok, err = Validate.checkTable(SPAWN_SCHEMA, opts)
    if not ok then return nil, err end

    local model = opts.model
    if type(model) == 'string' then
        if #model < 1 or #model > 64 then return nil, 'bad_model' end
        model = GetHashKey(model)
    elseif math.type(model) ~= 'integer' then
        return nil, 'bad_model'
    end

    local owner = Core.Registry.getCaller()
    local vehType = opts.type or 'automobile'
    local coords = opts.coords
    local heading = (opts.heading or 0.0) + 0.0

    -- the plate BEFORE the entity (a slow or failed read never strands one), held in usedPlates across the yields;
    -- an explicitly requested plate must be honoured or refused, never silently replaced
    local plate
    if opts.plate ~= nil then
        plate, err = normalizePlate(opts.plate, restoreRecordId)
    else
        plate, err = randomPlate()
    end
    if not plate then return nil, err end
    local hold = {}
    usedPlates[plate] = hold
    local function fail(why, entity)
        if usedPlates[plate] == hold then usedPlates[plate] = nil end
        if entity and entity ~= 0 and DoesEntityExist(entity) then DeleteEntity(entity) end
        return nil, why
    end

    local entity = CreateVehicleServerSetter(model, vehType, coords.x, coords.y, coords.z, heading)
    if entity == 0 then return fail('create_failed') end

    local deadline = GetGameTimer() + (Config.Vehicles.SpawnTimeoutMs or 5000)
    while not DoesEntityExist(entity) do
        if GetGameTimer() >= deadline then return fail('spawn_timeout', entity) end
        Wait(50)
    end

    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId == 0 then return fail('no_netid', entity) end

    local ownerCharId = opts.ownerCharId or (opts.ownerSrc and charIdOf(opts.ownerSrc)) or nil
    local keyMode = opts.keyMode or 'virtual'
    local keys = {}
    if opts.keys then
        for i = 1, #opts.keys do keys[opts.keys[i]] = true end
    end
    if ownerCharId and keyMode == 'virtual' then keys[ownerCharId] = true end
    SetVehicleNumberPlateText(entity, plate)

    local name = opts.model
    local info = {
        netId = netId, entity = entity, model = model, plate = plate,
        ownerCharId = ownerCharId, keys = keys, keyMode = keyMode, locked = opts.locked == true,
        vehId = nil, spawnedBy = owner, createdAt = os.time(),
        vehType = vehType, props = opts.props and cleanProps(opts.props, plate) or nil,
        modelName = type(name) == 'string' and name:find(MODEL_NAME) and name:lower() or nil,
        plateFixed = opts.plate ~= nil,          -- asked for: never re-plated by persist (else a collision re-plates)
    }
    track(info)
    writeState(entity, info)

    if opts.bucket then SetEntityRoutingBucket(entity, opts.bucket) end
    if opts.persistent or ownerCharId then SetEntityOrphanMode(entity, ORPHAN_KEEP_ENTITY) end
    if info.locked then SetVehicleDoorsLocked(entity, LOCK_LOCKED) end

    if opts.ownerSrc and info.props then
        TriggerClientEvent('core:client:applyVehicleProps', opts.ownerSrc, netId, info.props)
    end
    Core.emitHook('vehicleSpawned', netId, publicInfo(info))
    return netId
end

function Vehicles.spawn(opts)
    if type(opts) == 'table' and opts.recordId ~= nil then return nil, 'reserved_option' end
    return spawn(opts)
end

--- Deletes a tracked vehicle (and untracks it). Returns true when something was removed.
function Vehicles.delete(netId)
    if not Validate.value('netId', netId) then return false end
    local entity = entityOf(netId)
    local tracked = spawned[netId] ~= nil
    if entity ~= 0 then DeleteEntity(entity) end
    forget(netId)
    if not tracked and entity == 0 then return false end
    Core.emitHook('vehicleDeleted', netId)
    return true
end

function Vehicles.exists(netId)
    return entityOf(netId) ~= 0
end

function Vehicles.getEntity(netId)
    return entityOf(netId)
end

function Vehicles.getInfo(netId)
    local info = spawned[netId]
    if not info then return nil end
    return publicInfo(info)
end

--- State bag + best-effort RPC (SetVehicleDoorsLocked runs on the owning client).
function Vehicles.setLocked(netId, locked)
    if type(locked) ~= 'boolean' then return false end
    local info = spawned[netId]
    if not info then return false end
    local entity = entityOf(netId)
    if entity == 0 then return false end
    info.locked = locked
    Entity(entity).state:set('locked', locked, true)
    SetVehicleDoorsLocked(entity, locked and LOCK_LOCKED or LOCK_UNLOCKED)
    if info.vehId then write(info.vehId, { locked = locked }) end      -- the record follows (queued)
    return true
end

function Vehicles.isLocked(netId)
    local info = spawned[netId]
    return info ~= nil and info.locked == true
end

--- The keys bag, and the record's keys of a persisted car (queued): a key given or taken back is never only live.
local function syncKeys(info)
    local entity = entityOf(info.netId)
    if entity ~= 0 then Entity(entity).state:set('keys', info.keys, true) end
    if info.vehId then write(info.vehId, { keys = keyList(info.keys) }) end
end

function Vehicles.giveKeys(netId, charId)
    local info = spawned[netId]
    if not info or not Validate.value('id', charId) then return false end
    info.keys[charId] = true
    syncKeys(info)
    return true
end

function Vehicles.removeKeys(netId, charId)
    local info = spawned[netId]
    if not info or not Validate.value('id', charId) then return false end
    info.keys[charId] = nil
    syncKeys(info)
    return true
end

--- True when `src`'s character has an explicit virtual key. Item-key vehicles intentionally
--- have no such key: their owning plugin validates the physical inventory stack before calling
--- Vehicles.setLocked. Virtual-mode ownership remains compatible because spawn inserts its owner.
function Vehicles.hasKeys(src, netId)
    local info = spawned[netId]
    if not info then return false end
    local charId = charIdOf(src)
    if not charId then return false end
    return info.keys[charId] == true
end

--- A new owner must be an existing character (an online session's, else one awaited read): false otherwise.
function Vehicles.setOwner(netId, charId)
    local info = spawned[netId]
    if not info then return false end
    if charId ~= nil and not Validate.value('id', charId) then return false end
    if charId ~= nil and charId ~= info.ownerCharId then
        local known, err = P.characterExists(charId)
        if not known then
            Log.warn('vehicles: setOwner(%s): no character %s (%s)', tostring(netId), charId, tostring(err or 'none'))
            return false
        end
        if spawned[netId] ~= info then return false end       -- (the read yielded: the car may be gone)
    end
    local previous = info.ownerCharId
    if previous and previous ~= charId then info.keys[previous] = nil end -- virtual keys follow ownership
    info.ownerCharId = charId
    if charId and info.keyMode == 'virtual' then info.keys[charId] = true end
    local entity = entityOf(netId)
    if entity ~= 0 then
        local state = Entity(entity).state
        state:set('owner', charId or false, true)
        state:set('keys', info.keys, true)
        if charId then SetEntityOrphanMode(entity, ORPHAN_KEEP_ENTITY) end
    end
    if info.vehId then write(info.vehId, { ownerCharId = charId or false, keys = keyList(info.keys) }) end
    return true
end

function Vehicles.getOwner(netId)
    local info = spawned[netId]
    return info and info.ownerCharId or nil
end

function Vehicles.getPlayerVehicles(src)
    local charId = charIdOf(src)
    local list = {}
    if not charId then return list end
    for netId, info in pairs(spawned) do
        if info.ownerCharId == charId then list[#list + 1] = netId end
    end
    return list
end

function Vehicles.list()
    local list = {}
    for netId in pairs(spawned) do list[#list + 1] = netId end
    return list
end

--- A live car whose core-chosen plate collided at the insert gets a new random plate (entity, bag, props, map).
local function replate(info)
    local plate = randomPlate()
    local entity = entityOf(info.netId)
    if not plate or entity == 0 or spawned[info.netId] ~= info then return false end
    if usedPlates[info.plate] == info.netId then usedPlates[info.plate] = nil end
    info.plate, usedPlates[plate] = plate, info.netId
    if info.props then info.props.plate = plate end
    SetVehicleNumberPlateText(entity, plate)
    Entity(entity).state:set('plate', plate, true)
    return true
end

--- Creates the `vehicles` record of an already spawned vehicle (one awaited insert — it yields; the UNIQUE plate
--- index is the final guard: a core-chosen plate that collides is replaced and the insert retried, a plate the
--- caller asked for fails the persist). Returns vehId | nil.
function Vehicles.persist(netId)
    local info = spawned[netId]
    if not info then return nil end
    if info.persisting then                               -- a concurrent persist of the same car: its result
        local deadline = GetGameTimer() + 30000
        while info.persisting and GetGameTimer() < deadline do Wait(50) end
        return info.vehId
    end
    if info.vehId then return info.vehId end
    local entity = entityOf(netId)
    if entity == 0 then return nil end
    info.persisting = true
    local vehId, done, err
    for _ = 1, PERSIST_TRIES do
        vehId = Utils.uuid()
        done, err = DB.insert(TABLE, {
            id = vehId, owner_character_id = info.ownerCharId or nil, model = info.model, model_name = info.modelName,
            plate = info.plate, props = info.props or {}, stored = false, position = positionOf(entity),
            keys = keyList(info.keys), locked = info.locked == true,
            meta = { vehType = info.vehType, keyMode = info.keyMode },
        }, { returning = false })
        if done or DB.errorCode(err) ~= '23505' or not tostring(err):find('vehicles_plate_key', 1, true)
            or info.plateFixed or not replate(info) then break end
        Log.warn('vehicles: plate collision at persist; netId %s re-plated as %s', tostring(netId), info.plate)
    end
    info.persisting = nil
    if not done then
        Log.error('vehicles: persist of netId %s failed (%s)', tostring(netId), tostring(err))
        return nil
    end
    if spawned[netId] == info then setVehId(info, vehId) else info.vehId = vehId end
    mirrorOf({ id = vehId, ownerCharId = info.ownerCharId or false, model = info.model, modelName = info.modelName,
        plate = info.plate, stored = false, destroyed = false, parked = false, locked = info.locked == true,
        keys = keyList(info.keys), meta = { vehType = info.vehType, keyMode = info.keyMode } })
    settle(vehId)
    return vehId
end

--- The record's keys as spawn's `keys` option (an array of charIds ≤ 32; anything else: none).
local function recordKeys(record)
    local list, out = record.keys, {}
    if type(list) ~= 'table' or #list > 32 then return nil end
    for i = 1, #list do
        if Validate.value('id', list[i]) then out[#out + 1] = list[i] end
    end
    return #out > 0 and out or nil
end

local function spawnFromRecord(record, coords, heading, ownerSrc, bucket)
    if byVehId[record.id] or spawning[record.id] then return nil, 'already_spawned' end
    spawning[record.id] = true                        -- spawn yields: a second spawnRecord meanwhile is refused
    local ok, netId, err = pcall(spawn, {
        model = record.modelName or record.model, coords = coords, heading = heading or 0.0,
        type = record.meta and record.meta.vehType or nil, keyMode = record.meta and record.meta.keyMode or nil,
        plate = record.plate, ownerCharId = record.ownerCharId or nil, ownerSrc = ownerSrc,
        props = record.props, persistent = true, keys = recordKeys(record), locked = record.locked == true,
        bucket = bucket,
    }, record.id)
    spawning[record.id] = nil
    if not ok then error(netId, 0) end
    if not netId then return nil, err end
    -- never live AND parked: a node that names the record appeared while the car was made (the park paths refuse a
    -- record while it spawns — P.spawning — so this is the back-out of last resort)
    local now = recs[record.id]
    if now and now.parked and P.parkedNode and P.parkedNode(now) then
        Vehicles.delete(netId)
        return nil, 'parked'
    end
    setVehId(spawned[netId], record.id)
    local e = recs[record.id] or mirrorOf(record)
    local patch = { stored = false }
    if e.destroyed == true or record.destroyed == true then patch.destroyed = false end   -- a wreck brought back
    write(record.id, patch)
    return netId
end

--- Promotes one existing networked GTA vehicle (for example a validated, hotwired ambient car) into a
--- server-owned persistent Core vehicle. The caller is a trusted server resource; no net event exposes this API.
--- A Core.Scene clone (state `sn`: a map / plugin vehicle node's promoted entity) is refused 'scene_clone' — the
--- scene deletes it at its demotion, the record would be orphaned (review RV4 F8).
function Vehicles.adopt(netId, opts)
    if not Validate.value('netId', netId) or type(opts) ~= 'table' then return nil, 'bad_opts' end
    local valid, validationErr = Validate.checkTable(ADOPT_SCHEMA, opts)
    if not valid then return nil, validationErr end
    if opts.props then
        valid, validationErr = validateProps(opts.props)
        if not valid then return nil, validationErr end
    end
    if spawned[netId] then return nil, 'already_tracked' end
    local entity = NetworkGetEntityFromNetworkId(netId)
    if entity == 0 or not DoesEntityExist(entity) or GetEntityType(entity) ~= ENTITY_TYPE_VEHICLE then
        return nil, 'no_vehicle'
    end
    if Entity(entity).state.sn ~= nil then return nil, 'scene_clone' end
    local ownerSrc = opts.ownerSrc
    local ownerCharId = opts.ownerCharId or (ownerSrc and charIdOf(ownerSrc)) or nil
    if ownerSrc ~= nil and not Validate.value('src', ownerSrc) then return nil, 'bad_owner' end
    if ownerCharId ~= nil and not Validate.value('id', ownerCharId) then return nil, 'bad_owner' end
    local keyMode = opts.keyMode or 'virtual'
    if keyMode ~= 'virtual' and keyMode ~= 'item' then return nil, 'bad_key_mode' end

    local rawPlate = Utils.trim(GetVehicleNumberPlateText(entity) or '')
    local plate, plateErr = normalizePlate(rawPlate)
    if not plate then plate, plateErr = randomPlate() end
    if not plate then return nil, plateErr end
    -- the plate reads yielded: the entity may have gone or been adopted meanwhile
    if spawned[netId] then return nil, 'already_tracked' end
    if not DoesEntityExist(entity) or NetworkGetEntityFromNetworkId(netId) ~= entity then return nil, 'no_vehicle' end
    SetVehicleNumberPlateText(entity, plate)

    local keys = {}
    if ownerCharId and keyMode == 'virtual' then keys[ownerCharId] = true end
    local info = {
        netId = netId, entity = entity, model = GetEntityModel(entity), plate = plate,
        ownerCharId = ownerCharId, keys = keys, keyMode = keyMode, locked = opts.locked == true,
        vehId = nil, spawnedBy = Core.Registry.getCaller(), createdAt = os.time(),
        vehType = GetVehicleType(entity), props = type(opts.props) == 'table' and cleanProps(opts.props, plate) or nil,
    }
    track(info)
    local state = writeState(entity, info)
    SetVehicleDoorsLocked(entity, info.locked and LOCK_LOCKED or LOCK_UNLOCKED)
    SetEntityOrphanMode(entity, ORPHAN_KEEP_ENTITY)

    local vehId = Vehicles.persist(netId)
    if not vehId then
        forget(netId)
        state:set('coreVeh', false, true)
        return nil, 'persist_failed'
    end
    Core.emitHook('vehicleSpawned', netId, publicInfo(info))
    return vehId
end

--- Saves the last known position/props, then removes the entity from the world.
--- (An unpersisted vehicle is persisted first: an awaited insert.) The record write is queued.
function Vehicles.store(netId)
    local info = spawned[netId]
    if not info then return false end
    local vehId = info.vehId or Vehicles.persist(netId)
    if not vehId or spawned[netId] ~= info then return false end
    local patch = { stored = true, props = info.props or {}, keys = keyList(info.keys), locked = info.locked == true }
    local entity = entityOf(netId)
    if entity ~= 0 then patch.position = positionOf(entity) end
    if not write(vehId, patch) then return false end
    Vehicles.delete(netId)
    return true
end

--- Accepts a validated props table (client route goes through `core:server:vehicleProps`): clamped to the native
--- ranges, props.plate = the car's plate (cleanProps). A parked car's clone does not project coreProps: its node
--- takes them when it is demoted (server/vehicles_park.lua).
function Vehicles.saveProps(netId, props)
    local info = spawned[netId]
    if not info then return false end
    local ok, err = validateProps(props)
    if not ok then
        Log.debug('vehicles: rejected props for netId %s (%s)', tostring(netId), tostring(err))
        return false
    end
    local nextProps = cleanProps(props, info.plate)
    if json.encode(info.props or {}) == json.encode(nextProps) then return true end
    info.props = nextProps
    local entity = entityOf(netId)
    if info.parked then
        info.propsSaved = true                     -- a parked car's clone: its node takes them at the demotion
    elseif entity ~= 0 then
        Entity(entity).state:set('coreProps', info.props, true)
    end
    if info.vehId then write(info.vehId, { props = info.props }) end    -- queued; ≤ 1 per 5 s per driver
    return true
end

--- The world lost the entity (culled, deleted elsewhere): drop our book-keeping. A parked car's clone also tells
--- the domain (vehicleDeleted): its node lives on, the scene demotes it.
AddEventHandler('entityRemoved', function(entity)
    local netId = byEntity[entity]
    if not netId then return end
    local clone = spawned[netId] and spawned[netId].parked
    forget(netId)
    if clone then Core.emitHook('vehicleDeleted', netId) end
    Log.debug('vehicles: untracked netId %s (entity removed)', tostring(netId))
end)

local function clear(t) for k in pairs(t) do t[k] = nil end end

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    -- Synchronous teardown: no Wait. With Core.Scene every live persisted car is PARKED here first (P.beforeStop,
    -- server/vehicles_fleet.lua: clones hand their final pose to their nodes, other live cars become parked nodes
    -- at their pose — review RV4 F14 / RV6 F2), so the boot has nothing to spawn. Without it (or when a node was
    -- refused) a live persistent vehicle remains logically `stored = false` at its final position (the boot check
    -- re-parks it); a vehicle explicitly garaged earlier has no live entity here and remains `stored = true`.
    -- Every record write here is QUEUED (core_db commits it after core is gone, §56.1): nothing awaits, no flush.
    P.stopped = true
    if P.beforeStop then
        local ok, err = pcall(P.beforeStop)
        if not ok then Log.error('vehicles: parking teardown failed: %s', tostring(err)) end
    end
    for _, info in pairs(spawned) do
        local entity = info.entity
        if info.vehId then
            local patch = { stored = false, props = info.props or {}, keys = keyList(info.keys),
                locked = info.locked == true }
            if entity and DoesEntityExist(entity) then patch.position = positionOf(entity) end
            write(info.vehId, patch)
        end
        if entity and DoesEntityExist(entity) then DeleteEntity(entity) end
    end
    for _, t in ipairs({ spawned, byEntity, usedPlates, byVehId, clones, rest, recs, spawning }) do clear(t) end
end)

-- The one-shot hand-off to server/vehicles_park.lua (it adds its helpers and passes P on to
-- server/vehicles_fleet.lua, which clears the global).
P.entityOf, P.forget, P.track, P.writeState, P.publicInfo = entityOf, forget, track, writeState, publicInfo
P.validateProps, P.cleanProps, P.positionOf = validateProps, cleanProps, positionOf
P.write, P.readRecord, P.fromRow, P.fromRead, P.mirrorOf = write, readRecord, fromRow, fromRead, mirrorOf
P.settle, P.markWrite, P.lastWrite, P.writeSeq = settle, markWrite, lastWrite, function() return writeSeq end
P.spawnFromRecord, P.charIdOf, P.keyList = spawnFromRecord, charIdOf, keyList
-- fxlint-disable-next-line C003 -- one-shot hand-off to server/vehicles_park.lua (then vehicles_fleet.lua clears it)
CoreVehiclesPark = P
