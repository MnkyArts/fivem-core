// runtime/pages.ts — props identity, the 1-based patch rules and the load-aware waiters.
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import * as Pages from '../../src/runtime/pages.ts'
import * as Plugins from '../../src/runtime/plugins.ts'
import { setTransport, resetTransport } from '../../src/runtime/transport.ts'
import { setNotify } from '../../src/runtime/errors.ts'
import { isReactive } from 'vue'
import type { MsgPluginRegister } from '../../src/runtime/protocol.ts'
import type { PluginManifest } from '../../sdk/src/contract.ts'

const posts: Array<{ name: string; body: Record<string, unknown> }> = []
const toasts: string[] = []
let modules: Record<string, unknown> = {}
const flush = () => new Promise((r) => setTimeout(r, 0))
const COMPONENT = { name: 'FakePage', render: () => null }

function registerPlugin(id: string, pages: Record<string, unknown>, opts?: { entry?: string; generation?: number }): void {
  const entry = (opts && opts.entry) || 'plugin.' + id + '.js'
  const base = 'https://cfx-nui-' + id + '/ui/dist/'
  modules[base + entry] = { default: { __coreUIPlugin: true, apiVersion: 1, pages } }
  Plugins.register({
    id,
    generation: (opts && opts.generation) || 1,
    base,
    manifest: { id, apiVersion: 1, entry, css: [], build: id } as PluginManifest,
  } as MsgPluginRegister)
}

beforeEach(() => {
  posts.length = 0
  toasts.length = 0
  modules = {}
  Pages.resetPages()
  Plugins.resetPlugins()
  Plugins.setDevOptions({ loadTimeoutMs: 40 })
  Plugins.configurePlugins({
    document: null,
    importModule: (url: string) => {
      const mod = modules[url]
      return mod ? Promise.resolve(mod as Record<string, unknown>) : Promise.reject(new Error('404 ' + url))
    },
  })
  setNotify((m) => toasts.push(String((m as { message: string }).message)))
  setTransport({
    send(name, body) {
      posts.push({ name, body: body as Record<string, unknown> })
      return Promise.resolve({})
    },
  })
})

// ---------------------------------------------------------------- props identity (§7.4)

test('the props object of an id survives unregister + register', () => {
  Pages.registerPage({ action: 'page:register', id: 'test', type: 'page' })
  const before = Pages.propsFor('test')
  Pages.openPage({ action: 'page:open', id: 'test', props: { greeting: 'hi' } })
  Pages.unregisterPage('test')
  Pages.registerPage({ action: 'page:register', id: 'test', type: 'page' })
  assert.equal(Pages.propsFor('test'), before)
  Pages.openPage({ action: 'page:open', id: 'test', props: { greeting: 'again' } })
  assert.equal(before.greeting, 'again')
  assert.equal(Pages.pageState().pages.test.props, before)
  resetTransport()
})

test('page:open replaces the CONTENT of the props object, never the object', () => {
  Pages.registerPage({ action: 'page:register', id: 'p', type: 'page' })
  const props = Pages.propsFor('p')
  Pages.openPage({ action: 'page:open', id: 'p', props: { a: 1, b: 2 } })
  Pages.openPage({ action: 'page:open', id: 'p', props: { b: 3 } })
  assert.deepEqual(Object.keys(props), ['b'])
  assert.equal(props.b, 3)
  resetTransport()
})

// ---------------------------------------------------------------- patches (§38.10, 1-based)

function openWith(props: Record<string, unknown>, reactivity?: 'deep' | 'shallow'): Record<string, unknown> {
  Pages.setPageComponent('p', COMPONENT)
  Pages.registerPage({ action: 'page:register', id: 'p', type: 'page' })
  if (reactivity) Pages.pageState().pages.p.reactivity = reactivity
  Pages.openPage({ action: 'page:open', id: 'p', props })
  return Pages.propsFor('p')
}

test('R1: an in-range list index writes arr[n - 1]', () => {
  const props = openWith({ slots: ['a', 'b', 'c'] })
  Pages.applyPatch('p', [{ p: 'slots.2', v: 'B' }])
  assert.deepEqual(props.slots, ['a', 'B', 'c'])
  resetTransport()
})

