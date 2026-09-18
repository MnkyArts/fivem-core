// Kit/Surfaces Divider and Dash — the two hairline motifs of §37.1 (DESIGN §37.5).
// One file for both: they are never used apart — the divider parts a panel, the dash signs it —
// and a leaf title cannot also be a folder in Storybook's index.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreDivider from '../../kit/components/CoreDivider.vue'
import CoreDash from '../../kit/components/CoreDash.vue'
import DividerGallery from './scenes/DividerGallery.vue'

export default {
  title: 'Kit/Surfaces/Divider & Dash',
  component: CoreDivider,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'CoreDivider is 1 px of `--color-border` (`--color-border-strong` with `strong`), horizontal '
          + 'or vertical, and parts around a label-voice caption when it has one. CoreDash is the short accent '
          + 'bar of the mockups: 3 px high, any tone, and the brand gradient on `accent`. A vertical divider '
          + 'takes the height of the flex row it sits in, so give the row a height (or `align-items: stretch`) '
          + 'rather than the divider.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    vertical: { control: 'boolean' },
    strong: { control: 'boolean', description: 'white 20 % instead of the 10 % hairline.' },
    label: { control: 'text', description: 'A caption the line parts around.' },
  },
  args: { vertical: false, strong: false, label: '' },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '620px' } }, [
      h('p', { class: 'core-text', style: { marginBottom: '20px' } }, 'Restores a significant amount of health.'),
      h(CoreDivider, { ...args }),
      h('p', { class: 'core-flavor', style: { marginTop: '20px' } }, 'A small kit. A second chance.'),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-divider')).not.toBeNull())
    const divider = canvasElement.querySelector('.core-divider')
    expect(divider.getAttribute('role')).toBe('separator')
    expect(getComputedStyle(divider).height).toBe('1px')
  },
}

export const Labelled = {
  name: 'With a label',
  args: { label: 'Consumables' },
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '620px' } }, [
      h(CoreDivider, { ...args }),
    ]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'The two halves are pseudo-elements, so the caption keeps its intrinsic width and the lines '
          + 'share what is left. A labelled divider drops `role="separator"`: it carries a word now.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-divider.has-label')).not.toBeNull())
    const divider = canvasElement.querySelector('.core-divider')
    expect(divider.getAttribute('role')).toBeNull()
    expect(divider.querySelector('.core-divider__label').textContent.trim()).toBe('Consumables')
  },
}

export const Dash = {
  name: 'Dash',
  args: { width: 28, tone: 'accent' },
  argTypes: {
    width: { control: { type: 'number' } },
    tone: {
      control: 'select',
      options: ['accent', 'neutral', 'success', 'warning', 'danger', 'info'],
    },
  },
  render: (args) => ({
    setup: () => () => h('div', {
      class: 'pointer-events-auto flex items-center',
      style: { padding: '48px', gap: '16px' },
    }, [
      h(CoreDash, { width: args.width, tone: args.tone }),
      h('span', { class: 'core-label' }, 'Worlds are better with stories.'),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-dash')).not.toBeNull())
    const dash = canvasElement.querySelector('.core-dash')
    expect(dash.classList.contains('core-tone-accent')).toBe(true)
    expect(dash.getAttribute('aria-hidden')).toBe('true')
    expect(getComputedStyle(dash).height).toBe('3px')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(DividerGallery) }),
  parameters: {
    docs: {
      description: { story: 'Both directions, labels, the stat rows of mockup 3, and every dash width and tone.' },
      story: { inline: false, height: '1400px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreDivider & CoreDash')).toBeInTheDocument())
    expect(canvasElement.querySelector('.core-divider--vertical')).not.toBeNull()
    expect(canvasElement.querySelector('.core-divider--strong')).not.toBeNull()
    expect(canvasElement.querySelectorAll('.core-dash').length).toBeGreaterThan(8)
  },
}
