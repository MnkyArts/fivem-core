<script setup>
// PromptGallery — CorePrompt and CorePromptGroup over the game (open this scene with `bg=keyart`).
// Shows the mockup's two prompts, the description line, a hold that really runs, the lit and dead
// states, and the one prompt that takes the mouse — everything else stays click-through.
import { onBeforeUnmount, onMounted, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const hold = ref(0)
const opened = ref(0)
const focusMe = ref(null)
let raf = 0
let start = 0

function tick (now) {
  if (!start) start = now
  hold.value = Math.min(((now - start) % 2400) / 1800, 1)
  raf = window.requestAnimationFrame(tick)
}

onMounted(() => {
  raf = window.requestAnimationFrame(tick)
  // The focus ring of an interactive prompt, without anyone pressing Tab (:focus-visible is
  // keyboard-only). preventScroll keeps the gallery at the top for a screenshot.
  const el = focusMe.value && (focusMe.value.$el || focusMe.value)
  if (el && typeof el.focus === 'function') el.focus({ preventScroll: true })
})
onBeforeUnmount(() => { if (raf) window.cancelAnimationFrame(raf) })

// The stack a car offers when the player walks up to it.
const VEHICLE = [
  { keys: 'F', label: 'Enter vehicle', icon: 'steering' },
  { keys: 'R', label: 'Open trunk', icon: 'toolbox' },
  { keys: ['SHIFT', 'F'], label: 'Enter as passenger', icon: 'users' },
  { keys: 'H', label: 'Hotwire', icon: 'wrench', description: 'Needs a screwdriver and 30 seconds.', disabled: true },
]
</script>

<template>
  <KitStage
    title="CorePrompt"
    description="The world interaction prompt: a solid cap, then a plate that is opaque under the label and
      gone by its right edge, so the line sits on the game instead of in a box. Click-through by default —
      it is a HUD element, and the keyboard is what answers it."
  >
    <KitSection label="From the mockup" layout="column" :gap="10" note="mockup 2 — the car the player is standing at.">
      <CorePrompt keys="F" icon="steering" label="Enter vehicle" />
      <CorePrompt keys="R" icon="toolbox" label="Open trunk" />
    </KitSection>

    <KitSection label="States" layout="column" :gap="10">
      <CorePrompt keys="E" icon="door" label="Open door" />
      <CorePrompt keys="E" icon="door" label="Open door" active />
      <CorePrompt keys="E" icon="lock" label="Locked" description="The owner has the key." disabled />
      <CorePrompt keys="E" icon="medkit" label="Revive" description="Hold to stabilise — 8 seconds." :progress="hold" />
      <CorePrompt keys="E" icon="medkit" label="Revive" :progress="0.62" active />
    </KitSection>

    <KitSection label="Without an icon · combinations · rich label" layout="column" :gap="10">
      <CorePrompt keys="F" label="Pick up" />
      <CorePrompt :keys="['SHIFT', 'F']" icon="users" label="Enter as passenger" />
      <CorePrompt keys="mouse-right" icon="binoculars" label="Look through" />
      <CorePrompt keys="Y" icon="cash">
        Buy <b style="color: var(--color-accent)">jerry can</b> · $45
      </CorePrompt>
    </KitSection>

    <KitSection label="Interactive" layout="column" :gap="10"
                note="interactive turns the mouse on and makes the root a real button — the rest stay click-through.">
      <CorePrompt
        ref="focusMe"
        keys="R"
        icon="toolbox"
        label="Open trunk"
        interactive
        data-role="trunk"
        @click="opened += 1"
      />
      <CorePrompt keys="H" icon="wrench" label="Hotwire" interactive disabled data-role="dead" @click="opened += 1" />
      <span class="core-num text-fg-dim" data-role="count" style="font-size: 17px">opened {{ opened }}x</span>
    </KitSection>

    <KitSection label="CorePromptGroup" layout="column" :gap="20" note="column, gap 8 — one interaction point, every option.">
      <CorePromptGroup :items="VEHICLE" />
      <CorePromptGroup :items="VEHICLE.slice(0, 2)" align="end" style="width: 620px" />
    </KitSection>
  </KitStage>
</template>
