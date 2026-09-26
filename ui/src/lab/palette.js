// Palette lab — DEV ONLY. Tries a second colour next to the coral without touching the kit.
//
// The kit reads ONE accent (--color-accent*, --core-accent-rgb, the accent gradients, the glows)
// for five different jobs: the brand marks, the primary button, selection, form controls and
// focus. The lab gives each job ("role") its own copy of those tokens by re-declaring them on the
// component ROOTS that do the job: a custom property is resolved where it is used, so a
// `.core-menu` that declares `--color-accent: <teal>` re-tones every rule inside it, and a
// `.core-btn--primary` inside a teal card that declares the coral again is coral. Roles not given
// to the second colour are pinned back to the coral the page started with (`--lab1-*`, captured
// from the live tokens, so a server re-theme is captured too).
//
//   <html data-lab="select controls focus meters" data-lab-on2="light|dark" style="--lab2: …">
//
// `data-lab` lists the roles that wear the second colour; its mere presence switches the lab on.
// Nothing here is imported by src/main.js or src/styles.css: only kit-preview.html (src/kit/
// preview.js) and Storybook (.storybook/preview.js) load it, so it never reaches html/.

/** The candidates. `on` is the text colour on a solid fill of `base`. */
export const PRESETS = [
  { id: 'teal', name: 'Teal', base: '#0f9e8f', hi: '#2dd4bf', lo: '#0b7d71', on: '#ffffff',
    note: 'The coral’s complement. Warm/cool contrast, Vice City energy.' },
  { id: 'blue', name: 'Blue', base: '#3478f6', hi: '#62a0ff', lo: '#2a5fc4', on: '#ffffff',
    note: 'Calm and familiar (system blue). Sits close to the info colour.' },
  { id: 'ice', name: 'Ice', base: '#e8edf2', hi: '#ffffff', lo: '#c3ccd6', on: '#0b1116',
    note: 'Neutral white selection with dark text, like GTA’s own pause menu. Coral stays the only colour.' },
  { id: 'steel', name: 'Steel', base: '#56809f', hi: '#8fb6d6', lo: '#45677f', on: '#ffffff',
    note: 'Muted slate blue from the panels. Quiet and grown-up.' },
  { id: 'violet', name: 'Violet', base: '#6a58e6', hi: '#8e80ff', lo: '#5343c2', on: '#ffffff',
    note: 'Synthwave with the coral. Sits close to epic rarity and stress.' },
  { id: 'gold', name: 'Gold', base: '#f2b230', hi: '#ffc857', lo: '#cf9216', on: '#1a1306',
    note: 'Warm, “money” feel. Collides with the warning and legendary colours.' },
]

/** Which component roots do which job. Brand is the part that always stays coral. */
export const BRAND_ROOTS = [
  '.core-dash', '.core-heading', '.core-tagline', '.core-brand', '.core-divider', '.core-badge', '.core-tag',
  '.core-shard', '.core-tooltip', '.core-panel', '.core-dialog', '.core-drawer', '.core-toast', '.core-alert',
]

/** Source order is the tie-break for an element that is the root of two roles (a radio CARD is
 *  both a control and a selection): later wins, so `select` and `action` come last. */
export const ROLES = [
  { id: 'controls', name: 'Form controls', hint: 'checkbox, radio, switch, slider',
    roots: ['.core-check', '.core-radio', '.core-switch', '.core-slider'] },
  { id: 'focus', name: 'Focus & text fields', hint: 'focus rings, input / select / number borders',
    roots: ['.core-inputbox', '.core-textarea', '.core-number', '.core-selectbox', 'input.core-input',
      'textarea.core-input', 'select.core-select'] },
  { id: 'meters', name: 'Progress & meters', hint: 'progress, ring, spinner, XP bar, objectives',
    roots: ['.core-progress', '.core-ring', '.core-spinner', '.core-playerchip', '.core-avatar', '.core-objective'] },
  { id: 'game', name: 'Keys & world prompts', hint: 'pressed keys, prompts, interaction dot, compass',
    roots: ['.core-key', '.core-keyhint', '.core-keyhints', '.core-prompt', '.core-prompts', '.core-interaction-dot',
      '.core-compass', '.core-hudtile'] },
  { id: 'select', name: 'Selection & navigation', hint: 'menu rows, tabs, chips, slots, cards, lists, tables',
    roots: ['.core-menu', '.core-list', '.core-item', '.core-tabs', '.core-chips', '.core-chip', '.core-stepper',
      '.core-contextmenu', '.core-selectbox__popup', '.core-slotgrid', '.core-slot', '.core-hotbar', '.core-listview',
      '.core-listitem', '.core-card', '.core-table', '.core-swatches', '.core-swatch', '.core-radio--card',
      '.core-btn.is-active', '.core-iconbtn.is-active'] },
  { id: 'action', name: 'Primary buttons', hint: 'CoreButton / CoreIconButton variant="primary"',
    roots: ['.core-btn--primary', '.core-iconbtn--primary'] },
]

