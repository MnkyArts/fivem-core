// runtime/audio/sync.ts — u32 clock maths, the 10 s max-filter clock mapping, play heads, timelines,
// the one-shot rule, the drift controller and the currentTime fit (DESIGN §55.16; R6 §4.3–§4.5).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  DRIFT, DriftController, NetClock, TimeFit, U32, add32, clipStartable, diff32, mod, playHead,
  timelineAt, wrapError,
} from '../../src/runtime/audio/sync.ts'
import type { TimelinePos } from '../../src/runtime/audio/sync.ts'

const near = (a: number, b: number, eps = 1e-6) => Math.abs(a - b) <= eps

test('diff32 is a signed 32-bit difference, wrap-safe across 2^31 and 2^32', () => {
  assert.equal(diff32(10, 3), 7)
  assert.equal(diff32(3, 10), -7)
  assert.equal(diff32(5, U32 - 5), 10, 'across the u32 wrap')
  assert.equal(diff32(U32 - 5, 5), -10)
  assert.equal(diff32(2147483648 + 10, 2147483648 - 10), 20, 'across 2^31')
  assert.ok(near(diff32(100.25, 100), 0.25), 'fractional network times')
})

test('add32 wraps into [0, 2^32) and mod never goes negative', () => {
  assert.equal(add32(U32 - 1, 2), 1)
  assert.equal(add32(0, -1), U32 - 1)
  assert.equal(mod(-1, 10), 9)
  assert.equal(mod(25, 10), 5)
  assert.equal(mod(5, 0), 0)
})

test('wrapError takes the short way round a loop', () => {
  assert.ok(near(wrapError(9.9, 0.1, 10), -0.2))
  assert.ok(near(wrapError(0.1, 9.9, 10), 0.2))
  assert.ok(near(wrapError(5, 4, 10), 1))
})

test('NetClock: nothing before the first sample, then t - perf', () => {
  const c = new NetClock()
  assert.equal(c.synced(), false)
  assert.equal(c.now(100), null)
  c.sample(5000, 1000)
  assert.equal(c.synced(), true)
  assert.equal(c.offset(), 4000)
  assert.equal(c.now(1500), 5500, 'advances with performance.now()')
})

test('NetClock keeps the MAX offset: a delayed message never drags the clock back', () => {
  const c = new NetClock()
  c.sample(10000, 1000)
  c.sample(10050, 1080)  // arrived 30 ms late
  c.sample(10100, 1100)
  assert.equal(c.offset(), 9000)
  assert.equal(c.now(2000), 11000)
})

test('NetClock forgets samples older than 10 s (max over a sliding window)', () => {
  const c = new NetClock()
  c.sample(20000, 1000)          // offset 19000 (least delayed)
  c.sample(20990, 2000)          // offset 18990
  assert.equal(c.offset(), 19000)
  c.sample(30000, 11500)         // offset 18500; the 19000 sample is 10.5 s old now
  assert.equal(c.offset(), 18990)
  c.sample(40000, 23000)         // offset 17000 — nothing else within 10 s
  assert.equal(c.offset(), 17000)
})

test('NetClock after an idle gap keeps the newest sample (the feed is 0 Hz while the camera is still)', () => {
  const c = new NetClock()
  c.sample(50000, 1000)
  assert.equal(c.now(61000), 110000, 'no new sample: the last offset keeps mapping')
  assert.equal(c.held(), 1)
})

test('NetClock unwraps across 2^32: now() stays continuous', () => {
  const c = new NetClock()
  c.sample(U32 - 100, 1000)
  c.sample(50, 1150)
  assert.equal(c.offset(), U32 - 1100)
  assert.equal(c.now(1200), 100)
})

test('playHead = (net - t0) × rate + offset; paused freezes at pausedAt', () => {
  const s = { t0: 1000, rate: 1, paused: false, pausedAt: null, offset: 0 }
  assert.equal(playHead(s, 3500), 2500)
  assert.equal(playHead({ ...s, rate: 2 }, 3500), 5000)
  assert.equal(playHead({ ...s, offset: 250 }, 3500), 2750)
  assert.equal(playHead({ ...s, paused: true, pausedAt: 2000 }, 9000), 1000)
  assert.equal(playHead({ ...s, paused: true, pausedAt: null, offset: 700 }, 9000), 700, 'paused without a stamp = the offset')
  assert.equal(playHead({ ...s, t0: 5000 }, 4800), -200, 'a future t0 is a negative head')
  assert.equal(playHead({ ...s, t0: U32 - 1000 }, 500), 1500, 'across the wrap')
})

function pos(): TimelinePos {
  return { state: 0, index: 0, offset: 0, remaining: 0 }
}

