// core UI — audio engine: the per-voice graph, parameter recipes, the reverb (DESIGN §55.16;
// R6 §1.1–§1.4, §3.2, §8).
//
// One REAL voice = one emitter that is currently audible enough to earn a chain:
//
//   source.out ─► Biquad lowpass ─► level (Gain) ─► fader (Gain) ─► Panner ─► category bus
//                (occlusion, air,   (curve × cone ×  (LOD/steal/cut              └─ send (Gain) ─► reverb input
//                 rear cue)          occlusion × vol) ramps only)
//
// * EVERY PannerNode and AudioListener param is `automationRate = 'k-rate'`: Chromium otherwise takes
//   the per-sample panner path for every voice as soon as anything is automated (15× the cost,
//   R6 §1.2). Positions move by `linearRampToValueAtTime` over the feed interval — k-rate ramps are a
//   2.67 ms staircase, i.e. smooth — and `rolloffFactor = 0` (distance lives in `level`).
// * `level` and `fader` are separate nodes so a continuous distance update never cancels a fade.
// * Every parameter change first HOLDS the current value (read before cancelling), then ramps: a
//   bare cancelScheduledValues() would snap back to the previous event's value (R6 §8).
// * Reverb: two procedural impulse responses (small room / large space), crossfaded over 0.5 s by
//   the listener's environment; the idle convolver is disconnected so it stops processing.

import type { Category } from './types.ts'

export const CATEGORIES: ReadonlyArray<Category> = ['music', 'sfx', 'ambience', 'voice']

export function kRate(p: AudioParam): void {
  try {
    p.automationRate = 'k-rate'
  } catch (err) {
    /* a param with a fixed rate */
  }
}

export function listenerParams(l: AudioListener): AudioParam[] {
  return [l.positionX, l.positionY, l.positionZ, l.forwardX, l.forwardY, l.forwardZ, l.upX, l.upY, l.upZ]
}

export function pannerParams(p: PannerNode): AudioParam[] {
  return [p.positionX, p.positionY, p.positionZ, p.orientationX, p.orientationY, p.orientationZ]
}

/** Hold the current value, then ramp linearly to `value` over `seconds` (the R6 §1.4 recipe). */
export function rampTo(p: AudioParam, value: number, now: number, seconds: number): void {
  const v = p.value
  p.cancelScheduledValues(now)
  p.setValueAtTime(v, now)
  p.linearRampToValueAtTime(value, now + Math.max(0.003, seconds))
}

/** Hold the current value, then approach `value` exponentially (τ seconds; 95 % after 3τ). */
export function approach(p: AudioParam, value: number, now: number, tau: number): void {
  const v = p.value
  p.cancelScheduledValues(now)
  p.setValueAtTime(v, now)
  p.setTargetAtTime(value, now, Math.max(0.001, tau))
}

/** A step (only for params nobody hears move: a silent node, a static panner). */
export function setAt(p: AudioParam, value: number, now: number): void {
  p.cancelScheduledValues(now)
  p.setValueAtTime(value, now)
}

// ---------------------------------------------------------------- the voice

export interface VoiceOutputs {
  bus: AudioNode
  send: AudioNode
}

export class Voice {
  readonly emitterId: number
  readonly sourceId: number
  readonly category: Category
  readonly filter: BiquadFilterNode
  readonly level: GainNode
  readonly fader: GainNode
  readonly panner: PannerNode
  readonly send: GainNode
  /** 'on' = real (fading in or steady), 'fading' = on its way out */
  state: 'on' | 'fading' = 'on'
  /** performance ms when it became real */
  since: number
  hrtf = false
  switchedAt = -Infinity
  /** the release timer while fading out */
  timer: unknown = null
  /** last targets applied — skip automation that would not change anything */
  lastLevel = -1
  lastCutoff = -1
  lastSend = -1
  lastX = NaN
  lastY = NaN
  lastZ = NaN
  private upstream: AudioNode | null = null

  constructor(ctx: BaseAudioContext, emitterId: number, sourceId: number, category: Category, out: VoiceOutputs, since: number) {
    this.emitterId = emitterId
    this.sourceId = sourceId
    this.category = category
    this.since = since
    const f = ctx.createBiquadFilter()
    f.type = 'lowpass'
    kRate(f.frequency)
    kRate(f.Q)
    f.frequency.value = 20000
    f.Q.value = 0.7071
    this.filter = f
    this.level = ctx.createGain()
    this.level.gain.value = 0
    this.fader = ctx.createGain()
    this.fader.gain.value = 0
    const p = ctx.createPanner()
    p.panningModel = 'equalpower'
    p.distanceModel = 'linear'
    p.refDistance = 1
    p.maxDistance = 10000
    p.rolloffFactor = 0
    p.coneInnerAngle = 360
    p.coneOuterAngle = 360
    p.coneOuterGain = 0
    for (const param of pannerParams(p)) kRate(param)
    this.panner = p
    this.send = ctx.createGain()
    this.send.gain.value = 1
    f.connect(this.level)
    this.level.connect(this.fader)
    this.fader.connect(p)
    p.connect(out.bus)
    this.fader.connect(this.send)
    this.send.connect(out.send)
  }

