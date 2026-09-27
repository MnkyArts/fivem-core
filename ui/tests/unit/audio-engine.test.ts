// runtime/audio/{index,engine,mixer,sources,media}.ts over a recording fake Web Audio graph: lazy
// install, the k-rate wiring, voices real/virtual, budgets, fades before stop(), errors, idle suspend,
// occlusion, zones, HRTF, timelines and streams (DESIGN §55.16, §55.23).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { AudioEngine } from '../../src/runtime/audio/engine.ts'
import { installAudio } from '../../src/runtime/audio/index.ts'
import { inspectEmitter } from '../../src/runtime/audio/debug.ts'
import { deliver } from '../../src/runtime/transport.ts'
import { harness } from './audio-fakes.ts'
import type { FakeAudio, FakeBufferSource, FakeGain, FakeNode, FakePanner, Harness } from './audio-fakes.ts'

const NET = 5000000
const LISTENER = ['positionX', 'positionY', 'positionZ', 'forwardX', 'forwardY', 'forwardZ', 'upX', 'upY', 'upZ'] as const

function setup(): { h: Harness; e: AudioEngine } {
  const h = harness()
  return { h, e: new AudioEngine(h.env) }
}

/** A feed stamped with the network time that maps to now; the listener at (x, y, z) facing +Y. */
function feed(e: AudioEngine, h: Harness, extra?: Record<string, unknown>): void {
  e.handle('audio:feed', Object.assign({
    t: NET + h.now(), lx: 0, ly: 0, lz: 0, fx: 0, fy: 1, fz: 0, ux: 0, uy: 0, uz: 1,
  }, extra || {}))
}

function loop(e: AudioEngine, h: Harness, id: number, agoMs = 0, extra?: Record<string, unknown>): void {
  e.handle('audio:source', Object.assign({ id, type: 'loop', url: 'https://cdn.example.com/' + id + '.ogg', t0: NET + h.now() - agoMs }, extra || {}))
}

function emitter(e: AudioEngine, id: number, source: number, x: number, extra?: Record<string, unknown>): void {
  e.handle('audio:emitter', Object.assign({ id, source, x, y: 0, z: 0, range: 40, curve: 'linear', ref: 1 }, extra || {}))
}

async function pass(h: Harness): Promise<void> {
  h.advance(0)
  await h.settle()
  h.advance(0)
}

const priv = (e: AudioEngine) => e as unknown as { duck: FakeGain; reverb: { linkedState(): [boolean, boolean] } }

test('install: the engine chunk loads on the first audio:* message; no context before a source/emitter', async () => {
  const h = harness()
  let loads = 0
  let loaded: Promise<unknown> = Promise.resolve()
  const off = installAudio({
    env: () => h.env,
    importEngine: () => {
      loads++
      const p = import('../../src/runtime/audio/scene-audio.ts')
      loaded = p
      return p
    },
  })
  assert.equal(loads, 0, 'installing loads nothing')
  deliver({ action: 'audio:prefs', hrtf: false })
  deliver({ action: 'audio:debug', on: false })
  deliver({ action: 'audio:feed', t: 5, lx: 0, ly: 0, lz: 0 })
  deliver({ action: 'audio:remove', ids: [1] })
  assert.equal(loads, 1, 'one import for the whole burst')
  await loaded
  await h.settle()
  assert.equal(h.created(), 0, 'prefs/debug/feed/remove create no AudioContext')
  deliver({ action: 'audio:source', id: 1, type: 'loop', url: 'https://cdn.example.com/a.ogg', t0: 0 })
  assert.equal(h.created(), 1)
  deliver({ action: 'audio:emitter', id: 2, source: 1, x: 0, y: 0, z: 0 })
  assert.equal(h.created(), 1, 'one context for the life of the page')
  off()
  assert.equal(h.ctx.closed, true, 'the disposer closes it')
  deliver({ action: 'audio:source', id: 3, type: 'loop', url: 'https://cdn.example.com/b.ogg', t0: 0 })
  assert.equal(h.created(), 1, 'unsubscribed after dispose')
})

