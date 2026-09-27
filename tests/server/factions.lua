return function(H)
    local check, eq, errOf, lastSent, newServer, printed, stubs, suite =
        H.check, H.eq, H.errOf, H.lastSent, H.newServer, H.printed, H.stubs, H.suite

--- Runs fn() once around the first core_db `query` of env whose SQL contains `needle`: `when` = 'before' (the call
--- has not been sent yet) or 'after' (it answered, the caller has not resumed yet) — what a yield would allow.
--- Returns the function that takes the hook out again.
local function hookQuery(env, needle, when, fn)
    local real = rawget(env.exports, 'core_db')
    local wrap = setmetatable({ synchronous = rawget(real, 'synchronous') }, {
        __index = function(t, name)
            local call = function(_, ...)
                local sql = ...
                local hit = fn and name == 'query' and type(sql) == 'string' and sql:find(needle, 1, true) ~= nil
                local once = hit and fn or nil
                if once then fn = nil end
                if once and when == 'before' then once() end
                local out = table.pack(real[name](real, ...))
                if once and when == 'after' then once() end
                return table.unpack(out, 1, out.n)
            end
            rawset(t, name, call)
            return call
        end,
    })
    rawset(env.exports, 'core_db', wrap)
    return function() rawset(env.exports, 'core_db', real) end
end

