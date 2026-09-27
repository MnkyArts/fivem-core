// core UI — audio engine: the shared clock and drift control (DESIGN §55.16; R6 §4.3–§4.5). Pure.
//
// Clock: every `audio:feed` carries `t` = Core.Clock.now() (u32 ms, OneSync network time). The page
// records performance.now() on receipt; `offset = t − perf` over a sliding 10 s window keeps the
// MAX (the NUI hop only ever adds delay, so the largest offset is the least-delayed sample). u32
// wrap is handled by unwrapping each `t` against the previous one (signed 32-bit difference).
//
// Play head (ms) = (netNow − t0) × rate + offset  — `pausedAt` replaces netNow while paused.
//
// Drift (media elements, polled every 200 ms): error e = fitted currentTime − expected position;
//   |e| < 25 ms → rate 1 · 25 ms ≤ |e| < 750 ms → rate 1 − clamp(e / 4 s, ±2 %) (pitch preserved)
//   |e| ≥ 750 ms → re-seek (behind a 100 ms gain dip; not again within 1 s)
// Lock (the source stays muted until then): |e| ≤ 75 ms on 2 consecutive polls, or 4 s after the
// join — fail-open, so a source whose seeks are coarse (VBR MP3) is corrected audibly by rate
// instead of staying silent for ever. Seeks that do not land (a host without Range support): after 3
// within 10 s the controller stops seeking, fails open and steers by rate only (`stuck` — the deck
// then reloads the file into a blob, which can seek).

export const U32 = 4294967296
const I31 = 2147483648

/** a − b as a signed 32-bit difference; `a` may be fractional (a mapped network time). */
export function diff32(a: number, b: number): number {
  let d = (a - b) % U32
  if (d < 0) d += U32
  if (d >= I31) d -= U32
  return d
}

/** (t + ms) wrapped into [0, 2^32). */
export function add32(t: number, ms: number): number {
  let v = (t + ms) % U32
  if (v < 0) v += U32
  return v
}

/** Non-negative modulo (loop and timeline positions). */
export function mod(v: number, m: number): number {
  if (!(m > 0)) return 0
  const r = v % m
  return r < 0 ? r + m : r
}

/** Shortest signed difference actual − expected on a circle of `period` (a looping play head). */
export function wrapError(actual: number, expected: number, period: number): number {
  if (!(period > 0)) return actual - expected
  let e = mod(actual - expected, period)
  if (e > period / 2) e -= period
  return e
}

// ---------------------------------------------------------------- net clock

export const CLOCK_WINDOW_MS = 10000

export class NetClock {
  private readonly windowMs: number
  private perfs: number[] = []
  private offs: number[] = []
  private best = 0
  private lastT: number | null = null
  private lastUnwrapped = 0
  samples = 0

  constructor(windowMs?: number) {
    this.windowMs = windowMs && windowMs > 0 ? windowMs : CLOCK_WINDOW_MS
  }

  /** One `(t, perf)` pair: `t` the u32 network time Lua stamped, `perf` = performance.now() on receipt. */
  sample(t: number, perf: number): void {
    const un = this.lastT === null ? t : this.lastUnwrapped + diff32(t, this.lastT)
    this.lastT = t
    this.lastUnwrapped = un
    this.perfs.push(perf)
    this.offs.push(un - perf)
    this.samples++
    const cutoff = perf - this.windowMs
    while (this.perfs.length > 1 && this.perfs[0] < cutoff) {
      this.perfs.shift()
      this.offs.shift()
    }
    let best = -Infinity
    for (let i = 0; i < this.offs.length; i++) if (this.offs[i] > best) best = this.offs[i]
    this.best = best
  }

  synced(): boolean {
    return this.lastT !== null
  }

  /** The filtered offset (unwrapped network ms − perf ms), or null before the first sample. */
  offset(): number | null {
    return this.lastT === null ? null : this.best
  }

  /** The u32 network time (fractional) at `perf`, or null before the first sample. */
  now(perf: number): number | null {
    if (this.lastT === null) return null
    return mod(perf + this.best, U32)
  }

  /** How many samples the window holds right now (diagnostics). */
  held(): number {
    return this.perfs.length
  }

  reset(): void {
    this.perfs = []
    this.offs = []
    this.best = 0
    this.lastT = null
    this.lastUnwrapped = 0
    this.samples = 0
  }
}

// ---------------------------------------------------------------- play heads

