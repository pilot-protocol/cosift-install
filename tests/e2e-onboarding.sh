#!/usr/bin/env bash
# The interview end-to-end run: install.sh against real staging, then the onboarding
# interview inside a real Claude Code session reading the artifact the installer wrote.
#
#   tests/e2e-onboarding.sh              set up, then hand you a shell to drive it yourself
#   tests/e2e-onboarding.sh --drive      drive it non-interactively with `claude -p`
#   tests/e2e-onboarding.sh --keep       do not delete the scratch tree on exit
#
# Nothing on your host is touched: HOME is redirected to a scratch tree and the real
# ~/.claude.json is hashed before and after to prove it.
#
# Deployment coordinates come from tests/e2e-staging.env, which is not tracked:
#   COSIFT_E2E_PROJECT / _REGION / _AUTH_SERVICE / _MCP_SERVICE
# Optional: COSIFT_E2E_TOKEN, a ck_ token from an earlier staging signup. When set it is
# seeded where install.sh's recovery path will find it, so a re-run needs no email round
# trip and no verification-code quota.
set -euo pipefail

SELF=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$SELF/.." && pwd)

if [ -f "$SELF/e2e-staging.env" ]; then
  # shellcheck disable=SC1091
  . "$SELF/e2e-staging.env"
fi

PROJECT="${COSIFT_E2E_PROJECT:?set COSIFT_E2E_PROJECT}"
REGION="${COSIFT_E2E_REGION:?set COSIFT_E2E_REGION}"
AUTH_SERVICE="${COSIFT_E2E_AUTH_SERVICE:?set COSIFT_E2E_AUTH_SERVICE}"
MCP_SERVICE="${COSIFT_E2E_MCP_SERVICE:?set COSIFT_E2E_MCP_SERVICE}"

DRIVE=0
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --drive) DRIVE=1; shift ;;
    --keep)  KEEP=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) printf '!! unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

