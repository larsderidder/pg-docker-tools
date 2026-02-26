#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pg_ship.sh <dump_path> [options]

Ships a dump file or directory to an S3-compatible bucket (AWS S3, Garage, Tigris, Cloudflare R2, etc.).

Uses the AWS CLI under the hood. Set credentials via environment variables:
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION

Options:
  --bucket <name>          Target bucket name (required if not set in config)
  --prefix <path>          Key prefix inside the bucket (default: "pgbackups")
  --endpoint <url>         S3 endpoint URL (required for Garage, Tigris, R2, etc.)
  --config <path>          Path to config.yaml (reads ship.bucket / ship.prefix / ship.endpoint)
  --no-checksum            Skip uploading the .sha256 file alongside the dump
  --delete-after           Delete the local dump after a successful upload
  -h, --help               Show this help

Exit codes:
  0  success
  1  usage / config error
  2  upload failed

Examples:
  # Ship to AWS S3
  pg_ship.sh backups/app/prod/app_20260101_020000.dump \
    --bucket my-backups --prefix pgbackups/app/prod

  # Ship to Garage (or any S3-compatible store)
  pg_ship.sh backups/app/prod/app_20260101_020000.dump \
    --bucket my-backups \
    --endpoint https://s3.garage.example.com

  # Read bucket/endpoint from config.yaml, then clean up local file
  pg_ship.sh backups/app/prod/app_20260101_020000.dump \
    --config config.yaml --delete-after
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

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

DUMP_PATH="${1:-}"
shift || true

if [[ -z "$DUMP_PATH" ]]; then
  usage
  exit 1
fi

BUCKET=""
PREFIX=""
ENDPOINT=""
CONF_PATH="$CONF_DEFAULT"
UPLOAD_CHECKSUM="yes"
DELETE_AFTER="no"

while (( "$#" )); do
  case "$1" in
    --bucket)
      BUCKET="$2"
      shift 2
      ;;
    --prefix)
      PREFIX="$2"
      shift 2
      ;;
    --endpoint)
      ENDPOINT="$2"
      shift 2
      ;;
    --config)
      CONF_PATH="$2"
      shift 2
      ;;
    --no-checksum)
      UPLOAD_CHECKSUM="no"
      shift
      ;;
    --delete-after)
      DELETE_AFTER="yes"
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

require_cmd aws

# Read defaults from config.yaml if present
if [[ -f "$CONF_PATH" ]] && command -v yq >/dev/null 2>&1; then
  [[ -z "$BUCKET"   ]] && BUCKET="$(yq -r '.ship.bucket // ""'   "$CONF_PATH")"
  [[ -z "$PREFIX"   ]] && PREFIX="$(yq -r '.ship.prefix // ""'   "$CONF_PATH")"
  [[ -z "$ENDPOINT" ]] && ENDPOINT="$(yq -r '.ship.endpoint // ""' "$CONF_PATH")"
fi

PREFIX="${PREFIX:-pgbackups}"

if [[ -z "$BUCKET" ]]; then
  echo "No bucket specified. Pass --bucket or set ship.bucket in config.yaml."
  exit 1
fi

[[ -e "$DUMP_PATH" ]] || { echo "Dump path not found: $DUMP_PATH"; exit 1; }

DUMP_PATH="$(realpath "$DUMP_PATH")"
DUMP_NAME="$(basename "$DUMP_PATH")"
S3_TARGET="s3://${BUCKET}/${PREFIX}/${DUMP_NAME}"

ENDPOINT_ARGS=()
[[ -n "$ENDPOINT" ]] && ENDPOINT_ARGS+=(--endpoint-url "$ENDPOINT")

log "Shipping dump to S3"
log "Local path  : $DUMP_PATH"
log "Bucket      : $BUCKET"
log "Key prefix  : $PREFIX"
log "S3 target   : $S3_TARGET"
[[ -n "$ENDPOINT" ]] && log "Endpoint    : $ENDPOINT"

if [[ -f "$DUMP_PATH" ]]; then
  aws s3 cp "${ENDPOINT_ARGS[@]}" "$DUMP_PATH" "$S3_TARGET" || exit 2
elif [[ -d "$DUMP_PATH" ]]; then
  aws s3 cp "${ENDPOINT_ARGS[@]}" --recursive "$DUMP_PATH" "${S3_TARGET}/" || exit 2
fi

log "Upload complete"

if [[ "$UPLOAD_CHECKSUM" == "yes" && -f "${DUMP_PATH}.sha256" ]]; then
  aws s3 cp "${ENDPOINT_ARGS[@]}" "${DUMP_PATH}.sha256" "${S3_TARGET}.sha256" || exit 2
  log "Checksum uploaded to ${S3_TARGET}.sha256"
fi

if [[ "$DELETE_AFTER" == "yes" ]]; then
  rm -rf "$DUMP_PATH" "${DUMP_PATH}.sha256"
  log "Local dump deleted"
fi

log "pg_ship completed successfully"
