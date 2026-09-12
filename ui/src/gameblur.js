// core UI — glass panels: a live, blurred copy of the game behind `data-core-blur` (DESIGN §32)
//
// CSS backdrop filters cannot see the game — the CEF page is transparent and nothing of GTA is
// part of the browser's compositing surface, so FiveM paints a filtered area as a solid black
// box. FiveM's nui-core hooks `glTexParameterf` instead (NUIInitialize.cpp): a TEXTURE_2D
// texture that receives CLAMP_TO_EDGE -> MIRRORED_REPEAT -> REPEAT on TEXTURE_WRAP_T gets the
// game's back buffer bound to it (shared D3D11 texture -> EGL pbuffer). The FiveM main menu
// draws that texture into a canvas every 33 ms and blurs the canvas; the hook is process wide,
// so a resource NUI frame can do exactly the same.
//
//   installGameBlur(root[, initial]) -> { mode(), isAvailable(), refresh(), destroy() }
//
// One hidden source canvas holds the whole screen at `store.blur.scale`. Every element carrying
// `data-core-blur` gets a `.core-glass` wrapper (styles.css) whose canvas copies that element's
// own rectangle out of the source and blurs it in CSS. Outside FiveM (a plain browser, Storybook,
// the offline tests) the texture stays the 1x1 blue placeholder the sequence started from — that
// is what the probe detects, and the source becomes a painted dusk gradient in the Storybook
// preview's colours so the effect still shows during development.
//
// The module owns its config itself: it imports the store and reads `store.blur` and
// `store.shell.visible` on every tick, so nothing has to be plumbed through App.vue.
import { watch } from 'vue'
import { store, setBlur } from './store.js'

// ---------------------------------------------------------------- constants

/** The 1x1 pixel the hook sequence starts from. Still there after a draw = no hook. */
const PLACEHOLDER = { r: 0, g: 0, b: 255, tolerance: 8 }

/** The probe is retried a few times after install: the NUI can be alive before the game has
 *  rendered its first frame, and the back buffer is only swapped in once it has. */
const PROBE_RETRY_MS = [250, 1000, 3000]

/** §32.1 budget. Going over is a page bug, not a reason to stop drawing — one console warning. */
const CONSUMER_BUDGET = 12

/** Clamps from §32.2, applied here as well as in the store: a page may write `store.blur`. */
const LIMITS = {
  strength: [0, 40],
  fps: [5, 60],
  scale: [0.1, 1],
}

// Screen-space copy. The game frame is top-down and GL texture space is bottom-up, so Y is
// mirrored here: canvas (0, 0) is then the top-left of the game frame and every consumer can
// crop with plain CSS viewport coordinates.
const VERTEX_SRC = [
  'attribute vec2 aPosition;',
  'varying vec2 textureCoordinate;',
  'void main() {',
  '  gl_Position = vec4(aPosition, 0.0, 1.0);',
  '  textureCoordinate = vec2(aPosition.x * 0.5 + 0.5, 0.5 - aPosition.y * 0.5);',
  '}',
].join('\n')

const FRAGMENT_SRC = [
  'precision mediump float;',
  'uniform sampler2D external_texture;',
  'varying vec2 textureCoordinate;',
  'void main() {',
  '  gl_FragColor = texture2D(external_texture, textureCoordinate);',
  '}',
].join('\n')

/** `.storybook/preview.js` GAME_BG, layer for layer (CSS paints the first layer on top, so this
 *  list is drawn back to front). Lengths are CSS px and get multiplied by the source scale, so
 *  the fallback lines up with the Storybook floor: a panel's glass is the backdrop, blurred. */
const FALLBACK_BASE = '#0b0f15'
const FALLBACK_LINEAR = {
  deg: 168,
  stops: [[0, '#27323f'], [0.38, '#1b2330'], [0.68, '#131922'], [1, '#0b0f15']],
}
const FALLBACK_RADIALS = [
  { x: 0.50, y: 1.18, rx: 1500, ry: 900, rgb: [8, 11, 16], alpha: 0.88, stop: 0.68 },
  { x: 0.86, y: 0.82, rx: 900, ry: 620, rgb: [198, 128, 68], alpha: 0.20, stop: 0.58 },
  { x: 0.18, y: 0.12, rx: 1200, ry: 720, rgb: [108, 138, 184], alpha: 0.34, stop: 0.62 },
]

