--[[ core — client/scene_fx.lua — the built-in DRAWN non-entity kinds of Core.Scene (DESIGN §55.12): light,
     particle, marker, text, and the per-frame draw loop. `create` answers `true` (particles keep their ptfx handle
     privately: a handle the materialiser sees is always an entity), so every record lives here, keyed by node id.
     update() re-reads node.fields (false only when a particle's asset/name changed, or a text lost its text =
     re-create). hide, zone, sound and group live in client/scene_world.lua (next in the manifest), which extends
     this file's `C.fx`: C.fx.onZone is defined there, C.fx.stats / shutdown / recordOf / handlers cover both.
     - ONE draw loop exists only while a light, marker or text is live or a fade runs, and it runs PER FRAME only
       while one of them is within its draw range (range x 3 / drawDistance) or a fade runs (§9 rule); otherwise
       it re-checks the distances after min(IDLE_MS, gap / (camera speed + 10 m/s)). Per pass: one camera read,
       a rotation read only when a marker/text is in range, no allocation; markers/texts behind the camera
       skipped, ≤ MAX_TEXT_DRAWS draw-origin groups per frame. Every pass runs under pcall: an error is logged
       once (C.kinds.warnOnce) and each record is run on its own once more — the one that fails is dropped
       (update() then answers false and the materialiser re-creates it), the loop and the others keep going.
     - fades are the handlers' own (`fade = 'self'`): a late arrival ramps in over Fades.PropInMs, a destroy
       while the camera is within its visible range ramps out over Fades.PropOutMs (lights: intensity; particles:
       SetParticleFxLoopedAlpha, then StopParticleFxLooped; markers/texts: alpha); none above Speed.NoFadeAbove.
       A ramp's clock starts at the first pass that steps it (an idling loop never shows it half-way). A node
       re-created while its record still fades out takes that record back.
     Spot lights: `dir` (world vector) wins; else the node's rotation, where (0, 0, yaw) points straight DOWN and
     pitch tilts it up (90 = horizontal along yaw). Point lights have no script shadows; `falloff` is their
     falloff exponent (DRAW_LIGHT_WITH_RANGEEX).

     Natives (fxref + natives.json runtime names, 2026-09-26, apiset client; Rockstar headers for the meaning):
       DrawLightWithRange(x, y, z, r, g, b, range, intensity), DrawLightWithRangeAndShadow(x, y, z, r, g, b, range,
       intensity, falloffExponent), DrawSpotLight(x, y, z, dirX, dirY, dirZ, r, g, b, distance, brightness,
       innerAngle, outerAngle, exponent), DrawSpotLightWithShadow(… same …, shadowId 0..n-1 per frame),
       UseParticleFxAsset(name), StartParticleFxLoopedAtCoord(name, x, y, z, rx, ry, rz, scale, invX, invY, invZ,
       localOnly), StartParticleFxLoopedOnEntity(name, entity, ox, oy, oz, rx, ry, rz, scale, invX, invY, invZ),
       StartParticleFxLoopedOnEntityBone(name, entity, ox, oy, oz, rx, ry, rz, boneIndex, scale, invX, invY, invZ),
       SetParticleFxLoopedAlpha(handle, alpha), SetParticleFxLoopedColour(handle, r, g, b, localOnly),
       SetParticleFxLoopedScale(handle, scale), SetParticleFxLoopedOffsets(handle, x, y, z, rx, ry, rz),
       StopParticleFxLooped(handle, localOnly),
       DrawMarker (24 arguments, as client/markers.lua), SetDrawOrigin(x, y, z, p3), ClearDrawOrigin(),
       SetTextFont, SetTextScale(0.0, size), SetTextColour, SetTextCentre, SetTextOutline(),
       BeginTextCommandDisplayText('STRING' | 'CELL_EMAIL_BCON' for > 99 bytes), AddTextComponentSubstringPlayerName,
       EndTextCommandDisplayText(x, y, p2),
       GetFinalRenderedCamCoord(), GetFinalRenderedCamRot(2), GetOffsetFromEntityInWorldCoords(entity, x, y, z),
       DoesEntityExist(entity), GetGameTimer(), GetCurrentResourceName().
]]

local C = CoreSceneRuntime
assert(C and C.mat and C.kinds, 'client/scene_fx.lua needs client/scene_kinds.lua first')

local K = C.kinds
local Clock = Core.Clock
local floor, sqrt, sin, cos, rad, mtype = math.floor, math.sqrt, math.sin, math.cos, math.rad, math.type
local int, num, vec, pose = K.int, K.num, K.vec, K.pose   -- the readers scene_kinds uses

