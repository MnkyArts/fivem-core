// core UI — audio engine: context, buses, messages, the clock, ticking (DESIGN §55.16; R6 §9.0, §10).
//
//   buses music/sfx/ambience/voice ─► masterVol ─► duck ─► limiter ─► destination
//   voice sends ─► sendIn[category] ─► reverb (small room / large space) ─► masterVol
//
// ONE AudioContext (latencyHint 'playback'), created on the first source/emitter — never at install
// time — and suspended after 15 s with nothing in it. Emitters are virtual voices; every feed message
// (≤ 20 Hz) and every 200 ms tick runs the mixing pass (mixer.ts). While nothing exists there is no
// timer at all. Errors go to Lua as `audio:error { id, code }` (rate-limited: one per id and code per
// 10 s, five per second overall), stats as `audio:stats` once per second while `audio:debug { on }`.

import type { AudioErrorCode, Category, EngineEnv, EnginePrefs, PrefsSpec, SourceSpec } from './types.ts'
import { AUDIO_DEFAULTS, FADE } from './types.ts'
import { forwardOf, parseDebug, parseEmitter, parseFeed, parsePrefs, parseRemove, parseSource } from './validate.ts'
import { NetClock, add32, heardAt, outputLatencyMs, playHead } from './sync.ts'
import type { Clocked } from './sync.ts'
import { ClipCache } from './cache.ts'
import { CATEGORIES, ListenerDriver, approach, buildMaster, rampTo } from './spatial.ts'
import type { Reverb, ReverbMode, Voice } from './spatial.ts'
import { Source } from './sources.ts'
import type { SourceEnv } from './sources.ts'
import { BufferLoader } from './loader.ts'
import { Mixer, newEmitter } from './mixer.ts'
import { ErrorGate, engineStats } from './debug.ts'
import type { Emitter, Listener, MixerHost } from './mixer.ts'

const TICK_MS = 200
const IDLE_SUSPEND_MS = 15000
const HRTF_WARMUP_MS = 800

export type { EngineEnv } from './types.ts'

export class AudioEngine implements MixerHost {
  ctx: AudioContext | null = null
  readonly clock = new NetClock()
  readonly cache: ClipCache<AudioBuffer>
  readonly sources = new Map<number, Source>()
  readonly emitters = new Map<number, Emitter>()
  readonly dying = new Set<Voice>()
  readonly mixer: Mixer
  readonly prefs: EnginePrefs = {
    hrtf: false, maxVoices: AUDIO_DEFAULTS.voices, offsetMs: 0, streams: true,
    decoders: AUDIO_DEFAULTS.decoders, clipCacheMb: AUDIO_DEFAULTS.clipCacheMb, hrtfVoices: AUDIO_DEFAULTS.hrtfVoices,
  }
  listener: Listener | null = null
  paused = false
  debug = false
  reverbMode: ReverbMode = 'large'
  readonly vol: Record<Category | 'master', number> = { master: 1, music: 1, sfx: 1, ambience: 1, voice: 1 }
  errors = 0
  private env: EngineEnv
  private failed = false
  private buses = {} as Record<Category, GainNode>
  private sendIn = {} as Record<Category, GainNode>
  private masterVol: GainNode | null = null
  private duck: GainNode | null = null
  /** read by debug.ts (the level probe taps it) */
  limiter: DynamicsCompressorNode | null = null
  private reverb: Reverb | null = null
  analyser: AnalyserNode | null = null
  private ldriver: ListenerDriver | null = null
  private createdAt = 0
  private senv: SourceEnv | null = null
  private lastFeedAt = 0
  private tickTimer: unknown = null
  private kickTimer: unknown = null
  private idleTimer: unknown = null
  private debugTimer: unknown = null
  private idleSuspended = false
  private resumeAt = 0
  private suspendedReported = false
  private hrtfReadyAt = 0
  private offGesture: (() => void) | null = null
  private errorGate = new ErrorGate()
  /** sources of type `voice` (§55.17, Mumble's): no decoder, no AudioContext of their own */
  private voiceSources = new Set<number>()
  private tickErrors = 0
  private disposed = false

