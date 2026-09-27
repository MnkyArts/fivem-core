// core UI — audio engine: Icecast MP3 through fetch + ICY demux + MSE (DESIGN §55.16; R6 §5.2, §9.2).
//
// One connection gives audio, in-band titles and exact knowledge of what is buffered (measured in
// Chromium 103: playable 538 ms after the request). ICY framing: after every `icy-metaint` audio
// bytes comes ONE length byte L, then L × 16 bytes of metadata (`StreamTitle='…';` NUL-padded);
// L = 0 means "no metadata this time". Network chunks cut that framing anywhere, so the demuxer is a
// byte-level state machine that survives any split. MSE data is never CORS-tainted (R2 §A5).
//
// Live alignment (R6 §5.2): every listener receives the same byte at ≈ the same wall time, so
// holding the buffer level at L = 3 s (playbackRate 0.98–1.02, pitch preserved) keeps clients within
// a few hundred ms; more than L + 12 s ahead (beyond what paced reads allow) jumps back to the live
// edge behind a gain dip.
// Reconnect: backoff 1, 2, 4, 8, 16, 30 s; 30 s of healthy flow resets it. The SourceBuffer is kept
// across reconnects (`sequence` mode appends continue); a broken MediaSource is re-attached.
// Reads are PACED (never more than 256 KB queued or target + 5 s buffered, and never faster than
// 48 KB/s after a 128 KB burst — MP3 tops out at 40 KB/s — even if `buffered` lags), so a "stream"
// that is really a file plays in real time instead of being downloaded at line rate. A read (or a connect)
// that hangs for 10 s — Icecast keeps a listener's socket open when its source drops — and a media
// error (after which every append throws) both rebuild the MediaSource and reconnect.

import type { AudioErrorCode } from './types.ts'
import type { HostPolicy } from './net.ts'

// ---------------------------------------------------------------- the demuxer (pure)

export class IcyDemuxer {
  readonly metaint: number
  private toMeta: number
  /** -1 = not inside a metadata block */
  private metaLeft = -1
  private meta: Uint8Array | null = null
  private metaPos = 0
  audioBytes = 0
  metaBlocks = 0

  constructor(metaint: number) {
    this.metaint = metaint > 0 ? Math.floor(metaint) : 0
    this.toMeta = this.metaint
  }

  /** Feeds one network chunk. `onAudio` receives SUBARRAYS of `chunk` — copy what you keep. */
  push(chunk: Uint8Array, onAudio: (bytes: Uint8Array) => void, onMeta?: (text: string) => void): void {
    const n = chunk.length
    if (!this.metaint) {
      if (n) {
        this.audioBytes += n
        onAudio(chunk)
      }
      return
    }
    let i = 0
    while (i < n) {
      if (this.metaLeft > 0 && this.meta) {
        const take = Math.min(this.metaLeft, n - i)
        this.meta.set(chunk.subarray(i, i + take), this.metaPos)
        this.metaPos += take
        this.metaLeft -= take
        i += take
        if (this.metaLeft === 0) {
          const block = this.meta
          this.meta = null
          this.metaLeft = -1
          this.toMeta = this.metaint
          this.metaBlocks++
          if (onMeta) onMeta(decodeMeta(block))
        }
        continue
      }
      if (this.toMeta === 0) {
        const len = chunk[i] * 16
        i++
        if (len === 0) this.toMeta = this.metaint
        else {
          this.metaLeft = len
          this.meta = new Uint8Array(len)
          this.metaPos = 0
        }
        continue
      }
      const take = Math.min(this.toMeta, n - i)
      this.audioBytes += take
      onAudio(chunk.subarray(i, i + take))
      this.toMeta -= take
      i += take
    }
  }
}

/** Metadata bytes → text: NUL padding stripped, UTF-8 when valid, else Latin-1. */
export function decodeMeta(bytes: Uint8Array): string {
  let end = bytes.length
  while (end > 0 && bytes[end - 1] === 0) end--
  const view = bytes.subarray(0, end)
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(view)
  } catch (err) {
    return new TextDecoder('latin1').decode(view)
  }
}

/** `StreamTitle='…';` → the title (apostrophes inside the title survive: the end is `';`). */
export function parseStreamTitle(meta: string): string | null {
  const key = "StreamTitle='"
  const start = meta.indexOf(key)
  if (start === -1) return null
  const from = start + key.length
  let end = meta.indexOf("';", from)
  if (end === -1) end = meta.lastIndexOf("'")
  if (end < from) return null
  return meta.slice(from, end)
}

