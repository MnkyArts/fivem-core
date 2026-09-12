import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

const uiDir = dirname(fileURLToPath(import.meta.url))   // core/ui
const resourcesDir = resolve(uiDir, '../..')            // the folder core lives in

// DESIGN §7.1 — deterministic output so the manifest's `files { 'html/**' }` stays stable.
// No hashed names, one JS bundle, one CSS bundle, everything relative (`base: './'`)
// because the CEF loads the page from `nui://<resource>/html/index.html`.
function assetName(info) {
  const name = (info && (info.name || (info.names && info.names[0]))) || ''
  return name.endsWith('.css') ? 'assets/app.css' : 'assets/[name][extname]'
}

export default defineConfig({
  plugins: [vue()],
  base: './',
  build: {
    outDir: '../html',
    emptyOutDir: true,
    cssCodeSplit: false,
    target: 'chrome103', // FiveM's CEF floor; Vite 7 would otherwise default higher
    modulePreload: { polyfill: false },
    rollupOptions: {
      output: {
        entryFileNames: 'assets/app.js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: assetName,
      },
    },
  },
  server: {
    port: 5173,
    strictPort: false,
    // Plugin pages live outside this root (`<resource>/ui/src`, see src/plugins.js), so the
    // dev server has to be allowed to read core's sibling resources and the hoisted
    // node_modules of the resources/ npm workspace.
    fs: { allow: [resourcesDir] },
  },
})
