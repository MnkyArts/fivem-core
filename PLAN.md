# core — implementation plan

Resource dir: `/home/liamrbsn/Dokumente/Entwicklung/FiveM/resources/core` (Lua 5.4, standalone, no ox_lib, gta5
build 3751, OneSync, author MnkyArts). Example plugin dir: `/home/liamrbsn/Dokumente/Entwicklung/FiveM/resources/core_example`.

**The contract is `DESIGN.md` in this directory. Read the sections your run references before writing a line.**
This file only says who writes what, in which order, and which natives each file may use.

## 0. Rules for every implementer run

1. One file per tool call, ≤ ~150 lines per write; longer files = skeleton `Write` + `Edit` appends.
2. Verify every native you use with `fxref show <Name>` (batch them in ONE Bash loop at the start of the run).
   Check apiset vs the file's side. Names below are the verified names; a few differ from what you may expect
   (see §3 gotchas). Runtime helpers that are NOT natives (fine to call, fxref shows MISSING):
   `CreateThread, Wait, SetTimeout, ClearTimeout, AddEventHandler, RemoveEventHandler, RegisterNetEvent,
   TriggerEvent, TriggerServerEvent, TriggerClientEvent, RegisterCommand, exports, promise, Citizen.Await,
   json, msgpack, Entity, Player, LocalPlayer, GlobalState, GetPlayers, GetPlayerIdentifiers, SendNUIMessage`.
3. Lib chunks (`lib/**`) start with `local ns = ...` and add functions to `ns` (DESIGN §3). Core module files
   assign `Core.<Name> = {...}` / `Core.<Name>['sub.fn'] = ...` (DESIGN §2.2 for dotted names).
4. Every server net handler is registered through `Core.Net.on` except where DESIGN §5 says *raw*; raw ones
   start with `local src = source`.
5. `fxlint <resource_dir>` before you report; fix errors, fix or justify warnings with
   `-- fxlint-disable-next-line <RULE> -- <why>`. Known justified ones: S006 on the single `load(...)` in
   `import.lua`; S005 on `RegisterCommand(name, fn, false)` inside `lib/commands/shared.lua` (permission is
   checked by the wrapper via Core.Perms). Do not add a `.fxlintrc.json` ignore for anything else.
6. Report: files written (with line counts), natives verified, anything in DESIGN you could not follow and why,
   and "files remaining" if you stopped early. Never widen your slice.
7. Offline check for pure Lua: `luac5.4 -p <file>` (or `lua5.4 -e "loadfile('<file>')"`) for syntax on every file.

## 1. Runs (each ≤ 4 files / ≤ 650 lines; all runs are independent given DESIGN.md)

