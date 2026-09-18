<script setup>
// TableGallery — CoreTable (DESIGN §37.5, Data — display): a faction roster with cell slots, a
// selectable garage list with keyboard selection, a dense sticky-header log and the empty state.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'
import avatar from '../assets/avatar.jpg'

const money = (n) => '$ ' + Number(n).toLocaleString('en-US')

const rosterColumns = [
  { key: 'name', label: 'Member' },
  { key: 'rank', label: 'Rank', width: 140 },
  { key: 'status', label: 'Status', width: 120 },
  { key: 'seen', label: 'Last seen', width: 150 },
  { key: 'playtime', label: 'Playtime', width: 120, align: 'right', format: (v) => v + ' h' },
]

const roster = [
  { id: 1, name: 'Travis Kane', avatar, rank: 'Lead', rankTone: 'warning', status: 'online', seen: 'Now', playtime: 412 },
  { id: 2, name: 'Mila Ortega', avatar: '', rank: 'Enforcer', rankTone: 'accent', status: 'busy', seen: '4 min ago', playtime: 288 },
  { id: 3, name: 'Dez', avatar: '', rank: 'Runner', rankTone: 'info', status: 'away', seen: '22 min ago', playtime: 96 },
  { id: 4, name: 'Ana Reyes', avatar: '', rank: 'Recruit', rankTone: 'neutral', status: 'offline', seen: '3 h ago', playtime: 14 },
]

const STATUS_TONE = { online: 'success', busy: 'danger', away: 'warning', offline: 'neutral' }

const garageColumns = [
  { key: 'plate', label: 'Plate', width: 130 },
  { key: 'model', label: 'Vehicle' },
  { key: 'fuel', label: 'Fuel', width: 110, align: 'right', format: (v) => v + ' %' },
  { key: 'state', label: 'State', width: 150 },
  { key: 'value', label: 'Value', width: 140, align: 'right', format: money },
]

const garage = [
  { id: 'AB 41 XKZ', plate: 'AB 41 XKZ', model: 'Bravado Gauntlet', fuel: 72, state: 'Stored', tone: 'success', value: 32000 },
  { id: 'LS 09 TRV', plate: 'LS 09 TRV', model: 'Declasse Tornado', fuel: 18, state: 'Out — Sandy', tone: 'warning', value: 14500 },
  { id: 'ZZ 77 MRC', plate: 'ZZ 77 MRC', model: 'Vapid Dominator', fuel: 0, state: 'Impounded', tone: 'danger', value: 21750 },
  { id: 'QK 12 BNS', plate: 'QK 12 BNS', model: 'Maibatsu Sanchez', fuel: 94, state: 'Stored', tone: 'success', value: 6400 },
]

const selected = ref('LS 09 TRV')
const lastClicked = ref('')

const logColumns = [
  { key: 'time', label: 'Time', width: 90 },
  { key: 'who', label: 'Player' },
  { key: 'what', label: 'Action' },
  { key: 'amount', label: 'Amount', width: 120, align: 'right', format: money },
]

// A table almost always sits in a panel — the gallery brings one so the header band, the hairlines
// and the selected row are judged against the surface they will really have.
const PANEL = 'width: 960px; padding: 6px 14px 10px; border: 1px solid var(--color-border);'
  + ' border-radius: var(--radius-ui); background: var(--color-panel); box-shadow: var(--shadow-ui)'

const log = [
  { id: 1, time: '21:04', who: 'Travis Kane', what: 'Deposited into the faction safe', amount: 4200 },
  { id: 2, time: '20:58', who: 'Mila Ortega', what: 'Bought 120 rounds of 9 mm', amount: -960 },
  { id: 3, time: '20:41', who: 'Dez', what: 'Repaired the Gauntlet at Benny’s', amount: -1850 },
  { id: 4, time: '20:12', who: 'Travis Kane', what: 'Sold a crate at the docks', amount: 9600 },
  { id: 5, time: '19:55', who: 'Ana Reyes', what: 'Paid the weekly rent', amount: -750 },
  { id: 6, time: '19:30', who: 'Mila Ortega', what: 'Delivered the laundered cash', amount: 12400 },
  { id: 7, time: '19:02', who: 'Dez', what: 'Fined for reckless driving', amount: -300 },
]
</script>

