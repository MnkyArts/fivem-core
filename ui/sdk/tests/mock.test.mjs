// The typed fake Lua of `@core/ui/dev` (DESIGN §38.11 path 1), driven without a DOM: the tests
// play the shell by calling `transport.send(name, body)` — exactly what `runtime/transport.ts`
// does — and read `lua.messages` for what Lua would have sent back.

import { describe, it } from 'node:test'
import assert from 'node:assert/strict'
import { createMockTransport } from '../src/dev/mock.ts'

const req = (n, d, c = 'alpha') => ({ c, n, d, t: 10000 })
const lastOf = (messages, action) => [...messages].reverse().find((m) => m.action === action)

function pages(lua) {
  lua.registerPlugin('alpha', {
    pages: { alpha: 'page', alpha_other: 'page', alpha_hotbar: 'overlay', alpha_confirm: 'modal' },
  })
}

describe('mock transport — requests', () => {
  it('answers a registered handler with { ok: true, data }', async () => {
    const { transport, lua } = createMockTransport()
    lua.onRequest('split', ({ slot, amount }) => ({ ok: true, slot, amount }))
    const res = await transport.send('ui_request', req('split', { slot: 3, amount: 2 }))
    assert.deepEqual(res, { ok: true, data: { ok: true, slot: 3, amount: 2 } })
    assert.equal(lua.posts.length, 1)
    assert.equal(lua.posts[0].name, 'ui_request')
  })

  it('honours delayMs', async () => {
    const { transport, lua } = createMockTransport()
    lua.onRequest('slow', () => 'late', { delayMs: 40 })
    const t0 = Date.now()
    const res = await transport.send('ui_request', req('slow'))
    assert.deepEqual(res, { ok: true, data: 'late' })
    assert.ok(Date.now() - t0 >= 30, 'the answer came back too fast to have been delayed')
  })

  it('an unknown name is no_handler, a thrown handler is handler_error', async () => {
    const { transport, lua } = createMockTransport()
    lua.onRequest('boom', () => { throw new Error('nope') })
    const missing = await transport.send('ui_request', req('nothing'))
    assert.equal(missing.ok, false)
    assert.equal(missing.error.code, 'no_handler')
    assert.match(missing.error.message, /alpha\.nothing/)
    const failed = await transport.send('ui_request', req('boom'))
    assert.equal(failed.ok, false)
    assert.deepEqual(failed.error, { code: 'handler_error', message: 'nope' })
  })

  it('a rejected promise is handler_error too, and an abort rejects the send', async () => {
    const { transport, lua } = createMockTransport()
    lua.onRequest('later', () => Promise.reject(new Error('gone')))
    const res = await transport.send('ui_request', req('later'))
    assert.equal(res.error.code, 'handler_error')

    lua.onRequest('hang', () => 'never', { delayMs: 5000 })
    const ctrl = new AbortController()
    const p = transport.send('ui_request', req('hang'), ctrl.signal)
    ctrl.abort()
    await assert.rejects(() => p, (err) => err.name === 'AbortError')
  })

  it('lua.request round trips through the shell answering ui_response', async () => {
    const { transport, lua } = createMockTransport()
    const promise = lua.request('alpha', 'save', { id: 1 })
    const sent = lastOf(lua.messages, 'page:request')
    assert.equal(sent.id, 'alpha')
    assert.equal(sent.name, 'save')
    assert.deepEqual(sent.data, { id: 1 })
    await transport.send('ui_response', { rid: sent.rid, ok: true, data: { saved: true } })
    assert.deepEqual(await promise, { saved: true })

    const failing = lua.request('alpha', 'save')
    const second = lastOf(lua.messages, 'page:request')
    await transport.send('ui_response', { rid: second.rid, ok: false, error: { code: 'bad_request', message: 'no' } })
    await assert.rejects(() => failing, (err) => err.name === 'NuiError' && err.code === 'bad_request')
  })
})

