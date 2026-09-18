<script setup>
// ButtonGallery — every CoreButton variant, size, slot and state, plus the two buttons the
// mockups actually show (the inventory USE / DROP pair and the map's TRACK QUEST block) and the
// legacy bare classes a plugin page may still be wearing.
import { onMounted, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const clicks = ref(0)
const busy = ref(false)
const tracking = ref(false)
const focusMe = ref(null)

// The gallery must show a focus ring without anyone pressing Tab: :focus-visible only paints for
// keyboard focus, so the element is focused programmatically once the scene is up.
onMounted(() => {
  const el = focusMe.value && (focusMe.value.$el || focusMe.value)
  if (el && typeof el.focus === 'function') el.focus({ preventScroll: true })
})

function buy () {
  clicks.value += 1
  busy.value = true
  window.setTimeout(() => { busy.value = false }, 1400)
}

const panel = {
  background: 'var(--color-panel)',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  boxShadow: 'var(--shadow-ui)',
  padding: '20px',
}
</script>

<template>
  <KitStage
    title="CoreButton"
    description="Display voice, uppercase, tracked. The primary carries the brand: a gradient lit from the
      left, a coral drop glow and a white label. `fade` is the mockups' USE button — coral for the first
      fifth, dissolved into the panel by the right edge, held together by a thin coral line."
  >
    <KitSection label="Variants" note="secondary is the default, so a bare `core-btn` is already right.">
      <CoreButton variant="primary" icon="cart">Buy vehicle</CoreButton>
      <CoreButton variant="primary" fade icon="medkit">Use</CoreButton>
      <CoreButton>Drop</CoreButton>
      <CoreButton variant="ghost">Cancel</CoreButton>
      <CoreButton variant="danger" icon="trash">Delete save</CoreButton>
      <CoreButton variant="success" icon="check">Accept job</CoreButton>
    </KitSection>

    <KitSection label="Sizes" note="30 / 40 / 52 px — the --core-h-* control heights.">
      <CoreButton variant="primary" size="sm">Refuel</CoreButton>
      <CoreButton variant="primary" size="md">Refuel</CoreButton>
      <CoreButton variant="primary" size="lg">Refuel</CoreButton>
      <CoreButton size="sm">Leave</CoreButton>
      <CoreButton size="md">Leave</CoreButton>
      <CoreButton size="lg">Leave</CoreButton>
    </KitSection>

    <KitSection label="Icon · key cap · trailing" :gap="14">
      <CoreButton variant="primary" icon="navigation">Track quest</CoreButton>
      <CoreButton variant="primary" fade kbd="F" icon="medkit">Use</CoreButton>
      <CoreButton kbd="E">Open trunk</CoreButton>
      <CoreButton icon-right="chevron-right">Next crew</CoreButton>
      <CoreButton variant="ghost" icon="refresh">Reset filters</CoreButton>
      <CoreButton>
        <template #icon><CoreIcon name="fuel" :size="18" class="text-warning" /></template>
        Low fuel
      </CoreButton>
    </KitSection>

    <KitSection label="States" note="loading keeps the label (and the width); disabled swallows the click.">
      <CoreButton variant="primary" active>Owned</CoreButton>
      <CoreButton active icon="filter">Quests only</CoreButton>
      <CoreButton variant="primary" loading icon="cart">Buy vehicle</CoreButton>
      <CoreButton loading>Contacting dispatch</CoreButton>
      <CoreButton variant="primary" disabled icon="cart">Not enough cash</CoreButton>
      <CoreButton disabled>Locked</CoreButton>
      <CoreButton variant="danger" disabled>Cannot sell</CoreButton>
      <CoreButton ref="focusMe" variant="ghost">Focused</CoreButton>
    </KitSection>

    <KitSection label="Block" layout="column" :gap="12" note="is-block: full width of the column it sits in.">
      <div style="width: 340px; display: flex; flex-direction: column; gap: 10px">
        <CoreButton variant="primary" size="lg" block icon="navigation">Track quest</CoreButton>
        <CoreButton block>Clear all markers</CoreButton>
      </div>
    </KitSection>

    <KitSection label="From the mockups" :gap="26" note="Left: the inventory detail footer. Right: the map filter panel.">
      <div :style="panel" style="width: 420px">
        <div style="border-top: 1px solid var(--color-border); border-bottom: 1px solid var(--color-border);
                    display: flex; align-items: center; gap: 12px; padding: 12px 2px">
          <CoreIcon name="heart" :size="22" />
          <span class="core-display" style="font-size: 17px; letter-spacing: 0.1em; font-weight: 500">Health restore</span>
          <span class="core-num" style="margin-left: auto; font-size: 24px; font-weight: 700">+75</span>
        </div>
        <p class="core-flavor" style="margin: 16px 0 18px">A small kit. A second chance.</p>
        <div style="display: flex; gap: 12px">
          <CoreButton variant="primary" fade size="lg" style="flex: 1.15">
            <template #icon>
              <CoreKey class="core-btn__kbd"><CoreIcon name="medkit" :size="14" class="text-accent" /></CoreKey>
            </template>
            Use
          </CoreButton>
          <CoreButton size="lg" style="flex: 1">Drop</CoreButton>
        </div>
      </div>

      <div :style="panel" style="width: 320px">
        <p class="core-label" style="margin-bottom: 14px">Map filters</p>
        <p class="core-text" style="font-size: 14px; margin-bottom: 18px">
          Quests, locations and fast travel are shown. Three markers are on the route.
        </p>
        <CoreButton
          variant="primary"
          size="lg"
          block
          icon="navigation"
          :active="tracking"
          @click="tracking = !tracking"
        >
          {{ tracking ? 'Tracking' : 'Track quest' }}
        </CoreButton>
      </div>
    </KitSection>

    <KitSection label="Legacy classes" note="Plain elements wearing the bare classes — no component involved.">
      <button type="button" class="core-btn">Close</button>
      <button type="button" class="core-btn core-btn--primary">Confirm</button>
      <button type="button" class="core-btn core-btn--ghost">Skip</button>
      <button type="button" class="core-btn core-btn--danger">Abandon</button>
      <button type="button" class="core-btn" disabled>Sold out</button>
    </KitSection>

    <KitSection label="The click contract" layout="row" :gap="14"
                note="click never fires while loading or disabled — the counter proves it.">
      <CoreButton variant="primary" data-role="buy" :loading="busy" icon="cash" @click="buy">Buy fuel</CoreButton>
      <CoreButton data-role="dead" disabled @click="clicks += 1">Disabled</CoreButton>
      <span class="core-num" data-role="count" style="font-size: 19px">{{ clicks }} purchase(s)</span>
    </KitSection>
  </KitStage>
</template>
