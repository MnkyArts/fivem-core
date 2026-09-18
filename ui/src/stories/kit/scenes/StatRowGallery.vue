<script setup>
// StatRowGallery — the hairline-framed detail stat of mockup 3, the block it lives in, and what a
// stack of them looks like when the rows share their hairlines.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const CARD = {
  width: '520px',
  padding: '22px 26px 24px',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  background: 'var(--color-panel-solid)',
}

const WEAPON = [
  ['target', 'Damage', '34'],
  ['bolt', 'Fire rate', '62'],
  ['crosshair', 'Accuracy', '48'],
  ['speed', 'Range', '27'],
]

const TONES = [
  ['heart', 'Health restore', '+75', 'health'],
  ['shield', 'Armour', '+50', 'armour'],
  ['fuel', 'Fuel burn', '-12%', 'warning'],
  ['skull', 'Overdose risk', 'HIGH', 'danger'],
  ['leaf', 'Purity', '96%', 'success'],
  ['weight', 'Weight', '0.5', ''],
]

const HAIRLINES = ['both', 'top', 'bottom', 'none']
</script>

<template>
  <KitStage
    title="CoreStatRow"
    description="The detail stat of the inventory: a glyph, what the stat is in the display voice, and the
      number hard against the right edge — between two hairlines. Stacked rows share one line, so a list of
      effects reads as a single block instead of a ladder of borders."
  >
    <KitSection label="The item detail of mockup 3" :gap="40" note="One row, the flavour line under it, the actions after that.">
      <div :style="CARD">
        <CoreStatRow icon="heart" label="Health restore" value="+75" />
        <p class="core-flavor" style="margin-top: 20px">A small kit. A second chance.</p>
      </div>
      <p class="text-ui-xs text-fg-faint" style="max-width: 230px">
        The value stays white without a tone — the mockup's <code>+75</code> is not coral, and a row that
        shouts every time would stop meaning anything.
      </p>
    </KitSection>

    <KitSection label="Stacked" :gap="40" note=".core-statrow + .core-statrow drops the neighbour's top line — 56 px rhythm, one hairline between rows.">
      <div :style="CARD">
        <p class="core-label" style="margin-bottom: 14px">Heavy Revolver</p>
        <CoreStatRow v-for="[icon, label, value] in WEAPON" :key="label" :icon="icon" :label="label" :value="value" />
      </div>
      <div :style="CARD">
        <p class="core-label" style="margin-bottom: 14px">Med Kit · effects</p>
        <CoreStatRow icon="heart" label="Health restore" value="+75" tone="health" />
        <CoreStatRow icon="bolt" label="Stamina" value="+20" tone="stamina" />
        <CoreStatRow icon="brain" label="Stress" value="-15" tone="stress" />
      </div>
    </KitSection>

    <KitSection label="Tones" layout="column" :gap="0" note="`tone` colours the VALUE only; the glyph and the label stay in the text colours.">
      <div :style="CARD">
        <CoreStatRow
          v-for="[icon, label, value, tone] in TONES"
          :key="label"
          :icon="icon"
          :label="label"
          :value="value"
          :tone="tone"
        />
      </div>
    </KitSection>

    <KitSection label="Hairlines" layout="grid" :columns="4" :gap="18" note="both (default) · top · bottom · none — for a row that already sits inside a framed block.">
      <div v-for="mode in HAIRLINES" :key="mode">
        <CoreStatRow icon="cash" label="Sell price" :value="'$' + (mode.length * 120)" :hairlines="mode" />
        <p class="text-ui-xs text-fg-faint" style="margin-top: 10px">hairlines="{{ mode }}"</p>
      </div>
    </KitSection>

    <KitSection label="Value slot" :gap="40" note="The `value` slot takes anything — a unit, a glyph, a second number.">
      <div :style="CARD">
        <CoreStatRow icon="weight" label="Weight">
          <template #value>0.5 <span class="text-fg-dim text-ui-sm">KG</span></template>
        </CoreStatRow>
        <CoreStatRow icon="clock" label="Duration">
          <template #value>30 <span class="text-fg-dim text-ui-sm">SEC</span></template>
        </CoreStatRow>
        <CoreStatRow icon="star" label="Condition" tone="warning">
          <template #value>
            <CoreIcon name="star" size="lg" />
            <CoreIcon name="star" size="lg" />
            <CoreIcon name="star-outline" size="lg" />
          </template>
        </CoreStatRow>
      </div>
      <p class="text-ui-xs text-fg-faint" style="max-width: 230px">
        Anything in the slot inherits the value's colour, so a tone still reaches a glyph that was put
        there by hand.
      </p>
    </KitSection>
  </KitStage>
</template>
