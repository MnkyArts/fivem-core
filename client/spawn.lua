--[[ core — client/spawn.lua
     Core.Spawn (DESIGN §6.1): player model, appearance, spawning and teleporting.
     applyAppearance carries the full freemode look (DESIGN §34) and runs on every path that dresses
     the ped, so no plugin has to hook respawns to keep a face. Shape tolerance only: values are
     clamped, a wrong type skips that entry — semantic validation belongs to the calling plugin.

     Natives verified with fxref on 2026-09-12 (apiset client, or client+server where noted; this file
     is client-side either way). Appearance:
       SetPedHeadBlendData(ped, shapeFirst, shapeSecond, shapeThird, skinFirst, skinSecond, skinThird,
         shapeMix, skinMix, thirdMix, isParent), SetPedComponentVariation(ped, componentId, drawableId,
         textureId, paletteId), SetPedPropIndex(ped, componentId, drawableId, textureId, attach),
         ClearPedProp(ped, propId, p2), SetPedFaceFeature(ped, index, scale),
         IsPedCollectionComponentVariationValid(ped, componentId, collection, drawableId, textureId),
         SetPedCollectionComponentVariation(ped, componentId, collection, drawableId, textureId, paletteId),
         GetPedPropGlobalIndexFromCollection, GetNumberOfPedCollectionPropTextureVariations(ped, anchorPoint, collection, propIndex),
         SetPedCollectionPropIndex(ped, anchorPoint, collection, propIndex, textureId, attach),
         SetPedHeadOverlay(ped, overlayID, index, opacity),
         SetPedHeadOverlayColor(ped, overlayID, colorType, colorID, secondColorID),
         SetPedHairTint(ped, colorID, highlightColorID), SetPedEyeColor(ped, index).
       SetPedFaceFeature / SetPedHeadOverlayColor / SetPedHairTint / SetPedEyeColor are nativedb
       SET_PED_MICRO_MORPH / SET_PED_HEAD_OVERLAY_TINT / SET_PED_HAIR_TINT / SET_HEAD_BLEND_EYE_COLOR;
       the FiveM Lua runtime only emits the names used here (DESIGN §34.2).
       The four *Collection* natives are CFX additions (ns CFX, apiset client): FiveM-only and present on
       every build, so §34.5's (collection, localDrawable) pair needs no game build gate.
     Model and spawn: SetPlayerModel, SetPedDefaultComponentVariation, PlayerId, PlayerPedId,
       GetEntityModel, GetHashKey, FreezeEntityPosition, SetEntityCoords, SetEntityHeading,
       NetworkResurrectLocalPlayer (client), ClearPedTasksImmediately, ClearPlayerWantedLevel,
       SetEntityVisible (client), ShutdownLoadingScreen (client), ShutdownLoadingScreenNui (client),
       DoScreenFadeOut, DoScreenFadeIn, IsScreenFadedOut, IsScreenFadingOut (client), GetGameTimer.
]]

local Streaming = Core.Streaming
local Validate = Core.Validate
local Log = Core.Log

local FADE_MS <const> = 500
local MAX_COMPONENT <const> = 11
local MAX_PROP <const> = 8
local MAX_FEATURE <const> = 19       -- DESIGN §34.1: face features 0..19, GTA's order
local MAX_OVERLAY <const> = 12       -- DESIGN §34.1: head overlays 0..12
local MAX_OVERLAY_INDEX <const> = 255 -- DESIGN §34.1: overlay variant index, 255 = none
local MAX_COLOR_TYPE <const> = 2     -- overlay colour palette: 0 none, 1 hair colours, 2 makeup colours
local MAX_PARENT <const> = 45        -- DESIGN §34.1: head blend parents 0..45

local Spawn = {}
local firstSpawnDone = false

