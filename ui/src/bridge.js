// core UI — NUI <-> Lua transport (DESIGN §6.10, §7.2, §7.5)
//
// post(name, data)      -> Promise<object>   POST to https://<resource>/<name>
// onMessage(action, fn) -> off()             dispatch of SendNUIMessage payloads
// window.__core.send(m)                      dev helper: fake an incoming message

const hasParent = typeof window.GetParentResourceName === 'function'
const RESOURCE = hasParent ? window.GetParentResourceName() : null

/** true when the page runs in a plain browser (agent-browser / `npm run dev`). */
export const isDev = !hasParent

/** Optional observer hook (`window.__core.onPost` / `.onMessage`): Storybook and the
 *  offline tests use it to watch the wire without touching the transport. */
function tap(hook, a, b) {
  const shim = window.__core
  if (!shim || typeof shim[hook] !== 'function') return
  try {
    shim[hook](a, b)
  } catch (err) {
    console.error('[core:ui] __core.' + hook + ' failed', err)
  }
}

/** Fire a NUI callback. Always resolves (never rejects) so callers need no try/catch. */
export function post(name, data) {
  const body = data === undefined || data === null ? {} : data
  tap('onPost', name, body)
  if (isDev) {
    console.log('[core:ui] post', name, body)
    return Promise.resolve({})
  }
  return fetch(`https://${RESOURCE}/${name}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(body),
  })
    .then((res) => res.json())
    .catch((err) => {
      console.error('[core:ui] post failed', name, err)
      return {}
    })
}

const handlers = new Map()

function dispatch(event) {
  const msg = event && event.data
  if (!msg || typeof msg !== 'object') return
  const action = msg.action
  if (typeof action !== 'string') return
  tap('onMessage', msg)
  const set = handlers.get(action)
  if (!set) return
  for (const fn of Array.from(set)) {
    try {
      fn(msg)
    } catch (err) {
      console.error('[core:ui] handler failed for', action, err)
    }
  }
}

window.addEventListener('message', dispatch)

/** Subscribe to one `action` from Lua. Returns an unsubscribe function. */
export function onMessage(action, handler) {
  let set = handlers.get(action)
  if (!set) {
    set = new Set()
    handlers.set(action, set)
  }
  set.add(handler)
  return () => set.delete(handler)
}

// Dev/offline driver: `__core.send({ action: 'menu:open', ... })` (DESIGN §7.5).
window.__core = {
  send(msg) {
    window.dispatchEvent(new MessageEvent('message', { data: msg }))
    return msg
  },
  isDev,
  resource: RESOURCE,
}
