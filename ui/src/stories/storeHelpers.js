// core UI — shared story plumbing (DESIGN §6.10, §7.5).
//
// Stories drive the SAME reactive store the game drives: every state change is a
// real `SendNUIMessage` payload pushed through the dev shim (`window.__core.send`),
// never a faked component prop. If a story renders, the wire shape is right.
import { h, onMounted, watch } from 'vue'
import { store, dismissNotification, resetExtras } from '../store.js'
import { resetPages } from '../runtime/pages.ts'
import { resetLayers } from '../runtime/layers.ts'
import '../bridge.js' // installs window.__core (store.js pulls it in too, this is explicit)

export { store }

/** Long enough that a toast / progress bar stays put while you look at it. */
export const HOLD_MS = 60 * 60 * 1000

/** Fake one incoming NUI message — the exact dispatch path `window.__core.send` uses. */
export function send (msg) {
  const shim = window.__core
  if (shim && typeof shim.send === 'function') return shim.send(msg)
  window.dispatchEvent(new MessageEvent('message', { data: msg }))
  return msg
}

/** Back to a freshly loaded shell: no toasts, no modals, no pages, HUD off.
 *  The store keeps its timers in a private Map, so each one is cleared through the
 *  action/helper that owns it (`dismissNotification`, `progress:stop`) instead of
 *  by blanking the state — otherwise a stale timeout fires into the next story. */
export function resetStore () {
  for (const n of store.notifications.slice()) dismissNotification(n.id)
  send({ action: 'progress:stop' })
  send({ action: 'menu:close' })
  send({ action: 'input:close' })
  send({ action: 'alert:close' })
  send({ action: 'skillcheck:close' })
  send({ action: 'textui:hide' })
  // `resetExtras()` below puts health / armour / talking / muted / anchor / scale back, so this
  // only has to clear the fields core no longer draws but still hands to `useHud()` (§39.4).
  send({ action: 'hud:set', visible: false, cash: 0, bank: 0, name: '', serverId: 0, faction: false })
  // §38: the page/plugin/focus state lives in runtime/*.ts (it writes into these same store
  // slices), so a story starts from a shell with no page, no modal and no focus stack at all.
  resetPages()
  resetLayers()
  store.focused = false
  // §21 widgets (shard / spinner / key hints / stat bars / replicated state / locale) own
  // their own timers and keys, so the store clears them itself.
  resetExtras()
}

/** CSF3 `render` helper: run `build()` AFTER the widgets mounted, then draw `view()`.
 *
 *  Order matters. Menu / InputDialog / AlertDialog only initialise their local state
 *  (selected index, field defaults, focus) inside a `watch` on `visible`, so the
 *  message has to arrive while they are already mounted — exactly like Lua talking to
 *  a live NUI. Child `onMounted` runs before the parent's, so dispatching here is safe
 *  for every widget below. No template strings anywhere: the shipped bundle has no
 *  runtime compiler, so stories stay on `h()` too. */
export function scene (build, view) {
  return () => ({
    setup () {
      if (build) onMounted(build)
      return view
    },
  })
}

/** The fixed top-right rail App.vue puts the stat bars and the toast stack in. (§39.4 took the
 *  HUD out of it: the vitals strip is `position: fixed` on its own and needs no wrapper.) */
export function rail (...children) {
  return h('div', {
    style: {
      position: 'fixed',
      top: '16px',
      right: '16px',
      display: 'flex',
      flexDirection: 'column',
      alignItems: 'flex-end',
      gap: '10px',
      zIndex: 40,
      pointerEvents: 'none',
    },
  }, children)
}

/** Story-only caption, for states that are deliberately empty (a hidden HUD). */
export function note (text) {
  return h('p', {
    style: {
      position: 'fixed',
      left: '16px',
      bottom: '14px',
      margin: 0,
      padding: '6px 10px',
      border: '1px dashed rgba(242, 244, 248, 0.22)',
      borderRadius: '6px',
      color: 'rgba(242, 244, 248, 0.38)',
      font: '500 11px/1.4 var(--core-mono, monospace)',
      letterSpacing: '0.04em',
      pointerEvents: 'none',
    },
  }, text)
}

/** CSF3 `render` for a story with Controls: the same ordering as `scene`, plus a re-send
 *  whenever an arg changes.
 *
 *  The vue3 renderer does NOT remount on an args change — it hands `render(args)` a reactive
 *  proxy on the first call and then mutates that proxy in place (renderToCanvas ->
 *  updateArgs). So the live update has to come from a watcher inside the story's own setup:
 *  `flush: 'post'` puts the re-send after the DOM settled, exactly like a second
 *  SendNUIMessage arriving at a live NUI. `build(args, context)` is the message(s) the
 *  story sends; `view` renders the widget(s) under test. */
export function liveScene (build, view) {
  return (args, context) => ({
    setup () {
      const run = () => build(args, context)
      onMounted(run)
      watch(() => JSON.stringify(args), run, { flush: 'post' })
      return view
    },
  })
}

/** `{ control: 'object' }` args are deep-cloned so a control edit can never hand the store
 *  the same array twice (and so `JSON.stringify(args)` really changes). */
export function clone (value) {
  return JSON.parse(JSON.stringify(value))
}
