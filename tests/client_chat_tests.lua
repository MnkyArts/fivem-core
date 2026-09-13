-- Offline lifecycle/transport tests for client/chat.lua; no GTA runtime required.
local here = (arg[0]:match('^(.*)/') or '.')
local stubs = dofile(here .. '/stubs.lua')
local env = stubs.newEnv('client', 'core')
local hooks, callbacks, handlers, messages, commands, nativeCalls = {}, {}, {}, {}, {}, {}
local owners, removers = {}, {}
local typing, hidden, pageFocus, binding = false, false, false, nil
local passed = 0
local function eq(actual, expected, label)
    assert(actual == expected, label .. ': expected ' .. tostring(expected) .. ', got ' .. tostring(actual))
    passed = passed + 1
end
local function hook(name, ...)
    for _, fn in ipairs(hooks[name] or {}) do fn(...) end
end
local function nui(name, data)
    local result
    callbacks[name](data, function(value) result = value end)
    return result
end

env.Core = {
    UI = {
        isHidden = function() return hidden end,
        isFocused = function() return pageFocus or typing end,
        ['chat.isTyping'] = function() return typing end,
        ['chat.setTyping'] = function(open) typing = open end,
    },
    Net = { on = function(name, _, fn) handlers[name] = fn end },
    Keys = { register = function(opts) binding = opts end },
    Registry = {
        track = function(_, id, owner) owners[id] = owner end,
        untrack = function(_, id) owners[id] = nil end,
        onOwnerStop = function(kind, fn) removers[kind] = fn end,
    },
    on = function(name, fn)
        hooks[name] = hooks[name] or {}
        hooks[name][#hooks[name] + 1] = fn
    end,
    emitHook = hook,
}
env.RegisterNUICallback = function(name, fn) callbacks[name] = fn end
env.SendNUIMessage = function(message) messages[#messages + 1] = message end
env.ExecuteCommand = function(raw) commands[#commands + 1] = raw end
env.SetTextChatEnabled = function(value) nativeCalls.text = value end
env.DisableMultiplayerChat = function(value) nativeCalls.disabled = value end
stubs.loadFile(env, 'client/chat.lua')

eq(nativeCalls.text, false, 'startup disables native text chat')
eq(nativeCalls.disabled, true, 'startup closes GTA multiplayer chat')
eq(#hooks.uiReady, 1, 'only one uiReady listener')
pageFocus = true
hook('uiReady')
eq(messages[#messages].open, false, 'uiReady does not turn page focus into chat focus')
eq(nui('chat_focus', { open = true }).ok, false, 'page focus refuses chat')
eq(typing, false, 'a refusal does not hold the keyboard')
pageFocus, hidden = false, true
binding.onPress()
eq(typing, false, 'T cannot open a hidden shell')
eq(nui('chat_focus', { open = true }).ok, false, 'NUI cannot open a hidden shell')
hidden = false
binding.onPress()
eq(typing, true, 'T immediately takes keyboard focus')
eq(messages[#messages].open, true, 'T opens the shell input')
hook('uiVisibility', false)
eq(typing, false, 'visibility loss releases the keyboard')
eq(messages[#messages].open, false, 'visibility loss closes the input')
nui('chat_focus', { open = true })
local count = #messages
nui('chat_focus', { open = false })
eq(typing, false, 'Escape releases focus')
eq(#messages, count, 'focus callback does not send racing state echoes')

eq(nui('chat_command', { raw = '/pm 12 hello there' }).ok, true, 'valid command accepted')
eq(commands[1], 'pm 12 hello there', 'ExecuteCommand receives no leading slash')
nui('chat_command', { raw = '  /car "police car"  ' })
eq(commands[2], 'car "police car"', 'command arguments and quoting survive')
for _, raw in ipairs({ '/', '//say nope', '/id\nquit', string.rep('x', 513) }) do
    eq(nui('chat_command', { raw = raw }).ok, false, 'bad command rejected')
end
eq(#commands, 2, 'malformed commands never execute')
eq(nui('chat_send', { text = '   ' }).ok, false, 'empty message rejected')
eq(nui('chat_send', { text = string.rep('x', 257) }).ok, false, 'oversized message rejected')
eq(nui('chat_send', { text = 'hello', channel = 'local' }).ok, true, 'ordinary message accepted')
local sent = stubs.sent[#stubs.sent]
eq(sent.name, 'core:server:chat:send', 'messages use the validated server event')
eq(sent.args[2], 'local', 'selected channel is forwarded')

local receive = handlers['core:client:chat']
receive({ action = 'suggestions', items = { { command = '/pm' } }, history = 40, hideDelayMs = 2000, maxLength = 100 })
eq(messages[#messages].hideDelayMs, 2000, 'UI receives server fade configuration')
eq(messages[#messages].maxLength, 100, 'UI receives server message limit')
receive({ action = 'commandSuggestions', owner = 'plugin', items = { { command = '/plugin' } } })
eq(#messages[#messages].items, 2, 'plugin commands merge with core commands')
eq(owners['server:plugin'], 'plugin', 'provider is Registry-owned')
removers.chatSuggestions('server:plugin')
eq(#messages[#messages].items, 1, 'owner stop removes plugin suggestions')
eq(owners['server:plugin'], nil, 'owner stop untracks provider')
receive({ action = 'commandSuggestions', owner = 'plugin', items = { { command = '/old' } } })
receive({ action = 'suggestions', items = {} })
eq(#messages[#messages].items, 0, 'snapshot refresh removes stale server providers')
hook('chatSuggestions', 'local_plugin', { { command = '/local_test' } })
eq(messages[#messages].items[1].command, '/local_test', 'client VM commands join the same list')
eq(owners['client:local_plugin'], 'local_plugin', 'client VM suggestions are owned too')

stubs.triggerOn(env, 'onResourceStop', 0, 'other')
eq(nativeCalls.text, false, 'unrelated stop does not restore GTA chat')
stubs.triggerOn(env, 'onResourceStop', 0, 'core')
eq(nativeCalls.text, true, 'core stop restores native text chat')
eq(nativeCalls.disabled, false, 'core stop restores multiplayer chat')
eq(typing, false, 'core stop releases chat focus')
print(('client chat: %d passed, 0 failed'):format(passed))
