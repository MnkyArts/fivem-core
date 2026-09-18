// @core/ui/vite — the whole build config of a core UI plugin (DESIGN §38.13).
//
//   // <resource>/ui/vite.config.ts
//   import { defineConfig } from 'vite'
//   import { coreUI } from '@core/ui/vite'
//   export default defineConfig({ plugins: [coreUI()] })
//
// What it does, and why each piece is load-bearing (all of it was proven in the P1 prototype):
//   * ONE Vue. `vue` (and `@vue/runtime-dom|runtime-core|reactivity`), from the plugin's own source
//     AND from third-party packages inside its bundle, resolves to a virtual module that re-exports
//     `globalThis.__CORE_UI_HOST__.vue`. A second Vue would be a second reactivity graph, not just
//     bytes. The dep optimizer resolves with esbuild, not with Vite's plugin container, so the same
//     shim is installed there as well (`optimizeDeps.esbuildOptions.plugins`) — `exclude` alone is
//     not enough.
//   * Utilities-only CSS. A generated entry (`<ui>/.core-ui/entry.css`) references core's tokens and
//     emits ONLY the utilities this plugin's sources use, inside `@layer utilities`: no preflight, no
//     `:root` block, no kit class (§38.3). It must be a real file — `@tailwindcss/vite` resolves
//     `@import`/`@source` against `path.dirname(id)`.
//   * `preserveEntrySignatures: 'strict'`. Vite's app build default DROPS the entry's exports, and
//     the shell then reports "entry has no `export default defineUIPlugin(...)`" for a build that
//     looked perfectly fine.
//   * `base: './'` + `assetsInlineLimit: 0` so every asset URL resolves against the PLUGIN's origin
//     (`https://cfx-nui-<resource>/…`), and content-hashed names because an ES module URL is pinned
//     in the document's module map for the life of core's page (§38.1).
//   * `manifest.json` — what Lua reads with `LoadResourceFile` (§38.3), including the page ids found
//     statically in `defineUIPlugin({ pages })`.
//
// Two dev modes, chosen by Vite's `mode`:
//   `vite`              browser dev host — core's real shell runs in THIS Vite graph, so there is
//                       exactly one Vue by construction and `vue` is NOT redirected.
//   `vite --mode game`  attached — the in-game shell imports `src/index.ts` from this server, so the
//                       host shim, CORS, a fixed origin and the HMR websocket are all needed.
//   `vite build`        always uses the host shim.
//
// P1 V6 reported that the FIRST hot update after a page attaches is silently dropped. Re-measured
// here against Vite 7.3.6 with a real dev server in `game` mode, a raw `vite-hmr` websocket and the
// module graph walked like a browser would: the update frame arrives for the first edit in ~50 ms,
// in both orders (client connected before the modules are imported and after). There is therefore
// nothing for this plugin to fix in `configureServer`; if the drop shows up again in game, the
// suspect is the shell's attach sequence (§38.11 item 3), not the server.

import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'

const SDK_DIR = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const SDK_ENTRY = path.join(SDK_DIR, 'src/index.ts')
const CONTRACT_TS = path.join(SDK_DIR, 'src/contract.ts')
const THEME_CSS = path.join(SDK_DIR, 'theme.css')
const SDK_VERSION = JSON.parse(fs.readFileSync(path.join(SDK_DIR, 'package.json'), 'utf8')).version

/**
 * Tailwind's own stylesheets, as ABSOLUTE paths resolved from the SDK's context.
 *
 * The generated entry lives in `<plugin>/ui/.core-ui/`, and a bare `@import "tailwindcss/theme.css"`
 * there is resolved by walking up from THAT folder — which finds nothing whenever the plugin is not
 * a sibling of the install that carries Tailwind (a plugin outside the npm workspace, a fixture in a
 * temp dir, CI checking out this repo alone). The SDK always knows where its own peer dependency is,
 * so the entry names the file instead of asking for it.
 */
const sdkRequire = createRequire(path.join(SDK_DIR, 'noop.js'))
function tailwindCss(file) {
  try {
    return sdkRequire.resolve('tailwindcss/' + file)
  } catch {
    try {
      return path.join(path.dirname(sdkRequire.resolve('tailwindcss/package.json')), file)
    } catch {
      // Let Tailwind resolve it the old way and report its own error.
      return 'tailwindcss/' + file
    }
  }
}
const TW_THEME_CSS = tailwindCss('theme.css')
const TW_UTILITIES_CSS = tailwindCss('utilities.css')

