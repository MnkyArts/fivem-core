// my_plugin — the entry of `npm run dev` (core DESIGN §38.11 path 1).
//
// It mounts core's REAL shell in this plugin's own Vite server and activates the plugin object
// directly: one module graph, one Vue, native HMR. Edit anything under src/ and the open page
// updates without losing the props Lua "sent".
//
// Never shipped: `ui/dev/` is outside the resource's `files {}` and `npm run build` only ever
// looks at src/index.ts.
import { createDevHost } from '@core/ui/dev'
import plugin from '../src/index.ts'
import { initialProps, mock } from './mock.ts'

createDevHost({
  id: 'my_plugin',                      // the resource name — plugin id, page owner, nui channel
  plugin,
  // The mock carries its own types: `createDevHost` infers the props and RPC maps from it, so
  // `props` below and `lua.onRequest` in mock.ts are checked against the same declarations.
  mock,
  // What `Core.UI.registerPage` declares in client/main.lua. 'page' takes focus, 'overlay' never
  // does, 'modal' stacks on top of a page (§38.9).
  pages: { my_plugin: 'page' },
  props: { my_plugin: initialProps },
  open: 'my_plugin',
  background: 'game',                   // 'game' | 'ink' | 'none'
})

// The toolbar's restart button (and `__dev.restart()` in the console) replays
// plugin:unregister -> plugin:register with generation + 1. Press it after every change to
// `setup(ctx)`: anything the plugin fails to clean up shows up as a doubled listener.
