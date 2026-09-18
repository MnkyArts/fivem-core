// core UI runtime — error attribution, reporting and the global net (DESIGN §38.12).
//
// One realm hosts every plugin, so the only thing that makes a crash survivable is knowing WHOSE
// crash it was. Three sources of truth, in this order:
//   1. the `PluginBoundary` that caught it   — it knows the page and its owner outright,
//   2. the stack's first `cfx-nui-<resource>` URL — for a listener/timer/promise with no boundary,
//   3. nothing, and the line says so.
//
// Two lessons from the prototype that this file exists to encode:
//   * in a PRODUCTION Vue build `info` is `https://vuejs.org/error-reference/#runtime-<code>`, not
//     the readable string (0 setup, 1 render, 5 native handler, 6 component handler), and
//   * an event-handler throw leaves a perfectly valid tree — reporting it is right, replacing the
//     page with a fallback because a button misbehaved is not.

import { post } from './transport.ts'
import type { CbUiError } from './protocol.ts'

/** `cfx-nui-<resource>` is the origin FiveM serves a resource's files from (§38.1). */
const NUI_ORIGIN_RE = /cfx-nui-([a-zA-Z0-9_\-.]+)/
const RUNTIME_CODE_RE = /#runtime-(\d+)/

/** Vue's ErrorCodes for the kinds this shell branches on. */
const SETUP = 0
const RENDER = 1
const NATIVE_HANDLER = 5
const COMPONENT_HANDLER = 6

/** Test/dev seam: map a stack origin onto a resource (`http://127.0.0.1:8802` -> `alpha`). */
const originMap = new Map<string, string>()

export function setOriginMap(map: Record<string, string> | null): void {
  originMap.clear()
  if (!map) return
  for (const origin of Object.keys(map)) originMap.set(origin, map[origin])
}

let notifyFn: ((msg: { message: string; type?: string; title?: string; duration?: number }) => unknown) | null = null

/** The shell hands its toast function in; the runtime never imports the store. */
export function setNotify(fn: typeof notifyFn): void {
  notifyFn = fn
}

export function notify(message: string, type: string): void {
  if (!notifyFn) return
  try {
    notifyFn({ message, type })
  } catch (err) {
    console.error('[core:ui] notify failed', err)
  }
}

/** The numeric Vue error code behind `info`, or null for a string we do not recognise. */
export function errCode(info: string | null | undefined): number | null {
  const m = RUNTIME_CODE_RE.exec(info || '')
  return m ? Number(m[1]) : null
}

/** True for a throw that came out of an event handler — the tree below it is still fine. */
export function isHandlerError(info: string | null | undefined): boolean {
  const code = errCode(info)
  if (code === NATIVE_HANDLER || code === COMPONENT_HANDLER) return true
  return /handler/i.test(info || '')
}

/** True for setup/render — the subtree cannot be trusted and has to be replaced. */
export function isFatalRenderError(info: string | null | undefined): boolean {
  const code = errCode(info)
  if (code === SETUP || code === RENDER) return true
  return !isHandlerError(info)
}

/**
 * The component's name. `onErrorCaptured` hands over the PUBLIC instance, so the type lives at
 * `instance.$.type` and `$options.name` is undefined for every SFC.
 *
 * Order matters and matches Vue's own `getComponentName`: an EXPLICIT `name` (the `name:` option or
 * `defineOptions({ name })`) beats `__name`, which the SFC compiler fills in from the FILE name — a
 * developer who renamed a component in code meant that name to be the one in the error line.
 */
export function componentName(instance: unknown): string {
  const inst = instance as { $?: { type?: { __name?: string; name?: string } }; type?: { __name?: string; name?: string }; $options?: { name?: string } } | null
  if (!inst) return '(anonymous)'
  const type = (inst.$ && inst.$.type) || inst.type
  return (type && (type.name || type.__name)) || (inst.$options && inst.$options.name) || '(anonymous)'
}

