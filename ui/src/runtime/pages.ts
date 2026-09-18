// core UI runtime — page records, props, patches and lifecycle (DESIGN §38.6, §38.10, §7.4).
//
// Lua declares a page (`page:register` with an owner), the owner's plugin provides the component,
// Lua shows it (`page:open`). Three separate facts, three separate failure modes — this file keeps
// them apart and never lets one wait on a guess: a `page:open` for a plugin that is still loading
// waits on THAT plugin's promise, not on a fixed delay.
//
// The props object of an id is stable for the LIFE OF THE SHELL (§7.4). A plugin restart replaces
// the record and re-imports the module; a page store that captured `usePage(id).props` once must
// keep receiving every later open. Two shell-regression checks pin exactly that.

import { markRaw, reactive, ref, shallowReactive } from 'vue'
import type { Component } from 'vue'
import type { Off, PageDefinition, PageHandle } from '../../sdk/src/contract.ts'
import type { MsgPageOpen, MsgPageRegister, PageType, PatchOp } from './protocol.ts'
import { post } from './transport.ts'
import { bindRelease, createScope, withScope } from './scope.ts'
import type { OwnedScope } from './scope.ts'
import { guard, notify, report } from './errors.ts'
import * as Plugins from './plugins.ts'

export interface PageRecord {
  id: string
  type: PageType
  owner: string | null
  keepInput: boolean
  component: Component | null
  registered: boolean
  props: Record<string, unknown>
  keepAlive: boolean
  reactivity: 'deep' | 'shallow'
  /** True while the component is still being resolved (plugin loading, lazy chunk in flight). */
  loading: boolean
  error: string | null
  /** Did `onOpen` already run for the CURRENT open cycle? A page opened before its plugin was
   *  ready gets its hook when the component finally resolves, not never (F2). */
  opened: boolean
  /** Set by `PluginBoundary` when an instance died of a render/setup error. */
  crashed: boolean
  /** Bumped on the `page:open` after a crash — PageHost keys every instance with it, so the next
   *  open really remounts a subtree Vue would otherwise consider unchanged (§38.12). */
  epoch: number
}

export interface PageStoreSlice {
  pages: Record<string, PageRecord>
  openPage: string | null
  overlays: Record<string, true>
  modals: string[]
}

let state: PageStoreSlice = reactive({ pages: {}, openPage: null, overlays: {}, modals: [] }) as PageStoreSlice

export function attachPageStore(slice: PageStoreSlice): void {
  state = slice
}

export function pageState(): PageStoreSlice {
  return state
}

const propsById = new Map<string, Record<string, unknown>>()
const legacyComponents = new Map<string, Component>()
const definitions = new Map<string, PageDefinition>()
const scopes = new Map<string, OwnedScope>()
const handles = new Map<string, PageHandle>()
const listeners = new Map<string, Set<(data: unknown) => void>>()
const waiters = new Map<string, Set<(c: Component | null) => void>>()
const warned = new Set<string>()
/** One wait token PER PAGE: a second page opening must not silence the first one's timeout (F3). */
const openTokens = new Map<string, number>()
/** Bumped whenever a plugin activation goes away. PageHost drops its whole `<KeepAlive>` when this
 *  changes, so a cached instance can never outlive the module that created it. Reactive on purpose:
 *  the shell has to re-render on the bump. */
export const keepAliveEpoch = ref(0)

// ---------------------------------------------------------------- props (stable identity)

/** The one props object of an id. Deep-reactive unless the definition asked for `shallow`. */
export function propsFor(id: string, mode?: 'deep' | 'shallow'): Record<string, unknown> {
  let props = propsById.get(id)
  if (!props) {
    props = mode === 'shallow' ? shallowReactive({} as Record<string, unknown>) : reactive({} as Record<string, unknown>)
    propsById.set(id, props)
  }
  return props
}

function setProps(rec: PageRecord, next: unknown): string[] {
  const changed: string[] = []
  for (const key of Object.keys(rec.props)) {
    changed.push(key)
    delete rec.props[key]
  }
  if (next && typeof next === 'object') {
    for (const key of Object.keys(next as object)) {
      rec.props[key] = (next as Record<string, unknown>)[key]
      if (changed.indexOf(key) === -1) changed.push(key)
    }
  }
  return changed
}

