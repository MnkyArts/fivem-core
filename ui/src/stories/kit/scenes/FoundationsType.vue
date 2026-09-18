<script setup>
// FoundationsType — the type voices of DESIGN §37.1/§37.5 and the two bundled families.
// Sample copy comes straight from the mockups, so a wrong weight or tracking is obvious against
// the picture rather than a matter of taste.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const DISPLAY = [
  ['core-display core-display--xl', '--text-display-xl · 48 px', 'WAYFINDER'],
  ['core-display core-display--lg', '--text-display-lg · 34 px', 'INVENTORY'],
  ['core-display core-display--md', '--text-display · 24 px', 'MED KIT'],
  ['core-display core-display--sm', '--text-display-sm · 18 px', 'TRACK QUEST'],
]

const VOICES = [
  ['core-title', 'display 700 · 22 px · uppercase — panel and dialog titles', 'A Brighter Tomorrow'],
  ['core-label', 'display 600 · 12 px · 0.14 em — the caption over a control', 'Health restore'],
  ['core-eyebrow', 'display 500 · 13 px · 0.32 em — the subtitle under a heading', "Gear up for what's next."],
  ['core-text', 'Barlow 400 · 15 px · fg-dim — body copy and descriptions', 'Restores a significant amount of health.'],
  ['core-flavor', 'Barlow 400 italic · 14 px · fg-faint — the aside under a description', 'A small kit. A second chance.'],
  ['core-num', 'display 600 · tabular — any number that must not jitter', '18.5 / 30.0'],
]

const CONDENSED = [
  [500, false, 'Barlow Condensed 500'],
  [600, false, 'Barlow Condensed 600'],
  [600, true, 'Barlow Condensed 600 italic'],
  [700, false, 'Barlow Condensed 700'],
  [700, true, 'Barlow Condensed 700 italic'],
]

const BODY = [
  [400, false, 'Barlow 400'],
  [400, true, 'Barlow 400 italic'],
  [500, false, 'Barlow 500'],
  [600, false, 'Barlow 600'],
]

const SPECIMEN = 'Explore a larger tomorrow — 0123456789'

function face (family, weight, italic) {
  return {
    fontFamily: 'var(--font-' + family + ')',
    fontWeight: String(weight),
    fontStyle: italic ? 'italic' : 'normal',
    fontSize: family === 'display' ? '28px' : '22px',
    lineHeight: '1.25',
    margin: '0',
  }
}
</script>

<template>
  <KitStage
    title="Type"
    description="Barlow Condensed carries every heading, button, tab, menu row, label and number (uppercase,
      tracked); Barlow carries body copy and form text. Both are bundled under kit/fonts — the CEF cannot
      fetch the web — and are reached through --font-display and --font-sans, never by name."
  >
    <KitSection label="Display voice" layout="column" :gap="22" note="700 · uppercase · 0.04 em · line-height 1">
      <div v-for="[cls, caption, sample] in DISPLAY" :key="caption">
        <p :class="cls">{{ sample }}</p>
        <p class="text-ui-xs text-fg-faint font-mono" style="margin: 6px 0 0">{{ cls }} — {{ caption }}</p>
      </div>
    </KitSection>

    <KitSection label="Voices" layout="column" :gap="20" note="One class per voice — a page never restyles text by hand.">
      <div v-for="[cls, caption, sample] in VOICES" :key="cls">
        <p :class="cls">{{ sample }}</p>
        <p class="text-ui-xs text-fg-faint font-mono" style="margin: 6px 0 0">.{{ cls }} — {{ caption }}</p>
      </div>
    </KitSection>

    <KitSection label="Barlow Condensed — --font-display" layout="column" :gap="14">
      <div v-for="[weight, italic, caption] in CONDENSED" :key="caption" style="width: 100%">
        <p :style="face('display', weight, italic)">{{ SPECIMEN }}</p>
        <p class="text-ui-xs text-fg-faint font-mono">{{ caption }}</p>
      </div>
    </KitSection>

    <KitSection label="Barlow — --font-sans" layout="column" :gap="14">
      <div v-for="[weight, italic, caption] in BODY" :key="caption" style="width: 100%">
        <p :style="face('sans', weight, italic)">{{ SPECIMEN }}</p>
        <p class="text-ui-xs text-fg-faint font-mono">{{ caption }}</p>
      </div>
    </KitSection>

    <KitSection label="Sizes" layout="row" :gap="22" note="--text-ui-* for interface text, --text-display-* for the display voice.">
      <p class="text-ui-lg">text-ui-lg · 17</p>
      <p class="text-ui">text-ui · 15 (body)</p>
      <p class="text-ui-sm">text-ui-sm · 13</p>
      <p class="text-ui-xs">text-ui-xs · 11</p>
    </KitSection>
  </KitStage>
</template>
