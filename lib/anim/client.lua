--[[
    core lib: Core.Anim (DESIGN §3.10) — play/stop/query scripted animations.

    Loaded into the CALLER's VM by import.lua (`local ns = ...`), client side only.

        Core.Anim.play(ped, dict, clip, { flags = 1, duration = -1, blendIn = 8.0, blendOut = -8.0,
                                          playbackRate = 0.0, lockX = false, lockY = false,
                                          lockZ = false }) -> bool
        Core.Anim.stop(ped, dict?, clip?)        -- StopAnimTask with dict+clip, else ClearPedTasks
        Core.Anim.isPlaying(ped, dict, clip) -> bool

    The dictionary is streamed in through Core.Streaming (timeout bounded) and released again right
    after the task started — the clip keeps playing, the streamer just may evict the dict.

    Natives (verified with fxref 2026-09-12, apiset client): TaskPlayAnim, StopAnimTask,
    IsEntityPlayingAnim, ClearPedTasks.
]]

local ns = ...

local DEFAULT_BLEND_IN <const> = 8.0
local DEFAULT_BLEND_OUT <const> = -8.0
local STOP_BLEND_DELTA <const> = 1.0
local IS_PLAYING_TASK_FLAG <const> = 3   -- matches any scripted/task anim on the entity

--- Reads a number from opts, falling back to `default`.
local function numberOr(value, default)
    return type(value) == 'number' and value + 0.0 or default
end

--- Plays `clip` from `dict` on `ped`. Returns false when the dict cannot be streamed in.
function ns.play(ped, dict, clip, opts)
    if math.type(ped) ~= 'integer' or ped == 0 then return false end
    if type(dict) ~= 'string' or dict == '' or type(clip) ~= 'string' or clip == '' then return false end
    opts = type(opts) == 'table' and opts or {}

    if not Core.Streaming.requestAnimDict(dict, opts.timeout) then return false end

    local duration = math.type(opts.duration) == 'integer' and opts.duration or -1
    local flags = math.type(opts.flags) == 'integer' and opts.flags or 1
    TaskPlayAnim(ped, dict, clip,
        numberOr(opts.blendIn, DEFAULT_BLEND_IN), numberOr(opts.blendOut, DEFAULT_BLEND_OUT),
        duration, flags, numberOr(opts.playbackRate, 0.0),
        opts.lockX == true, opts.lockY == true, opts.lockZ == true)

    Core.Streaming.releaseAnimDict(dict)
    return true
end

--- Stops one clip (dict + clip given) or every scripted task on the ped.
function ns.stop(ped, dict, clip)
    if math.type(ped) ~= 'integer' or ped == 0 then return false end
    if type(dict) == 'string' and dict ~= '' and type(clip) == 'string' and clip ~= '' then
        StopAnimTask(ped, dict, clip, STOP_BLEND_DELTA)
    else
        ClearPedTasks(ped)
    end
    return true
end

--- True while `ped` is playing `clip` from `dict`.
function ns.isPlaying(ped, dict, clip)
    if math.type(ped) ~= 'integer' or ped == 0 then return false end
    if type(dict) ~= 'string' or type(clip) ~= 'string' then return false end
    return IsEntityPlayingAnim(ped, dict, clip, IS_PLAYING_TASK_FLAG)
end
