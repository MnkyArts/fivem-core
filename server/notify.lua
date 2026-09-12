-- core/server/notify.lua
-- Core.Notify (DESIGN §4.7): server-side toasts, delivered to the NUI shell via `core:client:notify`.

local Notify = {}
Core.Notify = Notify

local TYPES <const> = { info = true, success = true, error = true, warning = true }
local MAX_MESSAGE <const> = 256
local MAX_DURATION <const> = 30000
local MAX_SRC <const> = 4096

local function toSrc(value)
    if type(value) ~= 'number' or value ~= value then return nil end
    local n = math.floor(value)
    if n < 1 or n > MAX_SRC then return nil end
    return n
end

-- { message, type, duration } — `title` is part of the client-side shape (§6.10) but core never sets it.
local function buildPayload(message, notifyType, duration)
    if type(message) ~= 'string' and type(message) ~= 'number' then return nil end
    local text = Core.Utils.sanitize(message, MAX_MESSAGE)
    if text == '' then return nil end
    local kind = (type(notifyType) == 'string' and TYPES[notifyType]) and notifyType or 'info'
    local ms
    if type(duration) == 'number' and duration == duration and duration > 0 then
        ms = math.min(math.floor(duration), MAX_DURATION)
    end
    return { message = text, type = kind, duration = ms }
end

--- Notify one player. type ∈ { info, success, error, warning }, default 'info'.
function Notify.send(src, message, notifyType, duration)
    local target = toSrc(src)
    if not target then return false end
    local data = buildPayload(message, notifyType, duration)
    if not data then return false end
    TriggerClientEvent('core:client:notify', target, data)
    return true
end

--- Announcements only — one call fans out to every client, never use it in a loop.
function Notify.broadcast(message, notifyType)
    local data = buildPayload(message, notifyType, nil)
    if not data then return false end
    TriggerClientEvent('core:client:notify', -1, data)
    return true
end
