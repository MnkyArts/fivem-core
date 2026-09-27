// runtime/audio/icy.ts — the ICY metadata demuxer over arbitrary network chunking, title parsing,
// metadata text decoding and the reconnect backoff (DESIGN §55.16; R6 §5.2).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { IcyDemuxer, backoffMs, decodeMeta, parseStreamTitle } from '../../src/runtime/audio/icy.ts'

const enc = new TextEncoder()

/** `blocks` × [metaint audio bytes][L][L × 16 metadata bytes] — the audio is a counter mod 251. */
function stream(metaint: number, metas: Array<string | null>): { bytes: Uint8Array; audio: Uint8Array } {
  const parts: number[] = []
  const audio: number[] = []
  let n = 0
  for (const meta of metas) {
    for (let i = 0; i < metaint; i++) {
      const b = n++ % 251
      parts.push(b)
      audio.push(b)
    }
    if (meta === null) parts.push(0)
    else {
      const raw = enc.encode(meta)
      const len = Math.ceil(raw.length / 16)
      parts.push(len)
      for (let i = 0; i < len * 16; i++) parts.push(i < raw.length ? raw[i] : 0)
    }
  }
  for (let i = 0; i < 7; i++) {
    const b = n++ % 251
    parts.push(b)
    audio.push(b)
  }
  return { bytes: Uint8Array.from(parts), audio: Uint8Array.from(audio) }
}

function run(metaint: number, chunks: Uint8Array[]): { audio: Uint8Array; metas: string[] } {
  const d = new IcyDemuxer(metaint)
  const out: number[] = []
  const metas: string[] = []
  for (const c of chunks) d.push(c, (a) => { for (const b of a) out.push(b) }, (m) => metas.push(m))
  return { audio: Uint8Array.from(out), metas }
}

function split(bytes: Uint8Array, sizes: (i: number) => number): Uint8Array[] {
  const chunks: Uint8Array[] = []
  let at = 0
  let i = 0
  while (at < bytes.length) {
    const n = Math.max(1, sizes(i++))
    chunks.push(bytes.subarray(at, at + n))
    at += n
  }
  return chunks
}

const METAS = ["StreamTitle='One';", null, "StreamTitle='Guns N' Roses - Paradise City';StreamUrl='';", "StreamTitle='Three';"]

test('metaint 0: every byte is audio', () => {
  const bytes = Uint8Array.from([1, 2, 3, 4, 5])
  const r = run(0, [bytes])
  assert.deepEqual(Array.from(r.audio), [1, 2, 3, 4, 5])
  assert.deepEqual(r.metas, [])
})

test('one chunk: audio comes out exactly, metadata blocks in order, L = 0 blocks skipped', () => {
  const s = stream(32, METAS)
  const r = run(32, [s.bytes])
  assert.deepEqual(Array.from(r.audio), Array.from(s.audio))
  assert.deepEqual(r.metas, [METAS[0], METAS[2], METAS[3]])
})

test('one byte per chunk: every boundary inside the framing survives', () => {
  const s = stream(32, METAS)
  const r = run(32, split(s.bytes, () => 1))
  assert.deepEqual(Array.from(r.audio), Array.from(s.audio))
  assert.equal(r.metas.length, 3)
})

test('random chunking (property test over 40 seeds) gives the same bytes and titles', () => {
  const s = stream(29, METAS.concat(METAS))
  let seed = 12345
  const rnd = () => {
    seed = (seed * 1103515245 + 12345) & 0x7fffffff
    return seed
  }
  for (let k = 0; k < 40; k++) {
    const r = run(29, split(s.bytes, () => 1 + (rnd() % 70)))
    assert.deepEqual(Array.from(r.audio), Array.from(s.audio), 'seed round ' + k)
    assert.equal(r.metas.length, 6)
  }
})

test('a metadata block split across three chunks is reassembled', () => {
  const s = stream(8, ["StreamTitle='Split across chunks';"])
  // cut inside the length byte's block: 8 audio + 1 length + part of the metadata, …
  const r = run(8, [s.bytes.subarray(0, 12), s.bytes.subarray(12, 30), s.bytes.subarray(30)])
  assert.deepEqual(r.metas, ["StreamTitle='Split across chunks';"])
  assert.deepEqual(Array.from(r.audio), Array.from(s.audio))
})

test('the demuxer counts audio bytes and metadata blocks', () => {
  const s = stream(16, METAS)
  const d = new IcyDemuxer(16)
  d.push(s.bytes, () => {})
  assert.equal(d.audioBytes, s.audio.length)
  assert.equal(d.metaBlocks, 3)
})

test('parseStreamTitle: plain, with an apostrophe inside, missing, unterminated', () => {
  assert.equal(parseStreamTitle("StreamTitle='Artist - Song';"), 'Artist - Song')
  assert.equal(parseStreamTitle("StreamTitle='Guns N' Roses - Paradise City';StreamUrl='x';"), "Guns N' Roses - Paradise City")
  assert.equal(parseStreamTitle("StreamUrl='x';"), null)
  assert.equal(parseStreamTitle("StreamTitle='No end"), null)
  assert.equal(parseStreamTitle("StreamTitle='Cut here'"), 'Cut here')
  assert.equal(parseStreamTitle("StreamTitle='';"), '')
})

test('decodeMeta strips NUL padding, reads UTF-8, falls back to Latin-1', () => {
  assert.equal(decodeMeta(Uint8Array.from([65, 66, 0, 0, 0])), 'AB')
  assert.equal(decodeMeta(enc.encode('Café')), 'Café')
  assert.equal(decodeMeta(Uint8Array.from([67, 97, 102, 0xe9])), 'Café', 'a lone 0xE9 is Latin-1 é')
})

test('reconnect backoff is 1, 2, 4, 8, 16, then 30 s', () => {
  assert.deepEqual([0, 1, 2, 3, 4, 5, 6, 20].map(backoffMs), [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000])
})
