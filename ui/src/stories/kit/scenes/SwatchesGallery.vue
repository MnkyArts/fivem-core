<script setup>
// SwatchesGallery — CoreSwatches (DESIGN §37.5, Forms — choice).
// Paint pickers are where the "a very dark swatch still needs an edge" rule earns its keep, so the
// first row is deliberately full of near-blacks. Every swatch is a <button aria-pressed>: one tab
// stop for the group, arrows rove and pick.
import { computed, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const PAINT = [
  { value: 'black', color: '#0a0a0c', label: 'Carbon Black' },
  { value: 'graphite', color: '#23272c', label: 'Graphite' },
  { value: 'silver', color: '#c7ccd2', label: 'Brushed Silver' },
  { value: 'white', color: '#f2f3f5', label: 'Frost White' },
  { value: 'carmine', color: '#8c1c13', label: 'Carmine' },
  { value: 'coral', color: '#f6503f', label: 'Sunset Coral' },
  { value: 'sand', color: '#c2a06a', label: 'Desert Sand' },
  { value: 'olive', color: '#4a5240', label: 'Olive Drab' },
  { value: 'navy', color: '#1d3557', label: 'Midnight Navy' },
  { value: 'teal', color: '#1f7a72', label: 'Vice Teal' },
  { value: 'purple', color: '#5b3a8c', label: 'Ultra Violet' },
  { value: 'gold', color: '#d9a441', label: 'Bullion Gold' },
]

const HAIR = ['#120d0a', '#3a2a1d', '#6b4a2b', '#a87b4a', '#d9c9a3', '#b64a2a', '#8f8f93']

const FACTION = [
  { value: 'red', color: '#f6503f', label: 'Vagos Coral' },
  { value: 'green', color: '#3fd67f', label: 'Families Green' },
  { value: 'blue', color: '#55b6f7', label: 'Ballas Blue' },
  { value: 'violet', color: '#b68cff', label: 'Lost Violet' },
  { value: 'amber', color: '#f5a623', label: 'Triad Amber' },
  { value: 'locked', color: '#2a3138', label: 'Reserved', disabled: true },
]

const paint = ref('coral')
const hair = ref('#6b4a2b')
const faction = ref('blue')
const trim = ref('#a87b4a')
const small = ref('#b64a2a')

const paintLabel = computed(() => (PAINT.find((p) => p.value === paint.value) || {}).label || '—')
</script>

<template>
  <KitStage
    title="Swatches"
    description="A colour picker: real buttons with aria-pressed, one tab stop for the whole group, arrows roving
      and picking as they go. Selected = a 2 px ink gap and a 2 px accent-hi ring; every swatch keeps a 1 px light
      inset line so a near-black paint still has an edge."
  >
    <KitSection label="Vehicle paint" layout="column" :gap="0" note="12 colours in a wrapping row, 30 px squares, radius 3">
      <CoreSwatches v-model="paint" :items="PAINT" />
      <p class="core-label" style="margin-top: 16px">{{ paintLabel }}</p>
    </KitSection>

    <KitSection label="Plain strings" layout="column" :gap="0" note="a string item is both the value and the paint — the shortest way to write a picker">
      <CoreSwatches v-model="hair" :items="HAIR" shape="circle" />
      <p class="core-label" style="margin-top: 16px">hair — {{ hair }}</p>
    </KitSection>

    <KitSection label="Sizes and shapes" layout="column" :gap="20" note="22 / 30 / 38 px, square (radius 3) or circle">
      <CoreSwatches v-model="small" :items="HAIR" size="sm" />
      <CoreSwatches v-model="trim" :items="HAIR" size="md" />
      <CoreSwatches v-model="trim" :items="HAIR" size="lg" shape="circle" />
    </KitSection>

    <KitSection label="Grid and a disabled swatch" layout="column" :gap="0" note="`columns` lays the group out in a grid; a disabled item cannot be picked or roved onto">
      <CoreSwatches v-model="faction" :items="FACTION" :columns="3" size="lg" />
      <p class="core-label" style="margin-top: 16px">faction colour — {{ faction }}</p>
    </KitSection>

    <KitSection label="Disabled group" layout="column" :gap="0" note="the whole picker dims to 0.45 — a paint you have not unlocked yet">
      <CoreSwatches :model-value="'coral'" :items="PAINT" disabled />
    </KitSection>
  </KitStage>
</template>
