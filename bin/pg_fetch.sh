#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: pg_fetch.sh <s3_path> [options]

Downloads a dump file or directory from an S3-compatible store to a local path.
The .sha256 checksum file is downloaded and verified automatically (pass
--no-checksum to skip).

Uses the AWS CLI under the hood. Set credentials via environment variables:
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION

Arguments:
  <s3_path>   Full S3 key path, e.g. pgbackups/app/prod/app_20260101_020000.dump
              Or a full s3:// URI, e.g. s3://my-bucket/pgbackups/app/prod/app_20260101_020000.dump

Options:
  --bucket <name>      Source bucket name (required unless s3_path is a full s3:// URI
                       or bucket is set in config)
  --endpoint <url>     S3 endpoint URL (required for Garage, Tigris, R2, etc.)
  --output <path>      Local destination path (default: current directory, filename from S3 key)
  --config <path>      Path to config.yaml (reads ship.bucket / ship.endpoint)
  --no-checksum        Skip downloading and verifying the .sha256 file
  -h, --help           Show this help

Exit codes:
  0  success
  1  usage / config error
  2  download failed
  3  checksum verification failed

Examples:
  # Fetch using bucket and endpoint from config.yaml
  pg_fetch.sh pgbackups/app/prod/app_20260101_020000.dump --config config.yaml

  # Fetch from AWS S3 with explicit bucket, save to backups/
  pg_fetch.sh pgbackups/app/prod/app_20260101_020000.dump \
    --bucket my-backups --output backups/

  # Fetch from Garage
  pg_fetch.sh pgbackups/app/prod/app_20260101_020000.dump \
    --bucket my-backups \
    --endpoint https://s3.garage.example.com \
    --output backups/app/prod/

  # Fetch using a full s3:// URI
  pg_fetch.sh s3://my-backups/pgbackups/app/prod/app_20260101_020000.dump
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

S3_PATH="${1:-}"
shift || true

if [[ -z "$S3_PATH" ]]; then
  usage
  exit 1
fi

BUCKET=""
ENDPOINT=""
OUTPUT=""
CONF_PATH="$CONF_DEFAULT"
VERIFY_CHECKSUM="yes"

while (( "$#" )); do
  case "$1" in
    --bucket)
      BUCKET="$2"
      shift 2
      ;;
    --endpoint)
      ENDPOINT="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    --config)
      CONF_PATH="$2"
      shift 2
      ;;
    --no-checksum)
      VERIFY_CHECKSUM="no"
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
  [[ -z "$BUCKET"   ]] && BUCKET="$(yq -r '.ship.bucket // ""'     "$CONF_PATH")"
  [[ -z "$ENDPOINT" ]] && ENDPOINT="$(yq -r '.ship.endpoint // ""' "$CONF_PATH")"
fi

ENDPOINT_ARGS=()
[[ -n "$ENDPOINT" ]] && ENDPOINT_ARGS+=(--endpoint-url "$ENDPOINT")

# Handle full s3:// URIs
if [[ "$S3_PATH" == s3://* ]]; then
  S3_URI="$S3_PATH"
  # Extract bucket and key from URI
  URI_NO_SCHEME="${S3_PATH#s3://}"
  BUCKET="${URI_NO_SCHEME%%/*}"
  S3_KEY="${URI_NO_SCHEME#*/}"
else
  if [[ -z "$BUCKET" ]]; then
    echo "No bucket specified. Pass --bucket or set ship.bucket in config.yaml."
    exit 1
  fi
  S3_KEY="$S3_PATH"
  S3_URI="s3://${BUCKET}/${S3_KEY}"
fi

DUMP_NAME="$(basename "$S3_KEY")"

# Resolve output path
if [[ -z "$OUTPUT" ]]; then
  LOCAL_PATH="$PWD/$DUMP_NAME"
elif [[ -d "$OUTPUT" || "$OUTPUT" == */ ]]; then
  LOCAL_PATH="${OUTPUT%/}/$DUMP_NAME"
else
  LOCAL_PATH="$OUTPUT"
fi

mkdir -p "$(dirname "$LOCAL_PATH")"

log "Fetching dump from S3"
log "S3 source   : $S3_URI"
log "Bucket      : $BUCKET"
[[ -n "$ENDPOINT" ]] && log "Endpoint    : $ENDPOINT"
log "Local path  : $LOCAL_PATH"

# Directory dumps are stored as S3 "folders" (key prefix), use sync
if [[ "$DUMP_NAME" == *.dumpdir || "$DUMP_NAME" == */ ]]; then
  aws s3 sync "${ENDPOINT_ARGS[@]}" "$S3_URI" "$LOCAL_PATH" || exit 2
else
  aws s3 cp "${ENDPOINT_ARGS[@]}" "$S3_URI" "$LOCAL_PATH" || exit 2
fi

log "Download complete"

if [[ "$VERIFY_CHECKSUM" == "yes" ]]; then
  CHECKSUM_S3="${S3_URI}.sha256"
  CHECKSUM_LOCAL="${LOCAL_PATH}.sha256"

  if aws s3 ls "${ENDPOINT_ARGS[@]}" "$CHECKSUM_S3" >/dev/null 2>&1; then
    log "Downloading checksum file"
    aws s3 cp "${ENDPOINT_ARGS[@]}" "$CHECKSUM_S3" "$CHECKSUM_LOCAL" || exit 2

    log "Verifying checksum"
    # sha256sum expects the filename in the .sha256 file to match; run from the dump's directory
    DUMP_DIR="$(dirname "$LOCAL_PATH")"
    CHECKSUM_BASENAME="$(basename "$CHECKSUM_LOCAL")"
    (cd "$DUMP_DIR" && sha256sum -c "$CHECKSUM_BASENAME") || {
      log "ERROR: Checksum verification failed"
      exit 3
    }
    log "Checksum OK"
  else
    log "No checksum file found at ${CHECKSUM_S3}, skipping verification"
  fi
fi

log "pg_fetch completed successfully"
log "Dump available at: $LOCAL_PATH"
