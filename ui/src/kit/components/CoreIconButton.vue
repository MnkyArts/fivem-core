<script>
// CoreIconButton — a square, icon-only CoreButton (DESIGN §37.5, Actions).
// Module scope: the glyph size per button size — one step larger than CoreButton's, because an
// icon alone has to carry the whole box. `label` is mandatory in spirit: it is the only accessible
// name the button has, and it doubles as the native tooltip. The variant list and `fade` match
// CoreButton one for one: both wear the same fills, from the same rules in css/actions.css.
const ICON_PX = { sm: 16, md: 20, lg: 24 }
const VARIANTS = ['secondary', 'ghost', 'primary', 'danger', 'success']
</script>

<script setup>
import { computed } from 'vue'
import { SIZES, oneOf } from '../use.js'

const props = defineProps({
  /** Registry name or raw path. The default slot replaces it with any glyph. */
  icon: { type: String, required: true },
  /** `aria-label` and `title` — an icon button has no text to read. */
  label: { type: String, default: '' },
  variant: { type: String, default: 'secondary', validator: oneOf(VARIANTS) },
  /** Primary only, exactly as on CoreButton: the fading accent gradient. */
  fade: { type: Boolean, default: false },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** Circular instead of the 4 px radius. */
  round: { type: Boolean, default: false },
  /** Toggle-on. */
  active: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
})

const emit = defineEmits(['click'])

const iconPx = computed(() => ICON_PX[props.size] || ICON_PX.md)

function onClick (event) {
  if (props.disabled) {
    event.preventDefault()
    event.stopPropagation()
    return
  }
  emit('click', event)
}
</script>

<template>
  <button
    class="core-iconbtn"
    :class="[
      'core-iconbtn--' + variant,
      'core-iconbtn--' + size,
      {
        'is-fade': fade && variant === 'primary',
        'is-round': round,
        'is-active': active,
        'is-disabled': disabled,
      },
    ]"
    type="button"
    :disabled="disabled"
    :aria-label="label || null"
    :title="label || null"
    @click="onClick"
  >
    <slot><CoreIcon :name="icon" :size="iconPx" /></slot>
  </button>
</template>
