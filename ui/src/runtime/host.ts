// core UI runtime — the host object every plugin bundle talks to (DESIGN §38.6, §38.7).
//
// `globalThis.__CORE_UI_HOST__` is published BEFORE any plugin module is evaluated (shell.ts does
// that), because the SDK's virtual `vue` module reads `host.vue` at evaluation time: this object is
// how a plugin gets the shell's ONE Vue, and with it one reactivity graph, one app context and
// therefore globally registered `<CoreButton>` inside a plugin template.
//
// Everything a plugin can reach is scoped: `on`, `handle` and `useFeed` register in the scope that
// is being set up (the component's, else the plugin's), and an `invoke` that is still in flight when
// the plugin goes away rejects with `plugin_disposed` instead of resolving into a dead tree.

import { inject, provide, getCurrentInstance } from 'vue'
import * as Vue from 'vue'
import { API_VERSION, HOST_GLOBAL } from '../../sdk/src/contract.ts'
import type { CoreUIHost, NuiHandle, Off, PageHandle, RequestOptions, Scope } from '../../sdk/src/contract.ts'
import type { MsgPageRequest } from './protocol.ts'
import { NuiError, post, onMessage, request } from './transport.ts'
import { createScope, currentScope } from './scope.ts'
import type { OwnedScope } from './scope.ts'
import * as Pages from './pages.ts'
import * as Plugins from './plugins.ts'
import { useFeed as useFeedChannel } from './feeds.ts'
import { report } from './errors.ts'

/** Injection keys. `PluginBoundary` provides both around every plugin-owned instance. */
export const PAGE_KEY = 'core-ui:page'
export const PLUGIN_KEY = 'core-ui:plugin'
export const SCOPE_KEY = 'core-ui:scope'

/** The bag a page component lives in (provided by PluginBoundary, read by `usePage()`). */
export interface PageContext {
  id: string
  owner: string | null
}

const handlers = new Map<string, Map<string, (data: unknown) => unknown>>()
const pending = new Map<string, Set<{ reject: (err: unknown) => void }>>()
/** A scope with no plugin: `useScope()` outside a plugin still returns something disposable. */
let shellScope: OwnedScope | null = null

/** The page scope provided by `PluginBoundary`, when we are inside a page component. */
function injectedScope(): OwnedScope | null {
  return getCurrentInstance() ? (inject(SCOPE_KEY, null) as OwnedScope | null) : null
}

function channelHandlers(channel: string): Map<string, (data: unknown) => unknown> {
  let map = handlers.get(channel)
  if (!map) {
    map = new Map()
    handlers.set(channel, map)
  }
  return map
}

function trackPending(channel: string, entry: { reject: (err: unknown) => void }): () => void {
  let set = pending.get(channel)
  if (!set) {
    set = new Set()
    pending.set(channel, set)
  }
  set.add(entry)
  return () => {
    set.delete(entry)
  }
}

/** `plugin:unregister`: nothing of that resource may answer or resolve any more. */
Plugins.onPluginDispose((id) => {
  handlers.delete(id)
  const set = pending.get(id)
  if (set) {
    for (const entry of Array.from(set)) entry.reject(new NuiError('plugin_disposed', id + ' was stopped while a request was in flight'))
    pending.delete(id)
  }
})

// ---------------------------------------------------------------- NuiHandle

export function nuiHandle(channel: string): NuiHandle {
  return {
    channel,
    emit(event: string, data?: unknown) {
      post('ui_event', { page: channel, event, data: data === undefined ? {} : data })
    },
    invoke(name: string, data?: unknown, opts?: RequestOptions) {
      let release: () => void = () => {}
      return new Promise((resolve, reject) => {
        release = trackPending(channel, { reject })
        request(channel, name, data, opts).then(resolve, reject)
      }).finally(() => release())
    },
    on(event: string, fn: (data: never) => void): Off {
      return Pages.bindToScope(Pages.onPageEvent(channel, event, fn as (d: unknown) => void), injectedScope())
    },
    handle(name: string, fn: (data: unknown) => unknown): Off {
      const map = channelHandlers(channel)
      map.set(name, fn)
      return Pages.bindToScope(() => {
        if (map.get(name) === fn) map.delete(name)
      }, injectedScope())
    },
  } as NuiHandle
}

Plugins.setNuiFactory(nuiHandle)

// ---------------------------------------------------------------- Lua -> NUI requests

function answer(rid: unknown, ok: boolean, payload: unknown): void {
  if (ok) post('ui_response', { rid, ok: true, data: payload === undefined ? null : payload })
  else post('ui_response', { rid, ok: false, error: payload })
}

/** `page:request { id, rid, name, data }` — `id` is a page id OR a plugin channel (§38.5). */
export function answerRequest(msg: MsgPageRequest): void {
  const id = String(msg.id || '')
  const name = String(msg.name || '')
  let channel = id
  if (!handlers.has(channel)) {
    const rec = Pages.pageState().pages[id]
    if (rec && rec.owner) channel = rec.owner
  }
  const fn = handlers.get(channel) && (handlers.get(channel) as Map<string, (d: unknown) => unknown>).get(name)
  if (typeof fn !== 'function') {
    answer(msg.rid, false, { code: 'no_handler', message: 'no NUI handler "' + name + '" on channel "' + channel + '"' })
    return
  }
  let result: unknown
  try {
    result = fn(msg.data)
  } catch (err) {
    report({ plugin: channel, page: id, error: err, info: 'nui.handle("' + name + '")' })
    answer(msg.rid, false, { code: 'handler_error', message: err && (err as Error).message ? (err as Error).message : String(err) })
    return
  }
  if (result && typeof (result as Promise<unknown>).then === 'function') {
    void (result as Promise<unknown>).then(
      (value) => answer(msg.rid, true, value),
      (err) => {
        report({ plugin: channel, page: id, error: err, info: 'nui.handle("' + name + '")' })
        answer(msg.rid, false, { code: 'handler_error', message: err && (err as Error).message ? (err as Error).message : String(err) })
      },
    )
    return
  }
  answer(msg.rid, true, result)
}

