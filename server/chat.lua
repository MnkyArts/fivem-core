--[[
    core/server/chat.lua — Core.Chat (DESIGN §23), the CEF messenger.

    The shell (ui/src/components/Chat.vue) renders the feed and the input; this file owns the
    server truth: channels, permissions, cooldown, the filter veto, proximity routing and the
    line opacity every recipient receives. The stock `chat` resource's `chatMessage` is still
    cancelled (parity for servers that run chat's own NUI), but core delivers every line itself
    as `core:client:chat (action = 'add')` — the shell never renders `chat:addMessage`.

        Chat.send(src, message, opts?)             opts = { color?, prefix?, channel?, multiline? }
        Chat.broadcast(message, opts?)             announcements only — one call fans out to every client
        Chat.sendNear(coords, range, message, opts?) -> count
        Chat.registerChannel(name, { command, permission?, format?, global?, staffOnly?, color?,
                                     range?, description?, proximity?, fade? })
        Chat.setFilter(fn(src, channel, msg) -> bool)   -- return false to veto a message
        Chat.clear(src)                            -- wipe one player's CEF feed
        Chat.suggestions(src)                      -- table for the TAB completer (pushed on playerLoaded)

    Formats understand {tag} (faction tag, '[TST] '), {name}, {id} and {msg}. Built-in channels:
    local (proximity, default), ooc (global), faction (sender's faction only), a (staff, core.mod),
    me (proximity action) and /pm <id> <message>. /s <msg> screams: doubled range, opacity 1.

    Proximity lines carry `opacity` 0..1, computed from the SENDER distance against
    Config.Chat.FadeMeters { near, far }: full inside `near`, fading linearly to 0 at `far`.
    Global, system, PM and staff lines arrive at opacity 1.

    Slash input uses CLIENT ExecuteCommand (without the slash), preserving the player's
    identity and the server command wrapper's checks. Never execute as server console.

    Natives (verified with fxref 2026-09-13): CancelEvent (shared), GetGameTimer (server row),
    GetPlayerName(playerSrc) (server row). Everything else goes through
    Core.Player / Core.Perms / Core.Factions / Core.Commands.
]]

local Chat = {}
Core.Chat = Chat

local Utils = Core.Utils

local MAX_SRC <const> = 4096
local MAX_NAME <const> = 32
local MAX_PREFIX <const> = 32
local MAX_OUTPUT <const> = 1024          -- a formatted line: {tag}{name}: {msg} plus config prefix
local MAX_RANGE <const> = 500.0
local STAFF_PERM <const> = 'core.mod'
local DEFAULT_COLOR <const> = { 255, 255, 255 }
local SYSTEM_COLOR <const> = { 200, 90, 90 }
local PM_COLOR <const> = { 190, 140, 240 }
local ME_COLOR <const> = { 200, 150, 220 }
local DEFAULT_FORMAT <const> = '{name}: {msg}'
local PM_IN_FORMAT <const> = '(PM from {name} [{id}]): {msg}'
local PM_OUT_FORMAT <const> = '(PM to {name} [{id}]): {msg}'
local LINE_KINDS <const> = { message = true, me = true, system = true, pm = true, scream = true }

local channels = {}        -- [name] = { name, command, permission, format, global, staffOnly, color, range, proximity, fade }
local lastMessage = {}     -- [src] = GetGameTimer() of the last accepted message (cleared in playerDropped)
local filter               -- Core.Chat.setFilter
local lineSeq = 0          -- monotonic line id, unique per server session

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
    local value = setting('MaxLength', 200)
    if not Utils.isNumber(value) then value = 200 end
    return math.min(256, math.max(1, math.floor(value)))
end

local function cooldownMs()
    return math.max(0, math.floor(setting('CooldownMs', 800)))
end

local function proximityRange()
    return math.min(MAX_RANGE, math.max(1.0, setting('ProximityRange', 20.0) + 0.0))
end

--- { near, far } of the opacity fade (§23), clamped, near <= far.
local function fadeMeters()
    local meters = setting('FadeMeters', { near = 20.0, far = 90.0 })
    local near = type(meters) == 'table' and tonumber(meters.near) or nil
    local far = type(meters) == 'table' and tonumber(meters.far) or nil
    if not near or near ~= near or near < 1.0 then near = proximityRange() end
    if not far or far ~= far or far < near then far = near * 4.0 end
    return near, far
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

--- SENDER-side opacity for a proximity line (§23): 1 inside `near`, linear to 0 at `far`.
--- The client only renders it; the distance it receives is the server's.
local function proximityOpacity(dist, near, far)
    if dist <= near then return 1.0 end
    if dist >= far then return 0.0 end
    return math.floor((1.0 - (dist - near) / (far - near)) * 100.0 + 0.5) / 100.0
end

--------------------------------------------------------------------------------
-- Delivery: one CEF event per recipient (DESIGN §23)
--------------------------------------------------------------------------------

--- One CEF line: { id, seq, channel, name, tag, text, color, kind, opacity }.
--- Structured rendering: `name`/`tag`/`text` are separate fields the feed styles itself.
--- A channel with an EXPLICIT format (plugin channels, /me, /a, /pm) sends the formatted
--- string as `text` with an empty name, so custom formats survive verbatim (§23).
local function buildLine(text, opts)
    if type(text) ~= 'string' or text == '' then return nil end
    if type(opts) ~= 'table' then opts = nil end
    local kind = opts and LINE_KINDS[opts.kind] and opts.kind or 'message'
    local prefix = opts and cleanText(opts.prefix, MAX_PREFIX) or nil
    if prefix then text = prefix .. ' ' .. text end
    local opacity = opts and tonumber(opts.opacity) or nil
    if not opacity or opacity ~= opacity then opacity = 1.0 end
    lineSeq = lineSeq + 1
    local name = opts and type(opts.name) == 'string' and opts.name or ''
    local tag = opts and type(opts.tag) == 'string' and opts.tag or ''
    if opts and opts.formatted then name, tag = '', '' end
    return {
        id = lineSeq,
        seq = lineSeq,
        channel = opts and type(opts.channel) == 'string' and opts.channel or 'system',
        name = name,
        tag = tag ~= '' and tag or nil,
        text = text,
        color = (opts and normalizeColor(opts.color)) or DEFAULT_COLOR,
        kind = kind,
        opacity = math.min(1.0, math.max(0.0, opacity + 0.0)),
    }
end

local EVENT <const> = 'core:client:chat'

local function sendLine(target, line)
    TriggerClientEvent(EVENT, target, { action = 'add', line = line })
end

--- One player. Returns false when the src or the message is unusable.
function Chat.send(src, message, opts)
    local target = toSrc(src)
    if not target then return false end
    local text = cleanText(message, MAX_OUTPUT)
    if not text then return false end
    if type(opts) ~= 'table' then opts = nil end
    local line = buildLine(text, {
        color = opts and opts.color or nil,
        prefix = opts and opts.prefix or nil,
        channel = opts and opts.channel or 'system',
        kind = (opts and LINE_KINDS[opts.kind] and opts.kind) or 'message',
        opacity = 1.0,
    })
    if not line then return false end
    sendLine(target, line)
    return true
end

--- Every client at once — announcements only, never in a loop (DESIGN §9).
function Chat.broadcast(message, opts)
    local text = cleanText(message, MAX_OUTPUT)
    if not text then return false end
    if type(opts) ~= 'table' then opts = nil end
    local line = buildLine(text, {
        color = opts and opts.color or SYSTEM_COLOR,
        prefix = opts and opts.prefix or nil,
        channel = 'system',
        kind = 'system',
        opacity = 1.0,
    })
    if not line then return false end
    sendLine(-1, line)
    return true
end

--- Loaded players within `range` of `coords` (vector3 or { x, y, z }), each with the opacity
--- of THEIR distance (§23). Returns how many were reached.
function Chat.sendNear(coords, range, message, opts)
    local origin = toVector3(coords)
    if not origin then return 0 end
    local near, far = fadeMeters()
    if type(range) ~= 'number' or range ~= range or range <= 0 then range = far end
    range = math.min(range + 0.0, MAX_RANGE)
    if type(opts) ~= 'table' then opts = nil end
    local players = Core.Player.getPlayers()
    local sent = 0
    for i = 1, #players do
        local target = players[i]
        local position = Core.Player.getCoords(target)
        if position then
            local dist = #(position - origin)
            if dist <= range then
                local text = cleanText(message, MAX_OUTPUT)
                if text then
                    sendLine(target, buildLine(text, {
                        color = opts and opts.color or nil,
                        prefix = opts and opts.prefix or nil,
                        channel = opts and opts.channel or 'local',
                        kind = (opts and LINE_KINDS[opts.kind] and opts.kind) or 'message',
                        opacity = proximityOpacity(dist, near, far),
                    }))
                end
                sent = sent + 1
            end
        end
    end
    return sent
end

--- Everyone holding `perm` (staff channels). Returns how many were reached.
local function sendToPerm(perm, line)
    local players = Core.Player.getPlayers()
    local sent = 0
    for i = 1, #players do
        local target = players[i]
        if Core.Perms.has(target, perm) then
            sendLine(target, line)
            sent = sent + 1
        end
    end
    return sent
end

--- Faction channel: every ONLINE member of the sender's faction, sender included.
local function sendToFaction(src, line)
    local factions = Core.Factions
    local summary = type(factions) == 'table' and type(factions.getPlayerFaction) == 'function'
        and factions.getPlayerFaction(src) or nil
    local id = summary and summary.id or nil
    if type(id) ~= 'string' or id == '' or type(factions.getMembers) ~= 'function' then return false end
    local members = factions.getMembers(id)
    for i = 1, #members do
        local target = members[i] and members[i].online or nil
        if target then sendLine(target, line) end
    end
    return true
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

--- Channel permission check: staffOnly channels need `permission` (default core.mod);
--- faction channels need a faction. Both are re-checked per message, never cached.
local function mayUse(src, def)
    if def.permission and not Core.Perms.has(src, def.permission) then return false end
    if def.staffOnly and not Core.Perms.has(src, def.permission or STAFF_PERM) then return false end
    if def.faction then
        local factions = Core.Factions
        local summary = type(factions) == 'table' and type(factions.getPlayerFaction) == 'function'
            and factions.getPlayerFaction(src) or nil
        if not (summary and type(summary.id) == 'string' and summary.id ~= '') then return false end
    end
    return true
end

--- Shared by the interceptor and every channel command. `def` is a channel entry (or the config-driven
--- default channel). Returns true when the message was delivered.
local function dispatch(src, channel, message, def)
    local text = cleanText(message, maxLength())
    if not text then return false end
    if onCooldown(src) then return false end
    if vetoed(src, channel, text) then return false end
    if not mayUse(src, def) then return false end
    Core.emitHook('chatMessage', src, channel, text)

    local coords = Core.Player.getCoords(src)
    local fields = { tag = tagOf(src), name = nameOf(src), id = src, msg = text }
    local line = buildLine(def.format and applyFormat(def.format, fields) or text, {
        color = def.color,
        channel = channel,
        name = fields.name,
        tag = fields.tag ~= '' and fields.tag or nil,
        formatted = def.format ~= nil,     -- an explicit format renders as one string (§23)
        kind = (channel == 'me') and 'me' or 'message',
    })
    if not line then return false end

    if def.staffOnly then
        sendToPerm(def.permission or STAFF_PERM, line)
    elseif def.faction then
        sendToFaction(src, line)
    elseif def.global then
        line.opacity = 1.0
        local players = Core.Player.getPlayers()
        for i = 1, #players do sendLine(players[i], line) end
    else
        if not coords then return false end
        -- proximity: EVERY recipient gets their own opacity (§23). Delivery reaches out to
        -- FadeMeters.far: full opacity inside `near` (= ProximityRange by default), fading
        -- linearly to 0 at `far` — further speakers lose opacity, the far edge fades out.
        local near, far = fadeMeters()
        local range = def.range or far
        local players = Core.Player.getPlayers()
        for i = 1, #players do
            local target = players[i]
            local position = Core.Player.getCoords(target)
            if position then
                local dist = #(position - coords)
                if dist <= range then
                    line.opacity = proximityOpacity(dist, near, far)
                    sendLine(target, line)
                end
            end
        end
    end
    return true
end

--------------------------------------------------------------------------------
-- Scream (/s <msg>): doubled range, always opacity 1 (DESIGN §23)
--------------------------------------------------------------------------------

local function screamRange()
    local range = tonumber(setting('ScreamRange', 60.0))
    if not range or range ~= range or range <= 0 then range = proximityRange() * 2.0 end
    return math.min(MAX_RANGE, range)
end

Core.Commands.register(setting('ScreamCommand', 's'), {
    description = 'Scream: nearby players hear you further away',
    allowConsole = false,
    params = { { name = 'message', type = 'rest', help = 'message' } },
}, function(src, args)
    if src == 0 then return end
    if not Core.Player.isLoaded(src) then return end
    local text = cleanText(args.message, maxLength())
    if not text then return false end
    if onCooldown(src) then return false end
    if vetoed(src, 'scream', text) then return false end
    Core.emitHook('chatMessage', src, 'scream', text)

    local coords = Core.Player.getCoords(src)
    if not coords then return false end
    local fields = { tag = tagOf(src), name = nameOf(src), id = src, msg = text }
    local line = buildLine(text, {
        color = { 255, 230, 160 },
        channel = 'scream',
        name = fields.name,
        tag = fields.tag ~= '' and fields.tag or nil,
        kind = 'scream',
    })
    if not line then return false end
    local range = screamRange()
    local players = Core.Player.getPlayers()
    for i = 1, #players do
        local target = players[i]
        local position = Core.Player.getCoords(target)
        if position then
            local dist = #(position - coords)
            if dist <= range then
                -- a scream carries far: full opacity for everyone in range (§23)
                line.opacity = 1.0
                sendLine(target, line)
            end
        end
    end
    return true
end)

--------------------------------------------------------------------------------
-- Channels
--------------------------------------------------------------------------------

--- Register a chat channel and its command. `global = false` routes by proximity,
--- `staffOnly = true` delivers only to holders of `permission` (default core.mod),
--- `faction = true` delivers to the sender's faction only.
function Chat.registerChannel(name, def)
    if type(name) ~= 'string' or name == '' or #name > 32 or name:find('%s') then return false end
    if type(def) ~= 'table' then return false end
    local command = def.command
    if command == nil then command = name end
    if command ~= false and (type(command) ~= 'string' or command == '' or #command > 32
        or command:find('%s')) then return false end

    local range = tonumber(def.range)
    local format = type(def.format) == 'string' and def.format or nil
    local entry = {
        name = name,
        command = command,
        permission = type(def.permission) == 'string' and def.permission or nil,
        description = type(def.description) == 'string' and def.description or ('Chat channel: ' .. name),
        format = format,                   -- nil = structured rendering (name/tag/text separate)
        global = def.global == true,
        staffOnly = def.staffOnly == true,
        faction = def.faction == true,
        color = normalizeColor(def.color),
        range = (range and range > 0) and math.min(range, MAX_RANGE) or nil,
    }
    channels[name] = entry

    if command ~= false then
        Core.Commands.register(command, {
            description = type(def.description) == 'string' and def.description
                or ('Chat channel: ' .. name),
            permission = entry.permission,
            allowConsole = false,
            params = { { name = 'message', type = 'rest', help = 'message' } },
        }, function(src, args)
            if src == 0 then return end
            if not Core.Player.isLoaded(src) then return end
            -- read the live entry: a channel may have been replaced since the command was registered
            local channel = channels[name]
            if not channel then return end
            dispatch(src, name, args.message, channel)
        end)
    end
    return true
end

--- fn(src, channel, msg) -> false vetoes the message; nil clears the filter.
function Chat.setFilter(fn)
    if fn ~= nil and not Core.Utils.isCallable(fn) then return false end
    filter = fn
    return true
end

--- Wipes one player's CEF feed (§23) — admin tooling; the shell keeps nothing.
function Chat.clear(src)
    local target = toSrc(src)
    if not target then return false end
    TriggerClientEvent(EVENT, target, { action = 'clear' })
    return true
end

--- The channel chips the caller may use (§23): { id, label, description, command } — the
--- shell renders only these, so a permission-refused channel never appears as a chip.
--- `command` is the channel's slash command (nil for the commandless local channel), so the
--- TAB completer completes the REAL command instead of guessing from the channel name.
local function channelsFor(src)
    local out = {}
    for name, def in pairs(channels) do
        if name ~= 'me' and mayUse(src, def) then
            out[#out + 1] = {
                id = name,
                label = (name == 'local') and 'Local' or name,
                description = def.description or '',
                command = def.command ~= false and def.command or nil,
            }
        end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

--- The TAB completer's channel half (§23): every channel command the caller may use, as
--- { command, channel, description }. Permission is checked live per caller.
function Chat.suggestions(src)
    local out = {}
    for name, def in pairs(channels) do
        if def.command and def.command ~= false and mayUse(src, def) then
            out[#out + 1] = {
                command = '/' .. def.command,
                channel = name,
                description = def.description or ('Channel: %s'):format(name),
                params = { { name = '<message>', help = 'Message', type = 'rest', optional = false } },
            }
        end
    end
    table.sort(out, function(a, b) return a.command < b.command end)
    return out
end

--------------------------------------------------------------------------------
-- Built-in channels (DESIGN §23) and /pm
--------------------------------------------------------------------------------

Chat.registerChannel('local', {
    command = false,                   -- plain chat writes here; no slash command needed
    description = 'Local chat (nearby players)',
    global = false,
    color = { 235, 235, 235 },
})

Chat.registerChannel('ooc', {
    command = 'ooc', description = 'Out-of-character chat',
    global = true, color = { 150, 180, 220 },
})

Chat.registerChannel('faction', {
    command = 'fc', description = 'Faction chat (members only)',
    faction = true, color = { 140, 200, 160 },
})

Chat.registerChannel('me', {
    command = 'me', description = 'Roleplay action (nearby players only)',
    format = '* {name} {msg}', global = false, color = ME_COLOR,
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
    if not Core.Player.isLoaded(src) then return end
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

    local function pmLine(fmt, fields)
        local line = buildLine(applyFormat(fmt, fields), {
            color = PM_COLOR, channel = 'pm', kind = 'pm', opacity = 1.0,
        })
        return line
    end
    local received = pmLine(PM_IN_FORMAT, { tag = tagOf(src), name = nameOf(src), id = src, msg = text })
    if received then sendLine(target, received) end
    local sent = pmLine(PM_OUT_FORMAT, { tag = tagOf(target), name = nameOf(target), id = target, msg = text })
    if sent then sendLine(src, sent) end
end)

--------------------------------------------------------------------------------
-- The CEF input pipeline (DESIGN §23, §30.2)
--------------------------------------------------------------------------------

--- The default channel, rebuilt per message so a live Config.Chat edit takes effect immediately.
--- `range` stays nil on purpose: dispatch then delivers out to FadeMeters.far with the fade
--- band applied (§23) — pinning it to ProximityRange would make `far` dead config.
--- `Format` nil (the default) renders structured; a string forces the legacy one-string look.
local function defaultChannel()
    return {
        name = 'local',
        format = type(Config.Chat) == 'table' and type(Config.Chat.Format) == 'string' and Config.Chat.Format or nil,
        global = setting('Mode', 'proximity') ~= 'proximity',
        range = nil,
    }
end

--- A validated send from the CEF input. The client is an input device: the channel name is
--- resolved against the live registry (plugin channels included) and re-checked here —
--- schema first, then cooldown/permission/filter.
Core.Net.on('core:server:chat:send', { { 'string', min = 1, max = 256 }, { 'string', min = 1, max = 32 } },
function(src, message, channelName)
    if not Core.Player.isLoaded(src) then return end
    if channelName == 'scream' then
        -- /s semantics: doubled range, opacity 1 — reuse the scream command path
        Core.Commands.execute(setting('ScreamCommand', 's'), src, { message }, message)
        return
    end
    if channelName == 'local' then
        dispatch(src, 'local', message, defaultChannel())
        return
    end
    local def = channels[channelName]
    if not def then return end
    dispatch(src, channelName, message, def)
end, { cooldown = 250 })

--- A `/command` typed into the CEF input does NOT come through here: the client runs
--- ExecuteCommand locally and the engine routes unknown-to-client commands to the server
--- with the player's identity (`__cfx_internal:commandFallback`), so core's own permission
--- wrapper applies exactly as if the line was typed into any chat (§30.2).

--- The shell asks for the TAB completer's data (§23): channel commands + command suggestions
--- + the channel chips + the shell's history length. Answered per caller; the client caches
--- it until the next push.
local function pushSuggestions(src)
    local out = Chat.suggestions(src)
    local channelCommands = {}
    for _, def in pairs(channels) do
        if def.command then channelCommands['/' .. def.command] = true end
    end
    for _, command in ipairs(Core.Commands.suggestions(src)) do
        -- Do not re-introduce /fc via the generic command list for factionless players.
        if not channelCommands[command.command] and command.command ~= '/say' then
            out[#out + 1] = command
        end
    end
    local function bounded(key, default, minimum, maximum)
        local value = setting(key, default)
        if not Utils.isNumber(value) then value = default end
        return math.min(maximum, math.max(minimum, math.floor(value)))
    end
    TriggerClientEvent(EVENT, src, {
        action = 'suggestions', items = out, channels = channelsFor(src),
        history = bounded('History', 80, 1, 200),
        hideDelayMs = bounded('HideDelayMs', 8000, 0, 600000),
        visibleLines = bounded('VisibleLines', 8, 1, 30),
        maxLength = maxLength(),
    })
    Core.emitHook('chatSuggestionsRequested', src)
end

Core.Net.on('core:server:chat:suggestions', {}, function(src)
    pushSuggestions(src)
end, { cooldown = 1000 })

--------------------------------------------------------------------------------
-- The `chatMessage` interceptor (kept for parity with the stock chat resource)
--------------------------------------------------------------------------------

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
    dispatch(src, 'local', message, defaultChannel())
end)

--- Suggestion push: once per session (§30.2). The `playerLoaded` replay after `restart core`
--- re-seeds the client's cache.
AddEventHandler('core:hook:playerLoaded', function(src)
    if type(src) ~= 'number' or src <= 0 then return end
    pushSuggestions(src)
end)

--- Console `say` (the stock chat registered it; core owns it now): SYSTEM broadcast.
Core.Commands.register('say', {
    description = 'Broadcast a message to every player (console)',
    allowConsole = true,
    params = { { name = 'message', type = 'rest', help = 'message' } },
}, function(src, args)
    if src ~= 0 then return end
    local announcement = cleanText(args.message, MAX_OUTPUT)
    if announcement then
        Chat.broadcast(announcement, { prefix = 'SYSTEM', color = SYSTEM_COLOR })
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    if src == nil then return end
    lastMessage[src] = nil
    local name = GetPlayerName(src)
    if type(name) == 'string' and name ~= '' then
        Chat.broadcast(('* %s left'):format(Utils.sanitize(name, MAX_NAME)), { color = { 200, 170, 140 } })
    end
end)

--- Join lines (the stock chat sent these; core owns them now).
AddEventHandler('playerJoining', function()
    local src = source
    local name = GetPlayerName(src)
    if type(name) == 'string' and name ~= '' then
        Chat.broadcast(('* %s joined'):format(Utils.sanitize(name, MAX_NAME)), { color = { 150, 220, 150 } })
    end
end)
