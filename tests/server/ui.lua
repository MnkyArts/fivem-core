return function(H)
    local check, eq, lastSent, newServer, printed, stubs, suite =
        H.check, H.eq, H.lastSent, H.newServer, H.printed, H.stubs, H.suite

--- Core.UI shell visibility (DESIGN §31.5): validation and the op that is pushed.
--- server/ui.lua is loaded on top of the standard VM — it is not in SERVER_FILES,
--- so the other suites keep running without a Core.UI namespace.
local function suiteUI()
    suite('ui')
    stubs.resetServer()
    local env, Core = newServer()
    stubs.loadFile(env, 'server/ui.lua')
    local UI = Core.UI
    check(type(UI) == 'table', 'server/ui.lua installed Core.UI')
    stubs.connectPlayer(env, 1, { license = 'license:ui', name = 'Uiv' })

    --- op and positional arguments of the last core:client:ui push.
    local function lastPush()
        local packet = lastSent('core:client:ui')
        if not packet then return nil, nil, nil end
        return packet.args[1], packet.args[2], packet.target
    end

    -- hide: the reason is namespaced for the client, which stores it verbatim
    eq(UI.hide(1), true, 'hide pushes for a connected player')
    local op, args, target = lastPush()
    eq(op, 'hide', 'the op is hide')
    eq(args and args[1], 'server:default', 'an absent reason becomes server:default')
    eq(args and #args, 1, 'hide pushes exactly one argument')
    eq(target, 1, 'the push targets that player only')
    eq(UI.hide(1, 'cutscene'), true, 'hide takes a reason')
    op, args = lastPush()
    eq(args and args[1], 'server:cutscene', 'the reason is prefixed with server:')
    eq(UI.hide(1, 'mission.intro-2'), true, 'dots, dashes and digits are allowed')
    op, args = lastPush()
    eq(args and args[1], 'server:mission.intro-2', 'the reason passes through unchanged')

    -- show: same validation, the op is the only difference
    eq(UI.show(1, 'cutscene'), true, 'show pushes for a connected player')
    op, args = lastPush()
    eq(op, 'show', 'the op is show')
    eq(args and args[1], 'server:cutscene', 'show namespaces the reason the same way')
    eq(UI.show(1), true, 'show defaults to the default reason')
    op, args = lastPush()
    eq(args and args[1], 'server:default', 'show pushes server:default')

    -- src validation (§4): identity is the caller's argument, but it is still looked up
    local before = #stubs.sent
    eq(UI.hide(nil), false, 'hide refuses a missing src')
    eq(UI.hide(0), false, 'hide refuses src 0 (console)')
    eq(UI.hide('1'), false, 'hide refuses a non-integer src')
    eq(UI.hide(99), false, 'hide refuses a src nobody is connected on')
    eq(UI.show(99), false, 'show refuses a src nobody is connected on')
    eq(#stubs.sent, before, 'a bad src sends nothing')
    check(printed('is not a connected player') ~= nil, 'the bad src is logged')

    -- reason validation: pattern and length, both sides
    before = #stubs.sent
    eq(UI.hide(1, 'bad reason'), false, 'a space is not allowed in a reason')
    eq(UI.hide(1, ''), false, 'an empty reason is refused')
    eq(UI.hide(1, 42), false, 'a non-string reason is refused')
    eq(UI.hide(1, ('x'):rep(33)), false, 'a reason longer than 32 characters is refused')
    eq(UI.show(1, 'bad reason'), false, 'show validates its reason too')
    eq(#stubs.sent, before, 'an invalid reason sends nothing')
    check(printed('invalid reason') ~= nil, 'the invalid reason is logged')
    eq(UI.hide(1, ('x'):rep(32)), true, 'exactly 32 characters still passes')

    -- reachable through the export proxy like every other Core.UI function (§2.2)
    local call = stubs.exports.core and stubs.exports.core.call
    eq(call('plugin', 'UI', 'hide', 1, 'plugin_reason'), true, 'UI.hide is reachable from a plugin')
    op, args = lastPush()
    eq(op, 'hide', 'the proxied call pushed the same op')
    eq(args and args[1], 'server:plugin_reason',
        'a server-side plugin call is still a server reason (the client owns the caller namespace)')

    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
end

    return suiteUI
end