test('install: messages that arrive while the chunk loads are replayed in order', async () => {
  const h = harness()
  let loaded: Promise<unknown> = Promise.resolve()
  const off = installAudio({
    env: () => h.env,
    importEngine: () => {
      const p = import('../../src/runtime/audio/scene-audio.ts')
      loaded = p
      return p
    },
  })
  deliver({ action: 'audio:source', id: 1, type: 'loop', url: 'https://cdn.example.com/a.ogg', t0: 0 })
  deliver({ action: 'audio:emitter', id: 2, source: 1, x: 0, y: 0, z: 0 })
  deliver({ action: 'audio:remove', ids: [2] })
  assert.equal(h.created(), 0, 'nothing before the chunk is there')
  await loaded
  await h.settle()
  assert.equal(h.created(), 1, 'the queued source built the context')
  off()
})

test('a bad payload is ignored without touching Web Audio', () => {
  const { h, e } = setup()
  e.handle('audio:source', { id: 'x' })
  e.handle('audio:emitter', { id: 1 })
  e.handle('audio:nonsense', {})
  assert.equal(h.created(), 0)
  assert.equal(e.sources.size + e.emitters.size, 0)
})

test('context: all nine listener params k-rate; buses → master → duck → limiter → destination', () => {
  const { h, e } = setup()
  emitter(e, 1, 1, 0)
  for (const k of LISTENER) assert.equal(h.ctx.listener[k].automationRate, 'k-rate', k)
  const limiter = h.ctx.of('compressor')[0]
  assert.ok(limiter.outputs.has(h.ctx.destination))
  for (const cat of ['music', 'sfx', 'ambience', 'voice'] as const) {
    assert.ok((e.bus(cat) as unknown as FakeNode).reaches(limiter), cat + ' bus reaches the limiter')
    assert.ok((e.sendBus(cat) as unknown as FakeNode).reaches(limiter), cat + ' reverb send reaches the limiter')
  }
})

test('one loop through one voice: k-rate panner, rolloff 0, sample-exact start at head mod duration', async () => {
  const { h, e } = setup()
  h.ctx.decodeSeconds = 2
  feed(e, h)
  loop(e, h, 10, 1500)
  emitter(e, 20, 10, 3, { y: 4 })
  await pass(h)
  assert.equal(e.mixer.counts().real, 1)
  const info = inspectEmitter(e, 20) as { voice: { pannerRates: string[]; filterRates: string[]; rolloff: number; model: string; level: number }; listenerRates: string[] }
  assert.deepEqual(info.voice.pannerRates, ['k-rate', 'k-rate', 'k-rate', 'k-rate', 'k-rate', 'k-rate'])
  assert.deepEqual(info.voice.filterRates, ['k-rate', 'k-rate'])
  assert.equal(info.voice.rolloff, 0)
  assert.equal(info.voice.model, 'equalpower')
  assert.ok(info.listenerRates.every((r) => r === 'k-rate'))
  assert.ok(Math.abs(info.voice.level - (1 - 4 / 39)) < 1e-9, 'linear curve at 5 m of 40 (ref 1)')
  const node = h.ctx.of<FakeBufferSource>('bufferSource')[0]
  assert.ok(node && node.started, 'the buffer node started')
  assert.equal(node.loop, true)
  assert.ok(Math.abs(node.started.offset - 1.53) < 1e-6, 'head 1500 ms + 30 ms lead, mod 2 s: ' + node.started.offset)
  const out = e.sources.get(10)!.out as unknown as FakeNode
  assert.ok(out.reaches(e.bus('sfx') as unknown as FakeNode), 'fan-out → voice → the sfx bus')
  const panner = h.ctx.of<FakePanner>('panner').filter((p) => p.inputs.size > 0)[0]
  assert.equal(panner.positionX.value, 3)
  assert.equal(panner.positionY.value, 4)
})

