// core UI kit — the component registry (DESIGN §37.3).
//
// Every `components/Core<Name>.vue` is registered globally on the one Vue app (§7.4), which is why
// a plugin page can simply write `<CoreButton>` without importing anything: the page's compiled
// render function resolves the tag at runtime against this app.
//
// Adding a component = dropping a `Core<Name>.vue` file into `./components/`. Nothing else: the
// glob below is eager, so the file is in the bundle and in `window.CoreUI.kit.components` after the
// next `npm run build`. Its CSS belongs in the group partial of `./css/` (§37.4), never in a
// scoped <style> block.

const modules = import.meta.glob('./components/Core*.vue', { eager: true })

/** @type {Record<string, object>} `'CoreButton'` -> the component, keyed by file base name. */
export const components = {}

for (const path of Object.keys(modules).sort()) {
  const file = path.slice(path.lastIndexOf('/') + 1)
  const name = file.slice(0, -4) // drop '.vue'
  const mod = modules[path]
  components[name] = (mod && mod.default) || mod
}

/**
 * Registers every kit component on an app. Called by `src/main.js` before mount and by
 * `.storybook/preview.js` through `setup(app)`.
 *
 * @param {import('vue').App} app
 * @returns {import('vue').App} the same app, so the call can be chained
 */
export function installKit(app) {
  for (const name of Object.keys(components)) app.component(name, components[name])
  return app
}

export * from './icons.js'
export * from './use.js'
