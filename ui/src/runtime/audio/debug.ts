// core UI — audio engine: diagnostics (DESIGN §55.16 `/audiodebug`).
//
// `engineStats` is what `audio:stats` carries to Lua once per second while `audio:debug { on }` (voices
// real/virtual/fading/HRTF, sources and decoders, the clip cache, the clock offset, per-source drift);
// `inspectEmitter` and `probeLevel` back the dev seam `window.__core.audio` that the runtime suite uses
// to prove the k-rate wiring and that a tone really reaches the output. Nothing here runs unless asked.

import type { AudioEngine } from './engine.ts'
import { listenerParams, pannerParams } from './spatial.ts'

export function engineStats(e: AudioEngine): Record<string, unknown> {
  const ctx = e.ctx
  const counts = e.mixer.counts()
  let active = 0
  let decoders = 0
  let loading = 0
  let failed = 0
  let large = 0
  const drift: Array<Record<string, unknown>> = []
  for (const src of e.sources.values()) {
    if (src.active) active++
    if (src.active && src.isDecoder()) decoders++
    if (src.status === 'loading') loading++
    if (src.status === 'failed') failed++
    if (src.large) large++
    const d = src.active && src.player ? src.player.drift() : null
    if (d && drift.length < 8) drift.push({ id: src.id, errMs: Math.round(d.err * 1000), rate: Number(d.rate.toFixed(4)), locked: d.locked })
  }
  const offset = e.clock.offset()
  const L = e.listener
  return {
    context: ctx ? {
      state: ctx.state, sampleRate: ctx.sampleRate, baseLatency: ctx.baseLatency || 0,
      outputLatency: ctx.outputLatency || 0, time: Number(ctx.currentTime.toFixed(3)),
    } : null,
    voices: { real: counts.real, fading: counts.fading, virtual: counts.virtual, hrtf: counts.hrtf, max: e.prefs.maxVoices },
    sources: { total: e.sources.size, active, decoders, maxDecoders: e.decoderBudget(), loading, failed, large },
    emitters: e.emitters.size,
    loader: e.loader ? { downloads: e.loader.downloads, probes: e.loader.probes, decodes: e.loader.decodes } : null,
    cache: { bytes: e.cache.bytes(), limit: e.cache.limitBytes(), clips: e.cache.count(), hits: e.cache.hits, misses: e.cache.misses },
    clock: { synced: e.clock.synced(), offset: offset === null ? null : Math.round(offset), samples: e.clock.held(), latencyMs: Math.round(e.latencyMs()) },
    listener: L ? { x: Math.round(L.x * 100) / 100, y: Math.round(L.y * 100) / 100, z: Math.round(L.z * 100) / 100 } : null,
    reverb: e.reverbMode,
    paused: e.paused,
    errors: e.errors,
    drift,
  }
}

/** One emitter's chain as the suites check it: real or not, rates, panning model, levels. */
export function inspectEmitter(e: AudioEngine, emitterId: number): Record<string, unknown> | null {
  const ctx = e.ctx
  const em = e.emitters.get(emitterId)
  if (!ctx || !em) return null
  const v = em.voice
  return {
    real: !!v && v.state === 'on',
    state: v ? v.state : 'virtual',
    dist: em.dist,
    level: em.level,
    audibility: em.aud,
    score: em.score,
    voice: v ? {
      model: v.panner.panningModel,
      distanceModel: v.panner.distanceModel,
      rolloff: v.panner.rolloffFactor,
      pannerRates: pannerParams(v.panner).map((p) => p.automationRate),
      filterRates: [v.filter.frequency.automationRate, v.filter.Q.automationRate],
      level: v.level.gain.value,
      fader: v.fader.gain.value,
      cutoff: v.filter.frequency.value,
    } : null,
    listenerRates: listenerParams(ctx.listener).map((p) => p.automationRate),
  }
}

/** Peak |sample| at the limiter output over `ms` (the analyser is created and tapped on first use). */
export async function probeLevel(e: AudioEngine, ms: number): Promise<number | null> {
  const ctx = e.ctx
  if (!ctx || !e.limiter) return null
  if (!e.analyser) {
    e.analyser = ctx.createAnalyser()
    e.analyser.fftSize = 2048
    e.limiter.connect(e.analyser)
  }
  const a = e.analyser
  const buf = new Float32Array(a.fftSize)
  let peak = 0
  const end = e.now() + ms
  for (;;) {
    a.getFloatTimeDomainData(buf)
    for (let i = 0; i < buf.length; i++) {
      const v = Math.abs(buf[i])
      if (v > peak) peak = v
    }
    if (e.now() >= end) break
    await new Promise<void>((resolve) => {
      e.later(resolve, 25)
    })
  }
  return peak
}

/** `audio:error` to Lua, rate-limited: one per id and code per 10 s, five per second overall. */
export class ErrorGate {
  private seen = new Map<string, number>()
  private window: number[] = []

  allow(id: number, code: string, now: number): boolean {
    const key = id + ':' + code
    const at = this.seen.get(key)
    if (at !== undefined && now - at < 10000) return false
    if (this.seen.size > 256) this.seen.clear()
    this.seen.set(key, now)
    while (this.window.length && now - this.window[0] > 1000) this.window.shift()
    if (this.window.length >= 5) return false
    this.window.push(now)
    return true
  }
}
