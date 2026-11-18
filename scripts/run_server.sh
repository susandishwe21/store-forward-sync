#!/usr/bin/env bash
# Loads settings from .env (if it exists) and starts the sync server.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -f .env ]; then
  set -a
  source .env
  set +a
fi
exec dart run packages/sf_server/bin/serve.dart
