// core UI runtime — the NUI <-> Lua transport (DESIGN §38.8; replaces the body of src/bridge.js).
//
//   post(name, data, opts?)              -> Promise<object>  ALWAYS resolves (the §7.5 contract)
//   request(channel, name, data, opts?)  -> Promise<result>  rejects with a NuiError
//   onMessage(action, fn)                -> off()            SendNUIMessage dispatch
//   setTransport(impl) / resetTransport()                    the mock the dev host + tests mount
//   deliver(msg)                                             push an incoming message by hand
//
// A FiveM NUI callback POST is held by Lua for as long as it likes and a POST to a stopped
// resource never answers at all (§38.1), so EVERY fetch carries an AbortController deadline.
// Nothing here touches the store, Vue or the DOM at module scope beyond the one `message`
// listener, which is skipped when there is no `window` — `node --test` imports this file directly.

import type { NuiErrorCode, NuiErrorShape, RequestOptions } from '../../sdk/src/contract.ts'
import type { NuiCallbackName, RequestResult } from './protocol.ts'

const DEFAULT_TIMEOUT_MS = 10000
/** Lua clamps a request's own timeout; the fetch gets that plus a grace for the round trip. */
const REQUEST_GRACE_MS = 500

const hasWindow = typeof window !== 'undefined'
const hasParent = hasWindow && typeof (window as unknown as { GetParentResourceName?: unknown }).GetParentResourceName === 'function'
const RESOURCE: string | null = hasParent ? (window as unknown as { GetParentResourceName(): string }).GetParentResourceName() : null

/** true when the page runs in a plain browser (agent-browser, `npm run dev`, Storybook, a test). */
export const isDev: boolean = !hasParent

/** The error every rejecting transport path throws. `name` is the cross-bundle marker: a plugin
 *  bundles its own `NuiError` class, so `instanceof` cannot be the test — `err.name` is. */
export class NuiError extends Error {
  code: NuiErrorCode
  constructor(code: NuiErrorCode, message?: string) {
    super(message || code)
    this.name = 'NuiError'
    this.code = code
  }
}

export function isNuiError(err: unknown): err is NuiError {
  return !!err && typeof err === 'object' && (err as { name?: string }).name === 'NuiError'
}

// ---------------------------------------------------------------- swappable implementation

export interface TransportImpl {
  /** Resolves with the parsed body, or REJECTS (timeout, non-JSON, network). */
  send(name: string, body: unknown, signal: AbortSignal | undefined, timeoutMs: number): Promise<unknown>
  /** Diagnostics only. */
  readonly resource?: string | null
}

function fetchImpl(): TransportImpl {
  return {
    resource: RESOURCE,
    send(name, body, signal, timeoutMs) {
      if (isDev) {
        // The dev/offline shim: no NUI bridge exists, so the post is only logged. The shell
        // regression suite reads exactly this line — do not reshape it.
        console.log('[core:ui] post', name, body)
        // Menu controls wait for an acknowledgement; offline stories accept their simulated changes.
        return Promise.resolve(name === 'menu_change' ? { ok: true } : {})
      }
      const ctrl = new AbortController()
      const timer = setTimeout(() => ctrl.abort(), timeoutMs)
      if (signal) {
        if (signal.aborted) ctrl.abort()
        else signal.addEventListener('abort', () => ctrl.abort(), { once: true })
      }
      return fetch('https://' + RESOURCE + '/' + name, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=UTF-8' },
        body: JSON.stringify(body),
        signal: ctrl.signal,
      })
        .then((res) => res.json())
        .finally(() => clearTimeout(timer))
    },
  }
}

let impl: TransportImpl = fetchImpl()

/** Mount a mock (`@core/ui/dev`, Storybook, the unit tests). Returns the previous one. */
export function setTransport(next: TransportImpl): TransportImpl {
  const prev = impl
  impl = next
  return prev
}

export function resetTransport(): void {
  impl = fetchImpl()
}

export function transportResource(): string | null {
  return impl.resource === undefined ? RESOURCE : impl.resource
}

