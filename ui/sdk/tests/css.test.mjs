// The emitted stylesheet: opacity modifiers and where the candidates come from (DESIGN §37.4, §38.3).
//
// `bg-accent/10` is the idiom core's docs teach, and Tailwind compiles it to a literal fallback
// declaration plus the `color-mix()` form inside `@supports (color: color-mix(…))` — which is
// exactly what Chromium 103 needs. The build lint therefore judges the sheet the way
// ui/tests/kit-regression §11 judges core's: an UNGUARDED color-mix is the bug, a guarded one is
// the fix.

import { after, before, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import { buildError, buildPlugin, cleanupAll, makePlugin } from './helpers.mjs'

const OPACITY_PAGE = `<template>
  <div class="alpha-panel bg-panel/50 text-accent/80 border-border-strong/40 bg-error/15 px-8"></div>
</template>
`

describe('opacity modifiers on tokens', () => {
  let css
  let out

  before(async () => {
    const p = makePlugin({ resource: 'alpha', files: { 'ui/src/Page.vue': OPACITY_PAGE } })
    out = await buildPlugin(p.uiDir)
    css = out.css()
  })
  after(() => cleanupAll())

  it('builds instead of tripping the Chromium 103 lint', () => {
    assert.equal(out.manifest.id, 'alpha')
  })

  it('emits the literal fallback declaration first, with the right alpha', () => {
    // --color-panel rgba(11,17,22,.90) at 50% -> #0b1116 at .45 -> 73
    assert.ok(css.includes('.bg-panel\\/50{background-color:#0b111673}'), css)
    // --color-accent #f6503f at 80% -> cc
    assert.ok(css.includes('.text-accent\\/80{color:#f6503fcc}'), css)
    // --color-border-strong rgba(255,255,255,.22) at 40% -> #ffffff at .088 -> 16
    assert.ok(css.includes('.border-border-strong\\/40{border-color:#ffffff16}'), css)
  })

  it('puts every color-mix() inside the @supports guard, over the token variable', () => {
    const guards = css.match(/@supports \(color:color-mix\(in lab,red,red\)\)\{/g) || []
    assert.ok(guards.length >= 4, `expected one guard per modifier, got ${guards.length}`)
    for (const decl of css.match(/[^;{}@]*color-mix\(in oklab[^;}]*/g) || []) {
      assert.match(decl, /var\(--color-[a-z-]+,\s*#/, 'the color-mix must read the token with a literal fallback')
    }
    // Nothing outside a guard.
    const withoutGuards = css.replace(/@supports \(color:color-mix\(in lab,red,red\)\)\{[^}]*\}\}/g, '')
    assert.ok(!withoutGuards.includes('color-mix('), 'an unguarded color-mix survived')
  })

  it('still fails the build for a color-mix the plugin wrote itself', async () => {
    const p = makePlugin({
      resource: 'alpha',
      files: {
        'ui/src/Page.vue': `<template><div class="alpha-panel"></div></template>
<style scoped>
.alpha-panel { background: ${'color-' + 'mix'}(in srgb, #fff 50%, #000); }
</style>
`,
      },
    })
    const err = await buildError(p.uiDir)
    assert.match(err, /\[core-ui\] alpha: /)
    assert.match(err, /not in Chromium 103/)
  })
})

describe('candidate sources', () => {
  after(() => cleanupAll())

  it('never scans .core-ui/ or dist/, so a stale artefact cannot change the build', async () => {
    const p = makePlugin({ resource: 'alpha' })
    const first = await buildPlugin(p.uiDir)

    // What the migration hit: an old optimizer chunk and yesterday's bundle, both full of class
    // candidates the sources no longer contain.
    fs.mkdirSync(path.join(p.uiDir, '.core-ui/vite-cache'), { recursive: true })
    fs.writeFileSync(path.join(p.uiDir, '.core-ui/vite-cache/stale.js'), 'const a = "z-[9999] bg-info/25 underline"\n')
    fs.writeFileSync(path.join(p.uiDir, 'dist/old.js'), 'const b = "decoration-wavy tracking-eyebrow"\n')

    const second = await buildPlugin(p.uiDir)
    assert.equal(second.manifestRaw, first.manifestRaw, 'the build id drifted because of a stale artefact')
    const css = second.css()
    for (const stray of ['z-\\[9999\\]', 'decoration-wavy', 'bg-info\\/25']) {
      assert.ok(!css.includes(stray), `${stray} leaked into the sheet`)
    }
  })
})
