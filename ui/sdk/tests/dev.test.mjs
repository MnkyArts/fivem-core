// The two dev modes of `coreUI()` (DESIGN §38.11). Config only — no server is started.
//
//   vite              browser dev host: core's real shell runs in THIS Vite graph, so there is one
//                     Vue by construction and `vue` must NOT be redirected to the host shim.
//   vite --mode game  attached: the in-game shell (origin nui://core) imports from this server.
//   vite build        always the host shim.

import { after, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { resolveConfig } from 'vite'
import { coreUI } from '../vite/index.mjs'
import { cleanupAll, makePlugin } from './helpers.mjs'

const RESOLVED_VUE = '\0virtual:core-ui/vue'

async function resolve(uiDir, command, mode, options = {}) {
  const plugins = coreUI(options)
  const config = await resolveConfig({ root: uiDir, configFile: false, logLevel: 'silent', plugins }, command, mode)
  return { config, core: plugins[0] }
}

describe('dev modes', () => {
  after(() => cleanupAll())

  it('browser dev host: no vue redirection, SDK alias, generated CSS entry, workspace fs access', async () => {
    const p = makePlugin({ resource: 'alpha' })
    const { config, core } = await resolve(p.uiDir, 'serve', 'development')
    assert.equal(core.resolveId('vue', p.uiDir), null, 'vue was redirected in the browser dev host')
    assert.equal(core.resolveId('@vue/runtime-core', p.uiDir), null)
    assert.equal(core.resolveId('virtual:core-ui/vue', p.uiDir), RESOLVED_VUE, 'the virtual module must stay addressable')
    assert.ok(config.resolve.alias.some((a) => String(a.find) === '/^@core\\/ui$/' && a.replacement.endsWith('sdk/src/index.ts')))
    // The npm workspace root (here: the temp "resources" dir, in the repo: resources/). node_modules
    // is a symlink into it and Vite resolves symlinks, so without this every bare import 403s.
    assert.ok(config.server.fs.allow.includes(p.tmp), `fs.allow ${config.server.fs.allow} does not cover ${p.tmp}`)
    assert.equal(config.cacheDir, path.join(p.uiDir, '.core-ui/vite-cache'))
    assert.ok(fs.existsSync(path.join(p.uiDir, '.core-ui/entry.css')))
    assert.equal(fs.readFileSync(path.join(p.uiDir, '.core-ui/.gitignore'), 'utf8'), '*\n')
    assert.ok(!(config.optimizeDeps.exclude || []).includes('vue'), 'vue must stay pre-bundled in the browser dev host')
  })

  it('attached mode: host shim, fixed origin, strict port, its own HMR socket', async () => {
    const p = makePlugin({ resource: 'alpha' })
    const { config, core } = await resolve(p.uiDir, 'serve', 'game', { port: 5199 })
    assert.equal(core.resolveId('vue', p.uiDir), RESOLVED_VUE)
    assert.equal(core.resolveId('@vue/reactivity', p.uiDir), RESOLVED_VUE)
    assert.equal(core.resolveId('vue', RESOLVED_VUE), null, 'the shim itself must not be redirected')
    assert.equal(config.server.port, 5199)
    assert.equal(config.server.strictPort, true)
    assert.equal(config.server.origin, 'http://localhost:5199')
    assert.deepEqual(config.server.hmr, { protocol: 'ws', host: 'localhost', port: 5199 })
    assert.equal(config.server.cors, true)
    for (const pkg of ['vue', '@vue/runtime-dom', '@vue/runtime-core', '@vue/reactivity']) {
      assert.ok(config.optimizeDeps.exclude.includes(pkg), `${pkg} is not excluded from the dep optimizer`)
    }
    // The dep optimizer resolves with esbuild, not with Vite's plugin container: without this
    // second shim a pre-bundled dependency quietly loads its own Vue (P1 V6).
    assert.ok(config.optimizeDeps.esbuildOptions.plugins.some((x) => x.name === 'core-ui-vue-host'))
    const shim = core.load(RESOLVED_VUE)
    assert.match(shim.code, /export const ref = \/\*#__PURE__\*\//)
    assert.equal(shim.moduleSideEffects, false)
  })

  it('build always uses the host shim', async () => {
    const p = makePlugin({ resource: 'alpha' })
    const { config, core } = await resolve(p.uiDir, 'build', 'production')
    assert.equal(core.resolveId('vue', p.uiDir), RESOLVED_VUE)
    assert.equal(config.build.target, 'chrome103')
    assert.equal(config.build.cssCodeSplit, false)
    assert.equal(config.build.assetsInlineLimit, 0)
    assert.equal(config.build.emptyOutDir, true)
    assert.equal(config.base, './')
    assert.equal(config.build.rollupOptions.preserveEntrySignatures, 'strict')
  })

  it('injects the generated stylesheet into the entry, once', async () => {
    const p = makePlugin({ resource: 'alpha' })
    const { core } = await resolve(p.uiDir, 'build', 'production')
    const entry = path.join(p.uiDir, 'src/index.ts')
    const out = core.transform('export default 1\n', entry)
    assert.ok(out.code.startsWith(`import ${JSON.stringify(path.join(p.uiDir, '.core-ui/entry.css'))};`))
    assert.equal(core.transform(out.code, entry), null, 'the import was injected twice')
    assert.equal(core.transform('export default 1\n', path.join(p.uiDir, 'src/other.ts')), null)
  })

  it('the generated stylesheet references core tokens and emits utilities only', async () => {
    const p = makePlugin({ resource: 'alpha' })
    await resolve(p.uiDir, 'build', 'production')
    const css = fs.readFileSync(path.join(p.uiDir, '.core-ui/entry.css'), 'utf8')
    assert.match(css, /@layer properties, theme, base, components, utilities;/)
    // Tailwind's own files are named by ABSOLUTE path, resolved from the SDK: `.core-ui/` is not
    // next to the install in a plugin outside the workspace (or in CI, or in a temp fixture).
    assert.match(css, /@import "\/[^"]*tailwindcss\/theme\.css" theme\(reference\);/)
    assert.match(css, /@import "\/[^"]*sdk\/theme\.css" theme\(reference\);/)
    // `source(none)`: only the explicit @source below may contribute candidates, so a stale file
    // under .core-ui/ or dist/ can never change the sheet (or its content hash).
    assert.match(css, /@import "\/[^"]*tailwindcss\/utilities\.css" layer\(utilities\) source\(none\);/)
    assert.match(css, /@source not ".*\.core-ui\/\*\*";/)
    assert.match(css, /@source not ".*\/dist\/\*\*";/)
    assert.ok(!css.includes('preflight'), 'the plugin sheet must never pull preflight')
  })
})
