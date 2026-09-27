// Review RV3 regressions, media elements (DESIGN §55.16): ended elements are never restarted (F2),
// native loops do not re-seek at their wrap (F5), the blob fallback is single-flight and leak-free (F7),
// a failing player never stops the engine tick (F14), items and clips are retried (F15), the element
// rate follows the controller after a seek (F18), a seek storm stops (F19). Every test FAILS on the
// engine as first delivered.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { AudioEngine } from '../../src/runtime/audio/engine.ts'
import { harness, streamResponse } from './audio-fakes.ts'
import type { FakeAudio, FakeGain, Harness } from './audio-fakes.ts'

const NET = 5000000

function setup(): { h: Harness; e: AudioEngine } {
  const h = harness()
  return { h, e: new AudioEngine(h.env) }
}

function feed(e: AudioEngine, h: Harness): void {
  e.handle('audio:feed', { t: NET + h.now(), lx: 0, ly: 0, lz: 0, fx: 0, fy: 1, fz: 0, ux: 0, uy: 0, uz: 1 })
}

function emitter(e: AudioEngine, id: number, source: number, x: number): void {
  e.handle('audio:emitter', { id, source, x, y: 0, z: 0, range: 40, curve: 'linear', ref: 1 })
}

async function run(h: Harness, ms: number, step = 200): Promise<void> {
  for (let t = 0; t < ms; t += step) {
    h.advance(step)
    await h.settle()
  }
}

interface Media {
  t(): number
  restarts(): number
  sets(): number
  /** play `ms` of wall time in 10 ms steps: the element advances while playing, seeks complete */
  play(ms: number): Promise<void>
}

/**
 * HTML media semantics the plain fake lacks: currentTime clamps to [0, duration]; the end sets `ended`
 * (paused, event); play() on an ended element restarts it at 0; a native loop wraps. `seekable(src)`
 * says whether the host behind the current src can seek (no Range → the position does not move).
 */
function html(h: Harness, el: FakeAudio, duration: number, opts?: { loop?: boolean; seekable?: (src: string) => boolean }): Media {
  let t = 0
  let ended = false
  let restarts = 0
  let sets = 0
  Object.defineProperty(el, 'currentTime', {
    configurable: true,
    get: () => t,
    set: (v: number) => {
      sets++
      if (opts && opts.seekable && !opts.seekable(el.src)) return
      t = opts && opts.loop ? ((v % duration) + duration) % duration : Math.max(0, Math.min(duration, v))
      ended = !(opts && opts.loop) && t >= duration
    },
  })
  Object.defineProperty(el, 'ended', { configurable: true, get: () => ended, set: (v: boolean) => { ended = v } })
  el.duration = duration
  el.readyState = 4
  const base = el.play.bind(el)
  el.play = () => {
    if (ended) {
      t = 0
      ended = false
      restarts++
    }
    return base()
  }
  return {
    t: () => t,
    restarts: () => restarts,
    sets: () => sets,
    async play(ms: number) {
      for (let i = 0; i < ms; i += 10) {
        h.advance(10)
        if (!el.paused && !ended) {
          t += 0.01 * el.playbackRate
          if (t >= duration) {
            if (opts && opts.loop) t -= duration
            else {
              t = duration
              ended = true
              el.paused = true
              el.emit('ended')
            }
          }
        }
        el.emit('seeked')
        if (i % 100 === 0) await h.settle()
      }
    },
  }
}

function gateOf(h: Harness, el: FakeAudio): FakeGain {
  const media = h.ctx.of('media').filter((n) => (n as unknown as { mediaElement: FakeAudio }).mediaElement === el)[0]
  return media.outputs.values().next().value as unknown as FakeGain
}

// ---------------------------------------------------------------- F2 ended elements

test('F2: a finished large one-shot is not restarted from 0 by the drift poll — it ends', async () => {
  const { h, e } = setup()
  feed(e, h)
  h.fetchBytes = 1300000
  e.handle('audio:source', { id: 1, type: 'clip', url: 'https://cdn.example.com/announcement.mp3', t0: NET + h.now() })
  emitter(e, 2, 1, 3)
  await run(h, 400)
  const el = h.audios[0]
  assert.ok(el, 'an element plays the large clip')
  const m = html(h, el, 4)
  el.emit('canplay')
  await m.play(10000)
  assert.equal(m.restarts(), 0, 'play() was never called on the ended element')
  assert.equal(e.sources.get(1)!.status, 'ended')
  assert.equal(e.mixer.counts().real, 0)
})

