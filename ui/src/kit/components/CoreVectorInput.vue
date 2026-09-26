<script>
// Module scope: the kit's own clipboard. FiveM's CEF runs off-screen, and whether
// navigator.clipboard may read there depends on the build — so a copy is ALWAYS kept here too and
// a paste falls back to it. Copy one vector input, paste into another, whatever the browser allows.
let kitClipboard = ''
</script>

<script setup>
// CoreVectorInput — `{ x, y, z }` as three CoreNumberInputs (DESIGN §53, §37.5 Forms — text).
// One shared `step` / `precision`, per-axis caps in the axis colours (X red, Y green, Z blue — the
// editor gizmo's convention, drawn with the error / success / info tokens so a re-theme follows),
// and copy / paste of the whole vector: `x, y, z` text, `vector3(x, y, z)`, `{ x = …, y = … }` Lua
// tables and JSON all parse. A paste (Ctrl+V) into any of the three fields that holds a whole
// vector fills all three instead of landing as text in one. `rotation` switches the suffix to `°`.
import { computed, nextTick } from 'vue'
import { oneOf, SIZES } from '../use.js'

const AXES = ['x', 'y', 'z']

const props = defineProps({
  step: { type: Number, default: 0.01 },
  /** Decimals kept on commit. `null` = as many as `step` has. */
  precision: { type: Number, default: null },
  /** Lower bound: one number for every axis or `{ x, y, z }`. `null` = unbounded. */
  min: { type: [Number, Object], default: null },
  /** Upper bound: one number for every axis or `{ x, y, z }`. `null` = unbounded. */
  max: { type: [Number, Object], default: null },
  /** Axis captions. */
  labels: { type: Array, default: () => ['X', 'Y', 'Z'] },
  /** Paint the axis caps in the gizmo colours; `false` keeps them neutral. */
  axisColors: { type: Boolean, default: true },
  /** Degrees: the suffix becomes `°` (a `suffix` still wins). */
  rotation: { type: Boolean, default: false },
  suffix: { type: String, default: '' },
  /** Show the copy / paste buttons. */
  copyable: { type: Boolean, default: true },
  size: { type: String, default: 'sm', validator: oneOf(SIZES) },
  invalid: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  id: { type: String, default: '' },
})

const emit = defineEmits(['copy', 'paste'])
const model = defineModel({ type: Object, default: () => ({ x: 0, y: 0, z: 0 }) })

const vec = computed(() => {
  const v = model.value && typeof model.value === 'object' ? model.value : {}
  return { x: Number(v.x) || 0, y: Number(v.y) || 0, z: Number(v.z) || 0 }
})
const bound = (b, axis) => {
  if (b === null || b === undefined) return null
  if (typeof b === 'number') return Number.isFinite(b) ? b : null
  return Number.isFinite(b[axis]) ? b[axis] : null
}
const unit = computed(() => props.suffix || (props.rotation ? '°' : ''))
const decimals = computed(() => {
  if (Number.isFinite(props.precision)) return Math.max(0, Math.round(props.precision))
  const parts = String(props.step).split('.')
  return parts.length > 1 ? parts[1].length : 0
})

function setAxis (axis, n) {
  model.value = Object.assign({}, vec.value, { [axis]: n })
}

/**
 * Reads a vector out of clipboard text: `1, 2, 3` · `vector3(1, 2, 3)` · `{ x = 1, y = 2, z = 3 }` ·
 * `{"x":1,"y":2,"z":3}`. Returns null when the text does not hold exactly three numbers.
 * @param {string} text
 * @returns {{x:number,y:number,z:number}|null}
 */
