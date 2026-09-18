#!/usr/bin/env node
// core UI benchmarks (DESIGN §38.15) — writes `ui/tests/BENCH.md`.
//
//   node ui/tests/bench.mjs [--baseline <dir with index.html + assets/>] [--session <name>] [--keep]
//
// What is compared: the SHELL core ships today (`core/html`) against the last MONOLITHIC build —
// the one that compiled every plugin page into core's own bundle. The baseline is not in git (it is
// a build of deleted sources), so it is imported once with `--baseline <dir>` into the work folder
// (`resources/node_modules/.cache/core-ui-bench`, see WORK below) and re-used from there.
//
// Method, so the numbers can be checked:
//   * both shells are served by `nui-serve` (FiveM's headers, no validators, one origin each) and
//     each one's index.html gets ONE inline script that timestamps the `ui_ready` post — that is the
//     startup number: navigation start -> the shell told Lua it is alive.
//   * every timing is the MEDIAN of >= 10 runs, measured in the page with `performance.now()`;
//     long tasks come from a `PerformanceObserver`.
//   * bytes are measured on disk (raw + gzip level 9), because that is what a player downloads.
//   * everything else (plugin load, page open, patches, feeds, idle) runs in `bench-page.js`
//     against a REAL plugin bundle fetched over HTTP from a second origin.

import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { startServers } from './nui-serve.mjs'
import { ensureFixtures, resourceDir } from './build-fixtures.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const CORE = path.resolve(HERE, '../..')

const args = process.argv.slice(2)
const argOf = (n, d) => { const i = args.indexOf(n); return i === -1 ? d : args[i + 1] }

// The two SHELL copies (the current one with the probe, and the imported monolith) live OUTSIDE the
// resource on purpose: `fxlint <resource>` lints every stylesheet it finds inside one, and a copy of
// core's own built `app.css` would then report the banned filter property against the very rule the
// original is exempt from (it is the manifest's `html/` build output). `node_modules/.cache` is
// outside every resource, survives between runs and is ignored by everything.
const WORK = path.resolve(argOf('--work', path.join(CORE, '../node_modules/.cache/core-ui-bench')))
const BENCH_DIR = path.join(WORK, 'shells')
const BASELINE_HTML = path.join(WORK, 'baseline/html')
const SESSION = argOf('--session', 'uiplat-bench')
const PORTS = { core: 8831, core_baseline: 8832, fx_alpha: 8833, fx_beta: 8834 }

// The one thing injected into a measured page: a timestamp for the `ui_ready` post. Both shells log
// it in dev mode (`post()` -> console.log), which is the only hook that exists before the module
// runs — the `window.__core` shim is installed by the bundle itself and would overwrite anything.
const PROBE = `<script>window.__T0=performance.now();(function(){var L=console.log;console.log=function(a,b){`
  + `if(a==='[core:ui] post'&&b==='ui_ready'&&!window.__READY__)window.__READY__=performance.now();return L.apply(console,arguments)}})()</script>`

function run(cmd, argv, input) {
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, { cwd: CORE, stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (d) => { stdout += d })
    child.stderr.on('data', (d) => { stderr += d })
    child.on('error', (err) => resolve({ code: 127, stdout, stderr: String(err) }))
    child.on('close', (code) => resolve({ code, stdout, stderr }))
    if (input !== undefined) child.stdin.write(input)
    child.stdin.end()
  })
}
const browser = (argv, input) => run('agent-browser', ['--session', SESSION].concat(argv), input)
/** agent-browser prints an eval result JSON-quoted. */
const unquote = (s) => {
  const t = s.trim()
  try { return JSON.parse(t) } catch { return t }
}

const median = (list) => {
  const a = list.slice().sort((x, y) => x - y)
  return a.length ? (a.length % 2 ? a[(a.length - 1) / 2] : (a[a.length / 2 - 1] + a[a.length / 2]) / 2) : NaN
}
const ms = (n) => (Number.isFinite(n) ? (n < 1 ? n.toFixed(3) : n.toFixed(1)) + ' ms' : 'n/a')
const kb = (n) => (n / 1024).toFixed(1) + ' kB'
const gzip = (buf) => zlib.gzipSync(buf, { level: 9 }).length