  /** Connects the source's output (the fan-out) into this chain. */
  attach(src: AudioNode): void {
    if (this.upstream === src) return
    this.detach()
    src.connect(this.filter)
    this.upstream = src
  }

  detach(): void {
    if (!this.upstream) return
    try {
      this.upstream.disconnect(this.filter)
    } catch (err) {
      /* already gone */
    }
    this.upstream = null
  }

  /** Moves the panner: a ramp over `seconds`, or a step when `seconds` is 0 (a fresh voice). */
  place(x: number, y: number, z: number, now: number, seconds: number): void {
    if (x === this.lastX && y === this.lastY && z === this.lastZ) return
    const p = this.panner
    if (seconds > 0 && this.lastX === this.lastX) {
      rampTo(p.positionX, x, now, seconds)
      rampTo(p.positionY, y, now, seconds)
      rampTo(p.positionZ, z, now, seconds)
    } else {
      setAt(p.positionX, x, now)
      setAt(p.positionY, y, now)
      setAt(p.positionZ, z, now)
    }
    this.lastX = x
    this.lastY = y
    this.lastZ = z
  }

  fadeTo(value: number, now: number, ms: number): void {
    rampTo(this.fader.gain, value, now, ms / 1000)
  }

  setModel(hrtf: boolean, now: number): void {
    this.panner.panningModel = hrtf ? 'HRTF' : 'equalpower'
    this.hrtf = hrtf
    this.switchedAt = now
  }

  dispose(): void {
    this.detach()
    for (const n of [this.filter, this.level, this.fader, this.panner, this.send] as AudioNode[]) {
      try {
        n.disconnect()
      } catch (err) {
        /* already disconnected */
      }
    }
  }
}

// ---------------------------------------------------------------- reverb

/** Deterministic xorshift32 noise in [-1, 1). */
function noiseGen(seed: number): () => number {
  let s = seed >>> 0 || 0x9e3779b9
  return () => {
    s ^= s << 13
    s >>>= 0
    s ^= s >>> 17
    s ^= s << 5
    s >>>= 0
    return s / 2147483648 - 1
  }
}

export interface ImpulseSpec {
  seconds: number
  /** time to decay by 60 dB */
  rt60: number
  preDelayMs: number
  /** 0 = bright tail … 0.95 = dark tail (one-pole lowpass closing over the tail) */
  damping: number
  /** early reflections: [ms, gain] */
  early: ReadonlyArray<readonly [number, number]>
  seed: number
}

export const SMALL_ROOM: ImpulseSpec = {
  seconds: 0.7, rt60: 0.55, preDelayMs: 4, damping: 0.55, seed: 0x51a11,
  early: [[7, 0.5], [11, -0.42], [17, 0.35], [23, -0.3], [31, 0.24], [38, -0.2]],
}
export const LARGE_SPACE: ImpulseSpec = {
  seconds: 2.0, rt60: 1.7, preDelayMs: 22, damping: 0.85, seed: 0x1a46e,
  early: [[31, 0.35], [47, -0.28], [66, 0.22], [89, -0.17]],
}

/** Exponentially decaying, progressively darker stereo noise + a few early taps (no download). */
export function makeImpulse(ctx: BaseAudioContext, spec: ImpulseSpec): AudioBuffer {
  const sr = ctx.sampleRate
  const len = Math.max(2, Math.floor(spec.seconds * sr))
  const buf = ctx.createBuffer(2, len, sr)
  const pre = Math.min(len - 1, Math.floor((spec.preDelayMs / 1000) * sr))
  const k = Math.log(1000) / (spec.rt60 * sr)
  for (let c = 0; c < 2; c++) {
    const d = buf.getChannelData(c)
    const rnd = noiseGen(spec.seed + c * 7919)
    let lp = 0
    for (let i = pre; i < len; i++) {
      const t = (i - pre) / (len - pre)
      const a = 1 - spec.damping * t
      lp += a * (rnd() - lp)
      d[i] = lp * Math.exp(-k * (i - pre))
    }
    for (const [ms, g] of spec.early) {
      const i = Math.floor((ms / 1000) * sr) + (c ? 3 : 0)
      if (i < len) d[i] += c ? -g * 0.9 : g
    }
  }
  return buf
}

export type ReverbMode = 'small' | 'large' | 'dry'

/** Wet levels per environment (R6 §3.2): a room −12 dB, outdoors −18 dB, car/underwater dry. */
export const REVERB_WET: Record<ReverbMode, [number, number]> = {
  small: [0.25, 0],
  large: [0, 0.125],
  dry: [0, 0],
}

export class Reverb {
  readonly input: GainNode
  readonly small: ConvolverNode
  readonly large: ConvolverNode
  readonly wetSmall: GainNode
  readonly wetLarge: GainNode
  mode: ReverbMode = 'dry'
  private linked = [false, false]
  private timers: unknown[] = [null, null]
  private later: (fn: () => void, ms: number) => unknown
  private cancel: (h: unknown) => void

