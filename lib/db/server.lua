--[[
    core / lib/db/server.lua  —  Core.DB, the relational database lib (DESIGN §56.5)

    Compiled into EVERY server VM by import.lua (`LIB_MODULES.DB`, server only: there is no
    lib/db/shared.lua and the client never sees Core.DB). Each VM talks to the `core_db`
    resource directly — one export hop, the invoking resource is the owner of every call (§56.1).

    Two classes of calls (§56.5.1):
      * AWAITED (query single scalar execute batch transaction stream nextId flush awaitMigrations
        status and the table helpers insert insertMany select first count update delete upsert):
        a promise the export callback resolves, `Citizen.Await`, and a Lua-side `SetTimeout`
        deadline (`opts.timeout`, default 30000 ms) that answers `nil, 'timeout'`. They answer
        `result` or `nil, err` — a failed read is never an empty result. Outside a coroutine
        they answer `nil, 'not_in_coroutine'` BEFORE anything is sent (logged once per call
        site), unless the transport answers synchronously: the offline test bridge
        (core/tests/pgbridge.lua) marks its `exports.core_db` object `synchronous = true`, so
        suites keep calling DB-backed code from their main chunk (§56.10.2). FiveM's own
        `exports` table never holds that raw field.
      * QUEUED (save patch remove append enqueue) and `migrate`: synchronous exports, never
        yield, safe at file scope and in onResourceStop; `true` or `false, err`.
    `core_db` not started: awaited calls `nil, 'unavailable'` (transaction/flush/awaitMigrations
    `false, 'unavailable'`), queued calls `false, 'unavailable'`, logged at most once per 10 s.

    Values across the hop (§56.2.4): `Core.DB.NULL` → `{ __null = true }`; nil holes in positional
    params are padded with that marker (`params.n`, else the highest integer key); vectors become
    `{ x, y, z[, w] }`; functions, userdata and threads are refused with `invalid: …`. Everything
    sent is a fresh deep copy, so a caller may reuse its tables at once.

    Removed names (§56.5.6): `REMOVED_MODE` below. 'error' (the default since every module was ported,
    2026-09-27) raises; 'soft' (the port's transition mode) warned once per name and answered a neutral value.
    'error' raises
    "Core.DB.<name> was removed (DESIGN §56): use <replacement>". Any other unknown name always
    raises — the import.lua export proxy is never attached to this namespace.

    Exports of core_db called here (§56.2.3): query, batch, crud, nextId, txBegin, txQuery, txEnd,
    enqueue, sync, migrate, awaitMigrations, status, isHealthy. `scalar` sends query / txQuery opts
    `{ scalar = true }`: core_db answers the first column BY FIELD ORDER (a Lua row map has no order).
    Every awaited export gets the caller's deadline as `timeoutMs` (in its opts, or its timeout argument
    for sync / awaitMigrations; txBegin's is the transaction deadline), so core_db can refuse to start work
    the caller already gave up on; the Lua-side deadline timer is cleared as soon as the answer arrives.
    Natives: GetResourceState (shared). Runtime helpers: SetTimeout, ClearTimeout, Wait, Citizen.Await, promise.
]]

local ns = ...

--- 'soft' = removed names warn once and answer a neutral value; 'error' = they raise (§56.5.6).
local REMOVED_MODE <const> = 'error'

local RESOURCE <const> = 'core_db'
local DEFAULT_TIMEOUT_MS <const> = 30000       -- the Lua-side deadline of one awaited call
local MIGRATION_TIMEOUT_MS <const> = 60000     -- awaitMigrations default
local TX_TIMEOUT_MS <const> = 10000            -- a transaction's deadline (§56.2.3 default; core_db caps it at 60000)
local STREAM_TX_TIMEOUT_MS <const> = 60000     -- a stream's transaction deadline (core_db's max)
local STREAM_BATCH <const> = 500
local MAX_STREAM_BATCH <const> = 10000
local GRACE_MS <const> = 1000                  -- Lua deadline past a timeout core_db enforces itself
local UNAVAILABLE_LOG_MS <const> = 10000
local MAX_DEPTH <const> = 32
local SELF_CHUNK <const> = 'lib/db/server.lua:'

