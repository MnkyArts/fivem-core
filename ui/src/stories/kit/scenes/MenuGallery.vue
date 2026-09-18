<script setup>
// MenuGallery — every CoreMenu size, state and both gradients, plus the legacy .core-list markup
// the shell's keyboard menu still renders (DESIGN §37.5, Navigation).
// Global tags only (CoreMenu, CoreIcon); KitStage/KitSection are story plumbing.
import { onMounted, ref, useTemplateRef } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const MAIN = [
  { value: 'continue', label: 'Continue', icon: 'play' },
  { value: 'load', label: 'Load Game', icon: 'folder' },
  { value: 'settings', label: 'Settings', icon: 'settings' },
  { value: 'exit', label: 'Exit', icon: 'exit' },
]

const CATEGORIES = [
  { value: 'all', label: 'All', icon: 'grid' },
  { value: 'weapons', label: 'Weapons', icon: 'pistol' },
  { value: 'gear', label: 'Gear', icon: 'backpack' },
  { value: 'consumables', label: 'Consumables', icon: 'medkit' },
  { value: 'keys', label: 'Key Items', icon: 'key' },
]

const SERVICES = [
  { value: 'garage', label: 'Vehicle Garage', icon: 'garage', description: '14 vehicles stored', trailing: 'Level 3' },
  { value: 'bank', label: 'Faction Bank', icon: 'bank', description: 'Deposit, withdraw, payroll', trailing: '$482,300' },
  { value: 'jobs', label: 'Job Board', icon: 'clipboard', description: 'Contracts posted today', badge: 7 },
  { value: 'mechanic', label: 'Mechanic Shop', icon: 'wrench', description: 'Requires the Mechanic job', disabled: true },
  { value: 'leave', label: 'Leave Faction', icon: 'exit', description: 'You lose rank and garage access', danger: true },
]

const FAST_TRAVEL = [
  { value: 'north', label: 'Northern Ridge', trailing: '842 m' },
  { value: 'docks', label: 'Harbour Docks', trailing: '2.4 km' },
  { value: 'airfield', label: 'Sandy Airfield', trailing: '7.1 km' },
]

const main = ref('continue')
const category = ref('all')
const services = ref('garage')
const solid = ref('docks')
const legacy = ref(1)
const focused = ref('gear')
const dangerous = ref('leave')
const picked = ref('—')

// :focus-visible is keyboard-only: the active row is focused on mount so the ring is in the shot.
const focusDemo = useTemplateRef('focusDemo')
onMounted(() => {
  const row = focusDemo.value && focusDemo.value.querySelector('.core-menu__item.is-active')
  if (row) row.focus({ preventScroll: true })
})

const sidebarBox = {
  width: '266px',
  padding: '8px 7px',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  background: 'var(--color-panel)',
  boxShadow: 'var(--shadow-ui)',
}
</script>

<template>
  <KitStage
    title="CoreMenu"
    description="The main menu, a category sidebar and the shell's keyboard menu are one component at three
      sizes. v-model is the ACTIVE row — arrow keys only move it, `select` fires on Enter or a click."
  >
    <KitSection
      label="lg — the main menu"
      layout="column"
      :gap="12"
      note="selectOnHover on, fade on: solid coral for the first third, then dissolved into the background."
    >
      <div style="width: 420px">
        <CoreMenu v-model="main" :items="MAIN" size="lg" select-on-hover @select="picked = $event.label" />
      </div>
      <p class="core-flavor">Last selected: {{ picked }}</p>
    </KitSection>

    <KitSection label="md — the inventory sidebar" :gap="28" note="266 px box, rows full-bleed inside the panel padding.">
      <div :style="sidebarBox">
        <CoreMenu v-model="category" :items="CATEGORIES" />
      </div>
      <div :style="sidebarBox">
        <CoreMenu v-model="solid" :items="FAST_TRAVEL" :fade="false" />
        <p class="core-label" style="padding: 10px 18px 2px">fade = false</p>
      </div>
    </KitSection>

    <KitSection
      label="sm — descriptions, trailing values, badge, disabled, danger"
      layout="column"
      :gap="0"
      note="Two-line rows grow past the 38 px minimum; the danger row keeps the coral shape in error red."
    >
      <div :style="{ ...sidebarBox, width: '400px' }">
        <CoreMenu v-model="services" :items="SERVICES" size="sm" />
      </div>
    </KitSection>

    <KitSection label="Legacy .core-list / .core-item" layout="column" :gap="0" note="What components/Menu.vue renders today — no component, bare classes.">
      <div :style="{ ...sidebarBox, width: '380px' }">
        <ul class="core-list" role="menu">
          <li
            v-for="(entry, i) in ['Repair vehicle', 'Refuel — $84', 'Sell to scrapyard']"
            :key="entry"
            class="core-item"
            :class="{ 'is-active': i === legacy }"
            role="menuitem"
            @mouseenter="legacy = i"
          >
            <span class="icon min-w-5 flex-none text-center text-[13px] text-accent">&#9679;</span>
            <span class="body flex min-w-0 flex-col">
              <span class="label text-ui-sm leading-[1.3]">{{ entry }}</span>
              <span class="desc text-ui-xs text-fg-dim">Interact with the mechanic</span>
            </span>
          </li>
          <li class="core-item is-disabled" role="menuitem">
            <span class="icon min-w-5 flex-none text-center text-[13px] text-accent">&#9679;</span>
            <span class="body flex min-w-0 flex-col">
              <span class="label text-ui-sm leading-[1.3]">Tune engine</span>
              <span class="desc text-ui-xs text-fg-dim">Needs a lift bay</span>
            </span>
          </li>
        </ul>
      </div>
    </KitSection>

    <KitSection label="States" :gap="28" note="GEAR is focused on mount — the 2 px accent-hi ring, inset so it never leaves the row. Hover any row for white 4 % + fg; MECHANIC SHOP above is the disabled look. Right: a danger row while it is the active one.">
      <div ref="focusDemo" :style="sidebarBox">
        <CoreMenu v-model="focused" :items="CATEGORIES" />
      </div>
      <div :style="{ ...sidebarBox, width: '400px' }">
        <CoreMenu v-model="dangerous" :items="SERVICES" size="sm" />
      </div>
    </KitSection>
  </KitStage>
</template>