/** Reconnect delay: 1, 2, 4, 8, 16, then 30 s. */
export function backoffMs(attempt: number): number {
  return Math.min(30000, 1000 * Math.pow(2, Math.max(0, Math.min(5, attempt))))
}

// ---------------------------------------------------------------- the streamer

export interface IcyEnv {
  fetch: typeof fetch
  MediaSource: typeof MediaSource
  createObjectURL(o: MediaSource): string
  revokeObjectURL(u: string): void
  now(): number
  setTimeout(fn: () => void, ms: number): unknown
  clearTimeout(h: unknown): void
  /** true in the CEF (web security off: every response header is readable) */
  trustHeaders: boolean
  /** the host rule, applied to the final URL after redirects */
  policy: HostPolicy
}

export interface IcyHandlers {
  /** enough is buffered — the element was told to play */
  onPlayable(): void
  onError(code: AudioErrorCode): void
  onTitle?(title: string): void
  /** jump to `seconds` behind a gain dip (the owner's gate) */
  seek(seconds: number): void
}

export const ICY = {
  startAhead: 1.0, target: 3.0, band: 0.5, jumpAbove: 12.0, backKeep: 30, backTrimTo: 10,
  maxQueue: 2 * 1024 * 1024, maxAppend: 256 * 1024, healthyMs: 30000,
  /** backpressure: read no further while this much is queued or buffered beyond the target */
  maxQueued: 256 * 1024, aheadSlack: 5,
  /** and never faster than this per connection (bytes/s after a burst): 320 kbps MP3 is 40 KB/s */
  maxRate: 48 * 1024, burst: 128 * 1024,
  /** a connect or a read that waits this long = the connection went quiet */
  stallMs: 10000,
} as const

export class IcyStream {
  readonly url: string
  readonly el: HTMLAudioElement
  bytes = 0
  reconnects = 0
  title: string | null = null
  started = false
  private env: IcyEnv
  private h: IcyHandlers
  private ms: MediaSource | null = null
  private sb: SourceBuffer | null = null
  private objectUrl: string | null = null
  private ctrl: AbortController | null = null
  private queue: Uint8Array[] = []
  private queued = 0
  private attempt = 0
  private retry: unknown = null
  private stopped = false
  private flowingSince = 0
  private withMeta = true
  /** when the pending connect/read started (0 = not waiting on the network) */
  private waitingSince = 0
  private waiter: (() => void) | null = null
  /** bytes read on this connection and since when (the rate budget) */
  private connBytes = 0
  private connStart = 0
  private failReported = false
  private mediaReported = false

  constructor(env: IcyEnv, url: string, el: HTMLAudioElement, handlers: IcyHandlers) {
    this.env = env
    this.url = url
    this.el = el
    this.h = handlers
  }

  start(): void {
    this.stopped = false
    this.attach()
    void this.connect()
  }

  /** Buffered seconds ahead of the play position. */
  ahead(): number {
    const b = this.el.buffered
    if (!b || !b.length) return 0
    return Math.max(0, b.end(b.length - 1) - this.el.currentTime)
  }

  private attach(): void {
    this.detachSource()
    const ms = new this.env.MediaSource()
    this.ms = ms
    this.objectUrl = this.env.createObjectURL(ms)
    ms.addEventListener('sourceopen', () => {
      if (this.ms !== ms || this.stopped) return
      try {
        const sb = ms.addSourceBuffer('audio/mpeg')
        sb.mode = 'sequence'
        sb.addEventListener('updateend', () => {
          this.pump()
          this.wake()
        })
        this.sb = sb
        this.pump()
      } catch (err) {
        this.recover('media_error')
      }
    }, { once: true })
    this.el.src = this.objectUrl
  }

  private detachSource(): void {
    this.sb = null
    this.ms = null
    if (this.objectUrl) {
      this.env.revokeObjectURL(this.objectUrl)
      this.objectUrl = null
    }
  }

  /** Backpressure: resolves once less than 256 KB is queued and ≤ target + 5 s is buffered ahead. */
  private hasRoom(): boolean {
    if (this.stopped) return true
    const budget = ICY.burst + (ICY.maxRate * (this.env.now() - this.connStart)) / 1000
    return this.queued <= ICY.maxQueued && this.ahead() <= ICY.target + ICY.aheadSlack && this.connBytes <= budget
  }