/** The resource an error came out of, read off the first known origin in its stack. */
export function attribute(err: unknown): string | null {
  const stack = err && typeof err === 'object' ? (err as { stack?: unknown }).stack : null
  const text = typeof stack === 'string' ? stack : typeof err === 'string' ? err : ''
  if (!text) return null
  const m = NUI_ORIGIN_RE.exec(text)
  if (m) return m[1]
  for (const origin of originMap.keys()) {
    if (text.indexOf(origin) !== -1) return originMap.get(origin) as string
  }
  return null
}

// ---------------------------------------------------------------- reporting

export interface ErrorEntry {
  plugin?: string | null
  page?: string | null
  component?: string | null
  error: unknown
  info?: string | null
  /** Dropped silently when the same instance already reported (one line per crash, §38.12). */
  once?: unknown
}

const reported = new WeakSet<object>()
const log: CbUiError[] = []
const LOG_MAX = 50

/** The last 50 attributed errors — what the inspector shows and a test reads. */
export function errorLog(): readonly CbUiError[] {
  return log
}

export function clearErrorLog(): void {
  log.length = 0
}

function messageOf(err: unknown): string {
  if (err instanceof Error) return err.message || String(err)
  if (err && typeof err === 'object' && typeof (err as { message?: unknown }).message === 'string') return (err as { message: string }).message
  return String(err)
}

/** Logs once, posts `ui_error`, returns the wire record (null when it was a duplicate). */
export function report(entry: ErrorEntry): CbUiError | null {
  if (entry.once && typeof entry.once === 'object') {
    if (reported.has(entry.once as object)) return null
    reported.add(entry.once as object)
  }
  const err = entry.error
  const plugin = entry.plugin || attribute(err)
  const record: CbUiError = {
    plugin: plugin || null,
    page: entry.page || null,
    component: entry.component || null,
    message: messageOf(err),
    stack: err && typeof err === 'object' && typeof (err as { stack?: unknown }).stack === 'string' ? ((err as { stack: string }).stack as string).slice(0, 2000) : null,
    info: entry.info || null,
  }
  log.push(record)
  if (log.length > LOG_MAX) log.splice(0, log.length - LOG_MAX)
  console.error('[core:ui] ' + (record.plugin || 'shell') + (record.page ? '/' + record.page : '') + (record.component ? ' <' + record.component + '>' : '') + ':', err)
  post('ui_error', record)
  return record
}

// ---------------------------------------------------------------- the global net

let uninstall: (() => void) | null = null

/**
 * `window.onerror` / `unhandledrejection`: a listener, timer or promise that threw outside any
 * component tree. Attribution is the stack's `cfx-nui-<resource>` URL — nothing is swallowed.
 */
export function installGlobalHandlers(target?: EventTarget | null): () => void {
  const host = target || (typeof window !== 'undefined' ? window : null)
  if (!host || typeof host.addEventListener !== 'function') return () => {}
  if (uninstall) uninstall()

  const onError = (event: Event) => {
    const e = event as ErrorEvent
    const err = e.error || e.message || 'unknown error'
    report({ error: err, info: 'window.onerror', once: typeof err === 'object' ? err : undefined })
  }
  const onRejection = (event: Event) => {
    const e = event as PromiseRejectionEvent
    const err = e.reason
    report({ error: err, info: 'unhandledrejection', once: typeof err === 'object' && err ? err : undefined })
  }

  host.addEventListener('error', onError)
  host.addEventListener('unhandledrejection', onRejection)
  uninstall = () => {
    host.removeEventListener('error', onError)
    host.removeEventListener('unhandledrejection', onRejection)
    uninstall = null
  }
  return uninstall
}

/** Runs `fn`, attributes anything it throws and swallows it. Used for every plugin callback. */
export function guard<T>(entry: Omit<ErrorEntry, 'error'>, fn: () => T): T | undefined {
  try {
    return fn()
  } catch (err) {
    report(Object.assign({}, entry, { error: err }))
    return undefined
  }
}
