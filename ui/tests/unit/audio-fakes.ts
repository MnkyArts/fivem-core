// Fakes for the audio engine units (DESIGN §55.23): a recording Web Audio graph, an <audio> element,
// virtual time and timers. Not a test file itself (no `.test.ts`): the audio-*.test.ts files import it.
// Params record every automation call; a ramp/target sets `value` to its target at once, which is
// what the assertions read ("where is this param heading").

import type { EngineEnv } from '../../src/runtime/audio/engine.ts'

export interface ParamEvent {
  type: 'set' | 'ramp' | 'target' | 'cancel'
  value?: number
  time: number
  tau?: number
}

export class FakeParam {
  value: number
  automationRate: 'a-rate' | 'k-rate' = 'a-rate'
  events: ParamEvent[] = []
  constructor(value: number) {
    this.value = value
  }
  setValueAtTime(value: number, time: number): this {
    this.events.push({ type: 'set', value, time })
    this.value = value
    return this
  }
  linearRampToValueAtTime(value: number, time: number): this {
    this.events.push({ type: 'ramp', value, time })
    this.value = value
    return this
  }
  setTargetAtTime(value: number, time: number, tau: number): this {
    this.events.push({ type: 'target', value, time, tau })
    this.value = value
    return this
  }
  cancelScheduledValues(time: number): this {
    this.events.push({ type: 'cancel', time })
    return this
  }
  last(type?: ParamEvent['type']): ParamEvent | undefined {
    for (let i = this.events.length - 1; i >= 0; i--) if (!type || this.events[i].type === type) return this.events[i]
    return undefined
  }
}

export class FakeNode {
  readonly ctx: FakeContext
  readonly kind: string
  outputs = new Set<FakeNode>()
  inputs = new Set<FakeNode>()
  disposed = false
  constructor(ctx: FakeContext, kind: string) {
    this.ctx = ctx
    this.kind = kind
    ctx.nodes.push(this)
  }
  connect<T>(dest: T): T {
    const d = dest as unknown as FakeNode
    this.outputs.add(d)
    if (d && d.inputs) d.inputs.add(this)
    return dest
  }
  disconnect(dest?: unknown): void {
    if (dest) {
      const d = dest as FakeNode
      this.outputs.delete(d)
      if (d.inputs) d.inputs.delete(this)
      return
    }
    for (const o of this.outputs) o.inputs.delete(this)
    this.outputs.clear()
  }
  /** Is there a path from this node to the destination? */
  reaches(target: FakeNode, seen = new Set<FakeNode>()): boolean {
    if (this === target) return true
    if (seen.has(this)) return false
    seen.add(this)
    for (const o of this.outputs) if (o.reaches(target, seen)) return true
    return false
  }
}

export class FakeGain extends FakeNode {
  gain = new FakeParam(1)
}
export class FakeBiquad extends FakeNode {
  type = 'lowpass'
  frequency = new FakeParam(350)
  Q = new FakeParam(1)
}
export class FakePanner extends FakeNode {
  panningModel = 'equalpower'
  distanceModel = 'inverse'
  refDistance = 1
  maxDistance = 10000
  rolloffFactor = 1
  coneInnerAngle = 360
  coneOuterAngle = 360
  coneOuterGain = 0
  positionX = new FakeParam(0)
  positionY = new FakeParam(0)
  positionZ = new FakeParam(0)
  orientationX = new FakeParam(1)
  orientationY = new FakeParam(0)
  orientationZ = new FakeParam(0)
}
export class FakeCompressor extends FakeNode {
  threshold = new FakeParam(-24)
  knee = new FakeParam(30)
  ratio = new FakeParam(12)
  attack = new FakeParam(0.003)
  release = new FakeParam(0.25)
}
export class FakeConvolver extends FakeNode {
  buffer: FakeBuffer | null = null
  normalize = true
}
export class FakeAnalyser extends FakeNode {
  fftSize = 2048
  getFloatTimeDomainData(buf: Float32Array): void {
    buf.fill(0.25)
  }
}

export class FakeBuffer {
  readonly numberOfChannels: number
  readonly length: number
  readonly sampleRate: number
  private data: Float32Array[]
  constructor(channels: number, length: number, sampleRate: number) {
    this.numberOfChannels = channels
    this.length = length
    this.sampleRate = sampleRate
    this.data = []
    for (let c = 0; c < channels; c++) this.data.push(new Float32Array(length))
  }
  get duration(): number {
    return this.length / this.sampleRate
  }
  getChannelData(c: number): Float32Array {
    return this.data[c]
  }
}

