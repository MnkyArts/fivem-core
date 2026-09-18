// The happy path of `coreUI()` — what a plugin's `npm run build` must produce (DESIGN §38.3, §38.13).
//
//   node --test ui/sdk/tests/
//
// Every case builds the `alpha` fixture for real with Vite's JS API, in a temp copy laid out as
// `<tmp>/<resource>/ui`. Nothing is written into the repository.

import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { buildPlugin, cleanupAll, hasPackage, makePlugin } from './helpers.mjs'

describe('coreUI() build output', () => {
  let out
  let fixture

  before(async () => {
    fixture = makePlugin({ resource: 'alpha' })
    out = await buildPlugin(fixture.uiDir)
  })
  after(() => cleanupAll())

  it('emits a manifest with every field DESIGN §38.3 lists', () => {
    const m = out.manifest
    assert.equal(m.id, 'alpha')
    assert.equal(m.apiVersion, 1)
    assert.match(m.entry, /^plugin\.[A-Za-z0-9_-]+\.js$/)
    assert.equal(m.css.length, 1)
    assert.match(m.css[0], /^plugin\.[A-Za-z0-9_-]+\.css$/)
    assert.match(m.build, /^[0-9a-f]{10}$/)
    assert.equal(m.load, 'eager')
    assert.deepEqual(m.pages, ['alpha', 'alpha_lazy'])
    assert.equal(m.sdk, '1.0.0')
    assert.match(m.vue, /^3\./)
    assert.ok(m.preload.every((f) => f.startsWith('chunks/')))
  })

  it('names every output by content hash and writes nothing else', () => {
    for (const f of out.files) {
      assert.ok(
        f === 'manifest.json' || /\.[A-Za-z0-9_-]{8,}\.(js|css|png)$/.test(f),
        `${f} is not content-hashed — an ES module URL is pinned in the module map for the life of the page`,
      )
    }
  })

  it('is deterministic: the same sources rebuild to a byte-identical manifest', async () => {
    const again = await buildPlugin(fixture.uiDir)
    assert.equal(again.manifestRaw, out.manifestRaw)
    assert.deepEqual(again.files, out.files)
  })

  it('keeps the entry default export (preserveEntrySignatures)', () => {
    const entry = out.read(out.manifest.entry)
    assert.ok(/export\s*\{[^}]*as default/.test(entry) || /export\s+default/.test(entry),
      'the entry has no default export — Vite\'s app-build default dropped it')
    // The stamped object itself may live in a shared chunk (Rollup hoists what the lazy page also
    // uses); what must not move is the entry's default export.
    assert.ok(/__coreUIPlugin\s*:\s*(?:!0|true)/.test(out.js()), 'no defineUIPlugin object anywhere in the bundle')
  })

  it('ships no Vue runtime — the host provides the one Vue', () => {
    const js = out.js()
    for (const needle of ['createRenderer', 'baseCreateRenderer', '__v_isRef', '__v_skip', '__v_isShallow', 'EffectScope']) {
      assert.ok(!js.includes(needle), `${needle} is in the bundle — a second Vue means a second reactivity graph`)
    }
    assert.ok(js.includes('__CORE_UI_HOST__'), 'the bundle does not read the host object')
  })

  it('emits utilities only: no preflight, no :root block, no kit class', () => {
    const css = out.css()
    assert.ok(css.includes('@layer utilities{'), 'no utilities layer')
    assert.ok(css.includes('.bg-panel{background-color:var(--color-panel'), 'the token utility is missing or not token-based')
    assert.ok(css.includes('.px-8{'), 'an ordinary utility is missing')
    assert.ok(!css.includes(':root'), 'the token block leaked into the plugin sheet')
    assert.ok(!css.includes('@theme'), '@theme leaked into the plugin sheet')
    assert.ok(!css.includes('.core-btn'), 'a kit class leaked into the plugin sheet')
    assert.ok(!css.includes('box-sizing:border-box'), 'preflight leaked into the plugin sheet')
  })

  it('compiles a scoped @apply block through @core/ui/reference.css and emits no CSS for it', () => {
    const css = out.css()
    const scoped = /\.alpha-panel\[data-v-[0-9a-f]+\]\{([^}]*)\}/.exec(css)
    assert.ok(scoped, 'the scoped rule is missing')
    assert.match(scoped[1], /background-color:var\(--color-panel/)
    assert.match(scoped[1], /border-radius:var\(--radius-ui/)
    assert.match(scoped[1], /color:var\(--color-fg-dim/)
    assert.match(scoped[1], /letter-spacing:3px/)
    // @reference must contribute NOTHING of its own.
    assert.equal(css.match(/@layer utilities\{/g).length, 1)
  })

  it('keeps asset URLs relative to the plugin origin', () => {
    const css = out.css()
    assert.match(css, /url\(\.\/assets\/logo\.[A-Za-z0-9_-]+\.png\)/)
    assert.ok(out.files.some((f) => /^assets\/logo\.[A-Za-z0-9_-]+\.png$/.test(f)), 'the asset was inlined instead of emitted')
    const js = out.js()
    assert.ok(js.includes('import.meta.url'), 'the JS asset URL is not built from import.meta.url')
    assert.ok(!js.includes('data:image/png;base64'), 'an asset was base64-inlined')
  })

  it('puts a lazy page in chunks/ and keeps it OUT of preload', () => {
    assert.ok(out.files.some((f) => /^chunks\/Lazy\.[A-Za-z0-9_-]+\.js$/.test(f)), `no lazy chunk in ${out.files.join(', ')}`)
    // Preloading it would undo `definePage({ component: () => import(…) })`.
    assert.deepEqual(out.manifest.preload.filter((f) => f.startsWith('chunks/Lazy.')), [])
    // Everything that IS listed must be reachable from the entry through static imports only.
    const entry = out.read(out.manifest.entry)
    const statics = [...entry.matchAll(/from\s*["']\.\/([^"']+)["']|import\s*["']\.\/([^"']+)["']/g)].map((m) => m[1] || m[2])
    for (const f of out.manifest.preload) assert.ok(statics.includes(f), `${f} is preloaded but not statically imported by the entry`)
  })

  // `@lucide/vue` reaches this repo through the inventory plugin's own dependencies, so it exists in
  // the npm workspace and NOT in a lone checkout of core (CI installs `ui/package.json` only).
  it('lists a statically imported vendor chunk for preload', { skip: hasPackage('@lucide/vue') ? false : '@lucide/vue is not installed in this layout' }, async () => {
    const withVendor = makePlugin({
      resource: 'delta',
      files: {
        'ui/src/index.ts': `import { defineUIPlugin } from '@core/ui'
import { Search } from '@lucide/vue'
import Page from './Page.vue'
export default defineUIPlugin({ pages: { delta: Page }, setup(ctx) { ctx.log(Search) } })\n`,
      },
    })
    const built = await buildPlugin(withVendor.uiDir, { vendorChunk: true })
    const vendor = built.files.find((f) => /^chunks\/vendor\.[A-Za-z0-9_-]+\.js$/.test(f))
    assert.ok(vendor, `no vendor chunk in ${built.files.join(', ')}`)
    assert.ok(built.manifest.preload.includes(vendor), `preload ${JSON.stringify(built.manifest.preload)} is missing the vendor chunk`)
    assert.ok(built.manifest.preload.every((f) => !f.startsWith('chunks/Lazy.')), 'the lazy chunk is preloaded again')
  })

  it('warns about nothing when the fxmanifest is complete', () => {
    assert.deepEqual(out.warnings.filter((w) => w.includes('fxmanifest')), [])
  })

  it('honours load: lazy and vendorChunk', async () => {
    const lazy = makePlugin({ resource: 'gamma' })
    const built = await buildPlugin(lazy.uiDir, { load: 'lazy', vendorChunk: true })
    assert.equal(built.manifest.load, 'lazy')
    assert.equal(built.manifest.id, 'gamma')
  })
})
