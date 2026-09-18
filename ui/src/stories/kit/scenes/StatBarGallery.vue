<script setup>
// StatBarGallery — the HUD vitals of mockup 2. Open it with `?bg=keyart`: the plate is translucent
// ink, so the only honest way to judge it is over the game.
// The plate is plain markup on purpose — CoreStatBar is one row, the page owns the box around it.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const PLATE = {
  display: 'flex',
  flexDirection: 'column',
  gap: '9px',
  width: 'max-content',
  padding: '12px 16px',
  borderRadius: 'var(--radius-ui-sm)',
  background: 'rgba(6, 11, 15, 0.55)',
}

const VITALS = [
  ['health', 'heart', 100],
  ['armour', 'shield', 75],
  ['stamina', 'bolt', 80],
  ['hunger', 'food', 62],
  ['thirst', 'water', 44],
  ['oxygen', 'lungs', 91],
  ['stress', 'brain', 18],
]

const WIDTHS = [
  [160, 'a compact corner HUD'],
  [220, 'the default — mockup 2'],
  [300, 'a wide vehicle HUD'],
]
</script>

<template>
  <KitStage
    title="CoreStatBar"
    description="The HUD vital: a glyph in the vital's colour, a chunky flat bar in a dark well, a big
      condensed number. The row is click-through, so it can sit anywhere over the game, and the number keeps
      a floor width — 100 dropping to 75 must not make the plate around it twitch."
  >
    <KitSection label="The plate of mockup 2" :gap="40" note="ink 55 % · radius 4 · padding 12 16 — the box belongs to the page, the rows to the kit.">
      <div :style="PLATE">
        <CoreStatBar icon="heart" tone="health" :value="100" />
        <CoreStatBar icon="shield" tone="armour" :value="75" />
        <CoreStatBar icon="bolt" tone="stamina" :value="80" />
      </div>
      <div :style="PLATE">
        <CoreStatBar icon="heart" tone="health" :value="18" />
        <CoreStatBar icon="shield" tone="armour" :value="0" />
        <CoreStatBar icon="bolt" tone="stamina" :value="34" />
        <CoreStatBar icon="food" tone="hunger" :value="21" />
        <CoreStatBar icon="water" tone="thirst" :value="9" />
      </div>
    </KitSection>

    <KitSection label="Vitals" :gap="40" note="The seven meter tones of §37.2 — icon and fill share one colour.">
      <div :style="PLATE">
        <CoreStatBar v-for="[tone, icon, value] in VITALS" :key="tone" :icon="icon" :tone="tone" :value="value" />
      </div>
      <p class="text-ui-xs text-fg-faint" style="max-width: 260px">
        health · armour · stamina · hunger · thirst · oxygen · stress. A plugin picks the ones its HUD
        actually tracks; nothing here assumes all seven.
      </p>
    </KitSection>

    <KitSection label="Low" :gap="44" note="Under `lowBelow` (25 by default) the GLYPH pulses — the bar never moves.">
      <div :style="PLATE">
        <CoreStatBar icon="heart" tone="health" :value="12" />
        <CoreStatBar icon="lungs" tone="oxygen" :value="7" />
      </div>
      <div :style="PLATE">
        <CoreStatBar icon="heart" tone="health" :value="12" :low-below="0" />
        <CoreStatBar icon="lungs" tone="oxygen" :value="7" :low-below="0" />
      </div>
      <p class="text-ui-xs text-fg-faint" style="max-width: 200px">
        Right: the same two rows with <code>lowBelow: 0</code> — no warning at all.
      </p>
    </KitSection>

    <KitSection label="Width, value, max" layout="column" :gap="12" note="`width` is the bar only; the glyph and the number keep their own space.">
      <div v-for="[width, use] in WIDTHS" :key="width" style="display: flex; align-items: center; gap: 22px">
        <div :style="PLATE"><CoreStatBar icon="heart" tone="health" :value="68" :width="width" /></div>
        <span class="text-ui-xs text-fg-faint">:width="{{ width }}" — {{ use }}</span>
      </div>
      <div style="display: flex; align-items: center; gap: 22px">
        <div :style="PLATE"><CoreStatBar icon="ammo" tone="neutral" :value="17" :max="30" :low-below="20" /></div>
        <span class="text-ui-xs text-fg-faint">:max="30" — 17 rounds of a 30 round magazine</span>
      </div>
      <div style="display: flex; align-items: center; gap: 22px">
        <div :style="PLATE"><CoreStatBar icon="shield" tone="armour" :value="55" :show-value="false" /></div>
        <span class="text-ui-xs text-fg-faint">:show-value="false" — bar only</span>
      </div>
      <div style="display: flex; align-items: center; gap: 22px">
        <div :style="PLATE"><CoreStatBar tone="stamina" :value="80" /></div>
        <span class="text-ui-xs text-fg-faint">no icon — the row starts at the bar</span>
      </div>
      <div style="display: flex; align-items: center; gap: 22px">
        <div :style="PLATE"><CoreStatBar icon="shield" tone="armour" :value="75" icon-tone="fg" /></div>
        <span class="text-ui-xs text-fg-faint">icon-tone="fg" — the white shield of mockup 2, colour in the bar only</span>
      </div>
    </KitSection>
  </KitStage>
</template>
