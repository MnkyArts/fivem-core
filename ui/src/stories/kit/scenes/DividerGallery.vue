<script setup>
// DividerGallery — CoreDivider and CoreDash, the two hairline motifs of §37.1
// (DESIGN §37.5, Surfaces). They share a gallery because they are always used together: the
// divider parts a panel, the dash signs it.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const TONES = ['accent', 'neutral', 'success', 'warning', 'danger', 'info']
const WIDTHS = [18, 28, 44, 80]

const STATS = [
  ['Health restore', '+75'],
  ['Stamina', '+20'],
  ['Weight', '0.5 kg'],
]
</script>

<template>
  <KitStage
    title="CoreDivider &amp; CoreDash"
    :width="1080"
    description="A hairline and a short accent bar. The divider is 1 px of --color-border (or --color-border-strong
      with strong), horizontal or vertical, and parts around a label-voice caption when it has one. The dash is
      3 px high, takes any tone, and wears the brand gradient on accent."
  >
    <KitSection label="Divider" layout="column" :gap="22" note="Plain, strong, and with a label.">
      <div style="width: 100%">
        <p class="text-ui-sm text-fg-faint" style="margin-bottom: 10px">default</p>
        <CoreDivider />
      </div>
      <div style="width: 100%">
        <p class="text-ui-sm text-fg-faint" style="margin-bottom: 10px">strong</p>
        <CoreDivider strong />
      </div>
      <div style="width: 100%">
        <p class="text-ui-sm text-fg-faint" style="margin-bottom: 10px">label</p>
        <CoreDivider label="Consumables" />
      </div>
      <div style="width: 100%">
        <p class="text-ui-sm text-fg-faint" style="margin-bottom: 10px">strong + label</p>
        <CoreDivider strong label="Key items" />
      </div>
    </KitSection>

    <KitSection label="Vertical" layout="row" :gap="18"
      note="align-self: stretch, so it takes the height of the flex row it sits in. (.core-panel is a flex
        COLUMN, so a panel used as a row needs flex-row on the tag.)">
      <div class="core-panel flex flex-row items-center" style="padding: 14px 18px; gap: 18px">
        <span class="core-label" style="color: var(--color-fg)">Wayfinder</span>
        <CoreDivider vertical />
        <span class="text-ui-sm text-fg-faint">v1.0</span>
        <CoreDivider vertical />
        <span class="text-ui-sm text-fg-faint">eu-west-2</span>
      </div>
      <div class="core-panel flex flex-row items-stretch" style="padding: 14px 18px; gap: 18px; height: 92px">
        <div style="align-self: center">
          <p class="core-label">Cash</p>
          <p class="core-num" style="font-size: 20px; color: var(--color-fg)">$4,180</p>
        </div>
        <CoreDivider vertical />
        <div style="align-self: center">
          <p class="core-label">Bank</p>
          <p class="core-num" style="font-size: 20px; color: var(--color-fg)">$182,400</p>
        </div>
        <CoreDivider vertical label="or" />
        <div style="align-self: center">
          <p class="core-label">Debt</p>
          <p class="core-num" style="font-size: 20px; color: var(--color-error)">-$900</p>
        </div>
      </div>
    </KitSection>

    <KitSection label="In a panel — the stat rows of mockup 3" layout="column" :gap="0">
      <CorePanel title="Med Kit" subtitle="Common &middot; Consumable" padding="lg" style="width: 420px">
        <CoreDivider style="margin-bottom: 14px" />
        <div v-for="[label, value] in STATS" :key="label" class="flex items-center" style="gap: 12px; padding: 7px 0">
          <CoreIcon name="heart" size="sm" />
          <span class="core-label">{{ label }}</span>
          <span class="core-num" style="margin-left: auto; color: var(--color-fg)">{{ value }}</span>
        </div>
        <CoreDivider style="margin-top: 14px" />
        <p class="core-flavor" style="margin-top: 14px">A small kit. A second chance.</p>
      </CorePanel>
    </KitSection>

    <KitSection label="Dash — width" layout="row" :gap="30" note="width is px (a string passes through, so 100% works).">
      <div v-for="w in WIDTHS" :key="w" style="text-align: center">
        <CoreDash :width="w" style="margin: 0 auto 10px" />
        <span class="text-ui-xs text-fg-faint">:width="{{ w }}"</span>
      </div>
    </KitSection>

    <KitSection label="Dash — tones" layout="row" :gap="30" note="accent is the brand gradient; every other tone is flat.">
      <div v-for="tone in TONES" :key="tone" style="text-align: center">
        <CoreDash :tone="tone" :width="44" style="margin: 0 auto 10px" />
        <span class="text-ui-xs text-fg-faint">{{ tone }}</span>
      </div>
    </KitSection>

    <KitSection label="Dash in place" layout="column" :gap="18"
      note="Under a heading, and as the signature at the end of a footer line (mockup 1).">
      <div>
        <CoreHeading size="lg" title="Inventory" />
        <CoreDash style="margin-top: 14px" />
      </div>
      <div class="flex items-center" style="gap: 16px">
        <CoreDash :width="50" />
        <span class="core-label">Worlds are better with stories.</span>
      </div>
    </KitSection>
  </KitStage>
</template>