const VUE_PKGS = ['vue', '@vue/runtime-dom', '@vue/runtime-core', '@vue/reactivity']
const VIRTUAL_VUE = 'virtual:core-ui/vue'
const RESOLVED_VUE = '\0' + VIRTUAL_VUE
const PAGE_ID_RE = /^[A-Za-z0-9_-]{1,64}$/
/** FiveM cuts the whole vfs path at 255 chars (`NUISchemeHandler.cpp:124-127`, DESIGN §38.1). */
const VFS_MAX = 255
/** §38.4: Lua rejects a manifest with more than this many preload entries. */
const MAX_PRELOAD = 16
const ENTRY_CANDIDATES = ['src/index.ts', 'src/index.js']
const DEV_HOST_CANDIDATES = ['dev/host.ts', 'dev/host.js']

/** The page `npm run dev` serves when a plugin has no index.html of its own (§38.11 path 1). */
function devHostHtml(entry) {
  return [
    '<!doctype html>',
    '<html lang="en">',
    '  <head>',
    '    <meta charset="UTF-8" />',
    '    <meta name="viewport" content="width=device-width, initial-scale=1.0" />',
    '    <title>core ui — dev host</title>',
    '  </head>',
    '  <body>',
    '    <div id="app"></div>',
    `    <script type="module" src="${entry}"></script>`,
    '  </body>',
    '</html>',
    '',
  ].join('\n')
}

// ---------------------------------------------------------------- the contract is read, not copied

/** The one place API_VERSION exists is contract.ts; the manifest and the gate both read it there. */
function readApiVersion() {
  const src = fs.readFileSync(CONTRACT_TS, 'utf8')
  const m = /export\s+const\s+API_VERSION\s*=\s*(\d+)/.exec(src)
  if (!m) throw new Error(`[core-ui] no API_VERSION in ${CONTRACT_TS}`)
  return Number(m[1])
}

let VUE_NAMES = null
async function vueNames() {
  if (VUE_NAMES) return VUE_NAMES
  const V = await import('vue')
  VUE_NAMES = Object.keys(V).filter((n) => n !== 'default' && n !== '__esModule' && /^[A-Za-z_$][\w$]*$/.test(n))
  return VUE_NAMES
}

/**
 * The virtual `vue` module.
 *
 * `export const ref = V.ref` is a property READ, and Rollup's default
 * `treeshake.propertyReadSideEffects: true` has to assume a getter — all ~170 re-exports survive.
 * A `/*#__PURE__*\/` annotation is only honoured on a call, hence the IIFE: 171 members retained
 * drops to 18, the shim shrinks from 6 181 B to 3 770 B (P1 V2).
 */
export function vueShimSource(names, { pure = true } = {}) {
  const head =
    'const H = globalThis.__CORE_UI_HOST__;\n' +
    "if (!H || !H.vue) throw new Error('[core-ui] no __CORE_UI_HOST__.vue — this plugin bundle only runs inside the core shell');\n" +
    'const V = H.vue;\n'
  const body = names
    .map((n) => (pure ? `export const ${n} = /*#__PURE__*/ (() => V.${n})();` : `export const ${n} = V.${n};`))
    .join('\n')
  return head + body + '\nexport default V;\n'
}

/** esbuild side of the "one Vue" rule — the dep optimizer never sees a real `vue`. */
function esbuildVueHostShim() {
  return {
    name: 'core-ui-vue-host',
    setup(build) {
      const filter = new RegExp(`^(${VUE_PKGS.map((p) => p.replace(/[/@]/g, '\\$&')).join('|')})$`)
      build.onResolve({ filter }, () => ({ path: 'core-ui-vue', namespace: 'core-ui-vue' }))
      build.onLoad({ filter: /.*/, namespace: 'core-ui-vue' }, async () => ({
        contents: vueShimSource(await vueNames(), { pure: false }),
        loader: 'js',
      }))
    },
  }
}

/**
 * The generated CSS entry. Utilities ONLY: preflight, the `:root` recipes and the kit's component
 * classes all live in core's own stylesheet, which the page already carries.
 *
 * Stray utilities (P1 V4): `@tailwindcss/vite` treats every module Vite transforms as a scan
 * source, so a dependency can donate utilities the plugin never wrote — and because whether such a
 * module is scanned BEFORE the sheet is generated depends on module order, the emitted CSS, its
 * content hash and the manifest were not reproducible. Measured with Tailwind 4.3.3:
 *   * `@lucide/vue` 1.45 donates nothing any more, with or without the `@source not` lines below;
 *   * the `@source not` lines narrow the FILE-SYSTEM scan only — they do not filter the candidates
 *     Tailwind harvests from the module graph (the SDK's own `[core` + `:ui]` message survived an
 *     exclusion of the whole SDK folder, which is why it is joined at runtime in src/index.ts).
 * They stay because they cost nothing and make the sheet's inputs explicit. A dependency whose
 * classes a plugin genuinely needs is added back by the plugin itself: an ordinary
 * `import './extra.css'` from the entry, with its own `@source` line inside.
 */