local OPS <const> = {
    ['='] = true, ['<>'] = true, ['<'] = true, ['<='] = true, ['>'] = true, ['>='] = true,
    like = true, ilike = true, not_like = true, ['in'] = true, not_in = true, between = true,
    is_null = true, not_null = true, contains = true, overlaps = true,
}
local VECTOR_KEYS <const> = {
    vector2 = { 'x', 'y' }, vector3 = { 'x', 'y', 'z' }, vector4 = { 'x', 'y', 'z', 'w' },
    quat = { 'x', 'y', 'z', 'w' },
}
local REFUSED_TYPES <const> = { ['function'] = true, userdata = true, thread = true }

--- The SQL NULL sentinel (params, values, where). Never sent as is: the copy turns it into MARKER.
local NULL <const> = setmetatable({}, {
    __newindex = function() error('Core.DB.NULL is read-only', 2) end,
    __tostring = function() return 'Core.DB.NULL' end,
    __metatable = false,
})
local MARKER <const> = { __null = true }   -- what core_db maps to SQL NULL (§56.2.4)

--------------------------------------------------------------------------------
-- marshalling (§56.2.4)
--------------------------------------------------------------------------------

--- Deep copy of one value for the hop, or nil + 'invalid: …'.
local function copyValue(v, depth, seen)
    if rawequal(v, NULL) then return MARKER end
    local kind = type(v)
    if kind ~= 'table' then
        if REFUSED_TYPES[kind] then return nil, ('invalid: a %s cannot be sent to core_db'):format(kind) end
        local keys = VECTOR_KEYS[kind]
        if not keys then return v end
        local out = {}
        for i = 1, #keys do out[keys[i]] = v[keys[i]] end
        return out
    end
    if depth > MAX_DEPTH then return nil, 'invalid: value nested too deeply' end
    if seen[v] then return nil, 'invalid: cyclic table' end
    seen[v] = true
    local out = {}
    for key, value in pairs(v) do
        local keyKind = type(key)
        if keyKind ~= 'string' and keyKind ~= 'number' then
            seen[v] = nil
            return nil, ('invalid: a %s key cannot be sent to core_db'):format(keyKind)
        end
        local copy, err = copyValue(value, depth + 1, seen)
        if err then
            seen[v] = nil
            return nil, err
        end
        out[key] = copy
    end
    seen[v] = nil
    return out
end

local function copy(v)
    return copyValue(v, 1, {})
end

--- Positional params → a fresh sequence 1..n with NULL markers in the holes.
local function copyParams(params)
    if params == nil then return {} end
    if type(params) ~= 'table' or rawequal(params, NULL) then return nil, 'invalid: params must be a sequence' end
    local n, maxKey = params.n, 0
    for key in pairs(params) do
        if math.type(key) == 'integer' and key > 0 then
            if key > maxKey then maxKey = key end
        elseif key ~= 'n' then
            return nil, 'invalid: params must be a sequence (positional $1..$n)'
        end
    end
    if n == nil then
        n = maxKey
    else
        n = math.tointeger(n)
        if not n or n < 0 then return nil, 'invalid: params.n must be a count' end
    end
    local out = {}
    for i = 1, n do
        local value = params[i]
        if value == nil then
            out[i] = MARKER
        else
            local c, err = copy(value)
            if err then return nil, err end
            out[i] = c
        end
    end
    return out
end

--- A column map (values / set / row / changes / where) → a fresh copy keyed by column name.
local function copyMap(map, what, allowEmpty)
    if type(map) ~= 'table' or rawequal(map, NULL) then return nil, ('invalid: %s must be a table'):format(what) end
    local out = {}
    for key, value in pairs(map) do
        if type(key) ~= 'string' then return nil, ('invalid: %s keys must be column names'):format(what) end
        local c, err = copy(value)
        if err then return nil, err end
        out[key] = c
    end
    if not allowEmpty and next(out) == nil then return nil, ('invalid: %s must not be empty'):format(what) end
    return out
end

