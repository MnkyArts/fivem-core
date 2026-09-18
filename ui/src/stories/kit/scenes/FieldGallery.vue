<script setup>
// FieldGallery — CoreField stacked and inline (DESIGN §37.5).
// Left: the settings block `inline` was written for — a sentence and its hint on the left, the
// control right-aligned in `controlWidth`, a hairline under every row. Right: the stacked form,
// where the label wears the label voice and the message sits under the control.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const LANGUAGES = [
  { value: 'en', label: 'English' },
  { value: 'de', label: 'Deutsch' },
  { value: 'fr', label: 'Français' },
]
const QUALITY = ['Low', 'Normal', 'High', 'Ultra']

const language = ref('en')
const quality = ref('High')
const hudScale = ref(100)
const radioVolume = ref(60)
const callsign = ref('KESSLER-7')

const name = ref('Mara Kessler')
const phone = ref('555 0142')
const amount = ref('2400')
const bio = ref('Ex-mechanic out of Sandy Shores. Keeps a spare fuel can in every trunk she touches.')
const plate = ref('LS')

// The surfaces group owns `.core-panel`; this scene must stand on its own files only, so the
// frame around each block is written from the tokens instead.
const panelStyle = {
  width: '100%',
  background: 'var(--color-panel)',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  boxShadow: 'var(--shadow-ui)',
}
</script>

<template>
  <KitStage
    title="Field"
    description="The wrapper every control sits in. It owns the DOM id and hands it to the slot with `invalid`, so a
                 label, a control and its message stay wired together — stacked for a form, inline for a settings row."
    :width="1180"
  >
    <div class="grid" style="grid-template-columns: minmax(0, 1fr) minmax(0, 1fr); gap: 44px">
      <KitSection label="Inline — settings" layout="column" :gap="0"
                  note="Label in body copy, hint under it, control right-aligned in controlWidth (50 % by default).">
        <div :style="panelStyle" style="padding: 6px 20px 8px">
          <CoreField inline label="Interface language" hint="Applies to menus and notifications." control-width="200px">
            <template #default="{ id }">
              <CoreSelect :id="id" v-model="language" :items="LANGUAGES" />
            </template>
          </CoreField>

          <CoreField inline label="Texture quality" hint="Restart required." control-width="200px">
            <template #default="{ id }">
              <CoreSelect :id="id" v-model="quality" :items="QUALITY" />
            </template>
          </CoreField>

          <CoreField inline label="HUD scale" hint="Percent of the default size." control-width="200px">
            <template #default="{ id }">
              <CoreNumberInput :id="id" v-model="hudScale" :min="60" :max="140" :step="5" suffix="%" />
            </template>
          </CoreField>

          <CoreField inline label="Radio volume" control-width="200px">
            <template #default="{ id }">
              <CoreNumberInput :id="id" v-model="radioVolume" :min="0" :max="100" :step="10" suffix="%" />
            </template>
          </CoreField>

          <CoreField
            inline label="Dispatch callsign" required error="Already taken by another unit."
            control-width="200px"
          >
            <template #default="{ id, invalid }">
              <CoreInput :id="id" v-model="callsign" :invalid="invalid" />
            </template>
          </CoreField>
        </div>
      </KitSection>

      <KitSection label="Stacked — a form" layout="column" :gap="0"
                  note="Label voice over the control; an error replaces the hint rather than stacking under it.">
        <div :style="panelStyle" style="padding: 20px">
          <CoreField label="Character name" required hint="Shown to everyone in range.">
            <template #default="{ id, invalid }">
              <CoreInput :id="id" v-model="name" :invalid="invalid" icon="user" clearable />
            </template>
          </CoreField>

          <CoreField label="Phone number" hint="Six digits, no dashes.">
            <template #default="{ id }">
              <CoreInput :id="id" v-model="phone" prefix="+1" />
            </template>
          </CoreField>

          <CoreField label="Transfer amount" required>
            <template #default="{ id }">
              <CoreInput :id="id" v-model="amount" suffix="$" />
            </template>
          </CoreField>

          <CoreField label="Plate" required error="A plate needs at least three characters.">
            <template #default="{ id, invalid }">
              <CoreInput :id="id" v-model="plate" :invalid="invalid" icon="car" />
            </template>
          </CoreField>

          <CoreField label="Biography" hint="Backstory other players can read at the registrar.">
            <template #default="{ id }">
              <CoreTextarea :id="id" v-model="bio" :rows="4" :maxlength="180" counter />
            </template>
          </CoreField>
        </div>
      </KitSection>
    </div>
  </KitStage>
</template>
