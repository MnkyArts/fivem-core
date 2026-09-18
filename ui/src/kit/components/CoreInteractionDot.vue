<script>
// CoreInteractionDot — the world marker that says "you can interact here" (DESIGN §37.5, Game).
// Idle it is a ring around a white core on a world point; `focused` (the player is LOOKING at it)
// collapses the ring and puts a solid CoreKey on the SAME point while the band opens to `side`.
// The cap is the in-flow content of `__anchor`, so the centre never moves however wide the cap
// gets. Click-through, no emits: a HUD element that is painted, never clicked (§37.4).
// Module scope: the lock glyph's px size per cap size — an outline cap replaces the letter when
// the interaction is locked or out of reach, and a glyph has to be told a number.
const LOCK_PX = { sm: 12, md: 15, lg: 18 }
</script>

<script setup>
import { computed } from 'vue'
import { SIZES, METER_TONES, clamp, oneOf, toneClass } from '../use.js'

const props = defineProps({
  /** The player is looking at it: the dot becomes the key and the band opens. */
  focused: { type: Boolean, default: false },
  /** `'E'`, or `['SHIFT', 'E']` for a combination. */
  keys: { type: [String, Number, Array], default: 'E' },
  /** The action, in display voice. */
  label: { type: String, default: '' },
  /** Registry name or raw path, drawn in the band next to the label. */
  icon: { type: String, default: '' },
  /** Second line, sans, dim — the cost, the cooldown, why it is blocked. */
  description: { type: String, default: '' },
  /** 0-1 hold-to-interact, drawn along the bottom of the cap by CoreKey. */
  progress: { type: Number, default: 0 },
  /** Locked or out of reach: greyed out, and the focused cap becomes an outline lock. */
  disabled: { type: Boolean, default: false },
  /** Colour of the attention ring. */
  tone: { type: String, default: 'accent', validator: oneOf(METER_TONES) },
  /** Dot 10 / 14 / 18 px, cap sm / md / lg. */
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** CSS px from the left of the positioned parent. Only with `y` does it place the root. */
  x: { type: Number, default: null },
  /** CSS px from the top. Without both, the root is a 0 x 0 anchor the caller places. */
  y: { type: Number, default: null },
  /** Which way the band opens; `left` for a dot near the right screen edge. */
  side: { type: String, default: 'right', validator: oneOf(['right', 'left']) },
  /** A slow attention ring while idle. */
  pulse: { type: Boolean, default: true },
  /** Extra actions under the main band, `[{ keys, label, icon?, disabled? }]`. */
  options: { type: Array, default: () => [] },
})

const held = computed(() => clamp(Number(props.progress) || 0, 0, 1))

/** `keys` in every shape the prop accepts, as a list of cap labels. */
function capsOf (value) {
  const list = Array.isArray(value) ? value : [value]
  const out = []
  for (let i = 0; i < list.length; i += 1) {
    const cap = list[i]
    if (cap === '' || cap === null || cap === undefined) continue
    out.push(String(cap))
  }
  return out
}

const caps = computed(() => capsOf(props.keys))
const lockPx = computed(() => LOCK_PX[props.size] || LOCK_PX.md)

const optionList = computed(() => {
  const list = Array.isArray(props.options) ? props.options : []
  const out = []
  for (let i = 0; i < list.length; i += 1) {
    const item = list[i]
    if (!item || typeof item !== 'object') continue
    out.push({
      caps: capsOf(item.keys),
      label: item.label === undefined || item.label === null ? '' : String(item.label),
      icon: item.icon || '',
      disabled: Boolean(item.disabled),
    })
  }
  return out
})

// A pulse would only fight the cap once the band is open, and a locked marker never asks for
// attention in the first place.
const pulsing = computed(() => props.pulse && !props.focused && !props.disabled)

const rootClass = computed(() => [
  'core-interaction-dot',
  'core-interaction-dot--' + props.size,
  'core-interaction-dot--' + props.side,
  toneClass(props.tone),
  {
    'is-focused': props.focused,
    'is-disabled': props.disabled,
    'has-progress': held.value > 0,
    'is-pulse': pulsing.value,
  },
])

// Both coordinates or none: one of them alone would pin the root to an edge it was never meant
// to touch, so the anchor form (the CSS default, `position: relative`) wins.
const placed = computed(() => Number.isFinite(Number(props.x)) && Number.isFinite(Number(props.y))
  && props.x !== null && props.y !== null)

const rootStyle = computed(() => (placed.value
  ? { position: 'absolute', left: Number(props.x) + 'px', top: Number(props.y) + 'px' }
  : null))
</script>

<template>
  <div :class="rootClass" :style="rootStyle">
    <span class="core-interaction-dot__anchor">
      <span class="core-interaction-dot__ring"></span>
      <span v-if="pulsing" class="core-interaction-dot__pulse"></span>
      <span class="core-interaction-dot__dot"></span>

      <span class="core-interaction-dot__cap">
        <CoreKey v-if="disabled" variant="outline" :size="size">
          <CoreIcon name="lock" :size="lockPx" />
        </CoreKey>
        <CoreKey
          v-for="(cap, i) in (disabled ? [] : caps)"
          :key="cap + '|' + i"
          :label="cap"
          :size="size"
          :progress="held"
        />
      </span>

      <span class="core-interaction-dot__band">
        <slot>
          <CoreIcon v-if="icon" class="core-interaction-dot__icon" :name="icon" :size="18" />
          <span class="core-interaction-dot__label">{{ label }}</span>
          <span v-if="description" class="core-interaction-dot__description">{{ description }}</span>
        </slot>

        <span v-if="optionList.length" class="core-interaction-dot__options">
          <span
            v-for="(option, i) in optionList"
            :key="i"
            class="core-interaction-dot__option"
            :class="{ 'is-disabled': option.disabled }"
          >
            <CoreKey v-for="(cap, j) in option.caps" :key="j" :label="cap" size="sm" />
            <CoreIcon v-if="option.icon" :name="option.icon" :size="16" />
            {{ option.label }}
          </span>
        </span>
      </span>
    </span>
  </div>
</template>