--- A WHERE map (§56.5.3): nil/{} = no condition when `required` is false; ops checked by name.
local function copyWhere(where, required)
    if where == nil then
        if required then return nil, 'invalid: where must not be empty' end
        return nil
    end
    local out, err = copyMap(where, 'where', not required)
    if not out then return nil, err end
    for _, value in pairs(out) do
        if type(value) == 'table' and value.__op ~= nil and not OPS[value.__op] then
            return nil, ('invalid: unknown op %s'):format(tostring(value.__op))
        end
    end
    if next(out) == nil then return nil end
    return out
end

local function checkTable(name)
    if type(name) ~= 'string' or #name > 63 or not name:find('^[a-z_][a-z0-9_]*$') then
        return 'invalid: bad table name'
    end
    return nil
end

--- `opts` → opts (possibly the shared empty table), or nil + err.
local EMPTY <const> = setmetatable({}, { __newindex = function() error('read-only', 2) end })
local function readOpts(opts)
    if opts == nil then return EMPTY end
    if type(opts) ~= 'table' then return nil, 'invalid: opts must be a table' end
    local t = opts.timeout
    if t ~= nil and (type(t) ~= 'number' or not (t > 0) or t == math.huge) then
        return nil, 'invalid: opts.timeout must be a positive number of ms'
    end
    return opts
end

local function deadlineOf(opts, default)
    local t = opts.timeout
    if t then return math.floor(t) end
    return default or DEFAULT_TIMEOUT_MS
end

--------------------------------------------------------------------------------
-- availability, coroutine checks, logging
--------------------------------------------------------------------------------

local unavailableMuted = false

local function unavailable(what, detail)
    if not unavailableMuted then
        unavailableMuted = true
        Core.Log.warn('DB.%s: core_db is not available (%s) — ensure core_db (DESIGN §56.1)', what,
            detail and tostring(detail) or 'not started')
        SetTimeout(UNAVAILABLE_LOG_MS, function() unavailableMuted = false end)
    end
    return 'unavailable'
end

local function started()
    return GetResourceState(RESOURCE) == 'started'
end

--- True when the running code may yield (a thread, event handler, command, callback body).
local function canYield()
    local _, isMain = coroutine.running()
    return not isMain and coroutine.isyieldable()
end

--- The offline bridge answers inside the export call (§56.10.2); FiveM's `exports` never holds it raw.
local function synchronousTransport()
    local target = rawget(exports, RESOURCE)
    return type(target) == 'table' and rawget(target, 'synchronous') == true
end

--- 'file:line' of the first caller outside this file.
local function callSite()
    for level = 3, 14 do
        local _, where = pcall(error, '', level)
        if type(where) == 'string' and where ~= '' and not where:find(SELF_CHUNK, 1, true) then
            return (where:gsub(':%s*$', ''))
        end
    end
    return '?'
end

local loggedSites = {}

local function notInCoroutine(what)
    local site = callSite()
    if not loggedSites[site] then
        loggedSites[site] = true
        Core.Log.error('DB.%s at %s runs outside a coroutine — call it from a thread, event handler or '
            .. 'Core.onReady body (DESIGN §56.5.1)', what, site)
    end
    return 'not_in_coroutine'
end

--------------------------------------------------------------------------------
-- the export hop
--------------------------------------------------------------------------------

local function invoke(fnName, args)
    local target = exports[RESOURCE]
    return target[fnName](target, table.unpack(args, 1, args.n))
end

--- `exports.core_db:<fnName>(..., cb)` and wait for cb: the packed callback arguments (err
--- first), or nil + 'unavailable' / 'not_in_coroutine'. A timeout answers `{ 'timeout' }`.
local function await(fnName, deadlineMs, ...)
    if not started() then return nil, unavailable(fnName) end
    if not canYield() and not synchronousTransport() then return nil, notInCoroutine(fnName) end
    local answer, timer
    local p = promise.new()
    local args = table.pack(...)
    args.n = args.n + 1
    args[args.n] = function(...)
        if answer then return end
        answer = table.pack(...)
        if timer then
            ClearTimeout(timer)   -- the deadline is moot: never keep a 30 s timer per answered call
            timer = nil
        end
        p:resolve(answer)
    end
    local ok, callErr = pcall(invoke, fnName, args)
    if not ok then
        answer = answer or { n = 1, 'unavailable' }
        return nil, unavailable(fnName, callErr)
    end
    if not answer then
        if not canYield() then return nil, notInCoroutine(fnName) end
        timer = SetTimeout(deadlineMs, function()
            timer = nil
            if answer then return end
            answer = { n = 1, 'timeout' }
            p:resolve(answer)
        end)
        Citizen.Await(p)
    end
    return answer
