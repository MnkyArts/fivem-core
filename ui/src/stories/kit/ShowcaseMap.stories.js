// Kit/Showcase Map — mockup 4 rebuilt from kit components only (DESIGN §37.7).
// The completeness proof for a world map: the `//` CoreHeading, CoreChips, the CoreList of quests,
// the media-top CoreCard, CoreObjective, the icon CoreCheckbox rows and the footer CoreKeyHints,
// with a CoreDialog on TRACK QUEST. Art in stories/kit/assets is Storybook-only.
import { h } from 'vue'
import { within, expect, waitFor, userEvent } from 'storybook/test'
import ShowcaseMap from './scenes/ShowcaseMap.vue'

export default {
  title: 'Kit/Showcase/Map',
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Mockup 4 at 1920 × 1080, built from `<Core…>` tags, Tailwind layout utilities and the '
          + 'base type classes — no custom CSS and no literal colours. Chips filter the quest list, picking '
          + 'a quest re-reads the detail card and the objective, the map filters toggle, TRACK QUEST opens '
          + 'a CoreDialog.',
      },
      story: { inline: false, height: '1000px' },
    },
  },
}

export const Screen = {
  render: () => ({ setup: () => () => h(ShowcaseMap) }),
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvasElement.querySelector('.core-screen')).not.toBeNull())

    expect(canvasElement.querySelectorAll('.core-panel').length).toBe(2)
    expect(canvasElement.querySelectorAll('.core-listitem').length).toBe(4)
    expect(canvasElement.querySelectorAll('.core-check').length).toBe(6)
    await waitFor(() => expect(canvas.getByText('A Brighter Tomorrow')).toBeInTheDocument())

    // A chip filters the list down to the side quests…
    await userEvent.click(canvas.getByRole('button', { name: /^side$/i }))
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-listitem').length).toBe(2))

    // …and the selection follows, so the card never shows a quest the list has hidden
    // (the name is then on screen twice: the list row and the detail card).
    await waitFor(() => expect(canvas.getAllByText('Supply Lines').length).toBe(2))

    // The second row re-reads the card.
    await userEvent.click(canvasElement.querySelectorAll('.core-listitem')[1])
    await waitFor(() => expect(canvas.getAllByText('Echoes in the Hills').length).toBe(2))
  },
}