| Run | Files | DESIGN sections | ~Lines |
|---|---|---|---|
| **L1** | `import.lua`, `shared/config.lua`, `lib/utils/shared.lua`, `lib/math/shared.lua` | §1, §2, §3.1, §3.2, §10 | 200 + 110 + 190 + 100 |
| **L2** | `lib/validate/shared.lua`, `lib/log/shared.lua`, `lib/callback/shared.lua`, `lib/net/shared.lua` | §3.3–§3.6, §5 | 170 + 60 + 170 + 160 |
| **L3** | `lib/commands/shared.lua`, `lib/keys/client.lua`, `lib/streaming/client.lua`, `lib/anim/client.lua`, `lib/player/client.lua`, `lib/ui/client.lua` | §3.7–§3.12 | 190 + 70 + 120 + 70 + 70 + 30 |
| **S1** | `server/api.lua`, `server/db.lua`, `server/notify.lua`, `server/perms.lua` | §2.2, §2.3, §4.1, §4.4, §4.7 | 80 + 230 + 40 + 60 |
| **S2** | `server/player.lua`, `server/money.lua` | §4.2, §4.3, §5, §8 | 300 + 120 |
| **S3** | `server/factions.lua` | §4.5, §5.2, §8 | 340 |
| **S4** | `server/vehicles.lua`, `server/admin.lua`, `server/main.lua` | §4.6, §4.8, §4.9, §5 | 260 + 200 + 90 |
| **C1** | `client/api.lua`, `client/world.lua`, `client/markers.lua`, `client/textlabels.lua`, `client/blips.lua` | §2.2, §2.3, §6.3–§6.6 | 80 + 180 + 90 + 90 + 130 |
| **C2** | `client/interactions.lua`, `client/raycast.lua`, `client/vehicles.lua` | §6.7–§6.9 | 250 + 70 + 280 |
| **C3** | `client/ui.lua`, `client/player.lua` | §6.2, §6.10, §7.3 | 320 + 90 |
| **C4** | `client/spawn.lua`, `client/main.lua` | §6.1, §6.11 | 140 + 170 |
| **U1** | `ui/package.json`, `ui/vite.config.js`, `ui/index.html`, `ui/src/main.js`, `ui/src/bridge.js`, `ui/src/store.js`, `ui/src/coreui.js`, `ui/src/styles.css` | §7.1–§7.5 | small files, ~450 total |
| **U2** | `ui/src/App.vue`, `ui/src/components/Notifications.vue`, `TextUI.vue`, `Progress.vue`, `Hud.vue`, `PageHost.vue` | §7.2–§7.4 | ~500 |
| **U3** | `ui/src/components/Menu.vue`, `InputDialog.vue`, `AlertDialog.vue`, `ui/tests/shell-regression.js` | §7.2, §7.3, §7.5 | ~500 |
| **E1** | `../core_example/fxmanifest.lua`, `shared/config.lua`, `server/main.lua`, `client/main.lua`, `README.md` | §11 | ~300 |
| **E2** | `../core_example/ui/{package.json,vite.config.js,src/main.js,src/Page.vue}`, `core/templates/plugin/**` (manifest, client/server/shared stubs, ui/ copy of the same build setup) | §7.4, §11 | ~350 |
| **T1** (after L1–L3) | `tests/run_tests.lua`, `README.md` | §3, whole file | ~350 |

The scaffold placeholders were deleted; every file above is created fresh.

## 2. Natives per file (verified by the scouts on 2026-09-12 — still run `fxref show` yourself)

**import.lua** (shared): GetCurrentResourceName, IsDuplicityVersion, LoadResourceFile, GetResourceState.
**lib/utils/shared.lua**: GetHashKey, GetGameTimer. **lib/math/shared.lua**, **lib/validate**, **lib/log**: none.
**lib/callback/shared.lua**: IsDuplicityVersion, GetGameTimer (+ runtime helpers).
**lib/net/shared.lua**: server → GetPlayerPed(playerSrc), GetEntityCoords(entity) (server form has ONE arg),
IsPlayerAceAllowed(playerSrc, object), GetGameTimer; client → runtime helpers only.
**lib/commands/shared.lua**: RegisterCommand (shared), GetPlayerName (server), GetGameTimer.
**lib/keys/client.lua**: RegisterCommand, RegisterKeyMapping, IsNuiFocused, IsPauseMenuActive, GetGameTimer.
**lib/streaming/client.lua**: RequestModel, HasModelLoaded, SetModelAsNoLongerNeeded, IsModelValid,
IsModelInCdimage, RequestAnimDict, HasAnimDictLoaded, RemoveAnimDict, DoesAnimDictExist, RequestAnimSet,
HasAnimSetLoaded, RemoveAnimSet, RequestNamedPtfxAsset, HasNamedPtfxAssetLoaded, RemoveNamedPtfxAsset,
RequestCollisionAtCoord, HasCollisionLoadedAroundEntity, PlayerPedId, GetGameTimer, GetHashKey.
**lib/anim/client.lua**: TaskPlayAnim(ped, dict, name, speed, speedMultiplier, duration, flag, playbackRate,
lockX, lockY, lockZ), StopAnimTask(ped, dict, name, speed) — verify arg list —, IsEntityPlayingAnim(entity,
dict, name, taskFlag), ClearPedTasks (verify).
**lib/player/client.lua**: PlayerPedId, PlayerId, GetPlayerServerId, GetEntityCoords(entity, alive),
GetEntityHeading, IsPedDeadOrDying(ped, checkMeleeDeathFlags), AddStateBagChangeHandler, GetPlayerFromStateBagName.
**lib/ui/client.lua**: runtime helpers only.