test('R1: length + 1 appends', () => {
  const props = openWith({ slots: ['a', 'b'] })
  Pages.applyPatch('p', [{ p: 'slots.3', v: 'c' }])
  assert.deepEqual(props.slots, ['a', 'b', 'c'])
  resetTransport()
})

test('R1: deleting the LAST element shrinks the list', () => {
  const props = openWith({ slots: ['a', 'b', 'c'] })
  Pages.applyPatch('p', [{ p: 'slots.3' }])
  assert.deepEqual(props.slots, ['a', 'b'])
  resetTransport()
})

test('R1: an EMPTY list + index 1 appends', () => {
  const props = openWith({ slots: [] })
  Pages.applyPatch('p', [{ p: 'slots.1', v: 'first' }])
  assert.deepEqual(props.slots, ['first'])
  resetTransport()
})

test('R2: an EMPTY list that gets a map key becomes an object in its parent', () => {
  const props = openWith({ slots: [] })
  Pages.applyPatch('p', [{ p: 'slots.12', v: { id: 'gun' } }])
  assert.ok(!Array.isArray(props.slots))
  assert.deepEqual(props.slots, { 12: { id: 'gun' } })
  resetTransport()
})

test('R2: a numeric key on an object is a plain property', () => {
  const props = openWith({ slots: { 3: 'c' } })
  Pages.applyPatch('p', [{ p: 'slots.12', v: 'l' }])
  assert.deepEqual(props.slots, { 3: 'c', 12: 'l' })
  resetTransport()
})

test('R2: an out-of-range index on a non-empty list is a hole, applied and warned about', () => {
  const props = openWith({ slots: ['a'] })
  const realWarn = console.warn
  const warnings: string[] = []
  console.warn = (...args: unknown[]) => warnings.push(args.join(' '))
  Pages.applyPatch('p', [{ p: 'slots.9', v: 'far' }])
  console.warn = realWarn
  assert.equal((props.slots as unknown as Record<string, unknown>)['9'], 'far')
  assert.equal(warnings.length, 1)
  assert.match(warnings[0], /hole in a list/)
  resetTransport()
})

test('deleting in the middle of a list warns and leaves the length alone', () => {
  const props = openWith({ slots: ['a', 'b', 'c'] })
  const realWarn = console.warn
  console.warn = () => {}
  Pages.applyPatch('p', [{ p: 'slots.1' }])
  console.warn = realWarn
  assert.equal((props.slots as unknown[]).length, 3)
  assert.equal((props.slots as unknown[])[0], undefined)
  resetTransport()
})

test('a missing `v` deletes; `v: null` sets null', () => {
  const props = openWith({ a: 1, b: 2 })
  Pages.applyPatch('p', [{ p: 'a' }, { p: 'b', v: null }])
  assert.equal('a' in props, false)
  assert.equal(props.b, null)
  resetTransport()
})

test('intermediates that do not exist are created as maps', () => {
  const props = openWith({})
  Pages.applyPatch('p', [{ p: 'a.b.c', v: 7 }])
  assert.deepEqual(props.a, { b: { c: 7 } })
  resetTransport()
})

test('ops apply in order', () => {
  const props = openWith({ n: 0 })
  Pages.applyPatch('p', [{ p: 'n', v: 1 }, { p: 'n', v: 2 }, { p: 'n', v: 3 }])
  assert.equal(props.n, 3)
  resetTransport()
})

test('a patch for a page that is not open is ignored', () => {
  const props = openWith({ a: 1 })
  Pages.closePageAction({ id: 'p' })
  Pages.applyPatch('p', [{ p: 'a', v: 99 }])
  assert.equal(props.a, 1)
  resetTransport()
})

test('shallow pages copy along the path and re-assign the top-level key', () => {
  const props = openWith({ big: { list: ['a', 'b'] } }, 'shallow')
  const before = props.big
  const beforeList = (props.big as { list: unknown[] }).list
  Pages.applyPatch('p', [{ p: 'big.list.2', v: 'B' }])
  assert.notEqual(props.big, before, 'the top-level key is replaced')
  assert.notEqual((props.big as { list: unknown[] }).list, beforeList, 'the container on the path is copied')
  assert.deepEqual((props.big as { list: unknown[] }).list, ['a', 'B'])
  assert.deepEqual(beforeList, ['a', 'b'], 'the old value is untouched')
  resetTransport()
})

