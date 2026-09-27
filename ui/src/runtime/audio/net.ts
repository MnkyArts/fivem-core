// core UI — audio engine: every network read the page makes, bounded (DESIGN §55.16, §55.19).
//
// * `fetchLimited` — one fetch with an owner signal (a removed source aborts its downloads), a
//   time-to-headers and a total timeout, a byte cap counted WHILE reading (a live mount behind a clip
//   URL never grows a buffer without end), an optional soft stop ("more than a clip — play it through
//   an element"), and the host rule applied to the FINAL url after redirects.
// * `resolveMedia` — the same checks for a URL an <audio> element will load: the element follows
//   redirects invisibly, so the page follows them first and hands the element the final URL.
// * `probeDuration` — the duration of bytes we hold, read by a throw-away metadata-only element on a
//   blob URL: nothing is ever handed to decodeAudioData without a bounded decoded size (a 1 MB 6 kbps
//   Opus file decodes to 550 MB of PCM).
// * Host rule (§55.19 "clients never contact a host a player supplied"): https only (dev pages: http,
//   blob, data too), no credentials, and the host must be one the server validated — a host of the
//   source's own URL(s) (every item of a timeline) — or match one of the `hosts` patterns it sends with
//   the source (`cdn.example.com`, `*.example.com`). Resource files (`cfx-nui-<res>`) never leave their
//   resource, and no source reaches another resource's files.

import type { AudioErrorCode } from './types.ts'

export class AudioLoadError extends Error {
  /** `aborted` = the owner went away: never reported */
  code: AudioErrorCode | 'aborted'
  constructor(code: AudioErrorCode | 'aborted') {
    super(code)
    this.name = 'AudioLoadError'
    this.code = code
  }
}

export function loadCode(err: unknown): AudioErrorCode | 'aborted' {
  return err instanceof AudioLoadError ? err.code : 'fetch_failed'
}

// ---------------------------------------------------------------- host policy

export interface HostPolicy {
  allows(url: string): boolean
}

/** `cdn.example.com` matches itself; `*.example.com` matches any subdomain (not the apex). */
export function hostMatches(host: string, pattern: string): boolean {
  const h = host.toLowerCase()
  const p = pattern.toLowerCase()
  if (p.startsWith('*.')) return h.endsWith(p.slice(1)) && h.length > p.length - 1
  return h === p
}

export function makePolicy(sourceUrls: string | ReadonlyArray<string> | null, hosts: string[] | null, dev: boolean): HostPolicy {
  const own = new Set<string>()
  const list = sourceUrls === null ? [] : typeof sourceUrls === 'string' ? [sourceUrls] : sourceUrls
  for (const u of list) {
    try {
      own.add(new URL(u).hostname.toLowerCase())
    } catch (err) { /* not a URL: no host of its own */ }
  }
  let resourceOnly = own.size > 0
  for (const h of own) if (!h.startsWith('cfx-nui-')) resourceOnly = false
  return {
    allows(url: string): boolean {
      let u: URL
      try {
        u = new URL(url)
      } catch (err) {
        return false
      }
      if (u.protocol === 'blob:' || u.protocol === 'data:') return dev
      if (u.protocol !== 'https:' && !(dev && u.protocol === 'http:')) return false
      if (u.username || u.password) return false
      const host = u.hostname.toLowerCase()
      if (own.has(host)) return true
      if (resourceOnly || host.startsWith('cfx-nui-')) return false
      return !!hosts && hosts.some((p) => hostMatches(host, p))
    },
  }
}

// ---------------------------------------------------------------- bounded fetch

export interface NetEnv {
  fetch: typeof fetch
  setTimeout(fn: () => void, ms: number): unknown
  clearTimeout(h: unknown): void
}

export interface FetchOptions {
  policy: HostPolicy
  /** the owner's signal: aborting it aborts the request */
  signal?: AbortSignal
  /** hard cap: more is `too_large` */
  maxBytes: number
  /** soft cap: more stops reading and answers `truncated` (the caller switches paths) */
  stopAt?: number
  headersMs: number
  totalMs: number
  /** 'headers' reads nothing (redirect preflight) */
  as: 'bytes' | 'blob' | 'headers'
}

export interface FetchResult {
  finalUrl: string
  bytes: ArrayBuffer | null
  blob: Blob | null
  truncated: boolean
  length: number | null
}

export const FETCH = { headersMs: 15000, clipMs: 60000, fileMs: 180000 } as const

