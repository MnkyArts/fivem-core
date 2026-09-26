<script setup>
// Plugin page host (DESIGN §38.6, §38.9). Three layers, one boundary per instance:
//   overlays (z 10)  click-through, any number, never focusable
//   the page (z 20)  exclusive, takes the mouse
//   modals   (z 30)  stacked in open order above the page; everything below the top one is `inert`
//
// §38 removed the <script>/<link> injection that used to live here: a plugin's module and its
// stylesheet are loaded by `runtime/plugins.ts` from the plugin's OWN resource origin, and a page
// component is resolved through its owner. Escape -> ui_close stays central (store.handleKeydown).
//
// Every instance is keyed `<id>:<epoch>`: `epoch` is bumped by the `page:open` that follows a crash,
// which is what makes "the next page:open remounts it" (§38.12) true for an overlay too.
//
// §41: a page or modal in `game` input mode holds no focus, so its layer lets every click through —
// the layer itself (inline style) and everything inside it, kit buttons included (an important
// descendant utility beats the kit's components layer and a plugin's own rules).
//
// §54: while `Core.UI.hideHud` holds a reason, an overlay whose owner holds none is hidden with
// `v-show` on a `display: contents` wrapper — never closed, never unmounted, so the hotbar of the
// inventory comes back exactly as it was when the editor that hid it lets go.
import { computed, ref, watch } from 'vue'
import PluginBoundary from './PluginBoundary.vue'
import { store } from '../store.js'
import { isInert, overlayHidden, topModalId } from '../runtime/layers.ts'
import { keepAliveEpoch } from '../runtime/pages.ts'

const openPage = computed(() => (store.openPage ? store.pages[store.openPage] : null) || null)
const openProps = computed(() => (openPage.value && openPage.value.props) || {})
const keyOf = (page) => page.id + ':' + page.epoch

// The page layer has two shapes. A normal page is mounted and unmounted with its open state; a
// `keepAlive` page lives in a <KeepAlive> that OUTLIVES the close, so re-opening it deactivates and
// re-activates one instance instead of building a new one. Only the exclusive page layer honours
// the flag — an overlay is cheap and a modal is meant to be fresh.
const livePage = computed(() => {
  const page = openPage.value
  return page && page.component && !page.keepAlive ? page : null
})
const cachedPage = computed(() => {
  const page = openPage.value
  return page && page.component && page.keepAlive ? page : null
})

// `cachedHeld` is the LAST keep-alive page — the one whose instance sits in the cache. Everything
// inside the cached branch reads it instead of `cachedPage`, because a scoped slot may be
// re-evaluated while the page is already closed (Vue re-renders the child on a parent update), and
// a slot that dereferences a null record would throw straight into this page's own error boundary
// and tear the cached instance down. `cachedPage` is left to say only "is it showing right now".
const cachedHeld = ref(null)
watch(cachedPage, (page) => { if (page) cachedHeld.value = page }, { immediate: true })

// The cache must not outlive the module that created its instances: `keepAliveEpoch` is bumped
// whenever a plugin activation goes away, and dropping the container drops the whole <KeepAlive>.
const cacheArmed = computed(() => !!cachedHeld.value)
watch(keepAliveEpoch, () => { cachedHeld.value = null })

const overlays = computed(() => {
  const out = []
  for (const id of Object.keys(store.overlays)) {
    const page = store.pages[id]
    if (page && page.component) out.push(page)
  }
  return out
})

const modals = computed(() => {
  const out = []
  for (const id of store.modals) {
    const page = store.pages[id]
    if (page && page.component) out.push(page)
  }
  return out
})

// `inert` (Chromium 102+) is what stops Tab from walking out of a modal into the page behind it.
const pageInert = computed(() => (topModalId() ? true : null))
const modalInert = (id) => (isInert('modal', id) ? true : null)

// §41: `data-core-input` names the mode for tests and the inspector; only `game` changes anything.
const GAME_LAYER = '[&_*]:pointer-events-none!'
const isGame = (page) => !!page && page.input === 'game'
const inputClass = (page) => (isGame(page) ? GAME_LAYER : null)
const inputStyle = (page) => (isGame(page) ? { pointerEvents: 'none' } : null)
const modalStyle = (m, i) => (isGame(m) ? { zIndex: 30 + i, pointerEvents: 'none' } : { zIndex: 30 + i })
</script>

<template>
  <div class="page-host pointer-events-none fixed inset-0">
    <!-- overlays: click-through layer under the open page (z 10); §54 hides the ones whose owner
         holds no hideHud reason (`display: contents`, so an overlay's own layout is untouched) -->
    <div class="overlay-layer pointer-events-none absolute inset-0 z-10">
      <div
        v-for="o in overlays"
        v-show="!overlayHidden(o.owner)"
        :key="keyOf(o)"
        class="contents"
        :data-core-overlay="o.id"
      >
        <PluginBoundary :plugin="o.owner" :page="o.id">
          <component :is="o.component" :props="o.props" />
        </PluginBoundary>
      </div>
    </div>

    <!-- the open page: the shell layer that takes the mouse (z 20) -->
    <div
      v-if="livePage"
      class="page-layer pointer-events-auto absolute inset-0 z-20 overflow-hidden"
      :class="inputClass(livePage)"
      :style="inputStyle(livePage)"
      :data-core-input="livePage.input"
      :inert="pageInert"
    >
      <PluginBoundary :key="keyOf(livePage)" :plugin="livePage.owner" :page="livePage.id" focus-holder>
        <component :is="livePage.component" :props="openProps" />
      </PluginBoundary>
    </div>

    <!-- the same layer for a `keepAlive` page: the container stays mounted while the page is
         closed so the cached instance survives, and is hidden rather than removed -->
    <div
      v-if="cacheArmed"
      v-show="cachedPage"
      class="page-layer pointer-events-auto absolute inset-0 z-20 overflow-hidden"
      :class="inputClass(cachedHeld)"
      :style="inputStyle(cachedHeld)"
      :data-core-input="cachedHeld.input"
      :inert="pageInert"
    >
      <KeepAlive :max="3">
        <PluginBoundary
          v-if="cachedPage && cachedHeld"
          :key="keyOf(cachedHeld)"
          :plugin="cachedHeld.owner"
          :page="cachedHeld.id"
          focus-holder
        >
          <component :is="cachedHeld.component" :props="cachedHeld.props" />
        </PluginBoundary>
      </KeepAlive>
    </div>

    <!-- plugin modals: stacked in open order above the page (z 30 + index) -->
    <div
      v-for="(m, i) in modals"
      :key="keyOf(m)"
      class="modal-layer pointer-events-auto absolute inset-0 overflow-hidden"
      :class="inputClass(m)"
      :style="modalStyle(m, i)"
      :data-core-input="m.input"
      :inert="modalInert(m.id)"
    >
      <PluginBoundary :plugin="m.owner" :page="m.id" focus-holder>
        <component :is="m.component" :props="m.props" />
      </PluginBoundary>
    </div>
  </div>
</template>
