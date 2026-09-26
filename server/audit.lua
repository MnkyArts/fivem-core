--[[
    core/server/audit.lua — Core.Audit (DESIGN §46): the persisted, queryable audit trail.

    Audit.record(row) -> id        append one row (never updated afterwards); never yields, never throws
    Audit.recordLog(cat, src, msg) the Core.Log.audit mirror (lib/log): actor 'system', action 'core.<cat>'
    Audit.query(filter) -> { rows, next }   newest first, cursor paging
    Audit.get(id) -> row|nil
    Audit.prune() -> removed       retention now (the daily Cron job and the start do it by themselves)

    Storage is the Core.DB collection `audit` (one document per row). Core.DB already keeps every
    collection in memory, so this module keeps only a LEAN index next to it: one positional array per
    row, `entries` ascending by (ts, id), so a query is a backwards walk with early stops and never a
    DB.find over the collection. Full rows come from DB.get for the (<= 201) rows a page returns.

    Retention (settings `audit.retentionDays` / `audit.maxRows` / `audit.logMaxRows`, defined by
    server/settings.lua; 90 / 50000 / 20000 without it), in three pools that never evict each other: 'main'
    (the admin trail, maxRows), 'log' (Log.audit mirror rows `core.<category>` of gameplay categories such
    as money or faction, logMaxRows; staff categories admin/perms/player/native/settings/maps/bans stay in
    main) and 'exempt' (`sanction.*` / `ban.*`: no row cap, retentionDays x 4). A daily Cron job and the
    start prune oldest first within each pool. recordLog of a gameplay category writes at most 20 rows a
    second; the rest is counted into the next row's `ctx.suppressed`. The limits are cached (refreshed on
    prune and on a settings change): Settings.get may yield once on an async adapter and record() must not.

    Webhooks: rows with result 'ok'|'denied' go to Core.Webhook 'audit', denied rows also to
    'audit_denied'. Rows written by recordLog are NOT sent to 'audit': server/webhook.lua already mirrors
    every Log.audit line from the `audit` hook, and posting them twice would double the channel.

    Natives: GetGameTimer, GetPlayerName, GetConvar (server).
]]

local Audit = {}
Core.Audit = Audit

local Log = Core.Log
local Utils = Core.Utils

local COLLECTION <const> = 'audit'
local MAX_ACTION <const> = 64
local MAX_MESSAGE <const> = 512
local MAX_REASON <const> = 256
local MAX_VALUE <const> = 256
local MAX_NAME <const> = 64
local MAX_ID <const> = 64
local MAX_TARGETS <const> = 32
local MAX_CHANGES <const> = 64
local MAX_CTX_KEYS <const> = 32
local MAX_TEXT <const> = 640            -- lower-cased search text kept per row
local DEFAULT_LIMIT <const> = 50
local MAX_LIMIT <const> = 200
local DEFAULT_RETENTION_DAYS <const> = 90
local DEFAULT_MAX_ROWS <const> = 50000
local DEFAULT_LOG_MAX_ROWS <const> = 20000
local LOG_RATE_PER_S <const> = 20      -- recordLog rows per category and second; the rest is counted
-- Log.audit categories that are staff actions: their core.<category> rows live in the main pool
-- `cmd` = core's legacy staff commands (core.cmd.<name>, §4.8): staff actions stay in the main pool.
local STAFF_CATEGORIES <const> = { admin = true, perms = true, player = true, native = true, settings = true,
    maps = true, bans = true, cmd = true }
local EXEMPT_FACTOR <const> = 4
local DAY_MS <const> = 86400000
local MAX_PENDING <const> = 2000       -- rows recorded before the collection finished loading
local PRUNE_CHUNK <const> = 250        -- DB deletes per slice while pruning
local PRUNE_YIELD_MS <const> = 50      -- pause between two slices
local LOAD_RETRY_MS <const> = 30000
local ACTION_PATTERN <const> = '^[%w_%.%-:]+$'
local TYPE_PATTERN <const> = '^[%w_%-]+$'
local COLOR_OK <const> = 3447003
local COLOR_DENIED <const> = 15158332

