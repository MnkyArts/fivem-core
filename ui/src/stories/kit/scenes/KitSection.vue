<script setup>
// KitSection — one labelled group inside a KitStage (DESIGN §37.7).
//
//   <KitSection label="Sizes" note="heights come from --core-h-*">…</KitSection>
//   <KitSection label="Tones" layout="grid" :columns="4" :gap="12">…</KitSection>
//
// Eyebrow-voice label, a hairline under it, then the slot laid out by `layout`.
import { computed } from 'vue'

const props = defineProps({
  /** Eyebrow-voice caption over the hairline. */
  label: { type: String, default: '' },
  /** `row` (wraps, centred), `column` (stacked, left) or `grid` (`columns` equal columns). */
  layout: { type: String, default: 'row', validator: (v) => ['row', 'column', 'grid'].includes(v) },
  /** Grid column count. */
  columns: { type: Number, default: 3 },
  /** Gap between the children, in px. */
  gap: { type: Number, default: 16 },
  /** Small caption under the hairline: the rule or token this group demonstrates. */
  note: { type: String, default: '' },
})

const bodyStyle = computed(() => {
  const style = { gap: props.gap + 'px', marginTop: '16px' }
  if (props.layout === 'grid') {
    style.display = 'grid'
    style.gridTemplateColumns = 'repeat(' + props.columns + ', minmax(0, 1fr))'
    style.alignItems = 'start'
  } else {
    style.display = 'flex'
    style.flexDirection = props.layout === 'column' ? 'column' : 'row'
    style.alignItems = props.layout === 'column' ? 'flex-start' : 'center'
    if (props.layout === 'row') style.flexWrap = 'wrap'
  }
  return style
})
</script>

<template>
  <section class="core-kitsection">
    <p v-if="label" class="core-eyebrow">{{ label }}</p>
    <div v-if="label" class="border-b border-border" style="margin-top: 10px"></div>
    <!-- Ligatures off: Barlow would draw the `--` of a token name as a dash (see KitStage). -->
    <p
      v-if="note"
      class="text-fg-faint text-ui-sm"
      style="margin: 10px 0 0; font-variant-ligatures: none; font-feature-settings: 'liga' 0, 'calt' 0"
    >{{ note }}</p>
    <div :style="bodyStyle">
      <slot />
    </div>
  </section>
</template>
