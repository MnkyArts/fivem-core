// Review RV3 regressions, the clip path (DESIGN §55.16): bounded + abortable downloads (F8), the decode
// bound (F9), no re-download loop (F1), ClipCacheMb as a real budget (F3), first-play one-shots and
// prefetch (F20), the host rule on redirects (F10). Every test FAILS on the engine as first delivered.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { AudioEngine } from '../../src/runtime/audio/engine.ts'
import { hostMatches, makePolicy } from '../../src/runtime/audio/net.ts'
import { MAX_DECODE_BYTES } from '../../src/runtime/audio/loader.ts'
import { harness, streamResponse } from './audio-fakes.ts'
import type { FakeBufferSource, Harness } from './audio-fakes.ts'

const NET = 5000000
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

function setup(): { h: Harness; e: AudioEngine } {
  const h = harness()
  return { h, e: new AudioEngine(h.env) }
}

function feed(e: AudioEngine, h: Harness, extra?: Record<string, unknown>): void {
  e.handle('audio:feed', Object.assign({ t: NET + h.now(), lx: 0, ly: 0, lz: 0, fx: 0, fy: 1, fz: 0, ux: 0, uy: 0, uz: 1 }, extra || {}))
}

function emitter(e: AudioEngine, id: number, source: number, x: number, extra?: Record<string, unknown>): void {
  e.handle('audio:emitter', Object.assign({ id, source, x, y: 0, z: 0, range: 40, curve: 'linear', ref: 1 }, extra || {}))
}

async function run(h: Harness, ms: number, step = 200): Promise<void> {
  for (let t = 0; t < ms; t += step) {
    h.advance(step)
    await h.settle()
  }
}

const count = (h: Harness, needle: string) => h.fetches.filter((u) => u.includes(needle)).length

// ---------------------------------------------------------------- F8 bounded, abortable downloads

test('F8: removing a source aborts its download — every fetch carries the source signal', async () => {
  const { h, e } = setup()
  let pulled = 0
  const signals: AbortSignal[] = []
  h.env.fetch = ((_url: string, init?: RequestInit) => {
    if (init && init.signal) signals.push(init.signal)
    return Promise.resolve(streamResponse(init && init.signal, (c) => new Promise<void>((r) => setTimeout(() => {
      try {
        c.enqueue(new Uint8Array(16384))
        pulled += 16384
      } catch (err) { /* aborted meanwhile */ }
      r()
    }, 2))))
  }) as unknown as typeof fetch
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://radio.example.com/live', t0: NET + h.now() })
  emitter(e, 2, 1, 3)
  h.advance(0)
  await sleep(60)
  const before = pulled
  e.handle('audio:remove', { ids: [2, 1], fadeMs: 50 })
  await sleep(60)
  assert.ok(signals.length >= 1, 'the fetch got a signal')
  assert.ok(signals.every((s) => s.aborted), 'and it was aborted')
  assert.ok(pulled - before <= 16384, 'reading stopped: ' + (pulled - before) + ' bytes after the remove')
})

test('F8: a live mount behind a clip URL is read only up to the clip cap, then plays through an element', async () => {
  const { h, e } = setup()
  let pulled = 0
  h.env.fetch = ((_url: string, init?: RequestInit) => Promise.resolve(streamResponse(init && init.signal, (c) => new Promise<void>((r) => setTimeout(() => {
    try {
      if (pulled >= 10 * 1048576) c.close()
      else {
        c.enqueue(new Uint8Array(65536))
        pulled += 65536
      }
    } catch (err) { /* aborted meanwhile */ }
    r()
  }, 0))))) as unknown as typeof fetch
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'clip', url: 'https://radio.example.com/live.mp3', t0: NET + h.now() })
  emitter(e, 2, 1, 3)
  h.advance(0)
  for (let i = 0; i < 40 && !e.sources.get(1)!.large; i++) await sleep(5)
  await sleep(20)
  assert.ok(pulled <= MAX_DECODE_BYTES + 3 * 65536, 'read ' + pulled + ' bytes')
  assert.equal(e.sources.get(1)!.large, true, 'too big for a buffer → a decoder source')
  assert.equal(h.ctx.decodes, 0)
})

