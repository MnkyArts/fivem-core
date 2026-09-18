// core UI runtime — the plugin registry and loader (DESIGN §38.2, §38.6 "Loading a plugin").
//
// Two maps, on purpose (the prototype's V3 finding):
//   moduleCache   keyed by the ABSOLUTE URL that was imported. It mirrors the browser's own module
//                 map — a module can never be unloaded — so it SURVIVES unregister and makes a
//                 restart with an unchanged build free.
//   records       the ACTIVE activation per resource. Torn down completely on unregister even
//                 though the module stays: scope, setup disposer, pages, <link>s, requests.
//
// A production URL is NEVER busted with a query: `?g=` re-evaluates only the file it sits on while
// that file's relative static imports stay cached, so a multi-chunk plugin would run new entry code
// against stale chunks. The content hash in the file name is the only correct invalidation, which is
// why Lua re-reads `manifest.json` on every resource start. `?t=` is used for the DEV-SERVER path
// alone, where Vite rewrites the inner specifiers for us.

import { markRaw } from 'vue'
import { API_VERSION } from '../../sdk/src/contract.ts'
import type { PageDefinition, PluginContext, PluginManifest, UIPlugin } from '../../sdk/src/contract.ts'
import type { MsgPluginRegister, PluginState } from './protocol.ts'
import { createScope, withScope } from './scope.ts'
import type { OwnedScope } from './scope.ts'
import { post } from './transport.ts'
import { report } from './errors.ts'

export interface PluginRecord {
  id: string
  generation: number
  base: string
  build: string
  sdk: string
  load: 'eager' | 'lazy'
  /** The plugin's Vite dev server origin, or null for the normal `cfx-nui-<res>` path. */
  dev: string | null
  url: string
  css: string[]
  state: PluginState
  error: string | null
  ms: number | null
  pages: string[]
}

type LoadPhase = 'validate' | 'fetch' | 'evaluate' | 'setup'

interface ModuleEntry {
  state: 'loading' | 'loaded' | 'failed'
  promise: Promise<Record<string, unknown>>
  error?: unknown
}

interface Activation {
  scope: OwnedScope
  pages: Map<string, PageDefinition>
  disposer: (() => void) | null
  /** Settles when the activation reached `ready`, `failed` or `incompatible`. */
  done: Promise<PluginRecord>
  settle: (rec: PluginRecord) => void
}

interface Env {
  importModule(url: string): Promise<Record<string, unknown>>
  document: Document | null
  now(): number
}

const env: Env = {
  importModule: (url) => import(/* @vite-ignore */ url) as Promise<Record<string, unknown>>,
  document: typeof document !== 'undefined' ? document : null,
  now: () => (typeof performance !== 'undefined' && performance.now ? performance.now() : Date.now()),
}

export function configurePlugins(partial: Partial<Env>): void {
  if (partial.importModule !== undefined) env.importModule = partial.importModule
  if (partial.document !== undefined) env.document = partial.document
  if (partial.now !== undefined) env.now = partial.now
}

/** What the shell writes plugin records into (`store.plugins`, read by the inspector). */
export interface PluginStoreSlice { plugins: Record<string, PluginRecord> }

let state: PluginStoreSlice = { plugins: {} }

export function attachPluginStore(slice: PluginStoreSlice): void {
  state = slice
}

/** pages.ts installs itself here — one-way imports: pages -> plugins, never the other way. */
export interface PageSink {
  disposePagesOf(owner: string): void
  pluginSettled(rec: PluginRecord): void
}
let sink: PageSink = { disposePagesOf() {}, pluginSettled() {} }
export function setPageSink(next: PageSink): void {
  sink = next
}

const disposeHooks: Array<(id: string) => void> = []
/** host.ts hooks in here to reject the plugin's pending requests with `plugin_disposed`. */
export function onPluginDispose(fn: (id: string) => void): () => void {
  disposeHooks.push(fn)
  return () => {
    const i = disposeHooks.indexOf(fn)
    if (i !== -1) disposeHooks.splice(i, 1)
  }
}

const moduleCache = new Map<string, ModuleEntry>()
const records = new Map<string, PluginRecord>()
const activations = new Map<string, Activation>()

