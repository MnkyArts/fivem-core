--[[ core — client/interactions.lua
     Core.Interactions (DESIGN §6.7): point / entity / netId / models targets, one scan thread with a
     near/far cadence, exactly one active interaction, text UI prompt on enter/exit, the `core_interact`
     key mapping, an optional auto marker and owner tracking through Core.Registry. Entries with
     `worldPrompt` are collected into a second list the projection thread (the only per-frame loop)
     renders: `Renderer = 'native'` (default) draws the dot/key/label in the render thread, `Renderer =
     'nui'` sends `worldprompts:set` to the CEF shell and replaces the text UI for those entries. An idle
     dot is ONE composite DrawSprite (plus the pulse ring while it is in reach); the ONE looked-at hint is
     ONE Scaleform movie (`Hint = 'scaleform'`, default) or the DrawSprite + HUD text hint (`Hint =
     'sprites'`, and the automatic fallback while the movie loads or if it never does). Native renderer:
     every frame DRAWS, but only every WP_FOCUS_MS-th frame projects and asks `IsNuiFocused` (the render
     thread does the drawing projection through SetDrawOrigin), and an entity target's coords are re-read
     every frame only while they change — 8 identical reads park it on 250 ms.
     Natives (fxref, apiset client): GetEntityCoords, DoesEntityExist, NetworkDoesEntityExistWithNetworkId,
     NetworkGetEntityFromNetworkId, GetClosestObjectOfType, PlayerPedId, GetGameTimer, IsNuiFocused,
     GetScreenCoordFromWorldCoord, GetAspectRatio; native renderer: CreateRuntimeTxd, CreateRuntimeTexture,
     SetRuntimeTexturePixel, CommitRuntimeTexture, DrawSprite, GetActualScreenResolution, RegisterFontFile,
     RegisterFontId, GetRenderedCharacterHeight, SetDrawOrigin, ClearDrawOrigin, SetScriptGfxAlignParams,
     ResetScriptGfxAlign, SetTextFont, SetTextScale, SetTextColour, SetTextCentre, SetTextRightJustify,
     SetTextWrap, SetTextDropshadow, SetTextEdge, BeginTextCommandGetWidth, EndTextCommandGetWidth,
     BeginTextCommandDisplayText, AddTextComponentSubstringPlayerName, EndTextCommandDisplayText;
     Scaleform hint: RequestScaleformMovie, HasScaleformMovieLoaded, SetScaleformMovieAsNoLongerNeeded,
     BeginScaleformMovieMethod, ScaleformMovieMethodAddParamPlayerNameString,
     ScaleformMovieMethodAddParamBool, EndScaleformMovieMethod, DrawScaleformMovie.
     No per-frame loop beyond the projection thread: the scan runs at Config.Interactions.ScanIntervalMs
     (near) or FarScanIntervalMs (far, nothing within Config.Interactions.NearRange); the projection
     thread sleeps 250 ms while its list is empty and Wait(0)s only while dots are visible.
]]

local Interactions = {}

local entries = {}          -- id -> entry
local candidates = {}       -- reused per scan, never reallocated
local prompts = {}          -- reused per scan: the visible worldPrompt slots (1..promptCount)
local promptCount = 0       -- how many of `prompts` are live this pass
local promptDirty = false   -- a send failed (shell not ready) or state changed unseen
local forceSend = false     -- uiReady: the (reloaded) shell forgot everything
local focusedId = nil       -- id of the looked-at prompt entry, or nil
local counter = 0
local active = nil          -- ctx of the active entry, or nil
local activeLabel = nil     -- label currently shown in the text UI
local stopping = false

local SCAN_NEAR <const> = Config.Interactions.ScanIntervalMs
local SCAN_FAR <const> = Config.Interactions.FarScanIntervalMs
local NEAR_RANGE <const> = Config.Interactions.NearRange
local MAX_MODELS <const> = Config.Interactions.MaxModels
local LAST_SEEN_TTL_MS <const> = 10000      -- how long a models entry remembers where its prop was
local TEXTUI_OWNER <const> = 'interactions'          -- Core.UI text-UI ownership (client/ui.lua)
local TEXTUI_OPTS <const> = { owner = TEXTUI_OWNER } -- hoisted: a show must not allocate
local INTERACT_CMD <const> = 'core_interact'

local WP_CFG <const> = Config.Interactions.WorldPrompt or {}
local WP_ENABLED <const> = WP_CFG.Enabled == true
local WP_RANGE <const> = tonumber(WP_CFG.Range) or 6.0
local WP_OFFSET_Z <const> = tonumber(WP_CFG.OffsetZ) or 0.0
local WP_FOCUS_RADIUS <const> = tonumber(WP_CFG.FocusRadius) or 0.15
local WP_FOCUS_RADIUS_SQ <const> = WP_FOCUS_RADIUS * WP_FOCUS_RADIUS
local WP_MAX_VISIBLE <const> = tonumber(WP_CFG.MaxVisible) or 8
local WP_IDLE_MS <const> = 250
local WP_FOCUS_MS <const> = 33      -- native renderer: the projection/focus cadence; drawing stays per frame
local WP_REST_READS <const> = 8     -- identical entity reads in a row before the slot counts as resting
local WP_REST_MS <const> = 250      -- how often a resting entity's coords are re-read (§6.7)
local WP_EPSILON <const> = 0.0005
local WP_SENT <const> = { action = 'worldprompts:set', items = {} }   -- reused message; items filled per send
local WP_RETRY_MS <const> = 250     -- a failed send (shell not ready) is retried on this cadence, never per frame
local WP_SEND_MS <const> = 33       -- ~30 Hz position cadence; the shell interpolates between sends (§6.7)

-- Funcrefs from other resources must never take the scan thread down with them.
local function safeCall(fn, ctx)
    if not Core.Utils.isCallable(fn) then return nil end
    local ok, res = pcall(fn, ctx)
    if not ok then
        Core.Log.error('interaction callback failed: %s', tostring(res))
        return nil
    end
    return res
end

local function textUI(fnName, ...)
    local ui = Core.UI
    local tui = ui and ui.textUI
    local fn = tui and tui[fnName]
    if fn then fn(...) end
end

-- Resolves `opts.worldPrompt` (true | table | false | nil) to the entry's prompt fields.
-- A worldPrompt entry never gets the text UI; the dot IS its prompt.
local function applyWorldPrompt(entry, opts)
    local wp = opts.worldPrompt
    if wp == false then return end
    if wp == nil and not WP_ENABLED then return end
    local cfg = type(wp) == 'table' and wp or nil
    if cfg and cfg.enabled == false then return end
    entry.worldPrompt = true
    entry.promptRange = (cfg and tonumber(cfg.range)) or WP_RANGE
    entry.promptOffsetZ = (cfg and tonumber(cfg.offsetZ)) or WP_OFFSET_Z
    entry.promptIcon = cfg and type(cfg.icon) == 'string' and Core.Utils.sanitize(cfg.icon, 32) or nil
    entry.promptDesc = cfg and type(cfg.description) == 'string'
        and Core.Utils.sanitize(cfg.description, 64) or nil
end