test('F8: a download that hangs times out, is retried with backoff and reported once', async () => {
  const { h, e } = setup()
  let calls = 0
  h.env.fetch = ((_url: string, init?: RequestInit) => {
    calls++
    return Promise.resolve(streamResponse(init && init.signal, () => new Promise<void>(() => { /* never delivers */ })))
  }) as unknown as typeof fetch
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://slow.example.com/a.ogg', t0: NET + h.now() })
  emitter(e, 2, 1, 3)
  await run(h, 61000, 1000)
  assert.deepEqual(h.reports.filter((r) => r.event === 'error').map((r) => r.data), [{ id: 1, code: 'fetch_failed' }])
  assert.equal(e.sources.get(1)!.status === 'failed', false, 'a timeout is retried, not final')
  await run(h, 2000, 200)
  assert.ok(calls >= 2, 'retried after the backoff (' + calls + ' fetches)')
})

// ---------------------------------------------------------------- F9 the decode bound

test('F9: a 1 MB file that is 25 minutes long is never decoded — it plays through a media element', async () => {
  const { h, e } = setup()
  h.fetchBytes = 994569
  h.probeSeconds = 1500
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://uploads.example.com/bomb.ogg', t0: NET + h.now() })
  emitter(e, 2, 1, 3)
  await run(h, 600)
  assert.equal(h.ctx.decodes, 0, 'decodeAudioData never saw it')
  assert.equal(e.sources.get(1)!.large, true)
  assert.equal(h.audios.length, 1, 'one element plays it (decoder granted)')
  assert.ok(h.audios[0].src.startsWith('blob:'), 'from the bytes already downloaded: ' + h.audios[0].src)
})

test('F9: unknown duration → element; more channels than assumed → element after all; verdicts are remembered', async () => {
  const a = setup()
  a.h.probeSeconds = null
  feed(a.e, a.h)
  a.e.handle('audio:source', { id: 1, type: 'loop', url: 'https://cdn.example.com/odd.bin', t0: NET + a.h.now() })
  emitter(a.e, 2, 1, 3)
  await run(a.h, 400)
  assert.equal(a.h.ctx.decodes, 0)
  assert.equal(a.e.sources.get(1)!.large, true)
  const b = setup()
  b.h.ctx.decodeSeconds = 16
  b.h.ctx.decodeChannels = 6
  feed(b.e, b.h)
  b.e.handle('audio:source', { id: 1, type: 'loop', url: 'https://cdn.example.com/surround.ogg', t0: NET + b.h.now() })
  emitter(b.e, 2, 1, 3)
  await run(b.h, 400)
  assert.equal(b.e.sources.get(1)!.large, true, '16 s × 6 ch = 18 MB decoded > the 16 MB per-clip cap')
  assert.equal(b.e.cache.bytes(), 0, 'never cached')
  const downloads = b.e.loader!.downloads
  b.e.handle('audio:source', { id: 3, type: 'loop', url: 'https://cdn.example.com/surround.ogg', t0: NET + b.h.now() })
  assert.equal(b.e.sources.get(3)!.isDecoder(), true, 'a new source of that URL knows at once')
  emitter(b.e, 4, 3, 5)
  await run(b.h, 400)
  assert.equal(b.e.loader!.downloads, downloads, 'no second download or probe for the same URL')
})

// ---------------------------------------------------------------- F1 no re-download loop

test('F1: a large loop that loses its decoder slot never downloads again; regaining the slot does not either', async () => {
  const { h, e } = setup()
  e.handle('audio:prefs', { decoders: 1 })
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'stream', url: 'https://radio.example.com/a.ogg' })
  emitter(e, 11, 1, 1)
  h.fetchBytes = 1300000
  e.handle('audio:source', { id: 2, type: 'loop', url: 'https://cdn.example.com/big-ambience.mp3', t0: NET + h.now() })
  emitter(e, 12, 2, 5)
  await run(h, 5000)
  assert.equal(count(h, 'big-ambience'), 1, 'one download decided it is a file')
  assert.equal(h.audios.filter((a) => a.src.includes('big-ambience')).length, 0, 'no element while the stream holds the only slot')
  assert.equal(e.sources.get(2)!.isDecoder(), true)
  e.handle('audio:remove', { ids: [11, 1], fadeMs: 20 })
  await run(h, 4000)
  assert.equal(h.audios.filter((a) => a.src.includes('big-ambience')).length, 1, 'granted: one element')
  assert.ok(count(h, 'big-ambience') <= 2, 'only the redirect preflight on top (' + count(h, 'big-ambience') + ')')
})

