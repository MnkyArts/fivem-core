<script setup>
// ProgressGallery — every shape of CoreProgress: the four sizes, the thirteen tones, the mockup's
// inline capacity row, segmented magazines and armour plates, the threshold tones, indeterminate
// and a custom faction colour.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const SIZES = [
  ['xs', 2, 'a hairline under a card — the XP line of a list row'],
  ['sm', 4, 'the player chip XP bar'],
  ['md', 8, 'the default: capacity, fuel, upload'],
  ['lg', 12, 'a headline meter — heist prep, faction control'],
]

const TONES = [
  ['accent', 'Contract progress', 64],
  ['neutral', 'Inventory capacity', 62],
  ['success', 'Repair quality', 91],
  ['warning', 'Engine wear', 47],
  ['danger', 'Wanted heat', 78],
  ['info', 'Upload to dispatch', 35],
]

const VITALS = [
  ['health', 'Health', 82, 'heart'],
  ['armour', 'Armour', 40, 'shield'],
  ['stamina', 'Stamina', 66, 'bolt'],
  ['hunger', 'Hunger', 54, 'food'],
  ['thirst', 'Thirst', 31, 'water'],
  ['oxygen', 'Oxygen', 88, 'lungs'],
  ['stress', 'Stress', 22, 'brain'],
]

const THRESHOLDS = [
  ['Fuel — Sandking XL', 80],
  ['Fuel — Bravado Buffalo', 20],
  ['Fuel — Dinka Blista', 6],
]

const money = (value, max) => '$' + value.toLocaleString('en-US') + ' / $' + max.toLocaleString('en-US')

// The mockup's capacity plate: the inventory footer, 820 px wide, so the bar keeps the proportions
// of mockup 3 instead of stretching across the whole stage.
const PLATE = {
  width: '740px',
  padding: '16px 30px',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  background: 'var(--color-panel-solid)',
}
</script>

<template>
  <KitStage
    title="CoreProgress"
    description="The linear meter. One component covers the capacity row of the inventory, a magazine,
      a vital, an upload and the XP line — the track is always white 12 %, and only the fill changes:
      the brand gradient on accent, the near-white ramp on neutral, the flat vital colour otherwise."
  >
    <KitSection label="Sizes" layout="column" :gap="20" note="xs 2 · sm 4 · md 8 · lg 12 px. The track radius stays 2 px at every height.">
      <div v-for="[size, px, use] in SIZES" :key="size" style="width: 100%">
        <CoreProgress :size="size" :value="62" :label="size + ' · ' + px + ' px'" show-value />
        <p class="text-ui-xs text-fg-faint" style="margin: 8px 0 0">{{ use }}</p>
      </div>
    </KitSection>

    <KitSection label="Tones" layout="grid" :columns="2" :gap="26" note="core-tone-* on the root; the partial only ever writes var(--tone).">
      <CoreProgress
        v-for="[tone, label, value] in TONES"
        :key="tone"
        :tone="tone"
        :label="label"
        :value="value"
        show-value
      />
    </KitSection>

    <KitSection label="Vitals" layout="grid" :columns="2" :gap="26" note="The seven meter tones of §37.2 — the same colours the HUD stat bars wear.">
      <CoreProgress
        v-for="[tone, label, value, icon] in VITALS"
        :key="tone"
        :tone="tone"
        :label="label"
        :value="value"
        :icon="icon"
        show-value
      />
    </KitSection>

    <KitSection
      label="Inline — the capacity row"
      layout="column"
      :gap="18"
      note="`inline` + `tone=&quot;neutral&quot;`: glyph · caption · bar · value. A max that was really passed prints the fraction, with the / max half dimmed."
    >
      <div :style="PLATE">
        <CoreProgress inline tone="neutral" icon="backpack" label="Inventory capacity" :value="18.5" :max="30" show-value />
      </div>
      <div :style="PLATE">
        <CoreProgress inline tone="warning" icon="fuel" label="Fuel" :value="41" size="sm" show-value value-text="41 %" />
      </div>
      <div :style="PLATE">
        <CoreProgress inline icon="cash" label="Weekly payout" :value="8400" :max="12000" size="sm" show-value :format="money" />
      </div>
    </KitSection>

    <KitSection label="Segments" layout="column" :gap="22" note="One mask on the track carves the well AND the fill into n cells with a 2 px gap.">
      <div style="width: 420px">
        <CoreProgress label="Combat Pistol — magazine" :value="17" :max="30" :segments="15" show-value tone="neutral" />
      </div>
      <div style="width: 420px">
        <CoreProgress label="Armour plates" :value="3" :max="5" :segments="5" size="lg" tone="armour" show-value />
      </div>
      <div style="width: 420px">
        <CoreProgress label="Heist prep" :value="2" :max="4" :segments="4" size="lg" show-value />
      </div>
    </KitSection>

    <KitSection
      label="Thresholds"
      layout="column"
      :gap="22"
      note="warnBelow 25 / dangerBelow 10 — the bar swaps its TONE CLASS, so a re-themed server keeps owning the palette."
    >
      <CoreProgress
        v-for="[label, value] in THRESHOLDS"
        :key="label"
        :label="label"
        :value="value"
        :warn-below="25"
        :danger-below="10"
        tone="info"
        icon="fuel"
        show-value
      />
    </KitSection>

    <KitSection label="Indeterminate &amp; custom colour" layout="column" :gap="22" note="A 35 % fill sweeping the track; `color` overrides the tone for one bar.">
      <CoreProgress label="Syncing your garage with the server" indeterminate />
      <CoreProgress label="Los Santos Customs — reputation" :value="72" color="#9d7bff" show-value />
      <CoreProgress label="Vagos territory" :value="58" color="#ffd166" size="lg" show-value />
    </KitSection>

    <KitSection label="Slots" layout="column" :gap="22" note="`label` and `value` take markup when a string is not enough.">
      <CoreProgress :value="340" :max="500" show-value tone="info">
        <template #label>
          <CoreIcon name="xp" size="sm" style="vertical-align: -3px" /> Level 32 · next rank
        </template>
        <template #value>340 <span class="text-fg-dim">/ 500 XP</span></template>
      </CoreProgress>
      <CoreProgress :value="6" :max="8" show-value tone="success" size="lg">
        <template #label>Delivery route · Sandy Shores</template>
        <template #value><span class="text-fg-dim">stop</span> 6 / 8</template>
      </CoreProgress>
    </KitSection>
  </KitStage>
</template>
