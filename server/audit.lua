--[[
    core/server/audit.lua — Core.Audit (DESIGN §46, storage §56): the persisted, queryable audit trail.

    Audit.record(row) -> true|nil  append one row (never updated afterwards); never yields, never throws
    Audit.recordLog(cat, src, msg) the Core.Log.audit mirror (lib/log): actor 'system', action 'core.<cat>'
    Audit.query(filter) -> { rows, next } | nil, err   newest first, keyset paging (awaited: one SQL query)
    Audit.get(id) -> row|nil       one select (awaited)
    Audit.prune() -> removed       retention now (the daily Cron job and the start do it by themselves)

    Storage is the table `audit_log` (sql/0001_core_schema.sql, §56.6). `record` builds the row, keeps its
    sanitising and bounds, and hands it to the write-behind queue with `Core.DB.append` — nothing yields, the
    identity `id` is assigned when the queue commits (so `record` answers true, not the id). The stored row
    carries its retention `pool`, `target_keys` ('type:id' + 'account:<id>', GIN) and a lower-cased `search`
    haystack (≤ 640, trigram index when pg_trgm exists): `query` is ONE parameterised SELECT with keyset paging on
    `id`, no in-memory index. Rows come back in the §46 shape: `id` as a decimal string, `ts` in ms.

    Retention (settings `audit.retentionDays` / `audit.maxRows` / `audit.logMaxRows`, defined by
    server/settings.lua; 90 / 50000 / 20000 without it), in three pools that never evict each other: 'main'
    (the admin trail, maxRows), 'log' (Log.audit mirror rows `core.<category>` of gameplay categories such
    as money or faction, logMaxRows; staff categories admin/perms/player/native/settings/maps/bans stay in
    main) and 'exempt' (`sanction.*` / `ban.*`: no row cap, retentionDays x 4). A prune is a few set-based
    DELETEs per pool (age cut, then everything at or below the (cap+1)-th newest id), in batches, run at start,
    by a daily Cron job, on a settings change and after max(500, cap/20) appends to a pool since the last prune.
    recordLog of a gameplay category writes at most 20 rows a second; the rest is counted into the next row's
    `ctx.suppressed`. The limits are cached (refreshed on prune): Settings.get may yield, record() must not.

    Webhooks: rows with result 'ok'|'denied' go to Core.Webhook 'audit', denied rows also to
    'audit_denied'. Rows written by recordLog are NOT sent to 'audit': server/webhook.lua already mirrors
    every Log.audit line from the `audit` hook, and posting them twice would double the channel.

    Natives: GetGameTimer, GetPlayerName, GetConvar (server).
]]

local Audit = {}
Core.Audit = Audit

local Log = Core.Log
local Utils = Core.Utils
local DB = Core.DB

local TABLE <const> = 'audit_log'
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
local PRUNE_BATCH <const> = 5000       -- rows per DELETE while pruning
local PRUNE_YIELD_MS <const> = 50      -- pause between two batches (only inside a thread)
local PRUNE_RETRY_MS <const> = 60000   -- a prune skipped because the settings were not loaded runs again then
local DROP_LOG_MS <const> = 10000      -- at most one "row not stored" warning per 10 s
local ACTION_PATTERN <const> = '^[%w_%.%-:]+$'
local TYPE_PATTERN <const> = '^[%w_%-]+$'
local COLOR_OK <const> = 3447003
local COLOR_DENIED <const> = 15158332

local SOURCES <const> = { menu = true, palette = true, chat = true, console = true, editor = true, api = true, core = true }
local RESULTS <const> = { ok = true, denied = true, error = true }

-- the one place the table's columns map to the §46 row (id as a decimal string, ts in ms)
local COLUMNS <const> = 'id, (extract(epoch FROM at) * 1000)::bigint AS ts, action, source, resource, result, actor, '
    .. 'targets, changes, reason, ctx, message'

