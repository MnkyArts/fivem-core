<script setup>
// CoreProgress — the linear meter of DESIGN §37.5 (Data — meters): the inventory capacity row of
// mockup 3, a segmented ammo plate, the thin coral XP bar of the player chip.
// Three decisions that are not obvious from the props: a threshold swaps the TONE CLASS rather
// than a colour, so a re-themed server still owns the palette; `segments` masks the TRACK, which
// carries the fill with it (css partial); and the `18.5 / 30.0` fraction only appears when the
// caller really passed a `max` — the prop has a default, so only the raw vnode can tell.
import { computed, getCurrentInstance, useSlots } from 'vue'
import { METER_TONES, oneOf, toPercent, toneClass } from '../use.js'

const props = defineProps({
  /** Where the bar stands, between `min` and `max`. */
  value: { type: Number, default: 0 },
  min: { type: Number, default: 0 },
  max: { type: Number, default: 100 },
  /** Accent, a semantic tone or one of the vitals (§37.2). */
  tone: { type: String, default: 'accent', validator: oneOf(METER_TONES) },
  /** Any CSS colour — wins over `tone` for the fill. */
  color: { type: String, default: '' },
  /** Track height: `xs` 2 | `sm` 4 | `md` 8 | `lg` 12 px. */
  size: { type: String, default: 'md', validator: oneOf(['xs', 'sm', 'md', 'lg']) },
  /** Caption in the label voice (slot `label` overrides it). */
  label: { type: String, default: '' },
  /** Registry name or raw path, drawn in the tone. */
  icon: { type: String, default: '' },
  /** Print the read-out (slot `value` overrides it). */
  showValue: { type: Boolean, default: false },
  /** A finished string that replaces the read-out entirely. */
  valueText: { type: String, default: '' },
  /** `(value, max) => string` — the read-out, when a plain number is not enough. */
  format: { type: Function, default: null },
  /** One row: glyph, caption, bar, value — the capacity bar of the mockup. */
  inline: { type: Boolean, default: false },
  /** Cut the bar into n cells with a 2 px gap (magazines, armour plates). */
  segments: { type: Number, default: 0 },
  /** A short fill sweeping the track: busy, with no measurable progress. */
  indeterminate: { type: Boolean, default: false },
  /** Percent thresholds: under them the bar wears the warning / danger tone. */
  warnBelow: { type: Number, default: 0 },
  dangerBelow: { type: Number, default: 0 },
})

const instance = getCurrentInstance()

const pct = computed(() => (props.indeterminate ? 0 : toPercent(props.value, props.min, props.max)))

const tone = computed(() => {
  if (!props.indeterminate) {
    if (props.dangerBelow > 0 && pct.value < props.dangerBelow) return 'danger'
    if (props.warnBelow > 0 && pct.value < props.warnBelow) return 'warning'
  }
  return props.tone
})

const cells = computed(() => {
  const n = Math.floor(Number(props.segments))
  return Number.isFinite(n) && n > 1 ? n : 0
})

const rootClass = computed(() => [
  'core-progress--' + props.size,
  toneClass(tone.value),
  {
    'core-progress--inline': props.inline,
    'is-segmented': cells.value > 1,
    'is-indeterminate': props.indeterminate,
  },
])

const rootStyle = computed(() => {
  const style = {}
  if (props.color) {
    style['--tone'] = props.color
    style['--core-progress-fill'] = props.color
  }
  if (cells.value > 1) style['--core-progress-cells'] = String(cells.value)
  return style
})

// Two decimals is under a tenth of a pixel on any bar the shell draws, and the CSSOM drops the
// trailing zeros anyway (`62%`, not `62.00%`) — which keeps the inspected DOM readable.
const fillStyle = computed(() => (props.indeterminate ? null : { width: Math.round(pct.value * 100) / 100 + '%' }))

/** Decimals a number is written with, capped at 2 — `18.5` and `30` both print as `18.5 / 30.0`. */
function decimalsOf (n) {
  const dot = String(n).indexOf('.')
  return dot === -1 ? 0 : Math.min(2, String(n).length - dot - 1)
}

// Not reactive by itself (a vnode's props are a plain object); every read happens inside the
// computed below, which re-runs whenever the value or the max it prints changes.
function maxWasPassed () {
  const raw = instance && instance.vnode ? instance.vnode.props : null
  return !!raw && raw.max !== undefined && raw.max !== null
}

/** `{ text, max }` — `max` is the dimmed `/ 30.0` half, empty unless a fraction is printed. */
const readout = computed(() => {
  if (props.valueText) return { text: props.valueText, max: '' }
  if (typeof props.format === 'function') return { text: String(props.format(props.value, props.max)), max: '' }
  if (!maxWasPassed()) return { text: String(props.value), max: '' }
  const digits = Math.max(decimalsOf(props.value), decimalsOf(props.max))
  return { text: Number(props.value).toFixed(digits), max: ' / ' + Number(props.max).toFixed(digits) }
})

const slots = useSlots()
const hasValue = computed(() => props.showValue || !!slots.value)
const hasLabel = computed(() => !!props.label || !!slots.label)
const hasHead = computed(() => !props.inline && (hasLabel.value || hasValue.value || !!props.icon))
</script>

<template>
  <div class="core-progress" :class="rootClass" :style="rootStyle">
    <div v-if="hasHead" class="core-progress__head">
      <span class="core-progress__caption">
        <CoreIcon v-if="icon" :name="icon" size="sm" class="core-progress__icon" />
        <span v-if="hasLabel" class="core-progress__label"><slot name="label">{{ label }}</slot></span>
      </span>
      <span v-if="hasValue" class="core-progress__value">
        <slot name="value">{{ readout.text }}<span v-if="readout.max" class="core-progress__max">{{ readout.max }}</span></slot>
      </span>
    </div>

    <CoreIcon v-if="inline && icon" :name="icon" size="lg" class="core-progress__icon" />
    <span v-if="inline && hasLabel" class="core-progress__label"><slot name="label">{{ label }}</slot></span>

    <div
      class="core-progress__track"
      role="progressbar"
      :aria-valuemin="min"
      :aria-valuemax="max"
      :aria-valuenow="indeterminate ? null : value"
      :aria-label="label || null"
    >
      <div class="core-progress__fill" :style="fillStyle"></div>
    </div>

    <span v-if="inline && hasValue" class="core-progress__value">
      <slot name="value">{{ readout.text }}<span v-if="readout.max" class="core-progress__max">{{ readout.max }}</span></slot>
    </span>
  </div>
</template>
