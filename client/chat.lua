--[[
    core/client/chat.lua — event-driven CEF chat bridge (DESIGN §23, §30.3).
    UI owns keyboard focus; server owns messages, channels and permissions. Commands
    use CLIENT ExecuteCommand without the slash, preserving the player's identity.
    GTA's native chat is disabled while core runs; the separate stock `chat` NUI must
    be removed from startup. No control polling or per-frame suppression.

    Natives verified with fxref 2026-09-13: ExecuteCommand (shared),
    SetTextChatEnabled (client), DisableMultiplayerChat (client), GetCurrentResourceName (shared).
    Runtime helpers: SendNUIMessage, RegisterNUICallback, TriggerServerEvent, AddEventHandler.
]]

local UI = Core.UI
local MAX_TEXT <const> = 256
local snapshot = { action = 'chat:suggestions', items = {} }
local providers = {}

local function publishSuggestions()
    local message = {}
    for key, value in pairs(snapshot) do message[key] = value end
    message.items = {}
    for _, item in ipairs(snapshot.items) do message.items[#message.items + 1] = item end
    for _, items in pairs(providers) do
        for _, item in ipairs(items) do message.items[#message.items + 1] = item end
    end
    SendNUIMessage(message)
end

local function providerSuggestions(side, owner, items)
    if type(owner) ~= 'string' or owner == '' or type(items) ~= 'table' then return end
    local id = side .. ':' .. owner
    providers[id] = items
    Core.Registry.track('chatSuggestions', id, owner)
    publishSuggestions()
end

Core.Registry.onOwnerStop('chatSuggestions', function(id)
    providers[id] = nil
    Core.Registry.untrack('chatSuggestions', id)
    publishSuggestions()
end)
Core.on('chatSuggestions', function(owner, items)
    providerSuggestions('client', owner, items)
end)

local function refreshSuggestions()
    Core.emitHook('chatSuggestionsRequested')
    TriggerServerEvent('core:server:chat:suggestions')
end

local function suppressNativeChat()
    SetTextChatEnabled(false)
    DisableMultiplayerChat(true)
end
suppressNativeChat()

Core.Net.on('core:client:chat', { 'table' }, function(payload)
    if payload.action == 'add' and type(payload.line) == 'table' then
        SendNUIMessage({ action = 'chat:add', line = payload.line })
    elseif payload.action == 'clear' then
        SendNUIMessage({ action = 'chat:clear' })
    elseif payload.action == 'suggestions' then
        -- A fresh server snapshot starts a new round; removed/revoked providers cannot linger.
        for id in pairs(providers) do
            if id:sub(1, 7) == 'server:' then
                providers[id] = nil
                Core.Registry.untrack('chatSuggestions', id)
            end
        end
        snapshot = {
            action = 'chat:suggestions',
            items = type(payload.items) == 'table' and payload.items or {},
            channels = payload.channels,
            history = payload.history,
            hideDelayMs = payload.hideDelayMs,
            visibleLines = payload.visibleLines,
            maxLength = payload.maxLength,
        }
        publishSuggestions()
    elseif payload.action == 'commandSuggestions' then
        providerSuggestions('server', payload.owner, payload.items)
    end
end)

local function setTyping(open)
    if open and (UI.isHidden() or (UI.isFocused() and not UI['chat.isTyping']())) then return false end
    UI['chat.setTyping'](open)
    return true
end

-- Exactly one re-seed; page/modal focus must never be mistaken for chat typing.
Core.on('uiReady', function()
    suppressNativeChat()
    SendNUIMessage({ action = 'chat:open', open = UI['chat.isTyping']() })
    refreshSuggestions()
end)

Core.on('uiVisibility', function(visible)
    if not visible then
        UI['chat.setTyping'](false)
        SendNUIMessage({ action = 'chat:open', open = false })
    end
end)

RegisterNUICallback('chat_focus', function(data, cb)
    local open = type(data) == 'table' and data.open == true
    cb({ ok = setTyping(open) }) -- no echo: a stale open echo could race Escape/hide
end)

RegisterNUICallback('chat_send', function(data, cb)
    local text = type(data) == 'table' and data.text or nil
    local channel = type(data) == 'table' and data.channel or nil
    if type(text) ~= 'string' or not text:find('%S') or #text > MAX_TEXT then
        cb({ ok = false })
        return
    end
    if type(channel) ~= 'string' or channel == '' or #channel > 32 then channel = 'local' end
    TriggerServerEvent('core:server:chat:send', text, channel)
    cb({ ok = true })
end)

RegisterNUICallback('chat_command', function(data, cb)
    local raw = type(data) == 'table' and data.raw or nil
    if type(raw) ~= 'string' or #raw > 512 or raw:find('[%c]') then
        cb({ ok = false })
        return
    end
    raw = raw:match('^%s*(.-)%s*$'):gsub('^/', '', 1)
    if raw == '' or raw:sub(1, 1) == '/' then cb({ ok = false }); return end
    cb({ ok = true })
    ExecuteCommand(raw)
end)

Core.Keys.register({
    name = 'chat', description = 'Open chat', key = 'T',
    onPress = function()
        if not setTyping(true) then return end
        SendNUIMessage({ action = 'chat:open', open = true })
        refreshSuggestions()
    end,
})

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    UI['chat.setTyping'](false)
    SetTextChatEnabled(true)
    DisableMultiplayerChat(false)
end)
