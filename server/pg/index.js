// core/server/db_pg.js — Node side of the Postgres document store (DESIGN §33.1).
//
// One pg.Pool built from the convar `core_pg_url` (never logged), and two exports for
// server/db_pg.lua: pgQuery(sql, params, cb) and pgStatus(cb). Both refuse every invoking
// resource other than core itself, so no plugin can run SQL through this bridge.
// `cb(err, rows)` is called exactly once, errors are strings, nothing ever throws into the caller.
//
// Plain CommonJS SOURCE: `npm run build:server` in core/ui bundles it (with the `pg` driver) into
// server/db_pg.js, the file the manifest loads. FXServer's Node sandbox cannot read a node_modules
// folder behind the symlinked resource path, and a package.json at the resource root would wake the
// server's yarn builder — so the driver ships inside the bundle, like screenshot-basic's webpack build.

const POOL_OPTIONS = {
    max: 4,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 10000,
    statement_timeout: 10000,
    application_name: 'core',
};

const RESOURCE = GetCurrentResourceName();

// Inside a CommonJS module the bare name `exports` is the module object, not CitizenFX's export
// proxy; take whichever of the two is actually callable.
const registerExport = typeof exports === 'function' ? exports : global.exports;

let Pool = null;
let driverError = null;
try {
    Pool = require('pg').Pool;
} catch (err) {
    driverError = 'the pg driver is missing from the bundle — rebuild server/db_pg.js with: npm run build:server (in core/ui)';
}

let pool = null;
let poolError = null;
let refusedOnce = false;

function log(message) {
    console.log(`[core:db_pg] ${message}`);
}

/** A Postgres/driver error as one short string (never an object, never a stack). */
function describe(err) {
    if (!err) return 'unknown error';
    const message = typeof err.message === 'string' ? err.message : `${err}`;
    return err.code ? `${err.code} ${message}` : message;
}

/** Lazily builds the pool; returns null and sets poolError when it cannot. */
function getPool() {
    if (pool) return pool;
    if (poolError) return null;
    if (!Pool) {
        poolError = driverError;
        return null;
    }
    const url = GetConvar('core_pg_url', '');
    if (!url) {
        poolError = 'core_pg_url is not set';
        return null;
    }
    try {
        pool = new Pool(Object.assign({ connectionString: url }, POOL_OPTIONS));
    } catch (err) {
        poolError = describe(err);
        log(`could not create the pool: ${poolError}`);
        return null;
    }
    // An idle client that dies (server restart, network drop) emits here instead of crashing Node.
    pool.on('error', (err) => {
        log(`idle connection error: ${describe(err)}`);
    });
    log(`pool ready (max ${POOL_OPTIONS.max}, statement_timeout ${POOL_OPTIONS.statement_timeout} ms)`);
    return pool;
}

/** Wraps the Lua callback: fires at most once, on the main thread, with a string error. */
function once(cb) {
    let answered = false;
    return (err, rows) => {
        if (answered) return;
        answered = true;
        if (typeof cb !== 'function') return;
        // Node callbacks run off the main thread; natives (and Lua refs) need setImmediate.
        setImmediate(() => {
            try {
                cb(err ? `${err}` : null, rows);
            } catch (e) {
                log(`the Lua callback threw: ${describe(e)}`);
            }
        });
    };
}

/** Only core itself may use this bridge (DESIGN §33.1). */
function isOwnCall() {
    const invoker = GetInvokingResource();
    if (invoker === RESOURCE) return true;
    if (!refusedOnce) {
        refusedOnce = true;
        log(`refused a call from "${invoker}" — only ${RESOURCE} may query`);
    }
    return false;
}

registerExport('pgQuery', (sql, params, cb) => {
    const reply = once(cb);
    if (!isOwnCall()) return reply('forbidden');
    if (typeof sql !== 'string' || sql === '') return reply('invalid sql');
    const db = getPool();
    if (!db) return reply(poolError || 'no pool');
    // An empty Lua table arrives as an object, not an array; pg only accepts an array of values.
    const values = Array.isArray(params) ? params : [];
    db.query(sql, values).then(
        (result) => reply(null, (result && result.rows) || []),
        (err) => reply(describe(err)),
    );
});

registerExport('pgStatus', (cb) => {
    const reply = once(cb);
    if (!isOwnCall()) return reply('forbidden');
    const db = getPool();
    if (!db) return reply(poolError || 'no pool');
    db.query('SELECT 1').then(
        () => reply(null, { ok: true, total: db.totalCount, idle: db.idleCount, waiting: db.waitingCount }),
        (err) => reply(describe(err)),
    );
});

on('onResourceStop', (name) => {
    if (name !== RESOURCE || !pool) return;
    const closing = pool;
    pool = null;
    closing.end().catch(() => {});
});