export class FakeBufferSource extends FakeNode {
  buffer: FakeBuffer | null = null
  loop = false
  playbackRate = new FakeParam(1)
  started: { when: number; offset: number } | null = null
  stopped: number | null = null
  onended: (() => void) | null = null
  start(when = 0, offset = 0): void {
    this.started = { when, offset }
  }
  stop(when = 0): void {
    this.stopped = when
  }
  /** the test plays the node to its end */
  end(): void {
    if (this.onended) this.onended()
  }
}

export class FakeMediaNode extends FakeNode {
  mediaElement: FakeAudio
  constructor(ctx: FakeContext, el: FakeAudio) {
    super(ctx, 'media')
    this.mediaElement = el
  }
}

export class FakeListener {
  positionX = new FakeParam(0)
  positionY = new FakeParam(0)
  positionZ = new FakeParam(0)
  forwardX = new FakeParam(0)
  forwardY = new FakeParam(0)
  forwardZ = new FakeParam(-1)
  upX = new FakeParam(0)
  upY = new FakeParam(1)
  upZ = new FakeParam(0)
}

export class FakeContext {
  currentTime = 0
  sampleRate = 48000
  state: 'running' | 'suspended' | 'closed' = 'running'
  baseLatency = 0
  outputLatency = 0
  nodes: FakeNode[] = []
  readonly destination: FakeNode
  readonly listener = new FakeListener()
  decodes = 0
  decodeFail = false
  /** seconds a decode yields (tests set it per clip), and how many channels */
  decodeSeconds = 1
  decodeChannels = 2
  resumes = 0
  suspends = 0
  closed = false
  constructor() {
    this.destination = new FakeNode(this, 'destination')
  }
  createGain(): FakeGain { return new FakeGain(this, 'gain') }
  createBiquadFilter(): FakeBiquad { return new FakeBiquad(this, 'biquad') }
  createPanner(): FakePanner { return new FakePanner(this, 'panner') }
  createDynamicsCompressor(): FakeCompressor { return new FakeCompressor(this, 'compressor') }
  createConvolver(): FakeConvolver { return new FakeConvolver(this, 'convolver') }
  createAnalyser(): FakeAnalyser { return new FakeAnalyser(this, 'analyser') }
  createBufferSource(): FakeBufferSource { return new FakeBufferSource(this, 'bufferSource') }
  createMediaElementSource(el: FakeAudio): FakeMediaNode { return new FakeMediaNode(this, el) }
  createBuffer(channels: number, length: number, sampleRate: number): FakeBuffer {
    return new FakeBuffer(channels, length, sampleRate)
  }
  decodeAudioData(_bytes: ArrayBuffer): Promise<FakeBuffer> {
    this.decodes++
    if (this.decodeFail) return Promise.reject(new Error('EncodingError'))
    return Promise.resolve(new FakeBuffer(this.decodeChannels, Math.round(this.decodeSeconds * this.sampleRate), this.sampleRate))
  }
  resume(): Promise<void> {
    this.resumes++
    this.state = 'running'
    return Promise.resolve()
  }
  suspend(): Promise<void> {
    this.suspends++
    this.state = 'suspended'
    return Promise.resolve()
  }
  close(): Promise<void> {
    this.closed = true
    this.state = 'closed'
    return Promise.resolve()
  }
  of<T extends FakeNode>(kind: string): T[] {
    return this.nodes.filter((n) => n.kind === kind) as T[]
  }
}

class Ranges {
  private r: Array<[number, number]>
  constructor(r: Array<[number, number]>) {
    this.r = r
  }
  get length(): number {
    return this.r.length
  }
  start(i: number): number {
    return this.r[i][0]
  }
  end(i: number): number {
    return this.r[i][1]
  }
}

