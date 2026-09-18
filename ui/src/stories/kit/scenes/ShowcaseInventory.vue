<script setup>
// ShowcaseInventory — mockup 3 ("(3)", the inventory screen) rebuilt from kit components only
// (DESIGN §37.7). Nothing here is custom CSS: every surface is a <Core…> tag, the rest is Tailwind
// layout utilities and the base type classes of css/base.css.
//
// Alive, not a picture: the tabs switch, the category menu filters the grid, a slot click re-reads
// the detail panel, SORT re-orders the bag and USE raises a CoreToast.
import { computed, ref } from 'vue'
import keyart from '../assets/keyart.jpg'
import sidebarArt from '../assets/lastplayed.jpg'
import itemMedkit from '../assets/item-medkit.jpg'
import itemWater from '../assets/item-water.jpg'
import itemAmmo from '../assets/item-ammo.jpg'
import itemTape from '../assets/item-tape.jpg'
import itemKnife from '../assets/item-knife.jpg'
import itemJerrycan from '../assets/item-jerrycan.jpg'
import itemToolbox from '../assets/item-toolbox.jpg'

const TABS = ['Map', 'Inventory', 'Character', 'Skills', 'Journal']
const tab = ref('Inventory')

const CATEGORIES = [
  { value: 'all', label: 'All', icon: 'grid' },
  { value: 'weapons', label: 'Weapons', icon: 'pistol' },
  { value: 'gear', label: 'Gear', icon: 'backpack' },
  { value: 'consumables', label: 'Consumables', icon: 'medkit' },
  { value: 'keys', label: 'Key items', icon: 'key' },
]
const category = ref('all')

const SORTS = [
  { value: 'recent', label: 'Recent' },
  { value: 'name', label: 'Name' },
  { value: 'quantity', label: 'Quantity' },
]
const sort = ref('recent')

// One row per bag item: the CoreSlot props the grid needs AND the copy the detail panel prints.
const ITEMS = [
  {
    id: 'medkit', image: itemMedkit, count: 3, rarity: 'common', group: 'consumables',
    title: 'Med Kit', kind: 'Common · Consumable', held: 3, cap: 10,
    text: 'Restores a significant amount of health.', note: 'Essential for life on the road.',
    stat: { icon: 'heart', label: 'Health restore', value: '+75', tone: '' },
    flavor: 'A small kit. A second chance.', action: 'Use', past: 'Used', actionIcon: 'medkit',
  },
  {
    id: 'water', image: itemWater, count: 4, rarity: 'common', group: 'consumables',
    title: 'Water Bottle', kind: 'Common · Consumable', held: 4, cap: 12,
    text: 'Half a litre of clean water, still cold.', note: 'The road is long and the air is dry.',
    stat: { icon: 'water', label: 'Thirst', value: '+40', tone: 'thirst' },
    flavor: 'Every mile tastes better than the last.', action: 'Drink', past: 'Drank', actionIcon: 'water',
  },
  {
    id: 'ammo', image: itemAmmo, count: 60, rarity: 'common', group: 'weapons',
    title: 'Rifle Ammo', kind: 'Common · Ammunition', held: 60, cap: 240,
    text: 'Standard rounds for every rifle you are likely to find.', note: 'Heavy in the pack, light in a hurry.',
    stat: { icon: 'ammo', label: 'Rounds carried', value: '60', tone: '' },
    flavor: 'Count them twice before you need them once.', action: 'Load', past: 'Loaded', actionIcon: 'ammo',
  },
  {
    id: 'tape', image: itemTape, count: null, rarity: 'common', group: 'gear',
    title: 'Duct Tape', kind: 'Common · Material', held: 1, cap: 5,
    text: 'Holds the world together, one wrap at a time.', note: 'The first tool any mechanic reaches for.',
    stat: { icon: 'wrench', label: 'Repair', value: '+15', tone: 'success' },
    flavor: 'Temporary is a matter of opinion.', action: 'Use', past: 'Used', actionIcon: 'wrench',
  },
  {
    id: 'knife', image: itemKnife, count: null, rarity: 'uncommon', group: 'weapons',
    title: 'Folding Knife', kind: 'Uncommon · Tool', held: 1, cap: 1,
    text: 'A worn blade that still takes an edge.', note: 'Quiet, quick, and always within reach.',
    stat: { icon: 'knife', label: 'Damage', value: '+24', tone: 'danger' },
    flavor: 'Sharp enough for rope. Sharp enough for worse.', action: 'Equip', past: 'Equipped', actionIcon: 'knife',
  },
  {
    id: 'jerrycan', image: itemJerrycan, count: null, rarity: 'common', group: 'gear',
    title: 'Jerry Can', kind: 'Common · Gear', held: 1, cap: 2,
    text: 'Twenty litres of borrowed distance.', note: 'Fuel is the only freedom that runs out.',
    stat: { icon: 'fuel', label: 'Fuel', value: '+20 L', tone: 'warning' },
    flavor: 'The tank is never as full as the map is wide.', action: 'Refuel', past: 'Refuelled', actionIcon: 'fuel',
  },
  {
    id: 'toolbox', image: itemToolbox, count: 2, rarity: 'rare', group: 'gear',
    title: 'Tool Box', kind: 'Rare · Gear', held: 2, cap: 4,
    text: 'Everything you need to keep a car breathing.', note: 'Repairs a vehicle anywhere the road stops.',
    stat: { icon: 'wrench', label: 'Repair', value: '+60', tone: 'success' },
    flavor: 'Grease under the nails, miles under the wheels.', action: 'Use', past: 'Used', actionIcon: 'toolbox',
  },
]

