# core — offline tests

Plain Lua 5.4, no FiveM, no server. From the resource directory (or from here):

```sh
lua5.4 tests/run_tests.lua       # import.lua + lib/**   -- prints "N passed, M failed"
lua5.4 tests/server_tests.lua    # server/**             -- same output, exit code 1 on any failure
lua5.4 tests/client_chat_tests.lua # chat bridge, focus lifecycle and native-call contract (stubbed)
node --test ui/tests/chat-model.test.js # pure completion, caret, quoting and UTF-8 helpers
```

## Files
- `stubs.lua` — a stand-in for the CitizenFX Lua runtime: the natives `import.lua` and the
  libs use, `vector3`, an event bus wiring a simulated server VM to a client VM, a virtual
  clock (`stubs.tick(ms)`) driving `Wait`/`SetTimeout`/`promise`/`Citizen.Await`, state
  bags, `exports` and `json`. `stubs.newEnv(side, resourceName)` returns a fresh `_ENV` in
  which core's own files are compiled, so the real code runs unmodified.
  It also carries the server half: a KVP store that outlives a VM (so a reload round trips),
  connected players with identifiers/peds, fake entities for the vehicle natives, entity state
  bags and `stubs.connectPlayer/dropPlayer`. `stubs.resetServer()` clears all of it.
- `run_tests.lua` — the loader and lib suites, plus a small assertion helper.
- `server_tests.lua` — the same helper over one core server VM per suite (`import.lua`,
  `shared/config.lua`, then the `server/*.lua` modules in manifest order).
- `client_chat_tests.lua` — runs the real chat bridge with captured NUI/native calls; checks
  startup/stop, focus refusal, reload/hide, slash execution, config and plugin suggestion ownership.
- `../ui/tests/chat-model.test.js` — dependency-free Node tests for chat presentation helpers.
  `../ui/tests/shell-regression.js` additionally exercises fading, spacing, command navigation,
  argument hints, history, IME and focus in the built shell using `agent-browser` (see README).

## Covered
`import.lua` (lib loading, export proxy incl. `Core.UI.menu.open` and `Core.Player(src)`
sugar, `Core.Config` isolation from a plugin's `Config`, core-VM behaviour), readiness and
restarts (§2.4), and the libs: `Utils`, `Math`, `Validate` (every spec kind and its error
text), `Net` (check order, cooldowns, `playerDropped`), `Callback` (round trip across the
two VMs, timeout, rate limit, `awaitClient`), `Commands` (typed parsing, usage,
permissions, console, suggestions), `Keys` and `Log`.

`server_tests.lua` covers `Core.DB` (CRUD, queries, deep-copy isolation, the KVP round trip
through a fresh VM, `setAdapter`), `Core.Perms` (console, ACE, config groups, the `setGroup`
delegation), `Core.Player` (join, the `requestLoad` payload and its `respawn` flag, dot paths,
the §8 state-bag keys, save on drop, the ghost-session takeover, kick/ban), `Core.Money`
(including the transfer rollback), `Core.Factions` (create cost, the invite/accept/rank/kick
chain, permission denials, invite squatting, the bank rollback on a failing write),
`Core.Vehicles` (spawn, plates, keys, the `vehicleLock` net event with its distance check,
records and `spawnRecord`) and `server/api.lua` (the block list, the per-coroutine caller,
the owner sweep).

## Not covered
Everything that needs the engine: native client behaviour, drawing, in-game NUI focus, real KVP, real
networking, OneSync and entity behaviour. The natives here are stubs with hand-written
semantics — a green run means the Lua contracts hold, **not** that the resource works in
game. Use the in-game checklist in the resource README for that.