**server/api.lua**: GetInvokingResource (optional cross-check), runtime `exports`.
**server/db.lua**: StartFindKvp, FindKvp, EndFindKvp, GetResourceKvpString, SetResourceKvpNoSync,
DeleteResourceKvpNoSync, FlushResourceKvp; `json.encode/decode`; `os.time` (server has os).
**server/notify.lua**: TriggerClientEvent. **server/perms.lua**: IsPlayerAceAllowed.
**server/player.lua**: GetPlayerIdentifierByType(playerSrc, 'license'), GetPlayerName, GetPlayerPed,
GetEntityCoords, GetEntityHeading, GetEntityHealth, DropPlayer(playerSrc, reason), GetPlayerRoutingBucket,
SetPlayerRoutingBucket, GetPlayers (helper), GetGameTimer, os.time.
**server/money.lua**: none. **server/factions.lua**: GetGameTimer, GetPlayerName.
**server/vehicles.lua**: CreateVehicleServerSetter(modelHash, type, x, y, z, heading), DoesEntityExist, DeleteEntity,
SetVehicleNumberPlateText, GetVehicleNumberPlateText, NetworkGetNetworkIdFromEntity, NetworkGetEntityFromNetworkId,
GetEntityType, GetEntityCoords, GetEntityHeading, GetEntityModel, SetEntityOrphanMode(entity, 2),
SetEntityRoutingBucket, SetVehicleDoorsLocked, GetPlayerPed, GetVehiclePedIsIn(ped, lastVehicle),
GetPedInVehicleSeat(vehicle, seatIndex), GetHashKey, GetGameTimer.
**server/admin.lua**: GetPlayerPed, GetEntityCoords, GetEntityHeading, GetVehiclePedIsIn, GetAllVehicles,
DoesEntityExist, NetworkGetNetworkIdFromEntity, GetPlayerName, DeleteEntity.
**server/main.lua**: GetPlayers (helper), GlobalState.