end

--- A synchronous export (enqueue / migrate / isHealthy): its return value, or nil + err.
local function callSync(fnName, ...)
    if not started() then return nil, unavailable(fnName) end
    local ok, result = pcall(invoke, fnName, table.pack(...))
    if not ok then return nil, unavailable(fnName, result) end
    return result
end

--------------------------------------------------------------------------------
-- raw SQL and table helpers: ONE builder for Core.DB and for a transaction's `tx` (§56.5.2/3)
--------------------------------------------------------------------------------

--- The callback answer (err first) → the answer, or nil + err.
local function settle(answer, err)
    if not answer then return nil, err end
    if answer[1] ~= nil then return nil, tostring(answer[1]) end
    return answer
end

--- The wire opts of query / batch: `timeoutMs` is ALWAYS the caller's deadline, so core_db can refuse to
--- start work the caller already gave up on (review M4).
local function wireOpts(o)
    return { sync = o.sync == true or nil, timeoutMs = deadlineOf(o) }
end


--- Builds the awaited API on a context: ctx = {} for Core.DB, { txId, failed, closed } for a tx.
local function buildApi(ctx)
    local api = {}

    --- A failed statement inside a transaction marks it for rollback (§56.5.2).
    local function fail(err)
        if ctx.txId and not ctx.failed then ctx.failed = err end
        return nil, err
    end

    local function send(sql, p, o, scalar)
        local wire = wireOpts(o)
        wire.scalar = scalar or nil
        if ctx.txId then return settle(await('txQuery', deadlineOf(o), ctx.txId, sql, p, wire)) end
        return settle(await('query', deadlineOf(o), sql, p, wire))
    end

    --- true, rows | value, rowCount — or nil, err. `scalar` = core_db answers the first column of the first
    --- row BY FIELD ORDER instead of the rows (a Lua row map has no column order; review L6).
    local function statement(sql, params, opts, scalar)
        if ctx.closed then return nil, 'tx_unknown' end
        if type(sql) ~= 'string' or sql == '' then return fail('invalid: sql must be a non-empty string') end
        local o, err = readOpts(opts)
        if not o then return fail(err) end
        local p
        p, err = copyParams(params)
        if not p then return fail(err) end
        local answer
        answer, err = send(sql, p, o, scalar)
        if not answer then return fail(err) end
        if scalar then return true, answer[2], answer[3] end
        return true, answer[2] or {}, answer[3]
    end

    --- crud(op, table, args, txId, cb): the helper's result, or nil + err.
    local function crud(op, tbl, args, o)
        if ctx.closed then return nil, 'tx_unknown' end
        local err = checkTable(tbl)
        if err then return fail(err) end
        args.sync = o.sync == true or nil
        args.timeoutMs = deadlineOf(o)
        local answer
        answer, err = settle(await('crud', deadlineOf(o), op, tbl, args, ctx.txId or 0))
        if not answer then return fail(err) end
        return answer[2]
    end

    function api.query(sql, params, opts)
        local ok, rows = statement(sql, params, opts)
        if not ok then return nil, rows end
        return rows
    end

    function api.single(sql, params, opts)
        local ok, rows = statement(sql, params, opts)
        if not ok then return nil, rows end
        return rows[1]
    end

    --- The first column (by field order) of the first row; (nil, nil) without a row or for NULL.
    function api.scalar(sql, params, opts)
        local ok, value = statement(sql, params, opts, true)
        if not ok then return nil, value end
        return value
    end

    function api.execute(sql, params, opts)
        local ok, rows, rowCount = statement(sql, params, opts)
        if not ok then return nil, rows end
        return math.tointeger(rowCount) or 0
    end

    function api.insert(tbl, values, opts)
        local o, err = readOpts(opts)
        if not o then return fail(err) end
        local v
        v, err = copyMap(values, 'values', true)
        if not v then return fail(err) end
        local returning = o.returning
        if returning ~= nil and returning ~= false then
            returning, err = copy(returning)
            if err then return fail(err) end
        end
        return crud('insert', tbl, { values = v, returning = returning }, o)
    end

    function api.insertMany(tbl, rows, opts)
        local o, err = readOpts(opts)
        if not o then return fail(err) end
        if type(rows) ~= 'table' or rows[1] == nil then return fail('invalid: rows must be a non-empty sequence') end
        local list = {}
        for i = 1, #rows do
            list[i], err = copyMap(rows[i], 'row', true)
            if not list[i] then return fail(err) end
        end
        return crud('insertMany', tbl, { rows = list }, o)
    end

    --- select / first / count share the read arguments (§56.5.3).
    local function read(op, tbl, where, opts)
        local o, err = readOpts(opts)
        if not o then return fail(err) end
        local w
        w, err = copyWhere(where, false)
        if err then return fail(err) end
        local args = { where = w }
        if op ~= 'count' then
            if o.columns ~= nil then
                args.columns, err = copy(o.columns)
                if err then return fail(err) end
            end
            if o.orderBy ~= nil and type(o.orderBy) ~= 'string' then return fail('invalid: orderBy must be a string') end
            args.orderBy, args.limit, args.offset = o.orderBy, o.limit, o.offset
        end
        return crud(op, tbl, args, o)
    end

    function api.select(tbl, where, opts)
        local rows, err = read('select', tbl, where, opts)
        if rows == nil then return nil, err end
        return rows
    end

    function api.first(tbl, where, opts)
        return read('first', tbl, where, opts)
    end

    function api.count(tbl, where, opts)
        local n, err = read('count', tbl, where, opts)
        if n == nil then return nil, err end
        return math.tointeger(n) or n
    end

    function api.update(tbl, set, where, opts)
        local o, err = readOpts(opts)
        if not o then return fail(err) end
        local s, w
        s, err = copyMap(set, 'set', false)
        if not s then return fail(err) end
        w, err = copyWhere(where, true)
        if not w then return fail(err) end
        return crud('update', tbl, { set = s, where = w }, o)
    end

    function api.delete(tbl, where, opts)
        local o, err = readOpts(opts)
        if not o then return fail(err) end
        local w
        w, err = copyWhere(where, true)
        if not w then return fail(err) end
        return crud('delete', tbl, { where = w }, o)
    end

    function api.upsert(tbl, values, conflict, opts)
        local o, err = readOpts(opts)
        if not o then return fail(err) end
        local v, c, u, returning
        v, err = copyMap(values, 'values', false)
        if not v then return fail(err) end
        if type(conflict) == 'string' then conflict = { conflict } end
        if type(conflict) ~= 'table' or conflict[1] == nil then
            return fail('invalid: conflict must be a column or a list of columns')
        end
        c, err = copy(conflict)
        if err then return fail(err) end
        if o.update ~= nil then
            u, err = copy(o.update)
            if err then return fail(err) end
        end
        returning = o.returning
        if returning ~= nil and returning ~= false then
            returning, err = copy(returning)
            if err then return fail(err) end
        end
        return crud('upsert', tbl, { values = v, conflict = c, update = u, returning = returning }, o)
    end

    return api
