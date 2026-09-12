--[[
    core/server/webhook.lua — Core.Webhook (DESIGN §24)

    `Webhook.send(name, embed)` posts a Discord embed to the URL in the convar `core_webhook_<name>`
    (plain `set`, so it never reaches a client; empty or unset = that webhook is simply disabled).

    Sends are batched: at most one request per 2 s per webhook, up to 10 embeds per request, which is
    what Discord's rate limit tolerates and what keeps a burst of audit lines from becoming a burst of
    HTTP requests. Queued embeds beyond MAX_QUEUE are dropped (oldest first) and counted.

    When `core_webhook_audit` is set, core subscribes the `audit` hook (DESIGN §3.4) here, so every
    Core.Log.audit line is mirrored to Discord. The URL itself is never logged.

    Natives: GetConvar (shared). HTTP goes through Core.Http.fetch (server/http.lua).
]]

local Webhook = {}
Core.Webhook = Webhook

local Log = Core.Log
local Utils = Core.Utils

local queues = {}   -- [name] = { embeds = {}, timer = bool, lastSent = ms, dropped = n }

local CONVAR_PREFIX <const> = 'core_webhook_'
local MIN_INTERVAL_MS <const> = 2000
local MAX_EMBEDS <const> = 10
local MAX_QUEUE <const> = 50
local MAX_TITLE <const> = 256
local MAX_DESCRIPTION <const> = 2048
local MAX_FIELDS <const> = 25
local MAX_FIELD_NAME <const> = 256
local MAX_FIELD_VALUE <const> = 1024
local MAX_NAME_LEN <const> = 32
local DEFAULT_COLOR <const> = 3447003   -- Discord blurple-ish blue
local REQUEST_TIMEOUT_MS <const> = 10000

local function isName(value)
    return type(value) == 'string' and #value >= 1 and #value <= MAX_NAME_LEN
        and value:match('^[%w_%-]+$') ~= nil
end

--- The configured URL for this webhook, or nil. Read on every batch so a runtime `set` is picked up;
--- the value is a secret and is never printed.
local function webhookUrl(name)
    local url = GetConvar(CONVAR_PREFIX .. name, '')
    if type(url) ~= 'string' or url == '' or not url:match('^https://') then return nil end
    return url
end

local function cleanFields(fields)
    if type(fields) ~= 'table' then return nil end
    local out = {}
    for i = 1, math.min(#fields, MAX_FIELDS) do
        local field = fields[i]
        if type(field) == 'table' then
            local fieldName = Utils.sanitize(tostring(field.name or ''), MAX_FIELD_NAME)
            local value = Utils.sanitize(tostring(field.value or ''), MAX_FIELD_VALUE)
            if fieldName ~= '' and value ~= '' then
                out[#out + 1] = { name = fieldName, value = value, inline = field.inline == true }
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

--- Whatever a plugin passed in becomes a Discord-shaped embed, or nil when there is nothing to post.
local function buildEmbed(embed)
    if type(embed) ~= 'table' then return nil end
    local out = { timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ') }
    if embed.title ~= nil then out.title = Utils.sanitize(tostring(embed.title), MAX_TITLE) end
    if embed.description ~= nil then
        out.description = Utils.sanitize(tostring(embed.description), MAX_DESCRIPTION)
    end
    local color = embed.color
    if type(color) == 'number' and color == color then
        out.color = math.floor(Utils.clamp(color, 0, 0xFFFFFF))
    else
        out.color = DEFAULT_COLOR
    end
    out.fields = cleanFields(embed.fields)
    if (out.title == nil or out.title == '') and (out.description == nil or out.description == '')
        and out.fields == nil then
        return nil
    end
    return out
end

--- Send up to MAX_EMBEDS queued embeds as one request; re-arms itself while the queue is not empty.
local function flush(name)
    local queue = queues[name]
    if not queue then return end
    queue.timer = false
    local url = webhookUrl(name)
    if not url then
        queue.embeds = {}
        return
    end
    local batch = {}
    while #batch < MAX_EMBEDS and #queue.embeds > 0 do
        batch[#batch + 1] = table.remove(queue.embeds, 1)
    end
    if #batch == 0 then return end
    if queue.dropped > 0 then
        Log.warn('webhook %s: %d embed(s) dropped (queue full)', name, queue.dropped)
        queue.dropped = 0
    end
    queue.lastSent = GetGameTimer()
    -- Core.Http.fetch suspends, so it needs a thread of its own; at most one per 2 s per webhook.
    CreateThread(function()
        local status, _, _ = Core.Http.fetch(url, {
            method = 'POST', body = { embeds = batch }, timeoutMs = REQUEST_TIMEOUT_MS,
        })
        if not status then
            Log.warn('webhook %s: request failed', name)
        elseif status >= 300 then
            Log.warn('webhook %s: HTTP %d', name, status)
        end
    end)
    if #queue.embeds > 0 then
        queue.timer = true
        SetTimeout(MIN_INTERVAL_MS, function() flush(name) end)
    end
end

--- Arm the batch timer, never sooner than MIN_INTERVAL_MS after the last request.
local function schedule(name)
    local queue = queues[name]
    if not queue or queue.timer then return end
    queue.timer = true
    local elapsed = GetGameTimer() - queue.lastSent
    local wait = MIN_INTERVAL_MS - elapsed
    if wait < 0 then wait = 0 end
    SetTimeout(wait, function() flush(name) end)
end

--- Queue one embed `{ title, description, color, fields }` for the `core_webhook_<name>` webhook.
--- @return boolean queued (false = no URL configured, bad name, or empty embed)
function Webhook.send(name, embed)
    if not isName(name) then
        Log.error('Webhook.send: invalid name %s', tostring(name))
        return false
    end
    if not webhookUrl(name) then return false end
    local built = buildEmbed(embed)
    if not built then return false end
    local queue = queues[name]
    if not queue then
        queue = { embeds = {}, timer = false, lastSent = 0, dropped = 0 }
        queues[name] = queue
    end
    if #queue.embeds >= MAX_QUEUE then
        table.remove(queue.embeds, 1)
        queue.dropped = queue.dropped + 1
    end
    queue.embeds[#queue.embeds + 1] = built
    schedule(name)
    return true
end

-- Audit mirror. Subscribed unconditionally: `Webhook.send` re-reads the convar on every call and
-- `flush` re-reads it on every batch, so a `set core_webhook_audit ...` at runtime starts mirroring
-- and clearing the convar stops it — no restart, and no work at all while it is empty.
Core.on('audit', function(category, src, message)
    Webhook.send('audit', {
        title = ('audit: %s'):format(tostring(category)),
        description = tostring(message),
        fields = { { name = 'src', value = tostring(src), inline = true } },
    })
end)