/** Role mixes: how much of the UI the second colour takes over. */
export const MIXES = [
  { id: 'light', name: 'Light', roles: ['controls', 'focus'],
    note: 'Coral keeps selection and buttons; the second colour only on controls and focus.' },
  { id: 'split', name: 'Split', roles: ['controls', 'focus', 'meters', 'select'],
    note: 'Coral = brand + primary action + world prompts. The second colour does all the “where am I” work.' },
  { id: 'swap', name: 'Swap', roles: ['controls', 'focus', 'meters', 'game', 'select', 'action'],
    note: 'The second colour becomes the main one; coral is left for the brand marks only.' },
]

export const DEFAULT_MIX = 'split'

/* Every token that carries the accent, and the lab variable that replaces it. `--core-menu-fade`
   is not a theme token (CoreMenu declares it on .core-menu from the accent tokens), but it is
   declared on the very element the lab re-scopes, so it has to be re-declared too. */
const TOKENS = [
  ['--color-accent', ''],
  ['--color-accent-hi', '-hi'],
  ['--color-accent-lo', '-lo'],
  ['--color-accent-soft', '-soft'],
  ['--color-on-accent', '-on'],
  ['--core-accent-rgb', '-rgb'],
  ['--core-grad-accent', '-grad'],
  ['--core-grad-accent-fade', '-fade'],
  ['--core-grad-accent-fade-out', '-fade-out'],
  ['--core-menu-fade', '-menu-fade'],
  ['--shadow-glow', '-glow'],
  ['--shadow-glow-sm', '-glow-sm'],
  ['--core-focus', '-focus'],
]

const swapTo = (n) => TOKENS.map(([prop, suffix]) => prop + ': var(--lab' + n + suffix + ');').join(' ')

// Dark ink ticks for a light second colour (the kit's are white, drawn once as data URIs).
const TICK_DARK = "url(\"data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='none' stroke='%230b1116' stroke-width='3.8' stroke-linecap='round' stroke-linejoin='round'%3E%3Cpath d='M5.4 12.7l4.7 4.7L18.8 7.4'/%3E%3C/svg%3E\")"
const DASH_DARK = "url(\"data:image/svg+xml;charset=utf-8,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Crect x='5' y='10.5' width='14' height='3' rx='1.5' fill='%230b1116'/%3E%3C/svg%3E\")"

/** The whole lab stylesheet. `:where()` keeps every prefix at zero specificity, so which role an
 *  element follows is decided by its own root selector and then by ROLES order, never by the prefix. */
