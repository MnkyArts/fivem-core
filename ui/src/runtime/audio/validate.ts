// core UI — audio engine: message validation (DESIGN §55.16, INTERFACES §6). Pure, no DOM.
//
// Every `audio:*` payload passes one of these before the engine sees it. A payload that cannot be
// read is IGNORED (null) — Lua is trusted but its JSON is not always the shape one expects: a Lua
// table keyed by integer ids becomes a JSON array when the ids happen to be 1..n and an object with
// digit-string keys otherwise (AGENTS §8), so the id maps (`moving`, `occl`) accept both, plus
// prefixed keys (`n12`) and `{ id, … }` entries. Out-of-range numbers are clamped, not rejected.
//
// URLs: production accepts `https:` only (the page is https://cfx-nui-core, so http:// is mixed
// content and blocked anyway, R6 §5.1); `file = '@<res>/<path>'` resolves to the resource's own
// origin. A dev page (plain browser, `dev = true`) also takes http:, blob: and data: for the suites.

import type {
  Category, Cone, CurveName, EmitterSpec, EnvSpec, FeedSpec, PrefsSpec, RemoveSpec, SourceSpec,
  SourceType, StreamKind, TimelineItem, Vec3, ZoneShape,
} from './types.ts'

const MAX_ID = 2147483647
const U32 = 4294967296
const COORD_LIMIT = 100000
const MAX_ITEMS = 200
const MAX_MAP_ENTRIES = 512

const SOURCE_TYPES: Record<string, SourceType> = { clip: 'clip', loop: 'loop', timeline: 'timeline', stream: 'stream', voice: 'voice' }
const CATEGORIES: Record<string, Category> = { music: 'music', sfx: 'sfx', ambience: 'ambience', voice: 'voice' }
const CURVES: Record<string, CurveName> = { game: 'game', inverse: 'inverse', linear: 'linear' }
const KINDS: Record<string, StreamKind> = { mp3: 'mp3', ogg: 'ogg', hls: 'hls' }

type Obj = Record<string, unknown>

export function isObj(v: unknown): v is Obj {
  return !!v && typeof v === 'object' && !Array.isArray(v)
}

/** A finite number, or null. */
export function num(v: unknown): number | null {
  return typeof v === 'number' && Number.isFinite(v) ? v : null
}

export function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v
}

/** `num(v)` clamped into [lo, hi], or `def` when absent/invalid. */
export function numOr(v: unknown, def: number, lo: number, hi: number): number {
  const n = num(v)
  return n === null ? def : clamp(n, lo, hi)
}

/** A node id: integer 1..2^31-1 (a digit string is accepted too). */
export function parseId(v: unknown): number | null {
  let n: number | null = null
  if (typeof v === 'number') n = v
  else if (typeof v === 'string' && /^\d{1,10}$/.test(v)) n = Number(v)
  if (n === null || !Number.isInteger(n) || n < 1 || n > MAX_ID) return null
  return n
}

/** A map key that names an id: `'12'`, `'n12'`, `'e_12'`. */
export function parseKeyId(key: string): number | null {
  const m = /^[A-Za-z_]{0,8}(\d{1,10})$/.exec(key)
  return m ? parseId(m[1]) : null
}

/** Any finite number wrapped into a u32 (Lua may hand over a negative or unmasked value). */
export function u32(v: unknown): number | null {
  const n = num(v)
  if (n === null) return null
  const i = Math.floor(n) % U32
  return i < 0 ? i + U32 : i
}

/** `{x,y,z}` or `[x,y,z]` with finite, bounded components. */
export function vec(v: unknown): Vec3 | null {
  let x: unknown, y: unknown, z: unknown
  if (Array.isArray(v)) {
    x = v[0]; y = v[1]; z = v[2]
  } else if (isObj(v)) {
    x = v.x; y = v.y; z = v.z
  } else return null
  const a = num(x), b = num(y), c = num(z)
  if (a === null || b === null || c === null) return null
  if (Math.abs(a) > COORD_LIMIT || Math.abs(b) > COORD_LIMIT || Math.abs(c) > COORD_LIMIT) return null
  return { x: a, y: b, z: c }
}

function vec3Of(x: unknown, y: unknown, z: unknown, limit: number): Vec3 | null {
  const a = num(x), b = num(y), c = num(z)
  if (a === null || b === null || c === null) return null
  if (Math.abs(a) > limit || Math.abs(b) > limit || Math.abs(c) > limit) return null
  return { x: a, y: b, z: c }
}

/** Unit vector, or null for a zero/degenerate one. */
export function unit(v: Vec3 | null): Vec3 | null {
  if (!v) return null
  const len = Math.hypot(v.x, v.y, v.z)
  if (!(len > 1e-6)) return null
  return { x: v.x / len, y: v.y / len, z: v.z / len }
}

