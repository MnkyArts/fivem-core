// Kit/Forms/Slider — CoreSlider (DESIGN §37.5, Forms — choice).
//
// The character creator and the audio settings. A real <input type="range"> under the paint, so the
// keyboard (arrows, Home/End, Page Up/Down) and the step maths are the browser's; the kit only owns
// the track gradient, the thumb tile and the read-out.
import { h, ref } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreSlider from '../../kit/components/CoreSlider.vue'
import SliderGallery from './scenes/SliderGallery.vue'

export default {
  title: 'Kit/Forms/Slider',
  component: CoreSlider,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'A number picked by feel rather than typed: a face morph, a volume, a bounty. The fill '
          + 'is a two-stop gradient on the track cut at `--core-slider-pct`, so there is no second element '
          + 'to keep in sync. `update:modelValue` fires on every pixel of the drag and `change` once on '
          + 'release — put the ped re-render or the server call on `change`. When the exact digits matter, '
          + 'use CoreNumberInput instead.',
      },
      story: { inline: false, height: '240px' },
    },
  },
  argTypes: {
    label: { control: 'text' },
    min: { control: 'number' },
    max: { control: 'number' },
    step: { control: 'number' },
    showValue: { control: 'boolean' },
    suffix: { control: 'text' },
    minLabel: { control: 'text' },
    maxLabel: { control: 'text' },
    ticks: { control: 'boolean' },
    tone: { control: 'select', options: ['accent', 'neutral', 'success', 'warning', 'danger', 'info'] },
    disabled: { control: 'boolean' },
  },
  args: {
    label: 'Master volume',
    min: 0,
    max: 100,
    step: 1,
    showValue: true,
    suffix: '%',
    minLabel: '',
    maxLabel: '',
    ticks: false,
    tone: 'accent',
    disabled: false,
  },
}

export const Playground = {
  render: (args) => ({
    setup() {
      const value = ref(72)
      return () => h('div', { style: { padding: '48px', width: '520px' } }, [
        h(CoreSlider, {
          ...args,
          modelValue: value.value,
          'onUpdate:modelValue': (v) => { value.value = v },
        }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const input = await waitFor(() => {
      const el = canvasElement.querySelector('.core-slider__input')
      expect(el).not.toBeNull()
      return el
    })
    expect(input.value).toBe('72')
    // The fill is the inline percentage, not a second element.
    expect(canvasElement.querySelector('.core-slider').style.getPropertyValue('--core-slider-pct')).toBe('72%')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(SliderGallery) }),
  parameters: {
    docs: {
      description: { story: 'A character-creator block, audio settings, ticks and formats, every tone, input vs change, disabled.' },
      story: { inline: false, height: '1800px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Nose width')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-slider__input').length).toBeGreaterThan(14)
    expect(canvasElement.querySelectorAll('.core-slider__tick').length).toBeGreaterThan(8)
    expect(canvasElement.querySelector('.core-tone-success')).not.toBeNull()
  },
}
