// core UI — one reactive store for every built-in widget (DESIGN §6.10, §7.2, §7.3)
//
// §38 split this file in two: the STATE stays here (one reactive object the whole shell reads), the
// page/plugin/focus/feed LOGIC moved into `src/runtime/*.ts` and is delegated to below. The store
// hands the runtime its own slices (`pages`, `openPage`, `overlays`, `modals`, `focusStack`,
// `plugins`) so there is still exactly one reactive graph and every existing import keeps working.
import { reactive } from 'vue'
import { post, onMessage } from './runtime/transport.ts'
import { CHAT_DEFAULTS, bounded } from './chat.js'
import * as Pages from './runtime/pages.ts'
import * as Plugins from './runtime/plugins.ts'
import * as Layers from './runtime/layers.ts'
import * as Feeds from './runtime/feeds.ts'
import * as Errors from './runtime/errors.ts'

const NOTIFY_DEFAULT_MS = 5000
const NOTIFY_MAX_VISIBLE = 6
const SHARD_DEFAULT_MS = 4000
const SHARD_STYLES = ['wasted', 'success', 'info']

// §32: the glass config `src/gameblur.js` reads on every tick (Config.UI.Blur on the Lua side,
// pushed with `blur:set` on `ui_ready` and on change).
const BLUR_DEFAULTS = { enabled: true, strength: 10, fps: 30, scale: 0.5 }
const BLUR_LIMITS = { strength: [0, 40], fps: [5, 60], scale: [0.1, 1] }

export const store = reactive({
  // §31: the whole shell is hidden while the client holds at least one hide reason
  // (pause menu, screen fade, player switch, warning, cutscene, or a plugin's
  // `Core.UI.hide`). Nothing unmounts — only `.core-root` stops painting.
  shell: { visible: true, reasons: [] },
  // §32: `data-core-blur` panels show the blurred game behind them; src/gameblur.js reads this
  // (and `shell.visible`) itself, so nothing is plumbed through App.vue.
  blur: Object.assign({}, BLUR_DEFAULTS),
  notifications: [],
  textui: { visible: false, key: '', text: '', position: 'bottom' },
  progress: { visible: false, id: null, label: '', duration: 0, canCancel: false, startedAt: 0 },
  menu: { visible: false, id: null, title: '', items: [] },
  input: { visible: false, id: null, title: '', fields: [], submit: 'OK', cancel: 'Cancel' },
  alert: { visible: false, id: null, title: '', message: '', confirm: 'OK', cancel: 'Cancel' },
  // §21 adds the hudfeed fields: health / armour / speed stay null until Lua pushes a
  // number, so a server without client/hudfeed.lua renders exactly the v1 HUD.
  hud: {
    visible: false, cash: 0, bank: 0, name: '', serverId: 0, faction: false,
    health: null, armour: null, speed: null, street: '', zone: '', minimap: null,
  },
  shard: { visible: false, seq: 0, title: '', subtitle: '', style: 'info', duration: 0 },
  spinner: { visible: false, text: '' },
  keys: { visible: false, items: [] },
  // §6.7: the world interaction dots — the normalized `worldprompts:set` items, replaced
  // wholesale (an empty list, or anything that is not an array, clears the layer).
  worldprompts: { items: [] },
  // §23: the CEF chat — lines carry a server-computed opacity (0..1); `suggestions`
  // is the TAB completer snapshot pushed by client/chat.lua; `channels` are the chips
  // the server says this player may use; `channel` is the selected chip (the server
  // still validates every send).
  chat: { ...CHAT_DEFAULTS, lines: [], suggestions: [], channels: [], channel: 'local', open: false, activity: 0 },
  stats: {},      // name -> { name, label, value, min, max } (Config.Stats defs with hud = true)
  state: {},      // replicated player state, read by pages through CoreUI.state
  locale: { lang: 'en', strings: {} },
  // §38.6: the page slice is owned by runtime/pages.ts (it is attached below) — the records live
  // here so every widget, story and test keeps reading one store.
  pages: {},      // id -> { id, type, owner, keepInput, component, registered, props, ... }
  openPage: null, // exclusive, type === 'page'
  overlays: {},   // id -> true (click-through, never focusable)
  modals: [],     // §38.9: plugin modals, in open order, above the page
  focusStack: [], // §38.9: the mirror of client/ui.lua's stack ({ key, layer, id?, owner })
  plugins: {},    // §38.2: resource -> { state, generation, build, ms, error, pages } (inspector)
  dev: { enabled: false, log: false, inspector: false },
  focused: false,
})

