// fx_alpha — the counters the runtime suite reads, in a module of their own so the entry and the
// components can share them without an import cycle.
//
// `evals` is incremented HERE, at module scope: that is the one side effect a fixture is allowed,
// and it is what proves "a cached module is never evaluated twice" (§38.2).

/** Replaced by Vite's `define` — the only difference between the v1 and v2 builds of these sources. */
declare const __FX_VARIANT__: string
export const VARIANT: string = __FX_VARIANT__

export interface AlphaCounters {
  evals: number
  setups: number
  disposes: number
  /** `ctx.scope.listen(window, 'fx-alpha-probe')` hits — two per event means a leaked listener. */
  hits: number
  ticks: number
  pings: number
  opens: number
  closes: number
  updates: number
  changed: string[]
  variant: string
  lastPing: unknown
  /** Bumped by the lazy page's module scope: it must stay 0 until that page is first opened. */
  lazyEvals: number
  /** One per `onUpdated` of a bench slot — how many children a patch really re-rendered. */
  slotRenders: number
}

const bag = ((globalThis as unknown as { __fx?: Record<string, unknown> }).__fx ||= {})

export const counters: AlphaCounters = ((bag as Record<string, unknown>).alpha ||= {
  evals: 0, setups: 0, disposes: 0, hits: 0, ticks: 0, pings: 0,
  opens: 0, closes: 0, updates: 0, changed: [], variant: '', lastPing: null, lazyEvals: 0, slotRenders: 0,
}) as AlphaCounters

counters.evals++
counters.variant = VARIANT