// ---------------------------------------------------------------- records

function newRecord(id: string, extra?: Partial<PageRecord>): PageRecord {
  // Lua replays `plugin:register` BEFORE `page:register` (§38.4), so the owner's definition —
  // and with it `reactivity` — is normally known the first time the props object is created. A
  // page that is touched even earlier (an `ensurePage` from `CoreUI.usePage`) gets the deep
  // default and keeps it: props IDENTITY outranks the proxy flavour (§7.4).
  const owner = (extra && extra.owner) || null
  const known = owner ? Plugins.pageDefinition(owner, id) : null
  const rec: PageRecord = {
    id,
    type: 'page',
    owner: null,
    keepInput: false,
    component: legacyComponents.get(id) || null,
    registered: legacyComponents.has(id),
    props: propsFor(id, known && known.reactivity === 'shallow' ? 'shallow' : 'deep'),
    keepAlive: false,
    reactivity: 'deep',
    loading: false,
    error: null,
    opened: false,
    crashed: false,
    epoch: 0,
  }
  if (extra) Object.assign(rec, extra)
  return rec
}

export function ensurePage(id: string): PageRecord {
  let rec = state.pages[id]
  if (!rec) {
    rec = newRecord(id)
    state.pages[id] = rec
  }
  return rec
}

/** `page:register` — Lua is the authority for id, type, keepInput and OWNER (§38.3). */
export function registerPage(msg: MsgPageRegister): PageRecord {
  const id = String(msg.id)
  const owner = msg.owner ? String(msg.owner) : null
  const prev = state.pages[id]
  const type: PageType = msg.type === 'overlay' || msg.type === 'modal' ? msg.type : 'page'
  if (prev) {
    prev.type = type
    prev.keepInput = !!msg.keepInput
    prev.owner = owner
  } else {
    state.pages[id] = newRecord(id, { type, keepInput: !!msg.keepInput, owner })
  }
  const rec = state.pages[id]
  resolveComponent(rec)
  return rec
}

/** `page:unregister` — the declaration is gone; the props object is not (§7.4). */
export function unregisterPage(id: string): void {
  const rec = state.pages[id]
  if (rec) closeRecord(rec, true)
  delete state.pages[id]
  definitions.delete(id)
}

// ---------------------------------------------------------------- component resolution

function ownerMismatch(id: string, owner: string | null): void {
  for (const rec of Plugins.list()) {
    if (rec.id === owner) continue
    if (Plugins.pageIdsOf(rec.id).indexOf(id) === -1) continue
    const key = 'mismatch:' + id + ':' + rec.id
    if (warned.has(key)) return
    warned.add(key)
    console.error('[core:ui] plugin "' + rec.id + '" provides the page "' + id + '", but Lua registered it for owner "' + (owner || '(none)') + '" — a plugin may only provide pages of its own resource')
    return
  }
}

/** The definition currently in force: the owner plugin's page map, then the legacy CoreUI map. */
export function definitionFor(rec: PageRecord): PageDefinition | null {
  if (rec.owner) {
    const def = Plugins.pageDefinition(rec.owner, rec.id)
    if (def) return def
  }
  const legacy = legacyComponents.get(rec.id)
  if (legacy) return { component: legacy }
  // Nobody can render this id. If ANOTHER plugin provides it, that is the bug worth naming.
  if (rec.owner) ownerMismatch(rec.id, rec.owner)
  return null
}

function unwrap(mod: unknown): Component | null {
  if (!mod) return null
  const candidate = (mod as { default?: Component }).default || (mod as Component)
  return candidate ? (markRaw(candidate as object) as Component) : null
}

/**
 * Puts the resolved component on the record. A function value is ALWAYS a loader (§ contract), so
 * a lazy chunk resolves asynchronously and the record stays `loading` until it lands.
 */
