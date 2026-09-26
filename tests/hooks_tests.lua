-- Offline contracts for hooks on both VMs, plus the authoritative transfer extension point.
local here = (arg and arg[0] or 'tests/hooks_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
local stubs = dofile(here .. '/stubs.lua')
local passed = 0
local function check(value, message)
    assert(value, message)
    passed = passed + 1
end
local function fresh(side)
    stubs.newWorld()
    stubs.clear()
    local env = stubs.newEnv(side, 'core')
    stubs.loadImport(env)
    stubs.loadFile(env, 'shared/config.lua')
    stubs.loadFile(env, side .. '/api.lua')
    stubs.loadFile(env, 'shared/hooks.lua')
    return env, env.Core
end
for _, side in ipairs({ 'client', 'server' }) do
    local env, core = fresh(side)
    local hooks, registry = core.Hooks, core.Registry
    local order, payload = {}, { nested = { value = 7 } }
    hooks.register('order', function(data)
        order[#order + 1] = 'later'
        check(data.nested.value == 7, 'snapshot for each callback')
    end, { priority = 10 })
    hooks.register('order', function(data)
        order[#order + 1] = 'first'; data.nested.value = 99
    end)
    hooks.register('order', function() order[#order + 1] = 'second' end)
    check(hooks.run('order', payload), 'pipeline accepts')
    check(table.concat(order, ',') == 'first,second,later', 'priority and stable order')
    check(payload.nested.value == 7, 'original immutable')
    check(hooks.register('', function() end) == nil, 'empty name rejected')
    check(hooks.register('bad', false) == nil, 'noncallable rejected')
    check(hooks.register('bad', function() end, { priority = 0 / 0 }) == nil, 'nan priority rejected')
    check(hooks.register('bad', function() end, { filter = {} }) == nil, 'bad filter rejected')
    check(hooks.register('bad', function() end, { priority = 0.5 }) == nil, 'fractional priority rejected')
    local cycle = {}; cycle.self = cycle
    check(not hooks.run('none', cycle), 'cyclic payload rejected')
    check(not hooks.run('none', { callback = function() end }), 'function payload rejected')
    check(not hooks.run('none', { value = math.huge }), 'nonfinite payload rejected')
    check(not hooks.run('none', setmetatable({}, {})), 'metatable payload rejected')
    check(hooks.run('none', nil), 'empty unregistered pipeline succeeds')
    local deep = {}; local cursor = deep
    for _ = 1, 18 do cursor.next = {}; cursor = cursor.next end
    check(not hooks.run('none', deep), 'deep payload rejected')
    local wide = {}; for i = 1, 4100 do wide[i] = i end
    check(not hooks.run('none', wide), 'oversized payload rejected')

    local vetoes, observed = 0, false
    hooks.register('veto', function() vetoes = vetoes + 1; return false end)
    hooks.register('veto', function() error('must not execute after veto') end)
    hooks.register('veto', function(data, allowed, reason)
        observed = not allowed and reason == 'veto' and data.x == 1
        return true
    end, { after = true })
    local ok, reason = hooks.run('veto', { x = 1 })
    check(not ok and reason == 'veto' and vetoes == 1, 'false veto short-circuits')
    check(observed, 'after observer sees final decision')
    hooks.register('after', function() return false end, { after = true })
    hooks.register('after', function() error('ignored observer failure') end, { after = true })
    check(hooks.run('after', {}), 'after cannot alter allowed decision')
    hooks.register('error', function() error('failure') end)
    ok, reason = hooks.run('error', {})
    check(not ok and reason == 'callback_error', 'errors fail closed')
    hooks.register('reason', function() return false, 'not_allowed' end)
    ok, reason = hooks.run('reason', {})
    check(not ok and reason == 'not_allowed', 'veto preserves reason')
    local resumed = false
    hooks.register('yield', function() coroutine.yield(); resumed = true end)
    ok, reason = hooks.run('yield', {})
    check(not ok and reason == 'callback_yield' and not resumed, 'yield fails closed')
    hooks.register('filter', function() error('filtered out') end, { filter = function() return false end })
    check(hooks.run('filter', {}), 'false filter skips')
    hooks.register('filterError', function() end, { filter = function() error('bad filter') end })
    ok, reason = hooks.run('filterError', {})
    check(not ok and reason == 'filter_error', 'filter errors fail closed')
    hooks.register('filterYield', function() end, { filter = function() coroutine.yield() end })
    ok, reason = hooks.run('filterYield', {})
    check(not ok and reason == 'filter_yield', 'filter yields fail closed')
    hooks.register('recurse', function()
        local nested, why = hooks.run('recurse', {})
        check(not nested and why == 'reentrant', 'same-name recursion rejected')
    end)
    check(hooks.run('recurse', {}), 'outer invocation completes')
    check(hooks.run('recurse', {}), 'active guard released')
    local called = false
    hooks.register('callable', setmetatable({}, { __call = function() called = true end }))
    check(hooks.run('callable', {}) and called, 'callable table accepted')

    registry.setCaller('alpha')
    local handle = hooks.register('owned', function()
        check(registry.getCaller() == 'alpha', 'callback executes with registered owner')
    end)
    registry.setCaller('beta')
    check(not hooks.remove(handle), 'cross-owner removal denied')
    check(hooks.run('owned', {}), 'run owned callback')
    check(registry.getCaller() == 'beta', 'caller restored')
    registry.setCaller('alpha')
    check(hooks.remove(handle), 'owner can remove')
    check(not hooks.remove(handle), 'remove idempotent')
    local stopped = false
    hooks.register('stopped', function() stopped = true end)
    env.TriggerEvent('onResourceStop', 'alpha')
    registry.setCaller('core')
    check(hooks.run('stopped', {}) and not stopped, 'owner stop removes callback')
    local later, newRan, oldRan = nil, false, false
    hooks.register('mutation', function()
        if later then hooks.remove(later) end
        hooks.register('mutation', function() newRan = true end)
    end)
    later = hooks.register('mutation', function() oldRan = true end)
    check(hooks.run('mutation', {}) and not oldRan and not newRan, 'dispatch is stable under mutation')
    check(hooks.run('mutation', {}) and newRan, 'new registration visible on next run')
end

local env, core = fresh('server')
local balances, writes = { [1] = 100, [2] = 20 }, 0
core.Player = {
    isLoaded = function(src) return balances[src] ~= nil end,
    getData = function(src) return { cash = balances[src] } end,
    setData = function(src, _, money) balances[src] = money.cash; writes = writes + 1; return true end,
}
core.Log = { audit = function() end }
core.emitHook = function() end
stubs.loadFile(env, 'server/money.lua')
local money, hooks = core.Money, core.Hooks
check(money.transfer(1, 2, 'cash', 10), 'unhooked transfer succeeds')
check(balances[1] == 90 and balances[2] == 30, 'unhooked balances')
local invoked, blocked = 0, false
local id = hooks.register('money:beforeTransfer', function(data)
    invoked = invoked + 1
    check(data.from == 1 and data.to == 2 and data.amount == 10, 'transfer context')
    data.amount = 1000
    return false
end)
local before = writes
check(not money.transfer(1, 2, 'cash', 10), 'veto rejects transfer')
check(writes == before and balances[1] == 90 and balances[2] == 30, 'veto causes zero writes')
check(not money.transfer(1, 2, 'cash', 1000) and invoked == 1, 'funds checked before callback')
check(not money.transfer(1, 2, 'wrong', 10) and invoked == 1, 'account checked before callback')
check(not money.transfer(1, 1, 'cash', 10) and invoked == 1, 'same source rejected')
check(not money.transfer(1, 3, 'cash', 10) and invoked == 1, 'session checked before callback')
hooks.remove(id)
id = hooks.register('money:beforeTransfer', function(data)
    data.amount = 1000
    blocked = not money.transfer(1, 2, 'cash', 1)
end)
check(money.transfer(1, 2, 'cash', 10) and blocked, 'nested transfer blocked')
check(balances[1] == 80 and balances[2] == 40, 'callback cannot mutate transaction amount')
hooks.remove(id)
id = hooks.register('money:beforeTransfer', function() balances[1] = 0 end)
check(not money.transfer(1, 2, 'cash', 10) and balances[2] == 40, 'funds rechecked after callback')
hooks.remove(id)
balances[1] = 80
id = hooks.register('money:beforeTransfer', function() balances[2] = env.Config.Money.MaxAmount end)
check(not money.transfer(1, 2, 'cash', 10) and balances[1] == 80, 'cap rechecked before debit')
hooks.remove(id)
balances[2] = 40
id = hooks.register('money:beforeTransfer', function() error('reject') end)
check(not money.transfer(1, 2, 'cash', 10), 'hook errors reject transfers')
hooks.remove(id)
id = hooks.register('money:beforeTransfer', function() coroutine.yield() end)
check(not money.transfer(1, 2, 'cash', 10), 'yielding hook rejects transfers')
hooks.remove(id)
check(money.transfer(1, 2, 'cash', 10), 'transfer guard clears after rejection')
print(('hooks: %d passed, 0 failed'):format(passed))
