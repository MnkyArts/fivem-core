<script setup>
// CardGallery — CoreCard in both shapes and every state (DESIGN §37.5, Surfaces).
// The first section is the LAST PLAYED card of mockup 1 at its real size, so the crop and the
// component can be put side by side; the second is the media-top quest card of mockup 4.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'
import lastplayed from '../assets/lastplayed.jpg'
import questHero from '../assets/quest-hero.jpg'
import quest1 from '../assets/quest-1.jpg'
import quest2 from '../assets/quest-2.jpg'
import quest3 from '../assets/quest-3.jpg'
import medkit from '../assets/item-medkit.jpg'

const VARIANTS = [
  ['default', 'The panel fill, a hairline and the deep shadow.'],
  ['flat', 'White 2 %, no shadow — a card inside a panel (shown selected).'],
  ['ghost', 'No fill, no border: the copy sits flush on the panel.'],
]

const QUESTS = [
  { title: 'A Brighter Tomorrow', kind: 'Main Story', icon: 'warning', image: quest1, away: '842 m', selected: true },
  { title: 'Supply Lines', kind: 'Side Quest', icon: 'map-marker', image: quest2, away: '2.4 km', selected: false },
  { title: 'Echoes in the Hills', kind: 'Side Quest', icon: 'diamond-outline', image: quest3, away: '3.1 km', selected: false },
]
</script>

<template>
  <KitStage
    title="CoreCard"
    :width="1180"
    description="Media plus text. left insets the picture inside the card's 14 px padding with a 4 px radius;
      top lets it bleed to the top edge, dissolve into the card colour and carry the title up over the fade.
      Selection is a coral edge and a glow, never a filled block."
  >
    <KitSection label="Mockup 1 — LAST PLAYED" layout="column" :gap="14"
      note="eyebrow + display title + icon subtitle + a meta row under a hairline.">
      <CoreCard
        style="width: 546px"
        :image="lastplayed"
        :media-width="182"
        :media-height="152"
        eyebrow="Last played"
        title="A Brighter Tomorrow"
        subtitle="Northern Ridge"
        icon="map-marker"
      >
        <template #meta>
          <span><b>72%</b> Complete</span>
          <span>Mar 12, 2024&nbsp;&nbsp;18:24</span>
        </template>
      </CoreCard>
    </KitSection>

    <KitSection label="Mockup 4 — media top" layout="grid" :columns="3" :gap="20"
      note="uppercase=false keeps a quest name in mixed case; the picture fades into the card.">
      <CoreCard
        image-position="top"
        :image="questHero"
        :media-height="150"
        title="A Brighter Tomorrow"
        :uppercase="false"
        subtitle="Main Story"
        icon="warning"
      >
        <p class="core-text">
          Meet the contact at the old tower outside Solace City. They may have information about the next phase.
        </p>
        <template #meta>
          <span>Meet the contact at the old tower</span>
          <span class="core-num">842 m</span>
        </template>
      </CoreCard>

      <CoreCard
        image-position="top"
        :image="medkit"
        :media-height="150"
        eyebrow="Consumable"
        title="Med Kit"
        subtitle="Restores 75 health"
        icon="medkit"
      >
        <template #meta>
          <span><b>3</b> in inventory</span>
          <span class="core-num">0.5 kg</span>
        </template>
      </CoreCard>

      <CoreCard
        image-position="top"
        :image="quest2"
        :media-height="150"
        title="Supply Lines"
        :uppercase="false"
        subtitle="Side Quest"
        icon="map-marker"
        interactive
      >
        <p class="core-text">Run three crates of parts up to the Sandy Shores depot before the shift ends.</p>
      </CoreCard>
    </KitSection>

    <KitSection label="Variants" layout="column" :gap="0"
      note="Inside a panel a card must not stack a second shadowed surface on the first: flat is white 2 % with
        no shadow, ghost has no fill and no border at all (the quest brief of mockup 4). Selection and hover
        still read on all three.">
      <CorePanel title="Contracts" heading-size="sm" padding="lg" style="width: 640px">
        <div class="flex flex-col" style="gap: 12px">
          <CoreCard
            v-for="[variant, note] in VARIANTS"
            :key="variant"
            :variant="variant"
            :title="variant"
            :uppercase="false"
            :subtitle="note"
            icon="quest"
            interactive
            :selected="variant === 'flat'"
          >
            <template #trailing><span class="core-label">variant</span></template>
          </CoreCard>
        </div>
      </CorePanel>
    </KitSection>

    <KitSection label="States" layout="column" :gap="12"
      note="hover lifts the hairline to border-strong · selected is accent-hi + shadow-glow-sm · disabled is 0.45 and no hover.">
      <CoreCard
        v-for="quest in QUESTS"
        :key="quest.title"
        style="width: 520px"
        :image="quest.image"
        :media-width="108"
        :media-height="76"
        :title="quest.title"
        :uppercase="false"
        :subtitle="quest.kind"
        :icon="quest.icon"
        :selected="quest.selected"
        interactive
      >
        <template #trailing>
          <span class="core-num text-ui-sm">{{ quest.away }}</span>
        </template>
      </CoreCard>

      <CoreCard
        style="width: 520px"
        :image="quest3"
        :media-width="108"
        :media-height="76"
        title="Old Friends"
        :uppercase="false"
        subtitle="Completed"
        icon="check-circle"
        interactive
        disabled
      >
        <template #trailing>
          <span class="core-label">Done</span>
        </template>
      </CoreCard>
    </KitSection>

    <KitSection label="Without a picture" layout="grid" :columns="3" :gap="20"
      note="No image and no media slot: the card is a titled block with a meta row.">
      <CoreCard eyebrow="Faction" title="Northside MC" subtitle="14 members online" icon="users">
        <template #meta>
          <span>Rank <b>Enforcer</b></span>
          <span class="core-num">$18,420</span>
        </template>
      </CoreCard>
      <CoreCard title="Garage" subtitle="Impound — Mission Row" icon="garage" interactive>
        <p class="core-text">Sultan RS · plate 12ADM940 · released 4 h ago.</p>
      </CoreCard>
      <CoreCard eyebrow="Shop" title="Ammu-Nation" subtitle="Open until 02:00" icon="store" selected>
        <template #meta>
          <span><b>6</b> items in stock</span>
          <span>Pillbox Hill</span>
        </template>
      </CoreCard>
    </KitSection>
  </KitStage>
</template>
