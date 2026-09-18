<script setup>
// CoreTagline — stacked, widely tracked words beside a vertical hairline (DESIGN §37.5, Surfaces):
// the "EXPLORE / SURVIVE / BELONG" block of mockup 1 and the screen-header line of mockups 3 and 4.
// `rule` takes `true` for the hairline and the string `'accent'` for the 2 px coral rule the
// inventory and map headers use — the mockups have both and the component carries no `tone`.
import { computed } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  /** One line each; the default slot replaces them when a line needs its own markup. */
  lines: { type: Array, default: () => [] },
  /** `true` a hairline on the left, `'accent'` the coral rule. */
  rule: { type: [Boolean, String], default: false },
  /** An accent dash under the block; a number sets its width (default 28). */
  dash: { type: [Boolean, Number], default: false },
  /** Which edge the words line up with. */
  align: { type: String, default: 'left', validator: oneOf(['left', 'center', 'right']) },
})

const rootClass = computed(() => [
  'core-tagline',
  'core-tagline--align-' + props.align,
  {
    'has-rule': Boolean(props.rule),
    'is-rule-accent': props.rule === 'accent',
    'has-dash': Boolean(props.dash),
  },
])

const dashWidth = computed(() => (typeof props.dash === 'number' ? props.dash : 28))
</script>

<template>
  <div :class="rootClass">
    <div class="core-tagline__lines">
      <slot>
        <span v-for="(line, i) in lines" :key="i" class="core-tagline__line">{{ line }}</span>
      </slot>
    </div>
    <CoreDash v-if="dash" class="core-tagline__dash" :width="dashWidth" />
  </div>
</template>
