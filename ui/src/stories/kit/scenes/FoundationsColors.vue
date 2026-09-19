<script setup>
// FoundationsColors — every colour, gradient, radius and shadow token of DESIGN §37.2, with the
// value the browser actually resolved (so a mistyped token shows up as an empty swatch here
// before it shows up as an invisible button in game).
import { onMounted, reactive } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const GROUPS = [
  {
    label: 'Surfaces',
    note: 'Blue-black slate. Panels are translucent over the game; wells are darker, raised cells lighter.',
    names: ['ink', 'panel', 'panel-glass', 'panel-solid', 'panel-raise', 'panel-sunken', 'border', 'border-strong', 'backdrop'],
  },
  {
    label: 'Accent',
    note: 'One coral red carries the brand. Alpha modifiers (bg-accent/10) are only safe on the hex tokens.',
    names: ['accent', 'accent-hi', 'accent-lo', 'accent-soft', 'on-accent'],
  },
  { label: 'Status', names: ['success', 'warning', 'error', 'info'] },
  { label: 'Vitals', names: ['health', 'armour', 'stamina', 'hunger', 'thirst', 'oxygen', 'stress'] },
  { label: 'Rarity', names: ['rarity-common', 'rarity-uncommon', 'rarity-rare', 'rarity-epic', 'rarity-legendary'] },
  { label: 'Text', names: ['fg', 'fg-dim', 'fg-faint'] },
  { label: 'Keys', note: 'A key cap is a near-white tile with dark condensed text.', names: ['key', 'key-fg'] },
  {
    label: 'HUD plates',
    note: 'The vitals strip of §39: a white plate over a dark track. The two plate-<vital> colours are '
      + 'the glyph ON the white fill — the ordinary --color-health / --color-armour are made for dark ground. '
      + 'plate-loss / plate-gain are the change chunk of §39.3.1, sampled from Liam\'s two reference clips: '
      + 'they are only ever seen for the length of one change, which is why they are this loud.',
    names: ['plate', 'plate-lo', 'plate-fg', 'plate-track', 'plate-health', 'plate-armour',
      'plate-loss', 'plate-gain', 'hud-tile'],
  },
]

const GRADIENTS = [
  ['core-grad-accent', 'Primary buttons, active chips, checked boxes, progress fills.'],
  ['core-grad-accent-fade', 'Active menu rows and the fading primary button (the mockups’ USE).'],
  ['core-grad-accent-fade-out', 'The same recipe dissolving further — long rows.'],
  ['core-grad-sheen', 'The faint top sheen every panel wears (shown over --color-panel).'],
]

const RADII = ['radius-ui', 'radius-ui-sm', 'radius-ui-xs']
const SHADOWS = ['shadow-ui', 'shadow-ui-sm', 'shadow-ui-lg', 'shadow-glow', 'shadow-glow-sm']

const values = reactive({})

onMounted(() => {
  const css = getComputedStyle(document.documentElement)
  // Tailwind v4 drops a theme variable nothing references, so a token can be in the @theme block
  // and still be missing at runtime until a utility or a kit partial uses it (`@theme static`
  // forces all of them out). That is what "not emitted" below means — the token is not lost.
  const read = (name) => (css.getPropertyValue(name) || '').trim() || '— not emitted —'
  for (const group of GROUPS) for (const name of group.names) values['--color-' + name] = read('--color-' + name)
  for (const [name] of GRADIENTS) values['--' + name] = read('--' + name)
  for (const name of RADII.concat(SHADOWS)) values['--' + name] = read('--' + name)
})

// The colour over a faint diagonal weave on the ink floor, so a translucent token reads as
// translucent instead of as a slightly different grey.
function swatch (name) {
  const colour = 'var(--color-' + name + ')'
  return {
    background: 'linear-gradient(0deg, ' + colour + ' 0%, ' + colour + ' 100%), '
      + 'repeating-linear-gradient(45deg, rgba(255, 255, 255, 0.05) 0 7px, rgba(255, 255, 255, 0) 7px 14px), '
      + 'var(--color-ink)',
  }
}
</script>

<template>
  <KitStage
    title="Colour"
    description="DESIGN §37.2 — the @theme tokens (Tailwind utilities: bg-panel, text-fg-dim, border-border …)
      and the plain :root recipes. Re-theming a server means overriding --color-accent*, --core-accent-rgb
      and the three gradients; nothing else in the kit knows a literal colour. A swatch that reads
      &quot;not emitted&quot; is declared but unused: Tailwind v4 only writes out the theme variables it sees
      referenced."
  >
    <KitSection
      v-for="group in GROUPS"
      :key="group.label"
      :label="group.label"
      :note="group.note"
      layout="row"
      :gap="14"
    >
      <div v-for="name in group.names" :key="name" style="width: 184px">
        <div
          :style="swatch(name)"
          class="border border-border rounded-ui-sm"
          style="height: 58px"
        ></div>
        <p class="text-ui-sm" style="margin: 8px 0 0">{{ name }}</p>
        <p class="text-ui-xs text-fg-faint font-mono" style="margin: 2px 0 0">{{ values['--color-' + name] }}</p>
      </div>
    </KitSection>

    <KitSection
      label="Gradients"
      layout="column"
      :gap="18"
      note="Plain :root recipes, not theme keys — read them with var(), never rebuild them by hand."
    >
      <div v-for="[name, purpose] in GRADIENTS" :key="name" style="width: 100%">
        <div
          class="border border-border rounded-ui-sm"
          :style="{
            height: name === 'core-grad-sheen' ? '96px' : '44px',
            background: name === 'core-grad-sheen'
              ? 'var(--' + name + '), var(--color-panel-solid)'
              : 'var(--' + name + ')',
          }"
        ></div>
        <p class="text-ui-sm" style="margin: 8px 0 0">
          <span class="font-mono">--{{ name }}</span> <span class="text-fg-dim">· {{ purpose }}</span>
        </p>
        <p class="text-ui-xs text-fg-faint font-mono truncate">{{ values['--' + name] }}</p>
      </div>
    </KitSection>

    <KitSection label="Radius" :gap="20" note="6 px panels, 4 px controls, 3 px key caps / checkboxes / badges.">
      <div v-for="name in RADII" :key="name" style="width: 164px">
        <div
          class="bg-panel-raise border border-border-strong"
          :style="{ height: '62px', borderRadius: 'var(--' + name + ')' }"
        ></div>
        <p class="text-ui-sm font-mono" style="margin: 8px 0 0">--{{ name }}</p>
        <p class="text-ui-xs text-fg-faint font-mono">{{ values['--' + name] }}</p>
      </div>
    </KitSection>

    <KitSection
      label="Shadow"
      :gap="34"
      note="A deep soft shadow under a panel; the glow pair is the selection look (never a filled block)."
    >
      <div v-for="name in SHADOWS" :key="name" style="width: 176px; margin-bottom: 18px">
        <div
          class="bg-panel-solid rounded-ui"
          :style="{ height: '66px', boxShadow: 'var(--' + name + ')' }"
        ></div>
        <p class="text-ui-sm font-mono" style="margin: 14px 0 0">--{{ name }}</p>
        <p class="text-ui-xs text-fg-faint font-mono truncate">{{ values['--' + name] }}</p>
      </div>
    </KitSection>
  </KitStage>
</template>