die() { printf '!! %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

command -v gcloud >/dev/null || die "gcloud is not on PATH"
command -v claude >/dev/null || die "claude is not on PATH"
[ -f "$REPO/install.sh" ] || die "$REPO/install.sh does not exist"

# ------------------------------------------------------------------ host baseline
HOST_CLAUDE_JSON="$HOME/.claude.json"
host_fingerprint() {
  sha256sum "$HOST_CLAUDE_JSON" 2>/dev/null | cut -d' ' -f1 || echo ABSENT
}
HOST_BEFORE=$(host_fingerprint)
HOST_SKILLS_BEFORE=$(find "$HOME/.claude/skills" -maxdepth 2 2>/dev/null | sort || true)

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cosift-onboarding-e2e.XXXXXX")
cleanup() {
  rc=$?
  # The credential copy is the only secret in the tree; remove it even with --keep.
  rm -f "$SCRATCH/.claude/.credentials.json" 2>/dev/null || true
  if [ "$KEEP" -eq 1 ]; then
    printf '\n   scratch tree kept at %s (credentials removed)\n' "$SCRATCH"
  else
    rm -rf "$SCRATCH"
  fi
  HOST_AFTER=$(host_fingerprint)
  if [ "$HOST_BEFORE" != "$HOST_AFTER" ]; then
    printf '\n!! YOUR HOST ~/.claude.json CHANGED during this run (%s -> %s).\n' \
      "$HOST_BEFORE" "$HOST_AFTER" >&2
    printf '!! A backup should exist at %s.cosift-backup-*\n' "$HOST_CLAUDE_JSON" >&2
    exit 1
  fi
  if [ "$HOST_SKILLS_BEFORE" != "$(find "$HOME/.claude/skills" -maxdepth 2 2>/dev/null | sort || true)" ]; then
    printf '\n!! YOUR HOST ~/.claude/skills CHANGED during this run.\n' >&2
    exit 1
  fi
  printf '   host ~/.claude.json unchanged (%s)\n' "${HOST_BEFORE:0:12}"
  exit $rc
}
trap cleanup EXIT

# ------------------------------------------------------------------ staging coordinates
step "resolving staging URLs from Cloud Run ($PROJECT / $REGION)"
AUTH_BASE=$(gcloud run services describe "$AUTH_SERVICE" \
  --region="$REGION" --project="$PROJECT" --format='value(status.url)') \
  || die "could not describe $AUTH_SERVICE"
MCP_BASE=$(gcloud run services describe "$MCP_SERVICE" \
  --region="$REGION" --project="$PROJECT" --format='value(status.url)') \
  || die "could not describe $MCP_SERVICE"
MCP_URL="${MCP_BASE%/}/v1/mcp"

step "minting an identity token (valid ~1 hour)"
ID_TOKEN=$(gcloud auth print-identity-token) || die "could not mint an identity token"
EXTRA_HEADER="X-Serverless-Authorization: Bearer $ID_TOKEN"

# ------------------------------------------------------------------ scratch HOME
# HOME is overridden, CLAUDE_CONFIG_DIR is NOT: install.sh keys off HOME for ~/.claude.json
# while the claude CLI prefers CLAUDE_CONFIG_DIR, so setting both sends the MCP entry and the
# installer's idea of where it went to two different files.
step "preparing a scratch HOME at $SCRATCH"
mkdir -p "$SCRATCH/.claude" "$SCRATCH/.config"
command cp -f "$HOME/.claude/.credentials.json" "$SCRATCH/.claude/.credentials.json" 2>/dev/null \
  || printf '   no ~/.claude/.credentials.json to copy; export ANTHROPIC_API_KEY instead\n'
chmod 600 "$SCRATCH/.claude/.credentials.json" 2>/dev/null || true

# A scratch HOME is a brand-new machine to every tool that looks at it, and their first-run
# wizards are not what we are here to test. Seed just enough that this looks like a machine
# already in use: no zsh new-user menu, no Claude Code onboarding, theme picker, release
# notes or per-directory trust dialog.
: >"$SCRATCH/.zshrc"
printf 'PS1="%%~ %% "\n' >>"$SCRATCH/.zshrc"
CLAUDE_VERSION=$(claude --version 2>/dev/null | awk '{print $1}')
python3 - "$SCRATCH" "${CLAUDE_VERSION:-2.1.273}" "$PWD" <<'PY'
import json, os, sys
scratch, version, cwd = sys.argv[1], sys.argv[2], sys.argv[3]
src = os.path.expanduser('~/.claude.json')
seed = {}
try:
    with open(src) as fh:
        host = json.load(fh)
    # Presentation state only. Never projects (paths, history), never credentials or
    # anything under mcpServers - this file is the one the installer is about to edit.
    for k in ('theme', 'hasCompletedOnboarding', 'lastOnboardingVersion',
              'hasSeenAutoDefaultNotice', 'hasSeenTasksHint', 'hasSeenAutoModeOutsideReadPrompt',
              'editorMode', 'autoUpdates', 'preferredNotifChannel'):
        if k in host:
            seed[k] = host[k]
except Exception:
    seed['theme'] = 'dark'
    seed['hasCompletedOnboarding'] = True
seed.setdefault('hasCompletedOnboarding', True)
seed['lastReleaseNotesSeen'] = version
seed['lastClawdEntranceVersion'] = version
seed['numStartups'] = 50
trusted = {'hasTrustDialogAccepted': True, 'hasClaudeMdExternalIncludesApproved': True}
seed['projects'] = {cwd: dict(trusted), scratch: dict(trusted)}
with open(os.path.join(scratch, '.claude.json'), 'w') as fh:
    json.dump(seed, fh, indent=2)
PY
printf '   seeded a settled-looking environment (no zsh wizard, no Claude Code first run)\n'

if [ -n "${COSIFT_E2E_TOKEN:-}" ]; then
  # install.sh's recovery path scans every harness config and validates the candidate
  # against the MCP endpoint, so seeding opencode lets a claude-only install skip the
  # email round trip without pre-configuring the harness under test.
  mkdir -p "$SCRATCH/.config/opencode"
  cat >"$SCRATCH/.config/opencode/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
    "cosift-seed": {
      "type": "remote",
      "url": "$MCP_URL",
      "headers": { "Authorization": "Bearer $COSIFT_E2E_TOKEN" }
    }
  }
}
JSON
  printf '   seeded a recoverable credential; the installer will not ask for email\n'
fi

run_in_scratch() {
  env HOME="$SCRATCH" \
      PATH="$SCRATCH/.local/bin:$PATH" \
      COSIFT_AUTH_BASE="$AUTH_BASE" \
      COSIFT_MCP_URL="$MCP_URL" \
      COSIFT_EXTRA_HEADER="$EXTRA_HEADER" \
      "$@"
}

# ------------------------------------------------------------------ the install leg
step "running install.sh into the scratch HOME"
printf '   auth : %s\n   mcp  : %s\n' "$AUTH_BASE" "$MCP_URL"
if [ -z "${COSIFT_E2E_TOKEN:-}" ]; then
  cat <<'EOF'

   No COSIFT_E2E_TOKEN was set, so the installer will ask for your email and a
   6-digit code. Use a plus-addressed inbox you control. The cap is 3 codes per
   address per hour. Once you have a token, export it as COSIFT_E2E_TOKEN to make
   every later run non-interactive.

