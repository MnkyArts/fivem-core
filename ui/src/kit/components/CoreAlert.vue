<script>
// CoreAlert — inline banner (DESIGN §37.5, Feedback).
// Module scope: the tone → glyph table is shared by every instance, so an alert only needs a
// tone to say what it is. Passing `icon=""` explicitly opts out of the glyph entirely.
const TONE_ICON = {
  accent: 'info',
  neutral: 'info',
  info: 'info',
  success: 'success',
  warning: 'warning',
  danger: 'error',
}
</script>

<script setup>
import { computed, useSlots } from 'vue'
import { TONES, oneOf, toneClass } from '../use.js'

const props = defineProps({
  /** One of the six semantic tones; picks the fill, the bar and the default glyph. */
  tone: { type: String, default: 'info', validator: oneOf(TONES) },
  /** Display-voice headline. */
  title: { type: String, default: '' },
  /** Body copy; the default slot wins over it. */
  text: { type: String, default: '' },
  /** Registry name or raw path. Defaults to the tone's glyph; `icon=""` removes it. */
  icon: { type: String, default: undefined },
  /** `soft` = tone wash, `outline` = sunken well behind the same frame. */
  variant: { type: String, default: 'soft', validator: oneOf(['soft', 'outline']) },
  /** Adds the ✕ that emits `dismiss` (the caller still owns the visibility). */
  dismissible: { type: Boolean, default: false },
})

const emit = defineEmits(['dismiss'])
const slots = useSlots()

const glyph = computed(() => (props.icon === undefined ? TONE_ICON[props.tone] || 'info' : props.icon))
const hasBody = computed(() => Boolean(props.text) || Boolean(slots.default))
</script>

<template>
  <div class="core-alert" :class="[toneClass(tone), 'core-alert--' + tone, 'core-alert--' + variant]" role="status">
    <CoreIcon v-if="glyph" class="core-alert__icon" :name="glyph" size="md" />

    <div class="core-alert__body">
      <p v-if="title" class="core-alert__title">{{ title }}</p>
      <div v-if="hasBody" class="core-alert__text">
        <slot>{{ text }}</slot>
      </div>
      <div v-if="$slots.actions" class="core-alert__actions">
        <slot name="actions" />
      </div>
    </div>

    <button
      v-if="dismissible"
      type="button"
      class="core-alert__close"
      aria-label="Dismiss"
      @click="emit('dismiss')"
    >
      <CoreIcon name="close" size="sm" />
    </button>
  </div>
</template>
