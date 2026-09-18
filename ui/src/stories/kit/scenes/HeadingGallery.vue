<script setup>
// HeadingGallery — CoreHeading: sizes, the // slash marker, eyebrow, subtitle, actions, align
// (DESIGN §37.5, Surfaces). The first section is the INVENTORY block of mockup 3 at its real size.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const SIZES = [
  ['sm', '18 px — a panel inside a panel, a HUD card'],
  ['md', '24 px — the default, a panel title'],
  ['lg', '34 px — a page heading (mockup 3)'],
  ['xl', '48 px — a splash, a shard, a scoreboard'],
]
</script>

<template>
  <KitStage
    title="CoreHeading"
    :width="1180"
    description="The title block: a label-voice eyebrow above, the display title, an eyebrow-voice subtitle under
      it and actions on the right. slash puts the mockups' // marker before an italic title; the two large sizes
      run the title from white at the cap line into the dimmed foreground at the baseline."
  >
    <KitSection label="Mockup 3 — the inventory heading" layout="column" :gap="0">
      <CoreHeading size="lg" title="Inventory" subtitle="Gear up for what's next." tag="h1" />
    </KitSection>

    <KitSection label="Sizes" layout="column" :gap="28"
      note="Title 18 / 24 / 34 / 48 px (the --text-display-* scale); the eyebrow-voice subtitle follows at
        12 / 13 / 14 / 16 px, and its 0.32 em track never changes.">
      <div v-for="[size, note] in SIZES" :key="size" style="width: 100%">
        <CoreHeading :size="size" :title="'Los Santos Customs'" :subtitle="note" />
      </div>
    </KitSection>

    <KitSection label="Slash" layout="column" :gap="26"
      note="Two accent bars, 0.34 em x 0.9 em, skewed -20 degrees, 0.2 em apart — and the title turns italic.">
      <CoreHeading slash size="sm" title="Map filters" />
      <CoreHeading slash size="md" title="Quests" />
      <CoreHeading slash size="lg" title="Contracts" subtitle="Three open, one on a timer." />
    </KitSection>

    <KitSection label="Eyebrow, subtitle, actions" layout="column" :gap="30"
      note="The heading is a flex row, so the actions group needs a full-width parent to sit against the edge.">
      <div style="width: 100%">
        <CoreHeading eyebrow="Chapter two" title="A Brighter Tomorrow" size="lg" />
      </div>
      <div style="width: 100%">
        <CoreHeading title="Med Kit" subtitle="Common &middot; Consumable">
          <template #actions>
            <div style="text-align: right">
              <p class="core-num" style="font-size: 22px; color: var(--color-fg)">3 / 10</p>
              <p class="core-label" style="margin-top: 4px">In inventory</p>
            </div>
          </template>
        </CoreHeading>
      </div>
      <div style="width: 100%">
        <CoreHeading eyebrow="Faction" title="Northside MC" subtitle="Members &middot; Vehicles &middot; Treasury">
          <template #actions>
            <span class="core-label" style="color: var(--color-accent)">14 online</span>
          </template>
        </CoreHeading>
      </div>
    </KitSection>

    <KitSection label="Align" layout="column" :gap="26" note="left (default) / center / right.">
      <div style="width: 100%">
        <CoreHeading align="left" title="Left" subtitle="The default." />
      </div>
      <div style="width: 100%">
        <CoreHeading align="center" slash title="Center" subtitle="A splash, an empty state." />
      </div>
      <div style="width: 100%">
        <CoreHeading align="right" title="Right" subtitle="A sidebar against the screen edge." />
      </div>
    </KitSection>

    <KitSection label="Slot title" layout="column" :gap="20"
      note="The default slot replaces the title text — a count, a colour, an icon.">
      <CoreHeading size="lg" subtitle="Weekly payout">
        Treasury <span style="color: var(--color-accent)">$182,400</span>
      </CoreHeading>
    </KitSection>
  </KitStage>
</template>