test('shallow pages apply a one-segment op directly', () => {
  const props = openWith({ weight: 1 }, 'shallow')
  Pages.applyPatch('p', [{ p: 'weight', v: 84.5 }])
  assert.equal(props.weight, 84.5)
  resetTransport()
})

// ---------------------------------------------------------------- component resolution

test('a page resolves through its OWNER plugin', async () => {
  registerPlugin('alpha', { alpha: COMPONENT })
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'alpha', type: 'page', owner: 'alpha' })
  assert.equal(Pages.pageState().pages.alpha.component, COMPONENT)
  resetTransport()
})

test('a page:open that arrives while the plugin loads waits on THAT promise', async () => {
  let release: (() => void) | null = null
  const base = 'https://cfx-nui-alpha/ui/dist/'
  modules[base + 'plugin.aaa.js'] = null
  Plugins.configurePlugins({
    document: null,
    importModule: () => new Promise((resolve) => {
      release = () => resolve({ default: { __coreUIPlugin: true, apiVersion: 1, pages: { alpha: COMPONENT } } })
    }),
  })
  Plugins.register({
    id: 'alpha', generation: 1, base,
    manifest: { id: 'alpha', apiVersion: 1, entry: 'plugin.aaa.js', css: [], build: 'aaa' } as PluginManifest,
  } as MsgPluginRegister)
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'alpha', type: 'page', owner: 'alpha' })
  Pages.openPage({ action: 'page:open', id: 'alpha', props: { n: 1 } })
  assert.equal(Pages.pageState().pages.alpha.component, null)
  ;(release as unknown as () => void)()
  await flush()
  await flush()
  assert.equal(Pages.pageState().pages.alpha.component, COMPONENT)
  assert.equal(posts.filter((p) => p.name === 'ui_close').length, 0)
  resetTransport()
})

test('a page:open for a FAILED plugin fails fast: __error, a toast and ui_close', async () => {
  registerPlugin('alpha', { alpha: COMPONENT }, { entry: 'missing.js' })
  delete modules['https://cfx-nui-alpha/ui/dist/missing.js']
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'failed')
  Pages.registerPage({ action: 'page:register', id: 'alpha', type: 'page', owner: 'alpha' })
  Pages.openPage({ action: 'page:open', id: 'alpha' })
  const err = posts.filter((p) => p.name === 'ui_event').pop()
  assert.equal(err?.body.event, '__error')
  assert.ok(posts.some((p) => p.name === 'ui_close' && p.body.page === 'alpha'))
  assert.equal(toasts.length, 1)
  assert.equal(Pages.pageState().openPage, null)
  resetTransport()
})

test('a plugin that provides a page it does not own is named in the error', async () => {
  registerPlugin('beta', { alpha_page: COMPONENT })
  await flush()
  const realError = console.error
  const errors: string[] = []
  console.error = (...args: unknown[]) => errors.push(args.join(' '))
  Pages.registerPage({ action: 'page:register', id: 'alpha_page', type: 'page', owner: 'alpha' })
  console.error = realError
  assert.equal(errors.length, 1)
  assert.match(errors[0], /plugin "beta" provides the page "alpha_page"/)
  assert.match(errors[0], /owner "alpha"/)
  resetTransport()
})

test('unregistering a plugin drops the INSTANCE but never the open state (Lua owns focus)', async () => {
  const seen: string[] = []
  registerPlugin('alpha', {
    alpha: { component: COMPONENT, onOpen: () => seen.push('open'), onClose: () => seen.push('close') },
  })
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'alpha', type: 'page', owner: 'alpha' })
  Pages.openPage({ action: 'page:open', id: 'alpha', props: { a: 1 } })
  const props = Pages.propsFor('alpha')
  const scopeBefore = Pages.pageScope('alpha')
  Plugins.unregister('alpha')
  // The page STAYS open — Lua still holds NUI focus for it and will close it itself if it wants to.
  assert.equal(Pages.pageState().openPage, 'alpha')
  assert.equal(Pages.pageState().pages.alpha.component, null)
  assert.equal(Pages.pageState().pages.alpha.registered, false)
  assert.deepEqual(seen, ['open', 'close'], 'the OLD definition got its onClose')
  assert.equal(scopeBefore?.disposed, true, 'the page scope died with the activation')
  assert.equal(Pages.pageScope('alpha'), null)
  assert.equal(Pages.propsFor('alpha'), props)
  assert.equal(posts.filter((p) => p.name === 'ui_close').length, 0, 'nothing was closed behind Lua\'s back')
  resetTransport()
})

