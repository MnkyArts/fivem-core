<script setup>
// CoreDrawer gallery (DESIGN §37.5, Feedback). A drawer is always pinned to a viewport edge over
// the full height, so there is no honest "inline" version of it: the right-hand sheet opens on
// mount instead, which is what the static screenshot has to show. The buttons cover the rest.
import { onMounted, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const rightOpen = ref(false)
const leftOpen = ref(false)
const wideOpen = ref(false)
const bareOpen = ref(false)
const lastReason = ref('—')

const onClose = (reason) => { lastReason.value = reason }

const LOG = [
  ['02:14', 'Marek', 'Dropped 12 crates at the Paleto lockup.'],
  ['01:58', 'Ines', 'Paid $4,000 into the crew account.'],
  ['01:31', 'You', 'Promoted Ines to quartermaster.'],
  ['00:47', 'Dag', 'Lost the Sultan RS to a police impound.'],
  ['00:12', 'Marek', 'Opened a contract with Bennys.'],
]

onMounted(() => { rightOpen.value = true })
</script>

<template>
  <KitStage
    title="Drawer"
    description="The side sheet: the dialog's panel language pinned to an edge over the full height, entering
      with the 18 px slide of §37.1. Same Escape layer, same focus trap, same close reasons."
  >
    <KitSection label="Open one" :gap="12">
      <CoreButton icon="list" @click="rightOpen = true">Crew log (right)</CoreButton>
      <CoreButton icon="filter" @click="leftOpen = true">Filters (left)</CoreButton>
      <CoreButton variant="ghost" icon="map" @click="wideOpen = true">Wide, 560</CoreButton>
      <CoreButton variant="ghost" icon="eye" @click="bareOpen = true">No scrim</CoreButton>
      <span class="core-label" style="margin-left: 8px">last reason — {{ lastReason }}</span>
    </KitSection>

    <KitSection label="What it is for" layout="column" :gap="10">
      <p class="core-text" style="max-width: 70ch; margin: 0">
        A drawer holds the long list a dialog cannot: a crew log, a map filter column, a vehicle's
        modification history. It keeps the screen behind it visible, so the player never loses the
        place they were looking at.
      </p>
      <p class="core-flavor" style="margin: 0">The right-hand sheet is open on mount — press Escape to send it away.</p>
    </KitSection>

    <CoreDrawer v-model:open="rightOpen" title="Crew log" subtitle="Del Perro · last 4 hours" @close="onClose">
      <div
        v-for="row in LOG"
        :key="row[0]"
        class="flex items-start"
        style="gap: 12px; padding: 13px 0; border-top: 1px solid var(--color-border)"
      >
        <span class="core-num" style="flex: none; font-size: 14px; color: var(--color-fg-faint)">{{ row[0] }}</span>
        <span style="min-width: 0">
          <span class="core-label" style="margin: 0; color: var(--color-fg)">{{ row[1] }}</span>
          <span class="core-text" style="display: block; font-size: 14px">{{ row[2] }}</span>
        </span>
      </div>
      <template #footer>
        <CoreButton variant="ghost" size="sm" @click="rightOpen = false">Close</CoreButton>
        <CoreButton variant="primary" size="sm">Export</CoreButton>
      </template>
    </CoreDrawer>

    <CoreDrawer v-model:open="leftOpen" side="left" :width="320" title="Map filters" subtitle="Six categories" @close="onClose">
      <p class="core-text" style="margin: 0 0 12px">
        A left sheet enters with <code>core-slide-right</code>; the hairline sits on its inner edge so
        the screen behind it keeps its own frame.
      </p>
      <p class="core-flavor" style="margin: 0">Quests · Locations · Fast travel · Shops · Activities · Collectibles</p>
    </CoreDrawer>

    <CoreDrawer v-model:open="wideOpen" :width="560" title="Vehicle history" subtitle="Sultan RS · plate 46 TRV" @close="onClose">
      <p class="core-text" style="margin: 0">
        560 px of room for a table. The width prop is plain px, so a page can match it to whatever it
        has to show without touching the kit CSS.
      </p>
    </CoreDrawer>

    <CoreDrawer v-model:open="bareOpen" :backdrop="false" :width="360" title="No scrim" subtitle="The page stays usable" @close="onClose">
      <p class="core-text" style="margin: 0">
        With <code>:backdrop="false"</code> the layer is click-through: the sheet floats over a screen
        the player can still work with. Escape and the ✕ still close it.
      </p>
    </CoreDrawer>
  </KitStage>
</template>
