<script setup lang="ts">
// The dev host's toolbar (DESIGN §38.11 path 1) — the four things a plugin author reaches for:
// open a page, close it, restart the plugin (the cleanup proof), and change what is behind the UI.
//
// It uses kit COMPONENTS and kit CLASSES only, never a Tailwind utility: the utilities in a plugin's
// sheet are compiled from `<resource>/ui/src`, and core's sheet scans `core/ui/src` — this file sits
// in neither, so a utility written here would simply not exist. Inline styles read tokens.
import { ref } from 'vue'
import { paintBackground } from './types.ts'
import type { DevBackground } from './types.ts'
import type { LuaMock } from './mock.ts'

const props = defineProps<{
  pluginId: string
  pages: string[]
  background: DevBackground
  backgroundEl: HTMLElement
  lua: LuaMock
  onOpenPage: (id: string, props?: object) => void
  onClosePage: (id?: string) => void
  onRestart: () => Promise<void>
}>()

const page = ref(props.pages[0] || '')
const bg = ref<DevBackground>(props.background)
const busy = ref(false)

const BACKGROUNDS: DevBackground[] = ['game', 'ink', 'none']

function setBg(next: DevBackground): void {
  bg.value = next
  paintBackground(props.backgroundEl, next)
}

async function restart(): Promise<void> {
  busy.value = true
  try {
    await props.onRestart()
  } finally {
    busy.value = false
  }
}
</script>

<template>
  <div
    class="core-panel"
    data-core-dev-bar
    style="position: fixed; left: 50%; bottom: 14px; transform: translateX(-50%); z-index: 2147483000;
           display: flex; flex-direction: row; align-items: center; gap: 10px; width: auto;
           padding: 8px 12px; pointer-events: auto; white-space: nowrap;
           font-family: var(--font-sans); font-size: var(--text-ui-sm);"
  >
    <span class="core-label" style="color: var(--color-fg-faint)">{{ pluginId }}</span>

    <select v-if="pages.length > 1" v-model="page" class="core-select" data-core-dev-page style="min-width: 150px">
      <option v-for="id in pages" :key="id" :value="id">{{ id }}</option>
    </select>
    <span v-else class="core-key" style="padding: 2px 8px">{{ page || '—' }}</span>

    <CoreButton size="sm" variant="primary" data-core-dev-open @click="onOpenPage(page)">open</CoreButton>
    <CoreButton size="sm" data-core-dev-close @click="onClosePage(page)">close</CoreButton>
    <CoreButton size="sm" variant="ghost" :loading="busy" data-core-dev-restart @click="restart">restart</CoreButton>
    <CoreButton
      size="sm"
      variant="ghost"
      data-core-dev-inspector
      @click="lua.send({ action: 'inspector:toggle' })"
    >
      inspector
    </CoreButton>

    <span style="width: 1px; height: 20px; background: var(--color-border)"></span>

    <CoreButton
      v-for="option in BACKGROUNDS"
      :key="option"
      size="sm"
      variant="ghost"
      :active="bg === option"
      :data-core-dev-bg="option"
      @click="setBg(option)"
    >
      {{ option }}
    </CoreButton>
  </div>
</template>
