#!/usr/bin/env bash
#
# core/scripts/test-db.sh up|down|url  --  the THROWAWAY test database of DESIGN §56.10.1.
#
#   up    create the role `core_test` (password `core_test`) and the database `core_test` owned by it
#         inside the Docker container `core-postgres`; a no-op when both already exist
#   down  drop the database and the role again (every test table goes with them)
#   url   print the default CORE_TEST_PG_URL the suites and core_db/tests use
#
# The credentials are test-only (never a secret, never the production database `core`). The script
# talks to Postgres as the container's local superuser through `docker exec ... psql -U core`, so it
# reads no password and prints nothing but the test URL. CORE_PG_CONTAINER overrides the container name.

set -euo pipefail

readonly CONTAINER="${CORE_PG_CONTAINER:-core-postgres}"
readonly ROLE='core_test'
readonly DATABASE='core_test'
readonly DEFAULT_URL='postgres://core_test:core_test@127.0.0.1:5432/core_test'

usage() { printf 'usage: %s up|down|url\n' "$(basename -- "$0")"; }

# One statement against the maintenance database; -tA prints bare values (empty when no row).
psql_admin() {
    docker exec "$CONTAINER" psql -U core -d postgres -v ON_ERROR_STOP=1 -tAc "$1"
}

require_container() {
    if ! docker exec "$CONTAINER" true >/dev/null 2>&1; then
        printf 'test-db: the container %s is not running\n' "$CONTAINER" >&2
        exit 1
    fi
}

up() {
    require_container
    if [ -z "$(psql_admin "SELECT 1 FROM pg_roles WHERE rolname = '$ROLE'")" ]; then
        psql_admin "CREATE ROLE $ROLE LOGIN PASSWORD '$ROLE'" >/dev/null
        printf 'test-db: created role %s\n' "$ROLE"
    fi
    if [ -z "$(psql_admin "SELECT 1 FROM pg_database WHERE datname = '$DATABASE'")" ]; then
        # CREATE DATABASE cannot run inside a transaction block, so it is its own psql call
        psql_admin "CREATE DATABASE $DATABASE OWNER $ROLE" >/dev/null
        printf 'test-db: created database %s\n' "$DATABASE"
    fi
    printf 'test-db: ready (%s)\n' "$DEFAULT_URL"
}

down() {
    require_container
    psql_admin "DROP DATABASE IF EXISTS $DATABASE WITH (FORCE)" >/dev/null
    psql_admin "DROP ROLE IF EXISTS $ROLE" >/dev/null
    printf 'test-db: dropped database and role %s\n' "$ROLE"
}

case "${1:-}" in
    up) up ;;
    down) down ;;
    url) printf '%s\n' "$DEFAULT_URL" ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
esac
