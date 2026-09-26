// runtime/layers.ts — the mirrored focus stack, `inert` and the Escape order (DESIGN §38.9).
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import * as Layers from '../../src/runtime/layers.ts'
import type { FocusEntry } from '../../src/runtime/protocol.ts'

const slice = { focused: false, focusStack: [] as FocusEntry[] }

const modes: Record<string, string> = {}

beforeEach(() => {
  Layers.attachLayerStore(slice)
  Layers.setModalSource(() => [])
  for (const id of Object.keys(modes)) delete modes[id]
  Layers.setInputSource((id) => modes[id] || 'ui')
  Layers.resetLayers()
})

test('applyFocus mirrors the stack IN PLACE and drops unknown layers', () => {
  const before = slice.focusStack
  Layers.applyFocus({
    focused: true,
    stack: [
      { key: 'page:inv', layer: 'page', id: 'inv', owner: 'inventory' },
      { key: 'nonsense', layer: 'wat' },
      { key: 'modal:confirm', layer: 'modal', id: 'confirm', owner: 'inventory' },
    ],
  })
  assert.equal(slice.focusStack, before, 'the array identity is kept')
  assert.equal(slice.focused, true)
  assert.equal(slice.focusStack.length, 2)
  assert.equal(slice.focusStack[1].id, 'confirm')
})

test('an empty focus message releases everything', () => {
  Layers.applyFocus({ focused: true, stack: [{ key: 'page:a', layer: 'page', id: 'a' }] })
  Layers.applyFocus({ focused: false, stack: [] })
  assert.equal(slice.focused, false)
  assert.equal(slice.focusStack.length, 0)
  assert.equal(Layers.topModalId(), null)
})

test('the top entry is the highest rank, then the most recent', () => {
  Layers.applyFocus({
    focused: true,
    stack: [
      { key: 'chat', layer: 'chat' },
      { key: 'page:inv', layer: 'page', id: 'inv' },
      { key: 'modal:a', layer: 'modal', id: 'a' },
      { key: 'modal:b', layer: 'modal', id: 'b' },
    ],
  })
  assert.equal(Layers.topEntry()?.key, 'modal:b')
  assert.equal(Layers.topModalId(), 'b')
  Layers.applyFocus({
    focused: true,
    stack: [
      { key: 'page:inv', layer: 'page', id: 'inv' },
      { key: 'modal:a', layer: 'modal', id: 'a' },
      { key: 'system:alert', layer: 'system' },
    ],
  })
  assert.equal(Layers.topEntry()?.layer, 'system')
})

test('inert: everything focusable below the top modal, never the top modal', () => {
  assert.equal(Layers.isInert('page'), false)
  Layers.applyFocus({
    focused: true,
    stack: [
      { key: 'page:inv', layer: 'page', id: 'inv' },
      { key: 'modal:a', layer: 'modal', id: 'a' },
      { key: 'modal:b', layer: 'modal', id: 'b' },
    ],
  })
  assert.equal(Layers.isInert('page'), true)
  assert.equal(Layers.isInert('modal', 'a'), true)
  assert.equal(Layers.isInert('modal', 'b'), false)
  assert.equal(Layers.isInert('overlay'), true)
})

test('with no focus message yet the shell falls back to its own modal list', () => {
  Layers.setModalSource(() => ['own1', 'own2'])
  assert.equal(Layers.topModalId(), 'own2')
  assert.deepEqual(Layers.modalIds(), ['own1', 'own2'])
  // Lua's stack wins as soon as it arrives.
  Layers.applyFocus({ focused: true, stack: [{ key: 'modal:lua', layer: 'modal', id: 'lua' }] })
  assert.equal(Layers.topModalId(), 'lua')
})

test('Escape order: built-in modal -> top plugin modal -> page -> nothing', () => {
  assert.equal(Layers.escapeTarget(null, null), null)
  assert.equal(Layers.escapeTarget(null, 'inv'), 'page')
  Layers.applyFocus({
    focused: true,
    stack: [
      { key: 'page:inv', layer: 'page', id: 'inv' },
      { key: 'modal:confirm', layer: 'modal', id: 'confirm' },
    ],
  })
  assert.equal(Layers.escapeTarget(null, 'inv'), 'modal')
  assert.equal(Layers.escapeTarget('alert', 'inv'), 'builtin')
})

test('hasSystemLayer reports a built-in dialog in the stack', () => {
  assert.equal(Layers.hasSystemLayer(), false)
  Layers.applyFocus({ focused: true, stack: [{ key: 'system:menu', layer: 'system' }] })
  assert.equal(Layers.hasSystemLayer(), true)
})

// ---------------------------------------------------------------- §41 input modes

