<script setup>
// ShowcaseMap — mockup 4 ("(4)", the world map) rebuilt from kit components only (DESIGN §37.7).
// No custom CSS: <Core…> tags, Tailwind layout utilities and the base type classes of css/base.css.
//
// Alive: the chips filter the quest list, picking a quest re-reads the detail CoreCard and the
// objective, the six map filters toggle, and TRACK QUEST opens a CoreDialog.
import { computed, ref, watch } from 'vue'
import mapArt from '../assets/map.jpg'
import questHero from '../assets/quest-hero.jpg'
import quest1 from '../assets/quest-1.jpg'
import quest2 from '../assets/quest-2.jpg'
import quest3 from '../assets/quest-3.jpg'
import quest4 from '../assets/quest-4.jpg'

const TABS = ['Map', 'Inventory', 'Character', 'Quests', 'Skills', 'Journal']
const tab = ref('Map')

const KINDS = [
  { value: 'all', label: 'All' },
  { value: 'main', label: 'Main' },
  { value: 'side', label: 'Side' },
  { value: 'done', label: 'Completed' },
]
const kind = ref('all')

const QUESTS = [
  {
    id: 'brighter', kind: 'main', image: quest1, hero: questHero,
    icon: 'quest', iconTone: 'accent', title: 'A Brighter Tomorrow', subtitle: 'Main Story', trailing: '842 m',
    text: 'Meet the contact at the old tower outside Solace City. They may have information about the next phase.',
    objective: 'Meet the contact at the old tower', state: 'open',
  },
  {
    id: 'supply', kind: 'side', image: quest2, hero: quest2,
    icon: 'map-marker', iconTone: 'warning', title: 'Supply Lines', subtitle: 'Side Quest', trailing: '2.4 km',
    text: 'The depot on the coast road has stopped answering. Drive out, count what is left and radio it in.',
    objective: 'Reach the coast road depot', state: 'open',
  },
  {
    id: 'echoes', kind: 'side', image: quest3, hero: quest3,
    icon: 'diamond-outline', iconTone: 'neutral', title: 'Echoes in the Hills', subtitle: 'Side Quest', trailing: '3.1 km',
    text: 'A relay in Redwood Vale keeps repeating the same four seconds of tape. Somebody left it running.',
    objective: 'Find the relay in Redwood Vale', state: 'open',
  },
  {
    id: 'friends', kind: 'done', image: quest4, hero: quest4, completed: true,
    icon: 'check-circle', iconTone: 'neutral', title: 'Old Friends', subtitle: 'Completed', trailing: '',
    text: 'You found the camp above the vale, and the people who had been waiting there since the spring.',
    objective: 'Return to the camp above the vale', state: 'done',
  },
]

const shown = computed(() => (kind.value === 'all' ? QUESTS : QUESTS.filter((q) => q.kind === kind.value)))

// The list only wants CoreListItem props; `kind`, `hero`, `text` and the objective belong to the card.
const rows = computed(() => shown.value.map((q) => ({
  id: q.id, image: q.image, icon: q.icon, iconTone: q.iconTone,
  title: q.title, subtitle: q.subtitle, trailing: q.trailing, completed: q.completed,
})))

const selected = ref('brighter')
const active = computed(() => QUESTS.find((q) => q.id === selected.value) || QUESTS[0])

// A filter that hides the selected quest moves the selection to the first row that is left.
watch(shown, (list) => {
  if (list.length && !list.some((q) => q.id === selected.value)) selected.value = list[0].id
})

const FILTERS = [
  { value: 'quests', label: 'Quests', icon: 'quest', accent: true },
  { value: 'locations', label: 'Locations', icon: 'home' },
  { value: 'travel', label: 'Fast Travel', icon: 'camp' },
  { value: 'shops', label: 'Shops', icon: 'cart' },
  { value: 'activities', label: 'Activities', icon: 'help' },
  { value: 'collectibles', label: 'Collectibles', icon: 'leaf' },
]
const filters = ref(['quests', 'locations', 'travel'])

const HINTS = [
  { key: 'mouse-left', label: 'Pan' },
  { key: 'mouse-scroll', label: 'Zoom' },
  { key: 'R', label: 'Recenter' },
  { key: 'F', label: 'Show legend' },
]

const tracking = ref(false)
</script>

