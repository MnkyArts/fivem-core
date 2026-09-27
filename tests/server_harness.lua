--[[
    core/tests/server_harness.lua — shared harness for the server_tests.lua suites.

    Everything server_tests.lua's suites (tests/server/*.lua) share: the stubs, the
    assertion helpers, the shared pass/fail counters and newServer(). Returns a table `H`
    with every helper a suite file needs; suites bind the ones they use to locals at the
    top of their own file (`local check, eq = H.check, H.eq`).

    Same harness as run_tests.lua: every native and runtime helper comes from tests/stubs.lua,
    so this proves the pure Lua contracts of DESIGN §4, §5 and §8 — never in-game behaviour.
    One server VM per suite: import.lua, shared/config.lua, then the server modules in manifest
    order (the lib chunks load lazily from the real files). Persistence goes through the REAL
    core_db code and the throwaway test database (DESIGN §56.10: tests/pgbridge.lua; run
    `scripts/test-db.sh up` once): H.sql / H.scalar query it directly, H.spyDB records the calls.
]]

local here = (arg and arg[0] or 'tests/server_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local vector3 = stubs.vector3

local H = {}
H.stubs = stubs
H.vector3 = vector3

--------------------------------------------------------------------------------
-- assertions (identical style and exit code to run_tests.lua)
--------------------------------------------------------------------------------

H.passed, H.failed, H.suiteName = 0, 0, '?'
H.failures = {}

function H.suite(name)
    H.suiteName = name
end

local function show(v)
    if type(v) == 'string' then return ('%q'):format(v) end
    return tostring(v)
end

function H.check(cond, label, detail)
    if cond then
        H.passed = H.passed + 1
        return true
    end
    H.failed = H.failed + 1
    local line = ('FAIL  [%s] %s'):format(H.suiteName, label)
    if detail then line = line .. '\n        ' .. detail end
    H.failures[#H.failures + 1] = line
    print(line)
    return false
end

function H.eq(actual, expected, label)
    return H.check(actual == expected, label,
        ('expected %s, got %s'):format(show(expected), show(actual)))
end

--- Array equality, order included.
function H.same(actual, expected, label)
    local ok = type(actual) == 'table' and #actual == #expected
    if ok then
        for i = 1, #expected do
            if actual[i] ~= expected[i] then ok = false end
        end
    end
    local function list(t)
        if type(t) ~= 'table' then return tostring(t) end
        local parts = {}
        for i = 1, #t do parts[i] = show(t[i]) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return H.check(ok, label, ('expected %s, got %s'):format(list(expected), list(actual)))
end

--- The error of a `pcall`ed API that returns `value, err` — second return value only.
function H.errOf(...)
    return (select(2, ...))
end

--- The most recent printed line containing `needle`, or nil.
function H.printed(needle)
    for i = #stubs.printed, 1, -1 do
        if stubs.printed[i]:find(needle, 1, true) then return stubs.printed[i] end
    end
    return nil
end

--- The most recent TriggerClientEvent packet with that event name, or nil.
function H.lastSent(name)
    for i = #stubs.sent, 1, -1 do
        if stubs.sent[i].name == name then return stubs.sent[i] end
    end
    return nil
end

function H.clearFailures()
    for i = #stubs.failures, 1, -1 do stubs.failures[i] = nil end
end

--------------------------------------------------------------------------------
-- one core server VM per suite
--------------------------------------------------------------------------------

-- manifest order; a file that does not exist yet is skipped so the suite keeps running
local SERVER_FILES <const> = {
    'shared/ui_forms.lua', 'server/api.lua', 'shared/hooks.lua', 'server/db.lua', 'server/globals.lua', 'server/notify.lua',
    'server/perms.lua', 'server/player_store.lua', 'server/player.lua', 'server/playergrid.lua', 'server/money.lua',
    'server/factions.lua', 'server/vehicles.lua', 'server/vehicles_park.lua', 'server/vehicles_fleet.lua',
}

--- A fresh core VM with import.lua, shared/config.lua and the server modules loaded.
--- The test database is deliberately *not* reset here (stubs.resetServer does that): a second
--- newServer() reads the rows the first one wrote, like a core restart.
function H.newServer()
    stubs.newWorld()
    stubs.clear()
    H.clearFailures()
    -- GetGameTimer() is never 0 in game, and server/player.lua:650 treats "no previous
    -- requestLoad" as t = 0, so a clock at 0 would swallow the very first load request
    stubs.tick(1000)
    local env = stubs.newEnv('server', 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    for i = 1, #SERVER_FILES do
        if stubs.readFile(stubs.root .. '/' .. SERVER_FILES[i]) then
            stubs.loadFile(env, SERVER_FILES[i])
        end
    end
    return env, env.Core
end

--------------------------------------------------------------------------------
-- the test database (DESIGN §56.10): the bridge, direct SQL and a spy on core's core_db calls
--------------------------------------------------------------------------------

H.bridge = stubs.bridge

--- rows of a direct query (as the invoker `tests`); raises on an error so a broken assertion is loud.
function H.sql(sql, params)
    local rows, err = stubs.bridge.sql(sql, params)
    if not rows then error('H.sql: ' .. tostring(err), 2) end
    return rows
end

--- The first column of the first row of H.sql, or nil.
function H.scalar(sql, params)
    local row = H.sql(sql, params)[1]
    if not row then return nil end
    local _, value = next(row)
    return value
end

--- Wraps env's exports.core_db so every call is recorded before it goes through the bridge:
--- returns the live log { { fn = name, args = packed args }, ... } and a clear() function.
--- (lib/db/server.lua reads the raw `synchronous` field, so the wrapper keeps it.)
function H.spyDB(env)
    local real = rawget(env.exports, 'core_db')
    local log = {}
    local spy = setmetatable({ synchronous = rawget(real, 'synchronous') }, {
        __index = function(t, fnName)
            local fn = function(_, ...)
                log[#log + 1] = { fn = fnName, args = table.pack(...) }
                return real[fnName](real, ...)
            end
            rawset(t, fnName, fn)
            return fn
        end,
    })
    rawset(env.exports, 'core_db', spy)
    local function clear() for i = #log, 1, -1 do log[i] = nil end end
    local function restore() rawset(env.exports, 'core_db', real) end
    return log, clear, restore
end

--- Makes env's exports.core_db ASYNCHRONOUS like FiveM's: every call still runs at once against the test
--- database, but its callback fires `delayMs` later on the stub clock, so an awaited Core.DB call yields and
--- other code (a drop, a second join) can run while it is "in flight". Awaited calls then need a coroutine
--- (env.CreateThread). Returns restore().
function H.deferDB(env, delayMs)
    local real = rawget(env.exports, 'core_db')
    local proxy = setmetatable({}, {
        __index = function(t, fnName)
            local fn = function(_, ...)
                local args = table.pack(...)
                local cb = args[args.n]
                if type(cb) == 'function' then
                    args[args.n] = function(...)
                        local answer = table.pack(...)
                        env.SetTimeout(delayMs, function() cb(table.unpack(answer, 1, answer.n)) end)
                    end
                end
                return real[fnName](real, table.unpack(args, 1, args.n))
            end
            rawset(t, fnName, fn)
            return fn
        end,
    })
    rawset(env.exports, 'core_db', proxy)
    return function() rawset(env.exports, 'core_db', real) end
end

--------------------------------------------------------------------------------
-- fixtures shared by more than one suite
--------------------------------------------------------------------------------

--- The last core:client:notify message sent to `src`, or nil. Shared by admin_ranks.lua
--- and legacy_commands.lua.
function H.lastNoticeTo(src)
    for i = #stubs.sent, 1, -1 do
        local packet = stubs.sent[i]
        if packet.name == 'core:client:notify' and packet.target == src then return packet.args[1].message end
    end
    return nil
end

--- Fires the stock chatMessage event the way the chat resource does: the source arrives as
--- the FIRST ARGUMENT (`TriggerEvent('chatMessage', source, name, message)` in sv_chat), so
--- the stub dispatcher gets src twice — once for the `source` global, once as the argument.
--- A leading '/' keeps the interceptor's command branch busy exactly like chat's fallback.
--- Shared by chat.lua and playergrid.lua.
function H.dispatchChat(env, src, message)
    stubs.triggerOn(env, 'chatMessage', src, src, 'Ada', message)
end

return H
