--[[
    core/tests/db_tests.lua — the Core.DB lib (lib/db/server.lua) over the Postgres test bridge
    (DESIGN §56.5, §56.10.3 second bullet).

        scripts/test-db.sh up            (once: the throwaway database core_test)
        lua5.4 tests/db_tests.lua        (from the resource directory, or from tests/)

    Server VMs are built the way the stubs build them — import.lua (+ shared/config.lua for core) and
    NOTHING else, so Core.DB is the lib, never the old server/db.lua document store. The fixture resource
    `tests/fixtures/dbfixture` (mapped with bridge.mapResource) brings its own migration. Every call is
    synchronous through the bridge, so the checks run in the main chunk; the not-in-coroutine and timeout
    checks swap in their own transport. Exit code 1 when anything fails.
]]

local here = (arg and arg[0] or 'tests/db_tests.lua'):match('^(.*)[/\\][^/\\]*$') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads only the checked-in test stubs
local stubs = dofile(here .. '/stubs.lua')
local bridge = stubs.bridge

local passed, failed = 0, 0
local function check(value, message)
    if value then
        passed = passed + 1
    else
        failed = failed + 1
        print('FAIL: ' .. message)
    end
end
local function eq(actual, expected, message)
    check(actual == expected, ('%s (expected %s, got %s)'):format(message, tostring(expected), tostring(actual)))
end
--- Counts printed lines containing `needle`.
local function printedCount(needle)
    local n = 0
    for i = 1, #stubs.printed do
        if stubs.printed[i]:find(needle, 1, true) then n = n + 1 end
    end
    return n
end

local root = stubs.root
if root:sub(1, 1) ~= '/' then root = (os.getenv('PWD') or '.') .. '/' .. root end