export function buildCss () {
  const out = []
  const scope = (prefix, roots) => roots.map((r) => ':where(' + prefix + ') ' + r).join(',\n')

  // Capture the coral the page started with. The same formula CoreMenu uses for its fade.
  out.push('[data-lab] {\n'
    + '  --lab1: var(--color-accent); --lab1-hi: var(--color-accent-hi); --lab1-lo: var(--color-accent-lo);\n'
    + '  --lab1-soft: var(--color-accent-soft); --lab1-on: var(--color-on-accent); --lab1-rgb: var(--core-accent-rgb);\n'
    + '  --lab1-grad: var(--core-grad-accent); --lab1-fade: var(--core-grad-accent-fade);\n'
    + '  --lab1-fade-out: var(--core-grad-accent-fade-out);\n'
    + '  --lab1-menu-fade: linear-gradient(90deg, var(--color-accent-hi) 0%, var(--color-accent) 11%, var(--color-accent) 34%,'
    + ' rgb(var(--core-accent-rgb) / 0.52) 68%, rgb(var(--core-accent-rgb) / 0.03) 100%);\n'
    + '  --lab1-glow: var(--shadow-glow); --lab1-glow-sm: var(--shadow-glow-sm); --lab1-focus: var(--core-focus);\n'
    + '}')

  out.push(scope('[data-lab]', BRAND_ROOTS) + ' { ' + swapTo(1) + ' }')
  for (const role of ROLES) {
    out.push(scope('[data-lab]:not([data-lab~="' + role.id + '"])', role.roots) + ' { ' + swapTo(1) + ' }')
    out.push(scope('[data-lab~="' + role.id + '"]', role.roots) + ' { ' + swapTo(2) + ' }')
  }

  // Focus rings follow the focus role everywhere, not the component they sit on.
  out.push(':where([data-lab~="focus"]) :focus-visible { outline-color: var(--lab2-hi) !important; }')
  out.push(':where([data-lab]:not([data-lab~="focus"])) :focus-visible { outline-color: var(--lab1-hi) !important; }')

  // A light second colour needs dark marks where the kit draws white ones on the fill.
  const light = '[data-lab~="controls"][data-lab-on2="dark"]'
  out.push(':where(' + light + ") .core-check input[type='checkbox']:checked { background-image: " + TICK_DARK + ', var(--core-grad-accent); }')
  out.push(':where(' + light + ") .core-check input[type='checkbox']:indeterminate { background-image: " + DASH_DARK + ', var(--core-grad-accent); }')
  out.push(':where(' + light + ') .core-switch__input:checked + .core-switch__track .core-switch__thumb { background: var(--lab2-on); }')
  return out.join('\n\n')
}

/* ---- colour maths (sRGB, good enough for a lab) ------------------------------------------ */

function parseHex (hex) {
  let h = ('' + (hex || '')).trim().replace(/^#/, '')
  if (h.length === 3) h = h.split('').map((c) => c + c).join('')
  if (!/^[0-9a-fA-F]{6}$/.test(h)) return null
  const n = parseInt(h, 16)
  return [n >> 16, (n >> 8) & 255, n & 255]
}

const toHex = (rgb) => '#' + rgb.map((c) => Math.round(Math.min(255, Math.max(0, c))).toString(16).padStart(2, '0')).join('')
const mix = (a, b, t) => a.map((c, i) => c + (b[i] - c) * t)
const WHITE = [255, 255, 255]
const BLACK = [0, 0, 0]
const INK = [11, 17, 22]

function luminance (rgb) {
  const lin = (c) => { c /= 255; return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4 }
  return 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2])
}

function contrast (a, b) {
  const x = luminance(a)
  const y = luminance(b)
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05)
}

export function isHex (value) { return parseHex(value) !== null }

/** A preset by id, or a derived one for any hex. The coral is white-on at 3.4:1, so white wins
 *  unless it drops under 2.6:1 — the same call the kit made for the coral itself. */
export function resolvePalette (value) {
  const preset = PRESETS.find((p) => p.id === value)
  if (preset) return preset
  const rgb = parseHex(value)
  if (!rgb) return null
  const on = contrast(rgb, WHITE) >= 2.6 ? WHITE : INK
  return {
    id: 'custom',
    name: 'Custom',
    base: toHex(rgb),
    hi: toHex(mix(rgb, WHITE, 0.16)),
    lo: toHex(mix(rgb, BLACK, 0.14)),
    on: toHex(on),
    note: 'Derived from one colour: hi = 16 % lighter, lo = 14 % darker, text picked by contrast.',
  }
}