end

local base = buildApi({})
for name, fn in pairs(base) do ns[name] = fn end

--- Core.DB.batch({ { sql, params }, ... }, opts?) → results | nil, err — one transaction, one hop.
function ns.batch(statements, opts)
    local o, err = readOpts(opts)
    if not o then return nil, err end
    if type(statements) ~= 'table' or statements[1] == nil then
        return nil, 'invalid: statements must be a non-empty sequence'
    end
    local list = {}
    for i = 1, #statements do
        local s = statements[i]
        local sql = type(s) == 'table' and (s.sql or s[1]) or nil
        if type(sql) ~= 'string' or sql == '' then return nil, ('invalid: statement %d has no sql'):format(i) end
        local p
        p, err = copyParams(s.params or s[2])
        if not p then return nil, err end
        list[i] = { sql = sql, params = p }
    end
    local wire = wireOpts(o)
    wire.rows = o.rows == true or nil
    local answer
    answer, err = settle(await('batch', deadlineOf(o), list, wire))
    if not answer then return nil, err end
    return answer[2] or {}
end

--- Core.DB.nextId(name) → integer | nil, err (core_counters, atomic).
function ns.nextId(name)
    if type(name) ~= 'string' or name == '' then return nil, 'invalid: name must be a non-empty string' end
    local answer, err = settle(await('nextId', DEFAULT_TIMEOUT_MS, name, { timeoutMs = DEFAULT_TIMEOUT_MS }))
    if not answer then return nil, err end
    return math.tointeger(answer[2]) or answer[2]
