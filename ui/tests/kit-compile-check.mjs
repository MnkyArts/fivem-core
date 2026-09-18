#!/usr/bin/env node
// core UI kit — the parallel-safe compile check (DESIGN §37.7).
//
//   node ui/tests/kit-compile-check.mjs [files…]
//
// With no arguments it walks `ui/src/kit` and `ui/src/stories/kit`. `npm run build` empties
// `html/`, so two agents cannot build at the same time; this checker touches nothing, needs no
// dev server and can run while everyone else is still writing.
//
//   .vue   parse + compileScript (+ compileTemplate when there is no `<script setup>`) with
//          @vue/compiler-sfc, then the Chromium 103 lint over the template and style text.
//   .css   the §37.4 Chromium 103 list, brace balance and well-formed comments.
//   .js    syntax-only parse (the @babel/parser inside @vue/compiler-sfc, else acorn 8+,
//          else `node --check`) — modern ESM and `import.meta.glob` included.
//   .ts    the same parse with the `typescript` plugin (DESIGN §38: the plugin entries and the
//          shell runtime are TypeScript now); falls back to `ts.transpileModule` for the syntax
//          check when @babel/parser is not reachable.
//
// Output is one `ERROR|WARN file:line message` line per problem plus a summary; exit code 1
// when anything was reported as ERROR.
import { createRequire } from 'node:module'
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { execFileSync } from 'node:child_process'
import path from 'node:path'

const require = createRequire(import.meta.url)          // resolves resources/node_modules (hoisted workspace)
const uiDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const DEFAULT_ROOTS = [path.join(uiDir, 'src/kit'), path.join(uiDir, 'src/stories/kit')]
const EXTS = new Set(['.vue', '.css', '.js', '.mjs', '.ts', '.mts'])

const problems = []
const rel = (file) => {
  const r = path.relative(process.cwd(), file)
  return !r || r.startsWith('..') ? file : r
}
function report (level, file, line, message) {
  problems.push({ level, file, line: Number(line) || 1, message: String(message).split('\n')[0] })
}

// ---------------------------------------------------------------- shared patterns
// NOTHING in this file may be spelled the way a Tailwind class is spelled. Tailwind v4 detects
// its sources automatically, so it scans `ui/` including this checker, and any literal that looks
// like a utility is generated into the shipped bundle — which is how a lint rule about the unsafe
// transform utilities would end up PUTTING those unsafe declarations into html/assets/app.css.
// Every needle is therefore assembled from pieces, and the messages name the families in prose.
const T_FAMILY = ['trans' + 'late', 'ro' + 'tate', 'sc' + 'ale']
const FILTER_FAMILY = 'back' + 'drop'
const VALUE_TAIL = '[\\w[\\]./%-]+'
const CLASS_HEAD = '(^|[\\s"\'`:])'
const CSS_BANNED_FILTER = new RegExp('(^|[;{}\\s])(?:-webkit-)?' + FILTER_FAMILY + '-filter\\s*:', 'i')
const CSS_TRANSFORM_PROP = new RegExp('(^|[;{}\\s])(' + T_FAMILY.join('|') + ')\\s*:', 'i')
const TW_TRANSFORM = new RegExp(CLASS_HEAD + '-?(' + T_FAMILY.join('|') + ')-(x-|y-)?' + VALUE_TAIL)
const TW_BACKDROP = new RegExp(CLASS_HEAD + FILTER_FAMILY + '-' + VALUE_TAIL)

