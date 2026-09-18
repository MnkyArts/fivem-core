#!/usr/bin/env node
// core UI tests — builds the fixture plugins with the REAL toolchain (DESIGN §38.13, §38.15).
//
//   node ui/tests/build-fixtures.mjs [--force] [--quiet] [<name> …]
//
// Every fixture under `ui/tests/fixtures/<res>/ui` is built by Vite's JS API with `coreUI()` — the
// same plugin a real resource uses — so what the runtime suite loads is a genuine plugin bundle:
// content-hashed entry, utilities-only stylesheet, hashed assets, a generated manifest.json.
//
// Output layout (gitignored, `ui/tests/.fixtures-dist/`):
//
//     .fixtures-dist/<variant>/<resource>/ui/dist/…
//
// The VARIANT is the outer folder on purpose: `coreUI()` derives the plugin id from the name of the
// folder that contains `ui`, so `<resource>` has to be the direct parent of `ui` in the output tree
// as well — `.fixtures-dist/fx_alpha/v2/ui/dist` would build a plugin called "v2".
//
// `v1` and `v2` of fx_alpha are the SAME sources with one different `define` constant: different
// code, different content hash, different file name — a "restart with a new build" without editing
// anything, which is what `nui-serve`'s control endpoint then swaps between.

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'vite'
import { coreUI } from '../sdk/vite/index.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
export const FIXTURES_SRC = path.join(HERE, 'fixtures')
export const FIXTURES_DIST = path.join(HERE, '.fixtures-dist')
const SDK_DIR = path.resolve(HERE, '../sdk')

/** name -> what to build. `variants` is a map of variant -> extra `define`s. */
export const FIXTURES = [
  { name: 'fx_alpha', variants: { v1: { __FX_VARIANT__: '"v1"' }, v2: { __FX_VARIANT__: '"v2"' } } },
  { name: 'fx_beta', variants: { v1: {} } },
  { name: 'fx_lazy', variants: { v1: {} }, options: { load: 'lazy' } },
  { name: 'fx_throw_eval', variants: { v1: {} } },
  { name: 'fx_throw_setup', variants: { v1: {} } },
  { name: 'fx_not_plugin', variants: { v1: {} } },
  // Built normally, then rewritten to API 2 in both places the gate reads (§38.12).
  { name: 'fx_api2', variants: { v1: {} }, apiVersion: 2 },
]

/** Where one built fixture's RESOURCE root lives (the folder that holds `ui/dist`). */
export function resourceDir(name, variant = 'v1') {
  return path.join(FIXTURES_DIST, variant, name)
}

export function distDir(name, variant = 'v1') {
  return path.join(resourceDir(name, variant), 'ui/dist')
}

// ---------------------------------------------------------------- staleness

function newestMtime(dir, skip = () => false) {
  let newest = 0
  const walk = (d) => {
    let entries
    try {
      entries = fs.readdirSync(d, { withFileTypes: true })
    } catch {
      return
    }
    for (const e of entries) {
      const full = path.join(d, e.name)
      if (e.name === 'node_modules' || e.name.startsWith('.') || skip(full)) continue
      if (e.isDirectory()) walk(full)
      else {
        const m = fs.statSync(full).mtimeMs
        if (m > newest) newest = m
      }
    }
  }
  walk(dir)
  return newest
}

/** The inputs a fixture build depends on: its own sources, the SDK (facade + Vite plugin), this file. */
function inputStamp() {
  const parts = [
    String(newestMtime(FIXTURES_SRC)),
    String(newestMtime(SDK_DIR)),
    String(fs.statSync(fileURLToPath(import.meta.url)).mtimeMs),
    JSON.stringify(FIXTURES),
  ]
  return crypto.createHash('sha1').update(parts.join('|')).digest('hex').slice(0, 16)
}

const STAMP_FILE = path.join(FIXTURES_DIST, 'stamp.json')

export function fixturesStale() {
  try {
    const stamp = JSON.parse(fs.readFileSync(STAMP_FILE, 'utf8'))
    if (stamp.stamp !== inputStamp()) return true
    for (const f of FIXTURES) {
      for (const variant of Object.keys(f.variants)) {
        if (!fs.existsSync(path.join(distDir(f.name, variant), 'manifest.json'))) return true
      }
    }
    return false
  } catch {
    return true
  }
}

