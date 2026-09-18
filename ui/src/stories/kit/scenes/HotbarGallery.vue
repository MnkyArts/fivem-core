<script setup>
// HotbarGallery — CoreHotbar (DESIGN §37.5, Game).
// Shoot this one with ?bg=keyart: the hotbar is the only slot layout that sits on the bare game,
// so its panel fill and its shadow can only be judged with the world behind it.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

import pistol from '../assets/item-pistol.jpg'
import medkit from '../assets/item-medkit.jpg'
import water from '../assets/item-water.jpg'
import binoculars from '../assets/item-binoculars.jpg'
import ammo from '../assets/item-ammo.jpg'
import knife from '../assets/item-knife.jpg'
import jerrycan from '../assets/item-jerrycan.jpg'

// The four cells of mockup 2, in order.
const belt = [
  { id: 'pistol', image: pistol, count: 12, label: 'Combat Pistol' },
  { id: 'medkit', image: medkit, count: 4, label: 'Med Kit' },
  { id: 'water', image: water, count: 6, label: 'Bottled Water' },
  { id: 'binoculars', image: binoculars, count: 1, label: 'Field Binoculars' },
]

const loaded = [
  { id: 'pistol', image: pistol, count: 12, rarity: 'rare', durability: 0.72, label: 'Combat Pistol' },
  { id: 'knife', image: knife, rarity: 'uncommon', durability: 0.34, label: 'Folding Knife' },
  { id: 'ammo', image: ammo, count: 60, label: 'Rifle Ammo' },
  { id: 'jerrycan', image: jerrycan, disabled: true, label: 'Jerrycan — too heavy to carry' },
  { id: 'free', empty: true },
  { id: 'free2', empty: true },
]

const active = ref(0)
</script>

<template>
  <KitStage
    title="Hotbar"
    description="The belt of mockup 2: CoreSlot cells in the 5 / 4 landscape ratio with a solid key cap in
      the top-left corner and the stack count bottom right. `active` is an index — the number key the player
      pressed — and that cell wears the coral frame."
  >
    <KitSection label="Mockup 2 — four cells, nothing drawn" layout="column" :gap="16">
      <CoreHotbar :items="belt" :active="-1" />
    </KitSection>

    <KitSection label="Drawn weapon" layout="column" :gap="16" note="click a cell (or use the buttons) — `active` moves the frame">
      <CoreHotbar :items="belt" :active="active" @select="(i) => (active = i)" />
      <div class="flex items-center" style="gap: 8px">
        <button
          v-for="i in [0, 1, 2, 3]"
          :key="i"
          type="button"
          class="core-label bg-panel-raise border border-border rounded-ui-sm text-fg"
          style="padding: 7px 14px; cursor: pointer"
          @click="active = i"
        >{{ i + 1 }}</button>
        <button
          type="button"
          class="core-label border border-border rounded-ui-sm text-fg-dim"
          style="padding: 7px 14px; cursor: pointer; background: transparent"
          @click="active = -1"
        >Holster</button>
        <span class="text-fg-dim text-ui-sm">active = {{ active }}</span>
      </div>
    </KitSection>

    <KitSection label="Full belt — rarity, wear, a locked cell and two free ones" layout="column" :gap="16">
      <CoreHotbar :items="loaded" :active="0" />
    </KitSection>

    <KitSection label="Sizes and labels" layout="column" :gap="16" note="`slotWidth` scales the cell, `keys` renames the caps">
      <CoreHotbar :items="belt" :slot-width="72" :active="1" />
      <CoreHotbar :items="belt" :slot-width="120" :keys="['Q', 'E', 'R', 'F']" :active="2" />
      <CoreHotbar :items="belt" :slot-width="96" ratio="1 / 1" :active="3" />
    </KitSection>
  </KitStage>
</template>
