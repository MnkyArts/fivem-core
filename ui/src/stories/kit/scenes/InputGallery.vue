<script setup>
// InputGallery — CoreInput and CoreTextarea in every size, affix and state (DESIGN §37.5).
// The mockups show no text field, so this gallery is the proof of the box look itself: a dark
// well, a crisp hairline, coral focus with a soft halo. One input is focused on mount so the
// focus ring is visible in a screenshot without anyone clicking.
import { onMounted, ref } from 'vue'
import KitStage from './KitStage.vue'
import KitSection from './KitSection.vue'

const name = ref('Mara Kessler')
const phone = ref('555 0142')
const price = ref('2400')
const search = ref('Sultan RS')
const plate = ref('46QNC783')
const empty = ref('')
const tag = ref('')
const bio = ref('Ex-mechanic out of Sandy Shores. Keeps a spare fuel can in every trunk she touches.')
const notes = ref('')
const log = ref('Handed the keys back at 04:12.')

const bound = ref('Vinewood Hills')
const lastEnter = ref('—')
const focusMe = ref(null)

onMounted(() => {
  if (focusMe.value) focusMe.value.focus()
})
</script>

<template>
  <KitStage
    title="Input & Textarea"
    description="The box look of §37.5 on a single-line and a multi-line field: panel-sunken fill, white 16 % hairline
                 (28 % on hover), coral border plus the --core-focus halo while focused, error red when invalid."
  >
    <KitSection label="Sizes" layout="grid" :columns="3" note="Heights are --core-h-sm | -md | -lg (30 / 40 / 52 px).">
      <CoreInput v-model="empty" size="sm" placeholder="Search the manifest" icon="search" />
      <CoreInput v-model="search" size="md" icon="search" placeholder="Search the manifest" clearable />
      <CoreInput v-model="plate" size="lg" placeholder="Plate" icon="car" />
    </KitSection>

    <KitSection label="Icon, prefix, suffix, clear" layout="grid" :columns="3"
                note="A prefix or suffix is part of the value, so it reads in the text size, one step dimmer.">
      <CoreInput v-model="phone" prefix="+1" placeholder="Phone number" />
      <CoreInput v-model="price" suffix="$" placeholder="Asking price" />
      <CoreInput v-model="name" icon="user" clearable placeholder="Character name" />
    </KitSection>

    <KitSection label="States" layout="grid" :columns="3"
                note="The first field is focused on mount — that halo is what a player sees while typing.">
      <CoreInput ref="focusMe" v-model="bound" placeholder="Home district" />
      <CoreInput model-value="Los San" invalid placeholder="Character name" />
      <CoreInput model-value="46QNC783" disabled icon="car" />
      <CoreInput model-value="Bank of Los Santos" readonly icon="bank" />
      <CoreInput model-value="" placeholder="Nothing typed yet — the placeholder is fg-faint" />
      <CoreInput v-model="tag" maxlength="8" placeholder="Max 8 characters" />
    </KitSection>

    <KitSection label="v-model, enter and clear" layout="column" :gap="10"
                note="`enter` fires on the Enter key, `clear` when the ✕ is pressed; both keep the model a plain string.">
      <div class="flex items-center" style="gap: 14px; width: 100%">
        <CoreInput
          v-model="bound" clearable icon="map-marker" placeholder="Waypoint"
          style="max-width: 320px" @enter="lastEnter = bound" @clear="lastEnter = '(cleared)'"
        />
        <p class="core-text" style="margin: 0">
          model: <b class="text-fg">{{ bound || '(empty)' }}</b> · last enter: <b class="text-fg">{{ lastEnter }}</b>
        </p>
      </div>
    </KitSection>

    <KitSection label="Textarea" layout="grid" :columns="2" :gap="20"
                note="`counter` puts `used / maxlength` inside the well; `resize` is off by default.">
      <CoreTextarea v-model="bio" :rows="4" :maxlength="180" counter placeholder="Character biography" />
      <CoreTextarea v-model="notes" :rows="4" placeholder="Dispatch notes (resize: vertical)" resize="vertical" />
      <CoreTextarea v-model="log" :rows="3" invalid :maxlength="24" counter />
      <CoreTextarea model-value="Impound record locked by the sheriff's office." :rows="3" disabled />
    </KitSection>

    <KitSection label="Legacy bare classes" layout="grid" :columns="3" :gap="20"
                note="No components here: this is the markup the shell's InputDialog renders today
                      (.core-field / .core-label / input.core-input / textarea.core-input / select.core-select),
                      which the partial has to dress on the element itself.">
      <div class="core-field">
        <label class="core-label" for="legacy-name">Name</label>
        <input id="legacy-name" class="core-input" type="text" placeholder="Character name" />
      </div>
      <div class="core-field">
        <label class="core-label" for="legacy-garage">Garage</label>
        <select id="legacy-garage" class="core-select">
          <option>Pillbox Hill</option>
          <option>Legion Square</option>
          <option>Sandy Shores</option>
        </select>
      </div>
      <div class="core-field">
        <label class="core-label" for="legacy-reason">Reason</label>
        <textarea id="legacy-reason" class="core-input" rows="2" placeholder="Why the impound was released"></textarea>
      </div>
    </KitSection>
  </KitStage>
</template>
