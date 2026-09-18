// Kit/Forms Select — CoreSelect (DESIGN §37.5, Forms — text).
//
// Two shapes from one component: `box` is the form control, `inline` is the inventory mockup's
// chrome-free `SORT: RECENT v`. Focus never leaves the trigger — the popup is a real `listbox`
// driven by aria-activedescendant — and it is teleported into #core-overlays, placed by
// useFloating and closed by its own Escape layer, so Escape never reaches the shell's page store.
import { h, ref } from 'vue'
import { within, userEvent, expect, waitFor } from 'storybook/test'
import CoreSelect from '../../kit/components/CoreSelect.vue'
import SelectGallery from './scenes/SelectGallery.vue'

const SORTS = [
  { value: 'recent', label: 'Recent' },
  { value: 'name', label: 'Name' },
  { value: 'weight', label: 'Weight' },
  { value: 'value', label: 'Value' },
  { value: 'rarity', label: 'Rarity' },
]

export default {
  title: 'Kit/Forms/Select',
  component: CoreSelect,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'The dropdown. Items are the `items` vocabulary of §37.4 — strings or '
          + '`{ value, label, icon?, description?, disabled? }`. Space/Enter/↓ open, ↑/↓ move, Enter picks, '
          + 'typing jumps to a label, Escape and an outside click close. Use `box` in a form and `inline` for a '
          + 'sort or filter caption in a heading row; for two or three options that all fit on screen use '
          + 'CoreChips or CoreRadioGroup instead — a dropdown hides what it contains.',
      },
      story: { inline: false, height: '320px' },
    },
  },
  argTypes: {
    modelValue: { control: 'select', options: SORTS.map((s) => s.value) },
    variant: { control: 'inline-radio', options: ['box', 'inline'] },
    size: { control: 'inline-radio', options: ['sm', 'md', 'lg'] },
    placement: { control: 'inline-radio', options: ['auto', 'bottom', 'top'] },
    label: { control: 'text', description: 'Caption before the value — the colon is part of the string.' },
    placeholder: { control: 'text' },
    maxHeight: { control: 'number' },
    invalid: { control: 'boolean' },
    disabled: { control: 'boolean' },
  },
  args: {
    modelValue: 'recent',
    variant: 'box',
    size: 'md',
    placement: 'auto',
    label: '',
    placeholder: 'Select…',
    maxHeight: 260,
    invalid: false,
    disabled: false,
  },
}

export const Playground = {
  render: (args) => ({
    setup: () => () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', maxWidth: '300px' } },
      h(CoreSelect, { ...args, items: SORTS, 'onUpdate:modelValue': (v) => { args.modelValue = v } })),
  }),
  play: async ({ canvasElement }) => {
    const trigger = canvasElement.querySelector('.core-selectbox__trigger')
    await userEvent.click(trigger)
    // The popup is TELEPORTED, so it lives outside canvasElement — look it up on the document.
    const popup = await waitFor(() => {
      const el = document.querySelector('.core-selectbox__popup')
      expect(el).not.toBeNull()
      return el
    })
    expect(trigger.getAttribute('aria-expanded')).toBe('true')
    expect(popup.getAttribute('role')).toBe('listbox')
    await userEvent.click(popup.querySelectorAll('.core-selectbox__option')[2])
    await waitFor(() => expect(document.querySelector('.core-selectbox__popup')).toBeNull())
    expect(canvasElement.querySelector('.core-selectbox__value').textContent.trim()).toBe('Weight')
  },
}

export const Inline = {
  name: 'Inline (the mockup)',
  args: { variant: 'inline', label: 'SORT:' },
  render: (args) => ({
    setup: () => {
      const value = ref('recent')
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px' } }, [
        h('div', {
          style: {
            display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between',
            maxWidth: '640px', paddingBottom: '18px', borderBottom: '1px solid var(--color-border)',
          },
        }, [
          h('div', [
            h('h2', { class: 'core-display core-display--lg' }, 'Inventory'),
            h('p', { class: 'core-eyebrow', style: { marginTop: '12px' } }, 'Gear up for what’s next.'),
          ]),
          h(CoreSelect, {
            ...args,
            items: SORTS,
            modelValue: value.value,
            'onUpdate:modelValue': (v) => { value.value = v },
          }),
        ]),
      ])
    },
  }),
  parameters: {
    docs: {
      description: {
        story: 'The inventory mockup\'s grid header: no border, no fill, nothing but type — a caption in the '
          + 'label voice, the value in the display voice and a wide chevron that turns when the list opens.',
      },
    },
  },
}

export const Keyboard = {
  name: 'Keyboard and Escape layers',
  render: Playground.render,
  parameters: {
    docs: {
      description: {
        story: 'The trigger keeps focus the whole time, so every key is handled in one place. Escape is a kit '
          + 'escape LAYER (a capturing window listener that stops the event), which is why the first Escape '
          + 'closes only the list and the shell\'s own Escape handler never sees it.',
      },
    },
  },
  play: async ({ canvasElement }) => {
    const trigger = canvasElement.querySelector('.core-selectbox__trigger')
    trigger.focus()
    await userEvent.keyboard('{ArrowDown}')
    await waitFor(() => expect(document.querySelector('.core-selectbox__popup')).not.toBeNull())
    await userEvent.keyboard('{ArrowDown}{ArrowDown}{Enter}')
    await waitFor(() => expect(document.querySelector('.core-selectbox__popup')).toBeNull())
    expect(canvasElement.querySelector('.core-selectbox__value').textContent.trim()).toBe('Weight')
    // Typing jumps to a label.
    await userEvent.keyboard('r')
    const popup = await waitFor(() => {
      const el = document.querySelector('.core-selectbox__popup')
      expect(el).not.toBeNull()
      return el
    })
    expect(popup.querySelector('.core-selectbox__option.is-active').textContent.trim()).toBe('Recent')
    await userEvent.keyboard('{Escape}')
    await waitFor(() => expect(document.querySelector('.core-selectbox__popup')).toBeNull())
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(SelectGallery) }),
  parameters: {
    layout: 'fullscreen',
    docs: {
      story: { inline: false, height: '1100px' },
      description: { story: 'The mockup header, both variants in every size, icons and descriptions, states.' },
    },
  },
  play: async ({ canvasElement }) => {
    const canvas = within(canvasElement)
    await waitFor(() => expect(canvas.getByText('Select')).toBeInTheDocument())
    expect(canvasElement.querySelectorAll('.core-selectbox--inline').length).toBeGreaterThan(3)
    expect(canvasElement.querySelector('.core-selectbox.is-disabled')).not.toBeNull()
    expect(canvasElement.querySelector('.core-selectbox.is-invalid')).not.toBeNull()
  },
}
