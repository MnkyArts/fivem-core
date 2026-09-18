#!/usr/bin/env node
// core UI — the three agent-browser suites in ONE process tree (DESIGN §38.15).
//
//   node ui/tests/run-browser-suites.mjs [--only shell,kit,runtime] [--keep] [--session <name>]
//
// It builds the fixture plugins when an input changed, starts `nui-serve` (one origin per resource,
// FiveM's headers), opens the BUILT shell at `http://127.0.0.1:8821/html/index.html` and runs
// shell-regression, kit-regression and runtime-regression through agent-browser. Each suite's
// `PASS n/m` line is printed; any `FAIL` line or a missing PASS line fails the run.
//
// The servers must live in this process tree: a background server started from a separate shell
// call is killed with that call, and then every suite 404s.

import { spawn } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { startServers } from './nui-serve.mjs'
import { ensureFixtures, FIXTURES, resourceDir } from './build-fixtures.mjs'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const CORE = path.resolve(HERE, '../..')

const args = process.argv.slice(2)
const argOf = (name, fallback) => {
  const i = args.indexOf(name)
  return i === -1 ? fallback : args[i + 1]
}
const only = new Set((argOf('--only', 'shell,kit,runtime') || '').split(',').map((s) => s.trim()).filter(Boolean))
const SESSION = argOf('--session', 'uiplat-i5')
const KEEP = args.includes('--keep')

/** core is the CONTROL origin (the page's own), every fixture gets its own port = its own origin. */
const PORTS = { core: 8821, fx_alpha: 8822, fx_beta: 8823, fx_lazy: 8824, fx_throw_eval: 8825, fx_throw_setup: 8826, fx_not_plugin: 8827, fx_api2: 8828 }
const SHELL_URL = 'http://127.0.0.1:' + PORTS.core + '/html/index.html'

const SUITES = [
  { name: 'shell', file: 'shell-regression.js' },
  { name: 'kit', file: 'kit-regression.js' },
  { name: 'runtime', file: 'runtime-regression.js' },
]

function run(cmd, argv, opts) {
  const options = opts || {}
  return new Promise((resolve) => {
    const child = spawn(cmd, argv, { cwd: CORE, stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (d) => { stdout += d })
    child.stderr.on('data', (d) => { stderr += d })
    child.on('error', (err) => resolve({ code: 127, stdout, stderr: stderr + String(err) }))
    child.on('close', (code) => resolve({ code, stdout, stderr }))
    if (options.input !== undefined) child.stdin.write(options.input)
    child.stdin.end()
  })
}

const browser = (argv, opts) => run('agent-browser', ['--session', SESSION].concat(argv), opts)

async function main() {
  if (!fs.existsSync(path.join(CORE, 'html/assets/app.js'))) {
    process.stderr.write('run-browser-suites: core/html is not built — run `cd ui && npm run build` first\n')
    process.exit(2)
  }

  const built = await ensureFixtures({})
  process.stdout.write('fixtures: ' + (built.built ? 'rebuilt' : 'up to date') + '\n')

  const farm = await startServers({
    control: 'core',
    log: false,
    resources: [
      // The core RESOURCE root, so the shell is at /html/index.html exactly like in the CEF, and
      // `files { 'html/**' }` is what makes everything else 404 (DESIGN §38.1).
      { name: 'core', port: PORTS.core, dir: CORE, files: ['html/**'] },
    ].concat(
      FIXTURES.map((f) => ({ name: f.name, port: PORTS[f.name], dir: resourceDir(f.name, 'v1'), files: ['ui/dist/**'] })),
    ),
  })

  let failed = false
  try {
    const open = await browser(['open', SHELL_URL])
    if (open.code !== 0) throw new Error('agent-browser open failed: ' + open.stderr)

    for (const suite of SUITES) {
      if (!only.has(suite.name)) continue
      // Every suite starts from a fresh shell: they all drive global state.
      await browser(['open', SHELL_URL])
      await browser(['wait', '400'])
      const res = await browser(['eval', '--stdin'], { input: fs.readFileSync(path.join(HERE, suite.file), 'utf8') })
      // A suite returns its whole report as ONE string, so agent-browser prints it JSON-quoted with
      // escaped newlines: unescape before looking for the per-check lines.
      const text = ((res.stdout || '') + (res.stderr || '')).replace(/\\n/g, '\n').replace(/\\"/g, '"')
      const passLine = (text.match(/PASS \d+\/\d+/g) || []).pop()
      // The first line still carries the JSON opening quote of the returned string.
      const fails = (text.match(/^"?FAIL .*$/gm) || []).map((l) => l.replace(/^"/, ''))
      process.stdout.write('\n== ' + suite.name + '-regression\n')
      for (const line of fails) process.stdout.write(line + '\n')
      process.stdout.write((passLine || 'NO PASS LINE — the suite did not finish') + '\n')
      if (!passLine || fails.length) {
        failed = true
        if (!passLine) process.stdout.write(text.slice(-2000) + '\n')
      }
    }
  } finally {
    await farm.close()
    if (!KEEP) await browser(['close'])
  }
  process.exit(failed ? 1 : 0)
}

await main()
