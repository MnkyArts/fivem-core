// Kit/Game/Objective — CoreObjective and CoreTracker (DESIGN §37.5, Game).
// One file: the tracker is the HUD half of the same idea and renders CoreObjectives itself, so
// the two are always looked at together.
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreObjective from '../../kit/components/CoreObjective.vue'
import CoreTracker from '../../kit/components/CoreTracker.vue'
import ObjectiveGallery from './scenes/ObjectiveGallery.vue'

export default {
  title: 'Kit/Game/Objective & Tracker',
  component: CoreObjective,
  subcomponents: { CoreTracker },
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'One checklist line: an 18 px ring and a line of copy. The ring carries the whole '
          + 'state — hollow, coral ring + dot while active, filled with a check when done, an error cross '
          + 'with struck text when failed. CoreTracker is the HUD card of mockup 2 that stacks a few of '
          + 'them under a title; both are painted over the world and take no mouse.',
      },
      story: { inline: false, height: '260px' },
    },
  },
  argTypes: {
    text: { control: 'text' },
    state: { control: 'inline-radio', options: ['open', 'active', 'done', 'failed'] },
    trailing: { control: 'text', description: 'Right-hand value: a distance, a count, a timer.' },
    optional: { control: 'boolean', description: 'Marks the line as a bonus objective.' },
  },
  args: { text: 'Meet the contact at the old tower', state: 'active', trailing: '842 m', optional: false },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', maxWidth: '620px' } }, [
      h(CoreObjective, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-objective')).not.toBeNull())
    const objective = canvasElement.querySelector('.core-objective')
    expect(objective.classList.contains('is-active')).toBe(true)
    expect(canvasElement.querySelector('.core-objective__ring')).not.toBeNull()
    expect(canvasElement.querySelector('.core-objective__trailing').textContent.trim()).toBe('842 m')
  },
}

export const Tracker = {
  render: () => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreTracker, {
        title: 'A Brighter Tomorrow',
        text: 'Meet the contact at the old tower.',
        distance: '842 m',
      }),
    ]),
  }),
  parameters: {
    docs: { description: { story: 'The HUD card of mockup 2: the amber pin, a hairline running down out of it, and the distance row.' } },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-tracker')).not.toBeNull())
    const card = canvasElement.querySelector('.core-tracker')
    expect(card.classList.contains('core-tone-warning')).toBe(true)
    expect(getComputedStyle(card).pointerEvents).toBe('none')
    expect(canvasElement.querySelector('.core-tracker__title').textContent.trim()).toBe('A Brighter Tomorrow')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(ObjectiveGallery) }),
  parameters: {
    docs: {
      description: { story: 'The mockup tracker, three tones with nested objectives, and all four objective states including a bonus line.' },
      story: { inline: false, height: '1200px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    // The DOM text is Title Case; `core-tracker__title` only uppercases it in CSS.
    await waitFor(() => expect(canvas.getByText('A Brighter Tomorrow')).toBeInTheDocument())
    expect(canvasElement.querySelector('.core-objective.is-done')).not.toBeNull()
    expect(canvasElement.querySelector('.core-objective.is-failed')).not.toBeNull()
    expect(canvasElement.querySelectorAll('.core-tracker').length).toBe(5)
    expect(canvasElement.querySelectorAll('.core-tracker.has-bloom').length).toBe(4)
  },
}
