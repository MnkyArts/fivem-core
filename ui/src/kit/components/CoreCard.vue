<script setup>
// CoreCard — media + text (DESIGN §37.5, Surfaces): the LAST PLAYED card of mockup 1 (`left`) and
// the quest detail of mockup 4 (`top`, where the picture dissolves into the card and the title is
// pulled up over the fade).
// An interactive card is NOT a <button>: the `trailing` and `meta` slots routinely hold buttons of
// their own and nesting them is invalid HTML, so it takes role/tabindex and answers Enter + Space
// by hand — the one place the kit steps off the "everything clickable is a <button>" rule (§37.4).
import { computed } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  /**
   * `default` the panel fill · `flat` white 2 %, no shadow · `ghost` no fill and no border, for a
   * card sitting flush on a panel that already has one. Selection and hover read on all three.
   */
  variant: { type: String, default: 'default', validator: oneOf(['default', 'flat', 'ghost']) },
  /** Picture URL. The `media` slot replaces it (a canvas, a CoreSlot, a video). */
  image: { type: String, default: '' },
  /** `left` insets the picture in the card padding; `top` bleeds it to the top edge. */
  imagePosition: { type: String, default: 'left', validator: oneOf(['left', 'top']) },
  /** Media box width in px — `left` only; a `top` picture is always full width. */
  mediaWidth: { type: [Number, String], default: 168 },
  /** Media box height in px. */
  mediaHeight: { type: [Number, String], default: 180 },
  /** Label voice over the title. */
  eyebrow: { type: String, default: '' },
  /** Display-voice title. */
  title: { type: String, default: '' },
  /** Titles are uppercase and tracked; `false` keeps the copy as written (quest names). */
  uppercase: { type: Boolean, default: true },
  /** One line under the title, sans 15 px. */
  subtitle: { type: String, default: '' },
  /** Icon before the subtitle (registry name or raw path); the `icon` slot overrides it. */
  icon: { type: String, default: '' },
  /** Coral edge + glow — selection is never a filled block (§37.1). */
  selected: { type: Boolean, default: false },
  /** Hover look, pointer, keyboard focus and Enter/Space. */
  interactive: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
})

const emit = defineEmits(['click'])

const px = (v) => (typeof v === 'number' || /^\d+(\.\d+)?$/.test(String(v)) ? v + 'px' : String(v))

const clickable = computed(() => props.interactive && !props.disabled)

const rootClass = computed(() => [
  'core-card',
  'core-card--' + props.variant,
  'core-card--media-' + props.imagePosition,
  {
    'is-selected': props.selected,
    'is-interactive': props.interactive,
    'is-disabled': props.disabled,
  },
])

const mediaStyle = computed(() => (props.imagePosition === 'top'
  ? { height: px(props.mediaHeight) }
  : { width: px(props.mediaWidth), height: px(props.mediaHeight) }))

function activate (event) {
  if (!clickable.value) return
  emit('click', event)
}

function onKeydown (event) {
  if (!clickable.value) return
  if (event.key !== 'Enter' && event.key !== ' ' && event.key !== 'Spacebar') return
  event.preventDefault()
  emit('click', event)
}
</script>

<template>
  <div
    :class="rootClass"
    :role="clickable ? 'button' : null"
    :tabindex="clickable ? 0 : null"
    :aria-disabled="disabled ? 'true' : null"
    @click="activate"
    @keydown="onKeydown"
  >
    <div v-if="image || $slots.media" class="core-card__media" :style="mediaStyle">
      <slot name="media">
        <img class="core-card__image" :src="image" alt="" />
      </slot>
      <div v-if="imagePosition === 'top'" class="core-card__fade"></div>
    </div>

    <div class="core-card__main">
      <p v-if="eyebrow" class="core-card__eyebrow">{{ eyebrow }}</p>

      <h3 v-if="title" class="core-card__title" :class="{ 'is-plain': !uppercase }">{{ title }}</h3>

      <p v-if="subtitle || icon || $slots.icon" class="core-card__subtitle">
        <slot name="icon">
          <CoreIcon v-if="icon" :name="icon" size="sm" />
        </slot>
        <span>{{ subtitle }}</span>
      </p>

      <div v-if="$slots.default" class="core-card__body"><slot /></div>

      <div v-if="$slots.meta" class="core-card__meta"><slot name="meta" /></div>
    </div>

    <div v-if="$slots.trailing" class="core-card__trailing"><slot name="trailing" /></div>
  </div>
</template>