local cfg = (type(Config) == 'table' and type(Config.Scene) == 'table') and Config.Scene or {}
local fades = type(cfg.Fades) == 'table' and cfg.Fades or {}
local speedCfg = type(cfg.Speed) == 'table' and cfg.Speed or {}

local FADE_IN_MS <const> = tonumber(fades.PropInMs) or 300
local FADE_OUT_MS <const> = tonumber(fades.PropOutMs) or 450
local NO_FADE_ABOVE <const> = tonumber(speedCfg.NoFadeAbove) or 80
local MARKER_FADE_M <const> = 10.0     -- §55.12: markers (and texts) fade over the last 10 m of drawDistance
local MAX_TEXT_DRAWS <const> = 20      -- draw-origin groups per frame (the engine allows 32; prompts need some)
local MAX_SHADOWED <const> = 4         -- shadowed spot lights per frame; the rest draw without a shadow
local ANCHOR_CHECK_FRAMES <const> = 30 -- anchored draw records re-check their entity every 30th frame
local IDLE_MS <const> = 250            -- nothing within its draw range: the loop checks again at most this late
local IDLE_MIN_MS <const> = 16         -- ... and at least a frame's worth later
local IDLE_SPEED_MARGIN <const> = 10   -- m/s added to the camera speed for the idle wait (movers carry records)
local MAX_TEXT_BYTES <const> = 297     -- 3 components of 99 bytes (the schema caps text at 128 characters)

local FX = {}
local R = {}                  -- node id -> record (every fx kind)
local draws = { light = {}, marker = {}, text = {} }   -- live draw lists (swap-remove, rec.di = index)
local nDraw = { light = 0, marker = 0, text = 0 }
local fading, nFading = {}, 0 -- records whose `a` is ramping (rec.fi = index)
local nFlicker = 0            -- live lights with a flicker (the only per-frame Clock.now() reader)
local drawing, stopped = false, false

local function byte(v, default)
    v = tonumber(v)
    if not v or v ~= v then return default end
    return v < 0 and 0 or (v > 255 and 255 or floor(v))
end

--- { r, g, b, a } or { [1..4] } -> r, g, b, a bytes with defaults.
local function rgba(c, dr, dg, db, da)
    if type(c) ~= 'table' then return dr, dg, db, da end
    return byte(c.r or c[1], dr), byte(c.g or c[2], dg), byte(c.b or c[3], db), byte(c.a or c[4], da)
end

--------------------------------------------------------------------------------
-- self fades: `a` (0..1) ramps; a record that ramps to 0 while dying is finalised
--------------------------------------------------------------------------------

local fwd = {}   -- defined further down: finalize(rec) (a record goes for good), ensureDraw()

local function camSpeed()
    local _, _, _, _, _, _, speed = C.mat.camera()
    return tonumber(speed) or 0
end

--- Starts a ramp of `a` towards `target`. The clock starts at the first pass that steps it (fadeAt = nil until
--- then), so a loop that was idling when the ramp began never shows it half-way through.
local function fadeTo(rec, target, ms)
    rec.fadeFrom, rec.fadeTarget, rec.fadeAt, rec.fadeMs = rec.a, target, nil, ms
    if not rec.fi then
        nFading = nFading + 1
        fading[nFading], rec.fi = rec, nFading
    end
    fwd.ensureDraw()
end

local function fadeDone(rec)
    local i = rec.fi
    if not i then return end
    local last = fading[nFading]
    fading[i], last.fi = last, i
    fading[nFading], rec.fi = nil, nil
    nFading = nFading - 1
end

--- Steps every running fade by the clock (allocation-free; runs in the draw loop).
local function stepFades(now)
    local i = 1
    while i <= nFading do
        local rec = fading[i]
        local at = rec.fadeAt
        if not at then
            at = now
            rec.fadeAt = now
        end
        local t = rec.fadeMs > 0 and (now - at) / rec.fadeMs or 1
        if t >= 1 then
            rec.a = rec.fadeTarget
            fadeDone(rec)            -- swaps the last record into slot i: look at i again
            if rec.onFade then rec.onFade(rec) end
            if rec.dying and rec.a <= 0 then fwd.finalize(rec) end
        else
            rec.a = rec.fadeFrom + (rec.fadeTarget - rec.fadeFrom) * (t < 0 and 0 or t)
            if rec.onFade then rec.onFade(rec) end
            i = i + 1
        end
    end
end

--------------------------------------------------------------------------------
-- records: one per node id; draw lists; appear / vanish / take back
--------------------------------------------------------------------------------

local EMPTY <const> = {}
local NO_ASSETS <const> = {}
local FINAL = {}      -- kind -> fn(rec): what finalising a record of that kind releases

