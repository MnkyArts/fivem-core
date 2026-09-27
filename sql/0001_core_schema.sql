-- core/sql/0001_core_schema.sql — core's relational schema (DESIGN §56.6).
-- Applied once by core_db's migration runner (owner 'core', version 1). IMMUTABLE once applied anywhere:
-- change the schema with a new numbered file, never by editing this one (§56.4.3).
--
-- Conventions: text ids (the Lua side mints 32-hex uuids), timestamptz for times (Lua sees Unix seconds),
-- jsonb for aggregates loaded and saved as a unit, real columns for everything filtered/joined/constrained.
-- Every FK between tables the write-behind queue touches is DEFERRABLE INITIALLY DEFERRED (§56.3.3).

-- updated_at maintenance: set now() on every UPDATE unless the statement set updated_at itself.
CREATE OR REPLACE FUNCTION core_touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.updated_at IS NOT DISTINCT FROM OLD.updated_at THEN
        NEW.updated_at := now();
    END IF;
    RETURN NEW;
END
$$;

-- pg_trgm is a trusted extension (PG 13+): a database owner may create it. The audit search index below
-- is only built when it is available; searches still work without it (sequential ILIKE on the filtered set).
DO $$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_trgm;
EXCEPTION WHEN insufficient_privilege OR feature_not_supported OR undefined_file THEN
    RAISE NOTICE 'core: pg_trgm is not available (%), audit text search runs without an index', SQLERRM;
END
$$;

-- == counters (Core.DB.nextId, scene node ids, map ids) ===================================================
CREATE TABLE core_counters (
    name  text   PRIMARY KEY,
    value bigint NOT NULL DEFAULT 0
);

-- == accounts: one per license =============================================================================
CREATE TABLE accounts (
    id               text        PRIMARY KEY,
    license          text        NOT NULL,
    name             text        NOT NULL DEFAULT '',
    perm_group       text        NOT NULL DEFAULT 'user',
    first_seen       timestamptz NOT NULL DEFAULT now(),
    last_seen        timestamptz NOT NULL DEFAULT now(),
    playtime         integer     NOT NULL DEFAULT 0 CHECK (playtime >= 0),       -- seconds
    banned           boolean     NOT NULL DEFAULT false,                          -- has an active ban naming it
    permissions      text[]      NOT NULL DEFAULT '{}',                           -- permanent grants
    temp_permissions jsonb       NOT NULL DEFAULT '{}',                           -- { perm = expiresAt (s) }
    data             jsonb       NOT NULL DEFAULT '{}',                           -- plugin keys (setAccountData)
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT accounts_license_key UNIQUE (license)
);
CREATE INDEX accounts_perm_group_idx ON accounts (perm_group) WHERE perm_group <> 'user';
CREATE INDEX accounts_permissions_idx ON accounts USING gin (permissions) WHERE permissions <> '{}';
CREATE TRIGGER accounts_touch BEFORE UPDATE ON accounts FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

