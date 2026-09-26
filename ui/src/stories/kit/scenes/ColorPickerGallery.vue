<script setup>
// ColorPickerGallery — CoreColorPicker (DESIGN §53, §37.5 Forms — choice): inline with the default
// palette, alpha over the checkerboard, a custom swatch set, the popover trigger of a form row,
// no swatches at all, invalid and disabled.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const paint = ref('#F6503F')
const marker = ref('#55B6F780')
const faction = ref('#1E9E5A')
const blip = ref('#F5A623')
const empty = ref('')
const plain = ref('#2F5FD0')

const FACTION = [
  { value: '#1E9E5A', label: 'Families' }, { value: '#8E44AD', label: 'Ballas' }, { value: '#F2D43D', label: 'Vagos' },
  { value: '#2F5FD0', label: 'LSPD' }, { value: '#E0312B', label: 'EMS' }, { value: '#6B7480', label: 'Neutral' },
]
</script>

<template>
  <KitStage
    title="CoreColorPicker"
    description="Hex field, swatches and one slider per channel — never the native colour input, whose OS popup the
      off-screen CEF cannot show. Each track is the live gradient of its own channel; alpha sits on a checkerboard.
      The model is #RRGGBB (or #RRGGBBAA with `alpha` when not opaque), upper-case — the §43 `color` value."
    :width="1000"
  >
    <div class="grid gap-10" style="grid-template-columns: repeat(3, max-content)">
      <KitSection label="Inline — default palette" layout="column" :gap="10">
        <CoreColorPicker v-model="paint" />
        <p class="text-ui-sm text-fg-faint" style="margin: 0">{{ paint }}</p>
      </KitSection>
      <KitSection label="Alpha" layout="column" :gap="10" note="8-digit hex while the colour is translucent.">
        <CoreColorPicker v-model="marker" alpha />
        <p class="text-ui-sm text-fg-faint" style="margin: 0">{{ marker }}</p>
      </KitSection>
      <KitSection label="Custom swatches" layout="column" :gap="10">
        <CoreColorPicker v-model="faction" :swatches="FACTION" />
        <p class="text-ui-sm text-fg-faint" style="margin: 0">{{ faction }}</p>
      </KitSection>
    </div>

    <KitSection label="Popover — the form row" layout="grid" :columns="3" :gap="24"
                note="`popover` folds the picker behind a box-look trigger; Escape and an outside click close it.">
      <CoreField label="Blip colour"><CoreColorPicker v-model="blip" popover /></CoreField>
      <CoreField label="Unset" hint="An empty model shows the placeholder."><CoreColorPicker v-model="empty" popover /></CoreField>
      <CoreField label="Invalid" error="Pick a darker colour."><CoreColorPicker v-model="blip" popover invalid /></CoreField>
    </KitSection>

    <KitSection label="No swatches · disabled" layout="row" :gap="40">
      <CoreColorPicker v-model="plain" :swatches="[]" />
      <CoreColorPicker :model-value="'#B68CFF'" disabled />
    </KitSection>
  </KitStage>
</template>
