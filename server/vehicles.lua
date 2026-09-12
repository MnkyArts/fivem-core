--- core/server/vehicles.lua — Core.Vehicles (server).
--- Server-owned vehicle spawning, ownership/keys, lock state, and the `vehicles` document
--- records. DESIGN §4.6 (API), §5 (vehicleLock / vehicleProps net events), §8 (state bags).

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
local PROPS_MAX_ARRAY <const> = 32
local PROPS_DISTANCE <const> = 10.0
local COLLECTION <const> = 'vehicles'
local RECORDS_COOLDOWN_MS <const> = 1000

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
    locked = 'boolean?',
    persistent = 'boolean?',
    bucket = { 'integer', min = 0, max = 65535, optional = true },
}

local spawned = {}      -- [netId] = info (live, includes the entity handle)
local byEntity = {}     -- [entity handle] = netId
local usedPlates = {}   -- [plate] = netId

--- Resolves a **tracked** netId to a live entity handle (0 when untracked or gone).
--- Deliberately no NetworkGetEntityFromNetworkId fallback: the exported API must never
--- act on an entity core did not spawn (another resource's vehicle, a ped, ...).
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
    spawned[netId] = nil
    Core.Registry.untrack('vehicle', netId)
    return true
end

--- `^[%w ]{1,8}$` (Lua patterns have no counted repeats, so the length is checked separately).
local function normalizePlate(plate)
    if type(plate) ~= 'string' then return nil, 'bad_plate' end
    if #plate < 1 or #plate > PLATE_MAX then return nil, 'bad_plate' end
    if not plate:match('^[%w ]+$') then return nil, 'bad_plate' end
    if usedPlates[plate] then return nil, 'plate_taken' end
    return plate
end

local function randomPlate()
    for _ = 1, 20 do
        local plate = (Config.Vehicles.PlatePrefix or 'LS') .. Utils.randomString(5, PLATE_ALPHABET)
        plate = plate:sub(1, PLATE_MAX)
        if not usedPlates[plate] then return plate end
    end
    return (Config.Vehicles.PlatePrefix or 'LS') .. Utils.randomString(5, PLATE_ALPHABET)
end

local function charIdOf(src)
    local info = Core.Player.getInfo(src)
    return info and info.charId or nil
end

--- Public (copied) view of a tracked vehicle — never hands out the entity handle.
local function publicInfo(info)
    return {
        netId = info.netId, model = info.model, plate = info.plate,
        ownerCharId = info.ownerCharId, keys = Utils.deepCopy(info.keys),
        locked = info.locked, vehId = info.vehId, spawnedBy = info.spawnedBy,
        createdAt = info.createdAt,
    }
end

--- Deep-checks a client-supplied props table (DESIGN §5): string keys ≤ 32, values
--- number/boolean/string ≤ 32 or an array ≤ 32 of numbers, ≤ MaxPropsBytes encoded.
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
                if math.type(index) ~= 'integer' or index < 1 or n > PROPS_MAX_ARRAY then
                    return false, 'bad array: ' .. key
                end
                if type(entry) ~= 'number' or entry ~= entry then return false, 'bad array value: ' .. key end
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

--- Spawns a vehicle server-side and tracks it. Yields while the entity materialises,
--- so it must be called from a thread/event handler. Returns netId | nil, err.
function Vehicles.spawn(opts)
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
    local keys = {}
    if opts.keys then
        for i = 1, #opts.keys do keys[opts.keys[i]] = true end
    end
    if ownerCharId then keys[ownerCharId] = true end

    -- an explicitly requested plate must be honoured or refused, never silently replaced
    local plate
    if opts.plate ~= nil then
        plate, err = normalizePlate(opts.plate)
        if not plate then
            DeleteEntity(entity)
            return nil, err
        end
    else
        plate = randomPlate()
    end
    SetVehicleNumberPlateText(entity, plate)

    local info = {
        netId = netId, entity = entity, model = model, plate = plate,
        ownerCharId = ownerCharId, keys = keys, locked = opts.locked == true,
        vehId = nil, spawnedBy = owner, createdAt = os.time(),
        vehType = vehType, props = opts.props and Utils.jsonSafe(opts.props) or nil,
    }
    spawned[netId] = info
    byEntity[entity] = netId
    usedPlates[plate] = netId

    local state = Entity(entity).state
    state:set('coreVeh', true, true)
    state:set('locked', info.locked, true)
    state:set('owner', ownerCharId or false, true)
    state:set('keys', keys, true)
    state:set('plate', plate, true)

    if opts.bucket then SetEntityRoutingBucket(entity, opts.bucket) end
    if opts.persistent or ownerCharId then SetEntityOrphanMode(entity, ORPHAN_KEEP_ENTITY) end
    if info.locked then SetVehicleDoorsLocked(entity, LOCK_LOCKED) end

    Core.Registry.track('vehicle', netId, owner)
    if opts.ownerSrc and info.props then
        TriggerClientEvent('core:client:applyVehicleProps', opts.ownerSrc, netId, info.props)
    end
    Core.emitHook('vehicleSpawned', netId, publicInfo(info))
    return netId
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

--- True when `src`'s character owns the vehicle or holds a key for it.
function Vehicles.hasKeys(src, netId)
    local info = spawned[netId]
    if not info then return false end
    local charId = charIdOf(src)
    if not charId then return false end
    return info.ownerCharId == charId or info.keys[charId] == true
end

function Vehicles.setOwner(netId, charId)
    local info = spawned[netId]
    if not info then return false end
    if charId ~= nil and not Validate.value('id', charId) then return false end
    local previous = info.ownerCharId
    if previous and previous ~= charId then info.keys[previous] = nil end -- keys follow ownership for the old owner
    info.ownerCharId = charId
    if charId then info.keys[charId] = true end
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

local function positionOf(entity)
    local coords = GetEntityCoords(entity)
    return { x = coords.x, y = coords.y, z = coords.z, heading = GetEntityHeading(entity) }
end

--- Creates the `vehicles` document for an already spawned vehicle. Returns vehId | nil.
function Vehicles.persist(netId)
    local info = spawned[netId]
    if not info then return nil end
    if info.vehId then return info.vehId end
    local entity = entityOf(netId)
    if entity == 0 then return nil end
    local vehId = Core.DB.create(COLLECTION, {
        ownerCharId = info.ownerCharId or false, model = info.model, plate = info.plate,
        props = info.props or {}, stored = false, position = positionOf(entity),
        meta = { vehType = info.vehType },
    })
    if not vehId then return nil end
    info.vehId = vehId
    Entity(entity).state:set('vehId', vehId, true)
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

--- Spawns a stored vehicle from its record. Returns netId | nil, err.
function Vehicles.spawnRecord(vehId, coords, heading, ownerSrc)
    local record = Vehicles.getRecord(vehId)
    if not record then return nil, 'no_record' end
    if not Validate.value('vector3', coords) then return nil, 'bad_coords' end
    if record.stored == false then return nil, 'already_spawned' end
    for _, tracked in pairs(spawned) do
        if tracked.vehId == vehId then return nil, 'already_spawned' end
    end
    local netId, err = Vehicles.spawn({
        model = record.model, coords = coords, heading = heading or 0.0,
        type = record.meta and record.meta.vehType or nil, plate = record.plate,
        ownerCharId = record.ownerCharId or nil, ownerSrc = ownerSrc,
        props = record.props, persistent = true,
    })
    if not netId then return nil, err end
    local info = spawned[netId]
    info.vehId = vehId
    local entity = entityOf(netId)
    if entity ~= 0 then Entity(entity).state:set('vehId', vehId, true) end
    Core.DB.update(COLLECTION, vehId, { stored = false })
    return netId
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

--- Accepts a validated props table (client route goes through `core:server:vehicleProps`).
function Vehicles.saveProps(netId, props)
    local info = spawned[netId]
    if not info then return false end
    local ok, err = validateProps(props)
    if not ok then
        Log.debug('vehicles: rejected props for netId %s (%s)', tostring(netId), tostring(err))
        return false
    end
    info.props = Utils.jsonSafe(props)
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

--- The world lost the entity (culled, deleted elsewhere): drop our book-keeping.
AddEventHandler('entityRemoved', function(entity)
    local netId = byEntity[entity]
    if not netId then return end
    forget(netId)
    Log.debug('vehicles: untracked netId %s (entity removed)', tostring(netId))
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= Core.name then return end
    -- synchronous teardown: no Wait, the resource is already stopping
    for _, info in pairs(spawned) do
        if info.entity and DoesEntityExist(info.entity) then DeleteEntity(info.entity) end
    end
    spawned = {}
    byEntity = {}
    usedPlates = {}
end)
