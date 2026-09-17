#!/bin/sh
# Tier-A runner: every cases/*.sh in sorted order, each in its own process and temp dir.
set -u

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
CASES_DIR="$SELF_DIR/cases"
ONB_ROOT=$(cd -- "$SELF_DIR/../.." && pwd)
export ONB_ROOT

if [ ! -d "$CASES_DIR" ]; then
    printf 'run.sh: no cases directory at %s\n' "$CASES_DIR" >&2
    exit 2
fi

total=0
failed=0
skipped=0

for casefile in "$CASES_DIR"/*.sh; do
    [ -f "$casefile" ] || continue
    name=$(basename -- "$casefile")
    case "$name" in
        00-lib.sh) continue ;;
    esac

    total=$((total + 1))
    printf '>> %s\n' "$name"

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/cosift-onboarding-test.XXXXXX") || exit 2
    (
        ONB_TMP="$tmpdir"
        export ONB_TMP
        cd -- "$tmpdir" || exit 2
        sh "$casefile"
    )
    status=$?
    rm -rf -- "$tmpdir"

    if [ "$status" -eq 0 ]; then
        printf 'PASS %s\n' "$name"
    elif [ "$status" -eq 77 ]; then
        skipped=$((skipped + 1))
        printf 'SKIP %s\n' "$name"
    else
        failed=$((failed + 1))
        printf 'FAIL %s (exit %s)\n' "$name" "$status"
    fi
done

printf '\n%s cases, %s failed, %s skipped\n' "$total" "$failed" "$skipped"
[ "$failed" -eq 0 ] || exit 1
exit 0
