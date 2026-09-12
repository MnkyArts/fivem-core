// core UI — one-shot experiment for the game-blur texture hook (DESIGN §32, diagnostics only).
//
// Runs only inside a real NUI frame and only when the normal probe in gameblur.js stayed on
// the placeholder (or on `/uiblur test`). It creates a throw-away WebGL context per variant,
// issues one recipe of the "secret" TEXTURE_WRAP_T sequence, draws the texture and reads the
// centre pixel back twice (at once and 400 ms later). Whatever variant reports something other
// than the placeholder blue is the recipe nui-core's glTexParameterf hook accepts on this build.
// The results go to Lua as `blur_diag` with reason `variants` and end up in the client log.
import { post } from './bridge.js'

const VS = 'attribute vec2 aPosition; varying vec2 t; void main() { gl_Position = vec4(aPosition, 0.0, 1.0); t = aPosition * 0.5 + 0.5; }'
const FS = 'precision mediump float; uniform sampler2D external_texture; varying vec2 t; void main() { gl_FragColor = texture2D(external_texture, t); }'
const PLACEHOLDER = new Uint8Array([0, 0, 255, 255])

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

function makeContext(kind, layout) {
  const canvas = document.createElement('canvas')
  canvas.width = 64
  canvas.height = 36
  if (layout === 'tiny' || layout === 'full') {
    canvas.setAttribute('aria-hidden', 'true')
    Object.assign(canvas.style, layout === 'full'
      ? { position: 'fixed', inset: '0', width: '100vw', height: '100vh', opacity: '0.01', pointerEvents: 'none', zIndex: '-1' }
      : { position: 'fixed', left: '0', top: '0', width: '2px', height: '2px', opacity: '0.01', pointerEvents: 'none', zIndex: '-1' })
    document.body.appendChild(canvas)
  }
  const attrs = { alpha: false, antialias: false, depth: false, stencil: false, preserveDrawingBuffer: true, failIfMajorPerformanceCaveat: false }
  let gl = null
  try {
    gl = canvas.getContext(kind, attrs)
    if (!gl && kind === 'webgl') gl = canvas.getContext('experimental-webgl', attrs)
  } catch (err) { gl = null }
  return { canvas, gl }
}

function makeProgram(gl) {
  const compile = (type, src) => {
    const sh = gl.createShader(type)
    gl.shaderSource(sh, src)
    gl.compileShader(sh)
    if (!gl.getShaderParameter(sh, gl.COMPILE_STATUS)) throw new Error('shader: ' + gl.getShaderInfoLog(sh))
    return sh
  }
  const program = gl.createProgram()
  gl.attachShader(program, compile(gl.VERTEX_SHADER, VS))
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FS))
  gl.linkProgram(program)
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error('link: ' + gl.getProgramInfoLog(program))
  const buffer = gl.createBuffer()
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW)
  return { program, buffer }
}

function drawAndRead(gl, program, buffer, texture) {
  gl.viewport(0, 0, gl.drawingBufferWidth, gl.drawingBufferHeight)
  gl.useProgram(program)
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
  const loc = gl.getAttribLocation(program, 'aPosition')
  gl.enableVertexAttribArray(loc)
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0)
  gl.activeTexture(gl.TEXTURE0)
  gl.bindTexture(gl.TEXTURE_2D, texture)
  gl.uniform1i(gl.getUniformLocation(program, 'external_texture'), 0)
  gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4)
  const px = new Uint8Array(4)
  gl.readPixels(gl.drawingBufferWidth >> 1, gl.drawingBufferHeight >> 1, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, px)
  return [px[0], px[1], px[2], px[3]]
}

const T = 0x0DE1 // TEXTURE_2D

