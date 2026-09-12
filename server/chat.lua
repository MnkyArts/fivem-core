--[[
    core/server/chat.lua — Core.Chat (DESIGN §23), the chat layer over the default `chat` resource.

    The stock chat resource triggers `chatMessage (source, name, message)` as ARGUMENTS and only sends its
    own `chat:addMessage` when that event was not cancelled (system_resources/chat/sv_chat.lua:187). Core
    therefore cancels every `chatMessage` and re-broadcasts the line in its own format, with the sanitizing,
    per-src cooldown, filter veto and proximity routing below.

        Chat.send(src, message, opts?)             opts = { color = {r,g,b}, prefix = 'SYSTEM', multiline = false }
        Chat.broadcast(message, opts?)             announcements only — one call fans out to every client
        Chat.sendNear(coords, range, message, opts?) -> count
        Chat.registerChannel(name, { command, permission, format, global, staffOnly?, color?, range?, description? })
        Chat.setFilter(fn(src, channel, msg) -> bool)   -- return false to veto a message

    Formats understand {tag} (faction tag, '[TST] '), {name}, {id} and {msg}. Built-in channels: ooc, me,
    a (staff, permission core.mod, delivered to staff only) and /pm <id> <message>.
    Hook: `chatMessage (src, channel, msg)` fires once a message passed the filter, before delivery.

    Natives (verified with fxref 2026-09-12): CancelEvent (shared), GetGameTimer (server row),
    GetPlayerName(playerSrc) (server row). Everything else goes through Core.Player / Core.Perms / Core.Factions.
]]

local Chat = {}
Core.Chat = Chat

local Utils = Core.Utils

local MAX_SRC <const> = 4096
local MAX_NAME <const> = 32
local MAX_PREFIX <const> = 32
local MAX_OUTPUT <const> = 1024          -- a formatted line: {tag}{name} ({id}): {msg} plus config prefix
local MAX_RANGE <const> = 500.0
local STAFF_PERM <const> = 'core.mod'
local DEFAULT_COLOR <const> = { 255, 255, 255 }
local SYSTEM_COLOR <const> = { 200, 90, 90 }
local PM_COLOR <const> = { 190, 140, 240 }
local DEFAULT_FORMAT <const> = '{name}: {msg}'
local PM_IN_FORMAT <const> = '(PM from {name} [{id}]): {msg}'
local PM_OUT_FORMAT <const> = '(PM to {name} [{id}]): {msg}'

local channels = {}        -- [name] = { name, command, permission, format, global, staffOnly, color, range }
local lastMessage = {}     -- [src] = GetGameTimer() of the last accepted message (cleared in playerDropped)
local filter               -- Core.Chat.setFilter

--------------------------------------------------------------------------------
-- Config and small helpers
--------------------------------------------------------------------------------

--- One tunable from Config.Chat (§28), falling back to `default` when unset or of the wrong shape.
local function setting(key, default)
    local chat = Config.Chat
    local value = type(chat) == 'table' and chat[key] or nil
    if value == nil or type(value) ~= type(default) then return default end
    return value
end

local function maxLength()
    return math.max(1, math.floor(setting('MaxLength', 200)))
end

local function cooldownMs()
    return math.max(0, math.floor(setting('CooldownMs', 800)))
end

local function proximityRange()
    return math.min(MAX_RANGE, math.max(1.0, setting('ProximityRange', 20.0) + 0.0))
end

local function toSrc(value)
    if type(value) ~= 'number' or value ~= value then return nil end
    local n = math.floor(value)
    if n < 1 or n > MAX_SRC then return nil end
    return n
end

local function toVector3(value)
    if type(value) == 'vector3' then return value end
    if type(value) == 'table' and Utils.isNumber(value.x) and Utils.isNumber(value.y)
        and Utils.isNumber(value.z) then
        return vector3(value.x + 0.0, value.y + 0.0, value.z + 0.0)
    end
    return nil
end