function pluginCssSource(uiDir) {
  return [
    '/* generated by @core/ui/vite — do not edit, do not commit */',
    '@layer properties, theme, base, components, utilities;',
    `@import ${JSON.stringify(TW_THEME_CSS)} theme(reference);`,
    `@import ${JSON.stringify(THEME_CSS)} theme(reference);`,
    // `source(none)`: automatic detection walks up from this file's folder and would sweep
    // `.core-ui/vite-cache` and `dist/` — a stale optimizer chunk or yesterday's bundle would then
    // donate class candidates and the sheet's content hash would drift for unchanged sources.
    // With it off, ONLY the explicit @source below contributes file-system candidates.
    `@import ${JSON.stringify(TW_UTILITIES_CSS)} layer(utilities) source(none);`,
    `@source ${JSON.stringify(path.join(uiDir, 'src/**/*.{vue,ts,js,tsx,jsx}'))};`,
    '@source not "**/node_modules/**";',
    `@source not ${JSON.stringify(path.join(uiDir, '.core-ui/**'))};`,
    `@source not ${JSON.stringify(path.join(uiDir, 'dist/**'))};`,
    `@source not ${JSON.stringify(path.join(SDK_DIR, '**'))};`,
    '',
  ].join('\n')
}

// ---------------------------------------------------------------- Chromium 103 lint
// The §37.4 list, copied from ui/tests/kit-compile-check.mjs (which is a script, not a module, so
// there is nothing to import). Keep the two in sync. Every needle is assembled from string pieces
// for the reason that file states: Tailwind scans this source tree, and a literal that looks like a
// utility would be generated INTO the very bundle the rule protects.
const T_FAMILY = ['trans' + 'late', 'ro' + 'tate', 'sc' + 'ale']
const FILTER_FAMILY = 'back' + 'drop'
const CSS_BANNED = [
  [/color-mix\s*\(/i, 'color-mix() — not in Chromium 103; pre-mix the token or use rgb(var(--…-rgb) / a)'],
  [/:has\s*\(/i, ':has() — not in Chromium 103'],
  [new RegExp('(^|[;{}\\s])(' + T_FAMILY.join('|') + ')\\s*:', 'i'),
    'individual transform property — Chromium 103 only has `transform:`'],
  [new RegExp('(^|[;{}\\s])(?:-webkit-)?' + FILTER_FAMILY + '-filter\\s*:', 'i'),
    'the banned backdrop filter property — it paints a black box in the CEF; glass is `data-core-blur` (§32)'],
  [/@container\b/i, '@container — container queries are not in Chromium 103'],
  [/\d(?:\.\d+)?\s*(dvh|svh|lvh)\b/i, 'dynamic viewport unit (dvh/svh/lvh) — not in Chromium 103; use vh'],
  [/\bok(?:lch|lab)\s*\(/i, 'oklch()/oklab() — not in Chromium 103; write hex or rgb()'],
  [/(^|[;{}\s])scrollbar-(width|color)\s*:/i, 'scrollbar-width/-color — Chromium 103 needs ::-webkit-scrollbar'],
  [/@starting-style\b/i, '@starting-style — not in Chromium 103'],
  [/(^|[;{}\s])text-wrap\s*:/i, 'text-wrap — not in Chromium 103'],
]
/** In JS every rule but the individual-transform one applies: `{ rotate: 5 }` is an ordinary object
 *  literal, while `color-mix(`/`:has(`/`oklch(` in a string is broken in the CEF either way. */
const JS_BANNED = CSS_BANNED.filter(([re]) => !String(re).includes(T_FAMILY[0]))
const STRING_LITERAL = /"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)*'|`(?:[^`\\]|\\.)*`/g

/**
 * Blanks every `@supports (color: color-mix(…)) { … }` block, keeping the length so nothing else
 * shifts. Tailwind emits an opacity modifier (`bg-panel/50`) as a literal fallback declaration
 * FOLLOWED by the `color-mix()` form inside exactly that guard, which is precisely what Chromium
 * 103 needs: it takes the fallback and ignores the block. That is the rule `ui/tests/kit-regression`
 * §11 asserts on core's own bundle ("every color-mix() sits inside an @supports block"), so the
 * emitted stylesheet is held to the same one — an UNGUARDED color-mix still fails the build.
 */
function blankGuardedColorMix(text) {
  const guard = /@supports\s*\(\s*color\s*:\s*color-mix\([^)]*\)[^)]*\)\s*\{/gi
  let out = text
  let m
  while ((m = guard.exec(text))) {
    let depth = 1
    let i = m.index + m[0].length
    while (i < text.length && depth > 0) {
      if (text[i] === '{') depth++
      else if (text[i] === '}') depth--
      i++
    }
    out = out.slice(0, m.index) + ' '.repeat(i - m.index) + out.slice(i)
  }
  return out
}

function lintCssText(text, file, out) {
  const unguarded = blankGuardedColorMix(text)
  for (const [re, message] of CSS_BANNED) {
    // Everything but the color-mix rule is judged on the whole sheet, guarded blocks included.
    const subject = String(re).includes('color-mix') ? unguarded : text
    if (re.test(subject)) out.push(`${file}: ${message}`)
  }
}

/** CSS that a plugin embedded in JS (`import css from './x.css?inline'`, a template literal): only
 *  string literals are looked at, so ordinary code cannot trip the lint. It is still a guess over
 *  code the plugin did not necessarily write — every bundled dependency's strings pass through here
 *  — so a hit WARNS (one line per file and rule) and never fails the build. Emitted `.css` is the
 *  plugin's own output and stays an error. */
function lintJsEmbeddedCss(code, file, out) {
  const seen = new Set()
  for (const lit of code.match(STRING_LITERAL) || []) {
    for (const [re, message] of JS_BANNED) {
      if (re.test(lit) && !seen.has(message)) { seen.add(message); out.push(`${file} (embedded CSS): ${message}`) }
    }
  }
}

// ---------------------------------------------------------------- fxmanifest (warnings only)

/**
 * Text heuristics over the resource's fxmanifest — every one of these is a "the build succeeds and
 * the game serves nothing" trap (§38.1: only files packed by `files {}` are reachable, and a
 * `client_script` that is not also a `file` is served as garbage).
 */
function fxmanifestWarnings(resourceDir, distRel) {
  const file = ['fxmanifest.lua', '__resource.lua'].map((f) => path.join(resourceDir, f)).find((f) => fs.existsSync(f))
  if (!file) return [`no fxmanifest.lua in ${resourceDir} — the resource cannot serve ${distRel}/`]
  const raw = fs.readFileSync(file, 'utf8')
  // Lua comments would otherwise "satisfy" every check below.
  const src = raw.replace(/--\[\[[\s\S]*?\]\]/g, '').replace(/^[ \t]*--.*$/gm, '')
  const out = []
  const uiDirKey = /(^|\s)core_ui\s*[('"]/.test(src)
  if (!uiDirKey) out.push(`fxmanifest.lua has no \`core_ui '${distRel}'\` line — core will never probe this resource (§38.4)`)

  const strings = [...src.matchAll(/['"]([^'"\n]+)['"]/g)].map((m) => m[1])
  const head = distRel.split('/')[0] + '/'
  const covers = strings.some((s) => s === distRel || s.startsWith(distRel + '/') || (s.startsWith(head) && s.includes('*')))
  if (!covers) out.push(`fxmanifest.lua has no \`files\` entry covering ${distRel}/ — add \`files { '${distRel}/**' }\``)

  for (const m of src.matchAll(/client_scripts?\s*[({]([\s\S]*?)[)}]/g)) {
    for (const s of [...m[1].matchAll(/['"]([^'"\n]+)['"]/g)].map((x) => x[1])) {
      if (!s.includes('*')) continue
      // `**` crosses folders, `*` stops inside one. Splitting on `**` FIRST means the two
      // passes cannot see each other's output, so no placeholder character is needed - a raw
      // one in the source would make this file binary to git, grep and `file`.
      const escapeRe = (t) => t.replace(/[.+^${}()|[\]\\]/g, '\\$&')
      const rx = s.split('**').map((c) => c.split('*').map(escapeRe).join('[^/]*')).join('.*')
      const re = new RegExp('^' + rx + '$')
      if (re.test(`${distRel}/plugin.abc123.js`)) {
        out.push(`the client_script glob '${s}' can match inside ${distRel}/ — FiveM would serve those files as garbage (§38.1)`)
      }
    }
  }
  return out
}

// ---------------------------------------------------------------- static `pages` extraction

/** `import { defineUIPlugin as d } from '@core/ui'` and `import * as sdk from '@core/ui'` both count. */
function sdkLocalNames(ast) {
  const named = new Set()
  const namespaces = new Set()
  for (const node of ast.body) {
    if (node.type !== 'ImportDeclaration' || typeof node.source.value !== 'string') continue
    const from = node.source.value
    if (from !== '@core/ui' && !/(^|[/\\])sdk[/\\]src[/\\]index\.(ts|js|mjs)$/.test(from)) continue
    for (const spec of node.specifiers) {
      if (spec.type === 'ImportSpecifier' && spec.imported.name === 'defineUIPlugin') named.add(spec.local.name)
      else if (spec.type === 'ImportNamespaceSpecifier') namespaces.add(spec.local.name)
    }
  }
  return { named, namespaces }
}

function isDefineUIPluginCallee(callee, names) {
  if (callee.type === 'Identifier') return names.named.has(callee.name)
  if (callee.type === 'MemberExpression' && !callee.computed && callee.property.name === 'defineUIPlugin') {
    return callee.object.type === 'Identifier' ? names.namespaces.has(callee.object.name) : true
  }
  return false
}

/** Walks the entry's AST. Returns `{ found, pages, unknown }` — `unknown` when a spread or a
 *  computed key makes the list unreliable, in which case `pages` is left out of the manifest. */
function extractPages(ast) {
  const names = sdkLocalNames(ast)
  // A bare `defineUIPlugin` with no import happens when the entry is JS built by another tool; the
  // name alone is then the only signal available.
  const result = { found: false, pages: [], unknown: false }
  const seen = new Set()

  const visit = (node) => {
    if (!node || typeof node !== 'object' || seen.has(node)) return
    if (Array.isArray(node)) { for (const n of node) visit(n); return }
    if (!node.type) return
    seen.add(node)
    if (node.type === 'CallExpression' && isDefineUIPluginCallee(node.callee, names)) {
      result.found = true
      const arg = node.arguments[0]
      if (arg && arg.type === 'ObjectExpression') {
        const pagesProp = arg.properties.find(
          (p) => p.type === 'Property' && !p.computed
            && ((p.key.type === 'Identifier' && p.key.name === 'pages') || (p.key.type === 'Literal' && p.key.value === 'pages')),
        )
        if (pagesProp) {
          if (pagesProp.value.type !== 'ObjectExpression') result.unknown = true
          else {
            for (const p of pagesProp.value.properties) {
              if (p.type !== 'Property' || p.computed) { result.unknown = true; continue }
              const key = p.key.type === 'Identifier' ? p.key.name : p.key.type === 'Literal' ? String(p.key.value) : null
              if (key == null) result.unknown = true
              else result.pages.push(key)
            }
          }
        }
      } else if (arg) {
        result.unknown = true
      }
    }
    for (const key of Object.keys(node)) {
      if (key === 'type' || key === 'start' || key === 'end' || key === 'loc') continue
      visit(node[key])
    }
  }
  visit(ast.body)
  return result
}

// ---------------------------------------------------------------- paths

/**
 * The chunks the ENTRY needs before it can run: its static `imports`, transitively.
 *
 * `dynamicImports` are deliberately never followed — a lazy page
 * (`definePage({ component: () => import('./Page.vue') })`) exists precisely so its chunk is NOT
 * fetched until the page opens, and a `<link rel=modulepreload>` right after registration would
 * undo that.
 */
function staticChunkDeps(bundle, entryFile) {
  const seen = new Set([entryFile])
  const queue = [entryFile]
  const out = []
  while (queue.length) {
    const chunk = bundle[queue.shift()]
    if (!chunk || chunk.type !== 'chunk') continue
    for (const imp of chunk.imports || []) {
      if (seen.has(imp)) continue
      seen.add(imp)
      out.push(imp)
      queue.push(imp)
    }
  }
  return out.filter((f) => f.startsWith('chunks/')).sort()
}

/** The npm workspace root (the package.json that declares `workspaces`), else the resource's parent. */
function workspaceRoot(from) {
  let dir = from
  for (let i = 0; i < 8; i++) {
    const pkg = path.join(dir, 'package.json')
    if (fs.existsSync(pkg)) {
      try {
        if (JSON.parse(fs.readFileSync(pkg, 'utf8')).workspaces) return dir
      } catch { /* an unreadable package.json is not a workspace root */ }
    }
    const up = path.dirname(dir)
    if (up === dir) break
    dir = up
  }
  return path.dirname(path.dirname(from))
}

/** The Vue the shell will hand this plugin at runtime — diagnostics in the manifest (§38.3). */
function installedVueVersion(from) {
  for (const base of [path.join(from, 'noop.js'), path.join(SDK_DIR, 'noop.js'), import.meta.url]) {
    try {
      return createRequire(base)('vue/package.json').version
    } catch { /* try the next resolution base */ }
  }
  return undefined
}

// ---------------------------------------------------------------- the plugin

/**
 * @typedef {object} CoreUIOptions
 * @property {string} [id]            the resource name; must equal the folder when given
 * @property {'eager'|'lazy'} [load]  manifest `load` (default 'eager')
 * @property {number} [port]          dev-server port (default 5173)
 * @property {boolean} [vendorChunk]  put node_modules into `chunks/vendor.<hash>.js`
 */

/** @param {CoreUIOptions} [options] */
export function coreUI(options = {}) {
  const wanted = options.load || 'eager'
  if (wanted !== 'eager' && wanted !== 'lazy') throw new Error(`[core-ui] load must be 'eager' or 'lazy', got ${JSON.stringify(options.load)}`)
  const vendorChunk = options.vendorChunk === true
  const apiVersion = readApiVersion()

  let uiDir = ''
  let resource = ''
  let entryId = ''
  let cssEntry = ''
  let distRel = 'ui/dist'
  let hostShim = false
  let devHost = false
  /** @type {{ found: boolean, pages: string[], unknown: boolean }|null} */
  let pagesInfo = null

  const fail = (msg) => { throw new Error(`[core-ui] ${resource || path.basename(uiDir || process.cwd())}: ${msg}`) }

  const core = {
    name: 'core-ui',
    enforce: 'pre',

    async config(userConfig, env) {
      uiDir = path.resolve(userConfig.root || process.cwd())
      const resourceDir = path.dirname(uiDir)
      resource = path.basename(resourceDir)
      if (path.basename(uiDir) !== 'ui' || !resource || resource === '.' || resource === path.sep) {
        throw new Error(`[core-ui] ${uiDir} is not a <resource>/ui folder — a UI plugin's id is its resource name (DESIGN §38.3)`)
      }
      if (options.id && options.id !== resource) {
        fail(`options.id '${options.id}' does not match the resource folder '${resource}' (${resourceDir}) — the plugin id IS the resource name`)
      }

      const entryRel = ENTRY_CANDIDATES.find((c) => fs.existsSync(path.join(uiDir, c)))
      if (!entryRel) fail(`no entry — create src/index.ts (or src/index.js) with \`export default defineUIPlugin({ … })\``)
      entryId = path.join(uiDir, entryRel)

      const outDir = path.join(uiDir, 'dist')
      distRel = path.relative(resourceDir, outDir).split(path.sep).join('/')

      const genDir = path.join(uiDir, '.core-ui')
      fs.mkdirSync(genDir, { recursive: true })
      // Everything in here is generated per build; a plugin repo must not carry it.
      fs.writeFileSync(path.join(genDir, '.gitignore'), '*\n')
      cssEntry = path.join(genDir, 'entry.css')
      fs.writeFileSync(cssEntry, pluginCssSource(uiDir))

      // `vite build` always ships the shim; `vite` (browser dev host) runs the real shell in this
      // same graph, so redirecting `vue` there would break the ONE thing the dev host is for.
      hostShim = env.command === 'build' || env.mode === 'game'
      devHost = env.command === 'serve' && env.mode !== 'game'
      if (hostShim) await vueNames()

      const port = options.port || 5173
      const root = workspaceRoot(uiDir)
      /** @type {import('vite').UserConfig} */
      const config = {
        // Vite's default is `<nearest package.json dir>/node_modules/.vite`, i.e. the SHARED hoisted
        // node_modules in a workspace — every plugin's dep optimizer would fight over one cache.
        cacheDir: path.join(genDir, 'vite-cache'),
        base: './',
        resolve: { alias: [{ find: /^@core\/ui$/, replacement: SDK_ENTRY }] },
        define: {
          __VUE_OPTIONS_API__: 'true',
          __VUE_PROD_DEVTOOLS__: 'false',
          __VUE_PROD_HYDRATION_MISMATCH_DETAILS__: 'false',
        },
        build: {
          outDir: 'dist',
          emptyOutDir: true,          // the OLD hashed files must disappear (P1 V3.4)
          target: 'chrome103',
          cssCodeSplit: false,        // exactly one plugin.<hash>.css
          assetsInlineLimit: 0,       // never base64 — assets must be real files with real URLs
          modulePreload: { polyfill: false },
          minify: env.mode === 'development' ? false : 'esbuild',
          rollupOptions: {
            input: entryId,
            preserveEntrySignatures: 'strict',
            output: {
              format: 'es',
              entryFileNames: 'plugin.[hash].js',
              chunkFileNames: 'chunks/[name].[hash].js',
              assetFileNames: (info) => {
                const n = (info.names && info.names[0]) || info.name || ''
                return n.endsWith('.css') ? 'plugin.[hash].css' : 'assets/[name].[hash][extname]'
              },
              manualChunks: vendorChunk ? (mid) => (mid.includes('node_modules') ? 'vendor' : undefined) : undefined,
            },
          },
        },
        server: {
          port,
          cors: true,
          // node_modules is a workspace symlink and Vite resolves symlinks, so without this every
          // bare import 403s — and the browser dev host imports core's shell from outside this root.
          fs: { allow: [root] },
        },
      }

      if (hostShim) {
        config.optimizeDeps = {
          exclude: VUE_PKGS,                                    // dev: don't pre-bundle Vue …
          esbuildOptions: { plugins: [esbuildVueHostShim()] },  // … and don't let a dep bundle it
        }
      }
      if (devHost) {
        // The dev host imports core's shell, its stylesheet and its fonts from OUTSIDE this root,
        // so the optimizer must be told where to start; without it the first page load discovers
        // Vue mid-flight and reloads itself.
        const hostFile = DEV_HOST_CANDIDATES.find((f) => fs.existsSync(path.join(uiDir, f)))
        if (hostFile) config.optimizeDeps = { entries: [hostFile] }
      }
      if (env.command === 'serve' && env.mode === 'game') {
        // The in-game shell (origin nui://core) imports from this server: fixed origin, fixed port,
        // its own websocket (§38.11 item 3).
        config.server.strictPort = true
        config.server.origin = `http://localhost:${port}`
        config.server.hmr = { protocol: 'ws', host: 'localhost', port }
      }
      return config
    },

    resolveId(source, importer) {
      if (source === VIRTUAL_VUE || source === RESOLVED_VUE) return RESOLVED_VUE
      if (!hostShim) return null
      // from the plugin's own source AND from third-party packages inside the bundle
      if (VUE_PKGS.includes(source) && importer !== RESOLVED_VUE) return RESOLVED_VUE
      return null
    },

    load(rid) {
      if (rid === RESOLVED_VUE) return { code: vueShimSource(VUE_NAMES), moduleSideEffects: false }
      return null
    },

    transform(code, rid) {
      if (rid.split('?')[0] === entryId && !code.includes('.core-ui/entry.css')) {
        return { code: `import ${JSON.stringify(cssEntry)};\n` + code, map: null }
      }
      return null
    },

    buildStart() {
      pagesInfo = null
      for (const warning of fxmanifestWarnings(path.dirname(uiDir), distRel)) {
        this.warn(`[core-ui] ${resource}: ${warning}`)
      }
    },

    // §38.11 path 1: `npm run dev` needs a page. A plugin may write its own `ui/index.html`
    // (kept, untouched); with none, one is served from memory pointing at `dev/host.ts`, so the
    // whole browser dev loop is two files in the plugin and no HTML to maintain.
    configureServer(server) {
      if (!devHost || fs.existsSync(path.join(uiDir, 'index.html'))) return
      server.middlewares.use((req, res, next) => {
        const url = (req.url || '/').split('?')[0]
        if (url !== '/' && url !== '/index.html') return next()
        const hostFile = DEV_HOST_CANDIDATES.find((f) => fs.existsSync(path.join(uiDir, f)))
        if (!hostFile) {
          res.statusCode = 500
          res.setHeader('Content-Type', 'text/plain; charset=utf-8')
          res.end(`[core-ui] ${resource}: no ui/index.html and no ui/dev/host.ts.\n\n`
            + 'The browser dev host needs one file:\n\n'
            + "  // ui/dev/host.ts\n"
            + "  import { createDevHost } from '@core/ui/dev'\n"
            + "  import plugin from '../src/index.ts'\n"
            + `  createDevHost({ id: '${resource}', plugin })\n\n`
            + '(`npm run build` and `npm run dev:game` do not need it.)\n')
          return
        }
        server.transformIndexHtml(url, devHostHtml('/' + hostFile), req.originalUrl).then(
          (html) => {
            res.statusCode = 200
            res.setHeader('Content-Type', 'text/html; charset=utf-8')
            res.end(html)
          },
          (err) => next(err),
        )
      })
    },
  }

  // A SEPARATE, `post` plugin: Vite's own `vite:css-post` emits the stylesheet in ITS
  // generateBundle, and an `enforce: 'pre'` plugin's generateBundle runs before that — the manifest
  // would list `"css": []`. The same ordering gives this one the post-TypeScript entry code.
  const manifestPlugin = {
    name: 'core-ui:manifest',
    enforce: 'post',

    transform(code, rid) {
      if (rid.split('?')[0] !== entryId) return null
      let ast
      try {
        ast = this.parse(code)
      } catch (err) {
        this.warn(`[core-ui] ${resource}: could not parse the entry for page ids (${err.message})`)
        pagesInfo = { found: true, pages: [], unknown: true }
        return null
      }
      pagesInfo = extractPages(ast)
      return null
    },

    generateBundle(_opts, bundle) {
      if (!pagesInfo || !pagesInfo.found) {
        fail(`${path.relative(path.dirname(uiDir), entryId).split(path.sep).join('/')} has no \`export default defineUIPlugin({ … })\` — the shell rejects an entry without it (§38.6)`)
      }

      let entry = null
      const css = []
      const problems = []
      const suspects = []
      const files = Object.keys(bundle).sort()

      for (const file of files) {
        const out = bundle[file]
        if (out.type === 'chunk') {
          if (out.isEntry) entry = file
          lintJsEmbeddedCss(out.code, file, suspects)
        } else {
          if (file.endsWith('.css')) {
            css.push(file)
            lintCssText(typeof out.source === 'string' ? out.source : Buffer.from(out.source).toString('utf8'), file, problems)
          }
        }
        const vfs = `resources:/${resource}/${distRel}/${file}`
        if (vfs.length >= VFS_MAX) {
          problems.push(`${file}: the vfs path is ${vfs.length} chars — FiveM cuts at ${VFS_MAX} and the file is unreachable (§38.1)`)
        }
      }
      if (problems.length) fail(problems.join('\n  '))
      // Emitted CSS is the plugin's own and fails the build; a hit inside a JS string is a guess
      // over code the plugin did not necessarily write (a bundled dependency), so it only warns.
      for (const s of suspects) this.warn(`[core-ui] ${resource}: ${s}`)

      const pages = []
      if (!pagesInfo.unknown) {
        const seen = new Set()
        for (const id of pagesInfo.pages) {
          if (!PAGE_ID_RE.test(id)) fail(`page id ${JSON.stringify(id)} is not a plain id — [A-Za-z0-9_-], 1-64 chars (§38.4)`)
          if (seen.has(id)) fail(`page id '${id}' appears twice in defineUIPlugin({ pages })`)
          seen.add(id)
          pages.push(id)
        }
      } else {
        this.warn(`[core-ui] ${resource}: \`pages\` has a spread or a computed key — the page list is left out of manifest.json (Lua's registerPage stays the authority)`)
      }

      let preload = entry ? staticChunkDeps(bundle, entry) : []
      if (preload.length > MAX_PRELOAD) {
        this.warn(`[core-ui] ${resource}: ${preload.length} static chunks — only the first ${MAX_PRELOAD} are listed for preload (§38.4 caps the list; the rest still load as normal imports)`)
        preload = preload.slice(0, MAX_PRELOAD)
      }

      // Deterministic: same sources -> same content hashes -> same file names -> same build id.
      const build = crypto.createHash('sha1').update(files.join('\n')).digest('hex').slice(0, 10)
      const manifest = {
        id: resource,
        apiVersion,
        entry,
        css,
        build,
        load: wanted,
        preload,
        ...(pagesInfo.unknown ? {} : { pages }),
        sdk: SDK_VERSION,
        vue: installedVueVersion(uiDir),
      }
      this.emitFile({ type: 'asset', fileName: 'manifest.json', source: JSON.stringify(manifest, null, 2) + '\n' })

      // The version the bundle really carries. `defineUIPlugin` stamps it from contract.ts, so the
      // two can only differ when the plugin resolved a SECOND @core/ui (its own node_modules, a
      // stale copy) — exactly the case the shell would reject at runtime with an opaque message.
      // Rollup may put the stamped object in a shared chunk, so every chunk is looked at.
      for (const file of files) {
        const out = bundle[file]
        if (out.type !== 'chunk' || !out.code) continue
        const m = /__coreUIPlugin\s*:\s*(?:!0|true)\s*,\s*apiVersion\s*:\s*(\d+)/.exec(out.code)
        if (m && Number(m[1]) !== apiVersion) {
          fail(`${file} embeds API_VERSION ${m[1]} but this @core/ui speaks ${apiVersion} — the plugin resolved a different @core/ui (check ${path.join(uiDir, 'node_modules/@core/ui')})`)
        }
      }
    },
  }

  return [core, vue(), tailwindcss(), manifestPlugin]
}

export default coreUI
