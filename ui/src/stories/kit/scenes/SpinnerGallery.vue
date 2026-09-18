<script setup>
// SpinnerGallery — the two waiting states of the kit: CoreSpinner (busy, no measurable progress)
// and CoreSkeleton (the shape of the data that has not arrived yet).
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const SIZES = [
  ['sm', 14, 'inside a row or a small button'],
  ['md', 18, 'the default'],
  ['lg', 24, 'a panel that is still loading'],
]

const TONES = ['accent', 'neutral', 'success', 'warning', 'danger', 'info']

const cell = { display: 'flex', flexDirection: 'column', alignItems: 'center', gap: '10px', width: '140px' }

const PILL = {
  display: 'inline-flex',
  alignItems: 'center',
  gap: '12px',
  padding: '10px 18px',
  borderRadius: 'var(--radius-ui-sm)',
  border: '1px solid var(--color-border)',
  background: 'var(--color-panel)',
}

const CARD = {
  width: '340px',
  padding: '18px 20px',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  background: 'var(--color-panel-solid)',
}

const SLOT = {
  width: '74px',
  height: '74px',
  borderRadius: 'var(--radius-ui-sm)',
  border: '1px solid var(--color-border)',
  background: 'var(--color-panel-raise)',
  padding: '10px',
}
</script>

<template>
  <KitStage
    title="CoreSpinner &amp; CoreSkeleton"
    description="Two ways of saying &quot;not yet&quot;. The spinner is for work with no measurable
      progress — a server round trip, a database write, another player. The skeleton is for a layout that
      is already known: it holds the shape so the page does not jump when the data lands. When you DO know
      how far along you are, neither of these is the answer — use CoreProgress."
  >
    <KitSection label="Spinner — sizes" :gap="26" note="sm 14 · md 18 · lg 24 px, or a number. The stroke grows with the ring.">
      <div v-for="[size, px, use] in SIZES" :key="size" :style="cell">
        <CoreSpinner :size="size" />
        <span class="text-ui-sm">{{ size }} · {{ px }} px</span>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">{{ use }}</span>
      </div>
      <div :style="cell">
        <CoreSpinner :size="40" />
        <span class="text-ui-sm">:size="40"</span>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">any number of px</span>
      </div>
    </KitSection>

    <KitSection label="Spinner — tones and labels" layout="column" :gap="18" note="The label rides in the label voice; the ring keeps the tone.">
      <div style="display: flex; align-items: center; gap: 34px; flex-wrap: wrap">
        <CoreSpinner v-for="tone in TONES" :key="tone" :tone="tone" size="lg" />
      </div>
      <div style="display: flex; align-items: center; gap: 34px; flex-wrap: wrap">
        <CoreSpinner label="Contacting dispatch" />
        <CoreSpinner tone="neutral" label="Loading your garage" size="lg" />
        <CoreSpinner tone="info" label="Syncing" size="sm" />
      </div>
    </KitSection>

    <KitSection label="Spinner — in place" :gap="26" note="The shell's own busy pill (§37.6) is this component in a panel.">
      <div :style="PILL">
        <span class="core-label" style="letter-spacing: var(--tracking-label)">Contacting dispatch</span>
        <CoreSpinner size="sm" />
      </div>
      <div :style="PILL">
        <CoreSpinner tone="neutral" size="sm" label="Selling 14 items" />
      </div>
    </KitSection>

    <KitSection label="Skeleton — lines" layout="column" :gap="22" note="`height` is one line, `lines` stacks them, and a multi-line block ends short like real copy.">
      <div style="width: 480px">
        <CoreSkeleton :height="12" width="40%" />
      </div>
      <div style="width: 480px">
        <CoreSkeleton :lines="3" />
      </div>
      <div style="width: 480px">
        <CoreSkeleton :lines="2" :height="20" :radius="2" />
      </div>
    </KitSection>

    <KitSection label="Skeleton — the shape of what is coming" :gap="30" note="Match the real layout: a slot grid, an item card, a list row.">
      <div style="display: flex; gap: 10px">
        <div v-for="n in 4" :key="n" :style="SLOT">
          <CoreSkeleton height="100%" :radius="2" />
        </div>
      </div>
      <div :style="CARD">
        <div style="display: flex; gap: 14px; align-items: center">
          <CoreSkeleton :width="54" :height="54" :radius="4" />
          <div style="flex: 1 1 auto">
            <CoreSkeleton :height="16" width="70%" />
            <div style="height: 9px"></div>
            <CoreSkeleton :height="12" width="45%" />
          </div>
        </div>
        <div style="height: 18px"></div>
        <CoreSkeleton :lines="3" :height="11" />
      </div>
      <div :style="CARD">
        <div style="display: flex; align-items: center; gap: 12px">
          <CoreSpinner size="sm" tone="neutral" />
          <span class="core-label">Loading the marketplace</span>
        </div>
        <div style="height: 16px"></div>
        <CoreSkeleton :lines="4" :height="14" />
      </div>
    </KitSection>
  </KitStage>
</template>