test('F2: a timeline item shorter than its declared duration waits silently for its boundary', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', {
    id: 1, type: 'timeline', t0: NET + h.now(),
    items: [{ url: 'https://cdn.example.com/a.mp3', duration: 10000 }, { url: 'https://cdn.example.com/b.mp3', duration: 10000 }],
  })
  emitter(e, 2, 1, 3)
  await run(h, 200)
  const first = h.audios[0]
  const m = html(h, first, 4)
  first.emit('canplay')
  await m.play(9000)
  assert.equal(m.restarts(), 0, 'the 4 s file ended and stays ended')
  const second = h.audios[1]
  html(h, second, 60)
  second.emit('canplay')
  await m.play(1600)
  assert.ok(second.plays >= 1, 'the next item starts at its boundary')
  assert.equal(m.restarts(), 0)
})

// ---------------------------------------------------------------- F5 native loop wraps

test('F5: a natively looping element is not re-seeked at its wrap points', async () => {
  const { h, e } = setup()
  feed(e, h)
  h.fetchBytes = 1300000
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://cdn.example.com/amb.mp3', t0: NET + h.now() })
  emitter(e, 2, 1, 3)
  await run(h, 400)
  const el = h.audios[0]
  const m = html(h, el, 20, { loop: true })
  el.emit('canplay')
  await m.play(65000)
  const deck = (e.sources.get(1)!.player as unknown as { deck: { ctrl: { seeks: number; locked: boolean; lastError: number } } }).deck
  assert.equal(deck.ctrl.seeks, 0, 'three wraps, no seek')
  assert.equal(deck.ctrl.locked, true)
  assert.ok(Math.abs(deck.ctrl.lastError) < 0.05, 'still in sync: ' + deck.ctrl.lastError)
})

// ---------------------------------------------------------------- F7 the blob fallback

test('F7: a slow host without Range support: ONE whole-file download, and no object URL leaks', async () => {
  const { h, e } = setup()
  let downloads = 0
  let created = 0
  let revoked = 0
  h.env.fetch = ((_url: string, init?: RequestInit) => Promise.resolve(streamResponse(init && init.signal, (c) => new Promise<void>((r) => {
    downloads++
    h.env.setTimeout(() => {
      try {
        c.enqueue(new Uint8Array(16))
        c.close()
      } catch (err) { /* aborted */ }
      r()
    }, 8000)
  })))) as unknown as typeof fetch
  h.env.createObjectURL = () => 'blob:fake/' + ++created
  h.env.revokeObjectURL = () => { revoked++ }
  feed(e, h)
  e.handle('audio:source', {
    id: 1, type: 'timeline', t0: NET + h.now() - 30000,
    items: [{ url: 'https://dj.example.com/set1.mp3', duration: 3600000 }, { url: 'https://dj.example.com/set2.mp3', duration: 3600000 }],
  })
  emitter(e, 2, 1, 3)
  await run(h, 200)
  const el = h.audios[0]
  let t = 0
  // no Range: a seek never moves; the element is ready again 700 ms after each attempt (slower than the 500 ms seek timeout)
  Object.defineProperty(el, 'currentTime', {
    configurable: true,
    get: () => t,
    set: (v: number) => {
      if (el.src.startsWith('blob:')) t = v
      else h.env.setTimeout(() => el.emit('canplay'), 700)
    },
  })
  el.duration = 3600
  el.readyState = 4
  el.emit('canplay')
  let last = h.now()
  for (let i = 0; i < 1200; i++) {
    h.advance(10)
    if (!el.paused) t += (h.now() - last) / 1000
    last = h.now()
    if (i % 10 === 0) await h.settle()
  }
  await h.settle()
  assert.equal(downloads, 1, 'single flight')
  assert.ok(created - revoked <= 1, 'created ' + created + ', revoked ' + revoked)
  assert.ok(el.src.startsWith('blob:'), 'plays from the blob now')
})

