// `npm run dev` vs `npm run dev:game` as the dev SERVER really answers them (DESIGN §38.11).
//
// Both modes are started for real (Vite's JS API, a free port) and driven over HTTP. The one thing
// that must differ is `vue`: the browser dev host runs core's shell in this same graph, so `vue`
// stays the real module; attached mode serves the host shim, because the Vue is the game shell's.

import { after, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { cleanupAll, makePlugin, startDevServer } from './helpers.mjs'

const servers = []
async function serve(uiDir, mode) {
  const s = await startDevServer(uiDir, { mode })
  servers.push(s)
  return s
}

describe('dev server', () => {
  after(async () => {
    for (const s of servers.splice(0)) await s.close()
    cleanupAll()
  })

  it('serves a virtual index.html pointing at dev/host.ts when the plugin has none', async () => {
    const p = makePlugin({ resource: 'alpha' })
    assert.ok(!fs.existsSync(path.join(p.uiDir, 'index.html')), 'the fixture must not ship an index.html')
    const dev = await serve(p.uiDir)
    const page = await dev.get('/')
    assert.equal(page.status, 200)
    assert.match(page.text, /<div id="app"><\/div>/)
    assert.match(page.text, /src="\/dev\/host\.ts"/)
    // transformIndexHtml injected the HMR client — without it nothing hot-updates.
    assert.match(page.text, /@vite\/client/)
    assert.equal((await dev.get('/index.html')).status, 200)
  })

  it('explains itself when neither index.html nor dev/host.ts exists', async () => {
    const p = makePlugin({ resource: 'alpha', remove: ['ui/dev'] })
    const dev = await serve(p.uiDir)
    const page = await dev.get('/')
    assert.equal(page.status, 500)
    assert.match(page.text, /\[core-ui\] alpha: no ui\/index\.html and no ui\/dev\/host\.ts/)
    assert.match(page.text, /createDevHost\(\{ id: 'alpha', plugin \}\)/)
  })

  it('keeps a plugin-owned index.html', async () => {
    const p = makePlugin({ resource: 'alpha', files: { 'ui/index.html': '<!doctype html><html><body><b>mine</b><script type="module" src="/dev/host.ts"></script></body></html>\n' } })
    const dev = await serve(p.uiDir)
    const page = await dev.get('/')
    assert.equal(page.status, 200)
    assert.match(page.text, /<b>mine<\/b>/)
  })

  it('dev host: `vue` is the real module, and the plugin stylesheet is served', async () => {
    const p = makePlugin({ resource: 'alpha' })
    const dev = await serve(p.uiDir)
    const sfc = await dev.get('/src/Page.vue')
    assert.equal(sfc.status, 200)
    assert.ok(!sfc.text.includes('virtual:core-ui/vue'), 'the host shim must NOT be used in the browser dev host')
    // A real Vue module, from the optimizer cache (pinned into <ui>/.core-ui) or straight off disk.
    assert.match(sfc.text, /from "[^"]*(deps\/vue\.js|\/vue\/dist\/vue[^"]*)[^"]*"/)
    // The generated utilities entry is injected into the entry module and served as a JS module.
    const entry = await dev.get('/src/index.ts')
    assert.match(entry.text, /\.core-ui\/entry\.css/)
  })

  it('attached mode: `vue` resolves to the host shim', async () => {
    const p = makePlugin({ resource: 'alpha' })
    const dev = await serve(p.uiDir, 'game')
    const sfc = await dev.get('/src/Page.vue')
    assert.equal(sfc.status, 200)
    assert.match(sfc.text, /virtual:core-ui\/vue/)
    const shim = await dev.get('/@id/__x00__virtual:core-ui/vue')
    assert.match(shim.text, /__CORE_UI_HOST__/)
    assert.match(shim.text, /export const ref =/)
  })
})