// ---------------------------------------------------------------- URLs

const FILE_RE = /^@([A-Za-z0-9_.-]{1,64})\/(.{1,240})$/
const PATH_RE = /^[A-Za-z0-9_.\-/ ()+,&'!~]+$/

/** `'@<resource>/<path>'` → `https://cfx-nui-<resource>/<path>` (the resource's own NUI origin). */
export function resolveFile(file: unknown): string | null {
  if (typeof file !== 'string') return null
  const m = FILE_RE.exec(file)
  if (!m) return null
  const res = m[1]
  const path = m[2]
  if (res === '.' || res === '..' || !PATH_RE.test(path)) return null
  const segments = path.split('/')
  for (const seg of segments) if (seg === '' || seg === '.' || seg === '..') return null
  return 'https://cfx-nui-' + res + '/' + encodeURI(path)
}

/** An https URL (dev: also http/blob/data), without credentials, ≤ 2048 chars. */
export function resolveUrl(url: unknown, dev: boolean): string | null {
  if (typeof url !== 'string' || url.length === 0 || url.length > 2048) return null
  let u: URL
  try {
    u = new URL(url)
  } catch (err) {
    return null
  }
  if (u.username || u.password) return null
  if (u.protocol === 'https:') return u.href
  if (dev && (u.protocol === 'http:' || u.protocol === 'blob:' || u.protocol === 'data:')) return url
  return null
}

const HOST_RE = /^(\*\.)?[a-z0-9-]{1,63}(\.[a-z0-9-]{1,63})*$/

/** The server's host patterns for a source: ≤ 32 of `host` or `*.suffix`, lower-cased; null when none. */
export function parseHosts(v: unknown): string[] | null {
  if (!Array.isArray(v)) return null
  const out: string[] = []
  for (const h of v) {
    if (out.length >= 32) break
    if (typeof h !== 'string' || h.length > 253) continue
    const lower = h.toLowerCase()
    if (HOST_RE.test(lower) && lower !== '*.') out.push(lower)
  }
  return out.length ? out : null
}

/** `url` wins over `file`; null when neither resolves. */
function resolveEither(o: Obj, dev: boolean): string | null {
  if (o.url !== undefined && o.url !== null) return resolveUrl(o.url, dev)
  return resolveFile(o.file)
}

/** The stream decoder when the server did not name one: HLS by playlist, Ogg family, else MP3. */
export function inferKind(url: string, codec: string | null): StreamKind {
  const c = (codec || '').toLowerCase()
  let path = url.toLowerCase()
  try {
    path = new URL(url).pathname.toLowerCase()
  } catch (err) { /* keep the raw string */ }
  if (c.indexOf('mpegurl') !== -1 || c.indexOf('hls') !== -1 || c.indexOf('m3u8') !== -1 || path.endsWith('.m3u8')) return 'hls'
  if (/ogg|opus|vorbis|flac/.test(c) || /\.(ogg|oga|opus|flac)$/.test(path)) return 'ogg'
  return 'mp3'
}

// ---------------------------------------------------------------- audio:source

/**
 * Validates an `audio:source`. `onError(id, code)` hears about a source whose id is fine but whose
 * content address is not (so Lua can be told `bad_url`); anything else is silently ignored.
 */
export function parseSource(m: unknown, dev: boolean, onError?: (id: number, code: 'bad_url') => void): SourceSpec | null {
  if (!isObj(m)) return null
  const id = parseId(m.id)
  const type = typeof m.type === 'string' ? SOURCE_TYPES[m.type] : undefined
  if (id === null || !type) return null
  let url: string | null = null
  let items: TimelineItem[] | null = null
  if (type === 'timeline') {
    if (!Array.isArray(m.items) || m.items.length === 0 || m.items.length > MAX_ITEMS) return null
    items = []
    for (const it of m.items) {
      if (!isObj(it)) return null
      const u = resolveEither(it, dev)
      const d = num(it.duration)
      if (d === null || d <= 0 || d > 86400000) return null
      if (!u) {
        if (onError) onError(id, 'bad_url')
        return null
      }
      items.push({ url: u, duration: d })
    }
  } else if (type !== 'voice') {
    url = resolveEither(m, dev)
    if (!url) {
      if (onError) onError(id, 'bad_url')
      return null
    }
  }
  const codec = typeof m.codec === 'string' && m.codec.length <= 64 ? m.codec : null
  const kindField = typeof m.kind === 'string' ? KINDS[m.kind] : undefined
  const category = typeof m.category === 'string' && CATEGORIES[m.category]
    ? CATEGORIES[m.category]
    : (type === 'stream' || type === 'timeline' ? 'music' : 'sfx')
  return {
    id,
    type,
    url,
    items,
    loop: type === 'loop' || m.loop === true,
    t0: m.t0 === undefined || m.t0 === null ? null : u32(m.t0),
    rate: numOr(m.rate, 1, 0.25, 4),
    paused: m.paused === true,
    pausedAt: m.pausedAt === undefined || m.pausedAt === null ? null : u32(m.pausedAt),
    offset: numOr(m.offset, 0, -1e10, 1e10),
    volume: numOr(m.volume, 1, 0, 2),
    category,
    codec,
    kind: type === 'stream' ? (kindField || inferKind(url as string, codec)) : (kindField || null),
    hosts: parseHosts(m.hosts),
    trusted: m.trusted !== false,
  }
}

// ---------------------------------------------------------------- audio:emitter

/** A Core.Geometry definition (raw or normalized; vectors as `{x,y,z}` or arrays) → ZoneShape. */
export function parseZone(v: unknown): ZoneShape | null {
  if (!isObj(v) || typeof v.type !== 'string') return null
  if (v.type === 'sphere') {
    const c = vec(v.coords)
    const r = num(v.radius)
    if (!c || r === null || r <= 0 || r > 10000) return null
    return { type: 'sphere', x: c.x, y: c.y, z: c.z, radius: r }
  }
  if (v.type === 'box') {
    const c = vec(v.coords)
    const s = vec(v.size)
    if (!c || !s || s.x <= 0 || s.y <= 0 || s.z <= 0 || Math.max(s.x, s.y, s.z) > 10000) return null
    const rotation = numOr(v.rotation, 0, -1e6, 1e6)
    return { type: 'box', x: c.x, y: c.y, z: c.z, sx: s.x, sy: s.y, sz: s.z, rotation }
  }
  if (v.type === 'polygon' || v.type === 'poly') {
    const pts = v.points
    const minZ = num(v.minZ), maxZ = num(v.maxZ)
    if (!Array.isArray(pts) || pts.length < 3 || pts.length > 256 || minZ === null || maxZ === null || maxZ <= minZ) return null
    const xs: number[] = []
    const ys: number[] = []
    for (const p of pts) {
      let x: number | null = null, y: number | null = null
      if (Array.isArray(p)) { x = num(p[0]); y = num(p[1]) } else if (isObj(p)) { x = num(p.x); y = num(p.y) }
      if (x === null || y === null || Math.abs(x) > COORD_LIMIT || Math.abs(y) > COORD_LIMIT) return null
      xs.push(x)
      ys.push(y)
    }
    return { type: 'polygon', xs, ys, minZ, maxZ }
  }
  return null
}

/** GTA forward vector from rotation-order-2 Euler degrees (pitch rx, heading rz; 0/0 = +Y). */
export function forwardOf(rxDeg: number, rzDeg: number): Vec3 {
  const rx = (rxDeg * Math.PI) / 180
  const rz = (rzDeg * Math.PI) / 180
  const c = Math.cos(rx)
  return { x: -Math.sin(rz) * c, y: Math.cos(rz) * c, z: Math.sin(rx) }
}

function parseCone(v: unknown): Cone | null {
  if (!isObj(v)) return null
  const inner = numOr(v.inner, 360, 0, 360)
  const outer = numOr(v.outer, 360, inner, 360)
  if (inner >= 360) return null
  return { inner, outer, outerGain: numOr(v.outerGain, 0, 0, 1) }
}

export function parseEmitter(m: unknown): EmitterSpec | null {
  if (!isObj(m)) return null
  const id = parseId(m.id)
  const source = parseId(m.source)
  const p = vec3Of(m.x, m.y, m.z, COORD_LIMIT)
  if (id === null || source === null || !p) return null
  const range = numOr(m.range, 40, 1, 600)
  let ref = numOr(m.ref, 2, 0.1, 600)
  if (ref >= range) ref = range / 2
  const curve = typeof m.curve === 'string' && CURVES[m.curve] ? CURVES[m.curve] : 'game'
  return {
    id,
    source,
    x: p.x,
    y: p.y,
    z: p.z,
    range,
    volume: numOr(m.volume, 1, 0, 2),
    curve,
    ref,
    cone: parseCone(m.cone),
    dir: forwardOf(numOr(m.rx, 0, -1e6, 1e6), numOr(m.rz, 0, -1e6, 1e6)),
    priority: Math.round(numOr(m.priority, 3, 1, 5)),
    zone: parseZone(m.zone),
    occlusion: m.occlusion !== false,
  }
}

// ---------------------------------------------------------------- audio:remove / prefs / debug

export function parseRemove(m: unknown): RemoveSpec | null {
  if (!isObj(m)) return null
  const ids: number[] = []
  const list = Array.isArray(m.ids) ? m.ids : (m.id !== undefined ? [m.id] : null)
  if (!list) return null
  for (let i = 0; i < list.length && i < 4096; i++) {
    const id = parseId(list[i])
    if (id !== null) ids.push(id)
  }
  if (!ids.length) return null
  return { ids, fadeMs: numOr(m.fadeMs, 300, 5, 10000) }
}

export function parsePrefs(m: unknown): PrefsSpec | null {
  if (!isObj(m)) return null
  const out: PrefsSpec = {}
  if (typeof m.hrtf === 'boolean') out.hrtf = m.hrtf
  if (num(m.maxVoices) !== null) out.maxVoices = Math.round(clamp(m.maxVoices as number, 1, 64))
  if (num(m.offsetMs) !== null) out.offsetMs = clamp(m.offsetMs as number, -1000, 1000)
  if (typeof m.streams === 'boolean') out.streams = m.streams
  else if (num(m.streams) !== null) out.streams = Math.round(clamp(m.streams as number, 0, 8))
  if (num(m.decoders) !== null) out.decoders = Math.round(clamp(m.decoders as number, 0, 8))
  if (num(m.clipCacheMb) !== null) out.clipCacheMb = clamp(m.clipCacheMb as number, 8, 512)
  if (num(m.hrtfVoices) !== null) out.hrtfVoices = Math.round(clamp(m.hrtfVoices as number, 0, 32))
  return out
}

export function parseDebug(m: unknown): { on: boolean } | null {
  return isObj(m) ? { on: m.on === true } : null
}

// ---------------------------------------------------------------- audio:feed (hot path, ≤ 20 Hz)

function volume(v: unknown): number | null {
  const n = num(v)
  return n === null ? null : clamp(n, 0, 2)
}

function parseEnv(v: unknown): EnvSpec | null {
  if (!isObj(v)) return null
  const interior = v.interior === true ? 1 : (num(v.interior) ?? 0)
  const room = v.room === true ? 1 : (num(v.room) ?? 0)
  return { interior, room, vehicle: v.vehicle === true, underwater: v.underwater === true }
}

/**
 * One id map → flat entries. `arity` 5 = poses (`[id, x, y, z, rx, rz]`, the rotation NaN when absent),
 * 1 = values (`[id, v]`).
 */
function parseIdMap(v: unknown, arity: 1 | 5): number[] | null {
  if (v === undefined || v === null) return null
  const out: number[] = []
  const take = (id: number | null, value: unknown): void => {
    if (id === null || out.length >= MAX_MAP_ENTRIES * (arity + 1)) return
    if (arity === 5) {
      const p = vec(value)
      if (!p) return
      const rx = isObj(value) ? num(value.rx) : null
      const rz = isObj(value) ? num(value.rz) : null
      out.push(id, p.x, p.y, p.z, rx === null ? NaN : rx, rz === null ? NaN : rz)
    } else {
      const n = isObj(value) ? num(value.v) : num(value)
      if (n !== null) out.push(id, clamp(n, 0, 1))
    }
  }
  if (Array.isArray(v)) {
    for (let i = 0; i < v.length; i++) {
      const e = v[i]
      if (e === null || e === undefined) continue
      // `{ id, x, y, z }` / `{ id, v }` entries carry their id; a bare value is a Lua sequence slot.
      if (isObj(e) && e.id !== undefined) take(parseId(e.id), e)
      else take(i + 1, e)
    }
  } else if (isObj(v)) {
    for (const key in v) take(parseKeyId(key), v[key])
  } else return null
  return out
}

export function parseFeed(m: unknown): FeedSpec | null {
  if (!isObj(m)) return null
  const vel = vec3Of(m.vx, m.vy, m.vz, 1000)
  if (vel) {
    const speed = Math.hypot(vel.x, vel.y, vel.z)
    if (speed > 200) {
      vel.x *= 200 / speed
      vel.y *= 200 / speed
      vel.z *= 200 / speed
    }
  }
  return {
    t: m.t === undefined || m.t === null ? null : u32(m.t),
    pos: vec3Of(m.lx, m.ly, m.lz, COORD_LIMIT),
    fwd: unit(vec3Of(m.fx, m.fy, m.fz, 1e6)),
    up: unit(vec3Of(m.ux, m.uy, m.uz, 1e6)),
    vel,
    env: parseEnv(m.env),
    moving: parseIdMap(m.moving, 5),
    occl: parseIdMap(m.occl, 1),
    master: volume(m.master),
    music: volume(m.music),
    sfx: volume(m.sfx),
    ambience: volume(m.ambience),
    voice: volume(m.voice),
    paused: typeof m.paused === 'boolean' ? m.paused : null,
  }
}