export async function fetchLimited(env: NetEnv, url: string, o: FetchOptions): Promise<FetchResult> {
  if (!o.policy.allows(url)) throw new AudioLoadError('bad_url')
  const ctrl = new AbortController()
  let timedOut = false
  const onAbort = (): void => ctrl.abort()
  if (o.signal) {
    if (o.signal.aborted) throw new AudioLoadError('aborted')
    o.signal.addEventListener('abort', onAbort, { once: true })
  }
  let timer = env.setTimeout(() => {
    timedOut = true
    ctrl.abort()
  }, o.headersMs)
  const fail = (): AudioLoadError => new AudioLoadError(o.signal && o.signal.aborted && !timedOut ? 'aborted' : 'fetch_failed')
  let reader: ReadableStreamDefaultReader<Uint8Array> | null = null
  try {
    let res: Response
    try {
      res = await env.fetch(url, { signal: ctrl.signal, credentials: 'omit' })
    } catch (err) {
      throw fail()
    }
    const finalUrl = res.url || url
    if (!o.policy.allows(finalUrl)) {
      ctrl.abort()
      throw new AudioLoadError('bad_url')
    }
    if (!res.ok) {
      ctrl.abort()
      throw new AudioLoadError('fetch_failed')
    }
    const declared = Number(res.headers.get('content-length') || 0) || null
    const done = (bytes: ArrayBuffer | null, blob: Blob | null, truncated: boolean): FetchResult => ({ finalUrl, bytes, blob, truncated, length: declared })
    if (o.as === 'headers') {
      ctrl.abort()
      return done(null, null, false)
    }
    if (declared !== null && declared > o.maxBytes) {
      ctrl.abort()
      throw new AudioLoadError('too_large')
    }
    if (o.stopAt !== undefined && declared !== null && declared > o.stopAt) {
      ctrl.abort()
      return done(null, null, true)
    }
    env.clearTimeout(timer)
    timer = env.setTimeout(() => {
      timedOut = true
      ctrl.abort()
    }, o.totalMs)
    if (!res.body) throw new AudioLoadError('fetch_failed')
    reader = res.body.getReader()
    const chunks: Uint8Array[] = []
    let total = 0
    for (;;) {
      let step: ReadableStreamReadResult<Uint8Array>
      try {
        step = await reader.read()
      } catch (err) {
        throw fail()
      }
      if (step.done) break
      const chunk = step.value
      if (!chunk || !chunk.length) continue
      total += chunk.length
      if (total > o.maxBytes) {
        ctrl.abort()
        throw new AudioLoadError('too_large')
      }
      if (o.stopAt !== undefined && total > o.stopAt) {
        ctrl.abort()
        return done(null, null, true)
      }
      chunks.push(chunk)
    }
    reader = null
    if (o.as === 'blob') return done(null, new Blob(chunks as unknown as BlobPart[]), false)
    const out = new Uint8Array(total)
    let at = 0
    for (const c of chunks) {
      out.set(c, at)
      at += c.length
    }
    return done(out.buffer, null, false)
  } finally {
    env.clearTimeout(timer)
    if (o.signal) o.signal.removeEventListener('abort', onAbort)
    // cancelling an errored/aborted body REJECTS (it never throws): swallow it (a bogus
    // unhandledrejection would reach the shell's error reporter)
    if (reader) reader.cancel().catch(() => { /* already closed */ })
  }
}

/** The URL an element should load: redirects followed and checked here, the final URL returned. */
export async function resolveMedia(env: NetEnv, url: string, policy: HostPolicy, signal?: AbortSignal): Promise<string> {
  if (url.startsWith('blob:') || url.startsWith('data:')) {
    if (!policy.allows(url)) throw new AudioLoadError('bad_url')
    return url
  }
  const r = await fetchLimited(env, url, { policy, signal, maxBytes: Infinity, headersMs: FETCH.headersMs, totalMs: FETCH.headersMs, as: 'headers' })
  return r.finalUrl
}

// ---------------------------------------------------------------- duration probe

export interface ProbeEnv {
  createAudio(): HTMLAudioElement
  createObjectURL(o: Blob): string
  revokeObjectURL(u: string): void
  setTimeout(fn: () => void, ms: number): unknown
  clearTimeout(h: unknown): void
}

/** Seconds of audio in `blob` per the browser's own demuxer; null when unknown (→ never decode). */
export function probeDuration(env: ProbeEnv, blob: Blob, timeoutMs: number): Promise<number | null> {
  const el = env.createAudio()
  el.preload = 'metadata'
  el.muted = true
  const url = env.createObjectURL(blob)
  return new Promise<number | null>((resolve) => {
    let settled = false
    const finish = (value: number | null): void => {
      if (settled) return
      settled = true
      env.clearTimeout(timer)
      el.removeEventListener('loadedmetadata', onMeta)
      el.removeEventListener('error', onError)
      try {
        el.removeAttribute('src')
        el.load()
      } catch (err) { /* detached */ }
      env.revokeObjectURL(url)
      resolve(value)
    }
    const onMeta = (): void => {
      const d = el.duration
      finish(Number.isFinite(d) && d > 0 ? d : null)
    }
    const onError = (): void => finish(null)
    const timer = env.setTimeout(() => finish(null), timeoutMs)
    el.addEventListener('loadedmetadata', onMeta)
    el.addEventListener('error', onError)
    el.src = url
  })
}
