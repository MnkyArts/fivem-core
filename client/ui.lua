--- core / client/ui.lua — Core.UI: the NUI bridge (DESIGN §6.10).
--- Owns the page registry (one exclusive page + overlays), the focus rules, the
--- built-ins (notify, textUI, progress, menu, input, alert, hud), every NUI
--- callback and the focus watchdog.
--- Natives verified with fxref on 2026-09-12: SetNuiFocus, SetNuiFocusKeepInput,
--- RegisterNuiCallback, RegisterKeyMapping, PlaySoundFrontend (client),
--- RegisterCommand, AddStateBagChangeHandler (shared), GetGameTimer (client+server),
--- GetCurrentResourceName (shared).
--- Runtime helpers: SendNUIMessage (table form), promise, Citizen.Await, SetTimeout.
--- Note: `UI.progress` is the function itself, so inside core its canceller is only
--- reachable through the flat key — `UI['progress.cancel']()`, not `UI.progress.cancel()`.

local UI = Core.UI                  -- lib namespace from lib/ui/client.lua (UI.on/UI.off) — extend, never replace
local Registry = Core.Registry
local Log = Core.Log
local Validate = Core.Validate
local Utils = Core.Utils

local MAX_EVENT_BYTES <const> = 16384
local MAX_KEY_HINTS <const> = 12
local SHARD_MS <const> = 4000
local STATS_TICK_MS <const> = 250
local STATE_TICK_MS <const> = 250
local MAX_EVENT_KEYS <const> = 256
local MAX_NOTIFY_QUEUE <const> = 50
local NOTIFY_TICK_MS <const> = 100
local HUD_TICK_MS <const> = 100
local PROGRESS_GRACE_MS <const> = 5000
local PAGE_TYPES <const> = { page = true, overlay = true }
-- A page with no script/style is resolved from the shell's own bundle: send an
-- explicit null (dkjson's json.null encodes to `null`, falsy in JS like false).
local NO_URL <const> = (type(json) == 'table' and json.null) or false
local NOTIFY_TYPES <const> = { info = true, success = true, error = true, warning = true }
local SHARD_STYLES <const> = { wasted = true, success = true, info = true }
-- replicated keys forwarded to the page as `state:set` (§21); bulky ones stay in Lua
local STATE_SKIP <const> = { stats = true, attachments = true }
local STATE_KEYS <const> = { 'loaded', 'name', 'charId', 'cash', 'bank', 'faction', 'group', 'dead' }

local pages = {}                    -- id -> { owner, type, script, style, keepInput, registered }
local overlays = {}                 -- id -> true (visible overlays)
local openPage = nil                -- id of the exclusive page, or nil
local pending = {}                  -- requestId -> { kind, promise }
local modal = nil                   -- { kind = 'menu'|'input'|'alert', id = requestId }
local progressReq = nil             -- requestId of the running progress bar
local progressCancellable = false   -- whether that bar may be cancelled by the key bind
local textUI = nil                  -- { key, text, position }
local hud = { visible = false }     -- last HUD snapshot (re-sent on ui_ready)
local hudPending = {}               -- HUD fields waiting for the next 100 ms flush
local hudTimer = false
local hudSentAt = -HUD_TICK_MS
local keyHints = nil                -- items of the visible key hint bar, or nil
local spinnerText = nil             -- text of the running spinner, or nil
local statsPending = {}             -- stat name -> { value, min, max } awaiting the 250 ms flush
local statsTimer = false
local statsSentAt = -STATS_TICK_MS
local statePending = {}             -- replicated state key -> latest value awaiting its flush
local stateTimer = false
local stateSentAt = -STATE_TICK_MS
local notifyQueue = {}              -- pending notifications, coalesced by message+type+title
local notifyIndex = {}              -- coalesce key -> queued entry (keeps UI.notify O(1))
local notifyFlushing = false
local notifyWindowAt = 0
local notifyTickAt = 0
local notifySent = 0
local nuiReady = false
local uiReadyAt = nil               -- last accepted ui_ready, for the 1/s rate limit
local focusOwned = false
local focusKeepInput = false
local requestSeq = 0

-- Sub-namespace tables (§2.2): every function is stored BOTH as UI.menu.open and
-- as the flat dotted key UI['menu.open'], which is what exports.core:call looks up.
UI.menu = UI.menu or {}
UI.input = UI.input or {}
UI.textUI = UI.textUI or {}
UI.hud = UI.hud or {}
UI.keys = UI.keys or {}
UI.spinner = UI.spinner or {}
UI.stats = UI.stats or {}
UI.state = UI.state or {}
UI.locale = UI.locale or {}

--- Registers fn under both the dotted flat key and the nested table.
local function define(sub, name, fn)
    UI[sub .. '.' .. name] = fn
    UI[sub][name] = fn
end

--- Config.UI value with a default (Core.Config is the Config global inside core).
local function uiCfg(key, default)
    local cfg = Core.Config or Config
    local value = cfg and cfg.UI and cfg.UI[key]
    if value == nil then return default end
    return value
end

local function send(message)
    SendNUIMessage(message)
end

local function newRequestId()
    requestSeq = requestSeq + 1
    return requestSeq
end

--- Resolves a pending await (menu/input/alert/progress); unknown ids are ignored.
local function resolvePending(id, value)
    local entry = pending[id]
    if not entry then return false end
    pending[id] = nil
    if modal and modal.id == id then modal = nil end
    if progressReq == id then progressReq = nil end
    entry.promise:resolve(value)
    return true
end

--- What an unanswered built-in returns: alert/progress are booleans, the rest nil.
local function cancelValue(kind)
    return (kind == 'alert' or kind == 'progress') and false or nil
end

--- Unblocks everything still waiting on the shell (shell reload, resource stop).
local function resolveAllPending()
    for id, entry in pairs(pending) do
        pending[id] = nil
        entry.promise:resolve(cancelValue(entry.kind))
    end
    modal, progressReq, progressCancellable = nil, nil, false
end

--- Exactly SetNuiFocus(true, true) while a page or a built-in modal is open,
--- SetNuiFocus(false, false) the moment none is (DESIGN §6.10).
local function applyFocus()
    local want = (openPage ~= nil) or (modal ~= nil)
    local page = (modal == nil) and openPage and pages[openPage] or nil
    local keep = want and page ~= nil and page.keepInput == true
    if want == focusOwned and keep == focusKeepInput then return end
    focusOwned, focusKeepInput = want, keep
    if want then
        SetNuiFocus(true, true)
        SetNuiFocusKeepInput(keep)
    else
        SetNuiFocusKeepInput(false)
        SetNuiFocus(false, false)
    end
    send({ action = 'focus', focused = want })
end

--- Sends `message` and suspends the calling coroutine until the NUI answers.
--- Returns `fallback` immediately when the shell is not loaded, so a caller can
--- never hang on a page that will never reply.
local function awaitResult(kind, message, fallback, timeoutMs)
    local id = newRequestId()
    message.id = id
    if not nuiReady then
        Log.warn('UI.%s called before the NUI shell was ready', kind)
        return fallback
    end
    local p = promise.new()
    pending[id] = { kind = kind, promise = p }
    if kind ~= 'progress' then
        if modal then resolvePending(modal.id, nil) end
        modal = { kind = kind, id = id }
        applyFocus()
    else
        -- never leave an older bar pending: it would hang its caller until a reload
        if progressReq then resolvePending(progressReq, false) end
        progressReq = id
    end
    send(message)
    -- watchdog: a shell that never answers must not pin focus or hang the caller
    timeoutMs = timeoutMs or (kind ~= 'progress' and uiCfg('ModalTimeoutMs', 300000) or nil)
    if type(timeoutMs) == 'number' and timeoutMs > 0 then
        SetTimeout(timeoutMs, function()
            if resolvePending(id, fallback) then
                send({ action = kind == 'progress' and 'progress:stop' or (kind .. ':close'), id = id })
                applyFocus()
            end
        end)
    end
    local value = Citizen.Await(p)
    applyFocus()
    return value
end

--- Closes whichever built-in modal is open, resolving it with its cancel value.
local function closeModal()
    if not modal then return end
    local kind, id = modal.kind, modal.id
    send({ action = kind .. ':close' })
    resolvePending(id, kind == 'alert' and false or nil)
end

--- 'ui/dist/page.js' inside resource `owner` → 'https://cfx-nui-owner/ui/dist/page.js' (§7.4).
--- Only relative paths inside the owning resource are accepted: an absolute URL or a
--- traversal would let a page pull an arbitrary remote script into the NUI.
local function urlFor(owner, path)
    if type(path) ~= 'string' or path == '' then return nil end
    if path:find('://', 1, true) or path:find('..', 1, true)
        or path:sub(1, 1) == '/' or path:find('[^%w%._%-/]') then
        Log.error("UI.registerPage: '%s' is not a relative path inside '%s'", path, tostring(owner))
        return nil
    end
    return ('https://cfx-nui-%s/%s'):format(owner, path)
end

--- Stricter than Validate's 'id': no ':' at all, so a forged page/event pair from
--- the NUI cannot address another page's local event (core:ui:<page>:<event>).
local function isPlainId(value)
    return type(value) == 'string' and #value >= 1 and #value <= 64
        and value:find('^[%w_%-]+$') ~= nil
end

--- Cheap shallow bound on an NUI payload: key count + string length, no json pass.
local function payloadTooBig(payload)
    local keys = 0
    for _, value in pairs(payload) do
        keys = keys + 1
        if keys > MAX_EVENT_KEYS then return true end
        if type(value) == 'string' and #value > MAX_EVENT_BYTES then return true end
    end
    return false
end

-- ---------------------------------------------------------------- pages ----

--- Hides one page/overlay without touching focus. Returns whether it was shown.
local function closeOne(id)
    if overlays[id] then
        overlays[id] = nil
    elseif openPage == id then
        openPage = nil
    else
        return false
    end
    send({ action = 'page:close', id = id })
    return true
end

--- UI.registerPage(id, { type = 'page'|'overlay', script?, style?, keepInput? })
--- Without `script` the shell resolves the component from its own bundle. When
--- `script`/`style` ARE given they must be relative paths inside the CALLING
--- resource and become cfx-nui URL fallbacks.
function UI.registerPage(id, opts)
    local owner = Registry.getCaller()
    if not Validate.value('id', id) then
        Log.error('UI.registerPage: invalid page id (%s)', tostring(id))
        return false
    end
    if type(opts) ~= 'table' then
        Log.error("UI.registerPage('%s'): options table required", id)
        return false
    end
    local existing = pages[id]
    if existing and existing.owner ~= owner then
        Log.error("UI.registerPage('%s'): id already registered by '%s'", id, existing.owner)
        return false
    end
    local script, style = nil, nil
    if opts.script ~= nil then
        script = urlFor(owner, opts.script) -- a bad path fails the whole registration
        if not script then return false end
    end
    if opts.style ~= nil then
        style = urlFor(owner, opts.style)
        if not style then return false end
    end
    local entry = {
        owner = owner,
        type = PAGE_TYPES[opts.type] and opts.type or 'page',
        script = script,
        style = style,
        keepInput = opts.keepInput == true,
        registered = true,
    }
    pages[id] = entry
    Registry.track('page', id, owner)
    send({
        action = 'page:register', id = id, type = entry.type,
        script = entry.script or NO_URL, style = entry.style or NO_URL, keepInput = entry.keepInput,
    })
    return true
end

function UI.unregisterPage(id)
    local page = pages[id]
    if not page then return false end
    closeOne(id)
    pages[id] = nil
    Registry.untrack('page', id)
    send({ action = 'page:unregister', id = id })
    applyFocus()
    return true
end

--- Opens a page (exclusive: closes the current one first) or shows an overlay.
function UI.open(id, props)
    local page = pages[id]
    if not page then
        Log.error("UI.open: page '%s' is not registered", tostring(id))
        return false
    end
    if props ~= nil and type(props) ~= 'table' then
        Log.error("UI.open('%s'): props must be a table", id)
        return false
    end
    if page.type == 'overlay' then
        overlays[id] = true
    else
        if openPage and openPage ~= id then closeOne(openPage) end
        openPage = id
    end
    page.props = props or {}            -- kept so ui_ready can restore the page after a shell reload
    send({ action = 'page:open', id = id, props = page.props })
    applyFocus()
    return true
end

--- UI.close(id?) — nil closes the exclusive page that is currently open.
function UI.close(id)
    if id == nil then
        if openPage then closeOne(openPage) end
    else
        closeOne(id)
    end
    applyFocus()
end

--- Closes every page, overlay and built-in, then releases focus.
function UI.closeAll()
    if openPage then closeOne(openPage) end
    for id in pairs(overlays) do
        overlays[id] = nil
        send({ action = 'page:close', id = id })
    end
    closeModal()
    UI['progress.cancel']()
    UI['textUI.hide']()
    UI['keys.hide']()
    UI['spinner.hide']()
    applyFocus()
end

function UI.isOpen(id)
    return openPage == id or overlays[id] == true
end

function UI.getOpenPage()
    return openPage
end

function UI.isFocused()
    return focusOwned
end

--- Pushes an event into a page: NUI 'page:event' → CoreUI.on(pageId, event, fn).
function UI.send(id, event, data)
    if not pages[id] or not Validate.value('id', event) then return false end
    if data ~= nil and type(data) ~= 'table' then return false end
    send({ action = 'page:event', id = id, event = event, data = data or {} })
    return true
end

-- ------------------------------------------------- notify / textUI / progress ----

--- Drains the notify queue: at most Config.UI.MaxNotifyPerSecond per second, in
--- 100 ms ticks, and only while the queue is non-empty (DESIGN §9).
local function notifyTick()
    local now = GetGameTimer()
    notifyTickAt = now
    if now - notifyWindowAt >= 1000 then
        notifyWindowAt, notifySent = now, 0
    end
    local limit = uiCfg('MaxNotifyPerSecond', 10)
    for _ = 1, math.max(1, limit // 10) do
        if #notifyQueue == 0 or notifySent >= limit then break end
        local item = table.remove(notifyQueue, 1)
        notifyIndex[item.key] = nil
        item.key, item.action, item.id = nil, 'notify', newRequestId()
        send(item)
        notifySent = notifySent + 1
    end
    if #notifyQueue > 0 then
        SetTimeout(NOTIFY_TICK_MS, notifyTick)
    else
        notifyFlushing = false
    end
end

--- UI.notify({ message, type, duration, title }) or UI.notify(message, type).
function UI.notify(data, notifyType)
    local raw = data
    if type(data) == 'string' then
        raw = { message = data, type = notifyType }
    elseif type(data) ~= 'table' then
        return false
    end
    if type(raw.message) ~= 'string' or raw.message == '' then return false end
    local message = Utils.sanitize(raw.message, 256)
    local kind = NOTIFY_TYPES[raw.type] and raw.type or 'info'
    local duration = math.type(raw.duration) == 'integer'
        and Utils.clamp(raw.duration, 500, 60000)
        or uiCfg('NotifyDurationMs', 5000)
    local title = type(raw.title) == 'string' and raw.title ~= '' and Utils.sanitize(raw.title, 64) or nil
    local key = ('%s\0%s\0%s'):format(message, kind, title or '')
    local queued = notifyIndex[key]
    if queued then
        queued.count = queued.count + 1       -- coalesce instead of flooding the shell
        return true
    end
    if #notifyQueue >= MAX_NOTIFY_QUEUE then  -- the shell cannot keep up: drop the oldest
        local dropped = table.remove(notifyQueue, 1)
        notifyIndex[dropped.key] = nil
    end
    local entry = {
        key = key, message = message, type = kind, duration = duration, title = title, count = 1,
    }
    notifyQueue[#notifyQueue + 1] = entry
    notifyIndex[key] = entry
    if not notifyFlushing then
        notifyFlushing = true
        -- first one goes out at once, the rest land on the next 100 ms tick so a
        -- burst is spread instead of flooding the shell
        local since = GetGameTimer() - notifyTickAt
        if since >= NOTIFY_TICK_MS then
            notifyTick()
        else
            SetTimeout(NOTIFY_TICK_MS - since, notifyTick)
        end
    end
    return true
end

--- UI.textUI.show(key, text, { position, owner }) — `owner` scopes hide/isShown so
--- two producers (interactions, doors) cannot clear each other's prompt.
local function textUIShow(key, text, opts)
    if not Validate.value('id', key) then return false end
    if type(text) ~= 'string' or text == '' then return false end
    local position = type(opts) == 'table' and opts.position or 'bottom'
    if position ~= 'top' and position ~= 'bottom' and position ~= 'left' and position ~= 'right' then
        position = 'bottom'
    end
    local owner = type(opts) == 'table' and type(opts.owner) == 'string' and opts.owner ~= ''
        and opts.owner or 'default'
    textUI = { key = key, text = Utils.sanitize(text, 256), position = position, owner = owner }
    send({ action = 'textui:show', key = key, text = textUI.text, position = position })
    return true
end

--- Hides only when unqualified or called by the owner that showed it.
local function textUIHide(owner)
    if not textUI then return false end
    if owner ~= nil and owner ~= textUI.owner then return false end
    textUI = nil
    send({ action = 'textui:hide' })
    return true
end

local function textUIIsShown(owner)
    if not textUI then return false end
    return owner == nil or owner == textUI.owner
end

define('textUI', 'show', textUIShow)
define('textUI', 'hide', textUIHide)
define('textUI', 'isShown', textUIIsShown)

--- Stops the running progress bar and resolves its awaiting caller with false.
local function cancelProgress()
    local id = progressReq
    if not id then return false end
    progressCancellable = false
    send({ action = 'progress:stop', id = id })
    resolvePending(id, false)
    return true
end

--- UI.progress({ label, duration, canCancel }) -> completed:boolean — awaits.
--- `UI.progress` itself is the function, so cancel only exists under the flat
--- dotted key: UI['progress.cancel']() in core, Core.UI.progress.cancel() via the proxy.
function UI.progress(opts)
    if type(opts) ~= 'table' or math.type(opts.duration) ~= 'integer' then
        Log.error('UI.progress: { duration = <integer ms> } is required')
        return false
    end
    local duration = Utils.clamp(opts.duration, 100, 600000)
    local label = type(opts.label) == 'string' and Utils.sanitize(opts.label, 128) or ''
    cancelProgress()                      -- a second progress cancels the first
    if not nuiReady then
        Wait(duration)                    -- no shell: still honour the delay
        return true
    end
    progressCancellable = opts.canCancel == true
    local message = {
        action = 'progress:start', label = label, duration = duration,
        canCancel = opts.canCancel == true,
    }
    -- fail closed: a shell that never reports done means the action did NOT complete
    return awaitResult('progress', message, false, duration + PROGRESS_GRACE_MS) == true
end

UI['progress.cancel'] = cancelProgress

-- The progress bar takes no NUI focus, so the page never sees a key press: core
-- owns the cancel key itself. Not a restricted command — it only cancels the
-- local player's own cancellable progress bar.
RegisterCommand('core_cancel', function()
    if progressReq and progressCancellable then cancelProgress() end
end, false)
RegisterKeyMapping('core_cancel', 'Cancel current action', 'keyboard', uiCfg('CancelKey', 'X'))

-- ------------------------------------------------- menu / input / alert / hud ----

local FIELD_TYPES <const> = { text = true, number = true, select = true, checkbox = true }
local HUD_KEYS <const> = {
    visible = 'boolean', cash = 'number', bank = 'number', name = 'string', serverId = 'number',
    health = 'number', armour = 'number', speed = 'number', street = 'string', zone = 'string',
}

--- UI.menu.open({ title, items }) -> value|nil — awaits, nil on ESC/close.
--- Items are sent with their list index as `value`; the real value never leaves
--- Lua, so any value type (table, vector3) survives the round trip.
local function menuOpen(opts)
    if type(opts) ~= 'table' or type(opts.items) ~= 'table' then
        Log.error('UI.menu.open: { items = { { label = ..., value = ... } } } is required')
        return nil
    end
    local items, values = {}, {}
    for i = 1, #opts.items do
        local item = opts.items[i]
        if type(item) == 'table' and type(item.label) == 'string' then
            local index = #items + 1
            local value = item.value
            if value == nil then value = item.label end   -- and/or would swallow value = false
            values[index] = value
            items[index] = {
                label = Utils.sanitize(item.label, 128),
                description = type(item.description) == 'string' and Utils.sanitize(item.description, 256) or nil,
                icon = type(item.icon) == 'string' and Utils.sanitize(item.icon, 64) or nil,
                value = index,
                disabled = item.disabled == true,
            }
        end
    end
    if #items == 0 then return nil end
    local message = {
        action = 'menu:open',
        title = type(opts.title) == 'string' and Utils.sanitize(opts.title, 96) or '',
        items = items,
    }
    local index = math.tointeger(tonumber(awaitResult('menu', message)) or 0)
    if index and values[index] ~= nil then return values[index] end   -- value = false is a real answer
    return nil
end

local function menuClose()
    if not modal or modal.kind ~= 'menu' then return false end
    send({ action = 'menu:close' })
    resolvePending(modal.id, nil)
    return true
end

define('menu', 'open', menuOpen)
define('menu', 'close', menuClose)

--- UI.input.open({ title, fields, submit, cancel }) -> values|nil — awaits.
local function inputOpen(opts)
    if type(opts) ~= 'table' or type(opts.fields) ~= 'table' then
        Log.error('UI.input.open: { fields = { { name = ..., label = ... } } } is required')
        return nil
    end
    local fields = {}
    for i = 1, #opts.fields do
        local field = opts.fields[i]
        if type(field) == 'table' and Validate.value('id', field.name) and FIELD_TYPES[field.type or 'text'] then
            fields[#fields + 1] = {
                name = field.name,
                label = type(field.label) == 'string' and Utils.sanitize(field.label, 96) or field.name,
                type = field.type or 'text',
                options = type(field.options) == 'table' and field.options or nil,
                default = field.default,
                required = field.required == true,
                min = tonumber(field.min),
                max = tonumber(field.max),
                placeholder = type(field.placeholder) == 'string' and Utils.sanitize(field.placeholder, 64) or nil,
            }
        end
    end
    if #fields == 0 then return nil end
    local message = {
        action = 'input:open',
        title = type(opts.title) == 'string' and Utils.sanitize(opts.title, 96) or '',
        fields = fields,
        submit = type(opts.submit) == 'string' and Utils.sanitize(opts.submit, 32) or 'OK',
        cancel = type(opts.cancel) == 'string' and Utils.sanitize(opts.cancel, 32) or 'Cancel',
    }
    local raw = awaitResult('input', message)
    if type(raw) ~= 'table' then return nil end
    local out = {}
    for i = 1, #fields do
        local field = fields[i]
        local value = raw[field.name]
        if field.type == 'checkbox' then
            out[field.name] = value == true
        elseif field.type == 'number' then
            local num = tonumber(value)
            if num and num == num then
                if field.min then num = math.max(num, field.min) end
                if field.max then num = math.min(num, field.max) end
                out[field.name] = num
            end
        elseif field.type == 'select' then
            if field.options and Utils.contains(field.options, value) then out[field.name] = value end
        elseif type(value) == 'string' and value ~= '' then
            out[field.name] = Utils.sanitize(value, 256)
        end
        if field.required and out[field.name] == nil then return nil end
    end
    return out
end

define('input', 'open', inputOpen)

--- UI.alert({ title, message, confirm, cancel }) -> confirmed:boolean — awaits.
function UI.alert(opts)
    if type(opts) ~= 'table' or type(opts.message) ~= 'string' or opts.message == '' then
        Log.error('UI.alert: { message = "..." } is required')
        return false
    end
    local message = {
        action = 'alert:open',
        title = type(opts.title) == 'string' and Utils.sanitize(opts.title, 96) or '',
        message = Utils.sanitize(opts.message, 512),
        confirm = type(opts.confirm) == 'string' and Utils.sanitize(opts.confirm, 32) or 'OK',
        cancel = opts.cancel ~= false and (type(opts.cancel) == 'string' and Utils.sanitize(opts.cancel, 32) or 'Cancel') or false,
    }
    return awaitResult('alert', message, false) == true
end

--- Sends the merged HUD partial, at most one message per HUD_TICK_MS.
local function flushHud()
    hudTimer = false
    if next(hudPending) == nil then return end
    local message = hudPending
    hudPending = {}
    hudSentAt = GetGameTimer()
    message.action = 'hud:set'
    send(message)
end

--- UI.hud.set(partial) — core feeds cash/bank/name/serverId/faction itself (below).
local function hudSet(partial)
    if type(partial) ~= 'table' then return false end
    local out = {}
    for key, expected in pairs(HUD_KEYS) do
        local value = partial[key]
        if value ~= nil then
            if expected == 'number' then
                if Utils.isNumber(value) then out[key] = value end
            elseif expected == 'string' then
                if type(value) == 'string' then out[key] = Utils.sanitize(value, 64) end
            elseif type(value) == expected then
                out[key] = value
            end
        end
    end
    local minimap = partial.minimap
    if type(minimap) == 'table' and Utils.isNumber(minimap.x) and Utils.isNumber(minimap.y)
        and Utils.isNumber(minimap.w) and Utils.isNumber(minimap.h) then
        out.minimap = { x = minimap.x, y = minimap.y, w = minimap.w, h = minimap.h }
    end
    local faction = partial.faction
    if faction == false then
        out.faction = false
    elseif type(faction) == 'table' then
        out.faction = {
            name = type(faction.name) == 'string' and Utils.sanitize(faction.name, 64) or '',
            tag = type(faction.tag) == 'string' and Utils.sanitize(faction.tag, 8) or '',
            color = type(faction.color) == 'string' and Utils.sanitize(faction.color, 16) or nil,
        }
    end
    if next(out) == nil then return false end
    for key, value in pairs(out) do
        hud[key] = value
        hudPending[key] = value
    end
    if hudTimer then return true end        -- a flush is already scheduled: just merge
    local since = GetGameTimer() - hudSentAt
    if since >= HUD_TICK_MS then
        flushHud()
    else
        hudTimer = true
        SetTimeout(HUD_TICK_MS - since, flushHud)
    end
    return true
end

local function hudSetVisible(visible)
    return hudSet({ visible = visible == true })
end

local function hudIsVisible()
    return hud.visible == true
end

define('hud', 'set', hudSet)
define('hud', 'setVisible', hudSetVisible)
define('hud', 'isVisible', hudIsVisible)

-- ----------------------------------- keys / shard / spinner / stats / state ----

--- UI.keys.show({ { key = 'E', label = 'Interact' }, ... }) — instructional buttons.
local function keysShow(items)
    if type(items) ~= 'table' then return false end
    local out = {}
    for i = 1, math.min(#items, MAX_KEY_HINTS) do
        local item = items[i]
        if type(item) == 'table' and type(item.key) == 'string' and item.key ~= ''
            and type(item.label) == 'string' and item.label ~= '' then
            out[#out + 1] = { key = Utils.sanitize(item.key, 16), label = Utils.sanitize(item.label, 64) }
        end
    end
    if #out == 0 then
        Log.error('UI.keys.show: expected { { key = "E", label = "Interact" }, ... }')
        return false
    end
    keyHints = out
    send({ action = 'keys:show', items = out })
    return true
end

local function keysHide()
    if not keyHints then return false end
    keyHints = nil
    send({ action = 'keys:hide' })
    return true
end

define('keys', 'show', keysShow)
define('keys', 'hide', keysHide)

--- UI.shard({ title, subtitle?, duration = 4000, style = 'wasted'|'success'|'info' }).
function UI.shard(opts)
    if type(opts) ~= 'table' or type(opts.title) ~= 'string' or opts.title == '' then
        Log.error('UI.shard: { title = "..." } is required')
        return false
    end
    send({
        action = 'shard:show',
        title = Utils.sanitize(opts.title, 64),
        subtitle = type(opts.subtitle) == 'string' and Utils.sanitize(opts.subtitle, 96) or nil,
        duration = math.type(opts.duration) == 'integer' and Utils.clamp(opts.duration, 500, 60000) or SHARD_MS,
        style = SHARD_STYLES[opts.style] and opts.style or 'info',
    })
    return true
end

local function spinnerShow(text)
    if type(text) ~= 'string' or text == '' then return false end
    spinnerText = Utils.sanitize(text, 96)
    send({ action = 'spinner:show', text = spinnerText })
    return true
end

local function spinnerHide()
    if not spinnerText then return false end
    spinnerText = nil
    send({ action = 'spinner:hide' })
    return true
end

define('spinner', 'show', spinnerShow)
define('spinner', 'hide', spinnerHide)

--- Sends the merged stat bars, at most one message per STATS_TICK_MS.
local function flushStats()
    statsTimer = false
    if next(statsPending) == nil then return end
    local message = statsPending
    statsPending = {}
    statsSentAt = GetGameTimer()
    message.action = 'stats:set'
    send(message)
end

--- UI.stats.set({ hunger = { value = 80, min = 0, max = 100 }, thirst = 40 }) — coalesced.
local function statsSet(values)
    if type(values) ~= 'table' then return false end
    local count = 0
    for name, entry in pairs(values) do
        -- 'action' carries the message type and 'stats' is the JS container key,
        -- so neither can double as a stat name
        if type(name) == 'string' and name ~= 'action' and name ~= 'stats'
            and name:find('^[%w_%-]+$') then
            local bar
            if type(entry) == 'number' then
                bar = { value = entry }
            elseif type(entry) == 'table' and type(entry.value) == 'number' then
                bar = { value = entry.value, min = tonumber(entry.min), max = tonumber(entry.max) }
            end
            if bar then
                statsPending[name] = bar
                count = count + 1
            end
        end
    end
    if count == 0 then return false end
    if statsTimer then return true end
    local since = GetGameTimer() - statsSentAt
    if since >= STATS_TICK_MS then
        flushStats()
    else
        statsTimer = true
        SetTimeout(STATS_TICK_MS - since, flushStats)
    end
    return true
end

define('stats', 'set', statsSet)

--- Sends the keys that changed since the last flush; at most 4 flushes per second.
local function flushState()
    stateTimer = false
    local changed = statePending
    if next(changed) == nil then return end
    statePending = {}
    stateSentAt = GetGameTimer()
    send({ action = 'state:set', values = changed })   -- one message per flush, not per key
end

--- UI.state.set(key, value) — mirrors one replicated player state key into the page.
local function stateSet(key, value)
    if not Validate.value('id', key) then return false end
    local kind = type(value)
    if value == nil then
        value = NO_URL                      -- JSON null: the key is gone, not unchanged
    elseif kind == 'table' then
        if payloadTooBig(value) then return false end
    elseif kind ~= 'string' and kind ~= 'number' and kind ~= 'boolean' then
        return false
    end
    statePending[key] = value
    if stateTimer then return true end
    local since = GetGameTimer() - stateSentAt
    if since >= STATE_TICK_MS then
        flushState()
    else
        stateTimer = true
        SetTimeout(STATE_TICK_MS - since, flushState)
    end
    return true
end

define('state', 'set', stateSet)

--- UI.locale.set({ lang, strings }) — also accepts a flat strings table (§26).
local function localeSet(data)
    if type(data) ~= 'table' then return false end
    local cfg = Core.Config or Config
    send({
        action = 'locale:set',
        lang = type(data.lang) == 'string' and data.lang or (cfg and cfg.Locale) or 'en',
        strings = type(data.strings) == 'table' and data.strings or data,
    })
    return true
end

define('locale', 'set', localeSet)

--- Mirrors every replicated key of the local player into the page (ui_ready).
local function pushPlayerState()
    local Player = Core.Player
    for i = 1, #STATE_KEYS do
        local key = STATE_KEYS[i]
        local value = Player.get(key)
        if value ~= nil then stateSet(key, value) end
    end
end

--- Core's own locale strings, if lib/locale exists yet (written by another run).
local function pushLocale()
    local ok, data = pcall(function()
        local locale = Core.Locale
        return locale and locale.all and locale.all() or nil
    end)
    if ok and type(data) == 'table' then localeSet(data) end
end

-- ------------------------------------------------------- shell visibility ----
-- The shell is hidden while `hiddenReasons` is not empty (DESIGN §31). Reason keys
-- are namespaced by their owner, so no caller can clear one it does not own: the
-- game-state watchers below own 'game:*', a server push arrives as 'server:*' (it
-- is dispatched with caller `core`, so its key is stored verbatim) and a plugin
-- gets '<resource>:<reason>'. Natives verified with fxref on 2026-09-12 (client):
-- IsPauseMenuActive, IsScreenFadedOut, IsScreenFadingOut, IsPlayerSwitchInProgress,
-- IsWarningMessageActive, IsHudHidden, IsCinematicCamRendering.

local MAX_REASON_KEY <const> = 48
local REASON_PATTERN <const> = '^[%w_%-%.:]+$'
local DEFAULT_INTERVAL_MS <const> = 200
local MIN_INTERVAL_MS <const> = 50        -- a watcher loop must never approach Wait(0)
local IDLE_INTERVAL_MS <const> = 1000     -- every watcher disabled: sleep instead of spinning

--- One entry per auto-hide watcher: the `setAutoHide` name, its Config.UI.AutoHide
--- key, the reason it owns and the boolean natives it reads.
local WATCHERS <const> = {
    { name = 'pause', cfg = 'PauseMenu', default = true, reason = 'game:pause',
        read = function() return IsPauseMenuActive() end },
    { name = 'fade', cfg = 'ScreenFade', default = true, reason = 'game:fade',
        read = function() return IsScreenFadedOut() or IsScreenFadingOut() end },
    { name = 'switch', cfg = 'PlayerSwitch', default = true, reason = 'game:switch',
        read = function() return IsPlayerSwitchInProgress() end },
    { name = 'warning', cfg = 'Warning', default = true, reason = 'game:warning',
        read = function() return IsWarningMessageActive() end },
    -- off by default: IsHudHidden's exact semantics are undocumented and a wrong
    -- reading would hide the shell for good
    { name = 'hud', cfg = 'HudHidden', default = false, reason = 'game:hud',
        read = function() return IsHudHidden() end },
    { name = 'cinematic', cfg = 'Cinematic', default = true, reason = 'game:cinematic',
        read = function() return IsCinematicCamRendering() end },
}

local hiddenReasons = {}        -- reason key -> true
local hiddenCount = 0
local shellVisible = true       -- the last state the shell was told about
local autoHide = {}             -- watcher name -> enabled (Config at load, setAutoHide at runtime)
local watcherByName = {}

--- Config.UI.AutoHide value with a default (the whole table may be absent).
local function autoCfg(key, default)
    local cfg = uiCfg('AutoHide', nil)
    if type(cfg) ~= 'table' then return default end
    local value = cfg[key]
    if value == nil then return default end
    return value
end

for i = 1, #WATCHERS do
    local watcher = WATCHERS[i]
    watcherByName[watcher.name] = watcher
    autoHide[watcher.name] = autoCfg(watcher.cfg, watcher.default) == true
end

--- A fresh sorted array of the reason keys (hook payload and NUI message).
local function reasonList()
    local list = {}
    for key in pairs(hiddenReasons) do list[#list + 1] = key end
    table.sort(list)
    return list
end

--- Tells the shell what it should be doing right now (flip, and ui_ready).
local function sendVisible()
    send({ action = 'shell:visible', visible = shellVisible, reasons = reasonList() })
end

--- Applies a change of the reason set. One message and one hook per hidden<->visible
--- flip, never per reason change (§31.4). Hiding first closes whatever holds the
--- cursor — the open built-in modal (its await gets the same value as on ESC) and
--- the focused page — so nobody is stuck behind an invisible element.
local function applyVisibility()
    local visible = hiddenCount == 0
    if visible == shellVisible then return end
    shellVisible = visible
    if not visible then
        closeModal()
        if openPage then closeOne(openPage) end
        applyFocus()
    end
    sendVisible()
    Core.emitHook('uiVisibility', visible, reasonList())
end

--- Adds an already-namespaced key. `owner` is tracked in the registry so the reason
--- dies with a plugin that stops (§31.1); core's own keys need no bookkeeping.
local function addReason(key, owner)
    if hiddenReasons[key] then return false end
    hiddenReasons[key] = true
    hiddenCount = hiddenCount + 1
    if owner and owner ~= 'core' then Registry.track('uihide', key, owner) end
    applyVisibility()
    return true
end

--- Removes an already-namespaced key. Called without an owner from the registry
--- sweep, which has already dropped its own bookkeeping.
local function removeReason(key, owner)
    if not hiddenReasons[key] then return false end
    hiddenReasons[key] = nil
    hiddenCount = hiddenCount - 1
    if owner and owner ~= 'core' then Registry.untrack('uihide', key) end
    applyVisibility()
    return true
end

--- The key the CURRENT caller may touch, plus that caller. Core (and everything it
--- dispatches, including the §21 server pushes) uses the reason verbatim; a plugin
--- is confined to its own '<resource>:' space and can never clear a foreign reason.
local function reasonKeyFor(fn, reason)
    if reason == nil then reason = 'default' end
    if type(reason) ~= 'string' or not reason:find(REASON_PATTERN) then
        Log.error('UI.%s: invalid reason (%s)', fn, tostring(reason))
        return nil
    end
    local owner = Registry.getCaller()
    local key = owner == 'core' and reason or (owner .. ':' .. reason)
    if #key > MAX_REASON_KEY then
        Log.error("UI.%s: reason '%s' is longer than %d characters", fn, key, MAX_REASON_KEY)
        return nil
    end
    return key, owner
end

--- UI.hide(reason?) — hides the whole shell until every reason is gone.
function UI.hide(reason)
    local key, owner = reasonKeyFor('hide', reason)
    if not key then return false end
    addReason(key, owner)
    return true
end

--- UI.show(reason?) — drops this caller's reason; true when it removed one.
function UI.show(reason)
    local key, owner = reasonKeyFor('show', reason)
    if not key then return false end
    return removeReason(key, owner)
end

function UI.isHidden()
    return hiddenCount > 0
end

--- UI.hiddenReasons() — a copy of the reason keys, for admin and debug tooling.
function UI.hiddenReasons()
    return reasonList()
end

--- UI.setAutoHide('pause'|'fade'|'switch'|'warning'|'hud'|'cinematic', enabled) —
--- runtime toggle for one watcher; only `true` enables. Disabling one also clears
--- the reason it owns, so the shell never stays hidden by a watcher nobody reads.
function UI.setAutoHide(name, enabled)
    local watcher = type(name) == 'string' and watcherByName[name] or nil
    if not watcher then
        Log.error('UI.setAutoHide: unknown watcher (%s)', tostring(name))
        return false
    end
    local on = enabled == true
    autoHide[watcher.name] = on
    if not on then removeReason(watcher.reason) end
    return true
end

--- A reloaded shell forgets the server's reasons: the server pushes them
--- fire-and-forget and never re-sends them (§31.5).
local function clearServerReasons()
    for key in pairs(hiddenReasons) do
        if key:sub(1, 7) == 'server:' then removeReason(key) end
    end
end

-- A plugin that stops cannot leave the shell hidden behind it (§31.1).
Registry.onOwnerStop('uihide', function(id)
    removeReason(id)
end)

--- Config.UI.AutoHide.IntervalMs, clamped: this loop must never approach Wait(0).
local function watcherInterval()
    local ms = tonumber(autoCfg('IntervalMs', DEFAULT_INTERVAL_MS)) or DEFAULT_INTERVAL_MS
    if ms < MIN_INTERVAL_MS then return MIN_INTERVAL_MS end
    return ms
end

-- One thread for every game state (§31.3): at most six boolean natives per tick,
-- nothing per frame, and a NUI message only when the visible state flips.
CreateThread(function()
    while true do
        local active = false
        for i = 1, #WATCHERS do
            local watcher = WATCHERS[i]
            if autoHide[watcher.name] then
                active = true
                if watcher.read() then
                    addReason(watcher.reason)
                else
                    removeReason(watcher.reason)
                end
            end
        end
        local sleep = active and watcherInterval() or IDLE_INTERVAL_MS
        Wait(sleep)
    end
end)

-- ------------------------------------------------------------ NUI → Lua ----
-- Every callback answers cb(...) — a missing cb hangs the page's fetch().

RegisterNuiCallback('ui_ready', function(_, cb)
    local now = GetGameTimer()
    if uiReadyAt and now - uiReadyAt < 1000 then
        cb({ ok = true })               -- a ui_ready flood must not re-send the world
        return
    end
    uiReadyAt = now
    nuiReady = true
    resolveAllPending()                 -- the reloaded shell forgot every open modal
    clearServerReasons()                -- ... and the server's hide reasons, which nobody re-sends
    applyFocus()
    for id, page in pairs(pages) do
        send({
            action = 'page:register', id = id, type = page.type,
            script = page.script or NO_URL, style = page.style or NO_URL, keepInput = page.keepInput,
        })
    end
    local snapshot = { action = 'hud:set' }
    for key, value in pairs(hud) do snapshot[key] = value end
    send(snapshot)
    if textUI then
        send({ action = 'textui:show', key = textUI.key, text = textUI.text, position = textUI.position })
    end
    if keyHints then send({ action = 'keys:show', items = keyHints }) end
    if spinnerText then send({ action = 'spinner:show', text = spinnerText }) end
    pushPlayerState()
    pushLocale()
    for id in pairs(overlays) do
        send({ action = 'page:open', id = id, props = pages[id] and pages[id].props or {} })
    end
    local current = openPage and pages[openPage]
    if current then
        send({ action = 'page:open', id = openPage, props = current.props or {} })
    end
    send({ action = 'focus', focused = focusOwned })
    if not shellVisible then sendVisible() end   -- a shell mounted while hidden starts hidden (§31.4)
    Core.emitHook('uiReady')
    cb({ ok = true })
end)

RegisterNuiCallback('ui_close', function(data, cb)
    local id = type(data) == 'table' and data.page or nil
    if Validate.value('id', id) then
        UI.close(id)
    elseif modal then
        closeModal()
    else
        UI.close()
    end
    cb({ ok = true })
end)

RegisterNuiCallback('ui_event', function(data, cb)
    if type(data) ~= 'table' or not isPlainId(data.page) or not isPlainId(data.event) then
        cb({ ok = false })
        return
    end
    local payload = type(data.data) == 'table' and data.data or nil
    if payload and payloadTooBig(payload) then
        Log.warn("ui_event '%s:%s' dropped: payload too large", data.page, data.event)
        cb({ ok = false })
        return
    end
    TriggerEvent(('core:ui:%s:%s'):format(data.page, data.event), payload or {})
    cb({ ok = true })
end)

RegisterNuiCallback('ui_sound', function(data, cb)
    if type(data) == 'table' and type(data.name) == 'string' and #data.name <= 64
        and type(data.set) == 'string' and #data.set <= 64 then
        PlaySoundFrontend(-1, data.name, data.set, true)
    end
    cb({})
end)

--- Resolves the promise a built-in is awaiting; unknown ids are ignored.
local function resultCallback(name, kind, extract)
    RegisterNuiCallback(name, function(data, cb)
        if type(data) == 'table' then
            local id = math.tointeger(tonumber(data.id) or 0)
            local entry = id and pending[id]
            if entry and entry.kind ~= kind then
                -- a tampered page must not answer a menu await with an alert result
                Log.warn("NUI %s tried to answer a pending '%s' request", name, entry.kind)
            elseif entry then
                resolvePending(id, extract(data))
            end
        end
        cb({ ok = true })
    end)
end

resultCallback('menu_result', 'menu', function(data) return data.value end)
resultCallback('input_result', 'input', function(data) return type(data.values) == 'table' and data.values or nil end)
resultCallback('alert_result', 'alert', function(data) return data.confirmed == true end)
resultCallback('progress_cancel', 'progress', function() return false end)
resultCallback('progress_done', 'progress', function() return true end)

-- ------------------------------------------------ owner cleanup / HUD feed ----

-- A plugin that stops takes its pages with it (§2.3): close, then unregister.
Registry.onOwnerStop('page', function(id)
    UI.unregisterPage(id)
end)

Core.Net.on('core:client:notify', { 'table' }, function(data)
    UI.notify(data)
end)

--- Pushes the whole HUD snapshot from LocalPlayer.state (server writes, client reads).
local function refreshHud()
    local Player = Core.Player
    hudSet({
        name = Player.get('name'),
        cash = Player.get('cash'),
        bank = Player.get('bank'),
        serverId = Player.getServerId(),
        faction = Player.getFaction() or false,
    })
end

CreateThread(function()
    Wait(0)                                   -- let every client file finish loading first
    local Player = Core.Player
    while (Player.getServerId() or 0) <= 0 do
        Wait(1000)                            -- onChange needs 'player:<serverId>' to exist
    end
    Player.onChange('cash', function(value) hudSet({ cash = value }) end)
    Player.onChange('bank', function(value) hudSet({ bank = value }) end)
    Player.onChange('name', function(value) hudSet({ name = value }) end)
    Player.onChange('faction', function(value) hudSet({ faction = value or false }) end)
    -- nil key filter = every key of this player's bag (§8): the page mirrors the
    -- replicated state, minus the bulky keys it has no use for
    local bag = 'player:' .. Player.getServerId()
    AddStateBagChangeHandler(nil, bag, function(bagName, key, value)
        if bagName ~= bag or type(key) ~= 'string' or STATE_SKIP[key] then return end
        stateSet(key, value)
    end)
    refreshHud()
    pushPlayerState()
end)

Core.on('playerLoaded', refreshHud)

-- Focus watchdog (§9): 500 ms, releases a cursor nothing is holding any more.
CreateThread(function()
    while true do
        Wait(500)
        -- only ever release focus core itself took: NUI focus is global client
        -- state, so touching it while another resource holds it steals the cursor
        if focusOwned and not openPage and not modal then
            applyFocus()
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- synchronous: focus first, then unblock every coroutine still awaiting the shell
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    focusOwned, focusKeepInput = false, false
    openPage, textUI = nil, nil
    resolveAllPending()
end)

-- end of file