-- retention pools (R2-6): 'main' (admin trail, audit.maxRows), 'log' (Log.audit mirror rows of gameplay
-- categories, audit.logMaxRows), 'exempt' (sanction.* / ban.*: only retentionDays x 4). One pool never evicts another.
local appended = { main = 0, log = 0 }   -- rows appended per capped pool since the last prune (overflow trigger)
local logRate = {}          -- [category] = { at = second, n = rows this second, suppressed = n }
local logRateSize = 0       -- categories in logRate (reset past 256: dynamic category names stay bounded)
local dropped, dropLoggedAt = 0, nil   -- rows the queue refused since the last warning
local pruning = false
local pruneQueued = false
local pruneRetry = false    -- a retry of a skipped prune is scheduled
local limits = { days = DEFAULT_RETENTION_DAYS, main = DEFAULT_MAX_ROWS, log = DEFAULT_LOG_MAX_ROWS }

local clockOffset = os.time() * 1000 - GetGameTimer()
local lastTs = 0

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
    lastTs = math.floor(ts)
    return lastTs
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

--- A row id (the identity) from an integer or a decimal string, else nil.
local function toRowId(value)
    if type(value) == 'string' then
        if #value > 18 or not value:match('^%d+$') then return nil end
        value = tonumber(value)
    end
    if math.type(value) ~= 'integer' and not (type(value) == 'number' and value % 1 == 0) then return nil end
    value = math.tointeger(value)
    if not value or value <= 0 then return nil end
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

--- A target's type and id the way rows store them: type `^[%w_%-]+$` <= 32, an integral number id as an
--- integer (12.0 -> 12; a fractional one is refused), any other id as a bounded string. nil when refused.
--- The ONE normalisation of the write path and of the `target` query filter.
local function normTarget(kind, id)
    kind = clean(kind, 32)
    if not kind or not kind:match(TYPE_PATTERN) then return nil end
    if type(id) == 'number' then
        id = (id == id and id % 1 == 0) and math.tointeger(id) or nil
    else
        id = clean(id, MAX_ID)
    end
    if id == nil then return nil end
    return kind, id
end

--- The `target_keys` entry of a target ('type:id'), or nil when such a target is never stored.
local function targetKeyOf(kind, id)
    local k, i = normTarget(kind, id)
    if not k then return nil end
    return ('%s:%s'):format(k, tostring(i))
end

