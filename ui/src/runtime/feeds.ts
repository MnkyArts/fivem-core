// core UI runtime — telemetry feeds (DESIGN §38.10).
//
// Lua coalesces per key and sends at most one `feed` message per Config.UI.FeedIntervalMs for ALL
// channels; the shell coalesces per FRAME. A message lands in a plain buffer object and marks the
// channel dirty, ONE requestAnimationFrame per frame copies every dirty buffer into its
// `shallowReactive` target, and a 250 ms timer covers the case where the CEF throttles rAF (a
// hidden shell, §31). While nothing is dirty there is no rAF, no timer and no work at all.
//
// `ui_feed { channel, active }` tells Lua whether anybody is looking, so a producer loop can sleep.

import { shallowReactive } from 'vue'
import { post } from './transport.ts'
import { bindRelease } from './scope.ts'
import type { OwnedScope } from './scope.ts'
import type { Off } from '../../sdk/src/contract.ts'

/** Covers a throttled/never-firing rAF (the shell is hidden, the tab is in the background). */
const FALLBACK_MS = 250

interface Channel {
  name: string
  target: Record<string, unknown>
  buffer: Record<string, unknown>
  dirty: boolean
  subs: number
}

interface Env {
  raf: ((cb: (now: number) => void) => number) | null
  cancelRaf: ((h: number) => void) | null
  setTimeout: (fn: () => void, ms: number) => unknown
  clearTimeout: (h: unknown) => void
}

const env: Env = {
  raf: typeof requestAnimationFrame === 'function' ? requestAnimationFrame.bind(globalThis) : null,
  cancelRaf: typeof cancelAnimationFrame === 'function' ? cancelAnimationFrame.bind(globalThis) : null,
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (h) => clearTimeout(h as ReturnType<typeof setTimeout>),
}

/** Test seam: fake rAF and timers. `configureFeeds({})` changes nothing. */
export function configureFeeds(partial: Partial<Env>): void {
  if (partial.raf !== undefined) env.raf = partial.raf
  if (partial.cancelRaf !== undefined) env.cancelRaf = partial.cancelRaf
  if (partial.setTimeout !== undefined) env.setTimeout = partial.setTimeout
  if (partial.clearTimeout !== undefined) env.clearTimeout = partial.clearTimeout
}

const channels = new Map<string, Channel>()
let rafHandle: number | null = null
let fallbackHandle: unknown = null
let dirtyCount = 0
let flushes = 0
let writes = 0

function channelOf(name: string): Channel {
  let ch = channels.get(name)
  if (!ch) {
    ch = { name, target: shallowReactive({} as Record<string, unknown>), buffer: Object.create(null), dirty: false, subs: 0 }
    channels.set(name, ch)
  }
  return ch
}

function schedule(): void {
  if (rafHandle != null || fallbackHandle != null) return
  if (env.raf) rafHandle = env.raf(flush)
  fallbackHandle = env.setTimeout(flush, FALLBACK_MS)
}

function unschedule(): void {
  if (rafHandle != null && env.cancelRaf) env.cancelRaf(rafHandle)
  rafHandle = null
  if (fallbackHandle != null) env.clearTimeout(fallbackHandle)
  fallbackHandle = null
}

/** Copies every dirty buffer into its reactive target. One pass per frame, whatever came in. */
export function flush(): void {
  unschedule()
  if (dirtyCount === 0) return
  flushes++
  for (const ch of channels.values()) {
    if (!ch.dirty) continue
    ch.dirty = false
    dirtyCount--
    const buf = ch.buffer
    ch.buffer = Object.create(null)
    for (const key of Object.keys(buf)) {
      const value = buf[key]
      if (value === null || value === undefined) delete ch.target[key]
      else ch.target[key] = value
    }
  }
}

/** `feed { c: { [channel]: { key: value } } }` — latest value per key wins. */
export function applyFeed(msg: { c?: Record<string, Record<string, unknown>> } | null | undefined): void {
  const c = msg && msg.c
  if (!c || typeof c !== 'object') return
  for (const name of Object.keys(c)) {
    const values = c[name]
    if (!values || typeof values !== 'object') continue
    const ch = channelOf(name)
    for (const key of Object.keys(values)) {
      ch.buffer[key] = values[key]
      writes++
    }
    if (!ch.dirty) {
      ch.dirty = true
      dirtyCount++
    }
  }
  if (dirtyCount > 0) schedule()
}

// ---------------------------------------------------------------- subscriptions

function announce(ch: Channel, active: boolean): void {
  post('ui_feed', { channel: ch.name, active })
}

/** Raw subscription: increments the channel's reader count, returns the release. */
export function subscribe(channel: string): Off {
  const ch = channelOf(channel)
  ch.subs++
  if (ch.subs === 1) announce(ch, true)
  let live = true
  return () => {
    if (!live) return
    live = false
    ch.subs--
    if (ch.subs === 0) announce(ch, false)
  }
}

/**
 * The reactive view of a channel. The subscription dies with whoever asked for it: the COMPONENT
 * that called it (the common case — a HUD overlay reading telemetry), the page scope handed in by
 * the host, or the plugin scope of a running `setup`. Only a call with no owner at all is permanent,
 * and it says so: `Core.UI.isFeedActive` would otherwise stay true for the rest of the session and
 * a producer loop would never sleep again.
 */
export function useFeed<T extends object = Record<string, unknown>>(channel: string, owner?: OwnedScope | null): T {
  const ch = channelOf(channel)
  const off = subscribe(channel)
  if (!bindRelease(off, owner)) {
    console.warn('[core:ui] useFeed("' + channel + '") outside a scope — the subscription is never released')
  }
  return ch.target as T
}

/** Whether anything reads a channel right now (mirrors Lua's `Core.UI.isFeedActive`). */
export function isFeedActive(channel: string): boolean {
  const ch = channels.get(channel)
  return !!ch && ch.subs > 0
}

export function feedStats(): { channels: number; dirty: number; flushes: number; writes: number; scheduled: boolean; subs: Record<string, number> } {
  const subs: Record<string, number> = Object.create(null)
  for (const ch of channels.values()) subs[ch.name] = ch.subs
  return { channels: channels.size, dirty: dirtyCount, flushes, writes, scheduled: rafHandle != null || fallbackHandle != null, subs }
}

/** Story/test helper: forget every channel and every pending frame. */
export function resetFeeds(): void {
  unschedule()
  channels.clear()
  dirtyCount = 0
  flushes = 0
  writes = 0
}
