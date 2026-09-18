// Kit/Navigation/Chips — CoreChips, the quest filter row of the mockups (DESIGN §37.5, Navigation).
import { h } from 'vue'
import { within, expect, waitFor, userEvent } from 'storybook/test'
import CoreChips from '../../kit/components/CoreChips.vue'
import ChipsGallery from './scenes/ChipsGallery.vue'

const QUESTS = ['All', 'Main', 'Side', 'Completed']

export default {
  title: 'Kit/Navigation/Chips',
  component: CoreChips,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Filter chips and segmented controls: the selected chip is solid coral with no border, '
          + 'the rest are outlined wells. `multiple` turns the model into an ARRAY and every chip into its '
          + 'own toggle; `allowEmpty` decides whether the last active chip can be switched off (a filter row '
          + 'that selects nothing usually shows nothing, so the default is no). ←/→ move the FOCUS only — a '
          + 'chip is a toggle, so arrowing onto one must not silently change the filter; Space or Enter does. '
          + 'For the screens of a page use CoreTabs instead.',
      },
      story: { inline: false, height: '200px' },
    },
  },
  argTypes: {
    items: { control: 'object', description: '`[{ value, label, icon?, count?, disabled? }]`, or plain strings.' },
    multiple: { control: 'boolean', description: 'The model becomes an array of values.' },
    allowEmpty: { control: 'boolean', description: 'Clicking the active chip clears it (single: to null).' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'], description: 'Chip 28 / 36 / 44 px.' },
    wrap: { control: 'boolean', description: 'Wrap onto more lines instead of one row.' },
    stretch: { control: 'boolean', description: 'Equal-width cells filling the row (the map filter bar).' },
    minWidth: { control: 'number', description: 'A floor under every chip, in px — short labels keep their neighbours\' width.' },
  },
  args: { items: QUESTS, multiple: false, allowEmpty: false, size: 'md', wrap: false, stretch: false, minWidth: 0 },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '56px 48px' } }, [
      h(CoreChips, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Completed')).toBeInTheDocument())
    const chips = canvasElement.querySelectorAll('.core-chip')
    await userEvent.click(chips[2])
    expect(chips[2].classList.contains('is-active')).toBe(true)
    expect(chips[2].getAttribute('aria-pressed')).toBe('true')
    // allowEmpty is off: clicking the active chip again keeps it.
    await userEvent.click(chips[2])
    expect(chips[2].classList.contains('is-active')).toBe(true)
    // One tab stop, and ←/→ move the focus without toggling anything.
    expect(canvasElement.querySelectorAll('.core-chip[tabindex="0"]').length).toBe(1)
    await userEvent.keyboard('{ArrowRight}')
    expect(document.activeElement).toBe(chips[3])
    expect(chips[3].classList.contains('is-active')).toBe(false)
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ChipsGallery) }),
  parameters: { docs: { story: { inline: false, height: '1400px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreChips')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-chips').length).toBeGreaterThan(6)
    expect(canvasElement.querySelector('.core-chips--wrap')).not.toBeNull()
    expect(canvasElement.querySelector('.core-chips--stretch')).not.toBeNull()
    expect(canvasElement.querySelector('.core-chip:disabled')).not.toBeNull()
    // The multiple row really holds three active chips at once.
    expect(canvasElement.querySelectorAll('.core-chips .core-chip.is-active').length).toBeGreaterThan(6)
  },
}