const dev = { log: false, loadTimeoutMs: 8000, enabled: false }

export function setDevOptions(opts: { enabled?: boolean; log?: boolean; loadTimeoutMs?: number }): void {
  if (opts.enabled !== undefined) dev.enabled = !!opts.enabled
  if (opts.log !== undefined) dev.log = !!opts.log
  if (opts.loadTimeoutMs !== undefined && Number(opts.loadTimeoutMs) > 0) dev.loadTimeoutMs = Number(opts.loadTimeoutMs)
}

export function devOptions(): { enabled: boolean; log: boolean; loadTimeoutMs: number } {
  return { enabled: dev.enabled, log: dev.log, loadTimeoutMs: dev.loadTimeoutMs }
}

/** One grep-able format for the whole lifecycle (§38.14). Silent unless `dev:set { log }`. */
export function log(...args: unknown[]): void {
  if (dev.log) console.log('[UI]', ...args)
}

// ---------------------------------------------------------------- the module cache

export function importModule(url: string): Promise<Record<string, unknown>> {
  const hit = moduleCache.get(url)
  if (hit && hit.state !== 'failed') return hit.promise
  const entry: ModuleEntry = { state: 'loading', promise: null as unknown as Promise<Record<string, unknown>> }
  entry.promise = Promise.resolve()
    .then(() => env.importModule(url))
    .then(
      (mod) => {
        entry.state = 'loaded'
        return mod
      },
      (err) => {
        // A FAILED url may be retried on the next registration: a 404 is usually a missing build,
        // and the fix is `npm run build` + `restart <res>`, not a page reload.
        entry.state = 'failed'
        entry.error = err
        moduleCache.delete(url)
        throw err
      },
    )
  moduleCache.set(url, entry)
  return entry.promise
}

export function moduleStates(): Record<string, string> {
  const out: Record<string, string> = Object.create(null)
  for (const [url, entry] of moduleCache) out[url] = entry.state
  return out
}

// ---------------------------------------------------------------- <link> management

function linkNodes(id: string): Element[] {
  if (!env.document) return []
  return Array.from(env.document.querySelectorAll('link[data-core-plugin="' + id + '"]'))
}

function addLink(id: string, href: string): Promise<void> {
  const doc = env.document
  if (!doc) return Promise.resolve()
  return new Promise((resolve) => {
    const link = doc.createElement('link')
    link.rel = 'stylesheet'
    link.href = href
    link.setAttribute('data-core-plugin', id)
    // A stylesheet that 404s is a warning, not a load failure: the page still renders, just naked.
    link.onload = () => resolve()
    link.onerror = () => {
      console.error('[core:ui] ' + id + ': stylesheet failed to load', href)
      resolve()
    }
    doc.head.appendChild(link)
  })
}

function addPreload(id: string, href: string): void {
  const doc = env.document
  if (!doc) return
  const link = doc.createElement('link')
  link.rel = 'modulepreload'
  link.href = href
  link.setAttribute('data-core-plugin', id)
  doc.head.appendChild(link)
}

function removeLinks(id: string): void {
  for (const node of linkNodes(id)) {
    if (node.parentNode) node.parentNode.removeChild(node)
  }
}

// ---------------------------------------------------------------- registration

/** `load: 'lazy'` parks the manifest here until the first `page:open` of one of its pages. */
const manifests = new Map<string, PluginManifest>()

function recordOf(msg: MsgPluginRegister): PluginRecord {
  const m = (msg.manifest || {}) as PluginManifest
  return {
    id: msg.id,
    generation: Number(msg.generation) || 0,
    base: String(msg.base || ''),
    build: String(m.build || ''),
    sdk: String(m.sdk || ''),
    load: m.load === 'lazy' ? 'lazy' : 'eager',
    dev: msg.dev && msg.dev.origin ? String(msg.dev.origin).replace(/\/+$/, '') : null,
    url: '',
    css: Array.isArray(m.css) ? m.css.map(String) : [],
    state: 'registered',
    error: null,
    ms: null,
    pages: Array.isArray(m.pages) ? m.pages.map(String) : [],
  }
}