test('F1: with no decoder budget a large clip is fetched once and then waits', async () => {
  const { h, e } = setup()
  e.handle('audio:prefs', { streams: 0 })
  feed(e, h)
  h.fetchBytes = 1300000
  e.handle('audio:source', { id: 2, type: 'loop', url: 'https://cdn.example.com/big-ambience.mp3', t0: NET + h.now() })
  emitter(e, 12, 2, 5)
  await run(h, 5000)
  assert.equal(count(h, 'big-ambience'), 1)
  assert.equal(h.audios.length, 0)
})

// ---------------------------------------------------------------- F3 ClipCacheMb is a budget

test('F3: sources that went quiet hold no decoded buffers — ClipCacheMb bounds decoded memory', async () => {
  const { h, e } = setup()
  h.ctx.decodeSeconds = 30
  h.probeSeconds = 30
  e.handle('audio:prefs', { clipCacheMb: 128 })
  const feedAt = (x: number) => feed(e, h, { lx: x })
  feedAt(0)
  for (let i = 0; i < 10; i++) {
    e.handle('audio:source', { id: 100 + i, type: 'loop', url: 'https://cdn.example.com/shop' + i + '.ogg', t0: NET + h.now() })
    emitter(e, 200 + i, 100 + i, i * 200, { y: 5 })
  }
  e.handle('audio:prefs', { clipCacheMb: 64 })
  for (let i = 0; i < 10; i++) {
    feedAt(i * 200)
    await run(h, 3000)
  }
  feedAt(5000)
  await run(h, 4000)
  let held = 0
  for (const s of e.sources.values()) {
    const p = s.player as unknown as { buffer?: AudioBuffer } | null
    if (p && p.buffer) held += p.buffer.length * p.buffer.numberOfChannels * 4
  }
  assert.equal(held, 0, 'no idle source keeps a buffer')
  assert.ok(e.cache.bytes() <= e.cache.limitBytes(), (e.cache.bytes() / 1048576).toFixed(1) + ' MB cached')
})

test('F3: a clip that cannot fit next to the playing ones plays through an element, never outside the budget', async () => {
  const { h, e } = setup()
  e.handle('audio:prefs', { clipCacheMb: 8 })
  h.ctx.decodeSeconds = 15
  h.probeSeconds = 15
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://cdn.example.com/a.ogg', t0: NET + h.now() })
  emitter(e, 2, 1, 3)
  await run(h, 600)
  assert.ok(h.ctx.of<FakeBufferSource>('bufferSource').length >= 1, 'the first plays from a buffer (5.8 MB, pinned)')
  e.handle('audio:source', { id: 3, type: 'loop', url: 'https://cdn.example.com/b.ogg', t0: NET + h.now() })
  emitter(e, 4, 3, 4)
  await run(h, 600)
  assert.equal(e.sources.get(3)!.large, true, 'no room left next to the playing clip → element path')
  assert.ok(e.cache.bytes() <= e.cache.limitBytes())
})

// ---------------------------------------------------------------- F20 first-play one-shots, prefetch

for (const [leadLeft, fetchMs] of [[100, 150], [50, 120], [0, 80], [50, 250], [100, 350], [0, 200]]) {
  test(`F20: a 0.4 s clip plays on its first trigger (t0 ${leadLeft} ms ahead, fetch ${fetchMs} ms)`, async () => {
    const { h, e } = setup()
    h.env.fetch = ((_url: string) => new Promise((resolve) => h.env.setTimeout(() => resolve(new Response(new Uint8Array(2000))), fetchMs))) as unknown as typeof fetch
    h.ctx.decodeSeconds = 0.4
    feed(e, h)
    e.handle('audio:source', { id: 1, type: 'clip', url: 'https://cdn.example.com/doorbell.ogg', t0: NET + h.now() + leadLeft })
    emitter(e, 2, 1, 3)
    for (let i = 0; i < 25; i++) {
      h.advance(20)
      await h.settle()
    }
    const nodes = h.ctx.of<FakeBufferSource>('bufferSource')
    assert.equal(nodes.length, 1, 'started')
    const late = fetchMs > leadLeft + 20
    if (late) assert.ok(nodes[0].started!.offset < 0.001, 'the page\'s own loading delays it; the attack is kept')
  })
}

