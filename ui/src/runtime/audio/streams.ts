// core UI — audio engine: live streams (DESIGN §55.16; R6 §5, §9.2).
//
//   MP3 Icecast        → IcyStream (fetch + ICY demux + MSE `audio/mpeg`, in-band titles, buffer-level
//                        alignment at 3 s, paced reads, its own stall watchdog) when MSE takes audio/mpeg
//   HLS (m3u8)         → hls.js/light, imported lazily as its own chunk; main-thread transmux (the ESM
//                        build has no inline worker — audio-only is cheap). Its loader is wrapped by the
//                        host rule, so variant playlists, segments and keys (and their redirects) can
//                        only come from hosts the server allowed
//   everything else    → <audio src> (Ogg/Opus/Vorbis, MP3 without MSE) on the URL's checked FINAL
//                        address (the element would follow redirects invisibly)
// A break (error, 10 s without progress) reloads at the live edge with backoff 1–30 s; 5 s of progress
// after a reload ends the streak (the backoff starts over, `stream_failed` is reported again only for a
// new streak of 3). A fresh element per start: a paused live element would resume from stale data.

import type { AudioErrorCode } from './types.ts'
import { FADE } from './types.ts'
import type { Player, SourceHost } from './sources.ts'
import { rampTo } from './spatial.ts'
import { ICY, IcyStream, backoffMs } from './icy.ts'
import { play, unwire, wire } from './deck.ts'
import type { Wired } from './deck.ts'
import { loadCode, resolveMedia } from './net.ts'
import type { HostPolicy } from './net.ts'
import type { HlsCtor, HlsErrorData, HlsLike } from './media.ts'

const STALL_MS = 10000
/** Progress after a reload that ends a failure streak. */
const HEALTHY_MS = 5000

interface LoaderLike {
  load: (context: { url: string }, config: unknown, callbacks: LoaderCallbacks) => void
  abort(): void
  destroy(): void
  stats: unknown
  context: unknown
}
interface LoaderCallbacks {
  onSuccess(response: { url?: string }, stats: unknown, context: unknown, details: unknown): void
  onError(error: { code: number; text: string }, context: unknown, details: unknown, stats: unknown): void
  [key: string]: unknown
}
type LoaderCtor = new (config: unknown) => LoaderLike

/**
 * hls.js loads master/variant playlists, segments and keys through `config.loader`: this wrapper
 * refuses every URL — and every redirect target (`response.url`) — the host rule does not allow.
 */
export function guardLoader(Base: LoaderCtor, policy: HostPolicy, onRefuse: () => void): LoaderCtor {
  return function GuardedLoader(config: unknown): LoaderLike {
    const inner = new Base(config)
    return {
      get stats() { return inner.stats },
      get context() { return inner.context },
      abort: () => inner.abort(),
      destroy: () => inner.destroy(),
      load: (context, cfg, callbacks) => {
        if (!policy.allows(context.url)) {
          onRefuse()
          callbacks.onError({ code: 0, text: 'host not allowed' }, context, null, inner.stats)
          return
        }
        inner.load(context, cfg, Object.assign({}, callbacks, {
          onSuccess(response: { url?: string }, stats: unknown, ctx: unknown, details: unknown) {
            if (response && response.url && !policy.allows(response.url)) {
              onRefuse()
              callbacks.onError({ code: 0, text: 'redirected to a host that is not allowed' }, ctx, details, stats)
              return
            }
            callbacks.onSuccess(response, stats, ctx, details)
          },
        }))
      },
    }
  } as unknown as LoaderCtor
}

export class StreamPlayer implements Player {
  readonly decoder = true
  title: string | null = null
  private host: SourceHost
  private w: Wired | null = null
  private icy: IcyStream | null = null
  private hls: HlsLike | null = null
  private mode: 'icy' | 'element' | 'hls' = 'element'
  private retry: unknown = null
  private attempt = 0
  private reported = false
  private started = false
  private recovered = false
  private refused = false
  private lastT = -1
  private lastMoveAt = 0
  private healthyFrom = 0
  private run = 0
  private offs: Array<() => void> = []

