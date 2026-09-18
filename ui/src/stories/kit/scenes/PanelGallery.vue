<script setup>
// PanelGallery — every CorePanel variant, padding, heading and state (DESIGN §37.5, Surfaces).
// Run it over `bg=keyart` as well as `bg=game`: the fill, the hairline and the sheen only read
// right when there is a real picture behind the translucency.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const VARIANTS = [
  ['default', 'Translucent slate over the game — the everyday panel.'],
  ['solid', 'Opaque. For a panel that must not show the world (a shop over a bright street).'],
  ['flat', 'White 2 %, no shadow — a well inside another panel.'],
  ['ghost', 'Nothing but the padding: a section of a bigger surface.'],
  ['hud', 'The HUD plate: --color-hud, 4 px radius, brighter hairline, no sheen.'],
]

const VITALS = [
  ['health', 'Health', 82],
  ['armour', 'Armour', 46],
  ['stamina', 'Stamina', 100],
  ['hunger', 'Hunger', 61],
]

const PADDINGS = [
  ['none', '0 — a grid or a list that fills the panel edge to edge'],
  ['sm', '12 — sidebars, HUD cards'],
  ['md', '20 — the default'],
  ['lg', '28 — the inventory detail panel of mockup 3'],
]

const LOADOUT = [
  ['Combat Pistol', '1 mag', true],
  ['Micro SMG', '3 mags', false],
  ['Crowbar', '—', false],
]
</script>

