// runtime/audio/curves.ts — distance curves (0 at range, GTA's table), cones, occlusion, air, zones
// (DESIGN §55.16, §55.23; R3 §8.2, R6 §1.3, §2.3, §3.2).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  GTA_CURVE, GTA_SILENT, airCutoff, coneGain, curveGain, dbToGain, gainToDb, gameTable, insidePolygon,
  isBehind, occlusionCutoff, occlusionGain, scoreDb, zoneNearest,
} from '../../src/runtime/audio/curves.ts'
import type { ZoneShape } from '../../src/runtime/audio/types.ts'

const near = (a: number, b: number, eps = 1e-6) => Math.abs(a - b) <= eps

test('dB <-> gain round trip, and silence maps to a very low dB', () => {
  for (const db of [-60, -14, -3, 0, 6]) assert.ok(near(gainToDb(dbToGain(db)), db, 1e-9))
  assert.ok(near(dbToGain(-20), 0.1))
  assert.equal(gainToDb(0), -240)
})

test("GTA's table points hold exactly (R3 §8.2)", () => {
  for (const [d, db] of GTA_CURVE) assert.ok(near(gainToDb(gameTable(d)), db, 1e-9), d + ' m → ' + db + ' dB')
})

test('GTA plateau is 0 dB inside 5 m and silent from 128 m', () => {
  assert.equal(gameTable(0), 1)
  assert.equal(gameTable(2.5), 1)
  assert.equal(gameTable(GTA_SILENT), 0)
  assert.equal(gameTable(500), 0)
  const at110 = gameTable(110)
  assert.ok(at110 > 0 && at110 < dbToGain(-76), 'between 100 m and 128 m it keeps falling')
})

test('GTA table interpolates in dB between points (15 m = -22.5 dB)', () => {
  assert.ok(near(gainToDb(gameTable(15)), -22.5, 1e-9))
  assert.ok(near(gainToDb(gameTable(30)), -40, 1e-9))
})

test("curve 'game' keeps the table points below 0.8 × range (range 600)", () => {
  for (const [d, db] of GTA_CURVE) {
    if (d < 5) continue
    assert.ok(near(gainToDb(curveGain('game', d, 2, 600)), db, 1e-9), d + ' m')
  }
})

test('every curve is EXACTLY 0 at range and beyond, and > 0 just inside', () => {
  for (const curve of ['game', 'inverse', 'linear'] as const) {
    for (const range of [10, 40, 100]) {
      assert.equal(curveGain(curve, range, 2, range), 0, curve + ' at range ' + range)
      assert.equal(curveGain(curve, range + 5, 2, range), 0)
      assert.ok(curveGain(curve, range - 0.5, 2, range) > 0, curve + ' just inside ' + range)
    }
  }
})

test('every curve is monotonically non-increasing and continuous (no step at the window)', () => {
  for (const curve of ['game', 'inverse', 'linear'] as const) {
    let prev = curveGain(curve, 0, 2, 40)
    for (let d = 0.25; d <= 40; d += 0.25) {
      const g = curveGain(curve, d, 2, 40)
      assert.ok(g <= prev + 1e-12, curve + ' rises at ' + d)
      assert.ok(prev - g < 0.2, curve + ' jumps at ' + d)
      prev = g
    }
  }
})

test("curve 'linear' is 1 up to ref and 0.5 half way to range", () => {
  assert.equal(curveGain('linear', 1, 2, 42), 1)
  assert.ok(near(curveGain('linear', 22, 2, 42), 0.5))
})

test("curve 'inverse' is ref/d near the source and tapers to 0 (FMOD inverse tapered)", () => {
  assert.equal(curveGain('inverse', 1, 2, 600), 1)
  assert.ok(near(curveGain('inverse', 4, 2, 600), 0.5, 1e-3))
  const x = (590 - 2) / 598
  assert.ok(near(curveGain('inverse', 590, 2, 600), (1 - x) * (1 - x)), 'the taper wins near range')
})

test('a cone: 1 inside the inner angle, outerGain outside, linear in between (spec formula)', () => {
  const cone = { inner: 90, outer: 180, outerGain: 0.25 }
  const dir = { x: 0, y: 1, z: 0 }
  assert.equal(coneGain(null, dir, 0, 0, 0, 0, 10, 0), 1)
  assert.equal(coneGain(cone, dir, 0, 0, 0, 0, 10, 0), 1, 'straight ahead')
  assert.equal(coneGain(cone, dir, 0, 0, 0, 0, -10, 0), 0.25, 'behind')
  // 67.5° off axis = half way between 45° and 90° → 1 - 0.5 + 0.25 × 0.5
  const a = (67.5 * Math.PI) / 180
  assert.ok(near(coneGain(cone, dir, 0, 0, 0, 10 * Math.sin(a), 10 * Math.cos(a), 0), 0.625))
})

