<script setup>
// KitStage — the page frame every kit gallery scene is built from (DESIGN §37.7).
//
//   <KitStage title="Button" description="…">
//     <KitSection label="Variants"> … </KitSection>
//   </KitStage>
//
// Renders the same in Storybook (layout: 'fullscreen') and in the dev harness
// (kit-preview.html?scene=…): the stage brings its own padding and sits transparently over
// whatever background the page paints, so translucent panels can still be judged.
// Layout utilities + tokens only — no literal colour, font or radius (§37 rule for pages).
import { computed } from 'vue'

const props = defineProps({
  /** Display-voice heading with the accent dash under it. */
  title: { type: String, default: '' },
  /** One or two sentences under the title: what this gallery proves. */
  description: { type: String, default: '' },
  /** Max content width. A number is px. */
  width: { type: [Number, String], default: 1100 },
  /** Centre the content column instead of leaving it against the left edge. */
  center: { type: Boolean, default: false },
  /** 40 px of breathing room around everything (off for a full-bleed showcase scene). */
  padded: { type: Boolean, default: true },
})

const contentStyle = computed(() => ({
  maxWidth: typeof props.width === 'number' ? props.width + 'px' : String(props.width),
  margin: props.center ? '0 auto' : '0',
}))
</script>

<template>
  <div class="core-kitstage pointer-events-auto text-fg" :style="{ padding: padded ? '40px' : '0' }">
    <div :style="contentStyle">
      <header v-if="title || description" style="margin-bottom: 34px">
        <h1 v-if="title" class="core-display core-display--lg">{{ title }}</h1>
        <div class="bg-accent" style="width: 28px; height: 3px; margin-top: 14px"></div>
        <!-- Barlow ligates a double hyphen into a dash, which would turn every `--token` name in a
             description into an em dash. Gallery prose is full of them, so turn the feature off. -->
        <p
          v-if="description"
          class="text-fg-dim text-ui"
          style="margin: 16px 0 0; max-width: 78ch; font-variant-ligatures: none; font-feature-settings: 'liga' 0, 'calt' 0"
        >
          {{ description }}
        </p>
      </header>

      <div class="flex flex-col" style="gap: 36px">
        <slot />
      </div>
    </div>
  </div>
</template>