export interface Clocked {
  t0: number | null
  rate: number
  paused: boolean
  pausedAt: number | null
  offset: number
}

/** Play head in ms at network time `net`. A null t0 must be pinned by the caller first. */
export function playHead(s: Clocked, net: number): number {
  const t0 = s.t0 === null ? net : s.t0
  const at = s.paused ? (s.pausedAt === null ? t0 : s.pausedAt) : net
  return diff32(at, t0) * s.rate + s.offset
}

export interface TimelinePos {
  /** -1 before the first item starts, 0 playing, 1 ended (not looping) */
  state: -1 | 0 | 1
  index: number
  /** ms into the item (negative while pending) */
  offset: number
  /** ms left in the item */
  remaining: number
}

/** Where a head (ms) falls in a list of item durations. `out` is reused by the caller. */
export function timelineAt(durations: ReadonlyArray<number>, head: number, loop: boolean, out: TimelinePos): TimelinePos {
  let total = 0
  for (let i = 0; i < durations.length; i++) total += durations[i]
  out.index = 0
  out.offset = 0
  out.remaining = 0
  if (!(total > 0)) {
    out.state = 1
    return out
  }
  if (head < 0) {
    out.state = -1
    out.offset = head
    out.remaining = durations[0] - head
    return out
  }
  if (!loop && head >= total) {
    out.state = 1
    out.index = durations.length - 1
    return out
  }
  let h = loop ? mod(head, total) : head
  for (let i = 0; i < durations.length; i++) {
    if (h < durations[i] || i === durations.length - 1) {
      out.state = 0
      out.index = i
      out.offset = h
      out.remaining = durations[i] - h
      return out
    }
    h -= durations[i]
  }
  out.state = 1
  return out
}

/** One-shot rule (R6 §2.3): a clip first heard late by Δ plays from Δ only while Δ < 30 % of it. */
export function clipStartable(headMs: number, durationMs: number, startedBefore: boolean): boolean {
  if (headMs < 0) return true
  if (headMs >= durationMs - 20) return false
  if (startedBefore) return true
  return headMs <= 50 || headMs < 0.3 * durationMs
}

// ---------------------------------------------------------------- drift control

export const DRIFT = {
  pollMs: 200,
  deadBand: 0.025,
  rateLimit: 0.02,
  rateDiv: 4,
  seekAbove: 0.75,
  seekSettleMs: 1000,
  maxSeeks: 3,
  seekWindowMs: 10000,
  lockTol: 0.075,
  lockPolls: 2,
  lockTimeoutMs: 4000,
} as const

export type DriftAction = 'none' | 'rate' | 'seek'

export class DriftController {
  /** the correction factor to multiply the nominal rate by */
  rate = 1
  locked = false
  lastError = 0
  seeks = 0
  /** seeks stopped landing: rate-only until reset() */
  stuck = false
  private good = 0
  private joinedAt: number
  private lastSeekAt = -Infinity
  private seekTimes: number[] = []

  constructor(now: number) {
    this.joinedAt = now
  }

  /** A fresh join (new item, reload): unlock and forget the history. */
  reset(now: number): void {
    this.rate = 1
    this.locked = false
    this.good = 0
    this.joinedAt = now
    this.lastSeekAt = -Infinity
    this.lastError = 0
    this.stuck = false
    this.seekTimes = []
  }

  /** Marks a seek the caller made on its own (the join), so the settle time and the storm limit apply. */
  seeked(now: number): void {
    this.lastSeekAt = now
    this.good = 0
    this.seekTimes.push(now)
  }

  private recentSeeks(now: number): number {
    const cutoff = now - DRIFT.seekWindowMs
    while (this.seekTimes.length && this.seekTimes[0] < cutoff) this.seekTimes.shift()
    return this.seekTimes.length
  }

