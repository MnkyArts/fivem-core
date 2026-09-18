import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'

const uiDir = dirname(fileURLToPath(import.meta.url))   // core/ui
const resourcesDir = resolve(uiDir, '../..')            // the folder core lives in

// DESIGN §7.1 — deterministic output so the manifest's `files { 'html/**' }` stays stable.
// No hashed names, one JS bundle, one CSS bundle, everything relative (`base: './'`)
// because the CEF loads the page from `nui://<resource>/html/index.html`.
//
// §38: the entry is `src/main.ts` (index.html points at it) and the shell no longer compiles any
// plugin page — a plugin ships its own `ui/dist` and the runtime imports it from that resource's
// own origin. A lazily imported shell chunk still lands at `assets/<name>.js`; a plugin's module is
// an external URL, so it is never part of this graph.
function assetName(info) {
  const name = (info && (info.name || (info.names && info.names[0]))) || ''
  return name.endsWith('.css') ? 'assets/app.css' : 'assets/[name][extname]'
}

export default defineConfig({
  plugins: [vue(), tailwindcss()],   // Tailwind v4: CSS-first, configured in src/styles.css
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
        // Lower case: the only lazy chunk today is the §38.14 inspector, and a vfs path that
        // differs from the one a tool greps for is a bug waiting to happen.
        chunkFileNames: (chunk) => 'assets/' + String(chunk.name || 'chunk').toLowerCase() + '.js',
        assetFileNames: assetName,
      },
    },
  },
  server: {
    port: 5173,
    strictPort: false,
    // The hoisted node_modules of the resources/ npm workspace sits above this root, and a plugin
    // dev host resolves core's own sources through the workspace — both need `fs.allow`.
    cors: true,
    fs: { allow: [resourcesDir] },
  },
})
