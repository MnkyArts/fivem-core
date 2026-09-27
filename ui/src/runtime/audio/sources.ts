// core UI — audio engine: sources and their decoders (DESIGN §55.16; R6 §1.6, §2.3, §4.4–§4.5, §9.1).
//
// A Source is content + clock; ONE decoder per source fans out (its `out` GainNode) to every real
// voice of every emitter that plays it. What decodes depends on the type:
//   clip / loop   the loader (loader.ts) decides: an AudioBuffer (bounded decode, LRU-cached, pinned
//                 only while a node plays) started sample-exactly at the clock-derived head — or, for a
//                 file too long/big to decode, a media element (media.ts), which needs a decoder slot.
//                 That verdict is sticky for the source (`large`), so losing and regaining the slot
//                 never re-downloads. An UNTRUSTED source (`trusted = false`) never meets the loader:
//                 no download for a verdict, no probe, never decodeAudioData — always an element.
//   timeline      media elements per item, drift-controlled (media.ts)
//   stream        MP3 Icecast → fetch + ICY + MSE, Ogg → <audio>, HLS → hls.js (streams.ts)
//   voice         nothing here: world-speaker voice is Mumble's (§55.17)
// Every download a source starts carries its AbortController (a removed or re-addressed source stops
// downloading at once). A failed fetch is retried with backoff 1, 2, 4, 8 s (reported once per
// streak, RETRY in types.ts) before the source fails; a clock or content update revives a failed one.

import type { AudioErrorCode, SourceSpec } from './types.ts'
import { FADE, RETRY } from './types.ts'
import type { Clocked } from './sync.ts'
import { clipStartable, mod, wrapError } from './sync.ts'
import { rampTo } from './spatial.ts'
import { loadCode, makePolicy } from './net.ts'
import type { HostPolicy } from './net.ts'
import type { BufferLoader } from './loader.ts'
import { backoffMs } from './icy.ts'
import { ElementPlayer, TimelinePlayer } from './media.ts'
import type { HlsCtor } from './media.ts'
import { StreamPlayer } from './streams.ts'

/** A one-shot may start this much later than the clock says because the PAGE was loading it. */
export const LOCAL_DELAY_MAX_MS = 1500

/** Everything a source needs from the page; the engine builds one, the unit tests fake it. */
export interface SourceEnv {
  ctx: AudioContext
  fetch: typeof fetch
  createAudio(): HTMLAudioElement
  MediaSource: typeof MediaSource | null
  createObjectURL(o: Blob | MediaSource): string
  revokeObjectURL(u: string): void
  importHls(): Promise<HlsCtor>
  now(): number
  setTimeout(fn: () => void, ms: number): unknown
  clearTimeout(h: unknown): void
  loader: BufferLoader
  /**
   * A silent sink (gain 0 → destination) every source's fan-out is tied to: Web Audio only renders
   * what the destination pulls, and a media element behind createMediaElementSource stops advancing
   * when nothing pulls it — a decoding source whose voices are all virtual must keep its position.
   */
  keepAlive: AudioNode
  /** play head (ms) a media element should be at right now (graph latency included); null until synced */
  head(spec: Clocked): number | null
  /**
   * play head (ms) a buffer node must render at context time `ctxT`; null while a new context's
   * output clock starts, unless `now` (one-shots start at once on the render clock)
   */
  headAtCtx(spec: Clocked, ctxT: number, now?: boolean): number | null
  report(id: number, code: AudioErrorCode): void
  /** true in the CEF: every response header is readable (web security is off) */
  trustHeaders: boolean
  /** a dev page: http/blob/data URLs pass the host rule */
  dev: boolean
  /** the learned seek latency in seconds (R6 §4.5 `L_seek`): every join corrects it (deck.ts) */
  seek: { lead: number }
}

/** What a player may do to the source that owns it. */
export interface SourceHost {
  readonly id: number
  readonly spec: SourceSpec
  readonly out: GainNode
  readonly env: SourceEnv
  /** the host rule for this source's URLs (its own host + the server's `hosts`) */
  readonly policy: HostPolicy
  /** aborted when the source is removed or re-addressed */
  readonly signal: AbortSignal
  startedOnce: boolean
  /** ms of a one-shot that had already "played" when the page heard of it (null: unknown yet) */
  lateMs: number | null
  loops(): boolean
  markReady(): void
  markEnded(): void
  /** give up (permanent) — the player already retried where retrying makes sense */
  fail(code: AudioErrorCode): void
}

