// core UI — the Lua wire, observed (DESIGN §6.10).
//
// bridge.js calls two optional hooks on `window.__core`: `onPost(name, body)` for every
// NUI callback the shell fires and `onMessage(msg)` for every SendNUIMessage payload that
// reaches the page. This module installs them for Storybook, so a story's traffic shows up
// three ways at once:
//
//   * the Actions panel  — 'lua → nui: menu:open' / 'nui → lua: menu_result'
//   * the custom Lua panel (.storybook/lua-panel.js) — via the `core/lua` channel event
//   * `luaLog` — the same entries in order, which `play` functions assert against
//
// `parameters.lua.resolve(name, body) -> string|null` turns a callback back into the value
// the awaiting Lua call returns (`UI.menu.open(...) -> 'doors'`); it runs HERE, in the
// preview, because functions do not survive the trip to the manager iframe.
import { action } from 'storybook/actions'
import { addons } from 'storybook/preview-api'

export const LUA_EVENT = 'core/lua'       // one log entry
export const LUA_RESET = 'core/lua-reset' // story changed: drop the log, take new params
export const LUA_REQUEST = 'core/lua-request' // panel mounted late: replay what we have

/** Wire directions, exactly as the panel groups them. */
export const NUI_TO_LUA = 'nui→lua'
export const LUA_TO_NUI = 'lua→nui'
export const LUA_RESULT = 'lua-result'

/** Every entry of the current story, oldest first. Play functions read this. */
export const luaLog = []

let channel = null
let replayBound = false
let muted = false
let current = { id: null, lua: {} }

/** The preview channel only exists once the preview booted, so resolve it lazily. */
function chan () {
  if (channel) return channel
  try {
    channel = addons.getChannel()
  } catch (err) {
    channel = null
  }
  return channel
}

function push (entry) {
  if (muted) return
  luaLog.push(entry)
  const c = chan()
  if (c) c.emit(LUA_EVENT, entry)
}

/** Run `fn` without logging — used for the per-story store reset, which is not story traffic. */
export function withoutLog (fn) {
  muted = true
  try {
    return fn()
  } finally {
    muted = false
  }
}

export function resetLuaLog () {
  luaLog.length = 0
}

/** Callbacks the shell posted back to Lua (`menu_result`, `ui_event`, …). */
export function postsOf (name) {
  return luaLog.filter((e) => e.dir === NUI_TO_LUA && (!name || e.name === name))
}

/** Body of the last `post(name, body)` — `undefined` when it never happened. */
export function lastPost (name) {
  const list = postsOf(name)
  return list.length ? list[list.length - 1].body : undefined
}

/** Messages the story pushed into the shell (`menu:open`, `notify`, …). */
export function messagesOf (action_) {
  return luaLog.filter((e) => e.dir === LUA_TO_NUI && (!action_ || e.name === action_))
}

function replay () {
  const c = chan()
  if (!c) return
  c.emit(LUA_RESET, { id: current.id, lua: current.lua })
  for (const entry of luaLog) c.emit(LUA_EVENT, entry)
}

/** Global decorator (see .storybook/preview.js). Re-runs on every args change too, which is
 *  why it clears the log first: the story re-sends its message right after. */
export const luaChannel = (storyFn, context) => {
  const params = (context && context.parameters && context.parameters.lua) || {}
  const resolve = typeof params.resolve === 'function' ? params.resolve : null

  resetLuaLog()
  current = {
    id: context && context.id,
    lua: { call: params.call, message: params.message, callback: params.callback, note: params.note },
  }
  const c = chan()
  if (c) {
    c.emit(LUA_RESET, current)
    if (!replayBound) {
      replayBound = true
      c.on(LUA_REQUEST, replay)
    }
  }

  const shim = window.__core || (window.__core = {})
  shim.log = luaLog // handy from a devtools console: __core.log

  shim.onPost = (name, body) => {
    action('nui → lua: ' + name)(body)
    push({ dir: NUI_TO_LUA, name, body, at: Date.now() })
    if (!resolve) return
    const text = resolve(name, body)
    if (text) push({ dir: LUA_RESULT, name, text, at: Date.now() })
  }

  shim.onMessage = (msg) => {
    action('lua → nui: ' + msg.action)(msg)
    push({ dir: LUA_TO_NUI, name: msg.action, body: msg, at: Date.now() })
  }

  return storyFn()
}
