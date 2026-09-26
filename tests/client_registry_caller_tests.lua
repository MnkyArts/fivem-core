--[[
    core/tests/client_registry_caller_tests.lua — the CLIENT Registry caller is per coroutine (DESIGN §2.3,
    review M1, client/api.lua).

        lua5.4 tests/client_registry_caller_tests.lua    (from the resource directory, or from tests/)

    Two yielding export calls (a page waiting for its NUI answer) that finish out of LIFO order must not leave
    the caller on a plugin; a core thread registering meanwhile owns its item as 'core', so the owner sweep of
    a plugin never removes it. setCaller/withCaller inside a coroutine never touch the main-thread value.
    Exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/client_registry_caller_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local passed, failed = 0, 0

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  %s%s'):format(label, detail and ('\n        ' .. detail) or ''))
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

stubs.newWorld()
stubs.clear()
stubs.resetNui()
stubs.tick(1000)
local env = stubs.newEnv('client', 'core')
local Core = stubs.loadImport(env)
stubs.loadFile(env, 'shared/config.lua')
stubs.loadFile(env, 'client/api.lua')
local Registry = Core.Registry

local function call(caller, ns, fn, ...)
    return stubs.exports.core.call(caller, ns, fn, ...)
end

-- A stand-in client module: registrations are owner-tracked with Registry.getCaller(), as markers, zones,
-- controls, pages and UI requests do; the remover records what the owner sweep removed.
local items, removed = {}, {}
Registry.onOwnerStop('probe', function(id, owner)
    items[id] = nil
    removed[#removed + 1] = id .. '@' .. owner
end)
local serial = 0
local function register()
    serial = serial + 1
    local id, owner = 'probe:' .. serial, Registry.getCaller()
    items[id] = owner
    Registry.track('probe', id, owner)
    return id
end
local seen = {}
Core.Testing = {
    register = register,
    wait = function(tag, waitMs)   -- a page open that waits for its NUI answer
        local id = register()
        seen[#seen + 1] = { tag = tag, at = 'enter', caller = Registry.getCaller() }
        env.Wait(waitMs)
        seen[#seen + 1] = { tag = tag, at = 'exit', caller = Registry.getCaller(), second = register() }
        return id
    end,
    spawn = function()
        local inner
        env.CreateThread(function() inner = Registry.getCaller() end)
        return inner, Registry.getCaller()
    end,
}

-- 1. Interleaved yielding export calls, finishing out of LIFO order, and a core thread meanwhile.
local coreItem, coreCaller
env.CreateThread(function() call('res_a', 'Testing', 'wait', 'a', 10) end)
env.CreateThread(function() call('res_b', 'Testing', 'wait', 'b', 100) end)
env.CreateThread(function()   -- core's own thread (a scan loop, a timer)
    env.Wait(50)
    coreCaller = Registry.getCaller()
    coreItem = register()
end)
eq(seen[1] and seen[1].caller, 'res_a', 'the first dispatch sees its caller')
eq(seen[2] and seen[2].caller, 'res_b', 'the second dispatch sees its caller')
eq(Registry.getCaller(), 'core', 'the main thread is core while both are parked')
stubs.tick(20)
eq(seen[3] and seen[3].tag, 'a', 'the first dispatch finished first (not LIFO)')
eq(seen[3] and seen[3].caller, 'res_a', '... as res_a after its yield')
eq(seen[3] and items[seen[3].second], 'res_a', '... and registered as res_a after the yield')
stubs.tick(40)
eq(coreCaller, 'core', 'a core thread during the parked dispatch is core')
eq(items[coreItem], 'core', 'its registration is owned by core')
stubs.tick(100)
eq(seen[4] and seen[4].caller, 'res_b', 'the second dispatch kept res_b across the yield')
eq(seen[4] and items[seen[4].second], 'res_b', '... and registered as res_b')
eq(Registry.getCaller(), 'core', 'the main-thread caller is core after both finished')
local after
env.CreateThread(function() after = Registry.getCaller() end)
eq(after, 'core', 'a new thread afterwards is core, not a leaked plugin')

-- 2. The owner sweep removes only the plugin's items.
env.TriggerEvent('onResourceStop', 'res_a')
eq(#removed, 2, 'res_a stop removed its two items')
eq(items[coreItem], 'core', 'the core-owned item survived the sweep')
env.TriggerEvent('onResourceStop', 'res_b')
eq(#removed, 4, 'res_b stop removed its two items')
eq(items[coreItem], 'core', 'and core still owns its item')

-- 3. A plugin call that starts a thread inside core: the thread body is core's.
local inner, outer = call('res_a', 'Testing', 'spawn')
eq(outer, 'res_a', 'the dispatched function runs as the plugin')
eq(inner, 'core', 'a thread it starts runs as core')
eq(Registry.getCaller(), 'core', 'the main-thread export restored the caller')
local ok, err = pcall(call, 'res_a', 'Testing', 'missing')
check(not ok and tostring(err):find('no API') ~= nil, 'an unknown API still errors')
Core.Testing.boom = function() error('inner failure', 0) end
eq(select(2, pcall(call, 'res_a', 'Testing', 'boom')), 'inner failure', 'an API error surfaces unchanged')
eq(Registry.getCaller(), 'core', '... and the caller is restored after it')

-- 4. setCaller / withCaller inside a coroutine stay in that coroutine; the main thread keeps its value.
local inside, withIn, restored
env.CreateThread(function()
    Registry.setCaller('res_x')
    inside = Registry.getCaller()
    local _, got = Registry.withCaller('res_y', function() return Registry.getCaller() end)
    withIn = got
    restored = Registry.getCaller()
end)
eq(inside, 'res_x', 'setCaller in a coroutine applies to it')
eq(withIn, 'res_y', 'withCaller in a coroutine applies inside the callback')
eq(restored, 'res_x', 'and is restored after it')
eq(Registry.getCaller(), 'core', 'neither touched the main-thread caller')
Registry.setCaller('res_main')
eq(Registry.getCaller(), 'res_main', 'setCaller on the main thread')
local _, mainWith = Registry.withCaller('res_w', function() return Registry.getCaller() end)
eq(mainWith, 'res_w', 'withCaller on the main thread')
eq(Registry.getCaller(), 'res_main', 'restored after withCaller')
Registry.setCaller(nil)
eq(Registry.getCaller(), 'core', "setCaller(nil) is 'core'")
eq(#stubs.failures, 0, 'no thread errored')

print(('client registry caller: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