<template>
  <div class="relative w-full h-screen min-h-[900px] overflow-hidden">
    <CoreScreen background="solid">
      <template #brand>
        <CoreBrand size="lg" name="Wayfinder">
          <template #logo>
            <svg viewBox="0 0 24 24" aria-hidden="true">
              <path d="M12 2 23 21 1 21Z M12 9.6 6.4 19.2 17.6 19.2Z" fill="currentColor" fill-rule="evenodd" />
              <path d="M15.2 9.4 23 21 7.4 21Z" style="fill: var(--color-ink)" opacity="0.62" />
            </svg>
          </template>
        </CoreBrand>
      </template>

      <template #nav>
        <!-- The mockup hangs the tabs off the brand instead of centring them in the header, and
             CoreScreen only centres; `mr-auto` gives the row back to the left edge of the nav. -->
        <CoreTabs v-model="tab" :items="TABS" separators class="ml-16 mr-auto" />
      </template>

      <template #status>
        <CoreTagline :lines="['Explore', 'Drive', 'Survive', 'Belong']" />
        <CoreTagline class="ml-9" rule="accent" :lines="['Worlds', 'Are better', 'With stories.']" />
      </template>

      <div class="flex min-h-0 flex-1 gap-4">
        <!-- quests -->
        <CorePanel class="w-[492px] flex-none" title="Quests" slash padding="md">
          <CoreChips v-model="kind" :items="KINDS" size="lg" class="mb-4" />
          <CoreList v-model="selected" :items="rows" dividers />
        </CorePanel>

        <!-- the map itself: the picture is oversized so the compass and scale bar baked into the
             art fall outside the frame and the kit's own draw over clean terrain. -->
        <div class="relative min-w-0 flex-1 overflow-hidden rounded-ui">
          <img :src="mapArt" alt="" class="absolute -left-[6%] -top-[16%] h-[128%] w-[128%] max-w-none object-cover" />

          <div class="absolute right-7 top-6 flex flex-col items-center gap-1">
            <span class="core-num text-ui-sm text-fg">N</span>
            <CoreIconButton icon="navigation" label="Recentre north" size="lg" round />
          </div>

          <div class="absolute bottom-7 left-7 w-[230px]">
            <div class="flex justify-between">
              <span v-for="mark in ['0', '2', '5', '10 KM']" :key="mark" class="core-num text-ui-xs text-fg">
                {{ mark }}
              </span>
            </div>
            <CoreProgress class="mt-1.5" size="sm" tone="neutral" :value="100" :segments="3" />
          </div>
        </div>

        <!-- quest detail + map filters -->
        <CorePanel class="flex w-[440px] flex-none flex-col" padding="md">
          <div class="flex h-full min-h-0 flex-col">
            <CoreCard
              :image="active.hero"
              image-position="top"
              :media-height="175"
              :title="active.title"
              :uppercase="false"
              :icon="active.icon"
              :subtitle="active.subtitle"
            >
              <p class="core-text">{{ active.text }}</p>
            </CoreCard>

            <CoreDivider class="mt-5" />
            <CoreObjective class="mx-5 py-4" :text="active.objective" :state="active.state" :trailing="active.trailing" />
            <CoreDivider class="mb-5" />

            <!-- The mockup lines the copy up with the CARD's text, one step in from the picture. -->
            <CoreHeading class="mx-5" title="Map filters" slash size="sm" />
            <div class="mx-5 mt-4 flex flex-col gap-4">
              <CoreCheckbox v-for="f in FILTERS" :key="f.value" v-model="filters" :value="f.value" :label="f.label">
                <template #icon>
                  <CoreIcon
                    :name="f.icon"
                    size="md"
                    :class="['core-check__icon', f.accent ? 'text-accent' : '']"
                  />
                </template>
              </CoreCheckbox>
            </div>

            <!-- The mockup pins the call to action to the bottom edge of the panel. -->
            <div class="mt-auto pt-7">
              <CoreButton variant="primary" size="lg" block icon="navigation" @click="tracking = true">
                Track quest
              </CoreButton>
            </div>
          </div>
        </CorePanel>
      </div>

      <template #footer-start>
        <CoreKeyHints bare align="start" :items="[{ key: 'ESC', label: 'Back' }]" />
      </template>
      <template #footer-end>
        <CoreKeyHints bare :items="HINTS" />
        <div class="ml-9 flex flex-col items-end">
          <p class="core-flavor text-fg">More Than a Map</p>
          <CoreDash class="mt-1.5" :width="42" />
        </div>
      </template>
    </CoreScreen>

    <CoreDialog
      v-model:open="tracking"
      title="Track quest"
      :subtitle="active.title"
      icon="navigation"
      size="sm"
    >
      <p class="core-text">
        {{ active.objective }} — the route goes on your map and the objective is pinned to the HUD tracker.
      </p>
      <template #footer>
        <CoreButton @click="tracking = false">Cancel</CoreButton>
        <CoreButton variant="primary" icon="navigation" @click="tracking = false">Track</CoreButton>
      </template>
    </CoreDialog>
  </div>
</template>