const SORTERS = {
  recent: () => 0,
  name: (a, b) => a.title.localeCompare(b.title),
  quantity: (a, b) => (b.count || 1) - (a.count || 1),
}

const shown = computed(() => {
  const list = category.value === 'all' ? ITEMS.slice() : ITEMS.filter((i) => i.group === category.value)
  return list.sort(SORTERS[sort.value] || SORTERS.recent)
})

// The grid only wants the CoreSlot props — the detail copy would land on the <button> otherwise.
// No `rarity`: the mockup's cells carry no rarity line, the word lives in the detail eyebrow.
const cells = computed(() => shown.value.map((i) => ({
  id: i.id, image: i.image, count: i.count, label: i.title,
})))

const selected = ref('medkit')
const detail = computed(() => ITEMS.find((i) => i.id === selected.value) || ITEMS[0])

const toast = ref(null)
let timer = 0

function raise (tone, title, message) {
  toast.value = { tone, title, message }
  window.clearTimeout(timer)
  timer = window.setTimeout(() => { toast.value = null }, 3200)
}

const onUse = () => raise('success', detail.value.past, detail.value.title + ' — ' + detail.value.stat.label.toLowerCase() + ' ' + detail.value.stat.value + '.')
const onDrop = () => raise('warning', 'Dropped', detail.value.title + ' left on the ground.')
</script>