export class FakeAudio {
  crossOrigin: string | null = null
  preload = ''
  loop = false
  muted = false
  preservesPitch = false
  ended = false
  /** called when a metadata-only element (the loader's duration probe) gets a source */
  onProbe: ((el: FakeAudio) => void) | null = null
  private _src = ''
  currentTime = 0
  duration = NaN
  paused = true
  playbackRate = 1
  readyState = 0
  error: unknown = null
  buffered = new Ranges([])
  plays = 0
  private listeners = new Map<string, Set<() => void>>()
  get src(): string {
    return this._src
  }
  /** HTML: loading a new source clears `error` and `ended` (the media element load algorithm) */
  set src(v: string) {
    this._src = v
    this.error = null
    this.ended = false
    if (v && this.preload === 'metadata' && this.onProbe) this.onProbe(this)
  }
  addEventListener(type: string, fn: () => void): void {
    let set = this.listeners.get(type)
    if (!set) {
      set = new Set()
      this.listeners.set(type, set)
    }
    set.add(fn)
  }
  removeEventListener(type: string, fn: () => void): void {
    const set = this.listeners.get(type)
    if (set) set.delete(fn)
  }
  emit(type: string): void {
    const set = this.listeners.get(type)
    if (set) for (const fn of Array.from(set)) fn()
  }
  play(): Promise<void> {
    this.paused = false
    this.plays++
    return Promise.resolve()
  }
  pause(): void {
    this.paused = true
  }
  readonly load = (): void => { /* nothing to load */ }
  removeAttribute(name: string): void {
    if (name === 'src') this._src = ''
  }
  setBuffered(r: Array<[number, number]>): void {
    this.buffered = new Ranges(r)
  }
}

export interface Harness {
  env: EngineEnv
  ctx: FakeContext
  /** the media elements players created (the loader's metadata probes are left out) */
  readonly audios: FakeAudio[]
  /** every element, probes included */
  allAudios: FakeAudio[]
  /** what a duration probe answers: seconds, or null for "unknown" (default: ctx.decodeSeconds) */
  probeSeconds: number | null | undefined
  /** signals the fetches were given */
  signals: AbortSignal[]
  reports: Array<{ event: string; data: Record<string, unknown> }>
  fetches: string[]
  /** contexts created so far */
  created(): number
  now(): number
  /** runs every timer due within `ms` (in order), advancing virtual time and ctx.currentTime */
  advance(ms: number): void
  /** lets pending promises settle (fetch → arrayBuffer → decode → then) */
  settle(): Promise<void>
  pendingTimers(): number
  /** fetch answers with this many bytes (default 1000) or fails with `fail` */
  fetchBytes: number
  fetchFail: boolean
}

export function harness(): Harness {
  const ctx = new FakeContext()
  const timers: Array<{ id: number; at: number; fn: () => void }> = []
  let now = 1000
  let seq = 0
  let created = 0
  const h: Harness = {
    ctx,
    allAudios: [],
    get audios(): FakeAudio[] {
      return this.allAudios.filter((a: FakeAudio) => a.preload !== 'metadata')
    },
    probeSeconds: undefined,
    signals: [],
    reports: [],
    fetches: [],
    fetchBytes: 1000,
    fetchFail: false,
    created: () => created,
    now: () => now,
    env: undefined as unknown as EngineEnv,
    advance(ms: number) {
      const end = now + ms
      for (;;) {
        timers.sort((a, b) => a.at - b.at || a.id - b.id)
        const t = timers[0]
        if (!t || t.at > end) break
        timers.shift()
        ctx.currentTime += (t.at - now) / 1000
        now = t.at
        t.fn()
      }
      ctx.currentTime += (end - now) / 1000
      now = end
    },
    async settle() {
      for (let i = 0; i < 8; i++) await new Promise<void>((r) => setImmediate(r))
    },
    pendingTimers: () => timers.length,
  }
  h.env = {
    createContext: () => {
      created++
      return ctx as unknown as AudioContext
    },
    now: () => now,
    setTimeout: (fn, ms) => {
      const id = ++seq
      timers.push({ id, at: now + Math.max(0, ms), fn })
      return id
    },
    clearTimeout: (handle) => {
      const i = timers.findIndex((t) => t.id === handle)
      if (i !== -1) timers.splice(i, 1)
    },
    fetch: ((url: string, init?: RequestInit) => {
      h.fetches.push(String(url))
      if (init && init.signal) h.signals.push(init.signal)
      if (h.fetchFail) return Promise.reject(new TypeError('Failed to fetch'))
      return Promise.resolve(new Response(new Uint8Array(h.fetchBytes)))
    }) as unknown as typeof fetch,
    createAudio: () => {
      const a = new FakeAudio()
      a.onProbe = (el) => {
        void Promise.resolve().then(() => {
          const d = h.probeSeconds === undefined ? ctx.decodeSeconds : h.probeSeconds
          if (d === null) el.emit('error')
          else {
            el.duration = d
            el.emit('loadedmetadata')
          }
        })
      }
      h.allAudios.push(a)
      return a as unknown as HTMLAudioElement
    },
    MediaSource: null,
    createObjectURL: () => 'blob:fake/' + ++seq,
    revokeObjectURL: () => {},
    importHls: () => Promise.reject(new Error('no hls.js in unit tests')),
    report: (event, data) => {
      h.reports.push({ event, data })
    },
    dev: true,
  }
  return h
}

