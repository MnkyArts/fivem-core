// The facade (`@core/ui`) and the virtual `vue` module — the two pieces of the SDK that end up
// inside every plugin bundle (DESIGN §38.3, §38.7).
//
// The facade is exercised as the artifact a plugin really gets: esbuild-bundled, minified, imported
// from a file URL. That also measures what it costs (< 2 KB is the contract).

import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import esbuild from 'esbuild'
import { SDK_DIR } from './helpers.mjs'
import { vueShimSource } from '../vite/index.mjs'

const HOST_GLOBAL = '__CORE_UI_HOST__'
let tmp
let sdk
let minifiedBytes

describe('@core/ui facade', () => {
  before(async () => {
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'core-ui-facade-'))
    const out = path.join(tmp, 'facade.js')
    const res = await esbuild.build({
      entryPoints: [path.join(SDK_DIR, 'src/index.ts')],
      bundle: true,
      minify: true,
      format: 'esm',
      platform: 'browser',
      target: 'chrome103',
      outfile: out,
      logLevel: 'silent',
    })
    assert.equal(res.errors.length, 0)
    minifiedBytes = fs.statSync(out).size
    sdk = await import(pathToFileURL(out).href)
  })
  after(() => { fs.rmSync(tmp, { recursive: true, force: true }); delete globalThis[HOST_GLOBAL] })

  it('costs less than 2 KB minified', () => {
    assert.ok(minifiedBytes < 2048, `the facade is ${minifiedBytes} B minified — the budget is 2048 B`)
  })

  it('carries no runtime state and no host access at module scope', () => {
    // Importing it above already proved that: there is no host on globalThis yet.
    assert.equal(globalThis[HOST_GLOBAL], undefined)
    assert.equal(sdk.API_VERSION, 1)
    assert.equal(sdk.HOST_GLOBAL, HOST_GLOBAL)
  })

  it('defineUIPlugin is pure and stamps the API version', () => {
    const pages = { alpha: {} }
    const setup = () => {}
    const def = sdk.defineUIPlugin({ pages, setup })
    assert.equal(def.__coreUIPlugin, true)
    assert.equal(def.apiVersion, sdk.API_VERSION)
    assert.equal(def.pages, pages)
    assert.equal(def.setup, setup)
  })

  it('definePage hands the definition back untouched', () => {
    const def = { component: {}, keepAlive: true }
    assert.equal(sdk.definePage(def), def)
  })

  it('every host-backed export throws one clear error without a shell', () => {
    const expected = /^\[core:ui\] no host — @core\/ui used outside the core shell \(or before it booted\)$/
    for (const name of ['usePage', 'useNui', 'useScope', 'useFeed', 'useHud', 'usePlayerState', 'useStats', 't', 'notify', 'playSound', 'registerIcons']) {
      assert.throws(() => sdk[name]('x'), (err) => expected.test(err.message), `${name} did not throw the no-host error`)
    }
  })

  it('resolves the host at CALL time, not at import time', () => {
    const calls = []
    globalThis[HOST_GLOBAL] = {
      apiVersion: 1,
      usePage: (id) => ({ id, props: {} }),
      useNui: (c) => ({ channel: c || 'alpha' }),
      useScope: () => ({ disposed: false }),
      useFeed: () => ({}),
      hud: { cash: 5 },
      state: { 'trucking:active': true },
      stats: { hunger: { value: 3 } },
      t: (k, v) => { calls.push(['t', k, v]); return 'T:' + k },
      notify: (m, type) => calls.push(['notify', m, type]),
      playSound: (n, s) => calls.push(['sound', n, s]),
      registerIcons: (i) => calls.push(['icons', i]),
    }
    assert.equal(sdk.usePage('alpha').id, 'alpha')
    assert.equal(sdk.useNui().channel, 'alpha')
    assert.equal(sdk.useScope().disposed, false)
    assert.equal(sdk.useHud().cash, 5)
    assert.equal(sdk.usePlayerState()['trucking:active'], true)
    assert.equal(sdk.useStats().hunger.value, 3)
    assert.equal(sdk.t('hello', { a: 1 }), 'T:hello')
    sdk.notify('saved', 'success')
    sdk.playSound('click', null)
    sdk.registerIcons({ x: 'M0 0' })
    assert.deepEqual(calls.map((c) => c[0]), ['t', 'notify', 'sound', 'icons'])
    delete globalThis[HOST_GLOBAL]
  })

  it('NuiError identifies an error the shell created from its own copy of the class', () => {
    const mine = new sdk.NuiError('timeout', 'took too long')
    assert.equal(mine.name, 'NuiError')
    assert.equal(mine.code, 'timeout')
    assert.equal(mine.message, 'took too long')
    assert.ok(mine instanceof Error)
    assert.ok(mine instanceof sdk.NuiError)
    // What the shell's own bundle would hand over: same shape, different class object.
    const fromShell = Object.assign(new Error('gone'), { name: 'NuiError', code: 'resource_stopped' })
    assert.ok(fromShell instanceof sdk.NuiError, 'a cross-copy NuiError is not recognised')
    assert.ok(!(new Error('plain') instanceof sdk.NuiError))
  })
})

describe('virtual vue module', () => {
  it('re-exports the host namespace with PURE annotations so Rollup can drop what is unused', () => {
    const src = vueShimSource(['ref', 'computed', 'h'])
    assert.match(src, /globalThis\.__CORE_UI_HOST__/)
    assert.match(src, /export const ref = \/\*#__PURE__\*\/ \(\(\) => V\.ref\)\(\);/)
    assert.match(src, /export const computed = \/\*#__PURE__\*\/ \(\(\) => V\.computed\)\(\);/)
    assert.match(src, /export default V;/)
    assert.match(src, /only runs inside the core shell/)
  })

  it('has a plain form for the esbuild dep optimizer', () => {
    const src = vueShimSource(['ref'], { pure: false })
    assert.match(src, /export const ref = V\.ref;/)
    assert.ok(!src.includes('__PURE__'))
  })

  it('throws immediately when there is no host', async () => {
    const src = vueShimSource(['ref'])
    await assert.rejects(
      () => import('data:text/javascript;charset=utf-8,' + encodeURIComponent(src)),
      /no __CORE_UI_HOST__\.vue/,
    )
  })
})
