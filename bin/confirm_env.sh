#!/usr/bin/env bash
set -euo pipefail

target_env="$1"

if [[ "$target_env" == *prod* || "$target_env" == *production* ]]; then
  echo "You are about to restore a PRODUCTION environment: $target_env"
  echo "Type: RESTORE PROD"
  read -r confirmation
  [[ "$confirmation" == "RESTORE PROD" ]] || exit 1
fi
