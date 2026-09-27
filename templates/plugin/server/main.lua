-- my_plugin — server entry point.
--
-- Never trust the client: every net handler goes through Core.Net.on, which validates the
-- payload against the schema and applies cooldown / requireLoaded / permission / distance
-- before your handler runs, with a trusted `src` as the first argument (DESIGN.md §3.6, §5).
-- Net handlers, callbacks and commands are in-VM registrations — file scope, not Core.onReady.

-- Persist through your own tables, never your own files or a second database (DESIGN.md §56.9).
-- Registered here (this resource's first server file), at file scope — Core.DB.migrate never yields, so it
-- is safe this early. Delete sql/0001_init.sql and this call if the plugin has nothing to persist.
local migrated, migrateErr = Core.DB.migrate({ 'sql/0001_init.sql' })
if not migrated then
    Core.Log.error('my_plugin: the migrations could not be registered: %s', tostring(migrateErr))
end

-- Core.Net.on('my_plugin:server:doThing', { 'integer' }, function(src, price)
--     if price ~= Config.Price then return end                       -- client-sent values are hints only
--     if not Core.Money.remove(src, 'cash', price, 'my_plugin') then
--         return Core.Notify.send(src, 'Not enough money', 'error')
--     end
--
--     Core.Notify.send(src, 'Thanks!', 'success')
--     Core.Net.emit(src, 'my_plugin:client:done', price)
-- end, {
--     cooldown = 1000,                                               -- ms per player
--     requireLoaded = true,                                          -- session must exist
--     distance = { coords = Config.Shop.coords, max = 4.0 },         -- must stand at the spot
-- })
