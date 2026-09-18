<script setup>
// CoreDialog gallery (DESIGN §37.5, Feedback) — the four shapes a modal takes in the game: a
// tone-carrying confirm, a wide detail sheet, a persistent one that only its own buttons close,
// and the inline case (`:teleport="false" :backdrop="false"`) so a static screenshot shows the
// panel itself rather than an empty stage. `reason` is printed to prove the `close` payload.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const confirmOpen = ref(false)
const detailOpen = ref(false)
const persistentOpen = ref(false)
const lastReason = ref('—')

const onClose = (reason) => { lastReason.value = reason }

const LOADOUT = [
  ['Carbine Rifle', '120 rounds'],
  ['Heavy Pistol', '48 rounds'],
  ['Micro SMG', '90 rounds'],
  ['Sticky Bomb', '2'],
]
</script>

<template>
  <KitStage
    title="Dialog"
    description="Panel fill, one hairline, 6 px corners and the 2 px fading tone line along the top edge — the
      same surface as the mockups' detail card. Escape, the backdrop and the ✕ all report a reason."
  >
    <KitSection label="Open one" :gap="12" note="Escape closes the innermost popup first; the backdrop click reports `backdrop`">
      <CoreButton variant="danger" icon="car" @click="confirmOpen = true">Sell vehicle…</CoreButton>
      <CoreButton icon="backpack" @click="detailOpen = true">Loadout (lg)</CoreButton>
      <CoreButton variant="ghost" icon="lock" @click="persistentOpen = true">Persistent</CoreButton>
      <span class="core-label" style="margin-left: 8px">last reason — {{ lastReason }}</span>
    </KitSection>

    <KitSection label="Inline — sm" layout="column" note=":teleport=&quot;false&quot; :backdrop=&quot;false&quot; renders the panel in flow">
      <CoreDialog
        :open="true"
        :teleport="false"
        :backdrop="false"
        :closable="false"
        size="sm"
        tone="warning"
        icon="warning"
        title="Leave the crew?"
        subtitle="Del Perro · Rank 3"
      >
        You lose your rank, the shared garage and the crew channel. Rejoining starts you at rank 1.
        <template #footer>
          <CoreButton variant="ghost" size="sm">Stay</CoreButton>
          <CoreButton variant="danger" size="sm">Leave</CoreButton>
        </template>
      </CoreDialog>
    </KitSection>

    <KitSection label="Inline — md, no icon tile" layout="column">
      <CoreDialog
        :open="true"
        :teleport="false"
        :backdrop="false"
        :closable="false"
        title="Repair estimate"
        subtitle="Bennys · Strawberry"
      >
        <p class="core-text" style="margin: 0 0 14px">
          The Sultan needs a radiator, a front axle and a respray. The shop keeps it for six in-game
          hours; call a taxi from the phone if you are in a hurry.
        </p>
        <div class="flex items-center justify-between" style="padding: 10px 0; border-top: 1px solid var(--color-border)">
          <span class="core-label" style="margin: 0">Parts</span>
          <span class="core-num" style="font-size: 17px; color: var(--color-fg)">$1,840</span>
        </div>
        <div class="flex items-center justify-between" style="padding: 10px 0; border-top: 1px solid var(--color-border)">
          <span class="core-label" style="margin: 0">Labour</span>
          <span class="core-num" style="font-size: 17px; color: var(--color-fg)">$620</span>
        </div>
        <template #footer>
          <CoreButton variant="ghost" size="sm">Not now</CoreButton>
          <CoreButton variant="primary" size="sm" fade>Pay $2,460</CoreButton>
        </template>
      </CoreDialog>
    </KitSection>

    <CoreDialog
      v-model:open="confirmOpen"
      size="sm"
      tone="danger"
      icon="warning"
      title="Sell this vehicle?"
      subtitle="Sultan RS · Legion Square"
      @close="onClose"
    >
      The dealer offers <b class="text-fg">$68,400</b>, which is 40 % of what you paid. The upgrades
      do not come back and the plate is released to the pool.
      <template #footer>
        <CoreButton variant="ghost" size="sm" @click="confirmOpen = false">Keep it</CoreButton>
        <CoreButton variant="danger" size="sm" autofocus @click="confirmOpen = false">Sell</CoreButton>
      </template>
    </CoreDialog>

    <CoreDialog v-model:open="detailOpen" size="lg" title="Heist loadout" subtitle="Four players · Pacific Standard" @close="onClose">
      <p class="core-text" style="margin: 0 0 16px">
        Everything below is issued at the staging garage and taken back at the drop-off. Bring your
        own armour — the crate only holds weapons.
      </p>
      <div
        v-for="row in LOADOUT"
        :key="row[0]"
        class="flex items-center justify-between"
        style="padding: 12px 0; border-top: 1px solid var(--color-border)"
      >
        <span class="flex items-center" style="gap: 10px">
          <CoreIcon name="pistol" size="sm" style="color: var(--color-fg-faint)" />
          <span class="core-label" style="margin: 0; color: var(--color-fg)">{{ row[0] }}</span>
        </span>
        <span class="core-num" style="font-size: 17px; color: var(--color-fg-dim)">{{ row[1] }}</span>
      </div>
      <template #footer>
        <CoreButton variant="ghost" size="sm" @click="detailOpen = false">Back</CoreButton>
        <CoreButton variant="primary" size="sm" @click="detailOpen = false">Ready up</CoreButton>
      </template>
    </CoreDialog>

    <CoreDialog
      v-model:open="persistentOpen"
      persistent
      tone="info"
      icon="info"
      title="Read the rules"
      subtitle="Required once per character"
      @close="onClose"
    >
      Escape and the backdrop do nothing here — a persistent dialog only closes through its own
      buttons (or the ✕, which stays alive on purpose).
      <template #footer>
        <CoreButton variant="primary" size="sm" @click="persistentOpen = false">I understand</CoreButton>
      </template>
    </CoreDialog>
  </KitStage>
</template>