// One reactive graph: the runtime mutates THESE objects, never copies of them.
Pages.attachPageStore(store)
Plugins.attachPluginStore(store)
Layers.attachLayerStore(store)
Layers.setModalSource(() => store.modals)
Errors.setNotify((msg) => notify(msg))

const timers = new Map()          // non-reactive: notification + progress timeouts
let seq = 0

function setTimer(key, ms, fn) {
  clearTimer(key)
  timers.set(key, setTimeout(fn, ms))
}

function clearTimer(key) {
  const t = timers.get(key)
  if (t) clearTimeout(t)
  timers.delete(key)
}

/** True while a built-in modal owns the keyboard. Returns its name or null. */
export function activeModal() {
  if (store.alert.visible) return 'alert'
  if (store.input.visible) return 'input'
  if (store.menu.visible) return 'menu'
  return null
}

// ---------------------------------------------------------------- notifications

export function dismissNotification(id) {
  const i = store.notifications.findIndex((n) => n.id === id)
  if (i !== -1) store.notifications.splice(i, 1)
  clearTimer('n:' + id)
}

/** `notify` action: pushes, or bumps `count` on an identical visible toast. */
export function notify(msg) {
  const type = msg.type || 'info'
  const message = String(msg.message != null ? msg.message : '')
  const title = msg.title || ''
  const duration = Number(msg.duration) > 0 ? Number(msg.duration) : NOTIFY_DEFAULT_MS
  const count = Math.max(1, Number(msg.count) || 1)
  const same = store.notifications.find((n) => n.type === type && n.message === message && n.title === title)
  if (same) {
    same.count += count
    same.duration = duration
    setTimer('n:' + same.id, duration, () => dismissNotification(same.id))
    return same
  }
  const note = { id: msg.id != null ? msg.id : 'ui' + ++seq, type, message, title, duration, count }
  store.notifications.push(note)
  while (store.notifications.length > NOTIFY_MAX_VISIBLE) dismissNotification(store.notifications[0].id)
  setTimer('n:' + note.id, duration, () => dismissNotification(note.id))
  return note
}

// ---------------------------------------------------------------- result helpers
// Each clears its state first (optimistic close) and then posts; the matching
// `*:close` message Lua sends afterwards is a no-op.

export function menuResult(value) {
  const id = store.menu.id
  if (!store.menu.visible) return
  Object.assign(store.menu, { visible: false, id: null, title: '', items: [] })
  if (id != null) post('menu_result', { id, value: value === undefined ? null : value })
}

export function inputResult(values) {
  const id = store.input.id
  if (!store.input.visible) return
  Object.assign(store.input, { visible: false, id: null, title: '', fields: [] })
  if (id != null) post('input_result', { id, values: values === undefined ? null : values })
}

export function alertResult(confirmed) {
  const id = store.alert.id
  if (!store.alert.visible) return
  Object.assign(store.alert, { visible: false, id: null, title: '', message: '' })
  if (id != null) post('alert_result', { id, confirmed: !!confirmed })
}

function endProgress(callback) {
  const id = store.progress.id
  if (!store.progress.visible) return
  clearTimer('progress')
  Object.assign(store.progress, { visible: false, id: null, label: '', duration: 0, canCancel: false })
  if (id != null && callback) post(callback, { id })
}

export function progressCancel() {
  if (store.progress.visible && !store.progress.canCancel) return
  endProgress('progress_cancel')
}

export function progressDone() {
  endProgress('progress_done')
}

// ------------------------------------------------- shard / spinner / keys / stats
// All four are output only (DESIGN §21): no callback ever goes back to Lua.

/** Hides the shard banner. `seq` guards against a newer shard's timer firing late. */
export function hideShard(seq) {
  if (seq !== undefined && store.shard.seq !== seq) return
  clearTimer('shard')
  Object.assign(store.shard, { visible: false, title: '', subtitle: '' })
}

/** `keys:show` items: `{ key, label }`; anything without a key is dropped. */
function keyItems(items) {
  if (!Array.isArray(items)) return []
  const out = []
  for (const item of items) {
    if (!item) continue
    const key = String(item.key != null ? item.key : '')
    if (!key) continue
    out.push({ key, label: String(item.label != null ? item.label : '') })
  }
  return out
}

