<script setup>
// ShowcaseMainMenu — mockup 1 (`(1)`, the WAYFINDER main menu) rebuilt from kit components only
// (DESIGN §37.7). The completeness proof for the Surfaces and Navigation groups: nothing here is
// custom CSS, every box is a <Core…> tag placed with Tailwind layout utilities, and the only
// literal geometry is the position of a block on the 1920 x 1080 canvas.
//
// Composition, left to right: the brand lockup and its "AN OPEN WORLD ACTION RPG" eyebrow, the `lg`
// CoreMenu whose active row dissolves into the key art, the LAST PLAYED CoreCard above the footer
// line; top right the CorePlayerChip, the hairline CoreTagline and its accent dash.
//
// Alive, not a picture: the menu follows the pointer (`select-on-hover`) and the arrow keys, Enter
// or a click raises a CoreToast, EXIT opens a CoreDialog, and the card is a real interactive card.
import { onBeforeUnmount, ref } from 'vue'
import keyart from '../assets/keyart-menu.jpg'
import lastPlayed from '../assets/lastplayed.jpg'
import portrait from '../assets/avatar.jpg'

const active = ref('continue')
const quitOpen = ref(false)
const resumed = ref(false)
const toast = ref(null)
let timer = null

const items = [
  { value: 'continue', label: 'Continue', icon: 'play' },
  { value: 'load', label: 'Load Game', icon: 'folder' },
  { value: 'settings', label: 'Settings', icon: 'settings' },
  { value: 'exit', label: 'Exit', icon: 'exit' },
]

const NOTES = {
  continue: {
    tone: 'success',
    title: 'Loading save',
    message: 'A Brighter Tomorrow — Northern Ridge, 72 % complete.',
  },
  load: { tone: 'info', title: 'Save slots', message: 'Four saves on this profile, newest first.' },
  settings: { tone: 'info', title: 'Settings', message: 'Display, audio, controls, gameplay.' },
}

/** One toast at a time, replaced in place — the shell's notification behaviour (§37.6). */
function say (note) {
  if (!note) return
  toast.value = note
  clearTimeout(timer)
  timer = setTimeout(() => { toast.value = null }, 4200)
}

function onSelect (item) {
  if (item.value === 'exit') { quitOpen.value = true; return }
  say(NOTES[item.value])
}

function resume () {
  active.value = 'continue'
  resumed.value = true
  say(NOTES.continue)
}

function quit () {
  quitOpen.value = false
  say({ tone: 'warning', title: 'Session ended', message: 'Returning to the desktop.' })
}

onBeforeUnmount(() => clearTimeout(timer))
</script>

<template>
  <div class="relative w-full h-screen min-h-[900px] overflow-hidden">
    <!-- `left` is the main-menu scrim: ink over the key art, gone by 62 % of the width. -->
    <CoreBackground variant="left" :image="keyart" />

    <!-- ---- left column: brand, eyebrow, menu, LAST PLAYED ------------------------------------ -->
    <div class="absolute left-[74px] top-[62px] bottom-[182px] flex flex-col items-start">
      <CoreBrand size="lg" name="Wayfinder" tagline="Explore a larger tomorrow">
        <template #logo>
          <!-- The mark: a hollow coral triangle with a second one laid over its lower right. The
               overlay is white at 24 %, so it reads as slate on the ink and as pale coral where it
               crosses the arm — exactly what the mockup does. -->
          <svg viewBox="0 0 108 93" role="presentation">
            <path
              fill="currentColor"
              fill-rule="evenodd"
              d="M54 0 L108 93 L0 93 Z M54 37 L76 74 L31 74 Z"
            />
            <path fill="var(--color-fg)" opacity="0.24" d="M66 53 L108 93 L46 93 Z" />
          </svg>
        </template>
      </CoreBrand>

      <p class="core-eyebrow mt-[90px]">An open world action RPG</p>

      <CoreMenu
        v-model="active"
        class="mt-[52px] w-[440px] gap-[8px]"
        :items="items"
        size="lg"
        select-on-hover
        @select="onSelect"
      />

      <div class="flex-1 min-h-[40px]"></div>

      <CoreCard
        class="w-[632px]"
        :image="lastPlayed"
        :media-width="204"
        :media-height="182"
        eyebrow="Last played"
        title="A brighter tomorrow"
        subtitle="Northern Ridge"
        icon="map-marker"
        interactive
        :selected="resumed"
        @click="resume"
      >
        <template #meta>
          <span><b>72%</b> Complete</span>
          <span>Mar 12, 2024&nbsp;&nbsp;18:24</span>
        </template>
      </CoreCard>
    </div>

    <!-- ---- top right: player chip, hairline tagline ------------------------------------------ -->
    <div class="absolute right-[64px] top-[47px] flex items-start gap-[46px]">
      <CorePlayerChip
        name="Travis"
        :avatar="portrait"
        :level="32"
        :progress="0.57"
        status="online"
      />
      <CoreTagline :lines="['Explore', 'Survive', 'Belong']" rule :dash="44" />
    </div>

    <!-- ---- footer line ----------------------------------------------------------------------- -->
    <div class="absolute left-[74px] right-[64px] bottom-[52px] flex items-center justify-between">
      <span class="flex items-center gap-[24px]">
        <CoreDash :width="50" />
        <span class="core-eyebrow">Worlds are better with stories.</span>
      </span>
      <span class="flex items-center gap-[20px]">
        <span class="core-eyebrow">Wayfinder</span>
        <span class="core-eyebrow">v1.0</span>
      </span>
    </div>

    <!-- ---- live pieces ----------------------------------------------------------------------- -->
    <div class="absolute right-[64px] bottom-[110px] flex justify-end pointer-events-none">
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

    <CoreDialog
      v-model:open="quitOpen"
      title="Leave Wayfinder?"
      subtitle="Your last checkpoint was saved 4 minutes ago"
      icon="exit"
      tone="warning"
      size="sm"
    >
      <p class="core-text">Unsaved progress since the checkpoint is lost when you quit to the desktop.</p>
      <template #footer>
        <CoreButton variant="ghost" @click="quitOpen = false">Stay</CoreButton>
        <CoreButton variant="danger" kbd="Q" @click="quit">Quit to desktop</CoreButton>
      </template>
    </CoreDialog>
  </div>
</template>
