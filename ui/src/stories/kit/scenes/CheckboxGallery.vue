<script setup>
// CheckboxGallery — CoreCheckbox (DESIGN §37.5, Forms — choice).
// The first section rebuilds the MAP FILTERS block of the map mockup one to one (coral box, bold
// white tick, glyph between box and label), because that is the picture this component is judged
// against. The rest proves the array model, the sizes, every state and the legacy markup.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

// `accent` is the map's own marker colour, not a component state: the icon slot paints it.
const FILTERS = [
  { value: 'quests', label: 'Quests', icon: 'quest', accent: true },
  { value: 'locations', label: 'Locations', icon: 'home' },
  { value: 'travel', label: 'Fast Travel', icon: 'camp' },
  { value: 'shops', label: 'Shops', icon: 'cart' },
  { value: 'activities', label: 'Activities', icon: 'help' },
  { value: 'collectibles', label: 'Collectibles', icon: 'leaf' },
]

const filters = ref(['quests', 'locations', 'travel'])
const loot = ref(['ammo'])

const one = ref(true)
const off = ref(false)
const withDesc = ref(true)
const sizes = ref(true)

const panel = {
  padding: '20px 22px 22px',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  background: 'var(--color-panel)',
  boxShadow: 'var(--shadow-ui)',
  width: '320px',
}
const slash = { width: '7px', height: '21px', background: 'var(--color-accent)' }
</script>

<template>
  <KitStage
    title="Checkbox"
    description="A real <input type=&quot;checkbox&quot;> restyled with appearance:none — the box IS the input, so
      the label click target, the keyboard and :indeterminate come from the browser. The model is a boolean, or
      an array that the box adds its `value` to."
  >
    <KitSection label="Map filters — the mockup" note="coral box, bold round-joined tick, a glyph between box and label — the coral carries the state, not the glyph">
      <div :style="panel">
        <div class="flex items-center" style="gap: 14px; margin-bottom: 20px">
          <span class="flex" style="gap: 5px; transform: skewX(-18deg)">
            <span :style="slash"></span>
            <span :style="slash"></span>
          </span>
          <span class="core-display core-display--sm" style="font-style: italic">Map filters</span>
        </div>
        <div class="flex flex-col" style="gap: 13px">
          <CoreCheckbox
            v-for="f in FILTERS"
            :key="f.value"
            v-model="filters"
            :value="f.value"
            :label="f.label"
            :icon="f.icon"
          >
            <template v-if="f.accent" #icon>
              <CoreIcon class="core-check__icon" :name="f.icon" size="md" style="color: var(--color-accent)" />
            </template>
          </CoreCheckbox>
        </div>
      </div>
      <p class="core-text" style="align-self: flex-start; margin-top: 4px">
        <span class="core-label">model</span>
        <span class="core-num text-fg">[ {{ filters.join(', ') || '—' }} ]</span>
      </p>
    </KitSection>

    <KitSection label="Array model" layout="column" :gap="12" note="one v-model array, one checkbox per item — like Vue's native multi-checkbox binding">
      <CoreCheckbox v-model="loot" value="ammo" label="Ammo" icon="ammo" />
      <CoreCheckbox v-model="loot" value="medkit" label="Med kits" icon="medkit" />
      <CoreCheckbox v-model="loot" value="fuel" label="Jerry cans" icon="fuel" />
      <CoreCheckbox v-model="loot" value="tools" label="Repair tools" icon="wrench" disabled />
      <p class="core-num text-fg-dim text-ui-sm">picked: [ {{ loot.join(', ') || '—' }} ]</p>
    </KitSection>

    <KitSection label="Sizes" :gap="28" note="box 18 / 22 / 26 px — --radius-ui-xs, 1.5 px hairline">
      <CoreCheckbox v-model="sizes" size="sm" label="Small" />
      <CoreCheckbox v-model="sizes" size="md" label="Medium" />
      <CoreCheckbox v-model="sizes" size="lg" label="Large" />
    </KitSection>

    <KitSection label="States" layout="grid" :columns="3" :gap="18" note="hover brightens the hairline to white 70 %; focus is the 2 px accent-hi ring (Tab into the row)">
      <CoreCheckbox v-model="off" label="Unchecked" />
      <CoreCheckbox v-model="one" label="Checked" />
      <CoreCheckbox v-model="off" indeterminate label="Indeterminate" />
      <CoreCheckbox :model-value="false" disabled label="Disabled" />
      <CoreCheckbox :model-value="true" disabled label="Disabled, checked" />
      <CoreCheckbox :model-value="false" indeterminate disabled label="Disabled, partial" />
    </KitSection>

    <KitSection label="With a description" layout="column" :gap="16" note="label Barlow 15 px fg, description 13 px fg-dim">
      <CoreCheckbox v-model="withDesc" label="Keep my licence plate" description="Costs $250 at the next registration." icon="car" />
      <CoreCheckbox v-model="off" label="Share my location with the faction" description="Every member sees your blip while you are on duty." icon="users" />
      <CoreCheckbox :model-value="true" disabled label="Insured" description="Set by the dealership — you cannot change it here." icon="shield" />
    </KitSection>

    <KitSection label="Legacy markup" layout="column" :gap="12" note="<label class='core-check'><input type='checkbox'><span>…</span></label> — no component, same look">
      <label class="core-check">
        <input type="checkbox" checked>
        <span>Remember this character</span>
      </label>
      <label class="core-check core-check--sm">
        <input type="checkbox">
        <span>Skip the intro next time</span>
      </label>
    </KitSection>
  </KitStage>
</template>