test('nothing starts before the clock: the node waits for the first stamped feed', async () => {
  const { h, e } = setup()
  e.handle('audio:feed', { lx: 0, ly: 0, lz: 0, fx: 0, fy: 1, fz: 0 })
  loop(e, h, 10)
  emitter(e, 20, 10, 2)
  await pass(h)
  assert.equal(e.mixer.counts().real, 1, 'the voice may already be real')
  assert.equal(h.ctx.of<FakeBufferSource>('bufferSource').length, 0, '… but no play head without the clock')
  feed(e, h)
  h.advance(200)
  assert.equal(h.ctx.of<FakeBufferSource>('bufferSource').length, 1)
})

test('voice budget: maxVoices 2 of 5 emitters — the nearest are real, the rest virtual', async () => {
  const { h, e } = setup()
  e.handle('audio:prefs', { maxVoices: 2 })
  feed(e, h)
  for (let i = 0; i < 5; i++) {
    loop(e, h, 100 + i)
    emitter(e, 200 + i, 100 + i, 3 + i * 4)
  }
  await pass(h)
  const c = e.mixer.counts()
  assert.equal(c.real, 2)
  assert.equal(c.virtual, 3)
  assert.equal((inspectEmitter(e, 200) as { real: boolean }).real, true)
  assert.equal((inspectEmitter(e, 201) as { real: boolean }).real, true)
  assert.equal((inspectEmitter(e, 204) as { real: boolean }).real, false)
})

test('per source at most 4 real voices; out of range never real', async () => {
  const { h, e } = setup()
  feed(e, h)
  loop(e, h, 1)
  for (let i = 0; i < 6; i++) emitter(e, 10 + i, 1, 2 + i)
  emitter(e, 30, 1, 60)
  await pass(h)
  assert.equal(e.mixer.counts().real, 4)
  assert.equal((inspectEmitter(e, 30) as { real: boolean; level: number }).level, 0)
})

test('remove: the voice fades over fadeMs, is disposed after it, and the node stops AFTER its ramp', async () => {
  const { h, e } = setup()
  feed(e, h)
  loop(e, h, 1)
  emitter(e, 2, 1, 3)
  await pass(h)
  const node = h.ctx.of<FakeBufferSource>('bufferSource')[0]
  const fader = h.ctx.of<FakePanner>('panner')[0].inputs.values().next().value as unknown as FakeGain
  const t0 = h.ctx.currentTime
  e.handle('audio:remove', { ids: [2], fadeMs: 300 })
  const ramp = fader.gain.last('ramp')!
  assert.equal(ramp.value, 0)
  assert.ok(Math.abs(ramp.time - (t0 + 0.3)) < 1e-9, 'ramp to 0 over 300 ms')
  assert.equal(e.emitters.has(2), false)
  assert.equal(e.dying.size, 1)
  h.advance(330)
  assert.equal(e.dying.size, 1, 'still fading')
  h.advance(20)
  assert.equal(e.dying.size, 0, 'released after the ramp')
  assert.equal(fader.outputs.size, 0, 'disconnected')
  h.advance(5)
  assert.ok(node.stopped !== null && node.stopped >= t0 + 0.3, 'stop() only after the fade: ' + node.stopped)
})

test('removing a source fades its voices and disconnects its fan-out after the fade', async () => {
  const { h, e } = setup()
  feed(e, h)
  loop(e, h, 1)
  emitter(e, 2, 1, 3)
  await pass(h)
  const out = e.sources.get(1)!.out as unknown as FakeGain
  e.handle('audio:remove', { ids: [1], fadeMs: 100 })
  assert.equal(e.sources.has(1), false)
  assert.equal(out.gain.last('ramp')!.value, 0)
  h.advance(300)
  assert.equal(out.outputs.size, 0)
  assert.equal(e.mixer.counts().real, 0, 'the emitter stays, virtual, waiting for a source')
  assert.equal(e.emitters.size, 1)
})

