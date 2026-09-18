<script setup>
// CoreHeading — the title block of the kit (DESIGN §37.5, Surfaces): optional label-voice eyebrow
// above, the display title, an eyebrow-voice subtitle under it, actions on the right.
// `slash` is the mockups' `//` marker — two skewed accent bars sized in em, so they scale with the
// title — and it puts the title in italic, which is why Barlow Condensed 700 italic is bundled.
// The title element is skipped when there is nothing to put in it, so a panel that passes only
// `subtitle` does not leave an empty heading in the tree.
import { computed } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  /** Title text. The default slot overrides it (an italic word, a count, a `<span>`). */
  title: { type: String, default: '' },
  /** Eyebrow voice, under the title — the widely tracked line of the mockups. */
  subtitle: { type: String, default: '' },
  /** Label voice, above the title. */
  eyebrow: { type: String, default: '' },
  /** 18 / 24 / 34 / 48 px. */
  size: { type: String, default: 'md', validator: oneOf(['sm', 'md', 'lg', 'xl']) },
  /** The `//` marker before the title, which also turns the title italic. */
  slash: { type: Boolean, default: false },
  /** The element the title renders as — `h1`…`h6`, or `div` inside a card. */
  tag: { type: String, default: 'h2' },
  /** Which edge the block lines up with. */
  align: { type: String, default: 'left', validator: oneOf(['left', 'center', 'right']) },
})

const rootClass = computed(() => [
  'core-heading',
  'core-heading--' + props.size,
  'core-heading--align-' + props.align,
  { 'has-slash': props.slash },
])
</script>

<template>
  <div :class="rootClass">
    <div class="core-heading__main">
      <p v-if="eyebrow" class="core-heading__eyebrow">{{ eyebrow }}</p>

      <component
        :is="tag"
        v-if="title || slash || $slots.default"
        class="core-heading__title"
      >
        <span v-if="slash" class="core-heading__slash" aria-hidden="true">
          <span></span><span></span>
        </span>
        <span class="core-heading__text"><slot>{{ title }}</slot></span>
      </component>

      <p v-if="subtitle || $slots.subtitle" class="core-heading__subtitle">
        <slot name="subtitle">{{ subtitle }}</slot>
      </p>
    </div>

    <div v-if="$slots.actions" class="core-heading__actions">
      <slot name="actions" />
    </div>
  </div>
</template>
