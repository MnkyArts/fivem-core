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
- `client/interiors.lua` (§36, 2026-09-15): RequestIpl, RemoveIpl, IsIplActive, GetInteriorAtCoords, IsValidInterior, IsInteriorReady, ActivateInteriorEntitySet, DeactivateInteriorEntitySet, IsInteriorEntitySetActive, RefreshInterior, GetGameBuildNumber, IsDlcPresent (all client/shared apiset, verified with fxref).
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

## 8. Full freemode appearance (DESIGN §34, 2026-09-12) — built with the `charcreator` plugin

The plugin's own contract is `resources/charcreator/PLAN.md` (runs B–E there); this is the core half.

| run | agent | owns | notes |
|---|---|---|---|
| A | fivem-implementer (opus) | `client/spawn.lua` (apply order §34.2), `types/core.lua` (`CoreAppearance`), `README.md` (cheat sheet + "Appearance" note) | natives: SetPedFaceFeature, SetPedHeadOverlay, SetPedHeadOverlayColor, SetPedHairTint, SetPedEyeColor — the FiveM runtime names, not the nativedb renames (`fxref` now prints the runtime name; see the kit fix of the same day) |

## Vehicle system finalization — 2026-09-15

| Run | Owner | Files | Status |
|---|---|---|---|
| C1 | main (native-scout role unavailable in this environment; all calls verified with local `fxref`) | `server/vehicles.lua`, `client/vehicles.lua`, `DESIGN.md`, `README.md` | complete |
| C2 | main | `types/core.lua`, `tests/server_tests.lua` | complete (720 server tests) |

Contract: preserve Core.Vehicles compatibility with virtual keys, add persisted item-key mode for the vehicle_system plugin, and accept the bounded 0-based property maps Core.Vehicles.getProps already produces. See `../vehicle_system/PLAN.md` for complete native/API and test lists.

| C3 | main | `shared/config.lua`, `server/vehicles.lua`, `client/vehicles.lua`, `DESIGN.md`, `README.md`, `types/core.lua`, `tests/server_tests.lua` | complete — global stored/live plate uniqueness, `LS-` plates and complete condition props; `scripts/check.sh` passed |

| C4 | main | `client/vehicles.lua`, `DESIGN.md`, `README.md`, `types/core.lua` | complete — core's virtual-key `U` route now intentionally no-ops for item-key vehicles, allowing their domain plugin to validate its physical key |

## Interiors / IPL loader (DESIGN §36) — 2026-09-15

| Run | Owner | Files | Status |
|---|---|---|---|
| I1 | main | `DESIGN.md` (§36 contract), `client/interiors_data.lua` (new, 27 groups / 369 IPLs), `client/interiors.lua` (new, loader + API), `shared/config.lua` (`Config.Interiors`), `fxmanifest.lua`, `types/core.lua`, `README.md` (cheat sheet + config + checklist step 25), `tests/client_interiors_tests.lua` (new, 999 checks), `scripts/check.sh` | complete — `lua5.4` suites + `fxlint .` green |

Contract: port the IPL layer of Bob74/bob74_ipl (MIT, researched from master + DurtyFree dumps; own code and
grouping, attribution in the data file) as boot-loaded groups with build/DLC gates; per-interior entity-set
styling stays plugin-side via `Core.Interiors.activateSet`. Natives verified with local `fxref` (STREAMING +
INTERIOR client, CFX shared GetGameBuildNumber, DLC client IsDlcPresent).

## Persistent world vehicle run — 2026-09-15

| Run | Owner | Files | Status |
|---|---|---|---|
| P1 | main (custom scout/implementer/reviewer roles unavailable; natives checked with local `fxref`) | `server/vehicles.lua`, `client/vehicles.lua`, `types/core.lua`, `DESIGN.md`, `README.md`, `tests/server_tests.lua`, `tests/stubs.lua` | complete — ambient adoption, out-record restoration, world-vs-garage semantics and streamed props; 735 server checks, full check and zero-warning fxlint passed |

## Design system / UI kit (DESIGN §37) — 2026-09-18

Contract: DESIGN §37 (tokens, conventions, catalogue). Look authority: `FiveM/DesignMockups/*.png` — the kit
replaces the old visual direction, it does not extend it. Orchestrator (main) wrote the contract, cut the
Storybook art (`ui/src/stories/kit/assets/`) and reviewed every gallery from screenshots; implementers were
opus subagents with disjoint files, each with its own Vite port + `agent-browser --session`, verifying with
`node ui/tests/kit-compile-check.mjs` and screenshots of `kit-preview.html?scene=<Scene>` against 2.5× mockup
crops. Nobody but the orchestrator ran `npm run build` (it empties `html/`). One consolidated fix round per
group via SendMessage, then a contract-review pass (R1) whose seven findings went back to the owners.

