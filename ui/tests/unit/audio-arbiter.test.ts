// runtime/audio/arbiter.ts — real vs virtual voices, hysteresis, decoder grants, HRTF slots
// (DESIGN §55.16 "≤ Voices real … +3 dB / 1 s hysteresis", R6 §2.3, §9.5).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  ARBITER, decoderScore, selectDecoders, selectHrtf, selectVoices,
} from '../../src/runtime/audio/arbiter.ts'
import type { DecoderCand, HrtfCand, VoiceCand } from '../../src/runtime/audio/arbiter.ts'
import { dbToGain, scoreDb } from '../../src/runtime/audio/curves.ts'

function cand(id: number, db: number, extra?: Partial<VoiceCand>): VoiceCand {
  const aud = dbToGain(db)
  return Object.assign({ id, source: id, score: scoreDb(aud, 3), audibility: aud, real: false, since: 0, usable: true, eff: 0 }, extra || {})
}

function pick(cands: VoiceCand[], n: number, now = 10000, perSource: number = ARBITER.perSource): number[] {
  const out = new Set<number>()
  selectVoices(cands, n, perSource, now, out, [], new Map())
  return Array.from(out).sort((a, b) => a - b)
}

test('the loudest N become real, the rest stay virtual', () => {
  const cands = [cand(1, -30), cand(2, -10), cand(3, -20), cand(4, -5), cand(5, -40)]
  assert.deepEqual(pick(cands, 2), [2, 4])
  assert.deepEqual(pick(cands, 10), [1, 2, 3, 4, 5])
})

test('never real below -60 dB; entering needs -57 dB; a real voice holds down to -60 dB', () => {
  assert.deepEqual(pick([cand(1, -61)], 4), [])
  assert.deepEqual(pick([cand(1, -58)], 4), [], 'a virtual voice needs the floor + 3 dB')
  assert.deepEqual(pick([cand(1, -56)], 4), [1])
  assert.deepEqual(pick([cand(1, -59, { real: true, since: 0 })], 4), [1], 'the incumbent keeps it')
  assert.deepEqual(pick([cand(1, -61, { real: true, since: 0 })], 4), [])
})

test('+3 dB hysteresis: a challenger must be more than 3 dB louder to steal a slot', () => {
  const incumbent = cand(1, -20, { real: true, since: 0 })
  assert.deepEqual(pick([incumbent, cand(2, -18)], 1), [1], '2 dB louder is not enough')
  assert.deepEqual(pick([incumbent, cand(2, -16)], 1), [2], '4 dB louder steals')
})

test('a voice real for less than 1 s cannot be stolen, even by a far louder one', () => {
  const young = cand(1, -40, { real: true, since: 9500 })
  assert.deepEqual(pick([young, cand(2, -5)], 1, 10000), [1])
  assert.deepEqual(pick([young, cand(2, -5)], 1, 10600), [2], 'after 1 s it can')
})

test('at most 4 real voices per source (the nearest speakers of a club)', () => {
  const cands = [1, 2, 3, 4, 5, 6].map((id) => cand(id, -10 - id, { source: 77 }))
  assert.deepEqual(pick(cands, 32), [1, 2, 3, 4])
  assert.deepEqual(pick(cands, 32, 10000, 2), [1, 2])
})

test('unusable candidates (no source, failed, no decoder) are skipped', () => {
  assert.deepEqual(pick([cand(1, -5, { usable: false }), cand(2, -30)], 1), [2])
})

test('a budget of 0 selects nothing', () => {
  assert.deepEqual(pick([cand(1, -5)], 0), [])
})

test('ties break by id (deterministic across passes)', () => {
  assert.deepEqual(pick([cand(9, -10), cand(3, -10), cand(5, -10)], 2), [3, 5])
})

test('priority classes: +6 dB per class decide between similar sounds', () => {
  const quietImportant = cand(1, -30)
  quietImportant.score = scoreDb(quietImportant.audibility, 5)
  const louderNormal = cand(2, -25)
  assert.deepEqual(pick([quietImportant, louderNormal], 1), [1])
})

function dec(id: number, score: number, extra?: Partial<DecoderCand>): DecoderCand {
  return Object.assign({ id, score, active: false, since: 0, eligible: true, eff: 0 }, extra || {})
}

function decoders(cands: DecoderCand[], n: number, now = 20000): number[] {
  const out = new Set<number>()
  selectDecoders(cands, n, now, out, [])
  return Array.from(out).sort((a, b) => a - b)
}

test('decoders: the best-placed sources within the budget, ineligible ones never', () => {
  const c = [dec(1, -10), dec(2, -30), dec(3, -5), dec(4, 0, { eligible: false })]
  assert.deepEqual(decoders(c, 2), [1, 3])
  assert.deepEqual(decoders(c, 0), [])
})

test('decoders: an active one keeps its slot for 3 s and against < 3 dB challengers', () => {
  assert.deepEqual(decoders([dec(1, -20, { active: true, since: 18000 }), dec(2, 0)], 1, 20000), [1], 'protected for 3 s')
  assert.deepEqual(decoders([dec(1, -20, { active: true, since: 0 }), dec(2, -18)], 1), [1], 'hysteresis')
  assert.deepEqual(decoders([dec(1, -20, { active: true, since: 0 }), dec(2, -10)], 1), [2])
})

test('decoderScore ranks audible emitters by dB and inaudible ones by proximity', () => {
  assert.equal(decoderScore(-20, 0.1, 10, 40), -20)
  const justOutside = decoderScore(-240, 0, 45, 40)
  const farOutside = decoderScore(-240, 0, 60, 40)
  assert.ok(justOutside > farOutside)
  assert.ok(decoderScore(-80, 0.0001, 39, 40) > justOutside, 'any audibility beats none')
})

function hc(id: number, dist: number, hrtf = false, switchedAt = -Infinity): HrtfCand {
  return { id, dist, hrtf, switchedAt }
}

function hrtf(real: HrtfCand[], n: number, now = 50000): number[] {
  const out = new Set<number>()
  selectHrtf(real, n, now, out, [])
  return Array.from(out).sort((a, b) => a - b)
}

test('HRTF goes to the n nearest real voices', () => {
  assert.deepEqual(hrtf([hc(1, 30), hc(2, 5), hc(3, 10), hc(4, 50)], 2), [2, 3])
  assert.deepEqual(hrtf([hc(1, 30), hc(2, 5)], 0), [], 'off')
})

test('HRTF incumbents keep it within the rank slack; newcomers wait out the switch cooldown', () => {
  // voice 1 ranks 3rd with n = 2: inside n + slack(2) → keeps HRTF
  assert.deepEqual(hrtf([hc(1, 20, true), hc(2, 5), hc(3, 10)], 2), [1, 2])
  // voice 3 switched 1 s ago: it may not take a slot yet
  assert.deepEqual(hrtf([hc(2, 5), hc(3, 10, false, 49000)], 2), [2])
  // an incumbent ranked far out still keeps it while its own switch is recent
  assert.deepEqual(hrtf([hc(1, 90, true, 49500), hc(2, 5), hc(3, 10), hc(4, 11), hc(5, 12)], 2), [1, 2])
})