--- targets = { { type, id, name? } | src } -> bounded array; player targets gain accountId + name.
local function resolveTargets(list)
    if type(list) ~= 'table' then return nil end
    local out = {}
    for i = 1, math.min(#list, MAX_TARGETS) do
        local item = list[i]
        if type(item) ~= 'table' then item = { type = 'player', id = item } end
        local kind, id = normTarget(item.type, item.id)
        if kind then
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

--- The stored form of one built row: every column given (NULL for the absent ones, so every append has the
--- same column set and a flush writes them in one bulk statement), target keys and the search haystack.
local function toStored(row)
    local NULL = DB.NULL
    local actor = row.actor
    local parts, keys, seen = { row.action, actor.name or '', row.message or '', row.reason or '' }, {}, {}
    local function key(k)
        if not seen[k] then
            seen[k] = true
            keys[#keys + 1] = k
        end
    end
    if row.targets then
        for i = 1, #row.targets do
            local t = row.targets[i]
            key(targetKeyOf(t.type, t.id))
            if t.accountId then key('account:' .. t.accountId) end
            parts[#parts + 1] = t.name or ''
        end
    end
    local text = table.concat(parts, ' '):lower()
    if #text > MAX_TEXT then text = text:sub(1, MAX_TEXT) end
    while #text > 0 and not utf8.len(text) do text = text:sub(1, -2) end
    return {
        at = row.ts / 1000, pool = poolOf(row.action), action = row.action, source = row.source,
        resource = row.resource, result = row.result, actor = actor, actor_account_id = actor.accountId or NULL,
        targets = row.targets or NULL, target_keys = keys, changes = row.changes or NULL, reason = row.reason or NULL,
        ctx = row.ctx or NULL, message = row.message or NULL, search = text,
    }
end

--- A selected row (COLUMNS) -> the §46 row.
local function fromStored(r)
    local id = math.tointeger(r.id)
    return {
        id = id and ('%d'):format(id) or tostring(r.id), ts = math.tointeger(r.ts) or r.ts,
        actor = type(r.actor) == 'table' and r.actor or { kind = 'system' }, action = r.action, source = r.source,
        resource = r.resource, targets = r.targets, changes = r.changes, reason = r.reason, ctx = r.ctx,
        result = r.result or 'ok', message = r.message,
    }
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
-- retention
--------------------------------------------------------------------------------

--- A prune one second from now (coalesces a burst of records past a pool's slack).
local function schedulePrune()
    if pruneQueued or pruning then return end
    pruneQueued = true
    CreateThread(function()
        Wait(1000)
        pruneQueued = false
        Audit.prune()
    end)
end

--- Past max(500, cap/20) appends since the last prune, a pool gets a prune one second from now (not per row).
local function noteAppend(pool)
    local cap = limits[pool]
    if cap == nil then return end
    appended[pool] = appended[pool] + 1
    if appended[pool] > math.max(500, cap // 20) then schedulePrune() end
end

local function readLimit(settingsGet, key, fallback, min)
    if type(settingsGet) ~= 'function' then return fallback end
    local ok, value = pcall(settingsGet, key)
    if ok and type(value) == 'number' and value == value and value >= min and value < math.huge then
        return math.floor(value)
    end
    return fallback
end

--- Settings.get may yield once while the overrides load: only ever called from prune, never from record().
--- False (limits untouched) while Core.Settings has not loaded its stored overrides: every value read then
--- is a DEFAULT, and a prune with defaults would irreversibly delete rows an admin configured to keep.
--- Without Core.Settings (or a stand-in without isLoaded) the defaults ARE the configuration.
local function refreshLimits()
    local settings = rawget(Core, 'Settings')
    local get = type(settings) == 'table' and rawget(settings, 'get') or nil
    local days = readLimit(get, 'audit.retentionDays', DEFAULT_RETENTION_DAYS, 1)
    local main = readLimit(get, 'audit.maxRows', DEFAULT_MAX_ROWS, 1)
    local log = readLimit(get, 'audit.logMaxRows', DEFAULT_LOG_MAX_ROWS, 1)
    local isLoaded = type(settings) == 'table' and rawget(settings, 'isLoaded') or nil
    if type(isLoaded) == 'function' then
        local ok, ready = pcall(isLoaded)
        if not ok or ready ~= true then return false end
    end
    limits.days, limits.main, limits.log = days, main, log
    return true
end

--- A prune skipped for unloaded settings runs again PRUNE_RETRY_MS later (one retry pending at a time).
local function retryPrune()
    if pruneRetry then return end
    pruneRetry = true
    CreateThread(function()
        Wait(PRUNE_RETRY_MS)
        pruneRetry = false
        Audit.prune()
    end)
end

--- DELETEs the rows matching `cond` (params $1..$n) oldest first, PRUNE_BATCH per statement.
--- @return integer removed, string|nil err
local function deleteWhere(cond, params)
    local n = #params + 1
    local sql = ('DELETE FROM audit_log WHERE id IN (SELECT id FROM audit_log WHERE %s ORDER BY id LIMIT $%d)')
        :format(cond, n)
    params[n] = PRUNE_BATCH
    local removed = 0
    while true do
        local count, err = DB.execute(sql, params)
        if not count then return removed, err end
        removed = removed + count
        if count < PRUNE_BATCH then return removed end
        if coroutine.isyieldable() then Wait(PRUNE_YIELD_MS) end
    end
end

--- Every row of `pool` beyond its `cap` newest (keeps exactly `cap`).
local function deleteBeyondCap(pool, cap)
    local boundary, err = DB.scalar('SELECT id FROM audit_log WHERE pool = $1 ORDER BY id DESC OFFSET $2 LIMIT 1',
        { pool, cap })
    if err then return 0, err end
    if boundary == nil then return 0 end
    return deleteWhere('pool = $1 AND id <= $2', { pool, boundary })
end

--- One retention pass (Audit.prune holds the `pruning` flag around it): age cut per pool, then the row caps.
local function pruneNow()
    if not refreshLimits() then
        Log.warn('audit: prune skipped — the settings (retention limits) are not loaded yet; retrying in %d s',
            PRUNE_RETRY_MS // 1000)
        retryPrune()
        return 0
    end
    appended.main, appended.log = 0, 0
    local now = nowMs()
    local steps = {
        function() return deleteWhere("pool <> 'exempt' AND at < to_timestamp($1::double precision / 1000)",
            { now - limits.days * DAY_MS }) end,
        function() return deleteWhere("pool = 'exempt' AND at < to_timestamp($1::double precision / 1000)",
            { now - limits.days * EXEMPT_FACTOR * DAY_MS }) end,
        function() return deleteBeyondCap('main', limits.main) end,
        function() return deleteBeyondCap('log', limits.log) end,
    }
    local total = 0
    for i = 1, #steps do
        local removed, err = steps[i]()
        total = total + removed
        if err then
            Log.error('audit: prune stopped (%s); %d row(s) removed', tostring(err), total)
            return total
        end
    end
    if total > 0 then Log.info('audit: pruned %d row(s)', total) end
    return total
end

--- Retention, oldest first: rows older than retentionDays go (exempt rows: x4), then per pool the oldest rows
--- beyond its cap (main: maxRows, log: logMaxRows). Awaited (a thread, or the offline bridge).
--- @return integer removed
function Audit.prune()
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
    local registry = rawget(Core, 'Registry')
    local resource = clean(registry and registry.getCaller() or 'core', MAX_NAME) or 'core'
    local source = input.source
    if not SOURCES[source] then source = resource == 'core' and 'core' or 'api' end
    return {
        ts = nowMs(), actor = resolveActor(input.actor), action = action, source = source,
        resource = resource, targets = resolveTargets(input.targets), changes = boundChanges(input.changes),
        reason = clean(input.reason, MAX_REASON), ctx = boundCtx(input.ctx),
        result = RESULTS[input.result] and input.result or 'ok', message = clean(input.message, MAX_MESSAGE),
    }
end

--- One refused append: counted, and logged at most once per DROP_LOG_MS.
local function noteDropped(row, err)
    dropped = dropped + 1
    local now = GetGameTimer()
    if dropLoggedAt and now - dropLoggedAt < DROP_LOG_MS then return end
    dropLoggedAt = now
    Log.warn('audit: %d row(s) could not be stored (last %s: %s)', dropped, row.action, tostring(err))
    dropped = 0
end

local function recordRow(input, fromLog)
    if type(input) ~= 'table' then return nil end
    local ok, row, err = pcall(buildRow, input)
    if not ok or not row then
        Log.warn('Audit.record: %s', tostring(ok and err or row))
        return nil
    end
    local stored
    ok, stored, err = pcall(function() return DB.append(TABLE, toStored(row)) end)
    if not ok or not stored then
        noteDropped(row, ok and err or stored)
        return nil
    end
    local pool = poolOf(row.action)
    if pool ~= 'exempt' then noteAppend(pool) end
    local sent, mirrorErr = pcall(mirror, row, fromLog)
    if not sent then Log.warn('audit: webhook mirror failed: %s', tostring(mirrorErr)) end
    return true
end

--- Append one row (queued). Never yields, never throws; true once queued, nil when refused (bad action, the
--- queue refused it). The row id is assigned when the queue commits.
--- @return true|nil
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

--- A row by id (a decimal string or an integer), or nil (nil, err when the database failed). Awaited.
function Audit.get(id)
    local rowId = toRowId(id)
    if not rowId then return nil end
    local row, err = DB.single(('SELECT %s FROM audit_log WHERE id = $1'):format(COLUMNS), { rowId })
    if not row then return nil, err end
    return fromStored(row)
end

--- from/to accept ms (like `ts`) or seconds (os.time()); anything below 1e11 is read as seconds.
local function toMs(value)
    if type(value) ~= 'number' or value ~= value or value == math.huge or value == -math.huge then return nil end
    if value < 1e11 then value = value * 1000 end
    return math.floor(value)
end

local function optString(value, max)
    if type(value) ~= 'string' or value == '' or #value > max then return nil end
    return value
end

--- A LIKE operand with its wildcards escaped (the default escape character is the backslash).
local function likeEscape(text)
    return (text:gsub('[\\%%_]', '\\%0'))
end

--- Newest first. filter = { action?, actionPrefix?, actorAccount?, target? = { type, id }, resource?,
--- result?, from?, to?, text?, limit? = 50 (<= 200), before? = cursor } -> { rows, next } | nil, err.
--- ONE parameterised SELECT (keyset on id, LIMIT limit + 1). The cursor is the last row's id (a decimal string);
--- an integer id works as well. Awaited: a thread, handler, callback or export call.
function Audit.query(filter)
    if type(filter) ~= 'table' then filter = {} end
    local limit = DEFAULT_LIMIT
    if type(filter.limit) == 'number' and filter.limit == filter.limit then
        limit = math.max(1, math.min(MAX_LIMIT, math.floor(filter.limit)))
    end
    local action = optString(filter.action, MAX_ACTION)
    local prefix = optString(filter.actionPrefix, MAX_ACTION)
    local account = optString(filter.actorAccount, MAX_ID)
    local resource = optString(filter.resource, MAX_NAME)
    local result = RESULTS[filter.result] and filter.result or nil
    local targetKey = nil
    local target = filter.target
    if type(target) == 'table' and type(target.type) == 'string' and target.id ~= nil then
        targetKey = targetKeyOf(target.type, target.id)
    end
    local text = optString(filter.text, 128)
    text = text and text:lower()
    local from, to = toMs(filter.from), toMs(filter.to)
    local before = nil
    if filter.before ~= nil then before = toRowId(filter.before) end
    -- a filter that is present but unusable matches nothing (it must never widen the result)
    if (filter.action ~= nil and not action) or (filter.actionPrefix ~= nil and not prefix)
        or (filter.actorAccount ~= nil and not account) or (filter.resource ~= nil and not resource)
        or (filter.result ~= nil and not result) or (filter.target ~= nil and not targetKey)
        or (filter.text ~= nil and not text) or (filter.from ~= nil and not from) or (filter.to ~= nil and not to)
        or (filter.before ~= nil and not before) then
        return { rows = {} }
    end

    local where, params = {}, {}
    local function add(cond, value)
        params[#params + 1] = value
        where[#where + 1] = (cond:gsub('%$n', '$' .. #params))
    end
    if action then add('action = $n', action) end
    if prefix then add("action LIKE $n::text || '%'", likeEscape(prefix)) end
    if account then add('actor_account_id = $n', account) end
    if resource then add('resource = $n', resource) end
    if result then add('result = $n', result) end
    if targetKey then add('target_keys @> ARRAY[$n::text]', targetKey) end
    if text then add("search ILIKE '%' || $n::text || '%'", likeEscape(text)) end
    if from then add('at >= to_timestamp($n::double precision / 1000)', from) end
    if to then add('at <= to_timestamp($n::double precision / 1000)', to) end
    if before then add('id < $n', before) end
    params[#params + 1] = limit + 1
    local sql = ('SELECT %s FROM audit_log%s ORDER BY id DESC LIMIT $%d'):format(COLUMNS,
        #where > 0 and (' WHERE ' .. table.concat(where, ' AND ')) or '', #params)

    local found, err = DB.query(sql, params)
    if not found then
        Log.warn('audit: query failed: %s', tostring(err))
        return nil, err
    end
    local rows = {}
    for i = 1, math.min(#found, limit) do rows[i] = fromStored(found[i]) end
    local more = #found > limit
    return { rows = rows, next = (more and rows[#rows]) and rows[#rows].id or nil }
end

--------------------------------------------------------------------------------
-- start: retention + the daily job, once every server file ran
--------------------------------------------------------------------------------

local running = true

CreateThread(function()
    Wait(0)   -- every server file has loaded (server/settings.lua defines the audit.* keys)
    if not running then return end
    -- owner 'core': a thread of core's own resolves Registry.getCaller() to core (review M1, closed at the root)
    local cron = rawget(Core, 'Cron')
    if type(cron) == 'table' and type(cron.at) == 'function' then
        cron.at(4, 30, function() Audit.prune() end)
    end
    local settings = rawget(Core, 'Settings')
    if type(settings) == 'table' and type(settings.onChange) == 'function' then
        settings.onChange('audit.', function() schedulePrune() end)
    end
    Audit.prune()   -- awaits core's migrations inside core_db before the first statement
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= Core.name then return end
    running = false
end)
