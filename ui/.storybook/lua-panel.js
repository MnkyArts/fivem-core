// The custom "Lua" panel: what the Lua side calls, what it puts on the wire, what comes
// back, and what the awaiting Lua call ends up with — for the selected story.
//
// The preview half is src/stories/luaBridge.js; these three event names are its contract.
// Manager code is React, so this file is plain React.createElement (no JSX build step).
import React from 'react'
import { useChannel, useParameter } from 'storybook/manager-api'
import { useTheme } from 'storybook/theming'

export const ADDON_ID = 'core/lua'
export const PANEL_ID = ADDON_ID + '/panel'

const LUA_EVENT = 'core/lua'
const LUA_RESET = 'core/lua-reset'
const LUA_REQUEST = 'core/lua-request'

const e = React.createElement
const json = (value) => {
  try {
    return JSON.stringify(value, null, 2)
  } catch (err) {
    return String(value)
  }
}

function Section (props) {
  const t = props.theme
  return e('div', { style: { marginBottom: 18 } }, [
    e('div', {
      key: 'h',
      style: {
        display: 'flex', alignItems: 'baseline', gap: 8, marginBottom: 6,
        font: '700 10px/1.4 ' + t.typography.fonts.base, letterSpacing: '0.08em',
        textTransform: 'uppercase', color: t.color.mediumdark,
      },
    }, [props.title, props.hint ? e('code', { key: 'c', style: { font: '400 11px/1.4 ' + t.typography.fonts.mono, textTransform: 'none', letterSpacing: 0, color: props.tint || t.color.secondary } }, props.hint) : null]),
    props.children,
  ])
}

function Code (props) {
  const t = props.theme
  return e('pre', {
    style: {
      margin: 0, padding: '9px 11px', overflow: 'auto',
      maxHeight: props.cap ? 190 : 320,
      background: t.background.app, border: '1px solid ' + t.appBorderColor,
      borderRadius: t.appBorderRadius, borderLeft: '3px solid ' + (props.tint || t.appBorderColor),
      font: '400 11px/1.55 ' + t.typography.fonts.mono,
      color: props.tint && props.plain ? props.tint : t.color.defaultText,
      whiteSpace: 'pre-wrap', wordBreak: 'break-word',
    },
  }, props.children)
}

function Empty (props) {
  return e('div', {
    style: {
      padding: '8px 11px', border: '1px dashed ' + props.theme.appBorderColor,
      borderRadius: props.theme.appBorderRadius,
      font: '400 11px/1.5 ' + props.theme.typography.fonts.mono, color: props.theme.color.mediumdark,
    },
  }, props.children)
}

export function LuaPanel () {
  const t = useTheme()
  const param = useParameter('lua', {}) || {}
  const [sent, setSent] = React.useState({})
  const [log, setLog] = React.useState([])
  const started = React.useRef(0)

  const emit = useChannel({
    [LUA_RESET]: (payload) => {
      setLog([])
      started.current = 0
      setSent((payload && payload.lua) || {})
    },
    [LUA_EVENT]: (entry) => setLog((prev) => prev.concat(entry)),
  })

  // The panel can mount after the story already ran; ask the preview to replay its log.
  React.useEffect(() => { emit(LUA_REQUEST) }, [])

  const lua = Object.assign({}, sent, { call: param.call || sent.call, message: param.message || sent.message, callback: param.callback || sent.callback, note: param.note || sent.note })
  const at = (entry) => {
    if (!started.current) started.current = entry.at
    return '+' + String(entry.at - started.current).padStart(4, ' ') + 'ms'
  }
  const rows = (dir) => log.filter((x) => x.dir === dir)
  const outgoing = rows('lua→nui')
  const back = rows('nui→lua')
  const results = rows('lua-result')

  return e('div', {
    style: {
      height: '100%', overflow: 'auto', padding: '14px 16px 22px',
      background: t.background.content, color: t.color.defaultText,
      font: '400 12px/1.5 ' + t.typography.fonts.base,
    },
  }, [
    e('div', { key: 'bar', style: { display: 'flex', justifyContent: 'flex-end', marginBottom: 10 } },
      e('button', {
        type: 'button',
        onClick: () => { setLog([]); started.current = 0 },
        style: {
          padding: '3px 10px', cursor: 'pointer', borderRadius: t.appBorderRadius,
          border: '1px solid ' + t.appBorderColor, background: t.background.app,
          color: t.color.defaultText, font: '600 11px/1.6 ' + t.typography.fonts.base,
        },
      }, 'Clear')),

    e(Section, { key: 's1', theme: t, title: 'Lua call', hint: 'client/ui.lua' },
      lua.call
        ? e(Code, { theme: t, tint: t.color.secondary }, lua.call)
        : e(Empty, { theme: t }, 'This story sets no parameters.lua.call.')),

    e(Section, { key: 's2', theme: t, title: 'SendNUIMessage → NUI', hint: lua.message, tint: t.color.secondary },
      outgoing.length
        ? outgoing.map((x, i) => e('div', { key: i, style: { marginBottom: 6 } },
          e(Code, { theme: t, cap: true, tint: t.color.secondary }, at(x) + '  ' + x.name + '\n' + json(x.body))))
        : e(Empty, { theme: t }, 'Nothing sent yet.')),

    e(Section, { key: 's3', theme: t, title: 'NUI → Lua callbacks', hint: lua.callback, tint: t.color.gold },
      back.length
        ? back.map((x, i) => e('div', { key: i, style: { marginBottom: 6 } },
          e(Code, { theme: t, cap: true, tint: t.color.gold }, at(x) + '  post(\'' + x.name + '\')\n' + json(x.body))))
        : e(Empty, { theme: t }, 'Interact with the story (arrows / Enter / Esc / click) — every RegisterNuiCallback shows up here.')),

    e(Section, { key: 's4', theme: t, title: 'What Lua gets back' },
      results.length
        ? results.map((x, i) => e('div', { key: i, style: { marginBottom: 6 } },
          e(Code, { theme: t, tint: t.color.positive, plain: true }, x.text)))
        : e(Empty, { theme: t }, lua.callback ? 'Resolves once ' + lua.callback + ' is posted.' : 'This story awaits nothing on the Lua side.')),

    lua.note ? e('p', { key: 'note', style: { margin: 0, color: t.color.mediumdark, fontSize: 11 } }, lua.note) : null,
  ])
}