local SOURCES <const> = { menu = true, palette = true, chat = true, console = true, editor = true, api = true, core = true }
local RESULTS <const> = { ok = true, denied = true, error = true }

-- index entry layout (positional: ~50k of them live at once)
local E_TS <const>, E_ID <const>, E_ACTION <const>, E_ACCOUNT <const> = 1, 2, 3, 4
local E_RESULT <const>, E_RESOURCE <const>, E_POOL <const>, E_TARGETS <const>, E_TEXT <const> = 5, 6, 7, 8, 9

local entries = {}          -- ascending (ts, id)
-- retention pools (R2-6): 'main' (admin trail, audit.maxRows), 'log' (Log.audit mirror rows of gameplay
-- categories, audit.logMaxRows), 'exempt' (sanction.* / ban.*: only retentionDays x 4). One pool never evicts another.
local poolCount = { main = 0, log = 0, exempt = 0 }
local logRate = {}          -- [category] = { at = second, n = rows this second, suppressed = n }
local logRateSize = 0       -- categories in logRate (reset past 256: dynamic category names stay bounded)
local loaded = false
local loadBarrier = nil     -- promise while the first load is in flight
local pending = {}          -- rows recorded before `loaded` (already mirrored; stored by loadIndex)
local pendingDropped = 0
local pruning = false
local pruneQueued = false
local limits = { days = DEFAULT_RETENTION_DAYS, main = DEFAULT_MAX_ROWS, log = DEFAULT_LOG_MAX_ROWS }

local clockOffset = os.time() * 1000 - GetGameTimer()
local lastTs, lastSeq = 0, 0

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------

--- Printable, trimmed, at most `max` bytes, never a cut UTF-8 sequence; nil for nothing.
local function clean(value, max)
    if value == nil then return nil end
    local text = Utils.sanitize(tostring(value), max)
    while #text > 0 and not utf8.len(text) do text = text:sub(1, -2) end
    if text == '' then return nil end
    return text
end

--- Wall clock in ms: os.time() gives the second, GetGameTimer() the milliseconds. Monotonic.
local function nowMs()
    local wall = os.time() * 1000
    local ts = GetGameTimer() + clockOffset
    if ts < wall - 2000 or ts > wall + 2000 then
        clockOffset = wall - GetGameTimer()
        ts = wall
    end
    if ts < lastTs then ts = lastTs end
    return math.floor(ts)
end

--- Sortable, unique row id: 'a' .. 13-digit ms timestamp .. 3-digit sequence within that ms.
local function newId()
    local ts = nowMs()
    if ts == lastTs then
        lastSeq = lastSeq + 1
        if lastSeq > 999 then ts, lastSeq = ts + 1, 0 end
    else
        lastSeq = 0
    end
    lastTs = ts
    return ('a%013d%03d'):format(ts, lastSeq), ts
end

--- A change / ctx value: scalars stay, strings are bounded, anything else is stringified (<= 256).
local function boundValue(value)
    local kind = type(value)
    if value == nil or kind == 'boolean' then return value end
    if kind == 'number' then
        if value ~= value or value == math.huge or value == -math.huge then return tostring(value) end
        return value
    end
    if kind == 'string' then return clean(value, MAX_VALUE) or '' end
    if kind == 'table' then
        local ok, encoded = pcall(function() return json.encode(Utils.jsonSafe(value)) end)
        if ok and type(encoded) == 'string' then return clean(encoded, MAX_VALUE) or '' end
    end
    return clean(tostring(value), MAX_VALUE) or ''
end

local function playerApi()
    local player = rawget(Core, 'Player')
    if type(player) ~= 'table' then return nil end
    return player
end

--- Player.getInfo(src) without ever throwing; nil when nobody is loaded on that src.
local function infoOf(src)
    local player = playerApi()
    local getInfo = player and rawget(player, 'getInfo')
    if type(getInfo) ~= 'function' then return nil end
    local ok, info = pcall(getInfo, src)
    if ok and type(info) == 'table' then return info end
    return nil
