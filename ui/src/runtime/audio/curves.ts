// core UI — audio engine: loudness maths (DESIGN §55.16; R3 §8.2, R6 §1.3, §2.3, §3.2). Pure.
//
// The PannerNode only gives DIRECTION (rolloffFactor 0); distance, cone, occlusion and air are ours,
// folded into one GainNode and one lowpass. Every curve is EXACTLY 0 at `range`, so a voice that is
// culled or created at the edge of its range enters and leaves at true silence (R6 §8).
//
//   game     GTA's default rolloff (curve.cpp:689-736): 0 dB ≤ 5 m, -14 @10, -31 @20, -49 @40,
//            -62 @64, -76 @100, silent from 128 m; dB interpolated linearly in distance; within the
//            last 20 % of `range` a cos² window takes it to 0 (table points below 0.8·range are exact)
//   inverse  FMOD "inverse tapered": min(ref / max(d, ref), (1 - x)²), x = (d - ref) / (range - ref)
//   linear   1 - x

import type { Cone, CurveName, Vec3, ZoneShape } from './types.ts'

/** GTA's table: [metres, dB]. Past the last point the gain falls linearly to 0 at GTA_SILENT. */
export const GTA_CURVE: ReadonlyArray<readonly [number, number]> = [
  [5, 0], [10, -14], [20, -31], [40, -49], [64, -62], [100, -76],
]
export const GTA_SILENT = 128

/** −60 dB: below this a voice is never real (FMOD's vol0virtualvol, R6 §2.1). */
export const AUDIBILITY_FLOOR = 0.001
/** Fraction of `range` over which the game curve is windowed to 0. */
export const GAME_WINDOW = 0.2

export function dbToGain(db: number): number {
  return Math.pow(10, db / 20)
}

export function gainToDb(g: number): number {
  return g > 1e-12 ? 20 * Math.log10(g) : -240
}

/** GTA's curve as a linear gain (no range window). */
export function gameTable(d: number): number {
  const t = GTA_CURVE
  if (d <= t[0][0]) return 1
  for (let i = 1; i < t.length; i++) {
    if (d <= t[i][0]) {
      const [d0, db0] = t[i - 1]
      const [d1, db1] = t[i]
      return dbToGain(db0 + ((db1 - db0) * (d - d0)) / (d1 - d0))
    }
  }
  if (d >= GTA_SILENT) return 0
  const last = t[t.length - 1]
  return dbToGain(last[1]) * (1 - (d - last[0]) / (GTA_SILENT - last[0]))
}

/** Distance gain 0..1 of one curve; exactly 0 for d ≥ range. */
export function curveGain(curve: CurveName, d: number, ref: number, range: number): number {
  if (!(d < range)) return 0
  if (d < 0) d = 0
  const span = range - ref
  const x = span > 0 ? Math.min(1, Math.max(0, (d - ref) / span)) : 0
  if (curve === 'linear') return 1 - x
  if (curve === 'inverse') {
    const inv = ref / Math.max(d, ref)
    const taper = (1 - x) * (1 - x)
    return inv < taper ? inv : taper
  }
  let g = gameTable(d)
  const w0 = range * (1 - GAME_WINDOW)
  if (d > w0) {
    const c = Math.cos((Math.PI / 2) * ((d - w0) / (range - w0)))
    g *= c * c
  }
  return g
}

/**
 * Web Audio cone gain (spec §PannerNode "Sound Cones"): `dir` is the emitter's unit forward vector,
 * the angle is between it and the emitter→listener vector.
 */
export function coneGain(cone: Cone | null, dir: Vec3, ex: number, ey: number, ez: number, lx: number, ly: number, lz: number): number {
  if (!cone || cone.inner >= 360) return 1
  const vx = lx - ex, vy = ly - ey, vz = lz - ez
  const len = Math.hypot(vx, vy, vz)
  if (len < 1e-6) return 1
  const cos = (vx * dir.x + vy * dir.y + vz * dir.z) / len
  const angle = (Math.acos(Math.max(-1, Math.min(1, cos))) * 180) / Math.PI
  const inner = cone.inner / 2
  const outer = cone.outer / 2
  if (angle <= inner) return 1
  if (angle >= outer) return cone.outerGain
  const x = (angle - inner) / (outer - inner)
  return (1 - x) + cone.outerGain * x
}

/** Occlusion 0..1 → gain: 0 dB … −15 dB (R6 §3.2's table folded into one scalar). */
export function occlusionGain(o: number): number {
  return dbToGain(-15 * Math.min(1, Math.max(0, o)))
}

/** Occlusion 0..1 → lowpass cutoff, log-interpolated 20 kHz … 400 Hz. */
export function occlusionCutoff(o: number): number {
  return 20000 * Math.pow(400 / 20000, Math.min(1, Math.max(0, o)))
}

