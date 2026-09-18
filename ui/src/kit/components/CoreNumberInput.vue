<script>
// CoreNumberInput — `[-] 12 [+]` (DESIGN §37.5, Forms — text).
// The model is ALWAYS a number: the field keeps its own text while it is being typed (so a half
// written "1" or "-" is not thrown away and nothing clamps mid-keystroke) and commits — parse,
// clamp, round to `precision` — on blur and on Enter. The buttons repeat while held (400 ms, then
// every 60 ms) and go disabled at the bounds, so a hold can never run past min/max.
export default { inheritAttrs: false }
</script>

<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { oneOf, SIZES } from '../use.js'

const ICON_PX = { sm: 14, md: 18, lg: 22 }
const HOLD_DELAY = 400
const HOLD_EVERY = 60

const props = defineProps({
  /** Lower bound. `null` = unbounded (and then the empty field falls back to 0). */
  min: { type: Number, default: null },
  /** Upper bound. `null` = unbounded. */
  max: { type: Number, default: null },
  step: { type: Number, default: 1 },
  /** Decimals kept on commit. `null` = as many as `step` has. */
  precision: { type: Number, default: null },
  /** Unit after the number (`L`, `%`, `KG`). */
  suffix: { type: String, default: '' },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  invalid: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  id: { type: String, default: '' },
  name: { type: String, default: '' },
})

const emit = defineEmits(['focus', 'blur'])
const model = defineModel({ type: Number, default: 0 })

const inputEl = ref(null)
const focused = ref(false)

const lo = computed(() => (Number.isFinite(props.min) ? props.min : -Infinity))
const hi = computed(() => (Number.isFinite(props.max) ? props.max : Infinity))
const fallback = computed(() => (Number.isFinite(props.min) ? props.min : 0))
const decimals = computed(() => {
  if (Number.isFinite(props.precision)) return Math.max(0, Math.round(props.precision))
  const parts = String(props.step).split('.')
  return parts.length > 1 ? parts[1].length : 0
})

const iconSize = computed(() => ICON_PX[props.size] || ICON_PX.md)
const value = computed(() => (Number.isFinite(model.value) ? model.value : fallback.value))
const atMin = computed(() => value.value <= lo.value)
const atMax = computed(() => value.value >= hi.value)

function shape (n) {
  const factor = Math.pow(10, decimals.value)
  const bounded = Math.min(Math.max(n, lo.value), hi.value)
  return Math.round(bounded * factor) / factor
}

const format = (n) => (decimals.value > 0 ? n.toFixed(decimals.value) : String(n))

const text = ref(format(value.value))
watch(value, (n) => {
  if (!focused.value) text.value = format(n)
})

/** Typing is free: only a parsable number is pushed to the model, unclamped, until commit(). */
function onInput (event) {
  text.value = event.target.value
  const n = Number(text.value)
  if (text.value.trim() !== '' && Number.isFinite(n)) model.value = n
}

function commit () {
  const n = Number(text.value)
  const next = text.value.trim() === '' || !Number.isFinite(n) ? shape(fallback.value) : shape(n)
  model.value = next
  text.value = format(next)
}

function bump (dir) {
  const next = shape(value.value + dir * (Number.isFinite(props.step) && props.step !== 0 ? props.step : 1))
  model.value = next
  text.value = format(next)
  return next
}

/* Press-and-hold. The repeat stops itself at the bound so a held button cannot spin forever, and
   the window-level pointerup catches the release outside the button (drag off, alt-tab). */
let delayTimer = null
let repeatTimer = null

function stopHold () {
  if (delayTimer) { clearTimeout(delayTimer); delayTimer = null }
  if (repeatTimer) { clearInterval(repeatTimer); repeatTimer = null }
  if (typeof window !== 'undefined') window.removeEventListener('pointerup', stopHold)
}

function startHold (dir) {
  if (props.disabled) return
  stopHold()
  bump(dir)
  if (typeof window !== 'undefined') window.addEventListener('pointerup', stopHold)
  delayTimer = setTimeout(() => {
    repeatTimer = setInterval(() => {
      if ((dir < 0 && atMin.value) || (dir > 0 && atMax.value)) stopHold()
      else bump(dir)
    }, HOLD_EVERY)
  }, HOLD_DELAY)
}

function onKeydown (event) {
  if (event.key === 'ArrowUp') { event.preventDefault(); bump(1) }
  else if (event.key === 'ArrowDown') { event.preventDefault(); bump(-1) }
  else if (event.key === 'Enter') commit()
}

function onBlur (event) {
  focused.value = false
  commit()
  emit('blur', event)
}

function focus () {
  if (inputEl.value) inputEl.value.focus()
}

onBeforeUnmount(stopHold)
defineExpose({ focus })
</script>

<template>
  <div
    class="core-number"
    :class="['core-number--' + size, { 'is-focused': focused, 'is-invalid': invalid, 'is-disabled': disabled }]"
  >
    <button
      type="button"
      class="core-number__btn core-number__btn--dec"
      aria-label="Decrease"
      tabindex="-1"
      :disabled="disabled || atMin"
      @pointerdown="startHold(-1)"
      @pointerup="stopHold"
      @pointerleave="stopHold"
      @blur="stopHold"
    >
      <CoreIcon name="minus" :size="iconSize" />
    </button>

    <div class="core-number__field">
      <input
        ref="inputEl"
        v-bind="$attrs"
        class="core-number__el"
        type="text"
        inputmode="decimal"
        autocomplete="off"
        role="spinbutton"
        :id="id || undefined"
        :name="name || undefined"
        :value="text"
        :disabled="disabled"
        :aria-valuenow="value"
        :aria-valuemin="Number.isFinite(min) ? min : undefined"
        :aria-valuemax="Number.isFinite(max) ? max : undefined"
        :aria-invalid="invalid ? 'true' : undefined"
        @input="onInput"
        @keydown="onKeydown"
        @focus="focused = true; emit('focus', $event)"
        @blur="onBlur"
      />
      <span v-if="suffix" class="core-number__suffix">{{ suffix }}</span>
    </div>

    <button
      type="button"
      class="core-number__btn core-number__btn--inc"
      aria-label="Increase"
      tabindex="-1"
      :disabled="disabled || atMax"
      @pointerdown="startHold(1)"
      @pointerup="stopHold"
      @pointerleave="stopHold"
      @blur="stopHold"
    >
      <CoreIcon name="plus" :size="iconSize" />
    </button>
  </div>
</template>