--- Strips every caret first (they survive Utils.sanitize, which only removes control chars), then
--- sanitizes and cuts to `maxLen`. Returns nil for anything that ends up empty.
--- A single `%^%d` pass would be a colour-code bypass: gsub does not rescan what it skipped, so
--- '^^11' comes out as the perfectly valid '^1'. Carets have no use in a chat line, so all of them go.
--- Every outbound line, prefix and config-driven format reaches the client through here (buildPayload).
local function cleanText(value, maxLen)
    if type(value) ~= 'string' and type(value) ~= 'number' then return nil end
    local text = tostring(value):gsub('%^', '')
    text = Utils.sanitize(text, maxLen)
    if text == '' then return nil end
    return text
end

local function normalizeColor(value)
    if type(value) ~= 'table' then return nil end
    local out = {}
    for i = 1, 3 do
        local channel = value[i]
        if type(channel) ~= 'number' or channel ~= channel then return nil end
        out[i] = math.min(255, math.max(0, math.floor(channel)))
    end
    return out
end

local function nameOf(src)
    local name = Core.Player.getName(src)
    if type(name) ~= 'string' or name == '' then name = GetPlayerName(src) end
    if type(name) ~= 'string' or name == '' then return 'Unknown' end
    return Utils.sanitize(name, MAX_NAME)
end

--- '[TST] ' from the session's faction summary, '' when the player is in no faction.
local function tagOf(src)
    local factions = Core.Factions
    if type(factions) ~= 'table' or type(factions.getPlayerFaction) ~= 'function' then return '' end
    local faction = factions.getPlayerFaction(src)
    local tag = type(faction) == 'table' and faction.tag or nil
    if type(tag) ~= 'string' or tag == '' then return '' end
    return ('[%s] '):format(Utils.sanitize(tag, 8))
end

--- Replaces {tag}/{name}/{id}/{msg}. The function form of gsub is deliberate: it inserts the replacement
--- literally, so a `%` in a player's message can never be read as a capture reference.
local function applyFormat(fmt, fields)
    if type(fmt) ~= 'string' or fmt == '' then fmt = DEFAULT_FORMAT end
    local line = fmt:gsub('{(%w+)}', function(key)
        local value = fields[key]
        if value == nil then return '' end
        return tostring(value)
    end)
    return line
end

--------------------------------------------------------------------------------
-- Delivery (DESIGN §23: TriggerClientEvent('chat:addMessage', target, payload))
--------------------------------------------------------------------------------

--- The stock chat payload: { color = {r,g,b}, multiline = bool, args = { prefix?, message } }.
--- Two args render as `prefix: message`, one renders the line as-is (system_resources/chat/cl_chat.lua).
local function buildPayload(message, opts)
    local text = cleanText(message, MAX_OUTPUT)
    if not text then return nil end
    if type(opts) ~= 'table' then opts = nil end
    local prefix = opts and cleanText(opts.prefix, MAX_PREFIX) or nil
    return {
        color = (opts and normalizeColor(opts.color)) or DEFAULT_COLOR,
        multiline = (opts and opts.multiline == true) or false,
        args = prefix and { prefix, text } or { text },
    }
end

local function sendPayload(target, payload)
    TriggerClientEvent('chat:addMessage', target, payload)
end

--- One player. Returns false when the src or the message is unusable.
function Chat.send(src, message, opts)
    local target = toSrc(src)
    if not target then return false end
    local payload = buildPayload(message, opts)
    if not payload then return false end
    sendPayload(target, payload)
    return true
end

--- Every client at once — announcements only, never in a loop (DESIGN §9).
function Chat.broadcast(message, opts)
    local payload = buildPayload(message, opts)
    if not payload then return false end
    sendPayload(-1, payload)
    return true
end

--- Loaded players within `range` of `coords` (vector3 or { x, y, z }). Returns how many were reached.
function Chat.sendNear(coords, range, message, opts)
    local origin = toVector3(coords)
    if not origin then return 0 end
    if type(range) ~= 'number' or range ~= range or range <= 0 then range = proximityRange() end
    range = math.min(range + 0.0, MAX_RANGE)
    local payload = buildPayload(message, opts)
    if not payload then return 0 end
    local players = Core.Player.getPlayers()
    local sent = 0
    for i = 1, #players do
        local target = players[i]
        local position = Core.Player.getCoords(target)
        if position and #(position - origin) <= range then
            sendPayload(target, payload)
            sent = sent + 1
        end
    end
    return sent
