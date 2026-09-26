<script setup>
// VirtualListGallery — CoreVirtualList (DESIGN §53, §37.5 Data — display): a 10 000-row audit log
// that keeps ~20 rows in the DOM, scrollToIndex driven from a number field, a list with no height
// constraint (every row renders — CoreTree relies on that) and the empty state.
import { computed, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const ACTIONS = ['kicked', 'warned', 'froze', 'teleported to', 'spectated', 'healed', 'banned 1d', 'revived']
const STAFF = ['Ada', 'Travis', 'Mila', 'Dez', 'Reyes']
const TONES = ['warning', 'info', 'neutral', 'accent', 'neutral', 'success', 'danger', 'success']

const log = Array.from({ length: 10000 }, (_, i) => {
  const a = (i * 7) % ACTIONS.length
  const m = String(59 - (i % 60)).padStart(2, '0')
  return {
    id: i + 1,
    time: String(23 - (Math.floor(i / 60) % 24)).padStart(2, '0') + ':' + m,
    who: STAFF[(i * 3) % STAFF.length],
    what: ACTIONS[a],
    target: 'Player #' + (100 + ((i * 13) % 900)),
    tone: TONES[a],
  }
})

const list = ref(null)
const jump = ref(5000)
const range = ref({ start: 0, end: 0 })
const rendered = computed(() => range.value.end - range.value.start)

const LOGBOX = 'height: 340px; border: 1px solid var(--color-border); border-radius: var(--radius-ui);'
  + ' background: var(--color-panel)'
const ROW = 'display: flex; align-items: center; gap: 14px; height: 100%; padding: 0 14px;'
  + ' border-bottom: 1px solid var(--color-border)'

const short = ['Props', 'Vehicles', 'Peds', 'Element types', 'Favourites', 'Recent']
</script>

<template>
  <KitStage
    title="CoreVirtualList"
    description="Fixed-row-height virtualisation. The root is the scroll box; a spacer as tall as every row keeps
      the scrollbar honest and only the rows in view (plus `overscan`) exist, moved by one transform."
    :width="980"
  >
    <KitSection label="10 000 rows — the audit log" layout="column" :gap="12"
                note="Scroll: the DOM keeps about twenty rows. scrollToIndex() jumps; `range` reports the window.">
      <div class="flex items-center gap-3">
        <div style="width: 180px"><CoreNumberInput v-model="jump" :min="0" :max="9999" size="sm" /></div>
        <CoreButton size="sm" @click="list && list.scrollToIndex(jump, 'center')">Scroll to index</CoreButton>
        <span class="text-ui-sm text-fg-faint">window {{ range.start }}–{{ range.end }} · {{ rendered }} rows in the DOM</span>
      </div>
      <div style="width: 100%">
        <CoreVirtualList ref="list" :items="log" :item-height="40" :style="LOGBOX" @range="(r) => (range = r)">
          <template #default="{ item }">
            <div :style="ROW">
              <span class="core-num text-fg-faint" style="width: 60px">#{{ item.id }}</span>
              <span class="text-fg-dim" style="width: 50px">{{ item.time }}</span>
              <span class="text-fg" style="width: 80px">{{ item.who }}</span>
              <CoreTag size="sm" :tone="item.tone" :label="item.what" />
              <span class="text-fg-dim">{{ item.target }}</span>
            </div>
          </template>
        </CoreVirtualList>
      </div>
    </KitSection>

    <KitSection label="No height constraint" layout="column" :gap="12"
                note="Without a max-height the box grows to the spacer and every row renders — a short list pays nothing extra.">
      <div style="width: 320px">
        <CoreVirtualList :items="short" :item-height="34" key-field="">
          <template #default="{ item, index }">
            <div :style="ROW"><span class="core-num text-fg-faint">{{ index + 1 }}</span><span>{{ item }}</span></div>
          </template>
        </CoreVirtualList>
      </div>
    </KitSection>

    <KitSection label="Empty" layout="column" :gap="12" note="`empty` prints a line; the `empty` slot takes a CoreEmpty.">
      <div style="width: 420px; border: 1px solid var(--color-border); border-radius: var(--radius-ui)">
        <CoreVirtualList :items="[]" empty="No audit entries match these filters." />
      </div>
    </KitSection>
  </KitStage>
</template>
