--- core / client/ui.lua — Core.UI: the NUI bridge (DESIGN §6.10, §38).
--- Owns the page registry (one exclusive page + overlays + plugin modals), the
--- focus stack (§38.9), page state (snapshot/patch/feed, §38.10), the NUI↔Lua
--- request pair (§38.8), the built-ins (notify, textUI, progress, menu, input,
--- alert, hud), every NUI callback and the focus watchdog.
--- Natives verified with fxref on 2026-09-12 and 2026-09-18: SetNuiFocus,
--- SetNuiFocusKeepInput, PlaySoundFrontend, RegisterKeyMapping (client),
--- RegisterCommand, AddStateBagChangeHandler (shared), GetGameTimer (client+server),
--- GetCurrentResourceName (shared).
--- Runtime helpers: SendNUIMessage (table form), RegisterNuiCallback, promise,
--- Citizen.Await, SetTimeout.
--- Note: `UI.progress` is the function itself, so inside core its canceller is only
--- reachable through the flat key — `UI['progress.cancel']()`, not `UI.progress.cancel()`.
--- `Core.UIInternal` is the seam client/ui_plugins.lua uses; it is blocked from the
--- export (client/api.lua INTERNAL_NS), so no plugin can reach it.

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
local PAGE_TYPES <const> = { page = true, overlay = true, modal = true }
local MAX_PATCH_OPS <const> = 64          -- more than this costs less as one snapshot (§38.10)
local MAX_PATH_DEPTH <const> = 8
local MAX_PATH_LEN <const> = 160
local FEED_MIN_MS <const> = 16            -- one frame at 60 fps; never faster
local FEED_MAX_MS <const> = 1000
local MAX_REQUEST_NAME <const> = 64
local REQUEST_NAME_PATTERN <const> = '^[%w_%-%.:]+$'
local REQUEST_MIN_MS <const> = 1000
-- An explicit JSON null (dkjson's json.null encodes to `null`, falsy in JS like
-- false): a key the page must DROP, as opposed to one that simply did not change.
local JSON_NULL <const> = (type(json) == 'table' and json.null) or false
local NOTIFY_TYPES <const> = { info = true, success = true, error = true, warning = true }
local SHARD_STYLES <const> = { wasted = true, success = true, info = true }
-- replicated keys forwarded to the page as `state:set` (§21); bulky ones stay in Lua
local STATE_SKIP <const> = { stats = true, attachments = true }
local STATE_KEYS <const> = { 'loaded', 'name', 'charId', 'cash', 'bank', 'faction', 'group', 'dead' }

local pages = {}                    -- id -> { owner, type, keepInput, registered, props }
local overlays = {}                 -- id -> true (visible overlays)
local openPage = nil                -- id of the exclusive page, or nil
local modals = {}                   -- open plugin modals (type = 'modal'), top last (§38.9)
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
local focusCursor = true            -- pages/modals take the cursor; the chat input never does
local focusSignature = nil          -- last stack the shell was told about ('' = empty)
local chatTyping = false            -- §23: the CEF chat input owns keyboard while open
local requestSeq = 0
local patchQueue = {}               -- page id -> { snapshot, ops } waiting for the next tick
local feedDirty = {}                -- channel -> { key = value } waiting for the feed flush
local feedTimer = false
local feedActive = {}               -- channel -> true while a mounted component reads it
local requestHandlers = {}          -- owner -> { [name] = handler } for ui_request
local heldRequests = {}             -- key -> { owner, answer } — NUI cb's held until answered
local uiRequests = {}               -- rid -> { promise } — Lua → NUI awaits

--- The seam client/ui_plugins.lua uses; never part of Core.UI, which any plugin
--- can call through the export. Filled in from both files.
local UIInternal = {}
Core.UIInternal = UIInternal

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

