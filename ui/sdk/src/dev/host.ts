// @core/ui/dev — the browser dev host (DESIGN §38.11 path 1).
//
//   // <resource>/ui/dev/host.ts
//   import { createDevHost } from '@core/ui/dev'
//   import plugin from '../src/index.ts'
//   import { mock } from './mock.ts'
//   createDevHost({ id: 'inventory', plugin, mock, open: 'inventory' })
//
// It mounts core's REAL shell (the same `createShell` the game loads) with a mock transport, then
// ACTIVATES the already-imported plugin object instead of fetching a manifest: one Vite graph, one
// Vue, and Vue's own HMR for the plugin's SFCs. Nothing here ships — `ui/dev/` is not in the
// resource's `files {}` and `coreUI()` never builds it.
//
// The only seam it needs from the runtime is `configurePlugins({ importModule })`: the plugin is
// registered under a `core-ui-dev:/<id>/plugin.js` token whose "import" resolves from memory.

import '../../../src/styles.css'
import '../../../src/kit/fonts.css'
import { createApp, markRaw } from 'vue'
import type { App } from 'vue'
import { createShell } from '../../../src/shell.ts'
import type { Shell } from '../../../src/shell.ts'
import { deliver } from '../../../src/runtime/transport.ts'
import { configurePlugins } from '../../../src/runtime/plugins.ts'
import { installKit } from '../../../src/kit/index.js'
import type { PageType } from '../../../src/runtime/protocol.ts'
import { API_VERSION } from '../contract.ts'
import type { CoreUIHost, RpcMap, UIPlugin } from '../contract.ts'
import { createMockTransport } from './mock.ts'
import type { LuaMock, MockPageDecl, MockTransport, PagePropsMap } from './mock.ts'
import { paintBackground } from './types.ts'
import type { DevBackground } from './types.ts'
import Toolbar from './Toolbar.vue'

// Generic over BOTH halves of the mock: the host itself does not care what a plugin's rpc map looks
// like, but the caller does — inferring `Rpc`/`Pages` from `mock` is what keeps `__dev.lua.open(…)`
// and `lua.onRequest(…)` typed without a single cast at the call site.
export interface DevHostOptions<Rpc extends object = RpcMap, Pages extends object = PagePropsMap> {
  /** The resource name. Plugin id, page owner and nui channel are all this one string. */
  id: string
  /** `export default defineUIPlugin({ … })` — the object, imported by YOUR dev/host.ts. */
  plugin: UIPlugin
  /** From `createMockTransport()`, when you want request fakes registered before the mount. */
  mock?: MockTransport<Rpc, Pages>
  /** Page declarations (what `Core.UI.registerPage` does). Default: every `plugin.pages` key as 'page'. */
  pages?: Record<string, MockPageDecl | PageType>
  /** Props the toolbar opens a page with — checked against the page's own props type. */
  props?: { [K in keyof Pages & string]?: Pages[K] }
  target?: string | Element
  background?: DevBackground
  /** false leaves the toolbar out (screenshots, automated checks). */
  toolbar?: boolean
  /** Open this page right after the mount. */
  open?: (keyof Pages & string) | null
}

export interface DevHost<Rpc extends object = RpcMap, Pages extends object = PagePropsMap> {
  lua: LuaMock<Rpc, Pages>
  host: CoreUIHost
  shell: Shell
  /** `plugin:unregister` -> `plugin:register` (generation + 1) and re-open: the cleanup proof. */
  restart(): Promise<void>
  open<K extends keyof Pages & string>(id: K, props?: Pages[K]): void
  close(id?: string): void
  generation(): number
  destroy(): void
}

const LOCAL_SCHEME = 'core-ui-dev:/'
/** url -> module namespace. `plugins.ts` imports by URL; in the dev host the URL is a token. */
const locals = new Map<string, Record<string, unknown>>()
let importerInstalled = false

