// Kit/Forms/Schema Form — CoreSchemaForm (DESIGN §53 over the §43 vocabulary).
import { h, ref } from 'vue'
import { expect, waitFor } from 'storybook/test'
import CoreSchemaForm from '../../kit/components/CoreSchemaForm.vue'
import SchemaFormGallery from './scenes/SchemaFormGallery.vue'
import { BAN_FIELDS, RESOLVERS, SETTINGS_FIELDS } from './scenes/schemaFixtures.js'

export default {
  title: 'Kit/Forms/Schema Form',
  component: CoreSchemaForm,
  parameters: {
    layout: 'fullscreen',
    docs: {
      description: {
        component: 'Renders `Core.Schema.public(fields)` with kit controls: boolean → Switch · integer / number / heading → '
          + 'Number Input · string / password → Input · text → Textarea · reason → Textarea + template buttons · enum → '
          + 'Select (≤ 8), Chips (multiple, ≤ 8) or Combobox (> 8) · color → Color Picker · duration → presets + '
          + '`2h 30m` field · vector3 / rotation → Vector Input · model / player / ref / faction / item → Combobox over '
          + '`resolvers[type](query, field)` · array → rows · object → a nested group. `v-model` is the values object '
          + '(defaults fill the gaps), `errors` the server\'s `{ [path]: code }` map, `messages` rewords the codes. '
          + '`submit` carries the values when the advisory client check passes, `invalid` the error map otherwise; '
          + '`submit()` and `validate()` are exposed for a dialog footer.',
      },
      story: { inline: false, height: '720px' },
    },
  },
  argTypes: {
    inline: { control: 'boolean' },
    disabled: { control: 'boolean' },
    submitLabel: { control: 'text' },
    busy: { control: 'boolean' },
    fields: { control: false },
  },
  args: { inline: false, disabled: false, submitLabel: 'Ban player', busy: false },
}

export const Playground = {
  render: (args) => ({
    setup () {
      const values = ref({})
      const out = ref('—')
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '520px' } }, [
        h(CoreSchemaForm, {
          ...args,
          fields: BAN_FIELDS,
          resolvers: RESOLVERS,
          modelValue: values.value,
          'onUpdate:modelValue': (v) => { values.value = v },
          onSubmit: (v) => { out.value = 'submit ' + JSON.stringify(v) },
          onInvalid: (e) => { out.value = 'invalid ' + JSON.stringify(e) },
        }),
        h('p', { class: 'core-label', style: { marginTop: '14px' } }, out.value),
      ])
    },
  }),
  play: async ({ canvasElement, args }) => {
    const form = await waitFor(() => {
      const el = canvasElement.querySelector('.core-schemaform')
      expect(el).not.toBeNull()
      return el
    })
    expect(form.querySelectorAll('.core-field').length).toBe(4)
    expect(form.querySelector('.core-combobox')).not.toBeNull()
    expect(form.querySelectorAll('.core-schemaform__template').length).toBe(4)
    if (args.disabled || !args.submitLabel) return
    // An empty required player + reason: the client check refuses and marks both fields.
    form.dispatchEvent(new Event('submit', { bubbles: true, cancelable: true }))
    await waitFor(() => expect(form.querySelectorAll('.core-field.is-invalid').length).toBe(2))
  },
}

export const Settings = {
  name: 'Playground — settings rows',
  args: { inline: true, submitLabel: 'Save' },
  render: (args) => ({
    setup () {
      const values = ref({})
      return () => h('div', { class: 'pointer-events-auto', style: { padding: '48px', width: '760px' } }, [
        h(CoreSchemaForm, { ...args, fields: SETTINGS_FIELDS, modelValue: values.value, 'onUpdate:modelValue': (v) => { values.value = v } }),
      ])
    },
  }),
  play: async ({ canvasElement }) => {
    const form = await waitFor(() => {
      const el = canvasElement.querySelector('.core-schemaform')
      expect(el).not.toBeNull()
      return el
    })
    expect(form.querySelectorAll('.core-schemaform__group-title').length).toBe(3)
    // `hour` only shows with syncMode = fixed; `internal` is hidden for good.
    expect(form.textContent).not.toContain('Fixed hour')
    expect(form.textContent).not.toContain('never shown')
  },
}

export const Gallery = {
  render: () => ({ setup: () => () => h(SchemaFormGallery) }),
  parameters: {
    docs: {
      description: { story: 'The ban action, a settings section as inline rows, a map element with vectors / nested object / array, and the server error map.' },
      story: { inline: false, height: '1900px' },
    },
  },
  play: async ({ canvasElement }) => {
    await waitFor(() => expect(canvasElement.querySelectorAll('.core-schemaform').length).toBe(4))
    expect(canvasElement.querySelectorAll('.core-vector').length).toBeGreaterThan(2)
    expect(canvasElement.querySelector('.core-schemaform__array-row')).not.toBeNull()
    expect(canvasElement.querySelector('.core-schemaform__object')).not.toBeNull()
    expect(canvasElement.textContent).toContain('That player is not online any more.')
  },
}
