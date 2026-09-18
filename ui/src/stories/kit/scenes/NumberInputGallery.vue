<script setup>
// NumberInputGallery — CoreNumberInput in every size, bound and state (DESIGN §37.5).
// The pairs at the bounds prove the button disables itself rather than clamping silently, and the
// live readout proves the model is a NUMBER (never the string the field is holding while typing).
import { computed, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const small = ref(3)
const medium = ref(12)
const large = ref(250)

const atMin = ref(0)
const atMax = ref(10)
const free = ref(48)

const fuel = ref(37.5)
const tax = ref(7.25)
const weight = ref(24)

const bad = ref(999)
const locked = ref(1)

const qty = ref(4)
const unit = 1450
const total = computed(() => (qty.value * unit).toLocaleString('en-US'))
</script>

<template>
  <KitStage
    title="Number input"
    description="`[-] 12 [+]` on the box look: square buttons on the control height, the value in the display voice with
                 tabular figures. Hold a button to repeat (400 ms, then every 60 ms), ↑/↓ steps, and the field clamps
                 and rounds to `precision` on blur or Enter."
  >
    <KitSection label="Sizes" layout="grid" :columns="3" :gap="20"
                note="Buttons are square on --core-h-sm | -md | -lg, so the whole control scales with `size`.">
      <CoreNumberInput v-model="small" size="sm" :min="1" :max="99" />
      <CoreNumberInput v-model="medium" size="md" :min="1" :max="99" />
      <CoreNumberInput v-model="large" size="lg" :min="0" :max="999" :step="10" />
    </KitSection>

    <KitSection label="Bounds" layout="grid" :columns="3" :gap="20"
                note="A button at its bound is disabled (opacity 0.3, not-allowed) — a held repeat stops there too.">
      <div>
        <p class="core-label" style="margin-bottom: 8px">At min (0–10)</p>
        <CoreNumberInput v-model="atMin" :min="0" :max="10" />
      </div>
      <div>
        <p class="core-label" style="margin-bottom: 8px">At max (0–10)</p>
        <CoreNumberInput v-model="atMax" :min="0" :max="10" />
      </div>
      <div>
        <p class="core-label" style="margin-bottom: 8px">Unbounded</p>
        <CoreNumberInput v-model="free" />
      </div>
    </KitSection>

    <KitSection label="Step, precision and units" layout="grid" :columns="3" :gap="20"
                note="Without `precision` the decimals come from `step`, so 0.5 steps keep one decimal.">
      <div>
        <p class="core-label" style="margin-bottom: 8px">Jerry can</p>
        <CoreNumberInput v-model="fuel" :min="0" :max="60" :step="0.5" suffix="L" />
      </div>
      <div>
        <p class="core-label" style="margin-bottom: 8px">Sales tax</p>
        <CoreNumberInput v-model="tax" :min="0" :max="30" :step="0.25" :precision="2" suffix="%" />
      </div>
      <div>
        <p class="core-label" style="margin-bottom: 8px">Cargo weight</p>
        <CoreNumberInput v-model="weight" :min="0" :max="400" :step="4" suffix="KG" />
      </div>
    </KitSection>

    <KitSection label="States" layout="grid" :columns="3" :gap="20">
      <div>
        <p class="core-label" style="margin-bottom: 8px">Invalid</p>
        <CoreNumberInput v-model="bad" :min="1" :max="20" invalid />
      </div>
      <div>
        <p class="core-label" style="margin-bottom: 8px">Disabled</p>
        <CoreNumberInput v-model="locked" :min="1" :max="5" disabled />
      </div>
      <div>
        <p class="core-label" style="margin-bottom: 8px">Sold in packs of 4</p>
        <CoreNumberInput v-model="qty" :min="4" :max="64" :step="4" />
      </div>
    </KitSection>

    <KitSection label="Live model" layout="column" :gap="10"
                note="The model is a number: the total below is arithmetic, not string concatenation.">
      <p class="core-text" style="margin: 0">
        <b class="text-fg">{{ qty }}</b> × 9 mm box @ $1,450 — total
        <b class="text-fg core-num" style="font-size: 17px">${{ total }}</b>
        <span class="text-fg-faint"> (typeof {{ typeof qty }})</span>
      </p>
    </KitSection>
  </KitStage>
</template>
