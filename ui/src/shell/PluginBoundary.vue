<script setup lang="ts">
// One error boundary per plugin-owned instance (DESIGN §38.12).
//
// `onErrorCaptured -> false` stops the error at this subtree, so a crashing inventory page cannot
// take the HUD, the chat or another plugin's overlay with it. Two rules the prototype had to learn:
//
//   * in a PRODUCTION Vue build `info` is `https://vuejs.org/error-reference/#runtime-<code>`, not a
//     readable string — `runtime/errors.ts` parses the code instead of matching dev text, and
//   * an EVENT-HANDLER throw leaves a perfectly good tree: it is reported, and the page keeps
//     rendering. Only setup/render failures justify replacing the subtree.
//
// A crashed instance that HOLDS THE FOCUS is closed (`ui_close`), so a broken page can never trap
// the cursor. The next `page:open` remounts it from scratch.
import { computed, onActivated, onErrorCaptured, ref, watch } from 'vue'
import { componentName, isFatalRenderError, notify, report } from '../runtime/errors.ts'
import { providePageContext, type PageContext } from '../runtime/host.ts'
import { closePage, markCrashed, pageScope } from '../runtime/pages.ts'
import { devOptions } from '../runtime/plugins.ts'

const props = defineProps<{
  /** The owning resource, or null for a core/legacy page. */
  plugin?: string | null
  page: string
  /** True for the exclusive page and for modals — the layers that hold the NUI cursor. */
  focusHolder?: boolean
}>()

const failed = ref<string | null>(null)
const failedComponent = ref<string>('')

const ctx = computed<PageContext>(() => ({ id: props.page, owner: props.plugin || null }))
providePageContext({ id: props.page, owner: props.plugin || null }, pageScope(props.page))

// A remount (`page:close` + `page:open`) has to get a clean slate. PageHost keys every instance
// with `id:epoch`, so a crash really produces a NEW boundary — this watch only covers the case
// where the same boundary is reused for another id.
watch(
  () => props.page,
  () => {
    failed.value = null
    failedComponent.value = ''
  },
)

// A `keepAlive` page comes back from the KeepAlive cache instead of being remounted; if it died
// while it was open, the open that brought it back is the one §38.12 promises a fresh instance to.
onActivated(() => {
  failed.value = null
  failedComponent.value = ''
})

onErrorCaptured((err: unknown, instance: unknown, info: string) => {
  const component = componentName(instance)
  report({
    plugin: props.plugin || null,
    page: props.page,
    component,
    error: err,
    info,
    once: instance as object,
  })
  if (isFatalRenderError(info)) {
    failed.value = err && (err as Error).message ? (err as Error).message : String(err)
    failedComponent.value = component
    // The record remembers the crash so the NEXT `page:open` bumps its epoch and remounts — which
    // is the only way back for an overlay, because nothing ever closes one on its behalf.
    markCrashed(props.page)
    notify('UI page "' + props.page + '" crashed', 'error')
    if (props.focusHolder) closePage(props.page)
  }
  return false
})

const showReport = computed(() => !!failed.value && devOptions().enabled)
</script>

<template>
  <!-- Production: a failed instance renders NOTHING. Dev: a kit-styled report, so the developer
       sees which component of which resource died without opening the console. -->
  <div v-if="showReport" class="core-panel core-panel--pad-md pointer-events-auto m-6 max-w-lg text-ui-sm">
    <p class="font-display text-ui-lg tracking-label text-error uppercase">{{ plugin || 'core' }} / {{ page }}</p>
    <p class="mt-1 text-fg-dim">
      <code class="font-mono">&lt;{{ failedComponent }}&gt;</code> threw while rendering.
    </p>
    <p class="mt-2 font-mono text-ui-xs break-words text-fg">{{ failed }}</p>
    <p class="mt-3 text-ui-xs text-fg-faint">The page was replaced; the rest of the shell is untouched.</p>
  </div>
  <slot v-else-if="!failed" :ctx="ctx" />
</template>
