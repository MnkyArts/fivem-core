// core UI kit — the shared composables and helpers every Core*.vue component builds on
// (DESIGN §37.3, §37.4). Pure ESM, `vue` is the only import: the kit must stay a dependency-free
// part of the shell bundle, and every helper here has to work the same in Storybook and in the CEF.
//
// Chromium 103 (§7.1, §37.4): no Popover API and no `:has()`, so popups are teleported into
// `#core-overlays` and placed by hand (placeFloating / useFloating), and Escape is layered by the
// stack below instead of by the browser's top-layer.

import { nextTick, onScopeDispose, reactive, ref, unref, watch } from 'vue'

/** The `size` prop vocabulary of §37.4. */
export const SIZES = ['sm', 'md', 'lg']

/** The `tone` prop vocabulary of §37.4 — the six semantic tones. */
export const TONES = ['accent', 'neutral', 'success', 'warning', 'danger', 'info']

/** Tones a meter may also wear (CoreProgress, CoreRing, CoreStatBar): the vitals of §37.2. */
export const METER_TONES = TONES.concat(['health', 'armour', 'stamina', 'hunger', 'thirst', 'oxygen', 'stress'])

/** Item rarities (CoreSlot, CoreTag). */
export const RARITIES = ['common', 'uncommon', 'rare', 'epic', 'legendary']

/**
 * Prop validator factory for an enum prop: `tone: { type: String, validator: oneOf(TONES) }`.
 *
 * @param {Array<string|number>} list the allowed values
 * @returns {(value: unknown) => boolean}
 */
export function oneOf(list) {
  const allowed = Array.isArray(list) ? list : []
  return (value) => allowed.indexOf(value) !== -1
}

/**
 * The tone class for a component root. base.css maps it to `--tone` / `--tone-rgb` (§37.4).
 *
 * @param {string} tone one of TONES or METER_TONES
 * @returns {string} e.g. `'core-tone-accent'`; an unknown tone falls back to accent
 */
export function toneClass(tone) {
  return 'core-tone-' + (METER_TONES.indexOf(tone) === -1 ? 'accent' : tone)
}

/**
 * The rarity class for a slot or a tag.
 *
 * @param {string} rarity one of RARITIES
 * @returns {string|null} e.g. `'core-rarity-epic'`, or null when there is no rarity
 */
export function rarityClass(rarity) {
  return RARITIES.indexOf(rarity) === -1 ? null : 'core-rarity-' + rarity
}

let idSeq = 0

/**
 * A DOM id that is stable for the lifetime of the component that asked for it (label `for`,
 * `aria-controls`, …). Not reactive on purpose: call it once in `setup`.
 *
 * @param {string} [prefix] `'core'`
 * @returns {string} e.g. `'core-7'`
 */
export function useId(prefix = 'core') {
  idSeq += 1
  return prefix + '-' + idSeq
}

/**
 * Normalises the `items` prop of §37.4: a list of strings/numbers becomes `{ value, label }`
 * objects, objects pass through with `label` defaulting to `String(value)`.
 *
 * @param {Array<string|number|object>|unknown} items
 * @returns {Array<object>} always an array (`[]` for anything that is not one)
 */
export function normalizeItems(items) {
  if (!Array.isArray(items)) return []
  const out = []
  for (let i = 0; i < items.length; i += 1) {
    const item = items[i]
    if (item === null || item === undefined) continue
    if (typeof item === 'string' || typeof item === 'number') {
      out.push({ value: item, label: String(item) })
      continue
    }
    if (typeof item !== 'object') continue
    const value = item.value !== undefined ? item.value : item.id
    out.push(Object.assign({}, item, {
      value,
      label: item.label !== undefined && item.label !== null ? item.label : String(value === undefined ? '' : value),
    }))
  }
  return out
}

/**
 * Clamps a number into a range. A non-numeric input returns `min`.
 *
 * @param {number} n
 * @param {number} min
 * @param {number} max
 * @returns {number}
 */
export function clamp(n, min, max) {
  const v = Number(n)
  if (!Number.isFinite(v)) return min
  if (v < min) return min
  if (v > max) return max
  return v
}

/**
 * Where `value` sits between `min` and `max`, as 0-100. Safe against NaN and a zero span.
 *
 * @param {number} value
 * @param {number} [min] 0
 * @param {number} [max] 100
 * @returns {number} 0-100
 */
export function toPercent(value, min = 0, max = 100) {
  const lo = Number(min)
  const hi = Number(max)
  const v = Number(value)
  if (!Number.isFinite(v) || !Number.isFinite(lo) || !Number.isFinite(hi)) return 0
  const span = hi - lo
  if (span === 0) return v >= hi ? 100 : 0
  return clamp(((v - lo) / span) * 100, 0, 100)
}

