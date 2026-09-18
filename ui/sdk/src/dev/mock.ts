// @core/ui/dev — the typed fake Lua side (DESIGN §38.11 path 1).
//
// `createMockTransport()` gives you two halves of one wire:
//   * `transport` — a `TransportImpl` the real shell mounts (`createShell({ transport })`), so every
//     `ui_request` / `ui_event` / `ui_close` the shell posts lands here instead of in a CEF;
//   * `lua` — what client Lua would do, typed: open a page, patch its props, answer a request, push
//     a feed. It mirrors the parts of `client/ui.lua` a page can observe, including the focus stack
//     of §38.9, so a dev-host page behaves exactly like the real one.
//
// It touches no DOM: `deliver` is injected (the dev host passes the shell's), which is also what
// makes the unit tests possible without a browser.

import type { EventMap, Off, ReqOf, ResOf, RpcMap } from '../contract.ts'
import type {
  CbUiClose, CbUiEvent, CbUiRequest, CbUiResponse, FocusEntry, PageType, PatchOp, RequestResult,
} from '../../../src/runtime/protocol.ts'
import type { TransportImpl } from '../../../src/runtime/transport.ts'

export interface MockPost { name: string; body: unknown; at: number }
export type MockMessage = Record<string, unknown> & { action: string }
/** `{ pageId: propsType }` — one level deep on purpose (DESIGN §38.7). Like `EventMap`/`RpcMap`
 *  this is the DEFAULT, never the constraint: a plugin writes its page map as an `interface`, and
 *  an interface has no implicit index signature. */
export type PagePropsMap = Record<string, object>

export interface MockPageDecl {
  type?: PageType
  keepInput?: boolean
}

export interface MockRequestOptions {
  /** Answer after this many ms — the way a `Core.Callback.await` round trip feels. */
  delayMs?: number
}

export interface MockOptions {
  /** Where a Lua -> NUI message goes. The dev host passes the shell's `deliver`. */
  deliver?: (msg: MockMessage) => void
  /** Reported as `transport.resource` (diagnostics only). */
  resource?: string | null
  /** Default delay for every `onRequest` answer. */
  delayMs?: number
}

export interface LuaMock<Rpc extends object = RpcMap, Pages extends object = PagePropsMap> {
  /** Every NUI -> Lua post, in order. Assertions read this. */
  readonly posts: MockPost[]
  /** Every Lua -> NUI message this mock sent. */
  readonly messages: MockMessage[]
  /** The focus stack as `client/ui.lua` would derive it (§38.9). */
  readonly focus: readonly FocusEntry[]
  /** Page ids that are open, in open order. */
  readonly openPages: readonly string[]

  send(msg: MockMessage): void
  /** Declares a resource's pages the way Lua's `Core.UI.registerPage` does. */
  registerPlugin(id: string, opts?: { pages?: Record<string, MockPageDecl | PageType> }): void
  open<K extends keyof Pages & string>(id: K, props?: Pages[K]): void
  close(id?: string): void
  update<K extends keyof Pages & string>(id: K, partial: Partial<Pages[K] & object>): void
  /**
   * `patch('inventory', 'slots.12', slot)`; the value left out DELETES the key (§38.10).
   *
   * A path addresses the LUA table that was passed to `open` — Lua's view, **1-based**, exactly
   * what `Core.UI.patch` takes in Lua: `'items.1.count'` is the first element, and `length + 1`
   * appends. An array-form path is joined as written; its elements are Lua indexes.
   */
  patch(id: string, path: string | readonly (string | number)[], ...value: [unknown?]): void
  emit<E extends EventMap = EventMap>(channel: string, event: keyof E & string, data?: E[keyof E & string]): void
  feed(channel: string, values: Record<string, unknown>): void
  /** Lua -> NUI request: resolves with what the page's `nui.handle` answered. */
  request(channel: string, name: string, data?: unknown, opts?: { timeoutMs?: number }): Promise<unknown>
  /** Answers the page's `nui.invoke(name, …)`. Throwing gives the page a `handler_error`. */
  onRequest<K extends keyof Rpc & string>(
    name: K,
    fn: (data: ReqOf<Rpc[K]>) => ResOf<Rpc[K]> | Promise<ResOf<Rpc[K]>>,
    opts?: MockRequestOptions,
  ): Off
  /** Sees `page.emit` / `nui.emit` (the `ui_event` post). */
  onEvent(channel: string, event: string, fn: (data: unknown) => void): Off
  clear(): void
}

