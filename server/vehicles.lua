--- core/server/vehicles.lua — Core.Vehicles (server).
--- Server-owned vehicle spawning, ownership/keys, lock state, and the `vehicles` document
--- records. DESIGN §4.6 (API), §5 (vehicleLock / vehicleProps net events), §8 (state bags).
--- Parking (§55.21.4: park, the scene hooks, AutoPark, getInfoByRecord, the parked branches of spawnRecord /
--- restoreRecord / store / delete / deleteRecord) is server/vehicles_park.lua, which loads RIGHT AFTER this file
--- and takes the live maps and helpers once through the one-shot global `CoreVehiclesPark` (P); server/
--- vehicles_fleet.lua (AutoPark, boot / stop reconciliation, MaxParked) follows it and adds P.wake (a record
--- appeared: AutoPark) and P.beforeStop (core stops: clones hand their poses to their nodes, live cars park).
--- Props (review RV4 F1): every write goes through cleanProps — the JSON-safe copy with every known key clamped to
--- its native range (colour / mod indexes, healths 0..1000, fuel 0..100, dirt 0..15) and props.plate = the plate.
--- Records: spawnRecord answers 'already_spawned' only while the record's car is live (an out record with nothing
--- in the world is spawned: review RV6 F2); restoreRecord refuses a `destroyed` record (§55.21.4 notes, D-C).
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
local Net = Core.Net

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
local PROPS_DISTANCE <const> = 10.0
local COLLECTION <const> = 'vehicles'
local RECORDS_COOLDOWN_MS <const> = 1000
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
    model = 'any',
    coords = 'vector3',
    heading = 'number?',
    type = { 'string', max = 16, optional = true },
    plate = { 'string', max = PLATE_MAX, optional = true },
    ownerSrc = 'src?',
    ownerCharId = 'id?',
    keys = { 'array', of = 'id', max = 32, optional = true },
    props = 'table?',
    keyMode = { 'enum', 'virtual', 'item', optional = true },
    locked = 'boolean?',
    persistent = 'boolean?',
    bucket = { 'integer', min = 0, max = 65535, optional = true },
}

local ADOPT_SCHEMA <const> = {
    ownerSrc = 'src?',
    ownerCharId = 'id?',
    keyMode = { 'enum', 'virtual', 'item', optional = true },
    locked = 'boolean?',
    props = 'table?',
}

local spawned = {}      -- [netId] = info (live, includes the entity handle)
local byEntity = {}     -- [entity handle] = netId
local usedPlates = {}   -- [plate] = netId
local byVehId = {}      -- [vehId] = netId of the record's live vehicle (a parked car's adopted clone included)
local clones = {}       -- [nodeId] = netId: the adopted clone of a promoted parked car (server/vehicles_park.lua)
local rest = {}         -- [netId] = AutoPark's rest stamp (server/vehicles_park.lua)
-- The maps above are shared with server/vehicles_park.lua (P): they are cleared in place, never replaced.
local P = { spawned = spawned, byVehId = byVehId, clones = clones, rest = rest }

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
    return true
end

--- Normalises a persistent plate. Hyphens support real registration layouts such as LS-48291.
--- A plate is globally unique across **stored and live** Core.Vehicles records, not only within the
--- current process. `recordId` is used solely by spawnRecord when restoring that same record.
local function plateTaken(plate, recordId)
    if usedPlates[plate] then return true end
    local records = Core.DB.find(COLLECTION, { plate = plate })
    for i = 1, #records do
        if records[i].id ~= recordId then return true end
    end
    return false
end

local function normalizePlate(plate, recordId)
    if type(plate) ~= 'string' then return nil, 'bad_plate' end
    plate = Utils.trim(plate):upper()
    if #plate < 1 or #plate > PLATE_MAX then return nil, 'bad_plate' end
    if not plate:match('^[%w %-]+$') then return nil, 'bad_plate' end
    if plateTaken(plate, recordId) then return nil, 'plate_taken' end
    return plate
end