test('re-registering the plugin re-mounts an open page and runs the NEW onOpen', async () => {
  const seen: string[] = []
  registerPlugin('alpha', { alpha: { component: COMPONENT, onOpen: () => seen.push('open:1') } })
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'alpha', type: 'page', owner: 'alpha' })
  Pages.openPage({ action: 'page:open', id: 'alpha', props: { a: 1 } })
  const props = Pages.propsFor('alpha')
  const NEXT = { name: 'FakePage2', render: () => null }
  registerPlugin('alpha', { alpha: { component: NEXT, onOpen: () => seen.push('open:2') } }, { entry: 'plugin.alpha2.js', generation: 2 })
  await flush()
  assert.deepEqual(seen, ['open:1', 'open:2'])
  assert.equal(Pages.pageState().openPage, 'alpha')
  assert.equal(Pages.pageState().pages.alpha.component, NEXT)
  assert.equal(Pages.propsFor('alpha'), props, 'the props object belongs to the shell')
  assert.equal(props.a, 1)
  assert.ok(Pages.pageScope('alpha'), 'a fresh page scope')
  resetTransport()
})

test('a re-registration that FAILS fails every open page it owns', async () => {
  registerPlugin('alpha', { alpha: COMPONENT })
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'alpha', type: 'page', owner: 'alpha' })
  Pages.openPage({ action: 'page:open', id: 'alpha', props: {} })
  posts.length = 0
  Plugins.register({
    id: 'alpha', generation: 2, base: 'https://cfx-nui-alpha/ui/dist/',
    manifest: { id: 'alpha', apiVersion: 1, entry: 'gone.js', css: [], build: 'gone' } as PluginManifest,
  } as MsgPluginRegister)
  await flush()
  const err = posts.filter((p) => p.name === 'ui_event').pop()
  assert.equal(err?.body.event, '__error')
  assert.ok(posts.some((p) => p.name === 'ui_close' && p.body.page === 'alpha'))
  assert.equal(Pages.pageState().openPage, null)
  resetTransport()
})

test('onOpen is not lost when page:open beats the plugin (F2)', async () => {
  const seen: string[] = []
  let release: (() => void) | null = null
  Plugins.configurePlugins({
    document: null,
    importModule: () => new Promise((resolve) => {
      release = () => resolve({
        default: {
          __coreUIPlugin: true, apiVersion: 1,
          pages: { late: { component: COMPONENT, onOpen: (p: { props: Record<string, unknown> }) => seen.push('open:' + p.props.n) } },
        },
      })
    }),
  })
  Plugins.register({
    id: 'late', generation: 1, base: 'https://cfx-nui-late/ui/dist/',
    manifest: { id: 'late', apiVersion: 1, entry: 'p.js', css: [], build: 'p' } as PluginManifest,
  } as MsgPluginRegister)
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'late', type: 'page', owner: 'late' })
  Pages.openPage({ action: 'page:open', id: 'late', props: { n: 7 } })
  assert.deepEqual(seen, [], 'no component yet, no hook yet')
  ;(release as unknown as () => void)()
  await flush()
  await flush()
  assert.deepEqual(seen, ['open:7'], 'the hook ran once the component landed, with the final props')
  resetTransport()
})

test('two pages can wait at once and both fail on their own (F3)', async () => {
  Pages.registerPage({ action: 'page:register', id: 'w1', type: 'page' })
  Pages.registerPage({ action: 'page:register', id: 'w2', type: 'overlay' })
  Pages.openPage({ action: 'page:open', id: 'w1', props: {} })
  Pages.openPage({ action: 'page:open', id: 'w2', props: {} })
  await new Promise((r) => setTimeout(r, 90)) // loadTimeoutMs is 40 in these tests
  const failed = posts.filter((p) => p.name === 'ui_event' && (p.body as { event: string }).event === '__error')
  assert.deepEqual(failed.map((p) => (p.body as { page: string }).page).sort(), ['w1', 'w2'])
  resetTransport()
})

