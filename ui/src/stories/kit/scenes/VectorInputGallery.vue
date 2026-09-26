<script setup>
// VectorInputGallery — CoreVectorInput (DESIGN §53, §37.5 Forms — text): a world position with the
// §43 world bounds, a rotation in degrees, copy one → paste into the other, neutral axis caps,
// every size, the narrow side-panel wrap, invalid and disabled.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const pos = ref({ x: -1037.52, y: -2738.13, z: 13.76 })
const pos2 = ref({ x: 0, y: 0, z: 0 })
const rot = ref({ x: 0, y: 0, z: 147.5 })
const copied = ref('—')
const sizes = ['sm', 'md', 'lg']
const sized = ref({ x: 1.5, y: 2, z: -0.25 })
</script>

<template>
  <KitStage
    title="CoreVectorInput"
    description="{ x, y, z } as three CoreNumberInputs with one shared step / precision, axis caps in the gizmo colours
      (error / success / info tokens) and copy / paste of the whole vector — `1, 2, 3`, `vector3(…)`, Lua and JSON
      tables all parse, and Ctrl+V of a vector into any field fills all three."
    :width="1000"
  >
    <KitSection label="Position — world bounds" layout="column" :gap="12"
                note="min / max take a number or { x, y, z } (here the §43 world box: ±10000, z −1000…3000).">
      <div style="width: 640px">
        <CoreField label="Position">
          <CoreVectorInput v-model="pos" :min="{ x: -10000, y: -10000, z: -1000 }" :max="{ x: 10000, y: 10000, z: 3000 }" @copy="(t) => (copied = t)" />
        </CoreField>
        <CoreField label="Paste target" hint="Copy the position above, then press paste here.">
          <CoreVectorInput v-model="pos2" />
        </CoreField>
      </div>
      <p class="text-ui-sm text-fg-faint" style="margin: 0">copied: <b class="text-fg">{{ copied }}</b></p>
    </KitSection>

    <KitSection label="Rotation — degrees" layout="column" :gap="12" note="`rotation` puts the ° suffix on every axis.">
      <div style="width: 640px"><CoreVectorInput v-model="rot" rotation :step="0.5" :labels="['P', 'R', 'Y']" /></div>
    </KitSection>

    <KitSection label="Sizes · neutral caps · narrow column" layout="column" :gap="14"
                note="axisColors: false keeps the caps neutral; under three steppers of room the cells wrap one per row.">
      <div v-for="s in sizes" :key="s" style="width: 700px"><CoreVectorInput v-model="sized" :size="s" :axis-colors="s !== 'lg'" /></div>
      <div style="width: 300px; padding: 12px; border: 1px solid var(--color-border); border-radius: var(--radius-ui)">
        <CoreVectorInput v-model="sized" :copyable="false" />
      </div>
    </KitSection>

    <KitSection label="Invalid · disabled" layout="column" :gap="12">
      <div style="width: 640px"><CoreField label="Spawn point" error="Outside the map bounds."><CoreVectorInput v-model="pos2" invalid /></CoreField></div>
      <div style="width: 640px"><CoreVectorInput :model-value="{ x: 1, y: 2, z: 3 }" disabled /></div>
    </KitSection>
  </KitStage>
</template>