--- The focus stack, top last (DESIGN §38.9): chat (1) < page (2) < modal (3) <
--- system (4). Derived on every change instead of stored, so no path can leave a
--- stale entry behind — removing a page removes its entry by construction.
local function focusStack()
    local stack = {}
    if chatTyping then
        stack[#stack + 1] = { key = 'chat', layer = 'chat', owner = 'core' }
    end
    if openPage then
        local page = pages[openPage]
        stack[#stack + 1] = { key = 'page:' .. openPage, layer = 'page', id = openPage,
            owner = page and page.owner or 'core' }
    end
    for i = 1, #modals do
        local id = modals[i]
        local page = pages[id]
        stack[#stack + 1] = { key = 'modal:' .. id, layer = 'modal', id = id,
            owner = page and page.owner or 'core' }
    end
    if modal then
        stack[#stack + 1] = { key = 'system:' .. modal.kind, layer = 'system', owner = 'core' }
    end
    return stack
end

--- Cheap identity of a stack: only the keys can change what the shell draws.
local function stackSignature(stack)
    local keys = {}
    for i = 1, #stack do keys[i] = stack[i].key end
    return table.concat(keys, '|')
end

--- The top entry alone decides focus: SetNuiFocus(true, cursor) +
--- SetNuiFocusKeepInput(keepInput), an empty stack releases both (§38.9). The
--- natives are called only when that triple changes; the `focus` message also goes
--- out when only the stack moved, because the shell mirrors it for z-order and
--- `inert`. The CEF chat input never takes a cursor and loses the keyboard the
--- moment anything above it appears (§23).
local function applyFocus()
    if chatTyping and (openPage ~= nil or modal ~= nil or #modals > 0) then
        chatTyping = false
        send({ action = 'chat:open', open = false })
    end
    local stack = focusStack()
    local top = stack[#stack]
    local want = top ~= nil
    local cursor = want and top.layer ~= 'chat'
    local keep = false
    if want and (top.layer == 'page' or top.layer == 'modal') then
        local page = pages[top.id]
        keep = page ~= nil and page.keepInput == true
    end
    local signature = stackSignature(stack)
    local sameTriple = want == focusOwned and keep == focusKeepInput and cursor == focusCursor
    if sameTriple and signature == focusSignature then return end
    if not sameTriple then
        focusOwned, focusKeepInput, focusCursor = want, keep, cursor
        if want then
            SetNuiFocus(true, cursor)
            SetNuiFocusKeepInput(keep)
        else
            SetNuiFocusKeepInput(false)
            SetNuiFocus(false, false)
        end
    end
    focusSignature = signature
    send({ action = 'focus', focused = want, stack = stack })
end

--- Internal seam for client/chat.lua (§23): the chat input is open. Not part of the
--- public UI API — core's own chat drives it, plugins use pages.
local function setChatTyping(open)
    local want = open == true
    if chatTyping == want then return false end
    chatTyping = want
    applyFocus()
    return true
end

UI['chat.setTyping'] = setChatTyping

--- Internal getter for client/chat.lua (§23): is the chat input's keyboard held right
--- now. Distinct from UI.isFocused(), which is also true for pages and modals.
UI['chat.isTyping'] = function()
    return chatTyping
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

-- ------------------------------------------------------- page state (§38.10) ----
-- `update`/`patch` queue per page and leave as ONE `page:patch` on the next tick;
-- every other message for that page flushes the queue first, so the page never sees
-- an event before the state change that preceded it in Lua. The same ops are applied
-- to `pages[id].props` (the replay copy), so a shell reload restores CURRENT state.

--- Is `id` open as a plugin modal right now, and at which position.
local function modalIndex(id)
    for i = 1, #modals do
        if modals[i] == id then return i end
    end
    return nil
end

--- 'slots.12.count' → { 'slots', '12', 'count' }, or nil when the path is not
--- `seg(.seg){0,7}` of [%w_%-] (a forged deep path must never walk a props table).
local function splitPath(path)
    if type(path) ~= 'string' or path == '' or #path > MAX_PATH_LEN then return nil end
    local segs = {}
    for seg in path:gmatch('[^%.]+') do
        if #segs >= MAX_PATH_DEPTH or not seg:find('^[%w_%-]+$') then return nil end
        segs[#segs + 1] = seg
    end
    -- gmatch swallows empty segments, so 'a..b' and 'a.' are caught here
    if #segs == 0 or #segs ~= select(2, path:gsub('%.', '')) + 1 then return nil end
    return segs
end

--- The Lua key a path segment means for `container` — LUA's view of the data, so
--- `patch(id, 'slots.' .. slot, v)` with a Lua index hits that very element (§38.10).
--- R1 list element: the container is a list (a sequence, or an empty table — JSON
--- had to pick one) and the segment is an integer 1..#t+1, which is `t[n]` (#t+1
--- appends). R2 map key: everything else — an integer key the map already has, else
--- the plain string key. The second return marks an integer index that fell OUTSIDE
--- a non-empty list: still applied as a map key, but it leaves a hole the shell has
--- to mirror, so the caller warns.
local function keyFor(container, seg)
    local n = math.tointeger(tonumber(seg))
    local len = #container
    local isList = len > 0 or next(container) == nil
    if n and isList and n >= 1 and n <= len + 1 then return n, false end
    if n and container[n] ~= nil then return n, len > 0 end
    return seg, n ~= nil and len > 0
end

--- One Log.warn per page and path: a hole in a list is a design mistake, not an
--- error, and the same loop would otherwise print it every frame.
local function warnHole(id, path, why)
    local page = pages[id]
    if not page then return end
    local seen = page.patchWarned
    if not seen then
        seen = {}
        page.patchWarned = seen
    end
    if seen[path] then return end
    seen[path] = true
    Log.warn("UI.patch('%s', '%s'): %s — send the list whole with UI.update instead", id, path, why)
end

--- Applies one op to the replay copy. Intermediate tables are created on the way
--- for a write; a delete stops as soon as the path is missing.
local function applyOp(id, props, segs, path, value, hasValue)
    local container = props
    for i = 1, #segs - 1 do
        local key, outside = keyFor(container, segs[i])
        if outside then warnHole(id, path, ('segment %d is outside its list'):format(i)) end
        local child = container[key]
        if type(child) ~= 'table' then
            if not hasValue then return end
            child = {}
            container[key] = child
        end
        container = child
    end
    local key, outside = keyFor(container, segs[#segs])
    if outside then warnHole(id, path, 'the index is outside the list') end
    local len = #container
    if not hasValue and math.type(key) == 'integer' and len > 0 and key < len then
        warnHole(id, path, 'deleting in the middle of a list leaves a hole')
    end
    container[key] = hasValue and value or nil
end

--- Sends whatever is queued for `id`. Nothing is sent for a page that went away;
--- a queue that overflowed leaves as one `page:open` snapshot of the replay copy.
local function flushPage(id)
    local queue = patchQueue[id]
    if not queue then return end
    patchQueue[id] = nil
    local page = pages[id]
    if not page then return end
    if queue.snapshot then
        if openPage == id or overlays[id] or modalIndex(id) then
            send({ action = 'page:open', id = id, props = page.props or {} })
        end
    elseif #queue.ops > 0 then
        send({ action = 'page:patch', id = id, ops = queue.ops })
    end
end

--- Queues one wire op (`{ p = path, v = value }`; no `v` deletes) for the next tick.
local function queueOp(id, op)
    local queue = patchQueue[id]
    if not queue then
        queue = { snapshot = false, ops = {} }
        patchQueue[id] = queue
        SetTimeout(0, function() flushPage(id) end)
    end
    if queue.snapshot then return end
    queue.ops[#queue.ops + 1] = op
    if #queue.ops > MAX_PATCH_OPS then
        queue.snapshot, queue.ops = true, {}
    end
end

--- Every page message but `page:patch` itself flushes that page's queue first.
local function sendFor(id, message)
    flushPage(id)
    send(message)
end

-- ---------------------------------------------------------------- pages ----

--- Hides one page/overlay/modal without touching focus. Returns whether it was shown.
local function closeOne(id)
    if overlays[id] then
        overlays[id] = nil
    elseif openPage == id then
        openPage = nil
    else
        local index = modalIndex(id)
        if not index then return false end
        table.remove(modals, index)
    end
    sendFor(id, { action = 'page:close', id = id })
    return true
end

--- Closes every open plugin modal, top first, without touching focus.
local function closeModals()
    for i = #modals, 1, -1 do
        local id = modals[i]
        modals[i] = nil
        sendFor(id, { action = 'page:close', id = id })
    end
end

--- UI.registerPage(id, { type = 'page'|'overlay'|'modal', keepInput? })
--- The component comes from the owning resource's UI plugin (§38): Lua declares
--- the id, its type and who owns it, the shell resolves it. `modal` pages stack
--- above the exclusive page, any number of them (§38.9).
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
    if opts.script ~= nil or opts.style ~= nil then
        Log.error("UI.registerPage('%s'): script/style were removed — a page's code now comes "
            .. "from its own resource's UI plugin (core_ui '<dir>' + ui/dist, DESIGN §38)", id)
        return false
    end
    local entry = {
        owner = owner,
        type = PAGE_TYPES[opts.type] and opts.type or 'page',
        keepInput = opts.keepInput == true,
        registered = true,
    }
    pages[id] = entry
    Registry.track('page', id, owner)
    send({
        action = 'page:register', id = id, type = entry.type,
        keepInput = entry.keepInput, owner = owner,
    })
    return true
end

function UI.unregisterPage(id)
    local page = pages[id]
    if not page then return false end
    closeOne(id)
    pages[id] = nil
    patchQueue[id] = nil            -- nothing queued can outlive its page
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
    elseif page.type == 'modal' then
        if not modalIndex(id) then modals[#modals + 1] = id end   -- re-open = props only
    elseif openPage ~= id then
        -- a different exclusive page replaces the whole layer, modals included
        closeModals()
        if openPage then closeOne(openPage) end
        openPage = id
    end
    page.props = props or {}            -- kept so ui_ready can restore the page after a shell reload
    -- a snapshot supersedes whatever was queued: the ops are already in props
    patchQueue[id] = nil
    send({ action = 'page:open', id = id, props = page.props })
    applyFocus()
    return true
end

--- UI.close(id?) — nil closes the top plugin modal, or the exclusive page when
--- no modal is open.
function UI.close(id)
    if id == nil then
        if #modals > 0 then
            closeOne(modals[#modals])
        elseif openPage then
            closeOne(openPage)
        end
    else
        closeOne(id)
    end
    applyFocus()
end

--- Closes every page, overlay, plugin modal and built-in, then releases focus.
function UI.closeAll()
    closeModals()
    if openPage then closeOne(openPage) end
    for id in pairs(overlays) do
        overlays[id] = nil
        sendFor(id, { action = 'page:close', id = id })
    end
    closeModal()
    UI['progress.cancel']()
    UI['textUI.hide']()
    UI['keys.hide']()
    UI['spinner.hide']()
    applyFocus()
end

function UI.isOpen(id)
    return openPage == id or overlays[id] == true or modalIndex(id) ~= nil
end

function UI.getOpenPage()
    return openPage
end

function UI.isFocused()
    return focusOwned
end

--- Pushes an event into a page or a plugin channel: NUI 'page:event' →
--- CoreUI.on(id, event, fn) / the SDK's `page.on` / `nui.on` (§38.8).
function UI.send(id, event, data)
    local known = pages[id] ~= nil
        or (isPlainId(id) and type(UIInternal.hasPlugin) == 'function' and UIInternal.hasPlugin(id))
    if not known or not Validate.value('id', event) then return false end
    if data ~= nil and type(data) ~= 'table' then return false end
    sendFor(id, { action = 'page:event', id = id, event = event, data = data or {} })
    return true
end

-- --------------------------------------------------- update / patch / feed ----

--- The page `fn` may write to, or nil. Only the resource that registered a page —
--- or core itself — may change its state (§2.3). A page that is not SHOWING is a
--- silent no-op: a producer may push blindly, the wire stays quiet, and the next
--- `open` carries fresh props anyway (§38.10).
local function pageForWrite(fn, id)
    local page = pages[id]
    if not page then
        Log.error("UI.%s: page '%s' is not registered", fn, tostring(id))
        return nil
    end
    local caller = Registry.getCaller()
    if caller ~= 'core' and caller ~= page.owner then
        Log.error("UI.%s('%s'): '%s' does not own that page ('%s' does)", fn, id, caller, page.owner)
        return nil
    end
    if not UI.isOpen(id) then return nil end
    page.props = page.props or {}
    return page
end

--- What a page state value may be. These come from trusted Lua, exactly like the
--- props of `UI.open`, so they are type-checked but NOT size-bounded (§38.10).
local function patchValueOk(value)
    local kind = type(value)
    return kind == 'boolean' or kind == 'number' or kind == 'string' or kind == 'table'
end

--- Telemetry stays small, so a feed value keeps the shallow payload bound.
local function feedValueOk(value)
    local kind = type(value)
    if kind == 'boolean' or kind == 'number' then return true end
    if kind == 'string' then return #value <= MAX_EVENT_BYTES end
    return kind == 'table' and not payloadTooBig(value)
end

--- UI.update(id, { key = value, ... }) — shallow merge of top-level keys into the
--- page's props: one queued op per key, one `page:patch` on the next tick (§38.10).
function UI.update(id, partial)
    local page = pageForWrite('update', id)
    if not page then return false end
    if type(partial) ~= 'table' then
        Log.error("UI.update('%s'): partial must be a table", tostring(id))
        return false
    end
    for key, value in pairs(partial) do       -- validate everything before touching props
        if type(key) ~= 'string' or not key:find('^[%w_%-]+$') then
            Log.error("UI.update('%s'): '%s' is not a valid top-level key", id, tostring(key))
            return false
        end
        if not patchValueOk(value) then
            Log.error("UI.update('%s'): value of '%s' is not a boolean, number, string or table", id, key)
            return false
        end
    end
    for key, value in pairs(partial) do
        page.props[key] = value
        queueOp(id, { p = key, v = value })
    end
    return true
end

--- UI.patch(id, 'slots.12.count', value) — one deep op; a nil value deletes the key.
--- Segments are map keys or 1-BASED list indexes: Lua's view of the props table
--- (§38.10), so a Lua index addresses that very element on both sides.
function UI.patch(id, path, value)
    local page = pageForWrite('patch', id)
    if not page then return false end
    local segs = splitPath(path)
    if not segs then
        Log.error("UI.patch('%s'): '%s' is not a path of at most %d [%%w_%%-] segments",
            tostring(id), tostring(path), MAX_PATH_DEPTH)
        return false
    end
    if value ~= nil and not patchValueOk(value) then
        Log.error("UI.patch('%s', '%s'): value is not a boolean, number, string or table", id, path)
        return false
    end
    applyOp(id, page.props, segs, path, value, value ~= nil)
    queueOp(id, { p = path, v = value })      -- a nil value drops `v`: that IS the delete
    return true
end

--- Config.UI.FeedIntervalMs, clamped: telemetry must never approach one message
--- per frame, and never be slower than a second either.
local function feedInterval()
    local ms = tonumber(uiCfg('FeedIntervalMs', 50)) or 50
    return Utils.clamp(ms, FEED_MIN_MS, FEED_MAX_MS)
end

--- ONE `feed` message for every dirty channel, then no timer until the next write.
local function flushFeed()
    feedTimer = false
    local channels, any = {}, false
    for channel, values in pairs(feedDirty) do
        channels[channel] = values
        feedDirty[channel] = nil
        any = true
    end
    if any then send({ action = 'feed', c = channels }) end
end

--- UI.feed({ speed = 132 }) — telemetry on the CALLING resource's channel — or
--- UI.feed('inventory', { … }). Latest value per key wins; the shell copies the
--- buffer into its reactive feed objects once per frame (§38.10).
function UI.feed(channel, values)
    if values == nil and type(channel) == 'table' then
        channel, values = Registry.getCaller(), channel
    end
    if not isPlainId(channel) then
        Log.error('UI.feed: invalid channel (%s)', tostring(channel))
        return false
    end
    if type(values) ~= 'table' then
        Log.error("UI.feed('%s'): values must be a table", channel)
        return false
    end
    for key, value in pairs(values) do
        if type(key) ~= 'string' or not key:find('^[%w_%-]+$') then
            Log.error("UI.feed('%s'): '%s' is not a valid key", channel, tostring(key))
            return false
        end
        if not feedValueOk(value) then
            Log.error("UI.feed('%s'): value of '%s' is not a scalar or a bounded table", channel, key)
            return false
        end
    end
    local bucket = feedDirty[channel]
    if not bucket then
        bucket = {}
        feedDirty[channel] = bucket
    end
    for key, value in pairs(values) do bucket[key] = value end
    if not feedTimer then
        feedTimer = true
        SetTimeout(feedInterval(), flushFeed)
    end
    return true
end

--- True while a mounted component reads that feed (the shell reports it through
--- `ui_feed`), so a producer loop can sleep when nobody looks.
function UI.isFeedActive(channel)
    if channel == nil then channel = Registry.getCaller() end
    return isPlainId(channel) and feedActive[channel] == true
end

-- ------------------------------------------------------ requests (§38.8) ----

local function isRequestName(name)
    return type(name) == 'string' and #name >= 1 and #name <= MAX_REQUEST_NAME
        and name:find(REQUEST_NAME_PATTERN) ~= nil
end

--- Both directions clamp the caller's timeout into the same window.
local function clampTimeout(ms)
    local value = tonumber(ms) or uiCfg('RequestTimeoutMs', 10000)
    return Utils.clamp(value, REQUEST_MIN_MS, uiCfg('RequestMaxMs', 30000))
end

--- UI.onRequest(name, fn(data) -> result) — answers `nui.invoke(name, data)` on the
--- CALLER's channel. The handler crosses the export as a callable table (§2.2) and
--- may yield (Core.Callback.await), because the NUI cb is simply held open.
function UI.onRequest(name, fn)
    local owner = Registry.getCaller()
    if not isRequestName(name) then
        Log.error('UI.onRequest: invalid request name (%s)', tostring(name))
        return false
    end
    if not Utils.isCallable(fn) then
        Log.error("UI.onRequest('%s'): handler must be callable", name)
        return false
    end
    local byName = requestHandlers[owner]
    if not byName then
        byName = {}
        requestHandlers[owner] = byName
    end
    byName[name] = fn
    Registry.track('uirpc', owner .. '|' .. name, owner)
    return true
end

function UI.offRequest(name)
    local owner = Registry.getCaller()
    local byName = requestHandlers[owner]
    if not isRequestName(name) or not byName or byName[name] == nil then return false end
    byName[name] = nil
    if next(byName) == nil then requestHandlers[owner] = nil end
    Registry.untrack('uirpc', owner .. '|' .. name)
    return true
end

--- Answers every held `ui_request` of `owner` and forgets them. Called before the
--- handlers go away, from both cleanup paths (the registry sweep and onResourceStop),
--- so the page's fetch never hangs on a resource that stopped mid-request.
function UIInternal.failRequestsOf(owner, code)
    for key, entry in pairs(heldRequests) do
        if entry.owner == owner then
            heldRequests[key] = nil
            entry.answer({ ok = false, error = { code = code,
                message = ("resource '%s' stopped"):format(owner) } })
        end
    end
end

--- Everything a stopping resource left in this file. Idempotent: it runs from
--- client/ui.lua's own onResourceStop AND from the 'uirpc' registry remover,
--- whichever the engine dispatches first.
function UIInternal.dropOwner(owner)
    UIInternal.failRequestsOf(owner, 'resource_stopped')
    requestHandlers[owner] = nil
    feedDirty[owner], feedActive[owner] = nil, nil
end

Registry.onOwnerStop('uirpc', function(id)
    local owner, name = id:match('^(.-)|(.+)$')
    if not owner then return end
    UIInternal.failRequestsOf(owner, 'resource_stopped')
    local byName = requestHandlers[owner]
    if not byName then return end
    byName[name] = nil
    if next(byName) == nil then requestHandlers[owner] = nil end
end)

--- Resolves one Lua → NUI request; unknown/late rids are ignored.
local function resolveUiRequest(rid, ok, value)
    local entry = uiRequests[rid]
    if not entry then return false end
    uiRequests[rid] = nil
    entry.promise:resolve({ ok = ok, value = value })
    return true
end

--- UI.request(idOrChannel, name, data?, timeoutMs?) -> ok, result|errorCode.
--- Yields until the shell answers (`ui_response`), the timeout fires, the shell
--- reloads ('shell_reloaded') or it was never there ('not_ready'). Unlike the
--- built-ins this takes no focus and opens no modal.
function UI.request(target, name, data, timeoutMs)
    if not isPlainId(target) or not isRequestName(name)
        or (data ~= nil and type(data) ~= 'table') then
        Log.error('UI.request: invalid target/name/data (%s/%s)', tostring(target), tostring(name))
        return false, 'bad_request'
    end
    local known = pages[target] ~= nil
        or (type(UIInternal.hasPlugin) == 'function' and UIInternal.hasPlugin(target))
    if not known then
        Log.error("UI.request: '%s' is neither a registered page nor a UI plugin", target)
        return false, 'no_target'
    end
    if not nuiReady then return false, 'not_ready' end
    local rid = newRequestId()
    local p = promise.new()
    uiRequests[rid] = { promise = p }
    SetTimeout(clampTimeout(timeoutMs), function() resolveUiRequest(rid, false, 'timeout') end)
    sendFor(target, { action = 'page:request', id = target, rid = rid, name = name, data = data or {} })
    local answer = Citizen.Await(p)
    return answer.ok, answer.value
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
        value = JSON_NULL                   -- JSON null: the key is gone, not unchanged
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
        closeModals()                                 -- §38.9: plugin modals go with the page
        if openPage then closeOne(openPage) end
        if chatTyping then setChatTyping(false) end   -- §23: a hidden shell cannot keep the keyboard
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

-- ----------------------------------------------------------- game blur ----
-- The shell draws a live, blurred copy of the game frame behind every panel that
-- carries `data-core-blur` (DESIGN §32). Lua owns nothing but the config: one
-- `blur:set` on ui_ready and one per UI.setBlur call, no per-frame work here.

local blurOverride = {}         -- UI.setBlur values for this session; a nil key follows Config

local BLUR_TUNABLES <const> = { strength = 'Strength', fps = 'Fps', scale = 'Scale' }

--- Config.UI.Blur value with a default (the whole table may be absent).
local function blurCfg(key, default)
    local cfg = uiCfg('Blur', nil)
    if type(cfg) ~= 'table' then return default end
    local value = cfg[key]
    if value == nil then return default end
    return value
end

--- A tunable is forwarded only when it really is a number (override first, then Config);
--- otherwise the key stays out of the message and the shell keeps its own default (it
--- clamps them anyway: strength 0-40, fps 5-60, scale 0.1-1).
local function blurNumber(key)
    local value = blurOverride[key]
    if type(value) ~= 'number' then value = blurCfg(BLUR_TUNABLES[key], nil) end
    return type(value) == 'number' and value or nil
end

--- Tells the shell whether to draw the glass, and how (flip, and ui_ready).
local function sendBlur()
    local enabled = blurOverride.enabled
    if enabled == nil then enabled = blurCfg('Enabled', true) == true end
    send({
        action = 'blur:set', enabled = enabled,
        strength = blurNumber('strength'), fps = blurNumber('fps'), scale = blurNumber('scale'),
    })
end

--- UI.setBlur(enabled, opts?) — session-scoped override of Config.UI.Blur; only `true`
--- enables. `opts` may carry numeric `strength` (px), `fps` and `scale`; a key that is not
--- a number is ignored, so `setBlur(true)` keeps the earlier tuning. Re-sent on ui_ready,
--- so a shell reload keeps the override.
function UI.setBlur(enabled, opts)
    blurOverride.enabled = enabled == true
    if type(opts) == 'table' then
        for key in pairs(BLUR_TUNABLES) do
            if type(opts[key]) == 'number' then blurOverride[key] = opts[key] end
        end
    end
    sendBlur()
    return true
end

--- /uiblur              -> shows the current values
--- /uiblur off | on     -> toggles the glass
--- /uiblur 4 [0.5] [30] -> strength px [, scale [, fps]] — tuning without a restart; the
--- value you like goes into Config.UI.Blur afterwards.
RegisterCommand('uiblur', function(_, args)
    local first = args and args[1]
    if first == 'diag' or first == 'test' then
        -- diag: the current state; test: the hook recipe experiment (gameblur.probe.js).
        -- Both are answered by the blur_diag callback below and printed to the console.
        send({ action = first == 'diag' and 'blur:diag' or 'blur:test' })
        return
    end
    if first == 'off' or first == 'on' then
        UI.setBlur(first == 'on')
    elseif first ~= nil then
        UI.setBlur(true, { strength = tonumber(first), scale = tonumber(args[2]), fps = tonumber(args[3]) })
    end
    local enabled = blurOverride.enabled
    if enabled == nil then enabled = blurCfg('Enabled', true) == true end
    UI.notify(('Game blur %s: strength %s px, scale %s, fps %s'):format(
        enabled and 'on' or 'off', tostring(blurNumber('strength') or '?'),
        tostring(blurNumber('scale') or '?'), tostring(blurNumber('fps') or '?')), 'info')
end, false)

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
    for rid in pairs(uiRequests) do resolveUiRequest(rid, false, 'shell_reloaded') end
    for key, entry in pairs(heldRequests) do   -- their fetches died with the old document
        heldRequests[key] = nil
        entry.answer({ ok = false, error = { code = 'shell_reloaded', message = 'the NUI shell reloaded' } })
    end
    feedActive = {}                     -- nothing is mounted yet, so nothing subscribes
    applyFocus()
    -- Plugins FIRST: the shell must know which module owns a page before the page
    -- is declared, so a `page:register` is never orphaned (§38.4).
    if type(UIInternal.replayPlugins) == 'function' then UIInternal.replayPlugins() end
    for id, page in pairs(pages) do
        send({
            action = 'page:register', id = id, type = page.type,
            keepInput = page.keepInput, owner = page.owner,
        })
    end
    local snapshot = { action = 'hud:set' }
    for key, value in pairs(hud) do snapshot[key] = value end
    send(snapshot)
    sendBlur()                          -- the reloaded shell forgot the blur config too (§32.3)
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
    for i = 1, #modals do                       -- plugin modals in stack order, bottom first
        local page = pages[modals[i]]
        if page then send({ action = 'page:open', id = modals[i], props = page.props or {} }) end
    end
    local stack = focusStack()
    focusSignature = stackSignature(stack)
    send({ action = 'focus', focused = focusOwned, stack = stack })
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

--- NUI → Lua request (§38.8): `c` channel, `n` name, `d` payload, `t` timeout ms.
--- The cb is HELD — FiveM simply keeps the POST open — until the handler returns,
--- the timeout fires or the owning resource stops, so a handler may await the
--- server. Every path answers exactly once: `answer` is the only writer.
RegisterNuiCallback('ui_request', function(data, cb)
    if type(data) ~= 'table' or not isPlainId(data.c) or not isRequestName(data.n)
        or (data.d ~= nil and type(data.d) ~= 'table')
        or (data.t ~= nil and type(data.t) ~= 'number') then
        cb({ ok = false, error = { code = 'bad_request', message = 'malformed ui_request' } })
        return
    end
    if data.d and payloadTooBig(data.d) then
        cb({ ok = false, error = { code = 'bad_request', message = 'payload too large' } })
        return
    end
    local byName = requestHandlers[data.c]
    local handler = byName and byName[data.n]
    if not handler then
        cb({ ok = false, error = { code = 'no_handler',
            message = ("no handler '%s' on channel '%s'"):format(data.n, data.c) } })
        return
    end
    local key = newRequestId()
    local answered = false
    local function answer(payload)
        if answered then return end
        answered = true
        heldRequests[key] = nil
        -- cb JSON-encodes: a result the page could never receive answers as an error
        -- instead of throwing inside the callback and hanging the fetch forever
        if not pcall(cb, payload) then
            pcall(cb, { ok = false, error = { code = 'bad_result',
                message = 'the handler returned a value that cannot be sent to the page' } })
        end
    end
    heldRequests[key] = { owner = data.c, answer = answer }
    SetTimeout(clampTimeout(data.t), function()
        answer({ ok = false, error = { code = 'timeout', message = 'the Lua handler did not answer in time' } })
    end)
    local ok, result = pcall(handler, data.d or {})
    if ok then
        answer({ ok = true, data = result })
    else
        answer({ ok = false, error = { code = 'handler_error', message = tostring(result) } })
    end
end)

--- The shell's answer to UI.request. An unknown rid (already timed out, or forged)
--- is ignored; the awaiting coroutine is resumed exactly once either way.
RegisterNuiCallback('ui_response', function(data, cb)
    cb({ ok = true })
    if type(data) ~= 'table' then return end
    local rid = math.tointeger(tonumber(data.rid) or 0)
    if not rid or not uiRequests[rid] then return end
    if data.ok == true then
        local value = data.data
        if type(value) == 'table' and payloadTooBig(value) then
            resolveUiRequest(rid, false, 'bad_result')
        else
            resolveUiRequest(rid, true, value)
        end
        return
    end
    local code = type(data.error) == 'table' and type(data.error.code) == 'string'
        and data.error.code or 'error'
    resolveUiRequest(rid, false, code)
end)

RegisterNuiCallback('ui_sound', function(data, cb)
    if type(data) == 'table' and type(data.name) == 'string' and #data.name <= 64
        and type(data.set) == 'string' and #data.set <= 64 then
        PlaySoundFrontend(-1, data.name, data.set, true)
    end
    cb({})
end)

--- Game-blur diagnostics (DESIGN §32): the shell reports after every probe and on
--- `/uiblur diag`; printed to the client console so it lands in CitizenFX.log.
RegisterNuiCallback('blur_diag', function(data, cb)
    cb({})
    if type(data) ~= 'table' then return end
    if data.reason == 'variants' then
        print(('[core] game blur experiment (%s), viewport %s:'):format(tostring(data.trigger),
            type(data.viewport) == 'table' and json.encode(data.viewport) or '?'))
        if type(data.results) == 'table' then
            for i = 1, #data.results do
                local r = data.results[i]
                print(('[core]   %-28s now=%s later=%s glError=%s %s'):format(tostring(r.name),
                    type(r.now) == 'table' and json.encode(r.now) or '-',
                    type(r.later) == 'table' and json.encode(r.later) or '-',
                    tostring(r.glError), r.error and ('error=' .. tostring(r.error)) or ''))
            end
        end
        return
    end
    local samples = type(data.samples) == 'table' and json.encode(data.samples) or '?'
    local copy = type(data.copy) == 'table' and json.encode(data.copy) or tostring(data.copy)
    print(('[core] game blur (%s): mode=%s source=%s webgl=%s attached=%s size=%sx%s viewport=%s consumers=%s copy=%s enabled=%s shell=%s strength=%s scale=%s fps=%s samples=%s'):format(
        tostring(data.reason), tostring(data.mode), tostring(data.source), tostring(data.webgl),
        tostring(data.attached), tostring(data.width), tostring(data.height),
        type(data.viewport) == 'table' and json.encode(data.viewport) or '?', tostring(data.consumers),
        copy, tostring(data.enabled), tostring(data.shell), tostring(data.strength), tostring(data.scale),
        tostring(data.fps), samples))
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

-- The rest of the seam client/ui_plugins.lua uses (§38.4). `replayPlugins` and
-- `hasPlugin` are installed there; everything here is what that file needs FROM
-- this one, so neither has to reach into the other's state.
UIInternal.send = send
UIInternal.isNuiReady = function() return nuiReady end

--- The shell reports the first subscriber and the last unsubscribe of a feed
--- (`ui_feed`), so UI.isFeedActive can tell a producer loop to sleep.
function UIInternal.setFeedActive(channel, active)
    if not isPlainId(channel) then return false end
    feedActive[channel] = active and true or nil
    return true
end

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
        if focusOwned and not openPage and not modal and #modals == 0 and not chatTyping then
            applyFocus()
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then
        -- a plugin that stops: answer its held page requests before anything else
        -- drops the handlers, then forget its feed channel (§38.4)
        if type(resource) == 'string' then UIInternal.dropOwner(resource) end
        return
    end
    -- synchronous: focus first, then unblock every coroutine still awaiting the shell
    SetNuiFocusKeepInput(false)
    SetNuiFocus(false, false)
    focusOwned, focusKeepInput = false, false
    openPage, textUI, chatTyping = nil, nil, false
    for i = #modals, 1, -1 do modals[i] = nil end
    for rid in pairs(uiRequests) do resolveUiRequest(rid, false, 'shell_reloaded') end
    for key, entry in pairs(heldRequests) do
        heldRequests[key] = nil
        entry.answer({ ok = false, error = { code = 'resource_stopped', message = 'core stopped' } })
    end
    resolveAllPending()
end)

-- end of file