<template>
  <KitStage
    title="CoreTable"
    description="A real &lt;table&gt;, because a column has to keep its width across every row. Columns
      declare their own alignment, width and formatter; a `cell-&lt;key&gt;` slot takes a cell over
      completely, which is how the roster gets an avatar and a rank chip without a second component."
    :width="1180"
  >
    <KitSection label="Faction roster — cell slots" layout="column" :gap="0" note="cell-name draws the portrait, cell-rank a tag, cell-status a dot badge; playtime is right-aligned with a format().">
      <div :style="PANEL">
        <CoreTable :columns="rosterColumns" :rows="roster">
          <template #cell-name="{ row }">
            <span class="core-table__media">
              <CoreAvatar :src="row.avatar" :name="row.name" size="sm" />
              <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap">{{ row.name }}</span>
            </span>
          </template>
          <template #cell-rank="{ row }">
            <CoreTag size="sm" :tone="row.rankTone" :label="row.rank" />
          </template>
          <template #cell-status="{ row }">
            <span style="display: inline-flex; align-items: center; gap: 8px">
              <CoreBadge dot :tone="STATUS_TONE[row.status]" :pulse="row.status === 'online'" />
              <span class="text-ui-sm text-fg-dim">{{ row.status }}</span>
            </span>
          </template>
        </CoreTable>
      </div>
    </KitSection>

    <KitSection label="Garage — selectable" layout="column" :gap="12" note="v-model:selected holds the ROW KEY. Click the body, then ↑/↓ to move and Enter to open.">
      <div :style="PANEL">
        <CoreTable
          v-model:selected="selected"
          :columns="garageColumns"
          :rows="garage"
          selectable
          @row-click="(row) => (lastClicked = row.model)"
        >
          <template #cell-plate="{ value }">
            <span class="font-mono text-ui-sm">{{ value }}</span>
          </template>
          <template #cell-state="{ row }">
            <CoreTag size="sm" :tone="row.tone" :label="row.state" />
          </template>
        </CoreTable>
      </div>
      <p class="text-ui-sm text-fg-faint" style="margin: 0">
        selected: <b class="text-fg">{{ selected || '—' }}</b> · last row-click:
        <b class="text-fg">{{ lastClicked || '—' }}</b>
      </p>
    </KitSection>

    <KitSection label="Dense + sticky header" layout="column" :gap="0" note="dense = 36 px rows; stickyHeader needs a max-height on the component — the root IS the scroll wrapper.">
      <div :style="PANEL">
        <CoreTable :columns="logColumns" :rows="log" dense sticky-header style="max-height: 196px">
          <template #cell-amount="{ row, value }">
            <span :style="{ color: row.amount < 0 ? 'var(--color-error)' : 'var(--color-success)' }">{{ value }}</span>
          </template>
        </CoreTable>
      </div>
    </KitSection>

    <KitSection label="Empty" layout="column" :gap="20" note="The empty row spans every column; the `empty` slot takes a CoreEmpty for the full treatment.">
      <div :style="PANEL">
        <CoreTable :columns="garageColumns" :rows="[]" empty="No vehicle is registered to this character." />
      </div>
      <div :style="PANEL">
        <CoreTable :columns="garageColumns" :rows="[]">
          <template #empty>
            <CoreEmpty icon="garage" title="Garage empty" text="Buy a vehicle at Premium Deluxe Motorsport, or ask a faction lead to transfer one to you." />
          </template>
        </CoreTable>
      </div>
    </KitSection>
  </KitStage>
</template>