// ---------------------------------------------------------------- F14 the engine tick survives

test('F14: a media error inside a timeline tick neither throws out of the engine tick nor stops it', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'timeline', t0: NET + h.now() - 30000, items: [{ url: 'https://cdn.example.com/1.mp3', duration: 600000 }] })
  emitter(e, 2, 1, 3)
  e.handle('audio:source', { id: 3, type: 'stream', url: 'https://radio.example.com/b.ogg' })
  emitter(e, 4, 3, 6)
  await run(h, 200)
  const el = h.audios[0]
  el.readyState = 4
  el.emit('canplay')
  await run(h, 400)
  el.emit('seeked')
  el.error = { code: 2 }
  el.emit('error')
  const thrown: string[] = []
  for (let i = 0; i < 20; i++) {
    try {
      h.advance(200)
    } catch (err) {
      thrown.push(String(err))
    }
    await h.settle()
  }
  assert.deepEqual(thrown, [])
  assert.notEqual((e as unknown as { tickTimer: unknown }).tickTimer, null, 'the 5 Hz tick is still armed')
  const radio = h.audios.filter((a) => a.src.includes('b.ogg'))[0]
  assert.ok(radio, 'the healthy stream kept running')
})

// ---------------------------------------------------------------- F15 retries

test('F15: a network blip on a timeline item re-opens it after a backoff — the set goes on', async () => {
  const { h, e } = setup()
  feed(e, h)
  const items = [1, 2, 3].map((i) => ({ url: 'https://cdn.example.com/set/' + i + '.mp3', duration: 1200000 }))
  e.handle('audio:source', { id: 1, type: 'timeline', t0: NET + h.now() - 30000, items })
  emitter(e, 2, 1, 3)
  await run(h, 200)
  const el = h.audios[0]
  el.readyState = 4
  el.emit('canplay')
  await run(h, 400)
  el.error = { code: 2 }
  el.emit('error')
  await run(h, 3000)
  assert.equal(h.audios.length, 2, 'a second element…')
  const again = h.audios[1]
  assert.ok(again.src.endsWith('/1.mp3'), '…for the same item: ' + again.src)
  assert.equal(el.src, '', 'the broken one was released')
  html(h, again, 1200)
  again.emit('canplay')
  await run(h, 2000)
  const s = e.sources.get(1)!
  assert.notEqual(s.status, 'failed')
  assert.equal(e.mixer.counts().real, 1)
  assert.deepEqual(h.reports.filter((r) => r.event === 'error').map((r) => r.data), [{ id: 1, code: 'media_error' }], 'reported once')
})

test('F15: five failures in a row give the timeline up; a clock update revives it', async () => {
  const { h, e } = setup()
  feed(e, h)
  const items = [{ url: 'https://cdn.example.com/broken.mp3', duration: 600000 }]
  const t0 = NET + h.now() - 30000
  e.handle('audio:source', { id: 1, type: 'timeline', t0, items })
  emitter(e, 2, 1, 3)
  for (let k = 0; k < 40 && e.sources.get(1)!.status !== 'failed'; k++) {
    await run(h, 200)
    const el = h.audios[h.audios.length - 1]
    if (el && !el.error) {
      el.error = { code: 4 }
      el.emit('error')
    }
    await run(h, 800)
  }
  assert.equal(e.sources.get(1)!.status, 'failed')
  e.handle('audio:source', { id: 1, type: 'timeline', t0: t0 + 5, items })
  await run(h, 400)
  assert.notEqual(e.sources.get(1)!.status, 'failed', 'a clock update gives it a new chance')
})

test('F15: a clip whose download fails is retried with backoff and plays once the host answers', async () => {
  const { h, e } = setup()
  h.fetchFail = true
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://cdn.example.com/a.ogg', t0: NET + h.now() })
  emitter(e, 2, 1, 3)
  await run(h, 600)
  assert.deepEqual(h.reports.map((r) => r.data), [{ id: 1, code: 'fetch_failed' }])
  assert.notEqual(e.sources.get(1)!.status, 'failed')
  h.fetchFail = false
  await run(h, 3000)
  assert.equal(h.ctx.of('bufferSource').length, 1, 'playing after the retry')
})

