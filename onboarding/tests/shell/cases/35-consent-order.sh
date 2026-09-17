#!/bin/sh
# Consent order: no ledger-writing call is instructed before the consent block, and none
# before the user approves the list.
set -u
# shellcheck disable=SC1091
. "$(dirname -- "$0")/00-lib.sh"

BODY="$ONB_ROOT/interview/BODY.md"
MANIFEST="$ONB_ROOT/generated/MANIFEST.json"

[ -f "$BODY" ] || skip_case "interview/BODY.md has not landed yet"

check_order() { # path label -> "OK<tab>..." or "FAIL<tab>..." lines
    python3 - "$1" "$2" <<'PY'
import re
import sys

path, label = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

end = text.find("[CONSENT-BLOCK-END]")
if end < 0:
    print(f"FAIL\t{label}: no [CONSENT-BLOCK-END] marker")
    raise SystemExit(0)

# The point in the file after which the user has said yes.
APPROVAL = "Wait for a clear yes before anything is sent"

WRITER = re.compile(r"cosift_(lookup|request|topics)")

# A line before the gate may name a writing tool only when it is stating the rule about
# that tool. These are the shapes that count as stating the rule; anything else reads as
# an instruction to call one, which is the defect this case exists to catch.
RULE_SHAPES = (
    re.compile(r"\bNever (send|make)\b"),
    re.compile(r"\bmay not\b"),
    re.compile(r"Only cosift_search may run before the user has approved the list"),
    re.compile(r"Show the block below before any\b"),
    re.compile(r"\btool list\b"),
)

bad = []
for number, line in enumerate(text[:end].splitlines(), start=1):
    if not WRITER.search(line):
        continue
    if any(shape.search(line) for shape in RULE_SHAPES):
        continue
    bad.append(f"line {number}: {line.strip()}")

approval = text.find(APPROVAL)
if approval < 0:
    bad.append(f"the approval step is not stated: {APPROVAL!r} appears nowhere")

for name in ('cosift_topics("add"', "cosift_lookup(", "cosift_request("):
    first = text.find(name)
    if first < 0:
        bad.append(f"{name} appears nowhere in the file")
    elif first < end:
        bad.append(f"{name} is first used before the consent block")
    elif 0 <= approval and first < approval:
        bad.append(f"{name} is first used before the user approves the list")

if bad:
    print(f"FAIL\t{label}")
    for item in bad:
        print(f"DETAIL\t{item}")
else:
    print(f"OK\t{label}")
PY
}

report() { # output label
    case $1 in
    OK*) pass_note "$2" ;;
    *) fail_note "$2" "$(printf '%s' "$1" | grep '^DETAIL' | sed 's/^DETAIL\t//' | tr '\n' '|')" ;;
    esac
}

out=$(check_order "$BODY" "BODY.md")
report "$out" "no ledger-writing call is instructed before consent and approval in BODY.md"

# The same must hold in each wrapper, because that is the file a harness actually loads.
if [ ! -f "$MANIFEST" ]; then
    skip_note "wrapper ordering not checked: generated/MANIFEST.json is missing"
else
    for harness in claude codex hermes opencode; do
        relpath=$(manifest_field "$MANIFEST" "$harness" generated_path 2>/dev/null) || relpath=''
        generated="$ONB_ROOT/$relpath"
        if [ -z "$relpath" ] || [ ! -f "$generated" ]; then
            fail_note "$harness generated file is missing for the ordering check" "$generated"
            continue
        fi
        out=$(check_order "$generated" "$harness")
        report "$out" "$harness wrapper keeps every writing call after consent and approval"
    done
fi

finish
