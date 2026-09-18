#!/usr/bin/env node
// check-plugins.mjs — the workspace-level half of the UI-platform validation (DESIGN §38.13).
//
//   node core/ui/scripts/check-plugins.mjs [--json] [resources-dir]
//
// `coreUI()` validates one plugin while it builds it; Lua validates one manifest while it loads it
// (client/ui_plugins.lua + shared/ui_manifest.lua, §38.4). This looks at ALL of them at once and
// catches what neither can see on its own: two resources claiming the same plugin id or the same
// page id, a `ui/dist` older than the sources it was built from, a manifest that would be rejected
// in game, and an fxmanifest that will not serve the files.
//
// Errors exit 1; warnings never fail the run (a stale dist during development is normal).
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const CORE_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const args = process.argv.slice(2)
const asJson = args.includes('--json')
const RESOURCES = path.resolve(args.find((a) => !a.startsWith('--')) || path.dirname(CORE_DIR))

// §38.4, kept character-for-character in step with shared/ui_manifest.lua.
const API_VERSION = readApiVersion()
const SAFE_PATH = /^[A-Za-z0-9._\-/]+$/
const PAGE_ID = /^[A-Za-z0-9_-]{1,64}$/
const MAX_CSS = 8
const MAX_PRELOAD = 16
const VFS_MAX = 255

function readApiVersion() {
  const src = fs.readFileSync(path.join(CORE_DIR, 'ui/sdk/src/contract.ts'), 'utf8')
  return Number(/export\s+const\s+API_VERSION\s*=\s*(\d+)/.exec(src)[1])
}

const report = []
const add = (level, resource, message) => report.push({ level, resource, message })

/** `core_ui 'ui/dist'` — Lua comments do not count. */
function readManifestLua(resourceDir) {
  const file = ['fxmanifest.lua', '__resource.lua'].map((f) => path.join(resourceDir, f)).find((f) => fs.existsSync(f))
  if (!file) return null
  const raw = fs.readFileSync(file, 'utf8')
  return raw.replace(/--\[\[[\s\S]*?\]\]/g, '').replace(/^[ \t]*--.*$/gm, '')
}

function newestMtime(dir, skip = () => false) {
  let newest = 0
  const walk = (d) => {
    let entries
    try { entries = fs.readdirSync(d, { withFileTypes: true }) } catch { return }
    for (const e of entries) {
      const full = path.join(d, e.name)
      if (e.name === 'node_modules' || e.name.startsWith('.') || skip(full)) continue
      if (e.isDirectory()) walk(full)
      else newest = Math.max(newest, fs.statSync(full).mtimeMs)
    }
  }
  walk(dir)
  return newest
}

/** The §38.4 validator: the same answers Lua gives, in the same order. */
function validateManifest(resource, dir, m, distDir) {
  const errors = []
  const bad = (msg) => errors.push(msg)
  if (typeof m !== 'object' || m === null || Array.isArray(m)) return ['manifest.json is not an object']
  if (m.id !== resource) bad(`id '${m.id}' must equal the resource name '${resource}'`)
  if (!Number.isInteger(m.apiVersion)) bad(`apiVersion must be an integer, got ${JSON.stringify(m.apiVersion)}`)
  else if (m.apiVersion !== API_VERSION) {
    bad(`built for core UI API ${m.apiVersion}, this core provides ${API_VERSION} — rebuild the plugin with this core's @core/ui or update core`)
  }
  if (typeof m.entry !== 'string' || !SAFE_PATH.test(m.entry) || !/\.m?js$/.test(m.entry)) bad(`entry ${JSON.stringify(m.entry)} is not a .js/.mjs path`)
  if (!Array.isArray(m.css) || m.css.length > MAX_CSS) bad(`css must be an array of at most ${MAX_CSS} paths`)
  else for (const f of m.css) if (typeof f !== 'string' || !SAFE_PATH.test(f) || !f.endsWith('.css')) bad(`css entry ${JSON.stringify(f)} is not a .css path`)
  if (typeof m.build !== 'string' || m.build.length > 64) bad('build must be a string of at most 64 chars')
  if (m.load !== undefined && m.load !== 'eager' && m.load !== 'lazy') bad(`load must be 'eager' or 'lazy', got ${JSON.stringify(m.load)}`)
  if (m.preload !== undefined) {
    if (!Array.isArray(m.preload) || m.preload.length > MAX_PRELOAD) bad(`preload must be an array of at most ${MAX_PRELOAD} paths`)
    else for (const f of m.preload) if (typeof f !== 'string' || !SAFE_PATH.test(f) || !/\.m?js$/.test(f)) bad(`preload entry ${JSON.stringify(f)} is not a .js path`)
  }
  if (m.pages !== undefined) {
    if (!Array.isArray(m.pages)) bad('pages must be an array')
    else for (const id of m.pages) if (typeof id !== 'string' || !PAGE_ID.test(id)) bad(`page id ${JSON.stringify(id)} is not a plain id`)
  }
  const files = [m.entry, ...(Array.isArray(m.css) ? m.css : []), ...(Array.isArray(m.preload) ? m.preload : [])]
  for (const f of files) {
    if (typeof f !== 'string') continue
    if (f.includes('..')) bad(`'${f}' contains '..'`)
    const vfs = `resources:/${resource}/${dir}/${f}`
    if (vfs.length >= VFS_MAX) bad(`'${f}': the vfs path is ${vfs.length} chars, FiveM cuts at ${VFS_MAX}`)
    if (SAFE_PATH.test(String(f)) && !fs.existsSync(path.join(distDir, f))) bad(`'${f}' is in the manifest but not on disk`)
  }
  return errors
}

