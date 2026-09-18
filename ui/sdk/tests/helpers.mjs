// Shared plumbing for the @core/ui build tests.
//
// A fixture is copied into a throw-away `<tmp>/<resource>/ui` so the layout the plugin insists on
// (`<resource>/ui`) is real, and `<tmp>/node_modules` is symlinked at the workspace's hoisted
// node_modules so bare imports and `@reference "@core/ui/…"` resolve exactly as in a plugin repo.
// Nothing is ever written inside the repository.

import fs from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { build as viteBuild, createServer } from 'vite'
import { coreUI } from '../vite/index.mjs'

export const TESTS_DIR = path.dirname(fileURLToPath(import.meta.url))
export const FIXTURES = path.join(TESTS_DIR, 'fixtures')
export const SDK_DIR = path.dirname(TESTS_DIR)
export const WORKSPACE = path.resolve(SDK_DIR, '../../..')

const temps = []

/** Copy a fixture resource into a temp dir. `files` overwrites/adds paths relative to the resource. */
export function makePlugin({ from = 'alpha', resource = from, files = {}, remove = [] } = {}) {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'core-ui-test-'))
  temps.push(tmp)
  fs.symlinkSync(path.join(WORKSPACE, 'node_modules'), path.join(tmp, 'node_modules'), 'dir')
  const dir = path.join(tmp, resource)
  fs.cpSync(path.join(FIXTURES, from), dir, { recursive: true })
  for (const rel of remove) fs.rmSync(path.join(dir, rel), { recursive: true, force: true })
  for (const [rel, content] of Object.entries(files)) {
    const full = path.join(dir, rel)
    fs.mkdirSync(path.dirname(full), { recursive: true })
    fs.writeFileSync(full, content)
  }
  return { tmp, dir, uiDir: path.join(dir, 'ui'), resource }
}

export function cleanupAll() {
  for (const tmp of temps.splice(0)) fs.rmSync(tmp, { recursive: true, force: true })
}

function collectingLogger(logs) {
  const push = (level) => (msg) => { logs.push({ level, msg: String(msg) }) }
  return {
    info: push('info'),
    warn: push('warn'),
    warnOnce: push('warn'),
    error: push('error'),
    clearScreen() {},
    hasErrorLogged: () => false,
    hasWarned: false,
  }
}

/** Runs a real Vite build of the fixture. Returns the manifest, every emitted file and the logs. */
export async function buildPlugin(uiDir, options = {}, { mode } = {}) {
  const logs = []
  await viteBuild({
    root: uiDir,
    configFile: false,
    logLevel: 'warn',
    customLogger: collectingLogger(logs),
    mode,
    plugins: [coreUI(options)],
  })
  const dist = path.join(uiDir, 'dist')
  const files = listFiles(dist)
  // Read everything NOW: the next build of the same fixture empties dist (`emptyOutDir`), and a test
  // that compares two builds would otherwise read a file that no longer exists.
  const text = new Map()
  for (const f of files) {
    if (/\.(js|css|json|map|svg|txt|html)$/.test(f)) text.set(f, fs.readFileSync(path.join(dist, f), 'utf8'))
  }
  const manifestRaw = text.get('manifest.json') || null
  const join = (ext) => files.filter((f) => f.endsWith(ext)).map((f) => text.get(f)).join('\n')
  return {
    dist,
    files,
    logs,
    warnings: logs.filter((l) => l.level === 'warn').map((l) => l.msg),
    manifestRaw,
    manifest: manifestRaw ? JSON.parse(manifestRaw) : null,
    read: (rel) => {
      if (!text.has(rel)) throw new Error(`no such output file: ${rel} (have ${files.join(', ')})`)
      return text.get(rel)
    },
    js: () => join('.js'),
    css: () => join('.css'),
  }
}

/** The error a failed build throws, as the plain message (Vite wraps Rollup errors). */
export async function buildError(uiDir, options = {}, buildOptions = {}) {
  try {
    await buildPlugin(uiDir, options, buildOptions)
  } catch (err) {
    return String((err && (err.message || err.msg)) || err)
  }
  throw new Error('the build was expected to fail, but it succeeded')
}

/** A port nothing is listening on right now — `strictPort` in game mode needs a real number. */
export function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer()
    srv.on('error', reject)
    srv.listen(0, '127.0.0.1', () => {
      const { port } = srv.address()
      srv.close(() => resolve(port))
    })
  })
}

/** Starts a real Vite dev server on the fixture and hands back its URL. */
export async function startDevServer(uiDir, { mode, options = {} } = {}) {
  const port = await freePort()
  const server = await createServer({
    root: uiDir,
    configFile: false,
    logLevel: 'silent',
    mode,
    plugins: [coreUI({ ...options, port })],
    // TEST-ONLY. A dev server whose dep optimizer is mid-build never resolves `close()` (esbuild
    // reports "the build was canceled" and the run hangs), and the optimizer has nothing to do with
    // what these tests assert. A real `npm run dev` keeps it, and the browser smoke test exercises
    // the optimized path for real.
    optimizeDeps: { noDiscovery: true, include: [] },
  })
  await server.listen()
  const url = (server.resolvedUrls && server.resolvedUrls.local[0]) || `http://localhost:${port}/`
  return {
    server,
    url: url.replace(/\/$/, ''),
    get: async (p) => {
      const res = await fetch(url.replace(/\/$/, '') + p)
      return { status: res.status, text: await res.text() }
    },
    // `server.close()` leaves the file watchers alive, and `node --test` waits for the event loop:
    // the suite would pass and then hang forever.
    close: async () => {
      await server.close()
      await server.watcher.close()
    },
  }
}

export function listFiles(dir, base = dir, out = []) {
  if (!fs.existsSync(dir)) return out
  for (const name of fs.readdirSync(dir).sort()) {
    const full = path.join(dir, name)
    if (fs.statSync(full).isDirectory()) listFiles(full, base, out)
    else out.push(path.relative(base, full).split(path.sep).join('/'))
  }
  return out
}