end

--------------------------------------------------------------------------------
-- transactions and streams (§56.5.2)
--------------------------------------------------------------------------------

local function isCallable(fn)
    if type(fn) == 'function' then return true end
    local mt = type(fn) == 'table' and getmetatable(fn)
    return type(mt) == 'table' and mt.__call ~= nil
end

--- The `tx` handed to fn: the same methods as Core.DB, callable as tx.query(...) or tx:query(...).
local function newTx(ctx)
    local tx = {}
    for name, fn in pairs(buildApi(ctx)) do
        tx[name] = function(first, ...)
            if rawequal(first, tx) then return fn(...) end
            return fn(first, ...)
        end
    end
    return tx
end

--- Core.DB.transaction(fn, opts?) → true, fnResult... | false, err. fn returning false (+ reason),
--- throwing, or a failed tx statement rolls back; opts.timeout = the tx deadline (core_db clamps).
function ns.transaction(fn, opts)
    if not isCallable(fn) then return false, 'invalid: fn must be a function' end
    local o, err = readOpts(opts)
    if not o then return false, err end
    local answer
    answer, err = settle(await('txBegin', DEFAULT_TIMEOUT_MS, { timeoutMs = deadlineOf(o, TX_TIMEOUT_MS) }))
    if not answer then return false, err end
    -- without an id every tx.* call would silently run OUTSIDE the transaction
    if answer[2] == nil or answer[2] == 0 then return false, 'invalid: txBegin answered no transaction id' end
    local ctx = { txId = answer[2] }
    local result = table.pack(pcall(fn, newTx(ctx)))
    local failure
    if not result[1] then
        failure = 'error: ' .. tostring(result[2])
        Core.Log.error('DB.transaction: %s', tostring(result[2]))
    elseif result[2] == false then
        failure = type(result[3]) == 'string' and result[3] or ctx.failed or 'rollback'
    elseif ctx.failed then
        failure = ctx.failed
    end
    local ended, endErr = settle(await('txEnd', DEFAULT_TIMEOUT_MS, ctx.txId, failure == nil))
    ctx.closed = true
    if failure then return false, failure end
    if not ended then return false, endErr end
    return true, table.unpack(result, 2, result.n)
end

--- Core.DB.stream(sql, params, fn, opts?) → total | nil, err: a server-side cursor inside a
--- transaction, fn(rows) per batch of opts.batch (default 500); fn returning false stops.
function ns.stream(sql, params, fn, opts)
    if type(sql) ~= 'string' or sql == '' then return nil, 'invalid: sql must be a non-empty string' end
    if not isCallable(fn) then return nil, 'invalid: fn must be a function' end
    local o, err = readOpts(opts)
    if not o then return nil, err end
    local batch = o.batch == nil and STREAM_BATCH or math.tointeger(o.batch)
    if not batch or batch < 1 or batch > MAX_STREAM_BATCH then
        return nil, ('invalid: opts.batch must be an integer 1..%d'):format(MAX_STREAM_BATCH)
    end
    if o.sync then
        -- read-your-writes (§56.5.2): the cursor's transaction starts after everything queued so far committed
        local synced, syncErr = ns.flush(o.timeout)
        if not synced and syncErr and not tostring(syncErr):find('^dropped:') then return nil, syncErr end
    end
    local cursorSql = 'DECLARE core_stream NO SCROLL CURSOR FOR ' .. sql:gsub('[%s;]+$', '')
    local fetchSql = ('FETCH %d FROM core_stream'):format(batch)
    local ok, total = ns.transaction(function(tx)
        local _, declareErr = tx.execute(cursorSql, params)
        if declareErr then return false, declareErr end
        local count = 0
        while true do
            local rows, fetchErr = tx.query(fetchSql)
            if not rows then return false, fetchErr end
            local n = #rows
            if n == 0 then break end
            count = count + n
            if fn(rows) == false or n < batch then break end
            -- one batch per server tick keeps a big load off a single frame; the loop ends with the
            -- cursor (bounded by the row count) and never waits in non-yieldable code
            if canYield() then Wait(0) end -- per-frame: one FETCH per tick while the cursor lasts
        end
        return count
    end, { timeout = o.timeout or STREAM_TX_TIMEOUT_MS })
    if not ok then return nil, total end
    return total
