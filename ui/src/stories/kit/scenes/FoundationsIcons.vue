<script setup>
// FoundationsIcons — the whole icon registry (DESIGN §37.1, §37.3). Filled glyphs on a 24 x 24
// grid, drawn with currentColor. Use it to find a name before inventing one: a plugin only adds
// an icon (CoreUI.kit.registerIcons) when nothing here fits.
import { computed, ref } from 'vue'
import { ICONS } from '../../../kit/icons.js'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const names = Object.keys(ICONS).sort()
const query = ref('')

const shown = computed(() => {
  const q = query.value.trim().toLowerCase()
  return q ? names.filter((name) => name.toLowerCase().includes(q)) : names
})

const gridStyle = {
  display: 'grid',
  gridTemplateColumns: 'repeat(auto-fill, minmax(104px, 1fr))',
  gap: '10px',
  width: '100%',
}
</script>

<template>
  <KitStage
    title="Icons"
    description="&lt;CoreIcon name=&quot;heart&quot; size=&quot;lg&quot; /&gt; — the name is a registry key, and any
      icon prop in the kit takes the same key (or raw 24 x 24 path data). The glyph always inherits the
      colour of the text around it."
  >
    <KitSection label="Registry" layout="column" :gap="16" :note="names.length + ' icons · Material Design Icons, Apache-2.0, vendored into kit/icons.js'">
      <input
        v-model="query"
        class="core-input"
        type="text"
        placeholder="Filter by name"
        style="width: 280px"
      />
      <p v-if="query" class="text-ui-sm text-fg-dim">{{ shown.length }} of {{ names.length }}</p>
      <div :style="gridStyle">
        <div
          v-for="name in shown"
          :key="name"
          :title="name"
          class="bg-panel-raise border border-border rounded-ui-sm"
          style="display: flex; flex-direction: column; align-items: center; gap: 9px; padding: 14px 6px 10px"
        >
          <CoreIcon :name="name" size="lg" />
          <span class="text-ui-xs text-fg-faint" style="text-align: center; overflow-wrap: anywhere">{{ name }}</span>
        </div>
      </div>
      <p v-if="!shown.length" class="core-flavor">Nothing matches “{{ query }}”.</p>
    </KitSection>
  </KitStage>
</template>