describe('mock transport — state and events', () => {
  it('patch builds §38.10 ops: set, nested, Lua-view index, and delete when the value is left out', () => {
    const { lua } = createMockTransport()
    lua.patch('alpha', 'weight', 84.5)
    assert.deepEqual(lastOf(lua.messages, 'page:patch').ops, [{ p: 'weight', v: 84.5 }])
    // Lua's view, 1-based: `items.1` is the FIRST element. The path is passed through as written —
    // the shell is the side that maps `n` to `arr[n - 1]`.
    lua.patch('alpha', ['items', 1, 'count'], 3)
    assert.deepEqual(lastOf(lua.messages, 'page:patch').ops, [{ p: 'items.1.count', v: 3 }])
    lua.patch('alpha', 'slots.12', null)
    assert.deepEqual(lastOf(lua.messages, 'page:patch').ops, [{ p: 'slots.12', v: null }], 'null is a VALUE')
    lua.patch('alpha', 'slots.12')
    const del = lastOf(lua.messages, 'page:patch').ops[0]
    assert.equal(del.p, 'slots.12')
    assert.ok(!('v' in del), 'a delete op must have no `v` key at all')
  })

  it('update is a shallow merge of top-level keys and sends nothing when empty', () => {
    const { lua } = createMockTransport()
    lua.update('alpha', { weight: 84.5, maxWeight: 130 })
    assert.deepEqual(lastOf(lua.messages, 'page:patch').ops, [{ p: 'weight', v: 84.5 }, { p: 'maxWeight', v: 130 }])
    const before = lua.messages.length
    lua.update('alpha', {})
    assert.equal(lua.messages.length, before)
  })

  it('sees ui_event posts through onEvent', async () => {
    const { transport, lua } = createMockTransport()
    const seen = []
    const off = lua.onEvent('alpha', 'moveItem', (data) => seen.push(data))
    await transport.send('ui_event', { page: 'alpha', event: 'moveItem', data: { from: 1 } })
    await transport.send('ui_event', { page: 'alpha', event: 'other', data: {} })
    off()
    await transport.send('ui_event', { page: 'alpha', event: 'moveItem', data: { from: 2 } })
    assert.deepEqual(seen, [{ from: 1 }])
  })

  it('feed and emit carry the §38.5 shapes', () => {
    const { lua } = createMockTransport()
    lua.feed('alpha', { speed: 132 })
    assert.deepEqual(lastOf(lua.messages, 'feed').c, { alpha: { speed: 132 } })
    lua.emit('alpha', 'flash', { id: 'water' })
    const ev = lastOf(lua.messages, 'page:event')
    assert.equal(ev.id, 'alpha')
    assert.equal(ev.event, 'flash')
  })
})

describe('mock transport — focus (§38.9)', () => {
  it('derives page -> modal -> close the way client/ui.lua does', () => {
    const { lua } = createMockTransport()
    pages(lua)
    assert.deepEqual(lua.focus, [])

    lua.open('alpha')
    let focus = lastOf(lua.messages, 'focus')
    assert.equal(focus.focused, true)
    assert.deepEqual(focus.stack.map((e) => e.key), ['page:alpha'])
    assert.equal(focus.stack[0].owner, 'alpha')

    lua.open('alpha_confirm')
    focus = lastOf(lua.messages, 'focus')
    assert.deepEqual(focus.stack.map((e) => e.key), ['page:alpha', 'modal:alpha_confirm'])
    assert.deepEqual(focus.stack.map((e) => e.layer), ['page', 'modal'])

    lua.close('alpha_confirm')
    assert.deepEqual(lastOf(lua.messages, 'focus').stack.map((e) => e.key), ['page:alpha'])

    lua.close()
    focus = lastOf(lua.messages, 'focus')
    assert.equal(focus.focused, false)
    assert.deepEqual(focus.stack, [])
    assert.deepEqual(lua.openPages, [])
  })

  it('an overlay never enters the stack, and a second page replaces the first', () => {
    const { lua } = createMockTransport()
    pages(lua)
    lua.open('alpha_hotbar')
    assert.deepEqual(lastOf(lua.messages, 'focus').stack, [])
    assert.equal(lastOf(lua.messages, 'focus').focused, false)
    assert.deepEqual(lua.openPages, ['alpha_hotbar'])

    lua.open('alpha')
    lua.open('alpha_other')
    assert.deepEqual(lua.openPages, ['alpha_hotbar', 'alpha_other'])
    assert.deepEqual(lastOf(lua.messages, 'focus').stack.map((e) => e.key), ['page:alpha_other'])
  })

  it('a ui_close post from the shell closes that page', async () => {
    const { transport, lua } = createMockTransport()
    pages(lua)
    lua.open('alpha')
    await transport.send('ui_close', { page: 'alpha' })
    assert.deepEqual(lua.openPages, [])
    assert.equal(lastOf(lua.messages, 'focus').focused, false)
    assert.equal(lua.posts[lua.posts.length - 1].name, 'ui_close')
  })

  it('routes every message it sends into the injected deliver', () => {
    const seen = []
    const { lua } = createMockTransport({ deliver: (msg) => seen.push(msg.action) })
    pages(lua)
    lua.open('alpha')
    lua.clear()
    lua.close('alpha')
    assert.deepEqual(seen.slice(-2), ['page:close', 'focus'])
    assert.equal(lua.messages.length, 2, 'clear() empties the log but not the wire')
  })
})
