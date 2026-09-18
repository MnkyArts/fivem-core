// Kit/Surfaces Heading — CoreHeading, the title block of the kit (DESIGN §37.5).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreHeading from '../../kit/components/CoreHeading.vue'
import HeadingGallery from './scenes/HeadingGallery.vue'

export default {
  title: 'Kit/Surfaces/Heading',
  component: CoreHeading,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A label-voice eyebrow above, the display title, an eyebrow-voice subtitle under it and an '
          + 'actions group on the right. `slash` draws the mockups\' // marker — two accent bars skewed −20°, '
          + 'sized in em so they scale with the title — and puts the title in italic. The two large sizes run '
          + 'the title from white at the cap line into the dimmed foreground at the baseline, which is what '
          + 'makes a 34 px heading read as art rather than as a web `<h1>`. CorePanel renders one of these for '
          + 'its `title`, so a panel heading and a standalone heading are the same object.',
      },
      story: { inline: false, height: '320px' },
    },
  },
  argTypes: {
    size: {
      control: 'inline-radio',
      options: ['sm', 'md', 'lg', 'xl'],
      description: 'Title 18 / 24 / 34 / 48 px; the subtitle follows at 12 / 13 / 14 / 16 px.',
    },
    align: { control: 'inline-radio', options: ['left', 'center', 'right'] },
    title: { control: 'text' },
    subtitle: { control: 'text' },
    eyebrow: { control: 'text' },
    slash: { control: 'boolean' },
    tag: { control: 'text', description: 'h1…h6, or div inside a card.' },
  },
  args: {
    size: 'lg',
    align: 'left',
    title: 'Inventory',
    subtitle: "Gear up for what's next.",
    eyebrow: '',
    slash: false,
    tag: 'h2',
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreHeading, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-heading')).not.toBeNull())
    const heading = canvasElement.querySelector('.core-heading')
    expect(heading.classList.contains('core-heading--lg')).toBe(true)
    expect(heading.querySelector('h2.core-heading__title')).not.toBeNull()
    expect(heading.querySelector('.core-heading__subtitle')).not.toBeNull()
    expect(heading.querySelector('.core-heading__slash')).toBeNull()
  },
}

export const Slash = {
  args: { size: 'md', title: 'Quests', subtitle: '', slash: true },
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreHeading, { ...args }),
    ]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'The marker is decoration: two aria-hidden spans, so a screen reader still reads only "Quests".',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-heading.has-slash')).not.toBeNull())
    const slash = canvasElement.querySelector('.core-heading__slash')
    expect(slash.getAttribute('aria-hidden')).toBe('true')
    expect(slash.querySelectorAll('span').length).toBe(2)
    expect(getComputedStyle(canvasElement.querySelector('.core-heading__text')).fontStyle).toBe('italic')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(HeadingGallery) }),
  parameters: {
    docs: {
      description: { story: 'Sizes, the slash, eyebrow/subtitle/actions, alignment and a slot title.' },
      story: { inline: false, height: '1400px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreHeading')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-heading').length).toBeGreaterThan(8)
    expect(canvasElement.querySelector('.core-heading--xl')).not.toBeNull()
    expect(canvasElement.querySelector('.core-heading--align-right')).not.toBeNull()
  },
}
