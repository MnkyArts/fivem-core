-- core/sql/0002_core_legacy_import.sql — copy core's collections out of the old document table (DESIGN §56.7).
-- Owner 'core', version 2. A fresh install has no `core_documents`: the DO block returns at once.
-- Otherwise every core collection is copied into the tables of 0001, rows whose parents are missing are
-- skipped (and counted in a NOTICE), and `core_documents` is renamed to `legacy_documents`, which nothing
-- writes again. Plugin collections stay there for the plugins' own first migrations.
--
-- The old documents came from Lua through json.encode: an empty map was stored as [] and integer-keyed maps
-- as objects with digit keys, so every read below goes through a tolerant helper.

-- == helpers (dropped at the end of this migration) =========================================================
CREATE FUNCTION core_legacy_int(v jsonb, fallback bigint) RETURNS bigint LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN jsonb_typeof(v) = 'number' THEN floor((v #>> '{}')::numeric)::bigint
        WHEN jsonb_typeof(v) = 'string' AND (v #>> '{}') ~ '^-?[0-9]{1,18}(\.[0-9]+)?$' THEN floor((v #>> '{}')::numeric)::bigint
        ELSE fallback
    END
$$;

-- Unix seconds (number or digit string) -> timestamptz; anything else -> fallback
CREATE FUNCTION core_legacy_ts(v jsonb, fallback timestamptz DEFAULT now()) RETURNS timestamptz LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN core_legacy_int(v, 0) > 0 THEN to_timestamp(core_legacy_int(v, 0))
        ELSE fallback
    END
$$;

CREATE FUNCTION core_legacy_bool(v jsonb, fallback boolean) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(v) = 'boolean' THEN (v #>> '{}')::boolean ELSE fallback END
$$;

-- an object, or {} for anything else ([] was an empty Lua map)
CREATE FUNCTION core_legacy_obj(v jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN jsonb_typeof(v) = 'object' THEN v ELSE '{}'::jsonb END
$$;

-- an array; an object with digit keys becomes an array in key order; anything else -> []
CREATE FUNCTION core_legacy_list(v jsonb) RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE jsonb_typeof(v)
        WHEN 'array' THEN v
        WHEN 'object' THEN COALESCE((SELECT jsonb_agg(e.value ORDER BY e.key::int)
                                     FROM jsonb_each(v) AS e WHERE e.key ~ '^[0-9]{1,9}$'), '[]'::jsonb)
        ELSE '[]'::jsonb
    END
$$;

-- a list of strings -> text[] (order kept); a set map { x = true } -> its keys
CREATE FUNCTION core_legacy_texts(v jsonb) RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN jsonb_typeof(v) = 'object' AND NOT EXISTS (SELECT 1 FROM jsonb_object_keys(v) AS k WHERE k !~ '^[0-9]{1,9}$')
             AND v <> '{}'::jsonb
            THEN COALESCE((SELECT array_agg(e #>> '{}' ORDER BY o)
                           FROM jsonb_array_elements(core_legacy_list(v)) WITH ORDINALITY AS t(e, o)
                           WHERE jsonb_typeof(e) IN ('string', 'number')), '{}'::text[])
        WHEN jsonb_typeof(v) = 'object'
            THEN COALESCE((SELECT array_agg(e.key ORDER BY e.key) FROM jsonb_each(v) AS e
                           WHERE e.value NOT IN ('false'::jsonb, 'null'::jsonb)), '{}'::text[])
        WHEN jsonb_typeof(v) = 'array'
            THEN COALESCE((SELECT array_agg(e #>> '{}' ORDER BY o) FROM jsonb_array_elements(v) WITH ORDINALITY AS t(e, o)
                           WHERE jsonb_typeof(e) IN ('string', 'number')), '{}'::text[])
        ELSE '{}'::text[]
    END
$$;

DO $$
DECLARE
    n bigint;
    src bigint;
    seq bigint;
BEGIN
    IF to_regclass('core_documents') IS NULL THEN
        RETURN;
    END IF;

    -- accounts (one per license; a duplicated license keeps the most recently seen document) ---------------
    INSERT INTO accounts (id, license, name, perm_group, first_seen, last_seen, playtime, banned, permissions,
                          temp_permissions, data, created_at, updated_at)
    SELECT DISTINCT ON (d.data ->> 'license')
           d.id, d.data ->> 'license', left(COALESCE(d.data ->> 'name', ''), 64),
           COALESCE(NULLIF(d.data ->> 'group', ''), 'user'),
           core_legacy_ts(d.data -> 'firstSeen'), core_legacy_ts(d.data -> 'lastSeen'),
           LEAST(GREATEST(core_legacy_int(d.data -> 'playtime', 0), 0), 2147483647)::int,
           core_legacy_bool(d.data -> 'banned', false),
           core_legacy_texts(d.data -> 'permissions'), core_legacy_obj(d.data -> 'tempPermissions'),
           d.data - ARRAY['id', 'license', 'identifiers', 'name', 'group', 'firstSeen', 'lastSeen', 'playtime',
                          'banned', 'permissions', 'tempPermissions', 'createdAt', 'updatedAt', '_v'],
           core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'accounts' AND d.data ->> 'license' LIKE 'license:_%' AND d.id ~ '^[A-Za-z0-9_:-]{1,64}$'
    ORDER BY d.data ->> 'license', core_legacy_int(d.data -> 'lastSeen', 0) DESC, d.id;
    GET DIAGNOSTICS n = ROW_COUNT;
    SELECT count(*) INTO src FROM core_documents WHERE collection = 'accounts';
    RAISE NOTICE 'core legacy import: accounts % of %', n, src;

    -- identifiers: stored as a map { kind = 'kind:value' } (current) or a list of 'kind:value' (old)
    INSERT INTO account_identifiers (account_id, kind, identifier, last_seen)
    SELECT a.id, split_part(i.value, ':', 1), i.value, a.last_seen
    FROM accounts a
    JOIN core_documents d ON d.collection = 'accounts' AND d.id = a.id
    CROSS JOIN LATERAL (
        SELECT e.value FROM jsonb_each_text(core_legacy_obj(d.data -> 'identifiers')) AS e
        UNION ALL
        SELECT e.value FROM jsonb_array_elements_text(
            CASE WHEN jsonb_typeof(d.data -> 'identifiers') = 'array' THEN d.data -> 'identifiers' ELSE '[]'::jsonb END) AS e(value)
    ) AS i(value)
    WHERE i.value ~ '^[a-z0-9]+:.' AND split_part(i.value, ':', 1) <> 'ip' AND length(i.value) <= 128
    ON CONFLICT (account_id, kind) DO NOTHING;
    INSERT INTO account_identifiers (account_id, kind, identifier, last_seen)
    SELECT id, 'license', license, last_seen FROM accounts
    ON CONFLICT (account_id, kind) DO UPDATE SET identifier = EXCLUDED.identifier;

    -- characters (+ money rows); faction membership comes from factions below ------------------------------
    INSERT INTO characters (id, account_id, name, model, appearance, position, stats, weapons, attachments, meta,
                            permissions, temp_permissions, data, last_played, created_at, updated_at)
    SELECT d.id, d.data ->> 'accountId', left(COALESCE(d.data ->> 'name', ''), 64),
           COALESCE(NULLIF(d.data ->> 'model', ''), 'mp_m_freemode_01'),
           core_legacy_obj(d.data -> 'appearance'),
           CASE WHEN jsonb_typeof(d.data -> 'position') = 'object' THEN d.data -> 'position' END,
           core_legacy_obj(d.data -> 'stats'), core_legacy_obj(d.data -> 'weapons'),
           core_legacy_list(d.data -> 'attachments'), core_legacy_obj(d.data -> 'meta'),
           core_legacy_texts(d.data -> 'permissions'), core_legacy_obj(d.data -> 'tempPermissions'),
           d.data - ARRAY['id', 'accountId', 'name', 'model', 'appearance', 'position', 'stats', 'weapons',
                          'attachments', 'meta', 'permissions', 'tempPermissions', 'money', 'faction',
                          'createdAt', 'updatedAt', '_v'],
           core_legacy_ts(d.data -> 'updatedAt', NULL),
           core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'characters' AND d.id ~ '^[A-Za-z0-9_:-]{1,64}$'
      AND EXISTS (SELECT 1 FROM accounts a WHERE a.id = d.data ->> 'accountId');
    GET DIAGNOSTICS n = ROW_COUNT;
    SELECT count(*) INTO src FROM core_documents WHERE collection = 'characters';
    RAISE NOTICE 'core legacy import: characters % of %', n, src;

    INSERT INTO character_money (character_id, account, balance)
    SELECT c.id, m.key, LEAST(GREATEST(core_legacy_int(m.value, 0), 0), 999999999999)
    FROM characters c
    JOIN core_documents d ON d.collection = 'characters' AND d.id = c.id
    CROSS JOIN LATERAL jsonb_each(core_legacy_obj(d.data -> 'money')) AS m
    WHERE m.key ~ '^[A-Za-z_][A-Za-z0-9_]{0,31}$';

    -- permission groups -------------------------------------------------------------------------------------
    INSERT INTO perm_groups (name, label, weight, inherits, perms, removed, color, created_at, updated_at)
    SELECT d.id, left(COALESCE(d.data ->> 'label', d.id), 64),
           LEAST(GREATEST(core_legacy_int(d.data -> 'weight', 0), 0), 1000000)::int,
           core_legacy_texts(d.data -> 'inherits'), core_legacy_texts(d.data -> 'perms'),
           core_legacy_texts(d.data -> 'removed'), NULLIF(d.data ->> 'color', ''),
           core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'perm_groups' AND d.id ~ '^[A-Za-z0-9_-]{1,32}$';

    -- bans (v2 shape and the pre-§47 v1 shape { license, by = 'name', until }) -------------------------------
    INSERT INTO bans (id, account_id, name, reason, evidence, by_account_id, by_name, expires_at, revoked_at,
                      revoked_by_account_id, revoked_by_name, revoke_reason, hits, last_hit_at, relink,
                      created_at, updated_at)
    SELECT d.id,
           COALESCE((SELECT a.id FROM accounts a WHERE a.id = d.data ->> 'accountId'),
                    (SELECT a.id FROM accounts a WHERE a.license = d.data ->> 'license')),
           left(COALESCE(NULLIF(d.data ->> 'name', ''),
                         (SELECT NULLIF(a.name, '') FROM accounts a
                          WHERE a.id = d.data ->> 'accountId' OR a.license = d.data ->> 'license' LIMIT 1),
                         'unknown'), 64),
           left(COALESCE(NULLIF(d.data ->> 'reason', ''), 'No reason given'), 256),
           left(d.data ->> 'evidence', 512),
           CASE WHEN jsonb_typeof(d.data -> 'by') = 'object' THEN d.data -> 'by' ->> 'accountId' END,
           left(COALESCE(CASE WHEN jsonb_typeof(d.data -> 'by') = 'object' THEN d.data -> 'by' ->> 'name'
                              ELSE d.data ->> 'by' END, 'console'), 64),
           CASE WHEN core_legacy_int(COALESCE(d.data -> 'expiresAt', d.data -> 'until'), 0) > 0
                THEN to_timestamp(core_legacy_int(COALESCE(d.data -> 'expiresAt', d.data -> 'until'), 0)) END,
           CASE WHEN jsonb_typeof(d.data -> 'revoked') = 'object'
                    THEN core_legacy_ts(d.data -> 'revoked' -> 'at', core_legacy_ts(d.data -> 'updatedAt'))
                WHEN d.data -> 'revoked' = 'true'::jsonb THEN core_legacy_ts(d.data -> 'updatedAt') END,
           CASE WHEN jsonb_typeof(d.data -> 'revoked') = 'object' THEN d.data -> 'revoked' -> 'by' ->> 'accountId' END,
           CASE WHEN jsonb_typeof(d.data -> 'revoked') = 'object'
                    THEN left(COALESCE(d.data -> 'revoked' -> 'by' ->> 'name', 'console'), 64)
                WHEN d.data -> 'revoked' = 'true'::jsonb THEN 'console' END,
           CASE WHEN jsonb_typeof(d.data -> 'revoked') = 'object' THEN left(d.data -> 'revoked' ->> 'reason', 256) END,
           LEAST(GREATEST(core_legacy_int(d.data -> 'hits', 0), 0), 2147483647)::int,
           CASE WHEN d.data ? 'lastHitAt' THEN core_legacy_ts(d.data -> 'lastHitAt') END,
           NULLIF(d.data ->> 'relink', ''),
           core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'bans' AND d.id ~ '^[A-Za-z0-9_:-]{1,64}$';
    GET DIAGNOSTICS n = ROW_COUNT;
    SELECT count(*) INTO src FROM core_documents WHERE collection = 'bans';
    RAISE NOTICE 'core legacy import: bans % of %', n, src;

    INSERT INTO ban_accounts (ban_id, account_id, position)
    SELECT b.id, e.value, LEAST(e.ord - 1, 32767)::smallint
    FROM bans b
    JOIN core_documents d ON d.collection = 'bans' AND d.id = b.id
    CROSS JOIN LATERAL jsonb_array_elements_text(core_legacy_list(d.data -> 'accountIds')) WITH ORDINALITY AS e(value, ord)
    WHERE EXISTS (SELECT 1 FROM accounts a WHERE a.id = e.value)
    ON CONFLICT (ban_id, account_id) DO NOTHING;
    INSERT INTO ban_accounts (ban_id, account_id, position)
    SELECT id, account_id, 0 FROM bans WHERE account_id IS NOT NULL
    ON CONFLICT (ban_id, account_id) DO NOTHING;

    INSERT INTO ban_identifiers (ban_id, identifier)
    SELECT DISTINCT b.id, i.value
    FROM bans b
    JOIN core_documents d ON d.collection = 'bans' AND d.id = b.id
    CROSS JOIN LATERAL (
        SELECT e.value FROM jsonb_array_elements_text(core_legacy_list(d.data -> 'identifiers')) AS e(value)
        UNION
        SELECT d.data ->> 'license'
    ) AS i(value)
    WHERE i.value IS NOT NULL AND i.value ~ '^[a-z0-9]+:.' AND i.value NOT LIKE 'ip:%' AND length(i.value) <= 128
    ON CONFLICT (ban_id, identifier) DO NOTHING;

    INSERT INTO ban_tokens (ban_id, token)
    SELECT DISTINCT b.id, e.value
    FROM bans b
    JOIN core_documents d ON d.collection = 'bans' AND d.id = b.id
    CROSS JOIN LATERAL jsonb_array_elements_text(core_legacy_list(d.data -> 'tokens')) AS e(value)
    WHERE e.value <> '' AND length(e.value) <= 128
    ON CONFLICT (ban_id, token) DO NOTHING;

    -- the ban number sequence continues after the highest 'B<n>' id and the old counters/bans document
    SELECT GREATEST(
        COALESCE((SELECT max(substring(id FROM 2)::bigint) FROM bans WHERE id ~ '^B[0-9]{1,18}$'), 0),
        COALESCE((SELECT core_legacy_int(data -> 'value', 0) FROM core_documents
                  WHERE collection = 'counters' AND id = 'bans'), 0)) INTO seq;
    IF seq > 0 THEN
        PERFORM setval('ban_number_seq', seq);
    END IF;

    -- audit trail, in (ts, id) order so the identity follows the old order ------------------------------------
    INSERT INTO audit_log (at, pool, action, source, resource, result, actor, actor_account_id, targets,
                           target_keys, changes, reason, ctx, message, search)
    SELECT CASE WHEN core_legacy_int(d.data -> 'ts', 0) > 0
                THEN to_timestamp(core_legacy_int(d.data -> 'ts', 0) / 1000.0)
                ELSE core_legacy_ts(d.data -> 'createdAt') END,
           CASE WHEN d.data ->> 'action' LIKE 'sanction.%' OR d.data ->> 'action' LIKE 'ban.%' THEN 'exempt'
                WHEN d.data ->> 'action' LIKE 'core.%'
                     AND split_part(d.data ->> 'action', '.', 2)
                         NOT IN ('admin', 'perms', 'player', 'native', 'settings', 'maps', 'bans', 'cmd') THEN 'log'
                ELSE 'main' END,
           left(d.data ->> 'action', 64), d.data ->> 'source', d.data ->> 'resource',
           COALESCE(NULLIF(d.data ->> 'result', ''), 'ok'),
           core_legacy_obj(d.data -> 'actor'), d.data -> 'actor' ->> 'accountId',
           CASE WHEN jsonb_array_length(core_legacy_list(d.data -> 'targets')) > 0 THEN core_legacy_list(d.data -> 'targets') END,
           COALESCE((SELECT array_agg(DISTINCT k.key) FROM (
                        SELECT (t ->> 'type') || ':' || (t ->> 'id') AS key
                        FROM jsonb_array_elements(core_legacy_list(d.data -> 'targets')) AS t
                        WHERE jsonb_typeof(t) = 'object' AND t ? 'type' AND t ? 'id'
                        UNION ALL
                        SELECT 'account:' || (t ->> 'accountId')
                        FROM jsonb_array_elements(core_legacy_list(d.data -> 'targets')) AS t
                        WHERE jsonb_typeof(t) = 'object' AND t ? 'type' AND t ? 'id' AND t ? 'accountId'
                    ) AS k), '{}'::text[]),
           CASE WHEN jsonb_array_length(core_legacy_list(d.data -> 'changes')) > 0 THEN core_legacy_list(d.data -> 'changes') END,
           d.data ->> 'reason',
           CASE WHEN jsonb_typeof(d.data -> 'ctx') = 'object' THEN d.data -> 'ctx' END,
           d.data ->> 'message',
           left(lower(concat_ws(' ', d.data ->> 'action', d.data -> 'actor' ->> 'name', d.data ->> 'message',
                                d.data ->> 'reason',
                                (SELECT string_agg(t ->> 'name', ' ')
                                 FROM jsonb_array_elements(core_legacy_list(d.data -> 'targets')) AS t
                                 WHERE jsonb_typeof(t) = 'object'))), 640)
    FROM core_documents d
    WHERE d.collection = 'audit' AND COALESCE(d.data ->> 'action', '') <> ''
    ORDER BY core_legacy_int(d.data -> 'ts', 0), d.id;
    GET DIAGNOSTICS n = ROW_COUNT;
    SELECT count(*) INTO src FROM core_documents WHERE collection = 'audit';
    RAISE NOTICE 'core legacy import: audit % of %', n, src;

    -- settings, globals, world state, doors ---------------------------------------------------------------
    INSERT INTO settings (key, value, updated_by, created_at, updated_at)
    SELECT COALESCE(NULLIF(d.data ->> 'key', ''), replace(d.id, ':', '.')), d.data -> 'value',
           CASE WHEN jsonb_typeof(d.data -> 'by') = 'object' THEN d.data -> 'by' END,
           core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'settings' AND d.data ? 'value'
    ON CONFLICT (key) DO NOTHING;

    INSERT INTO globals (key, value, mirror, updated_at)
    SELECT v.key, v.value, COALESCE(core_legacy_obj(d.data -> 'mirror') -> v.key = 'true'::jsonb, false),
           core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    CROSS JOIN LATERAL jsonb_each(core_legacy_obj(d.data -> 'values')) AS v
    WHERE d.collection = 'globals' AND d.id = 'server' AND length(v.key) <= 64;

    INSERT INTO world_state (id, day_seconds, weather, frozen, cycle_index, cycle_minutes_left, updated_at)
    SELECT 1, LEAST(GREATEST(core_legacy_int(d.data -> 'daySeconds', 43200), 0), 86399)::int,
           COALESCE(NULLIF(d.data ->> 'weather', ''), 'CLEAR'), core_legacy_bool(d.data -> 'frozen', false),
           core_legacy_int(d.data -> 'cycleIndex', 1)::int,
           GREATEST(core_legacy_int(d.data -> 'cycleMinutesLeft', 0), 0)::int, core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'world' AND d.id = 'state';

    INSERT INTO doors (id, model, coords, locked, perms, auto_lock_ms, meta, created_at, updated_at)
    SELECT d.id, core_legacy_int(d.data -> 'model', 0), d.data -> 'coords', core_legacy_bool(d.data -> 'locked', true),
           core_legacy_texts(d.data -> 'perms'), GREATEST(core_legacy_int(d.data -> 'autoLockMs', 0), 0)::int,
           CASE WHEN jsonb_typeof(d.data -> 'meta') = 'object' THEN d.data -> 'meta' END,
           core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'doors' AND jsonb_typeof(d.data -> 'coords') = 'object';

    -- factions + members (one faction per character: a character listed twice stays in the first) --------------
    INSERT INTO factions (id, name, tag, color, owner_character_id, ranks, bank, meta, created_at, updated_at)
    SELECT d.id, left(d.data ->> 'name', 32), upper(left(d.data ->> 'tag', 5)),
           COALESCE(NULLIF(d.data ->> 'color', ''), '#ffffff'),
           (SELECT c.id FROM characters c WHERE c.id = d.data ->> 'ownerCharId'),
           core_legacy_list(d.data -> 'ranks'), GREATEST(core_legacy_int(d.data -> 'bank', 0), 0),
           core_legacy_obj(d.data -> 'meta'), core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'factions' AND COALESCE(d.data ->> 'name', '') <> '' AND COALESCE(d.data ->> 'tag', '') <> ''
    ORDER BY core_legacy_int(d.data -> 'createdAt', 0), d.id
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS n = ROW_COUNT;
    SELECT count(*) INTO src FROM core_documents WHERE collection = 'factions';
    RAISE NOTICE 'core legacy import: factions % of %', n, src;

    INSERT INTO faction_members (character_id, faction_id, rank, name, joined_at)
    SELECT m.key, f.id, LEAST(GREATEST(core_legacy_int(m.value -> 'rank', 1), 1), 32767)::smallint,
           left(COALESCE(m.value ->> 'name', ''), 64), core_legacy_ts(m.value -> 'joinedAt')
    FROM factions f
    JOIN core_documents d ON d.collection = 'factions' AND d.id = f.id
    CROSS JOIN LATERAL jsonb_each(core_legacy_obj(d.data -> 'members')) AS m
    WHERE jsonb_typeof(m.value) = 'object' AND EXISTS (SELECT 1 FROM characters c WHERE c.id = m.key)
    ORDER BY f.created_at, f.id
    ON CONFLICT (character_id) DO NOTHING;

    -- vehicles (a duplicated plate keeps the most recently written record) -----------------------------------
    INSERT INTO vehicles (id, owner_character_id, model, model_name, plate, props, stored, destroyed, parked,
                          locked, keys, position, meta, last_used_at, created_at, updated_at)
    SELECT DISTINCT ON (d.data ->> 'plate')
           d.id, (SELECT c.id FROM characters c WHERE c.id = d.data ->> 'ownerCharId'),
           core_legacy_int(d.data -> 'model', 0), NULLIF(d.data ->> 'modelName', ''), d.data ->> 'plate',
           core_legacy_obj(d.data -> 'props'),
           d.data -> 'stored' IS DISTINCT FROM 'false'::jsonb,
           core_legacy_bool(d.data -> 'destroyed', false),
           CASE WHEN jsonb_typeof(d.data -> 'parked') = 'number' AND core_legacy_int(d.data -> 'parked', 0) BETWEEN 1 AND 2147483647
                THEN core_legacy_int(d.data -> 'parked', 0)::int END,
           CASE WHEN jsonb_typeof(d.data -> 'locked') = 'boolean' THEN (d.data ->> 'locked')::boolean END,
           core_legacy_texts(d.data -> 'keys'),
           CASE WHEN jsonb_typeof(d.data -> 'position') = 'object' THEN d.data -> 'position' END,
           core_legacy_obj(d.data -> 'meta'),
           core_legacy_ts(d.data -> 'updatedAt'), core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'vehicles' AND COALESCE(d.data ->> 'plate', '') <> '' AND d.id ~ '^[A-Za-z0-9_:-]{1,64}$'
    ORDER BY d.data ->> 'plate', core_legacy_int(d.data -> 'updatedAt', 0) DESC, d.id;
    GET DIAGNOSTICS n = ROW_COUNT;
    SELECT count(*) INTO src FROM core_documents WHERE collection = 'vehicles';
    RAISE NOTICE 'core legacy import: vehicles % of %', n, src;

    -- persistent scene nodes ('n<id>'): kind/owner/parent/bucket become columns, the rest stays in doc ---------
    INSERT INTO scene_nodes (id, kind, owner, parent, bucket, doc, created_at, updated_at)
    SELECT substring(d.id FROM 2)::int, d.data ->> 'kind', COALESCE(NULLIF(d.data ->> 'owner', ''), 'core'),
           CASE WHEN jsonb_typeof(d.data -> 'parent') = 'number' THEN core_legacy_int(d.data -> 'parent', 0)::int END,
           core_legacy_int(d.data -> 'bucket', 0)::int,
           d.data - ARRAY['id', 'kind', 'owner', 'parent', 'bucket', 'createdAt', 'updatedAt'],
           core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'scene_nodes' AND d.id ~ '^n[0-9]{1,9}$' AND COALESCE(d.data ->> 'kind', '') <> '';

    -- counters: counters/<name> (bans went into the sequence) and scene_meta/counter -> core_counters ----------
    INSERT INTO core_counters (name, value)
    SELECT d.id, GREATEST(core_legacy_int(d.data -> 'value', 0), 0)
    FROM core_documents d
    WHERE d.collection = 'counters' AND d.id <> 'bans' AND d.id ~ '^[A-Za-z0-9_:-]{1,64}$'
    UNION ALL
    SELECT 'scene_nodes', GREATEST(core_legacy_int(d.data -> 'value', 0), 0)
    FROM core_documents d
    WHERE d.collection = 'scene_meta' AND d.id = 'counter'
    ON CONFLICT (name) DO UPDATE SET value = GREATEST(core_counters.value, EXCLUDED.value);

    -- maps and their elements, versions and journal ('<mapId>:<n>', '<mapId>:v<n>', '<mapId>:j<n>') ------------
    INSERT INTO maps (id, name, mode, active, target_bucket, published_version, published_seq, next_element_id,
                      journal_seq, meta, limits, expires_at, created_by, created_at, updated_at)
    SELECT d.id, left(COALESCE(NULLIF(d.data ->> 'name', ''), d.id), 64),
           CASE WHEN d.data ->> 'mode' = 'live' THEN 'live' ELSE 'draft' END,
           core_legacy_bool(d.data -> 'active', false), core_legacy_int(d.data -> 'targetBucket', 0)::int,
           core_legacy_int(d.data -> 'publishedVersion', 0)::int, core_legacy_int(d.data -> 'publishedSeq', 0)::int,
           GREATEST(core_legacy_int(d.data -> 'nextElementId', 1), 1)::int, core_legacy_int(d.data -> 'journalSeq', 0)::int,
           core_legacy_obj(d.data -> 'meta'),
           CASE WHEN jsonb_typeof(d.data -> 'limits') = 'object' THEN d.data -> 'limits' END,
           CASE WHEN core_legacy_int(d.data -> 'expiresAt', 0) > 0 THEN to_timestamp(core_legacy_int(d.data -> 'expiresAt', 0)) END,
           CASE WHEN jsonb_typeof(d.data -> 'createdBy') = 'object' THEN d.data -> 'createdBy' END,
           core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'maps' AND d.id ~ '^[A-Za-z0-9_-]{1,24}$';

    INSERT INTO map_elements (map_id, element_id, type, type_version, pos, rot, fields, layer, cam, author, rev,
                              info, created_at, updated_at)
    SELECT split_part(d.id, ':', 1), split_part(d.id, ':', 2)::int, d.data ->> 'type',
           core_legacy_int(d.data -> 'typeVersion', 1)::int, core_legacy_obj(d.data -> 'pos'), core_legacy_obj(d.data -> 'rot'),
           core_legacy_obj(d.data -> 'fields'), d.data ->> 'layer',
           CASE WHEN jsonb_typeof(d.data -> 'cam') = 'object' THEN d.data -> 'cam' END,
           d.data ->> 'by', GREATEST(core_legacy_int(d.data -> 'rev', 0), 0),
           CASE WHEN jsonb_typeof(d.data -> 'info') = 'object' THEN d.data -> 'info' END,
           core_legacy_ts(d.data -> 'createdAt'), core_legacy_ts(d.data -> 'updatedAt')
    FROM core_documents d
    WHERE d.collection = 'map_elements' AND d.id ~ '^[A-Za-z0-9_-]{1,24}:[0-9]{1,9}$'
      AND COALESCE(d.data ->> 'type', '') <> ''
      AND EXISTS (SELECT 1 FROM maps m WHERE m.id = split_part(d.id, ':', 1));
    GET DIAGNOSTICS n = ROW_COUNT;
    SELECT count(*) INTO src FROM core_documents WHERE collection = 'map_elements';
    RAISE NOTICE 'core legacy import: map elements % of %', n, src;

    INSERT INTO map_versions (map_id, version, elements, count, author, author_name, note, from_version, at)
    SELECT split_part(d.id, ':', 1), substring(split_part(d.id, ':', 2) FROM 2)::int,
           core_legacy_list(d.data -> 'elements'), GREATEST(core_legacy_int(d.data -> 'count', 0), 0)::int,
           d.data ->> 'by', d.data ->> 'byName', d.data ->> 'note',
           CASE WHEN jsonb_typeof(d.data -> 'from') = 'number' THEN core_legacy_int(d.data -> 'from', 0)::int END,
           core_legacy_ts(d.data -> 'at', core_legacy_ts(d.data -> 'createdAt'))
    FROM core_documents d
    WHERE d.collection = 'map_versions' AND d.id ~ '^[A-Za-z0-9_-]{1,24}:v[0-9]{1,9}$'
      AND EXISTS (SELECT 1 FROM maps m WHERE m.id = split_part(d.id, ':', 1));

    INSERT INTO map_journal (map_id, seq, at, author, source, actor, count, w, clear, ops, ids)
    SELECT split_part(d.id, ':', 1), substring(split_part(d.id, ':', 2) FROM 2)::int,
           core_legacy_ts(d.data -> 'at', core_legacy_ts(d.data -> 'createdAt')), d.data ->> 'by', d.data ->> 'source',
           CASE WHEN jsonb_typeof(d.data -> 'actor') = 'object' THEN d.data -> 'actor' END,
           GREATEST(core_legacy_int(d.data -> 'count', 0), 0)::int, GREATEST(core_legacy_int(d.data -> 'w', 1), 0)::int,
           core_legacy_bool(d.data -> 'clear', false),
           CASE WHEN jsonb_typeof(d.data -> 'ops') = 'array' THEN d.data -> 'ops' END,
           CASE WHEN jsonb_typeof(d.data -> 'ids') = 'array' THEN d.data -> 'ids' END
    FROM core_documents d
    WHERE d.collection = 'map_journal' AND d.id ~ '^[A-Za-z0-9_-]{1,24}:j[0-9]{1,9}$'
      AND EXISTS (SELECT 1 FROM maps m WHERE m.id = split_part(d.id, ':', 1));
    GET DIAGNOSTICS n = ROW_COUNT;
    SELECT count(*) INTO src FROM core_documents WHERE collection = 'map_journal';
    RAISE NOTICE 'core legacy import: map journal % of %', n, src;

    -- nothing writes the old table again; plugins import their own collections from it (§56.7, §56.9)
    ALTER TABLE core_documents RENAME TO legacy_documents;
    COMMENT ON TABLE legacy_documents IS
        'Pre-§56 document store, read-only. Plugins import their collections from it; drop it by hand once every plugin migrated.';
END
$$;

DROP FUNCTION core_legacy_texts(jsonb);
DROP FUNCTION core_legacy_list(jsonb);
DROP FUNCTION core_legacy_obj(jsonb);
DROP FUNCTION core_legacy_bool(jsonb, boolean);
DROP FUNCTION core_legacy_ts(jsonb, timestamptz);
DROP FUNCTION core_legacy_int(jsonb, bigint);
