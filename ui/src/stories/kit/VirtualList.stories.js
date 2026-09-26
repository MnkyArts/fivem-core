// Kit/Data/Virtual List — CoreVirtualList (DESIGN §53, §37.5 Data — display).
import { h, ref } from 'vue'
import { expect, waitFor } from 'storybook/test'
import CoreVirtualList from '../../kit/components/CoreVirtualList.vue'
import VirtualListGallery from './scenes/VirtualListGallery.vue'

const rows = Array.from({ length: 2000 }, (_, i) => ({ id: i + 1, name: 'Element ' + (i + 1), kind: i % 3 === 0 ? 'prop' : i % 3 === 1 ? 'vehicle' : 'ped' }))

export default {
  title: 'Kit/Data/Virtual List',
  component: CoreVirtualList,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A fixed-row-height virtualised list: `items`, `itemHeight`, `keyField`, `overscan`, the default '
          + 'slot gets `{ item, index }`, and `scrollToIndex(index, align?)` is exposed. The ROOT is the scroll box — '
          + 'give it a `height` or `max-height`; without one it grows to the whole list and renders every row. '
          + '`range` reports the rendered window, `reach-end` fires once per length near the bottom (a cursor loader).',
      },
    },
  },
  argTypes: {
    itemHeight: { control: { type: 'number', min: 20, max: 80 } },
    overscan: { control: { type: 'number', min: 0, max: 30 } },
    items: { control: false },
  },
  args: { itemHeight: 36, overscan: 6 },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const list = ref(null)
      const range = ref('—')
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '520px' } }, [
        h(CoreVirtualList, {
          ...args,
          ref: list,
          items: rows,
          style: 'height: 320px; border: 1px solid var(--color-border); border-radius: var(--radius-ui); background: var(--color-panel)',
          onRange: (r) => { range.value = r.start + '–' + r.end },
        }, {
          default: ({ item }) => h('div', {
            style: 'display: flex; align-items: center; gap: 12px; height: 100%; padding: 0 14px; border-bottom: 1px solid var(--color-border)',
          }, [h('span', { class: 'core-num text-fg-faint', style: 'width: 48px' }, '#' + item.id), h('span', item.name), h('span', { class: 'text-fg-faint' }, item.kind)]),
        }),
        h('p', { class: 'core-label', style: { marginTop: '14px' } }, 'window: ' + range.value),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const box = await waitFor(() => {
      const el = canvasElement.querySelector('.core-virtuallist')
      expect(el).not.toBeNull()
      return el
    })
    // Only a window of the 2000 rows exists; the spacer carries the full height.
    await waitFor(() => expect(box.querySelectorAll('.core-virtuallist__row').length).toBeGreaterThan(0))
    expect(box.querySelectorAll('.core-virtuallist__row').length).toBeLessThan(40)
    expect(box.querySelector('.core-virtuallist__spacer').style.height).toBe(2000 * 36 + 'px')
    box.scrollTop = 36 * 1000
    box.dispatchEvent(new Event('scroll'))
    await waitFor(() => expect(box.querySelector('[data-index="1000"]')).not.toBeNull())
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(VirtualListGallery) }),
  parameters: {
    docs: {
      description: { story: 'The 10 000-row audit log with scrollToIndex, an unconstrained short list and the empty state.' },
      story: { inline: false, height: '980px' },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-virtuallist').length).toBe(3))
    const big = canvasElement.querySelector('.core-virtuallist')
    expect(big.querySelectorAll('.core-virtuallist__row').length).toBeLessThan(40)
    expect(canvasElement.querySelector('.core-virtuallist.is-empty')).not.toBeNull()
  },
}