end

--- Everyone holding `perm` (staff channels). Returns how many were reached.
local function sendToPerm(perm, message, opts)
    local payload = buildPayload(message, opts)
    if not payload then return 0 end
    local players = Core.Player.getPlayers()
    local sent = 0
    for i = 1, #players do
        local target = players[i]
        if Core.Perms.has(target, perm) then
            sendPayload(target, payload)
            sent = sent + 1
        end
    end
    return sent
end

--------------------------------------------------------------------------------
-- Pipeline: cooldown -> sanitize -> filter veto -> hook -> format -> route
--------------------------------------------------------------------------------

--- Per-src throttle (Config.Chat.CooldownMs). Cleared in playerDropped; a rejected message never
--- refreshes the timestamp, so spamming cannot extend a mute.
local function onCooldown(src)
    local ms = cooldownMs()
    if ms <= 0 then return false end
    local now = GetGameTimer()
    local last = lastMessage[src]
    if last and now - last < ms then return true end
    lastMessage[src] = now
    return false
end

--- The Core.Chat.setFilter veto. A filter is plugin code: its error must not take the message pipeline
--- (and with it the whole chat) down, so it runs in pcall and a failing filter never blocks a message.
local function vetoed(src, channel, text)
    if not filter then return false end
    local ok, allowed = pcall(filter, src, channel, text)
    if not ok then
        Core.Log.warn('chat: filter failed (%s)', tostring(allowed))
        return false
    end
    return allowed == false
end

--- Shared by the interceptor and every channel command. `def` is a channel entry (or the config-driven
--- default channel). Returns true when the message was delivered.
local function dispatch(src, channel, message, def)
    local text = cleanText(message, maxLength())
    if not text then return false end
    if onCooldown(src) then return false end
    if vetoed(src, channel, text) then return false end
    Core.emitHook('chatMessage', src, channel, text)

    local line = applyFormat(def.format, {
        tag = tagOf(src), name = nameOf(src), id = src, msg = text,
    })
    local opts = { color = def.color }
    if def.staffOnly then
        sendToPerm(def.permission or STAFF_PERM, line, opts)
    elseif def.global then
        Chat.broadcast(line, opts)
    else
        local coords = Core.Player.getCoords(src)
        if not coords then return false end
        Chat.sendNear(coords, def.range or proximityRange(), line, opts)
    end
    return true
end

--------------------------------------------------------------------------------
-- Channels
--------------------------------------------------------------------------------

--- Register a chat channel and its command. `global = false` routes by proximity,
--- `staffOnly = true` delivers only to holders of `permission` (default core.mod).
function Chat.registerChannel(name, def)
    if type(name) ~= 'string' or name == '' or #name > 32 or name:find('%s') then return false end
    if type(def) ~= 'table' then return false end
    local command = type(def.command) == 'string' and def.command or name
    if command == '' or #command > 32 or command:find('%s') then return false end

    local range = tonumber(def.range)
    local entry = {
        name = name,
        command = command,
        permission = type(def.permission) == 'string' and def.permission or nil,
        format = type(def.format) == 'string' and def.format or DEFAULT_FORMAT,
        global = def.global == true,
        staffOnly = def.staffOnly == true,
        color = normalizeColor(def.color),
        range = (range and range > 0) and math.min(range, MAX_RANGE) or nil,
    }
    channels[name] = entry

    Core.Commands.register(command, {
        description = type(def.description) == 'string' and def.description
            or ('Chat channel: ' .. name),
        permission = entry.permission,
        allowConsole = false,
        params = { { name = 'message', type = 'rest', help = 'message' } },
    }, function(src, args)
        if src == 0 then return end
        -- read the live entry: a channel may have been replaced since the command was registered
        local channel = channels[name]
        if not channel then return end
        dispatch(src, name, args.message, channel)
    end)
    return true
