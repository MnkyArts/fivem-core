// core UI — the `window.CoreUI` surface plugin bundles talk to (DESIGN §7.4, kept by §38.12)
//
// §38 gave plugins a typed SDK (`@core/ui`, backed by `globalThis.__CORE_UI_HOST__`), but this
// object stays: the shell regression suite, the kit regression suite, Storybook and every page
// written before §38 reach for `window.CoreUI`. Every member below is load-bearing.
import { post } from './runtime/transport.ts'
import { store, ensurePage, setPageComponent, whenRegistered, onPageEvent, closePage, notify } from './store.js'
import { bindToScope, pageHandle } from './runtime/pages.ts'
import { currentHost, PAGE_KEY } from './runtime/host.ts'
import { list as pluginList } from './runtime/plugins.ts'

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

    /** Lua -> page (`page:event`). `pageId` may also be a plugin channel (§38.5). Returns an
     *  unsubscribe function; inside a plugin `setup` or a component it is scoped like the SDK's. */
    on(pageId, event, fn) {
      return bindToScope(onPageEvent(pageId, event, fn))
    },

    close(pageId) {
      closePage(pageId)
    },

    post,

    /** Read-only reactive HUD snapshot: `visible`, the §39 strip (health / armour / talking /
     *  muted / anchor / scale / minimap) and the fields core keeps for plugins but no longer
     *  draws itself (cash / bank / name / serverId / faction / speed / street / zone). Core
     *  paints only the §39.4 strip — anything else on this object is yours to render. */
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

    /** Composable for the page component itself. With no id — inside a page rendered by
     *  PageHost — it resolves the page being rendered, exactly like the SDK's `usePage()`. */
    usePage(id) {
      let pageId = id
      if (!pageId) {
        const V = window.Vue
        const ctx = V && V.getCurrentInstance && V.getCurrentInstance() ? V.inject(PAGE_KEY, null) : null
        if (!ctx) throw new Error('[core:ui] CoreUI.usePage() without an id works inside a page component only')
        pageId = ctx.id
      }
      ensurePage(pageId)
      return pageHandle(pageId)
    },

    /** §38.2: what the shell knows about every registered plugin (the inspector's source). */
    plugins() {
      return pluginList().map((p) => ({
        id: p.id, state: p.state, generation: p.generation, build: p.build, ms: p.ms, error: p.error, pages: p.pages.slice(),
      }))
    },

    /** §38.6: `globalThis.__CORE_UI_HOST__`, for a console poke or a test. */
    get host() {
      return currentHost()
    },
  }

  window.CoreUI = CoreUI
  return CoreUI
}