/**
 * `plugin:register`. Idempotent per (id, generation): the same generation re-sent (an `ui_ready`
 * replay) is ignored while it is loading or ready, and RETRIED when it failed.
 */
export function register(msg: MsgPluginRegister): PluginRecord {
  const id = msg && typeof msg.id === 'string' ? msg.id : ''
  if (!id) {
    console.error('[core:ui] plugin:register without an id', msg)
    return recordOf({ id: '', generation: 0, base: '', manifest: {} as PluginManifest } as MsgPluginRegister)
  }
  const prev = records.get(id)
  const generation = Number(msg.generation) || 0
  if (prev && prev.generation === generation && prev.state !== 'failed' && prev.state !== 'incompatible') return prev
  if (prev) unregister(id)

  const rec = recordOf(msg)
  records.set(id, rec)
  state.plugins[id] = rec
  log(id + ' registered (gen ' + rec.generation + ', build ' + (rec.build || '-') + ')')

  if (rec.load === 'eager') void activate(rec, msg.manifest)
  else manifests.set(id, msg.manifest)
  return rec
}

/** Starts the load of a lazy plugin. Safe to call for any state. */
export function ensureActivated(id: string): void {
  const rec = records.get(id)
  if (!rec || rec.state !== 'registered') return
  const manifest = manifests.get(id)
  manifests.delete(id)
  void activate(rec, manifest || ({} as PluginManifest))
}

function newActivation(id: string): Activation {
  let settle: (rec: PluginRecord) => void = () => {}
  const done = new Promise<PluginRecord>((resolve) => {
    settle = resolve
  })
  return { scope: createScope('plugin:' + id), pages: new Map(), disposer: null, done, settle }
}

function fail(rec: PluginRecord, phase: LoadPhase, err: unknown, incompatible?: boolean): void {
  const message = err && (err as Error).message ? (err as Error).message : String(err)
  rec.state = incompatible ? 'incompatible' : 'failed'
  rec.error = message
  rec.ms = null
  rec.pages = []
  removeLinks(rec.id)
  const act = activations.get(rec.id)
  if (act) {
    // A DEAD activation provides NOTHING. `setup` runs after the page map is built, so a plugin
    // whose setup threw would otherwise keep handing out components with no listeners, no request
    // handlers and no scope behind them (§38.6: a failed activation fails its pages).
    act.pages.clear()
    act.scope.dispose()
    act.settle(rec)
  }
  console.error('[core:ui] ' + rec.id + ' ' + rec.state + ' during ' + phase + ' (' + (rec.url || rec.base) + '): ' + message)
  sink.pluginSettled(rec)
  post('ui_plugin', { id: rec.id, generation: rec.generation, state: rec.state, error: message, ms: null, pages: [] })
}

