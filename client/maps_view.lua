--[[ core — client/maps_view.lua — what the map runtime draws and hides (DESIGN §52.4)
     Markers (the per-frame draw loop that exists only while the engine gathered something to draw),
     world model hides (applied while their region is loaded) and the editor view: declarative previews
     of data kinds and editor-only helpers within 150 m, switched on per owner (`Core.Registry` kind
     'mapEditorView'). Internal: it extends the engine handed over by client/maps_spawn.lua
     (`CoreMapsEngine.View`); client/maps.lua is the only caller.

     Natives (fxref 2026-09-26, apiset client): CreateModelHideExcludingScriptObjects(x, y, z, radius,
     modelHash, p5) (p5 = true; unlike CreateModelHide it leaves script objects visible, so our own map props
     of that model inside the radius stay), RemoveModelHide(x, y, z, radius, modelHash, p5) (p5 = false:
     "true does nothing"; that it also undoes the excluding variant is an IN-GAME CHECK — there is no
     documented excluding remove), DrawMarker (24 arguments, as client/markers.lua), DrawLine(x1, y1, z1, x2, y2, z2, r, g, b,
     a), SetDrawOrigin(x, y, z, p3), SetTextFont(font), SetTextScale(scale, size), SetTextColour(r, g, b,
     a), SetTextCentre(align), SetTextOutline(), BeginTextCommandDisplayText(text),
     AddTextComponentSubstringPlayerName(text), EndTextCommandDisplayText(x, y, p2), ClearDrawOrigin(),
     GetFinalRenderedCamRot(rotationOrder) -> vector3 (once per frame while markers are gathered: markers
     behind the camera are not drawn).
]]

local E = CoreMapsEngine
local Registry = Core.Registry
local floor = math.floor

local MAX_PREVIEW_ITEMS <const> = 8
local MAX_MARKER_DD <const> = 150.0   -- a marker's draw distance is capped here (review F14)
local CULL_MARGIN <const> = 4.0       -- the camera may be this far from the evaluation's before a re-evaluation

local View = {}
local markers, previews, counts = E.markers, E.previews, E.view
local typesById = {}
local typesState = nil          -- nil | 'loading' | 'ok'
local editorOwners, nEditors = {}, 0
local drawing = false
local nHides = 0

local function int(v)
    v = tonumber(v)
    return v and math.tointeger(v) or nil
end

local function byte(v, default)
    v = tonumber(v)
    if not v or v ~= v then return default end
    return v < 0 and 0 or (v > 255 and 255 or floor(v))
end

local function scale(v, default)
    v = tonumber(v)
    if not v or v ~= v or v <= 0 then return default end
    return v > 100 and 100.0 or v + 0.0
end

--- A marker's draw fields, flattened once per change: { type, r, g, b, a, sx, sy, sz, dd, bob, face }.
local function markerFields(e, extra)
    local m = type(extra) == 'table' and extra or {}
    local t = int(m.type)
    e.mt = (t and t >= 0 and t <= 43) and t or 1
    e.cr, e.cg, e.cb, e.ca = byte(m.r, 0), byte(m.g, 150), byte(m.b, 255), byte(m.a, 120)
    e.sx, e.sy, e.sz = scale(m.sx, 1.0), scale(m.sy, 1.0), scale(m.sz, 1.0)
    local dd = tonumber(m.dd)
    dd = (dd and dd == dd and dd > 0) and (dd > MAX_MARKER_DD and MAX_MARKER_DD or dd) or 30.0
    e.dd2 = dd * dd
    e.bob, e.face = m.bob == true, m.face == true
    -- behind the camera by more than this (along its forward vector): not drawn this frame
    e.cull = CULL_MARGIN + math.max(e.sx, e.sy, e.sz)
end

--------------------------------------------------------------------------------
-- World model hides: one per hide element, applied on region load, removed on unload
--------------------------------------------------------------------------------

local function hideOn(h)
    CreateModelHideExcludingScriptObjects(h.x, h.y, h.z, h.r, h.hash, true)
    nHides = nHides + 1
end

local function hideOff(h)
    RemoveModelHide(h.x, h.y, h.z, h.r, h.hash, false)
    nHides = nHides - 1
end

--- Creates or moves the hide `uid` of `region` (region.hides). A zero hash hides nothing.
function View.putHide(region, uid, hash, x, y, z, extra)
    local radius = type(extra) == 'table' and tonumber(extra.radius) or nil
    radius = (radius and radius == radius and radius > 0) and (radius > 500 and 500.0 or radius + 0.0) or 1.0
    local h = region.hides[uid]
    if h then
        if h.hash == hash and h.x == x and h.y == y and h.z == z and h.r == radius then return end
        hideOff(h)
        region.hides[uid] = nil
    end
    if hash == 0 then return end
    h = { hash = hash, x = x, y = y, z = z, r = radius }
    region.hides[uid] = h
    hideOn(h)
