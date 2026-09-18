<script setup lang="ts">
// fx_alpha's exclusive page. Every feature the suite asserts on is here and nothing else:
//   * `usePage()` with no id (provide/inject through PluginBoundary) and typed props,
//   * a kit tag the plugin never imported (`<CoreButton>`, globally registered on core's app),
//   * `px-8` ON that kit tag — the plugin's utility layer must beat the kit's components layer,
//   * a token utility (`bg-panel`), which must resolve to core's `--color-panel` by reference,
//   * a `<style scoped>` rule, which travels in the plugin's own stylesheet,
//   * an imported asset, whose URL must resolve against the PLUGIN's origin (`base: './'`),
//   * a handler that throws (the tree survives) and a child that throws while rendering (it does not).
import { ref } from 'vue'
import { useNui, usePage } from '@core/ui'
import Crash from './Crash.vue'
import markUrl from './mark.svg'
import { VARIANT, counters } from './state.ts'
import type { AlphaEvents, AlphaIncoming, AlphaProps, AlphaRpc } from './index.ts'

defineOptions({ name: 'FxAlphaPage', inheritAttrs: false })

const page = usePage<AlphaProps, AlphaEvents, AlphaIncoming>()
const nui = useNui<AlphaRpc>()

const echo = ref('')
const pageEvents = ref(0)

page.on('ping', () => { pageEvents.value++ })

async function callEcho() {
  try {
    const res = (await nui.invoke('echo', { from: 'page' })) as { echoed?: unknown } | null
    echo.value = JSON.stringify(res)
  } catch (err) {
    echo.value = 'ERR:' + (err as { code?: string }).code
  }
}

function throwInHandler(): void {
  throw new Error('fx_alpha: handler exploded on purpose')
}
</script>

<template>
  <div class="fx-alpha-page bg-panel text-fg-dim fixed top-10 left-10 p-4">
    <p class="fx-alpha-label">{{ VARIANT }}:{{ page.props.label || '-' }}</p>
    <p class="fx-alpha-scoped">scoped</p>
    <p class="fx-alpha-counts">{{ counters.setups }}/{{ pageEvents }}</p>
    <p class="fx-alpha-echo">{{ echo }}</p>
    <img class="fx-alpha-mark" :src="markUrl" alt="" width="8" height="8" />
    <CoreButton class="fx-alpha-btn px-8" @click="page.emit('hello', { at: 1 })">emit</CoreButton>
    <CoreButton class="fx-alpha-echo-btn" @click="callEcho()">echo</CoreButton>
    <CoreButton class="fx-alpha-throw" @click="throwInHandler()">throw</CoreButton>
    <Crash v-if="page.props.crash" />
  </div>
</template>

<style scoped>
.fx-alpha-scoped {
  border-left-style: solid;
  border-left-width: 7px;
}
</style>