test('a crashed page is remounted by the next page:open (F4)', () => {
  Pages.setPageComponent('boom', COMPONENT)
  Pages.registerPage({ action: 'page:register', id: 'boom', type: 'overlay' })
  Pages.openPage({ action: 'page:open', id: 'boom', props: { ok: false } })
  const rec = Pages.pageState().pages.boom
  assert.equal(rec.epoch, 0)
  Pages.markCrashed('boom')
  assert.equal(rec.crashed, true)
  Pages.openPage({ action: 'page:open', id: 'boom', props: { ok: true } })
  assert.equal(rec.crashed, false)
  assert.equal(rec.epoch, 1, 'a new epoch is a new vnode key, so the subtree really remounts')
  assert.equal(rec.error, null)
  resetTransport()
})

test('a lazy page component loader resolves and is cached', async () => {
  let calls = 0
  registerPlugin('alpha', {
    alpha: () => {
      calls++
      return Promise.resolve({ default: COMPONENT })
    },
  })
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'alpha', type: 'page', owner: 'alpha' })
  await flush()
  assert.equal(Pages.pageState().pages.alpha.component, COMPONENT)
  Pages.registerPage({ action: 'page:register', id: 'alpha', type: 'page', owner: 'alpha' })
  await flush()
  assert.equal(calls, 1)
  resetTransport()
})

// ---------------------------------------------------------------- layers

test('modals stack, the page layer stays, overlays are independent', () => {
  Pages.setPageComponent('page', COMPONENT)
  Pages.setPageComponent('m1', COMPONENT)
  Pages.setPageComponent('ov', COMPONENT)
  Pages.registerPage({ action: 'page:register', id: 'page', type: 'page' })
  Pages.registerPage({ action: 'page:register', id: 'm1', type: 'modal' })
  Pages.registerPage({ action: 'page:register', id: 'ov', type: 'overlay' })
  Pages.openPage({ action: 'page:open', id: 'page' })
  Pages.openPage({ action: 'page:open', id: 'ov' })
  Pages.openPage({ action: 'page:open', id: 'm1' })
  const s = Pages.pageState()
  assert.equal(s.openPage, 'page')
  assert.deepEqual(s.modals, ['m1'])
  assert.deepEqual(Object.keys(s.overlays), ['ov'])
  Pages.closePageAction({ id: 'm1' })
  assert.deepEqual(s.modals, [])
  assert.equal(s.openPage, 'page')
  resetTransport()
})

test('page hooks fire in the documented order', async () => {
  const seen: string[] = []
  registerPlugin('alpha', {
    alpha: {
      component: COMPONENT,
      onOpen: () => seen.push('open'),
      onUpdate: (_p: unknown, changed: readonly string[]) => seen.push('update:' + changed.join(',')),
      onClose: () => seen.push('close'),
    },
  })
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'alpha', type: 'page', owner: 'alpha' })
  Pages.openPage({ action: 'page:open', id: 'alpha', props: { a: 1 } })
  Pages.applyPatch('alpha', [{ p: 'a', v: 2 }])
  Pages.openPage({ action: 'page:open', id: 'alpha', props: { a: 3 } })
  Pages.closePageAction({ id: 'alpha' })
  assert.deepEqual(seen, ['open', 'update:a', 'update:a', 'close'])
  resetTransport()
})

test('a page whose plugin asks for shallow reactivity gets a shallowReactive props object', async () => {
  // A page id no other test has touched: `propsById` is deliberately never cleared (§7.4), so the
  // proxy flavour is decided exactly once, the first time an id is seen.
  registerPlugin('sh', { sh_page: { component: COMPONENT, reactivity: 'shallow' } })
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'sh_page', type: 'page', owner: 'sh' })
  Pages.openPage({ action: 'page:open', id: 'sh_page', props: { big: { n: 1 } } })
  const props = Pages.propsFor('sh_page')
  assert.equal(Pages.pageState().pages.sh_page.reactivity, 'shallow')
  // shallowReactive does not proxy nested values; reactive() would.
  assert.equal(isReactive(props.big as object), false)
  resetTransport()
})

