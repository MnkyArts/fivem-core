// Manager-side addon: adds the "Lua" panel next to Controls / Actions / Interactions.
// Everything it shows comes over the `core/lua*` channel events that the preview decorator
// in src/stories/luaBridge.js emits, plus `parameters.lua` from the selected story.
import React from 'react'
import { addons, types } from 'storybook/manager-api'
import { AddonPanel } from 'storybook/internal/components'
import { LuaPanel, ADDON_ID, PANEL_ID } from './lua-panel.js'

addons.register(ADDON_ID, () => {
  addons.add(PANEL_ID, {
    type: types.PANEL,
    title: 'Lua',
    // Docs pages render many stories at once, so the log would be meaningless there.
    match: ({ viewMode }) => viewMode === 'story',
    // AddonPanel keeps the children mounted while hidden, so the channel subscription in
    // LuaPanel survives tab switches and never misses an event.
    render: ({ active }) => React.createElement(AddonPanel, { active }, React.createElement(LuaPanel, null)),
  })
})