export interface MockTransport<Rpc extends object = RpcMap, Pages extends object = PagePropsMap> {
  transport: TransportImpl
  lua: LuaMock<Rpc, Pages>
}

const RANK: Record<string, number> = { page: 2, modal: 3 }

function wait(ms: number, signal?: AbortSignal): Promise<void> {
  if (!ms) return Promise.resolve()
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => resolve(), ms)
    if (signal) {
      signal.addEventListener('abort', () => {
        clearTimeout(timer)
        const err = new Error('aborted')
        err.name = 'AbortError'
        reject(err)
      }, { once: true })
    }
  })
}

export function createMockTransport<Rpc extends object = RpcMap, Pages extends object = PagePropsMap>(
  options: MockOptions = {},
): MockTransport<Rpc, Pages> {
  const posts: MockPost[] = []
  const messages: MockMessage[] = []
  const decls = new Map<string, { type: PageType; keepInput: boolean; owner: string }>()
  const openOrder: string[] = []
  const handlers = new Map<string, { fn: (d: unknown) => unknown; delayMs?: number }>()
  const listeners = new Map<string, Set<(data: unknown) => void>>()
  const pending = new Map<string | number, { resolve(v: unknown): void; reject(e: unknown): void }>()
  let focus: FocusEntry[] = []
  let rid = 0

  // Without an explicit `deliver` the shell's own dev shim is used — `runtime/transport.ts` puts
  // `window.__core.send` there the moment it is imported, which in a dev host is long before the
  // first message. With no window at all (a `node --test` run) the message is only recorded.
  const send = options.deliver || ((msg: MockMessage) => {
    const shim = (globalThis as { __core?: { send?(m: unknown): void } }).__core
    if (shim && typeof shim.send === 'function') shim.send(msg)
  })

  const out = (msg: MockMessage): void => {
    messages.push(msg)
    send(msg)
  }

  /** §38.9: the exclusive page, then modals in open order. Overlays never take focus. */
  function refreshFocus(): void {
    const stack: FocusEntry[] = []
    for (const id of openOrder) {
      const decl = decls.get(id)
      if (!decl || !RANK[decl.type]) continue
      stack.push({ key: decl.type + ':' + id, layer: decl.type as FocusEntry['layer'], id, owner: decl.owner })
    }
    stack.sort((a, b) => RANK[a.layer] - RANK[b.layer])
    focus = stack
    out({ action: 'focus', focused: stack.length > 0, stack })
  }

  function doOpen(id: string, props?: unknown): void {
    const decl = decls.get(id)
    // A `page` is exclusive: opening one closes the other (client/ui.lua does the same).
    if (decl && decl.type === 'page') {
      for (const other of openOrder.slice()) {
        if (other !== id && decls.get(other)?.type === 'page') doClose(other)
      }
    }
    if (!openOrder.includes(id)) openOrder.push(id)
    out({ action: 'page:open', id, props: (props as Record<string, unknown>) || {} })
    refreshFocus()
  }

  function doClose(id?: string): void {
    const target = id || (focus.length ? focus[focus.length - 1].id : openOrder[openOrder.length - 1])
    if (!target) return
    const at = openOrder.indexOf(target)
    if (at >= 0) openOrder.splice(at, 1)
    out({ action: 'page:close', id: target })
    refreshFocus()
  }

  function answerRequest(body: CbUiRequest, signal?: AbortSignal): Promise<RequestResult> {
    const entry = handlers.get(body.n)
    if (!entry) {
      return Promise.resolve({ ok: false, error: { code: 'no_handler', message: 'no Lua handler for ' + body.c + '.' + body.n } })
    }
    const delayMs = entry.delayMs != null ? entry.delayMs : options.delayMs || 0
    // The wait is the TRANSPORT (a held `cb` that the shell may abort); only the handler's own
    // failure becomes a RequestResult. Catching both here would turn every timeout into a
    // `handler_error` and the page would never see `timeout`.
    return wait(delayMs, signal).then(() => Promise.resolve()
      .then(() => entry.fn(body.d))
      .then(
        (data) => ({ ok: true, data } as RequestResult),
        (err: unknown) => ({
          ok: false,
          error: { code: 'handler_error', message: (err && (err as Error).message) || String(err) },
        } as RequestResult),
      ))
  }

  const transport: TransportImpl = {
    resource: options.resource === undefined ? 'core' : options.resource,
    send(name, body, signal) {
      posts.push({ name, body, at: Date.now() })
      if (name === 'ui_request') return answerRequest(body as CbUiRequest, signal)
      if (name === 'ui_response') {
        const res = body as CbUiResponse
        const waiter = pending.get(res.rid)
        if (waiter) {
          pending.delete(res.rid)
          if (res.ok) waiter.resolve(res.data)
          else waiter.reject(Object.assign(new Error((res.error && res.error.message) || 'request failed'), { name: 'NuiError', code: (res.error && res.error.code) || 'handler_error' }))
        }
        return Promise.resolve({})
      }
      if (name === 'ui_event') {
        const ev = body as CbUiEvent
        const set = listeners.get(ev.page + '\u0000' + ev.event)
        if (set) for (const fn of Array.from(set)) fn(ev.data)
        return Promise.resolve({})
      }
      if (name === 'ui_close') {
        doClose((body as CbUiClose).page)
        return Promise.resolve({})
      }
      return Promise.resolve({})
    },
  }

  const lua: LuaMock<Rpc, Pages> = {
    posts,
    messages,
    get focus() { return focus },
    get openPages() { return openOrder },

    send: out,

    registerPlugin(id, opts) {
      const pages = (opts && opts.pages) || {}
      for (const pageId of Object.keys(pages)) {
        const raw = pages[pageId]
        const decl: MockPageDecl = typeof raw === 'string' ? { type: raw } : raw || {}
        const entry = { type: decl.type || 'page', keepInput: decl.keepInput === true, owner: id }
        decls.set(pageId, entry)
        out({ action: 'page:register', id: pageId, type: entry.type, keepInput: entry.keepInput, owner: id })
      }
    },

    open(id, props) { doOpen(id, props) },
    close(id) { doClose(id) },

    update(id, partial) {
      const ops: PatchOp[] = Object.keys(partial as object).map((key) => ({ p: key, v: (partial as Record<string, unknown>)[key] }))
      if (ops.length) out({ action: 'page:patch', id, ops })
    },

    patch(id, path, ...value) {
      // §38.10: dot-joined segments in LUA's view (1-based) — the path is passed through exactly as
      // written, no index arithmetic; the shell maps `n` to `arr[n - 1]`. `v` absent deletes.
      const p = Array.isArray(path) ? path.join('.') : String(path)
      const op: PatchOp = value.length ? { p, v: value[0] } : { p }
      out({ action: 'page:patch', id, ops: [op] })
    },

    emit(channel, event, data) { out({ action: 'page:event', id: channel, event, data }) },

    feed(channel, values) { out({ action: 'feed', c: { [channel]: values } }) },

    request(channel, name, data, opts) {
      const id = ++rid
      return new Promise((resolve, reject) => {
        const ms = (opts && opts.timeoutMs) || 10000
        const timer = setTimeout(() => {
          if (!pending.has(id)) return
          pending.delete(id)
          reject(Object.assign(new Error(channel + '.' + name + ' timed out'), { name: 'NuiError', code: 'timeout' }))
        }, ms)
        // The timer must never be the reason a process stays alive (`node --test`).
        ;(timer as unknown as { unref?(): void }).unref?.()
        const settle = (fn: (v: never) => void) => (value: never) => {
          clearTimeout(timer)
          fn(value)
        }
        pending.set(id, { resolve: settle(resolve as (v: never) => void), reject: settle(reject as (v: never) => void) })
        out({ action: 'page:request', id: channel, rid: id, name, data })
      })
    },

    onRequest(name, fn, opts) {
      handlers.set(name, { fn: fn as (d: unknown) => unknown, delayMs: opts && opts.delayMs })
      return () => { handlers.delete(name) }
    },

    onEvent(channel, event, fn) {
      // The separator is written as an ESCAPE, never as a raw byte: a control character in the
      // source makes the file binary to git, grep and `file`.
      const key = channel + '\u0000' + event
      let set = listeners.get(key)
      if (!set) { set = new Set(); listeners.set(key, set) }
      set.add(fn)
      return () => { set.delete(fn) }
    },

    clear() {
      posts.length = 0
      messages.length = 0
    },
  }

  return { transport, lua }
}
