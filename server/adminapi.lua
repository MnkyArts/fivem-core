--[[
    core/server/adminapi.lua — Core.Admin (DESIGN §51): admin contributions, the rights snapshot, duty and
    staff modes. Any plugin contributes categories, actions, pages and player tabs as data plus a server
    handler; core owns the registry and the ONE dispatch path (server/adminapi_dispatch.lua: Admin.run,
    the chat commands generated from `command`), so every action gets the same checks and audit.

      Admin.category{ id, label, icon?, order?, permission? } -> bool, err
      Admin.action{ id, category, label, target, handler, ... }  -> bool, err   (full list: DESIGN §51)
      Admin.page{ id, category?, label, icon?, order?, permission?, duty?, page?, provider? } -> bool, err
      Admin.playerTab{ id, label, icon?, order?, permission?, duty?, page?, provider? } -> bool, err
      Admin.snapshot(src) -> { rank, duty, categories, actions, pages, playerTabs }
      Admin.setDuty(src, on) / isOnDuty(src) · setMode(src, mode, on, data?) / getModes(src)
      Admin.staff(onDutyOnly?) -> { src } · Admin.echo(text, { perm?, exclude? }) -> sent

    Registrations are owner-tracked (Registry kinds adminCategory / adminAction / adminPage /
    adminPlayerTab): the first registrant owns an id, the same owner replaces it, a stopped owner's
    entries go. Staff = loaded players holding Config.Admin.StaffPerm, kept as a set (playerLoaded,
    permsChanged(src), playerDropped; permsChanged(nil) coalesces into one walk per debounce window), so
    nothing here walks every player per action. Duty and modes are session state — never a replicated
    state bag: `core:admin:self` tells the player, `core:admin:staffState(s)` tells the on-duty staff (mode
    names only; mode data stays on the server) — audited on change, cleared on drop; modes also end with
    the duty and with a demotion. client/adminstate.lua is the receiving side.
    `core:admin:snapshotChanged` goes to the affected staff through Net.emitMany, debounced
    SNAPSHOT_DEBOUNCE_MS. Player tabs check Perms.canTarget(viewer, target) unless `hierarchy = false`.

    The private state is handed to adminapi_dispatch.lua through a one-shot metatable slot on Core.Admin,
    which that file clears at once (the export resolves with rawget, so it is never reachable from a plugin).

    Natives: GetGameTimer (server), GetPlayerName (server). SetTimeout, AddEventHandler
    are runtime helpers.
]]

local Admin = {}
Core.Admin = Admin

local Log = Core.Log
local Utils = Core.Utils
local Schema = Core.Schema
local Registry = Core.Registry

local ID_PATTERN <const> = '^[%w_%-%.]+$'
local PERM_PATTERN <const> = '^[%w_%-%.:]+$'
local PAGE_PATTERN <const> = '^[%w_%-]+$'   -- a plain UI page id: the UI bridge drops events of any other id
local COMMAND_PATTERN <const> = '^[%w_%-]+$'
local MODE_PATTERN <const> = '^%a[%w_]*$'
local MAX_ID <const>, MAX_PERM <const>, MAX_LABEL <const>, MAX_TEXT <const> = 64, 64, 64, 256
local MAX_ICON <const>, MAX_KEY <const>, MAX_COMMAND <const>, MAX_MODE <const> = 64, 32, 32, 32
local MAX_MODES <const> = 16            -- modes per player
local MAX_PLAYERS_TARGET <const> = 2000 -- hard cap of an action's `max`
local MAX_COOLDOWN <const> = 3600       -- seconds
local MAX_ECHO <const> = 256
local MAX_BLOCKS <const>, MAX_ROWS <const>, MAX_COLUMNS <const>, MAX_CELL <const> = 32, 200, 32, 512
local MAX_BLOCK_TEXT <const> = 4096
local SNAPSHOT_DEBOUNCE_MS <const> = 1000
local CONSOLE_WEIGHT <const> = 2147483647

local TARGETS <const> = { none = true, player = true, players = true, entity = true, coords = true }
local REASONS <const> = { none = true, optional = true, required = true }
local DANGERS <const> = { none = true, confirm = true, typed = true }
local KINDS <const> = { category = 'adminCategory', action = 'adminAction', page = 'adminPage',
    playerTab = 'adminPlayerTab' }

