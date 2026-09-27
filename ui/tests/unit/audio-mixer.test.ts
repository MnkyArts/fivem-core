// Review RV3 regressions, the engine and the mixing pass (DESIGN §55.16): a cone follows the heading
// the node sends — in `audio:emitter` and in `moving` (F11); voice sources (Mumble's, §55.17) never
// start the AudioContext or a timer (F12); nothing downloads for a source nobody can hear (F17).
// Every test FAILS on the engine as first delivered.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { AudioEngine } from '../../src/runtime/audio/engine.ts'
import { inspectEmitter } from '../../src/runtime/audio/debug.ts'
import { harness } from './audio-fakes.ts'
import type { Harness } from './audio-fakes.ts'

const NET = 5000000

function setup(): { h: Harness; e: AudioEngine } {
  const h = harness()
  return { h, e: new AudioEngine(h.env) }
}

function feed(e: AudioEngine, h: Harness, extra?: Record<string, unknown>): void {
  e.handle('audio:feed', Object.assign({ t: NET + h.now(), lx: 0, ly: 0, lz: 0, fx: 0, fy: 1, fz: 0, ux: 0, uy: 0, uz: 1 }, extra || {}))
}

async function run(h: Harness, ms: number): Promise<void> {
  for (let t = 0; t < ms; t += 200) {
    h.advance(200)
    await h.settle()
  }
}

const level = (e: AudioEngine, id: number) => (inspectEmitter(e, id) as { level: number }).level

test('F11: a cone faces the heading the node sends and follows it in `moving`', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'loop', url: 'https://cdn.example.com/pa.ogg', t0: NET + h.now() })
  // a PA horn 10 m north of the listener, facing south (heading 180°) — at the listener
  e.handle('audio:emitter', {
    id: 2, source: 1, x: 0, y: 10, z: 0, range: 60, curve: 'linear', ref: 1, rz: 180,
    cone: { inner: 90, outer: 180, outerGain: 0.25 },
  })
  await run(h, 400)
  const facing = level(e, 2)
  // the car it is mounted on turns north: the horn now points away from the listener
  feed(e, h, { moving: { n2: { x: 0, y: 10, z: 0, rz: 0 } } })
  const away = level(e, 2)
  assert.ok(facing > 0, 'audible')
  assert.ok(Math.abs(away / facing - 0.25) < 1e-6, 'behind the cone: outerGain (' + (away / facing).toFixed(3) + ')')
})

test('F12: a voice source and its emitters never start the AudioContext or a timer', async () => {
  const { h, e } = setup()
  feed(e, h)
  e.handle('audio:source', { id: 1, type: 'voice' })
  e.handle('audio:emitter', { id: 2, source: 1, x: 0, y: 0, z: 0 })
  e.handle('audio:emitter', { id: 3, source: 1, x: 5, y: 0, z: 0 })
  await run(h, 1000)
  assert.equal(h.created(), 0, 'no AudioContext for Mumble-rendered speakers')
  assert.equal(h.pendingTimers(), 0, 'no tick')
  assert.equal(e.emitters.size, 2, 'remembered all the same')
})

test('F17: no decoder — no download — for a stream nobody can hear; it starts when the volume returns', async () => {
  const { h, e } = setup()
  feed(e, h, { music: 0 })
  e.handle('audio:source', { id: 1, type: 'stream', url: 'https://radio.example.com/live.ogg' })
  e.handle('audio:emitter', { id: 2, source: 1, x: 3, y: 0, z: 0, range: 40, curve: 'linear', ref: 1 })
  await run(h, 1000)
  assert.equal(h.audios.length, 0, 'music slider at 0: nothing decodes')
  assert.equal(h.fetches.length, 0)
  feed(e, h, { music: 0.6 })
  await run(h, 600)
  assert.equal(h.audios.length, 1, 'the slider comes back: the stream starts')
})