EOF
fi
run_in_scratch sh "$REPO/install.sh" --harness=claude --onboarding

# ------------------------------------------------------------------ what the installer left
ARTIFACT="$SCRATCH/.claude/skills/cosift-onboarding/SKILL.md"
GENERATED="$REPO/onboarding/generated/claude/cosift-onboarding/SKILL.md"
STATE_CMD="$SCRATCH/.local/bin/cosift-onboarding"

step "checking what the installer wrote"
[ -f "$ARTIFACT" ] || die "no interview artifact at $ARTIFACT"
cmp -s "$ARTIFACT" "$GENERATED" \
  && printf '   artifact byte-identical to onboarding/generated/ (%s bytes)\n' "$(wc -c <"$ARTIFACT")" \
  || die "artifact at $ARTIFACT differs from $GENERATED"
printf '   artifact mode %s\n' "$(stat -c '%a' "$ARTIFACT")"
[ -x "$STATE_CMD" ] || die "no executable state command at $STATE_CMD"
printf '   state command %s (mode %s)\n' "$STATE_CMD" "$(stat -c '%a' "$STATE_CMD")"
printf '   cosift-onboarding status -> '
run_in_scratch "$STATE_CMD" status || printf '(exit %s)\n' "$?"

step "confirming claude sees the server"
run_in_scratch claude mcp list 2>&1 | sed 's/^/   /' || true

# ------------------------------------------------------------------ the interview leg
ALLOW='mcp__cosift__cosift_search,mcp__cosift__cosift_lookup,mcp__cosift__cosift_request,mcp__cosift__cosift_topics,Bash(cosift-onboarding:*)'

if [ "$DRIVE" -eq 1 ]; then
  step "driving the interview with claude -p"
  TRANSCRIPT="$SCRATCH/turn1.json"
  run_in_scratch claude -p "/cosift-onboarding" \
    --output-format json --allowedTools "$ALLOW" </dev/null >"$TRANSCRIPT" \
    || die "the first turn failed; see $TRANSCRIPT"
  SID=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["session_id"])' "$TRANSCRIPT")
  printf '   session %s\n\n' "$SID"
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("result",""))' "$TRANSCRIPT"
  cat <<EOF

   Continue the interview with:

     env HOME=$SCRATCH PATH=$SCRATCH/.local/bin:\$PATH \\
       claude -p "your answer" --resume $SID --output-format json \\
       --allowedTools '$ALLOW' </dev/null

   The prompt must come immediately after -p; \`claude -p --resume ID "text"\` fails.
   Grade the run against onboarding/tests/GRADE.md, reading the per-call ground truth from
   $SCRATCH/.claude/projects/*/*.jsonl rather than the model's own summary.

EOF
  [ "$KEEP" -eq 1 ] || printf '   re-run with --keep to hold the transcript for grading\n'
  exit 0
fi

step "over to you"
cat <<EOF

   The installer offers to open Claude Code for you at the end. Say yes and the
   interview runs straight away - that is the path to check, not the slash command.

   If you declined, or want another go, open it yourself:

     env HOME=$SCRATCH PATH=$SCRATCH/.local/bin:\$PATH claude "set up cosift"

   And to prove the session-start hook on its own: open a plain \`claude\` in that
   environment and type anything at all. The hook injects its directive at startup, but
   an agent has no turn to act in until you send a message - so a blank prompt sits
   there doing nothing, by design.

   What to watch for:
     * one message, one list, one question - not a series of questions
     * every suggestion is a general subject. If you see a client, a repository or a
       codename from your own work, that is a blocker and I want to know
     * it should say in one line that it read a local summary that stays on this machine
     * say yes once and it should submit and finish, with no further confirmations

   Staging is shared, so pick subjects you would be happy to see as a public article
   title. The identity token expires in about an hour; if calls start failing, quit and
   re-run this script rather than re-minting mid-interview.

   Press Ctrl-D in the shell when you are done; this script then proves your host
   config is untouched.

EOF
env HOME="$SCRATCH" PATH="$SCRATCH/.local/bin:$PATH" \
    COSIFT_AUTH_BASE="$AUTH_BASE" COSIFT_MCP_URL="$MCP_URL" \
    COSIFT_EXTRA_HEADER="$EXTRA_HEADER" \
    "${SHELL:-/bin/sh}" -i || true