// ---------------------------------------------------------------- module state
// One install per page (`installGameBlur` returns the same controller on a second call), so all
// of this is module scope; `destroy()` puts it back to the state below.

let controller = null
let rootEl = null
let observer = null
let unwatch = null
let timer = null
let syncQueued = false
let probeTimers = []
let warnedBudget = false

let glCanvas = null
let gl = null
let glProgram = null
let glBuffer = null
let glTexture = null
let glPosition = -1

let fbCanvas = null
let fbCtx = null
let fbKey = ''

/** 'live' (the hook answered), 'fallback' (painted gradient) or 'off' (no WebGL at all). */
let sourceMode = 'off'

/** element -> { wrapper, canvas, ctx, prevPosition, prevIsolation, strength, geom } */
const consumers = new Map()

// ---------------------------------------------------------------- small helpers

function clamp(value, range, fallback) {
  const n = Number(value)
  if (!Number.isFinite(n)) return fallback
  return Math.min(range[1], Math.max(range[0], n))
}

const cfgStrength = () => clamp(store.blur.strength, LIMITS.strength, 10)
const cfgFps = () => clamp(store.blur.fps, LIMITS.fps, 30)
const cfgScale = () => clamp(store.blur.scale, LIMITS.scale, 0.5)

function setStyle(el, prop, value) {
  if (el.style[prop] !== value) el.style[prop] = value
}

/** `data-core-blur="0"` (an explicit zero) switches the element off; any other non-number, or
 *  an empty value, means "use the configured strength". */
function attrStrength(el) {
  const raw = el.getAttribute('data-core-blur')
  if (raw == null || String(raw).trim() === '') return cfgStrength()
  const n = Number(raw)
  return Number.isFinite(n) ? clamp(n, LIMITS.strength, cfgStrength()) : cfgStrength()
}

function isDisabledConsumer(el) {
  const raw = el.getAttribute('data-core-blur')
  if (raw == null || String(raw).trim() === '') return false
  const n = Number(raw)
  return Number.isFinite(n) && n === 0
}

/** `<html data-game-blur="live|fallback|off">`: the mode a page or a test can read. Lives on
 *  documentElement so it is the same place whether the module was installed on `#app` (main.js)
 *  or on `document.body` (Storybook). */
function setRootMode(value) {
  const el = document.documentElement
  if (!el) return
  if (el.dataset.gameBlur !== value) el.dataset.gameBlur = value
}

/** The effective mode: the switch in `store.blur` can turn a working source off. */
function effectiveMode() {
  if (sourceMode === 'off' || !store.blur.enabled) return 'off'
  return sourceMode
}

// ---------------------------------------------------------------- source: WebGL (the game)

function compile(context, type, src) {
  const shader = context.createShader(type)
  context.shaderSource(shader, src)
  context.compileShader(shader)
  if (context.getShaderParameter(shader, context.COMPILE_STATUS)) return shader
  console.warn('[core:ui] game blur shader failed', context.getShaderInfoLog(shader))
  context.deleteShader(shader)
  return null
}

/** Builds the WebGL source. Returns false for every browser/CEF that has no usable context —
 *  mode `off`, no exception ever escapes into the shell. */