  /** The clip loader (null before the context exists) — diagnostics read its counters. */
  get loader(): BufferLoader | null {
    return this.senv ? this.senv.loader : null
  }

  constructor(env: EngineEnv) {
    this.env = env
    this.cache = new ClipCache<AudioBuffer>(AUDIO_DEFAULTS.clipCacheMb * 1048576)
    this.mixer = new Mixer(this)
  }

  // MixerHost
  bus(cat: Category): GainNode { return this.buses[cat] }
  sendBus(cat: Category): GainNode { return this.sendIn[cat] }
  now(): number { return this.env.now() }
  later(fn: () => void, ms: number): unknown { return this.env.setTimeout(fn, ms) }
  cancel(h: unknown): void { this.env.clearTimeout(h) }
  hrtfReady(): boolean { return this.env.now() >= this.hrtfReadyAt }

  /** The one entry point: `index.ts` routes every `audio:*` message here. */
  handle(action: string, msg: unknown): void {
    if (this.disposed) return
    switch (action) {
      case 'audio:source': return this.onSource(msg)
      case 'audio:emitter': return this.onEmitter(msg)
      case 'audio:remove': return this.onRemove(msg)
      case 'audio:feed': return this.onFeed(msg)
      case 'audio:prefs': return this.onPrefs(msg)
      case 'audio:debug': return this.onDebug(msg)
      default:
    }
  }

  // ------------------------------------------------------------ context + graph

  /** Creates the context and the fixed graph on first need; null when Web Audio is unavailable. */
  ensureContext(): AudioContext | null {
    if (this.ctx || this.failed || this.disposed) return this.ctx
    let ctx: AudioContext | null = null
    try {
      ctx = this.env.createContext()
    } catch (err) {
      ctx = null
    }
    if (!ctx) {
      this.failed = true
      this.error(0, 'no_webaudio')
      return null
    }
    this.ctx = ctx
    this.createdAt = this.env.now()
    this.ldriver = new ListenerDriver(ctx.listener)
    const g = buildMaster(ctx, this.vol, this.paused, (fn, ms) => this.env.setTimeout(fn, ms), (h) => this.env.clearTimeout(h))
    this.limiter = g.limiter
    this.duck = g.duck
    this.masterVol = g.masterVol
    this.reverb = g.reverb
    this.buses = g.buses
    this.sendIn = g.sendIn
    const keepAlive = g.keepAlive
    this.reverb.setMode(this.reverbMode, ctx.currentTime, 10)
    const env = this.env
    const loader = new BufferLoader(ctx, {
      fetch: env.fetch, setTimeout: (fn, ms) => env.setTimeout(fn, ms), clearTimeout: (h) => env.clearTimeout(h),
      createAudio: () => env.createAudio(), createObjectURL: (o) => env.createObjectURL(o),
      revokeObjectURL: (u) => env.revokeObjectURL(u),
    }, this.cache)
    this.senv = {
      ctx, fetch: env.fetch, createAudio: () => env.createAudio(), MediaSource: env.MediaSource,
      createObjectURL: (o) => env.createObjectURL(o), revokeObjectURL: (u) => env.revokeObjectURL(u),
      importHls: () => env.importHls(), now: () => env.now(),
      setTimeout: (fn, ms) => env.setTimeout(fn, ms), clearTimeout: (h) => env.clearTimeout(h),
      loader, keepAlive, head: (spec) => this.headOf(spec), headAtCtx: (spec, t, now) => this.headAtCtx(spec, t, now),
      report: (id, code) => this.error(id, code),
      trustHeaders: !env.dev, dev: env.dev, seek: { lead: 0.06 },
    }
    if (this.prefs.hrtf) this.warmHrtf()
    if (this.listener) this.applyListener(0)
    this.ensureRunning()
    return ctx
  }

