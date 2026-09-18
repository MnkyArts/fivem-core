<script setup>
// CoreBackground — the scrim between the game and a full screen (DESIGN §37.5, Surfaces).
// Absolute, click-through and z 0, so it fills the page layer (or any positioned box in a story)
// without ever swallowing a click. `dim` is one number that every variant reads through
// `--core-bg-a`, which is why `left` and `vignette` darken with the same prop; `fade` is the same
// idea for how far the directional gradients travel (`--core-bg-fade`).
// Layer order: picture, scrim, pattern, then whatever the caller adds through the default slot.
import { computed } from 'vue'
import { oneOf, clamp, blurAttr } from '../use.js'

const props = defineProps({
  /** `left` is the main menu, `vignette` the default frame, `bars` the cinematic bands. */
  variant: {
    type: String,
    default: 'vignette',
    validator: oneOf(['scrim', 'left', 'right', 'top', 'bottom', 'bars', 'vignette', 'solid', 'none']),
  },
  /** Scrim strength 0–1. Unset keeps the variant's own value (0.62–0.94). */
  dim: { type: [Number, String], default: null },
  /**
   * How far across the box `top`/`bottom`/`left`/`right` reach transparent, as a fraction (0–1) —
   * `0.3` dissolves a header strip over its own height. Unset keeps the variant's own value
   * (0.52, or 0.62 for left/right, which is the main menu of §37.5).
   */
  fade: { type: [Number, String], default: null },
  /** A picture under the scrim — key art, a map, a blurred still. */
  image: { type: String, default: '' },
  /**
   * How the picture is framed inside the page (`background-position`): `'center 30%'`,
   * `'right center'`, … The image always covers, so this is what keeps a 4:3 key art's subject in
   * view on a 16:9 screen instead of cropping it out.
   */
  position: { type: String, default: 'center' },
  /** `grid` lays a 40 px hairline grid over the scrim. */
  pattern: { type: String, default: 'none', validator: oneOf(['none', 'grid']) },
  /** Glass: the blurred copy of the game behind the whole page (§32, one per page). */
  blur: { type: [Boolean, Number, String], default: false },
})

// Both knobs are left UNSET when the caller says nothing, so each variant keeps the value the
// catalogue documents for it instead of every variant collapsing onto one default.
const rootStyle = computed(() => {
  const style = {}
  if (props.dim !== null && props.dim !== '') style['--core-bg-a'] = String(clamp(props.dim, 0, 1))
  if (props.fade !== null && props.fade !== '') style['--core-bg-fade'] = String(clamp(props.fade, 0, 1))
  return Object.keys(style).length ? style : null
})

const imageStyle = computed(() => (props.image
  ? { backgroundImage: 'url(' + props.image + ')', backgroundPosition: props.position || 'center' }
  : null))
</script>

<template>
  <div
    class="core-bg"
    :class="'core-bg--' + variant"
    :style="rootStyle"
    aria-hidden="true"
    v-bind="blurAttr(blur)"
  >
    <div v-if="image" class="core-bg__image" :style="imageStyle"></div>
    <div v-if="variant !== 'none'" class="core-bg__scrim"></div>
    <div v-if="pattern === 'grid'" class="core-bg__pattern"></div>
    <slot />
  </div>
</template>