// ---------------------------------------------------------------- F18 / F19 seeks

test('F18: after a re-seek the element runs at the controller rate, not at an old correction', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'timeline', t0: NET + h.now() - 30000, items: [{ url: 'https://cdn.example.com/1.mp3', duration: 600000 }] })
  emitter(e, 2, 1, 3)
  await run(h, 200)
  const el = h.audios[0]
  const m = html(h, el, 600)
  el.emit('canplay')
  await m.play(3000)
  el.currentTime = m.t() + 0.1
  await m.play(1200)
  assert.ok(Math.abs(el.playbackRate - 0.98) < 1e-9, '100 ms ahead → 2 % slower: ' + el.playbackRate)
  const deck = (e.sources.get(1)!.player as unknown as { cur: { deck: { ctrl: { seeks: number } } } }).cur.deck
  const before = deck.ctrl.seeks
  el.currentTime = m.t() - 2
  let rateAtSeek: number | null = null
  for (let i = 0; i < 200 && rateAtSeek === null; i++) {
    await m.play(10)
    if (deck.ctrl.seeks > before) rateAtSeek = el.playbackRate
  }
  assert.notEqual(rateAtSeek, null, 'it re-seeked')
  assert.equal(rateAtSeek, 1, 'the element runs at the controller rate (1) from the seek on, not at the stale 0.98')
})

test('F19: a looping item on a host without Range stops seeking, opens its gate and reloads once as a blob', async () => {
  const { h, e } = setup()
  let downloads = 0
  h.env.fetch = ((_url: string, init?: RequestInit) => Promise.resolve(streamResponse(init && init.signal, (c) => {
    downloads++
    c.enqueue(new Uint8Array(64))
    c.close()
  }))) as unknown as typeof fetch
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'timeline', loop: true, t0: NET + h.now() - 60000, items: [{ url: 'https://self-hosted.example.com/bed.mp3', duration: 240000 }] })
  emitter(e, 2, 1, 3)
  await run(h, 200)
  const el = h.audios[0]
  const m = html(h, el, 240, { loop: true, seekable: (src) => src.startsWith('blob:') })
  el.loop = true
  el.emit('canplay')
  let blobReady = false
  let httpsSeeks = 0
  let lastSets = 0
  for (let i = 0; i < 30; i++) {
    await m.play(1000)
    if (!el.src.startsWith('blob:')) httpsSeeks += m.sets() - lastSets
    lastSets = m.sets()
    if (el.src.startsWith('blob:') && !blobReady) {
      blobReady = true
      el.emit('canplay')
    }
  }
  const deck = (e.sources.get(1)!.player as unknown as { cur: { deck: { ctrl: { locked: boolean } } } }).cur.deck
  assert.ok(httpsSeeks <= 3, 'seek attempts on the Range-less URL: ' + httpsSeeks)
  assert.equal(downloads, 1, 'one blob download')
  assert.ok(blobReady, 'the blob replaced the URL')
  assert.equal(deck.ctrl.locked, true, 'and it locked (audible)')
  assert.equal(gateOf(h, el).gain.value, 1)
})

// ---------------------------------------------------------------- the end is the element's own

test('a guessed short duration (a host without Range reports 4 s for a 20 s file) does not stop a deck from joining', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'timeline', t0: NET + h.now() - 5000, items: [{ url: 'https://self-hosted.example.com/a.ogg', duration: 20000 }] })
  emitter(e, 2, 1, 3)
  await run(h, 200)
  const el = h.audios[0]
  html(h, el, 20)
  el.duration = 3.995
  el.emit('canplay')
  await run(h, 1000)
  const deck = (e.sources.get(1)!.player as unknown as { cur: { deck: { joined: boolean; ended: boolean } } }).cur.deck
  assert.equal(deck.joined, true, 'joined at the clock position')
  assert.equal(deck.ended, false)
  assert.ok(el.plays >= 1)
})

