#!/bin/sh
# SELF-TEST FIXTURE, NOT THE SHIPPED INSTALLER.
# A reference implementation of the install contract, used by run.sh --self-test
# to check that the Tier B assertions can actually pass and fail.
set -eu
umask 022

# shellcheck disable=SC1007
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
GEN=$SELF_DIR/generated
ARTIFACT=cosift-onboarding
: "${XDG_CONFIG_HOME:=$HOME/.config}"

HARNESS=
DRYRUN=no
FORCE=no
UNINSTALL=no
CODEX_SKILLS_DIR=${CODEX_SKILLS_DIR:-$HOME/.agents/skills}

usage() {
    cat <<EOF
Usage: install-onboarding.sh --harness <claude|codex|opencode|hermes> [options]

  --dry-run                show what would change, write nothing
  --force                  replace a foreign file, after backing it up
  --uninstall              remove our file and our own directory
  --codex-skills-dir DIR   override ~/.agents/skills
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
    --harness)
        shift
        HARNESS=${1:-}
        ;;
    --dry-run) DRYRUN=yes ;;
    --force) FORCE=yes ;;
    --uninstall) UNINSTALL=yes ;;
    --codex-skills-dir)
        shift
        CODEX_SKILLS_DIR=${1:-}
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "unknown option: $1" >&2
        exit 64
        ;;
    esac
    shift
done

case $HARNESS in
claude)
    TARGET=$HOME/.claude/skills/$ARTIFACT/SKILL.md
    SRC=$GEN/claude/SKILL.md
    OWN_DIR=$HOME/.claude/skills/$ARTIFACT
    ;;
codex)
    TARGET=$CODEX_SKILLS_DIR/$ARTIFACT/SKILL.md
    SRC=$GEN/codex/SKILL.md
    OWN_DIR=$CODEX_SKILLS_DIR/$ARTIFACT
    ;;
opencode)
    TARGET=$XDG_CONFIG_HOME/opencode/commands/$ARTIFACT.md
    SRC=$GEN/opencode/$ARTIFACT.md
    OWN_DIR=
    ;;
hermes)
    TARGET=${HERMES_HOME:-$HOME/.hermes}/skills/$ARTIFACT/SKILL.md
    SRC=$GEN/hermes/SKILL.md
    OWN_DIR=${HERMES_HOME:-$HOME/.hermes}/skills/$ARTIFACT
    ;;
*)
    echo "unknown harness: ${HARNESS:-<none>}" >&2
    usage >&2
    exit 64
    ;;
esac

if [ "$UNINSTALL" = yes ]; then
    if [ "$DRYRUN" = yes ]; then
        echo "would remove $TARGET"
        exit 0
    fi
    rm -f "$TARGET"
    [ -n "$OWN_DIR" ] && rmdir "$OWN_DIR" 2>/dev/null
    echo "removed $TARGET"
    exit 0
fi

[ -f "$SRC" ] || {
    echo "missing source file: $SRC" >&2
    exit 70
}

if [ "$HARNESS" = opencode ]; then
    RIVAL=$XDG_CONFIG_HOME/opencode/command/$ARTIFACT.md
    if [ -e "$RIVAL" ]; then
        echo "refusing: $RIVAL already exists." >&2
        echo "opencode scans both command/ and commands/, so installing would register" >&2
        echo "$ARTIFACT twice. Remove the file under command/ and re-run." >&2
        exit 3
    fi
fi

if [ -f "$TARGET" ] && cmp -s "$SRC" "$TARGET"; then
    echo "already installed: $TARGET"
    exit 0
fi

if [ -e "$TARGET" ] && [ "$FORCE" != yes ]; then
    echo "refusing: $TARGET exists and is not ours. Re-run with --force to back it up and replace it." >&2
    exit 3
fi

if [ "$DRYRUN" = yes ]; then
    [ -e "$TARGET" ] && echo "would back up $TARGET"
    echo "would write $TARGET (0644)"
    exit 0
fi

if [ -e "$TARGET" ]; then
    BACKUP=$TARGET.cosift-backup-$(date -u +%Y%m%dT%H%M%SZ)
    cp -p "$TARGET" "$BACKUP"
    echo "backed up $TARGET -> $BACKUP"
fi

mkdir -p "$(dirname "$TARGET")"
cp "$SRC" "$TARGET.tmp.$$"
chmod 0644 "$TARGET.tmp.$$"
mv "$TARGET.tmp.$$" "$TARGET"
echo "installed $TARGET"