-- The projection state. WP_SENT.items mirrors exactly what the shell holds (sentCount
-- entries), so a frame with an unchanged set is detected with plain comparisons and
-- sends nothing; the item tables are only (re)filled when something really changed.
local frame = {}            -- reused per frame: slots visible RIGHT NOW, scan order
-- §6.7: drawing is per frame, the projection is not. `frame[1..frameCount]` and `frameBest` are the
-- last projection pass's answer and are REDRAWN unchanged in between; `focusDirty` forces the next
-- frame to project, so a cached set can never outlive the scan (or the removal) that changed it.
local frameCount = 0        -- entries of `frame` the last projection pass filled
local frameBest = nil       -- the looked-at slot of that pass, or nil
local focusDirty = true     -- the slot list changed under the cached set: project on the next frame
local lastFocusAt = 0       -- GetGameTimer() of the last projection pass
local wpFocused = false     -- the last IsNuiFocused() answer (asked on projection frames only)
local sentCount = 0         -- entries of WP_SENT.items the shell currently holds
local retryAt = 0           -- GetGameTimer() before which a failed send is not retried
local lastSendAt = 0        -- GetGameTimer() of the last successful send (position throttle)

-- --------------------------------------------------------------- native renderer
-- §6.7: with `Renderer = 'native'` (default) the dot, the cap and the label are drawn in the
-- game's render thread — a moving dot is frame-perfect and costs zero NUI messages. The sprites
-- are runtime textures painted once from the kit's own geometry (ring, core, rounded cap, lock,
-- the band's fading tail); the label uses Barlow Condensed streamed as a GFx font library
-- (`stream/barlow_condensed.gfx`, built by scripts/build-font-gfx.sh). `Renderer = 'nui'` keeps
-- the shell's CoreInteractionDot instead.
local WP_NATIVE <const> = WP_CFG.Renderer ~= 'nui'
local WP_TXD <const> = 'core_wp'
local WP_FONT_DISPLAY <const> = 'Barlow Condensed'        -- 600, the band label
local WP_FONT_KEY <const> = 'Barlow Condensed Bold'       -- 700, the cap letter (CoreKey 700)
local WP_CAP_PX <const> = 26          -- md cap, kit §37.5
local WP_RING_PX <const> = 36         -- idle dot: bigger than the kit's 14 px so it reads in world
local WP_DOT_PX <const> = 16          -- the core's kit size; only the composite's scale reference now
-- the 'idle' composite is painted in the ring's 48 texel space: dot texels -> ring texels (§6.7)
local WP_DOT_TO_RING <const> = (WP_DOT_PX / 24.0) / (WP_RING_PX / 48.0)
local WP_BAND_H_PX <const> = 36       -- kit band min-height
local WP_BAND_GAP_PX <const> = 8      -- kit band margin-left
local WP_BAND_PAD_PX <const> = 14     -- kit band padding-left (the label inset)
local WP_BAND_TAIL_PX <const> = 76    -- kit band fading tail
local WP_LABEL_PX <const> = 15        -- kit label font-size
local WP_PULSE_MS <const> = 2400
local WP_TEXT_SCALE <const> = 0.30    -- fallback text scale at a 1080p reference
local WP_TEXT_Y <const> = 0.011       -- label anchor above the world point, 1080p normalized
local WP_INK <const> = { 20, 21, 26 }             -- --color-ink
local WP_HUD <const> = { 8, 12, 16, 173 }         -- --color-hud, rgba(8, 12, 16, 0.68)
local WP_TONE <const> = { 246, 80, 63 }           -- --color-accent #f6503f, the pulse
local WP_FG <const> = { 243, 245, 247 }           -- --color-fg, the band label
local WP_KEY_BG <const> = { 251, 251, 251 }       -- --color-key, the cap fill
local WP_KEY_FG <const> = { 17, 22, 27 }          -- --color-key-fg, the cap letter

-- The looked-at hint as ONE Scaleform movie (§6.7): 22 of the 28 native calls the sprite hint made
-- per frame were its own draws. The movie's stage is drawn centred on the world point (its origin is
-- the cap centre), so the render thread projects it exactly like the sprites. ONE instance ever —
-- the game's Scaleform pool is 40 movies for the whole game, never one per dot.
local WP_HINT_SF <const> = WP_NATIVE and WP_CFG.Hint ~= 'sprites'
local WP_HINT_MOVIE <const> = 'core_hint'
local WP_HINT_STAGE_W <const>, WP_HINT_STAGE_H <const> = 1400, 64   -- stage px, cap centre at its centre
local WP_HINT_LOAD_MS <const> = 10000      -- after this the sprite hint stays the fallback for good

local wpFontDisplay, wpFontKey = nil, nil
if WP_NATIVE then
    RegisterFontFile('barlow_condensed')
    wpFontDisplay = RegisterFontId(WP_FONT_DISPLAY)
    RegisterFontFile('barlow_condensed_bold')
    wpFontKey = RegisterFontId(WP_FONT_KEY)
end

local wpTxd = nil
local wpTex = nil           -- { ring, dot, cap, lock } runtime texture handles
local wpTexFailed = false
local screenW, screenH, screenAt = 0, 0, 0

local hintMovie = 0         -- Scaleform handle, 0 = none
local hintState = 0         -- 0 idle, 1 loading, 2 ready, 3 failed for good (sprites stay)
local hintLoadAt = 0        -- GetGameTimer() of the request, for the load timeout
local hintShown = false     -- the movie currently shows a hint (HIDE not sent yet)
-- what the movie was last told: a method call goes out only when one of these changed
local hintEntryId, hintKey, hintLabel, hintDisabled, hintLeft = nil, nil, nil, nil, false
local hintW, hintH = 0.0, 0.0     -- normalized draw size, refreshed with the resolution

local function clamp01(v)
    if v < 0.0 then return 0.0 end
    if v > 1.0 then return 1.0 end
    return v
end

--- 1 px-feathered disc coverage around (cx, cy) with radius r.
local function disc(x, y, cx, cy, r)
    local dx, dy = x - cx, y - cy
    return clamp01(0.5 + r - math.sqrt(dx * dx + dy * dy))
end

--- Rounded-rectangle SDF coverage, centred at (cx, cy) with half-size (hw, hh).
local function roundRect(x, y, cx, cy, hw, hh, radius)
    local qx = math.abs(x - cx) - (hw - radius)
    local qy = math.abs(y - cy) - (hh - radius)
    local ax, ay = math.max(qx, 0.0), math.max(qy, 0.0)
    local d = math.sqrt(ax * ax + ay * ay) + math.min(math.max(qx, qy), 0.0) - radius
    return clamp01(0.5 - d)
end

--- Source-over compositing into one pixel; colours 0..255, alpha/coverage 0..1.
local function over(r, g, b, a, cr, cg, cb, ca, cov)
    local sa = ca * cov
    if sa <= 0.0 then return r, g, b, a end
    local na = sa + a * (1.0 - sa)
    if na <= 0.0 then return 0.0, 0.0, 0.0, 0.0 end
    local w = a * (1.0 - sa)
    return (cr * sa + r * w) / na, (cg * sa + g * w) / na, (cb * sa + b * w) / na, na
end