async function activate(rec: PluginRecord, manifest: PluginManifest): Promise<void> {
  const started = env.now()
  const act = newActivation(rec.id)
  activations.set(rec.id, act)
  rec.state = 'loading'
  const stale = () => records.get(rec.id) !== rec

  let phase: LoadPhase = 'validate'
  try {
    const manifestVersion = Number(manifest && manifest.apiVersion)
    if (!rec.dev && manifestVersion !== API_VERSION) {
      throw new Error(rec.id + ' was built for core UI API ' + manifestVersion + ', this core provides ' + API_VERSION + ' — rebuild the plugin with this core\'s @core/ui or update core')
    }

    phase = 'fetch'
    let pending: Promise<Record<string, unknown>>
    if (rec.dev) {
      // §38.11 path 3: the plugin's own Vite server. Its client derives the websocket URL from its
      // own `import.meta.url`, so it talks to the dev server and not to core's origin.
      await importModule(rec.dev + '/@vite/client')
      installHmrShim()
      rec.url = rec.dev + '/src/index.ts'
      log(rec.id + ' loading ' + rec.url)
      pending = importModule(rec.url)
    } else {
      rec.url = rec.base + String(manifest.entry || '')
      for (const file of Array.isArray(manifest.preload) ? manifest.preload : []) addPreload(rec.id, rec.base + String(file))
      log(rec.id + ' loading ' + rec.url.split('/').pop())
      // The stylesheets and the entry travel TOGETHER — two file reads that do not depend on each
      // other. A module evaluated before its CSS landed is fine: nothing mounts before `ready`.
      pending = importModule(rec.url)
      pending.catch(() => {}) // the real handling is the `await` below; this only silences the race
      await Promise.all(rec.css.map((file) => addLink(rec.id, rec.base + file)))
      if (stale()) return discard(rec, act)
    }

    phase = 'evaluate'
    const mod = await pending
    if (stale()) return discard(rec, act)

    phase = 'validate'
    const def = (mod && (mod as { default?: UIPlugin }).default) || null
    if (!def || (def as UIPlugin).__coreUIPlugin !== true) {
      throw new Error(rec.id + ': entry has no `export default defineUIPlugin(...)`')
    }
    if (Number(def.apiVersion) !== API_VERSION) {
      throw new Error(rec.id + ' was built for core UI API ' + def.apiVersion + ', this core provides ' + API_VERSION + ' — rebuild the plugin with this core\'s @core/ui or update core')
    }

    const pages = def.pages || {}
    for (const pageId of Object.keys(pages)) act.pages.set(pageId, normalizePage(pages[pageId]))
    rec.pages = Array.from(act.pages.keys())

    phase = 'setup'
    runSetup(rec, act, def)

    rec.state = 'ready'
    rec.error = null
    rec.ms = Math.round(env.now() - started)
    log(rec.id + ' ready in ' + rec.ms + ' ms (' + rec.pages.length + ' page' + (rec.pages.length === 1 ? '' : 's') + ')')
    act.settle(rec)
    sink.pluginSettled(rec)
    post('ui_plugin', { id: rec.id, generation: rec.generation, state: 'ready', error: null, ms: rec.ms, pages: rec.pages })
  } catch (err) {
    if (stale()) return discard(rec, act)
    const incompatible = phase === 'validate' && /core UI API/.test(String(err && (err as Error).message))
    fail(rec, phase, err, incompatible)
  }
}

/** A result that arrived after a restart: drop it, and take its stylesheets with it. */
function discard(rec: PluginRecord, act: Activation): void {
  log(rec.id + ' generation ' + rec.generation + ' discarded (a newer registration won)')
  act.scope.dispose()
  act.settle(rec)
  if (activations.get(rec.id) === act) activations.delete(rec.id)
  // The live record owns the id's links now, so only sweep when nothing replaced us.
  if (!records.has(rec.id)) removeLinks(rec.id)
}

const asyncSetupWarned = new Set<string>()

/**
 * Runs `setup(ctx)` inside the activation's scope and records its disposer.
 *
 * `setup` is SYNCHRONOUS by contract: the shell has to know the page map and the plugin's listeners
 * the moment it reports `ready`, and an `async setup` would silently register everything after that.
 * One warning per plugin, and whatever the promise rejects with is still attributed rather than lost.
 */
function runSetup(rec: PluginRecord, act: Activation, def: UIPlugin): void {
  if (typeof def.setup !== 'function') return
  const ctx = contextFor(rec, act.scope)
  activeId = rec.id
  let result: void | (() => void)
  try {
    result = withScope(act.scope, () => (def.setup as (c: PluginContext) => void | (() => void))(ctx))
  } finally {
    activeId = null
  }
  const maybePromise = result as unknown as Promise<unknown> | null
  if (maybePromise && typeof maybePromise.then === 'function') {
    if (!asyncSetupWarned.has(rec.id)) {
      asyncSetupWarned.add(rec.id)
      console.warn('[core:ui] ' + rec.id + ': setup() must be synchronous — it returned a Promise; start async work inside it and register cleanup with ctx.scope')
    }
    void maybePromise.catch((err) => report({ plugin: rec.id, error: err, info: 'async setup' }))
    return
  }
  if (typeof result === 'function') act.disposer = result
}

/** A function in `pages` is ALWAYS a loader — functional components are not supported as roots. */
function normalizePage(value: unknown): PageDefinition {
  if (typeof value === 'function') return { component: value as PageDefinition['component'] }
  if (value && typeof value === 'object' && 'component' in (value as object)) {
    const def = value as PageDefinition
    const component = typeof def.component === 'function' ? def.component : markRaw(def.component as object)
    return Object.assign({}, def, { component: component as PageDefinition['component'] })
  }
  return { component: markRaw(value as object) as PageDefinition['component'] }
}

