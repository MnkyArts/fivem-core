// core UI — entry point (DESIGN §7.1, §7.2)
// `window.Vue` is assigned BEFORE mounting so plugin bundles (vue external, global
// `Vue`) share this exact Vue instance.
import * as Vue from 'vue'

window.Vue = Vue

import './styles.css'
import './kit/fonts.css'
import { installCoreUI } from './coreui.js'
import { installPluginPages } from './plugins.js'
import { installGameBlur } from './gameblur.js'
import { installKit, components, ICONS, registerIcons } from './kit/index.js'
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

// §37.3: the design system. Every `Core*.vue` is registered globally BEFORE the mount, so a plugin
// page compiled into this bundle resolves `<CoreButton>` at runtime without importing anything.
installKit(app)

app.mount('#app')

// §37.3: what a plugin may reach for — the component map (feature-detect a tag), the icon registry
// and `registerIcons({ 'my-icon': 'M...' })` for its own 24 x 24 glyphs.
CoreUI.kit = { components, icons: ICONS, registerIcons }

// §32: glass panels. Installed AFTER the mount so the first scan already sees the shell, and
// exposed for advanced pages (`CoreUI.gameBlur.mode()` -> 'live' | 'fallback' | 'off'). The
// module reads `store.blur` itself; Lua tunes it with `blur:set`.
CoreUI.gameBlur = installGameBlur(document.getElementById('app'))

// Tells Lua the NUI is alive: it re-sends every registered page and the HUD snapshot.
post('ui_ready', {})
