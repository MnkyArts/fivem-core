<script setup>
// SlotGallery — CoreSlot and CoreSlotGrid (DESIGN §37.5, Game).
// The first section rebuilds the 4 x 3 bag of mockup 3 cell for cell, so the fill, the hairline
// and the coral frame can be diffed against the screenshot; the rest proves every state.
import { onMounted, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

import medkit from '../assets/item-medkit.jpg'
import water from '../assets/item-water.jpg'
import ammo from '../assets/item-ammo.jpg'
import tape from '../assets/item-tape.jpg'
import knife from '../assets/item-knife.jpg'
import jerrycan from '../assets/item-jerrycan.jpg'
import toolbox from '../assets/item-toolbox.jpg'
import pistol from '../assets/item-pistol.jpg'
import binoculars from '../assets/item-binoculars.jpg'

const bag = [
  { id: 'medkit', image: medkit, count: 3, label: 'Med Kit' },
  { id: 'water', image: water, count: 4, label: 'Bottled Water' },
  { id: 'ammo', image: ammo, count: 60, label: 'Rifle Ammo' },
  { id: 'tape', image: tape, label: 'Duct Tape' },
  { id: 'knife', image: knife, label: 'Folding Knife' },
  { id: 'jerrycan', image: jerrycan, label: 'Jerrycan' },
  { id: 'toolbox', image: toolbox, count: 2, label: 'Toolbox' },
]

const selected = ref('medkit')

const rarities = [
  { rarity: 'common', image: tape, label: 'Duct Tape' },
  { rarity: 'uncommon', image: water, count: 4, label: 'Bottled Water' },
  { rarity: 'rare', image: binoculars, label: 'Field Binoculars' },
  { rarity: 'epic', image: pistol, count: 12, label: 'Combat Pistol' },
  { rarity: 'legendary', image: medkit, count: 3, label: 'Trauma Kit' },
]

const wear = [
  { durability: 1, label: 'Pristine' },
  { durability: 0.62, label: 'Worn' },
  { durability: 0.4, label: 'Damaged' },
  { durability: 0.12, label: 'Breaking' },
]

// The focus ring is keyboard-only, so the gallery has to put it there itself: focusing on mount
// (before any pointer event) is what Chromium counts as :focus-visible. preventScroll keeps a
// full-page screenshot starting at the top.
const focusDemo = ref(null)
onMounted(() => {
  const el = focusDemo.value && focusDemo.value.$el ? focusDemo.value.$el : focusDemo.value
  if (el && typeof el.focus === 'function') el.focus({ preventScroll: true })
})
</script>

<template>
  <KitStage
    title="Slot"
    description="The item cell of mockup 3: a barely-lighter tile with a bright hairline, the stack count
      bottom right in display voice, and — when it is the selected one — a coral frame that glows inside and
      out. CoreSlotGrid lays them out, pads the bag to its capacity and roves the arrow keys in 2D."
  >
    <KitSection label="Inventory grid — 4 x 3, 7 of 12 slots used" layout="column" :gap="14">
      <div class="bg-panel border border-border rounded-ui" style="width: 790px; padding: 24px">
        <h2 class="core-display core-display--md">Inventory</h2>
        <p class="core-eyebrow" style="margin: 10px 0 20px">Gear up for what&rsquo;s next.</p>
        <CoreSlotGrid v-model:selected="selected" :items="bag" :columns="4" :slots="12" />
      </div>
      <p class="text-fg-dim text-ui-sm">
        <span class="core-label" style="display: inline">selected</span>
        &nbsp;{{ selected === null ? 'nothing' : selected }} &middot; click a cell, or Tab into the grid and
        walk it with the arrow keys.
      </p>
    </KitSection>

    <KitSection
      label="States"
      layout="row"
      :gap="14"
      note="idle · selected · focused (the ring is put there on mount — it is keyboard-only) · disabled · empty · hotkey · badge. Hover any cell for border-strong + white 6 %."
    >
      <CoreSlot :image="medkit" :count="3" :size="118" label="Idle" />
      <CoreSlot :image="medkit" :count="3" :size="118" selected label="Selected" />
      <CoreSlot ref="focusDemo" :image="medkit" :count="3" :size="118" label="Focused" />
      <CoreSlot :image="medkit" :count="3" :size="118" disabled label="Disabled — soaked, unusable" />
      <CoreSlot :size="118" empty />
      <CoreSlot :image="pistol" :count="12" hotkey="1" :size="118" label="Combat Pistol" />
      <CoreSlot :image="toolbox" :count="2" badge="New" :size="118" label="Toolbox" />
    </KitSection>

    <KitSection label="Rarity" layout="row" :gap="14" note="a 2 px line and a faint bloom along the bottom, in the rarity colour">
      <div v-for="item in rarities" :key="item.rarity" style="width: 118px">
        <CoreSlot v-bind="item" :size="118" />
        <p class="core-label" style="margin-top: 8px; text-align: center">{{ item.rarity }}</p>
      </div>
    </KitSection>

    <KitSection label="Durability" layout="row" :gap="14" note="green, amber under 50 %, red under 20 % — and it sits above the rarity line">
      <div v-for="item in wear" :key="item.label" style="width: 118px">
        <CoreSlot :image="knife" :durability="item.durability" :size="118" :label="item.label" />
        <p class="core-label" style="margin-top: 8px; text-align: center">{{ item.label }}</p>
      </div>
      <div style="width: 118px">
        <CoreSlot :image="jerrycan" :durability="0.34" rarity="epic" :size="118" label="Reinforced Jerrycan" />
        <p class="core-label" style="margin-top: 8px; text-align: center">Epic + wear</p>
      </div>
    </KitSection>

    <KitSection label="No art" layout="row" :gap="14" note="a registry glyph stands in for missing item art; an empty cell draws nothing at all">
      <CoreSlot icon="medkit" :count="3" :size="118" label="Med Kit" />
      <CoreSlot icon="ammo" :count="60" :size="118" rarity="uncommon" label="Rifle Ammo" />
      <CoreSlot icon="fuel" :size="118" disabled label="Fuel Can — empty" />
      <CoreSlot :size="118" empty />
    </KitSection>

    <KitSection label="Size and ratio" layout="row" :gap="14" note="`size` is a px width, `ratio` the aspect — 5 / 4 is the hotbar cell">
      <CoreSlot :image="water" :count="4" :size="72" label="72 px" />
      <CoreSlot :image="water" :count="4" :size="96" label="96 px" />
      <CoreSlot :image="water" :count="4" :size="140" label="140 px" />
      <CoreSlot :image="water" :count="4" :size="140" ratio="5 / 4" hotkey="3" label="140 px, 5 / 4" />
    </KitSection>
  </KitStage>
</template>