// ---------------------------------------------------------------- the host object

/** What the shell hands in: the legacy `window.CoreUI` surface it already builds (§38.12). */
export interface HostDeps {
  hud: CoreUIHost['hud']
  state: CoreUIHost['state']
  stats: CoreUIHost['stats']
  lang(): string
  t(key: string, vars?: Record<string, unknown>): string
  notify(message: unknown, type?: string): void
  playSound(name: string, set?: string | null): void
  /** The kit's icon registry — only available after the mount, so it is read at call time. */
  registerIcons(icons: Record<string, string>): void
  dev(): boolean
}

let host: CoreUIHost | null = null

export function currentHost(): CoreUIHost | null {
  return host
}

export function createHost(deps: HostDeps): CoreUIHost {
  const usePage = <P extends object>(id?: string): PageHandle<P> => {
    let pageId = id
    if (!pageId) {
      const ctx = getCurrentInstance() ? (inject(PAGE_KEY, null) as PageContext | null) : null
      if (!ctx) throw new Error('[core:ui] usePage() without an id works inside a page component only — pass the page id')
      pageId = ctx.id
    }
    return Pages.pageHandle(pageId) as unknown as PageHandle<P>
  }

  const useNui = (channel?: string): NuiHandle => {
    let name = channel
    if (!name) {
      const ctx = getCurrentInstance() ? (inject(PLUGIN_KEY, null) as string | null) : null
      name = ctx || Plugins.activePluginId() || ''
      if (!name) throw new Error('[core:ui] useNui() without a channel works inside a plugin only — pass the channel')
    }
    return nuiHandle(name)
  }

  const useScope = (): Scope => {
    const injected = getCurrentInstance() ? (inject(SCOPE_KEY, null) as OwnedScope | null) : null
    if (injected && !injected.disposed) return injected
    const scope = currentScope()
    if (scope && !scope.disposed) return scope
    if (!shellScope || shellScope.disposed) shellScope = createScope('shell')
    return shellScope
  }

  const useFeed = <T extends object>(channel?: string): Readonly<T> => {
    let name = channel
    if (!name) {
      const ctx = getCurrentInstance() ? (inject(PLUGIN_KEY, null) as string | null) : null
      name = ctx || Plugins.activePluginId() || ''
      if (!name) throw new Error('[core:ui] useFeed() without a channel works inside a plugin only — pass the channel')
    }
    // The page scope is the fallback owner: a component that reads a feed must stop counting as a
    // reader the moment its page dies, even if Vue has not flushed its unmount yet (BUG 1).
    const owner = getCurrentInstance() ? (inject(SCOPE_KEY, null) as OwnedScope | null) : null
    return useFeedChannel<T>(name, owner) as Readonly<T>
  }

  host = {
    apiVersion: API_VERSION,
    vue: Vue as unknown as CoreUIHost['vue'],
    get dev() {
      return deps.dev()
    },
    usePage: usePage as CoreUIHost['usePage'],
    useNui: useNui as CoreUIHost['useNui'],
    useScope,
    useFeed: useFeed as CoreUIHost['useFeed'],
    hud: deps.hud,
    state: deps.state,
    stats: deps.stats,
    get lang() {
      return deps.lang()
    },
    t: (key, vars) => deps.t(key, vars),
    notify: (message, type) => deps.notify(message, type),
    playSound: (name, set) => deps.playSound(name, set),
    registerIcons: (icons) => deps.registerIcons(icons),
  } as CoreUIHost

  ;(globalThis as unknown as Record<string, unknown>)[HOST_GLOBAL] = host
  onMessage('page:request', (msg) => answerRequest(msg as unknown as MsgPageRequest))
  return host
}

/** PluginBoundary calls this so `usePage()`/`useNui()` resolve inside the page's subtree. */
export function providePageContext(ctx: PageContext, scope: OwnedScope | null): void {
  provide(PAGE_KEY, ctx)
  provide(PLUGIN_KEY, ctx.owner)
  provide(SCOPE_KEY, scope)
}

/** §38.14: per-channel request handlers and in-flight `invoke`s, for the inspector. */
export function channelStats(): Array<{ channel: string; handlers: number; pending: number }> {
  const names = new Set<string>()
  for (const channel of handlers.keys()) names.add(channel)
  for (const channel of pending.keys()) names.add(channel)
  const out: Array<{ channel: string; handlers: number; pending: number }> = []
  for (const channel of names) {
    const h = handlers.get(channel)
    const p = pending.get(channel)
    out.push({ channel, handlers: h ? h.size : 0, pending: p ? p.size : 0 })
  }
  return out.sort((a, b) => (a.channel < b.channel ? -1 : 1))
}

/** Story/test helper. */
export function resetHost(): void {
  handlers.clear()
  pending.clear()
  if (shellScope) shellScope.dispose()
  shellScope = null
}