end

--- A positive integer server id from a number or a numeric string, else nil.
local function toSrc(value)
    if type(value) == 'string' and value:match('^%d+$') then value = tonumber(value) end
    if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
    value = math.tointeger(value)
    if not value or value <= 0 or value > 0x7FFFFFFF then return nil end
    return value
end

--------------------------------------------------------------------------------
-- row normalisation
--------------------------------------------------------------------------------

--- actor = src | 0 | 'system' | a pre-resolved { kind, src?, accountId?, name?, group? } -> snapshot.
local function resolveActor(actor)
    if actor == nil or actor == 'system' then return { kind = 'system' } end
    if actor == 0 or actor == '0' or actor == 'console' then return { kind = 'console', name = 'console' } end
    local src = toSrc(actor)
    if src then
        local info = infoOf(src)
        if info then
            return { kind = 'player', src = src, accountId = clean(info.accountId, MAX_ID),
                name = clean(info.name, MAX_NAME), group = clean(info.group, MAX_NAME) }
        end
        return { kind = 'player', src = src, name = clean(GetPlayerName(src), MAX_NAME) }
    end
    if type(actor) == 'table' then
        local kind = actor.kind
        if kind ~= 'player' and kind ~= 'console' and kind ~= 'system' then kind = 'system' end
        return { kind = kind, src = toSrc(actor.src), accountId = clean(actor.accountId, MAX_ID),
            name = clean(actor.name, MAX_NAME), group = clean(actor.group, MAX_NAME) }
    end
    return { kind = 'system' }
end

