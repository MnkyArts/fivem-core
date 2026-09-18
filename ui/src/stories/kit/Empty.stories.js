// Kit/Data — CoreEmpty (DESIGN §37.5, Data — display).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreEmpty from '../../kit/components/CoreEmpty.vue'
import CoreTag from '../../kit/components/CoreTag.vue'
import { ICONS } from '../../kit/icons.js'
import EmptyGallery from './scenes/EmptyGallery.vue'

const ICON_NAMES = [''].concat(Object.keys(ICONS).sort())

const panel = {
  width: '520px',
  border: '1px solid var(--color-border)',
  borderRadius: 'var(--radius-ui)',
  background: 'var(--color-panel)',
}

export default {
  title: 'Kit/Data/Empty',
  component: CoreEmpty,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A list with nothing in it still has to say something. Framed glyph, one '
          + 'display-voice line, one sentence of what to do next — and the default slot for the button '
          + 'that does it. It is the `empty` slot of CoreTable and the body of an empty CoreSlotGrid. '
          + 'Any of the three pieces may be left out, so the same component covers "No messages" and '
          + 'a full three-part placeholder. Write the text as an instruction, not as an apology: the '
          + 'player wants to know what to do, not that the array has length 0.',
      },
    },
  },
  argTypes: {
    icon: { control: 'select', options: ICON_NAMES },
    title: { control: 'text' },
    text: { control: 'text' },
  },
  args: {
    icon: 'backpack',
    title: 'Nothing on you',
    text: 'Pick something up, or open a stash and drag it across. Your last three drops are still on the ground near Sandy Shores.',
  },
}

export const Playground = {
  // Spread the args inside the render function or the controls stop updating (../storeHelpers.js).
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h('div', { style: panel }, [h(CoreEmpty, { ...args })]),
    ]),
  }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Nothing on you')).toBeInTheDocument())
    expect(canvasElement.querySelector('.core-empty__icon svg.core-icon')).not.toBeNull()
    expect(canvasElement.querySelector('.core-empty__actions')).toBeNull()
  },
}

export const WithActions = {
  name: 'Playground — with actions',
  args: {
    icon: 'garage',
    title: 'Garage empty',
    text: 'Buy a vehicle at Premium Deluxe Motorsport, or ask a faction lead to transfer one to you.',
  },
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h('div', { style: panel }, [
        h(CoreEmpty, { ...args }, () => [
          h(CoreTag, { size: 'lg', variant: 'solid', tone: 'accent', icon: 'cart', label: 'Open the dealership' }),
          h(CoreTag, { size: 'lg', variant: 'outline', tone: 'neutral', icon: 'users', label: 'Ask the faction' }),
        ]),
      ]),
    ]),
  }),
  parameters: {
    docs: {
      description: {
        story: 'The default slot is the actions row and re-enables pointer events, so it works inside '
          + 'a click-through HUD panel. A page puts CoreButtons here — the story stands in with tags '
          + 'because a Data scene only reaches for its own group.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-empty__actions')).not.toBeNull())
    expect(getComputedStyle(canvasElement.querySelector('.core-empty__actions')).pointerEvents).toBe('auto')
  },
}

export const Minimal = {
  name: 'Playground — title only',
  args: { icon: '', title: 'No messages', text: '' },
  render: Playground.render,
  parameters: {
    docs: { description: { story: 'Nothing is required: a bare line is a perfectly good placeholder in a narrow column.' } },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('No messages')).toBeInTheDocument())
    expect(canvasElement.querySelector('.core-empty__icon')).toBeNull()
    expect(canvasElement.querySelector('.core-empty__text')).toBeNull()
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(EmptyGallery) }),
  parameters: {
    docs: {
      description: { story: 'The three shapes, the actions row, the minimal forms and the bare column a page drops into an existing surface.' },
      story: { inline: false, height: '1400px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreEmpty')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-empty').length).toBe(8)
    expect(canvasElement.querySelectorAll('.core-empty__actions').length).toBe(1)
  },
}
