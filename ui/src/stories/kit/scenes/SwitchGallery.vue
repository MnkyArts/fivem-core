<script setup>
// SwitchGallery — CoreSwitch (DESIGN §37.5, Forms — choice).
// A squared track, not a pill: the kit's radii are 3 / 4 / 6 px and a rounded capsule would be the
// only round thing on a settings screen. The first section is the shape a real settings page has —
// full-width rows, label left, switch right, a hairline between them.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const settings = ref({
  hud: true,
  minimap: true,
  voice: false,
  crosshair: true,
  damage: false,
})

const on = ref(true)
const off = ref(false)
const small = ref(true)
const medium = ref(true)
const large = ref(true)
const right = ref(true)

const rows = [
  { key: 'hud', label: 'Show the HUD', desc: 'Vitals, money and the hotbar. The compass has its own switch.' },
  { key: 'minimap', label: 'Minimap', desc: 'Hidden inside interiors either way.' },
  { key: 'voice', label: 'Push to talk', desc: 'Off = open mic on the proximity channel.' },
  { key: 'crosshair', label: 'Crosshair', desc: 'Never drawn while a weapon is holstered.' },
  { key: 'damage', label: 'Damage numbers', desc: 'Floating numbers over whatever you hit.' },
]

const rowStyle = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: '32px',
  padding: '14px 0',
  borderBottom: '1px solid var(--color-border)',
}
</script>

<template>
  <KitStage
    title="Switch"
    description="An on/off setting. The input is hidden but still focusable, the sibling track does the paint:
      42 x 22 squared track, radius 3, a 16 px white thumb that slides 20 px onto the accent gradient."
  >
    <KitSection label="A settings page" layout="column" :gap="0" note="labelPosition='left' (the default): label left, switch right, hairline under the row">
      <div style="width: 560px">
        <div v-for="row in rows" :key="row.key" :style="rowStyle">
          <span class="flex flex-col" style="gap: 3px">
            <span class="text-fg text-ui">{{ row.label }}</span>
            <span class="text-fg-dim text-ui-sm">{{ row.desc }}</span>
          </span>
          <CoreSwitch v-model="settings[row.key]" />
        </div>
      </div>
    </KitSection>

    <KitSection label="Label positions" layout="column" :gap="18" note="'left' = the settings row; 'right' = the switch reads like a checkbox">
      <CoreSwitch v-model="right" label="Auto-equip a picked-up weapon" style="width: 420px" />
      <CoreSwitch v-model="on" label-position="right" label="Auto-equip a picked-up weapon" />
    </KitSection>

    <KitSection label="Sizes" :gap="34" note="34 x 18 / 42 x 22 / 52 x 26 — thumb 12 / 16 / 20">
      <CoreSwitch v-model="small" size="sm" label-position="right" label="Small" />
      <CoreSwitch v-model="medium" size="md" label-position="right" label="Medium" />
      <CoreSwitch v-model="large" size="lg" label-position="right" label="Large" />
    </KitSection>

    <KitSection label="States" layout="grid" :columns="2" :gap="18" note="hover lifts the track border and glows the on state; Tab rings the track">
      <CoreSwitch v-model="off" label-position="right" label="Off" />
      <CoreSwitch v-model="on" label-position="right" label="On" />
      <CoreSwitch :model-value="false" disabled label-position="right" label="Disabled, off" />
      <CoreSwitch :model-value="true" disabled label-position="right" label="Disabled, on" />
    </KitSection>

    <KitSection label="With a description" layout="column" :gap="16" note="label 15 px fg, description 13 px fg-dim — the same two lines as the checkbox">
      <CoreSwitch
        v-model="on"
        label="Streamer mode"
        description="Hides player names, licence plates and the phone number panel."
        style="width: 460px"
      />
      <CoreSwitch
        v-model="off"
        label="Let the faction track me"
        description="Officers see your blip while you are clocked in."
        style="width: 460px"
      />
    </KitSection>

    <KitSection label="Bare" :gap="20" note="no label at all — the switch is the whole control (a table cell, a row end)">
      <CoreSwitch v-model="on" />
      <CoreSwitch v-model="off" />
      <CoreSwitch v-model="on" size="lg" />
    </KitSection>
  </KitStage>
</template>
