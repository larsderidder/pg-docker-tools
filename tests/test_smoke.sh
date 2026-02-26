#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

bash -n "$ROOT_DIR/bin/pg_dump.sh"
bash -n "$ROOT_DIR/bin/pg_restore.sh"
bash -n "$ROOT_DIR/bin/pg_ship.sh"
bash -n "$ROOT_DIR/bin/confirm_env.sh"

"$ROOT_DIR/bin/pg_dump.sh" --help >/dev/null || true
"$ROOT_DIR/bin/pg_restore.sh" --help >/dev/null || true
"$ROOT_DIR/bin/pg_ship.sh" --help >/dev/null
