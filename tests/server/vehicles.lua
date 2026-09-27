return function(H)
    local check, eq, errOf, lastSent, newServer, stubs, suite, vector3 =
        H.check, H.eq, H.errOf, H.lastSent, H.newServer, H.stubs, H.suite, H.vector3
    local sql, scalar = H.sql, H.scalar

--- A zero-based native map read back from jsonb: its keys are strings then ('0'); both forms are legal (§5).
local function at(map, i)
    if type(map) ~= 'table' then return nil end
    local v = map[i]
    if v == nil then v = map[tostring(i)] end
    return v
end

--- Core.Vehicles (DESIGN §4.6, §5, §8): spawn, plates, keys, the lock net event and records.
local function suiteVehicles()
    suite('vehicles')
    stubs.resetServer()
    local env, Core = newServer()
    env.GetEntityRoutingBucket = function(e) return stubs.entities[e] and stubs.entities[e].bucket or 0 end  -- CFX
    stubs.loadFile(env, 'server/getters.lua')        -- Vehicles.setData / getData (the §56 meta checks below)
    local V = Core.Vehicles
    stubs.connectPlayer(env, 1, { license = 'license:v1', name = 'Driver', coords = vector3(100.0, 100.0, 20.0) })
    local charId = Core.Player.getInfo(1).charId
    local ped = stubs.peds[1]

    local spawnedHook, deletedHook = {}, {}
    Core.on('vehicleSpawned', function(netId, info) spawnedHook[#spawnedHook + 1] = { netId = netId, info = info } end)
    Core.on('vehicleDeleted', function(netId) deletedHook[#deletedHook + 1] = netId end)

    -- spawn
    local netId, spawnErr = V.spawn({ model = 'adder', coords = vector3(100.0, 100.0, 20.0),
        heading = 90.0, ownerSrc = 1, locked = true, plate = 'LSTEST1', bucket = 3 })
    check(math.type(netId) == 'integer', 'spawn returns a netId', tostring(spawnErr))
    local entity = V.getEntity(netId)
    check(entity ~= 0, 'the entity handle is tracked')
    eq(V.exists(netId), true, 'exists')
    local record = stubs.entities[entity]
    eq(record.vehType, 'automobile', 'the default CreateVehicleServerSetter type')
    eq(record.model, env.GetHashKey('adder'), 'the model string was hashed')
    eq(record.plate, 'LSTEST1', 'SetVehicleNumberPlateText got the plate')
    eq(record.lockState, 2, 'a locked vehicle gets doorlock state 2')
    eq(record.orphanMode, 2, 'an owned vehicle is kept when orphaned')
    eq(record.bucket, 3, 'the routing bucket was applied')
    local state = stubs.entityState(env, entity)
    eq(state.coreVeh, true, 'the coreVeh state key')
    eq(state.locked, true, 'the locked state key')
    eq(state.owner, charId, 'the owner state key resolved ownerSrc to a charId')
    eq(state.plate, 'LSTEST1', 'the plate state key')
    eq(state.keys[charId], true, 'the owner holds a key')
    eq(#spawnedHook, 1, 'the vehicleSpawned hook fired')
    eq(spawnedHook[1].info.plate, 'LSTEST1', 'the hook carries the public info')
    eq(spawnedHook[1].info.entity, nil, 'the public info never leaks the entity handle')
    local info = V.getInfo(netId)
    eq(info.ownerCharId, charId, 'getInfo carries the owner')
    eq(info.spawnedBy, 'core', 'the calling resource is recorded')
    eq(info.locked, true, 'getInfo carries the lock state')
    info.keys[charId] = nil
    eq(V.hasKeys(1, netId), true, 'getInfo hands out a copy of the key table')

    -- spawn refusals
    eq(errOf(V.spawn('nope')), 'bad_opts', 'spawn refuses a non-table')
    eq(errOf(V.spawn({ model = 'adder' })), 'field "coords": expected vector3, got nil', 'coords are required')
    eq(errOf(V.spawn({ model = {}, coords = vector3(0, 0, 0) })), 'bad_model', 'the model must be a string or a hash')
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(0, 0, 0), plate = 'LSTEST1' })), 'plate_taken',
        'a plate already in use is refused')
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(0, 0, 0), plate = 'BAD!' })), 'bad_plate',
        'a plate with punctuation is refused')
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(0, 0, 0), recordId = 'cross_resource' })), 'reserved_option',
        'a public spawn cannot impersonate a record to bypass plate uniqueness')
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(0, 0, 0), plate = 'TOOLONGPLATE' })),
        'field "plate": expected string (len <= 8), got "TOOLONGPLATE"', 'an over-long plate is refused')
    stubs.spawnFails = true
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(0, 0, 0) })), 'create_failed',
        'a refusal from CreateVehicleServerSetter is passed on')
    stubs.spawnFails = false

    -- generated plates stay unique
    local netId2 = V.spawn({ model = 'adder', coords = vector3(0.0, 0.0, 0.0) })
    local plate2 = V.getInfo(netId2).plate
    check(plate2 ~= 'LSTEST1', 'a generated plate never collides')
    eq(plate2:sub(1, #Core.Config.Vehicles.PlatePrefix), Core.Config.Vehicles.PlatePrefix,
        'the generated plate carries the configured prefix')
    check(#plate2 <= 8, 'the generated plate fits the 8 character limit')
    eq(stubs.entityState(env, V.getEntity(netId2)).owner, false, 'an unowned vehicle replicates owner = false')
    local hyphenated = V.spawn({ model = 'adder', coords = vector3(10.0, 0.0, 0.0), plate = 'ls-48291' })
    eq(V.getInfo(hyphenated).plate, 'LS-48291', 'hyphenated plates are normalized for registration')
    eq(V.delete(hyphenated), true, 'hyphenated test vehicle is removed')

    -- item-key mode leaves core's virtual map empty, then survives persist/store/spawnRecord.
    local itemNetId = V.spawn({ model = 'adder', coords = vector3(20.0, 20.0, 20.0), ownerSrc = 1, keyMode = 'item' })
    check(math.type(itemNetId) == 'integer', 'item-key mode spawns')
    local itemEntity = V.getEntity(itemNetId)
    local itemState = stubs.entityState(env, itemEntity)
    eq(itemState.keyMode, 'item', 'item-key mode is replicated')
    eq(itemState.keys[charId], nil, 'item-key mode does not create a virtual owner key')
    eq(V.hasKeys(1, itemNetId), false, 'item-key owner is not accepted by the core virtual lock route')
    local itemVehId = V.persist(itemNetId)
    eq(V.getRecord(itemVehId).meta.keyMode, 'item', 'item-key mode is persisted')
    eq(V.store(itemNetId), true, 'an item-key vehicle stores')
    local itemRespawned = V.spawnRecord(itemVehId, vector3(21.0, 21.0, 21.0), 0.0, 1)
    check(math.type(itemRespawned) == 'integer', 'an item-key vehicle respawns')
    eq(V.getInfo(itemRespawned).keyMode, 'item', 'item-key mode is restored')
    eq(V.hasKeys(1, itemRespawned), false, 'restored item-key vehicle still has no virtual key')
    eq(V.delete(itemRespawned), true, 'item-key test entity is removed')
    eq(V.deleteRecord(itemVehId), true, 'item-key test record is removed')
    deletedHook = {} -- isolate the existing record lifecycle assertion below

    -- keys
    eq(V.hasKeys(1, netId), true, 'the owner holds the keys')
    eq(V.hasKeys(2, netId), false, 'a src without a session holds nothing')
    eq(V.hasKeys(1, netId2), false, 'no keys for an unowned vehicle')
    eq(V.giveKeys(netId2, charId), true, 'giveKeys')
    eq(V.hasKeys(1, netId2), true, 'the key grants access')
    eq(stubs.entityState(env, V.getEntity(netId2)).keys[charId], true, 'the keys state bag followed')
    eq(V.removeKeys(netId2, charId), true, 'removeKeys')
    eq(V.hasKeys(1, netId2), false, 'the key is gone')
    eq(V.giveKeys(netId2, 42), false, 'giveKeys validates the charId')
    eq(V.giveKeys(netId2, 'bad id'), false, 'giveKeys refuses a malformed charId')
    eq(V.giveKeys(999999, charId), false, 'giveKeys on an untracked netId')
    eq(V.setOwner(netId2, charId), true, 'setOwner')
    eq(V.getOwner(netId2), charId, 'getOwner')
    eq(V.hasKeys(1, netId2), true, 'the new owner holds the keys')
    eq(#V.getPlayerVehicles(1), 2, 'getPlayerVehicles lists both')
    eq(V.setOwner(netId2, nil), true, 'setOwner accepts nil to clear the owner')
    eq(V.getOwner(netId2), nil, 'the vehicle is unowned again')
    eq(stubs.entityState(env, V.getEntity(netId2)).owner, false, 'the owner state key is false again')
    -- keys follow ownership: setOwner(netId, nil) drops the owner AND the key that came with ownership
    eq(V.hasKeys(1, netId2), false, 'clearing the owner revokes the key that came with it')
    eq(V.removeKeys(netId2, charId), true, 'the key has to be taken back explicitly')
    eq(V.hasKeys(1, netId2), false, 'now the vehicle is truly out of reach')

    -- entityOf: untracked ids never resolve
    eq(V.getEntity(netId + 5000), 0, 'an untracked netId resolves to entity 0')
    eq(V.getEntity('nope'), 0, 'a non-integer netId resolves to 0')
    eq(V.getEntity(1.5), 0, 'a fractional netId resolves to 0')
    eq(V.exists(netId + 5000), false, 'exists is false for an untracked netId')
    eq(V.getInfo(netId + 5000), nil, 'getInfo of an untracked netId is nil')
    local foreign = stubs.newEntity(2, { model = 1 })
    eq(V.getEntity(stubs.entities[foreign].netId), 0, "another resource's vehicle is not reachable")
    eq(V.setLocked(stubs.entities[foreign].netId, true), false, 'and cannot be locked through the API')

    -- core:server:vehicleLock through the Core.Net wrapper (DESIGN §5)
    stubs.clear()
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId)
    eq(V.isLocked(netId), false, 'the lock toggled off')
    eq(stubs.entities[entity].lockState, 1, 'SetVehicleDoorsLocked got state 1')
    eq(stubs.entityState(env, entity).locked, false, 'the locked state key followed')
    eq((lastSent('core:client:notify') or {}).target, 1, 'only the caller is notified')
    eq(lastSent('core:client:notify').args[1].message, Core.Config.Texts.unlocked, 'the unlock message')
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId)
    eq(V.isLocked(netId), false, 'the 500 ms cooldown blocks an immediate repeat')

    stubs.tick(600)
    stubs.coords[ped] = vector3(1000.0, 1000.0, 20.0)
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId)
    eq(V.isLocked(netId), false, 'a player beyond LockDistance is refused')
    stubs.tick(600)
    stubs.coords[ped] = vector3(100.0, 100.0, 20.0)
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId)
    eq(V.isLocked(netId), true, 'back in range the lock toggles again')

    stubs.tick(600)
    stubs.clear()
    stubs.coords[ped] = vector3(1.0, 1.0, 0.0)               -- next to the unowned vehicle
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId2)
    eq(V.isLocked(netId2), false, 'a vehicle the player has no keys for stays unlocked')
    eq(lastSent('core:client:notify').args[1].message, Core.Config.Texts.no_keys, 'the refusal is notified')
    stubs.tick(600)
    stubs.clear()
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, netId + 5000)
    eq(lastSent('core:client:notify'), nil, 'an untracked netId is dropped silently')
    stubs.tick(600)
    stubs.triggerOn(env, 'core:server:vehicleLock', 1, 'nope')
    eq(lastSent('core:client:notify'), nil, 'a payload that fails the schema is dropped')
    stubs.coords[ped] = vector3(100.0, 100.0, 20.0)

    -- records: persist, store, spawnRecord and the double-spawn refusal
    local vehId = V.persist(netId)
    check(type(vehId) == 'string', 'persist creates the vehicles record')
    eq(stubs.entityState(env, entity).vehId, vehId, 'the vehId state key was written')
    eq(V.persist(netId), vehId, 'persist is idempotent')
    eq(V.persist(netId + 5000), nil, 'persist of an untracked netId is nil')
    eq(V.getRecord(vehId).plate, 'LSTEST1', 'the record carries the plate')
    eq(V.getRecord(vehId).stored, false, 'a freshly persisted vehicle is not stored')
    eq(V.getRecord(vehId).meta.vehType, 'automobile', 'the record remembers the vehicle type')
    eq(#V.getRecords(charId), 1, 'getRecords finds the owner records')
    eq(#V.getRecords('no-such-char'), 0, 'getRecords of a stranger is empty')
    eq(errOf(V.spawnRecord(vehId, vector3(5.0, 5.0, 5.0))), 'already_spawned',
        'a record already in the world cannot be spawned again')
    eq(errOf(V.spawnRecord('nope', vector3(0, 0, 0))), 'no_record', 'an unknown record is refused')

    eq(V.store(netId), true, 'store writes the record and removes the entity')
    eq(V.exists(netId), false, 'the vehicle left the world')
    eq(V.getRecord(vehId).stored, true, 'the record is marked stored')
    eq(V.getRecord(vehId).position.x, 100.0, 'the last position was written')
    eq(#deletedHook, 1, 'store emitted vehicleDeleted')
    eq(errOf(V.spawn({ model = 'adder', coords = vector3(9.0, 9.0, 9.0), plate = 'LSTEST1' })), 'plate_taken',
        'a stored record reserves its plate globally')
    eq(errOf(V.restoreRecord(vehId)), 'record_stored', 'world restore refuses a deliberately garaged record')

    local respawned = V.spawnRecord(vehId, vector3(5.0, 5.0, 5.0), 10.0, 1)
    check(math.type(respawned) == 'integer', 'spawnRecord brings the vehicle back')
    eq(V.getInfo(respawned).plate, 'LSTEST1', 'the plate was freed and reused')
    eq(V.getInfo(respawned).ownerCharId, charId, 'the owner was restored from the record')
    eq(V.getInfo(respawned).vehId, vehId, 'the live vehicle points back at its record')
    eq(V.getRecord(vehId).stored, false, 'the record is no longer stored')
    eq(errOf(V.spawnRecord(vehId, vector3(6.0, 6.0, 6.0))), 'already_spawned',
        'a second spawn of the same record is refused')

    -- props and delete
    eq(V.saveProps(respawned, { modEngine = 3, colour = 'red', extras = { 1, 2 }, on = true }), true,
        'saveProps accepts a well-formed props table')
    eq(V.getRecord(vehId).props.modEngine, 3, 'the props reached the record')
    eq(stubs.entityState(env, V.getEntity(respawned)).coreProps.colour, 'red',
        'changed saved props are projected for clients that stream later')
    local nativeMaps = {
        modEngine = 3, mods = { [0] = 3, ['1'] = 2 }, extras = { [0] = true, ['1'] = false },
        modToggles = { [17] = true }, burstTyres = { [0] = true }, tyreHealth = { [0] = 850.0 },
        doors = { [0] = true }, windows = { ['0'] = false }, lights = { true, false, 1 }, neonColor = { 10, 20, 30 },
    }
    eq(V.saveProps(respawned, nativeMaps), true, 'saveProps accepts zero-based and JSON-round-tripped native maps')
    eq(at(V.getRecord(vehId).props.mods, 0), 3, 'the zero-based mod survived')
    eq(at(V.getRecord(vehId).props.extras, 0), true, 'the zero-based extra survived')
    eq(at(V.getRecord(vehId).props.tyreHealth, 0), 850.0, 'wheel health survives the props validator')
    eq(at(V.getRecord(vehId).props.windows, 0), false, 'window condition survives JSON-safe props')
    -- review RV4 F1: every value is clamped to its native range and the props never rename the car
    eq(V.saveProps(respawned, { tankHealth = -1000.0, engineHealth = -4000.0, bodyHealth = 1500.0, fuelLevel = 250.0,
        dirtLevel = -3.0, colorPrimary = 999, colorSecondary = 7.6, windowTint = 42, wheels = -5, plateIndex = 99,
        xenonColor = 200, neonColor = { 300, -1, 20 }, customPrimary = true, mods = { [11] = 900, [12] = -9 },
        tyreHealth = { [0] = -5.0 }, lights = { true, false, 9 }, plate = 'HACKED', modEngine = 3 }), true,
        'saveProps takes out-of-range values ...')
    local clamped = V.getRecord(vehId).props
    eq(clamped.tankHealth, 0, '... a tank below 0 (a burning car) becomes 0')
    eq(clamped.engineHealth, 0, '... engine health 0..1000')
    eq(clamped.bodyHealth, 1000, '... body health at most 1000')
    eq(clamped.fuelLevel, 100, '... fuel 0..100')
    eq(clamped.dirtLevel, 0, '... dirt 0..15')
    eq(clamped.colorPrimary, 255, '... a paint index 0..255')
    eq(clamped.colorSecondary, 7, '... paint indexes are integers')
    eq(clamped.windowTint, 6, '... window tint -1..6')
    eq(clamped.wheels, 0, '... wheel type 0..12')
    eq(clamped.plateIndex, 12, '... plate style 0..12')
    eq(clamped.xenonColor, nil, '... a xenon colour outside 0..12 / 255 is dropped')
    eq(clamped.neonColor[1] .. ',' .. clamped.neonColor[2], '255,0', '... RGB 0..255')
    eq(clamped.customPrimary, nil, '... a custom colour that is neither false nor RGB is dropped')
    eq(at(clamped.mods, 11), 254, '... a mod index -1..254')
    eq(at(clamped.mods, 12), -1, '... (stock is -1)')
    eq(at(clamped.tyreHealth, 0), 0, '... wheel health 0..1000')
    eq(clamped.lights[3], 3, '... indicators 0..3')
    eq(clamped.plate, 'LSTEST1', '... and props.plate is always the car plate (never "HACKED")')
    eq(stubs.entityState(env, V.getEntity(respawned)).coreProps.plate, 'LSTEST1', 'the projected bag too')
    eq(V.saveProps(respawned, { [1] = 'no numeric keys' }), false, 'a numeric prop key is refused')
    eq(V.saveProps(respawned, { bad = { 'not a number' } }), false, 'a non-numeric array value is refused')
    eq(V.saveProps(respawned, { bad = print }), false, 'a function value is refused')
    eq(V.saveProps(respawned, 'nope'), false, 'a non-table is refused')
    eq(V.saveProps(netId + 5000, {}), false, 'saveProps on an untracked netId is refused')
    eq(V.getRecord(vehId).props.modEngine, 3, 'no refused props reached the record')

    eq(#V.list(), 2, 'list counts the live vehicles')
    eq(V.delete(respawned), true, 'delete removes a tracked vehicle')
    eq(V.getInfo(respawned), nil, 'the vehicle is untracked')
    eq(V.exists(respawned), false, 'and gone from the world')
    eq(V.delete(respawned), false, 'a second delete is false')
    eq(V.deleteRecord(vehId), true, 'deleteRecord removes the document')
    eq(V.getRecord(vehId), nil, 'the record is gone')
    eq(V.deleteRecord('nope'), false, 'deleteRecord of an unknown id is false')

    -- Core/server restart: a live persistent vehicle remains logically out and can be restored at its final position.
    local restartNetId = V.spawn({ model = 'adder', coords = vector3(77.0, 88.0, 20.0), ownerSrc = 1 })
    local restartVehId = V.persist(restartNetId)
    eq(V.saveProps(restartNetId, { colour = 'green' }), true, 'world vehicle props save before restart')
    stubs.triggerOn(env, 'onResourceStop', 0, Core.name)
    eq(V.getRecord(restartVehId).stored, false, 'core stop keeps a world vehicle out of the garage')
    eq(V.getRecord(restartVehId).position.x, 77.0, 'core stop saves final vehicle position')
    eq(V.exists(restartNetId), false, 'core stop deletes the live entity after storing it')
    local restoredNetId = V.restoreRecord(restartVehId)
    check(math.type(restoredNetId) == 'integer', 'an out record restores into the world')
    eq(stubs.coords[V.getEntity(restoredNetId)].x, 77.0, 'world restore uses the saved record position')
    eq(V.getInfo(restoredNetId).vehId, restartVehId, 'restored world entity keeps its unique vehicle id')
    eq(stubs.entityState(env, V.getEntity(restoredNetId)).coreProps.colour, 'green',
        'world restore projects props for whichever client streams it')
    eq(V.delete(restoredNetId), true, 'restored world test entity is removed')
    -- review RV6 F2: an out record with nothing in the world (a restart without the scene, a deleted car) is not
    -- 'already_spawned' for ever — the garage spawns it; a live one still refuses
    eq(V.getRecord(restartVehId).stored, false, 'the deleted car left its record out ...')
    local fromGarage, garageErr = V.spawnRecord(restartVehId, vector3(78.0, 88.0, 20.0), 0.0, 1)
    check(math.type(fromGarage) == 'integer', 'RV6 F2: ... and spawnRecord brings it back', tostring(garageErr))
    eq(errOf(V.spawnRecord(restartVehId, vector3(78.0, 88.0, 20.0))), 'already_spawned', 'while it is live: refused')
    eq(V.delete(fromGarage), true, 'garage test entity is removed')
    -- a record the scene marked destroyed (a wrecked parked clone, §55.21.4 D-C) is never restored into the world;
    -- a garage spawn brings it back and clears the mark
    sql('UPDATE vehicles SET destroyed = true WHERE id = $1', { restartVehId })   -- (behind core's back)
    eq(errOf(V.restoreRecord(restartVehId)), 'destroyed', 'restoreRecord refuses a wreck')
    local rebuilt = V.spawnRecord(restartVehId, vector3(79.0, 88.0, 20.0), 0.0, 1)
    check(math.type(rebuilt) == 'integer', 'spawnRecord brings a wreck back')
    eq(V.getRecord(restartVehId).destroyed, false, '... and clears the mark')
    eq(V.delete(rebuilt), true, 'rebuilt test entity is removed')
    -- the record's keys, lock and bucket come back with it (review RV4 F13 / F6)
    sql([[UPDATE vehicles SET keys = ARRAY['friend-7'], locked = true,
        position = '{"x":80.0,"y":88.0,"z":20.0,"heading":0.0,"bucket":6}' WHERE id = $1]], { restartVehId })
    local keyed = V.restoreRecord(restartVehId)
    eq(V.getInfo(keyed).keys['friend-7'], true, 'a restored car carries the record keys')
    eq(V.getInfo(keyed).locked, true, '... its lock')
    eq(stubs.entities[V.getEntity(keyed)].bucket, 6, '... and its bucket')
    eq(V.getInfoByRecord(restartVehId).position.bucket, 6, 'positionOf reports the bucket')
    eq(V.delete(keyed), true, 'keyed test entity is removed')

    -- A validated server plugin can adopt an existing ambient vehicle without trusting a client-created record.
    local ambient = stubs.newEntity(2, { model = env.GetHashKey('blista'), vehType = 'automobile', plate = 'NPC123' })
    stubs.coords[ambient], stubs.headings[ambient] = vector3(31.0, 32.0, 33.0), 123.0
    local ambientNetId = env.NetworkGetNetworkIdFromEntity(ambient)
    local adoptedVehId = V.adopt(ambientNetId, {
        ownerSrc = 1, keyMode = 'item', locked = false, props = { colour = 'blue' },
    })
    check(type(adoptedVehId) == 'string', 'an ambient network vehicle can be adopted persistently')
    eq(V.getInfo(ambientNetId).vehId, adoptedVehId, 'adoption tracks the ambient net id under its new vehId')
    eq(V.getInfo(ambientNetId).keyMode, 'item', 'adoption keeps physical-key mode')
    eq(V.getRecord(adoptedVehId).position.x, 31.0, 'adoption persists the ambient world position')
    eq(stubs.entities[ambient].orphanMode, 2, 'adoption makes the ambient entity server-persistent')
    eq(stubs.entityState(env, ambient).coreProps.colour, 'blue', 'adoption projects trusted initial props')
    eq(errOf(V.adopt(ambientNetId, { ownerSrc = 1 })), 'already_tracked', 'the same ambient entity cannot be adopted twice')
    eq(V.delete(ambientNetId), true, 'adopted ambient test entity is removed')
    eq(V.deleteRecord(adoptedVehId), true, 'adopted ambient test record is removed')
    -- review RV4 F8: a Core.Scene clone (state sn: a map / plugin vehicle node's promoted entity) is not adoptable —
    -- the scene deletes it at its demotion and the record would be orphaned / duplicated
    local sceneClone = stubs.newEntity(2, { model = env.GetHashKey('adder'), vehType = 'automobile', plate = 'MAP1' })
    stubs.coords[sceneClone] = vector3(40.0, 40.0, 20.0)
    stubs.entityState(env, sceneClone).sn = 77
    local recordsBefore = scalar('SELECT count(*) FROM vehicles')
    eq(errOf(V.adopt(env.NetworkGetNetworkIdFromEntity(sceneClone), { ownerSrc = 1 })), 'scene_clone',
        'RV4 F8: adopt refuses a scene clone')
    eq(V.getInfo(env.NetworkGetNetworkIdFromEntity(sceneClone)), nil, '... it is not tracked')
    eq(scalar('SELECT count(*) FROM vehicles'), recordsBefore, '... and no record is created')
    eq(stubs.entities[sceneClone].plate, 'MAP1', '... nor its plate touched')

    -- §55.21.4 without Core.Scene (tests/scene_parked_tests.lua covers parking): the §4.6 behaviour stays
    local parkNetId = V.spawn({ model = 'Adder', coords = vector3(60.0, 60.0, 20.0), ownerSrc = 1 })
    local parkVehId = V.persist(parkNetId)
    eq(V.getRecord(parkVehId).modelName, 'adder', 'persist keeps the model name the vehicle was spawned by')
    eq(V.getInfo(parkNetId).parked, nil, 'a normal vehicle is no parked clone')
    eq(errOf(V.park(parkNetId)), 'unavailable', 'park needs Core.Scene')
    eq(V.getInfoByRecord(parkVehId).netId, parkNetId, 'getInfoByRecord answers a live vehicle')
    eq(V.store(parkVehId), true, 'store takes a vehId too')
    eq(V.exists(parkNetId), false, 'the live vehicle of that record left')
    eq(V.getInfoByRecord(parkVehId).stored, true, 'getInfoByRecord answers a garaged record')
    local parkBack = V.spawnRecord(parkVehId, vector3(61.0, 61.0, 20.0))
    eq(stubs.entities[V.getEntity(parkBack)].model, env.GetHashKey('adder'), 'spawnRecord spawns by the model name')
    eq(V.delete(parkBack), true, 'parking test entity is removed')
    eq(V.deleteRecord(parkVehId), true, 'parking test record is removed')

    -- §56 port (DESIGN §56.6 `vehicles`): plates by the UNIQUE index, the owner index, queued patches of only the
    -- changed columns (never `meta`), a stop that only queues
    local log, clearLog, restoreSpy = H.spyDB(env)
    local function calls(fn, pred)
        local n = 0
        for _, c in ipairs(log) do if c.fn == fn and (not pred or pred(c)) then n = n + 1 end end
        return n
    end
    local function crudOn(op) return function(c) return c.args[1] == op and c.args[2] == 'vehicles' end end
    clearLog()
    local randomNet = V.spawn({ model = 'adder', coords = vector3(200.0, 0.0, 20.0) })
    local q
    for _, c in ipairs(log) do if c.fn == 'query' then q = c end end
    check(math.type(randomNet) == 'integer', 'a random-plate spawn')
    eq(calls('query'), 1, 'a random plate costs ONE query')
    check(q and q.args[1]:find('plate = ANY', 1, true) ~= nil, '... plate = ANY($1) (the UNIQUE index)',
        q and q.args[1])
    check(q and type(q.args[2][1]) == 'table' and #q.args[2][1] >= 1, '... over a batch of candidates')
    eq(calls('crud', crudOn('select')) + calls('crud', crudOn('first')), 0, '... and never a scan or a per-try read')
    clearLog()
    local explicitNet = V.spawn({ model = 'adder', coords = vector3(210.0, 0.0, 20.0), plate = 'IDX1' })
    eq(calls('crud', crudOn('first')), 1, 'an explicit plate: one indexed lookup')
    eq(calls('query'), 0, '... and nothing else')
    -- the UNIQUE plate index is the last guard: a core-chosen plate taken meanwhile is replaced, the insert retried
    local takenPlate = V.getInfo(randomNet).plate
    sql('INSERT INTO vehicles (id, model, plate) VALUES ($1, 1, $2)', { 'squatter1', takenPlate })
    clearLog()
    local collideVeh = V.persist(randomNet)
    check(type(collideVeh) == 'string', 'a plate collision at the insert retries: persist succeeds')
    eq(calls('crud', crudOn('insert')), 2, '... with a second insert')
    local newPlate = V.getInfo(randomNet).plate
    check(newPlate ~= takenPlate, '... and a new plate')
    eq(V.getRecord(collideVeh).plate, newPlate, '... the record carries it')
    eq(stubs.entities[V.getEntity(randomNet)].plate, newPlate, '... the entity')
    eq(stubs.entityState(env, V.getEntity(randomNet)).plate, newPlate, '... and the plate bag')
    sql('INSERT INTO vehicles (id, model, plate) VALUES ($1, 1, $2)', { 'squatter2', 'IDX1' })
    eq(V.persist(explicitNet), nil, 'a plate the caller asked for is never replaced: the persist fails')
    eq(V.getInfo(explicitNet).plate, 'IDX1', '... the car keeps it')
    -- the owner index
    local metaNet = V.spawn({ model = 'adder', coords = vector3(230.0, 0.0, 20.0), ownerSrc = 1 })
    local metaVeh = V.persist(metaNet)
    clearLog()
    local mine = V.getRecords(charId)
    local sel
    for _, c in ipairs(log) do if c.fn == 'crud' and c.args[1] == 'select' then sel = c end end
    eq(sel and sel.args[3].where and sel.args[3].where.owner_character_id, charId, 'getRecords: one select by owner')
    eq(sel and sel.args[3].sync, true, '... read-your-writes')
    eq(calls('crud') + calls('query'), 1, '... and nothing else')
    local found = false
    for _, r in ipairs(mine) do if r.id == metaVeh then found = r.ownerCharId == charId end end
    eq(found, true, '... it finds the new record with its owner')
    -- a plugin's meta key survives every write of core (they patch only their own columns)
    eq(V.setData(metaVeh, 'insurance', { tier = 2 }), true, 'a plugin key in meta (Vehicles.setData)')
    clearLog()
    V.saveProps(metaNet, { colorPrimary = 9 })
    V.setOwner(metaNet, charId)
    V.store(metaNet)
    V.setLocked(metaVeh, true)                                  -- garaged: the record itself
    V.giveKeys(metaVeh, 'friend-9')                             -- garaged, not mirrored: ONE queued statement
    V.removeKeys(metaVeh, 'friend-9')
    V.giveKeys(metaVeh, 'friend-8')
    V.setOwner(metaVeh, charId)
    local touchedMeta, statements = false, 0
    for _, c in ipairs(log) do
        for _, entry in ipairs(c.fn == 'enqueue' and c.args[1] or {}) do
            if entry.changes and entry.changes.meta ~= nil then touchedMeta = true end
            if entry.t == 'sql' then
                statements = statements + 1
                if entry.sql:find('meta%s*=') then touchedMeta = true end
            end
        end
    end
    eq(touchedMeta, false, 'no queued write of a record touches meta')
    eq(statements, 4, 'key / owner changes of a garaged record are single queued statements')
    local ins = V.getData(metaVeh, 'insurance')
    eq(ins and ins.tier, 2, "the plugin's meta key survived props, owner, store, lock and keys")
    eq(V.getData(metaVeh, 'keyMode'), 'virtual', "... and core's own meta keys too")
    local stored = V.getRecord(metaVeh)
    eq(stored.stored, true, 'store was written')
    eq(stored.locked, true, 'the garaged lock was written')
    eq(at(stored.props, 'colorPrimary'), 9, 'the props were written')
    local held = {}
    for _, k in ipairs(stored.keys) do held[k] = true end
    eq(held['friend-8'], true, 'giveKeys on a garaged record')
    eq(held['friend-9'], nil, 'removeKeys on a garaged record')
    eq(held[charId], true, 'setOwner kept the virtual owner key')
    -- review R3b #8: core's own meta keys are not Vehicles.setData's (the mirror of the world records holds them)
    eq(V.setData(metaVeh, 'keyMode', 'item'), false, "R3b #8: setData refuses core's keyMode")
    eq(V.setData(metaVeh, 'vehType', 'bike'), false, '... and vehType')
    eq(V.getData(metaVeh, 'keyMode'), 'virtual', '... which stay as persist wrote them')

    -- review R3b #1: keys, lock and owner of a PERSISTED car reach its record at once — a trade, then store, never
    -- leaves the seller a working key
    local function heldBy(vehId)
        local held = {}
        for _, k in ipairs(V.getRecord(vehId).keys) do held[k] = true end
        return held
    end
    stubs.connectPlayer(env, 2, { license = 'license:v2', name = 'Buyer', coords = vector3(300.0, 0.0, 20.0) })
    local buyerChar = Core.Player.getInfo(2).charId
    local tradeNet = V.spawn({ model = 'adder', coords = vector3(300.0, 0.0, 20.0), ownerSrc = 1, locked = true })
    local tradeVeh = V.persist(tradeNet)
    eq(heldBy(tradeVeh)[charId], true, 'R3b #1: persist writes the keys (the owner key)')
    eq(V.getRecord(tradeVeh).locked, true, '... and the lock')
    eq(V.setLocked(tradeNet, false), true, 'setLocked(netId) of a persisted car')
    eq(V.getRecord(tradeVeh).locked, false, '... reaches its record at once')
    eq(V.giveKeys(tradeNet, 'friend-3'), true, 'giveKeys(netId)')
    eq(heldBy(tradeVeh)['friend-3'], true, '... reaches its record at once')
    eq(V.setOwner(tradeNet, buyerChar), true, 'the seller sells (setOwner(netId))')
    local held = heldBy(tradeVeh)
    eq(held[charId], nil, "... the seller's key left the record")
    eq(held[buyerChar], true, "... the buyer's is in it")
    eq(V.getRecord(tradeVeh).ownerCharId, buyerChar, '... with the owner')
    eq(V.removeKeys(tradeNet, 'friend-3'), true, 'removeKeys(netId)')
    eq(heldBy(tradeVeh)['friend-3'], nil, '... reaches its record at once')
    eq(V.store(tradeNet), true, 'stored')
    local back = V.spawnRecord(tradeVeh, vector3(301.0, 0.0, 20.0), 0.0, 2)
    eq(V.hasKeys(1, back), false, "after the trade and a garage spawn the seller holds no key")
    eq(V.hasKeys(2, back), true, '... the buyer does')
    eq(V.delete(back), true, 'trade test car removed')

    -- review R3b #2: a new owner must be a character: a queued owner patch failing the FK at COMMIT would drop every
    -- change merged into the row's entry (here: the store in the same slice)
    local ghostNet = V.spawn({ model = 'adder', coords = vector3(310.0, 0.0, 20.0), ownerSrc = 1 })
    local ghostVeh = V.persist(ghostNet)
    clearLog()
    V.saveProps(ghostNet, { colorPrimary = 12 })
    eq(V.setOwner(ghostNet, 'ghost-char'), false, 'R3b #2: setOwner refuses a charId without a character')
    eq(V.getOwner(ghostNet), charId, '... the owner stays')
    eq(V.store(ghostNet), true, '... and a store queued in the same slice ...')
    local ghostRow = V.getRecord(ghostVeh)
    eq(ghostRow.stored, true, '... lands')
    eq(at(ghostRow.props, 'colorPrimary'), 12, '... with the props merged into it')
    local ghostWrites = 0
    for _, c in ipairs(log) do
        for _, entry in ipairs(c.fn == 'enqueue' and c.args[1] or {}) do
            if entry.changes and entry.changes.owner_character_id == 'ghost-char' then ghostWrites = ghostWrites + 1 end
        end
    end
    eq(ghostWrites, 0, '... no queued write names the unknown character')
    eq(V.setOwner(ghostVeh, 'ghost-char'), false, 'setOwner(vehId) of a garaged record refuses it too')
    eq(V.setOwner(ghostVeh, buyerChar), true, '... and takes a real character (not online: one read)')

    -- review R3b #4: the plate is chosen BEFORE the entity exists; a failed random-plate read is accepted; a garage
    -- spawn reads no plate (its record owns its plate under the UNIQUE index)
    local realCreate, createdAt = env.CreateVehicleServerSetter, nil
    env.CreateVehicleServerSetter = function(...)
        createdAt = #log
        return realCreate(...)
    end
    clearLog()
    local ordered = V.spawn({ model = 'adder', coords = vector3(320.0, 0.0, 20.0) })
    local plateAt
    for i, c in ipairs(log) do if c.fn == 'query' and not plateAt then plateAt = i end end
    check(plateAt ~= nil and createdAt ~= nil and plateAt <= createdAt, 'R3b #4: the plate query runs before the entity')
    H.bridge.fail('plate = ANY')
    local downNet = V.spawn({ model = 'adder', coords = vector3(321.0, 0.0, 20.0) })
    H.bridge.unfail()
    check(math.type(downNet) == 'integer', '... a failed random-plate read never fails the spawn')
    local function entityCount()
        local n = 0
        for _ in pairs(stubs.entities) do n = n + 1 end
        return n
    end
    local entitiesBefore = entityCount()
    H.bridge.fail('WHERE "plate"')
    local refused, refusedErr = V.spawn({ model = 'adder', coords = vector3(322.0, 0.0, 20.0), plate = 'DOWN1' })
    H.bridge.unfail()
    eq(refused, nil, 'an asked-for plate whose check failed is refused')
    eq(refusedErr, 'db', "... with 'db'")
    eq(entityCount(), entitiesBefore, '... and no entity was created (none leaks)')
    env.CreateVehicleServerSetter = realCreate
    V.delete(ordered)
    V.delete(downNet)
    local garageVeh = V.persist(V.spawn({ model = 'adder', coords = vector3(323.0, 0.0, 20.0) }))
    V.store(garageVeh)
    clearLog()
    local fromGarage2 = V.spawnRecord(garageVeh, vector3(324.0, 0.0, 20.0), 0.0)
    check(math.type(fromGarage2) == 'integer', 'a garage spawn')
    eq(calls('query') + calls('crud', function(c) return c.args[1] == 'first' and c.args[3].where
        and c.args[3].where.plate ~= nil end), 0, '... reads no plate')
    V.delete(fromGarage2)

    -- review R3b #7: a read that a write of this module raced (no mirror entry holds the change) is read again
    local racedVeh = ghostVeh                                   -- garaged, so not mirrored
    local current = rawget(env.exports, 'core_db')
    local armed = false
    rawset(env.exports, 'core_db', setmetatable({ synchronous = true }, { __index = function(t, name)
        local f = function(_, ...)
            local a = table.pack(...)
            if name == 'crud' and armed and a[1] == 'first' and a[2] == 'vehicles' and a[3].where
                and a[3].where.id == racedVeh then
                armed = false
                local cb, got = a[a.n], nil
                a[a.n] = function(...) got = table.pack(...) end
                local ret = current[name](current, table.unpack(a, 1, a.n))
                V.setLocked(racedVeh, false)                    -- a write of the module while the read was out
                cb(table.unpack(got, 1, got.n))
                return ret
            end
            return current[name](current, ...)
        end
        rawset(t, name, f)
        return f
    end }))
    V.setLocked(racedVeh, true)
    armed = true                                                -- the next read of the record is raced
    local racedRecord = V.getRecord(racedVeh)
    rawset(env.exports, 'core_db', current)
    eq(armed, false, 'R3b #7: (the read was raced)')
    eq(racedRecord and racedRecord.locked, false, '... and read again: the answer has the racing write')

    -- review R3b #10: core:vehicles:mine sends the client a projection of its records
    stubs.tick(1100)
    stubs.clear()
    stubs.triggerOn(env, 'core:cb:req:core:vehicles:mine', 1, 'k:mine')
    stubs.tick(0)
    local res = lastSent('core:cb:res:core:vehicles:mine')
    local list = res and res.args[3] or {}
    check(#list >= 1, 'R3b #10: the callback answers the records')
    local leaked, parkedBool = false, true
    for _, r in ipairs(list) do
        if r.props ~= nil or r.meta ~= nil or r.keys ~= nil or r.ownerCharId ~= nil then leaked = true end
        if type(r.parked) ~= 'boolean' or type(r.id) ~= 'string' or type(r.plate) ~= 'string' then parkedBool = false end
    end
    eq(leaked, false, '... without props, meta, keys or owner')
    eq(parkedBool, true, '... id, plate and parked as a boolean')

    -- core stops: every record write is QUEUED (an awaited call never returns in a stopping resource)
    local stopNet = V.spawn({ model = 'adder', coords = vector3(240.0, 0.0, 20.0), ownerSrc = 1 })
    local stopVeh = V.persist(stopNet)
    V.saveProps(stopNet, { colorPrimary = 11 })
    stubs.coords[V.getEntity(stopNet)] = vector3(245.0, 1.0, 20.0)
    clearLog()
    stubs.triggerOn(env, 'onResourceStop', 0, Core.name)
    eq(calls('crud') + calls('query') + calls('sync') + calls('txBegin') + calls('batch'), 0,
        'core stop: no awaited database call')
    check(calls('enqueue') >= 1, '... only queued writes')
    restoreSpy()
    eq(V.getRecord(stopVeh).position.x, 245.0, '... and they landed (the final position)')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

    return suiteVehicles
end
