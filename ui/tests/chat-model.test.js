import { test } from 'node:test'
import assert from 'node:assert/strict'
import { commandPool, commandContext, completeCommand, tokensOf, limitBytes, bounded } from '../src/chat.js'

const pm = { command: '/pm', description: 'Private message', params: [
  { name: '<target>', type: 'player', help: 'Server ID' },
  { name: '<message>', type: 'rest', help: 'Message' },
] }
const pool = commandPool([pm, { command: '/ping', params: [] }])
const context = (text, caret = text.length) => commandContext(text, caret, pool)

test('command pool deduplicates while retaining descriptions and argument metadata', () => {
  const result = commandPool([{ command: '/pm' }, pm, null, { command: 'bad' }, { command: '/two words' }])
  assert.equal(result.length, 1)
  assert.equal(result[0].description, pm.description)
  assert.equal(result[0].params[1].type, 'rest')
  const channels = commandPool([], [{ id: 'faction', command: 'fc', label: 'Faction' }])
  assert.equal(channels[0].command, '/fc')
  assert.equal(channels[0].params[0].type, 'rest')
})

test('slash filters case-insensitively and ordinary messages have no completions', () => {
  assert.equal(context('/').matches.length, 2)
  assert.equal(context('/P').matches.length, 2)
  assert.equal(context('/pm').matches.length, 1)
  assert.equal(context('hello').matches.length, 0)
  assert.equal(context('/unknown').matches.length, 0)
  assert.equal(context('/pm ').matches.length, 0)
})

test('the argument under the caret is active, not always the final argument', () => {
  assert.equal(context('/pm ').argument, 0)
  assert.equal(context('/pm 12').argument, 0)
  assert.equal(context('/pm 12 ').argument, 1)
  assert.equal(context('/pm 12 hello there ').argument, 1)
  assert.equal(context('/pm 12 hello there', 5).argument, 0)
  assert.equal(context('/pm 12 hello there', 2).argument, -1)
  assert.equal(context('/ping extra').argument, -1)
})

test('quoted and unfinished quoted values occupy one argument slot', () => {
  const command = [{ command: '/car', params: [{ name: '<model>' }, { name: '[plate]', optional: true }] }]
  assert.equal(commandContext('/car "two words" ', 17, command).argument, 1)
  assert.equal(commandContext('/car "two words', 15, command).argument, 0)
  assert.equal(commandContext('/car model    plate', 11, command).argument, 1)
  assert.equal(tokensOf('/car "two \\"quoted\\" words" plate'.replaceAll('\\\\', '\\')).length, 3)
})

test('completion replaces only the command token and retains arguments verbatim', () => {
  assert.deepEqual(completeCommand('/p', '/pm'), { text: '/pm ', caret: 4 })
  assert.deepEqual(completeCommand('/p 12 "hello world"', '/pm'), { text: '/pm 12 "hello world"', caret: 4 })
})

test('UTF-8 limits preserve whole code points', () => {
  assert.equal(limitBytes('hello', 4), 'hell')
  assert.equal(limitBytes('äöü', 5), 'äö')
  assert.equal(limitBytes('a😀b', 4), 'a')
  assert.equal(limitBytes('a😀b', 5), 'a😀')
})

test('configuration clamps finite numbers and ignores invalid shapes', () => {
  assert.equal(bounded(Infinity, 80, 1, 200), 80)
  assert.equal(bounded('40', 80, 1, 200), 80)
  assert.equal(bounded(800, 80, 1, 200), 200)
  assert.equal(bounded(2.9, 80, 1, 200), 2)
  assert.equal(bounded(0, 8000, 0, 600000), 0)
})
