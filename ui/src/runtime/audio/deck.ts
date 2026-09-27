// core UI — audio engine: one media element on the clock (DESIGN §55.16; R6 §1.7, §4.4–§4.5).
//
// A Deck is ONE <audio> wired into the graph (element → MediaElementAudioSourceNode → gate → the
// source's fan-out) plus the §4.5 drift controller: poll currentTime every tick, fit a line, steer
// playbackRate ±2 % (pitch preserved) or re-seek behind a gain dip, and keep the gate shut until the
// first lock. Every element gets crossOrigin = 'anonymous' (a cross-origin redirect then never
// taints, R2 §A5). What can go wrong, and what the deck does about it:
//   * an element that played to its END is never play()ed again (HTML would restart it from 0): the
//     deck holds with the gate shut (`ended`) and its player decides — a clip ends, a timeline waits
//     for its next item. The end is the element's own `ended`, never a comparison with `duration`:
//     from a host without Range support Chromium reports a guessed duration (4 s for a 20 s Ogg)
//   * a natively looping element wraps from `duration` to 0: samples are unwrapped before the fit
//   * resource files (https://cfx-nui-*) come whole into a blob: FiveM's scheme ignores Range; an
//     https host is loaded by its FINAL URL (redirects checked against the host rule first)
//   * seeks that do not land (no Range) or a seek storm (sync.ts): the file is reloaded ONCE into a
//     blob — single flight, capped, aborted with the deck, the previous object URL revoked
//   * no progress for 10 s while it should play, or no `canplay` 15 s after its source was set →
//     `errored`, and the player retries with backoff

import type { AudioErrorCode } from './types.ts'
import { FADE } from './types.ts'
import type { SourceEnv } from './sources.ts'
import { DriftController, TimeFit, mod, wrapError } from './sync.ts'
import { rampTo } from './spatial.ts'
import { FETCH, fetchLimited, loadCode, resolveMedia } from './net.ts'
import type { HostPolicy } from './net.ts'
import { MAX_FETCH_BYTES } from './loader.ts'

/** How much of the first settled error after a join goes into the learned seek lead. */
const LEAD_GAIN = 0.7
/** No progress for this long while the deck should be playing = broken. */
export const STALL_MS = 10000
/** `canplay` must come within this after the element got its source. */
export const OPEN_MS = 15000

export function isNuiFile(url: string): boolean {
  return url.startsWith('https://cfx-nui-')
}

export function play(el: HTMLMediaElement): void {
  try {
    const p = el.play()
    if (p && typeof p.catch === 'function') p.catch(() => { /* paused before it started, or no autoplay */ })
  } catch (err) {
    /* a detached element */
  }
}

export interface Wired {
  el: HTMLAudioElement
  node: MediaElementAudioSourceNode
  gate: GainNode
}

export function wire(env: SourceEnv, out: AudioNode, loop: boolean): Wired {
  const el = env.createAudio()
  el.crossOrigin = 'anonymous'
  el.preload = 'auto'
  el.loop = loop
  el.preservesPitch = true
  const node = env.ctx.createMediaElementSource(el)
  const gate = env.ctx.createGain()
  gate.gain.value = 0
  node.connect(gate)
  gate.connect(out)
  return { el, node, gate }
}

export function unwire(w: Wired, objectUrl: string | null, env: SourceEnv): void {
  try {
    w.el.pause()
    w.el.removeAttribute('src')
    w.el.load()
  } catch (err) { /* gone */ }
  try { w.node.disconnect() } catch (err) { /* already */ }
  try { w.gate.disconnect() } catch (err) { /* already */ }
  if (objectUrl) env.revokeObjectURL(objectUrl)
}

export class Deck {
  readonly w: Wired
  readonly ctrl: DriftController
  readonly fit = new TimeFit()
  loaded = false
  joined = false
  seeking = false
  errored = false
  errorCode: AudioErrorCode = 'media_error'
  /** a non-looping element that played to its end: held, never play()ed again */
  ended = false
  missedSeeks = 0
  /** the element can play (every `canplay`): a player waiting to start does so at once */
  onLoad: (() => void) | null = null
  private env: SourceEnv
  private policy: HostPolicy
  private loop: boolean
  private url: string | null = null
  private objectUrl: string | null = null
  private nominal = 1
  private disposed = false
  /** the next settled error corrects the learned seek lead */
  private adapt = false
  /** the gate was shut at the end */
  private gateShut = false
  /** the blob reload is in flight (single flight) / was tried */
  private fallback = false
  private triedBlob = false
  private downloads = new AbortController()
  private offs: Array<() => void> = []
  /** when the element got its source (0 while a download for it runs) */
  private openedAt = 0
  private lastPos = -1
  private lastMoveAt = 0
  private wrapBase = 0
  private lastRaw = -1