/** Air absorption: 20 kHz at the source, ~4 kHz at 100 m and beyond (GTA, R3 §8.2). */
export function airCutoff(d: number): number {
  return 20000 * Math.pow(0.2, Math.min(1, Math.max(0, d) / 100))
}

/** Equal-power folds back onto front: a source behind the listener gets −2 dB and 8 kHz (R6 §3.2). */
export const REAR_COS = Math.cos((110 * Math.PI) / 180)
export const REAR_GAIN = dbToGain(-2)
export const REAR_CUTOFF = 8000

/** Is the point behind the listener (> 110° off the forward vector)? */
export function isBehind(fwd: Vec3, lx: number, ly: number, lz: number, px: number, py: number, pz: number): boolean {
  const vx = px - lx, vy = py - ly, vz = pz - lz
  const len = Math.hypot(vx, vy, vz)
  if (len < 0.5) return false
  return (vx * fwd.x + vy * fwd.y + vz * fwd.z) / len < REAR_COS
}

/** Loudness score in dB for the arbiter: audibility plus ±6 dB per priority class around 3. */
export function scoreDb(audibility: number, priority: number): number {
  return gainToDb(audibility) + 6.0206 * (priority - 3)
}

// ---------------------------------------------------------------- zones ("fills the room")

function segmentNearest(ax: number, ay: number, bx: number, by: number, px: number, py: number, out: { x: number; y: number }): number {
  const dx = bx - ax, dy = by - ay
  const l2 = dx * dx + dy * dy
  let t = l2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / l2 : 0
  t = t < 0 ? 0 : t > 1 ? 1 : t
  out.x = ax + t * dx
  out.y = ay + t * dy
  return (px - out.x) * (px - out.x) + (py - out.y) * (py - out.y)
}

/** Even-odd rule, edges inclusive enough for a loudness decision (Core.Geometry semantics). */
export function insidePolygon(xs: number[], ys: number[], x: number, y: number): boolean {
  let inside = false
  for (let i = 0, j = xs.length - 1; i < xs.length; j = i++) {
    if ((ys[i] > y) !== (ys[j] > y) && x < ((xs[j] - xs[i]) * (y - ys[i])) / (ys[j] - ys[i]) + xs[i]) inside = !inside
  }
  return inside
}

const seg = { x: 0, y: 0 }

/**
 * Distance from (px, py, pz) to the zone (0 inside) and the nearest point of the zone in `out`
 * (the point itself when inside) — the voice is placed there, so inside a zone the sound has no
 * direction and walking out through the door it comes from the door.
 */
export function zoneNearest(zone: ZoneShape, px: number, py: number, pz: number, out: Vec3): number {
  if (zone.type === 'sphere') {
    const vx = px - zone.x, vy = py - zone.y, vz = pz - zone.z
    const len = Math.hypot(vx, vy, vz)
    if (len <= zone.radius) {
      out.x = px; out.y = py; out.z = pz
      return 0
    }
    const k = zone.radius / len
    out.x = zone.x + vx * k; out.y = zone.y + vy * k; out.z = zone.z + vz * k
    return len - zone.radius
  }
  if (zone.type === 'box') {
    const r = (zone.rotation * Math.PI) / 180
    const c = Math.cos(r), s = Math.sin(r)
    const dx = px - zone.x, dy = py - zone.y
    const hx = zone.sx / 2, hy = zone.sy / 2, hz = zone.sz / 2
    let lx = c * dx + s * dy
    let ly = -s * dx + c * dy
    let lz = pz - zone.z
    lx = lx < -hx ? -hx : lx > hx ? hx : lx
    ly = ly < -hy ? -hy : ly > hy ? hy : ly
    lz = lz < -hz ? -hz : lz > hz ? hz : lz
    out.x = zone.x + c * lx - s * ly
    out.y = zone.y + s * lx + c * ly
    out.z = zone.z + lz
    return Math.hypot(px - out.x, py - out.y, pz - out.z)
  }
  const z = pz < zone.minZ ? zone.minZ : pz > zone.maxZ ? zone.maxZ : pz
  if (insidePolygon(zone.xs, zone.ys, px, py)) {
    out.x = px; out.y = py; out.z = z
    return Math.abs(pz - z)
  }
  let best = Infinity
  let bx = px, by = py
  const n = zone.xs.length
  for (let i = 0; i < n; i++) {
    const j = (i + 1) % n
    const d2 = segmentNearest(zone.xs[i], zone.ys[i], zone.xs[j], zone.ys[j], px, py, seg)
    if (d2 < best) {
      best = d2
      bx = seg.x
      by = seg.y
    }
  }
  out.x = bx; out.y = by; out.z = z
  return Math.hypot(px - bx, py - by, pz - z)
}