function contextFor(rec: PluginRecord, scope: OwnedScope): PluginContext {
  return {
    id: rec.id,
    generation: rec.generation,
    build: rec.build,
    scope,
    get nui() {
      return nuiFactory(rec.id)
    },
    dev: dev.enabled,
    log: (...args: unknown[]) => log(rec.id + ':', ...args),
  } as PluginContext
}

/** The plugin whose `setup(ctx)` is running right now — `useNui()` with no channel resolves it. */
let activeId: string | null = null
export function activePluginId(): string | null {
  return activeId
}

/** host.ts supplies the real `NuiHandle` factory; before it does, `ctx.nui` throws a clear error. */
let nuiFactory: (channel: string) => PluginContext['nui'] = () => {
  throw new Error('[core:ui] the host object is not installed yet')
}
export function setNuiFactory(fn: typeof nuiFactory): void {
  nuiFactory = fn
}

// ---------------------------------------------------------------- unregister

/**
 * `plugin:unregister` (resource stop, restart, or a newer registration). Tears the ACTIVATION
 * down completely — the module stays in the cache, because the browser cannot unload it and
 * pretending otherwise only creates bugs (§38.2).
 */
/**
 * Tears an ACTIVATION down: page instances, request handlers, pending requests, `setup`'s disposer
 * and the plugin scope. The RECORD and the pages' open state survive — `unregister` deletes the
 * record afterwards, a dev hot re-activation keeps it and builds a new activation on top.
 */
function teardown(id: string, verb: string): void {
  const rec = records.get(id)
  const act = activations.get(id)
  // Pages first: their `onClose` hooks and component instances belong to this activation.
  try {
    sink.disposePagesOf(id)
  } catch (err) {
    report({ plugin: id, error: err, info: 'disposePagesOf' })
  }
  for (const hook of Array.from(disposeHooks)) {
    try {
      hook(id)
    } catch (err) {
      report({ plugin: id, error: err, info: 'plugin dispose hook' })
    }
  }
  if (!act) return
  // LIFO: `setup`'s own disposer runs before the scope it was created in.
  if (act.disposer) {
    try {
      act.disposer()
    } catch (err) {
      report({ plugin: id, error: err, info: 'setup disposer' })
    }
  }
  const counts = act.scope.counts()
  act.scope.dispose()
  act.settle(rec || ({ id, state: 'failed' } as PluginRecord))
  activations.delete(id)
  log(id + ' ' + verb + ' — cleaned ' + (rec ? rec.pages.length : 0) + ' pages, ' + counts.listeners + ' listeners, ' + counts.timers + ' timers')
}

export function unregister(id: string): void {
  records.delete(id)
  manifests.delete(id)
  delete state.plugins[id]
  teardown(id, 'stopped')
  removeLinks(id)
}

// ---------------------------------------------------------------- queries (pages.ts, inspector)

export function get(id: string): PluginRecord | undefined {
  return records.get(id)
}

export function list(): PluginRecord[] {
  return Array.from(records.values())
}

export function stateOf(id: string): PluginState | null {
  const rec = records.get(id)
  return rec ? rec.state : null
}

/** The page definition a plugin provides for `pageId`, or null. */
export function pageDefinition(owner: string, pageId: string): PageDefinition | null {
  const act = activations.get(owner)
  if (!act) return null
  return act.pages.get(pageId) || null
}

export function pageIdsOf(owner: string): string[] {
  const act = activations.get(owner)
  return act ? Array.from(act.pages.keys()) : []
}

/** The plugin's own scope — a page scope is created as a child bag by pages.ts. */
export function scopeOf(owner: string): OwnedScope | null {
  const act = activations.get(owner)
  return act ? act.scope : null
}

/**
 * Settles when the plugin reached `ready`, `failed` or `incompatible`. A `page:open` waits on THIS
 * promise instead of guessing a delay; `pages.ts` adds the `loadTimeoutMs` race on top.
 */