function createGl() {
  const options = {
    alpha: false,
    antialias: false,
    depth: false,
    stencil: false,
    preserveDrawingBuffer: true,   // readPixels (the probe) and drawImage read it back
    failIfMajorPerformanceCaveat: false,
  }
  let context = null
  try {
    // The canvas is never inserted into the page: the hook runs on the GL call, not on
    // compositing, and an off-DOM canvas cannot disturb the shell's layout.
    glCanvas = document.createElement('canvas')
    glCanvas.width = 1
    glCanvas.height = 1
    context = glCanvas.getContext('webgl', options) || glCanvas.getContext('experimental-webgl', options)
  } catch (err) {
    context = null
  }
  if (!context) {
    glCanvas = null
    return false
  }

  const vs = compile(context, context.VERTEX_SHADER, VERTEX_SRC)
  const fs = compile(context, context.FRAGMENT_SHADER, FRAGMENT_SRC)
  if (!vs || !fs) {
    glCanvas = null
    return false
  }
  const program = context.createProgram()
  context.attachShader(program, vs)
  context.attachShader(program, fs)
  context.linkProgram(program)
  if (!context.getProgramParameter(program, context.LINK_STATUS)) {
    console.warn('[core:ui] game blur program failed', context.getProgramInfoLog(program))
    glCanvas = null
    return false
  }

  const buffer = context.createBuffer()
  context.bindBuffer(context.ARRAY_BUFFER, buffer)
  // One full-screen quad as a TRIANGLE_STRIP, exactly like the main menu.
  context.bufferData(context.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), context.STATIC_DRAW)

  // The hook sequence. `texParameterf` (not `texParameteri`): nui-core hooks glTexParameterf,
  // so the WRAP_T triple has to travel through that entry point to be seen.
  const texture = context.createTexture()
  context.bindTexture(context.TEXTURE_2D, texture)
  context.texImage2D(
    context.TEXTURE_2D, 0, context.RGBA, 1, 1, 0, context.RGBA, context.UNSIGNED_BYTE,
    new Uint8Array([PLACEHOLDER.r, PLACEHOLDER.g, PLACEHOLDER.b, 255])
  )
  context.texParameterf(context.TEXTURE_2D, context.TEXTURE_MAG_FILTER, context.NEAREST)
  context.texParameterf(context.TEXTURE_2D, context.TEXTURE_MIN_FILTER, context.NEAREST)
  context.texParameterf(context.TEXTURE_2D, context.TEXTURE_WRAP_S, context.CLAMP_TO_EDGE)
  context.texParameterf(context.TEXTURE_2D, context.TEXTURE_WRAP_T, context.CLAMP_TO_EDGE)
  context.texParameterf(context.TEXTURE_2D, context.TEXTURE_WRAP_T, context.MIRRORED_REPEAT)
  context.texParameterf(context.TEXTURE_2D, context.TEXTURE_WRAP_T, context.REPEAT)
  context.texParameterf(context.TEXTURE_2D, context.TEXTURE_WRAP_T, context.CLAMP_TO_EDGE)

  gl = context
  glProgram = program
  glBuffer = buffer
  glTexture = texture
  glPosition = context.getAttribLocation(program, 'aPosition')

  // A lost context (driver reset, tab moved between GPUs) would otherwise freeze the glass on
  // its last frame: drop to the gradient and rebuild on restore.
  glCanvas.addEventListener('webglcontextlost', onContextLost, false)
  glCanvas.addEventListener('webglcontextrestored', onContextRestored, false)
  return true
}

function onContextLost(event) {
  event.preventDefault()
  gl = null
  if (sourceMode === 'live') sourceMode = 'fallback'
  applyConfig()
}

function onContextRestored() {
  destroyGl()
  if (createGl()) probeSource()
  applyConfig()
}

function destroyGl() {
  if (glCanvas) {
    glCanvas.removeEventListener('webglcontextlost', onContextLost, false)
    glCanvas.removeEventListener('webglcontextrestored', onContextRestored, false)
  }
  if (gl) {
    const lose = gl.getExtension('WEBGL_lose_context')
    if (lose) {
      try { lose.loseContext() } catch (err) { /* already gone */ }
    }
  }
  gl = null
  glCanvas = null
  glProgram = null
  glBuffer = null
  glTexture = null
  glPosition = -1
}

function drawGl(width, height) {
  if (!gl || !glCanvas) return false
  if (glCanvas.width !== width || glCanvas.height !== height) {
    glCanvas.width = width
    glCanvas.height = height
  }
  gl.viewport(0, 0, width, height)
  gl.useProgram(glProgram)
  gl.bindBuffer(gl.ARRAY_BUFFER, glBuffer)
  gl.enableVertexAttribArray(glPosition)
  gl.vertexAttribPointer(glPosition, 2, gl.FLOAT, false, 0, 0)
  gl.activeTexture(gl.TEXTURE0)
  gl.bindTexture(gl.TEXTURE_2D, glTexture)
  const sampler = gl.getUniformLocation(glProgram, 'external_texture')
  if (sampler) gl.uniform1i(sampler, 0)
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
  return true
}