test('feed: paused ducks the master to 0 over 200 ms and back; volumes approach the buses', async () => {
  const { h, e } = setup()
  emitter(e, 1, 1, 0)
  const duck = priv(e).duck
  const t = h.ctx.currentTime
  feed(e, h, { paused: true, music: 0.5, master: 0.8 })
  assert.equal(duck.gain.last('ramp')!.value, 0)
  assert.ok(Math.abs(duck.gain.last('ramp')!.time - (t + 0.2)) < 1e-9)
  assert.equal((e.bus('music') as unknown as FakeGain).gain.last('target')!.value, 0.5)
  assert.equal(e.vol.master, 0.8)
  feed(e, h, { paused: false })
  assert.equal(duck.gain.last('ramp')!.value, 1)
})

test('feed: the environment picks the reverb (interior small room, outdoors large, car/underwater dry)', () => {
  const { h, e } = setup()
  emitter(e, 1, 1, 0)
  assert.equal(e.reverbMode, 'large')
  feed(e, h, { env: { interior: 5 } })
  assert.equal(e.reverbMode, 'small')
  assert.deepEqual(priv(e).reverb.linkedState(), [true, true], 'both linked during the crossfade')
  h.advance(600)
  assert.deepEqual(priv(e).reverb.linkedState(), [true, false], 'the silent convolver is unlinked')
  feed(e, h, { env: { interior: 5, vehicle: true } })
  assert.equal(e.reverbMode, 'dry')
})

test('a clip first heard later than 30 % of it never starts; one within 30 % starts at Δ with a fade', async () => {
  const late = setup()
  feed(late.e, late.h)
  late.e.handle('audio:source', { id: 1, type: 'clip', url: 'https://cdn.example.com/c.ogg', t0: NET + late.h.now() - 600 })
  emitter(late.e, 2, 1, 2)
  await pass(late.h)
  assert.equal(late.e.sources.get(1)!.status, 'ended')
  assert.equal(late.h.ctx.of<FakeBufferSource>('bufferSource').length, 0)
  const ok = setup()
  feed(ok.e, ok.h)
  ok.e.handle('audio:source', { id: 1, type: 'clip', url: 'https://cdn.example.com/c.ogg', t0: NET + ok.h.now() - 200 })
  emitter(ok.e, 2, 1, 2)
  await pass(ok.h)
  const node = ok.h.ctx.of<FakeBufferSource>('bufferSource')[0]
  assert.ok(node && node.started && Math.abs(node.started.offset - 0.23) < 1e-6)
  assert.equal(node.loop, false)
  node.end()
  assert.equal(ok.e.sources.get(1)!.status, 'ended', 'onended ends the one-shot')
})

test('errors: decode failure and a bad URL reach Lua as audio:error { id, code }, rate-limited', async () => {
  const { h, e } = setup()
  h.ctx.decodeFail = true
  feed(e, h)
  loop(e, h, 1)
  emitter(e, 2, 1, 2)
  await pass(h)
  assert.deepEqual(h.reports.filter((r) => r.event === 'error').map((r) => r.data), [{ id: 1, code: 'decode_failed' }])
  assert.equal(e.sources.get(1)!.status, 'failed')
  e.handle('audio:source', { id: 9, type: 'clip', url: 'ftp://files.example.com/a.mp3' })
  assert.deepEqual(h.reports[h.reports.length - 1].data, { id: 9, code: 'bad_url' })
  const before = h.reports.length
  e.error(9, 'bad_url')
  assert.equal(h.reports.length, before, 'the same id + code within 10 s is not repeated')
  for (let i = 0; i < 10; i++) e.error(100 + i, 'fetch_failed')
  assert.equal(h.reports.length - before, 3, '≤ 5 per second overall (2 were already used)')
})

test('debug: audio:stats once per second while on, silent when off', () => {
  const { h, e } = setup()
  e.handle('audio:debug', { on: true })
  assert.equal(h.reports.filter((r) => r.event === 'stats').length, 1)
  h.advance(2100)
  assert.equal(h.reports.filter((r) => r.event === 'stats').length, 3)
  const s = h.reports[h.reports.length - 1].data as { voices: { max: number }; clock: { synced: boolean } }
  assert.equal(s.voices.max, 32)
  assert.equal(s.clock.synced, false)
  e.handle('audio:debug', { on: false })
  h.advance(3000)
  assert.equal(h.reports.filter((r) => r.event === 'stats').length, 3)
})