/**
 * The next selectable index of a roving list (arrow keys in tabs, menu, chips, radio group),
 * skipping items flagged `disabled`.
 *
 * @param {Array<object>} items normalised items
 * @param {number} from the current index (-1 before anything is selected)
 * @param {number} dir +1 forwards, -1 backwards
 * @param {boolean} [loop] true: wrap around the ends
 * @returns {number} the new index, or `from` when nothing else is selectable
 */
export function nextEnabledIndex(items, from, dir, loop = true) {
  const list = Array.isArray(items) ? items : []
  const len = list.length
  if (len === 0) return from
  const step = dir < 0 ? -1 : 1
  let i = from
  for (let n = 0; n < len; n += 1) {
    i += step
    if (i < 0 || i >= len) {
      if (!loop) return from
      i = i < 0 ? len - 1 : 0
    }
    const item = list[i]
    if (!item || !item.disabled) return i
  }
  return from
}

/**
 * The `data-core-blur` attribute of §32 as a `v-bind` object, so a `blur` prop can be spread onto
 * a panel: `v-bind="blurAttr(props.blur)"`.
 *
 * @param {boolean|number|string} blur false/undefined: no glass; true: the default strength;
 *   a number: that blur radius in CSS px (0 switches it off for this element)
 * @returns {object} `{}` or `{ 'data-core-blur': '' | '<n>' }`
 */
export function blurAttr(blur) {
  if (blur === undefined || blur === null || blur === false || blur === '') return {}
  if (blur === true) return { 'data-core-blur': '' }
  return { 'data-core-blur': String(blur) }
}

/**
 * The element every kit popup teleports into (§37.3): `#core-overlays`, which App.vue renders as
 * the last child of `.core-root` so §31 hides it with the shell. Outside the shell (Storybook, the
 * kit preview, a test page) it is created on the fly.
 *
 * @returns {HTMLElement|null} null when there is no document at all
 */
export function overlayTarget() {
  if (typeof document === 'undefined') return null
  const existing = document.getElementById('core-overlays')
  if (existing) return existing
  const el = document.createElement('div')
  el.id = 'core-overlays'
  el.className = 'core-overlays'
  const root = document.querySelector('.core-root')
  ;(root || document.body).appendChild(el)
  return el
}

/* ---- escape layers (§37.4) -----------------------------------------------------------------
   The store closes the open page on Escape with a BUBBLING window listener (§7.3). A popup that is
   open must swallow that key first, so the kit keeps a stack and one CAPTURING window listener:
   capture runs before the target, and stopImmediatePropagation() there means the store's handler
   never sees the event at all. The listener is installed with the first layer and removed with the
   last, so a shell with no popup open pays nothing. */

const escapeStack = []
let escapeBound = false

function onEscapeCapture(event) {
  if (event.key !== 'Escape' && event.key !== 'Esc') return
  const top = escapeStack[escapeStack.length - 1]
  if (!top) return
  event.preventDefault()
  event.stopImmediatePropagation()
  top()
}

function bindEscape() {
  if (escapeBound || typeof window === 'undefined') return
  window.addEventListener('keydown', onEscapeCapture, true)
  escapeBound = true
}

function unbindEscape() {
  if (!escapeBound || typeof window === 'undefined') return
  window.removeEventListener('keydown', onEscapeCapture, true)
  escapeBound = false
}

/**
 * Pushes an Escape handler onto the kit's layer stack. Only the topmost layer is ever called, and
 * the key stops there.
 *
 * @param {() => void} fn what Escape should do (usually: close this popup)
 * @returns {() => void} dispose — removes this layer wherever it sits in the stack
 */
export function pushEscapeLayer(fn) {
  if (typeof fn !== 'function') return () => {}
  escapeStack.push(fn)
  bindEscape()
  let live = true
  return () => {
    if (!live) return
    live = false
    const i = escapeStack.indexOf(fn)
    if (i !== -1) escapeStack.splice(i, 1)
    if (escapeStack.length === 0) unbindEscape()
  }
}

/**
 * Keeps an Escape layer registered for as long as `activeRef` is truthy, and cleans it up when the
 * component's scope goes away. This is what every kit popup uses.
 *
 * @param {import('vue').Ref<boolean>|(() => boolean)} activeRef open state
 * @param {() => void} fn what Escape should do
 * @returns {() => void} stop — drops the layer by hand
 */
