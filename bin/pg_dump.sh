#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pg_dump.sh <db_id> <env> [options]

Options:
  --config <path>        Path to config.yaml (default: package config.yaml)
  --mode <auto|docker|host>
                          Execution mode (default: auto)
  --format <custom|directory>
  --with-excludes        Exclude table data listed in config
  --only-excludes        Dump data only for excluded tables
  --jobs <n>             Parallel jobs (directory format only)
  --compress <level>     Compression level for pg_dump
  --output-dir <path>    Base output directory (default: backups/<db>/<env>)
  --password-env <name>  Environment variable to read PGPASSWORD from
  --keep-days <n>        Prune backups older than N days
  --keep-count <n>       Keep only N most recent backups
  --no-checksum          Skip writing checksum file
  -h, --help             Show this help
USAGE
}

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }
}

checksum_cmd() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum"
    return
  fi
  if command -v shasum >/dev/null 2>&1; then
    echo "shasum -a 256"
    return
  fi
  return 1
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_DEFAULT="$ROOT_DIR/config.yaml"

DB_ID="${1:-}"
TARGET_ENV="${2:-}"
shift 2 || true

if [[ -z "$DB_ID" || -z "$TARGET_ENV" ]]; then
  usage
  exit 1
fi

MODE=""
DUMP_FORMAT=""
JOBS=""
COMPRESS=""
OUTPUT_DIR=""
PASS_ENV_NAME=""
CONF_PATH="$CONF_DEFAULT"
KEEP_DAYS=""
KEEP_COUNT=""
WRITE_CHECKSUM="yes"
RUN_MODE="auto"

while (( "$#" )); do
  case "$1" in
    --config)
      CONF_PATH="$2"
      shift 2
      ;;
    --with-excludes|--only-excludes)
      MODE="$1"
      shift
      ;;
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --format)
      DUMP_FORMAT="$2"
      shift 2
      ;;
    --mode)
      RUN_MODE="$2"
      shift 2
      ;;
    --compress)
      COMPRESS="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --password-env)
      PASS_ENV_NAME="$2"
      shift 2
      ;;
    --keep-days)
      KEEP_DAYS="$2"
      shift 2
      ;;
    --keep-count)
      KEEP_COUNT="$2"
      shift 2
      ;;
    --no-checksum)
      WRITE_CHECKSUM="no"
      shift
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
  require_cmd pg_dump
fi

CFG_ROOT=".databases.$DB_ID.$TARGET_ENV"

PASSWORD_VAR="${PASS_ENV_NAME:-PGPASSWORD_${DB_ID^^}_${TARGET_ENV^^}}"
export PGPASSWORD="$(eval echo \$$PASSWORD_VAR)"
: "${PGPASSWORD:?$PASSWORD_VAR is not set}"

DUMP_FORMAT="${DUMP_FORMAT:-$(yq -r '.defaults.dump_format // "custom"' "$CONF_PATH") }"

PG_VER=$(yq -r "$CFG_ROOT.pg_version" "$CONF_PATH")
HOST=$(yq -r "$CFG_ROOT.host" "$CONF_PATH")
DB_NAME=$(yq -r "$CFG_ROOT.db" "$CONF_PATH")
DB_USER=$(yq -r "$CFG_ROOT.user" "$CONF_PATH")
NETWORK=$(yq -r "$CFG_ROOT.network // """ "$CONF_PATH")

TS=$(date +%Y%m%d_%H%M%S)
MODE_TAG=""
FORMAT_FLAG=""
OUT_EXT="dump"

case "$DUMP_FORMAT" in
  custom|c)
    FORMAT_FLAG="-Fc"
    ;;
  directory|d)
    FORMAT_FLAG="-Fd"
    OUT_EXT="dumpdir"
    ;;
  *)
    echo "Unknown format: $DUMP_FORMAT"
    exit 1
    ;;
esac

EXCLUDE_TABLES=()
if [[ -n "$MODE" ]]; then
  mapfile -t EXCLUDE_TABLES < <(yq -r "$CFG_ROOT.exclude_data[]?" "$CONF_PATH")
fi

EXCLUDE_ARGS=()
INCLUDE_ARGS=()
DATA_ONLY=""
if [[ "$MODE" == "--with-excludes" ]]; then
  for table in "${EXCLUDE_TABLES[@]}"; do
    EXCLUDE_ARGS+=("--exclude-table-data=$table")
  done
  MODE_TAG="_exclude"