function checkFxmanifest(resource, lua, dir) {
  const strings = [...lua.matchAll(/['"]([^'"\n]+)['"]/g)].map((m) => m[1])
  const head = dir.split('/')[0] + '/'
  if (!strings.some((s) => s === dir || s.startsWith(dir + '/') || (s.startsWith(head) && s.includes('*')))) {
    add('ERROR', resource, `no \`files\` entry covers ${dir}/ — the CEF cannot fetch what the resource does not pack (add \`files { '${dir}/**' }\`)`)
  }
  for (const m of lua.matchAll(/client_scripts?\s*[({]([\s\S]*?)[)}]/g)) {
    for (const s of [...m[1].matchAll(/['"]([^'"\n]+)['"]/g)].map((x) => x[1])) {
      if (!s.includes('*')) continue
      // `**` crosses folders, `*` stops inside one. Splitting on `**` FIRST means the two
      // passes cannot see each other's output, so no placeholder character is needed - a raw
      // one in the source would make this file binary to git, grep and `file`.
      const escapeRe = (t) => t.replace(/[.+^${}()|[\]\\]/g, '\\$&')
      const rx = s.split('**').map((c) => c.split('*').map(escapeRe).join('[^/]*')).join('.*')
      const re = new RegExp('^' + rx + '$')
      if (re.test(`${dir}/plugin.abc123.js`)) add('WARN', resource, `the client_script glob '${s}' can match inside ${dir}/ — FiveM serves those files as garbage`)
    }
  }
}

function scan() {
  const plugins = []
  const dirs = fs.readdirSync(RESOURCES, { withFileTypes: true })
    .filter((e) => (e.isDirectory() || e.isSymbolicLink()) && e.name !== 'node_modules' && !e.name.startsWith('.'))
    .map((e) => e.name)
    .sort()

  for (const resource of dirs) {
    const resourceDir = path.join(RESOURCES, resource)
    const lua = readManifestLua(resourceDir)
    if (!lua) continue
    const key = /(^|\s)core_ui\s*[('"]\s*['"]?([^'")\s]+)/.exec(lua)
    if (!key) continue                              // no opt-in: core never probes this resource
    const dir = key[2]
    const entry = { id: resource, dir, pages: [], ok: false, build: null }
    plugins.push(entry)

    if (!SAFE_PATH.test(dir) || dir.includes('..') || dir.startsWith('/') || dir.includes('://')) {
      add('ERROR', resource, `core_ui '${dir}' is not a relative folder inside the resource`)
      continue
    }
    const distDir = path.join(resourceDir, dir)
    const manifestFile = path.join(distDir, 'manifest.json')
    if (!fs.existsSync(manifestFile)) {
      add('ERROR', resource, `core_ui '${dir}' but ${dir}/manifest.json does not exist — run \`npm run build\` in ${resource}/ui`)
      continue
    }
    let m
    try { m = JSON.parse(fs.readFileSync(manifestFile, 'utf8')) } catch (err) {
      add('ERROR', resource, `${dir}/manifest.json is not valid JSON: ${err.message}`)
      continue
    }
    const errors = validateManifest(resource, dir, m, distDir)
    for (const e of errors) add('ERROR', resource, e)
    checkFxmanifest(resource, lua, dir)
    entry.pages = Array.isArray(m.pages) ? m.pages : []
    entry.build = typeof m.build === 'string' ? m.build : null
    entry.ok = errors.length === 0

    const srcDir = path.join(resourceDir, 'ui/src')
    if (fs.existsSync(srcDir)) {
      const src = newestMtime(srcDir)
      const dist = newestMtime(distDir)
      if (src > dist) {
        add('WARN', resource, `${dir}/ is older than ui/src (${new Date(dist).toISOString().slice(0, 19)} < ${new Date(src).toISOString().slice(0, 19)}) — rebuild before committing`)
      }
    }
  }

  // Cross-resource: one plugin per resource makes ids unique by construction, but a page id is
  // claimed by whoever registers it first in Lua — two resources claiming one is a real conflict.
  const byPage = new Map()
  for (const p of plugins) {
    for (const id of p.pages) {
      if (!byPage.has(id)) byPage.set(id, [])
      byPage.get(id).push(p.id)
    }
  }
  for (const [id, owners] of byPage) {
    if (owners.length > 1) add('ERROR', owners[0], `page id '${id}' is claimed by ${owners.join(' and ')} — page ids are global (§6.10)`)
  }
  const seen = new Set()
  for (const p of plugins) {
    if (seen.has(p.id)) add('ERROR', p.id, 'two manifests claim this plugin id')
    seen.add(p.id)
  }
  return plugins
}

const plugins = scan()
const errors = report.filter((r) => r.level === 'ERROR')
const warnings = report.filter((r) => r.level === 'WARN')

if (asJson) {
  console.log(JSON.stringify({ ok: errors.length === 0, resources: RESOURCES, apiVersion: API_VERSION, plugins, report }, null, 2))
} else {
  for (const r of report) console.log(`${r.level}${r.level === 'WARN' ? '  ' : ' '}${r.resource}: ${r.message}`)
  const names = plugins.map((p) => p.id).join(', ') || 'none'
  console.log(`check-plugins: ${plugins.length} UI plugin(s) [${names}], ${errors.length} error(s), ${warnings.length} warning(s)`)
}
process.exit(errors.length ? 1 : 0)