  /** `error` = actual − expected in seconds (positive = ahead). */
  decide(error: number, now: number): DriftAction {
    this.lastError = error
    const abs = Math.abs(error)
    if (abs >= DRIFT.seekAbove && !this.stuck) {
      this.good = 0
      if (now - this.lastSeekAt < DRIFT.seekSettleMs) return 'none'
      if (this.recentSeeks(now) < DRIFT.maxSeeks) {
        this.lastSeekAt = now
        this.seekTimes.push(now)
        this.seeks++
        this.rate = 1
        return 'seek'
      }
      // a seek storm: stop seeking, open the gate, steer by rate from here on
      this.stuck = true
      this.locked = true
    }
    if (!this.locked) {
      if (abs <= DRIFT.lockTol) this.good++
      else this.good = 0
      if (this.good >= DRIFT.lockPolls || now - this.joinedAt >= DRIFT.lockTimeoutMs) this.locked = true
    }
    let next = 1
    if (abs >= DRIFT.deadBand) {
      const c = error / DRIFT.rateDiv
      next = 1 - (c < -DRIFT.rateLimit ? -DRIFT.rateLimit : c > DRIFT.rateLimit ? DRIFT.rateLimit : c)
    }
    if (Math.abs(next - this.rate) < 0.0005) return 'none'
    this.rate = next
    return 'rate'
  }
}

// ---------------------------------------------------------------- currentTime fit

/**
 * `currentTime` is coarse and frozen per task (R6 §4.4): fit a line over the last 2 s of
 * (perf, currentTime) samples and read the position off the line instead of the raw value.
 */
export class TimeFit {
  private xs: number[] = []
  private ys: number[] = []
  private readonly windowMs: number

  constructor(windowMs?: number) {
    this.windowMs = windowMs && windowMs > 0 ? windowMs : 2000
  }

  add(perf: number, seconds: number): void {
    this.xs.push(perf)
    this.ys.push(seconds)
    const cutoff = perf - this.windowMs
    while (this.xs.length > 2 && this.xs[0] < cutoff) {
      this.xs.shift()
      this.ys.shift()
    }
  }

  reset(): void {
    this.xs = []
    this.ys = []
  }

  size(): number {
    return this.xs.length
  }

  /** Position (s) at `perf`; `rate` extrapolates while fewer than 3 samples exist. */
  at(perf: number, rate: number): number | null {
    const n = this.xs.length
    if (!n) return null
    const lastX = this.xs[n - 1]
    const lastY = this.ys[n - 1]
    if (n < 3) return lastY + ((perf - lastX) / 1000) * rate
    const x0 = this.xs[0]
    let sx = 0, sy = 0, sxx = 0, sxy = 0
    for (let i = 0; i < n; i++) {
      const x = this.xs[i] - x0
      sx += x
      sy += this.ys[i]
      sxx += x * x
      sxy += x * this.ys[i]
    }
    const den = n * sxx - sx * sx
    if (Math.abs(den) < 1e-9) return lastY + ((perf - lastX) / 1000) * rate
    const slope = (n * sxy - sx * sy) / den
    const icept = (sy - slope * sx) / n
    return icept + slope * (perf - x0)
  }
}

// ---------------------------------------------------------------- the output clock

export interface OutputClock {
  currentTime: number
  baseLatency?: number
  outputLatency?: number
  getOutputTimestamp?(): { contextTime?: number; performanceTime?: number }
}

/** Render → speaker delay the browser reports (base + output latency), bounded to 0..500 ms. */
export function outputLatencyMs(ctx: OutputClock | null): number {
  if (!ctx) return 0
  const ms = ((ctx.baseLatency || 0) + (ctx.outputLatency || 0)) * 1000
  return ms > 0 ? Math.min(500, ms) : 0
}

/**
 * performance.now() time at which context time `ctxT` is HEARD, from getOutputTimestamp() — a pair
 * stable to ±1 ms, where currentTime against performance.now() jitters ±9 ms and stands still for
 * ~200 ms while a new context's device starts (measured in Chromium). The first output callbacks
 * report contextTime ≈ 0 while performanceTime already runs and the pair keeps settling for a while,
 * so it is trusted once 300 ms of audio has been output; until then null (a context younger than 1 s,
 * unless `force`), after that the render clock + the reported latency.
 */
export function heardAt(ctx: OutputClock, ctxT: number, perfNow: number, ageMs: number, force: boolean): number | null {
  const ts = typeof ctx.getOutputTimestamp === 'function' ? ctx.getOutputTimestamp() : null
  const outPerf = ts && ts.performanceTime ? ts.performanceTime : 0
  const outCtx = ts && ts.contextTime ? ts.contextTime : 0
  if (outPerf > 0 && outCtx > 0.3) return outPerf + (ctxT - outCtx) * 1000
  if (ts && !force && ageMs < 1000) return null
  return perfNow + (ctxT - ctx.currentTime) * 1000 + outputLatencyMs(ctx)
}
