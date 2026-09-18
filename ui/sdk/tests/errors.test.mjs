// The build refuses to ship a plugin that would fail in game (DESIGN §38.13). Every message names
// the resource, because a plugin build runs in a folder whose name is the only identity it has.
//
// The banned-CSS needles below are assembled from pieces for the reason ui/tests/kit-compile-check
// states: Tailwind scans this tree, and a literal that reads like a utility would be compiled INTO
// a bundle.

import { after, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import path from 'node:path'
import { buildError, buildPlugin, cleanupAll, makePlugin } from './helpers.mjs'

const SCROLLBAR = 'scrollbar-' + 'width'

describe('build errors', () => {
  after(() => cleanupAll())

  it('refuses a root that is not <resource>/ui', async () => {
    const p = makePlugin({ resource: 'alpha' })
    const err = await buildError(p.dir)
    assert.match(err, /\[core-ui\]/)
    assert.ok(err.includes(p.dir), `the message does not name the folder: ${err}`)
    assert.match(err, /is not a <resource>\/ui folder/)
  })

  it('refuses an options.id that is not the resource name', async () => {
    const p = makePlugin({ resource: 'alpha' })
    const err = await buildError(p.uiDir, { id: 'beta' })
    assert.match(err, /\[core-ui\] alpha: options\.id 'beta' does not match the resource folder 'alpha'/)
  })

  it('refuses a ui folder without an entry', async () => {
    const p = makePlugin({ resource: 'alpha', remove: ['ui/src/index.ts'] })
    const err = await buildError(p.uiDir)
    assert.match(err, /\[core-ui\] alpha: no entry/)
    assert.match(err, /src\/index\.ts/)
  })

  it('refuses an output path over the 255-char vfs limit', async () => {
    const resource = 'a'.repeat(220)
    const p = makePlugin({ resource })
    const err = await buildError(p.uiDir)
    // Rollup prefixes the throwing plugin's name; the message itself is ours.
    assert.ok(err.includes(`[core-ui] ${resource}: `), err.slice(0, 160))
    assert.match(err, /the vfs path is \d+ chars — FiveM cuts at 255/)
  })

  it('refuses CSS that uses a Chromium-103-banned feature', async () => {
    const p = makePlugin({
      resource: 'alpha',
      files: {
        'ui/src/extra.css': `.alpha-scroll { ${SCROLLBAR}: thin; }\n`,
        'ui/src/index.ts': `import './extra.css'\nimport { defineUIPlugin } from '@core/ui'\nimport Page from './Page.vue'\nexport default defineUIPlugin({ pages: { alpha: Page } })\n`,
      },
    })
    const err = await buildError(p.uiDir)
    assert.match(err, /\[core-ui\] alpha: /)
    assert.ok(err.includes(SCROLLBAR), err)
    assert.match(err, /Chromium 103/)
  })

  it('only WARNS about a banned feature inside a JS string — a dependency must not block the build', async () => {
    const p = makePlugin({
      resource: 'alpha',
      files: {
        'ui/src/index.ts': `import { defineUIPlugin } from '@core/ui'
import Page from './Page.vue'
export const injected = '.alpha-scroll{${SCROLLBAR}:thin}'
export default defineUIPlugin({ pages: { alpha: Page }, setup(ctx) { ctx.log(injected) } })\n`,
      },
    })
    const out = await buildPlugin(p.uiDir)
    assert.equal(out.manifest.id, 'alpha')
    const hits = out.warnings.filter((w) => w.includes('(embedded CSS)'))
    assert.equal(hits.length, 1, `expected one warning, got ${out.warnings.length}: ${out.warnings.join(' | ')}`)
    assert.ok(hits[0].includes('[core-ui] alpha: '), hits[0])   // Vite prefixes the plugin name
    assert.ok(hits[0].includes(SCROLLBAR), hits[0])
  })

  it('does not mistake an ordinary object literal for CSS', async () => {
    const p = makePlugin({
      resource: 'alpha',
      files: {
        'ui/src/index.ts': `import { defineUIPlugin } from '@core/ui'
import Page from './Page.vue'
export const anim = { rotate: 90, scale: 2, translate: '10px' }
export default defineUIPlugin({ pages: { alpha: Page }, setup(ctx) { ctx.log(anim.rotate) } })\n`,
      },
    })
    const out = await buildPlugin(p.uiDir)
    assert.equal(out.manifest.id, 'alpha')
  })
})

describe('fxmanifest warnings', () => {
  after(() => cleanupAll())

  it('warns about a missing core_ui key, missing files coverage and a greedy client_script glob', async () => {
    const p = makePlugin({
      resource: 'alpha',
      files: {
        'fxmanifest.lua': `fx_version 'cerulean'
game 'gta5'
-- core_ui 'ui/dist'   (commented out: a comment must not satisfy the check)
client_scripts { '**/*.js' }
files { 'locales/*.json' }
`,
      },
    })
    const out = await buildPlugin(p.uiDir)
    const w = out.warnings.join('\n')
    assert.match(w, /has no `core_ui 'ui\/dist'` line/)
    assert.match(w, /no `files` entry covering ui\/dist/)
    assert.match(w, /client_script glob '\*\*\/\*\.js' can match inside ui\/dist/)
  })

  it('warns when the resource has no fxmanifest at all', async () => {
    const p = makePlugin({ resource: 'alpha', remove: ['fxmanifest.lua'] })
    const out = await buildPlugin(p.uiDir)
    assert.ok(out.warnings.some((x) => x.includes('no fxmanifest.lua in ' + path.dirname(p.uiDir))), out.warnings.join(' | '))
  })
})
