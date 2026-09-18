<script setup>
// ChipsGallery — the quest filter row of the mockups plus every CoreChips mode: single, multiple,
// allowEmpty, sizes, counts, icons, wrap and disabled (DESIGN §37.5, Navigation).
// Global tags only (CoreChips, CoreIcon); KitStage/KitSection are story plumbing.
import { onMounted, ref, useTemplateRef } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const QUESTS = ['All', 'Main', 'Side', 'Completed']

const CATEGORY = [
  { value: 'all', label: 'All', count: 38 },
  { value: 'weapons', label: 'Weapons', count: 6 },
  { value: 'gear', label: 'Gear', count: 11 },
  { value: 'meds', label: 'Consumables', count: 14 },
  { value: 'junk', label: 'Junk', count: 7 },
]

const MARKERS = [
  { value: 'quests', label: 'Quests', icon: 'quest' },
  { value: 'shops', label: 'Shops', icon: 'store' },
  { value: 'garages', label: 'Garages', icon: 'garage' },
  { value: 'fuel', label: 'Fuel', icon: 'fuel' },
  { value: 'hospital', label: 'Hospital', icon: 'hospital' },
]

const RANKS = [
  { value: 'recruit', label: 'Recruit' },
  { value: 'member', label: 'Member' },
  { value: 'officer', label: 'Officer' },
  { value: 'boss', label: 'Boss', disabled: true },
]

const LONG = [
  'All Vehicles', 'Sports', 'Super', 'Muscle', 'Off-road', 'Motorcycles',
  'Emergency', 'Commercial', 'Boats', 'Helicopters', 'Planes',
]

const quest = ref('All')
const category = ref('all')
const markers = ref(['quests', 'shops', 'fuel'])
const rank = ref('member')
const optional = ref('Side')
const sizeSm = ref('Main')
const sizeLg = ref('All')
const long = ref('Sports')
const segmented = ref('All')
const focused = ref('Main')

// :focus-visible is keyboard-only, so the gallery puts the focus there itself on mount.
const focusDemo = useTemplateRef('focusDemo')
onMounted(() => {
  const chip = focusDemo.value && focusDemo.value.querySelector('.core-chip:not(.is-active)')
  if (chip) chip.focus({ preventScroll: true })
})
</script>

<template>
  <KitStage
    title="CoreChips"
    description="Filter chips and segmented controls. The selected chip is solid coral with no border, the
      rest are outlined wells. ←/→ move the focus only — Space or Enter is what toggles a chip."
  >
    <KitSection label="The quest filter (single, allowEmpty off)" layout="column" :gap="12">
      <CoreChips v-model="quest" :items="QUESTS" />
      <p class="core-flavor">value → {{ quest }}</p>
    </KitSection>

    <KitSection label="Counts" layout="column" :gap="0" note="`count` on an item prints after the label.">
      <CoreChips v-model="category" :items="CATEGORY" />
    </KitSection>

    <KitSection label="multiple — the map filter row" layout="column" :gap="12" note="The model is an array; the last chip cannot be switched off without allowEmpty.">
      <CoreChips v-model="markers" :items="MARKERS" multiple />
      <p class="core-flavor">value → [{{ markers.join(', ') }}]</p>
    </KitSection>

    <KitSection label="allowEmpty — clicking the active chip clears it" layout="column" :gap="12">
      <CoreChips v-model="optional" :items="QUESTS" allow-empty />
      <p class="core-flavor">value → {{ optional === null ? 'null' : optional }}</p>
    </KitSection>

    <KitSection label="Sizes" layout="column" :gap="18" note="sm 28 px · md 36 px · lg 44 px.">
      <CoreChips v-model="sizeSm" :items="QUESTS" size="sm" />
      <CoreChips v-model="quest" :items="QUESTS" />
      <CoreChips v-model="sizeLg" :items="QUESTS" size="lg" />
    </KitSection>

    <KitSection label="Disabled item" layout="column" :gap="0" note="Boss needs rank 5 — no hover, no focus stop.">
      <CoreChips v-model="rank" :items="RANKS" />
    </KitSection>

    <KitSection
      label="stretch and minWidth — the map filter bar"
      layout="column"
      :gap="18"
      note="stretch makes every chip an equal cell across the panel; minWidth (118 px below) is the same idea without filling the row."
    >
      <div style="width: 520px">
        <CoreChips v-model="segmented" :items="QUESTS" stretch />
      </div>
      <CoreChips v-model="segmented" :items="QUESTS" :min-width="118" />
    </KitSection>

    <KitSection label="wrap — a long category row" layout="column" :gap="0">
      <div style="width: 620px">
        <CoreChips v-model="long" :items="LONG" wrap size="sm" />
      </div>
    </KitSection>

    <KitSection label="States" layout="column" :gap="0" note="ALL is focused on mount — the 2 px accent-hi ring, offset 2 px. Hover lifts the border to border-strong and the label to fg; BOSS above is the disabled look.">
      <div ref="focusDemo">
        <CoreChips v-model="focused" :items="QUESTS" />
      </div>
    </KitSection>
  </KitStage>
</template>
