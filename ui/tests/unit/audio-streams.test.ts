// Review RV3 regressions, live streams (DESIGN §55.16): the ICY path watches its connection and its
// media pipeline (F4), reloads reset their backoff (F6), hls.js only fetches from allowed hosts (F10),
// ICY reads are paced (F13), stopping never leaves an unhandled AbortError (F16). Every test FAILS on
// the engine as first delivered.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { AudioEngine } from '../../src/runtime/audio/engine.ts'
import { guardLoader } from '../../src/runtime/audio/streams.ts'
import { makePolicy } from '../../src/runtime/audio/net.ts'
import type { HlsCtor } from '../../src/runtime/audio/media.ts'
import { fakeMediaSource, harness, streamResponse } from './audio-fakes.ts'
import type { FakeAudio, Harness } from './audio-fakes.ts'

const NET = 5000000
const BPS = 16000
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

function setup(): { h: Harness; e: AudioEngine } {
  const h = harness()
  return { h, e: new AudioEngine(h.env) }
}

/** Feed + source + emitter, then one pass: returns the stream's element. */
async function start(e: AudioEngine, h: Harness, url: string, kind?: string): Promise<FakeAudio> {
  e.handle('audio:feed', { t: NET + h.now(), lx: 0, ly: 0, lz: 0, fx: 0, fy: 1, fz: 0, ux: 0, uy: 0, uz: 1 })
  e.handle('audio:source', Object.assign({ id: 1, type: 'stream', url }, kind ? { kind } : {}))
  e.handle('audio:emitter', { id: 2, source: 1, x: 3, y: 0, z: 0, range: 40, curve: 'linear', ref: 1 })
  h.advance(0)
  await h.settle()
  return h.audios[0]
}

/** MSE whose appends show up in the stream element's `buffered` (128 kbps = 16 KB/s). */
function mse(h: Harness): { appended(): number; created: Array<{ readyState: string }>; MS: typeof MediaSource } {
  let appended = 0
  const kit = fakeMediaSource((sb) => {
    sb.onAppend = (n) => {
      appended += n
      const el = h.audios[h.audios.length - 1]
      if (el) el.setBuffered([[0, appended / BPS]])
    }
  })
  return { appended: () => appended, created: kit.created, MS: kit.MS }
}

/** Playback: the element advances while playing, never past what is buffered. */
async function play(h: Harness, el: FakeAudio, ms: number, step = 200): Promise<void> {
  for (let t = 0; t < ms; t += step) {
    h.advance(step)
    if (!el.paused) {
      const end = el.buffered.length ? el.buffered.end(el.buffered.length - 1) : 0
      el.currentTime = Math.min(end, el.currentTime + (step / 1000) * el.playbackRate)
    }
    await h.settle()
  }
}

// ---------------------------------------------------------------- F4 ICY watchdog and media errors

test('F4: an Icecast connection that goes quiet is reconnected — and reported after three tries', async () => {
  const { h, e } = setup()
  const m = mse(h)
  h.env.MediaSource = m.MS
  let fetches = 0
  h.env.fetch = ((_url: string, init?: RequestInit) => {
    fetches++
    let sent = false
    return Promise.resolve(streamResponse(init && init.signal, (c) => {
      if (sent) return new Promise<void>(() => { /* the source dropped, the socket stays open */ })
      sent = true
      c.enqueue(new Uint8Array(65536))
    }, { headers: { 'icy-metaint': '0' } }))
  }) as unknown as typeof fetch
  const el = await start(e, h, 'https://radio.example.com/live.mp3', 'mp3')
  await play(h, el, 60000)
  assert.ok(fetches >= 3, 'reconnected ' + (fetches - 1) + ' times')
  assert.deepEqual(h.reports.filter((r) => r.event === 'error').map((r) => r.data), [{ id: 1, code: 'stream_failed' }])
})

