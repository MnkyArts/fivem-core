<script setup>
// CorePopover gallery (DESIGN §37.5, Feedback) — the three triggers, the eight placements and the
// two things that are easy to get wrong: a popover that matches its anchor's width, and one that
// lives INSIDE a dialog, where the first Escape has to close the popover and the second the dialog.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const PLACEMENTS = ['top', 'top-start', 'bottom', 'bottom-end', 'left', 'left-start', 'right', 'right-end']

const manualOpen = ref(false)
const layerOpen = ref(false)
const insideOpen = ref(false)
</script>

<template>
  <KitStage
    title="Popover"
    description="An opaque floating panel glued to its trigger: teleported into #core-overlays, placed by hand
      (Chromium 103 has no anchor positioning) and flipped away from the viewport edge on its own."
  >
    <KitSection label="Triggers" :gap="12" note="click toggles · hover opens with a 120 ms grace on the way out · manual obeys v-model:open">
      <CorePopover trigger="click">
        <template #trigger><CoreButton icon="user">Marek Novak</CoreButton></template>
        <p class="core-label" style="margin: 0 0 6px; color: var(--color-fg)">Marek Novak</p>
        <p style="margin: 0">Quartermaster · rank 4 · on duty at the Sandy Shores garage since 01:20.</p>
      </CorePopover>

      <CorePopover trigger="hover" placement="top">
        <template #trigger><CoreButton variant="ghost" icon="info">Hover me</CoreButton></template>
        <p style="margin: 0">
          The panel takes the mouse too, so a link inside it is reachable — leaving both closes it
          after 120 ms.
        </p>
      </CorePopover>

      <CorePopover v-model:open="manualOpen" trigger="manual" placement="bottom-end">
        <template #trigger><CoreButton variant="secondary" icon="settings">Anchor only</CoreButton></template>
        <p style="margin: 0 0 10px">Nothing on the trigger toggles this one — the page owns it.</p>
        <CoreButton size="sm" variant="ghost" @click="manualOpen = false">Close it</CoreButton>
      </CorePopover>

      <CoreButton variant="primary" size="sm" @click="manualOpen = !manualOpen">
        {{ manualOpen ? 'Close' : 'Open' }} the manual one
      </CoreButton>
    </KitSection>

    <KitSection label="Placements" layout="grid" :columns="4" :gap="12" note="each one flips to the opposite side when the viewport edge is in the way">
      <CorePopover v-for="p in PLACEMENTS" :key="p" :placement="p">
        <template #trigger><CoreButton size="sm" variant="secondary" block>{{ p }}</CoreButton></template>
        <p style="margin: 0">Placed <b class="text-fg">{{ p }}</b> of its anchor, 8 px away.</p>
      </CorePopover>
    </KitSection>

    <KitSection label="Match width" layout="column" :gap="12" note="matchWidth makes the panel at least as wide as the trigger — a dropdown under a field">
      <div style="width: 420px; max-width: 100%">
        <CorePopover match-width placement="bottom-start" style="width: 100%">
          <template #trigger><CoreButton block icon="garage">Legion Square garage</CoreButton></template>
          <p style="margin: 0 0 8px">Eight of ten bays used. The Kuruma is still at the impound.</p>
          <p class="core-flavor" style="margin: 0">Storage fees are charged at 04:00.</p>
        </CorePopover>
      </div>
    </KitSection>

    <KitSection label="Escape layers" :gap="12" note="open the dialog, open the popover inside it: the first Escape closes the popover, the second the dialog">
      <CoreButton variant="primary" icon="grid" @click="layerOpen = true">Popover inside a dialog</CoreButton>
    </KitSection>

    <CoreDialog v-model:open="layerOpen" title="Transfer funds" subtitle="Crew account · $18,240">
      <p class="core-text" style="margin: 0 0 14px">
        The popover below is teleported out of this panel, but it registers the newer Escape layer —
        so the key reaches it first and never touches the dialog underneath.
      </p>
      <CorePopover v-model:open="insideOpen" placement="bottom-start">
        <template #trigger><CoreButton size="sm" icon="users">Pick a member</CoreButton></template>
        <p class="core-label" style="margin: 0 0 6px; color: var(--color-fg)">Crew</p>
        <p style="margin: 0">Marek · Ines · Dag · Sofia</p>
      </CorePopover>
      <template #footer>
        <CoreButton variant="ghost" size="sm" @click="layerOpen = false">Cancel</CoreButton>
        <CoreButton variant="primary" size="sm" @click="layerOpen = false">Transfer</CoreButton>
      </template>
    </CoreDialog>
  </KitStage>
</template>
