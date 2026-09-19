<script setup>
// CoreVital — one plate of the vitals HUD (DESIGN §39): Liam's mockup as ONE parallelogram whose
// bottom slice is cut off and used as the food / drink bar. Everything is `em` over
// `--core-hud-unit` (1em = 100 px of the mockup, 24 px by default), so the whole strip scales
// with one number. That number is fixed px, not viewport-based: the rail and the progress panel
// are fixed px too, and a strip that grew with the screen would stop matching them.
//
// Three things are worth knowing before changing anything here:
//   * the value never becomes a width. It is published as the 0..1 custom property
//     `--core-vital-value` and the CSS clips the white fill with `clip-path: inset(...)` INSIDE
//     the skewed shape — a vertical clip edge in local space IS the parallelogram's own angle on
//     screen, which is why plate, bar and progress edges all lean by exactly the same 20°;
//   * the icon + label exist TWICE, pixel-identical: once on the dark track and once inside the
//     fill. A half-drained plate therefore shows a two-tone label split along the clip edge, and
//     the two copies must stay byte-for-byte the same markup;
//   * the change chunk of §39.3.1 shares the fill's clip TARGET — same `inset(...)`, same custom
//     property, same skewed box; only the transition durations differ, and the direction class
//     below is what picks them. It is transparent at rest because two anti-aliased edges resting
//     on one line would leave a coloured fringe along the fill's edge.
//
// It is a read-out on the game, never a target, so the root is click-through (§37.4).
import { computed, onBeforeUnmount, ref, watch } from 'vue'
import { METER_TONES, oneOf, toPercent, toneClass } from '../use.js'

const props = defineProps({
  /** Plate text, uppercased by the CSS (`Health`, `Armor`), and the a11y name of the vital. */
  label: { type: String, default: '' },
  /** Registry name or raw path — the plate glyph (`hud-heart`, `hud-shield`). */
  icon: { type: String, default: '' },
  /** Vital tone: `--tone` on the track, `--color-plate-<tone>` on the white fill. */
  tone: { type: String, default: 'health', validator: oneOf(METER_TONES) },
  value: { type: Number, default: 0 },
  max: { type: Number, default: 100 },
  /** Percent under which the GLYPH pulses. 0 switches the warning off; nothing else moves. */
  lowBelow: { type: Number, default: 25 },
  /** The stat in the cut-off slice (food / drink). `null` = no bar at all (`--solo`). */
  subValue: { type: Number, default: null },
  subMax: { type: Number, default: 100 },
  /** Registry name of the glyph under the bar (`hud-food`, `hud-drink`). */
  subIcon: { type: String, default: '' },
  /** The a11y name of the bar — the plate's own label says nothing about the stat under it. */
  subLabel: { type: String, default: '' },
  /** Bar percent under which fill and glyph turn warning. */
  subWarnBelow: { type: Number, default: 25 },
  /** …and under which they turn error and the glyph pulses. Wins over the warning. */
  subDangerBelow: { type: Number, default: 10 },
  /** `--core-hud-unit` for this component: a number is px, a string is a CSS length. Omitted =
   *  inherit whatever an ancestor (the shell's strip) set. */
  unit: { type: [Number, String], default: null },
})

const solo = computed(() => props.subValue === null || props.subValue === undefined)
const pct = computed(() => toPercent(props.value, 0, props.max))
const subPct = computed(() => (solo.value ? 0 : toPercent(props.subValue, 0, props.subMax)))

const isLow = computed(() => props.lowBelow > 0 && pct.value < props.lowBelow)
const isSubDanger = computed(() => !solo.value && subPct.value < props.subDangerBelow)
const isSubWarning = computed(() => !solo.value && !isSubDanger.value && subPct.value < props.subWarnBelow)

/** §39.3.1: how long a direction class survives its last change. Longer than the longest
 *  transition (0.65s), so the chunk only turns transparent once both edges are at rest. */
const CHANGE_CLEAR_MS = 900

const direction = ref('')
const subDirection = ref('')
let directionTimer = null
let subDirectionTimer = null

