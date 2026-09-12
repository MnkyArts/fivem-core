-- my_plugin configuration. Loaded in both VMs (shared_scripts), so client and server read
-- the same numbers. `Config` is a deliberate global inside this resource, exactly like core's
-- own config (DESIGN.md §1, §10); everything else in your files stays `local`.

Config = {
    Debug = false,

    -- Example: the spot the client registers a marker/interaction on and the server checks
    -- the caller's distance against (DESIGN.md §3.6 `distance` option).
    -- Shop = { coords = vector3(25.7, -1347.3, 29.49), radius = 2.0 },
    -- Price = 5,
}
