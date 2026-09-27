return function(H)
    local check, eq, dispatchChat, newServer, stubs, suite, vector3 =
        H.check, H.eq, H.dispatchChat, H.newServer, H.stubs, H.suite, H.vector3

--- Core.Chat (DESIGN §23): CEF delivery with per-recipient opacity, channels, scream,
--- the filter veto, the cooldown, and the Commands seam (§30.2).

local function suiteChat()
    suite('chat')
    stubs.resetServer()
    local env, Core = newServer()
    stubs.loadFile(env, 'server/chat.lua')
    local Chat = Core.Chat
    check(type(Chat) == 'table', 'server/chat.lua installed Core.Chat')

    stubs.connectPlayer(env, 1, { name = 'Ada', coords = vector3(0.0, 0.0, 0.0) })
    stubs.connectPlayer(env, 2, { name = 'Bruno', coords = vector3(10.0, 0.0, 0.0) })
    stubs.connectPlayer(env, 3, { name = 'Cleo', coords = vector3(300.0, 0.0, 0.0) })
    stubs.connectPlayer(env, 4, { name = 'Dora', coords = vector3(50.0, 0.0, 0.0) })

    --- The last core:client:chat packet pushed to `src`, or nil.
    local function lastChat(target)
        for i = #stubs.sent, 1, -1 do
            local s = stubs.sent[i]
            if s.name == 'core:client:chat' and s.target == target then return s.args[1] end
        end
        return nil
    end

    --- The line pushed to `src`, or nil (strict: a broadcast targets -1, never a player).
    local function lastLine(target)
        local payload = lastChat(target)
        return payload and payload.action == 'add' and payload.line or nil
    end

    --- The most recent broadcast line (-1), or nil.
    local function lastBroadcast()
        local payload = lastChat(-1)
        return payload and payload.action == 'add' and payload.line or nil
    end

    -- 1. send: one targeted line, system channel, full opacity
    eq(Chat.send(1, 'hello', { prefix = 'SYSTEM' }), true, 'send delivers to one player')
    local payload = lastChat(1)
    eq(payload and payload.action, 'add', 'the action is add')
    local line = payload.line
    eq(line.channel, 'system', 'an opts-less send names the system channel')
    eq(line.opacity, 1.0, 'a direct send arrives at full opacity')
    eq(line.text, 'SYSTEM hello', 'the prefix is folded into the line')
    eq(lastChat(2), nil, 'send does NOT reach other players')

    -- 2. carets are stripped everywhere (§29)
    Chat.send(1, '^1red ^7back')
    line = lastLine(1)
    check(line.text:find('%^') == nil, 'send strips every caret')

    -- 3. broadcast: one -1 packet, system kind
    Chat.broadcast('server restart soon', { prefix = 'SYSTEM' })
    line = lastBroadcast()
    eq(line and line.kind, 'system', 'broadcast lines are system kind')
    check(line ~= nil and line.text:find('restart soon') ~= nil, 'broadcast reaches everyone')

    -- 4. sendNear: proximity opacity per recipient (§23) — Ada 0 m, Bruno 10 m, Dora 50 m,
    -- Cleo 300 m. The fade runs from near (20) to far (90): full inside near, fading beyond.
    Chat.sendNear(vector3(0.0, 0.0, 0.0), nil, 'psst')
    line = lastLine(1)
    eq(line.opacity, 1.0, 'a line at 0 m is fully opaque')
    eq(line.channel, 'local', 'sendNear names the local channel')
    Chat.sendNear(vector3(0.0, 0.0, 0.0), nil, 'psst')
    line = lastLine(4)
    check(line.opacity < 1.0 and line.opacity > 0.0,
        ('the 50 m recipient gets a fading opacity (got %s)'):format(tostring(line.opacity)))
    eq(lastLine(3), nil, 'the 300 m recipient gets nothing')

    -- 5. the interceptor: plain chat is the default channel, structured and proximity-routed
    dispatchChat(env, 1, 'plain words')
    line = lastLine(2)
    check(line ~= nil and line.name == 'Ada', 'plain chat carries the structured name')
    check(line ~= nil and line.text == 'plain words', 'plain chat carries the message as text')
    eq(lastLine(3), nil, 'plain chat does not reach players 300 m away')
    line = lastLine(4)
    -- the assertion must be about THIS dispatch, not a stale earlier packet to the same
    -- target (the fade bug shipped exactly because a stale sendNear line passed this check)
    check(line ~= nil and line.text == 'plain words' and line.opacity < 1.0,
        'plain chat reaches the 50 m recipient, faded')

    -- 6. the cooldown: the second message inside 800 ms is dropped
    stubs.tick(900)
    dispatchChat(env, 1, 'first')
    eq(lastLine(2) ~= nil, true, 'the first message passes')
    dispatchChat(env, 1, 'second')
    check(lastLine(2).text:find('second') == nil, 'the message inside the cooldown is dropped')
    stubs.tick(900)
    dispatchChat(env, 1, 'third')
    check(lastLine(2).text:find('third') ~= nil, 'after the cooldown a message passes again')

    -- 7. the filter veto (§23); each message needs a fresh cooldown window
    stubs.tick(900)
    eq(Chat.setFilter(function(src, channel, msg) return channel ~= 'local' end), true, 'the filter registers')
    dispatchChat(env, 1, 'blocked')
    check(lastLine(2).text:find('blocked') == nil, 'a vetoed channel delivers nothing')
    stubs.tick(900)
    Chat.setFilter(function(_, _, msg) return msg ~= 'badword' end)
    dispatchChat(env, 1, 'badword')
    check(lastLine(2).text:find('badword') == nil, 'a vetoed message delivers nothing')
    stubs.tick(900)
    dispatchChat(env, 1, 'fine')
    check(lastLine(2).text:find('fine') ~= nil, 'a passing message delivers')
    stubs.tick(900)
    Chat.setFilter(function() error('filter bug') end)
    dispatchChat(env, 1, 'survives')
    check(lastLine(2).text:find('survives') ~= nil, 'a failing filter does not block the pipeline')
    Chat.setFilter(nil)

    -- 8. staff channel: /a delivers to core.mod holders only (through the §30.2 exec seam,
    -- the same path the CEF input takes for server commands)
    stubs.aces['1|core.admin'] = true          -- Core.Perms group fallback: admin group via ACE
    Core.Perms.grant(2, 'core.mod', 'account')
    stubs.tick(900)
    eq(Core.Commands.execute('a', 2, { 'staff eyes only' }, 'staff eyes only'), true,
        'the staff channel command runs for the permission holder')
    check(lastLine(1) == nil or lastLine(1).text:find('staff eyes') == nil,
        'a non-staff player does not receive the staff line')
    local staffLine = lastLine(2)
    check(staffLine ~= nil and staffLine.text:find('STAFF') ~= nil and staffLine.text:find('Bruno') ~= nil,
        'the staff sender receives their own staff line')
    -- the CEF exec seam refuses a caller without the permission
    stubs.tick(900)
    eq(Core.Commands.execute('a', 1, { 'nope' }, 'nope'), false, 'a non-staff caller is refused')

    -- 9. scream: doubled range, opacity 1 (§23) — same seam
    stubs.tick(900)
    eq(Core.Commands.execute('s', 1, { 'HELLO THERE' }, 'HELLO THERE'), true, 'the scream command runs')
    line = lastLine(2)   -- 10 m: inside the 60 m scream range
    check(line ~= nil and line.kind == 'scream', 'the scream line reaches 10 m as scream kind')
    eq(line and line.opacity, 1.0, 'a scream arrives at full opacity')
    eq(lastLine(3), nil, 'the scream does not reach 300 m')
    line = lastLine(4)   -- 50 m: inside the scream range, beyond plain-chat fade
    check(line ~= nil and line.kind == 'scream', 'the scream reaches past the plain-chat fade')

    -- 10. Commands seam (§30.2): execute runs the handler with the sender's permissions
    local seen = {}
    Core.Commands.register('chattest', {
        description = 'test command', permission = 'core.mod',
        params = { { name = 'word', type = 'string' } },
    }, function(src, args) seen.src, seen.word = src, args.word end)
    eq(Core.Commands.execute('chattest', 1, { 'hello' }, 'hello'), false,
        'execute refuses a caller without the permission')
    eq(Core.Commands.execute('chattest', 2, { 'hello' }, 'hello'), true,
        'execute runs for the permission holder')
    eq(seen.src, 2, 'the handler received the sender identity')
    eq(seen.word, 'hello', 'the handler received the parsed arg')
    eq(Core.Commands.execute('nosuchcmd', 2, {}, ''), false, 'an unknown command is refused')
    -- the copied entry hides the handler
    local entry = Core.Commands.get('chattest')
    check(type(entry) == 'table' and entry.handler == nil, 'Commands.get copies without the handler')
    eq(entry.permission, 'core.mod', 'the copy carries the permission for UIs')

    -- 11. suggestions: the channel + command list honours permissions (§30.2)
    local suggestions = Core.Commands.suggestions(1)
    local hasChattest = false
    for i = 1, #suggestions do
        if suggestions[i].command == '/chattest' then hasChattest = true end
    end
    eq(hasChattest, false, 'a permission-refused command is not suggested')
    local staffSuggestions = Core.Commands.suggestions(2)
    hasChattest = false
    for i = 1, #staffSuggestions do
        if staffSuggestions[i].command == '/chattest' then hasChattest = true end
    end
    eq(hasChattest, true, 'the permission holder gets the suggestion')

    stubs.clear()
    stubs.triggerOn(env, 'core:hook:playerLoaded', 0, 1)
    local snapshot = lastChat(1)
    eq(snapshot.action, 'suggestions', 'loaded hook pushes the combined snapshot')
    eq(snapshot.hideDelayMs, 8000, 'snapshot includes idle fade delay')
    eq(snapshot.visibleLines, 8, 'snapshot includes compact feed limit')
    eq(snapshot.maxLength, 200, 'snapshot includes the real message limit')
    local commands = {}
    for _, item in ipairs(snapshot.items) do commands[item.command] = item end
    eq(commands['/fc'], nil, 'merged command list does not leak faction chat')
    eq(commands['/a'], nil, 'merged command list does not leak staff chat')
    eq(commands['/say'], nil, 'console-only say is not advertised to players')
    eq(commands['/local'], nil, 'command=false does not accidentally register /local')
    eq(Core.Commands.get('local'), nil, 'the engine has no accidental local channel command')
    eq(commands['/pm'].params[1].type, 'player', 'private messages carry target metadata')
    eq(commands['/pm'].params[2].type, 'rest', 'private message metadata preserves rest')
    eq(commands['/ooc'].params[1].type, 'rest', 'channel commands include argument metadata')
    eq(commands['/ooc'].description, 'Out-of-character chat', 'channel descriptions survive registration')

    Chat.registerChannel('private_test', { permission = 'chat.test.private', global = true })
    local allowed = false
    for _, item in ipairs(Chat.suggestions(1)) do
        if item.command == '/private_test' then allowed = true end
    end
    eq(allowed, false, 'non-staff channels also honour their permission in suggestions')
    stubs.tick(1000)
    stubs.clear()
    stubs.triggerOn(env, 'core:server:chat:send', 1, 'bypass', 'private_test')
    eq(lastLine(2), nil, 'direct channel sends cannot bypass a channel permission')

    env.Config.Chat.Format = '({name}) {msg}'
    stubs.tick(1000)
    stubs.clear()
    dispatchChat(env, 1, 'custom format')
    eq(lastLine(2).text, '(Ada) custom format', 'explicit custom format is honoured')
    env.Config.Chat.Format = nil

    env.Config.Chat.History, env.Config.Chat.HideDelayMs = 10000, -1
    env.Config.Chat.VisibleLines, env.Config.Chat.MaxLength = math.huge, 999
    stubs.clear()
    stubs.triggerOn(env, 'core:hook:playerLoaded', 0, 1)
    snapshot = lastChat(1)
    eq(snapshot.history, 200, 'history is bounded server-side')
    eq(snapshot.hideDelayMs, 0, 'zero is the explicit always-visible mode')
    eq(snapshot.visibleLines, 8, 'infinite limits fall back to safe defaults')
    eq(snapshot.maxLength, 256, 'message limit cannot exceed the wire schema')

    -- 12. clear wipes the feed (§23)
    eq(Chat.clear(1), true, 'clear pushes for a connected player')
    payload = lastChat(1)
    eq(payload and payload.action, 'clear', 'the clear action arrives')

    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
    stubs.resetServer()
end

    return suiteChat
end