  private room(): Promise<void> {
    if (this.hasRoom()) return Promise.resolve()
    return new Promise<void>((resolve) => { this.waiter = resolve })
  }

  private wake(): void {
    const w = this.waiter
    if (w && this.hasRoom()) {
      this.waiter = null
      w()
    }
  }

  private async connect(): Promise<void> {
    if (this.stopped) return
    if (!this.env.policy.allows(this.url)) {
      this.refuse()
      return
    }
    const ctrl = new AbortController()
    this.ctrl = ctrl
    this.waitingSince = this.env.now()
    let res: Response
    try {
      res = await this.open(ctrl)
    } catch (err) {
      this.waitingSince = 0
      if (!this.stopped && this.ctrl === ctrl) this.reconnect()
      return
    }
    this.waitingSince = 0
    if (this.stopped || this.ctrl !== ctrl) {
      ctrl.abort()
      return
    }
    // the host rule on the FINAL url: a redirect must not lead to a host the server never validated
    if (!this.env.policy.allows(res.url || this.url)) {
      ctrl.abort()
      this.refuse()
      return
    }
    const header = res.headers.get('icy-metaint')
    const metaint = header ? parseInt(header, 10) || 0 : 0
    if (this.withMeta && !header && !this.env.trustHeaders) {
      // A browser may hide the header while the server still interleaves metadata into the audio:
      // never feed that to the decoder — go again without asking for metadata.
      this.withMeta = false
      ctrl.abort()
      if (!this.stopped) void this.connect()
      return
    }
    const demux = new IcyDemuxer(metaint)
    const reader = res.body ? res.body.getReader() : null
    if (!reader) {
      this.reconnect()
      return
    }
    this.flowingSince = this.env.now()
    this.connStart = this.flowingSince
    this.connBytes = 0
    try {
      for (;;) {
        // paced: a file behind a stream URL (or a bursting host) plays in real time, it is not
        // downloaded at line rate and then skipped through
        await this.room()
        if (this.stopped || this.ctrl !== ctrl) break
        this.waitingSince = this.env.now()
        const { value, done } = await reader.read()
        this.waitingSince = 0
        if (done || this.stopped || this.ctrl !== ctrl) break
        if (!value || !value.length) continue
        this.connBytes += value.length
        demux.push(value, (bytes) => this.enqueue(bytes), (text) => {
          const t = parseStreamTitle(text)
          if (t !== null && t !== this.title) {
            this.title = t
            if (this.h.onTitle) this.h.onTitle(t)
          }
        })
        if (this.attempt && this.env.now() - this.flowingSince > ICY.healthyMs) {
          this.attempt = 0
          this.failReported = false
          this.mediaReported = false
        }
        this.pump()
      }
    } catch (err) {
      /* the stream broke or was aborted — reconnect below when it is still ours */
    }
    this.waitingSince = 0
    // cancelling an errored/aborted body rejects (it never throws): a bare call would surface as an
    // unhandled rejection in the shell's error reporter
    reader.cancel().catch(() => { /* already closed */ })
    if (!this.stopped && this.ctrl === ctrl) this.reconnect()
  }

  private open(ctrl: AbortController): Promise<Response> {
    const go = (meta: boolean): Promise<Response> => this.env.fetch(this.url, {
      signal: ctrl.signal,
      cache: 'no-store',
      credentials: 'omit',
      headers: meta ? { 'Icy-MetaData': '1' } : undefined,
    }).then((res) => {
      if (!res.ok) throw new Error('HTTP ' + res.status)
      return res
    })
    if (!this.withMeta) return go(false)
    return go(true).catch((err: unknown) => {
      // a custom header costs a CORS preflight outside the CEF; retry plain once (inside the CEF a
      // TypeError is a real network failure and the normal backoff handles it)
      if (ctrl.signal.aborted || this.env.trustHeaders || !(err instanceof TypeError)) throw err
      this.withMeta = false
      return go(false)
    })
  }

  /** A host the rule refuses: reported, never retried. */
  private refuse(): void {
    this.stopped = true
    this.h.onError('bad_url')
  }

  private reconnect(): void {
    if (this.stopped || this.retry !== null) return
    this.ctrl = null
    const delay = backoffMs(this.attempt++)
    this.reconnects++
    if (this.attempt >= 3 && !this.failReported) {
      this.failReported = true
      this.h.onError('stream_failed')
    }
    this.retry = this.env.setTimeout(() => {
      this.retry = null
      if (this.stopped) return
      if (!this.ms || this.ms.readyState !== 'open' || this.el.error) {
        this.started = false
        this.attach()
      }
      void this.connect()
    }, delay)
  }

