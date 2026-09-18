// core UI — the shell as a mountable unit (DESIGN §38.6, §38.11).
//
// `main.ts` is three lines on top of this; the SDK's dev host (`createDevHost`, §38.11 path 1) and
// the integration tests mount the SAME shell with a mock transport, so what a plugin author sees in
// the browser is core's real HUD, real kit, real focus stack and real page host — never a stand-in.
//
// The boot ORDER is load-bearing:
//   1. `window.Vue`            — set before anything reads it (legacy plugin bundles, kit-regression)
//   2. `window.CoreUI`         — the legacy surface, needed by installKit consumers and the suites
//   3. `__CORE_UI_HOST__`      — BEFORE any plugin module is evaluated: the SDK's virtual `vue`
//                                module reads `host.vue` at evaluation time (§38.3)
//   4. createApp + errorHandler + installKit + mount
//   5. `CoreUI.kit`, then game blur (it wants a mounted shell to scan)
//   6. `ui_ready` — tells Lua the NUI is alive; it replays dev:set, plugins, pages and state.

import * as Vue from 'vue'
import type { App } from 'vue'
import type { CoreUIHost } from '../sdk/src/contract.ts'
import { installCoreUI } from './coreui.js'
import { installGameBlur } from './gameblur.js'
import { installKit, components, ICONS, registerIcons } from './kit/index.js'
import { store } from './store.js'
import { isDev, post, setTransport, resetTransport } from './runtime/transport.ts'
import type { TransportImpl } from './runtime/transport.ts'
import { createHost } from './runtime/host.ts'
import { installGlobalHandlers, report, setOriginMap } from './runtime/errors.ts'
import App_ from './App.vue'

/**
 * Diagnostic seams for the offline suites, mounted ONLY in a plain browser (`isDev` is false the
 * moment `GetParentResourceName` exists, i.e. in the CEF), so nothing here ships to a player:
 *   __core.store            the reactive store, for reading state a suite cannot see from the DOM
 *   __core.setOriginMap(m)  map a test origin onto a resource name for stack attribution
 *   __core.inspect()        the inspector snapshot; the chunk is imported on the FIRST call (the
 *                           same specifier the panel uses, so there is exactly one chunk and one
 *                           fetch) and is never touched by a shell nobody inspects
 */
function installDevSeams(): void {
  if (!isDev || typeof window === 'undefined') return
  const shim = (window as unknown as { __core?: Record<string, unknown> }).__core
  if (!shim) return
  shim.store = store
  shim.setOriginMap = setOriginMap
  shim.inspect = () => import('./shell/Inspector.vue').then((m) => (m as unknown as { snapshot(): unknown }).snapshot())
}

export interface ShellOptions {
  /** A mock transport (`@core/ui/dev`, Storybook, the integration suite). */
  transport?: TransportImpl | null
  /** §32 glass. Off in a test harness that has no game frame to sample. */
  gameBlur?: boolean
  /** Post `ui_ready` after the mount. The dev host turns this off — nobody is listening. */
  ready?: boolean
}

export interface Shell {
  app: App
  host: CoreUIHost
  coreui: Record<string, unknown>
  unmount(): void
}

export function createShell(target: string | Element, opts?: ShellOptions): Shell {
  const options: ShellOptions = Object.assign({ gameBlur: true, ready: true }, opts || {})
  if (options.transport) setTransport(options.transport)

  // 1 + 2 — `window.Vue` must exist before installCoreUI() reads it.
  ;(window as unknown as { Vue: typeof Vue }).Vue = Vue
  const CoreUI = installCoreUI() as Record<string, unknown>

  // 3 — the host object, published before the first plugin module can be imported.
  const host = createHost({
    hud: CoreUI.hud as CoreUIHost['hud'],
    state: CoreUI.state as CoreUIHost['state'],
    stats: CoreUI.stats as CoreUIHost['stats'],
    lang: () => store.locale.lang,
    t: (key, vars) => (CoreUI.t as (k: string, v?: unknown) => string)(key, vars),
    notify: (message, type) => {
      ;(CoreUI.notify as (m: unknown, t?: string) => unknown)(message, type)
    },
    playSound: (name, set) => {
      ;(CoreUI.playSound as (n: string, s?: string | null) => unknown)(name, set)
    },
    // The kit is only on CoreUI after the mount, so this is read at CALL time.
    registerIcons: (icons) => {
      const kit = CoreUI.kit as { registerIcons?: (i: Record<string, string>) => void } | undefined
      if (kit && typeof kit.registerIcons === 'function') kit.registerIcons(icons)
      else registerIcons(icons)
    },
    dev: () => store.dev.enabled,
  })

  // 4 — the app. Anything Vue could not attribute to a boundary lands here with its stack.
  const app = Vue.createApp(App_)
  app.config.errorHandler = (err: unknown, instance: unknown, info: string) => {
    report({ error: err, info, component: instance ? undefined : null })
  }
  // §37.3: every `Core*.vue` is registered globally BEFORE the mount, so a plugin page resolves
  // `<CoreButton>` at render time without importing anything.
  installKit(app)
  app.mount(target as string)

  // 5 — what a plugin may reach for (§37.3), then the glass.
  CoreUI.kit = { components, icons: ICONS, registerIcons }
  const el = (typeof target === 'string' ? document.querySelector(target) : target) || document.body
  if (options.gameBlur !== false) CoreUI.gameBlur = installGameBlur(el)
  const removeGlobalHandlers = installGlobalHandlers(window)
  installDevSeams()

  // 6 — Lua replays dev:set, every plugin:register, every page:register and the state snapshot.
  if (options.ready !== false) post('ui_ready', {})

  return {
    app,
    host,
    coreui: CoreUI,
    unmount() {
      removeGlobalHandlers()
      app.unmount()
      if (options.transport) resetTransport()
    },
  }
}
