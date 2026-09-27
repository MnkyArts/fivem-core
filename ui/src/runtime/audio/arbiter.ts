// core UI — audio engine: the voice arbiter (DESIGN §55.16; R6 §2.2–§2.3, §9.5). Pure.
//
// Every emitter is a VIRTUAL voice (state + a clock-derived play head); the arbiter picks which ones
// are REAL (a Web Audio chain) on every feed message and every engine tick:
//   * audibility = curve × cone × occlusion × volumes; score = dB(audibility) + 6 dB × (priority − 3)
//   * never real below −60 dB (entering needs −57 dB: 3 dB of hysteresis on the floor too)
//   * the top `Voices` by score, at most 4 per source (the nearest speakers of a club are enough)
//   * hysteresis: an incumbent gets +3 dB, and a voice real for < 1 s cannot be stolen
// Streams and timelines need a DECODER first: ≤ `Decoders` sources are decoding at once (ranked by
// their best emitter; +3 dB and a 3 s minimum for incumbents, because a decoder start costs a network
// round trip), and only a decoding source's emitters may become real. Buffer clips/loops need none.
// HRTF (opt-in) goes to the ≤ `HrtfVoices` NEAREST real voices, with a rank slack of 2 and ≥ 2 s
// between two model switches of one voice.

import { AUDIBILITY_FLOOR } from './curves.ts'

export const ARBITER = {
  hysteresisDb: 3,
  minRealMs: 1000,
  floor: AUDIBILITY_FLOOR,
  /** entering needs the floor + 3 dB */
  floorEnter: AUDIBILITY_FLOOR * 1.4125,
  perSource: 4,
  decoderMinMs: 3000,
  /** metres past `range` in which a stream may already start decoding (warm-up, R6 §2.3) */
  warmMargin: 25,
  hrtfSlack: 2,
  hrtfSwitchMs: 2000,
} as const

const PROTECT = 1000

export interface VoiceCand {
  /** emitter id */
  id: number
  source: number
  /** dB, see scoreDb() */
  score: number
  /** linear 0.. */
  audibility: number
  /** currently real (not fading out) */
  real: boolean
  /** when it became real (ms) */
  since: number
  /** the source can feed a real voice now (exists, not failed/ended, decoder granted) */
  usable: boolean
  /** scratch for the sort */
  eff: number
}

/** Chooses the real voices. `out` is cleared and filled with emitter ids; returns its size. */
export function selectVoices(
  cands: ReadonlyArray<VoiceCand>, n: number, perSource: number, now: number,
  out: Set<number>, scratch: VoiceCand[], perCount: Map<number, number>,
): number {
  out.clear()
  scratch.length = 0
  perCount.clear()
  if (n <= 0) return 0
  for (let i = 0; i < cands.length; i++) {
    const c = cands[i]
    if (!c.usable) continue
    if (c.audibility < (c.real ? ARBITER.floor : ARBITER.floorEnter)) continue
    c.eff = c.score + (c.real ? ARBITER.hysteresisDb : 0) + (c.real && now - c.since < ARBITER.minRealMs ? PROTECT : 0)
    scratch.push(c)
  }
  scratch.sort(byEff)
  for (let i = 0; i < scratch.length && out.size < n; i++) {
    const c = scratch[i]
    const k = perCount.get(c.source) || 0
    if (k >= perSource) continue
    perCount.set(c.source, k + 1)
    out.add(c.id)
  }
  return out.size
}

export interface DecoderCand {
  /** source id */
  id: number
  /** best score among its emitters (dB) — distance-ranked below audibility */
  score: number
  active: boolean
  since: number
  /** an emitter is inside range + warmMargin, the source may play (prefs, not failed/ended) */
  eligible: boolean
  eff: number
}

/** Chooses the decoding sources. `out` is cleared and filled with source ids; returns its size. */
export function selectDecoders(
  cands: ReadonlyArray<DecoderCand>, n: number, now: number, out: Set<number>, scratch: DecoderCand[],
): number {
  out.clear()
  scratch.length = 0
  if (n <= 0) return 0
  for (let i = 0; i < cands.length; i++) {
    const c = cands[i]
    if (!c.eligible) continue
    c.eff = c.score + (c.active ? ARBITER.hysteresisDb : 0) + (c.active && now - c.since < ARBITER.decoderMinMs ? PROTECT : 0)
    scratch.push(c)
  }
  scratch.sort(byEff)
  for (let i = 0; i < scratch.length && out.size < n; i++) out.add(scratch[i].id)
  return out.size
}

export interface HrtfCand {
  id: number
  dist: number
  hrtf: boolean
  switchedAt: number
}

/** The real voices that should run HRTF. `out` is cleared; `scratch` is reused. */
export function selectHrtf(real: ReadonlyArray<HrtfCand>, n: number, now: number, out: Set<number>, scratch: HrtfCand[]): void {
  out.clear()
  if (n <= 0 || !real.length) return
  scratch.length = 0
  for (let i = 0; i < real.length; i++) scratch.push(real[i])
  scratch.sort(byDist)
  // 1. incumbents keep HRTF while they rank within n + slack — or while they may not switch yet
  for (let r = 0; r < scratch.length && out.size < n; r++) {
    const c = scratch[r]
    if (c.hrtf && (r < n + ARBITER.hrtfSlack || now - c.switchedAt < ARBITER.hrtfSwitchMs)) out.add(c.id)
  }
  // 2. the nearest others fill the remaining slots
  for (let r = 0; r < scratch.length && r < n && out.size < n; r++) {
    const c = scratch[r]
    if (!c.hrtf && now - c.switchedAt >= ARBITER.hrtfSwitchMs) out.add(c.id)
  }
}

/** Stage-1 score of an emitter for the decoder ranking: audibility when audible, else proximity. */
export function decoderScore(scoreDb: number, audibility: number, dist: number, range: number): number {
  if (audibility > 0) return scoreDb
  return -400 - (10 * Math.max(0, dist - range)) / Math.max(1, range)
}

function byEff(a: { eff: number; id: number }, b: { eff: number; id: number }): number {
  return b.eff - a.eff || a.id - b.id
}

function byDist(a: HrtfCand, b: HrtfCand): number {
  return a.dist - b.dist || a.id - b.id
}