  /**
   * The connection went quiet, or the media pipeline broke (after a decode error every append
   * throws): drop the connection and the queue, attach a fresh MediaSource, reconnect with backoff.
   */
  recover(reason: 'stall' | 'media_error'): void {
    if (this.stopped) return
    if (reason === 'media_error' && !this.mediaReported) {
      this.mediaReported = true
      this.h.onError('media_error')
    }
    const ctrl = this.ctrl
    this.ctrl = null
    if (ctrl) ctrl.abort()
    this.waitingSince = 0
    this.queue = []
    this.queued = 0
    this.started = false
    this.attach()
    const w = this.waiter
    this.waiter = null
    if (w) w()
    this.reconnect()
  }

  private enqueue(bytes: Uint8Array): void {
    this.bytes += bytes.length
    this.queue.push(bytes.slice())
    this.queued += bytes.length
    while (this.queued > ICY.maxQueue && this.queue.length > 1) {
      const dropped = this.queue.shift() as Uint8Array
      this.queued -= dropped.length
    }
  }

  private pump(): void {
    const sb = this.sb
    if (!sb || sb.updating || !this.queue.length || this.stopped) return
    if (this.el.error) {
      this.recover('media_error')
      return
    }
    let size = 0
    let count = 0
    while (count < this.queue.length && (count === 0 || size + this.queue[count].length <= ICY.maxAppend)) {
      size += this.queue[count].length
      count++
    }
    const buf = new Uint8Array(size)
    let at = 0
    for (let i = 0; i < count; i++) {
      buf.set(this.queue[i], at)
      at += this.queue[i].length
    }
    try {
      sb.appendBuffer(buf)
      this.queue.splice(0, count)
      this.queued -= size
    } catch (err) {
      // QuotaExceeded: drop what was played and try again after that remove() finishes; anything
      // else (InvalidStateError) means the MediaSource or the element is broken
      if (err && (err as { name?: string }).name === 'QuotaExceededError') this.trim(2)
      else this.recover('media_error')
    }
  }

  private trim(keepBehind: number): void {
    const sb = this.sb
    const b = this.el.buffered
    if (!sb || sb.updating || !b || !b.length) return
    const cut = this.el.currentTime - keepBehind
    if (cut > b.start(0) + 0.5) {
      try { sb.remove(b.start(0), cut) } catch (err) { /* the next poll tries again */ }
    }
  }

  /** Called by the engine tick (~200 ms): watchdog, start, back-buffer trim, buffer-level alignment. */
  poll(): void {
    if (this.stopped) return
    const now = this.env.now()
    if (this.waitingSince && now - this.waitingSince > ICY.stallMs) {
      this.recover('stall')
      return
    }
    if (this.el.error) {
      this.recover('media_error')
      return
    }
    this.wake()
    const ahead = this.ahead()
    if (!this.started) {
      if (ahead >= ICY.startAhead) {
        this.started = true
        const p = this.el.play()
        if (p && typeof p.catch === 'function') p.catch(() => { /* the owner reports a blocked context */ })
        this.h.onPlayable()
      }
      return
    }
    const b = this.el.buffered
    if (b && b.length && this.el.currentTime - b.start(0) > ICY.backKeep) this.trim(ICY.backTrimTo)
    if (ahead > ICY.target + ICY.jumpAbove && b && b.length) {
      this.h.seek(b.end(b.length - 1) - ICY.target)
      return
    }
    let rate = 1
    if (ahead > ICY.target + ICY.band) rate = 1 + Math.min(0.02, (ahead - ICY.target) * 0.01)
    else if (ahead < ICY.target - ICY.band && ahead > 0.3) rate = 1 - Math.min(0.02, (ICY.target - ahead) * 0.01)
    if (Math.abs(this.el.playbackRate - rate) > 0.001) this.el.playbackRate = rate
  }

  stop(): void {
    this.stopped = true
    if (this.retry !== null) {
      this.env.clearTimeout(this.retry)
      this.retry = null
    }
    if (this.ctrl) {
      this.ctrl.abort()
      this.ctrl = null
    }
    const w = this.waiter
    this.waiter = null
    if (w) w()
    this.queue = []
    this.queued = 0
    this.detachSource()
    try {
      this.el.pause()
      this.el.removeAttribute('src')
      this.el.load()
    } catch (err) { /* the element is gone */ }
  }
}
