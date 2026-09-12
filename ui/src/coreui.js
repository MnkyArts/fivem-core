// core UI — the `window.CoreUI` surface plugin bundles talk to (DESIGN §7.4)
import { post } from './bridge.js'
import { store, ensurePage, setPageComponent, whenRegistered, onPageEvent, closePage, notify } from './store.js'

/** Installs `window.CoreUI`. `window.Vue` must already be set (main.js does it first). */
export function installCoreUI() {
  const Vue = window.Vue
  if (!Vue) throw new Error('[core:ui] window.Vue must be assigned before installCoreUI()')

  const CoreUI = {
    Vue,

    /** A plugin bundle calls this once it has executed; resolves a waiting `page:open`. */
    registerPage(id, component) {
      if (typeof id !== 'string' || !id) return
      setPageComponent(id, component)
    },

    /** page -> Lua: TriggerEvent('core:ui:<page>:<event>', data) on the client. */
    emit(pageId, event, data) {
      return post('ui_event', { page: pageId, event, data: data === undefined ? {} : data })
    },

    /** Lua -> page (`page:event`). Returns an unsubscribe function. */
    on(pageId, event, fn) {
      return onPageEvent(pageId, event, fn)
    },

    close(pageId) {
      closePage(pageId)
    },

    post,

    /** Read-only reactive HUD snapshot (cash / bank / name / serverId / faction,
     *  plus the §21 feed: health / armour / speed / street / zone / minimap). */
    hud: Vue.readonly(store.hud),

    /** Read-only reactive mirror of the replicated player state (`state:set`, §21). */
    state: Vue.readonly(store.state),

    /** Read-only reactive stat bars (`stats:set`, §18): name -> { value, min, max }. */
    stats: Vue.readonly(store.stats),

    /** Minimap anchor rect `{ x, y, w, h }` in CSS pixels, or null before the client
     *  measured it — a page can park itself next to the minimap with this. */
    get minimap() {
      return store.hud.minimap
    },

    /** Current NUI language (`locale:set`). */
    get lang() {
      return store.locale.lang
    },

    /** core's translation of `key` with `{{var}}` substitution (DESIGN §26).
     *  An unknown key comes back verbatim, exactly like `Core.Locale.t` in Lua.
     *  Plugin pages bundle their own strings; this is core's table only. */
    t(key, vars) {
      const id = String(key == null ? '' : key)
      const strings = store.locale.strings
      const raw = strings && typeof strings[id] === 'string' ? strings[id] : id
      if (!vars || typeof vars !== 'object') return raw
      return raw.replace(/\{\{\s*([\w.]+)\s*\}\}/g, (match, name) => (
        vars[name] === undefined || vars[name] === null ? match : String(vars[name])
      ))
    },

    /** Frontend sound through Lua: `ui_sound { name, set }` -> PlaySoundFrontend. */
    playSound(name, set) {
      if (typeof name !== 'string' || !name) return Promise.resolve({})
      return post('ui_sound', { name, set: set == null ? null : String(set) })
    },

    /** Waits for a bundle to register `id` (null after `timeoutMs`). Used by PageHost. */
    whenRegistered,

    /** Local toast without a Lua round trip (same shape as the `notify` action). */
    notify(message, type) {
      return notify(typeof message === 'object' && message !== null ? message : { message, type })
    },

    /** Composable for the page component itself. */
    usePage(id) {
      const V = window.Vue
      const props = ensurePage(id).props
      const api = {
        id,
        props,
        emit: (event, data) => CoreUI.emit(id, event, data),
        on: (event, fn) => {
          const off = onPageEvent(id, event, fn)
          if (V.getCurrentInstance && V.getCurrentInstance()) V.onUnmounted(off)
          return off
        },
        close: () => closePage(id),
      }
      return api
    },
  }

  window.CoreUI = CoreUI
  return CoreUI
}
