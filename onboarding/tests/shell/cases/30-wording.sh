#!/bin/sh
# Wording lint: interview/BODY.md against the BANNED and REQUIRED lists in interview/WORDING.md.
set -u
# shellcheck disable=SC1091
. "$(dirname -- "$0")/00-lib.sh"

BODY="$ONB_ROOT/interview/BODY.md"
WORDING="$ONB_ROOT/interview/WORDING.md"

[ -f "$BODY" ] || skip_case "interview/BODY.md has not landed yet"
[ -f "$WORDING" ] || skip_case "interview/WORDING.md has not landed yet"

RULES="$ONB_TMP/wording-rules.tsv"
python3 - "$WORDING" >"$RULES" <<'PY'
import re
import sys

HEADING = re.compile(r"^\s{0,3}#{1,6}\s*(.+?)\s*$")
BULLET = re.compile(r"^[-*+]\s+")

section = None
for raw in open(sys.argv[1], encoding="utf-8").read().splitlines():
    heading = HEADING.match(raw)
    if heading:
        title = heading.group(1).lower()
        section = "B" if "banned" in title else "R" if "required" in title else None
        continue
    if section is None:
        continue
    item = BULLET.sub("", raw.strip())
    if len(item) >= 2 and item[0] == item[-1] and item[0] in "`\"'":
        item = item[1:-1]
    if item:
        print(f"{section}\t{item}")
PY

if [ ! -s "$RULES" ]; then
    skip_case "WORDING.md declares no BANNED or REQUIRED items under a heading naming them"
fi

TAB=$(printf '\t')
banned_seen=0
required_seen=0

while IFS="$TAB" read -r kind item; do
    [ -n "${item:-}" ] || continue
    case "$kind" in
        B)
            banned_seen=$((banned_seen + 1))
            if grep -i -F -q -e "$item" "$BODY"; then
                fail_note "banned wording present in BODY.md: $item"
            else
                pass_note "banned wording absent: $item"
            fi
            ;;
        R)
            required_seen=$((required_seen + 1))
            if grep -F -q -e "$item" "$BODY"; then
                pass_note "required wording present: $item"
            else
                fail_note "required wording missing from BODY.md: $item"
            fi
            ;;
    esac
done <"$RULES"

if [ "$banned_seen" -eq 0 ]; then
    note "NOTE no BANNED items parsed from WORDING.md"
fi
if [ "$required_seen" -eq 0 ]; then
    note "NOTE no REQUIRED items parsed from WORDING.md"
fi
if [ "$banned_seen" -eq 0 ] && [ "$required_seen" -eq 0 ]; then
    skip_case "WORDING.md parsed to zero rules"
fi

note "linted $banned_seen banned and $required_seen required items"
finish