/** `worldprompts:set` items (§6.7): one dot per projected interaction. A slot is only drawable
 *  with a non-empty string id and finite x/y — anything else is dropped; the normalized screen
 *  coords are clamped to 0..1 and the text fields bounded, so a malformed Lua table cannot
 *  break the layer. Lua encodes an empty set as `{}`, not `[]` — that is no array either. */
const WP_MAX = { keys: 8, label: 96, icon: 32, description: 128 }
const wpIndex = new Map()          // id -> the stable item object the layer renders

function wpText(value, max) {
  const s = String(value != null ? value : '')
  return s.length > max ? s.slice(0, max) : s
}

/** A whole `worldprompts:set`, applied IN PLACE: an id keeps its object, so the component is
 *  reused and only the changed bindings re-render (a new object per message would re-patch the
 *  whole dot ~30×/s); the array identity is kept too, only reordered when the set changed. */
function applyWorldPrompts(items) {
  const list = Array.isArray(items) ? items : []
  const seen = new Set()
  const next = []
  for (const raw of list) {
    if (!raw || typeof raw !== 'object') continue
    if (typeof raw.id !== 'string' || !raw.id) continue
    const x = Number(raw.x)
    const y = Number(raw.y)
    if (!Number.isFinite(x) || !Number.isFinite(y)) continue
    let item = wpIndex.get(raw.id)
    if (!item) {
      // reactive(): the item is mutated in place on later messages, and a mutation through the
      // RAW object would never wake the render effect — the proxy is the observable identity.
      item = reactive({ id: raw.id, x: 0, y: 0, focused: false, disabled: false, keys: 'E', label: '', icon: '', description: '' })
      wpIndex.set(raw.id, item)
    }
    item.x = Math.min(1, Math.max(0, x))
    item.y = Math.min(1, Math.max(0, y))
    item.focused = !!raw.focused
    item.disabled = !!raw.disabled
    item.keys = wpText(raw.keys, WP_MAX.keys) || 'E'
    item.label = wpText(raw.label, WP_MAX.label)
    item.icon = wpText(raw.icon, WP_MAX.icon)
    item.description = wpText(raw.description, WP_MAX.description)
    seen.add(raw.id)
    next.push(item)
  }
  for (const id of Array.from(wpIndex.keys())) if (!seen.has(id)) wpIndex.delete(id)
  const current = store.worldprompts.items
  if (current.length !== next.length || next.some((item, i) => current[i] !== item)) {
    current.splice(0, current.length, ...next)
  }
}

/** Story/test helper: the world prompt layer starts empty. */
export function clearWorldPrompts() {
  wpIndex.clear()
  store.worldprompts.items.splice(0, store.worldprompts.items.length)
}

/** One `stats:set` entry -> a bar. Bad numbers collapse to a 0..100 bar at 0. */
function statEntry(name, raw) {
  const def = raw && typeof raw === 'object' ? raw : { value: raw }
  const min = Number.isFinite(Number(def.min)) ? Number(def.min) : 0
  const maxRaw = Number.isFinite(Number(def.max)) ? Number(def.max) : 100
  const max = maxRaw > min ? maxRaw : min + 100
  const value = Math.min(max, Math.max(min, Number(def.value) || 0))
  return { name, label: def.label ? String(def.label) : name, value, min, max }
}

// -------------------------------------------------------------------- game blur (§32)

/** Keeps a `blur:set` value inside its documented range; a non-number keeps the old one. */
function clampBlur(value, limit, current) {
  const n = Number(value)
  if (!Number.isFinite(n)) return current
  return Math.min(limit[1], Math.max(limit[0], n))
}

/** `blur:set` (Lua on `ui_ready` + on change, the dev shim, the Storybook control): a PARTIAL
 *  merge — a key the message leaves out keeps its current value. */
export function setBlur(config) {
  if (!config || typeof config !== 'object') return store.blur
  if (config.enabled !== undefined) store.blur.enabled = !!config.enabled
  if (config.strength !== undefined) store.blur.strength = clampBlur(config.strength, BLUR_LIMITS.strength, store.blur.strength)
  if (config.fps !== undefined) store.blur.fps = clampBlur(config.fps, BLUR_LIMITS.fps, store.blur.fps)
  if (config.scale !== undefined) store.blur.scale = clampBlur(config.scale, BLUR_LIMITS.scale, store.blur.scale)
  return store.blur
}

