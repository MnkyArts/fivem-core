// Static `pages` extraction (DESIGN §38.3): the build reads the page ids out of the entry's
// `defineUIPlugin({ pages })` so the manifest, the workspace check and Lua's validator can all see
// them without running the bundle. Lua's `Core.UI.registerPage` stays the authority.

import { after, describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { buildError, buildPlugin, cleanupAll, makePlugin } from './helpers.mjs'

const entry = (body) => `import Page from './Page.vue'\n${body}\n`

async function pagesOf(files, options) {
  const p = makePlugin({ resource: 'alpha', files })
  return buildPlugin(p.uiDir, options)
}

describe('pages extraction', () => {
  after(() => cleanupAll())

  it('reads a named import under an alias', async () => {
    const out = await pagesOf({
      'ui/src/index.ts': entry(`import { defineUIPlugin as mk } from '@core/ui'
export default mk({ pages: { alpha: Page, 'alpha-two': Page } })`),
    })
    assert.deepEqual(out.manifest.pages, ['alpha', 'alpha-two'])
  })

  it('reads a namespace import', async () => {
    const out = await pagesOf({
      'ui/src/index.ts': entry(`import * as sdk from '@core/ui'
export default sdk.defineUIPlugin({ pages: { alpha: Page } })`),
    })
    assert.deepEqual(out.manifest.pages, ['alpha'])
  })

  it('leaves pages out and warns when the object has a spread', async () => {
    const out = await pagesOf({
      'ui/src/index.ts': entry(`import { defineUIPlugin } from '@core/ui'
const extra = { alpha_extra: Page }
export default defineUIPlugin({ pages: { ...extra, alpha: Page } })`),
    })
    assert.equal(out.manifest.pages, undefined)
    assert.ok(out.warnings.some((w) => w.includes('spread or a computed key')), out.warnings.join(' | '))
  })

  it('leaves pages out and warns when a key is computed', async () => {
    const out = await pagesOf({
      'ui/src/index.ts': entry(`import { defineUIPlugin } from '@core/ui'
const id = 'alpha'
export default defineUIPlugin({ pages: { [id]: Page } })`),
    })
    assert.equal(out.manifest.pages, undefined)
    assert.ok(out.warnings.some((w) => w.includes('spread or a computed key')))
  })

  it('accepts a plugin with no pages at all', async () => {
    const out = await pagesOf({
      'ui/src/index.ts': `import { defineUIPlugin } from '@core/ui'
export default defineUIPlugin({ setup(ctx) { ctx.log('hud only') } })`,
    })
    assert.deepEqual(out.manifest.pages, [])
  })

  it('fails when the entry has no defineUIPlugin call', async () => {
    const p = makePlugin({
      resource: 'alpha',
      files: { 'ui/src/index.ts': entry('export default { pages: { alpha: Page } }') },
    })
    const err = await buildError(p.uiDir)
    assert.match(err, /\[core-ui\] alpha: /)
    assert.match(err, /export default defineUIPlugin/)
  })

  it('fails on a page id that is not a plain id', async () => {
    const p = makePlugin({
      resource: 'alpha',
      files: {
        'ui/src/index.ts': entry(`import { defineUIPlugin } from '@core/ui'
export default defineUIPlugin({ pages: { 'alpha page': Page } })`),
      },
    })
    const err = await buildError(p.uiDir)
    assert.match(err, /\[core-ui\] alpha: page id "alpha page" is not a plain id/)
  })

  it('fails on a duplicate page id', async () => {
    const p = makePlugin({
      resource: 'alpha',
      files: {
        'ui/src/index.ts': entry(`import { defineUIPlugin } from '@core/ui'
export default defineUIPlugin({ pages: { alpha: Page, 'alpha': Page } })`),
      },
    })
    const err = await buildError(p.uiDir)
    assert.match(err, /\[core-ui\] alpha: page id 'alpha' appears twice/)
  })
})
