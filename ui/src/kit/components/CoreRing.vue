<script setup>
// CoreRing — radial progress (DESIGN §37.5, Data — meters): a timer, a skill wheel, a compact
// vital. The arc is one circle with `stroke-dasharray` and a shrinking `stroke-dashoffset`; it
// starts at 12 o'clock through the SVG `transform` ATTRIBUTE on that circle, never a CSS transform
// (Chromium 103 drops the individual transform properties a utility would emit — §37.4).
// The centre is a slot: a value in the display voice by default, an icon with `icon`.
import { computed } from 'vue'
import { METER_TONES, oneOf, toPercent, toneClass } from '../use.js'

const props = defineProps({
  /** Where the arc stands, between 0 and `max`. */
  value: { type: Number, default: 0 },
  max: { type: Number, default: 100 },
  /** Outer diameter in px. */
  size: { type: Number, default: 48 },
  /** Stroke width of both the well and the arc, in px. */
  thickness: { type: Number, default: 4 },
  /** Accent, a semantic tone or one of the vitals (§37.2). */
  tone: { type: String, default: 'accent', validator: oneOf(METER_TONES) },
  /** Any CSS colour — wins over `tone` for the arc. */
  color: { type: String, default: '' },
  /** Registry name or raw path, drawn in the centre instead of the value. */
  icon: { type: String, default: '' },
})

const box = computed(() => Math.max(16, Number(props.size) || 48))
const half = computed(() => box.value / 2)
const stroke = computed(() => {
  const t = Number(props.thickness) || 4
  return Math.max(1, Math.min(half.value - 1, t))
})
const radius = computed(() => (box.value - stroke.value) / 2)
const circumference = computed(() => 2 * Math.PI * radius.value)

const pct = computed(() => toPercent(props.value, 0, props.max))
const offset = computed(() => circumference.value * (1 - pct.value / 100))

const viewBox = computed(() => '0 0 ' + box.value + ' ' + box.value)
// Built here, not in the template: `rotate(...)` spelled as a utility-shaped token in markup is
// exactly what the kit lint forbids, and the value belongs to the geometry anyway.
const upright = computed(() => 'rotate(-90 ' + half.value + ' ' + half.value + ')')

const rootClass = computed(() => toneClass(props.tone))
const rootStyle = computed(() => (props.color ? { '--tone': props.color } : null))

/** The centre read-out: the raw value, with at most one decimal so a timer does not jitter. */
const text = computed(() => String(Number(Number(props.value).toFixed(1))))
const valueStyle = computed(() => ({ fontSize: Math.max(10, Math.round(box.value * 0.32)) + 'px' }))
const iconSize = computed(() => Math.max(12, Math.round(box.value * 0.42)))
</script>

<template>
  <div
    class="core-ring"
    :class="rootClass"
    :style="rootStyle"
    role="progressbar"
    aria-valuemin="0"
    :aria-valuemax="max"
    :aria-valuenow="value"
  >
    <svg class="core-ring__svg" :width="box" :height="box" :viewBox="viewBox" aria-hidden="true" focusable="false">
      <circle class="core-ring__track" :cx="half" :cy="half" :r="radius" :stroke-width="stroke" />
      <circle
        class="core-ring__fill"
        :cx="half"
        :cy="half"
        :r="radius"
        :stroke-width="stroke"
        :stroke-dasharray="circumference"
        :stroke-dashoffset="offset"
        :transform="upright"
      />
    </svg>

    <div class="core-ring__center">
      <slot>
        <CoreIcon v-if="icon" :name="icon" :size="iconSize" />
        <span v-else class="core-ring__value" :style="valueStyle">{{ text }}</span>
      </slot>
    </div>
  </div>
</template>