/** §32.2: draw once, then read four points back. All four still the placeholder blue = the hook
 *  never bound the game frame (browser, Storybook, a build that dropped it) -> fallback. */
function probeSource() {
  if (!gl || !glCanvas) {
    // No context, or it was lost: the gradient is all there is — unless WebGL never existed
    // here at all, and then `off` has to stay `off`.
    if (sourceMode !== 'off') sourceMode = 'fallback'
    return sourceMode
  }
  const size = sourceSize()
  if (!drawGl(size.w, size.h)) return sourceMode
  const px = new Uint8Array(4)
  const points = [
    [size.w * 0.5, size.h * 0.5],
    [size.w * 0.25, size.h * 0.25],
    [size.w * 0.75, size.h * 0.25],
    [size.w * 0.5, size.h * 0.75],
  ]
  let live = false
  for (const point of points) {
    const x = Math.max(0, Math.min(size.w - 1, Math.round(point[0])))
    const y = Math.max(0, Math.min(size.h - 1, Math.round(point[1])))
    try {
      gl.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px)
    } catch (err) {
      return 'fallback'
    }
    const t = PLACEHOLDER.tolerance
    const placeholder = Math.abs(px[0] - PLACEHOLDER.r) <= t
      && Math.abs(px[1] - PLACEHOLDER.g) <= t
      && Math.abs(px[2] - PLACEHOLDER.b) <= t
    if (!placeholder) {
      live = true
      break
    }
  }
  sourceMode = live ? 'live' : 'fallback'
  if (live) {
    // The gradient is dead weight once the real frame arrives.
    fbCanvas = null
    fbCtx = null
    fbKey = ''
    clearProbeRetries()
  }
  return sourceMode
}

function clearProbeRetries() {
  for (const id of probeTimers) clearTimeout(id)
  probeTimers = []
}

/** The NUI can be up before the game drew its first frame, so the probe gets a few more tries.
 *  They stop the moment it answers `live` (or the module is destroyed). */
function scheduleProbeRetries() {
  clearProbeRetries()
  for (const delay of PROBE_RETRY_MS) {
    probeTimers.push(setTimeout(() => {
      if (!controller || sourceMode !== 'fallback') return
      if (probeSource() === 'live') applyConfig()
    }, delay))
  }
}

// ---------------------------------------------------------------- source: fallback gradient

/** One CSS `radial-gradient(<rx> <ry> at <x%> <y%>, rgba(...), transparent <stop>)`. Canvas only
 *  has circular gradients, so the circle is squashed by ry/rx; the end stop keeps the same RGB at
 *  alpha 0 so the fade does not darken the way a fade to `rgba(0,0,0,0)` would. */
function paintRadial(ctx, w, h, layer, scale) {
  const rx = Math.max(1, layer.rx * scale)
  const ry = Math.max(1, layer.ry * scale)
  const cx = w * layer.x
  const cy = h * layer.y
  const k = rx / ry
  const rgb = layer.rgb.join(', ')
  const gradient = ctx.createRadialGradient(0, 0, 0, 0, 0, rx)
  gradient.addColorStop(0, 'rgba(' + rgb + ', ' + layer.alpha + ')')
  gradient.addColorStop(Math.min(0.999, layer.stop), 'rgba(' + rgb + ', 0)')
  gradient.addColorStop(1, 'rgba(' + rgb + ', 0)')
  ctx.save()
  ctx.translate(cx, cy)
  ctx.scale(1, ry / rx)
  ctx.fillStyle = gradient
  ctx.fillRect(-cx, -cy * k, w, h * k)   // the canvas, expressed in the squashed space
  ctx.restore()
}

/** The dusk street of `.storybook/preview.js` GAME_BG, painted into the source canvas. */
function paintFallback(ctx, w, h, scale) {
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.globalCompositeOperation = 'source-over'
  ctx.fillStyle = FALLBACK_BASE
  ctx.fillRect(0, 0, w, h)

  const rad = (FALLBACK_LINEAR.deg * Math.PI) / 180
  const dx = Math.sin(rad)
  const dy = -Math.cos(rad)
  const len = Math.abs(w * Math.sin(rad)) + Math.abs(h * Math.cos(rad))   // CSS gradient line
  const linear = ctx.createLinearGradient(
    w / 2 - (dx * len) / 2, h / 2 - (dy * len) / 2,
    w / 2 + (dx * len) / 2, h / 2 + (dy * len) / 2
  )
  for (const stop of FALLBACK_LINEAR.stops) linear.addColorStop(stop[0], stop[1])
  ctx.fillStyle = linear
  ctx.fillRect(0, 0, w, h)

  for (const layer of FALLBACK_RADIALS) paintRadial(ctx, w, h, layer, scale)
}

