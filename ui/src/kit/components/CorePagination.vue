<script setup>
// CorePagination — page / cursor controls (DESIGN §53, §37.5 Navigation).
// Two modes from one bar. With a known `pageCount` it prints numbered pages (first, last, the
// current one with `siblings` either side, `…` for the gaps). Without one it is a CURSOR pager —
// `‹ PAGE 3 ›` — whose arrows follow `hasPrev` / `hasNext`, because a keyset-paginated server
// cannot say how many pages there are. `page` is 1-based (`v-model:page`); `pageSize` is
// `v-model:pageSize` with an inline CoreSelect when `pageSizes` is not empty. The bar never
// fetches anything: every move is `update:page` (+ `change`), the caller loads.
import { computed } from 'vue'
import { oneOf, SIZES } from '../use.js'

const props = defineProps({
  /** Total pages; `null` = unknown (cursor mode). */
  pageCount: { type: Number, default: null },
  /** Next exists. `null` = derive from `pageCount`. */
  hasNext: { type: Boolean, default: null },
  /** Previous exists. `null` = `page > 1`. */
  hasPrev: { type: Boolean, default: null },
  /** Total rows, for the `1–25 of 312` read-out; `null` hides it. */
  total: { type: Number, default: null },
  /** The page-size choices; `[]` hides the select. */
  pageSizes: { type: Array, default: () => [25, 50, 100] },
  /** Caption of the size select. */
  sizeLabel: { type: String, default: 'Rows:' },
  /** Numbered pages shown either side of the current one. */
  siblings: { type: Number, default: 1 },
  size: { type: String, default: 'md', validator: oneOf(SIZES) },
  disabled: { type: Boolean, default: false },
})

const emit = defineEmits(['change'])
const page = defineModel('page', { type: Number, default: 1 })
const pageSize = defineModel('pageSize', { type: Number, default: 25 })

const known = computed(() => Number.isFinite(props.pageCount) && props.pageCount >= 0)
const current = computed(() => Math.max(1, Math.floor(Number(page.value) || 1)))
const canPrev = computed(() => !props.disabled && (props.hasPrev === null ? current.value > 1 : props.hasPrev))
const canNext = computed(() => !props.disabled && (props.hasNext !== null
  ? props.hasNext
  : known.value && current.value < props.pageCount))

/** `[1, '…', 4, 5, 6, '…', 20]` — the gap marker is a string so it can never be clicked into. */
const items = computed(() => {
  if (!known.value) return []
  const last = Math.max(1, props.pageCount)
  const sib = Math.max(0, Math.floor(props.siblings))
  const lo = Math.max(2, current.value - sib)
  const hi = Math.min(last - 1, current.value + sib)
  const out = [1]
  // A gap that would hide exactly one page shows that page instead (`1 2 3 4 5`, not `1 … 3 4 5`).
  if (lo > 3) out.push('gap-lo')
  else if (lo === 3) out.push(2)
  for (let p = lo; p <= hi; p += 1) out.push(p)
  if (hi < last - 2) out.push('gap-hi')
  else if (hi === last - 2) out.push(last - 1)
  if (last > 1) out.push(last)
  return out
})

const rangeText = computed(() => {
  if (!Number.isFinite(props.total)) return ''
  if (props.total <= 0) return '0 of 0'
  const from = (current.value - 1) * pageSize.value + 1
  const to = Math.min(props.total, current.value * pageSize.value)
  return from.toLocaleString('en-US') + '–' + to.toLocaleString('en-US') + ' of ' + props.total.toLocaleString('en-US')
})

const sizeItems = computed(() => props.pageSizes.map((n) => ({ value: Number(n), label: String(n) })))

function go (p) {
  if (props.disabled) return
  const next = known.value ? Math.min(Math.max(1, p), Math.max(1, props.pageCount)) : Math.max(1, p)
  if (next === current.value) return
  page.value = next
  emit('change', { page: next, pageSize: pageSize.value })
}

function prev () { if (canPrev.value) go(current.value - 1) }
function next () { if (canNext.value) go(current.value + 1) }

function setSize (n) {
  if (props.disabled || n === pageSize.value) return
  pageSize.value = n
  page.value = 1
  emit('change', { page: 1, pageSize: n })
}
</script>

<template>
  <nav
    class="core-pagination"
    :class="['core-pagination--' + size, { 'is-disabled': disabled, 'is-cursor': !known }]"
    aria-label="Pagination"
  >
    <span v-if="rangeText" class="core-pagination__range">{{ rangeText }}</span>

    <div class="core-pagination__pages">
      <button type="button" class="core-pagination__btn core-pagination__btn--prev" aria-label="Previous page" :disabled="!canPrev" @click="prev">
        <CoreIcon name="chevron-left" size="sm" />
      </button>
      <template v-if="known">
        <template v-for="item in items" :key="item">
          <span v-if="typeof item === 'string'" class="core-pagination__gap" aria-hidden="true">…</span>
          <button
            v-else
            type="button"
            class="core-pagination__btn core-pagination__page"
            :class="{ 'is-active': item === current }"
            :aria-current="item === current ? 'page' : undefined"
            :disabled="disabled"
            @click="go(item)"
          >{{ item }}</button>
        </template>
      </template>
      <span v-else class="core-pagination__current" aria-live="polite">Page {{ current }}</span>
      <button type="button" class="core-pagination__btn core-pagination__btn--next" aria-label="Next page" :disabled="!canNext" @click="next">
        <CoreIcon name="chevron-right" size="sm" />
      </button>
    </div>

    <CoreSelect
      v-if="sizeItems.length"
      class="core-pagination__size"
      variant="inline"
      size="sm"
      placement="auto"
      :label="sizeLabel"
      :items="sizeItems"
      :model-value="pageSize"
      :disabled="disabled"
      @update:model-value="setSize"
    />
  </nav>
</template>
