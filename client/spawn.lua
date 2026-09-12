--- core / client / spawn.lua
--- Core.Spawn (DESIGN §6.1): player model, appearance, spawning and teleporting.
--- Runs inside core; other resources reach it through the `call` export proxy.

local Streaming = Core.Streaming
local Validate = Core.Validate
local Log = Core.Log

local FADE_MS <const> = 500
local MAX_COMPONENT <const> = 11
local MAX_PROP <const> = 8

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

local function applyComponents(ped, components)
    for key, entry in pairs(components) do
        local id = toInt(key)
        if id and id >= 0 and id <= MAX_COMPONENT and type(entry) == 'table' then
            SetPedComponentVariation(ped, id,
                toInt(entry.drawable or entry[1]) or 0,
                toInt(entry.texture or entry[2]) or 0,
                toInt(entry.palette or entry[3]) or 0)
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
                SetPedPropIndex(ped, id,
                    toInt(entry.drawable or entry[1]) or 0,
                    toInt(entry.texture or entry[2]) or 0, true, 0)
            end
        end
    end
end

local function applyHeadBlend(ped, blend)
    SetPedHeadBlendData(ped,
        toInt(blend.shapeFirst) or 0, toInt(blend.shapeSecond) or 0, toInt(blend.shapeThird) or 0,
        toInt(blend.skinFirst) or 0, toInt(blend.skinSecond) or 0, toInt(blend.skinThird) or 0,
        toFloat(blend.shapeMix), toFloat(blend.skinMix), toFloat(blend.thirdMix),
        blend.isParent == true)
end

--- appearance = { components = { [id] = { drawable, texture, palette } },
---                props = { [id] = { drawable, texture } | false }, headBlend = { ... } } (all optional)
function Spawn.applyAppearance(ped, appearance)
    if type(appearance) ~= 'table' or not ped or ped == 0 then return false end
    if type(appearance.components) == 'table' then applyComponents(ped, appearance.components) end
    if type(appearance.props) == 'table' then applyProps(ped, appearance.props) end
    if type(appearance.headBlend) == 'table' then applyHeadBlend(ped, appearance.headBlend) end
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
