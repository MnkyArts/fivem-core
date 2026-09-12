// core UI — entry point (DESIGN §7.1, §7.2)
// `window.Vue` is assigned BEFORE mounting so plugin bundles (vue external, global
// `Vue`) share this exact Vue instance.
import * as Vue from 'vue'

window.Vue = Vue

import './styles.css'
import { installCoreUI } from './coreui.js'
import { installPluginPages } from './plugins.js'
import { installGameBlur } from './gameblur.js'
import { post } from './bridge.js'
import App from './App.vue'

// Plugin pages are compiled into this bundle (src/plugins.js): register them before the
// app mounts so an early `page:open` already finds its component.
const CoreUI = installCoreUI()
installPluginPages(CoreUI)

const app = Vue.createApp(App)

app.config.errorHandler = (err, instance, info) => {
  console.error('[core:ui] vue error', info, err)
}

app.mount('#app')

// §32: glass panels. Installed AFTER the mount so the first scan already sees the shell, and
// exposed for advanced pages (`CoreUI.gameBlur.mode()` -> 'live' | 'fallback' | 'off'). The
// module reads `store.blur` itself; Lua tunes it with `blur:set`.
CoreUI.gameBlur = installGameBlur(document.getElementById('app'))

// Tells Lua the NUI is alive: it re-sends every registered page and the HUD snapshot.
post('ui_ready', {})