local categories, actions, pages, playerTabs = {}, {}, {}, {}   -- [id] = entry (entry.owner)
local staffSet = {}      -- [src] = true: loaded and holding Config.Admin.StaffPerm
local duty = {}          -- [src] = true while on duty
local modes = {}         -- [src] = { [mode] = data|true }
local pendingSnapshot = {}   -- [src] = true, flushed by one debounce timer
local snapshotArmed = false
local fullRefreshArmed = false   -- one coalesced walk over every player per debounce window

local P = { actions = actions, staffSet = staffSet }

local function config()
    return Config.Admin or {}
end

local function staffPerm()
    local perm = config().StaffPerm
    return type(perm) == 'string' and perm ~= '' and perm or 'core.admin.staff'
end

local function requireDuty()
    return config().RequireDuty ~= false
end

--- A trimmed string of 1..max characters (control characters removed), or nil.
local function text(value, max)
    if type(value) ~= 'string' then return nil end
    local out = value:gsub('%c', ''):match('^%s*(.-)%s*$')
    if out == '' then return nil end
    if #out > max then out = out:sub(1, max) end
    return out
end

local function isId(v)
    return type(v) == 'string' and #v >= 1 and #v <= MAX_ID and v:match(ID_PATTERN) ~= nil
end

local function isPerm(v)
    return type(v) == 'string' and #v >= 1 and #v <= MAX_PERM and v:match(PERM_PATTERN) ~= nil
end

local function isSrc(v)
    return math.type(v) == 'integer' and v >= 1 and v <= 65535
end

--- A server id from a payload (a JSON number may arrive as a float): integer 1..65535 or nil.
local function toSrc(v)
    local n = type(v) == 'number' and math.tointeger(v) or nil
    return (n and n >= 1 and n <= 65535) and n or nil
end

local function isLoaded(src)
    return isSrc(src) and Core.Player.isLoaded(src) == true
end

local function nameOf(src)
    if src == 0 then return 'console' end
    return Core.Player.getName(src) or GetPlayerName(src) or ('#' .. tostring(src))
end

--- Rank scope (DESIGN §51): Config.Admin.Scope[group] or 1; the console is not capped.
local function scopeOf(src)
    if src == 0 then return MAX_PLAYERS_TARGET end
    local scope = config().Scope
    local value = type(scope) == 'table' and scope[Core.Perms.getGroup(src)] or nil
    if math.type(value) ~= 'integer' or value < 1 then return 1 end
    return math.min(value, MAX_PLAYERS_TARGET)
end

local function onDuty(src)
    return src == 0 or duty[src] == true
end

--- Does `src` pass an entry's permission and duty gates?
local function allowed(src, entry)
    if entry.permission and not Core.Perms.has(src, entry.permission) then return false end
    if entry.duty and not onDuty(src) then return false end
    return true
end

--- One audit row, written as the entry's owner (the row's `resource`); never throws.
local function audit(owner, row)
    local auditApi = rawget(Core, 'Audit')
    if type(auditApi) ~= 'table' or type(auditApi.record) ~= 'function' then
        Log.audit('admin', type(row.actor) == 'number' and row.actor or nil, '%s %s %s', row.action,
            tostring(row.result or 'ok'), tostring(row.message or ''))
        return nil
    end
    local ok, id = Registry.withCaller(owner or 'core', auditApi.record, row)
    if not ok then Log.warn('admin: audit failed (%s)', tostring(id)) end
    return ok and id or nil
end

P.config, P.staffPerm, P.text, P.isId, P.isSrc, P.toSrc = config, staffPerm, text, isId, isSrc, toSrc
P.isLoaded = isLoaded
P.nameOf, P.scopeOf, P.onDuty, P.allowed, P.audit = nameOf, scopeOf, onDuty, allowed, audit

-- == Staff set and the debounced snapshotChanged ===========================================================

