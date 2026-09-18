<script setup>
// RadioGallery — CoreRadioGroup + CoreRadio (DESIGN §37.5, Forms — choice).
// The ring language is the objective ring of the map mockup; the `card` variant is the big
// selectable tile a spawn picker or a difficulty screen is made of. Arrow keys inside a group are
// the browser's own radio roving — nothing in the kit re-implements them.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const spawn = ref('apartment')
const SPAWNS = [
  { value: 'apartment', label: 'Apartment', description: 'Mirror Park, 4 Blvd — your own bed.', icon: 'bed' },
  { value: 'garage', label: 'Garage', description: 'Vehicles stay where you parked them.', icon: 'garage' },
  { value: 'hospital', label: 'Pillbox Hill Medical', description: 'Closest respawn, no vehicle.', icon: 'hospital' },
  { value: 'faction', label: 'Faction HQ', description: 'Needs a rank of Lieutenant or above.', icon: 'shield', disabled: true },
]

const payment = ref('cash')
const PAYMENT = [
  { value: 'cash', label: 'Cash', description: 'On hand: $4,280' },
  { value: 'bank', label: 'Bank transfer', description: 'Maze Bank · $18,940' },
  { value: 'credit', label: 'Faction credit', description: 'Needs an officer to sign it off.', disabled: true },
]

const difficulty = ref('Normal')
const DIFFICULTY = ['Story', 'Normal', 'Hardcore']

const size = ref('md')
const solo = ref('yes')
const voice = ref('No')
const locked = ref('b')
</script>

<template>
  <KitStage
    title="Radio"
    description="One choice out of a few. CoreRadioGroup provides the model, name, size and variant; CoreRadio
      injects them or works alone with its own v-model. The `card` variant turns the same control into the big
      selectable tile of a spawn or difficulty screen."
  >
    <KitSection label="Cards — spawn location" layout="column" :gap="0" note="checked = accent-hi border, accent-soft fill, a soft coral glow">
      <CoreRadioGroup v-model="spawn" variant="card" style="width: 460px">
        <CoreRadio
          v-for="s in SPAWNS"
          :key="s.value"
          :value="s.value"
          :description="s.description"
          :disabled="s.disabled"
        >
          <span class="flex items-center" style="gap: 9px">
            <CoreIcon :name="s.icon" size="sm" />
            <span>{{ s.label }}</span>
          </span>
        </CoreRadio>
      </CoreRadioGroup>
      <p class="core-label" style="margin-top: 14px">spawn — {{ spawn }}</p>
    </KitSection>

    <KitSection label="Rings — payment method" layout="column" :gap="0" note="circle 20 px, white 38 % hairline; checked = 2 px accent-hi ring + a 10 px accent dot">
      <CoreRadioGroup v-model="payment" :items="PAYMENT" />
      <p class="core-label" style="margin-top: 14px">paying with — {{ payment }}</p>
    </KitSection>

    <KitSection label="Horizontal" layout="column" :gap="0" note="orientation='horizontal' — ← / → move between the options, the browser skips the disabled ones">
      <CoreRadioGroup v-model="difficulty" :items="DIFFICULTY" orientation="horizontal" />
    </KitSection>

    <KitSection label="Sizes" layout="column" :gap="0" note="16 / 20 / 24 px rings, the label follows --text-ui">
      <CoreRadioGroup v-model="size" orientation="horizontal" size="sm">
        <CoreRadio value="sm" label="Small" />
        <CoreRadio value="md" label="Medium" size="md" />
        <CoreRadio value="lg" label="Large" size="lg" />
      </CoreRadioGroup>
    </KitSection>

    <KitSection label="States" layout="grid" :columns="4" :gap="16" note="hover brightens the hairline; Tab shows the 2 px accent-hi focus ring">
      <CoreRadio v-model="locked" value="a" label="Selectable" />
      <CoreRadio v-model="locked" value="b" label="Checked" />
      <CoreRadio :model-value="'x'" value="y" label="Disabled" disabled />
      <CoreRadio :model-value="'y'" value="y" label="Disabled, checked" disabled />
    </KitSection>

    <KitSection label="Disabled group" layout="column" :gap="0" note="`disabled` on the group reaches every option through inject">
      <CoreRadioGroup v-model="voice" :items="['Yes', 'No']" orientation="horizontal" disabled />
    </KitSection>

    <KitSection label="Standalone" layout="column" :gap="12" note="no group: each radio carries its own v-model and generated name">
      <CoreRadio v-model="solo" value="yes" label="Ride solo" description="No faction members get a call." />
      <CoreRadio v-model="solo" value="crew" label="Call the crew" description="Pings every member within 800 m." />
    </KitSection>

    <KitSection label="Item slot" layout="column" :gap="0" note="`item` customises the label without giving up the group's model">
      <CoreRadioGroup v-model="difficulty" :items="DIFFICULTY" orientation="horizontal">
        <template #item="{ item }">
          <span class="flex items-center" style="gap: 8px">
            <CoreIcon name="skull" size="sm" />
            <span>{{ item.label }}</span>
          </span>
        </template>
      </CoreRadioGroup>
    </KitSection>
  </KitStage>
</template>