test('a keepAlive page keeps its scope across a close, and loses it with its plugin (F5)', async () => {
  registerPlugin('ka', { ka_page: { component: COMPONENT, keepAlive: true } })
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'ka_page', type: 'page', owner: 'ka' })
  Pages.openPage({ action: 'page:open', id: 'ka_page', props: {} })
  assert.equal(Pages.pageState().pages.ka_page.keepAlive, true)
  const scope = Pages.pageScope('ka_page')
  assert.ok(scope)
  const epoch = Pages.keepAliveEpoch.value
  Pages.closePageAction({ id: 'ka_page' })
  assert.equal(Pages.pageScope('ka_page'), scope, 'the scope outlives the close')
  assert.equal(scope?.disposed, false)
  assert.equal(Pages.keepAliveEpoch.value, epoch, 'a close does not drop the cache')
  Plugins.unregister('ka')
  assert.equal(scope?.disposed, true, 'but the plugin going away does')
  assert.equal(Pages.keepAliveEpoch.value, epoch + 1)
  resetTransport()
})

// ---- BUG 2 (review round 2): a plugin whose setup() THROWS must not leave its pages mountable.

test('a plugin whose setup throws provides NO page definitions', async () => {
  const base = 'https://cfx-nui-bad/ui/dist/'
  modules[base + 'p.js'] = {
    default: {
      __coreUIPlugin: true, apiVersion: 1,
      pages: { bad_page: COMPONENT },
      setup: () => { throw new Error('setup exploded') },
    },
  }
  Plugins.register({
    id: 'bad', generation: 1, base,
    manifest: { id: 'bad', apiVersion: 1, entry: 'p.js', css: [], build: 'p' } as PluginManifest,
  } as MsgPluginRegister)
  await flush()
  assert.equal(Plugins.stateOf('bad'), 'failed')
  assert.equal(Plugins.pageDefinition('bad', 'bad_page'), null, 'a dead activation hands out nothing')
  assert.deepEqual(Plugins.pageIdsOf('bad'), [])

  // The page declared afterwards must not render, and opening it must fail loudly.
  Pages.registerPage({ action: 'page:register', id: 'bad_page', type: 'page', owner: 'bad' })
  assert.equal(Pages.pageState().pages.bad_page.component, null)
  posts.length = 0
  toasts.length = 0
  Pages.openPage({ action: 'page:open', id: 'bad_page', props: {} })
  const err = posts.filter((p) => p.name === 'ui_event').pop()
  assert.equal(err?.body.event, '__error')
  assert.match(String((err?.body.data as { error: string }).error), /setup exploded/)
  assert.ok(posts.some((p) => p.name === 'ui_close' && p.body.page === 'bad_page'))
  assert.equal(toasts.length, 1)
  assert.equal(Pages.pageState().openPage, null)
  resetTransport()
})

test('a page that is ALREADY mounted is unmounted and failed when its plugin dies', async () => {
  registerPlugin('flip', { flip_page: COMPONENT })
  await flush()
  Pages.registerPage({ action: 'page:register', id: 'flip_page', type: 'page', owner: 'flip' })
  Pages.openPage({ action: 'page:open', id: 'flip_page', props: {} })
  assert.equal(Pages.pageState().pages.flip_page.component, COMPONENT)
  posts.length = 0
  // A re-registration whose setup throws: the page is open WITH a component right now.
  modules['https://cfx-nui-flip/ui/dist/plugin.flip2.js'] = {
    default: {
      __coreUIPlugin: true, apiVersion: 1,
      pages: { flip_page: COMPONENT },
      setup: () => { throw new Error('setup exploded') },
    },
  }
  Plugins.register({
    id: 'flip', generation: 2, base: 'https://cfx-nui-flip/ui/dist/',
    manifest: { id: 'flip', apiVersion: 1, entry: 'plugin.flip2.js', css: [], build: 'f2' } as PluginManifest,
  } as MsgPluginRegister)
  await flush()
  assert.equal(Pages.pageState().pages.flip_page.component, null, 'the instance is gone')
  assert.ok(posts.some((p) => p.name === 'ui_event' && (p.body as { event: string }).event === '__error'))
  assert.ok(posts.some((p) => p.name === 'ui_close' && p.body.page === 'flip_page'))
  assert.equal(Pages.pageState().openPage, null)
  resetTransport()
})