| Run | Owner | Files | Status |
|---|---|---|---|
| F0a | opus | `ui/src/styles.css` (tokens, `@theme static`), `ui/src/kit/{index,icons,use}.js`, `kit/fonts.css` + `fonts/` (9 vendored Barlow woff2, OFL), `kit/css/base.css`, `kit/components/CoreIcon.vue`, `ui/src/main.js`, `ui/src/App.vue` (overlay root), `.storybook/preview.js` | complete — build, 99/99 shell regression |
| F0b | opus | `ui/kit-preview.html`, `ui/src/kit/preview.js` (dev harness), `ui/tests/kit-compile-check.mjs`, `stories/kit/README.md`, `scenes/{KitStage,KitSection,Foundations*,IconGallery}.vue`, `Foundations.stories.js`, `Icon.stories.js` | complete |
| K1 actions | opus | `css/actions.css`, CoreButton, CoreIconButton, CoreKey, CoreKeyHint, CoreKeyHints, CorePrompt, CorePromptGroup + stories/scenes | complete (+ fix rounds: prompt band, hint captions, tokens, IconButton `success`/`fade`) |
| K2 surfaces | opus | `css/surfaces.css`, CorePanel, CoreCard, CoreBackground, CoreScreen, CoreHeading, CoreDivider, CoreDash, CoreTagline, CoreBrand + stories/scenes | complete (+ `hud` panel, brand `xl`, tagline shadow, background `position`/`fade`, screen `navAlign`, card `variant`, subtitle scale) |
| K3 navigation | opus | `css/navigation.css`, CoreTabs, CoreMenu, CoreChips, CoreStepper + stories/scenes | complete (+ on-accent tokens, active tab `fg`, chips `stretch`/`minWidth`) |
| K4 forms-text | opus | `css/forms-text.css`, CoreField, CoreInput, CoreTextarea, CoreNumberInput, CoreSelect + stories/scenes | complete (+ teleport target at setup, popup z 50, pinned `placement`) |
| K5 forms-choice | opus | `css/forms-choice.css`, CoreCheckbox, CoreRadioGroup, CoreRadio, CoreSwitch, CoreSlider, CoreSwatches + stories/scenes | complete |
| K6 data-meters | opus | `css/data-meters.css`, CoreProgress, CoreRing, CoreStatBar, CoreStatRow, CoreSpinner, CoreSkeleton + stories/scenes | complete (+ StatBar `iconTone`) |
| K7 data-display | opus | `css/data-display.css`, CoreBadge, CoreTag, CoreAvatar, CorePlayerChip, CoreTable, CoreKeyValue, CoreEmpty + stories/scenes | complete (+ `--color-hud`, ping ring) |
| K8 game | opus | `css/game.css`, CoreSlot, CoreSlotGrid, CoreHotbar, CoreList, CoreListItem, CoreObjective, CoreTracker, CoreCompass + stories/scenes | complete (+ compass fov 270 / `labels`, pointer gating, hotbar roving, tracker `bloom`) |
| K9 feedback | opus | `css/feedback.css`, CoreAlert, CoreToast, CoreDialog, CoreDrawer, CorePopover, CoreContextMenu, CoreTooltip + stories/scenes | complete (+ overlay z-scale 40/50/60, teleport target at setup) |
| S1 shell modals | opus | `ui/src/components/{Menu,InputDialog,AlertDialog}.vue` | complete — hooks kept, 99/99 |
| S2a shell HUD | opus | `ui/src/components/{Hud,StatsBars,Notifications,Shard}.vue` | complete — hooks kept, 99/99 |
| S2b shell prompts | opus | `ui/src/components/{TextUI,Progress,KeyHints,Spinner,Chat}.vue` | complete — hooks kept, 99/99 |
| SC1 / SC2 showcase | opus | `stories/kit/Showcase{MainMenu,Hud,Inventory,Map}.stories.js` + scenes — the four mockups from kit tags only | complete; their gap lists drove the late additions above |
| T1 tests | opus | `ui/tests/kit-regression.js` | complete — `PASS 195/195` on the build |
| D1 docs | opus | `README.md`, `AGENTS.md`, `stories/docs/DesignSystem.mdx`, `templates/plugin/{README.md,ui/src/Page.vue}`, `../core_example/{README.md,ui/src/Page.vue}` | complete |
| R1 reconcile | opus | `DESIGN.md` §37 rewritten from the shipped sources (58 entries) | complete |
| K10 | opus | `CoreInteractionDot` (+ game.css block, gallery, story) — Liam's "interaction dot" | complete |
| S3A/S3B/S3C | opus | **the shell is kit only** — `ui/src/shell/` replaces `ui/src/components/` (deleted): every Lua-driven widget is a composition of kit components (§37.6); new `CoreShard`; additive kit props CoreDialog `escape/trap/role`, CoreMenu `keyboard/rowAttrs/glyph`, CoreProgress `fillEl`, CoreKeyValue `lastRule`/`label-<i>` | complete |
| T2 | opus | `ui/tests/{shell,kit}-regression.js`, the 15 shell stories (imports + moved hooks), CoreToast `×`, HUD glass tint, danger caption, spinner ellipsis | complete — shell 101/101, kit 195/195 |

Size: 62 components (5.4k lines), 10 CSS partials (5.7k), foundation JS (1.2k), 110 story/scene files (11.4k),
two suites (1.5k). Final gate: `scripts/check.sh` green (fxlint 0/0, Lua 385 + 764), shell regression 101/101,
kit regression 195/195, Storybook builds (265 stories). Open: in-game pass (the CEF's real blur, fonts and
pointer behaviour); the existing plugin pages (inventory, charcreator, trucking) still use their own elements
— migrating them to the kit is the next run; a global UI scale decision (the kit is calibrated to the mockups'
1672 px frame, ~13 % small at 1080p).

## Runtime UI platform (DESIGN §38) — 2026-09-18

Liam: *"a real FiveM frontend platform"*. Until this run core compiled every plugin page INTO its own bundle
(`ui/src/plugins.js`, §7.4): changing the inventory meant rebuilding core, and a resource core had never seen
could not bring a UI. §38 replaces that coupling and nothing else — still ONE `ui_page`, ONE Vue, ONE kit, ONE
focus owner, but every resource now owns, builds, ships and restarts its own frontend and core imports it at
runtime from `https://cfx-nui-<res>/ui/dist/`. Contract written first (DESIGN §38, revised after every review
round), then the TypeScript half of it (`ui/sdk/src/contract.ts`) imported by both sides so the compiler proves
the shell implements what the SDK calls. Orchestrator (main) owned `DESIGN.md` §38 and routed every
cross-agent finding; implementers were opus subagents with disjoint files.

