-- core/tests/fixtures/dbfixture/sql/0001_fixture.sql — the fixture resource of tests/db_tests.lua
-- (DESIGN §56.10.3). Mapped with bridge.mapResource('dbfixture', ...); applied by Core.DB.migrate in
-- the suite, so it also proves a plugin migration read from the CALLING resource. Tables carry the
-- resource prefix (§56.4.3); the FK is DEFERRABLE INITIALLY DEFERRED like every FK the queue writes.

CREATE TABLE dbfixture_things (
    id          text PRIMARY KEY,
    name        text NOT NULL,
    qty         integer NOT NULL DEFAULT 0,
    price       numeric(10, 2),
    big         bigint,
    tags        text[],
    data        jsonb,
    seen_at     timestamptz,
    day         date,
    flag        boolean,
    note        text,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE dbfixture_log (
    id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    thing_id    text REFERENCES dbfixture_things (id) ON DELETE CASCADE DEFERRABLE INITIALLY DEFERRED,
    msg         text NOT NULL,
    at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX dbfixture_log_thing ON dbfixture_log (thing_id);

CREATE TABLE dbfixture_pairs (
    a           integer NOT NULL,
    b           integer NOT NULL,
    v           text,
    PRIMARY KEY (a, b)
);
