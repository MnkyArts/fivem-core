<script setup>
// SelectGallery — CoreSelect in both variants (DESIGN §37.5).
// The first section rebuilds the inventory mockup's grid header, because `inline` exists for
// exactly that row: `SORT: RECENT v` with no chrome at all. Everything below it is the `box`
// variant a form uses. Open a list with the mouse or with Space/↓ — the popup is teleported into
// #core-overlays and closes on Escape before the shell ever sees the key.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const SORTS = [
  { value: 'recent', label: 'Recent' },
  { value: 'name', label: 'Name' },
  { value: 'weight', label: 'Weight' },
  { value: 'value', label: 'Value' },
  { value: 'rarity', label: 'Rarity' },
]

const CATEGORIES = [
  { value: 'all', label: 'All items', icon: 'backpack', description: '38 of 60 slots used' },
  { value: 'weapons', label: 'Weapons', icon: 'pistol', description: 'Carried and holstered' },
  { value: 'meds', label: 'Medical', icon: 'medkit', description: 'Bandages, kits, pills' },
  { value: 'tools', label: 'Tools', icon: 'wrench', description: 'Repair and breach gear' },
  { value: 'contraband', label: 'Contraband', icon: 'lock', description: 'Locked by dispatch', disabled: true },
]

const GARAGES = ['Pillbox Hill', 'Legion Square', 'Sandy Shores', 'Paleto Bay', 'Vespucci Beach',
  'Vinewood Hills', 'Del Perro Pier', 'La Mesa Impound', 'Grapeseed Barn']

const RANKS = ['Recruit', 'Soldier', 'Lieutenant', 'Underboss', 'Boss']

const sort = ref('recent')
const category = ref('all')
const garage = ref('Legion Square')
const rank = ref('Lieutenant')
const empty = ref(null)
const badPlate = ref(null)
const locked = ref('Recruit')
const above = ref('Sandy Shores')
const events = ref('—')
</script>

<template>
  <KitStage
    title="Select"
    description="One dropdown, two shapes: `inline` is the mockup's chrome-free caption + value + chevron, `box` is the
                 form control. Popup: panel 98 %, border-strong, 4 px padding, 36 px options; the keyboard cursor is a
                 coral 16 % row with a 2 px inset bar, the current value a check on the right."
  >
    <KitSection label="Inline — the inventory grid header" layout="column" :gap="0"
                note="The mockup's row: SORT: RECENT with a wide chevron. No border, no fill, nothing but type.">
      <div
        class="flex items-end justify-between"
        style="width: 100%; padding-bottom: 18px; border-bottom: 1px solid var(--color-border)"
      >
        <div>
          <h2 class="core-display core-display--lg">Inventory</h2>
          <p class="core-eyebrow" style="margin-top: 12px">Gear up for what’s next.</p>
        </div>
        <CoreSelect v-model="sort" variant="inline" label="SORT:" :items="SORTS" />
      </div>
    </KitSection>

    <KitSection label="Inline sizes and states" layout="row" :gap="40">
      <CoreSelect v-model="sort" variant="inline" size="sm" label="SORT:" :items="SORTS" />
      <CoreSelect v-model="rank" variant="inline" label="RANK:" :items="RANKS" />
      <CoreSelect v-model="garage" variant="inline" size="lg" label="GARAGE:" :items="GARAGES" />
      <CoreSelect v-model="locked" variant="inline" label="RANK:" :items="RANKS" disabled />
    </KitSection>

    <KitSection label="Box — sizes" layout="grid" :columns="3" :gap="20"
                note="The popup matches the trigger width in the box variant (matchWidth).">
      <CoreSelect v-model="rank" size="sm" :items="RANKS" />
      <CoreSelect v-model="garage" :items="GARAGES" />
      <CoreSelect v-model="rank" size="lg" :items="RANKS" />
    </KitSection>

    <KitSection label="Box — icons, descriptions, disabled options" layout="grid" :columns="2" :gap="20"
                note="Items are normalised by normalizeItems: an icon and a description come straight off the item.">
      <CoreSelect v-model="category" :items="CATEGORIES" :max-height="300" />
      <CoreSelect v-model="category" label="FILTER:" :items="CATEGORIES" />
    </KitSection>

    <KitSection label="Box — states" layout="grid" :columns="3" :gap="20">
      <div>
        <p class="core-label" style="margin-bottom: 8px">Placeholder</p>
        <CoreSelect v-model="empty" :items="GARAGES" placeholder="Pick a garage…" />
      </div>
      <div>
        <p class="core-label" style="margin-bottom: 8px">Invalid</p>
        <CoreSelect v-model="badPlate" :items="GARAGES" placeholder="Required" invalid />
      </div>
      <div>
        <p class="core-label" style="margin-bottom: 8px">Disabled</p>
        <CoreSelect v-model="locked" :items="RANKS" disabled />
      </div>
    </KitSection>

    <KitSection label="Placement and events" layout="row" :gap="24"
                note="`placement: 'top'` opens upwards; useFloating flips either way when the viewport is tight.">
      <CoreSelect
        v-model="above" :items="GARAGES" placement="top" style="width: 260px"
        @open="events = 'open'" @close="events = 'close'"
      />
      <p class="core-text" style="margin: 0">
        value: <b class="text-fg">{{ above }}</b> · last event: <b class="text-fg">{{ events }}</b>
      </p>
    </KitSection>
  </KitStage>
</template>
