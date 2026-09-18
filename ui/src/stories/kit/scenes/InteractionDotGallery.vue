<script setup>
// InteractionDotGallery — CoreInteractionDot (DESIGN §37.5, Game).
// Shoot this one with ?bg=keyart: the dot is painted ON the world, and both the white core with
// its dark halo and the band's dissolving --color-hud plate can only be judged over a real scene.
// The first 1600 x 900 block is the world itself (one viewport, the dots placed with `x`/`y` at
// plausible points of the key art); everything below it is the spec.
import { onBeforeUnmount, onMounted, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

// The hold-to-interact loop: 0 -> 1 over 2.2 s, a beat at full, then round again. setInterval and
// not rAF on purpose — a gallery must animate the same way in a headless screenshot run.
const hold = ref(0)
let timer = null

onMounted(() => {
  timer = setInterval(() => {
    const next = hold.value + 0.02
    hold.value = next > 1.24 ? 0 : next
  }, 44)
})

onBeforeUnmount(() => {
  if (timer) clearInterval(timer)
  timer = null
})

// The "look at it" demo: the switch is the player's eyes.
const looking = ref(false)

// The dot is a 0 x 0 anchor, so every demo needs a positioned box to be placed in — exactly the
// way a plugin drops it into its own world-to-screen layer.
const worldStyle = { position: 'relative', width: '1600px', height: '900px', overflow: 'hidden' }
const boxStyle = { position: 'relative', width: '360px', height: '120px' }
const cellStyle = { position: 'relative', width: '100%', height: '112px' }
const toneStyle = { position: 'relative', width: '150px', height: '90px' }
const wideStyle = { position: 'relative', width: '620px', height: '160px' }
</script>

<template>
  <div>
    <!-- ---- the world: one 1600 x 900 viewport over the key art ---------------------------- -->
    <div :style="worldStyle">
      <!-- idle, scattered: a hatch on the ledge, a crate on the trail, a fuse box by the pines -->
      <CoreInteractionDot :x="215" :y="604" keys="E" label="Open Hatch" icon="door" />
      <CoreInteractionDot :x="880" :y="556" keys="E" label="Loot Crate" icon="crate" />
      <CoreInteractionDot :x="1062" :y="700" keys="E" label="Cut Power" icon="bolt" tone="warning" />
      <CoreInteractionDot :x="52" :y="150" size="sm" keys="E" label="Climb Tower" icon="tower" />

      <!-- the truck: what the player is looking at, with a second action under the band -->
      <CoreInteractionDot
        :x="1296"
        :y="588"
        focused
        keys="F"
        label="Enter Vehicle"
        icon="steering"
        :options="[{ keys: 'R', label: 'Open Trunk', icon: 'toolbox' }]"
      />

      <!-- near the right edge, so the band has to open the other way -->
      <CoreInteractionDot
        :x="1548"
        :y="404"
        focused
        side="left"
        keys="E"
        label="Open Roof Box"
        icon="crate"
      />

      <!-- locked: an outline cap with the lock glyph, and the reason on the second line -->
      <CoreInteractionDot
        :x="330"
        :y="318"
        focused
        disabled
        keys="E"
        label="Locked"
        icon="door"
        description="The owner has the key."
      />

      <!-- hold-to-interact: CoreKey's bar fills along the bottom of the cap -->
      <CoreInteractionDot
        :x="820"
        :y="790"
        focused
        keys="E"
        label="Hold E · Search"
        icon="backpack"
        :progress="hold > 1 ? 1 : hold"
      />
    </div>

    <!-- ---- the spec: the key art stays, dimmed — the bands are ink 68 % and would simply
             disappear on a black plate ------------------------------------------------------- -->
    <div class="bg-ink/60">
      <KitStage
        title="Interaction Dot"
        description="The world marker that says 'you can interact here'. Idle it is a ring around a
          white core on a world point; the moment the player LOOKS at it the ring collapses and a
          solid key cap takes its place on the SAME point, with the band opening to the side. Place
          it with x/y inside a positioned parent, or drop it where the caller already is. It is a
          HUD element: click-through, no emits."
        :width="1600"
      >
        <KitSection
          label="Look at it"
          note="the anchor never moves — the ring collapses (160 ms) while the cap fades and scales in from 0.7 and the band slides out from behind it"
          layout="row"
          :gap="40"
        >
          <CoreSwitch v-model="looking" label="Player is looking at the marker" />
          <div :style="boxStyle">
            <CoreInteractionDot
              :x="40"
              :y="60"
              :focused="looking"
              keys="E"
              label="Buy Fuel"
              icon="fuel"
              description="$2.40 / litre"
            />
          </div>
        </KitSection>

        <KitSection
          label="Placement"
          note="with both x and y the root is `position: absolute` at that point (what a world-to-screen projection feeds it); with neither it is a 0 x 0 `position: relative` anchor that sits wherever the caller put it"
          layout="row"
          :gap="0"
        >
          <div :style="boxStyle">
            <CoreInteractionDot :x="40" :y="60" focused keys="E" label="x 40 · y 60" icon="map-marker" />
          </div>
          <div style="position: relative; padding: 54px 0 54px 40px">
            <CoreInteractionDot focused keys="E" label="In flow" icon="pin" />
          </div>
        </KitSection>

        <KitSection
          label="Sizes"
          note="dot 10 / 14 / 18 px around a 4 / 6 / 8 px core, cap sm / md / lg, band 30 / 36 / 42 px"
          layout="row"
          :gap="0"
        >
          <div v-for="size in ['sm', 'md', 'lg']" :key="size" :style="boxStyle">
            <CoreInteractionDot :x="40" :y="34" :size="size" keys="E" label="Pick Up" icon="box" />
            <CoreInteractionDot
              :x="40"
              :y="86"
              focused
              :size="size"
              keys="E"
              label="Pick Up"
              icon="box"
            />
          </div>
        </KitSection>

        <KitSection
          label="States"
          note="idle (pulse on) · idle without the pulse · out of reach · locked and looked at · holding · a combination · the same marker focused · the default slot instead of the band's own content"
          layout="grid"
          :columns="4"
          :gap="0"
        >
          <div :style="cellStyle">
            <CoreInteractionDot :x="40" :y="56" keys="E" label="Search" icon="search" />
          </div>
          <div :style="cellStyle">
            <CoreInteractionDot :x="40" :y="56" :pulse="false" keys="E" label="Search" icon="search" />
          </div>
          <div :style="cellStyle">
            <CoreInteractionDot :x="40" :y="56" disabled keys="E" label="Impounded" icon="car" />
          </div>
          <div :style="cellStyle">
            <CoreInteractionDot
              :x="40"
              :y="56"
              focused
              disabled
              keys="E"
              label="Impounded"
              icon="car"
              description="Pay the fine at the depot."
            />
          </div>
          <div :style="cellStyle">
            <CoreInteractionDot
              :x="40"
              :y="56"
              focused
              keys="E"
              label="Hotwire"
              icon="wrench"
              :progress="hold > 1 ? 1 : hold"
            />
          </div>
          <div :style="cellStyle">
            <CoreInteractionDot
              :x="40"
              :y="56"
              focused
              :keys="['SHIFT', 'E']"
              label="Force Door"
              icon="hammer"
            />
          </div>
          <div :style="cellStyle">
            <CoreInteractionDot :x="40" :y="56" focused size="sm" keys="E" label="Pick Lock" icon="key" />
          </div>
          <div :style="cellStyle">
            <CoreInteractionDot :x="40" :y="56" focused keys="E" tone="success">
              <span class="flex items-center" style="gap: 10px">
                <CoreIcon name="ammo" :size="18" />
                <span class="core-interaction-dot__label">Buy Ammo</span>
                <CoreTag tone="success" size="sm">$240</CoreTag>
              </span>
            </CoreInteractionDot>
          </div>
        </KitSection>

        <KitSection
          label="Tones — the attention ring"
          note="`tone` colours the slow `core-ping` ring only; the cap and the band stay the kit's white-on-hud"
          layout="row"
          :gap="0"
        >
          <div v-for="tone in ['accent', 'success', 'warning', 'danger', 'info']" :key="tone" :style="toneStyle">
            <CoreInteractionDot :x="40" :y="46" :tone="tone" keys="E" :label="tone" />
            <p class="core-label" style="position: absolute; left: 0; bottom: 0">{{ tone }}</p>
          </div>
        </KitSection>

        <KitSection
          label="Both sides, with options"
          note="`side` decides which way the band opens — `left` for a dot near the right screen edge; the option rows hang under the band's start and mirror with it"
          layout="row"
          :gap="0"
        >
          <div :style="wideStyle">
            <CoreInteractionDot
              :x="40"
              :y="70"
              focused
              keys="F"
              label="Enter Vehicle"
              icon="steering"
              :options="[
                { keys: 'R', label: 'Open Trunk', icon: 'toolbox' },
                { keys: 'G', label: 'Refuel', icon: 'fuel' },
                { keys: 'H', label: 'Hotwire', icon: 'wrench', disabled: true },
              ]"
            />
          </div>
          <div :style="wideStyle">
            <CoreInteractionDot
              :x="580"
              :y="70"
              focused
              side="left"
              keys="F"
              label="Enter Vehicle"
              icon="steering"
              :options="[{ keys: 'R', label: 'Open Trunk', icon: 'toolbox' }]"
            />
          </div>
        </KitSection>
      </KitStage>
    </div>
  </div>
</template>
