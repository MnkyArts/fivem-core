<script setup>
// CoreDivider — a hairline (DESIGN §37.5, Surfaces). With a label it parts around a label-voice
// caption; the two halves are pseudo-elements, so the caption keeps its intrinsic width and the
// lines share what is left.
// `role="separator"` only when there is no label: a labelled divider is a heading-ish landmark
// and announcing it as a bare separator loses the word.
import { computed, useSlots } from 'vue'

const props = defineProps({
  /** A 1 px column that stretches to the height of its flex parent. */
  vertical: { type: Boolean, default: false },
  /** `border-strong` (white 20 %) instead of the default hairline. */
  strong: { type: Boolean, default: false },
  /** Caption in the middle of the line; the default slot overrides it. */
  label: { type: String, default: '' },
})

const slots = useSlots()

const hasLabel = computed(() => Boolean(props.label || slots.default))

const rootClass = computed(() => [
  'core-divider',
  {
    'core-divider--vertical': props.vertical,
    'core-divider--strong': props.strong,
    'has-label': hasLabel.value,
  },
])
</script>

<template>
  <div
    :class="rootClass"
    :role="hasLabel ? null : 'separator'"
    :aria-orientation="!hasLabel && vertical ? 'vertical' : null"
  >
    <span v-if="hasLabel" class="core-divider__label"><slot>{{ label }}</slot></span>
  </div>
</template>