local function randomPlate(recordId)
    for _ = 1, 1000 do
        local plate = (Config.Vehicles.PlatePrefix or 'LS') .. Utils.randomString(5, PLATE_ALPHABET)
        plate = plate:sub(1, PLATE_MAX):upper()
        if not plateTaken(plate, recordId) then return plate end
    end
    return nil
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
    local entity = CreateVehicleServerSetter(model, vehType, coords.x, coords.y, coords.z, heading)
    if entity == 0 then return nil, 'create_failed' end

    local deadline = GetGameTimer() + (Config.Vehicles.SpawnTimeoutMs or 5000)
    while not DoesEntityExist(entity) do
        if GetGameTimer() >= deadline then
            if DoesEntityExist(entity) then DeleteEntity(entity) end
            return nil, 'spawn_timeout'
        end
        Wait(50)
    end

    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId == 0 then
        DeleteEntity(entity)
        return nil, 'no_netid'
    end

    local ownerCharId = opts.ownerCharId or (opts.ownerSrc and charIdOf(opts.ownerSrc)) or nil
    local keyMode = opts.keyMode or 'virtual'
    local keys = {}
    if opts.keys then
        for i = 1, #opts.keys do keys[opts.keys[i]] = true end
    end
    if ownerCharId and keyMode == 'virtual' then keys[ownerCharId] = true end

    -- an explicitly requested plate must be honoured or refused, never silently replaced
    local plate
    if opts.plate ~= nil then
        plate, err = normalizePlate(opts.plate, restoreRecordId)
        if not plate then
            DeleteEntity(entity)
            return nil, err
        end
    else
        plate = randomPlate(restoreRecordId)
        if not plate then
            DeleteEntity(entity)
            return nil, 'plate_exhausted'
        end
    end
    SetVehicleNumberPlateText(entity, plate)

    local name = opts.model
    local info = {
        netId = netId, entity = entity, model = model, plate = plate,
        ownerCharId = ownerCharId, keys = keys, keyMode = keyMode, locked = opts.locked == true,
        vehId = nil, spawnedBy = owner, createdAt = os.time(),
        vehType = vehType, props = opts.props and cleanProps(opts.props, plate) or nil,
        modelName = type(name) == 'string' and name:find(MODEL_NAME) and name:lower() or nil,
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
    return true
end

function Vehicles.isLocked(netId)
    local info = spawned[netId]
    return info ~= nil and info.locked == true
end

local function syncKeys(info)
    local entity = entityOf(info.netId)
    if entity ~= 0 then Entity(entity).state:set('keys', info.keys, true) end
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

function Vehicles.setOwner(netId, charId)
    local info = spawned[netId]
    if not info then return false end
    if charId ~= nil and not Validate.value('id', charId) then return false end
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
    if info.vehId then Core.DB.update(COLLECTION, info.vehId, { ownerCharId = charId or false }) end
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

--- Creates the `vehicles` document for an already spawned vehicle. Returns vehId | nil.
function Vehicles.persist(netId)
    local info = spawned[netId]
    if not info then return nil end
    if info.vehId then return info.vehId end
    local entity = entityOf(netId)
    if entity == 0 then return nil end
    local vehId = Core.DB.create(COLLECTION, {
        ownerCharId = info.ownerCharId or false, model = info.model, modelName = info.modelName, plate = info.plate,
        props = info.props or {}, stored = false, position = positionOf(entity),
        meta = { vehType = info.vehType, keyMode = info.keyMode },
    })
    if not vehId then return nil end
    setVehId(info, vehId)
    return vehId
end

function Vehicles.getRecords(charId)
    if not Validate.value('id', charId) then return {} end
    return Core.DB.find(COLLECTION, { ownerCharId = charId })
end

function Vehicles.getRecord(vehId)
    if not Validate.value('id', vehId) then return nil end
    return Core.DB.get(COLLECTION, vehId)
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
    if byVehId[record.id] then return nil, 'already_spawned' end
    local netId, err = spawn({
        model = record.modelName or record.model, coords = coords, heading = heading or 0.0,
        type = record.meta and record.meta.vehType or nil, keyMode = record.meta and record.meta.keyMode or nil,
        plate = record.plate, ownerCharId = record.ownerCharId or nil, ownerSrc = ownerSrc,
        props = record.props, persistent = true, keys = recordKeys(record), locked = record.locked == true,
        bucket = bucket,
    }, record.id)
    if not netId then return nil, err end
    setVehId(spawned[netId], record.id)
    local patch = { stored = false }
    if record.destroyed == true then patch.destroyed = false end     -- the domain brought a wreck back
    Core.DB.update(COLLECTION, record.id, patch)
    return netId
end

--- Spawns a record at a garage exit: a garaged one, or an out one with nothing in the world (no live car, no parked
--- node — review RV6 F2: never 'already_spawned' for ever). Returns netId | nil, err.
function Vehicles.spawnRecord(vehId, coords, heading, ownerSrc)
    local record = Vehicles.getRecord(vehId)
    if not record then return nil, 'no_record' end
    if not Validate.value('vector3', coords) then return nil, 'bad_coords' end
    return spawnFromRecord(record, coords, heading, ownerSrc)
end

--- Restores an out-of-garage record into the world at its saved position (and bucket), e.g. after a server
--- restart. Unlike spawnRecord this refuses stored vehicles, so boot recovery can never duplicate something
--- deliberately parked in a garage, and a `destroyed` record (a wrecked clone, §55.21.4 notes): only a domain's
--- spawnRecord brings a wreck back.
function Vehicles.restoreRecord(vehId, coords, heading, ownerSrc)
    local record = Vehicles.getRecord(vehId)
    if not record then return nil, 'no_record' end
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
    return spawnFromRecord(record, coords, heading, ownerSrc, bucket)
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
    local plate = normalizePlate(rawPlate)
    if not plate then plate = randomPlate() end
    if not plate then return nil, 'plate_exhausted' end
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
function Vehicles.store(netId)
    local info = spawned[netId]
    if not info then return false end
    local vehId = info.vehId or Vehicles.persist(netId)
    if not vehId then return false end
    local patch = { stored = true, props = info.props or {} }
    local entity = entityOf(netId)
    if entity ~= 0 then patch.position = positionOf(entity) end
    Core.DB.update(COLLECTION, vehId, patch)
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
    if info.vehId then Core.DB.update(COLLECTION, info.vehId, { props = info.props }) end
    return true
end

function Vehicles.deleteRecord(vehId)
    if not Validate.value('id', vehId) then return false end
    return Core.DB.delete(COLLECTION, vehId) == true
end

--- Distance resolver for the wrapper's `distance` check: the vehicle's own position.
local function vehicleCoords(_, netId)
    local entity = entityOf(netId)
    if entity == 0 then return nil end
    return GetEntityCoords(entity)
end

--- Toggles the lock of a core vehicle the player holds keys for (DESIGN §5).
Net.on('core:server:vehicleLock', { 'netId' }, function(src, netId)
    local entity = entityOf(netId)
    if entity == 0 or GetEntityType(entity) ~= ENTITY_TYPE_VEHICLE then return end
    if Entity(entity).state.coreVeh ~= true then return end
    if not Vehicles.hasKeys(src, netId) then
        Core.Notify.send(src, Config.Texts.no_keys, 'error')
        return
    end
    local locked = not Vehicles.isLocked(netId)
    if not Vehicles.setLocked(netId, locked) then return end
    Core.Notify.send(src, locked and Config.Texts.locked or Config.Texts.unlocked, 'info')
end, {
    cooldown = 500,
    requireLoaded = true,
    distance = { coords = vehicleCoords, max = Config.Vehicles.LockDistance },
})

--- Owner's client reports the vehicle's mod/colour props so they survive a respawn.
--- A ped sitting in the vehicle is inside PROPS_DISTANCE of it by definition (DESIGN §5).
Net.on('core:server:vehicleProps', { 'netId', { 'table', max = PROPS_MAX_KEYS } }, function(src, netId, props)
    local entity = entityOf(netId)
    if entity == 0 or GetEntityType(entity) ~= ENTITY_TYPE_VEHICLE then return end
    if Entity(entity).state.coreVeh ~= true then return end
    if not Vehicles.hasKeys(src, netId) then return end
    Vehicles.saveProps(netId, props)
end, {
    cooldown = 5000,
    requireLoaded = true,
    distance = { coords = vehicleCoords, max = PROPS_DISTANCE },
})

--- DESIGN §5.2: the player's own persisted vehicle records. Throttled per src because
--- it scans (and deep-copies) the whole `vehicles` collection.
local recordsCooldown = {}

Core.Callback.register('core:vehicles:mine', function(src)
    local now = GetGameTimer()
    if now < (recordsCooldown[src] or 0) then return {} end
    recordsCooldown[src] = now + RECORDS_COOLDOWN_MS
    local charId = charIdOf(src)
    if not charId then return {} end
    return Vehicles.getRecords(charId)
end)

AddEventHandler('playerDropped', function()
    local src = source
    recordsCooldown[src] = nil
end)

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
    P.stopped = true
    if P.beforeStop then
        local ok, err = pcall(P.beforeStop)
        if not ok then Log.error('vehicles: parking teardown failed: %s', tostring(err)) end
    end
    for _, info in pairs(spawned) do
        local entity = info.entity
        if info.vehId then
            local patch = { stored = false, props = info.props or {} }
            if entity and DoesEntityExist(entity) then patch.position = positionOf(entity) end
            Core.DB.update(COLLECTION, info.vehId, patch)
        end
        if entity and DoesEntityExist(entity) then DeleteEntity(entity) end
    end
    for _, t in ipairs({ spawned, byEntity, usedPlates, byVehId, clones, rest }) do clear(t) end
    Core.DB.flush()
end)

-- The one-shot hand-off to server/vehicles_park.lua (it adds its helpers and passes P on to
-- server/vehicles_fleet.lua, which clears the global).
P.entityOf, P.forget, P.track, P.writeState, P.publicInfo = entityOf, forget, track, writeState, publicInfo
P.validateProps, P.cleanProps, P.positionOf = validateProps, cleanProps, positionOf
-- fxlint-disable-next-line C003 -- one-shot hand-off to server/vehicles_park.lua (then vehicles_fleet.lua clears it)
CoreVehiclesPark = P