test('joining a one-shot after its real end holds at the end — it is never replayed from 0', async () => {
  const { h, e } = setup()
  feed(e, h)
  h.fetchBytes = 1300000
  e.handle('audio:source', { id: 1, type: 'clip', url: 'https://cdn.example.com/short.mp3', t0: NET + h.now() - 6000 })
  emitter(e, 2, 1, 3)
  await run(h, 400)
  const el = h.audios[0]
  const m = html(h, el, 4)
  el.emit('canplay')
  await m.play(2000)
  assert.equal(m.restarts(), 0)
  assert.equal(e.sources.get(1)!.status, 'ended')
})

// ---------------------------------------------------------------- trusted = false: never decoded

test('trusted = false: a clip never reaches the loader or the decoder — it plays through an element, exactly at t0', async () => {
  const { h, e } = setup()
  feed(e, h)
  const t0 = h.now() + 300
  e.handle('audio:source', { id: 1, type: 'clip', url: 'https://uploads.example.com/boom.ogg', t0: NET + t0, trusted: false })
  emitter(e, 2, 1, 3)
  await run(h, 200)
  const el = h.audios[0]
  assert.ok(el, 'an element (decoder slot granted at once)')
  const m = html(h, el, 0.5)
  let startedAt = -1
  const base = el.play.bind(el)
  el.play = () => {
    if (startedAt < 0) startedAt = h.now()
    return base()
  }
  el.emit('canplay')
  await m.play(1500)
  assert.equal(h.ctx.decodes, 0, 'decodeAudioData never called')
  assert.equal(e.loader!.downloads + e.loader!.probes, 0, 'not even downloaded or probed for a verdict')
  assert.ok(Math.abs(startedAt - t0) <= 10, 'launched at t0 (' + (startedAt - t0) + ' ms)')
  assert.equal(m.restarts(), 0)
  assert.equal(e.sources.get(1)!.status, 'ended', 'and it ends with its element')
})

test('trusted = false: a short one-shot the page loaded late still plays from its top (gate open at once)', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'clip', url: 'https://uploads.example.com/bell.ogg', t0: NET + h.now(), trusted: false })
  emitter(e, 2, 1, 3)
  await run(h, 400)
  const el = h.audios[0]
  const m = html(h, el, 0.4)
  el.emit('canplay')
  await m.play(100)
  assert.ok(el.plays >= 1, 'started although the clock is 400+ ms past t0')
  assert.equal(gateOf(h, el).gain.last('ramp')!.value, 1, 'no waiting for a lock: a 0.4 s sound would be over')
  assert.ok(m.t() < 0.2, 'from its top')
})

test('trusted = false: a loop plays through an element locked to the clock', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://uploads.example.com/amb.ogg', t0: NET + h.now() - 5000, trusted: false })
  emitter(e, 2, 1, 3)
  await run(h, 200)
  const el = h.audios[0]
  const m = html(h, el, 20, { loop: true })
  el.emit('canplay')
  await m.play(4000)
  const deck = (e.sources.get(1)!.player as unknown as { deck: { ctrl: { locked: boolean; lastError: number } } }).deck
  assert.equal(h.ctx.decodes, 0)
  assert.equal(deck.ctrl.locked, true, 'locked')
  assert.ok(Math.abs(deck.ctrl.lastError) < 0.05, 'in sync: ' + deck.ctrl.lastError)
  assert.equal(gateOf(h, el).gain.value, 1)
})

test('trusted flips are a content change: a buffer loop becomes an element one, and back', async () => {
  const { h, e } = setup()
  feed(e, h)
  const spec = { id: 1, type: 'loop', url: 'https://cdn.example.com/x.ogg', t0: NET + h.now() }
  e.handle('audio:source', spec)
  emitter(e, 2, 1, 3)
  await run(h, 600)
  assert.equal(h.ctx.decodes, 1)
  assert.equal(h.audios.length, 0)
  e.handle('audio:source', Object.assign({}, spec, { trusted: false }))
  await run(h, 800)
  assert.equal(e.sources.get(1)!.isDecoder(), true)
  assert.equal(h.audios.length, 1, 'now an element')
  assert.equal(h.ctx.decodes, 1, 'and nothing new decoded')
})
