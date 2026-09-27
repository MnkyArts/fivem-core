return function(H)
    local check, eq, newServer, printed, stubs, suite =
        H.check, H.eq, H.newServer, H.printed, H.stubs, H.suite

--- Core.Money (DESIGN §4.3): add/remove/set, the transfer rollback and the moneyChanged hook.
local function suiteMoney()
    suite('money')
    stubs.resetServer()
    local env, Core = newServer()
    local M = Core.Money
    local MAX <const> = Core.Config.Money.MaxAmount
    stubs.connectPlayer(env, 1, { license = 'license:m1', name = 'Rich' })
    stubs.connectPlayer(env, 2, { license = 'license:m2', name = 'Poor' })

    local hooks = {}
    Core.on('moneyChanged', function(src, account, amount, delta, reason)
        hooks[#hooks + 1] = { src = src, account = account, amount = amount, delta = delta, reason = reason }
    end)

    -- reads
    eq(M.get(1, 'cash'), 5000, 'a new character starts with the configured cash')
    eq(M.get(1, 'bank'), 25000, '... and bank')
    eq(M.get(1, 'crypto'), 0, 'an unconfigured account reads 0')
    eq(M.get(99, 'cash'), 0, 'a src without a session reads 0')
    eq(M.canAfford(1, 'cash', 5000), true, 'canAfford at exactly the balance')
    eq(M.canAfford(1, 'cash', 5001), false, 'canAfford above the balance')
    eq(M.canAfford(1, 'cash', -1), false, 'canAfford refuses a negative amount')
    eq(M.canAfford(1, 'crypto', 0), false, 'canAfford refuses an unconfigured account')

    -- add
    eq(M.add(1, 'cash', 250, 'wage'), true, 'add')
    eq(M.get(1, 'cash'), 5250, 'the balance went up')
    eq(#hooks, 1, 'the moneyChanged hook fired once')
    eq(hooks[1].src, 1, 'the hook carries the src')
    eq(hooks[1].account, 'cash', 'the hook carries the account')
    eq(hooks[1].amount, 5250, 'the hook carries the new balance')
    eq(hooks[1].delta, 250, 'the hook carries the delta')
    eq(hooks[1].reason, 'wage', 'the hook carries the reason')
    eq(env.Player(1).state.cash, 5250, 'the cash state-bag key followed the change')
    check(printed('money src=1') ~= nil, 'the change is audited')
    eq(M.add(1, 'cash', 5), true, 'add without a reason works')
    eq(hooks[#hooks].reason, 'unknown', "an absent reason is audited as 'unknown'")

    -- add: rejected input never changes a balance
    local before = M.get(1, 'cash')
    eq(M.add(1, 'cash', 0), false, 'add of 0 is refused')
    eq(M.add(1, 'cash', -5), false, 'add of a negative amount is refused')
    eq(M.add(1, 'cash', 1.5), false, 'add of a float is refused')
    eq(M.add(1, 'cash', 0 / 0), false, 'add of NaN is refused')
    eq(M.add(1, 'cash', '100'), false, 'add of a numeric string is refused')
    eq(M.add(1, 'crypto', 5), false, 'add to an unconfigured account is refused')
    eq(M.add(1, 'cash', MAX + 1), false, 'add above MaxAmount is refused outright')
    eq(M.add(1, 'cash', MAX), false, 'add that would overflow MaxAmount is refused')
    eq(M.add(99, 'cash', 5), false, 'add without a session is refused')
    eq(M.get(1, 'cash'), before, 'no refused add moved the balance')

    -- remove
    eq(M.remove(1, 'cash', 255, 'fee'), true, 'remove')
    eq(M.get(1, 'cash'), 5000, 'the balance went down')
    eq(hooks[#hooks].delta, -255, 'the hook carries a negative delta')
    eq(M.remove(1, 'cash', 5001), false, 'remove more than the balance is refused')
    eq(M.get(1, 'cash'), 5000, 'an insufficient remove is never partial')
    eq(M.remove(1, 'cash', 0), false, 'remove of 0 is refused')
    eq(M.remove(99, 'cash', 1), false, 'remove without a session is refused')
    eq(M.remove(1, 'cash', 5000, 'all of it'), true, 'remove of the exact balance works')
    eq(M.get(1, 'cash'), 0, 'the account is empty')
    eq(env.Player(1).state.cash, 0, 'the empty balance replicated')

    -- set
    eq(M.set(1, 'cash', 1234), true, 'set')
    eq(M.get(1, 'cash'), 1234, 'set wrote the balance')
    eq(hooks[#hooks].delta, 1234, 'set reports the delta from the old balance')
    eq(hooks[#hooks].reason, 'set', "set audits as 'set' by default")
    eq(M.set(1, 'cash', 0), true, 'set to zero is allowed (unlike add/remove)')
    eq(M.set(1, 'cash', -1), false, 'set refuses a negative amount')
    eq(M.set(1, 'cash', MAX + 1), false, 'set refuses more than MaxAmount')
    eq(M.set(1, 'cash', 1.5), false, 'set refuses a float')
    eq(M.set(99, 'cash', 1), false, 'set without a session is refused')

    -- transfer
    M.set(1, 'cash', 5000, 'reset')
    M.set(2, 'cash', 5000, 'reset')
    eq(M.transfer(1, 2, 'cash', 1000, 'gift'), true, 'transfer moves money')
    eq(M.get(1, 'cash'), 4000, 'the sender paid')
    eq(M.get(2, 'cash'), 6000, 'the receiver got it')
    eq(M.transfer(1, 1, 'cash', 10), false, 'transfer to self is refused')
    eq(M.transfer(1, 99, 'cash', 10), false, 'transfer to a src without a session is refused')
    eq(M.transfer(99, 1, 'cash', 10), false, 'transfer from a src without a session is refused')
    eq(M.transfer(1, 2, 'cash', 0), false, 'transfer of 0 is refused')
    eq(M.transfer(1, 2, 'crypto', 10), false, 'transfer on an unconfigured account is refused')
    eq(M.transfer(1, 2, 'cash', 99999), false, 'transfer beyond the balance is refused')
    eq(M.get(1, 'cash'), 4000, 'a refused transfer moved nothing')
    eq(M.get(2, 'cash'), 6000, '... on either side')

    -- the receiver cannot take it: reject before either balance changes
    M.set(2, 'cash', MAX, 'fill')
    local hooksBefore = #hooks
    eq(M.transfer(1, 2, 'cash', 100), false, 'a transfer the receiver cannot take fails')
    eq(M.get(1, 'cash'), 4000, 'the sender is unchanged')
    eq(M.get(2, 'cash'), MAX, 'the receiver is unchanged')
    eq(env.Player(1).state.cash, 4000, 'the unchanged balance remains replicated')
    eq(#hooks - hooksBefore, 0, 'a capped recipient is rejected before any mutation hook')
    eq(Core.Money.get(1, 'cash'), 4000, 'preflight rejection leaves the sender unchanged')
end

    return suiteMoney
end
