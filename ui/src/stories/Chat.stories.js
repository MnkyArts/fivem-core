// Chat stories exercise the same messages and keyboard path as the CEF shell (§30.3).
import { h } from 'vue'
import { expect, waitFor } from 'storybook/test'
import Chat from '../components/Chat.vue'
import { resetExtras } from '../store.js'
import { send, liveScene, clone } from './storeHelpers.js'

const lines = [
  { id: 1, text: 'Welcome to the server', kind: 'system', color: [170, 185, 200] },
  { id: 2, name: 'Ada', text: 'Anyone got a wrench?', tag: '[LS] ', opacity: 1 },
  { id: 3, name: 'Bruno', text: 'Garage has one. On my way.', opacity: 0.55 },
  { id: 4, name: 'Cleo', text: 'See you there.', opacity: 0.3 },
]
const suggestions = [
  { command: '/car', description: 'Spawn a vehicle', params: [
    { name: '<model>', type: 'string', help: 'Vehicle model name' },
    { name: '[plate]', type: 'string', optional: true, help: 'Custom number plate' },
  ] },
  { command: '/me', description: 'A nearby roleplay action', params: [{ name: '<message>', type: 'rest' }] },
  { command: '/ooc', description: 'Out-of-character chat', params: [{ name: '<message>', type: 'rest' }] },
  { command: '/pm', description: 'Send a private message', params: [
    { name: '<target>', type: 'player', help: 'Recipient server ID' },
    { name: '<message>', type: 'rest', help: 'Your private message' },
  ] },
]
const render = liveScene(args => {
  resetExtras()
  send({ action: 'chat:suggestions', items: clone(suggestions), hideDelayMs: args.hideDelayMs,
    channels: [{ id: 'local', label: 'Local' }, { id: 'ooc', label: 'OOC', command: 'ooc' }] })
  for (const line of clone(args.lines)) send({ action: 'chat:add', line })
  send({ action: 'chat:open', open: !!args.open })
}, () => h(Chat))

const inputOf = async canvas => {
  await waitFor(() => expect(canvas.querySelector('.chat input')).not.toBeNull())
  return canvas.querySelector('.chat input')
}
const type = (input, text) => {
  input.value = text
  input.dispatchEvent(new Event('input', { bubbles: true }))
}
const key = (input, key) => input.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true, cancelable: true }))

export default {
  title: 'Built-ins/Chat', component: Chat, render,
  parameters: {
    layout: 'fullscreen',
    docs: { description: { component: 'Quiet, unboxed chat. New messages wake the feed; it fades after eight seconds. T restores history. Slash opens command suggestions; arrows select, Tab completes, argument hints follow the caret. Server-owned routing and proximity opacity.' } },
    lua: { message: 'chat:add', note: 'Config.Chat.HideDelayMs controls inactivity; 0 keeps story previews visible.' },
  },
  args: { lines, open: false, hideDelayMs: 0 },
  argTypes: {
    lines: { control: 'object' }, open: { control: 'boolean' }, hideDelayMs: { control: 'number' },
  },
}

export const Feed = {
  name: 'Quiet proximity feed',
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.line')).toHaveLength(4))
    expect(canvasElement.querySelectorAll('.line')[1].textContent).toBe('[LS] Ada: Anyone got a wrench?')
    expect(canvasElement.querySelectorAll('.line')[2].style.opacity).toBe('0.55')
  },
}

export const Input = {
  name: 'Reading and typing', args: { open: true },
  play: async ({ canvasElement }) => {
    const input = await inputOf(canvasElement)
    expect(input).toHaveFocus()
    expect(canvasElement.querySelectorAll('.line')[2].style.opacity).toBe('1')
    type(input, 'See you at the garage')
    key(input, 'Tab')
    expect(input.value).toBe('See you at the garage')
  },
}

export const Commands = {
  name: 'Command picker', args: { open: true },
  play: async ({ canvasElement }) => {
    const input = await inputOf(canvasElement)
    type(input, '/')
    await waitFor(() => expect(canvasElement.querySelectorAll('.command-option')).toHaveLength(4))
    key(input, 'ArrowDown')
    await waitFor(() => expect(canvasElement.querySelector('[aria-selected="true"]')).toHaveTextContent('/me'))
    expect(input.value).toBe('/')
    key(input, 'Tab')
    await waitFor(() => expect(input.value).toBe('/me '))
    type(input, '/') // leave the command picker visible for inspection
  },
}

export const ArgumentHints = {
  name: 'Argument at the caret', args: { open: true },
  play: async ({ canvasElement }) => {
    const input = await inputOf(canvasElement)
    type(input, '/pm 12 Meet me at the garage')
    await waitFor(() => expect(canvasElement.querySelector('.param-active')).toHaveTextContent('<message>'))
    input.setSelectionRange(5, 5)
    input.dispatchEvent(new Event('select'))
    await waitFor(() => expect(canvasElement.querySelector('.param-active')).toHaveTextContent('<target>'))
    type(input, '/pm 12 Meet me at the garage')
  },
}

export const OptionalArgument = {
  name: 'Optional argument help', args: { open: true },
  play: async ({ canvasElement }) => {
    const input = await inputOf(canvasElement)
    type(input, '/car sultan ')
    await waitFor(() => expect(canvasElement.querySelector('.param-active')).toHaveTextContent('[plate]'))
    expect(canvasElement.querySelector('#chat-argument-help')).toHaveTextContent('optional')
  },
}

export const AutoHide = {
  name: 'Idle fade and history restore', args: { hideDelayMs: 600 },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.feed')).toHaveClass('feed-visible'))
    await waitFor(() => expect(canvasElement.querySelector('.feed')).not.toHaveClass('feed-visible'), { timeout: 2000 })
    send({ action: 'chat:open', open: true })
    await inputOf(canvasElement)
    await waitFor(() => expect(canvasElement.querySelector('.feed')).toHaveClass('feed-visible'))
    expect(canvasElement.querySelectorAll('.line')).toHaveLength(4)
  },
}
