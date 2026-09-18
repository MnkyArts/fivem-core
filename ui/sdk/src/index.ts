// @core/ui — the facade a plugin imports (DESIGN §38.7).
//
// It holds NO state and bundles into every plugin (< 2 KB minified): `defineUIPlugin` and
// `definePage` are pure (they run at module evaluation, possibly in a test with no shell around),
// everything else resolves `globalThis.__CORE_UI_HOST__` AT CALL TIME and throws a clear error when
// the shell is not there. That is why a plugin may be imported by `node --test` or Storybook without
// a host, and why re-activating a cached module needs nothing from this file.
//
//   import { defineUIPlugin, definePage, usePage, useNui } from '@core/ui'
//
//   export default defineUIPlugin({
//     pages: { inventory: definePage<Props>({ component: () => import('./Page.vue') }) },
//     setup(ctx) { ctx.nui.on('sync', applySync) },
//   })

// The `.ts` extension is explicit on purpose: Node's type stripping (`node --test` over the shell's
// unit tests, DESIGN §38.15) does no extensionless resolution, and `allowImportingTsExtensions` in
// tsconfig.plugin.json makes it legal for TypeScript. Vite/esbuild resolve it either way.
import { API_VERSION, HOST_GLOBAL } from './contract.ts'
import type {
  CoreUIHost, EventMap, HudState, NuiErrorCode, NuiHandle, PageDefinition, PageHandle,
  RpcMap, Scope, StatBar, UIPlugin, UIPluginDefinition,
} from './contract.ts'
import type { DeepReadonly } from 'vue'

export { API_VERSION, HOST_GLOBAL }
export type * from './contract.ts'

/** Thrown/rejected by `nui.invoke` and by a failed `nui.handle` answer (DESIGN §38.8). */
export class NuiError extends Error {
  readonly code: NuiErrorCode

  constructor(code: NuiErrorCode, message?: string) {
    super(message || code)
    this.name = 'NuiError'
    this.code = code
  }

  // The shell and every plugin bundle their own copy of this class, so a plain prototype check
  // would be false for an error the shell created. Identify by shape instead. (`override`:
  // Function.prototype already carries [Symbol.hasInstance], and plugins compile with
  // noImplicitOverride.)
  static override [Symbol.hasInstance](v: unknown): boolean {
    return !!v && typeof v === 'object'
      && (v as { name?: unknown }).name === 'NuiError'
      && typeof (v as { code?: unknown }).code === 'string'
  }
}

// Joined at runtime on purpose. Tailwind scans every module Vite transforms, and this message
// spelled out in one piece reads as an arbitrary-property utility: every plugin's stylesheet would
// carry a stray `.\[core\:ui\]{core:ui}` rule — and only on some builds, because whether the facade
// is scanned before the sheet is generated depends on module order, which made the emitted CSS
// file's content hash (and with it the manifest) irreproducible. `+` is folded by esbuild before
// Tailwind ever sees the code; a join is not. Same string at runtime.
const NO_HOST = ['[core', ':ui] no host — @core/ui used outside the core shell (or before it booted)'].join('')

function host(): CoreUIHost {
  const h = (globalThis as Record<string, unknown>)[HOST_GLOBAL] as CoreUIHost | undefined
  if (!h) throw new Error(NO_HOST)
  return h
}

// ---------------------------------------------------------------- pure definitions

/** Wraps a plugin definition into the entry's `export default`. Pure — no host access. */
export function defineUIPlugin(def: UIPluginDefinition): UIPlugin {
  return { ...def, __coreUIPlugin: true, apiVersion: API_VERSION }
}

/** Identity with types attached: gives a page its props type and its hooks. Pure — no host access. */
export function definePage<Props extends object = Record<string, unknown>>(
  def: PageDefinition<Props>,
): PageDefinition<Props> {
  return def
}

// ---------------------------------------------------------------- host-backed composables

// The generics take any `object`, not `Record<string, …>`: a plugin writes its props, events and
// rpc maps as INTERFACES, and an interface has no implicit index signature.

/** No id inside a page component: the page being rendered. With an id: that page. */
export function usePage<
  P extends object = Record<string, unknown>, O extends object = EventMap, I extends object = EventMap,
>(id?: string): PageHandle<P, O, I> {
  return host().usePage<P, O, I>(id)
}

/** The calling plugin's channel (`Core.UI.on('<resource>', …)` in Lua), or the named one. */
export function useNui<
  R extends object = RpcMap, O extends object = EventMap, I extends object = EventMap,
>(channel?: string): NuiHandle<R, O, I> {
  return host().useNui<R, O, I>(channel)
}

/** The scope being set up (component scope inside a component, else the plugin scope). */
export function useScope(): Scope {
  return host().useScope()
}

/** Frame-coalesced telemetry written by `Core.UI.feed` — shallow-reactive, read only. */
export function useFeed<T extends object = Record<string, unknown>>(channel?: string): Readonly<T> {
  return host().useFeed<T>(channel)
}

/** Core's HUD state (cash, name, faction, health, street, …) — reactive, read only. */
export function useHud(): DeepReadonly<HudState> {
  return host().hud
}

/** The mirrored player state bags (`Core.UI.state`) — reactive, read only. */
export function usePlayerState(): DeepReadonly<Record<string, unknown>> {
  return host().state
}

/** The stat bars core publishes (`Core.Stats`) — reactive, read only. */
export function useStats(): DeepReadonly<Record<string, StatBar>> {
  return host().stats
}

// ---------------------------------------------------------------- shell services

/** Core's locale lookup (`Core.Locale.t` on the Lua side). */
export function t(key: string, vars?: Record<string, unknown>): string {
  return host().t(key, vars)
}

/** A shell toast. `notify('saved', 'success')` or `notify({ message, type, title, duration })`. */
export function notify(
  message: string | { message: string; type?: 'info' | 'success' | 'error' | 'warning'; title?: string; duration?: number },
  type?: string,
): void {
  host().notify(message, type)
}

/** A game sound through core's audio bridge. */
export function playSound(name: string, set?: string | null): void {
  host().playSound(name, set)
}

/** Add glyphs to the kit's icon set (`<CoreIcon name="…">`), keyed by name, value = SVG path data. */
export function registerIcons(icons: Record<string, string>): void {
  host().registerIcons(icons)
}
