// runtime/feeds.ts — frame coalescing, the fallback timer, subscriber presence (DESIGN §38.10).
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import * as Feeds from '../../src/runtime/feeds.ts'
import { createScope, withScope } from '../../src/runtime/scope.ts'
import { effectScope } from 'vue'
import { setTransport, resetTransport } from '../../src/runtime/transport.ts'

let frames: Array<(now: number) => void> = []
let timers: Array<{ fn: () => void; ms: number }> = []
const posts: Array<{ name: string; body: Record<string, unknown> }> = []

const runFrame = () => {
  const queue = frames
  frames = []
  for (const cb of queue) cb(0)
}
const runTimers = () => {
  const queue = timers
  timers = []
  for (const t of queue) t.fn()
}

beforeEach(() => {
  frames = []
  timers = []
  posts.length = 0
  Feeds.resetFeeds()
  Feeds.configureFeeds({
    raf: (cb) => (frames.push(cb), frames.length),
    cancelRaf: () => {
      frames = []
    },
    setTimeout: (fn, ms) => {
      timers.push({ fn, ms })
      return timers.length
    },
    clearTimeout: () => {
      timers = []
    },
  })
  setTransport({
    send(name, body) {
      posts.push({ name, body: body as Record<string, unknown> })
      return Promise.resolve({})
    },
  })
})

test('nothing is scheduled while idle', () => {
  assert.equal(Feeds.feedStats().scheduled, false)
  assert.equal(frames.length, 0)
  assert.equal(timers.length, 0)
  resetTransport()
})

test('1000 writes in one frame cost ONE flush, and the latest value wins', () => {
  for (let i = 0; i < 1000; i++) Feeds.applyFeed({ c: { vehicle: { speed: i } } })
  assert.equal(frames.length, 1, 'exactly one rAF was requested')
  assert.equal(Feeds.feedStats().flushes, 0, 'nothing is copied before the frame')
  const view = Feeds.useFeed<{ speed: number }>('vehicle')
  runFrame()
  assert.equal(Feeds.feedStats().flushes, 1)
  assert.equal(view.speed, 999)
  resetTransport()
})

test('after a flush nothing is scheduled again until new data arrives', () => {
  Feeds.applyFeed({ c: { v: { a: 1 } } })
  runFrame()
  assert.equal(frames.length, 0)
  assert.equal(timers.length, 0)
  assert.equal(Feeds.feedStats().scheduled, false)
  Feeds.applyFeed({ c: { v: { a: 2 } } })
  assert.equal(frames.length, 1)
  resetTransport()
})

test('a 250 ms fallback timer covers a throttled rAF', () => {
  Feeds.applyFeed({ c: { v: { a: 1 } } })
  assert.equal(timers.length, 1)
  assert.equal(timers[0].ms, 250)
  const view = Feeds.useFeed<{ a: number }>('v')
  frames = [] // the frame never comes (the shell is hidden)
  runTimers()
  assert.equal(view.a, 1)
  assert.equal(Feeds.feedStats().flushes, 1)
  resetTransport()
})

test('null/undefined removes a key', () => {
  const view = Feeds.useFeed<Record<string, unknown>>('v')
  Feeds.applyFeed({ c: { v: { a: 1, b: 2 } } })
  runFrame()
  assert.deepEqual(Object.keys(view).sort(), ['a', 'b'])
  Feeds.applyFeed({ c: { v: { a: null } } })
  runFrame()
  assert.deepEqual(Object.keys(view), ['b'])
  resetTransport()
})

test('several channels flush in the same frame, and only the dirty ones', () => {
  const a = Feeds.useFeed<{ x: number }>('a')
  const b = Feeds.useFeed<{ x: number }>('b')
  Feeds.applyFeed({ c: { a: { x: 1 }, b: { x: 2 } } })
  assert.equal(frames.length, 1)
  runFrame()
  assert.equal(a.x, 1)
  assert.equal(b.x, 2)
  assert.equal(Feeds.feedStats().flushes, 1)
  resetTransport()
})