function copyShell(from, to) {
  fs.rmSync(to, { recursive: true, force: true })
  fs.cpSync(from, to, { recursive: true })
  const index = path.join(to, 'index.html')
  const html = fs.readFileSync(index, 'utf8')
  if (html.indexOf('__READY__') === -1) fs.writeFileSync(index, html.replace('</head>', PROBE + '\n  </head>'))
}

/** Raw + gzip bytes of what the CEF downloads, split by kind. */
function weigh(dir) {
  const out = { js: 0, jsGz: 0, css: 0, cssGz: 0, font: 0, files: [] }
  for (const name of fs.readdirSync(path.join(dir, 'assets'))) {
    const file = path.join(dir, 'assets', name)
    const buf = fs.readFileSync(file)
    if (name.endsWith('.js')) { out.js += buf.length; out.jsGz += gzip(buf) }
    else if (name.endsWith('.css')) { out.css += buf.length; out.cssGz += gzip(buf) }
    else out.font += buf.length
    if (name.endsWith('.js') || name.endsWith('.css')) out.files.push({ name, bytes: buf.length, gz: gzip(buf) })
  }
  out.files.sort((a, b) => b.bytes - a.bytes)
  return out
}

async function startupOnce(url) {
  await browser(['open', url])
  await browser(['wait', '250'])
  const res = await browser(['eval', 'window.__READY__ || null'])
  const value = Number(unquote(res.stdout))
  return Number.isFinite(value) && value > 0 ? value : null
}

/**
 * N reloads of each shell, ALTERNATING between them: a browser that has just started is slower than
 * one that has been running for a minute, and measuring one shell's ten runs before the other's
 * would put that drift entirely into the comparison. One warm-up run per shell is discarded.
 */
async function startupPair(urls, runs) {
  const samples = {}
  for (const key of Object.keys(urls)) {
    samples[key] = []
    await startupOnce(urls[key])
  }
  for (let i = 0; i < runs; i++) {
    for (const key of Object.keys(urls)) {
      const value = await startupOnce(urls[key])
      if (value !== null) samples[key].push(value)
    }
  }
  return samples
}

async function main() {
  const importBaseline = argOf('--baseline', null)
  if (importBaseline) {
    fs.rmSync(BASELINE_HTML, { recursive: true, force: true })
    fs.mkdirSync(path.dirname(BASELINE_HTML), { recursive: true })
    fs.cpSync(path.resolve(importBaseline), BASELINE_HTML, { recursive: true })
  }
  const hasBaseline = fs.existsSync(path.join(BASELINE_HTML, 'assets'))
  await ensureFixtures({})

  copyShell(path.join(CORE, 'html'), path.join(BENCH_DIR, 'new/html'))
  if (hasBaseline) copyShell(BASELINE_HTML, path.join(BENCH_DIR, 'baseline/html'))

  const farm = await startServers({
    control: 'core',
    resources: [
      { name: 'core', port: PORTS.core, dir: path.join(BENCH_DIR, 'new'), files: ['html/**'] },
      { name: 'core_baseline', port: PORTS.core_baseline, dir: path.join(BENCH_DIR, 'baseline'), files: ['html/**'] },
      { name: 'fx_alpha', port: PORTS.fx_alpha, dir: resourceDir('fx_alpha', 'v1'), files: ['ui/dist/**'] },
      { name: 'fx_beta', port: PORTS.fx_beta, dir: resourceDir('fx_beta', 'v1'), files: ['ui/dist/**'] },
    ],
  })

  const data = { at: new Date().toISOString(), node: process.version }
  try {
    const url = 'http://127.0.0.1:' + PORTS.core + '/html/index.html'
    const urls = { now: url }
    if (hasBaseline) urls.baseline = 'http://127.0.0.1:' + PORTS.core_baseline + '/html/index.html'
    const startups = await startupPair(urls, 11)
    data.newStartup = startups.now
    if (hasBaseline) data.baseStartup = startups.baseline

    await browser(['open', url])
    await browser(['wait', '400'])
    const res = await browser(['eval', '--stdin'], fs.readFileSync(path.join(HERE, 'bench-page.js'), 'utf8'))
    const raw = unquote(res.stdout)
    try {
      data.page = JSON.parse(raw)
    } catch (err) {
      process.stderr.write('bench: the in-page run did not return JSON:\n' + String(raw).slice(0, 2000) + '\n')
      process.exit(1)
    }
  } finally {
    await farm.close()
    if (!args.includes('--keep')) await browser(['close'])
  }

  data.weightNew = weigh(path.join(CORE, 'html'))
  if (hasBaseline) data.weightBase = weigh(BASELINE_HTML)
  data.plugins = {}
  for (const name of ['fx_alpha', 'fx_beta']) {
    const dir = path.join(resourceDir(name, 'v1'), 'ui/dist')
    let bytes = 0
    let gz = 0
    const walk = (d) => {
      for (const e of fs.readdirSync(d, { withFileTypes: true })) {
        const full = path.join(d, e.name)
        if (e.isDirectory()) walk(full)
        else if (/\.(js|css)$/.test(e.name)) { const buf = fs.readFileSync(full); bytes += buf.length; gz += gzip(buf) }
      }
    }
    walk(dir)
    data.plugins[name] = { bytes, gz }
  }

  fs.writeFileSync(path.join(HERE, 'BENCH.md'), render(data))
  fs.writeFileSync(path.join(BENCH_DIR, 'bench.json'), JSON.stringify(data, null, 2))
  process.stdout.write('bench: wrote ui/tests/BENCH.md\n')
}

