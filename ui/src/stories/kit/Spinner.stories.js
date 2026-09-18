// Kit/Data/Spinner — CoreSpinner and its sibling CoreSkeleton, the kit's two waiting states
// (DESIGN §37.5, Data — meters). They share one file because they answer the same question.
//
// Not to be confused with `Built-ins/Spinner` one folder up: that story drives the SHELL's busy
// pill through `spinner:show` (§21). This one is the kit component the pill is built from (§37.6).
import { h } from 'vue'
import { within, expect, waitFor } from 'storybook/test'
import CoreSpinner from '../../kit/components/CoreSpinner.vue'
import CoreSkeleton from '../../kit/components/CoreSkeleton.vue'
import { METER_TONES } from '../../kit/use.js'
import SpinnerGallery from './scenes/SpinnerGallery.vue'

export default {
  title: 'Kit/Data/Spinner & Skeleton',
  component: CoreSpinner,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'For work with no measurable progress — a server round trip, a database write, waiting '
          + 'on another player. One ring with a single lit border side over a white 20 % circle, exactly '
          + 'like the shell\'s busy pill. When you DO know how far along you are, use CoreProgress (or '
          + 'CoreProgress `indeterminate` when the bar itself is the layout). Its sibling CoreSkeleton is '
          + 'in this file too: use it when the LAYOUT is already known and only the data is missing.',
      },
      story: { inline: false, height: '220px' },
    },
  },
  argTypes: {
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'], description: '14 / 18 / 24 px, or a number.' },
    tone: { control: 'select', options: METER_TONES },
    label: { control: 'text', description: 'Optional caption after the ring, in the label voice.' },
  },
  args: { size: 'md', tone: 'accent', label: 'Contacting dispatch' },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
      h(CoreSpinner, { ...args }),
    ]),
  }),
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-spinner')).not.toBeNull())
    const root = canvasElement.querySelector('.core-spinner')
    expect(root.getAttribute('role')).toBe('status')
    expect(root.getAttribute('aria-label')).toBe('Contacting dispatch')
    expect(root.classList.contains('core-tone-accent')).toBe(true)
    const ring = root.querySelector('.core-spinner__ring')
    expect(ring.style.width).toBe('18px')
    expect(getComputedStyle(ring).animationName).toBe('core-spin')
  },
}

export const Skeleton = {
  // The file's shared args belong to the spinner; drop them here so they do not land on the
  // skeleton's root as stray attributes. The destructuring happens INSIDE the render function, so
  // the args proxy is still read reactively and the controls stay live.
  render: (args) => ({
    setup: () => () => {
      const { size, tone, label, ...own } = args
      return h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '520px' } }, [
        h(CoreSkeleton, { ...own }),
      ])
    },
  }),
  argTypes: {
    width: { control: 'text', description: 'A number is px, a string passes through.' },
    height: { control: { type: 'range', min: 4, max: 80, step: 1 }, description: 'One line, in px.' },
    lines: { control: { type: 'range', min: 1, max: 8, step: 1 } },
    radius: { control: 'text', description: 'A number is px. Default: the 3 px chip radius.' },
    size: { table: { disable: true } },
    tone: { table: { disable: true } },
    label: { table: { disable: true } },
  },
  args: { width: '100%', height: 14, lines: 3, radius: '' },
  parameters: {
    docs: {
      description: {
        story: 'CoreSkeleton holds the shape of what is coming, so the page does not jump when the data '
          + 'lands. A multi-line block ends short, the way a real paragraph does. It is `aria-hidden`: the '
          + 'loading state is announced by whatever asked for the data.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelector('.core-skeleton')).not.toBeNull())
    const root = canvasElement.querySelector('.core-skeleton')
    expect(root.getAttribute('aria-hidden')).toBe('true')
    expect(root.querySelectorAll('.core-skeleton__line').length).toBe(3)
    expect(getComputedStyle(root.querySelector('.core-skeleton__line')).animationName).toBe('core-shimmer')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(SpinnerGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: { story: 'Spinner sizes, tones and labels, the busy pill, and skeletons in the shape of a slot grid, an item card and a list.' },
      story: { inline: false, height: '900px' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('CoreSpinner & CoreSkeleton')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-spinner').length).toBeGreaterThan(10)
    expect(canvasElement.querySelectorAll('.core-skeleton').length).toBeGreaterThan(8)
    // The stroke grows with the ring: 2 px at 14, 3 px at 24 and above.
    const lg = [...canvasElement.querySelectorAll('.core-spinner__ring')].filter((el) => el.style.width === '40px')
    expect(lg.length).toBe(1)
    expect(lg[0].style.getPropertyValue('--core-spinner-w')).toBe('5px')
  },
}
