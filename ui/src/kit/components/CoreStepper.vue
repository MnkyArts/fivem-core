<script setup>
// CoreStepper — the `‹ value ›` cycler (DESIGN §37.5, Navigation), in the shared box look.
//
// Two modes off one prop set: pass `items` and it cycles their values (skipping disabled ones and
// showing the item's label); leave `items` empty and it is a number between `min` and `max`. The
// centre is a `role="spinbutton"` so ←/→ work wherever the focus sits inside the box, and the
// chevrons disable themselves at the ends unless `loop`. The chevrons are deliberately OUT of the
// tab order (the ARIA spinbutton pattern): one control in a settings column is one Tab stop, and
// the arrow keys already reach both directions.
// Numbers are re-rounded after every step: 0.1 + 0.2 must not print as 0.30000000000000004.
import { computed } from 'vue'
import { SIZES, oneOf, normalizeItems, nextEnabledIndex, clamp } from '../use.js'

const ICON_PX = { sm: 16, md: 18, lg: 22 }

const props = defineProps({
  /** `[{ value, label, disabled? }]` — present: the stepper cycles items, not numbers. */
  items: { type: Array, default: () => [] },
  /** Numeric mode bounds and increment. */
  min: { type: Number, default: 0 },
  max: { type: Number, default: 100 },
  step: { type: Number, default: 1 },
  /** Wrap around the ends instead of stopping (and disabling the chevron). */
  loop: { type: Boolean, default: false },
  /** `(value, item) => string` for the centre label (units, percentages, a lookup). */
  format: { type: Function, default: null },
  /** Print `3 / 24` after the label in `fg-faint`. */
  showCount: { type: Boolean, default: false },
  /** Fill the width of the row it sits in. */
  block: { type: Boolean, default: false },
  /** Box height `--core-h-sm|md|lg` (30 / 40 / 52 px); the chevrons stay square. */
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  disabled: { type: Boolean, default: false },
})

const model = defineModel()

const list = computed(() => normalizeItems(props.items))
const isItems = computed(() => list.value.length > 0)

const index = computed(() => {
  if (!isItems.value) return -1
  const i = list.value.findIndex((item) => item.value === model.value)
  return i === -1 ? list.value.findIndex((item) => !item.disabled) : i
})
const item = computed(() => (index.value >= 0 ? list.value[index.value] : null))
const number = computed(() => clamp(model.value === undefined || model.value === null ? props.min : model.value, props.min, props.max))
const value = computed(() => (isItems.value ? (item.value ? item.value.value : undefined) : number.value))

const text = computed(() => {
  if (typeof props.format === 'function') return String(props.format(value.value, item.value))
  if (isItems.value) return item.value ? String(item.value.label) : ''
  return String(number.value)
})

const countText = computed(() => {
  if (!props.showCount) return ''
  if (isItems.value) return (index.value + 1) + ' / ' + list.value.length
  return number.value + ' / ' + props.max
})

const rootClass = computed(() => [
  'core-stepper--' + props.size,
  { 'core-stepper--block': props.block, 'is-disabled': props.disabled },
])
const iconPx = computed(() => ICON_PX[props.size] || ICON_PX.md)

const canStep = (dir) => {
  if (props.disabled) return false
  if (props.loop) return true
  if (isItems.value) return nextEnabledIndex(list.value, index.value, dir, false) !== index.value
  return dir < 0 ? number.value > props.min : number.value < props.max
}
const canPrev = computed(() => canStep(-1))
const canNext = computed(() => canStep(1))

/** Float steps drift (0.1 + 0.2); 6 decimals is past anything a game setting needs. */
const tidy = (n) => Number(Number(n).toFixed(6))

function stepBy (dir) {
  if (props.disabled) return
  if (isItems.value) {
    const next = nextEnabledIndex(list.value, index.value, dir, props.loop)
    if (next === index.value || next < 0) return
    model.value = list.value[next].value
    return
  }
  const size = Number(props.step) || 1
  let next = tidy(number.value + dir * size)
  if (next > props.max) next = props.loop ? props.min : props.max
  if (next < props.min) next = props.loop ? props.max : props.min
  if (next === number.value) return
  model.value = next
}

function jump (dir) {
  if (props.disabled) return
  if (isItems.value) {
    const next = nextEnabledIndex(list.value, dir < 0 ? list.value.length : -1, dir, false)
    if (next < 0 || next === index.value) return
    model.value = list.value[next].value
    return
  }
  model.value = dir < 0 ? props.max : props.min
}

function onKeydown (event) {
  const key = event.key
  if (key === 'ArrowRight' || key === 'ArrowUp') stepBy(1)
  else if (key === 'ArrowLeft' || key === 'ArrowDown') stepBy(-1)
  else if (key === 'Home') jump(1)
  else if (key === 'End') jump(-1)
  else return
  event.preventDefault()
}
</script>

<template>
  <div class="core-stepper" :class="rootClass" @keydown="onKeydown">
    <button
      type="button"
      class="core-stepper__btn core-stepper__btn--prev"
      :disabled="!canPrev"
      aria-label="Previous value"
      tabindex="-1"
      @click="stepBy(-1)"
    >
      <CoreIcon name="chevron-left" :size="iconPx" />
    </button>

    <div
      class="core-stepper__value"
      role="spinbutton"
      :tabindex="disabled ? -1 : 0"
      :aria-valuenow="isItems ? index + 1 : number"
      :aria-valuemin="isItems ? 1 : min"
      :aria-valuemax="isItems ? list.length : max"
      :aria-valuetext="text"
      :aria-disabled="disabled ? 'true' : null"
    >
      <slot :value="value" :item="item">
        <span class="core-stepper__label">{{ text }}</span>
      </slot>
      <span v-if="countText" class="core-stepper__count">{{ countText }}</span>
    </div>

    <button
      type="button"
      class="core-stepper__btn core-stepper__btn--next"
      :disabled="!canNext"
      aria-label="Next value"
      tabindex="-1"
      @click="stepBy(1)"
    >
      <CoreIcon name="chevron-right" :size="iconPx" />
    </button>
  </div>
</template>
