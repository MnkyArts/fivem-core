// Kit/Actions Prompt — CorePrompt and CorePromptGroup (DESIGN §37.5, Actions).
import { h } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import CorePrompt from '../../kit/components/CorePrompt.vue'
import CorePromptGroup from '../../kit/components/CorePromptGroup.vue'
import PromptGallery from './scenes/PromptGallery.vue'
import keyart from './assets/keyart.jpg'

const VEHICLE = [
  { keys: 'F', label: 'Enter vehicle', icon: 'steering' },
  { keys: 'R', label: 'Open trunk', icon: 'toolbox' },
  { keys: ['SHIFT', 'F'], label: 'Enter as passenger', icon: 'users' },
]

// The prompt only reads over the game, so both stories bring a frame of it.
const over = (child, height) => h('div', {
  class: 'pointer-events-auto',
  style: {
    padding: '48px',
    minHeight: height,
    backgroundImage: 'url(' + keyart + ')',
    backgroundSize: 'cover',
    backgroundPosition: 'center',
  },
}, [child])

export default {
  title: 'Kit/Actions/Prompt & Prompt Group',
  component: CorePrompt,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The world interaction prompt: a solid `lg` cap, then a plate that is opaque under the '
          + 'label and gone by its right edge, so the line sits on the game instead of in a box. It is a HUD '
          + 'element, so it is click-through — `interactive` is what turns the mouse on, and only then is the '
          + 'root a real `<button>`. `progress` drives the hold bar on the cap(s); `active` lights the cap '
          + 'coral for the interaction the player is actually looking at. CorePromptGroup stacks the options '
          + 'one interaction point offers.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    keys: { control: 'text' },
    label: { control: 'text' },
    icon: { control: 'text', description: 'Registry name or raw path.' },
    description: { control: 'text', description: 'Second line, sans, dim.' },
    progress: { control: { type: 'range', min: 0, max: 1, step: 0.01 } },
    active: { control: 'boolean', description: 'Lit — the cap turns coral.' },
    disabled: { control: 'boolean' },
    interactive: { control: 'boolean', description: 'Takes the mouse and becomes a button.' },
  },
  args: {
    keys: 'F',
    label: 'Enter vehicle',
    icon: 'steering',
    description: '',
    progress: 0,
    active: false,
    disabled: false,
    interactive: false,
  },
}

export const Playground = {
  render: (args) => ({ setup: () => () => over(h(CorePrompt, { ...args }), '160px') }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-prompt')).not.toBeNull())
    const prompt = canvasElement.querySelector('.core-prompt')
    // Click-through until `interactive`, and the cap is the lg one.
    expect(getComputedStyle(prompt).pointerEvents).toBe('none')
    expect(prompt.querySelector('.core-key--lg')).not.toBeNull()
    expect(prompt.querySelector('.core-prompt__band')).not.toBeNull()
  },
}

export const Group = {
  name: 'CorePromptGroup',
  render: () => ({ setup: () => () => over(h(CorePromptGroup, { items: VEHICLE }), '200px') }),
  parameters: {
    controls: { disable: true },
    docs: { description: { story: 'Every option one interaction point offers — column, 8 px apart, still click-through.' } },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-prompt').length).toBe(3))
    expect(canvasElement.querySelectorAll('.core-prompts')[0].className).toContain('core-prompts--start')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(PromptGallery) }),
  parameters: {
    controls: { disable: true },
    backgrounds: { value: 'night' },
    docs: {
      story: { inline: false, height: '1500px' },
      description: { story: 'The mockup\'s two prompts, the states, a hold that runs, and the one prompt that takes the mouse.' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CorePrompt')).toBeInTheDocument())

    // `interactive` clicks, `disabled` does not — even when it is interactive.
    const count = canvasElement.querySelector('[data-role=count]')
    const trunk = canvasElement.querySelector('[data-role=trunk]')
    const dead = canvasElement.querySelector('[data-role=dead]')
    expect(trunk.tagName).toBe('BUTTON')
    await userEvent.click(trunk)
    await waitFor(() => expect(count.textContent).toContain('opened 1x'))
    await userEvent.click(dead, { pointerEventsCheck: 0 })
    expect(count.textContent).toContain('opened 1x')
  },
}
