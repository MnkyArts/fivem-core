// Kit/Navigation/Pagination — CorePagination (DESIGN §53, §37.5 Navigation).
import { h, ref } from 'vue'
import { expect, waitFor } from 'storybook/test'
import CorePagination from '../../kit/components/CorePagination.vue'
import PaginationGallery from './scenes/PaginationGallery.vue'

export default {
  title: 'Kit/Navigation/Pagination',
  component: CorePagination,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: '`v-model:page` (1-based) and `v-model:pageSize`. A known `pageCount` gives numbered pages; `null` is '
          + 'a cursor pager (`‹ PAGE 3 ›`) driven by `hasNext` / `hasPrev`. `total` prints `1–25 of 312`, '
          + '`pageSizes` (`[]` hides it) is an inline CoreSelect, `siblings` sets how many numbers flank the current '
          + 'page. Emits one `change` ({ page, pageSize }) per move; the caller fetches.',
      },
      story: { inline: false, height: '200px' },
    },
  },
  argTypes: {
    pageCount: { control: { type: 'number', min: 0 } },
    total: { control: { type: 'number', min: 0 } },
    hasNext: { control: 'select', options: [null, true, false] },
    siblings: { control: { type: 'number', min: 0, max: 3 } },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    disabled: { control: 'boolean' },
  },
  args: { pageCount: 13, total: 312, hasNext: null, siblings: 1, size: 'md', disabled: false },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const page = ref(1)
      const pageSize = ref(25)
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '760px' } }, [
        h(CorePagination, {
          ...args,
          page: page.value,
          'onUpdate:page': (v) => { page.value = v },
          pageSize: pageSize.value,
          'onUpdate:pageSize': (v) => { pageSize.value = v },
        }),
        h('p', { class: 'core-label', style: { marginTop: '14px' } }, 'page ' + page.value + ' · size ' + pageSize.value),
      ])
    },
  }),
  play: async ({ canvasElement, args }) => {
    if (!Number.isFinite(args.pageCount) || args.disabled) return
    const nav = await waitFor(() => {
      const el = canvasElement.querySelector('.core-pagination')
      expect(el).not.toBeNull()
      return el
    })
    expect(nav.querySelector('.core-pagination__btn--prev').disabled).toBe(true)
    nav.querySelector('.core-pagination__btn--next').click()
    await waitFor(() => expect(nav.querySelector('.core-pagination__page.is-active').textContent.trim()).toBe('2'))
    expect(nav.querySelector('.core-pagination__range').textContent).toContain('26–50')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(PaginationGallery) }),
  parameters: {
    docs: {
      description: { story: 'Numbered with total and size, the cursor pager, short and long runs, every size, disabled.' },
      story: { inline: false, height: '900px' },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-pagination').length).toBe(8))
    expect(canvasElement.querySelectorAll('.core-pagination.is-cursor').length).toBe(1)
    expect(canvasElement.querySelectorAll('.core-pagination__gap').length).toBeGreaterThan(1)
  },
}