export function resolveComponent(rec: PageRecord): Component | null {
  const def = definitionFor(rec)
  if (!def) {
    rec.component = null
    rec.registered = false
    return null
  }
  definitions.set(rec.id, def)
  rec.keepAlive = def.keepAlive === true
  rec.reactivity = def.reactivity === 'shallow' ? 'shallow' : 'deep'
  const component = def.component
  if (typeof component === 'function') {
    rec.loading = true
    void Promise.resolve()
      .then(() => (component as () => Promise<Component>)())
      .then((mod) => {
        const resolved = unwrap(mod)
        rec.loading = false
        if (!resolved) throw new Error('page "' + rec.id + '": the component loader resolved to nothing')
        // Cache it back INTO the plugin's own definition, so a re-register (or a second open)
        // never runs the loader twice. `normalizePage` made that object per activation, so a
        // restart still re-imports the chunk.
        def.component = resolved
        rec.component = resolved
        rec.registered = true
        settleWaiters(rec.id, resolved)
        componentReady(rec)
      })
      .catch((err) => {
        rec.loading = false
        rec.error = err && (err as Error).message ? (err as Error).message : String(err)
        report({ plugin: rec.owner, page: rec.id, error: err, info: 'page component loader' })
        settleWaiters(rec.id, null)
      })
    return null
  }
  rec.component = markRaw(component as object) as Component
  rec.registered = true
  settleWaiters(rec.id, rec.component)
  componentReady(rec)
  return rec.component
}

/**
 * The component of an OPEN page just became available. Give the page its scope and run `onOpen` —
 * this is the hook a server-opened page would otherwise lose, because `page:open` regularly arrives
 * before the owner's module has even been fetched (F2).
 */
function componentReady(rec: PageRecord): void {
  if (!rec.component || rec.opened || !isPageOpen(rec.id)) return
  if (!scopes.has(rec.id)) scopes.set(rec.id, createScope('page:' + rec.id))
  rec.opened = true
  hook(rec, 'onOpen')
}

function settleWaiters(id: string, component: Component | null): void {
  const set = waiters.get(id)
  if (!set) return
  waiters.delete(id)
  for (const resolve of Array.from(set)) resolve(component)
}

/** Legacy `CoreUI.registerPage(id, component)` — the map used when the owner has no plugin. */
export function setPageComponent(id: string, component: Component | null): PageRecord {
  const raw = component ? (markRaw(component as object) as Component) : null
  if (raw) legacyComponents.set(id, raw)
  else legacyComponents.delete(id)
  const rec = ensurePage(id)
  resolveComponent(rec)
  if (raw && !rec.component) {
    rec.component = raw
    rec.registered = true
    settleWaiters(id, raw)
  }
  return rec
}

/** Legacy waiter (DESIGN §7.4). Resolves with the component, or null after `timeoutMs`. */
export function whenRegistered(id: string, timeoutMs = 5000): Promise<Component | null> {
  const rec = state.pages[id]
  if (rec && rec.component) return Promise.resolve(rec.component)
  return new Promise((resolve) => {
    let set = waiters.get(id)
    if (!set) {
      set = new Set()
      waiters.set(id, set)
    }
    const done = (component: Component | null) => {
      set.delete(done)
      resolve(component || null)
    }
    set.add(done)
    setTimeout(() => {
      if (set.has(done)) done(null)
    }, timeoutMs)
  })
}

// ---------------------------------------------------------------- events + handles

export function onPageEvent(id: string, event: string, fn: (data: unknown) => void): Off {
  const key = id + '|' + event
  let set = listeners.get(key)
  if (!set) {
    set = new Set()
    listeners.set(key, set)
  }
  set.add(fn)
  return () => {
    set.delete(fn)
  }
}

/** `page:event` — `id` is a page id OR a plugin channel (§38.5). Same dispatch either way. */
export function emitPageEvent(id: string, event: string, data?: unknown): void {
  const set = listeners.get(id + '|' + event)
  if (!set) return
  for (const fn of Array.from(set)) {
    try {
      fn(data)
    } catch (err) {
      report({ page: id, error: err, info: 'page event "' + event + '"' })
    }
  }
}

/** Ties an `off` to whoever is being set up (see `scope.bindRelease`): the component, its page
 *  scope, the plugin scope — whichever exist. */