end

function View.delHide(region, uid)
    local h = region.hides[uid]
    if not h then return false end
    region.hides[uid] = nil
    hideOff(h)
    return true
end

function View.clearHides(region)
    for uid, h in pairs(region.hides) do
        region.hides[uid] = nil
        hideOff(h)
    end
end

function View.hideCount() return nHides end

--------------------------------------------------------------------------------
-- Editor view previews (declarative, built once per element and change, drawn by the draw loop)
--------------------------------------------------------------------------------

local function color(c, r, g, b, a)
    if type(c) ~= 'table' then return r, g, b, a end
    return byte(c.r or c[1], r), byte(c.g or c[2], g), byte(c.b or c[3], b), byte(c.a or c[4], a)
end

local function size3(v, d)
    if type(v) == 'number' then
        local s = scale(v, d)
        return s, s, s
    end
    if type(v) ~= 'table' then return d, d, d end
    return scale(v.x or v.sx or v[1], d), scale(v.y or v.sy or v[2], d), scale(v.z or v.sz or v[3], d)
end

--- An oriented box (yaw only) as its 8 corners: { 3, r, g, b, a, bottom 1..4, top 1..4 }.
local function boxItem(e, sx, sy, sz, r, g, b, a)
    local hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
    local rad = math.rad(e.rz)
    local c, s = math.cos(rad), math.sin(rad)
    local item, k = { 3, r, g, b, a }, 5
    for level = 0, 1 do
        local z = e.z + (level == 0 and -hz or hz)
        for i = 1, 4 do
            local ax = (i == 1 or i == 4) and -hx or hx
            local ay = i <= 2 and -hy or hy
            item[k + 1], item[k + 2], item[k + 3] = e.x + ax * c - ay * s, e.y + ax * s + ay * c, z
            k = k + 3
        end
    end
    return item
end

local function labelText(e, def, text)
    local fallback = def and type(def.label) == 'string' and def.label or nil
    if type(text) ~= 'string' or text == '' then return fallback end
    if text:sub(1, 1) == '$' then
        local fields = e.extra and e.extra.f
        local value = type(fields) == 'table' and fields[text:sub(2)] or nil
        if value == nil then return fallback end
        text = tostring(value)
    end
    return text:sub(1, 64)
end

