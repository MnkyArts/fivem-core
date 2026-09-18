// ui/scripts/check-plugins.mjs — the workspace view (DESIGN §38.13). Runs the real script as a
// child process against a temp "resources" folder holding freshly built fixtures.

import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { buildPlugin, cleanupAll, makePlugin, SDK_DIR } from './helpers.mjs'

const SCRIPT = path.join(SDK_DIR, '../scripts/check-plugins.mjs')

function run(resourcesDir, args = []) {
  try {
    const out = execFileSync(process.execPath, [SCRIPT, resourcesDir, ...args], { encoding: 'utf8' })
    return { code: 0, out }
  } catch (err) {
    return { code: err.status, out: String(err.stdout || '') + String(err.stderr || '') }
  }
}

describe('check-plugins', () => {
  let ws

  before(async () => {
    // One temp root with two built plugins; `makePlugin` already gives each its own root, so the
    // first one's parent is reused as the workspace.
    const alpha = makePlugin({ resource: 'alpha' })
    ws = alpha.tmp
    await buildPlugin(alpha.uiDir)
    const beta = makePlugin({
      resource: 'beta',
      files: {
        'ui/src/index.ts': `import { defineUIPlugin } from '@core/ui'
import Page from './Page.vue'
export default defineUIPlugin({ pages: { beta: Page } })\n`,
      },
    })
    await buildPlugin(beta.uiDir)
    fs.cpSync(beta.dir, path.join(ws, 'beta'), { recursive: true })
  })
  after(() => cleanupAll())

  it('accepts two valid plugins and names them', () => {
    const { code, out } = run(ws)
    assert.equal(code, 0, out)
    assert.match(out, /check-plugins: 2 UI plugin\(s\) \[alpha, beta\], 0 error\(s\)/)
  })

  it('--json reports the plugins, their pages and the api version', () => {
    const { out } = run(ws, ['--json'])
    const data = JSON.parse(out)
    assert.equal(data.ok, true)
    assert.equal(data.apiVersion, 1)
    assert.deepEqual(data.plugins.map((p) => p.id).sort(), ['alpha', 'beta'])
    assert.deepEqual(data.plugins[0].pages, ['alpha', 'alpha_lazy'])
    assert.ok(data.plugins.every((p) => p.ok && p.build))
  })

  it('reports a page id claimed by two resources', () => {
    const manifestFile = path.join(ws, 'beta/ui/dist/manifest.json')
    const m = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
    fs.writeFileSync(manifestFile, JSON.stringify({ ...m, pages: ['alpha'] }, null, 2))
    const { code, out } = run(ws)
    assert.equal(code, 1)
    assert.match(out, /page id 'alpha' is claimed by alpha and beta/)
    fs.writeFileSync(manifestFile, JSON.stringify(m, null, 2))
  })

  it('reports an apiVersion the shell would refuse, and a file that is not on disk', () => {
    const manifestFile = path.join(ws, 'beta/ui/dist/manifest.json')
    const m = JSON.parse(fs.readFileSync(manifestFile, 'utf8'))
    fs.writeFileSync(manifestFile, JSON.stringify({ ...m, apiVersion: 2, entry: 'plugin.gone.js' }, null, 2))
    const { code, out } = run(ws)
    assert.equal(code, 1)
    assert.match(out, /built for core UI API 2, this core provides 1/)
    assert.match(out, /'plugin\.gone\.js' is in the manifest but not on disk/)
    fs.writeFileSync(manifestFile, JSON.stringify(m, null, 2))
  })

  it('warns when dist is older than ui/src instead of failing', () => {
    const src = path.join(ws, 'beta/ui/src/Page.vue')
    const future = new Date(Date.now() + 60_000)
    fs.utimesSync(src, future, future)
    const { code, out } = run(ws)
    assert.equal(code, 0, out)
    assert.match(out, /WARN\s+beta: ui\/dist\/ is older than ui\/src/)
  })

  it('fails when a resource opts in but never built', () => {
    fs.rmSync(path.join(ws, 'beta/ui/dist'), { recursive: true, force: true })
    const { code, out } = run(ws)
    assert.equal(code, 1)
    assert.match(out, /ui\/dist\/manifest\.json does not exist/)
  })
})