test('occlusion maps 0..1 to 0..-15 dB and 20 kHz..400 Hz, clamped', () => {
  assert.equal(occlusionGain(0), 1)
  assert.ok(near(gainToDb(occlusionGain(1)), -15))
  assert.ok(near(gainToDb(occlusionGain(5)), -15), 'clamped')
  assert.ok(near(occlusionCutoff(0), 20000))
  assert.ok(near(occlusionCutoff(1), 400))
  assert.ok(occlusionCutoff(0.5) < 20000 && occlusionCutoff(0.5) > 400)
})

test('air absorption: 20 kHz at the source, 4 kHz from 100 m', () => {
  assert.ok(near(airCutoff(0), 20000))
  assert.ok(near(airCutoff(100), 4000))
  assert.ok(near(airCutoff(400), 4000))
  assert.ok(airCutoff(50) < airCutoff(10))
})

test('rear cue: > 110° off the listener forward is behind', () => {
  const fwd = { x: 0, y: 1, z: 0 }
  assert.equal(isBehind(fwd, 0, 0, 0, 0, 10, 0), false)
  assert.equal(isBehind(fwd, 0, 0, 0, 0, -10, 0), true)
  assert.equal(isBehind(fwd, 0, 0, 0, 10, 0, 0), false, '90° is the side, not behind')
  const a = (120 * Math.PI) / 180
  assert.equal(isBehind(fwd, 0, 0, 0, 10 * Math.sin(a), 10 * Math.cos(a), 0), true)
  assert.equal(isBehind(fwd, 0, 0, 0, 0, -0.1, 0), false, 'on top of the listener has no side')
})

test('score = dB(audibility) + 6 dB per priority class around 3', () => {
  assert.ok(near(scoreDb(0.1, 3), -20))
  assert.ok(near(scoreDb(0.1, 5) - scoreDb(0.1, 3), 12.0412, 1e-3))
  assert.ok(scoreDb(0.1, 1) < scoreDb(0.01, 5))
})

test('sphere zone: inside → distance 0 and the voice sits on the listener; outside → surface', () => {
  const zone: ZoneShape = { type: 'sphere', x: 0, y: 0, z: 0, radius: 10 }
  const out = { x: 0, y: 0, z: 0 }
  assert.equal(zoneNearest(zone, 3, 4, 0, out), 0)
  assert.deepEqual(out, { x: 3, y: 4, z: 0 })
  assert.ok(near(zoneNearest(zone, 20, 0, 0, out), 10))
  assert.ok(near(out.x, 10) && near(out.y, 0))
})

test('box zone honours its rotation (Core.Geometry: local x = c·dx + s·dy)', () => {
  const zone: ZoneShape = { type: 'box', x: 0, y: 0, z: 0, sx: 20, sy: 2, sz: 4, rotation: 90 }
  const out = { x: 0, y: 0, z: 0 }
  // rotated 90°: the long side lies along world Y
  assert.equal(zoneNearest(zone, 0, 9, 0, out), 0)
  assert.ok(near(zoneNearest(zone, 9, 0, 0, out), 8), '1 m half-width along world X')
  assert.ok(near(out.x, 1, 1e-9) && near(out.y, 0, 1e-9))
  assert.ok(near(zoneNearest(zone, 0, 0, 5, out), 3), 'above the box')
})

test('polygon zone: inside in plan → vertical distance only; outside → nearest edge', () => {
  const zone: ZoneShape = { type: 'polygon', xs: [0, 10, 10, 0], ys: [0, 0, 10, 10], minZ: 0, maxZ: 5 }
  const out = { x: 0, y: 0, z: 0 }
  assert.equal(zoneNearest(zone, 5, 5, 2, out), 0)
  assert.ok(near(zoneNearest(zone, 5, 5, 8, out), 3))
  assert.ok(near(zoneNearest(zone, 13, 5, 2, out), 3))
  assert.ok(near(out.x, 10) && near(out.y, 5) && near(out.z, 2))
  assert.ok(near(zoneNearest(zone, 13, 14, 2, out), 5), 'corner: 3-4-5')
})

test('insidePolygon handles a concave outline', () => {
  const xs = [0, 10, 10, 5, 0]
  const ys = [0, 0, 10, 5, 10]
  assert.equal(insidePolygon(xs, ys, 2, 2), true)
  assert.equal(insidePolygon(xs, ys, 5, 8), false, 'inside the notch')
  assert.equal(insidePolygon(xs, ys, 12, 2), false)
})