export interface Player {
  readonly decoder: boolean
  /** begin (or resume) playback — idempotent */
  start(): void
  /** stop after a fade; start() may follow */
  stop(fadeMs: number): void
  /** ≤ 5 Hz: clock alignment, item switches, stream health, retries */
  tick(now: number): void
  /** the clock parameters changed: re-align now */
  resync(): void
  dispose(): void
  drift(): { err: number; rate: number; locked: boolean } | null
}

// ---------------------------------------------------------------- the buffer player (clip / loop)

/** Seconds of lead so a start is never scheduled in the past. */
const LEAD = 0.03

export class BufferPlayer implements Player {
  readonly decoder = false
  readonly buffer: AudioBuffer
  private host: SourceHost
  private node: AudioBufferSourceNode | null = null
  private gain: GainNode | null = null
  private anchorCtx = 0
  private anchorPos = 0
  private rateEff = 1
  private lastErr = 0

  constructor(host: SourceHost, buffer: AudioBuffer) {
    this.host = host
    this.buffer = buffer
  }

  start(): void {
    this.begin(this.host.spec.category === 'sfx' ? FADE.cut : FADE.edge, FADE.lod)
  }

  /**
   * Starts a node at the clock position: `edgeMs` fades a start at the very top of the content,
   * `midMs` one inside it (a late join or a LOD transition).
   */
  private begin(edgeMs: number, midMs: number): void {
    if (this.node) return
    const env = this.host.env
    const spec = this.host.spec
    if (spec.paused) return
    const ctx = env.ctx
    const loop = this.host.loops()
    let when = ctx.currentTime + LEAD
    // a loop waits for the precise output clock (it fades in anyway); a one-shot never waits
    const h = env.headAtCtx(spec, when, !loop)
    if (h === null) return
    const dur = this.buffer.duration * 1000
    let offset = 0
    if (h < 0) when += -h / 1000 / spec.rate
    else if (loop) offset = mod(h, dur) / 1000
    else {
      const at = this.oneShotAt(h, dur)
      if (at === null) {
        this.host.markEnded()
        return
      }
      offset = at / 1000
    }
    const node = ctx.createBufferSource()
    node.buffer = this.buffer
    node.loop = loop
    node.playbackRate.value = spec.rate
    const gain = ctx.createGain()
    gain.gain.value = 0
    node.connect(gain)
    gain.connect(this.host.out)
    // a start inside the content fades in like a LOD transition, a start at the top is an edge
    rampTo(gain.gain, 1, when, (offset > 0.05 ? midMs : edgeMs) / 1000)
    node.start(when, offset)
    this.node = node
    this.gain = gain
    this.anchorCtx = when
    this.anchorPos = offset
    this.rateEff = spec.rate
    this.host.startedOnce = true
    if (!loop) {
      node.onended = () => {
        if (this.node !== node) return
        this.release()
        this.host.markEnded()
      }
    }
  }

  /**
   * Where a one-shot starts (ms), or null when it is over. Only the NETWORK lateness counts against
   * the one-shot rule (R6 §2.3): the part the page spent fetching/decoding delays the start rather
   * than eating the attack (up to LOCAL_DELAY_MAX_MS). A clip heard before resumes where it is.
   */
  private oneShotAt(h: number, dur: number): number | null {
    if (this.host.startedOnce) return clipStartable(h, dur, true) ? h : null
    const late = this.host.lateMs === null ? h : Math.max(0, Math.min(h, this.host.lateMs))
    if (!clipStartable(late, dur, false)) return null
    // `h` is the head at the scheduled start (LEAD from now): that lead is no delay
    const local = h - late - LEAD * 1000 * this.host.spec.rate
    if (local <= 20) return h
    return local <= Math.max(LOCAL_DELAY_MAX_MS, dur) ? late : null
  }

