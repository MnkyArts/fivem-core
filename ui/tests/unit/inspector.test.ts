// runtime/inspector.ts — the snapshot builder (DESIGN §38.14). No DOM, no panel: the Vue component
// only formats what this returns, so this is where the numbers are pinned.
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import * as Inspector from '../../src/runtime/inspector.ts'
import * as Plugins from '../../src/runtime/plugins.ts'
import * as Pages from '../../src/runtime/pages.ts'
import * as Layers from '../../src/runtime/layers.ts'
import * as Feeds from '../../src/runtime/feeds.ts'
import { clearErrorLog, report, setNotify } from '../../src/runtime/errors.ts'
import { post, resetStats, resetTransport, setTransport } from '../../src/runtime/transport.ts'
import type { MsgPluginRegister } from '../../src/runtime/protocol.ts'
import type { PluginManifest } from '../../sdk/src/contract.ts'

const COMPONENT = { name: 'FakePage', render: () => null }
const flush = () => new Promise((r) => setTimeout(r, 0))
const slice = { focused: false, focusStack: [] }

beforeEach(() => {
  Inspector.stop()
  Pages.resetPages()
  Plugins.resetPlugins()
  Feeds.resetFeeds()
  clearErrorLog()
  resetStats()
  Layers.attachLayerStore(slice)
  Layers.resetLayers()
  setNotify(() => {})
  Plugins.configurePlugins({
    document: null,
    importModule: (url: string) =>
      url.indexOf('good') !== -1
        ? Promise.resolve({ default: { __coreUIPlugin: true, apiVersion: 1, pages: { good_page: COMPONENT }, setup: (ctx: { scope: { timeout(f: () => void, ms: number): void } }) => { ctx.scope.timeout(() => {}, 60000) } } })
        : Promise.reject(new Error('404 ' + url)),
  })
  setTransport({ send: () => Promise.resolve({}) })
})

function registerPlugin(id: string, entry: string): void {
  Plugins.register({
    id, generation: 3, base: 'https://cfx-nui-' + id + '/ui/dist/',
    manifest: { id, apiVersion: 1, entry, css: [], build: 'b' + id } as PluginManifest,
  } as MsgPluginRegister)
}

test('an empty shell reports empty everything', () => {
  const s = Inspector.snapshot(1000)
  assert.deepEqual(s.plugins, [])
  assert.deepEqual(s.pages, [])
  assert.deepEqual(s.focus, [])
  assert.deepEqual(s.longTasks, [])
  assert.equal(s.traffic.outPerSec, 0)
  assert.equal(s.traffic.bytes, false, 'byte counting is off while the panel is closed')
  resetTransport()
})

test('plugins, their scopes and the module cache show up', async () => {
  registerPlugin('good', 'plugin.good.js')
  registerPlugin('bad', 'plugin.bad.js')
  await flush()
  const s = Inspector.snapshot(1000)
  const good = s.plugins.find((p) => p.id === 'good')
  const bad = s.plugins.find((p) => p.id === 'bad')
  assert.equal(good?.state, 'ready')
  assert.equal(good?.generation, 3)
  assert.equal(good?.build, 'bgood')
  assert.ok(typeof good?.ms === 'number')
  assert.deepEqual(good?.pages, ['good_page'])
  assert.equal(bad?.state, 'failed')
  assert.match(String(bad?.error), /404/)
  // The plugin's scope is listed with the timer its `setup` armed.
  const scope = s.scopes.find((x) => x.label === 'plugin:good')
  assert.equal(scope?.timers, 1)
  // The failed URL is dropped from the cache so a retry really refetches; the good one stays.
  assert.deepEqual(s.modules.map((m) => m.state), ['loaded'])
  Plugins.unregister('good')
  Plugins.unregister('bad')
  resetTransport()
})

test('pages report declared / open / mounted and their owner', async () => {
  registerPlugin('good', 'plugin.good.js')
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'good_page', type: 'page', owner: 'good' })
  Pages.registerPage({ action: 'page:register', id: 'orphan', type: 'overlay' })
  let s = Inspector.snapshot(1000)
  assert.deepEqual(s.pages.find((p) => p.id === 'good_page'), {
    id: 'good_page', owner: 'good', type: 'page', open: false, mounted: false,
    keepAlive: false, reactivity: 'deep', crashed: false, error: null,
  })
  Pages.openPage({ action: 'page:open', id: 'good_page', props: {} })
  s = Inspector.snapshot(2000)
  const page = s.pages.find((p) => p.id === 'good_page')
  assert.equal(page?.open, true)
  assert.equal(page?.mounted, true)
  assert.ok(s.scopes.some((x) => x.label === 'page:good_page'))
  Pages.markCrashed('good_page')
  s = Inspector.snapshot(3000)
  assert.equal(s.pages.find((p) => p.id === 'good_page')?.mounted, false, 'a crashed instance is not mounted')
  resetTransport()
})

test('the focus stack is mirrored verbatim', () => {
  Layers.applyFocus({ focused: true, stack: [
    { key: 'page:inv', layer: 'page', id: 'inv', owner: 'inventory' },
    { key: 'modal:confirm', layer: 'modal', id: 'confirm', owner: 'inventory' },
  ] })
  const s = Inspector.snapshot(1000)
  assert.deepEqual(s.focus.map((f) => f.key), ['page:inv', 'modal:confirm'])
  resetTransport()
})

test('traffic and feed rates are deltas between two snapshots', async () => {
  Inspector.snapshot(1000)
  await post('ui_event', { a: 1 })
  await post('ui_event', { a: 2 })
  await post('ui_close', { page: 'x' })
  const s = Inspector.snapshot(3000) // +2 s
  assert.equal(s.dt, 2)
  assert.equal(s.traffic.out.ui_event, 2)
  assert.equal(s.traffic.outPerSec, 1.5, '3 posts over 2 s')
  resetTransport()
})

test('feed writes and flushes are counted per second', () => {
  let frame: (() => void) | null = null
  Feeds.configureFeeds({ raf: (cb) => { frame = () => cb(0); return 1 }, cancelRaf: () => {}, setTimeout: () => 0, clearTimeout: () => {} })
  Inspector.snapshot(1000)
  Feeds.applyFeed({ c: { veh: { speed: 1, rpm: 2 } } })
  ;(frame as unknown as () => void)()
  const s = Inspector.snapshot(2000)
  assert.equal(s.feeds.writesPerSec, 2)
  assert.equal(s.feeds.flushesPerSec, 1)
  Feeds.configureFeeds({ raf: null, cancelRaf: null })
  resetTransport()
})

test('the last errors ride along', () => {
  const realError = console.error
  console.error = () => {}
  report({ plugin: 'inventory', page: 'inv', error: new Error('render exploded') })
  console.error = realError
  const s = Inspector.snapshot(1000)
  assert.equal(s.errors.length, 1)
  assert.equal(s.errors[0].plugin, 'inventory')
  resetTransport()
})

test('start() arms byte counting, stop() disarms it and leaves nothing running', () => {
  assert.equal(Inspector.isRunning(), false)
  Inspector.start()
  Inspector.start() // idempotent
  assert.equal(Inspector.isRunning(), true)
  assert.equal(Inspector.snapshot(1000).traffic.bytes, true)
  Inspector.stop()
  assert.equal(Inspector.isRunning(), false)
  assert.equal(Inspector.snapshot(2000).traffic.bytes, false)
  resetTransport()
})