--- Queue `core:admin:snapshotChanged` for one src, or (nil) for every online staff member.
local function queueSnapshot(src)
    if src == nil then
        for s in pairs(staffSet) do pendingSnapshot[s] = true end
    elseif isSrc(src) then
        pendingSnapshot[src] = true
    end
    if snapshotArmed or next(pendingSnapshot) == nil then return end
    snapshotArmed = true
    SetTimeout(SNAPSHOT_DEBOUNCE_MS, function()
        snapshotArmed = false
        local targets = {}
        for s in pairs(pendingSnapshot) do
            if Core.Player.isLoaded(s) then targets[#targets + 1] = s end
        end
        pendingSnapshot = {}
        table.sort(targets)
        if #targets > 0 then Core.Net.emitMany(targets, 'core:admin:snapshotChanged') end
    end)
end
P.queueSnapshot = queueSnapshot

--- Turns every staff mode of `src` off (each change audited and sent, see setMode).
local function clearModes(src)
    local set = modes[src]
    if not set then return end
    local names = {}
    for mode in pairs(set) do names[#names + 1] = mode end
    table.sort(names)
    for i = 1, #names do Admin.setMode(src, names[i], false) end
end

--- Re-reads one player's staff membership; a demoted player loses duty and modes (audited).
local function refreshStaff(src)
    local was = staffSet[src] == true
    local is = isLoaded(src) and Core.Perms.has(src, staffPerm()) == true
    staffSet[src] = is or nil
    if was and not is then
        if duty[src] then Admin.setDuty(src, false) else clearModes(src) end
    end
    return was ~= is
end

--- permsChanged(nil) (a whole group changed, a define's default, the load): ONE walk over the loaded
--- players per debounce window, however many arrive (a plugin start defines many permissions).
local function refreshAllStaff()
    if fullRefreshArmed then return end
    fullRefreshArmed = true
    SetTimeout(SNAPSHOT_DEBOUNCE_MS, function()
        fullRefreshArmed = false
        local players = Core.Player.getPlayers()
        for i = 1, #players do
            if refreshStaff(players[i]) then queueSnapshot(players[i]) end
        end
        queueSnapshot(nil)
    end)
end

-- == Registration helpers ==================================================================================

local function fail(kind, id, err)
    Log.warn('Admin.%s: %s refused (%s)', kind, tostring(id), err)
    return false, err
end

--- Common fields of every entry; nil + err on a bad definition.
local function baseEntry(kind, def)
    if type(def) ~= 'table' then return nil, 'definition' end
    if not isId(def.id) then return nil, 'id' end
    local label = text(def.label, MAX_LABEL)
    if not label then return nil, 'label' end
    if def.icon ~= nil and not text(def.icon, MAX_ICON) then return nil, 'icon' end
    local order = def.order == nil and 100 or def.order
    if type(order) ~= 'number' or order ~= order or math.abs(order) > 1e6 then return nil, 'order' end
    if def.permission ~= nil and not isPerm(def.permission) then return nil, 'permission' end
    if def.description ~= nil and type(def.description) ~= 'string' then return nil, 'description' end
    return { kind = kind, id = def.id, label = label, icon = text(def.icon, MAX_ICON), order = order,
        permission = def.permission, description = text(def.description, MAX_TEXT) }
end

--- Owner rule: the first registrant owns an id, the same owner replaces it. Returns the owner or nil.
local function claim(list, id)
    local owner = Registry.getCaller()
    local existing = list[id]
    if existing and existing.owner ~= owner then return nil, 'owned' end
    return owner
end

local function store(storeTable, kind, entry)
    storeTable[entry.id] = entry
    Registry.track(KINDS[kind], entry.id, entry.owner)
    queueSnapshot(nil)
    return true
end

--- `page` (a plain UI page id, ^[%w_%-]+$ ≤ 64) and/or `provider` (a callable) for pages and player tabs.
local function viewEntry(kind, def)
    local entry, err = baseEntry(kind, def)
    if not entry then return nil, err end
    if def.page ~= nil and (type(def.page) ~= 'string' or #def.page > MAX_ID or not def.page:match(PAGE_PATTERN)) then
        return nil, 'page'
    end
    if def.provider ~= nil and not Utils.isCallable(def.provider) then return nil, 'provider' end
    if def.page == nil and def.provider == nil then return nil, 'page_or_provider' end
    if def.duty ~= nil and type(def.duty) ~= 'boolean' then return nil, 'duty' end
    entry.page, entry.provider = def.page, def.provider
    if def.duty == nil then entry.duty = requireDuty() else entry.duty = def.duty end
    return entry
end

-- == Registrations =========================================================================================

--- Admin.category{ id, label, icon?, order? = 100, permission? }
function Admin.category(def)
    local entry, err = baseEntry('category', def)
    if not entry then return fail('category', type(def) == 'table' and def.id, err) end
    local owner, claimErr = claim(categories, entry.id)
    if not owner then return fail('category', entry.id, claimErr) end
    entry.owner = owner
    return store(categories, 'category', entry)
end

--- Admin.page{ id, category?, label, icon?, order?, permission?, duty?, page?, provider? }
function Admin.page(def)
    local entry, err = viewEntry('page', def)
    if not entry then return fail('page', type(def) == 'table' and def.id, err) end
    if def.category ~= nil and not isId(def.category) then return fail('page', entry.id, 'category') end
    entry.category = def.category
    local owner, claimErr = claim(pages, entry.id)
    if not owner then return fail('page', entry.id, claimErr) end
    entry.owner = owner
    return store(pages, 'page', entry)
end

--- Admin.playerTab{ id, label, icon?, order?, permission?, duty?, hierarchy? = true, page?, provider? }
--- `hierarchy`: the viewer must pass Perms.canTarget on the tab's target (turn off for harmless tabs).
function Admin.playerTab(def)
    local entry, err = viewEntry('playerTab', def)
    if not entry then return fail('playerTab', type(def) == 'table' and def.id, err) end
    if def.hierarchy ~= nil and type(def.hierarchy) ~= 'boolean' then return fail('playerTab', entry.id, 'hierarchy') end
    entry.hierarchy = def.hierarchy ~= false
    local owner, claimErr = claim(playerTabs, entry.id)
    if not owner then return fail('playerTab', entry.id, claimErr) end
    entry.owner = owner
    return store(playerTabs, 'playerTab', entry)
end

local function optBool(value, default)
    if value == nil then return true, default end
    if type(value) ~= 'boolean' then return false end
    return true, value
end

--- Validates an action definition into the stored entry (handler kept, args normalised).
local function actionEntry(def)
    local entry, err = baseEntry('action', def)
    if not entry then return nil, err end
    if not isId(def.category) then return nil, 'category' end
    if not Utils.isCallable(def.handler) then return nil, 'handler' end
    local target = def.target == nil and 'none' or def.target
    if not TARGETS[target] then return nil, 'target' end
    local reason = def.reason == nil and 'none' or def.reason
    if not REASONS[reason] then return nil, 'reason' end
    local danger = def.danger == nil and 'none' or def.danger
    if not DANGERS[danger] then return nil, 'danger' end
    local permission = def.permission or ('admin.' .. def.id)
    if not isPerm(permission) then return nil, 'permission' end
    local default = def.default == nil and 'admin' or def.default
    if default ~= false and (type(default) ~= 'string' or not default:match('^[%w_%-]+$')) then return nil, 'default' end
    local okSelf, self = optBool(def.self, true)
    local okHier, hierarchy = optBool(def.hierarchy, true)
    local okDuty, dutyFlag = optBool(def.duty, requireDuty())
    local okEcho, echo = optBool(def.echo, true)
    local okHidden, hidden = optBool(def.hidden, false)
    if not okSelf then return nil, 'self' end
    if not okHier then return nil, 'hierarchy' end
    if not okDuty then return nil, 'duty' end
    if not okEcho then return nil, 'echo' end
    if not okHidden then return nil, 'hidden' end
    local max = 1
    if target == 'players' then
        max = def.max == nil and 50 or def.max
        if math.type(max) ~= 'integer' or max < 1 or max > MAX_PLAYERS_TARGET then return nil, 'max' end
    elseif def.max ~= nil and def.max ~= 1 then
        return nil, 'max'
    end
    local cooldown = def.cooldown == nil and 1 or def.cooldown
    if type(cooldown) ~= 'number' or cooldown ~= cooldown or cooldown < 0 or cooldown > MAX_COOLDOWN then
        return nil, 'cooldown'
    end
    local command = def.command
    if command == nil or command == false then
        command = nil
    elseif type(command) ~= 'string' or #command > MAX_COMMAND or not command:match(COMMAND_PATTERN) then
        return nil, 'command'
    else
        command = command:lower()
    end
    if def.key ~= nil and (type(def.key) ~= 'string' or #def.key > MAX_KEY) then return nil, 'key' end
    local args, publicArgs = nil, {}
    if def.args ~= nil then
        if type(def.args) ~= 'table' then return nil, 'args' end
        if #def.args > 0 then
            local fields, fieldErr = Schema.fields(def.args)
            if not fields then return nil, 'args:' .. tostring(fieldErr) end
            args, publicArgs = fields, Schema.public(fields) or {}
        end
    end
    entry.category, entry.handler, entry.target, entry.reason, entry.danger = def.category, def.handler, target,
        reason, danger
    entry.permission, entry.default, entry.self, entry.hierarchy = permission, default or nil, self, hierarchy
    entry.duty, entry.echo, entry.hidden, entry.max, entry.cooldown = dutyFlag, echo, hidden, max, cooldown
    entry.command, entry.key, entry.args, entry.publicArgs = command, def.key ~= '' and def.key or nil, args,
        publicArgs
    return entry
end

--- Admin.action{ … } (DESIGN §51). The permission is Perms.define'd with its `default` group.
function Admin.action(def)
    local entry, err = actionEntry(def)
    if not entry then return fail('action', type(def) == 'table' and def.id, err) end
    local owner, claimErr = claim(actions, entry.id)
    if not owner then return fail('action', entry.id, claimErr) end
    entry.owner = owner
    local previous = actions[entry.id]
    Core.Perms.define(entry.permission, { label = entry.label, description = entry.description,
        category = entry.category, default = entry.default })
    store(actions, 'action', entry)
    if P.syncCommand then P.syncCommand(entry, previous) end
    return true
end

-- A stopped owner's entries go; the snapshot of every online staff member is refreshed.
local function sweeper(storeTable)
    return function(id)
        local entry = storeTable[id]
        storeTable[id] = nil
        if entry and entry.kind == 'action' and P.syncCommand then P.syncCommand(nil, entry) end
        queueSnapshot(nil)
    end
end
Registry.onOwnerStop(KINDS.category, sweeper(categories))
Registry.onOwnerStop(KINDS.action, sweeper(actions))
Registry.onOwnerStop(KINDS.page, sweeper(pages))
Registry.onOwnerStop(KINDS.playerTab, sweeper(playerTabs))

-- == Snapshot (advisory; Admin.run re-checks everything) ===================================================

local function byOrder(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.id < b.id
end

--- May `src` use this action (permission + duty)?
local function usable(src, action)
    return action ~= nil and allowed(src, action)
end
P.usable = usable

local function publicAction(action, scope)
    return {
        id = action.id, category = action.category, label = action.label, description = action.description,
        icon = action.icon, order = action.order, permission = action.permission, target = action.target,
        self = action.self, hierarchy = action.hierarchy,
        max = action.target == 'players' and math.min(action.max, scope) or 1,
        args = Utils.deepCopy(action.publicArgs), reason = action.reason, danger = action.danger,
        cooldown = action.cooldown, duty = action.duty, echo = action.echo, command = action.command,
        key = action.key, hidden = action.hidden, owner = action.owner,
    }
end

local function publicView(entry)
    return { id = entry.id, category = entry.category, label = entry.label, icon = entry.icon, order = entry.order,
        permission = entry.permission, duty = entry.duty, page = entry.page, provider = entry.provider ~= nil,
        hierarchy = entry.hierarchy, owner = entry.owner }
end

--- Admin.snapshot(src) -> { rank = { group, weight, scope }, duty, categories, actions, pages, playerTabs }
--- Only what `src` may use (permission + duty), public fields only; `max` already capped for `src`.
function Admin.snapshot(src)
    if src ~= 0 and not isSrc(src) then return nil end
    local scope = scopeOf(src)
    local out = {
        rank = { group = src == 0 and 'console' or Core.Perms.getGroup(src),
            weight = src == 0 and CONSOLE_WEIGHT or Core.Perms.getWeight(src), scope = scope },
        duty = onDuty(src), categories = {}, actions = {}, pages = {}, playerTabs = {},
    }
    local used = {}
    for _, action in pairs(actions) do
        if usable(src, action) then
            out.actions[#out.actions + 1] = publicAction(action, scope)
            used[action.category] = true
        end
    end
    for _, page in pairs(pages) do
        if allowed(src, page) then
            out.pages[#out.pages + 1] = publicView(page)
            if page.category then used[page.category] = true end
        end
    end
    for _, tab in pairs(playerTabs) do
        if allowed(src, tab) then out.playerTabs[#out.playerTabs + 1] = publicView(tab) end
    end
    for id, category in pairs(categories) do
        if used[id] and allowed(src, category) then
            out.categories[#out.categories + 1] = { id = id, label = category.label, icon = category.icon,
                order = category.order, owner = category.owner }
        end
    end
    table.sort(out.categories, byOrder)
    table.sort(out.actions, byOrder)
    table.sort(out.pages, byOrder)
    table.sort(out.playerTabs, byOrder)
    return out
end

-- == Provider blocks (schema pages rendered by the admin frontend) ========================================

--- A JSON-safe scalar for a cell: strings bounded, finite numbers and booleans as they are.
local function cell(value)
    local kind = type(value)
    if kind == 'string' then return #value > MAX_CELL and value:sub(1, MAX_CELL) or value end
    if kind == 'number' then return (value == value and value ~= math.huge and value ~= -math.huge) and value or nil end
    if kind == 'boolean' then return value end
    if value == nil then return nil end
    local str = tostring(value)
    return #str > MAX_CELL and str:sub(1, MAX_CELL) or str
end

local function pairsRows(list, max, map)
    local out = {}
    if type(list) ~= 'table' then return out end
    for i = 1, math.min(#list, max) do
        if type(list[i]) == 'table' then
            local row = map(list[i])
            if row then out[#out + 1] = row end
        end
    end
    return out
end

local BLOCKS = {}
BLOCKS.keyvalue = function(b)
    return { kind = 'keyvalue', title = cell(b.title), rows = pairsRows(b.rows, MAX_ROWS, function(r)
        return { label = cell(r.label or r[1]), value = cell(r.value or r[2]) }
    end) }
end
BLOCKS.table = function(b)
    local columns = pairsRows(b.columns, MAX_COLUMNS, function(c)
        if type(c.key) ~= 'string' then return nil end
        return { key = c.key, label = cell(c.label) or c.key }
    end)
    return { kind = 'table', title = cell(b.title), columns = columns, rows = pairsRows(b.rows, MAX_ROWS, function(r)
        local row = {}
        for i = 1, #columns do row[columns[i].key] = cell(r[columns[i].key]) end
        return row
    end) }
end
BLOCKS.text = function(b)
    if type(b.text) ~= 'string' then return nil end
    return { kind = 'text', text = #b.text > MAX_BLOCK_TEXT and b.text:sub(1, MAX_BLOCK_TEXT) or b.text }
end
BLOCKS.stats = function(b)
    return { kind = 'stats', items = pairsRows(b.items, MAX_COLUMNS, function(it)
        return { label = cell(it.label), value = cell(it.value), icon = cell(it.icon) }
    end) }
end
BLOCKS.actions = function(b, viewer)
    local ids = {}
    if type(b.ids) == 'table' then
        for i = 1, math.min(#b.ids, MAX_COLUMNS) do
            if usable(viewer, actions[b.ids[i]]) then ids[#ids + 1] = b.ids[i] end
        end
    end
    return { kind = 'actions', title = cell(b.title), ids = ids }
end
BLOCKS.form = function(b, viewer)
    if not usable(viewer, actions[b.submit]) then return nil end
    local fields = type(b.fields) == 'table' and Schema.public(b.fields) or nil
    if not fields then return nil end
    return { kind = 'form', title = cell(b.title), fields = fields, submit = b.submit }
end

--- A provider's answer, bounded and filtered for `viewer` (unknown kinds and malformed blocks dropped).
local function cleanBlocks(list, viewer)
    local out = {}
    if type(list) ~= 'table' then return out end
    for i = 1, math.min(#list, MAX_BLOCKS) do
        local b = list[i]
        local build = type(b) == 'table' and BLOCKS[b.kind] or nil
        if build then
            local ok, block = pcall(build, b, viewer)
            if ok and block then out[#out + 1] = block end
        end
    end
    return out
end

--- Runs a page / player-tab provider for `viewer` -> { ok, blocks } | { ok, page } | { ok = false, error }.
local function view(entry, viewer, ctx)
    if not entry then return { ok = false, error = 'unknown' } end
    if not allowed(viewer, entry) then return { ok = false, error = 'no_permission' } end
    if ctx.target and entry.hierarchy and not Core.Perms.canTarget(viewer, ctx.target) then
        return { ok = false, error = 'rank' }
    end
    if not entry.provider then return { ok = true, page = entry.page } end
    local ok, blocks = pcall(entry.provider, ctx)
    if not ok then
        Log.error('admin: provider %s (%s) failed: %s', entry.id, entry.owner, tostring(blocks))
        return { ok = false, error = 'error' }
    end
    return { ok = true, page = entry.page, blocks = cleanBlocks(blocks, viewer) }
end

-- == Duty and staff modes ==================================================================================

-- Staff state is never in a replicated state bag (every client could read who is on duty, vanished or
-- spectating). It goes to the player itself (`core:admin:self`) and, while they are on duty, to the on-duty
-- staff (`core:admin:staffState`); a player going on duty gets the whole list once (`core:admin:staffStates`).

--- What `src` is told about itself: { duty, modes = { [name] = true } } (mode data stays on the server).
local function selfState(src)
    local names, set = {}, modes[src]
    if set then for mode in pairs(set) do names[mode] = true end end
    return { duty = duty[src] == true, modes = names }
end

--- What the on-duty staff see of `src`: { src, duty, modes } — modes only while `src` is on duty.
local function staffState(src)
    local on = duty[src] == true
    return { src = src, duty = on, modes = on and selfState(src).modes or nil }
end

local function sendSelf(src)
    Core.Net.emitMany({ src }, 'core:admin:self', selfState(src))
end

--- `src`'s state to every on-duty staff member (Config.Admin.StaffPerm holders), minus `exclude`.
local function sendStaffState(src, exclude)
    local targets, list = {}, Admin.staff(true)
    for i = 1, #list do
        if list[i] ~= exclude then targets[#targets + 1] = list[i] end
    end
    if #targets > 0 then Core.Net.emitMany(targets, 'core:admin:staffState', staffState(src)) end
end

--- Admin.setDuty(src, on) -> bool. Going on duty needs Config.Admin.StaffPerm; audited on change.
--- Going off duty turns every staff mode off first (so Security.isStaffExempt stops exempting).
function Admin.setDuty(src, on)
    if not isLoaded(src) or type(on) ~= 'boolean' then return false end
    if on and not Core.Perms.has(src, staffPerm()) then return false end
    if not on then clearModes(src) end
    if (duty[src] == true) == on then return true end
    duty[src] = on or nil
    audit('core', { actor = src, action = 'core.admin.duty', source = 'core',
        targets = { { type = 'player', id = src } }, changes = { { key = 'duty', old = not on, new = on } } })
    sendSelf(src)
    if on then
        local list, staff = {}, Admin.staff(true)
        for i = 1, #staff do list[i] = staffState(staff[i]) end
        Core.Net.emitMany({ src }, 'core:admin:staffStates', list)
        sendStaffState(src, src)
    else
        sendStaffState(src)
    end
    queueSnapshot(src)
    return true
end

--- Console: true (exempt); a player: its session flag.
function Admin.isOnDuty(src)
    if src == 0 then return true end
    return isSrc(src) and duty[src] == true
end

--- Admin.setMode(src, mode, on, data?) -> bool. Any mode name (^%a[%w_]*$, ≤ 32, ≤ 16 per player); the
--- known ones are noclip, vanish, spectate, god, editor (server/security.lua exempts them). `data` stays
--- on the server (getModes); on/off changes are audited and sent to the player (core:admin:self) and, while
--- it is on duty, to the on-duty staff (core:admin:staffState) — names only. Server hook
--- `staffModeChanged (src, modes)` (names) on every change, clears (duty off, demotion) and drop included.
function Admin.setMode(src, mode, on, data)
    if not isLoaded(src) or type(on) ~= 'boolean' then return false end
    if type(mode) ~= 'string' or #mode > MAX_MODE or not mode:match(MODE_PATTERN) then return false end
    local kind = type(data)
    if data ~= nil and kind ~= 'table' and kind ~= 'string' and kind ~= 'number' and kind ~= 'boolean' then
        return false
    end
    local set = modes[src]
    local was = set ~= nil and set[mode] ~= nil
    if on then
        if not set then
            set = {}
            modes[src] = set
        end
        if not was and Utils.count(set) >= MAX_MODES then return false end
        if data == nil then set[mode] = true else set[mode] = Utils.jsonSafe(data) end
    else
        if not was then return true end
        set[mode] = nil
        if next(set) == nil then modes[src] = nil end
    end
    if was == on then return true end
    sendSelf(src)
    if duty[src] then sendStaffState(src) end
    Core.emitHook('staffModeChanged', src, selfState(src).modes)
    audit('core', { actor = src, action = 'core.admin.mode', source = 'core',
        targets = { { type = 'player', id = src } }, changes = { { key = mode, old = was, new = on } },
        ctx = data ~= nil and { data = data } or nil })
    return true
end

--- A copy of { [mode] = data|true } (empty for nobody / no modes).
function Admin.getModes(src)
    local set = isSrc(src) and modes[src] or nil
    return set and Utils.deepCopy(set) or {}
end

--- Online staff (loaded, holding Config.Admin.StaffPerm), ascending; onDutyOnly filters by duty.
function Admin.staff(onDutyOnly)
    local out = {}
    for src in pairs(staffSet) do
        if not onDutyOnly or duty[src] then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

--- On-duty staff minus `exclude` (a src or an array), optionally only holders of `perm`.
local function echoTargets(perm, exclude)
    local skip = {}
    if type(exclude) == 'number' then skip[exclude] = true
    elseif type(exclude) == 'table' then for i = 1, #exclude do skip[exclude[i]] = true end end
    local out = {}
    local list = Admin.staff(true)
    for i = 1, #list do
        local src = list[i]
        if not skip[src] and (not perm or Core.Perms.has(src, perm)) then out[#out + 1] = src end
    end
    return out
end
P.echoTargets = echoTargets

--- Admin.echo(text, { perm?, exclude? }) -> number of staff told (`core:admin:echo` { text, at }).
function Admin.echo(message, opts)
    local line = text(message, MAX_ECHO)
    if not line then return 0 end
    if opts ~= nil and type(opts) ~= 'table' then return 0 end
    opts = opts or {}
    if opts.perm ~= nil and not isPerm(opts.perm) then return 0 end
    local targets = echoTargets(opts.perm, opts.exclude)
    if #targets == 0 then return 0 end
    return Core.Net.emitMany(targets, 'core:admin:echo', { text = line, at = os.time() })
end

-- == Transport (the run callback lives in adminapi_dispatch.lua) ==========================================

Core.Callback.register('core:admin:snapshot', function(src)
    return Admin.snapshot(src)
end, { permission = staffPerm(), cooldownMs = 1000 })

Core.Callback.register('core:admin:page', { { 'table', max = 8 } }, function(src, payload)
    local params = payload.params
    if not isId(payload.id) or (params ~= nil and type(params) ~= 'table') then return { ok = false, error = 'payload' } end
    return view(pages[payload.id], src, { id = payload.id, viewer = src, params = params })
end, { permission = staffPerm(), cooldownMs = 250 })

Core.Callback.register('core:admin:playerTab', { { 'table', max = 8 } }, function(src, payload)
    local target = toSrc(payload.target)
    if not isId(payload.id) or not isLoaded(target) then return { ok = false, error = 'payload' } end
    return view(playerTabs[payload.id], src, { id = payload.id, viewer = src, target = target })
end, { permission = staffPerm(), cooldownMs = 250 })

-- == Lifecycle =============================================================================================

-- A staff member (re)loads: membership, then its own state once (a reconnect or a core restart resets it).
Core.on('playerLoaded', function(value)
    local src = toSrc(value)
    if not src then return end
    refreshStaff(src)
    if staffSet[src] then sendSelf(src) end
end)

-- A player's rights changed (src) or a whole group did (nil): staff membership, then their snapshot.
Core.on('permsChanged', function(value)
    if value ~= nil then
        local src = toSrc(value)
        if not src then return end
        if refreshStaff(src) or staffSet[src] then queueSnapshot(src) end
        return
    end
    refreshAllStaff()
end)

AddEventHandler('playerDropped', function()
    local src = toSrc(source)
    if not src then return end
    local wasOnDuty, hadModes = duty[src] == true, modes[src] ~= nil
    staffSet[src], duty[src], modes[src], pendingSnapshot[src] = nil, nil, nil, nil
    if wasOnDuty then sendStaffState(src) end   -- { src, duty = false }: the on-duty staff drop the entry
    if hadModes then Core.emitHook('staffModeChanged', src, {}) end
end)

-- One-shot hand-off to server/adminapi_dispatch.lua (next in the manifest), which clears the slot. The
-- export resolves names with rawget, so a metatable field is never reachable from a plugin.
setmetatable(Admin, { __private = P })