export function bindToScope(off: Off, owner?: OwnedScope | null): Off {
  bindRelease(off, owner)
  return off
}

export function isPageOpen(id: string): boolean {
  return state.openPage === id || state.overlays[id] === true || state.modals.indexOf(id) !== -1
}

/** The stable `PageHandle` of an id — what `usePage(id)` and every page hook receive. */
export function pageHandle(id: string): PageHandle {
  let handle = handles.get(id)
  if (handle) return handle
  handle = {
    id,
    get props() {
      return propsFor(id)
    },
    get isOpen() {
      return isPageOpen(id)
    },
    emit(event: string, data?: unknown) {
      post('ui_event', { page: id, event, data: data === undefined ? {} : data })
    },
    on(event: string, fn: (data: never) => void) {
      return bindToScope(onPageEvent(id, event, fn as (d: unknown) => void))
    },
    close() {
      closePage(id)
    },
  } as PageHandle
  handles.set(id, handle)
  return handle
}

function hook(rec: PageRecord, name: 'onOpen' | 'onUpdate' | 'onClose', changed?: string[]): void {
  const def = definitions.get(rec.id)
  const fn = def && (def as unknown as Record<string, unknown>)[name]
  if (typeof fn !== 'function') return
  const scope = scopes.get(rec.id) || null
  guard({ plugin: rec.owner, page: rec.id, info: 'page ' + name }, () =>
    withScope(scope, () => (fn as (p: PageHandle, c?: readonly string[]) => void)(pageHandle(rec.id), changed)),
  )
}

// ---------------------------------------------------------------- open / close

function show(rec: PageRecord): void {
  if (rec.type === 'overlay') {
    state.overlays[rec.id] = true
  } else if (rec.type === 'modal') {
    if (state.modals.indexOf(rec.id) === -1) state.modals.push(rec.id)
  } else {
    // §38.9: the page layer is exclusive — opening another replaces it.
    const prev = state.openPage
    state.openPage = rec.id
    if (prev && prev !== rec.id) {
      const prevRec = state.pages[prev]
      if (prevRec) closeRecord(prevRec, false)
    }
  }
  if (!scopes.has(rec.id)) scopes.set(rec.id, createScope('page:' + rec.id))
}

function hide(rec: PageRecord): boolean {
  let was = false
  if (state.openPage === rec.id) {
    state.openPage = null
    was = true
  }
  if (state.overlays[rec.id]) {
    delete state.overlays[rec.id]
    was = true
  }
  const i = state.modals.indexOf(rec.id)
  if (i !== -1) {
    state.modals.splice(i, 1)
    was = true
  }
  return was
}

/** Hides a page and disposes its scope. `hard` also forgets a kept-alive instance's scope. */
function closeRecord(rec: PageRecord, hard: boolean): void {
  const was = hide(rec)
  // `onClose` pairs with `onOpen`: a page that never got its open hook never gets a close one.
  if (was && rec.opened) hook(rec, 'onClose')
  rec.opened = false
  const scope = scopes.get(rec.id)
  if (scope && (hard || !rec.keepAlive)) {
    scope.dispose()
    scopes.delete(rec.id)
  }
}

/** `PluginBoundary` reports a dead instance here; the next `page:open` remounts it (§38.12). */
export function markCrashed(id: string): void {
  const rec = state.pages[id]
  if (rec) rec.crashed = true
}

/** `page:open`. Props are applied BEFORE the component exists, so an early open is not a race. */
export function openPage(msg: MsgPageOpen): void {
  const id = String(msg.id)
  const rec = ensurePage(id)
  const wasOpen = isPageOpen(id)
  const changed = setProps(rec, msg.props)
  // §38.12: "the next page:open remounts it" — a new epoch is a new vnode key, so even an overlay
  // that crashed while it stayed open comes back.
  if (rec.crashed) {
    rec.crashed = false
    rec.epoch++
  }
  rec.error = null
  show(rec)
  if (wasOpen) {
    hook(rec, 'onUpdate', changed)
  } else if (rec.component) {
    rec.opened = true
    hook(rec, 'onOpen')
  }
  // No component yet: `componentReady` runs `onOpen` the moment one exists (F2).
  if (rec.component) return
  waitForComponent(rec)
}

