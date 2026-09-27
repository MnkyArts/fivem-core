// core UI — audio engine: media-element players (DESIGN §55.16; R6 §4.4–§4.5, §9.3).
//
//   ElementPlayer   a clip/loop that is untrusted or too long/big to decode (loader.ts): the bytes we
//                   already hold as a blob, else the URL (resource files are fetched whole by the
//                   deck); the element loops natively. A one-shot the page heard of in time starts
//                   from its top at once (exactly at t0 when that is ahead) with its gate open — a
//                   short sound would be over before a drift lock; the page's own loading delays it
//                   instead of eating its attack. One joined in progress seeks to the clock like a
//                   timeline. It ends when the ELEMENT ends (never replayed; `duration` is a guess on
//                   hosts without Range).
//   TimelinePlayer  items back to back on the clock; the next item is preloaded 15 s ahead and
//                   switched at the exact boundary; a start at t0 plays from a held element; an item
//                   shorter than its declared duration waits silently for its boundary
// Both retry a broken deck (media error, stalled, never loaded) with backoff 1, 2, 4, 8 s — reported
// once per streak — and give the source up after RETRY.max consecutive failures; 10 s of locked
// playback ends a streak. Live streams are streams.ts; the deck itself is deck.ts.

import type { AudioErrorCode } from './types.ts'
import { FADE, RETRY } from './types.ts'
import type { Player, SourceHost } from './sources.ts'
import { timelineAt } from './sync.ts'
import type { TimelinePos } from './sync.ts'
import { backoffMs } from './icy.ts'
import { Deck } from './deck.ts'

const PRELOAD_MS = 15000

export interface HlsErrorData {
  fatal?: boolean
  type?: string
  details?: string
}
/** The slice of hls.js the engine uses (hls.js/light, imported lazily as its own chunk). */
export interface HlsLike {
  loadSource(url: string): void
  attachMedia(media: HTMLMediaElement): void
  on(event: string, fn: (event: string, data: HlsErrorData) => void): void
  recoverMediaError(): void
  destroy(): void
}
export interface HlsCtor {
  new (config?: Record<string, unknown>): HlsLike
  isSupported(): boolean
  readonly Events: { readonly ERROR: string; readonly MANIFEST_PARSED: string }
  readonly ErrorTypes: { readonly NETWORK_ERROR: string; readonly MEDIA_ERROR: string }
  /** hls.js's default config: its `loader` is wrapped by the host rule (streams.ts) */
  readonly DefaultConfig?: { loader?: unknown }
}

/** A failure streak with backoff (shared by the element and timeline players). */
class Streak {
  failures = 0
  retryAt = 0
  private okSince = 0

  /** Returns true when the caller should give up; otherwise schedules the next attempt. */
  fail(host: SourceHost, code: AudioErrorCode, now: number): boolean {
    if (code === 'bad_url' || code === 'too_large') return true
    this.failures++
    if (this.failures > RETRY.max) return true
    if (this.failures === 1) host.env.report(host.id, code)
    this.retryAt = now + backoffMs(this.failures - 1)
    this.okSince = 0
    return false
  }

  /** Locked playback for RETRY.okMs ends a streak. */
  ok(locked: boolean, now: number): void {
    if (!locked) {
      this.okSince = 0
      return
    }
    if (!this.okSince) this.okSince = now
    else if (this.failures && now - this.okSince >= RETRY.okMs) this.failures = 0
  }
}

// ---------------------------------------------------------------- a long clip/loop

export class ElementPlayer implements Player {
  readonly decoder = true
  private host: SourceHost
  private blob: Blob | null
  private url: string
  private deck: Deck | null = null
  private streak = new Streak()
  private timer: unknown = null

  constructor(host: SourceHost, blob: Blob | null, url: string) {
    this.host = host
    this.blob = blob
    this.url = url
  }

