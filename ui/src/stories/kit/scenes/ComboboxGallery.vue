<script setup>
// ComboboxGallery — CoreCombobox (DESIGN §53, §37.5 Forms — text): local filtering, multiple with
// tags, creatable, an async search with a fake latency (the player picker), 5 000 options through
// the virtual list, and the invalid / disabled states.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const WEATHER = [
  { value: 'CLEAR', label: 'Clear', icon: 'sun' }, { value: 'EXTRASUNNY', label: 'Extra sunny', icon: 'sun' },
  { value: 'CLOUDS', label: 'Clouds', icon: 'cloud' }, { value: 'OVERCAST', label: 'Overcast', icon: 'cloud' },
  { value: 'RAIN', label: 'Rain', icon: 'rain' }, { value: 'THUNDER', label: 'Thunder', icon: 'bolt' },
  { value: 'FOGGY', label: 'Foggy', icon: 'cloud' }, { value: 'SNOW', label: 'Snow', icon: 'snow' },
  { value: 'XMAS', label: 'Christmas', icon: 'snow', description: 'Snow on the ground' },
  { value: 'HALLOWEEN', label: 'Halloween', icon: 'moon', description: 'Event only', disabled: true },
]
const TAGS = ['race', 'drift', 'offroad', 'derby', 'heist', 'roleplay', 'event', 'training']

const PLAYERS = ['Ada Byron', 'Travis Kane', 'Mila Ortega', 'Dez', 'Ana Reyes', 'Lamar Davis', 'Franklin Clinton',
  'Trevor Philips', 'Michael De Santa', 'Lester Crest'].map((name, i) => ({ value: 11 + i * 7, label: name, description: 'ID ' + (11 + i * 7) }))
const searchPlayers = (q) => new Promise((resolve) => {
  const n = String(q || '').toLowerCase()
  setTimeout(() => resolve(PLAYERS.filter((p) => !n || p.label.toLowerCase().includes(n) || String(p.value).startsWith(n))), 350)
})

const MODELS = Array.from({ length: 5000 }, (_, i) => 'prop_' + ['barrier', 'crate', 'cone', 'bench', 'lamp'][i % 5] + '_' + String(i).padStart(4, '0'))

const weather = ref('RAIN')
const tags = ref(['race', 'event'])
const created = ref(['vip'])
const player = ref(null)
const model = ref('prop_cone_0002')
const bad = ref(null)
</script>

<template>
  <KitStage
    title="CoreCombobox"
    description="The filterable select. Focus stays in the field and the list is driven by aria-activedescendant; the
      popup shares every rule with CoreSelect's. Local `options` are filtered here, `search(query)` replaces them
      (debounced, stale answers dropped), and past `virtualThreshold` rows the list is virtualised."
    :width="1000"
  >
    <KitSection label="Single — local filter" layout="grid" :columns="2" :gap="24"
                note="Type to filter label, value and description; ↑/↓ + Enter pick, Escape closes the list first.">
      <CoreField label="Weather"><CoreCombobox v-model="weather" :options="WEATHER" clearable /></CoreField>
      <CoreField label="Invalid" error="Pick a weather type."><CoreCombobox v-model="bad" :options="WEATHER" invalid placeholder="Choose…" /></CoreField>
    </KitSection>

    <KitSection label="Multiple + creatable" layout="grid" :columns="2" :gap="24"
                note="Picks are removable tags; Backspace in an empty field drops the last. `creatable` offers the typed text first.">
      <CoreField label="Map tags"><CoreCombobox v-model="tags" :options="TAGS" multiple /></CoreField>
      <CoreField label="Custom groups" hint="Type a new group name and press Enter.">
        <CoreCombobox v-model="created" :options="['admin', 'mod', 'vip']" multiple creatable />
      </CoreField>
    </KitSection>

    <KitSection label="Async search — the player picker" layout="grid" :columns="2" :gap="24"
                note="search(query) resolves after 350 ms; a spinner sits in the well meanwhile. The picked label is remembered.">
      <CoreField label="Target player"><CoreCombobox v-model="player" :search="searchPlayers" placeholder="Name or server id…" clearable /></CoreField>
      <p class="text-ui-sm text-fg-faint" style="margin: 28px 0 0">value: <b class="text-fg">{{ player === null ? '—' : player }}</b></p>
    </KitSection>

    <KitSection label="5 000 options — virtualised" layout="grid" :columns="2" :gap="24"
                note="Past 100 rows the list renders through CoreVirtualList; the keyboard cursor scrolls it with scrollToIndex.">
      <CoreField label="Model"><CoreCombobox v-model="model" :options="MODELS" creatable /></CoreField>
      <CoreField label="Disabled"><CoreCombobox :model-value="'CLEAR'" :options="WEATHER" disabled /></CoreField>
    </KitSection>
  </KitStage>
</template>
