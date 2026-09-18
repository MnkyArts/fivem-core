<script>
// CoreButton — every button in the kit (DESIGN §37.5, Actions).
// Module scope: the icon size per button size. Three decisions worth knowing: `click` is declared
// as an emit (so the native listener does not also fire) and is swallowed while disabled OR
// loading; `loading` never hides the label, so the button cannot change width mid-request; and
// `fade` only means anything on the primary — it is the mockups' USE button.
const ICON_PX = { sm: 14, md: 18, lg: 22 }
const VARIANTS = ['primary', 'secondary', 'ghost', 'danger', 'success']
</script>

<script setup>
import { computed, useSlots } from 'vue'
import { SIZES, oneOf } from '../use.js'

const props = defineProps({
  variant: { type: String, default: 'secondary', validator: oneOf(VARIANTS) },
  /** Primary only: the fading accent gradient instead of the solid one. */
  fade: { type: Boolean, default: false },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** Full width of the parent. */
  block: { type: Boolean, default: false },
  /** Registry name or raw path; the `icon` slot wins over it. */
  icon: { type: String, default: '' },
  /** Same, on the trailing edge; the `trailing` slot wins over it. */
  iconRight: { type: String, default: '' },
  /** A key cap inside the button, leftmost: `[F] USE`. */
  kbd: { type: [String, Number], default: '' },
  /** Busy: the icon becomes a spinner and clicks stop. */
  loading: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  /** Toggle-on (a sticky filter, the selected tool) — not `:active`. */
  active: { type: Boolean, default: false },
  type: { type: String, default: 'button' },
})

const emit = defineEmits(['click'])
const slots = useSlots()

const iconPx = computed(() => ICON_PX[props.size] || ICON_PX.md)
const hasIcon = computed(() => !!(props.icon || slots.icon))
const hasTrailing = computed(() => !!(props.iconRight || slots.trailing))

function onClick (event) {
  if (props.disabled || props.loading) {
    event.preventDefault()
    event.stopPropagation()
    return
  }
  emit('click', event)
}
</script>

<template>
  <button
    class="core-btn"
    :class="[
      'core-btn--' + variant,
      'core-btn--' + size,
      {
        'is-fade': fade && variant === 'primary',
        'is-block': block,
        'is-active': active,
        'is-loading': loading,
        'is-disabled': disabled,
      },
    ]"
    :type="type"
    :disabled="disabled"
    :aria-busy="loading ? 'true' : null"
    @click="onClick"
  >
    <CoreKey v-if="kbd !== '' && kbd !== null" class="core-btn__kbd" :label="kbd" size="sm" />
    <span v-if="loading" class="core-btn__spinner" aria-hidden="true"></span>
    <span v-else-if="hasIcon" class="core-btn__icon">
      <slot name="icon"><CoreIcon :name="icon" :size="iconPx" /></slot>
    </span>
    <span v-if="$slots.default" class="core-btn__label"><slot /></span>
    <span v-if="hasTrailing" class="core-btn__icon">
      <slot name="trailing"><CoreIcon :name="iconRight" :size="iconPx" /></slot>
    </span>
  </button>
</template>
