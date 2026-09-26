-- core/server/ui.lua
-- Core.UI server namespace (DESIGN §21): every call targets one player and is
-- executed by that player's client/ui.lua.
--   * non-awaiting ops travel over ONE net event, `core:client:ui (op, args)`,
--     handled by client/ui_remote.lua; `args` is the positional argument list.
--   * the four modal ops (progress/menu/input/alert) use
--     Core.Callback.awaitClientTimeout(src, 'core:ui:<kind>', Config.UI.ModalTimeoutMs,
--     opts) and return the player's answer (nil/false on timeout, ESC or a drop).
-- Sub-namespaces are stored BOTH flat (`Core.UI['menu.open']`, what the export
-- proxy looks up, DESIGN §2.2) and nested (`Core.UI.menu.open`), like client/ui.lua.
-- Natives verified with fxref on 2026-09-12: GetPlayerName (apiset client+server,
-- server form `GetPlayerName(playerSrc) -> string`).
-- Runtime helper: TriggerClientEvent.

local UI = {}
Core.UI = UI

local Validate = Core.Validate
local Log = Core.Log
local Utils = Core.Utils

local UI_EVENT <const> = 'core:client:ui'
local MAX_TEXT <const> = 256
local MAX_LABEL <const> = 128
local MAX_KEY_ITEMS <const> = 12
local SHARD_STYLES <const> = { wasted = true, success = true, info = true }
local DEFAULT_MODAL_TIMEOUT_MS <const> = 300000
local DEFAULT_SHARD_MS <const> = 4000
-- A progress bar answers when it finishes, so it only needs its own duration plus
-- slack for the round trip; everything else waits for the player.
local PROGRESS_GRACE_MS <const> = 5000
-- How much early a "completed" answer may arrive before it is treated as a lie.
local PROGRESS_TOLERANCE_MS <const> = 250
local MAX_TITLE <const> = 96
local MAX_BUTTON <const> = 32
local Forms = Core.UIForms
local menus, menuSequence = {}, 0
-- Shell visibility (DESIGN §31.5): the reason a server push adds to the client's
-- hide set, namespaced as 'server:<reason>' so no plugin can clear it.
local MAX_REASON <const> = 32
local REASON_PATTERN <const> = '^[%w_%-%.:]+$'
local MAX_PATCH_PATH <const> = 160          -- the client's own bound for UI.patch (§38.10)

--- Sub-namespace tables: the flat dotted key is the one exports.core:call resolves.
UI.textUI = {}
UI.menu = {}
UI.input = {}
UI.keys = {}
UI.spinner = {}
UI.hud = {}

local function define(sub, name, fn)
    UI[sub .. '.' .. name] = fn
    UI[sub][name] = fn
end