end

--------------------------------------------------------------------------------
-- queued writes (§56.5.4) — synchronous, never yield
--------------------------------------------------------------------------------

local function enqueue(entry)
    local result, err = callSync('enqueue', { entry })
    if result == nil then return false, err end
    if type(result) ~= 'table' then return false, 'invalid: no answer from enqueue' end
    if result.error ~= nil then return false, tostring(result.error) end
    return true
end

--- A PK value, or a map holding every PK column.
local function copyKey(key)
    if key == nil or rawequal(key, NULL) then return nil, 'invalid: key is required' end
    if type(key) == 'table' then return copyMap(key, 'key', false) end
    return copy(key)
end

function ns.save(tbl, row)
    local err = checkTable(tbl)
    if err then return false, err end
    local r
    r, err = copyMap(row, 'row', false)
    if not r then return false, err end
    return enqueue({ t = 'save', table = tbl, row = r })
end

function ns.patch(tbl, key, changes)
    local err = checkTable(tbl)
    if err then return false, err end
    local k, c
    k, err = copyKey(key)
    if k == nil then return false, err end
    c, err = copyMap(changes, 'changes', false)
    if not c then return false, err end
    return enqueue({ t = 'patch', table = tbl, key = k, changes = c })
end

function ns.remove(tbl, key)
    local err = checkTable(tbl)
    if err then return false, err end
    local k
    k, err = copyKey(key)
    if k == nil then return false, err end
    return enqueue({ t = 'remove', table = tbl, key = k })
end

function ns.append(tbl, row)
    local err = checkTable(tbl)
    if err then return false, err end
    local r
    r, err = copyMap(row, 'row', true)
    if not r then return false, err end
    return enqueue({ t = 'append', table = tbl, row = r })
end

function ns.enqueue(sql, params, key)
    if type(sql) ~= 'string' or sql == '' then return false, 'invalid: sql must be a non-empty string' end
    local p, err = copyParams(params)
    if not p then return false, err end
    if key ~= nil then
        key, err = copy(key)
        if err then return false, err end
    end
    return enqueue({ t = 'sql', sql = sql, params = p, key = key })
end

--------------------------------------------------------------------------------
-- migrations, flush, health (§56.5.5)
--------------------------------------------------------------------------------

--- Core.DB.migrate(list) → true | false, err — non-blocking, call it at file scope (§56.4.1).
function ns.migrate(list)
    if type(list) ~= 'table' or list[1] == nil then return false, 'invalid: migrate takes a list of migrations' end
    local l, err = copy(list)
    if not l then return false, err end
    local result
    result, err = callSync('migrate', l)
    if result == nil then return false, err end
    if type(result) ~= 'table' then return false, 'invalid: no answer from migrate' end
    if result.error ~= nil then return false, tostring(result.error) end
    return true
end

local function timeoutArg(timeoutMs, default)
    if timeoutMs == nil then return default end
    if type(timeoutMs) ~= 'number' or not (timeoutMs > 0) or timeoutMs == math.huge then return nil end
    return math.floor(timeoutMs)
end

--- Core.DB.awaitMigrations(timeoutMs?) → true | false, err — waits for this resource's barrier.
function ns.awaitMigrations(timeoutMs)
    local t = timeoutArg(timeoutMs, MIGRATION_TIMEOUT_MS)
    if not t then return false, 'invalid: timeoutMs must be a positive number' end
    local answer, err = settle(await('awaitMigrations', t + GRACE_MS, t))
    if not answer then return false, err end
    return true
