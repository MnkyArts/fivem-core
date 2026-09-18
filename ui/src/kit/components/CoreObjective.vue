<script>
// CoreObjective — one checklist line under a quest (DESIGN §37.5, Game).
// An 18 px ring carries the whole state: hollow when open, coral ring + dot while active,
// filled coral with a check when done, an error cross with struck text when failed. Display
// only — the ring is decoration, so the state is announced through the text, not the circle.
// Module scope: `defineProps` cannot see a const declared inside <script setup>.
const STATES = ['open', 'active', 'done', 'failed']
</script>

<script setup>
import { computed } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  text: { type: String, default: '' },
  state: { type: String, default: 'open', validator: oneOf(STATES) },
  /** Right-hand value: a distance, a count (`2 / 5`), a timer. */
  trailing: { type: [String, Number], default: '' },
  /** Marks the line as a bonus objective. */
  optional: { type: Boolean, default: false },
})

const rootClass = computed(() => ['core-objective', 'is-' + (STATES.indexOf(props.state) === -1 ? 'open' : props.state)])
const glyph = computed(() => (props.state === 'done' ? 'check' : (props.state === 'failed' ? 'close' : '')))
</script>

<template>
  <div :class="rootClass">
    <span class="core-objective__ring">
      <CoreIcon v-if="glyph" :name="glyph" :size="10" />
    </span>
    <p class="core-objective__text"><slot>{{ text }}</slot></p>
    <span v-if="optional" class="core-objective__optional">Optional</span>
    <span v-if="$slots.trailing || trailing !== ''" class="core-objective__trailing">
      <slot name="trailing">{{ trailing }}</slot>
    </span>
  </div>
</template>
