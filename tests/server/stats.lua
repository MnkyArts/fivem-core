return function(H)
    local check, eq, newServer, stubs, suite =
        H.check, H.eq, H.newServer, H.stubs, H.suite

--- First upvalue of `fn` called `name`, or nil.
local function upvalue(fn, name)
    if type(fn) ~= 'function' then return nil end
    for i = 1, 64 do
        local key, value = debug.getupvalue(fn, i)
        if not key then return nil end
        if key == name then return value end
    end
    return nil
end

--- Core.Stats definition normalisation (DESIGN §18, §39.5): where a stat's bar goes and which
--- glyph sits under it. server/stats.lua is loaded on top of the standard VM — it is not in
--- SERVER_FILES, so the other suites keep running without a Core.Stats namespace.
--- Nothing in the public API reports a def's `hud`/`icon` back, and the normalisation is a
--- contract all the same, so the suite reaches the private table the only way left:
--- Stats.define -> the `registerDef` upvalue -> its `defs` upvalue. It fails loudly if that chain
--- is renamed, which is exactly when these checks want re-reading anyway.
local function suiteStats()
    suite('stats')
    stubs.resetServer()
    local env, Core = newServer()
    stubs.loadFile(env, 'server/stats.lua')
    local Stats = Core.Stats
    check(type(Stats) == 'table', 'server/stats.lua installed Core.Stats')
    local defs = upvalue(upvalue(Stats.define, 'registerDef'), 'defs')
    if not check(type(defs) == 'table', 'the suite can read the normalised definitions') then return end

    -- the shipped config went through normalizeDef at load (§39.5 defaults)
    eq(defs.hunger and defs.hunger.hud, 'health', "config's hunger keeps hud = 'health'")
    eq(defs.hunger and defs.hunger.icon, 'hud-food', 'and its icon')
    eq(defs.thirst and defs.thirst.hud, 'armour', "config's thirst keeps hud = 'armour'")
    eq(defs.thirst and defs.thirst.icon, 'hud-drink', 'and its icon')

    eq(Stats.define('stress', { min = 0, max = 100, hud = 'armour', icon = 'hud-drink' }), true,
        'a slotted def registers')
    eq(defs.stress.hud, 'armour', "hud = 'armour' survives normalisation")
    eq(defs.stress.icon, 'hud-drink', 'so does a string icon')
    eq(Stats.define('energy', { min = 0, max = 100, hud = true }), true, 'a rail-bar def registers')
    eq(defs.energy.hud, true, 'hud = true still means a bar on the rail plate')
    eq(defs.energy.icon, nil, 'a def without an icon stores none')
    eq(Stats.define('mood', { min = 0, max = 100, hud = 'nonsense' }), true,
        'an unknown slot still defines the stat')
    eq(defs.mood.hud, false, "... but 'nonsense' is no slot the shell can draw: no bar at all")
    eq(Stats.define('focus', { min = 0, max = 100, hud = 'health', icon = 42 }), true,
        'a non-string icon does not stop the def')
    eq(defs.focus.hud, 'health', 'the slot is kept')
    eq(defs.focus.icon, nil, 'the number icon is dropped')
    eq(Stats.define('calm', { min = 0, max = 100 }), true, 'a def with no hud key registers')
    eq(defs.calm.hud, false, 'and asks for no bar')
    eq(Stats.define('grit', { min = 0, max = 100, hud = false, icon = 'hud-food' }), true,
        'hud = false is explicit')
    eq(defs.grit.hud, false, 'and stays false')
end

    return suiteStats
end
