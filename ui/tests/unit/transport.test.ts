// runtime/transport.ts — post never rejects, request maps every failure to a NuiError.
//   node --test "ui/tests/unit/**/*.test.ts"
// Node 22 strips the types natively, so relative imports carry the `.ts` extension and nothing in
// here needs a DOM: the transport is swapped for a mock with `setTransport`.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  post, request, onMessage, deliver, setTransport, resetTransport, stats, resetStats,
  measureBytes, isNuiError, NuiError, isDev,
} from '../../src/runtime/transport.ts'
import type { TransportImpl } from '../../src/runtime/transport.ts'

function mock(send: TransportImpl['send']): void {
  setTransport({ send, resource: 'core' })
}

test('isDev is true outside the CEF (no GetParentResourceName)', () => {
  assert.equal(isDev, true)
})

test('post resolves with the parsed body', async () => {
  mock((name, body) => Promise.resolve({ echoed: name, body }))
  const res = await post('ui_close', { page: 'p' })
  assert.deepEqual(res, { echoed: 'ui_close', body: { page: 'p' } })
  resetTransport()
})

test('post NEVER rejects — a failing bridge is an empty object', async () => {
  mock(() => Promise.reject(new Error('bridge is dead')))
  const res = await post('ui_event', { page: 'p' })
  assert.deepEqual(res, {})
  resetTransport()
})

test('post NEVER rejects — a non-object answer becomes {}', async () => {
  mock(() => Promise.resolve('<html>not json</html>'))
  assert.deepEqual(await post('ui_ready', {}), {})
  resetTransport()
})

test('post passes its timeout down to the implementation', async () => {
  let seen = 0
  mock((_n, _b, _s, timeoutMs) => {
    seen = timeoutMs
    return Promise.resolve({})
  })
  await post('ui_event', {}, { timeoutMs: 1234 })
  assert.equal(seen, 1234)
  resetTransport()
})

test('request posts ui_request { c, n, d, t } and unwraps ok:true', async () => {
  let body: Record<string, unknown> | null = null
  mock((name, b) => {
    assert.equal(name, 'ui_request')
    body = b as Record<string, unknown>
    return Promise.resolve({ ok: true, data: { slot: 3 } })
  })
  const res = await request('inventory', 'split', { slot: 3 }, { timeoutMs: 2000 })
  assert.deepEqual(res, { slot: 3 })
  assert.deepEqual(body, { c: 'inventory', n: 'split', d: { slot: 3 }, t: 2000 })
  resetTransport()
})

test('request gives the fetch t + 500 ms of grace', async () => {
  let seen = 0
  mock((_n, _b, _s, timeoutMs) => {
    seen = timeoutMs
    return Promise.resolve({ ok: true })
  })
  await request('inv', 'x', null, { timeoutMs: 3000 })
  assert.equal(seen, 3500)
  resetTransport()
})

test('request rejects with the error code Lua sent', async () => {
  mock(() => Promise.resolve({ ok: false, error: { code: 'no_handler', message: 'nope' } }))
  await assert.rejects(
    () => request('inv', 'split'),
    (err: unknown) => isNuiError(err) && (err as NuiError).code === 'no_handler' && (err as Error).message === 'nope',
  )
  resetTransport()
})

test('request maps a code the contract does not know to `transport`', async () => {
  mock(() => Promise.resolve({ ok: false, error: { code: 'shell_reloaded', message: 'gone' } }))
  await assert.rejects(
    () => request('inv', 'split'),
    (err: unknown) => isNuiError(err) && (err as NuiError).code === 'transport',
  )
  resetTransport()
})

test('request maps a dead transport to `transport`', async () => {
  mock(() => Promise.reject(new Error('socket closed')))
  await assert.rejects(
    () => request('inv', 'split'),
    (err: unknown) => isNuiError(err) && (err as NuiError).code === 'transport',
  )
  resetTransport()
})

test('request maps an AbortError to `timeout`', async () => {
  mock(() => {
    const err = new Error('aborted') as Error & { name: string }
    err.name = 'AbortError'
    return Promise.reject(err)
  })
  await assert.rejects(
    () => request('inv', 'split'),
    (err: unknown) => isNuiError(err) && (err as NuiError).code === 'timeout',
  )
  resetTransport()
})

test('an already-aborted signal rejects before anything is sent', async () => {
  let sent = 0
  mock(() => {
    sent++
    return Promise.resolve({ ok: true })
  })
  const ctrl = new AbortController()
  ctrl.abort()
  await assert.rejects(
    () => request('inv', 'split', null, { signal: ctrl.signal }),
    (err: unknown) => isNuiError(err) && (err as NuiError).code === 'aborted',
  )
  assert.equal(sent, 0)
  resetTransport()
})

test('a signal that aborts mid-flight rejects with `aborted`', async () => {
  const ctrl = new AbortController()
  mock((_n, _b, signal) => new Promise((_res, rej) => {
    signal?.addEventListener('abort', () => rej(new Error('aborted')))
  }))
  const p = request('inv', 'split', null, { signal: ctrl.signal })
  ctrl.abort()
  await assert.rejects(p, (err: unknown) => isNuiError(err) && (err as NuiError).code === 'aborted')
  resetTransport()
})

test('onMessage dispatches by action and unsubscribes', () => {
  const seen: unknown[] = []
  const off = onMessage('page:open', (m) => seen.push(m))
  deliver({ action: 'page:open', id: 'a' })
  deliver({ action: 'page:close', id: 'a' })
  deliver('not a message')
  off()
  deliver({ action: 'page:open', id: 'b' })
  assert.equal(seen.length, 1)
  assert.equal((seen[0] as { id: string }).id, 'a')
})

test('a throwing handler does not stop the other subscribers', () => {
  const seen: string[] = []
  const a = onMessage('focus', () => {
    throw new Error('boom')
  })
  const b = onMessage('focus', () => seen.push('b'))
  deliver({ action: 'focus', focused: true })
  a()
  b()
  assert.deepEqual(seen, ['b'])
})

test('counters count messages, bytes only while measuring', async () => {
  resetStats()
  measureBytes(false)
  mock(() => Promise.resolve({}))
  await post('ui_event', { a: 1 })
  await post('ui_event', { a: 2 })
  deliver({ action: 'feed', c: {} })
  let s = stats()
  assert.equal(s.out.ui_event, 2)
  assert.equal(s.in.feed, 1)
  assert.equal(s.bytesOut, 0)
  measureBytes(true)
  await post('ui_event', { a: 3 })
  s = stats()
  assert.ok(s.bytesOut > 0)
  measureBytes(false)
  resetStats()
  resetTransport()
})
