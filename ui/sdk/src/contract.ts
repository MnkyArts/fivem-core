// @core/ui — the contract between a plugin bundle and core's shell (DESIGN §38.6, §38.7).
//
// The ONE source of truth shared by the SDK facade (bundled into every plugin) and the shell
// runtime (which implements `CoreUIHost`). Both sides import THIS file, so the compiler proves
// the shell implements what the SDK calls.
//
// Rules for this file (do not break them):
//   - types + constants only, no runtime logic,
//   - no imports except `import type` from 'vue',
//   - no enums, no namespaces, no decorators — Node's type stripping must be able to run any
//     file that imports it (`node --test ui/tests/unit/*.test.ts`).

import type { Component, DeepReadonly } from 'vue'

/** Bumped only on a breaking change of CoreUIHost / the manifest / the wire protocol. */
export const API_VERSION = 1
/** The global the shell publishes before any plugin module is evaluated. */
export const HOST_GLOBAL = '__CORE_UI_HOST__'

// ---------------------------------------------------------------- manifest (ui/dist/manifest.json)

/** Written by `@core/ui/vite`, read by Lua (`LoadResourceFile`), never fetched by the page. */
export interface PluginManifest {
  /** MUST equal the FiveM resource name (one UI plugin per resource). */
  id: string
  apiVersion: number
  /** Entry module, relative to the manifest's folder. Content-hashed in production. */
  entry: string
  /** Stylesheets, relative to the manifest's folder. */
  css: string[]
  /** Opaque build id (changes whenever entry/css/chunks change). */
  build: string
  /** 'eager' (default): import right after registration. 'lazy': import on the first page open. */
  load?: 'eager' | 'lazy'
  /** Chunks worth a <link rel=modulepreload> once the entry is requested. */
  preload?: string[]
  /** Page ids found statically in defineUIPlugin({ pages }) — validation + tooling only. */
  pages?: string[]
  /** SDK and Vue versions the plugin was built against — diagnostics only. */
  sdk?: string
  vue?: string
}

// ---------------------------------------------------------------- errors

/** `resource_stopped`/`plugin_disposed` are owner deaths; `transport` is the fetch itself failing. */
export type NuiErrorCode =
  | 'timeout' | 'aborted' | 'no_handler' | 'handler_error' | 'bad_request' | 'bad_result'
  | 'resource_stopped' | 'plugin_disposed' | 'transport'

/** What crosses the wire for a failed request; the SDK turns it into a `NuiError`. */
export interface NuiErrorShape { code: NuiErrorCode; message: string }

// ---------------------------------------------------------------- typing helpers

/**
 * `{ eventName: payload }` — page -> Lua (emit) or Lua -> page (on).
 *
 * This is the DEFAULT, not the constraint: the handles below accept any `object`, because an
 * `interface` has no implicit index signature and would otherwise be rejected where a
 * `Record<string, unknown>` is required — and an interface is what a plugin naturally writes.
 */
export type EventMap = Record<string, unknown>
/** `{ requestName: { req: payload; res: result } }` — NUI -> Lua request/response. */
export type RpcMap = Record<string, { req: unknown; res: unknown }>
/** The request half of one `RpcMap` entry, tolerant of a map written as an interface. */
export type ReqOf<T> = T extends { req: infer Q } ? Q : unknown
/** The response half of one `RpcMap` entry. */
export type ResOf<T> = T extends { res: infer R } ? R : unknown
export type Off = () => void

export interface RequestOptions { timeoutMs?: number; signal?: AbortSignal }

// ---------------------------------------------------------------- scopes (ownership + cleanup)

/** A disposable bag. Everything a plugin/page creates through the SDK lands in one. */
export interface Scope {
  readonly disposed: boolean
  /** Runs `fn` on dispose (LIFO). Returns a function that removes the hook again. */
  onDispose(fn: () => void): Off
  /** window/document/element listener that dies with the scope. */
  listen<K extends keyof WindowEventMap>(target: Window, type: K, fn: (e: WindowEventMap[K]) => void, opts?: AddEventListenerOptions | boolean): Off
  listen(target: EventTarget, type: string, fn: (e: Event) => void, opts?: AddEventListenerOptions | boolean): Off
  timeout(fn: () => void, ms: number): Off
  interval(fn: () => void, ms: number): Off
  /** requestAnimationFrame loop; `fn` returns false to stop itself. */
  raf(fn: (now: number) => boolean | void): Off
}

// ---------------------------------------------------------------- transport handles

/** The plugin's own channel: events and requests that are NOT tied to one page. */
export interface NuiHandle<Rpc extends object = RpcMap, Out extends object = EventMap, In extends object = EventMap> {
  /** Plugin id == resource name == Lua channel (`Core.UI.on('<resource>', event, fn)`). */
  readonly channel: string
  /** Fire and forget -> client Lua `TriggerEvent('core:ui:<channel>:<event>', data)`. */
  emit<K extends keyof Out & string>(event: K, data?: Out[K]): void
  /** Request/response -> the owner's `Core.UI.onRequest(name, fn)`. Rejects with NuiError. */
  invoke<K extends keyof Rpc & string>(name: K, data?: ReqOf<Rpc[K]>, opts?: RequestOptions): Promise<ResOf<Rpc[K]>>
  /** Lua -> NUI event (`Core.UI.send(channel, event, data)`). Auto-removed with the current scope. */
  on<K extends keyof In & string>(event: K, fn: (data: In[K]) => void): Off
  /** Lua -> NUI request (`Core.UI.request(channel, name, data)`): answer by returning (a promise of) the result. */
  handle(name: string, fn: (data: unknown) => unknown | Promise<unknown>): Off
}