test('idle: with nothing left the tick stops and the context is suspended after 15 s; a message wakes it', async () => {
  const { h, e } = setup()
  feed(e, h)
  loop(e, h, 1)
  emitter(e, 2, 1, 2)
  await pass(h)
  e.handle('audio:remove', { ids: [1, 2], fadeMs: 50 })
  h.advance(400)
  assert.equal(h.pendingTimers(), 1, 'only the idle countdown remains')
  h.advance(15000)
  assert.equal(h.ctx.suspends, 1)
  assert.equal(h.pendingTimers(), 0, 'idle = zero timers')
  loop(e, h, 3)
  assert.equal(h.ctx.state, 'running')
})

test('moving emitters ramp their panner over the feed interval (k-rate linear ramps, no steps)', async () => {
  const { h, e } = setup()
  feed(e, h)
  loop(e, h, 1)
  emitter(e, 2, 1, 5)
  await pass(h)
  h.advance(50)
  const panner = h.ctx.of<FakePanner>('panner')[0]
  const t = h.ctx.currentTime
  feed(e, h, { moving: { n2: { x: 6, y: 1, z: 0 } } })
  const r = panner.positionX.last('ramp')!
  assert.equal(r.value, 6)
  assert.ok(Math.abs(r.time - (t + 0.05)) < 1e-9, 'over the 50 ms since the last feed')
  assert.equal(panner.positionY.last('ramp')!.value, 1)
})

test('the listener moves by ramps too, extrapolated by its velocity', () => {
  const { h, e } = setup()
  emitter(e, 1, 1, 0)
  feed(e, h)
  h.advance(50)
  feed(e, h, { lx: 10, vx: 20, vy: 0, vz: 0 })
  const r = h.ctx.listener.positionX.last('ramp')!
  assert.ok(Math.abs((r.value as number) - 11) < 1e-9, 'x + v·T = 10 + 20 × 0.05')
})

test('occlusion lowers the level (≤ -15 dB) and closes the lowpass', async () => {
  const { h, e } = setup()
  feed(e, h)
  loop(e, h, 1)
  emitter(e, 2, 1, 3)
  await pass(h)
  const open = inspectEmitter(e, 2) as { level: number; voice: { cutoff: number } }
  feed(e, h, { occl: { n2: 1 } })
  const shut = inspectEmitter(e, 2) as { level: number; voice: { cutoff: number } }
  assert.ok(Math.abs(shut.level / open.level - Math.pow(10, -15 / 20)) < 1e-9)
  assert.ok(shut.voice.cutoff < 500 && open.voice.cutoff > 15000)
  emitter(e, 2, 1, 3, { occlusion: false })
  feed(e, h, { occl: { n2: 1 } })
  assert.ok(Math.abs((inspectEmitter(e, 2) as { level: number }).level - open.level) < 1e-9, 'occlusion = false ignores it')
})

test('a zone fills the room: inside, full level and the voice sits on the listener', async () => {
  const { h, e } = setup()
  feed(e, h, { lx: 3, ly: 3 })
  loop(e, h, 1)
  emitter(e, 2, 1, 100, { range: 30, zone: { type: 'sphere', coords: { x: 0, y: 0, z: 0 }, radius: 10 } })
  await pass(h)
  const info = inspectEmitter(e, 2) as { dist: number; level: number; real: boolean }
  assert.equal(info.dist, 0)
  assert.equal(info.level, 1)
  assert.equal(info.real, true)
  const panner = h.ctx.of<FakePanner>('panner')[0]
  assert.equal(panner.positionX.value, 3)
  assert.equal(panner.positionY.value, 3)
})

