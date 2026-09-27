return function(H)
    local check, eq, newServer, printed, stubs, suite =
        H.check, H.eq, H.newServer, H.printed, H.stubs, H.suite

--- Core.Perms (DESIGN §4.4): console, ACE, config group, and the setGroup delegation.
local function suitePerms()
    suite('perms')
    stubs.resetServer()
    local env, Core = newServer()
    local P = Core.Perms

    -- console and plain refusals
    eq(P.has(0, 'core.admin'), true, 'the console has every permission')
    eq(P.has(0, 'anything.at.all'), true, 'the console is not checked against a list')
    eq(P.has(0, ''), false, 'an empty permission name is refused even for the console')
    eq(P.has(0, 42), false, 'a non-string permission is refused')
    eq(P.has(1, 'core.admin'), false, 'an unknown src has nothing')
    eq(P.has('1', 'core.admin'), false, 'a string src is refused (identity is a number)')
    eq(P.has(-1, 'core.admin'), false, 'a negative src is refused')
    eq(P.has(5000, 'core.admin'), false, 'an out-of-range src is refused')
    eq(P.getGroup(99), 'user', 'a src without a session reads the default group')

    -- ACE wins before the group list
    stubs.aces['1|core.admin'] = true
    eq(P.has(1, 'core.admin'), true, 'an ACE grants the permission without a session')
    eq(P.isAdmin(1), true, 'isAdmin follows the ACE')
    stubs.aces['1|core.admin'] = nil
    eq(P.has(1, 'core.admin'), false, 'removing the ACE removes the permission')

    -- config groups on the live account document
    stubs.connectPlayer(env, 1, { license = 'license:p1', name = 'Mod' })
    eq(P.getGroup(1), 'user', 'a new account starts in the user group')
    eq(P.has(1, 'core.mod'), false, 'the user group grants nothing')
    eq(P.setGroup(1, 'mod'), true, 'setGroup moves the player into a configured group')
    eq(P.getGroup(1), 'mod', 'getGroup reads the account group')
    eq(P.has(1, 'core.mod'), true, 'the group list grants its own permission')
    eq(P.has(1, 'core.admin'), false, 'mod does not imply admin')
    check(printed('perms src=1') ~= nil, 'the group change is audited')

    -- core.admin implies everything the admin group lists
    eq(P.setGroup(1, 'admin'), true, 'setGroup to admin')
    eq(P.isAdmin(1), true, 'isAdmin')
    eq(P.has(1, 'core.mod'), true, 'core.admin implies the rest of the admin list')
    eq(P.has(1, 'core.nothing'), false, 'core.admin does not invent permissions')

    -- setGroup validation
    eq(P.setGroup(1, 'wizard'), false, 'an unconfigured group is refused')
    eq(P.setGroup(1, 42), false, 'a non-string group is refused')
    eq(P.setGroup(99, 'mod'), false, 'setGroup without a session is refused')
    eq(P.setGroup(0, 'mod'), false, 'the console has no group to set')
    eq(P.getGroup(1), 'admin', 'a refused setGroup changed nothing')

    -- Core.Player.setGroup is the single writer (DESIGN §14)
    local info = Core.Player.getInfo(1)
    eq(info.group, 'admin', 'the live session carries the new group')
    eq(env.Player(1).state.group, 'admin', 'the group state-bag key was re-replicated')
    local row = Core.DB.first('accounts', { id = info.accountId })
    eq(row and row.perm_group, 'admin', 'the accounts row persisted the group (perm_group)')
    local realSetGroup = Core.Player.setGroup
    Core.Player.setGroup = function() return false end
    eq(P.setGroup(1, 'user'), false, 'Perms.setGroup refuses when Player.setGroup refuses')
    eq(P.getGroup(1), 'admin', 'and the group did not change')
    Core.Player.setGroup = realSetGroup

    -- an unknown stored group falls back to the default
    Core.Player.setData(1, 'ignored', true)
    Core.DB.update('accounts', { perm_group = 'ghost-group' }, { id = info.accountId })
    eq(P.getGroup(1), 'admin', 'getGroup reads the session, not the row')
    local reloadedEnv, Reloaded = newServer()
    stubs.connectPlayer(reloadedEnv, 1, { license = 'license:p1', name = 'Mod' })
    eq(Reloaded.Player.getInfo(1).group, 'ghost-group', 'the session loaded the unknown group verbatim')
    eq(Reloaded.Perms.getGroup(1), 'user', 'an unknown group in the row reads back as user')
    eq(Reloaded.Perms.has(1, 'core.admin'), false, 'and grants nothing')
end

    return suitePerms
end
