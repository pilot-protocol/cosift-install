#!/usr/bin/env bash
# The one real-endpoint run: the test image, pointed at IAM-gated staging.
#
#   COSIFT_E2E_EMAIL='you+cosift@example.com' tests/e2e-staging.sh [-- INSTALL_ARGS]
#
# Resolves the staging URLs from Cloud Run (never hardcodes a *.run.app URL),
# mints an identity token, and hands you an interactive container so you can
# type the real 6-digit code from your inbox.
#
# Deployment coordinates come from tests/e2e-staging.env, which is not tracked:
#   COSIFT_E2E_PROJECT / _REGION / _AUTH_SERVICE / _MCP_SERVICE
set -euo pipefail

if [ -f "$(dirname "$0")/e2e-staging.env" ]; then
  # shellcheck disable=SC1091
  . "$(dirname "$0")/e2e-staging.env"
fi

# Deployment coordinates are supplied by the environment, never defaulted here: this
# repository is public and the deployment it points at is not.
PROJECT="${COSIFT_E2E_PROJECT:?set COSIFT_E2E_PROJECT}"
REGION="${COSIFT_E2E_REGION:?set COSIFT_E2E_REGION}"
AUTH_SERVICE="${COSIFT_E2E_AUTH_SERVICE:?set COSIFT_E2E_AUTH_SERVICE}"
MCP_SERVICE="${COSIFT_E2E_MCP_SERVICE:?set COSIFT_E2E_MCP_SERVICE}"
IMAGE="${COSIFT_TEST_IMAGE:-cosift-install-tests:latest}"

SELF=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF/.." && pwd)

INSTALL_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --) shift; INSTALL_ARGS=("$@"); break ;;
    -h|--help)
      sed -n '2,12p' "$0"; exit 0 ;;
    *) INSTALL_ARGS+=("$1"); shift ;;
  esac
done

die() { printf '!! %s\n' "$*" >&2; exit 1; }

command -v gcloud >/dev/null || die "gcloud is not on PATH"
command -v docker >/dev/null || die "docker is not on PATH"
[ -f "$REPO/install.sh" ] || die "$REPO/install.sh does not exist yet"

EMAIL="${COSIFT_E2E_EMAIL:-}"
[ -n "$EMAIL" ] || die "set COSIFT_E2E_EMAIL to a plus-addressed inbox you control"
case "$EMAIL" in
  *+*@*) ;;
  *) die "COSIFT_E2E_EMAIL must be plus-addressed (e.g. you+cosift@example.com);
   got '$EMAIL'. Plus-addressing is mandated so staging signups stay traceable
   and disposable." ;;
esac

echo "==> resolving staging URLs from Cloud Run ($PROJECT / $REGION)"
AUTH_BASE=$(gcloud run services describe "$AUTH_SERVICE" \
  --region="$REGION" --project="$PROJECT" --format='value(status.url)') \
  || die "could not describe $AUTH_SERVICE"
MCP_BASE=$(gcloud run services describe "$MCP_SERVICE" \
  --region="$REGION" --project="$PROJECT" --format='value(status.url)') \
  || die "could not describe $MCP_SERVICE"
[ -n "$AUTH_BASE" ] || die "$AUTH_SERVICE has no status.url"
[ -n "$MCP_BASE" ] || die "$MCP_SERVICE has no status.url"
MCP_URL="${MCP_BASE%/}/v1/mcp"

echo "==> minting an identity token"
ID_TOKEN=$(gcloud auth print-identity-token) || die "could not mint an identity token"
[ -n "$ID_TOKEN" ] || die "empty identity token"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "==> building $IMAGE"
  docker build -f "$REPO/tests/Dockerfile" -t "$IMAGE" "$REPO/tests"
fi

cat <<EOF

================================================================
  cosift-install E2E against REAL staging
================================================================
  auth base : $AUTH_BASE
  mcp url   : $MCP_URL
  email     : $EMAIL
  extra hdr : X-Serverless-Authorization: Bearer <identity token>

  What to expect
  --------------
  1. The installer asks for your email. Type exactly:
         $EMAIL
  2. /auth/start always returns 200 after ~800 ms, whatever you type.
     "A code is on its way" is conditional, not a promise.
  3. Check that inbox for a 6-digit code and type it in. The cap is
     3 codes per address per hour, so do not spam a re-run.
  4. A green finish means a real ck_ token was minted AND a real MCP
     initialize returned 200.

  Reading a 401
  -------------
  * Google HTML page (starts with "<html>" / mentions "Your client does
    not have permission"):  the IDENTITY TOKEN expired or is wrong.
    They are valid ~1 hour. Re-run this script to mint a fresh one.
  * JSON {"error":"invalid_token"}:  OUR service rejected the ck_ token.
    The identity token is fine; the cosift credential is not.
  A 403 is a banned account (a new token will not help).
  A 421 means the hostname is not in the MCP service's ALLOWED_HOSTS.

  Nothing on your host is touched: HOME is inside the throwaway container.
================================================================

EOF

set -x
exec docker run --rm -it \
  --user tester \
  -e HOME=/home/tester \
  -e COSIFT_AUTH_BASE="$AUTH_BASE" \
  -e COSIFT_MCP_URL="$MCP_URL" \
  -e COSIFT_EXTRA_HEADER="X-Serverless-Authorization: Bearer $ID_TOKEN" \
  -v "$REPO:/work:ro" \
  -w /home/tester \
  "$IMAGE" \
  sh /work/install.sh ${INSTALL_ARGS[@]+"${INSTALL_ARGS[@]}"}
