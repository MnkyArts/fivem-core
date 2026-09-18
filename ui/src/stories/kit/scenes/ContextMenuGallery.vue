<script setup>
// CoreContextMenu gallery (DESIGN §37.5, Feedback). The interesting part is not the rows, it is the
// clamping: the four corner buttons open the same menu at the four corners of the viewport, and the
// bottom-right one has to flip and stay fully on screen. The slot grid is the real-world case —
// right-click an item, get "use / split / drop".
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'
import medkit from '../assets/item-medkit.jpg'
import water from '../assets/item-water.jpg'
import ammo from '../assets/item-ammo.jpg'
import knife from '../assets/item-knife.jpg'

const ITEM_MENU = [
  { value: 'use', label: 'Use', icon: 'medkit', kbd: 'E' },
  { value: 'equip', label: 'Equip', icon: 'hand', kbd: 'F' },
  { separator: true },
  { value: 'split', label: 'Split stack', icon: 'copy' },
  { value: 'give', label: 'Give to…', icon: 'users', disabled: true },
  { separator: true },
  { value: 'drop', label: 'Drop', icon: 'trash', kbd: 'DEL', danger: true },
]

const VEHICLE_MENU = [
  { value: 'lock', label: 'Lock doors', icon: 'lock', kbd: 'L' },
  { value: 'engine', label: 'Toggle engine', icon: 'engine' },
  { value: 'lights', label: 'Lights', icon: 'car-light' },
  { separator: true },
  { value: 'impound', label: 'Report stolen', icon: 'police', danger: true },
]

const ITEMS = [
  { id: 'medkit', image: medkit, name: 'Med Kit' },
  { id: 'water', image: water, name: 'Water' },
  { id: 'ammo', image: ammo, name: 'Heavy Rounds' },
  { id: 'knife', image: knife, name: 'Combat Knife' },
]

const open = ref(false)
const position = ref({ x: 0, y: 0 })
const items = ref(ITEM_MENU)
const target = ref('—')
const picked = ref('—')

function show (event, what, list) {
  position.value = { x: event.clientX, y: event.clientY }
  items.value = list
  target.value = what
  open.value = true
}

function corner (event, which) {
  const el = event.currentTarget.getBoundingClientRect()
  position.value = { x: Math.round(el.left + el.width / 2), y: Math.round(el.top + el.height / 2) }
  items.value = ITEM_MENU
  target.value = which
  open.value = true
}

const onSelect = (item) => { picked.value = item.label + ' — ' + target.value }
</script>

<template>
  <KitStage
    title="Context menu"
    description="Right-click rows in the display voice, placed at a point instead of against an element: the kit's
      placeFloating() runs against a zero-size rect, so the menu flips and clamps like every other popup."
  >
    <KitSection label="Right-click an item" :gap="12" note="the whole grid is one menu — position moves, the items stay">
      <button
        v-for="item in ITEMS"
        :key="item.id"
        type="button"
        class="core-focusable"
        style="width: 92px; height: 92px; padding: 10px; border: 1px solid var(--color-border);
          border-radius: var(--radius-ui-sm); background: var(--color-panel-raise); cursor: context-menu"
        @contextmenu.prevent="show($event, item.name, ITEM_MENU)"
      >
        <img :src="item.image" :alt="item.name" style="width: 100%; height: 100%; object-fit: contain" />
      </button>

      <button
        type="button"
        class="core-focusable flex items-center"
        style="gap: 10px; height: 92px; padding: 0 18px; border: 1px solid var(--color-border);
          border-radius: var(--radius-ui-sm); background: var(--color-panel-raise); cursor: context-menu"
        @contextmenu.prevent="show($event, 'Sultan RS', VEHICLE_MENU)"
      >
        <CoreIcon name="car" size="lg" style="color: var(--color-fg-faint)" />
        <span class="core-label" style="margin: 0; color: var(--color-fg)">Sultan RS</span>
      </button>
    </KitSection>

    <KitSection label="Last pick" layout="column" :gap="6">
      <p class="core-label" style="margin: 0">selected — <span style="color: var(--color-fg)">{{ picked }}</span></p>
      <p class="core-flavor" style="margin: 0">↑/↓ skip separators and the disabled row · Enter picks · Escape, a scroll or a click outside close it.</p>
    </KitSection>

    <KitSection label="Clamping" layout="column" :gap="10" note="the same menu at the four corners of the viewport — none of it may leave the screen">
      <div style="position: relative; height: 150px">
        <CoreButton
          v-for="c in [['top left', '0', 'auto', 'auto', '0'], ['top right', 'auto', '0', 'auto', '0'],
                       ['bottom left', '0', 'auto', '0', 'auto'], ['bottom right', 'auto', '0', '0', 'auto']]"
          :key="c[0]"
          size="sm"
          variant="secondary"
          :style="{ position: 'fixed', left: c[1], right: c[2], bottom: c[3], top: c[4], margin: '10px', zIndex: 5 }"
          @click="corner($event, c[0])"
        >
          {{ c[0] }}
        </CoreButton>
        <p class="core-text" style="margin: 0">
          The four buttons are pinned to the corners of the window. Opening the bottom-right one has
          to flip the menu upwards and pull it back inside the 8 px padding.
        </p>
      </div>
    </KitSection>

    <CoreContextMenu v-model:open="open" :position="position" :items="items" @select="onSelect" />
  </KitStage>
</template>
