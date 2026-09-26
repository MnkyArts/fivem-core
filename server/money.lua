--[[
    core/server/money.lua — Core.Money (DESIGN §4.3)

    Integer balances on the accounts listed in Config.Money.Accounts (cash, bank), stored on the
    character document through Core.Player.setData('money', ...) so the §8 state-bag keys cash/bank
    re-replicate on every change. Every successful change is audited and emits the moneyChanged hook.

    Server side only; no natives are used in this file.
]]

local Money = {}
local transferring = false

local Log = Core.Log
local Utils = Core.Utils

--- True for a configured account key.
local function isAccount(account)
    return type(account) == 'string' and Config.Money.Accounts[account] ~= nil
end

--- True for a positive, whole, in-range amount (add/remove/transfer).
local function isPositiveAmount(amount)
    return math.type(amount) == 'integer' and amount > 0 and amount <= Config.Money.MaxAmount
end

--- Reads the player's money table (a copy), normalised to in-range integers. nil without a session.
local function readMoney(src)
    local player = Core.Player
    if not player or not player.isLoaded(src) then return nil end
    local money = player.getData(src, 'money')
    if type(money) ~= 'table' then money = {} end
    for account in pairs(Config.Money.Accounts) do
        local value = money[account]
        value = math.type(value) == 'integer' and value or math.floor(tonumber(value) or 0)
        if value < 0 then value = 0 end
        if value > Config.Money.MaxAmount then value = Config.Money.MaxAmount end
        money[account] = value
    end
    return money
end

--- Persists the new money table, audits the change and fires the moneyChanged hook.
local function commit(src, money, account, newAmount, delta, reason)
    local text = Utils.sanitize(reason or 'unknown', 64)
    if not Core.Player.setData(src, 'money', money) then return false end
    Log.audit('money', src, '%s %s%d -> %d (%s)', account, delta >= 0 and '+' or '', delta, newAmount, text)
    Core.emitHook('moneyChanged', src, account, newAmount, delta, text)
    return true
end

function Money.get(src, account)
    if not isAccount(account) then return 0 end
    local money = readMoney(src)
    if not money then return 0 end
    return money[account] or 0
end

function Money.canAfford(src, account, amount)
    if not isAccount(account) or math.type(amount) ~= 'integer' or amount < 0 then return false end
    return Money.get(src, account) >= amount
end

function Money.add(src, account, amount, reason)
    if not isAccount(account) or not isPositiveAmount(amount) then return false end
    local money = readMoney(src)
    if not money then return false end
    local newAmount = (money[account] or 0) + amount
    if newAmount > Config.Money.MaxAmount then return false end
    money[account] = newAmount
    return commit(src, money, account, newAmount, amount, reason)
end

function Money.remove(src, account, amount, reason)
    if not isAccount(account) or not isPositiveAmount(amount) then return false end
    local money = readMoney(src)
    if not money then return false end
    local current = money[account] or 0
    if current < amount then return false end
    local newAmount = current - amount
    money[account] = newAmount
    return commit(src, money, account, newAmount, -amount, reason)
end

function Money.set(src, account, amount, reason)
    if not isAccount(account) then return false end
    if math.type(amount) ~= 'integer' or amount < 0 or amount > Config.Money.MaxAmount then return false end
    local money = readMoney(src)
    if not money then return false end
    local delta = amount - (money[account] or 0)
    money[account] = amount
    return commit(src, money, account, amount, delta, reason or 'set')
end

local function transfer(fromSrc, toSrc, account, amount, reason)
    if fromSrc == toSrc then return false end
    if not isAccount(account) or not isPositiveAmount(amount) then return false end
    local player = Core.Player
    if not player or not player.isLoaded(fromSrc) or not player.isLoaded(toSrc) then return false end

    local text = Utils.sanitize(reason or 'transfer', 64)
    if Money.get(fromSrc, account) < amount
        or Money.get(toSrc, account) > Config.Money.MaxAmount - amount then return false end
    local allowed = Core.Hooks.run('money:beforeTransfer', {
        from = fromSrc, to = toSrc, account = account, amount = amount, reason = text,
    })
    if not allowed then return false end
    -- Callbacks may change sessions or balances through other APIs; validate them again.
    if not player.isLoaded(fromSrc) or not player.isLoaded(toSrc)
        or Money.get(toSrc, account) > Config.Money.MaxAmount - amount then return false end
    if not Money.remove(fromSrc, account, amount, text) then return false end
    if not Money.add(toSrc, account, amount, text) then
        -- roll back: the receiver could not take it (cap or a session that just went away)
        Money.add(fromSrc, account, amount, 'transfer rollback')
        return false
    end
    return true
end

function Money.transfer(fromSrc, toSrc, account, amount, reason)
    if transferring then return false end
    transferring = true
    local ok, result = pcall(transfer, fromSrc, toSrc, account, amount, reason)
    transferring = false
    if not ok then return false end
    return result
end

Core.Money = Money
