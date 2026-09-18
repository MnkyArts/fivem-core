<script setup>
// CoreBrand — the logo lockup (DESIGN §37.5, Surfaces): the main-menu wordmark of mockup 1 and the
// small header version of mockups 3 and 4.
// The mark box is only rendered when there is something to put in it, so a server with no logo
// gets a clean wordmark instead of an empty square. The `logo` slot takes an inline SVG — that is
// how the mockups' coral triangle is drawn, and it inherits the accent colour from the box.
import { computed } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  /** The wordmark — display 700, 22 / 30 / 48 / 64 px. */
  name: { type: String, default: '' },
  /** Eyebrow-voice line under the name. */
  tagline: { type: String, default: '' },
  /** Logo URL. The `logo` slot overrides it (and is the better way in: an inline SVG). */
  logo: { type: String, default: '' },
  /** `sm` header · `md` screen header · `lg` the main menu · `xl` a splash. */
  size: { type: String, default: 'md', validator: oneOf(['sm', 'md', 'lg', 'xl']) },
})

const rootClass = computed(() => ['core-brand', 'core-brand--' + props.size])
</script>

<template>
  <div :class="rootClass">
    <span v-if="logo || $slots.logo" class="core-brand__logo">
      <slot name="logo">
        <img :src="logo" alt="" />
      </slot>
    </span>

    <span class="core-brand__text">
      <span class="core-brand__name">{{ name }}</span>
      <span v-if="tagline" class="core-brand__tagline">{{ tagline }}</span>
    </span>
  </div>
</template>