test('HRTF: after the database warm-up the nearest voices switch model behind a 30 ms dip', async () => {
  const { h, e } = setup()
  e.handle('audio:prefs', { hrtf: true, hrtfVoices: 1 })
  feed(e, h)
  loop(e, h, 1)
  loop(e, h, 2)
  emitter(e, 10, 1, 2)
  emitter(e, 11, 2, 8)
  await pass(h)
  h.advance(1200)
  h.advance(100)
  const near = (inspectEmitter(e, 10) as { voice: { model: string } }).voice.model
  const far = (inspectEmitter(e, 11) as { voice: { model: string } }).voice.model
  assert.equal(near, 'HRTF')
  assert.equal(far, 'equalpower')
  e.handle('audio:prefs', { hrtf: false })
  h.advance(300)
  assert.equal((inspectEmitter(e, 10) as { voice: { model: string } }).voice.model, 'equalpower')
})

test('a station switch fades the old chain out and builds a new one on the new source', async () => {
  const { h, e } = setup()
  feed(e, h)
  loop(e, h, 1)
  loop(e, h, 2)
  emitter(e, 10, 1, 2)
  await pass(h)
  const first = h.ctx.of<FakePanner>('panner')[0]
  emitter(e, 10, 2, 2)
  await pass(h)
  const panners = h.ctx.of<FakePanner>('panner')
  assert.equal(panners.length, 2, 'a second chain, not the old one revived')
  assert.ok((e.sources.get(2)!.out as unknown as FakeNode).reaches(panners[1]))
  h.advance(600)
  assert.equal(first.outputs.size, 0, 'the old chain is gone after its fade')
})

/** Drives `el` as a playing element: its currentTime follows `pos()` in 10 ms steps. */
function play(h: Harness, el: FakeAudio, ms: number, pos: () => number): void {
  for (let t = 0; t < ms; t += 10) {
    el.currentTime = pos()
    h.advance(10)
  }
}

function gateOf(h: Harness, el: FakeAudio): FakeGain {
  const media = h.ctx.of('media').filter((n) => (n as unknown as { mediaElement: FakeAudio }).mediaElement === el)[0]
  return media.outputs.values().next().value as unknown as FakeGain
}

test('timeline: one element per item (crossOrigin anonymous), next item preloaded, joins at the clock', async () => {
  const { h, e } = setup()
  feed(e, h)
  const t0perf = h.now() - 3000
  e.handle('audio:source', {
    id: 1, type: 'timeline', t0: NET + t0perf,
    items: [{ url: 'https://cdn.example.com/1.mp3', duration: 10000 }, { url: 'https://cdn.example.com/2.mp3', duration: 10000 }],
  })
  emitter(e, 2, 1, 2)
  await pass(h)
  assert.equal(h.audios.length, 2, 'the current item and the next (< 15 s before it starts)')
  const el = h.audios[0]
  assert.equal(el.crossOrigin, 'anonymous')
  assert.equal(el.preload, 'auto')
  assert.equal(el.src, 'https://cdn.example.com/1.mp3', 'an https host streams directly (Range)')
  assert.equal(h.audios[1].src, 'https://cdn.example.com/2.mp3')
  assert.equal(gateOf(h, el).gain.value, 0, 'muted until the first lock')
  el.readyState = 4
  el.emit('canplay')
  h.advance(200)
  const expected = () => (h.now() - t0perf) / 1000
  assert.ok(Math.abs(el.currentTime - (expected() + 0.12)) < 0.25, 'joined at the clock position + the seek lead: ' + el.currentTime)
  el.emit('seeked')
  assert.equal(el.paused, false)
  play(h, el, 800, expected)
  assert.equal(gateOf(h, el).gain.last('ramp')!.value, 1, 'locked → the gate opens over 300 ms')
  play(h, el, 600, () => expected() + 0.1)
  assert.ok(Math.abs(el.playbackRate - 0.98) < 1e-9, '100 ms ahead → 2 % slower (pitch preserved): ' + el.playbackRate)
  const deck = (e.sources.get(1)!.player as unknown as { cur: { deck: { ctrl: { seeks: number } } } }).cur.deck
  play(h, el, 1600, () => expected() - 1.5)
  assert.ok(deck.ctrl.seeks >= 1, 'far behind → a re-seek behind the dip')
})

