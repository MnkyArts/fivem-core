<script setup>
// CoreListItem — one rich row of the quest list of mockup 4 (DESIGN §37.5, Game).
// Thumb, tone glyph, Title Case condensed title, dim subtitle, trailing value pinned bottom
// right. `disabled` is aria-only so CoreList's ↑/↓ roving can still walk over the row.
// The title is the one display-voice string in the kit that is NOT uppercased.
import { computed } from 'vue'
import { oneOf, toneClass, METER_TONES } from '../use.js'

const props = defineProps({
  /** Thumbnail, 96 x 84, cover-cropped. The `media` slot replaces it. */
  image: { type: String, default: '' },
  /** Glyph between thumb and text (registry name or raw path). The `icon` slot replaces it. */
  icon: { type: String, default: '' },
  /** Colour of that glyph. */
  iconTone: { type: String, default: 'accent', validator: oneOf(METER_TONES) },
  title: { type: String, default: '' },
  subtitle: { type: String, default: '' },
  /** Bottom-right value — a distance, a price, a timer. */
  trailing: { type: [String, Number], default: '' },
  selected: { type: Boolean, default: false },
  completed: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  /** false renders a plain <div>: a row that only reports, never selects. */
  interactive: { type: Boolean, default: true },
})

const emit = defineEmits(['click'])

// `is-interactive` is what turns the mouse on in the partial — a `interactive: false` row inside
// a click-through HUD panel must not eat the click. It tracks the PROP, not `!disabled`: a
// disabled row still has to hit-test to show `cursor: not-allowed`, and the partial's
// `.is-disabled` rules sit after the hover rules so they win anyway.
const rootClass = computed(() => [
  'core-listitem',
  {
    'is-selected': props.selected,
    'is-completed': props.completed,
    'is-disabled': props.disabled,
    'is-interactive': props.interactive,
  },
])

function onClick(event) {
  if (props.disabled) return
  emit('click', event)
}
</script>

<template>
  <component
    :is="interactive ? 'button' : 'div'"
    :type="interactive ? 'button' : null"
    :class="rootClass"
    :aria-disabled="disabled ? 'true' : null"
    :aria-current="interactive && selected ? 'true' : null"
    @click="onClick"
  >
    <span v-if="$slots.media || image" class="core-listitem__media">
      <slot name="media">
        <img class="core-listitem__image" :src="image" :alt="''" draggable="false" />
      </slot>
    </span>

    <span v-if="$slots.icon || icon" class="core-listitem__icon" :class="toneClass(iconTone)">
      <slot name="icon">
        <CoreIcon :name="icon" :size="26" />
      </slot>
    </span>

    <span class="core-listitem__text">
      <span v-if="title" class="core-listitem__title">{{ title }}</span>
      <span v-if="subtitle" class="core-listitem__subtitle">{{ subtitle }}</span>
      <slot />
    </span>

    <span v-if="$slots.trailing || trailing !== ''" class="core-listitem__trailing">
      <slot name="trailing">{{ trailing }}</slot>
    </span>
  </component>
</template>
