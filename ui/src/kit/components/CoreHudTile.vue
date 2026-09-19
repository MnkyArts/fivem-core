<script setup>
// CoreHudTile — the slanted dark tile that opens the vitals strip (DESIGN §39): the voice
// indicator next to the HEALTH and ARMOR plates. Same unit system as CoreVital
// (`font-size: var(--core-hud-unit, 24px)`, 1em = 100 px of the mockup) and the same 20° lean,
// but only the SHAPE is skewed — the glyph is a sibling, centred and upright, because a skewed
// mic reads as a broken one.
//
// `active` is "you are transmitting": a thick `fg` ring and a soft white glow. `dimmed` is the
// muted twin's 40 % glyph. Height follows `--core-hudtile-h` so a caller can put the tile next to
// `--solo` vitals (1.57em) without a prop for it. Click-through, like every HUD read-out.
import { computed } from 'vue'

const props = defineProps({
  /** Registry name or raw path — the glyph in the tile (`hud-mic`, `hud-mic-off`). */
  icon: { type: String, default: 'hud-mic' },
  /** Transmitting: the bright ring and the glow. */
  active: { type: Boolean, default: false },
  /** Muted / idle: the glyph drops to 40 %. */
  dimmed: { type: Boolean, default: false },
  /** Accessible name. Without one the tile is decoration and is hidden from the a11y tree. */
  label: { type: String, default: '' },
  /** `--core-hud-unit` for this tile: a number is px, a string is a CSS length. Omitted =
   *  inherit whatever an ancestor (the shell's strip) set. */
  unit: { type: [Number, String], default: null },
})

const rootClass = computed(() => ({ 'is-active': props.active, 'is-dimmed': props.dimmed }))

const rootStyle = computed(() => {
  const unit = props.unit
  if (unit === null || unit === undefined || unit === '') return null
  return { '--core-hud-unit': typeof unit === 'number' ? unit + 'px' : String(unit) }
})
</script>

<template>
  <div
    class="core-hudtile"
    :class="rootClass"
    :style="rootStyle"
    :role="label ? 'img' : null"
    :aria-label="label || null"
    :aria-hidden="label ? null : 'true'"
  >
    <div class="core-hudtile__shape"></div>
    <CoreIcon v-if="icon" :name="icon" size="lg" class="core-hudtile__icon" />
  </div>
</template>
