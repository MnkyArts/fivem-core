-- my_plugin/sql/0001_init.sql — this plugin's own table (core DESIGN §56.9).
-- Registered by Core.DB.migrate({ 'sql/0001_init.sql' }) at file scope in server/main.lua. Owner 'my_plugin',
-- version 1. IMMUTABLE once applied anywhere: change the schema with a NEW numbered file, never by editing
-- this one (core DESIGN §56.4.3) — copy this file to 0002_*.sql and ALTER instead.
--
-- core registers its own migrations before any plugin starts, so core_touch_updated_at() already exists here.

-- A tiny example row per character; replace `my_plugin_things` and `data` with your own shape.
CREATE TABLE my_plugin_things (
    id           text        PRIMARY KEY,
    character_id text        NOT NULL REFERENCES characters (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    data         jsonb       NOT NULL DEFAULT '{}',
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX my_plugin_things_character_idx ON my_plugin_things (character_id);

CREATE TRIGGER my_plugin_things_touch BEFORE UPDATE ON my_plugin_things
    FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();