// ---------------------------------------------------------------- counters (§38.14)

const counters = {
  out: Object.create(null) as Record<string, number>,
  in: Object.create(null) as Record<string, number>,
  bytesOut: 0,
  bytesIn: 0,
}
let countBytes = false

/** Byte counting is off in production (it costs a JSON.stringify per message). */
export function measureBytes(on: boolean): void {
  countBytes = !!on
  if (!on) {
    counters.bytesOut = 0
    counters.bytesIn = 0
  }
}

export function stats(): { out: Record<string, number>; in: Record<string, number>; bytesOut: number; bytesIn: number; bytes: boolean } {
  return {
    out: Object.assign(Object.create(null), counters.out),
    in: Object.assign(Object.create(null), counters.in),
    bytesOut: counters.bytesOut,
    bytesIn: counters.bytesIn,
    bytes: countBytes,
  }
}

export function resetStats(): void {
  counters.out = Object.create(null)
  counters.in = Object.create(null)
  counters.bytesOut = 0
  counters.bytesIn = 0
}

function sizeOf(value: unknown): number {
  try {
    return JSON.stringify(value === undefined ? null : value).length
  } catch (err) {
    return 0
  }
}

// ---------------------------------------------------------------- taps (`window.__core`)

/** Observer hook used by Storybook's Lua panel and the offline tests — never the transport. */
function tap(hook: 'onPost' | 'onMessage', a: unknown, b?: unknown): void {
  if (!hasWindow) return
  const shim = (window as unknown as { __core?: Record<string, unknown> }).__core
  if (!shim || typeof shim[hook] !== 'function') return
  try {
    ;(shim[hook] as (x: unknown, y?: unknown) => void)(a, b)
  } catch (err) {
    console.error('[core:ui] __core.' + hook + ' failed', err)
  }
}

// ---------------------------------------------------------------- posting

