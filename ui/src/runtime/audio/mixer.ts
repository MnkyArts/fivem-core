// core UI — audio engine: the mixing pass (DESIGN §55.16; R6 §2.2–§2.3, §3.2, §8, §9.5).
//
// Run on every feed message and every engine tick, in this order:
//   1. measure every emitter against the listener: distance (or zone distance), curve × cone ×
//      occlusion × volume = its level; × source/bus/master volume = its audibility → score (dB)
//   2. grant decoders (streams, timelines, big files) to the best-placed sources that can be heard at
//      all (volume 0 — GTA's music slider down — downloads nothing); clips entering range + 25 m are
//      fetched and decoded ahead (prefetch), so a one-shot does not pay its download when it fires
//   3. pick the real voices (arbiter.ts), build or revive their chains, fade out the rest (LOD 400 ms)
//   4. a buffer source plays while any of its voices lives (fading ones included)
//   5. HRTF for the nearest real voices when the player asked for it (a 30 ms dip per model switch)
// Nothing here allocates per pass: candidates live on the emitters, pools are keyed by id.

import type { Category, EmitterSpec, Vec3 } from './types.ts'
import {
  REAR_CUTOFF, REAR_GAIN, airCutoff, coneGain, curveGain, isBehind, occlusionCutoff, occlusionGain,
  scoreDb, zoneNearest,
} from './curves.ts'
import { ARBITER, decoderScore, selectDecoders, selectHrtf, selectVoices } from './arbiter.ts'
import type { DecoderCand, HrtfCand, VoiceCand } from './arbiter.ts'
import type { Clocked } from './sync.ts'
import { Voice, approach, setAt } from './spatial.ts'
import { FADE } from './types.ts'
import type { Source } from './sources.ts'

export interface Listener {
  x: number
  y: number
  z: number
  /** the ramp target (position + velocity × interval): zones place their voice relative to it */
  tx: number
  ty: number
  tz: number
  fwd: Vec3
  up: Vec3
  vel: Vec3
}

export interface Emitter {
  spec: EmitterSpec
  x: number
  y: number
  z: number
  occl: number
  occlDirty: boolean
  moving: boolean
  voice: Voice | null
  dist: number
  /** curve × cone × occlusion × emitter volume */
  level: number
  /** level × source × bus × master volume (× rear) — what the arbiter ranks */
  aud: number
  score: number
  /** air + occlusion cutoff (the rear cue is added per voice) */
  cutoff: number
  send: number
  rear: boolean
  px: number
  py: number
  pz: number
  cand: VoiceCand
}

export function newEmitter(spec: EmitterSpec): Emitter {
  return {
    spec, x: spec.x, y: spec.y, z: spec.z, occl: 0, occlDirty: false, moving: false, voice: null,
    dist: Infinity, level: 0, aud: 0, score: -240, cutoff: 20000, send: 1, rear: false,
    px: spec.x, py: spec.y, pz: spec.z,
    cand: { id: spec.id, source: spec.source, score: -240, audibility: 0, real: false, since: 0, usable: false, eff: 0 },
  }
}

export interface MixerHost {
  readonly ctx: AudioContext | null
  readonly sources: Map<number, Source>
  readonly emitters: Map<number, Emitter>
  readonly dying: Set<Voice>
  readonly listener: Listener | null
  readonly vol: Record<Category | 'master', number>
  readonly prefs: { hrtf: boolean; maxVoices: number; hrtfVoices: number }
  bus(cat: Category): GainNode
  sendBus(cat: Category): GainNode
  now(): number
  later(fn: () => void, ms: number): unknown
  cancel(h: unknown): void
  headOf(spec: Clocked): number | null
  decoderBudget(): number
  streamsAllowed(): boolean
  hrtfReady(): boolean
  kick(): void
}

