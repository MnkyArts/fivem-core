return function(H)
    local check, eq, newServer, printed, stubs, suite =
        H.check, H.eq, H.newServer, H.printed, H.stubs, H.suite

--- server/db.lua (DESIGN §56.6, §56.11): core's migrations are registered at file scope and applied, and the
--- console command /dbstatus reports health, pool, queue and migrations — never the database URL.
local function suiteDB()
    suite('db')
    stubs.resetServer()
    local env, Core = newServer()
    local DB = Core.DB

    -- Core.DB inside core is the lib (§56.1): no document store behind it any more
    check(type(DB) == 'table' and type(DB.transaction) == 'function' and type(DB.save) == 'function',
        'Core.DB in core\'s VM is the lib')
    check(select(1, pcall(function() return DB.nope end)) == false, 'an unknown Core.DB name raises (closed namespace)')

    -- 1. the migrations server/db.lua registered at file scope are applied (owner core, versions 1 and 2)
    eq(DB.awaitMigrations(), true, 'core\'s migrations settle')
    local applied = H.sql("SELECT version, name FROM core_migrations WHERE owner = 'core' ORDER BY version")
    eq(#applied, 2, 'core_migrations holds two versions for core')
    eq(applied[1] and applied[1].version, 1, 'version 1 ...')
    eq(applied[1] and applied[1].name, 'core_schema', '... is the schema')
    eq(applied[2] and applied[2].version, 2, 'version 2 ...')
    eq(applied[2] and applied[2].name, 'core_legacy_import', '... is the legacy import')
    for _, tbl in ipairs({ 'accounts', 'account_identifiers', 'characters', 'character_money' }) do
        eq(H.scalar('SELECT to_regclass($1) IS NOT NULL AS ok', { tbl }), true, ('the table %s exists'):format(tbl))
    end
    local status = DB.status()
    local own = status and status.migrations and status.migrations.core
    check(type(own) == 'table' and own.version == 2, 'core_db reports core at version 2',
        own and ('%s / %s'):format(tostring(own.version), tostring(own.state)) or 'no entry')

    -- 2. /dbstatus: console only, every section, never the URL
    local cmd = env.__vm.commands.dbstatus
    check(cmd ~= nil, '/dbstatus is registered')
    stubs.clear()
    cmd.fn(7, {}, '/dbstatus')
    eq(printed('/dbstatus'), nil, 'a player gets nothing from /dbstatus')
    stubs.clear()
    cmd.fn(0, {}, '/dbstatus')
    check(printed('/dbstatus: healthy') ~= nil, 'the console sees the health line')
    check(printed('pool:') ~= nil, '... the pool line')
    check(printed('queue:') ~= nil, '... the queue counters')
    check(printed('migrations core: version 2') ~= nil, '... and core\'s migration version',
        tostring(printed('migrations')))
    local leaked = false
    for i = 1, #stubs.printed do
        local line = stubs.printed[i]
        if line:find('postgres://', 1, true) or line:find('core_test:core_test', 1, true) then leaked = true end
    end
    eq(leaked, false, 'no printed line carries the database URL or its credentials')

    -- 3. without core_db: /dbstatus says so, and a failed registration is logged loudly
    local realState = env.GetResourceState
    env.GetResourceState = function(res)
        if res == 'core_db' then return 'stopped' end
        return realState(res)
    end
    stubs.clear()
    cmd.fn(0, {}, '/dbstatus')
    check(printed('/dbstatus: core_db did not answer (unavailable)') ~= nil, '/dbstatus reports an unavailable core_db')
    stubs.clear()
    stubs.loadFile(env, 'server/db.lua')
    check(printed("migrations could not be registered (unavailable)") ~= nil,
        'a migration registration that fails is logged as an error')
    env.GetResourceState = realState
end

    return suiteDB
end
