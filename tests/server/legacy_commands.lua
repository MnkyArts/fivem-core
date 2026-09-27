return function(H)
    local check, eq, lastNoticeTo, lastSent, newServer, stubs, suite, vector3 =
        H.check, H.eq, H.lastNoticeTo, H.lastSent, H.newServer, H.stubs, H.suite, H.vector3

--- R2-15 / R2-1 / R2-2: the legacy staff commands as an admin path — duty, an audit row WITH the actor per executed
--- command, the staff echo, /ban's actor src, the rank checks of /dv /tpto /weapon /weapons, and
--- Config.Admin.LegacyCommands = false. Cast: 1 admin (on duty), 2 admin (off duty), 3 senior (on duty), 4 user.
local function suiteLegacyCommands()
    suite('legacy commands')
    stubs.resetServer()
    local env, Core = newServer()
    stubs.loadFile(env, 'server/getters.lua')
    stubs.loadFile(env, 'server/weapons.lua')
    stubs.loadFile(env, 'server/admin.lua')
    local P, Perms = Core.Player, Core.Perms
    for src, spec in ipairs({ { 'license:l1', 'Al', 'admin' }, { 'license:l2', 'Off', 'admin' },
        { 'license:l3', 'Se', 'senior' }, { 'license:l4', 'Us', 'user' } }) do
        stubs.connectPlayer(env, src, { license = spec[1], name = spec[2], coords = vector3(src * 1.0, 0.0, 0.0) })
        Perms.setGroup(src, spec[3])
    end
    local duty, echoes, rows, modes = { [1] = true, [3] = true }, {}, {}, {}
    Core.Admin = {
        isOnDuty = function(src) return src == 0 or duty[src] == true end,
        echo = function(text, opts) echoes[#echoes + 1] = { text = text, exclude = opts and opts.exclude } return 1 end,
        getModes = function(src) return modes[src] or {} end,
    }
    Core.Audit = { record = function(row) rows[#rows + 1] = row return #rows end }
    local banOpts
    Core.Bans = { add = function(opts) banOpts = opts return opts.reason ~= 'refuse' and { id = 'B1' } or nil end }
    env.NetworkGetEntityOwner = function(entity)
        for src, ped in pairs(stubs.peds) do if ped == entity then return src end end
        return -1
    end
    local function run(name, src, ...)
        stubs.clear()
        local words = { ... }
        env.CreateThread(function()
            env.__vm.commands[name].fn(src, words, '/' .. name .. ' ' .. table.concat(words, ' '))
        end)
        stubs.tick(50)
    end
    local function lastRow(action)
        for i = #rows, 1, -1 do if rows[i].action == action then return rows[i] end end
        return nil
    end
    local RANK = 'You cannot do that to a player of equal or higher rank.'
    local DUTY = 'You must be on duty to use staff commands.'

    -- 1. duty (Config.Admin.RequireDuty): players only, the console is exempt, no Core.Admin = refused
    run('heal', 2, '4')
    eq(lastSent('core:client:heal'), nil, 'an off-duty admin is refused')
    eq(lastNoticeTo(2), DUTY, '... with the duty text')
    eq(lastRow('core.cmd.heal'), nil, '... and nothing is audited')
    run('heal', 1, '4')
    eq(lastSent('core:client:heal') and lastSent('core:client:heal').target, 4, 'an on-duty admin heals')
    run('heal', 0, '4')
    eq(lastSent('core:client:heal') and lastSent('core:client:heal').target, 4, 'the console needs no duty')
    Core.Config.Admin.RequireDuty = false
    run('heal', 2, '4')
    eq(lastSent('core:client:heal') and lastSent('core:client:heal').target, 4, 'RequireDuty = false lifts the gate')
    Core.Config.Admin.RequireDuty = true
    local admin = Core.Admin
    Core.Admin = nil
    run('heal', 1, '4')
    eq(lastSent('core:client:heal'), nil, 'without Core.Admin the duty is unknown: refused')
    Core.Admin = admin

    -- 2. every executed command: one audit row with the actor, and an echo to the other staff
    rows, echoes = {}, {}
    run('givecash', 1, '4', '50')
    local row = lastRow('core.cmd.givecash')
    check(row ~= nil, 'givecash writes core.cmd.givecash')
    eq(row and row.actor, 1, '... with the actor src')
    eq(row and row.source, 'chat', "... source 'chat'")
    eq(row and row.targets and row.targets[1].id, 4, '... the target player')
    eq(row and row.message, 'add cash 50', '... and the summary')
    check(#echoes == 1 and echoes[1].text:find('/givecash', 1, true) ~= nil, 'the on-duty staff get an echo')
    eq(echoes[1] and echoes[1].exclude, 1, '... without the actor')
    run('heal', 0, '4')
    eq(lastRow('core.cmd.heal').actor, 0, 'the console is the actor of its own rows')
    eq(lastRow('core.cmd.heal').source, 'console', "... source 'console'")
    run('kick', 1, '4', 'spamming', 'chat')
    eq(lastRow('core.cmd.kick') and lastRow('core.cmd.kick').reason, 'spamming chat', 'kick records the reason')
    local each = {
        { 'tp', 1, '10', '20', '30' }, { 'tpto', 1, '4' }, { 'bring', 1, '4' }, { 'setbank', 1, '4', '5' },
        { 'givebank', 1, '4', '5' }, { 'setcash', 1, '4', '5' }, { 'setgroup', 1, '4', 'helper' },
        { 'announce', 1, 'hello', 'all' }, { 'revive', 1, '4' }, { 'heal', 1, '4' },
        { 'weapon', 1, '4', 'WEAPON_PISTOL', '10' }, { 'weapons', 1, 'clear', '4' }, { 'ban', 1, '4', '1', 'x' },
        { 'car', 1 },
    }
    for _, spec in ipairs(each) do
        rows = {}
        run(table.unpack(spec))
        local got = lastRow('core.cmd.' .. spec[1])
        check(got ~= nil and got.actor == 1, ('/%s is audited with its actor'):format(spec[1]))
    end
    rows = {}
    stubs.clear()
    stubs.triggerOn(env, 'core:server:teleportToWaypoint', 1, vector3(100.0, 200.0, 30.0))
    eq(lastRow('core.cmd.tpm') and lastRow('core.cmd.tpm').actor, 1, 'the /tpm event is audited too')
    stubs.tick(1100)
    duty[1] = false
    stubs.triggerOn(env, 'core:server:teleportToWaypoint', 1, vector3(1.0, 2.0, 3.0))
    eq(P.getData(1, 'position').x, 100.0, '... and refused off duty')
    duty[1] = true

    -- 3. /ban hands Core.Bans the actor SRC (R2-1); a refused ban says so
    run('ban', 1, '4', '2', 'cheats')
    eq(banOpts and banOpts.by, 1, 'by = the actor src')
    eq(banOpts and banOpts.duration, 7200, 'the duration in seconds')
    run('ban', 1, '4', '0', 'refuse')
    eq(lastNoticeTo(1), 'Could not ban Us', 'a refused Bans.add is reported, not claimed')

    -- 4. /dv: never out from under a player of equal or higher rank (R2-2)
    local car = stubs.newEntity(2, {})
    local ped1, ped3 = stubs.peds[1], stubs.peds[3]
    stubs.pedVehicle[ped1], stubs.pedVehicle[ped3] = car, car
    stubs.vehicleSeats[car] = { [-1] = ped3, [0] = ped1 }
    run('dv', 1)
    eq(stubs.entities[car].exists, true, 'dv: an admin cannot delete the car a senior drives')
    eq(lastNoticeTo(1), RANK, '... rank text')
    run('dv', 3)
    eq(stubs.entities[car].exists, false, 'dv: the senior deletes it with the admin inside')
    eq(lastRow('core.cmd.dv') and lastRow('core.cmd.dv').targets[1].type, 'vehicle', 'dv audits the vehicle')
    stubs.pedVehicle[ped1], stubs.pedVehicle[ped3] = nil, nil

    -- 5. /tpto: anybody may be visited, except hidden staff one does not outrank (R2-2)
    run('tpto', 1, '3')
    eq(lastSent('core:client:teleport') and lastSent('core:client:teleport').target, 1, 'tpto a visible senior: allowed')
    modes[3] = { vanish = true }
    run('tpto', 1, '3')
    eq(lastSent('core:client:teleport'), nil, 'tpto a vanished senior: refused')
    eq(lastNoticeTo(1), RANK, '... rank text')
    modes[3], modes[4] = nil, { spectate = true }
    run('tpto', 1, '4')
    eq(lastSent('core:client:teleport') and lastSent('core:client:teleport').target, 1,
        'tpto a spectating player one outranks: allowed')

    -- 6. /weapon and /weapons clear (R2-2)
    run('weapon', 1, '3', 'WEAPON_PISTOL')
    eq(Core.Weapons.has(3, 'WEAPON_PISTOL'), false, 'weapon: admin -> senior is refused')
    eq(lastNoticeTo(1), RANK, '... rank text')
    run('weapon', 1, '1', 'WEAPON_PISTOL', '5')
    eq(Core.Weapons.has(1, 'WEAPON_PISTOL'), true, 'weapon: self is fine')
    run('weapon', 1, '4', 'NOPE')
    eq(lastNoticeTo(1), 'Unknown weapon NOPE', 'weapon: an unknown name')
    run('weapon', 3, '1', 'WEAPON_SMG', '1')
    eq(Core.Weapons.has(1, 'WEAPON_SMG'), true, 'weapon: senior -> admin is allowed')
    run('weapons', 1, 'clear', '3')
    eq(lastNoticeTo(1), RANK, 'weapons clear: admin -> senior is refused')
    run('weapons', 3, 'clear', '1')
    eq(Core.Weapons.has(1, 'WEAPON_SMG'), false, 'weapons clear: senior -> admin is allowed')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')

    -- 7. Config.Admin.LegacyCommands = false: none of the staff commands exist, the player ones stay
    stubs.resetServer()
    local off = newServer()
    off.Config.Admin.LegacyCommands = false
    stubs.loadFile(off, 'server/getters.lua')
    stubs.loadFile(off, 'server/weapons.lua')
    stubs.loadFile(off, 'server/admin.lua')
    local cmds = off.__vm.commands
    for _, name in ipairs({ 'tp', 'tpto', 'bring', 'car', 'dv', 'setcash', 'setbank', 'givecash', 'givebank',
        'setgroup', 'kick', 'ban', 'announce', 'revive', 'heal', 'weapon', 'weapons' }) do
        eq(cmds[name], nil, ('LegacyCommands = false: no /%s'):format(name))
    end
    eq(off.__vm.netEvents['core:server:teleportToWaypoint'], nil, '... and no /tpm handler')
    check(cmds.id ~= nil and cmds.players ~= nil and cmds.faction ~= nil, 'the player commands stay')
end

    return suiteLegacyCommands
end
