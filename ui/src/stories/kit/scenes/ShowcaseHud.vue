<script setup>
// ShowcaseHud — mockup 2 (`(2)`, the in-world HUD) rebuilt from kit components only (DESIGN §37.7).
// The completeness proof for the Game and Data groups: CoreStatBar, CoreCompass, CoreTag,
// CoreTracker, CorePrompt(Group) and CoreHotbar over a `vignette` CoreBackground, placed with
// Tailwind layout utilities and nothing else.
//
// Two honest gaps are visible here and listed in the run report: the minimap is a PLACEHOLDER (the
// real one is the game's own round map, which a CEF can never draw), and the vitals plate is a bare
// `bg-hud rounded-ui` box because the kit has no HUD-plate surface — a CorePanel is 90 % opaque and
// would sit on the world like a window.
//
// Alive: the demo strip bottom left moves the vitals and turns the compass, the hotbar cells select
// and raise a CoreToast, and the [F] prompt is `interactive`, so it can actually be clicked.
import { computed, onBeforeUnmount, ref } from 'vue'
import keyart from '../assets/keyart.jpg'
import pistol from '../assets/item-pistol.jpg'
import medkit from '../assets/item-medkit.jpg'
import water from '../assets/item-water.jpg'
import binoculars from '../assets/item-binoculars.jpg'

const health = ref(100)
const armour = ref(75)
const stamina = ref(80)
const heading = ref(2)
// -1: nothing drawn. Mockup 2 shows four identical cells, and the coral selection ring is loud —
// it belongs to the first click, not to the resting HUD.
const slot = ref(-1)
const inVehicle = ref(false)
const toast = ref(null)
let timer = null

// No `rarity`: the mockup's cells carry nothing but art, a key cap and a count. SlotGallery is
// where the rarity lines are shown.
const items = [
  { id: 'pistol', image: pistol, count: 12, label: 'Combat pistol' },
  { id: 'medkit', image: medkit, count: 4, label: 'Medkit' },
  { id: 'water', image: water, count: 6, label: 'Water' },
  { id: 'binoculars', image: binoculars, count: 1, label: 'Binoculars' },
]

const prompts = computed(() => [
  { keys: 'F', label: inVehicle.value ? 'Leave vehicle' : 'Enter vehicle', icon: 'steering', interactive: true, active: inVehicle.value },
  { keys: 'R', label: 'Open trunk', icon: 'toolbox' },
])

const clamp = (n) => Math.max(0, Math.min(100, Math.round(n)))

function say (note) {
  toast.value = note
  clearTimeout(timer)
  timer = setTimeout(() => { toast.value = null }, 3600)
}

function hit () {
  const soak = Math.min(armour.value, 26)
  armour.value = clamp(armour.value - soak)
  health.value = clamp(health.value - (28 - soak * 0.6))
  stamina.value = clamp(stamina.value - 14)
  say({ tone: 'danger', title: 'Hit', message: 'Rifle round, left shoulder. Armour took most of it.' })
}

function patch () {
  health.value = 100
  armour.value = 75
  stamina.value = 80
  say({ tone: 'success', title: 'Patched up', message: 'Medkit used — vitals back to full.' })
}

function pick (index, item) {
  slot.value = index
  say({ tone: 'info', title: 'Equipped', message: item.label + ' — ' + item.count + ' left.' })
}

function board () {
  inVehicle.value = !inVehicle.value
  say({
    tone: 'info',
    title: inVehicle.value ? 'In the truck' : 'On foot',
    message: inVehicle.value ? 'Engine running. 842 m to the old tower.' : 'You step back out into the grass.',
  })
}

onBeforeUnmount(() => clearTimeout(timer))
</script>

<template>
  <div class="relative w-full h-screen min-h-[900px] overflow-hidden">
    <CoreBackground variant="vignette" :image="keyart" :dim="0.3" />

    <!-- ---- vitals plate, top left ------------------------------------------------------------ -->
    <div class="absolute left-[66px] top-[47px] flex flex-col gap-[10px] rounded-ui bg-hud p-[14px] shadow-ui-sm">
      <CoreStatBar icon="heart" tone="health" :value="health" />
      <CoreStatBar icon="shield" tone="armour" :value="armour" />
      <CoreStatBar icon="bolt" tone="stamina" :value="stamina" />
    </div>

    <!-- ---- compass, top centre --------------------------------------------------------------- -->
    <div class="absolute left-0 right-0 top-[34px] flex justify-center">
      <!-- No markers: mockup 2 keeps the band to ticks and cardinals, and a blip beside NE reads as
           clutter at this width. CompassGallery is where the marker API is shown off. -->
      <CoreCompass :heading="heading" />
    </div>

    <!-- ---- clock and minimap, top right ------------------------------------------------------- -->
    <div class="absolute right-[37px] top-[22px] flex flex-col items-end">
      <!-- `dark` paints the glyph in the tone, which is what makes the mockup's sun warm. -->
      <CoreTag variant="dark" size="lg" tone="warning" icon="sun" label="18:24" />

      <!-- PLACEHOLDER: the round map is the game's own, drawn under the CEF. The kit only owns the
           ring around it, so the scene draws the hole it has to leave free. -->
      <div class="mt-[2px] mr-[18px] flex flex-col items-center">
        <span class="core-display core-display--sm">N</span>
        <div class="mt-[4px] flex h-[204px] w-[204px] flex-col items-center justify-center gap-[6px] rounded-full border-2 border-fg-dim bg-hud shadow-ui-sm">
          <CoreIcon name="map" size="xl" class="text-fg-dim" />
          <span class="core-eyebrow">Minimap</span>
        </div>
      </div>

      <CoreTracker
        class="mt-[16px]"
        title="A brighter tomorrow"
        text="Meet the contact at the old tower."
        distance="842 m"
        tone="warning"
      />
    </div>

    <!-- ---- interaction prompts, on the truck --------------------------------------------------- -->
    <div class="absolute right-[3.5%] top-[59.5%]">
      <CorePromptGroup :items="prompts" align="start" @select="board" />
    </div>

    <!-- ---- hotbar, bottom centre --------------------------------------------------------------- -->
    <div class="absolute bottom-[46px] left-0 right-0 flex justify-center">
      <CoreHotbar :items="items" :active="slot" @select="pick" />
    </div>

    <!-- ---- demo strip (not in the mockup: the scene has to be drivable) ------------------------- -->
    <div class="absolute bottom-[46px] left-[66px] flex w-[320px] flex-col gap-[12px] rounded-ui bg-hud p-[14px] shadow-ui-sm">
      <span class="core-label">Demo controls</span>
      <div class="flex gap-[8px]">
        <CoreButton size="sm" variant="danger" icon="skull" @click="hit">Take a hit</CoreButton>
        <CoreButton size="sm" variant="success" icon="medkit" @click="patch">Patch up</CoreButton>
      </div>
      <CoreSlider v-model="heading" :min="0" :max="359" label="Heading" show-value suffix="&deg;" />
    </div>

    <!-- ---- live toast ---------------------------------------------------------------------------- -->
    <div class="absolute bottom-[150px] right-[37px] flex justify-end pointer-events-none">
      <Transition name="core-slide-up">
        <CoreToast
          v-if="toast"
          :tone="toast.tone"
          :title="toast.title"
          :message="toast.message"
          dismissible
          @dismiss="toast = null"
        />
      </Transition>
    </div>
  </div>
</template>