export function whenSettled(id: string): Promise<PluginRecord | null> {
  const rec = records.get(id)
  if (!rec) return Promise.resolve(null)
  if (rec.state === 'ready' || rec.state === 'failed' || rec.state === 'incompatible') return Promise.resolve(rec)
  const act = activations.get(id)
  if (!act) return Promise.resolve(rec)
  return act.done
}

// ---------------------------------------------------------------- dev-server HMR (§38.11)

/**
 * A production shell has no Vue HMR runtime, so install a coarse one: every update re-activates the
 * plugins that came from a dev server (props survive — they belong to the shell — component-local
 * state does not). A shell built with `build:dev` keeps Vue's own runtime and this does nothing.
 */
export function installHmrShim(): 'native' | 'shim' {
  const g = globalThis as unknown as { __VUE_HMR_RUNTIME__?: unknown }
  if (g.__VUE_HMR_RUNTIME__) return 'native'
  g.__VUE_HMR_RUNTIME__ = {
    createRecord: () => true,
    rerender: () => {
      scheduleDevReload()
      return true
    },
    reload: () => {
      scheduleDevReload()
      return true
    },
  }
  return 'shim'
}

/** Vite calls `rerender`/`reload` once per invalidated record, so one save arrives as a burst.
 *  A trailing 30 ms timer turns that burst into exactly one re-activation. */
const HMR_DEBOUNCE_MS = 30
let hmrTimer: ReturnType<typeof setTimeout> | null = null

export function scheduleDevReload(only?: string): void {
  if (hmrTimer) clearTimeout(hmrTimer)
  hmrTimer = setTimeout(() => {
    hmrTimer = null
    void reloadDevPlugins(only)
  }, HMR_DEBOUNCE_MS)
}

/**
 * A hot update RE-ACTIVATES the plugin (§38.11): the old `setup` disposer runs, the old scope and
 * every page instance die, the entry is re-imported with a fresh `?t=` and the NEW definition's
 * `setup` runs in a new scope. That is what makes an edit to `setup()` or to a module-level store
 * take effect — swapping only the page map would leave the old listeners registered forever.
 *
 * Query busting is safe HERE and nowhere else: the dev server rewrites the inner specifiers of
 * every invalidated module, so the changed file really is re-fetched (a production `?g=` does not).
 * The record, the pages' open state and their props survive — they belong to the shell.
 */
export async function reloadDevPlugins(only?: string): Promise<void> {
  for (const rec of Array.from(records.values())) {
    if (!rec.dev || rec.state !== 'ready') continue
    if (only && rec.id !== only) continue
    const url = rec.url.split('?')[0] + '?t=' + Date.now()
    try {
      const mod = await env.importModule(url)
      const def = (mod && (mod as { default?: UIPlugin }).default) || null
      if (!def || def.__coreUIPlugin !== true) {
        report({ plugin: rec.id, error: new Error('hot update: entry has no `export default defineUIPlugin(...)`'), info: 'hot reload' })
        continue
      }
      if (records.get(rec.id) !== rec) continue // a restart won while we were importing

      teardown(rec.id, 'hot-reloading')
      const act = newActivation(rec.id)
      activations.set(rec.id, act)
      const pages = def.pages || {}
      for (const pageId of Object.keys(pages)) act.pages.set(pageId, normalizePage(pages[pageId]))
      rec.pages = Array.from(act.pages.keys())
      rec.url = url
      runSetup(rec, act, def)
      act.settle(rec)
      sink.pluginSettled(rec)
      log(rec.id + ' hot-reloaded from ' + rec.dev + ' (' + rec.pages.length + ' pages)')
    } catch (err) {
      report({ plugin: rec.id, error: err, info: 'hot reload' })
    }
  }
}

// ---------------------------------------------------------------- test helper

/** Forgets every record, activation and cached module. Only the unit tests use it. */
export function resetPlugins(): void {
  if (hmrTimer) clearTimeout(hmrTimer)
  hmrTimer = null
  asyncSetupWarned.clear()
  for (const id of Array.from(records.keys())) unregister(id)
  records.clear()
  activations.clear()
  manifests.clear()
  moduleCache.clear()
  for (const id of Object.keys(state.plugins)) delete state.plugins[id]
}
