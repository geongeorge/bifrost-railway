#!/bin/sh
# Railway boot wrapper for Bifrost. Everything here is idempotent: it runs on every
# deploy and on every container restart, and hands off to the image's own entrypoint.
set -e

APP_DIR="${APP_DIR:-/app/data}"
PG_SSL_MODE="${PG_SSL_MODE:-require}"
PG_USER="${PG_USER:-bifrost}"
PG_DB=bifrost

# ---------------------------------------------------------------------------
# 1. Put config.json in place.
# APP_DIR is a declared VOLUME, so a mounted volume would hide a copy baked into the
# image at build time. Writing it at boot keeps the file correct either way.
# ---------------------------------------------------------------------------
#
# CORS defaults to this deployment's own public URL rather than "*", so a browser on
# some other origin cannot spend the operator's provider credits with a leaked virtual
# key. Set BIFROST_ALLOWED_ORIGINS (comma-separated) to widen it.
ALLOWED_ORIGINS="${BIFROST_ALLOWED_ORIGINS:-${BIFROST_EXTERNAL_URL:-*}}"
ALLOWED_ORIGINS_JSON=$(printf '%s' "$ALLOWED_ORIGINS" | sed 's/,/","/g')

mkdir -p "$APP_DIR"
sed -e "s|__PG_SSL_MODE__|${PG_SSL_MODE}|g" \
    -e "s|__ALLOWED_ORIGINS__|${ALLOWED_ORIGINS_JSON}|g" \
    /app/config.json > "$APP_DIR/config.json"
echo "boot: wrote $APP_DIR/config.json (pg ssl_mode=${PG_SSL_MODE}, allowed_origins=${ALLOWED_ORIGINS})"

# ---------------------------------------------------------------------------
# 2. Size the Go heap from the cgroup.
# Railway's hosts are far larger than the container's memory limit, and Go's default
# target is derived from the host — which invites an OOM kill under load.
# ---------------------------------------------------------------------------
if [ -z "$GOMEMLIMIT" ] && [ -r /sys/fs/cgroup/memory.max ]; then
    _cg_max=$(cat /sys/fs/cgroup/memory.max)
    case "$_cg_max" in
        '' | max) ;;
        *)
            GOMEMLIMIT="$((_cg_max / 1048576 * 90 / 100))MiB"
            export GOMEMLIMIT
            echo "boot: GOMEMLIMIT=$GOMEMLIMIT (container limit $((_cg_max / 1048576))MiB)"
            ;;
    esac
fi

# ---------------------------------------------------------------------------
# 3. Create Bifrost's own Postgres role and database.
# Bifrost needs a UTF8 database created from template0 and a role that owns it.
# Railway's managed Postgres offers neither, and a template deploy has no room for a
# manual step — so the container provisions them from the superuser URL at boot and
# then connects as the scoped role. Skip the whole block by setting PG_BOOTSTRAP=0
# (for an external Postgres where the role and database already exist).
# ---------------------------------------------------------------------------
bootstrap_postgres() {
    psql "$PG_ADMIN_URL" -v ON_ERROR_STOP=1 -q \
        -v role="$PG_USER" -v pw="$PG_PASSWORD" -v db="$PG_DB" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE', :'role', :'pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
\gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'role', :'pw')
 WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'role')
\gexec
SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING ''UTF8''', :'db', :'role')
 WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = :'db')
\gexec
SQL
}

if [ "${PG_BOOTSTRAP:-1}" = "1" ] && [ -n "$PG_ADMIN_URL" ]; then
    if [ -z "$PG_PASSWORD" ]; then
        echo "Error: PG_PASSWORD is required so Bifrost's own database role has a password."
        exit 1
    fi
    # Railway has no service ordering, so Postgres may still be booting.
    _ok=0
    _i=1
    while [ "$_i" -le 20 ]; do
        if bootstrap_postgres; then
            _ok=1
            break
        fi
        echo "boot: Postgres not ready for bootstrap (attempt $_i/20), retrying in 5s"
        _i=$((_i + 1))
        sleep 5
    done
    if [ "$_ok" != "1" ]; then
        echo "Error: could not create the '$PG_USER' role and '$PG_DB' database on the configured Postgres."
        exit 1
    fi
    echo "boot: Postgres role '$PG_USER' and database '$PG_DB' are present"
fi

exec /app/docker-entrypoint.sh "$@"
