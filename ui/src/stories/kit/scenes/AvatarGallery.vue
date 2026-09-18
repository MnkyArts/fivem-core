<script setup>
// AvatarGallery — CoreAvatar and CorePlayerChip (DESIGN §37.5, Data — display).
// The last section rebuilds mockup 1's top-right chip 1:1; open it with `&bg=keyart` to judge the
// panel against the same sky the mockup uses.
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'
import avatar from '../assets/avatar.jpg'

const SIZES = [
  ['sm', 28, 'a table cell, a chat line'],
  ['md', 40, 'the default — a roster row'],
  ['lg', 56, 'a player card'],
  ['xl', 76, 'the profile header'],
]

const STATUSES = [
  ['online', 'in the session'],
  ['away', 'idle over a minute'],
  ['busy', 'in a job, do not invite'],
  ['offline', 'last seen 3 h ago'],
]

const CREW = [
  { name: 'Travis Kane', src: avatar, status: 'online', rank: 'Lead' },
  { name: 'Mila Ortega', src: '', status: 'busy', rank: 'Enforcer' },
  { name: 'Dez', src: '', status: 'away', rank: 'Runner' },
  { name: 'Ana Reyes Vidal', src: '', status: 'offline', rank: 'Recruit' },
]
</script>

<template>
  <KitStage
    title="CoreAvatar · CorePlayerChip"
    description="A portrait with somewhere to fall back to, and the chip mockup 1 hangs in the top
      right of the main menu. Both size themselves in px, so they fit a 28 px chat line and a 76 px
      profile header without a second component."
  >
    <KitSection label="Sizes" :gap="26" note="sm 28 · md 40 · lg 56 · xl 76, or any number of px.">
      <div v-for="[size, px, use] in SIZES" :key="size" style="display: flex; flex-direction: column; align-items: center; gap: 10px; width: 150px">
        <CoreAvatar :src="avatar" name="Travis Kane" :size="size" />
        <span class="text-ui-sm">{{ size }} · {{ px }}</span>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">{{ use }}</span>
      </div>
      <div style="display: flex; flex-direction: column; align-items: center; gap: 10px; width: 150px">
        <CoreAvatar :src="avatar" name="Travis Kane" :size="96" />
        <span class="text-ui-sm">:size="96"</span>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">any number of px</span>
      </div>
    </KitSection>

    <KitSection label="Shape, initials, ring" :gap="26" note="No src — or a url that 404s — falls back to the first letters of up to two words.">
      <div style="display: flex; flex-direction: column; align-items: center; gap: 10px; width: 160px">
        <CoreAvatar :src="avatar" name="Travis Kane" size="lg" shape="circle" />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">shape="circle"</span>
      </div>
      <div style="display: flex; flex-direction: column; align-items: center; gap: 10px; width: 160px">
        <CoreAvatar name="Mila Ortega" size="lg" />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">initials — white 8 % plate</span>
      </div>
      <div style="display: flex; flex-direction: column; align-items: center; gap: 10px; width: 160px">
        <CoreAvatar name="Dez" size="lg" shape="circle" />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">one word, one letter</span>
      </div>
      <div style="display: flex; flex-direction: column; align-items: center; gap: 10px; width: 160px">
        <CoreAvatar src="/does-not-exist.jpg" name="Ana Reyes" size="lg" />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">broken url — same fallback</span>
      </div>
      <div style="display: flex; flex-direction: column; align-items: center; gap: 10px; width: 160px">
        <CoreAvatar :src="avatar" name="Travis Kane" size="lg" ring />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">ring — 2 px accent-hi, 2 px gap</span>
      </div>
      <div style="display: flex; flex-direction: column; align-items: center; gap: 10px; width: 160px">
        <CoreAvatar :src="avatar" name="Travis Kane" size="lg" shape="circle" ring status="online" />
        <span class="text-ui-xs text-fg-faint" style="text-align: center">ring + status</span>
      </div>
    </KitSection>

    <KitSection label="Presence" :gap="26" note="The dot carries a 2 px ink ring so it stays readable on a portrait of any colour.">
      <div v-for="[status, caption] in STATUSES" :key="status" style="display: flex; flex-direction: column; align-items: center; gap: 10px; width: 170px">
        <CoreAvatar :src="avatar" name="Travis Kane" size="lg" :status="status" />
        <span class="text-ui-sm">{{ status }}</span>
        <span class="text-ui-xs text-fg-faint" style="text-align: center">{{ caption }}</span>
      </div>
    </KitSection>

    <KitSection label="In a roster row" layout="column" :gap="0" note="sm / md next to a name is where an avatar spends most of its life.">
      <div
        v-for="member in CREW"
        :key="member.name"
        style="display: flex; align-items: center; gap: 14px; width: 420px; padding: 10px 4px; border-bottom: 1px solid var(--color-border)"
      >
        <CoreAvatar :src="member.src" :name="member.name" size="md" :status="member.status" />
        <span class="text-ui" style="flex: 1 1 auto; min-width: 0">{{ member.name }}</span>
        <CoreTag size="sm" :label="member.rank" tone="neutral" />
      </div>
    </KitSection>

    <KitSection label="CorePlayerChip — mockup 1" layout="column" :gap="18" note="74 px, portrait flush left, name + presence, then `Lv.` and the 4 px coral XP rail.">
      <CorePlayerChip name="Travis" :avatar="avatar" :level="32" :progress="0.56" status="online" />
      <CorePlayerChip name="Mila Ortega" :level="7" :progress="0.18" status="busy" />
      <CorePlayerChip name="Dez" :avatar="avatar" :level="99" :progress="1" status="away" subtitle="Grove Mechanics · Shift ends 21:00" />
      <CorePlayerChip name="Ana Reyes Vidal Santos" :level="1" :progress="0.04" status="offline" subtitle="Last seen 3 hours ago" />
    </KitSection>

    <KitSection label="CorePlayerChip — the slots" layout="column" :gap="18" note="`meta` replaces the level + XP row; `avatar` replaces the portrait.">
      <CorePlayerChip name="Travis" :avatar="avatar" status="online">
        <template #meta>
          <CoreTag size="sm" variant="solid" tone="danger" icon="police" label="Wanted 3" />
          <CoreTag size="sm" tone="warning" label="$ 2,400 bounty" />
        </template>
      </CorePlayerChip>
      <CorePlayerChip name="Dispatch" :level="3" levelLabel="Ch." :progress="0.33" status="online" subtitle="Los Santos · night shift">
        <template #avatar>
          <CoreIcon name="radio" :size="30" class="text-fg-dim" />
        </template>
      </CorePlayerChip>
    </KitSection>
  </KitStage>
</template>
