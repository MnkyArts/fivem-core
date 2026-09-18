// Kit/Forms/Switch — CoreSwitch (DESIGN §37.5, Forms — choice).
//
// The settings-row control: a squared 42 x 22 track (radius 3, like a key cap and a checkbox — the
// kit has no pills) with a 16 px white thumb that slides onto the accent gradient.
import { h, ref } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreSwitch from '../../kit/components/CoreSwitch.vue'
import SwitchGallery from './scenes/SwitchGallery.vue'

export default {
  title: 'Kit/Forms/Switch',
  component: CoreSwitch,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'An on/off that takes effect the moment it is flipped — HUD elements, push to talk, '
          + 'streamer mode. A checkbox is the one to use when the choice is only committed later (a form '
          + 'with a Save button) or when several boxes feed one array. The native input is visually hidden '
          + 'but never `display: none`, so it keeps its place in the tab order and the track shows the '
          + 'focus ring through the `+` combinator.',
      },
      story: { inline: false, height: '220px' },
    },
  },
  argTypes: {
    label: { control: 'text' },
    description: { control: 'text' },
    labelPosition: { control: 'inline-radio', options: ['left', 'right'] },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    disabled: { control: 'boolean' },
  },
  args: {
    label: 'Push to talk',
    description: 'Off = open mic on the proximity channel.',
    labelPosition: 'left',
    size: 'md',
    disabled: false,
  },
}

export const Playground = {
  render: (args) => ({
    setup() {
      const on = ref(true)
      return () => h('div', { style: { padding: '48px', width: '480px' } }, [
        h(CoreSwitch, {
          ...args,
          style: { width: '100%' },
          modelValue: on.value,
          'onUpdate:modelValue': (v) => { on.value = v },
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const input = await waitFor(() => {
      const el = canvasElement.querySelector('.core-switch__input')
      expect(el).not.toBeNull()
      return el
    })
    expect(input.checked).toBe(true)
    expect(input.getAttribute('role')).toBe('switch')
    input.click()
    await waitFor(() => expect(canvasElement.querySelector('.core-switch').className).not.toContain('is-on'))
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(SwitchGallery) }),
  parameters: {
    docs: {
      description: { story: 'A real settings page, both label positions, the sizes, every state and the bare switch.' },
      story: { inline: false, height: '1400px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Push to talk')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-switch').length).toBeGreaterThan(12)
    expect(canvasElement.querySelectorAll('.core-switch.is-on').length).toBeGreaterThan(5)
    expect(canvasElement.querySelector('.core-switch__input:disabled')).not.toBeNull()
  },
}