function drawFallback(width, height, scale) {
  if (!fbCanvas) {
    fbCanvas = document.createElement('canvas')
    fbCtx = fbCanvas.getContext('2d')
    fbKey = ''
  }
  if (!fbCtx) return false
  const key = width + 'x' + height + '@' + scale
  if (fbKey === key) return true            // static image: repaint only when the size changed
  fbCanvas.width = width
  fbCanvas.height = height
  paintFallback(fbCtx, width, height, scale)
  fbKey = key
  return true
}

// ---------------------------------------------------------------- the shared source

function sourceSize() {
  const scale = cfgScale()
  return {
    w: Math.max(1, Math.round((window.innerWidth || 1) * scale)),
    h: Math.max(1, Math.round((window.innerHeight || 1) * scale)),
    scale,
  }
}

/** Refreshes the one source canvas for this frame. Returns the canvas, or null. */
function drawSource() {
  const size = sourceSize()
  if (sourceMode === 'live') return drawGl(size.w, size.h) ? glCanvas : null
  if (sourceMode === 'fallback') return drawFallback(size.w, size.h, size.scale) ? fbCanvas : null
  return null
}

// ---------------------------------------------------------------- consumers

function attach(el) {
  const wrapper = document.createElement('div')
  wrapper.className = 'core-glass'
  wrapper.setAttribute('aria-hidden', 'true')
  const canvas = document.createElement('canvas')
  wrapper.appendChild(canvas)

  // A negative-z child needs a positioned, isolated parent: `isolation: isolate` keeps the
  // wrapper from falling behind the page instead of behind the panel's own content.
  const computed = window.getComputedStyle(el)
  const entry = {
    wrapper,
    canvas,
    ctx: canvas.getContext('2d'),
    prevPosition: el.style.position,
    prevIsolation: el.style.isolation,
    tookPosition: computed.position === 'static',
    strength: -1,
    geom: '',
  }
  if (entry.tookPosition) el.style.position = 'relative'
  el.style.isolation = 'isolate'
  el.insertBefore(wrapper, el.firstChild)
  consumers.set(el, entry)
}

function detach(el) {
  const entry = consumers.get(el)
  if (!entry) return
  consumers.delete(el)
  if (entry.wrapper.parentNode) entry.wrapper.parentNode.removeChild(entry.wrapper)
  if (entry.tookPosition) el.style.position = entry.prevPosition
  el.style.isolation = entry.prevIsolation
}

function detachAll() {
  for (const el of Array.from(consumers.keys())) detach(el)
}

/** Full rescan of `root` — cheap (a handful of panels) and idempotent, so the MutationObserver
 *  can just call it instead of reasoning about individual records. */
function syncConsumers() {
  if (!rootEl) return
  if (!store.blur.enabled || sourceMode === 'off') {
    detachAll()
    return
  }
  const found = new Set()
  if (rootEl.matches && rootEl.matches('[data-core-blur]')) found.add(rootEl)
  for (const el of rootEl.querySelectorAll('[data-core-blur]')) found.add(el)

  for (const el of Array.from(consumers.keys())) {
    if (!el.isConnected || !found.has(el) || isDisabledConsumer(el)) detach(el)
  }
  for (const el of found) {
    if (isDisabledConsumer(el) || consumers.has(el)) continue
    attach(el)
  }
  if (consumers.size > CONSUMER_BUDGET && !warnedBudget) {
    warnedBudget = true
    console.warn('[core:ui] game blur: ' + consumers.size + ' data-core-blur elements (DESIGN §32.1 budget is '
      + CONSUMER_BUDGET + ') — put it on panels, never on list rows')
  }
}

