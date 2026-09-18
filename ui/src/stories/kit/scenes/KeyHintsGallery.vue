<script setup>
// KeyHintsGallery — CoreKeyHints: the map footer of the mockup (bare, right-aligned, mouse glyphs
// next to caps), the framed bar, every alignment, both item shapes the shell may send and the
// start / end slots.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

// The mockup's map footer, in its order.
const MAP = [
  { key: 'mouse-left', label: 'Pan' },
  { key: 'mouse-scroll', label: 'Zoom' },
  { key: 'R', label: 'Recenter' },
  { key: 'F', label: 'Show legend' },
]

// What `keys:show` puts in the store: always `{ key, label }`.
const SHELL = [
  { key: 'E', label: 'Interact' },
  { key: 'G', label: 'Holster' },
  { key: 'ESC', label: 'Back' },
]

// The richer shape: a combination in one hint, and a bare string (cap, no caption).
const MIXED = [
  { keys: ['SHIFT', 'F'], label: 'Enter as passenger' },
  { keys: ['CTRL', 'S'], label: 'Save outfit' },
  'ESC',
]

const footer = {
  background: 'linear-gradient(180deg, rgba(6, 11, 15, 0) 0%, rgba(6, 11, 15, 0.92) 55%)',
  borderTop: '1px solid var(--color-border)',
  padding: '18px 28px',
  width: '100%',
}
</script>

<template>
  <KitStage
    title="CoreKeyHints"
    description="The instructional-button bar. `bare` is the form that sits in a CoreScreen footer — no fill,
      no border, because the footer already draws the hairline; the framed form is for a HUD corner."
  >
    <KitSection label="The map footer" layout="column" :gap="0"
                note="bare · align end · mouse glyphs and caps in one row (mockup 4).">
      <div :style="footer">
        <CoreKeyHints :items="MAP" bare />
      </div>
    </KitSection>

    <KitSection label="Framed" layout="column" :gap="14" note="Not bare: panel fill, hairline, radius 4, padding 8 14.">
      <CoreKeyHints :items="SHELL" style="width: 520px" />
      <CoreKeyHints :items="MAP" variant="outline" style="width: 520px" />
    </KitSection>

    <KitSection label="Alignment" layout="column" :gap="14" note="start · end (default) · between.">
      <CoreKeyHints :items="SHELL" align="start" style="width: 620px" />
      <CoreKeyHints :items="SHELL" align="end" style="width: 620px" />
      <CoreKeyHints :items="SHELL" align="between" style="width: 620px" />
    </KitSection>

    <KitSection label="Sizes" layout="column" :gap="14">
      <CoreKeyHints :items="SHELL" size="sm" align="start" style="width: 520px" />
      <CoreKeyHints :items="SHELL" size="md" align="start" style="width: 520px" />
      <CoreKeyHints :items="SHELL" size="lg" align="start" style="width: 520px" />
    </KitSection>

    <KitSection label="Item shapes" layout="column" :gap="14"
                note="{ key, label } (the store), { keys: [...], label } (a combination) and a bare string (cap only).">
      <CoreKeyHints :items="MIXED" align="start" bare />
    </KitSection>

    <KitSection label="Slots" layout="column" :gap="14"
                note="start / end wrap the items; the default slot replaces them entirely.">
      <CoreKeyHints :items="SHELL" align="between" style="width: 620px">
        <template #start>
          <span class="core-label" style="letter-spacing: 0.2em">Los Santos · Vinewood</span>
        </template>
      </CoreKeyHints>
      <CoreKeyHints align="between" style="width: 620px">
        <CoreKeyHint keys="mouse-left" label="Move item" />
        <CoreKeyHint keys="mouse-right" label="Split stack" />
        <CoreKeyHint :keys="['SHIFT', 'mouse-left']" label="Move all" />
        <CoreKeyHint keys="ESC" label="Close" variant="outline" />
      </CoreKeyHints>
    </KitSection>
  </KitStage>
</template>
