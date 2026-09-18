// <resource>/ui/dev/host.ts — the entry of `npm run dev` (core DESIGN §38.11 path 1).
//
// It mounts core's REAL shell in this plugin's own Vite server and activates the plugin object
// directly, so there is one module graph, one Vue and native HMR: edit a component under src/ and
// the open page updates without losing the props Lua "sent".
//
// Never shipped. `npm run build` builds src/index.ts only.

import { createDevHost } from '@core/ui/dev'
import plugin from '../src/index.ts'
import { mock, initialProps } from './mock.ts'

createDevHost({
  id: 'my_plugin',                       // the resource name — plugin id, page owner, nui channel
  plugin,
  mock,
  // What `Core.UI.registerPage` declares in client/main.lua. 'page' takes focus, 'overlay' never
  // does, 'modal' stacks on top of a page (§38.9).
  pages: { my_plugin: 'page' },
  props: { my_plugin: initialProps },
  open: 'my_plugin',                     // open it right away; the toolbar can close/re-open
  background: 'game',                    // 'game' | 'ink' | 'none'
})

// The toolbar's `restart` button (and `__dev.restart()`) replays plugin:unregister ->
// plugin:register with generation + 1. Press it after every change to setup(ctx): anything your
// plugin failed to clean up shows as a doubled listener or a leaked timer.
