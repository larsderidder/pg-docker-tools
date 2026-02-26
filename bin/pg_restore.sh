#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pg_restore.sh <db_id> <env> <dump_path> [options]

Options:
  --config <path>        Path to config.yaml (default: package config.yaml)
  --mode <auto|docker|host>
                          Execution mode (default: auto)
  --no-clean             Skip --clean --if-exists
  --jobs <n>             Parallel jobs for pg_restore
  --toc <path>           TOC list file (path under current working directory)
  --password-env <name>  Environment variable to read PGPASSWORD from
  -h, --help             Show this help
USAGE
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_DEFAULT="$ROOT_DIR/config.yaml"

DB_ID="${1:-}"
TARGET_ENV="${2:-}"
DUMP_PATH="${3:-}"
shift 3 || true

if [[ -z "$DB_ID" || -z "$TARGET_ENV" || -z "$DUMP_PATH" ]]; then
  usage
  exit 1
fi

MODE=""
JOBS=""
TOC_FILE=""
PASS_ENV_NAME=""
CONF_PATH="$CONF_DEFAULT"
RUN_MODE="auto"

while (( "$#" )); do
  case "$1" in
    --config)
      CONF_PATH="$2"
      shift 2
      ;;
    --no-clean)
      MODE="--no-clean"
      shift
      ;;
    --mode)
      RUN_MODE="$2"
      shift 2
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --toc)
      TOC_FILE="$2"
      shift 2
      ;;
    --password-env)
      PASS_ENV_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

require_cmd yq

if [[ "$RUN_MODE" == "auto" ]]; then
  if command -v docker >/dev/null 2>&1; then
    RUN_MODE="docker"
  else
    RUN_MODE="host"
  fi
fi

if [[ "$RUN_MODE" != "docker" && "$RUN_MODE" != "host" ]]; then
  echo "Unknown mode: $RUN_MODE"
  exit 1
fi

if [[ "$RUN_MODE" == "docker" ]]; then
  require_cmd docker
else
  require_cmd pg_restore
fi

CFG_ROOT=".databases.$DB_ID.$TARGET_ENV"

"$ROOT_DIR/bin/confirm_env.sh" "$TARGET_ENV"

[[ -f "$DUMP_PATH" || -d "$DUMP_PATH" ]] || { echo "Dump path not found: $DUMP_PATH"; exit 1; }

PASSWORD_VAR="${PASS_ENV_NAME:-PGPASSWORD_${DB_ID^^}_${TARGET_ENV^^}}"
export PGPASSWORD="$(eval echo \$$PASSWORD_VAR)"
: "${PGPASSWORD:?$PASSWORD_VAR is not set}"

PG_VER=$(yq -r "$CFG_ROOT.pg_version" "$CONF_PATH")
HOST=$(yq -r "$CFG_ROOT.host" "$CONF_PATH")
DB_NAME=$(yq -r "$CFG_ROOT.db" "$CONF_PATH")
DB_USER=$(yq -r "$CFG_ROOT.user" "$CONF_PATH")
NETWORK=$(yq -r "${CFG_ROOT}.network // \"\"" "$CONF_PATH")

CLEAN_ARGS=(--clean --if-exists)
if [[ "$MODE" == "--no-clean" ]]; then
  CLEAN_ARGS=()
fi

RESTORE_JOBS="${JOBS:-32}"

DOCKER_NET_ARGS=()
if [[ -n "$NETWORK" ]]; then
  DOCKER_NET_ARGS+=(--network "$NETWORK")
else
  DOCKER_NET_ARGS+=(--network host)
fi

log "Starting pg_restore"
log "Database           : $DB_ID"
log "Environment        : $TARGET_ENV"
log "Postgres version   : $PG_VER"
log "Host               : $HOST"
log "DB name            : $DB_NAME"
log "User               : $DB_USER"
log "Dump path          : $DUMP_PATH"
log "Docker network     : ${NETWORK:-host}"
log "Run mode           : $RUN_MODE"

LIST_ARGS=()
if [[ -n "$TOC_FILE" ]]; then
  [[ -f "$TOC_FILE" ]] || { echo "TOC list not found: $TOC_FILE"; exit 1; }
  case "$TOC_FILE" in
    /*)
      echo "TOC list must be under the current working directory so it can be mounted into /work. Got: $TOC_FILE"
      exit 1
      ;;
  esac
  LIST_ARGS=(-L "/work/$TOC_FILE")
  log "TOC list           : $TOC_FILE"
else
  log "TOC list           : (none)"
fi

TOC_TEXT=$(
  if [[ "$RUN_MODE" == "docker" ]]; then
    docker run --rm \
      --user "$(id -u):$(id -g)" \
      -v "$PWD:/work" \
      postgres:${PG_VER} \
      pg_restore -l "/work/$DUMP_PATH"
  else
    pg_restore -l "$DUMP_PATH"
  fi
)

HAS_TABLE_DATA="no"
HAS_TABLE_DEF="no"

if printf '%s\n' "$TOC_TEXT" | grep -q " TABLE DATA "; then
  HAS_TABLE_DATA="yes"
fi
if printf '%s\n' "$TOC_TEXT" | awk '/ TABLE DATA /{next} / TABLE /{found=1; exit} END{if(found) print "yes"}' | grep -q "yes"; then
  HAS_TABLE_DEF="yes"
fi

if [[ "$HAS_TABLE_DATA" == "yes" && "$HAS_TABLE_DEF" == "no" ]]; then
  CLEAN_ARGS=()
  log "Restore mode       : data-only (auto no-clean)"

  if [[ "$RESTORE_JOBS" != "1" ]]; then
    RESTORE_JOBS="1"
    log "Restore jobs       : forced to 1 (data-only safety)"
  fi

  if [[ -z "$TOC_FILE" ]]; then
    log "WARNING            : No TOC list in use. pg_restore --data-only may reset sequences via SEQUENCE SET."
  fi
elif [[ "$MODE" == "--no-clean" ]]; then
  log "Restore mode       : full (no-clean)"
else
  log "Restore mode       : full"
fi

log "Restore jobs       : $RESTORE_JOBS"
log "Launching pg_restore container (verbose)"

if [[ "$RUN_MODE" == "docker" ]]; then
  docker run --rm \
    "${DOCKER_NET_ARGS[@]}" \
    --user "$(id -u):$(id -g)" \
    -e PGPASSWORD \
    -v "$PWD:/work" \
    postgres:${PG_VER} \
    pg_restore \
      -v \
      -j "$RESTORE_JOBS" \
      "${CLEAN_ARGS[@]}" \
      --no-owner \
      --no-acl \
      "${LIST_ARGS[@]}" \
      -h "$HOST" \
      -U "$DB_USER" \
      -d "$DB_NAME" \
      "/work/$DUMP_PATH"
else
  pg_restore \
    -v \
    -j "$RESTORE_JOBS" \
    "${CLEAN_ARGS[@]}" \
    --no-owner \
    --no-acl \
    "${LIST_ARGS[@]}" \
    -h "$HOST" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    "$DUMP_PATH"
fi

log "pg_restore completed successfully"
