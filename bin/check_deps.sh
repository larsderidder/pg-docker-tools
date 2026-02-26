#!/usr/bin/env bash
set -euo pipefail

missing=()
for cmd in docker yq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    missing+=("$cmd")
  fi
done

if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
  missing+=("sha256sum|shasum")
fi

if (( ${#missing[@]} > 0 )); then
  echo "Missing dependencies: ${missing[*]}"
  exit 1
fi

echo "All dependencies available: docker, yq, sha256sum|shasum"

# Optional: aws CLI is required only for pg_ship.sh
if ! command -v aws >/dev/null 2>&1; then
  echo "Optional: aws CLI not found (required for pg_ship.sh)"
else
  echo "Optional: aws CLI available (pg_ship.sh ready)"
fi
