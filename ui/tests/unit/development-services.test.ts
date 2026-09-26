// Built-in modal protocol uses the production reactive store and transport.
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { deliver, setTransport } from '../../src/runtime/transport.ts'
// The store only needs event registration; no DOM or component implementation is mocked.
;(globalThis as unknown as {window: unknown}).window = {addEventListener() {}}
const { store, activeModal, skillCheckResult, handleKeydown, inputResult, menuResult, menuChange, setMenuBackHandler } = await import('../../src/store.js')

const posts: Array<{name: string; body: unknown}> = []
beforeEach(() => {
  for (const kind of ['menu', 'input', 'alert', 'skillcheck']) deliver({action: kind + ':close'})
  posts.length = 0
  setTransport({send(name, body) { posts.push({name, body}); return Promise.resolve({}) }})
})
function open(canCancel = true): void {
  deliver({action: 'skillcheck:open', id: 42, difficulty: ['easy', {speed: 50, areaSize: 20}], keys: ['e'], canCancel})
}
function escape(): void { handleKeydown({key: 'Escape', preventDefault() {}, defaultPrevented: false}) }

test('skill-check participates in the existing modal stack', () => {
  open()
  assert.equal(activeModal(), 'skillcheck')
  assert.equal(store.skillcheck.visible, true)
  assert.equal(store.skillcheck.id, 42)
  assert.equal(store.skillcheck.difficulty.length, 2)
})
test('successful skill-check posts once and releases its store state', () => {
  open()
  skillCheckResult(true)
  skillCheckResult(true)
  assert.equal(store.skillcheck.visible, false)
  assert.deepEqual(posts, [{name: 'skillcheck_result', body: {id: 42, success: true}}])
})
test('Escape reports failure rather than success', () => {
  open()
  escape()
  assert.equal(activeModal(), null)
  assert.deepEqual(posts, [{name: 'skillcheck_result', body: {id: 42, success: false}}])
})
test('non-cancellable skill-check ignores Escape but server close still wins', () => {
  open(false)
  escape()
  assert.equal(store.skillcheck.visible, true)
  assert.equal(posts.length, 0)
  deliver({action: 'skillcheck:close', id: 42})
  assert.equal(store.skillcheck.visible, false)
})
test('stale close cannot dismiss a newer skill-check', () => {
  open()
  deliver({action: 'skillcheck:close', id: 41})
  assert.equal(store.skillcheck.visible, true)
  deliver({action: 'skillcheck:close', id: 42})
  assert.equal(posts.length, 0)
})
test('expanded form preserves boolean and multiple-selection result types', () => {
  deliver({action: 'input:open', id: 9, fields: [{name:'tags',type:'multiselect',options:['a','b']}]})
  inputResult({tags: ['a','b'], consent: false, amount: 0})
  assert.deepEqual(posts, [{name: 'input_result', body: {id: 9, values: {tags:['a','b'],consent:false,amount:0}}}])
})
test('ordinary menu return contract remains scalar', () => {
  deliver({action:'menu:open', id:10, items:[{label:'Choose',value:3}]})
  menuResult(3)
  assert.deepEqual(posts, [{name:'menu_result',body:{id:10,value:3}}])
})

test('rejected menu changes remain open and return false', async () => {
  setTransport({send() { return Promise.resolve({ok:false}) }})
  deliver({action:'menu:open', id:10, items:[{label:'Enabled',value:3,checked:false}]})
  assert.equal(await menuChange(3, {checked:true}), false)
  assert.equal(store.menu.visible, true)
  assert.equal((store.menu.items as Array<{checked: boolean}>)[0].checked, false)
})

test('unknown menu delivery closes instead of retaining uncertain state', async () => {
  deliver({action:'menu:open', id:10, items:[{label:'Enabled',value:3,checked:false}]})
  assert.equal(await menuChange(3, {checked:true}), false)
  assert.equal(store.menu.visible, false)
  assert.deepEqual(posts.map(p => p.name), ['menu_change', 'menu_result'])
})

test('late menu acknowledgement cannot change a replacement', async () => {
  let answer: (value: Record<string, unknown>) => void = () => {}
  setTransport({send() { return new Promise(resolve => { answer = resolve }) }})
  deliver({action:'menu:open', id:10, items:[{label:'Old',value:3,checked:false}]})
  const pending = menuChange(3, {checked:true})
  deliver({action:'menu:open', id:11, items:[{label:'New',value:3,checked:false}]})
  answer({ok:true})
  assert.equal(await pending, false)
  assert.equal(store.menu.id, 11)
  assert.equal((store.menu.items as Array<{checked: boolean}>)[0].checked, false)
})

test('central Escape handler navigates back before closing the root menu', () => {
  let depth = 1
  const dispose = setMenuBackHandler(() => { if (!depth) return false; depth--; return true })
  try {
    deliver({action:'menu:open', id:10, items:[{label:'Nested',value:3}]})
    escape()
    assert.equal(depth, 0)
    assert.equal(store.menu.visible, true)
    assert.equal(posts.length, 0)
    escape()
    assert.equal(store.menu.visible, false)
    assert.deepEqual(posts, [{name:'menu_result',body:{id:10,value:null}}])
  } finally { dispose() }
})