--- json round-trips turn integer table keys into strings; accept both.
local function toInt(v)
    local n = tonumber(v)
    if not n then return nil end
    return math.tointeger(n // 1)
end

local function toFloat(v)
    local n = tonumber(v)
    if not n or n ~= n then return 0.0 end
    return n + 0.0
end

--- §34.2 tolerance: ids clamp into their domain (and to >= 0 when no max is given), never reject.
--- Returns nil when the value is not a number at all, so the caller can skip that entry silently.
local function clampInt(v, min, max)
    local n = toInt(v)
    if not n then return nil end
    if n < min then return min end
    if max and n > max then return max end
    return n
end

--- Same for §34.2's two float ranges: feature scale [-1, 1] and overlay opacity [0, 1].
local function clampFloat(v, min, max)
    local n = toFloat(v)
    if n < min then return min end
    if n > max then return max end
    return n
end

--- Blocks until the screen is fully faded out (bounded); safe to call when already faded.
local function fadeOutAndWait()
    if IsScreenFadedOut() then return end
    if not IsScreenFadingOut() then DoScreenFadeOut(FADE_MS) end
    local deadline = GetGameTimer() + FADE_MS + 1000
    -- bounded poll (<= FADE_MS + 1000 ms); 50 ms is plenty for a screen fade, no per-frame cost
    while not IsScreenFadedOut() and GetGameTimer() < deadline do
        Wait(50)
    end
end

--- §34.5: a (collection, localDrawable) pair addresses an item inside one DLC pack and survives a
--- title update, where the global index of every later pack shifts. Returns the pair when the entry
--- carries a usable one, nil when it does not (then the caller uses the global index as before).
--- The empty string is a real collection (the base game), so the test is "a string", not "non-empty";
--- §34.2 tolerance: a wrong type or a negative local index skips the pair, it never rejects the entry.
local function collectionPair(entry)
    if type(entry.collection) ~= 'string' then return nil end
    local localDrawable = toInt(entry.localDrawable)
    if not localDrawable or localDrawable < 0 then return nil end
    return entry.collection, localDrawable
end

local function applyComponents(ped, components)
    for key, entry in pairs(components) do
        local id = toInt(key)
        if id and id >= 0 and id <= MAX_COMPONENT and type(entry) == 'table' then
            local texture = clampInt(entry.texture or entry[2], 0) or 0
            local palette = clampInt(entry.palette or entry[3], 0) or 0
            local collection, localDrawable = collectionPair(entry)
            -- §34.5: a pack that is no longer streamed fails the validity check and falls back to the
            -- global index, so the slot always ends up set rather than left empty.
            if collection and IsPedCollectionComponentVariationValid(ped, id, collection, localDrawable, texture) then
                SetPedCollectionComponentVariation(ped, id, collection, localDrawable, texture, palette)
            else
                SetPedComponentVariation(ped, id, clampInt(entry.drawable or entry[1], 0) or 0, texture, palette)
            end
        end
    end
end

local function applyProps(ped, props)
    for key, entry in pairs(props) do
        local id = toInt(key)
        if id and id >= 0 and id <= MAX_PROP then
            if entry == false then
                ClearPedProp(ped, id, 0)
            elseif type(entry) == 'table' then
                local texture = clampInt(entry.texture or entry[2], 0) or 0
                local collection, localDrawable = collectionPair(entry)
                -- §34.5: -1 means that collection/index is not loaded; fall back to the global index.
                -- There is no IsPedCollectionPropValid, so the texture is bounded by hand.
                if collection and GetPedPropGlobalIndexFromCollection(ped, id, collection, localDrawable) ~= -1 then
                    local textures = GetNumberOfPedCollectionPropTextureVariations(ped, id, collection, localDrawable)
                    if type(textures) == 'number' and textures > 0 and texture >= textures then texture = textures - 1 end
                    SetPedCollectionPropIndex(ped, id, collection, localDrawable, texture, true)
                else
                    SetPedPropIndex(ped, id, clampInt(entry.drawable or entry[1], 0) or 0, texture, true, 0)
                end
            end
        end
    end
end

--- headBlend ids clamp into the 46 parent heads (§34.1), mixes into [0, 1]; this call is the first
--- thing an appearance table reaches, so it must never hand garbage to the native.
local function applyHeadBlend(ped, blend)
    SetPedHeadBlendData(ped,
        clampInt(blend.shapeFirst, 0, MAX_PARENT) or 0, clampInt(blend.shapeSecond, 0, MAX_PARENT) or 0,
        clampInt(blend.shapeThird, 0, MAX_PARENT) or 0,
        clampInt(blend.skinFirst, 0, MAX_PARENT) or 0, clampInt(blend.skinSecond, 0, MAX_PARENT) or 0,
        clampInt(blend.skinThird, 0, MAX_PARENT) or 0,
        clampFloat(blend.shapeMix, 0.0, 1.0), clampFloat(blend.skinMix, 0.0, 1.0),
        clampFloat(blend.thirdMix, 0.0, 1.0),
        blend.isParent == true)
end

--- faceFeatures = { [0..19] = -1.0 .. 1.0 }; a non-numeric value skips that feature.
local function applyFaceFeatures(ped, features)
    for key, value in pairs(features) do
        local id = toInt(key)
        if id and id >= 0 and id <= MAX_FEATURE and tonumber(value) then
            SetPedFaceFeature(ped, id, clampFloat(value, -1.0, 1.0))
        end
    end
end

--- headOverlays = { [0..12] = { index, opacity, colorType, color, color2 } }; index 255 = none,
--- missing opacity = fully opaque. The colour call only happens for colorType > 0 (§34.2) —
--- GTA leaves the overlay on the model's own colours otherwise.
local function applyHeadOverlays(ped, overlays)
    for key, entry in pairs(overlays) do
        local id = toInt(key)
        if id and id >= 0 and id <= MAX_OVERLAY and type(entry) == 'table' then
            local index = clampInt(entry.index, 0, MAX_OVERLAY_INDEX)
            if index then
                SetPedHeadOverlay(ped, id, index,
                    tonumber(entry.opacity) and clampFloat(entry.opacity, 0.0, 1.0) or 1.0)
                local colorType = clampInt(entry.colorType, 0, MAX_COLOR_TYPE) or 0
                if colorType > 0 then
                    SetPedHeadOverlayColor(ped, id, colorType,
                        clampInt(entry.color, 0) or 0, clampInt(entry.color2, 0) or 0)
                end
            end
        end
    end
end

--- hairColor = { color, highlight }; a missing or wrong-typed field falls back to 0, like applyHeadBlend.
local function applyHairColor(ped, hair)
    SetPedHairTint(ped, clampInt(hair.color, 0) or 0, clampInt(hair.highlight, 0) or 0)
end

--- Applies any subset of DESIGN §34.1 to a ped, in the §34.2 order — head blend first, because
--- freemode features and overlays only render once blend data exists.
--- appearance = { headBlend = { ... }, components = { [0..11] = { drawable, texture, palette } },
---                props = { [0..8] = { drawable, texture } | false }, faceFeatures = { [0..19] = -1..1 },
---                headOverlays = { [0..12] = { index, opacity, colorType, color, color2 } },
---                hairColor = { color, highlight }, eyeColor = int } — every key optional.
function Spawn.applyAppearance(ped, appearance)
    if type(appearance) ~= 'table' or not ped or ped == 0 then return false end
    if type(appearance.headBlend) == 'table' then applyHeadBlend(ped, appearance.headBlend) end
    if type(appearance.components) == 'table' then applyComponents(ped, appearance.components) end
    if type(appearance.props) == 'table' then applyProps(ped, appearance.props) end
    if type(appearance.faceFeatures) == 'table' then applyFaceFeatures(ped, appearance.faceFeatures) end
    if type(appearance.headOverlays) == 'table' then applyHeadOverlays(ped, appearance.headOverlays) end
    if type(appearance.hairColor) == 'table' then applyHairColor(ped, appearance.hairColor) end

    local eyeColor = clampInt(appearance.eyeColor, 0)
    if eyeColor then SetPedEyeColor(ped, eyeColor) end
    return true
end

--- Switches the player model (only when it differs) and applies the appearance on top.
function Spawn.setModel(model, appearance)
    if type(model) ~= 'string' or #model < 1 or #model > 64 then
        Log.warn('Spawn.setModel: invalid model %s', tostring(model))
        return false
    end

    local hash = GetHashKey(model)
    local ped = PlayerPedId()

    if GetEntityModel(ped) ~= hash then
        if not Streaming.requestModel(hash) then
            Log.warn('Spawn.setModel: model %s failed to load', model)
            return false
        end
        SetPlayerModel(PlayerId(), hash)
        ped = PlayerPedId()
        SetPedDefaultComponentVariation(ped)
        Streaming.releaseModel(hash)
    end

    if type(appearance) == 'table' then Spawn.applyAppearance(ped, appearance) end
    return true
end

--- Full spawn sequence (DESIGN §6.1). Returns false when the model or collision failed to load in time;
--- the ped is unfrozen and placed either way.
function Spawn.spawnPlayer(opts)
    if type(opts) ~= 'table' then return false end

    local coords = opts.coords
    local ok, err = Validate.value('vector3', coords)
    if not ok then
        Log.warn('Spawn.spawnPlayer: %s', err or 'invalid coords')
        return false
    end

    local heading = toFloat(opts.heading)
    local fade = opts.fade ~= false
    local resurrect = opts.resurrect ~= false
    local model = opts.model or Config.Player.DefaultModel
    local success = true

    if fade then fadeOutAndWait() end

    if not Spawn.setModel(model, opts.appearance) then success = false end

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)

    -- Move BEFORE waiting: Streaming.requestCollision polls HasCollisionLoadedAroundEntity(PlayerPedId()),
    -- so the ped has to sit at the destination already or the wait is a no-op and the player falls through.
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)

    if not Streaming.requestCollision(coords) then
        Log.warn('Spawn.spawnPlayer: collision not loaded at %.1f %.1f %.1f', coords.x, coords.y, coords.z)
        success = false
    end

    if resurrect then
        NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, heading, true, false, false, 0, 0)
        ped = PlayerPedId()
    end

    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    SetEntityHeading(ped, heading)
    ClearPedTasksImmediately(ped)
    ClearPlayerWantedLevel(PlayerId())
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)

    if not firstSpawnDone then
        firstSpawnDone = true
        ShutdownLoadingScreen()
        ShutdownLoadingScreenNui()
    end

    if fade then DoScreenFadeIn(FADE_MS) end
    return success
end

--- Faded teleport: fade out -> freeze -> move -> collision -> heading -> fade in.
function Spawn.teleport(coords, heading)
    local ok, err = Validate.value('vector3', coords)
    if not ok then
        Log.warn('Spawn.teleport: %s', err or 'invalid coords')
        return false
    end

    fadeOutAndWait()

    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    -- same ordering rule as spawnPlayer: move first, then wait for collision around the ped
    SetEntityCoords(ped, coords.x, coords.y, coords.z, false, false, false, false)
    Streaming.requestCollision(coords)
    if heading ~= nil then SetEntityHeading(ped, toFloat(heading)) end
    FreezeEntityPosition(ped, false)

    DoScreenFadeIn(FADE_MS)
    return true
end

Core.Spawn = Spawn