function parseVector (text) {
  const s = String(text || '')
  const named = {}
  const re = /["']?([xyz])["']?\s*[=:]\s*(-?\d+(?:\.\d+)?(?:e[-+]?\d+)?)/gi
  let m = re.exec(s)
  while (m) { named[m[1].toLowerCase()] = Number(m[2]); m = re.exec(s) }
  if (AXES.every((a) => Number.isFinite(named[a]))) return { x: named.x, y: named.y, z: named.z }
  const nums = s.replace(/vector3|vec3/gi, '').match(/-?\d+(?:\.\d+)?(?:e[-+]?\d+)?/gi)
  if (!nums || nums.length !== 3) return null
  const [x, y, z] = nums.map(Number)
  return [x, y, z].every(Number.isFinite) ? { x, y, z } : null
}

/** Clamps and rounds a pasted vector exactly like a committed field would. */
function shape (v) {
  const f = Math.pow(10, decimals.value)
  const out = {}
  for (const a of AXES) {
    let n = v[a]
    const lo = bound(props.min, a)
    const hi = bound(props.max, a)
    if (lo !== null && n < lo) n = lo
    if (hi !== null && n > hi) n = hi
    out[a] = Math.round(n * f) / f
  }
  return out
}

const asText = () => AXES.map((a) => vec.value[a].toFixed(decimals.value)).join(', ')

function copy () {
  const text = asText()
  kitClipboard = text
  // Fire and forget: a browser that refuses (or never answers) must not hold up the copy.
  try {
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).catch(() => {})
  } catch (e) { /* the kit clipboard above still holds it */ }
  emit('copy', text)
}

function apply (text) {
  const v = parseVector(text)
  if (!v) return false
  const next = shape(v)
  model.value = next
  emit('paste', next)
  return true
}

/** Browser clipboard first, raced against 250 ms — a permission prompt the off-screen CEF cannot
 *  show would otherwise leave the promise pending forever — then the kit's own clipboard. */
async function paste () {
  if (props.disabled) return
  let text = ''
  try {
    if (navigator.clipboard && navigator.clipboard.readText) {
      text = await Promise.race([
        navigator.clipboard.readText(),
        new Promise((resolve) => setTimeout(() => resolve(''), 250)),
      ])
    }
  } catch (e) { text = '' }
  if (!apply(text)) apply(kitClipboard)
}

/** Ctrl+V of a whole vector into any field fills all three. The field that has focus keeps its
 *  own TEXT until it commits (CoreNumberInput), so it is handed its new number as an input event —
 *  otherwise its blur would commit the old text over the pasted axis. */
function onPaste (event) {
  if (props.disabled) return
  const text = event.clipboardData ? event.clipboardData.getData('text') : ''
  if (!parseVector(text) || !apply(text)) return
  event.preventDefault()
  const target = event.target
  const cell = target && target.closest ? target.closest('[data-axis]') : null
  if (!cell || target.tagName !== 'INPUT') return
  const axis = cell.getAttribute('data-axis')
  const n = shape(parseVector(text))[axis].toFixed(decimals.value)
  // After the tick: the pasted model has to come back through the parent's v-model first (§37.4),
  // or this field's own update would merge its axis into the STALE vector and undo the paste.
  nextTick(() => {
    target.value = n
    target.dispatchEvent(new Event('input', { bubbles: true }))
  })
}

defineExpose({ copy, paste, parseVector })
</script>

<template>
  <div
    class="core-vector"
    :class="['core-vector--' + size, { 'has-axis-colors': axisColors, 'is-disabled': disabled, 'is-invalid': invalid }]"
    role="group"
    @paste="onPaste"
  >
    <div v-for="(axis, i) in AXES" :key="axis" class="core-vector__cell" :class="'core-vector__cell--' + axis" :data-axis="axis">
      <span class="core-vector__axis" aria-hidden="true">{{ labels[i] || axis.toUpperCase() }}</span>
      <CoreNumberInput
        :model-value="vec[axis]"
        :id="id && i === 0 ? id : undefined"
        :aria-label="labels[i] || axis.toUpperCase()"
        :step="step"
        :precision="precision === null ? undefined : precision"
        :min="bound(min, axis)"
        :max="bound(max, axis)"
        :suffix="unit"
        :size="size"
        :invalid="invalid"
        :disabled="disabled"
        @update:model-value="(n) => setAxis(axis, n)"
      />
    </div>
    <div v-if="copyable" class="core-vector__actions">
      <CoreIconButton icon="copy" label="Copy" variant="ghost" :size="size" :disabled="disabled" @click="copy" />
      <CoreIconButton icon="clipboard" label="Paste" variant="ghost" :size="size" :disabled="disabled" @click="paste" />
    </div>
  </div>
</template>