  constructor(ctx: BaseAudioContext, out: AudioNode, later: (fn: () => void, ms: number) => unknown, cancel: (h: unknown) => void) {
    this.later = later
    this.cancel = cancel
    this.input = ctx.createGain()
    this.small = ctx.createConvolver()
    this.small.buffer = makeImpulse(ctx, SMALL_ROOM)
    this.large = ctx.createConvolver()
    this.large.buffer = makeImpulse(ctx, LARGE_SPACE)
    this.wetSmall = ctx.createGain()
    this.wetSmall.gain.value = 0
    this.wetLarge = ctx.createGain()
    this.wetLarge.gain.value = 0
    this.small.connect(this.wetSmall)
    this.large.connect(this.wetLarge)
    this.wetSmall.connect(out)
    this.wetLarge.connect(out)
  }

  /** Crossfades to the environment's wet levels over `ms` and unlinks the silent convolver. */
  setMode(mode: ReverbMode, now: number, ms: number): void {
    if (mode === this.mode) return
    this.mode = mode
    const wet = REVERB_WET[mode]
    const nodes = [this.small, this.large]
    const gains = [this.wetSmall, this.wetLarge]
    for (let i = 0; i < 2; i++) {
      if (this.timers[i] !== null) {
        this.cancel(this.timers[i])
        this.timers[i] = null
      }
      if (wet[i] > 0 && !this.linked[i]) {
        this.input.connect(nodes[i])
        this.linked[i] = true
      }
      rampTo(gains[i].gain, wet[i], now, ms / 1000)
      if (wet[i] === 0 && this.linked[i]) {
        this.timers[i] = this.later(() => {
          this.timers[i] = null
          if (REVERB_WET[this.mode][i] === 0 && this.linked[i]) {
            try { this.input.disconnect(nodes[i]) } catch (err) { /* already */ }
            this.linked[i] = false
          }
        }, ms + 50)
      }
    }
  }

  linkedState(): [boolean, boolean] {
    return [this.linked[0], this.linked[1]]
  }
}

// ---------------------------------------------------------------- the fixed master graph

export interface MasterGraph {
  limiter: DynamicsCompressorNode
  duck: GainNode
  masterVol: GainNode
  /** gain 0 → destination: keeps every source's fan-out pulled (see SourceEnv.keepAlive) */
  keepAlive: GainNode
  reverb: Reverb
  buses: Record<Category, GainNode>
  sendIn: Record<Category, GainNode>
}

/**
 * buses[cat] ─► masterVol ─► duck ─► limiter (−3 dB, 20:1, 3 ms) ─► destination;
 * sendIn[cat] ─► reverb ─► masterVol; keepAlive (gain 0) ─► destination.
 */
export function buildMaster(
  ctx: BaseAudioContext, vol: Record<Category | 'master', number>, paused: boolean,
  later: (fn: () => void, ms: number) => unknown, cancel: (h: unknown) => void,
): MasterGraph {
  const limiter = ctx.createDynamicsCompressor()
  limiter.threshold.value = -3
  limiter.knee.value = 0
  limiter.ratio.value = 20
  limiter.attack.value = 0.003
  limiter.release.value = 0.25
  const duck = ctx.createGain()
  const masterVol = ctx.createGain()
  masterVol.connect(duck)
  duck.connect(limiter)
  limiter.connect(ctx.destination)
  duck.gain.value = paused ? 0 : 1
  masterVol.gain.value = vol.master
  const keepAlive = ctx.createGain()
  keepAlive.gain.value = 0
  keepAlive.connect(ctx.destination)
  const reverb = new Reverb(ctx, masterVol, later, cancel)
  const buses = {} as Record<Category, GainNode>
  const sendIn = {} as Record<Category, GainNode>
  for (const cat of CATEGORIES) {
    const bus = ctx.createGain()
    bus.gain.value = vol[cat]
    bus.connect(masterVol)
    buses[cat] = bus
    const send = ctx.createGain()
    send.gain.value = vol[cat]
    send.connect(reverb.input)
    sendIn[cat] = send
  }
  return { limiter, duck, masterVol, keepAlive, reverb, buses, sendIn }
}

// ---------------------------------------------------------------- the listener

/** Drives the nine k-rate AudioListener params: a step the first time, then ramps over the feed interval. */
export class ListenerDriver {
  private params: AudioParam[]
  private target = new Float64Array(9)
  private placed = false

  constructor(l: AudioListener) {
    this.params = listenerParams(l)
    for (const p of this.params) kRate(p)
  }

  apply(now: number, L: { tx: number; ty: number; tz: number; fwd: { x: number; y: number; z: number }; up: { x: number; y: number; z: number } }, T: number): void {
    const t = this.target
    t[0] = L.tx
    t[1] = L.ty
    t[2] = L.tz
    t[3] = L.fwd.x
    t[4] = L.fwd.y
    t[5] = L.fwd.z
    t[6] = L.up.x
    t[7] = L.up.y
    t[8] = L.up.z
    for (let i = 0; i < 9; i++) {
      if (T > 0 && this.placed) rampTo(this.params[i], t[i], now, T)
      else setAt(this.params[i], t[i], now)
    }
    this.placed = true
  }
}