<template>
  <KitStage
    title="CorePanel"
    :width="1180"
    description="The bordered dark panel every screen is built from: a translucent slate fill, a 1 px hairline,
      6 px radius and a deep soft shadow, with a faint 120 px sheen down from the top edge. Padding lives on the
      header, body and footer — never on the root — so a bare &lt;div class=&quot;core-panel&quot;&gt; works and a
      full-bleed grid can sit in a padding=&quot;none&quot; body."
  >
    <KitSection label="Variants" layout="grid" :columns="2" :gap="20">
      <CorePanel v-for="[variant, note] in VARIANTS" :key="variant" :variant="variant" :title="variant">
        <p class="core-text">{{ note }}</p>
      </CorePanel>
    </KitSection>

    <KitSection label="The HUD plate" layout="row" :gap="20"
      note="variant=&quot;hud&quot; over bg=keyart: --color-hud is thinner than --color-panel, so the plate stays
        readable on a bright street without turning into a menu. It never takes blur — the HUD is up all the time.">
      <CorePanel variant="hud" padding="sm" style="width: 268px">
        <div v-for="[tone, label, value] in VITALS" :key="tone" class="flex items-center" style="gap: 10px; padding: 3px 0">
          <span class="core-label" :class="'core-tone-' + tone" style="width: 72px; color: var(--tone)">{{ label }}</span>
          <span
            :class="'core-tone-' + tone"
            style="flex: 1 1 auto; height: 4px; border-radius: 2px; background: var(--color-panel-sunken)"
          >
            <span :style="{ display: 'block', width: value + '%', height: '100%', borderRadius: '2px', background: 'var(--tone)' }"></span>
          </span>
          <span class="core-num text-ui-xs text-fg-dim" style="width: 26px; text-align: right">{{ value }}</span>
        </div>
      </CorePanel>

      <CorePanel variant="hud" padding="sm" style="width: 190px">
        <div class="flex items-center" style="gap: 10px">
          <CoreIcon name="cash" size="sm" class="text-success" />
          <span class="core-label">Cash</span>
          <span class="core-num text-ui" style="margin-left: auto; color: var(--color-fg)">$4,180</span>
        </div>
      </CorePanel>

      <CorePanel variant="hud" padding="sm" accent style="width: 210px">
        <p class="core-label" style="color: var(--color-fg)">Wanted</p>
        <p class="text-ui-sm text-fg-dim" style="margin-top: 4px">Two stars &middot; Vinewood</p>
      </CorePanel>
    </KitSection>

    <KitSection label="Padding" layout="grid" :columns="4" :gap="16" note="0 / 12 / 20 / 28 px on every part.">
      <CorePanel v-for="[pad, note] in PADDINGS" :key="pad" :padding="pad">
        <div class="bg-accent-soft border border-accent rounded-ui-sm" style="padding: 10px 12px">
          <p class="core-label" style="color: var(--color-fg)">padding="{{ pad }}"</p>
          <p class="text-ui-xs text-fg-faint" style="margin-top: 6px">{{ note }}</p>
        </div>
      </CorePanel>
    </KitSection>

    <KitSection label="Heading" layout="grid" :columns="2" :gap="20" note="title · subtitle · eyebrow · slash · headingSize.">
      <CorePanel title="Inventory" subtitle="Gear up for what's next." padding="lg">
        <p class="core-text">Title + subtitle, the inventory grid header of mockup 3.</p>
      </CorePanel>
      <CorePanel title="Quests" slash>
        <p class="core-text">slash — the // marker and an italic title (mockup 4).</p>
      </CorePanel>
      <CorePanel eyebrow="Los Santos Customs" title="Repair &amp; Respray" heading-size="lg">
        <p class="core-text">eyebrow above, headingSize="lg" (34 px).</p>
      </CorePanel>
      <CorePanel title="Med Kit" subtitle="Common &middot; Consumable" padding="lg">
        <template #actions>
          <div style="text-align: right">
            <p class="core-num" style="font-size: 22px; color: var(--color-fg)">3 / 10</p>
            <p class="core-label" style="margin-top: 4px">In inventory</p>
          </div>
        </template>
        <p class="core-text">Restores a significant amount of health.</p>
        <p class="core-flavor" style="margin-top: 10px">A small kit. A second chance.</p>
      </CorePanel>
    </KitSection>

    <KitSection label="Accent, footer, scroll" layout="grid" :columns="3" :gap="20">
      <CorePanel accent title="Dispatch" subtitle="Unit 12-Adam">
        <p class="core-text">accent — a 2 px coral line dissolving along the top edge.</p>
      </CorePanel>

      <CorePanel title="Loadout">
        <ul style="list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px">
          <li v-for="[gun, ammo, equipped] in LOADOUT" :key="gun" class="flex items-center justify-between">
            <span class="text-ui" :style="{ color: equipped ? 'var(--color-fg)' : 'var(--color-fg-dim)' }">{{ gun }}</span>
            <span class="core-num text-ui-sm text-fg-faint">{{ ammo }}</span>
          </li>
        </ul>
        <template #footer>
          <span class="core-label">Weight</span>
          <span class="core-num text-ui-sm" style="margin-left: auto; color: var(--color-fg)">18.5 / 30.0</span>
        </template>
      </CorePanel>

      <CorePanel title="Faction log" subtitle="Last 24 hours" scroll style="height: 232px">
        <p v-for="n in 9" :key="n" class="core-text" style="margin-bottom: 10px">
          {{ n }}. Vehicle #{{ 4180 + n }} impounded at Mission Row.
        </p>
      </CorePanel>
    </KitSection>

    <KitSection label="Glass and the bare class" layout="grid" :columns="2" :gap="20"
      note="blur = data-core-blur (§32): gameblur.js inserts the .core-glass wrapper and paints the tint.">
      <CorePanel blur title="Glass" subtitle="blur">
        <p class="core-text">A blurred copy of the game behind a thinner tint. One per page (§32.1).</p>
      </CorePanel>
      <div class="core-panel" style="padding: 20px">
        <p class="core-title">Legacy class</p>
        <p class="core-text" style="margin-top: 8px">
          &lt;div class="core-panel"&gt; on plain HTML is the default variant with no padding of its own.
        </p>
      </div>
    </KitSection>
  </KitStage>
</template>