  /** Resumes a context the browser suspended (not our own idle suspend); reports it once. */
  private ensureRunning(): void {
    const ctx = this.ctx
    if (!ctx || ctx.state === 'running' || ctx.state === 'closed') return
    const now = this.env.now()
    if (now < this.resumeAt) return
    this.resumeAt = now + 2000
    this.idleSuspended = false
    try {
      quiet(ctx.resume())
    } catch (err) { /* reported below */ }
    if (this.env.onUserGesture && !this.offGesture) {
      this.offGesture = this.env.onUserGesture(() => {
        if (this.ctx && this.ctx.state === 'suspended') quiet(this.ctx.resume())
      })
    }
    this.env.setTimeout(() => {
      if (this.ctx && this.ctx.state === 'suspended' && !this.idleSuspended && !this.suspendedReported) {
        this.suspendedReported = true
        this.error(0, 'suspended')
      }
    }, 2000)
  }

  /** Triggers Chromium's lazy HRTF database load before any voice depends on it. */
  private warmHrtf(): void {
    const ctx = this.ctx
    if (!ctx) return
    try {
      const probe = ctx.createPanner()
      probe.panningModel = 'HRTF'
    } catch (err) { /* no HRTF */ }
    this.hrtfReadyAt = this.env.now() + HRTF_WARMUP_MS
  }

  private wake(): void {
    if (this.idleTimer !== null) {
      this.env.clearTimeout(this.idleTimer)
      this.idleTimer = null
    }
    if (this.ctx && this.idleSuspended) {
      this.idleSuspended = false
      quiet(this.ctx.resume())
    }
  }

  /** Anything that can make sound (emitters of a voice source cannot: Mumble renders those). */
  private busy(): boolean {
    if (this.sources.size > 0 || this.dying.size > 0) return true
    for (const em of this.emitters.values()) if (!this.voiceSources.has(em.spec.source)) return true
    return false
  }

  /** How late (ms into the sound) the page heard of a source — network time, no output latency. */
  private stampLate(src: Source): void {
    const net = this.clock.now(this.env.now())
    src.lateMs = net === null || src.spec.t0 === null ? null : Math.max(0, playHead(src.spec, net))
  }

  // ------------------------------------------------------------ clock

  /** What a media element must be at NOW: it feeds the graph, which is heard `outputLatencyMs` later. */
  latencyMs(): number {
    return this.prefs.offsetMs + outputLatencyMs(this.ctx)
  }

  /**
   * Play head (ms) a media element should be at right now (heard position = pos(net + user offset)
   * once the graph's latency has passed); null until the clock is synced.
   */
  headOf(spec: Clocked): number | null {
    const net = this.clock.now(this.env.now())
    if (net === null || spec.t0 === null) return null
    return playHead(spec, add32(net, this.latencyMs()))
  }

  /**
   * Play head (ms) a buffer node must RENDER at context time `ctxT` (sync.ts heardAt: the output
   * timestamp, nothing while a young context's device starts); `now` = a one-shot never waits.
   */
  headAtCtx(spec: Clocked, ctxT: number, now?: boolean): number | null {
    const ctx = this.ctx
    if (!ctx || spec.t0 === null) return null
    const perf = this.env.now()
    const heard = heardAt(ctx, ctxT, perf, perf - this.createdAt, !!now)
    const net = heard === null ? null : this.clock.now(heard)
    return net === null ? null : playHead(spec, add32(net, this.prefs.offsetMs))
  }

  /** A source without t0 starts "now" — pinned once the clock is known. */
  private pinT0(spec: SourceSpec, prev: SourceSpec | null): void {
    if (spec.t0 !== null) return
    if (prev && prev.t0 !== null) {
      spec.t0 = prev.t0
      return
    }
    const net = this.clock.now(this.env.now())
    if (net !== null) spec.t0 = Math.floor(net)
  }

  // ------------------------------------------------------------ messages

