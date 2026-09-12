// core/tests/pg_smoke.js — the one online test of the Postgres bridge (DESIGN §33.4).
//
//     CORE_PG_URL="postgres://core:...@127.0.0.1:5432/core" node tests/pg_smoke.js
//
// Plain Node, no FXServer: the CitizenFX globals server/db_pg.js needs are shimmed here, then the
// bridge itself creates the table, upserts a document, reads it back, updates and deletes it.
// Prints PASS/FAIL per step, exits 1 on the first failure, and only ever touches its own row —
// `core_documents` is left in place. Without CORE_PG_URL it skips instead of failing.

const URL = process.env.CORE_PG_URL || '';

if (!URL) {
    console.log('SKIP  pg_smoke: CORE_PG_URL is not set — export it (the value lives in server.cfg as');
    console.log('      core_pg_url) and re-run, e.g. CORE_PG_URL="postgres://core:...@127.0.0.1:5432/core"');
    process.exit(0);
}

const COLLECTION = 'smoke';
const DOC_ID = `smoke-${process.pid}`;

const SCHEMA = `CREATE TABLE IF NOT EXISTS core_documents (
    collection text   NOT NULL,
    id         text   NOT NULL,
    data       jsonb  NOT NULL,
    updated_at bigint NOT NULL DEFAULT 0,
    PRIMARY KEY (collection, id)
)`;
const SELECT_ALL = 'SELECT id, data::text AS data FROM core_documents WHERE collection = $1';
const UPSERT = 'INSERT INTO core_documents (collection, id, data, updated_at) VALUES ($1, $2, $3::jsonb, $4)'
    + ' ON CONFLICT (collection, id) DO UPDATE SET data = EXCLUDED.data, updated_at = EXCLUDED.updated_at';
const DELETE_ONE = 'DELETE FROM core_documents WHERE collection = $1 AND id = $2';

// --- the FiveM globals server/db_pg.js expects ------------------------------------------------

const registered = {};
const handlers = {};
let invoker = 'core';

global.GetCurrentResourceName = () => 'core';
global.GetInvokingResource = () => invoker;
global.GetConvar = (name, fallback) => (name === 'core_pg_url' ? URL : fallback);
global.exports = (name, fn) => { registered[name] = fn; };
global.on = (name, fn) => { handlers[name] = fn; };

require('../server/db_pg.js');

// --- helpers ----------------------------------------------------------------------------------

let failures = 0;

function check(ok, label, detail) {
    if (ok) {
        console.log(`PASS  ${label}`);
        return true;
    }
    failures += 1;
    console.log(`FAIL  ${label}${detail ? ` — ${detail}` : ''}`);
    return false;
}

/** The export, as a promise: resolves with rows, rejects with the error string. */
function pgQuery(sql, params) {
    return new Promise((resolve, reject) => {
        registered.pgQuery(sql, params, (err, rows) => (err ? reject(err) : resolve(rows)));
    });
}

function pgStatus() {
    return new Promise((resolve, reject) => {
        registered.pgStatus((err, status) => (err ? reject(err) : resolve(status)));
    });
}

function findRow(rows, id) {
    return (rows || []).find((row) => row.id === id);
}

// --- the round trip ---------------------------------------------------------------------------

async function main() {
    check(typeof registered.pgQuery === 'function', 'db_pg.js exports pgQuery');
    check(typeof registered.pgStatus === 'function', 'db_pg.js exports pgStatus');

    invoker = 'some_plugin';
    const refused = await pgQuery('SELECT 1', []).then(() => null, (err) => err);
    check(refused === 'forbidden', 'another resource is refused', `got ${refused}`);
    invoker = 'core';

    const status = await pgStatus();
    check(status && status.ok === true, 'pgStatus reaches the database');

    await pgQuery(SCHEMA, []);
    check(true, 'core_documents exists (CREATE TABLE IF NOT EXISTS)');

    const doc = { id: DOC_ID, name: 'smoke', nested: { n: 1 }, tags: ['a', 'b'] };
    await pgQuery(UPSERT, [COLLECTION, DOC_ID, JSON.stringify(doc), Math.floor(Date.now() / 1000)]);
    let row = findRow(await pgQuery(SELECT_ALL, [COLLECTION]), DOC_ID);
    check(row !== undefined, 'the document comes back from the SELECT');
    const read = row ? JSON.parse(row.data) : {};
    check(read.name === 'smoke', 'the value survived the jsonb round trip', `got ${read.name}`);
    check(read.nested && read.nested.n === 1, 'nested objects survived');
    check(read.tags && read.tags[1] === 'b', 'arrays survived');

    doc.name = 'smoke-updated';
    await pgQuery(UPSERT, [COLLECTION, DOC_ID, JSON.stringify(doc), Math.floor(Date.now() / 1000)]);
    row = findRow(await pgQuery(SELECT_ALL, [COLLECTION]), DOC_ID);
    check(row && JSON.parse(row.data).name === 'smoke-updated', 'the second upsert updated the row');

    await pgQuery(DELETE_ONE, [COLLECTION, DOC_ID]);
    row = findRow(await pgQuery(SELECT_ALL, [COLLECTION]), DOC_ID);
    check(row === undefined, 'the document is gone after the DELETE');

    const bad = await pgQuery('SELECT * FROM core_no_such_table', []).then(() => null, (err) => err);
    check(typeof bad === 'string' && bad.length > 0, 'a broken statement answers with a string error',
        `got ${typeof bad}`);
}

main().then(
    () => {
        if (handlers.onResourceStop) handlers.onResourceStop('core');   // closes the pool
        console.log(failures === 0 ? '\npg_smoke: PASS' : `\npg_smoke: FAIL (${failures})`);
        process.exitCode = failures === 0 ? 0 : 1;
    },
    (err) => {
        if (handlers.onResourceStop) handlers.onResourceStop('core');
        console.log(`FAIL  pg_smoke threw: ${err && err.message ? err.message : err}`);
        console.log('\npg_smoke: FAIL');
        process.exitCode = 1;
    },
);