| Run | Owner | Files | Status |
|---|---|---|---|
| R1 | opus | research only — the CitizenFX source (master `0d8a2a6f7`): `cfx-nui-<res>` is served for every resource with or without a `ui_page`, the response headers, the 255-char vfs path cut, `files {}` as the allow-list, what `restart` vs `refresh` re-globs, the held NUI callback `cb`, CEF 103's feature set → `…/scratchpad/uiplat/R1-fivem-source.md`, condensed into DESIGN §38.1 | complete — every row carries its file:line |
| R2 | opus | inventory of the old world: every plugin entry, `window.CoreUI` use, third-party deps, CSS, module-level side effects, Lua calls and tests, plus every doc line stating the build-time rule (§C7) → `…/scratchpad/uiplat/R2-repo-inventory.md` | complete — became the docs worklist |
| P1 | opus | mechanism prototype outside the repo: cross-origin `import()`, the one-Vue shim, utilities-only Tailwind, `preserveEntrySignatures`, the module-map URL pinning, Vite HMR against an attached shell → `P1-prototype-report.md` | complete — six of its findings are now `coreUI()` behaviour |
| I3 | opus | `shared/ui_manifest.lua` (new), `client/ui_plugins.lua` (new), `server/ui_plugins.lua` (new), `client/ui.lua` (focus stack + `modal`, `owner`, `update`/`patch`/`feed`/`onRequest`/`request`, `ui_ready` replay order, `script`/`style` removed), `client/api.lua`, `server/ui.lua`, `client/ui_remote.lua`, `shared/config.lua`, `fxmanifest.lua`, `types/core.lua`, `tests/stubs.lua` (client NUI stubs), `tests/client_ui_tests.lua` (new) | complete — run_tests 385, server_tests 776, client_ui_tests 277 (275 + the `/uiplugins` dev-origin follow-up), client_chat_tests 40, fxlint 0/0 |
| I1 | opus | the SDK + tooling: `ui/sdk/**` (`package.json` `@core/ui`, `src/contract.ts`, `src/index.ts` facade, generated `src/client.d.ts`, `theme.css`, `reference.css`, `tsconfig.plugin.json`, `vite/index.mjs` = `coreUI()`, `src/dev/**` dev host + mock, `templates/`, `tests/*.test.mjs`), `ui/scripts/{gen-kit-types,check-plugins}.mjs`, `ui/tsconfig.json`, `ui/package.json`, workspace root `package.json` | complete — facade ~1.1 kB min / 0.57 kB gz, `vue-tsc` clean, TypeScript pinned `^5.9.3` |
| I2a | opus | the shell runtime: `ui/src/runtime/{protocol,transport,scope,plugins,pages,layers,feeds,errors,host,inspector}.ts`, `ui/src/shell.ts`, `ui/src/main.ts`, `ui/src/shell/{PageHost,PluginBoundary,Inspector}.vue`, `ui/src/recipes.css`, `styles.css` (`source(none)` + explicit `@source`), `coreui.js`/`store.js`/`bridge.js`/`App.vue`, `ui/tests/unit/**`; **deleted** `ui/src/plugins.js` and `ui/src/main.js` | complete — units green, shell 101/101, kit 195/195, `window.CoreUI` surface intact |
| I4 | opus | migrated `inventory`, `charcreator`, `trucking`, `core_example` and `core/templates/plugin` + `scripts/new-plugin.sh`: per-plugin `ui/package.json`, `vite.config.ts`, `tsconfig.json`, `.gitignore`, `defineUIPlugin` entry, `core_ui 'ui/dist'` + `files { 'ui/dist/**' }`, committed `ui/dist/`; inventory's module-level subscriptions and window listeners moved into `attach(ctx)` called from `setup(ctx)`; `core_example` + the template became the TypeScript showcase | complete — `check-plugins` 4 plugins, 0 errors |
| I5 | opus | integration: `ui/tests/nui-serve.mjs` (one ORIGIN per resource, FiveM's exact headers and query stripping), `ui/tests/fixtures/**` + `build-fixtures.mjs` (8 fixture resources incl. the failure cases), `runtime-regression.js`, `run-browser-suites.mjs`, `bench.mjs` + `bench-page.js` → `BENCH.md`, `scripts/check.sh` (9 steps), `.github/workflows/*.yml`, `.gitignore` | complete — runtime regression 135/135 |
| D1 | opus | `README.md` (build + "UI plugins" + the three dev loops + state/requests/plugins API + `Config.UI` keys + commands + troubleshooting + checklist steps 26–35), `AGENTS.md` (§1–§6, §8), `PLAN.md` (this table), superseded-markers in `DESIGN.md` outside §38, `ui/src/stories/docs/*.mdx` + new `UIPlatform.mdx` | complete |

Review rounds (all folded back into DESIGN §38 before the code was written, which is why §38 reads like a
post-mortem in places): **patch paths** — the first draft addressed the page's 0-based JS view, so
`Core.UI.patch('inv', 'slots.' .. slot, v)` with a Lua slot number would silently hit the neighbour; §38.10 now
specifies Lua's 1-based view with the R1/R2 rules applied identically on both sides, and advises keying
collections by strings. **Page-open ownership** — the shell must never close a page because a plugin came or
went; open state is Lua's, the shell only unmounts, and the single exception (a failed plugin holding focus)
posts `ui_close`. **Waiting for a plugin** — the old fixed 5 s guess became a wait on the load promise itself
with `Config.UI.PluginLoadTimeoutMs`. **`setup` must be synchronous**, or a restart races the next activation.
**Third-party CSS** — a banned Chromium-103 feature inside a bundled dependency's JS string literal warns
instead of failing the build, or `@lucide/vue` would make a plugin unbuildable. **Token opacity modifiers**
(`bg-error/15`) compiled to unguarded `color-mix()` in plugin builds and were invisible in game; `coreUI()` now
guards them behind `@supports`, which is why charcreator's soft tints appear for the first time.

Measured (`ui/tests/BENCH.md`, medians of 11 runs): a player downloads **378.5 kB** of JS instead of 649.5 kB
(-42 %; gzip 211.6 → 128.2 kB) and 137.3 kB of CSS instead of 176.0 kB (-22 %); shell startup did not regress
(43.9 ms vs 54.4 ms, spread wider than the difference); plugin load 8.6 ms cold / 2.2 ms warm; `page:open` to
mounted 5.2 ms; a one-slot patch is 81 B against a 7 947 B snapshot for a 200-slot inventory (98×), with one
slot component re-rendered instead of 200; feeds flush at the frame rate no matter the input rate; ten
registered plugins with no page open run zero timers, zero rAF and zero observers.

Open: **nobody could test in game** (FXServer down, no client) — `…/scratchpad/uiplat/INGAME-CHECKLIST.md` is
merged into README steps 26–35, and step 27 (cross-resource `import()` inside the real CEF 103) is the one that
decides the architecture. Also open: `@lucide/vue` and `@dnd-kit/*` are now bundled per plugin rather than once,
so two plugins using the same library ship it twice (deliberate: a shared vendor chunk would re-introduce the
coupling §38 removes).

## Runs (2026-09-18 — scale pass: 1,000–2,000 players, driven by the inventory's performance pass)

Trigger: the inventory's resmon work (inventory DESIGN §11.8) plus Liam's "we will probably have 1–2k players".
Facts read from the FiveM source first: `TriggerClientEvent(-1)` is one reliable packet per connected client
(`ServerResources.cpp`), entity state bags only route to clients that hold the entity (`ServerGameState.cpp`),
resmon averages a resource's own time over 64 frames (`ResourceMonitor.h`). The "Scale." rule in AGENTS §3 is new.

| run | model | owns | result |
|---|---|---|---|
| orchestrator | — | `lib/net/shared.lua` (`Net.emitMany`: payload packed once, one `TriggerClientEventInternal` per target), `client/main.lua` (client hook `pedChanged (ped, previous)` out of the 1 s death-watch thread), `server/remote.lua` (`Audio.playAt` on grid candidates + `emitMany`), `server/stats.lua` (decay pass chunked: 100 players / 250 ms, period compensated), `server/player.lua` (autosave pass chunked: 25 sessions / 250 ms), `tests/run_tests.lua`, DESIGN §3.6 / §4 / §8 / §9 / §20, README, `types/core.lua`, AGENTS §3 + §5 | `run_tests` 385 → 401 |
| G | opus | `server/playergrid.lua` (new, internal `Core.PlayerGrid`: 128 m cells, staggered refresh — every player once per 2 s in 250 ms slices — `candidates(coords, range, out)` with 64 m slack, empty-grid and absurd-radius fallbacks, `pending` set for sessions without a ped), `server/getters.lua` (`getInRange`, `getClosest`), `server/chat.lua` (`sendNear`, proximity, `/s`), `server/api.lua` (internal name), `fxmanifest.lua`, `tests/server_tests.lua`, DESIGN §22.1 + §9, README, `types/core.lua` | chat proximity with 60 online asks 7 players for coords instead of 60; results identical to brute force over 300 randomised players; `server_tests` 776 → 835, orchestrator +7 (audio, chunked autosave) → 842 |

Still a full loop on purpose: global/staff/faction chat, `/players`, name search, `worldsync`/`notify`
broadcasts (genuinely global, rare). Open: `sendToPerm` asks `Perms.has` per player per staff line — a
staff-holder index is the scale fix if staff chat ever gets busy. Nothing here was tested in game.

## World prompts — 3D interaction dots (DESIGN §6.7) — 2026-09-18

Liam: *"Implement 3D Interaction with WorldToScreen … using our Interaction Dot, when the Player is near
enough and looks at the Interaction it should turn to the KeyHint. For example in Inventory Item pickups."*
Decisions: **opt-in** per interaction (`worldPrompt`), and for those entries the world dot **replaces** the
bottom-center textUI pill. The `CoreInteractionDot` kit component already exists (§37.5) — this run feeds it
with real projected coordinates and mounts it. The contract lives in DESIGN §6.7 (written before this plan).

Spec: the client scan additionally collects enabled `.worldPrompt` entries within `range` m (nearest
`MaxVisible`); a second thread projects each `coords + offsetZ` with `GetScreenCoordFromWorldCoord` every frame
while that list is non-empty, marks the one nearest the reticle (normalized screen distance, aspect-scaled)
`focused`, and sends a whole-set `worldprompts:set` NUI message only when something visible changed (reused
tables — a still camera sends nothing). `core_interact` prefers the focused entry over the scan's `active`
one; `onEnter`/`onExit`/`canInteract` and the server-side checks are unchanged. Server-side entries
(`Interactions.addGlobal/addFor`) carry `worldPrompt` through `toWire` untouched.

Config (`shared/config.lua`, new block inside `Interactions`):
`WorldPrompt = { Enabled = false, Range = 15.0, OffsetZ = 0.0, FocusRadius = 0.15, MaxVisible = 8 }`.

Natives (verified with `fxref show` in this session; implementer re-verifies, apiset client):
`GetScreenCoordFromWorldCoord(x,y,z) -> ok, normalizedX, normalizedY` (GRAPHICS; false when not visible to the
rendering camera), `GetAspectRatio(false)` (GRAPHICS). `DoesEntityExist`/`GetEntityCoords(entity,false)` only
for `entity` targets (already in the file's header).

| Run | Owner | Files | ~Lines | Status |
|---|---|---|---|---|
| A | fivem-implementer | `shared/config.lua`, `client/interactions.lua`, `client/ui.lua` (one `UIInternal.worldPromptBatch` seam), `types/core.lua` (`CoreInteractionOptions`/`CoreInteractionWorldPromptOptions`) | +15, +210, +8, +10 | complete |
| B | fivem-implementer | `ui/src/store.js`, `ui/src/shell/WorldPrompts.vue` (new), `ui/src/App.vue`, `ui/src/stories/WorldPrompts.stories.js` (new) | +30, ~45, +2, ~70 | complete |
| C | fivem-implementer | `tests/stubs.lua` (projection stubs), `tests/client_ui_tests.lua` (new world-prompt suite), `ui/tests/shell-regression.js` (worldprompts section) | +25, +140, +40 | complete — client_ui 277 → 311, shell 101 → 107 |
| D | main | `README.md`, `AGENTS.md` (§5 counts), `core_example/client/main.lua` (`worldPrompt = true` on the demo interaction), inventory wiring (`shared/config.lua`, `server/drops.lua`, `server/ops.lua`, `server/main.lua`, `client/drops.lua`, `client/main.lua`, inventory `DESIGN.md`, `tests/suites/drops_suite.lua`), `PLAN.md` | | complete after fix round below |

Fix round (orchestrator, after run C's findings): the `UIInternal.worldPromptBatch` seam was defined ABOVE
`local function send`, so its body called the nil global and killed the projection thread on the first send —
moved below `send`; `focusedId` was never assigned (dead focused-preference) — `project()` now sets it from the
focus winner and clears it when the set empties; a set whose last dot left the screen sent no clear — the dirty
check now also compares the projected count against `sentCount`; the projection thread no longer spins at
`Wait(0)` while NUI focus is held (it idles at 250 ms) and a failed send retries on `WP_RETRY_MS` instead of
every frame; the scan now keeps the nearest `MaxVisible` prompts instead of the first `pairs()` order. Inventory
ground drops register a per-prop `Core.Interactions.add({ entity = obj, worldPrompt = ... })` (removed with the
prop) and the page-less `inventory:pickup` callback (`Inv.Ops.pickup`), replacing the aggregate count pill.
Inventory suites 1963 → 1970, shell browser suite PASS 107/107, full `scripts/check.sh` green, `fxlint` core
and inventory 0/0.

Invariants for the implementer:
- `client/interactions.lua` keeps its **one scan thread**; the projection thread is the only new loop
  (`Wait(0)` only while the prompt list is non-empty, else 250 ms — fxlint-safe adaptive wait).
- **No Lua allocation in the projection loop** on an unchanged frame; the NUI message table and its item
  tables are reused (bounded by `MaxVisible`), positions rounded to 4 decimals, dirty check per slot
  (`id/focused/disabled/label` string/boolean compare, `x`/`y` epsilon 0.0005, enter/leave message).
- A slot that is seen and then projected behind the camera leaves the message that frame; the set is sorted
  nearest-first by the scan.
- The textUI is suppressed **only** for `entry.worldPrompt` entries in `activate()` and the label-refresh
  branch; every other producer (doors, drops, respawn) is untouched.
- `worldPrompt = true | { enabled?, range?, offsetZ?, icon?, description? } | false | nil`; `nil` resolves
  from `Config.Interactions.WorldPrompt.Enabled`. `icon`/`description` sanitized (32/64).
- Focus: `d = ((x - 0.5) * aspect)^2 + (y - 0.5)^2 ≤ FocusRadius^2`; among candidates the in-`radius`
  (not disabled) one wins, then the smaller `d`. Interact target = focused entry, else active entry.
- `Core.on('uiReady', …)` forces the next frame to send (a reloaded shell forgot the set).
- The shell widget is `fixed inset-0 z-20 pointer-events-none`; item px = `x * innerWidth`, `y * innerHeight`;
  `side = x > 0.6 ? 'left' : 'right'`; re-read the viewport on `resize`; `CoreInteractionDot` is globally
  registered (no import). Never a literal colour/radius outside the kit.
- No per-frame `.state` reads, no `GetGamePool`, no broadcast, no new net event; the only message is
  `worldprompts:set` (whole set; `items = {}` clears).

Test surface:
- Lua: a new `client_ui_tests.lua` VM with `client/api.lua`, `client/interactions.lua`, `client/ui.lua`;
  stub `GetScreenCoordFromWorldCoord` (`stubs.projectWorld`) and `GetAspectRatio` (`stubs.aspectRatio`);
  assert: `worldPrompt` entry never shows `textui:show`; a `worldprompts:set` carries it with normalized
  coords; center projection ⇒ `focused = true` / `disabled = false`; off-center ⇒ `focused = false`; beyond
  radius ⇒ `disabled = true`; empty list clears; `core_interact` runs the focused entry's `onInteract`
  (and falls back to active when nothing is focused); `setLabel` re-sends the new label.
- Shell: `worldprompts:set` renders `.core-interaction-dot` at `x * innerWidth` px, idle by default, focused
  item shows the key cap + label, `items = []` clears; click-through.
- Story: `Built-ins/World Prompts` with a focused and an idle dot (mirror `TextUI.stories.js`).

In-game checklist (Liam): walk up to a `worldPrompt` interaction → dot on the point (no bottom pill); look at
it → key cap + label, press E → the action fires exactly once; look away → back to the dot; walk out → gone;
a locked/out-of-reach dot shows the outline lock; `resmon` while a dot is visible ≤ ~0.03 ms and 0.00–0.01 ms
idle; no NUI messages while standing still looking at a dot. Also on the list: `restart core` re-registers;
`/uiplugins` unaffected.


### World prompts — feedback round (Liam, in-game: too far, hovering, laggy)

| run | owner | files | result |
|---|---|---|---|
| E1 | main | `shared/config.lua` (`WorldPrompt.Range 15 → 6.0`), `client/interactions.lua` (position sends throttled to `WP_SEND_MS` ~30 Hz, structural changes bypass; `changed` seed fixed so an empty forced set still sends), `ui/src/store.js` (`worldprompts:set` applied IN PLACE on per-id `reactive` objects — stable identity, only changed bindings re-render), `ui/src/shell/WorldPrompts.vue` (wrapper carries the point as `transform: translate3d` + 34 ms linear transition), `ui/src/stories/WorldPrompts.stories.js`, inventory `shared/config.lua` (`PromptRange 12 → 6.0`) + `client/drops.lua` (`GetModelDimensions` centre height, `PromptOffsetZ 0.2` fallback), both DESIGN docs | core 401/842/311/40, inventory 1970, shell 107/107, kit 195/195, runtime 152/152, fxlint 0/0 |

Why: per-frame NUI messages are the known CEF jank source (community NUI resources update at 20–50 ms and
interpolate; native systems like vPrompt/ox_target draw in the render thread). The dot now moves on the
compositor between ~30 Hz sends, and its world height comes from the model it sits on.

### World prompts — native renderer (Liam: "can we also draw it native / scaleform then? Read also FiveM Sourcecode")

Source read (local checkout `FiveM/fivem`, master `0d8a2a6f7`): `SEND_NUI_MESSAGE` is registered in
`nui-resources/src/ResourceUIScripting.cpp:103` and ends in `nui::PostFrameMessage` — one CEF process-message
IPC per call, which is what made the dot janky. `extra-natives-five/src/RuntimeAssetNatives.cpp:1099` exposes
`CREATE_RUNTIME_TXD`, `CREATE_RUNTIME_TEXTURE`, `SET_RUNTIME_TEXTURE_PIXEL`, `COMMIT_RUNTIME_TEXTURE` and
`CREATE_RUNTIME_TEXTURE_FROM_DUI_HANDLE` (`CREATE_DUI` in `nui-resources/.../ResourceUIScripting.cpp:340`); a
DUI is one CEF window per instance, so N dots would mean N browsers — rejected. `DrawSprite` + the HUD text
natives run in the game render thread: no IPC, frame-perfect, which is how vPrompt/ox_target-scale systems do
it.

| run | owner | files | result |
|---|---|---|---|
| N1 | main | `shared/config.lua` (`WorldPrompt.Renderer = 'native'`), `client/interactions.lua` (native renderer: runtime-painted sprites ring/dot/cap/lock, DrawSprite + font-4 text, pulse, disabled lock, 1080p scaling, 5 s resolution refresh, 2 s sprite pre-warm), `tests/stubs.lua` (native stubs + draw recording), `tests/client_ui_tests.lua` (`newInteractionsClient(renderer)` + native suite), DESIGN §6.7 + §9, README | core 401/842/324/40, inventory 1970, fxlint 0/0 |

Fixed during the run: the native block first referenced `frame` before its `local` declaration and `bestSlot`
was scoped inside the projection `if` (the NUI loop then compared against a nil global) — both caught by the
offline suites; `DrawSprite` must take the texture dict NAME, not the `CreateRuntimeTxd` handle (caught in
review, asserted in the native suite).

N1 follow-up (Liam, in-game): the label was anchored at x = 0.0 (`EndTextCommandDisplayText(0.0, ty)` — the x is
the anchor, `SetTextWrap` only bounds the line), so it drew at the left screen edge; now the anchor is the cap
side and the label flips with it. Idle dot enlarged 14/6 → 20/9 px (`WP_RING_PX`/`WP_DOT_PX`), cap unchanged
(the `E` was reported good). client_ui 324/0, fxlint 0/0.

N2 (Liam, in-game): dot too small, KeyHint unlike the kit, pulse not the brand red, and "can we use our font?".
Read `FiveM/fivem` master `0d8a2a6f7`: `RegisterFontFile`/`RegisterFontId` (`TextChangingFunctions.cpp:123`) feed
Scaleform's font manager from a streamed `.gfx` font library (`sfFontStuff.cpp:64` looks up `<name>.gfx` in the
streamer) — no runtime TTF path, and Scaleform itself only takes Flash-era fonts. Built one with JPEXS FFDec
26.3.0 (LGPL, build-time only): `scripts/font-to-gfx.java` imports the TTF via FFDec's font machinery and saves
with the GFX signature; `scripts/build-font-gfx.sh` decompresses the kit's woff2 and runs it. Round-trip through
FFDec reproduces advance widths within 0.0005 em. `stream/barlow_condensed.gfx` is committed.
Renderer changes: ring 30 / core 13, pulse in `--color-accent` (246,80,63), label in Barlow Condensed, band =
`--color-hud` DrawRect sized by `EndTextCommandGetWidth(true)` + a generated fading tail sprite. client_ui
324 → 332, fxlint 0/0. New stream asset ⇒ `refresh` before `restart core`.

N3 (Liam, in-game): "I only see Glyphs. Dot can be a bit bigger still. Make sure KeyHint is 1 to 1 to Kit."
Ring 30 → 36 / core 13 → 16. The band dropped `DrawRect` for a stretched 1×1 `--color-hud` texel + the fade
sprite (one pipeline for everything). Kit geometry now exact: near edge `cap/2 + 8`, label inset 14, tail 76,
height 36, cap radius 3 and `--color-key` fill, label `--color-fg`, key `--color-key-fg`; the cap scales in
(130 ms) like the kit's transition. Built the 700 weight too (`barlow_condensed_bold.gfx`, CoreKey is 700) and
calibrated text through `GetRenderedCharacterHeight` so a line is exactly the kit's 15 px at any resolution.
client_ui 331/0, fxlint 0/0.

N4: the label rendered as boxes/fallback. Root cause found by diffing against the GFx format: a plain
`DefineFont2` tag inside a `.gfx` is NOT enumerated by Scaleform's font provider — that is the conversion
`gfxexport` performs (the community pipeline's missing step). FFDec exposes the target class directly, so
`scripts/font-to-gfx.java` now builds a fresh **`DefineCompactedFont`** (tag 1005, GFx-native) and fills it
through `addCharacter` (advances are stored per glyph; `setAdvanceValues` is unsupported there). Verified by
FFDec dump (`DefineCompactedFont (chid: 1, fn: "Barlow Condensed")`, tagId 1005) and a TTF round-trip (only
the soft-hyphen edge case differs by >0.01 em). No Lua/test changes; both `.gfx` rebuilt.

N5 (Liam): look-gating, a 1-2 px seam between band body and fade, and the prompt "sliding" ~5% while the
camera moves. Look-gating: `core_interact` no longer falls back to the proximity-active entry when that entry
is a worldPrompt one. Seam: the body+fade pair became ONE `--color-hud` texture painted per measured width
(last 76 px ramping out) and cached per quantized width — a single quad cannot have a filtered junction.
Slide: the qb-target-proven fix — all draws now happen under `SetDrawOrigin` at the world point (plus
`SetScriptGfxAlignParams(0,0,0,0)`), so the render thread projects the origin with the final camera instead of
the script projecting one frame ahead of it; the script-side projection stays only for the look-at test.
client_ui 334/0, fxlint 0/0.

N6: the font still rendered as boxes. Web research (Cfx forum + community repos) surfaced a working
`stream/supermarket.gfx`: it is `ExporterInfo` + `FileAttributes` + **`DefineFont3`** + **`ExportAssets`** (the font
exported under its name) + ShowFrame/End — i.e. gfxexport converts the swfmill DefineFont2 to DefineFont3 and
exports the symbol. Neither a plain DefineFont2 nor FFDec's DefineCompactedFont is enumerated by Scaleform's
provider, which is why the glyphs stayed boxes. `scripts/font-to-gfx.java` now emits that exact structure
(FFDec's `DefineFont3Tag` + `ExportAssetsTag` + `ExporterInfo`), verified tag-for-tag against supermarket.gfx.
Resmon: 0.15–0.20 ms came from per-frame text measurement (`EndTextCommandGetWidth`) and `GetAspectRatio`; the
label width is now cached per label/resolution (regression test asserts one measurement across frames) and the
aspect is cached with the 5 s resolution refresh. client_ui 335/0, fxlint 0/0.

N7 (Liam: still ~0.10 ms in resmon while the hint is up): what a per-frame renderer costs here is the number
of native calls it makes (each goes through the runtime's invoke path), so the pass was counted with a scratch
harness over `tests/stubs.lua` and the count cut without changing a single drawn pixel. Removed per frame: the
looked-at dot's wasted draw-origin group (it opened one in the idle loop, drew nothing, cleared it, then opened
its own), the duplicate `SetScriptGfxAlignParams`/`ResetScriptGfxAlign` bracket the hint added on top of the
idle loop's, and the second `GetGameTimer` (`project(now)` now takes the projection thread's timestamp and
hands it down). Removed per frame in Lua: `string.upper` of the label and the `widthPx .. ':' .. tailPx` concat
inside `bandTexture` — the whole hint layout (uppercased text, measured width, band sprite + its normalized
width) is one cache keyed on the RAW `entry.label` plus text scale and resolution, rebuilt outside the draw
bracket. Same draws, same argument values, same order (idle dots first, hint on top), no native added or
dropped. Measured: lone idle dot 12 → 11 calls/frame, lone looked-at hint 33 → 28, +6 per further idle dot
unchanged (75 → 70 at `MaxVisible` 8). The suite now asserts the steady-state budget itself (draw origins,
origin clears, one gfx-align bracket, one `GetGameTimer`, no texture creation) and that a renamed label
rebuilds the cache exactly once. client_ui 335 → 344/0, run_tests 401/0, server 842/0, chat 40/0, fxlint 0/0.

N8 (Liam: "nothing really changed" after N7 — expected in hindsight: 5 of ~30 calls is inside resmon's noise,
the per-call invoke cost is the lever): core's manifest now sets `use_experimental_fxv2_oal 'yes'`, FiveM's
direct native route (DESIGN §30.4) — **an experiment until the in-game resmon number is in**; one line to
revert. Before flipping a switch that changes every native call in core, client and server, the differences
between the two routes were read from the Cfx source and core was audited mechanically against FiveM's own
parameter lists (scratch `oal_audit.py` over fxref's DB): 841 call sites of 323 natives (309 eligible for the
direct route), 0 extra non-zero arguments, 0 vector-for-scalar arguments. Nothing breaks — but three places
were WRONG on the default route and would have silently changed behaviour with the switch, so they were made
route-agnostic first (the on/off comparison then measures performance only): `lib/net` ACE fallback
(`IsPlayerAceAllowed(...) == true` can never be true, a BOOL return is `false`/`1`), `Raycast.between`
(`if not hit` — the BOOL out-value is the integer 0 and `not 0` is false, so every miss was reported as a hit
at 0,0,0) and `Vehicles.getProps` (`lightsOn == true` — lights were never saved as on). The ACE stub now
answers `1`/`false` like the shipped wrapper, so the fallback test pins the fix instead of hiding the bug.
run_tests 401/0, server 842/0, client_ui 344/0, chat 40/0, fxlint 0/0. In-game: resmon at an inventory drop
(world prompt only) and at the example shop (also `world.lua` marker + label), raycast users (inventory
context, remote, trucking delivery), headlight state across a vehicle save/restore.

N9 (the looked-at hint as ONE Scaleform movie; two parallel runs off one contract — A built the movie and its
builder, B the renderer, tests and docs): N7 counted the pass and N8 attacked the per-call cost, and what was
left is that the HINT is the loop — 22 of the 28 native calls a lone hint makes per frame are its own draws
(2 sprites, 18 text natives, the draw-origin pair), while an idle dot costs 5. An in-game probe (`wp_sfprobe`,
2026-09-18) settled the two open questions before a line was written: `DrawScaleformMovie` called between
`SetDrawOrigin` and `ClearDrawOrigin` IS projected by the render thread — the movie stays glued to the world
point exactly like the sprites — and a per-frame thread drawing one movie reads 0.03 ms in resmon where the
sprite hint reads ~0.10. Hence a HYBRID rather than "all Scaleform": the game's `ScaleformMgrArray` pool is 40
movies for the WHOLE game (HUD, minimap, phone, every resource — read from gameconfig.xml), so the idle dots
stay sprites and core holds exactly ONE movie instance, never one per dot. `stream/core_hint.gfx` (requested as
`core_hint`) is a GFX/SWF8/AS2 one-frame movie, stage 1400x64 with the cap centre at the stage centre,
`TIMELINE = this`, API `SET_HINT(key, label, disabled, left, restart)` + `HIDE()`, built by
`scripts/build-hint-gfx.sh` from `scripts/hint.as` through FFDec and committed. The renderer requests it on the
SCAN cadence when the first prompt becomes visible, keeps it until the resource stops (one pool slot),
re-requests one the game dropped, gives up after 10 s with a single warning, and per frame draws
`SetDrawOrigin` + one `DrawScaleformMovie(handle, 0.0, 0.0, 1400 * s / resX, 64 * s / resY, 255, 255, 255, 255,
0)` + `ClearDrawOrigin`; `SET_HINT` goes out only when the entry, its key, its label, `disabled` or `left`
changed (the side flip got 0.58/0.62 hysteresis, so a dot sitting on the old 0.6 threshold cannot send a method
call per frame) and `HIDE` once when focus is lost, the `promptCount == 0` early return included. The sprite
hint is untouched and is the automatic fallback while the movie loads or if it never does (`Hint = 'sprites'`
pins it); in Scaleform mode nothing measures text, and the `SetScriptGfxAlignParams`/`ResetScriptGfxAlign`
bracket now opens lazily before the first SPRITE of a frame, so a lone hint draws without one while a frame with
idle dots still has exactly one. Two rules came out of the review: the cache mirrors only what the movie was
really told (a refused `BeginScaleformMovieMethod` is retried next frame), and a new focus is announced one
frame before it is drawn — focus can jump straight from dot A to dot B with no unfocused frame and therefore no
`HIDE`, so a buffered method call would otherwise show A's content at B's position (the focus-in starts at alpha
0, so the skipped frame is invisible). Budget: a lone looked-at hint 28 → **7** native calls per frame, +6 per idle
dot plus the 2-call sprite bracket (70 → 51 at `MaxVisible` 8). client_ui 344 → 414/0 (the old native suite
pinned to `Hint = 'sprites'` so every sprite check stays; a new scaleform suite covers the request by name, the
movie geometry under its own draw origin, no text/band/measurement, every SET_HINT and HIDE transition, the
announce-then-draw split including a direct A -> B focus move and a refused Begin, the lone-hint per-frame
budget, the hysteresis, the never-loads fallback with its timeout release and the stop release),
run_tests 401/0, server 842/0, chat 40/0, fxlint 0/0. New stream asset ⇒ `refresh` before
`restart core`. In-game: baseline and letter-spacing of both texts against the sprite hint, band length vs. the
measured one, the left flip, the lock cap, the focus-in animation, and resmon with the hint up.

N9 in game (Liam, 2026-09-18, right after the deploy): the Scaleform hint works ("works great"). Not reported
yet, so still open: resmon for `core` with the hint up vs. an idle dot only (the number this run exists for),
the item-by-item look check above, and the probe's second round (`sfprobe e|f|g`).

N10 (the idle dots: fewer native calls per dot, and fewer projections per frame): with the hint down to one
movie, the DOTS were the loop — per visible idle dot per frame the harness counted 6 (point target, in reach:
`GetScreenCoordFromWorldCoord`, `SetDrawOrigin`, 3 `DrawSprite` = pulse + ring + core, `ClearDrawOrigin`), 5
out of reach (the common case: a dot is DRAWN within `range` 6 m but usable within `radius` 2 m) and +2 for an
ENTITY target (`DoesEntityExist` + `GetEntityCoords`), so a hint plus 7 entity dots — an inventory drop pile —
was 67 calls per frame. Three levers, all resting on the fact Liam's in-game probe (mode G) established for
N9: everything is drawn under `SetDrawOrigin`, so the RENDER thread projects the world point and the
script-side projection is needed only for the look-at test and the visible set, never for drawing. **D1**:
the idle dot is ONE composite runtime texture `'idle'` (the ring texture's layers plus the old `'dot'`
texture's layers converted into ring space — a dot texel r becomes `r * (16/24) / (36/48)` ring texels — and
composited on top in the same source-over order), so an out-of-reach dot is a single `DrawSprite` and the
`'dot'` texture is gone; identical at full alpha, and at `dim = 150` the halo/core overlap is composited once
instead of twice, which is the only visual difference and is accepted. The dots deliberately stay sprites
rather than becoming movies too: the same call count for the common out-of-reach dot, and zero of the game's
40 `ScaleformMgrArray` slots. **D2**: the projection pass (one `GetScreenCoordFromWorldCoord` per slot, the
visible set, the focus winner) and `IsNuiFocused` run on a 33 ms cadence — every 2nd frame at 60 fps, every
5th at 144 — while EVERY frame still draws from the cached visible set; a dirty flag set at the end of every
scan pass and by `Interactions.remove` pulls a projection forward, so a cached set can never outlive the slot
list it came from (the slot tables are reused and re-filled by the scan, which is exactly how a stale dot
would be drawn at another entry's position). **D3**: an entity target's coordinates are re-read every frame
only while they change — 8 consecutive identical reads (three scalar comparisons, no vector, no key string)
park the slot on a 250 ms read, any difference puts it back on every frame, a vanished entity leaves the
visible set at once, and the scan resets the counter when it re-fills a slot with a different entry. The
`'nui'` renderer is untouched: it needs x/y to place DOM nodes, so it projects and asks `IsNuiFocused` every
frame as before. Budget per DRAWING frame: lone Scaleform hint 7 → **5**, lone enabled idle dot 11 → **8**,
each further enabled dot 6 → **4**, each disabled dot 5 → **3**, a resting entity target +2 → **0**; averaged
over the 33 ms cadence at a 16 ms step, hint + 7 dots at `MaxVisible` 8 is 51 → **~31** (point) and 67 →
**~32** (entity). client_ui 414 → 470/0: `wpFrame(co, ms)` now advances the virtual clock (default 40 ms, so
every frame of the three existing suites stays a projection frame and every existing assertion keeps its
meaning — only the two "and its core dot" sprite checks changed, into the composite's), plus two new suites
for the cadence (one projection per 33 ms window while every frame draws, `IsNuiFocused` on projection frames
only, the focus freeze, the three dirty-flag paths including removing the looked-at entry between two 5 ms
frames, and the exact non-projection-frame budgets) and for entity targets (8 reads then 250 ms, a push
noticed at the next due read with the draw origin following, a re-filled slot starting over, a deleted entity
gone on the very next frame, and the documented trade-off that a PARKED entity is noticed at its next due
read). run_tests 401/0, server 842/0, chat 40/0, fxlint 0/0, no global write (`luac -l -l` SETTABUP _ENV = 0).
In-game: the dots must look unchanged (a disabled one is the one to compare), focus still feels immediate,
a dot on a MOVING vehicle must not judder, a pushed drop's dot follows within 250 ms, and resmon standing
among several drops is the number this run exists for.

N10 in game (Liam, 2026-09-19, after the deploy): "it's perfect" — the hint with the baked tracking and the
composite idle dots are accepted as they are. Never reported, so not claimed anywhere: resmon for `core` (hint
up, several drops in view, the direct native route before/after) and the probe's modes E/F.
