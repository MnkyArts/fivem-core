<script setup>
// CoreScreen — the full-page scaffold of mockups 3 and 4 (DESIGN §37.5, Surfaces): a
// CoreBackground at z 0 and header / body / footer above it.
// Header and footer are rendered only when one of their slots is filled, so `<CoreScreen>` with
// nothing but a body is a scrim and a padded column — a plugin page pays for what it uses.
// The background is a slot with the component as its fallback, which is how a page swaps in a
// video, a live map or its own layered art without losing the frame.
// `navAlign="center"` takes the nav out of the header's flow and pins it to the middle of the
// SCREEN: with `space` the nav only ever centres between brand and status, and those are never the
// same width, so mockup 3's tabs would sit visibly off-centre.
import { computed, useSlots } from 'vue'
import { oneOf } from '../use.js'

const props = defineProps({
  /** CoreBackground variant — `scrim`, `left`, `vignette`, `bars`, `solid`, `none`, … */
  background: { type: String, default: 'scrim' },
  /** Passed to the background: scrim strength 0–1. */
  dim: { type: [Number, String], default: null },
  /** Passed to the background: a picture under the scrim. */
  image: { type: String, default: '' },
  /** Passed to the background: how that picture is framed (`background-position`). */
  position: { type: String, default: 'center' },
  /** Passed to the background: the blurred copy of the game behind the page (§32). */
  blur: { type: [Boolean, Number, String], default: false },
  /** 24 / 28 px around the body. Off for a full-bleed page (a map, a video). */
  padded: { type: Boolean, default: true },
  /**
   * Where the `nav` slot sits: `space` shares the leftover room (centred between brand and status),
   * `center` pins it to the middle of the screen (mockup 3), `start` hangs it off the brand
   * (mockup 4).
   */
  navAlign: { type: String, default: 'space', validator: oneOf(['space', 'center', 'start']) },
})

const slots = useSlots()

const hasHeader = computed(() => Boolean(slots.brand || slots.nav || slots.status))
const hasFooter = computed(() => Boolean(slots['footer-start'] || slots['footer-end']))
</script>

<template>
  <div class="core-screen" :class="'core-screen--nav-' + navAlign">
    <slot name="background">
      <CoreBackground :variant="background" :dim="dim" :image="image" :position="position" :blur="blur" />
    </slot>

    <header v-if="hasHeader" class="core-screen__header">
      <div class="core-screen__brand"><slot name="brand" /></div>
      <div class="core-screen__nav"><slot name="nav" /></div>
      <div class="core-screen__status"><slot name="status" /></div>
    </header>

    <div class="core-screen__body" :class="{ 'is-padded': padded }">
      <slot />
    </div>

    <footer v-if="hasFooter" class="core-screen__footer">
      <div class="core-screen__footer-start"><slot name="footer-start" /></div>
      <div class="core-screen__footer-end"><slot name="footer-end" /></div>
    </footer>
  </div>
</template>
