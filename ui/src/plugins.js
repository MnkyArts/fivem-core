// core UI — plugin pages, compiled into this bundle (DESIGN §7.4)
//
// Plugins ship no UI files of their own: every sibling resource of `core` that has
// `ui/src/index.js` is pulled into core's shell at build time, so players download one
// dist (`core/html`) no matter how many plugins the server runs.
//
// A plugin's `ui/src/index.js`:
//     export const id = 'my_plugin'          // the page id used by Core.UI.registerPage
//     export { default } from './Page.vue'
//
// The glob is relative to this file: ../../../ is the folder `core` lives in, so it matches
// `<resource>/ui/src/index.js` for every resource next to core. It is resolved by Vite at
// build time — adding a plugin means rebuilding core's UI, not shipping a second bundle.
const modules = import.meta.glob('../../../*/ui/src/index.js', { eager: true })

const RESOURCE_RE = /([^/\\]+)[/\\]ui[/\\]src[/\\]index\.js$/

/** Explicit `export const id`, else the resource folder name. */
function pageIdOf (path, mod) {
  if (typeof mod.id === 'string' && mod.id) return mod.id
  const match = RESOURCE_RE.exec(path)
  return match ? match[1] : null
}

/**
 * Registers every discovered plugin page on `CoreUI`. Called from main.js right after
 * installCoreUI() so a page is ready before Lua's first `page:register` arrives.
 * Returns a Map of id -> source path (handy in the console).
 */
export function installPluginPages (CoreUI) {
  const registered = new Map()
  if (!CoreUI || typeof CoreUI.registerPage !== 'function') return registered

  for (const path of Object.keys(modules).sort()) {
    if (path.indexOf('/core/ui/') !== -1) continue // core's own shell is not a plugin

    const mod = modules[path] || {}
    const id = pageIdOf(path, mod)
    const component = mod.default

    if (!id || !component) {
      console.warn('[core:ui] ignoring plugin page', path, '- needs `export const id` and a default-exported component')
      continue
    }
    if (registered.has(id)) {
      console.warn('[core:ui] duplicate plugin page id "' + id + '"', path, 'already taken by', registered.get(id))
      continue
    }

    registered.set(id, path)
    CoreUI.registerPage(id, component)
  }

  return registered
}