test('timeline: a resource file is fetched whole into a blob URL (cfx-nui has no Range support)', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'timeline', t0: NET + h.now(), items: [{ file: '@club/set.ogg', duration: 600000 }] })
  emitter(e, 2, 1, 2)
  await pass(h)
  assert.ok(h.fetches.includes('https://cfx-nui-club/set.ogg'))
  assert.ok(h.audios[0].src.startsWith('blob:'), h.audios[0].src)
})

test('decoders: ≤ Decoders streams/timelines at once, the nearest win; one just past range warms up', async () => {
  const { h, e } = setup()
  e.handle('audio:prefs', { decoders: 2 })
  feed(e, h)
  for (let i = 0; i < 4; i++) {
    e.handle('audio:source', { id: 10 + i, type: 'stream', url: 'https://radio.example.com/' + i + '.ogg' })
    emitter(e, 20 + i, 10 + i, 5 + i * 5)
  }
  await pass(h)
  assert.equal(h.audios.length, 2, 'two decoders')
  assert.deepEqual(h.audios.map((a) => a.src), ['https://radio.example.com/0.ogg', 'https://radio.example.com/1.ogg'])
  const warm = setup()
  feed(warm.e, warm.h)
  warm.e.handle('audio:source', { id: 1, type: 'stream', url: 'https://radio.example.com/x.ogg' })
  emitter(warm.e, 2, 1, 50)
  await pass(warm.h)
  assert.equal(warm.e.sources.get(1)!.active, true, '10 m past a 40 m range: decoding already (warm-up)')
  assert.equal(warm.e.mixer.counts().real, 0, '… but not audible yet')
})

test('streams: Ogg (and MP3 without MSE) play through <audio src>; the gate opens on playing', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'stream', url: 'https://radio.example.com/live', kind: 'mp3' })
  emitter(e, 2, 1, 3)
  await pass(h)
  const el = h.audios[0]
  assert.equal(el.src, 'https://radio.example.com/live')
  assert.equal(el.crossOrigin, 'anonymous')
  assert.equal(el.plays, 1)
  assert.equal(e.sources.get(1)!.status, 'loading')
  el.emit('playing')
  assert.equal(e.sources.get(1)!.status, 'ready')
  assert.equal(gateOf(h, el).gain.last('ramp')!.value, 1)
})

test('streams: a stall of 10 s reloads to the live edge with backoff; streams=false plays none', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'stream', url: 'https://radio.example.com/live.ogg' })
  emitter(e, 2, 1, 3)
  await pass(h)
  const el = h.audios[0]
  el.emit('playing')
  el.currentTime = 1
  h.advance(10500)
  h.advance(1100)
  await h.settle()
  assert.equal(el.plays, 2, 'reloaded after the 1 s backoff (the URL is re-checked first)')
  const off = setup()
  off.e.handle('audio:prefs', { streams: false })
  feed(off.e, off.h)
  off.e.handle('audio:source', { id: 1, type: 'stream', url: 'https://radio.example.com/live.ogg' })
  emitter(off.e, 2, 1, 3)
  await pass(off.h)
  assert.equal(off.h.audios.length, 0)
})

test('a decoder that loses its slot is torn down (element src dropped after the fade)', async () => {
  const { h, e } = setup()
  e.handle('audio:prefs', { decoders: 1 })
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'stream', url: 'https://radio.example.com/a.ogg' })
  emitter(e, 2, 1, 30)
  await pass(h)
  const first = h.audios[0]
  e.handle('audio:source', { id: 3, type: 'stream', url: 'https://radio.example.com/b.ogg' })
  emitter(e, 4, 3, 1)
  h.advance(3200)
  await h.settle()
  h.advance(400)
  assert.equal(first.src, '', 'the far stream released its decoder')
  assert.equal(h.audios[h.audios.length - 1].src, 'https://radio.example.com/b.ogg')
})

test('dispose closes the context and forgets everything', async () => {
  const { h, e } = setup()
  feed(e, h)
  loop(e, h, 1)
  emitter(e, 2, 1, 2)
  await pass(h)
  e.dispose()
  assert.equal(h.ctx.closed, true)
  assert.equal(e.sources.size + e.emitters.size, 0)
  e.handle('audio:emitter', { id: 5, source: 1, x: 0, y: 0, z: 0 })
  assert.equal(h.created(), 1, 'a disposed engine never builds a second context')
})