test('ui_feed is posted on the FIRST subscribe and the LAST unsubscribe only', () => {
  const s1 = createScope('one')
  const s2 = createScope('two')
  withScope(s1, () => Feeds.useFeed('vehicle'))
  withScope(s2, () => Feeds.useFeed('vehicle'))
  const feedPosts = () => posts.filter((p) => p.name === 'ui_feed')
  assert.equal(feedPosts().length, 1)
  assert.deepEqual(feedPosts()[0].body, { channel: 'vehicle', active: true })
  assert.equal(Feeds.isFeedActive('vehicle'), true)
  s1.dispose()
  assert.equal(feedPosts().length, 1, 'one reader left — nothing announced')
  assert.equal(Feeds.isFeedActive('vehicle'), true)
  s2.dispose()
  assert.equal(feedPosts().length, 2)
  assert.deepEqual(feedPosts()[1].body, { channel: 'vehicle', active: false })
  assert.equal(Feeds.isFeedActive('vehicle'), false)
  resetTransport()
})

test('a useFeed outside a scope warns and never releases', () => {
  const realWarn = console.warn
  const warnings: string[] = []
  console.warn = (...args: unknown[]) => warnings.push(args.join(' '))
  Feeds.useFeed('orphan')
  console.warn = realWarn
  assert.equal(warnings.length, 1)
  assert.match(warnings[0], /outside a scope/)
  assert.equal(Feeds.isFeedActive('orphan'), true)
  resetTransport()
})

test('a message with no `c` does nothing', () => {
  Feeds.applyFeed({})
  Feeds.applyFeed(null)
  assert.equal(frames.length, 0)
  resetTransport()
})

// ---- BUG 1 (review round 2): a component that reads a feed must stop counting when it unmounts.
// `effectScope()` is exactly what Vue gives a component's setup, so this is the component case.

test('a useFeed inside a COMPONENT is released when the component goes away', () => {
  const feedPosts = () => posts.filter((p) => p.name === 'ui_feed')
  const scope = effectScope()
  scope.run(() => Feeds.useFeed('vehicle'))
  assert.equal(Feeds.isFeedActive('vehicle'), true)
  assert.deepEqual(feedPosts()[0].body, { channel: 'vehicle', active: true })
  scope.stop()
  assert.equal(Feeds.isFeedActive('vehicle'), false)
  assert.equal(feedPosts().length, 2)
  assert.deepEqual(feedPosts()[1].body, { channel: 'vehicle', active: false })
  resetTransport()
})

test('a component subscription is ALSO released by the page scope handed in (plugin:unregister)', () => {
  const page = createScope('page:hud')
  const component = effectScope()
  component.run(() => Feeds.useFeed('vehicle', page))
  assert.equal(Feeds.isFeedActive('vehicle'), true)
  // The plugin goes away: the page scope dies while the component is still waiting to unmount.
  page.dispose()
  assert.equal(Feeds.isFeedActive('vehicle'), false)
  assert.equal(posts.filter((p) => p.name === 'ui_feed' && p.body.active === false).length, 1)
  // The component unmounting afterwards must not double-release.
  component.stop()
  assert.equal(posts.filter((p) => p.name === 'ui_feed').length, 2)
  resetTransport()
})

test('a useFeed in a plugin setup is released with the plugin scope', () => {
  const plugin = createScope('plugin:trucking')
  withScope(plugin, () => Feeds.useFeed('trucking'))
  assert.equal(Feeds.isFeedActive('trucking'), true)
  plugin.dispose()
  assert.equal(Feeds.isFeedActive('trucking'), false)
  resetTransport()
})

test('two subscribers: ui_feed only on the FIRST and the LAST', () => {
  const a = effectScope()
  const b = createScope('plugin:x')
  a.run(() => Feeds.useFeed('shared'))
  withScope(b, () => Feeds.useFeed('shared'))
  const feedPosts = () => posts.filter((p) => p.name === 'ui_feed' && p.body.channel === 'shared')
  assert.equal(feedPosts().length, 1)
  a.stop()
  assert.equal(Feeds.isFeedActive('shared'), true)
  assert.equal(feedPosts().length, 1, 'one reader left — nothing announced')
  b.dispose()
  assert.equal(Feeds.isFeedActive('shared'), false)
  assert.equal(feedPosts().length, 2)
  assert.equal(feedPosts()[1].body.active, false)
  resetTransport()
})