  onSource(msg: unknown): void {
    const spec = parseSource(msg, this.env.dev, (id, code) => this.error(id, code))
    if (!spec) return
    if (spec.type === 'voice') {
      // world-speaker voice is Mumble's (§55.17): nothing to decode, and no reason for a context
      this.voiceSources.add(spec.id)
      this.dropSource(spec.id, FADE.lod)
      return
    }
    this.voiceSources.delete(spec.id)
    if (!this.ensureContext() || !this.senv) return
    this.wake()
    const existing = this.sources.get(spec.id)
    this.pinT0(spec, existing ? existing.spec : null)
    if (existing) {
      if (existing.spec.category !== spec.category) {
        // voices are bound to a bus: let the arbiter rebuild them on the new one
        for (const em of this.emitters.values()) if (em.spec.source === spec.id) this.mixer.release(em, FADE.lod)
      }
      const replay = existing.spec.t0 !== spec.t0 || existing.spec.url !== spec.url
      existing.update(spec)
      if (replay) this.stampLate(existing)
    } else {
      const src = new Source(this.senv, spec)
      this.sources.set(spec.id, src)
      this.stampLate(src)
    }
    this.kick()
  }

  private dropSource(id: number, fadeMs: number): void {
    const src = this.sources.get(id)
    if (!src) return
    for (const e of this.emitters.values()) if (e.spec.source === id && e.voice) this.mixer.release(e, fadeMs)
    src.dispose(fadeMs)
    this.sources.delete(id)
    this.kick()
  }

  onEmitter(msg: unknown): void {
    const spec = parseEmitter(msg)
    if (!spec) return
    // an emitter of a voice source is only remembered: it never needs the page's audio
    if (!this.voiceSources.has(spec.source) && !this.ensureContext()) return
    this.wake()
    const em = this.emitters.get(spec.id)
    if (em) {
      const switched = em.spec.source !== spec.source
      em.spec = spec
      em.x = spec.x
      em.y = spec.y
      em.z = spec.z
      em.cand.source = spec.source
      if (!spec.occlusion) em.occl = 0
      // a station switch: the old chain fades out, the arbiter fades the new source in (R6 §8)
      if (switched && em.voice) this.mixer.release(em, 500)
    } else this.emitters.set(spec.id, newEmitter(spec))
    if (this.ctx) this.kick()
  }

  onRemove(msg: unknown): void {
    const spec = parseRemove(msg)
    if (!spec) return
    for (const id of spec.ids) {
      const em = this.emitters.get(id)
      if (em) {
        if (em.voice) this.mixer.release(em, spec.fadeMs)
        this.emitters.delete(id)
      }
      this.voiceSources.delete(id)
      this.dropSource(id, spec.fadeMs)
    }
    this.kick()
  }

