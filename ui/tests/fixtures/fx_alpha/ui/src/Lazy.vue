<script lang="ts">
// MODULE scope of the lazy chunk (a plain <script> block, not <script setup>, which is a per-mount
// setup function): `lazyEvals` counts how often this chunk was EVALUATED. It must still be 0 after
// `fx_alpha` is ready and only become 1 on the first `page:open` of `fx_alpha_lazy` — that is what
// makes a lazy page worth having, and the server's request log has to agree.
import { counters } from './state.ts'

counters.lazyEvals++
export { counters }
</script>

<script setup lang="ts">
defineOptions({ name: 'FxAlphaLazy', inheritAttrs: false })
</script>

<template>
  <div class="fx-alpha-lazy text-fg-dim fixed bottom-10 left-10 p-4">lazy {{ counters.lazyEvals }}</div>
</template>