  stop(fadeMs: number): void {
    const node = this.node
    const gain = this.gain
    if (!node || !gain) return
    this.node = null
    this.gain = null
    node.onended = null
    const now = this.host.env.ctx.currentTime
    rampTo(gain.gain, 0, now, fadeMs / 1000)
    try {
      node.stop(now + fadeMs / 1000 + 0.02)
    } catch (err) {
      /* not started yet */
    }
    this.host.env.setTimeout(() => {
      try {
        gain.disconnect()
      } catch (err) {
        /* already */
      }
    }, fadeMs + 80)
  }

  private release(): void {
    if (this.gain) {
      try {
        this.gain.disconnect()
      } catch (err) {
        /* already */
      }
    }
    this.node = null
    this.gain = null
  }

  /**
   * Clock drift of a long-running loop, both sides evaluated at the same context time: ±0.1 %
   * playbackRate past 12 ms (inaudible, absorbs 100 ppm), back to nominal under 4 ms, and a 100 ms
   * crossfade restart past 80 ms (a context that stalled, a device that restarted).
   */
  tick(): void {
    const node = this.node
    const env = this.host.env
    if (!node || env.ctx.state !== 'running' || !this.host.loops()) return
    const now = env.ctx.currentTime
    if (now < this.anchorCtx) return
    const head = env.headAtCtx(this.host.spec, now)
    if (head === null) return
    const period = this.buffer.duration
    const actual = mod(this.anchorPos + (now - this.anchorCtx) * this.rateEff, period)
    const err = wrapError(actual, mod(head / 1000, period), period)
    this.lastErr = err
    const nominal = this.host.spec.rate
    if (Math.abs(err) > 0.08) {
      this.resync()
      return
    }
    let next = this.rateEff
    if (Math.abs(err) > 0.012) next = nominal * (err > 0 ? 0.999 : 1.001)
    else if (Math.abs(err) < 0.004) next = nominal
    if (next !== this.rateEff) {
      this.anchorPos = actual
      this.anchorCtx = now
      this.rateEff = next
      node.playbackRate.setValueAtTime(next, now)
    }
  }

  /** New clock parameters: crossfade to a fresh node at the new head (100 ms, correlated material). */
  resync(): void {
    if (!this.node) return
    this.stop(100)
    this.begin(100, 100)
  }

  dispose(): void {
    this.stop(FADE.stop)
  }

  drift(): { err: number; rate: number; locked: boolean } | null {
    return this.node && this.host.loops() ? { err: this.lastErr, rate: this.rateEff, locked: true } : null
  }
}

// ---------------------------------------------------------------- the source

/** The hosts a source may reach: its own URL's (every item's, for a timeline) + the server's `hosts`. */
function policyOf(spec: SourceSpec, dev: boolean): HostPolicy {
  const urls = spec.items ? spec.items.map((it) => it.url) : spec.url ? [spec.url] : []
  return makePolicy(urls, spec.hosts, dev)
}

export type SourceStatus = 'idle' | 'loading' | 'ready' | 'failed' | 'ended'

export class Source implements SourceHost {
  readonly id: number
  spec: SourceSpec
  readonly out: GainNode
  readonly env: SourceEnv
  status: SourceStatus = 'idle'
  /** the engine wants it producing audio */
  active = false
  /** performance ms when it was granted a decoder (decoder-type sources) */
  decoderSince = 0
  startedOnce = false
  lateMs: number | null = null
  player: Player | null = null
  policy: HostPolicy
  /** plays through a media element (too long/big to decode) — sticky for this content */
  large = false
  /** consecutive failed attempts, and when the next one may start */
  failures = 0
  retryAt = 0
  private largeBlob: Blob | null = null
  private ctrl = new AbortController()
  private pinned: string | null = null
  private generation = 0
  private disposed = false
  private prefetching = false
  /** one load of this source's content in flight (independent of `status`, which dropPlayer resets) */
  private requesting = false

  constructor(env: SourceEnv, spec: SourceSpec) {
    this.env = env
    this.spec = spec
    this.id = spec.id
    this.policy = policyOf(spec, env.dev)
    this.out = env.ctx.createGain()
    this.out.gain.value = spec.volume
    this.out.connect(env.keepAlive)
  }

  get signal(): AbortSignal {
    return this.ctrl.signal
  }

