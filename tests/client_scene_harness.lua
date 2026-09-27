-- tests/client_scene_harness.lua — a stub CLIENT VM for the Core.Scene client files (DESIGN §55.10–§55.13).
-- Shared by the client scene suites; not a suite itself. Usage:
--
--   local H = dofile(here .. '/client_scene_harness.lua')
--   local h = H.new({ scene = function(Scene) … end,   -- edit Config.Scene before the files load (caps, budgets …)
--                     runtime = true,                  -- create CoreSceneRuntime with the fake cache + focus (default)
--                     motion = true })                 -- load the real shared/scene_motion.lua (default)
--   h.load('client/scene_mat_assets.lua')             -- stubs.loadFile in the VM, in the manifest order:
--   h.load('client/scene_materializer.lua')           --   scene_mat_assets (C.assets, C.fades) -> scene_materializer
--   h.load('client/scene_movers.lua')                 --   (C.mat) -> … -> scene_movers (C.movers); h.loadMat() does all three
--
-- What it gives:
--   h.env, h.stubs, h.C (= CoreSceneRuntime), h.FRAME (16 ms: Wait(0) is one frame on the virtual clock)
--   h.tick(ms), h.frames(n) -> advance the clock; h.now() -> the clock
--   h.calls[name] / h.n(name) -> calls of a stubbed native; h.warnings -> every Core.Log.warn / error line
--   h.cam(x, y, z [, pitch, yaw]) -> the rendered camera (yaw 0 looks along +y); h.set.fov, h.set.lodscale
--   h.ents[handle] = { model, x, y, z, rx, ry, rz, alpha (nil = no override), deleted, attachedTo, lod, room,
--       collision / visible (after SetEntityCollision / SetEntityVisible), alphaLog = { … } };
--       h.newEntity(model, x, y, z [, type]) -> handle; h.alive() -> live entity count
--   h.models[hash] = { mode = 'ok' | 'missing' | 'never' | 'vehicle' | 'ped', delay = ms }  (default ok, 0 ms)
--   h.anims[name], h.ptfx[name] = { mode = 'ok' | 'missing' | 'never', delay = ms }
--   h.requested[key], h.released[key] -> request / release counts of models, anim dicts, ptfx assets
--   h.set.interiorAt = function(x, y, z) -> interior id ; h.interiorReady[id] = true
--   h.set.poolExtra = objects the fake game pool holds besides ours (GetGamePool('CObject'))
--   h.players[serverId] = ped handle ; h.netEntities[netId] = entity handle
--   h.C.focus: an empty fake of client/scene_focus.lua's C.focus (the predecessor scene_mat_assets.lua asserts)
--   h.cache: the fake C.cache — h.node(id, kindId, class, x, y, z, fields [, extra]) builds and registers a
--       node record (extra: parent, children, motion, attach, offset, offrot, bone, radius, flags, unwanted)
--   h.motion = Core.SceneMotion (the real module; build descriptors with h.motion.validate(desc))
local here = debug.getinfo(1, 'S').source:match('^@(.*)/') or '.'
-- fxlint-disable-next-line S006 -- offline harness loads checked-in stubs only
local stubs = dofile(here .. '/stubs.lua')

local H = {}

