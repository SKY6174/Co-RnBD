#!/bin/sh
# Use the same reviewed CLI release locally and in CI. Preserve explicit targets/consent.
set -eu

SUPABASE_REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SUPABASE_EXPECTED_VERSION=$(cat "$SUPABASE_REPO_ROOT/.supabase-cli-version")
if ! command -v supabase >/dev/null 2>&1; then
  echo "Install Supabase CLI $SUPABASE_EXPECTED_VERSION (see README.md)." >&2
  exit 1
fi
SUPABASE_ACTUAL_VERSION=$(supabase --version)
if [ "$SUPABASE_ACTUAL_VERSION" != "$SUPABASE_EXPECTED_VERSION" ]; then
  echo "Supabase CLI $SUPABASE_EXPECTED_VERSION required; found $SUPABASE_ACTUAL_VERSION. See README.md." >&2
  exit 1
fi

for SUPABASE_ARGUMENT in "$@"; do
  case "$SUPABASE_ARGUMENT" in
    --workdir|--workdir=*) exec supabase "$@" ;;
  esac
done
exec supabase --workdir "$SUPABASE_REPO_ROOT" "$@"
