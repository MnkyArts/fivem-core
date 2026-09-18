<script setup>
// StepperGallery — both CoreStepper modes (items and numeric), the sizes, showCount, format, loop,
// block and disabled (DESIGN §37.5, Navigation).
// Global tags only (CoreStepper, CoreIcon); KitStage/KitSection are story plumbing.
import { onMounted, ref, useTemplateRef } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const PLATES = ['Standard White', 'Yellow Plates', 'Blue on White', 'North Yankton', 'Ecola']

const LIVERIES = [
  { value: 0, label: 'Factory' },
  { value: 1, label: 'Street Racer' },
  { value: 2, label: 'Desert Camo' },
  { value: 3, label: 'Faction Colours', disabled: true },
  { value: 4, label: 'Matte Black' },
]

const SHIFTS = ['Night', 'Morning', 'Afternoon', 'Evening']

const plate = ref('Yellow Plates')
const livery = ref(1)
const wheel = ref(0)
const payout = ref(1750)
const tint = ref(35)
const shiftSm = ref('Morning')
const shift = ref('Morning')
const shiftLg = ref('Evening')
const seats = ref(4)
const locked = ref('Standard White')
const focused = ref('Blue on White')

// The box lights up while anything inside it has the focus — put it there so the shot shows it.
const focusDemo = useTemplateRef('focusDemo')
onMounted(() => {
  const value = focusDemo.value && focusDemo.value.querySelector('.core-stepper__value')
  if (value) value.focus({ preventScroll: true })
})

const money = (value) => '$' + Number(value).toLocaleString('en-US')
const percent = (value) => value + ' %'
const wheelName = (value) => 'Type ' + value
const seatCount = (value) => value + (value === 1 ? ' seat' : ' seats')
</script>

<template>
  <KitStage
    title="CoreStepper"
    description="The ‹ value › cycler in the shared box look. Pass `items` and it walks their values; leave
      `items` out and it is a number between min and max. One tab stop — ←/→ step it wherever the focus sits."
  >
    <KitSection label="items — a character / vehicle option" layout="column" :gap="14">
      <div style="display: flex; align-items: center; gap: 18px">
        <span class="core-label" style="width: 130px">Licence plate</span>
        <CoreStepper v-model="plate" :items="PLATES" :show-count="true" loop />
      </div>
      <p class="core-flavor">value → {{ plate }}</p>
    </KitSection>

    <KitSection label="Disabled entries are skipped" layout="column" :gap="14" note="“Faction Colours” needs rank 3 — the stepper walks straight past it.">
      <div style="display: flex; align-items: center; gap: 18px">
        <span class="core-label" style="width: 130px">Livery</span>
        <CoreStepper v-model="livery" :items="LIVERIES" show-count />
      </div>
      <p class="core-flavor">value → {{ livery }}</p>
    </KitSection>

    <KitSection label="Numeric — min / max / step" layout="column" :gap="14" note="No loop: wheel type sits on its minimum, so the ‹ chevron is dead.">
      <div style="display: flex; align-items: center; gap: 18px">
        <span class="core-label" style="width: 130px">Wheel type</span>
        <CoreStepper v-model="wheel" :min="0" :max="9" :format="wheelName" />
      </div>
      <div style="display: flex; align-items: center; gap: 18px">
        <span class="core-label" style="width: 130px">Window tint</span>
        <CoreStepper v-model="tint" :min="0" :max="100" :step="5" :format="percent" />
      </div>
    </KitSection>

    <KitSection label="format — units and currency" layout="column" :gap="14" note="`format` also keeps a step of 250 from ever printing 1749.9999.">
      <div style="display: flex; align-items: center; gap: 18px">
        <span class="core-label" style="width: 130px">Payout</span>
        <CoreStepper v-model="payout" :min="0" :max="5000" :step="250" :format="money" />
      </div>
    </KitSection>

    <KitSection label="Sizes" :gap="18" note="sm 30 px · md 40 px · lg 52 px (--core-h-*).">
      <CoreStepper v-model="shiftSm" :items="SHIFTS" size="sm" loop />
      <CoreStepper v-model="shift" :items="SHIFTS" loop />
      <CoreStepper v-model="shiftLg" :items="SHIFTS" size="lg" loop />
    </KitSection>

    <KitSection label="block and disabled" layout="column" :gap="16" note="block fills the row — a settings column; disabled keeps the value readable.">
      <div style="width: 360px; display: flex; flex-direction: column; gap: 14px">
        <CoreStepper v-model="seats" :min="1" :max="8" :format="seatCount" block />
        <CoreStepper v-model="locked" :items="PLATES" block disabled />
      </div>
    </KitSection>

    <KitSection label="States" layout="column" :gap="0" note="Focused on mount: accent border plus the --core-focus halo. Hover lifts the border to white 28 % and a chevron to fg; the disabled control above keeps its value readable at 45 %.">
      <div ref="focusDemo">
        <CoreStepper v-model="focused" :items="PLATES" show-count loop />
      </div>
    </KitSection>
  </KitStage>
</template>