test('buffer heads map context time through getOutputTimestamp; nothing is scheduled while the device starts', () => {
  const { h, e } = setup()
  let ts = { contextTime: 0.0003, performanceTime: 0 }
  ;(h.ctx as unknown as { getOutputTimestamp: () => typeof ts }).getOutputTimestamp = () => ts
  emitter(e, 1, 1, 0)
  feed(e, h)
  const spec = { t0: NET + h.now() - 1000, rate: 1, paused: false, pausedAt: null, offset: 0 }
  assert.equal(e.headAtCtx(spec, 0.05), null, 'the output clock is not running yet')
  ts = { contextTime: 0.05, performanceTime: h.now() }
  assert.equal(e.headAtCtx(spec, 0.08), null, 'the first callbacks (contextTime ≤ 300 ms) are not trusted')
  ts = { contextTime: 2, performanceTime: h.now() + 50 }
  // context time 2.1 s is heard at now + 150 ms → 1150 ms into the sound
  assert.ok(Math.abs((e.headAtCtx(spec, 2.1) as number) - 1150) < 1e-6)
  e.handle('audio:prefs', { offsetMs: 40 })
  assert.ok(Math.abs((e.headAtCtx(spec, 2.1) as number) - 1190) < 1e-6, 'the player offset renders ahead')
  e.handle('audio:prefs', { offsetMs: 0 })
  ts = { contextTime: 0, performanceTime: 0 }
  h.advance(1100)
  const at = h.ctx.currentTime + 0.03
  assert.ok(Math.abs((e.headAtCtx(spec, at) as number) - 2130) < 1e-6, 'after 1 s without a usable pair the render clock is used')
})

test('the seek lead is learned: a join that lands 50 ms ahead shortens the next one', async () => {
  const { h, e } = setup()
  feed(e, h)
  const t0perf = h.now() - 3000
  e.handle('audio:source', { id: 1, type: 'timeline', t0: NET + t0perf, items: [{ url: 'https://cdn.example.com/1.mp3', duration: 60000 }] })
  emitter(e, 2, 1, 2)
  await pass(h)
  const el = h.audios[0]
  el.readyState = 4
  el.emit('canplay')
  h.advance(200)
  el.emit('seeked')
  const seek = (e as unknown as { senv: { seek: { lead: number } } }).senv.seek
  assert.equal(seek.lead, 0.06)
  play(h, el, 800, () => (h.now() - t0perf) / 1000 + 0.05)
  // the helper sets currentTime up to 10 ms before each tick, so the settled error reads 40–50 ms
  assert.ok(seek.lead > 0.06 - 0.05 * 0.7 - 0.002 && seek.lead < 0.06 - 0.04 * 0.7 + 0.002, 'lead ' + seek.lead)
})

test('timeline with a future t0: the element waits paused at 0 and plays exactly at t0, already locked', async () => {
  const { h, e } = setup()
  feed(e, h)
  const startPerf = h.now() + 650  // between two 200 ms ticks (1600, 1800)
  e.handle('audio:source', { id: 1, type: 'timeline', t0: NET + startPerf, items: [{ url: 'https://cdn.example.com/drop.mp3', duration: 30000 }] })
  emitter(e, 2, 1, 2)
  await pass(h)
  const el = h.audios[0]
  el.readyState = 4
  el.emit('canplay')
  h.advance(250)
  assert.equal(el.paused, true, 'held before t0')
  assert.equal(el.plays, 0)
  h.advance(startPerf - h.now() + 1)
  assert.equal(el.paused, false, 'launched at t0 by the boundary timer, not by the next 200 ms tick')
  assert.ok(el.currentTime < 0.05, 'from the top, no seek')
  assert.equal(gateOf(h, el).gain.last('ramp')!.value, 1, 'an exact start is audible at once (edge fade)')
  const d = e.sources.get(1)!.player!.drift()!
  assert.equal(d.locked, true)
})
