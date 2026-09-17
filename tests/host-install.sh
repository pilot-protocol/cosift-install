#!/usr/bin/env bash
# Run the installer on THIS machine, against staging, exactly as a user would meet it.
#
#   tests/host-install.sh [--new-account] [any other install.sh flag]
#
# Unlike tests/e2e-onboarding.sh this does NOT use a scratch HOME: it writes to your real
# ~/.claude.json, ~/.claude/settings.json, ~/.claude/skills/ and ~/.local/bin. That is the
# point of it. Undo with:  tests/host-install.sh --uninstall
#
# Staging coordinates come from tests/e2e-staging.env, which is not tracked.
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF/.." && pwd)

# shellcheck disable=SC1091
[ -f "$SELF/e2e-staging.env" ] && . "$SELF/e2e-staging.env"

PROJECT="${COSIFT_E2E_PROJECT:?set COSIFT_E2E_PROJECT in tests/e2e-staging.env}"
REGION="${COSIFT_E2E_REGION:?set COSIFT_E2E_REGION}"
AUTH_SERVICE="${COSIFT_E2E_AUTH_SERVICE:?set COSIFT_E2E_AUTH_SERVICE}"
MCP_SERVICE="${COSIFT_E2E_MCP_SERVICE:?set COSIFT_E2E_MCP_SERVICE}"

die() { printf '!! %s\n' "$*" >&2; exit 1; }
command -v gcloud >/dev/null || die "gcloud is not on PATH"

AUTH_BASE=$(gcloud run services describe "$AUTH_SERVICE" --region="$REGION" \
  --project="$PROJECT" --format='value(status.url)') || die "cannot reach $AUTH_SERVICE"
MCP_BASE=$(gcloud run services describe "$MCP_SERVICE" --region="$REGION" \
  --project="$PROJECT" --format='value(status.url)') || die "cannot reach $MCP_SERVICE"
ID_TOKEN=$(gcloud auth print-identity-token) || die "cannot mint an identity token"

# ~/.claude is a git repo on this machine, so record where it stood before we touch it.
if git -C "$HOME/.claude" rev-parse --git-dir >/dev/null 2>&1; then
  printf '   ~/.claude is git-tracked; after the run:\n'
  printf '     git -C ~/.claude diff settings.json        what the installer added\n'
  printf '     git -C ~/.claude checkout settings.json    put it back\n\n'
fi

exec env \
  COSIFT_AUTH_BASE="$AUTH_BASE" \
  COSIFT_MCP_URL="${MCP_BASE%/}/v1/mcp" \
  COSIFT_EXTRA_HEADER="X-Serverless-Authorization: Bearer $ID_TOKEN" \
  sh "$REPO/install.sh" "$@"
