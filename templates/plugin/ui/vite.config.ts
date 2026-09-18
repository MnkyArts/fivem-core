// The whole build config of a core UI plugin (core DESIGN §38.13). `coreUI()` brings the Vue SFC
// and Tailwind plugins, the Chromium-103 target, the one-Vue resolution, the utilities-only
// stylesheet, the content-hashed output in ui/dist and the manifest.json core reads.
import { defineConfig } from 'vite'
import { coreUI } from '@core/ui/vite'

export default defineConfig({ plugins: [coreUI()] })