// §37.4: what Chromium 103 (FiveM's CEF) does not have.
const CSS_BANNED = [
  [/color-mix\s*\(/i, 'color-mix() — not in Chromium 103; pre-mix the token or use rgb(var(--…-rgb) / a)'],
  [/:has\s*\(/i, ':has() — not in Chromium 103'],
  [CSS_TRANSFORM_PROP, 'individual transform property — Chromium 103 only has `transform:`'],
  [CSS_BANNED_FILTER, 'the banned backdrop filter property — it paints a black box in the CEF; glass is `data-core-blur` (§32)'],
  [/@container\b/i, '@container — container queries are not in Chromium 103'],
  [/\d(?:\.\d+)?\s*(dvh|svh|lvh)\b/i, 'dynamic viewport unit (dvh/svh/lvh) — not in Chromium 103; use vh'],
  [/\bok(?:lch|lab)\s*\(/i, 'oklch()/oklab() — not in Chromium 103; write hex or rgb()'],
  [/(^|[;{}\s])scrollbar-(width|color)\s*:/i, 'scrollbar-width/-color — Chromium 103 needs ::-webkit-scrollbar'],
  [/@starting-style\b/i, '@starting-style — not in Chromium 103'],
  [/(^|[;{}\s])text-wrap\s*:/i, 'text-wrap — not in Chromium 103'],
]

// ---------------------------------------------------------------- CSS
/** Blanks comments (keeping line breaks) so the feature lint never fires on documentation,
 *  and reports the two comment bugs that actually happen: a body containing the terminator
 *  (which closes the comment early and leaves a stray one behind) and an unclosed comment. */
function stripCssComments (src, file) {
  const END = '*' + '/'
  let out = ''
  let i = 0
  let line = 1
  let inComment = false
  let openedAt = 1
  while (i < src.length) {
    const two = src[i] + (src[i + 1] || '')
    if (!inComment && two === '/*') { inComment = true; openedAt = line; out += '  '; i += 2; continue }
    if (inComment && two === END) { inComment = false; out += '  '; i += 2; continue }
    if (!inComment && two === END) {
      report('ERROR', file, line, 'stray comment terminator — a comment body must never contain it (AGENTS §3 UI)')
      out += '  '; i += 2; continue
    }
    out += inComment && src[i] !== '\n' ? ' ' : src[i]
    if (src[i] === '\n') line++
    i++
  }
  if (inComment) report('ERROR', file, openedAt, 'unterminated comment')
  return out
}

function lintCss (file, src) {
  const code = stripCssComments(src, file)
  const lines = code.split('\n')
  let depth = 0
  lines.forEach((text, i) => {
    const line = i + 1
    for (const [re, message] of CSS_BANNED) if (re.test(text)) report('ERROR', file, line, message)
    // A `&` where a selector may start (line head, or after `{`/`}`/`;`) — not one inside a string.
    if (/(^|[{};])\s*&[\s\w:.#[&>+~*]/.test(text)) {
      report('ERROR', file, line, 'CSS nesting — Chromium 103 does not support `&`; write the full selector')
    }
    for (const ch of text) {
      if (ch === '{') depth++
      else if (ch === '}' && --depth < 0) { report('ERROR', file, line, 'unbalanced braces: one `}` too many'); depth = 0 }
    }
  })
  if (depth > 0) report('ERROR', file, lines.length, 'unbalanced braces: ' + depth + ' block(s) left open')
}

// ---------------------------------------------------------------- JS
let sfc = null
try { sfc = require('@vue/compiler-sfc') } catch { /* reported once in the run section */ }

// `node --check` would treat a bare .js as CommonJS outside this package and cannot see
// `import.meta.glob`, so the parser of choice is the @babel/parser bundled inside
// @vue/compiler-sfc (the checker needs that package anyway). The hoisted `acorn` is 7.4.1 —
// it hangs forever on `ecmaVersion: 'latest'` — so it is only used from 8.x upwards.
let acorn = null
try {
  const a = require('acorn')
  if (Number(String(a.version || '0').split('.')[0]) >= 8) acorn = a
} catch { /* fall back below */ }

let ts = null
try { ts = require('typescript') } catch { /* only needed when @babel/parser is missing */ }

function lintJs (file, src, isTs) {
  if (sfc && typeof sfc.babelParse === 'function') {
    try {
      sfc.babelParse(src, { sourceType: 'module', plugins: isTs ? ['typescript'] : [] })
    } catch (err) {
      report('ERROR', file, (err.loc && err.loc.line) || 1, err.message)
    }
    return
  }
  // TypeScript cannot go through acorn or `node --check`; tsc's own transpile is the syntax check.
  if (isTs) {
    if (!ts) {
      report('WARN', file, 1, 'neither @vue/compiler-sfc nor typescript is resolvable — the .ts file was not parsed')
      return
    }
    const out = ts.transpileModule(src, {
      reportDiagnostics: true,
      fileName: file,
      compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, isolatedModules: true },
    })
    for (const d of out.diagnostics || []) {
      const at = d.file && d.start != null ? d.file.getLineAndCharacterOfPosition(d.start).line + 1 : 1
      report('ERROR', file, at, ts.flattenDiagnosticMessageText(d.messageText, ' '))
    }
    return
  }
  if (acorn) {
    try {
      acorn.parse(src, { ecmaVersion: 'latest', sourceType: 'module', allowHashBang: true, allowAwaitOutsideFunction: true })
    } catch (err) {
      report('ERROR', file, (err.loc && err.loc.line) || 1, err.message)
    }
    return
  }
  try {
    execFileSync(process.execPath, ['--check', file], { stdio: 'pipe' })
  } catch (err) {
    const out = String((err && err.stderr) || err)
    const at = out.match(/:(\d+)\n/)
    const msg = out.match(/^\s*(SyntaxError:.*)$/m)
    report('ERROR', file, at ? at[1] : 1, msg ? msg[1] : 'syntax error')
  }
}

// ---------------------------------------------------------------- SFC
/** The markup rules of §37.4 that a compiler cannot see. Tailwind v4 emits the transform utility
 *  families as the matching individual CSS properties, which Chromium 103 drops silently, so a kit
 *  template must move those into the group's CSS partial and write `transform:` instead. */
function lintMarkup (file, text, startLine, what) {
  text.split('\n').forEach((line, i) => {
    const at = startLine + i
    const t = TW_TRANSFORM.exec(line)
    if (t) report('ERROR', file, at, 'Tailwind transform utility "' + t[0].trim() + '" in the ' + what
      + ' — v4 emits the individual property, which Chromium 103 ignores; use `transform:` in the CSS partial')
    const b = TW_BACKDROP.exec(line)
    if (b) report('ERROR', file, at, 'Tailwind utility `' + b[0].trim() + '` in the ' + what
      + ' — the banned filter family; glass is the `blur` prop / `data-core-blur` (§32)')
  })
}

function lintVue (file, src) {
  if (!sfc) return
  const id = path.basename(file, '.vue')
  const { descriptor, errors } = sfc.parse(src, { filename: file })
  for (const err of errors || []) {
    report('ERROR', file, (err.loc && err.loc.start && err.loc.start.line) || 1, err.message || String(err))
  }
  if (descriptor.script || descriptor.scriptSetup) {
    try {
      sfc.compileScript(descriptor, { id, inlineTemplate: !!descriptor.scriptSetup })
    } catch (err) {
      const block = descriptor.scriptSetup || descriptor.script
      const line = (err.loc && err.loc.start && err.loc.start.line) || block.loc.start.line
      report('ERROR', file, line, err.message || String(err))
    }
  }
  if (!descriptor.scriptSetup && descriptor.template) {
    const out = sfc.compileTemplate({ source: descriptor.template.content, filename: file, id })
    for (const err of out.errors || []) {
      const at = (err.loc && err.loc.start && err.loc.start.line) || 1
      report('ERROR', file, descriptor.template.loc.start.line + at - 1, err.message || String(err))
    }
  }
  if (descriptor.template) lintMarkup(file, descriptor.template.content, descriptor.template.loc.start.line, 'template')
  const inComponents = path.resolve(file).startsWith(path.join(uiDir, 'src/kit/components') + path.sep)
  for (const style of descriptor.styles || []) {
    lintMarkup(file, style.content, style.loc.start.line, 'style block')
    lintCss(file, '\n'.repeat(style.loc.start.line - 1) + style.content)
    if (inComponents) {
      report('WARN', file, style.loc.start.line,
        'a <style> block in kit/components — kit CSS belongs in the group partial under kit/css (§37.4)')
    }
  }
}

// ---------------------------------------------------------------- run
function walk (dir, out) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name.startsWith('.')) continue
    const full = path.join(dir, name)
    if (statSync(full).isDirectory()) walk(full, out)
    else if (EXTS.has(path.extname(name))) out.push(full)
  }
  return out
}