  constructor(env: SourceEnv, out: AudioNode, loop: boolean, policy: HostPolicy) {
    this.env = env
    this.policy = policy
    this.loop = loop
    this.w = wire(env, out, loop)
    this.ctrl = new DriftController(env.now())
    this.listen('canplay', () => {
      this.loaded = true
      if (this.onLoad) this.onLoad()
    })
    this.listen('error', () => {
      if (this.fallback) return
      this.errored = true
      this.errorCode = 'media_error'
    })
    this.listen('ended', () => { if (!this.loop) this.ended = true })
  }

  private listen(type: string, fn: () => void): void {
    this.w.el.addEventListener(type, fn)
    this.offs.push(() => this.w.el.removeEventListener(type, fn))
  }

  /** Bytes we hold, or a URL (resource files → whole-file blob; https → its checked final URL). Never throws. */
  async open(url: string | null, blob: Blob | null): Promise<void> {
    this.url = url
    try {
      if (blob) this.setBlob(blob)
      else if (url && isNuiFile(url)) {
        const r = await fetchLimited(this.env, url, {
          policy: this.policy, signal: this.downloads.signal, maxBytes: MAX_FETCH_BYTES,
          headersMs: FETCH.headersMs, totalMs: FETCH.fileMs, as: 'blob',
        })
        if (this.disposed || !r.blob) return
        this.setBlob(r.blob)
      } else if (url) {
        const final = await resolveMedia(this.env, url, this.policy, this.downloads.signal)
        if (this.disposed) return
        this.url = final
        this.w.el.src = final
      }
      this.openedAt = this.env.now()
    } catch (err) {
      const code = loadCode(err)
      if (this.disposed || code === 'aborted') return
      this.errored = true
      this.errorCode = code
    }
  }

  private setBlob(b: Blob): void {
    if (this.objectUrl) this.env.revokeObjectURL(this.objectUrl)
    this.objectUrl = this.env.createObjectURL(b)
    this.w.el.src = this.objectUrl
  }

  setRate(nominal: number): void {
    if (nominal === this.nominal) return
    this.nominal = nominal
    this.w.el.playbackRate = nominal * this.ctrl.rate
  }

  /** Before t0: loaded, paused, at 0 — so the start is a plain play() at the right moment. */
  hold(): void {
    if (!this.loaded) return
    const el = this.w.el
    if (!el.paused) el.pause()
    if (el.currentTime > 0.05 && !this.seeking) el.currentTime = 0
  }

  /** Plays from a held position (an exact start or an item boundary): open at once, no re-join. */
  launch(): void {
    if (!this.loaded || this.joined || this.ended) return
    const now = this.env.now()
    this.joined = true
    this.ctrl.reset(now)
    this.ctrl.locked = true
    this.ctrl.seeked(now)
    this.w.el.playbackRate = this.nominal
    this.lastMoveAt = now
    play(this.w.el)
    rampTo(this.w.gate.gain, 1, this.env.ctx.currentTime, FADE.edge / 1000)
  }

  /** The not-yet-loaded watchdog alone (a player that cannot sync yet still wants it). */
  watch(now: number): void {
    if (!this.loaded && !this.errored && !this.fallback && this.openedAt && now - this.openedAt > OPEN_MS) {
      this.errored = true
      this.errorCode = 'media_error'
    }
  }

  /** Aligns the element with `expected` seconds (a loop passes its period). */
  sync(expected: number, period: number | null, now: number): void {
    if (this.errored || this.disposed || this.seeking || this.fallback) return
    if (!this.loaded) {
      this.watch(now)
      return
    }
    const el = this.w.el
    if (period === null && this.atEnd()) {
      this.holdAtEnd()
      return
    }
    if (!this.joined) {
      // a first join is silent (the gate opens on lock); a re-join of an audible deck (new clock
      // parameters, resume after pause) seeks behind a dip and keeps its lock
      this.joined = true
      const audible = this.ctrl.locked
      if (!audible) this.ctrl.reset(now)
      this.ctrl.seeked(now)
      this.jump(expected + this.env.seek.lead, period, audible)
      return
    }
    if (el.paused) {
      play(el)
      this.lastMoveAt = now
    }
    const raw = el.currentTime
    if (raw !== this.lastPos) {
      this.lastPos = raw
      this.lastMoveAt = now
    } else if (now - this.lastMoveAt > STALL_MS) {
      this.errored = true
      this.errorCode = 'media_error'
      return
    }
    if (el.readyState < 3) return
    let sample = raw
    if (period) {
      // a native loop wraps currentTime from `period` to 0: unwrap so the line fit stays a line
      if (this.lastRaw >= 0) {
        if (raw < this.lastRaw - period / 2) this.wrapBase += period
        else if (raw > this.lastRaw + period / 2) this.wrapBase -= period
      }
      this.lastRaw = raw
      sample = raw + this.wrapBase
    }
    this.fit.add(now, sample)
    const fitted = this.fit.at(now, el.playbackRate)
    let actual = fitted === null ? sample : fitted
    if (period) actual = mod(actual, period)
    const err = period ? wrapError(actual, expected, period) : actual - expected
    if (this.adapt && this.fit.size() >= 3) {
      // a join that landed ahead by e means the seek took e less than assumed
      this.adapt = false
      const s = this.env.seek
      if (Math.abs(err) < 0.5) s.lead = Math.min(0.3, Math.max(0, s.lead - err * LEAD_GAIN))
    }
    const was = this.ctrl.locked
    const act = this.ctrl.decide(err, now)
    if (act === 'seek') this.jump(expected + this.env.seek.lead, period, true)
    else if (act === 'rate') el.playbackRate = this.nominal * this.ctrl.rate
    if (!was && this.ctrl.locked) rampTo(this.w.gate.gain, 1, this.env.ctx.currentTime, FADE.lock / 1000)
    if (this.ctrl.stuck) this.reloadAsBlob()
  }

