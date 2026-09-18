<script>
// CoreToast — notification card (DESIGN §37.5, Feedback; the skin of the shell's Notifications,
// §37.6). HUD furniture: the card is click-through (§37.4) and only the ✕ takes the mouse, so a
// stack of toasts can never swallow a click meant for the game.
const TONE_ICON = {
  accent: 'bell',
  neutral: 'bell',
  info: 'info',
  success: 'success',
  warning: 'warning',
  danger: 'error',
}
</script>

<script setup>
import { computed } from 'vue'
import { TONES, clamp, oneOf, toneClass, blurAttr } from '../use.js'

const props = defineProps({
  /** One of the six semantic tones; picks the bar, the glyph and the title colour. */
  tone: { type: String, default: 'info', validator: oneOf(TONES) },
  /** Display-voice kicker in the tone ("VEHICLE IMPOUNDED"). */
  title: { type: String, default: '' },
  /** The line itself; the default slot wins over it. */
  message: { type: String, default: '' },
  /** Registry name or raw path. Defaults to the tone's glyph; `icon=""` removes it. */
  icon: { type: String, default: undefined },
  /** How often the same notification arrived while the card was up (`x3`); < 2 hides the pill. */
  count: { type: Number, default: 0 },
  /** 0-1 of life left. `null`/undefined leaves the bar out. */
  progress: { type: Number, default: undefined },
  /** Adds the ✕ that emits `dismiss`. */
  dismissible: { type: Boolean, default: false },
  /** §32 glass: `true` or a blur radius in px. */
  blur: { type: [Boolean, Number, String], default: false },
})

const emit = defineEmits(['dismiss'])

const glyph = computed(() => (props.icon === undefined ? TONE_ICON[props.tone] || 'info' : props.icon))
const hasLife = computed(() => typeof props.progress === 'number' && Number.isFinite(props.progress))
const lifeWidth = computed(() => clamp(props.progress, 0, 1) * 100 + '%')
</script>

<template>
  <div
    class="core-toast"
    :class="[toneClass(tone), 'core-toast--' + tone]"
    role="status"
    aria-live="polite"
    v-bind="blurAttr(blur)"
  >
    <span class="core-toast__bar" aria-hidden="true"></span>

    <div class="core-toast__main">
      <CoreIcon v-if="glyph" class="core-toast__icon" :name="glyph" size="md" />

      <div class="core-toast__body">
        <p v-if="title" class="core-toast__title">{{ title }}</p>
        <div class="core-toast__message">
          <slot>{{ message }}</slot>
        </div>
      </div>

      <span v-if="count > 1" class="core-toast__count">x{{ count }}</span>

      <button
        v-if="dismissible"
        type="button"
        class="core-toast__close"
        aria-label="Dismiss"
        @click="emit('dismiss')"
      >
        <CoreIcon name="close" size="sm" />
      </button>
    </div>

    <div v-if="hasLife" class="core-toast__life" aria-hidden="true">
      <div class="core-toast__lifefill" :style="{ width: lifeWidth }"></div>
    </div>
  </div>
</template>
