// runtime/plugins.ts — the loader state machine, driven by a fake importer (DESIGN §38.6).
// No DOM: `configurePlugins({ document: null })` turns the <link> management into a no-op.
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import * as Plugins from '../../src/runtime/plugins.ts'
import { setTransport, resetTransport } from '../../src/runtime/transport.ts'
import type { PluginManifest } from '../../sdk/src/contract.ts'
import type { MsgPluginRegister } from '../../src/runtime/protocol.ts'

const posts: Array<{ name: string; body: Record<string, unknown> }> = []
let imports: string[] = []
let modules: Record<string, unknown> = {}

function manifest(extra?: Partial<PluginManifest>): PluginManifest {
  return Object.assign({ id: 'alpha', apiVersion: 1, entry: 'plugin.aaa.js', css: [], build: 'aaa' }, extra) as PluginManifest
}

function msg(extra?: Partial<MsgPluginRegister>): MsgPluginRegister {
  return Object.assign(
    { id: 'alpha', generation: 1, base: 'https://cfx-nui-alpha/ui/dist/', manifest: manifest() },
    extra,
  ) as MsgPluginRegister
}

function plugin(def: Record<string, unknown>): Record<string, unknown> {
  return { default: Object.assign({ __coreUIPlugin: true, apiVersion: 1 }, def) }
}

const flush = () => new Promise((r) => setTimeout(r, 0))

beforeEach(() => {
  posts.length = 0
  imports = []
  modules = {}
  Plugins.resetPlugins()
  Plugins.configurePlugins({
    document: null,
    importModule: (url: string) => {
      imports.push(url)
      const mod = modules[url]
      if (!mod) return Promise.reject(new Error('404 ' + url))
      if (typeof mod === 'function') return Promise.resolve().then(() => (mod as () => unknown)() as Record<string, unknown>)
      return Promise.resolve(mod as Record<string, unknown>)
    },
  })
  setTransport({
    send(name, body) {
      posts.push({ name, body: body as Record<string, unknown> })
      return Promise.resolve({})
    },
  })
})

const lastPlugin = () => posts.filter((p) => p.name === 'ui_plugin').pop()

test('a healthy plugin reaches `ready` and reports its pages', async () => {
  let setupRan = 0
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({
    pages: { alpha: {}, alpha_hud: {} },
    setup: () => {
      setupRan++
    },
  })
  Plugins.register(msg())
  await flush()
  const rec = Plugins.get('alpha')
  assert.equal(rec?.state, 'ready')
  assert.equal(setupRan, 1)
  assert.deepEqual(rec?.pages.sort(), ['alpha', 'alpha_hud'])
  const reported = lastPlugin()
  assert.equal(reported?.body.state, 'ready')
  assert.equal(reported?.body.generation, 1)
  assert.ok(typeof reported?.body.ms === 'number')
  resetTransport()
})

test('a 404 entry fails and stays retryable', async () => {
  Plugins.register(msg())
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'failed')
  assert.match(String(lastPlugin()?.body.error), /404/)
  // The module cache dropped the failed URL, so a re-register really tries again.
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({ pages: { alpha: {} } })
  Plugins.register(msg({ generation: 2 }))
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'ready')
  assert.equal(imports.length, 2)
  resetTransport()
})

test('an entry that throws while evaluating fails with its message', async () => {
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = () => {
    throw new Error('module evaluation exploded')
  }
  Plugins.register(msg())
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'failed')
  assert.match(String(lastPlugin()?.body.error), /evaluation exploded/)
  resetTransport()
})

test('a throwing setup fails the activation, not the shell', async () => {
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({
    pages: { alpha: {} },
    setup: () => {
      throw new Error('setup exploded')
    },
  })
  Plugins.register(msg())
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'failed')
  assert.match(String(lastPlugin()?.body.error), /setup exploded/)
  resetTransport()
})

test('a manifest apiVersion the host does not speak is `incompatible`, and nothing is imported', async () => {
  Plugins.register(msg({ manifest: manifest({ apiVersion: 2 }) }))
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'incompatible')
  assert.equal(imports.length, 0)
  assert.match(String(lastPlugin()?.body.error), /built for core UI API 2, this core provides 1/)
  resetTransport()
})

test('a default export that is not a defineUIPlugin is rejected', async () => {
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = { default: { pages: {} } }
  Plugins.register(msg())
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'failed')
  assert.match(String(lastPlugin()?.body.error), /export default defineUIPlugin/)
  resetTransport()
})