function installLocalImporter(): void {
  if (importerInstalled) return
  importerInstalled = true
  configurePlugins({
    importModule: (url: string) => {
      const hit = locals.get(url)
      if (hit) return Promise.resolve(hit)
      return import(/* @vite-ignore */ url) as Promise<Record<string, unknown>>
    },
  })
}

export function createDevHost<Rpc extends object = RpcMap, Pages extends object = PagePropsMap>(
  options: DevHostOptions<Rpc, Pages>,
): DevHost<Rpc, Pages> {
  const id = options.id
  if (!id) throw new Error('[core:ui/dev] createDevHost needs the resource name as `id`')
  if (!options.plugin || options.plugin.__coreUIPlugin !== true) {
    throw new Error('[core:ui/dev] `plugin` must be the default export of src/index.ts — `export default defineUIPlugin({ … })`')
  }

  const mock: MockTransport<Rpc, Pages> = options.mock
    || createMockTransport<Rpc, Pages>({ deliver, resource: id })
  const lua = mock.lua

  installLocalImporter()
  const url = LOCAL_SCHEME + id + '/plugin.js'
  locals.set(url, { default: markRaw(options.plugin as unknown as object) })

  const bgEl = document.createElement('div')
  bgEl.setAttribute('data-core-dev-bg', '')
  paintBackground(bgEl, options.background || 'game')
  document.body.insertBefore(bgEl, document.body.firstChild)

  const shell = createShell(options.target || '#app', {
    transport: mock.transport,
    gameBlur: false,
    ready: false,
  })

  let generation = 0
  const lastProps = new Map<string, unknown>()
  const pageDecls: Record<string, MockPageDecl | PageType> = options.pages
    || Object.keys(options.plugin.pages || {}).reduce((acc: Record<string, PageType>, key) => {
      acc[key] = 'page'
      return acc
    }, {})

  function announce(): void {
    generation += 1
    lua.send({
      action: 'plugin:register',
      id,
      generation,
      base: LOCAL_SCHEME + id + '/',
      manifest: { id, apiVersion: API_VERSION, entry: 'plugin.js', css: [], build: 'dev' },
    })
    lua.registerPlugin(id, { pages: pageDecls })
  }

  function open(pageId: string, props?: unknown): void {
    const next = props
      ?? lastProps.get(pageId)
      ?? (options.props ? (options.props as Record<string, unknown>)[pageId] : undefined)
    lastProps.set(pageId, next)
    ;(lua.open as (p: string, v?: unknown) => void)(pageId, next)
  }

  async function restart(): Promise<void> {
    const wasOpen = lua.openPages.slice()
    lua.send({ action: 'plugin:unregister', id })
    announce()
    await Promise.resolve()
    for (const pageId of wasOpen) open(pageId)
  }

  announce()

  const toolbarEl = document.createElement('div')
  toolbarEl.setAttribute('data-core-dev-toolbar', '')
  let toolbarApp: App | null = null
  if (options.toolbar !== false) {
    document.body.appendChild(toolbarEl)
    toolbarApp = createApp(Toolbar, {
      pluginId: id,
      pages: Object.keys(pageDecls),
      background: options.background || 'game',
      backgroundEl: bgEl,
      lua,
      onOpenPage: open,
      onClosePage: (pageId?: string) => lua.close(pageId),
      onRestart: restart,
    })
    installKit(toolbarApp)
    toolbarApp.mount(toolbarEl)
  }

  const api: DevHost<Rpc, Pages> = {
    lua,
    host: shell.host,
    shell,
    restart,
    open,
    close: (pageId?: string) => lua.close(pageId),
    generation: () => generation,
    destroy() {
      if (toolbarApp) toolbarApp.unmount()
      toolbarEl.remove()
      bgEl.remove()
      shell.unmount()
      locals.delete(url)
    },
  }
  ;(window as unknown as { __dev: DevHost<Rpc, Pages> }).__dev = api
  if (options.open) open(options.open as string)
  return api
}