test('a game modal is never the top modal: not the Escape target, never makes the page inert', () => {
  modes.hud_modal = 'game'
  Layers.setModalSource(() => ['hud_modal'])
  assert.equal(Layers.topModalId(), null, 'the fallback list skips a game modal')
  assert.deepEqual(Layers.modalIds(), [])
  assert.equal(Layers.isInert('page'), false, 'the page under it stays interactive')
  assert.equal(Layers.escapeTarget(null, 'inv'), 'page', 'Escape goes past it to the page')
  // A stale stack (page:input landed before the next focus message) is filtered the same way.
  Layers.applyFocus({
    focused: true,
    stack: [
      { key: 'page:inv', layer: 'page', id: 'inv' },
      { key: 'modal:confirm', layer: 'modal', id: 'confirm' },
      { key: 'modal:hud_modal', layer: 'modal', id: 'hud_modal' },
    ],
  })
  assert.equal(Layers.topModalId(), 'confirm', 'the highest modal that holds focus wins')
  assert.deepEqual(Layers.modalIds(), ['confirm'])
  assert.equal(Layers.isInert('modal', 'confirm'), false)
})

test('a game page is never the Escape target', () => {
  modes.editor = 'game'
  assert.equal(Layers.escapeTarget(null, 'editor'), null)
  modes.editor = 'look'
  assert.equal(Layers.escapeTarget(null, 'editor'), 'page', 'look still receives keyboard events')
  modes.editor = 'mixed'
  assert.equal(Layers.escapeTarget(null, 'editor'), 'page')
  modes.editor = 'game'
  assert.equal(Layers.escapeTarget('menu', 'editor'), 'builtin', 'a built-in above it still takes Escape')
})

// ---------------------------------------------------------------- §54: `shell:hud`

test('shell:hud hides the overlays of owners without a reason and keeps the holder\'s', () => {
  const hud = { hidden: false, keep: [] as string[] }
  Layers.attachHudStore(hud)
  const keepArray = hud.keep
  assert.equal(Layers.hudHidden(), false)
  assert.equal(Layers.overlayHidden('inventory'), false, 'nothing is hidden before the first message')

  Layers.applyHudHide({ action: 'shell:hud', hidden: true, keep: ['admin'] })
  assert.equal(Layers.hudHidden(), true)
  assert.equal(hud.hidden, true, 'the attached slice is written')
  assert.equal(hud.keep, keepArray, 'keep is replaced IN PLACE (one reactive array)')
  assert.deepEqual(hud.keep, ['admin'])
  assert.equal(Layers.overlayHidden('inventory'), true, 'another resource\'s overlay hides (the hotbar)')
  assert.equal(Layers.overlayHidden('admin'), false, 'the holder\'s own overlay stays (admin_hud)')
  assert.equal(Layers.overlayHidden(null), true, 'an overlay without an owner is core\'s — hidden unless core holds a reason')
  assert.equal(Layers.overlayHidden(undefined), true)

  // a second holder: its overlays come back, everybody else's stay hidden
  Layers.applyHudHide({ action: 'shell:hud', hidden: true, keep: ['admin', 'inventory'] })
  assert.equal(Layers.overlayHidden('inventory'), false)
  assert.equal(Layers.overlayHidden('smartphone'), true)

  Layers.applyHudHide({ action: 'shell:hud', hidden: false, keep: [] })
  assert.equal(Layers.hudHidden(), false)
  assert.deepEqual(hud.keep, [], 'showing again empties the keep list')
  assert.equal(Layers.overlayHidden('smartphone'), false, 'every overlay is back')
  Layers.attachHudStore({ hidden: false, keep: [] })
})

test('shell:hud normalizes what Lua can send', () => {
  const hud = { hidden: false, keep: [] as string[] }
  Layers.attachHudStore(hud)
  // Lua encodes an empty table as an OBJECT: it means "nobody holds a reason" (core itself hid it)
  Layers.applyHudHide({ action: 'shell:hud', hidden: true, keep: {} })
  assert.equal(hud.hidden, true)
  assert.deepEqual(hud.keep, [])
  assert.equal(Layers.overlayHidden('admin'), true)
  // junk entries and duplicates are dropped
  Layers.applyHudHide({ action: 'shell:hud', hidden: true, keep: ['admin', '', 7, null, 'admin', 'core'] as unknown as string[] })
  assert.deepEqual(hud.keep, ['admin', 'core'])
  assert.equal(Layers.overlayHidden(null), false, 'core in keep keeps the owner-less overlays')
  // a malformed message is a VISIBLE hud — never one that stays hidden for good
  Layers.applyHudHide(null)
  assert.equal(hud.hidden, false)
  Layers.applyHudHide({ action: 'shell:hud', hidden: 'yes' as unknown as boolean, keep: ['admin'] })
  assert.equal(hud.hidden, false, 'only a real `true` hides')
  assert.deepEqual(hud.keep, [], 'and a visible hud keeps nobody')
  // resetLayers() (stories, the dev host) puts it back as well
  Layers.applyHudHide({ action: 'shell:hud', hidden: true, keep: ['admin'] })
  Layers.resetLayers()
  assert.equal(hud.hidden, false)
  assert.deepEqual(hud.keep, [])
  Layers.attachHudStore({ hidden: false, keep: [] })
})