**client/api.lua**: runtime only. **client/world.lua**: PlayerPedId, GetEntityCoords, GetGameTimer.
**client/markers.lua**: DrawMarker(type, x, y, z, dirX, dirY, dirZ, rotX, rotY, rotZ, scaleX, scaleY, scaleZ, r, g, b, a,
bobUpAndDown, faceCamera, p19, rotate, textureDict, textureName, drawOnEnts).
**client/textlabels.lua**: SetDrawOrigin(x, y, z, p3), ClearDrawOrigin, SetTextFont, SetTextScale, SetTextColour,
SetTextCentre, SetTextDropshadow / SetTextDropShadow (both exist — pick one and verify its arg list), SetTextEdge,
SetTextOutline, BeginTextCommandDisplayText('STRING'), AddTextComponentSubstringPlayerName, EndTextCommandDisplayText(x, y, p2).
**client/blips.lua**: AddBlipForCoord, AddBlipForRadius, AddBlipForEntity, SetBlipSprite, SetBlipColour, SetBlipScale,
SetBlipAlpha, SetBlipAsShortRange, SetBlipDisplay, SetBlipCategory, SetBlipRoute, SetBlipRouteColour,
BeginTextCommandSetBlipName('STRING'), AddTextComponentSubstringPlayerName, EndTextCommandSetBlipName, RemoveBlip,
DoesBlipExist, SetBlipCoords (verify), GetFirstBlipInfoId(8), GetBlipInfoIdCoord, IsWaypointActive, SetNewWaypoint(x, y),
DeleteWaypointsFromThisPlayer (NOT DeleteWaypoint), NetworkGetEntityFromNetworkId, DoesEntityExist.
**client/interactions.lua**: PlayerPedId, GetEntityCoords, DoesEntityExist, GetClosestObjectOfType(x, y, z, radius,
modelHash, isMission, p6, p7), NetworkGetEntityFromNetworkId, NetworkDoesEntityExistWithNetworkId, RegisterCommand,
RegisterKeyMapping, IsNuiFocused, GetGameTimer, GetHashKey.
**client/raycast.lua**: GetGameplayCamCoord, GetGameplayCamRot(rotationOrder = 2),
StartExpensiveSynchronousShapeTestLosProbe(x1, y1, z1, x2, y2, z2, flags, entity, p8), GetShapeTestResult(handle) →
retval, hit, endCoords, surfaceNormal, entityHit; PlayerPedId.
**client/vehicles.lua**: GetGamePool('CVehicle'), GetVehiclePedIsIn, GetPedInVehicleSeat, IsPedInAnyVehicle,
NetworkGetNetworkIdFromEntity, NetworkGetEntityFromNetworkId, NetworkDoesEntityExistWithNetworkId,
NetworkRequestControlOfEntity, NetworkHasControlOfEntity, SetVehicleDoorsLocked, GetVehicleDoorLockStatus,
GetVehiclePedIsTryingToEnter, AddStateBagChangeHandler, GetEntityFromStateBagName, GetDisplayNameFromVehicleModel,
the label native (`fxref search "label text"` → GetFilenameForAudioConversation / GetLabelText alias — verify), SetVehicleEngineOn,
SetVehicleFixed, SetVehicleDeformationFixed, SetVehicleEngineHealth, SetVehicleBodyHealth, SetVehiclePetrolTankHealth,
GetEntityModel, GetVehicleNumberPlateText, GetVehicleNumberPlateTextIndex, SetVehicleNumberPlateTextIndex,
GetVehicleColours, SetVehicleColours, GetVehicleExtraColours, SetVehicleExtraColours, GetVehicleCustomPrimaryColour,
GetVehicleCustomSecondaryColour, GetIsVehiclePrimaryColourCustom, GetIsVehicleSecondaryColourCustom,
SetVehicleCustomPrimaryColour, SetVehicleCustomSecondaryColour, ClearVehicleCustomPrimaryColour,
ClearVehicleCustomSecondaryColour, GetVehicleExtraColour_5 / SetVehicleExtraColour_5 (interior), GetVehicleExtraColour_6 /
SetVehicleExtraColour_6 (dashboard), GetVehicleWheelType, SetVehicleWheelType, GetVehicleWindowTint, SetVehicleWindowTint,
GetVehicleLivery, SetVehicleLivery, GetVehicleLivery2, SetVehicleLivery2, GetVehicleXenonLightColorIndex,
SetVehicleXenonLightColorIndex, GetVehicleNeonEnabled, SetVehicleNeonEnabled, GetVehicleNeonColour, SetVehicleNeonColour,
GetVehicleTyreSmokeColor, SetVehicleTyreSmokeColor, DoesExtraExist, IsVehicleExtraTurnedOn, SetVehicleExtra,
SetVehicleModKit(vehicle, 0), GetVehicleMod, SetVehicleMod(vehicle, modType, modIndex, customTires), IsToggleModOn,
ToggleVehicleMod, GetVehicleModVariation, GetVehicleEngineHealth, GetVehicleBodyHealth, GetVehiclePetrolTankHealth,
GetVehicleFuelLevel, SetVehicleFuelLevel, GetVehicleDirtLevel, SetVehicleDirtLevel, IsVehicleTyreBurst, SetVehicleTyreBurst,
SetVehicleTyreFixed, PlayerPedId, GetEntityCoords, GetGameTimer, GetHashKey.
**client/ui.lua**: SetNuiFocus, SetNuiFocusKeepInput, IsNuiFocused, RegisterNuiCallback (native form), GetGameTimer;
runtime SendNUIMessage (table form), SetTimeout, promise, Citizen.Await.
**client/spawn.lua**: SetPlayerModel(player, model), SetPedDefaultComponentVariation, SetEntityCoords(entity, x, y, z,
alive, deadFlag, ragdoll, clearArea) — 8 args —, SetEntityHeading, NetworkResurrectLocalPlayer(x, y, z, heading),
ClearPedTasksImmediately, ClearPlayerWantedLevel(player), SetEntityVisible(entity, visible, unk), FreezeEntityPosition,
DoScreenFadeIn, DoScreenFadeOut, IsScreenFadedOut, ShutdownLoadingScreen, ShutdownLoadingScreenNui,
SetPedComponentVariation(ped, componentId, drawableId, textureId, paletteId), SetPedPropIndex(ped, componentId,
drawableId, textureId, updateModel), ClearPedProp, SetPedHeadBlendData, PlayerPedId, PlayerId, GetEntityModel, GetHashKey.
**client/player.lua**: SetEntityHealth, GetEntityMaxHealth, SetPedArmour, PlayerPedId, GetEntityCoords, GetEntityHeading.
**client/main.lua**: IsPedDeadOrDying, PlayerPedId, GetEntityCoords, RegisterCommand, GetGameTimer; `exports.spawnmanager`
in a pcall.

