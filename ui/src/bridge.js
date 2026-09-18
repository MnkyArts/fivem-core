// core UI — NUI <-> Lua transport (DESIGN §6.10, §7.2, §7.5, §38.8).
//
// The implementation moved to `src/runtime/transport.ts` when §38 added request/response, timeouts,
// counters and a swappable mock. This module keeps its path and its three exports, because 34 files
// (and every story) import them from here:
//
//   post(name, data)      -> Promise<object>   POST to https://<resource>/<name>; NEVER rejects
//   onMessage(action, fn) -> off()             dispatch of SendNUIMessage payloads
//   isDev                                      true in a plain browser (no GetParentResourceName)
//   window.__core.send(m)                      dev helper: fake an incoming message
//
// Importing this file still installs `window.__core` — transport.ts does it on load.
export { post, onMessage, isDev, request, deliver, setTransport, resetTransport, NuiError } from './runtime/transport.ts'