/** Mutation records arrive in bursts (one Vue patch = many records); collapse them into one
 *  rescan on the microtask queue. Our own wrapper insertion triggers exactly one extra pass,
 *  which finds nothing new and stops. */
function scheduleSync() {
  if (syncQueued || !controller) return
  syncQueued = true
  Promise.resolve().then(() => {
    syncQueued = false
    if (!controller) return
    syncConsumers()
    kick()
  })
}

// ---------------------------------------------------------------- frame loop

/** Everything except "is any consumer actually visible" — that costs a layout read, so the tick
 *  itself decides it while it measures. */
function canRun() {
  return !!controller
    && sourceMode !== 'off'
    && store.blur.enabled === true
    && store.shell.visible !== false
    && document.hidden !== true
    && consumers.size > 0
}

function stop() {
  if (timer === null) return
  clearTimeout(timer)
  timer = null
}

function kick() {
  if (timer !== null || !canRun()) return
  timer = setTimeout(tick, 0)
}

function tick() {
  timer = null
  if (!canRun()) return
  if (!drawFrame()) return          // nothing to paint -> the loop stops completely
  timer = setTimeout(tick, Math.round(1000 / cfgFps()))
}

/** One frame: measure every consumer (read phase), draw the source once, copy per consumer
 *  (write phase). Returns false when no consumer had a non-zero rect. */
function drawFrame() {
  const scale = cfgScale()
  const jobs = []
  for (const [el, entry] of consumers) {
    if (!el.isConnected) continue
    const rect = entry.wrapper.getBoundingClientRect()
    if (rect.width <= 0 || rect.height <= 0) continue
    jobs.push({ entry, rect, strength: attrStrength(el) })
  }
  if (!jobs.length) return false
  const src = drawSource()
  if (!src) return false
  for (const job of jobs) paintConsumer(job, src, scale)
  return true
}

function paintConsumer(job, src, scale) {
  const entry = job.entry
  const rect = job.rect
  const strength = job.strength
  // −2×strength on every side: a CSS blur samples transparent pixels past the edge, so the copy
  // has to be bigger than the panel or the glass gets a washed-out border.
  const margin = strength * 2
  const cssW = rect.width + margin * 2
  const cssH = rect.height + margin * 2

  const geom = margin + ':' + Math.round(cssW) + ':' + Math.round(cssH)
  if (entry.geom !== geom) {
    entry.geom = geom
    setStyle(entry.canvas, 'left', -margin + 'px')
    setStyle(entry.canvas, 'top', -margin + 'px')
    setStyle(entry.canvas, 'width', cssW + 'px')
    setStyle(entry.canvas, 'height', cssH + 'px')
  }
  if (entry.strength !== strength) {
    entry.strength = strength
    setStyle(entry.canvas, 'filter', 'blur(' + strength + 'px)')
  }

  const bw = Math.max(1, Math.round(cssW * scale))
  const bh = Math.max(1, Math.round(cssH * scale))
  if (entry.canvas.width !== bw) entry.canvas.width = bw        // reassigning also clears it
  if (entry.canvas.height !== bh) entry.canvas.height = bh
  const ctx = entry.ctx
  if (!ctx) return
  ctx.clearRect(0, 0, bw, bh)

  // The source holds the viewport at `scale`, so the element's CSS rect maps straight into it.
  const sx = (rect.left - margin) * scale
  const sy = (rect.top - margin) * scale
  const sw = cssW * scale
  const sh = cssH * scale
  if (sw <= 0 || sh <= 0) return
  const x0 = Math.max(0, Math.min(src.width, sx))
  const y0 = Math.max(0, Math.min(src.height, sy))
  const x1 = Math.max(0, Math.min(src.width, sx + sw))
  const y1 = Math.max(0, Math.min(src.height, sy + sh))
  if (x1 - x0 < 1 || y1 - y0 < 1) return
  // A panel hanging over the screen edge gets its source rect clamped; the destination is
  // clamped by the same fraction so the copy keeps its 1:1 scale instead of stretching (a plain
  // `drawImage(src, sx, sy, sw, sh, 0, 0, w, h)` when nothing is clipped).
  const dx = ((x0 - sx) / sw) * bw
  const dy = ((y0 - sy) / sh) * bh
  const dw = ((x1 - x0) / sw) * bw
  const dh = ((y1 - y0) / sh) * bh
  ctx.drawImage(src, x0, y0, x1 - x0, y1 - y0, dx, dy, dw, dh)
}

