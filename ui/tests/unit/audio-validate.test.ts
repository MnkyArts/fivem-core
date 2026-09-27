// runtime/audio/validate.ts — every audio:* payload: bad ones are ignored, numbers clamped, URLs
// https-only (dev also http/blob/data), files resolved to their resource's NUI origin, id maps read
// in every JSON shape a Lua table can take (INTERFACES §6, AGENTS §8).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  parseDebug, parseEmitter, parseFeed, parseId, parsePrefs, parseRemove, parseSource, resolveFile, resolveUrl, u32,
} from '../../src/runtime/audio/validate.ts'

const base = { id: 7, type: 'loop', url: 'https://cdn.example.com/a.ogg', t0: 1000 }

test('parseSource: a valid loop with defaults filled in', () => {
  const s = parseSource(base, false)
  assert.ok(s)
  assert.equal(s.url, 'https://cdn.example.com/a.ogg')
  assert.equal(s.loop, true, 'a loop loops')
  assert.equal(s.rate, 1)
  assert.equal(s.volume, 1)
  assert.equal(s.category, 'sfx')
  assert.equal(s.paused, false)
  assert.equal(s.offset, 0)
  assert.equal(s.t0, 1000)
})

test('parseSource: `trusted` defaults to true; only an explicit false marks content never to decode', () => {
  assert.equal(parseSource(base, false)!.trusted, true)
  assert.equal(parseSource({ ...base, trusted: false }, false)!.trusted, false)
  assert.equal(parseSource({ ...base, trusted: 0 }, false)!.trusted, true, 'only the boolean false counts')
})

test('parseSource ignores bad payloads: no object, bad id, unknown type', () => {
  assert.equal(parseSource(null, false), null)
  assert.equal(parseSource('x', false), null)
  assert.equal(parseSource({ ...base, id: 0 }, false), null)
  assert.equal(parseSource({ ...base, id: 1.5 }, false), null)
  assert.equal(parseSource({ ...base, type: 'video' }, false), null)
})

test('parseSource: https only in the CEF; a bad address reports bad_url for a good id', () => {
  const errors: Array<[number, string]> = []
  const onError = (id: number, code: string) => { errors.push([id, code]) }
  assert.equal(parseSource({ ...base, url: 'http://radio.example.com/live' }, false, onError), null)
  assert.equal(parseSource({ ...base, url: 'https://user:pw@example.com/a.mp3' }, false, onError), null)
  assert.equal(parseSource({ ...base, url: 'javascript:alert(1)' }, false, onError), null)
  assert.deepEqual(errors, [[7, 'bad_url'], [7, 'bad_url'], [7, 'bad_url']])
  assert.ok(parseSource({ ...base, url: 'http://127.0.0.1:8821/a.wav' }, true), 'dev pages may use http')
  assert.ok(parseSource({ ...base, url: 'blob:http://127.0.0.1/x' }, true))
})

test("parseSource: file '@res/path' resolves to https://cfx-nui-res/path", () => {
  const s = parseSource({ id: 3, type: 'clip', file: '@boombox/sounds/drop one.ogg' }, false)
  assert.ok(s)
  assert.equal(s.url, 'https://cfx-nui-boombox/sounds/drop%20one.ogg')
  assert.equal(s.loop, false)
})

test('resolveFile refuses traversal, absolute paths, odd resource names and query characters', () => {
  assert.equal(resolveFile('@res/../core/html/index.html'), null)
  assert.equal(resolveFile('@res//a.ogg'), null)
  assert.equal(resolveFile('@../a.ogg'), null)
  assert.equal(resolveFile('@res/a.ogg?x=1'), null)
  assert.equal(resolveFile('res/a.ogg'), null)
  assert.equal(resolveFile('@my-res_2/a/b.mp3'), 'https://cfx-nui-my-res_2/a/b.mp3')
})

test('resolveUrl normalises https and refuses everything else outside dev', () => {
  assert.equal(resolveUrl('https://Example.com/a b.mp3', false), 'https://example.com/a%20b.mp3')
  assert.equal(resolveUrl('ftp://example.com/a.mp3', false), null)
  assert.equal(resolveUrl('https://' + 'a'.repeat(2100), false), null)
  assert.equal(resolveUrl(42, false), null)
})

test('parseSource clamps numbers and wraps t0 into u32', () => {
  const s = parseSource({ ...base, rate: 10, volume: 5, t0: -1, offset: 'x', pausedAt: 4294967296 + 5 }, false)
  assert.ok(s)
  assert.equal(s.rate, 4)
  assert.equal(s.volume, 2)
  assert.equal(s.t0, 4294967295)
  assert.equal(s.offset, 0)
  assert.equal(s.pausedAt, 5)
})