test('a result for a stale generation is discarded', async () => {
  let release: (() => void) | null = null
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = () =>
    new Promise((resolve) => {
      release = () => resolve(plugin({ pages: { old: {} } }))
    })
  modules['https://cfx-nui-alpha/ui/dist/plugin.bbb.js'] = plugin({ pages: { fresh: {} } })
  Plugins.register(msg())
  await flush()
  Plugins.register(msg({ generation: 2, manifest: manifest({ entry: 'plugin.bbb.js', build: 'bbb' }) }))
  await flush()
  ;(release as unknown as () => void)()
  await flush()
  const rec = Plugins.get('alpha')
  assert.equal(rec?.generation, 2)
  assert.equal(rec?.state, 'ready')
  assert.deepEqual(rec?.pages, ['fresh'])
  // The stale activation never reported.
  assert.equal(posts.filter((p) => p.name === 'ui_plugin' && p.body.generation === 1).length, 0)
  resetTransport()
})

test('re-activating the SAME url does not re-import, but setup runs again', async () => {
  let setupRan = 0
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({
    pages: { alpha: {} },
    setup: () => {
      setupRan++
    },
  })
  Plugins.register(msg())
  await flush()
  Plugins.register(msg({ generation: 2 }))
  await flush()
  assert.equal(imports.length, 1)
  assert.equal(setupRan, 2)
  assert.equal(Plugins.get('alpha')?.generation, 2)
  resetTransport()
})

test('a new build url imports again', async () => {
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({ pages: { alpha: {} } })
  modules['https://cfx-nui-alpha/ui/dist/plugin.ccc.js'] = plugin({ pages: { alpha: {}, extra: {} } })
  Plugins.register(msg())
  await flush()
  Plugins.register(msg({ generation: 2, manifest: manifest({ entry: 'plugin.ccc.js', build: 'ccc' }) }))
  await flush()
  assert.deepEqual(imports, [
    'https://cfx-nui-alpha/ui/dist/plugin.aaa.js',
    'https://cfx-nui-alpha/ui/dist/plugin.ccc.js',
  ])
  assert.deepEqual(Plugins.get('alpha')?.pages.sort(), ['alpha', 'extra'])
  resetTransport()
})

test('unregister disposes the scope and runs the setup disposer first', async () => {
  const order: string[] = []
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({
    pages: { alpha: {} },
    setup: (ctx: { scope: { onDispose(f: () => void): void } }) => {
      ctx.scope.onDispose(() => order.push('scope'))
      return () => order.push('disposer')
    },
  })
  Plugins.register(msg())
  await flush()
  const disposed: string[] = []
  const offHook = Plugins.onPluginDispose((id) => disposed.push(id))
  Plugins.unregister('alpha')
  offHook()
  assert.deepEqual(order, ['disposer', 'scope'])
  assert.deepEqual(disposed, ['alpha'])
  assert.equal(Plugins.get('alpha'), undefined)
  resetTransport()
})

test('a lazy plugin waits for ensureActivated', async () => {
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({ pages: { alpha: {} } })
  Plugins.register(msg({ manifest: manifest({ load: 'lazy' }) }))
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'registered')
  assert.equal(imports.length, 0)
  Plugins.ensureActivated('alpha')
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'ready')
  resetTransport()
})

test('a function value in `pages` is kept as a loader, never called at registration', async () => {
  let calls = 0
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({
    pages: {
      alpha: () => {
        calls++
        return Promise.resolve({ default: { name: 'Lazy' } })
      },
    },
  })
  Plugins.register(msg())
  await flush()
  assert.equal(calls, 0)
  assert.equal(typeof Plugins.pageDefinition('alpha', 'alpha')?.component, 'function')
  resetTransport()
})

test('whenSettled resolves for a ready plugin and for a failed one', async () => {
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({ pages: { alpha: {} } })
  Plugins.register(msg())
  const settled = await Plugins.whenSettled('alpha')
  assert.equal(settled?.state, 'ready')
  Plugins.register(msg({ id: 'beta', generation: 1, base: 'https://cfx-nui-beta/ui/dist/', manifest: manifest({ id: 'beta' }) }))
  const failed = await Plugins.whenSettled('beta')
  assert.equal(failed?.state, 'failed')
  assert.equal(await Plugins.whenSettled('nobody'), null)
  resetTransport()
})

