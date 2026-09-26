<script setup>
// PaletteLab — the same slice of UI under every candidate second colour, side by side (DEV ONLY,
// src/lab/palette.js). Not a kit component and not part of DESIGN §37: a scratch bench for picking
// a second colour before the kit gets one.
//
//   kit-preview.html?scene=PaletteLab&roles=split|light|swap
//
// Every column is the kit untouched plus a `data-lab` wrapper, so what you see is exactly what
// the tokens would do. The columns SHARE their state: pick a row, a tab or a slot in one column
// and every column follows, so the comparison is always like for like.
import { computed, onBeforeMount, ref } from 'vue'
import { MIXES, PRESETS, installLab, paletteVars, resolveRoles, mixOf } from '../../../lab/palette.js'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const params = new URLSearchParams(window.location.search)
const mix = ref(mixOf(resolveRoles(params.get('roles'))) || 'split')
const roles = computed(() => resolveRoles(mix.value))
const mixNote = computed(() => (MIXES.find((m) => m.id === mix.value) || {}).note || '')

const columns = computed(() => [{ id: 'off', name: 'Current', base: '', note: 'The kit as it ships.' }]
  .concat(PRESETS)
  .map((p) => {
    if (p.id === 'off') return { palette: p, attrs: {}, style: {} }
    const { vars, on } = paletteVars(p)
    return { palette: p, attrs: { 'data-lab': roles.value.join(' '), 'data-lab-on2': on }, style: vars }
  }))

const MIX_ITEMS = MIXES.map((m) => ({ value: m.id, label: m.name }))
const TABS = ['Map', 'Inventory', 'Skills']
const MENU = [
  { value: 'continue', label: 'Continue', icon: 'play' },
  { value: 'garage', label: 'Garage', icon: 'garage', badge: 3 },
  { value: 'settings', label: 'Settings', icon: 'settings' },
  { value: 'exit', label: 'Leave session', icon: 'exit' },
]
const CHIPS = ['All', 'Weapons', 'Food']
const PAY = [
  { value: 'cash', label: 'Cash' },
  { value: 'bank', label: 'Bank' },
]
const SLOTS = [
  { id: 'a', icon: 'pistol', count: 12 },
  { id: 'b', icon: 'medkit', count: 3 },
  { id: 'c', icon: 'food', count: 5 },
  { id: 'd', icon: 'key', count: 1 },
]

const tab = ref('Inventory')
const menu = ref('garage')
const chip = ref('Weapons')
const pay = ref('bank')
const slot = ref('b')
const hud = ref(true)
const ammo = ref(true)
const volume = ref(62)

onBeforeMount(() => installLab())
</script>

<template>
  <KitStage
    title="Palette lab"
    width="100%"
    description="The coral stays the brand. Each column gives a second colour the jobs picked below; everything else is the kit untouched. The columns share their state — click a menu row, tab or slot in one and all follow. The last row is the honesty check: the error red next to the coral."
  >
    <KitSection label="How much the second colour takes over" :note="mixNote">
      <CoreChips v-model="mix" :items="MIX_ITEMS" />
    </KitSection>

    <div style="display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 20px; align-items: start">
      <div v-for="col in columns" :key="col.palette.id" v-bind="col.attrs" :style="col.style">
        <CorePanel padding="md" accent>
          <CoreHeading :title="col.palette.name" :subtitle="col.palette.base || 'coral only'" size="md" slash />
          <p class="text-fg-faint text-ui-sm" style="margin: 8px 0 0; min-height: 40px">{{ col.palette.note }}</p>

          <CoreTabs v-model="tab" :items="TABS" size="sm" style="margin-top: 14px" />

          <CoreMenu v-model="menu" :items="MENU" size="sm" style="margin-top: 14px" />

          <div style="display: flex; gap: 8px; margin-top: 16px">
            <CoreButton variant="primary" size="sm" icon="check">Confirm</CoreButton>
            <CoreButton size="sm">Cancel</CoreButton>
            <CoreButton variant="danger" size="sm" icon="trash">Sell</CoreButton>
          </div>

          <CoreChips v-model="chip" :items="CHIPS" size="sm" style="margin-top: 16px" />

          <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 12px 16px; margin-top: 18px">
            <CoreCheckbox v-model="ammo" label="Auto-reload" size="sm" />
            <CoreSwitch v-model="hud" label="HUD" size="sm" />
            <CoreRadioGroup v-model="pay" :items="PAY" orientation="horizontal" size="sm" style="grid-column: 1 / -1" />
          </div>
          <CoreSlider v-model="volume" label="Radio volume" show-value suffix="%" style="margin-top: 14px" />

          <!-- A focused field, frozen: CoreInput only sets is-focused while its input really has
               focus, and only one column could. Same markup, the state pinned. -->
          <div class="core-inputbox core-inputbox--sm is-focused" style="margin-top: 16px">
            <CoreIcon class="core-inputbox__icon" name="search" :size="16" />
            <input class="core-inputbox__el" value="Focused field" readonly tabindex="-1">
          </div>

          <div style="display: flex; gap: 10px; margin-top: 18px">
            <CoreSlot
              v-for="s in SLOTS"
              :key="s.id"
              :icon="s.icon"
              :count="s.count"
              :size="64"
              :selected="slot === s.id"
              @click="slot = s.id"
            />
          </div>

          <CoreProgress :value="64" label="Stash upload" show-value size="sm" style="margin-top: 18px" />

          <div style="display: flex; align-items: center; gap: 10px; margin-top: 18px">
            <CoreKey label="E" />
            <span class="text-fg-dim text-ui-sm">Interact</span>
            <CoreKey label="F" pressed :progress="0.6" />
            <span class="text-fg-dim text-ui-sm">Held</span>
          </div>

          <div style="display: flex; align-items: center; gap: 8px; margin-top: 18px">
            <CoreTag tone="accent" variant="solid" label="Featured" />
            <CoreTag tone="danger" variant="solid" label="Wanted" />
            <CoreTag tone="danger" label="Insufficient funds" />
          </div>
        </CorePanel>
      </div>
    </div>
  </KitStage>
</template>