end

--- Core.DB.flush(timeoutMs?) → true | false, err — every entry queued before the call committed;
--- false, 'dropped:<n>' when the queue dropped entries of that range (§56.3.5).
function ns.flush(timeoutMs)
    local t = timeoutArg(timeoutMs, DEFAULT_TIMEOUT_MS)
    if not t then return false, 'invalid: timeoutMs must be a positive number' end
    local answer, err = settle(await('sync', t + GRACE_MS, nil, t))
    if not answer then return false, err end
    local info = answer[2]
    local dropped = type(info) == 'table' and math.tointeger(info.dropped) or 0
    if dropped and dropped > 0 then return false, ('dropped:%d'):format(dropped) end
    return true
end

--- Core.DB.status() → { healthy, pool, queue, migrations } | nil, err.
function ns.status()
    local answer, err = settle(await('status', DEFAULT_TIMEOUT_MS, { timeoutMs = DEFAULT_TIMEOUT_MS }))
    if not answer then return nil, err end
    return answer[2]
end

--- Core.DB.isHealthy() → boolean — a synchronous export call, never yields.
function ns.isHealthy()
    return callSync('isHealthy') == true
end

--------------------------------------------------------------------------------
-- values and errors
--------------------------------------------------------------------------------

ns.NULL = NULL

--- Core.DB.op(name, value, value2?) → a WHERE condition (§56.5.3); the name is checked when sent.
function ns.op(name, value, value2)
    return { __op = name, value = value, value2 = value2 }
end

--- Core.DB.json(value) → JSON text for a `$n::jsonb` raw parameter.
function ns.json(value)
    return json.encode(value)
end

--- Core.DB.errorCode(err) → the SQLSTATE ('23505') or the leading word ('timeout', 'invalid', …).
function ns.errorCode(err)
    if type(err) ~= 'string' then return nil end
    local state = err:match('^([%dA-Z][%dA-Z][%dA-Z][%dA-Z][%dA-Z])%f[^%w_]')
    if state and state:find('%d') then return state end
    return err:match('^([%a_]+)')
end

--------------------------------------------------------------------------------
-- removed names (§56.5.6) and the closed namespace
--------------------------------------------------------------------------------

local function emptyList() return {} end
local function answerNil() return nil end
local function answerFalse() return false end
local function answerZero() return 0 end

-- name -> { replacement, neutral answer (soft mode), its description for the warning }
local REMOVED <const> = {
    get = { 'Core.DB.first', answerNil, 'nil' },
    findOne = { 'Core.DB.first', answerNil, 'nil' },
    create = { 'Core.DB.insert', answerNil, 'nil' },
    find = { 'Core.DB.select', emptyList, '{}' },
    all = { 'Core.DB.select', emptyList, '{}' },
    set = { 'Core.DB.save', answerFalse, 'false' },
    export = { 'pg_dump (DESIGN §56.11)', answerNil, 'nil' },
    import = { 'pg_restore (DESIGN §56.11)', answerZero, '0' },
    isDegraded = { 'Core.DB.isHealthy', answerFalse, 'false' },
    setAdapter = { "the core_pg_url convar (Postgres is required)", answerFalse, 'false' },
    markDegraded = { "Core.on('dbStatus')", answerFalse, 'false' },
}

local warnedRemoved = {}

for name, spec in pairs(REMOVED) do
    local message = ('Core.DB.%s was removed (DESIGN §56): use %s'):format(name, spec[1])
    local neutral, label = spec[2], spec[3]
    ns[name] = function()
        if REMOVED_MODE == 'error' then error(message, 2) end
        if not warnedRemoved[name] then
            warnedRemoved[name] = true
            Core.Log.warn('%s (transition mode: answering %s)', message, label)
        end
        return neutral()
    end
end

-- nothing else exists on Core.DB: an unknown name fails at the access, never through an export
setmetatable(ns, {
    __index = function(_, key)
        if type(key) ~= 'string' then return nil end
        error(('Core.DB.%s does not exist (DESIGN §56.5)'):format(key), 2)
    end,
})
