// core UI runtime — the inspector's data source (DESIGN §38.14). Dev only, lazily imported.
//
// This module is reached through ONE dynamic `import()` from App.vue's async `<Inspector>`, so a
// production shell never fetches the chunk and pays nothing but the integer counters the runtime
// keeps anyway. `start()` is what turns the expensive parts on — byte counting in the transport and
// a `longtask` PerformanceObserver — and `stop()` turns them off again, so a closed panel really is
// zero timers and zero observers.

import * as Plugins from './plugins.ts'
import * as Pages from './pages.ts'
import * as Layers from './layers.ts'
import { feedStats } from './feeds.ts'
import { channelStats } from './host.ts'
import { measureBytes, stats as transportStats } from './transport.ts'
import { errorLog } from './errors.ts'
import type { CbUiError, FocusEntry } from './protocol.ts'

export interface LongTask { start: number; duration: number }

export interface InspectorSnapshot {
  at: number
  /** Seconds since the previous snapshot; 0 for the first one. */
  dt: number
  plugins: Array<{ id: string; state: string; generation: number; build: string; ms: number | null; url: string; pages: string[]; error: string | null; dev: string | null; load: string }>
  modules: Array<{ url: string; state: string }>
  pages: Array<{ id: string; owner: string | null; type: string; open: boolean; mounted: boolean; keepAlive: boolean; reactivity: string; crashed: boolean; error: string | null }>
  focus: FocusEntry[]
  scopes: Array<{ label: string; listeners: number; timers: number; rafs: number; hooks: number }>
  channels: Array<{ channel: string; handlers: number; pending: number }>
  traffic: {
    out: Record<string, number>
    in: Record<string, number>
    outPerSec: number
    inPerSec: number
    bytesOutPerSec: number
    bytesInPerSec: number
    bytes: boolean
  }
  feeds: { channels: number; flushes: number; writes: number; subs: Record<string, number>; flushesPerSec: number; writesPerSec: number }
  longTasks: LongTask[]
  errors: CbUiError[]
}

interface Sample {
  at: number
  out: number
  in: number
  bytesOut: number
  bytesIn: number
  flushes: number
  writes: number
}

const LONG_TASK_MAX = 20
const longTasks: LongTask[] = []
let observer: { disconnect(): void } | null = null
let prev: Sample | null = null
let running = false

function totalOf(map: Record<string, number>): number {
  let n = 0
  for (const key of Object.keys(map)) n += map[key]
  return n
}

function perSec(now: number, then: number, delta: number): number {
  const dt = (now - then) / 1000
  if (dt <= 0) return 0
  return Math.round((delta / dt) * 10) / 10
}

/**
 * One reading of everything the shell knows about itself. Pure apart from the sample it remembers
 * for the rate columns, so a test can call it twice and assert the deltas.
 */
export function snapshot(now?: number): InspectorSnapshot {
  const at = now != null ? now : Date.now()
  const t = transportStats()
  const f = feedStats()
  const outTotal = totalOf(t.out)
  const inTotal = totalOf(t.in)

  const plugins = Plugins.list().map((p) => ({
    id: p.id, state: p.state, generation: p.generation, build: p.build, ms: p.ms,
    url: p.url, pages: p.pages.slice(), error: p.error, dev: p.dev, load: p.load,
  }))

  const scopes: InspectorSnapshot['scopes'] = []
  for (const p of plugins) {
    const scope = Plugins.scopeOf(p.id)
    if (scope) scopes.push(Object.assign({ label: scope.label }, scope.counts()))
  }

  const state = Pages.pageState()
  const pages: InspectorSnapshot['pages'] = []
  for (const id of Object.keys(state.pages)) {
    const rec = state.pages[id]
    if (!rec) continue
    const open = state.openPage === id || state.overlays[id] === true || state.modals.indexOf(id) !== -1
    pages.push({
      id, owner: rec.owner, type: rec.type, open,
      mounted: open && !!rec.component && !rec.crashed,
      keepAlive: rec.keepAlive, reactivity: rec.reactivity, crashed: rec.crashed, error: rec.error,
    })
    const scope = Pages.pageScope(id)
    if (scope) scopes.push(Object.assign({ label: scope.label }, scope.counts()))
  }

  const modules: InspectorSnapshot['modules'] = []
  const moduleStates = Plugins.moduleStates()
  for (const url of Object.keys(moduleStates)) modules.push({ url, state: moduleStates[url] })

  const dt = prev ? (at - prev.at) / 1000 : 0
  const snap: InspectorSnapshot = {
    at,
    dt: Math.round(dt * 100) / 100,
    plugins,
    modules,
    pages,
    focus: Layers.focusStack().slice(),
    scopes,
    channels: channelStats(),
    traffic: {
      out: t.out,
      in: t.in,
      outPerSec: prev ? perSec(at, prev.at, outTotal - prev.out) : 0,
      inPerSec: prev ? perSec(at, prev.at, inTotal - prev.in) : 0,
      bytesOutPerSec: prev ? perSec(at, prev.at, t.bytesOut - prev.bytesOut) : 0,
      bytesInPerSec: prev ? perSec(at, prev.at, t.bytesIn - prev.bytesIn) : 0,
      bytes: t.bytes,
    },
    feeds: {
      channels: f.channels, flushes: f.flushes, writes: f.writes, subs: f.subs,
      flushesPerSec: prev ? perSec(at, prev.at, f.flushes - prev.flushes) : 0,
      writesPerSec: prev ? perSec(at, prev.at, f.writes - prev.writes) : 0,
    },
    longTasks: longTasks.slice(),
    errors: errorLog().slice(),
  }
  prev = { at, out: outTotal, in: inTotal, bytesOut: t.bytesOut, bytesIn: t.bytesIn, flushes: f.flushes, writes: f.writes }
  return snap
}

/** Arms the expensive parts. Idempotent. */
export function start(): void {
  if (running) return
  running = true
  prev = null
  measureBytes(true)
  const PO = (globalThis as unknown as { PerformanceObserver?: new (cb: (l: { getEntries(): Array<{ startTime: number; duration: number }> }) => void) => { observe(o: object): void; disconnect(): void } }).PerformanceObserver
  if (!PO) return
  try {
    const po = new PO((list) => {
      for (const entry of list.getEntries()) {
        longTasks.push({ start: Math.round(entry.startTime), duration: Math.round(entry.duration) })
      }
      if (longTasks.length > LONG_TASK_MAX) longTasks.splice(0, longTasks.length - LONG_TASK_MAX)
    })
    po.observe({ type: 'longtask', buffered: true })
    observer = po
  } catch (err) {
    // `longtask` is not observable everywhere; the rest of the panel is worth having anyway.
    observer = null
  }
}

/** Disarms everything: no observer, no byte counting, nothing left running. */
export function stop(): void {
  if (!running) return
  running = false
  measureBytes(false)
  if (observer) observer.disconnect()
  observer = null
  longTasks.length = 0
  prev = null
}

export function isRunning(): boolean {
  return running
}
