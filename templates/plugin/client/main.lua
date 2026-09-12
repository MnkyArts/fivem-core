-- my_plugin — client entry point.
--
-- In-VM registrations (keys, net handlers, callbacks, commands) stay at file scope; anything
-- that registers INTO core (markers, text labels, blips, interactions, UI pages) goes inside
-- Core.onReady, which also runs again after every core restart (DESIGN.md §2.4).
-- Core cleans up everything this resource registered when it stops — no manual teardown.

Core.onReady(function()
    -- A marker drawn by core's single draw loop while you are within drawDistance (§6.4):
    -- Core.Markers.add({
    --     coords = Config.Shop.coords,
    --     type = 1,
    --     color = { 91, 140, 255, 120 },
    --     drawDistance = 30.0,
    -- })

    -- An interaction: core shows the `[E] label` text UI in range and calls onInteract on E (§6.7).
    -- Pass `marker = { type = 1, ... }` instead of the block above to let it manage its own marker.
    -- Core.Interactions.add({
    --     coords = Config.Shop.coords,
    --     radius = Config.Shop.radius,
    --     label = 'Buy something ($5)',
    --     onInteract = function(ctx)
    --         if Core.UI.progress({ label = 'Buying...', duration = 2000, canCancel = true }) then
    --             Core.Net.emit('my_plugin:server:doThing', Config.Price)
    --         end
    --     end,
    -- })

    -- The Vue page in ui/src, compiled into core's shell (§7.4) — no script/style paths,
    -- core already has the component. Open it with Core.UI.open('my_plugin', { ... }) and
    -- receive its events with Core.UI.on('my_plugin', 'greet', function(data) end).
    -- Core.UI.registerPage('my_plugin', { type = 'page' })
end)