--- Core.Factions (DESIGN §4.5, §8, §56): create, the membership chain, permission denials, the invite squatting
--- rule, the bank against Core.Money (and a failing bank statement), the unique indexes and the one-faction key
--- behind memory's back, rank renumbering in the rows, a restart, the disband cascade and a failed load; the review
--- fixes (R3a): awaited renames + UTF-8 names, dropped queued writes read back, outcomes re-read after a lost answer,
--- a deposit into a faction disbanded meanwhile, offline refunds, reconcile writing only what changed.
local function suiteFactions()
    suite('factions')
    stubs.resetServer()
    local env, Core = newServer()
    local F, Money, Player = Core.Factions, Core.Money, Core.Player
    local cfg = Core.Config.Factions
    stubs.connectPlayer(env, 1, { license = 'license:f1', name = 'Boss' })
    stubs.connectPlayer(env, 2, { license = 'license:f2', name = 'Rook' })
    stubs.connectPlayer(env, 3, { license = 'license:f3', name = 'Rival' })
    local c1, c2 = Player.getInfo(1).charId, Player.getInfo(2).charId

    local updated, changed = {}, {}
    Core.on('factionUpdated', function(id) updated[#updated + 1] = id end)
    Core.on('factionChanged', function(src, summary) changed[#changed + 1] = { src = src, summary = summary } end)

    -- create charges CreateCost from CostAccount
    eq(Money.get(1, cfg.CostAccount), 25000, 'the founder can afford the fee')
    local id, createErr = F.create(1, 'Los Santos Cabs', 'lsc')
    check(type(id) == 'string', 'create returns the faction id', tostring(createErr))
    eq(Money.get(1, cfg.CostAccount), 25000 - cfg.CreateCost, 'CreateCost was charged')
    local doc = F.get(id)
    eq(doc.name, 'Los Santos Cabs', 'the document carries the name')
    eq(doc.tag, 'LSC', 'the tag is upper-cased')
    eq(doc.color, cfg.DefaultColor, 'the default colour is applied')
    eq(doc.ownerCharId, c1, 'the creator owns it')
    eq(doc.members[c1].rank, #cfg.DefaultRanks, 'the creator gets the highest default rank')
    eq(doc.bank, 0, 'the bank starts empty')
    eq(env.GlobalState['faction:' .. id].memberCount, 1, 'the faction was published to GlobalState')
    eq(env.GlobalState['faction:' .. id].tag, 'LSC', 'the GlobalState entry carries the tag')
    eq(env.Player(1).state.faction.tag, 'LSC', 'the faction state-bag key was written')
    eq(env.Player(1).state.faction.rankName, 'Leader', 'the state bag carries the rank name')
    eq(env.Player(1).state.faction.perms, nil, 'the state summary carries only the six public fields')
    eq(Player.getData(1, 'faction').id, id, 'the character document remembers the faction')
    eq(updated[#updated], id, 'the factionUpdated hook fired')
    eq(changed[#changed].summary.isOwner, true, 'the factionChanged hook carries the full summary')
    eq(F.getPlayerFaction(1).perms.manage, true, 'the owner has every permission')

    -- create refusals
    eq(errOf(F.create(1, 'Other Co', 'OTH')), 'already_in_faction', 'a member cannot found a second one')
    eq(errOf(F.create(2, 'los santos cabs', 'XX2')), 'name_taken', 'names are unique, case-insensitively')
    eq(errOf(F.create(2, 'Fresh Start', 'lsc')), 'tag_taken', 'tags are unique, case-insensitively')
    eq(errOf(F.create(2, 'ab', 'FRS')), 'invalid_name', 'the name minimum is enforced')
    eq(errOf(F.create(2, 'Fresh Start', 'f')), 'invalid_tag', 'the tag minimum is enforced')
    eq(errOf(F.create(2, 'Fresh Start', 'to long')), 'invalid_tag', 'the tag pattern is enforced')
    eq(errOf(F.create(2, 'Fresh Start', 'FRS', { color = 'blue' })), 'invalid_color', 'the colour must be #RRGGBB')
    eq(errOf(F.create(0, 'Fresh Start', 'FRS')), 'arg 1: expected src 1..4096, got 0', 'src 0 cannot found one')
    eq(errOf(F.create(99, 'Fresh Start', 'FRS')), 'not_loaded', 'a src without a session cannot found one')
    Money.set(2, cfg.CostAccount, cfg.CreateCost - 1, 'poor')
    eq(errOf(F.create(2, 'Fresh Start', 'FRS')), 'insufficient_funds', 'the fee must be affordable')
    eq(H.scalar("SELECT count(*) FROM factions WHERE tag = 'FRS'"), 0, 'no row is left behind')
    eq(H.scalar('SELECT count(*) FROM factions'), 1, 'exactly one faction exists')
    eq(H.scalar('SELECT rank FROM faction_members WHERE character_id = $1 AND faction_id = $2', { c1, id }),
        #cfg.DefaultRanks, 'the founder\'s member row was written with the faction (one transaction)')

    -- invite -> accept -> rank -> kick
    eq(errOf(F.invite(2, 3)), 'no_faction', 'a player in no faction cannot invite')
    eq(errOf(F.invite(1, 1)), 'self_target', 'nobody invites themselves')
    eq(errOf(F.invite(1, 99)), 'target_not_loaded', 'the target needs a session')
    stubs.clear()
    eq(F.invite(1, 2), true, 'the owner invites')
    check((lastSent('core:client:notify') or {}).target ~= nil, 'the invite is notified')
    eq(errOf(F.acceptInvite(3)), 'no_invite', 'accepting without an invite is refused')
    eq(F.acceptInvite(2), true, 'the invite is accepted')
    eq(F.get(id).members[c2].rank, 1, 'a new member joins at rank 1')
    eq(H.scalar('SELECT rank FROM faction_members WHERE character_id = $1 AND faction_id = $2', { c2, id }), 1,
        'the member row exists before acceptInvite answers')
    eq(F.get(id).members[c2].name, 'Rook', 'the member row carries the display name')
    eq(env.Player(2).state.faction.rankName, 'Member', 'the member state bag carries the rank name')
    eq(env.GlobalState['faction:' .. id].memberCount, 2, 'the member count was republished')
    eq(#F.getMembers(id), 2, 'getMembers lists both')
    eq(F.getMembers(id)[1].charId, c1, 'getMembers sorts by rank, highest first')
    eq(F.getMembers(id)[1].online, 1, 'getMembers resolves the online src')
    eq(errOf(F.acceptInvite(2)), 'no_invite', 'the invite was consumed')

    -- permission denials for a rank-1 member
    eq(errOf(F.invite(2, 3)), 'no_permission', 'rank 1 may not invite')
    eq(errOf(F.kick(2, c1)), 'no_permission', 'rank 1 may not kick')
    eq(errOf(F.setRank(2, c1, 1)), 'no_permission', 'rank 1 may not manage ranks')
    eq(errOf(F.withdraw(2, 1)), 'no_permission', 'rank 1 may not withdraw')
    eq(errOf(F.update(2, { name = 'Renamed' })), 'no_permission', 'rank 1 may not rename')
    eq(errOf(F.disband(2)), 'not_owner', 'only the owner disbands')
    eq(errOf(F.leave(1)), 'owner_cannot_leave', 'the owner may not simply leave')
    eq(F.hasPerm(2, 'invite'), false, 'hasPerm agrees')
    eq(F.hasPerm(1, 'invite'), true, 'the owner has every perm')

    -- ranks
    eq(F.setRank(1, c2, 2), true, 'the owner promotes a member')
    eq(F.get(id).members[c2].rank, 2, 'the rank was written')
    eq(H.scalar('SELECT rank FROM faction_members WHERE character_id = $1', { c2 }), 2, '... to the member row')
    eq(env.Player(2).state.faction.rankName, 'Officer', 'the promoted member re-replicated')
    eq(F.hasPerm(2, 'invite'), true, 'rank 2 may invite now')
    eq(F.hasPerm(2, 'bank'), false, 'rank 2 still may not touch the bank')
    eq(errOf(F.setRank(1, c1, 1)), 'self_target', 'the owner cannot demote himself')
    eq(errOf(F.setRank(1, 'no-such-char', 2)), 'target_not_member', 'an unknown member is refused')
    eq(errOf(F.setRank(1, c2, 99)), 'arg 3: expected integer 1..8, got 99', 'the rank is range-checked')
    eq(errOf(F.setRank(1, c2, 3)), nil, 'the owner may promote to his own rank')
    eq(F.setRank(1, c2, 2), true, 'and demote again')

    -- kick
    eq(errOf(F.kick(1, c1)), 'self_target', 'the owner cannot kick himself')
    eq(F.kick(1, c2), true, 'the owner kicks the member')
    eq(F.get(id).members[c2], nil, 'the member is gone')
    eq(H.scalar('SELECT count(*) FROM faction_members WHERE character_id = $1', { c2 }), 0, '... and so is his row')
    eq(env.Player(2).state.faction, false, 'the kicked member replicates false, never nil')
    eq(Player.getData(2, 'faction'), false, 'the character document was cleared')
    eq(F.getPlayerFaction(2), nil, 'getPlayerFaction is nil again')
    eq(env.GlobalState['faction:' .. id].memberCount, 1, 'the member count shrank')
    eq(errOf(F.kick(1, c2)), 'target_not_member', 'kicking a non-member is refused')

    -- invite squatting: another faction may not overwrite a live invite
    local rivalId = F.create(3, 'Vagos', 'VGS')
    check(type(rivalId) == 'string', 'the rival faction was founded')
    eq(F.invite(1, 2), true, 'LSC invites the free agent')
    eq(errOf(F.invite(3, 2)), 'invite_pending', 'a second faction cannot squat on a pending invite')
    eq(F.invite(1, 2), true, 'the same faction may refresh its own invite')
    stubs.tick(cfg.InviteTimeoutMs + 1000)
    eq(F.invite(3, 2), true, 'once the invite expired another faction may invite')
    eq(F.acceptInvite(2), true, 'the free agent joins the rival')
    eq(F.getPlayerFaction(2).tag, 'VGS', 'and is now a Vago')
    eq(errOf(F.invite(1, 2)), 'target_in_faction', 'a member of another faction cannot be invited')
    eq(F.leave(2), true, 'a plain member may leave')
    eq(F.getPlayerFaction(2), nil, 'and is free again')
    eq(H.scalar('SELECT count(*) FROM faction_members WHERE character_id = $1', { c2 }), 0, 'leave removed the row')

    -- an expired invite is refused on accept as well
    eq(F.invite(1, 2), true, 'invited once more')
    stubs.tick(cfg.InviteTimeoutMs + 1)
    eq(errOf(F.acceptInvite(2)), 'invite_expired', 'an expired invite cannot be accepted')
    eq(F.invite(1, 2), true, 'invited again')
    eq(F.declineInvite(2), true, 'decline drops the invite')
    eq(F.declineInvite(2), false, 'a second decline is false')
    eq(errOf(F.acceptInvite(2)), 'no_invite', 'the declined invite is gone')

    -- bank: deposit, withdraw and the rollback of a failing document write
    Money.set(1, cfg.CostAccount, 5000, 'topup')
    eq(F.deposit(1, 1000), true, 'a member deposits')
    eq(F.getBank(id), 1000, 'the faction bank grew')
    eq(Money.get(1, cfg.CostAccount), 4000, 'the depositor paid')
    eq(errOf(F.deposit(1, 999999)), 'insufficient_funds', 'you cannot deposit what you lack')
    eq(errOf(F.deposit(1, 0)), 'arg 2: expected integer 1..999999999, got 0', 'the amount is range-checked')
    eq(F.withdraw(1, 400), true, 'the owner withdraws')
    eq(F.getBank(id), 600, 'the faction bank shrank')
    eq(Money.get(1, cfg.CostAccount), 4400, 'the money arrived')
    eq(errOf(F.withdraw(1, 5000)), 'insufficient_funds', 'you cannot withdraw more than the bank holds')
    local function bankRow() return H.scalar('SELECT bank FROM factions WHERE id = $1', { id }) end
    local function moneyRow(charId)
        return H.scalar('SELECT balance FROM character_money WHERE character_id = $1 AND account = $2',
            { charId, cfg.CostAccount })
    end
    eq(bankRow(), 600, 'the bank column agrees with memory')
    eq(moneyRow(c1), 4400, 'the money row agrees with the session')

    -- a failing bank statement never leaves money moved (§56.8 rule 2: one guarded UPDATE, money around it)
    H.bridge.fail('SET bank = bank', 'XX000 simulated bank failure')
    eq(errOf(F.deposit(1, 100)), 'save_failed', 'a failing bank statement refuses the deposit')
    eq(Money.get(1, cfg.CostAccount), 4400, 'and gives the money back')
    eq(errOf(F.withdraw(1, 100)), 'save_failed', 'a failing bank statement refuses the withdrawal')
    eq(Money.get(1, cfg.CostAccount), 4400, 'and pays nothing out')
    H.bridge.unfail()
    eq(F.getBank(id), 600, 'the faction bank is untouched by either')
    eq(bankRow(), 600, '... in the row as well')
    eq(moneyRow(c1), 4400, '... and the money row never moved')
    check(printed('faction_deposit_rollback') ~= nil, 'the rollback is audited')
    -- the SQL guard is the authority: a bank the row does not hold is refused even when memory disagrees
    H.sql('UPDATE factions SET bank = 50 WHERE id = $1', { id })
    eq(errOf(F.withdraw(1, 100)), 'insufficient_funds', 'the guarded UPDATE refuses what the row does not hold')
    eq(Money.get(1, cfg.CostAccount), 4400, 'and nothing was paid out')
    H.sql('UPDATE factions SET bank = 600 WHERE id = $1', { id })

    -- R3a-5: a refund to a player who left during the statement is credited to his money row, never destroyed
    local undo = hookQuery(env, 'SET bank = bank', 'before', function() stubs.dropPlayer(env, 1) end)
    H.bridge.fail('SET bank = bank', 'XX000 simulated bank failure')
    eq(errOf(F.deposit(1, 100)), 'save_failed', 'the deposit of a player who left meanwhile fails')
    H.bridge.unfail()
    undo()
    eq(Player.getInfo(1), nil, 'the depositor is gone')
    eq(moneyRow(c1), 4400, 'his refund was credited to his money row (one atomic upsert)')
    check(printed('credited to his bank offline') ~= nil, 'the offline credit is logged')
    stubs.connectPlayer(env, 1, { license = 'license:f1', name = 'Boss' })
    eq(Money.get(1, cfg.CostAccount), 4400, 'his next session has the money back')
    eq(F.getPlayerFaction(1).isOwner, true, 'and still leads his faction')

    -- R3a-2: a lost answer (connection-class error) is not "not applied": factions.bank is re-read
    H.sql('UPDATE factions SET bank = 700 WHERE id = $1', { id })     -- as if the statement had committed
    H.bridge.fail('SET bank = bank', '08006 simulated connection loss')
    eq(F.deposit(1, 100), true, 'a deposit that landed despite the lost answer counts')
    eq(Money.get(1, cfg.CostAccount), 4300, 'its money stays with the faction')
    eq(F.getBank(id), 700, 'memory follows the row')
    eq(errOf(F.deposit(1, 100)), 'save_failed', 'a deposit that did not land is refused')
    eq(Money.get(1, cfg.CostAccount), 4300, 'and refunded')
    eq(bankRow(), 700, 'the row never moved')
    H.bridge.unfail()
    H.sql('UPDATE factions SET bank = 600 WHERE id = $1', { id })     -- a withdrawal that landed
    H.bridge.fail('SET bank = bank', '08006 simulated connection loss')
    eq(F.withdraw(1, 100), true, 'a withdrawal that landed despite the lost answer pays out')
    H.bridge.unfail()
    eq(Money.get(1, cfg.CostAccount), 4400, 'the payout arrived')
    eq(F.getBank(id), 600, 'memory follows the row again')

    -- the unique indexes and the one-faction key decide when memory does not know (a row written behind core's back)
    local c3 = Player.getInfo(3).charId
    H.sql("INSERT INTO factions (id, name, tag) VALUES ('ghostcrew', 'Ghost Crew', 'GHO')")
    Money.set(2, cfg.CostAccount, 30000, 'topup')
    eq(errOf(F.create(2, 'ghost CREW', 'GC2')), 'name_taken', 'the lower(name) index refuses a duplicate memory missed')
    eq(Money.get(2, cfg.CostAccount), 30000, 'the fee came back')
    eq(errOf(F.create(2, 'Other Crew', 'gho')), 'tag_taken', 'the upper(tag) index refuses a duplicate tag')
    eq(Money.get(2, cfg.CostAccount), 30000, 'the fee came back again')
    H.sql('INSERT INTO faction_members (character_id, faction_id, rank) VALUES ($1, $2, 1)', { c2, 'ghostcrew' })
    eq(errOf(F.create(2, 'Other Crew', 'OTC')), 'already_in_faction', 'the faction_members key: one faction per character')
    eq(Money.get(2, cfg.CostAccount), 30000, 'refunded')
    eq(H.scalar("SELECT count(*) FROM factions WHERE tag = 'OTC'"), 0, 'the rolled back transaction left no faction row')
    eq(F.invite(1, 2), true, 'memory still sees a free agent')
    eq(errOf(F.acceptInvite(2)), 'already_in_faction', 'the member insert is refused by the key')
    eq(F.get(id).members[c2], nil, 'the reserved member was taken back')
    eq(F.getPlayerFaction(2), nil, 'and he is in no faction')
    local _, dupErr = H.bridge.sql('INSERT INTO faction_members (character_id, faction_id, rank) VALUES ($1, $2, 1)',
        { c3, id })
    check(type(dupErr) == 'string' and dupErr:find('23505', 1, true) ~= nil, 'the database refuses a second membership',
        tostring(dupErr))
    H.sql('DELETE FROM faction_members WHERE character_id = $1', { c2 })
    H.sql("DELETE FROM factions WHERE id = 'ghostcrew'")

    -- R3a-2: an insert / delete answered with a lost connection: the member row decides
    eq(F.invite(1, 2), true, 'invited again')
    H.sql('INSERT INTO faction_members (character_id, faction_id, rank, name) VALUES ($1, $2, 1, $3)', { c2, id, 'Rook' })
    H.bridge.fail('INSERT INTO "faction_members"', '08006 simulated connection loss')
    eq(F.acceptInvite(2), true, 'a join whose row landed despite the lost answer is a join')
    H.bridge.unfail()
    eq(F.getPlayerFaction(2) and F.getPlayerFaction(2).id, id, 'he is a member')
    H.sql('DELETE FROM faction_members WHERE character_id = $1', { c2 })   -- as if the delete had committed
    H.bridge.fail('DELETE FROM "faction_members"', '08006 simulated connection loss')
    eq(F.kick(1, c2), true, 'a kick whose delete landed despite the lost answer is a kick')
    H.bridge.unfail()
    eq(F.get(id).members[c2], nil, 'memory let him go')
    eq(F.invite(1, 2), true, 'invited once more')
    H.bridge.fail('INSERT INTO "faction_members"', '08006 simulated connection loss')
    eq(errOf(F.acceptInvite(2)), 'save_failed', 'a join whose row did not land is refused')
    H.bridge.unfail()
    eq(F.get(id).members[c2], nil, 'and the reservation was taken back')

    -- R3a-1: renames are AWAITED and the unique index decides — Lua's lower() is ASCII only, Postgres' is not
    stubs.connectPlayer(env, 5, { license = 'license:f5', name = 'Mafioso' })
    local olmId = F.create(5, 'ölmafia', 'OLM')
    check(type(olmId) == 'string', 'a faction with a non-ASCII name is founded')
    eq(errOf(F.update(1, { name = 'Ölmafia' })), 'name_taken', 'the lower(name) index refuses what the ASCII check missed')
    eq(F.get(id).name, 'Los Santos Cabs', 'memory kept the old name')
    eq(env.GlobalState['faction:' .. id].name, 'Los Santos Cabs', 'GlobalState kept it')
    eq(H.scalar('SELECT name FROM factions WHERE id = $1', { id }), 'Los Santos Cabs', 'and so did the row')
    eq(F.update(1, { name = 'x' .. ('ä'):rep(31) .. 'y' }), true, 'a 33-character name is accepted')
    local cut = F.get(id).name
    eq(cut, 'x' .. ('ä'):rep(31), 'it is cut to NameMax CHARACTERS, on a character boundary')
    eq(utf8.len(cut), 32, 'valid UTF-8, 32 characters')
    eq(H.scalar('SELECT name FROM factions WHERE id = $1', { id }), cut, 'the row holds exactly that')
    eq(errOf(F.update(1, { name = 'Bad\255Name' })), 'invalid_name', 'a name that is not UTF-8 is refused')
    eq(F.update(1, { name = 'Los Santos Cabs' }), true, 'renamed back')

    -- R3a-4: a deposit into a faction disbanded while its statement ran is refunded
    Money.set(5, cfg.CostAccount, 1000, 'topup')
    undo = hookQuery(env, 'SET bank = bank', 'after', function() F.disband(5) end)
    eq(errOf(F.deposit(5, 100)), 'no_faction', 'the deposit answers no_faction')
    undo()
    eq(F.get(olmId), nil, 'the faction is gone')
    eq(Money.get(5, cfg.CostAccount), 1000, 'and the depositor got his money back')

    -- removeRank renumbers the member ROWS (absolute ranks, one slice with the ranks patch)
    stubs.connectPlayer(env, 4, { license = 'license:f4', name = 'Ace' })
    local c4 = Player.getInfo(4).charId
    eq(F.invite(1, 2) and F.acceptInvite(2), true, 'Rook joins again')
    eq(F.invite(1, 4) and F.acceptInvite(4), true, 'Ace joins')
    eq(F.setRank(1, c4, 2), true, 'Ace becomes an Officer')
    eq(F.addRank(1, 'Boss', {}), true, 'the owner adds a fourth rank')
    local function ranksOf()
        local out = {}
        for _, row in ipairs(H.sql('SELECT character_id, rank FROM faction_members WHERE faction_id = $1', { id })) do
            out[row.character_id] = row.rank
        end
        return out
    end
    eq(ranksOf()[c1], 4, 'the owner moved up to the new top rank in his row')
    eq(H.scalar('SELECT jsonb_array_length(ranks) FROM factions WHERE id = $1', { id }), 4, 'the ranks column has four')
    eq(F.removeRank(1, 2), true, 'the owner removes rank 2')
    local rows = ranksOf()
    eq(rows[c4], 1, 'a member of the removed rank drops to 1 in his row')
    eq(rows[c2], 1, 'a rank-1 member stays at 1')
    eq(rows[c1], 3, 'the owner follows the top rank down')
    eq(H.scalar('SELECT jsonb_array_length(ranks) FROM factions WHERE id = $1', { id }), 3, 'three ranks are stored')
    eq(H.scalar("SELECT ranks -> 1 ->> 'name' FROM factions WHERE id = $1", { id }), 'Leader', 'the ranks above moved down')
    eq(F.get(id).members[c4].rank, 1, 'memory agrees with the rows')
    eq(env.Player(4).state.faction.rankName, 'Member', 'the renumbered member re-replicated')

    -- R3a-1: a queued faction write the database drops is read back: a dropped owner patch must not leave the
    -- transfer in memory while the member ranks of the same slice landed
    H.bridge.fail('UPDATE "factions" AS', 'XX000 simulated constraint failure')
    eq(F.setOwner(1, c4), true, 'the transfer is queued')
    H.bridge.unfail()
    eq(F.get(id).ownerCharId, c4, 'memory showed the new owner until the drop was reported')
    stubs.tick(10)
    eq(F.get(id).ownerCharId, c1, 'the re-read restored the owner the row still holds')
    eq(F.getPlayerFaction(1).isOwner, true, 'Boss leads again')
    eq(F.getPlayerFaction(4).isOwner, false, 'Ace does not')
    eq(F.get(id).members[c4].rank, ranksOf()[c4], 'the member ranks follow the rows that landed')
    eq(F.setRank(1, c4, 1), true, 'Ace goes back to rank 1')

    -- R3a-10: reconcile writes the state bag only when it differs
    local bag = env.Player(4).state
    local realSet, writes = bag.set, 0
    bag.set = function(self, key, ...)
        if key == 'faction' then writes = writes + 1 end
        return realSet(self, key, ...)
    end
    Core.emitHook('playerLoaded', 4)
    eq(writes, 0, 'a reconcile with nothing changed writes no state bag')
    bag.set = realSet
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error')

    -- restart: a new core VM loads factions + members; a session derives data.faction from faction_members
    stubs.triggerOn(env, 'onResourceStop', 0, 'core')
    local env2, Core2 = newServer()
    local F2, P2 = Core2.Factions, Core2.Player
    local reloaded = F2.get(id)
    eq(reloaded and reloaded.name, 'Los Santos Cabs', 'the faction came back')
    eq(reloaded and reloaded.ownerCharId, c1, 'with its owner')
    eq(reloaded and #reloaded.ranks, 3, 'its ranks')
    eq(reloaded and reloaded.members[c4] and reloaded.members[c4].rank, 1, 'its members and their ranks')
    eq(reloaded and reloaded.members[c4] and reloaded.members[c4].name, 'Ace', 'the member display name')
    eq(F2.getBank(id), 600, 'and its bank')
    eq(#F2.list(), 2, 'both factions are listed')
    eq(env2.GlobalState['faction:' .. id] and env2.GlobalState['faction:' .. id].memberCount, 3,
        'the load republished GlobalState')
    stubs.connectPlayer(env2, 4, { license = 'license:f4', name = 'Ace' })
    stubs.connectPlayer(env2, 1, { license = 'license:f1', name = 'Boss' })
    local ref = P2.getData(4, 'faction')
    eq(type(ref) == 'table' and ref.id, id, 'the session derived data.faction from faction_members')
    eq(type(ref) == 'table' and ref.rank, 1, '... with the rank')
    eq(env2.Player(4).state.faction and env2.Player(4).state.faction.tag, 'LSC', 'the state bag was refreshed on load')
    eq(F2.getPlayerFaction(1).isOwner, true, 'the owner is recognised again')

    -- disband removes the faction row; the member rows go with it (ON DELETE CASCADE)
    eq(F2.disband(1), true, 'the owner disbands')
    eq(H.scalar('SELECT count(*) FROM factions WHERE id = $1', { id }), 0, 'the faction row is gone')
    eq(H.scalar('SELECT count(*) FROM faction_members WHERE faction_id = $1', { id }), 0, 'its member rows cascaded')
    eq(P2.getData(4, 'faction'), false, 'an online member lost data.faction')
    eq(env2.Player(4).state.faction, false, '... and his state bag says false')
    eq(env2.GlobalState['faction:' .. id], false, 'the GlobalState entry was cleared')
    eq(F2.get(id), nil, 'memory forgot it')

    -- a failed load is retried and never looks like "no factions"
    stubs.triggerOn(env2, 'onResourceStop', 0, 'core')
    H.bridge.fail('FROM factions f', 'XX000 simulated read failure')
    local env3, Core3 = newServer()
    -- an existing character (each VM's uuid sequence starts alike: a NEW account would collide with the first one)
    stubs.connectPlayer(env3, 2, { license = 'license:f2', name = 'Rook' })
    stubs.connectPlayer(env3, 3, { license = 'license:f3', name = 'Rival' })
    local early = Core3.Player.getData(3, 'faction')
    eq(type(early) == 'table' and early.rank, 3, 'a session loads its membership from faction_members, factions or not')
    eq(Core3.Factions.getPlayerFaction(3), nil, 'but no summary exists before the factions are in')
    eq(#Core3.Factions.list(), 0, 'nothing is listed while the load fails')
    eq(errOf(Core3.Factions.create(2, 'Late Crew', 'LATE')), 'unavailable', 'mutations are refused, not run on empty memory')
    check(printed('could not load the factions') ~= nil, 'the failed load is logged')
    H.bridge.unfail()
    stubs.tick(1100)
    eq(#Core3.Factions.list(), 1, 'the retry loaded the remaining faction')
    eq(Core3.Factions.getPlayerFaction(2), nil, 'a player without membership is in no faction')
    eq(env3.Player(2).state.faction, false, 'the reconcile after the load wrote his state bag')
    eq(env3.Player(3).state.faction and env3.Player(3).state.faction.tag, 'VGS',
        'a session that loaded before the factions got its state bag once they were in')
    eq(Core3.Factions.getPlayerFaction(3).isOwner, true, 'and its summary')
    eq(#stubs.failures, 0, 'nothing escaped as an uncaught error (restarts)')
end

    return suiteFactions
end