local function drawAdd(rec)
    local kind = rec.kind
    local n = nDraw[kind] + 1
    nDraw[kind] = n
    draws[kind][n], rec.di = rec, n
    if rec.flick then nFlicker = nFlicker + 1 end
    fwd.ensureDraw()
end

local function drawRemove(rec)
    local i = rec.di
    if not i then return end
    local kind = rec.kind
    local list, n = draws[kind], nDraw[kind]
    local last = list[n]
    list[i], last.di = last, i
    list[n], rec.di = nil, nil
    nDraw[kind] = n - 1
    if rec.flick then nFlicker = nFlicker - 1 end
end

function fwd.finalize(rec)
    if rec.fi then fadeDone(rec) end
    if rec.di then drawRemove(rec) end
    local fin = FINAL[rec.kind]
    if fin then fin(rec) end
    if R[rec.id] == rec then R[rec.id] = nil end
    rec.gone, rec.dying = true, false
end

local function setPose(rec, x, y, z, rx, ry, rz)
    rec.x, rec.y, rec.z, rec.rx, rec.ry, rec.rz = x, y, z, rx, ry, rz
end

local function newRecord(node, kind, ctx)
    local rec = { id = node.id, kind = kind, node = node, a = 1.0 }
    setPose(rec, pose(node, ctx))
    R[node.id] = rec
    return rec
end

--- Draw records of a child (or an attached node) follow their anchor entity every frame.
local function anchorRecord(rec, node)
    rec.anchor = K.anchorOf(node)
    if rec.anchor then rec.ox, rec.oy, rec.oz = vec(node.offset, 0.0, 0.0, 0.0) end
end

local function follow(rec, check)
    local e = rec.anchor
    if check and not DoesEntityExist(e) then
        rec.anchor = nil
        return
    end
    local p = GetOffsetFromEntityInWorldCoords(e, rec.ox, rec.oy, rec.oz)
    rec.x, rec.y, rec.z = p.x, p.y, p.z
end

--- A late arrival (inside its visible range, ctx.late) ramps in; everything else is there at once.
local function appear(rec, ctx)
    if type(ctx) == 'table' and ctx.late == true and camSpeed() <= NO_FADE_ABOVE then
        rec.a = 0.0
        if rec.onFade then rec.onFade(rec) end   -- applied now: a running loop steps it only next frame
        fadeTo(rec, 1.0, FADE_IN_MS)
    else
        rec.a = 1.0
    end
end

--- Destroy: ramps out while the camera is within `visible` metres (and slow enough), else goes at once.
local function vanish(rec, visible)
    if rec.a > 0 and visible and visible > 0 and camSpeed() <= NO_FADE_ABOVE then
        local cx, cy, cz = C.mat.camera()
        local dx, dy, dz = rec.x - cx, rec.y - cy, rec.z - cz
        if dx * dx + dy * dy + dz * dz <= visible * visible then
            rec.dying = true
            fadeTo(rec, 0.0, FADE_OUT_MS)
            return
        end
    end
    fwd.finalize(rec)
end

--- create() of a node whose record still fades out: take it back (ramp in from where it is). A record of
--- another kind, or one that is not dying, is finalised first.
local function takeBack(node, kind)
    local rec = R[node.id]
    if not rec then return nil end
    if rec.kind == kind and rec.dying then
        rec.dying, rec.node = false, node
        fadeTo(rec, 1.0, FADE_IN_MS)
        return rec
    end
    fwd.finalize(rec)
    return nil
end

local function live(node)
    local rec = R[node.id]
    if not rec or rec.dying then return nil end
    rec.node = node
    return rec
end

--------------------------------------------------------------------------------
-- light
--------------------------------------------------------------------------------

local FLICKER <const> = { candle = 1, neon = 2, strobe = 3 }