test('F20: a clip whose emitter is still out of earshot is fetched and decoded ahead', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://cdn.example.com/fountain.ogg', t0: NET + h.now() })
  emitter(e, 2, 1, 55)
  await run(h, 400)
  assert.equal(e.mixer.counts().real, 0, 'not audible at 55 m (range 40)')
  assert.equal(count(h, 'fountain'), 1, 'but already downloaded')
  assert.equal(h.ctx.decodes, 1, 'and decoded')
  feed(e, h, { lx: 30 })
  await run(h, 400)
  assert.equal(h.ctx.of<FakeBufferSource>('bufferSource').length, 1, 'plays at once when it becomes audible')
  assert.equal(count(h, 'fountain'), 1, 'from the cache')
})

// ---------------------------------------------------------------- F10 the host rule

test('F10: host patterns — exact hosts, *.suffix without the apex, resource files stay in their resource', () => {
  assert.equal(hostMatches('cdn.example.com', 'cdn.example.com'), true)
  assert.equal(hostMatches('a.cdn.example.com', '*.cdn.example.com'), true)
  assert.equal(hostMatches('cdn.example.com', '*.cdn.example.com'), false)
  assert.equal(hostMatches('evilcdn.example.com', '*.cdn.example.com'), false)
  const p = makePolicy('https://radio.example.com/live', ['*.cdn.example.com'], false)
  assert.equal(p.allows('https://radio.example.com/other'), true)
  assert.equal(p.allows('https://edge.cdn.example.com/seg1.ts'), true)
  assert.equal(p.allows('https://grabber.example/x'), false)
  assert.equal(p.allows('http://radio.example.com/live'), false, 'no http outside dev')
  assert.equal(p.allows('https://user:pw@radio.example.com/live'), false)
  assert.equal(p.allows('blob:https://x/1'), false)
  const res = makePolicy('https://cfx-nui-club/set.ogg', ['*.cdn.example.com'], false)
  assert.equal(res.allows('https://cfx-nui-club/other.ogg'), true)
  assert.equal(res.allows('https://edge.cdn.example.com/x'), false, 'a resource file never leaves its resource')
  assert.equal(makePolicy('https://a.example/x', null, true).allows('blob:http://127.0.0.1/1'), true, 'dev pages')
  const set = makePolicy(['https://a.example/1.mp3', 'https://b.example/2.mp3', 'https://cfx-nui-club/3.ogg'], null, false)
  assert.equal(set.allows('https://b.example/2.mp3'), true, 'every item host of a timeline is its own')
  assert.equal(set.allows('https://cfx-nui-other/x.ogg'), false, 'never another resource\'s files')
})

test('F10: a clip redirected to a host the server did not allow is refused (bad_url) and never decoded', async () => {
  const { h, e } = setup()
  h.env.fetch = ((_url: string, init?: RequestInit) => Promise.resolve(streamResponse(init && init.signal, (c) => {
    c.enqueue(new Uint8Array(2000))
    c.close()
  }, { url: 'https://grabber.example/x.ogg' }))) as unknown as typeof fetch
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'clip', url: 'https://cdn.example.com/x.ogg', t0: NET + h.now() })
  emitter(e, 2, 1, 3)
  await run(h, 400)
  assert.equal(h.ctx.decodes, 0)
  assert.equal(e.sources.get(1)!.status, 'failed')
  assert.deepEqual(h.reports.filter((r) => r.event === 'error').map((r) => r.data), [{ id: 1, code: 'bad_url' }])
})

test('F10: the source `hosts` list lets the server allow a CDN redirect', async () => {
  const { h, e } = setup()
  h.env.fetch = ((_url: string, init?: RequestInit) => Promise.resolve(streamResponse(init && init.signal, (c) => {
    c.enqueue(new Uint8Array(2000))
    c.close()
  }, { url: 'https://edge7.cdn.example.com/x.ogg' }))) as unknown as typeof fetch
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://cdn.example.com/x.ogg', t0: NET + h.now(), hosts: ['*.cdn.example.com'] })
  emitter(e, 2, 1, 3)
  await run(h, 400)
  assert.equal(h.ctx.decodes, 1)
  assert.equal(h.reports.length, 0)
})