  constructor(host: SourceHost) {
    this.host = host
  }

  start(): void {
    if (this.w) return
    const env = this.host.env
    const spec = this.host.spec
    const url = spec.url as string
    const w = wire(env, this.host.out, false)
    this.w = w
    this.lastMoveAt = env.now()
    const listen = (type: string, fn: () => void): void => {
      w.el.addEventListener(type, fn)
      this.offs.push(() => w.el.removeEventListener(type, fn))
    }
    listen('playing', () => this.playable())
    listen('error', () => {
      if (this.icy) this.icy.recover('media_error')
      else this.broken()
    })
    const MS = env.MediaSource
    if (spec.kind === 'mp3' && MS && typeof MS.isTypeSupported === 'function' && MS.isTypeSupported('audio/mpeg')) {
      this.mode = 'icy'
      this.icy = new IcyStream({
        fetch: env.fetch, MediaSource: MS, createObjectURL: (o) => env.createObjectURL(o),
        revokeObjectURL: (u) => env.revokeObjectURL(u), now: () => env.now(),
        setTimeout: (fn, ms) => env.setTimeout(fn, ms), clearTimeout: (h) => env.clearTimeout(h),
        trustHeaders: env.trustHeaders, policy: this.host.policy,
      }, url, w.el, {
        onPlayable: () => this.playable(),
        onError: (code) => this.fail(code),
        onTitle: (t) => { this.title = t },
        seek: (s) => this.jump(s),
      })
      this.icy.start()
      return
    }
    if (spec.kind === 'hls') {
      this.mode = 'hls'
      void this.startHls(url)
      return
    }
    this.mode = 'element'
    void this.startElement(url)
  }

  /** A permanent error (bad_url) ends the source; anything else was already retried. */
  private fail(code: AudioErrorCode): void {
    if (code === 'bad_url') this.host.fail(code)
    else this.host.env.report(this.host.id, code)
  }

  private async startElement(url: string): Promise<void> {
    const w = this.w
    const run = ++this.run
    let final: string
    try {
      final = await resolveMedia(this.host.env, url, this.host.policy, this.host.signal)
    } catch (err) {
      const code = loadCode(err)
      if (this.w !== w || run !== this.run || code === 'aborted') return
      if (code === 'bad_url') this.host.fail(code)
      else this.broken()
      return
    }
    if (!w || this.w !== w || run !== this.run) return
    w.el.src = final
    play(w.el)
  }

  private async startHls(url: string): Promise<void> {
    const env = this.host.env
    let Hls: HlsCtor
    try {
      Hls = await env.importHls()
    } catch (err) {
      this.host.fail('hls_failed')
      return
    }
    const w = this.w
    if (!w) return
    if (!Hls.isSupported()) {
      this.host.fail('unsupported')
      return
    }
    const base = Hls.DefaultConfig ? Hls.DefaultConfig.loader : undefined
    if (typeof base !== 'function' || !this.host.policy.allows(url)) {
      // without the loader hook the host rule could not be enforced for segments and keys
      this.host.fail(typeof base !== 'function' ? 'unsupported' : 'bad_url')
      return
    }
    // ESM hls.js has no inline worker: transmux on the main thread (audio-only is cheap)
    const hls = new Hls({
      enableWorker: false, lowLatencyMode: true, backBufferLength: 30, maxBufferLength: 30, liveSyncDurationCount: 3,
      loader: guardLoader(base as LoaderCtor, this.host.policy, () => { this.refused = true }),
    })
    this.hls = hls
    hls.on(Hls.Events.ERROR, (_ev: string, data: HlsErrorData) => {
      if (!data || this.hls !== hls) return
      if (this.refused) {
        // a playlist, segment or key on a host the server did not allow: never retried
        env.setTimeout(() => this.host.fail('bad_url'), 0)
        return
      }
      if (!data.fatal) return
      if (data.type === Hls.ErrorTypes.MEDIA_ERROR && !this.recovered) {
        this.recovered = true
        hls.recoverMediaError()
        return
      }
      this.broken()
    })
    hls.on(Hls.Events.MANIFEST_PARSED, () => play(w.el))
    hls.attachMedia(w.el)
    hls.loadSource(url)
  }