elif [[ "$MODE" == "--only-excludes" ]]; then
  if (( ${#EXCLUDE_TABLES[@]} == 0 )); then
    echo "No exclude_data configured for ${DB_ID}/${TARGET_ENV}"
    exit 1
  fi
  for table in "${EXCLUDE_TABLES[@]}"; do
    INCLUDE_ARGS+=("--table=$table")
  done
  DATA_ONLY="--data-only"
  MODE_TAG="_only_excluded"
elif [[ -n "$MODE" ]]; then
  echo "Unknown mode: $MODE"
  exit 1
fi

if [[ -n "$JOBS" && "$FORMAT_FLAG" != "-Fd" ]]; then
  echo "--jobs requires directory format (--format directory)"
  exit 1
fi

BASE_DIR="${OUTPUT_DIR:-backups/${DB_ID}/${TARGET_ENV}}"
OUT="${BASE_DIR}/${DB_ID}_${TS}${MODE_TAG}.${OUT_EXT}"

JOBS_ARGS=()
[[ -n "$JOBS" ]] && JOBS_ARGS+=(--jobs "$JOBS")

COMPRESS_ARGS=()
[[ -n "$COMPRESS" ]] && COMPRESS_ARGS+=(--compress "$COMPRESS")

DOCKER_NET_ARGS=()
if [[ -n "$NETWORK" ]]; then
  DOCKER_NET_ARGS+=(--network "$NETWORK")
else
  DOCKER_NET_ARGS+=(--network host)
fi

mkdir -p "$(dirname "$OUT")"

log "Starting pg_dump"
log "Database           : $DB_ID"
log "Environment        : $TARGET_ENV"
log "Postgres version   : $PG_VER"
log "Host               : $HOST"
log "DB name            : $DB_NAME"
log "User               : $DB_USER"
log "Output file        : $OUT"
log "Docker network     : ${NETWORK:-host}"
log "Dump format        : $DUMP_FORMAT"
log "Dump jobs          : ${JOBS:-default}"
log "Dump compress      : ${COMPRESS:-default}"
log "Run mode           : $RUN_MODE"

log "Launching pg_dump container (verbose)"

if [[ "$RUN_MODE" == "docker" ]]; then
  docker run --rm \
    "${DOCKER_NET_ARGS[@]}" \
    --user "$(id -u):$(id -g)" \
    -e PGPASSWORD \
    -v "$PWD:/work" \
    postgres:${PG_VER} \
    pg_dump \
      -v \
      $FORMAT_FLAG \
      "${JOBS_ARGS[@]}" \
      "${COMPRESS_ARGS[@]}" \
      $DATA_ONLY \
      --no-owner \
      --no-acl \
      "${EXCLUDE_ARGS[@]}" \
      "${INCLUDE_ARGS[@]}" \
      -h "$HOST" \
      -U "$DB_USER" \
      -d "$DB_NAME" \
      -f "/work/$OUT"
else
  pg_dump \
    -v \
    $FORMAT_FLAG \
    "${JOBS_ARGS[@]}" \
    "${COMPRESS_ARGS[@]}" \
    $DATA_ONLY \
    --no-owner \
    --no-acl \
    "${EXCLUDE_ARGS[@]}" \
    "${INCLUDE_ARGS[@]}" \
    -h "$HOST" \
    -U "$DB_USER" \
    -d "$DB_NAME" \
    -f "$OUT"
fi

if [[ "$WRITE_CHECKSUM" == "yes" ]]; then
  CHECKSUM_TOOL="$(checksum_cmd)" || { echo "Missing dependency: sha256sum or shasum"; exit 1; }
  if [[ -f "$OUT" ]]; then
    eval "$CHECKSUM_TOOL \"$OUT\" > \"$OUT.sha256\""
  elif [[ -d "$OUT" ]]; then
    find "$OUT" -type f -print0 | sort -z | xargs -0 $CHECKSUM_TOOL > "$OUT.sha256"
  fi
  log "Checksum written to $OUT.sha256"
fi

if [[ -n "$KEEP_DAYS" ]]; then
  find "$BASE_DIR" -mindepth 1 -maxdepth 1 \
    -name "${DB_ID}_*.$OUT_EXT" -mtime "+$KEEP_DAYS" -exec rm -rf {} +
  log "Pruned backups older than $KEEP_DAYS days"
fi

if [[ -n "$KEEP_COUNT" ]]; then
  mapfile -t BACKUP_LIST < <(ls -dt "$BASE_DIR/${DB_ID}_"*".${OUT_EXT}" 2>/dev/null || true)
  if (( ${#BACKUP_LIST[@]} > KEEP_COUNT )); then
    for old in "${BACKUP_LIST[@]:$KEEP_COUNT}"; do
      rm -rf "$old"
      rm -f "$old.sha256"
    done
    log "Kept $KEEP_COUNT most recent backups"
  fi
fi

log "pg_dump completed successfully"
log "Dump written to $OUT"
