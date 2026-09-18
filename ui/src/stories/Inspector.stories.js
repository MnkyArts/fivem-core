// UI platform inspector (DESIGN §38.14) — dev only, never in a production shell.
//
// Lua side: `/uiinspect` (or `Config.UI.Dev.Inspector`) sends `inspector:toggle`; the shell flips
// `store.dev.inspector`, App.vue's async component issues its ONE dynamic import and the panel
// mounts. It is read-only by construction — `pointer-events: none`, no control, never focusable —
// so everything below is driven by feeding the RUNTIME, exactly like the game would.
import { h, onMounted } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import Inspector from '../shell/Inspector.vue'
import { send } from './storeHelpers.js'
import { register, configurePlugins, resetPlugins, setDevOptions } from '../runtime/plugins.ts'
import { applyFeed, resetFeeds, useFeed } from '../runtime/feeds.ts'
import { createScope, withScope } from '../runtime/scope.ts'
import { report } from '../runtime/errors.ts'

const COMPONENT = { name: 'StoryPage', render: () => h('div') }

/** A fake module graph: `register` imports through this instead of the network. */
function fakeModules (map) {
  configurePlugins({
    importModule: (url) => {
      const mod = map[url]
      if (!mod) return Promise.reject(new Error('404 ' + url))
      return Promise.resolve(mod)
    },
  })
}

const plugin = (pages, setup) => ({ default: { __coreUIPlugin: true, apiVersion: 1, pages, setup } })

/** Registers one plugin the way `client/ui_plugins.lua` does. */
function registerPlugin (id, entry, generation, mod) {
  register({
    id,
    generation,
    base: 'https://cfx-nui-' + id + '/ui/dist/',
    manifest: { id, apiVersion: 1, entry, css: [], build: entry.split('.')[1] },
  })
  return mod
}

let storyScope = null

function build () {
  resetPlugins()
  resetFeeds()
  setDevOptions({ enabled: true, log: false })
  if (storyScope) storyScope.dispose()
  storyScope = createScope('story')

  const base = 'https://cfx-nui-'
  fakeModules({
    [base + 'inventory/ui/dist/plugin.a81f3c.js']: plugin(
      { inventory: COMPONENT, inventory_hotbar: COMPONENT },
      (ctx) => {
        ctx.scope.listen(window, 'blur', () => {})
        ctx.scope.timeout(() => {}, 600000)
        ctx.nui.handle('split', (d) => d)
      },
    ),
    [base + 'trucking/ui/dist/plugin.77c010.js']: plugin({ trucking_hud: COMPONENT }),
  })

  registerPlugin('inventory', 'plugin.a81f3c.js', 3)
  registerPlugin('trucking', 'plugin.77c010.js', 1)
  // A resource whose build never shipped: the loudest thing the panel can show.
  registerPlugin('charcreator', 'plugin.missing.js', 2)

  // Pages, focus and telemetry arrive as real wire messages.
  send({ action: 'page:register', id: 'inventory', type: 'page', keepInput: false, owner: 'inventory' })
  send({ action: 'page:register', id: 'inventory_hotbar', type: 'overlay', keepInput: false, owner: 'inventory' })
  send({ action: 'page:register', id: 'trucking_hud', type: 'overlay', keepInput: false, owner: 'trucking' })
  send({ action: 'page:open', id: 'inventory_hotbar', props: {} })
  send({ action: 'page:open', id: 'inventory', props: { slots: [], maxWeight: 120 } })
  send({ action: 'focus', focused: true, stack: [{ key: 'page:inventory', layer: 'page', id: 'inventory', owner: 'inventory' }] })
  withScope(storyScope, () => useFeed('trucking'))
  applyFeed({ c: { trucking: { speed: 132, rpm: 0.71, gear: 4 } } })
  report({ plugin: 'charcreator', page: 'charcreator', error: new Error('Cannot read properties of undefined (reading \'heads\')') })
}

const view = () => h(Inspector)

const scene = () => ({
  setup () {
    onMounted(build)
    return view
  },
})

export default {
  title: 'Shell/Inspector',
  component: Inspector,
  parameters: {
    layout: 'fullscreen',
    lua: {
      message: 'inspector:toggle',
      call: '-- console or a key binding\n/uiinspect\n\n'
        + '-- or permanently for a dev server\nConfig.UI.Dev.Enabled = true\nConfig.UI.Dev.Inspector = true',
      note: 'Dev only. The chunk (assets/inspector.js) is fetched by the first toggle and never before.',
    },
    docs: {
      description: {
        component: 'Everything the shell knows about itself (DESIGN §38.14): plugin states with '
          + 'generation, build and load time, the module cache, pages (declared / open / mounted) and '
          + 'their owner, the mirrored focus stack, per-scope listener/timer/rAF counts, request '
          + 'handlers and in-flight requests, message and byte rates, feed rates, long tasks and the '
          + 'last 50 errors. Byte counting and the PerformanceObserver are armed on mount and dropped '
          + 'on unmount, so a closed panel costs nothing. This story feeds the real runtime with a '
          + 'fake module graph: two healthy plugins, one whose build never shipped.',
      },
    },
  },
}

export const Panel = {
  name: 'Inspector',
  render: scene,
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('UI inspector')).toBeInTheDocument())
    // The two healthy plugins settle asynchronously; the broken one reports its 404.
    await waitFor(() => expect(canvas.getAllByText('ready').length).toBe(2))
    expect(canvas.getByText('failed')).toBeInTheDocument()
    expect(canvas.getByText('page:inventory')).toBeInTheDocument()
    expect(canvas.getByText('plugin:inventory')).toBeInTheDocument()
    // Read-only: the panel must never take a pointer event away from the page underneath it.
    const panel = canvasElement.querySelector('.core-inspector')
    expect(getComputedStyle(panel).pointerEvents).toBe('none')
  },
}
