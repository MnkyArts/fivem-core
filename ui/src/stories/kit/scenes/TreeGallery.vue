<script setup>
// TreeGallery — CoreTree (DESIGN §53, §37.5 Data — display): the map editor's outliner (layer →
// type → element, trailing hide/lock buttons, counts as badges, 1 500 elements through the
// virtual list), a multi-select permission catalogue, dense, and the empty state.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const TYPES = [['prop', 'box'], ['vehicle', 'car'], ['ped', 'user'], ['spawn', 'map-marker']]
const outliner = ['Base', 'Race track', 'Checkpoint decor'].map((layer, li) => ({
  id: 'layer:' + li,
  label: layer,
  icon: 'folder',
  children: TYPES.map(([type, icon], ti) => {
    const n = li === 0 && ti === 0 ? 1500 : 3 + ((li * 4 + ti * 5) % 9)
    return {
      id: 'layer:' + li + ':' + type,
      label: type.charAt(0).toUpperCase() + type.slice(1) + 's',
      icon,
      badge: n,
      children: Array.from({ length: n }, (_, i) => ({
        id: li + ':' + type + ':' + i,
        label: type + '_' + String(i + 1).padStart(4, '0'),
        icon,
      })),
    }
  }),
}))

const selected = ref('0:prop:3')
const expanded = ref(['layer:0', 'layer:0:prop'])
const hidden = ref([])
const locked = ref(['layer:2'])
const lastEvent = ref('—')
const toggleIn = (list, key) => {
  const at = list.value.indexOf(key)
  if (at === -1) list.value = list.value.concat([key])
  else list.value = list.value.filter((k) => k !== key)
}

const perms = [
  { id: 'admin', label: 'admin', children: [
    { id: 'admin.players', label: 'players', children: [
      { id: 'admin.players.kick', label: 'kick' }, { id: 'admin.players.ban', label: 'ban' },
      { id: 'admin.players.freeze', label: 'freeze' }, { id: 'admin.players.spectate', label: 'spectate' },
    ] },
    { id: 'admin.world', label: 'world', children: [
      { id: 'admin.world.weather', label: 'weather' }, { id: 'admin.world.time', label: 'time' },
    ] },
    { id: 'admin.maps', label: 'maps', children: [{ id: 'admin.maps.edit', label: 'edit' }, { id: 'admin.maps.publish', label: 'publish', disabled: true }] },
  ] },
]
const permSel = ref(['admin.players.kick', 'admin.players.freeze'])
const permOpen = ref(['admin', 'admin.players', 'admin.world'])
</script>

<template>
  <KitStage
    title="CoreTree"
    description="Nested rows with expand / collapse and selection. The visible rows are flattened and rendered through
      CoreVirtualList, so an outliner with thousands of elements costs only what is on screen. One tab stop:
      ↑/↓ move, → opens or steps in, ← closes or steps out, Enter selects, Space toggles in `multiple`."
    :width="1000"
  >
    <div class="grid gap-10" style="grid-template-columns: 1fr 1fr">
      <KitSection label="Outliner — trailing slot + badges" layout="column" :gap="10"
                  note="1 500 props in the first type still scroll smoothly: only the rows in view exist.">
        <div style="width: 100%; padding: 6px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)">
          <CoreTree
            v-model="selected"
            v-model:expanded="expanded"
            :items="outliner"
            label="Outliner"
            style="max-height: 360px"
            @activate="(n) => (lastEvent = 'activate ' + n.label)"
            @toggle="(n, open) => (lastEvent = (open ? 'open ' : 'close ') + n.label)"
          >
            <template #trailing="{ node, depth }">
              <template v-if="depth === 0">
                <CoreIconButton :icon="hidden.includes(node.id) ? 'eye-off' : 'eye'" label="Hide layer" variant="ghost" size="sm" :active="hidden.includes(node.id)" @click="toggleIn(hidden, node.id)" />
                <CoreIconButton :icon="locked.includes(node.id) ? 'lock' : 'unlock'" label="Lock layer" variant="ghost" size="sm" :active="locked.includes(node.id)" @click="toggleIn(locked, node.id)" />
              </template>
            </template>
          </CoreTree>
        </div>
        <p class="text-ui-sm text-fg-faint" style="margin: 0">selected: <b class="text-fg">{{ selected || '—' }}</b> · last: <b class="text-fg">{{ lastEvent }}</b></p>
      </KitSection>

      <KitSection label="Multiple — permission catalogue" layout="column" :gap="10"
                  note="Ctrl-click toggles, Shift-click selects a range, Space toggles the cursor row; a disabled node never selects.">
        <div style="width: 100%; padding: 6px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)">
          <CoreTree v-model="permSel" v-model:expanded="permOpen" :items="perms" multiple dense label="Permissions" />
        </div>
        <p class="text-ui-sm text-fg-faint" style="margin: 0">{{ permSel.join(', ') || '—' }}</p>
      </KitSection>
    </div>

    <KitSection label="Empty" layout="column" :gap="10" note="`empty` prints a line; the `empty` slot takes anything.">
      <div style="width: 360px; border: 1px solid var(--color-border); border-radius: var(--radius-ui)">
        <CoreTree :items="[]" empty="This map has no elements yet." />
      </div>
    </KitSection>
  </KitStage>
</template>
