<script setup>
// IconButtonGallery — CoreIconButton: the four variants, the three square sizes, round, the
// toggle-on state, disabled, and the two places it actually appears (a panel header's actions and
// a map toolbar).
import { onMounted, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const pinned = ref(true)
const muted = ref(false)
const zoom = ref(3)
const focusMe = ref(null)

// :focus-visible only paints for keyboard focus, so the ring is put on screen by hand.
onMounted(() => {
  const el = focusMe.value && (focusMe.value.$el || focusMe.value)
  if (el && typeof el.focus === 'function') el.focus({ preventScroll: true })
})

const VARIANTS = [
  ['secondary', 'settings', 'Settings'],
  ['ghost', 'close', 'Close'],
  ['primary', 'check', 'Confirm'],
  ['danger', 'trash', 'Delete'],
  ['success', 'check-circle', 'Accept job'],
]

const label = { display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '9px', width: '112px' }
const panel = {
  background: 'var(--color-panel)',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  boxShadow: 'var(--shadow-ui)',
  padding: '14px 16px',
}
</script>

<template>
  <KitStage
    title="CoreIconButton"
    description="A square CoreButton — same fills, same borders, same focus ring, width locked to the control
      height. `label` is the accessible name and the tooltip, because the glyph carries no text."
  >
    <KitSection label="Variants" :gap="24" note="The same five fills as CoreButton, from the same rules.">
      <div v-for="[variant, icon, name] in VARIANTS" :key="variant" :style="label">
        <CoreIconButton :variant="variant" :icon="icon" :label="name" />
        <span class="text-ui-xs text-fg-faint">{{ variant }}</span>
      </div>
      <div :style="label">
        <CoreIconButton variant="primary" fade icon="medkit" label="Use med kit" />
        <span class="text-ui-xs text-fg-faint">primary · fade</span>
      </div>
    </KitSection>

    <KitSection label="Sizes" :gap="24" note="30 / 40 / 52 px — square, from --core-h-*.">
      <div v-for="size in ['sm', 'md', 'lg']" :key="size" :style="label">
        <CoreIconButton icon="refresh" label="Refresh" :size="size" />
        <span class="text-ui-xs text-fg-faint">{{ size }}</span>
      </div>
      <div v-for="size in ['sm', 'md', 'lg']" :key="'r-' + size" :style="label">
        <CoreIconButton icon="close" label="Close" :size="size" round />
        <span class="text-ui-xs text-fg-faint">round · {{ size }}</span>
      </div>
    </KitSection>

    <KitSection label="States" :gap="24">
      <div :style="label">
        <CoreIconButton icon="pin" label="Pin quest" :active="pinned" @click="pinned = !pinned" />
        <span class="text-ui-xs text-fg-faint">active (toggle)</span>
      </div>
      <div :style="label">
        <CoreIconButton icon="volume-off" label="Mute radio" :active="muted" variant="ghost" @click="muted = !muted" />
        <span class="text-ui-xs text-fg-faint">ghost · toggle</span>
      </div>
      <div :style="label">
        <CoreIconButton icon="trash" label="Delete" variant="danger" disabled />
        <span class="text-ui-xs text-fg-faint">disabled</span>
      </div>
      <div :style="label">
        <CoreIconButton icon="star" label="Favourite" variant="primary" round />
        <span class="text-ui-xs text-fg-faint">primary · round</span>
      </div>
      <div :style="label">
        <CoreIconButton icon="crown" label="Custom glyph">
          <CoreIcon name="crown" :size="20" class="text-warning" />
        </CoreIconButton>
        <span class="text-ui-xs text-fg-faint">default slot</span>
      </div>
      <div :style="label">
        <CoreIconButton ref="focusMe" icon="keyboard" label="Key bindings" variant="ghost" />
        <span class="text-ui-xs text-fg-faint">:focus-visible</span>
      </div>
    </KitSection>

    <KitSection label="In place" :gap="26" note="A panel header's actions, and the map toolbar.">
      <div :style="panel" style="width: 420px; display: flex; align-items: center; gap: 12px">
        <span class="core-title" style="font-size: 18px">Vehicle garage</span>
        <span class="text-ui-sm text-fg-faint" style="margin-left: auto">12 / 20</span>
        <CoreIconButton icon="sort" label="Sort" size="sm" variant="ghost" />
        <CoreIconButton icon="filter" label="Filter" size="sm" variant="ghost" active />
        <CoreIconButton icon="close" label="Close" size="sm" variant="ghost" />
      </div>

      <div :style="panel" style="display: inline-flex; flex-direction: column; gap: 8px; padding: 8px">
        <CoreIconButton icon="plus" label="Zoom in" @click="zoom = Math.min(zoom + 1, 6)" />
        <CoreIconButton icon="minus" label="Zoom out" @click="zoom = Math.max(zoom - 1, 1)" />
        <CoreIconButton icon="navigation" label="Recenter" variant="primary" />
      </div>
      <span class="core-num text-fg-dim" style="font-size: 17px">zoom {{ zoom }} / 6</span>
    </KitSection>
  </KitStage>
</template>
