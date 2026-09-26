// Kit/Data/Tree — CoreTree (DESIGN §53, §37.5 Data — display).
import { h, ref } from 'vue'
import { expect, waitFor } from 'storybook/test'
import CoreTree from '../../kit/components/CoreTree.vue'
import TreeGallery from './scenes/TreeGallery.vue'

const items = [
  { id: 'vehicles', label: 'Vehicles', icon: 'car', badge: 3, children: [
    { id: 'sports', label: 'Sports', children: [{ id: 'banshee', label: 'Banshee' }, { id: 'comet', label: 'Comet' }] },
    { id: 'offroad', label: 'Off-road', children: [{ id: 'sandking', label: 'Sandking' }] },
  ] },
  { id: 'peds', label: 'Peds', icon: 'user', children: [{ id: 'cop', label: 'Cop' }, { id: 'medic', label: 'Medic', disabled: true }] },
  { id: 'props', label: 'Props', icon: 'box' },
]

export default {
  title: 'Kit/Data/Tree',
  component: CoreTree,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Nested rows with expand / collapse and selection. `items` nest through `children` (`childrenField`), '
          + 'each node `{ id, label, icon?, badge?, disabled? }`. `v-model` is the selected key (an array with '
          + '`multiple`), `v-model:expanded` the open keys. Slots `icon`, `label`, `badge` and `trailing` get the node. '
          + 'The root is ONE tab stop with an aria-activedescendant cursor; rows render through CoreVirtualList, '
          + 'so a caller\'s max-height makes it scroll and only the visible rows exist. Emits `select`, `toggle` '
          + '(node, open) and `activate` (double click).',
      },
    },
  },
  argTypes: {
    multiple: { control: 'boolean' },
    dense: { control: 'boolean' },
    disabled: { control: 'boolean' },
    indent: { control: { type: 'number', min: 8, max: 32 } },
    items: { control: false },
  },
  args: { multiple: false, dense: false, disabled: false, indent: 16 },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const selected = ref(args.multiple ? [] : 'comet')
      const expanded = ref(['vehicles', 'sports'])
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '420px' } }, [
        h('div', { style: 'padding: 6px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)' }, [
          h(CoreTree, {
            ...args,
            items,
            label: 'Catalogue',
            modelValue: selected.value,
            'onUpdate:modelValue': (v) => { selected.value = v },
            expanded: expanded.value,
            'onUpdate:expanded': (v) => { expanded.value = v },
          }),
        ]),
        h('p', { class: 'core-label', style: { marginTop: '14px' } }, 'selected: ' + JSON.stringify(selected.value)),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const tree = await waitFor(() => {
      const el = canvasElement.querySelector('.core-tree')
      expect(el).not.toBeNull()
      return el
    })
    await waitFor(() => expect(tree.querySelectorAll('.core-tree__row').length).toBe(7))
    expect(tree.querySelector('.core-tree__row.is-selected').textContent).toContain('Comet')
    // → on a closed node opens it; the flat row list grows by its children.
    tree.focus()
    const offroad = Array.from(tree.querySelectorAll('.core-tree__row')).find((r) => r.textContent.includes('Off-road'))
    offroad.click()
    tree.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }))
    await waitFor(() => expect(tree.querySelectorAll('.core-tree__row').length).toBe(8))
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(TreeGallery) }),
  parameters: {
    docs: {
      description: { story: 'The editor outliner (trailing buttons, badges, 1 500 virtualised elements), a multi-select permission tree, the empty state.' },
      story: { inline: false, height: '860px' },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-tree').length).toBe(3))
    const outliner = canvasElement.querySelector('.core-tree')
    // 1 500 children are open under the first type, but only a window of rows is in the DOM.
    expect(outliner.querySelectorAll('.core-tree__row').length).toBeLessThan(60)
    expect(canvasElement.querySelectorAll('.core-tree.is-multiple .core-tree__row.is-selected').length).toBe(2)
  },
}