  loops(): boolean {
    return this.spec.type === 'loop' || this.spec.loop
  }

  /** Needs a decoder slot: streams, timelines, untrusted clips/loops and those too long/big for a buffer. */
  isDecoder(): boolean {
    const t = this.spec.type
    if (t === 'stream' || t === 'timeline' || this.large) return true
    if (t !== 'clip' && t !== 'loop') return false
    return !this.spec.trusted || (!!this.spec.url && this.env.loader.isLarge(this.spec.url))
  }

  /** Can feed a real voice. */
  usable(): boolean {
    return this.spec.type !== 'voice' && this.status !== 'failed' && this.status !== 'ended'
  }

  markReady(): void {
    if (this.status === 'loading' || this.status === 'idle') this.status = 'ready'
    this.failures = 0
  }

  markEnded(): void {
    this.status = 'ended'
  }

  fail(code: AudioErrorCode): void {
    this.status = 'failed'
    this.env.report(this.id, code)
    this.dropPlayer(FADE.stop)
  }

  /** A failed attempt: retry with backoff (reported once per streak), give up after MAX_RETRIES. */
  private failed(code: AudioErrorCode): void {
    this.failures++
    if (this.failures > RETRY.max) {
      this.fail(code)
      return
    }
    if (this.failures === 1) this.env.report(this.id, code)
    this.retryAt = this.env.now() + backoffMs(this.failures - 1)
    this.status = 'idle'
  }

  setActive(on: boolean): void {
    if (on === this.active) return
    this.active = on
    if (on) {
      this.ensurePlayer()
      if (this.player) this.player.start()
    } else {
      // everything goes: a decoder its slot, a buffer player its buffer and pin (the buffer stays in
      // the LRU, so coming back is a cache hit — or a fetch if the budget needed the room)
      this.dropPlayer(FADE.stop)
    }
  }

  private ensurePlayer(): void {
    if (this.player || this.disposed || this.requesting || !this.usable() || this.status === 'loading') return
    if (this.env.now() < this.retryAt) return
    const spec = this.spec
    if (spec.type === 'timeline') {
      this.player = new TimelinePlayer(this)
      this.status = 'ready'
      return
    }
    if (spec.type === 'stream') {
      this.player = new StreamPlayer(this)
      this.status = 'loading'
      return
    }
    const url = spec.url as string
    if (!spec.trusted) {
      // content an attacker may control: its bytes never reach decodeAudioData
      this.player = new ElementPlayer(this, null, url)
      this.status = 'ready'
      return
    }
    if (this.large || this.env.loader.isLarge(url)) {
      this.large = true
      this.player = new ElementPlayer(this, this.largeBlob, url)
      this.status = 'ready'
      return
    }
    const gen = this.generation
    this.status = 'loading'
    this.requesting = true
    this.env.loader.get(url, this.policy, this.signal).then(
      (res) => {
        this.requesting = false
        if (this.disposed || gen !== this.generation) return
        if (this.status === 'loading') this.status = 'idle'
        if (res.kind === 'element') {
          // too long/big for a buffer: from now on it needs a decoder slot, granted by the mixer
          this.large = true
          this.largeBlob = res.blob
          this.active = false
          return
        }
        this.failures = 0
        // deactivated meanwhile: the buffer just stays in the LRU (a later activation is a cache hit)
        if (!this.active || this.player || !this.env.loader.cache.pin(url)) return
        this.pinned = url
        this.player = new BufferPlayer(this, res.buffer)
        this.status = 'ready'
        this.player.start()
      },
      (err: unknown) => {
        this.requesting = false
        if (this.disposed || gen !== this.generation) return
        if (this.status === 'loading') this.status = 'idle'
        const code = loadCode(err)
        if (code === 'aborted') return
        if (code === 'fetch_failed') this.failed(code)
        else this.fail(code)
      },
    )
  }

