// Kit/Forms/Radio — CoreRadioGroup + CoreRadio (DESIGN §37.5, Forms — choice).
//
// Two components, one file: a radio never appears without its group's contract, and the `card`
// variant is the same control with a tile around it. The ring language is the objective ring of
// the map mockup — a thin bright circle, filled with a coral dot when it is the one you picked.
import { h, ref } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreRadioGroup from '../../kit/components/CoreRadioGroup.vue'
import CoreRadio from '../../kit/components/CoreRadio.vue'
import RadioGallery from './scenes/RadioGallery.vue'

const SPAWNS = [
  { value: 'apartment', label: 'Apartment', description: 'Mirror Park, 4 Blvd — your own bed.' },
  { value: 'garage', label: 'Garage', description: 'Vehicles stay where you parked them.' },
  { value: 'hospital', label: 'Pillbox Hill Medical', description: 'Closest respawn, no vehicle.' },
  { value: 'faction', label: 'Faction HQ', description: 'Needs a rank of Lieutenant or above.', disabled: true },
]

export default {
  title: 'Kit/Forms/Radio & Radio Group',
  component: CoreRadioGroup,
  subcomponents: { CoreRadio },
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'One choice out of a few, all of them visible. The group provides `{ model, name, '
          + 'disabled, size, variant }` to every CoreRadio by inject, so a radio written by hand inside the '
          + 'default slot behaves exactly like one rendered from `items`; alone, a CoreRadio falls back to '
          + 'its own `v-model`. Arrow keys are the browser\'s, because the inputs are real radios sharing a '
          + '`name`. More than about six options belong in a CoreSelect instead.',
      },
      story: { inline: false, height: '360px' },
    },
  },
  argTypes: {
    orientation: { control: 'inline-radio', options: ['vertical', 'horizontal'] },
    variant: { control: 'inline-radio', options: ['radio', 'card'] },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    disabled: { control: 'boolean' },
  },
  args: { orientation: 'vertical', variant: 'card', size: 'md', disabled: false },
}

export const Playground = {
  render: (args) => ({
    setup() {
      const spawn = ref('apartment')
      return () => h('div', { style: { padding: '48px', maxWidth: '520px' } }, [
        h(CoreRadioGroup, {
          ...args,
          items: SPAWNS,
          modelValue: spawn.value,
          'onUpdate:modelValue': (v) => { spawn.value = v },
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const radios = await waitFor(() => {
      const list = canvasElement.querySelectorAll('.core-radio input[type="radio"]')
      expect(list.length).toBe(4)
      return list
    })
    expect(radios[0].checked).toBe(true)
    expect(radios[3].disabled).toBe(true)
    radios[1].click()
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-radio')[1].className).toContain('is-checked'))
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(RadioGallery) }),
  parameters: {
    docs: {
      description: { story: 'Cards, rings, both orientations, the sizes, a disabled group, standalone radios and the `item` slot.' },
      story: { inline: false, height: '1600px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Bank transfer')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-radio--card').length).toBe(4)
    // Every group shares one name per group, and each group has exactly one checked option.
    expect(canvasElement.querySelectorAll('.core-radio.is-checked').length).toBeGreaterThan(4)
  },
}