test('parseSource: timelines need 1..200 items with url|file and a positive duration', () => {
  const items = [{ url: 'https://cdn.example.com/1.mp3', duration: 180000 }, { file: '@club/2.ogg', duration: 1000 }]
  const s = parseSource({ id: 9, type: 'timeline', items, loop: true }, false)
  assert.ok(s)
  assert.equal(s.items!.length, 2)
  assert.equal(s.items![1].url, 'https://cfx-nui-club/2.ogg')
  assert.equal(s.category, 'music', 'timelines default to music')
  assert.equal(parseSource({ id: 9, type: 'timeline', items: [] }, false), null)
  assert.equal(parseSource({ id: 9, type: 'timeline', items: [{ url: items[0].url }] }, false), null, 'no duration')
  const many = Array.from({ length: 201 }, () => items[0])
  assert.equal(parseSource({ id: 9, type: 'timeline', items: many }, false), null)
})

test('parseSource: stream decoder from the server, else inferred (HLS by playlist, Ogg family, MP3)', () => {
  const kind = (extra: Record<string, unknown>) => parseSource({ id: 1, type: 'stream', ...extra }, false)!.kind
  assert.equal(kind({ url: 'https://r.example.com/live', kind: 'ogg' }), 'ogg')
  assert.equal(kind({ url: 'https://r.example.com/live/index.m3u8' }), 'hls')
  assert.equal(kind({ url: 'https://r.example.com/live', codec: 'application/vnd.apple.mpegurl' }), 'hls')
  assert.equal(kind({ url: 'https://r.example.com/live.opus' }), 'ogg')
  assert.equal(kind({ url: 'https://r.example.com/live' }), 'mp3')
  assert.equal(parseSource({ id: 1, type: 'voice' }, false)!.url, null, 'voice sources carry no address')
})

test('parseEmitter: defaults, clamps, ref below range, bad payloads ignored', () => {
  const e = parseEmitter({ id: 2, source: 7, x: 1, y: 2, z: 3 })
  assert.ok(e)
  assert.equal(e.range, 40)
  assert.equal(e.curve, 'game')
  assert.equal(e.ref, 2)
  assert.equal(e.priority, 3)
  assert.equal(e.occlusion, true)
  assert.equal(e.volume, 1)
  const c = parseEmitter({ id: 2, source: 7, x: 1, y: 2, z: 3, range: 900, ref: 50, priority: 9.4, curve: 'cubic', occlusion: false })
  assert.ok(c)
  assert.equal(c.range, 600)
  assert.equal(c.ref, 50)
  assert.equal(c.priority, 5)
  assert.equal(c.curve, 'game')
  assert.equal(c.occlusion, false)
  assert.equal(parseEmitter({ id: 2, source: 7, x: 1, y: 2, z: 3, range: 10, ref: 20 })!.ref, 5)
  assert.equal(parseEmitter({ id: 2, source: 7, x: 1, y: 2 }), null)
  assert.equal(parseEmitter({ id: 2, source: 7, x: 1, y: 2, z: 1e9 }), null)
  assert.equal(parseEmitter({ id: 2, x: 1, y: 2, z: 3 }), null)
})

test('parseEmitter: cones, facing from rz, zones in JSON vector shapes (objects or arrays)', () => {
  const e = parseEmitter({
    id: 1, source: 2, x: 0, y: 0, z: 0, rz: 90, cone: { inner: 60, outer: 400, outerGain: 3 },
    zone: { type: 'box', coords: [1, 2, 3], size: { x: 10, y: 4, z: 3 }, rotation: 45 },
  })
  assert.ok(e)
  assert.deepEqual(e.cone, { inner: 60, outer: 360, outerGain: 1 })
  assert.ok(Math.abs(e.dir.x + 1) < 1e-9 && Math.abs(e.dir.y) < 1e-9, 'heading 90° faces -X in GTA')
  assert.deepEqual(e.zone, { type: 'box', x: 1, y: 2, z: 3, sx: 10, sy: 4, sz: 3, rotation: 45 })
  const poly = parseEmitter({ id: 1, source: 2, x: 0, y: 0, z: 0, zone: { type: 'poly', points: [[0, 0], { x: 5, y: 0 }, [5, 5]], minZ: 0, maxZ: 4 } })
  assert.ok(poly && poly.zone && poly.zone.type === 'polygon')
  const bad = parseEmitter({ id: 1, source: 2, x: 0, y: 0, z: 0, zone: { type: 'sphere', coords: [0, 0, 0], radius: -1 } })
  assert.ok(bad)
  assert.equal(bad.zone, null, 'an unreadable zone degrades to a point emitter')
})