function collect (args) {
  if (!args.length) {
    const found = []
    for (const root of DEFAULT_ROOTS) if (existsSync(root)) walk(root, found)
    return found.sort()
  }
  const files = []
  for (const arg of args) {
    const full = path.resolve(process.cwd(), arg)
    if (!existsSync(full)) { report('ERROR', full, 1, 'no such file'); continue }
    if (statSync(full).isDirectory()) walk(full, files)
    else files.push(full)
  }
  return files.sort()
}

const files = collect(process.argv.slice(2))
if (!sfc && files.some((f) => f.endsWith('.vue'))) {
  console.log('NOTE  @vue/compiler-sfc is not resolvable from ' + rel(uiDir) + ' — .vue files were skipped')
}
if (!sfc && !acorn) console.log('NOTE  no @vue/compiler-sfc and no acorn 8+ — JS falls back to `node --check`')

for (const file of files) {
  const ext = path.extname(file)
  let src = ''
  try { src = readFileSync(file, 'utf8') } catch (err) { report('ERROR', file, 1, 'unreadable: ' + err.message); continue }
  if (ext === '.vue') lintVue(file, src)
  else if (ext === '.css') lintCss(file, src)
  else lintJs(file, src, ext === '.ts' || ext === '.mts')
}

problems.sort((a, b) => (a.file === b.file ? a.line - b.line : a.file < b.file ? -1 : 1))
for (const p of problems) console.log(p.level + (p.level === 'WARN' ? '  ' : ' ') + rel(p.file) + ':' + p.line + ' ' + p.message)

const errors = problems.filter((p) => p.level === 'ERROR').length
const warnings = problems.length - errors
console.log('kit-compile-check: ' + files.length + ' file(s), ' + errors + ' error(s), ' + warnings + ' warning(s)')
process.exit(errors ? 1 : 0)
