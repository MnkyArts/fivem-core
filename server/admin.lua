--- core/server/admin.lua — admin and utility commands (DESIGN §4.8), all registered through
--- Core.Commands.register (typed params + permission), plus the `core:server:teleportToWaypoint`
--- handler from DESIGN §5 (/tpm itself is a client command in client/main.lua).

local Commands = Core.Commands
local Net = Core.Net
local Utils = Core.Utils

local PERM_ADMIN <const> = 'core.admin'
local PERM_MOD <const> = 'core.mod'
local DV_RADIUS <const> = 5.0
local MAX_PLAYER_LIST <const> = 20
local FACTION_COOLDOWN_MS <const> = 1000
local MAP_LIMIT_XY <const> = 5000.0
local MAP_LIMIT_Z_MIN <const> = -300.0
local MAP_LIMIT_Z_MAX <const> = 2000.0

--- Answers the caller: notification in game, plain print on the console (src 0).
local function reply(src, message, kind)
    if src == 0 then
        print(('[core] %s'):format(message))
        return
    end
    Core.Notify.send(src, message, kind or 'info')
end

local function inBounds(coords)
    return math.abs(coords.x) <= MAP_LIMIT_XY and math.abs(coords.y) <= MAP_LIMIT_XY
        and coords.z >= MAP_LIMIT_Z_MIN and coords.z <= MAP_LIMIT_Z_MAX
end

local function adminName(src)
    if src == 0 then return 'console' end
    return GetPlayerName(src) or ('src ' .. src)
end

--- Closest core-spawned vehicle entity within `radius`, or 0.
local function nearestCoreVehicle(coords, radius)
    local best, bestDist = 0, radius
    local list = Core.Vehicles.list()
    for i = 1, #list do
        local entity = Core.Vehicles.getEntity(list[i])
        if entity ~= 0 then
            local dist = #(GetEntityCoords(entity) - coords)
            if dist <= bestDist then best, bestDist = entity, dist end
        end
    end
    return best
end

--- Closest vehicle of any origin within `radius`, or 0.
local function nearestVehicle(coords, radius)
    local vehicles = GetAllVehicles()
    local best, bestDist = 0, radius
    for i = 1, #vehicles do
        local entity = vehicles[i]
        if DoesEntityExist(entity) then
            local dist = #(GetEntityCoords(entity) - coords)
            if dist <= bestDist then best, bestDist = entity, dist end
        end
    end
    return best
end

Commands.register('id', { description = 'Show your own server id' }, function(src)
    if src == 0 then return end
    reply(src, ('Your id: [%d] %s'):format(src, adminName(src)), 'info')
end)

