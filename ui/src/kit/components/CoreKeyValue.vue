<script setup>
// CoreKeyValue — a ruled label/value list (DESIGN §37.5, Data — display).
// The read-out voice of mockup 3 ("3 / 10" over "IN INVENTORY"), laid out as rows: label voice left,
// display voice right, one hairline per row. `columns` only splits the SAME rows into a grid, so a
// wide detail panel stays a single `items` array. The `value-<i>` and `label-<i>` slots are indexed
// 0..n-1 because a label is free text — the index is the only stable handle.
import { computed } from 'vue'
import { METER_TONES, toneClass } from '../use.js'

const props = defineProps({
  /** `[{ label, value, icon?, tone? }]` — `tone` paints the value and its glyph. */
  items: { type: Array, default: () => [] },
  /** Split the rows into this many equal columns. */
  columns: { type: Number, default: 1 },
  /**
   * Keep the hairline under the LAST row. `false` rules only BETWEEN rows, which is what a block
   * that ends at its own panel's edge needs (the shell's HUD plate, §37.6) — a rule floating above
   * the padding reads as an unfinished list.
   */
  lastRule: { type: Boolean, default: true },
})

const rows = computed(() => (Array.isArray(props.items) ? props.items : []).filter(Boolean))

const gridStyle = computed(() => ({
  gridTemplateColumns: 'repeat(' + Math.max(1, Math.round(props.columns)) + ', minmax(0, 1fr))',
}))

const itemClass = (item) => [
  'core-kv__item',
  item.tone && METER_TONES.indexOf(item.tone) !== -1 ? [toneClass(item.tone), 'is-toned'] : null,
]

// Inline, not a class: the rule is one declaration and it belongs to this component alone, so it
// does not need a state class in the partial every other component would have to read past.
const itemStyle = (i) => (!props.lastRule && i === rows.value.length - 1 ? { borderBottomColor: 'transparent' } : null)
</script>

<template>
  <dl class="core-kv" :style="gridStyle">
    <div v-for="(item, i) in rows" :key="item.label + ':' + i" :class="itemClass(item)" :style="itemStyle(i)">
      <dt class="core-kv__label">
        <CoreIcon v-if="item.icon" class="core-kv__icon" :name="item.icon" :size="16" />
        <slot :name="'label-' + i" :item="item" :label="item.label"><span>{{ item.label }}</span></slot>
      </dt>
      <dd class="core-kv__value">
        <slot :name="'value-' + i" :item="item" :value="item.value">{{ item.value }}</slot>
      </dd>
    </div>
  </dl>
</template>