--- The element's preview items; the type's `preview` when the tuple names its type (`extra.t`),
--- otherwise a default per kind (point: sphere marker, zone: its box, helper: a 1 m box).
local function buildPreview(e)
    local ex = e.extra
    local def = ex and type(ex.t) == 'string' and typesById[ex.t] or nil
    local list = def and type(def.preview) == 'table' and def.preview or nil
    local items = {}
    if list then
        for i = 1, math.min(#list, MAX_PREVIEW_ITEMS) do
            local p = list[i]
            local k = type(p) == 'table' and p.kind or nil
            if k == 'marker' then
                local t = int(p.type)
                local sx, sy, sz = size3(p.scale, 1.0)
                local r, g, b, a = color(p.color, 90, 170, 255, 170)
                items[#items + 1] = { 1, (t and t >= 0 and t <= 43) and t or 1, sx, sy, sz, r, g, b, a }
            elseif k == 'sphere' then
                items[#items + 1] = { 2, scale(p.radius, 1.0), 90, 170, 255, 90 }
            elseif k == 'box' then
                local sx, sy, sz = size3(p.size or ex, 1.0)
                items[#items + 1] = boxItem(e, sx, sy, sz, 90, 255, 160, 200)
            elseif k == 'label' then
                local text = labelText(e, def, p.text)
                if text then items[#items + 1] = { 4, text } end
            end
        end
    end
    if #items == 0 then
        if e.kind == 4 then
            items[1] = { 1, 28, 0.35, 0.35, 0.35, 90, 170, 255, 170 }
        elseif e.kind == 5 then
            local sx, sy, sz = size3(ex, 2.0)
            items[1] = boxItem(e, sx, sy, sz, 90, 255, 160, 200)
        else
            items[1] = boxItem(e, 1.0, 1.0, 1.0, 255, 170, 60, 200)
        end
        local text = labelText(e, def, nil)
        if text then items[2] = { 4, text } end
    end
    return items
end

local function drawPreview(e)
    local items = e.pv
    for n = 1, #items do
        local it = items[n]
        local k = it[1]
        if k == 1 then
            DrawMarker(it[2], e.x, e.y, e.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, it[3], it[4], it[5],
                it[6], it[7], it[8], it[9], false, false, 2, false, nil, nil, false)
        elseif k == 2 then
            local r = it[2]
            DrawMarker(28, e.x, e.y, e.z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r, r, r,
                it[3], it[4], it[5], it[6], false, false, 2, false, nil, nil, false)
        elseif k == 3 then
            local r, g, b, a = it[2], it[3], it[4], it[5]
            for i = 0, 3 do
                local bi, bj = 6 + i * 3, 6 + ((i + 1) % 4) * 3
                local ti, tj = bi + 12, bj + 12
                DrawLine(it[bi], it[bi + 1], it[bi + 2], it[bj], it[bj + 1], it[bj + 2], r, g, b, a)
                DrawLine(it[ti], it[ti + 1], it[ti + 2], it[tj], it[tj + 1], it[tj + 2], r, g, b, a)
                DrawLine(it[bi], it[bi + 1], it[bi + 2], it[ti], it[ti + 1], it[ti + 2], r, g, b, a)
            end
        else
            SetDrawOrigin(e.x, e.y, e.z + 0.6, 0)
            SetTextFont(4)
            SetTextScale(0.0, 0.3)
            SetTextColour(255, 255, 255, 215)
            SetTextCentre(true)
            SetTextOutline()
            BeginTextCommandDisplayText('STRING')
            AddTextComponentSubstringPlayerName(it[2])
            EndTextCommandDisplayText(0.0, 0.0, 0)
            ClearDrawOrigin()
        end
    end
end

--- The one per-frame draw loop of the map runtime: runs only while markers or previews are gathered
--- (the engine starts it after an evaluation that found some) and ends by itself when both are gone.
local function drawLoop()
    local rad, sin, cos = math.rad, math.sin, math.cos
    while (counts.nm > 0 or counts.np > 0) and not E.isStopped() do
        local nm = counts.nm
        if nm > 0 then
            -- the forward vector of this frame's camera (rotation order 2: pitch x, yaw z; degrees) and the
            -- evaluation's camera position: a dot product per marker, no allocation
            local rot = GetFinalRenderedCamRot(2)
            local pitch, yaw = rad(rot.x), rad(rot.z)
            local cp = cos(pitch)
            local fx, fy, fz = -sin(yaw) * cp, cos(yaw) * cp, sin(pitch)
            local cx, cy, cz = counts.cx, counts.cy, counts.cz
            for i = 1, nm do
                local e = markers[i]
                if e.alive and (e.x - cx) * fx + (e.y - cy) * fy + (e.z - cz) * fz > -e.cull then
                    DrawMarker(e.mt, e.x, e.y, e.z, 0.0, 0.0, 0.0, e.rx, e.ry, e.rz, e.sx, e.sy, e.sz,
                        e.cr, e.cg, e.cb, e.ca, e.bob, e.face, 2, false, nil, nil, false)
                end
            end
        end
        for i = 1, counts.np do
            local e = previews[i]
            if e.alive and e.pv then drawPreview(e) end
        end
        Wait(0)   -- per-frame: markers and previews are drawn right now; the loop ends when none are left
    end
    drawing = false
end

local function startDraw()
    if drawing then return end
    drawing = true
    CreateThread(drawLoop)
end

--------------------------------------------------------------------------------
-- Editor view (owner-tracked): the type list is fetched once, previews are drawn within 150 m
--------------------------------------------------------------------------------

local function fetchTypes()
    if typesState then return end
    typesState = 'loading'
    CreateThread(function()
        local ok, list = pcall(Core.Callback.await, 'core:maps:types')
        if not ok or type(list) ~= 'table' then
            typesState = nil   -- retried the next time a view is switched on
            return
        end
        local byId = {}
        for i = 1, #list do
            local t = list[i]
            if type(t) == 'table' and type(t.id) == 'string' then byId[t.id] = t end
        end
        typesById, typesState = byId, 'ok'
        E.resetPreviews()
    end)
end

local function applyEditor()
    E.setEditor(nEditors > 0)
    if nEditors > 0 then fetchTypes() end
end

--- Switches the editor view on or off for `owner`; it is drawn while any owner has it on.
function View.setEditorView(on, owner)
    local had = editorOwners[owner] == true
    if on == had then return end
    if on then
        editorOwners[owner], nEditors = true, nEditors + 1
        Registry.track('mapEditorView', owner, owner)
    else
        editorOwners[owner], nEditors = nil, nEditors - 1
        Registry.untrack('mapEditorView', owner)
    end
    applyEditor()
end

function View.editorOn() return nEditors > 0 end

Registry.onOwnerStop('mapEditorView', function(_, owner)
    if not editorOwners[owner] then return end
    editorOwners[owner], nEditors = nil, nEditors - 1
    applyEditor()
end)

E.setView(buildPreview, startDraw, markerFields)
E.View = View