/** `page:close` (Lua's own close — no `ui_close` goes back). */
export function closePageAction(msg: { id?: string | null }): void {
  const id = msg && msg.id ? String(msg.id) : state.openPage
  if (!id) return
  const rec = state.pages[id]
  if (rec) closeRecord(rec, false)
  else {
    state.openPage = state.openPage === id ? null : state.openPage
    delete state.overlays[id]
  }
}

/** Escape, a close button or a crashed page: hide right away, then let Lua decide (§7.3). */
export function closePage(id?: string | null): void {
  const page = id || state.openPage
  if (!page) return
  const rec = state.pages[page]
  if (rec) closeRecord(rec, false)
  else {
    if (state.openPage === page) state.openPage = null
    delete state.overlays[page]
  }
  post('ui_close', { page })
}

/** A page whose component cannot be produced: tell Lua, toast, and never hold the cursor (§38.6). */
function failOpen(rec: PageRecord, reason: string): void {
  rec.error = reason
  post('ui_event', { page: rec.id, event: '__error', data: { error: reason } })
  notify('UI page "' + rec.id + '" did not load', 'error')
  closePage(rec.id)
}

/** Waits on the OWNER PLUGIN's own promise (never a fixed delay), with `loadTimeoutMs` on top. */
function waitForComponent(rec: PageRecord): void {
  const token = (openTokens.get(rec.id) || 0) + 1
  openTokens.set(rec.id, token)
  const owner = rec.owner
  const timeoutMs = Plugins.devOptions().loadTimeoutMs
  const stillWanted = () => openTokens.get(rec.id) === token && isPageOpen(rec.id) && !rec.component

  if (owner && Plugins.stateOf(owner)) {
    Plugins.ensureActivated(owner)
    const pluginState = Plugins.stateOf(owner)
    if (pluginState === 'failed' || pluginState === 'incompatible') {
      const plugin = Plugins.get(owner)
      failOpen(rec, (plugin && plugin.error) || 'plugin_failed')
      return
    }
    let timer: ReturnType<typeof setTimeout> | null = setTimeout(() => {
      timer = null
      if (stillWanted()) failOpen(rec, 'load_timeout')
    }, timeoutMs)
    void Plugins.whenSettled(owner).then(() => {
      if (timer) clearTimeout(timer)
      if (!stillWanted()) return
      resolveComponent(rec)
      if (rec.component || rec.loading) return
      const plugin = Plugins.get(owner)
      failOpen(rec, plugin && plugin.error ? plugin.error : 'not_registered')
    })
    return
  }

  // No plugin owns it: the legacy path (a page registered through `CoreUI.registerPage`).
  void whenRegistered(rec.id, timeoutMs).then((component) => {
    if (component || !stillWanted()) return
    failOpen(rec, 'not_registered')
  })
}

// ---------------------------------------------------------------- patches (§38.10)
//
// A path addresses the LUA table that was passed to `open` — Lua's view, 1-BASED. Both sides run
// the same two rules so the live page and core's replay copy can never drift apart:
//   R1 list element  the container is an Array and the segment is an integer 1 <= n <= length + 1
//                    -> arr[n - 1]  (length + 1 appends; deleting the last element shrinks the list)
//   R2 map key       everything else -> a property write/delete. An EMPTY array that receives a map
//                    key is replaced by {} in its parent first (an empty Lua table is both, and JSON
//                    had to pick one). A hole (out-of-range index, or a delete in the middle of a
//                    list) is still applied, and warned about once.

interface Step {
  container: Record<string, unknown> | unknown[]
  key: string | number
  isIndex: boolean
}

const INT_RE = /^\d+$/

function warnHole(id: string, path: string, what: string): void {
  const key = 'hole:' + id + ':' + path
  if (warned.has(key)) return
  warned.add(key)
  console.warn('[core:ui] page "' + id + '": ' + what + ' at "' + path + '" leaves a hole in a list — send this list whole with Core.UI.update')
}