export class Mixer {
  private host: MixerHost
  private cands: VoiceCand[] = []
  private scratch: VoiceCand[] = []
  private perCount = new Map<number, number>()
  private realSet = new Set<number>()
  private decCands: DecoderCand[] = []
  private decScratch: DecoderCand[] = []
  private decPool = new Map<number, DecoderCand>()
  private decSet = new Set<number>()
  private best = new Map<number, number>()
  private live = new Map<number, number>()
  private hrtfCands: HrtfCand[] = []
  private hrtfScratch: HrtfCand[] = []
  private hrtfPool = new Map<number, HrtfCand>()
  private hrtfSet = new Set<number>()
  private nearest: Vec3 = { x: 0, y: 0, z: 0 }

  constructor(host: MixerHost) {
    this.host = host
  }

  /** One pass. `T` = the feed interval in seconds (0 on a tick: moving things ramp 50 ms). */
  update(T: number): void {
    const h = this.host
    const ctx = h.ctx
    if (!ctx) return
    const L = h.listener
    const now = h.now()
    const ctxNow = ctx.currentTime
    // 1. measure; remember the best emitter of every decoder source; warm clips up
    this.best.clear()
    if (L) {
      for (const em of h.emitters.values()) {
        const src = h.sources.get(em.spec.source)
        this.measure(em, src, L)
        if (!src || em.dist > em.spec.range + ARBITER.warmMargin) continue
        if (src.isDecoder()) {
          const sc = decoderScore(em.score, em.aud, em.dist, em.spec.range)
          const b = this.best.get(src.id)
          if (b === undefined || sc > b) this.best.set(src.id, sc)
        } else src.prefetch()
      }
    }
    // 2. decoders
    this.decCands.length = 0
    for (const src of h.sources.values()) {
      if (!src.isDecoder()) continue
      let c = this.decPool.get(src.id)
      if (!c) {
        c = { id: src.id, score: 0, active: false, since: 0, eligible: false, eff: 0 }
        this.decPool.set(src.id, c)
      }
      const b = this.best.get(src.id)
      const audible = h.vol.master * h.vol[src.spec.category] * src.spec.volume > 0
      c.score = b === undefined ? -1e9 : b
      c.active = src.active
      c.since = src.decoderSince
      c.eligible = b !== undefined && audible && src.usable() && (src.spec.type !== 'stream' || h.streamsAllowed())
      this.decCands.push(c)
    }
    selectDecoders(this.decCands, h.decoderBudget(), now, this.decSet, this.decScratch)
    for (const src of h.sources.values()) {
      if (!src.isDecoder()) continue
      const on = this.decSet.has(src.id)
      if (on && !src.active) {
        src.decoderSince = now
        src.setActive(true)
      } else if (!on && src.active) src.setActive(false)
    }
    // 3. voices
    this.cands.length = 0
    if (L) {
      for (const em of h.emitters.values()) {
        const src = h.sources.get(em.spec.source)
        const c = em.cand
        c.id = em.spec.id
        c.source = em.spec.source
        c.score = em.score
        c.audibility = em.aud
        c.real = !!em.voice && em.voice.state === 'on'
        c.since = em.voice ? em.voice.since : 0
        c.usable = !!src && src.usable() && (!src.isDecoder() || src.active)
          && (src.spec.type !== 'stream' || h.streamsAllowed())
        this.cands.push(c)
      }
    }
    selectVoices(this.cands, h.prefs.maxVoices, ARBITER.perSource, now, this.realSet, this.scratch, this.perCount)
    for (const em of h.emitters.values()) {
      const v = em.voice
      if (this.realSet.has(em.spec.id)) {
        if (!v || v.state === 'fading') this.makeReal(em, now, ctxNow)
        this.applyVoice(em, ctxNow, T)
      } else if (v && v.state === 'on') this.release(em, FADE.lod)
    }
    // 4. a buffer source plays while any of its voices lives
    this.live.clear()
    for (const em of h.emitters.values()) if (em.voice) this.count(em.voice.sourceId)
    for (const v of h.dying) this.count(v.sourceId)
    for (const src of h.sources.values()) {
      if (!src.isDecoder()) src.setActive(src.usable() && (this.live.get(src.id) || 0) > 0)
    }
    // 5. HRTF
    this.hrtf(now)
    this.prune()
  }

