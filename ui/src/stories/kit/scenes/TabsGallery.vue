<script setup>
// TabsGallery — every CoreTabs size, the separator and stretch variants, badges, a disabled tab and
// the clickable key caps (DESIGN §37.5, Navigation).
// Global tags only (CoreTabs, CoreKey, CoreIcon); KitStage/KitSection are story plumbing.
import { onMounted, ref, useTemplateRef } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const SCREENS = ['Map', 'Inventory', 'Character', 'Skills', 'Journal']
const MAP_SCREENS = ['Map', 'Inventory', 'Character', 'Quests', 'Skills', 'Journal']

const SHOP = [
  { value: 'weapons', label: 'Weapons', icon: 'pistol' },
  { value: 'ammo', label: 'Ammunition', icon: 'ammo', badge: 12 },
  { value: 'armour', label: 'Armour', icon: 'shield' },
  { value: 'illegal', label: 'Black Market', icon: 'lock', disabled: true },
]

const GARAGE = [
  { value: 'stored', label: 'In Garage', badge: 14 },
  { value: 'out', label: 'Out', badge: 2 },
  { value: 'impound', label: 'Impound' },
]

const header = ref('Inventory')
const mapHeader = ref('Map')
const shop = ref('ammo')
const garage = ref('stored')
const small = ref('Skills')
const medium = ref('Inventory')
const large = ref('Character')
const bare = ref('Journal')
const keyed = ref('Character')
const focused = ref('Map')
const changed = ref('—')

// The focus ring is keyboard-only, so the gallery has to put it there itself: focusing the active
// tab on mount (before any pointer input) is what :focus-visible matches.
const focusDemo = useTemplateRef('focusDemo')
onMounted(() => {
  const tab = focusDemo.value && focusDemo.value.querySelector('.core-tab.is-active')
  if (tab) tab.focus({ preventScroll: true })
})
</script>

<template>
  <KitStage
    title="CoreTabs"
    description="The screen switcher of the inventory and map mockups: dim condensed caps, the active one
      white over a glowing coral underline that sits on the hairline. One tab stop, ←/→ Home/End rove."
  >
    <KitSection label="md — the inventory header" layout="column" :gap="18" note="Default: line on, no separators.">
      <CoreTabs v-model="header" :items="SCREENS" @change="changed = $event" />
      <p class="core-flavor">change → {{ changed }}</p>
    </KitSection>

    <KitSection label="separators — the map header" layout="column" :gap="0" note="A hairline sits in the middle of every gap.">
      <CoreTabs v-model="mapHeader" :items="MAP_SCREENS" separators />
    </KitSection>

    <KitSection label="Icons, badges and a disabled tab" layout="column" :gap="0">
      <CoreTabs v-model="shop" :items="SHOP" />
    </KitSection>

    <KitSection label="Sizes" layout="column" :gap="24" note="sm 14 px · md 17 px · lg 20 px label.">
      <CoreTabs v-model="small" :items="SCREENS" size="sm" />
      <CoreTabs v-model="medium" :items="SCREENS" />
      <CoreTabs v-model="large" :items="SCREENS" size="lg" />
    </KitSection>

    <KitSection label="stretch — a segmented header inside a panel" layout="column" :gap="0" note="Tabs share the width equally.">
      <div
        style="width: 520px; padding: 4px 16px 0; border: 1px solid var(--color-border);
          border-radius: var(--radius-ui); background: var(--color-panel)"
      >
        <CoreTabs v-model="garage" :items="GARAGE" stretch />
        <p class="core-text" style="padding: 14px 0 16px; font-size: var(--text-ui-sm)">
          14 vehicles stored at Northern Ridge. Impound releases cost $250.
        </p>
      </div>
    </KitSection>

    <KitSection label="Key caps — a controller / keyboard header" layout="column" :gap="0" note="prevKey / nextKey are clickable and step the selection.">
      <CoreTabs v-model="keyed" :items="SCREENS" prev-key="Q" next-key="E" separators />
    </KitSection>

    <KitSection label="line = false" layout="column" :gap="0" note="No hairline; the underline still glows under the active tab.">
      <CoreTabs v-model="bare" :items="SCREENS" :line="false" />
    </KitSection>

    <KitSection label="States" layout="column" :gap="0" note="MAP is focused on mount — the 2 px accent-hi ring, offset 2 px. Hover any tab to see it lift to fg; BLACK MARKET above is the disabled look.">
      <div ref="focusDemo">
        <CoreTabs v-model="focused" :items="SCREENS" />
      </div>
    </KitSection>
  </KitStage>
</template>
