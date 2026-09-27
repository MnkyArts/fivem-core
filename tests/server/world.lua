return function(H)
    local check, eq, newServer, printed, stubs, suite, vector3 =
        H.check, H.eq, H.newServer, H.printed, H.stubs, H.suite, H.vector3

--- A core VM with the world modules this suite covers (the harness loads the session modules only).
local function worldServer()
    local env, Core = newServer()
    stubs.loadFile(env, 'server/doors.lua')
    stubs.loadFile(env, 'server/environment.lua')
    stubs.triggerOn(env, 'onResourceStart', 0, 'core')
    return env, Core
end

local function stop(env)
    stubs.triggerOn(env, 'onResourceStop', 0, 'core')
end

--- The core_db calls of a spy log, per export name; `enqueue` entries counted per table.
local function tally(log)
    local calls, tables = {}, {}
    for i = 1, #log do
        local call = log[i]
        calls[call.fn] = (calls[call.fn] or 0) + 1
        if call.fn == 'enqueue' and type(call.args[1]) == 'table' then
            for _, entry in ipairs(call.args[1]) do
                if entry.table then tables[entry.table] = (tables[entry.table] or 0) + 1 end
            end
        end
    end
    return calls, tables
end

local function doorRow(id)
    return H.sql('SELECT model, locked, perms, auto_lock_ms, coords FROM doors WHERE id = $1', { id })[1]
end

--- Core.Doors on the `doors` table (DESIGN §16, §56): the stored lock state wins over a restart and a
--- re-register, registers are served from memory, lock changes are one queued patch, and a door registered
--- before the load landed is merged when it does.
local function suiteDoors()
    suite('world: doors')
    stubs.resetServer()
    local env, Core = worldServer()
    local Doors = Core.Doors
    local gate = { id = 'gate', model = 12345, coords = vector3(10.0, 20.5, 30.25), locked = true,
        perms = { 'core.admin' }, autoLockMs = 0 }

    eq(Doors.register(gate), 'gate', 'a door registers')
    local row = doorRow('gate')
    check(row ~= nil, 'the row was written')
    eq(row and row.locked, true, '... with its lock state')
    eq(row and row.model, 12345, '... its model')
    eq(row and row.coords and row.coords.y, 20.5, '... its coords')
    eq(row and row.perms and row.perms[1], 'core.admin', '... and its perms (text[])')

    eq(Doors.setLocked('gate', false), true, 'unlock')
    eq(doorRow('gate').locked, false, 'the lock change reached the row')

    -- re-registering an unchanged door costs nothing; a lock change is one queued write, never a read
    local log, clear, restore = H.spyDB(env)
    for _ = 1, 20 do Doors.register(gate) end
    local calls = tally(log)
    eq(next(calls), nil, 'twenty re-registers of an unchanged door touch core_db zero times')
    eq(Doors.get('gate').locked, false, 'a re-register keeps the stored lock state (memory, not a query)')
    clear()
    for i = 1, 5 do
        Doors.register({ id = 'cell' .. i, model = 777, coords = vector3(i * 1.0, 0.0, 0.0), locked = false })
    end
    local registerCalls, registerTables = tally(log)
    eq(registerCalls.enqueue, 5, 'five new doors: five queued saves')
    eq(registerCalls.crud, nil, 'and not one helper read')
    eq(registerCalls.query, nil, 'nor one query')
    eq(registerTables.doors, 5, 'every queued write is a doors row')
    clear()
    eq(Doors.setLocked('cell1', true), true, 'lock a cell')
    calls = tally(log)
    eq(calls.enqueue, 1, 'a lock change is one queued write')
    eq(log[1] and log[1].args[1][1].t, 'patch', '... a patch')
    restore()
    eq(doorRow('cell1').locked, true, 'the patch landed')
    eq(Doors.unregister('cell2'), true, 'unregister keeps the row')
    eq(H.scalar("SELECT count(*) FROM doors WHERE id = 'cell2'"), 1, 'the row of an unregistered door stays')

    -- restart: every stored row is a runtime door again, before any plugin registers it
    stop(env)
    local env2, Core2 = worldServer()
    local D2 = Core2.Doors
    eq(D2.get('gate') and D2.get('gate').locked, false, 'the unlocked gate survived the restart')
    eq(D2.get('cell1') and D2.get('cell1').locked, true, 'the locked cell survived the restart')
    eq(D2.get('cell2') ~= nil, true, 'an unregistered but stored door is restored as well (as before)')
    eq(D2.get('gate').coords.z, 30.25, 'coords come back')
    eq(D2.get('gate').perms[1], 'core.admin', 'perms come back')
    local log2, _, restore2 = H.spyDB(env2)
    D2.register(gate)
    eq(next((tally(log2))), nil, 'the owner re-registering after the restart writes nothing')
    restore2()
    eq(D2.get('gate').locked, false, 'the stored lock state beats opts.locked = true')

    -- a door registered before the rows landed takes the stored lock when they do and is saved then
    stop(env2)
    H.bridge.fail('SELECT %* FROM "doors"', 'XX000 simulated read failure')
    local env3, Core3 = worldServer()
    local D3 = Core3.Doors
    check(printed('could not load the doors') ~= nil, 'the failed load is logged')
    D3.register(gate)
    eq(D3.get('gate').locked, true, 'before the load the door runs on opts.locked')
    D3.register({ id = 'shed', model = 999, coords = vector3(1.0, 2.0, 3.0), locked = true })
    eq(D3.setLocked('shed', false), true, 'a lock change before the load')
    eq(doorRow('gate').locked, false, 'nothing overwrote the stored gate while the load failed')
    eq(doorRow('shed'), nil, 'and nothing was written for the new door yet')
    H.bridge.unfail()
    stubs.tick(1100)
    eq(D3.get('gate').locked, false, 'the load merged the stored lock into the early door')
    eq(D3.get('cell1') ~= nil, true, 'and restored the other stored doors')
    eq(doorRow('shed') and doorRow('shed').locked, false, 'the early door was saved with its own lock change')
    stop(env3)
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