export function useEscapeLayer(activeRef, fn) {
  let dispose = null
  const release = () => {
    if (dispose) dispose()
    dispose = null
  }
  const stop = watch(
    () => Boolean(typeof activeRef === 'function' ? activeRef() : unref(activeRef)),
    (active) => {
      release()
      if (active) dispose = pushEscapeLayer(fn)
    },
    { immediate: true },
  )
  onScopeDispose(() => {
    stop()
    release()
  })
  return () => {
    stop()
    release()
  }
}

/**
 * Calls `fn` when a pointer goes down anywhere outside the given elements, while `activeRef` is
 * truthy. Capturing, so a handler that stops propagation inside the popup cannot hide the click.
 *
 * @param {() => (Element|{ $el?: Element }|import('vue').Ref|null|undefined)[]} getElements
 *   everything that counts as "inside" (the anchor and the floating panel, usually)
 * @param {(event: PointerEvent) => void} fn
 * @param {import('vue').Ref<boolean>|(() => boolean)} [activeRef] default: always active
 * @returns {() => void} stop
 */
export function onClickOutside(getElements, fn, activeRef) {
  if (typeof window === 'undefined') return () => {}
  let bound = false
  const handler = (event) => {
    const list = typeof getElements === 'function' ? getElements() : []
    const target = event.target
    for (let i = 0; i < list.length; i += 1) {
      const el = elementOf(list[i])
      if (el && target instanceof Node && el.contains(target)) return
    }
    fn(event)
  }
  const bind = (on) => {
    if (on === bound) return
    bound = on
    if (on) window.addEventListener('pointerdown', handler, true)
    else window.removeEventListener('pointerdown', handler, true)
  }
  const stopWatch = watch(
    () => (activeRef === undefined ? true : Boolean(typeof activeRef === 'function' ? activeRef() : unref(activeRef))),
    bind,
    { immediate: true },
  )
  const stop = () => {
    stopWatch()
    bind(false)
  }
  onScopeDispose(stop)
  return stop
}

/* ---- floating placement (§37.4) ------------------------------------------------------------
   Chromium 103 has no anchor positioning and no Popover API, so a popup is teleported into
   `#core-overlays` and positioned in viewport (fixed) coordinates by hand. placeFloating() is the
   whole geometry and is pure, so it can be unit-tested; useFloating() only feeds it rects. */

const SIDES = ['top', 'bottom', 'left', 'right']

/** Unwraps whatever a template ref holds: an element, a component instance, or a nested ref. */
function elementOf(value) {
  const v = unref(value)
  if (!v) return null
  if (typeof Element !== 'undefined' && v instanceof Element) return v
  if (v.$el && typeof Element !== 'undefined' && v.$el instanceof Element) return v.$el
  return null
}

function parsePlacement(placement) {
  const parts = String(placement || 'bottom-start').split('-')
  const side = SIDES.indexOf(parts[0]) === -1 ? 'bottom' : parts[0]
  const align = parts[1] === 'start' || parts[1] === 'end' ? parts[1] : 'center'
  return { side, align }
}

function normalizeRect(rect) {
  const r = rect || {}
  const left = Number(r.left !== undefined ? r.left : r.x) || 0
  const top = Number(r.top !== undefined ? r.top : r.y) || 0
  const width = Number(r.width) || 0
  const height = Number(r.height) || 0
  return { left, top, width, height, right: left + width, bottom: top + height }
}

function mainAxis(side, anchor, size, offset) {
  if (side === 'bottom') return anchor.bottom + offset
  if (side === 'top') return anchor.top - offset - size.height
  if (side === 'right') return anchor.right + offset
  return anchor.left - offset - size.width
}

function crossAxis(side, align, anchor, size) {
  const vertical = side === 'top' || side === 'bottom'
  const start = vertical ? anchor.left : anchor.top
  const span = vertical ? anchor.width : anchor.height
  const own = vertical ? size.width : size.height
  if (align === 'start') return start
  if (align === 'end') return start + span - own
  return start + (span - own) / 2
}

/**
 * Places a floating box next to an anchor: flips to the opposite side when the wanted one does not
 * fit, then clamps the result into the viewport. Pure — it reads no DOM.
 *
 * @param {{ left?: number, top?: number, x?: number, y?: number, width: number, height: number }} anchorRect
 * @param {{ width: number, height: number }} floatingSize
 * @param {{ placement?: string, offset?: number, padding?: number,
 *           viewport?: { width: number, height: number } }} [opts]
 *   `placement` is `top|bottom|left|right` with an optional `-start` / `-end` (default: centred),
 *   `offset` the gap to the anchor (8), `padding` the gap to the viewport edge (8). Without an
 *   explicit `viewport` the window's inner size is used, or 1920 x 1080 outside a browser.
 * @returns {{ x: number, y: number, placement: string }} viewport (fixed) coordinates
 */