function H.new(opts)
    opts = opts or {}
    stubs.newWorld()
    stubs.clear()
    local h = { stubs = stubs, FRAME = 16, calls = {}, warnings = {}, ents = {}, models = {}, anims = {}, ptfx = {},
        requested = {}, released = {}, interiorReady = {}, players = {}, netEntities = {}, nodes = {},
        set = { fov = 50.0, lodscale = 1.0, poolExtra = 0, interiorAt = nil } }
    local env = stubs.newEnv('client', 'core')
    h.env = env
    stubs.loadFile(env, 'import.lua')
    stubs.loadFile(env, 'shared/config.lua')
    if opts.scene then opts.scene(env.Config.Scene) end
    stubs.loadFile(env, 'client/api.lua')
    env.Wait = function(ms) return coroutine.yield((tonumber(ms) or 0) > 0 and ms or h.FRAME) end
    env.Citizen.Wait = env.Wait
    local function warn(fmt, ...) h.warnings[#h.warnings + 1] = tostring(fmt):format(...) end
    env.Core.Log = { warn = warn, error = warn, info = function() end, debug = function() end }
    local calls = h.calls
    local function count(name) calls[name] = (calls[name] or 0) + 1 end
    function h.n(name) return calls[name] or 0 end
    function h.tick(ms) return stubs.tick(ms) end
    function h.frames(n) return stubs.tick((n or 1) * h.FRAME) end
    function h.now() return stubs.now() end
    function h.load(path, ...) return stubs.loadFile(env, path, ...) end

    -- camera: one persistent vector each (the materialiser reads them without allocating)
    local camC, camR = stubs.vector3(0.0, 0.0, 0.0), stubs.vector3(0.0, 0.0, 0.0)
    function h.cam(x, y, z, pitch, yaw)
        camC.x, camC.y, camC.z = x + 0.0, y + 0.0, z + 0.0
        if pitch then camR.x = pitch + 0.0 end
        if yaw then camR.z = yaw + 0.0 end
    end
    env.GetFinalRenderedCamCoord = function() count('GetFinalRenderedCamCoord') return camC end
    env.GetFinalRenderedCamRot = function(order)
        count('GetFinalRenderedCamRot')
        assert(order == 2, 'rotation order 2')
        return camR
    end
    env.GetFinalRenderedCamFov = function() count('GetFinalRenderedCamFov') return h.set.fov end
    env.GetLodscale = function() count('GetLodscale') return h.set.lodscale end

    -- entities
    local nextHandle = 7000
    local ents = h.ents
    function h.newEntity(model, x, y, z, etype)
        nextHandle = nextHandle + 1
        ents[nextHandle] = { model = model, x = x, y = y, z = z, rx = 0.0, ry = 0.0, rz = 0.0, type = etype or 3,
            alphaLog = {} }
        return nextHandle
    end
    function h.alive()
        local c = 0
        for _, e in pairs(ents) do if not e.deleted and not e.foreign then c = c + 1 end end
        return c
    end
    local function ent(e) return ents[e] and not ents[e].deleted and ents[e] or nil end
    env.CreateObjectNoOffset = function(model, x, y, z, network, host, dynamic)
        count('CreateObjectNoOffset')
        assert(network == false and host == false and dynamic == false, 'local static object')
        return h.newEntity(model, x, y, z, 3)
    end
    -- BOOL natives answer 1 / false like the default invoke route (AGENTS §8)
    env.DoesEntityExist = function(e) count('DoesEntityExist') return ent(e) and 1 or false end
    env.DeleteEntity = function(e)
        count('DeleteEntity')
        assert(ent(e), 'DeleteEntity of a live entity (' .. tostring(e) .. ')')
        ents[e].deleted = true
    end
    env.SetEntityAlpha = function(e, a, skin)
        count('SetEntityAlpha')
        assert(skin == false, 'SetEntityAlpha(e, a, false)')
        local r = assert(ent(e), 'SetEntityAlpha on a live entity')
        r.alpha = a
        r.alphaLog[#r.alphaLog + 1] = a
    end
    env.ResetEntityAlpha = function(e)
        count('ResetEntityAlpha')
        local r = ent(e)
        if r then r.alpha, r.reset = nil, (r.reset or 0) + 1 end
    end
    env.SetEntityLodDist = function(e, v) count('SetEntityLodDist') ents[e].lod = v end
    env.SetEntityCoordsNoOffset = function(e, x, y, z, a, b, c)
        count('SetEntityCoordsNoOffset')
        assert(a == false and b == false and c == false, 'SetEntityCoordsNoOffset(..., false, false, false)')
        local r = ents[e]
        r.x, r.y, r.z = x, y, z
    end
    env.SetEntityRotation = function(e, rx, ry, rz, order, p5)
        count('SetEntityRotation')
        assert(order == 2 and p5 == false, 'SetEntityRotation(..., 2, false)')
        local r = ents[e]
        r.rx, r.ry, r.rz = rx, ry, rz
    end
    env.IsEntityAttached = function(e) count('IsEntityAttached') return (ent(e) and ents[e].attachedTo) and 1 or false end
    env.GetEntityAttachedTo = function(e) count('GetEntityAttachedTo') return (ent(e) and ents[e].attachedTo) or 0 end
    env.AttachEntityToEntity = function(...)
        count('AttachEntityToEntity')
        assert(select('#', ...) == 16, 'AttachEntityToEntity takes 16 arguments (OAL)')
        local e, p, bone, ox, oy, oz, rx, ry, rz = ...
        local r = ents[e]
        r.attachedTo, r.bone, r.attachOffset, r.attachRot = p, bone, { ox, oy, oz }, { rx, ry, rz }
        r.attachArgs = table.pack(...)
    end
    env.DetachEntity = function(e) count('DetachEntity') ents[e].attachedTo = nil end
    env.GetEntityType = function(e) return ents[e] and ents[e].type or 0 end
    env.GetPedBoneIndex = function(_, bone) count('GetPedBoneIndex') return bone + 1000 end
    env.GetEntityBoneIndexByName = function(_, name) count('GetEntityBoneIndexByName') return name == 'missing' and -1 or 7 end
    env.GetEntityCoords = function(e)
        count('GetEntityCoords')
        local r = ents[e]
        return stubs.vector3(r and r.x or 0.0, r and r.y or 0.0, r and r.z or 0.0)
    end
    env.GetEntityRotation = function(e, order)
        assert(order == 2, 'GetEntityRotation(e, 2)')
        local r = ents[e]
        return stubs.vector3(r and r.rx or 0.0, r and r.ry or 0.0, r and r.rz or 0.0)
    end
    env.GetPlayerFromServerId = function(src) return h.players[src] and src or -1 end
    env.GetPlayerPed = function(player) return h.players[player] or 0 end
    env.NetworkDoesEntityExistWithNetworkId = function(id) count('NetworkDoesEntityExistWithNetworkId') return h.netEntities[id] and 1 or false end
    env.NetworkGetEntityFromNetworkId = function(id) count('NetworkGetEntityFromNetworkId') return h.netEntities[id] or 0 end
    env.SetEntityHeading = function(e, v) ents[e].rz = v end
    env.FreezeEntityPosition = function(e, on) ents[e].frozen = on end
    -- RV6 F3 (a world change): collision off and hidden the frame the old world's copies are dropped
    env.SetEntityCollision = function(e, on, keep)
        count('SetEntityCollision')
        local r = assert(ent(e), 'SetEntityCollision on a live entity')
        r.collision, r.keepPhysics = on, keep
    end
    env.SetEntityVisible = function(e, on, p2)
        count('SetEntityVisible')
        local r = assert(ent(e), 'SetEntityVisible on a live entity')
        r.visible = on
        assert(p2 == false, 'SetEntityVisible(e, on, false)')
    end

    -- assets: models / anim dicts / ptfx assets with a mode and a load delay from the first request
    local reqAt = {}
    local function assetOk(t, key) return not (t[key] and t[key].mode == 'missing') end
    local function loaded(t, key)
        local spec = t[key]
        if not reqAt[key] or (spec and spec.mode == 'never') then return false end
        return stubs.now() - reqAt[key] >= (spec and spec.delay or 0) and 1 or false
    end
    local function request(name, key)
        count(name)
        h.requested[key] = (h.requested[key] or 0) + 1
        reqAt[key] = reqAt[key] or stubs.now()
    end
    local function release(name, key)
        count(name)
        h.released[key], reqAt[key] = (h.released[key] or 0) + 1, nil
    end
    env.IsModelInCdimage = function(m) count('IsModelInCdimage') return assetOk(h.models, m) and 1 or false end
    env.IsModelValid = function(m) return assetOk(h.models, m) and 1 or false end
    env.IsModelAVehicle = function(m) count('IsModelAVehicle') return (h.models[m] and h.models[m].mode == 'vehicle') and 1 or false end
    env.IsModelAPed = function(m) count('IsModelAPed') return (h.models[m] and h.models[m].mode == 'ped') and 1 or false end
    env.RequestModel = function(m) request('RequestModel', m) end
    env.HasModelLoaded = function(m) count('HasModelLoaded') return loaded(h.models, m) end
    env.SetModelAsNoLongerNeeded = function(m) release('SetModelAsNoLongerNeeded', m) end
    env.DoesAnimDictExist = function(d) count('DoesAnimDictExist') return assetOk(h.anims, d) and 1 or false end
    env.RequestAnimDict = function(d) request('RequestAnimDict', d) end
    env.HasAnimDictLoaded = function(d) count('HasAnimDictLoaded') return loaded(h.anims, d) end
    env.RemoveAnimDict = function(d) release('RemoveAnimDict', d) end
    env.RequestNamedPtfxAsset = function(a) request('RequestNamedPtfxAsset', a) end
    env.HasNamedPtfxAssetLoaded = function(a) count('HasNamedPtfxAssetLoaded') return loaded(h.ptfx, a) end
    env.RemoveNamedPtfxAsset = function(a) release('RemoveNamedPtfxAsset', a) end

    -- interiors, the object pool
    env.GetInteriorAtCoords = function(x, y, z)
        count('GetInteriorAtCoords')
        return h.set.interiorAt and h.set.interiorAt(x, y, z) or 0
    end
    env.IsInteriorReady = function(id) count('IsInteriorReady') return h.interiorReady[id] and 1 or false end
    env.ForceRoomForEntity = function(e, int, key)
        count('ForceRoomForEntity')
        ents[e].room = { int, key }
    end
    env.GetGamePool = function(name)
        count('GetGamePool')
        assert(name == 'CObject', 'GetGamePool("CObject")')
        local list = {}
        for handle, r in pairs(ents) do if not r.deleted and r.type == 3 then list[#list + 1] = handle end end
        for i = 1, h.set.poolExtra do list[#list + 1] = -i end
        return list
    end

    -- the fake cache and the runtime hand-off
    local kinds = {}
    local cache = {
        node = function(id) return h.nodes[id] end,
        kind = function(idx) return kinds[idx] end,
        kindById = function(id) for _, k in pairs(kinds) do if k.id == id then return k end end return nil end,
        forEachNode = function(fn) for _, n in pairs(h.nodes) do fn(n) end end,
        stats = function() return {} end,
        wanted = function(node) return node.unwanted ~= true end,
    }
    h.cache = cache
    --- A node record the way the cache builds them (INTERFACES §5); `class` = a class name or wire code.
    function h.node(id, kindId, class, x, y, z, fields, extra)
        local k
        for _, kk in pairs(kinds) do if kk.id == kindId then k = kk end end
        if not k then
            k = { idx = #kinds + 1, id = kindId, class = class, meta = nil }
            kinds[k.idx] = k
        end
        local node = { id = id, kindIdx = k.idx, kind = k, ver = 1, parent = 0, flags = 0, x = x + 0.0, y = y + 0.0,
            z = z + 0.0, rx = 0.0, ry = 0.0, rz = 0.0, radius = 0, fields = fields or {}, children = nil }
        for key, v in pairs(extra or {}) do node[key] = v end
        h.nodes[id] = node
        return node
    end
    if opts.runtime ~= false then
        env.CoreSceneRuntime = { cache = cache, focus = {} }
        h.C = env.CoreSceneRuntime
    end
    --- The materialiser in the manifest order: scene_mat_assets -> scene_materializer -> scene_movers.
    function h.loadMat()
        h.load('client/scene_mat_assets.lua')
        h.load('client/scene_materializer.lua')
        h.load('client/scene_movers.lua')
    end
    if opts.motion ~= false then h.load('shared/scene_motion.lua') end
    h.motion = env.Core.SceneMotion
    return h
end

return H