--- Paints one runtime texture from `fn(x, y) -> r, g, b, a` (a in 0..1).
local function paint(name, width, height, fn)
    local tex = CreateRuntimeTexture(wpTxd, name, width, height)
    if not tex or tex == 0 then return nil end
    for py = 0, height - 1 do
        for px = 0, width - 1 do
            local r, g, b, a = fn(px + 0.5, py + 0.5)
            SetRuntimeTexturePixel(tex, px, py,
                math.floor(r + 0.5), math.floor(g + 0.5), math.floor(b + 0.5),
                math.floor(clamp01(a) * 255.0 + 0.5))
        end
    end
    CommitRuntimeTexture(tex)
    return tex
end

--- Builds the sprites once; a failure disables the native renderer for good.
local function ensureTextures()
    if wpTex then return true end
    if wpTexFailed then return false end
    local ok, err = pcall(function()
        local txd = CreateRuntimeTxd(WP_TXD)
        if not txd or txd == 0 then error('no runtime txd') end
        wpTxd = txd

        local ring = paint('ring', 48, 48, function(x, y)
            local r, g, b, a = 0.0, 0.0, 0.0, 0.0
            r, g, b, a = over(r, g, b, a, WP_INK[1], WP_INK[2], WP_INK[3], 0.45,
                disc(x, y, 24.0, 24.0, 11.0))
            r, g, b, a = over(r, g, b, a, 255.0, 255.0, 255.0, 0.92,
                disc(x, y, 24.0, 24.0, 9.5) - disc(x, y, 24.0, 24.0, 8.0))
            return r, g, b, a
        end)

        -- The whole idle dot as ONE sprite (§6.7): the ring's layers, then the core's halo and core
        -- converted into ring space (a dot texel r becomes r * WP_DOT_TO_RING ring texels) and
        -- composited on top in the same source-over order. Identical at dim 255; a disabled dot
        -- composites the overlap once instead of twice, which is the only difference.
        local idle = paint('idle', 48, 48, function(x, y)
            local r, g, b, a = 0.0, 0.0, 0.0, 0.0
            r, g, b, a = over(r, g, b, a, WP_INK[1], WP_INK[2], WP_INK[3], 0.45,
                disc(x, y, 24.0, 24.0, 11.0))
            r, g, b, a = over(r, g, b, a, 255.0, 255.0, 255.0, 0.92,
                disc(x, y, 24.0, 24.0, 9.5) - disc(x, y, 24.0, 24.0, 8.0))
            r, g, b, a = over(r, g, b, a, WP_INK[1], WP_INK[2], WP_INK[3], 0.45,
                disc(x, y, 24.0, 24.0, 6.5 * WP_DOT_TO_RING))
            r, g, b, a = over(r, g, b, a, 255.0, 255.0, 255.0, 1.0,
                disc(x, y, 24.0, 24.0, 3.0 * WP_DOT_TO_RING))
            return r, g, b, a
        end)

        local cap = paint('cap', 48, 48, function(x, y)
            local r, g, b, a = 0.0, 0.0, 0.0, 0.0
            r, g, b, a = over(r, g, b, a, 0.0, 0.0, 0.0, 0.5,
                roundRect(x, y + 2.0, 24.0, 24.0, 23.0, 23.0, 5.5))
            r, g, b, a = over(r, g, b, a, WP_INK[1], WP_INK[2], WP_INK[3], 0.9,
                roundRect(x, y, 24.0, 24.0, 23.0, 23.0, 5.5))
            r, g, b, a = over(r, g, b, a, WP_KEY_BG[1], WP_KEY_BG[2], WP_KEY_BG[3], 1.0,
                roundRect(x, y, 24.0, 24.0, 21.5, 21.5, 4.5))
            return r, g, b, a
        end)

        local lock = paint('lock', 48, 48, function(x, y)
            local r, g, b, a = 0.0, 0.0, 0.0, 0.0
            local shell = roundRect(x, y, 24.0, 24.0, 23.0, 23.0, 8.0)
                - roundRect(x, y, 24.0, 24.0, 21.0, 21.0, 7.0)
            r, g, b, a = over(r, g, b, a, 235.0, 236.0, 240.0, 0.85, shell)
            local shackle = (y <= 24.0)
                and (disc(x, y, 24.0, 24.0, 7.0) - disc(x, y, 24.0, 24.0, 4.8)) or 0.0
            r, g, b, a = over(r, g, b, a, WP_INK[1], WP_INK[2], WP_INK[3], 0.9, shackle)
            r, g, b, a = over(r, g, b, a, WP_INK[1], WP_INK[2], WP_INK[3], 0.9,
                roundRect(x, y, 24.0, 28.0, 8.0, 6.0, 2.0))
            return r, g, b, a
        end)

        if not (ring and idle and cap and lock) then
            error('runtime texture creation failed')
        end
        wpTex = { ring = ring, idle = idle, cap = cap, lock = lock }
    end)
    if not ok then
        wpTexFailed = true
        Core.Log.error('world prompt sprites failed, prompt dots are not drawn: %s', tostring(err))
        return false
    end
    return true
end

-- The band is ONE sprite per width: a horizontally painted --color-hud bar whose last `tail`
-- columns ramp to zero. Two abutting sprites (body + fade) always show a 1-2 px filtering seam
-- where their feathered edges meet; one texture has no seam at all. Widths are quantized to 4 px
-- and cached, and the texture is only painted when that width is first seen (never per frame).
local bandTexCache = {}
local bandTexCount = 0
local WP_BAND_TEX_MAX <const> = 40

--- @return string|nil name, integer widthPx
local function bandTexture(widthPx, tailPx)
    widthPx = math.floor(math.max(16, math.min(1024, widthPx)) / 4 + 0.5) * 4
    tailPx = math.floor(math.max(4, math.min(tailPx, widthPx - 8)) + 0.5)
    local key = widthPx .. ':' .. tailPx
    local cached = bandTexCache[key]
    if cached then return cached, widthPx end
    if bandTexCount >= WP_BAND_TEX_MAX then return nil end
    bandTexCount = bandTexCount + 1
    local name = 'band' .. bandTexCount
    local tex = CreateRuntimeTexture(wpTxd, name, widthPx, 4)
    if not tex or tex == 0 then return nil end
    local solidEnd = widthPx - tailPx
    for x = 0, widthPx - 1 do
        local a = (x < solidEnd) and 1.0 or (1.0 - (x - solidEnd + 0.5) / tailPx)
        local ai = math.floor(clamp01(a) * WP_HUD[4] + 0.5)
        for y = 0, 3 do
            SetRuntimeTexturePixel(tex, x, y, WP_HUD[1], WP_HUD[2], WP_HUD[3], ai)
        end
    end
    CommitRuntimeTexture(tex)
    bandTexCache[key] = name
    return name, widthPx
end

local wpTextScale = WP_TEXT_SCALE     -- calibrated so the label is exactly WP_LABEL_PX tall
local wpKeyScale = WP_TEXT_SCALE
local focusSince, focusId = 0, nil    -- the cap scale-in, kit-like
local screenAspect = 16 / 9           -- refreshed with the resolution, not per frame
-- The looked-at hint's layout cache (§6.7): everything derived from (entry.label, text scale,
-- resolution). `measuredSource` is the RAW entry.label the cache was built from, so an unchanged
-- frame costs two comparisons: no string.upper, no width measurement, no band lookup.
local measuredSource, measuredScale = nil, nil
local measuredLabel = nil                          -- the uppercased text that is drawn
local measuredBand, measuredBandNorm = nil, 0.0    -- band sprite (nil = none), its normalized width

