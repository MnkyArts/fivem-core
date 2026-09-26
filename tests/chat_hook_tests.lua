--[[
    core/tests/chat_hook_tests.lua — the `chat:beforeMessage` veto of server/chat.lua (Core.Hooks, §40; used by
    the admin plugin's mute).

        lua5.4 tests/chat_hook_tests.lua    (from the resource directory, or from tests/)

    Also the review fixes R2-5 (the channel permission runs before the cooldown, filter and hooks) and R2-4
    (global / staff lines packed once through Net.emitMany, the staff route = Core.Admin's staff set, join/leave
    lines per Config.Chat.JoinLeave 'staff' | 'all' | 'off').

    Proves: no hook = every path delivers; a veto blocks the default channel, the CEF send, a channel command,
    /s and /pm, tells the sender the veto's reason (never a Hooks-internal code) and nobody else; the payload is
    { src, channel, text }; setFilter still vetoes first (the hook is not asked then); a failing hook fails
    closed; removing the hook restores delivery. Exit code 1 on failure.
]]

local here = (arg and arg[0] or 'tests/chat_hook_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local vector3 = stubs.vector3

local passed, failed, failures = 0, 0, {}

local function check(cond, label, detail)
    if cond then
        passed = passed + 1
        return true
    end
    failed = failed + 1
    failures[#failures + 1] = label .. (detail and (' -- ' .. detail) or '')
    return false
end

local function eq(actual, expected, label)
    return check(actual == expected, label, ('expected %s, got %s'):format(tostring(expected), tostring(actual)))
end

-- the same server VM as server_tests.lua's chat suite (manifest order, missing files skipped)
local SERVER_FILES <const> = {
    'shared/ui_forms.lua', 'server/api.lua', 'shared/hooks.lua', 'server/db.lua', 'server/db_mysql.lua',
    'server/globals.lua', 'server/notify.lua', 'server/perms.lua', 'server/player.lua', 'server/playergrid.lua',
    'server/money.lua', 'server/factions.lua', 'server/vehicles.lua', 'server/chat.lua',
}

stubs.resetServer()
stubs.newWorld()
stubs.clear()
stubs.tick(1000)
local env = stubs.newEnv('server', 'core')
stubs.loadImport(env)
stubs.loadFile(env, 'shared/config.lua')
for i = 1, #SERVER_FILES do
    if stubs.readFile(stubs.root .. '/' .. SERVER_FILES[i]) then stubs.loadFile(env, SERVER_FILES[i]) end
end
local Core = env.Core
local Chat, Hooks = Core.Chat, Core.Hooks
if not check(type(Chat) == 'table' and type(Hooks) == 'table', 'Core.Chat and Core.Hooks are installed') then
    print(('%d passed, %d failed'):format(passed, failed))
    os.exit(1)
end

stubs.connectPlayer(env, 1, { name = 'Ada', coords = vector3(0.0, 0.0, 0.0) })
stubs.connectPlayer(env, 2, { name = 'Bruno', coords = vector3(10.0, 0.0, 0.0) })

--- Every core:client:chat line pushed to `target` since the last stubs.clear().
local function linesTo(target)
    local out = {}
    for i = 1, #stubs.sent do
        local s = stubs.sent[i]
        if s.name == 'core:client:chat' and s.target == target and s.args[1].action == 'add' then
            out[#out + 1] = s.args[1].line
        end
    end
    return out
end

local function received(target, needle)
    local lines = linesTo(target)
    for i = 1, #lines do
        if lines[i].text:find(needle, 1, true) then return lines[i] end
    end
    return nil
end

--- One message on a fresh cooldown window and a fresh send log.
local function fresh()
    stubs.tick(1000)
    stubs.clear()
end

local function say(src, text) stubs.triggerOn(env, 'chatMessage', src, src, 'x', text) end
local function cef(src, text, channel) stubs.triggerOn(env, 'core:server:chat:send', src, text, channel) end
local function command(name, src, args, raw) return Core.Commands.execute(name, src, args, raw) end

-- 1. no hook registered: every path delivers
fresh()
say(1, 'hello bruno')
check(received(2, 'hello bruno') ~= nil, 'without a hook the default channel delivers')

-- 2. a veto for player 1 only, with a reason
local seen = {}
local handle = Hooks.register('chat:beforeMessage', function(payload)
    seen[#seen + 1] = payload
    if payload.src == 1 then return false, 'You are muted for 10 minutes.' end
    return true
end)
check(type(handle) == 'string', 'the hook registers')

fresh()
say(1, 'muted words')
eq(received(2, 'muted words'), nil, 'a vetoed message reaches nobody')
local notice = received(1, 'You are muted for 10 minutes.')
check(notice ~= nil, 'the sender is told the veto reason')
eq(notice and notice.kind, 'system', 'the refusal is a system line')
eq(received(1, 'muted words'), nil, 'the sender does not see the message as sent')
local last = seen[#seen]
eq(last and last.src, 1, 'payload.src')
eq(last and last.channel, 'local', 'payload.channel')
eq(last and last.text, 'muted words', 'payload.text')

fresh()
say(2, 'free words')
check(received(1, 'free words') ~= nil, 'another player still chats')

fresh()
cef(1, 'via the input', 'local')
eq(received(2, 'via the input'), nil, 'the CEF send path is vetoed')

fresh()
cef(1, 'ooc words', 'ooc')
eq(received(2, 'ooc words'), nil, 'a global channel is vetoed')
eq(seen[#seen].channel, 'ooc', 'the channel name reaches the hook')

fresh()
command('ooc', 1, { 'ooc command' }, 'ooc command')
eq(received(2, 'ooc command'), nil, 'a channel command is vetoed')

fresh()
command('s', 1, { 'SCREAM' }, 'SCREAM')
eq(received(2, 'SCREAM'), nil, 'a scream is vetoed')
eq(seen[#seen].channel, 'scream', 'scream channel name')

fresh()
command('pm', 1, { '2', 'secret' }, '2 secret')
eq(received(2, 'secret'), nil, 'a private message is vetoed')
eq(seen[#seen].channel, 'pm', 'pm channel name')
check(received(1, 'You are muted') ~= nil, 'the pm sender is told too')

-- 3. setFilter vetoes first: the hook is not asked
fresh()
local asked = #seen
Chat.setFilter(function(_, _, msg) return msg ~= 'filtered' end)
say(2, 'filtered')
eq(#seen, asked, 'a filter veto short-circuits the hook')
eq(received(1, 'filtered'), nil, 'the filtered message is not delivered')
eq(#linesTo(2), 0, 'a filter veto sends the sender nothing (unchanged behaviour)')
Chat.setFilter(nil)

-- 4. a bare veto and a failing hook: generic text, never a Hooks code
Hooks.remove(handle)
local bare = Hooks.register('chat:beforeMessage', function() return false end)
fresh()
say(1, 'bare veto')
eq(received(2, 'bare veto'), nil, 'a bare veto blocks')
check(received(1, 'Your message was not sent.') ~= nil, 'a bare veto shows the generic text')
eq(received(1, 'veto'), nil, "the code 'veto' is never shown")
Hooks.remove(bare)

local broken = Hooks.register('chat:beforeMessage', function() error('mute lookup exploded') end)
fresh()
say(1, 'broken hook')
eq(received(2, 'broken hook'), nil, 'a failing hook fails closed (Hooks contract)')
check(received(1, 'Your message was not sent.') ~= nil, 'the failing hook shows the generic text')
eq(received(1, 'callback_error'), nil, 'callback_error is never shown')
Hooks.remove(broken)

-- 5. no hook again: delivery is back
fresh()
say(1, 'back again')
check(received(2, 'back again') ~= nil, 'removing the hook restores delivery')

-- 6. R2-5: the channel permission runs first — a refused channel never reaches the hooks, the filter or the cooldown
local permHandle = Hooks.register('chat:beforeMessage', function(payload)
    seen[#seen + 1] = payload
    if payload.src == 1 then return false, 'You are muted for 10 minutes.' end
    return true
end)
fresh()
local askedBefore = #seen
cef(2, 'sneaky staff line', 'a')
eq(#seen, askedBefore, 'a channel the sender may not use never reaches the veto hooks')
cef(1, 'muted and not staff', 'a')
eq(#seen, askedBefore, 'not even for a muted sender')
eq(received(1, 'You are muted'), nil, 'who then gets no mute text for a channel they cannot use')
stubs.clear()
say(2, 'right after the refused line')
check(received(1, 'right after the refused line') ~= nil, 'a refused channel does not stamp the cooldown')
Hooks.remove(permHandle)

-- 7. R2-4: global, staff and faction lines are packed once; the staff route is Core.Admin's staff set
stubs.connectPlayer(env, 3, { name = 'Cleo', coords = vector3(3000.0, 0.0, 0.0) })
local packs, internal = 0, {}
env.msgpack = { pack_args = function(...) packs = packs + 1 return 'packed', select('#', ...) end }
env.TriggerClientEventInternal = function(name, target) internal[#internal + 1] = { name = name, target = target } end
fresh()
cef(1, 'ooc to everyone', 'ooc')
eq(packs, 1, 'an ooc line is packed once')
eq(#internal, 3, 'and addressed to each of the 3 loaded players')
local broadcasts = 0
for i = 1, #internal do
    if internal[i].target == -1 then broadcasts = broadcasts + 1 end
end
for i = 1, #stubs.sent do
    if stubs.sent[i].target == -1 then broadcasts = broadcasts + 1 end
end
eq(broadcasts, 0, 'never as a -1 broadcast')
eq(internal[1] and internal[1].name, 'core:client:chat', 'the chat event')
env.msgpack, env.TriggerClientEventInternal = nil, nil

rawset(Core, 'Admin', { staff = function() return { 2 } end })
Core.Perms.grant(2, 'core.mod', 'account')
Core.Perms.grant(3, 'core.mod', 'account')
fresh()
eq(command('a', 2, { 'staff only' }, 'staff only'), true, 'a staff member uses /a')
check(received(2, 'staff only') ~= nil, 'the staff set member holding the perm receives it')
eq(received(3, 'staff only'), nil, 'a perm holder outside the staff set does not (the set is the route)')
eq(received(1, 'staff only'), nil, 'a player does not')

-- 8. join/leave lines: Config.Chat.JoinLeave
local function joinLine(target, needle)
    local line = received(target, needle)
    return line ~= nil and line.kind == 'system'
end
local function broadcastWith(needle)
    for i = 1, #stubs.sent do
        local s = stubs.sent[i]
        if s.name == 'core:client:chat' and s.target == -1 and s.args[1].line.text:find(needle, 1, true) then return true end
    end
    return false
end
rawset(Core, 'Admin', { staff = function() return { 2, 5 } end })
env.Config.Chat.JoinLeave = nil
fresh()
stubs.connectPlayer(env, 5, { name = 'Eve', coords = vector3(5.0, 0.0, 0.0) })
check(joinLine(2, 'Eve joined'), "default 'staff': the staff see the join line")
eq(received(1, 'Eve joined'), nil, 'a player does not')
eq(broadcastWith('Eve joined'), false, 'no -1 broadcast')
fresh()
stubs.triggerOn(env, 'playerDropped', 5, 'Exiting')
check(joinLine(2, 'Eve left'), 'the staff see the leave line')
eq(received(5, 'Eve left'), nil, 'never the leaving player itself')
eq(received(1, 'Eve left'), nil, 'nor a player')
env.Config.Chat.JoinLeave = 'all'
fresh()
stubs.connectPlayer(env, 6, { name = 'Finn', coords = vector3(6.0, 0.0, 0.0) })
check(broadcastWith('Finn joined'), "'all': one -1 broadcast")
env.Config.Chat.JoinLeave = 'off'
fresh()
stubs.triggerOn(env, 'playerDropped', 6, 'Exiting')
eq(#linesTo(2) + #linesTo(-1), 0, "'off': no line at all")
env.Config.Chat.JoinLeave = 'everyone'
fresh()
stubs.connectPlayer(env, 7, { name = 'Gus', coords = vector3(7.0, 0.0, 0.0) })
check(joinLine(2, 'Gus joined') and not broadcastWith('Gus joined'), 'an unknown value falls back to staff')
env.Config.Chat.JoinLeave = 'staff'
rawset(Core, 'Admin', nil)

eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')
stubs.resetServer()

print(('chat hook: %d passed, %d failed'):format(passed, failed))
if failed > 0 then
    for i = 1, #failures do print('  FAIL ' .. failures[i]) end
    os.exit(1)
end