/** Resolves one segment against its container, normalising an empty array into a map when needed. */
function step(container: Record<string, unknown> | unknown[], seg: string, parent: Step | null, id: string, path: string): Step {
  if (Array.isArray(container)) {
    if (INT_RE.test(seg)) {
      const n = Number(seg)
      if (n >= 1 && n <= container.length + 1) return { container, key: n - 1, isIndex: true }
    }
    if (container.length === 0 && parent) {
      // An empty list that receives a map key was a map all along — an empty Lua table is both and
      // JSON had to pick one, so swap it for `{}` in its parent before writing.
      const replacement: Record<string, unknown> = {}
      write(parent, replacement)
      return { container: replacement, key: seg, isIndex: false }
    }
    if (container.length > 0) warnHole(id, path, 'key "' + seg + '"')
    return { container, key: seg, isIndex: false }
  }
  return { container, key: seg, isIndex: false }
}

function read(s: Step): unknown {
  return (s.container as Record<string | number, unknown>)[s.key]
}

function write(s: Step, value: unknown): void {
  ;(s.container as Record<string | number, unknown>)[s.key] = value
}

function remove(s: Step, id: string, path: string): void {
  if (s.isIndex && Array.isArray(s.container)) {
    const arr = s.container as unknown[]
    const i = s.key as number
    if (i === arr.length - 1) {
      arr.length = arr.length - 1
      return
    }
    if (i < arr.length - 1) warnHole(id, path, 'deleting element ' + (i + 1))
  }
  delete (s.container as Record<string | number, unknown>)[s.key]
}

/** Applies ONE op against `root`. Intermediates that do not exist are created as maps. */
function applyOne(root: Record<string, unknown>, id: string, op: PatchOp): string | null {
  const path = String(op.p || '')
  const segs = path.split('.').filter((s) => s.length > 0)
  if (segs.length === 0) return null
  const isDelete = !('v' in op)
  let container: Record<string, unknown> | unknown[] = root
  let parent: Step | null = null

  for (let i = 0; i < segs.length - 1; i++) {
    const s = step(container, segs[i], parent, id, path)
    let next = read(s)
    if (next === null || next === undefined || typeof next !== 'object') {
      if (isDelete) return null // nothing to delete under a branch that does not exist
      next = {}
      write(s, next)
    }
    parent = s
    container = next as Record<string, unknown> | unknown[]
  }

  const last = step(container, segs[segs.length - 1], parent, id, path)
  if (isDelete) remove(last, id, path)
  else write(last, op.v)
  return segs[0]
}

/** Shallow pages copy every container along the path, then re-assign the top-level key. */
function copyAlong(value: unknown, rest: string[]): unknown {
  if (value === null || typeof value !== 'object') return value
  const copy: Record<string, unknown> | unknown[] = Array.isArray(value) ? (value as unknown[]).slice() : Object.assign({}, value as Record<string, unknown>)
  if (rest.length === 0) return copy
  const seg = rest[0]
  const key = Array.isArray(copy) && INT_RE.test(seg) ? Number(seg) - 1 : seg
  const child = (copy as Record<string | number, unknown>)[key]
  if (child && typeof child === 'object') (copy as Record<string | number, unknown>)[key] = copyAlong(child, rest.slice(1))
  return copy
}

/** `page:patch` — applied in order. A patch for a page that is not open is ignored silently. */
export function applyPatch(id: string, ops: PatchOp[] | null | undefined): void {
  if (!Array.isArray(ops) || ops.length === 0) return
  const rec = state.pages[id]
  if (!rec || !isPageOpen(id)) return
  const props = rec.props
  const changed: string[] = []
  for (const op of ops) {
    if (!op || typeof op.p !== 'string') continue
    let top: string | null
    if (rec.reactivity === 'shallow') {
      const segs = op.p.split('.').filter((s) => s.length > 0)
      if (segs.length === 0) continue
      if (segs.length === 1) {
        top = applyOne(props, id, op)
      } else {
        const tmp: Record<string, unknown> = { [segs[0]]: copyAlong(props[segs[0]], segs.slice(1)) }
        top = applyOne(tmp, id, op)
        props[segs[0]] = tmp[segs[0]]
      }
    } else {
      top = applyOne(props, id, op)
    }
    if (top && changed.indexOf(top) === -1) changed.push(top)
  }
  if (changed.length) hook(rec, 'onUpdate', changed)
}