export function placeFloating(anchorRect, floatingSize, opts = {}) {
  const o = opts || {}
  const offset = Number.isFinite(Number(o.offset)) ? Number(o.offset) : 8
  const padding = Number.isFinite(Number(o.padding)) ? Number(o.padding) : 8
  const hasWindow = typeof window !== 'undefined'
  const vp = o.viewport || (hasWindow ? { width: window.innerWidth, height: window.innerHeight } : { width: 1920, height: 1080 })
  const vw = Number(vp.width) || 0
  const vh = Number(vp.height) || 0

  const anchor = normalizeRect(anchorRect)
  const size = {
    width: Number(floatingSize && floatingSize.width) || 0,
    height: Number(floatingSize && floatingSize.height) || 0,
  }

  const wanted = parsePlacement(o.placement)
  let side = wanted.side
  const align = wanted.align

  // Flip when the wanted side overflows and the opposite one does not.
  const room = {
    top: anchor.top - padding - offset,
    bottom: vh - padding - offset - anchor.bottom,
    left: anchor.left - padding - offset,
    right: vw - padding - offset - anchor.right,
  }
  const need = side === 'top' || side === 'bottom' ? size.height : size.width
  if (room[side] < need) {
    const opposite = { top: 'bottom', bottom: 'top', left: 'right', right: 'left' }[side]
    if (room[opposite] >= need && room[opposite] > room[side]) side = opposite
  }

  const vertical = side === 'top' || side === 'bottom'
  let x = vertical ? crossAxis(side, align, anchor, size) : mainAxis(side, anchor, size, offset)
  let y = vertical ? mainAxis(side, anchor, size, offset) : crossAxis(side, align, anchor, size)

  // Clamp into the viewport; a box wider/taller than the viewport pins to the leading edge.
  const maxX = Math.max(padding, vw - padding - size.width)
  const maxY = Math.max(padding, vh - padding - size.height)
  x = Math.min(Math.max(x, padding), maxX)
  y = Math.min(Math.max(y, padding), maxY)

  return { x, y, placement: align === 'center' ? side : side + '-' + align }
}

/**
 * Keeps a teleported popup glued to its anchor: recomputes on open (after nextTick, when the panel
 * has a size), on window resize, on any capturing scroll, and whenever the panel itself resizes.
 *
 * @param {import('vue').Ref} anchorRef template ref of the trigger
 * @param {import('vue').Ref} floatingRef template ref of the popup
 * @param {import('vue').Ref<boolean>} openRef open state
 * @param {object|(() => object)} [opts] `{ placement, offset, padding, matchWidth }` — a plain
 *   object or a getter, so a component can pass reactive props
 * @returns {{ style: object, placement: import('vue').Ref<string>, update: () => void }}
 *   `style` is `{ position: 'fixed', left, top, minWidth? }` for `:style`
 */
export function useFloating(anchorRef, floatingRef, openRef, opts = {}) {
  const readOpts = () => (typeof opts === 'function' ? opts() : unref(opts)) || {}
  const style = reactive({ position: 'fixed', left: '0px', top: '0px' })
  const placement = ref(parsePlacementString(readOpts().placement))

  function update() {
    if (typeof window === 'undefined') return
    const anchor = elementOf(anchorRef)
    const floating = elementOf(floatingRef)
    if (!anchor || !floating) return
    const o = readOpts()
    const rect = anchor.getBoundingClientRect()
    const placed = placeFloating(rect, { width: floating.offsetWidth, height: floating.offsetHeight }, {
      placement: o.placement,
      offset: o.offset,
      padding: o.padding,
      viewport: { width: window.innerWidth, height: window.innerHeight },
    })
    style.left = Math.round(placed.x) + 'px'
    style.top = Math.round(placed.y) + 'px'
    placement.value = placed.placement
    if (o.matchWidth) style.minWidth = Math.round(rect.width) + 'px'
    else delete style.minWidth
  }

  let observer = null
  let listening = false
  function listen(on) {
    if (typeof window === 'undefined' || on === listening) return
    listening = on
    if (on) {
      window.addEventListener('resize', update)
      window.addEventListener('scroll', update, true)
      if (typeof ResizeObserver !== 'undefined') {
        observer = new ResizeObserver(update)
        const floating = elementOf(floatingRef)
        if (floating) observer.observe(floating)
      }
      return
    }
    window.removeEventListener('resize', update)
    window.removeEventListener('scroll', update, true)
    if (observer) observer.disconnect()
    observer = null
  }

  const stop = watch(
    () => Boolean(unref(openRef)),
    (open) => {
      listen(false)
      if (!open) return
      nextTick(() => {
        update()
        listen(true)
      })
    },
    { immediate: true },
  )

  onScopeDispose(() => {
    stop()
    listen(false)
  })

  return { style, placement, update }
}