--- Flicker gain at shared-clock time `t` (integer ms): the same on every client (seeded), allocation-free.
local function flickerAt(mode, t, seed)
    if mode == 1 then       -- candle: two incommensurate sines, 0.5 .. 1
        local s = (seed % 1000) + 0.0
        return 0.75 + 0.125 * (sin(t * 0.0113 + s) + sin(t * 0.0271 + s * 1.7))
    elseif mode == 2 then   -- neon: on, dropping to 15 % in about one 120 ms slot of 24
        local h = ((t // 120) * 1103515245 + seed * 12345) % 2147483648
        return (h // 65536) % 24 == 0 and 0.15 or 1.0
    elseif mode == 3 then   -- strobe: 10 Hz on/off
        return ((t + seed * 37) // 50) % 2 == 0 and 1.0 or 0.0
    end
    return 1.0
end
FX.flickerAt = flickerAt

--- A spot light's direction from the node's rotation: (0, 0, yaw) points DOWN, pitch tilts it up.
local function spotDir(rec)
    if rec.fixedDir then return end
    local p, y = rad(rec.rx - 90.0), rad(rec.rz)
    local cp = cos(p)
    rec.dx, rec.dy, rec.dz = -sin(y) * cp, cos(y) * cp, sin(p)
end

local function lightFields(rec, node, f)
    rec.spot = f.type == 'spot'
    rec.r, rec.g, rec.b = rgba(f.color, 255, 255, 255, 255)
    rec.intensity = num(f.intensity, 5.0, 0.0, 100.0)
    rec.range = num(f.range, 10.0, 0.1, 100.0)
    rec.vis = rec.range * 3                    -- R_vis: past it nothing is drawn, a destroy never fades
    rec.vis2 = rec.vis * rec.vis
    rec.shadow = f.shadow == true
    rec.falloff = f.falloff ~= nil and num(f.falloff, nil, 0.0, 10000.0) or nil
    rec.inner, rec.outer = num(f.inner, 1.0, 0.0, 180.0), num(f.outer, 30.0, 0.0, 180.0)
    local flick = FLICKER[f.flicker]
    if rec.di and (flick ~= nil) ~= (rec.flick ~= nil) then nFlicker = nFlicker + (flick and 1 or -1) end
    rec.flick, rec.seed = flick, int(f.seed) or node.id
    if type(f.dir) == 'table' then
        local x, y, z = vec(f.dir, 0.0, 0.0, -1.0)
        local len = sqrt(x * x + y * y + z * z)
        if len < 1e-6 then x, y, z, len = 0.0, 0.0, -1.0, 1.0 end
        rec.dx, rec.dy, rec.dz, rec.fixedDir = x / len, y / len, z / len, true
    else
        rec.fixedDir = false
        spotDir(rec)
    end
end

local function drawLight(l, k, shadows)
    local intensity = l.intensity * k
    if l.spot then
        local exp = l.falloff or 1.0
        if l.shadow and shadows < MAX_SHADOWED then
            DrawSpotLightWithShadow(l.x, l.y, l.z, l.dx, l.dy, l.dz, l.r, l.g, l.b, l.range, intensity,
                l.inner, l.outer, exp, shadows)
            return shadows + 1
        end
        DrawSpotLight(l.x, l.y, l.z, l.dx, l.dy, l.dz, l.r, l.g, l.b, l.range, intensity, l.inner, l.outer, exp)
    elseif l.falloff then
        DrawLightWithRangeAndShadow(l.x, l.y, l.z, l.r, l.g, l.b, l.range, intensity, l.falloff)
    else
        DrawLightWithRange(l.x, l.y, l.z, l.r, l.g, l.b, l.range, intensity)
    end
    return shadows
end

local LIGHT = { class = 'fx', budget = 'lights', fade = 'self' }

function LIGHT.radii(node)   -- range × 3 | min(range × 3 + 50, 300) | R_in + 30 (§55.11)
    local range = num((node.fields or EMPTY).range, 10.0, 0.1, 100.0)
    local vis = range * 3
    local rin = vis + 50 < 300 and vis + 50 or 300.0
    return vis, rin, rin + 30
end

--- The shared create path of the draw kinds: a new record (or the one taken back), fields, appear, list.
local function createDrawn(node, ctx, kind, fieldsFn)
    local f = node.fields or EMPTY
    local rec = takeBack(node, kind)
    local fresh = rec == nil
    if fresh then
        rec = newRecord(node, kind, ctx)
    else
        setPose(rec, pose(node, ctx))
    end
    anchorRecord(rec, node)
    if fieldsFn(rec, node, f) == false then   -- unusable fields (a text without text)
        fwd.finalize(rec)
        return nil
    end
    if fresh then
        appear(rec, ctx)
        drawAdd(rec)
    end
    K.syncInteract(node, nil, rec.x, rec.y, rec.z)
    return true
end

--- update() of the draw kinds: fields in place, 'move' re-places at the node's base pose.
local function updateDrawn(node, what, fieldsFn, onMove)
    local rec = live(node)
    if not rec then return false end
    if fieldsFn(rec, node, node.fields or EMPTY) == false then return false end
    if what == 'move' or what == 'attach' then
        setPose(rec, pose(node, nil))
        anchorRecord(rec, node)
        if onMove then onMove(rec) end
    end
    K.syncInteract(node, nil, rec.x, rec.y, rec.z)
    return true
end

--- place() of the draw kinds (movers): the record's pose; anchored records follow their entity instead.
local function placeDrawn(node, _, x, y, z, rx, ry, rz)
    local rec = R[node.id]
    if not rec or rec.anchor then return end
    setPose(rec, x, y, z, rx, ry, rz)
    if rec.spot then spotDir(rec) end
end

--- destroy() of the 'self'-fading kinds: prompts go at once, the record ramps out while in view (rec.vis).
local function destroyDrawn(node)
    K.clearInteract(node.id)
    local rec = R[node.id]
    if not rec or rec.dying then return end
    vanish(rec, rec.vis)
end

function LIGHT.create(node, ctx) return createDrawn(node, ctx, 'light', lightFields) end
function LIGHT.update(node, _, what) return updateDrawn(node, what, lightFields, spotDir) end
LIGHT.place, LIGHT.destroy = placeDrawn, destroyDrawn

--------------------------------------------------------------------------------
-- particle (looped ptfx; the asset is requested in WARM, `UseParticleFxAsset` before every start)
--------------------------------------------------------------------------------

local function particleAlpha(rec)
    SetParticleFxLoopedAlpha(rec.h, rec.alpha * rec.a)
end

local function startPtfx(rec, node, f)
    local scale = num(f.scale, 1.0, 0.01, 50.0)
    UseParticleFxAsset(f.asset)
    local anchor, h = K.anchorOf(node), nil
    if anchor then   -- a child (or an attached node) plays on its anchor entity
        local ox, oy, oz = vec(node.offset, 0.0, 0.0, 0.0)
        local rx, ry, rz = vec(node.offrot, 0.0, 0.0, 0.0)
        if node.bone ~= nil then
            h = StartParticleFxLoopedOnEntityBone(f.name, anchor, ox, oy, oz, rx, ry, rz, K.boneOf(anchor, node.bone),
                scale, false, false, false)
        else
            h = StartParticleFxLoopedOnEntity(f.name, anchor, ox, oy, oz, rx, ry, rz, scale, false, false, false)
        end
    else
        h = StartParticleFxLoopedAtCoord(f.name, rec.x, rec.y, rec.z, rec.rx, rec.ry, rec.rz, scale,
            false, false, false, false)
    end
    if not h or h == 0 then return false end
    rec.h, rec.onEntity, rec.scale, rec.asset, rec.name = h, anchor ~= nil, scale, f.asset, f.name
    rec.cr, rec.alpha = nil, nil
    return true
end

--- Colour, scale and alpha that differ from what the effect has.
local function particleLook(rec, f)
    local scale = num(f.scale, 1.0, 0.01, 50.0)
    if scale ~= rec.scale then
        SetParticleFxLoopedScale(rec.h, scale)
        rec.scale = scale
    end
    local r, g, b = rgba(f.color, 255, 255, 255, 255)
    if r ~= rec.cr or g ~= rec.cg or b ~= rec.cb then
        if rec.cr or type(f.color) == 'table' then
            SetParticleFxLoopedColour(rec.h, r / 255, g / 255, b / 255, false)
        end
        rec.cr, rec.cg, rec.cb = r, g, b
    end
    local alpha = num(f.alpha, 1.0, 0.0, 1.0)
    if alpha ~= rec.alpha then
        rec.alpha = alpha
        particleAlpha(rec)
    end
end

local function particleOk(f)
    return type(f.asset) == 'string' and f.asset ~= '' and type(f.name) == 'string' and f.name ~= ''
end

local PARTICLE = { class = 'fx', budget = 'particles', fade = 'self' }

function PARTICLE.assets(node)
    local f = node.fields or EMPTY
    if not particleOk(f) then return NO_ASSETS end
    return { { type = 'ptfx', name = f.asset } }
end

local function drawDistance(f, default)
    return num(f.drawDistance, default, 1.0, 1000.0)
end

function PARTICLE.radii(node)   -- drawDistance | + 10 | + 20 past R_in (§55.11)
    local dd = drawDistance(node.fields or EMPTY, 150.0)
    return dd, dd + 10, dd + 30
end

function PARTICLE.create(node, ctx)
    local f = node.fields or EMPTY
    if not particleOk(f) then return nil end
    local rec = takeBack(node, 'particle')
    if rec and (rec.asset ~= f.asset or rec.name ~= f.name) then
        fwd.finalize(rec)
        rec = nil
    end
    if rec then
        particleLook(rec, f)
    else
        rec = newRecord(node, 'particle', ctx)
        if not startPtfx(rec, node, f) then
            R[node.id] = nil
            return nil
        end
        rec.onFade = particleAlpha
        particleLook(rec, f)   -- before appear(): a fade stepped at once needs rec.alpha
        appear(rec, ctx)
    end
    rec.vis = drawDistance(f, 150.0)
    K.syncInteract(node, nil, rec.x, rec.y, rec.z)
    return true
end

function PARTICLE.update(node, _, what)
    local rec = live(node)
    if not rec then return false end
    local f = node.fields or EMPTY
    if f.asset ~= rec.asset or f.name ~= rec.name or what == 'attach' then return false end   -- re-create
    particleLook(rec, f)
    rec.vis = drawDistance(f, 150.0)
    if what == 'move' and not rec.onEntity then
        setPose(rec, pose(node, nil))
        SetParticleFxLoopedOffsets(rec.h, rec.x, rec.y, rec.z, rec.rx, rec.ry, rec.rz)
    end
    K.syncInteract(node, nil, rec.x, rec.y, rec.z)
    return true
end

function PARTICLE.place(node, _, x, y, z, rx, ry, rz)
    local rec = R[node.id]
    if not rec or rec.onEntity or rec.dying then return end
    setPose(rec, x, y, z, rx, ry, rz)
    SetParticleFxLoopedOffsets(rec.h, x, y, z, rx, ry, rz)
end

PARTICLE.destroy = destroyDrawn

function FINAL.particle(rec)
    if rec.h then StopParticleFxLooped(rec.h, false) end   -- live particles finish their own lifetime
    rec.h = nil
end

--------------------------------------------------------------------------------
-- marker and text (drawn by the fx loop; alpha over the last metres of drawDistance)
--------------------------------------------------------------------------------

local function distanceFields(rec, dd)
    rec.dd, rec.dd2, rec.vis = dd, dd * dd, dd
    rec.band = dd * 0.4 < MARKER_FADE_M and dd * 0.4 or MARKER_FADE_M
end

local function markerFields(rec, _, f)
    local t = int(f.type)
    rec.mt = (t and t >= 0 and t <= 43) and t or 1
    rec.cr, rec.cg, rec.cb, rec.ca = rgba(f.color, 0, 150, 255, 120)
    if type(f.scale) == 'table' then
        local x, y, z = vec(f.scale, 1.0, 1.0, 1.0)
        rec.sx, rec.sy, rec.sz = num(x, 1.0, 0.01, 100.0), num(y, 1.0, 0.01, 100.0), num(z, 1.0, 0.01, 100.0)
    else
        local s = num(f.scale, 1.0, 0.01, 100.0)
        rec.sx, rec.sy, rec.sz = s, s, s
    end
    rec.bob, rec.face, rec.rotate = f.bob == true, f.face == true, f.rotate == true
    distanceFields(rec, drawDistance(f, 50.0))
    rec.cull = 4.0 + math.max(rec.sx, rec.sy, rec.sz)   -- behind the camera by more than this: skipped
end

local function ddRadii(default)
    return function(node)
        local dd = drawDistance(node.fields or EMPTY, default)
        return dd, dd + 10, dd + 30
    end
end

local MARKER = { class = 'fx', budget = 'markers', fade = 'self', radii = ddRadii(50.0) }
function MARKER.create(node, ctx) return createDrawn(node, ctx, 'marker', markerFields) end
function MARKER.update(node, _, what) return updateDrawn(node, what, markerFields) end
MARKER.place, MARKER.destroy = placeDrawn, destroyDrawn

--- The end (inclusive) of a ≤ 99-byte chunk of `s` from `from` that does not split a UTF-8 character.
local function chunkEnd(s, from)
    local e = from + 98
    if e >= #s then return #s end
    while e > from do
        local b = s:byte(e + 1)
        if b < 0x80 or b >= 0xC0 then break end   -- the next byte starts a character: cut here
        e = e - 1
    end
    return e
end

--- text -> label, t1, t2, t3: one GTA text component holds 99 bytes; longer text uses the 10-slot label.
local function splitText(s)
    if #s <= 99 then return 'STRING', s, nil, nil end
    local parts, from = {}, 1
    while from <= #s and #parts < 3 do
        local e = chunkEnd(s, from)
        parts[#parts + 1] = s:sub(from, e)
        from = e + 1
    end
    return 'CELL_EMAIL_BCON', parts[1], parts[2], parts[3]
end
FX.splitText = splitText

local function textFields(rec, _, f)
    local text = f.text
    if mtype(text) then text = tostring(text) end
    if type(text) ~= 'string' or text == '' then return false end
    if #text > MAX_TEXT_BYTES then text = text:sub(1, chunkEnd(text, MAX_TEXT_BYTES - 98)) end
    if text ~= rec.text then
        rec.text = text
        rec.label, rec.t1, rec.t2, rec.t3 = splitText(text)
    end
    rec.scale = num(f.scale, 0.35, 0.05, 3.0)
    local font = int(f.font)
    rec.font = (font and font >= 0) and font or 4
    rec.cr, rec.cg, rec.cb, rec.ca = rgba(f.color, 255, 255, 255, 215)
    rec.outline = f.outline == true
    distanceFields(rec, drawDistance(f, 25.0))
end

local TEXT = { class = 'fx', budget = 'texts', fade = 'self', radii = ddRadii(25.0) }
function TEXT.create(node, ctx) return createDrawn(node, ctx, 'text', textFields) end
function TEXT.update(node, _, what) return updateDrawn(node, what, textFields) end
TEXT.place, TEXT.destroy = placeDrawn, destroyDrawn

--------------------------------------------------------------------------------
-- the draw loop: per frame while a light, marker or text is within its draw range or a fade runs; otherwise a
-- distance-gated check every <= IDLE_MS. Every pass runs under pcall; a record that fails on its own is dropped.
--------------------------------------------------------------------------------

local frameN = 0
-- the pass's shared state (one table, reused): camera, forward (read lazily), flicker time, counters
local F = { cx = 0.0, cy = 0.0, cz = 0.0, fx = 0.0, fy = 1.0, fz = 0.0, rot = false, t = -1, shadows = 0,
    drawn = 0, near = 0, gap = 0.0, check = false }

local function drawText(t, alpha)
    SetDrawOrigin(t.x, t.y, t.z, false)
    SetTextScale(0.0, t.scale)
    SetTextFont(t.font)
    SetTextColour(t.cr, t.cg, t.cb, alpha)
    SetTextCentre(true)
    if t.outline then SetTextOutline() end
    BeginTextCommandDisplayText(t.label)
    AddTextComponentSubstringPlayerName(t.t1)
    if t.t2 then AddTextComponentSubstringPlayerName(t.t2) end
    if t.t3 then AddTextComponentSubstringPlayerName(t.t3) end
    EndTextCommandDisplayText(0.0, 0.0, 0)
    ClearDrawOrigin()
end

--- The camera forward of this pass: read once, and only when a marker or text is within range.
local function forward()
    F.rot = true
    local rot = GetFinalRenderedCamRot(2)
    local pitch, yaw = rad(rot.x), rad(rot.z)
    local cp = cos(pitch)
    F.fx, F.fy, F.fz = -sin(yaw) * cp, cos(yaw) * cp, sin(pitch)
end

--- Out of range: keep how far the nearest record is from its range (the idle wait follows from it).
local function gapOf(d2, range)
    local gap = sqrt(d2) - range
    if gap < F.gap then F.gap = gap end
end

local function lightFrame(l)
    if l.anchor then follow(l, F.check) end
    local dx, dy, dz = l.x - F.cx, l.y - F.cy, l.z - F.cz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > l.vis2 then return gapOf(d2, l.vis) end
    F.near = F.near + 1
    local k = l.a
    if l.flick then
        if F.t < 0 then F.t = Clock.now() end   -- the shared clock, once per pass and only for a live flicker
        k = k * flickerAt(l.flick, F.t, l.seed)
    end
    if k > 0 then F.shadows = drawLight(l, k, F.shadows) end
end

--- Markers: in front of the camera and inside the draw distance, alpha over the last metres.
local function markerFrame(m)
    if m.anchor then follow(m, F.check) end
    local dx, dy, dz = m.x - F.cx, m.y - F.cy, m.z - F.cz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > m.dd2 then return gapOf(d2, m.dd) end
    F.near = F.near + 1
    if not F.rot then forward() end
    if dx * F.fx + dy * F.fy + dz * F.fz > -m.cull then
        local k = (m.dd - sqrt(d2)) / m.band
        local alpha = floor(m.ca * m.a * (k < 1 and k or 1))
        if alpha > 0 then
            DrawMarker(m.mt, m.x, m.y, m.z, 0.0, 0.0, 0.0, m.rx, m.ry, m.rz, m.sx, m.sy, m.sz,
                m.cr, m.cg, m.cb, alpha, m.bob, m.face, 2, m.rotate, nil, nil, false)
        end
    end
end

--- Texts: the same rule, at most MAX_TEXT_DRAWS draw-origin groups a pass.
local function textFrame(t)
    if t.anchor then follow(t, F.check) end
    local dx, dy, dz = t.x - F.cx, t.y - F.cy, t.z - F.cz
    local d2 = dx * dx + dy * dy + dz * dz
    if d2 > t.dd2 then return gapOf(d2, t.dd) end
    F.near = F.near + 1
    if F.drawn >= MAX_TEXT_DRAWS then return end
    if not F.rot then forward() end
    if dx * F.fx + dy * F.fy + dz * F.fz > 0 then
        local k = (t.dd - sqrt(d2)) / t.band
        local alpha = floor(t.ca * t.a * (k < 1 and k or 1))
        if alpha > 0 then
            drawText(t, alpha)
            F.drawn = F.drawn + 1
        end
    end
end

local DRAWN <const> = { 'light', 'marker', 'text' }
local FRAME_OF <const> = { light = lightFrame, marker = markerFrame, text = textFrame }

--- One pass: the fades, then every drawn record (drawn within its range, else only its distance kept).
local function pass()
    frameN = frameN + 1
    F.check = frameN % ANCHOR_CHECK_FRAMES == 0
    if nFading > 0 then stepFades(GetGameTimer()) end
    local cam = GetFinalRenderedCamCoord()
    F.cx, F.cy, F.cz = cam.x, cam.y, cam.z
    F.rot, F.t, F.shadows, F.drawn, F.near, F.gap = false, -1, 0, 0, 0, math.huge
    for k = 1, #DRAWN do
        local kind = DRAWN[k]
        local list, fn = draws[kind], FRAME_OF[kind]
        for i = 1, nDraw[kind] do fn(list[i]) end
    end
end

--- Takes a record out for good, by hand when finalising it fails too.
local function evict(rec)
    if pcall(fwd.finalize, rec) then return end
    if rec.fi then fadeDone(rec) end
    if rec.di then drawRemove(rec) end
    if R[rec.id] == rec then R[rec.id] = nil end
    rec.gone, rec.dying = true, false
end

--- A pass failed: every record once more on its own; one that fails is dropped (the error was logged once), so
--- a bad record never takes the others — or the loop — down with it.
local function quarantine()
    for k = 1, #DRAWN do
        local kind = DRAWN[k]
        local list, fn = draws[kind], FRAME_OF[kind]
        local i = 1
        while i <= nDraw[kind] do
            local rec = list[i]
            if pcall(fn, rec) then
                i = i + 1
            else
                evict(rec)
                if list[i] == rec then i = i + 1 end   -- could not be taken out: step over it
            end
        end
    end
    local i = 1
    while i <= nFading do
        local rec = fading[i]
        if not rec.onFade or pcall(rec.onFade, rec) then
            i = i + 1
        else
            evict(rec)
            if fading[i] == rec then i = i + 1 end
        end
    end
end

--- Nothing within range: sleep until the nearest record could be (the camera speed plus a margin for movers
--- carrying records), at most IDLE_MS.
local function idleWait()
    local _, _, _, _, _, _, speed = C.mat.camera()
    local ms = F.gap * 1000 / ((tonumber(speed) or 0) + IDLE_SPEED_MARGIN)
    if ms ~= ms or ms > IDLE_MS then return IDLE_MS end
    return ms < IDLE_MIN_MS and IDLE_MIN_MS or floor(ms)
end

local function drawLoop()
    while not stopped and nDraw.light + nDraw.marker + nDraw.text + nFading > 0 do
        local ok, err = pcall(pass)
        if not ok then
            K.warnOnce('fx draw loop', err)
            local okQ, errQ = pcall(quarantine)
            if not okQ then K.warnOnce('fx draw loop (quarantine)', errQ) end
        end
        if nDraw.light + nDraw.marker + nDraw.text + nFading == 0 then break end   -- the last one just went
        if not ok or F.near > 0 or nFading > 0 then
            Wait(0)   -- per-frame: something is drawn (or fading) right now
        else
            local okW, ms = pcall(idleWait)
            Wait(okW and ms or IDLE_MS)   -- nothing within its draw range: distance-gated, back within IDLE_MS
        end
    end
    drawing = false
end

function fwd.ensureDraw()
    if drawing or stopped then return end   -- a running (or idling) loop picks new records up on its next pass
    drawing = true
    CreateThread(drawLoop)
end

--------------------------------------------------------------------------------
-- registration, API, shutdown
--------------------------------------------------------------------------------

local ORDER <const> = { 'light', 'particle', 'marker', 'text' }
FX.handlers = { light = LIGHT, particle = PARTICLE, marker = MARKER, text = TEXT }   -- scene_world.lua adds its own
for i = 1, #ORDER do C.mat.registerKind(ORDER[i], FX.handlers[ORDER[i]]) end

--- The record of node `id` (tests, the debug overlay): read-only. scene_world.lua widens it to its kinds.
function FX.recordOf(id) return R[id] end

--- This file's counters; scene_world.lua adds its own to the same table.
function FX.stats()
    return { lights = nDraw.light, markers = nDraw.marker, texts = nDraw.text, fading = nFading, drawing = drawing }
end

--- Core stops: every light, effect, marker and text goes now (no fade-out).
local function shutdown()
    stopped = true
    for _, rec in pairs(R) do fwd.finalize(rec) end
end
FX.shutdown = shutdown   -- scene_world.lua wraps it so FX.shutdown() covers both files

local SELF <const> = GetCurrentResourceName()
AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= SELF then return end
    shutdown()
end)

C.fx = FX