test('css and the entry module load in PARALLEL (F6)', async () => {
  const order: string[] = []
  let releaseCss: (() => void) | null = null
  Plugins.configurePlugins({
    document: {
      head: { appendChild: () => {} },
      querySelectorAll: () => [],
      createElement: () => {
        const el: Record<string, unknown> = {}
        el.setAttribute = () => {}
        // Hand the test the stylesheet's "load" callback instead of firing it.
        Object.defineProperty(el, 'onload', {
          set(fn: () => void) {
            releaseCss = () => {
              order.push('css')
              fn()
            }
          },
        })
        return el
      },
    } as unknown as Document,
    importModule: (url: string) => {
      order.push('import:' + url.split('/').pop())
      return Promise.resolve(plugin({ pages: { alpha: {} } }))
    },
  })
  Plugins.register(msg({ manifest: manifest({ css: ['plugin.aaa.css'] }) }))
  await flush()
  // The import was issued without waiting for the stylesheet.
  assert.deepEqual(order, ['import:plugin.aaa.js'])
  assert.equal(Plugins.stateOf('alpha'), 'loading')
  ;(releaseCss as unknown as () => void)()
  await flush()
  assert.deepEqual(order, ['import:plugin.aaa.js', 'css'])
  assert.equal(Plugins.stateOf('alpha'), 'ready')
  resetTransport()
})

test('an async setup warns once and its rejection is attributed (F7)', async () => {
  const realWarn = console.warn
  const warnings: string[] = []
  console.warn = (...args: unknown[]) => warnings.push(args.join(' '))
  modules['https://cfx-nui-alpha/ui/dist/plugin.aaa.js'] = plugin({
    pages: { alpha: {} },
    setup: () => Promise.reject(new Error('async boom')),
  })
  Plugins.register(msg())
  await flush()
  await flush()
  console.warn = realWarn
  assert.equal(Plugins.stateOf('alpha'), 'ready', 'an async setup does not fail the plugin')
  assert.equal(warnings.length, 1)
  assert.match(warnings[0], /setup\(\) must be synchronous/)
  const errs = posts.filter((p) => p.name === 'ui_error')
  assert.equal(errs.length, 1)
  assert.equal(errs[0].body.plugin, 'alpha')
  assert.equal(errs[0].body.info, 'async setup')
  resetTransport()
})

test('a dev hot update RE-ACTIVATES the plugin: old disposer, new setup (F8)', async () => {
  const seen: string[] = []
  let version = 1
  Plugins.configurePlugins({
    document: null,
    importModule: (url: string) => {
      if (url.indexOf('@vite/client') !== -1) return Promise.resolve({})
      const n = version
      return Promise.resolve(plugin({
        pages: { alpha: {} },
        setup: () => {
          seen.push('setup:' + n)
          return () => seen.push('dispose:' + n)
        },
      }))
    },
  })
  Plugins.register(msg({ dev: { origin: 'http://localhost:5199' } }))
  await flush()
  assert.equal(Plugins.stateOf('alpha'), 'ready')
  assert.deepEqual(seen, ['setup:1'])
  const firstUrl = Plugins.get('alpha')?.url
  version = 2
  await Plugins.reloadDevPlugins()
  assert.deepEqual(seen, ['setup:1', 'dispose:1', 'setup:2'])
  assert.equal(Plugins.stateOf('alpha'), 'ready', 'the record survives a hot update')
  assert.notEqual(Plugins.get('alpha')?.url, firstUrl, 'a fresh ?t= busts the dev module')
  resetTransport()
})

test('a burst of HMR callbacks coalesces into ONE re-activation (F8)', async () => {
  let setups = 0
  Plugins.configurePlugins({
    document: null,
    importModule: (url: string) =>
      url.indexOf('@vite/client') !== -1
        ? Promise.resolve({})
        : Promise.resolve(plugin({ pages: { alpha: {} }, setup: () => { setups++ } })),
  })
  Plugins.register(msg({ dev: { origin: 'http://localhost:5199' } }))
  await flush()
  assert.equal(setups, 1)
  Plugins.scheduleDevReload()
  Plugins.scheduleDevReload()
  Plugins.scheduleDevReload()
  await new Promise((r) => setTimeout(r, 80))
  assert.equal(setups, 2, 'three Vite callbacks, one re-activation')
  resetTransport()
})
