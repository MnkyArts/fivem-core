#!/usr/bin/env node
// fxlint-disable-file: developer tool, plain Node — not resource code. core — load a `/dbexport` file straight into Postgres, without FXServer (DESIGN §33.4).
//
//   CORE_PG_URL="postgres://core:…@127.0.0.1:5432/core" node scripts/pg-import.js data/export-<ts>.json [--replace]
//
// Use it for the one-time switch from KVP while players may be online: `/dbimport` runs inside the
// server, so a session that loaded before the import would be autosaved over the imported rows.
// Loading the rows first and restarting core afterwards makes every session load from Postgres.
// `--replace` empties each collection in the file before inserting; without it rows are upserted.
'use strict'

const fs = require('fs')
const path = require('path')

const file = process.argv[2]
const replace = process.argv.includes('--replace')
const url = process.env.CORE_PG_URL || ''

if (!file || !url) {
  console.error('usage: CORE_PG_URL=postgres://… node scripts/pg-import.js <export.json> [--replace]')
  process.exit(2)
}

// `pg` comes from the npm workspace (resources/node_modules, installed for core/ui), not from the resource.
const { Pool } = require('pg')

const SCHEMA = `CREATE TABLE IF NOT EXISTS core_documents (
  collection text NOT NULL,
  id text NOT NULL,
  data jsonb NOT NULL,
  updated_at bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (collection, id)
)`
const UPSERT = `INSERT INTO core_documents (collection, id, data, updated_at) VALUES ($1, $2, $3::jsonb, $4)
  ON CONFLICT (collection, id) DO UPDATE SET data = EXCLUDED.data, updated_at = EXCLUDED.updated_at`

async function main () {
  const dump = JSON.parse(fs.readFileSync(file, 'utf8'))
  const collections = dump && dump.collections
  if (!collections || typeof collections !== 'object') throw new Error('not a core export (no "collections")')

  const pool = new Pool({ connectionString: url, max: 2, application_name: 'core-pg-import' })
  const client = await pool.connect()
  let written = 0
  try {
    await client.query('BEGIN')
    await client.query(SCHEMA)
    for (const [collection, docs] of Object.entries(collections)) {
      const entries = Array.isArray(docs) ? docs.map((d) => [d && d.id, d]) : Object.entries(docs || {})
      if (replace) await client.query('DELETE FROM core_documents WHERE collection = $1', [collection])
      for (const [id, doc] of entries) {
        if (typeof id !== 'string' || !id || !doc || typeof doc !== 'object') continue
        const stored = Object.assign({}, doc, { id })
        const updatedAt = Number.isFinite(Number(stored.updatedAt)) ? Number(stored.updatedAt) : Math.floor(Date.now() / 1000)
        await client.query(UPSERT, [collection, id, JSON.stringify(stored), updatedAt])
        written++
      }
      console.log(`${collection}: ${entries.length} document(s)${replace ? ' (replaced)' : ''}`)
    }
    await client.query('COMMIT')
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {})
    throw err
  } finally {
    client.release()
    await pool.end()
  }
  console.log(`pg-import: ${written} document(s) written from ${path.basename(file)}`)
}

main().catch((err) => {
  console.error('pg-import failed:', err.message || err)
  process.exit(1)
})
