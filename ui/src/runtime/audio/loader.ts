// core UI — audio engine: the clip loader (DESIGN §55.16 "decoded clips LRU"; R6 §1.6).
//
// A clip/loop becomes an AudioBuffer only when its DECODED size is bounded before decodeAudioData
// runs — the decode allocates float PCM for the file's whole duration at the context rate, whatever
// the compressed size (a 1 MB 6 kbps Opus file = 25 min = 550 MB). The order is:
//   1. read at most MAX_DECODE_BYTES (counted while reading; a `content-length` above it stops at once)
//      — anything bigger is "a file": it plays through a media element and needs a decoder slot
//   2. probe the duration of the bytes (metadata-only element on a blob URL); unknown → element
//   3. duration × rate × 2 ch × 4 B must fit MAX_CLIP_BYTES and the cache room left by PLAYING clips
//   4. decode, check the real size (more channels than assumed → element), put it in the budget
// The verdict "too long/big for a buffer" is remembered per URL, so a source that loses its decoder
// slot and gets it back never downloads or probes again. Downloads are shared per URL and
// reference-counted: each requester passes its source's signal, the last one to let go aborts.

import type { ClipCache } from './cache.ts'
import { AudioLoadError, FETCH, fetchLimited, probeDuration } from './net.ts'
import type { HostPolicy, NetEnv, ProbeEnv } from './net.ts'

/** Compressed bytes a clip may have before it counts as a file (≈ 75 s of 128 kbps MP3). */
export const MAX_DECODE_BYTES = 1200000
/** A whole file into a blob (resource files, hosts without Range support). */
export const MAX_FETCH_BYTES = 200 * 1024 * 1024
/** Decoded PCM per clip: ≈ 43 s of stereo float at 48 kHz. */
export const MAX_CLIP_BYTES = 16 * 1024 * 1024
export const PROBE_MS = 3000

export type LoadResult =
  | { kind: 'buffer'; buffer: AudioBuffer }
  | { kind: 'element'; blob: Blob | null; url: string }

export interface LoaderEnv extends NetEnv, ProbeEnv {}

interface Pending {
  p: Promise<LoadResult>
  ctrl: AbortController
  refs: number
}

export class BufferLoader {
  readonly cache: ClipCache<AudioBuffer>
  decodes = 0
  probes = 0
  downloads = 0
  private ctx: BaseAudioContext
  private env: LoaderEnv
  private pending = new Map<string, Pending>()
  private large = new Set<string>()

  constructor(ctx: BaseAudioContext, env: LoaderEnv, cache: ClipCache<AudioBuffer>) {
    this.ctx = ctx
    this.env = env
    this.cache = cache
  }

  /** Known to be too long or too big for a buffer: plays through an element, needs a decoder. */
  isLarge(url: string): boolean {
    return this.large.has(url)
  }

  private markLarge(url: string): void {
    if (this.large.size >= 512) this.large.clear()
    this.large.add(url)
  }

  /** A buffer (unpinned — pin it before use) or the element verdict; rejects with AudioLoadError. */
  get(url: string, policy: HostPolicy, signal: AbortSignal): Promise<LoadResult> {
    const hit = this.cache.get(url)
    if (hit) return Promise.resolve({ kind: 'buffer', buffer: hit })
    if (this.large.has(url)) return Promise.resolve({ kind: 'element', blob: null, url })
    if (signal.aborted) return Promise.reject(new AudioLoadError('aborted'))
    let entry = this.pending.get(url)
    if (!entry) {
      const ctrl = new AbortController()
      const created: Pending = { p: this.download(url, policy, ctrl.signal), ctrl, refs: 0 }
      const clear = (): void => {
        if (this.pending.get(url) === created) this.pending.delete(url)
      }
      created.p.then(clear, clear)
      this.pending.set(url, created)
      entry = created
    }
    const e = entry
    e.refs++
    return new Promise<LoadResult>((resolve, reject) => {
      let released = false
      const letGo = (): void => {
        released = true
        signal.removeEventListener('abort', onAbort)
        e.refs--
      }
      const onAbort = (): void => {
        if (released) return
        letGo()
        if (e.refs <= 0) {
          e.ctrl.abort()
          if (this.pending.get(url) === e) this.pending.delete(url)
        }
        reject(new AudioLoadError('aborted'))
      }
      signal.addEventListener('abort', onAbort, { once: true })
      e.p.then(
        (r) => {
          if (released) return
          letGo()
          resolve(r)
        },
        (err: unknown) => {
          if (released) return
          letGo()
          reject(err)
        },
      )
    })
  }

  private async download(url: string, policy: HostPolicy, signal: AbortSignal): Promise<LoadResult> {
    this.downloads++
    const r = await fetchLimited(this.env, url, {
      policy, signal, maxBytes: MAX_FETCH_BYTES, stopAt: MAX_DECODE_BYTES,
      headersMs: FETCH.headersMs, totalMs: FETCH.clipMs, as: 'bytes',
    })
    if (r.truncated || !r.bytes) {
      this.markLarge(url)
      return { kind: 'element', blob: null, url: r.finalUrl }
    }
    const bytes = r.bytes
    // the Blob copies the bytes now: decodeAudioData detaches `bytes` later
    const blob = new Blob([bytes])
    this.probes++
    const seconds = await probeDuration(this.env, blob, PROBE_MS)
    if (signal.aborted) throw new AudioLoadError('aborted')
    const estimate = seconds === null ? Infinity : seconds * this.ctx.sampleRate * 2 * 4
    if (estimate > MAX_CLIP_BYTES) {
      this.markLarge(url)
      return { kind: 'element', blob, url: r.finalUrl }
    }
    // not now: the budget is held by clips that are playing (no verdict — it may fit later)
    if (estimate > this.cache.room()) return { kind: 'element', blob, url: r.finalUrl }
    this.decodes++
    let buffer: AudioBuffer
    try {
      buffer = await this.ctx.decodeAudioData(bytes)
    } catch (err) {
      throw new AudioLoadError('decode_failed')
    }
    if (signal.aborted) throw new AudioLoadError('aborted')
    const size = buffer.length * buffer.numberOfChannels * 4
    if (size > MAX_CLIP_BYTES) {
      this.markLarge(url)
      return { kind: 'element', blob, url: r.finalUrl }
    }
    if (!this.cache.put(url, buffer, size)) return { kind: 'element', blob, url: r.finalUrl }
    return { kind: 'buffer', buffer }
  }
}