--- A server VM: import.lua (+ core's config for core) and nothing else — Core.DB is the lib.
local function newVM(resourceName)
    local env = stubs.newEnv('server', resourceName)
    stubs.loadImport(env)
    if resourceName == 'core' then stubs.loadFile(env, 'shared/config.lua') end
    return env, env.Core
end

stubs.newWorld()
stubs.clear()
stubs.tick(1000)
stubs.resetServer()

local coreEnv, CoreC = newVM('core')
local fxEnv, Fx = newVM('dbfixture')
local DB = Fx.DB

--------------------------------------------------------------------------------
-- the namespace: a server-only lib, closed, never proxied (§56.1)
--------------------------------------------------------------------------------
check(type(DB) == 'table' and type(DB.query) == 'function', 'Core.DB is the lib in a plugin server VM')
check(type(CoreC.DB) == 'table' and CoreC.DB.transaction ~= nil, 'and in core\'s own server VM')
local ok, err
local rows
ok, err = pcall(function() return DB.nope end)
check(not ok and tostring(err):find('Core.DB.nope does not exist', 1, true) ~= nil, 'an unknown name raises in the lib')
eq(stubs.exports.core, nil, 'nothing was forwarded to core\'s call export')
local client = stubs.newEnv('client', 'dbfixture')
stubs.loadImport(client)
eq(client.Core.DB, nil, 'Core.DB is absent in a plugin client VM')
local coreClient = stubs.newEnv('client', 'core')
stubs.loadImport(coreClient)
eq(coreClient.Core.DB, nil, 'and in core\'s client VM')
eq(rawget(client.Core, 'DB'), nil, 'no empty proxy is cached on the client')

--------------------------------------------------------------------------------
-- migrations (§56.4): core's own files, then the fixture resource's
--------------------------------------------------------------------------------
bridge.mapResource('dbfixture', root .. '/tests/fixtures/dbfixture')   -- starts the bridge (and resets)
check(bridge.running(), 'the bridge started on first use')
eq(CoreC.DB.migrate({ 'sql/0001_core_schema.sql', 'sql/0002_core_legacy_import.sql' }), true, 'core registers its migrations')
eq(CoreC.DB.awaitMigrations(), true, 'core\'s migrations are applied')
local FIXTURE_MIGRATIONS = {
    'sql/0001_fixture.sql',
    { version = 2, name = 'name_index', sql = 'CREATE INDEX IF NOT EXISTS dbfixture_things_name ON dbfixture_things (name)' },
}
eq(DB.migrate(FIXTURE_MIGRATIONS), true, 'the fixture registers a file and an inline migration')
eq(DB.awaitMigrations(), true, 'the fixture migrations are applied')
local applied = bridge.sql("SELECT version, name FROM core_migrations WHERE owner = 'dbfixture' ORDER BY version")
check(applied and #applied == 2 and applied[1].version == 1 and applied[1].name == 'fixture'
    and applied[2].name == 'name_index', 'core_migrations holds both fixture versions under the invoking resource')
ok, err = DB.migrate('sql/0001_fixture.sql')
check(ok == false and DB.errorCode(err) == 'invalid', 'migrate refuses a non-list')
ok, err = DB.migrate({ { version = 0, name = 'zero', sql = 'SELECT 1' } })
check(ok == false and DB.errorCode(err) == 'invalid', 'core_db refuses version 0 synchronously: ' .. tostring(err))
ok, err = DB.awaitMigrations()
check(ok == false and DB.errorCode(err) == 'migrations_failed', 'a refused registration fails the barrier (§56.2.3)')
eq(DB.migrate(FIXTURE_MIGRATIONS), true, 'registering again clears it')
eq(DB.awaitMigrations(), true, 'and nothing is re-applied')

local badEnv, Bad = newVM('dbfixture_bad')
eq(Bad.DB.migrate({ { version = 1, name = 'broken', sql = 'CREATE TABLE dbfixture_bad_x (' } }), true,
    'a broken migration registers (non-blocking)')
ok, err = Bad.DB.awaitMigrations()
check(ok == false and Bad.DB.errorCode(err) == 'migrations_failed', 'awaitMigrations reports the failure: ' .. tostring(err))
rows, err = Bad.DB.query('SELECT 1 AS x')
check(rows == nil and Bad.DB.errorCode(err) == 'migrations_failed', 'the failed barrier refuses that resource\'s calls')
rows, err = DB.query('SELECT 1 AS x')
check(rows and rows[1].x == 1, 'other resources are not held by it')
local st = DB.status()
check(type(st) == 'table' and st.healthy == true and type(st.pool) == 'table' and type(st.queue) == 'table',
    'status answers healthy, pool and queue')
check(st and type(st.migrations) == 'table' and st.migrations.dbfixture ~= nil and st.migrations.core ~= nil,
    'status lists the migration owners')
eq(DB.isHealthy(), true, 'isHealthy is a synchronous true')

--------------------------------------------------------------------------------
-- marshalling (§56.2.4): NULL, holes, refused values, vectors, JSON, arrays
--------------------------------------------------------------------------------
do
    eq(DB.scalar('SELECT $1::text IS NULL AS n', { DB.NULL }), true, 'Core.DB.NULL is SQL NULL in raw params')
    local row = DB.single('SELECT $1::int AS a, $2::int AS b, $3::int AS c', { 1, nil, 3 })
    check(row and row.a == 1 and row.b == nil and row.c == 3, 'a nil hole in params is padded with NULL')
    row = DB.single('SELECT $1::int AS a, $2::int AS b', { 7, n = 2 })
    check(row and row.a == 7 and row.b == nil, 'params.n pads trailing holes')
    row = DB.single('SELECT $1::int AS a, $2::text AS b', table.pack(5, nil))
    check(row and row.a == 5 and row.b == nil, 'table.pack params keep their trailing nil')
    local params = { 1, nil, 3 }
    DB.query('SELECT $1::int AS a, $2::int AS b, $3::int AS c', params)
    check(params[2] == nil and params.n == nil, 'the caller\'s params table is never padded in place')
    local r, e = DB.query('SELECT $1::text AS x', { function() end })
    check(r == nil and DB.errorCode(e) == 'invalid', 'a function param is refused: ' .. tostring(e))
    r, e = DB.query('SELECT $1::jsonb AS x', { { nested = { fn = print } } })
    check(r == nil and DB.errorCode(e) == 'invalid', 'a nested function is refused')
    r, e = DB.query('SELECT $1::text AS x', { io.stdout })
    check(r == nil and DB.errorCode(e) == 'invalid', 'a userdata param is refused')
    r, e = DB.query('SELECT 1 AS x', { a = 1 })
    check(r == nil and DB.errorCode(e) == 'invalid', 'named params are refused (positional $n only)')
    local cyclic = {}
    cyclic.self = cyclic
    r, e = DB.query('SELECT $1::jsonb AS x', { cyclic })
    check(r == nil and DB.errorCode(e) == 'invalid', 'a cyclic table is refused')
    eq(DB.scalar("SELECT ($1::jsonb ->> 'y')::float8 AS y", { stubs.vector3(1.5, 2.5, 3.5) }), 2.5,
        'a vector crosses as { x, y, z }')
    eq(DB.scalar("SELECT $1::jsonb ->> 'k' AS k", { { k = 'v' } }), 'v', 'a map param crosses as JSON text')
    eq(DB.scalar('SELECT $1::int[] @> ARRAY[2] AS has', { { 1, 2, 3 } }), true, 'a sequence param is a Postgres array')
    eq(DB.json({ a = 1 }), '{"a":1}', 'Core.DB.json encodes a value')
    eq(DB.scalar('SELECT jsonb_typeof($1::jsonb) AS t', { DB.json({}) }), 'array', 'Core.DB.json({}) is []')
    eq(DB.scalar('SELECT $1::jsonb ->> 1 AS s', { DB.json({ 'a', 'b' }) }), 'b', 'a JSON param with an explicit cast')
    local op = DB.op('between', 1, 5)
    check(op.__op == 'between' and op.value == 1 and op.value2 == 5, 'Core.DB.op builds { __op, value, value2 }')
    check(not pcall(function() DB.NULL.x = 1 end), 'Core.DB.NULL is read-only')
    eq(tostring(DB.NULL), 'Core.DB.NULL', 'Core.DB.NULL prints its name')
end

--------------------------------------------------------------------------------
-- awaited raw SQL (§56.5.2): query single scalar execute batch nextId, types back, errors
--------------------------------------------------------------------------------
do
    local rows = DB.query('SELECT 1 AS x WHERE false')
    check(type(rows) == 'table' and #rows == 0, 'an empty read is an empty table, not nil')
    local row, e = DB.single('SELECT 1 AS x WHERE false')
    check(row == nil and e == nil, 'single answers (nil, nil) when there is no row')
    eq(DB.scalar('SELECT 42 AS v'), 42, 'scalar answers the first column')
    eq(math.type(DB.scalar('SELECT 42 AS v')), 'integer', 'an int4 arrives as a Lua integer')
    local none
    none, e = DB.scalar('SELECT 1 AS v WHERE false')
    check(none == nil and e == nil, 'scalar answers (nil, nil) without a row')
    eq(DB.execute("INSERT INTO dbfixture_things (id, name) VALUES ('a', 'Alpha'), ('b', 'Beta')"), 2,
        'execute answers the rowCount')
    rows, e = DB.query('SELECT * FROM dbfixture_nope')
    check(rows == nil and DB.errorCode(e) == '42P01', 'a SQL error is nil, "<SQLSTATE> <message>": ' .. tostring(e))
    rows, e = DB.query('')
    check(rows == nil and DB.errorCode(e) == 'invalid', 'an empty sql is refused')
    rows, e = DB.query('SELECT 1 AS x', nil, 'fast')
    check(rows == nil and DB.errorCode(e) == 'invalid', 'opts must be a table')
    rows, e = DB.query('SELECT 1 AS x', nil, { timeout = -5 })
    check(rows == nil and DB.errorCode(e) == 'invalid', 'opts.timeout must be positive')
    rows = DB.query('SELECT 1 AS x', nil, { sync = true, timeout = 5000 })
    check(rows and rows[1].x == 1, 'opts { sync, timeout } are accepted (read-your-writes)')

    DB.execute([[INSERT INTO dbfixture_things (id, name, qty, price, big, tags, data, seen_at, day, flag)
        VALUES ('t', 'Typed', 3, 12.5, 9007199254740000, ARRAY['x', 'y'], '{"k": [1, 2]}',
                to_timestamp(1700000000.75), '2026-09-27', false)]])
    row = DB.single('SELECT * FROM dbfixture_things WHERE id = $1', { 't' })
    check(row and row.qty == 3 and math.type(row.qty) == 'integer', 'int4 → integer')
    check(row and row.price == 12.5, 'numeric → number')
    check(row and row.big == 9007199254740000, 'int8 → number')
    check(row and type(row.tags) == 'table' and row.tags[1] == 'x' and row.tags[2] == 'y', 'text[] → sequence')
    check(row and type(row.data) == 'table' and row.data.k[2] == 2, 'jsonb → parsed value')
    check(row and row.seen_at == 1700000000 and math.type(row.seen_at) == 'integer', 'timestamptz → integer Unix seconds (floor)')
    eq(row and row.day, '2026-09-27', 'date → YYYY-MM-DD')
    eq(row and row.flag, false, 'bool false → false')
    check(row and row.note == nil and rawget(row, 'note') == nil, 'SQL NULL → absent key')

    local results = DB.batch({
        { 'UPDATE dbfixture_things SET qty = qty + 1 WHERE id = $1', { 'a' } },
        { sql = 'SELECT id FROM dbfixture_things WHERE id = ANY($1) ORDER BY id', params = { { 'a', 'b' } } },
    }, { rows = true })
    check(results and results[1].rowCount == 1 and results[2].rows and #results[2].rows == 2,
        'batch answers results[i] = { rowCount, rows } with opts.rows')
    results, e = DB.batch({ { "UPDATE dbfixture_things SET qty = 100 WHERE id = 'a'" }, { 'SELECT * FROM dbfixture_nope' } })
    check(results == nil and DB.errorCode(e) == '42P01', 'a failing statement fails the batch')
    eq(DB.scalar("SELECT qty FROM dbfixture_things WHERE id = 'a'"), 1, 'and the whole batch rolled back')
    results = DB.batch({ { 'SELECT 1 AS x' } })
    check(results and results[1] and results[1].rows == nil, 'rows are left out unless opts.rows')
    results, e = DB.batch({})
    check(results == nil and DB.errorCode(e) == 'invalid', 'an empty batch is refused')

    local id1, id2 = DB.nextId('dbfixture:things'), DB.nextId('dbfixture:things')
    check(id1 == 1 and id2 == 2 and math.type(id2) == 'integer', 'nextId counts 1, 2 (core_counters)')
    local bad
    bad, e = DB.nextId('')
    check(bad == nil and DB.errorCode(e) == 'invalid', 'nextId refuses an empty name')
end

--------------------------------------------------------------------------------
-- scalar = the FIRST column by field order (review L6), outside and inside a transaction
--------------------------------------------------------------------------------
do
    eq(DB.scalar('SELECT 1 AS b, 2 AS a'), 1, 'scalar answers the first column by field order')
    local none, e = DB.scalar('SELECT NULL::int AS a, 5 AS b')
    check(none == nil and e == nil, 'a NULL first column is nil, never the next one')
    local list = DB.scalar([[SELECT '[{"k": 1}, {"k": 2}]'::jsonb AS j]])
    check(type(list) == 'table' and list[2] and list[2].k == 2, 'a jsonb list of objects is a value, never mistaken for rows')
    local okT, a, b = DB.transaction(function(tx)
        return tx.scalar('SELECT 3 AS b, 4 AS a'), tx:scalar('SELECT NULL::int AS a, 6 AS b')
    end)
    check(okT == true and a == 3, 'tx.scalar answers the first column by field order')
    eq(b, nil, 'tx.scalar: a NULL first column is nil')
end

--------------------------------------------------------------------------------
-- table helpers (§56.5.3): catalog-typed values, WHERE ops, refused identifiers, empty-where refusal
--------------------------------------------------------------------------------
do
    local T = 'dbfixture_things'
    local row = DB.insert(T, { id = 'h1', name = 'Helper', qty = 5, tags = { 'a', 'b' }, data = { deep = { 1, 2 } },
        seen_at = 1700000000, day = '2026-01-02', note = DB.NULL, flag = true })
    check(row and row.id == 'h1' and row.qty == 5 and row.tags[2] == 'b' and row.data.deep[2] == 2,
        'insert answers the row (RETURNING *)')
    check(row and row.seen_at == 1700000000 and row.day == '2026-01-02' and row.flag == true and row.note == nil,
        'values convert by column type (Unix seconds, date, bool, NULL)')
    check(row and type(row.created_at) == 'number', 'a column default comes back')
    row = DB.insert(T, { id = 'h2', name = 'Two' }, { returning = { 'id' } })
    check(row and row.id == 'h2' and row.name == nil, 'opts.returning = { cols } narrows the answer')
    eq(DB.insert(T, { id = 'h3', name = 'Three', qty = 7 }, { returning = false }), true, 'returning = false answers true')
    local e
    row, e = DB.insert(T, { id = 'h1', name = 'Dup' })
    check(row == nil and DB.errorCode(e) == '23505', 'a duplicate key is nil, 23505: ' .. tostring(e))
    eq(DB.insertMany(T, { { id = 'm1', name = 'M1', qty = 1 }, { id = 'm2', name = 'M2', qty = 2 }, { id = 'm3', name = 'M3' } }),
        3, 'insertMany answers the count')

    local function ids(rows)
        if type(rows) ~= 'table' then return tostring(rows) end
        local out = {}
        for i = 1, #rows do out[i] = rows[i].id end
        return table.concat(out, ',')
    end
    eq(ids(DB.select(T, { qty = 5 })), 'h1', 'where col = value')
    eq(ids(DB.select(T, { id = { 'm1', 'm3' } }, { orderBy = 'id DESC' })), 'm3,m1', 'where col = { list } (ANY) + orderBy DESC')
    eq(ids(DB.select(T, { note = DB.NULL, id = DB.op('like', 'h%') }, { orderBy = 'id' })), 'h1,h2,h3', 'where col = NULL (IS NULL)')
    eq(ids(DB.select(T, { qty = DB.op('>', 1), id = DB.op('like', 'm%') })), 'm2', 'op > and like')
    eq(ids(DB.select(T, { qty = DB.op('between', 1, 2), id = DB.op('like', 'm%') }, { orderBy = 'id' })), 'm1,m2', 'op between')
    eq(ids(DB.select(T, { id = DB.op('in', { 'm1', 'h2' }) }, { orderBy = 'id' })), 'h2,m1', 'op in')
    eq(ids(DB.select(T, { id = DB.op('not_in', { 'm1' }), name = DB.op('ilike', 'm%') }, { orderBy = 'id' })), 'm2,m3',
        'op not_in and ilike')
    eq(ids(DB.select(T, { tags = DB.op('contains', { 'a' }) })), 'h1', 'op contains (@>)')
    eq(ids(DB.select(T, { tags = DB.op('overlaps', { 'b', 'z' }) })), 'h1', 'op overlaps (&&)')
    eq(ids(DB.select(T, { tags = DB.op('not_null'), id = DB.op('like', 'h%') })), 'h1', 'op not_null')
    eq(ids(DB.select(T, { id = DB.op('like', 'm%') }, { orderBy = 'id', limit = 2, offset = 1 })), 'm2,m3', 'limit + offset')
    local picked = DB.select(T, { id = 'h1' }, { columns = { 'id', 'qty' } })
    check(picked and picked[1] and picked[1].qty == 5 and picked[1].name == nil, 'opts.columns selects only those')
    local empty = DB.select(T, { id = 'nope' })
    check(type(empty) == 'table' and #empty == 0, 'select without a match is an empty table')
    eq((DB.first(T, { id = DB.op('like', 'm%') }, { orderBy = 'id DESC' }) or {}).id, 'm3', 'first answers one row')
    local none
    none, e = DB.first(T, { id = 'zzz' })
    check(none == nil and e == nil, 'first answers (nil, nil) when there is none')
    eq(DB.count(T, { id = DB.op('like', 'm%') }), 3, 'count with where')
    eq(DB.count(T), DB.scalar('SELECT count(*) AS n FROM dbfixture_things'), 'count without where counts the table')

    eq(DB.update(T, { qty = 10, note = 'upd' }, { id = DB.op('like', 'm%') }), 3, 'update answers the rowCount')
    eq(DB.scalar("SELECT note FROM dbfixture_things WHERE id = 'm2'"), 'upd', 'the update landed')
    eq(DB.update(T, { note = DB.NULL }, { id = 'm1' }), 1, 'update to NULL')
    eq(DB.scalar("SELECT note IS NULL AS n FROM dbfixture_things WHERE id = 'm1'"), true, 'the column is NULL again')
    local n
    n, e = DB.update(T, { qty = 4242 }, {})
    check(n == nil and DB.errorCode(e) == 'invalid', 'update refuses an empty where')
    n, e = DB.update(T, { qty = 4242 })
    check(n == nil and DB.errorCode(e) == 'invalid', 'update refuses a missing where')
    n, e = DB.update(T, {}, { id = 'm1' })
    check(n == nil and DB.errorCode(e) == 'invalid', 'update refuses an empty set')
    n, e = DB.delete(T, {})
    check(n == nil and DB.errorCode(e) == 'invalid', 'delete refuses an empty where')
    n, e = DB.delete(T)
    check(n == nil and DB.errorCode(e) == 'invalid', 'delete refuses a missing where')
    eq(DB.count(T, { qty = 4242 }), 0, 'no refused call touched a row')
    eq(DB.delete(T, { id = 'm3' }), 1, 'delete answers the rowCount')

    row = DB.upsert('dbfixture_pairs', { a = 1, b = 2, v = 'one' }, { 'a', 'b' })
    eq(row and row.v, 'one', 'upsert inserts')
    row = DB.upsert('dbfixture_pairs', { a = 1, b = 2, v = 'two' }, { 'a', 'b' })
    eq(row and row.v, 'two', 'upsert updates on conflict')
    row = DB.upsert(T, { id = 'h1', name = 'Renamed', qty = 99 }, 'id', { update = { 'name' } })
    check(row and row.name == 'Renamed' and row.qty == 5, 'opts.update overwrites only those columns')
    eq(DB.upsert('dbfixture_pairs', { a = 1, b = 3 }, { 'a', 'b' }, { returning = false }), true, 'upsert returning = false')
    row = DB.upsert('dbfixture_pairs', { a = 1, b = 3 }, { 'a', 'b' })
    check(row and row.a == 1 and row.b == 3, 'a DO NOTHING upsert still answers the existing row')
    row, e = DB.upsert(T, { id = 'x', name = 'X' })
    check(row == nil and DB.errorCode(e) == 'invalid', 'upsert needs a conflict target')

    local rows
    rows, e = DB.select('dbfixture_things"; DROP TABLE dbfixture_things; --')
    check(rows == nil and DB.errorCode(e) == 'invalid', 'a hostile table name is refused')
    rows, e = DB.select('dbfixture_nope')
    check(rows == nil and DB.errorCode(e) == 'invalid', 'an unknown table is refused: ' .. tostring(e))
    rows, e = DB.select(T, { ['id" = id OR 1 = 1 --'] = 1 })
    check(rows == nil and DB.errorCode(e) == 'invalid', 'an unknown where column is refused')
    rows, e = DB.select(T, nil, { orderBy = 'id; DROP TABLE dbfixture_things' })
    check(rows == nil and DB.errorCode(e) == 'invalid', 'a hostile orderBy is refused')
    rows, e = DB.select(T, nil, { columns = { 'id', 'nope' } })
    check(rows == nil and DB.errorCode(e) == 'invalid', 'an unknown column in opts.columns is refused')
    row, e = DB.insert(T, { id = 'x', name = 'X', nope = 1 })
    check(row == nil and DB.errorCode(e) == 'invalid', 'an unknown value column is refused')
    rows, e = DB.select(T, { qty = DB.op('~', 1) })
    check(rows == nil and DB.errorCode(e) == 'invalid', 'an unknown op is refused')
    row, e = DB.insert(T, 'x')
    check(row == nil and DB.errorCode(e) == 'invalid', 'values must be a table')
    rows, e = DB.select(T, { [1] = 'x' })
    check(rows == nil and DB.errorCode(e) == 'invalid', 'where keys must be column names')
    check((DB.count(T) or 0) > 0, 'the fixture table is still there')
end

--------------------------------------------------------------------------------
-- transactions (§56.5.2): commit, rollback by false / throw / failed statement, deadline, deferred FKs
--------------------------------------------------------------------------------
do
    local T = 'dbfixture_things'
    local function count(id) return DB.count(T, { id = id }) end
    local ok2, res, extra = DB.transaction(function(tx)
        tx.insert(T, { id = 'tx1', name = 'One' })
        tx:insert(T, { id = 'tx2', name = 'Two' })          -- colon calls work as well
        return 'committed', tx.scalar('SELECT count(*) AS n FROM dbfixture_things WHERE id LIKE $1', { 'tx%' })
    end)
    check(ok2 == true and res == 'committed' and extra == 2, 'transaction commits and answers true, fn\'s results')
    eq(DB.count(T, { id = DB.op('like', 'tx%') }), 2, 'both rows are visible after the commit')
    local e
    ok2, e = DB.transaction(function(tx)
        tx.insert(T, { id = 'tx3', name = 'Three' })
        return false, 'changed_mind'
    end)
    check(ok2 == false and e == 'changed_mind', 'fn returning false, reason rolls back with that reason')
    eq(count('tx3'), 0, 'nothing of it committed')
    ok2, e = DB.transaction(function(tx) tx.insert(T, { id = 'tx4', name = 'Four' }) return false end)
    check(ok2 == false and e == 'rollback' and count('tx4') == 0, 'a bare false answers rollback')
    ok2, e = DB.transaction(function(tx)
        tx.insert(T, { id = 'tx5', name = 'Five' })
        error('boom')
    end)
    check(ok2 == false and DB.errorCode(e) == 'error' and tostring(e):find('boom', 1, true) ~= nil,
        'a throwing fn rolls back with error: <msg>')
    eq(count('tx5'), 0, 'nothing of the throwing fn committed')
    check(printedCount('DB.transaction:') >= 1, 'the throw is logged')
    local later
    ok2, e = DB.transaction(function(tx)
        tx.insert(T, { id = 'tx6', name = 'Six' })
        tx.insert(T, { id = 'tx1', name = 'Dup' })          -- 23505 aborts the transaction
        later = table.pack(tx.query('SELECT 1 AS x'))
        return 'ignored'
    end)
    check(ok2 == false and DB.errorCode(e) == '23505', 'a failed statement + a normal return rolls back: ' .. tostring(e))
    check(later and later[1] == nil and DB.errorCode(later[2]) == 'tx_aborted', 'later statements answer tx_aborted')
    eq(count('tx6'), 0, 'nothing of the aborted transaction committed')
    ok2, e = DB.transaction(function(tx)
        tx.insert(T, { id = 'tx8', name = 'Eight' })
        tx.select('dbfixture_nope')
        return true
    end)
    check(ok2 == false and DB.errorCode(e) == 'invalid' and count('tx8') == 0, 'a refused helper inside fn rolls back too')
    local kept
    DB.transaction(function(tx) kept = tx return true end)
    local r
    r, e = kept.query('SELECT 1 AS x')
    check(r == nil and e == 'tx_unknown', 'a tx used after its end answers tx_unknown')
    ok2 = DB.transaction(function(tx)
        tx.insert('dbfixture_log', { thing_id = 'tx7', msg = 'child first' }, { returning = false })
        tx.insert(T, { id = 'tx7', name = 'Parent later' }, { returning = false })
        return true
    end)
    eq(ok2, true, 'a DEFERRABLE INITIALLY DEFERRED FK is checked at COMMIT')
    ok2, e = DB.transaction(function(tx)
        tx.insert('dbfixture_log', { thing_id = 'orphan', msg = 'x' }, { returning = false })
        return true
    end)
    check(ok2 == false and DB.errorCode(e) == '23503', 'a violated deferred FK fails the COMMIT: ' .. tostring(e))
    ok2, e = DB.transaction(function(tx)
        -- fxlint-disable-next-line S006 -- offline harness: real time must pass for core_db's deadline
        os.execute('sleep 0.2')
        tx.query('SELECT 1 AS x')
        return true
    end, { timeout = 50 })
    check(ok2 == false and DB.errorCode(e) == 'tx_expired', 'the tx deadline rolls back: ' .. tostring(e))
    ok2, e = DB.transaction('nope')
    check(ok2 == false and DB.errorCode(e) == 'invalid', 'transaction needs a function')
end

--------------------------------------------------------------------------------
-- stream (§56.5.2): a cursor in a transaction, batches, early stop, one batch per tick in a thread
--------------------------------------------------------------------------------
do
    local list = {}
    for i = 1, 1200 do list[i] = { id = ('s%04d'):format(i), name = 'S', qty = i } end
    eq(DB.insertMany('dbfixture_things', list), 1200, 'insertMany seeds 1200 rows in one call')
    local sizes = {}
    local total = DB.stream('SELECT id, qty FROM dbfixture_things WHERE id LIKE $1 ORDER BY id;', { 's%' },
        function(rows) sizes[#sizes + 1] = #rows end)
    eq(total, 1200, 'stream answers the total row count')
    eq(table.concat(sizes, ','), '500,500,200', 'fn sees batches of the default 500')
    sizes = {}
    total = DB.stream('SELECT id FROM dbfixture_things WHERE id LIKE $1', { 's%' },
        function(rows) sizes[#sizes + 1] = #rows return false end, { batch = 100 })
    check(total == 100 and #sizes == 1, 'fn returning false stops after that batch')
    local e
    total, e = DB.stream('SELECT * FROM dbfixture_nope', nil, function() end)
    check(total == nil and DB.errorCode(e) == '42P01', 'a bad cursor query is nil, err')
    total, e = DB.stream('SELECT 1 AS x', nil, function() error('stream boom') end)
    check(total == nil and DB.errorCode(e) == 'error', 'a throwing fn ends the stream with an error')
    total, e = DB.stream('SELECT 1 AS x', nil, nil)
    check(total == nil and DB.errorCode(e) == 'invalid', 'stream needs a function')
    total, e = DB.stream('SELECT 1 AS x', nil, function() end, { batch = 0 })
    check(total == nil and DB.errorCode(e) == 'invalid', 'opts.batch must be 1..10000')
    check(DB.save('dbfixture_things', { id = 'zq0001', name = 'Q', qty = 7 }) == true, 'a queued row before a sync stream')
    local synced = {}
    total = DB.stream('SELECT id FROM dbfixture_things WHERE id = $1', { 'zq0001' },
        function(rows) synced[#synced + 1] = rows[1] and rows[1].id end, { sync = true })
    check(total == 1 and synced[1] == 'zq0001', 'opts.sync: the stream reads its own queued writes')
    local seen, done = 0, nil
    fxEnv.CreateThread(function()
        done = DB.stream('SELECT id FROM dbfixture_things WHERE id LIKE $1', { 's%' },
            function() seen = seen + 1 end, { batch = 400 })
    end)
    check(seen == 1 and done == nil, 'in a thread the first batch runs at once, then the stream waits a tick')
    stubs.tick(0)
    check(seen == 3 and done == 1200, 'the scheduler runs the remaining batches')
end

--------------------------------------------------------------------------------
-- queued writes (§56.5.4, §56.3): visible after the call (test mode flushes), coalescing, flush, drops
--------------------------------------------------------------------------------
do
    local T = 'dbfixture_things'
    eq(DB.save(T, { id = 'q1', name = 'Queued', qty = 1 }), true, 'save answers true')
    eq((DB.first(T, { id = 'q1' }) or {}).name, 'Queued', 'a queued save is visible after the call')
    eq(DB.patch(T, 'q1', { qty = 5, note = 'patched' }), true, 'patch answers true')
    local row = DB.first(T, { id = 'q1' })
    check(row and row.qty == 5 and row.name == 'Queued' and row.note == 'patched', 'patch changes only its columns')
    eq(DB.save(T, { id = 'q1', name = 'Saved again' }), true, 'a second save of the row')
    row = DB.first(T, { id = 'q1' })
    check(row and row.name == 'Saved again' and row.qty == 5, 'save overwrites only the columns it carries')
    eq(DB.patch('dbfixture_pairs', { a = 1, b = 2 }, { v = 'three' }), true, 'patch by a composite key')
    eq(DB.scalar('SELECT v FROM dbfixture_pairs WHERE a = 1 AND b = 2'), 'three', 'the composite patch landed')
    eq(DB.remove(T, 'q1'), true, 'remove answers true')
    eq(DB.count(T, { id = 'q1' }), 0, 'the removed row is gone')
    eq(DB.patch(T, 'q1', { qty = 9 }), true, 'a patch of an absent row is accepted')
    eq(DB.count(T, { id = 'q1' }), 0, 'and is a no-op')
    eq(DB.append('dbfixture_log', { thing_id = 'h1', msg = 'appended' }), true, 'append answers true')
    eq(DB.count('dbfixture_log', { msg = 'appended' }), 1, 'the appended row is there (identity id)')
    eq(DB.enqueue('UPDATE dbfixture_things SET note = $1 WHERE id = $2', { 'raw', 'h1' }), true, 'enqueue raw sql')
    eq(DB.scalar("SELECT note FROM dbfixture_things WHERE id = 'h1'"), 'raw', 'the raw statement ran')

    local ok2, e = DB.save(T, { name = 'no pk' })
    check(ok2 == false and DB.errorCode(e) == 'invalid', 'save without the primary key is refused: ' .. tostring(e))
    ok2, e = DB.save('dbfixture_nope', { id = 'x' })
    check(ok2 == false and DB.errorCode(e) == 'invalid', 'save to an unknown table is refused')
    ok2, e = DB.save(T, {})
    check(ok2 == false and DB.errorCode(e) == 'invalid', 'an empty row is refused')
    ok2, e = DB.patch(T, nil, { qty = 1 })
    check(ok2 == false and DB.errorCode(e) == 'invalid', 'patch needs a key')
    ok2, e = DB.patch(T, 'h1', {})
    check(ok2 == false and DB.errorCode(e) == 'invalid', 'patch needs changes')
    ok2, e = DB.enqueue('')
    check(ok2 == false and DB.errorCode(e) == 'invalid', 'enqueue needs sql')
    ok2, e = DB.save(T, { id = 'q2', name = 'N', data = { f = print } })
    check(ok2 == false and DB.errorCode(e) == 'invalid', 'a function inside a queued row is refused')
    ok2, e = DB.append('Bad Name', { msg = 'x' })
    check(ok2 == false and DB.errorCode(e) == 'invalid', 'a hostile table name is refused')
    eq(DB.count(T, { id = 'q2' }), 0, 'refused entries queue nothing')

    -- one enqueue call carrying several entries = what one Lua slice queues: coalescing shows in the rows
    local res = fxEnv.exports.core_db:enqueue({
        { t = 'save', table = T, row = { id = 'c1', name = 'first', qty = 1 } },
        { t = 'patch', table = T, key = 'c1', changes = { qty = 2 } },
        { t = 'sql', sql = "INSERT INTO dbfixture_log (msg) VALUES ('keyed-1')", params = {}, key = 'k' },
        { t = 'sql', sql = "INSERT INTO dbfixture_log (msg) VALUES ('keyed-2')", params = {}, key = 'k' },
        { t = 'save', table = T, row = { id = 'c2', name = 'gone' } },
        { t = 'remove', table = T, key = 'c2' },
    })
    check(type(res) == 'table' and res.seq ~= nil, 'enqueue answers { seq }')
    row = DB.first(T, { id = 'c1' })
    check(row and row.name == 'first' and row.qty == 2, 'patch after a pending save merged into it')
    eq(DB.count('dbfixture_log', { msg = { 'keyed-1', 'keyed-2' } }), 1, 'two keyed sql entries coalesce to one')
    eq(DB.scalar("SELECT msg FROM dbfixture_log WHERE msg LIKE 'keyed-%'"), 'keyed-2', 'the newer keyed statement won')
    eq(DB.count(T, { id = 'c2' }), 0, 'save then remove leaves no row')
    eq(DB.flush(), true, 'flush answers true when nothing was dropped')

    local failures = {}
    Fx.on('dbWriteFailed', function(owner, kind, tbl, err2)
        failures[#failures + 1] = { owner = owner, kind = kind, tbl = tbl, err = err2 }
    end)
    eq(DB.save(T, { id = 'bad1', name = 'Bad', qty = 'not a number' }), true, 'a save that only Postgres refuses is queued')
    check(failures[1] and failures[1].owner == 'dbfixture' and failures[1].kind == 'save' and failures[1].tbl == T,
        'the dropped entry reaches Core.on(\'dbWriteFailed\') in the VM')
    eq(DB.count(T, { id = 'bad1' }), 0, 'the poisoned entry was dropped')
    local okF, errF = DB.flush()
    check(okF == false and errF == 'dropped:1' and DB.errorCode(errF) == 'dropped', 'flush reports it: false, dropped:1')
    eq(DB.flush(), true, 'a later flush with nothing new dropped answers true')
end

--------------------------------------------------------------------------------
-- errorCode (§56.2.5)
--------------------------------------------------------------------------------
do
    eq(DB.errorCode('23505 duplicate key value violates unique constraint "x"'), '23505', 'errorCode: SQLSTATE')
    eq(DB.errorCode('57P01 terminating connection'), '57P01', 'errorCode: a SQLSTATE with a letter')
    eq(DB.errorCode('XX000 internal error'), 'XX000', 'errorCode: class XX')
    eq(DB.errorCode('timeout'), 'timeout', 'errorCode: a bare word')
    eq(DB.errorCode('invalid: unknown table x'), 'invalid', 'errorCode: invalid')
    eq(DB.errorCode('migrations_failed: core v1 core_schema: boom'), 'migrations_failed', 'errorCode: migrations_failed')
    eq(DB.errorCode('dropped:3'), 'dropped', 'errorCode: dropped:<n>')
    eq(DB.errorCode('tx_aborted'), 'tx_aborted', 'errorCode: tx_aborted')
    eq(DB.errorCode('error: x.lua:1: boom'), 'error', 'errorCode: a thrown transaction fn')
    eq(DB.errorCode(nil), nil, 'errorCode(nil) is nil')
end

--------------------------------------------------------------------------------
-- removed names (§56.5.6): error mode (the default) raises; the transition's soft mode answered neutral values
--------------------------------------------------------------------------------
do
    local okE, msg = pcall(DB.get, 'things', 'x')
    check(not okE and tostring(msg):find('Core.DB.get was removed (DESIGN §56): use Core.DB.first', 1, true) ~= nil,
        'error mode (default) raises the §56.5.6 message')
    for _, name in ipairs({ 'findOne', 'create', 'all', 'find', 'set', 'export', 'import', 'isDegraded',
                            'setAdapter', 'markDegraded' }) do
        local ok = pcall(DB[name], 'things', {})
        check(not ok, 'removed name raises: ' .. name)
    end
    okE, msg = pcall(DB.setAdapter, {})
    check(not okE and tostring(msg):find('Core.DB.setAdapter was removed (DESIGN §56)', 1, true) ~= nil,
        'error mode raises for the internal names too')

    local code = stubs.readFile(stubs.root .. '/lib/db/server.lua')
    local patched, hits = code:gsub("REMOVED_MODE <const> = 'error'", "REMOVED_MODE <const> = 'soft'")
    eq(hits, 1, 'the lib has exactly one REMOVED_MODE constant')
    local soft = {}
    -- fxlint-disable-next-line S006 -- offline harness compiles core's own lib file with the switch flipped
    load(patched, '@core/lib/db/server.lua', 't', fxEnv)(soft)
    eq(soft.get('things', 'x'), nil, 'soft: get → nil')
    local a1 = soft.all('things')
    check(type(a1) == 'table' and next(a1) == nil, 'soft: all → {}')
    eq(soft.set('things', 'x', {}), false, 'soft: set → false')
    eq(soft.isDegraded('things'), false, 'soft: isDegraded → false')
end

--------------------------------------------------------------------------------
-- outside a coroutine (§56.5.1): nothing is sent, logged once per call site; queued calls never need one
--------------------------------------------------------------------------------
do
    local transport = rawget(fxEnv.exports, 'core_db')
    rawset(transport, 'synchronous', false)          -- as in FiveM: an answer only ever arrives later
    local before = bridge.sql("SELECT count(*) AS n FROM dbfixture_log WHERE msg = 'main chunk'")[1].n
    local answers = {}
    for i = 1, 2 do answers[i] = table.pack(DB.execute("INSERT INTO dbfixture_log (msg) VALUES ('main chunk')")) end
    check(answers[1][1] == nil and answers[1][2] == 'not_in_coroutine' and answers[2][2] == 'not_in_coroutine',
        'an awaited call outside a coroutine answers nil, not_in_coroutine (no throw)')
    eq(bridge.sql("SELECT count(*) AS n FROM dbfixture_log WHERE msg = 'main chunk'")[1].n, before, 'and sends nothing')
    eq(printedCount('outside a coroutine'), 1, 'logged once for that call site')
    local sameSite = printedCount('db_tests.lua:')
    DB.query('SELECT 1 AS x')
    eq(printedCount('outside a coroutine'), 2, 'another call site logs again')
    check(printedCount('db_tests.lua:') > sameSite, 'the log names the caller\'s file and line')
    local ok2, e = DB.transaction(function() return true end)
    check(ok2 == false and e == 'not_in_coroutine', 'transaction outside a coroutine')
    ok2, e = DB.flush()
    check(ok2 == false and e == 'not_in_coroutine', 'flush outside a coroutine')
    eq(DB.save('dbfixture_things', { id = 'nc1', name = 'queued at file scope' }), true, 'queued calls need no coroutine')
    eq(DB.isHealthy(), true, 'isHealthy needs no coroutine')
    local inThread
    fxEnv.CreateThread(function() inThread = DB.scalar('SELECT 7 AS v') end)
    eq(inThread, 7, 'the same call inside a thread runs')
    rawset(transport, 'synchronous', true)
    eq(DB.count('dbfixture_things', { id = 'nc1' }), 1, 'the queued save landed')
end

--------------------------------------------------------------------------------
-- core_db not started (§56.5.1): unavailable, logged at most once per 10 s
--------------------------------------------------------------------------------
do
    local logged = printedCount('core_db is not available')
    stubs.resourceStates.core_db = 'stopped'
    local r, e = DB.query('SELECT 1 AS x')
    check(r == nil and e == 'unavailable', 'awaited → nil, unavailable')
    local ok2
    ok2, e = DB.save('dbfixture_things', { id = 'u1', name = 'U' })
    check(ok2 == false and e == 'unavailable', 'queued → false, unavailable')
    ok2, e = DB.transaction(function() return true end)
    check(ok2 == false and e == 'unavailable', 'transaction → false, unavailable')
    ok2, e = DB.migrate({ 'sql/0001_fixture.sql' })
    check(ok2 == false and e == 'unavailable', 'migrate → false, unavailable')
    ok2, e = DB.flush()
    check(ok2 == false and e == 'unavailable', 'flush → false, unavailable')
    eq(DB.isHealthy(), false, 'isHealthy → false')
    eq(DB.status(), nil, 'status → nil')
    eq(printedCount('core_db is not available') - logged, 1, 'logged once for the burst')
    stubs.tick(10001)
    DB.query('SELECT 1 AS x')
    eq(printedCount('core_db is not available') - logged, 2, 'and again after 10 s')
    stubs.resourceStates.core_db = nil
    eq(DB.scalar('SELECT 1 AS x'), 1, 'calls work again once core_db is started')
    eq(DB.count('dbfixture_things', { id = 'u1' }), 0, 'nothing was queued while it was down')
end

--------------------------------------------------------------------------------
-- the await path with a transport that answers later (FiveM's shape): resume, Lua deadline, late answers
--------------------------------------------------------------------------------
do
    local real = rawget(fxEnv.exports, 'core_db')
    local pending = {}
    local fake = {}
    function fake.query(_, _sql, _params, _opts, cb) pending[#pending + 1] = cb end
    rawset(fxEnv.exports, 'core_db', fake)
    local got
    fxEnv.CreateThread(function() got = table.pack(DB.query('SELECT 1 AS x')) end)
    eq(got, nil, 'the thread parks until core_db answers')
    pending[1](nil, { { x = 1 } }, 1)
    check(got and got[1] and got[1][1].x == 1, 'the later answer resumes it with the rows')
    got = nil
    fxEnv.CreateThread(function() got = table.pack(DB.query('SELECT 1 AS x', nil, { timeout = 50 })) end)
    stubs.tick(49)
    eq(got, nil, 'no answer at 49 ms')
    stubs.tick(1)
    check(got and got[1] == nil and got[2] == 'timeout', 'opts.timeout is the Lua deadline: nil, timeout')
    pending[2](nil, { { x = 2 } }, 1)
    check(got[2] == 'timeout', 'a late answer after the deadline is ignored')
    got = nil
    fxEnv.CreateThread(function() got = table.pack(DB.query('SELECT 1 AS x')) end)
    stubs.tick(29999)
    eq(got, nil, 'the default deadline has not passed at 29999 ms')
    stubs.tick(1)
    check(got and got[2] == 'timeout', 'the default deadline is 30 s')
    got = nil
    fxEnv.CreateThread(function() got = table.pack(DB.query('SELECT 1 AS x')) end)
    pending[4]('42P01 relation "x" does not exist')
    check(got and got[1] == nil and DB.errorCode(got[2]) == '42P01', 'an error answer arrives as nil, err')
    function fake.query() error('No such export query in resource core_db') end
    got = nil
    fxEnv.CreateThread(function() got = table.pack(DB.query('SELECT 1 AS x')) end)
    check(got and got[1] == nil and got[2] == 'unavailable', 'an export that throws answers unavailable')
    rawset(fxEnv.exports, 'core_db', real)
end

--------------------------------------------------------------------------------
-- deadlines: the Lua timer is cleared on an answer (L9); every awaited export gets timeoutMs (M4)
--------------------------------------------------------------------------------
do
    local real = rawget(fxEnv.exports, 'core_db')
    local pending, cleared = {}, 0
    local realClear = fxEnv.ClearTimeout
    fxEnv.ClearTimeout = function(timer)
        cleared = cleared + 1
        return realClear(timer)
    end
    rawset(fxEnv.exports, 'core_db', { query = function(_, _sql, _params, _opts, cb) pending[#pending + 1] = cb end })
    local got
    fxEnv.CreateThread(function() got = table.pack(DB.query('SELECT 1 AS x')) end)
    pending[1](nil, { { x = 1 } }, 1)
    check(got and got[1] and cleared == 1, 'an answer clears its deadline timer')
    fxEnv.CreateThread(function() got = table.pack(DB.query('SELECT 1 AS x', nil, { timeout = 20 })) end)
    stubs.tick(20)
    check(got and got[2] == 'timeout' and cleared == 1, 'a deadline that fired is not cleared again')
    fxEnv.ClearTimeout = realClear

    local seen = {}
    local answers = { txBegin = { nil, 7 }, sync = { nil, { dropped = 0 } }, nextId = { nil, 1 } }
    rawset(fxEnv.exports, 'core_db', setmetatable({ synchronous = true }, { __index = function(t, name)
        local fn = function(_, ...)
            local args = table.pack(...)
            seen[name] = args
            local cb = args[args.n]
            if type(cb) == 'function' then cb(table.unpack(answers[name] or { nil, {}, 0 }, 1, 3)) end
        end
        rawset(t, name, fn)
        return fn
    end }))
    local function opt(name, index, key)
        local args = seen[name]
        local value = args and args[index]
        if key then return type(value) == 'table' and value[key] or nil end
        return value
    end
    DB.query('SELECT 1 AS x', nil, { timeout = 1234 })
    eq(opt('query', 3, 'timeoutMs'), 1234, 'query: opts.timeout reaches core_db as timeoutMs')
    DB.query('SELECT 1 AS x')
    eq(opt('query', 3, 'timeoutMs'), 30000, 'query: the default deadline is sent as well')
    DB.select('dbfixture_things', nil, { timeout = 2000 })
    eq(opt('crud', 3, 'timeoutMs'), 2000, 'crud: args.timeoutMs')
    DB.batch({ { 'SELECT 1 AS x' } })
    eq(opt('batch', 2, 'timeoutMs'), 30000, 'batch: opts.timeoutMs')
    DB.nextId('dbfixture:deadline')
    eq(opt('nextId', 2, 'timeoutMs'), 30000, 'nextId: opts.timeoutMs')
    DB.status()
    eq(opt('status', 1, 'timeoutMs'), 30000, 'status: opts.timeoutMs')
    DB.flush(4000)
    eq(opt('sync', 2), 4000, 'flush: sync(seq, timeoutMs)')
    DB.awaitMigrations(5000)
    eq(opt('awaitMigrations', 1), 5000, 'awaitMigrations(timeoutMs)')
    DB.transaction(function(tx) tx.query('SELECT 1 AS x', nil, { timeout = 900 }) return true end, { timeout = 3000 })
    eq(opt('txBegin', 1, 'timeoutMs'), 3000, 'txBegin: the transaction deadline')
    eq(opt('txQuery', 4, 'timeoutMs'), 900, 'txQuery: opts.timeoutMs')
    DB.transaction(function() return true end)
    eq(opt('txBegin', 1, 'timeoutMs'), 10000, 'txBegin: the default transaction deadline is sent explicitly')
    rawset(fxEnv.exports, 'core_db', real)
end

--------------------------------------------------------------------------------
-- bridge.fail and core_db's events: the error reaches the caller, events reach the live VMs only
--------------------------------------------------------------------------------
do
    local statuses = {}
    Fx.on('dbStatus', function(healthy, reason) statuses[#statuses + 1] = { healthy = healthy, reason = reason } end)
    bridge.fail('"dbfixture_p.-rs"', '08006 connection failure')   -- a Lua pattern (`.-`), not a RegExp
    local r, e = DB.select('dbfixture_pairs')
    check(r == nil and DB.errorCode(e) == '08006', 'bridge.fail makes matching statements answer its error: ' .. tostring(e))
    eq(DB.scalar('SELECT 5 AS v'), 5, 'statements that do not match run normally')
    bridge.unfail()
    r = DB.select('dbfixture_pairs')
    check(type(r) == 'table' and #r >= 1, 'bridge.unfail restores the table')
    check(statuses[1] and statuses[1].healthy == false, 'a connection-class error flips health: dbStatus(false)')
    check(statuses[2] and statuses[2].healthy == true, 'the next success flips it back: dbStatus(true)')

    local oldFailures = {}
    Fx.on('dbWriteFailed', function() oldFailures[#oldFailures + 1] = true end)
    stubs.newWorld()                                  -- fxEnv is no longer part of the test world
    local _, Fresh = newVM('dbfixture')
    local fresh = {}
    Fresh.on('dbWriteFailed', function(owner) fresh[#fresh + 1] = owner end)
    eq(Fresh.DB.save('dbfixture_things', { id = 'bad2', name = 'Bad', qty = 'nope' }), true, 'a poisoned save from a new VM')
    eq(#fresh, 1, 'the event reaches the VM of the current world')
    eq(#oldFailures, 0, 'and not a VM of a previous world')
end

stubs.resetServer()
eq(bridge.sql('SELECT count(*) AS n FROM dbfixture_things')[1].n, 0, 'stubs.resetServer() empties the database')
eq(bridge.sql("SELECT count(*) AS n FROM core_migrations WHERE owner = 'dbfixture'")[1].n, 2, 'migrations stay applied')

print(('db: %d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
