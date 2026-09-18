<script setup>
// ObjectiveGallery — CoreObjective and CoreTracker (DESIGN §37.5, Game).
// Shoot this one with ?bg=keyart: CoreTracker is a HUD card over the world, and its ink 72 %
// fill and the hairline running down out of the pin only read against something bright.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const states = [
  { state: 'open', text: 'Find a working radio', trailing: '1.4 km' },
  { state: 'active', text: 'Meet the contact at the old tower', trailing: '842 m' },
  { state: 'done', text: 'Refuel the truck at Harmony', trailing: '' },
  { state: 'failed', text: 'Reach the drop before midnight', trailing: '00:00' },
]

const chain = [
  { state: 'done', text: 'Clear the checkpoint' },
  { state: 'active', text: 'Meet the contact at the old tower', trailing: '842 m' },
  { state: 'open', text: 'Escort the convoy back to Solace City' },
  { state: 'open', text: 'Recover the black box', optional: true },
]
</script>

<template>
  <KitStage
    title="Objective &amp; Tracker"
    description="The quest checklist and the HUD card of mockup 2 and 4. A CoreObjective is an 18 px ring
      and a line of copy; CoreTracker stacks title, one line of direction and the distance beside a rail
      whose hairline runs down out of the pin. Both are painted over the world and take no mouse."
    :width="1000"
  >
    <KitSection
      label="Tracker — mockup 2"
      layout="column"
      :gap="18"
      note="`bloom` (the default) lets the world through two soft spots on the left — a small one behind the pin, a bigger one out of the bottom-left corner — the way the mockup's plate does; `:bloom=&quot;false&quot;` is the flat --color-hud plate"
    >
      <CoreTracker
        title="A Brighter Tomorrow"
        text="Meet the contact at the old tower."
        distance="842 m"
      />
      <CoreTracker
        :bloom="false"
        title="A Brighter Tomorrow"
        text="Meet the contact at the old tower."
        distance="842 m"
      />
    </KitSection>

    <KitSection label="Tracker — tones and objectives" layout="column" :gap="20">
      <div class="flex items-start" style="gap: 20px">
        <CoreTracker
          title="Supply Lines"
          tone="info"
          icon="truck"
          text="Deliver the crates to the depot."
          distance="2.4 km"
          :objectives="[
            { state: 'done', text: 'Load the truck' },
            { state: 'active', text: 'Drive to Paleto Bay', trailing: '2.4 km' },
          ]"
        />
        <CoreTracker
          title="Last Call"
          tone="danger"
          icon="skull"
          text="Survive until dawn. Nobody is coming."
          distance="120 m"
        />
        <CoreTracker
          title="Scrap Run"
          tone="success"
          icon="crate"
          text="Three more crates and the contract is yours."
          distance="640 m"
        />
      </div>
    </KitSection>

    <KitSection label="Objective states" layout="column" :gap="6" note="open · active (coral ring + dot) · done (filled, text dimmed) · failed (error cross, struck)">
      <div class="bg-panel border border-border rounded-ui" style="width: 640px; padding: 14px 20px">
        <CoreObjective v-for="item in states" :key="item.state" v-bind="item" />
      </div>
    </KitSection>

    <KitSection label="A chain, with a bonus line" layout="column" :gap="6">
      <div class="bg-panel border border-border rounded-ui" style="width: 640px; padding: 14px 20px">
        <CoreObjective v-for="(item, i) in chain" :key="i" v-bind="item" />
      </div>
    </KitSection>
  </KitStage>
</template>