  private count(sourceId: number): void {
    this.live.set(sourceId, (this.live.get(sourceId) || 0) + 1)
  }

  private measure(em: Emitter, src: Source | undefined, L: Listener): void {
    const s = em.spec
    let px = em.x, py = em.y, pz = em.z
    let d: number
    if (s.zone) {
      // relative to the listener's ramp target: inside the zone the voice sits ON the listener
      d = zoneNearest(s.zone, L.tx, L.ty, L.tz, this.nearest)
      px = this.nearest.x
      py = this.nearest.y
      pz = this.nearest.z
    } else d = Math.hypot(px - L.x, py - L.y, pz - L.z)
    em.px = px
    em.py = py
    em.pz = pz
    em.dist = d
    const o = s.occlusion ? em.occl : 0
    let level = curveGain(s.curve, d, s.ref, s.range)
    if (level > 0) {
      if (!s.zone) level *= coneGain(s.cone, s.dir, px, py, pz, L.x, L.y, L.z)
      level *= occlusionGain(o) * s.volume
    }
    const rear = !s.zone && isBehind(L.fwd, L.x, L.y, L.z, px, py, pz)
    em.rear = rear
    em.level = level
    const vol = src ? this.host.vol[src.spec.category] * src.spec.volume : 0
    em.aud = level * vol * this.host.vol.master * (rear ? REAR_GAIN : 1)
    em.score = scoreDb(em.aud, s.priority)
    em.cutoff = Math.min(airCutoff(d), occlusionCutoff(o))
    em.send = 1 + 1.5 * o
  }

  private makeReal(em: Emitter, now: number, ctxNow: number): void {
    const h = this.host
    const src = h.sources.get(em.spec.source)
    const ctx = h.ctx
    if (!src || !ctx) return
    const old = em.voice
    if (old && old.state === 'fading') {
      if (old.sourceId === src.id && old.category === src.spec.category) {
        // still fading out: bring the same chain back up instead of building a second one
        if (old.timer !== null) h.cancel(old.timer)
        old.timer = null
        h.dying.delete(old)
        old.state = 'on'
        old.since = now
        old.fadeTo(1, ctxNow, FADE.lod)
        return
      }
      // a station switch / new bus: the old chain finishes its fade on its own (it is in `dying`)
      em.voice = null
    }
    const cat = src.spec.category
    const v = new Voice(ctx, em.spec.id, src.id, cat, { bus: h.bus(cat), send: h.sendBus(cat) }, now)
    v.attach(src.out)
    v.place(em.px, em.py, em.pz, ctxNow, 0)
    const lvl = em.level * (em.rear ? REAR_GAIN : 1)
    const cut = em.rear ? Math.min(em.cutoff, REAR_CUTOFF) : em.cutoff
    setAt(v.level.gain, lvl, ctxNow)
    setAt(v.filter.frequency, cut, ctxNow)
    setAt(v.send.gain, em.send, ctxNow)
    v.lastLevel = lvl
    v.lastCutoff = cut
    v.lastSend = em.send
    // content that starts right now gets an edge; anything already running comes up like a LOD
    const head = h.headOf(src.spec)
    const fresh = !src.startedOnce && src.spec.type !== 'stream' && (head === null || head <= 50)
    v.fadeTo(1, ctxNow, fresh ? (cat === 'sfx' ? FADE.cut : FADE.edge) : FADE.lod)
    em.voice = v
  }