test('timelineAt: pending, index + offset, the last item, ended, looping', () => {
  const d = [1000, 2000, 500]
  assert.deepEqual(timelineAt(d, -300, false, pos()), { state: -1, index: 0, offset: -300, remaining: 1300 })
  assert.deepEqual(timelineAt(d, 1500, false, pos()), { state: 0, index: 1, offset: 500, remaining: 1500 })
  assert.deepEqual(timelineAt(d, 3200, false, pos()), { state: 0, index: 2, offset: 200, remaining: 300 })
  assert.equal(timelineAt(d, 3500, false, pos()).state, 1)
  const looped = timelineAt(d, 3500 * 2 + 1200, true, pos())
  assert.equal(looped.state, 0)
  assert.equal(looped.index, 1)
  assert.equal(looped.offset, 200)
  assert.equal(timelineAt([], 10, true, pos()).state, 1)
})

test('one-shot rule: a late clip plays from Δ only while Δ < 30 % of it', () => {
  assert.equal(clipStartable(-100, 2000, false), true, 'not started yet')
  assert.equal(clipStartable(40, 100, false), true, '≤ 50 ms is always fine')
  assert.equal(clipStartable(500, 2000, false), true)
  assert.equal(clipStartable(700, 2000, false), false)
  assert.equal(clipStartable(1500, 2000, true), true, 'a clip heard before resumes at its elapsed time')
  assert.equal(clipStartable(1990, 2000, true), false, 'nothing left to play')
})

test('drift: inside the 25 ms dead band the rate is exactly 1', () => {
  const c = new DriftController(0)
  c.rate = 1.01
  assert.equal(c.decide(0.02, 100), 'rate')
  assert.equal(c.rate, 1)
  assert.equal(c.decide(-0.01, 300), 'none', 'no change → no action')
})

test('drift: 25 ms … 750 ms steers the rate by e / 4 s, clamped to ±2 %', () => {
  const c = new DriftController(0)
  assert.equal(c.decide(0.04, 100), 'rate')
  assert.ok(near(c.rate, 0.99), '40 ms ahead → 1 % slower')
  c.decide(-0.04, 300)
  assert.ok(near(c.rate, 1.01), '40 ms behind → 1 % faster')
  c.decide(0.5, 500)
  assert.ok(near(c.rate, 1 - DRIFT.rateLimit), 'clamped')
})

test('drift: ≥ 750 ms re-seeks, but not again within 1 s', () => {
  const c = new DriftController(0)
  assert.equal(c.decide(0.9, 100), 'seek')
  assert.equal(c.rate, 1)
  assert.equal(c.decide(-0.8, 600), 'none', 'still settling')
  assert.equal(c.decide(-0.8, 1200), 'seek')
  assert.equal(c.seeks, 2)
})

test('drift: locked after two good polls, or 4 s after the join (fail-open)', () => {
  const c = new DriftController(0)
  c.decide(0.2, 200)
  assert.equal(c.locked, false)
  c.decide(0.05, 400)
  assert.equal(c.locked, false, 'one good poll is not a lock')
  c.decide(-0.03, 600)
  assert.equal(c.locked, true)
  const slow = new DriftController(0)
  slow.decide(0.3, 3800)
  assert.equal(slow.locked, false)
  slow.decide(0.3, 4100)
  assert.equal(slow.locked, true, 'coarse seeks (VBR MP3) do not keep a source silent for ever')
})

test('drift: reset() unlocks and forgets for a fresh join', () => {
  const c = new DriftController(0)
  c.decide(0.01, 200)
  c.decide(0.01, 400)
  assert.equal(c.locked, true)
  c.reset(1000)
  assert.equal(c.locked, false)
  assert.equal(c.rate, 1)
  assert.equal(c.decide(0.9, 1100), 'seek', 'the settle time was reset too')
})

test('TimeFit recovers position and slope from noisy currentTime samples', () => {
  const f = new TimeFit()
  const jitter = [0.004, -0.003, 0.002, -0.004, 0.003, 0, -0.002, 0.001]
  for (let i = 0; i < 8; i++) f.add(1000 + i * 200, 10 + i * 0.2 * 1.02 + jitter[i])
  const at = f.at(2600, 1)
  assert.ok(at !== null && near(at, 10 + 1.6 * 1.02, 0.006), String(at))
})

test('TimeFit extrapolates with the rate below 3 samples and drops samples past 2 s', () => {
  const f = new TimeFit()
  assert.equal(f.at(0, 1), null)
  f.add(1000, 5)
  assert.ok(near(f.at(1500, 1) as number, 5.5))
  for (let i = 1; i <= 20; i++) f.add(1000 + i * 200, 5 + i * 0.2)
  assert.ok(f.size() <= 12, 'about 2 s of samples at 5 Hz')
})