  start(): void {
    if (this.deck || this.host.env.now() < this.streak.retryAt) return
    const deck = new Deck(this.host.env, this.host.out, this.host.loops(), this.host.policy)
    this.deck = deck
    // a one-shot waiting for its element starts the moment it can play, not at the next tick
    deck.onLoad = () => {
      if (this.deck !== deck || deck.joined) return
      try {
        this.tick(this.host.env.now())
      } catch (err) {
        console.error('[core:ui] audio: starting source ' + this.host.id + ' failed', err)
      }
    }
    void deck.open(this.url, this.blob)
  }

  tick(now: number): void {
    const deck = this.deck
    if (!deck) {
      this.start()
      return
    }
    if (deck.errored) {
      this.stop(FADE.stop)
      if (this.streak.fail(this.host, deck.errorCode, now)) this.host.fail(deck.errorCode)
      return
    }
    const spec = this.host.spec
    const head = this.host.env.head(spec)
    const loop = this.host.loops()
    const dur = deck.w.el.duration
    // a loop needs its period; a one-shot only its own end
    if (head === null || (loop && (!(dur > 0) || !Number.isFinite(dur)))) {
      deck.watch(now)
      return
    }
    if (spec.paused) {
      if (deck.joined) deck.pause(FADE.edge)
      return
    }
    if (!loop && deck.atEnd()) {
      // a one-shot that played to its end is over: never restarted by a poll
      this.stop(FADE.edge)
      this.host.markEnded()
      return
    }
    if (!loop && !deck.joined) {
      const late = this.host.lateMs === null ? Math.max(0, head) : Math.max(0, Math.min(head, this.host.lateMs))
      if (late <= 50) {
        if (head < 0) this.boundary(-head)
        if (!deck.loaded) {
          deck.watch(now)
          return
        }
        if (head < 0) {
          deck.hold()
          return
        }
        if (deck.w.el.currentTime < 0.05) {
          deck.setRate(spec.rate)
          deck.launch()
          this.host.startedOnce = true
          return
        }
      }
    }
    if (head < -150) {
      deck.hold()
      return
    }
    this.host.startedOnce = true
    deck.setRate(spec.rate)
    deck.sync(Math.max(0, head) / 1000, loop ? dur : null, now)
    this.streak.ok(deck.ctrl.locked, now)
  }

  /** Run the next tick exactly when a start that is < 400 ms away is due. */
  private boundary(ms: number): void {
    if (ms >= 400 || this.timer !== null) return
    const env = this.host.env
    this.timer = env.setTimeout(() => {
      this.timer = null
      if (this.deck) this.tick(env.now())
    }, Math.max(0, ms))
  }

  stop(fadeMs: number): void {
    if (this.timer !== null) {
      this.host.env.clearTimeout(this.timer)
      this.timer = null
    }
    if (this.deck) this.deck.close(fadeMs)
    this.deck = null
  }

  resync(): void {
    if (this.deck) this.deck.joined = false
  }

  dispose(): void {
    this.stop(FADE.stop)
  }

  drift(): { err: number; rate: number; locked: boolean } | null {
    const d = this.deck
    return d ? { err: d.ctrl.lastError, rate: d.ctrl.rate, locked: d.ctrl.locked } : null
  }
}

// ---------------------------------------------------------------- timelines

interface Slot {
  index: number
  deck: Deck
}

export class TimelinePlayer implements Player {
  readonly decoder = true
  private host: SourceHost
  private cur: Slot | null = null
  private next: Slot | null = null
  private pos: TimelinePos = { state: 0, index: 0, offset: 0, remaining: 0 }
  private started = false
  private timer: unknown = null
  private streak = new Streak()

  constructor(host: SourceHost) {
    this.host = host
  }

  private durations(): number[] {
    const items = this.host.spec.items || []
    return items.map((it) => it.duration)
  }

  /** One looping item plays as a natively looping element (no seek at the wrap). */
  private single(): boolean {
    const items = this.host.spec.items
    return !!items && items.length === 1 && this.host.loops()
  }

