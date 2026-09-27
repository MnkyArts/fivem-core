// runtime/audio/cache.ts — the decoded-clip LRU: byte accounting, recency, pinning, limits
// (DESIGN §55.16 `Audio.ClipCacheMb`).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { ClipCache } from '../../src/runtime/audio/cache.ts'

test('put/get account bytes and count hits and misses', () => {
  const c = new ClipCache<string>(100)
  assert.equal(c.put('a', 'A', 30), true)
  assert.equal(c.put('b', 'B', 20), true)
  assert.equal(c.bytes(), 50)
  assert.equal(c.count(), 2)
  assert.equal(c.get('a'), 'A')
  assert.equal(c.get('zz'), undefined)
  assert.equal(c.hits, 1)
  assert.equal(c.misses, 1)
})

test('the least recently USED entry goes first (get refreshes recency)', () => {
  const c = new ClipCache<string>(100)
  c.put('a', 'A', 40)
  c.put('b', 'B', 40)
  c.get('a')
  c.put('c', 'C', 40)
  assert.deepEqual(c.keys(), ['a', 'c'])
  assert.equal(c.bytes(), 80)
  assert.equal(c.evictions, 1)
})

test('pinned entries are never evicted; the total may exceed the limit until unpinned', () => {
  const c = new ClipCache<string>(100)
  c.put('a', 'A', 60)
  assert.equal(c.pin('a'), true)
  assert.equal(c.put('b', 'B', 60), false, 'nothing unpinned to evict except the newcomer itself')
  assert.deepEqual(c.keys(), ['a'])
  c.put('c', 'C', 30)
  assert.equal(c.bytes(), 90)
  c.pin('c')
  c.put('d', 'D', 50)
  assert.equal(c.has('d'), false)
  c.unpin('a')
  assert.equal(c.bytes(), 90, 'unpinning alone does not evict what fits')
})

test('unpin makes an entry evictable again; pin on a missing key is false', () => {
  const c = new ClipCache<string>(100)
  c.put('a', 'A', 80)
  c.pin('a')
  c.put('b', 'B', 30)
  assert.equal(c.has('b'), false)
  c.unpin('a')
  c.put('b', 'B', 30)
  assert.deepEqual(c.keys(), ['b'])
  assert.equal(c.pin('nope'), false)
})

test('an entry larger than the whole limit is refused', () => {
  const c = new ClipCache<string>(100)
  assert.equal(c.put('huge', 'H', 101), false)
  assert.equal(c.bytes(), 0)
})

test('replacing a key adjusts the total and keeps its pins', () => {
  const c = new ClipCache<string>(100)
  c.put('a', 'A', 40)
  c.pin('a')
  c.put('a', 'A2', 10)
  assert.equal(c.bytes(), 10)
  c.put('b', 'B', 95)
  assert.equal(c.get('a'), 'A2', 'still pinned after the replace')
})

test('shrinking the limit evicts down to it; delete frees the bytes', () => {
  const c = new ClipCache<string>(100)
  c.put('a', 'A', 30)
  c.put('b', 'B', 30)
  c.put('c', 'C', 30)
  c.setLimit(50)
  assert.deepEqual(c.keys(), ['c'])
  assert.equal(c.delete('c'), true)
  assert.equal(c.bytes(), 0)
  assert.equal(c.delete('c'), false)
  assert.equal(c.limitBytes(), 50)
})
