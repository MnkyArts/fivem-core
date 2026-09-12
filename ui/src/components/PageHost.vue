<script setup>
// Plugin page host (DESIGN §7.4): injects each registered page's <link>/<script> once,
// renders the open page in a focusable layer and every overlay in a click-through layer.
// Escape -> ui_close is handled centrally by store.handleKeydown.
import { computed, watch, onMounted } from 'vue'
import { store, notify, whenRegistered } from '../store.js'
import { post } from '../bridge.js'

const WAIT_MS = 5000
const injected = new Map() // id -> { style, styleNode, script, scriptNode }
let waitToken = 0

function drop (node) {
  if (node && node.parentNode) node.parentNode.removeChild(node)
}

// One <link>/<script> per page id; a re-register with a new path replaces that node.
function syncTags () {
  const pages = store.pages || {}

  for (const id of Object.keys(pages)) {
    const page = pages[id] || {}
    const style = page.style || null
    const script = page.script || null
    let rec = injected.get(id)
    if (!rec) {
      rec = { style: null, styleNode: null, script: null, scriptNode: null }
      injected.set(id, rec)
    }

    if (rec.style !== style) {
      drop(rec.styleNode)
      rec.styleNode = null
      rec.style = style
      if (style) {
        const link = document.createElement('link')
        link.rel = 'stylesheet'
        link.href = style
        link.dataset.corePage = id
        link.onerror = () => notify({ message: 'Style of UI page "' + id + '" failed to load', type: 'warning' })
        document.head.appendChild(link)
        rec.styleNode = link
      }
    }

    if (rec.script !== script) {
      drop(rec.scriptNode)
      rec.scriptNode = null
      rec.script = script
      if (script) {
        const el = document.createElement('script')
        el.src = script
        el.async = false
        el.dataset.corePage = id
        el.onerror = () => notify({ message: 'UI page "' + id + '" failed to load', type: 'error' })
        document.head.appendChild(el)
        rec.scriptNode = el
      }
    }
  }

  for (const id of Array.from(injected.keys())) {
    if (pages[id]) continue
    const rec = injected.get(id)
    drop(rec.styleNode)
    drop(rec.scriptNode)
    injected.delete(id)
  }
}

// `component` is markRaw'd by the store, so the deep watch never walks into it.
watch(() => store.pages, syncTags, { deep: true })

const openPage = computed(() => (store.openPage ? store.pages[store.openPage] : null) || null)
const openComponent = computed(() => (openPage.value && openPage.value.component) || null)
const openProps = computed(() => (openPage.value && openPage.value.props) || {})

const overlays = computed(() => {
  const out = []
  for (const id of Object.keys(store.overlays)) {
    const page = store.pages[id]
    if (page && page.component) out.push({ id, component: page.component, props: page.props })
  }
  return out
})

// page:open before the bundle registered: wait 5 s, then tell Lua and warn the player.
watch(
  () => store.openPage,
  (id) => {
    const token = ++waitToken
    if (!id) return
    const page = store.pages[id]
    if (page && page.component) return
    whenRegistered(id, WAIT_MS).then((component) => {
      if (component || token !== waitToken || store.openPage !== id) return
      post('ui_event', { page: id, event: '__error', data: { error: 'not_registered' } })
      notify({ message: 'UI page "' + id + '" did not load', type: 'error' })
    })
  },
  { immediate: true }
)

onMounted(syncTags)
</script>

<template>
  <div class="page-host">
    <div class="overlay-layer">
      <component :is="o.component" v-for="o in overlays" :key="o.id" :props="o.props" />
    </div>
    <div v-if="openComponent" class="page-layer">
      <component :is="openComponent" :props="openProps" />
    </div>
  </div>
</template>

<style scoped>
.page-host {
  position: fixed;
  inset: 0;
  pointer-events: none;
}

.overlay-layer {
  position: absolute;
  inset: 0;
  z-index: 10;
  pointer-events: none;
}

.page-layer {
  position: absolute;
  inset: 0;
  z-index: 20;
  pointer-events: auto;
  overflow: hidden;
}
</style>
