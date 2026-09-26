<script setup>
// SchemaFormGallery — CoreSchemaForm (DESIGN §53 over §43): the ban action in a dialog-sized panel
// (player resolver, duration presets, reason templates), a settings section as inline rows (groups,
// order, visibleWhen, every scalar type, a read-only and a hidden field), a map element (vectors,
// heading, model, nested object, array of objects) and the server's error map.
import { ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'
import { BAN_FIELDS, ELEMENT_FIELDS, RESOLVERS, SETTINGS_FIELDS } from './schemaFixtures.js'

const ban = ref({})
const settings = ref({})
const element = ref({})
const submitted = ref('—')
const errored = ref({ target: 13 })
const SERVER_ERRORS = { target: 'custom:That player is not online any more.', duration: 'max', reason: 'length' }
const errFields = BAN_FIELDS.map((f) => (f.name === 'duration' ? Object.assign({}, f, { max: 604800 }) : f))

const PANEL = 'padding: 20px 22px; border: 1px solid var(--color-border); border-radius: var(--radius-ui);'
  + ' background: var(--color-panel); box-shadow: var(--shadow-ui)'
</script>

<template>
  <KitStage
    title="CoreSchemaForm"
    description="One renderer for settings, admin action arguments and map element fields: `Core.Schema.public` in,
      kit controls out. Hidden fields are skipped, the rest ordered by `order` under their `group`; `visibleWhen`
      re-evaluates on every change; `errors` (the server's map) always wins over the advisory client check."
    :width="1180"
  >
    <div class="grid gap-10" style="grid-template-columns: 460px 1fr; align-items: start">
      <KitSection label="Admin action — ban" layout="column" :gap="10"
                  note="player → CoreCombobox over resolvers.player · duration → presets + free text · reason → templates.">
        <div :style="PANEL" style="width: 100%">
          <CoreSchemaForm v-model="ban" :fields="BAN_FIELDS" :resolvers="RESOLVERS" submit-label="Ban player"
                          @submit="(v) => (submitted = JSON.stringify(v))" @invalid="(e) => (submitted = 'invalid: ' + Object.keys(e).join(', '))" />
        </div>
        <p class="text-ui-sm text-fg-faint" style="margin: 0; word-break: break-all">submit: <b class="text-fg">{{ submitted }}</b></p>
      </KitSection>

      <KitSection label="Settings section — inline rows" layout="column" :gap="10"
                  note="Switch “Time sync” to Fixed hour or Fast cycle: the dependent row appears. 12 weather options → a combobox.">
        <div :style="PANEL" style="width: 100%">
          <CoreSchemaForm v-model="settings" :fields="SETTINGS_FIELDS" inline />
        </div>
      </KitSection>
    </div>

    <div class="grid gap-10" style="grid-template-columns: 1fr 460px; align-items: start">
      <KitSection label="Map element — vectors, nested object, array" layout="column" :gap="10"
                  note="An array row is the item field drawn bare; an object is a framed group; remove stops at minItems.">
        <div :style="PANEL" style="width: 100%">
          <CoreSchemaForm v-model="element" :fields="ELEMENT_FIELDS" :resolvers="RESOLVERS" />
        </div>
      </KitSection>

      <KitSection label="Server errors" layout="column" :gap="10"
                  note="errors = { target: 'custom:…', duration: 'max', reason: 'length' } — worded by messageFor().">
        <div :style="PANEL" style="width: 100%">
          <CoreSchemaForm v-model="errored" :fields="errFields" :resolvers="RESOLVERS" :errors="SERVER_ERRORS" />
        </div>
      </KitSection>
    </div>
  </KitStage>
</template>
