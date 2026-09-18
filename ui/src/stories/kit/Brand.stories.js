// Kit/Surfaces Brand and Tagline — the logo lockup of mockup 1 and the stacked, widely tracked
// words that sit beside a rule in every screen header (DESIGN §37.5).
// One file for both, and a leaf title cannot also be a folder in Storybook's index.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreBrand from '../../kit/components/CoreBrand.vue'
import CoreTagline from '../../kit/components/CoreTagline.vue'
import BrandGallery from './scenes/BrandGallery.vue'

// The mockups' mark: a coral triangle with a notch and a darker wedge over its lower right.
// Raw SVG rather than an icon, because a server's logo is art, not a 24 x 24 glyph.
const mark = () => h('svg', { viewBox: '0 0 24 24', 'aria-hidden': 'true' }, [
  h('path', { d: 'M12 2 23 21 1 21Z M12 9.6 6.4 19.2 17.6 19.2Z', fill: 'currentColor', 'fill-rule': 'evenodd' }),
  h('path', { d: 'M15.2 9.4 23 21 7.4 21Z', style: { fill: 'var(--color-ink)' }, opacity: '0.62' }),
])

export default {
  title: 'Kit/Surfaces/Brand & Tagline',
  component: CoreBrand,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'CoreBrand is mark + wordmark + tagline, at 22 / 30 / 48 / 64 px. The mark box is not rendered '
          + 'at all without a `logo` or a `logo` slot, so a server with no art still gets a clean wordmark, and '
          + 'the slot inherits the accent colour — pass an inline SVG and it comes out coral. CoreTagline '
          + 'stacks words on a 0.3 em track at line-height 1.75 beside a hairline (`rule`) or the coral rule of '
          + 'mockups 3 and 4 (`rule="accent"`), with an optional dash under the block.',
      },
      story: { inline: false, height: '280px' },
    },
  },
  argTypes: {
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg', 'xl'] },
    name: { control: 'text' },
    tagline: { control: 'text' },
    logo: { control: 'text', description: 'A URL. The logo slot is the better way in.' },
  },
  args: { size: 'lg', name: 'Wayfinder', tagline: 'Explore a larger tomorrow', logo: '' },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreBrand, { ...args }, { logo: mark }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-brand')).not.toBeNull())
    const brand = canvasElement.querySelector('.core-brand')
    expect(brand.classList.contains('core-brand--lg')).toBe(true)
    expect(brand.querySelector('.core-brand__logo svg')).not.toBeNull()
    expect(brand.querySelector('.core-brand__name').textContent.trim()).toBe('Wayfinder')
  },
}

export const NoMark = {
  name: 'Wordmark only',
  args: { size: 'md', tagline: '' },
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreBrand, { ...args }),
    ]),
  }),
  parameters: {
    docs: { description: { story: 'No logo and no slot: the mark box is skipped, not left empty.' } },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-brand')).not.toBeNull())
    expect(canvasElement.querySelector('.core-brand__logo')).toBeNull()
  },
}

export const Tagline = {
  name: 'Tagline',
  args: { lines: ['Explore', 'Survive', 'Belong'], rule: true, dash: true, align: 'left' },
  argTypes: {
    rule: { control: 'inline-radio', options: [false, true, 'accent'] },
    dash: { control: 'boolean' },
    align: { control: 'inline-radio', options: ['left', 'center', 'right'] },
  },
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreTagline, { lines: args.lines, rule: args.rule, dash: args.dash, align: args.align }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-tagline')).not.toBeNull())
    const tagline = canvasElement.querySelector('.core-tagline')
    expect(tagline.classList.contains('has-rule')).toBe(true)
    expect(tagline.querySelectorAll('.core-tagline__line').length).toBe(3)
    expect(tagline.querySelector('.core-dash')).not.toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(BrandGallery) }),
  parameters: {
    docs: {
      description: { story: 'The main-menu lockup, every size, both rules, the dash and all three alignments.' },
      story: { inline: false, height: '1300px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreBrand & CoreTagline')).toBeInTheDocument())
    expect(canvasElement.querySelector('.core-brand--lg')).not.toBeNull()
    expect(canvasElement.querySelector('.core-tagline.is-rule-accent')).not.toBeNull()
    expect(canvasElement.querySelector('.core-tagline--align-right')).not.toBeNull()
  },
}