## 3. Gotchas (from the scouts)

- Server `GetEntityCoords(entity)` takes one argument; the client form takes `(entity, alive)`.
- `SetEntityCoords` (client) has 8 arguments: `(entity, x, y, z, alive, deadFlag, ragdoll, clearArea)`.
- There is no `DrawText`, `SetPedHairColor`, `SetPedEyeColor`, `SetPedFaceFeature`, `GetVehicleRoofLivery`,
  `IsVehicleNeonLightEnabled`, `SetVehicleNeonLightsColour`, `GetVehicleInteriorColour`, `DeleteWaypoint`,
  `StartShapeTestRay`, `GetActiveScreenResolution` — use the names listed in §2.
- `GetLabelText` is an alias; fxref may list it under `GetFilenameForAudioConversation`. Search before use.
- `RemoveBlip`/`AddBlipFor*` are client+server; everything blip-related in core runs client-side anyway.
- `SetTextDropshadow(distance, r, g, b, a)` vs `SetTextDropShadow()` — two different natives; pick one, verify.
- `GetVehicleType` is a shared CFX native returning a string; `CreateVehicleServerSetter` needs that string as `type`.
- `os.time()`/`os.date()` exist on the server only. Client code uses `GetGameTimer()`.

## 4. Offline verification the main session runs after the runs

- `fxlint core`, `fxlint core_example` — 0 errors, warnings justified.
- `lua5.4 core/tests/run_tests.lua` — libs + import loader (T1).
- `cd core/ui && npm install && npm run build` → `core/html/`; `cd core_example/ui && npm install && npm run build`.
- `agent-browser` on `core/html/index.html` + `core/ui/tests/shell-regression.js`.
- Deploy: `fxserver deploy core`, `fxserver deploy core_example`, restart, `fxserver logs --errors`.

## 5. Wave 2 runs (DESIGN §15–§28) — 2026-09-12

Same rules as §0. All runs are independent given DESIGN.md; edits to files owned by an earlier run go back to that run.
The manifest already lists every new file (main.lua stays last; api.lua first). `shared/config.lua` already has the §28 keys.

