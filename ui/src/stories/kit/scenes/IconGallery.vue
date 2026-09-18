<script setup>
// IconGallery — the CoreIcon contract: sizes, colour by inheritance, spin, raw path data.
// (The full registry lives in FoundationsIcons.)
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const SIZES = [
  ['xs', 14, 'inline with 11–13 px text'],
  ['sm', 16, 'inside a small button'],
  ['md', 20, 'the default'],
  ['lg', 24, 'menu rows, list items'],
  ['xl', 32, 'empty states, dialog tiles'],
]

const TONES = [
  ['text-fg', 'heart'],
  ['text-fg-dim', 'backpack'],
  ['text-accent', 'star'],
  ['text-success', 'check-circle'],
  ['text-warning', 'warning'],
  ['text-error', 'close-circle'],
  ['text-info', 'info'],
]

const VITALS = [
  ['text-health', 'heart'],
  ['text-armour', 'shield'],
  ['text-stamina', 'bolt'],
  ['text-hunger', 'food'],
  ['text-thirst', 'water'],
  ['text-oxygen', 'lungs'],
  ['text-stress', 'brain'],
]

// Raw 24 x 24 path data is accepted anywhere a registry name is — this is the mockups' mark.
const MARK = 'M12 3L21.5 20.5H2.5L12 3Z M12 9.5L7.5 17.5H16.5L12 9.5Z'

// Tiles hang from the top of the row so captions of different lengths cannot stagger them, and
// every glyph sits in the same 44 px box so the labels under them line up.
const tile = (width) => ({
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  alignSelf: 'flex-start',
  gap: '8px',
  width: width + 'px',
})
const GLYPH = { display: 'flex', alignItems: 'center', justifyContent: 'center', height: '44px' }
</script>

<template>
  <KitStage
    title="CoreIcon"
    description="One inline &lt;svg viewBox=&quot;0 0 24 24&quot; fill=&quot;currentColor&quot;&gt;. It takes its colour
      from the text around it, so an icon is never coloured by a prop — colour the parent (or let the owning
      component's tone do it) and the glyph follows."
  >
    <KitSection label="Sizes" :gap="26" note="xs 14 · sm 16 · md 20 · lg 24 · xl 32, or any number of px.">
      <div v-for="[size, px, use] in SIZES" :key="size" :style="tile(132)">
        <div :style="GLYPH"><CoreIcon name="medkit" :size="size" /></div>
        <span class="text-ui-sm">{{ size }} · {{ px }}</span>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">{{ use }}</span>
      </div>
      <div :style="tile(132)">
        <div :style="GLYPH"><CoreIcon name="medkit" :size="44" /></div>
        <span class="text-ui-sm font-mono">:size="44"</span>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">any number of px</span>
      </div>
    </KitSection>

    <KitSection label="Colour" :gap="22" note="currentColor — a text utility on the wrapper is all it takes.">
      <div v-for="[tone, icon] in TONES" :key="tone" :class="tone" :style="tile(128)">
        <div :style="GLYPH"><CoreIcon :name="icon" size="lg" /></div>
        <span class="text-ui-xs font-mono">{{ tone }}</span>
      </div>
    </KitSection>

    <KitSection label="Vitals" :gap="22" note="The meter tones of §37.2 — the same colours CoreStatBar uses.">
      <div v-for="[tone, icon] in VITALS" :key="tone" :class="tone" :style="tile(128)">
        <div :style="GLYPH"><CoreIcon :name="icon" size="lg" /></div>
        <span class="text-ui-xs font-mono">{{ tone }}</span>
      </div>
    </KitSection>

    <KitSection label="Spin, raw path, unknown name, title" :gap="30">
      <div :style="tile(190)">
        <div :style="GLYPH"><CoreIcon name="refresh" size="xl" spin /></div>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">spin — 0.8 s linear, the loading state</span>
      </div>
      <div :style="tile(190)">
        <div :style="GLYPH"><CoreIcon :path="MARK" size="xl" class="text-accent" /></div>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">:path — raw 24 × 24 data, no registry entry</span>
      </div>
      <div :style="tile(190)">
        <div :style="GLYPH" class="border border-border rounded-ui-sm"><CoreIcon name="not-an-icon" size="xl" /></div>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">an unknown name draws nothing and warns once</span>
      </div>
      <div :style="tile(190)">
        <div :style="GLYPH"><CoreIcon name="heart" size="xl" title="Health" /></div>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">title — the only way the glyph reaches the a11y tree</span>
      </div>
    </KitSection>

    <KitSection label="In text" layout="column" :gap="10" note="vertical-align: middle keeps a glyph on the baseline of a sentence.">
      <p class="core-text">
        Pick up the <CoreIcon name="medkit" size="sm" /> med kit, then drive to the
        <CoreIcon name="map-marker" size="sm" class="text-accent" /> marker on the ridge.
      </p>
      <p class="core-label">
        <CoreIcon name="heart" size="xs" /> health restore
      </p>
    </KitSection>
  </KitStage>
</template>
