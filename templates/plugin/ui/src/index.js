// my_plugin — page entry (DESIGN §7.4).
//
// core's shell finds this file at build time (core/ui/src/plugins.js) and registers the
// default export under `id`. The plugin ships no UI files: no vite config, no dist, no
// node_modules — rebuild core's UI (`cd core/ui && npm run build`) after changing Page.vue.
// Use the same id in client/main.lua: Core.UI.registerPage('my_plugin', { type = 'page' }).
export const id = 'my_plugin'
export { default } from './Page.vue'