// Each recipe gets a fresh, bound texture and does the whole parameter/upload dance itself.
const RECIPES = {
  // What gameblur.js does today: f for everything, 1x1 upload first, trailing CLAMP reset.
  'f-1x1-reset': (gl) => {
    gl.texImage2D(T, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, PLACEHOLDER)
    gl.texParameterf(T, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.texParameterf(T, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.texParameterf(T, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.REPEAT)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
  },
  // Same without the trailing reset (screenshot-basic has none).
  'f-1x1-noreset': (gl) => {
    gl.texImage2D(T, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, PLACEHOLDER)
    gl.texParameterf(T, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.texParameterf(T, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.texParameterf(T, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.REPEAT)
  },
  // screenshot-basic (three.js 0.100): i-params first, upload, then only the three f WRAP_T calls.
  'ssb-i-then-f': (gl) => {
    gl.texParameteri(T, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameteri(T, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.texParameteri(T, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.texImage2D(T, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, PLACEHOLDER)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.REPEAT)
  },
  // Same, but the upload is viewport-sized (a DataTexture of the screen size).
  'ssb-viewport': (gl) => {
    gl.texParameteri(T, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameteri(T, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.texParameteri(T, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    const w = Math.max(1, window.innerWidth), h = Math.max(1, window.innerHeight)
    const data = new Uint8Array(w * h * 4)
    for (let i = 0; i < data.length; i += 4) { data[i + 2] = 255; data[i + 3] = 255 }
    gl.texImage2D(T, 0, gl.RGBA, w, h, 0, gl.RGBA, gl.UNSIGNED_BYTE, data)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.REPEAT)
  },
  // screenshot-basic's exact texture: 1x1 RGB (three.js RGBFormat), i-params, then the f triple.
  'ssb-rgb': (gl) => {
    gl.texParameteri(T, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
    gl.texParameteri(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameteri(T, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
    gl.texParameteri(T, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1)
    gl.texImage2D(T, 0, gl.RGB, 1, 1, 0, gl.RGB, gl.UNSIGNED_BYTE, new Uint8Array([0, 0, 255]))
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.REPEAT)
  },
  // Only the WRAP_T calls, nothing else touches the parameters.
  'f-wrapT-only': (gl) => {
    gl.texImage2D(T, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, PLACEHOLDER)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.REPEAT)
    gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
  },
  // The sequence issued twice in a row (a first pass may only register the texture).
  'f-1x1-twice': (gl) => {
    gl.texImage2D(T, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, PLACEHOLDER)
    for (let pass = 0; pass < 2; pass++) {
      gl.texParameterf(T, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
      gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
      gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.MIRRORED_REPEAT)
      gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.REPEAT)
      gl.texParameterf(T, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
    }
  },
}

const VARIANTS = [
  { name: 'f-1x1-reset', kind: 'webgl', layout: 'tiny', recipe: 'f-1x1-reset' },
  { name: 'f-1x1-noreset', kind: 'webgl', layout: 'tiny', recipe: 'f-1x1-noreset' },
  { name: 'ssb-i-then-f', kind: 'webgl', layout: 'tiny', recipe: 'ssb-i-then-f' },
  { name: 'ssb-viewport', kind: 'webgl', layout: 'tiny', recipe: 'ssb-viewport' },
  { name: 'ssb-rgb', kind: 'webgl', layout: 'tiny', recipe: 'ssb-rgb' },
  { name: 'f-wrapT-only', kind: 'webgl', layout: 'tiny', recipe: 'f-wrapT-only' },
  { name: 'f-1x1-twice', kind: 'webgl', layout: 'tiny', recipe: 'f-1x1-twice' },
  { name: 'webgl2-f-1x1-reset', kind: 'webgl2', layout: 'tiny', recipe: 'f-1x1-reset' },
  { name: 'detached-f-1x1-reset', kind: 'webgl', layout: 'none', recipe: 'f-1x1-reset' },
  { name: 'fullscreen-f-1x1-reset', kind: 'webgl', layout: 'full', recipe: 'f-1x1-reset' },
  { name: 'delayed-draw-f-1x1-reset', kind: 'webgl', layout: 'tiny', recipe: 'f-1x1-reset', delayMs: 600 },
]

async function runVariant(v) {
  const result = { name: v.name }
  const { canvas, gl } = makeContext(v.kind, v.layout)
  if (!gl) {
    result.error = 'no context'
    if (canvas.parentNode) canvas.parentNode.removeChild(canvas)
    return result
  }
  try {
    const { program, buffer } = makeProgram(gl)
    const texture = gl.createTexture()
    gl.activeTexture(gl.TEXTURE0)
    gl.bindTexture(gl.TEXTURE_2D, texture)
    RECIPES[v.recipe](gl)
    if (v.delayMs) await sleep(v.delayMs)
    result.now = drawAndRead(gl, program, buffer, texture)
    await sleep(400)
    result.later = drawAndRead(gl, program, buffer, texture)
    result.glError = gl.getError()
  } catch (err) {
    result.error = String(err && err.message || err)
  }
  try {
    const lose = gl.getExtension('WEBGL_lose_context')
    if (lose) lose.loseContext()
  } catch (err) { /* gone already */ }
  if (canvas.parentNode) canvas.parentNode.removeChild(canvas)
  return result
}

let running = false

/** Runs every variant one after the other and posts one `variants` report. */
export async function runHookExperiments(trigger) {
  if (running) return
  running = true
  const results = []
  for (const v of VARIANTS) {
    // eslint-disable-next-line no-await-in-loop
    results.push(await runVariant(v))
  }
  running = false
  try {
    post('blur_diag', { reason: 'variants', trigger: trigger || 'auto', viewport: [window.innerWidth, window.innerHeight], results })
  } catch (err) { /* nothing to do */ }
  return results
}
