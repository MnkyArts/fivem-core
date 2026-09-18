// runtime/errors.ts — attribution, the production `info` URL and one report per instance (§38.12).
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import * as Errors from '../../src/runtime/errors.ts'
import { setTransport, resetTransport } from '../../src/runtime/transport.ts'

const posts: Array<{ name: string; body: Record<string, unknown> }> = []
const toasts: string[] = []
const realError = console.error

beforeEach(() => {
  posts.length = 0
  toasts.length = 0
  Errors.clearErrorLog()
  Errors.setOriginMap(null)
  Errors.setNotify((m) => toasts.push(String((m as { message: string }).message)))
  setTransport({
    send(name, body) {
      posts.push({ name, body: body as Record<string, unknown> })
      return Promise.resolve({})
    },
  })
  console.error = () => {}
})

function restore(): void {
  console.error = realError
  resetTransport()
}

test('errCode parses the production error-reference URL', () => {
  assert.equal(Errors.errCode('https://vuejs.org/error-reference/#runtime-5'), 5)
  assert.equal(Errors.errCode('https://vuejs.org/error-reference/#runtime-0'), 0)
  assert.equal(Errors.errCode('native event handler'), null)
  assert.equal(Errors.errCode(null), null)
  restore()
})

test('a handler error is reported but never replaces the subtree', () => {
  // 5 = native event handler, 6 = component event handler.
  assert.equal(Errors.isHandlerError('https://vuejs.org/error-reference/#runtime-5'), true)
  assert.equal(Errors.isHandlerError('https://vuejs.org/error-reference/#runtime-6'), true)
  assert.equal(Errors.isFatalRenderError('https://vuejs.org/error-reference/#runtime-5'), false)
  // The dev build's readable strings still work.
  assert.equal(Errors.isHandlerError('native event handler'), true)
  restore()
})

test('setup (0) and render (1) are fatal', () => {
  assert.equal(Errors.isFatalRenderError('https://vuejs.org/error-reference/#runtime-0'), true)
  assert.equal(Errors.isFatalRenderError('https://vuejs.org/error-reference/#runtime-1'), true)
  assert.equal(Errors.isFatalRenderError('render function'), true)
  restore()
})

test('attribute reads the resource out of a cfx-nui stack URL', () => {
  const err = new Error('boom')
  err.stack = 'Error: boom\n    at Proxy.render (https://cfx-nui-inventory/ui/dist/plugin.a1.js:4:120)'
  assert.equal(Errors.attribute(err), 'inventory')
  restore()
})

test('attribute falls back to a test-origin map', () => {
  const err = new Error('boom')
  err.stack = 'Error: boom\n    at http://127.0.0.1:8802/ui/dist/plugin.js:1:1'
  assert.equal(Errors.attribute(err), null)
  Errors.setOriginMap({ 'http://127.0.0.1:8802': 'alpha' })
  assert.equal(Errors.attribute(err), 'alpha')
  Errors.setOriginMap(null)
  restore()
})

test('attribute returns null for an error with no known origin', () => {
  assert.equal(Errors.attribute(new Error('plain')), null)
  assert.equal(Errors.attribute(null), null)
  restore()
})

test('report posts ui_error with the whole attribution and keeps a log', () => {
  const err = new Error('render exploded')
  err.stack = 'Error: render exploded\n    at https://cfx-nui-inventory/ui/dist/p.js:1:1'
  const rec = Errors.report({ page: 'inventory', component: 'Boom', error: err, info: 'https://vuejs.org/error-reference/#runtime-1' })
  assert.equal(rec?.plugin, 'inventory')
  assert.equal(rec?.page, 'inventory')
  assert.equal(rec?.component, 'Boom')
  assert.equal(rec?.message, 'render exploded')
  assert.ok(rec?.stack)
  const posted = posts.filter((p) => p.name === 'ui_error')
  assert.equal(posted.length, 1)
  assert.equal(posted[0].body.component, 'Boom')
  assert.equal(Errors.errorLog().length, 1)
  restore()
})

test('an explicit plugin beats the stack attribution', () => {
  const rec = Errors.report({ plugin: 'trucking', error: new Error('x') })
  assert.equal(rec?.plugin, 'trucking')
  restore()
})

test('`once` reports one crash per instance', () => {
  const instance = {}
  assert.ok(Errors.report({ error: new Error('a'), once: instance }))
  assert.equal(Errors.report({ error: new Error('b'), once: instance }), null)
  assert.equal(posts.filter((p) => p.name === 'ui_error').length, 1)
  restore()
})

test('componentName reads the <script setup> name off $.type.__name', () => {
  assert.equal(Errors.componentName({ $: { type: { __name: 'InventoryPage' } } }), 'InventoryPage')
  assert.equal(Errors.componentName({ type: { name: 'CoreButton' } }), 'CoreButton')
  assert.equal(Errors.componentName({ $options: { name: 'Old' } }), 'Old')
  assert.equal(Errors.componentName(null), '(anonymous)')
  restore()
})

test('guard swallows and attributes', () => {
  const out = Errors.guard({ plugin: 'alpha', page: 'a', info: 'hook' }, () => {
    throw new Error('hook exploded')
  })
  assert.equal(out, undefined)
  const posted = posts.filter((p) => p.name === 'ui_error')
  assert.equal(posted.length, 1)
  assert.equal(posted[0].body.plugin, 'alpha')
  assert.equal(posted[0].body.info, 'hook')
  restore()
})

test('the global net catches an error event and an unhandled rejection', () => {
  const target = new EventTarget()
  const off = Errors.installGlobalHandlers(target)
  const err = new Error('loose')
  err.stack = 'Error: loose\n    at https://cfx-nui-trucking/ui/dist/p.js:1:1'
  const ev = new Event('error') as Event & { error?: unknown }
  ev.error = err
  target.dispatchEvent(ev)
  const rej = new Event('unhandledrejection') as Event & { reason?: unknown }
  rej.reason = new Error('nobody caught me')
  target.dispatchEvent(rej)
  off()
  target.dispatchEvent(ev)
  const posted = posts.filter((p) => p.name === 'ui_error')
  assert.equal(posted.length, 2)
  assert.equal(posted[0].body.plugin, 'trucking')
  assert.equal(posted[1].body.info, 'unhandledrejection')
  restore()
})

test('the log keeps at most 50 entries', () => {
  for (let i = 0; i < 60; i++) Errors.report({ error: new Error('e' + i) })
  assert.equal(Errors.errorLog().length, 50)
  assert.equal(Errors.errorLog()[49].message, 'e59')
  restore()
})

test('an explicit name beats the SFC compiler\'s file name (S1)', () => {
  // `__name` is what @vue/compiler-sfc fills in from the FILE; `name` is what the author wrote.
  assert.equal(Errors.componentName({ $: { type: { name: 'InventoryGrid', __name: 'Page' } } }), 'InventoryGrid')
  assert.equal(Errors.componentName({ $: { type: { __name: 'Page' } } }), 'Page')
  restore()
})