--- The text scale that renders a `WP_LABEL_PX` line at this resolution, measured through the
--- game's own font metrics so the band matches the kit's 15 px label 1:1. A font that has not
--- streamed in yet can answer with a bogus metric, so anything far from the 1080p reference is
--- ignored instead of inflating the label.
local function calibrate(font, resY)
    local base = WP_TEXT_SCALE * (resY / 1080.0)
    local h = GetRenderedCharacterHeight(base, font)
    if h and h > 0 then
        local want = (WP_LABEL_PX * (resY / 1080.0)) / resY
        local scaled = base * (want / h)
        if scaled > base * 0.4 and scaled < base * 2.5 then return scaled end
    end
    return base
end

--- Screen resolution, refreshed every 5 s (it changes only when the player does).
local function screenSize(now)
    if screenW == 0 or now - screenAt > 5000 then
        local w, h = GetActualScreenResolution()
        if w and h and w > 0 and h > 0 then
            screenW, screenH, screenAt = w, h, now
            local a = GetAspectRatio(false)
            screenAspect = (a and a > 0) and a or (w / h)
            wpTextScale = calibrate(wpFontDisplay or 4, h)
            wpKeyScale = calibrate(wpFontKey or 4, h)
            measuredSource = nil      -- the text metrics changed with the resolution
        elseif screenW == 0 then
            screenW, screenH = 1920, 1080
        end
        -- the hint movie is drawn as its whole stage, 1 stage px = resY / 1080 screen px
        local s = screenH / 1080.0
        hintW, hintH = WP_HINT_STAGE_W * s / screenW, WP_HINT_STAGE_H * s / screenH
    end
    return screenW, screenH
end