  /** Download + decode a clip while it is still inaudible (an emitter within range + margin). */
  prefetch(): void {
    const spec = this.spec
    if (this.disposed || this.player || this.prefetching || this.status !== 'idle' || this.large || !this.spec.trusted) return
    if ((spec.type !== 'clip' && spec.type !== 'loop') || !spec.url || this.env.now() < this.retryAt) return
    const url = spec.url
    if (this.env.loader.cache.has(url) || this.env.loader.isLarge(url)) return
    this.prefetching = true
    const gen = this.generation
    this.env.loader.get(url, this.policy, this.signal).then(
      (res) => {
        this.prefetching = false
        if (this.disposed || gen !== this.generation || res.kind !== 'element') return
        this.large = true
        this.largeBlob = res.blob
      },
      () => {
        // the real activation fetches again and reports what goes wrong
        this.prefetching = false
      },
    )
  }

  private dropPlayer(fadeMs: number): void {
    const p = this.player
    this.player = null
    if (p) {
      p.stop(fadeMs)
      p.dispose()
    }
    if (this.pinned) {
      this.env.loader.cache.unpin(this.pinned)
      this.pinned = null
    }
    if (this.status === 'ready' || this.status === 'loading') this.status = 'idle'
  }

  /** A newer `audio:source` for the same id. */
  update(next: SourceSpec): void {
    const prev = this.spec
    this.spec = next
    if (next.volume !== prev.volume) rampTo(this.out.gain, next.volume, this.env.ctx.currentTime, FADE.edge / 1000)
    if (JSON.stringify(next.hosts) !== JSON.stringify(prev.hosts)) this.policy = policyOf(next, this.env.dev)
    const content = next.type !== prev.type || next.url !== prev.url || next.kind !== prev.kind
      || next.trusted !== prev.trusted || JSON.stringify(next.items) !== JSON.stringify(prev.items)
    if (content) {
      // new content: stop every download of the old one, forget its verdicts and failures
      this.generation++
      this.ctrl.abort()
      this.ctrl = new AbortController()
      this.dropPlayer(FADE.lod)
      this.policy = policyOf(next, this.env.dev)
      this.status = 'idle'
      this.startedOnce = false
      this.large = false
      this.largeBlob = null
      this.failures = 0
      this.retryAt = 0
      if (this.active) {
        this.ensurePlayer()
        if (this.player) this.player.start()
      }
      return
    }
    const clock = next.t0 !== prev.t0 || next.rate !== prev.rate || next.paused !== prev.paused
      || next.pausedAt !== prev.pausedAt || next.offset !== prev.offset || next.loop !== prev.loop
    if (!clock) return
    // a new t0 is a new play (a re-triggered clip gets the one-shot rule again)
    if (next.t0 !== prev.t0) this.startedOnce = false
    // a clock update revives what failed or ended (the server says "play this now")
    if (this.status === 'failed') {
      this.failures = 0
      this.retryAt = 0
      this.status = 'idle'
    }
    if (this.status === 'ended' && !next.paused) this.status = this.player ? 'ready' : 'idle'
    if (this.player) {
      if (next.paused) this.player.stop(FADE.edge)
      else if (prev.paused) this.player.start()
      else this.player.resync()
    }
  }

  tick(now: number): void {
    const p = this.player
    if (p && this.active) {
      p.tick(now)
      // a buffer node waits for the clock (and for t0) — start() is idempotent; the player may have
      // failed inside its own tick, so read `this.player` again
      const q = this.player
      if (q && !q.decoder) q.start()
    } else if (!p && this.active && this.status === 'idle') {
      // a retry that has waited out its backoff, or a buffer that was evicted before it was pinned
      this.ensurePlayer()
      if (this.player) this.player.start()
    }
  }

  dispose(fadeMs: number): void {
    this.disposed = true
    this.active = false
    this.ctrl.abort()
    this.dropPlayer(fadeMs)
    rampTo(this.out.gain, 0, this.env.ctx.currentTime, fadeMs / 1000)
    this.env.setTimeout(() => {
      try {
        this.out.disconnect()
      } catch (err) {
        /* already */
      }
    }, fadeMs + 80)
  }

  stats(): Record<string, unknown> {
    const d = this.player ? this.player.drift() : null
    return {
      id: this.id,
      type: this.spec.type,
      status: this.status,
      active: this.active,
      decoder: this.isDecoder(),
      large: this.large,
      failures: this.failures,
      errMs: d ? Math.round(d.err * 1000) : null,
      rate: d ? Number(d.rate.toFixed(4)) : null,
      locked: d ? d.locked : null,
    }
  }
}
