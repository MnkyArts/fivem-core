<script setup>
// CoreShard gallery (DESIGN §37.5, Feedback; the skin of the shell's Shard, §37.6).
// The three styles, the title-only shape and what a long line does — stacked, because the band is
// full-bleed and the one thing worth proving here is that three of them can share a page: the
// component has no position of its own, the caller places it (the shell hangs it at 24vh, z 45).
//
// The wire field of `shard:show` is `style`; the prop is `variant`, because Vue parses anything
// called `style` as CSS as soon as props are merged (see CoreShard.vue).
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const STYLES = [
  { variant: 'wasted', title: 'Wasted', subtitle: 'You lost $500' },
  { variant: 'success', title: 'Mission passed', subtitle: 'Respect + $1,250' },
  { variant: 'info', title: 'Wanted level increased', subtitle: 'Lose the cops to stay free' },
]
</script>

<template>
  <KitStage
    title="Shard"
    description="The centre-screen banner of the base game: a full-bleed band that fades out towards both
      screen edges, a tinted hairline top and bottom, the title in the display voice over an eyebrow-voice
      line. The style is a tone — wasted is danger, info is the accent — and the band never takes the mouse."
  >
    <KitSection label="Styles" layout="column" :gap="28" note="wasted · success · info (the default)">
      <CoreShard
        v-for="s in STYLES"
        :key="s.variant"
        :variant="s.variant"
        :title="s.title"
        :subtitle="s.subtitle"
      />
    </KitSection>

    <KitSection label="Title only" layout="column" :gap="28" note="`subtitle` is optional — the band keeps its proportions">
      <CoreShard variant="wasted" title="Busted" />
    </KitSection>

    <KitSection label="Long copy" layout="column" :gap="28" note="the title wraps inside 86 vw, the subtitle inside 72 vw">
      <CoreShard
        variant="success"
        title="The Paleto Bay score is in the bag"
        subtitle="Everyone made it out — split the take at the lock-up before the heat comes down"
      />
    </KitSection>
  </KitStage>
</template>