  onFeed(msg: unknown): void {
    const f = parseFeed(msg)
    if (!f) return
    const now = this.env.now()
    if (f.t !== null) {
      const first = !this.clock.synced()
      this.clock.sample(f.t, now)
      if (first) {
        for (const src of this.sources.values()) {
          this.pinT0(src.spec, null)
          if (src.lateMs === null) this.stampLate(src)
        }
      }
    }
    const gap = this.lastFeedAt ? now - this.lastFeedAt : 1000 / AUDIO_DEFAULTS.listenerHz
    this.lastFeedAt = now
    // ramp over the nominal interval: after an idle gap (camera still = no feed) never over seconds
    const T = Math.min(120, Math.max(30, gap)) / 1000
    if (f.pos) {
      const prev = this.listener
      const fwd = f.fwd || (prev ? prev.fwd : { x: 0, y: 1, z: 0 })
      const up = f.up || (prev ? prev.up : { x: 0, y: 0, z: 1 })
      const vel = f.vel || { x: 0, y: 0, z: 0 }
      this.listener = {
        x: f.pos.x, y: f.pos.y, z: f.pos.z,
        tx: f.pos.x + vel.x * T, ty: f.pos.y + vel.y * T, tz: f.pos.z + vel.z * T,
        fwd, up, vel,
      }
    } else if (this.listener && (f.fwd || f.up)) {
      if (f.fwd) this.listener.fwd = f.fwd
      if (f.up) this.listener.up = f.up
    }
    if (f.moving) {
      const m = f.moving
      for (let i = 0; i + 5 < m.length; i += 6) {
        const em = this.emitters.get(m[i])
        if (!em) continue
        em.x = m[i + 1]
        em.y = m[i + 2]
        em.z = m[i + 3]
        em.moving = true
        // a cone on something that turns (a PA on a car) follows its heading
        if (em.spec.cone && (m[i + 4] === m[i + 4] || m[i + 5] === m[i + 5])) {
          em.spec.dir = forwardOf(m[i + 4] === m[i + 4] ? m[i + 4] : 0, m[i + 5] === m[i + 5] ? m[i + 5] : 0)
        }
      }
    }
    if (f.occl) {
      const o = f.occl
      for (let i = 0; i + 1 < o.length; i += 2) {
        const em = this.emitters.get(o[i])
        if (!em || !em.spec.occlusion) continue
        if (Math.abs(em.occl - o[i + 1]) > 0.05) em.occlDirty = true
        em.occl = o[i + 1]
      }
    }
    let volumes = false
    for (const key of ['master', 'music', 'sfx', 'ambience', 'voice'] as const) {
      const v = f[key]
      if (v !== null && v !== this.vol[key]) {
        this.vol[key] = v
        volumes = true
      }
    }
    const ctx = this.ctx
    if (f.env) {
      const mode: ReverbMode = f.env.underwater || f.env.vehicle ? 'dry' : f.env.interior ? 'small' : 'large'
      this.reverbMode = mode
      if (ctx && this.reverb) this.reverb.setMode(mode, ctx.currentTime, 500)
    }
    if (f.paused !== null && f.paused !== this.paused) {
      this.paused = f.paused
      if (ctx && this.duck) rampTo(this.duck.gain, f.paused ? 0 : 1, ctx.currentTime, 0.2)
    }
    if (!ctx) return
    if (volumes) this.applyVolumes()
    if (f.pos || f.fwd || f.up) this.applyListener(T)
    this.update(T)
  }

  onPrefs(msg: unknown): void {
    const p = parsePrefs(msg)
    if (!p) return
    const wasHrtf = this.prefs.hrtf
    this.applyPrefs(p)
    if (this.prefs.hrtf && !wasHrtf) this.warmHrtf()
    if (this.ctx) this.kick()
  }

  private applyPrefs(p: PrefsSpec): void {
    if (p.hrtf !== undefined) this.prefs.hrtf = p.hrtf
    if (p.maxVoices !== undefined) this.prefs.maxVoices = p.maxVoices
    if (p.offsetMs !== undefined) this.prefs.offsetMs = p.offsetMs
    if (p.streams !== undefined) this.prefs.streams = p.streams
    if (p.decoders !== undefined) this.prefs.decoders = p.decoders
    if (p.hrtfVoices !== undefined) this.prefs.hrtfVoices = p.hrtfVoices
    if (p.clipCacheMb !== undefined) {
      this.prefs.clipCacheMb = p.clipCacheMb
      this.cache.setLimit(p.clipCacheMb * 1048576)
    }
  }

  onDebug(msg: unknown): void {
    const d = parseDebug(msg)
    if (!d || d.on === this.debug) return
    this.debug = d.on
    if (this.debugTimer !== null) {
      this.env.clearTimeout(this.debugTimer)
      this.debugTimer = null
    }
    if (d.on) this.debugLoop()
  }

  private debugLoop(): void {
    this.env.report('stats', engineStats(this))
    this.debugTimer = this.env.setTimeout(() => {
      this.debugTimer = null
      if (this.debug) this.debugLoop()
    }, 1000)
  }

  /** Streams allowed by the player's prefs. */
  streamsAllowed(): boolean {
    return this.prefs.streams !== false && this.prefs.streams !== 0
  }

  /** The decoder budget: the config value, lowered by a numeric `streams` pref. */
  decoderBudget(): number {
    const s = this.prefs.streams
    return typeof s === 'number' ? Math.min(this.prefs.decoders, s) : this.prefs.decoders
  }