/** Watch the PERCENTAGE, not the prop: `max` moves the plate too, and the chunk has to follow
 *  what the clip path was given. Default (`pre`) flush on purpose — the class then lands in the
 *  SAME render as the new `--core-vital-value`, which is what makes the browser pick this
 *  direction's durations for this very change. No `immediate`: the first value never animates. */
watch(pct, (next, prev) => {
  direction.value = next < prev ? 'loss' : 'gain'
  if (directionTimer) clearTimeout(directionTimer)
  directionTimer = setTimeout(() => { directionTimer = null; direction.value = '' }, CHANGE_CLEAR_MS)
})

/** `null` while there is no bar at all, so a sub stat APPEARING (null -> number) or going away
 *  is not a change — an arriving `stats:set` would otherwise flash a full-width green chunk. */
watch(() => (solo.value ? null : subPct.value), (next, prev) => {
  if (next === null || prev === null) return
  subDirection.value = next < prev ? 'loss' : 'gain'
  if (subDirectionTimer) clearTimeout(subDirectionTimer)
  subDirectionTimer = setTimeout(() => { subDirectionTimer = null; subDirection.value = '' }, CHANGE_CLEAR_MS)
})

onBeforeUnmount(() => {
  if (directionTimer) clearTimeout(directionTimer)
  if (subDirectionTimer) clearTimeout(subDirectionTimer)
  directionTimer = null
  subDirectionTimer = null
})

const rootClass = computed(() => [
  toneClass(props.tone),
  {
    'core-vital--solo': solo.value,
    'is-low': isLow.value,
    'is-sub-warning': isSubWarning.value,
    'is-sub-danger': isSubDanger.value,
    'is-loss': direction.value === 'loss',
    'is-gain': direction.value === 'gain',
    'is-sub-loss': subDirection.value === 'loss',
    'is-sub-gain': subDirection.value === 'gain',
  },
])

/** 0-100 -> a 0..1 number with at most four decimals: the CSS multiplies it by 100 % again. */
const fraction = (n) => String(Math.round(n * 100) / 10000)

const rootStyle = computed(() => {
  const style = { '--core-vital-value': fraction(pct.value) }
  if (!solo.value) style['--core-vital-sub'] = fraction(subPct.value)
  const unit = props.unit
  if (unit !== null && unit !== undefined && unit !== '') {
    style['--core-hud-unit'] = typeof unit === 'number' ? unit + 'px' : String(unit)
  }
  return style
})
</script>

<template>
  <div
    class="core-vital"
    :class="rootClass"
    :style="rootStyle"
    role="progressbar"
    :aria-label="label || null"
    aria-valuemin="0"
    :aria-valuemax="max"
    :aria-valuenow="value"
  >
    <div class="core-vital__shape">
      <div class="core-vital__plate">
        <!-- The look ON THE TRACK: white label, the vital's dark-ground tone. -->
        <div class="core-vital__content">
          <CoreIcon v-if="icon" :name="icon" size="lg" class="core-vital__icon" />
          <span v-if="label" class="core-vital__label">{{ label }}</span>
        </div>
        <!-- §39.3.1: the loss / gain chunk. Under the fill, so only the span between the two
             edges shows — and over the track content, so it hides the label while it travels. -->
        <div class="core-vital__chunk" aria-hidden="true"></div>
        <!-- The same content again, inside the clipped white plate: ink label, plate tone. -->
        <div class="core-vital__fill" aria-hidden="true">
          <div class="core-vital__content">
            <CoreIcon v-if="icon" :name="icon" size="lg" class="core-vital__icon" />
            <span v-if="label" class="core-vital__label">{{ label }}</span>
          </div>
        </div>
      </div>

      <div
        v-if="!solo"
        class="core-vital__bar"
        role="progressbar"
        :aria-label="subLabel || null"
        aria-valuemin="0"
        :aria-valuemax="subMax"
        :aria-valuenow="subValue"
      >
        <div class="core-vital__subchunk" aria-hidden="true"></div>
        <div class="core-vital__subfill"></div>
      </div>
    </div>

    <CoreIcon v-if="!solo && subIcon" :name="subIcon" size="lg" class="core-vital__subicon" />
  </div>
</template>
