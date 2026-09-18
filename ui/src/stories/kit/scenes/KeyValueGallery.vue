<script setup>
// KeyValueGallery — CoreKeyValue (DESIGN §37.5, Data — display): the ruled label/value list that
// carries mockup 3's read-out voice (label voice left, display voice right).
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const ITEM = [
  { label: 'Rarity', value: 'Common', icon: 'diamond-outline' },
  { label: 'Type', value: 'Consumable', icon: 'medkit' },
  { label: 'In inventory', value: '3 / 10' },
  { label: 'Weight', value: '0.8 kg', icon: 'weight' },
  { label: 'Sell value', value: '$ 240', icon: 'cash', tone: 'success' },
]

const VEHICLE = [
  { label: 'Plate', value: 'AB 41 XKZ' },
  { label: 'Model', value: 'Bravado Gauntlet' },
  { label: 'Top speed', value: '206 km/h', icon: 'speed' },
  { label: 'Fuel', value: '72 %', icon: 'fuel', tone: 'warning' },
  { label: 'Engine', value: '98 %', icon: 'engine', tone: 'success' },
  { label: 'Insurance', value: 'Lapsed', icon: 'shield', tone: 'danger' },
]

const CHARACTER = [
  { label: 'Name', value: 'Travis Kane' },
  { label: 'Citizen ID', value: 'LS-4471-A' },
  { label: 'Faction', value: 'Grove Mechanics', icon: 'users' },
  { label: 'Phone', value: '555-0182', icon: 'phone' },
  { label: 'Bank', value: '$ 148,320', icon: 'bank' },
  { label: 'Cash', value: '$ 2,410', icon: 'cash' },
  { label: 'Wanted', value: '3 stars', icon: 'police', tone: 'danger' },
  { label: 'Licences', value: 'Car · Weapon', icon: 'id-card' },
]

const PAYOUT = [
  { label: 'Base pay', value: '$ 1,200' },
  { label: 'Distance bonus', value: '$ 340' },
  { label: 'Damage', value: '− $ 180', tone: 'danger' },
  { label: 'Total', value: '$ 1,360', tone: 'success' },
]
</script>

<template>
  <KitStage
    title="CoreKeyValue"
    description="Facts, ruled. The label wears the label voice, the value the display voice — the same
      pairing mockup 3 uses for &quot;3 / 10 · IN INVENTORY&quot;. `columns` only reflows the SAME rows,
      so a detail panel and a wide profile share one items array."
  >
    <KitSection label="One column" layout="column" :gap="0" note="The default. A tone paints the value and its glyph.">
      <div style="width: 380px">
        <CoreKeyValue :items="ITEM" />
      </div>
    </KitSection>

    <KitSection label="Two columns" layout="column" :gap="0" note=":columns=&quot;2&quot; — the items flow left to right, so every hairline lines up across the grid.">
      <div style="width: 760px">
        <CoreKeyValue :items="VEHICLE" :columns="2" />
      </div>
    </KitSection>

    <KitSection label="Four columns" layout="column" :gap="0" note="A profile header: eight facts in one band.">
      <CoreKeyValue :items="CHARACTER" :columns="4" />
    </KitSection>

    <KitSection label="Tones and a slot" layout="column" :gap="0" note="`value-<i>` takes over one value by index — here the total gets a tag in front of it.">
      <div style="width: 420px">
        <CoreKeyValue :items="PAYOUT">
          <template #value-3="{ value }">
            <span style="display: inline-flex; align-items: center; gap: 10px">
              <CoreTag size="sm" variant="soft" tone="success" label="Clean run" />
              <span>{{ value }}</span>
            </span>
          </template>
        </CoreKeyValue>
      </div>
    </KitSection>

    <KitSection label="Inside a panel" layout="column" :gap="0" note="What it looks like where it actually lives: over a translucent surface, under a heading.">
      <div
        style="width: 420px; padding: 20px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel); box-shadow: var(--shadow-ui)"
      >
        <p class="core-eyebrow" style="margin: 0 0 4px">Common · Consumable</p>
        <h3 class="core-title" style="margin: 0 0 18px">Med Kit</h3>
        <CoreKeyValue :items="ITEM" />
      </div>
    </KitSection>
  </KitStage>
</template>
