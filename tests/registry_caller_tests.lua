--[[
    core/tests/registry_caller_tests.lua — the Registry caller is per coroutine (DESIGN §2.3, review M1).

        lua5.4 tests/registry_caller_tests.lua    (from the resource directory, or from tests/)

    Two yielding export calls that finish out of LIFO order must not leave the global caller on a plugin,
    and a core thread registering a Cron job meanwhile must own it as 'core'. Also: setCaller/withCaller
    inside a coroutine never touch the global; the main thread keeps the global path; hooks run their
    callback as the registering owner. Exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/registry_caller_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
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

stubs.resetServer()
stubs.newWorld()
stubs.clear()
stubs.tick(1000)
local env = stubs.newEnv('server', 'core')
local Core = stubs.loadImport(env)
stubs.loadFile(env, 'shared/config.lua')
stubs.loadFile(env, 'server/api.lua')
stubs.loadFile(env, 'shared/hooks.lua')
stubs.loadFile(env, 'server/cron.lua')
local Registry = Core.Registry

local function call(caller, ns, fn, ...)
    return stubs.exports.core.call(caller, ns, fn, ...)
end

--- The owner the Registry recorded for one cron job id.
local function cronOwner(id)
    for _, owner in ipairs({ 'core', 'res_a', 'res_b' }) do
        local owned = Registry.getOwned(owner)
        if owned and owned.cron and owned.cron[id] then return owner end
    end
    return nil
end

-- 1. Two interleaved yielding export calls, finishing out of LIFO order (a starts first, ends first).
local seen = {}
Core.Testing = {
    park = function(tag, waitMs)
        seen[#seen + 1] = { tag = tag, at = 'enter', caller = Registry.getCaller() }
        env.Wait(waitMs)
        seen[#seen + 1] = { tag = tag, at = 'exit', caller = Registry.getCaller() }
        return Registry.getCaller()
    end,
    spawn = function()   -- a plugin call that starts a thread inside core
        local inner
        env.CreateThread(function() inner = Registry.getCaller() end)
        return inner, Registry.getCaller()
    end,
}
local cronId, cronCaller
env.CreateThread(function() call('res_a', 'Testing', 'park', 'a', 10) end)
env.CreateThread(function() call('res_b', 'Testing', 'park', 'b', 100) end)
env.CreateThread(function()   -- core's own thread, e.g. audit.lua's post-load job registration
    env.Wait(50)
    cronCaller = Registry.getCaller()
    cronId = Core.Cron.at(4, 30, function() end)
end)
eq(seen[1] and seen[1].caller, 'res_a', 'the first dispatch sees its caller')
eq(seen[2] and seen[2].caller, 'res_b', 'the second dispatch sees its caller')
eq(Registry.getCaller(), 'core', 'the main thread is still core while both are parked')
stubs.tick(20)
eq(seen[3] and seen[3].tag, 'a', 'the first dispatch finished first (not LIFO)')
eq(seen[3] and seen[3].caller, 'res_a', '... still as res_a after its yield')
stubs.tick(40)
eq(cronCaller, 'core', 'a core thread during the parked dispatch is core')
eq(cronOwner(cronId), 'core', 'the Cron job it registered is owned by core')
stubs.tick(100)
eq(seen[4] and seen[4].caller, 'res_b', 'the second dispatch kept res_b across the yield')
eq(Registry.getCaller(), 'core', 'the global caller is core after both finished')
local after
env.CreateThread(function() after = Registry.getCaller() end)
eq(after, 'core', 'a new thread afterwards is core, not a leaked plugin')
local lateId
env.CreateThread(function() lateId = Core.Cron.at(5, 0, function() end) end)
eq(cronOwner(lateId), 'core', 'a Cron job registered after both calls is owned by core')

-- 2. A plugin call that starts a thread inside core: the thread body is core's.
local inner, outer = call('res_a', 'Testing', 'spawn')
eq(outer, 'res_a', 'the dispatched function runs as the plugin')
eq(inner, 'core', 'a thread it starts runs as core')
eq(Registry.getCaller(), 'core', 'the main-thread export restored the global')

-- 3. setCaller / withCaller inside a coroutine stay in that coroutine.
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
eq(Registry.getCaller(), 'core', 'neither touched the global')

-- 4. The main thread keeps the global path (resource load, offline suites).
Registry.setCaller('res_main')
eq(Registry.getCaller(), 'res_main', 'setCaller on the main thread sets the global')
local _, mainWith = Registry.withCaller('res_w', function() return Registry.getCaller() end)
eq(mainWith, 'res_w', 'withCaller on the main thread')
eq(Registry.getCaller(), 'res_main', 'restored after withCaller')
Registry.setCaller(nil)
eq(Registry.getCaller(), 'core', "setCaller(nil) is 'core'")

-- 5. Hooks run the callback as the registering owner, from a coroutine too.
local hookOwner, hookRun
call('res_b', 'Hooks', 'register', 'probe', function() hookOwner = Registry.getCaller() return true end)
env.CreateThread(function() hookRun = Core.Hooks.run('probe', {}) end)
eq(hookRun, true, 'the pipeline ran from a thread')
eq(hookOwner, 'res_b', 'the callback ran as its owner')
eq(Registry.getCaller(), 'core', 'and the owner did not leak')
eq(#stubs.failures, 0, 'no thread errored')

print(('registry caller: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