// ---------------------------------------------------------------- config / events

/** Re-reads `store.blur` + `store.shell.visible`: attaches or drops every wrapper, writes the
 *  root attribute and starts or stops the loop. Cheap enough to call from anywhere. */
function applyConfig() {
  if (!controller) return
  const mode = effectiveMode()
  setRootMode(mode)
  if (mode === 'off') {
    stop()
    detachAll()                    // §32.4: disabled means no `.core-glass` in the document
    return
  }
  syncConsumers()
  fbKey = ''                       // scale may have changed: repaint the gradient once
  kick()
}

function onResize() {
  fbKey = ''
  kick()
}

function onVisibility() {
  if (document.hidden) stop()
  else kick()
}

// ---------------------------------------------------------------- install

/**
 * Installs the game blur once per page (a second call returns the same controller, whatever
 * `root` says). `root` is the subtree watched for `data-core-blur`: `#app` from main.js,
 * `document.body` from Storybook.
 *
 * @param {Element} root element whose subtree is scanned for `data-core-blur`
 * @param {{enabled?: boolean, strength?: number, fps?: number, scale?: number}} [initial]
 *        optional config merged into `store.blur` before the first frame (same clamps as the
 *        `blur:set` message) — Storybook uses it, Lua sends `blur:set` instead
 * @returns {{mode: () => string, isAvailable: () => boolean, refresh: () => string, destroy: () => void}}
 */
export function installGameBlur(root, initial) {
  if (controller) {
    if (initial) setBlur(initial)
    controller.refresh()
    return controller
  }
  if (initial) setBlur(initial)

  rootEl = root && root.nodeType === 1 ? root : document.body
  if (!rootEl) {
    setRootMode('off')
    return {
      mode: () => 'off',
      isAvailable: () => false,
      refresh: () => 'off',
      destroy: () => {},
    }
  }

  sourceMode = createGl() ? 'fallback' : 'off'

  controller = {
    /** What `<html data-game-blur>` says: 'live' (the game frame), 'fallback' (the dev
     *  gradient) or 'off' (no WebGL, or `store.blur.enabled === false`). */
    mode: () => effectiveMode(),
    /** True when this page can produce a source at all — the WebGL probe succeeded. It does
     *  not follow the config switch; `mode()` does. */
    isAvailable: () => sourceMode !== 'off',
    /** Re-runs the probe (call it once the game is actually rendering) and the consumer scan. */
    refresh() {
      if (!controller) return 'off'
      if (sourceMode !== 'live') probeSource()
      applyConfig()
      return effectiveMode()
    },
    /** Removes every wrapper, the observer, the loop and the GL context. */
    destroy() {
      stop()
      clearProbeRetries()
      if (observer) observer.disconnect()
      if (unwatch) unwatch()
      window.removeEventListener('resize', onResize)
      document.removeEventListener('visibilitychange', onVisibility)
      detachAll()
      destroyGl()
      fbCanvas = null
      fbCtx = null
      fbKey = ''
      sourceMode = 'off'
      const el = document.documentElement
      if (el && el.dataset.gameBlur !== undefined) delete el.dataset.gameBlur
      observer = null
      unwatch = null
      rootEl = null
      controller = null
      warnedBudget = false
    },
  }

  if (sourceMode !== 'off') {
    probeSource()
    if (sourceMode === 'fallback') scheduleProbeRetries()
  }

  observer = new MutationObserver(scheduleSync)
  // `class`/`style`/`hidden` are watched as well: a panel can become visible again without any
  // node being added (v-show, a state class), and the loop has to be woken for that too.
  observer.observe(rootEl, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['data-core-blur', 'class', 'style', 'hidden'],
  })

  // The only config plumbing there is (§32 "Install"): the store drives everything.
  unwatch = watch(
    () => [store.blur.enabled, store.blur.strength, store.blur.fps, store.blur.scale, store.shell.visible],
    () => applyConfig()
  )

  window.addEventListener('resize', onResize)
  document.addEventListener('visibilitychange', onVisibility)

  applyConfig()
  return controller
}

export default installGameBlur
