<script setup>
// EmptyGallery — CoreEmpty (DESIGN §37.5, Data — display): the placeholder a list shows instead of
// nothing at all, with and without the actions slot, on its own and inside a panel.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const CASES = [
  {
    icon: 'backpack',
    title: 'Nothing on you',
    text: 'Pick something up, or open a stash and drag it across. Your last three drops are still on the ground near Sandy Shores.',
  },
  {
    icon: 'quest',
    title: 'No active contracts',
    text: 'Talk to a fixer at the docks or wait for the next faction call — new contracts post every 20 minutes.',
  },
  {
    icon: 'search',
    title: 'No match',
    text: 'Nothing in this stash is called that. Clear the filter or try a shorter name.',
  },
]
</script>

<template>
  <KitStage
    title="CoreEmpty"
    description="A list with nothing in it still has to say something. Framed glyph, one display-voice
      line, one sentence of what to do next — and the default slot for the button that does it. It is
      the `empty` slot of CoreTable and the body of an empty CoreSlotGrid."
  >
    <KitSection label="The three shapes" layout="grid" :columns="3" :gap="18" note="Icon + title + text; any of the three may be left out.">
      <div
        v-for="c in CASES"
        :key="c.title"
        style="align-self: stretch; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)"
      >
        <CoreEmpty :icon="c.icon" :title="c.title" :text="c.text" />
      </div>
    </KitSection>

    <KitSection label="With actions" layout="column" :gap="0" note="The default slot is the actions row and takes the mouse back. A page puts CoreButtons here; this gallery stands in with tags because a scene only uses its own group's components.">
      <div style="width: 520px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)">
        <CoreEmpty
          icon="garage"
          title="Garage empty"
          text="Buy a vehicle at Premium Deluxe Motorsport, or ask a faction lead to transfer one to you."
        >
          <CoreTag size="lg" variant="solid" tone="accent" icon="cart" label="Open the dealership" />
          <CoreTag size="lg" variant="outline" tone="neutral" icon="users" label="Ask the faction" />
        </CoreEmpty>
      </div>
    </KitSection>

    <KitSection label="Minimal" :gap="20" note="Title only, or text only — a compact placeholder inside a narrow column.">
      <div style="width: 300px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)">
        <CoreEmpty title="No messages" />
      </div>
      <div style="width: 300px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)">
        <CoreEmpty text="This faction has no bank history yet." />
      </div>
      <div style="width: 300px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)">
        <CoreEmpty icon="signal" text="Waiting for the server to answer." />
      </div>
    </KitSection>

    <KitSection label="Bare, over the game" layout="column" :gap="0" note="Without a panel it is just the column — that is how a page drops it into an existing surface.">
      <CoreEmpty
        icon="map-marker"
        title="Nothing tracked"
        text="Pick a quest on the left and it will show up here, with the route and the distance to the next objective."
      />
    </KitSection>
  </KitStage>
</template>
