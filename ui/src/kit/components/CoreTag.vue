<script setup>
// CoreTag — small label chip (DESIGN §37.5, Data — display).
// `rarity` wins over `tone`: both only define --tone / --tone-rgb, so the rarity class simply comes
// last on the root. `variant="dark" size="lg"` is the HUD clock chip of mockup 2. A plain tag is a
// label and stays click-through; only the optional remove button takes the mouse back.
import { computed } from 'vue'
import { RARITIES, TONES, oneOf, rarityClass, toneClass } from '../use.js'

const ICON_SIZE = { sm: 14, md: 16, lg: 18 }

const props = defineProps({
  /** The chip text. The default slot replaces it. */
  label: { type: [String, Number], default: '' },
  /** Registry name or raw path data, drawn before the label. */
  icon: { type: String, default: '' },
  /** One of §37.4's six tones. */
  tone: { type: String, default: 'neutral', validator: oneOf(TONES) },
  /** An item rarity — wins over `tone`. */
  rarity: { type: String, default: '', validator: (v) => v === '' || RARITIES.indexOf(v) !== -1 },
  /** `soft` (14 % fill), `solid`, `outline`, `dark` (the HUD plate). */
  variant: { type: String, default: 'soft', validator: oneOf(['soft', 'solid', 'outline', 'dark']) },
  /** 20 / 24 / 30 px high. */
  size: { type: String, default: 'md', validator: oneOf(['sm', 'md', 'lg']) },
  /** Adds the ✕ button that emits `remove`. */
  removable: { type: Boolean, default: false },
})

const emit = defineEmits(['remove'])

const rootClass = computed(() => [
  'core-tag',
  'core-tag--' + props.variant,
  'core-tag--' + props.size,
  rarityClass(props.rarity) || toneClass(props.tone),
])

const iconSize = computed(() => ICON_SIZE[props.size] || ICON_SIZE.md)
</script>

<template>
  <span :class="rootClass">
    <CoreIcon v-if="icon" class="core-tag__icon" :name="icon" :size="iconSize" />
    <span class="core-tag__label"><slot>{{ label }}</slot></span>
    <button
      v-if="removable"
      class="core-tag__remove"
      type="button"
      :aria-label="'Remove ' + (label || 'tag')"
      @click.stop="emit('remove')"
    >
      <CoreIcon name="close" :size="12" />
    </button>
  </span>
</template>