  private playable(): void {
    if (!this.w) return
    this.healthyFrom = this.host.env.now()
    if (this.started) return
    this.started = true
    this.host.markReady()
    rampTo(this.w.gate.gain, 1, this.host.env.ctx.currentTime, (FADE.edge * 2) / 1000)
  }

  private jump(seconds: number): void {
    const w = this.w
    if (!w) return
    const env = this.host.env
    rampTo(w.gate.gain, 0, env.ctx.currentTime, FADE.dip / 1000)
    env.setTimeout(() => {
      if (this.w !== w) return
      try { w.el.currentTime = seconds } catch (err) { /* not seekable yet */ }
      rampTo(w.gate.gain, 1, env.ctx.currentTime, (FADE.dip * 2) / 1000)
    }, FADE.dip)
  }

  /** Element/HLS failure or stall: reload to the live edge with backoff 1–30 s. */
  private broken(): void {
    if (this.retry !== null || !this.w || this.refused) return
    const env = this.host.env
    const delay = backoffMs(this.attempt++)
    this.healthyFrom = 0
    if (this.attempt >= 3 && !this.reported) {
      this.reported = true
      env.report(this.host.id, 'stream_failed')
    }
    this.retry = env.setTimeout(() => {
      this.retry = null
      const w = this.w
      if (!w) return
      this.lastMoveAt = env.now()
      this.recovered = false
      const url = this.host.spec.url as string
      if (this.mode === 'hls') {
        if (this.hls) this.hls.destroy()
        this.hls = null
        void this.startHls(url)
      } else void this.startElement(url)
    }, delay)
  }

  tick(now: number): void {
    const w = this.w
    if (!w) return
    if (this.icy) {
      this.icy.poll()
      return
    }
    const t = w.el.currentTime
    if (t !== this.lastT) {
      this.lastT = t
      this.lastMoveAt = now
    } else if (now - this.lastMoveAt > STALL_MS) {
      this.lastMoveAt = now
      this.broken()
      return
    }
    // a reload that plays for 5 s ends the streak: the next hiccup waits 1 s again
    if (this.attempt && this.healthyFrom && now - this.healthyFrom >= HEALTHY_MS && now - this.lastMoveAt < 1000) {
      this.attempt = 0
      this.reported = false
    }
  }

  stop(fadeMs: number): void {
    const w = this.w
    if (!w) return
    const env = this.host.env
    this.w = null
    this.run++
    this.started = false
    if (this.retry !== null) {
      env.clearTimeout(this.retry)
      this.retry = null
    }
    for (const off of this.offs) off()
    this.offs = []
    rampTo(w.gate.gain, 0, env.ctx.currentTime, fadeMs / 1000)
    const icy = this.icy
    const hls = this.hls
    this.icy = null
    this.hls = null
    // the element stops only after the gate's fade (a cut would click)
    env.setTimeout(() => {
      if (icy) icy.stop()
      if (hls) hls.destroy()
      unwire(w, null, env)
    }, fadeMs + 30)
  }

  resync(): void { /* live: no clock */ }

  dispose(): void {
    this.stop(FADE.stop)
  }

  drift(): { err: number; rate: number; locked: boolean } | null {
    if (!this.w) return null
    const ahead = this.icy ? this.icy.ahead() - ICY.target : 0
    return { err: ahead, rate: this.w.el.playbackRate, locked: this.started }
  }
}