| Run | Files | DESIGN | ~Lines |
|---|---|---|---|
| **W1** | `server/worldsync.lua`, `client/worldsync.lua` | §15 (+§6.4–§6.7 option shapes) | 260 + 160 |
| **W2** | `server/doors.lua`, `client/doors.lua` | §16 | 240 + 200 |
| **W3** | `server/environment.lua`, `client/environment.lua`, `server/cron.lua` | §17 | 220 + 180 + 170 |
| **W4** | `server/stats.lua`, `client/stats.lua` | §18 | 200 + 40 |
| **W5** | `server/weapons.lua`, `client/weapons.lua` | §19 (+§25 hook contract) | 220 + 140 |
| **W6** | `server/remote.lua`, `client/remote.lua`, `lib/audio/client.lua` | §20 | 200 + 220 + 60 |
| **W7** | `server/ui.lua`, `client/ui_remote.lua`, `client/hudfeed.lua` | §21 | 180 + 90 + 140 |
| **C3 (resume)** | `client/ui.lua` additions | §21 (keys/shard/spinner/stats/state/locale/ui_sound) | +120 |
| **W8** | `server/getters.lua`, `server/globals.lua`, `server/services.lua` (incl. `Core.Api`) | §22 | 180 + 90 + 120 |
| **S1 (resume)** | `server/perms.lua` (grant/revoke/list), `server/db.lua` (nextId/migrate/export/import), `server/db_mysql.lua` | §22, §27 | +70, +120, 130 |
| **S2 (resume)** | `server/player.lua` (setReplicated, playerDataChanged hook, setControls/setFrozen/setInvincible/setVisible/setHealth/setArmour/getHealth/getArmour) | §17, §20, §22 | +90 |
| **W9** | `server/chat.lua` | §23 | 230 |
| **W10** | `server/http.lua`, `server/webhook.lua`, `server/security.lua` | §24, §25 | 160 + 110 + 170 |
| **W11** | `lib/locale/shared.lua`, `locales/en.json`, `locales/de.json`, `templates/plugin/locales/en.json` | §26 | 120 + json |
| **W12** (Vue) | `ui/src/components/Shard.vue`, `Spinner.vue`, `KeyHints.vue`, `StatsBars.vue`, edits `store.js`/`coreui.js`/`App.vue`/`Hud.vue`, new stories | §21 | ~600 |
| **T2** | `tests/server_tests.lua`, `tests/stubs.lua` (extend) | §27 | ~600 |
| **W13** (after W1–W12) | `types/core.lua`, `../.luarc.json` | §27 | ~800 |
| **W14** (after W1–W12) | `scripts/new-plugin.sh`, `scripts/check.sh`, `../.github/workflows/core-ci.yml`, README updates | §27 | ~250 |

Natives to verify per file (names from the 2026-09-12 scouts where already verified; the rest via `fxref show` in your run):
- `client/doors.lua`: DoorSystemSetDoorState, DoorSystemGetDoorState, IsDoorRegisteredWithSystem, AddDoorToSystem, SetStateOfClosestDoorOfType, GetEntityCoords, PlayerPedId, GetHashKey.
- `client/environment.lua`: NetworkOverrideClockTime, SetWeatherTypeOverTime, SetWeatherTypeNowPersist, SetWeatherTypePersist, ClearOverrideWeather, ClearWeatherTypePersist, SetOverrideWeather, DoScreenFadeOut/In, TriggerScreenblurFadeIn/Out, AnimpostfxPlay/AnimpostfxStop/AnimpostfxStopAll, SetTimecycleModifier, SetTimecycleModifierStrength, ClearTimecycleModifier, SetPlayerControl, FreezeEntityPosition, SetEntityInvincible, SetEntityVisible, SetEntityHealth, GetEntityMaxHealth, SetPedArmour.
- `client/weapons.lua`: GiveWeaponToPed, RemoveWeaponFromPed, RemoveAllPedWeapons, SetPedAmmo, GetAmmoInPedWeapon, HasPedGotWeapon, GiveWeaponComponentToPed, SetPedWeaponTintIndex, GetHashKey, PlayerPedId.
- `client/remote.lua` + `lib/audio/client.lua`: PlaySoundFrontend, PlaySoundFromCoord, GetSoundId, ReleaseSoundId, StopSound, AttachEntityToEntity, CreateObject, DeleteEntity, GetPedBoneIndex, SetNewWaypoint, DeleteWaypointsFromThisPlayer, GetFirstBlipInfoId, GetBlipInfoIdCoord, IsWaypointActive, GetPlayerFromServerId, GetPlayerPed, NetworkGetNetworkIdFromEntity, GetActivePlayers, GetEntityCoords, PlayerPedId + the §6.9 raycast natives.
- `client/hudfeed.lua`: GetEntityHealth, GetEntityMaxHealth, GetPedArmour, GetEntitySpeed, GetStreetNameAtCoord, GetNameOfZone, GetFilenameForAudioConversation (label text), GetSafeZoneSize, GetAspectRatio, GetActualScreenResolution, PlayerPedId, GetEntityCoords.
- `server/getters.lua`: GetPlayerPed, GetEntityCoords (1-arg), GetVehiclePedIsIn, GetPedInVehicleSeat, GetVehicleMaxNumberOfPassengers (verify apiset), GetPlayerName.
- `server/http.lua`: PerformHttpRequest (helper), SetHttpHandler (verify), GetConvar. `server/security.lua`: SetRoutingBucketEntityLockdownMode, CancelEvent; event handlers weaponDamageEvent/explosionEvent (runtime-facts §9 signatures `(sender, data)`).
- `server/environment.lua`, `server/stats.lua`, `server/weapons.lua`, `server/remote.lua`, `server/ui.lua`, `server/globals.lua`, `server/services.lua`, `server/chat.lua`, `server/cron.lua`, `server/worldsync.lua`: no GTA natives beyond GetGameTimer/GetPlayerPed/GetEntityCoords/GetHashKey; `os.date`/`os.time` allowed server-side.

