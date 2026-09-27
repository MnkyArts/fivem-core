return function(H)
    local eq, lastNoticeTo, lastSent, newServer, stubs, suite =
        H.eq, H.lastNoticeTo, H.lastSent, H.newServer, H.stubs, H.suite

--- The legacy commands of server/admin.lua (§4.8) under the §44 ranks: a player may act only on somebody it
--- strictly outranks; /setgroup also refuses self and any group at or above the actor's weight; the console
--- is exempt. Cast: 1 mod (200), 2 admin (300), 3 senior (400), 4 admin (300).
local function suiteAdminRanks()
    suite('admin ranks')
    stubs.resetServer()
    local env, Core = newServer()
    stubs.loadFile(env, 'server/getters.lua')
    stubs.loadFile(env, 'server/admin.lua')
    local Perms, Money = Core.Perms, Core.Money
    local function run(name, src, ...)
        stubs.clear()
        local words = { ... }
        env.__vm.commands[name].fn(src, words, '/' .. name .. ' ' .. table.concat(words, ' '))
    end
    for src, spec in ipairs({ { 'license:mod', 'Mo', 'mod' }, { 'license:adm', 'Al', 'admin' },
        { 'license:sen', 'Se', 'senior' }, { 'license:ad2', 'Ann', 'admin' } }) do
        stubs.connectPlayer(env, src, { license = spec[1], name = spec[2] })
        Perms.setGroup(src, spec[3])
    end
    local RANK = 'You cannot do that to a player of equal or higher rank.'
    -- everybody on duty here; suiteLegacyCommands covers duty, audit rows and echo (R2-15)
    Core.Admin = { isOnDuty = function() return true end, echo = function() return 0 end,
        getModes = function() return {} end }
    local realBans = rawget(Core, 'Bans')
    local banned, bannedBy = {}, {}
    Core.Bans = { add = function(opts)
        banned[#banned + 1], bannedBy[#bannedBy + 1] = opts.target, opts.by
        return { id = 'b' .. #banned }
    end }

    -- /kick (core.mod)
    stubs.dropped = {}
    run('kick', 1, '2')
    eq(#stubs.dropped, 0, 'kick: mod -> admin is refused')
    eq(lastNoticeTo(1), RANK, '... with the rank text')
    run('kick', 2, '1')
    eq(stubs.dropped[1] and stubs.dropped[1].src, 1, 'kick: admin -> mod is allowed')
    run('kick', 2, '4')
    eq(#stubs.dropped, 1, 'kick: admin -> admin (equal) is refused')
    run('kick', 2, '2')
    eq(#stubs.dropped, 1, 'kick: nobody kicks themselves')
    run('kick', 0, '3')
    eq(stubs.dropped[2] and stubs.dropped[2].src, 3, 'kick: the console kicks anybody')

    -- /ban (core.admin)
    run('ban', 1, '2', '1')
    eq(#banned, 0, 'ban: a mod lacks the permission (mod -> admin refused)')
    run('ban', 2, '3', '1')
    eq(#banned, 0, 'ban: admin -> senior is refused')
    eq(lastNoticeTo(2), RANK, '... with the rank text')
    run('ban', 2, '4', '1')
    eq(#banned, 0, 'ban: admin -> admin (equal) is refused')
    run('ban', 3, '3', '1')
    eq(#banned, 0, 'ban: nobody bans themselves')
    run('ban', 3, '2', '1')
    eq(banned[1], 2, 'ban: senior -> admin is allowed')
    eq(bannedBy[1], 3, 'ban: Core.Bans gets the actor SRC as `by` (R2-1), never a player-chosen name')
    run('ban', 0, '3', '0')
    eq(banned[2], 3, 'ban: the console bans anybody')
    Core.Bans = realBans

    -- /bring (core.admin)
    run('bring', 2, '3')
    eq(lastSent('core:client:teleport'), nil, 'bring: admin -> senior is refused')
    eq(lastNoticeTo(2), RANK, '... with the rank text')
    run('bring', 2, '4')
    eq(lastSent('core:client:teleport'), nil, 'bring: admin -> admin (equal) is refused')
    run('bring', 3, '2')
    eq(lastSent('core:client:teleport') and lastSent('core:client:teleport').target, 2, 'bring: senior -> admin is allowed')
    run('bring', 2, '2')
    eq(lastSent('core:client:teleport') and lastSent('core:client:teleport').target, 2, 'bring: self passes (a no-op move)')
    run('bring', 0, '2')
    eq(lastSent('core:client:teleport'), nil, 'bring: the console has no position to bring to')
    run('bring', 1, '4')
    eq(lastSent('core:client:teleport'), nil, 'bring: a mod lacks the permission')

    -- money: /givecash /givebank /setcash /setbank (core.admin)
    local cash3, bank4 = Money.get(3, 'cash'), Money.get(4, 'bank')
    run('givecash', 2, '3', '100')
    eq(Money.get(3, 'cash'), cash3, 'givecash: admin -> senior is refused')
    eq(lastNoticeTo(2), RANK, '... with the rank text')
    run('givebank', 2, '4', '100')
    eq(Money.get(4, 'bank'), bank4, 'givebank: admin -> admin (equal) is refused')
    run('setcash', 2, '3', '1')
    eq(Money.get(3, 'cash'), cash3, 'setcash: admin -> senior is refused')
    run('setbank', 2, '4', '1')
    eq(Money.get(4, 'bank'), bank4, 'setbank: admin -> admin (equal) is refused')
    local cash2 = Money.get(2, 'cash')
    run('givecash', 3, '2', '100')
    eq(Money.get(2, 'cash'), cash2 + 100, 'givecash: senior -> admin is allowed')
    run('setbank', 2, '1', '7')
    eq(Money.get(1, 'bank'), 7, 'setbank: admin -> mod is allowed')
    run('givecash', 2, '2', '5')
    eq(Money.get(2, 'cash'), cash2 + 105, 'money: self passes')
    run('setcash', 0, '3', '9')
    eq(Money.get(3, 'cash'), 9, 'setcash: the console sets anybody')
    run('givecash', 1, '1', '5')
    eq(Money.get(1, 'cash'), 5000, 'money: a mod lacks the permission')

    -- /setgroup (core.admin): outrank the target, never self, only groups below the actor
    run('setgroup', 2, '1', 'helper')
    eq(Perms.getGroup(1), 'helper', 'setgroup: admin moves a mod to a lighter group')
    run('setgroup', 2, '1', 'admin')
    eq(Perms.getGroup(1), 'helper', 'setgroup: admin cannot hand out its own weight')
    eq(lastNoticeTo(2), 'You can only assign groups below your own rank.', '... and is told so')
    run('setgroup', 2, '1', 'senior')
    eq(Perms.getGroup(1), 'helper', 'setgroup: ... nor a heavier group')
    run('setgroup', 2, '2', 'mod')
    eq(Perms.getGroup(2), 'admin', 'setgroup: nobody changes their own group')
    eq(lastNoticeTo(2), 'You cannot change the group of this player.', '... with the refusal text')
    run('setgroup', 2, '3', 'user')
    eq(Perms.getGroup(3), 'senior', 'setgroup: admin -> senior is refused')
    run('setgroup', 2, '4', 'user')
    eq(Perms.getGroup(4), 'admin', 'setgroup: admin -> admin (equal) is refused')
    run('setgroup', 3, '2', 'mod')
    eq(Perms.getGroup(2), 'mod', 'setgroup: senior demotes an admin')
    run('setgroup', 1, '4', 'user')
    eq(Perms.getGroup(4), 'admin', 'setgroup: a helper lacks the permission')
    run('setgroup', 0, '3', 'owner')
    eq(Perms.getGroup(3), 'owner', 'setgroup: the console sets any group')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

    return suiteAdminRanks
end