  private applyVolumes(): void {
    const ctx = this.ctx
    if (!ctx || !this.masterVol) return
    const now = ctx.currentTime
    approach(this.masterVol.gain, this.vol.master, now, 0.05)
    for (const cat of CATEGORIES) {
      approach(this.buses[cat].gain, this.vol[cat], now, 0.05)
      approach(this.sendIn[cat].gain, this.vol[cat], now, 0.05)
    }
  }

  private applyListener(T: number): void {
    if (this.ctx && this.listener && this.ldriver) this.ldriver.apply(this.ctx.currentTime, this.listener, T)
  }

  // ------------------------------------------------------------ passes and ticking

  /** One mixing pass, then keep the tick (or the idle countdown) going. */
  update(T: number): void {
    if (this.disposed) return
    try {
      this.mixer.update(T)
    } catch (err) {
      this.tickError(0, err)
    }
    this.schedule()
  }

  /** A throw inside one source (or the pass) is logged — never allowed to stop the engine's timer. */
  private tickError(id: number, err: unknown): void {
    if (this.tickErrors++ < 5) console.error('[core:ui] audio: ' + (id ? 'source ' + id : 'the mixing pass') + ' threw', err)
  }

  /** Coalesces the passes a burst of messages asks for into one, on the next task. */
  kick(): void {
    if (this.kickTimer !== null || this.disposed) return
    this.kickTimer = this.env.setTimeout(() => {
      this.kickTimer = null
      this.update(0)
    }, 0)
  }

  private schedule(): void {
    if (this.disposed) return
    if (!this.busy()) {
      this.idle()
      return
    }
    if (this.tickTimer === null) this.tickTimer = this.env.setTimeout(() => this.tick(), TICK_MS)
  }

  /** 5 Hz while anything exists: every source aligns itself with the clock, then a pass. */
  tick(): void {
    this.tickTimer = null
    if (this.disposed) return
    try {
      this.ensureRunning()
      const now = this.env.now()
      for (const src of this.sources.values()) {
        try {
          src.tick(now)
        } catch (err) {
          this.tickError(src.id, err)
        }
      }
    } finally {
      // one failing source must never leave the engine without its tick
      this.update(0)
    }
  }

  /** Nothing left: suspend the context after 15 s (an idle running context still pulls its graph). */
  private idle(): void {
    if (this.idleTimer !== null || !this.ctx || this.idleSuspended) return
    this.idleTimer = this.env.setTimeout(() => {
      this.idleTimer = null
      const ctx = this.ctx
      if (!ctx || this.busy() || this.disposed) return
      this.idleSuspended = true
      quiet(ctx.suspend())
    }, IDLE_SUSPEND_MS)
  }

  // ------------------------------------------------------------ errors, stats, dev seams

  /** `audio:error { id, code }` to Lua — one per id and code per 10 s, ≤ 5 per second overall. */
  error(id: number, code: AudioErrorCode): void {
    this.errors++
    if (this.errorGate.allow(id, code, this.env.now())) this.env.report('error', { id, code })
  }

  dispose(): void {
    if (this.disposed) return
    this.disposed = true
    for (const h of [this.tickTimer, this.kickTimer, this.idleTimer, this.debugTimer]) if (h !== null) this.env.clearTimeout(h)
    this.tickTimer = null
    this.kickTimer = null
    this.idleTimer = null
    this.debugTimer = null
    for (const em of this.emitters.values()) {
      if (em.voice) em.voice.dispose()
      em.voice = null
    }
    for (const v of this.dying) v.dispose()
    this.dying.clear()
    this.emitters.clear()
    for (const src of this.sources.values()) src.dispose(FADE.cut)
    this.sources.clear()
    if (this.offGesture) {
      this.offGesture()
      this.offGesture = null
    }
    const ctx = this.ctx
    this.ctx = null
    if (ctx) quiet(ctx.close())
  }
}

/** Swallows the rejection of a promise nobody awaits (resume/suspend/close/play). */
function quiet(p: unknown): void {
  if (p && typeof (p as Promise<unknown>).catch === 'function') (p as Promise<unknown>).catch(() => { /* ignored */ })
}