--- Config.UI value with a default (Core.Config is core's own config, DESIGN §2.0).
local function uiCfg(key, default)
    local cfg = Core.Config or Config
    local value = cfg and cfg.UI and cfg.UI[key]
    if value == nil then return default end
    return value
end

--- A connected player id, or nil. Identity always comes from the caller's `src`
--- argument here (server API, not a net payload) but it is still range-checked
--- and looked up before anything is sent.
local function toSrc(value)
    if not Validate.value('src', value) then return nil end
    local name = GetPlayerName(value)
    if name == nil or name == '' then return nil end
    return value
end

--- Sends one non-awaiting op to a single client. `args` is positional.
local function push(src, op, args)
    local target = toSrc(src)
    if not target then
        Log.error('UI.%s: %s is not a connected player', op, tostring(src))
        return false
    end
    TriggerClientEvent(UI_EVENT, target, op, args or {})
    return true
end

-- ------------------------------------------------------------- pages ----

--- UI.open(src, id, props?) — opens a registered page/overlay on that client.
function UI.open(src, id, props)
    if not Validate.value('id', id) then
        Log.error('UI.open: invalid page id (%s)', tostring(id))
        return false
    end
    if props ~= nil and type(props) ~= 'table' then
        Log.error("UI.open('%s'): props must be a table", id)
        return false
    end
    return push(src, 'open', { id, props })
end

--- UI.close(src, id?) — nil id closes whatever exclusive page is open.
function UI.close(src, id)
    if id ~= nil and not Validate.value('id', id) then
        Log.error('UI.close: invalid page id (%s)', tostring(id))
        return false
    end
    return push(src, 'close', { id })
end

--- UI.send(src, id, event, data) — pushes an event into an open page.
function UI.send(src, id, event, data)
    if not Validate.value('id', id) or not Validate.value('id', event) then
        Log.error('UI.send: invalid page id/event (%s/%s)', tostring(id), tostring(event))
        return false
    end
    if data ~= nil and type(data) ~= 'table' then
        Log.error("UI.send('%s', '%s'): data must be a table", id, event)
        return false
    end
    return push(src, 'send', { id, event, data })
end

--- UI.update(src, id, partial) — shallow merge of top-level keys into that page's
--- props on one client (§38.10). The client re-validates every key and value; this
--- end only keeps a malformed call off the wire.
function UI.update(src, id, partial)
    if not Validate.value('id', id) then
        Log.error('UI.update: invalid page id (%s)', tostring(id))
        return false
    end
    if type(partial) ~= 'table' then
        Log.error("UI.update('%s'): partial must be a table", id)
        return false
    end
    return push(src, 'update', { id, partial })
end

--- UI.patch(src, id, path, value) — one deep op; a nil value deletes the key, so
--- the argument list really is two long in that case (the client unpacks by hand).
function UI.patch(src, id, path, value)
    if not Validate.value('id', id) then
        Log.error('UI.patch: invalid page id (%s)', tostring(id))
        return false
    end
    if type(path) ~= 'string' or path == '' or #path > MAX_PATCH_PATH then
        Log.error("UI.patch('%s'): invalid path (%s)", id, tostring(path))
        return false
    end
    return push(src, 'patch', { id, path, value })
end

--- UI.notify(src, message, type?, duration?) — alias of Core.Notify.send (§4.7).
function UI.notify(src, message, kind, duration)
    local Notify = Core.Notify
    if not Notify then return false end
    return Notify.send(src, message, kind, duration)
end

-- ------------------------------------------------------- text UI / hud ----

local function textUIShow(src, key, text, opts)
    if not Validate.value('id', key) then
        Log.error('UI.textUI.show: invalid key (%s)', tostring(key))
        return false
    end
    if type(text) ~= 'string' or text == '' then
        Log.error("UI.textUI.show('%s'): text must be a non-empty string", key)
        return false
    end
    local position = type(opts) == 'table' and opts.position or nil
    return push(src, 'textUI.show', { key, Utils.sanitize(text, MAX_TEXT), { position = position } })
end

local function textUIHide(src)
    return push(src, 'textUI.hide', {})
end

define('textUI', 'show', textUIShow)
define('textUI', 'hide', textUIHide)

--- UI.hud.setVisible(src, bool) — shows/hides the whole HUD on that client.
local function hudSetVisible(src, visible)
    return push(src, 'hud.setVisible', { visible == true })
end

define('hud', 'setVisible', hudSetVisible)

-- ------------------------------------------------------------- visibility ----
-- Fire-and-forget like every other push: the server keeps no record of which
-- reasons a client holds, and a NUI reload drops them (§31.5).

--- 'server:<reason>' for a valid reason, nil (and a log line) for anything else.
local function reasonKey(op, reason)
    if reason == nil then reason = 'default' end
    if type(reason) ~= 'string' or #reason > MAX_REASON or not reason:find(REASON_PATTERN) then
        Log.error('UI.%s: invalid reason (%s)', op, tostring(reason))
        return nil
    end
    return 'server:' .. reason
end

--- UI.hide(src, reason?) — hides that player's whole NUI shell until every reason
--- is gone. An open built-in modal and the focused page are closed client-side.
function UI.hide(src, reason)
    local key = reasonKey('hide', reason)
    if not key then return false end
    return push(src, 'hide', { key })
end

--- UI.show(src, reason?) — drops this server reason again; other reasons (the
--- game-state watchers, a plugin's own) keep the shell hidden on their own.
function UI.show(src, reason)
    local key = reasonKey('show', reason)
    if not key then return false end
    return push(src, 'show', { key })
end

-- --------------------------------------------- key hints / shard / spinner ----

--- UI.keys.show(src, { { key = 'E', label = 'Interact' }, ... }) — instructional buttons.
local function keysShow(src, items)
    if type(items) ~= 'table' or #items == 0 then
        Log.error('UI.keys.show: { { key = "E", label = "..." }, ... } is required')
        return false
    end
    local list = {}
    for i = 1, math.min(#items, MAX_KEY_ITEMS) do
        local item = items[i]
        if type(item) == 'table' and type(item.key) == 'string' and type(item.label) == 'string' then
            list[#list + 1] = {
                key = Utils.sanitize(item.key, 16),
                label = Utils.sanitize(item.label, 64),
            }
        end
    end
    if #list == 0 then
        Log.error('UI.keys.show: no usable { key, label } entry')
        return false
    end
    return push(src, 'keys.show', { list })
end

local function keysHide(src)
    return push(src, 'keys.hide', {})
end

define('keys', 'show', keysShow)
define('keys', 'hide', keysHide)

--- UI.shard(src, { title, subtitle?, duration = 4000, style = 'wasted'|'success'|'info' }).
function UI.shard(src, opts)
    if type(opts) ~= 'table' or type(opts.title) ~= 'string' or opts.title == '' then
        Log.error('UI.shard: { title = "..." } is required')
        return false
    end
    local duration = math.type(opts.duration) == 'integer' and opts.duration or DEFAULT_SHARD_MS
    local style = (type(opts.style) == 'string' and SHARD_STYLES[opts.style]) and opts.style or 'info'
    return push(src, 'shard', { {
        title = Utils.sanitize(opts.title, MAX_LABEL),
        subtitle = type(opts.subtitle) == 'string' and Utils.sanitize(opts.subtitle, MAX_LABEL) or nil,
        duration = Utils.clamp(duration, 500, 60000),
        style = style,
    } })
end

local function spinnerShow(src, text)
    if type(text) ~= 'string' or text == '' then
        Log.error('UI.spinner.show: text must be a non-empty string')
        return false
    end
    return push(src, 'spinner.show', { Utils.sanitize(text, MAX_LABEL) })
end

local function spinnerHide(src)
    return push(src, 'spinner.hide', {})
end

define('spinner', 'show', spinnerShow)
define('spinner', 'hide', spinnerHide)

-- ------------------------------------------------------------- modals ----
-- Each modal is a client callback (client/ui_remote.lua) that resolves when the
-- player answers, so the calling coroutine suspends: never call these from a
-- loop over players, and never from an event handler that must return fast.

--- How long a player may leave a modal open (Config.UI.ModalTimeoutMs).
local function modalTimeout()
    local ms = uiCfg('ModalTimeoutMs', DEFAULT_MODAL_TIMEOUT_MS)
    return math.type(ms) == 'integer' and ms or DEFAULT_MODAL_TIMEOUT_MS
end

--- Sends one modal to a client and suspends until it answers (nil on timeout).
local function awaitModal(src, kind, opts, ms)
    local target = toSrc(src)
    if not target then
        Log.error('UI.%s: %s is not a connected player', kind, tostring(src))
        return nil
    end
    if type(opts) ~= 'table' then
        Log.error('UI.%s: an options table is required', kind)
        return nil
    end
    return Core.Callback.awaitClientTimeout(target, 'core:ui:' .. kind, ms or modalTimeout(), opts)
end

--- UI.progress(src, { label, duration, canCancel }) -> completed:boolean.
--- The client answers when its bar finishes, so the answer is only believed when
--- at least the requested time really elapsed on the server.
function UI.progress(src, opts)
    local duration = type(opts) == 'table' and type(opts.duration) == 'number'
        and math.tointeger(opts.duration) or nil
    if not duration then
        Log.error('UI.progress: { duration = <integer ms> } is required')
        return false
    end
    local startedAt = GetGameTimer()
    local done = awaitModal(src, 'progress', {
        label = type(opts.label) == 'string' and Utils.sanitize(opts.label, MAX_LABEL) or nil,
        duration = duration,
        canCancel = opts.canCancel == true,
    }, duration + PROGRESS_GRACE_MS)
    if done ~= true then return false end
    return (GetGameTimer() - startedAt) >= (duration - PROGRESS_TOLERANCE_MS)
end

--- UI.menu.open(src, { title, items }) -> value|nil (nil on ESC/timeout).
--- The real values never leave the server: the client is sent one index per row
--- and its answer counts only as an index into the server's own item list.
local function menuOpen(src, opts)
    if not toSrc(src) or type(opts) ~= 'table' then return nil end
    if opts.onChange ~= nil and not Utils.isCallable(opts.onChange) then return nil end
    local sent, records = Forms.menu(opts.items)
    if not sent then return nil end
    menuSequence = menuSequence + 1
    local token = menuSequence
    local owner = Core.Registry.getCaller()
    local entry = { token = token, records = records, owner = owner, onChange = opts.onChange, changedAt = -1000 }
    if menus[src] then Core.Registry.untrack('serverMenu', tostring(menus[src].token)) end
    menus[src] = entry
    Core.Registry.track('serverMenu', tostring(token), owner)
    local answer = awaitModal(src, 'menu', {
        title = type(opts.title) == 'string' and Utils.sanitize(opts.title, MAX_TITLE) or '',
        items = sent, _menuToken = token,
    })
    if menus[src] ~= entry then return nil end
    menus[src] = nil
    Core.Registry.untrack('serverMenu', tostring(token))
    return Forms.menuValue(records, answer)
end

Core.Callback.register('core:ui:menuChange', { 'number', 'table' }, function(src, token, data)
    local entry = menus[src]
    if not entry or entry.busy or entry.token ~= token or GetGameTimer() - entry.changedAt < 100 then return false end
    local ok, item, selected = Forms.menuChange(entry.records, data)
    if not ok then return false end
    entry.changedAt = GetGameTimer()
    local callback = item.onChange or entry.onChange
    if callback then
        entry.busy = true
        local success, err = Core.Registry.withCaller(entry.owner, callback, item.value, selected, item.row.selected)
        entry.busy = false
        if not success then Log.error('UI.menu onChange failed: %s', tostring(err)) end
    end
    return true
end)

Core.Registry.onOwnerStop('serverMenu', function(key)
    for src, entry in pairs(menus) do
        if tostring(entry.token) == key then
            menus[src] = nil
            TriggerClientEvent(UI_EVENT, src, 'menu.close', { entry.token })
            break
        end
    end
    Core.Registry.untrack('serverMenu', key)
end)

AddEventHandler('playerDropped', function()
    local src = source
    local entry = menus[src]
    if entry then Core.Registry.untrack('serverMenu', tostring(entry.token)); menus[src] = nil end
end)

local function inputOpen(src, opts)
    if type(opts) ~= 'table' then return nil end
    local fields = Forms.fields(opts.fields)
    if not fields then return nil end
    local answer = awaitModal(src, 'input', {
        title = type(opts.title) == 'string' and Utils.sanitize(opts.title, MAX_TITLE) or '', fields = fields,
        submit = type(opts.submit) == 'string' and Utils.sanitize(opts.submit, MAX_BUTTON) or 'OK',
        cancel = type(opts.cancel) == 'string' and Utils.sanitize(opts.cancel, MAX_BUTTON) or 'Cancel',
    })
    return Forms.answer(fields, answer)
end

define('menu', 'open', menuOpen)
define('input', 'open', inputOpen)

--- UI.alert(src, { title, message, confirm, cancel }) -> confirmed:boolean.
function UI.alert(src, opts)
    local confirmed = awaitModal(src, 'alert', opts)
    return confirmed == true
end
