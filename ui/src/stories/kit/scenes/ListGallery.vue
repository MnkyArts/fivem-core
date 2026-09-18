<script setup>
// ListGallery — CoreList and CoreListItem (DESIGN §37.5, Game).
// The first section is the quest list of mockup 4: thumb, tone glyph, Title Case condensed
// title, dim subtitle, distance bottom right, the first row framed in coral.
import { onMounted, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

import quest1 from '../assets/quest-1.jpg'
import quest2 from '../assets/quest-2.jpg'
import quest3 from '../assets/quest-3.jpg'
import quest4 from '../assets/quest-4.jpg'

const quests = [
  { id: 'brighter', image: quest1, icon: 'quest', iconTone: 'accent', title: 'A Brighter Tomorrow', subtitle: 'Main Story', trailing: '842 m' },
  { id: 'supply', image: quest2, icon: 'map-marker', iconTone: 'warning', title: 'Supply Lines', subtitle: 'Side Quest', trailing: '2.4 km' },
  { id: 'static', image: quest3, icon: 'radio', iconTone: 'info', title: 'Nothing But Static', subtitle: 'Side Quest', trailing: '5.1 km' },
  { id: 'longroad', image: quest4, icon: 'check-circle', iconTone: 'success', title: 'The Long Road Home', subtitle: 'Completed', trailing: '—', completed: true },
]

const selected = ref('brighter')
const dense = ref('supply')

const contracts = [
  { id: 'haul', image: quest2, icon: 'truck', iconTone: 'info', title: 'Night Haul to Paleto', subtitle: 'Trucking · 3 stops', trailing: '$2,400' },
  { id: 'chop', image: quest3, icon: 'car', iconTone: 'warning', title: 'Chop Shop Order', subtitle: 'Criminal · Sandy Shores', trailing: '$5,150' },
  { id: 'escort', image: quest4, icon: 'shield', iconTone: 'accent', title: 'Convoy Escort', subtitle: 'Faction · Needs 3 players', trailing: 'Locked', disabled: true },
]

// :focus-visible is keyboard-only, so the gallery focuses one row on mount (before any pointer
// event) to put the ring on the page. preventScroll keeps a full-page screenshot at the top.
const focusDemo = ref(null)
onMounted(() => {
  const el = focusDemo.value && focusDemo.value.$el ? focusDemo.value.$el : focusDemo.value
  if (el && typeof el.focus === 'function') el.focus({ preventScroll: true })
})
</script>

<template>
  <KitStage
    title="List"
    description="Rich rows for a quest log, a contract board, a vehicle garage. The root class is
      core-listview, never core-list — that legacy name belongs to the old menu &lt;ul&gt;. One tab stop,
      the arrow keys rove, Enter selects, and the selected row is framed in coral instead of filled."
    :width="1000"
  >
    <KitSection label="Quest log — mockup 4" layout="column" :gap="14">
      <div class="bg-panel border border-border rounded-ui" style="width: 720px; padding: 20px">
        <CoreList v-model="selected" :items="quests" @select="() => {}" />
      </div>
      <p class="text-fg-dim text-ui-sm">
        <span class="core-label" style="display: inline">selected</span>
        &nbsp;{{ selected }} &middot; the last row is `completed`: dimmed thumb and title.
      </p>
    </KitSection>

    <KitSection label="Dividers" layout="column" :gap="14" note="`dividers` trades the cards for one hairline between rows — except around the selected one">
      <div class="bg-panel border border-border rounded-ui" style="width: 720px; padding: 8px 16px">
        <CoreList v-model="dense" :items="quests" dividers />
      </div>
    </KitSection>

    <KitSection label="Contracts — a disabled row" layout="column" :gap="14">
      <div style="width: 720px">
        <CoreList :items="contracts" />
      </div>
    </KitSection>

    <KitSection
      label="Single items"
      layout="column"
      :gap="12"
      note="CoreListItem on its own — idle · selected · focused (ring put there on mount) · disabled · completed · read-only. Hover any row for border-strong + white 5 %."
    >
      <div style="width: 560px; display: flex; flex-direction: column; gap: 10px">
        <CoreListItem ref="focusDemo" icon="crate" icon-tone="neutral" title="Scrap Metal" subtitle="Materials · 12 kg" trailing="x42" />
        <CoreListItem title="Anonymous Tip" subtitle="No map marker yet" trailing="?" />
        <CoreListItem icon="bolt" icon-tone="stamina" title="Overcharged Battery" subtitle="Rare component" selected trailing="1.2 km" />
        <CoreListItem icon="lock" icon-tone="danger" title="Sealed Bunker" subtitle="Requires a keycard" disabled trailing="Locked" />
        <CoreListItem icon="check-circle" icon-tone="success" title="Fuel Run" subtitle="Completed 2 h ago" completed trailing="+$820" />
        <CoreListItem :interactive="false" icon="info" icon-tone="info" title="Read Only Row" subtitle="`interactive` false — a &lt;div&gt;, no hover, no focus" trailing="—" />
      </div>
    </KitSection>
  </KitStage>
</template>
