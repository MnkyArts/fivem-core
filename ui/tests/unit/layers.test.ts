// runtime/layers.ts — the mirrored focus stack, `inert` and the Escape order (DESIGN §38.9).
import { test, beforeEach } from 'node:test'
import assert from 'node:assert/strict'
import * as Layers from '../../src/runtime/layers.ts'
import type { FocusEntry } from '../../src/runtime/protocol.ts'

const slice = { focused: false, focusStack: [] as FocusEntry[] }

beforeEach(() => {
  Layers.attachLayerStore(slice)
  Layers.setModalSource(() => [])
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
