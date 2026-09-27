--[[ core — client/maps_preview.lua — the editor view of Core.Maps on Core.Scene (DESIGN §55.21.1, §52.4)
     The client handler of the core-internal scene kind 'map:data' (class data, fade 'self'): map points, zones,
     editor helpers and placeholders of undefined types are `map:data` nodes that reach editors only (the server's
     audience { editors = true }). A LIVE node is a record here (create answers `true`: no entity; the materialiser
     creates records within 160 m and lets them go past 190 m). Nothing is drawn unless the editor view is on
     (Core.Maps.setEditorView, owner-tracked in client/maps.lua, which loads next and drives setEditor).
     - Previews come from the element type's declarative `preview` (the `core:maps:types` list): marker, sphere,
       box (turned by the yaw), label; a '$name' value reads the node's `f` (label fields) first, then its fields
       (`size`). Without one: a point is a small sphere, a zone its box, anything else — a placeholder of an
       undefined type, a helper — a 1 m box. The list is fetched when the view turns on (again once it is older
       than 60 s) and once more for each type id a record names that the list lacks; attempts are >= 1.5 s apart
       (the callback's 1 s cooldown per player — the admin editor asks too), 3 per fetch, then the old list stays.
     - ONE loop exists only while the view is on and a record is LIVE. It draws per frame only while a record is
       within 150 m (≤ Config.Maps.MaxMarkers of them, nearest first; re-gathered every 250 ms, after 2 m of camera
       travel or a change); otherwise it checks again after ≤ 500 ms (sooner when the camera speed could close the
       gap). Per frame: one camera coord + one camera rotation read (previews behind the camera are skipped),
       marker / sphere 1 DrawMarker, box 12 DrawLine, label 10 text natives (≤ 10 labels); no allocation.
     Hand-off: `CoreSceneRuntime.mapsPreview` = { setEditor(on), stats() } for client/maps.lua (nothing on Core).

     Natives (fxref + natives.json 2026-09-27; apiset client unless noted):
       GetGameTimer(), GetFinalRenderedCamCoord() -> vector3, GetFinalRenderedCamRot(rotationOrder) -> vector3,
       DrawMarker(type, x, y, z, dirX, dirY, dirZ, rotX, rotY, rotZ, scaleX, scaleY, scaleZ, r, g, b, a, bob,
       faceCamera, p19, rotate, textureDict, textureName, drawOnEnts), DrawLine(x1, y1, z1, x2, y2, z2, r, g, b, a),
       SetDrawOrigin(x, y, z, p3), ClearDrawOrigin(), SetTextFont(font), SetTextScale(scale, size),
       SetTextColour(r, g, b, a), SetTextCentre(align), SetTextOutline(), BeginTextCommandDisplayText(text),
       AddTextComponentSubstringPlayerName(text), EndTextCommandDisplayText(x, y, p2),
       GetCurrentResourceName() (CFX shared). Runtime helpers: CreateThread, Wait, AddEventHandler.
]]

local C = CoreSceneRuntime
assert(type(C) == 'table' and type(C.mat) == 'table' and type(C.cache) == 'table',
    'client/maps_preview.lua loads after the client scene files (CoreSceneRuntime.mat / .cache), before client/maps.lua')
local mat, Log = C.mat, Core.Log
local floor, sqrt, sin, cos, rad, max, huge = math.floor, math.sqrt, math.sin, math.cos, math.rad, math.max, math.huge

local function setting(v, default, low, high)
    v = tonumber(v) or default
    if v ~= v or v < low then return low end
    return v > high and high or v
end

local KIND <const> = 'map:data'
local cfg = (type(Config) == 'table' and type(Config.Maps) == 'table') and Config.Maps or {}
local MAX_SHOWN <const> = floor(setting(cfg.MaxMarkers, 64, 0, 512))   -- previews drawn per frame (§52.5)
local RANGE <const> = 150.0                                             -- the editor view's reach (§52.4)
local RANGE2 <const> = RANGE * RANGE
local R_IN <const>, R_OUT <const> = RANGE + 10.0, RANGE + 40.0          -- the materialiser's create / delete radii
local RING <const>, NRINGS <const> = 5.0, 30                            -- distance rings: nearest first, no sort
local GATHER_MS <const>, MOVE2 <const> = 250, 4.0                       -- re-gather: 250 ms or 2 m of travel
local IDLE_MS <const>, IDLE_MIN_MS <const>, IDLE_SPEED <const> = 500, 50, 10.0
local MAX_ITEMS <const>, MAX_LABELS <const>, MAX_TEXT <const> = 8, 10, 64
local TYPES_STALE_MS <const>, FETCH_GAP_MS <const>, FETCH_TRIES <const> = 60000, 1500, 3
local SELF <const> = GetCurrentResourceName()
local EMPTY <const> = {}

local P = {}
local list, nList, byId = {}, 0, {}        -- LIVE records (swap-remove, rec.i); node id -> record
local shown, nShown = {}, 0                -- the gathered previews, nearest first
local rings, ringN = {}, {}
for i = 1, NRINGS do rings[i], ringN[i] = {}, 0 end
local typesById, typesGen, typesState, typesAt, asked = {}, 0, nil, nil, {}
local on, running, stopped, dirty, warned = false, false, false, false, false
local lx, ly, lz, nextGather, gap = huge, huge, huge, 0, huge
local fetches, lastAsk = 0, nil

--------------------------------------------------------------------------------
-- descriptor values: colours, sizes, '$field' references
--------------------------------------------------------------------------------

local function byte(v, default)
    v = tonumber(v)
    if not v or v ~= v then return default end
    return v < 0 and 0 or (v > 255 and 255 or floor(v))
end

--- '#RRGGBB' / '#RRGGBBAA' (the type schema's colour), { r, g, b, a } or { [1..4] } -> r, g, b, a with defaults.
local function colour(c, r, g, b, a)
    if type(c) == 'string' then
        local hr, hg, hb, ha = c:match('^#(%x%x)(%x%x)(%x%x)(%x?%x?)$')
        if not hr then return r, g, b, a end
        return tonumber(hr, 16), tonumber(hg, 16), tonumber(hb, 16), #ha == 2 and tonumber(ha, 16) or a
    end
    if type(c) ~= 'table' then return r, g, b, a end
    return byte(c.r or c[1], r), byte(c.g or c[2], g), byte(c.b or c[3], b), byte(c.a or c[4], a)
end

--- A literal, or '$name': the node's label fields (`f`) first, then its own fields (a zone's `size`).
local function value(fields, v)
    if type(v) ~= 'string' or v:sub(1, 1) ~= '$' then return v end
    local name, f = v:sub(2), fields.f
    local x = type(f) == 'table' and f[name] or nil
    if x == nil then x = fields[name] end
    return x
end

local function positive(v, default)
    v = tonumber(v)
    if not v or v ~= v or v <= 0 then return default end
    return v > 1000 and 1000.0 or v + 0.0
end

--- number | { x, y, z } | { sx, sy, sz } | { [1..3] } -> sx, sy, sz (each in (0, 1000], else `default`)
local function size3(v, default)
    if type(v) ~= 'table' then
        local s = positive(v, default)
        return s, s, s
    end
    return positive(v.x or v.sx or v[1], default), positive(v.y or v.sy or v[2], default),
        positive(v.z or v.sz or v[3], default)
end

--- A box around the record (its yaw only) as its 8 corners: { 3, r, g, b, a, bottom 1..4, top 1..4 }.
local function boxItem(rec, sx, sy, sz, r, g, b, a)
    local hx, hy, hz = sx * 0.5, sy * 0.5, sz * 0.5
    local yaw = rad(rec.rz)
    local c, s = cos(yaw), sin(yaw)
    local it, k = { 3, r, g, b, a }, 5
    for level = 0, 1 do
        local z = rec.z + (level == 0 and -hz or hz)
        for i = 1, 4 do
            local ax = (i == 1 or i == 4) and -hx or hx
            local ay = i <= 2 and -hy or hy
            it[k + 1], it[k + 2], it[k + 3] = rec.x + ax * c - ay * s, rec.y + ax * s + ay * c, z
            k = k + 3
        end
    end
    return it
end

--- A label's text: the literal, the '$field' value (scalars arrive as strings), else the type's label.
local function labelOf(fields, def, text)
    local v = value(fields, text)
    local kind = type(v)
    if kind == 'number' or kind == 'boolean' then v = tostring(v) elseif kind ~= 'string' then v = nil end
    if v == nil or v == '' then
        v = def and def.label
        if type(v) ~= 'string' or v == '' then return nil end
    end
    return v:sub(1, MAX_TEXT)
end

--------------------------------------------------------------------------------
-- the type list (callback core:maps:types) and the records' draw items
--------------------------------------------------------------------------------

local function ask()
    local ok, answer = pcall(function() return Core.Callback.await('core:maps:types') end)
    return ok and type(answer) == 'table' and answer or nil
end

--- One fetch at a time, >= FETCH_GAP_MS apart (the callback's cooldown is 1 s per player, and the admin editor asks
--- too): a refused or failed attempt is tried again, FETCH_TRIES in all; then the list we had stays.
local function fetchTypes()
    if typesState == 'loading' or stopped then return end
    typesState = 'loading'
    CreateThread(function()
        for _ = 1, FETCH_TRIES do
            local wait = lastAsk and lastAsk + FETCH_GAP_MS - GetGameTimer() or 0
            if wait > 0 then Wait(wait) end
            if stopped then break end
            lastAsk, fetches = GetGameTimer(), fetches + 1
            local answer = ask()
            if answer then
                local byType = {}
                for i = 1, #answer do
                    local t = answer[i]
                    if type(t) == 'table' and type(t.id) == 'string' then byType[t.id] = t end
                end
                typesById, typesState, typesAt, typesGen, dirty = byType, 'ok', GetGameTimer(), typesGen + 1, true
                return
            end
        end
        typesState = typesAt and 'ok' or nil
    end)
end

--- The record's items, built on create / change / a new type list (never per frame): { 1, type, sx, sy, sz, r, g,
--- b, a } marker · { 2, radius, r, g, b, a } sphere · { 3, r, g, b, a, 8 corners } box · { 4, text } label.
local function build(rec)
    local f = rec.node.fields
    if type(f) ~= 'table' then f = EMPTY end
    local tid = f.t or f.mapType
    local def = type(tid) == 'string' and typesById[tid] or nil
    if not def and typesState == 'ok' and type(tid) == 'string' and not asked[tid] then
        asked[tid] = true                  -- defined after the list came (or a placeholder): asked once
        fetchTypes()
    end
    local items, n, ext = {}, 0, 1.0
    local pv = def and type(def.preview) == 'table' and def.preview or EMPTY
    for i = 1, (#pv < MAX_ITEMS and #pv or MAX_ITEMS) do
        local p, it = pv[i], nil
        local kind = type(p) == 'table' and p.kind or nil
        if kind == 'marker' then
            local t = tonumber(p.type)
            local sx, sy, sz = size3(value(f, p.scale), 1.0)
            local r, g, b, a = colour(p.color, 90, 170, 255, 170)
            it, ext = { 1, (t and t >= 0 and t <= 43) and floor(t) or 1, sx, sy, sz, r, g, b, a }, max(ext, sx, sy, sz)
        elseif kind == 'sphere' then
            local d = positive(value(f, p.radius), 1.0)
            local r, g, b, a = colour(p.color, 90, 170, 255, 90)
            it, ext = { 2, d, r, g, b, a }, max(ext, d)
        elseif kind == 'box' then
            local sx, sy, sz = size3(value(f, p.size) or f.size, 1.0)
            local r, g, b, a = colour(p.color, 90, 255, 160, 200)
            it, ext = boxItem(rec, sx, sy, sz, r, g, b, a), max(ext, sx, sy, sz)
        elseif kind == 'label' then
            local text = labelOf(f, def, p.text)
            if text then it = { 4, text } end
        end
        if it then
            n = n + 1
            items[n] = it
        end
    end
    if n == 0 then   -- no usable preview: by element kind; with the list here, an unknown type is a placeholder
        local k = def and def.kind or (typesAt == nil and f.k or nil)
        if k == 'point' then
            items[1] = { 1, 28, 0.35, 0.35, 0.35, 90, 170, 255, 170 }
        elseif k == 'zone' then
            local sx, sy, sz = size3(f.size, 2.0)
            items[1], ext = boxItem(rec, sx, sy, sz, 90, 255, 160, 200), max(ext, sx, sy, sz)
        else
            items[1] = boxItem(rec, 1.0, 1.0, 1.0, 255, 170, 60, 200)
        end
        n = 1
        local text = def and labelOf(f, def, nil)
        if text then
            n = 2
            items[2] = { 4, text }
        end
    end
    rec.items, rec.n, rec.gen, rec.cull = items, n, typesGen, 4.0 + ext
end

--------------------------------------------------------------------------------
-- the draw loop: per frame only while a preview is within 150 m, else a distance check every <= 500 ms
--------------------------------------------------------------------------------

--- Nearest first (5 m rings), at most MAX_SHOWN within RANGE; `gap` = how far the nearest one outside is.
local function gather(cx, cy, cz)
    for i = 1, NRINGS do ringN[i] = 0 end
    local out2 = huge
    for i = 1, nList do
        local rec = list[i]
        local dx, dy, dz = rec.x - cx, rec.y - cy, rec.z - cz
        local d2 = dx * dx + dy * dy + dz * dz
        if d2 <= RANGE2 then
            local ring = floor(sqrt(d2) / RING) + 1
            if ring > NRINGS then ring = NRINGS end
            local k = ringN[ring] + 1
            ringN[ring], rings[ring][k] = k, rec
        elseif d2 < out2 then
            out2 = d2
        end
    end
    gap = sqrt(out2) - RANGE
    local n = 0
    for ring = 1, NRINGS do
        local l = rings[ring]
        for i = 1, ringN[ring] do
            local rec = l[i]
            l[i] = nil
            if n < MAX_SHOWN then
                if rec.gen ~= typesGen then build(rec) end   -- a new type list: rebuilt when next shown
                n = n + 1
                shown[n] = rec
            end
        end
    end
    for i = n + 1, nShown do shown[i] = nil end
    nShown = n
end

--- One record's items (skipped when its centre is behind the camera by more than its extent); -> labels drawn.
local function drawRec(rec, cx, cy, cz, fx, fy, fz, labels)
    local x, y, z = rec.x, rec.y, rec.z
    if (x - cx) * fx + (y - cy) * fy + (z - cz) * fz < -rec.cull then return labels end
    local items = rec.items
    for n = 1, rec.n do
        local it = items[n]
        local k = it[1]
        if k == 1 then
            DrawMarker(it[2], x, y, z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, it[3], it[4], it[5],
                it[6], it[7], it[8], it[9], false, false, 2, false, nil, nil, false)
        elseif k == 2 then
            local d = it[2]
            DrawMarker(28, x, y, z, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, d, d, d,
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
        elseif labels < MAX_LABELS then
            labels = labels + 1
            SetDrawOrigin(x, y, z + 0.6, false)
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
    return labels
end

--- One pass: re-gather when due, then draw what was gathered. -> true when something is within range.
local function pass()
    local t = GetGameTimer()
    local cam = GetFinalRenderedCamCoord()
    local cx, cy, cz = cam.x, cam.y, cam.z
    local dx, dy, dz = cx - lx, cy - ly, cz - lz
    if dirty or t >= nextGather or dx * dx + dy * dy + dz * dz >= MOVE2 then
        dirty, nextGather, lx, ly, lz = false, t + GATHER_MS, cx, cy, cz
        gather(cx, cy, cz)
    end
    if nShown == 0 then return false end
    local rot = GetFinalRenderedCamRot(2)   -- rotation order 2: pitch x, yaw z (degrees)
    local pitch, yaw = rad(rot.x), rad(rot.z)
    local cp = cos(pitch)
    local fx, fy, fz = -sin(yaw) * cp, cos(yaw) * cp, sin(pitch)
    local labels = 0
    for i = 1, nShown do
        local rec = shown[i]
        if not rec.dead then labels = drawRec(rec, cx, cy, cz, fx, fy, fz, labels) end
    end
    return true
end

--- Nothing within range: back when the camera could have closed the gap (its speed + 10 m/s), <= IDLE_MS.
local function idleWait()
    local _, _, _, _, _, _, speed = mat.camera()
    local ms = gap * 1000 / ((tonumber(speed) or 0) + IDLE_SPEED)
    if ms ~= ms or ms > IDLE_MS then return IDLE_MS end
    return ms < IDLE_MIN_MS and IDLE_MIN_MS or floor(ms)
end

local function loop()
    while on and nList > 0 and not stopped do
        local ok, drew = pcall(pass)
        if not ok then
            if not warned then
                warned = true
                Log.warn('maps: editor preview failed: %s', tostring(drew))
            end
            drew = false
        end
        if drew then
            Wait(0)   -- per-frame: previews within 150 m are drawn right now; the loop ends with the view
        else
            Wait(idleWait())
        end
    end
    for i = 1, nShown do shown[i] = nil end
    nShown, running, lx, ly, lz = 0, false, huge, huge, huge
end

local function ensureLoop()
    if running or stopped or not on or nList == 0 then return end
    running = true
    CreateThread(loop)
end

--------------------------------------------------------------------------------
-- the 'map:data' handler (C.mat) and the hand-off to client/maps.lua
--------------------------------------------------------------------------------

local HANDLER = { class = 'data', fade = 'self' }

--- Every record: visible range 150 m, created within 160 m, let go past 190 m.
function HANDLER.radii() return RANGE, R_IN, R_OUT end

local function setPose(rec, node)
    rec.node = node
    rec.x, rec.y, rec.z, rec.rz = node.x or 0.0, node.y or 0.0, node.z or 0.0, node.rz or 0.0
end

function HANDLER.create(node)
    local id = node.id
    local rec = byId[id]
    if not rec then
        rec = { id = id, i = nList + 1, items = EMPTY, n = 0, gen = -1, cull = 5.0, dead = false }
        nList = rec.i
        list[nList], byId[id] = rec, rec
    end
    setPose(rec, node)
    build(rec)
    dirty = true
    ensureLoop()
    return true
end

--- Any change (fields, pose, kind): the items again, in place.
function HANDLER.update(node)
    local rec = byId[node.id]
    if not rec then return false end
    setPose(rec, node)
    build(rec)
    dirty = true
end

function HANDLER.destroy(node)
    local rec = byId[node.id]
    if not rec then return end
    byId[node.id], rec.dead = nil, true
    local i, last = rec.i, list[nList]
    list[i], last.i = last, i
    list[nList], nList = nil, nList - 1
    dirty = true
end

mat.registerKind(KIND, HANDLER)

--- The editor view is on (any owner, client/maps.lua counts them): fetch the type list when needed, draw.
function P.setEditor(v)
    v = v == true
    if v == on then return end
    on = v
    if not on then return end            -- the loop ends on its next pass
    asked = {}
    if typesAt == nil or GetGameTimer() - typesAt >= TYPES_STALE_MS then fetchTypes() end
    dirty = true
    ensureLoop()
end

function P.stats()
    local nTypes = 0
    for _ in pairs(typesById) do nTypes = nTypes + 1 end
    return { previews = nShown, dataNodes = nList, types = nTypes, typesState = typesState or 'none',
        drawing = running, fetches = fetches, editorView = on }
end

-- core stops: the materialiser destroys every record; the loop ends on its next pass
AddEventHandler('onClientResourceStop', function(resource)
    if resource == SELF then stopped, on = true, false end
end)

C.mapsPreview = P
