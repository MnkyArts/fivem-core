// core UI — audio engine: the decoded-clip cache (DESIGN §55.16 `Audio.ClipCacheMb`, R6 §1.6). Pure.
//
// Decoded PCM is 22 MB per stereo minute at 48 kHz, so decoded clips live in ONE least-recently-used
// map with a byte limit (64 MB by default). A source that is playing a clip PINS its entry: pinned
// entries are never evicted, so the total may exceed the limit while everything is in use and comes
// back under it as soon as something is unpinned. A single entry larger than the limit is refused.
// Map iteration order is insertion order, so `get` re-inserts to mark an entry as recently used.

interface Entry<V> {
  value: V
  bytes: number
  refs: number
}

export class ClipCache<V> {
  private map = new Map<string, Entry<V>>()
  private total = 0
  private limit: number
  hits = 0
  misses = 0
  evictions = 0

  constructor(limitBytes: number) {
    this.limit = Math.max(0, limitBytes)
  }

  setLimit(limitBytes: number): void {
    this.limit = Math.max(0, limitBytes)
    this.evict()
  }

  limitBytes(): number {
    return this.limit
  }

  /** The value, marked as most recently used; counts a hit or a miss. */
  get(key: string): V | undefined {
    const e = this.map.get(key)
    if (!e) {
      this.misses++
      return undefined
    }
    this.map.delete(key)
    this.map.set(key, e)
    this.hits++
    return e.value
  }

  has(key: string): boolean {
    return this.map.has(key)
  }

  /** Stores a value; false when it cannot fit (larger than the limit, or evicted at once). */
  put(key: string, value: V, bytes: number): boolean {
    const size = Math.max(0, bytes)
    if (size > this.limit) return false
    const old = this.map.get(key)
    if (old) {
      this.total -= old.bytes
      this.map.delete(key)
    }
    this.map.set(key, { value, bytes: size, refs: old ? old.refs : 0 })
    this.total += size
    this.evict()
    return this.map.has(key)
  }

  /** A playing source holds its entry. Returns false when the key is not cached. */
  pin(key: string): boolean {
    const e = this.map.get(key)
    if (!e) return false
    e.refs++
    return true
  }

  unpin(key: string): void {
    const e = this.map.get(key)
    if (!e) return
    e.refs = Math.max(0, e.refs - 1)
    if (!e.refs) this.evict()
  }

  delete(key: string): boolean {
    const e = this.map.get(key)
    if (!e) return false
    this.total -= e.bytes
    this.map.delete(key)
    return true
  }

  /** Oldest unpinned entries go until the total fits. */
  evict(): void {
    if (this.total <= this.limit) return
    for (const [key, e] of this.map) {
      if (this.total <= this.limit) break
      if (e.refs > 0) continue
      this.map.delete(key)
      this.total -= e.bytes
      this.evictions++
    }
  }

  bytes(): number {
    return this.total
  }

  /** Bytes held by pinned (playing) entries — the part eviction cannot free. */
  pinnedBytes(): number {
    let n = 0
    for (const e of this.map.values()) if (e.refs > 0) n += e.bytes
    return n
  }

  /** How big a new entry may be and still fit once every unpinned entry is evicted. */
  room(): number {
    return Math.max(0, this.limit - this.pinnedBytes())
  }

  count(): number {
    return this.map.size
  }

  /** Keys, least recently used first (tests, diagnostics). */
  keys(): string[] {
    return Array.from(this.map.keys())
  }

  clear(): void {
    this.map.clear()
    this.total = 0
  }
}
