// runtime/scope.ts — the disposable bag behind every plugin and page (DESIGN §38.6).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createScope, currentScope, withScope, configureScopes } from '../../src/runtime/scope.ts'

test('onDispose runs LIFO and counts hooks', () => {
  const order: string[] = []
  const scope = createScope('t')
  scope.onDispose(() => order.push('first'))
  scope.onDispose(() => order.push('second'))
  assert.equal(scope.counts().hooks, 2)
  scope.dispose()
  assert.deepEqual(order, ['second', 'first'])
  assert.equal(scope.counts().hooks, 0)
})

test('dispose is idempotent', () => {
  let n = 0
  const scope = createScope('t')
  scope.onDispose(() => n++)
  scope.dispose()
  scope.dispose()
  assert.equal(n, 1)
  assert.equal(scope.disposed, true)
})

test('a throwing disposer does not strand the ones after it', () => {
  const order: string[] = []
  const scope = createScope('t')
  scope.onDispose(() => order.push('a'))
  scope.onDispose(() => {
    throw new Error('boom')
  })
  scope.onDispose(() => order.push('c'))
  scope.dispose()
  assert.deepEqual(order, ['c', 'a'])
})

test('the returned remover unregisters a hook', () => {
  let n = 0
  const scope = createScope('t')
  const off = scope.onDispose(() => n++)
  off()
  off()
  assert.equal(scope.counts().hooks, 0)
  scope.dispose()
  assert.equal(n, 1)
})

test('listen adds and removes a listener on its target', () => {
  const target = new EventTarget()
  const seen: string[] = []
  const scope = createScope('t')
  scope.listen(target, 'ping', () => seen.push('x'))
  assert.equal(scope.counts().listeners, 1)
  target.dispatchEvent(new Event('ping'))
  scope.dispose()
  target.dispatchEvent(new Event('ping'))
  assert.deepEqual(seen, ['x'])
})

test('timeout and interval die with the scope', async () => {
  let fired = 0
  const scope = createScope('t')
  scope.timeout(() => fired++, 5)
  scope.interval(() => fired++, 5)
  assert.equal(scope.counts().timers, 2)
  scope.dispose()
  await new Promise((r) => setTimeout(r, 30))
  assert.equal(fired, 0)
})

test('a timeout that fired releases its own slot', async () => {
  let fired = 0
  const scope = createScope('t')
  scope.timeout(() => fired++, 1)
  await new Promise((r) => setTimeout(r, 20))
  assert.equal(fired, 1)
  assert.equal(scope.counts().timers, 0)
  scope.dispose()
})

test('raf loops until the callback returns false, and is cancelled by dispose', () => {
  const queue: Array<(now: number) => void> = []
  configureScopes({ raf: (cb) => (queue.push(cb), queue.length), cancelRaf: () => {} })
  const scope = createScope('t')
  let ticks = 0
  scope.raf(() => {
    ticks++
    return ticks < 3
  })
  assert.equal(scope.counts().rafs, 1)
  while (queue.length) (queue.shift() as (n: number) => void)(0)
  assert.equal(ticks, 3)
  assert.equal(scope.counts().rafs, 0)
  scope.dispose()
  configureScopes({ raf: null, cancelRaf: null })
})

test('after dispose every method is a no-op returning a no-op', () => {
  const scope = createScope('t')
  scope.dispose()
  let n = 0
  const target = new EventTarget()
  const offs = [
    scope.onDispose(() => n++),
    scope.listen(target, 'ping', () => n++),
    scope.timeout(() => n++, 1),
    scope.interval(() => n++, 1),
    scope.raf(() => {
      n++
    }),
  ]
  target.dispatchEvent(new Event('ping'))
  for (const off of offs) off()
  // `onDispose` on a dead scope runs its hook at once (nothing else will), the rest do nothing.
  assert.equal(n, 1)
  assert.deepEqual(scope.counts(), { listeners: 0, timers: 0, rafs: 0, hooks: 0 })
})

test('withScope sets currentScope and restores it, even when fn throws', () => {
  const scope = createScope('t')
  assert.equal(currentScope(), null)
  const seen = withScope(scope, () => currentScope())
  assert.equal(seen, scope)
  assert.equal(currentScope(), null)
  assert.throws(() =>
    withScope(scope, () => {
      throw new Error('boom')
    }),
  )
  assert.equal(currentScope(), null)
  scope.dispose()
})
