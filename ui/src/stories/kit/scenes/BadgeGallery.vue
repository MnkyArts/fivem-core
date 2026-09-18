<script setup>
// BadgeGallery — CoreBadge and CoreTag: every variant, tone, rarity, size and state
// (DESIGN §37.5, Data — display). The clock chip at the end is mockup 2's HUD read-out.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const TONES = ['accent', 'neutral', 'success', 'warning', 'danger', 'info']
const RARITIES = ['common', 'uncommon', 'rare', 'epic', 'legendary']

const COUNTS = [
  ['3', 'unread dispatch calls'],
  ['12', 'items over capacity'],
  ['128', 'clipped by max = 99'],
]

const STATUS_TAGS = [
  { label: 'On duty', tone: 'success', icon: 'shield' },
  { label: 'Wanted', tone: 'danger', icon: 'police' },
  { label: 'Low fuel', tone: 'warning', icon: 'fuel' },
  { label: 'Impounded', tone: 'neutral', icon: 'garage' },
]

const filters = ref(['Pistols', 'Ammunition', 'Medical'])
function drop (name) {
  filters.value = filters.value.filter((f) => f !== name)
}
function reset () {
  filters.value = ['Pistols', 'Ammunition', 'Medical']
}
</script>

<template>
  <KitStage
    title="CoreBadge · CoreTag"
    description="The two smallest things in the kit. A badge counts (or just says &quot;something
      changed&quot;); a tag names — a rarity, a state, a filter someone can drop again. Both read
      their colour from the tone classes of css/base.css, so a rarity and a tone are the same
      machinery."
  >
    <KitSection label="Badge — variants × tones" layout="column" :gap="14" note="solid · soft · outline. Accent solid wears the brand gradient.">
      <div v-for="variant in ['solid', 'soft', 'outline']" :key="variant" style="display: flex; align-items: center; gap: 14px">
        <span class="core-label" style="width: 76px">{{ variant }}</span>
        <CoreBadge v-for="tone in TONES" :key="tone" :variant="variant" :tone="tone" :value="7" />
        <span class="text-ui-xs text-fg-faint" style="margin-left: 8px">accent · neutral · success · warning · danger · info</span>
      </div>
    </KitSection>

    <KitSection label="Badge — counts, dot, pulse" :gap="30" note="max (99) prints 99+; dot drops the value; pulse expands a tone ring out of the pip (core-ping).">
      <div v-for="[value, caption] in COUNTS" :key="value" style="display: flex; flex-direction: column; align-items: center; gap: 9px; width: 150px">
        <CoreBadge :value="value" />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">{{ caption }}</span>
      </div>
      <div style="display: flex; flex-direction: column; align-items: center; gap: 9px; width: 150px">
        <CoreBadge dot tone="success" />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">dot — server online</span>
      </div>
      <div style="display: flex; flex-direction: column; align-items: center; gap: 9px; width: 150px">
        <CoreBadge dot pulse tone="danger" />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">dot + pulse — panic button</span>
      </div>
      <div style="display: flex; flex-direction: column; align-items: center; gap: 9px; width: 150px">
        <CoreBadge pulse value="2" tone="warning" />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">pulse with a count</span>
      </div>
    </KitSection>

    <KitSection label="Badge — in place" :gap="34" note="A badge is never alone: it hangs off a glyph, a tab label or a row.">
      <div style="position: relative; display: inline-flex; padding: 6px">
        <CoreIcon name="bell" size="lg" class="text-fg-dim" />
        <CoreBadge value="4" style="position: absolute; top: 0; right: -4px" />
      </div>
      <div style="position: relative; display: inline-flex; padding: 6px">
        <CoreIcon name="chat" size="lg" class="text-fg-dim" />
        <CoreBadge dot pulse tone="accent" style="position: absolute; top: 3px; right: 0" />
      </div>
      <span class="core-label" style="display: inline-flex; align-items: center; gap: 8px">
        Inventory <CoreBadge value="26" variant="soft" tone="neutral" />
      </span>
      <span class="core-label" style="display: inline-flex; align-items: center; gap: 8px">
        Faction requests <CoreBadge value="128" variant="soft" tone="info" />
      </span>
    </KitSection>

    <KitSection label="Tag — variants" layout="column" :gap="14" note="soft (14 %) · solid · outline · dark (the HUD plate, no border).">
      <div v-for="variant in ['soft', 'solid', 'outline', 'dark']" :key="variant" style="display: flex; align-items: center; gap: 10px">
        <span class="core-label" style="width: 76px">{{ variant }}</span>
        <CoreTag v-for="tone in TONES" :key="tone" :variant="variant" :tone="tone" :label="tone" />
      </div>
    </KitSection>

    <KitSection label="Tag — rarities" :gap="10" note="rarity wins over tone: both only set --tone / --tone-rgb, and the rarity class lands last.">
      <CoreTag v-for="r in RARITIES" :key="r" :rarity="r" :label="r" />
      <CoreTag v-for="r in RARITIES" :key="r + '-solid'" :rarity="r" variant="solid" :label="r" />
    </KitSection>

    <KitSection label="Tag — sizes and icons" :gap="12" note="20 / 24 / 30 px. The glyph scales with the chip (14 / 16 / 18).">
      <CoreTag size="sm" icon="ammo" label="9 mm" tone="neutral" />
      <CoreTag size="md" icon="medkit" label="Consumable" tone="success" />
      <CoreTag size="lg" icon="crown" label="Faction lead" tone="warning" />
      <CoreTag size="lg" variant="solid" icon="police" label="Wanted 3" tone="danger" />
    </KitSection>

    <KitSection label="Tag — states" :gap="12">
      <CoreTag v-for="t in STATUS_TAGS" :key="t.label" :icon="t.icon" :tone="t.tone" :label="t.label" />
    </KitSection>

    <KitSection label="Tag — removable" layout="column" :gap="12" note="The ✕ is a real button: hover brightens it, Tab reaches it, Enter fires `remove`.">
      <div style="display: flex; align-items: center; gap: 10px; min-height: 30px">
        <CoreTag
          v-for="name in filters"
          :key="name"
          :label="name"
          tone="accent"
          removable
          @remove="drop(name)"
        />
        <span v-if="!filters.length" class="text-ui-sm text-fg-faint">All filters cleared.</span>
      </div>
      <button class="core-label" type="button" style="pointer-events: auto; cursor: pointer; background: none; border: 0; padding: 0; color: var(--color-accent)" @click="reset">
        reset the filters
      </button>
    </KitSection>

    <KitSection label="Mockup 2 — the HUD clock" :gap="16" note="variant=&quot;dark&quot; size=&quot;lg&quot;: ink 78 %, no border, fg text — and the tone stays on the glyph.">
      <CoreTag variant="dark" size="lg" icon="sun" tone="warning" label="18:24" />
      <CoreTag variant="dark" size="lg" icon="moon" tone="info" label="02:07" />
      <CoreTag variant="dark" size="lg" icon="map-marker" tone="accent" label="Sandy Shores" />
      <CoreTag variant="dark" size="lg" icon="cash" tone="success" label="$ 14,280" />
    </KitSection>
  </KitStage>
</template>