end

--- fn(src, channel, msg) -> false vetoes the message; nil clears the filter.
function Chat.setFilter(fn)
    if fn ~= nil and not Core.Utils.isCallable(fn) then return false end
    filter = fn
    return true
end

--------------------------------------------------------------------------------
-- Built-in channels (DESIGN §23) and /pm
--------------------------------------------------------------------------------

Chat.registerChannel('ooc', {
    command = 'ooc', description = 'Out-of-character chat',
    format = '(OOC) {name}: {msg}', global = true, color = { 150, 180, 220 },
})

Chat.registerChannel('me', {
    command = 'me', description = 'Roleplay action (nearby players only)',
    format = '* {name} {msg}', global = false, color = { 200, 150, 220 },
})

Chat.registerChannel('a', {
    command = 'a', description = 'Staff chat',
    format = '[STAFF] {name}: {msg}', global = true, staffOnly = true,
    permission = STAFF_PERM, color = { 255, 190, 90 },
})

Core.Commands.register('pm', {
    description = 'Send a private message',
    allowConsole = false,
    params = {
        { name = 'target', type = 'player', help = 'server id' },
        { name = 'message', type = 'rest', help = 'message' },
    },
}, function(src, args)
    if src == 0 then return end
    -- args.target is a connected server id (the `player` param type checks that), but it still has to be
    -- a loaded session and not the sender themselves.
    local target = toSrc(args.target)
    if not target or target == src or not Core.Player.isLoaded(target) then
        Chat.send(src, 'No such player', { prefix = 'PM', color = SYSTEM_COLOR })
        return
    end
    local text = cleanText(args.message, maxLength())
    if not text then return end
    if onCooldown(src) then return end
    if vetoed(src, 'pm', text) then return end
    Core.emitHook('chatMessage', src, 'pm', text)

    local opts = { color = PM_COLOR }
    Chat.send(target, applyFormat(PM_IN_FORMAT, { tag = tagOf(src), name = nameOf(src), id = src, msg = text }), opts)
    Chat.send(src, applyFormat(PM_OUT_FORMAT, { tag = tagOf(target), name = nameOf(target), id = target, msg = text }), opts)
end)

--------------------------------------------------------------------------------
-- The `chatMessage` interceptor
--------------------------------------------------------------------------------

--- The default channel, rebuilt per message so a live Config.Chat edit takes effect immediately.
local function defaultChannel()
    return {
        name = 'default',
        format = setting('Format', '{tag}{name} ({id}): {msg}'),
        global = setting('Mode', 'global') ~= 'proximity',
        range = proximityRange(),
    }
end

-- chat passes (source, name, message) as ARGUMENTS, so the player id is the first parameter, not the
-- `source` global. Cancelling stops chat's own broadcast (it checks WasEventCanceled) — core re-sends.
AddEventHandler('chatMessage', function(playerSrc, _, message)
    CancelEvent()
    if type(message) ~= 'string' then return end
    if playerSrc == 0 then
        -- the server console's `say`: no session, no cooldown and no faction tag, just the system line
        local announcement = cleanText(message, MAX_OUTPUT)
        if announcement then
            Chat.broadcast(announcement, { prefix = 'SYSTEM', color = SYSTEM_COLOR })
        end
        return
    end
    local src = toSrc(playerSrc)
    if not src then return end
    if message:sub(1, 1) == '/' then
        -- an unknown command came back through chat's commandFallback: answer the sender, never the server
        local shown = cleanText(message, 64)
        if shown then
            Chat.send(src, ('Unknown command: %s'):format(shown), { prefix = 'SYSTEM', color = SYSTEM_COLOR })
        end
        return
    end
    if not Core.Player.isLoaded(src) then return end
    dispatch(src, 'default', message, defaultChannel())
end)

AddEventHandler('playerDropped', function()
    local src = source
    if src == nil then return end
    lastMessage[src] = nil
end)
