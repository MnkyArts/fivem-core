--[[
    core/tests/callback_tests.lua — refusal reasons of Core.Callback (lib/callback/shared.lua, DESIGN §3.5/§44).

        lua5.4 tests/callback_tests.lua    (from the resource directory, or from tests/)

    Every await form answers the handler's results unchanged, or `nil, err` with err one of
    'rate_limit' | 'schema' | 'cooldown' | 'permission' | 'timeout' | 'error'. Two VMs per suite (a plugin
    server VM whose Core.Perms.has is a scripted export, and a client VM). Exit code 1 on failure.
]]

local here = (arg and arg[0] or 'tests/callback_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')

local passed, failed, suiteName = 0, 0, '?'

local function eq(actual, expected, label)
    if actual == expected then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    print(('FAIL  [%s] %s\n        expected %s, got %s'):format(suiteName, label, tostring(expected), tostring(actual)))
    return false
end

--- A server VM (plugin 'cb_test', Core.Perms.has answered by `allowed`) and a client VM, one world.
local function pair(allowed)
    stubs.newWorld()
    stubs.clear()
    stubs.resetServer()
    stubs.net.drop, stubs.net.latency = false, 0
    stubs.exports.core = { call = function(_, ns, fn, src, perm)
        if ns == 'Perms' and fn == 'has' then return allowed[perm] == src end
        if ns == 'Player' and fn == 'isLoaded' then return true end
    end }
    local server = stubs.newEnv('server', 'cb_test')
    local client = stubs.newEnv('client', 'cb_test')
    return server, stubs.loadImport(server), client, stubs.loadImport(client)
end

--- Runs `fn` in a client thread and returns a table with every value it returned (n = count), or 'pending'.
local function ask(env, fn)
    local out = { pending = true }
    env.CreateThread(function()
        local r = table.pack(fn())
        out.pending, out.n = false, r.n
        for i = 1, r.n do out[i] = r[i] end
    end)
    return out
end

