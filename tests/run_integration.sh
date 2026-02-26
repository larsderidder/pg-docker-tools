#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

require_cmd docker
require_cmd yq

export PGPASSWORD_APP_LOCAL=postgres

compose() {
  docker compose -f "$ROOT_DIR/docker-compose.yml" "$@"
}

compose up -d

cleanup() {
  compose down -v
}
trap cleanup EXIT

log() {
  echo "[integration] $*"
}

log "Waiting for Postgres to become healthy"
for _ in {1..30}; do
  if compose ps --status running | grep -q postgres; then
    if docker exec "$(compose ps -q postgres)" pg_isready -U postgres >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 1
done

CONTAINER_ID="$(compose ps -q postgres)"

log "Seeding data"
docker exec "$CONTAINER_ID" psql -U postgres -d pgtools_test -c "CREATE TABLE IF NOT EXISTS demo(id SERIAL PRIMARY KEY, name TEXT);"
docker exec "$CONTAINER_ID" psql -U postgres -d pgtools_test -c "INSERT INTO demo(name) VALUES('alpha') ON CONFLICT DO NOTHING;"

log "Running dump"
"$ROOT_DIR/bin/pg_dump.sh" app local --config "$SCRIPT_DIR/config.yaml" --output-dir "$SCRIPT_DIR/backups/app/local"

DUMP_FILE=$(ls -1t "$SCRIPT_DIR/backups/app/local"/*.dump | head -n 1)

log "Running restore"
"$ROOT_DIR/bin/pg_restore.sh" app local "$DUMP_FILE" --config "$SCRIPT_DIR/config.yaml" --no-clean

log "Integration test completed"