  private open(index: number): Slot {
    const items = this.host.spec.items || []
    const deck = new Deck(this.host.env, this.host.out, this.single(), this.host.policy)
    void deck.open(items[index].url, null)
    return { index, deck }
  }

  start(): void {
    this.started = true
    this.tick(this.host.env.now())
  }

  tick(now: number): void {
    if (!this.started) return
    const env = this.host.env
    const spec = this.host.spec
    const items = spec.items
    if (!items || !items.length) return
    if (spec.paused) {
      if (this.cur && this.cur.deck.joined) this.cur.deck.pause(FADE.edge)
      return
    }
    const head = env.head(spec)
    if (head === null) return
    const durations = this.durations()
    const pos = timelineAt(durations, head, this.host.loops(), this.pos)
    if (pos.state === 1) {
      this.teardown(FADE.edge)
      this.host.markEnded()
      return
    }
    if (now < this.streak.retryAt) return
    const index = pos.index
    if (!this.cur || this.cur.index !== index) this.switchTo(index)
    const cur = this.cur as Slot
    const deck = cur.deck
    if (deck.errored) {
      // a CDN blip must not end the set: close the item and open it again after a backoff
      const code = deck.errorCode
      deck.close(FADE.stop)
      this.cur = null
      if (this.streak.fail(this.host, code, now)) {
        this.teardown(FADE.stop)
        this.host.fail(code)
      }
      return
    }
    this.host.markReady()
    deck.setRate(spec.rate)
    const el = deck.w.el
    if (pos.state === -1) {
      deck.hold()
      deck.watch(now)
      this.boundary(-pos.offset)
    } else if (!deck.joined && deck.loaded && el.paused && el.currentTime < 0.05 && pos.offset < 250) {
      // a held element at the top and the clock just reached it: a plain play() is exact
      deck.launch()
    } else {
      deck.sync(pos.offset / 1000, this.single() ? durations[0] / 1000 : null, now)
    }
    this.streak.ok(deck.ctrl.locked, now)
    if (this.single()) return
    const n = items.length
    const nextIndex = index + 1 < n ? index + 1 : (this.host.loops() ? 0 : -1)
    if (nextIndex >= 0 && nextIndex !== index && pos.remaining < PRELOAD_MS && (!this.next || this.next.index !== nextIndex)) {
      if (this.next) this.next.deck.dispose()
      this.next = this.open(nextIndex)
    }
    if (this.next) this.next.deck.hold()
    this.boundary(pos.remaining)
  }

  /** Run the next tick exactly at a boundary that is < 400 ms away. */
  private boundary(ms: number): void {
    if (ms >= 400 || this.timer !== null) return
    const env = this.host.env
    this.timer = env.setTimeout(() => {
      this.timer = null
      if (this.started) this.tick(env.now())
    }, Math.max(0, ms))
  }

  private switchTo(index: number): void {
    const old = this.cur
    if (this.next && this.next.index === index && !this.next.deck.errored) {
      this.cur = this.next
      this.next = null
      this.cur.deck.launch()
    } else this.cur = this.open(index)
    if (old) old.deck.close(FADE.edge)
  }

  private teardown(fadeMs: number): void {
    if (this.cur) this.cur.deck.close(fadeMs)
    if (this.next) this.next.deck.dispose()
    this.cur = null
    this.next = null
    if (this.timer !== null) {
      this.host.env.clearTimeout(this.timer)
      this.timer = null
    }
  }

  stop(fadeMs: number): void {
    this.started = false
    this.teardown(fadeMs)
  }

  resync(): void {
    if (this.cur) this.cur.deck.joined = false
    if (this.started) this.tick(this.host.env.now())
  }

  dispose(): void {
    this.stop(FADE.stop)
  }

  drift(): { err: number; rate: number; locked: boolean } | null {
    const d = this.cur ? this.cur.deck : null
    return d ? { err: d.ctrl.lastError, rate: d.ctrl.rate, locked: d.ctrl.locked } : null
  }
}
