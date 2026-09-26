// Kit/Data — CoreTable (DESIGN §37.5, Data — display).
import { h, ref } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreTable from '../../kit/components/CoreTable.vue'
import TableGallery from './scenes/TableGallery.vue'

const columns = [
  { key: 'plate', label: 'Plate', width: 130 },
  { key: 'model', label: 'Vehicle' },
  { key: 'fuel', label: 'Fuel', width: 110, align: 'right', format: (v) => v + ' %' },
  { key: 'value', label: 'Value', width: 140, align: 'right', format: (v) => '$ ' + Number(v).toLocaleString('en-US') },
]

const rows = [
  { id: 'AB 41 XKZ', plate: 'AB 41 XKZ', model: 'Bravado Gauntlet', fuel: 72, value: 32000 },
  { id: 'LS 09 TRV', plate: 'LS 09 TRV', model: 'Declasse Tornado', fuel: 18, value: 14500 },
  { id: 'ZZ 77 MRC', plate: 'ZZ 77 MRC', model: 'Vapid Dominator', fuel: 0, value: 21750 },
  { id: 'QK 12 BNS', plate: 'QK 12 BNS', model: 'Maibatsu Sanchez', fuel: 94, value: 6400 },
]

export default {
  title: 'Kit/Data/Table',
  component: CoreTable,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A real `<table>`, because a column has to keep its width across every row. Each '
          + 'column declares its own `align`, `width` and `format(value, row)`; a `cell-<key>` slot '
          + 'takes one cell over completely (`{ row, value, column }`), which is how a roster gets a '
          + 'portrait and a rank chip without a second component. The component root is the SCROLL '
          + 'WRAPPER, not the table — `stickyHeader` needs a scroll container, so the max-height you '
          + 'set on `<CoreTable>` is what the header sticks inside. `v-model:selected` holds the row '
          + 'KEY (`rowKey`, `id` by default), never the index, because rows get re-sorted. Sorting (§53): '
          + '`sortable` (or a column\'s own `sortable`) turns headers into buttons that flip `v-model:sortKey` / '
          + '`v-model:sortDir` and emit one `update:sort` ({ key, dir }) — the table never reorders rows itself, the '
          + 'caller (usually the server) does. `loading` sweeps a bar along the top edge and dims the rows; with no '
          + 'rows yet it draws `loadingRows` skeleton rows instead of the empty line.',
      },
    },
  },
  argTypes: {
    selectable: { control: 'boolean', description: 'Rows highlight and the body answers ↑/↓ + Enter.' },
    dense: { control: 'boolean', description: '36 px rows instead of 44 px.' },
    stickyHeader: { control: 'boolean', description: 'Needs a max-height on the component.' },
    rowKey: { control: 'text' },
    sortable: { control: 'boolean', description: 'Every column sorts unless it says sortable: false.' },
    loading: { control: 'boolean', description: 'Sweeping bar + dimmed rows; skeleton rows when empty.' },
    empty: { control: 'text' },
    columns: { control: false },
    rows: { control: false },
  },
  args: { selectable: true, dense: false, stickyHeader: false, rowKey: 'id', empty: 'No vehicle is registered to this character.', sortable: true, loading: false },
}

const panel = {
  width: '820px',
  padding: '6px 14px 10px',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  background: 'var(--color-panel)',
  boxShadow: 'var(--shadow-ui)',
}

export const Playground = {
  // The args are spread inside the render function so the controls stay live (../storeHelpers.js).
  render: (args) => ({
    setup () {
      const selected = ref('LS 09 TRV')
      const clicked = ref('')
      const sort = ref({ key: null, dir: 'asc' })
      // The story plays the caller: it sorts on update:sort, the table only reports.
      const sorted = () => {
        const { key, dir } = sort.value
        if (!key) return rows
        const d = dir === 'desc' ? -1 : 1
        return rows.slice().sort((a, b) => (a[key] < b[key] ? -d : a[key] > b[key] ? d : 0))
      }
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
        h('div', { style: panel }, [
          h(CoreTable, {
            ...args,
            columns,
            rows: sorted(),
            sortKey: sort.value.key,
            sortDir: sort.value.dir,
            'onUpdate:sort': (s) => { sort.value = s },
            selected: selected.value,
            'onUpdate:selected': (v) => { selected.value = v },
            onRowClick: (row) => { clicked.value = row.model },
            style: args.stickyHeader ? 'max-height: 160px' : undefined,
          }),
        ]),
        h('p', { class: 'core-label', style: { marginTop: '16px' } },
          'selected: ' + (selected.value || '—') + '  ·  last row-click: ' + (clicked.value || '—')),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Bravado Gauntlet')).toBeInTheDocument())
    // Selection follows the row key, and a click moves it.
    expect(canvasElement.querySelector('.core-table__row.is-selected')).not.toBeNull()
    canvasElement.querySelectorAll('.core-table__row')[0].click()
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-table__row')[0].classList.contains('is-selected')).toBe(true))
    // The header cells wear the label voice, the alignment modifier comes from the column.
    expect(canvasElement.querySelectorAll('.core-table__th').length).toBe(4)
    expect(canvasElement.querySelectorAll('.core-table__th--right').length).toBe(2)
    // §53: a sortable header reports the sort; the story re-sorts and aria-sort follows.
    const sortBtn = canvasElement.querySelectorAll('.core-table__sort')[3]
    if (sortBtn) {
      sortBtn.click()
      await waitFor(() => expect(canvasElement.querySelectorAll('.core-table__th')[3].getAttribute('aria-sort')).toBe('ascending'))
      expect(canvasElement.querySelectorAll('.core-table__row')[0].textContent).toContain('Maibatsu Sanchez')
    }
  },
}

export const Empty = {
  name: 'Playground — empty',
  args: { rows: [] },
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h('div', { style: panel }, [h(CoreTable, { ...args, columns, rows: [] })]),
    ]),
  }),
  parameters: {
    docs: { description: { story: 'The placeholder row spans every column. The `empty` slot replaces the line with a CoreEmpty.' } },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('No vehicle is registered to this character.')).toBeInTheDocument())
    expect(canvasElement.querySelector('.core-table__empty td').getAttribute('colspan')).toBe('4')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(TableGallery) }),
  parameters: {
    docs: {
      description: { story: 'A faction roster built from cell slots, a selectable garage, a dense sticky-header ledger, the sortable garage with both loading states (§53) and both empty states.' },
      story: { inline: false, height: '2150px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreTable')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-table').length).toBe(7)
    expect(canvasElement.querySelectorAll('.core-table__row--skeleton').length).toBe(3)
    expect(canvasElement.querySelector('.core-table__th[aria-sort="descending"]')).not.toBeNull()
    expect(canvasElement.querySelector('.core-table--dense')).not.toBeNull()
    expect(canvasElement.querySelector('.core-table__wrap.is-sticky')).not.toBeNull()
    // ↑/↓ on the focused body move the selection without a mouse.
    const body = canvasElement.querySelectorAll('.core-table__body')[1]
    body.focus()
    body.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', bubbles: true }))
    // Scoped to that body: the §53 sortable table below lists the same plates.
    await waitFor(() => expect(Array.from(body.querySelectorAll('tr')).find((tr) => tr.textContent.includes('ZZ 77 MRC')).classList.contains('is-selected')).toBe(true))
  },
}