// ---------------------------------------------------------------- plugin lifecycle bridge

/**
 * A plugin activation went away (`plugin:unregister`, a newer generation, a dev hot re-activation).
 *
 * LUA OWNS OPEN AND CLOSE. This must therefore NOT touch `openPage`, `overlays` or `modals`: on a
 * plain re-registration Lua still holds NUI focus for that page, and hiding it here would leave a
 * cursor on an empty screen. The instance dies, the declaration and the open state live on — the
 * page simply has no component until the new activation provides one (or `pluginSettled` fails it).
 * A real resource stop is different: Lua sends `page:close`/`page:unregister` itself.
 */
function disposePagesOf(owner: string): void {
  for (const id of Object.keys(state.pages)) {
    const rec = state.pages[id]
    if (!rec || rec.owner !== owner) continue
    // The OLD definition's onClose, while it is still the one in `definitions`.
    if (rec.opened) hook(rec, 'onClose')
    rec.opened = false
    const scope = scopes.get(id)
    if (scope) {
      scope.dispose()
      scopes.delete(id)
    }
    rec.component = null
    rec.registered = false
    rec.loading = false
    rec.crashed = false
    definitions.delete(id)
  }
  // Any `<KeepAlive>` cache holding this plugin's instances must die with the module that made them.
  keepAliveEpoch.value++
}

/**
 * A plugin settled. `ready`: re-resolve every page it owns, and give an OPEN one a fresh scope and
 * the NEW definition's `onOpen` — the component remounts against the SAME props object, because
 * props belong to the shell, not to the plugin (§7.4). `failed`/`incompatible`: an open page that
 * still has no component goes through the §38.6 failure path so it cannot hold the cursor.
 */
function pluginSettled(plugin: { id: string; state: string; error: string | null }): void {
  for (const id of Object.keys(state.pages)) {
    const rec = state.pages[id]
    if (!rec || rec.owner !== plugin.id) continue
    if (plugin.state === 'failed' || plugin.state === 'incompatible') {
      // Re-resolve first: the dead activation provides nothing, so this drops the component unless
      // a LEGACY `CoreUI.registerPage` still covers the id. Whatever is left unrenderable and open
      // goes through the §38.6 failure path — including a page that was already mounted.
      if (rec.opened) hook(rec, 'onClose')
      rec.opened = false
      resolveComponent(rec)
      if (isPageOpen(id) && !rec.component) failOpen(rec, plugin.error || 'plugin_failed')
      continue
    }
    // `resolveComponent` calls `componentReady`, which is what re-runs `onOpen` for an open page.
    resolveComponent(rec)
  }
}

Plugins.setPageSink({ disposePagesOf, pluginSettled })

// ---------------------------------------------------------------- views + test helpers

export function pageScope(id: string): OwnedScope | null {
  return scopes.get(id) || null
}

export function openOverlays(): PageRecord[] {
  const out: PageRecord[] = []
  for (const id of Object.keys(state.overlays)) {
    const rec = state.pages[id]
    if (rec && rec.component) out.push(rec)
  }
  return out
}

export function openModals(): PageRecord[] {
  const out: PageRecord[] = []
  for (const id of state.modals) {
    const rec = state.pages[id]
    if (rec && rec.component) out.push(rec)
  }
  return out
}

/** Story/test helper: back to a shell with no page state (props identity is kept on purpose). */
export function resetPages(): void {
  for (const id of Object.keys(state.pages)) {
    const scope = scopes.get(id)
    if (scope) scope.dispose()
    scopes.delete(id)
    delete state.pages[id]
  }
  state.openPage = null
  for (const id of Object.keys(state.overlays)) delete state.overlays[id]
  state.modals.splice(0, state.modals.length)
  definitions.clear()
  listeners.clear()
  waiters.clear()
  warned.clear()
  openTokens.clear()
  keepAliveEpoch.value++
}