/** Story/test helper: back to a freshly loaded shell for everything §21, §31 and §32 added. */
export function resetExtras() {
  hideShard()
  Object.assign(store.shell, { visible: true, reasons: [] })
  Object.assign(store.blur, BLUR_DEFAULTS)
  Object.assign(store.spinner, { visible: false, text: '' })
  Object.assign(store.keys, { visible: false, items: [] })
  clearWorldPrompts()
  for (const name of Object.keys(store.stats)) delete store.stats[name]
  for (const key of Object.keys(store.state)) delete store.state[key]
  Object.assign(store.hud, { health: null, armour: null, speed: null, street: '', zone: '', minimap: null })
  store.chat.lines.splice(0, store.chat.lines.length)
  store.chat.suggestions = []
  Object.assign(store.chat, CHAT_DEFAULTS, { channels: [], channel: 'local', open: false, activity: store.chat.activity + 1 })
}

// ---------------------------------------------------------------- plugin pages (§38.6)
//
// Everything below is `runtime/pages.ts`, re-exported under its old name: 34 files import these
// from `store.js` and nothing about their behaviour changed. The props object of an id is still
// stable for the life of the shell (§7.4).

/** Escape / close button on a page, overlay or modal -> Lua decides, we hide right away. */
export const closePage = Pages.closePage
export const ensurePage = Pages.ensurePage
/** Called by a plugin bundle through CoreUI.registerPage — resolves pending opens. */
export const setPageComponent = Pages.setPageComponent
/** Resolves with the component, or null once `timeoutMs` passes (DESIGN §7.4: 5 s). */
export const whenRegistered = Pages.whenRegistered
export const onPageEvent = Pages.onPageEvent
/** The one props object of a page id (DESIGN §7.4). */
export const pageProps = Pages.propsFor

// ---------------------------------------------------------------- Lua -> NUI actions

const HUD_KEYS = [
  'visible', 'cash', 'bank', 'name', 'serverId', 'faction',
  'health', 'armour', 'speed', 'street', 'zone', 'minimap',
]