--- targets = { { type, id, name? } | src } -> bounded array; player targets gain accountId + name.
local function resolveTargets(list)
    if type(list) ~= 'table' then return nil end
    local out = {}
    for i = 1, math.min(#list, MAX_TARGETS) do
        local item = list[i]
        if type(item) ~= 'table' then item = { type = 'player', id = item } end
        local kind = clean(item.type, 32)
        if kind and kind:match(TYPE_PATTERN) then
            local id = item.id
            if type(id) == 'number' then
                id = (id == id and id % 1 == 0) and math.tointeger(id) or nil
            else
                id = clean(id, MAX_ID)
            end
            if id ~= nil then
                local target = { type = kind, id = id, name = clean(item.name, MAX_NAME),
                    accountId = clean(item.accountId, MAX_ID) }
                local src = kind == 'player' and toSrc(id)
                if src then
                    local info = infoOf(src)
                    if info then
                        target.accountId = target.accountId or clean(info.accountId, MAX_ID)
                        target.name = target.name or clean(info.name, MAX_NAME)
                    else
                        target.name = target.name or clean(GetPlayerName(src), MAX_NAME)
                    end
                end
                out[#out + 1] = target
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

--- changes = { { key, old, new } } (named or positional) -> bounded array.
local function boundChanges(list)
    if type(list) ~= 'table' then return nil end
    local out = {}
    for i = 1, math.min(#list, MAX_CHANGES) do
        local change = list[i]
        if type(change) == 'table' then
            local key = clean(change.key or change[1], MAX_NAME)
            if key then
                local old, new = change.old, change.new
                if old == nil and new == nil then old, new = change[2], change[3] end
                out[#out + 1] = { key = key, old = boundValue(old), new = boundValue(new) }
            end
        end
    end
    if #out == 0 then return nil end
    return out
end

--- ctx = { [string] = value } -> at most 32 keys, values bounded like change values.
local function boundCtx(ctx)
    if type(ctx) ~= 'table' then return nil end
    local out, n = {}, 0
    for key, value in pairs(ctx) do
        if n >= MAX_CTX_KEYS then break end
        local name = type(key) == 'string' and clean(key, MAX_NAME) or nil
        if name then
            out[name] = boundValue(value)
            n = n + 1
        end
    end
    if n == 0 then return nil end
    return out
end

--- The retention pool of an action: exempt (sanction.*, ban.*), log (core.<gameplay category>), main.
local function poolOf(action)
    if action:sub(1, 9) == 'sanction.' or action:sub(1, 4) == 'ban.' then return 'exempt' end
    if action:sub(1, 5) == 'core.' and not STAFF_CATEGORIES[action:match('^core%.([^.]+)') or ''] then
        return 'log'
    end
    return 'main'
end

--- The search text and the target keys of one stored row (lower case, bounded).
local function indexEntry(row)
    local actor = type(row.actor) == 'table' and row.actor or {}
    local parts, keys = { tostring(row.action or ''), actor.name or '', row.message or '', row.reason or '' }, nil
    if type(row.targets) == 'table' then
        local list = { '|' }
        for i = 1, #row.targets do
            local t = row.targets[i]
            if type(t) == 'table' and t.type ~= nil and t.id ~= nil then
                list[#list + 1] = ('%s:%s|'):format(t.type, tostring(t.id))
                if t.accountId then list[#list + 1] = ('account:%s|'):format(t.accountId) end
                parts[#parts + 1] = t.name or ''
            end
        end
        if #list > 1 then keys = table.concat(list) end
    end
    local text = table.concat(parts, ' '):lower()
    if #text > MAX_TEXT then text = text:sub(1, MAX_TEXT) end
    local action = tostring(row.action or '')
    return {
        math.floor(tonumber(row.ts) or 0), tostring(row.id), action, actor.accountId, row.result or 'ok',
        row.resource, poolOf(action), keys, text,
    }
end

local function before(a, b)
    if a[E_TS] ~= b[E_TS] then return a[E_TS] < b[E_TS] end
    return a[E_ID] < b[E_ID]
end

--- Appends, keeping (ts, id) order: new rows are the newest in practice, the loop is a safety net.
local function addEntry(entry)
    local i = #entries + 1
    while i > 1 and before(entry, entries[i - 1]) do i = i - 1 end
    table.insert(entries, i, entry)
    poolCount[entry[E_POOL]] = poolCount[entry[E_POOL]] + 1
end

--------------------------------------------------------------------------------
-- webhook mirror
--------------------------------------------------------------------------------

local function actorLabel(actor)
    if actor.kind ~= 'player' then return actor.kind end
    local label = actor.name or 'unknown'
    if actor.src then label = ('%s [%d]'):format(label, actor.src) end
    if actor.accountId then label = ('%s · %s'):format(label, actor.accountId) end
    return label
end

local function buildEmbed(row)
    local fields = { { name = 'Actor', value = actorLabel(row.actor), inline = true } }
    if row.targets then
        local list = {}
        for i = 1, math.min(#row.targets, 5) do
            local t = row.targets[i]
            list[i] = ('%s:%s%s'):format(t.type, tostring(t.id), t.name and (' ' .. t.name) or '')
        end
        if #row.targets > 5 then list[#list + 1] = ('+%d more'):format(#row.targets - 5) end
        fields[#fields + 1] = { name = 'Targets', value = table.concat(list, '\n'), inline = true }
    end
    if row.reason then fields[#fields + 1] = { name = 'Reason', value = row.reason } end
    if row.changes then
        local list = {}
        for i = 1, math.min(#row.changes, 5) do
            local c = row.changes[i]
            list[i] = ('%s: %s -> %s'):format(c.key, tostring(c.old), tostring(c.new))
        end
        fields[#fields + 1] = { name = 'Changes', value = table.concat(list, '\n') }
    end
    fields[#fields + 1] = { name = 'Source', value = ('%s / %s'):format(row.source, row.resource), inline = true }
    if row.result ~= 'ok' then fields[#fields + 1] = { name = 'Result', value = row.result, inline = true } end
    return {
        title = row.action, description = row.message, fields = fields,
        color = row.result == 'denied' and COLOR_DENIED or COLOR_OK,
    }
end

--- ok/denied rows -> 'audit' (unless the Log.audit hook already posted it) and denied -> 'audit_denied'.
local function mirror(row, fromLog)
    if row.result ~= 'ok' and row.result ~= 'denied' then return end
    local webhook = rawget(Core, 'Webhook')
    if type(webhook) ~= 'table' or type(webhook.send) ~= 'function' then return end
    local toAudit = not fromLog and GetConvar('core_webhook_audit', '') ~= ''
    local toDenied = row.result == 'denied' and GetConvar('core_webhook_audit_denied', '') ~= ''
    if not toAudit and not toDenied then return end
    local embed = buildEmbed(row)
    if toAudit then webhook.send('audit', embed) end
    if toDenied then webhook.send('audit_denied', embed) end
end

--------------------------------------------------------------------------------
-- persistence, load, retention
--------------------------------------------------------------------------------

--- A prune one second from now (coalesces a burst of records past the maxRows slack).
local function schedulePrune()
    if pruneQueued or pruning then return end
    pruneQueued = true
    CreateThread(function()
        Wait(1000)
        pruneQueued = false
        Audit.prune()
    end)
end

--- Past its cap + slack, a pool gets a prune one second from now (not per row).
local function overflowing(pool)
    local cap = limits[pool]
    return cap ~= nil and poolCount[pool] > cap + math.max(500, cap // 20)
end

--- Writes one row through Core.DB and indexes it. Returns the id, or nil when the DB refused it.
local function persist(row)
    local id = Core.DB.create(COLLECTION, row)
    if not id then
        Log.warn('audit: could not store row %s (%s)', row.id, row.action)
        return nil
    end
    addEntry(indexEntry(row))
    if overflowing('main') or overflowing('log') then schedulePrune() end
    return id
end

--- Builds the index from the stored documents (the predicate reads them in place and copies nothing),
--- then writes the rows recorded while the load was out. One loader; later callers wait on it.
local function loadIndex()
    if loaded then return true end
    if loadBarrier then
        pcall(Citizen.Await, loadBarrier)
        return loaded
    end
    local barrier = promise.new()
    loadBarrier = barrier
    local list = {}
    local ok, err = pcall(Core.DB.find, COLLECTION, function(doc)
        list[#list + 1] = indexEntry(doc)
        return false
    end)
    if ok and not Core.DB.isDegraded(COLLECTION) then
        table.sort(list, before)
        local counts = { main = 0, log = 0, exempt = 0 }
        for i = 1, #list do counts[list[i][E_POOL]] = counts[list[i][E_POOL]] + 1 end
        entries, poolCount, loaded = list, counts, true
        -- never older than what is stored: os.time() only has seconds, so a restart within the same
        -- second could otherwise mint an id that already exists (and sort before the stored rows)
        local newest = list[#list] and list[#list][E_TS] or 0
        if newest >= lastTs then lastTs, lastSeq = newest + 1, -1 end
        local queue = pending
        pending = {}
        for i = 1, #queue do
            local row = queue[i]
            if row.ts <= newest then row.id, row.ts = newId() end
            persist(row)
        end
        if pendingDropped > 0 then
            Log.warn('audit: %d row(s) were dropped while the collection was loading', pendingDropped)
            pendingDropped = 0
        end
        Log.debug('audit: %d row(s) indexed', #entries)
    else
        Log.error('audit: the %s collection could not be read (%s); rows stay queued', COLLECTION,
            tostring(ok and 'degraded' or err))
    end
    loadBarrier = nil
    barrier:resolve(loaded)
    return loaded
end

local function readLimit(settingsGet, key, fallback, min)
    if type(settingsGet) ~= 'function' then return fallback end
    local ok, value = pcall(settingsGet, key)
    if ok and type(value) == 'number' and value == value and value >= min and value < math.huge then
        return math.floor(value)
    end
    return fallback
end

--- Settings.get may yield once on an async adapter: only ever called from a thread, never from record().
local function refreshLimits()
    local settings = rawget(Core, 'Settings')
    local get = type(settings) == 'table' and rawget(settings, 'get') or nil
    limits.days = readLimit(get, 'audit.retentionDays', DEFAULT_RETENTION_DAYS, 1)
    limits.main = readLimit(get, 'audit.maxRows', DEFAULT_MAX_ROWS, 1)
    limits.log = readLimit(get, 'audit.logMaxRows', DEFAULT_LOG_MAX_ROWS, 1)
end

--- One retention pass (Audit.prune holds the `pruning` flag around it).
local function pruneNow()
    refreshLimits()
    local now = nowMs()
    local cutoff = now - limits.days * DAY_MS
    local exemptCutoff = now - limits.days * EXEMPT_FACTOR * DAY_MS
    -- per pool: how many rows survive the day cut, and so how many of its oldest must go for the cap
    local survivors = { main = 0, log = 0 }
    for i = 1, #entries do
        local e = entries[i]
        local pool = e[E_POOL]
        if pool ~= 'exempt' and e[E_TS] >= cutoff then survivors[pool] = survivors[pool] + 1 end
    end
    local overflow = { main = survivors.main - limits.main, log = survivors.log - limits.log }
    local kept, doomed, counts = {}, {}, { main = 0, log = 0, exempt = 0 }
    for i = 1, #entries do
        local e = entries[i]
        local pool, drop = e[E_POOL], false
        if pool == 'exempt' then
            drop = e[E_TS] < exemptCutoff
        elseif e[E_TS] < cutoff then
            drop = true
        elseif overflow[pool] > 0 then
            drop, overflow[pool] = true, overflow[pool] - 1
        end
        if drop then
            doomed[#doomed + 1] = e[E_ID]
        else
            kept[#kept + 1] = e
            counts[pool] = counts[pool] + 1
        end
    end
    entries, poolCount = kept, counts
    local canYield = coroutine.isyieldable()
    for i = 1, #doomed do
        Core.DB.delete(COLLECTION, doomed[i])
        if canYield and i % PRUNE_CHUNK == 0 then Wait(PRUNE_YIELD_MS) end
    end
    if #doomed > 0 then Log.info('audit: pruned %d row(s), %d kept', #doomed, #entries) end
    return #doomed
end

--- Retention, oldest first: rows older than retentionDays go (exempt rows: x4), then per pool the oldest rows
--- beyond its cap (main: maxRows, log: logMaxRows). The index is swapped at once; DB deletes follow in chunks.
--- @return integer removed
function Audit.prune()
    if not loaded and not loadIndex() then return 0 end
    if pruning then return 0 end
    pruning = true
    local ok, removed = pcall(pruneNow)
    pruning = false
    if not ok then
        Log.error('audit: prune failed: %s', tostring(removed))
        return 0
    end
    return removed
end

--------------------------------------------------------------------------------
-- public API
--------------------------------------------------------------------------------

local function buildRow(input)
    local action = input.action
    if type(action) ~= 'string' or #action > MAX_ACTION or not action:match(ACTION_PATTERN) then
        return nil, ('invalid action %s'):format(tostring(action))
    end
    local id, ts = newId()
    local registry = rawget(Core, 'Registry')
    local resource = clean(registry and registry.getCaller() or 'core', MAX_NAME) or 'core'
    local source = input.source
    if not SOURCES[source] then source = resource == 'core' and 'core' or 'api' end
    return {
        id = id, ts = ts, actor = resolveActor(input.actor), action = action, source = source,
        resource = resource, targets = resolveTargets(input.targets), changes = boundChanges(input.changes),
        reason = clean(input.reason, MAX_REASON), ctx = boundCtx(input.ctx),
        result = RESULTS[input.result] and input.result or 'ok', message = clean(input.message, MAX_MESSAGE),
    }
end

local function recordRow(input, fromLog)
    if type(input) ~= 'table' then return nil end
    local ok, row, err = pcall(buildRow, input)
    if not ok or not row then
        Log.warn('Audit.record: %s', tostring(ok and err or row))
        return nil
    end
    if loaded then
        if not persist(row) then return nil end
    else
        if #pending >= MAX_PENDING then
            table.remove(pending, 1)
            pendingDropped = pendingDropped + 1
        end
        pending[#pending + 1] = row
    end
    local sent, mirrorErr = pcall(mirror, row, fromLog)
    if not sent then Log.warn('audit: webhook mirror failed: %s', tostring(mirrorErr)) end
    return row.id
end

--- Append one row. Never yields, never throws; nil when the row was refused (bad action, DB refused).
--- @return string|nil id
function Audit.record(input)
    return recordRow(input, false)
end

--- The Core.Log.audit mirror (lib/log): `{ actor = 'system', action = 'core.' .. category,
--- targets = { player src }, message }`. Not re-posted to the 'audit' webhook (the hook already did).
function Audit.recordLog(category, src, message)
    local cat = clean(category, MAX_ACTION - 5)
    cat = cat and (cat:gsub('[^%w_%.%-:]', '_')) or 'log'
    local ctx = nil
    if poolOf('core.' .. cat) == 'log' then
        -- R2-6: a busy economy never floods the trail; staff categories are never capped
        local second, rate = GetGameTimer() // 1000, logRate[cat]
        if not rate then
            if logRateSize >= 256 then logRate, logRateSize = {}, 0 end
            rate = { at = second, n = 0, suppressed = 0 }
            logRate[cat], logRateSize = rate, logRateSize + 1
        end
        if rate.at ~= second then rate.at, rate.n = second, 0 end
        if rate.n >= LOG_RATE_PER_S then
            rate.suppressed = rate.suppressed + 1
            return nil
        end
        rate.n = rate.n + 1
        if rate.suppressed > 0 then ctx, rate.suppressed = { suppressed = rate.suppressed }, 0 end
    end
    local target = toSrc(src)
    return recordRow({
        actor = 'system', action = 'core.' .. cat, message = message, ctx = ctx,
        targets = target and { { type = 'player', id = target } } or nil,
    }, true)
end

--- A row by id (deep copy), or nil.
function Audit.get(id)
    if type(id) ~= 'string' or #id > MAX_ID then return nil end
    if not loaded then
        for i = 1, #pending do
            if pending[i].id == id then return Utils.deepCopy(pending[i]) end
        end
    end
    return Core.DB.get(COLLECTION, id)
end

--- from/to accept ms (like `ts`) or seconds (os.time()); anything below 1e11 is read as seconds.
local function toMs(value)
    if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then return nil end
    if value < 1e11 then value = value * 1000 end
    return math.floor(value)
end

--- The opaque cursor is '<ts>/<id>'; a bare row id of this module's format works as well.
local function cursorKey(cursor)
    if type(cursor) ~= 'string' or #cursor > 96 then return nil end
    local ts, id = cursor:match('^(%d+)/(.+)$')
    if ts then return { math.tointeger(tonumber(ts)) or 0, id } end
    ts = cursor:match('^a(%d%d%d%d%d%d%d%d%d%d%d%d%d)%d%d%d$')
    if ts then return { math.tointeger(tonumber(ts)) or 0, cursor } end
    return nil
end

--- Index of the last entry strictly before `key` ({ ts, id }), 0 when there is none.
local function lastBefore(key)
    local lo, hi = 1, #entries + 1
    while lo < hi do
        local mid = (lo + hi) // 2
        if before(entries[mid], key) then lo = mid + 1 else hi = mid end
    end
    return lo - 1
end

local function optString(value, max)
    if type(value) ~= 'string' or value == '' or #value > max then return nil end
    return value
end

--- Newest first. filter = { action?, actionPrefix?, actorAccount?, target? = { type, id }, resource?,
--- result?, from?, to?, text?, limit? = 50 (<= 200), before? = cursor } -> { rows, next }.
--- Cost: one backwards walk over the lean index (early stop at `from`, binary search for `to`/`before`)
--- plus one DB.get per returned row.
function Audit.query(filter)
    if type(filter) ~= 'table' then filter = {} end
    if not loaded and not loadIndex() then return { rows = {} } end
    local limit = DEFAULT_LIMIT
    if type(filter.limit) == 'number' and filter.limit == filter.limit then
        limit = math.max(1, math.min(MAX_LIMIT, math.floor(filter.limit)))
    end
    local action = optString(filter.action, MAX_ACTION)
    local prefix = optString(filter.actionPrefix, MAX_ACTION)
    local account = optString(filter.actorAccount, MAX_ID)
    local resource = optString(filter.resource, MAX_NAME)
    local result = RESULTS[filter.result] and filter.result or nil
    local targetKey
    local target = filter.target
    if type(target) == 'table' and type(target.type) == 'string' and target.id ~= nil then
        targetKey = ('|%s:%s|'):format(target.type, tostring(target.id))
    end
    local text = optString(filter.text, 128)
    text = text and text:lower()
    local from, to = toMs(filter.from), toMs(filter.to)
    -- a filter that is present but unusable matches nothing (it must never widen the result)
    if (filter.action ~= nil and not action) or (filter.actionPrefix ~= nil and not prefix)
        or (filter.actorAccount ~= nil and not account) or (filter.resource ~= nil and not resource)
        or (filter.result ~= nil and not result) or (filter.target ~= nil and not targetKey)
        or (filter.text ~= nil and not text) or (filter.from ~= nil and not from) or (filter.to ~= nil and not to) then
        return { rows = {} }
    end
    local start = #entries
    if filter.before ~= nil then
        local key = cursorKey(filter.before)
        if not key then return { rows = {} } end
        start = lastBefore(key)
    end
    if to then start = math.min(start, lastBefore({ to + 1, '' })) end

    local hits, more = {}, false
    local prefixLen = prefix and #prefix or 0
    for i = start, 1, -1 do
        local e = entries[i]
        if from and e[E_TS] < from then break end
        if (not action or e[E_ACTION] == action)
            and (not prefix or e[E_ACTION]:sub(1, prefixLen) == prefix)
            and (not account or e[E_ACCOUNT] == account)
            and (not resource or e[E_RESOURCE] == resource)
            and (not result or e[E_RESULT] == result)
            and (not targetKey or (e[E_TARGETS] and e[E_TARGETS]:find(targetKey, 1, true)))
            and (not text or e[E_TEXT]:find(text, 1, true)) then
            if #hits == limit then
                more = true
                break
            end
            hits[#hits + 1] = e
        end
    end
    local rows = {}
    for i = 1, #hits do
        local row = Core.DB.get(COLLECTION, hits[i][E_ID])
        if row then rows[#rows + 1] = row end
    end
    local last = hits[#hits]
    return { rows = rows, next = (more and last) and ('%d/%s'):format(last[E_TS], last[E_ID]) or nil }
end

--------------------------------------------------------------------------------
-- start: load the index once every server file ran, then retention + the daily job
--------------------------------------------------------------------------------

local running = true

CreateThread(function()
    Wait(0)   -- every server file has loaded, so db_pg.lua / db_mysql.lua picked the adapter already
    while running and not loadIndex() do Wait(LOAD_RETRY_MS) end
    if not running then return end
    Audit.prune()
    -- owner 'core': a thread of core's own resolves Registry.getCaller() to core (review M1, closed at the root)
    local cron = rawget(Core, 'Cron')
    if type(cron) == 'table' and type(cron.at) == 'function' then
        cron.at(4, 30, function() Audit.prune() end)
    end
    local settings = rawget(Core, 'Settings')
    if type(settings) == 'table' and type(settings.onChange) == 'function' then
        settings.onChange('audit.', function() schedulePrune() end)
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= Core.name then return end
    running = false
    if #pending > 0 then Log.warn('audit: %d queued row(s) were never stored', #pending) end
end)
