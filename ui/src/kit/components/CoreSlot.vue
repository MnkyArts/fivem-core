<script setup>
// CoreSlot — one item cell of the inventory grid and the hotbar (DESIGN §37.5, Game).
// A <button> while `interactive`, so a slot is reachable by keyboard on its own and inside
// CoreSlotGrid's 2D roving; `disabled` is aria-only (never the native attribute) because a
// disabled cell must still be focusable for the arrow keys to walk past it.
// The hotkey chip is local markup, not CoreKey: a 18 px cap has no hold state and no sizes.
import { computed } from 'vue'
import { clamp, oneOf, rarityClass, RARITIES } from '../use.js'

const props = defineProps({
  /** Item art. Drawn contained inside a 12 % inset, never stretched. */
  image: { type: String, default: '' },
  /** Fallback glyph (registry name or raw path) when there is no `image`. */
  icon: { type: String, default: '' },
  /** Stack size, bottom right. Any falsy value but 0 hides it. */
  count: { type: [Number, String], default: null },
  /** Key cap top left — the hotbar's `1`…`4`. */
  hotkey: { type: [Number, String], default: '' },
  /** Native tooltip (`title`) and the accessible name of the button. */
  label: { type: String, default: '' },
  /** Rarity line + bloom along the bottom edge. */
  rarity: { type: String, default: '', validator: oneOf(RARITIES.concat([''])) },
  /** Condition, 0–1. Green, amber under 50 %, red under 20 %. `null` hides the bar. */
  durability: { type: Number, default: null },
  /** Short text badge, top right (`NEW`, `EQ`). */
  badge: { type: [Number, String], default: '' },
  selected: { type: Boolean, default: false },
  disabled: { type: Boolean, default: false },
  /** An empty cell: nothing inside, no hover, still focusable so the grid can rove over it. */
  empty: { type: Boolean, default: false },
  /** Fixed cell width in px. Unset: the slot fills its grid cell. */
  size: { type: [Number, String], default: null },
  /** `aspect-ratio` of the cell — `'1 / 1'` in a grid, `'5 / 4'` in the hotbar. */
  ratio: { type: String, default: '1 / 1' },
  /** false renders a plain <div>: a slot in a tooltip or a legend takes no input. */
  interactive: { type: Boolean, default: true },
})

const emit = defineEmits(['click', 'dblclick', 'contextmenu'])

// `is-interactive` is what turns the mouse on in the partial: without it the cell is
// click-through, so a legend or a tooltip slot inside a HUD eats nothing. It tracks the PROP,
// not `!disabled` — a disabled cell still has to hit-test to show `cursor: not-allowed`.
const rootClass = computed(() => [
  'core-slot',
  props.rarity ? 'core-slot--rarity-' + props.rarity : null,
  rarityClass(props.rarity),
  {
    'is-interactive': props.interactive,
    'is-selected': props.selected,
    'is-empty': props.empty,
    'is-disabled': props.disabled,
  },
])

const rootStyle = computed(() => {
  const style = { '--core-slot-ratio': props.ratio }
  if (props.size !== null && props.size !== '') {
    style.width = typeof props.size === 'number' ? props.size + 'px' : String(props.size)
    style.flex = 'none'
  }
  return style
})

const showCount = computed(() => !props.empty && props.count !== null && props.count !== '' && props.count !== false)

const bar = computed(() => {
  if (props.empty || props.durability === null) return null
  const pct = clamp(Number(props.durability) * 100, 0, 100)
  return { width: pct + '%', cls: pct < 20 ? 'is-low' : (pct < 50 ? 'is-warn' : null) }
})

function on(name, event) {
  if (props.disabled) return
  emit(name, event)
}
</script>

<template>
  <component
    :is="interactive ? 'button' : 'div'"
    :type="interactive ? 'button' : null"
    :class="rootClass"
    :style="rootStyle"
    :title="label || null"
    :aria-label="interactive && label ? label : null"
    :aria-disabled="disabled ? 'true' : null"
    :aria-pressed="interactive && selected ? 'true' : null"
    @click="on('click', $event)"
    @dblclick="on('dblclick', $event)"
    @contextmenu="on('contextmenu', $event)"
  >
    <template v-if="!empty">
      <span class="core-slot__media">
        <img v-if="image" class="core-slot__image" :src="image" :alt="''" draggable="false" />
        <CoreIcon v-else-if="icon" class="core-slot__glyph" :name="icon" :size="32" />
      </span>

      <span v-if="hotkey !== '' && hotkey !== null" class="core-slot__hotkey">{{ hotkey }}</span>
      <span v-if="badge !== '' && badge !== null" class="core-slot__badge">{{ badge }}</span>
      <span v-if="showCount" class="core-slot__count">{{ count }}</span>

      <span v-if="bar" class="core-slot__durability">
        <span class="core-slot__durability-fill" :class="bar.cls" :style="{ width: bar.width }"></span>
      </span>

      <span v-if="rarity" class="core-slot__rarity"></span>
      <slot />
      <span v-if="$slots.overlay" class="core-slot__overlay"><slot name="overlay" /></span>
    </template>
  </component>
</template>
