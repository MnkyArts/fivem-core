<script setup>
// CoreAlert gallery (DESIGN §37.5, Feedback) — every tone, both variants, the dismissible and the
// action shapes. The alert is the *inline* banner: it belongs inside a panel, next to the thing it
// talks about. A message that should follow the player around the map is a CoreToast instead.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const TONES = ['accent', 'neutral', 'success', 'warning', 'danger', 'info']

const COPY = {
  accent: ['Faction invite', 'The Del Perro Crew asked you to ride with them. The offer expires in five minutes.'],
  neutral: ['Nothing tracked', 'Pick a contract from the board to put an objective on your map.'],
  success: ['Purchase complete', 'The Sultan RS is waiting in your Legion Square garage.'],
  warning: ['Fuel low', '12 % left in the tank. Nearest pump is 480 m north on Route 68.'],
  danger: ['Wanted level raised', 'Dispatch has your last known position. Lose the chopper before you drive home.'],
  info: ['Server restart in 10 minutes', 'Anything parked on the street is impounded on restart. Garage your vehicle.'],
}

const dismissed = ref(false)
</script>

<template>
  <KitStage
    title="Alert"
    description="The inline banner: tone 10 % fill, a tone hairline and the 3 px tone bar down the left edge.
      It sits inside the panel it belongs to — a message that must follow the player is a toast."
  >
    <KitSection label="Tones — soft" layout="column" :gap="12" note="tone drives the fill, the bar and the default glyph">
      <CoreAlert
        v-for="tone in TONES"
        :key="tone"
        style="width: 620px; max-width: 100%"
        :tone="tone"
        :title="COPY[tone][0]"
        :text="COPY[tone][1]"
      />
    </KitSection>

    <KitSection label="Tones — outline" layout="column" :gap="12" note="no tone wash: the frame and the bar over a sunken well">
      <CoreAlert
        v-for="tone in ['warning', 'info', 'success']"
        :key="tone"
        variant="outline"
        style="width: 620px; max-width: 100%"
        :tone="tone"
        :title="COPY[tone][0]"
        :text="COPY[tone][1]"
      />
    </KitSection>

    <KitSection label="With actions" layout="column" :gap="12">
      <CoreAlert tone="danger" title="Impound release" style="width: 620px; max-width: 100%">
        Your Kuruma was towed from Vespucci Boulevard. Release costs $1,250 and the paperwork
        expires at 04:00.
        <template #actions>
          <CoreButton variant="danger" size="sm">Pay $1,250</CoreButton>
          <CoreButton variant="ghost" size="sm">Leave it</CoreButton>
        </template>
      </CoreAlert>
    </KitSection>

    <KitSection label="Dismissible" layout="column" :gap="12" note="the ✕ only emits `dismiss` — the caller owns the visibility">
      <CoreAlert
        v-if="!dismissed"
        tone="info"
        dismissible
        title="New contact"
        text="Lester added a number to your phone. Call him when you are out of the city."
        style="width: 620px; max-width: 100%"
        @dismiss="dismissed = true"
      />
      <CoreButton v-else size="sm" variant="ghost" @click="dismissed = false">Bring it back</CoreButton>
    </KitSection>

    <KitSection label="Shapes" layout="column" :gap="12" note="title only, text only, and a glyph the caller chose">
      <CoreAlert tone="success" title="Objective complete" style="width: 620px; max-width: 100%" />
      <CoreAlert tone="neutral" icon="" text="No blips match the filters you have on." style="width: 620px; max-width: 100%" />
      <CoreAlert
        tone="warning"
        icon="fuel"
        title="Engine damaged"
        text="The radiator is leaking. Get to a mechanic before the temperature gauge tops out."
        style="width: 620px; max-width: 100%"
      />
    </KitSection>
  </KitStage>
</template>