/** The `--lab2-*` variables for a palette, the same recipes §37.2 writes for the coral. */
export function paletteVars (palette) {
  const base = parseHex(palette.base)
  const hi = parseHex(palette.hi)
  const lo = parseHex(palette.lo)
  const on = parseHex(palette.on)
  const dark = luminance(on) < 0.2
  const t = base.join(' ')
  const a = (alpha) => 'rgb(' + t + ' / ' + alpha + ')'
  const glow = dark ? 0.6 : 1 // a light colour glows much harder at the same alpha
  // A light fill carries DARK text, so it cannot dissolve into the dark panel the way the coral
  // does: the text on the faded end would be ink on slate. It stays (almost) solid instead.
  const fade = dark
    ? 'linear-gradient(90deg, ' + palette.hi + ' 0%, ' + palette.base + ' 18%, ' + a(0.9) + ' 100%)'
    : 'linear-gradient(90deg, ' + toHex(mix(base, WHITE, 0.03)) + ' 0%, ' + palette.base + ' 18%, ' + a(0.18) + ' 100%)'
  const menuFade = dark
    ? 'linear-gradient(90deg, ' + palette.hi + ' 0%, ' + palette.base + ' 11%, ' + palette.base + ' 60%, ' + a(0.88) + ' 100%)'
    : 'linear-gradient(90deg, ' + palette.hi + ' 0%, ' + palette.base + ' 11%, ' + palette.base + ' 34%, ' + a(0.52) + ' 68%, ' + a(0.03) + ' 100%)'
  return {
    vars: {
      '--lab2': palette.base,
      '--lab2-hi': palette.hi,
      '--lab2-lo': palette.lo,
      '--lab2-soft': a(0.16),
      '--lab2-on': palette.on,
      '--lab2-rgb': t,
      '--lab2-grad': 'linear-gradient(90deg, ' + toHex(mix(base, WHITE, 0.05)) + ' 0%, ' + palette.base + ' 45%, '
        + toHex(mix(lo || base, base, 0.5)) + ' 100%)',
      '--lab2-fade': fade,
      '--lab2-fade-out': 'linear-gradient(90deg, ' + toHex(mix(base, WHITE, 0.03)) + ' 0%, ' + palette.base + ' 16%, ' + a(0.04) + ' 100%)',
      '--lab2-menu-fade': menuFade,
      '--lab2-glow': '0 0 0 1px ' + palette.hi + ', 0 0 22px ' + a(0.42 * glow) + ', inset 0 0 26px ' + a(0.12 * glow),
      '--lab2-glow-sm': '0 0 0 1px ' + palette.hi + ', 0 0 16px ' + a(0.32 * glow),
      '--lab2-focus': '0 0 0 3px ' + a(0.18 * glow),
    },
    on: dark ? 'dark' : 'light',
    contrast: contrast(base, on),
  }
}

/** Which roles a `roles` value names: a mix id or a comma list of role ids. */
export function resolveRoles (value) {
  const mixDef = MIXES.find((m) => m.id === value)
  if (mixDef) return mixDef.roles.slice()
  const ids = ('' + (value || '')).split(/[\s,]+/).filter((id) => ROLES.some((r) => r.id === id))
  return ids.length ? ids : MIXES.find((m) => m.id === DEFAULT_MIX).roles.slice()
}

/** The mix id when `roles` is exactly one of them, else ''. */
export function mixOf (roles) {
  const key = roles.slice().sort().join(',')
  const hit = MIXES.find((m) => m.roles.slice().sort().join(',') === key)
  return hit ? hit.id : ''
}

let styleEl = null

/** Inject the lab stylesheet once per document. */
export function installLab (doc = document) {
  if (styleEl && styleEl.ownerDocument === doc) return
  styleEl = doc.createElement('style')
  styleEl.id = 'core-palette-lab'
  styleEl.textContent = buildCss()
  doc.head.appendChild(styleEl)
}

/** Apply a palette (preset id or hex; falsy / 'off' = the kit as it is) and a role set to `el`. */
export function applyLab (el, paletteValue, roles) {
  const palette = paletteValue && paletteValue !== 'off' ? resolvePalette(paletteValue) : null
  for (const [prop] of Object.entries(paletteVars(PRESETS[0]).vars)) el.style.removeProperty(prop)
  if (!palette) {
    el.removeAttribute('data-lab')
    el.removeAttribute('data-lab-on2')
    return null
  }
  const { vars, on } = paletteVars(palette)
  for (const [prop, value] of Object.entries(vars)) el.style.setProperty(prop, value)
  el.setAttribute('data-lab', roles.join(' '))
  el.setAttribute('data-lab-on2', on)
  return palette
}