<template>
  <div class="relative w-full h-screen min-h-[900px] overflow-hidden">
    <CoreScreen background="scrim" :image="keyart" :dim="0.74">
      <template #brand>
        <CoreBrand size="lg" name="Wayfinder">
          <template #logo>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M12 2 23 21 1 21Z M12 9.6 6.4 19.2 17.6 19.2Z" fill="currentColor" fill-rule="evenodd" />
              <path d="M15.2 9.4 23 21 7.4 21Z" style="fill: var(--color-ink)" opacity="0.62" />
            </svg>
          </template>
        </CoreBrand>
        <!-- Em spaces: the mockup sets two words per line with a wide gap, and HTML collapses
             ordinary ones. -->
        <CoreTagline class="ml-7" :lines="['Explore\u2003Drive', 'Survive\u2003Belong']" />
      </template>

      <template #nav>
        <!-- CoreScreen centres the nav in the space LEFT of the status block; the mockup centres
             it on the screen. A margin is the only layout-only way to move it back. -->
        <CoreTabs v-model="tab" :items="TABS" size="lg" class="mr-[290px]" />
      </template>

      <template #status>
        <CoreTagline rule="accent" :lines="['Worlds', 'Are better', 'With stories.']" />
      </template>

      <!-- The mockup keeps a wide band of key art between the header and the panels (96 px at
           1080p) — the body's own 24 px is only the start of it. -->
      <div class="flex min-h-0 flex-1 gap-5 pt-24">
        <!-- category sidebar -->
        <CorePanel padding="none" class="w-[304px] flex-none">
          <div class="flex h-full flex-col">
            <div class="px-3 pt-11">
              <CoreMenu v-model="category" :items="CATEGORIES" size="lg" />
            </div>
            <!-- Two CoreBackgrounds: `scrim` darkens the picture to the mockup's level, and a
                 `top` one in a short box of its own dissolves the upper edge into the panel —
                 the kit has no variant that does both, and `top` alone fades over half the box. -->
            <div class="relative mt-auto h-[332px] overflow-hidden rounded-b-ui">
              <CoreBackground variant="scrim" :image="sidebarArt" :dim="0.55" />
              <div class="absolute inset-x-0 top-0 h-[170px]">
                <CoreBackground variant="top" :dim="0.96" />
              </div>
              <div class="absolute inset-x-0 bottom-0 px-9 pb-11">
                <CoreTagline :lines="['The open road', 'Always leads', 'Somewhere']" dash />
              </div>
            </div>
          </div>
        </CorePanel>

        <!-- the bag -->
        <CorePanel
          class="min-w-0 flex-1"
          title="Inventory"
          subtitle="Gear up for what's next."
          heading-size="xl"
          padding="lg"
        >
          <template #actions>
            <CoreSelect v-model="sort" :items="SORTS" variant="inline" label="Sort:" />
          </template>

          <CoreSlotGrid
            v-if="cells.length"
            v-model:selected="selected"
            :items="cells"
            :columns="4"
            :slots="12"
            :gap="16"
            ratio="5 / 4"
          />
          <CoreEmpty
            v-else
            icon="backpack"
            title="Nothing here"
            text="No key items in your pack yet — the world has not handed you one."
          />

          <template #footer>
            <CoreProgress
              class="w-full"
              inline
              tone="neutral"
              icon="backpack"
              label="Inventory capacity"
              :value="18.5"
              :max="30"
              show-value
            />
          </template>
        </CorePanel>

        <!-- item detail -->
        <CorePanel
          class="w-[588px] flex-none"
          :title="detail.title"
          :subtitle="detail.kind"
          heading-size="lg"
          padding="lg"
        >
          <template #actions>
            <div class="text-right">
              <p class="core-num text-display-lg leading-none">
                <span class="text-fg">{{ detail.held }}</span>
                <span class="text-fg-dim"> / {{ detail.cap }}</span>
              </p>
              <p class="core-label mt-2">In inventory</p>
            </div>
          </template>

          <div class="flex h-full min-h-0 flex-col">
            <div class="flex min-h-0 flex-1 items-center justify-center py-2">
              <img :src="detail.image" alt="" class="h-full w-full object-contain" />
            </div>

            <p class="core-text mt-4 text-fg">{{ detail.text }}</p>
            <p class="core-text mt-1 text-fg-faint">{{ detail.note }}</p>

            <CoreStatRow
              class="mt-5"
              :icon="detail.stat.icon"
              :label="detail.stat.label"
              :value="detail.stat.value"
              :tone="detail.stat.tone"
            />

            <p class="core-flavor mt-4">{{ detail.flavor }}</p>

            <div class="mt-6 flex gap-4">
              <CoreButton variant="primary" fade size="lg" :icon="detail.actionIcon" class="flex-1" @click="onUse">
                {{ detail.action }}
              </CoreButton>
              <CoreButton size="lg" class="flex-1" @click="onDrop">Drop</CoreButton>
            </div>
          </div>
        </CorePanel>
      </div>

      <template #footer-start>
        <span class="core-label text-fg">Wayfinder</span>
        <CoreDivider vertical class="h-3.5" />
        <span class="core-text text-ui-sm text-fg-faint">v1.0</span>
      </template>
      <template #footer-end>
        <span class="core-label">Built for worlds yet to be explored.</span>
        <CoreDash :width="34" />
      </template>
    </CoreScreen>

    <!-- The band of key art between header and panels is the only place a toast covers nothing. -->
    <Transition name="core-slide-down">
      <div v-if="toast" class="absolute right-8 top-[104px] z-10">
        <CoreToast :tone="toast.tone" :title="toast.title" :message="toast.message" />
      </div>
    </Transition>
  </div>
</template>