const actions = {
  notify,
  'textui:show': (m) => Object.assign(store.textui, {
    visible: true, key: m.key || '', text: m.text || '', position: m.position || 'bottom',
  }),
  'textui:hide': () => { store.textui.visible = false },
  'progress:start': (m) => {
    const duration = Number(m.duration) > 0 ? Number(m.duration) : 0
    clearTimer('progress')
    Object.assign(store.progress, {
      visible: true, id: m.id, label: m.label || '', duration, canCancel: !!m.canCancel, startedAt: Date.now(),
    })
    // The bar owns its own completion: Lua's promise resolves on `progress_done`.
    if (duration > 0) setTimer('progress', duration, () => { if (store.progress.id === m.id) progressDone() })
  },
  'progress:stop': (m) => {
    if (m.id != null && store.progress.id !== m.id) return
    clearTimer('progress')
    Object.assign(store.progress, { visible: false, id: null, label: '', duration: 0, canCancel: false })
  },
  'menu:open': (m) => Object.assign(store.menu, {
    visible: true, id: m.id, title: m.title || '', items: Array.isArray(m.items) ? m.items : [],
  }),
  'menu:close': () => Object.assign(store.menu, { visible: false, id: null, title: '', items: [] }),
  'input:open': (m) => Object.assign(store.input, {
    visible: true, id: m.id, title: m.title || '', fields: Array.isArray(m.fields) ? m.fields : [],
    submit: m.submit || 'OK', cancel: m.cancel === false ? false : m.cancel || 'Cancel',
  }),
  'input:close': () => Object.assign(store.input, { visible: false, id: null, title: '', fields: [] }),
  'alert:open': (m) => Object.assign(store.alert, {
    visible: true, id: m.id, title: m.title || '', message: m.message || '',
    confirm: m.confirm || 'OK', cancel: m.cancel === false ? false : m.cancel || 'Cancel',
  }),
  'alert:close': () => Object.assign(store.alert, { visible: false, id: null, title: '', message: '' }),
  'hud:set': (m) => {
    for (const key of HUD_KEYS) if (m[key] !== undefined) store.hud[key] = m[key]
  },
  'keys:show': (m) => Object.assign(store.keys, { visible: true, items: keyItems(m.items) }),
  'keys:hide': () => Object.assign(store.keys, { visible: false, items: [] }),
  // §6.7: whole-set replace (client/interactions.lua sends only when something changed);
  // an empty list clears the layer.
  'worldprompts:set': (m) => applyWorldPrompts(m.items),
  'shard:show': (m) => {
    const duration = Number(m.duration) > 0 ? Number(m.duration) : SHARD_DEFAULT_MS
    const next = store.shard.seq + 1   // re-keys the element so the animation replays
    Object.assign(store.shard, {
      visible: true,
      seq: next,
      title: m.title != null ? String(m.title) : '',
      subtitle: m.subtitle != null ? String(m.subtitle) : '',
      style: SHARD_STYLES.indexOf(m.style) === -1 ? 'info' : m.style,
      duration,
    })
    // The banner owns its own life: Lua fires and forgets (DESIGN §21).
    setTimer('shard', duration, () => hideShard(next))
  },
  'spinner:show': (m) => Object.assign(store.spinner, { visible: true, text: m.text != null ? String(m.text) : '' }),
  'spinner:hide': () => Object.assign(store.spinner, { visible: false, text: '' }),
  // Whole-table replace, like the `stats` state bag it mirrors (§18): a name that is no
  // longer in the message loses its bar. Entries sit at the top level (`{ hunger = … }`),
  // a `stats` sub-table is accepted too.
  'stats:set': (m) => {
    const src = m.stats && typeof m.stats === 'object' ? m.stats : m
    const seen = {}
    for (const name of Object.keys(src)) {
      if (name === 'action' || name === 'stats') continue
      seen[name] = true
      const entry = statEntry(name, src[name])
      if (store.stats[name]) Object.assign(store.stats[name], entry)
      else store.stats[name] = entry
    }
    for (const name of Object.keys(store.stats)) if (!seen[name]) delete store.stats[name]
  },
  'state:set': (m) => {
    if (!m) return
    // Lua batches a whole flush into `values`; the single key/value shape stays
    // supported for older senders. null/undefined always means "key is gone".
    const apply = (key, value) => {
      if (typeof key !== 'string' || !key) return
      if (value === undefined || value === null) delete store.state[key]
      else store.state[key] = value
    }
    if (m.values && typeof m.values === 'object') {
      for (const key of Object.keys(m.values)) apply(key, m.values[key])
      return
    }
    apply(m.key, m.value)
  },
  'locale:set': (m) => {
    store.locale.lang = m.lang ? String(m.lang) : 'en'
    const strings = m.strings && typeof m.strings === 'object' ? m.strings : {}
    store.locale.strings = Object.assign({}, strings)
  },
  // §23: one CEF line from client/chat.lua. The line is server-truth (opacity, channel,
  // color arrive validated); the shell only trims its own history length.
  'chat:add': (m) => {
    const line = m && typeof m.line === 'object' && m.line ? m.line : null
    if (!line || typeof line.text !== 'string') return
    store.chat.lines.push({ ...line, id: 'chat' + ++seq })
    store.chat.activity++
    if (store.chat.lines.length > store.chat.history) store.chat.lines.splice(0, store.chat.lines.length - store.chat.history)
  },
  'chat:clear': () => { store.chat.lines.splice(0, store.chat.lines.length); store.chat.activity++ },
  'chat:suggestions': (m) => {
    store.chat.suggestions = Array.isArray(m.items) ? m.items : []
    if (Array.isArray(m.channels)) store.chat.channels = m.channels
    if (!store.chat.channels.some(c => c.id === store.chat.channel)) store.chat.channel = 'local'
    store.chat.history = bounded(m.history, store.chat.history, 1, 200)
    store.chat.hideDelayMs = bounded(m.hideDelayMs, store.chat.hideDelayMs, 0, 600000)
    store.chat.visibleLines = bounded(m.visibleLines, store.chat.visibleLines, 1, 30)
    store.chat.maxLength = bounded(m.maxLength, store.chat.maxLength, 1, 256)
    if (store.chat.lines.length > store.chat.history) store.chat.lines.splice(0, store.chat.lines.length - store.chat.history)
  },
  // T (Lua) opens the input, ESC/submit closes it; Chat.vue watches the flag.
  'chat:open': (m) => { store.chat.open = m.open === true },
  // §38.5: a page is DECLARED by Lua (id, type, keepInput, owner); its component comes from the
  // owner's plugin. The `script`/`style` URL loader of §7.4 is gone.
  'page:register': (m) => Pages.registerPage(m),
  'page:unregister': (m) => Pages.unregisterPage(m.id),
  'page:open': (m) => Pages.openPage(m),
  'page:close': (m) => Pages.closePageAction(m),
  'page:patch': (m) => Pages.applyPatch(m.id, m.ops),
  'page:event': (m) => Pages.emitPageEvent(m.id, m.event, m.data),
  // §38.2: one activation of a resource's UI module. `page:request` is answered by runtime/host.ts,
  // which subscribes itself once the host object exists.
  'plugin:register': (m) => Plugins.register(m),
  'plugin:unregister': (m) => Plugins.unregister(m.id),
  // §38.10: coalesced telemetry — one rAF per frame, nothing while idle.
  feed: (m) => Feeds.applyFeed(m),
  // §38.11/§38.14: verbose lifecycle logs, the inspector and the page load deadline.
  'dev:set': (m) => {
    store.dev.enabled = !!m.enabled
    store.dev.log = !!m.log
    store.dev.inspector = !!m.inspector
    Plugins.setDevOptions({ enabled: store.dev.enabled, log: store.dev.log, loadTimeoutMs: m.loadTimeoutMs })
  },
  'inspector:toggle': () => {
    store.dev.inspector = !store.dev.inspector
  },
  // §31.4: one message per hidden<->visible flip (never per reason change), re-sent on
  // `ui_ready` while hidden so a NUI reload lands in the right state. Hiding only stops the
  // paint: timers, the progress bar and the HUD keep running underneath. `reasons` is
  // debug information for a page or the console — nothing in the shell branches on it.
  'shell:visible': (m) => Object.assign(store.shell, {
    visible: m.visible !== false,
    reasons: Array.isArray(m.reasons) ? m.reasons.map(String) : [],
  }),
  // §32.2: `{ action = 'blur:set', enabled, strength, fps, scale }`. src/gameblur.js watches
  // `store.blur`, so a message is all it takes to turn the glass off or re-tune it live.
  'blur:set': (m) => setBlur(m),
  // `/uiblur diag`: src/gameblur.js answers with a `blur_diag` post that Lua prints.
  'blur:diag': () => {
    try { window.dispatchEvent(new CustomEvent('core:blur-diag')) } catch (err) { /* no DOM */ }
  },
  'blur:test': () => {
    try { window.dispatchEvent(new CustomEvent('core:blur-test')) } catch (err) { /* no DOM */ }
  },
  // §38.9: `focus { focused, stack }`. client/ui.lua owns the stack and the natives; the shell only
  // mirrors it, for `inert` on the layers under a modal and for the Escape order.
  focus: (m) => Layers.applyFocus(m),
}