  /** Non-looping: the element has played (or been seeked) to its end. */
  atEnd(): boolean {
    return this.ended || (!this.loop && this.w.el.ended)
  }

  private holdAtEnd(): void {
    if (this.gateShut) return
    this.ended = true
    this.gateShut = true
    rampTo(this.w.gate.gain, 0, this.env.ctx.currentTime, FADE.edge / 1000)
    this.env.setTimeout(() => { if (!this.disposed) this.w.el.pause() }, FADE.edge + 20)
  }

  /** Seek to `target`, behind a dip when the deck is audible; a seek that does not land counts. */
  private jump(target: number, period: number | null, audible: boolean): void {
    const t = period ? mod(target, period) : Math.max(0, target)
    const el = this.w.el
    const dip = audible && this.ctrl.locked
    this.fit.reset()
    this.wrapBase = 0
    this.lastRaw = -1
    this.seeking = true
    this.adapt = true
    // the controller starts again from rate 1 after a seek: so does the element
    el.playbackRate = this.nominal * this.ctrl.rate
    const go = (): void => {
      if (this.disposed) return
      let finished = false
      const done = (): void => {
        if (finished || this.disposed) return
        finished = true
        el.removeEventListener('seeked', done)
        this.seeking = false
        // a join past the real end lands AT the end: play() would restart the file from 0
        if (period === null && this.atEnd()) {
          this.holdAtEnd()
          return
        }
        const off = period ? Math.abs(wrapError(el.currentTime, t, period)) : Math.abs(el.currentTime - t)
        if (off > 1 && ++this.missedSeeks >= 2) this.reloadAsBlob()
        if (this.fallback) return
        this.lastMoveAt = this.env.now()
        play(el)
        if (dip) rampTo(this.w.gate.gain, 1, this.env.ctx.currentTime, FADE.dip / 1000)
      }
      el.addEventListener('seeked', done)
      this.env.setTimeout(done, 500)
      try {
        el.currentTime = t
      } catch (err) {
        done()
      }
    }
    if (dip) {
      rampTo(this.w.gate.gain, 0, this.env.ctx.currentTime, FADE.dip / 1000)
      this.env.setTimeout(go, FADE.dip)
    } else go()
  }

  /** The host cannot seek: fetch the file ONCE into a blob (bounded, aborted with the deck). */
  private reloadAsBlob(): void {
    if (this.triedBlob || this.fallback || this.objectUrl || !this.url || this.disposed) return
    this.triedBlob = true
    this.fallback = true
    fetchLimited(this.env, this.url, {
      policy: this.policy, signal: this.downloads.signal, maxBytes: MAX_FETCH_BYTES,
      headersMs: FETCH.headersMs, totalMs: FETCH.fileMs, as: 'blob',
    }).then(
      (r) => {
        this.fallback = false
        if (this.disposed || !r.blob) return
        this.loaded = false
        this.joined = false
        this.missedSeeks = 0
        this.ctrl.reset(this.env.now())
        this.setBlob(r.blob)
        this.openedAt = this.env.now()
      },
      (err: unknown) => {
        this.fallback = false
        const code = loadCode(err)
        if (this.disposed || code === 'aborted') return
        // no blob either: it keeps playing where it plays (the controller stays rate-only)
        if (code === 'bad_url') {
          this.errored = true
          this.errorCode = code
        }
      },
    )
  }

  pause(fadeMs: number): void {
    rampTo(this.w.gate.gain, 0, this.env.ctx.currentTime, fadeMs / 1000)
    const el = this.w.el
    this.env.setTimeout(() => { if (!this.disposed) el.pause() }, fadeMs + 20)
    this.joined = false
  }

  /** Fade the gate out, then tear everything down. */
  close(fadeMs: number): void {
    if (this.disposed) return
    this.downloads.abort()
    rampTo(this.w.gate.gain, 0, this.env.ctx.currentTime, fadeMs / 1000)
    this.env.setTimeout(() => this.dispose(), fadeMs + 30)
  }

  dispose(): void {
    if (this.disposed) return
    this.disposed = true
    this.downloads.abort()
    for (const off of this.offs) off()
    this.offs = []
    unwire(this.w, this.objectUrl, this.env)
    this.objectUrl = null
  }
}