Commands.register('players', { description = 'List connected players', allowConsole = true }, function(src)
    local players = GetPlayers()
    local lines = {}
    for i = 1, #players do
        if i > MAX_PLAYER_LIST then break end
        local id = tonumber(players[i])
        if id then lines[#lines + 1] = ('[%d] %s'):format(id, GetPlayerName(id) or '?') end
    end
    reply(src, ('%d player(s): %s'):format(#players, table.concat(lines, ', ')), 'info')
end)

Commands.register('car', {
    description = 'Spawn a vehicle and get in',
    permission = PERM_ADMIN,
    params = {
        { name = 'model', type = 'string', help = 'vehicle model', optional = true },
        { name = 'plate', type = 'string', help = 'custom plate', optional = true },
    },
}, function(src, args)
    if src == 0 then return end
    local ped = GetPlayerPed(src)
    if ped == 0 then return end
    local model = args.model or Config.Admin.CarDefaultModel
    local netId, err = Core.Vehicles.spawn({
        model = model,
        coords = GetEntityCoords(ped),
        heading = GetEntityHeading(ped),
        plate = args.plate,
        ownerSrc = src,
    })
    if not netId then
        reply(src, ('Could not spawn %s (%s)'):format(model, tostring(err)), 'error')
        return
    end
    TriggerClientEvent('core:client:warpIntoVehicle', src, netId)
    reply(src, ('Spawned %s (netId %d)'):format(model, netId), 'success')
end)

Commands.register('dv', {
    description = 'Delete the vehicle you are in, or the closest one',
    permission = PERM_ADMIN,
}, function(src)
    if src == 0 then return end
    local ped = GetPlayerPed(src)
    if ped == 0 then return end
    local coords = GetEntityCoords(ped)
    local entity = GetVehiclePedIsIn(ped, false)
    if entity == 0 then entity = nearestCoreVehicle(coords, DV_RADIUS) end
    if entity == 0 then entity = nearestVehicle(coords, DV_RADIUS) end
    if entity == 0 or not DoesEntityExist(entity) then
        reply(src, 'No vehicle within 5 m', 'error')
        return
    end
    local netId = NetworkGetNetworkIdFromEntity(entity)
    if netId ~= 0 and Core.Vehicles.getInfo(netId) then
        Core.Vehicles.delete(netId)
    else
        DeleteEntity(entity)
    end
    reply(src, 'Vehicle deleted', 'success')
end)

Commands.register('tp', {
    description = 'Teleport to coordinates',
    permission = PERM_ADMIN,
    params = {
        { name = 'x', type = 'number' }, { name = 'y', type = 'number' }, { name = 'z', type = 'number' },
    },
}, function(src, args)
    if src == 0 then return end
    local coords = vector3(args.x, args.y, args.z)
    if not inBounds(coords) then
        reply(src, 'Those coordinates are outside the map', 'error')
        return
    end
    Core.Player.setCoords(src, coords)
    reply(src, ('Teleported to %.1f, %.1f, %.1f'):format(coords.x, coords.y, coords.z), 'success')
end)

--- /tpm is a client command (client/main.lua) that reads the waypoint and sends this event.
Net.on('core:server:teleportToWaypoint', { 'vector3' }, function(src, coords)
    if not inBounds(coords) then return end
    Core.Player.setCoords(src, coords)
end, { cooldown = 1000, requireLoaded = true, permission = PERM_ADMIN })

Commands.register('tpto', {
    description = 'Teleport to a player',
    permission = PERM_ADMIN,
    params = { { name = 'player', type = 'player', help = 'server id' } },
}, function(src, args)
    if src == 0 then return end
    local coords, heading = Core.Player.getCoords(args.player)
    if not coords then
        reply(src, 'That player has no position', 'error')
        return
    end
    Core.Player.setCoords(src, coords, heading)
    reply(src, ('Teleported to %s'):format(adminName(args.player)), 'success')
end)

Commands.register('bring', {
    description = 'Bring a player to you',
    permission = PERM_ADMIN,
    params = { { name = 'player', type = 'player', help = 'server id' } },
}, function(src, args)
    if src == 0 then return end
    local coords, heading = Core.Player.getCoords(src)
    if not coords then
        reply(src, 'You have no position', 'error')
        return
    end
    Core.Player.setCoords(args.player, coords, heading)
    reply(src, ('Brought %s'):format(adminName(args.player)), 'success')
    Core.Notify.send(args.player, 'You were teleported by an admin', 'info')
end)

--- /setcash /setbank /givecash /givebank — `mode` is 'set' (absolute) or 'add' (delta).
local function registerMoneyCommand(name, account, mode, description)
    Commands.register(name, {
        description = description,
        permission = PERM_ADMIN,
        allowConsole = true,
        params = {
            { name = 'player', type = 'player', help = 'server id' },
            { name = 'amount', type = 'integer', help = 'amount' },
        },
    }, function(src, args)
        local amount = args.amount
        local minimum = mode == 'set' and 0 or 1
        if amount < minimum or amount > Config.Money.MaxAmount then
            reply(src, 'Invalid amount', 'error')
            return
        end
        local ok
        if mode == 'set' then
            ok = Core.Money.set(args.player, account, amount, 'admin')
        else
            ok = Core.Money.add(args.player, account, amount, 'admin')
        end
        if not ok then
            reply(src, 'Money change failed (player not loaded or cap reached)', 'error')
            return
        end
        reply(src, ('%s %s %s for %s'):format(mode == 'set' and 'Set' or 'Gave',
            Utils.formatMoney(amount), account, adminName(args.player)), 'success')
    end)
end

registerMoneyCommand('setcash', 'cash', 'set', "Set a player's cash")
registerMoneyCommand('setbank', 'bank', 'set', "Set a player's bank balance")
registerMoneyCommand('givecash', 'cash', 'add', 'Give cash to a player')
registerMoneyCommand('givebank', 'bank', 'add', 'Give bank money to a player')

Commands.register('setgroup', {
    description = 'Set a player permission group',
    permission = PERM_ADMIN,
    allowConsole = true,
    params = {
        { name = 'player', type = 'player', help = 'server id' },
        { name = 'group', type = 'string', help = 'user | mod | admin' },
    },
}, function(src, args)
    if not Core.Perms.setGroup(args.player, args.group) then
        reply(src, ('Unknown group: %s'):format(args.group), 'error')
        return
    end
    reply(src, ('%s is now %s'):format(adminName(args.player), args.group), 'success')
    Core.Notify.send(args.player, ('Your group is now %s'):format(args.group), 'info')
end)

Commands.register('kick', {
    description = 'Kick a player',
    permission = PERM_MOD,
    allowConsole = true,
    params = {
        { name = 'player', type = 'player', help = 'server id' },
        { name = 'reason', type = 'rest', optional = true },
    },
}, function(src, args)
    local reason = Utils.sanitize(args.reason or 'Kicked by staff', 128)
    Core.Player.kick(args.player, reason)
    reply(src, ('Kicked %s (%s)'):format(adminName(args.player), reason), 'success')
end)

Commands.register('ban', {
    description = 'Ban a player for a number of hours (0 = permanent)',
    permission = PERM_ADMIN,
    allowConsole = true,
    params = {
        { name = 'player', type = 'player', help = 'server id' },
        { name = 'hours', type = 'integer', help = 'hours, 0 = permanent' },
        { name = 'reason', type = 'rest', optional = true },
    },
}, function(src, args)
    if args.hours < 0 or args.hours > 87600 then
        reply(src, 'Hours must be between 0 and 87600', 'error')
        return
    end
    local reason = Utils.sanitize(args.reason or 'Banned by staff', 128)
    Core.Player.ban(args.player, reason, args.hours * 3600, adminName(src))
    reply(src, ('Banned %s for %s (%s)'):format(adminName(args.player),
        args.hours == 0 and 'ever' or (args.hours .. ' h'), reason), 'success')
end)

Commands.register('announce', {
    description = 'Broadcast a message to everyone',
    permission = PERM_MOD,
    allowConsole = true,
    params = { { name = 'message', type = 'rest', help = 'message' } },
}, function(src, args)
    local message = Utils.sanitize(args.message, 256)
    if #message == 0 then
        reply(src, 'Nothing to announce', 'error')
        return
    end
    Core.Notify.broadcast(message, 'info')
end)

Commands.register('revive', {
    description = 'Revive a player where they are',
    permission = PERM_MOD,
    params = { { name = 'player', type = 'player', help = 'server id', optional = true } },
}, function(src, args)
    local target = args.player or src
    if target == 0 then
        reply(src, 'Usage: /revive <player>', 'error')
        return
    end
    local coords, heading = Core.Player.getCoords(target)
    Core.Player.respawn(target, coords, heading)
    reply(src, ('Revived %s'):format(adminName(target)), 'success')
end)

Commands.register('heal', {
    description = 'Restore health and armour',
    permission = PERM_MOD,
    params = { { name = 'player', type = 'player', help = 'server id', optional = true } },
}, function(src, args)
    local target = args.player or src
    if target == 0 then
        reply(src, 'Usage: /heal <player>', 'error')
        return
    end
    TriggerClientEvent('core:client:heal', target)
    reply(src, ('Healed %s'):format(adminName(target)), 'success')
end)

--- /faction — a thin chat front-end over Core.Factions (the UI route are the §5.2 callbacks).
local function words(raw)
    local parts = {}
    if type(raw) ~= 'string' then return parts end
    for word in raw:gmatch('%S+') do parts[#parts + 1] = word end
    return parts
end

-- /faction is open to everyone and its actions read (and deep-copy) faction documents,
-- so it gets its own per-src throttle; chat itself can be driven far faster than that.
local factionCooldown = {}

AddEventHandler('playerDropped', function()
    local src = source
    factionCooldown[src] = nil
end)

local factionActions = {}

function factionActions.create(src, parts)
    if #parts < 2 then return false, 'Usage: /faction create <name> <tag>' end
    local tag = parts[#parts]
    local name = table.concat(parts, ' ', 1, #parts - 1)
    local id, err = Core.Factions.create(src, name, tag)
    if not id then return false, err or 'Could not create the faction' end
    return true, ('Faction %s [%s] created'):format(name, tag)
end

function factionActions.invite(src, parts)
    local target = math.tointeger(tonumber(parts[1]))
    if not target then return false, 'Usage: /faction invite <player id>' end
    local ok, err = Core.Factions.invite(src, target)
    if not ok then return false, err or 'Could not invite that player' end
    return true, ('Invited [%d] %s'):format(target, adminName(target))
end

function factionActions.accept(src)
    local ok, err = Core.Factions.acceptInvite(src)
    if not ok then return false, err or 'No pending invite' end
    return true, 'You joined the faction'
end

function factionActions.leave(src)
    local ok, err = Core.Factions.leave(src)
    if not ok then return false, err or 'Could not leave' end
    return true, 'You left the faction'
end

function factionActions.kick(src, parts)
    if not parts[1] then return false, 'Usage: /faction kick <charId>' end
    local ok, err = Core.Factions.kick(src, parts[1])
    if not ok then return false, err or 'Could not kick that member' end
    return true, 'Member kicked'
end

function factionActions.rank(src, parts)
    local rank = math.tointeger(tonumber(parts[2]))
    if not parts[1] or not rank then return false, 'Usage: /faction rank <charId> <rank>' end
    local ok, err = Core.Factions.setRank(src, parts[1], rank)
    if not ok then return false, err or 'Could not change that rank' end
    return true, ('Rank set to %d'):format(rank)
end

function factionActions.info(src)
    local faction = Core.Factions.getPlayerFaction(src)
    if not faction then return false, 'You are not in a faction' end
    return true, ('%s [%s] - rank %d (%s)%s'):format(faction.name, faction.tag, faction.rank,
        faction.rankName, faction.isOwner and ' - owner' or '')
end

function factionActions.list()
    local factions = Core.Factions.list()
    if #factions == 0 then return true, 'No factions yet' end
    local lines = {}
    for i = 1, #factions do
        if i > MAX_PLAYER_LIST then break end
        lines[#lines + 1] = ('%s [%s] (%d)'):format(factions[i].name, factions[i].tag, factions[i].memberCount)
    end
    return true, table.concat(lines, ', ')
end

Commands.register('faction', {
    description = 'Faction commands',
    params = {
        { name = 'action', type = 'string', help = 'create|invite|accept|leave|kick|rank|info|list' },
        { name = 'rest', type = 'rest', optional = true },
    },
}, function(src, args)
    if src == 0 then return end
    local now = GetGameTimer()
    if now < (factionCooldown[src] or 0) then return end
    factionCooldown[src] = now + FACTION_COOLDOWN_MS
    local action = factionActions[args.action:lower()]
    if not action then
        reply(src, 'Usage: /faction <create|invite|accept|leave|kick|rank|info|list>', 'error')
        return
    end
    local ok, message = action(src, words(args.rest))
    reply(src, message or (ok and 'Done' or 'Failed'), ok and 'success' or 'error')
end)
