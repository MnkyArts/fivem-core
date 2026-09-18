// Kit/Navigation/Stepper — CoreStepper, the `‹ value ›` cycler (DESIGN §37.5, Navigation).
import { h } from 'vue'
import { within, expect, waitFor, userEvent } from 'storybook/test'
import CoreStepper from '../../kit/components/CoreStepper.vue'
import StepperGallery from './scenes/StepperGallery.vue'

const PLATES = ['Standard White', 'Yellow Plates', 'Blue on White', 'North Yankton', 'Ecola']

export default {
  title: 'Kit/Navigation/Stepper',
  component: CoreStepper,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'One value between two chevrons, in the shared box look. Pass `items` and it walks their '
          + 'values (skipping disabled ones and showing the label); leave `items` out and it is a number '
          + 'between `min` and `max`. It is ONE tab stop — the centre is a `role="spinbutton"` and ←/→ step '
          + 'it wherever the focus sits inside the box — and without `loop` the chevron at the end of the '
          + 'range disables itself. Use it where a dropdown would be overkill (a character option, a setting '
          + 'with five values); for many options use CoreSelect.',
      },
      story: { inline: false, height: '200px' },
    },
  },
  argTypes: {
    items: { control: 'object', description: 'Present: the stepper cycles these instead of numbers.' },
    min: { control: 'number', description: 'Numeric mode lower bound.' },
    max: { control: 'number', description: 'Numeric mode upper bound.' },
    step: { control: 'number', description: 'Numeric mode increment.' },
    loop: { control: 'boolean', description: 'Wrap around the ends instead of stopping.' },
    showCount: { control: 'boolean', description: 'Print `3 / 24` after the label — meant for `items` mode.' },
    block: { control: 'boolean', description: 'Fill the width of the row.' },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'], description: 'Box 30 / 40 / 52 px.' },
    disabled: { control: 'boolean' },
  },
  args: { items: PLATES, min: 0, max: 100, step: 1, loop: true, showCount: true, block: false, size: 'md', disabled: false },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '56px 48px' } }, [
      h(CoreStepper, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Standard White')).toBeInTheDocument())
    const next = canvasElement.querySelector('.core-stepper__btn--next')
    const label = canvasElement.querySelector('.core-stepper__label')
    await userEvent.click(next)
    expect(label.textContent.trim()).toBe('Yellow Plates')
    expect(canvasElement.querySelector('.core-stepper__count').textContent.trim()).toBe('2 / 5')
    // ←/→ work from the spinbutton, which is the control's single tab stop.
    const value = canvasElement.querySelector('.core-stepper__value')
    expect(value.getAttribute('role')).toBe('spinbutton')
    value.focus()
    await userEvent.keyboard('{ArrowLeft}')
    expect(label.textContent.trim()).toBe('Standard White')
    // loop is on: one more step back wraps to the last plate.
    await userEvent.keyboard('{ArrowLeft}')
    expect(label.textContent.trim()).toBe('Ecola')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(StepperGallery) }),
  parameters: { docs: { story: { inline: false, height: '1300px' } } },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreStepper')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-stepper').length).toBeGreaterThan(7)
    expect(canvasElement.querySelector('.core-stepper--block')).not.toBeNull()
    expect(canvasElement.querySelector('.core-stepper.is-disabled')).not.toBeNull()
    // No loop on the tint row: at 0 the back chevron is dead.
    expect(canvasElement.querySelector('.core-stepper__btn:disabled')).not.toBeNull()
  },
}
