<script setup>
// CoreToast gallery (DESIGN §37.5, Feedback; the skin of the shell's Notifications, §37.6).
// The first section is the rail as the shell stacks it — 340 px cards, 8 px apart, top right —
// because that is the only place a toast is ever seen; the rest proves tone, count and life bar.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const RAIL = [
  { tone: 'success', title: 'Deposit', message: 'You banked $4,200 from the Paleto run.' },
  { tone: 'warning', title: 'Vehicle damage', message: 'The Sultan is at 34 % — it will not survive another roadblock.' },
  { tone: 'danger', title: 'Wanted', message: 'Three stars. Dispatch is calling in a chopper.' },
  { tone: 'info', title: 'Faction', message: 'Marek went on duty at the Sandy Shores garage.' },
]

const TONES = ['accent', 'neutral', 'success', 'warning', 'danger', 'info']
</script>

<template>
  <KitStage
    title="Toast"
    description="The notification card: 340 px, panel fill, one hairline, a 3 px tone bar and a title in the
      tone. Click-through like every HUD surface (§37.4) — only the ✕ takes the mouse."
  >
    <KitSection label="The rail" layout="column" :gap="8" note="how the shell stacks them: top right, newest first">
      <CoreToast v-for="t in RAIL" :key="t.title" :tone="t.tone" :title="t.title" :message="t.message" />
    </KitSection>

    <KitSection label="Tones" layout="grid" :columns="2" :gap="12">
      <CoreToast
        v-for="tone in TONES"
        :key="tone"
        :tone="tone"
        :title="tone"
        message="Ammu-Nation restocked. Heavy rounds are back on the shelf."
      />
    </KitSection>

    <KitSection label="Repeats and life" layout="column" :gap="10" note="`count` for a line that arrived again, `progress` for the time left">
      <CoreToast tone="warning" title="Radiation" message="Leave the quarry — you are taking damage." :count="4" />
      <CoreToast tone="info" title="Fare offered" message="Pickup at Del Perro Pier, 1.4 km." :progress="1" />
      <CoreToast tone="info" title="Fare offered" message="Pickup at Del Perro Pier, 1.4 km." :progress="0.55" />
      <CoreToast tone="info" title="Fare offered" message="Pickup at Del Perro Pier, 1.4 km." :progress="0.12" />
    </KitSection>

    <KitSection label="Shapes" layout="column" :gap="10" note="no title, no glyph, dismissible, and rich content in the slot">
      <CoreToast tone="neutral" message="Autosave complete." />
      <CoreToast tone="success" icon="" title="Level up" message="Rank 27 — Bennys unlocked the turbo tune." />
      <CoreToast
        tone="danger"
        dismissible
        title="Insurance claim"
        message="The Kuruma was written off. $2,700 was deducted for the replacement."
        :count="2"
        :progress="0.8"
      />
      <CoreToast tone="accent" title="Contract">
        <span class="text-fg">Lester</span> wants the Vangelico job run before 02:00 — the night guard
        rotates at three.
      </CoreToast>
    </KitSection>
  </KitStage>
</template>