-- the latest identifier of every kind an account connected with (license, license2, discord, fivem, steam,
-- xbl, live — never ip); replaces the in-memory identifier index of getters.lua (§47, §49)
CREATE TABLE account_identifiers (
    account_id text        NOT NULL REFERENCES accounts (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    kind       text        NOT NULL,
    identifier text        NOT NULL,                                               -- full 'kind:value'
    last_seen  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (account_id, kind)
);
CREATE INDEX account_identifiers_identifier_idx ON account_identifiers (identifier);

-- == characters =============================================================================================
CREATE TABLE characters (
    id               text        PRIMARY KEY,
    account_id       text        NOT NULL REFERENCES accounts (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    name             text        NOT NULL DEFAULT '',
    model            text        NOT NULL DEFAULT 'mp_m_freemode_01',
    appearance       jsonb       NOT NULL DEFAULT '{}',
    position         jsonb,                                                        -- { x, y, z, heading }
    stats            jsonb       NOT NULL DEFAULT '{}',                           -- deaths, playtime, needs, plugin stats
    weapons          jsonb       NOT NULL DEFAULT '{}',
    attachments      jsonb       NOT NULL DEFAULT '[]',
    meta             jsonb       NOT NULL DEFAULT '{}',
    permissions      text[]      NOT NULL DEFAULT '{}',
    temp_permissions jsonb       NOT NULL DEFAULT '{}',
    data             jsonb       NOT NULL DEFAULT '{}',                           -- plugin top-level keys (Player.setData)
    last_played      timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX characters_account_idx ON characters (account_id);
CREATE TRIGGER characters_touch BEFORE UPDATE ON characters FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

-- one row per money account of Config.Money.Accounts (cash, bank, ...)
CREATE TABLE character_money (
    character_id text   NOT NULL REFERENCES characters (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    account      text   NOT NULL,
    balance      bigint NOT NULL DEFAULT 0 CHECK (balance >= 0),
    PRIMARY KEY (character_id, account)
);

-- == permission groups (§44) ================================================================================
CREATE TABLE perm_groups (
    name       text        PRIMARY KEY,
    label      text        NOT NULL DEFAULT '',
    weight     integer     NOT NULL DEFAULT 0,
    inherits   text[]      NOT NULL DEFAULT '{}',
    perms      text[]      NOT NULL DEFAULT '{}',
    removed    text[]      NOT NULL DEFAULT '{}',                                 -- perms an owner took out
    color      text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER perm_groups_touch BEFORE UPDATE ON perm_groups FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

-- == bans (§47) ==============================================================================================
CREATE SEQUENCE ban_number_seq;

CREATE TABLE bans (
    id                    text        PRIMARY KEY DEFAULT ('B' || nextval('ban_number_seq')),
    account_id            text        REFERENCES accounts (id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    name                  text        NOT NULL DEFAULT 'unknown',
    reason                text        NOT NULL DEFAULT 'No reason given',
    evidence              text,
    by_account_id         text,                                                   -- soft: history outlives accounts
    by_name               text        NOT NULL DEFAULT 'console',
    expires_at            timestamptz,                                            -- NULL = permanent
    revoked_at            timestamptz,
    revoked_by_account_id text,
    revoked_by_name       text,
    revoke_reason         text,
    hits                  integer     NOT NULL DEFAULT 0,
    last_hit_at           timestamptz,
    relink                text,                                                   -- a license still to link (§47)
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX bans_account_idx ON bans (account_id) WHERE account_id IS NOT NULL;
CREATE INDEX bans_active_idx  ON bans (expires_at) WHERE revoked_at IS NULL;
CREATE INDEX bans_list_idx    ON bans (created_at DESC, id DESC);
CREATE INDEX bans_relink_idx  ON bans (relink) WHERE relink IS NOT NULL;
CREATE TRIGGER bans_touch BEFORE UPDATE ON bans FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

-- every account that held a banned identifier when the ban was added (§47 accountIds), explicit one first
CREATE TABLE ban_accounts (
    ban_id     text     NOT NULL REFERENCES bans (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    account_id text     NOT NULL REFERENCES accounts (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    position   smallint NOT NULL DEFAULT 0,
    PRIMARY KEY (ban_id, account_id)
);
CREATE INDEX ban_accounts_account_idx ON ban_accounts (account_id);

CREATE TABLE ban_identifiers (
    ban_id     text NOT NULL REFERENCES bans (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    identifier text NOT NULL,
    PRIMARY KEY (ban_id, identifier)
);
CREATE INDEX ban_identifiers_identifier_idx ON ban_identifiers (identifier);

CREATE TABLE ban_tokens (
    ban_id text NOT NULL REFERENCES bans (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    token  text NOT NULL,
    PRIMARY KEY (ban_id, token)
);
CREATE INDEX ban_tokens_token_idx ON ban_tokens (token);

-- == audit trail (§46) =======================================================================================
-- append-only through the queue (Core.DB.append); pruned by Core.Audit per pool (main/log/exempt)
CREATE TABLE audit_log (
    id               bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    at               timestamptz NOT NULL DEFAULT now(),
    pool             text        NOT NULL DEFAULT 'main' CHECK (pool IN ('main', 'log', 'exempt')),
    action           text        NOT NULL,
    source           text,
    resource         text,
    result           text        NOT NULL DEFAULT 'ok',
    actor            jsonb       NOT NULL DEFAULT '{}',                           -- { kind, src?, accountId?, name?, group? }
    actor_account_id text,
    targets          jsonb,                                                        -- [ { type, id, name?, accountId? } ]
    target_keys      text[]      NOT NULL DEFAULT '{}',                           -- 'type:id' and 'account:<id>'
    changes          jsonb,
    reason           text,
    ctx              jsonb,
    message          text,
    search           text        NOT NULL DEFAULT ''                              -- lower-cased haystack (≤ 640)
);
CREATE INDEX audit_log_pool_idx    ON audit_log (pool, id);
CREATE INDEX audit_log_at_idx      ON audit_log USING brin (at);
CREATE INDEX audit_log_action_idx  ON audit_log (action, id DESC);
CREATE INDEX audit_log_actor_idx   ON audit_log (actor_account_id, id DESC) WHERE actor_account_id IS NOT NULL;
CREATE INDEX audit_log_targets_idx ON audit_log USING gin (target_keys);
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm') THEN
        CREATE INDEX audit_log_search_idx ON audit_log USING gin (search gin_trgm_ops);
    END IF;
END
$$;

-- == settings (§45), globals (§22), world state (§17) ========================================================
CREATE TABLE settings (
    key        text        PRIMARY KEY,                                            -- the dotted key
    value      jsonb       NOT NULL,
    updated_by jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER settings_touch BEFORE UPDATE ON settings FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

CREATE TABLE globals (
    key        text        PRIMARY KEY,
    value      jsonb       NOT NULL,
    mirror     boolean     NOT NULL DEFAULT false,                                -- published as GlobalState['g:<key>']
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER globals_touch BEFORE UPDATE ON globals FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

CREATE TABLE world_state (
    id                 smallint    PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    day_seconds        integer     NOT NULL DEFAULT 43200,
    weather            text        NOT NULL DEFAULT 'CLEAR',
    frozen             boolean     NOT NULL DEFAULT false,
    cycle_index        integer     NOT NULL DEFAULT 1,
    cycle_minutes_left integer     NOT NULL DEFAULT 0,
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER world_state_touch BEFORE UPDATE ON world_state FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

-- == doors (§16) ==============================================================================================
CREATE TABLE doors (
    id           text        PRIMARY KEY,
    model        bigint      NOT NULL,
    coords       jsonb       NOT NULL,                                             -- { x, y, z }
    locked       boolean     NOT NULL DEFAULT true,
    perms        text[]      NOT NULL DEFAULT '{}',
    auto_lock_ms integer,
    meta         jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER doors_touch BEFORE UPDATE ON doors FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

-- == factions (§4.5): membership is a table, one faction per character ======================================
CREATE TABLE factions (
    id                 text        PRIMARY KEY,
    name               text        NOT NULL,
    tag                text        NOT NULL,
    color              text        NOT NULL DEFAULT '#ffffff',
    owner_character_id text        REFERENCES characters (id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    ranks              jsonb       NOT NULL DEFAULT '[]',                         -- [ { name, perms = { perm = true } } ], index = rank
    bank               bigint      NOT NULL DEFAULT 0 CHECK (bank >= 0),
    meta               jsonb       NOT NULL DEFAULT '{}',
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX factions_name_key ON factions (lower(name));
CREATE UNIQUE INDEX factions_tag_key  ON factions (upper(tag));
CREATE TRIGGER factions_touch BEFORE UPDATE ON factions FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

CREATE TABLE faction_members (
    character_id text        PRIMARY KEY REFERENCES characters (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    faction_id   text        NOT NULL REFERENCES factions (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    rank         smallint    NOT NULL DEFAULT 1 CHECK (rank >= 1),
    name         text        NOT NULL DEFAULT '',                                 -- display name at join
    joined_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX faction_members_faction_idx ON faction_members (faction_id);

-- == vehicles (§4.6) =========================================================================================
CREATE TABLE vehicles (
    id                 text        PRIMARY KEY,
    owner_character_id text        REFERENCES characters (id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
    model              bigint      NOT NULL,                                       -- joaat hash as the game gives it
    model_name         text,
    plate              text        NOT NULL,
    props              jsonb       NOT NULL DEFAULT '{}',
    stored             boolean     NOT NULL DEFAULT true,                          -- garaged
    destroyed          boolean     NOT NULL DEFAULT false,
    parked             integer,                                                    -- scene node id (soft: nodes flush separately)
    locked             boolean,
    keys               text[]      NOT NULL DEFAULT '{}',                          -- character ids holding a key
    position           jsonb,                                                      -- { x, y, z, heading, bucket? }
    meta               jsonb       NOT NULL DEFAULT '{}',
    last_used_at       timestamptz NOT NULL DEFAULT now(),                         -- MaxParked LRU order (§4.6)
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT vehicles_plate_key UNIQUE (plate)
);
CREATE INDEX vehicles_owner_idx ON vehicles (owner_character_id) WHERE owner_character_id IS NOT NULL;
CREATE INDEX vehicles_world_idx ON vehicles (last_used_at, id) WHERE stored = false OR parked IS NOT NULL;
CREATE INDEX vehicles_keys_idx  ON vehicles USING gin (keys) WHERE keys <> '{}';
CREATE TRIGGER vehicles_touch BEFORE UPDATE ON vehicles FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

-- == scene nodes (§55.18): persistent nodes only =============================================================
CREATE TABLE scene_nodes (
    id         integer     PRIMARY KEY,
    kind       text        NOT NULL,
    owner      text        NOT NULL,                                               -- resource name
    parent     integer,                                                            -- soft: parents flush in the same pass
    bucket     integer     NOT NULL DEFAULT 0,
    doc        jsonb       NOT NULL,                                               -- the rest of scene_store's docOf()
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX scene_nodes_owner_idx ON scene_nodes (owner, kind);
CREATE TRIGGER scene_nodes_touch BEFORE UPDATE ON scene_nodes FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

-- == maps (§52) ===============================================================================================
CREATE TABLE maps (
    id                text        PRIMARY KEY,
    name              text        NOT NULL,
    mode              text        NOT NULL DEFAULT 'draft' CHECK (mode IN ('draft', 'live')),
    active            boolean     NOT NULL DEFAULT false,
    target_bucket     integer     NOT NULL DEFAULT 0,
    published_version integer     NOT NULL DEFAULT 0,
    published_seq     integer     NOT NULL DEFAULT 0,
    next_element_id   integer     NOT NULL DEFAULT 1,
    journal_seq       integer     NOT NULL DEFAULT 0,
    meta              jsonb       NOT NULL DEFAULT '{}',
    limits            jsonb,
    expires_at        timestamptz,
    created_by        jsonb,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER maps_touch BEFORE UPDATE ON maps FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

CREATE TABLE map_elements (
    map_id       text        NOT NULL REFERENCES maps (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    element_id   integer     NOT NULL,
    type         text        NOT NULL,
    type_version integer     NOT NULL DEFAULT 1,
    pos          jsonb       NOT NULL,
    rot          jsonb       NOT NULL,
    fields       jsonb       NOT NULL DEFAULT '{}',
    layer        text,
    cam          jsonb,
    author       text,                                                             -- accountId | 'console' | 'system' | 'src:<n>'
    rev          bigint      NOT NULL DEFAULT 0,                                   -- ms stamp, strictly increasing (§52)
    info         jsonb,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (map_id, element_id)
);
CREATE TRIGGER map_elements_touch BEFORE UPDATE ON map_elements FOR EACH ROW EXECUTE FUNCTION core_touch_updated_at();

-- published snapshots; the start-up load reads the metadata columns only, never `elements`
CREATE TABLE map_versions (
    map_id       text        NOT NULL REFERENCES maps (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    version      integer     NOT NULL,
    elements     jsonb       NOT NULL DEFAULT '[]',
    count        integer     NOT NULL DEFAULT 0,
    author       text,
    author_name  text,
    note         text,
    from_version integer,
    at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (map_id, version)
);

-- the edit journal; the start-up load reads (map_id, seq, at, author, w) only, never `ops`/`ids`
CREATE TABLE map_journal (
    map_id text        NOT NULL REFERENCES maps (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    seq    integer     NOT NULL,
    at     timestamptz NOT NULL DEFAULT now(),
    author text,
    source text,
    actor  jsonb,
    count  integer     NOT NULL DEFAULT 0,
    w      integer     NOT NULL DEFAULT 1,                                         -- prune weight
    clear  boolean     NOT NULL DEFAULT false,
    ops    jsonb,
    ids    jsonb,
    PRIMARY KEY (map_id, seq)
);
CREATE INDEX map_journal_author_idx ON map_journal (map_id, author, seq DESC);