for (const action of Object.keys(actions)) onMessage(action, actions[action])

// ---------------------------------------------------------------- keyboard (DESIGN §7.3)

function isTextTarget(event) {
  const el = event.target
  if (!el || !el.tagName) return false
  return el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable === true
}

/** Escape -> the §38.9 order: kit escape layers (a capturing listener in kit/use.js already ran and
 *  stopped the event if a popup was open) -> the built-in menu/input/alert -> the top plugin modal
 *  -> the open page.
 *  x / Backspace -> cancel a cancellable progress bar. */
export function handleKeydown(event) {
  if (event.key === 'Escape') {
    const modal = activeModal()
    const target = Layers.escapeTarget(modal, store.openPage)
    if (target === 'builtin') {
      if (modal === 'alert') alertResult(false)
      else if (modal === 'input') inputResult(null)
      else if (modal === 'menu') menuResult(null)
    } else if (target === 'modal') closePage(Layers.topModalId())
    else if (target === 'page') closePage()
    else return
    event.preventDefault()
    return
  }
  if (!store.progress.visible || !store.progress.canCancel || isTextTarget(event)) return
  if (event.key === 'Backspace' || event.key === 'x' || event.key === 'X') {
    progressCancel()
    event.preventDefault()
  }
}

window.addEventListener('keydown', handleKeydown)
