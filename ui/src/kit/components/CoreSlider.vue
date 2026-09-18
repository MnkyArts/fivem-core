<script setup>
// CoreSlider — a value on a track (DESIGN §37.5, Forms — choice).
// A real <input type="range"> painted through the ::-webkit-slider-* pseudo-elements; the fill is
// not an element but a two-stop gradient on the track, cut at `--core-slider-pct`, which is the
// only thing this component writes inline. `update:modelValue` fires while dragging and `change`
// once on release, so a caller can preview cheaply and commit expensively (a re-render of the ped,
// a server round trip). The gradient stop is a plain percentage, so the fill can sit up to half a
// thumb (5 px) away from the thumb's centre at the very ends — the price of the one-element track.
import { computed } from 'vue'
import { clamp, oneOf, toneClass, TONES, toPercent } from '../use.js'

const props = defineProps({
  min: { type: Number, default: 0 },
  max: { type: Number, default: 100 },
  step: { type: Number, default: 1 },
  /** Label voice caption over the track. */
  label: { type: String, default: '' },
  /** Show the current value at the right of the caption row. */
  showValue: { type: Boolean, default: false },
  /** `(value) => string` for the read-out — "Narrow", "1 920 x 1 080", "2.5x". */
  format: { type: Function, default: null },
  /** Appended to the read-out when there is no `format` ("%", " km/h"). */
  suffix: { type: String, default: '' },
  /** Caption under the left end of the track ("Narrow"). */
  minLabel: { type: String, default: '' },
  /** Caption under the right end of the track ("Wide"). */
  maxLabel: { type: String, default: '' },
  /** `true` = a mark per step while there are at most 20 of them; a number = that many marks. */
  ticks: { type: [Boolean, Number], default: false },
  tone: { type: String, default: 'accent', validator: oneOf(TONES) },
  disabled: { type: Boolean, default: false },
})

const emit = defineEmits(['change'])
const model = defineModel({ type: Number, default: 0 })

const value = computed(() => clamp(model.value, props.min, props.max))
const percent = computed(() => toPercent(value.value, props.min, props.max))

const text = computed(() => (props.format ? String(props.format(value.value)) : String(value.value) + props.suffix))

/** Marks are drawn as N children spread with space-between, so N is a count, not a position list. */
const marks = computed(() => {
  const span = props.max - props.min
  const step = props.step > 0 ? props.step : 1
  let count = 0
  if (props.ticks === true) {
    const steps = Math.round(span / step)
    count = steps >= 1 && steps <= 20 ? steps + 1 : 0
  } else if (typeof props.ticks === 'number' && Number.isFinite(props.ticks)) {
    count = Math.round(props.ticks)
  }
  if (count < 2) return []
  const out = []
  for (let i = 0; i < count; i += 1) out.push((i / (count - 1)) * 100)
  return out
})

function onInput(event) {
  model.value = Number(event.target.value)
}

function onChange(event) {
  emit('change', Number(event.target.value))
}
</script>

<template>
  <div
    class="core-slider"
    :class="[toneClass(tone), { 'is-disabled': disabled }]"
    :style="{ '--core-slider-pct': percent + '%' }"
  >
    <div v-if="label || showValue || $slots.value" class="core-slider__head">
      <span v-if="label" class="core-slider__label">{{ label }}</span>
      <span v-if="showValue || $slots.value" class="core-slider__value">
        <slot name="value" :value="value" :percent="percent">{{ text }}</slot>
      </span>
    </div>

    <div class="core-slider__rail">
      <input
        class="core-slider__input"
        type="range"
        :min="min"
        :max="max"
        :step="step"
        :value="value"
        :disabled="disabled"
        :aria-label="label || undefined"
        :aria-valuetext="text"
        @input="onInput"
        @change="onChange"
      >
      <div v-if="marks.length" class="core-slider__ticks" aria-hidden="true">
        <span
          v-for="(mark, i) in marks"
          :key="i"
          class="core-slider__tick"
          :class="{ 'is-passed': mark <= percent }"
        ></span>
      </div>
    </div>

    <div v-if="minLabel || maxLabel" class="core-slider__ends">
      <span>{{ minLabel }}</span>
      <span>{{ maxLabel }}</span>
    </div>
  </div>
</template>