local function worldRow()
    return H.sql('SELECT day_seconds, weather, frozen, cycle_index, cycle_minutes_left FROM world_state WHERE id = 1')[1]
end

--- Core.World on `world_state` (DESIGN §17, §56): explicit changes are saved at once, the running clock at most
--- once per real minute, the stop saves the rest, a restart resumes, and a row that cannot be read is never
--- overwritten by the defaults.
local function suiteEnvironment()
    suite('world: environment')
    stubs.resetServer()
    local env, Core = worldServer()
    local World = Core.World
    local h, m = World.getTime()
    eq(h * 60 + m, 12 * 60, 'a fresh world starts at Config.World.StartTime')
    local row = worldRow()
    eq(row and row.day_seconds, 43200, 'the first start writes the row')
    eq(row and row.weather, 'CLEAR', '... with the default weather')

    eq(World.setTime(7, 30), true, 'setTime')
    eq(worldRow().day_seconds, 7 * 3600 + 30 * 60, 'an explicit time change is saved at once')
    eq(World.setWeather('RAIN'), true, 'setWeather')
    eq(worldRow().weather, 'RAIN', 'an explicit weather change is saved at once')
    eq(World.freezeTime(true), true, 'freeze')
    eq(worldRow().frozen, true, 'the freeze is saved at once')
    eq(World.freezeTime(false), true, 'unfreeze')

    -- the running clock: GlobalState per game minute, the row at most once per real minute
    local log, clear, restore = H.spyDB(env)
    clear()
    stubs.tick(10000)
    local _, tables = tally(log)
    eq(tables.world_state, nil, 'ten real seconds (five game minutes) write no world row')
    h, m = World.getTime()
    eq(env.GlobalState['core:time'].m, m, 'GlobalState follows every game minute')
    stubs.tick(52000)
    _, tables = tally(log)
    eq(tables.world_state, 1, 'a real minute of running clock is one save')
    restore()
    local saved = worldRow().day_seconds
    check(saved > 7 * 3600 + 30 * 60, 'the saved clock moved on', tostring(saved))

    -- stop saves the rest; a restart resumes time, weather and freeze
    stubs.tick(4000)
    local stopH, stopM = World.getTime()
    stop(env)
    eq(worldRow().day_seconds // 60, stopH * 60 + stopM, 'the stop saved the clock to the minute')
    local env2, Core2 = worldServer()
    local W2 = Core2.World
    local h2, m2 = W2.getTime()
    eq(h2 * 60 + m2, stopH * 60 + stopM, 'the restart resumed the clock')
    eq(W2.getWeather(), 'RAIN', 'the restart resumed the weather')
    eq(env2.GlobalState['core:weather'].type, 'RAIN', 'and published it')
    W2.freezeTime(true)
    stop(env2)

    -- a row that cannot be read: defaults run, the row is kept, a later read adopts it
    local before = worldRow()
    H.bridge.fail('FROM "world_state" WHERE', 'XX000 simulated read failure')
    local env3, Core3 = worldServer()
    local W3 = Core3.World
    check(printed('the world state could not be read') ~= nil, 'the failed read is logged')
    eq(W3.getWeather(), 'CLEAR', 'the defaults run while the row cannot be read')
    stubs.tick(70000)
    local kept = worldRow()
    eq(kept.day_seconds, before.day_seconds, 'a minute of running clock did not overwrite the stored time')
    eq(kept.weather, 'RAIN', '... nor the stored weather')
    H.bridge.unfail()
    stubs.tick(15000)
    eq(W3.getWeather(), 'RAIN', 'the re-read adopted the stored weather')
    eq(W3.isTimeFrozen(), true, '... and the stored freeze')
    local h3, m3 = W3.getTime()
    eq(h3 * 3600 + m3 * 60, before.day_seconds - before.day_seconds % 60, '... and the stored clock')
    stop(env3)

    -- an explicit change while the row cannot be read wins over the late read
    H.bridge.fail('FROM "world_state" WHERE', 'XX000 simulated read failure')
    local env4, Core4 = worldServer()
    local W4 = Core4.World
    eq(W4.setWeather('SNOW'), true, 'an admin sets the weather while the row cannot be read')
    eq(worldRow().weather, 'SNOW', 'the explicit change is saved')
    H.bridge.unfail()
    stubs.tick(16000)
    eq(W4.getWeather(), 'SNOW', 'the late read did not replace the explicit change')
    stop(env4)

    -- R3a-7: an explicit change while the START read is out keeps only that field; clock + freeze come from the row
    H.sql("UPDATE world_state SET day_seconds = 18000, weather = 'RAIN', frozen = true WHERE id = 1")
    local env5, Core5 = newServer()
    stubs.loadFile(env5, 'server/environment.lua')
    local W5 = Core5.World
    local real = rawget(env5.exports, 'core_db')
    local hooked = false
    rawset(env5.exports, 'core_db', setmetatable({ synchronous = rawget(real, 'synchronous') }, {
        __index = function(_, name)
            return function(_, ...)
                local op, tbl = ...
                if not hooked and name == 'crud' and op == 'first' and tbl == 'world_state' then
                    hooked = true
                    W5.setWeather('THUNDER')          -- an admin, while the read is out
                end
                return real[name](real, ...)
            end
        end,
    }))
    stubs.triggerOn(env5, 'onResourceStart', 0, 'core')
    rawset(env5.exports, 'core_db', real)
    eq(hooked, true, 'the weather changed while the start read was out')
    local h5, m5 = W5.getTime()
    eq(h5 * 3600 + m5 * 60, 18000, 'the stored clock was adopted anyway')
    eq(W5.isTimeFrozen(), true, 'and the stored freeze')
    eq(W5.getWeather(), 'THUNDER', 'the explicit weather was re-applied over the row')
    local merged = worldRow()
    eq(merged.day_seconds, 18000, 'the saved row keeps the stored clock')
    eq(merged.weather, 'THUNDER', 'and carries the explicit weather')
    stop(env5)
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

    return function()
        suiteDoors()
        suiteEnvironment()
    end
end