  private applyVoice(em: Emitter, ctxNow: number, T: number): void {
    const v = em.voice
    if (!v || v.state !== 'on') return
    v.place(em.px, em.py, em.pz, ctxNow, (em.moving || em.spec.zone) && T > 0 ? T : 0.05)
    const rear = em.rear && !v.hrtf
    const lvl = em.level * (rear ? REAR_GAIN : 1)
    if (Math.abs(lvl - v.lastLevel) > Math.max(1e-5, 0.01 * Math.max(lvl, v.lastLevel))) {
      approach(v.level.gain, lvl, ctxNow, em.occlDirty ? 0.15 : Math.max(0.02, T / 2))
      v.lastLevel = lvl
    }
    const cut = rear ? Math.min(em.cutoff, REAR_CUTOFF) : em.cutoff
    if (Math.abs(cut - v.lastCutoff) > 0.02 * cut) {
      approach(v.filter.frequency, cut, ctxNow, 0.08)
      v.lastCutoff = cut
    }
    if (Math.abs(em.send - v.lastSend) > 0.01) {
      approach(v.send.gain, em.send, ctxNow, 0.15)
      v.lastSend = em.send
    }
    em.occlDirty = false
  }

  /** Fades a voice out and disposes it after the ramp (`stop` after the fade, R6 §8). */
  release(em: Emitter, fadeMs: number): void {
    const v = em.voice
    if (!v) return
    const h = this.host
    if (v.timer !== null) h.cancel(v.timer)
    v.state = 'fading'
    if (h.ctx) v.fadeTo(0, h.ctx.currentTime, fadeMs)
    h.dying.add(v)
    v.timer = h.later(() => {
      v.timer = null
      h.dying.delete(v)
      v.dispose()
      if (em.voice === v) em.voice = null
      h.kick()
    }, fadeMs + 40)
  }

  private hrtf(now: number): void {
    const h = this.host
    const n = h.prefs.hrtf && h.hrtfReady() ? h.prefs.hrtfVoices : 0
    this.hrtfCands.length = 0
    for (const em of h.emitters.values()) {
      const v = em.voice
      if (!v || v.state !== 'on') continue
      let c = this.hrtfPool.get(em.spec.id)
      if (!c) {
        c = { id: em.spec.id, dist: 0, hrtf: false, switchedAt: 0 }
        this.hrtfPool.set(em.spec.id, c)
      }
      c.dist = em.dist
      c.hrtf = v.hrtf
      c.switchedAt = v.switchedAt
      this.hrtfCands.push(c)
    }
    if (!this.hrtfCands.length) return
    selectHrtf(this.hrtfCands, n, now, this.hrtfSet, this.hrtfScratch)
    for (const c of this.hrtfCands) {
      const em = h.emitters.get(c.id)
      const v = em ? em.voice : null
      const want = this.hrtfSet.has(c.id)
      if (v && want !== v.hrtf) this.switchModel(v, want, now)
    }
  }

  /** A panning-model switch is not click-free: dip 30 ms, switch, come back. */
  private switchModel(v: Voice, hrtf: boolean, now: number): void {
    const h = this.host
    const ctx = h.ctx
    if (!ctx || now - v.since < 500 || now - v.switchedAt < 100) return
    v.switchedAt = now
    v.fadeTo(0, ctx.currentTime, 30)
    h.later(() => {
      if (v.state !== 'on') return
      v.setModel(hrtf, h.now())
      v.fadeTo(1, ctx.currentTime, 30)
    }, 35)
  }

  /** Drops pool entries of ids that are gone (rare: only when the pools grew past the live sets). */
  private prune(): void {
    const h = this.host
    if (this.decPool.size > h.sources.size * 2 + 64) {
      for (const id of this.decPool.keys()) if (!h.sources.has(id)) this.decPool.delete(id)
    }
    if (this.hrtfPool.size > h.emitters.size * 2 + 64) {
      for (const id of this.hrtfPool.keys()) if (!h.emitters.has(id)) this.hrtfPool.delete(id)
    }
  }

  /** Voice counts for stats and the arbiter tests. */
  counts(): { real: number; fading: number; hrtf: number; virtual: number } {
    let real = 0
    let hrtf = 0
    for (const em of this.host.emitters.values()) {
      const v = em.voice
      if (v && v.state === 'on') {
        real++
        if (v.hrtf) hrtf++
      }
    }
    return { real, fading: this.host.dying.size, hrtf, virtual: this.host.emitters.size - real }
  }
}