test('F4: after a decode error the MediaSource is rebuilt and the stream reconnects; media_error is reported once', async () => {
  const { h, e } = setup()
  const m = mse(h)
  h.env.MediaSource = m.MS
  let fetches = 0
  h.env.fetch = ((_url: string, init?: RequestInit) => {
    fetches++
    return Promise.resolve(streamResponse(init && init.signal, (c) => new Promise<void>((r) => {
      h.env.setTimeout(() => {
        try { c.enqueue(new Uint8Array(3200)) } catch (err) { /* aborted */ }
        r()
      }, 200)
    }), { headers: { 'icy-metaint': '0' } }))
  }) as unknown as typeof fetch
  const el = await start(e, h, 'https://radio.example.com/live.mp3', 'mp3')
  await play(h, el, 3000)
  el.error = { code: 3 }
  el.emit('error')
  await play(h, el, 5000)
  assert.ok(fetches >= 2, 'reconnected')
  assert.ok(m.created.length >= 2, 'a fresh MediaSource')
  assert.deepEqual(h.reports.map((r) => r.data), [{ id: 1, code: 'media_error' }])
})

// ---------------------------------------------------------------- F6 backoff reset

test('F6: every transient stall of an element stream costs the same short silence; nothing is reported', async () => {
  const { h, e } = setup()
  const el = await start(e, h, 'https://radio.example.com/live.ogg')
  el.emit('playing')
  const waits: number[] = []
  for (let k = 0; k < 5; k++) {
    for (let i = 0; i < 300; i++) {
      el.currentTime += 0.2
      h.advance(200)
      await h.settle()
    }
    const plays = el.plays
    const t0 = h.now()
    while (el.plays === plays) {
      h.advance(100)
      await h.settle()
    }
    waits.push((h.now() - t0) / 1000)
    el.emit('playing')
  }
  assert.ok(waits.every((w) => w <= 12), 'silence per stall: ' + JSON.stringify(waits))
  assert.equal(h.reports.filter((r) => r.data.code === 'stream_failed').length, 0)
})

// ---------------------------------------------------------------- F10 hls.js obeys the host rule

class BaseLoader {
  stats = { loaded: 0 }
  context: unknown = null
  static loads: string[] = []
  load = (ctx: { url: string }, _cfg: unknown, cb: { onSuccess(r: { url: string }, s: unknown, c: unknown, d: unknown): void }): void => {
    BaseLoader.loads.push(ctx.url)
    cb.onSuccess({ url: ctx.url.includes('/redirect/') ? 'https://grabber.example/x.ts' : ctx.url }, this.stats, ctx, null)
  }
  abort(): void {}
  destroy(): void {}
}

test('F10: the hls.js loader refuses playlists, segments, keys and redirect targets on other hosts', () => {
  BaseLoader.loads = []
  let refused = 0
  const Guarded = guardLoader(BaseLoader as never, makePolicy('https://radio.example.com/live.m3u8', ['*.cdn.example.com'], false), () => { refused++ })
  const l = new Guarded({})
  const got: string[] = []
  const cb = {
    onSuccess: (r: { url?: string }) => { got.push('ok ' + r.url) },
    onError: (err: { text: string }) => { got.push('refused: ' + err.text) },
    onTimeout: () => {},
  }
  l.load({ url: 'https://radio.example.com/live/seg1.ts' }, {}, cb)
  l.load({ url: 'https://edge.cdn.example.com/seg2.ts' }, {}, cb)
  l.load({ url: 'https://grabber.example/key.bin' }, {}, cb)
  l.load({ url: 'https://radio.example.com/redirect/seg3.ts' }, {}, cb)
  assert.equal(got.filter((g) => g.startsWith('ok')).length, 2)
  assert.equal(refused, 2)
  assert.equal(BaseLoader.loads.includes('https://grabber.example/key.bin'), false, 'never even requested')
})