/** The raw post: REJECTS on timeout, abort, a non-JSON body or a dead bridge. */
export function rawPost(name: string, data?: unknown, opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<unknown> {
  const body = data === undefined || data === null ? {} : data
  const timeoutMs = opts && opts.timeoutMs != null ? opts.timeoutMs : DEFAULT_TIMEOUT_MS
  counters.out[name] = (counters.out[name] || 0) + 1
  if (countBytes) counters.bytesOut += sizeOf(body)
  tap('onPost', name, body)
  let p: Promise<unknown>
  try {
    p = impl.send(name, body, opts && opts.signal, timeoutMs)
  } catch (err) {
    p = Promise.reject(err)
  }
  return p.then((res) => {
    if (countBytes) counters.bytesIn += sizeOf(res)
    return res
  })
}

/**
 * Fire a NUI callback. Never rejects: a caller writes `post('ui_close', { page })` and is done.
 * A failure is one console.error and an empty object, exactly as before §38.
 */
export function post(name: NuiCallbackName | string, data?: unknown, opts?: { timeoutMs?: number; signal?: AbortSignal }): Promise<Record<string, unknown>> {
  return rawPost(name, data, opts).then(
    (res) => (res && typeof res === 'object' ? (res as Record<string, unknown>) : {}),
    (err) => {
      console.error('[core:ui] post failed', name, err)
      return {}
    },
  )
}

function codeOf(err: unknown): NuiErrorCode {
  if (isNuiError(err)) return err.code
  const name = err && typeof err === 'object' ? (err as { name?: string }).name : ''
  if (name === 'AbortError' || name === 'TimeoutError') return 'timeout'
  return 'transport'
}

/** The codes the contract knows. Lua may answer with one it invented (`shell_reloaded`); anything
 *  the SDK cannot name becomes `transport` so a plugin's `catch` never sees a surprise string. */
const KNOWN_CODES: Record<string, true> = {
  timeout: true, aborted: true, no_handler: true, handler_error: true, bad_request: true,
  bad_result: true, resource_stopped: true, plugin_disposed: true, transport: true,
}

function wireCode(code: unknown): NuiErrorCode {
  return typeof code === 'string' && KNOWN_CODES[code] ? (code as NuiErrorCode) : 'transport'
}

/**
 * NUI -> Lua request/response (§38.8). Posts `ui_request { c, n, d, t }`; Lua holds the callback
 * until its handler answers. Rejects with a `NuiError` for every failure mode, including a
 * transport that never came back.
 */
export function request(channel: string, name: string, data?: unknown, opts?: RequestOptions): Promise<unknown> {
  const signal = opts && opts.signal
  if (signal && signal.aborted) return Promise.reject(new NuiError('aborted', 'request aborted before it was sent'))
  const t = opts && opts.timeoutMs != null && opts.timeoutMs > 0 ? Math.floor(opts.timeoutMs) : DEFAULT_TIMEOUT_MS
  const body = { c: channel, n: name, d: data === undefined ? null : data, t }
  return rawPost('ui_request', body, { timeoutMs: t + REQUEST_GRACE_MS, signal }).then(
    (res) => {
      const result = res as RequestResult | null
      if (!result || typeof result !== 'object') throw new NuiError('bad_result', channel + '.' + name + ' answered with a non-object')
      if (result.ok === false) {
        const error = (result as { error?: NuiErrorShape }).error
        const message = (error && error.message) || (channel + '.' + name + ' failed')
        throw new NuiError(error ? wireCode(error.code) : 'handler_error', message)
      }
      return (result as { data?: unknown }).data
    },
    (err) => {
      if (signal && signal.aborted) throw new NuiError('aborted', channel + '.' + name + ' was aborted')
      if (isNuiError(err)) throw err
      const code = codeOf(err)
      throw new NuiError(code, channel + '.' + name + ': ' + (err && (err as Error).message ? (err as Error).message : String(err)))
    },
  )
}

// ---------------------------------------------------------------- incoming (`SendNUIMessage`)

const handlers = new Map<string, Set<(msg: Record<string, unknown>) => void>>()

/** Dispatch one incoming message object. The mock transport calls this directly. */
export function deliver(msg: unknown): void {
  if (!msg || typeof msg !== 'object') return
  const action = (msg as { action?: unknown }).action
  if (typeof action !== 'string') return
  counters.in[action] = (counters.in[action] || 0) + 1
  if (countBytes) counters.bytesIn += sizeOf(msg)
  tap('onMessage', msg)
  const set = handlers.get(action)
  if (!set) return
  for (const fn of Array.from(set)) {
    try {
      fn(msg as Record<string, unknown>)
    } catch (err) {
      console.error('[core:ui] handler failed for', action, err)
    }
  }
}

/** Subscribe to one `action` from Lua. Returns an unsubscribe function. */
export function onMessage(action: string, handler: (msg: Record<string, unknown>) => void): () => void {
  let set = handlers.get(action)
  if (!set) {
    set = new Set()
    handlers.set(action, set)
  }
  set.add(handler)
  return () => {
    set.delete(handler)
  }
}

if (hasWindow) {
  window.addEventListener('message', (event: MessageEvent) => deliver(event && event.data))

  // Dev/offline driver (DESIGN §7.5). `onPost`/`onMessage` are assigned onto it by Storybook's
  // Lua panel, so the object is EXTENDED, never replaced, when something got there first.
  const shim = ((window as unknown as { __core?: Record<string, unknown> }).__core || {}) as Record<string, unknown>
  shim.send = (msg: unknown) => {
    window.dispatchEvent(new MessageEvent('message', { data: msg }))
    return msg
  }
  shim.isDev = isDev
  shim.resource = RESOURCE
  shim.stats = stats
  // The integration suites drive the REAL shell in a plain browser: `setTransport` lets an
  // agent-browser script answer `ui_request` and capture every post without monkey-patching
  // `fetch` or `console.log` (§38.15).
  shim.setTransport = setTransport
  shim.resetTransport = resetTransport
  shim.deliver = deliver
  ;(window as unknown as { __core: Record<string, unknown> }).__core = shim
}