--- Rebuilds the looked-at hint's layout cache (§6.7): the uppercased text, its measured width and
--- the band sprite that fits it. Runs when the focused label, the text scale or the resolution
--- changed, never per frame: it is a text-layout call, a string build and a texture lookup.
local function measureHint(rawLabel, resX, resY, s)
    -- Barlow Condensed runs uppercase in the kit (CSS text-transform); string.upper is byte-wise,
    -- so non-ASCII stays untouched instead of mangling.
    local label = string.upper(rawLabel)
    SetTextFont(wpFontDisplay or 4)
    SetTextScale(0.0, wpTextScale)
    BeginTextCommandGetWidth('STRING')
    AddTextComponentSubstringPlayerName(label)
    local labelW = EndTextCommandGetWidth(true)        -- fraction of screen width
    if not labelW or labelW <= 0.001 or labelW > 0.6 then
        -- a bogus metric (font not streamed yet) must not stretch the band across the screen
        labelW = math.min(0.6, #label * 0.004) * (resY / 1080.0)
    end
    local pad = WP_BAND_PAD_PX * s / resX
    local tail = WP_BAND_TAIL_PX * s / resX
    local bandName, bandW = bandTexture(
        math.floor((pad + labelW + tail) * resX + 0.5),
        math.floor(tail * resX + 0.5))
    measuredSource, measuredScale, measuredLabel = rawLabel, wpTextScale, label
    measuredBand, measuredBandNorm = bandName, bandName and (bandW / resX) or 0.0
end

--- Gives the one pool slot back. Safe to call with no handle.
local function releaseHint()
    if hintMovie ~= 0 then
        SetScaleformMovieAsNoLongerNeeded(hintMovie)
        hintMovie = 0
    end
end

--- Blanks the movie ONCE when focus is lost, so a late-applied SET_HINT can never flash the
--- previous hint's content. Costs one boolean read on every other frame.
local function hideHint()
    if not hintShown then return end
    hintShown, hintEntryId = false, nil
    if hintState == 2 and BeginScaleformMovieMethod(hintMovie, 'HIDE') then
        EndScaleformMovieMethod()
    end
end

--- The hint movie's lifecycle, driven by the SCAN cadence — never by the per-frame path (§6.7):
--- request it when the first world prompt shows up, notice the same pass when it is already loaded,
--- give up after WP_HINT_LOAD_MS with one warning (the sprite hint stays the fallback), and forget a
--- handle the game dropped so the next pass requests it again. `pCount` is this pass's prompt count.
local function hintTick(now, pCount)
    if hintState == 0 then
        if pCount <= 0 then return end
        hintMovie, hintState, hintLoadAt = RequestScaleformMovie(WP_HINT_MOVIE), 1, now
        hintShown, hintEntryId = false, nil
    end
    if hintState == 1 then
        if HasScaleformMovieLoaded(hintMovie) then
            hintState = 2
        elseif now - hintLoadAt > WP_HINT_LOAD_MS then
            releaseHint()
            hintState = 3
            Core.Log.warn('world prompt hint movie %s did not load, drawing the sprite hint instead',
                WP_HINT_MOVIE)
        end
    elseif hintState == 2 and not HasScaleformMovieLoaded(hintMovie) then
        -- the game dropped the movie (pool pressure): forget everything we told it
        hintMovie, hintState, hintShown, hintEntryId = 0, 0, false, nil
        hintKey, hintLabel, hintDisabled, hintLeft = nil, nil, nil, false
    end
end

--- The native dot layer for one frame (DESIGN §6.7): idle dots first, then the looked-at
--- cap + key + band on top, 1:1 with the kit's CoreInteractionDot focused state. Everything is
--- anchored with `SetDrawOrigin` at the world point, so the render thread projects it — the
--- prompt stays glued to the position when the camera moves (a script-side projection always
--- trails the final render camera by a frame, which is the slide).
--- The looked-at hint is ONE Scaleform movie once `core_hint` is ready (`Hint = 'scaleform'`), and
--- the sprite hint below whenever it is not — which is also all `Hint = 'sprites'` ever runs.
--- Per-frame budget: ONE script-gfx-align bracket around the SPRITES (opened lazily, so a lone
--- Scaleform hint draws without one), ONE draw-origin group per visible dot (the looked-at dot
--- opens only its own), no string work. `now` is the projection frame's timestamp.
local function drawNative(visible, bestSlot, now)
    if not ensureTextures() then return end
    local resX, resY = screenSize(now)
    local s = resY / 1080.0

    -- the hint's layout comes from the cache; a rebuild (label, scale or resolution changed)
    -- happens BEFORE the draw bracket opens, so no text-layout call ever sits inside it
    local entry
    if bestSlot then
        entry = bestSlot.entry
        -- the kit scales the cap in when a dot gains focus (0.18 s there, 130 ms here)
        if entry.id ~= focusId then
            focusId, focusSince = entry.id, now
        end
        -- the movie lays its own text out: no measurement, no band texture in Scaleform mode
        if hintState ~= 2 and (measuredSource ~= entry.label or measuredScale ~= wpTextScale) then
            measureHint(entry.label, resX, resY, s)
        end
    else
        focusId = nil
        hideHint()
    end

    local pulse = (now % WP_PULSE_MS) / WP_PULSE_MS
    local ringW, ringH = WP_RING_PX * s / resX, WP_RING_PX * s / resY

    -- script gfx aligns to the full screen (not the safe zone), matching the projection the focus
    -- test uses; every dot is one draw-origin group (the engine limit is 32 per frame). The bracket
    -- belongs to the sprites: it opens before the first one and only then.
    local aligned = false
    for i = 1, visible do
        local slot = frame[i]
        if slot ~= bestSlot then
            if not aligned then
                aligned = true
                SetScriptGfxAlignParams(0.0, 0.0, 0.0, 0.0)
            end
            SetDrawOrigin(slot.drawX, slot.drawY, slot.drawZ, 0)
            local dim = slot.disabled and 150 or 255
            if not slot.disabled then
                local k = 1.0 + 1.6 * pulse
                DrawSprite(WP_TXD, 'ring', 0.0, 0.0, ringW * k, ringH * k, 0.0,
                    WP_TONE[1], WP_TONE[2], WP_TONE[3],
                    math.floor((1.0 - pulse) * 130.0 + 0.5), false, 0)
            end
            -- ring + core are ONE composited sprite: a disabled dot is a single draw (§6.7)
            DrawSprite(WP_TXD, 'idle', 0.0, 0.0, ringW, ringH, 0.0, 255, 255, 255, dim, false, 0)
            ClearDrawOrigin()
        end
    end

    if bestSlot and hintState == 2 then
        -- ONE movie for the whole hint: a method call only when something CHANGED, then the stage
        -- drawn centred on the world point under its own draw origin (§6.7).
        local disabled = bestSlot.disabled
        local left = hintLeft
        if bestSlot.x > 0.62 then left = true elseif bestSlot.x < 0.58 then left = false end
        local restart = entry.id ~= hintEntryId or not hintShown
        if restart or entry.key ~= hintKey or entry.label ~= hintLabel
            or disabled ~= hintDisabled or left ~= hintLeft then
            if BeginScaleformMovieMethod(hintMovie, 'SET_HINT') then
                ScaleformMovieMethodAddParamPlayerNameString(entry.key)
                ScaleformMovieMethodAddParamPlayerNameString(entry.label)   -- RAW: the movie uppercases
                ScaleformMovieMethodAddParamBool(disabled)
                ScaleformMovieMethodAddParamBool(left)
                ScaleformMovieMethodAddParamBool(restart)
                EndScaleformMovieMethod()
                -- the cache mirrors ONLY what the movie was really told: a refused Begin leaves it
                -- alone, so the next frame retries instead of assuming a call that never happened
                hintEntryId, hintKey, hintLabel, hintDisabled, hintLeft, hintShown =
                    entry.id, entry.key, entry.label, disabled, left, true
            end
        end

        -- A new focus is ANNOUNCED one frame before it is drawn: focus can jump straight from dot A
        -- to dot B with no unfocused frame in between, so no HIDE ran, and a method call the engine
        -- applies after this frame's render would show A's content at B's position. The focus-in
        -- animation starts at alpha 0, so the one skipped frame is invisible.
        if not restart then
            SetDrawOrigin(bestSlot.drawX, bestSlot.drawY, bestSlot.drawZ, 0)
            DrawScaleformMovie(hintMovie, 0.0, 0.0, hintW, hintH, 255, 255, 255, 255, 0)
            ClearDrawOrigin()
        end
    elseif bestSlot then
        if not aligned then
            aligned = true
            SetScriptGfxAlignParams(0.0, 0.0, 0.0, 0.0)
        end
        local disabled = bestSlot.disabled
        local focusT = clamp01((now - focusSince) / 130.0)
        local capScale = 0.7 + 0.3 * focusT
        local capW = WP_CAP_PX * s * capScale / resX
        local capH = WP_CAP_PX * s * capScale / resY

        local ty = -WP_TEXT_Y * s
        local edge = (WP_CAP_PX * 0.5 + WP_BAND_GAP_PX) * s / resX
        local pad = WP_BAND_PAD_PX * s / resX
        local left = bestSlot.x > 0.6

        SetDrawOrigin(bestSlot.drawX, bestSlot.drawY, bestSlot.drawZ, 0)

        if measuredBand then
            local bandNorm = measuredBandNorm
            local center = left and -(edge + bandNorm * 0.5) or (edge + bandNorm * 0.5)
            DrawSprite(WP_TXD, measuredBand, center, 0.0, left and -bandNorm or bandNorm,
                WP_BAND_H_PX * s / resY, 0.0, 255, 255, 255, 255, false, 0)
        end

        DrawSprite(WP_TXD, disabled and 'lock' or 'cap', 0.0, 0.0, capW, capH, 0.0,
            255, 255, 255, 255, false, 0)

        if not disabled then
            SetTextFont(wpFontKey or 4)
            SetTextScale(0.0, wpKeyScale)
            SetTextColour(WP_KEY_FG[1], WP_KEY_FG[2], WP_KEY_FG[3], 255)
            SetTextCentre(true)
            BeginTextCommandDisplayText('STRING')
            AddTextComponentSubstringPlayerName(entry.key)
            EndTextCommandDisplayText(0.0, ty)
        end

        SetTextFont(wpFontDisplay or 4)
        SetTextScale(0.0, wpTextScale)
        SetTextColour(WP_FG[1], WP_FG[2], WP_FG[3], disabled and 165 or 255)
        SetTextCentre(false)
        SetTextDropshadow(0, 0, 0, 0, 255)
        SetTextEdge(2, 0, 0, 0, 150)
        local labelX
        if left then
            labelX = -(edge + pad)
            SetTextRightJustify(true)
            SetTextWrap(-1.0, labelX)
        else
            labelX = edge + pad
            SetTextRightJustify(false)
            SetTextWrap(labelX, 1.0)
        end
        BeginTextCommandDisplayText('STRING')
        AddTextComponentSubstringPlayerName(measuredLabel)
        EndTextCommandDisplayText(labelX, ty)

        ClearDrawOrigin()
    end
    if aligned then ResetScriptGfxAlign() end
end


--- Re-reads ONE entity slot's world point, but only as often as the entity actually moves (§6.7):
--- `sameReads` counts consecutive reads that returned exactly the previous x, y, z — 8 of them park
--- the slot on WP_REST_MS, any difference puts it back on every frame. Three scalar comparisons, no
--- allocation, no key string. Sets the draw anchor; returns false when the entity is gone.
local function readEntity(slot, now)
    if now < slot.nextReadAt then return true end
    local entity = slot.entry.entity
    if not DoesEntityExist(entity) then return false end
    local coords = GetEntityCoords(entity, false)
    local x, y, z = coords.x, coords.y, coords.z
    if x == slot.readX and y == slot.readY and z == slot.readZ then
        slot.sameReads = slot.sameReads + 1
    else
        slot.sameReads, slot.readX, slot.readY, slot.readZ = 0, x, y, z
    end
    slot.nextReadAt = (slot.sameReads >= WP_REST_READS) and (now + WP_REST_MS) or now
    slot.drawX, slot.drawY, slot.drawZ = x, y, z + (slot.entry.promptOffsetZ or 0.0)
    return true
end

--- One frame of the world prompts (DESIGN §6.7). Entity slots are re-read every frame (as often as
--- they move); only a PROJECTION frame (`pass`) re-projects the world points, rebuilds the visible
--- set `frame[1..frameCount]` and picks `frameBest`/`focusedId` — every other frame redraws that same
--- answer, which is why nothing here depends on the projection being fresh. Then it draws natively
--- (`Renderer = 'native'`) or sends the changed whole set to the shell (`Renderer = 'nui'`, which
--- passes every frame because it needs x/y). `now` is the frame's `GetGameTimer()`, handed down.
local function project(now, pass)
    if promptCount <= 0 then
        frameCount, frameBest, focusedId = 0, nil, nil
        if WP_NATIVE then
            hideHint()            -- the last prompt went away: blank the movie once
            return                -- nothing to draw and no set to clear in native mode
        end
    elseif pass then
        local aspect = screenAspect
        local visible = 0
        local bestSlot, bestD, bestDisabled
        for i = 1, promptCount do
            local slot = prompts[i]
            slot.focused = false
            -- entity targets move between scans; point/models targets keep the scan coords. The draw
            -- anchor is the world point: the render thread projects it (SetDrawOrigin), so the prompt
            -- does not slide when the camera moves the way a per-frame projection does.
            if slot.entry.entity == nil or readEntity(slot, now) then
                local ok, sx, sy = GetScreenCoordFromWorldCoord(slot.drawX, slot.drawY, slot.drawZ)
                if ok then
                    -- 4 decimals: the comparison epsilon is coarser than the rounding
                    slot.x = math.floor(sx * 10000 + 0.5) / 10000
                    slot.y = math.floor(sy * 10000 + 0.5) / 10000
                    visible = visible + 1
                    frame[visible] = slot
                end
            end
        end

        -- focus: inside FocusRadius (normalized, aspect-scaled reticle distance), an
        -- in-reach dot beats an out-of-reach one, then the smaller distance wins
        for i = 1, visible do
            local slot = frame[i]
            local disabled = slot.dist > slot.entry.radius
            slot.disabled = disabled
            local dx = (slot.x - 0.5) * aspect
            local dy = slot.y - 0.5
            local d = dx * dx + dy * dy
            if d <= WP_FOCUS_RADIUS_SQ then
                local better = not bestSlot
                    or (bestDisabled and not disabled)
                    or (disabled == bestDisabled and d < bestD)
                if better then bestSlot, bestD, bestDisabled = slot, d, disabled end
            end
        end
        frameCount, frameBest = visible, bestSlot
        focusedId = bestSlot and bestSlot.entry.id or nil
    else
        -- a drawing frame: only entity slots move, and one whose entity vanished leaves the cached
        -- set at once (the dirty flag re-projects the rest on the next frame)
        local kept = 0
        for i = 1, frameCount do
            local slot = frame[i]
            if slot.entry.entity == nil or readEntity(slot, now) then
                kept = kept + 1
                frame[kept] = slot
            else
                focusDirty = true
                if slot == frameBest then frameBest, focusedId = nil, nil end
            end
        end
        frameCount = kept
    end

    if WP_NATIVE then
        drawNative(frameCount, frameBest, now)
        return
    end

    -- ---------------------------------------------------------- NUI transport
    local visible, bestSlot = frameCount, frameBest
    local structural = promptDirty or forceSend   -- set/count/focus/label changes are never throttled
    local changed = structural
    for i = 1, visible do
        local slot = frame[i]
        slot.focused = slot == bestSlot
        local prev = i <= sentCount and WP_SENT.items[i] or nil
        if not prev
            or prev.id ~= slot.entry.id
            or prev.focused ~= slot.focused
            or prev.disabled ~= slot.disabled
            or prev.label ~= slot.entry.label then
            structural, changed = true, true
        elseif math.abs((prev.x or 0) - slot.x) > WP_EPSILON
            or math.abs((prev.y or 0) - slot.y) > WP_EPSILON then
            changed = true
        end
    end

    -- a dot that left the screen (or the whole set) leaves the message right away
    if visible ~= sentCount then structural, changed = true, true end

    if not changed then return end
    -- positions only: ~30 Hz is plenty, the shell glides between two sends (a moving dot at
    -- 60 messages/s is what makes the CEF jank; focus/enter/leave bypass this throttle)
    if not structural and now - lastSendAt < WP_SEND_MS then return end

    local items = WP_SENT.items
    for i = #items, visible + 1, -1 do items[i] = nil end
    for i = 1, visible do
        local slot = frame[i]
        local item = items[i]
        if not item then
            item = {}
            items[i] = item
        end
        item.id = slot.entry.id
        item.x = slot.x
        item.y = slot.y
        item.focused = slot.focused
        item.disabled = slot.disabled
        item.keys = slot.entry.key
        item.label = slot.entry.label
        item.icon = slot.entry.promptIcon
        item.description = slot.entry.promptDesc
    end
    sentCount = visible
    promptDirty = false
    forceSend = false
    if Core.UIInternal.worldPromptBatch(WP_SENT) then
        retryAt = 0
        lastSendAt = now
        return
    end
    promptDirty = true           -- shell not ready: retry on an idle tick, not every frame
    retryAt = now + WP_RETRY_MS
end

-- The only per-frame loop: Wait(0) while dots are on screen, 250 ms otherwise. Every frame DRAWS,
-- but with the native renderer only every WP_FOCUS_MS-th one projects and asks `IsNuiFocused` —
-- between them the last visible set, the last focused slot and the last focus answer stand, and the
-- dirty flag pulls a projection forward (DESIGN §6.7). The 'nui' renderer needs x/y per frame, so it
-- passes every frame. A page or modal holding NUI focus freezes the whole thread on the idle cadence
-- — nothing is drawn while it is open (the wake-up always projects, 250 ms > WP_FOCUS_MS) — and a
-- failed send is retried on WP_RETRY_MS, never per frame.
CreateThread(function()
    while not stopping do
        local now = GetGameTimer()
        local pass = focusDirty or not WP_NATIVE or now - lastFocusAt >= WP_FOCUS_MS
        if pass then
            lastFocusAt, focusDirty = now, false
            wpFocused = IsNuiFocused()
        end
        if wpFocused then
            Wait(WP_IDLE_MS)
        else
            if retryAt == 0 or now >= retryAt then project(now, pass) end
            Wait((promptCount > 0 and retryAt == 0) and 0 or WP_IDLE_MS)
        end
    end
end)

Core.on('uiReady', function()
    forceSend = true               -- a (reloaded) shell forgot every set we sent
end)

-- Resolves an entry's current world target. Returns coords, entity (0 for points) or nil when the
-- target does not exist right now. `now` is GetGameTimer() of the current pass.
local function resolveTarget(entry, pedCoords, now)
    if entry.coords and not entry.models then
        return entry.coords, 0
    end

    if entry.entity then
        if DoesEntityExist(entry.entity) then
            return GetEntityCoords(entry.entity, false), entry.entity
        end
        return nil
    end

    if entry.netId then
        if NetworkDoesEntityExistWithNetworkId(entry.netId) then
            local ent = NetworkGetEntityFromNetworkId(entry.netId)
            if ent ~= 0 and DoesEntityExist(ent) then
                return GetEntityCoords(ent, false), ent
            end
        end
        return nil
    end

    if entry.models then
        -- A models entry with coords is gated on that distance first (cheap). Without coords the pool
        -- search costs one GetClosestObjectOfType per model (≤ Config.Interactions.MaxModels), so once
        -- a pass finds nothing the next search is held off until the far cadence has elapsed.
        if entry.coords and #(pedCoords - entry.coords) > NEAR_RANGE then return nil end
        if entry.nextModelScanAt and now < entry.nextModelScanAt then return nil end
        local bestCoords, bestEnt, bestDist
        for i = 1, #entry.models do
            local obj = GetClosestObjectOfType(pedCoords.x, pedCoords.y, pedCoords.z, entry.radius,
                entry.models[i], false, false, false)
            if obj ~= 0 and DoesEntityExist(obj) then
                local coords = GetEntityCoords(obj, false)
                local dist = #(pedCoords - coords)
                if not bestDist or dist < bestDist then
                    bestDist, bestCoords, bestEnt = dist, coords, obj
                end
            end
        end
        if bestCoords then
            entry.nextModelScanAt = nil
            entry.lastSeen, entry.lastSeenAt = bestCoords, now
            return bestCoords, bestEnt
        end

        entry.nextModelScanAt = now + SCAN_FAR
        if entry.lastSeenAt and now - entry.lastSeenAt > LAST_SEEN_TTL_MS then
            entry.lastSeen, entry.lastSeenAt = nil, nil
        end
    end

    return nil
end

local function makeCtx(entry, coords, entity, distance)
    return { id = entry.id, coords = coords, entity = entity, distance = distance, data = entry.data }
end

local function deactivate()
    local ctx = active
    active, activeLabel = nil, nil
    if not ctx then return end
    textUI('hide', TEXTUI_OWNER)
    local entry = entries[ctx.id]
    if entry then safeCall(entry.onExit, ctx) end
end

local function activate(entry, ctx)
    active = ctx
    activeLabel = entry.label
    safeCall(entry.onEnter, ctx)
    -- a worldPrompt entry draws the dot instead of the bottom pill (DESIGN §6.7)
    if not entry.worldPrompt then
        textUI('show', entry.key, entry.label, TEXTUI_OPTS)
    end
end

-- One scan pass. Returns the sleep for the next pass.
local function scan()
    local ped = PlayerPedId()
    local pedCoords = GetEntityCoords(ped, false)
    local now = GetGameTimer()
    local near = false
    local count = 0
    local pCount = 0

    for _, entry in pairs(entries) do
        if entry.enabled then
            local coords, entity = resolveTarget(entry, pedCoords, now)
            if coords then
                local dist = #(pedCoords - coords)
                if dist <= NEAR_RANGE then near = true end
                if dist <= entry.radius then
                    count = count + 1
                    local slot = candidates[count]
                    if not slot then
                        slot = {}
                        candidates[count] = slot
                    end
                    slot.entry, slot.coords, slot.entity, slot.dist, slot.skip = entry, coords, entity, dist, false
                end
                -- world prompt dots: within range, nearest MaxVisible, and not denied by
                -- canInteract while inside the activation radius (evaluated once below)
                if entry.worldPrompt and dist <= entry.promptRange then
                    local slot
                    if pCount < WP_MAX_VISIBLE then
                        pCount = pCount + 1
                        slot = prompts[pCount]
                        if not slot then
                            slot = {}
                            prompts[pCount] = slot
                        end
                    else
                        -- full: keep only the nearest MaxVisible, so the set never depends on
                        -- the pairs(entries) order of this pass
                        local farIndex, farDist = 1, prompts[1].dist
                        for j = 2, pCount do
                            local d = prompts[j].dist
                            if d > farDist then farIndex, farDist = j, d end
                        end
                        if dist < farDist then slot = prompts[farIndex] end
                    end
                    if slot then
                        -- the slot tables are reused, so a slot that gets a DIFFERENT entry starts
                        -- the entity read rule over (§6.7); the scan sets the draw anchor itself,
                        -- the projection never does
                        if slot.entry ~= entry then
                            slot.sameReads, slot.nextReadAt = 0, 0
                            slot.readX, slot.readY, slot.readZ = coords.x, coords.y, coords.z
                        end
                        slot.entry, slot.coords, slot.entity, slot.dist = entry, coords, entity, dist
                        slot.drawX, slot.drawY = coords.x, coords.y
                        slot.drawZ = coords.z + (entry.promptOffsetZ or 0.0)
                    end
                end
            elseif entry.models and not entry.coords and entry.lastSeen then
                -- an ungated models entry keeps the near cadence only while the player is still around
                -- the last place one of its props actually was; otherwise it falls back to far
                if #(pedCoords - entry.lastSeen) <= NEAR_RANGE then near = true end
            end
        end
    end

    -- canInteract once per within-radius entry per pass: the verdict picks `active`
    -- AND excludes denied entries from the prompt list (DESIGN §6.7)
    local chosenEntry, chosenCtx, chosenDist
    for i = 1, count do
        local slot = candidates[i]
        local entry = slot.entry
        local ctx = makeCtx(entry, slot.coords, slot.entity, slot.dist)
        local denied = entry.canInteract ~= nil and safeCall(entry.canInteract, ctx) == false
        entry._wpDenied = denied
        if not denied and (not chosenEntry or slot.dist < chosenDist) then
            chosenEntry, chosenCtx, chosenDist = entry, ctx, slot.dist
        end
    end

    for i = 1, count do
        local slot = candidates[i]
        slot.entry, slot.coords = nil, nil
    end

    -- prompt slots a canInteract denial removed while inside the activation radius
    for i = pCount, 1, -1 do
        local slot = prompts[i]
        if slot.dist <= slot.entry.radius and slot.entry._wpDenied then
            prompts[i] = prompts[pCount]
            prompts[pCount] = nil
            pCount = pCount - 1
        end
    end

    -- the shell draws the set in list order, so keep it nearest-first
    for i = 2, pCount do
        local slot = prompts[i]
        local j = i
        while j > 1 and prompts[j - 1].dist > slot.dist do
            prompts[j] = prompts[j - 1]
            j = j - 1
        end
        prompts[j] = slot
    end
    promptCount = pCount
    -- every slot table may hold a different entry now: the next frame must project (§6.7)
    focusDirty = true

    -- the hint movie is requested, watched and given up on here, on the scan cadence (§6.7)
    if WP_HINT_SF then hintTick(now, pCount) end

    if not chosenEntry then
        deactivate()
    elseif not active or active.id ~= chosenCtx.id then
        deactivate()
        activate(chosenEntry, chosenCtx)
    else
        active.coords, active.entity, active.distance = chosenCtx.coords, chosenCtx.entity, chosenCtx.distance
        if activeLabel ~= chosenEntry.label then
            activeLabel = chosenEntry.label
            if not chosenEntry.worldPrompt then
                textUI('show', chosenEntry.key, chosenEntry.label, TEXTUI_OPTS)
            end
        end
    end

    return near and SCAN_NEAR or SCAN_FAR
end

CreateThread(function()
    while not stopping do
        local sleep = SCAN_FAR
        if next(entries) then
            sleep = scan()
        elseif active then
            deactivate()
        end
        Wait(sleep)
    end
end)

local function addMarker(entry, opts)
    local coords = opts.coords or entry.coords
    if not coords then
        Core.Log.warn('interaction %s: marker ignored, no coords on the interaction', entry.id)
        return nil
    end
    local mopts = {}
    for k, v in pairs(opts) do mopts[k] = v end
    mopts.coords = coords
    return Core.Markers.add(mopts)
end

--- Register an interaction. opts: coords|entity|netId|models, radius, label, key, marker, data,
--- onInteract/onEnter/onExit/canInteract, enabled, cooldown, worldPrompt (DESIGN §6.7).
---@param opts table
---@return string|nil id
function Interactions.add(opts)
    if type(opts) ~= 'table' then return nil end

    local models
    if type(opts.models) == 'table' then
        models = {}
        for i = 1, #opts.models do
            if i > MAX_MODELS then break end
            models[i] = Core.Utils.hash(opts.models[i])
        end
        if #models == 0 then models = nil end
    end

    local coords = Core.Utils.isVector3(opts.coords) and opts.coords or nil
    local entity = type(opts.entity) == 'number' and opts.entity or nil
    local netId = type(opts.netId) == 'number' and opts.netId or nil
    if not coords and not entity and not netId and not models then
        Core.Log.error('Interactions.add: needs one of coords, entity, netId or models')
        return nil
    end

    local owner = Core.Registry.getCaller()
    counter = counter + 1
    local id = ('%s:i%d'):format(owner, counter)

    local entry = {
        id = id,
        owner = owner,
        coords = coords,
        entity = entity,
        netId = netId,
        models = models,
        radius = tonumber(opts.radius) or 2.0,
        label = Core.Utils.sanitize(opts.label or 'Interact', 64),
        key = Core.Utils.sanitize(opts.key or Config.Interactions.Key, 16),
        onInteract = opts.onInteract,
        onEnter = opts.onEnter,
        onExit = opts.onExit,
        canInteract = opts.canInteract,
        enabled = opts.enabled ~= false,
        cooldown = tonumber(opts.cooldown) or 500,
        data = opts.data,
        lastUse = nil,      -- nil = never used; set to GetGameTimer() on each accepted press
    }
    applyWorldPrompt(entry, opts)

    if type(opts.marker) == 'table' then
        entry.markerId = addMarker(entry, opts.marker)
    end

    entries[id] = entry
    Core.Registry.track('interaction', id, owner)
    return id
end

--- Remove one interaction (and the marker it created).
---@param id string
---@return boolean removed
function Interactions.remove(id)
    local entry = entries[id]
    if not entry then return false end
    entries[id] = nil
    if active and active.id == id then
        active, activeLabel = nil, nil
        textUI('hide', TEXTUI_OWNER)
        safeCall(entry.onExit, makeCtx(entry, entry.coords, 0, 0.0))
    end
    for i = 1, promptCount do
        if prompts[i].entry == entry then
            prompts[i] = prompts[promptCount]
            prompts[promptCount] = nil
            promptCount = promptCount - 1
            focusDirty = true      -- the cached visible set may hold this slot: re-project (§6.7)
            break
        end
    end
    if focusedId == id then focusedId = nil end
    if entry.markerId then Core.Markers.remove(entry.markerId) end
    Core.Registry.untrack('interaction', id)
    return true
end

--- Remove every interaction of the calling resource.
function Interactions.removeAll()
    local owner = Core.Registry.getCaller()
    for id, entry in pairs(entries) do
        if entry.owner == owner then Interactions.remove(id) end
    end
end

--- Enable/disable an interaction without removing it; disabling clears it if it is active.
---@param id string
---@param enabled boolean
---@return boolean ok
function Interactions.setEnabled(id, enabled)
    local entry = entries[id]
    if not entry then return false end
    entry.enabled = enabled ~= false
    if not entry.enabled and active and active.id == id then deactivate() end
    return true
end

--- Change the prompt label (applied on the next scan while active).
---@param id string
---@param text string
---@return boolean ok
function Interactions.setLabel(id, text)
    local entry = entries[id]
    if not entry then return false end
    entry.label = Core.Utils.sanitize(text, 64)
    return true
end

--- The id of the active interaction, or nil. Allocation-free, unlike getActive.
---@return string|nil id
function Interactions.getActiveId()
    return active and active.id or nil
end

--- The active interaction context, or nil.
---@return table|nil ctx { id, coords, entity, distance, data }
function Interactions.getActive()
    local ctx = active
    if not ctx then return nil end
    return { id = ctx.id, coords = ctx.coords, entity = ctx.entity, distance = ctx.distance, data = ctx.data }
end

-- The interact key: one command + one mapping, no polling. Rebindable in the pause menu.
-- A worldPrompt entry only fires while its dot is looked at (DESIGN §6.7) — proximity alone is
-- not enough; without a focused dot the scan's active entry fires, but only for entries that do
-- not use the world prompt. Both paths run the same checks.
RegisterCommand(INTERACT_CMD, function()
    if IsNuiFocused() then return end
    local entry = focusedId and entries[focusedId] or nil
    if not entry and active then
        local activeEntry = entries[active.id]
        if activeEntry and not activeEntry.worldPrompt then entry = activeEntry end
    end
    if not entry or not entry.enabled or not entry.onInteract then return end

    local now = GetGameTimer()
    if entry.lastUse and now - entry.lastUse < entry.cooldown then return end

    -- the target is up to ScanIntervalMs old: re-resolve it and refuse if the player walked
    -- out of range in the meantime, so the callback always gets a fresh ctx.
    local pedCoords = GetEntityCoords(PlayerPedId(), false)
    local coords, entity = resolveTarget(entry, pedCoords, now)
    if not coords then return end
    local distance = #(pedCoords - coords)
    if distance > entry.radius then return end

    entry.lastUse = now
    if active and active.id == entry.id then
        active.coords, active.entity, active.distance = coords, entity, distance
    end
    safeCall(entry.onInteract, makeCtx(entry, coords, entity, distance))
end, false)

RegisterKeyMapping(INTERACT_CMD, 'Interact', 'keyboard', Config.Interactions.Key)

-- Owner cleanup: every interaction a plugin registered dies with that plugin (DESIGN §2.3).
Core.Registry.onOwnerStop('interaction', function(id)
    Interactions.remove(id)
end)

AddEventHandler('onClientResourceStop', function(resource)
    if resource ~= Core.name then return end
    stopping = true
    active, activeLabel = nil, nil
    for id in pairs(entries) do entries[id] = nil end
    for i = 1, promptCount do prompts[i] = nil end
    for i = 1, frameCount do frame[i] = nil end
    promptCount, focusedId, forceSend, promptDirty = 0, nil, false, false
    frameCount, frameBest, focusDirty, wpFocused = 0, nil, true, false
    sentCount = 0
    for i in pairs(WP_SENT.items) do WP_SENT.items[i] = nil end
    releaseHint()                 -- the one Scaleform pool slot goes back, synchronously
    hintState, hintShown, hintEntryId = 0, false, nil
end)

-- Warm the runtime sprites off the first-dot path (~7k one-off native calls, nothing per frame).
if WP_NATIVE then
    CreateThread(function()
        Wait(2000)
        ensureTextures()
    end)
end

Core.Interactions = Interactions

-- end of file