test('parseRemove: an id list or one id, invalid entries dropped, the fade clamped', () => {
  assert.deepEqual(parseRemove({ ids: [1, 'x', 2, -3, '4'], fadeMs: 1 }), { ids: [1, 2, 4], fadeMs: 5 })
  assert.deepEqual(parseRemove({ id: 9 }), { ids: [9], fadeMs: 300 })
  assert.equal(parseRemove({ ids: [] }), null)
  assert.equal(parseRemove({ ids: 'all' }), null)
})

test('parseFeed: pose, normalised vectors, volumes clamped, velocity bounded', () => {
  const f = parseFeed({
    t: 123456, lx: 1, ly: 2, lz: 3, fx: 0, fy: 2, fz: 0, ux: 0, uy: 0, uz: 5, vx: 1000, vy: 0, vz: 0,
    master: 1.5, music: -1, sfx: 3, paused: true, env: { interior: 7, room: 2, vehicle: true },
  })
  assert.ok(f)
  assert.equal(f.t, 123456)
  assert.deepEqual(f.pos, { x: 1, y: 2, z: 3 })
  assert.deepEqual(f.fwd, { x: 0, y: 1, z: 0 })
  assert.deepEqual(f.up, { x: 0, y: 0, z: 1 })
  assert.ok(f.vel && Math.abs(f.vel.x - 200) < 1e-9, 'speed capped at 200 m/s')
  assert.equal(f.master, 1.5)
  assert.equal(f.music, 0)
  assert.equal(f.sfx, 2)
  assert.equal(f.ambience, null, 'absent stays absent')
  assert.equal(f.paused, true)
  assert.deepEqual(f.env, { interior: 7, room: 2, vehicle: true, underwater: false })
})

test('parseFeed: a zero forward vector or missing pose parts are ignored, not guessed', () => {
  const f = parseFeed({ lx: 1, ly: 2, fx: 0, fy: 0, fz: 0 })
  assert.ok(f)
  assert.equal(f.pos, null)
  assert.equal(f.fwd, null)
  assert.equal(f.t, null)
  assert.equal(parseFeed(7), null)
})

test('parseFeed: `moving` / `occl` in every shape a Lua table becomes in JSON', () => {
  const asObject = parseFeed({ moving: { '12': { x: 1, y: 2, z: 3, rz: 90 }, n13: [4, 5, 6], junk: { x: 1 } } })!
  assert.deepEqual(asObject.moving, [12, 1, 2, 3, NaN, 90, 13, 4, 5, 6, NaN, NaN], 'a heading rides along when given')
  const asEntries = parseFeed({ moving: [{ id: 40, x: 1, y: 1, z: 1 }], occl: [{ id: 40, v: 2 }] })!
  assert.deepEqual(asEntries.moving, [40, 1, 1, 1, NaN, NaN])
  assert.deepEqual(asEntries.occl, [40, 1], 'clamped to 0..1')
  const asSequence = parseFeed({ occl: [0.5, null, 0.25] })!
  assert.deepEqual(asSequence.occl, [1, 0.5, 3, 0.25], 'a Lua sequence: index = id')
  const prefixed = parseFeed({ occl: { e5: 0.1, '6': 'x' } })!
  assert.deepEqual(prefixed.occl, [5, 0.1])
})

test('parsePrefs keeps only valid keys and clamps them', () => {
  assert.deepEqual(parsePrefs({ hrtf: true, maxVoices: 500, offsetMs: -5000, streams: false }), { hrtf: true, maxVoices: 64, offsetMs: -1000, streams: false })
  assert.deepEqual(parsePrefs({ streams: 2.6, decoders: 99, clipCacheMb: 1, hrtfVoices: 4 }), { streams: 3, decoders: 8, clipCacheMb: 8, hrtfVoices: 4 })
  assert.deepEqual(parsePrefs({ hrtf: 'yes' }), {})
  assert.equal(parsePrefs(null), null)
  assert.deepEqual(parseDebug({ on: true }), { on: true })
  assert.deepEqual(parseDebug({ on: 1 }), { on: false })
})

test('ids: integers 1..2^31-1 (digit strings too); u32 wraps anything finite', () => {
  assert.equal(parseId(5), 5)
  assert.equal(parseId('42'), 42)
  assert.equal(parseId(0), null)
  assert.equal(parseId(-1), null)
  assert.equal(parseId(2147483648), null)
  assert.equal(parseId('4x'), null)
  assert.equal(u32(4294967296 + 10), 10)
  assert.equal(u32(-10), 4294967286)
  assert.equal(u32(Infinity), null)
})