-- client -> server ------------------------------------------------------------------------------------------
do
    suiteName = 'await'
    local server, Core, client, CC = pair({ ['cb.view'] = 1 })
    Core.Callback.register('t:plain', function() return 1, nil, 3 end)
    Core.Callback.register('t:none', function() end)
    Core.Callback.register('t:schema', { 'integer' }, function(_, n) return n end)
    Core.Callback.register('t:cool', function() return 'ok' end, { cooldownMs = 1000 })
    Core.Callback.register('t:perm', function() return 'ok' end, { permission = 'cb.view' })
    Core.Callback.register('t:deny', function() return 'ok' end, { permission = 'cb.admin' })
    Core.Callback.register('t:boom', function() error('boom') end)

    local r = ask(client, function() return CC.Callback.await('t:plain') end)
    eq(r.n, 3, 'plain results keep their count')
    eq(r[1], 1, 'first result')
    eq(r[2], nil, 'a nil in the middle')
    eq(r[3], 3, 'third result')
    r = ask(client, function() return CC.Callback.await('t:none') end)
    eq(r.n, 0, 'a handler returning nothing answers nothing (no err)')

    r = ask(client, function() return CC.Callback.await('t:schema', 'x') end)
    eq(r[1], nil, 'schema refusal: nil')
    eq(r[2], 'schema', "schema refusal: 'schema'")
    r = ask(client, function() return CC.Callback.await('t:schema', 4) end)
    eq(r[1], 4, 'a valid payload still answers')

    r = ask(client, function() return CC.Callback.await('t:cool') end)
    eq(r[1], 'ok', 'first request inside no cooldown')
    r = ask(client, function() return CC.Callback.await('t:cool') end)
    eq(r[2], 'cooldown', "cooldown refusal: 'cooldown'")

    r = ask(client, function() return CC.Callback.await('t:perm') end)
    eq(r[1], 'ok', 'the permission holder is answered')
    r = ask(client, function() return CC.Callback.await('t:deny') end)
    eq(r[1], nil, 'permission refusal: nil')
    eq(r[2], 'permission', "permission refusal: 'permission'")

    r = ask(client, function() return CC.Callback.await('t:boom') end)
    eq(r[2], 'error', "a handler error: 'error'")
    r = ask(client, function() return CC.Callback.awaitTimeout('t:deny', 2000) end)
    eq(r[2], 'permission', 'awaitTimeout carries the reason too')
    r = ask(client, function() return CC.Callback.await(42) end)
    eq(r[2], 'error', "an invalid name: 'error'")

    stubs.net.drop = true
    r = ask(client, function() return CC.Callback.awaitTimeout('t:plain', 500) end)
    eq(r.pending, true, 'no answer yet')
    stubs.tick(600)
    eq(r[1], nil, 'timeout: nil')
    eq(r[2], 'timeout', "timeout: 'timeout'")
    stubs.net.drop = false

    -- rate limit: answered with 'rate_limit', at most 10 such answers per second (the rest time out)
    Core.Config.RateLimits.CallbackPerSecond = 1
    stubs.tick(2000)
    local answers = {}
    for i = 1, 14 do answers[i] = ask(client, function() return CC.Callback.awaitTimeout('t:plain', 1000) end) end
    eq(answers[1][1], 1, 'the first request passes the limiter')
    eq(answers[2][2], 'rate_limit', "a rate-limited request: 'rate_limit'")
    eq(answers[11][2], 'rate_limit', 'ten rate_limit answers per second')
    eq(answers[12].pending, true, 'beyond that the flood is not mirrored back')
    stubs.tick(1100)
    eq(answers[12][2], 'timeout', 'and those requests time out')
    Core.Config.RateLimits.CallbackPerSecond = 20
    eq(#stubs.failures, 0, 'no thread errored')
end

-- server -> client ------------------------------------------------------------------------------------------
do
    suiteName = 'awaitClient'
    local server, Core, client, CC = pair({})
    CC.Callback.register('t:ping', function(w) return 'pong-' .. w end)
    CC.Callback.register('t:typed', { 'integer' }, function(n) return n end)
    CC.Callback.register('t:fail', function() error('client boom') end)

    local r = ask(server, function() return Core.Callback.awaitClient(1, 't:ping', 'x') end)
    eq(r[1], 'pong-x', 'plain client result')
    eq(r.n, 1, 'one value, no err')
    r = ask(server, function() return Core.Callback.awaitClient(1, 't:typed', 'x') end)
    eq(r[2], 'schema', "client schema refusal: 'schema'")
    r = ask(server, function() return Core.Callback.awaitClient(1, 't:fail') end)
    eq(r[2], 'error', "client handler error: 'error'")
    r = ask(server, function() return Core.Callback.awaitClient(0, 't:ping') end)
    eq(r[2], 'error', "an invalid src: 'error'")

    -- a forged reason from a client is never passed through
    stubs.net.drop = true
    r = ask(server, function() return Core.Callback.awaitClientTimeout(1, 't:ping', 2000, 'y') end)
    local key
    for i = #stubs.sent, 1, -1 do
        if stubs.sent[i].name == 'core:cb:req:t:ping' then key = stubs.sent[i].args[1] break end
    end
    stubs.triggerOn(server, 'core:cb:res:t:ping', 1, key, false, 'permission; drop table')
    eq(r[2], 'error', "an unknown reason from a client reads as 'error'")

    r = ask(server, function() return Core.Callback.awaitClient(1, 't:ping', 'z') end)
    stubs.triggerOn(server, 'playerDropped', 1, 'quit')
    eq(r[1], nil, 'a dropped player: nil')
    eq(r[2], 'timeout', "a dropped player: 'timeout'")
    stubs.net.drop = false
    eq(#stubs.failures, 0, 'no thread errored')
end

print(('callback: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
