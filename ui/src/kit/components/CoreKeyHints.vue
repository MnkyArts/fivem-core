<script setup>
// CoreKeyHints — the hint bar (DESIGN §37.5, Actions): the row of `[R] RECENTER` pairs along a
// footer. Items come in either shape — `{ key, label }` (what the shell's `keys:show` store sends)
// or `{ keys: [...], label }` — and a bare string is a cap with no caption. `bare` drops the panel
// chrome for a CoreScreen footer, which already brings its own hairline.
import { computed } from 'vue'
import { SIZES, blurAttr, normalizeItems, oneOf } from '../use.js'

const props = defineProps({
  /** `[{ key | keys, label }]`, or plain strings. */
  items: { type: Array, default: () => [] },
  align: { type: String, default: 'end', validator: oneOf(['start', 'end', 'between']) },
  /** No fill, border or padding — the footer form. */
  bare: { type: Boolean, default: false },
  variant: { type: String, default: 'solid', validator: oneOf(['solid', 'outline']) },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  /** §32 glass: `true` for the default strength, a number for that radius. */
  blur: { type: [Boolean, Number, String], default: false },
})

// normalizeItems() gives every entry a `value`; a string item therefore arrives as
// `{ value: 'ESC', label: 'ESC' }`, and printing that label next to its own cap would read
// `[ESC] ESC` — so a caption is only kept when the item really named a key.
const hints = computed(() => normalizeItems(props.items).map((item, i) => {
  const named = item.keys !== undefined || item.key !== undefined
  const keys = item.keys !== undefined ? item.keys : (item.key !== undefined ? item.key : item.value)
  return { id: i, keys, label: named ? item.label : '' }
}))
</script>

<template>
  <div
    class="core-keyhints"
    :class="['core-keyhints--' + align, { 'is-bare': bare }]"
    v-bind="blurAttr(blur)"
  >
    <slot name="start" />
    <slot>
      <CoreKeyHint
        v-for="hint in hints"
        :key="hint.id"
        :keys="hint.keys"
        :label="hint.label"
        :variant="variant"
        :size="size"
      />
    </slot>
    <slot name="end" />
  </div>
</template>
