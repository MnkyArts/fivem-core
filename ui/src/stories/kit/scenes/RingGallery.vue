<script setup>
// RingGallery — CoreRing at every size, tone and thickness, with the three things its centre can
// hold: the value it computes itself, an icon, or whatever the default slot puts there.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const SIZES = [
  [28, 3, 'beside a list row'],
  [36, 3, 'a hotbar cooldown'],
  [48, 4, 'the default'],
  [64, 5, 'a panel header'],
  [96, 6, 'an empty state, a heist stage'],
]

const TONES = [
  ['accent', 68, 'Contract'],
  ['neutral', 41, 'Storage'],
  ['success', 100, 'Repaired'],
  ['warning', 55, 'Wear'],
  ['danger', 23, 'Heat'],
  ['info', 77, 'Upload'],
]

const VITALS = [
  ['health', 82, 'heart'],
  ['armour', 40, 'shield'],
  ['stamina', 66, 'bolt'],
  ['hunger', 54, 'food'],
  ['thirst', 31, 'water'],
  ['oxygen', 88, 'lungs'],
  ['stress', 22, 'brain'],
]

const STAGES = [0, 25, 50, 75, 100]

const cell = { display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '10px', width: '118px' }
</script>

<template>
  <KitStage
    title="CoreRing"
    description="Radial progress for the places a bar cannot go: a hotbar cooldown, a timer over a marker,
      a compact stat in a header. One SVG circle with a shrinking dash offset, butt caps, and an arc that
      starts at 12 o'clock — set by the SVG transform attribute, so no CSS transform is involved."
  >
    <KitSection label="Sizes" :gap="30" note="`size` is the outer diameter, `thickness` the stroke. The centre text scales with the ring.">
      <div v-for="[size, thickness, use] in SIZES" :key="size" :style="cell">
        <CoreRing :size="size" :thickness="thickness" :value="72" />
        <span class="text-ui-sm">{{ size }} · {{ thickness }} px</span>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">{{ use }}</span>
      </div>
    </KitSection>

    <KitSection label="Tones" :gap="26" note="core-tone-* again: the arc is var(--tone), the well is white 12 % like every other track.">
      <div v-for="[tone, value, label] in TONES" :key="tone" :style="cell">
        <CoreRing :tone="tone" :value="value" :size="64" :thickness="5" />
        <span class="core-label">{{ label }}</span>
      </div>
    </KitSection>

    <KitSection label="Vitals, with a glyph in the centre" :gap="22" note="`icon` replaces the value — the ring itself is the read-out.">
      <div v-for="[tone, value, icon] in VITALS" :key="tone" :style="cell">
        <CoreRing :tone="tone" :value="value" :icon="icon" :size="56" :thickness="4" />
        <span class="text-ui-xs text-fg-faint">{{ tone }} · {{ value }}</span>
      </div>
    </KitSection>

    <KitSection label="Progress" :gap="26" note="0 draws the well only; 100 closes the circle. The arc eases over 250 ms when the value changes.">
      <div v-for="value in STAGES" :key="value" :style="cell">
        <CoreRing :value="value" :size="64" :thickness="5" />
        <span class="text-ui-xs text-fg-faint">{{ value }} %</span>
      </div>
    </KitSection>

    <KitSection label="Thickness" :gap="26" note="From a hairline ring to a donut — 2 to 10 px on the same 72 px circle.">
      <div v-for="thickness in [2, 4, 6, 8, 10]" :key="thickness" :style="cell">
        <CoreRing :value="64" :size="72" :thickness="thickness" tone="info" />
        <span class="text-ui-xs text-fg-faint">:thickness="{{ thickness }}"</span>
      </div>
    </KitSection>

    <KitSection label="The centre is a slot" :gap="30" note="A countdown, a fraction, a unit — anything that fits.">
      <div :style="cell">
        <CoreRing :value="8" :max="10" :size="72" :thickness="5" tone="warning">
          <span class="core-display core-display--sm">8s</span>
        </CoreRing>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">a cooldown, counting down</span>
      </div>
      <div :style="cell">
        <CoreRing :value="3" :max="4" :size="72" :thickness="5">
          <span class="core-display core-display--sm">3/4</span>
        </CoreRing>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">heist prep stages done</span>
      </div>
      <div :style="cell">
        <CoreRing :value="46" :size="72" :thickness="5" color="#9d7bff">
          <CoreIcon name="fuel" size="lg" />
        </CoreRing>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">a faction colour via `color`</span>
      </div>
      <div :style="cell">
        <CoreRing :value="100" :size="72" :thickness="5" tone="success">
          <CoreIcon name="check" size="lg" />
        </CoreRing>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">finished</span>
      </div>
    </KitSection>
  </KitStage>
</template>