## 6. UI visibility runs (DESIGN §31, 2026-09-12)

| run | agent | owns | notes |
|---|---|---|---|
| UIV-1 | fivem-implementer (opus) | `shared/config.lua` (UI.AutoHide), `client/ui.lua` (reasons, watchers, hook, hidden transition, ui_ready re-send), `server/ui.lua` (hide/show), `types/core.lua`, `tests/server_tests.lua` | natives: IsPauseMenuActive, IsScreenFadedOut, IsScreenFadingOut, IsPlayerSwitchInProgress, IsWarningMessageActive, IsHudHidden, IsCinematicCamRendering (all client) — re-verify with fxref |
| UIV-2 | general-purpose (opus) | `ui/src/store.js`, `ui/src/App.vue`, `ui/src/styles.css` (only the `.core-root.is-hidden` rule), `ui/tests/shell-regression.js`, Storybook story + Lua panel entry + Introduction.mdx, `README.md` | verify with `npx vite build` to a scratch dir, the regression over HTTP, `npx storybook build` |

## 7. Game blur runs (DESIGN §32, 2026-09-12) — start after §6 runs are merged

| run | agent | owns | notes |
|---|---|---|---|
| GB-1 | general-purpose (opus) | new `ui/src/gameblur.js`, `ui/src/main.js`, `ui/src/App.vue` (watchEffect only), `ui/src/store.js` (`store.blur`, `blur:set`), `ui/src/styles.css` (glass rules, `--color-panel-glass`, root override), `ui/tests/shell-regression.js` | verify: scratch vite build, regression over HTTP (+3 → 52), no CSS warnings |
| GB-2 | general-purpose (opus) | `data-core-blur` on the built-in panels (Menu, InputDialog, AlertDialog, Hud, StatsBars, Notifications, TextUI, Progress, KeyHints, Spinner), `core_example/ui/src/Page.vue`, `templates/plugin/ui/src/Page.vue`, `.storybook/preview.js` (install), new `ui/src/stories/GameBlur.stories.js`, Introduction.mdx, README (Styling + Visibility wording + config + checklist step), template/example READMEs | verify: scratch vite build + storybook build |
| GB-3 | fivem-implementer (opus) | `shared/config.lua` (`UI.Blur`), `client/ui.lua` (`blur:set` on ui_ready, `Core.UI.setBlur`), `types/core.lua`, `tests/server_tests.lua` untouched unless needed | no new natives |