// ---------------------------------------------------------------- MSE and streaming responses

export class FakeSourceBuffer {
  mode = 'segments'
  updating = false
  appended = 0
  /** a DOMException name every append throws (a broken MediaSource: 'InvalidStateError') */
  failWith: string | null = null
  onAppend: ((bytes: number) => void) | null = null
  private l = new Map<string, Set<() => void>>()
  addEventListener(t: string, fn: () => void): void {
    let set = this.l.get(t)
    if (!set) {
      set = new Set()
      this.l.set(t, set)
    }
    set.add(fn)
  }
  appendBuffer(b: Uint8Array): void {
    if (this.failWith) throw new DOMException('append refused', this.failWith)
    this.appended += b.length
    if (this.onAppend) this.onAppend(b.length)
  }
  remove(): void { /* nothing buffered to drop */ }
}

export interface FakeMediaSourceKit {
  MS: typeof MediaSource
  created: Array<{ readyState: string; sb: FakeSourceBuffer | null }>
  /** every SourceBuffer created so far */
  buffers(): FakeSourceBuffer[]
}

/** A MediaSource class for `h.env.MediaSource`: opens on the next microtask, takes audio/mpeg. */
export function fakeMediaSource(onBuffer?: (sb: FakeSourceBuffer) => void): FakeMediaSourceKit {
  const created: Array<{ readyState: string; sb: FakeSourceBuffer | null }> = []
  class MS {
    static isTypeSupported(t: string): boolean {
      return t === 'audio/mpeg'
    }
    readyState = 'closed'
    sb: FakeSourceBuffer | null = null
    private l = new Map<string, Array<() => void>>()
    constructor() {
      created.push(this)
      void Promise.resolve().then(() => {
        this.readyState = 'open'
        for (const f of this.l.get('sourceopen') || []) f()
      })
    }
    addEventListener(t: string, fn: () => void): void {
      const list = this.l.get(t) || []
      list.push(fn)
      this.l.set(t, list)
    }
    addSourceBuffer(): FakeSourceBuffer {
      this.sb = new FakeSourceBuffer()
      if (onBuffer) onBuffer(this.sb)
      return this.sb
    }
  }
  return {
    MS: MS as unknown as typeof MediaSource,
    created,
    buffers: () => created.map((m) => m.sb).filter((b): b is FakeSourceBuffer => !!b),
  }
}

/**
 * A Response whose body is `pull`-driven and — like a real fetch — errors with an AbortError when the
 * request's signal aborts. `url` fakes the final URL after redirects.
 */
export function streamResponse(
  signal: AbortSignal | null | undefined,
  pull: (c: ReadableStreamDefaultController<Uint8Array>) => void | Promise<void>,
  opts?: { headers?: Record<string, string>; url?: string; status?: number },
): Response {
  let ctl: ReadableStreamDefaultController<Uint8Array> | null = null
  // highWaterMark 0: `pull` runs only when the body is READ (a headers-only preflight never pulls)
  const body = new ReadableStream<Uint8Array>({
    start(c) { ctl = c },
    pull: (c) => pull(c),
  }, { highWaterMark: 0 })
  if (signal) {
    signal.addEventListener('abort', () => {
      try {
        if (ctl) ctl.error(new DOMException('The operation was aborted.', 'AbortError'))
      } catch (err) { /* already closed */ }
    }, { once: true })
  }
  const res = new Response(body, { headers: opts && opts.headers, status: opts && opts.status ? opts.status : 200 })
  if (opts && opts.url) Object.defineProperty(res, 'url', { value: opts.url })
  return res
}
