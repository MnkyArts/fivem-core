// DESIGN §41 across the pieces a browser dev host wires together: the SDK's fake Lua
// (`@core/ui/dev` mock) speaks `page:input` and the extended `page:register`, and the shell runtime
// that receives them (pages.ts + layers.ts) turns them into the page's input mode, the Escape policy
// and the mirrored focus stack — without a DOM.
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import { createMockTransport } from '../../sdk/src/dev/mock.ts'
import type { MockMessage } from '../../sdk/src/dev/mock.ts'
import * as Pages from '../../src/runtime/pages.ts'
import * as Layers from '../../src/runtime/layers.ts'
import { setTransport, resetTransport } from '../../src/runtime/transport.ts'
import type { FocusEntry, MsgFocus, MsgPageInput, MsgPageOpen, MsgPageRegister } from '../../src/runtime/protocol.ts'

const COMPONENT = { name: 'FakePage', render: () => null }
const layerSlice = { focused: false, focusStack: [] as FocusEntry[] }

/** What `store.js` does with each message, minus the DOM: the runtime handlers themselves. */
function deliver(msg: MockMessage): void {
  if (msg.action === 'page:register') Pages.registerPage(msg as unknown as MsgPageRegister)
  else if (msg.action === 'page:input') Pages.setPageInput(msg as unknown as MsgPageInput)
  else if (msg.action === 'page:open') Pages.openPage(msg as unknown as MsgPageOpen)
  else if (msg.action === 'page:close') Pages.closePageAction(msg as { id?: string })
  else if (msg.action === 'focus') Layers.applyFocus(msg as unknown as MsgFocus)
}

beforeEach(() => {
  Pages.resetPages()
  Layers.attachLayerStore(layerSlice)
  Layers.setModalSource(() => Pages.pageState().modals)
  Layers.resetLayers()
  Pages.setPageComponent('editor', COMPONENT)
  Pages.setPageComponent('editor_confirm', COMPONENT)
})

test('the mock declares input and escape the way client/ui.lua does', () => {
  const { lua } = createMockTransport({ deliver })
  lua.registerPlugin('editor', {
    pages: {
      editor: { type: 'page', input: 'game', escape: 'event' },
      editor_confirm: 'modal',
      editor_legacy: { keepInput: true },
    },
  })
  const regs = lua.messages.filter((m) => m.action === 'page:register')
  assert.equal(regs[0].input, 'game')
  assert.equal(regs[0].escape, 'event')
  assert.equal(regs[0].keepInput, false)
  assert.equal(regs[1].input, 'ui', 'a bare type string is a ui page')
  assert.equal(regs[1].escape, 'close')
  assert.equal(regs[2].input, 'mixed', 'keepInput alone is mixed')
  assert.equal(regs[2].keepInput, true)
  const pages = Pages.pageState().pages
  assert.equal(pages.editor.input, 'game', 'and the runtime stored it')
  assert.equal(pages.editor.escape, 'event')
})

test('a game page holds no focus entry; setInput brings it back', () => {
  const { lua } = createMockTransport({ deliver })
  lua.registerPlugin('editor', { pages: { editor: { type: 'page', input: 'game' }, editor_confirm: 'modal' } })
  lua.open('editor')
  assert.equal(lua.focus.length, 0, 'no entry for a game page')
  assert.equal(layerSlice.focused, false)
  assert.equal(Layers.escapeTarget(null, Pages.pageState().openPage), null, 'Escape has no target')

  lua.setInput('editor', 'ui')
  const input = lua.messages.filter((m) => m.action === 'page:input')
  assert.equal(input.length, 1, 'one page:input')
  assert.equal(input[0].input, 'ui')
  assert.equal(Pages.pageHandle('editor').input, 'ui', 'the page reads the new mode')
  assert.deepEqual(lua.focus.map((e) => e.key), ['page:editor'], 'and holds focus again')
  assert.equal(Layers.escapeTarget(null, Pages.pageState().openPage), 'page')

  const before = lua.messages.length
  lua.setInput('editor', 'ui')
  assert.equal(lua.messages.length, before, 'the same mode sends nothing')

  lua.open('editor_confirm')
  assert.deepEqual(lua.focus.map((e) => e.key), ['page:editor', 'modal:editor_confirm'])
  lua.setInput('editor_confirm', 'game')
  assert.deepEqual(lua.focus.map((e) => e.key), ['page:editor'], 'a game modal leaves the stack')
  assert.equal(Layers.topModalId(), null, 'and is not the top modal in the mirror')
  assert.equal(Layers.isInert('page'), false, 'so the page under it is not inert')
})

test("Escape = 'event' through the mock: the page stays, the mock hears the escape event", () => {
  const { lua, transport } = createMockTransport({ deliver })
  setTransport(transport)
  lua.registerPlugin('editor', { pages: { editor: { type: 'page', escape: 'event' } } })
  lua.open('editor')
  const heard: unknown[] = []
  lua.onEvent('editor', 'escape', (data) => { heard.push(data) })
  assert.equal(Pages.escapePage(Pages.pageState().openPage), 'event')
  assert.equal(heard.length, 1, 'the mock saw ui_event escape')
  assert.deepEqual(lua.openPages, ['editor'], 'nothing was closed')
  assert.ok(!lua.posts.some((p) => p.name === 'ui_close'))
  resetTransport()
})