test('F10: an HLS stream that points at a disallowed segment host fails with bad_url — no retry loop', async () => {
  const { h, e } = setup()
  const instances: Array<{ handlers: Map<string, (ev: string, d: unknown) => void> }> = []
  class FakeHls {
    static isSupported(): boolean { return true }
    static Events = { ERROR: 'hlsError', MANIFEST_PARSED: 'hlsManifestParsed' }
    static ErrorTypes = { NETWORK_ERROR: 'networkError', MEDIA_ERROR: 'mediaError' }
    static DefaultConfig = { loader: BaseLoader }
    handlers = new Map<string, (ev: string, d: unknown) => void>()
    private cfg: { loader: new (c: unknown) => BaseLoader }
    constructor(cfg: { loader: new (c: unknown) => BaseLoader }) {
      this.cfg = cfg
      instances.push(this)
    }
    on(ev: string, fn: (ev: string, d: unknown) => void): void { this.handlers.set(ev, fn) }
    attachMedia(): void {}
    loadSource(url: string): void {
      const L = this.cfg.loader
      new L(this.cfg).load({ url }, {}, {
        onSuccess: () => {
          new L(this.cfg).load({ url: 'https://grabber.example/seg0.ts' }, {}, {
            onSuccess: () => {},
            onError: () => { (this.handlers.get('hlsError') as (ev: string, d: unknown) => void)('hlsError', { fatal: false, type: 'networkError' }) },
            onTimeout: () => {},
          } as never)
        },
        onError: () => {},
        onTimeout: () => {},
      } as never)
    }
    recoverMediaError(): void {}
    destroy(): void {}
  }
  h.env.importHls = () => Promise.resolve(FakeHls as unknown as HlsCtor)
  await start(e, h, 'https://radio.example.com/live/index.m3u8')
  await play(h, h.audios[0], 3000)
  assert.equal(instances.length, 1, 'one hls.js instance, never rebuilt')
  assert.equal(e.sources.get(1)!.status, 'failed')
  assert.deepEqual(h.reports.map((r) => r.data), [{ id: 1, code: 'bad_url' }])
})

// ---------------------------------------------------------------- F13 paced reads

test('F13: a static 8 MB MP3 behind a stream URL plays in real time — not downloaded at line rate, no jumps', async () => {
  const { h, e } = setup()
  const m = mse(h)
  h.env.MediaSource = m.MS
  let fetches = 0
  const FILE = 8 * 1024 * 1024
  h.env.fetch = ((_url: string, init?: RequestInit) => {
    fetches++
    let sent = 0
    return Promise.resolve(streamResponse(init && init.signal, (c) => {
      if (sent >= FILE) c.close()
      else {
        sent += 65536
        c.enqueue(new Uint8Array(65536))
      }
    }, { headers: { 'icy-metaint': '0' } }))
  }) as unknown as typeof fetch
  const el = await start(e, h, 'https://cdn.example.com/mix.mp3', 'mp3')
  let jumps = 0
  let t = 0
  Object.defineProperty(el, 'currentTime', { configurable: true, get: () => t, set: (v: number) => { jumps++; t = v } })
  for (let i = 0; i < 150; i++) {
    h.advance(200)
    await h.settle()
    if (!el.paused) t = Math.min(el.buffered.length ? el.buffered.end(0) : 0, t + 0.2 * el.playbackRate)
  }
  const seconds = m.appended() / BPS
  assert.ok(seconds <= 30 + 16, 'buffered ' + seconds.toFixed(1) + ' s of audio in 30 s')
  assert.equal(jumps, 0, 'no live-edge jumps')
  assert.equal(fetches, 1, 'no end → no reconnect → no second download')
})

// ---------------------------------------------------------------- F16 no unhandled rejections

test('F16: stopping an ICY stream never leaves an unhandled AbortError', async () => {
  let unhandled = 0
  const onUnhandled = (): void => { unhandled++ }
  process.on('unhandledRejection', onUnhandled)
  try {
    const { h, e } = setup()
    h.env.MediaSource = mse(h).MS
    h.env.fetch = ((_url: string, init?: RequestInit) => Promise.resolve(streamResponse(init && init.signal, (c) => new Promise<void>((r) => {
      h.env.setTimeout(() => {
        try { c.enqueue(new Uint8Array(3200)) } catch (err) { /* aborted */ }
        r()
      }, 200)
    }), { headers: { 'icy-metaint': '0' } }))) as unknown as typeof fetch
    const el = await start(e, h, 'https://radio.example.com/live.mp3', 'mp3')
    await play(h, el, 2000)
    e.handle('audio:remove', { ids: [2, 1], fadeMs: 50 })
    await play(h, el, 1000)
    await sleep(30)
  } finally {
    process.off('unhandledRejection', onUnhandled)
  }
  assert.equal(unhandled, 0)
})