// ---------------------------------------------------------------- the build

/** `coreUI()` hard-codes `outDir: 'dist'` (relative to the plugin's ui/ folder). This `post` plugin
 *  runs its `config` hook after it and points the same build at the gitignored output tree. */
function outDirPlugin(absOut) {
  return {
    name: 'fx-fixture-outdir',
    enforce: 'post',
    config() {
      return { build: { outDir: absOut, emptyOutDir: true } }
    },
  }
}

/** The §38.12 gate fixture: rewrite BOTH places `apiVersion` is read from. */
function rewriteApiVersion(dir, version) {
  const manifestFile = path.join(dir, 'manifest.json')
  const manifest = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
  manifest.apiVersion = version
  fs.writeFileSync(manifestFile, JSON.stringify(manifest, null, 2) + '\n')
  const entry = path.join(dir, manifest.entry)
  const code = fs.readFileSync(entry, 'utf8')
  const next = code.replace(/(__coreUIPlugin\s*:\s*(?:!0|true)\s*,\s*apiVersion\s*:\s*)\d+/, '$1' + version)
  if (next === code) throw new Error(`build-fixtures: could not rewrite apiVersion in ${entry}`)
  fs.writeFileSync(entry, next)
}

export async function buildFixtures(opts = {}) {
  const only = opts.only && opts.only.length ? new Set(opts.only) : null
  const list = FIXTURES.filter((f) => !only || only.has(f.name))
  const built = []
  for (const fixture of list) {
    const uiDir = path.join(FIXTURES_SRC, fixture.name, 'ui')
    for (const [variant, define] of Object.entries(fixture.variants)) {
      const out = distDir(fixture.name, variant)
      await build({
        root: uiDir,
        configFile: false,
        logLevel: opts.quiet === false ? 'info' : 'warn',
        define,
        plugins: [coreUI(fixture.options || {}), outDirPlugin(out)],
      })
      if (fixture.apiVersion) rewriteApiVersion(out, fixture.apiVersion)
      const manifest = JSON.parse(fs.readFileSync(path.join(out, 'manifest.json'), 'utf8'))
      built.push({ name: fixture.name, variant, dir: out, resource: resourceDir(fixture.name, variant), manifest })
    }
  }
  fs.mkdirSync(FIXTURES_DIST, { recursive: true })
  // The tree is generated; nothing in it is ever committed.
  fs.writeFileSync(path.join(FIXTURES_DIST, '.gitignore'), '*\n')
  if (!only) fs.writeFileSync(STAMP_FILE, JSON.stringify({ stamp: inputStamp(), at: new Date().toISOString() }, null, 2) + '\n')
  return built
}

/** What `run-browser-suites.mjs` and `bench.mjs` call: build only when an input changed. */
export async function ensureFixtures(opts = {}) {
  if (!opts.force && !fixturesStale()) return { built: false }
  const built = await buildFixtures(opts)
  return { built: true, fixtures: built }
}

// ---------------------------------------------------------------- CLI

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url))) {
  const args = process.argv.slice(2)
  const force = args.includes('--force')
  const quiet = args.includes('--quiet')
  const only = args.filter((a) => !a.startsWith('--'))
  const started = Date.now()
  if (!force && !only.length && !fixturesStale()) {
    process.stdout.write('build-fixtures: up to date (' + FIXTURES.length + ' fixtures)\n')
  } else {
    const built = await buildFixtures({ only, quiet })
    for (const b of built) {
      process.stdout.write(
        'build-fixtures: ' + b.name + '/' + b.variant + ' -> ' + path.relative(process.cwd(), b.dir)
        + '  entry ' + b.manifest.entry + ', css ' + (b.manifest.css || []).length
        + ', load ' + (b.manifest.load || 'eager') + ', api ' + b.manifest.apiVersion + '\n',
      )
    }
    process.stdout.write('build-fixtures: ' + built.length + ' build(s) in ' + ((Date.now() - started) / 1000).toFixed(1) + ' s\n')
  }
}