function render(d) {
  const p = d.page
  const L = []
  const pct = (a, b) => (Number.isFinite(a) && Number.isFinite(b) && b ? ((a - b) / b * 100).toFixed(0) + ' %' : 'n/a')
  L.push('# core UI — benchmarks (DESIGN §38.15)')
  L.push('')
  L.push('Generated by `node ui/tests/bench.mjs` on ' + d.at.slice(0, 19).replace('T', ' ') + ' (Node ' + d.node + ', Chromium via agent-browser).')
  L.push('Every timing is the **median of ' + (p.runs) + ' runs** measured in the page with `performance.now()`;')
  L.push('bytes are measured on disk (gzip level 9). Re-run it after any change to the shell or the runtime —')
  L.push('the file is overwritten, never hand-edited.')
  L.push('')
  L.push('**Baseline** = the last monolithic build of `core/html`, the one that compiled every plugin page into')
  L.push("core's own bundle (§38.16 deleted `ui/src/plugins.js`). It is not in git; `bench.mjs --baseline <dir>`")
  L.push('imports it once into `resources/node_modules/.cache/core-ui-bench/baseline/html` and re-uses it from there')
  L.push('(outside the resource: `fxlint` lints every stylesheet inside one, and a copy of a built `app.css` trips K006).')
  L.push('')
  L.push('## 1. What a player downloads')
  L.push('')
  L.push('| | baseline (monolith) | now (shell only) | change |')
  L.push('|---|---|---|---|')
  const wn = d.weightNew
  const wb = d.weightBase
  L.push('| JS (raw) | ' + (wb ? kb(wb.js) : 'n/a') + ' | ' + kb(wn.js) + ' | ' + (wb ? pct(wn.js, wb.js) : 'n/a') + ' |')
  L.push('| JS (gzip) | ' + (wb ? kb(wb.jsGz) : 'n/a') + ' | ' + kb(wn.jsGz) + ' | ' + (wb ? pct(wn.jsGz, wb.jsGz) : 'n/a') + ' |')
  L.push('| CSS (raw) | ' + (wb ? kb(wb.css) : 'n/a') + ' | ' + kb(wn.css) + ' | ' + (wb ? pct(wn.css, wb.css) : 'n/a') + ' |')
  L.push('| CSS (gzip) | ' + (wb ? kb(wb.cssGz) : 'n/a') + ' | ' + kb(wn.cssGz) + ' | ' + (wb ? pct(wn.cssGz, wb.cssGz) : 'n/a') + ' |')
  L.push('| fonts (unchanged) | ' + (wb ? kb(wb.font) : 'n/a') + ' | ' + kb(wn.font) + ' | — |')
  L.push('')
  L.push('Core\'s files now: ' + wn.files.map((f) => f.name + ' ' + kb(f.bytes) + ' (gz ' + kb(f.gz) + ')').join(', ') + '.')
  L.push('')
  L.push('A plugin ships its own bundle instead of being compiled in: '
    + Object.keys(d.plugins).map((k) => k + ' ' + kb(d.plugins[k].bytes) + ' (gz ' + kb(d.plugins[k].gz) + ')').join(', ')
    + ' — fetched from that resource\'s own origin, only when the resource is started.')
  L.push('')
  L.push('## 2. Shell startup (navigation start -> `ui_ready` posted)')
  L.push('')
  L.push('Measured by ALTERNATING the two shells, one warm-up run each discarded. The spread between the runs is')
  L.push('wider than the difference between the two builds, so read this as "startup did not regress", not as a win.')
  L.push('')
  L.push('| | median | min | max | samples |')
  L.push('|---|---|---|---|---|')
  if (d.baseStartup) L.push('| baseline (monolith) | ' + ms(median(d.baseStartup)) + ' | ' + ms(Math.min(...d.baseStartup)) + ' | ' + ms(Math.max(...d.baseStartup)) + ' | ' + d.baseStartup.length + ' |')
  L.push('| now (shell only) | ' + ms(median(d.newStartup)) + ' | ' + ms(Math.min(...d.newStartup)) + ' | ' + ms(Math.max(...d.newStartup)) + ' | ' + d.newStartup.length + ' |')
  L.push('')
  L.push('## 3. Plugin load and page open')
  L.push('')
  L.push('| what | median |')
  L.push('|---|---|')
  L.push('| plugin load, COLD (fetch + evaluate + `setup`, module cache empty) | ' + ms(median(p.loadCold)) + ' |')
  L.push('| plugin load, WARM (cached module, new activation — a restart) | ' + ms(median(p.loadWarm)) + ' |')
  L.push('| `page:open` -> component in the document | ' + ms(median(p.pageOpen)) + ' |')
  L.push('')
  L.push('## 4. Snapshot vs patch — a ' + p.slots + '-slot inventory')
  L.push('')
  L.push('| | deep (default) | shallow (`reactivity: \'shallow\'`) |')
  L.push('|---|---|---|')
  L.push('| first open: mount ' + p.slots + ' slot components | ' + ms(median(p.deep.mountMs)) + ' | ' + ms(median(p.shallow.mountMs)) + ' |')
  L.push('| snapshot on the wire (`page:open`) | ' + p.deep.snapshotBytes + ' B | ' + p.shallow.snapshotBytes + ' B |')
  L.push('| snapshot into the OPEN page: apply + render | ' + ms(median(p.deep.snapshotMs)) + ' | ' + ms(median(p.shallow.snapshotMs)) + ' |')
  L.push('| snapshot: slot components re-rendered | ' + p.deep.snapshotRenders + ' | ' + p.shallow.snapshotRenders + ' |')
  L.push('| one slot on the wire (`page:patch`) | ' + p.deep.patchBytes + ' B | ' + p.shallow.patchBytes + ' B |')
  L.push('| patch: apply only (200 ops, per op) | ' + ms(p.deep.patchBatchMs) + ' | ' + ms(p.shallow.patchBatchMs) + ' |')
  L.push('| patch: apply + render (one op) | ' + ms(median(p.deep.patchRenderMs)) + ' | ' + ms(median(p.shallow.patchRenderMs)) + ' |')
  L.push('| patch: slot components re-rendered | ' + p.deep.patchRenders + ' | ' + p.shallow.patchRenders + ' |')
  L.push('')
  L.push('Wire ratio: a patch is ' + (p.deep.snapshotBytes / p.deep.patchBytes).toFixed(0) + 'x smaller than the snapshot,')
  L.push('and FiveM pays two JSON encodes, two parses and a structured clone per message (§38.10).')
  L.push('`performance.now()` is clamped to 100 us in Chromium, which is why a single apply is timed in a batch of 200.')
  L.push('')
  L.push('## 5. Feeds')
  L.push('')
  L.push('| what | value |')
  L.push('|---|---|')
  L.push('| messages delivered in ' + (p.feed.ms / 1000).toFixed(1) + ' s (intended 1 kHz) | ' + p.feed.messages + ' (' + p.feed.messagesPerSec + '/s) |')
  L.push('| reactive flushes | ' + p.feed.flushes + ' (' + p.feed.flushesPerSec + '/s) |')
  L.push('| long tasks while feeding | ' + p.feed.longTasks + ' |')
  L.push('')
  L.push('One `requestAnimationFrame` per frame copies the latest value per key into the reactive target, so the')
  L.push('flush rate is the frame rate no matter how fast Lua pushes (the browser clamps a nested timer chain to')
  L.push('roughly 250 messages/s, which is why the intended 1 kHz is reported next to what was really delivered).')
  L.push('')
  L.push('## 6. Idle with ' + p.idle.plugins + ' registered, ready plugins and no page open')
  L.push('')
  L.push('| what | in ' + p.idle.seconds.toFixed(1) + ' s |')
  L.push('|---|---|')
  L.push('| `setTimeout` | ' + p.idle.setTimeout + ' |')
  L.push('| `setInterval` | ' + p.idle.setInterval + ' |')
  L.push('| `requestAnimationFrame` | ' + p.idle.raf + ' |')
  L.push('| observers created | ' + p.idle.observers + ' |')
  L.push('| NUI messages posted | ' + p.idle.posts + (p.idle.posts ? ' (' + p.idle.postNames.join(', ') + ')' : '') + ' |')
  L.push('| long tasks | ' + p.idle.longTasks + ' |')
  L.push('')
  L.push('Counted by wrapping `setTimeout`/`setInterval`/`requestAnimationFrame`/`MutationObserver`/`PerformanceObserver`')
  L.push('for the whole window; the harness\'s own `sleep` is excluded by stack frame.')
  if (p.idle.scheduledBy && p.idle.scheduledBy.length) {
    L.push('')
    L.push('What scheduled anything at all, by stack frame:')
    for (const entry of p.idle.scheduledBy) L.push('* `' + entry.kind + '` — ' + entry.stack.join(' <- '))
  }
  if (p.idle.postNames && p.idle.postNames.indexOf('blur_diag') !== -1) {
    L.push('')
    L.push('The `blur_diag` posts are §32\'s game-blur probe re-issuing its bind sequence: in a plain browser there is')
    L.push('no game texture to hook, so it keeps retrying on its backoff. In the CEF it binds and goes quiet — but it')
    L.push('is the only thing in the shell that talks while nothing happens, and it is worth re-checking in game.')
  }
  L.push('')
  L.push('## 7. Where the new architecture is NOT faster')
  L.push('')
  L.push('* **First open of a lazy page.** A compiled-in page was already in core\'s bundle; a plugin page now')
  L.push('  costs an HTTP round trip to another origin plus evaluation — the COLD number above (' + ms(median(p.loadCold)) + ')')
  L.push('  instead of ~0. `load: \'lazy\'` moves that cost to the first `page:open` of that resource.')
  L.push('* **Every extra resource adds a fetch.** Ten plugins are ten modules and ten stylesheets, requested in')
  L.push('  parallel but never bundled together; the monolith paid for them once, in one file, even for the 90 %')
  L.push('  of players who never open the page.')
  L.push('* **A restart is not free.** A same-build restart re-runs `setup` and remounts every open page of that')
  L.push('  resource (the WARM number, ' + ms(median(p.loadWarm)) + '); the monolith had no such event at all.')
  // The crossover is measured, never assumed: n ops cost n x the per-op apply, a snapshot costs its
  // own apply+render whatever changed, so they meet at snapshotMs / patchBatchMs ops.
  const crossover = Math.round(median(p.deep.snapshotMs) / p.deep.patchBatchMs)
  L.push('* **Patches stop being cheaper once the delta is big.** One op costs ' + ms(p.deep.patchBatchMs) + ' to apply and')
  L.push('  re-renders one child; a whole snapshot costs ' + ms(median(p.deep.snapshotMs)) + ' and re-renders all ' + p.slots + '. The two meet at')
  L.push('  about **' + crossover + ' ops** (' + ms(median(p.deep.snapshotMs)) + ' / ' + ms(p.deep.patchBatchMs) + ') — below that a patch wins on apply time as well as on')
  L.push('  bytes, above it the snapshot is the cheaper message. §38.10 caps a flush at 64 ops and falls back to a')
  L.push('  `page:open` for exactly this reason.')
  L.push('')
  return L.join('\n') + '\n'
}

await main()