/** One page of this plugin: its props, its open state and its own event channel. */
export interface PageHandle<Props extends object = Record<string, unknown>, Out extends object = EventMap, In extends object = EventMap> {
  readonly id: string
  /** Stable reactive object for the life of the shell (DESIGN §7.4) — never replaced, only mutated. */
  readonly props: Props
  readonly isOpen: boolean
  emit<K extends keyof Out & string>(event: K, data?: Out[K]): void
  on<K extends keyof In & string>(event: K, fn: (data: In[K]) => void): Off
  close(): void
}

// ---------------------------------------------------------------- plugin definition

export interface PageHooks<Props extends object = Record<string, unknown>> {
  /** `page:open` applied (props are already set). Runs for re-opens of an open page too. */
  onOpen?(page: PageHandle<Props>): void
  /** Props changed through `Core.UI.update/patch` or a repeated `Core.UI.open`. */
  onUpdate?(page: PageHandle<Props>, changed: readonly string[]): void
  onClose?(page: PageHandle<Props>): void
}

/**
 * Lazy page component: `() => import('./Page.vue')`.
 *
 * A function value in `pages` is ALWAYS treated as a loader — functional components are not
 * supported as page roots. Wrap one in `defineComponent`/an SFC (or put it behind a loader that
 * resolves to it) if you need a render function at the root of a page.
 */
export type ComponentLoader = () => Promise<Component | { default: Component }>

export interface PageDefinition<Props extends object = Record<string, unknown>> extends PageHooks<Props> {
  component: Component | ComponentLoader
  /** Keep the component instance alive (hidden) between opens. Default false: closed == unmounted.
   *  Honoured on the exclusive page layer only — overlays and modals ignore it. */
  keepAlive?: boolean
  /** 'deep' (default): patches mutate in place, precise triggers. 'shallow': shallowReactive props,
   *  patches copy along the path and re-assign the top-level key (no deep proxies for big blobs). */
  reactivity?: 'deep' | 'shallow'
}

/** Handed to `setup(ctx)` once per activation of the plugin (DESIGN §38.2). */
export interface PluginContext {
  /** Resource name. */
  readonly id: string
  /** Bumped by core on every (re)start of the resource in this game session. */
  readonly generation: number
  readonly build: string
  readonly scope: Scope
  readonly nui: NuiHandle
  /** true when the shell runs with Config.UI.Dev (inspector, verbose logs). */
  readonly dev: boolean
  log(...args: unknown[]): void
}

export interface UIPluginDefinition {
  pages?: Record<string, Component | ComponentLoader | PageDefinition<any>>
  /** Runs once per activation (module may be cached, the plugin instance is new). May return a disposer.
   *  Must be SYNCHRONOUS: a returned Promise is warned about — start async work inside and clean it
   *  up through `ctx.scope`, so a restart cannot race the next activation. */
  setup?(ctx: PluginContext): void | (() => void)
}

/** What `defineUIPlugin()` returns and the entry module default-exports. */
export interface UIPlugin extends UIPluginDefinition {
  readonly __coreUIPlugin: true
  readonly apiVersion: number
}

// ---------------------------------------------------------------- read-only shell state

export interface HudState {
  visible: boolean; cash: number; bank: number; name: string; serverId: number
  faction: false | { name: string; tag: string; color?: string | null }
  health: number | null; armour: number | null; speed: number | null
  street: string; zone: string
  minimap: { x: number; y: number; w: number; h: number } | null
}
export interface StatBar { name: string; label: string; value: number; min: number; max: number }

// ---------------------------------------------------------------- the host object

/** `globalThis[HOST_GLOBAL]`, published by the shell before any plugin module is evaluated. */
export interface CoreUIHost {
  readonly apiVersion: number
  /** The ONE Vue module namespace (what `import * as Vue from 'vue'` gives the shell). */
  readonly vue: typeof import('vue')
  readonly dev: boolean

  /** Inside a page component: no id -> the page being rendered (provide/inject). With an id: any page of any plugin. */
  usePage<P extends object = Record<string, unknown>, O extends object = EventMap, I extends object = EventMap>(id?: string): PageHandle<P, O, I>
  /** Inside plugin code (setup, page component): the calling plugin's channel. With an id: that channel. */
  useNui<R extends object = RpcMap, O extends object = EventMap, I extends object = EventMap>(channel?: string): NuiHandle<R, O, I>
  /** The scope of the component/plugin currently being set up (component scope > plugin scope). */
  useScope(): Scope
  /** Frame-coalesced telemetry: a shallow-reactive object fed by `Core.UI.feed(channel, values)`. */
  useFeed<T extends object = Record<string, unknown>>(channel?: string): Readonly<T>

  readonly hud: DeepReadonly<HudState>
  readonly state: DeepReadonly<Record<string, unknown>>
  readonly stats: DeepReadonly<Record<string, StatBar>>
  readonly lang: string
  t(key: string, vars?: Record<string, unknown>): string
  notify(message: string | { message: string; type?: 'info' | 'success' | 'error' | 'warning'; title?: string; duration?: number }, type?: string): void
  playSound(name: string, set?: string | null): void
  registerIcons(icons: Record<string, string>): void
}
