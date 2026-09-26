<script setup>
// PaginationGallery — CorePagination (DESIGN §53, §37.5 Navigation): a numbered pager with a total
// and the size select under a table, a cursor pager (no pageCount — the server's keyset paging),
// the short and the long page runs, every size, disabled.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const page = ref(4)
const size = ref(25)
const cursorPage = ref(3)
const hasMore = ref(true)
const few = ref(2)
const many = ref(48)
const sizes = ['sm', 'md', 'lg']
const sized = ref(5)
const log = ref('—')
const BAR = 'width: 100%; padding: 12px 16px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)'
</script>

<template>
  <KitStage
    title="CorePagination"
    description="Page or cursor controls. With a `pageCount` it numbers the pages (first, last, the current one with
      `siblings` either side, … for the gaps); without one it is a cursor pager whose arrows follow `hasPrev` /
      `hasNext`. It never fetches: every move is `update:page` plus one `change`, and the caller loads."
    :width="1000"
  >
    <KitSection label="Numbered — total + size select" layout="column" :gap="10"
                note="312 players, 25 per page. Changing the size goes back to page 1.">
      <div :style="BAR">
        <CorePagination
          v-model:page="page"
          v-model:page-size="size"
          :page-count="Math.ceil(312 / size)"
          :total="312"
          @change="(c) => (log = JSON.stringify(c))"
        />
      </div>
      <p class="text-ui-sm text-fg-faint" style="margin: 0">change: <b class="text-fg">{{ log }}</b></p>
    </KitSection>

    <KitSection label="Cursor — no page count" layout="column" :gap="10"
                note="The audit log pages by cursor: the server says hasNext, nobody knows the last page.">
      <div :style="BAR" class="flex items-center gap-4">
        <CorePagination v-model:page="cursorPage" :has-next="hasMore" :page-sizes="[]" />
        <CoreSwitch v-model="hasMore" label="Server has more" />
      </div>
    </KitSection>

    <KitSection label="Short and long runs" layout="column" :gap="10">
      <div :style="BAR"><CorePagination v-model:page="few" :page-count="3" :page-sizes="[]" /></div>
      <div :style="BAR"><CorePagination v-model:page="many" :page-count="120" :siblings="2" :page-sizes="[]" /></div>
    </KitSection>

    <KitSection label="Sizes · disabled" layout="column" :gap="10">
      <div v-for="s in sizes" :key="s" :style="BAR"><CorePagination v-model:page="sized" :page-count="12" :size="s" :total="287" :page-sizes="[10, 25]" :page-size="25" /></div>
      <div :style="BAR"><CorePagination :page="2" :page-count="9" disabled /></div>
    </KitSection>
  </KitStage>
</template>
