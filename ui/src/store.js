// core UI — one reactive store for every built-in widget (DESIGN §6.10, §7.2, §7.3)
import { reactive, markRaw } from 'vue'
import { post, onMessage } from './bridge.js'

const NOTIFY_DEFAULT_MS = 5000
const NOTIFY_MAX_VISIBLE = 6
const SHARD_DEFAULT_MS = 4000
const SHARD_STYLES = ['wasted', 'success', 'info']

export const store = reactive({
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
  stats: {},      // name -> { name, label, value, min, max } (Config.Stats defs with hud = true)
  state: {},      // replicated player state, read by pages through CoreUI.state
  locale: { lang: 'en', strings: {} },
  pages: {},      // id -> { id, type, script, style, keepInput, component, registered, props }
  openPage: null, // exclusive, type === 'page'
  overlays: {},   // id -> true
  focused: false,
})

const timers = new Map()          // non-reactive: notification + progress timeouts
const pageListeners = new Map()   // `${page}|${event}` -> Set<fn>
const waiters = new Map()         // page id -> Set<resolve>  (open before the bundle registered)
const components = new Map()      // page id -> component, so a re-register never drops it
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

/** One `stats:set` entry -> a bar. Bad numbers collapse to a 0..100 bar at 0. */
function statEntry(name, raw) {
  const def = raw && typeof raw === 'object' ? raw : { value: raw }
  const min = Number.isFinite(Number(def.min)) ? Number(def.min) : 0
  const maxRaw = Number.isFinite(Number(def.max)) ? Number(def.max) : 100
  const max = maxRaw > min ? maxRaw : min + 100
  const value = Math.min(max, Math.max(min, Number(def.value) || 0))
  return { name, label: def.label ? String(def.label) : name, value, min, max }
}

/** Story/test helper: back to a freshly loaded shell for everything §21 added. */
export function resetExtras() {
  hideShard()
  Object.assign(store.spinner, { visible: false, text: '' })
  Object.assign(store.keys, { visible: false, items: [] })
  for (const name of Object.keys(store.stats)) delete store.stats[name]
  for (const key of Object.keys(store.state)) delete store.state[key]
  Object.assign(store.hud, { health: null, armour: null, speed: null, street: '', zone: '', minimap: null })
}

/** Escape / close button on a page or overlay -> Lua decides, we hide right away. */
export function closePage(id) {
  const page = id || store.openPage
  if (!page) return
  if (store.openPage === page) store.openPage = null
  if (store.overlays[page]) delete store.overlays[page]
  post('ui_close', { page })
}

// ---------------------------------------------------------------- plugin pages

/** A fresh page record that keeps a component already registered for this id — pages
 *  compiled into the shell (src/plugins.js) register once, Lua may re-register any time. */
function newPage(id, extra) {
  const component = components.get(id) || null
  return Object.assign(
    { id, type: 'page', script: null, style: null, keepInput: false, component, registered: !!component, props: {} },
    extra
  )
}

export function ensurePage(id) {
  let page = store.pages[id]
  if (!page) {
    page = newPage(id)
    store.pages[id] = page
  }
  return page
}

function setProps(page, props) {
  for (const key of Object.keys(page.props)) delete page.props[key]
  if (props && typeof props === 'object') Object.assign(page.props, props)
}

/** Called by a plugin bundle through CoreUI.registerPage — resolves pending opens. */
export function setPageComponent(id, component) {
  const raw = component ? markRaw(component) : null
  if (raw) components.set(id, raw)
  else components.delete(id)
  const page = ensurePage(id)
  page.component = raw
  page.registered = !!raw
  const set = waiters.get(id)
  if (!set) return page
  waiters.delete(id)
  for (const resolve of Array.from(set)) resolve(page.component)
  return page
}

/** Resolves with the component, or null once `timeoutMs` passes (DESIGN §7.4: 5 s). */
export function whenRegistered(id, timeoutMs = 5000) {
  const page = store.pages[id]
  if (page && page.component) return Promise.resolve(page.component)
  return new Promise((resolve) => {
    let set = waiters.get(id)
    if (!set) {
      set = new Set()
      waiters.set(id, set)
    }
    const done = (component) => {
      set.delete(done)
      resolve(component || null)
    }
    set.add(done)
    setTimeout(() => {
      if (set.has(done)) done(null)
    }, timeoutMs)
  })
}

export function onPageEvent(page, event, fn) {
  const key = page + '|' + event
  let set = pageListeners.get(key)
  if (!set) {
    set = new Set()
    pageListeners.set(key, set)
  }
  set.add(fn)
  return () => set.delete(fn)
}

function emitPageEvent(page, event, data) {
  const set = pageListeners.get(page + '|' + event)
  if (!set) return
  for (const fn of Array.from(set)) {
    try {
      fn(data)
    } catch (err) {
      console.error('[core:ui] page event failed', page, event, err)
    }
  }
}

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
  'page:register': (m) => {
    const script = m.script || null
    const prev = store.pages[m.id]
    // Same source keeps the live record. `script: null` is the normal case now: the page is
    // compiled into this bundle, so it is registered before Lua ever says hello (DESIGN §7.4).
    if (prev && prev.script === script) {
      Object.assign(prev, { type: m.type || 'page', style: m.style || null, keepInput: !!m.keepInput })
      return
    }
    store.pages[m.id] = newPage(m.id, {
      type: m.type || 'page', script, style: m.style || null, keepInput: !!m.keepInput,
    })
  },
  'page:unregister': (m) => {
    if (store.openPage === m.id) store.openPage = null
    delete store.overlays[m.id]
    delete store.pages[m.id]
  },
  'page:open': (m) => {
    const page = ensurePage(m.id)
    setProps(page, m.props)
    if (page.type === 'overlay') store.overlays[m.id] = true
    else store.openPage = m.id
  },
  'page:close': (m) => {
    const id = m.id || store.openPage
    if (!id) return
    if (store.openPage === id) store.openPage = null
    delete store.overlays[id]
  },
  'page:event': (m) => emitPageEvent(m.id, m.event, m.data),
  focus: (m) => { store.focused = !!m.focused },
}

for (const action of Object.keys(actions)) onMessage(action, actions[action])

// ---------------------------------------------------------------- keyboard (DESIGN §7.3)

function isTextTarget(event) {
  const el = event.target
  if (!el || !el.tagName) return false
  return el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT' || el.isContentEditable === true
}

/** Escape -> topmost modal's cancel result, else close the open page.
 *  x / Backspace -> cancel a cancellable progress bar. */
export function handleKeydown(event) {
  if (event.key === 'Escape') {
    const modal = activeModal()
    if (modal === 'alert') alertResult(false)
    else if (modal === 'input') inputResult(null)
    else if (modal === 'menu') menuResult(null)
    else if (store.openPage) closePage()
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