function parsePlacementString(placement) {
  const p = parsePlacement(placement)
  return p.align === 'center' ? p.side : p.side + '-' + p.align
}

/* ---- focus (§37.4) -------------------------------------------------------------------------- */

const FOCUSABLE_SELECTOR = [
  'a[href]',
  'area[href]',
  'button:not([disabled])',
  'input:not([disabled]):not([type="hidden"])',
  'select:not([disabled])',
  'textarea:not([disabled])',
  'summary',
  'iframe',
  'audio[controls]',
  'video[controls]',
  '[contenteditable]:not([contenteditable="false"])',
  '[tabindex]:not([tabindex="-1"])',
].join(',')

/**
 * Every element inside `container` a Tab could reach, in document order: visible, not disabled and
 * not `aria-hidden`.
 *
 * @param {Element|{ $el?: Element }|import('vue').Ref} container
 * @returns {HTMLElement[]}
 */
export function focusables(container) {
  const el = elementOf(container)
  if (!el || typeof el.querySelectorAll !== 'function') return []
  const out = []
  const found = el.querySelectorAll(FOCUSABLE_SELECTOR)
  for (let i = 0; i < found.length; i += 1) {
    const node = found[i]
    if (node.hasAttribute('disabled') || node.getAttribute('aria-hidden') === 'true') continue
    if (node.tabIndex < 0) continue
    // offsetParent is null for display:none (and for position:fixed, hence the rect fallback).
    if (node.offsetParent === null && node.getClientRects().length === 0) continue
    out.push(node)
  }
  return out
}

/**
 * Traps Tab inside a container while it is active (CoreDialog, CoreDrawer — §37.5): focus moves in
 * on activation and back to wherever it came from on deactivation.
 *
 * @param {import('vue').Ref} containerRef template ref of the panel
 * @param {import('vue').Ref<boolean>} activeRef open state
 * @param {{ initialFocus?: string|import('vue').Ref, returnFocus?: boolean }} [options]
 *   `initialFocus` is a selector inside the container or a ref; without it the first `[autofocus]`
 *   wins, then the first focusable. `returnFocus` (true) restores the previous focus on close.
 * @returns {{ focusInitial: () => void }}
 */
export function useFocusTrap(containerRef, activeRef, options = {}) {
  const opts = options || {}
  const returnFocus = opts.returnFocus !== false
  let previous = null
  let bound = false

  function onKeydown(event) {
    if (event.key !== 'Tab') return
    const container = elementOf(containerRef)
    if (!container) return
    const list = focusables(container)
    if (list.length === 0) {
      event.preventDefault()
      return
    }
    const first = list[0]
    const last = list[list.length - 1]
    const active = document.activeElement
    if (!container.contains(active)) {
      event.preventDefault()
      ;(event.shiftKey ? last : first).focus()
      return
    }
    if (event.shiftKey && active === first) {
      event.preventDefault()
      last.focus()
    } else if (!event.shiftKey && active === last) {
      event.preventDefault()
      first.focus()
    }
  }

  function focusInitial() {
    const container = elementOf(containerRef)
    if (!container) return
    let target = null
    if (opts.initialFocus) {
      target = typeof opts.initialFocus === 'string'
        ? container.querySelector(opts.initialFocus)
        : elementOf(opts.initialFocus)
    }
    if (!target) target = container.querySelector('[autofocus]')
    if (!target) target = focusables(container)[0] || null
    if (target && typeof target.focus === 'function') target.focus()
  }

  function bind(on) {
    if (typeof window === 'undefined' || on === bound) return
    bound = on
    if (on) window.addEventListener('keydown', onKeydown)
    else window.removeEventListener('keydown', onKeydown)
  }

  const stop = watch(
    () => Boolean(unref(activeRef)),
    (active) => {
      if (active) {
        previous = typeof document !== 'undefined' ? document.activeElement : null
        bind(true)
        nextTick(focusInitial)
        return
      }
      bind(false)
      if (returnFocus && previous && typeof previous.focus === 'function') previous.focus()
      previous = null
    },
    { immediate: true },
  )

  onScopeDispose(() => {
    stop()
    bind(false)
  })

  return { focusInitial }
}
